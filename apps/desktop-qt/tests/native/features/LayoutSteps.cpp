// The window's layout the shell keeps itself (LayoutController): hiding and
// showing the thread list from its button, the header and mod+b, remembered on
// this device (navigation/layout.feature's sidebar, threads/sidebar-list.feature,
// navigation/appearance.feature's motion). That DefaultShell hides the list,
// gives the thread the width in one step and swaps in the settings sections is
// in tst_ShellExamples.

#include "CommandRegistry.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "LayoutController.h"
#include "World.h"

namespace {

// How often the shell told the window its layout changed since the scenario
// last acted on it.
struct LayoutChanges {
  int count = 0;
  bool watching = false;
};

LayoutController* layout(World& world) {
  return world.native().controller<LayoutController>();
}

bool collapsed(World& world) {
  return world.state(QStringLiteral("layout")).toMap().value(QStringLiteral("sidebarCollapsed")).toBool();
}

void watch(World& world) {
  LayoutChanges& changes = world.node.part<LayoutChanges>();
  changes.count = 0;
  if (changes.watching) return;
  changes.watching = true;
  QObject::connect(&world.bridge(), &ShellBridge::stateEntryChanged, &world.bridge(), [&changes](const QString& key) {
    if (key == QLatin1String("layout")) ++changes.count;
  });
}

// The sidebar's own button and the header's show button both dispatch it.
void toggle(World& world) {
  watch(world);
  world.bridge().dispatch(QStringLiteral("sidebar.toggle"), {});
}

void expectCollapsed(World& world, bool want) {
  // A starting shell reads the device's layout once the event loop runs.
  world.waitFor([&world] { return world.state(QStringLiteral("layout")).isValid(); }, QStringLiteral("the shell publishes its layout"));
  expect(collapsed(world) == want, QStringLiteral("the window's layout is %1").arg(show(world.state(QStringLiteral("layout")))));
  expect(layout(world)->sidebarCollapsed() == want, QStringLiteral("the layout controller disagrees with what it published"));
}

const Steps steps([] {
  step(QStringLiteral("the sidebar is (shown|hidden)"), [](World& world, const Captures& c, const Table&) {
    const bool hidden = c[0] == QLatin1String("hidden");
    if (world.checking) return expectCollapsed(world, hidden);
    layout(world)->setSidebarCollapsed(hidden);
    expectCollapsed(world, hidden);
  });
  step(QStringLiteral("the user (?:toggles the sidebar|asks to show the sidebar|hides the thread list|shows the thread list)"),
       [](World& world, const Captures&, const Table&) { toggle(world); });
  step(QStringLiteral("the user presses the sidebar shortcut"), [](World& world, const Captures&, const Table&) {
    watch(world);
    auto* keys = world.native().controller<KeybindingController>();
    expect(keys->commands()->run(QStringLiteral("sidebar.toggle")), QStringLiteral("sidebar.toggle is not a keybinding command"));
  });
  step(QStringLiteral("the main view takes the full width"), [](World& world, const Captures&, const Table&) {
    expectCollapsed(world, true);
  });
  step(QStringLiteral("the thread list is back"), [](World& world, const Captures&, const Table&) {
    expectCollapsed(world, false);
  });
  // One change of the layout per toggle: the window lays out once, with no
  // animated width in between.
  step(QStringLiteral("the (?:thread view is resized once, not on every frame|sidebar appears without animation)"),
       [](World& world, const Captures&, const Table&) {
         const int count = world.node.part<LayoutChanges>().count;
         expect(count == 1, QStringLiteral("the layout changed %1 times").arg(count));
       });
  // The window is in settings; DefaultShell draws SettingsNav where the
  // thread list was (tst_ShellExamples).
  step(QStringLiteral("the (?:thread list is hidden|settings sections are shown in its place)"), [](World& world, const Captures&, const Table&) {
    expect(world.state(QStringLiteral("route")).toMap().value(QStringLiteral("kind")) == QLatin1String("settings"),
           QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
  });
});

}  // namespace
