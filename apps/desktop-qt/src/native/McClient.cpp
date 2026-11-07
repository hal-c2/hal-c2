#include "McClient.h"

#include <QJsonDocument>
#include <QLoggingCategory>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrlQuery>
#include <QUuid>
#include <QWebSocket>

#include <algorithm>

// The socket's lifecycle, one line per step, under the attempt's trace id: the MC
// logs its side under the same id (HalC2.Web.Socket).
Q_LOGGING_CATEGORY(lcMc, "hal_c2.mc")

namespace {

// A fresh W3C trace id: 32 hex digits.
QString newTraceId() {
  return QUuid::createUuid().toString(QUuid::Id128);
}

// What every request of one attempt carries, so the MC's log names it.
void trace(QNetworkRequest& request, const QString& traceId) {
  request.setRawHeader("traceparent", QStringLiteral("00-%1-%2-01").arg(traceId, traceId.left(16)).toLatin1());
}

}  // namespace

McClient::McClient(QObject* parent) : QObject(parent) {
  m_retryTimer.setSingleShot(true);
  connect(&m_retryTimer, &QTimer::timeout, this, &McClient::connectSocket);
  m_pingTimer.setInterval(25000);
  connect(&m_pingTimer, &QTimer::timeout, this, &McClient::ping);
  m_pongTimer.setSingleShot(true);
  // Past the 15 s (`remote_timeout`) an MC's socket may block on one call to a
  // cluster member before it reads the next ping: subscribing to a watched
  // shape, a config, a terminal, a preview host, a server update or a git
  // action still calls the member from the socket process (socket.ex
  // `subscribe/4`). Back to 10 s once those move off it (hal-c2#976).
  m_pongTimer.setInterval(20000);
  connect(&m_pongTimer, &QTimer::timeout, this, [this] {
    qCInfo(lcMc).noquote() << "no pong in" << m_pongTimer.interval() << "ms (trace" << m_traceId + ")";
    emit checked(false);
    drop(QStringLiteral("timeout"));
  });
  // A socket that opens but is never said hello to is as dead as one that drops.
  m_setupTimer.setSingleShot(true);
  m_setupTimer.setInterval(15000);
  connect(&m_setupTimer, &QTimer::timeout, this, [this] {
    qCInfo(lcMc).noquote() << "no hello in" << m_setupTimer.interval() << "ms (trace" << m_traceId + ")";
    drop(QStringLiteral("timeout"));
  });
  // Only a connection that held starts the retry delays over: one that drops as
  // soon as it is up is retried ever more slowly, not every half second.
  m_heldTimer.setSingleShot(true);
  m_heldTimer.setInterval(30000);
  connect(&m_heldTimer, &QTimer::timeout, this, [this] { m_attempt = 0; });
  // A foreground check (wake()) that goes unanswered replaces the connection at
  // once: one that died while the app was away is the likely case.
  m_probeTimer.setSingleShot(true);
  m_probeTimer.setInterval(15000);
  connect(&m_probeTimer, &QTimer::timeout, this, [this] {
    qCInfo(lcMc).noquote() << "no answer to the check in" << m_probeTimer.interval() << "ms (trace" << m_traceId + ")";
    emit checked(false);
    drop(QStringLiteral("check"));
  });
}

McClient::~McClient() {
  // Whoever is owed a reply is going too.
  m_calls.clear();
  close();
}

void McClient::open(const QUrl& origin, const QString& token, const QString& environment) {
  // Opened again (paired anew): the socket it had goes first, or both would feed it.
  if (!m_closed) close();
  QUrl url = origin;
  url.setScheme(origin.scheme() == QLatin1String("https") ? QStringLiteral("wss") : QStringLiteral("ws"));
  url.setPath(QStringLiteral("/ws"));
  QUrlQuery query;
  query.addQueryItem(QStringLiteral("token"), token);
  query.addQueryItem(QStringLiteral("protocol"), QString::number(kProtocol));
  url.setQuery(query);
  // Another MC: what the last one said of itself is not this one's, and
  // until it answers nothing names the one it left ("Connecting to …").
  if (origin != m_origin) {
    m_descriptor = {};
    m_mc.clear();
    m_environment.clear();
  }
  m_origin = origin;
  m_url = url;
  m_token = token;
  m_closed = false;
  m_attempt = 0;
  m_failure.clear();
  m_failureMessage.clear();
  m_failureTraceId.clear();
  m_blockedProtocol = 0;
  m_ticketed = false;
  m_expectedEnvironment = environment;
  connectSocket();
}

void McClient::close() {
  m_closed = true;
  ++m_generation;
  m_retryTimer.stop();
  m_pongTimer.stop();
  m_setupTimer.stop();
  m_heldTimer.stop();
  m_probeTimer.stop();
  if (m_socket) {
    QWebSocket* socket = m_socket;
    m_socket = nullptr;
    socket->disconnect(this);
    // What was sent last goes out first, as a farewell such as
    // `hal-c2.unregisterPush`; abort() would drop it.
    socket->flush();
    socket->abort();
    socket->deleteLater();
  }
  const bool wasReady = std::exchange(m_ready, false);
  m_pingTimer.stop();
  // The socket that carried them is gone: they are answered as by a drop.
  failCalls();
  if (wasReady) emit readyChanged(false);
  setPhase(Phase::Closed);
}

void McClient::failCalls() {
  const auto calls = std::exchange(m_calls, {});
  // In the order they were made, so a caller's later call fails after its earlier one.
  QList<int> ids = calls.keys();
  std::sort(ids.begin(), ids.end());
  for (int id : ids) {
    const Call call = calls.value(id);
    emit callEnded(id);
    // Not sent again: the MC may have carried it out.
    if (call.context && call.reply) call.reply(QJsonValue(), QStringLiteral("disconnected"));
  }
}

void McClient::setPhase(Phase phase) {
  if (phase == m_phase) return;
  if (phase == Phase::Offline) qCInfo(lcMc) << "offline: waiting for the network";
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
  if (m_phase == Phase::Retrying || m_phase == Phase::Refused || m_phase == Phase::Blocked) {
    retryNow();
  } else if (m_ready) {
    ping();
    m_probeTimer.start();
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

McClient* McClient::routed(const QString& environment, const QString& mc) const {
  if (!m_route || (environment.isEmpty() && mc.isEmpty())) return nullptr;
  McClient* other = m_route(environment, mc);
  return other == this ? nullptr : other;
}

int McClient::subscribe(QObject* context, const QJsonObject& shape, FrameHandler onFrame, Resume resume) {
  const QString environment = shape.contains(QLatin1String("environment")) ? shape.value(QLatin1String("environment")).toString()
                                                                         : shape.value(QLatin1String("environmentId")).toString();
  if (McClient* other = routed(environment, shape.value(QLatin1String("mc")).toString())) {
    const int id = m_nextId++;
    m_forwarded.insert(id, {other, other->subscribe(context, shape, std::move(onFrame), std::move(resume))});
    // Its id here goes once that subscription goes with its context.
    connect(context, &QObject::destroyed, this, [this, id] { m_forwarded.remove(id); });
    return id;
  }
  const int id = m_nextId++;
  const auto gone = connect(context, &QObject::destroyed, this, [this, id] { unsubscribe(id); });
  m_subscriptions.insert(id, {shape, std::move(onFrame), gone, std::move(resume)});
  sendSub(id);
  return id;
}

void McClient::more(int id, int items) {
  if (const auto forwarded = m_forwarded.value(id); forwarded.first) return forwarded.first->more(forwarded.second, items);
  if (!m_subscriptions.contains(id)) return;
  send({{QStringLiteral("t"), QStringLiteral("more")}, {QStringLiteral("id"), id}, {QStringLiteral("items"), items}});
}

void McClient::ack(int id, qint64 sequence) {
  if (const auto forwarded = m_forwarded.value(id); forwarded.first) return forwarded.first->ack(forwarded.second, sequence);
  if (!m_subscriptions.contains(id)) return;
  send({{QStringLiteral("t"), QStringLiteral("ack")}, {QStringLiteral("id"), id}, {QStringLiteral("sequence"), sequence}});
}

void McClient::unsubscribe(int id) {
  if (m_forwarded.contains(id)) {
    const auto forwarded = m_forwarded.take(id);
    if (forwarded.first) forwarded.first->unsubscribe(forwarded.second);
    return;
  }
  if (!m_subscriptions.contains(id)) return;
  endSubscription(id);
  send({{QStringLiteral("t"), QStringLiteral("unsub")}, {QStringLiteral("id"), id}});
}

void McClient::endSubscription(int id) {
  disconnect(m_subscriptions.take(id).contextGone);
}

void McClient::call(QObject* context, const QString& environment, const QString& method, const QJsonValue& payload,
                      Reply reply) {
  if (McClient* other = routed(environment, {})) return other->call(context, environment, method, payload, std::move(reply));
  if (!m_ready) {
    // Replies are never synchronous, so callers see one order either way.
    QTimer::singleShot(0, context, [reply = std::move(reply)] {
      reply(QJsonValue(), QStringLiteral("not connected"));
    });
    return;
  }
  const int id = m_nextId++;
  m_calls.insert(id, {context, std::move(reply), environment});
  emit callStarted(id, environment, method);
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
  if (!renewalDue()) return sendPost(context, path, body, std::move(reply));
  renew([this, context = QPointer<QObject>(context), path, body, reply = std::move(reply)](const std::optional<QString>& error) {
    if (!context) return;
    if (error) return reply(QJsonValue(), error);
    sendPost(context, path, body, reply);
  });
}

bool McClient::renewalDue() const {
  return m_expiresAt.isValid() && QDateTime::currentDateTimeUtc().msecsTo(m_expiresAt) <= m_renewWithinMs;
}

void McClient::renew(std::function<void(const std::optional<QString>& error)> done) {
  m_renewing.append(std::move(done));
  // One renewal at a time; whoever asks meanwhile waits on it.
  if (m_renewing.size() > 1) return;
  if (!m_http) m_http = new QNetworkAccessManager(this);
  QNetworkRequest renewal = request(QStringLiteral("/api/auth/session/renew"));
  renewal.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
  renewal.setTransferTimeout(15000);
  QNetworkReply* answer = m_http->post(renewal, QByteArrayLiteral("{}"));
  connect(answer, &QNetworkReply::finished, this, [this, answer] {
    answer->deleteLater();
    const int status = answer->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QDateTime expiresAt =
        QDateTime::fromString(QJsonDocument::fromJson(answer->readAll()).object().value(QLatin1String("expiresAt")).toString(), Qt::ISODateWithMs);
    std::optional<QString> error;
    if (status == 200 && expiresAt.isValid()) {
      m_expiresAt = expiresAt;
      emit credentialRenewed(expiresAt);
    } else {
      error = QStringLiteral("The environment credential could not be renewed (%1).")
                  .arg(status > 0 ? QStringLiteral("HTTP %1").arg(status) : answer->errorString());
    }
    for (const auto& waiting : std::exchange(m_renewing, {})) waiting(error);
  });
}

void McClient::sendPost(QObject* context, const QString& path, const QJsonObject& body, Reply reply) {
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
  // Each attempt learns afresh what the MC says of it.
  m_failureMessage.clear();
  m_blockedProtocol = 0;
  qCInfo(lcMc).noquote() << "connecting to" << m_origin.toString(QUrl::RemoveUserInfo) << "(attempt" << m_attempt + 1
                         << "trace" << m_traceId + ")";
  setPhase(Phase::Connecting);
  if (!m_http) m_http = new QNetworkAccessManager(this);
  QNetworkRequest descriptor = request(QStringLiteral("/.well-known/hal-c2/environment"));
  descriptor.setTransferTimeout(5000);
  trace(descriptor, m_traceId);
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
        qCInfo(lcMc).noquote() << "blocked: the MC speaks protocol" << m_blockedProtocol << "and this client" << kProtocol
                               << "(trace" << m_traceId + ")";
        setPhase(Phase::Blocked);
        return;
      }
      // An address that now answers as another environment is not that one.
      const QString environment = m_descriptor.value(QLatin1String("environmentId")).toString();
      if (!environment.isEmpty() && m_expectedEnvironment.isEmpty()) m_expectedEnvironment = environment;
      if (!environment.isEmpty() && environment != m_expectedEnvironment) {
        m_failure = QStringLiteral("mismatch");
        stop(Phase::Blocked, QStringLiteral("Connected environment %1 does not match %2.").arg(environment, m_expectedEnvironment));
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
    } else if (renewalDue()) {
      // The bare token goes in the socket's address: renewed first, like a ticket's.
      const quint64 generation = m_generation;
      renew([this, generation](const std::optional<QString>&) {
        if (generation == m_generation && !m_closed) openSocket();
      });
    } else {
      openSocket();
    }
  });
}

void McClient::openWithTicket() {
  if (!renewalDue()) return requestTicket();
  // A credential about to run out is renewed before it buys a ticket; the
  // ticket's answer decides what happens if it could not be.
  const quint64 generation = m_generation;
  renew([this, generation](const std::optional<QString>&) {
    if (generation == m_generation && !m_closed) requestTicket();
  });
}

void McClient::requestTicket() {
  const quint64 generation = m_generation;
  QNetworkRequest ticket = request(QStringLiteral("/api/auth/websocket-ticket"));
  ticket.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
  ticket.setTransferTimeout(5000);
  trace(ticket, m_traceId);
  QNetworkReply* answer = m_http->post(ticket, QByteArrayLiteral("{}"));
  connect(answer, &QNetworkReply::finished, this, [this, answer, generation] {
    answer->deleteLater();
    if (generation != m_generation || m_closed) return;
    const int status = answer->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QString issued = QJsonDocument::fromJson(answer->readAll()).object().value(QLatin1String("ticket")).toString();
    if (status == 200 && !issued.isEmpty()) {
      m_ticketed = true;
      openSocket(issued);
      return;
    }
    m_failure = status > 0 ? QStringLiteral("HTTP %1").arg(status) : answer->errorString();
    // What the MC answered says whether trying again can help
    // (client-runtime connection/errors.ts mapRemoteEnvironmentError).
    if (status == 401) {
      // The MC no longer knows this credential: only pairing again mends that.
      m_failure = QStringLiteral("refused");
      stop(Phase::Refused, QStringLiteral("The environment credential is invalid."));
    } else if (status == 403) {
      stop(Phase::Blocked, QStringLiteral("The environment credential does not grant the required access."));
    } else if (status == 400) {
      stop(Phase::Blocked, QStringLiteral("The environment rejected the authentication request."));
    } else if (status == 404) {
      stop(Phase::Blocked, QStringLiteral("The environment endpoint could not be found."));
    } else {
      if (status >= 500) {
        m_failureMessage = QStringLiteral("The environment could not authorize the connection.");
      } else if (status == 200) {
        m_failureMessage = QStringLiteral("Remote environment endpoint returned an invalid response.");
      }
      m_failureTraceId = m_traceId;
      scheduleRetry();
    }
  });
}

void McClient::openSocket(const QString& ticket) {
  auto* socket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
  m_socket = socket;
  // Only the current socket speaks for the MC.
  connect(socket, &QWebSocket::textMessageReceived, this, [this, socket](const QString& text) {
    if (socket == m_socket) onMessage(text);
  });
  connect(socket, &QWebSocket::disconnected, this, [this, socket] { onClosed(socket); });
  connect(socket, &QWebSocket::errorOccurred, this, [this, socket] { onClosed(socket); });
  QUrl url = m_url;
  if (!ticket.isEmpty()) {
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("wsTicket"), ticket);
    query.addQueryItem(QStringLiteral("protocol"), QString::number(kProtocol));
    url.setQuery(query);
  }
  QNetworkRequest handshake(url);
  trace(handshake, m_traceId);
  m_setupTimer.start();
  socket->open(handshake);
}

void McClient::onMessage(const QString& text) {
  const QJsonObject frame = QJsonDocument::fromJson(text.toUtf8()).object();
  const QString type = frame.value(QLatin1String("t")).toString();
  // Whatever it says, the MC is answering.
  if (m_pongTimer.isActive() || m_probeTimer.isActive()) {
    m_pongTimer.stop();
    m_probeTimer.stop();
    emit checked(true);
  }
  if (type == QLatin1String("hello")) {
    m_setupTimer.stop();
    m_heldTimer.start();
    m_readySince.start();
    m_ready = true;
    m_failure.clear();
    m_failureMessage.clear();
    m_failureTraceId.clear();
    m_mc = frame.value(QLatin1String("mc")).toString();
    m_environment = frame.value(QLatin1String("environment")).toString();
    m_pingTimer.start();
    qCInfo(lcMc).noquote() << "ready: mc" << m_mc << "(trace" << m_traceId + ")";
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
    const bool known = m_calls.contains(id);
    const Call call = m_calls.take(id);
    if (known) emit callEnded(id);
    // Its context is gone, and whatever the reply would have touched with it.
    if (!call.context || !call.reply) return;
    const Reply& reply = call.reply;
    if (type == QLatin1String("rpc.result")) {
      reply(frame.value(QLatin1String("result")), std::nullopt);
    } else {
      QString error = frame.value(QLatin1String("error")).toVariant().toString();
      // A cluster member the MC cannot reach: named, as the user knows it.
      if (error == QLatin1String("MC unavailable: noconnection")) {
        const QString environment = call.environment.isEmpty() ? m_environment : call.environment;
        QString name = m_names ? m_names(environment) : QString();
        if (name.isEmpty()) name = environment;
        error = QStringLiteral("%1 is not connected.").arg(name);
      }
      reply(frame.value(QLatin1String("detail")), error);
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
  const int code = socket->closeCode();
  socket->disconnect(this);
  socket->deleteLater();
  const bool wasReady = m_ready;
  m_ready = false;
  m_pingTimer.stop();
  m_pongTimer.stop();
  m_setupTimer.stop();
  m_heldTimer.stop();
  m_probeTimer.stop();
  qCInfo(lcMc).noquote() << "closed:" << reason << "code" << code
                         << (wasReady ? QStringLiteral("after %1 ms ready").arg(m_readySince.elapsed()) : QStringLiteral("before hello"))
                         << "(trace" << m_traceId + ")";
  failCalls();
  if (wasReady) emit readyChanged(false);
  if (m_closed) return;
  m_failure = reason;
  m_failureMessage.clear();
  m_failureTraceId = m_traceId;
  if (revoked) {
    qCInfo(lcMc).noquote() << "refused: the MC revoked this session (trace" << m_traceId + ")";
    setPhase(Phase::Refused);
    return;
  }
  failed(reason, wasReady);
}

// A socket that never got its hello may have been turned away for its
// credential. With the bare token that is either a paired session's token,
// which needs a ticket, or one the MC refuses: asking for a ticket tells which.
// A ticketed socket that failed is retried like any other, and so is one that
// timed out: the MC took it, so it took its credential.
// A connection that failed wake()'s check is replaced at once; should the new
// one fail too, it is retried as usual.
void McClient::failed(const QString& reason, bool wasReady) {
  if (reason == QLatin1String("check")) {
    connectSocket();
    return;
  }
  if (wasReady || m_ticketed || reason == QLatin1String("timeout")) {
    scheduleRetry();
    return;
  }
  openWithTicket();
}

void McClient::stop(Phase phase, const QString& message) {
  m_failureMessage = message;
  m_failureTraceId = m_traceId;
  qCInfo(lcMc).noquote() << (phase == Phase::Refused ? "refused:" : "blocked:") << message << "(trace" << m_traceId + ")";
  setPhase(phase);
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
  qCInfo(lcMc).noquote() << "retrying in" << m_retryDelay << "ms (trace" << m_traceId + ")";
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
