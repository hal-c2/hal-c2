// Snap Shot on the desktop (SnapShotController): Settings, SnapShots and
// capturing a window into the draft (features/settings/snap-shot.feature,
// source-control/snap-shot.feature). The desktop is FakePortal, whose
// shortcut answers at once, unless a scenario's desktop "gives shortcuts
// through the desktop portal": then it is PortalSnapShot itself, talking to
// FakeDesktopPortal on a bus of the test's own.

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QRandomGenerator>

#include "ComposerController.h"
#include "FakeDesktopPortal.h"
#include "DraftController.h"
#include "Harness.h"
#include "HelperSnapShot.h"
#include "KeybindingController.h"
#include "MacPlatform.h"
#include "NativeShell.h"
#include "NavigationController.h"
#ifdef HAL_C2_HAS_DBUS
#include "PortalSnapShot.h"
#endif
#include "SettingsController.h"
#include "GnomeSnapShot.h"
#include "SnapShotBackend.h"
#include "SnapShotController.h"
#include "Stream.h"
#include "World.h"

// SnapShotMacosSteps.cpp: the shortcut pressed when the scenario runs on a Mac.
void snapShotMacPress(World& world);

namespace snapshot {
void resetCaptureHelpers();
void uninstallCaptureHelpers(World& world);
}

namespace {

using namespace stream;

// What the desktop does, for FakePortal to read and record into.
struct FakeDesktop {
  bool picker = false;
  // Why capture access is not ready, if it is not.
  QString message;
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
  // Shortcut checks wait for answerCheck(), in the order they were asked.
  bool holdChecks = false;
  QList<std::function<void(const SnapShotBackend::Check&)>> checks;
  // The desktop will not pause the capture shortcut, with this reason.
  std::optional<QString> refusePause;
  // The desktop does not answer a shortcut's bind.
  bool holdShortcuts = false;
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
    session.message = desktop().message;
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
    if (desktop().holdShortcuts) {
      m_shortcut.pending = true;
    } else if (desktop().refuse.isEmpty()) {
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
  void checkShortcut(const QJsonObject& shortcut, std::function<void(const Check&)> done) override {
    if (desktop().holdChecks) {
      desktop().checks.append(std::move(done));
      return;
    }
    SnapShotBackend::checkShortcut(shortcut, std::move(done));
  }
  bool pause(bool paused, QString* reason) override {
    if (!paused || !desktop().refusePause) return true;
    *reason = *desktop().refusePause;
    return false;
  }
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
  // The desktop's answers changed (FakeDesktop).
  void update() { emit changed(); }

private:
  QString m_desktop;
  bool m_probed = false;
  Shortcut m_shortcut;
};

// The shell's desktop is PortalSnapShot on FakeDesktopPortal, not FakePortal.
bool& throughPortal() {
  static bool on = false;
  return on;
}

// Every shell of tst_Features gets the fake portal, on a Wayland session.
[[maybe_unused]] const bool installed = [] {
  SnapShotBackend::setEnvironment(environment(QStringLiteral("wayland")));
  SnapShotBackend::setPortalFactory([](const SnapShotBackend::Platform& platform, QObject* parent) -> SnapShotBackend* {
#ifdef HAL_C2_HAS_DBUS
    if (throughPortal()) return new PortalSnapShot(platform, parent);
#endif
    return new FakePortal(platform, parent);
  });
  return true;
}();

SnapShotController* controller(World& world) {
  return world.native().controller<SnapShotController>();
}

FakePortal* portal(World& world) {
  SnapShotBackend* backend = controller(world)->backend();
  // KDE and Hyprland hold their shortcut in the portal behind the capture helper.
  if (auto* helper = dynamic_cast<HelperSnapShot*>(backend)) backend = helper->shortcuts();
  if (auto* gnome = dynamic_cast<GnomeSnapShot*>(backend)) backend = gnome->portal();
  return dynamic_cast<FakePortal*>(backend);
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

FakeDesktopPortal& bus() {
  return FakeDesktopPortal::instance();
}

// A fresh desktop: Wayland on no named compositor, nothing bound yet; through
// the desktop portal on the test's bus, answering as `portal` does, with one.
void resetDesktop(World& world, const QProcessEnvironment& env = environment(QStringLiteral("wayland")),
                  const std::optional<PortalDesktop>& portal = std::nullopt, const SnapShotBackend::GnomeFactory& gnome = {},
                  bool picker = false) {
  desktop() = {};
  snapshot::resetCaptureHelpers();
  desktop().picker = picker;
  SnapShotBackend::setGnomeFactory(gnome);
  throughPortal() = portal.has_value();
  if (portal) {
    bus().reset();
    bus().desktop = *portal;
  }
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
  if (desktop().holdShortcuts) return;
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

// The user saves the shortcut they recorded.
void save(World& world) {
  expect(field(world, QStringLiteral("shortcut.canSave")).toBool(), QStringLiteral("the shortcut to be ready to save; Snap Shot is %1").arg(show(snapShot(world))));
  send(world, QStringLiteral("shortcut.save"));
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
  if (MacPlatform::overridden()) return snapShotMacPress(world);
  seen() = {};
  QObject::connect(&world.bridge(), &ShellBridge::windowCommandRequested, controller(world),
                   [](const QString& command) { seen().raised.append(command); });
  // A real backend (NiriSnapShot) hears its shortcut the same way.
  if (portal(world)) {
    portal(world)->press();
  } else {
    emit controller(world)->backend()->activated();
  }
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

const QJsonObject kCtrlShift1{{QStringLiteral("key"), QStringLiteral("1")}, {QStringLiteral("metaKey"), false},
                              {QStringLiteral("ctrlKey"), false},          {QStringLiteral("shiftKey"), true},
                              {QStringLiteral("altKey"), false},           {QStringLiteral("modKey"), true}};

// Snap Shot on with `shortcut`, without waiting on the desktop's answer.
void turnOnWith(World& world, const QJsonObject& shortcut = kCtrlShift2) {
  settings(world)->set(QStringLiteral("snapShotShortcut"), shortcut.toVariantMap());
  settings(world)->set(QStringLiteral("snapShotEnabled"), true);
}

// A desktop that captures and gives shortcuts through the desktop portal,
// answering as `portal` says, with Settings, SnapShots open.
void portalDesktop(World& world, const PortalDesktop& portal = {}) {
  resetDesktop(world, environment(QStringLiteral("wayland")), portal);
  openPanel(world);
}

void waitForField(World& world, const QString& path, const QVariant& value) {
  world.waitFor([&] { return field(world, path) == value; },
                [&] { return QStringLiteral("%1 to be %2; Snap Shot is %3").arg(path, show(value), show(snapShot(world))); });
}

// The desktop's answers to FakePortal changed.
void update(World& world) {
  expect(portal(world) != nullptr, QStringLiteral("the shell has no fake portal"));
  portal(world)->update();
}

bool hasWizard(World& world) {
  return field(world, QStringLiteral("wizard")).toMap().contains(QStringLiteral("step"));
}

// The keys of a shortcut as the feature names it.
void pressNamed(World& world, const QString& name) {
  static const QHash<QString, QPair<int, Qt::KeyboardModifiers>> keys{
      {QStringLiteral("Shift+K"), {Qt::Key_K, Qt::ShiftModifier}},  {QStringLiteral("Ctrl+C"), {Qt::Key_C, Qt::ControlModifier}},
      {QStringLiteral("Ctrl+S"), {Qt::Key_S, Qt::ControlModifier}}, {QStringLiteral("Ctrl+Z"), {Qt::Key_Z, Qt::ControlModifier}},
      {QStringLiteral("Alt+Tab"), {Qt::Key_Tab, Qt::AltModifier}},  {QStringLiteral("Super+L"), {Qt::Key_L, Qt::MetaModifier}},
      {QStringLiteral("Ctrl+Alt+K"), {Qt::Key_K, Qt::ControlModifier | Qt::AltModifier}},
  };
  expect(keys.contains(name), QStringLiteral("no keys for %1").arg(name));
  press(world, keys.value(name).first, keys.value(name).second);
}

std::optional<QVariantMap> toastSaying(World& world, const QString& description) {
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    if (item.toMap().value(QStringLiteral("description")).toString() == description) return item.toMap();
  }
  return std::nullopt;
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
    // shortcut with allowing capture the step before it.
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
    // Close, once Snap Shot was on before setup opened.
    const QString close = field(world, QStringLiteral("wizard.closeLabel")).toString();
    expect(close == QLatin1String("Finish later") || close == QLatin1String("Close"),
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
  });
  step(QStringLiteral("the shortcut is saved as Ctrl\\+Shift\\+2"), [](World& world, const Captures&, const Table&) {
    // The recorded keys are the shortcut once the user saves them.
    save(world);
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
    save(world);
    expect(field(world, QStringLiteral("shortcut.status")) == QLatin1String("Your desktop did not allow the shortcut.") &&
               field(world, QStringLiteral("shortcut.permissions")).toBool(),
           QStringLiteral("the refusal and a way to ask again; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("shortcut.permissions"));
    expect(desktop().configured == 1, QStringLiteral("the desktop to show its shortcut permissions again"));
  });

  // The panel's rows.
  step(QStringLiteral("Snap Shot is (still being checked|on with only a manual window picker available|"
                      "on and waiting for the user to approve the shortcut|on with a shortcut that has been seen to work|"
                      "on with no shortcut chosen yet|on but the desktop reports a problem)"),
       [](World& world, const Captures& c, const Table&) {
         if (c[0] == QLatin1String("still being checked")) {
           PortalDesktop portal;
           portal.holdScreenshot = true;
           resetDesktop(world, environment(QStringLiteral("wayland")), portal);
           // The panel asks, and the desktop has not answered.
           world.native().controller<NavigationController>()->open(NavigationController::Route::settings(SnapShotController::kSection));
           world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("section")) == SnapShotController::kSection; },
                         [&] { return QStringLiteral("Settings, SnapShots to open; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
         } else if (c[0].contains(QLatin1String("window picker"))) {
           desktop().picker = true;
           turnOn(world);
         } else if (c[0].contains(QLatin1String("approve"))) {
           PortalDesktop portal;
           portal.bind = PortalAnswer::Hold;
           portalDesktop(world, portal);
           turnOnWith(world);
           world.waitFor([] { return bus().prompting(); }, QStringLiteral("the desktop to prompt for the shortcut"));
         } else if (c[0].contains(QLatin1String("seen to work"))) {
           turnOn(world);
         } else if (c[0].contains(QLatin1String("no shortcut"))) {
           settings(world)->set(QStringLiteral("snapShotEnabled"), true);
         } else {
           turnOn(world);
           desktop().message = QStringLiteral("Your desktop could not say whether it can capture windows.");
           update(world);
         }
       });
  step(QStringLiteral("the capture row reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForField(world, QStringLiteral("status"), c[0]);
  });
  step(QStringLiteral("the desktop reports that capture is not supported on this platform"), [](World& world, const Captures&, const Table&) {
    resetDesktop(world, environment(QStringLiteral("x11")));
    openPanel(world);
  });
  step(QStringLiteral("the capture row says the desktop's reason, or \"Not supported on this platform\\.\""),
       [](World& world, const Captures&, const Table&) {
         expect(!field(world, QStringLiteral("available")).toBool() && !field(world, QStringLiteral("status")).toString().isEmpty(),
                QStringLiteral("the row to say why capture is not supported; Snap Shot is %1").arg(show(snapShot(world))));
       });
  step(QStringLiteral("capture cannot be turned on"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), true}});
    expect(!settings(world)->setting(QStringLiteral("snapShotEnabled")).toBool() && !hasWizard(world) &&
               !field(world, QStringLiteral("switchOn")).toBool(),
           QStringLiteral("capture to stay off with no setup; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("Snap Shot is on and setup is not finished on (GNOME|KDE Plasma|a desktop HAL-C2 cannot name)"),
       [](World& world, const Captures& c, const Table&) {
         const QString current = c[0] == QLatin1String("GNOME") ? QStringLiteral("GNOME") : c[0] == QLatin1String("KDE Plasma") ? QStringLiteral("KDE") : QStringLiteral("sway");
         resetDesktop(world, environment(QStringLiteral("wayland"), current));
         // KDE's setup is its capture helper.
         if (current == QLatin1String("KDE")) snapshot::uninstallCaptureHelpers(world);
         openPanel(world);
         desktop().message = QStringLiteral("Your desktop could not say whether it can capture windows.");
         turnOn(world);
         update(world);
       });
  step(QStringLiteral("the setup button reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForField(world, QStringLiteral("setupLabel"), c[0]);
  });
  step(QStringLiteral("capture access is in place"), [](World& world, const Captures&, const Table&) { turnOn(world); });
  step(QStringLiteral("it reopens setup to revisit access or the shortcut"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.open"));
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut"), QStringLiteral("setup to open on the shortcut; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.back"));
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access"), QStringLiteral("setup to go back to access; Snap Shot is %1").arg(show(snapShot(world))));
  });

  // The shortcut.
  step(QStringLiteral("Snap Shot is on with the shortcut Ctrl\\+Shift\\+1"), [](World& world, const Captures&, const Table&) {
    turnOnWith(world, kCtrlShift1);
    waitForField(world, QStringLiteral("shortcut.registered"), true);
  });
  step(QStringLiteral("the panel shows Ctrl\\+Shift\\+2 with Save and Cancel"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.keys")) == QLatin1String("Ctrl+Shift+2") && field(world, QStringLiteral("shortcut.changed")).toBool() &&
               field(world, QStringLiteral("shortcut.canSave")).toBool(),
           QStringLiteral("Ctrl+Shift+2 to wait for Save or Cancel; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the shortcut in use is still Ctrl\\+Shift\\+1"), [](World& world, const Captures&, const Table&) {
    expect(QJsonValue::fromVariant(settings(world)->setting(QStringLiteral("snapShotShortcut"))).toObject() == kCtrlShift1 &&
               desktop().binds == QStringList{QStringLiteral("CTRL+SHIFT+1")},
           QStringLiteral("Ctrl+Shift+1 to stay in use; the desktop holds %1").arg(desktop().binds.join(u',')));
  });
  step(QStringLiteral("the panel shows Ctrl\\+Shift\\+1 again and nothing changed"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.keys")) == QLatin1String("Ctrl+Shift+1") && !field(world, QStringLiteral("shortcut.changed")).toBool() &&
               desktop().binds == QStringList{QStringLiteral("CTRL+SHIFT+1")},
           QStringLiteral("Ctrl+Shift+1 back with nothing changed; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user is changing the shortcut"), [](World& world, const Captures&, const Table&) {
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
    send(world, QStringLiteral("record.start"));
  });
  step(QStringLiteral("(recording starts|the desktop says the shortcut is free|the shortcut is one HAL-C2 uses for \"Terminal: Toggle\"|"
                      "the user presses only modifier keys on a Wayland desktop)"),
       [](World& world, const Captures& c, const Table&) {
         if (c[0].contains(QLatin1String("free"))) {
           press(world, Qt::Key_At, Qt::ControlModifier | Qt::ShiftModifier);
         } else if (c[0].contains(QLatin1String("Terminal: Toggle"))) {
           press(world, Qt::Key_J, Qt::ControlModifier);
         } else if (c[0].contains(QLatin1String("modifier"))) {
           for (const int code : {50, 62}) {
             send(world, QStringLiteral("record.modifier"),
                  {{QStringLiteral("modifier"), QStringLiteral("shift")}, {QStringLiteral("code"), code}, {QStringLiteral("down"), true}});
           }
         }
       });
  step(QStringLiteral("the shortcut row says \"(.*)\""), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return field(world, QStringLiteral("shortcut.status")) == c[0] || field(world, QStringLiteral("shortcut.description")) == c[0]; },
                  [&] { return QStringLiteral("the shortcut row to say %1; Snap Shot is %2").arg(c[0], show(snapShot(world))); });
  });
  step(QStringLiteral("a desktop that gives shortcuts through the desktop portal"), [](World& world, const Captures&, const Table&) {
    portalDesktop(world);
  });
  step(QStringLiteral("no shortcut is saved yet"), [](World& world, const Captures&, const Table&) {
    expect(!settings(world)->setting(QStringLiteral("snapShotShortcut")).isValid() ||
               QJsonValue::fromVariant(settings(world)->setting(QStringLiteral("snapShotShortcut"))).toObject().value(QLatin1String("kind")) ==
                   QLatin1String("both-shift-keys"),
           QStringLiteral("a shortcut is saved"));
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
  });
  step(QStringLiteral("the shortcut row suggests a shortcut such as Ctrl\\+Shift\\+2"), [](World& world, const Captures&, const Table&) {
    waitForField(world, QStringLiteral("shortcut.status"), QStringLiteral("Try a shortcut such as Ctrl+Shift+2."));
  });
  step(QStringLiteral("pressing both Shift keys is not offered as the shortcut"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.keys")) == QLatin1String("Choose shortcut") && bus().triggers.isEmpty(),
           QStringLiteral("no shortcut to be offered; the desktop was asked for %1, Snap Shot is %2").arg(bus().triggers.join(u','), show(snapShot(world))));
  });
  step(QStringLiteral("the user starts recording a new shortcut and presses the current one"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("record.start"));
    capture(world);
  });
  step(QStringLiteral("no capture starts"), [](World&, const Captures&, const Table&) {
    expect(desktop().captures.isEmpty(), QStringLiteral("no capture; %1 were taken").arg(desktop().captures.size()));
  });
  step(QStringLiteral("pausing the capture shortcut ends when recording ends, is cancelled, or the panel closes"),
       [](World& world, const Captures&, const Table&) {
         const auto captures = [&](qsizetype count, const QString& after) {
           capture(world);
           expect(desktop().captures.size() == count, QStringLiteral("the shortcut to capture again once %1; %2 captures").arg(after).arg(desktop().captures.size()));
         };
         pressNamed(world, QStringLiteral("Ctrl+Alt+K"));
         captures(1, QStringLiteral("recording ends"));
         send(world, QStringLiteral("record.start"));
         send(world, QStringLiteral("record.cancel"));
         captures(2, QStringLiteral("recording is cancelled"));
         send(world, QStringLiteral("record.start"));
         world.native().controller<NavigationController>()->open(NavigationController::Route::settings());
         captures(3, QStringLiteral("the panel closes"));
       });
  step(QStringLiteral("the user presses Tab, holds a key down, or presses a modifier on its own"), [](World& world, const Captures&, const Table&) {
    press(world, Qt::Key_Tab, Qt::NoModifier);
    press(world, Qt::Key_Backtab, Qt::ShiftModifier);
    send(world, QStringLiteral("record.key"),
         {{QStringLiteral("key"), int(Qt::Key_At)}, {QStringLiteral("modifiers"), int((Qt::ControlModifier | Qt::ShiftModifier).toInt())}, {QStringLiteral("repeat"), true}});
    press(world, Qt::Key_Control, Qt::ControlModifier);
    send(world, QStringLiteral("record.modifier"), {{QStringLiteral("modifier"), QStringLiteral("control")}, {QStringLiteral("code"), 37}, {QStringLiteral("down"), true}});
  });
  step(QStringLiteral("no shortcut is recorded"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.recording")).toBool() && !field(world, QStringLiteral("shortcut.changed")).toBool() &&
               field(world, QStringLiteral("shortcut.status")) == QLatin1String("Press your shortcut. Esc cancels."),
           QStringLiteral("the recorder to keep listening; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the desktop shows a portal shortcut that was refused or never granted"), [](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.bind = PortalAnswer::Refuse;
    portalDesktop(world, portal);
    turnOnWith(world);
    waitForField(world, QStringLiteral("shortcut.status"), QStringLiteral("Shortcut permission wasn't granted. Open shortcut permissions to allow it."));
    expect(field(world, QStringLiteral("shortcut.permissions")).toBool(), QStringLiteral("Shortcut permissions to be offered; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user chooses Shortcut permissions"), [](World& world, const Captures&, const Table&) {
    bus().desktop.bind = PortalAnswer::Hold;
    send(world, QStringLiteral("shortcut.permissions"));
  });
  step(QStringLiteral("the desktop asks for the shortcut again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([] { return bus().prompting(); }, [] { return QStringLiteral("the desktop to prompt again; it was asked for %1").arg(bus().triggers.join(u',')); });
    expect(bus().triggers.size() == 2, QStringLiteral("a second request; the desktop was asked for %1").arg(bus().triggers.join(u',')));
  });
  step(QStringLiteral("the button is disabled while its prompt is pending"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.permissions")).toBool() && !field(world, QStringLiteral("shortcut.permissionsEnabled")).toBool(),
           QStringLiteral("Shortcut permissions to wait on the prompt; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the row says %1 while it is").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("shortcut.pending")).toBool() && field(world, QStringLiteral("shortcut.status")) == c[0],
           QStringLiteral("the row to say %1 while the prompt is open; Snap Shot is %2").arg(c[0], show(snapShot(world))));
  });
  step(QStringLiteral("the shortcut is a modifier pair, or the desktop says asking again changes nothing"), [](World& world, const Captures&, const Table&) {
    // The first portal version cannot show its shortcut permissions again.
    PortalDesktop portal;
    portal.shortcutsVersion = 1;
    portal.bind = PortalAnswer::Refuse;
    portalDesktop(world, portal);
    turnOnWith(world);
    waitForField(world, QStringLiteral("shortcut.status"),
                 QStringLiteral("Shortcut permission wasn't granted. Allow HAL-C2 in your desktop's shortcut settings."));
  });
  step(QStringLiteral("there is no Shortcut permissions button"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("shortcut.permissions")).toBool(),
           QStringLiteral("no Shortcut permissions where the desktop cannot ask again; Snap Shot is %1").arg(show(snapShot(world))));
    settings(world)->set(QStringLiteral("snapShotShortcut"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("both-shift-keys")}});
    expect(!field(world, QStringLiteral("shortcut.permissions")).toBool(),
           QStringLiteral("no Shortcut permissions for a modifier pair; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the desktop reports a shortcut HAL-C2 cannot read"), [](World& world, const Captures&, const Table&) {
    turnOnWith(world, QJsonObject{{QStringLiteral("trigger"), QStringLiteral("…")}});
  });
  step(QStringLiteral("the shortcut row says \"Change shortcut\" instead of showing keys"), [](World& world, const Captures&, const Table&) {
    waitForField(world, QStringLiteral("shortcut.keys"), QStringLiteral("Change shortcut"));
  });
  step(QStringLiteral("recording a new one replaces it"), [](World& world, const Captures&, const Table&) {
    recordCtrlShift2(world);
    save(world);
    expect(QJsonValue::fromVariant(settings(world)->setting(QStringLiteral("snapShotShortcut"))).toObject() == kCtrlShift2 &&
               field(world, QStringLiteral("shortcut.keys")) == QLatin1String("Ctrl+Shift+2"),
           QStringLiteral("Ctrl+Shift+2 to replace it; Snap Shot is %1").arg(show(snapShot(world))));
  });

  // App text and the capture cues.
  step(QStringLiteral("a Linux desktop that only provides a screenshot"), [](World& world, const Captures&, const Table&) {
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
  });
  step(QStringLiteral("including app text is off and cannot be turned on"), [](World& world, const Captures&, const Table&) {
    const QVariant before = settings(world)->setting(QStringLiteral("snapShotIncludeAccessibility"));
    send(world, QStringLiteral("set"), {{QStringLiteral("key"), QStringLiteral("accessibility")}, {QStringLiteral("value"), true}});
    expect(!field(world, QStringLiteral("accessibility.checked")).toBool() && !field(world, QStringLiteral("accessibility.enabled")).toBool() &&
               settings(world)->setting(QStringLiteral("snapShotIncludeAccessibility")) == before,
           QStringLiteral("app text to stay off; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the panel says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("accessibility.status")) == c[0] || field(world, QStringLiteral("shortcut.status")) == c[0], QStringLiteral("the panel to say %1; Snap Shot is %2").arg(c[0], show(snapShot(world))));
  });
  step(QStringLiteral("the user's settings cannot be written"), [](World& world, const Captures&, const Table&) {
    // A file where the preferences' folder would be.
    const QString blocker = QDir(world.configDir()).filePath(QStringLiteral("not-a-folder"));
    QDir().mkpath(world.configDir());
    QFile file(blocker);
    expect(file.open(QIODevice::WriteOnly), QStringLiteral("cannot write %1").arg(blocker));
    file.close();
    settings(world)->setDevicePath(QDir(blocker).filePath(QStringLiteral("preferences.json")));
  });
  step(QStringLiteral("the user turns off the capture sound"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("sound"), {{QStringLiteral("value"), QStringLiteral("off")}});
  });
  step(QStringLiteral("the sound is still on"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("sound.value")) == QLatin1String("soft-pop") && settings(world)->setting(QStringLiteral("snapShotPlaySound")).toBool(),
           QStringLiteral("the sound to stay on; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user is told the save failed with the reason"), [](World& world, const Captures&, const Table&) {
    const auto toast = toastTitled(world, QStringLiteral("Setting not saved"));
    expect(toast && toast->value(QStringLiteral("description")).toString().startsWith(QLatin1String("Cannot save ")),
           QStringLiteral("the save's failure and why; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("the user opens the capture sound choices"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("the choices are Off, \"Whoosh \\(Default\\)\" and Click"), [](World& world, const Captures&, const Table&) {
    QStringList labels;
    for (const QVariant& choice : field(world, QStringLiteral("sound.choices")).toList()) labels.append(choice.toMap().value(QStringLiteral("label")).toString());
    expect(labels == QStringList{QStringLiteral("Off"), QStringLiteral("Whoosh (Default)"), QStringLiteral("Click")},
           QStringLiteral("Off, Whoosh and Click; the choices are %1").arg(labels.join(u',')));
  });
  step(QStringLiteral("the current choice is shown on the row as (Off|Whoosh \\(Default\\)|Click)"), [](World& world, const Captures& c, const Table&) {
    for (const QVariant& choice : field(world, QStringLiteral("sound.choices")).toList()) {
      if (choice.toMap().value(QStringLiteral("label")) == c[0]) send(world, QStringLiteral("sound"), {{QStringLiteral("value"), choice.toMap().value(QStringLiteral("value"))}});
    }
    expect(field(world, QStringLiteral("sound.label")) == c[0], QStringLiteral("the row to show %1; Snap Shot is %2").arg(c[0], show(snapShot(world))));
  });
  step(QStringLiteral("a Linux session where any other desktop but Niri"), [](World& world, const Captures&, const Table&) {
    resetDesktop(world, environment(QStringLiteral("wayland"), QStringLiteral("sway")));
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
    openPanel(world);
    // The flash and animation rows say it (TurnSteps' "the user is told").
    world.toldInPlace = [&world] {
      return QStringList{field(world, QStringLiteral("flash.status")).toString(), field(world, QStringLiteral("animations.status")).toString()};
    };
  });
  step(QStringLiteral("a desktop that gives only a window picker"), [](World& world, const Captures&, const Table&) {
    desktop().picker = true;
    turnOn(world);
    update(world);
  });
  step(QStringLiteral("the capture row says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("description")) == c[0], QStringLiteral("the capture row to say %1; Snap Shot is %2").arg(c[0], show(snapShot(world))));
  });

  // Catching up with the desktop.
  step(QStringLiteral("the panel is open"), [](World& world, const Captures&, const Table&) {
    portalDesktop(world);
    turnOnWith(world);
    waitForField(world, QStringLiteral("shortcut.registered"), true);
    expect(field(world, QStringLiteral("status")) == QLatin1String("Ready to capture"), QStringLiteral("capture to be ready; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user returns to the app after changing capture access or the shortcut outside it"), [](World&, const Captures&, const Table&) {
    bus().desktop.windowCapture = false;
    emit qGuiApp->applicationStateChanged(Qt::ApplicationActive);
  });
  step(QStringLiteral("the panel shows the current state without being reopened"), [](World& world, const Captures&, const Table&) {
    waitForField(world, QStringLiteral("status"), QStringLiteral("Manual capture only — you'll choose a window each time"));
  });
  step(QStringLiteral("it does the same when the desktop reports the shortcut changed"), [](World& world, const Captures&, const Table&) {
    bus().changeShortcut(QStringLiteral("Ctrl+Alt+S"));
    waitForField(world, QStringLiteral("shortcut.keys"), QStringLiteral("Ctrl+Alt+S"));
    expect(field(world, QStringLiteral("shortcut.status")) == QLatin1String("Desktop shortcut: Ctrl+Alt+S"),
           QStringLiteral("the row to show the desktop's shortcut; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user asked for shortcut permission and the desktop failed"), [](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.sessionFails = true;
    portalDesktop(world, portal);
    turnOnWith(world);
    waitForField(world, QStringLiteral("shortcut.status"), QStringLiteral("Your desktop could not create a capture shortcut session."));
  });
  step(QStringLiteral("the user is told what went wrong once"), [](World& world, const Captures&, const Table&) {
    expect(!toastSaying(world, QStringLiteral("Your desktop could not create a capture shortcut session.")) && !hasWizard(world),
           QStringLiteral("the failure on the shortcut row alone; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("the user can ask (?:again|for the shortcut again)"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.permissions")).toBool(), QStringLiteral("a way to ask again; Snap Shot is %1").arg(show(snapShot(world))));
    // The desktop works again.
    bus().reset();
    send(world, QStringLiteral("shortcut.permissions"));
    waitForField(world, QStringLiteral("shortcut.registered"), true);
  });

  // Setup.
  step(QStringLiteral("setup is open and a step fails"), [](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.screenshotFails = true;
    portalDesktop(world, portal);
    send(world, QStringLiteral("setup.open"));
  });
  step(QStringLiteral("the error is shown in setup"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access") &&
               field(world, QStringLiteral("wizard.details")) == QLatin1String("Your desktop could not say whether it can capture windows."),
           QStringLiteral("setup to show the failure; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("closing setup does not repeat it in the panel"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.close"));
    expect(!hasWizard(world) && !toastSaying(world, QStringLiteral("Your desktop could not say whether it can capture windows.")) &&
               field(world, QStringLiteral("status")) == QLatin1String("Turn this on to set up snapshots."),
           QStringLiteral("the failure to go with setup; Snap Shot is %1, the shell shows %2").arg(show(snapShot(world)), show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("Snap Shot was off and the user opened setup"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.open"));
    expect(hasWizard(world), QStringLiteral("setup to open; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("capture is off again"), [](World& world, const Captures&, const Table&) { expectOff(world); });
  step(QStringLiteral("Snap Shot was on and the user opened setup to change something"), [](World& world, const Captures&, const Table&) {
    turnOn(world);
    send(world, QStringLiteral("setup.open"));
    expect(hasWizard(world), QStringLiteral("setup to open; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("capture is still on"), [](World& world, const Captures&, const Table&) {
    expect(!hasWizard(world) && settings(world)->setting(QStringLiteral("snapShotEnabled")).toBool() &&
               field(world, QStringLiteral("shortcut.registered")).toBool(),
           QStringLiteral("capture to stay on; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("turning it on succeeds but the following status check fails"), [](World& world, const Captures&, const Table&) {
    desktop().message = QStringLiteral("Your desktop could not say whether it can capture windows.");
    update(world);
  });
  step(QStringLiteral("the user opens setup"), [](World& world, const Captures&, const Table&) { send(world, QStringLiteral("setup.open")); });
  step(QStringLiteral("setup opens at its first step"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access") && field(world, QStringLiteral("wizard.closeLabel")) == QLatin1String("Finish later"),
           QStringLiteral("setup to open on access; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("finishing later turns capture back off"), [](World& world, const Captures&, const Table&) {
    // Trying again turns capture on, and the check still fails.
    send(world, QStringLiteral("setup.continue"));
    expect(settings(world)->setting(QStringLiteral("snapShotEnabled")).toBool() && field(world, QStringLiteral("wizard.step")) == QLatin1String("access"),
           QStringLiteral("capture on and setup still on access; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.close"));
    expectOff(world);
  });
  step(QStringLiteral("the title says \"Set up snapshots for\" the user's desktop, or just \"Set up snapshots\""), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.title")) == QLatin1String("Set up snapshots"),
           QStringLiteral("setup's title on an unnamed desktop; Snap Shot is %1").arg(show(snapShot(world))));
    resetDesktop(world, environment(QStringLiteral("wayland"), QStringLiteral("GNOME")));
    openPanel(world);
    send(world, QStringLiteral("setup.open"));
    expect(field(world, QStringLiteral("wizard.title")) == QLatin1String("Set up snapshots for GNOME"),
           QStringLiteral("setup's title on GNOME; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the steps are capture access and the shortcut"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut"), QStringLiteral("setup on the shortcut; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.back"));
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access"), QStringLiteral("access before it; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user can go back to access but cannot jump ahead to the shortcut"), [](World& world, const Captures&, const Table&) {
    desktop().message = QStringLiteral("Your desktop could not say whether it can capture windows.");
    update(world);
    send(world, QStringLiteral("setup.continue"));
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access"), QStringLiteral("setup to stay on access; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.close"));
    send(world, QStringLiteral("setup.open"), {{QStringLiteral("step"), QStringLiteral("shortcut")}});
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access"), QStringLiteral("setup to open on access; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("Snap Shot was (on|off) when the user opened setup"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("on")) turnOn(world);
    send(world, QStringLiteral("setup.open"));
  });
  step(QStringLiteral("the setup footer offers %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("wizard.closeLabel")) == c[0], QStringLiteral("setup to offer %1; Snap Shot is %2").arg(c[0], show(snapShot(world))));
  });
  step(QStringLiteral("the desktop cannot report whether capture is supported"), [](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.screenshotFails = true;
    portalDesktop(world, portal);
  });
  step(QStringLiteral("the user checks capture access"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.continue"));
  });
  step(QStringLiteral("setup says %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("wizard.heading")) == c[0] && field(world, QStringLiteral("wizard.body")) == c[1],
           QStringLiteral("setup to say %1 and %2; Snap Shot is %3").arg(c[0], c[1], show(snapShot(world))));
  });
  step(QStringLiteral("capture access is not reported as ready"), [](World& world, const Captures&, const Table&) {
    waitForField(world, QStringLiteral("wizard.busy"), false);
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access") && field(world, QStringLiteral("wizard.continueLabel")) == QLatin1String("Try again") &&
               field(world, QStringLiteral("status")) == QLatin1String("Capture needs attention"),
           QStringLiteral("access not to be ready; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user is on the shortcut step(?: with a saved shortcut| on a desktop that gives shortcuts by portal)?"),
       [](World& world, const Captures&, const Table&) {
         turnOn(world);
         send(world, QStringLiteral("setup.open"));
         expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut"), QStringLiteral("setup on the shortcut; Snap Shot is %1").arg(show(snapShot(world))));
       });
  step(QStringLiteral("the user is on the shortcut step on while recording"), [](World& world, const Captures&, const Table&) {
    turnOn(world);
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("record.start"));
  });
  step(QStringLiteral("capture access is lost"), [](World& world, const Captures&, const Table&) {
    desktop().message = QStringLiteral("Your desktop could not say whether it can capture windows.");
    update(world);
  });
  step(QStringLiteral("setup says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap wizard = field(world, QStringLiteral("wizard")).toMap();
    const bool says = std::any_of(wizard.cbegin(), wizard.cend(), [&](const QVariant& value) { return value == c[0]; });
    expect(says, QStringLiteral("setup to say %1; it shows %2").arg(c[0], show(wizard)));
  });
  step(QStringLiteral("the user cannot finish until access is back"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.done"));
    expect(hasWizard(world) && !field(world, QStringLiteral("wizard.doneEnabled")).toBool(),
           QStringLiteral("setup to stay open without access; Snap Shot is %1").arg(show(snapShot(world))));
    desktop().message.clear();
    update(world);
    expect(field(world, QStringLiteral("wizard.doneEnabled")).toBool(), QStringLiteral("finishing once access is back; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.done"));
    expect(!hasWizard(world), QStringLiteral("setup to finish; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the user records a different one"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("record.start"));
    pressNamed(world, QStringLiteral("Ctrl+Alt+K"));
  });
  step(QStringLiteral("the finishing button reads \"Save and finish\" and is available only when the shortcut can be saved"),
       [](World& world, const Captures&, const Table&) {
         expect(field(world, QStringLiteral("wizard.doneLabel")) == QLatin1String("Save and finish") && field(world, QStringLiteral("wizard.doneEnabled")).toBool() &&
                    field(world, QStringLiteral("shortcut.canSave")).toBool(),
                QStringLiteral("Save and finish, available; Snap Shot is %1").arg(show(snapShot(world))));
         // One the desktop reserves cannot be saved, so setup cannot finish with it.
         send(world, QStringLiteral("record.start"));
         pressNamed(world, QStringLiteral("Super+L"));
         expect(field(world, QStringLiteral("wizard.doneLabel")) == QLatin1String("Save and finish") && !field(world, QStringLiteral("wizard.doneEnabled")).toBool(),
                QStringLiteral("Save and finish, unavailable; Snap Shot is %1").arg(show(snapShot(world))));
       });
  step(QStringLiteral("the user records nothing"), [](World& world, const Captures&, const Table&) { send(world, QStringLiteral("shortcut.discard")); });
  step(QStringLiteral("the button reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("wizard.doneLabel")) == c[0] && field(world, QStringLiteral("wizard.doneEnabled")).toBool(),
           QStringLiteral("the button to read %1; Snap Shot is %2").arg(c[0], show(snapShot(world))));
  });
  step(QStringLiteral("setup asked the desktop for a shortcut and its prompt is pending"), [](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.bind = PortalAnswer::Hold;
    portalDesktop(world, portal);
    settings(world)->set(QStringLiteral("snapShotShortcut"), kCtrlShift2.toVariantMap());
    send(world, QStringLiteral("setup.open"));
    world.waitFor([] { return bus().prompting(); }, QStringLiteral("the desktop to prompt for the shortcut"));
  });
  step(QStringLiteral("the user can finish setup and approve the prompt later"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.doneEnabled")).toBool(), QStringLiteral("setup to finish while the prompt is open; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("setup.done"));
    expect(!hasWizard(world) && settings(world)->setting(QStringLiteral("snapShotEnabled")).toBool(),
           QStringLiteral("setup to finish with capture on; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the desktop has refused the shortcut"), [](World& world, const Captures&, const Table&) {
    bus().answer(false);
    waitForField(world, QStringLiteral("shortcut.pending"), false);
    send(world, QStringLiteral("setup.open"));
  });
  step(QStringLiteral("the user cannot finish until it is allowed or changed"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.done"));
    expect(hasWizard(world) && !field(world, QStringLiteral("wizard.doneEnabled")).toBool() && field(world, QStringLiteral("wizard.permissions")).toBool(),
           QStringLiteral("setup to wait on the refused shortcut; Snap Shot is %1").arg(show(snapShot(world))));
    send(world, QStringLiteral("record.start"));
    pressNamed(world, QStringLiteral("Ctrl+Alt+K"));
    expect(field(world, QStringLiteral("wizard.doneEnabled")).toBool(), QStringLiteral("a changed shortcut to finish setup; Snap Shot is %1").arg(show(snapShot(world))));
  });

  // The desktop portal's answers.
  step(QStringLiteral("(the desktop grants the shortcut and shows it as \"Ctrl\\+Alt\\+S\"|"
                      "the user refuses the permission prompt on a desktop that (?:can|cannot) ask again|"
                      "the desktop grants the shortcut but assigns no keys, and (?:can|cannot) ask again)"),
       [](World& world, const Captures& c, const Table&) {
         auto& portal = bus().desktop;
         if (c[0].contains(QLatin1String("cannot ask"))) portal.shortcutsVersion = 1;
         if (c[0].contains(QLatin1String("Ctrl+Alt+S"))) portal.label = QStringLiteral("Ctrl+Alt+S");
         if (c[0].contains(QLatin1String("refuses"))) portal.bind = PortalAnswer::Refuse;
         if (c[0].contains(QLatin1String("no keys"))) portal.bind = PortalAnswer::Unassigned;
         turnOnWith(world);
       });
  step(QStringLiteral("the desktop's shortcut permission prompt is open"), [](World& world, const Captures&, const Table&) {
    bus().desktop.bind = PortalAnswer::Hold;
    turnOnWith(world);
    world.waitFor([] { return bus().prompting(); }, QStringLiteral("the desktop to prompt for the shortcut"));
  });
  step(QStringLiteral("the user takes up to two minutes to answer it"), [](World&, const Captures&, const Table&) {
    expect(FakeDesktopPortal::promptTimeoutMs() >= 120'000,
           QStringLiteral("the prompt to be waited for two minutes, not %1 ms").arg(FakeDesktopPortal::promptTimeoutMs()));
  });
  step(QStringLiteral("HAL-C2 keeps waiting and the shortcut row keeps asking for the prompt to be approved"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.pending")).toBool() &&
               field(world, QStringLiteral("shortcut.status")) == QLatin1String("Approve the shortcut permission prompt to continue."),
           QStringLiteral("the row to wait on the prompt; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("the shortcut is registered as soon as the user approves"), [](World& world, const Captures&, const Table&) {
    bus().answer(true);
    waitForField(world, QStringLiteral("shortcut.registered"), true);
  });
  step(QStringLiteral("(the desktop's shortcut service restarts|the desktop closes HAL-C2's shortcut session|"
                      "the permission prompt is not answered in time|the desktop's shortcut service cannot be reached)"),
       [](World& world, const Captures& c, const Table&) {
         if (c[0].contains(QLatin1String("in time"))) {
           bus().desktop.bind = PortalAnswer::Hold;
           bus().shortenPrompts();
           turnOnWith(world);
           return;
         }
         if (c[0].contains(QLatin1String("cannot be reached"))) {
           bus().dropService();
           turnOnWith(world);
           return;
         }
         turnOnWith(world);
         waitForField(world, QStringLiteral("shortcut.registered"), true);
         if (c[0].contains(QLatin1String("restarts"))) bus().restartService();
         else bus().closeSession();
       });
  step(QStringLiteral("the user records (Shift\\+K|Ctrl\\+C|Ctrl\\+S|Ctrl\\+Z|Alt\\+Tab|Super\\+L)"), [](World& world, const Captures& c, const Table&) {
    pressNamed(world, c[0]);
  });
  step(QStringLiteral("Save is not available"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("shortcut.canSave")).toBool(), QStringLiteral("Save to be unavailable; Snap Shot is %1").arg(show(snapShot(world))));
  });
  step(QStringLiteral("Snap Shot is on and its shortcut is registered"), [](World& world, const Captures&, const Table&) {
    portalDesktop(world);
    turnOnWith(world);
    waitForField(world, QStringLiteral("shortcut.registered"), true);
  });
  step(QStringLiteral("the user changes a setting that is not about Snap Shot"), [](World& world, const Captures&, const Table&) {
    settings(world)->set(QStringLiteral("wordWrap"), !settings(world)->setting(QStringLiteral("wordWrap")).toBool());
    world.sync();
  });
  step(QStringLiteral("the shortcut stays registered without being released and set up again"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.registered")).toBool() && bus().creates == 1 && bus().triggers.size() == 1 && bus().closes == 0,
           QStringLiteral("one session, never closed; %1 sessions, %2 binds, %3 closed").arg(bus().creates).arg(bus().triggers.size()).arg(bus().closes));
  });
  step(QStringLiteral("an approved desktop shortcut session is not dropped"), [](World&, const Captures&, const Table&) {
    expect(bus().sessionOpen(), QStringLiteral("the desktop's session to stay open"));
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
    // A compositor's own config holds it; the user says it is there.
    send(world, field(world, QStringLiteral("shortcut.managed")).toBool() ? QStringLiteral("config.complete") : QStringLiteral("setup.done"));
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

// For the other SnapShot*Steps.cpp files: the panel, and the desktop
// FakePortal plays.
namespace snapshot {

void openPanel(World& world) {
  ::openPanel(world);
}
QVariant field(World& world, const QString& path) {
  return ::field(world, path);
}
QString describe(World& world) {
  return show(snapShot(world));
}
void send(World& world, const QString& action, const QVariantMap& payload) {
  ::send(world, action, payload);
}
void set(World& world, const QString& key, const QVariant& value) {
  settings(world)->set(key, value);
}
QVariant setting(World& world, const QString& key) {
  return settings(world)->setting(key);
}
void press(World& world, int key, Qt::KeyboardModifiers modifiers) {
  ::press(world, key, modifiers);
}
void waitForField(World& world, const QString& path, const QVariant& value) {
  ::waitForField(world, path, value);
}
void turnOn(World& world) {
  ::turnOn(world);
}
// A GNOME session wrapping the fake portal with `factory`; a session on no
// named desktop without one.
void gnomeSession(World& world, SnapShotBackend::GnomeFactory factory, bool picker) {
  resetDesktop(world, factory ? environment(QStringLiteral("wayland"), QStringLiteral("GNOME")) : environment(QStringLiteral("wayland")), std::nullopt, factory, picker);
}
qsizetype portalCaptures() {
  return desktop().captures.size();
}
qsizetype attachmentCount(World& world) {
  return attachments(world, threadKey(world)).size();
}
void expectFailureToast(World& world, const QString& body) {
  expectToast(world, QStringLiteral("Snapshot failed"), body);
}
void openThreadForCapture(World& world) {
  openThread(world);
  openPanel(world);
}
void portalDesktop(World& world, const PortalDesktop& portal) {
  ::portalDesktop(world, portal);
}
void holdChecks() {
  desktop().holdChecks = true;
}
qsizetype heldChecks() {
  return desktop().checks.size();
}
void answerCheck(qsizetype index, const SnapShotBackend::Check& answer) {
  desktop().checks.at(index)(answer);
}
void refusePause(const QString& reason) {
  desktop().refusePause = reason;
}
QStringList played() {
  return desktop().played;
}
void resetDesktop(World& world, const QProcessEnvironment& env) {
  ::resetDesktop(world, env);
}
void openThread(World& world) {
  ::openThread(world);
}
void capture(World& world) {
  ::capture(world);
}
QVariantList draft(World& world) {
  return attachments(world, threadKey(world));
}
SnapShotBackend* backend(World& world) {
  return controller(world)->backend();
}
void expectToast(World& world, const QString& title, const QString& description) {
  ::expectToast(world, title, description);
}

void session(World& world, const QProcessEnvironment& env) {
  ::resetDesktop(world, env);
}
void portalSession(World& world, const QProcessEnvironment& env, const PortalDesktop& portal) {
  ::resetDesktop(world, env, portal);
}
void shortcutRefused(const QString& reason) {
  desktop().holdShortcuts = false;
  desktop().refuse = reason;
}
void holdShortcuts() {
  desktop().holdShortcuts = true;
}
QStringList binds() {
  return desktop().binds;
}
void thread(World& world) {
  ::openThread(world);
}
void pressShortcut(World& world) {
  ::capture(world);
}
QVariantMap attachedImage(World& world) {
  return attached(world, threadKey(world));
}
QVariantList draftImages(World& world) {
  return attachments(world, threadKey(world));
}
void pickerOnly(World& world) {
  desktop().picker = true;
  update(world);
}

}  // namespace snapshot

// For the other Snap Shot steps files.
void snapShotOpenThread(World& world) {
  openThread(world);
}

QVariantList snapShotDraft(World& world) {
  return attachments(world, threadKey(world));
}
