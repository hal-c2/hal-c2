#pragma once

#include <QAbstractListModel>
#include <QObject>
#include <QString>
#include <QTimer>

#include <functional>
#include <optional>
#include <vector>

#include "FileTreeModel.h"

class NodeClient;

// A file's text as one row per line, so a ListView only lays out the lines on
// screen: a 1 MB file is one string and a list of offsets into it.
class TextLinesModel : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY textChanged)
  // The longest line, in characters.
  Q_PROPERTY(int maxColumns READ maxColumns NOTIFY textChanged)

public:
  enum Role { TextRole = Qt::UserRole + 1, NumberRole };

  explicit TextLinesModel(QObject* parent = nullptr) : QAbstractListModel(parent) {}

  void setText(const QString& text);
  int maxColumns() const { return m_maxColumns; }
  Q_INVOKABLE QString line(int row) const;

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void textChanged();

private:
  QString m_text;
  std::vector<std::pair<int, int>> m_lines;  // offset, length
  int m_maxColumns = 0;
};

// The Files tab: a thread's workspace (its worktree, else its project's
// folder) browsed through the node's `projects.listEntries`, searched with
// `projects.searchEntries` and read with `projects.readFile`, so a thread on a
// remote environment browses that machine's files.
//
// The tree loads the top folder when the tab is first shown, and each folder
// when first expanded. Typing a query searches after a short pause and shows
// the matches with their folders; clearing it restores the tree. A file opens
// read-only in the viewer below `lines`, at a line when asked (past the end:
// the last line); the tree reveals it.
class WorkspaceFiles : public QObject {
  Q_OBJECT
  Q_PROPERTY(FileTreeModel* tree READ tree CONSTANT)
  Q_PROPERTY(TextLinesModel* lines READ lines CONSTANT)
  // The workspace folder on its environment; empty when the thread has none.
  Q_PROPERTY(QString root READ root NOTIFY targetChanged)
  Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
  // A search is on its way.
  Q_PROPERTY(bool searching READ searching NOTIFY searchChanged)
  // The node had more matches than it sent.
  Q_PROPERTY(bool searchTruncated READ searchTruncated NOTIFY searchChanged)
  Q_PROPERTY(QString searchProblem READ searchProblem NOTIFY searchChanged)
  // The file in the viewer, and how it is: none, loading, ready or error.
  Q_PROPERTY(QString openPath READ openPath NOTIFY fileChanged)
  Q_PROPERTY(QString fileStatus READ fileStatus NOTIFY fileChanged)
  Q_PROPERTY(QString fileProblem READ fileProblem NOTIFY fileChanged)
  // "Preview limited to the first 1 MB of a 3,145,728 byte file.", when only
  // the start of the file came.
  Q_PROPERTY(QString truncatedNotice READ truncatedNotice NOTIFY fileChanged)
  Q_PROPERTY(bool fileEmpty READ fileEmpty NOTIFY fileChanged)
  // The line the viewer was asked to show (1-based, within the file), or 0.
  Q_PROPERTY(int revealLine READ revealLine NOTIFY revealRequested)
  Q_PROPERTY(bool wrap READ wrap WRITE setWrap NOTIFY wrapChanged)

public:
  // How long typing pauses before the search goes out, as the web's.
  static constexpr int searchDelayMs = 120;
  static constexpr int searchLimit = 200;

  explicit WorkspaceFiles(NodeClient* client, QObject* parent = nullptr);

  // One `projects.searchEntries` for `query` under `cwd`: the Files tab's
  // search, and the composer's @ menu.
  using SearchDone =
      std::function<void(const QList<FileTreeModel::Entry>& entries, bool truncated, const std::optional<QString>& error)>;
  static void searchEntries(NodeClient* client, QObject* context, const QString& environmentId, const QString& cwd, const QString& query,
                            int limit, SearchDone done);

  FileTreeModel* tree() { return &m_tree; }
  TextLinesModel* lines() { return &m_lines; }

  // The workspace to browse: the environment it is on and its folder there.
  // A new one forgets the tree, the search and the open file.
  void setTarget(const QString& environmentId, const QString& root);
  // Only a shown tab loads anything.
  void setActive(bool active);

  QString root() const { return m_root; }
  QString query() const { return m_query; }
  void setQuery(const QString& query);
  bool searching() const { return m_searching; }
  bool searchTruncated() const { return m_searchTruncated; }
  QString searchProblem() const { return m_searchProblem; }
  QString openPath() const { return m_openPath; }
  QString fileStatus() const { return m_fileStatus; }
  QString fileProblem() const { return m_fileProblem; }
  QString truncatedNotice() const { return m_truncatedNotice; }
  bool fileEmpty() const { return m_fileStatus == QLatin1String("ready") && m_lines.rowCount() == 0; }
  int revealLine() const { return m_revealLine; }
  bool wrap() const { return m_wrap; }
  void setWrap(bool wrap);

  // Opens a file in the viewer, at `line` when above 0, and reveals it in the tree.
  Q_INVOKABLE void openFile(const QString& path, int line = 0);
  Q_INVOKABLE void closeFile();
  // Reads the open file again.
  Q_INVOKABLE void reloadFile();
  // Lists the top folder again (after it failed).
  Q_INVOKABLE void reload();
  // Expands the folders above `path` (loading them as needed) and selects it.
  Q_INVOKABLE void reveal(const QString& path);

signals:
  void targetChanged();
  void queryChanged();
  void searchChanged();
  void fileChanged();
  void revealRequested();
  void wrapChanged();

private:
  void list(const QString& folder);
  void search();
  void walkReveal();

  NodeClient* m_client;
  FileTreeModel m_tree;
  TextLinesModel m_lines;
  QString m_environment;
  QString m_root;
  bool m_active = false;
  // Bumped with every new target: answers about an older one are dropped.
  int m_generation = 0;
  QString m_query;
  QTimer m_searchDelay;
  int m_searchRequest = 0;
  bool m_searching = false;
  bool m_searchTruncated = false;
  QString m_searchProblem;
  QString m_openPath;
  int m_openLine = 0;
  int m_fileRequest = 0;
  QString m_fileStatus = QStringLiteral("none");
  QString m_fileProblem;
  QString m_truncatedNotice;
  int m_revealLine = 0;
  QString m_revealing;
  bool m_wrap = false;
};
