#pragma once

#include <QAbstractListModel>
#include <QDateTime>
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
// shell row (`pullRequests`), so their state, checks and review follow the
// MC's sync as rows change. Nothing is loaded here: the MC's snapshots arrive
// with the row. Rows come as the web's pullRequestListLines lays them out:
// stacks (the host's own, or links chained by base branch) bottom to top, the
// most recently active first. Dismissed stack layers are not rows; they are
// listed apart (`dismissed`) and linking one again brings it back.
//
// Actions go to the thread's environment: link(text) takes a pull request URL
// or a number on the thread's own repository (`thread.pull-request.link`, as
// the user's), unlink(key) is its way back (`thread.pull-request.unlink`; a
// stack layer is dismissed instead), refresh() asks the MC to read every
// listed one from its host again (`pullRequests.invalidate`). While the
// environment is offline the rows stay as last synced and nothing is sent.
//
// Under them the tab lists the open pull requests of the thread's project
// that are not linked (`projectOpen`, from `pullRequests.list`), read when
// the tab asks (loadProject()) and again on refresh(); each opens its review
// (RightPanelController's `rightPanel.reviewProject`) and can be linked.
class ThreadPullRequests : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
  // Listed ones still open (or not yet read from their host).
  Q_PROPERTY(int openCount READ openCount NOTIFY rowsChanged)
  // The environment is reachable: linking, unlinking and refreshing are offered.
  Q_PROPERTY(bool online READ online NOTIFY stateChanged)
  // Why the reference typed (or given to link()) cannot be linked, once the
  // user typed, or why linking it failed.
  Q_PROPERTY(QString problem READ problem NOTIFY stateChanged)
  // The link field's text; setting it is the user typing.
  Q_PROPERTY(QString reference READ reference WRITE setReference NOTIFY stateChanged)
  // `reference` names a pull request that can be linked now.
  Q_PROPERTY(bool canLink READ canLink NOTIFY stateChanged)
  // What `reference` links: "github.com/acme/shop #42", or empty.
  Q_PROPERTY(QString preview READ preview NOTIFY stateChanged)
  // The environment keeps several pull requests per thread; without it the
  // tab says the links are unavailable.
  Q_PROPERTY(bool available READ available NOTIFY stateChanged)
  // Stack layers dismissed from the thread: [{key, number, repository, title,
  // url, sourceLabel}]. link(url) brings one back.
  Q_PROPERTY(QVariantList dismissed READ dismissed NOTIFY rowsChanged)
  // When the host was last read for any of them: "synced 5m ago", or empty.
  Q_PROPERTY(QString syncedLabel READ syncedLabel NOTIFY rowsChanged)
  // What an environment too old to find a branch's pull request says instead.
  Q_PROPERTY(QString notice READ notice NOTIFY stateChanged)
  Q_PROPERTY(bool linking READ linking NOTIFY stateChanged)
  Q_PROPERTY(bool refreshing READ refreshing NOTIFY stateChanged)
  // The link field shows: the tab's Link button, or "Link pull request to
  // thread" from anywhere else.
  Q_PROPERTY(bool linkOpen READ linkOpen WRITE setLinkOpen NOTIFY stateChanged)
  // [{key, number, title, author, branches, draft, url}], newest first, and
  // why they could not be read.
  Q_PROPERTY(QVariantList projectOpen READ projectOpen NOTIFY projectChanged)
  Q_PROPERTY(QString projectProblem READ projectProblem NOTIFY projectChanged)

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
    // "Linked by you · 1h ago": how and when it was linked.
    LinkedNoteRole,
    // "Unlink from thread", or "Dismiss from thread" for a stack layer.
    UnlinkLabelRole,
    // Where it sits in its host's stack, bottom first: "Layer 2 of 3"; empty
    // outside a stack.
    StackLabelRole,
    // How far up its stack it sits: 0 on its base, one more per layer.
    DepthRole,
    // On the bottom row of a stack of several: its size, and what kind of
    // stack it is ("GitHub stack of 3: merging a layer lands the ones below
    // it.", "3 pull requests chained by base branch."). 0 and empty elsewhere.
    StackSizeRole,
    StackNoteRole,
  };

  using Notify = std::function<void(const QString& type, const QString& title, const QString& description)>;
  using Open = std::function<void(const QUrl& url)>;

  ThreadPullRequests(McClient* client, ShellStore* store, Notify notify, Open open, QObject* parent = nullptr);
  // What "now" is for how long ago a link was made.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // Where "Copy link" writes; the system clipboard unless a test sets it.
  void setClipboardWriter(std::function<bool(const QString&)> copy) { m_copy = std::move(copy); }

  // The thread shown ("<environment>:<thread id>"); reads its row again, so
  // it is also how a changed row lands. Rows only change when the links do.
  void setThread(const QString& threadKey);

  int count() const { return int(m_links.size()); }
  int openCount() const;
  bool online() const { return m_online; }
  QString problem() const;
  QString reference() const { return m_reference; }
  void setReference(const QString& reference);
  bool canLink() const;
  QString preview() const;
  bool available() const;
  QVariantList dismissed() const;
  QString syncedLabel() const;
  QString notice() const;
  bool linking() const { return m_linking; }
  bool refreshing() const { return m_refreshing > 0; }
  bool linkOpen() const { return m_linkOpen; }
  void setLinkOpen(bool open);
  // The row of `key`, or -1.
  Q_INVOKABLE int indexOf(const QString& key) const;
  // The address of "host/repository#number": its link's, its project entry's, or the host's page.
  QString urlOf(const QString& key) const;
  QVariant value(int row, int role) const { return data(index(row), role); }

  // Links what `text` names (and makes it the reference): a pull request URL
  // (any repository on a host a project of the environment reads) or
  // 123 / #123 (the thread's project). One link is sent at a time.
  Q_INVOKABLE void link(const QString& text);
  Q_INVOKABLE void unlink(const QString& key);
  Q_INVOKABLE void refresh();
  QVariantList projectOpen() const;
  QString projectProblem() const { return m_projectProblem; }
  // Reads the project's open pull requests; a thread already read is not read again.
  Q_INVOKABLE void loadProject(bool again = false);
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
  void projectChanged();

private:
  QString environmentId() const { return m_thread.left(m_thread.indexOf(QLatin1Char(':'))); }
  QString threadId() const { return m_thread.mid(m_thread.indexOf(QLatin1Char(':')) + 1); }
  const QJsonObject* find(const QString& key) const;
  QString ago(const QString& iso) const;

  McClient* m_client;
  ShellStore* m_store;
  Notify m_notify;
  Open m_open;
  QString m_thread;
  // The rows in order, and where each sits in its stack.
  struct Line {
    int depth = 0;
    int stackSize = 0;
    bool native = false;
  };
  QList<QJsonObject> m_links;
  QList<Line> m_lines;
  QList<QJsonObject> m_dismissed;
  bool m_online = false;
  // The link field: its text, whether the user has typed (validation shows
  // from then on), and why the last link failed.
  QString m_reference;
  bool m_dirty = false;
  QString m_problem;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  std::function<bool(const QString&)> m_copy;
  bool m_linking = false;
  int m_refreshing = 0;
  bool m_linkOpen = false;
  // The project's open pull requests as last read, and the thread they were read for.
  QList<QJsonObject> m_project;
  QString m_projectThread;
  QString m_projectProblem;
};
