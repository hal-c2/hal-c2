// Scanning an environment's pairing code (features/mobile/
// pairing-and-environments.feature): the scanner as the user reaches it from
// the pairing screen, with the camera the scenario owns (FakeCamera). A code
// is held up to it as a camera's frame of the picture the desktop draws for
// the link, turned and small on a desk full of other things.

#include <QQuickItem>
#include <QQuickWindow>

#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

QString screenTexts(World& world) {
  return world.texts().join(QStringLiteral(" | "));
}

QVariantMap scanner(World& world) {
  return world.state(QStringLiteral("scanner")).toMap();
}

// The whole of the item is inside the window.
void expectOnScreen(World& world, const QString& objectName) {
  QQuickItem* item = world.item(objectName);
  // Layouts settle on the window's polish, which drawing a frame runs.
  world.window().grabWindow();
  const QRectF place = item->mapRectToScene(QRectF(0, 0, item->width(), item->height()));
  expect(QRectF(QPointF(0, 0), QSizeF(world.window().size())).contains(place),
         QStringLiteral("%1 is not all on the %2x%3 screen: it is %4x%5 at %6,%7")
             .arg(objectName)
             .arg(world.window().width())
             .arg(world.window().height())
             .arg(place.width())
             .arg(place.height())
             .arg(place.x())
             .arg(place.y()));
}

// The user asks to scan, from the pairing screen.
void chooseToScan(World& world) {
  world.tap(QStringLiteral("pairingScan"));
  world.item(QStringLiteral("scanScreen"));
}

// The scanner with its camera running, the user having allowed it when the
// system asked.
void scan(World& world) {
  if (world.camera->running()) return;
  chooseToScan(world);
  if (world.camera->asking()) world.camera->reply(ScanCamera::Access::Granted);
  world.waitFor([&] { return world.camera->running(); },
                [&] { return QStringLiteral("the camera to run; the scanner is %1 and the screen says: %2").arg(show(scanner(world)), screenTexts(world)); });
  // What it sees, the way back and what to point it at all fit the window.
  expectOnScreen(world, QStringLiteral("scanPreview"));
  expectOnScreen(world, QStringLiteral("back"));
  expectOnScreen(world, QStringLiteral("scanMessage"));
}

const Steps steps([] {
  using S = QString;

  step(S("the app runs on (a phone on its side|a tablet|a tablet held upright)"), [](World& world, const Captures& c, const Table&) {
    const QSize size = c[0] == QLatin1String("a phone on its side") ? QSize(915, 412) : c[0] == QLatin1String("a tablet") ? QSize(1280, 800) : QSize(800, 1280);
    world.resize(size.width(), size.height());
  });

  step(S("an environment shows a pairing code"), [](World& world, const Captures&, const Table&) { world.link = world.environment.link(); });

  step(S("the user scans the code"), [](World& world, const Captures&, const Table&) {
    scan(world);
    world.camera->show(camera::sees(world.link, QSize(1280, 720), 250, 97));
    world.waitFor([&] { return !scanner(world).value(S("open")).toBool(); },
                  [&] { return S("the code to be read; the scanner is %1 and the screen says: %2").arg(show(scanner(world)), screenTexts(world)); });
    // The camera's work is done.
    expect(!world.camera->running(), S("the camera is still running"));
    world.waitFor([&] { return world.find(S("scanScreen")) == nullptr; }, S("the scanner to leave the screen"));
  });

  step(S("its threads start loading"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return show(world.state(S("sidebar"))).contains(S("Tax line")); },
                  [&] { return S("the environment's threads; the thread list is %1").arg(show(world.state(S("sidebar")))); });
  });

  step(S("the environment's threads are listed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return pairingPhase(world) == QLatin1String("paired"); }, [&] { return S("the device to pair; it says: %1").arg(screenTexts(world)); });
    threadList(world);
    threadRow(world, S("Tax line"));
  });

  step(S("the app has not been granted camera access"), [](World& world, const Captures&, const Table&) {
    expect(world.camera->held == ScanCamera::Access::Undetermined && world.camera->asked == 0, S("the app was asked about the camera before"));
  });

  step(S("the user chooses to scan a pairing code"), [](World& world, const Captures&, const Table&) { chooseToScan(world); });

  step(S("the phone asks for camera access"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.camera->asking(); }, [&] { return S("the system's question; the scanner is %1").arg(show(scanner(world))); });
    expect(world.camera->asked == 1, S("the phone asked %1 times").arg(world.camera->asked));
    // Nothing is seen before the user answers.
    expect(!world.camera->running(), S("the camera runs before the user allowed it"));
  });

  // Asked again, the system answers for the user.
  step(S("the user has denied camera access"), [](World& world, const Captures&, const Table&) {
    world.camera->held = ScanCamera::Access::Denied;
    world.camera->answer = ScanCamera::Access::Denied;
  });

  step(S("the user is told camera access is needed"), [](World& world, const Captures&, const Table&) {
    const QString said = world.item(S("scanDenied"))->property("text").toString();
    expect(said.startsWith(S("HAL-C2 needs the camera")), S("the screen says: %1").arg(screenTexts(world)));
    expect(!world.camera->running(), S("the camera runs without the user's leave"));
    expectOnScreen(world, S("scanDenied"));
  });

  step(S("the user is offered to open the system settings"), [](World& world, const Captures&, const Table&) {
    expectOnScreen(world, S("scanSettings"));
    world.tap(S("scanSettings"));
    world.waitFor([&] { return world.camera->settingsOpened == 1; }, S("the system's settings for the app"));
  });

  step(S("the user scans a code that does not contain a pairing link"), [](World& world, const Captures&, const Table&) {
    scan(world);
    world.camera->show(camera::sees(S("https://example.com/menu?table=12"), QSize(1280, 720), 250, 20));
    world.waitFor([&] { return !scanner(world).value(S("message")).toString().isEmpty(); },
                  [&] { return S("the code to be read; the scanner is %1").arg(show(scanner(world))); });
  });

  step(S("the user is told the code is not a valid pairing code"), [](World& world, const Captures&, const Table&) {
    const QString said = world.item(S("scanMessage"))->property("text").toString();
    expect(said.startsWith(S("That is not a HAL-C2 pairing code.")), S("the screen says: %1").arg(screenTexts(world)));
    expectOnScreen(world, S("scanMessage"));
  });

  step(S("the scanner keeps looking"), [](World& world, const Captures&, const Table&) {
    expect(scanner(world).value(S("open")).toBool() && world.camera->running(), S("the scanner is %1").arg(show(scanner(world))));
    world.item(S("scanPreview"));
  });

  step(S("the user is scanning for a pairing code"), [](World& world, const Captures&, const Table&) { scan(world); });

  step(S("the user leaves the scanner by (its back button|the system's back)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("its back button")) {
      world.tap(S("back"));
    } else {
      world.back();
    }
    world.waitFor([&] { return world.find(S("scanScreen")) == nullptr; }, [&] { return S("the scanner to go; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the user switches to another app"), [](World& world, const Captures&, const Table&) { world.background(); });

  step(S("the user switches to another app and back"), [](World& world, const Captures&, const Table&) {
    world.background();
    expect(!world.camera->running(), S("the camera runs behind another app"));
    world.foreground();
  });

  step(S("the camera is off"), [](World& world, const Captures&, const Table&) {
    expect(!world.camera->running(), S("the camera is running; the scanner is %1").arg(show(scanner(world))));
  });

  step(S("the scanner is looking again"), [](World& world, const Captures&, const Table&) {
    expect(world.camera->running(), S("the camera is off; the scanner is %1").arg(show(scanner(world))));
    world.item(S("scanPreview"));
  });
});

}  // namespace
