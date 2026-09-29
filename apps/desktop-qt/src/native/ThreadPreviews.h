#pragma once

#include <QAbstractListModel>
#include <QJsonObject>
#include <QSet>
#include <QString>
#include <QUrl>

#include <functional>

class NodeClient;

// The Previews tab: a thread's browser tabs as the node keeps them
// (`preview.list`), each opened in the user's browser rather than embedded.
// While shown it follows the node's `preview` events (the node serving the
// thread's environment; a linked environment's list is read again on show
// and on reload()).
//
// close(tabId) is `preview.close`: the row goes at once and stays gone while
// the close is in flight; a close that fails brings it back where it was.
class ThreadPreviews : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
  // idle, loading, ready or failed: the list itself, not its tabs.
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QString message READ message NOTIFY statusChanged)

public:
  enum Role {
    TabIdRole = Qt::UserRole + 1,
    UrlRole,
    // The page's title, or its URL while it has none.
    TitleRole,
    // idle, loading, loaded or failed.
    StatusRole,
    // Why the page failed to load, or empty.
    ProblemRole,
  };

  using Notify = std::function<void(const QString& type, const QString& title, const QString& description)>;
  using Open = std::function<void(const QUrl& url)>;

  ThreadPreviews(NodeClient* client, Notify notify, Open open, QObject* parent = nullptr);
  ~ThreadPreviews() override;

  // The thread shown, and the node whose events carry its tabs (empty when
  // none does).
  void setThread(const QString& environmentId, const QString& threadId, const QString& node);
  // Loads and follows while shown; forgets nothing when hidden.
  void setActive(bool active);

  QString status() const { return m_status; }
  QString message() const { return m_message; }

  Q_INVOKABLE void reload();
  // Opens the tab's page in the browser.
  Q_INVOKABLE void open(const QString& tabId);
  Q_INVOKABLE void close(const QString& tabId);

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void countChanged();
  void statusChanged();

private:
  void follow();
  void unfollow();
  void onEvent(const QJsonObject& event);
  void setStatus(const QString& status, const QString& message = {});
  int rowOf(const QString& tabId) const;
  void upsert(const QJsonObject& snapshot);
  void remove(const QString& tabId);

  NodeClient* m_client;
  Notify m_notify;
  Open m_open;
  QString m_environment;
  QString m_thread;
  QString m_node;
  bool m_active = false;
  int m_subscription = -1;
  // Replies for another thread (or an older load) are dropped.
  int m_generation = 0;
  QString m_epoch;
  qint64 m_revision = -1;
  QList<QJsonObject> m_rows;
  // Tabs being closed: their events do not bring them back.
  QSet<QString> m_closing;
  QString m_status = QStringLiteral("idle");
  QString m_message;
};
