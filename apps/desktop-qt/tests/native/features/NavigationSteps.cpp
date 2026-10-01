// The shell's route (NavigationController): where the user goes from the
// shell and the window title
// (features/desktop/native-navigation.feature), and settings left for the
// thread it was opened from (settings/search-and-navigation.feature,
// navigation/focus.feature).

#include "Harness.h"
#include "Stream.h"
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
  // Settings reached from a thread of "shop" (settings/search-and-navigation.feature, navigation/focus.feature).
  step(QStringLiteral("the user (?:has opened|is in) settings"), [](World& world, const Captures&, const Table&) {
    if (!world.mc.projects.contains(stream::kProject)) {
      world.mc.projects.insert(stream::kProject, {{QStringLiteral("id"), stream::kProject}, {QStringLiteral("title"), stream::kProject},
                                                    {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()}});
      world.connect();
      world.sync();
    }
    world.bridge().dispatch(QStringLiteral("settings.open"), {});
  });
  step(QStringLiteral("the user opened settings from a thread"), [](World& world, const Captures&, const Table&) {
    stream::lookAtThread(world, stream::kProject);
    world.bridge().dispatch(QStringLiteral("settings.open"), {});
  });
  step(QStringLiteral("the user opens pull requests"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("pullRequests.open"), {});
  });
  step(QStringLiteral("the user opens usage"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("usage.open"), {});
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
  step(QStringLiteral("(?:the|that) thread is shown(?: again)?"), [](World& world, const Captures&, const Table&) {
    expectRoute(world, QStringLiteral("thread"), QStringLiteral("threadKey"), world.mc.environmentId + QLatin1Char(':') + stream::kThread);
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
});

}  // namespace
