#include "PortalSnapShot.h"

#ifdef HAL_C2_HAS_DBUS

#include <QCryptographicHash>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#include <QFile>
#include <QGuiApplication>
#include <QProcessEnvironment>
#include <QUrl>
#include <QUuid>

namespace {

const QString kService = QStringLiteral("org.freedesktop.portal.Desktop");
const QString kPath = QStringLiteral("/org/freedesktop/portal/desktop");
const QString kRequest = QStringLiteral("org.freedesktop.portal.Request");
const QString kSession = QStringLiteral("org.freedesktop.portal.Session");
const QString kScreenshot = QStringLiteral("org.freedesktop.portal.Screenshot");
const QString kShortcuts = QStringLiteral("org.freedesktop.portal.GlobalShortcuts");
const QString kProperties = QStringLiteral("org.freedesktop.DBus.Properties");
// The Screenshot portal's `target` for the window in front.
constexpr uint kWindowTarget = 8;
constexpr int kPromptTimeoutMs = 120'000;
constexpr int kTimeoutMs = 5'000;
constexpr qint64 kMaxPngBytes = 32 * 1024 * 1024;

struct PortalShortcut {
  QString id;
  QVariantMap properties;
};

QDBusArgument& operator<<(QDBusArgument& argument, const PortalShortcut& shortcut) {
  argument.beginStructure();
  argument << shortcut.id << shortcut.properties;
  argument.endStructure();
  return argument;
}

const QDBusArgument& operator>>(const QDBusArgument& argument, PortalShortcut& shortcut) {
  argument.beginStructure();
  argument >> shortcut.id >> shortcut.properties;
  argument.endStructure();
  return argument;
}

QDBusConnection bus() {
  return QDBusConnection::sessionBus();
}

QString token() {
  return QStringLiteral("hal_c2_") + QUuid::createUuid().toString(QUuid::Id128);
}

// A handle the portal gives as an object path or a string.
QString handleOf(const QVariant& value) {
  if (value.canConvert<QDBusObjectPath>()) return value.value<QDBusObjectPath>().path();
  return value.toString();
}

QVariant unwrap(const QVariant& value) {
  return value.canConvert<QDBusVariant>() ? value.value<QDBusVariant>().variant() : value;
}

// Answers `done` with the reply to `message`, or its error.
void call(const QDBusMessage& message, QObject* context, std::function<void(const QDBusMessage&)> done) {
  auto* watcher = new QDBusPendingCallWatcher(bus().asyncCall(message), context);
  QObject::connect(watcher, &QDBusPendingCallWatcher::finished, context, [watcher, done = std::move(done)] {
    watcher->deleteLater();
    done(watcher->reply());
  });
}

void closeObject(const QString& path, const QString& interface) {
  bus().send(QDBusMessage::createMethodCall(kService, path, interface, QStringLiteral("Close")));
}

bool sandboxed() {
  const QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
  return env.contains(QStringLiteral("FLATPAK_ID")) || env.contains(QStringLiteral("SNAP"));
}

}  // namespace

Q_DECLARE_METATYPE(PortalShortcut)

// --- PortalRequest ---------------------------------------------------------------

PortalRequest::PortalRequest(const QString& handle, int timeoutMs, Done done, QObject* parent)
    : QObject(parent), m_handle(handle), m_done(std::move(done)) {
  // Before the call: the Response may come before its method reply.
  listen(true);
  m_timeout.setSingleShot(true);
  m_timeout.setInterval(timeoutMs);
  connect(&m_timeout, &QTimer::timeout, this, [this] {
    closeObject(m_handle, kRequest);
    finish(2, {{QStringLiteral("timeout"), true}});
  });
  m_timeout.start();
}

void PortalRequest::listen(bool on) {
  if (on) {
    bus().connect(kService, m_handle, kRequest, QStringLiteral("Response"), this, SLOT(response(uint, QVariantMap)));
  } else {
    bus().disconnect(kService, m_handle, kRequest, QStringLiteral("Response"), this, SLOT(response(uint, QVariantMap)));
  }
}

void PortalRequest::moveTo(const QString& handle) {
  if (handle == m_handle || !m_done) return;
  listen(false);
  m_handle = handle;
  listen(true);
}

void PortalRequest::finish(uint status, const QVariantMap& results) {
  if (!m_done) return;
  listen(false);
  m_timeout.stop();
  const Done done = std::exchange(m_done, {});
  done(status, results);
  deleteLater();
}

// --- PortalSnapShot --------------------------------------------------------------

PortalSnapShot::PortalSnapShot(const Platform& platform, QObject* parent) : SnapShotBackend(parent) {
  m_session.mode = QStringLiteral("portal");
  m_session.desktop = platform.desktop;
  qDBusRegisterMetaType<PortalShortcut>();
  qDBusRegisterMetaType<QList<PortalShortcut>>();
}

PortalSnapShot::~PortalSnapShot() {
  closeSession();
}

QString PortalSnapShot::requestPrefix() const {
  QString sender = bus().baseService();
  sender.remove(0, 1).replace(QLatin1Char('.'), QLatin1Char('_'));
  return kPath + QStringLiteral("/request/") + sender + QLatin1Char('/');
}

// Unsandboxed apps name themselves to the portal (host registry) before
// anything else, so its permissions are the app's; older portals lack it.
void PortalSnapShot::registerApp() {
  if (m_registered) return;
  m_registered = true;
  if (sandboxed()) return;
  QString appId = QGuiApplication::desktopFileName();
  if (appId.isEmpty()) appId = QStringLiteral("hal-c2");
  QDBusMessage message =
      QDBusMessage::createMethodCall(kService, kPath, QStringLiteral("org.freedesktop.host.portal.Registry"), QStringLiteral("Register"));
  message.setArguments({appId, QVariantMap{}});
  bus().send(message);
}

void PortalSnapShot::probe() {
  if (m_session.ready || m_probing) return;
  m_probing = true;
  registerApp();
  QDBusMessage message = QDBusMessage::createMethodCall(kService, kPath, kProperties, QStringLiteral("GetAll"));
  message.setArguments({kScreenshot});
  call(message, this, [this](const QDBusMessage& reply) {
    m_probing = false;
    const QVariantMap properties = reply.type() == QDBusMessage::ReplyMessage
                                       ? qdbus_cast<QVariantMap>(reply.arguments().value(0))
                                       : QVariantMap{};
    const uint version = unwrap(properties.value(QStringLiteral("version"))).toUInt();
    const uint targets = unwrap(properties.value(QStringLiteral("AvailableTargets"))).toUInt();
    m_session.backend = version >= 3 && (targets & kWindowTarget) ? QStringLiteral("screenshot-portal") : QStringLiteral("picker");
    m_session.ready = true;
    emit changed();
  });
}

void PortalSnapShot::request(const QString& interface, const QString& method, QVariantList arguments, QVariantMap options,
                             int timeoutMs, PortalRequest::Done done) {
  const QString handleToken = token();
  options.insert(QStringLiteral("handle_token"), handleToken);
  QPointer<PortalRequest> pending = new PortalRequest(requestPrefix() + handleToken, timeoutMs, std::move(done), this);
  QDBusMessage message = QDBusMessage::createMethodCall(kService, kPath, interface, method);
  arguments.append(options);
  message.setArguments(arguments);
  call(message, this, [pending](const QDBusMessage& reply) {
    if (!pending) return;
    if (reply.type() != QDBusMessage::ReplyMessage) {
      pending->finish(2, {{QStringLiteral("error"), reply.errorMessage()}});
      return;
    }
    pending->moveTo(handleOf(reply.arguments().value(0)));
  });
}

void PortalSnapShot::capture() {
  if (m_capturing) return;
  m_capturing = true;
  registerApp();
  QVariantMap options{{QStringLiteral("modal"), false}};
  if (m_session.backend == QLatin1String("screenshot-portal")) {
    options.insert(QStringLiteral("interactive"), false);
    options.insert(QStringLiteral("target"), QVariant::fromValue(kWindowTarget));
  } else {
    // The picker: the user chooses the window.
    options.insert(QStringLiteral("interactive"), true);
  }
  request(kScreenshot, QStringLiteral("Screenshot"), {QString()}, options, kPromptTimeoutMs, [this](uint status, const QVariantMap& results) {
    m_capturing = false;
    if (status == 1) {
      emit failed(QStringLiteral("Snapshot was cancelled."));
      return;
    }
    if (status != 0) {
      emit failed(QStringLiteral("Your desktop did not allow the snapshot."));
      return;
    }
    // A file the portal owns: read, never removed.
    const QUrl uri(unwrap(results.value(QStringLiteral("uri"))).toString());
    QFile file(uri.isLocalFile() ? uri.toLocalFile() : QString());
    if (!file.open(QIODevice::ReadOnly) || file.size() > kMaxPngBytes) {
      emit failed(QStringLiteral("Invalid screenshot file."));
      return;
    }
    const QByteArray png = file.readAll();
    static const QByteArray header("\x89PNG\r\n\x1a\n", 8);
    QImage image;
    if (!png.startsWith(header) || !image.loadFromData(png, "PNG") || image.isNull()) {
      emit failed(QStringLiteral("Invalid or oversized window screenshot."));
      return;
    }
    if (image.width() > 2560 || image.height() > 1600) {
      image = image.scaled(2560, 1600, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    // The portal names neither the app nor the window.
    emit captured(image, QStringLiteral("Window"), QString());
  });
}

// --- The capture shortcut ---------------------------------------------------------

void PortalSnapShot::setShortcut(const Shortcut& shortcut) {
  m_shortcut = shortcut;
  emit changed();
}

void PortalSnapShot::closeSession() {
  ++m_generation;
  if (m_sessionHandle.isEmpty()) return;
  bus().disconnect(kService, m_sessionHandle, kSession, QStringLiteral("Closed"), this, SLOT(onSessionClosed(QDBusMessage)));
  closeObject(m_sessionHandle, kSession);
  m_sessionHandle.clear();
}

void PortalSnapShot::shortcutFailed(const QString& message) {
  closeSession();
  setShortcut({false, false, {}, message, true});
}

void PortalSnapShot::bind(const QString& trigger) {
  if (trigger == m_trigger && !m_sessionHandle.isEmpty()) return;
  closeSession();
  m_trigger = trigger;
  m_shortcutId = QStringLiteral("hal-c2-snap-shot-") +
                 QString::fromLatin1(QCryptographicHash::hash(trigger.toUtf8(), QCryptographicHash::Sha256).toHex().left(16));
  setShortcut({false, true, {}, QStringLiteral("Waiting for shortcut permission. Approve the desktop prompt if one appears."),
               m_shortcutsVersion == 0 || m_shortcutsVersion >= 2});
  registerApp();
  if (m_watcher.watchedServices().isEmpty()) {
    // The shortcut's signals, and the portal going away under it.
    bus().connect(kService, kPath, kShortcuts, QStringLiteral("Activated"), this, SLOT(onShortcutSignal(QDBusMessage)));
    bus().connect(kService, kPath, kShortcuts, QStringLiteral("ShortcutsChanged"), this, SLOT(onShortcutSignal(QDBusMessage)));
    m_watcher.setConnection(bus());
    m_watcher.setWatchMode(QDBusServiceWatcher::WatchForOwnerChange);
    m_watcher.addWatchedService(kService);
    connect(&m_watcher, &QDBusServiceWatcher::serviceOwnerChanged, this, &PortalSnapShot::onOwnerChanged);
  }
  const quint64 generation = m_generation;
  QDBusMessage version = QDBusMessage::createMethodCall(kService, kPath, kProperties, QStringLiteral("Get"));
  version.setArguments({kShortcuts, QStringLiteral("version")});
  call(version, this, [this, generation](const QDBusMessage& reply) {
    if (generation != m_generation) return;
    if (reply.type() != QDBusMessage::ReplyMessage) {
      shortcutFailed(QStringLiteral("This desktop doesn't offer app shortcuts. Choose a shortcut in your desktop's settings instead."));
      return;
    }
    m_shortcutsVersion = unwrap(reply.arguments().value(0)).toUInt();
    const QVariantMap create{{QStringLiteral("session_handle_token"), token()}};
    request(kShortcuts, QStringLiteral("CreateSession"), {}, create, kTimeoutMs, [this, generation](uint status, const QVariantMap& results) {
      const QString handle = handleOf(unwrap(results.value(QStringLiteral("session_handle"))));
      if (generation != m_generation) {
        if (status == 0 && !handle.isEmpty()) closeObject(handle, kSession);
        return;
      }
      if (status != 0 || handle.isEmpty()) {
        shortcutFailed(results.contains(QStringLiteral("timeout")) ? QStringLiteral("Shortcut permission request timed out. Try again.")
                                                                  : QStringLiteral("Your desktop could not create a capture shortcut session."));
        return;
      }
      m_sessionHandle = handle;
      bus().connect(kService, handle, kSession, QStringLiteral("Closed"), this, SLOT(onSessionClosed(QDBusMessage)));
      m_shortcut.canRetry = m_shortcutsVersion >= 2;
      const QList<PortalShortcut> shortcuts{
          {m_shortcutId,
           {{QStringLiteral("description"), QStringLiteral("Capture a window")}, {QStringLiteral("preferred_trigger"), m_trigger}}}};
      // Every session binds, even when the desktop remembers the approval.
      request(kShortcuts, QStringLiteral("BindShortcuts"),
              {QVariant::fromValue(QDBusObjectPath(handle)), QVariant::fromValue(shortcuts), QString()}, {}, kPromptTimeoutMs,
              [this, generation](uint status, const QVariantMap& results) {
                if (generation != m_generation) return;
                if (status != 0) {
                  setShortcut({false, false, {},
                               m_shortcutsVersion >= 2
                                   ? QStringLiteral("Shortcut permission wasn't granted. Open shortcut permissions to allow it.")
                                   : QStringLiteral("Shortcut permission wasn't granted. Allow HAL-C2 in your desktop's shortcut settings."),
                               m_shortcutsVersion >= 2});
                  return;
                }
                bound(results.value(QStringLiteral("shortcuts")));
              });
    });
  });
}

void PortalSnapShot::bound(const QVariant& shortcuts) {
  QString label;
  bool found = false;
  for (const PortalShortcut& shortcut : qdbus_cast<QList<PortalShortcut>>(unwrap(shortcuts))) {
    if (shortcut.id != m_shortcutId) continue;
    found = true;
    label = unwrap(shortcut.properties.value(QStringLiteral("trigger_description"))).toString().trimmed();
  }
  setShortcut({found && !label.isEmpty(), false, label,
               !label.isEmpty()            ? QStringLiteral("Desktop shortcut: %1").arg(label)
               : m_shortcutsVersion >= 2 ? QStringLiteral("No shortcut is assigned. Open shortcut permissions to choose one.")
                                         : QStringLiteral("No shortcut is assigned. Choose one in your desktop's shortcut settings."),
               m_shortcutsVersion >= 2});
}

void PortalSnapShot::release() {
  closeSession();
  m_trigger.clear();
  setShortcut({});
}

void PortalSnapShot::configure() {
  if (m_sessionHandle.isEmpty()) {
    // The session failed or was closed: a fresh one asks again.
    const QString trigger = std::exchange(m_trigger, {});
    if (!trigger.isEmpty()) bind(trigger);
    return;
  }
  if (m_shortcutsVersion < 2) {
    Shortcut shortcut = m_shortcut;
    shortcut.message = QStringLiteral("Open your desktop's shortcut settings and allow HAL-C2's capture shortcut.");
    setShortcut(shortcut);
    return;
  }
  QDBusMessage message = QDBusMessage::createMethodCall(kService, kPath, kShortcuts, QStringLiteral("ConfigureShortcuts"));
  message.setArguments({QVariant::fromValue(QDBusObjectPath(m_sessionHandle)), QString(), QVariantMap{}});
  bus().send(message);
}

void PortalSnapShot::onShortcutSignal(const QDBusMessage& message) {
  const QVariantList arguments = message.arguments();
  if (m_sessionHandle.isEmpty() || handleOf(arguments.value(0)) != m_sessionHandle) return;
  if (message.member() == QLatin1String("Activated")) {
    if (arguments.value(1).toString() == m_shortcutId && m_shortcut.registered) emit activated();
  } else if (message.member() == QLatin1String("ShortcutsChanged")) {
    bound(arguments.value(1));
  }
}

void PortalSnapShot::onSessionClosed(const QDBusMessage&) {
  shortcutFailed(QStringLiteral("Your desktop closed the capture shortcut. Retry the shortcut request."));
}

void PortalSnapShot::onOwnerChanged(const QString&, const QString& oldOwner, const QString&) {
  if (oldOwner.isEmpty() || (m_sessionHandle.isEmpty() && !m_shortcut.pending)) return;
  shortcutFailed(QStringLiteral("The desktop shortcut service restarted. Retry the shortcut request."));
}

#endif
