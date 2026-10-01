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
#include <QTcpServer>
#include <QUrl>
#include <QWebSocket>
#include <QWebSocketServer>

#include <functional>
#include <memory>
#include <typeindex>
#include <unordered_map>

// One MC of protocol 3 (apps/server-ex lib/hal_c2/web/protocol.ex): hello,
// the shell shape, and `orchestration.dispatchCommand`, which it records and
// answers (or refuses, or holds until told to answer). Any other call is
// answered with null unless a domain handles it.
//
// A domain's fake lives with its steps: an Extension registers its RPC and
// shape handlers on every new MC, and keeps its state in a part:
//
//   namespace {
//   struct FakeGit { QList<QJsonObject> calls; };
//   const FakeMc::Extension git([](FakeMc& MC) {
//     mc.onRpc(QStringLiteral("git."), [&mc](const FakeMc::Rpc& rpc) {
//       mc.part<FakeGit>().calls.append(rpc.payload);
//       mc.reply(rpc, QJsonValue::Null);
//     });
//   });
//   }  // namespace
class FakeMc : public QObject {
public:
  struct Rpc {
    int id = 0;
    QString method;
    QJsonObject payload;
    // The connection it came on; an answer to a dropped one is not sent.
    QPointer<QWebSocket> socket;
    // The environment it is for ("" for the MC's own).
    QString environment;
  };
  using RpcHandler = std::function<void(const Rpc& rpc)>;
  // `id` is the subscription's; the shape is live until unsubscribed, forgotten
  // or the connection drops.
  using ShapeHandler = std::function<void(int id, const QJsonObject& shape)>;

  // A `POST` to the MC's HTTP API: `respond(status, body)` answers it.
  using HttpHandler = std::function<void(const QJsonObject& body, std::function<void(int status, const QJsonObject& answer)> respond)>;

  struct Extension {
    explicit Extension(void (*extend)(FakeMc& mc));
  };

  FakeMc();

  QUrl origin() const { return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(m_port)); }

  // `method` is exact, or a namespace ("cluster." takes every `cluster.*`
  // call); an exact match wins.
  void onRpc(const QString& method, RpcHandler handler);
  void onShape(const QString& type, ShapeHandler handler);
  // Hands a call an exact handler does not take to its namespace's handler,
  // when two domains fake one method for different callers.
  void passOn(const Rpc& rpc);
  // `path` is exact ("/api/pull-requests/diff"); an unknown one is a 404.
  void onHttp(const QString& path, HttpHandler handler) { m_httpHandlers.insert(path, std::move(handler)); }
  // Any request under `prefix` ("/api/device-hub/"), HTTP or a socket's
  // handshake: the handler gets the connection with the request unread
  // (`head` is its request line and headers) and answers it itself, or hands
  // it to a QWebSocketServer of its own.
  using RawHandler = std::function<void(QTcpSocket* socket, const QByteArray& head)>;
  void onRaw(const QString& prefix, RawHandler handler) { m_rawHandlers.insert(prefix, std::move(handler)); }

  void send(const QJsonObject& frame);
  // Whether the call came on the connection still open.
  bool current(const Rpc& rpc) const { return rpc.socket == m_socket; }
  void reply(const Rpc& rpc, const QJsonValue& result);
  // An `rpc.error`, with `detail` when given.
  void refuse(const Rpc& rpc, const QString& message, const QJsonObject& detail = {});
  // Live subscriptions to the shape type, oldest first.
  QList<int> subscribers(const QString& type) const;
  QJsonObject shapeOf(int id) const { return m_live.value(id); }
  // A subscription the MC turned down, which gets nothing more.
  void forget(int id) { m_live.remove(id); }

  // Named holds say which answers wait: `answers` holds commands and terminal
  // calls; a domain may hold its own. Held answers are deferred until
  // answerHeld(), which lifts every hold.
  void hold(const QString& what) { m_holds.insert(what); }
  bool holding(const QString& what) const { return m_holds.contains(what); }
  void defer(std::function<void()> answer) { m_held.append(std::move(answer)); }
  void answerHeld();

  // A domain's state on this MC, made on first use.
  template <class T>
  T& part() {
    std::shared_ptr<void>& slot = m_parts[std::type_index(typeid(T))];
    if (!slot) slot = std::make_shared<T>();
    return *static_cast<T*>(slot.get());
  }

  QString name = QStringLiteral("mc-a");
  QString environmentId = QStringLiteral("env-a");
  // The MC's environment's label, when it has one ("This machine" otherwise).
  QString label;
  QMap<QString, QJsonObject> threads;
  QMap<QString, QJsonObject> projects;
  QList<QUrl> connections;
  // Every `sub` frame, in order.
  QList<QJsonObject> subscriptions;
  QList<QJsonObject> commands;
  QHash<QString, QString> refusals;
  // What an accepted command does to the MC's rows (the real MC's
  // projection), run before it is answered.
  QList<std::function<void(const QJsonObject& command)>> effects;
  // Checkouts whose whole status a domain fakes, by folder: the `vcs`
  // snapshot (`local`, `remote`) the workspace's `vcs` shape sends for them.
  QHash<QString, std::function<QJsonObject()>> checkouts;
  QJsonObject capabilities{
      {QStringLiteral("threadSettlement"), true},
      {QStringLiteral("threadSnooze"), true},
      {QStringLiteral("threadVisitedTracking"), true},
      {QStringLiteral("threadPinning"), true},
      {QStringLiteral("threadTitleRegeneration"), true},
      {QStringLiteral("pullRequests"), true},
      {QStringLiteral("threadPullRequests"), true},
      {QStringLiteral("threadPullRequestLinking"), true},
  };
  bool holdSnapshot = false;
  // Environments outside the cluster the MC is linked to (HalC2.Links), and
  // why a link is down ("unreachable", "refused"; absent while it is online).
  QStringList linked;
  QHash<QString, QString> linkProblems;
  // What each link's pairing granted, listed as its `scopes`; none listed when unset.
  QHash<QString, QStringList> linkScopes;
  // Each linked environment's label, when it is not its id.
  QHash<QString, QString> linkLabels;

  // Whether the shell was asked for with its links' rows (`"links": true`).
  bool shellLinks = false;
  // Each linked environment's own rows, by environment then id: [id, kind, row].
  // Its one MC is named as this MC is, since a linked environment's MC
  // names may collide with the cluster's.
  QHash<QString, QMap<QString, QJsonArray>> linkedRows;

  void sendSnapshot();
  // The MC pairs with an environment outside its cluster, announced as
  // `shell.links`; with links' rows, then its MC (offline until
  // `shell.linkMc`) and its rows follow as the MC's first follow of that
  // environment's shell brings them.
  void link(const QString& environment);
  void unlink(const QString& environment);
  // Announces the links as they now are.
  void sendLinks();
  // Another MC joins this one's cluster, announced as the shell announces it on nodeup.
  void join(const QString& peer, const QString& peerEnvironment);
  // The cluster member serving each environment that joined, by environment.
  QHash<QString, QString> peers;
  void sendRow(const QString& id, const QJsonObject& row, const QString& kind = QStringLiteral("thread"));
  // Rows of the cluster member `mc` as `shell.rows`: each [id, kind, fields].
  void sendRows(const QString& mc, const QJsonArray& rows);
  // A linked environment's row, kept and sent as `shell.linkRows`.
  void sendLinkRow(const QString& environment, const QString& id, const QJsonObject& row,
                   const QString& kind = QStringLiteral("thread"));
  // A link goes down (`problem`, e.g. "unreachable") or comes back (empty):
  // `shell.links` says so, and its MC goes offline or online.
  void setLinkProblem(const QString& environment, const QString& problem);

  void drop() {
    if (m_socket) m_socket->close();
  }
  void stopAccepting() { m_tcp.close(); }

private:
  void accept();
  // A new connection: an HTTP `POST` is answered here, anything else is the socket's.
  void route(QTcpSocket* socket);
  void answerHttp(QTcpSocket* socket, const QByteArray& request);
  void onMessage(QWebSocket* socket, const QString& text);
  void dispatchCommand(const Rpc& rpc);
  QJsonArray links() const;
  QJsonObject linkedEnvironment(const QString& environment) const;
  QJsonObject unreachable(const QString& environment) const;
  void sendLinkFrame(const QString& type, const QString& environment, QJsonObject frame);

  // Listens for both: the socket's handshakes go on to m_server.
  QTcpServer m_tcp;
  QWebSocketServer m_server;
  QHash<QString, HttpHandler> m_httpHandlers;
  QHash<QString, RawHandler> m_rawHandlers;
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
