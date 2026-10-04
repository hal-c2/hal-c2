// Reviewing the checkout beside a thread (features/source-control/review-diffs.feature):
// the Diff tab over the MC's `review.getDiffPreview`, driven through the
// DiffPanel brick as the user drives it. The MC's side is faked here: the
// working tree's patch, and the branch's against each base. Also a changed
// file opened in the user's editor, from the diff or from the commit review
// (commit-and-generated-messages.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "DiffModel.h"
#include "FakeConfig.h"
#include "FilesWorkspace.h"
#include "Harness.h"
#include "RightPanelController.h"
#include "ThreadDiff.h"
#include "World.h"

namespace {

const QString kLongLine = QString(300, QLatin1Char('x'));

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
};

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("review.getDiffPreview"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.asked.append(rpc.payload);
    const QString base = rpc.payload.value(QLatin1String("baseRef")).toString(fake.automaticBase);
    const auto source = [&](const QString& kind, const QString& title, const QJsonValue& baseRef, const QString& diff) {
      return QJsonObject{{QStringLiteral("id"), kind}, {QStringLiteral("kind"), kind}, {QStringLiteral("title"), title},
                         {QStringLiteral("baseRef"), baseRef}, {QStringLiteral("headRef"), fake.head}, {QStringLiteral("diff"), diff},
                         {QStringLiteral("diffHash"), QStringLiteral("hash-%1").arg(diff.size())}, {QStringLiteral("truncated"), false}};
    };
    mc.reply(rpc, QJsonObject{{QStringLiteral("cwd"), rpc.payload.value(QLatin1String("cwd"))},
                                {QStringLiteral("generatedAt"), QStringLiteral("2026-09-23T10:00:00Z")},
                                {QStringLiteral("sources"), QJsonArray{source(QStringLiteral("working-tree"), QStringLiteral("Working tree"), QJsonValue(), fake.workingTree),
                                                                       source(QStringLiteral("branch-range"), QStringLiteral("Branch"), base, fake.branch.value(base))}}});
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

// The Diff tab beside the thread, on the checkout's working tree (the thread
// has no turn yet), as the DiffPanel brick draws it.
Brick& panel(World& world) {
  if (!world.brick) {
    world.bridge().dispatch(QStringLiteral("panel.open"), QVariantMap{{QStringLiteral("tab"), QStringLiteral("diff")}});
    waitForDiff(world);
    expect(diff(world).status() == QLatin1String("ready") && diff(world).reviewing(), describeDiff(world));
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
  world.mc.part<OpenedInEditor>() = {path, QStringLiteral("zed")};
  if (fake(world).noEditor) return;
  setEditors(world, QJsonArray{QStringLiteral("zed")});
  world.waitFor([&] { return !world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("editors")).toList().isEmpty(); },
                QStringLiteral("the environment's editors to be known"));
}

const Steps steps([] {
  const QString q = kQuoted;

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
    Brick& brick = panel(world);
    diff(world).select(ThreadDiff::Branch);
    waitForDiff(world);
    expect(diff(world).comparedBase() == c[1] && diff(world).model()->paths() == QStringList{QStringLiteral("src/cart.ts")}, describeDiff(world));
    QQuickItem* field = brick.item(QStringLiteral("diffBaseRef"));
    world.waitFor([&] { return field->isVisible(); }, QStringLiteral("the base to be offered"));
    brick.click(QStringLiteral("diffBaseRef"));
    for (const QChar ch : c[0]) QTest::keyClick(&brick.window(), ch.toLatin1());
    QTest::keyClick(&brick.window(), Qt::Key_Return);
    world.sync();
    waitForDiff(world);
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
});

}  // namespace
