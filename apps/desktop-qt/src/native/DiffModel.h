#pragma once

#include <QAbstractListModel>
#include <QJsonArray>
#include <QSet>
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include <vector>

// A unified git patch (the MC's `orchestration.getTurnDiff`) as rows a
// ListView draws one line at a time: a header per file, and under an
// expanded file its hunks and lines. The patch is kept whole and rows point
// into it, so a 10 MB diff costs one scan (files and counts) up front and a
// file's lines are only split when it is expanded. Expanding and collapsing a
// file inserts and removes its rows; nothing else moves.
//
// A review cut short lists its files without their changes (setFiles):
// opening one asks for them (fileWanted) and they come with setFilePatch, or
// the file says why not (setFileState).
//
// `split` pairs each run of removed lines with the added lines that follow
// it, for a side-by-side view: a line row then has a left (old) and a right
// (new) side.
class DiffModel : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int fileCount READ fileCount NOTIFY patchChanged)
  Q_PROPERTY(int additions READ additions NOTIFY patchChanged)
  Q_PROPERTY(int deletions READ deletions NOTIFY patchChanged)
  // The longest line in the patch, in characters: how wide a row can get.
  Q_PROPERTY(int maxColumns READ maxColumns NOTIFY patchChanged)
  Q_PROPERTY(bool split READ split WRITE setSplit NOTIFY splitChanged)
  Q_PROPERTY(bool allExpanded READ allExpanded NOTIFY expansionChanged)

public:
  enum Role {
    // file, hunk or line
    KindRole = Qt::UserRole + 1,
    // The file's index, for toggling from any of its rows.
    FileRole,
    // A file's path (its new one when renamed), a hunk's header.
    PathRole,
    // A renamed file's old path.
    PreviousPathRole,
    // added, deleted, renamed or modified; binary files add nothing else.
    ChangeRole,
    BinaryRole,
    AdditionsRole,
    DeletionsRole,
    ExpandedRole,
    // A line's (the left side's, when split) text without its sign.
    TextRole,
    // "+", "-", " " or "\\" (no newline at end of file); "" for an empty side.
    SignRole,
    OldLineRole,
    NewLineRole,
    // The right side of a split row.
    RightTextRole,
    RightSignRole,
    // A file listed without its changes: "unloaded", "loading", "error",
    // "missing" (no patch for it) or "gone" (the checkout no longer has this
    // diff); "" once they are here.
    StateRole,
    // Why the file shows no changes, for its state.
    NoteRole,
    // The file's changes are cut short; its counts are whole.
    PartialRole,
  };

  // Up to this many changed and context lines, every file starts expanded.
  static constexpr int autoExpandLines = 4000;

  explicit DiffModel(QObject* parent = nullptr);

  // Replaces the patch; files start expanded when the whole patch is small,
  // unless diffs open collapsed (setCollapsedByDefault).
  void setPatch(const QString& patch);
  // The "Default diff file state" setting: the next patch opens with every
  // file collapsed.
  void setCollapsedByDefault(bool collapsed) { m_collapsedByDefault = collapsed; }
  void clear() { setPatch({}); }
  // A review's files without their changes: [{path, previousPath, additions,
  // deletions}], each closed until opened.
  void setFiles(const QJsonArray& files);
  // `file`'s changes, from a patch that has them (one of `patch`'s files has
  // its path); false when none does. `partial`: they are cut short.
  bool setFilePatch(int file, const QString& patch, bool partial);
  void setFileState(int file, const QString& state, const QString& note = {});
  // The MC's patch without the mark it ends a cut patch with.
  static QString withoutTruncatedMarker(const QString& patch);

  int fileCount() const { return int(m_files.size()); }
  int additions() const { return m_additions; }
  int deletions() const { return m_deletions; }
  int maxColumns() const { return m_maxColumns; }
  bool split() const { return m_split; }
  void setSplit(bool split);
  bool allExpanded() const;

  QStringList paths() const;
  // The changed files by folder, for a tree beside the diff, in the order the
  // diff has them: a folder where its first file is. A path the diff has
  // twice (a file replaced by a link) is listed once, as modified.
  // [{kind: "folder"|"file", name, path, depth, file (a file's index),
  // change, additions, deletions, open (a folder's), shown (no folder above
  // it is closed)}].
  Q_INVOKABLE QVariantList tree() const;
  // Closes or opens a folder of the tree; it stays so across patches.
  Q_INVOKABLE void toggleFolder(const QString& path);
  Q_INVOKABLE bool folderOpen(const QString& path) const { return !m_closedFolders.contains(path); }
  // The file's path, and whether it is expanded.
  Q_INVOKABLE QString path(int file) const { return file >= 0 && file < fileCount() ? m_files[file].path : QString(); }
  QString previousPath(int file) const { return file >= 0 && file < fileCount() ? m_files[file].previousPath : QString(); }
  Q_INVOKABLE QString state(int file) const { return file >= 0 && file < fileCount() ? m_files[file].state : QString(); }
  bool expanded(int file) const { return file >= 0 && file < fileCount() && m_files[file].expanded; }
  // The header row of `file`, or -1.
  // The lines `first` to `last` of one side of `file` ("old": removed lines
  // by their old numbers; else added and unchanged lines by their new ones),
  // for a comment on them: {startIndex, endIndex (among the file's lines),
  // diff (the lines with their signs), rangeLabel ("+10 to +12", the sign
  // when every line has the same)}. Empty when the file shows none of them.
  Q_INVOKABLE QVariantMap excerpt(int file, const QString& side, int first, int last);
  Q_INVOKABLE int rowOfFile(int file) const;
  Q_INVOKABLE int fileOf(const QString& path) const;
  Q_INVOKABLE void toggle(int file);
  Q_INVOKABLE void setExpanded(int file, bool expanded);
  Q_INVOKABLE void expandAll();
  Q_INVOKABLE void collapseAll();

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void patchChanged();
  void splitChanged();
  // allExpanded changed.
  void expansionChanged();
  // A folder of the tree was opened or closed.
  void treeChanged();
  // `file`, listed without its changes, was opened.
  void fileWanted(int file);

private:
  struct Line {
    int offset = 0;  // into m_patch, at the sign
    int length = 0;  // with the sign
    char sign = ' ';  // '+', '-', ' ', '\\', or '@' for a hunk header
    int oldLine = 0;
    int newLine = 0;
  };
  // A line row: indexes into File::lines, -1 for an empty side.
  struct Pair {
    int left = -1;
    int right = -1;
  };
  struct File {
    QString path;
    QString previousPath;
    QString change = QStringLiteral("modified");
    bool binary = false;
    int body = 0;  // the first hunk's offset, or the end when it has none
    int end = 0;
    int additions = 0;
    int deletions = 0;
    int lineCount = 0;
    bool expanded = false;
    QString state;
    QString note;
    bool partial = false;
    // Split on first expansion.
    bool parsed = false;
    std::vector<Line> lines;
    std::vector<Pair> pairs;
  };
  struct Row {
    int file = 0;
    int line = -1;  // -1 for the header, else into lines (or pairs, when split)
  };

  void parse();
  // The files of m_patch from `from` on; widens m_maxColumns to their lines.
  std::vector<File> parseFrom(qsizetype from);
  bool waiting(const File& file) const { return !file.state.isEmpty(); }
  // Inserts or removes the file's rows; the callers say when allExpanded changes.
  void expandOne(int file, bool expand);
  void ensureLines(File& file);
  void pairLines(File& file) const;
  int linesShown(const File& file) const;
  void rebuildRows();
  QString textOf(const File& file, int line) const;

  QString m_patch;
  std::vector<File> m_files;
  std::vector<Row> m_rows;
  int m_additions = 0;
  int m_deletions = 0;
  int m_maxColumns = 0;
  bool m_split = false;
  bool m_collapsedByDefault = false;
  QSet<QString> m_closedFolders;
};
