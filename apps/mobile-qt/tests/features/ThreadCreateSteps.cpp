// Starting threads on the phone (features/threads/creating.feature): its home
// screen's New thread, the shared DraftController and ComposerController
// behind it, and `orchestration.launchThread` as WorktreeSteps.cpp serves it.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "ComposerController.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Phone.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "WorkspaceController.h"
#include "World.h"

namespace {

#define S(text) QStringLiteral(text)

struct Creating {
  // The draft a step opened, and the one sent while its thread is being made.
  QString draftId;
  QString sentDraftId;
  QString sentThreadId;
};

Creating& creating(World& world) {
  return world.mc.part<Creating>();
}

QVariantMap route(World& world) {
  return world.state(S("route")).toMap();
}

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

QJsonObject modelNamed(const QString& name) {
  return {{S("instanceId"), S("claudeAgent")}, {S("model"), S("claude-") + name.toLower()}};
}

// Claude, offering the models the scenarios name.
void offerModels(World& world) {
  QJsonArray models;
  for (const QString& name : {S("Opus"), S("Sonnet"), S("GPT-5")}) {
    models.append(QJsonObject{{S("slug"), modelNamed(name).value(QLatin1String("model"))}, {S("name"), name},
                              {S("capabilities"), QJsonObject{{S("optionDescriptors"), QJsonArray()}}}});
  }
  offerProviders(world.mc, {QJsonObject{{S("instanceId"), S("claudeAgent")}, {S("driver"), S("claudeAgent")}, {S("displayName"), S("Claude")},
                                        {S("enabled"), true}, {S("installed"), true}, {S("status"), S("ready")}, {S("models"), models}}});
  world.sync();
}

QList<QJsonObject> launches(World& world) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("orchestration.launchThread")) found.append(rpc.payload);
  }
  return found;
}

void goHome(World& world) {
  const auto home = [&] { return route(world).value(S("kind")) == QLatin1String("home") && world.find(S("homeScreen")) != nullptr; };
  for (int tries = 0; tries < 6 && !home(); ++tries) {
    world.back();
    world.sync();
  }
  world.waitFor(home, [&] { return S("the home screen; the route is %1").arg(show(route(world))); });
}

// New thread on the home screen, as the user reaches it from a thread: a draft
// other than `besides` opens.
void startNewThread(World& world, const QString& besides = {}) {
  goHome(world);
  world.tap(S("newThread"));
  world.waitFor([&] { return route(world).value(S("kind")) == QLatin1String("draft") && route(world).value(S("draftId")) != besides; },
                [&] { return S("a draft; the route is %1").arg(show(route(world))); });
  creating(world).draftId = route(world).value(S("draftId")).toString();
  world.item(S("composer"));
}

void send(World& world, const QString& text) {
  QQuickItem* input = world.item(S("input"));
  world.waitFor([&] { return input->isEnabled(); }, S("the composer to take text"));
  world.tap(input);
  world.type(text);
  world.tap(S("primaryAction"));
}

// A draft sent while the MC holds its start, as a new worktree being set up.
void sendHeld(World& world, const QString& text) {
  startNewThread(world);
  Creating& made = creating(world);
  made.sentDraftId = made.draftId;
  world.mc.hold(S("answers"));
  send(world, text);
  world.waitFor([&] { return launches(world).size() == 1; }, [&] { return S("the start; the screen shows %1").arg(world.texts().join(S(" | "))); });
  made.sentThreadId = launches(world).constFirst().value(QLatin1String("threadId")).toString();
}

bool toldTitled(World& world, const QString& title) {
  for (const QVariant& item : world.state(S("toasts")).toMap().value(S("items")).toList()) {
    if (item.toMap().value(S("title")).toString().startsWith(title)) return true;
  }
  return false;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("the user starts a new thread"), [](World& world, const Captures&, const Table&) {
    // A draft still being sent stays as it is; the new thread is another.
    startNewThread(world, creating(world).sentDraftId);
  });

  // The model and mode a new thread keeps, unless the project names its own.
  step(S("the current thread uses the model %1( in plan mode)?").arg(q), [](World& world, const Captures& c, const Table&) {
    offerModels(world);
    if (world.thread.isEmpty()) {
      world.thread = haveThread(world, S("Tax line"));
      openThread(world, S("Tax line"));
    }
    const bool plan = !c[1].isEmpty();
    if (plan) {
      expect(world.native().controller<SettingsController>()->writeDevice(S("planModeEnabled"), true), S("plan mode could not be turned on"));
    }
    QJsonObject fields{{S("modelSelection"), modelNamed(c[0])}};
    if (plan) fields.insert(S("interactionMode"), S("plan"));
    updateRow(world.mc, world.thread, fields);
    world.waitFor([&] {
      return composer(world).value(S("selectedModel")) == modelNamed(c[0]).value(QLatin1String("model")).toString() &&
             (!plan || composer(world).value(S("interactionMode")) == QLatin1String("plan"));
    }, [&] { return S("the thread's model; the composer is %1").arg(show(composer(world))); });
  });
  step(S("%1 has the default model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.projects.contains(c[0]), S("there is no project %1").arg(c[0]));
    QJsonObject row = world.mc.projects.value(c[0]);
    row.insert(S("defaultModelSelection"), modelNamed(c[1]));
    world.mc.projects.insert(c[0], row);
    world.mc.sendRow(c[0], row, S("project"));
    world.sync();
  });
  step(S("the draft uses the model %1(?: in (plan|default) mode)?").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString model = modelNamed(c[0]).value(QLatin1String("model")).toString();
    world.waitFor([&] {
      const QVariantMap shown = composer(world);
      return route(world).value(S("kind")) == QLatin1String("draft") && shown.value(S("target")) == creating(world).draftId &&
             shown.value(S("selectedModel")) == model && (c[1].isEmpty() || shown.value(S("interactionMode")) == c[1]);
    }, [&] { return S("the draft on %1; the composer is %2").arg(c[0], show(composer(world))); });
  });
  // Another thread of the project, in the default mode, opened from the thread list.
  step(S("the user opens another thread of %1 that uses the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("shop"), S("the phone's threads are in shop, not %1").arg(c[0]));
    const QString title = S("Cart totals");
    world.thread = haveThread(world, title);
    updateRow(world.mc, world.thread, {{S("modelSelection"), modelNamed(c[1])}, {S("interactionMode"), S("default")}});
    goHome(world);
    openThread(world, title);
    world.waitFor([&] {
      return composer(world).value(S("selectedModel")) == modelNamed(c[1]).value(QLatin1String("model")).toString() &&
             composer(world).value(S("interactionMode")) == QLatin1String("default");
    }, [&] { return S("the other thread; the composer is %1").arg(show(composer(world))); });
  });

  // A new thread on the current thread's branch, from the thread's menu.
  step(S("the current thread is on the branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updateRow(world.mc, world.thread, {{S("branch"), c[0]}, {S("worktreePath"), S("/work/wt-") + QString(c[0]).replace(u'/', u'-')}});
    world.sync();
  });
  step(S("the user starts a new thread on that branch from the thread menu"), [](World& world, const Captures&, const Table&) {
    world.tap(S("threadMenu"));
    world.awaitPopup(S("mobileMenu"));
    world.tap(S("mobileMenuItem:new-thread-on-branch"));
    world.awaitPopup(S("mobileMenu"), false);
  });
  step(S("a draft opens in the same worktree as the current thread"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return route(world).value(S("kind")) == QLatin1String("draft"); }, [&] { return S("a draft; the route is %1").arg(show(route(world))); });
    const auto checkout = world.native().controller<WorkspaceController>()->checkout(route(world).value(S("draftId")).toString());
    expect(checkout.envMode == QLatin1String("worktree") && checkout.worktreePath == S("/work/wt-feature-cart") && checkout.branch == S("feature/cart"),
           S("the draft is in %1 on %2").arg(checkout.worktreePath.value_or(checkout.envMode), checkout.branch.value_or(QString())));
  });

  // A start the environment refuses, or cannot be asked for.
  step(S("the environment rejects new threads"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(S("orchestration.launchThread"), S("Provider unavailable"));
  });
  step(S("the user sends the first message of a new thread"), [](World& world, const Captures&, const Table&) {
    startNewThread(world);
    send(world, S("Add caching"));
  });
  step(S("the environment is unreachable"), [](World& world, const Captures&, const Table&) {
    // An agent the phone could start a thread with, were it connected.
    offerModels(world);
    world.mc.setOnline(world.mc.environmentId, false);
    world.sync();
  });
  step(S("the user is told the environment is offline"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return composer(world).value(S("sendDisabledReason")) == QLatin1String("Not connected"); },
                  [&] { return S("the composer to say so; it is %1").arg(show(composer(world))); });
    // The prompt can still be written, and a send says why it did not go.
    QQuickItem* input = world.item(S("input"));
    world.tap(input);
    world.type(S("Add caching"));
    world.waitFor([&] { return composer(world).value(S("text")) == QLatin1String("Add caching"); },
                  [&] { return S("the prompt; the composer is %1").arg(show(composer(world))); });
    world.bridge().dispatch(S("composer.submit"), QVariantMap{{S("intent"), S("foreground")}});
    world.sync();
    world.waitFor([&] { return toldTitled(world, S("Not connected")); }, [&] { return S("the notice; the toasts are %1").arg(show(world.state(S("toasts")))); });
  });
  step(S("no draft is sent to the environment"), [](World& world, const Captures&, const Table&) {
    expect(launches(world).isEmpty(), S("the MC was asked to start a thread"));
    expect(!composer(world).value(S("text")).toString().isEmpty(), S("the draft lost its prompt"));
  });

  // A new thread while the last one is still being made.
  step(S("the user sent a draft that is still creating its worktree"), [](World& world, const Captures&, const Table&) {
    sendHeld(world, S("Set up the linter"));
  });
  step(S("a fresh draft opens"), [](World& world, const Captures&, const Table&) {
    const Creating& made = creating(world);
    expect(!made.draftId.isEmpty() && made.draftId != made.sentDraftId, S("the sent draft opened again"));
    expect(composer(world).value(S("text")).toString().isEmpty(), S("the new draft shows %1").arg(show(composer(world))));
  });
  step(S("the sent thread keeps setting up and starts when its worktree is ready"), [](World& world, const Captures&, const Table&) {
    const Creating& made = creating(world);
    expect(world.native().controller<ComposerController>()->launching(made.sentDraftId), S("the sent draft is no longer starting"));
    world.mc.answerHeld();
    world.waitFor([&] { return world.mc.threads.contains(made.sentThreadId) && !world.native().controller<ComposerController>()->launching(made.sentDraftId); },
                  S("the sent thread to start"));
    world.sync();
    expect(launches(world).size() == 1, S("%1 starts were asked for").arg(launches(world).size()));
    expect(route(world).value(S("draftId")) == made.draftId, S("the phone left the new draft: %1").arg(show(route(world))));
  });
  step(S("the user sent a draft and opened a new draft while it set up"), [](World& world, const Captures&, const Table&) {
    sendHeld(world, S("Set up the linter"));
    startNewThread(world, creating(world).sentDraftId);
    QQuickItem* input = world.item(S("input"));
    world.waitFor([&] { return input->isEnabled(); }, S("the composer to take text"));
    world.tap(input);
    world.type(S("Write the changelog"));
    world.waitFor([&] { return composer(world).value(S("text")) == QLatin1String("Write the changelog"); },
                  [&] { return S("the new draft's prompt; the composer is %1").arg(show(composer(world))); });
  });
  step(S("the sent thread fails to start"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(S("orchestration.launchThread"), S("Provider unavailable"));
    world.mc.answerHeld();
    world.waitFor([&] { return !world.native().controller<ComposerController>()->launching(creating(world).sentDraftId); }, S("the start to fail"));
    world.sync();
  });
  step(S("its prompt is back in its own draft"), [](World& world, const Captures&, const Table&) {
    const QString text = world.native().controller<ComposerController>()->draft(creating(world).sentDraftId);
    expect(text == QLatin1String("Set up the linter"), S("the sent draft holds \"%1\"").arg(text));
  });
  step(S("the new draft is unchanged"), [](World& world, const Captures&, const Table&) {
    expect(route(world).value(S("draftId")) == creating(world).draftId && composer(world).value(S("text")) == QLatin1String("Write the changelog"),
           S("the composer shows %1").arg(show(composer(world))));
  });
});

}  // namespace
