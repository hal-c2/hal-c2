#include "FakeNode.h"

#include <QJsonDocument>
#include <QtLogging>

#include <utility>

namespace {

QList<void (*)(FakeNode&)>& extensions() {
  static QList<void (*)(FakeNode&)> list;
  return list;
}

}  // namespace

FakeNode::Extension::Extension(void (*extend)(FakeNode& node)) {
  extensions().append(extend);
}

FakeNode::FakeNode() : m_server(QStringLiteral("fake-node"), QWebSocketServer::NonSecureMode) {
  if (!m_server.listen(QHostAddress::LocalHost)) qFatal("fake node cannot listen");
  m_port = m_server.serverPort();
  QObject::connect(&m_server, &QWebSocketServer::newConnection, this, [this] { accept(); });

  onShape(QStringLiteral("shell"), [this](int id, const QJsonObject& shape) {
    m_shellSubscription = id;
    shellLinks = shape.value(QLatin1String("links")).toBool();
    if (!holdSnapshot) sendSnapshot();
  });
  onRpc(QStringLiteral("orchestration.dispatchCommand"), [this](const Rpc& rpc) { dispatchCommand(rpc); });
  for (const auto extend : std::as_const(extensions())) extend(*this);
}

void FakeNode::onRpc(const QString& method, RpcHandler handler) {
  m_rpc.insert(method, std::move(handler));
}

void FakeNode::onShape(const QString& type, ShapeHandler handler) {
  m_shapes.insert(type, std::move(handler));
}

void FakeNode::send(const QJsonObject& frame) {
  if (m_socket) m_socket->sendTextMessage(QString::fromUtf8(QJsonDocument(frame).toJson(QJsonDocument::Compact)));
}

void FakeNode::reply(const Rpc& rpc, const QJsonValue& result) {
  if (rpc.socket != m_socket) return;
  send({{QStringLiteral("t"), QStringLiteral("rpc.result")}, {QStringLiteral("id"), rpc.id}, {QStringLiteral("result"), result}});
}

void FakeNode::refuse(const Rpc& rpc, const QString& message, const QJsonObject& detail) {
  if (rpc.socket != m_socket) return;
  QJsonObject frame{{QStringLiteral("t"), QStringLiteral("rpc.error")}, {QStringLiteral("id"), rpc.id}, {QStringLiteral("error"), message}};
  if (!detail.isEmpty()) frame.insert(QStringLiteral("detail"), detail);
  send(frame);
}

QList<int> FakeNode::subscribers(const QString& type) const {
  QList<int> ids;
  for (auto it = m_live.cbegin(); it != m_live.cend(); ++it) {
    if (it->value(QLatin1String("type")) == type) ids.append(it.key());
  }
  return ids;
}

void FakeNode::answerHeld() {
  m_holds.clear();
  const auto held = std::exchange(m_held, {});
  for (const auto& answer : held) answer();
}

void FakeNode::sendSnapshot() {
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
      {QStringLiteral("nodes"),
       QJsonArray{QJsonObject{
           {QStringLiteral("node"), name},
           {QStringLiteral("online"), true},
           {QStringLiteral("environment"),
            QJsonObject{
                {QStringLiteral("environmentId"), environmentId},
                {QStringLiteral("capabilities"), capabilities},
            }},
       }}},
      {QStringLiteral("rows"), rows},
      {QStringLiteral("links"), links()},
  };
  if (shellLinks) {
    // Each link carries its nodes and rows as the node holds them.
    QJsonArray withRows;
    for (const QJsonValue& value : snapshot.value(QLatin1String("links")).toArray()) {
      QJsonObject link = value.toObject();
      const QString environment = link.value(QLatin1String("environment")).toObject().value(QLatin1String("environmentId")).toString();
      QJsonArray linkRows;
      for (const QJsonArray& row : linkedRows.value(environment)) linkRows.append(QJsonArray{name, row.at(0), row.at(1), row.at(2)});
      link.insert(QStringLiteral("nodes"), QJsonArray{QJsonObject{
                                               {QStringLiteral("node"), name},
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

void FakeNode::link(const QString& environment) {
  if (!linked.contains(environment)) linked.append(environment);
  sendLinks();
  if (!shellLinks) return;
  sendLinkFrame(QStringLiteral("shell.linkEnvironment"), environment,
                {{QStringLiteral("environment"), linkedEnvironment(environment)}});
  sendLinkFrame(QStringLiteral("shell.linkNode"), environment,
                {{QStringLiteral("online"), !linkProblems.contains(environment)}});
  QJsonArray rows;
  for (const QJsonArray& row : linkedRows.value(environment)) rows.append(row);
  if (!rows.isEmpty()) sendLinkFrame(QStringLiteral("shell.linkRows"), environment, {{QStringLiteral("rows"), rows}});
}

void FakeNode::sendLinkRow(const QString& environment, const QString& id, const QJsonObject& row, const QString& kind) {
  const QJsonArray entry{id, kind, row};
  linkedRows[environment].insert(id, entry);
  if (shellLinks && linked.contains(environment)) {
    QJsonArray rows;
    rows.append(entry);
    sendLinkFrame(QStringLiteral("shell.linkRows"), environment, {{QStringLiteral("rows"), rows}});
  }
}

void FakeNode::setLinkProblem(const QString& environment, const QString& problem) {
  if (problem.isEmpty()) {
    linkProblems.remove(environment);
  } else {
    linkProblems.insert(environment, problem);
  }
  sendLinks();
  if (shellLinks) sendLinkFrame(QStringLiteral("shell.linkNode"), environment, {{QStringLiteral("online"), problem.isEmpty()}});
}

// What the node answers a request for a linked environment while its link is
// down (HalC2.Links.unreachable/3).
QJsonObject FakeNode::unreachable(const QString& environment) const {
  return {{QStringLiteral("_tag"), QStringLiteral("EnvironmentUnreachableError")},
          {QStringLiteral("environmentId"), environment},
          {QStringLiteral("reason"), linkProblems.value(environment)},
          {QStringLiteral("message"), QStringLiteral("%1 cannot be reached.").arg(environment)}};
}

QJsonObject FakeNode::linkedEnvironment(const QString& environment) const {
  return {{QStringLiteral("environmentId"), environment},
          {QStringLiteral("label"), linkLabels.value(environment, environment)},
          {QStringLiteral("capabilities"), capabilities}};
}

void FakeNode::sendLinkFrame(const QString& type, const QString& environment, QJsonObject frame) {
  if (!m_socket || m_shellSubscription < 0) return;
  frame.insert(QStringLiteral("t"), type);
  frame.insert(QStringLiteral("id"), m_shellSubscription);
  frame.insert(QStringLiteral("link"), environment);
  frame.insert(QStringLiteral("node"), name);
  send(frame);
}

void FakeNode::unlink(const QString& environment) {
  linked.removeAll(environment);
  linkProblems.remove(environment);
  sendLinks();
}

void FakeNode::sendLinks() {
  if (!m_socket || m_shellSubscription < 0) return;
  send({{QStringLiteral("t"), QStringLiteral("shell.links")}, {QStringLiteral("id"), m_shellSubscription}, {QStringLiteral("links"), links()}});
}

QJsonArray FakeNode::links() const {
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
    result.replace(result.size() - 1, link);
  }
  return result;
}

void FakeNode::join(const QString& peer, const QString& peerEnvironment) {
  peers.insert(peerEnvironment, peer);
  send({
      {QStringLiteral("t"), QStringLiteral("shell.environment")},
      {QStringLiteral("id"), m_shellSubscription},
      {QStringLiteral("node"), peer},
      {QStringLiteral("environment"),
       QJsonObject{{QStringLiteral("environmentId"), peerEnvironment}, {QStringLiteral("capabilities"), capabilities}}},
  });
}

void FakeNode::sendRow(const QString& id, const QJsonObject& row, const QString& kind) {
  QJsonArray rows;
  rows.append(QJsonArray{id, kind, row});
  sendRows(name, rows);
}

void FakeNode::sendRows(const QString& node, const QJsonArray& rows) {
  if (!m_socket || m_shellSubscription < 0) return;
  send({
      {QStringLiteral("t"), QStringLiteral("shell.rows")},
      {QStringLiteral("id"), m_shellSubscription},
      {QStringLiteral("node"), node},
      {QStringLiteral("rows"), rows},
  });
}

void FakeNode::accept() {
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
          {QStringLiteral("node"), name},
          {QStringLiteral("environment"), environmentId}});
  }
}

void FakeNode::onMessage(QWebSocket* socket, const QString& text) {
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

void FakeNode::dispatchCommand(const Rpc& rpc) {
  commands.append(rpc.payload);
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
