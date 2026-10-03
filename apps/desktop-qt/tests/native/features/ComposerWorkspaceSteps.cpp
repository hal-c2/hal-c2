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

// `server.getHostResources` (HostResourcesSnapshot): each machine's free CPU
// and memory, by environment; `refuse` fails the check.
struct FakeResources {
  QHash<QString, QJsonObject> machines;
  QString refuse;
  int asked = 0;
};

const FakeMc::Extension resources([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("server.getHostResources"), [&mc](const FakeMc::Rpc& rpc) {
    ++mc.part<FakeResources>().asked;
    const auto answer = [&mc, rpc] {
      const FakeResources& fake = mc.part<FakeResources>();
      if (!fake.refuse.isEmpty()) {
        mc.refuse(rpc, fake.refuse);
        return;
      }
      const QString environment = rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
      mc.reply(rpc, fake.machines.value(environment));
    };
    if (mc.holding(QStringLiteral("resources"))) {
      mc.defer(answer);
    } else {
      answer();
    }
  });
});

QJsonObject machine(double cpuUtilization, double freeMemory) {
  return {{QStringLiteral("sampledAt"), 1790157600000.0},
          {QStringLiteral("cpuUtilization"), cpuUtilization},
          {QStringLiteral("cpuCount"), 8},
          {QStringLiteral("availableMemoryBytes"), freeMemory * 16e9},
          {QStringLiteral("totalMemoryBytes"), 16e9}};
}

// "shop" on this machine ("laptop") and on "server", with load balancing on:
// the laptop is busy, the server idle.
void twoBalancedMachines(World& world) {
  const QJsonObject identity{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}};
  QJsonObject row = world.mc.projects.value(kProject);
  row.insert(QStringLiteral("repositoryIdentity"), identity);
  world.mc.projects.insert(kProject, row);
  world.mc.sendRows(world.mc.name, {QJsonValue(QJsonArray{kProject, QStringLiteral("project"), row})});
  world.mc.peers.insert(kPeerEnvironment, kPeer);
  const int shell = world.mc.subscribers(QStringLiteral("shell")).value(0);
  world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.environment")}, {QStringLiteral("id"), shell}, {QStringLiteral("mc"), kPeer},
                 {QStringLiteral("environment"), QJsonObject{{QStringLiteral("environmentId"), kPeerEnvironment}, {QStringLiteral("label"), QStringLiteral("server")}, {QStringLiteral("capabilities"), world.mc.capabilities}}}});
  world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.mc")}, {QStringLiteral("id"), shell}, {QStringLiteral("mc"), kPeer}, {QStringLiteral("online"), true}});
  world.mc.sendRows(kPeer, {QJsonValue(QJsonArray{QStringLiteral("shop-copy"), QStringLiteral("project"),
                                                  QJsonObject{{QStringLiteral("id"), QStringLiteral("shop-copy")}, {QStringLiteral("title"), kProject},
                                                              {QStringLiteral("workspaceRoot"), QStringLiteral("/srv/shop")}, {QStringLiteral("scripts"), QJsonArray()},
                                                              {QStringLiteral("repositoryIdentity"), identity}}})});
  world.mc.part<FakeResources>().machines = {{world.mc.environmentId, machine(0.9, 0.2)}, {kPeerEnvironment, machine(0.1, 0.8)}};
  world.native().controller<SettingsController>()->set(QStringLiteral("loadBalancingEnabled"), true);
  world.sync();
}

int choiceLabelled(World& world, const QString& label) {
  const QVariantList environments = workspace(world).value(QStringLiteral("environments")).toList();
  for (qsizetype i = 0; i < environments.size(); ++i) {
    if (environments.at(i).toMap().value(QStringLiteral("label")) == label) return int(i);
  }
  fail(QStringLiteral("the composer offers %1, not %2").arg(show(environments), label));
}

const Steps steps([] {
  const QString q = kQuoted;

  // One prompt, several models (drafting-and-sending.feature).
  step(QStringLiteral("the user is starting a new thread"), [](World& world, const Captures&, const Table&) {
    // With Codex and Claude ready to take it.
    if (world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList().isEmpty()) {
      const auto provider = [](const QString& id, const QString& name, const QStringList& models) {
        QJsonArray list;
        for (const QString& slug : models) list.append(QJsonObject{{QStringLiteral("slug"), slug}, {QStringLiteral("name"), slug}});
        return QJsonObject{{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), id}, {QStringLiteral("displayName"), name}, {QStringLiteral("enabled"), true},
                           {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")}, {QStringLiteral("models"), list}};
      };
      publishProviders(world.mc, {provider(QStringLiteral("codex"), QStringLiteral("Codex"), {QStringLiteral("gpt-5"), QStringLiteral("gpt-5-codex")}),
                                  provider(QStringLiteral("claudeAgent"), QStringLiteral("Claude"), {QStringLiteral("claude-opus"), QStringLiteral("claude-sonnet")})});
      world.sync();
    }
    newThread(world);
    world.waitFor([&] { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("selectedModel")) == QLatin1String("gpt-5"); },
                  [&] { return QStringLiteral("the draft on gpt-5; the composer shows %1").arg(show(world.state(QStringLiteral("composer")))); });
  });
  step(QStringLiteral("the user chooses two models and a base branch and sends %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The draft's own model, and Claude's beside it.
    click(world, part(world, QStringLiteral("modelPicker")));
    world.waitFor([&] { return composerPart(world, QStringLiteral("modelPickerProvider:claudeAgent")) != nullptr; }, QStringLiteral("the model picker to open"));
    click(world, part(world, QStringLiteral("modelPickerProvider:claudeAgent")));
    world.waitFor([&] { return composerPart(world, QStringLiteral("modelPickerMultiple:claudeAgent:claude-opus")) != nullptr; }, QStringLiteral("Claude's models"));
    click(world, part(world, QStringLiteral("modelPickerMultiple:claudeAgent:claude-opus")));
    world.waitFor([&] { return world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("multiple")).toList().size() == 2; },
                  [&] { return QStringLiteral("two models; the picker has %1").arg(show(world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("multiple")))); });
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

  // Auto balance.
  step(QStringLiteral("the project exists on two connected machines and load balancing is on"), [](World& world, const Captures&, const Table&) {
    twoBalancedMachines(world);
  });
  step(QStringLiteral("the user chooses \"Auto balance\" as the machine a new thread runs on"), [](World& world, const Captures&, const Table&) {
    newThread(world);
    pick(world, QStringLiteral("hostPicker"), choiceLabelled(world, QStringLiteral("Auto balance")));
  });
  step(QStringLiteral("the thread starts on the machine with the most room when the first message is sent"), [](World& world, const Captures&, const Table&) {
    expect(part(world, QStringLiteral("hostPicker"))->property("displayText") == QLatin1String("Auto balance") && world.mc.part<FakeResources>().asked == 2,
           QStringLiteral("the picker reads \"%1\" after %2 checks").arg(part(world, QStringLiteral("hostPicker"))->property("displayText").toString()).arg(world.mc.part<FakeResources>().asked));
    sendFirstMessage(world);
    // The idle server's checkout, not the busy laptop's.
    const QJsonObject call = launch(world);
    expect(call.value(QLatin1String("projectId")) == QLatin1String("shop-copy"), QStringLiteral("the launch is %1").arg(show(call.toVariantMap())));
  });
  step(QStringLiteral("the user chose \"Auto balance\" for a new thread"), [](World& world, const Captures&, const Table&) {
    twoBalancedMachines(world);
    // The machines have not answered yet.
    world.mc.hold(QStringLiteral("resources"));
    newThread(world);
    pick(world, QStringLiteral("hostPicker"), choiceLabelled(world, QStringLiteral("Auto balance")));
    world.waitFor([&] { return part(world, QStringLiteral("hostPicker"))->property("displayText") == QStringLiteral("Checking machines…"); },
                  [&] { return QStringLiteral("the picker to check the machines; it reads \"%1\"").arg(part(world, QStringLiteral("hostPicker"))->property("displayText").toString()); });
  });
  step(QStringLiteral("checking the machines' free resources fails"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeResources>().refuse = QStringLiteral("resource telemetry is unavailable");
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the picker shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return part(world, QStringLiteral("hostPicker"))->property("displayText") == c[0]; },
                  [&] { return QStringLiteral("the picker to read %1; it reads \"%2\"").arg(c[0], part(world, QStringLiteral("hostPicker"))->property("displayText").toString()); });
  });
  step(QStringLiteral("the user chooses the machine %1 instead").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.label = c[0];
    pick(world, QStringLiteral("hostPicker"), 1);
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the thread starts on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(workspace(world).value(QStringLiteral("activeEnvironmentId")) == world.mc.environmentId && !workspace(world).value(QStringLiteral("environmentAutomatic")).toBool(),
           QStringLiteral("the header shows %1").arg(show(workspace(world))));
    sendFirstMessage(world);
    // This machine's checkout, though the server has more room.
    const QJsonObject call = launch(world);
    expect(call.value(QLatin1String("projectId")) == kProject && c[0] == world.mc.label, QStringLiteral("the launch is %1").arg(show(call.toVariantMap())));
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
