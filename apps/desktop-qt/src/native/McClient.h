#pragma once

#include <QHash>
#include <QJsonObject>
#include <QJsonValue>
#include <QList>
#include <QNetworkRequest>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QUrl>

#include <functional>
#include <optional>

class QNetworkAccessManager;
class QWebSocket;

// The shell's own protocol-3 connection to its MC (apps/server-ex
// lib/hal_c2/web/protocol.ex), the C++ twin of client-runtime's ClusterSocket.
// Subscriptions are multiplexed by id, sent once the MC says hello, and
// sent again after every reconnect or `resync`.
class McClient : public QObject {
  Q_OBJECT

public:
  using FrameHandler = std::function<void(const QJsonObject& frame)>;
  // `error` is set when the call failed: the MC's message, or "not connected"
  // / "disconnected" when the socket was not there to carry it.
  using Reply = std::function<void(const QJsonValue& result, const std::optional<QString>& error)>;

  explicit McClient(QObject* parent = nullptr);
  ~McClient() override;

  // `origin` is the MC's http(s) origin; the token is its access token.
  void open(const QUrl& origin, const QString& token);
  void close();
  // Drops the socket and connects again, as reloading the web app does.
  void reconnect() {
    const QUrl origin = m_origin;
    const QString token = m_token;
    close();
    open(origin, token);
  }
  bool isReady() const { return m_ready; }
  // The http(s) origin the MC was opened at.
  QUrl origin() const { return m_origin; }
  QString mc() const { return m_mc; }
  // The environment the MC itself serves, for calls about the MC (its
  // cluster); empty until the first hello.
  QString environment() const { return m_environment; }

  // `context` owns the callback, as with a Qt connection: once it is destroyed
  // no reply or frame reaches it, and its subscriptions are ended.
  int subscribe(QObject* context, const QJsonObject& shape, FrameHandler onFrame);
  void unsubscribe(int id);
  void call(QObject* context, const QString& environment, const QString& method, const QJsonValue& payload, Reply reply);
  // POSTs `body` to `path` of the MC's origin (its HTTP API, for answers too
  // large for the socket, as `/api/pull-requests/diff`), with the access token.
  // A refusal's `error` is the body's `message`, `detail` or `_tag`, else the
  // HTTP status; `result` is then the body.
  void post(QObject* context, const QString& path, const QJsonObject& body, Reply reply);
  // POSTs `bytes` to a signed URL the MC handed out (`relativeUrl`, as
  // `attachments.createUploadUrl`'s): the URL is its own authorization.
  void upload(QObject* context, const QString& relativeUrl, const QByteArray& bytes, const QString& mimeType, Reply reply);
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
  void setPingInterval(int ms) { m_pingTimer.setInterval(ms); }

signals:
  void readyChanged(bool ready);

private:
  void connectSocket();
  void onMessage(const QString& text);
  void onClosed(QWebSocket* socket);
  void sendSub(int id);
  void send(const QJsonObject& message);

  struct Subscription {
    QJsonObject shape;
    FrameHandler onFrame;
    // Ends the subscription when its context goes.
    QMetaObject::Connection contextGone;
  };
  struct Call {
    QPointer<QObject> context;
    Reply reply;
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
  QString m_mc;
  QString m_environment;
  int m_nextId = 1;
  int m_attempt = 0;
  bool m_ready = false;
  bool m_closed = true;
};
