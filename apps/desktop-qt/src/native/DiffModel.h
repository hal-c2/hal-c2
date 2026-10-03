#pragma once

#include <QAbstractListModel>
#include <QList>
#include <QString>
#include <QStringList>

#include <vector>

// A unified git patch (the MC's `orchestration.getTurnDiff`) as rows a
// ListView draws one line at a time: a header per file, and under an
// expanded file its hunks and lines. The patch is kept whole and rows point
// into it, so a 10 MB diff costs one scan (files and counts) up front and a
// file's lines are only split when it is expanded. Expanding and collapsing a
// file inserts and removes its rows; nothing else moves.
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

  int fileCount() const { return int(m_files.size()); }
  int additions() const { return m_additions; }
  int deletions() const { return m_deletions; }
  int maxColumns() const { return m_maxColumns; }
  bool split() const { return m_split; }
  void setSplit(bool split);
  bool allExpanded() const;

  QStringList paths() const;
  // The file's path, and whether it is expanded.
  QString path(int file) const { return file >= 0 && file < fileCount() ? m_files[file].path : QString(); }
  bool expanded(int file) const { return file >= 0 && file < fileCount() && m_files[file].expanded; }
  // The header row of `file`, or -1.
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
  void expansionChanged();

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
};
