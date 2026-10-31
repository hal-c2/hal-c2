// The capture shortcut kept in the compositor's config, and Niri capture
// (features/settings/snap-shot.feature): SnapShotController and
// CaptureShortcutConfig on real files in a scratch HOME, with `niri` and
// `hyprctl` stood in for. Niri capture is NiriSnapShot itself, on a fake IPC
// socket and the test's own bus.

#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QPointer>
#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QSemaphore>
#include <QTemporaryDir>

#include <memory>

#include "CaptureShortcutConfig.h"
#include "FakeDesktopPortal.h"
#include "Harness.h"
#include "NativeShell.h"
#include "PortalSnapShot.h"
#include "SnapShotBackend.h"
#include "SnapShotController.h"
#include "World.h"

namespace snapshot {
void openPanel(World& world);
QVariant field(World& world, const QString& path);
QString describe(World& world);
void send(World& world, const QString& action, const QVariantMap& payload = {});
void set(World& world, const QString& key, const QVariant& value);
QVariant setting(World& world, const QString& key);
void press(World& world, int key, Qt::KeyboardModifiers modifiers);
void session(World& world, const QProcessEnvironment& env);
void shortcutRefused(const QString& reason);
void holdShortcuts();
QStringList binds();
void thread(World& world);
void pressShortcut(World& world);
QVariantMap attachedImage(World& world);
QVariantList draftImages(World& world);
void pickerOnly(World& world);
}  // namespace snapshot

namespace {

using namespace snapshot;

// What `niri` and `hyprctl` answer, and what they were asked.
struct Compositor {
  bool niriValid = true;
  std::optional<QList<CaptureShortcutConfig::HyprlandBind>> binds = QList<CaptureShortcutConfig::HyprlandBind>{};
  QString reload;
  QStringList validated;
  int reloads = 0;
  // A step holds the tool until it has looked at the panel.
  bool hold = false;
  QSemaphore waiting;
  QSemaphore release;
};

Compositor& compositor() {
  static Compositor* state = new Compositor;
  return *state;
}

void held() {
  if (!compositor().hold) return;
  compositor().waiting.release();
  compositor().release.tryAcquire(1, 10'000);
}

[[maybe_unused]] const bool tools = [] {
  CaptureShortcutConfig::Tools fake;
  fake.validateNiri = [](const QString& path) {
    held();
    compositor().validated.append(path);
    return compositor().niriValid;
  };
  fake.hyprlandBindings = [] {
    held();
    return compositor().binds;
  };
  fake.reloadHyprland = [] {
    ++compositor().reloads;
    return compositor().reload;
  };
  SnapShotController::setConfigTools(fake);
  return true;
}();

// The scratch home, and the file a scenario reviews.
struct Scene {
  std::unique_ptr<QTemporaryDir> home;
  QString desktop;
  QString file;
  QByteArray before;
  QString chosen;
  QString staleId;
  QString backup;
  std::unique_ptr<QTemporaryDir> runtime;
  std::unique_ptr<QLocalServer> niri;
  QString niriVersion = QStringLiteral("25.11.0");
  bool focusedWindow = true;
  int shots = 0;
};

Scene& scene() {
  static Scene state;
  return state;
}

QProcessEnvironment environmentFor(const QString& desktop) {
  scene().home = std::make_unique<QTemporaryDir>();
  QProcessEnvironment env;
  env.insert(QStringLiteral("XDG_SESSION_TYPE"), QStringLiteral("wayland"));
  env.insert(QStringLiteral("XDG_CURRENT_DESKTOP"), desktop);
  env.insert(QStringLiteral("HOME"), scene().home->path());
  env.insert(QStringLiteral("XDG_CONFIG_HOME"), scene().home->filePath(QStringLiteral(".config")));
  return env;
}

void write(const QString& path, const QByteArray& bytes) {
  QDir().mkpath(QFileInfo(path).absolutePath());
  QFile file(path);
  file.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
  expect(file.open(QIODevice::WriteOnly | QIODevice::Truncate) && file.write(bytes) == bytes.size(), QStringLiteral("cannot write %1").arg(path));
}

QByteArray read(const QString& path) {
  QFile file(path);
  return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
}

// A session of `desktop` with an ordinary config, Snap Shot on, in setup's
// shortcut step.
void open(World& world, const QString& desktop, bool holdBind = false) {
  compositor().niriValid = true;
  compositor().binds = QList<CaptureShortcutConfig::HyprlandBind>{};
  compositor().reload.clear();
  compositor().validated.clear();
  compositor().reloads = 0;
  compositor().hold = false;
  scene().desktop = desktop;
  scene().chosen.clear();
  scene().staleId.clear();
  scene().backup.clear();
  const QProcessEnvironment env = environmentFor(desktop);
  const bool niri = desktop == QLatin1String("niri");
  scene().file = niri ? CaptureShortcutConfig::niriConfigPath(env) : CaptureShortcutConfig::hyprlandConfigPath(env);
  scene().before = niri ? QByteArrayLiteral("binds {\n    Mod+T { spawn \"foot\"; }\n}\n") : QByteArrayLiteral("bind = SUPER, T, exec, foot\n");
  write(scene().file, scene().before);
  session(world, env);
  if (holdBind) holdShortcuts();
  set(world, QStringLiteral("snapShotEnabled"), true);
  openPanel(world);
  send(world, QStringLiteral("setup.open"), {{QStringLiteral("step"), QStringLiteral("shortcut")}});
  world.toldInPlace = [&world] {
    return QStringList{field(world, QStringLiteral("config.error")).toString(), field(world, QStringLiteral("config.details")).toString(),
                       field(world, QStringLiteral("config.intro")).toString(), field(world, QStringLiteral("shortcut.status")).toString()};
  };
}

// Sets config.* again until the worker has answered.
void settle(World& world) {
  world.waitFor([&] { return field(world, QStringLiteral("config.canReview")).toBool() || field(world, QStringLiteral("config.review")).isValid() ||
                             !field(world, QStringLiteral("config")).isValid(); },
                [&] { return QStringLiteral("the config change to settle; Snap Shot is %1").arg(describe(world)); });
  world.waitFor([&] { return field(world, QStringLiteral("config.reviewLabel")) == QLatin1String("Review changes") &&
                             !field(world, QStringLiteral("config.review.saveLabel")).toString().endsWith(u'…'); },
                [&] { return QStringLiteral("the config change to finish; Snap Shot is %1").arg(describe(world)); });
}

void review(World& world, const QVariantMap& payload = {}) {
  send(world, QStringLiteral("config.review"), payload);
  settle(world);
}

void reviewed(World& world) {
  review(world);
  expect(field(world, QStringLiteral("config.review.changed")).toBool(), QStringLiteral("a diff; Snap Shot is %1").arg(describe(world)));
}

void save(World& world) {
  send(world, QStringLiteral("config.save"));
  settle(world);
  const QString backup = field(world, QStringLiteral("config.backup")).toString();
  if (!backup.isEmpty()) scene().backup = backup;
}

void expectUnchanged(World& world) {
  if (!QFileInfo(scene().file).isReadable()) QFile(scene().file).setPermissions(QFile::ReadOwner | QFile::WriteOwner);
  expect(read(scene().file) == scene().before, QStringLiteral("the config not to change; it holds %1; Snap Shot is %2").arg(QString::fromUtf8(read(scene().file)), describe(world)));
}

void expectDetails(World& world, const QString& reason) {
  expect(field(world, QStringLiteral("config.details")) == reason, QStringLiteral("the reason \"%1\"; Snap Shot is %2").arg(reason, describe(world)));
}

QString diffText(World& world, const QString& kind) {
  QStringList lines;
  for (const QVariant& line : field(world, QStringLiteral("config.review.lines")).toList()) {
    if (line.toMap().value(QStringLiteral("kind")) == kind) lines.append(line.toMap().value(QStringLiteral("text")).toString());
  }
  return lines.join(u'\n');
}

// Niri's IPC: one JSON line in, one out, and the event stream.
void serveNiri() {
  // A socket's path has a length limit the scratch home's can pass.
  scene().runtime = std::make_unique<QTemporaryDir>(QStringLiteral("/dev/shm/hal-c2-niri-XXXXXX"));
  scene().niri = std::make_unique<QLocalServer>();
  expect(scene().niri->listen(scene().runtime->filePath(QStringLiteral("s"))), QStringLiteral("cannot listen as Niri: %1").arg(scene().niri->errorString()));
  static QPointer<QLocalSocket> stream;
  stream = nullptr;
  QObject::connect(scene().niri.get(), &QLocalServer::newConnection, [] {
    while (QLocalSocket* socket = scene().niri->nextPendingConnection()) {
      QObject::connect(socket, &QLocalSocket::readyRead, socket, [socket] {
        while (socket->canReadLine()) {
          const QJsonDocument request = QJsonDocument::fromJson("[" + socket->readLine() + "]");
          const QJsonValue value = request.array().at(0);
          const auto reply = [&](const QJsonObject& ok) { socket->write(QJsonDocument(QJsonObject{{QStringLiteral("Ok"), ok}}).toJson(QJsonDocument::Compact) + '\n'); };
          const QJsonObject window{{QStringLiteral("id"), 7}, {QStringLiteral("pid"), 70}, {QStringLiteral("app_id"), QStringLiteral("firefox")}, {QStringLiteral("title"), QStringLiteral("Docs")}};
          if (value == QJsonValue(QStringLiteral("Version"))) {
            reply({{QStringLiteral("Version"), scene().niriVersion}});
          } else if (value == QJsonValue(QStringLiteral("EventStream"))) {
            stream = socket;
            socket->write("{\"Ok\":\"Handled\"}\n{\"WindowsChanged\":{\"windows\":[]}}\n");
          } else if (value == QJsonValue(QStringLiteral("FocusedWindow"))) {
            reply({{QStringLiteral("FocusedWindow"), scene().focusedWindow ? QJsonValue(window) : QJsonValue()}});
          } else if (value == QJsonValue(QStringLiteral("Windows"))) {
            reply({{QStringLiteral("Windows"), QJsonArray{window}}});
          } else if (value.isObject()) {
            const QString path = value[QLatin1String("Action")][QLatin1String("ScreenshotWindow")][QLatin1String("path")].toString();
            ++scene().shots;
            QImage image(32, 20, QImage::Format_RGB32);
            image.fill(Qt::darkGreen);
            image.save(path, "PNG");
            reply({{QStringLiteral("Handled"), true}});
            if (stream) stream->write(QJsonDocument(QJsonObject{{QStringLiteral("ScreenshotCaptured"), QJsonObject{{QStringLiteral("path"), path}}}}).toJson(QJsonDocument::Compact) + '\n');
          }
        }
      });
    }
  });
}

void openNiri(World& world, const QString& version, bool takeName = false) {
  compositor().hold = false;
  scene().desktop = QStringLiteral("niri");
  scene().niriVersion = version;
  scene().focusedWindow = true;
  scene().shots = 0;
  QProcessEnvironment env = environmentFor(QStringLiteral("niri"));
  serveNiri();
  env.insert(QStringLiteral("NIRI_SOCKET"), scene().niri->fullServerName());
  PortalSnapShot::useBus(FakeDesktopPortal::appConnection());
  // The test's other connection on that bus holds the name, as another HAL-C2 would.
  const QString name = QStringLiteral("hal-c2.SnapShot");
  if (takeName) {
    expect(FakeDesktopPortal::instance().otherConnection().interface()->registerService(name).isValid(), QStringLiteral("cannot hold the endpoint's name"));
  }
  session(world, env);
  set(world, QStringLiteral("snapShotEnabled"), true);
  openPanel(world);
  if (takeName) FakeDesktopPortal::instance().otherConnection().interface()->unregisterService(name);
}

const Steps steps([] {
  const QString q = kQuoted;

  // --- Sessions ---------------------------------------------------------------------

  step(QStringLiteral("a Niri or Hyprland session"), [](World& world, const Captures&, const Table&) { open(world, QStringLiteral("niri")); });
  step(QStringLiteral("a Niri or Hyprland session with a saved shortcut"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"));
    reviewed(world);
    save(world);
    send(world, QStringLiteral("setup.open"), {{QStringLiteral("step"), QStringLiteral("shortcut")}});
    scene().before = read(scene().file);
  });
  // Its tool waits, so a step can see what shows while it runs.
  step(QStringLiteral("a Hyprland session"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"));
    compositor().hold = true;
  });
  step(QStringLiteral("a Niri or Hyprland session where HAL-C2 keeps the binding in the compositor config"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    send(world, QStringLiteral("setup.close"), {{QStringLiteral("completed"), true}});
  });
  step(QStringLiteral("the shortcut row offers %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("shortcut.keys")) == c[0] && field(world, QStringLiteral("shortcut.managed")).toBool(),
           QStringLiteral("the row to offer %1; Snap Shot is %2").arg(c[0], describe(world)));
  });
  step(QStringLiteral("choosing it opens setup at the shortcut step"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("setup.open"), {{QStringLiteral("step"), QStringLiteral("shortcut")}});
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut"), QStringLiteral("the shortcut step; Snap Shot is %1").arg(describe(world)));
  });

  // --- Review -----------------------------------------------------------------------

  step(QStringLiteral("the user records a shortcut and chooses Review changes"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("record.start"));
    press(world, Qt::Key_K, Qt::ControlModifier | Qt::AltModifier);
    review(world);
  });
  step(QStringLiteral("the config's changes are shown as a diff with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("config.review.note")) == c[0] && diffText(world, QStringLiteral("added")).contains(QLatin1String("Ctrl+Alt+K")),
           QStringLiteral("the diff and %1; Snap Shot is %2").arg(c[0], describe(world)));
  });
  step(QStringLiteral("nothing is written until the user chooses Save shortcut"), [](World& world, const Captures&, const Table&) {
    expectUnchanged(world);
    expect(field(world, QStringLiteral("config.review.saveLabel")) == QLatin1String("Save shortcut"), QStringLiteral("Save shortcut; Snap Shot is %1").arg(describe(world)));
    save(world);
    expect(read(scene().file).contains("Ctrl+Alt+K"), QStringLiteral("the file to gain the binding: %1; Snap Shot is %2").arg(QString::fromUtf8(read(scene().file)), describe(world)));
  });
  step(QStringLiteral("the user chooses Review changes"), [](World& world, const Captures&, const Table&) {
    if (compositor().hold) {
      send(world, QStringLiteral("config.review"));
      compositor().waiting.acquire();
      return;
    }
    review(world);
  });
  step(QStringLiteral("the button reads %1 until the proposal arrives").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("config.reviewLabel")) == c[0] && !field(world, QStringLiteral("config.canReview")).toBool(),
           QStringLiteral("%1; Snap Shot is %2").arg(c[0], describe(world)));
  });
  step(QStringLiteral("the desktop cannot prepare the changes"), [](World& world, const Captures&, const Table&) {
    compositor().binds.reset();
    compositor().hold = false;
    compositor().release.release();
    settle(world);
  });
  step(QStringLiteral("the technical reason is under Advanced"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("config.details")).toString().isEmpty(), QStringLiteral("a reason; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user can try the review again"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("config.canReview")).toBool(), QStringLiteral("Review changes to be offered; Snap Shot is %1").arg(describe(world)));
    compositor().binds = QList<CaptureShortcutConfig::HyprlandBind>{};
    reviewed(world);
  });
  step(QStringLiteral("the user is reviewing a diff for the shortcut Ctrl\\+Shift\\+1"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    send(world, QStringLiteral("record.start"));
    press(world, Qt::Key_Exclam, Qt::ControlModifier | Qt::ShiftModifier);
    reviewed(world);
  });
  step(QStringLiteral("the user records Ctrl\\+Shift\\+3"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("record.start"));
    press(world, Qt::Key_NumberSign, Qt::ControlModifier | Qt::ShiftModifier);
  });
  step(QStringLiteral("the old diff is withdrawn and the user reviews again"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("config.review")).isValid(), QStringLiteral("no diff; Snap Shot is %1").arg(describe(world)));
    reviewed(world);
    expect(diffText(world, QStringLiteral("added")).contains(QLatin1String("Ctrl+Shift+3")), QStringLiteral("the new keys; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user is reviewing a diff"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    reviewed(world);
    world.answerQuestion = [&world](bool) { send(world, QStringLiteral("config.cancel")); };
  });
  step(QStringLiteral("the config is not written and setup is not finished"), [](World& world, const Captures&, const Table&) {
    expectUnchanged(world);
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut") && !field(world, QStringLiteral("config.review")).isValid(),
           QStringLiteral("setup still open, no diff; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the config already holds the shortcut"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    reviewed(world);
    save(world);
    send(world, QStringLiteral("setup.open"), {{QStringLiteral("step"), QStringLiteral("shortcut")}});
    scene().before = read(scene().file);
  });
  step(QStringLiteral("the user reviews changes"), [](World& world, const Captures&, const Table&) { review(world); });
  step(QStringLiteral("the user can choose Done"), [](World& world, const Captures&, const Table&) {
    expectUnchanged(world);
    expect(field(world, QStringLiteral("wizard.doneEnabled")).toBool(), QStringLiteral("Done; Snap Shot is %1").arg(describe(world)));
    send(world, QStringLiteral("setup.done"));
    expect(!field(world, QStringLiteral("wizard")).isValid(), QStringLiteral("setup closed; Snap Shot is %1").arg(describe(world)));
  });

  // --- Saving -----------------------------------------------------------------------

  step(QStringLiteral("the user reviewed a diff and saves it"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"));
    reviewed(world);
  });
  step(QStringLiteral("the config is written and the desktop reloaded"), [](World& world, const Captures&, const Table&) {
    save(world);
    expect(read(scene().file).contains("global, hal-c2") && compositor().reloads == 1, QStringLiteral("the binding and a reload: %1").arg(QString::fromUtf8(read(scene().file))));
  });
  step(QStringLiteral("the user is told \"Shortcut saved\" and to use the shortcut from another app"), [](World& world, const Captures&, const Table&) {
    const QVariantList toasts = world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    const bool told = std::any_of(toasts.begin(), toasts.end(), [](const QVariant& toast) {
      return toast.toMap().value(QStringLiteral("title")) == QLatin1String("Shortcut saved") &&
             toast.toMap().value(QStringLiteral("description")) == QLatin1String("Use Ctrl+Shift+2 from another app.");
    });
    expect(told, QStringLiteral("the toast; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("setup closes"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("wizard")).isValid(), QStringLiteral("setup closed; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the config is written but the desktop could not reload"), [](World& world, const Captures&, const Table&) {
    compositor().reload = QStringLiteral("Config saved, but Hyprland couldn't reload it. Run hyprctl reload.");
    save(world);
  });
  step(QStringLiteral("setup does not finish"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut") && !field(world, QStringLiteral("wizard.doneEnabled")).toBool(),
           QStringLiteral("setup open and unfinished; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the write fails"), [](World& world, const Captures&, const Table&) {
    // The file the review read has changed, so nothing may be written.
    write(scene().file, scene().before + "# edited\n");
    scene().before = read(scene().file);
    save(world);
    expectUnchanged(world);
  });
  step(QStringLiteral("the old diff is withdrawn"), [](World& world, const Captures&, const Table&) {
    expect(!field(world, QStringLiteral("config.review")).isValid(), QStringLiteral("no diff; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user chooses Remove shortcut under Advanced and reviews the change"), [](World& world, const Captures&, const Table&) {
    review(world, {{QStringLiteral("remove"), true}});
  });
  step(QStringLiteral("the diff removes only HAL-C2's binding"), [](World& world, const Captures&, const Table&) {
    expect(diffText(world, QStringLiteral("added")).isEmpty() && diffText(world, QStringLiteral("removed")).contains(QLatin1String("global, hal-c2")) &&
               !diffText(world, QStringLiteral("removed")).contains(QLatin1String("foot")),
           QStringLiteral("only the binding removed; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("saving says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    save(world);
    expect(field(world, QStringLiteral("config.intro")) == c[0], QStringLiteral("%1; Snap Shot is %2").arg(c[0], describe(world)));
    expect(!read(scene().file).contains("hal-c2"), QStringLiteral("the binding gone: %1").arg(QString::fromUtf8(read(scene().file))));
  });
  step(QStringLiteral("with no binding to remove the user is told %1").arg(q), [](World& world, const Captures& c, const Table&) {
    review(world, {{QStringLiteral("remove"), true}});
    expect(field(world, QStringLiteral("config.intro")) == c[0], QStringLiteral("%1; Snap Shot is %2").arg(c[0], describe(world)));
  });
  step(QStringLiteral("the user opens Advanced and chooses a different file"), [](World& world, const Captures&, const Table&) {
    const QString real = scene().home->filePath(QStringLiteral("dotfiles/niri.kdl"));
    write(real, scene().before);
    scene().chosen = scene().home->filePath(QStringLiteral(".config/mine.kdl"));
    QFile::link(real, scene().chosen);
    scene().before = read(real);
    scene().file = real;
    review(world, {{QStringLiteral("file"), scene().chosen}});
  });
  step(QStringLiteral("the changes are prepared against that file"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("config.review.changed")).toBool(), QStringLiteral("a diff; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the panel shows which settings file is in use, including a link's target and that it will be kept"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("config.file")) == scene().chosen &&
               field(world, QStringLiteral("config.review.linked")) == QStringLiteral("Linked to %1. The link will be kept.").arg(QFileInfo(scene().file).canonicalFilePath()),
           QStringLiteral("the file and its link; Snap Shot is %1").arg(describe(world)));
    save(world);
    expect(QFileInfo(scene().chosen).isSymLink(), QStringLiteral("the link to be kept"));
  });
  step(QStringLiteral("the user opens Advanced"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("the binding is shown with where to paste it and a way to copy it"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("config.binding")).toString().contains(QLatin1String("--dest\" \"hal-c2.SnapShot\"")) &&
               field(world, QStringLiteral("config.manual")).toString().startsWith(QLatin1String("Paste this inside binds")),
           QStringLiteral("the binding and where it goes; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("copying says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    send(world, QStringLiteral("config.copy"));
    expect(field(world, QStringLiteral("config.copyLabel")) == c[0] && QGuiApplication::clipboard()->text() == field(world, QStringLiteral("config.binding")).toString(),
           QStringLiteral("%1 and the binding on the clipboard; Snap Shot is %2").arg(c[0], describe(world)));
  });
  step(QStringLiteral("the user saved the shortcut into the config"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"));
    compositor().reload = QStringLiteral("Config saved, but Hyprland couldn't reload it. Run hyprctl reload.");
    reviewed(world);
    scene().before = read(scene().file);
    save(world);
  });
  step(QStringLiteral("the backup file's path is shown"), [](World& world, const Captures&, const Table&) {
    const QString path = field(world, QStringLiteral("config.backup")).toString().mid(QStringLiteral("Backup: ").size());
    expect(!path.isEmpty() && read(path) == scene().before, QStringLiteral("a backup with the old config; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("a Hyprland session where HAL-C2's shortcut action is not registered yet"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"), true);
  });
  step(QStringLiteral("setup says %1 while it connects").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world, QStringLiteral("config.connecting")) == c[0], QStringLiteral("%1; Snap Shot is %2").arg(c[0], describe(world)));
  });
  step(QStringLiteral("%1 when it is not coming").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world, QStringLiteral("snapShotEnabled"), false);
    shortcutRefused(QStringLiteral("no answer"));
    set(world, QStringLiteral("snapShotEnabled"), true);
    world.waitFor([&] { return field(world, QStringLiteral("config.connecting")) == c[0]; }, [&] { return QStringLiteral("%1; Snap Shot is %2").arg(c[0], describe(world)); });
  });

  // --- Refusals ---------------------------------------------------------------------

  step(QStringLiteral("the settings file cannot be read"), [](World&, const Captures&, const Table&) { QFile(scene().file).setPermissions({}); });
  step(QStringLiteral("the settings file belongs to another user or to Omarchy defaults"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"));
    scene().chosen = scene().home->filePath(QStringLiteral(".local/share/omarchy/default/hypr/bindings.conf"));
    write(scene().chosen, "bind = SUPER, T, exec, foot\n");
    send(world, QStringLiteral("config.review"), {{QStringLiteral("file"), scene().chosen}});
  });
  step(QStringLiteral("the settings file has an unexpected extension"), [](World& world, const Captures&, const Table&) {
    scene().chosen = scene().home->filePath(QStringLiteral(".config/niri/config.txt"));
    write(scene().chosen, scene().before);
    send(world, QStringLiteral("config.review"), {{QStringLiteral("file"), scene().chosen}});
  });
  step(QStringLiteral("a Niri config includes files by pattern or variable"), [](World&, const Captures&, const Table&) {
    scene().before = "include \"parts/*.kdl\"\nbinds {\n}\n";
    write(scene().file, scene().before);
  });
  step(QStringLiteral("a Niri config includes more than 64 files or nests deeper than 10 levels"), [](World&, const Captures&, const Table&) {
    QByteArray config;
    for (int i = 0; i < 65; ++i) {
      const QString name = QStringLiteral("part%1.kdl").arg(i);
      write(QFileInfo(scene().file).absoluteDir().filePath(name), "");
      config += "include \"" + name.toUtf8() + "\"\n";
    }
    scene().before = config + "binds {\n}\n";
    write(scene().file, scene().before);
  });
  step(QStringLiteral("a Niri include cannot be read"), [](World&, const Captures&, const Table&) {
    const QString part = QFileInfo(scene().file).absoluteDir().filePath(QStringLiteral("part.kdl"));
    write(part, "");
    QFile(part).setPermissions({});
    scene().before = "include \"part.kdl\"\nbinds {\n}\n";
    write(scene().file, scene().before);
  });
  step(QStringLiteral("a Hyprland Lua config returns early or uses long strings"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"));
    scene().chosen = scene().home->filePath(QStringLiteral(".config/hypr/hyprland.lua"));
    write(scene().chosen, "return {}\n");
    send(world, QStringLiteral("config.review"), {{QStringLiteral("file"), scene().chosen}});
  });
  step(QStringLiteral("a Niri config has more than one binds section"), [](World&, const Captures&, const Table&) {
    scene().before = "binds {\n}\nbinds {\n}\n";
    write(scene().file, scene().before);
  });
  step(QStringLiteral("nothing is changed and the user is told %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settle(world);
    expectUnchanged(world);
    expect(field(world, QStringLiteral("config.error")) == QLatin1String("Couldn't prepare the changes. Check Advanced for help."), QStringLiteral("a refusal; Snap Shot is %1").arg(describe(world)));
    expectDetails(world, c[0]);
  });
  step(QStringLiteral("the chosen keys are already bound in the config, in a file it includes, or by Hyprland itself"), [](World& world, const Captures&, const Table&) {
    const QString part = QFileInfo(scene().file).absoluteDir().filePath(QStringLiteral("part.kdl"));
    write(part, "binds {\n    Ctrl+Shift+2 { spawn \"foot\"; }\n}\n");
    scene().before = "include \"part.kdl\"\nbinds {\n}\n";
    write(scene().file, scene().before);
  });
  step(QStringLiteral("nothing is changed and the user is told the keys are already used and to choose another shortcut"), [](World& world, const Captures&, const Table&) {
    expectUnchanged(world);
    expect(field(world, QStringLiteral("config.details")).toString().contains(QLatin1String("already")), QStringLiteral("the keys refused; Snap Shot is %1").arg(describe(world)));
    // Hyprland's own binds count too.
    open(world, QStringLiteral("hyprland"));
    compositor().binds = QList<CaptureShortcutConfig::HyprlandBind>{{5, QStringLiteral("2"), QStringLiteral("exec"), QStringLiteral("foot")}};
    review(world);
    expectUnchanged(world);
    expect(field(world, QStringLiteral("config.details")).toString().contains(QLatin1String("already")), QStringLiteral("Hyprland's keys refused; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("a Hyprland session that cannot report its current shortcuts"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"));
    compositor().binds.reset();
  });
  step(QStringLiteral("the user is told to try again from the Hyprland session"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("config.details")).toString().contains(QLatin1String("Hyprland session")), QStringLiteral("to try from the session; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("nothing is changed"), [](World& world, const Captures&, const Table&) { expectUnchanged(world); });
  step(QStringLiteral("the desktop is saving a reviewed shortcut change"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    reviewed(world);
    compositor().hold = true;
    send(world, QStringLiteral("config.save"));
    compositor().waiting.acquire();
  });
  step(QStringLiteral("the user tries to cancel the review, record other keys, go back, turn capture off and close setup"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("config.cancel"));
    send(world, QStringLiteral("record.start"));
    send(world, QStringLiteral("setup.back"));
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), false}});
    send(world, QStringLiteral("setup.close"), {{QStringLiteral("completed"), false}});
    send(world, QStringLiteral("config.complete"));
    send(world, QStringLiteral("setup.done"));
  });
  step(QStringLiteral("setup stays open on the review until the save finishes"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("config.busy")).toBool() && !field(world, QStringLiteral("config.review.id")).toString().isEmpty() &&
               field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut") &&
               field(world, QStringLiteral("switchOn")).toBool(),
           QStringLiteral("the review to stay; Snap Shot is %1").arg(describe(world)));
    compositor().hold = false;
    compositor().release.release();
    settle(world);
    expect(read(scene().file).contains("hal-c2"), QStringLiteral("the save to land: %1").arg(QString::fromUtf8(read(scene().file))));
  });
  step(QStringLiteral("the desktop is saving a reviewed shortcut change the user was still recording over"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    reviewed(world);
    send(world, QStringLiteral("record.start"));
    expect(field(world, QStringLiteral("shortcut.recording")).toBool(), QStringLiteral("recording; Snap Shot is %1").arg(describe(world)));
    compositor().hold = true;
    send(world, QStringLiteral("config.save"));
    compositor().waiting.acquire();
  });
  step(QStringLiteral("the user presses other keys"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("record.key"), {{QStringLiteral("key"), int(Qt::Key_K)}, {QStringLiteral("modifiers"), int(Qt::ControlModifier | Qt::AltModifier)}});
    expect(!field(world, QStringLiteral("shortcut.recording")).toBool(), QStringLiteral("the save to end the recording; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user has a shortcut change under review"), [](World& world, const Captures&, const Table&) { reviewed(world); });
  step(QStringLiteral("the user turns capture off and on again"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), false}});
    send(world, QStringLiteral("enable"), {{QStringLiteral("on"), true}});
  });
  step(QStringLiteral("no config change is under review"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("wizard.step")) == QLatin1String("shortcut") && !field(world, QStringLiteral("config.review")).isValid(),
           QStringLiteral("setup without the review; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user asks to review another change"), [](World& world, const Captures&, const Table&) { send(world, QStringLiteral("config.review")); });
  step(QStringLiteral("the user is told to wait for the current config change to finish"), [](World& world, const Captures&, const Table&) {
    expectDetails(world, QStringLiteral("Wait for the current config change to finish."));
    compositor().hold = false;
    compositor().release.release();
    settle(world);
  });
  step(QStringLiteral("the user records a shortcut of Shift and a letter, or of a punctuation key"), [](World& world, const Captures&, const Table&) {
    for (const auto& [key, modifiers] : {std::pair<int, int>{Qt::Key_K, Qt::ShiftModifier}, std::pair<int, int>{Qt::Key_Comma, Qt::ControlModifier | Qt::AltModifier}}) {
      send(world, QStringLiteral("record.start"));
      press(world, key, Qt::KeyboardModifiers(modifiers));
      expect(field(world, QStringLiteral("shortcut.status")) == QLatin1String("Choose a letter, number, or function key with Ctrl, Alt, or Super."),
             QStringLiteral("the keys refused; Snap Shot is %1").arg(describe(world)));
    }
  });
  step(QStringLiteral("the user is told to choose a letter, number or function key with Ctrl, Alt or Super"), [](World& world, const Captures&, const Table&) {
    review(world);
    expectUnchanged(world);
    expectDetails(world, QStringLiteral("Choose a letter, number, or function key with Ctrl, Alt, or Super."));
  });
  step(QStringLiteral("the user reviewed a change to the Niri config"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    reviewed(world);
  });
  step(QStringLiteral("Niri validates the new config first"), [](World&, const Captures&, const Table&) {
    expect(compositor().validated.size() == 1 && compositor().validated.first() != scene().file, QStringLiteral("a stand-in validated: %1").arg(compositor().validated.join(u',')));
    expect(!QFile::exists(compositor().validated.first()), QStringLiteral("the stand-in to be gone"));
  });
  step(QStringLiteral("a config Niri rejects is not saved"), [](World& world, const Captures&, const Table&) {
    scene().before = read(scene().file);
    send(world, QStringLiteral("record.start"));
    press(world, Qt::Key_K, Qt::ControlModifier | Qt::AltModifier);
    reviewed(world);
    compositor().niriValid = false;
    save(world);
    expectUnchanged(world);
    expect(field(world, QStringLiteral("config.details")).toString().startsWith(QLatin1String("Niri couldn't validate")), QStringLiteral("Niri's refusal; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user reviewed a change to a config that uses Windows line endings and is readable only by the user"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    scene().before = "binds {\r\n    Mod+T { spawn \"foot\"; }\r\n}\r\n";
    write(scene().file, scene().before);
    QFile(scene().file).setPermissions(QFile::ReadOwner | QFile::WriteOwner);
    reviewed(world);
  });
  step(QStringLiteral("the new binding uses the same line endings"), [](World&, const Captures&, const Table&) {
    const QByteArray after = read(scene().file);
    expect(after.contains("Ctrl+Shift+2") && after.count('\n') == after.count("\r\n"), QStringLiteral("CRLF throughout: %1").arg(QString::fromUtf8(after)));
  });
  step(QStringLiteral("the file keeps its permissions"), [](World&, const Captures&, const Table&) {
    expect(QFile(scene().file).permissions() == (QFile::ReadOwner | QFile::WriteOwner | QFile::ReadUser | QFile::WriteUser), QStringLiteral("0600 on the file"));
  });
  step(QStringLiteral("the settings file is larger than 1 MB"), [](World&, const Captures&, const Table&) {
    scene().before = QByteArray(1024 * 1024 + 1, ' ');
    write(scene().file, scene().before);
  });
  step(QStringLiteral("the settings file and its included files add up to more than 1 MB"), [](World&, const Captures&, const Table&) {
    QByteArray config;
    for (int i = 0; i < 3; ++i) {
      const QString name = QStringLiteral("big%1.kdl").arg(i);
      write(QFileInfo(scene().file).absoluteDir().filePath(name), QByteArray(500 * 1024, ' '));
      config += "include \"" + name.toUtf8() + "\"\n";
    }
    scene().before = config + "binds {\n}\n";
    write(scene().file, scene().before);
  });
  step(QStringLiteral("the settings file is not a text file"), [](World&, const Captures&, const Table&) {
    scene().before = QByteArray("binds {\0}\n", 9);
    write(scene().file, scene().before);
  });
  step(QStringLiteral("the user reviewed a change to the Hyprland config and saves it"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("hyprland"));
    reviewed(world);
  });
  step(QStringLiteral("Hyprland reloads and reports errors in its config"), [](World& world, const Captures&, const Table&) {
    compositor().reload = QStringLiteral("Config saved, but Hyprland reported config errors. Check hyprctl configerrors, then run hyprctl reload.");
    save(world);
  });
  step(QStringLiteral("the user is told Hyprland reported config errors"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("config.intro")) == QLatin1String("Saved, but the shortcut needs attention. Check Advanced for help.") &&
               field(world, QStringLiteral("config.details")).toString().contains(QLatin1String("reported config errors")),
           QStringLiteral("config errors; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user reviewed a change to the Niri or Hyprland config"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    reviewed(world);
    scene().staleId = field(world, QStringLiteral("config.review.id")).toString();
  });
  step(QStringLiteral("the user has since reviewed another change, or the change was already saved"), [](World& world, const Captures&, const Table&) { reviewed(world); });
  step(QStringLiteral("the user saves the earlier review"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("config.save"), {{QStringLiteral("id"), scene().staleId}});
    settle(world);
  });
  step(QStringLiteral("nothing is written"), [](World& world, const Captures&, const Table&) { expectUnchanged(world); });
  step(QStringLiteral("the user is told the preview expired and to review the changes again"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("config.details")).toString().contains(QLatin1String("expired")), QStringLiteral("expired; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user reviewed a change to a Niri config that includes an optional file that does not exist"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    scene().before = "include optional=true \"maybe.kdl\"\nbinds {\n}\n";
    write(scene().file, scene().before);
    reviewed(world);
  });
  step(QStringLiteral("that file has been created since the review"), [](World&, const Captures&, const Table&) {
    write(QFileInfo(scene().file).absoluteDir().filePath(QStringLiteral("maybe.kdl")), "");
  });
  step(QStringLiteral("nothing is written and the user is asked to review again"), [](World& world, const Captures&, const Table&) {
    expectUnchanged(world);
    expect(field(world, QStringLiteral("config.error")) == QLatin1String("Couldn't save your shortcut. Review the changes and try again."), QStringLiteral("to review again; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user saves"), [](World& world, const Captures&, const Table&) { save(world); });

  // --- Compositor-managed shortcut ------------------------------------------------------

  step(QStringLiteral("the user checks a shortcut in HAL-C2"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("record.start"));
    press(world, Qt::Key_K, Qt::ControlModifier | Qt::AltModifier);
  });
  step(QStringLiteral("the shortcut row says to configure the capture shortcut in the compositor's config and save it"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.status")) == QLatin1String("Configure the capture shortcut in your Niri config, not in HAL-C2.") &&
               !field(world, QStringLiteral("shortcut.canSave")).toBool(),
           QStringLiteral("to configure it there; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("HAL-C2 does not register the shortcut itself"), [](World& world, const Captures&, const Table&) {
    expect(binds().isEmpty(), QStringLiteral("no shortcut bound; bound %1; Snap Shot is %2").arg(binds().join(u','), describe(world)));
  });

  // --- Niri ---------------------------------------------------------------------------

  step(QStringLiteral("a Niri session of version 25\\.11 or newer"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("another HAL-C2 instance already owns the endpoint"), [](World& world, const Captures&, const Table&) { openNiri(world, QStringLiteral("25.11.0"), true); });
  step(QStringLiteral("the endpoint disconnects while HAL-C2 is running"), [](World& world, const Captures&, const Table&) {
    openNiri(world, QStringLiteral("25.11.0"));
    QDBusConnection(FakeDesktopPortal::appConnection()).interface()->unregisterService(QStringLiteral("hal-c2.SnapShot"));
    world.waitFor([&] { return !field(world, QStringLiteral("shortcut.registered")).toBool(); }, [&] { return QStringLiteral("the endpoint to go; Snap Shot is %1").arg(describe(world)); });
  });
  step(QStringLiteral("the endpoint is up and the binding is not in the config yet"), [](World& world, const Captures&, const Table&) { openNiri(world, QStringLiteral("25.11.0")); });
  step(QStringLiteral("a Niri session older than version 25\\.11"), [](World& world, const Captures&, const Table&) { openNiri(world, QStringLiteral("25.8.0")); });
  step(QStringLiteral("nothing is attached and the user is told SnapShots require Niri 25\\.11 or newer"), [](World& world, const Captures&, const Table&) {
    expect(scene().shots == 0, QStringLiteral("no capture taken"));
    const QVariantList toasts = world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    const bool told = std::any_of(toasts.begin(), toasts.end(), [](const QVariant& toast) {
      return toast.toMap().value(QStringLiteral("description")) == QLatin1String("SnapShots require Niri 25.11 or newer.");
    });
    expect(told, QStringLiteral("the failure; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("a Niri session with the capture binding set up"), [](World& world, const Captures&, const Table&) { openNiri(world, QStringLiteral("25.11.0")); });
  step(QStringLiteral("another program calls the capture endpoint with arguments"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return field(world, QStringLiteral("shortcut.registered")).toBool(); }, [&] { return QStringLiteral("the endpoint; Snap Shot is %1").arg(describe(world)); });
    QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("hal-c2.SnapShot"), CaptureShortcutConfig::kNiriPath, CaptureShortcutConfig::kNiriInterface, QStringLiteral("Capture"));
    call << QStringLiteral("extra");
    const auto pending = FakeDesktopPortal::instance().otherConnection().asyncCall(call, 2000);
    auto watcher = std::make_shared<QDBusPendingCallWatcher>(pending);
    world.waitFor([&] { return watcher->isFinished(); }, QStringLiteral("the endpoint to answer"));
    world.onSettingsPage.insert(QStringLiteral("endpointError"), [name = watcher->error().name()](const QStringList&) {
      expect(name == QLatin1String("org.freedesktop.DBus.Error.InvalidArgs"), QStringLiteral("InvalidArgs, not %1").arg(name));
    });
  });
  step(QStringLiteral("the call is refused as invalid"), [](World& world, const Captures&, const Table&) { world.onSettingsPage.value(QStringLiteral("endpointError"))({}); });
  step(QStringLiteral("the desktop app runs on Linux on Niri"), [](World& world, const Captures&, const Table&) {
    openNiri(world, QStringLiteral("25.11.0"));
    thread(world);
  });
  step(QStringLiteral("Niri has no focused window"), [](World&, const Captures&, const Table&) { scene().focusedWindow = false; });
  step(QStringLiteral("a Linux Wayland session on Niri"), [](World& world, const Captures&, const Table&) {
    openNiri(world, QStringLiteral("25.11.0"));
    thread(world);
  });
  step(QStringLiteral("capture works through a Niri binding"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("shortcut.managed")).toBool() && field(world, QStringLiteral("shortcut.registered")).toBool(),
           QStringLiteral("the endpoint up; Snap Shot is %1").arg(describe(world)));
    pressShortcut(world);
    world.waitFor([&] { return !draftImages(world).isEmpty(); }, [&] { return QStringLiteral("the capture; Snap Shot is %1").arg(describe(world)); });
    expect(scene().shots == 1 && attachedImage(world).value(QStringLiteral("mimeType")) == QLatin1String("image/png"), QStringLiteral("one PNG from Niri"));
  });
  step(QStringLiteral("HAL-C2 runs inside a (\\S+) sandbox on a (\\S+(?: Plasma)?) Wayland session"), [](World& world, const Captures& c, const Table&) {
    QProcessEnvironment env = environmentFor(c[1] == QLatin1String("KDE Plasma") ? QStringLiteral("kde") : c[1].toLower());
    env.insert(c[0] == QLatin1String("Snap") ? QStringLiteral("SNAP") : QStringLiteral("FLATPAK_ID"), QStringLiteral("hal-c2"));
    // Even with Niri's socket in reach.
    env.insert(QStringLiteral("NIRI_SOCKET"), scene().home->filePath(QStringLiteral("s")));
    session(world, env);
  });
  step(QStringLiteral("capture works through the desktop portal when it can capture a window"), [](World& world, const Captures&, const Table&) {
    expect(field(world, QStringLiteral("backend")) == QLatin1String("screenshot-portal") && !field(world, QStringLiteral("shortcut.managed")).toBool(),
           QStringLiteral("the portal; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("otherwise the user picks the window each time"), [](World& world, const Captures&, const Table&) {
    pickerOnly(world);
    expect(field(world, QStringLiteral("status")) == QStringLiteral("Manual capture only — you'll choose a window each time"), QStringLiteral("the picker; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("no compositor config, extension or capture helper is offered"), [](World& world, const Captures&, const Table&) {
    const QVariant config = field(world, QStringLiteral("config"));
    expect(!config.isValid() || config.isNull(), QStringLiteral("no config; Snap Shot is %1").arg(describe(world)));
  });
  step(QStringLiteral("the user reviewed the changes to the Niri config"), [](World& world, const Captures&, const Table&) {
    open(world, QStringLiteral("niri"));
    reviewed(world);
  });
  step(QStringLiteral("the Niri config changed on disk afterwards"), [](World&, const Captures&, const Table&) {
    write(scene().file, scene().before + "# edited\n");
    scene().before = read(scene().file);
  });
  step(QStringLiteral("the user reviews the changes to the Hyprland config and saves them"), [](World& world, const Captures&, const Table&) {
    compositor().hold = false;
    reviewed(world);
    save(world);
  });
  step(QStringLiteral("the config is written in one step after checking it did not change since review"), [](World&, const Captures&, const Table&) {
    expect(read(scene().file).contains("global, hal-c2"), QStringLiteral("the binding: %1").arg(QString::fromUtf8(read(scene().file))));
    const QStringList left = QFileInfo(scene().file).absoluteDir().entryList(QDir::Files | QDir::Hidden);
    expect(left.size() == 2, QStringLiteral("only the config and its backup: %1").arg(left.join(u',')));
  });
  step(QStringLiteral("a backup of the previous config is kept"), [](World&, const Captures&, const Table&) {
    const QDir folder = QFileInfo(scene().file).absoluteDir();
    QStringList backups = folder.entryList(QDir::Files | QDir::Hidden);
    backups.removeAll(QFileInfo(scene().file).fileName());
    expect(backups.size() == 1 && read(folder.filePath(backups.first())) == scene().before, QStringLiteral("the old config kept; found %1").arg(backups.join(u',')));
  });
  step(QStringLiteral("no capture is taken"), [](World&, const Captures&, const Table&) {
    expect(scene().shots == 0, QStringLiteral("no capture; %1 taken").arg(scene().shots));
  });
});

}  // namespace

// For the capture steps every desktop shares (SnapShotMacosSteps.cpp).
int snapShotNiriShots() {
  return scene().shots;
}
