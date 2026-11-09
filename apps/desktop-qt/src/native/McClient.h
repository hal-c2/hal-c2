#pragma once

#include <QHash>
#include <QJsonObject>
#include <QJsonValue>
#include <QList>
#include <QNetworkRequest>
#include <QDateTime>
#include <QElapsedTimer>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QUrl>

#include <functional>
#include <optional>

class QNetworkAccessManager;
class QWebSocket;

// The shell's own protocol-3 connection to its MC (apps/server-ex
// lib/hal_c2/web/protocol.ex).
// Subscriptions are multiplexed by id, sent once the MC says hello, and
// sent again after every reconnect or `resync`: from where their owner says
// they had got to (Resume), or whole.
//
// One owner of retries. Before each socket it reads the MC's descriptor
// (`/.well-known/hal-c2/environment`) and stays blocked on a protocol it does
// not speak. A socket that drops, or is not said hello to in time, is retried
// with growing delays, which start over once a connection has held; without a
// network it waits for one, and a credential the MC refuses waits for the
// user (phase()). An address that answers as another environment than the
// one it was opened for is not used. The MC's own access token opens the socket as `?token=`; a
// paired session's token does not, so a handshake that fails asks the MC for a
// socket ticket (`/api/auth/websocket-ticket`): it either gets one and opens
// with `?wsTicket=` from then on, or learns from the MC's answer whether the
// credential is refused, the connection blocked, or the MC worth retrying.
// wake() tries again whatever it waits for, and checks a connection that looks
// healthy: one that does not answer in time is replaced at once.
class McClient : public QObject {
  Q_OBJECT

public:
  // The protocol this client speaks (apps/server-ex HalC2.Web.Protocol).
  static constexpr int kProtocol = 3;
  enum class Phase {
    Closed,      // never opened, or closed
    Connecting,  // reading the descriptor, opening the socket, waiting for hello
    Ready,       // the MC said hello
    Retrying,    // dropped or unreachable: the next attempt is scheduled (retryDelay)
    Offline,     // this device has no network: waits for it
    Refused,     // the MC refuses the credential: waits for the user to pair again
    Blocked,     // the MC speaks another protocol (blockedProtocol), is another environment, or turned the
                 // credential away for good (failureMessage): retried only when asked
  };
  using FrameHandler = std::function<void(const QJsonObject& frame)>;
  // What a `sub` frame carries besides its shape: a stream's `offset`,
  // `handle` and `window`, the shell's `have`. Asked each time the frame is
  // sent, so whoever holds the data is the one to say where it continues.
  using Resume = std::function<QJsonObject()>;
  // `error` is set when the call failed: the MC's message, or "not connected"
  // / "disconnected" when the socket was not there to carry it. A cluster
  // member the MC cannot reach is "<name> is not connected." (environmentNames).
  using Reply = std::function<void(const QJsonValue& result, const std::optional<QString>& error)>;
  // Whether `error` says the MC could not reach the cluster member the call
  // was for (the call never got there), however it was worded for the user.
  static bool unreachable(const QString& error);

  explicit McClient(QObject* parent = nullptr);
  ~McClient() override;

  // `origin` is the MC's http(s) origin; the token is its access token.
  // `environment` is the environment it must serve; when empty, the one its
  // first descriptor names is.
  void open(const QUrl& origin, const QString& token, const QString& environment = {});
  void close();
  // Drops the socket and connects again, to the same environment.
  void reconnect() {
    const QUrl origin = m_origin;
    const QString token = m_token;
    const QString environment = m_expectedEnvironment;
    close();
    open(origin, token, environment);
  }
  bool isReady() const { return m_ready; }
  Phase phase() const { return m_phase; }
  // Why the last connection ended or could not be made ("timeout", "closed",
  // or the socket's own words); empty while none has failed since it was ready.
  QString failure() const { return m_failure; }
  // What the last failure means to the user, when the MC said more than that
  // it was unreachable ("The environment credential is invalid."); empty
  // otherwise.
  QString failureMessage() const { return m_failureMessage; }
  // The W3C trace id of the attempt that failed, sent as `traceparent` with
  // its requests; empty when none failed.
  QString failureTraceId() const { return m_failureTraceId; }
  // The delay before the scheduled retry, in ms (Phase::Retrying).
  int retryDelay() const { return m_retryDelay; }
  // The protocol the MC's descriptor declares, when it blocks the connection.
  int blockedProtocol() const { return m_blockedProtocol; }
  // The MC's descriptor as last read (label, serverVersion, ...).
  QJsonObject descriptor() const { return m_descriptor; }
  // Whether this device has a network. Offline, a drop is not retried until
  // the network is back.
  void setOnline(bool online);
  // The app came to the foreground: a waiting, refused or blocked connection is
  // tried now, and a ready one is checked (checked()) and replaced at once if
  // it does not answer within probeTimeout().
  void wake();
  // Tries again now, whatever it was waiting for.
  void retryNow();
  // The http(s) origin the MC was opened at.
  QUrl origin() const { return m_origin; }
  QString mc() const { return m_mc; }
  // The environment the MC itself serves, for calls about the MC (its
  // cluster); empty until the first hello.
  QString environment() const { return m_environment; }
  // Names an environment for the user, for a call to one the MC cannot reach.
  using Names = std::function<QString(const QString& environment)>;
  void setEnvironmentNames(Names names) { m_names = std::move(names); }
  // The client serving `environment`, or the cluster MC `mc`, when it is not
  // this one: the saved environments the shell connects to beside its own
  // (SavedEnvironments) each have a client. Calls and subscriptions addressed
  // to one of theirs go there, so callers hold one client whichever
  // environment they talk to. Asked once per call and per subscription.
  using Route = std::function<McClient*(const QString& environment, const QString& mc)>;
  void setRoute(Route route) { m_route = std::move(route); }

  // When the credential runs out; invalid when it does not, or is not known
  // (the desktop's own MC). An HTTP request made within renewWithin() of then
  // renews it first (`/api/auth/session/renew`): the socket is not touched,
  // and a renewal that fails fails only the request that needed it.
  void setCredentialExpiry(const QDateTime& expiresAt) { m_expiresAt = expiresAt; }
  QDateTime credentialExpiry() const { return m_expiresAt; }
  void setRenewWithin(qint64 ms) { m_renewWithinMs = ms; }
  qint64 renewWithin() const { return m_renewWithinMs; }

  // `context` owns the callback, as with a Qt connection: once it is destroyed
  // no reply or frame reaches it, and its subscriptions are ended.
  // Without `resume` the shape is asked for whole each time.
  int subscribe(QObject* context, const QJsonObject& shape, FrameHandler onFrame, Resume resume = {});
  void unsubscribe(int id);
  // Asks a windowed stream for the runs before its window that hold `items`
  // turn items; a `page` frame answers.
  void more(int id, int items);
  // Says how far of a subscription that asked for `acks` has been consumed.
  void ack(int id, qint64 sequence);
  void call(QObject* context, const QString& environment, const QString& method, const QJsonValue& payload, Reply reply);
  // POSTs `body` to `path` of the MC's origin (its HTTP API, for answers too
  // large for the socket, as `/api/pull-requests/diff`), with the access token.
  // A refusal's `error` is the body's `message`, `detail` or `_tag`, else the
  // HTTP status; `result` is then the body.
  void post(QObject* context, const QString& path, const QJsonObject& body, Reply reply);
  // POSTs `bytes` to a signed URL the MC handed out (`relativeUrl`, as
  // `attachments.createUploadUrl`'s): the URL is its own authorization.
  void upload(QObject* context, const QString& relativeUrl, const QByteArray& bytes, const QString& mimeType, Reply reply,
              std::function<void(qint64 sent, qint64 total)> progress = {});
  // GETs a signed URL the MC handed out (`assets.createUrl`'s `relativeUrl`)
  // and gives its bytes, or why it could not be read.
  using Bytes = std::function<void(const QByteArray& bytes, const std::optional<QString>& error)>;
  void download(QObject* context, const QString& relativeUrl, Bytes reply);
  // A request for `path` (and `query`), both percent-encoded, on the MC's
  // origin carrying the access token, for streams the socket does not carry (a device's screen
  // through /api/device-hub). `socket`: its ws(s) twin, for a QWebSocket.
  QNetworkRequest request(const QString& path, const QString& query = {}, bool socket = false) const;
  // `orchestration.dispatchCommand` with a fresh commandId.
  void dispatchCommand(QObject* context, const QString& environment, QJsonObject command, Reply reply);

  void setRetryDelays(const QList<int>& delaysMs) { m_retryDelaysMs = delaysMs; }
  QList<int> retryDelays() const { return m_retryDelaysMs; }
  // How often a ready connection pings the MC, so a quiet one is kept alive.
  void setPingInterval(int ms) { m_pingTimer.setInterval(ms); }
  int pingInterval() const { return m_pingTimer.interval(); }
  // How long a ping may go unanswered before the connection counts as dead.
  void setPongTimeout(int ms) { m_pongTimer.setInterval(ms); }
  int pongTimeout() const { return m_pongTimer.interval(); }
  // How long wake()'s check may go unanswered before the connection is replaced.
  void setProbeTimeout(int ms) { m_probeTimer.setInterval(ms); }
  int probeTimeout() const { return m_probeTimer.interval(); }
  // How long an open socket may go without the MC's hello before it is dropped.
  void setSetupTimeout(int ms) { m_setupTimer.setInterval(ms); }
  int setupTimeout() const { return m_setupTimer.interval(); }
  // How long a connection must hold before the retry delays start over; set
  // while one is holding, it counts from then.
  void setSteadyAfter(int ms) { m_heldTimer.setInterval(ms); }
  int steadyAfter() const { return m_heldTimer.interval(); }

signals:
  void readyChanged(bool ready);
  void phaseChanged();
  // A ping was answered (`alive`), or was not in time and the socket is replaced.
  void checked(bool alive);
  // A call went out as `id`, and later was answered or failed (the slow
  // requests warning, SlowRequestController).
  void callStarted(int id, const QString& environment, const QString& method);
  void callEnded(int id);
  // The credential was renewed and runs out at `expiresAt` now.
  void credentialRenewed(const QDateTime& expiresAt);

private:
  void connectSocket();
  void openSocket(const QString& ticket = {});
  // Asks the MC for a socket ticket and opens with it; a credential it does
  // not know is refused, and anything else is retried.
  void openWithTicket();
  void requestTicket();
  // The other client `environment` or `mc` is routed to; null for this one.
  McClient* routed(const QString& environment, const QString& mc) const;
  // Whether the credential runs out within renewWithin().
  bool renewalDue() const;
  // Renews the credential, then says whether it could (nothing) or why not.
  void renew(std::function<void(const std::optional<QString>& error)> done);
  void sendPost(QObject* context, const QString& path, const QJsonObject& body, Reply reply);
  void ping();
  void drop(const QString& reason);
  void failed(const QString& reason, bool wasReady);
  void scheduleRetry();
  // Stops at `phase` (Refused or Blocked) for what the MC said: no retry mends it.
  void stop(Phase phase, const QString& message);
  void setPhase(Phase phase);
  void onMessage(const QString& text);
  void onClosed(QWebSocket* socket);
  // Answers every call in flight with "disconnected".
  void failCalls();
  void sendSub(int id);
  void send(const QJsonObject& message);

  struct Subscription {
    QJsonObject shape;
    FrameHandler onFrame;
    // Ends the subscription when its context goes.
    QMetaObject::Connection contextGone;
    Resume resume;
  };
  struct Call {
    QPointer<QObject> context;
    Reply reply;
    QString environment;
  };
  void endSubscription(int id);

  QUrl m_origin;
  QUrl m_url;
  QString m_token;
  QNetworkAccessManager* m_http = nullptr;
  QPointer<QWebSocket> m_socket;
  QHash<int, Subscription> m_subscriptions;
  QHash<int, Call> m_calls;
  QList<int> m_retryDelaysMs{500, 1000, 2000, 4000, 8000};
  QTimer m_retryTimer;
  QTimer m_pingTimer;
  QTimer m_pongTimer;
  QTimer m_setupTimer;
  QTimer m_heldTimer;
  QTimer m_probeTimer;
  QElapsedTimer m_readySince;
  Phase m_phase = Phase::Closed;
  QString m_failure;
  QString m_failureMessage;
  // The environment the MC must serve.
  QString m_expectedEnvironment;
  Names m_names;
  Route m_route;
  // Subscriptions another client carries: this client's id → that one's.
  QHash<int, std::pair<QPointer<McClient>, int>> m_forwarded;
  QDateTime m_expiresAt;
  qint64 m_renewWithinMs = 24LL * 60 * 60 * 1000;
  // Who waits on the renewal in flight; empty while none is.
  QList<std::function<void(const std::optional<QString>&)>> m_renewing;
  QString m_traceId;
  QString m_failureTraceId;
  // Why the socket is being dropped from this side ("timeout").
  QString m_dropReason;
  QJsonObject m_descriptor;
  int m_retryDelay = 0;
  int m_blockedProtocol = 0;
  // Bumped by every attempt: an answer to an older one is ignored.
  quint64 m_generation = 0;
  bool m_online = true;
  // The token is a paired session's: every socket needs a ticket.
  bool m_ticketed = false;
  QString m_mc;
  QString m_environment;
  int m_nextId = 1;
  int m_attempt = 0;
  bool m_ready = false;
  bool m_closed = true;
};
