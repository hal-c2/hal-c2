// DiffModel: a turn's patch as the rows the diff panel draws, while patches
// come and go (the same one again, a new one), files are expanded and
// collapsed one by one or all at once, the view switches between unified and
// split, and the "open collapsed" setting changes.
//
// The model is the patch as files of hunks of signed lines, generated and
// written out as git writes it; the rows it should show follow from that.
// Each command also checks that a property's signal fires exactly when the
// property changes, and that the rows only change with their signals.

#include "Prop.h"
#include "WorkspaceModels.h"

#include <QSignalSpy>

#include "DiffModel.h"

namespace {

rc::Gen<QString> oneOf(const QStringList& values) { return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end())); }

const QStringList kPaths{QStringLiteral("a.txt"), QStringLiteral("src/b.cpp"), QStringLiteral("src/c/d.h"), QStringLiteral("e")};
// Line contents that look like the patch's own headers.
const QStringList kTexts{QString(), QStringLiteral("x"), QStringLiteral("-- y"), QStringLiteral("++ z"), QStringLiteral("@@ w"),
                         QStringLiteral("diff --git a/q b/q"), QStringLiteral("long line of text")};

struct Hunk {
  int oldStart = 1;
  int newStart = 1;
  // Each line with its sign: '+', '-', ' ' or '\\'.
  QList<std::pair<char, QString>> lines;

  QString header() const {
    int olds = 0;
    int news = 0;
    for (const auto& [sign, text] : lines) {
      if (sign != '+' && sign != '\\') ++olds;
      if (sign != '-' && sign != '\\') ++news;
    }
    return QStringLiteral("@@ -%1,%2 +%3,%4 @@ fn").arg(oldStart).arg(olds).arg(newStart).arg(news);
  }
};

struct File {
  QString path;
  QString previousPath;
  QString change = QStringLiteral("modified");
  bool binary = false;
  QList<Hunk> hunks;

  int count(char wanted) const {
    int count = 0;
    for (const Hunk& hunk : hunks) {
      for (const auto& line : hunk.lines) count += line.first == wanted ? 1 : 0;
    }
    return count;
  }
  int lineCount() const {
    int count = 0;
    for (const Hunk& hunk : hunks) count += 1 + int(hunk.lines.size());
    return count;
  }
};

QString patchOf(const QList<File>& files) {
  QString patch;
  for (const File& file : files) {
    const QString before = file.previousPath.isEmpty() ? file.path : file.previousPath;
    patch += QStringLiteral("diff --git a/%1 b/%2\n").arg(before, file.path);
    if (file.change == QLatin1String("added")) patch += QStringLiteral("new file mode 100644\n");
    if (file.change == QLatin1String("deleted")) patch += QStringLiteral("deleted file mode 100644\n");
    if (file.change == QLatin1String("renamed")) {
      patch += QStringLiteral("similarity index 90%\nrename from %1\nrename to %2\n").arg(file.previousPath, file.path);
    }
    if (file.binary) {
      patch += QStringLiteral("Binary files a/%1 and b/%1 differ\n").arg(file.path);
      continue;
    }
    if (file.hunks.isEmpty()) continue;
    patch += QStringLiteral("index 1234567..89abcde 100644\n");
    patch += file.change == QLatin1String("added") ? QStringLiteral("--- /dev/null\n") : QStringLiteral("--- a/%1\n").arg(before);
    patch += file.change == QLatin1String("deleted") ? QStringLiteral("+++ /dev/null\n") : QStringLiteral("+++ b/%1\n").arg(file.path);
    for (const Hunk& hunk : file.hunks) {
      patch += hunk.header() + QLatin1Char('\n');
      for (const auto& [sign, text] : hunk.lines) {
        patch += QLatin1Char(sign) + (sign == '\\' ? QStringLiteral(" No newline at end of file") : text) + QLatin1Char('\n');
      }
    }
  }
  return patch;
}

rc::Gen<Hunk> genHunk(char only) {
  return rc::gen::exec([only] {
    Hunk hunk;
    hunk.oldStart = *rc::gen::inRange(1, 40);
    hunk.newStart = *rc::gen::inRange(1, 40);
    const std::vector<char> signs = only ? std::vector<char>{only} : std::vector<char>{' ', '+', '-'};
    const int count = *rc::gen::inRange(1, 7);
    for (int i = 0; i < count; ++i) hunk.lines.append({*rc::gen::elementOf(signs), *oneOf(kTexts)});
    if (*rc::gen::weightedElement<bool>({{1, true}, {5, false}})) hunk.lines.append({'\\', QString()});
    return hunk;
  });
}

// A hunk too long for the patch to open expanded.
Hunk bigHunk() {
  Hunk hunk;
  for (int i = 0; i <= DiffModel::autoExpandLines; ++i) hunk.lines.append({' ', QStringLiteral("same")});
  return hunk;
}

rc::Gen<QList<File>> genFiles() {
  return rc::gen::exec([] {
    QStringList paths = kPaths;
    QList<File> files;
    const int count = *rc::gen::inRange(0, 4);
    for (int i = 0; i < count && !paths.isEmpty(); ++i) {
      File file;
      file.path = paths.takeAt(*rc::gen::inRange<int>(0, int(paths.size())));
      file.change = *oneOf({QStringLiteral("modified"), QStringLiteral("added"), QStringLiteral("deleted"), QStringLiteral("renamed")});
      if (file.change == QLatin1String("renamed")) file.previousPath = QStringLiteral("old/") + file.path;
      file.binary = file.change != QLatin1String("renamed") && *rc::gen::weightedElement<bool>({{1, true}, {6, false}});
      if (!file.binary) {
        const char only = file.change == QLatin1String("added") ? '+' : file.change == QLatin1String("deleted") ? '-' : 0;
        const int hunks = file.change == QLatin1String("renamed") ? *rc::gen::inRange(0, 2) : *rc::gen::inRange(1, 3);
        for (int h = 0; h < hunks; ++h) file.hunks.append(*genHunk(only));
        if (file.change == QLatin1String("modified") && *rc::gen::weightedElement<bool>({{1, true}, {30, false}})) {
          file.hunks.append(bigHunk());
        }
      }
      files.append(file);
    }
    return files;
  });
}

struct Model {
  QList<File> files;
  QString patch;
  QList<bool> expanded;
  bool split = false;
  bool collapsedByDefault = false;

  bool allExpanded() const { return std::all_of(expanded.begin(), expanded.end(), [](bool open) { return open; }); }

  struct Row {
    QString kind;
    int file = 0;
    QString path;
    QString text;
    QString sign;
    int oldLine = 0;
    int newLine = 0;
    QString rightText;
    QString rightSign;
    bool expanded = false;
    bool operator==(const Row&) const = default;
  };

  QList<Row> rows() const {
    QList<Row> rows;
    for (int f = 0; f < files.size(); ++f) {
      const File& file = files.at(f);
      rows.append({QStringLiteral("file"), f, file.path, {}, {}, 0, 0, {}, {}, expanded.at(f)});
      if (!expanded.at(f)) continue;
      // Every line of the file, numbered, and the hunk headers among them.
      struct Line {
        char sign;
        QString text;
        int oldLine = 0;
        int newLine = 0;
      };
      QList<Line> lines;
      for (const Hunk& hunk : file.hunks) {
        lines.append({'@', hunk.header()});
        int oldLine = hunk.oldStart;
        int newLine = hunk.newStart;
        for (const auto& [sign, text] : hunk.lines) {
          Line line{sign, sign == '\\' ? QStringLiteral(" No newline at end of file") : text};
          if (sign == ' ' || sign == '-') line.oldLine = oldLine++;
          if (sign == ' ' || sign == '+') line.newLine = newLine++;
          lines.append(line);
        }
      }
      const auto row = [&](int left, int right) {
        const Line& any = lines.at(left >= 0 ? left : right);
        Row out{any.sign == '@' ? QStringLiteral("hunk") : QStringLiteral("line"), f, any.sign == '@' ? any.text : file.path};
        out.expanded = true;
        if (left >= 0) {
          out.text = lines.at(left).text;
          out.sign = any.sign == '@' ? QString() : QString(QLatin1Char(lines.at(left).sign));
          out.oldLine = lines.at(left).oldLine;
        }
        const int newSide = split ? right : left;
        if (newSide >= 0) out.newLine = lines.at(newSide).newLine;
        if (split && any.sign != '@' && right >= 0) {
          out.rightText = lines.at(right).text;
          out.rightSign = QString(QLatin1Char(lines.at(right).sign));
        }
        rows.append(out);
      };
      if (!split) {
        for (int l = 0; l < lines.size(); ++l) row(l, -1);
        continue;
      }
      // Side by side: a run of removals beside the additions that follow it.
      for (int l = 0; l < lines.size();) {
        if (lines.at(l).sign != '-' && lines.at(l).sign != '+') {
          row(l, lines.at(l).sign == '\\' ? -1 : l);
          ++l;
          continue;
        }
        int removed = l;
        while (removed < lines.size() && lines.at(removed).sign == '-') ++removed;
        int added = removed;
        while (added < lines.size() && lines.at(added).sign == '+') ++added;
        for (int k = 0; k < std::max(removed - l, added - removed); ++k) {
          row(k < removed - l ? l + k : -1, k < added - removed ? removed + k : -1);
        }
        l = added;
      }
    }
    return rows;
  }
};

void showValue(const Model::Row& row, std::ostream& os) {
  os << row.kind.toStdString() << " " << row.file << " " << row.path.toStdString() << " [" << row.sign.toStdString() << "|"
     << row.text.toStdString() << "|" << row.oldLine << "|" << row.newLine << "|" << row.rightSign.toStdString() << "|"
     << row.rightText.toStdString() << "]" << (row.expanded ? " open" : "");
}

void showValue(const File& file, std::ostream& os) {
  os << file.change.toStdString() << " " << file.path.toStdString() << (file.binary ? " binary" : "") << " with "
     << file.hunks.size() << " hunks of " << file.lineCount() << " lines";
}

struct Sut {
  DiffModel diff;
  halc2::prop::ModelMirror mirror{&diff};
  QSignalSpy patchChanged{&diff, &DiffModel::patchChanged};
  QSignalSpy splitChanged{&diff, &DiffModel::splitChanged};
  QSignalSpy expansionChanged{&diff, &DiffModel::expansionChanged};

  QList<Model::Row> rows() const {
    QList<Model::Row> rows;
    for (int row = 0; row < diff.rowCount(); ++row) {
      const QModelIndex at = diff.index(row);
      rows.append({at.data(DiffModel::KindRole).toString(), at.data(DiffModel::FileRole).toInt(), at.data(DiffModel::PathRole).toString(),
                   at.data(DiffModel::TextRole).toString(), at.data(DiffModel::SignRole).toString(),
                   at.data(DiffModel::OldLineRole).toInt(), at.data(DiffModel::NewLineRole).toInt(),
                   at.data(DiffModel::RightTextRole).toString(), at.data(DiffModel::RightSignRole).toString(),
                   at.data(DiffModel::ExpandedRole).toBool()});
    }
    return rows;
  }
};

// The rows, the header facts, and that each property's signal fired once if
// it changed and never if not.
void check(const Model& before, const Model& expected, Sut& sut) {
  RC_ASSERT(sut.diff.fileCount() == int(expected.files.size()));
  for (int f = 0; f < expected.files.size(); ++f) {
    const File& file = expected.files.at(f);
    const QModelIndex header = sut.diff.index(sut.diff.rowOfFile(f));
    RC_ASSERT(header.data(DiffModel::ChangeRole).toString() == file.change);
    RC_ASSERT(header.data(DiffModel::PreviousPathRole).toString() == file.previousPath);
    RC_ASSERT(header.data(DiffModel::BinaryRole).toBool() == file.binary);
    RC_ASSERT(header.data(DiffModel::AdditionsRole).toInt() == file.count('+'));
    RC_ASSERT(header.data(DiffModel::DeletionsRole).toInt() == file.count('-'));
    RC_ASSERT(sut.diff.fileOf(file.path) == f);
  }
  int additions = 0;
  int deletions = 0;
  for (const File& file : expected.files) {
    additions += file.count('+');
    deletions += file.count('-');
  }
  RC_ASSERT(sut.diff.additions() == additions);
  RC_ASSERT(sut.diff.deletions() == deletions);
  RC_ASSERT(sut.rows() == expected.rows());
  RC_ASSERT(sut.diff.allExpanded() == expected.allExpanded());
  RC_ASSERT(sut.diff.split() == expected.split);

  RC_ASSERT(sut.patchChanged.count() == (before.patch != expected.patch ? 1 : 0));
  RC_ASSERT(sut.splitChanged.count() == (before.split != expected.split ? 1 : 0));
  RC_ASSERT(sut.expansionChanged.count() == (before.allExpanded() != expected.allExpanded() ? 1 : 0));
  sut.patchChanged.clear();
  sut.splitChanged.clear();
  sut.expansionChanged.clear();
  const QStringList problems = sut.mirror.problems();
  RC_ASSERT(problems == QStringList());
}

using Command = rc::state::Command<Model, Sut>;

template <class Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(sut);
    check(before, expected, sut);
  }
};

struct SetPatch : Step<SetPatch> {
  QList<File> files = *genFiles();
  void apply(Model& model) const override {
    const QString patch = patchOf(files);
    if (patch == model.patch) return;
    model.files = files;
    model.patch = patch;
    int total = 0;
    for (const File& file : files) total += file.lineCount();
    const bool open = !model.collapsedByDefault && total <= DiffModel::autoExpandLines;
    model.expanded = QList<bool>(files.size(), open);
  }
  void act(Sut& sut) const { sut.diff.setPatch(patchOf(files)); }
  void show(std::ostream& os) const override {
    os << "patch of ";
    rc::show(files, os);
  }
};

// The same turn's diff read again.
struct SamePatch : Step<SamePatch> {
  QString patch;
  explicit SamePatch(const Model& model) : patch(model.patch) {}
  void apply(Model&) const override {}
  void act(Sut& sut) const { sut.diff.setPatch(patch); }
  void show(std::ostream& os) const override { os << "the same patch again"; }
};

struct SetExpanded : Step<SetExpanded> {
  int file;
  bool expand = *rc::gen::arbitrary<bool>();
  bool toggle = *rc::gen::arbitrary<bool>();
  explicit SetExpanded(const Model& model) {
    RC_PRE(!model.files.isEmpty());
    file = *rc::gen::inRange<int>(0, int(model.files.size()));
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(file < model.files.size()); }
  void apply(Model& model) const override { model.expanded[file] = toggle ? !model.expanded.at(file) : expand; }
  void act(Sut& sut) const {
    if (toggle) {
      sut.diff.toggle(file);
    } else {
      sut.diff.setExpanded(file, expand);
    }
  }
  void show(std::ostream& os) const override {
    if (toggle) {
      os << "toggle file " << file;
    } else {
      os << (expand ? "expand file " : "collapse file ") << file;
    }
  }
};

struct All : Step<All> {
  bool expand = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.expanded.fill(expand); }
  void act(Sut& sut) const {
    if (expand) {
      sut.diff.expandAll();
    } else {
      sut.diff.collapseAll();
    }
  }
  void show(std::ostream& os) const override { os << (expand ? "expand all" : "collapse all"); }
};

struct Split : Step<Split> {
  bool split = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.split = split; }
  void act(Sut& sut) const { sut.diff.setSplit(split); }
  void show(std::ostream& os) const override { os << (split ? "split view" : "unified view"); }
};

struct CollapsedByDefault : Step<CollapsedByDefault> {
  bool collapsed = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.collapsedByDefault = collapsed; }
  void act(Sut& sut) const { sut.diff.setCollapsedByDefault(collapsed); }
  void show(std::ostream& os) const override { os << (collapsed ? "diffs open collapsed" : "diffs open expanded"); }
};

}  // namespace

class WorkspaceDiffProp : public QObject {
  Q_OBJECT

private slots:
  void diff() {
    QVERIFY(rc::check("the diff shows each file's lines while it is expanded, and says when that changes", [] {
      Sut sut;
      rc::state::check(Model(), sut,
                       rc::state::gen::execOneOfWithArgs<SetPatch, SetPatch, SamePatch, SetExpanded, SetExpanded, SetExpanded, All, Split,
                                                         CollapsedByDefault>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceDiffProp)
#include "tst_WorkspaceDiffProp.moc"
