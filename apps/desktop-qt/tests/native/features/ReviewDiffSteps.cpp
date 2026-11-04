// Reviewing the checkout beside a thread (features/source-control/review-diffs.feature):
// the Diff tab over the MC's `review.getDiffPreview`, driven through the
// DiffPanel brick as the user drives it. The MC's side is faked here: the
// working tree's patch, and the branch's against each base. Also a changed
// file opened in the user's editor, from the diff or from the commit review
// (commit-and-generated-messages.feature).

#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>
#include <QSet>
#include <QTest>
#include <qpa/qwindowsysteminterface.h>

#include <memory>

#include "Brick.h"
#include "DiffModel.h"
#include "FakeConfig.h"
#include "FakeGit.h"
#include "FilesWorkspace.h"
#include "NavigationController.h"
#include "Harness.h"
#include "Panel.h"
#include "Stream.h"
#include "RightPanelController.h"
#include "ThreadDiff.h"
#include "World.h"

namespace {

const QString kLongLine = QString(300, QLatin1Char('x'));
// Where the MC puts a thread's worktree: under its data directory, outside the project (HalC2.Vcs.worktree_path/2).
const QString kWorktree = QStringLiteral("/home/hal-c2/elixir/worktrees/shop/feature-tax");

QString patchChanging(const QString& path, const QStringList& added) {
  QString patch = QStringLiteral("diff --git a/%1 b/%1\n--- a/%1\n+++ b/%1\n@@ -1,2 +1,%2 @@\n const cart = [];\n-export const tax = 0;\n").arg(path).arg(added.size() + 1);
  for (const QString& line : added) patch += QLatin1Char('+') + line + QLatin1Char('\n');
  return patch;
}

QStringList lines(const QString& name, int count) {
  QStringList out;
  for (int n = 1; n <= count; ++n) out.append(QStringLiteral("export const %1%2 = %2;").arg(name).arg(n));
  return out;
}

// The checkout as `review.getDiffPreview` reports it (HalC2.Review).
struct FakeReview {
  QString head = QStringLiteral("feature/tax");
  QString automaticBase = QStringLiteral("main");
  // Uncommitted work: a long file first, so jumping to a later one scrolls.
  QString workingTree = patchChanging(QStringLiteral("src/cart.ts"), lines(QStringLiteral("rate"), 60) + QStringList{kLongLine}) +
                        patchChanging(QStringLiteral("src/tax.ts"), lines(QStringLiteral("band"), 3)) +
                        patchChanging(QStringLiteral("README.md"), lines(QStringLiteral("note"), 40));
  // The branch's changes, by the base they are against.
  QHash<QString, QString> branch{
      {QStringLiteral("main"), patchChanging(QStringLiteral("src/cart.ts"), lines(QStringLiteral("rate"), 2))},
      {QStringLiteral("origin/main"), patchChanging(QStringLiteral("src/cart.ts"), lines(QStringLiteral("rate"), 2)) +
                                          patchChanging(QStringLiteral("src/pay.ts"), lines(QStringLiteral("fee"), 2))},
  };
  QList<QJsonObject> asked;
  // The scenario says the environment has no editor.
  bool noEditor = false;
  // Too large to carry every file's patch: the MC counts each file and cuts
  // the patch short; a file's own patch is asked for with `file`.
  bool truncated = false;
  // Files it counts but has no patch for.
  QJsonArray unpatched;
  // Files whose own patch is still cut short.
  QSet<QString> partial;
  // The next ask for these files' patch fails.
  QSet<QString> failing;
  // The checkout no longer has the diff a file is asked from.
  bool gone = false;
  // The MC has no patch of the working tree at all.
  bool noSource = false;
  // What the panel said while it loaded, in order.
  QStringList statuses;
};

// Each file's part of a patch, by its path.
QList<std::pair<QString, QString>> filesOf(const QString& patch) {
  static const QRegularExpression header(QStringLiteral("^diff --git a/\\S+ b/(\\S+)$"), QRegularExpression::MultilineOption);
  QList<std::pair<QString, QString>> files;
  QList<std::pair<qsizetype, QString>> starts;
  for (auto it = header.globalMatch(patch); it.hasNext();) {
    const auto match = it.next();
    starts.append({match.capturedStart(), match.captured(1)});
  }
  for (qsizetype i = 0; i < starts.size(); ++i) {
    const qsizetype end = i + 1 < starts.size() ? starts.at(i + 1).first : patch.size();
    files.append({starts.at(i).second, patch.mid(starts.at(i).first, end - starts.at(i).first)});
  }
  return files;
}

// The counts the MC keeps beside a patch it cut short.
QJsonArray statsOf(const QString& patch) {
  QJsonArray stats;
  for (const auto& [path, part] : filesOf(patch)) {
    int additions = 0;
    int deletions = 0;
    for (const QString& line : part.split(QLatin1Char('\n'))) {
      if (line.startsWith(QLatin1Char('+')) && !line.startsWith(QLatin1String("+++"))) ++additions;
      if (line.startsWith(QLatin1Char('-')) && !line.startsWith(QLatin1String("---"))) ++deletions;
    }
    stats.append(QJsonObject{{QStringLiteral("path"), path}, {QStringLiteral("previousPath"), QJsonValue()}, {QStringLiteral("additions"), additions}, {QStringLiteral("deletions"), deletions}});
  }
  return stats;
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("review.getDiffPreview"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.asked.append(rpc.payload);
    const QString base = rpc.payload.value(QLatin1String("baseRef")).toString(fake.automaticBase);
    const QString file = rpc.payload.value(QLatin1String("file")).toObject().value(QLatin1String("path")).toString();
    if (!file.isEmpty() && fake.failing.remove(file)) {
      mc.refuse(rpc, QStringLiteral("git diff timed out"));
      return;
    }
    const auto source = [&](const QString& kind, const QString& title, const QJsonValue& baseRef, const QString& whole) {
      QString diff = whole;
      bool cut = false;
      QJsonObject out{{QStringLiteral("id"), kind}, {QStringLiteral("kind"), kind}, {QStringLiteral("title"), title}, {QStringLiteral("baseRef"), baseRef}, {QStringLiteral("headRef"), fake.head}};
      if (!file.isEmpty()) {
        // One file's own patch.
        diff.clear();
        for (const auto& [path, part] : filesOf(whole)) {
          if (path == file) diff = part;
        }
        cut = fake.partial.contains(file);
        if (cut) diff += QStringLiteral("\n\n[truncated]");
      } else if (fake.truncated && kind == QLatin1String("working-tree")) {
        QJsonArray stats = statsOf(whole);
        for (const QJsonValue& stat : std::as_const(fake.unpatched)) stats.append(stat);
        out.insert(QStringLiteral("files"), stats);
        diff = filesOf(whole).value(0).second + QStringLiteral("\n\n[truncated]");
        cut = true;
      }
      out.insert(QStringLiteral("diff"), diff);
      out.insert(QStringLiteral("diffHash"), QStringLiteral("hash-%1").arg(qHash(whole)));
      out.insert(QStringLiteral("truncated"), cut);
      return out;
    };
    QJsonArray sources;
    // A checkout that moved on has no diff the file was listed from.
    if (!(fake.noSource || (fake.gone && !file.isEmpty()))) {
      sources.append(source(QStringLiteral("working-tree"), QStringLiteral("Working tree"), QJsonValue(), fake.workingTree));
    }
    if (!(fake.gone && !file.isEmpty())) sources.append(source(QStringLiteral("branch-range"), QStringLiteral("Branch"), base, fake.branch.value(base)));
    mc.reply(rpc, QJsonObject{{QStringLiteral("cwd"), rpc.payload.value(QLatin1String("cwd"))},
                                {QStringLiteral("generatedAt"), QStringLiteral("2026-09-23T10:00:00Z")},
                                {QStringLiteral("sources"), sources}});
  });
});

FakeReview& fake(World& world) {
  return world.mc.part<FakeReview>();
}

ThreadDiff& diff(World& world) {
  return *world.native().controller<RightPanelController>()->diff();
}

QString describeDiff(World& world) {
  return QStringLiteral("the diff (%1: %2) shows %3").arg(diff(world).status(), diff(world).message(), diff(world).model()->paths().join(QStringLiteral(", ")));
}

void waitForDiff(World& world) {
  world.waitFor([&] { return diff(world).status() != QLatin1String("loading") && diff(world).status() != QLatin1String("idle"); },
                [&] { return QStringLiteral("the diff to load; %1").arg(describeDiff(world)); });
}

// The Diff tab beside the thread, as the DiffPanel brick draws it: on the
// checkout's working tree while the thread has no turn.
Brick& panel(World& world) {
  if (!world.brick) {
    world.bridge().dispatch(QStringLiteral("panel.open"), QVariantMap{{QStringLiteral("tab"), QStringLiteral("diff")}});
    waitForDiff(world);
    // Short, so a later file is below the fold.
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nDiffPanel { source: Panel.diff }\n", QSize(900, 420));
  }
  return *world.brick;
}

// An entry of the panel's options menu.
void chooseOption(World& world, const QString& entry) {
  Brick& brick = panel(world);
  brick.click(QStringLiteral("diffOptions"));
  world.waitFor([&] { return brick.item(entry)->isVisible(); }, QStringLiteral("the diff's options to open"));
  brick.click(entry);
  world.sync();
}

QQuickItem* rows(World& world) {
  return panel(world).item(QStringLiteral("diffRows"));
}

// The file whose row is at the top of the view.
QString fileAtTop(World& world) {
  QQuickItem* view = rows(world);
  int row = -1;
  QMetaObject::invokeMethod(view, "indexAt", Q_RETURN_ARG(int, row), Q_ARG(qreal, view->property("contentX").toReal()),
                            Q_ARG(qreal, view->property("contentY").toReal() + 1));
  DiffModel& model = *diff(world).model();
  return model.data(model.index(row), DiffModel::PathRole).toString();
}

void setEditors(World& world, const QJsonArray& editors) {
  FakeConfig& config = fakeConfig(world.mc);
  config.config.insert(QStringLiteral("availableEditors"), editors);
  QJsonObject sent = config.config;
  sent.insert(QStringLiteral("settings"), config.settings);
  for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), sent}});
  }
  world.sync();
}

// The user's editor, unless the scenario says there is none.
void haveEditor(World& world, const QString& path) {
  world.mc.part<filesteps::OpenedInEditor>() = {path, QStringLiteral("zed")};
  if (fake(world).noEditor) return;
  setEditors(world, QJsonArray{QStringLiteral("zed")});
  world.waitFor([&] { return !world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("editors")).toList().isEmpty(); },
                QStringLiteral("the environment's editors to be known"));
}

// The first shown item called `name` under `item`.
QQuickItem* findNamed(QQuickItem* item, const QString& name) {
  if (!item->isVisible()) return nullptr;
  if (item->objectName() == name) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = findNamed(child, name)) return found;
  }
  return nullptr;
}

int countNamed(QQuickItem* item, const QString& name) {
  if (!item->isVisible()) return 0;
  int count = item->objectName() == name ? 1 : 0;
  for (QQuickItem* child : item->childItems()) count += countNamed(child, name);
  return count;
}

// Steps change the background's thread ("t1") or another of the scenario's.
void writeTo(World& world, const QString& thread = QStringLiteral("t1")) {
  stream::FakeStreams& streams = world.mc.part<stream::FakeStreams>();
  streams.thread = thread;
  streams.environment = world.mc.environmentId;
}

// Picks `label` ("Branch changes", "Turn 2") from what the tab can show.
void pick(World& world, const QString& label) {
  Brick& brick = panel(world);
  QQuickItem* picker = brick.item(QStringLiteral("diffTurnPicker"));
  int index = -1;
  world.waitFor([&] {
    const QVariantList choices = diff(world).choices();
    for (qsizetype i = 0; i < choices.size(); ++i) {
      if (choices.at(i).toMap().value(QStringLiteral("label")) == label) index = int(i);
    }
    return index >= 0;
  }, [&] { return QStringLiteral("the diff to offer %1; it offers %2").arg(label, show(diff(world).choices())); });
  QMetaObject::invokeMethod(picker, "activated", Q_ARG(int, index));
  world.sync();
  waitForDiff(world);
}

// The branch's changes against its base.
void reviewBranch(World& world) {
  if (diff(world).selection() != ThreadDiff::Branch) pick(world, QStringLiteral("Branch changes"));
  expect(diff(world).selection() == ThreadDiff::Branch && diff(world).status() != QLatin1String("error"), describeDiff(world));
}

QObject* basesPopup(World& world) {
  QObject* popup = panel(world).root()->findChild<QObject*>(QStringLiteral("diffBases"));
  expect(popup != nullptr, QStringLiteral("the diff has no list of bases"));
  return popup;
}

// The list of bases to compare against, open with the checkout's refs.
Brick& openBases(World& world) {
  reviewBranch(world);
  Brick& brick = panel(world);
  if (!basesPopup(world)->property("opened").toBool()) brick.click(QStringLiteral("diffBasePicker"));
  world.waitFor([&] { return basesPopup(world)->property("opened").toBool() && !diff(world).basesLoading(); }, QStringLiteral("the bases to be listed"));
  return brick;
}

void type(Brick& brick, const QString& text) {
  for (const QChar ch : text) {
    if (ch == QLatin1Char('\n')) {
      QTest::keyClick(&brick.window(), Qt::Key_Return);
    } else {
      QTest::keyClick(&brick.window(), ch.toLatin1());
    }
  }
}

// Types `text` in the search of the bases.
void searchBases(World& world, const QString& text) {
  Brick& brick = openBases(world);
  brick.click(QStringLiteral("diffBaseRef"));
  type(brick, text);
  world.sync();
}

// The bases the list shows, by label.
QStringList basesShown(World& world) {
  Brick& brick = panel(world);
  brick.grab();
  QStringList labels;
  const std::function<void(QQuickItem*)> collect = [&](QQuickItem* item) {
    if (!item->isVisible()) return;
    if (item->objectName().startsWith(QLatin1String("diffBaseChoice-"))) labels.append(item->objectName().mid(15));
    for (QQuickItem* child : item->childItems()) collect(child);
  };
  collect(brick.window().contentItem());
  return labels;
}

// Picks a base as the user does: the one listed, else the ref typed.
void pickBase(World& world, const QString& ref) {
  Brick& brick = openBases(world);
  if (ref != QLatin1String("Automatic")) {
    brick.click(QStringLiteral("diffBaseRef"));
    type(brick, ref);
    world.sync();
  }
  if (basesShown(world).contains(ref)) {
    brick.click(QStringLiteral("diffBaseChoice-") + ref);
  } else {
    QTest::keyClick(&brick.window(), Qt::Key_Return);
  }
  world.sync();
  waitForDiff(world);
  expect(!basesPopup(world)->property("opened").toBool(), QStringLiteral("the list of bases stayed open"));
}

// The heading of `path`'s file, scrolled into view.
QQuickItem* fileHeader(World& world, const QString& path) {
  Brick& brick = panel(world);
  DiffModel& model = *diff(world).model();
  const int file = model.fileOf(path);
  expect(file >= 0, QStringLiteral("%1 is not in the diff; %2").arg(path, describeDiff(world)));
  QMetaObject::invokeMethod(rows(world), "positionViewAtIndex", Q_ARG(int, model.rowOfFile(file)), Q_ARG(int, 0));
  QQuickItem* header = nullptr;
  world.waitFor([&] {
    brick.grab();
    header = findNamed(brick.window().contentItem(), QStringLiteral("diffFile-") + path);
    return header != nullptr;
  }, QStringLiteral("the heading of %1 to be shown").arg(path));
  return header;
}

// An item of `path`'s heading.
QQuickItem* inHeading(World& world, const QString& path, const QString& name) {
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    found = findNamed(fileHeader(world, path), name);
    return found != nullptr;
  }, QStringLiteral("the heading of %1 to show %2").arg(path, name));
  return found;
}

// Opens `path`'s file by its heading.
void openInDiff(World& world, const QString& path) {
  DiffModel& model = *diff(world).model();
  QQuickItem* header = fileHeader(world, path);
  expect(!model.expanded(model.fileOf(path)), QStringLiteral("%1 is open already").arg(path));
  QTest::mouseClick(&panel(world).window(), Qt::LeftButton, Qt::NoModifier, panel(world).at(header, 0.3, 16 / header->height()));
  world.sync();
  expect(model.expanded(model.fileOf(path)), QStringLiteral("%1 did not open").arg(path));
}

// The lines `path` shows.
int linesOf(World& world, const QString& path) {
  DiffModel& model = *diff(world).model();
  const int file = model.fileOf(path);
  const int next = file + 1 < model.fileCount() ? model.rowOfFile(file + 1) : model.rowCount();
  return next - model.rowOfFile(file) - 1;
}

QStringList treeListing(World& world) {
  QStringList listed;
  for (const QVariant& node : diff(world).model()->tree()) {
    const QVariantMap entry = node.toMap();
    listed.append(QStringLiteral("%1%2%3").arg(QString(entry.value(QStringLiteral("depth")).toInt(), QLatin1Char(' ')), entry.value(QStringLiteral("name")).toString(),
                                             entry.value(QStringLiteral("kind")) == QLatin1String("folder") ? QStringLiteral("/") : QString()));
  }
  return listed;
}

// The file tree shown beside the diff.
QQuickItem* showTree(World& world) {
  Brick& brick = panel(world);
  QQuickItem* tree = brick.item(QStringLiteral("diffTreeRows"));
  if (!tree->isVisible()) chooseOption(world, QStringLiteral("diffTree"));
  world.waitFor([&] { return tree->isVisible(); }, QStringLiteral("the file tree to be shown"));
  return tree;
}

// The tree's row for `path`.
QQuickItem* treeNode(World& world, const QString& path) {
  Brick& brick = panel(world);
  showTree(world);
  QQuickItem* node = nullptr;
  world.waitFor([&] {
    brick.grab();
    const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
      if (item->objectName() == QLatin1String("diffTreeNode") && item->isVisible() && item->property("modelData").toMap().value(QStringLiteral("path")) == path) node = item;
      for (QQuickItem* child : item->childItems()) find(child);
    };
    node = nullptr;
    find(brick.window().contentItem());
    return node != nullptr;
  }, [&] { return QStringLiteral("the tree to list %1; it lists %2").arg(path, treeListing(world).join(QStringLiteral(", "))); });
  return node;
}

void chooseInTree(World& world, const QString& path) {
  QQuickItem* node = treeNode(world, path);
  QTest::mouseClick(&panel(world).window(), Qt::LeftButton, Qt::NoModifier, panel(world).at(node));
  world.sync();
}

// The checkpoint the thread's turn `turn` left, its run.
QString runOf(World& world, int turn) {
  stream::FakeStreams& streams = world.mc.part<stream::FakeStreams>();
  return streams.threads.value(streams.thread).value(QStringLiteral("checkpoint\ncp-%1").arg(turn)).value(QLatin1String("runId")).toString();
}

QVariantList toastTitles(World& world) {
  QVariantList titles;
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) titles.append(item.toMap().value(QStringLiteral("title")));
  return titles;
}

// A thread of the project "shop" beside the background's.
void addThread(World& world, const QString& id, const QString& title, const QJsonObject& fields = {}) {
  QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), QStringLiteral("shop")}, {QStringLiteral("branch"), QStringLiteral("feature/tax")},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
}

QString idOfTitle(World& world, const QString& title) {
  for (auto it = world.mc.threads.cbegin(); it != world.mc.threads.cend(); ++it) {
    if (it->value(QLatin1String("title")) == title) return it.key();
  }
  fail(QStringLiteral("no thread is called %1").arg(title));
  return {};
}

void openThread(World& world, const QString& id) {
  const QString key = world.mc.environmentId + QLatin1Char(':') + id;
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")) == key; }, QStringLiteral("the thread %1 to open").arg(id));
  // Its Diff tab, should the thread not have it open.
  world.bridge().dispatch(QStringLiteral("panel.open"), QVariantMap{{QStringLiteral("tab"), QStringLiteral("diff")}});
  world.sync();
}


// A note with a code block pasted in.
const QString kFencedNote = QStringLiteral("Use this instead:\n```ts\nexport const rate = taxTable[band];\n```\nThanks");

// The message a scenario sent.
struct SentReview {
  QJsonObject message;
};

const Steps steps([] {
  const QString q = kQuoted;

  // A thread in a worktree of its own: the review is of that checkout, not the project's.
  step(QStringLiteral("the thread works in a new worktree under the HAL-C2 home"), [](World& world, const Captures&, const Table&) {
    const QString id = world.mc.threads.constBegin().key();
    QJsonObject row = world.mc.threads.value(id);
    row.insert(QStringLiteral("worktreePath"), kWorktree);
    world.mc.threads.insert(id, row);
    world.mc.sendRow(id, row);
    world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("worktreePath")) == kWorktree; },
                  QStringLiteral("the thread to be in its worktree"));
  });
  step(QStringLiteral("the user reviews the working tree"), [](World& world, const Captures&, const Table&) {
    panel(world);
  });
  step(QStringLiteral("the worktree's changes are in the diff"), [](World& world, const Captures&, const Table&) {
    expect(!fake(world).asked.isEmpty() && fake(world).asked.constLast().value(QLatin1String("cwd")) == kWorktree,
           QStringLiteral("the review asked for %1").arg(fake(world).asked.isEmpty() ? QStringLiteral("nothing") : fake(world).asked.constLast().value(QLatin1String("cwd")).toString()));
    expect(diff(world).status() == QLatin1String("ready") && diff(world).model()->paths().contains(QStringLiteral("src/tax.ts")), describeDiff(world));
  });

  // Stacked and split.
  step(QStringLiteral("the user switches the diff to the split view"), [](World& world, const Captures&, const Table&) {
    panel(world);
    expect(!diff(world).model()->split(), QStringLiteral("the diff is already split"));
    chooseOption(world, QStringLiteral("diffSplit"));
  });
  step(QStringLiteral("the old and new lines are shown side by side"), [](World& world, const Captures&, const Table&) {
    DiffModel& model = *diff(world).model();
    expect(model.split(), QStringLiteral("the diff is not split"));
    bool paired = false;
    for (int row = 0; row < model.rowCount(); ++row) {
      const QModelIndex index = model.index(row);
      paired = paired || (model.data(index, DiffModel::SignRole) == QLatin1String("-") && model.data(index, DiffModel::RightSignRole) == QLatin1String("+"));
    }
    expect(paired, QStringLiteral("no removed line sits beside an added one"));
    // The reverse: one column again.
    chooseOption(world, QStringLiteral("diffSplit"));
    expect(!model.split(), QStringLiteral("the diff cannot be stacked again"));
  });

  // The base.
  step(QStringLiteral("the user compares the branch against %1 instead of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    reviewBranch(world);
    expect(diff(world).comparedBase() == c[1] && diff(world).model()->paths() == QStringList{QStringLiteral("src/cart.ts")}, describeDiff(world));
    pickBase(world, c[0]);
  });
  step(QStringLiteral("the diff shows the changes against %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(diff(world).status() == QLatin1String("ready") && diff(world).comparedBase() == c[0] && diff(world).comparedHead() == QLatin1String("feature/tax") &&
               diff(world).model()->paths() == QStringList{QStringLiteral("src/cart.ts"), QStringLiteral("src/pay.ts")},
           QStringLiteral("%1 against %2").arg(describeDiff(world), diff(world).comparedBase()));
    expect(fake(world).asked.last().value(QLatin1String("baseRef")) == c[0], QStringLiteral("the MC was asked %1").arg(show(fake(world).asked.last().toVariantMap())));
    // The reverse: no base named, the MC picks again.
    diff(world).setBaseRef(QString());
    waitForDiff(world);
    expect(diff(world).comparedBase() == QLatin1String("main"), QStringLiteral("the branch is compared against %1").arg(diff(world).comparedBase()));
  });

  // The file tree.
  step(QStringLiteral("the user shows the file tree of the diff"), [](World& world, const Captures&, const Table&) {
    chooseOption(world, QStringLiteral("diffTree"));
  });
  step(QStringLiteral("the changed files are listed by folder"), [](World& world, const Captures&, const Table&) {
    QStringList listed;
    for (const QVariant& node : diff(world).model()->tree()) {
      const QVariantMap entry = node.toMap();
      listed.append(QStringLiteral("%1%2%3").arg(QString(entry.value(QStringLiteral("depth")).toInt(), QLatin1Char(' ')), entry.value(QStringLiteral("name")).toString(),
                                               entry.value(QStringLiteral("kind")) == QLatin1String("folder") ? QStringLiteral("/") : QString()));
    }
    const QStringList wanted{QStringLiteral("src/"), QStringLiteral(" cart.ts"), QStringLiteral(" tax.ts"), QStringLiteral("README.md")};
    expect(listed == wanted, QStringLiteral("the tree lists [%1]").arg(listed.join(QStringLiteral(", "))));
    Brick& brick = panel(world);
    QQuickItem* tree = brick.item(QStringLiteral("diffTreeRows"));
    world.waitFor([&] { return tree->isVisible() && tree->property("count").toInt() == wanted.size(); },
                  [&] { return QStringLiteral("the tree to be drawn; it has %1 rows").arg(tree->property("count").toInt()); });
    expect(brick.shows(QStringLiteral("tax.ts")) && brick.shows(QStringLiteral("src")), QStringLiteral("the tree does not name its files"));
  });
  step(QStringLiteral("choosing a file jumps to it"), [](World& world, const Captures&, const Table&) {
    Brick& brick = panel(world);
    expect(fileAtTop(world) == QLatin1String("src/cart.ts"), QStringLiteral("the diff starts at %1").arg(fileAtTop(world)));
    QQuickItem* node = nullptr;
    const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
      if (item->objectName() == QLatin1String("diffTreeNode") && item->property("modelData").toMap().value(QStringLiteral("path")) == QLatin1String("src/tax.ts")) node = item;
      for (QQuickItem* child : item->childItems()) find(child);
    };
    find(brick.window().contentItem());
    expect(node != nullptr, QStringLiteral("the tree does not offer src/tax.ts"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(node));
    world.waitFor([&] { return fileAtTop(world) == QLatin1String("src/tax.ts"); },
                  [&] { return QStringLiteral("the diff to jump to src/tax.ts; its top is %1").arg(fileAtTop(world)); });
    // The reverse: the tree goes away again.
    chooseOption(world, QStringLiteral("diffTree"));
    expect(!brick.item(QStringLiteral("diffTreeRows"))->isVisible(), QStringLiteral("the tree is still shown"));
  });

  // Every file at once.
  step(QStringLiteral("the user collapses all files and then expands all files"), [](World& world, const Captures&, const Table&) {
    DiffModel& model = *diff(world).model();
    panel(world);
    expect(model.allExpanded(), QStringLiteral("the files do not start open"));
    chooseOption(world, QStringLiteral("diffExpandAll"));
    expect(model.rowCount() == model.fileCount(), QStringLiteral("%1 rows for %2 collapsed files").arg(model.rowCount()).arg(model.fileCount()));
    chooseOption(world, QStringLiteral("diffExpandAll"));
  });
  step(QStringLiteral("every file is shown open again"), [](World& world, const Captures&, const Table&) {
    DiffModel& model = *diff(world).model();
    expect(model.allExpanded() && model.fileCount() == 3, describeDiff(world));
    for (int file = 0; file < model.fileCount(); ++file) {
      const int next = file + 1 < model.fileCount() ? model.rowOfFile(file + 1) : model.rowCount();
      expect(next - model.rowOfFile(file) > 1, QStringLiteral("%1 shows no lines").arg(model.path(file)));
    }
  });

  // Wrapping.
  step(QStringLiteral("the user turns on line wrapping in the diff"), [](World& world, const Captures&, const Table&) {
    QQuickItem* view = rows(world);
    // Lines start unwrapped here, whatever the word wrap setting says.
    diff(world).setWrap(false);
    world.waitFor([&] { return view->property("contentWidth").toReal() > view->width(); }, QStringLiteral("the long line to scroll sideways"));
    expect(!diff(world).wrap() && view->property("contentWidth").toReal() > view->width(),
           QStringLiteral("the long line does not scroll sideways: the rows are %1 wide in a view of %2").arg(view->property("contentWidth").toReal()).arg(view->width()));
    chooseOption(world, QStringLiteral("diffWrap"));
  });
  step(QStringLiteral("long lines wrap instead of scrolling sideways"), [](World& world, const Captures&, const Table&) {
    QQuickItem* view = rows(world);
    world.waitFor([&] { return diff(world).wrap() && view->property("contentWidth").toReal() <= view->width(); },
                  [&] { return QStringLiteral("the rows to fit the view; they are %1 wide in %2").arg(view->property("contentWidth").toReal()).arg(view->width()); });
    // The reverse.
    chooseOption(world, QStringLiteral("diffWrap"));
    expect(!diff(world).wrap(), QStringLiteral("wrapping cannot be turned off again"));
  });

  // Too narrow to wrap: the setting stays on, the lines scroll instead.
  step(QStringLiteral("the user wraps long lines in the diff"), [](World& world, const Captures&, const Table&) {
    QQuickItem* view = rows(world);
    diff(world).setWrap(true);
    world.waitFor([&] { return view->property("contentWidth").toReal() <= view->width(); }, QStringLiteral("the long lines to wrap"));
  });
  step(QStringLiteral("the diff has room for fewer than forty characters of code"), [](World& world, const Captures&, const Table&) {
    Brick& brick = panel(world);
    // A sheet in a 900px window.
    brick.window().resize(380, 420);
    brick.root()->setSize(QSizeF(380, 420));
    QQuickItem* root = brick.root();
    world.waitFor([&] { return root->property("codeWidth").toReal() < root->property("wrapFloor").toReal(); },
                  [&] { return QStringLiteral("a line of code to have less than %1px; it has %2").arg(root->property("wrapFloor").toReal()).arg(root->property("codeWidth").toReal()); });
  });
  step(QStringLiteral("long lines scroll sideways under their line numbers"), [](World& world, const Captures&, const Table&) {
    QQuickItem* view = rows(world);
    QQuickItem* root = panel(world).root();
    world.waitFor([&] { return !root->property("wrap").toBool() && view->property("contentWidth").toReal() > view->width(); },
                  [&] { return QStringLiteral("the rows to scroll sideways; they are %1 wide in %2").arg(view->property("contentWidth").toReal()).arg(view->width()); });
    expect(diff(world).wrap(), QStringLiteral("the narrow panel turned the wrap setting off"));
  });
  step(QStringLiteral("they wrap again once the diff is wider"), [](World& world, const Captures&, const Table&) {
    QQuickItem* view = rows(world);
    Brick& brick = panel(world);
    QQuickItem* root = brick.root();
    brick.window().resize(900, 420);
    root->setSize(QSizeF(900, 420));
    world.waitFor([&] { return root->property("wrap").toBool() && view->property("contentWidth").toReal() <= view->width(); },
                  [&] { return QStringLiteral("the rows to wrap again; they are %1 wide in %2").arg(view->property("contentWidth").toReal()).arg(view->width()); });
  });

  // Refreshing.
  step(QStringLiteral("the user refreshes the diff"), [](World& world, const Captures&, const Table&) {
    panel(world);
    expect(diff(world).model()->fileCount() == 3, describeDiff(world));
    // The checkout moved on since the diff was read.
    fake(world).workingTree += patchChanging(QStringLiteral("src/checkout.ts"), {QStringLiteral("export const total = 1;")});
    chooseOption(world, QStringLiteral("diffReload"));
    waitForDiff(world);
  });
  step(QStringLiteral("the diff shows the checkout as it is now"), [](World& world, const Captures&, const Table&) {
    expect(diff(world).status() == QLatin1String("ready") && diff(world).model()->paths().contains(QStringLiteral("src/checkout.ts")) &&
               diff(world).model()->fileCount() == 4,
           describeDiff(world));
  });

  // A note on lines of the diff, for the prompt.
  // The comment box on lines `first` to `last` of `path`.
  const auto openComment = [](World& world, int first, int last, const QString& path) {
    Brick& brick = panel(world);
    // The line's own button, shown while the pointer is over the line.
    QQuickItem* button = nullptr;
    const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
      if (item->objectName() == QLatin1String("diffLineComment")) {
        QObject* line = item->property("row").value<QObject*>();
        if (line && line->property("newLine").toInt() == first && line->property("sign").toString() == QLatin1String("+") &&
            diff(world).model()->path(line->property("file").toInt()) == path) {
          button = item;
        }
      }
      for (QQuickItem* child : item->childItems()) find(child);
    };
    world.waitFor([&] {
      brick.grab();
      find(brick.window().contentItem());
      return button != nullptr;
    }, QStringLiteral("line %1 of %2 to be shown").arg(first).arg(path));
    // The row is as wide as the longest line: its start is what is in view.
    const QPoint onLine = button->parentItem()->mapToScene(QPointF(60, button->parentItem()->height() / 2)).toPoint();
    QTest::mouseMove(&brick.window(), onLine + QPoint(40, 0));
    QTest::mouseMove(&brick.window(), onLine);
    world.waitFor([&] { return button->isVisible(); }, QStringLiteral("the line to offer a comment"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(button));
    QQuickItem* lastLine = brick.item(QStringLiteral("diffCommentLast"));
    world.waitFor([&] { return lastLine->isVisible(); }, QStringLiteral("the comment box to open"));
    lastLine->setProperty("text", QString::number(last));
  };
  const auto commentOn = [openComment](World& world, const QString& note, int first, int last, const QString& path) {
    Brick& brick = panel(world);
    openComment(world, first, last, path);
    brick.click(QStringLiteral("diffCommentNote"));
    for (const QChar ch : note) QTest::keyClick(&brick.window(), ch.toLatin1());
    brick.click(QStringLiteral("diffCommentAdd"));
    world.sync();
  };
  const auto comments = [](World& world) { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("reviewComments")).toList(); };
  // What a send of "Please fix this" carries to the MC.
  const auto sent = [](World& world) {
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("Please fix this")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
    QJsonObject message;
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) message = command;
    }
    expect(!message.isEmpty(), QStringLiteral("no message was sent; the MC has %1").arg(world.describeCommands()));
    return message;
  };
  step(QStringLiteral("the user comments %1 on lines (\\d+) to (\\d+) of %1").arg(q), [commentOn](World& world, const Captures& c, const Table&) {
    commentOn(world, c[0], c[1].toInt(), c[2].toInt(), c[3]);
  });
  step(QStringLiteral("the user commented on lines (\\d+) to (\\d+) of %1").arg(q), [commentOn](World& world, const Captures& c, const Table&) {
    commentOn(world, QStringLiteral("Use the tax table"), c[0].toInt(), c[1].toInt(), c[2]);
  });
  step(QStringLiteral("the composer carries that comment with the file and line range"), [comments, sent](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return comments(world).size() == 1; }, [&] { return QStringLiteral("the comment; the composer is %1").arg(show(world.state(QStringLiteral("composer")))); });
    const QVariantMap chip = comments(world).first().toMap();
    expect(chip.value(QStringLiteral("label")) == QLatin1String("src/cart.ts L10-12") && chip.value(QStringLiteral("text")) == QLatin1String("Use the tax table"),
           QStringLiteral("the composer carries %1").arg(show(chip)));
    // Sent, the message names the chip and carries the note, the file and the lines.
    const QJsonObject message = sent(world);
    const QJsonArray records = message.value(QLatin1String("context")).toObject().value(QLatin1String("records")).toArray();
    const QJsonObject record = records.first().toObject();
    const QString reference = QStringLiteral("[src/cart.ts L10-12](hal-c2-context://v1/review-comment/%1)").arg(record.value(QLatin1String("contextId")).toString());
    expect(message.value(QLatin1String("text")).toString() == QStringLiteral("Please fix this\n\n") + reference, QStringLiteral("the message reads %1").arg(message.value(QLatin1String("text")).toString()));
    expect(records.size() == 1 && record.value(QLatin1String("kind")) == QLatin1String("review-comment") && record.value(QLatin1String("filePath")) == QLatin1String("src/cart.ts") &&
               record.value(QLatin1String("rangeLabel")) == QLatin1String("+10 to +12") && record.value(QLatin1String("text")) == QLatin1String("Use the tax table") &&
               record.value(QLatin1String("diff")) == QLatin1String("+export const rate9 = 9;\n+export const rate10 = 10;\n+export const rate11 = 11;") &&
               record.value(QLatin1String("endIndex")).toInt() - record.value(QLatin1String("startIndex")).toInt() == 2,
           QStringLiteral("the message carries %1").arg(show(records.toVariantList())));
    expect(comments(world).isEmpty(), QStringLiteral("the sent comment is still on the draft"));
  });
  step(QStringLiteral("the user deletes that comment"), [comments](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return comments(world).size() == 1; }, QStringLiteral("the comment to be on the draft"));
    // The comment's chip on the composer.
    world.bridge().dispatch(QStringLiteral("composer.reviewComment.remove"), QVariantMap{{QStringLiteral("id"), comments(world).first().toMap().value(QStringLiteral("id"))}});
    world.sync();
  });
  step(QStringLiteral("the composer no longer carries it"), [comments, sent](World& world, const Captures&, const Table&) {
    expect(comments(world).isEmpty(), QStringLiteral("the composer carries %1").arg(show(comments(world))));
    const QJsonObject message = sent(world);
    expect(message.value(QLatin1String("text")) == QLatin1String("Please fix this") && !message.contains(QLatin1String("context")),
           QStringLiteral("the message carries %1").arg(show(message.toVariantMap())));
  });

  // The user's editor.
  step(QStringLiteral("no editor is available on this environment"), [](World& world, const Captures&, const Table&) {
    fake(world).noEditor = true;
    setEditors(world, QJsonArray());
  });
  step(QStringLiteral("the user opens %1 from the diff").arg(q), [](World& world, const Captures& c, const Table&) {
    haveEditor(world, c[0]);
    Brick& brick = panel(world);
    QQuickItem* header = brick.item(QStringLiteral("diffFile-") + c[0]);
    QQuickItem* button = nullptr;
    const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
      if (item->objectName() == QLatin1String("diffOpenInEditor")) button = item;
      for (QQuickItem* child : item->childItems()) find(child);
    };
    find(header);
    expect(button != nullptr && button->isVisible(), QStringLiteral("%1 cannot be opened from the diff").arg(c[0]));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(button));
    world.sync();
  });
  step(QStringLiteral("the user opens %1 from the commit review").arg(q), [](World& world, const Captures& c, const Table&) {
    haveEditor(world, c[0]);
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nGitActions {}\n", QSize(900, 700));
    Brick& brick = *world.brick;
    // The review of what will be committed: the git menu's Commit.
    QObject* dialog = brick.root()->findChild<QObject*>(QStringLiteral("commitDialog"));
    expect(dialog != nullptr, QStringLiteral("the git actions have no commit review"));
    QMetaObject::invokeMethod(dialog, "open");
    const QString name = QStringLiteral("fileOpen-") + c[0];
    world.waitFor([&] { return dialog->property("opened").toBool(); }, QStringLiteral("the commit review to open"));
    brick.click(name);
    world.sync();
  });
  // Following the checkout.
  step(QStringLiteral("the user is reviewing the working tree"), [](World& world, const Captures&, const Table&) {
    panel(world);
    expect(diff(world).selection() == -1 && diff(world).reviewing() && diff(world).status() == QLatin1String("ready"), describeDiff(world));
    QObject::connect(&diff(world), &ThreadDiff::statusChanged, &diff(world), [&world] { fake(world).statuses.append(diff(world).status()); });
    // What the agent's edit of src/cart.ts (the Files steps' "the agent changes") leaves.
    writeTo(world);
    fake(world).workingTree = patchChanging(QStringLiteral("src/cart.ts"), lines(QStringLiteral("rate"), 60) + QStringList{kLongLine, QStringLiteral("export const agent = true;")}) +
                              patchChanging(QStringLiteral("src/tax.ts"), lines(QStringLiteral("band"), 3)) +
                              patchChanging(QStringLiteral("README.md"), lines(QStringLiteral("note"), 40));
  });
  step(QStringLiteral("the diff shows the new changes without the user refreshing"), [](World& world, const Captures&, const Table&) {
    DiffModel& model = *diff(world).model();
    world.waitFor([&] { return model.additions() == 105; }, [&] { return QStringLiteral("the agent's line to be shown; the diff adds %1 lines").arg(model.additions()); });
    expect(!fake(world).statuses.contains(QStringLiteral("loading")), QStringLiteral("the diff went %1 meanwhile").arg(fake(world).statuses.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("coming back to the window after working elsewhere shows the checkout as it is now"), [](World& world, const Captures&, const Table&) {
    QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationInactive);
    world.sync();
    // Changed elsewhere, with nothing in the thread to say so.
    fake(world).workingTree += patchChanging(QStringLiteral("src/checkout.ts"), {QStringLiteral("export const total = 1;")});
    QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationActive);
    world.waitFor([&] { return diff(world).model()->paths().contains(QStringLiteral("src/checkout.ts")); }, [&] { return describeDiff(world); });
    expect(!fake(world).statuses.contains(QStringLiteral("loading")), QStringLiteral("the diff went %1 meanwhile").arg(fake(world).statuses.join(QStringLiteral(", "))));
  });

  // The branch's base.
  step(QStringLiteral("the branch %1 was started from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).head = c[0];
    fake(world).automaticBase = c[1];
  });
  step(QStringLiteral("the user reviews the branch changes"), [](World& world, const Captures&, const Table&) {
    reviewBranch(world);
  });
  step(QStringLiteral("the diff compares against %1 and the choice of base reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString shown = panel(world).item(QStringLiteral("diffBasePicker"))->property("text").toString();
    expect(diff(world).status() == QLatin1String("ready") && diff(world).comparedBase() == c[0] && shown == c[1],
           QStringLiteral("%1 against %2, the base reads %3").arg(describeDiff(world), diff(world).comparedBase(), shown));
  });
  step(QStringLiteral("the user picks %1 as the base").arg(q), [](World& world, const Captures& c, const Table&) {
    pickBase(world, c[0]);
  });
  step(QStringLiteral("the user picks %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    pickBase(world, c[0]);
  });
  step(QStringLiteral("the diff compares against %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList wanted;
    for (const auto& [path, part] : filesOf(fake(world).branch.value(c[0]))) wanted.append(path);
    expect(diff(world).status() == QLatin1String("ready") && diff(world).comparedBase() == c[0] && diff(world).model()->paths() == wanted,
           QStringLiteral("%1 against %2").arg(describeDiff(world), diff(world).comparedBase()));
    const QString shown = panel(world).item(QStringLiteral("diffBasePicker"))->property("text").toString();
    const QString reads = c[0] == fake(world).automaticBase && diff(world).baseRef().isEmpty() ? QStringLiteral("Automatic") : c[0];
    expect(shown == reads, QStringLiteral("the base reads %1").arg(shown));
  });
  step(QStringLiteral("%1 exists on the remote and has no local branch").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeGitBranches(world, QStringLiteral("/work/shop"), {}, {c[0]});
  });
  step(QStringLiteral("%1 exists locally and as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeGitBranches(world, QStringLiteral("/work/shop"), {c[0]}, {c[1]});
  });
  step(QStringLiteral("the user searches the bases to compare against for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    searchBases(world, c[0]);
  });
  step(QStringLiteral("the user opens the bases to compare against"), [](World& world, const Captures&, const Table&) {
    openBases(world);
  });
  step(QStringLiteral("%1 is offered and marked as remote only").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return basesShown(world) == QStringList{c[0]}; }, [&] { return QStringLiteral("only %1 to be offered; %2 are").arg(c[0], basesShown(world).join(QStringLiteral(", "))); });
    QQuickItem* choice = panel(world).item(QStringLiteral("diffBaseChoice-") + c[0]);
    expect(findNamed(choice, QStringLiteral("diffBaseRemoteOnly")) != nullptr, QStringLiteral("%1 is not marked as remote only").arg(c[0]));
  });
  step(QStringLiteral("a search that matches nothing says no refs match"), [](World& world, const Captures&, const Table&) {
    Brick& brick = panel(world);
    type(brick, QStringLiteral("zzz"));
    world.sync();
    QQuickItem* empty = brick.item(QStringLiteral("diffBaseEmpty"));
    world.waitFor([&] { return basesShown(world).isEmpty() && empty->isVisible(); }, [&] { return QStringLiteral("nothing to be offered; %1 are").arg(basesShown(world).join(QStringLiteral(", "))); });
    expect(empty->property("text") == QLatin1String("No matching refs."), QStringLiteral("the list says %1").arg(empty->property("text").toString()));
  });
  step(QStringLiteral("%1 is offered once").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return basesShown(world).contains(c[0]); }, [&] { return QStringLiteral("%1 to be offered; %2 are").arg(c[0], basesShown(world).join(QStringLiteral(", "))); });
    const QStringList shown = basesShown(world);
    expect(shown.count(c[0]) == 1 && !shown.contains(QStringLiteral("origin/") + c[0]), QStringLiteral("the bases are %1").arg(shown.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("searching for %1 finds that same entry").arg(q), [](World& world, const Captures& c, const Table&) {
    searchBases(world, c[0]);
    world.waitFor([&] { return basesShown(world) == QStringList{QStringLiteral("release")}; }, [&] { return QStringLiteral("the search to find release; it finds %1").arg(basesShown(world).join(QStringLiteral(", "))); });
  });
  step(QStringLiteral("choosing it compares against the local %1").arg(q), [](World& world, const Captures& c, const Table&) {
    panel(world).click(QStringLiteral("diffBaseChoice-") + c[0]);
    world.sync();
    waitForDiff(world);
    expect(diff(world).baseRef() == c[0] && diff(world).comparedBase() == c[0] && fake(world).asked.last().value(QLatin1String("baseRef")) == c[0],
           QStringLiteral("the MC was asked %1").arg(show(fake(world).asked.last().toVariantMap())));
  });
  step(QStringLiteral("the user is reviewing the changes of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    reviewBranch(world);
    expect(diff(world).comparedHead() == c[0], QStringLiteral("the diff is of %1").arg(diff(world).comparedHead()));
  });
  step(QStringLiteral("%1 is not among the bases").arg(q), [](World& world, const Captures& c, const Table&) {
    // The checkout's other branch is, so the refs are listed.
    world.waitFor([&] { return basesShown(world).contains(QStringLiteral("main")); }, [&] { return QStringLiteral("main to be offered; %1 are").arg(basesShown(world).join(QStringLiteral(", "))); });
    expect(!basesShown(world).contains(c[0]), QStringLiteral("the bases are %1").arg(basesShown(world).join(QStringLiteral(", "))));
  });

  // A diff too large to load whole.
  step(QStringLiteral("the changes are too large for the diff to carry every file's patch"), [](World& world, const Captures&, const Table&) {
    fake(world).truncated = true;
    fake(world).unpatched.append(QJsonObject{{QStringLiteral("path"), QStringLiteral("assets/data.bin")}, {QStringLiteral("previousPath"), QJsonValue()},
                                             {QStringLiteral("additions"), 5000}, {QStringLiteral("deletions"), 0}});
  });
  step(QStringLiteral("the user reviews the changes"), [](World& world, const Captures&, const Table&) {
    panel(world);
  });
  step(QStringLiteral("the diff says it is incomplete while its totals still cover every change"), [](World& world, const Captures&, const Table&) {
    DiffModel& model = *diff(world).model();
    expect(diff(world).status() == QLatin1String("ready") && diff(world).truncated(), describeDiff(world));
    expect(panel(world).item(QStringLiteral("diffTruncated"))->isVisible(), QStringLiteral("the diff does not say it is incomplete"));
    expect(model.fileCount() == 4 && model.additions() == 104 + 5000 && model.deletions() == 3,
           QStringLiteral("%1 files, +%2 -%3").arg(model.fileCount()).arg(model.additions()).arg(model.deletions()));
    for (int file = 0; file < model.fileCount(); ++file) {
      expect(!model.expanded(file) && model.state(file) == QLatin1String("unloaded"), QStringLiteral("%1 is %2").arg(model.path(file), model.state(file)));
    }
  });
  step(QStringLiteral("a file's changes are loaded when the user opens that file"), [](World& world, const Captures&, const Table&) {
    const qsizetype asked = fake(world).asked.size();
    // Nothing is asked for a file before it is opened.
    expect(asked == 1, QStringLiteral("the MC was asked %1 times").arg(asked));
    openInDiff(world, QStringLiteral("src/tax.ts"));
    DiffModel& model = *diff(world).model();
    world.waitFor([&] { return model.state(model.fileOf(QStringLiteral("src/tax.ts"))).isEmpty(); }, [&] { return QStringLiteral("src/tax.ts to load; it is %1").arg(model.state(model.fileOf(QStringLiteral("src/tax.ts")))); });
    expect(fake(world).asked.last().value(QLatin1String("file")).toObject().value(QLatin1String("path")) == QLatin1String("src/tax.ts"),
           QStringLiteral("the MC was asked %1").arg(show(fake(world).asked.last().toVariantMap())));
    expect(linesOf(world, QStringLiteral("src/tax.ts")) > 3, QStringLiteral("src/tax.ts shows %1 lines").arg(linesOf(world, QStringLiteral("src/tax.ts"))));
    // The others are still unloaded.
    expect(model.state(model.fileOf(QStringLiteral("src/cart.ts"))) == QLatin1String("unloaded"), QStringLiteral("src/cart.ts was loaded too"));
  });
  step(QStringLiteral("a file whose changes cannot be loaded says no patch is available for it"), [](World& world, const Captures&, const Table&) {
    const QString path = QStringLiteral("assets/data.bin");
    openInDiff(world, path);
    QQuickItem* note = inHeading(world, path, QStringLiteral("diffFileNote"));
    world.waitFor([&] { return note->property("text") == QLatin1String("No patch available for this file."); },
                  [&] { return QStringLiteral("the file to say why; it says %1").arg(note->property("text").toString()); });
  });

  // One file's changes.
  step(QStringLiteral("%1 has changes too large to show in full").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).truncated = true;
    fake(world).partial.insert(c[0]);
  });
  step(QStringLiteral("loading the changes of %1 failed").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).truncated = true;
    fake(world).failing.insert(c[0]);
  });
  step(QStringLiteral("the user opens %1 in the diff").arg(q), [](World& world, const Captures& c, const Table&) {
    openInDiff(world, c[0]);
  });
  step(QStringLiteral("the file is marked as a partial preview"), [](World& world, const Captures&, const Table&) {
    inHeading(world, QStringLiteral("src/cart.ts"), QStringLiteral("diffFilePartial"));
    expect(linesOf(world, QStringLiteral("src/cart.ts")) > 0, QStringLiteral("the partial file shows no lines"));
  });
  step(QStringLiteral("the mark explains that the file is too large to show in full and that the counts include all changes"), [](World& world, const Captures&, const Table&) {
    Brick& brick = panel(world);
    QQuickItem* mark = inHeading(world, QStringLiteral("src/cart.ts"), QStringLiteral("diffFilePartial"));
    const QString why = QStringLiteral("This file is too large to show in full. Counts include all changes.");
    expect(!brick.shows(why), QStringLiteral("the explanation is shown before the pointer is over the mark"));
    QTest::mouseMove(&brick.window(), brick.at(mark) + QPoint(-30, 0));
    QTest::mouseMove(&brick.window(), brick.at(mark));
    world.waitFor([&] { return brick.shows(why); }, QStringLiteral("the mark to explain itself"));
  });
  step(QStringLiteral("the file offers to retry loading the diff"), [](World& world, const Captures&, const Table&) {
    inHeading(world, QStringLiteral("src/cart.ts"), QStringLiteral("diffFileRetry"));
    expect(inHeading(world, QStringLiteral("src/cart.ts"), QStringLiteral("diffFileNote"))->property("text") == QLatin1String("git diff timed out"),
           QStringLiteral("the file does not say why"));
  });
  step(QStringLiteral("the user retries and the environment answers"), [](World& world, const Captures&, const Table&) {
    QQuickItem* retry = inHeading(world, QStringLiteral("src/cart.ts"), QStringLiteral("diffFileRetry"));
    QTest::mouseClick(&panel(world).window(), Qt::LeftButton, Qt::NoModifier, panel(world).at(retry));
    world.sync();
  });
  step(QStringLiteral("the changes of %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    DiffModel& model = *diff(world).model();
    world.waitFor([&] { return model.state(model.fileOf(c[0])).isEmpty() && linesOf(world, c[0]) > 60; },
                  [&] { return QStringLiteral("%1 to show its lines; it is %2 with %3").arg(c[0], model.state(model.fileOf(c[0]))).arg(linesOf(world, c[0])); });
  });
  step(QStringLiteral("the user opened a diff and the checkout was changed so that this diff no longer exists"), [](World& world, const Captures&, const Table&) {
    fake(world).truncated = true;
    panel(world);
    expect(diff(world).truncated() && diff(world).model()->fileCount() == 3, describeDiff(world));
    fake(world).gone = true;
    fake(world).workingTree = patchChanging(QStringLiteral("src/tax.ts"), lines(QStringLiteral("band"), 3));
  });
  step(QStringLiteral("the file says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* note = inHeading(world, QStringLiteral("src/cart.ts"), QStringLiteral("diffFileNote"));
    world.waitFor([&] { return note->property("text") == c[0]; }, [&] { return QStringLiteral("the file says %1").arg(note->property("text").toString()); });
  });
  step(QStringLiteral("the files that still differ are listed again"), [](World& world, const Captures&, const Table&) {
    const QStringList wanted{QStringLiteral("src/tax.ts"), QStringLiteral("src/checkout.ts")};
    expect(diff(world).status() == QLatin1String("ready") && diff(world).model()->paths() == wanted, describeDiff(world));
  });

  // Nothing to show.
  step(QStringLiteral("the user reviews a selection that changed nothing"), [](World& world, const Captures&, const Table&) {
    writeTo(world);
    finishTurnWithPatch(world, 1, QString());
    panel(world);
  });
  step(QStringLiteral("the user reviews a selection the MC has no patch for"), [](World& world, const Captures&, const Table&) {
    fake(world).noSource = true;
    panel(world);
  });
  step(QStringLiteral("the diff says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = panel(world);
    QQuickItem* message = brick.item(QStringLiteral("diffMessage"));
    world.waitFor([&] { return message->isVisible() && brick.shows(c[0]); }, [&] { return QStringLiteral("the diff to say %1; %2").arg(c[0], describeDiff(world)); });
  });

  // Each thread's own choice.
  step(QStringLiteral("the user reviews %1 in the thread %1 and the branch against %1 in the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The background's thread is the first; the second works in its own worktree.
    world.mc.threads[QStringLiteral("t1")].insert(QStringLiteral("title"), c[1]);
    writeTo(world);
    finishTurnWithPatch(world, 1, patchChanging(QStringLiteral("src/turn1.ts"), {QStringLiteral("export const one = 1;")}));
    finishTurnWithPatch(world, 2, patchChanging(QStringLiteral("src/turn2.ts"), {QStringLiteral("export const two = 2;")}));
    finishTurnWithPatch(world, 3, patchChanging(QStringLiteral("src/turn3.ts"), {QStringLiteral("export const three = 3;")}));
    pick(world, c[0]);
    expect(diff(world).shownTurn() == 2, describeDiff(world));
    addThread(world, QStringLiteral("fees"), c[3]);
    openThread(world, QStringLiteral("fees"));
    pickBase(world, c[2]);
    expect(diff(world).comparedBase() == c[2], describeDiff(world));
  });
  step(QStringLiteral("the user switches between %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openThread(world, idOfTitle(world, c[0]));
    world.waitFor([&] { return diff(world).status() == QLatin1String("ready"); }, [&] { return describeDiff(world); });
  });
  step(QStringLiteral("each thread shows its own selection with its own base"), [](World& world, const Captures&, const Table&) {
    // Tax, open now.
    world.waitFor([&] { return diff(world).selection() == 2 && diff(world).status() == QLatin1String("ready"); }, [&] { return QStringLiteral("Tax to show turn 2; %1").arg(describeDiff(world)); });
    expect(diff(world).model()->paths() == QStringList{QStringLiteral("src/turn2.ts")}, describeDiff(world));
    openThread(world, QStringLiteral("fees"));
    world.waitFor([&] { return diff(world).selection() == ThreadDiff::Branch && diff(world).status() == QLatin1String("ready"); }, [&] { return QStringLiteral("Fees to show its branch; %1").arg(describeDiff(world)); });
    expect(diff(world).baseRef() == QLatin1String("origin/main") && diff(world).comparedBase() == QLatin1String("origin/main"),
           QStringLiteral("Fees compares against %1").arg(diff(world).comparedBase()));
    expect(panel(world).item(QStringLiteral("diffBasePicker"))->property("text") == QLatin1String("origin/main"), QStringLiteral("the base does not read origin/main"));
  });
  step(QStringLiteral("a thread that was never reviewed opens on the working tree without needing git status"), [](World& world, const Captures&, const Table&) {
    // A worktree whose git status the MC never sends.
    const QString worktree = QStringLiteral("/work/shop-new");
    addThread(world, QStringLiteral("fresh"), QStringLiteral("New work"), {{QStringLiteral("worktreePath"), worktree}});
    openThread(world, QStringLiteral("fresh"));
    world.waitFor([&] { return diff(world).reviewing() && diff(world).selection() == -1 && diff(world).status() == QLatin1String("ready"); },
                  [&] { return QStringLiteral("the working tree; %1").arg(describeDiff(world)); });
    expect(fake(world).asked.last().value(QLatin1String("cwd")) == worktree && !fake(world).asked.last().contains(QLatin1String("baseRef")),
           QStringLiteral("the MC was asked %1").arg(show(fake(world).asked.last().toVariantMap())));
  });

  // A turn that is rolled back.
  step(QStringLiteral("the user is reviewing %1 of the thread").arg(q), [](World& world, const Captures& c, const Table&) {
    writeTo(world);
    for (int turn = 1; turn <= 3; ++turn) {
      finishTurnWithPatch(world, turn, patchChanging(QStringLiteral("src/turn%1.ts").arg(turn), {QStringLiteral("export const turn = %1;").arg(turn)}));
    }
    pick(world, c[0]);
    expect(diff(world).selection() == 3 && diff(world).status() == QLatin1String("ready"), describeDiff(world));
  });
  step(QStringLiteral("the thread is rolled back to turn (\\d+)"), [](World& world, const Captures& c, const Table&) {
    // As the MC's rollback does: the later runs are rolled back, their checkpoints stale.
    for (int turn = c[0].toInt() + 1; turn <= 3; ++turn) {
      stream::set(world, QStringLiteral("run"), runOf(world, turn), {{QStringLiteral("status"), QStringLiteral("rolled_back")}});
      stream::set(world, QStringLiteral("checkpoint"), QStringLiteral("cp-%1").arg(turn), {{QStringLiteral("status"), QStringLiteral("stale")}});
    }
    world.sync();
  });
  step(QStringLiteral("the diff shows the latest turn"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return diff(world).latestTurn() == 2 && diff(world).shownTurn() == 2 && diff(world).status() == QLatin1String("ready"); },
                  [&] { return QStringLiteral("turn 2; the diff shows turn %1 of %2: %3").arg(diff(world).shownTurn()).arg(diff(world).latestTurn()).arg(describeDiff(world)); });
    expect(diff(world).model()->paths() == QStringList{QStringLiteral("src/turn2.ts")}, describeDiff(world));
    const QString picked = panel(world).item(QStringLiteral("diffTurnPicker"))->property("currentText").toString();
    expect(picked == QLatin1String("Latest turn") || picked.contains(QLatin1String("Latest")), QStringLiteral("the picker reads %1").arg(picked));
  });

  // The file tree.
  step(QStringLiteral("%1 is collapsed in the diff").arg(q), [](World& world, const Captures& c, const Table&) {
    DiffModel& model = *diff(world).model();
    QQuickItem* header = fileHeader(world, c[0]);
    QTest::mouseClick(&panel(world).window(), Qt::LeftButton, Qt::NoModifier, panel(world).at(header, 0.3, 16 / header->height()));
    world.sync();
    expect(!model.expanded(model.fileOf(c[0])), QStringLiteral("%1 did not collapse").arg(c[0]));
  });
  step(QStringLiteral("the user chooses %1 in the file tree").arg(q), [](World& world, const Captures& c, const Table&) {
    // Somewhere else first, so choosing it has to scroll.
    QMetaObject::invokeMethod(rows(world), "positionViewAtEnd");
    world.waitFor([&] { return fileAtTop(world) != c[0]; }, QStringLiteral("the diff to scroll away"));
    chooseInTree(world, c[0]);
  });
  const auto scrolledTo = [](World& world, const QString& path) {
    DiffModel& model = *diff(world).model();
    world.waitFor([&] { return model.expanded(model.fileOf(path)) && fileAtTop(world) == path; },
                  [&] { return QStringLiteral("%1 open at the top; the top is %2").arg(path, fileAtTop(world)); });
  };
  step(QStringLiteral("%1 opens and is scrolled to").arg(q), [scrolledTo](World& world, const Captures& c, const Table&) { scrolledTo(world, c[0]); });
  step(QStringLiteral("the user scrolls away and chooses %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    QMetaObject::invokeMethod(rows(world), "positionViewAtEnd");
    world.waitFor([&] { return fileAtTop(world) != c[0]; }, QStringLiteral("the diff to scroll away"));
    chooseInTree(world, c[0]);
  });
  step(QStringLiteral("%1 is scrolled to again").arg(q), [scrolledTo](World& world, const Captures& c, const Table&) { scrolledTo(world, c[0]); });
  step(QStringLiteral("the user closed the folder %1 in the diff's file tree").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).workingTree += patchChanging(c[0] + QStringLiteral("/money.ts"), {QStringLiteral("export const cents = 100;")});
    chooseInTree(world, c[0]);
    expect(!diff(world).model()->folderOpen(c[0]), QStringLiteral("%1 is still open").arg(c[0]));
  });
  step(QStringLiteral("a refresh brings a new changed file in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).workingTree += patchChanging(c[0] + QStringLiteral("/round.ts"), {QStringLiteral("export const round = Math.round;")});
    chooseOption(world, QStringLiteral("diffReload"));
    waitForDiff(world);
    world.waitFor([&] { return diff(world).model()->paths().contains(c[0] + QStringLiteral("/round.ts")); }, [&] { return describeDiff(world); });
  });
  step(QStringLiteral("%1 stays closed").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!diff(world).model()->folderOpen(c[0]), QStringLiteral("%1 opened again").arg(c[0]));
    treeNode(world, c[0]);
    expect(countNamed(panel(world).window().contentItem(), QStringLiteral("diffTreeNode")) == 5,
           QStringLiteral("the tree shows %1 rows of %2").arg(countNamed(panel(world).window().contentItem(), QStringLiteral("diffTreeNode"))).arg(treeListing(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the new file is listed in it"), [](World& world, const Captures&, const Table&) {
    const QStringList listed = treeListing(world);
    const qsizetype folder = listed.indexOf(QStringLiteral(" lib/"));
    expect(folder >= 0 && listed.mid(folder + 1, 2) == QStringList{QStringLiteral("  money.ts"), QStringLiteral("  round.ts")}, QStringLiteral("the tree lists %1").arg(listed.join(QStringLiteral(", "))));
    // The way back: opened, the folder shows it.
    chooseInTree(world, QStringLiteral("src/lib"));
    treeNode(world, QStringLiteral("src/lib/round.ts"));
  });
  step(QStringLiteral("the diff changes %1 before %1 before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).workingTree.clear();
    for (const QString& path : c) fake(world).workingTree += patchChanging(path, {QStringLiteral("export const changed = true;")});
  });
  step(QStringLiteral("each folder sits where its first changed file is"), [](World& world, const Captures&, const Table&) {
    const QStringList wanted{QStringLiteral("src/"), QStringLiteral(" b.ts"), QStringLiteral(" a.ts"), QStringLiteral("docs/"), QStringLiteral(" a.md")};
    expect(treeListing(world) == wanted, QStringLiteral("the tree lists %1").arg(treeListing(world).join(QStringLiteral(", "))));
    treeNode(world, QStringLiteral("docs/a.md"));
  });
  step(QStringLiteral("%1 was a regular file and is now a symbolic link").arg(q), [](World& world, const Captures& c, const Table&) {
    // As git shows a type change: the file deleted, and a link of its name added.
    fake(world).workingTree = QStringLiteral("diff --git a/%1 b/%1\ndeleted file mode 100644\n--- a/%1\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-const cart = [];\n-export const tax = 0;\n"
                                             "diff --git a/%1 b/%1\nnew file mode 120000\n--- /dev/null\n+++ b/%1\n@@ -0,0 +1 @@\n+lib/cart.ts\n\\ No newline at end of file\n")
                                  .arg(c[0]) +
                              patchChanging(QStringLiteral("src/tax.ts"), lines(QStringLiteral("band"), 3));
  });
  step(QStringLiteral("%1 is listed once as modified").arg(q), [](World& world, const Captures& c, const Table&) {
    int listed = 0;
    QString change;
    for (const QVariant& node : diff(world).model()->tree()) {
      if (node.toMap().value(QStringLiteral("path")) != c[0]) continue;
      ++listed;
      change = node.toMap().value(QStringLiteral("change")).toString();
    }
    expect(listed == 1 && change == QLatin1String("modified"), QStringLiteral("%1 is listed %2 times, %3").arg(c[0]).arg(listed).arg(change));
    treeNode(world, c[0]);
  });

  // A file's heading.
  step(QStringLiteral("the user copies the path of %1 from its heading in the diff").arg(q), [](World& world, const Captures& c, const Table&) {
    world.clipboard.clear();
    QQuickItem* copy = inHeading(world, c[0], QStringLiteral("diffCopyPath"));
    QTest::mouseClick(&panel(world).window(), Qt::LeftButton, Qt::NoModifier, panel(world).at(copy));
    world.sync();
  });
  step(QStringLiteral("the user is told the path was copied"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toastTitles(world).contains(QStringLiteral("Path copied")); }, [&] { return QStringLiteral("the toasts are %1").arg(show(toastTitles(world))); });
  });
  step(QStringLiteral("the environment has a file manager and the editors %1, %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("VS Code") && c[1] == QLatin1String("Zed"), QStringLiteral("only VS Code and Zed are faked"));
    setEditors(world, QJsonArray{QStringLiteral("file-manager"), QStringLiteral("vscode"), QStringLiteral("zed")});
  });
  step(QStringLiteral("the environment has no file manager"), [](World& world, const Captures&, const Table&) {
    setEditors(world, QJsonArray{QStringLiteral("vscode"), QStringLiteral("zed")});
  });
  step(QStringLiteral("the environment has nothing that can open files"), [](World& world, const Captures&, const Table&) {
    setEditors(world, QJsonArray());
  });
  step(QStringLiteral("the user opens the menu of %1 in the diff").arg(q), [](World& world, const Captures& c, const Table&) {
    // Its heading drawn, with or without the menu's button.
    inHeading(world, c[0], QStringLiteral("diffCopyPath"));
    world.sync();
    if (QQuickItem* button = findNamed(fileHeader(world, c[0]), QStringLiteral("diffFileMenu"))) {
      QTest::mouseClick(&panel(world).window(), Qt::LeftButton, Qt::NoModifier, panel(world).at(button));
      world.waitFor([&] { return panel(world).root()->findChild<QObject*>(QStringLiteral("diffFileActions"))->property("opened").toBool(); }, QStringLiteral("the menu to open"));
    }
  });
  const auto menuOffers = [](World& world) {
    QStringList offered;
    for (const QString& name : {QStringLiteral("diffFileOpen"), QStringLiteral("diffFileReveal"), QStringLiteral("diffFileEditor-vscode"), QStringLiteral("diffFileEditor-zed")}) {
      if (findNamed(panel(world).window().contentItem(), name)) offered.append(name);
    }
    return offered;
  };
  step(QStringLiteral("open, reveal in the file manager and open with either editor"), [menuOffers](World& world, const Captures&, const Table&) {
    expect(menuOffers(world).size() == 4, QStringLiteral("the menu offers %1").arg(menuOffers(world).join(QStringLiteral(", "))));
    // Opening with Zed opens the file there.
    panel(world).click(QStringLiteral("diffFileEditor-zed"));
    const QList<QJsonObject> calls = filesteps::editorCalls(world);
    expect(calls.size() == 1 && calls.first().value(QLatin1String("editor")) == QLatin1String("zed") &&
               calls.first().value(QLatin1String("cwd")) == QLatin1String("/work/shop/src/cart.ts"),
           QStringLiteral("the MC was asked %1").arg(calls.isEmpty() ? QStringLiteral("nothing") : show(calls.first().toVariantMap())));
  });
  step(QStringLiteral("only opening with the editors is offered"), [menuOffers](World& world, const Captures&, const Table&) {
    expect(menuOffers(world) == QStringList{QStringLiteral("diffFileEditor-vscode"), QStringLiteral("diffFileEditor-zed")},
           QStringLiteral("the menu offers %1").arg(menuOffers(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("no menu is shown"), [](World& world, const Captures&, const Table&) {
    expect(findNamed(fileHeader(world, QStringLiteral("src/cart.ts")), QStringLiteral("diffFileMenu")) == nullptr, QStringLiteral("the file offers a menu"));
  });
  step(QStringLiteral("the thread works in %1 of the repository").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject project = world.mc.projects.value(QStringLiteral("shop"));
    project.insert(QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop/") + c[0]);
    project.insert(QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}, {QStringLiteral("rootPath"), QStringLiteral("/work/shop")}});
    world.mc.projects.insert(QStringLiteral("shop"), project);
    world.mc.sendRow(QStringLiteral("shop"), project, QStringLiteral("project"));
    // The repository's changes, in the thread's folder and beside it.
    fake(world).workingTree = patchChanging(QStringLiteral("packages/api/server.ts"), {QStringLiteral("export const port = 80;")}) +
                              patchChanging(c[0] + QStringLiteral("/src/app.ts"), {QStringLiteral("export const app = true;")});
    world.sync();
    panel(world);
    world.waitFor([&] { return fake(world).asked.last().value(QLatin1String("cwd")) == QStringLiteral("/work/shop/") + c[0]; },
                  [&] { return QStringLiteral("the review of the thread's folder; the MC was asked %1").arg(show(fake(world).asked.last().toVariantMap())); });
  });
  step(QStringLiteral("nothing is opened because the file is not in the thread's folder"), [](World& world, const Captures&, const Table&) {
    expect(filesteps::editorCalls(world).isEmpty(), QStringLiteral("the MC was asked to open %1").arg(show(filesteps::editorCalls(world).value(0).toVariantMap())));
    QQuickItem* button = inHeading(world, QStringLiteral("packages/api/server.ts"), QStringLiteral("diffOpenInEditor"));
    expect(!button->isEnabled() && button->property("ToolTip.text").toString() != QLatin1String("Open in editor"), QStringLiteral("the file's button does not say why"));
  });
  step(QStringLiteral("%1 opens as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* button = inHeading(world, c[0], QStringLiteral("diffOpenInEditor"));
    expect(button->isEnabled(), QStringLiteral("%1 cannot be opened").arg(c[0]));
    QTest::mouseClick(&panel(world).window(), Qt::LeftButton, Qt::NoModifier, panel(world).at(button));
    const QList<QJsonObject> calls = filesteps::editorCalls(world);
    expect(calls.size() == 1 && calls.first().value(QLatin1String("cwd")) == QStringLiteral("/work/shop/packages/web/") + c[1],
           QStringLiteral("the MC was asked %1").arg(calls.isEmpty() ? QStringLiteral("nothing") : show(calls.first().toVariantMap())));
  });

  // Keyboard and pasted notes.
  step(QStringLiteral("the user comments with a code block fenced by three backticks on lines (\\d+) to (\\d+) of %1").arg(q), [openComment](World& world, const Captures& c, const Table&) {
    Brick& brick = panel(world);
    openComment(world, c[0].toInt(), c[1].toInt(), c[2]);
    // Pasted, newlines and all.
    brick.item(QStringLiteral("diffCommentNote"))->setProperty("text", kFencedNote);
    brick.click(QStringLiteral("diffCommentAdd"));
    world.sync();
  });
  step(QStringLiteral("the message with that comment is sent"), [comments, sent](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return comments(world).size() == 1; }, [&] { return QStringLiteral("the comment; the composer is %1").arg(show(world.state(QStringLiteral("composer")))); });
    world.mc.part<SentReview>().message = sent(world);
  });
  step(QStringLiteral("the provider receives the comment and the quoted lines with the code kept in one piece"), [](World& world, const Captures&, const Table&) {
    const QJsonObject record = world.mc.part<SentReview>().message.value(QLatin1String("context")).toObject().value(QLatin1String("records")).toArray().first().toObject();
    expect(record.value(QLatin1String("text")) == kFencedNote &&
               record.value(QLatin1String("diff")) == QLatin1String("+export const rate9 = 9;\n+export const rate10 = 10;\n+export const rate11 = 11;"),
           QStringLiteral("the message carries %1").arg(show(record.toVariantMap())));
  });
  step(QStringLiteral("the quoted lines carry the language of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject record = world.mc.part<SentReview>().message.value(QLatin1String("context")).toObject().value(QLatin1String("records")).toArray().first().toObject();
    expect(record.value(QLatin1String("filePath")) == c[0] && record.value(QLatin1String("fenceLanguage")) == QLatin1String("ts"),
           QStringLiteral("the quoted lines carry %1").arg(record.value(QLatin1String("fenceLanguage")).toString()));
  });
  step(QStringLiteral("the user is writing the comment %1 on %1 lines (\\d+) to (\\d+)").arg(q), [openComment](World& world, const Captures& c, const Table&) {
    Brick& brick = panel(world);
    openComment(world, c[2].toInt(), c[3].toInt(), c[1]);
    brick.click(QStringLiteral("diffCommentNote"));
    for (const QChar ch : c[0]) QTest::keyClick(&brick.window(), ch.toLatin1());
    brick.takesKeys = true;
  });
  step(QStringLiteral("the user is writing an empty comment on %1 lines (\\d+) to (\\d+)").arg(q), [openComment](World& world, const Captures& c, const Table&) {
    Brick& brick = panel(world);
    openComment(world, c[1].toInt(), c[2].toInt(), c[0]);
    brick.click(QStringLiteral("diffCommentNote"));
    brick.takesKeys = true;
  });
  step(QStringLiteral("the comment is added to the composer"), [comments](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return comments(world).size() == 1; }, [&] { return QStringLiteral("the comment; the composer is %1").arg(show(world.state(QStringLiteral("composer")))); });
    const QVariantMap chip = comments(world).first().toMap();
    expect(chip.value(QStringLiteral("label")) == QLatin1String("src/cart.ts L10-12") && chip.value(QStringLiteral("text")) == QLatin1String("Use the tax table"),
           QStringLiteral("the composer carries %1").arg(show(chip)));
    expect(!panel(world).root()->findChild<QObject*>(QStringLiteral("diffCommentPopup"))->property("opened").toBool(), QStringLiteral("the comment box stayed open"));
  });
  step(QStringLiteral("nothing is added to the composer"), [comments](World& world, const Captures&, const Table&) {
    expect(comments(world).isEmpty(), QStringLiteral("the composer carries %1").arg(show(comments(world))));
    expect(panel(world).root()->findChild<QObject*>(QStringLiteral("diffCommentPopup"))->property("opened").toBool(), QStringLiteral("the comment box closed"));
  });
});

}  // namespace
