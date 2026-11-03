// The phone's side of features/source-control/review-diffs.feature: a
// thread's checkout reviewed on its own screen, the Diff tab the desktop
// draws beside the thread (the shared DiffPanel brick), reached by the
// thread's Diff button. The MC's `review.getDiffPreview` is faked here as the
// desktop harness's ReviewDiffSteps fakes it: the working tree's patch, and
// the branch's against each base.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

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

const QString kThreadTitle = S("Tax line");

QString patchChanging(const QString& path, int lines, const QString& name) {
  QString patch = S("diff --git a/%1 b/%1\n--- a/%1\n+++ b/%1\n@@ -1,2 +1,%2 @@\n const cart = [];\n-export const tax = 0;\n").arg(path).arg(lines + 1);
  for (int n = 1; n <= lines; ++n) patch += S("+export const %1%2 = %2;\n").arg(name).arg(n);
  return patch;
}

// The checkout as `review.getDiffPreview` reports it (HalC2.Review). Short
// lines, so a row fits the phone's width and its middle can be tapped.
struct FakeReview {
  QString head = S("feature/tax");
  QString automaticBase = S("main");
  QString workingTree = patchChanging(S("src/cart.ts"), 12, S("rate")) + patchChanging(S("src/tax.ts"), 3, S("band"));
  QHash<QString, QString> branch{
      {S("main"), patchChanging(S("src/cart.ts"), 2, S("rate"))},
      {S("origin/main"), patchChanging(S("src/cart.ts"), 2, S("rate")) + patchChanging(S("src/pay.ts"), 2, S("fee"))},
  };
  QList<QJsonObject> asked;
};

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(S("review.getDiffPreview"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.asked.append(rpc.payload);
    const QString base = rpc.payload.value(QLatin1String("baseRef")).toString(fake.automaticBase);
    const auto source = [&](const QString& kind, const QString& title, const QJsonValue& baseRef, const QString& diff) {
      return QJsonObject{{S("id"), kind},          {S("kind"), kind},      {S("title"), title},
                         {S("baseRef"), baseRef},  {S("headRef"), fake.head}, {S("diff"), diff},
                         {S("diffHash"), S("hash-%1").arg(diff.size())}, {S("truncated"), false}};
    };
    mc.reply(rpc, QJsonObject{{S("cwd"), rpc.payload.value(QLatin1String("cwd"))},
                              {S("generatedAt"), S("2026-09-23T10:00:00Z")},
                              {S("sources"), QJsonArray{source(S("working-tree"), S("Working tree"), QJsonValue(), fake.workingTree),
                                                        source(S("branch-range"), S("Branch"), base, fake.branch.value(base))}}});
  });
});

FakeReview& fake(World& world) { return world.mc.part<FakeReview>(); }

ThreadDiff& diff(World& world) { return *world.native().controller<RightPanelController>()->diff(); }

QString describeDiff(World& world) {
  return S("the diff (%1: %2) shows %3; the screen says: %4")
      .arg(diff(world).status(), diff(world).message(), diff(world).model()->paths().join(S(", ")), world.texts().join(S(" | ")));
}

void waitForDiff(World& world) {
  world.waitFor([&] { return diff(world).status() != QLatin1String("loading") && diff(world).status() != QLatin1String("idle"); },
                [&] { return S("the diff to load; %1").arg(describeDiff(world)); });
}

// The thread's Diff screen, reached by its button, on the working tree (the
// thread has no turn yet).
void diffScreen(World& world) {
  if (!world.find(S("diffPanel"))) world.tap(S("openDiff"));
  world.item(S("diffPanel"));
  waitForDiff(world);
  expect(diff(world).status() == QLatin1String("ready") && diff(world).reviewing(), describeDiff(world));
}

// An entry of the panel's options menu.
void chooseOption(World& world, const QString& entry) {
  diffScreen(world);
  world.tap(S("diffOptions"));
  world.tap(entry);
  world.waitFor([&] { return !world.find(entry); }, S("the diff's options to close"));
}

// The picker's entry labelled `label`.
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
}

QVariantList comments(World& world) { return world.state(S("composer")).toMap().value(S("reviewComments")).toList(); }

const Steps steps([] {
  const QString q = kQuoted;

  step(S("a connected environment with a thread in the git project %1 on the branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.clear();
    world.mc.threads.clear();
    world.mc.projects.insert(c[0], {{S("id"), c[0]}, {S("title"), c[0]}, {S("workspaceRoot"), S("/work/") + c[0]}, {S("scripts"), QJsonArray()},
                                     {S("createdAt"), S("2026-09-01T09:00:00Z")}, {S("updatedAt"), S("2026-09-01T09:00:00Z")}});
    fake(world).head = c[1];
    pairWithEnvironment(world);
    world.thread = haveThread(world, kThreadTitle);
    updateRow(world.mc, world.thread, {{S("branch"), c[1]}});
    openThread(world, kThreadTitle);
  });

  // Stacked and split.
  step(S("the user switches the diff to the split view"), [](World& world, const Captures&, const Table&) {
    diffScreen(world);
    expect(!diff(world).model()->split(), S("the diff is already split"));
    chooseOption(world, S("diffSplit"));
  });
  step(S("the old and new lines are shown side by side"), [](World& world, const Captures&, const Table&) {
    DiffModel& model = *diff(world).model();
    expect(model.split(), S("the diff is not split"));
    bool paired = false;
    for (int row = 0; row < model.rowCount(); ++row) {
      const QModelIndex index = model.index(row);
      paired = paired || (model.data(index, DiffModel::SignRole) == QLatin1String("-") && model.data(index, DiffModel::RightSignRole) == QLatin1String("+"));
    }
    expect(paired, S("no removed line sits beside an added one"));
    // The reverse: one column again.
    chooseOption(world, S("diffSplit"));
    expect(!model.split(), S("the diff cannot be stacked again"));
  });

  // The base.
  step(S("the user compares the branch against %1 instead of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    diffScreen(world);
    pick(world, S("Branch changes"));
    waitForDiff(world);
    expect(diff(world).comparedBase() == c[1] && diff(world).model()->paths() == QStringList{S("src/cart.ts")}, describeDiff(world));
    // The base picker's search takes a typed ref.
    world.tap(S("diffBasePicker"));
    QObject* bases = world.item(S("diffBasePicker"))->findChild<QObject*>(S("diffBases"));
    world.waitFor([&] { return bases && bases->property("opened").toBool(); }, S("the list of bases to open"));
    world.tap(S("diffBaseRef"));
    world.type(c[0]);
    world.press(S("Return"));
    world.sync();
    waitForDiff(world);
    expect(!bases->property("opened").toBool(), S("the list of bases stayed open"));
  });
  step(S("the diff shows the changes against %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return diff(world).status() == QLatin1String("ready") && diff(world).comparedBase() == c[0]; },
                  [&] { return S("%1 against %2").arg(describeDiff(world), diff(world).comparedBase()); });
    expect(diff(world).comparedHead() == QLatin1String("feature/tax") && diff(world).model()->paths() == QStringList{S("src/cart.ts"), S("src/pay.ts")},
           describeDiff(world));
    expect(fake(world).asked.last().value(QLatin1String("baseRef")) == c[0], S("the MC was asked %1").arg(show(fake(world).asked.last().toVariantMap())));
    world.waitFor([&] { return world.shows(S("src/pay.ts")); }, [&] { return describeDiff(world); });
    // The reverse: no base named, the MC picks again.
    diff(world).setBaseRef(QString());
    waitForDiff(world);
    expect(diff(world).comparedBase() == QLatin1String("main"), S("the branch is compared against %1").arg(diff(world).comparedBase()));
  });

  // A note on lines of the diff, for the prompt: the line tapped.
  step(S("the user comments %1 on lines (\\d+) to (\\d+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    diffScreen(world);
    const int first = c[1].toInt();
    QQuickItem* line = nullptr;
    world.waitFor(
        [&] {
          line = world.findWhere([&](QQuickItem* item) {
            if (item->objectName() != QLatin1String("diffLine")) return false;
            QObject* row = item->property("row").value<QObject*>();
            return row && row->property("newLine").toInt() == first && row->property("sign").toString() == QLatin1String("+") &&
                   diff(world).model()->path(row->property("file").toInt()) == c[3];
          });
          return line != nullptr;
        },
        [&] { return S("line %1 of %2 to be shown; %3").arg(first).arg(c[3], describeDiff(world)); });
    world.tap(line);
    world.awaitPopup(S("diffCommentPopup"));
    world.item(S("diffCommentLast"))->setProperty("text", c[2]);
    world.tap(S("diffCommentNote"));
    world.type(c[0]);
    world.tap(S("diffCommentAdd"));
    world.awaitPopup(S("diffCommentPopup"), false);
  });
  step(S("the composer carries that comment with the file and line range"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return comments(world).size() == 1; }, [&] { return S("the comment; the composer is %1").arg(show(world.state(S("composer")))); });
    const QVariantMap chip = comments(world).first().toMap();
    expect(chip.value(S("label")) == QLatin1String("src/cart.ts L10-12") && chip.value(S("text")) == QLatin1String("Use the tax table"),
           S("the composer carries %1").arg(show(chip)));
    // Back on the thread, the comment waits on the composer.
    world.back();
    world.item(S("centreHost"));
    expect(!world.find(S("diffPanel")), S("the diff is still on screen"));
    world.item(S("reviewComment-") + chip.value(S("id")).toString());
    // Sent, the message names the chip and carries the note, the file and the lines.
    QQuickItem* input = world.item(S("input"));
    world.waitFor([&] { return input->isEnabled(); }, S("the composer to take text"));
    world.tap(input);
    world.type(S("Please fix this"));
    world.tap(S("primaryAction"));
    QJsonObject message;
    world.waitFor(
        [&] {
          for (const QJsonObject& command : std::as_const(world.mc.commands)) {
            if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) message = command;
          }
          return !message.isEmpty();
        },
        [&] { return S("a message; the screen says: %1").arg(world.texts().join(S(" | "))); });
    const QJsonArray records = message.value(QLatin1String("context")).toObject().value(QLatin1String("records")).toArray();
    const QJsonObject record = records.first().toObject();
    const QString reference = S("[src/cart.ts L10-12](hal-c2-context://v1/review-comment/%1)").arg(record.value(QLatin1String("contextId")).toString());
    expect(message.value(QLatin1String("text")).toString() == S("Please fix this\n\n") + reference,
           S("the message reads %1").arg(message.value(QLatin1String("text")).toString()));
    expect(records.size() == 1 && record.value(QLatin1String("kind")) == QLatin1String("review-comment") &&
               record.value(QLatin1String("filePath")) == QLatin1String("src/cart.ts") && record.value(QLatin1String("rangeLabel")) == QLatin1String("+10 to +12") &&
               record.value(QLatin1String("text")) == QLatin1String("Use the tax table") &&
               record.value(QLatin1String("diff")) == QLatin1String("+export const rate9 = 9;\n+export const rate10 = 10;\n+export const rate11 = 11;"),
           S("the message carries %1").arg(show(records.toVariantList())));
    world.waitFor([&] { return comments(world).isEmpty(); }, S("the sent comment to leave the draft"));
  });
});

}  // namespace
