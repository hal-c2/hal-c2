// Starting threads (features/threads/creating.feature): the model a new
// thread starts with, background starts that leave the draft ready for the
// next one, one prompt sent to several models, and a draft moved to another
// project, the thread list's button, and starts that fail or cannot be made.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QSet>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "CommandPaletteController.h"
#include "ComposerController.h"
#include "DraftController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Launches.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "SidebarController.h"
#include "ThreadList.h"
#include "WorkspaceController.h"
#include "World.h"

namespace {

QJsonObject selectionOf(const QString& model) {
  return {{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")},
          {QStringLiteral("model"), QStringLiteral("claude-") + model.toLower()}};
}

struct Creating {
  // The draft's thread id when the scenario's first prompt was written.
  QString firstThreadId;
  // The draft sent while its thread is still being made, and its thread.
  QString sentDraftId;
  QString sentThreadKey;
};

NavigationController* navigation(World& world) {
  return world.native().controller<NavigationController>();
}

WorkspaceController* workspace(World& world) {
  return world.native().controller<WorkspaceController>();
}

void startDraft(World& world, const QVariantMap& payload = {}) {
  world.startNewThread(payload);
  world.waitFor([&] { return navigation(world)->route().kind == QLatin1String("draft"); },
                [&] { return QStringLiteral("a draft; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  world.draftId = navigation(world)->route().draftId;
  world.waitFor([&] { return world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("isDraft")).toBool(); },
                QStringLiteral("the header to show the draft"));
}

// A new worktree off "main", as the header's checkout picker sets it.
void useNewWorktree(World& world) {
  WorkspaceController::Checkout checkout;
  checkout.envMode = QStringLiteral("worktree");
  checkout.branch = QStringLiteral("main");
  workspace(world)->setCheckout(world.draftId, checkout);
}

void type(World& world, const QString& text) {
  world.bridge().dispatch(QStringLiteral("composer.text.set"),
                          QVariantMap{{QStringLiteral("target"), world.draftId}, {QStringLiteral("text"), text}, {QStringLiteral("cursor"), text.size()}});
}

void sendInBackground(World& world) {
  world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("intent"), QStringLiteral("background")}});
  world.sync();
}

// The project's folder is a Git checkout on "main": its status reaches whoever follows it.
void makeGitProject(World& world, const QString& project) {
  const QString cwd = QStringLiteral("/work/") + project;
  const QJsonObject local{{QStringLiteral("isRepo"), true}, {QStringLiteral("isDefaultRef"), true}, {QStringLiteral("hasWorkingTreeChanges"), false},
                          {QStringLiteral("hasPrimaryRemote"), true}, {QStringLiteral("refName"), QStringLiteral("main")},
                          {QStringLiteral("workingTree"), QJsonObject{{QStringLiteral("files"), QJsonArray()}}}};
  world.mc.checkouts.insert(cwd, [local] { return QJsonObject{{QStringLiteral("local"), local}, {QStringLiteral("remote"), QJsonObject()}}; });
  for (const int id : world.mc.subscribers(QStringLiteral("vcs"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("cwd")) != cwd) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("vcs")}, {QStringLiteral("id"), id},
                   {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("localUpdated")}, {QStringLiteral("local"), local}}}});
  }
  world.sync();
}

const QList<std::pair<QString, QJsonObject>>& models() {
  static const QList<std::pair<QString, QJsonObject>> list{
      {QStringLiteral("Opus"), {{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), QStringLiteral("claude-opus")}}},
      {QStringLiteral("GPT-5"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}}},
      {QStringLiteral("Gemini"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("model"), QStringLiteral("gemini-2.5-pro")}}},
  };
  return list;
}

QJsonObject modelNamed(const QString& name) {
  for (const auto& [label, selection] : models()) {
    if (label == name) return selection;
  }
  fail(QStringLiteral("no model \"%1\"").arg(name));
}

// The three agents, each with its model, ready to run.
void offerModels(World& world) {
  QJsonArray providers;
  for (const auto& [label, selection] : models()) {
    const QString instance = selection.value(QLatin1String("instanceId")).toString();
    providers.append(QJsonObject{{QStringLiteral("instanceId"), instance}, {QStringLiteral("driver"), instance}, {QStringLiteral("displayName"), label},
                                 {QStringLiteral("enabled"), true}, {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")},
                                 {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), selection.value(QLatin1String("model"))},
                                                                                  {QStringLiteral("name"), label},
                                                                                  {QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("optionDescriptors"), QJsonArray()}}}}}}});
  }
  publishProviders(world.mc, providers);
  world.sync();
  world.waitFor([&] { return world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList().size() == 3; },
                [&] { return QStringLiteral("the models; the picker is %1").arg(show(world.state(QStringLiteral("modelPicker")))); });
}

void choose(World& world, const char* action, const QString& name) {
  world.bridge().dispatch(QString::fromLatin1(action), modelNamed(name).toVariantMap());
}

QVariantList severalModels(World& world) {
  return world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("multiple")).toList();
}


QVariantMap composerShown(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

// The thread list as the window draws it (Sidebar.qml).
Brick& threadList(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, QByteArrayLiteral("import QtQuick\nimport HalC2.Bricks\nSidebar { height: 600 }\n"), QSize(256, 600));
  }
  return *world.brick;
}

void addProject(World& world, const QString& name) {
  const QJsonObject row{{QStringLiteral("id"), name}, {QStringLiteral("title"), name}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + name},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}, {QStringLiteral("scripts"), QJsonArray()}};
  world.mc.projects.insert(name, row);
  world.mc.sendRow(name, row, QStringLiteral("project"));
  world.sync();
}

std::optional<DraftController::Draft> draftOf(World& world, const QString& id) {
  return world.native().controller<DraftController>()->draft(id);
}

void submit(World& world) {
  world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("intent"), QStringLiteral("foreground")}});
  world.sync();
}

// A draft in a new worktree, sent, whose launch the MC holds: its thread is
// still being made.
void sendHeld(World& world) {
  makeGitProject(world, world.mc.projects.firstKey());
  startDraft(world);
  useNewWorktree(world);
  type(world, QStringLiteral("Set up the linter"));
  Creating& creating = world.mc.part<Creating>();
  creating.sentDraftId = world.draftId;
  creating.sentThreadKey = world.mc.environmentId + QLatin1Char(':') + draftOf(world, world.draftId)->threadId;
  world.mc.hold(QStringLiteral("answers"));
  submit(world);
  world.waitFor([&] { return launchCalls(world).size() == 1; }, [&] { return QStringLiteral("the launch; the toasts are %1").arg(show(world.state(QStringLiteral("toasts")))); });
}

bool toldTitled(World& world, const QString& title) {
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    if (item.toMap().value(QStringLiteral("title")).toString().startsWith(title)) return true;
  }
  return false;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Background starts.
  step(QStringLiteral("the user has written a first message in a draft"), [](World& world, const Captures&, const Table&) {
    makeGitProject(world, world.mc.projects.firstKey());
    startDraft(world);
    useNewWorktree(world);
    type(world, QStringLiteral("Set up the linter"));
    world.mc.part<Creating>().firstThreadId = world.native().controller<DraftController>()->draft(world.draftId)->threadId;
  });
  step(QStringLiteral("the user starts the thread in the background"), [](World& world, const Captures&, const Table&) { sendInBackground(world); });
  step(QStringLiteral("the thread starts working without being opened"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return launchCalls(world).size() == 1; }, QStringLiteral("the launch"));
    const QJsonObject launch = launchCalls(world).constFirst();
    expect(launch.value(QLatin1String("threadId")) == world.mc.part<Creating>().firstThreadId &&
               launch.value(QLatin1String("initialMessage")).toObject().value(QLatin1String("text")) == QLatin1String("Set up the linter"),
           QStringLiteral("the launch is %1").arg(show(launch.toVariantMap())));
    expect(navigation(world)->route().kind == QLatin1String("draft") && navigation(world)->route().draftId == world.draftId,
           QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("a new draft opens with the same workspace mode and base branch"), [](World& world, const Captures&, const Table&) {
    const auto draft = world.native().controller<DraftController>()->draft(world.draftId);
    const WorkspaceController::Checkout checkout = workspace(world)->checkout(world.draftId);
    const QVariantMap composer = world.state(QStringLiteral("composer")).toMap();
    // The same draft, for a thread of its own, with nothing written yet.
    expect(draft && draft->threadId != world.mc.part<Creating>().firstThreadId && composer.value(QStringLiteral("target")) == world.draftId &&
               composer.value(QStringLiteral("text")).toString().isEmpty(),
           QStringLiteral("the composer shows %1").arg(show(composer)));
    expect(checkout.envMode == QLatin1String("worktree") && checkout.branch == QStringLiteral("main"),
           QStringLiteral("the draft is in %1 on %2").arg(checkout.envMode, checkout.branch.value_or(QString())));
  });
  step(QStringLiteral("the draft is set to use a new worktree"), [](World& world, const Captures&, const Table&) {
    makeGitProject(world, world.mc.projects.firstKey());
    startDraft(world);
    useNewWorktree(world);
  });
  step(QStringLiteral("the user starts two threads in the background"), [](World& world, const Captures&, const Table&) {
    for (const QString& prompt : {QStringLiteral("Add caching"), QStringLiteral("Add retries")}) {
      type(world, prompt);
      sendInBackground(world);
    }
  });
  step(QStringLiteral("each thread works in its own new worktree"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QList<QJsonObject> launches = launchCalls(world);
    expect(launches.size() >= 2, QStringLiteral("the MC launched %1 threads").arg(launches.size()));
    QSet<QString> threads;
    for (const QJsonObject& launch : launches) {
      const QJsonObject strategy = launch.value(QLatin1String("workspaceStrategy")).toObject();
      // A worktree the MC makes for this thread alone, off the base branch.
      expect(strategy.value(QLatin1String("type")) == QLatin1String("worktree") && strategy.value(QLatin1String("baseRef")) == QLatin1String("main") &&
                 !strategy.contains(QLatin1String("worktreePath")),
             QStringLiteral("the launch is %1").arg(show(launch.toVariantMap())));
      threads.insert(launch.value(QLatin1String("threadId")).toString());
    }
    expect(threads.size() == launches.size(), QStringLiteral("two launches share a thread"));
  });

  // Several models.
  step(QStringLiteral("%1 is a Git project").arg(q), [](World& world, const Captures& c, const Table&) { makeGitProject(world, c[0]); });
  step(QStringLiteral("the user sends the first message to the models %1, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startDraft(world);
    world.waitFor([&] { return workspace(world)->git() && workspace(world)->git()->local.value(QLatin1String("isRepo")).toBool(); },
                  QStringLiteral("the draft's checkout to be known"));
    offerModels(world);
    choose(world, "composer.model.select", c[0]);
    choose(world, "composer.model.multiple.toggle", c[1]);
    choose(world, "composer.model.multiple.toggle", c[2]);
    expect(severalModels(world).size() == 3, QStringLiteral("the picker is %1").arg(show(world.state(QStringLiteral("modelPicker")))));
    type(world, QStringLiteral("Add caching"));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  step(QStringLiteral("three threads are created, one per model"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return launchCalls(world).size() == 3; }, [&] { return QStringLiteral("three launches; the MC got %1").arg(launchCalls(world).size()); });
    QStringList started;
    for (const QJsonObject& launch : launchCalls(world)) {
      expect(launch.value(QLatin1String("initialMessage")).toObject().value(QLatin1String("text")) == QLatin1String("Add caching"),
             QStringLiteral("the launch is %1").arg(show(launch.toVariantMap())));
      started.append(launch.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("model")).toString());
    }
    started.sort();
    expect(started == QStringList{QStringLiteral("claude-opus"), QStringLiteral("gemini-2.5-pro"), QStringLiteral("gpt-5")},
           QStringLiteral("the models are %1").arg(started.join(QStringLiteral(", "))));
    // The window stays on the draft, ready for another prompt.
    expect(navigation(world)->route().draftId == world.draftId && world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("text")).toString().isEmpty(),
           QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("%1 is not a Git project").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject row{{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]},
                          {QStringLiteral("scripts"), QJsonArray()}};
    world.mc.projects.insert(c[0], row);
    world.mc.sendRow(c[0], row, QStringLiteral("project"));
    world.sync();
    startDraft(world, QVariantMap{{QStringLiteral("projectKey"), world.projectKey(c[0])}});
    world.waitFor([&] { return workspace(world)->git().has_value(); }, QStringLiteral("the draft's folder to be read"));
  });
  step(QStringLiteral("the user tries to pick more than one model for the first message"), [](World& world, const Captures&, const Table&) {
    offerModels(world);
    choose(world, "composer.model.select", QStringLiteral("Opus"));
    choose(world, "composer.model.multiple.toggle", QStringLiteral("GPT-5"));
  });
  step(QStringLiteral("only one model can be chosen"), [](World& world, const Captures&, const Table&) {
    const QVariantMap composer = world.state(QStringLiteral("composer")).toMap();
    expect(severalModels(world).isEmpty() && composer.value(QStringLiteral("selectedModel")) == QLatin1String("gpt-5"),
           QStringLiteral("the picker is %1, the composer %2").arg(show(severalModels(world)), show(composer)));
    bool told = false;
    for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      told |= item.toMap().value(QStringLiteral("title")) == QLatin1String("Only one model can be chosen");
    }
    expect(told, QStringLiteral("the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });

  // A draft's project.
  step(QStringLiteral("the project %1 exists only on the environment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.join(QStringLiteral("mc-") + c[1], c[1]);
    world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.mc")}, {QStringLiteral("id"), world.mc.subscribers(QStringLiteral("shell")).value(0)},
                   {QStringLiteral("mc"), QStringLiteral("mc-") + c[1]}, {QStringLiteral("online"), true}});
    world.mc.sendRows(QStringLiteral("mc-") + c[1],
                      QJsonArray{QJsonValue(QJsonArray{c[0], QStringLiteral("project"),
                                                       QJsonObject{{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]},
                                                                   {QStringLiteral("workspaceRoot"), QStringLiteral("/srv/") + c[0]}, {QStringLiteral("scripts"), QJsonArray()}}})});
    world.sync();
    // The draft that is moved (DraftSteps' "the user moves the draft to"): this machine's, with something written.
    startDraft(world);
    type(world, QStringLiteral("Sketch the endpoint"));
    const auto before = world.native().controller<DraftController>()->draft(world.draftId);
    expect(before && before->environmentId == world.mc.environmentId, QStringLiteral("the draft is not this machine's"));
  });
  step(QStringLiteral("the draft targets the environment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The draft the window shows after the move.
    const auto draft = world.native().controller<DraftController>()->draft(world.native().controller<NavigationController>()->route().draftId);
    expect(draft && draft->environmentId == c[0] && draft->projectId == QLatin1String("api"),
           QStringLiteral("the draft is on %1 in %2").arg(draft ? draft->environmentId : QString(), draft ? draft->projectId : QString()));
    // What was written came along, and the header names the new project.
    world.waitFor([&] { return world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("projectTitle")) == QLatin1String("api"); },
                  [&] { return QStringLiteral("the header to name api; it shows %1").arg(show(world.state(QStringLiteral("workspace")))); });
    expect(world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("text")) == QLatin1String("Sketch the endpoint"),
           QStringLiteral("the composer shows %1").arg(show(world.state(QStringLiteral("composer")))));
  });

  step(QStringLiteral("%1 has the default model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.projects.contains(c[0]), QStringLiteral("there is no project %1").arg(c[0]));
    QJsonObject row = world.mc.projects.value(c[0]);
    row.insert(QStringLiteral("defaultModelSelection"), selectionOf(c[1]));
    world.mc.projects.insert(c[0], row);
    world.mc.sendRow(c[0], row, QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("the current thread uses the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    expect(!key.isEmpty(), QStringLiteral("no thread is open"));
    updateThreadRow(world, key.mid(key.indexOf(QLatin1Char(':')) + 1), [&](QJsonObject& row) { row.insert(QStringLiteral("modelSelection"), selectionOf(c[0])); });
    world.waitFor([&] { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("selectedModel")) == selectionOf(c[0]).value(QLatin1String("model")).toString(); },
                  [&] { return QStringLiteral("the thread's model; the composer is %1").arg(show(world.state(QStringLiteral("composer")))); });
  });
  step(QStringLiteral("the draft uses the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap composer = world.state(QStringLiteral("composer")).toMap();
      return world.state(QStringLiteral("route")).toMap().value(QStringLiteral("kind")) == QLatin1String("draft") &&
             composer.value(QStringLiteral("target")) == world.draftId &&
             composer.value(QStringLiteral("selectedModel")) == selectionOf(c[0]).value(QLatin1String("model")).toString();
    }, [&] { return QStringLiteral("the draft on %1; the composer is %2").arg(c[0], show(world.state(QStringLiteral("composer")))); });
  });
  // The thread list's new thread button.
  step(QStringLiteral("the environment also has the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addProject(world, c[0]);
    world.waitFor([&] { return world.native().sidebar()->groups().size() == 2; }, QStringLiteral("two projects in the sidebar"));
  });
  step(QStringLiteral("%1 is the only project").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const auto& groups = world.native().sidebar()->groups();
    expect(groups.size() == 1 && groups.constFirst().summary.value(QStringLiteral("displayName")) == c[0],
           QStringLiteral("the sidebar has %1 projects").arg(groups.size()));
  });
  step(QStringLiteral("the user presses the new thread button in the thread list( with Shift held)?"), [](World& world, const Captures& c, const Table&) {
    Brick& list = threadList(world);
    world.sync();
    QQuickItem* button = list.item(QStringLiteral("newThread"));
    QTest::mouseClick(&list.window(), Qt::LeftButton, c[0].isEmpty() ? Qt::NoModifier : Qt::ShiftModifier, list.at(button));
    world.sync();
  });
  step(QStringLiteral("the user is asked which project to start the thread in"), [](World& world, const Captures&, const Table&) {
    auto* palette = world.native().controller<CommandPaletteController>();
    expect(palette->isOpen() && palette->submenu() == QLatin1String("New thread in...") && palette->count() == 2,
           QStringLiteral("the palette is %1 on \"%2\" with %3 entries")
               .arg(palette->isOpen() ? QStringLiteral("open") : QStringLiteral("closed"), palette->submenu())
               .arg(palette->count()));
    expect(navigation(world)->route().kind == QLatin1String("thread"),
           QStringLiteral("a thread started without asking: %1").arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("a draft thread opens in %1 without asking").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return navigation(world)->route().kind == QLatin1String("draft"); },
                  [&] { return QStringLiteral("a draft; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
    world.draftId = navigation(world)->route().draftId;
    const auto draft = draftOf(world, world.draftId);
    expect(draft && draft->projectId == c[0], QStringLiteral("the draft is in %1").arg(draft ? draft->projectId : QString()));
    expect(!world.native().controller<CommandPaletteController>()->isOpen(), QStringLiteral("the command palette asked"));
  });
  step(QStringLiteral("the button's hint says Shift starts the thread in the current project"), [](World& world, const Captures&, const Table&) {
    const QString hint = threadList(world).item(QStringLiteral("newThread"))->property("toolTip").toString();
    expect(hint.contains(QStringLiteral("New thread in current project: Shift+click")), QStringLiteral("the hint is \"%1\"").arg(hint));
  });

  // The model and mode a new thread keeps.
  step(QStringLiteral("the current thread uses the model %1 in plan mode").arg(q), [](World& world, const Captures& c, const Table&) {
    offerModels(world);
    expect(world.native().controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true), QStringLiteral("plan mode could not be turned on"));
    const QString key = navigation(world)->threadKey();
    expect(!key.isEmpty(), QStringLiteral("no thread is open"));
    const QJsonObject model = modelNamed(c[0]);
    updateThreadRow(world, key.mid(key.indexOf(QLatin1Char(':')) + 1), [&](QJsonObject& row) {
      row.insert(QStringLiteral("modelSelection"), model);
      row.insert(QStringLiteral("interactionMode"), QStringLiteral("plan"));
    });
    world.waitFor([&] { return composerShown(world).value(QStringLiteral("selectedModel")) == model.value(QLatin1String("model")).toString() &&
                               composerShown(world).value(QStringLiteral("interactionMode")) == QLatin1String("plan"); },
                  [&] { return QStringLiteral("the thread's model and mode; the composer is %1").arg(show(composerShown(world))); });
  });
  step(QStringLiteral("the draft uses the model %1 in plan mode").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString model = modelNamed(c[0]).value(QLatin1String("model")).toString();
    world.waitFor([&] {
      const QVariantMap composer = composerShown(world);
      return navigation(world)->route().kind == QLatin1String("draft") && composer.value(QStringLiteral("target")) == navigation(world)->route().draftId &&
             composer.value(QStringLiteral("selectedModel")) == model && composer.value(QStringLiteral("interactionMode")) == QLatin1String("plan");
    }, [&] { return QStringLiteral("the draft on %1 in plan mode; the composer is %2").arg(c[0], show(composerShown(world))); });
  });

  // A new thread while the last one is still being made.
  step(QStringLiteral("the user sent a draft that is still creating its worktree"), [](World& world, const Captures&, const Table&) { sendHeld(world); });
  step(QStringLiteral("a fresh draft opens"), [](World& world, const Captures&, const Table&) {
    const QString sent = world.mc.part<Creating>().sentDraftId;
    world.waitFor([&] { return navigation(world)->route().kind == QLatin1String("draft") && navigation(world)->route().draftId != sent; },
                  [&] { return QStringLiteral("a fresh draft; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
    world.draftId = navigation(world)->route().draftId;
    const QVariantMap composer = composerShown(world);
    expect(composer.value(QStringLiteral("target")) == world.draftId && composer.value(QStringLiteral("text")).toString().isEmpty(),
           QStringLiteral("the composer shows %1").arg(show(composer)));
  });
  step(QStringLiteral("the sent thread keeps setting up and starts when its worktree is ready"), [](World& world, const Captures&, const Table&) {
    const Creating& creating = world.mc.part<Creating>();
    expect(draftOf(world, creating.sentDraftId).has_value() && world.native().controller<ComposerController>()->launching(creating.sentDraftId),
           QStringLiteral("the sent draft is no longer being made"));
    world.mc.answerHeld();
    world.sync();
    world.waitFor([&] { return !draftOf(world, creating.sentDraftId) && world.mc.threads.contains(creating.sentThreadKey.section(u':', 1)); },
                  QStringLiteral("the sent thread to start"));
    expect(launchCalls(world).size() == 1 && navigation(world)->route().draftId == world.draftId,
           QStringLiteral("%1 launches; the route is %2").arg(launchCalls(world).size()).arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("the user sent a draft and opened a new draft while it set up"), [](World& world, const Captures&, const Table&) {
    sendHeld(world);
    world.startNewThread({});
    world.waitFor([&] { return navigation(world)->route().draftId != world.mc.part<Creating>().sentDraftId; }, QStringLiteral("a new draft"));
    world.draftId = navigation(world)->route().draftId;
    type(world, QStringLiteral("Write the changelog"));
  });
  step(QStringLiteral("the sent thread fails to start"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("orchestration.launchThread"), QStringLiteral("Provider unavailable"));
    world.mc.answerHeld();
    world.sync();
    world.waitFor([&] { return !world.native().controller<ComposerController>()->launching(world.mc.part<Creating>().sentDraftId); },
                  QStringLiteral("the launch to be answered"));
  });
  step(QStringLiteral("its prompt is back in its own draft"), [](World& world, const Captures&, const Table&) {
    const auto sent = draftOf(world, world.mc.part<Creating>().sentDraftId);
    expect(sent && sent->text == QLatin1String("Set up the linter"), QStringLiteral("the sent draft reads \"%1\"").arg(sent ? sent->text : QString()));
  });
  step(QStringLiteral("the new draft is unchanged"), [](World& world, const Captures&, const Table&) {
    const auto fresh = draftOf(world, world.draftId);
    const QVariantMap composer = composerShown(world);
    expect(fresh && fresh->text == QLatin1String("Write the changelog") && navigation(world)->route().draftId == world.draftId &&
               composer.value(QStringLiteral("text")) == QLatin1String("Write the changelog"),
           QStringLiteral("the composer shows %1").arg(show(composer)));
  });

  // A request to several models whose start fails after the user moved on.
  step(QStringLiteral("a request to several models is still starting"), [](World& world, const Captures&, const Table&) {
    makeGitProject(world, world.mc.projects.firstKey());
    startDraft(world);
    world.waitFor([&] { return workspace(world)->git() && workspace(world)->git()->local.value(QLatin1String("isRepo")).toBool(); },
                  QStringLiteral("the draft's checkout to be known"));
    offerModels(world);
    choose(world, "composer.model.select", QStringLiteral("Opus"));
    choose(world, "composer.model.multiple.toggle", QStringLiteral("Gemini"));
    expect(severalModels(world).size() == 2, QStringLiteral("the picker is %1").arg(show(world.state(QStringLiteral("modelPicker")))));
    world.mc.hold(QStringLiteral("answers"));
    type(world, QStringLiteral("Add caching"));
    submit(world);
    world.waitFor([&] { return launchCalls(world).size() == 2; }, [&] { return QStringLiteral("two launches; the MC got %1").arg(launchCalls(world).size()); });
  });
  step(QStringLiteral("the user has typed a new prompt in the emptied draft"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return composerShown(world).value(QStringLiteral("text")).toString().isEmpty(); },
                  [&] { return QStringLiteral("the draft to empty; the composer shows %1").arg(show(composerShown(world))); });
    type(world, QStringLiteral("Add retries"));
  });
  step(QStringLiteral("one of the models fails to start"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("orchestration.launchThread"), QStringLiteral("Provider unavailable"));
    world.mc.answerHeld();
    world.sync();
    world.waitFor([&] { return toldTitled(world, QStringLiteral("Could not start")); },
                  [&] { return QStringLiteral("the failure; the toasts are %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the new prompt is left as it is"), [](World& world, const Captures&, const Table&) {
    const QVariantMap composer = composerShown(world);
    const auto draft = draftOf(world, world.draftId);
    expect(composer.value(QStringLiteral("text")) == QLatin1String("Add retries") && draft && draft->text == QLatin1String("Add retries"),
           QStringLiteral("the composer shows %1").arg(show(composer)));
  });

  // A draft whose project is gone: here, its machine left the cluster.
  step(QStringLiteral("the draft's project is no longer available"), [](World& world, const Captures&, const Table&) {
    world.draftId = world.native().controller<DraftController>()->start(QStringLiteral("env-left"), QStringLiteral("shop"));
    world.waitFor([&] { return composerShown(world).value(QStringLiteral("target")) == world.draftId; },
                  [&] { return QStringLiteral("the draft; the composer is %1").arg(show(composerShown(world))); });
  });
  step(QStringLiteral("the draft keeps its prompt"), [](World& world, const Captures&, const Table&) {
    const auto draft = draftOf(world, world.draftId);
    expect(draft && !draft->text.isEmpty() && composerShown(world).value(QStringLiteral("text")) == draft->text && launchCalls(world).isEmpty(),
           QStringLiteral("the composer shows %1").arg(show(composerShown(world))));
  });

  // A start the environment refuses, or cannot be asked for.
  step(QStringLiteral("the environment rejects new threads"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("orchestration.launchThread"), QStringLiteral("Provider unavailable"));
  });
  step(QStringLiteral("the user sends the first message of a new thread"), [](World& world, const Captures&, const Table&) {
    startDraft(world);
    type(world, QStringLiteral("Add caching"));
    submit(world);
  });
  step(QStringLiteral("the environment is unreachable"), [](World& world, const Captures&, const Table&) {
    world.mc.setOnline(world.mc.environmentId, false);
    world.sync();
  });
  step(QStringLiteral("the user is told the environment is offline"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return composerShown(world).value(QStringLiteral("sendDisabledReason")) == QLatin1String("Not connected"); },
                  [&] { return QStringLiteral("the composer to say so; it is %1").arg(show(composerShown(world))); });
    type(world, QStringLiteral("Add caching"));
    submit(world);
    world.waitFor([&] { return toldTitled(world, QStringLiteral("Not connected")); },
                  [&] { return QStringLiteral("the notice; the toasts are %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("no draft is sent to the environment"), [](World& world, const Captures&, const Table&) {
    expect(launchCalls(world).isEmpty(), QStringLiteral("the MC was asked to launch"));
    expect(!composerShown(world).value(QStringLiteral("text")).toString().isEmpty(), QStringLiteral("the draft lost its prompt"));
  });
});

}  // namespace
