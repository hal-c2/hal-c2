// Forking from a response, a thread's relatives and merging a fork back
// (features/threads/fork-and-lineage.feature): ThreadLineageController over
// the shell's rows (`lineage`, `forkedFrom`). The MC makes the fork
// (HalC2.Orchestration.Fork): its row follows an accepted `thread.fork`.

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "NavigationController.h"
#include "Stream.h"
#include "ThreadLineageController.h"
#include "ThreadList.h"
#include "World.h"

namespace {

const QString kParent = QStringLiteral("t-plan");
const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");

struct Forks {
  // The MC makes the fork but its row does not reach the shell.
  bool withhold = false;
};

QJsonObject forkRow(const QString& id, const QString& title, const QString& project, const QString& parent, const QString& run) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), project},
          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:30:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:30:00Z")},
          {QStringLiteral("lineage"), QJsonObject{{QStringLiteral("parentThreadId"), parent}, {QStringLiteral("relationshipToParent"), QStringLiteral("fork")},
                                                  {QStringLiteral("rootThreadId"), parent}}},
          {QStringLiteral("forkedFrom"), QJsonObject{{QStringLiteral("type"), QStringLiteral("run")}, {QStringLiteral("threadId"), parent}, {QStringLiteral("runId"), run}}}};
}

const FakeMc::Extension forks([](FakeMc& mc) {
  mc.effects.append([&mc](const QJsonObject& command) {
    if (command.value(QLatin1String("type")) != QLatin1String("thread.fork")) return;
    const QString source = command.value(QLatin1String("sourceThreadId")).toString();
    const QString target = command.value(QLatin1String("targetThreadId")).toString();
    const QJsonObject parent = mc.threads.value(source);
    const QString title = command.value(QLatin1String("title")).toString(parent.value(QLatin1String("title")).toString() + QStringLiteral(" fork"));
    const QJsonObject row = forkRow(target, title, parent.value(QLatin1String("projectId")).toString(), source,
                                    command.value(QLatin1String("sourcePoint")).toObject().value(QLatin1String("runId")).toString());
    mc.threads.insert(target, row);
    if (!mc.part<Forks>().withhold) mc.sendRow(target, row);
  });
});

QString idOf(const QString& key) {
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

// A fork of the Background's thread; "Try Stripe" is the one the feature takes for granted.
void addFork(World& world, const QString& title) {
  const QString id = QStringLiteral("t-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
  if (world.mc.threads.contains(id)) return;
  const QJsonObject row = forkRow(id, title, world.mc.threads.value(kParent).value(QLatin1String("projectId")).toString(), kParent, QStringLiteral("run-1"));
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
}

const int registered = (provideThread(QStringLiteral("Try Stripe"), [](World& world) { addFork(world, QStringLiteral("Try Stripe")); }), 0);

void view(World& world, const QString& title) {
  const QString key = threadKeyOf(world, title);
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the window to show %1").arg(key); });
  world.sync();
}

QVariantMap lineage(World& world) {
  return world.state(QStringLiteral("lineage")).toMap();
}

// The assistant's latest reply in the open thread, forked from as its "Fork from this response" does.
void forkFromLatestResponse(World& world) {
  TimelineModel& model = stream::timeline(world);
  QString run;
  for (int row = model.rowCount() - 1; row >= 0 && run.isEmpty(); --row) {
    run = model.finishedRunOf(stream::role(model, row, TimelineModel::IdRole).toString());
  }
  expect(!run.isEmpty(), QStringLiteral("no finished response to fork from; %1").arg(stream::describe(model)));
  world.bridge().dispatch(QStringLiteral("thread.forkFromRun"), QVariantMap{{QStringLiteral("runId"), run}});
}

std::optional<QVariantMap> toastTitled(World& world, const QString& title) {
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    if (item.toMap().value(QStringLiteral("title")) == title) return item.toMap();
  }
  return std::nullopt;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a connected environment with the thread %1 whose last agent run finished").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(QStringLiteral("shop"), {{QStringLiteral("id"), QStringLiteral("shop")}, {QStringLiteral("title"), QStringLiteral("shop")},
                                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.threads.insert(kParent, {{QStringLiteral("id"), kParent}, {QStringLiteral("title"), c[0]}, {QStringLiteral("projectId"), QStringLiteral("shop")},
                                      {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt}, {QStringLiteral("latestRunId"), QStringLiteral("run-1")},
                                      {QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("latestRunCompletedAt"), kAt}});
    world.connect();
    world.sync();
    stream::FakeStreams& streams = world.mc.part<stream::FakeStreams>();
    streams.thread = kParent;
    streams.environment = world.mc.environmentId;
    stream::startRun(world, 600);
    stream::addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Stripe and Paddle both fit.")}});
    stream::settleRun(world, QStringLiteral("completed"), 60);
    stream::look(world, world.mc.environmentId + QLatin1Char(':') + kParent);
    // The row the fake projects commands onto is this MC's.
    projectThreadCommands(world);
  });

  // Forking from a response.
  step(QStringLiteral("the user forks %1 from (?:the agent's latest|a) response").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.native().controller<NavigationController>()->threadKey() == threadKeyOf(world, c[0]), QStringLiteral("%1 is not open").arg(c[0]));
    forkFromLatestResponse(world);
  });
  step(QStringLiteral("the environment rejects the fork"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("thread.fork"), QStringLiteral("Only finished runs can be used."));
  });
  step(QStringLiteral("the fork was created but its thread has not reached this client"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Forks>().withhold = true;
    world.native().controller<ThreadLineageController>()->setArrivalTimeout(50);
  });
  step(QStringLiteral("the user is told to reconnect and open the fork from the thread list"), [](World& world, const Captures&, const Table&) {
    const QString title = QStringLiteral("The fork was created, but it did not reach this client");
    world.waitFor([&] { return toastTitled(world, title).has_value(); },
                  [&] { return QStringLiteral("the notice; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
    expect(toastTitled(world, title)->value(QStringLiteral("description")) == QLatin1String("Reconnect and try opening it from the thread list."),
           QStringLiteral("the notice is %1").arg(show(*toastTitled(world, title))));
    // The MC did make the fork; the window stayed where it was.
    expect(world.mc.threads.size() == 2 && world.native().controller<NavigationController>()->threadKey() == world.mc.environmentId + QLatin1Char(':') + kParent,
           QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
  });

  // Relatives.
  step(QStringLiteral("%1 and %1 are forks of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addFork(world, c[0]);
    addFork(world, c[1]);
    // One of them is at work.
    updateThreadRow(world, idOf(threadKeyOf(world, c[1])), [](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("status"), QStringLiteral("running"));
    });
  });
  step(QStringLiteral("the user looks at (?:the relatives of|merging) %1(?: back)?").arg(q), [](World& world, const Captures& c, const Table&) { view(world, c[0]); });
  step(QStringLiteral("both forks are listed with how many are running"), [](World& world, const Captures&, const Table&) {
    QStringList titles;
    for (const QVariant& fork : lineage(world).value(QStringLiteral("forks")).toList()) titles.append(fork.toMap().value(QStringLiteral("title")).toString());
    titles.sort();
    expect(titles == QStringList{QStringLiteral("Try Paddle"), QStringLiteral("Try Stripe")} && lineage(world).value(QStringLiteral("title")) == QStringLiteral("Lineage · 1 running"),
           QStringLiteral("the lineage is %1").arg(show(lineage(world))));
  });
  step(QStringLiteral("the user opens its parent thread"), [](World& world, const Captures&, const Table&) {
    const QVariantMap parent = lineage(world).value(QStringLiteral("parent")).toMap();
    expect(!parent.isEmpty() && !parent.value(QStringLiteral("missing")).toBool(), QStringLiteral("the lineage is %1").arg(show(lineage(world))));
    world.bridge().dispatch(QStringLiteral("lineage.open"), QVariantMap{{QStringLiteral("key"), parent.value(QStringLiteral("key"))}});
  });
  step(QStringLiteral("the parent of %1 was deleted").arg(q), [](World& world, const Captures& c, const Table&) {
    threadKeyOf(world, c[0]);  // the fork exists
    view(world, c[0]);
    QJsonObject gone = world.mc.threads.take(kParent);
    gone.insert(QStringLiteral("deletedAt"), QStringLiteral("2026-09-23T09:45:00Z"));
    world.mc.sendRow(kParent, gone);
    world.sync();
  });
  step(QStringLiteral("the parent is shown as unavailable"), [](World& world, const Captures&, const Table&) {
    const QVariantMap parent = lineage(world).value(QStringLiteral("parent")).toMap();
    expect(parent.value(QStringLiteral("missing")).toBool() && parent.value(QStringLiteral("title")) == QLatin1String("This related thread is unavailable"),
           QStringLiteral("the lineage is %1").arg(show(lineage(world))));
    // It cannot be opened.
    const QString before = world.native().controller<NavigationController>()->threadKey();
    world.bridge().dispatch(QStringLiteral("lineage.open"), QVariantMap{{QStringLiteral("key"), parent.value(QStringLiteral("key"))}});
    expect(world.native().controller<NavigationController>()->threadKey() == before, QStringLiteral("the missing parent opened"));
  });

  // Merging back.
  step(QStringLiteral("%1 has (no|a) finished run").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(threadKeyOf(world, c[0]));
    if (c[1] == QLatin1String("no")) return;
    updateThreadRow(world, id, [](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-fork"));
      row.insert(QStringLiteral("status"), QStringLiteral("completed"));
      row.insert(QStringLiteral("latestRunCompletedAt"), QStringLiteral("2026-09-23T09:50:00Z"));
    });
  });
  step(QStringLiteral("merging is unavailable until a run in the fork completes"), [](World& world, const Captures&, const Table&) {
    expect(!lineage(world).value(QStringLiteral("canMerge")).toBool() &&
               lineage(world).value(QStringLiteral("mergeHint")) == QLatin1String("Complete a run in this fork before merging it back"),
           QStringLiteral("the lineage is %1").arg(show(lineage(world))));
    const qsizetype before = world.mc.commands.size();
    world.bridge().dispatch(QStringLiteral("lineage.mergeBack"), QVariantMap());
    world.sync();
    expect(world.mc.commands.size() == before, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the user merges %1 back into %1").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, c[0]);
    expect(lineage(world).value(QStringLiteral("canMerge")).toBool() &&
               lineage(world).value(QStringLiteral("mergeHint")) == QStringLiteral("Merge this conversation back into ") + c[1],
           QStringLiteral("the lineage is %1").arg(show(lineage(world))));
    world.bridge().dispatch(QStringLiteral("lineage.mergeBack"), QVariantMap());
    world.sync();
    bool merged = false;
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      merged |= command.value(QLatin1String("type")) == QLatin1String("thread.merge_back") &&
                command.value(QLatin1String("sourceThreadId")) == idOf(threadKeyOf(world, c[0])) && command.value(QLatin1String("targetThreadId")) == kParent &&
                command.value(QLatin1String("sourcePoint")).toObject().value(QLatin1String("runId")) == QLatin1String("run-fork");
    }
    expect(merged, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  // Where a fork came from.
  step(QStringLiteral("the user reads the start of the conversation"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("it says the thread was forked from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // ThreadLineage.qml reads "Forked from <title>" over the conversation.
    const QVariantMap parent = lineage(world).value(QStringLiteral("parent")).toMap();
    expect(parent.value(QStringLiteral("title")) == c[0] && !parent.value(QStringLiteral("missing")).toBool(), QStringLiteral("the lineage is %1").arg(show(lineage(world))));
  });
  step(QStringLiteral("the user can open the source conversation from there"), [](World& world, const Captures&, const Table&) {
    const QString parent = lineage(world).value(QStringLiteral("parent")).toMap().value(QStringLiteral("key")).toString();
    world.bridge().dispatch(QStringLiteral("lineage.open"), QVariantMap{{QStringLiteral("key"), parent}});
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == parent; },
                  [&] { return QStringLiteral("the source to open; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  });
});

}  // namespace
