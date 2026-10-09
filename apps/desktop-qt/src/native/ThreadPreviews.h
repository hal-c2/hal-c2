#pragma once

#include <QAbstractListModel>
#include <QJsonObject>
#include <QSet>
#include <QString>
#include <QUrl>

#include <functional>

class McClient;

// The Previews tab: a thread's browser tabs as the MC keeps them
// (`preview.list`), each opened in the user's browser rather than embedded.
// While shown it follows the MC's `preview` events (the MC serving the
// thread's environment).
//
// close(tabId) is `preview.close`: the row goes at once and stays gone while
// the close is in flight; a close that fails brings it back where it was.
//
// newTab() is `preview.open` with no address: an empty tab the user fills
// from `suggestions`, as the web's empty browser tab offers: the web servers
// listening on the MC's machine (its `localServers` shape, followed only
// while the list shows), the project's configured preview addresses and the
// pages this device opened last. navigate(tabId, url) is `preview.navigate`,
// and opens the page in the browser.
class ThreadPreviews : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
  // idle, loading, ready or failed: the list itself, not its tabs.
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QString message READ message NOTIFY statusChanged)
  // What an empty tab offers: [{url, label, kind}], kind "server",
  // "configured" or "recent"; each address once.
  Q_PROPERTY(QVariantList suggestions READ suggestions NOTIFY suggestionsChanged)
  // The first tab with no page yet (what `suggestions` would fill), or "".
  Q_PROPERTY(QString emptyTab READ emptyTab NOTIFY emptyTabChanged)

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
  // The pages this device opened last, newest first: read, and written.
  using Recents = std::function<QStringList()>;
  using Remember = std::function<void(const QStringList& urls)>;
  static constexpr int maxRecents = 10;

  ThreadPreviews(McClient* client, Notify notify, Open open, QObject* parent = nullptr);
  ~ThreadPreviews() override;

  // The thread shown, and the MC whose events carry its tabs (empty when
  // none does).
  void setThread(const QString& environmentId, const QString& threadId, const QString& mc);
  // Loads and follows while shown; forgets nothing when hidden.
  void setActive(bool active);
  // The preview addresses the thread's project configures (its scripts' previewUrl).
  void setConfigured(const QStringList& urls);
  void setRecents(Recents read, Remember write);
  QVariantList suggestions() const;
  QString emptyTab() const;

  QString status() const { return m_status; }
  QString message() const { return m_message; }

  Q_INVOKABLE void reload();
  // Opens the tab's page in the browser.
  Q_INVOKABLE void open(const QString& tabId);
  Q_INVOKABLE void close(const QString& tabId);
  // An empty tab on the MC.
  Q_INVOKABLE void newTab();
  // Points the tab at `url` and opens the page in the browser.
  Q_INVOKABLE void navigate(const QString& tabId, const QString& url);

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void countChanged();
  void statusChanged();
  void suggestionsChanged();
  void emptyTabChanged();

private:
  void follow();
  void unfollow();
  void onEvent(const QJsonObject& event);
  void setStatus(const QString& status, const QString& message = {});
  int rowOf(const QString& tabId) const;
  void upsert(const QJsonObject& snapshot);
  void remove(const QString& tabId);

  McClient* m_client;
  Notify m_notify;
  Open m_open;
  QString m_environment;
  QString m_thread;
  QString m_mc;
  bool m_active = false;
  int m_subscription = -1;
  // Replies for another thread (or an older load) are dropped.
  int m_generation = 0;
  QString m_epoch;
  qint64 m_revision = -1;
  QList<QJsonObject> m_rows;
  // Tabs being closed: their events do not bring them back.
  QSet<QString> m_closing;
  // A list is on its way; the thread's events since it was asked for, which it may predate.
  bool m_listing = false;
  QList<QJsonObject> m_early;
  int m_servers = -1;
  // The MC's machine's web servers: {url, processName}.
  QList<QJsonObject> m_serverList;
  QStringList m_configured;
  Recents m_readRecents;
  Remember m_writeRecents;
  QString m_status = QStringLiteral("idle");
  QString m_message;
};
