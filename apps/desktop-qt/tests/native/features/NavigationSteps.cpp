// The shell's route (NavigationController): where the user goes from the
// shell, where the page reports its own links took it, and the window title
// (features/desktop/native-navigation.feature).

#include "Harness.h"
#include "World.h"

namespace {

QVariant route(World& world) {
  return world.state(QStringLiteral("route"));
}

void expectRoute(World& world, const QString& kind, const QString& field = {}, const QString& value = {}) {
  world.sync();
  const QVariant current = route(world);
  expect(at(current, QStringLiteral("kind")) == kind && (field.isEmpty() || at(current, field) == value),
         QStringLiteral("the route is %1").arg(show(current)));
}

const Steps steps([] {
  const QString q = kQuoted;

  // The user in the shell.
  step(QStringLiteral("the user opens %1 from the sidebar").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), c[0]}});
  });
  step(QStringLiteral("the user opens the draft %1 from the sidebar").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), c[0]}});
  });
  step(QStringLiteral("the user starts a new thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(c[0])}});
  });
  step(QStringLiteral("the user opens settings"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("settings.open"), {});
  });
  step(QStringLiteral("the user opens pull requests"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("pullRequests.open"), {});
  });
  step(QStringLiteral("the user opens usage"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("usage.open"), {});
  });

  // The page, following its own links.
  step(QStringLiteral("the page's own link takes it to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("thread")}, {QStringLiteral("threadKey"), c[0]}});
  });
  step(QStringLiteral("the page goes back to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("thread")}, {QStringLiteral("threadKey"), c[0]}});
  });
  step(QStringLiteral("the page lands on the new draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("draft")}, {QStringLiteral("draftId"), c[0]}}, true);
  });
  step(QStringLiteral("the page reloads"), [](World& world, const Captures&, const Table&) {
    world.follows.clear();
    world.bridge().dispatch(QStringLiteral("shell.native.query"), {});
  });

  step(QStringLiteral("the desktop quits and starts again"), [](World& world, const Captures&, const Table&) {
    world.restart();
  });

  // What the shell shows.
  step(QStringLiteral("the window shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectRoute(world, QStringLiteral("thread"), QStringLiteral("threadKey"), c[0]);
  });
  step(QStringLiteral("the window shows the draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectRoute(world, QStringLiteral("draft"), QStringLiteral("draftId"), c[0]);
  });
  step(QStringLiteral("the window shows a new thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectRoute(world, QStringLiteral("newThread"), QStringLiteral("projectKey"), c[0]);
  });
  step(QStringLiteral("the window shows settings"), [](World& world, const Captures&, const Table&) {
    expectRoute(world, QStringLiteral("settings"));
  });
  step(QStringLiteral("the window shows the settings section %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectRoute(world, QStringLiteral("settings"), QStringLiteral("section"), c[0]);
  });
  step(QStringLiteral("the window shows pull requests"), [](World& world, const Captures&, const Table&) {
    expectRoute(world, QStringLiteral("pullRequests"));
  });
  step(QStringLiteral("the window shows usage"), [](World& world, const Captures&, const Table&) {
    expectRoute(world, QStringLiteral("usage"));
  });
  step(QStringLiteral("the window shows home"), [](World& world, const Captures&, const Table&) {
    expectRoute(world, QStringLiteral("home"));
  });
  step(QStringLiteral("the window is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(at(route(world), QStringLiteral("title")) == c[0], QStringLiteral("the route is %1").arg(show(route(world))));
  });
  const auto canGoBack = [](bool can) {
    return [can](World& world, const Captures&, const Table&) {
      world.sync();
      expect(at(route(world), QStringLiteral("canGoBack")).toBool() == can,
             QStringLiteral("the route is %1").arg(show(route(world))));
    };
  };
  step(QStringLiteral("the user can go back"), canGoBack(true));
  step(QStringLiteral("the user can not go back"), canGoBack(false));
  step(QStringLiteral("the sidebar marks %1 as open").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariant sidebar = world.state(QStringLiteral("sidebar"));
    expect(at(sidebar, QStringLiteral("activeThreadKey")) == c[0],
           QStringLiteral("the sidebar marks %1").arg(show(at(sidebar, QStringLiteral("activeThreadKey")))));
  });
  step(QStringLiteral("the sidebar marks the draft %1 as open").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariant sidebar = world.state(QStringLiteral("sidebar"));
    expect(at(sidebar, QStringLiteral("activeDraftId")) == c[0] && at(sidebar, QStringLiteral("activeThreadKey")).isNull(),
           QStringLiteral("the sidebar is %1").arg(show(sidebar)));
  });
  step(QStringLiteral("the page is asked to open the draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariantMap& follow : world.follows) {
        if (follow.value(QStringLiteral("kind")) == QLatin1String("draft") && follow.value(QStringLiteral("draftId")) == c[0]) return true;
      }
      return false;
    }, [&] { return QStringLiteral("to follow the draft; the page got %1").arg(world.describePage()); });
  });
  step(QStringLiteral("the page is asked to open (settings|pull requests|usage|home)"), [](World& world, const Captures& c, const Table&) {
    const QString kind = c[0] == QLatin1String("pull requests") ? QStringLiteral("pullRequests") : c[0];
    world.waitFor([&] {
      for (const QVariantMap& follow : world.follows) {
        if (follow.value(QStringLiteral("kind")) == kind) return true;
      }
      return false;
    }, [&] { return QStringLiteral("to follow %1; the page got %2").arg(kind, world.describePage()); });
  });
  step(QStringLiteral("the page is last asked to open %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!world.follows.isEmpty() && world.follows.constLast().value(QStringLiteral("threadKey")) == c[0],
           QStringLiteral("the page got %1").arg(world.describePage()));
  });
  step(QStringLiteral("the page is not told where to go"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.follows.isEmpty(), QStringLiteral("the page got %1").arg(world.describePage()));
  });
});

}  // namespace
