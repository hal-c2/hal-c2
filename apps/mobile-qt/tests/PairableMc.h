#pragma once

// The MCs the phone's tests pair with (tst_Pairing, and the scenarios'
// World): the desktop harness's fake MC with the HTTP side of pairing, and
// the addresses a link can name beside it.

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QRegularExpression>
#include <QString>
#include <QStringList>
#include <QTcpServer>
#include <QTcpSocket>
#include <QUrl>
#include <QUrlQuery>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"

namespace pairable {

inline void answer(QTcpSocket* socket, int status, const QByteArray& body, const QByteArray& type = "application/json") {
  socket->readAll();
  socket->write("HTTP/1.1 " + QByteArray::number(status) + (status < 300 ? " OK" : " Refused") + "\r\nContent-Type: " + type +
                "\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
  socket->disconnectFromHost();
}

inline QByteArray json(const QJsonObject& object) {
  return QJsonDocument(object).toJson(QJsonDocument::Compact);
}

// An MC a device can pair with: the fake MC's socket and rows, and the HTTP
// side of pairing as apps/server-ex router.ex answers it.
class PairableMc {
public:
  PairableMc(const QString& name, const QString& label) {
    mc.name = QStringLiteral("mc-") + name;
    mc.environmentId = QStringLiteral("env-") + name;
    mc.label = label;
    mc.projects.insert(QStringLiteral("p-") + name, {{QStringLiteral("id"), QStringLiteral("p-") + name},
                                                     {QStringLiteral("title"), QStringLiteral("project of ") + name},
                                                     {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + name},
                                                     {QStringLiteral("scripts"), QJsonArray()},
                                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                     {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
    mc.threads.insert(QStringLiteral("t-") + name, {{QStringLiteral("id"), QStringLiteral("t-") + name},
                                                    {QStringLiteral("title"), threadTitle()},
                                                    {QStringLiteral("projectId"), QStringLiteral("p-") + name},
                                                    {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T08:00:00Z")},
                                                    {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T08:00:00Z")}});
    mc.onRaw(QStringLiteral("/.well-known/hal-c2/environment"), [this](QTcpSocket* socket, const QByteArray&) {
      if (!isMc) return answer(socket, 404, "<html>Not found</html>", "text/html");
      answer(socket, 200,
             json({{QStringLiteral("environmentId"), mc.environmentId},
                   {QStringLiteral("label"), mc.label},
                   {QStringLiteral("orchestrationProtocolVersion"), protocol},
                   {QStringLiteral("mc"), mc.name}}));
    });
    mc.onRaw(QStringLiteral("/oauth/token"), [this](QTcpSocket* socket, const QByteArray& head) {
      static const QRegularExpression contentLength(QStringLiteral("content-length: *(\\d+)"), QRegularExpression::CaseInsensitiveOption);
      const qsizetype length = contentLength.match(QString::fromUtf8(head)).captured(1).toLongLong();
      auto done = std::make_shared<bool>(false);
      // The form may come after its headers.
      const auto exchange = [this, socket, head, length, done] {
        const QByteArray request = socket->peek(socket->bytesAvailable());
        if (*done || request.size() < head.size() + length) return;
        *done = true;
        const QUrlQuery form(QString::fromUtf8(request.mid(head.size(), length)));
        exchanges.append(form);
        // A pairing token buys one session.
        if (!pairingTokens.removeOne(form.queryItemValue(QStringLiteral("subject_token"), QUrl::FullyDecoded))) {
          return answer(socket, 400, json({{QStringLiteral("error"), QStringLiteral("invalid_grant")}}));
        }
        sessions.append(QStringLiteral("session-%1-%2").arg(mc.environmentId).arg(exchanges.size()));
        answer(socket, 200, json({{QStringLiteral("access_token"), sessions.last()}, {QStringLiteral("token_type"), QStringLiteral("Bearer")}}));
      };
      QObject::connect(socket, &QTcpSocket::readyRead, socket, exchange);
      exchange();
    });
    // A session's token does not open the socket itself: it buys a ticket, while the MC still knows it.
    mc.onRaw(QStringLiteral("/ws?token="), [](QTcpSocket* socket, const QByteArray&) { answer(socket, 401, "unauthorized", "text/plain"); });
    mc.onRaw(QStringLiteral("/api/auth/websocket-ticket"), [this](QTcpSocket* socket, const QByteArray& head) {
      static const QRegularExpression bearer(QStringLiteral("authorization: Bearer ([^\\r\\n]+)"), QRegularExpression::CaseInsensitiveOption);
      if (!sessions.contains(bearer.match(QString::fromUtf8(head)).captured(1))) {
        return answer(socket, 401, json({{QStringLiteral("_tag"), QStringLiteral("EnvironmentAuthInvalidError")}}));
      }
      tickets.append(QStringLiteral("ticket-%1").arg(tickets.size() + 1));
      answer(socket, 200, json({{QStringLiteral("ticket"), tickets.last()}}));
    });
  }

  QString threadTitle() const { return QStringLiteral("thread of ") + mc.environmentId; }
  // A fresh pairing link, as `mix hal_c2.pair` prints it.
  QString link() {
    pairingTokens.append(QStringLiteral("pair-%1-%2").arg(mc.environmentId).arg(++m_links));
    return mc.origin().toString() + QStringLiteral("/?token=") + pairingTokens.last();
  }
  // The MC signs a device out: its session buys nothing more and its socket closes.
  void revoke(const QString& session) {
    sessions.removeAll(session);
    mc.drop();
  }
  // Whether the socket open now came with a ticket this MC sold.
  bool connectedWithTicket() const {
    return !mc.connections.isEmpty() && tickets.contains(QUrlQuery(mc.connections.last()).queryItemValue(QStringLiteral("wsTicket")));
  }

  FakeMc mc;
  int protocol = McClient::kProtocol;
  // false: some other web server answers at this address
  bool isMc = true;
  QStringList pairingTokens;
  QStringList sessions;
  QStringList tickets;
  // Every form `/oauth/token` was sent.
  QList<QUrlQuery> exchanges;

private:
  int m_links = 0;
};

// The MC's plain-HTTP listener as a device on its network meets it: a TLS
// handshake is turned away at once (the fake MC alone would leave it waiting
// for a request), and everything else is the MC's.
class PlainListener : public QTcpServer {
public:
  explicit PlainListener(const QUrl& mc) {
    if (!listen(QHostAddress::LocalHost)) qFatal("cannot listen");
    connect(this, &QTcpServer::newConnection, this, [this, mc] {
      while (QTcpSocket* in = nextPendingConnection()) {
        auto* out = new QTcpSocket(in);
        connect(in, &QTcpSocket::readyRead, in, [in, out, mc] {
          if (out->state() == QAbstractSocket::UnconnectedState) {
            if (in->peek(1) == QByteArray(1, '\x16')) return in->abort();
            out->connectToHost(mc.host(), mc.port());
          }
          out->write(in->readAll());
        });
        connect(out, &QTcpSocket::readyRead, in, [in, out] { in->write(out->readAll()); });
        connect(out, &QTcpSocket::disconnected, in, &QTcpSocket::disconnectFromHost);
        connect(in, &QTcpSocket::disconnected, in, &QObject::deleteLater);
      }
    });
  }
  QString address() const { return QStringLiteral("127.0.0.1:%1").arg(serverPort()); }
};

// An address nothing answers at.
inline QString deadAddress() {
  QTcpServer server;
  server.listen(QHostAddress::LocalHost);
  const QString address = QStringLiteral("127.0.0.1:%1").arg(server.serverPort());
  server.close();
  return address;
}

}  // namespace pairable

using pairable::deadAddress;
using pairable::PairableMc;
using pairable::PlainListener;
