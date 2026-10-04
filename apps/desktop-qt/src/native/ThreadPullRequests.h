#pragma once

#include <QAbstractListModel>
#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QUrl>

#include <functional>
#include <optional>
#include <variant>

class McClient;
class ShellStore;

// The Pull requests tab: the pull requests linked to a thread, read from its
// shell row (`pullRequests`; dismissed stack layers hidden), so their state,
// checks and review follow the MC's sync as rows change. Nothing is loaded
// here: the MC's snapshots arrive with the row.
//
// Actions go to the thread's environment: link(text) takes a pull request URL
// or a number on the thread's own repository (`thread.pull-request.link`, as
// the user's), unlink(key) is its way back (`thread.pull-request.unlink`; a
// stack layer is dismissed instead), refresh() asks the MC to read every
// listed one from its host again (`pullRequests.invalidate`). While the
// environment is offline the rows stay as last synced and nothing is sent.
class ThreadPullRequests : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
  // Listed ones still open (or not yet read from their host).
  Q_PROPERTY(int openCount READ openCount NOTIFY rowsChanged)
  // The environment is reachable: linking, unlinking and refreshing are offered.
  Q_PROPERTY(bool online READ online NOTIFY stateChanged)
  // Why the text given to link() cannot be linked, or why linking failed.
  Q_PROPERTY(QString problem READ problem NOTIFY stateChanged)
  // What an environment too old to find a branch's pull request says instead.
  Q_PROPERTY(QString notice READ notice NOTIFY stateChanged)
  Q_PROPERTY(bool linking READ linking NOTIFY stateChanged)
  Q_PROPERTY(bool refreshing READ refreshing NOTIFY stateChanged)
  // The link field shows: the tab's Link button, or "Link pull request to
  // thread" from anywhere else.
  Q_PROPERTY(bool linkOpen READ linkOpen WRITE setLinkOpen NOTIFY stateChanged)

public:
  enum Role {
    // "host/repository#number"
    KeyRole = Qt::UserRole + 1,
    HostRole,
    RepositoryRole,
    NumberRole,
    UrlRole,
    TitleRole,
    // open, draft, merged, closed, or unknown until the host was read.
    StateRole,
    // Open, Draft, Merged, Closed or "Waiting for host state".
    StateLabelRole,
    // passing, failing, pending or empty.
    ChecksRole,
    ChecksLabelRole,
    // approved, changes-requested, review-required or empty.
    ReviewRole,
    ReviewLabelRole,
    ConflictingRole,
    AdditionsRole,
    DeletionsRole,
    AuthorRole,
    // "head → base", or empty.
    BranchesRole,
    // manual, created, agent or stack.
    SourceRole,
    // "Linked by you", "Created from this thread", ...
    SourceLabelRole,
    // "Unlink from thread", or "Dismiss from thread" for a stack layer.
    UnlinkLabelRole,
  };

  using Notify = std::function<void(const QString& type, const QString& title, const QString& description)>;
  using Open = std::function<void(const QUrl& url)>;

  ThreadPullRequests(McClient* client, ShellStore* store, Notify notify, Open open, QObject* parent = nullptr);

  // The thread shown ("<environment>:<thread id>"); reads its row again, so
  // it is also how a changed row lands. Rows only change when the links do.
  void setThread(const QString& threadKey);

  int count() const { return int(m_links.size()); }
  int openCount() const;
  bool online() const { return m_online; }
  QString problem() const { return m_problem; }
  QString notice() const;
  bool linking() const { return m_linking; }
  bool refreshing() const { return m_refreshing > 0; }
  bool linkOpen() const { return m_linkOpen; }
  void setLinkOpen(bool open);
  // The row of `key`, or -1.
  Q_INVOKABLE int indexOf(const QString& key) const;
  QVariant value(int row, int role) const { return data(index(row), role); }

  // Links what `text` names: a pull request URL (any repository on a host a
  // project of the environment reads) or 123 / #123 (the thread's project).
  Q_INVOKABLE void link(const QString& text);
  Q_INVOKABLE void unlink(const QString& key);
  Q_INVOKABLE void refresh();
  // Opens the pull request in the browser.
  Q_INVOKABLE void open(const QString& key);
  Q_INVOKABLE void copyLink(const QString& key);

  // What `text` names, as the link command wants it, or why it cannot be linked.
  struct Target {
    QString host;
    QString repository;
    int number = 0;
    QString url;
  };
  static std::optional<Target> parseUrl(const QString& url);
  std::variant<Target, QString> resolve(const QString& text) const;

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void countChanged();
  void rowsChanged();
  void stateChanged();

private:
  QString environmentId() const { return m_thread.left(m_thread.indexOf(QLatin1Char(':'))); }
  QString threadId() const { return m_thread.mid(m_thread.indexOf(QLatin1Char(':')) + 1); }
  const QJsonObject* find(const QString& key) const;
  void setProblem(const QString& problem);

  McClient* m_client;
  ShellStore* m_store;
  Notify m_notify;
  Open m_open;
  QString m_thread;
  QList<QJsonObject> m_links;
  bool m_online = false;
  QString m_problem;
  bool m_linking = false;
  int m_refreshing = 0;
  bool m_linkOpen = false;
};
