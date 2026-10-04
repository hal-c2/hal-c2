// Snap Shot on the desktop (SnapShotController): Settings, SnapShots and
// capturing a window into the draft (features/settings/snap-shot.feature,
// source-control/snap-shot.feature). The desktop portal is FakePortal, so no
// scenario touches the session bus: its shortcut answers at once, and the
// Snap Shot shortcut is FakePortal saying so.

#include <QJsonArray>
#include <QJsonObject>
#include <QRandomGenerator>

#include "ComposerController.h"
#include "DraftController.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "SnapShotBackend.h"
#include "SnapShotController.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

// What the desktop does, for FakePortal to read and record into.
struct FakeDesktop {
  bool picker = false;
  // The desktop turns down the shortcut with this.
  QString refuse;
  // The next capture fails with this.
  QString failure;
  QImage image;
  QStringList binds;
  int releases = 0;
  int configured = 0;
  // Each capture: true when the user picked the window.
  QList<bool> captures;
  QStringList played;
};

FakeDesktop& desktop() {
  static FakeDesktop state;
  return state;
}

QProcessEnvironment environment(const QString& type, const QString& current = {}) {
  QProcessEnvironment env;
  env.insert(QStringLiteral("XDG_SESSION_TYPE"), type);
  if (!current.isEmpty()) env.insert(QStringLiteral("XDG_CURRENT_DESKTOP"), current);
  return env;
}

// The trigger as a desktop names it: CTRL+SHIFT+2 is Ctrl+Shift+2.
QString describeTrigger(const QString& trigger) {
  static const QHash<QString, QString> names{{QStringLiteral("CTRL"), QStringLiteral("Ctrl")},
                                             {QStringLiteral("SHIFT"), QStringLiteral("Shift")},
                                             {QStringLiteral("ALT"), QStringLiteral("Alt")},
                                             {QStringLiteral("LOGO"), QStringLiteral("Super")}};
  QStringList parts;
  for (const QString& part : trigger.split(QLatin1Char('+'))) parts.append(names.value(part, part));
  return parts.join(QLatin1Char('+'));
}

class FakePortal : public SnapShotBackend {
public:
  FakePortal(const Platform& platform, QObject* parent) : SnapShotBackend(parent), m_desktop(platform.desktop) {}

  QString desktopName() const { return m_desktop; }

  Session session() const override {
    Session session;
    session.ready = m_probed;
    session.mode = QStringLiteral("portal");
    session.backend = desktop().picker ? QStringLiteral("picker") : QStringLiteral("screenshot-portal");
    session.desktop = m_desktop;
    return session;
  }
  Shortcut shortcut() const override { return m_shortcut; }
  void probe() override {
    if (m_probed) return;
    m_probed = true;
    emit changed();
  }
  void bind(const QString& trigger) override {
    desktop().binds.append(trigger);
    m_shortcut = {};
    if (desktop().refuse.isEmpty()) {
      m_shortcut.registered = true;
      m_shortcut.label = describeTrigger(trigger);
    } else {
      m_shortcut.message = desktop().refuse;
    }
    emit changed();
  }
  void release() override {
    ++desktop().releases;
    m_shortcut = {};
    emit changed();
  }
  void configure() override { ++desktop().configured; }
  void capture() override {
    desktop().captures.append(desktop().picker);
    if (!desktop().failure.isEmpty()) {
      emit failed(std::exchange(desktop().failure, QString()));
      return;
    }
    // The portal names no app.
    emit captured(desktop().image, QStringLiteral("Window"), QString());
  }
  void play(const QString& sound) override { desktop().played.append(sound); }

  // The user presses the Snap Shot shortcut.
  void press() { emit activated(); }

private:
  QString m_desktop;
  bool m_probed = false;
  Shortcut m_shortcut;
};

// Every shell of tst_Features gets the fake portal, on a Wayland session.
[[maybe_unused]] const bool installed = [] {
  SnapShotBackend::setEnvironment(environment(QStringLiteral("wayland")));
  SnapShotBackend::setPortalFactory(
      [](const SnapShotBackend::Platform& platform, QObject* parent) -> SnapShotBackend* { return new FakePortal(platform, parent); });
  return true;
}();

SnapShotController* controller(World& world) {
  return world.native().controller<SnapShotController>();
}

FakePortal* portal(World& world) {
  return dynamic_cast<FakePortal*>(controller(world)->backend());
}

QVariantMap snapShot(World& world) {
  return world.state(QStringLiteral("snapShot")).toMap();
}

QVariant field(World& world, const QString& path) {
  return at(snapShot(world), path);
}

void send(World& world, const QString& action, const QVariantMap& payload = {}) {
  world.bridge().dispatch(QStringLiteral("snapShot.") + action, payload);
}

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

// A fresh desktop: Wayland on no named compositor, nothing bound yet.
void resetDesktop(World& world, const QProcessEnvironment& env = environment(QStringLiteral("wayland"))) {
  desktop() = {};
  QImage image(320, 200, QImage::Format_RGB32);
  image.fill(Qt::darkCyan);
  desktop().image = image;
  SnapShotBackend::setEnvironment(env);
  world.restart();
  // The shell's controllers start once the MC has answered.
  world.connect();
  world.sync();
  // Snap Shot is Linux's, so its shortcuts are too, whatever runs the tests.
  world.native().controller<KeybindingController>()->setMac(false);
}

// A thread of "shop", open in the window.
void openThread(World& world) {
  if (!world.mc.part<FakeStreams>().thread.isEmpty()) return;
  const QJsonObject project{{QStringLiteral("id"), kProject},
                            {QStringLiteral("title"), kProject},
                            {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                            {QStringLiteral("scripts"), QJsonArray()}};
  world.mc.projects.insert(kProject, project);
  world.mc.sendRow(kProject, project, QStringLiteral("project"));
  world.sync();
  lookAtThread(world, kProject);
}

void openPanel(World& world) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::settings(SnapShotController::kSection));
  world.waitFor([&] { return field(world, QStringLiteral("ready")).toBool(); },
                [&] { return QStringLiteral("Snap Shot to be ready; it is %1").arg(show(snapShot(world))); });
}

const QJsonObject kCtrlShift2{{QStringLiteral("key"), QStringLiteral("2")}, {QStringLiteral("metaKey"), false},
                              {QStringLiteral("ctrlKey"), false},          {QStringLiteral("shiftKey"), true},
                              {QStringLiteral("altKey"), false},           {QStringLiteral("modKey"), true}};

// Snap Shot on and holding Ctrl+Shift+2.
void turnOn(World& world) {
  settings(world)->set(QStringLiteral("snapShotShortcut"), kCtrlShift2.toVariantMap());
  settings(world)->set(QStringLiteral("snapShotEnabled"), true);
  world.waitFor([&] { return field(world, QStringLiteral("shortcut.registered")).toBool(); },
                [&] { return QStringLiteral("the shortcut to be held; Snap Shot is %1").arg(show(snapShot(world))); });
}

void press(World& world, int key, Qt::KeyboardModifiers modifiers) {
  send(world, QStringLiteral("record.key"), {{QStringLiteral("key"), key}, {QStringLiteral("modifiers"), int(modifiers.toInt())}});
}

void recordCtrlShift2(World& world) {
  if (!settings(world)->setting(QStringLiteral("snapShotEnabled")).toBool()) {
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
  }
  send(world, QStringLiteral("record.start"));
  press(world, Qt::Key_At, Qt::ControlModifier | Qt::ShiftModifier);
}

void expectOff(World& world) {
  expect(!settings(world)->setting(QStringLiteral("snapShotEnabled")).toBool() && !field(world, QStringLiteral("switchOn")).toBool() &&
             field(world, QStringLiteral("status")) == QLatin1String("Turn this on to set up snapshots."),
         QStringLiteral("capture to be off and invite turning it on; Snap Shot is %1").arg(show(snapShot(world))));
}

// The raised windows and the draft's attachments, from the last capture on.
struct Seen {
  QStringList raised;
};

Seen& seen() {
  static Seen state;
  return state;
}

void capture(World& world) {
  seen() = {};
  QObject::connect(&world.bridge(), &ShellBridge::windowCommandRequested, controller(world),
                   [](const QString& command) { seen().raised.append(command); });
  expect(portal(world) != nullptr, QStringLiteral("the shell has no fake portal"));
  portal(world)->press();
}

QString threadKey(World& world) {
  return world.mc.environmentId + QLatin1Char(':') + kThread;
}

QVariantList attachments(World& world, const QString& target) {
  return world.native().controller<ComposerController>()->attachments(target);
}

// The one capture `target`'s draft holds.
QVariantMap attached(World& world, const QString& target) {
  const QVariantList images = attachments(world, target);
  expect(images.size() == 1, QStringLiteral("one capture on %1's draft, not %2").arg(target, show(images)));
  const QVariantMap image = images.first().toMap();
  expect(at(image, QStringLiteral("source.kind")) == QLatin1String("snap-shot"),
         QStringLiteral("the attachment to be a snapshot; it is %1").arg(show(image)));
  return image;
}

std::optional<QVariantMap> toastTitled(World& world, const QString& title) {
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    if (item.toMap().value(QStringLiteral("title")).toString() == title) return item.toMap();
  }
  return std::nullopt;
}

void expectToast(World& world, const QString& title, const QString& description) {
  const auto toast = toastTitled(world, title);
  expect(toast && toast->value(QStringLiteral("description")).toString() == description,
         QStringLiteral("the toast \"%1\": %2; the shell shows %3").arg(title, description, show(world.state(QStringLiteral("toasts")))));
}

// A capture of noise: no image format makes it small.
QImage noise(int width, int height) {
  QImage image(width, height, QImage::Format_RGB32);
  auto* random = QRandomGenerator::global();
  for (int y = 0; y < height; ++y) {
    auto* line = reinterpret_cast<quint32*>(image.scanLine(y));
    for (int x = 0; x < width; ++x) line[x] = random->generate() | 0xff000000;
  }
  return image;
}

const Steps steps([] {
  const QString q = kQuoted;

  // settings/snap-shot.feature
  step(QStringLiteral("the user opens Settings, SnapShots in the desktop app"), [](World& world, const Captures&, const Table&) {
    resetDesktop(world);
    openPanel(world);
  });
  step(QStringLiteral("the user never turned on Snap Shot"), [](World& world, const Captures&, const Table&) {
    expect(!settings(world)->setting(QStringLiteral("snapShotEnabled")).toBool(), QStringLiteral("Snap Shot is on"));
  });
  step(QStringLiteral("capture is off and the user is invited to turn it on to set up snapshots"),
       [](World& world, const Captures&, const Table&) { expectOff(world); });
  step(QStringLiteral("the user turns on snapshots"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), true}});
  });
  step(QStringLiteral("setup asks the user to allow capture and then to choose a shortcut"), [](World& world, const Captures&, const Table&) {
    // The portal asks for capture at the first capture, so setup opens on the
    // shortcut with allowing capture the step before it, as the web's does.
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut") &&
               field(world, QStringLiteral("wizard.heading")) == QLatin1String("Choose your shortcut"),
           QStringLiteral("setup to ask for a shortcut; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.back"));
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access") &&
               field(world, QStringLiteral("wizard.heading")) == QLatin1String("Allow snapshots"),
           QStringLiteral("setup to ask to allow capture first; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.continue"));
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut"),
           QStringLiteral("allowing capture to lead to the shortcut; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user chooses to finish later"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.closeLabel")) == QLatin1String("Finish later"),
           QStringLiteral("setup to offer finishing later; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.close"));
  });
  step(QStringLiteral("Snap Shot is on with a shortcut"), [](World& world, const Captures&, const Table&) { turnOn(world); });
  step(QStringLiteral("the user turns off snapshots"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), false}});
  });
  step(QStringLiteral("the shortcut is released and nothing that was installed is removed"), [](World& world, const Captures&, const Table&) {
    expect(desktop().releases > 0 && !field(world, QStringLiteral("shortcut.registered")).toBool(),
           QStringLiteral("the shortcut to be released; Snap Shot is %1").arg(show(snapShot(world))));
    expect(QJsonValue::fromVariant(settings(world)->setting(QStringLiteral("snapShotShortcut"))).toObject() == kCtrlShift2,
           QStringLiteral("the shortcut to stay chosen for next time"));
    expectOff(world);
  });
  step(QStringLiteral("the user changes the shortcut and presses Ctrl\\+Shift\\+2"), [](World& world, const Captures&, const Table&) {
    recordCtrlShift2(world);
    send(world, QStringLiteral("shortcut.save"));
  });
  step(QStringLiteral("the shortcut is saved as Ctrl\\+Shift\\+2"), [](World& world, const Captures&, const Table&) {
    expect(QJsonValue::fromVariant(settings(world)->setting(QStringLiteral("snapShotShortcut"))).toObject() == kCtrlShift2,
           QStringLiteral("the shortcut to be saved; it is %1").arg(show(settings(world)->setting(QStringLiteral("snapShotShortcut")))));
    expect(desktop().binds.endsWith(QStringLiteral("CTRL+SHIFT+2")) && field(world, QStringLiteral("shortcut.keys")) == QLatin1String("Ctrl+Shift+2"),
           QStringLiteral("the desktop to hold Ctrl+Shift+2; it holds %1, Snap Shot is %2").arg(desktop().binds.join(u','), show(snapShot(world))));
  });
  step(QStringLiteral("the user is recording a new shortcut"), [](World& world, const Captures&, const Table&) {
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
    send(world, QStringLiteral("record.start"));
    expect(field(world, QStringLiteral("shortcut.status")) == QLatin1String("Press your shortcut. Esc cancels."),
           QStringLiteral("the recorder to listen; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the previous shortcut is kept"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("shortcut.recording")).toBool() && !field(world, QStringLiteral("shortcut.changed")).toBool(),
           QStringLiteral("recording to stop with nothing changed; Snap Shot is %1").arg(show(snapShot(world))));
    expect(QJsonValue::fromVariant(settings(world)->setting(QStringLiteral("snapShotShortcut"))).toObject().value(QLatin1String("kind")) ==
               QLatin1String("both-shift-keys"),
           QStringLiteral("the shortcut to stay both Shift keys"));
  });
  step(QStringLiteral("the user records (a modifier with no key on Linux|a shortcut HAL-C2 already uses|a shortcut the system reserves)"),
       [](World& world, const Captures& c, const Table&) {
         settings(world)->set(QStringLiteral("snapShotEnabled"), true);
         send(world, QStringLiteral("record.start"));
         if (c[0].startsWith(QLatin1String("a modifier"))) {
           // Both Shift keys, and no key with them.
           for (const int code : {50, 62}) {
             send(world, QStringLiteral("record.modifier"),
                  {{QStringLiteral("modifier"), QStringLiteral("shift")}, {QStringLiteral("code"), code}, {QStringLiteral("down"), true}});
           }
         } else if (c[0].contains(QLatin1String("HAL-C2"))) {
           press(world, Qt::Key_O, Qt::ControlModifier | Qt::ShiftModifier);  // New thread
         } else {
           press(world, Qt::Key_L, Qt::MetaModifier);  // Super+L locks the screen
         }
       });
  step(QStringLiteral("the shortcut is refused because (.+)"), [](World& world, const Captures& c, const Table&) {
    static const QHash<QString, QString> reasons{
        {QStringLiteral("Linux shortcuts need a letter, number or function key"),
         QStringLiteral("Add a letter, number, or function key to your shortcut.")},
        {QStringLiteral("it collides with a HAL-C2 keybinding"), QStringLiteral("HAL-C2 already uses this for \"")},
        {QStringLiteral("the system reserves it"), QStringLiteral("The system already uses this shortcut.")},
    };
    const QString status = field(world, QStringLiteral("shortcut.status")).toString();
    expect(!field(world, QStringLiteral("shortcut.canSave")).toBool() && status.startsWith(reasons.value(c[0], c[0])),
           QStringLiteral("the shortcut to be refused (%1); Snap Shot is %2").arg(c[0], show(snapShot(world))));
  });
  step(QStringLiteral("the user turns sound off"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("sound"), {{QStringLiteral("value"), QStringLiteral("off")}});
  });
  step(QStringLiteral("captures happen without a sound"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("sound.label")) == QLatin1String("Off"), QStringLiteral("the sound to show Off; Snap Shot is %1").arg(show(snapShot(world))));
    openThread(world);
    turnOn(world);
    capture(world);
    attached(world, threadKey(world));
    expect(desktop().played.isEmpty(), QStringLiteral("no sound; %1 played").arg(desktop().played.join(u',')));
  });
  step(QStringLiteral("the user picks the Click sound"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("sound"), {{QStringLiteral("value"), QStringLiteral("camera-shutter")}});
  });
  step(QStringLiteral("captures play Click instead of Whoosh"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("sound.label")) == QLatin1String("Click"), QStringLiteral("the sound to show Click; Snap Shot is %1").arg(show(snapShot(world))));
    openThread(world);
    turnOn(world);
    capture(world);
    expect(desktop().played == QStringList{QStringLiteral("camera-shutter")}, QStringLiteral("Click; %1 played").arg(desktop().played.join(u',')));
  });
  step(QStringLiteral("a Niri session"), [](World& world, const Captures&, const Table&) {
    resetDesktop(world, environment(QStringLiteral("wayland"), QStringLiteral("niri")));
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
    openPanel(world);
  });
  step(QStringLiteral("the user is told capture effects are not available on Niri"), [](World& world, const Captures&, const Table&) {
    for (const QString& cue : {QStringLiteral("flash"), QStringLiteral("animations")}) {
      expect(field(world, cue + QStringLiteral(".status")) == QLatin1String("Capture effects aren't available on Niri.") &&
                 !field(world, cue + QStringLiteral(".enabled")).toBool(),
             QStringLiteral("%1 to be unavailable on Niri; Snap Shot is %2").arg(cue, show(snapShot(world))));
    }
  });
  step(QStringLiteral("the desktop will not allow the shortcut"), [](World&, const Captures&, const Table&) {
    desktop().refuse = QStringLiteral("Your desktop did not allow the shortcut.");
  });
  step(QStringLiteral("the user is told the desktop did not allow it and can ask again"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.status")) == QLatin1String("Your desktop did not allow the shortcut.") &&
               field(world, QStringLiteral("shortcut.permissions")).toBool(),
           QStringLiteral("the refusal and a way to ask again; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("shortcut.permissions"));
    expect(desktop().configured == 1, QStringLiteral("the desktop to show its shortcut permissions again"));
  });

  // source-control/snap-shot.feature
  step(QStringLiteral("the desktop app with Snap Shot turned on and its shortcut set"), [](World& world, const Captures&, const Table&) {
    resetDesktop(world);
    turnOn(world);
  });
  step(QStringLiteral("(?:the user is working in a browser with a thread open in HAL-C2|HAL-C2 is the app in front|"
                      "a Linux Wayland session with an app running under XWayland in front)"),
       [](World& world, const Captures&, const Table&) { openThread(world); });
  step(QStringLiteral("the user presses the Snap Shot shortcut(?: from another app)?"), [](World& world, const Captures&, const Table&) {
    capture(world);
  });
  step(QStringLiteral("the user captures a window"), [](World& world, const Captures&, const Table&) {
    openThread(world);
    capture(world);
  });
  step(QStringLiteral("(?:an image of the (?:browser|HAL-C2) window is attached to the (?:thread's )?draft|that app's window is captured)"),
       [](World& world, const Captures&, const Table&) {
         const QVariantMap image = attached(world, threadKey(world));
         expect(image.value(QStringLiteral("mimeType")) == QLatin1String("image/png") &&
                    image.value(QStringLiteral("name")).toString().startsWith(QLatin1String("window-")),
                QStringLiteral("a PNG of the window; the attachment is %1").arg(show(image)));
         expect(world.actionsOf(QStringLiteral("composer.focus")).size() == 1, QStringLiteral("the composer to take focus"));
       });
  step(QStringLiteral("HAL-C2 comes to the front"), [](World&, const Captures&, const Table&) {
    expect(seen().raised == QStringList{QStringLiteral("raise")}, QStringLiteral("the window to come forward; asked %1").arg(seen().raised.join(u',')));
  });
  step(QStringLiteral("no thread is open and the current project is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject project{{QStringLiteral("id"), c[0]},
                              {QStringLiteral("title"), c[0]},
                              {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]},
                              {QStringLiteral("scripts"), QJsonArray()}};
    world.mc.projects.insert(c[0], project);
    world.mc.sendRow(c[0], project, QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("a new draft in %1 holds the capture").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("draft"), QStringLiteral("a draft to show; the route is %1").arg(show(route)));
    const QString id = at(route, QStringLiteral("draftId")).toString();
    const auto draft = world.native().controller<DraftController>()->draft(id);
    expect(draft && draft->projectId == c[0], QStringLiteral("the draft to be in %1").arg(c[0]));
    attached(world, id);
  });
  step(QStringLiteral("a capture is attached to a draft that was not sent"), [](World& world, const Captures&, const Table&) {
    openThread(world);
    capture(world);
    attached(world, threadKey(world));
  });
  step(QStringLiteral("the user restarts HAL-C2"), [](World& world, const Captures&, const Table&) { world.restart(); });
  step(QStringLiteral("the capture is still attached to the draft"), [](World& world, const Captures&, const Table&) {
    const QVariantMap image = attached(world, threadKey(world));
    expect(at(image, QStringLiteral("source.appName")) == QLatin1String("Window"), QStringLiteral("the capture to keep its source; it is %1").arg(show(image)));
  });
  step(QStringLiteral("the window is too large to attach"), [](World& world, const Captures&, const Table&) {
    openThread(world);
    controller(world)->setMaxImageBytes(20 * 1024);
    desktop().image = noise(800, 600);
  });
  step(QStringLiteral("nothing is attached and the user is told the capture was too large"), [](World& world, const Captures&, const Table&) {
    expect(attachments(world, threadKey(world)).isEmpty(), QStringLiteral("nothing attached; %1").arg(show(attachments(world, threadKey(world)))));
    expectToast(world, QStringLiteral("Snapshot failed"), QStringLiteral("The captured window is too large to attach."));
  });
  step(QStringLiteral("the desktop app runs in a Linux X11 session"), [](World& world, const Captures&, const Table&) {
    resetDesktop(world, environment(QStringLiteral("x11")));
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
  });
  step(QStringLiteral("the user opens Snap Shot settings"), [](World& world, const Captures&, const Table&) {
    // On a fresh desktop when the scenario starts here (composer/qt-shell-backlog.feature).
    if (world.shellSubscriptions() == 0) resetDesktop(world);
    openPanel(world);
  });
  step(QStringLiteral("the user can record the global shortcut"), [](World& world, const Captures&, const Table&) {
    recordCtrlShift2(world);
    send(world, QStringLiteral("shortcut.save"));
    expect(QJsonValue::fromVariant(settings(world)->setting(QStringLiteral("snapShotShortcut"))).toObject() == kCtrlShift2 &&
               desktop().binds.endsWith(QStringLiteral("CTRL+SHIFT+2")) && field(world, QStringLiteral("shortcut.keys")) == QLatin1String("Ctrl+Shift+2"),
           QStringLiteral("the desktop to hold Ctrl+Shift+2; it holds %1, Snap Shot is %2").arg(desktop().binds.join(u','), show(snapShot(world))));
  });
  step(QStringLiteral("the user can see whether the desktop compositor supports it"), [](World& world, const Captures&, const Table&) {
    // This desktop captures through its portal, and the page says so.
    expect(field(world, QStringLiteral("available")).toBool() && field(world, QStringLiteral("mode")) == QLatin1String("portal") &&
               field(world, QStringLiteral("status")) == QLatin1String("Ready to capture"),
           QStringLiteral("the page to say capture is supported; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the composer is focused in HAL-C2"), [](World& world, const Captures&, const Table&) {
    // On a desktop whose own prompt asks what to capture.
    resetDesktop(world);
    turnOn(world);
    desktop().picker = true;
    openThread(world);
  });
  step(QStringLiteral("the user presses the global Snap Shot shortcut and selects a screen region"), [](World& world, const Captures&, const Table&) {
    capture(world);
    expect(desktop().captures == QList<bool>{true}, QStringLiteral("the desktop to ask what to capture"));
  });
  step(QStringLiteral("the capture is attached to that composer"), [](World& world, const Captures&, const Table&) {
    const QVariantMap image = attached(world, threadKey(world));
    const QVariantList shown = world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("attachments")).toList();
    expect(image.value(QStringLiteral("mimeType")) == QLatin1String("image/png") && shown.size() == 1 &&
               shown.first().toMap().value(QStringLiteral("id")) == image.value(QStringLiteral("id")) &&
               world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("target")) == threadKey(world),
           QStringLiteral("the composer to show the capture; it shows %1").arg(show(shown)));
    expect(world.actionsOf(QStringLiteral("composer.focus")).size() == 1, QStringLiteral("the composer to take focus"));
  });
  step(QStringLiteral("Snap Shot is shown as not supported on this platform"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("available")).toBool() && !field(world, QStringLiteral("rows")).toBool() &&
               field(world, QStringLiteral("status")).toString().contains(QLatin1String("not supported")),
           QStringLiteral("Snap Shot to be unsupported; it is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("a Linux Wayland session on another compositor"), [](World& world, const Captures&, const Table&) {
    resetDesktop(world, environment(QStringLiteral("wayland"), QStringLiteral("sway")));
  });
  step(QStringLiteral("the user sets up Snap Shot"), [](World& world, const Captures&, const Table&) {
    openPanel(world);
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), true}});
    recordCtrlShift2(world);
    send(world, QStringLiteral("setup.done"));
    expect(!field(world, QStringLiteral("wizard")).isValid() || field(world, QStringLiteral("wizard")).isNull(),
           QStringLiteral("setup to finish; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("capture works through the desktop portal"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("mode")) == QLatin1String("portal") && field(world, QStringLiteral("status")) == QLatin1String("Ready to capture") &&
               desktop().binds.endsWith(QStringLiteral("CTRL+SHIFT+2")),
           QStringLiteral("the portal to hold the shortcut; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("a Linux Wayland session on a compositor without automatic capture"), [](World& world, const Captures&, const Table&) {
    desktop().picker = true;
    openThread(world);
    openPanel(world);
    expect(field(world, QStringLiteral("status")) == QStringLiteral("Manual capture only — you'll choose a window each time"),
           QStringLiteral("capture to be manual; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user picks the window to capture"), [](World& world, const Captures&, const Table&) {
    expect(desktop().captures == QList<bool>{true}, QStringLiteral("the desktop's window picker to open"));
  });
  step(QStringLiteral("the attachment has no text or controls data"), [](World& world, const Captures&, const Table&) {
    const QVariantMap source = attached(world, threadKey(world)).value(QStringLiteral("source")).toMap();
    const QStringList keys{QStringLiteral("appName"), QStringLiteral("capturedAt"), QStringLiteral("kind"), QStringLiteral("windowTitle")};
    expect(source.keys() == keys, QStringLiteral("only the capture's source; it is %1").arg(show(source)));
  });
  step(QStringLiteral("the user cancels the desktop's capture prompt"), [](World&, const Captures&, const Table&) {
    desktop().failure = QStringLiteral("Snapshot was cancelled.");
  });
  step(QStringLiteral("nothing is attached and the user is told the snapshot was cancelled"), [](World& world, const Captures&, const Table&) {
    expect(attachments(world, threadKey(world)).isEmpty(), QStringLiteral("nothing attached; %1").arg(show(attachments(world, threadKey(world)))));
    expectToast(world, QStringLiteral("Snapshot failed"), QStringLiteral("Snapshot was cancelled."));
  });
  step(QStringLiteral("no project has been added"), [](World& world, const Captures&, const Table&) {
    expect(world.mc.projects.isEmpty(), QStringLiteral("the MC has projects"));
  });
  step(QStringLiteral("nothing is attached and the user is asked to add a project first"), [](World& world, const Captures&, const Table&) {
    expect(desktop().captures.size() == 1, QStringLiteral("the window to be captured"));
    expectToast(world, QStringLiteral("Snapshot taken, but no project is available"), QStringLiteral("Add a project, then capture the window again."));
  });
  step(QStringLiteral("Snap Shot is off"), [](World& world, const Captures&, const Table&) {
    settings(world)->set(QStringLiteral("snapShotEnabled"), false);
  });
  step(QStringLiteral("the desktop no longer holds the shortcut and nothing is captured"), [](World& world, const Captures&, const Table&) {
    expect(desktop().releases > 0 && desktop().captures.isEmpty() && attachments(world, threadKey(world)).isEmpty(),
           QStringLiteral("no capture after turning off; %1 captures").arg(desktop().captures.size()));
  });
});

}  // namespace
