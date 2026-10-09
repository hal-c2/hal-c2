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
// The shell's rows carry versions as the MC's do (lib/hal_c2/shell.ex): each
// MC's rows are at [`epoch`, rev], and a `sub` whose `have` names the version
// the client was last told is answered with the rows changed since, any other
// with all of them, marked `reset`.
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
  // A client frame the MC itself does not read (`more`).
  using FrameHandler = std::function<void(const QJsonObject& frame)>;

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
  void onFrame(const QString& type, FrameHandler handler) { m_frames.insert(type, std::move(handler)); }
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
  // Whether a client's socket is open: a frame sent now reaches it.
  bool connected() const { return m_socket && m_socket->state() == QAbstractSocket::ConnectedState; }
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
  // Lifts every hold and forgets the held answers: what they answer never
  // reached the MC.
  void dropHeld() {
    m_holds.clear();
    m_held.clear();
  }

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
  // Every `shell` frame it answered one with, in order.
  QList<QJsonObject> shellFrames;
  // Names this run of the MC's shell: after a restart (another epoch) what a
  // client holds of its rows is of no use.
  QString epoch = QStringLiteral("epoch-1");
  // False for an MC from before rows had versions: its frames carry none.
  bool versioned = true;
  QList<QJsonObject> commands;
  // The environment each of `commands` was sent to ("" for the MC's own).
  QStringList commandEnvironments;
  // Every call, in order, whoever answers it.
  QList<Rpc> calls;
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
      {QStringLiteral("threadPinReorder"), true},
      {QStringLiteral("threadActiveReorder"), true},
      {QStringLiteral("threadTitleRegeneration"), true},
      {QStringLiteral("pullRequests"), true},
      {QStringLiteral("threadPullRequests"), true},
      {QStringLiteral("threadPullRequestLinking"), true},
  };
  bool holdSnapshot = false;
  bool answerPings = true;  // false: the MC has stopped answering, its socket still open
  // The cluster's other members, in the order they joined, and the MC serving
  // each environment.
  QStringList members;
  QHash<QString, QString> peers;
  // A member's label, when its environment has one.
  QHash<QString, QString> peerLabels;
  // Members whose MC is down: their rows stay, and requests for them fail.
  QSet<QString> offline;
  // Each member's rows, by environment then id: [id, kind, row].
  QHash<QString, QMap<QString, QJsonArray>> peerRows;

  void sendSnapshot();
  // Another MC joins this one's cluster, announced as the shell announces it
  // on nodeup: its environment, whether it is online, and its rows.
  void join(const QString& peer, const QString& peerEnvironment);
  // The same for a machine known by one name, its environment's id and label.
  void join(const QString& name) {
    peerLabels.insert(name, name);
    join(QStringLiteral("mc-") + name, name);
  }
  void sendRow(const QString& id, const QJsonObject& row, const QString& kind = QStringLiteral("thread"));
  // Rows of the cluster member `mc` as `shell.rows`: each [id, kind, fields].
  void sendRows(const QString& mc, const QJsonArray& rows);
  // A frame of the shell subscription as given, its id added: what a
  // misbehaving MC sends.
  void sendShell(QJsonObject frame);
  // A member's row, kept and sent as its `shell.rows` once it has joined.
  void sendPeerRow(const QString& environment, const QString& id, const QJsonObject& row,
                   const QString& kind = QStringLiteral("thread"));
  // A member's MC goes down or comes back (`shell.mc`).
  void setOnline(const QString& environment, bool online);
  // A member is removed from the cluster: the shell drops it and its rows
  // (`shell.mc` with `removed`).
  void remove(const QString& environment);

  // Closes the client's connection: from here on it is sent nothing and
  // nothing it says is read, whatever the socket still does on its way out.
  void drop();
  void stopAccepting() { m_tcp.close(); }
  void startAccepting() { m_tcp.listen(QHostAddress::LocalHost, m_port); }

private:
  void accept();
  // A new connection: an HTTP `POST` is answered here, anything else is the socket's.
  void route(QTcpSocket* socket);
  void answerHttp(QTcpSocket* socket, const QByteArray& request);
  void onMessage(QWebSocket* socket, const QString& text);
  void dispatchCommand(const Rpc& rpc);
  QJsonObject peerEnvironment(const QString& environment) const;
  // The MC's rows as they are now, by id: [id, kind, row].
  QMap<QString, QJsonArray> rowsOf(const QString& mc) const;
  // One MC of a `shell` frame, and its rows the client lacks appended to `rows`.
  QJsonObject shellMc(const QString& mc, bool online, const QJsonObject& environment, QJsonArray& rows);
  // The member a request is for, when its MC is down.
  bool down(const QString& environment, const QString& mc) const;

  // Listens for both: the socket's handshakes go on to m_server.
  QTcpServer m_tcp;
  QWebSocketServer m_server;
  QHash<QString, HttpHandler> m_httpHandlers;
  QHash<QString, RawHandler> m_rawHandlers;
  quint16 m_port = 0;
  QPointer<QWebSocket> m_socket;
  int m_shellSubscription = -1;
  // The `have` of the shell subscription being answered.
  QJsonObject m_have;
  // What the client was last told of each MC's rows, and the rev that made.
  struct Told {
    int rev = 0;
    QMap<QString, QJsonArray> rows;
  };
  QHash<QString, Told> m_told;
  QHash<QString, FrameHandler> m_frames;
  QMap<int, QJsonObject> m_live;
  QHash<QString, RpcHandler> m_rpc;
  QHash<QString, ShapeHandler> m_shapes;
  QSet<QString> m_holds;
  QList<std::function<void()>> m_held;
  std::unordered_map<std::type_index, std::shared_ptr<void>> m_parts;
};
