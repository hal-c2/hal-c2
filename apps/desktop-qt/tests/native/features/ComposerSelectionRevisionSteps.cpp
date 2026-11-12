// What the composer shows is what runs: a pick is made against the thread's
// selection revision, a send without one names no model, a stale one is
// refused and comes back, and a draft starts on its project's MC's defaults
// (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include "ComposerController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Launches.h"
#include "SettingsController.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

using S = QString;

// A change the MC has taken that this client has not been sent yet.
struct Unheard {
  bool pending = false;
};

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

QString ownKey(World& world) {
  return world.mc.environmentId + QLatin1Char(':') + kThread;
}

QString peerKey() {
  return kPeerEnvironment + QLatin1Char(':') + kPeerThread;
}

// The catalogue of the Background: Codex's models, and Claude's.
QString instanceFor(const QString& model) {
  return model.startsWith(QLatin1String("claude")) ? S("claudeAgent") : S("codex");
}

QJsonObject selection(const QString& instanceId, const QString& model) {
  return {{S("instanceId"), instanceId}, {S("model"), model}};
}

QJsonArray providers(World& world) {
  return fakeConfig(world.mc).config.value(QLatin1String("providers")).toArray();
}

void offer(World& world, const QJsonArray& list) {
  publishProviders(world.mc, list);
  world.sync();
}

// The thread's row as the MC has it: a change to what it runs on moves its
// revision on, when it keeps one.
void change(World& world, const QJsonObject& fields, bool heard = true) {
  QJsonObject& row = world.mc.threads[kThread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  if (row.contains(S("selectionRevision"))) row.insert(S("selectionRevision"), row.value(S("selectionRevision")).toInt() + 1);
  world.mc.part<Unheard>().pending = !heard;
  if (!heard) return;
  world.mc.sendRow(kThread, row);
  world.sync();
}

void expectOn(World& world, const QString& instanceId, const QString& model) {
  world.waitFor([&] { return composer(world).value(S("selectedInstanceId")) == instanceId && composer(world).value(S("selectedModel")) == model; },
                [&] { return S("the composer on %1 of %2; it shows %3").arg(model, instanceId, show(composer(world))); });
}

void pick(World& world, const QString& model) {
  world.bridge().dispatch(S("composer.model.select"), QVariantMap{{S("instanceId"), instanceFor(model)}, {S("model"), model}});
  expectOn(world, instanceFor(model), model);
}

// The runtime mode a label of the composer's access picker names.
QString modeOf(World& world, const QString& label) {
  for (const QVariant& entry : composer(world).value(S("runtimeModes")).toList()) {
    if (entry.toMap().value(S("label")).toString().compare(label, Qt::CaseInsensitive) == 0) return entry.toMap().value(S("value")).toString();
  }
  fail(S("the composer offers %1").arg(show(composer(world).value(S("runtimeModes")))));
  return {};
}

QList<QJsonObject> commandsOf(World& world, const QString& type) {
  QList<QJsonObject> found;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == type) found.append(command);
  }
  return found;
}

qsizetype indexOf(World& world, const std::function<bool(const QJsonObject&)>& match) {
  for (qsizetype i = 0; i < world.mc.commands.size(); ++i) {
    if (match(world.mc.commands.at(i))) return i;
  }
  return -1;
}

QString modelOf(const QJsonObject& command) {
  return command.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("model")).toString();
}

// The user changes the open thread's access, and the MC takes it.
void changeAccess(World& world, const QString& label, const QString& threadId) {
  const QString mode = modeOf(world, label);
  const qsizetype before = world.mc.commands.size();
  world.bridge().dispatch(S("composer.runtimeMode.set"), QVariantMap{{S("mode"), mode}});
  world.waitFor([&] {
    for (qsizetype i = before; i < world.mc.commands.size(); ++i) {
      const QJsonObject& command = world.mc.commands.at(i);
      if (command.value(QLatin1String("type")) == QLatin1String("thread.runtime-mode.set") && command.value(QLatin1String("threadId")) == threadId) return true;
    }
    return false;
  }, [&] { return S("the access change; the MC has %1").arg(world.describeCommands()); });
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  // A thread on an MC that keeps a selection revision, Claude's Opus named as its catalogue names it.
  step(S("a thread runs on %1 here").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonArray list = providers(world);
    for (qsizetype i = 0; i < list.size(); ++i) {
      QJsonObject entry = list.at(i).toObject();
      QJsonArray models = entry.value(S("models")).toArray();
      for (qsizetype m = 0; m < models.size(); ++m) {
        QJsonObject model = models.at(m).toObject();
        if (model.value(S("slug")) == QLatin1String("claude-opus")) model.insert(S("name"), S("Opus"));
        models.replace(m, model);
      }
      entry.insert(S("models"), models);
      list.replace(i, entry);
    }
    offer(world, list);
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(S("modelSelection"), selection(instanceFor(c[0]), c[0]));
    row.insert(S("selectionRevision"), 1);
    world.mc.sendRow(kThread, row);
    world.sync();
    expectOn(world, instanceFor(c[0]), c[0]);
  });
  step(S("a thread runs on %1 on an MC that keeps no selection revision").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(S("modelSelection"), selection(instanceFor(c[0]), c[0]));
    row.remove(S("selectionRevision"));
    world.mc.sendRow(kThread, row);
    world.sync();
    expectOn(world, instanceFor(c[0]), c[0]);
  });
  step(S("the user picked %1 for its next turn").arg(q), [](World& world, const Captures& c, const Table&) { pick(world, c[0]); });
  step(S("another client has moved the thread to %1, which this client has not heard yet").arg(q), [](World& world, const Captures& c, const Table&) {
    change(world, {{S("modelSelection"), selection(instanceFor(c[0]), c[0])}}, false);
  });

  // A stale send.
  step(S("nothing is sent on the user's behalf and %1 stays in the prompt").arg(q), [](World& world, const Captures& c, const Table&) {
    auto* controller = world.native().controller<ComposerController>();
    world.waitFor([&] { return controller->draft(ownKey(world)) == c[0]; },
                  [&] { return S("the prompt back; it holds %1 and the MC has %2").arg(show(controller->draft(ownKey(world))), world.describeCommands()); });
    world.sync();
    expect(commandsOf(world, S("message.dispatch")).size() == 1 && commandsOf(world, S("thread.model-selection.set")).isEmpty() &&
               commandsOf(world, S("provider.switch")).isEmpty(),
           S("the client sent more than the one refused message: %1").arg(world.describeCommands()));
  });
  step(S("the composer shows %1 once the change arrives").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.part<Unheard>().pending, S("no change was waiting to arrive"));
    world.mc.part<Unheard>().pending = false;
    world.mc.sendRow(kThread, world.mc.threads.value(kThread));
    world.sync();
    expectOn(world, instanceFor(c[0]), c[0]);
  });

  // A send with no pick.
  step(S("the user sends %1 without picking a model").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(S("composer.submit"), QVariantMap{{S("text"), c[0]}, {S("intent"), S("foreground")}});
    world.waitFor([&] { return !commandsOf(world, S("message.dispatch")).isEmpty(); },
                  [&] { return S("the message; the MC has %1").arg(world.describeCommands()); });
  });
  step(S("the message names no model, so the turn runs on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject message = commandsOf(world, S("message.dispatch")).constLast();
    expect(!message.contains(S("modelSelection")) && !message.contains(S("selectionBase")) && commandsOf(world, S("provider.switch")).isEmpty() &&
               commandsOf(world, S("thread.model-selection.set")).isEmpty(),
           S("the send named a model: %1").arg(world.describeCommands()));
    expect(modelOf(world.mc.threads.value(kThread)) == c[0], S("the thread runs on %1").arg(modelOf(world.mc.threads.value(kThread))));
  });

  // An MC that keeps no revision.
  step(S("the thread is set to %1 before the message goes with that pick").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !commandsOf(world, S("message.dispatch")).isEmpty(); },
                  [&] { return S("the message; the MC has %1").arg(world.describeCommands()); });
    const qsizetype set = indexOf(world, [&](const QJsonObject& command) {
      return command.value(QLatin1String("type")) == QLatin1String("thread.model-selection.set") && modelOf(command) == c[0];
    });
    const qsizetype message = indexOf(world, [&](const QJsonObject& command) {
      return command.value(QLatin1String("type")) == QLatin1String("message.dispatch") && modelOf(command) == c[0];
    });
    expect(set >= 0 && message > set, S("the thread set to %1, then the message with it; the MC has %2").arg(c[0], world.describeCommands()));
  });
  step(S("the composer shows %1, the thread's own now").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return modelOf(world.mc.threads.value(kThread)) == c[0]; }, S("the thread to take the pick"));
    world.sync();
    expectOn(world, instanceFor(c[0]), c[0]);
  });
  step(S("a change made on another client after it replaces the pick"), [](World& world, const Captures&, const Table&) {
    change(world, {{S("modelSelection"), selection(S("claudeAgent"), S("claude-opus"))}});
    expectOn(world, S("claudeAgent"), S("claude-opus"));
  });

  // The user's own access change.
  step(S("the user changes the thread's access to (.+)"), [](World& world, const Captures& c, const Table&) {
    const QString mode = modeOf(world, c[0]);
    changeAccess(world, c[0], kThread);
    world.waitFor([&] { return world.mc.threads.value(kThread).value(S("runtimeMode")) == mode && composer(world).value(S("runtimeMode")) == mode; },
                  [&] { return S("the thread in %1; the composer shows %2").arg(mode, show(composer(world))); });
  });
  step(S("the composer still shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expectOn(world, instanceFor(c[0]), c[0]);
  });

  // A cluster: the first thread's MC keeps no revision, the second's does.
  step(S("one thread is on an MC that keeps no selection revision and another on one that does"), [](World& world, const Captures&, const Table&) {
    world.mc.join(kPeer, kPeerEnvironment);
    publishProvidersOn(world.mc, kPeerEnvironment, providers(world));
    world.mc.sendPeerRow(kPeerEnvironment, kPeerThread,
                         {{S("id"), kPeerThread}, {S("title"), S("Remote")}, {S("projectId"), kProject},
                          {S("createdAt"), S("2026-09-23T09:00:00Z")}, {S("updatedAt"), S("2026-09-23T09:00:00Z")},
                          {S("modelSelection"), selection(S("codex"), S("gpt-5"))}, {S("runtimeMode"), S("full-access")}, {S("selectionRevision"), 3}});
    world.sync();
  });
  step(S("the user changed the first thread's access to (.+)"), [](World& world, const Captures& c, const Table&) {
    look(world, ownKey(world));
    changeAccess(world, c[0], kThread);
  });
  step(S("the user picked %1 for the second thread's next turn").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    fake.thread = kPeerThread;
    fake.environment = kPeerEnvironment;
    look(world, peerKey());
    expectOn(world, S("codex"), S("gpt-5"));
    pick(world, c[0]);
  });
  // The peer's thread is not among the rows `appliesModes` moves: its answer names no revision.
  step(S("the second thread's MC answers an access change to it without moving the thread"), [](World& world, const Captures&, const Table&) {
    changeAccess(world, S("Supervised"), kPeerThread);
  });
  step(S("a change made on another client to the second thread replaces the pick"), [](World& world, const Captures&, const Table&) {
    world.mc.sendPeerRow(kPeerEnvironment, kPeerThread,
                         {{S("id"), kPeerThread}, {S("title"), S("Remote")}, {S("projectId"), kProject},
                          {S("createdAt"), S("2026-09-23T09:00:00Z")}, {S("updatedAt"), S("2026-09-23T09:01:00Z")},
                          {S("modelSelection"), selection(S("claudeAgent"), S("claude-opus"))}, {S("runtimeMode"), S("full-access")},
                          {S("selectionRevision"), 4}});
    world.sync();
    expectOn(world, S("claudeAgent"), S("claude-opus"));
  });

  // A thread whose account is off.
  step(S("a thread runs on %1 on the account %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonArray list = providers(world);
    for (const QString& name : {c[1], S("Codex Work")}) {
      list.append(QJsonObject{{S("instanceId"), name.toLower().replace(u' ', u'_')}, {S("driver"), S("codex")}, {S("displayName"), name},
                              {S("enabled"), true}, {S("installed"), true}, {S("status"), S("ready")},
                              {S("models"), QJsonArray{QJsonObject{{S("slug"), c[0]}, {S("name"), c[0]}}}}});
    }
    offer(world, list);
    change(world, {{S("modelSelection"), selection(c[1].toLower().replace(u' ', u'_'), c[0])}, {S("selectionRevision"), 1}});
  });
  step(S("the composer shows %1 on %1, which cannot run a turn now").arg(q), [](World& world, const Captures& c, const Table&) {
    expectOn(world, QString(c[1]).toLower().replace(u' ', u'_'), c[0]);
    world.waitFor([&] { return composer(world).value(S("sendDisabledReason")) == QLatin1String("Choose a model to send"); },
                  [&] { return S("the composer to ask for a pick; it shows %1").arg(show(composer(world))); });
  });
  step(S("a message is not sent until the user picks a model"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(S("composer.submit"), QVariantMap{{S("text"), S("Carry on")}, {S("intent"), S("foreground")}});
    world.sync();
    expect(commandsOf(world, S("message.dispatch")).isEmpty(), S("a message was sent: %1").arg(world.describeCommands()));
    world.bridge().dispatch(S("composer.model.select"), QVariantMap{{S("instanceId"), S("codex_work")}, {S("model"), S("gpt-5")}});
    expectOn(world, S("codex_work"), S("gpt-5"));
    world.bridge().dispatch(S("composer.submit"), QVariantMap{{S("text"), S("Carry on")}, {S("intent"), S("foreground")}});
    world.waitFor([&] { return !commandsOf(world, S("message.dispatch")).isEmpty(); },
                  [&] { return S("the message; the MC has %1").arg(world.describeCommands()); });
    const QJsonObject message = commandsOf(world, S("message.dispatch")).constLast();
    expect(message.value(S("modelSelection")).toObject().value(S("instanceId")) == QLatin1String("codex_work"),
           S("the message went with %1").arg(show(message.toVariantMap())));
  });

  // A new thread's defaults come from its project's MC.
  step(S("this machine starts new threads on %1 with full access").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().controller<SettingsController>()->ready(); }, S("the shell to read the settings"));
    saveElsewhere(world.mc, S("defaultModelSelection"), selection(instanceFor(c[0]), c[0]));
    saveElsewhere(world.mc, S("defaultRuntimeMode"), S("full-access"));
    world.sync();
  });
  step(S("the project's machine starts new threads there on %1 with (.+) access").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject row = world.mc.projects.value(kProject);
    row.insert(S("newThreadModelSelection"), selection(instanceFor(c[0]), c[0]));
    row.insert(S("newThreadRuntimeMode"), c[1] == QLatin1String("Supervised") ? S("approval-required") : S("full-access"));
    world.mc.projects.insert(kProject, row);
    world.mc.sendRows(world.mc.name, {QJsonValue(QJsonArray{kProject, S("project"), row})});
    world.sync();
  });
  step(S("the draft is on %1 with (.+) access").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return composer(world).value(S("target")) == world.draftId; },
                  [&] { return S("the composer on the new thread; it shows %1").arg(show(composer(world))); });
    const QString mode = modeOf(world, c[1]);
    expectOn(world, instanceFor(c[0]), c[0]);
    world.waitFor([&] { return composer(world).value(S("runtimeMode")) == mode; },
                  [&] { return S("the draft in %1; it shows %2").arg(mode, show(composer(world))); });
    // And it starts the thread on what it shows.
    world.bridge().dispatch(S("composer.submit"), QVariantMap{{S("text"), S("Add caching")}, {S("intent"), S("foreground")}});
    world.waitFor([&] { return !launchCalls(world).isEmpty(); }, S("the thread to launch"));
    const QJsonObject launch = launchCalls(world).constLast();
    expect(modelOf(launch) == c[0] && launch.value(S("runtimeMode")) == mode, S("the launch is %1").arg(show(launch.toVariantMap())));
  });
});

}  // namespace
