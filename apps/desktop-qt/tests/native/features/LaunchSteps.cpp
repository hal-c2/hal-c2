// A new thread's first send (ComposerController::submitDraft): the thread the
// MC launches for it, what the launch carries, and the window moving to it
// (features/composer/sending-turns.feature, desktop/native-composer.feature,
// composer/drafting-and-sending.feature,
// source-control/worktrees-and-setup-scripts.feature).

#include <QJsonArray>
#include <QJsonObject>

#include "ComposerController.h"
#include "DraftController.h"
#include "Harness.h"
#include "Launch.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "World.h"

namespace {

// `orchestration.launchThread`: the MC makes the thread (its shell row) and
// answers with its id; refused like a command, held with the answers.
struct FakeLaunches {
  QList<QJsonObject> calls;
};

const FakeMc::Extension launches([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("orchestration.launchThread"), [&mc](const FakeMc::Rpc& rpc) {
    const QString method = QStringLiteral("orchestration.launchThread");
    mc.part<FakeLaunches>().calls.append(rpc.payload);
    const auto answer = [&mc, rpc, method] {
      if (mc.refusals.contains(method)) {
        mc.refuse(rpc, mc.refusals.value(method));
        return;
      }
      const QString threadId = rpc.payload.value(QLatin1String("threadId")).toString();
      const QJsonObject row{
          {QStringLiteral("id"), threadId},
          {QStringLiteral("projectId"), rpc.payload.value(QLatin1String("projectId"))},
          {QStringLiteral("title"), rpc.payload.value(QLatin1String("title"))},
          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T10:00:00Z")},
      };
      mc.threads.insert(threadId, row);
      mc.sendRow(threadId, row);
      mc.reply(rpc, QJsonObject{{QStringLiteral("threadId"), threadId}, {QStringLiteral("resumed"), false}});
    };
    if (mc.holding(QStringLiteral("answers"))) {
      mc.defer(answer);
    } else {
      answer();
    }
  });
});

// The prompt the last background start sent.
struct Background {
  QString text;
};

// A toast of `type` titled `title`, with the one action `action` (any, when empty).
bool toastOffering(World& world, const QString& type, const QString& title, const QString& action) {
  for (const QVariant& entry : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    const QVariantMap toast = entry.toMap();
    if (toast.value(QStringLiteral("type")) != type || toast.value(QStringLiteral("title")) != title) continue;
    const QVariantList actions = toast.value(QStringLiteral("actions")).toList();
    if (action.isEmpty() || (actions.size() == 1 && actions.first().toMap().value(QStringLiteral("label")) == action)) return true;
  }
  return false;
}

QList<QJsonObject> calls(World& world) {
  return world.mc.part<FakeLaunches>().calls;
}

QJsonObject lastLaunch(World& world) {
  world.waitFor([&] { return !calls(world).isEmpty(); }, [] { return QStringLiteral("a launch; the MC got none"); });
  return calls(world).constLast();
}

QJsonObject message(const QJsonObject& launch) {
  return launch.value(QLatin1String("initialMessage")).toObject();
}

QJsonObject strategy(const QJsonObject& launch) {
  return launch.value(QLatin1String("workspaceStrategy")).toObject();
}

QString describe(const QJsonObject& launch) {
  return show(launch.toVariantMap());
}

NavigationController* navigation(World& world) {
  return world.native().controller<NavigationController>();
}

// The user starts a new thread in the project the window shows.
void startDraft(World& world) {
  world.startNewThread(QVariantMap());
  world.waitFor([&] { return navigation(world)->route().kind == QLatin1String("draft"); },
                [&] { return QStringLiteral("a draft; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  world.draftId = navigation(world)->route().draftId;
  world.waitFor([&] { return world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("isDraft")).toBool(); },
                [&] { return QStringLiteral("the header to show the draft; it shows %1").arg(show(world.state(QStringLiteral("workspace")))); });
}

const Steps steps([] {
  const QString q = kQuoted;

  // The user.
  step(QStringLiteral("the user is starting a new thread in the project"), [](World& world, const Captures&, const Table&) {
    startDraft(world);
  });
  step(QStringLiteral("the user sends %1 in the background").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), c[0]},
                                                                           {QStringLiteral("intent"), QStringLiteral("background")}});
  });
  step(QStringLiteral("the user tries to start the thread"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("Add tax to the cart")},
                                                                           {QStringLiteral("intent"), QStringLiteral("foreground")}});
  });
  step(QStringLiteral("the user tries to start a thread with an empty first message"), [](World& world, const Captures&, const Table&) {
    startDraft(world);
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("  ")},
                                                                           {QStringLiteral("intent"), QStringLiteral("foreground")}});
  });
  step(QStringLiteral("the user goes back"), [](World& world, const Captures&, const Table&) {
    navigation(world)->back();
  });

  // The launch.
  step(QStringLiteral("a thread titled from %1 is created").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    expect(launch.value(QLatin1String("title")) == c[0] && launch.value(QLatin1String("generateTitle")).toBool(),
           QStringLiteral("the launch is %1").arg(describe(launch)));
    const QString threadKey = world.mc.environmentId + QLatin1Char(':') + launch.value(QLatin1String("threadId")).toString();
    world.waitFor([&] { return navigation(world)->threadKey() == threadKey; },
                  [&] { return QStringLiteral("%1; the route is %2").arg(threadKey, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("its first turn starts with that message"), [](World& world, const Captures&, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    expect(!message(launch).value(QLatin1String("text")).toString().isEmpty() &&
               message(launch).value(QLatin1String("text")) == launch.value(QLatin1String("title")),
           QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the MC launches the thread with the message %1 titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    expect(message(launch).value(QLatin1String("text")) == c[0] && launch.value(QLatin1String("title")) == c[1] &&
               !message(launch).value(QLatin1String("messageId")).toString().isEmpty(),
           QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the launch is for the draft's thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    const auto draft = world.native().controller<DraftController>()->draft(world.draftId);
    expect(launch.value(QLatin1String("projectId")) == c[0] &&
               (!draft || launch.value(QLatin1String("threadId")) == draft->threadId),
           QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the launch starts in the project folder"), [](World& world, const Captures&, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    expect(strategy(launch).value(QLatin1String("type")) == QLatin1String("root"), QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the worktree starts from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    expect(strategy(launch).value(QLatin1String("type")) == QLatin1String("worktree") &&
               strategy(launch).value(QLatin1String("baseRef")) == c[0],
           QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the launch uses the model %1 of %1 in the %1 and %1 modes").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    const QJsonObject model = launch.value(QLatin1String("modelSelection")).toObject();
    expect(model.value(QLatin1String("model")) == c[0] && model.value(QLatin1String("instanceId")) == c[1] &&
               launch.value(QLatin1String("runtimeMode")) == c[2] && launch.value(QLatin1String("interactionMode")) == c[3],
           QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the launch carries the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    const QJsonArray images = message(launch).value(QLatin1String("attachments")).toArray();
    const bool found = std::any_of(images.begin(), images.end(), [&](const QJsonValue& image) {
      return image.toObject().value(QLatin1String("name")) == c[0] && !image.toObject().value(QLatin1String("id")).toString().isEmpty();
    });
    expect(found, QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the thread is not started"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(calls(world).isEmpty() && navigation(world)->route().kind == QLatin1String("draft"),
           QStringLiteral("the MC launched %1; the route is %2").arg(describe(calls(world).value(0)), show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("the user is told to pick a base branch"), [](World& world, const Captures&, const Table&) {
    const auto told = [&] {
      for (const QVariant& toast : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
        if (toast.toMap().value(QStringLiteral("description")).toString().startsWith(QLatin1String("Select a base branch"))) return true;
      }
      return false;
    };
    world.waitFor(told, [&] { return QStringLiteral("a toast; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the MC launches no thread"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(calls(world).isEmpty(), QStringLiteral("the MC launched %1").arg(describe(calls(world).value(0))));
  });
  step(QStringLiteral("the MC launches (\\d+) threads?"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(calls(world).size() == c[0].toInt(), QStringLiteral("the MC launched %1 threads").arg(calls(world).size()));
  });

  // What the window shows.
  step(QStringLiteral("the window shows the launched thread in the draft's place"), [](World& world, const Captures&, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    const QString threadKey = world.mc.environmentId + QLatin1Char(':') + launch.value(QLatin1String("threadId")).toString();
    world.waitFor([&] { return navigation(world)->threadKey() == threadKey; },
                  [&] { return QStringLiteral("%1; the route is %2").arg(threadKey, show(world.state(QStringLiteral("route")))); });
    expect(!world.native().controller<DraftController>()->draft(world.draftId),
           QStringLiteral("the shell still keeps the draft %1").arg(world.draftId));
  });
  step(QStringLiteral("the window shows the thread the background start launched"), [](World& world, const Captures&, const Table&) {
    const QString threadKey = world.mc.environmentId + QLatin1Char(':') + lastLaunch(world).value(QLatin1String("threadId")).toString();
    world.waitFor([&] { return navigation(world)->threadKey() == threadKey; },
                  [&] { return QStringLiteral("%1; the route is %2").arg(threadKey, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("the new thread still reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const auto draft = world.native().controller<DraftController>()->draft(world.draftId);
    expect(draft && draft->text == c[0], QStringLiteral("the draft reads %1").arg(draft ? draft->text : QStringLiteral("nothing; it is gone")));
  });

  // A background start (mod+alt+Enter): the prompt it sent.
  const auto typeFirst = [](World& world, const QString& text) {
    // The window may already have landed on a draft (DraftController::land).
    if (navigation(world)->route().kind == QLatin1String("draft")) world.draftId = navigation(world)->route().draftId;
    else startDraft(world);
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), world.draftId}, {QStringLiteral("text"), text}, {QStringLiteral("cursor"), text.size()}});
  };
  const auto sendInBackground = [](World& world) {
    world.mc.part<Background>().text = world.native().controller<ComposerController>()->draft(world.draftId);
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("intent"), QStringLiteral("background")}});
  };
  step(QStringLiteral("the user is writing the first message of a new thread"), [typeFirst](World& world, const Captures&, const Table&) {
    typeFirst(world, QStringLiteral("Set up the linter"));
  });
  step(QStringLiteral("the user sends it in the background"), [sendInBackground](World& world, const Captures&, const Table&) {
    sendInBackground(world);
  });
  step(QStringLiteral("the user sent %1 in the background").arg(q), [typeFirst, sendInBackground](World& world, const Captures& c, const Table&) {
    world.mc.hold(QStringLiteral("answers"));
    typeFirst(world, c[0]);
    sendInBackground(world);
  });
  step(QStringLiteral("the background thread fails to start"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("orchestration.launchThread"), QStringLiteral("Provider unavailable"));
    world.sync();
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("a new thread starts with that message"), [](World& world, const Captures&, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    expect(message(launch).value(QLatin1String("text")) == world.mc.part<Background>().text.trimmed(),
           QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the user is told it started in the background with a way to open it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toastOffering(world, QStringLiteral("success"), QStringLiteral("Started 1 thread in background"), QStringLiteral("Open")); },
                  [&] { return QStringLiteral("the toast; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the composer is ready for another prompt"), [](World& world, const Captures&, const Table&) {
    const auto draft = world.native().controller<DraftController>()->draft(world.draftId);
    const QVariantMap composer = world.state(QStringLiteral("composer")).toMap();
    expect(navigation(world)->route().draftId == world.draftId && draft &&
               draft->threadId != lastLaunch(world).value(QLatin1String("threadId")).toString() &&
               composer.value(QStringLiteral("target")) == world.draftId && composer.value(QStringLiteral("text")).toString().isEmpty(),
           QStringLiteral("the composer shows %1").arg(show(composer)));
  });
  step(QStringLiteral("the user is told the background prompt could not be sent"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toastOffering(world, QStringLiteral("error"), QStringLiteral("A background prompt could not be sent"), QString()); },
                  [&] { return QStringLiteral("the toast; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the user can restore %1 into the composer").arg(q), [](World& world, const Captures& c, const Table&) {
    // The draft was empty, so the prompt is back in it.
    const QVariantMap composer = world.state(QStringLiteral("composer")).toMap();
    expect(composer.value(QStringLiteral("target")) == world.draftId && composer.value(QStringLiteral("text")) == c[0],
           QStringLiteral("the composer shows %1").arg(show(composer)));
  });
});

}  // namespace

QList<QJsonObject> launchCalls(World& world) {
  return world.mc.part<FakeLaunches>().calls;
}
