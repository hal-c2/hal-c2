#include "McClient.h"

#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrlQuery>
#include <QUuid>
#include <QWebSocket>

McClient::McClient(QObject* parent) : QObject(parent) {
  m_retryTimer.setSingleShot(true);
  connect(&m_retryTimer, &QTimer::timeout, this, &McClient::connectSocket);
  m_pingTimer.setInterval(25000);
  connect(&m_pingTimer, &QTimer::timeout, this, [this] { send({{QStringLiteral("t"), QStringLiteral("ping")}}); });
}

McClient::~McClient() {
  close();
}

void McClient::open(const QUrl& origin, const QString& token) {
  QUrl url = origin;
  url.setScheme(origin.scheme() == QLatin1String("https") ? QStringLiteral("wss") : QStringLiteral("ws"));
  url.setPath(QStringLiteral("/ws"));
  QUrlQuery query;
  query.addQueryItem(QStringLiteral("token"), token);
  url.setQuery(query);
  m_origin = origin;
  m_url = url;
  m_token = token;
  m_closed = false;
  m_attempt = 0;
  connectSocket();
}

void McClient::close() {
  m_closed = true;
  m_retryTimer.stop();
  if (m_socket) {
    QWebSocket* socket = m_socket;
    m_socket = nullptr;
    socket->disconnect(this);
    socket->abort();
    socket->deleteLater();
  }
  if (m_ready) {
    m_ready = false;
    m_pingTimer.stop();
    emit readyChanged(false);
  }
}

int McClient::subscribe(QObject* context, const QJsonObject& shape, FrameHandler onFrame) {
  const int id = m_nextId++;
  const auto gone = connect(context, &QObject::destroyed, this, [this, id] { unsubscribe(id); });
  m_subscriptions.insert(id, {shape, std::move(onFrame), gone});
  sendSub(id);
  return id;
}

void McClient::unsubscribe(int id) {
  if (!m_subscriptions.contains(id)) return;
  endSubscription(id);
  send({{QStringLiteral("t"), QStringLiteral("unsub")}, {QStringLiteral("id"), id}});
}

void McClient::endSubscription(int id) {
  disconnect(m_subscriptions.take(id).contextGone);
}

void McClient::call(QObject* context, const QString& environment, const QString& method, const QJsonValue& payload,
                      Reply reply) {
  if (!m_ready) {
    // Replies are never synchronous, so callers see one order either way.
    QTimer::singleShot(0, context, [reply = std::move(reply)] {
      reply(QJsonValue(), QStringLiteral("not connected"));
    });
    return;
  }
  const int id = m_nextId++;
  m_calls.insert(id, {context, std::move(reply)});
  send({
      {QStringLiteral("t"), QStringLiteral("rpc")},
      {QStringLiteral("id"), id},
      {QStringLiteral("environment"), environment},
      {QStringLiteral("method"), method},
      {QStringLiteral("payload"), payload},
  });
}

void McClient::post(QObject* context, const QString& path, const QJsonObject& body, Reply reply) {
  if (m_closed || !m_origin.isValid()) {
    QTimer::singleShot(0, context, [reply = std::move(reply)] { reply(QJsonValue(), QStringLiteral("not connected")); });
    return;
  }
  if (!m_http) m_http = new QNetworkAccessManager(this);
  QUrl url = m_origin;
  url.setPath(path);
  QNetworkRequest request(url);
  request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
  request.setRawHeader("Authorization", "Bearer " + m_token.toUtf8());
  QNetworkReply* answer = m_http->post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
  connect(answer, &QNetworkReply::finished, this, [answer, context = QPointer<QObject>(context), reply = std::move(reply)] {
    answer->deleteLater();
    if (!context) return;
    const int status = answer->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QJsonDocument document = QJsonDocument::fromJson(answer->readAll());
    const QJsonValue result = document.isObject() ? QJsonValue(document.object()) : QJsonValue();
    if (status >= 200 && status < 300) {
      reply(result, std::nullopt);
      return;
    }
    const QJsonObject refusal = document.object();
    QString error = refusal.value(QLatin1String("message")).toString();
    if (error.isEmpty()) error = refusal.value(QLatin1String("detail")).toString();
    if (error.isEmpty()) error = refusal.value(QLatin1String("_tag")).toString();
    if (error.isEmpty()) error = status > 0 ? QStringLiteral("HTTP %1").arg(status) : answer->errorString();
    reply(result, error);
  });
}

QNetworkRequest McClient::request(const QString& path, const QString& query, bool socket) const {
  QUrl url = m_origin;
  if (socket) url.setScheme(m_origin.scheme() == QLatin1String("https") ? QStringLiteral("wss") : QStringLiteral("ws"));
  // Already encoded: an MC's hubBasePath carries `mcs/<name%40host>`.
  url.setPath(path, QUrl::TolerantMode);
  url.setQuery(query);
  QNetworkRequest request(url);
  request.setRawHeader("Authorization", "Bearer " + m_token.toUtf8());
  return request;
}

void McClient::dispatchCommand(QObject* context, const QString& environment, QJsonObject command, Reply reply) {
  command.insert(QStringLiteral("commandId"), QUuid::createUuid().toString(QUuid::WithoutBraces));
  call(context, environment, QStringLiteral("orchestration.dispatchCommand"), command, std::move(reply));
}

void McClient::connectSocket() {
  if (m_closed) return;
  auto* socket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
  m_socket = socket;
  connect(socket, &QWebSocket::textMessageReceived, this, &McClient::onMessage);
  connect(socket, &QWebSocket::disconnected, this, [this, socket] { onClosed(socket); });
  connect(socket, &QWebSocket::errorOccurred, this, [this, socket] { onClosed(socket); });
  socket->open(m_url);
}

void McClient::onMessage(const QString& text) {
  const QJsonObject frame = QJsonDocument::fromJson(text.toUtf8()).object();
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("hello")) {
    m_ready = true;
    m_attempt = 0;
    m_mc = frame.value(QLatin1String("mc")).toString();
    m_environment = frame.value(QLatin1String("environment")).toString();
    m_pingTimer.start();
    for (auto it = m_subscriptions.cbegin(); it != m_subscriptions.cend(); ++it) sendSub(it.key());
    emit readyChanged(true);
    return;
  }
  if (type == QLatin1String("pong")) return;
  const QJsonValue idValue = frame.value(QLatin1String("id"));
  if (!idValue.isDouble()) return;
  const int id = idValue.toInt();
  if (type == QLatin1String("rpc.result") || type == QLatin1String("rpc.error")) {
    const Call call = m_calls.take(id);
    // Its context is gone, and whatever the reply would have touched with it.
    if (!call.context || !call.reply) return;
    const Reply& reply = call.reply;
    if (type == QLatin1String("rpc.result")) {
      reply(frame.value(QLatin1String("result")), std::nullopt);
    } else {
      reply(frame.value(QLatin1String("detail")), frame.value(QLatin1String("error")).toVariant().toString());
    }
    return;
  }
  const auto subscription = m_subscriptions.constFind(id);
  if (subscription == m_subscriptions.constEnd()) return;
  if (type == QLatin1String("resync")) {
    sendSub(id);
    return;
  }
  const FrameHandler handler = subscription->onFrame;
  // The MC ended the shape and already forgot it.
  if (type == QLatin1String("end")) endSubscription(id);
  handler(frame);
}

void McClient::onClosed(QWebSocket* socket) {
  if (socket != m_socket) return;
  m_socket = nullptr;
  socket->disconnect(this);
  socket->deleteLater();
  const bool wasReady = m_ready;
  m_ready = false;
  m_pingTimer.stop();
  const auto calls = std::exchange(m_calls, {});
  for (const Call& call : calls) {
    if (call.context && call.reply) call.reply(QJsonValue(), QStringLiteral("disconnected"));
  }
  if (wasReady) emit readyChanged(false);
  if (m_closed) return;
  const int delay = m_retryDelaysMs.isEmpty()
                        ? 8000
                        : m_retryDelaysMs.at(std::min<qsizetype>(m_attempt, m_retryDelaysMs.size() - 1));
  m_attempt++;
  m_retryTimer.start(delay);
}

void McClient::sendSub(int id) {
  const auto subscription = m_subscriptions.constFind(id);
  if (subscription == m_subscriptions.constEnd() || !m_ready) return;
  send({
      {QStringLiteral("t"), QStringLiteral("sub")},
      {QStringLiteral("id"), id},
      {QStringLiteral("shape"), subscription->shape},
      {QStringLiteral("offset"), QJsonValue::Null},
  });
}

void McClient::send(const QJsonObject& message) {
  if (m_socket && m_socket->state() == QAbstractSocket::ConnectedState) {
    m_socket->sendTextMessage(QString::fromUtf8(QJsonDocument(message).toJson(QJsonDocument::Compact)));
  }
}
