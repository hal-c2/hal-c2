// Where a new thread runs, picked in the composer's context strip on screen
// (ComposerBrick.h): the machine, the checkout mode and the branch
// (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "ComposerBrick.h"
#include "FakeGit.h"
#include "Harness.h"
#include "Launches.h"
#include "NavigationController.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

const QString kRoot = QStringLiteral("/work/shop");
const QString kPrompt = QStringLiteral("Add caching");

QVariantMap workspace(World& world) {
  return world.state(QStringLiteral("workspace")).toMap();
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

QQuickItem* part(World& world, const QString& objectName) {
  QQuickItem* item = composerPart(world, objectName);
  expect(item != nullptr, QStringLiteral("the composer shows no %1").arg(objectName));
  return item;
}

void click(World& world, QQuickItem* item) {
  Brick& brick = composerBrick(world);
  expect(item->isVisible() && item->isEnabled(), QStringLiteral("%1 cannot be clicked").arg(item->objectName()));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  world.sync();
}

// Opens the picker's list and takes its entry `index` with the keyboard.
void pick(World& world, const QString& pickerName, int index) {
  Brick& brick = composerBrick(world);
  QQuickItem* picker = part(world, pickerName);
  QObject* popup = picker->property("popup").value<QObject*>();
  click(world, picker);
  world.waitFor([&] { return popup->property("opened").toBool(); }, [&] { return QStringLiteral("%1 to open").arg(pickerName); });
  for (int guard = 0; picker->property("highlightedIndex").toInt() != index && guard < 8; ++guard) {
    QTest::keyClick(&brick.window(), picker->property("highlightedIndex").toInt() < index ? Qt::Key_Down : Qt::Key_Up);
  }
  expect(picker->property("highlightedIndex").toInt() == index, QStringLiteral("%1 offers no entry %2").arg(pickerName).arg(index));
  QTest::keyClick(&brick.window(), Qt::Key_Return);
  world.sync();
}

// The window on a new thread's draft in "shop", the composer on screen.
void newThread(World& world) {
  if (world.native().controller<NavigationController>()->route().kind != QLatin1String("draft")) {
    world.openDraft(kProject);
    world.waitFor([&] { return workspace(world).value(QStringLiteral("isDraft")).toBool(); },
                  [&] { return QStringLiteral("the draft; the header shows %1").arg(show(workspace(world))); });
  }
  composerBrick(world);
}

// Types `name` in the branch picker and confirms it once the refs answered.
void confirmBranch(World& world, const QString& name) {
  click(world, part(world, QStringLiteral("branchButton")));
  QObject* popup = composerItem(world)->findChild<QObject*>(QStringLiteral("branchPicker"));
  world.waitFor([&] { return popup && popup->property("opened").toBool(); }, QStringLiteral("the branch picker to open"));
  typeInComposer(world, name);
  world.waitFor([&] { return workspace(world).value(QStringLiteral("branchQuery")) == name && !workspace(world).value(QStringLiteral("branchesLoading")).toBool(); },
                [&] { return QStringLiteral("the refs for %1; the header shows %2").arg(name, show(workspace(world))); });
  world.sync();
  pressInComposer(world, QStringLiteral("Enter"));
  world.waitFor([&] { return !popup->property("visible").toBool(); }, QStringLiteral("the branch picker to close"));
}

void sendFirstMessage(World& world) {
  QMetaObject::invokeMethod(composerItem(world), "focusInput");
  typeInComposer(world, kPrompt);
  pressInComposer(world, QStringLiteral("Enter"));
}

QJsonObject launch(World& world) {
  world.waitFor([&] { return !launchCalls(world).isEmpty(); }, [&] { return QStringLiteral("a launch; the toasts are %1").arg(show(toasts(world))); });
  return launchCalls(world).constLast();
}

const Steps steps([] {
  const QString q = kQuoted;

  // The machine.
  step(QStringLiteral("two environments are connected"), [](World& world, const Captures&, const Table&) {
    // The second has a checkout of the same repository.
    const QJsonObject identity{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}};
    QJsonObject row = world.mc.projects.value(kProject);
    row.insert(QStringLiteral("repositoryIdentity"), identity);
    world.mc.projects.insert(kProject, row);
    world.mc.sendRows(world.mc.name, {QJsonValue(QJsonArray{kProject, QStringLiteral("project"), row})});
    world.mc.join(kPeer, kPeerEnvironment);
    world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.mc")}, {QStringLiteral("id"), world.mc.subscribers(QStringLiteral("shell")).value(0)},
                   {QStringLiteral("mc"), kPeer}, {QStringLiteral("online"), true}});
    world.mc.sendRows(kPeer, {QJsonValue(QJsonArray{QStringLiteral("shop-copy"), QStringLiteral("project"),
                                                    QJsonObject{{QStringLiteral("id"), QStringLiteral("shop-copy")}, {QStringLiteral("title"), kProject},
                                                                {QStringLiteral("workspaceRoot"), QStringLiteral("/srv/shop")}, {QStringLiteral("scripts"), QJsonArray()},
                                                                {QStringLiteral("repositoryIdentity"), identity}}})});
    world.sync();
  });
  step(QStringLiteral("the user starts a new thread on the second environment"), [](World& world, const Captures&, const Table&) {
    newThread(world);
    const QVariantList environments = workspace(world).value(QStringLiteral("environments")).toList();
    int second = -1;
    for (qsizetype i = 0; i < environments.size(); ++i) {
      if (environments.at(i).toMap().value(QStringLiteral("environmentId")) == kPeerEnvironment) second = int(i);
    }
    expect(second >= 0, QStringLiteral("the composer offers %1").arg(show(environments)));
    pick(world, QStringLiteral("hostPicker"), second);
    world.waitFor([&] { return workspace(world).value(QStringLiteral("activeEnvironmentId")) == kPeerEnvironment; },
                  [&] { return QStringLiteral("the draft on the second environment; the header shows %1").arg(show(workspace(world))); });
    sendFirstMessage(world);
  });
  step(QStringLiteral("the thread is created in the second environment"), [](World& world, const Captures&, const Table&) {
    const QJsonObject call = launch(world);
    expect(call.value(QLatin1String("projectId")) == QLatin1String("shop-copy") && call.value(QLatin1String("initialMessage")).toObject().value(QLatin1String("text")) == kPrompt,
           QStringLiteral("the launch is %1").arg(show(call.toVariantMap())));
    // The fake MC lists every launched thread as its own, so the project says where it went.
    const QString threadId = call.value(QLatin1String("threadId")).toString();
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey().endsWith(QLatin1Char(':') + threadId); },
                  [&] { return QStringLiteral("the thread %1; the route is %2").arg(threadId, show(world.state(QStringLiteral("route")))); });
  });

  // The checkout.
  step(QStringLiteral("the project is a Git repository"), [](World& world, const Captures&, const Table&) {
    fakeGitRepo(world, kRoot, {QStringLiteral("main"), QStringLiteral("feature/tax")}, QStringLiteral("feature/tax"), QStringLiteral("main"));
    world.sync();
  });
  step(QStringLiteral("the user chooses to work in a new worktree from branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    newThread(world);
    pick(world, QStringLiteral("envModePicker"), 1);
    world.waitFor([&] { return workspace(world).value(QStringLiteral("envMode")) == QLatin1String("worktree"); },
                  [&] { return QStringLiteral("New worktree; the header shows %1").arg(show(workspace(world))); });
    confirmBranch(world, c[0]);
  });
  step(QStringLiteral("the first turn works in a new worktree based on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    sendFirstMessage(world);
    const QJsonObject strategy = launch(world).value(QLatin1String("workspaceStrategy")).toObject();
    expect(strategy.value(QLatin1String("type")) == QLatin1String("worktree") && strategy.value(QLatin1String("baseRef")) == c[0],
           QStringLiteral("the launch works in %1").arg(show(strategy.toVariantMap())));
  });
  step(QStringLiteral("the user chose to work in a new worktree"), [](World& world, const Captures&, const Table&) {
    // A checkout on no branch (a detached head) offers no base to start from.
    fakeGitRepo(world, kRoot, {QStringLiteral("main")}, QString(), QStringLiteral("main"));
    world.sync();
    newThread(world);
    pick(world, QStringLiteral("envModePicker"), 1);
    world.waitFor([&] { return workspace(world).value(QStringLiteral("envMode")) == QLatin1String("worktree"); },
                  [&] { return QStringLiteral("New worktree; the header shows %1").arg(show(workspace(world))); });
  });
  step(QStringLiteral("no base branch is chosen"), [](World& world, const Captures&, const Table&) {
    expect(workspace(world).value(QStringLiteral("branch")).isNull(), QStringLiteral("the header shows %1").arg(show(workspace(world))));
  });
  step(QStringLiteral("the user tries to send the first message"), [](World& world, const Captures&, const Table&) { sendFirstMessage(world); });
  step(QStringLiteral("the user is asked to select a base branch"), [](World& world, const Captures&, const Table&) {
    const QVariantList shown = toasts(world);
    expect(std::any_of(shown.cbegin(), shown.cend(), [](const QVariant& toast) {
             return toast.toMap().value(QStringLiteral("description")) == QLatin1String("Select a base branch before sending in New worktree mode.");
           }), QStringLiteral("the toasts are %1").arg(show(shown)));
    world.sync();
    expect(launchCalls(world).isEmpty() && composerEditor(world)->property("text") == kPrompt, QStringLiteral("the MC launched a thread, or the draft was lost"));
  });

  // The branch.
  step(QStringLiteral("the project has no branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeGitRepo(world, kRoot, {QStringLiteral("main")}, QStringLiteral("main"), QStringLiteral("main"));
    world.waitFor([&] { return workspace(world).value(QStringLiteral("branch")) == QLatin1String("main"); },
                  [&] { return QStringLiteral("the thread on main; the header shows %1").arg(show(workspace(world))); });
    expect(c[0] != QLatin1String("main"), QStringLiteral("main exists"));
  });
  step(QStringLiteral("the user searches for %1 and confirms it").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    confirmBranch(world, c[0]);
  });
  step(QStringLiteral("the thread works on a new branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return workspace(world).value(QStringLiteral("branch")) == c[0] && world.mc.threads.value(kThread).value(QLatin1String("branch")).toString() == c[0]; },
                  [&] { return QStringLiteral("the thread on %1; the header shows %2").arg(c[0], show(workspace(world))); });
  });
});

}  // namespace
