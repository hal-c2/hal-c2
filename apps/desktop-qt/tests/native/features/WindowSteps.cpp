// More than one window (navigation/windows.feature): each NativeWindow has
// its own route, drafts and panels over the shell's one MC connection, and
// reopens with them after a restart until it is closed.

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QEvent>
#include <QJsonArray>

#include "ComposerController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Keymap.h"
#include "KeybindingController.h"
#include "LayoutController.h"
#include "QuitController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "NavigationController.h"
#include "Stream.h"
#include "World.h"

namespace {

const QString kFirst = QStringLiteral("t1");
const QString kSecond = QStringLiteral("t2");
const QString kStableId = QStringLiteral("stable");

QString keyOf(World& world, const QString& thread) {
  return world.mc.environmentId + QLatin1Char(':') + thread;
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
  world.mc.projects.insert(stream::kProject, {{QStringLiteral("id"), stream::kProject}, {QStringLiteral("title"), stream::kProject},
                                                {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()}});
  for (const QString& id : {kFirst, kSecond}) {
    world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("projectId"), stream::kProject},
                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                   {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  }
  world.connect();
  world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
  world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(world, kFirst)}});
  world.sync();
}

// What the user's layout (or the palette's "New window") asks for.
// The MC's subscriptions from the second window on: its own, while the
// first window stays where it is.
struct SecondWindowWork {
  qsizetype firstSub = 0;
  // Its id, once the first window closed.
  QString id;
};

QStringList toastTitles(NativeWindow* window) {
  QStringList titles;
  const QVariantList items = window->bridge()->state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
  for (const QVariant& item : items) titles.append(item.toMap().value(QStringLiteral("title")).toString());
  return titles;
}

NativeWindow* openSecond(World& world, const QVariantMap& payload = {}) {
  world.mc.part<SecondWindowWork>().firstSub = world.mc.subscriptions.size();
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

void ensureConnected(World& world) {
  if (world.shellSubscriptions() > 0) return;
  world.connect();
  world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
}

// The quit shortcut, timed on a clock the steps move.
struct QuitState {
  qint64 now = 1000;
  int quits = 0;
  bool hooked = false;
};

QuitState& quitting(World& world) {
  QuitState& state = world.mc.part<QuitState>();
  if (!state.hooked) {
    state.hooked = true;
    auto* controller = world.native().shared<QuitController>();
    controller->setClock([&state] { return state.now; });
    QObject::connect(controller, &QuitController::quitRequested, controller, [&state] { ++state.quits; });
  }
  return state;
}

void quitKey(World& world, QEvent::Type type, bool autoRepeat = false) {
  sendKey(world, type, Qt::Key_Q, Qt::ControlModifier, autoRepeat);
}

// mod goes down, then Q; `heldMs` later (auto-repeating meanwhile, as a held
// key does after half a second) Q comes up, then mod.
void pressQuit(World& world, qint64 heldMs, bool releaseMod = true) {
  QuitState& state = quitting(world);
  sendKey(world, QEvent::KeyPress, Qt::Key_Control, Qt::ControlModifier);
  quitKey(world, QEvent::KeyPress);
  const qint64 start = state.now;
  for (qint64 at = 500; at <= heldMs; at += 33) {
    state.now = start + at;
    quitKey(world, QEvent::KeyPress, true);
  }
  state.now = start + heldMs;
  quitKey(world, QEvent::KeyRelease);
  if (releaseMod) sendKey(world, QEvent::KeyRelease, Qt::Key_Control, Qt::NoModifier);
  world.sync();
}

// The quit shortcut as the platform's menus name it.
#ifdef Q_OS_MACOS
const QString kQuitKeys = QStringLiteral("⌘Q");
#else
const QString kQuitKeys = QStringLiteral("Ctrl+Q");
#endif

QString quitHint(World& world) {
  world.sync();
  return at(world.state(QStringLiteral("quitHint")), QStringLiteral("message")).toString();
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
    world.closeWindow(second(world));
  });
  // The first window closed with others open: the second becomes the main one.
  step(QStringLiteral("the user closes the first window"), [](World& world, const Captures&, const Table&) {
    if (NativeWindow* window = second(world)) {
      openIn(world, window, kSecond);
      world.mc.part<SecondWindowWork>().id = window->id();
    }
    world.closeWindow(world.native().main());
  });
  step(QStringLiteral("the second window is still open on its own thread"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const auto& windows = world.native().windows();
    const QString id = world.mc.part<SecondWindowWork>().id;
    expect(windows.size() == 1 && windows.front()->id() == id,
           QStringLiteral("%1 windows are open, the first %2").arg(windows.size()).arg(windows.front()->id()));
    expect(shownBy(windows.front().get()) == keyOf(world, kSecond),
           QStringLiteral("the second window shows %1").arg(shownBy(windows.front().get())));
    expect(!stream::followers(world, kSecond).isEmpty(), QStringLiteral("the second window stopped following its thread"));
  });
  step(QStringLiteral("the app is still running"), [](World& world, const Captures&, const Table&) {
    expect(world.lastWindowClosed == 0, QStringLiteral("the app was told its last window closed"));
  });
  step(QStringLiteral("only the second window reopens"), [](World& world, const Captures&, const Table&) {
    const auto& windows = world.native().windows();
    const QString id = world.mc.part<SecondWindowWork>().id;
    expect(windows.size() == 1 && windows.front()->id() == id,
           QStringLiteral("%1 windows reopened, the first %2").arg(windows.size()).arg(windows.front()->id()));
    NativeWindow* window = windows.front().get();
    world.waitFor([&] { return shownBy(window) == keyOf(world, kSecond); },
                  [&] { return QStringLiteral("the window to reopen on %1; it shows %2").arg(kSecond, shownBy(window)); });
  });
  step(QStringLiteral("the first window stays open on the same thread"), [](World& world, const Captures&, const Table&) {
    expect(world.native().windows().size() == 1, QStringLiteral("%1 windows are open").arg(world.native().windows().size()));
    expectFirstOn(world, kFirst);
    world.waitFor([&] { return stream::followers(world, kSecond).isEmpty(); },
                  QStringLiteral("the closed window's thread to be let go"));
    expect(!stream::followers(world, kFirst).isEmpty(), QStringLiteral("the first window stopped following its thread"));
  });

  // What main.cpp publishes on the first window's bridge when the backend fails.
  step(QStringLiteral("the backend fails"), [](World& world, const Captures&, const Table&) {
    world.bridge().publish(QStringLiteral("backendError"), QStringLiteral("the MC exited"));
  });
  step(QStringLiteral("the user opens a third window"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("window.new"), QVariantMap{});
    expect(world.native().windows().size() == 3, QStringLiteral("%1 windows are open").arg(world.native().windows().size()));
  });
  step(QStringLiteral("every window shows the failure"), [](World& world, const Captures&, const Table&) {
    for (const auto& window : world.native().windows()) {
      const QString error = window->bridge()->state()->value(QStringLiteral("backendError")).toString();
      expect(error == QLatin1String("the MC exited"), QStringLiteral("window %1 shows the error \"%2\"").arg(window->id(), error));
    }
  });

  // A failure to save settings reaches the window that asked.
  step(QStringLiteral("the MC refuses to save settings"), [](World& world, const Captures&, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    world.waitFor([settings] { return settings->ready(); }, QStringLiteral("the shell to read the MC's settings"));
    fakeConfig(world.mc).refuseWrites = QStringLiteral("The settings file is read-only.");
  });
  step(QStringLiteral("the user changes an MC setting in the second window and goes back to the first"), [](World& world, const Captures&, const Table&) {
    world.native().setActiveWindow(second(world));
    world.native().controller<SettingsController>()->set(QStringLiteral("autoResumeLimitedThreads"), true);
    world.native().setActiveWindow(world.native().main());
  });
  step(QStringLiteral("the second window says \"Setting not saved\""), [](World& world, const Captures&, const Table&) {
    NativeWindow* window = second(world);
    world.waitFor([&] { return toastTitles(window).contains(QStringLiteral("Setting not saved")); },
                  [&] { return QStringLiteral("the second window's toasts are %1").arg(toastTitles(window).join(QStringLiteral(", "))); });
  });
  step(QStringLiteral("the first window shows no toast"), [](World& world, const Captures&, const Table&) {
    const QStringList titles = toastTitles(world.native().main());
    expect(titles.isEmpty(), QStringLiteral("the first window's toasts are %1").arg(titles.join(QStringLiteral(", "))));
  });

  // Mc work in flight when a window closes (McClient's contexts).
  step(QStringLiteral("the second window is waiting on the MC"), [](World& world, const Captures&, const Table&) {
    openIn(world, second(world), kSecond);
    // A refusal would toast in the window that asked.
    world.mc.refusals.insert(QStringLiteral("thread.unsettle"), QStringLiteral("Not now"));
    world.mc.hold(QStringLiteral("answers"));
    const qsizetype sent = world.mc.commands.size();
    second(world)->bridge()->dispatch(QStringLiteral("thread.unsettle"), QVariantMap{{QStringLiteral("key"), keyOf(world, kSecond)}});
    world.waitFor([&] { return world.mc.commands.size() > sent; }, QStringLiteral("the second window's command to reach the MC"));
  });
  step(QStringLiteral("the MC answers what the closed window asked"), [](World& world, const Captures&, const Table&) {
    world.mc.answerHeld();
    // And a frame already on its way to each of the window's subscriptions.
    const QList<QJsonObject>& subs = world.mc.subscriptions;
    for (qsizetype i = world.mc.part<SecondWindowWork>().firstSub; i < subs.size(); ++i) {
      world.mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), subs.at(i).value(QLatin1String("id"))}});
    }
    world.sync();
  });
  step(QStringLiteral("the MC no longer sends the closed window anything"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QList<QJsonObject>& subs = world.mc.subscriptions;
    QStringList live;
    for (qsizetype i = world.mc.part<SecondWindowWork>().firstSub; i < subs.size(); ++i) {
      const int id = subs.at(i).value(QLatin1String("id")).toInt();
      if (!world.mc.shapeOf(id).isEmpty()) live << show(world.mc.shapeOf(id).toVariantMap());
    }
    expect(live.isEmpty(), QStringLiteral("the closed window still follows %1").arg(live.join(u", ")));
  });

  // A window's id names its folder (NativeShell's validWindowId).
  step(QStringLiteral("the shell is asked for a second window with the id \"([^\"]*)\""), [](World& world, const Captures& c, const Table&) {
    connectWithThreads(world);
    openSecond(world, {{QStringLiteral("id"), c[0]}});
  });
  step(QStringLiteral("the second window keeps its files in its own folder"), [](World& world, const Captures&, const Table&) {
    const QString id = second(world)->id();
    const QDir windows(QDir(world.homeDir()).filePath(QStringLiteral("state/shell-windows")));
    expect(!id.contains(QLatin1Char('/')) && !id.contains(QLatin1Char('.')) && windows.exists(id),
           QStringLiteral("the window is \"%1\"; the windows folder holds %2").arg(id, windows.entryList(QDir::Dirs | QDir::NoDotAndDotDot).join(u", ")));
    const QStringList home = QDir(world.homeDir()).entryList(QDir::AllEntries | QDir::NoDotAndDotDot);
    expect(!home.contains(QStringLiteral("outside")), QStringLiteral("a folder was made outside the windows folder: %1").arg(home.join(u", ")));
  });
  step(QStringLiteral("the saved windows are \"([^\"]*)\" and \"([^\"]*)\""), [](World& world, const Captures& c, const Table&) {
    QDir().mkpath(QDir(world.homeDir()).filePath(QStringLiteral("state")));
    QFile file(QDir(world.homeDir()).filePath(QStringLiteral("state/shell-windows.json")));
    expect(file.open(QIODevice::WriteOnly), QStringLiteral("the saved windows could not be written"));
    file.write(QJsonDocument(QJsonObject{{QStringLiteral("open"), QJsonArray{NativeWindow::kMain, c[0], c[1]}}}).toJson());
  });
  step(QStringLiteral("only the window \"([^\"]*)\" reopens beside the first"), [](World& world, const Captures& c, const Table&) {
    QStringList ids;
    for (const auto& window : world.native().windows()) ids << window->id();
    expect(ids.size() == 2 && ids.at(1) == c[0], QStringLiteral("the open windows are %1").arg(ids.join(u", ")));
  });

  step(QStringLiteral("the second window is signed in to the same environments"), [](World& world, const Captures&, const Table&) {
    NativeWindow* window = second(world);
    world.sync();
    QStringList keys;
    collectKeys(window->bridge()->state()->value(QStringLiteral("sidebar")), keys);
    expect(keys.contains(keyOf(world, kFirst)) && keys.contains(keyOf(world, kSecond)),
           QStringLiteral("the second window's sidebar lists %1").arg(keys.join(u", ")));
    // One connection, and so one sign-in, for every window.
    expect(world.mc.connections.size() == 1, QStringLiteral("the shell opened %1 connections").arg(world.mc.connections.size()));
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
  // Unsent work outlives the window it was typed in.
  step(QStringLiteral("the user has unsent work in the second window"), [](World& world, const Captures&, const Table&) {
    NativeWindow* window = second(world);
    openIn(world, window, kSecond);
    window->bridge()->dispatch(QStringLiteral("composer.text.set"),
                               QVariantMap{{QStringLiteral("target"), keyOf(world, kSecond)},
                                           {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                                {QStringLiteral("revision"), world.nextEdit++}}},
                                           {QStringLiteral("text"), kDraft},
                                           {QStringLiteral("cursor"), kDraft.size()}});
    // And a new thread started there.
    window->bridge()->dispatch(QStringLiteral("thread.new"), QVariantMap());
    world.sync();
    const QVariantMap route = window->bridge()->state()->value(QStringLiteral("route")).toMap();
    expect(route.value(QStringLiteral("kind")) == QLatin1String("draft"), QStringLiteral("the second window shows %1").arg(show(route)));
    world.draftId = route.value(QStringLiteral("draftId")).toString();
    window->bridge()->dispatch(QStringLiteral("composer.text.set"),
                               QVariantMap{{QStringLiteral("target"), world.draftId},
                                           {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                                {QStringLiteral("revision"), world.nextEdit++}}},
                                           {QStringLiteral("text"), kDraft},
                                           {QStringLiteral("cursor"), kDraft.size()}});
    world.sync();
  });
  step(QStringLiteral("the first window has that unsent work"), [](World& world, const Captures&, const Table&) {
    world.sync();
    auto* composer = world.native().main()->controller<ComposerController>();
    const QString text = composer->draft(keyOf(world, kSecond));
    expect(text == kDraft, QStringLiteral("the first window's draft of the thread is \"%1\"").arg(text));
    const QString draftText = composer->draft(world.draftId);
    expect(draftText == kDraft, QStringLiteral("the first window's new-thread draft is \"%1\"").arg(draftText));
    world.bridge().dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), world.draftId}});
    world.sync();
    const QString shown = at(world.state(QStringLiteral("composer")), QStringLiteral("text")).toString();
    expect(shown == kDraft, QStringLiteral("the first window's composer on the new thread shows \"%1\"").arg(shown));
  });

  step(QStringLiteral("the user restarts the app"), [](World& world, const Captures&, const Table&) {
    world.restart();
    world.connect();
    world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
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
    // The first window kept its own route, and sees the same drafts.
    expectFirstOn(world, kFirst);
    const QString first = world.native().main()->controller<ComposerController>()->draft(keyOf(world, kSecond));
    expect(first == kDraft, QStringLiteral("the first window's draft of the thread is \"%1\"").arg(first));
  });

  // The app's zoom (the application menu's mod+=, mod++, mod+-, mod+0).
  step(QStringLiteral("the app is zoomed in"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
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

  // Quitting (QuitController, `confirmQuit`).
  step(QStringLiteral("the quit shortcut is set to (Hold|Double press|Direct)"), [](World& world, const Captures& c, const Table&) {
    const QString mode = c[0] == u"Hold" ? QStringLiteral("hold") : c[0] == u"Direct" ? QStringLiteral("direct") : QStringLiteral("double-click");
    world.native().controller<SettingsController>()->set(QStringLiteral("confirmQuit"), mode);
    quitting(world);
  });
  step(QStringLiteral("the user holds mod\\+Q for 1.2 seconds"), [](World& world, const Captures&, const Table&) {
    pressQuit(world, QuitController::kHoldMs + 40);
  });
  step(QStringLiteral("the user presses mod\\+Q twice within 500 milliseconds"), [](World& world, const Captures&, const Table&) {
    pressQuit(world, 80, false);
    quitting(world).now += 220;
    pressQuit(world, 80);
  });
  step(QStringLiteral("the user presses mod\\+Q once"), [](World& world, const Captures&, const Table&) {
    pressQuit(world, 80);
  });
  step(QStringLiteral("the user chooses Quit from the command palette"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
    quitting(world);
    expect(world.native().controller<KeybindingController>()->commands()->run(QuitController::kQuit),
           QStringLiteral("there is no Quit command"));
  });
  step(QStringLiteral("the app quits"), [](World& world, const Captures&, const Table&) {
    // By the quit shortcut, or by closing the last window (main.cpp quits on
    // lastWindowClosed).
    const int quits = world.lastWindowClosed > 0 ? world.lastWindowClosed : quitting(world).quits;
    expect(quits == 1, QStringLiteral("the app was asked to quit %1 times").arg(quits));
  });
  step(QStringLiteral("the app keeps running"), [](World& world, const Captures&, const Table&) {
    expect(quitting(world).quits == 0, QStringLiteral("the app was asked to quit"));
  });
  step(QStringLiteral("the user is told to hold the shortcut or press twice to quit"), [](World& world, const Captures&, const Table&) {
    const QString hint = quitHint(world);
    expect(hint == QStringLiteral("Hold %1 or press twice to quit").arg(kQuitKeys), QStringLiteral("the hint says \"%1\"").arg(hint));
  });
  step(QStringLiteral("the user is told to press the shortcut again to quit"), [](World& world, const Captures&, const Table&) {
    const QString hint = quitHint(world);
    expect(hint == QStringLiteral("Press %1 again to quit").arg(kQuitKeys), QStringLiteral("the hint says \"%1\"").arg(hint));
  });
});

}  // namespace
