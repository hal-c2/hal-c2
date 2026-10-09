// The diff panel's model (DiffModel.h) fed any text as a patch: a turn's diff
// from the MC, as git wrote it or as an agent or a hostile source made it. The
// model must not crash, every row it shows must read, and an excerpt of
// lines must hold only lines of the side it names, for the range asked.

#include "Fuzz.h"
#include "DiffModel.h"

#include <algorithm>
#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// What the parser looks for, so the engine can splice it in (Qt is not
// instrumented, so it cannot learn these from its comparisons).
const std::vector<std::string> kWords{"diff --git a/", " b/", "--- a/", "+++ b/", "@@ -", " +", " @@", "\n+", "\n-",
                                      "\n ", "\\ No newline at end of file", "rename from", "new file mode",
                                      "Binary files", "/dev/null", "\n"};

// A path of `folders` folders and a file.
std::string deepPath(int folders) {
  std::string path;
  for (int i = 0; i < folders; ++i) path += "d/";
  return path + "f";
}

// Room for the seed with a path of PATH_MAX; the engine's own default is 5000.
constexpr size_t kMaxPatch = 20000;

// An index the engine mostly keeps small (so ranges overlap the patch's line
// numbers) but also sends out of range, negative, or huge.
auto Index() { return fuzztest::OneOf(fuzztest::InRange<int>(-5, 40), fuzztest::Arbitrary<int>()); }

// Every role of every row reads, and the rows are as the model says they are:
// file rows in order, a line row only under an expanded file, and each file's
// header is where rowOfFile() says.
void readAllRows(DiffModel& model) {
  const QHash<int, QByteArray> roles = model.roleNames();
  int previousFile = -1;
  for (int row = 0; row < model.rowCount(); ++row) {
    const QModelIndex index = model.index(row, 0);
    for (auto it = roles.cbegin(); it != roles.cend(); ++it) model.data(index, it.key());
    const QString kind = model.data(index, DiffModel::KindRole).toString();
    const int file = model.data(index, DiffModel::FileRole).toInt();
    ASSERT_TRUE(kind == QLatin1String("file") || kind == QLatin1String("hunk") || kind == QLatin1String("line"))
        << "row " << row << " kind " << kind.toStdString();
    ASSERT_GE(file, 0) << "row " << row;
    ASSERT_LT(file, model.fileCount()) << "row " << row;
    ASSERT_GE(file, previousFile) << "row " << row << " is above its file's header";
    if (kind == QLatin1String("file")) {
      ASSERT_EQ(model.rowOfFile(file), row);
      ASSERT_EQ(model.data(index, DiffModel::PathRole).toString(), model.path(file));
    } else {
      ASSERT_TRUE(model.expanded(file)) << "row " << row << " is a line of a collapsed file";
    }
    previousFile = file;
  }
}

void checkExcerpt(const QVariantMap& excerpt, const QString& side) {
  if (excerpt.isEmpty()) return;
  const int startIndex = excerpt.value(QStringLiteral("startIndex")).toInt();
  const int endIndex = excerpt.value(QStringLiteral("endIndex")).toInt();
  const QString diff = excerpt.value(QStringLiteral("diff")).toString();
  const QString label = excerpt.value(QStringLiteral("rangeLabel")).toString();
  ASSERT_GE(startIndex, 0);
  ASSERT_GE(endIndex, startIndex);
  ASSERT_FALSE(label.isEmpty());
  // A line is picked from [startIndex, endIndex] at most once. (A line with no
  // sign at all, which git never writes, is picked as an empty string.)
  const QStringList lines = diff.split(QLatin1Char('\n'));
  ASSERT_LE(lines.size(), endIndex - startIndex + 1) << diff.toStdString();
  // The side's own lines: removed for "old", added or unchanged for "new".
  const bool old = side == QLatin1String("old");
  for (const QString& line : lines) {
    if (line.isEmpty()) continue;  // an unchanged empty line
    ASSERT_EQ(line.startsWith(QLatin1Char('-')), old) << "excerpt of " << side.toStdString() << " holds " << line.toStdString();
  }
}

void PatchReads(const std::string& text, bool split, int file, const std::string& side, int first, int last) {
  const QString patch = fuzz::utf8(text);
  fuzz::print(patch);
  const QString which = fuzz::utf8(side);

  DiffModel model;
  model.setPatch(patch);
  readAllRows(model);

  model.setSplit(split);
  readAllRows(model);

  // The tree lists each file at most once, as a file row of the model.
  const QVariantList tree = model.tree();
  int treeFiles = 0;
  for (const QVariant& node : tree) {
    if (node.toMap().value(QStringLiteral("kind")).toString() == QLatin1String("file")) ++treeFiles;
  }
  ASSERT_LE(treeFiles, model.fileCount());

  // An excerpt of a range reads the same reversed, and a file out of range or
  // a range that starts at line zero or less reads as nothing.
  const QVariantMap excerpt = model.excerpt(file, which, first, last);
  checkExcerpt(excerpt, which);
  if (file < 0 || file >= model.fileCount() || std::min(first, last) <= 0) {
    ASSERT_TRUE(excerpt.isEmpty());
  } else {
    ASSERT_TRUE(model.excerpt(file, which, last, first) == excerpt);
  }

  // Toggling and expanding move rows; they must read too.
  model.toggle(file);
  readAllRows(model);
  model.setSplit(!split);
  readAllRows(model);
  model.expandAll();
  readAllRows(model);
  model.collapseAll();
  readAllRows(model);
  model.setExpanded(file, true);
  readAllRows(model);
  model.clear();
  readAllRows(model);
  ASSERT_EQ(model.fileCount(), 0);
}
FUZZ_TEST(DiffModel, PatchReads)
    .WithDomains(fuzz::Text(kWords).WithMaxSize(kMaxPatch), fuzztest::Arbitrary<bool>(), Index(),
                 fuzz::Word({"old", "new", "other"}), Index(), Index())
    .WithSeeds([] {
      // Real diffs: a modified file, added and renamed and binary files, a
      // deleted file with no newline at its end, and a path 2000 segments deep
      // (about what PATH_MAX allows; tree() recurses once per segment, about 440
      // bytes of stack each, which fits the 8 MB the fuzz run allows).
      const std::string deep = deepPath(1999);
      const std::string nested = "diff --git a/" + deep + " b/" + deep + "\n--- a/" + deep + "\n+++ b/" + deep +
                                 "\n@@ -1 +1 @@\n-x\n+y\n";
      return std::vector<std::tuple<std::string, bool, int, std::string, int, int>>{
          {"diff --git a/src/cart.ts b/src/cart.ts\n--- a/src/cart.ts\n+++ b/src/cart.ts\n@@ -1,2 +1,2 @@\n const total = 0;\n"
           "-const tax = 1;\n+const tax = 2;\n",
           false, 0, "new", 1, 2},
          {"diff --git a/a.txt b/a.txt\nnew file mode 100644\n--- /dev/null\n+++ b/a.txt\n@@ -0,0 +1,2 @@\n+one\n+two\n"
           "diff --git a/old.txt b/new.txt\nsimilarity index 90%\nrename from old.txt\nrename to new.txt\n--- a/old.txt\n"
           "+++ b/new.txt\n@@ -3 +3 @@\n-x\n\\ No newline at end of file\n+y\n"
           "diff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n",
           true, 1, "old", 3, 3},
          {"diff --git a/gone b/gone\ndeleted file mode 100644\n--- a/gone\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n", false, 0,
           "old", 1, 1},
          {nested, false, 0, "new", 1, 1},
          {nested, true, -1, "new", 0, -5},
      };
    });

// The tree over a patch's paths: any paths, with empty segments and names
// that are also folders. It must not crash, and each file it lists is a file
// of the model.
void TreeOfPaths(const std::vector<std::string>& paths) {
  QString patch;
  for (const std::string& path : paths) {
    const QString name = fuzz::utf8(path);
    patch += QStringLiteral("diff --git a/%1 b/%1\n--- a/%1\n+++ b/%1\n@@ -1 +1 @@\n-x\n+y\n").arg(name);
  }
  DiffModel model;
  model.setPatch(patch);
  const QVariantList tree = model.tree();
  for (const QVariant& node : tree) {
    const QVariantMap entry = node.toMap();
    if (entry.value(QStringLiteral("kind")).toString() != QLatin1String("file")) continue;
    const int file = entry.value(QStringLiteral("file")).toInt();
    ASSERT_GE(file, 0);
    ASSERT_LT(file, model.fileCount());
  }
  readAllRows(model);
}
FUZZ_TEST(DiffModel, TreeOfPaths)
    .WithDomains(fuzztest::VectorOf(fuzz::Text({"/", "a", "b", ".", "..", " "})).WithMaxSize(8))
    .WithSeeds([] {
      return std::vector<std::tuple<std::vector<std::string>>>{
          {{"src/cart.ts", "src/tax.ts", "README"}},
          {{"a/b", "a", "a/", "/", ""}},
          {{deepPath(1999)}},
      };
    });

}  // namespace
