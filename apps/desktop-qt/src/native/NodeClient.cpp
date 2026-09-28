#include "NodeClient.h"

#include <QJsonDocument>
#include <QUrlQuery>
#include <QUuid>
#include <QWebSocket>

NodeClient::NodeClient(QObject* parent) : QObject(parent) {
  m_retryTimer.setSingleShot(true);
  connect(&m_retryTimer, &QTimer::timeout, this, &NodeClient::connectSocket);
  m_pingTimer.setInterval(25000);
  connect(&m_pingTimer, &QTimer::timeout, this, [this] { send({{QStringLiteral("t"), QStringLiteral("ping")}}); });
}

NodeClient::~NodeClient() {
  close();
}

void NodeClient::open(const QUrl& origin, const QString& token) {
  QUrl url = origin;
  url.setScheme(origin.scheme() == QLatin1String("https") ? QStringLiteral("wss") : QStringLiteral("ws"));
  url.setPath(QStringLiteral("/ws"));
  QUrlQuery query;
  query.addQueryItem(QStringLiteral("token"), token);
  url.setQuery(query);
  m_origin = origin;
  m_url = url;
  m_closed = false;
  m_attempt = 0;
  connectSocket();
}

void NodeClient::close() {
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

int NodeClient::subscribe(const QJsonObject& shape, FrameHandler onFrame) {
  const int id = m_nextId++;
  m_subscriptions.insert(id, {shape, std::move(onFrame)});
  sendSub(id);
  return id;
}

void NodeClient::unsubscribe(int id) {
  if (m_subscriptions.remove(id) > 0) {
    send({{QStringLiteral("t"), QStringLiteral("unsub")}, {QStringLiteral("id"), id}});
  }
}

void NodeClient::call(const QString& environment, const QString& method, const QJsonValue& payload,
                      Reply reply) {
  if (!m_ready) {
    // Replies are never synchronous, so callers see one order either way.
    QTimer::singleShot(0, this, [reply = std::move(reply)] {
      reply(QJsonValue(), QStringLiteral("not connected"));
    });
    return;
  }
  const int id = m_nextId++;
  m_calls.insert(id, std::move(reply));
  send({
      {QStringLiteral("t"), QStringLiteral("rpc")},
      {QStringLiteral("id"), id},
      {QStringLiteral("environment"), environment},
      {QStringLiteral("method"), method},
      {QStringLiteral("payload"), payload},
  });
}

void NodeClient::dispatchCommand(const QString& environment, QJsonObject command, Reply reply) {
  command.insert(QStringLiteral("commandId"), QUuid::createUuid().toString(QUuid::WithoutBraces));
  call(environment, QStringLiteral("orchestration.dispatchCommand"), command, std::move(reply));
}

void NodeClient::connectSocket() {
  if (m_closed) return;
  auto* socket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
  m_socket = socket;
  connect(socket, &QWebSocket::textMessageReceived, this, &NodeClient::onMessage);
  connect(socket, &QWebSocket::disconnected, this, [this, socket] { onClosed(socket); });
  connect(socket, &QWebSocket::errorOccurred, this, [this, socket] { onClosed(socket); });
  socket->open(m_url);
}

void NodeClient::onMessage(const QString& text) {
  const QJsonObject frame = QJsonDocument::fromJson(text.toUtf8()).object();
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("hello")) {
    m_ready = true;
    m_attempt = 0;
    m_node = frame.value(QLatin1String("node")).toString();
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
    const Reply reply = m_calls.take(id);
    if (!reply) return;
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
  // The node ended the shape and already forgot it.
  if (type == QLatin1String("end")) m_subscriptions.remove(id);
  handler(frame);
}

void NodeClient::onClosed(QWebSocket* socket) {
  if (socket != m_socket) return;
  m_socket = nullptr;
  socket->disconnect(this);
  socket->deleteLater();
  const bool wasReady = m_ready;
  m_ready = false;
  m_pingTimer.stop();
  const auto calls = std::exchange(m_calls, {});
  for (const Reply& reply : calls) reply(QJsonValue(), QStringLiteral("disconnected"));
  if (wasReady) emit readyChanged(false);
  if (m_closed) return;
  const int delay = m_retryDelaysMs.isEmpty()
                        ? 8000
                        : m_retryDelaysMs.at(std::min<qsizetype>(m_attempt, m_retryDelaysMs.size() - 1));
  m_attempt++;
  m_retryTimer.start(delay);
}

void NodeClient::sendSub(int id) {
  const auto subscription = m_subscriptions.constFind(id);
  if (subscription == m_subscriptions.constEnd() || !m_ready) return;
  send({
      {QStringLiteral("t"), QStringLiteral("sub")},
      {QStringLiteral("id"), id},
      {QStringLiteral("shape"), subscription->shape},
      {QStringLiteral("offset"), QJsonValue::Null},
  });
}

void NodeClient::send(const QJsonObject& message) {
  if (m_socket && m_socket->state() == QAbstractSocket::ConnectedState) {
    m_socket->sendTextMessage(QString::fromUtf8(QJsonDocument(message).toJson(QJsonDocument::Compact)));
  }
}
