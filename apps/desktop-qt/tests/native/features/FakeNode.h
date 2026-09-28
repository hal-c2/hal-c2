#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QStringList>
#include <QUrl>
#include <QWebSocket>
#include <QWebSocketServer>

#include <functional>
#include <memory>
#include <typeindex>
#include <unordered_map>

// One node of protocol 3 (apps/server-ex lib/hal_c2/web/protocol.ex): hello,
// the shell shape, and `orchestration.dispatchCommand`, which it records and
// answers (or refuses, or holds until told to answer). Any other call is
// answered with null unless a domain handles it.
//
// A domain's fake lives with its steps: an Extension registers its RPC and
// shape handlers on every new node, and keeps its state in a part:
//
//   namespace {
//   struct FakeGit { QList<QJsonObject> calls; };
//   const FakeNode::Extension git([](FakeNode& node) {
//     node.onRpc(QStringLiteral("git."), [&node](const FakeNode::Rpc& rpc) {
//       node.part<FakeGit>().calls.append(rpc.payload);
//       node.reply(rpc, QJsonValue::Null);
//     });
//   });
//   }  // namespace
class FakeNode : public QObject {
public:
  struct Rpc {
    int id = 0;
    QString method;
    QJsonObject payload;
    // The connection it came on; an answer to a dropped one is not sent.
    QPointer<QWebSocket> socket;
  };
  using RpcHandler = std::function<void(const Rpc& rpc)>;
  // `id` is the subscription's; the shape is live until unsubscribed, forgotten
  // or the connection drops.
  using ShapeHandler = std::function<void(int id, const QJsonObject& shape)>;

  struct Extension {
    explicit Extension(void (*extend)(FakeNode& node));
  };

  FakeNode();

  QUrl origin() const { return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(m_port)); }

  // `method` is exact, or a namespace ("cluster." takes every `cluster.*`
  // call); an exact match wins.
  void onRpc(const QString& method, RpcHandler handler);
  void onShape(const QString& type, ShapeHandler handler);

  void send(const QJsonObject& frame);
  // Whether the call came on the connection still open.
  bool current(const Rpc& rpc) const { return rpc.socket == m_socket; }
  void reply(const Rpc& rpc, const QJsonValue& result);
  // An `rpc.error`, with `detail` when given.
  void refuse(const Rpc& rpc, const QString& message, const QJsonObject& detail = {});
  // Live subscriptions to the shape type, oldest first.
  QList<int> subscribers(const QString& type) const;
  QJsonObject shapeOf(int id) const { return m_live.value(id); }
  // A subscription the node turned down, which gets nothing more.
  void forget(int id) { m_live.remove(id); }

  // Named holds say which answers wait: `answers` holds commands and terminal
  // calls; a domain may hold its own. Held answers are deferred until
  // answerHeld(), which lifts every hold.
  void hold(const QString& what) { m_holds.insert(what); }
  bool holding(const QString& what) const { return m_holds.contains(what); }
  void defer(std::function<void()> answer) { m_held.append(std::move(answer)); }
  void answerHeld();

  // A domain's state on this node, made on first use.
  template <class T>
  T& part() {
    std::shared_ptr<void>& slot = m_parts[std::type_index(typeid(T))];
    if (!slot) slot = std::make_shared<T>();
    return *static_cast<T*>(slot.get());
  }

  QString name = QStringLiteral("node-a");
  QString environmentId = QStringLiteral("env-a");
  QMap<QString, QJsonObject> threads;
  QMap<QString, QJsonObject> projects;
  QList<QUrl> connections;
  // Every `sub` frame, in order.
  QList<QJsonObject> subscriptions;
  QList<QJsonObject> commands;
  QHash<QString, QString> refusals;
  // What an accepted command does to the node's rows (the real node's
  // projection), run before it is answered.
  QList<std::function<void(const QJsonObject& command)>> effects;
  QJsonObject capabilities{
      {QStringLiteral("threadSettlement"), true},
      {QStringLiteral("threadSnooze"), true},
      {QStringLiteral("threadVisitedTracking"), true},
  };
  bool holdSnapshot = false;
  // Environments outside the cluster the node is linked to (HalC2.Links), and
  // why a link is down ("unreachable", "refused"; absent while it is online).
  QStringList linked;
  QHash<QString, QString> linkProblems;
  // Each linked environment's label, when it is not its id.
  QHash<QString, QString> linkLabels;

  void sendSnapshot();
  // The node pairs with an environment outside its cluster, announced as `shell.links`.
  void link(const QString& environment);
  void unlink(const QString& environment);
  // Announces the links as they now are.
  void sendLinks();
  // Another node joins this one's cluster, announced as the shell announces it on nodeup.
  void join(const QString& peer, const QString& peerEnvironment);
  // The cluster member serving each environment that joined, by environment.
  QHash<QString, QString> peers;
  void sendRow(const QString& id, const QJsonObject& row, const QString& kind = QStringLiteral("thread"));
  // Rows of the cluster member `node` as `shell.rows`: each [id, kind, fields].
  void sendRows(const QString& node, const QJsonArray& rows);

  void drop() {
    if (m_socket) m_socket->close();
  }
  void stopAccepting() { m_server.close(); }

private:
  void accept();
  void onMessage(QWebSocket* socket, const QString& text);
  void dispatchCommand(const Rpc& rpc);
  QJsonArray links() const;

  QWebSocketServer m_server;
  quint16 m_port = 0;
  QPointer<QWebSocket> m_socket;
  int m_shellSubscription = -1;
  QMap<int, QJsonObject> m_live;
  QHash<QString, RpcHandler> m_rpc;
  QHash<QString, ShapeHandler> m_shapes;
  QSet<QString> m_holds;
  QList<std::function<void()>> m_held;
  std::unordered_map<std::type_index, std::shared_ptr<void>> m_parts;
};
