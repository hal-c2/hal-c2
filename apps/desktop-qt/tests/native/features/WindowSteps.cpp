// More than one window (navigation/windows.feature): each NativeWindow has
// its own route, drafts and panels over the shell's one node connection, and
// reopens with them after a restart until it is closed.

#include <QCoreApplication>
#include <QEvent>
#include <QJsonArray>

#include "ComposerController.h"
#include "Harness.h"
#include "LayoutController.h"
#include "NavigationController.h"
#include "Stream.h"
#include "World.h"

namespace {

const QString kFirst = QStringLiteral("t1");
const QString kSecond = QStringLiteral("t2");
const QString kStableId = QStringLiteral("stable");

QString keyOf(World& world, const QString& thread) {
  return world.node.environmentId + QLatin1Char(':') + thread;
}

NativeWindow* second(World& world) {
  const auto& windows = world.native().windows();
  return windows.size() > 1 ? windows.at(1).get() : nullptr;
}

QString shownBy(NativeWindow* window) {
  return window->controller<NavigationController>()->threadKey();
}

void collectKeys(const QVariant& value, QStringList& keys) {
  if (value.typeId() == QMetaType::QVariantMap) {
    const QVariantMap map = value.toMap();
    for (auto it = map.cbegin(); it != map.cend(); ++it) {
      if (it.key() == QLatin1String("key")) keys.append(it.value().toString());
      collectKeys(it.value(), keys);
    }
  } else if (value.typeId() == QMetaType::QVariantList) {
    for (const QVariant& item : value.toList()) collectKeys(item, keys);
  }
}

// Two threads of one project, the first open in the first window.
void connectWithThreads(World& world) {
  world.node.projects.insert(stream::kProject, {{QStringLiteral("id"), stream::kProject}, {QStringLiteral("title"), stream::kProject},
                                                {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()}});
  for (const QString& id : {kFirst, kSecond}) {
    world.node.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("projectId"), stream::kProject},
                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                   {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  }
  world.connect();
  world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); }, QStringLiteral("the shell to take over"));
  world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(world, kFirst)}});
  world.sync();
}

// What the user's layout (or the palette's "New window") asks for.
NativeWindow* openSecond(World& world, const QVariantMap& payload = {}) {
  world.bridge().dispatch(QStringLiteral("window.new"), payload);
  NativeWindow* window = second(world);
  expect(window != nullptr, QStringLiteral("no second window opened"));
  return window;
}

void openIn(World& world, NativeWindow* window, const QString& thread) {
  window->bridge()->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(world, thread)}});
  world.waitFor([&] { return shownBy(window) == keyOf(world, thread); },
                [&] { return QStringLiteral("the window to show %1; it shows %2").arg(thread, shownBy(window)); });
  world.sync();
}

void expectFirstOn(World& world, const QString& thread) {
  world.sync();
  const QString shown = shownBy(world.native().main());
  expect(shown == keyOf(world, thread) && at(world.state(QStringLiteral("route")), QStringLiteral("threadKey")) == shown,
         QStringLiteral("the first window shows %1").arg(show(world.state(QStringLiteral("route")))));
}

const QString kDraft = QStringLiteral("Carry on from the other window");

// The zoom factor `window` draws its content at (LayoutController's `layout`).
double zoomOf(NativeWindow* window) {
  return at(window->bridge()->state()->value(QStringLiteral("layout")), QStringLiteral("zoom")).toDouble();
}

const Steps steps([] {
  step(QStringLiteral("the user's shell layout opens a second window"), [](World& world, const Captures&, const Table&) {
    connectWithThreads(world);
    openSecond(world);
  });
  step(QStringLiteral("a second window is open"), [](World& world, const Captures&, const Table&) {
    connectWithThreads(world);
    openSecond(world);
  });
  step(QStringLiteral("the user opens a thread in the second window"), [](World& world, const Captures&, const Table&) {
    openIn(world, second(world), kSecond);
  });
  step(QStringLiteral("the first window still shows its own thread"), [](World& world, const Captures&, const Table&) {
    expectFirstOn(world, kFirst);
    expect(shownBy(second(world)) == keyOf(world, kSecond), QStringLiteral("the second window shows %1").arg(shownBy(second(world))));
  });

  step(QStringLiteral("the user closes the second window"), [](World& world, const Captures&, const Table&) {
    // It was showing the other thread, followed only for it.
    openIn(world, second(world), kSecond);
    world.waitFor([&] { return !stream::followers(world, kSecond).isEmpty(); }, QStringLiteral("the second window to follow its thread"));
    world.native().closeWindow(second(world)->id());
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
  });
  step(QStringLiteral("the first window stays open on the same thread"), [](World& world, const Captures&, const Table&) {
    expect(world.native().windows().size() == 1, QStringLiteral("%1 windows are open").arg(world.native().windows().size()));
    expectFirstOn(world, kFirst);
    world.waitFor([&] { return stream::followers(world, kSecond).isEmpty(); },
                  QStringLiteral("the closed window's thread to be let go"));
    expect(!stream::followers(world, kFirst).isEmpty(), QStringLiteral("the first window stopped following its thread"));
  });

  step(QStringLiteral("the second window is signed in to the same environments"), [](World& world, const Captures&, const Table&) {
    NativeWindow* window = second(world);
    world.sync();
    QStringList keys;
    collectKeys(window->bridge()->state()->value(QStringLiteral("sidebar")), keys);
    expect(keys.contains(keyOf(world, kFirst)) && keys.contains(keyOf(world, kSecond)),
           QStringLiteral("the second window's sidebar lists %1").arg(keys.join(u", ")));
    // One connection, and so one sign-in, for every window.
    expect(world.node.connections.size() == 1, QStringLiteral("the shell opened %1 connections").arg(world.node.connections.size()));
  });
  step(QStringLiteral("navigating in one window does not navigate the other"), [](World& world, const Captures&, const Table&) {
    NativeWindow* window = second(world);
    openIn(world, window, kSecond);
    expectFirstOn(world, kFirst);
    world.bridge().dispatch(QStringLiteral("settings.open"), {});
    world.sync();
    expect(at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("settings"),
           QStringLiteral("the first window did not open settings"));
    expect(shownBy(window) == keyOf(world, kSecond) &&
               at(window->bridge()->state()->value(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("thread"),
           QStringLiteral("the second window moved to %1").arg(show(window->bridge()->state()->value(QStringLiteral("route")))));
  });

  step(QStringLiteral("a second window with a stable identity has a draft and an open panel"), [](World& world, const Captures&, const Table&) {
    connectWithThreads(world);
    NativeWindow* window = openSecond(world, {{QStringLiteral("id"), kStableId}});
    expect(window->id() == kStableId, QStringLiteral("the window is %1").arg(window->id()));
    openIn(world, window, kSecond);
    window->bridge()->dispatch(QStringLiteral("composer.text.set"),
                               QVariantMap{{QStringLiteral("target"), keyOf(world, kSecond)},
                                           {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                                {QStringLiteral("revision"), world.nextEdit++}}},
                                           {QStringLiteral("text"), kDraft},
                                           {QStringLiteral("cursor"), kDraft.size()}});
    window->bridge()->dispatch(QStringLiteral("rightPanel.toggle"), QVariantMap());
    world.sync();
    expect(at(window->bridge()->state()->value(QStringLiteral("panel")), QStringLiteral("isOpen")).toBool(),
           QStringLiteral("the second window's panel did not open"));
    expect(!at(world.state(QStringLiteral("panel")), QStringLiteral("isOpen")).toBool(), QStringLiteral("the first window's panel opened too"));
  });
  step(QStringLiteral("the user restarts the app"), [](World& world, const Captures&, const Table&) {
    world.restart();
    world.connect();
    world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); }, QStringLiteral("the shell to take over"));
  });
  step(QStringLiteral("that window has the same draft and panel"), [](World& world, const Captures&, const Table&) {
    NativeWindow* window = world.native().window(kStableId);
    expect(window != nullptr, QStringLiteral("the window %1 did not reopen").arg(kStableId));
    world.waitFor([&] { return shownBy(window) == keyOf(world, kSecond); },
                  [&] { return QStringLiteral("the window to reopen on %1; it shows %2").arg(kSecond, shownBy(window)); });
    world.sync();
    const QString text = window->controller<ComposerController>()->draft(keyOf(world, kSecond));
    expect(text == kDraft, QStringLiteral("the window's draft is \"%1\"").arg(text));
    expect(at(window->bridge()->state()->value(QStringLiteral("panel")), QStringLiteral("isOpen")).toBool(),
           QStringLiteral("the window's panel is %1").arg(show(window->bridge()->state()->value(QStringLiteral("panel")))));
    // The first window kept its own.
    expectFirstOn(world, kFirst);
    expect(world.native().main()->controller<ComposerController>()->draft(keyOf(world, kSecond)).isEmpty(),
           QStringLiteral("the first window has the other window's draft"));
  });

  // The app's zoom (the application menu's mod+=, mod++, mod+-, mod+0).
  step(QStringLiteral("the app is zoomed in"), [](World& world, const Captures&, const Table&) {
    if (world.shellSubscriptions() == 0) {
      world.connect();
      world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); }, QStringLiteral("the shell to take over"));
    }
    world.native().controller<LayoutController>()->setZoomLevel(1);
    world.sync();
    expect(zoomOf(world.native().main()) > 1, QStringLiteral("the app is at %1").arg(zoomOf(world.native().main())));
  });
  step(QStringLiteral("the app content is (larger|smaller|back to its actual size)"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const double zoom = zoomOf(world.native().main());
    const bool ok = c[0] == u"larger" ? zoom > 1 : c[0] == u"smaller" ? zoom > 0 && zoom < 1 : qFuzzyCompare(zoom, 1.0);
    expect(ok, QStringLiteral("the app is at %1").arg(zoom));
  });
  step(QStringLiteral("the second window's content is larger too"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(zoomOf(world.native().main()) > 1 && qFuzzyCompare(zoomOf(second(world)), zoomOf(world.native().main())),
           QStringLiteral("the first window is at %1, the second at %2").arg(zoomOf(world.native().main())).arg(zoomOf(second(world))));
  });
});

}  // namespace
