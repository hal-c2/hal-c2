// Snap Shot on GNOME (GnomeSnapShot): setup of the extension bundled with the
// app, against a GNOME Shell that answers here and a scratch XDG_DATA_HOME.
// Nothing reaches the session bus or the real gnome-shell folder. The panel
// and FakePortal come from SnapShotSteps.cpp.

#include <QBuffer>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <memory>

#include "GnomeSnapShot.h"
#include "Harness.h"
#include "SnapShotBackend.h"
#include "World.h"

namespace snapshot {
void openPanel(World& world);
QVariant field(World& world, const QString& path);
QString describe(World& world);
void send(World& world, const QString& action, const QVariantMap& payload = {});
void turnOn(World& world);
void gnomeSession(World& world, SnapShotBackend::GnomeFactory factory, bool picker);
qsizetype portalCaptures();
qsizetype attachmentCount(World& world);
void expectFailureToast(World& world, const QString& body);
void openThreadForCapture(World& world);
void pressShortcut(World& world);
}  // namespace snapshot

namespace {

using namespace snapshot;

const QString kBundle = QStringLiteral(":/hal-c2/gnome-extension");

// What GNOME answers, and what it was asked.
struct FakeGnome {
  GnomeShell::Extension extension;
  GnomeShell::Capture capture;
  QList<bool> enabled;
  QStringList captures;
  QList<bool> flashes;
  std::unique_ptr<QTemporaryDir> home;
};

FakeGnome& gnome() {
  static FakeGnome fake;
  return fake;
}

class FakeShell : public GnomeShell {
public:
  void inspect(std::function<void(const Extension&)> done) override { done(gnome().extension); }
  void setEnabled(bool on, std::function<void(const QString& error)> done) override {
    gnome().enabled.append(on);
    gnome().extension.state = on ? 1 : 2;
    gnome().extension.service = on ? 2 : 0;
    done({});
  }
  void capture(const QString& busName, bool flash, std::function<void(const Capture&)> done) override {
    gnome().captures.append(busName);
    gnome().flashes.append(flash);
    done(gnome().capture);
  }
};

QString dataHome() {
  return gnome().home->path();
}

QString target() {
  return dataHome() + QStringLiteral("/gnome-shell/extensions/") + GnomeSnapShot::kUuid;
}

GnomeSnapShot::Paths paths() {
  return {kBundle, dataHome(), {}};
}

void writeInstalled(double version) {
  QDir().mkpath(target());
  QFile file(target() + QStringLiteral("/metadata.json"));
  expect(file.open(QIODevice::WriteOnly | QIODevice::Truncate), QStringLiteral("the installed extension to be writable"));
  file.write(QJsonDocument(QJsonObject{{QStringLiteral("uuid"), GnomeSnapShot::kUuid},
                                       {QStringLiteral("version"), version},
                                       {QStringLiteral("shell-version"), QJsonArray{QStringLiteral("47")}}})
                 .toJson());
}

double bundled() {
  return GnomeSnapShot::metadata(kBundle).value_or(GnomeSnapShot::Metadata{}).version;
}

double installedVersion() {
  return GnomeSnapShot::metadata(target()).value_or(GnomeSnapShot::Metadata{}).version;
}

// A GNOME session where GNOME 47 has answered nothing about the extension.
void session(World& world, bool picker = true) {
  gnome() = {};
  gnome().home = std::make_unique<QTemporaryDir>();
  gnome().extension.shellVersion = QStringLiteral("47.2");
  QImage image(64, 48, QImage::Format_RGB32);
  image.fill(Qt::darkCyan);
  QBuffer png(&gnome().capture.png);
  png.open(QIODevice::WriteOnly);
  image.save(&png, "PNG");
  gnome().capture.metadata = QStringLiteral("{\"title\":\"Docs\",\"appName\":\"Firefox\"}");
  gnomeSession(
      world,
      [](SnapShotBackend* portal, QObject* parent) -> SnapShotBackend* {
        return new GnomeSnapShot(portal, new FakeShell, paths(), parent);
      },
      picker);
}

// The extension loaded by GNOME, in the state GetExtensionInfo reports.
void loaded(double version, int state) {
  writeInstalled(version);
  gnome().extension.state = state;
  gnome().extension.version = version;
}

void enabled() {
  loaded(bundled(), 1);
  gnome().extension.service = 2;
}

// What the session's extension folder and backups hold, to compare.
QStringList files() {
  QStringList found;
  QDirIterator it(dataHome(), QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System, QDirIterator::Subdirectories);
  while (it.hasNext()) found.append(it.next());
  found.sort();
  return found;
}

QStringList before;

void expectWizard(World& world, const QString& key, const QString& value) {
  expect(field(world, QStringLiteral("wizard.") + key) == value, QStringLiteral("setup's %1 to be %2; Snap Shot is %3").arg(key, value, describe(world)));
}

void onAccessStep(World& world) {
  openPanel(world);
  send(world, QStringLiteral("setup.open"), {{QStringLiteral("step"), QStringLiteral("access")}});
}

// The flash and animation rows say it (TurnSteps' "the user is told").
void toldByEffects(World& world) {
  openPanel(world);
  world.toldInPlace = [&world] {
    return QStringList{field(world, QStringLiteral("flash.status")).toString(), field(world, QStringLiteral("animations.status")).toString()};
  };
}

void chooseStep(World& world, const QString& action) {
  onAccessStep(world);
  before = files();
  send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), action}});
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a GNOME session where the extension (?:is )?(not installed|was just installed|installed but waiting for a new login|"
                      "installed but too old|installed while GNOME extensions are off|installed but turned off|enabled and answering|failing to start)"),
       [](World& world, const Captures& c, const Table&) {
         session(world);
         const QString& state = c[0];
         if (state == QLatin1String("was just installed") || state.endsWith(QLatin1String("new login"))) {
           writeInstalled(bundled());
         } else if (state.endsWith(QLatin1String("too old"))) {
           loaded(bundled() - 1, 2);
         } else if (state.endsWith(QLatin1String("are off"))) {
           loaded(bundled(), 2);
           gnome().extension.userExtensionsEnabled = false;
         } else if (state.endsWith(QLatin1String("turned off"))) {
           loaded(bundled(), 2);
         } else if (state.startsWith(QLatin1String("enabled"))) {
           enabled();
         } else if (state.startsWith(QLatin1String("failing"))) {
           loaded(bundled(), 3);
           gnome().extension.error = QStringLiteral("JS ERROR");
         }
         openPanel(world);
       });
  step(QStringLiteral("setup says %1 with the action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectWizard(world, QStringLiteral("heading"), c[0]);
    expectWizard(world, QStringLiteral("continueLabel"), c[1]);
  });
  step(QStringLiteral("the user continues setup"), [](World& world, const Captures&, const Table&) { onAccessStep(world); });
  step(QStringLiteral("the user is asked to sign out and back in, and setup waits for that"), [](World& world, const Captures&, const Table&) {
    expectWizard(world, QStringLiteral("heading"), QStringLiteral("Extension installed"));
    expectWizard(world, QStringLiteral("step"), QStringLiteral("access"));
    expect(field(world, QStringLiteral("wizard.body")).toString().contains(QLatin1String("sign out")), describe(world));
  });

  step(QStringLiteral("a GNOME version the extension does not support"), [](World& world, const Captures&, const Table&) {
    session(world);
    gnome().extension.shellVersion = QStringLiteral("44.1");
    openPanel(world);
  });
  step(QStringLiteral("it points to Take snapshot in the command palette to choose a window"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.body")).toString().contains(QLatin1String("Take snapshot from the command palette")), describe(world));
  });
  step(QStringLiteral("the user can still finish setup"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.continue"));
    expectWizard(world, QStringLiteral("step"), QStringLiteral("shortcut"));
    expect(field(world, QStringLiteral("backend")) == QLatin1String("picker"), describe(world));
  });

  step(QStringLiteral("the GNOME extension is (enabled|installed but turned off)"), [](World& world, const Captures& c, const Table&) {
    session(world);
    if (c[0] == QLatin1String("enabled")) {
      enabled();
    } else {
      loaded(bundled(), 2);
    }
    openPanel(world);
  });
  step(QStringLiteral("the user opens Advanced for the GNOME extension"), [](World& world, const Captures&, const Table&) { onAccessStep(world); });
  step(QStringLiteral("they can disable the extension, and turn it back on"), [](World& world, const Captures&, const Table&) {
    const QVariantMap option = field(world, QStringLiteral("wizard.advanced")).toList().value(0).toMap();
    expect(option.value(QStringLiteral("action")) == QLatin1String("disable-extension") &&
               option.value(QStringLiteral("note")).toString().contains(QLatin1String("No download needed")),
           describe(world));
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), option.value(QStringLiteral("action"))}});
    expect(gnome().enabled == QList<bool>{false}, QStringLiteral("GNOME to be asked to disable it"));
    expectWizard(world, QStringLiteral("action"), QStringLiteral("enable-extension"));
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), QStringLiteral("enable-extension")}});
    expect(gnome().enabled == QList<bool>({false, true}), QStringLiteral("GNOME to be asked to enable it"));
    expectWizard(world, QStringLiteral("heading"), QStringLiteral("Capture is ready"));
  });

  step(QStringLiteral("a GNOME session that still needs a new login"), [](World& world, const Captures&, const Table&) {
    session(world);
    writeInstalled(bundled());
    onAccessStep(world);
  });
  step(QStringLiteral("the user checks again"), [](World& world, const Captures&, const Table&) { send(world, QStringLiteral("setup.continue")); });
  step(QStringLiteral("the answer is acknowledged and setup keeps asking for the login"), [](World& world, const Captures&, const Table&) {
    expectWizard(world, QStringLiteral("checkMessage"), QStringLiteral("Still waiting for you to sign out and back in."));
    expectWizard(world, QStringLiteral("heading"), QStringLiteral("Extension installed"));
  });

  step(QStringLiteral("a GNOME session with an older HAL-C2 extension installed"), [](World& world, const Captures&, const Table&) {
    session(world);
    loaded(bundled() - 1, 1);
  });
  step(QStringLiteral("the user updates the extension in setup"), [](World& world, const Captures&, const Table&) {
    chooseStep(world, QStringLiteral("install-extension"));
  });
  step(QStringLiteral("the new extension is put in place in one step"), [](World&, const Captures&, const Table&) {
    expect(installedVersion() == bundled(), QStringLiteral("the bundled version in place; it is %1").arg(installedVersion()));
    expect(QFile::exists(target() + QStringLiteral("/captureService.js")), QStringLiteral("the bundle's files in place"));
    const QStringList staged = QDir(QFileInfo(target()).path()).entryList({QStringLiteral(".hal-c2-capture-install-*")}, QDir::Dirs | QDir::Hidden);
    expect(staged.isEmpty(), QStringLiteral("no staging left; found %1").arg(staged.join(u',')));
  });
  step(QStringLiteral("the replaced version is kept in a backup folder"), [](World&, const Captures&, const Table&) {
    const QString backups = dataHome() + QStringLiteral("/hal-c2/extension-backups");
    const QStringList boxes = QDir(backups).entryList({QStringLiteral("capture-*")}, QDir::Dirs);
    expect(boxes.size() == 1, QStringLiteral("one backup; found %1").arg(boxes.join(u',')));
    const auto kept = GnomeSnapShot::metadata(backups + u'/' + boxes[0] + u'/' + GnomeSnapShot::kUuid);
    expect(kept && kept->version == bundled() - 1, QStringLiteral("the old version in the backup"));
  });
  step(QStringLiteral("a failed update puts the old version back"), [](World&, const Captures&, const Table&) {
    writeInstalled(bundled() - 1);
    GnomeSnapShot::Paths failing = paths();
    const QString place = target();
    failing.rename = [place](const QString& from, const QString& to) { return to != place && QDir().rename(from, to); };
    expect(!GnomeSnapShot::install(failing).isEmpty(), QStringLiteral("the update to fail"));
    expect(installedVersion() == bundled() - 1, QStringLiteral("the old version back; it is %1").arg(installedVersion()));
  });

  step(QStringLiteral("a GNOME session with a newer HAL-C2 extension installed than the one bundled with the app"),
       [](World& world, const Captures&, const Table&) {
         session(world);
         loaded(bundled() + 1, 1);
       });
  step(QStringLiteral("the HAL-C2 extension's folder is a link or not a regular folder"), [](World& world, const Captures&, const Table&) {
    session(world);
    QTemporaryDir elsewhere;
    QDir().mkpath(QFileInfo(target()).path());
    // A link to nowhere counts too.
    expect(QFile::link(elsewhere.path() + QStringLiteral("/gone"), target()), QStringLiteral("the link to be made"));
  });
  step(QStringLiteral("the user installs the extension in setup"), [](World& world, const Captures&, const Table&) {
    chooseStep(world, QStringLiteral("install-extension"));
  });
  step(QStringLiteral("nothing is replaced"), [](World&, const Captures&, const Table&) {
    expect(files() == before, QStringLiteral("the files as they were; they are %1").arg(files().join(u',')));
  });
  step(QStringLiteral("the user is told a newer extension is installed and to update HAL-C2 instead"), [](World& world, const Captures&, const Table&) {
    expectWizard(world, QStringLiteral("details"), QStringLiteral("A newer extension is installed. Update HAL-C2 instead of replacing it."));
  });
  step(QStringLiteral("the user is told to manage it in GNOME Extensions instead"), [](World& world, const Captures&, const Table&) {
    expectWizard(world, QStringLiteral("details"), QStringLiteral("The extension installation is not a regular directory. Manage it in GNOME Extensions instead."));
  });

  step(QStringLiteral("a GNOME session where the user has turned off all user extensions"), [](World& world, const Captures&, const Table&) {
    session(world);
    loaded(bundled(), 2);
    gnome().extension.userExtensionsEnabled = false;
    openPanel(world);
  });
  step(QStringLiteral("setup tells the user to turn on Extensions in the GNOME Extensions app"), [](World& world, const Captures&, const Table&) {
    expectWizard(world, QStringLiteral("heading"), QStringLiteral("Allow GNOME extensions"));
    expect(field(world, QStringLiteral("wizard.body")).toString().contains(QLatin1String("turn on Extensions")), describe(world));
  });
  step(QStringLiteral("HAL-C2 does not enable the user's other extensions"), [](World&, const Captures&, const Table&) {
    expect(gnome().enabled.isEmpty(), QStringLiteral("GNOME not to be asked to enable anything"));
  });
  step(QStringLiteral("the user is told to turn on HAL-C2 SnapShots in GNOME Extensions"), [](World& world, const Captures&, const Table&) {
    expectWizard(world, QStringLiteral("heading"), QStringLiteral("Enable the extension"));
    expect(field(world, QStringLiteral("wizard.body")).toString().contains(QLatin1String("HAL-C2 SnapShots")), describe(world));
  });

  step(QStringLiteral("the extension bundled with the app is copied for this user only"), [](World&, const Captures&, const Table&) {
    QFile list(kBundle + QStringLiteral("/bundle.json"));
    expect(list.open(QIODevice::ReadOnly), QStringLiteral("the bundle to list its files"));
    const QJsonArray bundle = QJsonDocument::fromJson(list.readAll()).object().value(QLatin1String("files")).toArray();
    expect(!bundle.isEmpty(), QStringLiteral("a bundle with files"));
    for (const QJsonValue& name : bundle) {
      expect(QFile::exists(target() + u'/' + name.toString()), QStringLiteral("%1 in the user's extensions").arg(name.toString()));
    }
  });
  step(QStringLiteral("nothing is downloaded and no administrator password is asked"), [](World& world, const Captures&, const Table&) {
    // Local files and nothing else: GNOME wasn't asked for anything but its answers.
    expect(gnome().enabled.isEmpty(), QStringLiteral("GNOME not to be asked to enable it before a login"));
    expectWizard(world, QStringLiteral("heading"), QStringLiteral("Extension installed"));
  });

  step(QStringLiteral("Snap Shot is on with the GNOME extension not enabled"), [](World& world, const Captures&, const Table&) {
    session(world);
    loaded(bundled(), 2);
    turnOn(world);
  });
  step(QStringLiteral("a Linux session where the GNOME extension is installed but is the first version"), [](World& world, const Captures&, const Table&) {
    session(world);
    loaded(1, 1);
    gnome().extension.service = 1;
    turnOn(world);
    toldByEffects(world);
  });
  step(QStringLiteral("a Linux session where GNOME setup has not been finished"), [](World& world, const Captures&, const Table&) {
    session(world);
    loaded(bundled(), 2);
    turnOn(world);
    toldByEffects(world);
  });

  step(QStringLiteral("the desktop app runs (on a GNOME session|on Linux without GNOME)"), [](World& world, const Captures& c, const Table&) {
    session(world);
    if (c[0] == QLatin1String("on Linux without GNOME")) {
      gnomeSession(world, {}, true);
      world.sync();
    }
    onAccessStep(world);
    before = files();
  });
  step(QStringLiteral("setup is asked to (install the KDE Plasma capture helper|install the GNOME extension)"), [](World& world, const Captures& c, const Table&) {
    const QString action = c[0].contains(QLatin1String("KDE")) ? QStringLiteral("install-kde-helper") : QStringLiteral("install-extension");
    send(world, QStringLiteral("setup.action"), {{QStringLiteral("action"), action}});
    gnome().capture.error = SnapShotBackend::unsupportedSetup(action);
  });
  step(QStringLiteral("nothing is installed, removed or changed"), [](World&, const Captures&, const Table&) {
    expect(files() == before, QStringLiteral("the files as they were; they are %1").arg(files().join(u',')));
    expect(gnome().enabled.isEmpty(), QStringLiteral("GNOME not to be asked for anything"));
  });
  step(QStringLiteral("the user is told this step is not available in this session"), [](World& world, const Captures&, const Table&) {
    expectWizard(world, QStringLiteral("details"), gnome().capture.error);
  });

  step(QStringLiteral("a Linux Wayland session on GNOME"), [](World& world, const Captures&, const Table&) {
    session(world);
    enabled();
  });
  step(QStringLiteral("capture works through the HAL-C2 GNOME extension"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("backend")) == QLatin1String("gnome-extension") && field(world, QStringLiteral("status")) == QLatin1String("Ready to capture"),
           describe(world));
  });

  step(QStringLiteral("a GNOME session with the HAL-C2 extension enabled"), [](World& world, const Captures&, const Table&) {
    session(world);
    enabled();
    openThreadForCapture(world);
    turnOn(world);
  });
  step(QStringLiteral("the desktop portal can capture a single window"), [](World& world, const Captures&, const Table&) {
    session(world, false);
    enabled();
    openThreadForCapture(world);
    turnOn(world);
  });
  step(QStringLiteral("the capture goes through the desktop portal"), [](World&, const Captures&, const Table&) {
    expect(portalCaptures() == 1, QStringLiteral("the portal to capture once; it did %1 times").arg(portalCaptures()));
  });
  step(QStringLiteral("the extension is not asked for the screenshot"), [](World&, const Captures&, const Table&) {
    expect(gnome().captures.isEmpty(), QStringLiteral("no capture through the extension"));
  });

  step(QStringLiteral("a GNOME session with two HAL-C2 instances running"), [](World& world, const Captures&, const Table&) {
    session(world);
    enabled();
    openThreadForCapture(world);
    turnOn(world);
  });
  step(QStringLiteral("one instance is capturing a window"), [](World&, const Captures&, const Table&) {
    // The name is held by the other instance: DBusGnomeShell answers this.
    gnome().capture.error = QStringLiteral("Another HAL-C2 instance is capturing a window. Try again.");
  });
  step(QStringLiteral("the other instance's user presses the Snap Shot shortcut"), [](World& world, const Captures&, const Table&) { pressShortcut(world); });
  step(QStringLiteral("that capture fails and the user is told another HAL-C2 instance is capturing and to try again"), [](World& world, const Captures&, const Table&) {
    expect(gnome().captures.size() == 1 && portalCaptures() == 0, QStringLiteral("no other capture tried"));
    expect(attachmentCount(world) == 0, QStringLiteral("nothing attached"));
    expectFailureToast(world, QStringLiteral("Another HAL-C2 instance is capturing a window. Try again."));
  });
});

}  // namespace
