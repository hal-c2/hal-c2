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
    shellLinks = shape.value(QLatin1String("links")).toBool();
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
  QJsonObject snapshot{
      {QStringLiteral("t"), QStringLiteral("shell")},
      {QStringLiteral("id"), m_shellSubscription},
      {QStringLiteral("mcs"),
       QJsonArray{QJsonObject{
           {QStringLiteral("mc"), name},
           {QStringLiteral("online"), true},
           {QStringLiteral("environment"),
            label.isEmpty() ? QJsonObject{{QStringLiteral("environmentId"), environmentId}, {QStringLiteral("capabilities"), capabilities}}
                            : QJsonObject{{QStringLiteral("environmentId"), environmentId},
                                          {QStringLiteral("label"), label},
                                          {QStringLiteral("capabilities"), capabilities}}},
       }}},
      {QStringLiteral("rows"), rows},
      {QStringLiteral("links"), links()},
  };
  if (shellLinks) {
    // Each link carries its MCs and rows as the MC holds them.
    QJsonArray withRows;
    for (const QJsonValue& value : snapshot.value(QLatin1String("links")).toArray()) {
      QJsonObject link = value.toObject();
      const QString environment = link.value(QLatin1String("environment")).toObject().value(QLatin1String("environmentId")).toString();
      QJsonArray linkRows;
      for (const QJsonArray& row : linkedRows.value(environment)) linkRows.append(QJsonArray{name, row.at(0), row.at(1), row.at(2)});
      link.insert(QStringLiteral("mcs"), QJsonArray{QJsonObject{
                                               {QStringLiteral("mc"), name},
                                               {QStringLiteral("online"), !linkProblems.contains(environment)},
                                               {QStringLiteral("environment"), linkedEnvironment(environment)},
                                           }});
      link.insert(QStringLiteral("rows"), linkRows);
      withRows.append(link);
    }
    snapshot.insert(QStringLiteral("links"), withRows);
  }
  send(snapshot);
}

void FakeMc::link(const QString& environment) {
  if (!linked.contains(environment)) linked.append(environment);
  sendLinks();
  if (!shellLinks) return;
  sendLinkFrame(QStringLiteral("shell.linkEnvironment"), environment,
                {{QStringLiteral("environment"), linkedEnvironment(environment)}});
  sendLinkFrame(QStringLiteral("shell.linkMc"), environment,
                {{QStringLiteral("online"), !linkProblems.contains(environment)}});
  QJsonArray rows;
  for (const QJsonArray& row : linkedRows.value(environment)) rows.append(row);
  if (!rows.isEmpty()) sendLinkFrame(QStringLiteral("shell.linkRows"), environment, {{QStringLiteral("rows"), rows}});
}

void FakeMc::sendLinkRow(const QString& environment, const QString& id, const QJsonObject& row, const QString& kind) {
  const QJsonArray entry{id, kind, row};
  linkedRows[environment].insert(id, entry);
  if (shellLinks && linked.contains(environment)) {
    QJsonArray rows;
    rows.append(entry);
    sendLinkFrame(QStringLiteral("shell.linkRows"), environment, {{QStringLiteral("rows"), rows}});
  }
}

void FakeMc::setLinkProblem(const QString& environment, const QString& problem) {
  if (problem.isEmpty()) {
    linkProblems.remove(environment);
  } else {
    linkProblems.insert(environment, problem);
  }
  sendLinks();
  if (shellLinks) sendLinkFrame(QStringLiteral("shell.linkMc"), environment, {{QStringLiteral("online"), problem.isEmpty()}});
}

// What the MC answers a request for a linked environment while its link is
// down (HalC2.Links.unreachable/3).
QJsonObject FakeMc::unreachable(const QString& environment) const {
  return {{QStringLiteral("_tag"), QStringLiteral("EnvironmentUnreachableError")},
          {QStringLiteral("environmentId"), environment},
          {QStringLiteral("reason"), linkProblems.value(environment)},
          {QStringLiteral("message"), QStringLiteral("%1 cannot be reached.").arg(environment)}};
}

QJsonObject FakeMc::linkedEnvironment(const QString& environment) const {
  return {{QStringLiteral("environmentId"), environment},
          {QStringLiteral("label"), linkLabels.value(environment, environment)},
          {QStringLiteral("capabilities"), capabilities}};
}

void FakeMc::sendLinkFrame(const QString& type, const QString& environment, QJsonObject frame) {
  if (!m_socket || m_shellSubscription < 0) return;
  frame.insert(QStringLiteral("t"), type);
  frame.insert(QStringLiteral("id"), m_shellSubscription);
  frame.insert(QStringLiteral("link"), environment);
  frame.insert(QStringLiteral("mc"), name);
  send(frame);
}

void FakeMc::unlink(const QString& environment) {
  linked.removeAll(environment);
  linkProblems.remove(environment);
  sendLinks();
}

void FakeMc::sendLinks() {
  if (!m_socket || m_shellSubscription < 0) return;
  send({{QStringLiteral("t"), QStringLiteral("shell.links")}, {QStringLiteral("id"), m_shellSubscription}, {QStringLiteral("links"), links()}});
}

QJsonArray FakeMc::links() const {
  QJsonArray result;
  for (const QString& environment : linked) {
    result.append(QJsonObject{
        {QStringLiteral("environment"),
         QJsonObject{{QStringLiteral("environmentId"), environment},
                     {QStringLiteral("label"), linkLabels.value(environment, environment)}}},
        {QStringLiteral("origin"), QStringLiteral("http://") + environment + QStringLiteral(":3780")},
        {QStringLiteral("online"), !linkProblems.contains(environment)},
    });
    QJsonObject link = result.last().toObject();
    if (linkProblems.contains(environment)) link.insert(QStringLiteral("problem"), linkProblems.value(environment));
    if (linkScopes.contains(environment)) link.insert(QStringLiteral("scopes"), QJsonArray::fromStringList(linkScopes.value(environment)));
    result.replace(result.size() - 1, link);
  }
  return result;
}

void FakeMc::join(const QString& peer, const QString& peerEnvironment) {
  peers.insert(peerEnvironment, peer);
  send({
      {QStringLiteral("t"), QStringLiteral("shell.environment")},
      {QStringLiteral("id"), m_shellSubscription},
      {QStringLiteral("mc"), peer},
      {QStringLiteral("environment"),
       QJsonObject{{QStringLiteral("environmentId"), peerEnvironment}, {QStringLiteral("capabilities"), capabilities}}},
  });
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
    const QString down = shape.value(QLatin1String("environment")).toString();
    if (linkProblems.contains(down)) {
      const QJsonObject detail = unreachable(down);
      send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), detail.value(QLatin1String("message"))}, {QStringLiteral("detail"), detail}});
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
    const QString down = message.value(QLatin1String("environment")).toString();
    const Rpc rpc{id, message.value(QLatin1String("method")).toString(), message.value(QLatin1String("payload")).toObject(), socket, down};
    calls.append(rpc);
    if (linkProblems.contains(down)) {
      const QJsonObject detail = unreachable(down);
      refuse(rpc, detail.value(QLatin1String("message")).toString(), detail);
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
  // A refusal is for every command of a type, or (`type:threadId`) one thread's.
  const QString one = type + QLatin1Char(':') + rpc.payload.value(QLatin1String("threadId")).toString();
  const QString refused = refusals.contains(one) ? one : type;
  auto answer = [this, rpc, known = refusals.contains(refused), refusal = refusals.value(refused)] {
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
