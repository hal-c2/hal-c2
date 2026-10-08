#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QTimer>

#include <functional>
#include <optional>
#include <vector>

#include "FileTreeModel.h"

class McClient;
class TimelineModel;

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
// folder) browsed through the MC's `projects.listEntries`, searched with
// `projects.searchEntries` and read with `projects.readFile`, so a thread on a
// remote environment browses that machine's files.
//
// The tree loads the top folder when the tab is first shown, and each folder
// when first expanded. Typing a query searches after a short pause and shows
// the matches with their folders; clearing it restores the tree. A file opens
// in the viewer below `lines`, at a line when asked (past the end: the last
// line); the tree reveals it.
//
// Markdown, CSV and HTML files show rendered (`renderedText`) until the user
// asks for their source; the choice is kept per kind (sourceKinds, which the
// owner saves on this device). A file the MC read whole from inside the
// workspace can be edited (`setEditing`, `edit`): an edit is written with
// `projects.writeFile` half a second after the last one, and at once when the
// file closes or another opens. A write the MC refuses keeps the edit and
// says why (`saveProblem`, `saveFailed`). A Markdown task ticked in the
// rendered view (`toggleTask`) is written at once.
class WorkspaceFiles : public QObject {
  Q_OBJECT
  Q_PROPERTY(FileTreeModel* tree READ tree CONSTANT)
  Q_PROPERTY(TextLinesModel* lines READ lines CONSTANT)
  // The workspace folder on its environment; empty when the thread has none.
  Q_PROPERTY(QString root READ root NOTIFY targetChanged)
  Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
  // A search is on its way.
  Q_PROPERTY(bool searching READ searching NOTIFY searchChanged)
  // The MC had more matches than it sent.
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
  // The file's text, as read or as last edited.
  Q_PROPERTY(QString text READ text NOTIFY textChanged)
  // What the file renders as: markdown, csv, html, or "" for plain text.
  Q_PROPERTY(QString renderKind READ renderKind NOTIFY fileChanged)
  Q_PROPERTY(bool rendered READ rendered WRITE setRendered NOTIFY renderedChanged)
  // What the rendered view draws: Markdown (a CSV file's as a table, task
  // boxes as `task:<n>` links) or the HTML itself.
  Q_PROPERTY(QString renderedText READ renderedText NOTIFY textChanged)
  Q_PROPERTY(bool editable READ editable NOTIFY fileChanged)
  // Why the file cannot be edited, or "".
  Q_PROPERTY(QString readOnlyReason READ readOnlyReason NOTIFY fileChanged)
  Q_PROPERTY(bool editing READ editing WRITE setEditing NOTIFY renderedChanged)
  // An edit is not written yet.
  Q_PROPERTY(bool unsaved READ unsaved NOTIFY saveChanged)
  Q_PROPERTY(QString saveProblem READ saveProblem NOTIFY saveChanged)

public:
  // How long typing pauses before the search goes out, as the web's.
  static constexpr int searchDelayMs = 120;
  static constexpr int searchLimit = 200;
  // How long after the last edit it is written, as the web's.
  static constexpr int saveDelayMs = 500;
  // The rows of a CSV file its table shows.
  static constexpr int csvRowLimit = 500;

  explicit WorkspaceFiles(McClient* client, QObject* parent = nullptr);

  // One `projects.searchEntries` for `query` under `cwd`: the Files tab's
  // search, and the composer's @ menu.
  using SearchDone =
      std::function<void(const QList<FileTreeModel::Entry>& entries, bool truncated, const std::optional<QString>& error)>;
  static void searchEntries(McClient* client, QObject* context, const QString& environmentId, const QString& cwd, const QString& query,
                            int limit, SearchDone done);

  FileTreeModel* tree() { return &m_tree; }
  TextLinesModel* lines() { return &m_lines; }

  // The workspace to browse: the environment it is on and its folder there.
  // A new one forgets the tree, the search and the open file.
  void setTarget(const QString& environmentId, const QString& root);
  // Only a shown tab loads anything.
  void setActive(bool active);

  // The thread whose agent changes the workspace: the tree lists its loaded
  // folders again once a command or file change settles or a checkpoint
  // lands (the web's workspaceMutationId), at once while the tab shows, else
  // when it next does.
  void setTimeline(TimelineModel* timeline);
  QString environment() const { return m_environment; }
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
  // Whether long lines wrap: what the user chose here, else the word wrap
  // setting (setDefaultWrap).
  bool wrap() const { return m_wrap.value_or(m_defaultWrap); }
  void setWrap(bool wrap);
  void setDefaultWrap(bool wrap);
  QString text() const { return m_text; }
  QString renderKind() const;
  bool rendered() const;
  void setRendered(bool rendered);
  QString renderedText() const;
  bool editable() const { return readOnlyReason().isEmpty() && m_fileStatus == QLatin1String("ready"); }
  QString readOnlyReason() const;
  bool editing() const { return m_editing; }
  void setEditing(bool editing);
  bool unsaved() const { return m_pending; }
  QString saveProblem() const { return m_saveProblem; }
  // How long an edit waits to be written (saveDelayMs unless a test says).
  void setSaveDelay(int ms) { m_saveDelay.setInterval(ms); }
  // How long typing pauses before a search goes out (searchDelayMs unless a test says).
  void setSearchDelay(int ms) { m_searchDelay.setInterval(ms); }
  // The kinds the user reads as source rather than rendered.
  QStringList sourceKinds() const { return m_sourceKinds; }
  void setSourceKinds(const QStringList& kinds);

  // Opens a file in the viewer, at `line` when above 0, and reveals it in the tree.
  Q_INVOKABLE void openFile(const QString& path, int line = 0);
  Q_INVOKABLE void closeFile();
  // Reads the open file again.
  Q_INVOKABLE void reloadFile();
  // Lists the top folder again (after it failed).
  Q_INVOKABLE void reload();
  // Expands the folders above `path` (loading them as needed) and selects it.
  Q_INVOKABLE void reveal(const QString& path);
  // The open file's text as the user changed it.
  Q_INVOKABLE void edit(const QString& contents);
  // Ticks or unticks the open Markdown file's nth task (from 0).
  Q_INVOKABLE void toggleTask(int index);

signals:
  void targetChanged();
  void queryChanged();
  void searchChanged();
  void fileChanged();
  void revealRequested();
  void wrapChanged();
  void textChanged();
  void renderedChanged();
  void saveChanged();
  // The user chose source or rendered for a kind.
  void sourceKindsChanged();
  // The MC would not write `path`.
  void saveFailed(const QString& path, const QString& problem);

private:
  void list(const QString& folder);
  void search();
  void walkReveal();
  void setText(const QString& text);
  // Writes a pending edit now; `closing` when the file is going away, so
  // nothing but a failure is heard of it.
  void save(bool closing = false);
  // What the agent last did to the workspace, or empty.
  QString mutation() const;
  void followMutation();

  McClient* m_client;
  FileTreeModel m_tree;
  TextLinesModel m_lines;
  QString m_environment;
  QString m_root;
  bool m_active = false;
  // The newest listing asked for of each folder: any other answer is stale.
  int m_listRequest = 0;
  QHash<QString, int> m_listRequests;
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
  QPointer<TimelineModel> m_timeline;
  QString m_mutation;
  // The workspace changed while the tab was hidden.
  bool m_stale = false;
  QString m_text;
  bool m_truncated = false;
  QStringList m_sourceKinds;
  bool m_editing = false;
  QTimer m_saveDelay;
  // An edit waits to be written; a write is on its way.
  bool m_pending = false;
  bool m_saving = false;
  int m_revision = 0;
  QString m_saveProblem;
  std::optional<bool> m_wrap;
  bool m_defaultWrap = false;
};
