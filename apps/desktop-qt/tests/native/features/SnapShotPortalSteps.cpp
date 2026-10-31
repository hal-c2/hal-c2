// Snap Shot's platform-neutral half (SnapShotController) against a desktop
// that answers late or not at all (features/settings/snap-shot.feature): the
// shortcut check, pausing the capture shortcut, setup while the desktop is
// asked, the sound preview, and the portal's shortcut session. The panel and
// FakePortal come from SnapShotSteps.cpp.

#include <QJsonObject>

#include "FakeDesktopPortal.h"
#include "Harness.h"
#include "SnapShotBackend.h"
#include "World.h"

namespace snapshot {
void openPanel(World& world);
QVariant field(World& world, const QString& path);
QString describe(World& world);
void send(World& world, const QString& action, const QVariantMap& payload = {});
void set(World& world, const QString& key, const QVariant& value);
QVariant setting(World& world, const QString& key);
void press(World& world, int key, Qt::KeyboardModifiers modifiers);
void waitForField(World& world, const QString& path, const QVariant& value);
void portalDesktop(World& world, const PortalDesktop& portal = {});
void holdChecks();
qsizetype heldChecks();
void answerCheck(qsizetype index, const SnapShotBackend::Check& answer);
void refusePause(const QString& reason);
QStringList played();
}  // namespace snapshot

namespace {

using namespace snapshot;

const QString kChecking = QStringLiteral("Checking shortcut…");

FakeDesktopPortal& bus() {
  return FakeDesktopPortal::instance();
}

void expectStatus(World& world, const QString& status, const QString& why) {
  expect(field(world, QStringLiteral("shortcut.status")) == status, QStringLiteral("%1; Snap Shot is %2").arg(why, describe(world)));
}

// Records a shortcut whose check the desktop has not answered.
void recordHeld(World& world, int key, Qt::KeyboardModifiers modifiers) {
  holdChecks();
  set(world, QStringLiteral("snapShotEnabled"), true);
  const qsizetype asked = heldChecks();
  send(world, QStringLiteral("record.start"));
  press(world, key, modifiers);
  expect(heldChecks() == asked + 1, QStringLiteral("the desktop to be asked about the shortcut; Snap Shot is %1").arg(describe(world)));
}

// The wizard, after something it should have ignored.
void expectStill(World& world, const QString& step, const QString& after) {
  const QVariantMap wizard = field(world, QStringLiteral("wizard")).toMap();
  expect(wizard.value(QStringLiteral("step")) == step && wizard.value(QStringLiteral("busy")).toBool(),
         QStringLiteral("setup to stay on %1 while it works, after %2; Snap Shot is %3").arg(step, after, describe(world)));
}

const Steps steps([] {
  const QString q = kQuoted;

  // The shortcut check.
  step(QStringLiteral("the desktop is being asked if the shortcut is free"), [](World& world, const Captures&, const Table&) {
    holdChecks();
    press(world, Qt::Key_At, Qt::ControlModifier | Qt::ShiftModifier);
  });
  step(QStringLiteral("the user recorded (?:a new shortcut|a shortcut and its check is still running)"),
       [](World& world, const Captures&, const Table&) { recordHeld(world, Qt::Key_At, Qt::ControlModifier | Qt::ShiftModifier); });
  step(QStringLiteral("the desktop fails while checking it"), [](World& world, const Captures&, const Table&) {
    expectStatus(world, kChecking, QStringLiteral("the row to say the shortcut is being checked"));
    answerCheck(heldChecks() - 1, {false, {}});
  });
  step(QStringLiteral("the shortcut row shows the failure, or \"Could not check this shortcut\\.\""), [](World& world, const Captures&, const Table&) {
    expectStatus(world, QStringLiteral("Could not check this shortcut."), QStringLiteral("a check that failed to say so"));
    // A failure with a reason shows the reason.
    recordHeld(world, Qt::Key_K, Qt::ControlModifier | Qt::AltModifier);
    answerCheck(heldChecks() - 1, {false, QStringLiteral("The desktop shortcut service restarted.")});
    expectStatus(world, QStringLiteral("The desktop shortcut service restarted."), QStringLiteral("the desktop's reason"));
  });
  step(QStringLiteral("the user records another shortcut"), [](World& world, const Captures&, const Table&) {
    recordHeld(world, Qt::Key_K, Qt::ControlModifier | Qt::AltModifier);
  });
  step(QStringLiteral("the answer to the first check is ignored"), [](World& world, const Captures&, const Table&) {
    answerCheck(heldChecks() - 2, {false, QStringLiteral("The first shortcut is taken.")});
    expectStatus(world, kChecking, QStringLiteral("the first answer to change nothing"));
    expect(!field(world, QStringLiteral("shortcut.canSave")).toBool(), QStringLiteral("Save to wait on the second check"));
  });
  step(QStringLiteral("the second shortcut's answer decides whether Save is available"), [](World& world, const Captures&, const Table&) {
    answerCheck(heldChecks() - 1, {true, QStringLiteral("Your desktop will confirm this shortcut when you save it.")});
    expectStatus(world, QStringLiteral("Ready to save."), QStringLiteral("the second answer to count"));
    expect(field(world, QStringLiteral("shortcut.canSave")).toBool() && field(world, QStringLiteral("shortcut.keys")) == QLatin1String("Ctrl+Alt+K"),
           QStringLiteral("Ctrl+Alt+K to be ready to save; Snap Shot is %1").arg(describe(world)));
  });

  // Pausing the capture shortcut.
  step(QStringLiteral("the desktop fails to pause the capture shortcut"), [](World& world, const Captures&, const Table&) {
    refusePause({});
    set(world, QStringLiteral("snapShotEnabled"), true);
  });
  step(QStringLiteral("the user starts recording a shortcut"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("record.start"));
  });
  step(QStringLiteral("recording does not start"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("shortcut.recording")).toBool(), QStringLiteral("no recording; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user is told \"Could not start shortcut recording\\.\" or the desktop's reason"), [](World& world, const Captures&, const Table&) {
    expectStatus(world, QStringLiteral("Could not start shortcut recording."), QStringLiteral("recording that could not start to say so"));
    refusePause(QStringLiteral("Another app is holding the keyboard."));
    send(world, QStringLiteral("record.start"));
    expectStatus(world, QStringLiteral("Another app is holding the keyboard."), QStringLiteral("the desktop's reason"));
  });

  // Setup while the desktop is asked again.
  step(QStringLiteral("setup is checking access or saving"), [](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.screenshotFails = true;
    portalDesktop(world, portal);
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), true}});
    waitForField(world, QStringLiteral("wizard.continueLabel"), QStringLiteral("Try again"));
    bus().desktop.screenshotFails = false;
    bus().desktop.holdScreenshot = true;
    send(world, QStringLiteral("setup.continue"));
    waitForField(world, QStringLiteral("wizard.busy"), true);
  });
  step(QStringLiteral("the user cannot close setup or move between its steps until it has finished"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.close"));
    expectStill(world, QStringLiteral("access"), QStringLiteral("closing"));
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), false}});
    expectStill(world, QStringLiteral("access"), QStringLiteral("turning capture off"));
    send(world, QStringLiteral("setup.continue"));
    expectStill(world, QStringLiteral("access"), QStringLiteral("continuing"));
    send(world, QStringLiteral("record.start"));
    expect(!field(world, QStringLiteral("shortcut.recording")).toBool(), QStringLiteral("no recording while setup works"));
    world.waitFor([] { return bus().screenshotHeld(); }, [] { return QStringLiteral("the desktop to be asked again"); });
    bus().answerScreenshot();
    waitForField(world, QStringLiteral("wizard.busy"), false);
    send(world, QStringLiteral("setup.continue"));
    waitForField(world, QStringLiteral("wizard.step"), QStringLiteral("shortcut"));
    send(world, QStringLiteral("setup.close"));
    expect(!field(world, QStringLiteral("wizard")).toMap().contains(QStringLiteral("step")),
           QStringLiteral("setup to close once it has finished; Snap Shot is %1").arg(describe(world)));
  });

  // The capture sound.
  step(QStringLiteral("the capture sound choices are open"), [](World& world, const Captures&, const Table&) {
    set(world, QStringLiteral("snapShotEnabled"), true);
    send(world, QStringLiteral("sound"), {{QStringLiteral("value"), QStringLiteral("soft-pop")}});
  });
  step(QStringLiteral("the user plays Click without selecting it"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("sound.play"), {{QStringLiteral("sound"), QStringLiteral("camera-shutter")}});
  });
  step(QStringLiteral("Click plays once"), [](World&, const Captures&, const Table&) {
    expect(played() == QStringList{QStringLiteral("camera-shutter")}, QStringLiteral("Click once; the desktop played %1").arg(played().join(u',')));
  });
  // The popup staying open is the page's (tst_SnapShotSettings.qml).
  step(QStringLiteral("the choices stay open and the sound in use does not change"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("sound.value")) == QLatin1String("soft-pop") &&
               setting(world, QStringLiteral("snapShotSound")) == QLatin1String("soft-pop"),
           QStringLiteral("Whoosh to stay the sound; Snap Shot is %1").arg(describe(world)));
  });

  // The portal's shortcut session.
  step(QStringLiteral("the desktop's shortcut session could not be started"), [](World& world, const Captures&, const Table&) {
    bus().desktop.sessionFails = true;
    set(world, QStringLiteral("snapShotShortcut"),
        QVariantMap{{QStringLiteral("key"), QStringLiteral("2")}, {QStringLiteral("ctrlKey"), true}, {QStringLiteral("shiftKey"), true}});
    set(world, QStringLiteral("snapShotEnabled"), true);
    waitForField(world, QStringLiteral("shortcut.status"), QStringLiteral("Your desktop could not create a capture shortcut session."));
    expect(field(world, QStringLiteral("shortcut.permissions")).toBool(),
           QStringLiteral("asking again to be offered without a session; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("a new shortcut session asks the desktop for the shortcut"), [](World& world, const Captures&, const Table&) {
    world.waitFor([] { return bus().prompting(); },
                  [] { return QStringLiteral("the desktop to prompt; it created %1 sessions").arg(bus().creates); });
    expect(bus().creates == 2, QStringLiteral("a second session; the desktop created %1").arg(bus().creates));
    waitForField(world, QStringLiteral("shortcut.status"), QStringLiteral("Approve the shortcut permission prompt to continue."));
  });
  step(QStringLiteral("the user asks for shortcut permission again"), [](World& world, const Captures&, const Table&) {
    bus().desktop.sessionFails = false;
    bus().desktop.bind = PortalAnswer::Hold;
    send(world, QStringLiteral("shortcut.permissions"));
  });

  // Keys the portal names.
  step(QStringLiteral("the user records Ctrl\\+Alt\\+(Up|Home)"), [](World& world, const Captures& c, const Table&) {
    set(world, QStringLiteral("snapShotEnabled"), true);
    send(world, QStringLiteral("record.start"));
    press(world, c[0] == QLatin1String("Up") ? Qt::Key_Up : Qt::Key_Home, Qt::ControlModifier | Qt::AltModifier);
  });
  step(QStringLiteral("saving asks the desktop for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    send(world, QStringLiteral("shortcut.save"));
    world.waitFor([&] { return bus().triggers.contains(c[0]); },
                  [&] { return QStringLiteral("the desktop to be asked for %1; it was asked for %2").arg(c[0], bus().triggers.join(u',')); });
  });
  step(QStringLiteral("the saved shortcut is pressing both Shift keys"), [](World& world, const Captures&, const Table&) {
    set(world, QStringLiteral("snapShotShortcut"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("both-shift-keys")}});
    set(world, QStringLiteral("snapShotEnabled"), true);
  });
});

}  // namespace
