// Snap Shot on macOS (MacSnapShot, MacPermissionHelper) in
// features/settings/snap-shot.feature, on a MacPlatform that answers as the
// scenario's Mac does. MacPlatform.mm itself only builds on Apple.

#include <QJsonObject>
#include <QProcess>

#include "Harness.h"
#include "KeybindingController.h"
#include "MacPermissionHelper.h"
#include "MacPlatform.h"
#include "MacSnapShot.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "SnapShotController.h"
#include "World.h"

// SnapShotSteps.cpp.
void snapShotOpenThread(World& world);
QVariantList snapShotDraft(World& world);

namespace {

const QString kScreen = MacPlatform::kScreenRecording;
const QString kText = MacPlatform::kAccessibility;

// What this Mac allows and what it was asked.
struct FakeMac {
  MacPlatform::Permissions allowed;
  bool readFails = false;
  bool refuseWatch = false;
  QString captureFailure;
  QStringList requested;
  QStringList watched;
  int captures = 0;
  int kept = 0;
  std::optional<MacPlatform::SettingsWindow> settings;
  QString helperText;
  QRect helperBounds;
  bool helperShown = false;
  int helperCloses = 0;
  int reveals = 0;
  int focuses = 0;
};

FakeMac& mac() {
  static FakeMac state;
  return state;
}

class FakeMacPlatform final : public MacPlatform {
public:
  using MacPlatform::MacPlatform;

  std::optional<Permissions> permissions() override {
    if (mac().readFails) return std::nullopt;
    return mac().allowed;
  }
  void request(const QString& permission) override { mac().requested.append(permission); }
  void openSettings(const QString&) override {
    mac().settings = SettingsWindow{true, true, QRect(100, 100, 800, 600)};
  }
  bool watchPair(const QString& modifier) override {
    if (mac().refuseWatch) return false;
    mac().watched.append(modifier);
    return true;
  }
  bool holdChord(const QJsonObject&) override { return true; }
  void letGo() override {}
  void capture(bool includeText, std::function<void(const Capture&)> done) override {
    ++mac().captures;
    Capture result;
    result.app = QStringLiteral("Safari");
    result.title = QStringLiteral("Docs");
    if (!mac().captureFailure.isEmpty()) {
      result.step = QStringLiteral("capture-window");
      result.status = mac().captureFailure;
      result.exitCode = 1;
      return done(result);
    }
    result.image = QImage(320, 200, QImage::Format_RGB32);
    result.image.fill(Qt::darkCyan);
    if (includeText) {
      const QString text = QStringLiteral("Docs: Getting started");
      result.context = {{QStringLiteral("accessibleText"), text},
                        {QStringLiteral("accessibility"),
                         QJsonObject{{QStringLiteral("format"), QStringLiteral("flat-text")}, {QStringLiteral("text"), text}, {QStringLiteral("truncated"), false}}}};
    }
    done(result);
  }
  std::optional<SettingsWindow> settingsWindow() override { return mac().settings; }
  void showHelper(const QRect& bounds, const QString& text) override {
    mac().helperShown = true;
    mac().helperBounds = bounds;
    mac().helperText = text;
  }
  void hideHelper() override { mac().helperShown = false; }
  void closeHelper() override {
    mac().helperShown = false;
    ++mac().helperCloses;
  }
  bool helperFocused() override { return false; }
  void revealApp() override { ++mac().reveals; }
  void focusApp() override { ++mac().focuses; }
};

SnapShotController* controller(World& world) {
  return world.native().controller<SnapShotController>();
}

MacSnapShot* backend(World& world) {
  auto* found = dynamic_cast<MacSnapShot*>(controller(world)->backend());
  expect(found != nullptr, QStringLiteral("the desktop to run on macOS"));
  return found;
}

QVariantMap snap(World& world) {
  return world.state(QStringLiteral("snapShot")).toMap();
}

QVariant field(World& world, const QString& path) {
  return at(snap(world), path);
}

void send(World& world, const QString& action, const QVariantMap& payload = {}) {
  world.bridge().dispatch(QStringLiteral("snapShot.") + action, payload);
}

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

void include(World& world, bool on) {
  settings(world)->set(QStringLiteral("snapShotIncludeAccessibility"), on);
}

void openPanel(World& world) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::settings(SnapShotController::kSection));
  world.waitFor([&] { return field(world, QStringLiteral("ready")).toBool(); },
                [&] { return QStringLiteral("Snap Shot to be ready; it is %1").arg(show(snap(world))); });
}

// The app starts on the scenario's Mac (World forgets the factory at the end).
void startApp(World& world) {
  MacPlatform::setFactory([](QObject* parent) { return new FakeMacPlatform(parent); });
  world.restart();
  world.connect();
  world.sync();
  world.native().controller<KeybindingController>()->setMac(true);
  world.toldInPlace = [&world] {
    return QStringList{field(world, QStringLiteral("wizard.permissionsError")).toString()};
  };
}

void macDesktop(World& world) {
  mac() = {};
  startApp(world);
  // Scenarios say when app text is included; "macOS" alone means it is not.
  include(world, false);
  openPanel(world);
}

// A permission changed in System Settings, and the app has looked.
void looked(World& world) {
  backend(world)->refresh();
}

void allowAll() {
  mac().allowed = {true, true};
}

void turnOn(World& world) {
  allowAll();
  settings(world)->set(QStringLiteral("snapShotEnabled"), true);
  looked(world);
  world.waitFor([&] { return field(world, QStringLiteral("shortcut.registered")).toBool(); },
                [&] { return QStringLiteral("the shortcut to be held; Snap Shot is %1").arg(show(snap(world))); });
}

QVariantMap row(World& world, const QString& id) {
  for (const QVariant& item : field(world, QStringLiteral("wizard.permissionRows")).toList()) {
    if (item.toMap().value(QStringLiteral("id")) == id) return item.toMap();
  }
  fail(QStringLiteral("no %1 row; Snap Shot is %2").arg(id, show(snap(world))));
}

bool enabled(World& world) {
  return settings(world)->setting(QStringLiteral("snapShotEnabled")).toBool();
}

void expectCanContinue(World& world, bool can) {
  expect(field(world, QStringLiteral("wizard.continueEnabled")).toBool() == can,
         QStringLiteral("Continue to be %1; Snap Shot is %2").arg(can ? QStringLiteral("available") : QStringLiteral("unavailable"), show(snap(world))));
}

void expectStep(World& world, const QString& name) {
  expect(field(world, QStringLiteral("wizard.step")) == name, QStringLiteral("setup on the %1 step; Snap Shot is %2").arg(name, show(snap(world))));
}

MacPermissionHelper* helper(World& world) {
  return backend(world)->helper();
}

void showHelper(World& world) {
  send(world, QStringLiteral("setup.open"));
  send(world, QStringLiteral("permission.allow"), {{QStringLiteral("id"), kScreen}});
}

// Both of `modifier`'s keys, with the recorder listening.
void pressBoth(World& world, const QString& modifier, const QString& left, const QString& right) {
  send(world, QStringLiteral("record.start"));
  for (const QString& code : {left, right}) {
    send(world, QStringLiteral("record.modifier"), {{QStringLiteral("modifier"), modifier}, {QStringLiteral("code"), code}, {QStringLiteral("down"), true}});
  }
}

// The shortcut pressed with a thread open.
void capture(World& world) {
  snapShotOpenThread(world);
  emit backend(world)->platform()->pressed();
  world.waitFor([&] { return !snapShotDraft(world).isEmpty(); }, [&] { return QStringLiteral("the capture on the draft"); });
}

const Steps steps([] {
  step(QStringLiteral("the desktop app runs on (macOS|macOS with app text included|Windows or macOS)"), [](World& world, const Captures& c, const Table&) {
    macDesktop(world);
    if (c[0] == QLatin1String("macOS with app text included")) include(world, true);
  });
  step(QStringLiteral("Snap Shot is on and the desktop app runs on macOS"), [](World& world, const Captures&, const Table&) {
    macDesktop(world);
    mac().allowed.screenRecording = true;
    settings(world)->set(QStringLiteral("snapShotEnabled"), true);
    looked(world);
  });

  // Setup.
  step(QStringLiteral("the user allows capture during setup"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.open"));
    for (const QVariant& item : field(world, QStringLiteral("wizard.permissionRows")).toList()) {
      const QVariantMap permission = item.toMap();
      if (permission.value(QStringLiteral("required")).toBool()) send(world, QStringLiteral("permission.allow"), {{QStringLiteral("id"), permission.value(QStringLiteral("id"))}});
    }
  });
  step(QStringLiteral("the user is asked for (Screen Recording and Accessibility|Screen Recording|Accessibility)"), [](World&, const Captures& c, const Table&) {
    QStringList wanted;
    if (c[0].contains(QLatin1String("Screen Recording"))) wanted.append(kScreen);
    if (c[0].contains(QLatin1String("Accessibility"))) wanted.append(kText);
    expect(mac().requested == wanted, QStringLiteral("macOS asked for %1, not %2").arg(wanted.join(u','), mac().requested.join(u',')));
  });
  step(QStringLiteral("the user finishes setup without changing the shortcut"), [](World& world, const Captures&, const Table&) {
    allowAll();
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.continue"));
    expectStep(world, QStringLiteral("shortcut"));
    send(world, QStringLiteral("setup.done"));
  });
  step(QStringLiteral("the shortcut is pressing both Shift keys"), [](World& world, const Captures&, const Table&) {
    const QJsonObject saved = QJsonValue::fromVariant(settings(world)->setting(QStringLiteral("snapShotShortcut"))).toObject();
    expect(saved.value(QLatin1String("kind")) == QLatin1String("both-shift-keys"), QStringLiteral("both Shift keys; the shortcut is %1").arg(show(saved.toVariantMap())));
  });
  step(QStringLiteral("the desktop watches for the shortcut"), [](World& world, const Captures&, const Table&) { turnOn(world); });
  step(QStringLiteral("the Dock lists the desktop app once"), [](World& world, const Captures&, const Table&) {
    // The Dock shows apps, and the watch starts none: it runs in this one.
    expect(mac().watched.contains(QStringLiteral("shift")) && backend(world)->findChildren<QProcess*>().isEmpty(),
           QStringLiteral("Shift watched in the app itself; watched %1").arg(mac().watched.join(u',')));
  });

  // Each permission on its own.
  step(QStringLiteral("the user is on the access step"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.open"));
    expectStep(world, QStringLiteral("access"));
  });
  step(QStringLiteral("Screen Recording is shown with %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QVariantMap screen = row(world, kScreen);
    expect(screen.value(QStringLiteral("title")) == QLatin1String("Screen Recording") && screen.value(QStringLiteral("description")) == c[0] &&
               screen.value(QStringLiteral("required")).toBool(),
           show(screen));
  });
  step(QStringLiteral("Accessibility is shown as optional text and controls"), [](World& world, const Captures&, const Table&) {
    const QVariantMap text = row(world, kText);
    expect(text.value(QStringLiteral("description")) == QLatin1String("Optional. Include text and controls from the captured app.") &&
               !text.value(QStringLiteral("required")).toBool(),
           show(text));
  });
  step(QStringLiteral("Continue is %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("wizard.continueLabel")) == c[0], QStringLiteral("Continue to read %1; Snap Shot is %2").arg(c[0], show(snap(world))));
  });
  step(QStringLiteral("Accessibility only gates Continue when app text is included"), [](World& world, const Captures&, const Table&) {
    mac().allowed = {true, false};
    looked(world);
    expectCanContinue(world, true);
    include(world, true);
    expectCanContinue(world, false);
    mac().allowed.accessibility = true;
    looked(world);
    expectCanContinue(world, true);
  });
  step(QStringLiteral("setup asks for two permissions and one is allowed"), [](World& world, const Captures&, const Table&) {
    macDesktop(world);
    include(world, true);
    mac().allowed = {true, false};
    send(world, QStringLiteral("setup.open"));
  });
  step(QStringLiteral("the allowed permission is marked as allowed"), [](World& world, const Captures&, const Table&) {
    expect(row(world, kScreen).value(QStringLiteral("granted")).toBool(), show(snap(world)));
  });
  step(QStringLiteral("the other offers to be allowed"), [](World& world, const Captures&, const Table&) {
    expect(!row(world, kText).value(QStringLiteral("granted")).toBool(), show(snap(world)));
  });
  step(QStringLiteral("setup does not let the user continue"), [](World& world, const Captures&, const Table&) { expectCanContinue(world, false); });
  step(QStringLiteral("setup lets the user continue"), [](World& world, const Captures&, const Table&) { expectCanContinue(world, true); });
  step(QStringLiteral("the user allows the other permission in system settings and returns to the app"), [](World& world, const Captures&, const Table&) {
    mac().allowed.accessibility = true;
    looked(world);
  });
  step(QStringLiteral("both are marked as allowed"), [](World& world, const Captures&, const Table&) {
    expect(row(world, kScreen).value(QStringLiteral("granted")).toBool() && row(world, kText).value(QStringLiteral("granted")).toBool(), show(snap(world)));
  });
  step(QStringLiteral("setup is waiting on a permission"), [](World& world, const Captures&, const Table&) {
    macDesktop(world);
    send(world, QStringLiteral("setup.open"));
    expectStep(world, QStringLiteral("access"));
  });
  step(QStringLiteral("the check of the permission's state fails"), [](World& world, const Captures&, const Table&) {
    mac().readFails = true;
    looked(world);
  });
  step(QStringLiteral("the next check succeeds"), [](World& world, const Captures&, const Table&) {
    mac().readFails = false;
    allowAll();
    looked(world);
  });
  step(QStringLiteral("the message goes away"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.permissionsError")).toString().isEmpty(), show(snap(world)));
    expectCanContinue(world, true);
  });

  // The test capture.
  step(QStringLiteral("the user allows capture in setup and the test capture fails"), [](World& world, const Captures&, const Table&) {
    allowAll();
    mac().captureFailure = QStringLiteral("exited");
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.continue"));
  });
  step(QStringLiteral("capture stays off, the user is told %1 with the reason").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString details = field(world, QStringLiteral("wizard.details")).toString();
    expect(!enabled(world) && details.startsWith(c[0]) && details.contains(QLatin1String("screencapture exited with code 1")),
           QStringLiteral("capture off and why; Snap Shot is %1").arg(show(snap(world))));
    expectStep(world, QStringLiteral("access"));
  });
  step(QStringLiteral("the user can try again"), [](World& world, const Captures&, const Table&) {
    expectCanContinue(world, true);
    mac().captureFailure.clear();
    send(world, QStringLiteral("setup.continue"));
    expectStep(world, QStringLiteral("shortcut"));
    expect(enabled(world), QStringLiteral("capture on once the test works"));
  });
  step(QStringLiteral("the user continues past the access step"), [](World& world, const Captures&, const Table&) {
    allowAll();
    send(world, QStringLiteral("setup.open"));
    looked(world);
    const QString body = field(world, QStringLiteral("wizard.body")).toString();
    expect(body.contains(QLatin1String("bypass its window picker")) && body.contains(QLatin1String("choose Allow")),
           QStringLiteral("setup to warn of macOS's prompt; it says %1").arg(body));
    QObject::connect(backend(world), &SnapShotBackend::captured, backend(world), [] { ++mac().kept; });
    send(world, QStringLiteral("setup.continue"));
  });
  step(QStringLiteral("the user is told macOS may ask to bypass its window picker and to choose Allow"), [](World&, const Captures&, const Table&) {
    // Read before continuing: setup moves on once the test works.
    expect(mac().captures == 1, QStringLiteral("one test capture, not %1").arg(mac().captures));
  });
  step(QStringLiteral("the test image is discarded"), [](World& world, const Captures&, const Table&) {
    expect(mac().kept == 0 && snapShotDraft(world).isEmpty(), QStringLiteral("no capture kept"));
    expectStep(world, QStringLiteral("shortcut"));
  });

  // Coming back to setup.
  step(QStringLiteral("the user allowed Screen Recording and the app had to quit and reopen"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("permission.allow"), {{QStringLiteral("id"), kScreen}});
    mac().allowed.screenRecording = true;
    startApp(world);
    world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("section")) == SnapShotController::kSection; },
                  [&] { return QStringLiteral("Settings, SnapShots to open; the route is %1, Snap Shot is %2, resume is %3")
                            .arg(show(world.state(QStringLiteral("route"))), show(snap(world)), settings(world)->setting(QStringLiteral("snapShotSetupResume")).toString()); });
  });
  step(QStringLiteral("setup resumes where the user left it, with capture on or off as it was"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !field(world, QStringLiteral("wizard")).isNull() && field(world, QStringLiteral("wizard.step")) == QLatin1String("access"); },
                  [&] { return QStringLiteral("setup at access; Snap Shot is %1").arg(show(snap(world))); });
    expect(!enabled(world), QStringLiteral("capture still off"));
    // Closing it for good ends the resuming.
    send(world, QStringLiteral("setup.close"));
    startApp(world);
    expect(field(world, QStringLiteral("wizard")).isNull(), QStringLiteral("no setup on the next start; Snap Shot is %1").arg(show(snap(world))));
  });

  // Done, and undone.
  step(QStringLiteral("Screen Recording is allowed, and Accessibility too when app text is included"), [](World&, const Captures&, const Table&) { allowAll(); });
  step(QStringLiteral("a shortcut is saved"), [](World& world, const Captures&, const Table&) { turnOn(world); });
  step(QStringLiteral("no setup button is shown and the shortcut stays editable in the panel"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("setupLabel")).toString().isEmpty() && field(world, QStringLiteral("shortcut.registered")).toBool() &&
               !field(world, QStringLiteral("shortcut.keys")).toString().isEmpty(),
           QStringLiteral("no setup button; Snap Shot is %1").arg(show(snap(world))));
  });
  step(QStringLiteral("the user revokes a permission"), [](World& world, const Captures&, const Table&) {
    mac().allowed.screenRecording = false;
    looked(world);
  });
  step(QStringLiteral("the setup button returns as %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("setupLabel")) == c[0], QStringLiteral("the button to read %1; Snap Shot is %2").arg(c[0], show(snap(world))));
  });
  step(QStringLiteral("Snap Shot is on and a permission was revoked so capture needs attention"), [](World& world, const Captures&, const Table&) {
    turnOn(world);
    mac().allowed.screenRecording = false;
    looked(world);
    expect(field(world, QStringLiteral("status")) == QLatin1String("Capture needs attention") && !field(world, QStringLiteral("shortcut.registered")).toBool(),
           QStringLiteral("capture to need attention; Snap Shot is %1").arg(show(snap(world))));
  });
  step(QStringLiteral("the user allows the permission again"), [](World& world, const Captures&, const Table&) {
    mac().allowed.screenRecording = true;
    looked(world);
  });
  step(QStringLiteral("the panel clears the message and the shortcut works again"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("status")) != QLatin1String("Capture needs attention") && field(world, QStringLiteral("shortcut.registered")).toBool(),
           show(snap(world)));
    capture(world);
  });
  step(QStringLiteral("no restart of HAL-C2 is needed"), [](World&, const Captures&, const Table&) {});

  // The panel beside System Settings.
  step(QStringLiteral("the user is sent to System Settings to allow Screen Recording or Accessibility"), [](World& world, const Captures&, const Table&) { showHelper(world); });
  step(QStringLiteral("a small panel beside System Settings says to drag HAL-C2 into the list"), [](World& world, const Captures&, const Table&) {
    expect(mac().helperShown && mac().helperText == MacPermissionHelper::kText && mac().helperBounds == MacPermissionHelper::boundsBeside(mac().settings->bounds),
           QStringLiteral("the panel beside Settings; it says %1").arg(mac().helperText));
    expect(helper(world)->permission() == kScreen, QStringLiteral("the panel for Screen Recording"));
  });
  step(QStringLiteral("the user can drag the app from it or choose to reveal the app in Finder"), [](World& world, const Captures&, const Table&) {
    emit backend(world)->platform()->helperRevealRequested();
    expect(mac().reveals == 1, QStringLiteral("the app shown in Finder"));
  });
  step(QStringLiteral("the permission panel is showing beside System Settings"), [](World& world, const Captures&, const Table&) {
    macDesktop(world);
    showHelper(world);
    expect(mac().helperShown, QStringLiteral("the panel to show"));
  });
  step(QStringLiteral("the permission is granted"), [](World& world, const Captures&, const Table&) {
    mac().allowed.screenRecording = true;
    helper(world)->check();
  });
  step(QStringLiteral("the panel closes itself"), [](World& world, const Captures&, const Table&) {
    expect(!helper(world)->open() && !mac().helperShown && mac().focuses == 1, QStringLiteral("the panel gone and HAL-C2 back in front"));
  });
  step(QStringLiteral("instead the user closes System Settings or brings another app forward"), [](World& world, const Captures&, const Table&) {
    mac().allowed.screenRecording = false;
    showHelper(world);
    expect(mac().helperShown, QStringLiteral("the panel to show again"));
    mac().settings->frontmost = false;
    helper(world)->track();
  });
  step(QStringLiteral("the panel closes or hides with it"), [](World& world, const Captures&, const Table&) {
    expect(helper(world)->open() && !mac().helperShown, QStringLiteral("the panel hidden while another app is in front"));
    mac().settings->frontmost = true;
    helper(world)->track();
    expect(mac().helperShown, QStringLiteral("the panel back with Settings"));
    mac().settings->open = false;
    helper(world)->track();
    expect(!helper(world)->open() && !mac().helperShown, QStringLiteral("the panel closed with Settings"));
  });

  // App text.
  step(QStringLiteral("the user turns on including app text"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("set"), {{QStringLiteral("key"), QStringLiteral("accessibility")}, {QStringLiteral("value"), true}});
  });
  step(QStringLiteral("the permission is refused"), [](World& world, const Captures&, const Table&) {
    expect(!mac().allowed.accessibility, QStringLiteral("Accessibility not to be allowed"));
    looked(world);
  });
  step(QStringLiteral("app text stays off and the user is told %1 with the reason").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(!field(world, QStringLiteral("accessibility.checked")).toBool(), show(snap(world)));
    for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      const QVariantMap toast = item.toMap();
      if (toast.value(QStringLiteral("title")) == c[0] && toast.value(QStringLiteral("description")).toString().contains(QLatin1String("Accessibility"))) return;
    }
    fail(QStringLiteral("the toast %1; the shell shows %2").arg(c[0], show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("captures carry the app's text and controls when the app makes them available"), [](World& world, const Captures&, const Table&) {
    // No permission yet, so nothing changed; allowed, it turns on.
    expect(!field(world, QStringLiteral("accessibility.checked")).toBool(), show(snap(world)));
    allowAll();
    looked(world);
    send(world, QStringLiteral("set"), {{QStringLiteral("key"), QStringLiteral("accessibility")}, {QStringLiteral("value"), true}});
    expect(field(world, QStringLiteral("accessibility.checked")).toBool(), show(snap(world)));
    capture(world);
    const QVariantMap source = snapShotDraft(world).first().toMap().value(QStringLiteral("source")).toMap();
    expect(source.value(QStringLiteral("accessibleText")) == QLatin1String("Docs: Getting started") &&
               at(source, QStringLiteral("accessibility.format")) == QLatin1String("flat-text"),
           QStringLiteral("the window's text on the capture; it is %1").arg(show(source)));
  });

  // The shortcut.
  step(QStringLiteral("the user is on the shortcut step on a desktop that records modifier pairs"), [](World& world, const Captures&, const Table&) {
    macDesktop(world);
    allowAll();
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.continue"));
    expectStep(world, QStringLiteral("shortcut"));
  });
  step(QStringLiteral("the user chooses the shortcut of pressing both Shift keys"), [](World& world, const Captures&, const Table&) {
    settings(world)->set(QStringLiteral("snapShotShortcut"), QVariantMap{{QStringLiteral("key"), QStringLiteral("k")}, {QStringLiteral("modKey"), true}});
    turnOn(world);
    pressBoth(world, QStringLiteral("shift"), QStringLiteral("ShiftLeft"), QStringLiteral("ShiftRight"));
  });
  step(QStringLiteral("the shortcut row says it is observed and cannot be reserved exclusively"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.status")) == QLatin1String("Shift + Shift is observed and cannot be reserved exclusively."),
           QStringLiteral("the row to say it is observed; Snap Shot is %1").arg(show(snap(world))));
  });
  step(QStringLiteral("it adds \"no further note\""), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("the user chooses a shortcut of pressing both of a modifier key and the system refuses to let HAL-C2 watch it"), [](World& world, const Captures&, const Table&) {
    settings(world)->set(QStringLiteral("snapShotShortcut"), QVariantMap{{QStringLiteral("key"), QStringLiteral("k")}, {QStringLiteral("modKey"), true}});
    turnOn(world);
    mac().refuseWatch = true;
    pressBoth(world, QStringLiteral("alt"), QStringLiteral("AltLeft"), QStringLiteral("AltRight"));
  });
  step(QStringLiteral("the shortcut row says that key is not available on this system"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.status")) == QLatin1String("Option + Option is not available on this system."),
           QStringLiteral("the row to say the key is not available; Snap Shot is %1").arg(show(snap(world))));
  });
  step(QStringLiteral("capture does not claim the shortcut is registered"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("shortcut.canSave")).toBool(), QStringLiteral("nothing to save; Snap Shot is %1").arg(show(snap(world))));
    // Nor when it is the saved one the system stops letting through.
    settings(world)->set(QStringLiteral("snapShotShortcut"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("modifier-pair")}, {QStringLiteral("modifier"), QStringLiteral("alt")}});
    expect(!field(world, QStringLiteral("shortcut.registered")).toBool(), show(snap(world)));
  });
});

}  // namespace
