// Where a new thread runs, picked in the composer's context strip on screen
// (ComposerBrick.h): the machine, the checkout mode and the branch
// (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "FakeGit.h"
#include "Harness.h"
#include "Launches.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "World.h"
#include "WorkspaceController.h"

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
  expect(item->isVisible() && item->isEnabled(),
         QStringLiteral("%1 cannot be clicked (visible %2, enabled %3); the header shows %4").arg(item->objectName()).arg(item->isVisible()).arg(item->isEnabled()).arg(show(workspace(world))));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  world.sync();
}

// Opens the picker's list and takes its entry `index` with the keyboard.
void pick(World& world, const QString& pickerName, int index) {
  Brick& brick = composerBrick(world);
  QQuickItem* picker = part(world, pickerName);
  QObject* popup = picker->property("popup").value<QObject*>();
  world.waitFor([&] { return !popup->property("visible").toBool(); }, [&] { return QStringLiteral("%1 to be closed").arg(pickerName); });
  click(world, picker);
  world.waitFor([&] { return popup->property("opened").toBool(); },
                [&] { return QStringLiteral("%1 to open (visible %2, enabled %3, focus %4)").arg(pickerName).arg(popup->property("visible").toBool()).arg(picker->isEnabled()).arg(picker->hasActiveFocus()); });
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

// Codex and Claude ready to take a new thread's prompt.
void offerCodexAndClaude(World& world) {
  if (!world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList().isEmpty()) return;
  const auto provider = [](const QString& id, const QString& name, const QStringList& models) {
    QJsonArray list;
    for (const QString& model : models) list.append(QJsonObject{{QStringLiteral("slug"), model}, {QStringLiteral("name"), model}});
    return QJsonObject{{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), id}, {QStringLiteral("displayName"), name},
                       {QStringLiteral("enabled"), true}, {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")},
                       {QStringLiteral("models"), list}};
  };
  publishProviders(world.mc, {provider(QStringLiteral("codex"), QStringLiteral("Codex"), {QStringLiteral("gpt-5"), QStringLiteral("gpt-5-codex")}),
                              provider(QStringLiteral("claudeAgent"), QStringLiteral("Claude"), {QStringLiteral("claude-opus"), QStringLiteral("claude-sonnet")})});
  world.sync();
}

// The draft's own model, and Claude's beside it.
void chooseClaudeToo(World& world) {
  click(world, part(world, QStringLiteral("modelPicker")));
  world.waitFor([&] { return composerPart(world, QStringLiteral("modelPickerProvider:claudeAgent")) != nullptr; }, QStringLiteral("the model picker to open"));
  click(world, part(world, QStringLiteral("modelPickerProvider:claudeAgent")));
  world.waitFor([&] { return composerPart(world, QStringLiteral("modelPickerMultiple:claudeAgent:claude-opus")) != nullptr; }, QStringLiteral("Claude's models"));
  click(world, part(world, QStringLiteral("modelPickerMultiple:claudeAgent:claude-opus")));
  world.waitFor([&] { return world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("multiple")).toList().size() == 2; },
                [&] { return QStringLiteral("two models; the picker has %1").arg(show(world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("multiple")))); });
}

// The worktree the scenario's new thread is to be in, when it is in one.
struct ChoiceDraft {
  QString worktree;
};

// A thread of the project that worked in `worktree`, `hour` o'clock its last use.
void haveWorktreeThread(World& world, const QString& project, const QString& id, const QString& branch, const QString& worktree, int hour, const QString& archivedAt = {}) {
  QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("projectId"), project}, {QStringLiteral("worktreePath"), worktree},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T07:00:00Z")},
                  {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T%1:00:00Z").arg(hour, 2, 10, QLatin1Char('0'))}};
  if (!branch.isEmpty()) row.insert(QStringLiteral("branch"), branch);
  if (!archivedAt.isEmpty()) row.insert(QStringLiteral("archivedAt"), archivedAt);
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
}

void haveStartedThread(World& world, const QString& project, const QString& worktree) {
  QJsonObject row{{QStringLiteral("id"), QStringLiteral("t-started")}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), project},
                  {QStringLiteral("latestUserMessageAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  if (!worktree.isEmpty()) row.insert(QStringLiteral("worktreePath"), worktree);
  world.mc.threads.insert(QStringLiteral("t-started"), row);
  world.mc.sendRow(QStringLiteral("t-started"), row);
  world.sync();
}

// A new thread's draft, in `worktree` when there is one.
void openChoiceDraft(World& world, const QString& worktree) {
  newThread(world);
  if (worktree.isEmpty()) return;
  const QString draft = world.native().controller<NavigationController>()->route().draftId;
  auto* controller = world.native().controller<WorkspaceController>();
  WorkspaceController::Checkout checkout = controller->checkout(draft);
  checkout.envMode = QStringLiteral("worktree");
  checkout.worktreePath = worktree;
  controller->setCheckout(draft, checkout);
  world.waitFor([&] { return workspace(world).value(QStringLiteral("worktreePath")) == worktree; },
                [&] { return QStringLiteral("the draft in the worktree; the header shows %1").arg(show(workspace(world))); });
}

void openChoice(World& world) {
  QQuickItem* picker = part(world, QStringLiteral("envModePicker"));
  click(world, picker);
  QObject* popup = picker->property("popup").value<QObject*>();
  world.waitFor([&] { return popup->property("opened").toBool(); }, QStringLiteral("the workspace choice to open"));
}

// What the workspace choice lists, as on screen.
QStringList choices(World& world) {
  QQuickItem* picker = part(world, QStringLiteral("envModePicker"));
  QStringList labels;
  for (int index = 0; index < picker->property("count").toInt(); ++index) {
    QString label;
    QMetaObject::invokeMethod(picker, "textAt", Q_RETURN_ARG(QString, label), Q_ARG(int, index));
    labels.append(label);
  }
  return labels;
}

void openBasePicker(World& world) {
  click(world, part(world, QStringLiteral("branchButton")));
  QObject* popup = composerItem(world)->findChild<QObject*>(QStringLiteral("branchPicker"));
  world.waitFor([&] { return popup && popup->property("opened").toBool(); }, QStringLiteral("the branch picker to open"));
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  // One prompt, several models (drafting-and-sending.feature).
  step(QStringLiteral("the user is starting a new thread"), [](World& world, const Captures&, const Table&) {
    offerCodexAndClaude(world);
    newThread(world);
    world.waitFor([&] { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("selectedModel")) == QLatin1String("gpt-5"); },
                  [&] { return QStringLiteral("the draft on gpt-5; the composer shows %1").arg(show(world.state(QStringLiteral("composer")))); });
  });
  step(QStringLiteral("the user chooses two models and a base branch and sends %1").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseClaudeToo(world);
    expect(part(world, QStringLiteral("modelPickerTitle"))->property("text") == QLatin1String("2 models"), QStringLiteral("the picker does not say two models"));
    pressInComposer(world, QStringLiteral("Escape"));
    confirmBranch(world, QStringLiteral("main"));
    QMetaObject::invokeMethod(composerItem(world), "focusInput");
    typeInComposer(world, c[0]);
    pressInComposer(world, QStringLiteral("Enter"));
  });
  step(QStringLiteral("one thread per model starts with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return launchCalls(world).size() == 2; }, [&] { return QStringLiteral("two launches; the MC got %1 and the toasts are %2").arg(launchCalls(world).size()).arg(show(toasts(world))); });
    QStringList models;
    for (const QJsonObject& call : launchCalls(world)) {
      expect(call.value(QLatin1String("initialMessage")).toObject().value(QLatin1String("text")) == c[0], QStringLiteral("the launch is %1").arg(show(call.toVariantMap())));
      models.append(call.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("model")).toString());
    }
    models.sort();
    expect(models == QStringList{QStringLiteral("claude-opus"), QStringLiteral("gpt-5")}, QStringLiteral("the threads run on %1").arg(models.join(u", ")));
    world.sync();
    expect(std::any_of(toasts(world).cbegin(), toasts(world).cend(), [](const QVariant& toast) { return toast.toMap().value(QStringLiteral("title")).toString().startsWith(QLatin1String("Started 2 thread")); }),
           QStringLiteral("the toasts are %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("each thread works in its own worktree"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> calls = launchCalls(world);
    for (const QJsonObject& call : calls) {
      const QJsonObject strategy = call.value(QLatin1String("workspaceStrategy")).toObject();
      expect(strategy.value(QLatin1String("type")) == QLatin1String("worktree") && strategy.value(QLatin1String("baseRef")) == QLatin1String("main"),
             QStringLiteral("the launch works in %1").arg(show(strategy.toVariantMap())));
    }
    expect(calls.at(0).value(QLatin1String("threadId")) != calls.at(1).value(QLatin1String("threadId")), QStringLiteral("both launches name one thread"));
  });

  // The workspace choice (source-control/worktrees-and-setup-scripts.feature).
  step(QStringLiteral("the user is writing the first message of a new thread in %1 in the project folder").arg(q), [](World& world, const Captures&, const Table&) {
    newThread(world);
  });
  step(QStringLiteral("the user is writing the first message of a new thread in %1 in an existing worktree").arg(q), [](World& world, const Captures& c, const Table&) {
    haveWorktreeThread(world, c[0], QStringLiteral("t-before"), QStringLiteral("feature/tax"), QStringLiteral("/work/shop-worktrees/tax"), 10);
    openChoiceDraft(world, QStringLiteral("/work/shop-worktrees/tax"));
  });
  step(QStringLiteral("the user opens the workspace choice"), [](World& world, const Captures&, const Table&) {
    openChoice(world);
  });
  step(QStringLiteral("the choices are %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(choices(world) == QStringList{c[0], c[1]}, QStringLiteral("the choices are %1").arg(choices(world).join(u", ")));
  });
  step(QStringLiteral("a thread in %1 has started in the project folder").arg(q), [](World& world, const Captures& c, const Table&) {
    haveStartedThread(world, c[0], {});
  });
  step(QStringLiteral("a thread in %1 has started in a worktree").arg(q), [](World& world, const Captures& c, const Table&) {
    haveStartedThread(world, c[0], QStringLiteral("/work/shop-worktrees/tax"));
  });
  step(QStringLiteral("the user looks at the thread's workspace"), [](World& world, const Captures&, const Table&) {
    // A started thread's strip stays only with the setting that keeps it.
    world.native().controller<SettingsController>()->set(QStringLiteral("persistComposerContextStrip"), true);
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(world.mc.environmentId + QStringLiteral(":t-started")));
    world.waitFor([&] { return workspace(world).value(QStringLiteral("threadKey")) == world.mc.environmentId + QStringLiteral(":t-started"); },
                  [&] { return QStringLiteral("the thread; the header shows %1").arg(show(workspace(world))); });
    composerBrick(world);
  });
  step(QStringLiteral("it reads %1 and cannot be changed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const auto locked = [&] {
      return part(world, QStringLiteral("envModeLocked"))->isVisible() && part(world, QStringLiteral("envModeLockedLabel"))->property("text") == c[0] &&
             !part(world, QStringLiteral("envModePicker"))->isVisible() && !workspace(world).value(QStringLiteral("envModeChangeable")).toBool();
    };
    world.waitFor(locked, [&] {
      return QStringLiteral("the lock; shown %1, label \"%2\", composer %3").arg(part(world, QStringLiteral("envModeLocked"))->isVisible())
          .arg(part(world, QStringLiteral("envModeLockedLabel"))->property("text").toString(), show(world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("showContextStrip"))));
    });
    // Asking anyway changes nothing.
    const QString mode = workspace(world).value(QStringLiteral("envMode")).toString();
    world.bridge().dispatch(QStringLiteral("workspace.envMode.set"), QVariantMap{{QStringLiteral("mode"), mode == QLatin1String("worktree") ? QStringLiteral("local") : QStringLiteral("worktree")}});
    world.sync();
    expect(workspace(world).value(QStringLiteral("envMode")) == mode && workspace(world).value(QStringLiteral("envModeLabel")) == c[0], QStringLiteral("the header shows %1").arg(show(workspace(world))));
  });
  step(QStringLiteral("the user chose two models for a new thread in %1").arg(q), [](World& world, const Captures&, const Table&) {
    offerCodexAndClaude(world);
    newThread(world);
    chooseClaudeToo(world);
    pressInComposer(world, QStringLiteral("Escape"));
  });
  step(QStringLiteral("the user looks at the workspace choice"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("it says each model starts in its own worktree"), [](World& world, const Captures&, const Table&) {
    const QString hint = part(world, QStringLiteral("envModeLocked"))->property("hint").toString();
    expect(hint == QLatin1String("Each model starts in its own worktree."), QStringLiteral("it says \"%1\"").arg(hint));
    expect(workspace(world).value(QStringLiteral("envMode")) == QLatin1String("worktree"), QStringLiteral("the header shows %1").arg(show(workspace(world))));
  });
  step(QStringLiteral("the most recently used worktree of %1 is on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    haveWorktreeThread(world, c[0], QStringLiteral("t-latest"), c[1], QStringLiteral("/work/shop-worktrees/latest"), 10);
  });
  step(QStringLiteral("the most recently used worktree of %1 is on no branch").arg(q), [](World& world, const Captures& c, const Table&) {
    haveWorktreeThread(world, c[0], QStringLiteral("t-latest"), {}, QStringLiteral("/work/shop-worktrees/latest"), 10);
  });
  step(QStringLiteral("the most recently used worktree of %1 is the worktree the new thread is already in").arg(q), [](World& world, const Captures& c, const Table&) {
    haveWorktreeThread(world, c[0], QStringLiteral("t-latest"), QStringLiteral("feature/here"), QStringLiteral("/work/shop-worktrees/latest"), 10);
    world.mc.part<ChoiceDraft>().worktree = QStringLiteral("/work/shop-worktrees/latest");
  });
  step(QStringLiteral("the most recently used worktree of %1 belongs only to an archived thread").arg(q), [](World& world, const Captures& c, const Table&) {
    haveWorktreeThread(world, c[0], QStringLiteral("t-latest"), QStringLiteral("feature/gone"), QStringLiteral("/work/shop-worktrees/latest"), 10, QStringLiteral("2026-09-23T10:30:00Z"));
  });
  step(QStringLiteral("an older thread in %1 used another worktree").arg(q), [](World& world, const Captures& c, const Table&) {
    haveWorktreeThread(world, c[0], QStringLiteral("t-older"), QStringLiteral("feature/older"), QStringLiteral("/work/shop-worktrees/older"), 8);
  });
  step(QStringLiteral("no thread in %1 has used a worktree").arg(q), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the user opens the workspace choice of a new thread"), [](World& world, const Captures&, const Table&) {
    openChoiceDraft(world, world.mc.part<ChoiceDraft>().worktree);
    openChoice(world);
  });
  step(QStringLiteral("it offers %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(choices(world).size() == 3 && choices(world).at(2) == c[0], QStringLiteral("the choices are %1").arg(choices(world).join(u", ")));
  });
  step(QStringLiteral("the other worktree is offered as the previous worktree"), [](World& world, const Captures&, const Table&) {
    expect(choices(world).size() == 3 && choices(world).at(2) == QLatin1String("Previous worktree (feature/older)"), QStringLiteral("the choices are %1").arg(choices(world).join(u", ")));
  });
  step(QStringLiteral("the choices are the current checkout and a new worktree only"), [](World& world, const Captures&, const Table&) {
    expect(choices(world) == QStringList{QStringLiteral("Current checkout"), QStringLiteral("New worktree")}, QStringLiteral("the choices are %1").arg(choices(world).join(u", ")));
  });

  // The base picker's start from origin.
  step(QStringLiteral("the user chose a new worktree for a new thread in %1").arg(q), [](World& world, const Captures&, const Table&) {
    newThread(world);
    pick(world, QStringLiteral("envModePicker"), 1);
  });
  step(QStringLiteral("the user opens the base picker"), [](World& world, const Captures&, const Table&) { openBasePicker(world); });
  step(QStringLiteral("it offers %1 with a switch for starting the worktree from origin").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* row = part(world, QStringLiteral("startFromOriginRow"));
    QQuickItem* toggle = part(world, QStringLiteral("startFromOrigin"));
    expect(row->isVisible() && toggle->isVisible(), QStringLiteral("the switch is not offered"));
    expect(composerBrick(world).shows(c[0]), QStringLiteral("the picker does not say \"%1\"").arg(c[0]));
  });
  step(QStringLiteral("it explains this creates the worktree from the latest matching branch on origin instead of the local branch"), [](World& world, const Captures&, const Table&) {
    const QString help = part(world, QStringLiteral("startFromOriginHelp"))->property("text").toString();
    expect(help.contains(QLatin1String("latest matching branch on origin")) && help.contains(QLatin1String("instead of your local branch")), QStringLiteral("it says \"%1\"").arg(help));
  });
  step(QStringLiteral("%1 is (off|on) in the settings").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("Start new worktrees from origin"), QStringLiteral("no such setting: %1").arg(c[0]));
    saveElsewhere(world.mc, QStringLiteral("newWorktreesStartFromOrigin"), c[1] == QLatin1String("on"));
    world.waitFor([&] { return world.native().controller<SettingsController>()->setting(QStringLiteral("newWorktreesStartFromOrigin")).toBool() == (c[1] == QLatin1String("on")); },
                  QStringLiteral("the shell to take the setting"));
  });
  const auto newWorktreeOnMain = [](World& world) {
    newThread(world);
    pick(world, QStringLiteral("envModePicker"), 1);
  };
  const auto sendOnMain = [](World& world) {
    confirmBranch(world, QStringLiteral("main"));
    sendFirstMessage(world);
  };
  step(QStringLiteral("the user turns on %1 in a new thread's base picker").arg(q), [newWorktreeOnMain](World& world, const Captures&, const Table&) {
    newWorktreeOnMain(world);
    openBasePicker(world);
    click(world, part(world, QStringLiteral("startFromOrigin")));
    world.waitFor([&] { return workspace(world).value(QStringLiteral("startFromOrigin")).toBool(); }, [&] { return QStringLiteral("the switch to take; the header shows %1").arg(show(workspace(world))); });
    pressInComposer(world, QStringLiteral("Escape"));
    QObject* popup = composerItem(world)->findChild<QObject*>(QStringLiteral("branchPicker"));
    world.waitFor([&] { return !popup->property("visible").toBool(); }, QStringLiteral("the branch picker to close"));
  });
  step(QStringLiteral("the user turns off %1 in a new thread's base picker").arg(q), [newWorktreeOnMain](World& world, const Captures&, const Table&) {
    newWorktreeOnMain(world);
    openBasePicker(world);
    expect(part(world, QStringLiteral("startFromOrigin"))->property("checked").toBool(), QStringLiteral("the switch starts off with the setting on"));
    click(world, part(world, QStringLiteral("startFromOrigin")));
    world.waitFor([&] { return !workspace(world).value(QStringLiteral("startFromOrigin")).toBool(); }, [&] { return QStringLiteral("the switch to take; the header shows %1").arg(show(workspace(world))); });
    pressInComposer(world, QStringLiteral("Escape"));
    QObject* popup = composerItem(world)->findChild<QObject*>(QStringLiteral("branchPicker"));
    world.waitFor([&] { return !popup->property("visible").toBool(); }, QStringLiteral("the branch picker to close"));
  });
  step(QStringLiteral("that thread's worktree starts from origin"), [sendOnMain](World& world, const Captures&, const Table&) {
    if (launchCalls(world).isEmpty()) sendOnMain(world);
    const QJsonObject strategy = launch(world).value(QLatin1String("workspaceStrategy")).toObject();
    expect(strategy.value(QLatin1String("type")) == QLatin1String("worktree") && strategy.value(QLatin1String("startFromOrigin")).toBool(), QStringLiteral("the launch works in %1").arg(show(strategy.toVariantMap())));
  });
  step(QStringLiteral("that thread's worktree starts from the local branch"), [sendOnMain](World& world, const Captures&, const Table&) {
    if (launchCalls(world).isEmpty()) sendOnMain(world);
    const QJsonObject strategy = launch(world).value(QLatin1String("workspaceStrategy")).toObject();
    expect(strategy.value(QLatin1String("type")) == QLatin1String("worktree") && !strategy.value(QLatin1String("startFromOrigin")).toBool(), QStringLiteral("the launch works in %1").arg(show(strategy.toVariantMap())));
  });
  step(QStringLiteral("the project's default workspace is a new worktree"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("defaultThreadEnvMode"), QStringLiteral("worktree"));
    world.sync();
  });
  step(QStringLiteral("the user opens a new thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(c[0])}});
    world.waitFor([&] { return workspace(world).value(QStringLiteral("envMode")) == QLatin1String("worktree"); },
                  [&] { return QStringLiteral("the draft in a new worktree; the header shows %1").arg(show(workspace(world))); });
  });
  step(QStringLiteral("the setting stays (off|on)"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const bool on = c[0] == QLatin1String("on");
    expect(world.native().controller<SettingsController>()->setting(QStringLiteral("newWorktreesStartFromOrigin")).toBool() == on &&
               fakeConfig(world.mc).settings.value(QLatin1String("newWorktreesStartFromOrigin")).toBool() == on,
           QStringLiteral("the setting changed"));
  });

  // The machine.
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

  step(QStringLiteral("%1 has the project %1 and the connected machine %1 has only %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[1] == kProject, QStringLiteral("the open thread's project is %1").arg(kProject));
    world.mc.label = c[0];
    // The second machine joins the cluster under its own name.
    world.mc.peers.insert(kPeerEnvironment, kPeer);
    const int shell = world.mc.subscribers(QStringLiteral("shell")).value(0);
    world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.environment")}, {QStringLiteral("id"), shell}, {QStringLiteral("mc"), kPeer},
                   {QStringLiteral("environment"), QJsonObject{{QStringLiteral("environmentId"), kPeerEnvironment}, {QStringLiteral("label"), c[2]}, {QStringLiteral("capabilities"), world.mc.capabilities}}}});
    world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.mc")}, {QStringLiteral("id"), shell}, {QStringLiteral("mc"), kPeer}, {QStringLiteral("online"), true}});
    world.mc.sendRows(kPeer, {QJsonValue(QJsonArray{c[3], QStringLiteral("project"),
                                                    QJsonObject{{QStringLiteral("id"), c[3]}, {QStringLiteral("title"), c[3]}, {QStringLiteral("workspaceRoot"), QStringLiteral("/srv/") + c[3]},
                                                                {QStringLiteral("scripts"), QJsonArray()}}})});
    world.sync();
  });
  step(QStringLiteral("the user has typed a prompt for a new thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kProject, QStringLiteral("the open thread's project is %1").arg(kProject));
    newThread(world);
    typeInComposer(world, kPrompt);
    settleComposer(world);
  });
  step(QStringLiteral("the user chooses %1 as the machine the thread runs on").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList environments = workspace(world).value(QStringLiteral("environments")).toList();
    int choice = -1;
    for (qsizetype i = 0; i < environments.size(); ++i) {
      if (environments.at(i).toMap().value(QStringLiteral("label")) == c[0]) choice = int(i);
    }
    expect(choice >= 0, QStringLiteral("the composer offers %1").arg(show(environments)));
    pick(world, QStringLiteral("hostPicker"), choice);
  });
  step(QStringLiteral("the new thread is in %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return workspace(world).value(QStringLiteral("activeEnvironmentId")) == kPeerEnvironment && workspace(world).value(QStringLiteral("projectTitle")) == c[0]; },
                  [&] { return QStringLiteral("the draft in %1 on %2; the header shows %3").arg(c[0], c[1], show(workspace(world))); });
    const auto where = world.native().controller<WorkspaceController>()->launch(world.draftId);
    expect(where.environmentId == kPeerEnvironment && where.projectId == c[0] && // The draft is the machine's own now: the picker names the machine, the header the project.
               part(world, QStringLiteral("hostPicker"))->property("displayText") == c[1],
           QStringLiteral("the thread would start in %1 on %2; the picker reads \"%3\"")
               .arg(where.projectId, where.environmentId, part(world, QStringLiteral("hostPicker"))->property("displayText").toString()));
  });
  step(QStringLiteral("the prompt is still there"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    expect(composerEditor(world)->property("text") == kPrompt && world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("target")) == world.draftId,
           QStringLiteral("the composer reads \"%1\"").arg(composerEditor(world)->property("text").toString()));
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
    // A started thread keeps the composer's branch control only with Composer context on.
    world.native().controller<SettingsController>()->set(QStringLiteral("persistComposerContextStrip"), true);
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

bool connectSecondComposerEnvironment(World& world) {
  // The composer's scenarios: a thread of Stream.h's is open.
  if (world.mc.part<FakeStreams>().thread.isEmpty()) return false;
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
  return true;
}
