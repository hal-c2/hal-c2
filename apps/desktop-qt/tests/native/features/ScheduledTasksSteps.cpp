// The native Scheduled Tasks settings section (ScheduledTasksController): the
// settings scenarios of features/settings/scheduled-tasks.feature. The fake
// keeps each environment's tasks as the node's HalC2.ScheduledTasks does,
// answering scheduledTasks.* and the `scheduledTasks` shape.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "FakeNode.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "World.h"

namespace {

struct FakeTasks {
  QHash<QString, QJsonArray> tasks;  // by environment
  int next = 0;
  QVariantMap draft;  // the scenario's new task, before it is saved
};

QString environmentOf(const FakeNode& node, const FakeNode::Rpc& rpc) {
  return rpc.environment.isEmpty() ? node.environmentId : rpc.environment;
}

// The node's own list to its watchers, as HalC2.ScheduledTasks broadcasts it.
void broadcast(FakeNode& node) {
  for (const int id : node.subscribers(QStringLiteral("scheduledTasks"))) {
    node.send({{QStringLiteral("t"), QStringLiteral("scheduledTasks")},
               {QStringLiteral("id"), id},
               {QStringLiteral("tasks"), node.part<FakeTasks>().tasks.value(node.environmentId)}});
  }
}

qsizetype indexOf(const QJsonArray& tasks, const QString& id) {
  for (qsizetype i = 0; i < tasks.size(); ++i) {
    if (tasks.at(i).toObject().value(QLatin1String("id")) == id) return i;
  }
  return -1;
}

void answer(FakeNode& node, const FakeNode::Rpc& rpc) {
    FakeTasks& fake = node.part<FakeTasks>();
    const QString environment = environmentOf(node, rpc);
    QJsonArray& tasks = fake.tasks[environment];
    const QString id = rpc.payload.value(QLatin1String("id")).toString();
    const qsizetype at = indexOf(tasks, id);
    if (rpc.method == QLatin1String("scheduledTasks.list")) {
      node.reply(rpc, QJsonObject{{QStringLiteral("tasks"), tasks}});
      return;
    }
    if (rpc.method == QLatin1String("scheduledTasks.upsert")) {
      QJsonObject task = rpc.payload;
      if (at < 0 && task.value(QLatin1String("requireExisting")).toBool()) {
        node.refuse(rpc, QStringLiteral("Schedule task not found."));
        return;
      }
      task.remove(QStringLiteral("requireExisting"));
      if (id.isEmpty()) task.insert(QStringLiteral("id"), QStringLiteral("task-%1").arg(++fake.next));
      task.insert(QStringLiteral("nextRunAt"), task.value(QLatin1String("enabled")).toBool() ? QJsonValue(QStringLiteral("2099-01-01T09:00:00.000Z"))
                                                                                             : QJsonValue(QJsonValue::Null));
      task.insert(QStringLiteral("lastRunStatus"), at < 0 ? QStringLiteral("never") : tasks.at(at).toObject().value(QLatin1String("lastRunStatus")).toString());
      if (at < 0) {
        tasks.append(task);
      } else {
        tasks.replace(at, task);
      }
      node.reply(rpc, task);
    } else if (at < 0) {
      node.refuse(rpc, QStringLiteral("Schedule task not found."));
      return;
    } else if (rpc.method == QLatin1String("scheduledTasks.delete")) {
      tasks.removeAt(at);
      node.reply(rpc, QJsonObject{});
    } else if (rpc.method == QLatin1String("scheduledTasks.setEnabled")) {
      QJsonObject task = tasks.at(at).toObject();
      task.insert(QStringLiteral("enabled"), rpc.payload.value(QLatin1String("enabled")));
      tasks.replace(at, task);
      node.reply(rpc, task);
    } else {
      node.reply(rpc, QJsonObject{});
    }
    if (environment == node.environmentId) broadcast(node);
}

const FakeNode::Extension scheduled([](FakeNode& node) {
  node.onShape(QStringLiteral("scheduledTasks"), [&node](int id, const QJsonObject&) {
    node.send({{QStringLiteral("t"), QStringLiteral("scheduledTasks")},
               {QStringLiteral("id"), id},
               {QStringLiteral("tasks"), node.part<FakeTasks>().tasks.value(node.environmentId)}});
  });
  node.onRpc(QStringLiteral("scheduledTasks."), [&node](const FakeNode::Rpc& rpc) {
    // A held save is answered once released, late.
    if (node.holding(QStringLiteral("scheduledTasks")) && rpc.method == QLatin1String("scheduledTasks.upsert")) {
      node.defer([&node, rpc] { answer(node, rpc); });
      return;
    }
    answer(node, rpc);
  });
});

QJsonObject task(const QString& id, const QString& title, const QString& projectId, const QJsonObject& fields = {}) {
  QJsonObject result{{QStringLiteral("id"), id},
                     {QStringLiteral("title"), title},
                     {QStringLiteral("prompt"), QStringLiteral("Look at ") + title},
                     {QStringLiteral("enabled"), true},
                     {QStringLiteral("schedule"), QJsonObject{{QStringLiteral("type"), QStringLiteral("fixed_time")}, {QStringLiteral("timeOfDay"), QStringLiteral("09:00")}}},
                     {QStringLiteral("projectId"), projectId},
                     {QStringLiteral("threadId"), QJsonValue::Null},
                     {QStringLiteral("workspaceStrategy"), QJsonObject{{QStringLiteral("type"), QStringLiteral("root")}}},
                     {QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("codex-model")}}},
                     {QStringLiteral("runtimeMode"), QStringLiteral("full-access")},
                     {QStringLiteral("interactionMode"), QStringLiteral("default")},
                     {QStringLiteral("nextRunAt"), QStringLiteral("2099-01-01T09:00:00.000Z")},
                     {QStringLiteral("lastRunStatus"), QStringLiteral("succeeded")}};
  for (auto it = fields.begin(); it != fields.end(); ++it) result.insert(it.key(), it.value());
  return result;
}

void seed(World& world, const QJsonObject& task) {
  world.node.part<FakeTasks>().tasks[world.node.environmentId].append(task);
}

QJsonArray stored(World& world) {
  return world.node.part<FakeTasks>().tasks.value(world.node.environmentId);
}

QJsonObject provider(const QString& instanceId, const QString& name, const QStringList& models) {
  QJsonArray list;
  for (const QString& model : models) list.append(QJsonObject{{QStringLiteral("slug"), model}, {QStringLiteral("name"), model}});
  return {{QStringLiteral("instanceId"), instanceId},
          {QStringLiteral("driver"), instanceId},
          {QStringLiteral("displayName"), name},
          {QStringLiteral("enabled"), true},
          {QStringLiteral("installed"), true},
          {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), QStringLiteral("authenticated")}}},
          {QStringLiteral("models"), list}};
}

// Codex and Claude on this machine, and "api" defaulting to Claude's model.
void providersHere(World& world) {
  FakeConfig& fake = fakeConfig(world.node);
  fake.config.insert(QStringLiteral("providers"), QJsonArray{provider(QStringLiteral("codex"), QStringLiteral("Codex"), {QStringLiteral("codex-model")}),
                                                             provider(QStringLiteral("claude"), QStringLiteral("Claude"), {QStringLiteral("claude-model")})});
  QJsonObject& api = world.node.projects[QStringLiteral("api")];
  api.insert(QStringLiteral("defaultModelSelection"),
             QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("claude")}, {QStringLiteral("model"), QStringLiteral("claude-model")}});
}

QVariantMap section(World& world) {
  return world.state(QStringLiteral("scheduledTasks")).toMap();
}

QVariantMap scope(World& world) {
  return world.state(QStringLiteral("settingsScope")).toMap();
}

QVariantMap editor(World& world) {
  return section(world).value(QStringLiteral("editor")).toMap();
}

void openTasks(World& world) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  world.native().controller<NavigationController>()->open(NavigationController::Route::settings(QStringLiteral("/settings/scheduled-tasks")));
  world.waitFor([&] { return section(world).value(QStringLiteral("open")).toBool() && !scope(world).isEmpty(); },
                [&] { return QStringLiteral("scheduled tasks to show; they are %1").arg(show(section(world))); });
}

// This machine's listing, once loaded.
QVariantMap environment(World& world, const QString& id) {
  for (const QVariant& row : section(world).value(QStringLiteral("environments")).toList()) {
    if (row.toMap().value(QStringLiteral("id")) == id) return row.toMap();
  }
  return {};
}

QVariantMap ready(World& world) {
  world.waitFor([&] { return environment(world, world.node.environmentId).value(QStringLiteral("status")) == QLatin1String("ready"); },
                [&] { return QStringLiteral("this machine's tasks to load; they are %1").arg(show(section(world))); });
  return environment(world, world.node.environmentId);
}

QVariantMap row(World& world, const QString& title) {
  for (const QVariant& task : ready(world).value(QStringLiteral("tasks")).toList()) {
    if (task.toMap().value(QStringLiteral("title")) == title) return task.toMap();
  }
  return {};
}

QString choose(World& world, const QString& list, const QString& label) {
  QString id;
  world.waitFor([&] {
    for (const QVariant& entry : scope(world).value(list).toList()) {
      if (entry.toMap().value(QStringLiteral("label")) == label || entry.toMap().value(QStringLiteral("title")) == label) {
        id = entry.toMap().value(list == QLatin1String("projects") ? QStringLiteral("key") : QStringLiteral("id")).toString();
      }
    }
    return !id.isEmpty();
  }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(label, show(scope(world))); });
  return id;
}

// A new task's editor, its draft filled in and changed by `change`.
QVariantMap newDraft(World& world, const QVariantMap& change = {}) {
  openTasks(world);
  ready(world);
  world.bridge().dispatch(QStringLiteral("scheduledTasks.new"), QVariant());
  world.waitFor([&] { return !editor(world).isEmpty(); }, [&] { return QStringLiteral("the editor to open; the section is %1").arg(show(section(world))); });
  QVariantMap draft = editor(world).value(QStringLiteral("draft")).toMap();
  draft.insert(QStringLiteral("title"), QStringLiteral("Check Sentry"));
  draft.insert(QStringLiteral("prompt"), QStringLiteral("Look at the new Sentry issues."));
  for (auto it = change.begin(); it != change.end(); ++it) draft.insert(it.key(), it.value());
  return draft;
}

void save(World& world, const QVariantMap& draft) {
  world.bridge().dispatch(QStringLiteral("scheduledTasks.save"), QVariantMap{{QStringLiteral("draft"), draft}});
}

QJsonObject savedTask(World& world) {
  world.waitFor([&] { return !stored(world).isEmpty() && editor(world).isEmpty(); },
                [&] { return QStringLiteral("the task to be saved; the section is %1").arg(show(section(world))); });
  return stored(world).last().toObject();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user starts a new task"), [](World& world, const Captures&, const Table&) {
    providersHere(world);
    const QVariantMap draft = newDraft(world);
    world.node.part<FakeTasks>().draft = draft;
  });
  step(QStringLiteral("it starts in a new worktree from %1 fetched from origin").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap draft = world.node.part<FakeTasks>().draft;
    expect(draft.value(QStringLiteral("workspaceMode")) == QLatin1String("worktree") && draft.value(QStringLiteral("baseRef")) == c[0] &&
               draft.value(QStringLiteral("startFromOrigin")).toBool(),
           QStringLiteral("a new worktree from %1; the draft is %2").arg(c[0], show(draft)));
  });
  step(QStringLiteral("it runs at 09:00 every day with full access"), [](World& world, const Captures&, const Table&) {
    save(world, world.node.part<FakeTasks>().draft);
    const QJsonObject task = savedTask(world);
    const QJsonObject schedule = task.value(QLatin1String("schedule")).toObject();
    expect(schedule.value(QLatin1String("type")) == QLatin1String("fixed_time") && schedule.value(QLatin1String("timeOfDay")) == QLatin1String("09:00") &&
               !schedule.contains(QLatin1String("weekdays")) && task.value(QLatin1String("runtimeMode")) == QLatin1String("full-access"),
           QStringLiteral("09:00 every day with full access; the task is %1").arg(show(task.toVariantMap())));
  });
  step(QStringLiteral("its model is the project's default model"), [](World& world, const Captures&, const Table&) {
    const QJsonObject selection = savedTask(world).value(QLatin1String("modelSelection")).toObject();
    expect(selection.value(QLatin1String("instanceId")) == QLatin1String("claude") && selection.value(QLatin1String("model")) == QLatin1String("claude-model"),
           QStringLiteral("api's Claude model; the task runs %1").arg(show(selection.toVariantMap())));
  });

  step(QStringLiteral("the user creates a task that uses (a new worktree|the project checkout|a specific checkout)"),
       [](World& world, const Captures& c, const Table&) {
         providersHere(world);
         const QString mode = c[0] == QLatin1String("a new worktree")         ? QStringLiteral("worktree")
                              : c[0] == QLatin1String("the project checkout") ? QStringLiteral("root")
                                                                               : QStringLiteral("existing_worktree");
         save(world, newDraft(world, {{QStringLiteral("workspaceMode"), mode}, {QStringLiteral("checkoutPath"), QStringLiteral("/work/api-review")}}));
       });
  step(QStringLiteral("each run works in (a fresh worktree from the base|the project root|the chosen checkout path)"),
       [](World& world, const Captures& c, const Table&) {
         const QJsonObject workspace = savedTask(world).value(QLatin1String("workspaceStrategy")).toObject();
         const QJsonObject expected = c[0] == QLatin1String("the project root")
                                          ? QJsonObject{{QStringLiteral("type"), QStringLiteral("root")}}
                                      : c[0] == QLatin1String("the chosen checkout path")
                                          ? QJsonObject{{QStringLiteral("type"), QStringLiteral("existing_worktree")}, {QStringLiteral("worktreePath"), QStringLiteral("/work/api-review")}}
                                          : QJsonObject{{QStringLiteral("type"), QStringLiteral("worktree")}, {QStringLiteral("baseRef"), QStringLiteral("main")}, {QStringLiteral("startFromOrigin"), true}};
         expect(workspace == expected, QStringLiteral("the workspace is %1").arg(show(workspace.toVariantMap())));
       });

  step(QStringLiteral("the user saves a task (without a prompt|that runs every 0 minutes|that uses a specific checkout with no path)"),
       [](World& world, const Captures& c, const Table&) {
         providersHere(world);
         QVariantMap change;
         if (c[0] == QLatin1String("without a prompt")) {
           change = {{QStringLiteral("prompt"), QStringLiteral("  ")}};
         } else if (c[0] == QLatin1String("that runs every 0 minutes")) {
           change = {{QStringLiteral("scheduleMode"), QStringLiteral("interval")}, {QStringLiteral("intervalMinutes"), QStringLiteral("0")}};
         } else {
           change = {{QStringLiteral("workspaceMode"), QStringLiteral("existing_worktree")}, {QStringLiteral("checkoutPath"), QString()}};
         }
         save(world, newDraft(world, change));
         world.sync();
         expect(stored(world).isEmpty(), QStringLiteral("nothing to be saved"));
       });
  step(QStringLiteral("the user saves a task on an environment that is disconnected"), [](World& world, const Captures&, const Table&) {
    // The editor is open on another machine when its link drops.
    const QString laptop = QStringLiteral("Laptop");
    fakeConfig(world.node).elsewhere.insert(laptop, QJsonObject{});
    documentOf(world.node, laptop);
    world.node.linkLabels.insert(laptop, laptop);
    world.node.link(laptop);
    openTasks(world);
    world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), choose(world, QStringLiteral("environments"), laptop)}});
    world.waitFor([&] { return environment(world, laptop).value(QStringLiteral("status")) == QLatin1String("ready"); },
                  [&] { return QStringLiteral("Laptop's tasks to load; the section is %1").arg(show(section(world))); });
    world.bridge().dispatch(QStringLiteral("scheduledTasks.new"), QVariant());
    world.waitFor([&] { return editor(world).value(QStringLiteral("connected")).toBool(); },
                  [&] { return QStringLiteral("the editor to open on Laptop; the section is %1").arg(show(section(world))); });
    QVariantMap draft = editor(world).value(QStringLiteral("draft")).toMap();
    draft.insert(QStringLiteral("title"), QStringLiteral("Check Sentry"));
    draft.insert(QStringLiteral("prompt"), QStringLiteral("Look at the new Sentry issues."));
    world.node.setLinkProblem(laptop, QStringLiteral("unreachable"));
    world.waitFor([&] { return !editor(world).value(QStringLiteral("connected")).toBool(); },
                  [&] { return QStringLiteral("the editor to see the disconnect; it is %1").arg(show(editor(world))); });
    save(world, draft);
  });

  step(QStringLiteral("a paused task and a task that failed its last run"), [](World& world, const Captures&, const Table&) {
    seed(world, task(QStringLiteral("paused"), QStringLiteral("Nightly build"), QStringLiteral("api"),
                     {{QStringLiteral("enabled"), false}, {QStringLiteral("nextRunAt"), QJsonValue::Null}}));
    seed(world, task(QStringLiteral("failed"), QStringLiteral("Check Sentry"), QStringLiteral("api"),
                     {{QStringLiteral("lastRunStatus"), QStringLiteral("failed")}, {QStringLiteral("lastRunError"), QStringLiteral("The server stopped during this run.")}}));
  });
  step(QStringLiteral("the user opens scheduled tasks"), [](World& world, const Captures&, const Table&) {
    openTasks(world);
  });
  step(QStringLiteral("the paused task says it is paused"), [](World& world, const Captures&, const Table&) {
    const QVariantMap paused = row(world, QStringLiteral("Nightly build"));
    expect(paused.value(QStringLiteral("when")) == QLatin1String("Paused") && !paused.value(QStringLiteral("enabled")).toBool(),
           QStringLiteral("the paused task is %1").arg(show(paused)));
    expect(row(world, QStringLiteral("Check Sentry")).value(QStringLiteral("when")).toString().startsWith(QLatin1String("Next run in")),
           QStringLiteral("the other to say when it runs next; it is %1").arg(show(row(world, QStringLiteral("Check Sentry")))));
  });
  step(QStringLiteral("the failed task shows its last error"), [](World& world, const Captures&, const Table&) {
    const QVariantMap failed = row(world, QStringLiteral("Check Sentry"));
    expect(failed.value(QStringLiteral("lastRunStatus")) == QLatin1String("failed") &&
               failed.value(QStringLiteral("lastRunError")) == QLatin1String("The server stopped during this run."),
           QStringLiteral("the failed task is %1").arg(show(failed)));
  });

  step(QStringLiteral("tasks in projects %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& project : {c[0], c[1]}) {
      world.node.projects.insert(project, QJsonObject{{QStringLiteral("id"), project},
                                                      {QStringLiteral("title"), project},
                                                      {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project},
                                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                      {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                      {QStringLiteral("scripts"), QJsonArray()}});
      seed(world, task(project + QStringLiteral("-task"), project + QStringLiteral(" review"), project));
    }
  });
  step(QStringLiteral("the user views scheduled tasks for project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openTasks(world);
    world.bridge().dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), choose(world, QStringLiteral("projects"), c[0])}});
    world.waitFor([&] { return scope(world).value(QStringLiteral("projectLabel")) == c[0]; },
                  [&] { return QStringLiteral("the scope to be %1; it is %2").arg(c[0], show(scope(world))); });
  });
  step(QStringLiteral("only the tasks for %1 are listed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantList tasks = ready(world).value(QStringLiteral("tasks")).toList();
      return tasks.size() == 1 && tasks.first().toMap().value(QStringLiteral("title")) == c[0] + QStringLiteral(" review");
    }, [&] { return QStringLiteral("only %1's task; the section is %2").arg(c[0], show(section(world))); });
  });

  step(QStringLiteral("a task %1").arg(q), [](World& world, const Captures& c, const Table&) {
    seed(world, task(QStringLiteral("task-sentry"), c[0], QStringLiteral("api")));
  });
  step(QStringLiteral("the user deletes the task"), [](World& world, const Captures&, const Table&) {
    openTasks(world);
    world.waitFor([&] { return !ready(world).value(QStringLiteral("tasks")).toList().isEmpty(); },
                  [&] { return QStringLiteral("the task to be listed; the section is %1").arg(show(section(world))); });
    world.bridge().dispatch(QStringLiteral("scheduledTasks.delete"),
                            QVariantMap{{QStringLiteral("environmentId"), world.node.environmentId}, {QStringLiteral("id"), QStringLiteral("task-sentry")}});
  });
  step(QStringLiteral("it no longer runs and is no longer listed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return stored(world).isEmpty() && ready(world).value(QStringLiteral("tasks")).toList().isEmpty(); },
                  [&] { return QStringLiteral("the task to be gone; the section is %1").arg(show(section(world))); });
  });

  step(QStringLiteral("the user follows a link to a task that was deleted"), [](World& world, const Captures&, const Table&) {
    world.connect();
    world.sync();
    world.bridge().dispatch(QStringLiteral("scheduledTasks.open"),
                            QVariantMap{{QStringLiteral("environmentId"), world.node.environmentId}, {QStringLiteral("taskId"), QStringLiteral("task-gone")}});
  });
  step(QStringLiteral("the user is told the task is unavailable"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return ready(world).value(QStringLiteral("linkMissing")).toBool(); },
                  [&] { return QStringLiteral("the link to be missing; the section is %1").arg(show(section(world))); });
    expect(editor(world).isEmpty(), QStringLiteral("no editor to open"));
  });

  step(QStringLiteral("the environment %1 is disconnected").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeConfig(world.node).elsewhere.insert(c[0], QJsonObject{});
    documentOf(world.node, c[0]);
    world.node.linkLabels.insert(c[0], c[0]);
    world.node.link(c[0]);
    world.node.setLinkProblem(c[0], QStringLiteral("unreachable"));
  });
  step(QStringLiteral("the user opens scheduled tasks for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openTasks(world);
    world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), choose(world, QStringLiteral("environments"), c[0])}});
  });
  step(QStringLiteral("the user is offered to reconnect %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap shown = environment(world, c[0]);
      return shown.value(QStringLiteral("status")) == QLatin1String("disconnected") &&
             shown.value(QStringLiteral("message")) == QStringLiteral("Reconnect %1 to view its scheduled tasks.").arg(c[0]);
    }, [&] { return QStringLiteral("%1 to be offered a reconnect; the section is %2").arg(c[0], show(section(world))); });
  });

  // A save answered after the page was left and a new editor opened.
  step(QStringLiteral("the user saves a task and starts another before the save is answered"), [](World& world, const Captures&, const Table&) {
    providersHere(world);
    world.node.hold(QStringLiteral("scheduledTasks"));
    save(world, newDraft(world));
    world.waitFor([&] { return editor(world).value(QStringLiteral("saving")).toBool(); },
                  [&] { return QStringLiteral("the save to be sent; the editor is %1").arg(show(editor(world))); });
    auto* navigation = world.native().controller<NavigationController>();
    navigation->open(NavigationController::Route::settings(QStringLiteral("/settings/general")));
    world.waitFor([&] { return !section(world).value(QStringLiteral("open")).toBool(); }, QStringLiteral("the section to close"));
    openTasks(world);
    world.bridge().dispatch(QStringLiteral("scheduledTasks.new"), QVariant());
    world.waitFor([&] { return !editor(world).isEmpty() && !editor(world).value(QStringLiteral("saving")).toBool(); },
                  [&] { return QStringLiteral("a new editor to open; the section is %1").arg(show(section(world))); });
    world.node.part<FakeTasks>().draft = editor(world);
    world.node.answerHeld();
  });
  step(QStringLiteral("the first task is saved and the new task stays open"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return stored(world).size() == 1 && ready(world).value(QStringLiteral("tasks")).toList().size() == 1; },
                  [&] { return QStringLiteral("the first task to be listed; the section is %1").arg(show(section(world))); });
    world.sync();
    const QVariantMap opened = world.node.part<FakeTasks>().draft;
    expect(!editor(world).isEmpty() && editor(world).value(QStringLiteral("seq")) == opened.value(QStringLiteral("seq")) &&
               !editor(world).value(QStringLiteral("editing")).toBool() && !editor(world).value(QStringLiteral("saving")).toBool(),
           QStringLiteral("the new task's editor to stay open; the section is %1").arg(show(section(world))));
  });
});

}  // namespace
