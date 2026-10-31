// Snap Shot on Windows (WindowsSnapShot) with Windows itself faked: the desktop
// the scenarios that say "runs on Windows" run on, and the one the capture cues
// run on, since a desktop portal has none. The Win32 half,
// src/native/win/WindowsSystem.cpp, is not built or run by these.

#include <QJsonObject>

#include "Harness.h"
#include "SnapShotBackend.h"
#include "WindowsSnapShot.h"
#include "World.h"

namespace snapshot {
void openPanel(World& world);
QVariant field(World& world, const QString& path);
QString describe(World& world);
void send(World& world, const QString& action, const QVariantMap& payload = {});
QVariant setting(World& world, const QString& key);
void set(World& world, const QString& key, const QVariant& value);
QStringList played();
void resetDesktop(World& world, const QProcessEnvironment& env);
void openThread(World& world);
void capture(World& world);
QVariantList draft(World& world);
SnapShotBackend* backend(World& world);
void expectToast(World& world, const QString& title, const QString& description);
}  // namespace snapshot

namespace {

using namespace snapshot;

// What Windows does, for FakeWindows to read and record into.
struct Machine {
  std::optional<WindowsSystem::Window> window = WindowsSystem::Window{7, QStringLiteral("npm test"), QRect(10, 20, 800, 600), QStringLiteral("C:\\Tools\\Terminal.exe")};
  QImage image;
  bool answerGrabs = true;
  bool grabRunning = false;
  bool refusePairs = false;
  bool animations = true;
  int flashes = 0;
  int flights = 0;
  int flightsWithFlash = 0;
  QSize attachedSize;
};

Machine& machine() {
  static Machine state;
  return state;
}

class FakeWindows : public WindowsSystem {
public:
  using WindowsSystem::WindowsSystem;

  std::optional<Window> foreground() override { return machine().window; }
  void grab(const QRect&) override {
    if (machine().answerGrabs) emit grabbed(machine().image);
    else machine().grabRunning = true;
  }
  bool grabbing() const override { return machine().grabRunning; }
  void cancelGrab() override {}
  bool holdHotKey(uint, uint) override { return true; }
  void releaseHotKey() override {}
  bool canHoldHotKey(uint, uint) override { return true; }
  bool watchPair(uint, uint) override { return !machine().refusePairs; }
  void stopWatching() override {}
  bool canWatchPair(uint, uint) override { return !machine().refusePairs; }
  bool animationsEnabled() const override { return machine().animations; }
  void flash(const QRect&, bool) override { ++machine().flashes; }
  void fly(const QImage&, const QRect&, bool flash) override {
    ++machine().flights;
    if (flash) ++machine().flightsWithFlash;
  }
  bool cueShowing() const override { return false; }
};

void runOnWindows(World& world) {
  machine() = {};
  machine().image = QImage(320, 200, QImage::Format_RGB32);
  machine().image.fill(Qt::darkCyan);
  WindowsSnapShot::setCaptureTimeout(15000);
  SnapShotBackend::setWindowsFactory([](QObject* parent) -> WindowsSystem* { return new FakeWindows(parent); });
  QProcessEnvironment env;
  env.insert(QStringLiteral("OS"), QStringLiteral("Windows_NT"));
  resetDesktop(world, env);
  openPanel(world);
  QObject::connect(backend(world), &SnapShotBackend::captured, backend(world),
                   [](const QImage& image, const QString&, const QString&) { machine().attachedSize = image.size(); });
}

void turnOn(World& world) {
  send(world, QStringLiteral("enable"), {{QStringLiteral("on"), true}});
}

void expectStatus(World& world, const QString& status) {
  expect(field(world, QStringLiteral("shortcut.status")) == status, QStringLiteral("the shortcut row to say \"%1\"; Snap Shot is %2").arg(status, describe(world)));
}

void pressBoth(World& world, const QString& modifier) {
  send(world, QStringLiteral("record.start"));
  const auto hold = [&](const char* side) {
    send(world, QStringLiteral("record.modifier"), {{QStringLiteral("modifier"), modifier}, {QStringLiteral("code"), QLatin1String(side)}, {QStringLiteral("down"), true}});
  };
  hold("left");
  hold("right");
}

void expectNothingAttached(World& world, const QString& told) {
  world.waitFor([&] { return !static_cast<WindowsSnapShot*>(backend(world))->capturing(); }, [] { return QStringLiteral("the capture to end"); });
  expect(draft(world).isEmpty(), QStringLiteral("nothing attached; the draft has %1").arg(show(draft(world))));
  expectToast(world, QStringLiteral("Snapshot failed"), told);
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the desktop app runs on Windows"), [](World& world, const Captures&, const Table&) { runOnWindows(world); });

  // settings/snap-shot.feature: no setup.
  step(QStringLiteral("capture is on and no setup is opened"), [](World& world, const Captures&, const Table&) {
    expect(setting(world, QStringLiteral("snapShotEnabled")).toBool() && !field(world, QStringLiteral("wizard")).toMap().contains(QStringLiteral("step")),
           QStringLiteral("capture on with no setup; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the setup button is not shown"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("setupLabel")).toString().isEmpty(), QStringLiteral("no setup button; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user allows capture during setup"), [](World& world, const Captures&, const Table&) { turnOn(world); });
  step(QStringLiteral("the user is asked for nothing"), [](World& world, const Captures&, const Table&) {
    expect(setting(world, QStringLiteral("snapShotEnabled")).toBool() && !field(world, QStringLiteral("wizard")).toMap().contains(QStringLiteral("step")),
           QStringLiteral("nothing to allow; Snap Shot is %1").arg(describe(world)));
  });

  // The cues.
  step(QStringLiteral("the user turns (flash|animation) off"), [](World& world, const Captures& c, const Table&) {
    runOnWindows(world);
    openThread(world);
    turnOn(world);
    send(world, QStringLiteral("set"), {{QStringLiteral("key"), c[0] == QLatin1String("flash") ? QStringLiteral("flash") : QStringLiteral("animations")}, {QStringLiteral("value"), false}});
  });
  step(QStringLiteral("captures happen without a flash on the captured window"), [](World& world, const Captures&, const Table&) {
    capture(world);
    expect(draft(world).size() == 1 && machine().flashes == 0 && machine().flightsWithFlash == 0 && machine().flights == 1,
           QStringLiteral("a flight with no flash: %1 flashes, %2 of %3 flights flashed").arg(machine().flashes).arg(machine().flightsWithFlash).arg(machine().flights));
  });
  step(QStringLiteral("captures happen without the image flying into the draft"), [](World& world, const Captures&, const Table&) {
    capture(world);
    expect(draft(world).size() == 1 && machine().flights == 0 && machine().flashes == 1,
           QStringLiteral("a still flash and no flight: %1 flashes, %2 flights").arg(machine().flashes).arg(machine().flights));
  });
  step(QStringLiteral("the sound, flash and animation are on"), [](World& world, const Captures&, const Table&) {
    runOnWindows(world);
    openThread(world);
    turnOn(world);
  });
  step(QStringLiteral("the sound plays, the captured window flashes and the image flies into the draft"), [](World& world, const Captures&, const Table&) {
    expect(played().size() == 1 && machine().flightsWithFlash == 1 && draft(world).size() == 1,
           QStringLiteral("the sound and a flight with its flash: played %1, %2 flights flashed").arg(played().join(u',')).arg(machine().flightsWithFlash));
  });
  step(QStringLiteral("the system asks for reduced motion"), [](World& world, const Captures&, const Table&) {
    runOnWindows(world);
    openThread(world);
    turnOn(world);
    machine().animations = false;
  });
  step(QStringLiteral("the image lands in the draft without animating"), [](World& world, const Captures&, const Table&) {
    expect(draft(world).size() == 1 && machine().flights == 0, QStringLiteral("no flight; %1 flights").arg(machine().flights));
  });

  // A modifier pair.
  step(QStringLiteral("the user chooses the shortcut of pressing both (Super|Alt) keys"), [](World& world, const Captures& c, const Table&) {
    turnOn(world);
    pressBoth(world, c[0] == QLatin1String("Super") ? QStringLiteral("meta") : QStringLiteral("alt"));
    send(world, QStringLiteral("shortcut.save"));
  });
  step(QStringLiteral("the shortcut row says it is observed and cannot be reserved exclusively"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.status")).toString().contains(QLatin1String("is observed and cannot be reserved exclusively.")),
           QStringLiteral("the observed warning; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("it adds %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("shortcut.status")).toString().endsWith(c[0]), QStringLiteral("the note \"%1\"; Snap Shot is %2").arg(c[0], describe(world)));
  });
  // Windows' half of "Windows or macOS"; the macOS watcher says the same.
  step(QStringLiteral("the desktop app runs on Windows or macOS"), [](World& world, const Captures&, const Table&) { runOnWindows(world); });
  step(QStringLiteral("the user chooses a shortcut of pressing both of a modifier key and the system refuses to let HAL-C2 watch it"),
       [](World& world, const Captures&, const Table&) {
         machine().refusePairs = true;
         turnOn(world);
         pressBoth(world, QStringLiteral("alt"));
         send(world, QStringLiteral("record.key"), {{QStringLiteral("key"), int(Qt::Key_Escape)}, {QStringLiteral("modifiers"), 0}});
       });
  step(QStringLiteral("the shortcut row says that key is not available on this system"), [](World& world, const Captures&, const Table&) {
    // The saved both-Shift shortcut is refused too, so the row reads as its own.
    expect(field(world, QStringLiteral("shortcut.status")).toString().endsWith(QLatin1String("is not available on this system.")),
           QStringLiteral("the key to be reported; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("capture does not claim the shortcut is registered"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("shortcut.registered")).toBool() && !field(world, QStringLiteral("shortcut.canSave")).toBool(),
           QStringLiteral("the shortcut not to be registered; Snap Shot is %1").arg(describe(world)));
  });

  // source-control/snap-shot.feature: capturing.
  step(QStringLiteral("the Windows window capture does not answer in time"), [](World& world, const Captures&, const Table&) {
    openThread(world);
    turnOn(world);
    machine().answerGrabs = false;
    WindowsSnapShot::setCaptureTimeout(0);
  });
  step(QStringLiteral("an earlier Windows window capture is still running"), [](World& world, const Captures&, const Table&) {
    openThread(world);
    turnOn(world);
    machine().grabRunning = true;
  });
  step(QStringLiteral("nothing is attached and the user is told the window could not be captured"), [](World& world, const Captures&, const Table&) {
    expectNothingAttached(world, WindowsSnapShot::kCouldNotCapture);
  });
  step(QStringLiteral("no half-finished capture is kept"), [](World& world, const Captures&, const Table&) {
    // The press after the stuck grab ends works.
    machine().grabRunning = false;
    machine().answerGrabs = true;
    capture(world);
    expect(draft(world).size() == 1, QStringLiteral("the next capture to attach; the draft has %1").arg(show(draft(world))));
  });
  step(QStringLiteral("no window is available to capture"), [](World& world, const Captures&, const Table&) {
    openThread(world);
    turnOn(world);
    machine().window = std::nullopt;
  });
  step(QStringLiteral("nothing is attached and the user is told the active window is not available for capture"),
       [](World& world, const Captures&, const Table&) { expectNothingAttached(world, WindowsSnapShot::kNoWindow); });
  step(QStringLiteral("the window in front is larger than 2,560 by 1,600 pixels"), [](World& world, const Captures&, const Table&) {
    openThread(world);
    turnOn(world);
    machine().image = QImage(5120, 2000, QImage::Format_RGB32);
    machine().image.fill(Qt::darkCyan);
  });
  step(QStringLiteral("the attached image is shrunk to fit within 2,560 by 1,600 pixels"), [](World& world, const Captures&, const Table&) {
    expect(draft(world).size() == 1 && machine().attachedSize == QSize(2560, 1000),
           QStringLiteral("2560x1000 with its shape kept; it is %1x%2").arg(machine().attachedSize.width()).arg(machine().attachedSize.height()));
  });
  step(QStringLiteral("the window belongs to the program %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openThread(world);
    turnOn(world);
    machine().window->program = QStringLiteral("C:\\Program Files\\") + c[0];
  });
  step(QStringLiteral("the window reports no program name"), [](World& world, const Captures&, const Table&) {
    openThread(world);
    turnOn(world);
    machine().window->program.clear();
  });
  step(QStringLiteral("the user captures it"), [](World& world, const Captures&, const Table&) { capture(world); });
  step(QStringLiteral("the attachment names the app %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(draft(world).size() == 1 && at(draft(world).first(), QStringLiteral("source.appName")) == c[0],
           QStringLiteral("the app %1; the draft has %2").arg(c[0], show(draft(world))));
  });
});

}  // namespace
