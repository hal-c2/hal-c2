#pragma once

#include <QHash>
#include <QJsonObject>
#include <QJsonValue>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QUrl>

#include <functional>
#include <optional>

class QNetworkAccessManager;
class QWebSocket;

// The shell's own protocol-3 connection to its node (apps/server-ex
// lib/hal_c2/web/protocol.ex), the C++ twin of client-runtime's ClusterSocket.
// Subscriptions are multiplexed by id, sent once the node says hello, and
// sent again after every reconnect or `resync`. The page keeps its own
// connection; this one carries what the shell's chrome owns.
class NodeClient : public QObject {
  Q_OBJECT

public:
  using FrameHandler = std::function<void(const QJsonObject& frame)>;
  // `error` is set when the call failed: the node's message, or "not connected"
  // / "disconnected" when the socket was not there to carry it.
  using Reply = std::function<void(const QJsonValue& result, const std::optional<QString>& error)>;

  explicit NodeClient(QObject* parent = nullptr);
  ~NodeClient() override;

  // `origin` is the node's http(s) origin; the token is its access token.
  void open(const QUrl& origin, const QString& token);
  void close();
  bool isReady() const { return m_ready; }
  // The http(s) origin the node was opened at.
  QUrl origin() const { return m_origin; }
  QString node() const { return m_node; }
  // The environment the node itself serves, for calls about the node (its
  // cluster); empty until the first hello.
  QString environment() const { return m_environment; }

  int subscribe(const QJsonObject& shape, FrameHandler onFrame);
  void unsubscribe(int id);
  void call(const QString& environment, const QString& method, const QJsonValue& payload, Reply reply);
  // POSTs `body` to `path` of the node's origin (its HTTP API, for answers too
  // large for the socket, as `/api/pull-requests/diff`), with the access token.
  // A refusal's `error` is the body's `message`, `detail` or `_tag`, else the
  // HTTP status; `result` is then the body.
  void post(const QString& path, const QJsonObject& body, Reply reply);
  // `orchestration.dispatchCommand` with a fresh commandId.
  void dispatchCommand(const QString& environment, QJsonObject command, Reply reply);

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
  };

  QUrl m_origin;
  QUrl m_url;
  QString m_token;
  QNetworkAccessManager* m_http = nullptr;
  QPointer<QWebSocket> m_socket;
  QHash<int, Subscription> m_subscriptions;
  QHash<int, Reply> m_calls;
  QList<int> m_retryDelaysMs{500, 1000, 2000, 4000, 8000};
  QTimer m_retryTimer;
  QTimer m_pingTimer;
  QString m_node;
  QString m_environment;
  int m_nextId = 1;
  int m_attempt = 0;
  bool m_ready = false;
  bool m_closed = true;
};
