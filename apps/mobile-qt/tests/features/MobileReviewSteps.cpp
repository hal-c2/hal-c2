// Reviewing changes on a phone (features/mobile/review-and-diffs.feature):
// the shared DiffPanel on the thread's own screen, its sources (turns, the
// working tree, branch changes), files marked viewed, and comments begun by
// tapping or holding a line. This file's fake MC side is installed by its
// Background step on that scenario's MC alone, so the other domains' fakes
// for the same calls keep theirs: checkpoint diffs per turn, and
// `review.getDiffPreview` whole or cut short (its files listed, each one's
// patch asked for when opened, failing as often as a step says).

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>

#include <utility>

#include "DiffModel.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "RightPanelController.h"
#include "ThreadDiff.h"
#include "World.h"

namespace {

#define S QStringLiteral

const QString kTitle = S("Fix checkout");
const QString kCart = S("src/cart.ts");
const QString kPrice = S("src/price.ts");
const QDateTime kNow = QDateTime::fromString(S("2026-09-23T10:00:00Z"), Qt::ISODate);

// One file's patch: a context line, `removed` lines taken away, then
// `added` lines ("+export const <name><n> = <n>;" at new line n+1), so a
// step can tap a line by its new number.
QString patchOf(const QString& path, const QString& name, int added, int removed = 1) {
  QString patch = S("diff --git a/%1 b/%1\n--- a/%1\n+++ b/%1\n@@ -1,%2 +1,%3 @@\n const start = 0;\n").arg(path).arg(removed + 1).arg(added + 1);
  for (int n = 1; n <= removed; ++n) patch += S("-export const old%1 = %1;\n").arg(n);
  for (int n = 2; n <= added + 1; ++n) patch += S("+export const %1%2 = %2;\n").arg(name).arg(n);
  return patch;
}

QString renamePatch() {
  return S("diff --git a/src/cart.ts b/src/basket.ts\nsimilarity index 90%\nrename from src/cart.ts\nrename to src/basket.ts\n"
           "--- a/src/cart.ts\n+++ b/src/basket.ts\n@@ -1,2 +1,2 @@\n const start = 0;\n-export const total = 1;\n+export const total = 2;\n");
}

QString binaryPatch(const QString& path) {
  return S("diff --git a/%1 b/%1\nnew file mode 100644\nindex 0000000..1234567\nBinary files /dev/null and b/%1 differ\n").arg(path);
}

// The MC's side of this file's scenarios, as its Background sets it up.
struct FakeMobileReview {
  QMap<int, QString> turns;  // turn number -> its patch
  QString full;
  QString workingTree;
  QString branch;
  QString branchBase = S("main");
  bool lazy = false;  // the review lists its files without their patches
  QJsonArray lazyFiles;
  QHash<QString, QString> filePatches;
  QHash<QString, int> fileFailures;  // times a file's load still fails
  bool filePartial = false;
  bool failTurnDiff = false;
  QString lastNote;
  int pendingFirst = 0;  // a selection a step has yet to start a comment on
  int pendingLast = 0;
  QStringList seenPaths;  // the diff as it was when last read whole
  QList<QJsonObject> asked;  // every review.getDiffPreview payload
};

FakeMobileReview& fake(World& world) { return world.mc.part<FakeMobileReview>(); }

ThreadDiff& diff(World& world) { return *world.native().controller<RightPanelController>()->diff(); }

QString describeDiff(World& world) {
  return S("the diff (%1: %2) shows %3; the screen says: %4")
      .arg(diff(world).status(), diff(world).message(), diff(world).model()->paths().join(S(", ")), world.texts().join(S(" | ")));
}

void waitForDiff(World& world) {
  world.waitFor([&] { return diff(world).status() != QLatin1String("loading") && diff(world).status() != QLatin1String("idle"); },
                [&] { return S("the diff to load; %1").arg(describeDiff(world)); });
}

// The thread's Diff screen on whatever it opens on, done loading.
void reviewScreen(World& world) {
  if (!world.find(S("diffPanel"))) world.tap(S("openDiff"));
  world.item(S("diffPanel"));
  waitForDiff(world);
}

// The picker's entry labelled `label`, as ReviewDiffSteps picks one.
void pick(World& world, const QString& label) {
  QQuickItem* picker = world.item(S("diffTurnPicker"));
  world.tap(picker);
  QObject* popup = picker->property("popup").value<QObject*>();
  world.waitFor([&] { return popup->property("opened").toBool(); }, S("the diff's picker to open"));
  QQuickItem* entry = nullptr;
  world.waitFor(
      [&] {
        entry = world.findWhere([&](QQuickItem* item) { return item->inherits("QQuickItemDelegate") && item->property("text") == label; });
        return entry != nullptr;
      },
      [&] { return S("the picker to offer %1; the screen says: %2").arg(label, world.texts().join(S(" | "))); });
  world.tap(entry);
  world.waitFor([&] { return !popup->property("visible").toBool(); }, S("the diff's picker to close"));
  waitForDiff(world);
}

// An entry of the panel's options menu.
void chooseOption(World& world, const QString& entry) {
  world.tap(S("diffOptions"));
  world.tap(entry);
  world.waitFor([&] { return !world.find(entry); }, S("the diff's options to close"));
}

// The shown line of `path` whose new number is `line`.
QQuickItem* lineAt(World& world, const QString& path, int line) {
  QQuickItem* found = nullptr;
  world.waitFor(
      [&] {
        found = world.findWhere([&](QQuickItem* item) {
          if (item->objectName() != QLatin1String("diffLine")) return false;
          QObject* row = item->property("row").value<QObject*>();
          return row && row->property("newLine").toInt() == line && diff(world).model()->path(row->property("file").toInt()) == path;
        });
        return found != nullptr;
      },
      [&] { return S("line %1 of %2 to be shown; %3").arg(line).arg(path, describeDiff(world)); });
  return found;
}

int fileOf(World& world, const QString& path) {
  const int file = diff(world).model()->fileOf(path);
  expect(file >= 0, S("%1 is not in the diff; %2").arg(path, describeDiff(world)));
  return file;
}

QVariant role(World& world, int row, int what) { return diff(world).model()->data(diff(world).model()->index(row), what); }

// The model rows that are lines of `path`.
int lineRows(World& world, const QString& path) {
  DiffModel& model = *diff(world).model();
  const int file = fileOf(world, path);
  int rows = 0;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (model.data(model.index(row), DiffModel::KindRole) == QLatin1String("line") &&
        model.data(model.index(row), DiffModel::FileRole).toInt() == file) {
      ++rows;
    }
  }
  return rows;
}

QVariantList comments(World& world) { return world.state(S("composer")).toMap().value(S("reviewComments")).toList(); }

QString iso(const QDateTime& time) { return time.toUTC().toString(Qt::ISODate); }

void set(World& world, const QString& kind, const QString& id, const QJsonObject& fields) {
  changeEntity(world.mc, world.thread, kind, id, {{S("s"), fields}});
  world.sync();
}

// A finished turn that changed `paths` with `patch`, and the checkpoint it
// left, as ToolCallSteps writes one.
void finishTurn(World& world, int turn, const QStringList& paths, const QString& patch) {
  FakeStreams& streams = world.mc.part<FakeStreams>();
  world.run = S("run-%1").arg(streams.ordinal + 1);
  const QString run = world.run;
  set(world, S("run"), run,
      {{S("id"), run}, {S("ordinal"), ++streams.ordinal}, {S("status"), S("running")}, {S("requestedAt"), iso(kNow)}, {S("startedAt"), iso(kNow)}});
  const QString message = S("message:") + run;
  set(world, S("turn-item"), message,
      {{S("id"), message}, {S("type"), S("user_message")}, {S("runId"), run}, {S("ordinal"), ++streams.ordinal},
       {S("status"), S("completed")}, {S("text"), S("Fix the checkout")}, {S("updatedAt"), iso(kNow)}});
  QJsonArray files;
  for (const QString& path : paths) files.append(QJsonObject{{S("path"), path}, {S("kind"), S("modified")}, {S("additions"), 2}, {S("deletions"), 0}});
  const QString reply = S("reply:%1").arg(turn);
  set(world, S("turn-item"), reply,
      {{S("id"), reply}, {S("type"), S("assistant_message")}, {S("runId"), run}, {S("ordinal"), ++streams.ordinal},
       {S("status"), S("completed")}, {S("text"), S("Answer %1").arg(turn)}, {S("updatedAt"), iso(kNow)}});
  const QString checkpoint = S("checkpoint:%1").arg(turn);
  set(world, S("turn-item"), checkpoint,
      {{S("id"), checkpoint}, {S("type"), S("checkpoint")}, {S("runId"), run}, {S("ordinal"), ++streams.ordinal},
       {S("status"), S("completed")}, {S("checkpointId"), S("cp-%1").arg(turn)}, {S("scopeId"), S("scope-1")}, {S("files"), files},
       {S("updatedAt"), iso(kNow)}});
  set(world, S("run"), run, {{S("status"), S("completed")}, {S("completedAt"), iso(kNow.addSecs(30))}});
  updateRow(world.mc, world.thread, {{S("activeRunId"), QJsonValue::Null}, {S("latestRunId"), run}});
  set(world, S("checkpoint"), S("cp-%1").arg(turn),
      {{S("id"), S("cp-%1").arg(turn)}, {S("scopeId"), S("scope-1")}, {S("runId"), run}, {S("appRunOrdinal"), turn}, {S("status"), S("ready")},
       {S("files"), files}});
  fake(world).turns.insert(turn, patch);
  world.sync();
}

// This file's calls, answered from the fake above. Installed on the
// scenario's MC by its Background step, replacing the other domains'
// handlers for it alone.
void installFake(World& world) {
  FakeMc& mc = world.mc;
  mc.onRpc(S("orchestration.getTurnDiff"), [&mc](const FakeMc::Rpc& rpc) {
    FakeMobileReview& review = mc.part<FakeMobileReview>();
    if (review.failTurnDiff) return mc.refuse(rpc, S("the checkpoint diffs are busy"));
    mc.reply(rpc, QJsonObject{{S("diff"), review.turns.value(rpc.payload.value(QLatin1String("toTurnCount")).toInt())}});
  });
  mc.onRpc(S("orchestration.getFullThreadDiff"), [&mc](const FakeMc::Rpc& rpc) {
    FakeMobileReview& review = mc.part<FakeMobileReview>();
    if (review.failTurnDiff) return mc.refuse(rpc, S("the checkpoint diffs are busy"));
    mc.reply(rpc, QJsonObject{{S("diff"), review.full}});
  });
  mc.onRpc(S("review.getDiffPreview"), [&mc](const FakeMc::Rpc& rpc) {
    FakeMobileReview& review = mc.part<FakeMobileReview>();
    review.asked.append(rpc.payload);
    const QJsonObject wanted = rpc.payload.value(QLatin1String("file")).toObject();
    if (!wanted.isEmpty()) {
      const QString path = wanted.value(QLatin1String("path")).toString();
      if (review.fileFailures.value(path) > 0) {
        --review.fileFailures[path];
        return mc.refuse(rpc, S("Could not load the diff. Select the file to retry."));
      }
      const QString patch = review.filePatches.value(path);
      return mc.reply(rpc, QJsonObject{{S("cwd"), rpc.payload.value(QLatin1String("cwd"))},
                                       {S("generatedAt"), S("2026-09-23T10:00:00Z")},
                                       {S("sources"), QJsonArray{QJsonObject{{S("id"), wanted.value(QLatin1String("sourceKind"))},
                                                                             {S("kind"), wanted.value(QLatin1String("sourceKind"))},
                                                                             {S("title"), S("Working tree")},
                                                                             {S("baseRef"), QJsonValue()},
                                                                             {S("headRef"), S("feature/cart")},
                                                                             {S("diff"), patch},
                                                                             {S("diffHash"), S("file-%1").arg(qHash(patch))},
                                                                             {S("truncated"), review.filePartial}}}}});
    }
    const auto source = [&review](const QString& kind, const QString& title, const QJsonValue& baseRef, const QString& patch) {
      QJsonObject entry{{S("id"), kind},
                        {S("kind"), kind},
                        {S("title"), title},
                        {S("baseRef"), baseRef},
                        {S("headRef"), S("feature/cart")},
                        {S("diff"), review.lazy && kind == QLatin1String("working-tree") ? QString() : patch},
                        {S("diffHash"), S("%1-%2-%3").arg(kind).arg(qHash(patch)).arg(review.lazy)},
                        {S("truncated"), review.lazy && kind == QLatin1String("working-tree")}};
      if (review.lazy && kind == QLatin1String("working-tree")) entry.insert(S("files"), review.lazyFiles);
      return entry;
    };
    mc.reply(rpc, QJsonObject{{S("cwd"), rpc.payload.value(QLatin1String("cwd"))},
                              {S("generatedAt"), S("2026-09-23T10:00:00Z")},
                              {S("sources"), QJsonArray{source(S("working-tree"), S("Working tree"), QJsonValue(), review.workingTree),
                                                        source(S("branch-range"), S("Branch"), review.branchBase, review.branch)}}});
  });
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // The Background: three finished turns (the latest changed both files, the
  // second only the cart, the first only the price), a working tree with
  // both, and branch changes with only the price, so each source reads
  // differently.
  step(S("the thread %1 has changed %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kTitle && c[1] == kCart && c[2] == kPrice, S("this file's thread is %1 changing %2 and %3").arg(kTitle, kCart, kPrice));
    installFake(world);
    FakeMobileReview& review = fake(world);
    review.workingTree = patchOf(kCart, S("rate"), 15) + patchOf(kPrice, S("cost"), 6);
    review.branch = patchOf(kPrice, S("cost"), 4);
    review.full = patchOf(kCart, S("rate"), 15) + patchOf(kPrice, S("cost"), 3);
    world.thread = haveThread(world, kTitle);
    openThread(world, kTitle);
    finishTurn(world, 1, {kPrice}, patchOf(kPrice, S("cost"), 3));
    finishTurn(world, 2, {kCart}, patchOf(kCart, S("rate"), 5));
    finishTurn(world, 3, {kCart, kPrice}, patchOf(kCart, S("rate"), 15) + patchOf(kPrice, S("cost"), 3));
  });

  // Opening a review, of a named source or as it opens.
  step(S("the user reviews %1").arg(q), [](World& world, const Captures&, const Table&) { reviewScreen(world); });
  step(S("the user is reviewing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    reviewScreen(world);
    if (c[0].contains(QLatin1Char('/'))) {
      // A file, not the thread: the latest turn's, shown open.
      const int file = fileOf(world, c[0]);
      if (!diff(world).model()->expanded(file)) world.tap(S("diffFile-") + c[0]);
      world.waitFor([&] { return lineRows(world, c[0]) > 0; }, [&] { return describeDiff(world); });
    }
  });
  step(S("the user is reviewing the working tree"), [](World& world, const Captures&, const Table&) {
    reviewScreen(world);
    pick(world, S("Working tree"));
  });
  step(S("the user reviews the changes"), [](World& world, const Captures&, const Table&) {
    reviewScreen(world);
    pick(world, S("Working tree"));
  });
  step(S("the user reviews the latest turn"), [](World& world, const Captures&, const Table&) {
    reviewScreen(world);
    if (diff(world).selection() != -1) {
      pick(world, S("Latest turn"));
    } else if (diff(world).status() == QLatin1String("ready")) {
      // Already on it: reviewing it again reads it again.
      chooseOption(world, S("diffReload"));
      waitForDiff(world);
    }
  });
  step(S("the user reviews the (.+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    reviewScreen(world);
    const QHash<QString, QString> labels{{S("working tree"), S("Working tree")}, {S("branch changes"), S("Branch changes")},
                                         {S("latest turn"), S("Latest turn")}, {S("second turn"), S("Turn 2")}};
    expect(labels.contains(c[0]), S("no diff source is called %1").arg(c[0]));
    pick(world, labels.value(c[0]));
  });
  step(S("the diff shows the (working tree|branch changes|latest turn|second turn)"), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, QPair<int, QStringList>> shown{{S("working tree"), {-2, {kCart, kPrice}}},
                                                        {S("branch changes"), {-3, {kPrice}}},
                                                        {S("latest turn"), {-1, {kCart, kPrice}}},
                                                        {S("second turn"), {2, {kCart}}}};
    expect(shown.contains(c[0]), S("no diff source is called %1").arg(c[0]));
    const auto want = shown.value(c[0]);
    world.waitFor([&] { return diff(world).selection() == want.first && diff(world).model()->paths() == want.second; },
                  [&] { return describeDiff(world); });
    for (const QString& path : want.second) world.item(S("diffFile-") + path);
  });
  step(S("the user switches to the working tree"), [](World& world, const Captures&, const Table&) {
    reviewScreen(world);
    pick(world, S("Working tree"));
  });
  step(S("the user switches to the working tree and back"), [](World& world, const Captures&, const Table&) {
    pick(world, S("Working tree"));
    expect(!diff(world).viewedPaths().contains(kCart), S("the cart is viewed in the working tree too; %1").arg(show(diff(world).viewedPaths())));
    pick(world, S("Latest turn"));
  });

  // The changed files as a list beside the diff.
  step(S("the user hides the changed files list"), [](World& world, const Captures&, const Table&) {
    if (!world.find(S("diffTreeRows"))) chooseOption(world, S("diffTree"));
    world.item(S("diffTreeRows"));
    chooseOption(world, S("diffTree"));
  });
  step(S("only the diff is shown"), [](World& world, const Captures&, const Table&) {
    expect(!world.find(S("diffTreeRows")), S("the changed files list is still shown; %1").arg(describeDiff(world)));
    world.item(S("diffRows"));
  });
  step(S("the user shows the changed files list"), [](World& world, const Captures&, const Table&) { chooseOption(world, S("diffTree")); });
  step(S("\"(src/[^\"]*)\" and \"(src/[^\"]*)\" are listed"), [](World& world, const Captures& c, const Table&) {
    world.item(S("diffTreeRows"));
    QStringList paths;
    for (const QVariant& node : diff(world).model()->tree()) {
      if (node.toMap().value(S("kind")) == QLatin1String("file")) paths.append(node.toMap().value(S("path")).toString());
    }
    expect(paths.contains(c[0]) && paths.contains(c[1]), S("the list holds %1").arg(paths.join(S(", "))));
    expect(world.shows(S("cart.ts")) && world.shows(S("price.ts")), S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });

  // One file open and closed, and marked viewed.
  step(S("the user collapses %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (diff(world).model()->expanded(fileOf(world, c[0]))) world.tap(S("diffFile-") + c[0]);
  });
  step(S("the changes in %1 are hidden").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!diff(world).model()->expanded(fileOf(world, c[0])) && lineRows(world, c[0]) == 0, describeDiff(world));
  });
  step(S("the user expands %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!diff(world).model()->expanded(fileOf(world, c[0]))) world.tap(S("diffFile-") + c[0]);
  });
  step(S("the changes in %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return diff(world).model()->expanded(fileOf(world, c[0])) && lineRows(world, c[0]) > 0; },
                  [&] { return describeDiff(world); });
  });
  const auto tapViewed = [](World& world, const QString& path) {
    QQuickItem* header = world.item(S("diffFile-") + path);
    QQuickItem* box = nullptr;
    world.waitFor(
        [&] {
          box = world.findWhere([&](QQuickItem* item) {
            if (item->objectName() != QLatin1String("diffViewed")) return false;
            for (QQuickItem* up = item; up; up = up->parentItem()) {
              if (up == header) return true;
            }
            return false;
          });
          return box != nullptr;
        },
        [&] { return S("the Viewed box of %1; %2").arg(path, describeDiff(world)); });
    world.tap(box);
  };
  step(S("the user marks %1 as viewed").arg(q), [tapViewed](World& world, const Captures& c, const Table&) { tapViewed(world, c[0]); });
  step(S("the user marks %1 as not viewed").arg(q), [tapViewed](World& world, const Captures& c, const Table&) { tapViewed(world, c[0]); });
  step(S("%1 is collapsed and shown as viewed").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(diff(world).viewedPaths().contains(c[0]), S("viewed are %1").arg(show(diff(world).viewedPaths())));
    expect(!diff(world).model()->expanded(fileOf(world, c[0])) && lineRows(world, c[0]) == 0, describeDiff(world));
  });
  step(S("%1 is expanded again").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!diff(world).viewedPaths().contains(c[0]), S("viewed are %1").arg(show(diff(world).viewedPaths())));
    world.waitFor([&] { return diff(world).model()->expanded(fileOf(world, c[0])) && lineRows(world, c[0]) > 0; },
                  [&] { return describeDiff(world); });
  });
  step(S("the user marked %1 as viewed in the latest turn").arg(q), [tapViewed](World& world, const Captures& c, const Table&) {
    reviewScreen(world);
    tapViewed(world, c[0]);
    expect(diff(world).viewedPaths().contains(c[0]), S("viewed are %1").arg(show(diff(world).viewedPaths())));
  });
  step(S("%1 is still viewed in the latest turn").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(diff(world).viewedPaths().contains(c[0]), S("viewed are %1").arg(show(diff(world).viewedPaths())));
    expect(!diff(world).model()->expanded(fileOf(world, c[0])), describeDiff(world));
  });

  // Nothing to show.
  step(S("the latest turn changed nothing"), [](World& world, const Captures&, const Table&) { finishTurn(world, 4, {}, {}); });
  step(S("the user is told the diff is empty"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return diff(world).status() == QLatin1String("empty"); }, [&] { return describeDiff(world); });
    expect(world.shows(S("No changes in the latest turn")), S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });
  step(S("%1 has no ready turn diffs and its worktree has no changes").arg(q), [](World& world, const Captures&, const Table&) {
    for (int turn = 1; turn <= 3; ++turn) set(world, S("checkpoint"), S("cp-%1").arg(turn), {{S("status"), S("stale")}});
    fake(world).workingTree.clear();
    world.sync();
  });
  step(S("the user is told there are no review diffs"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return diff(world).status() == QLatin1String("empty"); }, [&] { return describeDiff(world); });
    expect(world.shows(S("No changes")), S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });
  step(S("the user is told the thread has no ready turn diffs and the worktree diff is empty"),
       [](World& world, const Captures&, const Table&) {
         expect(diff(world).message() == QLatin1String("No uncommitted changes."), describeDiff(world));
         for (const QVariant& choice : diff(world).choices()) {
           const QString label = choice.toMap().value(S("label")).toString();
           expect(!label.startsWith(QLatin1String("Turn")) && label != QLatin1String("Latest turn"), S("a turn is offered: %1").arg(label));
         }
       });

  // The choice of turns, newest first.
  step(S("%1 has three turns with ready diffs").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return diff(world).latestTurn() == 3; }, [&] { return S("the latest turn is %1").arg(diff(world).latestTurn()); });
  });
  step(S("the user opens the choice of diffs to review"), [](World& world, const Captures&, const Table&) {
    reviewScreen(world);
    QQuickItem* picker = world.item(S("diffTurnPicker"));
    world.tap(picker);
    QObject* popup = picker->property("popup").value<QObject*>();
    world.waitFor([&] { return popup->property("opened").toBool(); }, S("the choice of diffs to open"));
  });
  step(S("the turns are listed from the third to the first"), [](World& world, const Captures&, const Table&) {
    QStringList labels;
    for (const QVariant& choice : diff(world).choices()) labels.append(choice.toMap().value(S("label")).toString());
    const QStringList turns = labels.filter(QRegularExpression(S("^Turn ")));
    expect(turns == QStringList({S("Turn 3"), S("Turn 2"), S("Turn 1")}), S("the picker offers %1").arg(labels.join(S(", "))));
    expect(world.shows(S("Turn 3")), S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });
  step(S("%1 is the third").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(diff(world).latestTurn() == 3, S("the latest turn is %1").arg(diff(world).latestTurn()));
    expect(diff(world).choices().first().toMap().value(S("label")) == c[0], S("the picker starts with %1").arg(show(diff(world).choices().first())));
  });

  // Comments on lines.
  step(S("the user selects lines (\\d+) to (\\d+) and writes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).lastNote = c[2];
    world.tap(lineAt(world, kCart, c[0].toInt()));
    world.awaitPopup(S("diffCommentPopup"));
    world.item(S("diffCommentLast"))->setProperty("text", c[1]);
    world.tap(S("diffCommentNote"));
    world.type(c[2]);
    world.tap(S("diffCommentAdd"));
    world.awaitPopup(S("diffCommentPopup"), false);
  });
  step(S("the comment is attached to lines (\\d+) to (\\d+) in the draft for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return comments(world).size() == 1; }, [&] { return S("the comment; the composer is %1").arg(show(world.state(S("composer")))); });
    const QVariantMap chip = comments(world).first().toMap();
    expect(chip.value(S("label")) == S("src/cart.ts L%1-%2").arg(c[0], c[1]) && chip.value(S("text")) == fake(world).lastNote,
           S("the draft carries %1").arg(show(chip)));
  });
  step(S("the user taps line (\\d+)"), [](World& world, const Captures& c, const Table&) { world.tap(lineAt(world, kCart, c[0].toInt())); });
  step(S("a comment on line (\\d+) is started"), [](World& world, const Captures& c, const Table&) {
    world.awaitPopup(S("diffCommentPopup"));
    expect(world.popup(S("diffCommentPopup"))->property("first").toInt() == c[0].toInt(),
           S("the comment starts at line %1").arg(world.popup(S("diffCommentPopup"))->property("first").toInt()));
    expect(world.item(S("diffCommentHeading"))->property("text") == S("Line %1").arg(c[0]),
           S("the heading reads %1").arg(world.item(S("diffCommentHeading"))->property("text").toString()));
  });
  step(S("the user touches and holds line (\\d+)"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* line = lineAt(world, kCart, c[0].toInt());
    QQuickItem* panel = world.item(S("diffPanel"));
    world.hold(line, [&] { return panel->property("rangeLine").toInt() == c[0].toInt(); }, S("line %1 to be marked").arg(c[0]));
  });
  step(S("line (\\d+) is marked as the start of a range"), [](World& world, const Captures& c, const Table&) {
    expect(world.item(S("diffPanel"))->property("rangeLine").toInt() == c[0].toInt() && world.find(S("diffRangeMark")),
           S("the range starts at %1").arg(world.item(S("diffPanel"))->property("rangeLine").toInt()));
  });
  step(S("a comment on lines (\\d+) to (\\d+) is started"), [](World& world, const Captures& c, const Table&) {
    world.awaitPopup(S("diffCommentPopup"));
    expect(world.item(S("diffCommentHeading"))->property("text") == S("Lines %1-%2").arg(c[0], c[1]),
           S("the heading reads %1").arg(world.item(S("diffCommentHeading"))->property("text").toString()));
  });
  step(S("the user touched and held line (\\d+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    reviewScreen(world);
    pick(world, S("Working tree"));
    QQuickItem* panel = world.item(S("diffPanel"));
    world.hold(lineAt(world, c[1], c[0].toInt()), [&] { return panel->property("rangeLine").toInt() == c[0].toInt(); },
               S("line %1 to be marked").arg(c[0]));
  });
  step(S("the user taps line (\\d+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.tap(lineAt(world, c[1], c[0].toInt()));
  });
  step(S("a comment on line (\\d+) of %1 is started").arg(q), [](World& world, const Captures& c, const Table&) {
    world.awaitPopup(S("diffCommentPopup"));
    QObject* popup = world.popup(S("diffCommentPopup"));
    expect(popup->property("path") == c[1] && popup->property("first").toInt() == c[0].toInt(),
           S("the comment is on %1 line %2").arg(popup->property("path").toString()).arg(popup->property("first").toInt()));
  });
  step(S("line (\\d+) of %1 is no longer marked").arg(q), [](World& world, const Captures&, const Table&) {
    expect(world.item(S("diffPanel"))->property("rangeLine").toInt() == -1 && !world.find(S("diffRangeMark")),
           S("the range still starts at %1").arg(world.item(S("diffPanel"))->property("rangeLine").toInt()));
  });
  step(S("the user selected (.+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    reviewScreen(world);
    static const QRegularExpression one(S("^line (\\d+)$"));
    static const QRegularExpression range(S("^lines (\\d+) to (\\d+)$"));
    if (const auto match = one.match(c[0]); match.hasMatch()) {
      fake(world).pendingFirst = fake(world).pendingLast = match.captured(1).toInt();
    } else if (const auto match = range.match(c[0]); match.hasMatch()) {
      fake(world).pendingFirst = match.captured(1).toInt();
      fake(world).pendingLast = match.captured(2).toInt();
      QQuickItem* panel = world.item(S("diffPanel"));
      world.hold(lineAt(world, c[1], fake(world).pendingFirst),
                 [&] { return panel->property("rangeLine").toInt() == fake(world).pendingFirst; }, S("the range to start"));
    } else {
      fail(S("no selection reads %1").arg(c[0]));
    }
  });
  step(S("the user starts a review comment"), [](World& world, const Captures&, const Table&) {
    world.tap(lineAt(world, kCart, fake(world).pendingLast));
    world.awaitPopup(S("diffCommentPopup"));
  });
  step(S("the comment is headed %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.item(S("diffCommentHeading"))->property("text") == c[0],
           S("the heading reads %1").arg(world.item(S("diffCommentHeading"))->property("text").toString()));
  });
  step(S("the user is writing a review comment"), [](World& world, const Captures&, const Table&) {
    reviewScreen(world);
    world.tap(lineAt(world, kCart, 10));
    world.awaitPopup(S("diffCommentPopup"));
    world.tap(S("diffCommentNote"));
    world.type(S("use the helper here"));
  });
  step(S("the user discards it"), [](World& world, const Captures&, const Table&) {
    QQuickItem* cancel = nullptr;
    world.waitFor(
        [&] {
          cancel = world.findWhere([](QQuickItem* item) { return item->property("text") == QLatin1String("Cancel"); });
          return cancel != nullptr;
        },
        S("the comment's Cancel"));
    world.tap(cancel);
    world.awaitPopup(S("diffCommentPopup"), false);
  });
  step(S("no comment is added to the draft"), [](World& world, const Captures&, const Table&) {
    expect(comments(world).isEmpty(), S("the draft carries %1").arg(show(comments(world))));
  });

  // Files the diff cannot show whole.
  step(S("the thread changed the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).workingTree += binaryPatch(c[0]);
  });
  step(S("%1 is listed as a non-text file").arg(q), [](World& world, const Captures& c, const Table&) {
    const int header = diff(world).model()->rowOfFile(fileOf(world, c[0]));
    expect(role(world, header, DiffModel::BinaryRole).toBool(), describeDiff(world));
    expect(world.shows(S("binary")), S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });
  step(S("no diff rows are offered for it"), [](World& world, const Captures&, const Table&) {
    expect(lineRows(world, S("assets/icon.png")) == 0, describeDiff(world));
  });
  const auto lazyWith = [](World& world, const QJsonArray& files, const QHash<QString, QString>& patches) {
    FakeMobileReview& review = fake(world);
    review.lazy = true;
    review.lazyFiles = files;
    review.filePatches = patches;
  };
  step(S("the patch of %1 arrived truncated").arg(q), [lazyWith](World& world, const Captures& c, const Table&) {
    fake(world).filePartial = true;
    lazyWith(world, QJsonArray{QJsonObject{{S("path"), c[0]}, {S("additions"), 20}, {S("deletions"), 5}}}, {{c[0], patchOf(c[0], S("rate"), 3)}});
  });
  step(S("the rows that arrived are shown"), [](World& world, const Captures&, const Table&) {
    if (diff(world).model()->state(fileOf(world, kCart)) == QLatin1String("unloaded")) world.tap(S("diffFile-") + kCart);
    world.waitFor([&] { return lineRows(world, kCart) > 0; }, [&] { return describeDiff(world); });
  });
  step(S("the file is marked as a partial preview"), [](World& world, const Captures&, const Table&) {
    const int header = diff(world).model()->rowOfFile(fileOf(world, kCart));
    expect(role(world, header, DiffModel::PartialRole).toBool(), describeDiff(world));
    expect(world.shows(S("Partial diff preview")), S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });
  step(S("its added and removed counts still cover the whole file"), [](World& world, const Captures&, const Table&) {
    const int header = diff(world).model()->rowOfFile(fileOf(world, kCart));
    expect(role(world, header, DiffModel::AdditionsRole).toInt() == 20 && role(world, header, DiffModel::DeletionsRole).toInt() == 5,
           S("the file counts +%1 -%2").arg(role(world, header, DiffModel::AdditionsRole).toInt()).arg(role(world, header, DiffModel::DeletionsRole).toInt()));
  });
  step(S("%1 has a diff of more than 400 rows").arg(q), [lazyWith](World& world, const Captures& c, const Table&) {
    lazyWith(world, QJsonArray{QJsonObject{{S("path"), c[0]}, {S("additions"), 450}, {S("deletions"), 1}}}, {{c[0], patchOf(c[0], S("big"), 450)}});
  });
  step(S("%1 says its diff is large and offers to load it").arg(q), [](World& world, const Captures& c, const Table&) {
    world.item(S("diffFile-") + c[0]);
    expect(diff(world).model()->state(fileOf(world, c[0])) == QLatin1String("unloaded") && lineRows(world, c[0]) == 0, describeDiff(world));
    expect(world.shows(S("This preview exceeds the size limit. Changes shown are incomplete. Totals include all changes.")),
           S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });
  step(S("the user asks to load the diff"), [](World& world, const Captures&, const Table&) { world.tap(S("diffFile-src/big.ts")); });
  step(S("the rows of %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return diff(world).model()->state(fileOf(world, c[0])).isEmpty() && lineRows(world, c[0]) > 400; },
                  [&] { return describeDiff(world); });
  });
  step(S("the diff of %1 could not be loaded").arg(q), [lazyWith](World& world, const Captures& c, const Table&) {
    fake(world).fileFailures.insert(c[0], 1);
    lazyWith(world, QJsonArray{QJsonObject{{S("path"), c[0]}, {S("additions"), 15}, {S("deletions"), 1}}}, {{c[0], patchOf(c[0], S("rate"), 15)}});
  });
  step(S("%1 says the diff could not be loaded and to select the file to retry").arg(q), [](World& world, const Captures& c, const Table&) {
    if (diff(world).model()->state(fileOf(world, c[0])) == QLatin1String("unloaded")) world.tap(S("diffFile-") + c[0]);
    world.waitFor([&] { return diff(world).model()->state(fileOf(world, c[0])) == QLatin1String("error"); }, [&] { return describeDiff(world); });
    expect(world.shows(S("Could not load the diff. Select the file to retry.")), S("the screen says: %1").arg(world.texts().join(S(" | "))));
    world.item(S("diffFileRetry"));
  });
  step(S("the user selects %1").arg(q), [](World& world, const Captures&, const Table&) { world.tap(S("diffFileRetry")); });
  step(S("the diff of %1 is asked for again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return diff(world).model()->state(fileOf(world, c[0])).isEmpty() && lineRows(world, c[0]) > 0; },
                  [&] { return describeDiff(world); });
    int asks = 0;
    for (const QJsonObject& payload : std::as_const(fake(world).asked)) {
      if (payload.value(QLatin1String("file")).toObject().value(QLatin1String("path")) == c[0]) ++asks;
    }
    expect(asks >= 2, S("the file was asked for %1 times").arg(asks));
  });

  // A renamed file's header.
  step(S("the agent renamed %1 to %1").arg(q), [](World& world, const Captures&, const Table&) { fake(world).workingTree = renamePatch(); });
  step(S("the header reads %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(diff(world).model()->previousPath(fileOf(world, c[1])) == c[0], describeDiff(world));
    expect(world.shows(c[0] + S(" → ") + c[1]), S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });

  // The file being looked at does not carry across sources or out of the diff.
  step(S("the user selected %1 in the changed files list of the latest turn").arg(q), [](World& world, const Captures& c, const Table&) {
    reviewScreen(world);
    diff(world).focusFile(c[0]);
    world.waitFor([&] { return diff(world).focusPath() == c[0] && diff(world).model()->paths() == QStringList{c[0]}; },
                  [&] { return describeDiff(world); });
  });
  step(S("the user selected %1 in the changed files list").arg(q), [](World& world, const Captures& c, const Table&) {
    reviewScreen(world);
    pick(world, S("Working tree"));
    diff(world).focusFile(c[0]);
    world.waitFor([&] { return diff(world).focusPath() == c[0]; }, [&] { return describeDiff(world); });
  });
  step(S("the diff is read again and no longer contains %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kPrice, S("this step drops %1").arg(kPrice));
    fake(world).workingTree = patchOf(kCart, S("rate"), 15);
    chooseOption(world, S("diffReload"));
    waitForDiff(world);
  });
  step(S("no file is selected in the changed files list"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return diff(world).focusPath().isEmpty(); }, [&] { return S("%1 is still selected; %2").arg(diff(world).focusPath(), describeDiff(world)); });
  });

  // Refreshing from the review menu (the Android phone is NotificationSteps').
  step(S("the user opens the review menu"), [](World& world, const Captures&, const Table&) { world.tap(S("diffOptions")); });
  step(S("the user is offered to refresh the current diff"), [](World& world, const Captures&, const Table&) {
    expect(world.item(S("diffReload"))->property("text") == QLatin1String("Reload"), S("the menu offers %1").arg(world.texts().join(S(" | "))));
  });

  // The header's totals and the comments waiting in the draft.
  step(S("the diff adds 12 lines and removes 4"), [](World& world, const Captures&, const Table&) {
    fake(world).workingTree = patchOf(kCart, S("rate"), 12, 4);
  });
  step(S("the draft for %1 carries two review comments").arg(q), [](World& world, const Captures&, const Table&) {
    reviewScreen(world);
    pick(world, S("Working tree"));
    expect(diff(world).comment(kCart, S("new"), 2, 3, S("first")) && diff(world).comment(kCart, S("new"), 5, 6, S("second")), describeDiff(world));
    world.waitFor([&] { return comments(world).size() == 2; }, [&] { return S("the draft carries %1").arg(show(comments(world))); });
  });
  step(S("the user looks at the review header"), [](World& world, const Captures&, const Table&) { world.item(S("diffPanel")); });
  step(S("the header shows (\\d+) added, (\\d+) removed and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(diff(world).model()->additions() == c[0].toInt() && diff(world).model()->deletions() == c[1].toInt(), describeDiff(world));
    expect(world.shows(S("+") + c[0]) && world.shows(S("−") + c[1]), S("the screen says: %1").arg(world.texts().join(S(" | "))));
    expect(world.item(S("diffCommentCount"))->property("text") == c[2],
           S("the header counts %1").arg(world.item(S("diffCommentCount"))->property("text").toString()));
  });

  // A diff read before, read again over a failure or no connection.
  step(S("the user reviewed the latest turn earlier"), [](World& world, const Captures&, const Table&) {
    reviewScreen(world);
    expect(diff(world).status() == QLatin1String("ready"), describeDiff(world));
    fake(world).seenPaths = diff(world).model()->paths();
    // And left it for the thread, as "earlier" says.
    world.back();
    world.waitFor([&] { return !world.find(S("diffPanel")); }, S("the diff to close"));
  });
  step(S("reading the diff now fails with a reason"), [](World& world, const Captures&, const Table&) { fake(world).failTurnDiff = true; });
  step(S("the user is told the review is unavailable and why"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("diffStale")) != nullptr; }, [&] { return describeDiff(world); });
    const QString text = world.item(S("diffStale"))->property("text").toString();
    expect(text.contains(QLatin1String("Review unavailable")) && text.contains(QLatin1String("the checkpoint diffs are busy")), text);
  });
  step(S("the earlier diff is still shown below"), [](World& world, const Captures&, const Table&) {
    expect(diff(world).status() == QLatin1String("ready") && diff(world).model()->paths() == fake(world).seenPaths, describeDiff(world));
    world.item(S("diffRows"));
  });
  step(S("the earlier diff is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return diff(world).status() == QLatin1String("ready") && diff(world).model()->paths() == fake(world).seenPaths; },
                  [&] { return describeDiff(world); });
    world.item(S("diffRows"));
  });
  step(S("the user is told it may be out of date"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("diffStale")) != nullptr; }, [&] { return describeDiff(world); });
    expect(world.item(S("diffStale"))->property("text").toString().contains(QLatin1String("may be out of date")),
           world.item(S("diffStale"))->property("text").toString());
  });
});

}  // namespace
}  // namespace
