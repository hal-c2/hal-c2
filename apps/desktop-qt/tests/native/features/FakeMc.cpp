#include "FakeMc.h"

#include <QJsonDocument>
#include <QTcpSocket>
#include <QtLogging>

#include <memory>
#include <utility>

namespace {

QList<void (*)(FakeMc&)>& extensions() {
  static QList<void (*)(FakeMc&)> list;
  return list;
}

// What the MC answers a request for a member it cannot reach (socket.ex).
const QString kUnavailable = QStringLiteral("MC unavailable: noconnection");

}  // namespace

FakeMc::Extension::Extension(void (*extend)(FakeMc& mc)) {
  extensions().append(extend);
}

FakeMc::FakeMc() : m_server(QStringLiteral("fake-mc"), QWebSocketServer::NonSecureMode) {
  if (!m_tcp.listen(QHostAddress::LocalHost)) qFatal("fake MC cannot listen");
  m_port = m_tcp.serverPort();
  QObject::connect(&m_tcp, &QTcpServer::pendingConnectionAvailable, this, [this] {
    while (QTcpSocket* socket = m_tcp.nextPendingConnection()) route(socket);
  });
  QObject::connect(&m_server, &QWebSocketServer::newConnection, this, [this] { accept(); });

  onShape(QStringLiteral("shell"), [this](int id, const QJsonObject& shape) {
    m_shellSubscription = id;
    if (!holdSnapshot) sendSnapshot();
  });
  onRpc(QStringLiteral("orchestration.dispatchCommand"), [this](const Rpc& rpc) { dispatchCommand(rpc); });
  for (const auto extend : std::as_const(extensions())) extend(*this);
}

void FakeMc::onRpc(const QString& method, RpcHandler handler) {
  m_rpc.insert(method, std::move(handler));
}

void FakeMc::passOn(const Rpc& rpc) {
  const auto handler = m_rpc.constFind(rpc.method.left(rpc.method.indexOf(QLatin1Char('.')) + 1));
  if (handler != m_rpc.cend()) return (*handler)(rpc);
  reply(rpc, QJsonValue::Null);
}

void FakeMc::onShape(const QString& type, ShapeHandler handler) {
  m_shapes.insert(type, std::move(handler));
}

void FakeMc::send(const QJsonObject& frame) {
  if (m_socket) m_socket->sendTextMessage(QString::fromUtf8(QJsonDocument(frame).toJson(QJsonDocument::Compact)));
}

void FakeMc::reply(const Rpc& rpc, const QJsonValue& result) {
  if (rpc.socket != m_socket) return;
  send({{QStringLiteral("t"), QStringLiteral("rpc.result")}, {QStringLiteral("id"), rpc.id}, {QStringLiteral("result"), result}});
}

void FakeMc::refuse(const Rpc& rpc, const QString& message, const QJsonObject& detail) {
  if (rpc.socket != m_socket) return;
  QJsonObject frame{{QStringLiteral("t"), QStringLiteral("rpc.error")}, {QStringLiteral("id"), rpc.id}, {QStringLiteral("error"), message}};
  if (!detail.isEmpty()) frame.insert(QStringLiteral("detail"), detail);
  send(frame);
}

QList<int> FakeMc::subscribers(const QString& type) const {
  QList<int> ids;
  for (auto it = m_live.cbegin(); it != m_live.cend(); ++it) {
    if (it->value(QLatin1String("type")) == type) ids.append(it.key());
  }
  return ids;
}

void FakeMc::answerHeld() {
  m_holds.clear();
  const auto held = std::exchange(m_held, {});
  for (const auto& answer : held) answer();
}

void FakeMc::sendSnapshot() {
  if (!m_socket || m_shellSubscription < 0) return;
  QJsonArray rows;
  for (auto it = threads.cbegin(); it != threads.cend(); ++it) {
    rows.append(QJsonArray{name, it.key(), QStringLiteral("thread"), *it});
  }
  for (auto it = projects.cbegin(); it != projects.cend(); ++it) {
    rows.append(QJsonArray{name, it.key(), QStringLiteral("project"), *it});
  }
  QJsonArray mcs{QJsonObject{
      {QStringLiteral("mc"), name},
      {QStringLiteral("online"), true},
      {QStringLiteral("environment"),
       label.isEmpty() ? QJsonObject{{QStringLiteral("environmentId"), environmentId}, {QStringLiteral("capabilities"), capabilities}}
                       : QJsonObject{{QStringLiteral("environmentId"), environmentId},
                                     {QStringLiteral("label"), label},
                                     {QStringLiteral("capabilities"), capabilities}}},
  }};
  for (const QString& environment : std::as_const(members)) {
    const QString peer = peers.value(environment);
    mcs.append(QJsonObject{{QStringLiteral("mc"), peer},
                           {QStringLiteral("online"), !offline.contains(environment)},
                           {QStringLiteral("environment"), peerEnvironment(environment)}});
    for (const QJsonArray& row : peerRows.value(environment)) rows.append(QJsonArray{peer, row.at(0), row.at(1), row.at(2)});
  }
  send({
      {QStringLiteral("t"), QStringLiteral("shell")},
      {QStringLiteral("id"), m_shellSubscription},
      {QStringLiteral("mcs"), mcs},
      {QStringLiteral("rows"), rows},
  });
}

QJsonObject FakeMc::peerEnvironment(const QString& environment) const {
  QJsonObject descriptor{{QStringLiteral("environmentId"), environment}, {QStringLiteral("capabilities"), capabilities}};
  if (peerLabels.contains(environment)) descriptor.insert(QStringLiteral("label"), peerLabels.value(environment));
  return descriptor;
}

void FakeMc::join(const QString& peer, const QString& peerEnvironment) {
  if (!members.contains(peerEnvironment)) members.append(peerEnvironment);
  peers.insert(peerEnvironment, peer);
  if (!m_socket || m_shellSubscription < 0) return;
  send({
      {QStringLiteral("t"), QStringLiteral("shell.environment")},
      {QStringLiteral("id"), m_shellSubscription},
      {QStringLiteral("mc"), peer},
      {QStringLiteral("environment"), this->peerEnvironment(peerEnvironment)},
  });
  QJsonArray rows;
  for (const QJsonArray& row : peerRows.value(peerEnvironment)) rows.append(row);
  if (!rows.isEmpty()) sendRows(peer, rows);
  setOnline(peerEnvironment, !offline.contains(peerEnvironment));
}

void FakeMc::sendPeerRow(const QString& environment, const QString& id, const QJsonObject& row, const QString& kind) {
  const QJsonArray entry{id, kind, row};
  peerRows[environment].insert(id, entry);
  if (peers.contains(environment)) sendRows(peers.value(environment), QJsonArray{QJsonValue(entry)});
}

void FakeMc::setOnline(const QString& environment, bool online) {
  if (online) {
    offline.remove(environment);
  } else {
    offline.insert(environment);
  }
  if (!m_socket || m_shellSubscription < 0) return;
  send({{QStringLiteral("t"), QStringLiteral("shell.mc")},
        {QStringLiteral("id"), m_shellSubscription},
        {QStringLiteral("mc"), peers.value(environment)},
        {QStringLiteral("online"), online}});
}

void FakeMc::remove(const QString& environment) {
  const QString peer = peers.take(environment);
  members.removeAll(environment);
  offline.remove(environment);
  peerRows.remove(environment);
  if (!m_socket || m_shellSubscription < 0) return;
  send({{QStringLiteral("t"), QStringLiteral("shell.mc")},
        {QStringLiteral("id"), m_shellSubscription},
        {QStringLiteral("mc"), peer},
        {QStringLiteral("online"), false},
        {QStringLiteral("removed"), true}});
}

// A request for a member whose MC is down, by its environment or its MC.
bool FakeMc::down(const QString& environment, const QString& mc) const {
  return offline.contains(environment) || (!mc.isEmpty() && offline.contains(peers.key(mc)));
}

void FakeMc::sendRow(const QString& id, const QJsonObject& row, const QString& kind) {
  QJsonArray rows;
  rows.append(QJsonArray{id, kind, row});
  sendRows(name, rows);
}

void FakeMc::sendRows(const QString& mc, const QJsonArray& rows) {
  if (!m_socket || m_shellSubscription < 0) return;
  send({
      {QStringLiteral("t"), QStringLiteral("shell.rows")},
      {QStringLiteral("id"), m_shellSubscription},
      {QStringLiteral("mc"), mc},
      {QStringLiteral("rows"), rows},
  });
}

void FakeMc::route(QTcpSocket* socket) {
  socket->setParent(this);
  auto request = std::make_shared<QByteArray>();
  auto routed = std::make_shared<QMetaObject::Connection>();
  const auto read = [this, socket, request, routed] {
    if (request->isEmpty() && socket->bytesAvailable() < 5) return;
    if (request->isEmpty() && !m_rawHandlers.isEmpty()) {
      const QByteArray peeked = socket->peek(socket->bytesAvailable());
      const qsizetype end = peeked.indexOf("\r\n\r\n");
      if (end < 0) return;
      const QString path = QString::fromUtf8(peeked.left(peeked.indexOf('\r')).split(' ').value(1));
      for (auto handler = m_rawHandlers.cbegin(); handler != m_rawHandlers.cend(); ++handler) {
        if (!path.startsWith(handler.key())) continue;
        QObject::disconnect(*routed);
        handler.value()(socket, peeked.left(end + 4));
        return;
      }
    }
    if (request->isEmpty() && !socket->peek(5).startsWith("POST ")) {
      QObject::disconnect(*routed);
      m_server.handleConnection(socket);
      return;
    }
    request->append(socket->readAll());
    const qsizetype headersEnd = request->indexOf("\r\n\r\n");
    if (headersEnd < 0) return;
    qsizetype length = 0;
    for (const QByteArray& line : request->left(headersEnd).split('\n')) {
      if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toLongLong();
    }
    if (request->size() < headersEnd + 4 + length) return;
    QObject::disconnect(*routed);
    answerHttp(socket, *request);
  };
  *routed = QObject::connect(socket, &QTcpSocket::readyRead, this, read);
  read();
}

void FakeMc::answerHttp(QTcpSocket* socket, const QByteArray& request) {
  const qsizetype headersEnd = request.indexOf("\r\n\r\n");
  const QString path = QString::fromUtf8(request.left(request.indexOf('\r')).split(' ').value(1)).section(QLatin1Char('?'), 0, 0);
  const QJsonObject body = QJsonDocument::fromJson(request.mid(headersEnd + 4)).object();
  QPointer<QTcpSocket> connection = socket;
  const auto respond = [connection](int status, const QJsonObject& answer) {
    if (!connection) return;
    const QByteArray json = QJsonDocument(answer).toJson(QJsonDocument::Compact);
    connection->write(QStringLiteral("HTTP/1.1 %1 %2\r\nContent-Type: application/json\r\nContent-Length: %3\r\nConnection: close\r\n\r\n")
                          .arg(status)
                          .arg(status < 300 ? QStringLiteral("OK") : QStringLiteral("Error"))
                          .arg(json.size())
                          .toUtf8() +
                      json);
    connection->disconnectFromHost();
  };
  const auto handler = m_httpHandlers.constFind(path);
  if (handler == m_httpHandlers.constEnd()) {
    respond(404, {{QStringLiteral("_tag"), QStringLiteral("NotFound")}});
    return;
  }
  (*handler)(body, respond);
}

void FakeMc::accept() {
  while (QWebSocket* socket = m_server.nextPendingConnection()) {
    socket->setParent(this);
    connections.append(socket->requestUrl());
    m_socket = socket;
    m_shellSubscription = -1;
    m_live.clear();
    QObject::connect(socket, &QWebSocket::textMessageReceived, this,
                     [this, socket](const QString& text) { onMessage(socket, text); });
    QObject::connect(socket, &QWebSocket::disconnected, socket, &QObject::deleteLater);
    send({{QStringLiteral("t"), QStringLiteral("hello")},
          {QStringLiteral("protocol"), 3},
          {QStringLiteral("mc"), name},
          {QStringLiteral("environment"), environmentId}});
  }
}

void FakeMc::onMessage(QWebSocket* socket, const QString& text) {
  if (socket != m_socket) return;
  const QJsonObject message = QJsonDocument::fromJson(text.toUtf8()).object();
  const QString type = message.value(QLatin1String("t")).toString();
  const int id = message.value(QLatin1String("id")).toInt();
  if (type == QLatin1String("sub")) {
    subscriptions.append(message);
    const QJsonObject shape = message.value(QLatin1String("shape")).toObject();
    if (down(shape.value(QLatin1String("environment")).toString(), shape.value(QLatin1String("mc")).toString())) {
      send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), kUnavailable}});
      return;
    }
    const auto handler = m_shapes.constFind(shape.value(QLatin1String("type")).toString());
    if (handler == m_shapes.cend()) return;
    m_live.insert(id, shape);
    (*handler)(id, shape);
  } else if (type == QLatin1String("unsub")) {
    m_live.remove(id);
  } else if (type == QLatin1String("ping")) {
    send({{QStringLiteral("t"), QStringLiteral("pong")}});
  } else if (type == QLatin1String("rpc")) {
    const Rpc rpc{id, message.value(QLatin1String("method")).toString(), message.value(QLatin1String("payload")).toObject(), socket,
                  message.value(QLatin1String("environment")).toString()};
    if (down(rpc.environment, {})) {
      refuse(rpc, kUnavailable);
      return;
    }
    auto handler = m_rpc.constFind(rpc.method);
    if (handler == m_rpc.cend()) {
      const qsizetype dot = rpc.method.indexOf(QLatin1Char('.'));
      if (dot > 0) handler = m_rpc.constFind(rpc.method.left(dot + 1));
    }
    if (handler != m_rpc.cend()) {
      (*handler)(rpc);
    } else {
      reply(rpc, QJsonValue::Null);
    }
  }
}

void FakeMc::dispatchCommand(const Rpc& rpc) {
  commands.append(rpc.payload);
  commandEnvironments.append(rpc.environment);
  const QString type = rpc.payload.value(QLatin1String("type")).toString();
  auto answer = [this, rpc, known = refusals.contains(type), refusal = refusals.value(type)] {
    if (known) {
      refuse(rpc, refusal);
    } else {
      for (const auto& effect : std::as_const(effects)) effect(rpc.payload);
      reply(rpc, QJsonObject{{QStringLiteral("sequence"), commands.size()}});
    }
  };
  if (holding(QStringLiteral("answers"))) {
    defer(answer);
  } else {
    answer();
  }
}
