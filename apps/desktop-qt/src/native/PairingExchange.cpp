#include "PairingExchange.h"

#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrlQuery>

#include <memory>

#include "McClient.h"

namespace pairing {

namespace {

constexpr int kTimeoutMs = 5000;

struct Attempt {
  QNetworkAccessManager* http;
  QObject* context;
  Link link;
  Client client;
  std::function<void(const Result&)> done;
};

QUrl at(const QUrl& origin, const QString& path) {
  QUrl url = origin;
  url.setPath(path);
  return url;
}

bool answered(const QNetworkReply* reply) {
  return reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).isValid();
}

void spend(const std::shared_ptr<Attempt>& attempt, const QUrl& origin, const QJsonObject& descriptor) {
  QNetworkRequest request(at(origin, QStringLiteral("/oauth/token")));
  request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/x-www-form-urlencoded"));
  request.setTransferTimeout(kTimeoutMs);
  QList<std::pair<QString, QString>> form{
      {QStringLiteral("grant_type"), QStringLiteral("urn:ietf:params:oauth:grant-type:token-exchange")},
      {QStringLiteral("subject_token_type"), QStringLiteral("urn:hal-c2:params:oauth:token-type:environment-bootstrap")},
      {QStringLiteral("subject_token"), attempt->link.token},
      {QStringLiteral("client_label"), attempt->client.label},
      {QStringLiteral("client_device_type"), attempt->client.deviceType},
  };
  if (!attempt->client.os.isEmpty()) form.append({QStringLiteral("client_os"), attempt->client.os});
  QByteArray body;
  for (const auto& [name, value] : form) {
    if (!body.isEmpty()) body += '&';
    body += name.toUtf8() + '=' + QUrl::toPercentEncoding(value);
  }
  QNetworkReply* reply = attempt->http->post(request, body);
  QObject::connect(reply, &QNetworkReply::finished, attempt->context, [attempt, reply, origin, descriptor] {
    reply->deleteLater();
    Result result{Outcome::Refused, origin, {}, descriptor};
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    result.token = QJsonDocument::fromJson(reply->readAll()).object().value(QLatin1String("access_token")).toString();
    if (!answered(reply)) {
      result.outcome = Outcome::Unreachable;
    } else if (status >= 200 && status < 300 && !result.token.isEmpty()) {
      result.outcome = Outcome::Paired;
    }
    if (result.outcome != Outcome::Paired) result.token.clear();
    attempt->done(result);
  });
}

// Asks the origin at `index` who it is. Only one that does not answer at all
// passes the question on to the next: an answer of any kind stands.
void describe(const std::shared_ptr<Attempt>& attempt, qsizetype index) {
  const QUrl origin = attempt->link.origins.at(index);
  QNetworkRequest request(at(origin, QStringLiteral("/.well-known/hal-c2/environment")));
  request.setTransferTimeout(kTimeoutMs);
  QNetworkReply* reply = attempt->http->get(request);
  QObject::connect(reply, &QNetworkReply::finished, attempt->context, [attempt, reply, origin, index] {
    reply->deleteLater();
    if (!answered(reply)) {
      if (index + 1 < attempt->link.origins.size()) return describe(attempt, index + 1);
      return attempt->done({Outcome::Unreachable, attempt->link.origins.first(), {}, {}});
    }
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QJsonObject descriptor = QJsonDocument::fromJson(reply->readAll()).object();
    const QJsonValue protocol = descriptor.value(QLatin1String("orchestrationProtocolVersion"));
    if (status < 200 || status >= 300 || descriptor.value(QLatin1String("environmentId")).toString().isEmpty() || !protocol.isDouble()) {
      return attempt->done({Outcome::NotMc, origin, {}, {}});
    }
    if (protocol.toInt() != McClient::kProtocol) return attempt->done({Outcome::Incompatible, origin, {}, descriptor});
    spend(attempt, origin, descriptor);
  });
}

}  // namespace

std::optional<Link> readLink(const QString& entered) {
  static const QRegularExpression scheme(QStringLiteral("^[a-zA-Z][a-zA-Z\\d+.-]*://"));
  static const QRegularExpression leadingSlashes(QStringLiteral("^/+"));
  QString text = entered.trimmed();
  const bool hasScheme = scheme.match(text).hasMatch();
  if (!hasScheme) text = QStringLiteral("https://") + text.remove(leadingSlashes);
  const QUrl url(text);
  const QString protocol = url.scheme().toLower();
  if (!url.isValid() || url.host().isEmpty() || (protocol != QLatin1String("http") && protocol != QLatin1String("https"))) {
    return std::nullopt;
  }
  Link link;
  link.token = QUrlQuery(url.fragment(QUrl::FullyEncoded)).queryItemValue(QStringLiteral("token"), QUrl::FullyDecoded).trimmed();
  if (link.token.isEmpty()) {
    link.token = QUrlQuery(url.query(QUrl::FullyEncoded)).queryItemValue(QStringLiteral("token"), QUrl::FullyDecoded).trimmed();
  }
  if (link.token.isEmpty()) return std::nullopt;
  for (const QString& candidate : hasScheme ? QStringList{protocol} : QStringList{QStringLiteral("https"), QStringLiteral("http")}) {
    QUrl origin;
    origin.setScheme(candidate);
    origin.setHost(url.host());
    origin.setPort(url.port());
    link.origins.append(origin);
  }
  return link;
}

std::optional<Invitation> readInvitation(const QString& received) {
  // A QR code holds under 3000 characters, and a pairing link a fraction of that.
  constexpr qsizetype kLongest = 2048;
  QString text = received.trimmed();
  if (text.isEmpty() || text.size() > kLongest) return std::nullopt;
  QUrl url(text);
  if (url.scheme() == QLatin1String("hal-c2")) {
    const QString path = url.path();
    if (url.host().compare(QLatin1String("pair"), Qt::CaseInsensitive) != 0 || !url.userInfo().isEmpty() || url.port() != -1 ||
        (!path.isEmpty() && path != QLatin1String("/"))) {
      return std::nullopt;
    }
    // Two of them is one for the user to read and one to be used.
    const QStringList carried = QUrlQuery(url.query(QUrl::FullyEncoded)).allQueryItemValues(QStringLiteral("pairingUrl"), QUrl::FullyDecoded);
    if (carried.size() != 1) return std::nullopt;
    text = carried.first().trimmed();
    url = QUrl(text);
  }
  const QString scheme = url.scheme();
  if (!url.isValid() || (scheme != QLatin1String("http") && scheme != QLatin1String("https")) || url.host().isEmpty() || !url.userInfo().isEmpty()) {
    return std::nullopt;
  }
  // With its scheme written, the link has the one origin readLink gives it.
  const auto link = readLink(text);
  if (!link) return std::nullopt;
  return Invitation{text, link->origins.first().toString(QUrl::FullyEncoded)};
}

void exchange(QNetworkAccessManager* http, QObject* context, const Link& link, const Client& client,
              std::function<void(const Result&)> done) {
  describe(std::make_shared<Attempt>(Attempt{http, context, link, client, std::move(done)}), 0);
}

}  // namespace pairing
