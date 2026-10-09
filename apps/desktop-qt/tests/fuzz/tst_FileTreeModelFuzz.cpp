// The Files tab's tree (FileTreeModel.h) fed any sequence of listings, answers,
// failures, expansions, searches and reloads, in any order, for folders whose
// names collide: a listing may name its own folder, or a folder below it, so a
// project can look like a cycle. The model must not crash or recurse without
// bound, and every row it shows must read, under a folder row above it.

#include "Fuzz.h"
#include "FileTreeModel.h"

#include <QHash>

#include <cstdint>
#include <optional>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// Short names, so paths collide: "a" under "a" is a self-reference, "a/" and
// "/" and ".." are the odd ones git and the MC can send.
const std::vector<std::string> kPool{"a", "b", "a/b", "", ".", "..", "/", "a/"};

enum Op : std::uint8_t {
  SetListing,
  SetFailed,
  AnswerNext,
  AnswerFailed,
  Expand,
  Collapse,
  Toggle,
  ExpandAll,
  CollapseAll,
  Retry,
  Refresh,
  Reload,
  Search,
  EndSearch,
  Select,
  Clear,
  OpCount
};

struct Item {
  std::string path;
  bool directory = false;
  bool ignored = false;
};

struct Step {
  std::uint8_t op = 0;
  std::string folder;
  std::vector<Item> items;
};

FileTreeModel::Entry entryOf(const Item& item) { return {fuzz::utf8(item.path), item.directory, item.ignored}; }

QList<FileTreeModel::Entry> entriesOf(const std::vector<Item>& items) {
  QList<FileTreeModel::Entry> entries;
  for (const Item& item : items) entries.append(entryOf(item));
  return entries;
}

// What the tree shows: every row reads, its kind is known, and under a row it
// is a folder one level up (the nearest row above it that is shallower).
void readRows(FileTreeModel& tree) {
  ASSERT_TRUE(tree.rootStatus() == QLatin1String("loading") || tree.rootStatus() == QLatin1String("ready") ||
              tree.rootStatus() == QLatin1String("error"))
      << tree.rootStatus().toStdString();
  const QHash<int, QByteArray> roles = tree.roleNames();
  const int count = tree.rowCount();
  QStringList visible;
  for (int row = 0; row < count; ++row) {
    const QModelIndex index = tree.index(row, 0);
    for (auto it = roles.cbegin(); it != roles.cend(); ++it) tree.data(index, it.key());
    const QString kind = tree.data(index, FileTreeModel::KindRole).toString();
    const QString path = tree.data(index, FileTreeModel::PathRole).toString();
    const int depth = tree.data(index, FileTreeModel::DepthRole).toInt();
    ASSERT_TRUE(kind == QLatin1String("file") || kind == QLatin1String("directory") || kind == QLatin1String("loading") ||
                kind == QLatin1String("error"))
        << "row " << row << " kind " << kind.toStdString();
    ASSERT_GE(depth, 0) << "row " << row;
    if (kind == QLatin1String("file") || kind == QLatin1String("directory")) {
      visible.append(path);
      // Some row shows the path (the first, when a path is listed twice).
      const int first = tree.rowOf(path);
      ASSERT_GE(first, 0) << "row " << row << " " << path.toStdString();
      ASSERT_EQ(tree.data(tree.index(first, 0), FileTreeModel::PathRole).toString(), path);
      if (kind == QLatin1String("directory")) {
        ASSERT_EQ(tree.data(index, FileTreeModel::ExpandedRole).toBool(), tree.isExpanded(path)) << path.toStdString();
      }
    }
    if (depth == 0) continue;
    bool parentFound = false;
    for (int above = row - 1; above >= 0 && !parentFound; --above) {
      const QModelIndex upper = tree.index(above, 0);
      const int upperDepth = tree.data(upper, FileTreeModel::DepthRole).toInt();
      if (upperDepth >= depth) continue;
      ASSERT_EQ(upperDepth, depth - 1) << "row " << row << " has no parent folder above it";
      parentFound = true;
    }
    ASSERT_TRUE(parentFound) << "row " << row << " has no parent folder above it";
  }
  ASSERT_TRUE(tree.visiblePaths() == visible) << "visiblePaths disagrees with the rows";
}

void apply(FileTreeModel& tree, std::vector<QString>& requested, const Step& step) {
  const QString folder = fuzz::utf8(step.folder);
  const QList<FileTreeModel::Entry> entries = entriesOf(step.items);
  switch (static_cast<Op>(step.op)) {
    case SetListing:
      tree.setListing(folder, entries);
      break;
    case SetFailed:
      tree.setFailed(folder, QStringLiteral("boom"));
      break;
    case AnswerNext:
    case AnswerFailed:
      if (requested.empty()) break;
      {
        const QString asked = requested.front();
        requested.erase(requested.begin());
        if (static_cast<Op>(step.op) == AnswerFailed) {
          tree.setFailed(asked, QStringLiteral("no"));
        } else {
          tree.setListing(asked, entries);
        }
      }
      break;
    case Expand:
      tree.expand(folder);
      break;
    case Collapse:
      tree.collapse(folder);
      break;
    case Toggle:
      tree.toggle(folder);
      break;
    case ExpandAll:
      tree.expandAll();
      break;
    case CollapseAll:
      tree.collapseAll();
      break;
    case Retry:
      tree.retry(folder);
      break;
    case Refresh:
      tree.refresh();
      break;
    case Reload:
      tree.reload();
      break;
    case Search:
      tree.setSearch(entries);
      break;
    case EndSearch:
      tree.setSearch(std::nullopt);
      break;
    case Select:
      tree.select(folder);
      break;
    case Clear:
      tree.clear();
      break;
    default:
      break;
  }
}

void TreeReads(const std::vector<Step>& steps) {
  QJsonArray json;
  for (const Step& step : steps) {
    QJsonArray items;
    for (const Item& item : step.items) {
      items.append(QJsonObject{{QStringLiteral("path"), fuzz::utf8(item.path)}, {QStringLiteral("directory"), item.directory},
                               {QStringLiteral("ignored"), item.ignored}});
    }
    json.append(QJsonObject{{QStringLiteral("op"), int(step.op)}, {QStringLiteral("folder"), fuzz::utf8(step.folder)},
                            {QStringLiteral("items"), items}});
  }
  fuzz::print(json);

  FileTreeModel tree;
  // The folders the model asked for and no one has answered yet.
  std::vector<QString> requested;
  tree.setFetch([&requested](const QString& folder) { requested.push_back(folder); });
  for (const Step& step : steps) {
    apply(tree, requested, step);
    readRows(tree);
  }
  // Whatever is still asked for lands empty, and the tree still reads.
  const std::vector<QString> pending = requested;
  requested.clear();
  for (const QString& folder : pending) tree.setListing(folder, {});
  readRows(tree);
  fuzz::settle();
}

Step step(Op op, std::string folder = {}, std::vector<Item> items = {}) {
  return Step{static_cast<std::uint8_t>(op), std::move(folder), std::move(items)};
}
Item dir(std::string path) { return Item{std::move(path), true, false}; }
Item file(std::string path) { return Item{std::move(path), false, false}; }

FUZZ_TEST(FileTree, TreeReads)
    .WithDomains(fuzztest::VectorOf(fuzztest::StructOf<Step>(
                                        fuzztest::InRange<std::uint8_t>(0, OpCount - 1), fuzz::Word(kPool),
                                        fuzztest::VectorOf(fuzztest::StructOf<Item>(fuzz::Word(kPool), fuzztest::Arbitrary<bool>(),
                                                                                    fuzztest::Arbitrary<bool>()))
                                            .WithMaxSize(4)))
                     .WithMaxSize(24))
    .WithSeeds([] {
      using Steps = std::vector<Step>;
      return std::vector<std::tuple<Steps>>{
          // A project as the Files tab opens it: the top, a folder opened by
          // hand, expandAll landing, a search and its end, then a reload.
          {Steps{step(SetListing, "", {dir("a"), file("R"), Item{"n", true, true}}), step(Expand, "a"),
                 step(AnswerNext, "", {file("a/x"), dir("a/b")}), step(ExpandAll), step(AnswerNext, "", {file("a/b/y")}),
                 step(AnswerFailed, "", {}), step(CollapseAll), step(Search, "", {file("a/b/y")}), step(EndSearch),
                 step(Reload), step(Refresh), step(Retry, "a")}},
          // A folder listing itself: expandAll never ends (expandUnder recurses).
          {Steps{step(SetListing, "", {dir("a")}), step(SetListing, "a", {dir("a")}), step(ExpandAll)}},
          // Expanding a folder that lists itself: rowsUnder recurses.
          {Steps{step(SetListing, "", {dir("a")}), step(SetListing, "a", {dir("a")}), step(Expand, "a")}},
          // A cycle through two folders: a listed under a/b, a/b under a.
          {Steps{step(SetListing, "", {dir("a")}), step(SetListing, "a", {dir("a/b")}), step(SetListing, "a/b", {dir("a")}),
                 step(ExpandAll)}},
      };
    });

}  // namespace
