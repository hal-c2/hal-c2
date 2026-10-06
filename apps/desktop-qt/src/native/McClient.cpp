#include "McClient.h"

#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrlQuery>
#include <QUuid>
#include <QWebSocket>

namespace {

// A fresh W3C trace id: 32 hex digits.
QString newTraceId() {
  return QUuid::createUuid().toString(QUuid::Id128);
}

}  // namespace

McClient::McClient(QObject* parent) : QObject(parent) {
  m_retryTimer.setSingleShot(true);
  connect(&m_retryTimer, &QTimer::timeout, this, &McClient::connectSocket);
  m_pingTimer.setInterval(25000);
  connect(&m_pingTimer, &QTimer::timeout, this, &McClient::ping);
  m_pongTimer.setSingleShot(true);
  m_pongTimer.setInterval(10000);
  connect(&m_pongTimer, &QTimer::timeout, this, [this] {
    emit checked(false);
    drop(QStringLiteral("timeout"));
  });
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
  m_failure.clear();
  m_failureTraceId.clear();
  m_blockedProtocol = 0;
  m_ticketed = false;
  connectSocket();
}

void McClient::close() {
  m_closed = true;
  ++m_generation;
  m_retryTimer.stop();
  m_pongTimer.stop();
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
  setPhase(Phase::Closed);
}

void McClient::setPhase(Phase phase) {
  if (phase == m_phase) return;
  m_phase = phase;
  emit phaseChanged();
}

void McClient::setOnline(bool online) {
  if (online == m_online) return;
  m_online = online;
  if (m_closed) return;
  if (online) {
    if (m_phase == Phase::Offline) retryNow();
  } else if (m_phase == Phase::Retrying) {
    // The retry would only fail: wait for the network instead.
    m_retryTimer.stop();
    setPhase(Phase::Offline);
  }
}

void McClient::wake() {
  if (m_closed) return;
  if (m_phase == Phase::Retrying) {
    retryNow();
  } else if (m_ready) {
    ping();
  }
}

void McClient::retryNow() {
  if (m_closed || m_ready || m_phase == Phase::Connecting) return;
  m_retryTimer.stop();
  m_attempt = 0;
  connectSocket();
}

// One ping at a time: the pong (or any frame) must come before the timeout.
void McClient::ping() {
  if (!m_ready) return;
  send({{QStringLiteral("t"), QStringLiteral("ping")}});
  if (!m_pongTimer.isActive()) m_pongTimer.start();
}

// Gives up on a socket that stopped answering; it is retried like any drop.
void McClient::drop(const QString& reason) {
  if (!m_socket) return;
  m_dropReason = reason;
  QWebSocket* socket = m_socket;
  socket->abort();
  // abort() may not report the close itself.
  onClosed(socket);
}

int McClient::subscribe(QObject* context, const QJsonObject& shape, FrameHandler onFrame, Resume resume) {
  const int id = m_nextId++;
  const auto gone = connect(context, &QObject::destroyed, this, [this, id] { unsubscribe(id); });
  m_subscriptions.insert(id, {shape, std::move(onFrame), gone, std::move(resume)});
  sendSub(id);
  return id;
}

void McClient::more(int id, int items) {
  if (!m_subscriptions.contains(id)) return;
  send({{QStringLiteral("t"), QStringLiteral("more")}, {QStringLiteral("id"), id}, {QStringLiteral("items"), items}});
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

void McClient::upload(QObject* context, const QString& relativeUrl, const QByteArray& bytes, const QString& mimeType, Reply reply) {
  if (m_closed || !m_origin.isValid()) {
    QTimer::singleShot(0, context, [reply = std::move(reply)] { reply(QJsonValue(), QStringLiteral("not connected")); });
    return;
  }
  if (!m_http) m_http = new QNetworkAccessManager(this);
  QUrl url = m_origin;
  url.setPath(relativeUrl, QUrl::TolerantMode);
  QNetworkRequest request(url);
  request.setHeader(QNetworkRequest::ContentTypeHeader, mimeType.isEmpty() ? QStringLiteral("application/octet-stream") : mimeType);
  QNetworkReply* answer = m_http->post(request, bytes);
  connect(answer, &QNetworkReply::finished, this, [answer, context = QPointer<QObject>(context), reply = std::move(reply)] {
    answer->deleteLater();
    if (!context) return;
    const int status = answer->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status >= 200 && status < 300) {
      reply(QJsonValue(), std::nullopt);
      return;
    }
    // The MC answers a refused upload in plain words.
    const QJsonDocument document = QJsonDocument::fromJson(answer->peek(4096));
    QString error = document.object().value(QLatin1String("message")).toString();
    if (error.isEmpty() && !document.isObject()) error = QString::fromUtf8(answer->readAll()).trimmed();
    if (error.isEmpty()) error = status > 0 ? QStringLiteral("HTTP %1").arg(status) : answer->errorString();
    reply(QJsonValue(), error);
  });
}

void McClient::download(QObject* context, const QString& relativeUrl, Bytes reply) {
  if (m_closed || !m_origin.isValid()) {
    QTimer::singleShot(0, context, [reply = std::move(reply)] { reply({}, QStringLiteral("not connected")); });
    return;
  }
  if (!m_http) m_http = new QNetworkAccessManager(this);
  // The URL carries its own query (the signature).
  const QUrl url = m_origin.resolved(QUrl(relativeUrl));
  QNetworkReply* answer = m_http->get(QNetworkRequest(url));
  connect(answer, &QNetworkReply::finished, this, [answer, context = QPointer<QObject>(context), reply = std::move(reply)] {
    answer->deleteLater();
    if (!context) return;
    const int status = answer->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status >= 200 && status < 300) {
      reply(answer->readAll(), std::nullopt);
      return;
    }
    reply({}, status > 0 ? QStringLiteral("HTTP %1").arg(status) : answer->errorString());
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

// One attempt: the MC's descriptor first, which says whether its protocol is
// one this client speaks, then the socket.
void McClient::connectSocket() {
  if (m_closed) return;
  if (!m_online) {
    setPhase(Phase::Offline);
    return;
  }
  const quint64 generation = ++m_generation;
  m_traceId = newTraceId();
  m_dropReason.clear();
  m_retryDelay = 0;
  setPhase(Phase::Connecting);
  if (!m_http) m_http = new QNetworkAccessManager(this);
  QNetworkRequest descriptor = request(QStringLiteral("/.well-known/hal-c2/environment"));
  descriptor.setTransferTimeout(5000);
  QNetworkReply* answer = m_http->get(descriptor);
  connect(answer, &QNetworkReply::finished, this, [this, answer, generation] {
    answer->deleteLater();
    if (generation != m_generation || m_closed) return;
    const QJsonDocument document = QJsonDocument::fromJson(answer->readAll());
    if (document.isObject()) {
      m_descriptor = document.object();
      const QJsonValue protocol = m_descriptor.value(QLatin1String("orchestrationProtocolVersion"));
      if (protocol.isDouble() && protocol.toInt() != kProtocol) {
        // Retrying cannot help: one side has to be updated.
        m_blockedProtocol = protocol.toInt();
        m_failureTraceId = m_traceId;
        setPhase(Phase::Blocked);
        return;
      }
    }
    // Nobody there: the socket would only fail the same way.
    const QNetworkReply::NetworkError error = answer->error();
    if (error == QNetworkReply::ConnectionRefusedError || error == QNetworkReply::HostNotFoundError ||
        error == QNetworkReply::TimeoutError || error == QNetworkReply::OperationCanceledError) {
      const bool timedOut = error == QNetworkReply::TimeoutError || error == QNetworkReply::OperationCanceledError;
      m_failure = timedOut ? QStringLiteral("timeout") : answer->errorString();
      m_failureTraceId = m_traceId;
      scheduleRetry();
      return;
    }
    // An MC that does not describe itself is left to the socket to refuse.
    if (m_ticketed) {
      openWithTicket();
    } else {
      openSocket();
    }
  });
}

void McClient::openWithTicket() {
  const quint64 generation = m_generation;
  QNetworkRequest ticket = request(QStringLiteral("/api/auth/websocket-ticket"));
  ticket.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
  ticket.setTransferTimeout(5000);
  QNetworkReply* answer = m_http->post(ticket, QByteArrayLiteral("{}"));
  connect(answer, &QNetworkReply::finished, this, [this, answer, generation] {
    answer->deleteLater();
    if (generation != m_generation || m_closed) return;
    const int status = answer->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QString issued = QJsonDocument::fromJson(answer->readAll()).object().value(QLatin1String("ticket")).toString();
    if (status == 401) {
      // The MC no longer knows this credential: no retry mends that.
      setPhase(Phase::Refused);
    } else if (status == 200 && !issued.isEmpty()) {
      m_ticketed = true;
      openSocket(issued);
    } else {
      scheduleRetry();
    }
  });
}

void McClient::openSocket(const QString& ticket) {
  auto* socket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
  m_socket = socket;
  connect(socket, &QWebSocket::textMessageReceived, this, &McClient::onMessage);
  connect(socket, &QWebSocket::disconnected, this, [this, socket] { onClosed(socket); });
  connect(socket, &QWebSocket::errorOccurred, this, [this, socket] { onClosed(socket); });
  QUrl url = m_url;
  if (!ticket.isEmpty()) {
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("wsTicket"), ticket);
    url.setQuery(query);
  }
  QNetworkRequest handshake(url);
  handshake.setRawHeader("traceparent", QStringLiteral("00-%1-%2-01").arg(m_traceId, m_traceId.left(16)).toLatin1());
  socket->open(handshake);
}

void McClient::onMessage(const QString& text) {
  const QJsonObject frame = QJsonDocument::fromJson(text.toUtf8()).object();
  const QString type = frame.value(QLatin1String("t")).toString();
  // Whatever it says, the MC is answering.
  if (m_pongTimer.isActive()) {
    m_pongTimer.stop();
    emit checked(true);
  }
  if (type == QLatin1String("hello")) {
    m_ready = true;
    m_attempt = 0;
    m_failure.clear();
    m_failureTraceId.clear();
    m_mc = frame.value(QLatin1String("mc")).toString();
    m_environment = frame.value(QLatin1String("environment")).toString();
    m_pingTimer.start();
    for (auto it = m_subscriptions.cbegin(); it != m_subscriptions.cend(); ++it) sendSub(it.key());
    setPhase(Phase::Ready);
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
  const FrameHandler handler = subscription->onFrame;
  if (type == QLatin1String("resync")) {
    // Fell behind, and the MC dropped the shape: its owner takes the offset
    // the MC names, and it is asked for again from there.
    handler(frame);
    sendSub(id);
    return;
  }
  // The MC ended the shape and already forgot it.
  if (type == QLatin1String("end")) endSubscription(id);
  handler(frame);
}

void McClient::onClosed(QWebSocket* socket) {
  if (socket != m_socket) return;
  m_socket = nullptr;
  // The MC's own close code and words, before the socket goes.
  const bool revoked = socket->closeCode() == 4401;
  QString reason = std::exchange(m_dropReason, {});
  if (reason.isEmpty() && socket->error() == QAbstractSocket::SocketTimeoutError) reason = QStringLiteral("timeout");
  if (reason.isEmpty()) reason = socket->closeReason();
  if (reason.isEmpty() && socket->error() != QAbstractSocket::UnknownSocketError) reason = socket->errorString();
  if (reason.isEmpty()) reason = QStringLiteral("closed");
  socket->disconnect(this);
  socket->deleteLater();
  const bool wasReady = m_ready;
  m_ready = false;
  m_pingTimer.stop();
  m_pongTimer.stop();
  const auto calls = std::exchange(m_calls, {});
  for (const Call& call : calls) {
    if (call.context && call.reply) call.reply(QJsonValue(), QStringLiteral("disconnected"));
  }
  if (wasReady) emit readyChanged(false);
  if (m_closed) return;
  m_failure = reason;
  m_failureTraceId = m_traceId;
  if (revoked) {
    setPhase(Phase::Refused);
    return;
  }
  failed(reason, wasReady);
}

// A socket that never got its hello may have been turned away for its
// credential. With the bare token that is either a paired session's token,
// which needs a ticket, or one the MC refuses: asking for a ticket tells which.
// A ticketed socket that failed is retried like any other.
void McClient::failed(const QString& reason, bool wasReady) {
  Q_UNUSED(reason);
  if (wasReady || m_ticketed) {
    scheduleRetry();
    return;
  }
  openWithTicket();
}

void McClient::scheduleRetry() {
  if (!m_online) {
    setPhase(Phase::Offline);
    return;
  }
  m_retryDelay = m_retryDelaysMs.isEmpty()
                     ? 8000
                     : m_retryDelaysMs.at(std::min<qsizetype>(m_attempt, m_retryDelaysMs.size() - 1));
  m_attempt++;
  m_retryTimer.start(m_retryDelay);
  // Retrying again says so again: the delay changed.
  if (m_phase == Phase::Retrying) {
    emit phaseChanged();
  } else {
    setPhase(Phase::Retrying);
  }
}

void McClient::sendSub(int id) {
  const auto subscription = m_subscriptions.constFind(id);
  if (subscription == m_subscriptions.constEnd() || !m_ready) return;
  QJsonObject frame{
      {QStringLiteral("t"), QStringLiteral("sub")},
      {QStringLiteral("id"), id},
      {QStringLiteral("shape"), subscription->shape},
      {QStringLiteral("offset"), QJsonValue::Null},
  };
  if (subscription->resume) {
    const QJsonObject resume = subscription->resume();
    for (auto it = resume.begin(); it != resume.end(); ++it) frame.insert(it.key(), it.value());
  }
  send(frame);
}

void McClient::send(const QJsonObject& message) {
  if (m_socket && m_socket->state() == QAbstractSocket::ConnectedState) {
    m_socket->sendTextMessage(QString::fromUtf8(QJsonDocument(message).toJson(QJsonDocument::Compact)));
  }
}
