// A new thread's first send (ComposerController::submitDraft): the thread the
// node launches for it, what the launch carries, and the window moving to it
// (features/desktop/native-composer.feature, composer/drafting-and-sending.feature,
// source-control/worktrees-and-setup-scripts.feature).

#include <QJsonArray>
#include <QJsonObject>

#include "DraftController.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "World.h"

namespace {

// `orchestration.launchThread`: the node makes the thread (its shell row) and
// answers with its id; refused like a command, held with the answers.
struct FakeLaunches {
  QList<QJsonObject> calls;
};

const FakeNode::Extension launches([](FakeNode& node) {
  node.onRpc(QStringLiteral("orchestration.launchThread"), [&node](const FakeNode::Rpc& rpc) {
    const QString method = QStringLiteral("orchestration.launchThread");
    node.part<FakeLaunches>().calls.append(rpc.payload);
    const auto answer = [&node, rpc, method] {
      if (node.refusals.contains(method)) {
        node.refuse(rpc, node.refusals.value(method));
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
      node.threads.insert(threadId, row);
      node.sendRow(threadId, row);
      node.reply(rpc, QJsonObject{{QStringLiteral("threadId"), threadId}, {QStringLiteral("resumed"), false}});
    };
    if (node.holding(QStringLiteral("answers"))) {
      node.defer(answer);
    } else {
      answer();
    }
  });
});

QList<QJsonObject> calls(World& world) {
  return world.node.part<FakeLaunches>().calls;
}

QJsonObject lastLaunch(World& world) {
  world.waitFor([&] { return !calls(world).isEmpty(); }, [] { return QStringLiteral("a launch; the node got none"); });
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
    const QString threadKey = world.node.environmentId + QLatin1Char(':') + launch.value(QLatin1String("threadId")).toString();
    world.waitFor([&] { return navigation(world)->threadKey() == threadKey; },
                  [&] { return QStringLiteral("%1; the route is %2").arg(threadKey, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("its first turn starts with that message"), [](World& world, const Captures&, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    expect(!message(launch).value(QLatin1String("text")).toString().isEmpty() &&
               message(launch).value(QLatin1String("text")) == launch.value(QLatin1String("title")),
           QStringLiteral("the launch is %1").arg(describe(launch)));
  });
  step(QStringLiteral("the node launches the thread with the message %1 titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
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
           QStringLiteral("the node launched %1; the route is %2").arg(describe(calls(world).value(0)), show(world.state(QStringLiteral("route")))));
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
  step(QStringLiteral("the node launches no thread"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(calls(world).isEmpty(), QStringLiteral("the node launched %1").arg(describe(calls(world).value(0))));
  });
  step(QStringLiteral("the node launches (\\d+) threads?"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(calls(world).size() == c[0].toInt(), QStringLiteral("the node launched %1 threads").arg(calls(world).size()));
  });

  // What the page is asked.
  step(QStringLiteral("the page is asked to set the composer text for the draft to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const PageAction& action : world.actionsOf(QStringLiteral("composer.text.set"))) {
        if (action.payload.value(QStringLiteral("target")) == world.draftId && action.payload.value(QStringLiteral("text")) == c[0]) return true;
      }
      return false;
    }, [&] { return QStringLiteral("the composer text; the page got %1").arg(world.describePage()); });
  });

  // What the window shows.
  step(QStringLiteral("the window shows the launched thread in the draft's place"), [](World& world, const Captures&, const Table&) {
    const QJsonObject launch = lastLaunch(world);
    const QString threadKey = world.node.environmentId + QLatin1Char(':') + launch.value(QLatin1String("threadId")).toString();
    world.waitFor([&] { return navigation(world)->threadKey() == threadKey; },
                  [&] { return QStringLiteral("%1; the route is %2").arg(threadKey, show(world.state(QStringLiteral("route")))); });
    expect(!world.native().controller<DraftController>()->draft(world.draftId),
           QStringLiteral("the shell still keeps the draft %1").arg(world.draftId));
  });
  step(QStringLiteral("the new thread still reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const auto draft = world.native().controller<DraftController>()->draft(world.draftId);
    expect(draft && draft->text == c[0], QStringLiteral("the draft reads %1").arg(draft ? draft->text : QStringLiteral("nothing; it is gone")));
  });
});

}  // namespace
