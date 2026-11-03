#pragma once

#include <QAbstractListModel>
#include <QColor>
#include <QDateTime>
#include <QHash>
#include <QObject>
#include <QTemporaryFile>
#include <memory>
#include <QPointer>
#include <QString>
#include <QTimer>
#include <QUrl>
#include <QVariantList>

#include <functional>
#include <optional>
#include <vector>

#include "CodeReader.h"
#include "FileTreeModel.h"

class McClient;
class QJsonValue;
class TimelineModel;

// A file's text as one row per line, so a ListView only lays out the lines on
// screen: a 1 MB file is one string and a list of offsets into it.
//
// The text is coloured by its language once read (codereader, off the GUI
// thread), when `path` names a syntax and the text is no longer than
// codereader::kMaxChars. A row's `styled` is then its line as StyledText, cut
// at `columnLimit` characters as the viewer cuts `text`; it is empty while the
// line is plain. Only the rows asked for are made up. `background` picks the
// light or the dark colouring, and a switch changes `styled` alone, with
// nothing read again.
class TextLinesModel : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY textChanged)
  // The longest line, in characters.
  Q_PROPERTY(int maxColumns READ maxColumns NOTIFY textChanged)
  Q_PROPERTY(QColor background READ background WRITE setBackground NOTIFY backgroundChanged)
  // The most of a line `styled` holds; past it, "…".
  Q_PROPERTY(int columnLimit READ columnLimit WRITE setColumnLimit NOTIFY columnLimitChanged)
  // Whether the lines show coloured now, and whether the text is being read.
  Q_PROPERTY(bool coloured READ coloured NOTIFY colouredChanged)
  Q_PROPERTY(bool reading READ reading NOTIFY readingChanged)

public:
  enum Role { TextRole = Qt::UserRole + 1, NumberRole, StyledRole };

  explicit TextLinesModel(QObject* parent = nullptr) : QAbstractListModel(parent) {}

  // `path` is the file's, whose name picks its syntax; none leaves it plain.
  void setText(const QString& text, const QString& path = QString());
  int maxColumns() const { return m_maxColumns; }
  Q_INVOKABLE QString line(int row) const;
  QColor background() const { return m_background; }
  void setBackground(const QColor& background);
  int columnLimit() const { return m_columnLimit; }
  void setColumnLimit(int limit);
  bool coloured() const;
  bool reading() const { return m_reading; }
  // Row `row` as its `styled` role reads.
  QString styled(int row) const;

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void textChanged();
  void backgroundChanged();
  void columnLimitChanged();
  void colouredChanged();
  void readingChanged();

private:
  bool readable() const;
  QString key() const;
  void read();
  void setRuns(std::shared_ptr<const codereader::Runs> runs);
  void setReading(bool reading);
  void restyle();

  QString m_text;
  QString m_path;
  std::vector<std::pair<int, int>> m_lines;  // offset, length
  int m_maxColumns = 0;
  QColor m_background;
  int m_columnLimit = 2000;
  // What reading the text made; null while it is plain.
  std::shared_ptr<const codereader::Runs> m_runs;
  bool m_reading = false;
  // Lets a finished read find this model only while it is for the text shown.
  std::shared_ptr<int> m_alive = std::make_shared<int>(0);
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
// owner saves on this device). A file the MC read whole can be edited,
// one outside the workspace (opened by its full path) too (`setEditing`,
// `edit`): an edit is written with
// `projects.writeFile` half a second after the last one, and at once when the
// file closes or another opens. A write the MC refuses keeps the edit and
// says why (`saveProblem`, `saveFailed`); one refused outside the workspace
// for want of terminal access leaves such files there read-only
// (`readOnlyReason`). A Markdown task ticked in the
// rendered view (`toggleTask`) is written at once.
//
// A media file (mediaKindOf) is never read as text: the environment signs a
// URL for it with `assets.createUrl` (`mediaUrl`), which the viewer loads.
// The URL lasts an hour; opening the file again, or showing the tab, after
// that signs a new one. A preview that fails to load (`mediaFailed`) leaves
// the file in error, and `reloadFile` signs it again.
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
  // What the open file previews as instead of text: image, video, audio, pdf,
  // or "" for a file read as text.
  Q_PROPERTY(QString mediaKind READ mediaKind NOTIFY fileChanged)
  Q_PROPERTY(QUrl mediaDocument READ mediaDocument NOTIFY fileChanged)
  // Where the preview loads a media file from, once signed; else empty.
  Q_PROPERTY(QUrl mediaUrl READ mediaUrl NOTIFY fileChanged)
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
  // The open file is on its machine outside the workspace, so not in the tree.
  Q_PROPERTY(bool outsideProject READ outsideProject NOTIFY fileChanged)
  // The folder the path trail lists: loading, ready, gone or error, what it
  // holds (path, name, directory; folders first) and why it lists nothing.
  Q_PROPERTY(QString trailFolder READ trailFolder NOTIFY trailChanged)
  Q_PROPERTY(QString trailStatus READ trailStatus NOTIFY trailChanged)
  Q_PROPERTY(QVariantList trailEntries READ trailEntries NOTIFY trailChanged)
  Q_PROPERTY(QString trailProblem READ trailProblem NOTIFY trailChanged)

public:
  // How long typing pauses before the search goes out.
  static constexpr int searchDelayMs = 120;
  static constexpr int searchLimit = 200;
  // How long after the last edit it is written.
  static constexpr int saveDelayMs = 500;
  // What a table shows of a CSV or TSV file; its source has the rest.
  static constexpr int tableRowLimit = 100;
  static constexpr int tableColumnLimit = 30;
  static constexpr int tableCellLimit = 2000;

  struct DelimitedPreview {
    QList<QStringList> rows;
    bool truncated = false;
  };
  // The delimiter a file's table has, by its type and else its name: null for no table.
  static QChar previewDelimiter(const QString& name, const QString& mimeType = {});
  static DelimitedPreview parseDelimited(const QString& text, QChar delimiter);
  // The table as Markdown, saying so when it is limited; empty with no rows.
  static QString tableMarkdown(const QString& text, QChar delimiter);

  explicit WorkspaceFiles(McClient* client, QObject* parent = nullptr);

  // One `projects.searchEntries` for `query` under `cwd`: the Files tab's
  // search, and the composer's @ menu.
  using SearchDone =
      std::function<void(const QList<FileTreeModel::Entry>& entries, bool truncated, const std::optional<QString>& error)>;
  static void searchEntries(McClient* client, QObject* context, const QString& environmentId, const QString& cwd, const QString& query,
                            int limit, SearchDone done);

  FileTreeModel* tree() { return &m_tree; }
  TextLinesModel* lines() { return &m_lines; }

  // The workspace to browse: the environment it is on and its folder there,
  // and the thread it is for (which media URLs are signed for). A new
  // workspace forgets the tree, the search and the open file.
  void setTarget(const QString& environmentId, const QString& root, const QString& threadId = {});
  // Only a shown tab loads anything.
  void setActive(bool active);
  // The workspace changed under the open file: shows it as it is now, once the
  // user's own edit is out of the way, without a loading state.
  void followOpenFile();

  // The thread whose agent changes the workspace: the tree lists its loaded
  // folders again once a command or file change settles or a checkpoint
  // lands, at once while the tab shows, else
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
  bool fileEmpty() const { return m_fileStatus == QLatin1String("ready") && mediaKind().isEmpty() && m_lines.rowCount() == 0; }
  int revealLine() const { return m_revealLine; }
  // Whether long lines wrap: what the user chose here, else the word wrap
  // setting (setDefaultWrap).
  bool wrap() const { return m_wrap.value_or(m_defaultWrap); }
  void setWrap(bool wrap);
  void setDefaultWrap(bool wrap);
  QString text() const { return m_text; }
  QString renderKind() const;
  // What a file previews as, by its extension: image, video, audio, pdf, or "".
  static QString mediaKindOf(const QString& path);
  QString mediaKind() const { return mediaKindOf(m_openPath); }
  // A PDF's local copy, once read; what the document view opens.
  QUrl mediaDocument() const { return m_mediaDocument ? QUrl::fromLocalFile(m_mediaDocument->fileName()) : QUrl(); }
  QUrl mediaUrl() const { return m_mediaUrl; }
  bool rendered() const;
  void setRendered(bool rendered);
  QString renderedText() const;
  bool editable() const { return readOnlyReason().isEmpty() && m_fileStatus == QLatin1String("ready") && mediaKind().isEmpty(); }
  QString readOnlyReason() const;
  // The open file is outside the workspace on an environment that refused such a write.
  bool hostWritesRefused() const;
  bool editing() const { return m_editing; }
  void setEditing(bool editing);
  bool unsaved() const { return m_pending; }
  // A write waits or is on its way.
  bool writing() const { return m_underWay || !m_writes.isEmpty(); }
  // The viewer is going away: an edit that waits for its pause goes now, and
  // writesFinished says when no write is left. Destroying the viewer first
  // drops what is queued, so its owner waits for this (NativeShell).
  void finishWrites() { save(true); }
  QString saveProblem() const { return m_saveProblem; }
  bool outsideProject() const;
  QString trailFolder() const { return m_trailFolder; }
  QString trailStatus() const { return m_trailStatus; }
  QVariantList trailEntries() const { return m_trailEntries; }
  QString trailProblem() const { return m_trailProblem; }
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
  // Reads the open file again (signs a media file's URL again).
  Q_INVOKABLE void reloadFile();
  // The preview could not load `url`: the open file is in error, unless the
  // URL is no longer the one shown.
  Q_INVOKABLE void mediaFailed(const QUrl& url);
  // Hands the open media file's address to the browser (mediaOpened), signing
  // it again first when it has run out.
  Q_INVOKABLE void openMedia();
  // Lists the top folder again (after it failed).
  Q_INVOKABLE void reload();
  // Expands the folders above `path` (loading them as needed) and selects it.
  Q_INVOKABLE void reveal(const QString& path);
  // The open file's text as the user changed it.
  Q_INVOKABLE void edit(const QString& contents);
  // Ticks or unticks the open Markdown file's nth task (from 0).
  Q_INVOKABLE void toggleTask(int index);
  // Lists a folder for the path trail, or again after it failed.
  Q_INVOKABLE void listTrail(const QString& folder);
  // Asks for the open file's address and hands it to the thread's browser.
  Q_INVOKABLE void openInPreview();
  // Sends a note on lines of the open file to the prompt.
  Q_INVOKABLE void commentOnLines(int first, int last, const QString& note);

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
  void trailChanged();
  void commentRequested(const QVariantMap& comment);
  void previewReady(const QUrl& url);
  void previewRefused(const QString& reason);
  // The user chose source or rendered for a kind.
  void sourceKindsChanged();
  // The MC would not write `path`.
  void saveFailed(const QString& path, const QString& problem);
  // The last write was answered.
  void writesFinished();
  // The browser is to open `url`, the open media file's address (openMedia).
  void mediaOpened(const QUrl& url);

private:
  void list(const QString& folder);
  void search();
  void walkReveal();
  void setText(const QString& text);
  void signMedia(int request);
  // The open media file has no URL that still works.
  bool mediaExpired() const;
  // Writes a pending edit now; `closing` when the file is going away, so
  // nothing but a failure is heard of it.
  void save(bool closing = false);
  // Sends the oldest waiting write, once the one under way is answered.
  void writeNext();
  // A write of the open file is under way or waiting.
  bool writingOpenFile() const;
  // Reads the open file for the latest request, to show it.
  void readOpenFile();
  void followMutation();
  // The newest file change the agent made names `path`.
  bool newestChangeNames(const QString& path) const;
  // The agent changed the workspace: the open file shows what is there now.
  // Reads the open file while it stays on screen; the waiting ticks are applied
  // if the file is still what the user is looking at.
  void refreshFile();
  void rereadIfDue();
  void noteTruncation(const QJsonObject& file);
  void applyTask(int index);
  void clearTrail();
  // What assets.createUrl serves the open file as.
  QJsonObject fileResource() const;
  static QString readProblem(const QJsonValue& detail, const QString& error);

  McClient* m_client;
  FileTreeModel m_tree;
  TextLinesModel m_lines;
  QString m_environment;
  QString m_root;
  QString m_thread;
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
  // Task boxes ticked and waiting on the read that checks the file has not moved.
  QList<int> m_waitingTicks;
  int m_openLine = 0;
  // Opened at a line, so shown as source until the user asks otherwise; not a preference.
  bool m_lineSource = false;
  // A read was skipped or dropped for the user's edit: read again once it is written.
  bool m_rereadLater = false;
  // The open media file was rewritten while nothing could show it.
  bool m_mediaRewritten = false;
  QString m_trailFolder;
  QString m_trailStatus;
  QString m_trailProblem;
  QVariantList m_trailEntries;
  int m_trailRequest = 0;
  int m_fileRequest = 0;
  QString m_fileStatus = QStringLiteral("none");
  QString m_fileProblem;
  QString m_truncatedNotice;
  QUrl m_mediaUrl;
  // When the MC stops serving m_mediaUrl, a minute early.
  QDateTime m_mediaExpires;
  std::unique_ptr<QTemporaryFile> m_mediaDocument;
  // The signing whose address openMedia is waiting for; else 0.
  int m_openOnSign = 0;
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
  struct Write {
    QString environment;
    QString root;
    QString path;
    QString contents;
    int revision;
    int request;
    bool closing;
  };
  QList<Write> m_writes;
  std::optional<Write> m_underWay;
  // The open file is loading, and reads once its writes have landed.
  bool m_readAfterWrites = false;
  int m_revision = 0;
  QString m_saveProblem;
  // The environment that refused to write a file by its full path for want of
  // terminal access (the session's scopes do not change while it lasts).
  QString m_hostWritesRefusedOn;
  std::optional<bool> m_wrap;
  bool m_defaultWrap = false;
};
