// Starting threads (features/threads/creating.feature): the model a new
// thread starts with, background starts that leave the draft ready for the
// next one, one prompt sent to several models, and a draft moved to another
// project.

#include <QJsonArray>
#include <QJsonObject>
#include <QSet>

#include "DraftController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Launch.h"
#include "NavigationController.h"
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
    choose(world, "composer.model.toggle", c[1]);
    choose(world, "composer.model.toggle", c[2]);
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
    choose(world, "composer.model.toggle", QStringLiteral("GPT-5"));
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
  });
  step(QStringLiteral("the user moves the draft to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startDraft(world);
    type(world, QStringLiteral("Sketch the endpoint"));
    const auto before = world.native().controller<DraftController>()->draft(world.draftId);
    expect(before && before->environmentId == world.mc.environmentId, QStringLiteral("the draft is not this machine's"));
    world.bridge().dispatch(QStringLiteral("draft.project"), QVariantMap{{QStringLiteral("draftId"), world.draftId}, {QStringLiteral("projectKey"), world.projectKey(c[0])}});
  });
  step(QStringLiteral("the draft targets the environment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto draft = world.native().controller<DraftController>()->draft(world.draftId);
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
});

}  // namespace
