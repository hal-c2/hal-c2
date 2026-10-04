// Project actions beyond running them (features/files/project-scripts-and-actions.feature)
// and the checkout's hal-c2.json (files/project-file.feature): the action
// editor and the thread details' Actions as the window draws them
// (ProjectActionEditor.qml, ThreadDetailsPanel.qml) over
// ProjectActionsController. TerminalSteps.cpp runs actions from the header.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "FakeConfig.h"
#include "FakeFiles.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Keymap.h"
#include "NavigationController.h"
#include "ProjectActionsController.h"
#include "RightPanelController.h"
#include "World.h"

namespace {

QJsonArray scriptsOf(World& world, const QString& project) {
  return world.mc.projects.value(project).value(QLatin1String("scripts")).toArray();
}

std::optional<QJsonObject> scriptNamed(World& world, const QString& project, const QString& name) {
  for (const QJsonValue& value : scriptsOf(world, project)) {
    if (value.toObject().value(QLatin1String("name")) == name) return value.toObject();
  }
  return std::nullopt;
}

QString describeScripts(World& world, const QString& project) {
  return QStringLiteral("%1 has the actions %2").arg(project, QString::fromUtf8(QJsonDocument(scriptsOf(world, project)).toJson(QJsonDocument::Compact)));
}

// The project the scenario's actions belong to: the first the MC has.
QString project(World& world) {
  expect(!world.mc.projects.isEmpty(), QStringLiteral("the MC has no project"));
  return world.mc.projects.contains(QStringLiteral("shop")) ? QStringLiteral("shop") : world.mc.projects.firstKey();
}

void setScripts(World& world, const QString& project, const QJsonArray& scripts) {
  QJsonObject row = world.mc.projects.value(project);
  row.insert(QStringLiteral("scripts"), scripts);
  world.mc.projects.insert(project, row);
  world.mc.sendRow(project, row, QStringLiteral("project"));
  world.sync();
}

QJsonObject script(const QString& id, const QString& name, const QString& command, bool setup = false) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("name"), name}, {QStringLiteral("command"), command},
          {QStringLiteral("icon"), QStringLiteral("play")}, {QStringLiteral("runOnWorktreeCreate"), setup}};
}

QVariant workspace(World& world) {
  return world.state(QStringLiteral("workspace"));
}

QVariantMap actions(World& world) {
  return world.state(QStringLiteral("projectActions")).toMap();
}

// A thread of `project`, shown in the window (TerminalSteps' thread).
void showThread(World& world, const QString& project) {
  const QString threadId = QStringLiteral("thread-in-") + project;
  const QString key = world.mc.environmentId + QLatin1Char(':') + threadId;
  if (at(workspace(world), QStringLiteral("threadKey")) == key && at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("thread")) return;
  const QJsonObject row{{QStringLiteral("id"), threadId}, {QStringLiteral("title"), QStringLiteral("Cart")}, {QStringLiteral("projectId"), project},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  world.mc.threads.insert(threadId, row);
  world.mc.sendRow(threadId, row);
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return at(workspace(world), QStringLiteral("threadKey")) == key && actions(world).value(QStringLiteral("projectKey")) == world.mc.environmentId + QLatin1Char(':') + project; },
                [&] { return QStringLiteral("the thread of %1; the header shows %2").arg(project, show(workspace(world))); });
}

// --- The terminal the action runs in ---------------------------------------------------

QList<QJsonObject> terminalCalls(World& world, const QString& method) {
  QList<QJsonObject> calls;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == method) calls.append(rpc.payload);
  }
  return calls;
}

// `command` was typed into a terminal opened in the thread's workspace.
void expectRan(World& world, const QString& command) {
  const QString cwd = at(workspace(world), QStringLiteral("worktreePath")).toString().isEmpty() ? at(workspace(world), QStringLiteral("projectRoot")).toString()
                                                                                                : at(workspace(world), QStringLiteral("worktreePath")).toString();
  world.waitFor([&] {
    const QList<QJsonObject> opened = terminalCalls(world, QStringLiteral("terminal.open"));
    const QList<QJsonObject> written = terminalCalls(world, QStringLiteral("terminal.write"));
    return std::any_of(opened.cbegin(), opened.cend(), [&](const QJsonObject& call) { return call.value(QLatin1String("cwd")) == cwd; }) &&
           std::any_of(written.cbegin(), written.cend(), [&](const QJsonObject& call) { return call.value(QLatin1String("data")) == command + QLatin1Char('\r'); });
  }, [&] {
    return QStringLiteral("%1 in a terminal at %2; terminals were opened %3 and written %4")
        .arg(command, cwd, show(QVariant::fromValue(terminalCalls(world, QStringLiteral("terminal.open")))), show(QVariant::fromValue(terminalCalls(world, QStringLiteral("terminal.write")))));
  });
}

// --- The editor ------------------------------------------------------------------------

void showEditorBrick(World& world) {
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { ProjectActionEditor {} }\n", QSize(900, 800));
  world.waitFor([&] { return world.brick->root()->findChild<QObject*>(QStringLiteral("projectActionEditor"))->property("opened").toBool(); },
                QStringLiteral("the action editor to open"));
}

// The editor on a new action, or on the action named `name`.
void openEditor(World& world, const QString& name = {}) {
  showThread(world, project(world));
  if (name.isEmpty()) {
    world.bridge().dispatch(ProjectActionsController::kAdd, QVariantMap{});
  } else {
    const std::optional<QJsonObject> found = scriptNamed(world, project(world), name);
    expect(found.has_value(), describeScripts(world, project(world)));
    world.bridge().dispatch(QStringLiteral("projectActions.edit"), QVariantMap{{QStringLiteral("scriptId"), found->value(QLatin1String("id")).toString()}});
  }
  expect(!actions(world).value(QStringLiteral("editor")).isNull(), QStringLiteral("no editor opened: %1").arg(show(actions(world))));
  showEditorBrick(world);
}

// Replaces what the field holds, typing as the user does.
void type(World& world, const QString& field, const QString& text) {
  world.brick->click(field);
  QQuickItem* item = world.brick->item(field);
  expect(item->hasActiveFocus(), QStringLiteral("%1 did not take the keyboard").arg(field));
  QMetaObject::invokeMethod(item, "selectAll");
  if (text.isEmpty()) {
    QTest::keyClick(&world.brick->window(), Qt::Key_Backspace);
  } else {
    for (const QChar character : text) QTest::keyClick(&world.brick->window(), character.toLatin1());
  }
}

void save(World& world) {
  world.brick->click(QStringLiteral("projectActionSave"));
  world.sync();
}

void saved(World& world) {
  world.waitFor([&] { return actions(world).value(QStringLiteral("editor")).isNull(); },
                [&] { return QStringLiteral("the editor to close; it is %1").arg(show(actions(world).value(QStringLiteral("editor")))); });
  world.sync();
}

int updates(World& world) {
  int count = 0;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    count += rpc.method == QLatin1String("projects.mutate") && rpc.payload.value(QLatin1String("type")) == QLatin1String("project.update") &&
             rpc.payload.contains(QLatin1String("scripts"));
  }
  return count;
}

// --- Shortcuts -------------------------------------------------------------------------

KeybindingController* keymap(World& world) {
  return world.native().controller<KeybindingController>();
}

QString commandOf(World& world, const QString& project, const QString& name) {
  const std::optional<QJsonObject> found = scriptNamed(world, project, name);
  return QStringLiteral("script.%1.run").arg(found ? found->value(QLatin1String("id")).toString() : name.toLower());
}

bool bound(World& world, const QString& key, const QString& command) {
  for (const QJsonValue& rule : fakeConfig(world.mc).config.value(QLatin1String("keybindingRules")).toArray()) {
    if (rule.toObject().value(QLatin1String("key")) == key && rule.toObject().value(QLatin1String("command")) == command) return true;
  }
  return false;
}

void bindShortcut(World& world, const QString& command, const QString& key) {
  keymap(world)->save(command, key, QString());
  world.waitFor([&] { return bound(world, key, command) && !keymap(world)->saving(); }, QStringLiteral("the shortcut to be saved"));
  world.sync();
}

// --- hal-c2.json -----------------------------------------------------------------------

void writeProjectFile(World& world, const QString& contents) {
  fakeFiles(world.mc).files.insert(QStringLiteral("hal-c2.json"), contents);
}

QString fileScripts(const QList<std::pair<QString, QString>>& scripts) {
  QJsonArray list;
  for (const auto& [name, command] : scripts) list.append(QJsonObject{{QStringLiteral("name"), name}, {QStringLiteral("command"), command}});
  return QString::fromUtf8(QJsonDocument(QJsonObject{{QStringLiteral("scripts"), list}}).toJson());
}

// The thread details column, with the project's actions.
void showDetails(World& world, const QString& project) {
  showThread(world, project);
  auto* panel = world.native().controller<RightPanelController>();
  if (!panel->detailsOpen()) world.bridge().dispatch(QStringLiteral("threadPanel.toggle"), QVariantMap());
  world.waitFor([&] { return actions(world).value(QStringLiteral("file")) != QLatin1String("loading"); }, QStringLiteral("hal-c2.json to be read"));
  world.sync();  // the thread's own read of the file has been answered
  world.sync();
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n"
                                               "ThreadDetailsPanel { details: Shell.state.panel?.details ?? null }\n",
                                        QSize(280, 800));
}

QStringList offeredImports(World& world) {
  QStringList names;
  for (const QVariant& offered : actions(world).value(QStringLiteral("imports")).toList()) {
    const QString name = offered.toMap().value(QStringLiteral("name")).toString();
    // As the details column draws them.
    if (world.brick->item(QStringLiteral("threadDetailsImport-") + name)->isVisible()) names.append(name);
  }
  return names;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Running from the thread's details and from a shortcut.
  step(QStringLiteral("the user is looking at the details of a thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showDetails(world, c[0]);
  });
  step(QStringLiteral("the user runs %1 from the thread's details").arg(q), [](World& world, const Captures& c, const Table&) {
    const std::optional<QJsonObject> found = scriptNamed(world, project(world), c[0]);
    expect(found.has_value(), describeScripts(world, project(world)));
    world.brick->click(QStringLiteral("threadDetailsAction-") + found->value(QLatin1String("id")).toString());
    world.sync();
  });
  step(QStringLiteral("%1 runs in a terminal for the thread's workspace").arg(q), [](World& world, const Captures& c, const Table&) { expectRan(world, c[0]); });
  step(QStringLiteral("%1 runs in the thread's terminal").arg(q), [](World& world, const Captures& c, const Table&) { expectRan(world, c[0]); });
  step(QStringLiteral("%1 has the shortcut %1").arg(q), [](World& world, const Captures& c, const Table&) {
    bindShortcut(world, commandOf(world, project(world), c[0]), c[1]);
  });
  step(QStringLiteral("the user presses %1 in a thread of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showThread(world, c[1]);
    pressKey(world, c[0]);
    world.sync();
  });

  // Adding, editing and removing.
  step(QStringLiteral("the user adds an action named %1 running %1 with the (play|test|lint|configure|build|debug) icon").arg(q),
       [](World& world, const Captures& c, const Table&) {
         openEditor(world);
         type(world, QStringLiteral("projectActionName"), c[0]);
         type(world, QStringLiteral("projectActionCommand"), c[1]);
         world.bridge().dispatch(QStringLiteral("projectActions.set"), QVariantMap{{QStringLiteral("icon"), c[2]}});
         save(world);
         saved(world);
       });
  step(QStringLiteral("%1 has the action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (world.onSettingsPage.contains(QStringLiteral("hasAction"))) return world.onSettingsPage.value(QStringLiteral("hasAction"))(c);
    world.waitFor([&] { return scriptNamed(world, c[0], c[1]).has_value(); }, [&] { return describeScripts(world, c[0]); });
    world.sync();
    // And the header offers it.
    const QString id = scriptNamed(world, c[0], c[1])->value(QLatin1String("id")).toString();
    const QVariantList offered = at(workspace(world), QStringLiteral("scripts")).toList();
    expect(std::any_of(offered.cbegin(), offered.cend(), [&](const QVariant& entry) { return at(entry, QStringLiteral("id")) == id; }),
           QStringLiteral("the header offers %1").arg(show(offered)));
  });
  step(QStringLiteral("%1 can be run").arg(q), [](World& world, const Captures& c, const Table&) {
    const std::optional<QJsonObject> found = scriptNamed(world, project(world), c[0]);
    expect(found.has_value(), describeScripts(world, project(world)));
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), found->value(QLatin1String("id")).toString()}});
    expectRan(world, found->value(QLatin1String("command")).toString());
  });
  step(QStringLiteral("the user adds an action with (no name|no command)"), [](World& world, const Captures& c, const Table&) {
    openEditor(world);
    if (c[0] == QLatin1String("no name")) {
      type(world, QStringLiteral("projectActionCommand"), QStringLiteral("bun test"));
    } else {
      type(world, QStringLiteral("projectActionName"), QStringLiteral("Test"));
    }
    save(world);
  });
  step(QStringLiteral("no action is added"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(updates(world) == 0 && !actions(world).value(QStringLiteral("editor")).isNull(),
           QStringLiteral("the project was saved %1 time(s); %2").arg(updates(world)).arg(describeScripts(world, project(world))));
  });
  step(QStringLiteral("the user changes the command of %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openEditor(world, c[0]);
    type(world, QStringLiteral("projectActionCommand"), c[1]);
    save(world);
    saved(world);
  });
  step(QStringLiteral("%1 runs %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const std::optional<QJsonObject> found = scriptNamed(world, project(world), c[0]);
    expect(found && found->value(QLatin1String("command")) == c[1], describeScripts(world, project(world)));
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), found->value(QLatin1String("id")).toString()}});
    expectRan(world, c[1]);
  });
  step(QStringLiteral("the user deletes the action %1(?: from %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    openEditor(world, c[0]);
    world.brick->click(QStringLiteral("projectActionDelete"));
    // "from <project>" has no question in its scenario: the user says yes.
    if (!c.value(1).isEmpty()) {
      const QVariant question = world.state(QStringLiteral("confirmation"));
      expect(question.typeId() == QMetaType::QVariantMap, QStringLiteral("no question is asked"));
      world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                              QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), true}});
      world.waitFor([&] { return !scriptNamed(world, c[1], c[0]).has_value(); }, [&] { return describeScripts(world, c[1]); });
      world.sync();
    }
  });
  step(QStringLiteral("the user is asked to confirm deleting %1 because it cannot be undone").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariant question = world.state(QStringLiteral("confirmation"));
    expect(at(question, QStringLiteral("title")) == QStringLiteral("Delete action \"%1\"?").arg(c[0]) &&
               at(question, QStringLiteral("description")) == QLatin1String("This action cannot be undone.") && at(question, QStringLiteral("destructive")).toBool(),
           QStringLiteral("the question is %1").arg(show(question)));
    expect(scriptNamed(world, project(world), c[0]).has_value(), QStringLiteral("the action went before the user answered"));
  });
  step(QStringLiteral("%1 no longer has the action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !scriptNamed(world, c[0], c[1]).has_value(); }, [&] { return describeScripts(world, c[0]); });
    world.sync();
    const QVariantList offered = at(workspace(world), QStringLiteral("scripts")).toList();
    expect(std::none_of(offered.cbegin(), offered.cend(), [&](const QVariant& entry) { return at(entry, QStringLiteral("name")) == c[1]; }),
           QStringLiteral("the header offers %1").arg(show(offered)));
  });

  // The setup script.
  step(QStringLiteral("%1 is the setup script of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonArray scripts = scriptsOf(world, c[1]);
    if (!scriptNamed(world, c[1], c[0])) scripts.append(script(c[0].toLower(), c[0], QStringLiteral("bun install"), true));
    setScripts(world, c[1], scripts);
  });
  step(QStringLiteral("the user makes %1 run automatically on worktree creation").arg(q), [](World& world, const Captures& c, const Table&) {
    openEditor(world, c[0]);
    world.brick->click(QStringLiteral("projectActionSetup"));
    save(world);
    saved(world);
  });
  step(QStringLiteral("%1 is the setup script").arg(q), [](World& world, const Captures& c, const Table&) {
    const std::optional<QJsonObject> found = scriptNamed(world, project(world), c[0]);
    expect(found && found->value(QLatin1String("runOnWorktreeCreate")).toBool(), describeScripts(world, project(world)));
  });
  step(QStringLiteral("%1 no longer runs on worktree creation").arg(q), [](World& world, const Captures& c, const Table&) {
    const std::optional<QJsonObject> found = scriptNamed(world, project(world), c[0]);
    expect(found && !found->value(QLatin1String("runOnWorktreeCreate")).toBool(), describeScripts(world, project(world)));
  });

  // Shortcuts.
  step(QStringLiteral("the user clears the shortcut of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openEditor(world, c[0]);
    world.brick->click(QStringLiteral("projectActionKeybinding"));
    QTest::keyClick(&world.brick->window(), Qt::Key_Backspace);
    save(world);
    saved(world);
  });
  step(QStringLiteral("%1 no longer runs %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString command = commandOf(world, project(world), c[1]);
    world.waitFor([&] {
      const QList<keybindings::Binding>& bindings = keymap(world)->resolved();
      return !bound(world, c[0], command) &&
             std::none_of(bindings.cbegin(), bindings.cend(), [&](const keybindings::Binding& binding) { return binding.command == command; });
    }, [&] { return QStringLiteral("%1 to stop running %2; the rules are %3").arg(c[0], command, show(fakeConfig(world.mc).config.value(QLatin1String("keybindingRules")).toArray().toVariantList())); });
  });
  step(QStringLiteral("the project %1 also has an action %1 with the shortcut %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString command = commandOf(world, project(world), c[1]);
    const QJsonObject row{{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]},
                          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                          {QStringLiteral("scripts"), QJsonArray{script(command.section(QLatin1Char('.'), 1, 1), c[1], QStringLiteral("bun docs"))}}};
    world.mc.projects.insert(c[0], row);
    world.mc.sendRow(c[0], row, QStringLiteral("project"));
    world.sync();
    bindShortcut(world, command, c[2]);
  });
  step(QStringLiteral("%1 still runs %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const std::optional<QJsonObject> found = scriptNamed(world, c[2], c[1]);
    expect(found.has_value(), describeScripts(world, c[2]));
    const QString command = QStringLiteral("script.%1.run").arg(found->value(QLatin1String("id")).toString());
    const QList<keybindings::Binding>& bindings = keymap(world)->resolved();
    expect(bound(world, c[0], command) &&
               std::any_of(bindings.cbegin(), bindings.cend(), [&](const keybindings::Binding& binding) { return binding.command == command; }),
           QStringLiteral("the rules are %1").arg(show(fakeConfig(world.mc).config.value(QLatin1String("keybindingRules")).toArray().toVariantList())));
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      expect(rpc.method != QLatin1String("hal-c2.removeKeybinding"), QStringLiteral("the shortcut was removed"));
    }
  });

  // The preview address.
  step(QStringLiteral("the user edits %1 without a preview address").arg(q), [](World& world, const Captures& c, const Table&) {
    openEditor(world, c[0]);
    expect(actions(world).value(QStringLiteral("editor")).toMap().value(QStringLiteral("previewUrl")).toString().isEmpty(), show(actions(world)));
  });
  step(QStringLiteral("opening the preview automatically (cannot|can) be turned on"), [](World& world, const Captures& c, const Table&) {
    const bool wanted = c[0] == QLatin1String("can");
    const QQuickItem* toggle = world.brick->item(QStringLiteral("projectActionAutoOpenPreview"));
    world.waitFor([&] { return toggle->isEnabled() == wanted; }, QStringLiteral("the switch to be %1").arg(wanted ? u"enabled" : u"disabled"));
    if (!wanted) return;
    world.brick->click(QStringLiteral("projectActionAutoOpenPreview"));
    world.waitFor([&] { return actions(world).value(QStringLiteral("editor")).toMap().value(QStringLiteral("autoOpenPreview")).toBool(); },
                  [&] { return QStringLiteral("the editor to take it; it is %1").arg(show(actions(world).value(QStringLiteral("editor")))); });
  });
  step(QStringLiteral("the user sets the preview address %1").arg(q), [](World& world, const Captures& c, const Table&) {
    type(world, QStringLiteral("projectActionPreviewUrl"), c[0]);
  });

  // hal-c2.json.
  step(QStringLiteral("the checkout's hal-c2.json sets the default workspace to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    writeProjectFile(world, QStringLiteral("{\"defaultThreadEnvMode\": \"%1\"}").arg(c[0]));
  });
  step(QStringLiteral("the user never chose a default workspace for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject settings = fakeConfig(world.mc).settings;
    expect(settings.value(QLatin1String("defaultThreadEnvMode")).toString().isEmpty() &&
               !settings.value(QLatin1String("projectSettingsOverrides")).toObject().value(c[0]).toObject().contains(QLatin1String("defaultThreadEnvMode")),
           QStringLiteral("the settings are %1").arg(show(settings.toVariantMap())));
  });
  step(QStringLiteral("the user set the default workspace for %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    saveOn(world.mc, world.mc.environmentId, QStringLiteral("projectSettingsOverrides"),
           QJsonObject{{c[0], QJsonObject{{QStringLiteral("defaultThreadEnvMode"), c[1]}}}});
    world.sync();
  });
  const auto startsIn = [](World& world, const QString& mode) {
    world.waitFor([&] { return at(workspace(world), QStringLiteral("isDraft")).toBool() && actions(world).value(QStringLiteral("file")) != QLatin1String("loading"); },
                  [&] { return QStringLiteral("the draft and its hal-c2.json; the header shows %1").arg(show(workspace(world))); });
    world.waitFor([&] { return at(workspace(world), QStringLiteral("envMode")) == mode; },
                  [&] { return QStringLiteral("the draft to start in \"%1\"; the header shows %2").arg(mode, show(workspace(world))); });
    world.sync();
    expect(at(workspace(world), QStringLiteral("envMode")) == mode, QStringLiteral("the header shows %1").arg(show(workspace(world))));
  };
  step(QStringLiteral("the draft starts in a new worktree"), [startsIn](World& world, const Captures&, const Table&) { startsIn(world, QStringLiteral("worktree")); });
  step(QStringLiteral("the draft starts in the project folder"), [startsIn](World& world, const Captures&, const Table&) { startsIn(world, QStringLiteral("local")); });

  step(QStringLiteral("the checkout's hal-c2.json declares the actions %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    writeProjectFile(world, fileScripts({{c[0], QStringLiteral("bun ") + c[0].toLower()}, {c[1], QStringLiteral("bun ") + c[1].toLower()}}));
  });
  step(QStringLiteral("the checkout's hal-c2.json declares %1 running %1 and %1 running %1").arg(q), [](World& world, const Captures& c, const Table&) {
    writeProjectFile(world, fileScripts({{c[0], c[1]}, {c[2], c[3]}}));
  });
  step(QStringLiteral("the checkout's hal-c2.json does not match the project file format"), [](World& world, const Captures&, const Table&) {
    // A script without a command.
    writeProjectFile(world, QStringLiteral("{\"scripts\": [{\"name\": \"Dev\"}]}"));
  });
  step(QStringLiteral("the checkout's hal-c2.json has comments and declares the action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    writeProjectFile(world, QStringLiteral("// Shared with everyone who opens the checkout.\n{\n  /* the dev server */\n  \"scripts\": [\n"
                                           "    {\"name\": \"%1\", \"command\": \"bun dev\"}, // trailing comma next\n  ],\n}\n").arg(c[0]));
  });
  step(QStringLiteral("%1 already has an action %1 running %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonArray scripts = scriptsOf(world, c[0]);
    scripts.append(script(c[1].toLower(), c[1], c[2]));
    setScripts(world, c[0], scripts);
  });
  step(QStringLiteral("the user looks at the actions of %1").arg(q), [](World& world, const Captures& c, const Table&) { showDetails(world, c[0]); });
  step(QStringLiteral("%1 and %1 are offered to import from hal-c2.json").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(offeredImports(world) == QStringList({c[0], c[1]}), QStringLiteral("the details offer %1").arg(offeredImports(world).join(u", ")));
  });
  step(QStringLiteral("%1 is offered to import from hal-c2.json").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(offeredImports(world) == QStringList({c[0]}), QStringLiteral("the details offer %1").arg(offeredImports(world).join(u", ")));
  });
  step(QStringLiteral("the user imports actions from hal-c2.json"), [](World& world, const Captures&, const Table&) {
    showDetails(world, project(world));
    const QStringList offered = offeredImports(world);
    expect(!offered.isEmpty(), QStringLiteral("nothing is offered to import: %1").arg(show(actions(world))));
    for (const QString& name : offered) {
      const int before = scriptsOf(world, project(world)).size();
      world.brick->click(QStringLiteral("threadDetailsImport-") + name);
      world.waitFor([&] { return scriptsOf(world, project(world)).size() > before; }, [&] { return describeScripts(world, project(world)); });
      world.sync();
    }
  });
  step(QStringLiteral("only %1 is added").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonArray scripts = scriptsOf(world, project(world));
    expect(scripts.size() == 2 && scripts.last().toObject().value(QLatin1String("name")) == c[0] && updates(world) == 1,
           describeScripts(world, project(world)));
    expect(actions(world).value(QStringLiteral("imports")).toList().isEmpty(), QStringLiteral("more is offered: %1").arg(show(actions(world))));
  });
  step(QStringLiteral("the user is warned that hal-c2.json is invalid"), [](World& world, const Captures&, const Table&) {
    if (world.onSettingsPage.contains(QStringLiteral("invalidProjectFile"))) return world.onSettingsPage.value(QStringLiteral("invalidProjectFile"))(Captures());
    const QQuickItem* warning = world.brick->item(QStringLiteral("threadDetailsProjectFileProblem"));
    expect(warning->isVisible() && warning->property("text").toString().startsWith(QStringLiteral("hal-c2.json is invalid")),
           QStringLiteral("the details say nothing of the file: %1").arg(show(actions(world))));
  });
  step(QStringLiteral("no actions are offered from it"), [](World& world, const Captures&, const Table&) {
    expect(actions(world).value(QStringLiteral("imports")).toList().isEmpty(), show(actions(world)));
  });
});

}  // namespace
