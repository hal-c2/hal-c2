#include "GnomeSnapShot.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QTemporaryDir>

#ifdef HAL_C2_HAS_DBUS
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QTimer>
#endif

namespace {

constexpr qint64 kMaxPngBytes = 32 * 1024 * 1024;

QString extensionsDir(const GnomeSnapShot::Paths& paths) {
  return paths.dataHome + QStringLiteral("/gnome-shell/extensions");
}

// The folder itself, not what a link points to; a dangling link counts.
bool present(const QFileInfo& info) {
  return info.exists() || info.isSymLink();
}

bool moveFolder(const GnomeSnapShot::Paths& paths, const QString& from, const QString& to) {
  return paths.rename ? paths.rename(from, to) : QDir().rename(from, to);
}

}  // namespace

GnomeSnapShot::GnomeSnapShot(SnapShotBackend* portal, GnomeShell* shell, const Paths& paths, QObject* parent)
    : SnapShotBackend(parent), m_portal(portal), m_shell(shell), m_paths(paths) {
  m_portal->setParent(this);
  m_shell->setParent(this);
  connect(m_portal, &SnapShotBackend::changed, this, &SnapShotBackend::changed);
  connect(m_portal, &SnapShotBackend::activated, this, &SnapShotBackend::activated);
  connect(m_portal, &SnapShotBackend::captured, this, &SnapShotBackend::captured);
  connect(m_portal, &SnapShotBackend::failed, this, &SnapShotBackend::failed);
}

bool GnomeSnapShot::extensionSetup() const {
  const Session portal = m_portal->session();
  return m_status && portal.ready && portal.message.isEmpty() && portal.backend != QLatin1String("screenshot-portal") &&
         m_status->status != QLatin1String("unsupported");
}

bool GnomeSnapShot::answering() const {
  return m_extension && (m_extension->service == 1 || m_extension->service == 2);
}

SnapShotBackend::Session GnomeSnapShot::session() const {
  Session session = m_portal->session();
  session.ready = session.ready && m_status.has_value();
  session.checking = session.checking || m_working || (m_inspecting && m_status.has_value());
  if (extensionSetup()) {
    session.backend = QStringLiteral("gnome-extension");
    session.feedbackAvailable = m_extension->service == 2;
  }
  return session;
}

void GnomeSnapShot::probe() {
  m_portal->probe();
  if (!m_status && !m_inspecting) inspect();
}

void GnomeSnapShot::refresh() {
  m_portal->refresh();
  // A step under way looks again when it is done.
  if (m_working) return;
  inspect();
  emit changed();
}

void GnomeSnapShot::inspect(std::function<void()> then) {
  const quint64 id = ++m_inspection;
  m_inspecting = true;
  m_shell->inspect([this, id, then = std::move(then)](const GnomeShell::Extension& extension) {
    if (id != m_inspection) return;
    m_inspecting = false;
    m_extension = extension;
    const auto bundled = metadata(m_paths.bundle);
    m_status = bundled ? status(extension, *bundled, metadata(extensionsDir(m_paths) + u'/' + kUuid))
                       : Status{QStringLiteral("error"), tr("The extension is missing from this build. Update or reinstall HAL-C2.")};
    if (then) then();
    emit changed();
  });
}

void GnomeSnapShot::setEffects(bool flash, bool animate) {
  m_portal->setEffects(flash, animate);
  m_flash = flash;
}

void GnomeSnapShot::capture() {
  // The portal first, whenever it can take the window in front; and its picker
  // when the extension does not answer, which is capability missing, not denied.
  if (m_portal->session().backend == QLatin1String("screenshot-portal") || !answering()) {
    m_portal->capture();
    return;
  }
  if (m_capturing) return;
  m_capturing = true;
  m_shell->capture(busName(QGuiApplication::desktopFileName()), m_flash && m_extension->service == 2, [this](const GnomeShell::Capture& capture) {
    m_capturing = false;
    if (!capture.error.isEmpty()) {
      emit failed(capture.error);
      return;
    }
    QString error;
    const QImage image = decode(capture.png, &error);
    if (image.isNull()) {
      emit failed(error);
      return;
    }
    const QJsonObject window = QJsonDocument::fromJson(capture.metadata.toUtf8()).object();
    emit captured(image, window.value(QLatin1String("appName")).toString(), window.value(QLatin1String("title")).toString());
  });
}

std::optional<SnapShotBackend::Setup> GnomeSnapShot::setup() const {
  if (!m_status) return std::nullopt;
  const Session portal = m_portal->session();
  if (!portal.ready || !portal.message.isEmpty() || portal.backend == QLatin1String("screenshot-portal")) return std::nullopt;
  const QString& name = m_status->status;

  Setup setup;
  // Without the extension this is the picker, whose setup is only this word.
  if (name == QLatin1String("unsupported")) {
    setup.accessReady = true;
    setup.heading = tr("Automatic capture isn't available");
    setup.body = tr("Use Take snapshot from the command palette to choose a window.");
    setup.details = m_status->message;
    setup.checkMessage = tr("Ready. You'll choose a window each time.");
    return setup;
  }

  setup.status = name == QLatin1String("enabled") ? QString() : tr("Set up active-window snapshots");
  setup.effects = m_extension->service == 1                    ? tr("Update the GNOME extension, then sign out and back in to enable effects.")
                  : name != QLatin1String("enabled") || !answering() ? tr("Finish extension setup to enable effects.")
                                                                     : QString();
  setup.actionLabel = tr("Check again");
  setup.checkMessage = tr("Not ready yet. Finish the step above.");
  if (name == QLatin1String("not-installed")) {
    setup.heading = tr("Install the extension");
    setup.body = tr("The HAL-C2 GNOME extension lets you capture other windows and bring them into your draft. Sign out once after installing.");
    setup.action = QStringLiteral("install-extension");
    setup.actionLabel = tr("Install extension");
  } else if (name == QLatin1String("restart-required")) {
    setup.heading = tr("Extension installed");
    setup.body = tr("Save your work, then sign out and back in. Your setup will be waiting here.");
    setup.checkMessage = tr("Still waiting for you to sign out and back in.");
  } else if (name == QLatin1String("update-required")) {
    setup.heading = tr("Update the extension");
    setup.body = tr("Install the update, then sign out and back in.");
    setup.action = QStringLiteral("install-extension");
    setup.actionLabel = tr("Update extension");
  } else if (name == QLatin1String("extensions-disabled")) {
    setup.heading = tr("Allow GNOME extensions");
    setup.body = tr("Open GNOME Extensions and turn on Extensions, then check again.");
  } else if (name == QLatin1String("disabled")) {
    setup.heading = tr("Enable the extension");
    setup.body = tr("Enable HAL-C2 SnapShots to start capturing windows.");
    setup.action = QStringLiteral("enable-extension");
    setup.actionLabel = tr("Enable extension");
  } else if (name == QLatin1String("enabled") && answering()) {
    setup.accessReady = true;
    setup.heading = tr("Capture is ready");
    setup.body = tr("Next, choose your shortcut.");
    setup.actionLabel.clear();
    setup.checkMessage = tr("Ready. Continue to choose your shortcut.");
  } else if (name == QLatin1String("enabled")) {
    setup.heading = tr("Check capture access");
    setup.body = tr("The extension isn't ready yet. Try again in a moment.");
    setup.actionLabel.clear();
  } else {
    setup.heading = tr("Couldn't set up the extension");
    setup.body = tr("Check HAL-C2 SnapShots in GNOME Extensions, then try again.");
    setup.details = m_status->message;
    setup.checkMessage = tr("Still unable to check access. See Advanced for help.");
  }
  if (name == QLatin1String("enabled")) {
    setup.advanced.append({QStringLiteral("disable-extension"), tr("Disable extension"), tr("Included with HAL-C2. No download needed.")});
  }
  return setup;
}

void GnomeSnapShot::settled(const QString& error) {
  m_working = false;
  if (!error.isEmpty()) emit setupFailed(error);
  // Whatever it did, GNOME says where setup stands now.
  inspect();
}

void GnomeSnapShot::perform(const QString& action) {
  const bool install = action == QLatin1String("install-extension");
  const bool enable = action == QLatin1String("enable-extension");
  if (!install && !enable && action != QLatin1String("disable-extension")) {
    emit setupFailed(unsupportedSetup(action));
    return;
  }
  if (m_working) return;
  m_working = true;
  emit changed();
  // What was on screen may be out of date: GNOME is asked again before anything changes.
  inspect([this, action, install, enable] {
    const Status now = *m_status;
    if (install) {
      QString error = installBlocked(m_paths);
      if (error.isEmpty()) {
        error = now.status == QLatin1String("not-installed") || now.status == QLatin1String("update-required") ? GnomeSnapShot::install(m_paths)
                                                                                                                : now.message;
      }
      // GNOME discovers a newly installed local extension at the next login.
      settled(error);
      return;
    }
    if (enable && now.status != QLatin1String("disabled")) {
      settled(now.message);
      return;
    }
    m_shell->setEnabled(enable, [this](const QString& error) { settled(error); });
  });
}

std::optional<GnomeSnapShot::Metadata> GnomeSnapShot::metadata(const QString& dir) {
  QFile file(dir + QStringLiteral("/metadata.json"));
  if (!file.open(QIODevice::ReadOnly)) return std::nullopt;
  const QJsonObject json = QJsonDocument::fromJson(file.readAll()).object();
  if (json.value(QLatin1String("uuid")).toString() != kUuid || !json.value(QLatin1String("version")).isDouble() ||
      !json.value(QLatin1String("shell-version")).isArray()) {
    return std::nullopt;
  }
  Metadata metadata{kUuid, json.value(QLatin1String("version")).toDouble(), {}};
  for (const QJsonValue& version : json.value(QLatin1String("shell-version")).toArray()) metadata.shellVersions.append(version.toString());
  return metadata;
}

GnomeSnapShot::Status GnomeSnapShot::status(const GnomeShell::Extension& shell, const Metadata& bundled, const std::optional<Metadata>& installed) {
  const auto say = [](const char* name, const QString& message) { return Status{QLatin1String(name), message}; };
  if (!shell.failure.isEmpty()) return say("error", shell.failure);
  const QString major = shell.shellVersion.section(u'.', 0, 0);
  if (!bundled.shellVersions.contains(major)) {
    return say("unsupported", tr("The bundled extension supports GNOME %1. This session runs GNOME %2.").arg(bundled.shellVersions.join(QStringLiteral(", ")), major));
  }
  if (!shell.state && !installed) {
    return say("not-installed", tr("Install the bundled extension to capture the active window without a picker. No download or administrator password is needed."));
  }
  if (installed && (!shell.state || (shell.version && installed->version > *shell.version))) {
    return say("restart-required", tr("Installed. Save your work, sign out of GNOME and sign back in, then return here to enable the extension. Restarting HAL-C2 alone is not enough."));
  }
  if ((installed ? installed->version : shell.version.value_or(0)) < bundled.version) {
    return say("update-required", tr("A newer extension is bundled with this app. Install it, then sign out and back in to load the update."));
  }
  if (!shell.userExtensionsEnabled) {
    return say("extensions-disabled", tr("GNOME has disabled user extensions. Turn on Extensions in the GNOME Extensions app, then check again. HAL-C2 will not enable your other extensions for you."));
  }
  if (shell.state == 1) return say("enabled", tr("The HAL-C2 extension is running. Active-window snapshots are available."));
  if (shell.state == 3 || shell.state == 4) {
    return say("error", !shell.error.isEmpty() ? shell.error : tr("GNOME could not load the extension. Check GNOME Extensions for details, or sign out and back in."));
  }
  return say("disabled", tr("Enable the HAL-C2 extension to allow active-window snapshots. You can disable it here at any time."));
}

QString GnomeSnapShot::installBlocked(const Paths& paths) {
  const QString target = extensionsDir(paths) + u'/' + kUuid;
  const QFileInfo existing(target);
  if (!present(existing)) return {};
  if (existing.isSymLink() || !existing.isDir()) {
    return tr("The extension installation is not a regular directory. Manage it in GNOME Extensions instead.");
  }
  const auto installed = metadata(target);
  if (!installed) return tr("The installed extension could not be read. Manage it in GNOME Extensions instead.");
  const auto bundled = metadata(paths.bundle);
  if (bundled && installed->version > bundled->version) return tr("A newer extension is installed. Update HAL-C2 instead of replacing it.");
  return {};
}

QString GnomeSnapShot::install(const Paths& paths) {
  const QString missing = tr("The extension is missing from this build. Update or reinstall HAL-C2.");
  if (!metadata(paths.bundle)) return missing;
  if (const QString blocked = installBlocked(paths); !blocked.isEmpty()) return blocked;

  QFile list(paths.bundle + QStringLiteral("/bundle.json"));
  if (!list.open(QIODevice::ReadOnly)) return missing;
  const QJsonArray files = QJsonDocument::fromJson(list.readAll()).object().value(QLatin1String("files")).toArray();
  if (files.isEmpty()) return missing;

  const QString parent = extensionsDir(paths);
  const QString couldNot = tr("Could not set up the GNOME extension.");
  if (!QDir().mkpath(parent)) return couldNot;
  // Beside the target, so it moves into place in one step.
  QTemporaryDir staged(parent + QStringLiteral("/.hal-c2-capture-install-XXXXXX"));
  if (!staged.isValid()) return couldNot;
  for (const QJsonValue& entry : files) {
    const QString name = entry.toString();
    const QString to = staged.filePath(name);
    if (name.isEmpty() || !QFile::copy(paths.bundle + u'/' + name, to)) return missing;
    QFile::setPermissions(to, QFile::ReadOwner | QFile::WriteOwner | QFile::ReadGroup | QFile::ReadOther);
  }
  QFile::setPermissions(staged.path(), QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner | QFile::ReadGroup | QFile::ExeGroup | QFile::ReadOther | QFile::ExeOther);

  const QString target = parent + u'/' + kUuid;
  QString backup;
  if (present(QFileInfo(target))) {
    const QString backups = paths.dataHome + QStringLiteral("/hal-c2/extension-backups");
    if (!QDir().mkpath(backups)) return couldNot;
    QTemporaryDir box(backups + QStringLiteral("/capture-XXXXXX"));
    if (!box.isValid()) return couldNot;
    box.setAutoRemove(false);
    backup = box.filePath(kUuid);
    if (!moveFolder(paths, target, backup)) {
      QDir().rmdir(box.path());
      return couldNot;
    }
  }
  if (!moveFolder(paths, staged.path(), target)) {
    if (!backup.isEmpty()) {
      QDir().rename(backup, target);
      QDir().rmdir(QFileInfo(backup).path());
    }
    return couldNot;
  }
  return {};
}

QString GnomeSnapShot::busName(const QString& appId) {
  return appId.contains(QLatin1String("dev"), Qt::CaseInsensitive) ? QStringLiteral("io.github.halc2.HalC2.Development.SnapShot")
                                                                    : QStringLiteral("io.github.halc2.HalC2.SnapShot");
}

QImage GnomeSnapShot::decode(const QByteArray& png, QString* error) {
  static const QByteArray header("\x89PNG\r\n\x1a\n", 8);
  QImage image;
  if (png.size() > kMaxPngBytes || !png.startsWith(header) || !image.loadFromData(png, "PNG") || image.isNull()) {
    *error = tr("Invalid or oversized window screenshot.");
    return {};
  }
  if (image.width() > 2560 || image.height() > 1600) image = image.scaled(2560, 1600, Qt::KeepAspectRatio, Qt::SmoothTransformation);
  return image;
}

#ifdef HAL_C2_HAS_DBUS

namespace {

const QString kShell = QStringLiteral("org.gnome.Shell");
const QString kShellPath = QStringLiteral("/org/gnome/Shell");
const QString kExtensions = QStringLiteral("org.gnome.Shell.Extensions");
const QString kProperties = QStringLiteral("org.freedesktop.DBus.Properties");
const QString kService = QStringLiteral("org.gnome.Shell.Extensions.HalC2SnapShot");
const QString kServicePath = QStringLiteral("/org/gnome/Shell/Extensions/HalC2SnapShot");
constexpr int kTimeoutMs = 5'000;
// How long the connection outlives a capture: the extension takes its flash
// away with the connection, and the flash lasts 180ms.
constexpr int kFlashMs = 300;

class DBusGnomeShell : public GnomeShell {
public:
  void inspect(std::function<void(const Extension&)> done) override {
    QDBusMessage all = QDBusMessage::createMethodCall(kShell, kShellPath, kProperties, QStringLiteral("GetAll"));
    all.setArguments({kExtensions});
    call(QDBusConnection::sessionBus(), all, [this, done = std::move(done)](const QDBusMessage& properties) {
      Extension extension;
      if (properties.type() != QDBusMessage::ReplyMessage) {
        extension.failure = failure(properties);
        done(extension);
        return;
      }
      const QVariantMap shell = qdbus_cast<QVariantMap>(properties.arguments().value(0));
      extension.shellVersion = shell.value(QStringLiteral("ShellVersion")).toString();
      extension.userExtensionsEnabled = shell.value(QStringLiteral("UserExtensionsEnabled")).toBool();
      QDBusMessage info = QDBusMessage::createMethodCall(kShell, kShellPath, kExtensions, QStringLiteral("GetExtensionInfo"));
      info.setArguments({GnomeSnapShot::kUuid});
      call(QDBusConnection::sessionBus(), info, [this, extension, done](const QDBusMessage& reply) mutable {
        if (reply.type() != QDBusMessage::ReplyMessage) {
          extension.failure = failure(reply);
          done(extension);
          return;
        }
        const QVariantMap found = qdbus_cast<QVariantMap>(reply.arguments().value(0));
        if (found.contains(QStringLiteral("state"))) extension.state = found.value(QStringLiteral("state")).toInt();
        if (found.contains(QStringLiteral("version"))) extension.version = found.value(QStringLiteral("version")).toDouble();
        extension.error = found.value(QStringLiteral("error")).toString();
        QDBusMessage version = QDBusMessage::createMethodCall(kService, kServicePath, kProperties, QStringLiteral("GetAll"));
        version.setArguments({kService});
        call(QDBusConnection::sessionBus(), version, [extension, done](const QDBusMessage& service) mutable {
          // Not answering is an answer: the extension is not running.
          if (service.type() == QDBusMessage::ReplyMessage) {
            extension.service = qdbus_cast<QVariantMap>(service.arguments().value(0)).value(QStringLiteral("Version")).toInt();
          }
          done(extension);
        });
      });
    });
  }

  void setEnabled(bool on, std::function<void(const QString& error)> done) override {
    QDBusMessage message = QDBusMessage::createMethodCall(kShell, kShellPath, kExtensions, on ? QStringLiteral("EnableExtension") : QStringLiteral("DisableExtension"));
    message.setArguments({GnomeSnapShot::kUuid});
    call(QDBusConnection::sessionBus(), message, [this, done = std::move(done)](const QDBusMessage& reply) {
      if (reply.type() != QDBusMessage::ReplyMessage) {
        done(failure(reply));
      } else if (!reply.arguments().value(0).toBool()) {
        done(tr("GNOME has not loaded the extension. Sign out and back in, then try again."));
      } else {
        done({});
      }
    });
  }

  void capture(const QString& busName, bool flash, std::function<void(const Capture&)> done) override {
    // A connection of its own: the extension trusts the owner of `busName`,
    // and the name goes when the connection does.
    static int count = 0;
    const QString name = QStringLiteral("hal-c2-gnome-capture-%1").arg(++count);
    QDBusConnection bus = QDBusConnection::connectToBus(QDBusConnection::SessionBus, name);
    const auto owner = bus.isConnected() ? bus.interface()->registerService(busName, QDBusConnectionInterface::DontQueueService, QDBusConnectionInterface::DontAllowReplacement)
                                         : QDBusReply<QDBusConnectionInterface::RegisterServiceReply>();
    if (!owner.isValid() || owner.value() != QDBusConnectionInterface::ServiceRegistered) {
      QDBusConnection::disconnectFromBus(name);
      Capture capture;
      capture.error = tr("Another HAL-C2 instance is capturing a window. Try again.");
      done(capture);
      return;
    }
    QDBusMessage message = QDBusMessage::createMethodCall(kService, kServicePath, kService, flash ? QStringLiteral("CaptureWithFeedback") : QStringLiteral("Capture"));
    if (flash) message.setArguments({true, false});
    call(bus, message, [name, flash, done = std::move(done)](const QDBusMessage& reply) {
      Capture capture;
      if (reply.type() == QDBusMessage::ReplyMessage && reply.arguments().size() >= 2) {
        capture.png = reply.arguments().value(0).toByteArray();
        capture.metadata = reply.arguments().value(1).toString();
      } else {
        capture.error = reply.errorMessage().isEmpty() ? tr("Invalid extension screenshot.") : reply.errorMessage();
      }
      QTimer::singleShot(flash ? kFlashMs : 0, [name] { QDBusConnection::disconnectFromBus(name); });
      done(capture);
    });
  }

private:
  static QString failure(const QDBusMessage& reply) {
    static const QStringList absent{QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown"), QStringLiteral("org.freedesktop.DBus.Error.NoReply"),
                                    QStringLiteral("org.freedesktop.DBus.Error.Timeout"), QStringLiteral("org.freedesktop.DBus.Error.TimedOut"),
                                    QStringLiteral("org.freedesktop.DBus.Error.Disconnected")};
    if (absent.contains(reply.errorName()) || reply.errorMessage().isEmpty()) {
      return tr("GNOME did not respond. Sign in to a GNOME Wayland session and try again.");
    }
    return reply.errorMessage();
  }

  void call(QDBusConnection bus, const QDBusMessage& message, std::function<void(const QDBusMessage&)> done) {
    auto* watcher = new QDBusPendingCallWatcher(bus.asyncCall(message, kTimeoutMs), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [done = std::move(done)](QDBusPendingCallWatcher* finished) {
      finished->deleteLater();
      done(finished->reply());
    });
  }
};

}  // namespace

GnomeSnapShot* GnomeSnapShot::create(SnapShotBackend* portal, QObject* parent) {
  Paths paths{QStringLiteral(":/hal-c2/gnome-extension"), QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation), {}};
  return new GnomeSnapShot(portal, new DBusGnomeShell, paths, parent);
}

#else

GnomeSnapShot* GnomeSnapShot::create(SnapShotBackend*, QObject*) {
  return nullptr;
}

#endif
