#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QList>
#include <QString>
#include <QVariantList>

#include <functional>
#include <optional>

// A project's folders as the rows of a tree a ListView draws: each visible
// entry with its depth, a folder's children under it while it is expanded.
// Folders load when first expanded (`fetch`, answered with setListing or
// setFailed); a loading folder shows a "loading" row, a failed one an "error"
// row the user can retry from. Expanding, collapsing and a listing that lands
// insert and remove only that folder's rows.
//
// A search swaps in a tree of its own made of the matches and their folders,
// all expanded; ending it brings back the tree as the user left it.
class FileTreeModel : public QAbstractListModel {
  Q_OBJECT
  // The top folder's: loading, ready or error (with `rootProblem`).
  Q_PROPERTY(QString rootStatus READ rootStatus NOTIFY rootChanged)
  Q_PROPERTY(QString rootProblem READ rootProblem NOTIFY rootChanged)
  Q_PROPERTY(QString selectedPath READ selectedPath NOTIFY selectedChanged)
  Q_PROPERTY(bool filtered READ filtered NOTIFY rootChanged)
  // Every folder is kept open (expandAll), down to the ones still loading.
  Q_PROPERTY(bool allExpanded READ allExpanded NOTIFY allExpandedChanged)

public:
  enum Role {
    PathRole = Qt::UserRole + 1,
    NameRole,
    DepthRole,
    // file, directory, loading (a folder's children on the way) or error
    // (they could not be listed; `problem` says why).
    KindRole,
    ExpandedRole,
    IgnoredRole,
    ProblemRole,
    SelectedRole,
  };

  struct Entry {
    QString path;
    bool directory = false;
    bool ignored = false;
  };

  explicit FileTreeModel(QObject* parent = nullptr);

  // Asked for a folder's children ("" is the top); answered with setListing
  // or setFailed.
  void setFetch(std::function<void(const QString& folder)> fetch) { m_fetch = std::move(fetch); }

  // Forgets every folder and loads the top one again; a search on screen stays.
  void reload();
  // Forgets every folder without loading anything.
  void clear();
  void setListing(const QString& folder, const QList<Entry>& entries);
  void setFailed(const QString& folder, const QString& problem);
  // The matches of a search as the tree, or the user's tree again (nullopt).
  void setSearch(const std::optional<QList<Entry>>& matches);

  QString rootStatus() const;
  QString rootProblem() const;
  QString selectedPath() const { return m_selected; }
  bool filtered() const { return m_searching; }
  bool loaded(const QString& folder) const;
  // Whether the folder was asked for since the tree was last cleared.
  bool requested(const QString& folder) const;
  bool isExpanded(const QString& folder) const;

  Q_INVOKABLE void toggle(const QString& path);
  Q_INVOKABLE void expand(const QString& path);
  Q_INVOKABLE void collapse(const QString& path);
  // Opens every folder, loading each as it becomes known; folders git
  // ignores stay closed (a dependency tree is not what the user asked for).
  Q_INVOKABLE void expandAll();
  // Closes every folder: only the top level shows.
  Q_INVOKABLE void collapseAll();
  bool allExpanded() const { return m_expandAll; }
  // Lists every folder already loaded again, in place: what is open stays open.
  void refresh();
  // Lists a folder that failed again.
  Q_INVOKABLE void retry(const QString& folder);
  Q_INVOKABLE void select(const QString& path);
  // The row showing `path` (an entry, not a placeholder), or -1.
  Q_INVOKABLE int rowOf(const QString& path) const;
  // A loaded folder's entries ("" the top) as {path, name, directory}, folders
  // first: what the viewer's path trail offers beside a file.
  Q_INVOKABLE QVariantList entriesIn(const QString& folder) const;
  // The visible paths, in order, for tests and keyboard walking.
  QStringList visiblePaths() const;

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void rootChanged();
  void selectedChanged();
  void allExpandedChanged();
  // A folder's children landed (or failed); reveal() walks on from here.
  void folderSettled(const QString& folder);

private:
  enum class State { Unloaded, Loading, Loaded, Failed };
  struct Folder {
    State state = State::Unloaded;
    QString problem;
    QList<Entry> children;
    bool expanded = false;
  };
  struct Row {
    QString path;
    int depth = 0;
    // file, directory, loading or error
    QString kind;
    bool ignored = false;
  };
  using Folders = QHash<QString, Folder>;

  Folders& folders() { return m_searching ? m_search : m_folders; }
  const Folders& folders() const { return m_searching ? m_search : m_folders; }
  // Asks for a folder of the user's tree.
  void load(const QString& folder);
  // Shows a folder's listing (or failure) that just landed in the user's tree.
  void settle(const QString& folder);
  QList<Row> rowsUnder(const QString& folder, int depth) const;
  // Redraws a visible folder's children after its state changed.
  void refill(const QString& folder);
  // The rows under `folder`'s row (or every row, for the top): [first, end).
  std::pair<int, int> childRange(const QString& folder) const;

  std::function<void(const QString&)> m_fetch;
  Folders m_folders;
  Folders m_search;
  bool m_searching = false;
  bool m_expandAll = false;
  // Opens `folder`'s folders, as expandAll asks.
  void expandUnder(const QString& folder);
  QList<Row> m_rows;
  QString m_selected;
};
