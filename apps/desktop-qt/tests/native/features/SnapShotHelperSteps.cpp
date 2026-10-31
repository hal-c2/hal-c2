// The capture helpers of KDE Plasma and Hyprland (HelperSnapShot, CaptureHelper;
// features/settings/snap-shot.feature, source-control/snap-shot.feature) against
// a fake helper in a scratch directory: a shell script that does what its mode
// file says and logs how it was called. No real helper or KDE service tool can
// run from here, because the paths are replaced before anything starts.

#include <QDir>
#include <QFile>
#include <QImage>
#include <QTemporaryDir>

#include "CaptureHelper.h"
#include "HelperSnapShot.h"
#include "FakeDesktopPortal.h"
#include "Harness.h"
#include "SnapShotBackend.h"
#include "World.h"

namespace snapshot {
SnapShotBackend* backend(World& world);
QVariant field(World& world, const QString& path);
QString describe(World& world);
void openPanel(World& world);
void send(World& world, const QString& action, const QVariantMap& payload = {});
void set(World& world, const QString& key, const QVariant& value);
QVariant setting(World& world, const QString& key);
void session(World& world, const QProcessEnvironment& env);
void portalSession(World& world, const QProcessEnvironment& env, const PortalDesktop& portal);
void waitForField(World& world, const QString& path, const QVariant& value);
void thread(World& world);
void pressShortcut(World& world);
QVariantMap attachedImage(World& world);
QVariantList draftImages(World& world);
void resetCaptureHelpers();
}  // namespace snapshot

namespace {

using namespace snapshot;

struct Scratch {
  QTemporaryDir root;
  QString bundle(CaptureHelper::Kind kind) const { return root.filePath(QStringLiteral("bundle/") + CaptureHelper::executableName(kind)); }
  QString dataHome() const { return root.filePath(QStringLiteral("data")); }
  QString tools() const { return root.filePath(QStringLiteral("tools")); }
  QString noTools() const { return root.filePath(QStringLiteral("no-tools")); }
  QString mode() const { return root.filePath(QStringLiteral("mode")); }
  QString calls() const { return root.filePath(QStringLiteral("calls")); }
};

void write(const QString& path, const QByteArray& bytes, bool executable = false) {
  QDir().mkpath(QFileInfo(path).path());
  QFile file(path);
  expect(file.open(QIODevice::WriteOnly | QIODevice::Truncate) && file.write(bytes) == bytes.size(), QStringLiteral("to write %1").arg(path));
  file.close();
  if (executable) file.setPermissions(file.permissions() | QFileDevice::ExeOwner);
}

// Exits with what the mode file asks for; every call is logged.
QByteArray helperScript(const Scratch& scratch) {
  return QString::fromUtf8(R"sh(#!/bin/sh
root='%1'
echo "$*" >> "$root/calls"
case "$(cat "$root/mode")" in
  hang) exec sleep 30 ;;
  silent) exit 1 ;;
  denied-kde) echo 'org.kde.KWin.ScreenShot2.Error.NoAuthorized' >&2; exit 1 ;;
  denied-capture) [ "$1" = capture ] && { echo 'Hyprland denied screen capture. Allow HAL-C2 in the screen-sharing prompt, then try again.' >&2; exit 1; } ;;
esac
case "$1" in
  check) echo '{"feedbackAvailable":false}' ;;
  capture) cp "$root/capture.png" "$2/capture.png"; echo '{"window":{"appName":"Browser","title":"Docs"}}' ;;
esac
)sh").arg(scratch.root.path()).toUtf8();
}

Scratch& scratch() {
  static Scratch state;
  static const bool made = [] {
    Scratch* made = &state;
    QDir().mkpath(made->noTools());
    for (const CaptureHelper::Kind kind : {CaptureHelper::Kind::Kde, CaptureHelper::Kind::Hyprland}) {
      write(made->bundle(kind), helperScript(*made), true);
    }
    for (const QString& tool : {QStringLiteral("kbuildsycoca6"), QStringLiteral("systemd-run")}) {
      write(QDir(made->tools()).filePath(tool), "#!/bin/sh\nexit 0\n", true);
    }
    QImage image(320, 200, QImage::Format_RGB32);
    image.fill(Qt::darkCyan);
    image.save(made->root.filePath(QStringLiteral("capture.png")), "PNG");
    return true;
  }();
  Q_UNUSED(made);
  return state;
}

bool& bundleMissing() {
  static bool missing = false;
  return missing;
}

// Before any test makes a backend: no path a helper comes from is ever real.
const bool kSeams = [] {
  CaptureHelper::setPaths([](CaptureHelper::Kind kind) {
    return CaptureHelper::Paths{bundleMissing() ? QString() : scratch().bundle(kind), scratch().dataHome()};
  });
  CaptureHelper::setToolPath({scratch().tools()});
  return true;
}();

void setMode(const QByteArray& mode) {
  write(scratch().mode(), mode + "\n");
}

CaptureHelper::Kind kindOf(const QString& desktop) {
  return desktop == QLatin1String("KDE Plasma") ? CaptureHelper::Kind::Kde : CaptureHelper::Kind::Hyprland;
}

QProcessEnvironment environmentOf(const QString& desktop) {
  QProcessEnvironment env;
  env.insert(QStringLiteral("XDG_SESSION_TYPE"), QStringLiteral("wayland"));
  env.insert(QStringLiteral("WAYLAND_DISPLAY"), QStringLiteral("wayland-1"));
  env.insert(QStringLiteral("XDG_CURRENT_DESKTOP"), desktop);
  env.insert(QStringLiteral("HOME"), scratch().root.filePath(QStringLiteral("home")));
  return env;
}

QProcessEnvironment environmentOf(CaptureHelper::Kind kind) {
  return environmentOf(kind == CaptureHelper::Kind::Kde ? QStringLiteral("KDE") : QStringLiteral("Hyprland"));
}

QString installed(CaptureHelper::Kind kind) {
  return CaptureHelper(kind, {{}, scratch().dataHome()}).executable();
}

QString entry() {
  return QDir(scratch().dataHome()).filePath(QStringLiteral("applications/io.github.halc2.HalC2.KdeCapture.desktop"));
}

QString helperText(CaptureHelper::Kind kind) {
  QFile file(scratch().bundle(kind));
  file.open(QIODevice::ReadOnly);
  return QString::fromUtf8(file.readAll());
}

// Installs through a helper of its own, as setup would, and waits for it.
void install(CaptureHelper::Kind kind) {
  CaptureHelper helper(kind, {scratch().bundle(kind), scratch().dataHome()});
  QEventLoop loop;
  bool done = false;
  QObject::connect(&helper, &CaptureHelper::changed, &loop, [&] {
    if (helper.busy() || helper.state().status.isEmpty()) return;
    done = true;
    loop.quit();
  });
  helper.perform(helper.installAction());
  if (!done) loop.exec();
  expect(QFile::exists(installed(kind)), QStringLiteral("the helper to install; it says %1").arg(helper.state().message));
}

// A session reads the helper's files as they are, not as a new scenario's.
bool& keepHelper() {
  static bool keep = false;
  return keep;
}

void load(World& world, const QProcessEnvironment& env) {
  keepHelper() = true;
  session(world, env);
  keepHelper() = false;
  openPanel(world);
}

void uninstall() {
  QDir(scratch().dataHome()).removeRecursively();
}

QStringList calls() {
  QFile file(scratch().calls());
  if (!file.open(QIODevice::ReadOnly)) return {};
  return QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
}

void tellInPlace(World& world) {
  world.toldInPlace = [&world] {
    return QStringList{field(world, QStringLiteral("wizard.details")).toString(), field(world, QStringLiteral("flash.status")).toString(),
                       field(world, QStringLiteral("animations.status")).toString(), field(world, QStringLiteral("shortcut.status")).toString()};
  };
}

// A desktop with the helper in the given state, and the panel open.
void desktopWith(World& world, CaptureHelper::Kind kind, const QString& state) {
  uninstall();
  if (state != QLatin1String("not installed")) install(kind);
  if (state == QLatin1String("out of date")) write(installed(kind), "#!/bin/sh\n# an older build\n", true);
  if (state == QLatin1String("failing its check") || state == QLatin1String("failing")) setMode("silent");
  load(world, environmentOf(kind));
  tellInPlace(world);
}

void waitForHelper(World& world) {
  world.waitFor([&] { return !field(world, QStringLiteral("checking")).toBool(); },
                [&] { return QStringLiteral("the helper to answer; Snap Shot is %1").arg(describe(world)); });
}

void expectWizardTells(World& world, const QString& wanted) {
  world.waitFor([&] { return field(world, QStringLiteral("wizard.details")).toString().contains(wanted); },
                [&] { return QStringLiteral("setup to tell the user %1; Snap Shot is %2").arg(wanted, describe(world)); });
}

void expectToastContaining(World& world, const QString& wanted) {
  world.waitFor(
      [&] {
        for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
          if (item.toMap().value(QStringLiteral("description")).toString().contains(wanted)) return true;
        }
        return false;
      },
      [&] { return QStringLiteral("a toast saying %1; the shell shows %2").arg(wanted, show(world.state(QStringLiteral("toasts")))); });
}

bool& kdeScenario() {
  static bool kde = false;
  return kde;
}

// What a link conflict must leave as it found it.
struct Conflict {
  QString path;
  QByteArray bytes;
};
QList<Conflict>& conflicts() {
  static QList<Conflict> list;
  return list;
}

void linkInstead(const QString& path) {
  const QString target = scratch().root.filePath(QStringLiteral("elsewhere-") + QFileInfo(path).fileName());
  write(target, "not the helper\n");
  QFile::remove(path);
  QDir().mkpath(QFileInfo(path).path());
  expect(QFile::link(target, path), QStringLiteral("to link %1").arg(path));
  conflicts().append({path, "not the helper\n"});
}

void expectConflictsKept() {
  expect(!conflicts().isEmpty(), QStringLiteral("a conflict to keep"));
  for (const Conflict& conflict : conflicts()) {
    QFile file(conflict.path);
    expect(file.open(QIODevice::ReadOnly) && file.readAll() == conflict.bytes, QStringLiteral("%1 to be left as it was").arg(conflict.path));
  }
}

QString actionFor(const QString& step) {
  if (step == QLatin1String("install the KDE Plasma capture helper")) return QStringLiteral("install-kde-helper");
  if (step == QLatin1String("install the Hyprland capture helper")) return QStringLiteral("install-hyprland-helper");
  if (step == QLatin1String("install the GNOME extension")) return QStringLiteral("install-extension");
  if (step == QLatin1String("allow screen recording the way macOS does")) return QStringLiteral("allow-screen-recording");
  return QStringLiteral("test-mac-capture");
}

const Steps steps([] {
  step(QStringLiteral("the user installed the capture helper during setup"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Kde, QStringLiteral("not installed"));
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), true}});
    waitForField(world, QStringLiteral("wizard.action"), QStringLiteral("install-kde-helper"));
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), QStringLiteral("install-kde-helper")}});
    waitForField(world, QStringLiteral("wizard.action"), QString());
    world.waitFor([&] { return QFile::exists(installed(CaptureHelper::Kind::Kde)) && !field(world, QStringLiteral("wizard.busy")).toBool(); },
                  [&] { return QStringLiteral("the helper installed; Snap Shot is %1").arg(describe(world)); });
  });
  step(QStringLiteral("capture is off and the helper stays installed"), [](World& world, const Captures&, const Table&) {
    expect(!setting(world, QStringLiteral("snapShotEnabled")).toBool() && QFile::exists(installed(CaptureHelper::Kind::Kde)) && QFile::exists(entry()),
           QStringLiteral("capture off and the helper kept; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("Snap Shot is on but the capture helper is not installed"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Kde, QStringLiteral("not installed"));
    set(world, QStringLiteral("snapShotEnabled"), true);
  });
  step(QStringLiteral("Snap Shot is on but the capture helper's access check failed"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Kde, QStringLiteral("failing"));
    set(world, QStringLiteral("snapShotEnabled"), true);
  });
  step(QStringLiteral("a Linux session where (Hyprland|KDE Plasma) has its helper ready but no effects"), [](World& world, const Captures& c, const Table&) {
    desktopWith(world, kindOf(c[0]), QStringLiteral("ready"));
    set(world, QStringLiteral("snapShotEnabled"), true);
  });
  step(QStringLiteral("a Linux session where (Hyprland|KDE Plasma) has no helper or an outdated one"), [](World& world, const Captures& c, const Table&) {
    desktopWith(world, kindOf(c[0]), QStringLiteral("not installed"));
    set(world, QStringLiteral("snapShotEnabled"), true);
  });

  // The access step.
  step(QStringLiteral("a (KDE Plasma|Hyprland) session where the capture helper is (not installed|out of date|failing its check)"),
       [](World& world, const Captures& c, const Table&) { desktopWith(world, kindOf(c[0]), c[1]); });
  step(QStringLiteral("setup offers \"Install the capture helper\""), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.continueLabel")) == QLatin1String("Install helper") &&
               field(world, QStringLiteral("wizard.action")).toString().startsWith(QLatin1String("install-")),
           QStringLiteral("setup to offer installing; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("setup offers \"Update the capture helper\""), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.continueLabel")) == QLatin1String("Update helper") &&
               field(world, QStringLiteral("wizard.action")).toString().startsWith(QLatin1String("install-")),
           QStringLiteral("setup to offer updating; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("setup offers \"Check again\""), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.continueLabel")) == QLatin1String("Check again") && field(world, QStringLiteral("wizard.action")).toString().isEmpty(),
           QStringLiteral("setup to offer checking again; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("a KDE Plasma session where the capture helper fails its access check"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Kde, QStringLiteral("failing"));
    send(world, QStringLiteral("setup.open"));
  });
  step(QStringLiteral("the user checks again and it still fails"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.continue"));
    world.waitFor([&] { return !field(world, QStringLiteral("wizard.checkMessage")).toString().isEmpty(); },
                  [&] { return QStringLiteral("the check to be answered; Snap Shot is %1").arg(describe(world)); });
  });
  step(QStringLiteral("suggests reinstalling the capture helper and checking again"), [](World& world, const Captures&, const Table&) {
    const bool offered = field(world, QStringLiteral("wizard.advanced")).toList().value(0).toMap().value(QStringLiteral("label")) == QLatin1String("Reinstall helper");
    expect(field(world, QStringLiteral("wizard.body")) == QLatin1String("Try reinstalling the capture helper, then check again.") && offered,
           QStringLiteral("setup to suggest reinstalling; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("a Hyprland session with the capture helper installed"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Hyprland, QStringLiteral("ready"));
  });
  step(QStringLiteral("setup says the desktop may ask for permission when the user first captures"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.details")).toString().contains(QLatin1String("may ask for screen-sharing permission on your first capture")),
           QStringLiteral("setup to warn about the first capture; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("a session whose capture helper was installed by setup"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Hyprland, QStringLiteral("ready"));
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.back"));
  });
  step(QStringLiteral("the user opens Advanced on the access step"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("access"), QStringLiteral("the access step; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("they can remove the capture helper"), [](World& world, const Captures&, const Table&) {
    const QVariantMap option = field(world, QStringLiteral("wizard.advanced")).toList().value(0).toMap();
    expect(option.value(QStringLiteral("action")) == QLatin1String("remove-hyprland-helper"), show(option));
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), option.value(QStringLiteral("action"))}});
    world.waitFor([&] { return !QFile::exists(installed(CaptureHelper::Kind::Hyprland)); },
                  [&] { return QStringLiteral("the helper removed; Snap Shot is %1").arg(describe(world)); });
    write(scratch().root.filePath(QStringLiteral("note")), option.value(QStringLiteral("note")).toString().toUtf8());
  });
  step(QStringLiteral("the helper's own note says it is included with HAL-C2 and needs no download"), [](World&, const Captures&, const Table&) {
    QFile note(scratch().root.filePath(QStringLiteral("note")));
    expect(note.open(QIODevice::ReadOnly) && note.readAll() == "Included with HAL-C2. No download needed.", QStringLiteral("the helper's note"));
  });

  step(QStringLiteral("a Linux Wayland session on (KDE Plasma|Hyprland)"), [](World& world, const Captures& c, const Table&) {
    desktopWith(world, kindOf(c[0]), QStringLiteral("ready"));
  });

  // Hyprland's shortcut session.
  step(QStringLiteral("a Hyprland session where the binding is kept in the Hyprland config"), [](World&, const Captures&, const Table&) {});
  const auto hyprland = [](World& world, const PortalDesktop& portal) {
    uninstall();
    install(CaptureHelper::Kind::Hyprland);
    keepHelper() = true;
    portalSession(world, environmentOf(CaptureHelper::Kind::Hyprland), portal);
    keepHelper() = false;
    openPanel(world);
    set(world, QStringLiteral("snapShotEnabled"), true);
    tellInPlace(world);
  };
  step(QStringLiteral("HAL-C2 is still connecting to Hyprland's shortcuts"), [hyprland](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.bind = PortalAnswer::Hold;
    hyprland(world, portal);
  });
  step(QStringLiteral("Hyprland registers the capture action"), [hyprland](World& world, const Captures&, const Table&) { hyprland(world, {}); });
  step(QStringLiteral("Hyprland does not register the capture action"), [hyprland](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.bind = PortalAnswer::Nothing;
    hyprland(world, portal);
  });
  step(QStringLiteral("Hyprland's shortcut session cannot be reached"), [hyprland](World& world, const Captures&, const Table&) {
    PortalDesktop portal;
    portal.sessionFails = true;
    hyprland(world, portal);
  });
  step(QStringLiteral("the user asks for the shortcut permission"), [hyprland](World& world, const Captures&, const Table&) {
    hyprland(world, {});
    waitForField(world, QStringLiteral("shortcut.registered"), true);
    expect(!field(world, QStringLiteral("shortcut.permissions")).toBool(), QStringLiteral("asking again not to be offered; Snap Shot is %1").arg(describe(world)));
    send(world, QStringLiteral("shortcut.permissions"));
  });
  step(QStringLiteral("the user is told to change the capture binding in the Hyprland config and save it"), [](World& world, const Captures&, const Table&) {
    waitForField(world, QStringLiteral("shortcut.status"), QStringLiteral("Change the capture binding in your Hyprland config, then save it."));
  });

  // What setup refuses to touch.
  // "a Hyprland session" is SnapShotConfigSteps.cpp's; the helper it starts with is installed.
  step(QStringLiteral("a KDE Plasma session"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Kde, QStringLiteral("ready"));
    kdeScenario() = true;
  });
  const auto current = [] { return kdeScenario() ? CaptureHelper::Kind::Kde : CaptureHelper::Kind::Hyprland; };
  step(QStringLiteral("the helper or its launcher entry is a link"), [current](World&, const Captures&, const Table&) { linkInstead(installed(current())); });
  step(QStringLiteral("the helper is a link"), [current](World&, const Captures&, const Table&) { linkInstead(installed(current())); });
  step(QStringLiteral("the helper's folder is a link"), [current](World&, const Captures&, const Table&) {
    const QString folder = QFileInfo(installed(current())).path();
    const QString elsewhere = scratch().root.filePath(QStringLiteral("elsewhere-folder"));
    QDir(elsewhere).removeRecursively();
    QDir().rename(folder, elsewhere);
    expect(QFile::link(elsewhere, folder), QStringLiteral("to link %1").arg(folder));
    QFile moved(QDir(elsewhere).filePath(QFileInfo(installed(current())).fileName()));
    expect(moved.open(QIODevice::ReadOnly), QStringLiteral("the helper moved"));
    conflicts().append({installed(current()), moved.readAll()});
  });
  step(QStringLiteral("another program's launcher entry has the helper's name"), [](World&, const Captures&, const Table&) {
    const QByteArray other = "[Desktop Entry]\nType=Application\nName=Someone else\n";
    write(entry(), other);
    conflicts().append({entry(), other});
  });
  step(QStringLiteral("the user installs or removes the capture helper"), [current](World& world, const Captures&, const Table&) {
    const CaptureHelper helper(current(), {});
    load(world, environmentOf(current()));
    waitForHelper(world);
    world.toldInPlace = [&world] { return QStringList{field(world, QStringLiteral("wizard.details")).toString()}; };
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), helper.removeAction()}});
    waitForHelper(world);
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), helper.installAction()}});
    waitForHelper(world);
  });

  step(QStringLiteral("the app was built without its capture helper"), [current](World& world, const Captures&, const Table&) {
    bundleMissing() = true;
    load(world, environmentOf(current()));
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.back"));
  });
  step(QStringLiteral("the user checks capture access or installs the helper"), [current](World& world, const Captures&, const Table&) {
    waitForHelper(world);
    expectWizardTells(world, QStringLiteral("missing from this build"));
    uninstall();
    send(world, QStringLiteral("setup.continue"));
    waitForHelper(world);
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), CaptureHelper(current(), {}).installAction()}});
  });
  step(QStringLiteral("the user is told the helper is missing from this build and to update or reinstall HAL-C2"), [current](World& world, const Captures&, const Table&) {
    expectWizardTells(world, QStringLiteral("missing from this build. Update or reinstall HAL-C2."));
    expect(!QFile::exists(installed(current())), QStringLiteral("nothing to be installed"));
  });
  step(QStringLiteral("KDE's service tools are not installed"), [](World& world, const Captures&, const Table&) {
    uninstall();
    CaptureHelper::setToolPath({scratch().noTools()});
    load(world, environmentOf(CaptureHelper::Kind::Kde));
    waitForHelper(world);
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), QStringLiteral("install-kde-helper")}});
    waitForHelper(world);
  });
  step(QStringLiteral("KDE has not granted the helper screen capture access"), [](World& world, const Captures&, const Table&) {
    setMode("denied-kde");
    load(world, environmentOf(CaptureHelper::Kind::Kde));
    waitForHelper(world);
    send(world, QStringLiteral("setup.open"));
  });
  step(QStringLiteral("the helper does not answer a check"), [](World& world, const Captures&, const Table&) {
    setMode("silent");
    load(world, environmentOf(CaptureHelper::Kind::Kde));
    waitForHelper(world);
    send(world, QStringLiteral("setup.open"));
  });

  // Capturing.
  step(QStringLiteral("a KDE Plasma or Hyprland session where the capture helper is not ready"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Kde, QStringLiteral("not installed"));
    set(world, QStringLiteral("snapShotEnabled"), true);
    thread(world);
  });
  step(QStringLiteral("the user is told what is missing and to open Settings, SnapShots to continue setup"), [](World& world, const Captures&, const Table&) {
    expectToastContaining(world, QStringLiteral("Install the bundled helper to capture the window you're using without a picker. Open Settings → SnapShots to continue setup."));
  });
  step(QStringLiteral("the helper does not answer within twenty seconds"), [](World& world, const Captures&, const Table&) {
    expect(CaptureHelper::kTimeoutMs == 20'000, QStringLiteral("the wait to be twenty seconds"));
    CaptureHelper::setTimeout(200);
    setMode("hang");
    set(world, QStringLiteral("snapShotEnabled"), true);
    thread(world);
  });
  step(QStringLiteral("the user is told Hyprland capture did not respond and to check capture setup and try again"), [](World& world, const Captures&, const Table&) {
    expectToastContaining(world, QStringLiteral("Hyprland capture did not respond. Check capture setup and try again."));
  });

  // Setup only writes what it was asked to.
  step(QStringLiteral("a KDE Plasma or Hyprland session"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Kde, QStringLiteral("not installed"));
  });
  step(QStringLiteral("the user checks capture access without choosing to install"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.open"));
    send(world, QStringLiteral("setup.continue"));
    waitForHelper(world);
  });
  step(QStringLiteral("nothing is written to the user's files"), [](World&, const Captures&, const Table&) {
    expect(!QDir(scratch().dataHome()).exists(), QStringLiteral("no files before installing"));
  });
  step(QStringLiteral("files are written only after the user chooses to install the helper"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), QStringLiteral("install-kde-helper")}});
    world.waitFor([&] { return QFile::exists(installed(CaptureHelper::Kind::Kde)) && QFile::exists(entry()) && !field(world, QStringLiteral("checking")).toBool(); },
                  [&] { return QStringLiteral("the helper installed; Snap Shot is %1").arg(describe(world)); });
    expect(QFileInfo(entry()).permissions().testFlag(QFileDevice::ReadOwner) && QFileInfo(installed(CaptureHelper::Kind::Kde)).isExecutable(),
           QStringLiteral("the installed helper to run"));
  });

  // Another desktop's steps.
  // source-control/snap-shot.feature.
  step(QStringLiteral("a Hyprland session whose capture helper fails"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Hyprland, QStringLiteral("ready"));
    set(world, QStringLiteral("snapShotEnabled"), true);
    thread(world);
    setMode("denied-capture");
  });
  step(QStringLiteral("the capture fails and no other capture method is tried"), [](World& world, const Captures&, const Table&) {
    expectToastContaining(world, QStringLiteral("Hyprland denied screen capture"));
    expect(draftImages(world).isEmpty(), QStringLiteral("nothing attached"));
    expect(field(world, QStringLiteral("backend")) != QLatin1String("picker"), QStringLiteral("no picker"));
  });
  step(QStringLiteral("capture works through the capture helper(?: and a Hyprland binding)?"), [](World& world, const Captures&, const Table&) {
    const qsizetype before = calls().size();
    set(world, QStringLiteral("snapShotEnabled"), true);
    thread(world);
    pressShortcut(world);
    world.waitFor([&] { return !draftImages(world).isEmpty(); }, [&] { return QStringLiteral("the capture attached; Snap Shot is %1").arg(describe(world)); });
    expect(calls().mid(before).join(QLatin1Char(' ')).contains(QLatin1String("capture")), QStringLiteral("the helper to capture; it was called %1").arg(calls().join(QLatin1String(", "))));
  });
  step(QStringLiteral("Hyprland refuses screen capture to HAL-C2"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Hyprland, QStringLiteral("ready"));
    set(world, QStringLiteral("snapShotEnabled"), true);
    thread(world);
    setMode("denied-capture");
  });
  step(QStringLiteral("the user is shown the capture was denied and how to allow it"), [](World& world, const Captures&, const Table&) {
    expectToastContaining(world, QStringLiteral("Hyprland denied screen capture. Allow HAL-C2 in the screen-sharing prompt, then try again."));
  });
  step(QStringLiteral("the flash and animation are on and the desktop's capture helper cannot show them"), [](World& world, const Captures&, const Table&) {
    desktopWith(world, CaptureHelper::Kind::Hyprland, QStringLiteral("ready"));
    set(world, QStringLiteral("snapShotFlash"), true);
    set(world, QStringLiteral("snapShotEnabled"), true);
    set(world, QStringLiteral("snapShotAnimations"), true);
    thread(world);
  });
  step(QStringLiteral("the image is attached without waiting for the effects"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !draftImages(world).isEmpty(); }, [&] { return QStringLiteral("the capture attached; Snap Shot is %1").arg(describe(world)); });
  });
  step(QStringLiteral("the capture is not reported as failed"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      expect(item.toMap().value(QStringLiteral("type")) != QLatin1String("error"), show(item));
    }
  });
});

}  // namespace

namespace snapshot {
// Every scenario starts with the helper installed, as if setup had been done
// before; the steps above take it away.
void resetCaptureHelpers() {
  Q_UNUSED(kSeams);
  if (keepHelper()) return;
  kdeScenario() = false;
  conflicts().clear();
  bundleMissing() = false;
  CaptureHelper::setToolPath({scratch().tools()});
  CaptureHelper::setTimeout(CaptureHelper::kTimeoutMs);
  setMode("ok");
  QFile::remove(scratch().calls());
  uninstall();
  install(CaptureHelper::Kind::Kde);
  install(CaptureHelper::Kind::Hyprland);
}
void uninstallCaptureHelpers(World& world) {
  uninstall();
  load(world, environmentOf(CaptureHelper::Kind::Kde));
}
// The GNOME scenarios share these words (SnapShotGnomeSteps.cpp holds the steps).
bool helperInUse(World& world) {
  return dynamic_cast<HelperSnapShot*>(backend(world)) != nullptr;
}
void helperConflictsKept() {
  expectConflictsKept();
}
void helperOnKde(World& world) {
  uninstall();
  load(world, environmentOf(QStringLiteral("KDE")));
  send(world, QStringLiteral("setup.open"));
  tellInPlace(world);
}
void helperNothingInstalled() {
  expect(!QDir(scratch().dataHome()).exists(), QStringLiteral("nothing installed"));
}
QString setupAction(const QString& step) {
  return actionFor(step);
}
}  // namespace snapshot
