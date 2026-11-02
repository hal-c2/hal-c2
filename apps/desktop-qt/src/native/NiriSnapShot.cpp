#include "NiriSnapShot.h"

#ifdef HAL_C2_HAS_DBUS

#include <QDBusConnectionInterface>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>

#include <algorithm>
#include <memory>
#include <utility>

#include "CaptureShortcutConfig.h"
#include "PortalSnapShot.h"

namespace {

const QString kTooOld = QStringLiteral("SnapShots require Niri 25.11 or newer.");
const QString kNoWindow = QStringLiteral("Niri has no focused window to capture.");
const QString kTimedOut = QStringLiteral("Niri did not answer in time.");
const QString kUnreachable = QStringLiteral("Could not reach Niri.");

QString appId() {
  const QString name = QGuiApplication::desktopFileName();
  return name.isEmpty() ? QStringLiteral("hal-c2") : name;
}

// One JSON message per line, each at most kMaxMessage; nullopt-like empty
// `line` until a whole one has arrived.
QByteArray takeLine(QLocalSocket* socket, QByteArray& buffer, bool* tooLong) {
  buffer += socket->readAll();
  const qsizetype end = buffer.indexOf('\n');
  if (end < 0) {
    *tooLong = buffer.size() > NiriSnapShot::kMaxMessage;
    return {};
  }
  const QByteArray line = buffer.left(end);
  buffer.remove(0, end + 1);
  return line;
}

// A window's identity, to tell it is still the one captured.
bool sameWindow(const QJsonObject& a, const QJsonObject& b) {
  return a.value(QLatin1String("id")) == b.value(QLatin1String("id")) && a.value(QLatin1String("pid")) == b.value(QLatin1String("pid")) &&
         a.value(QLatin1String("app_id")) == b.value(QLatin1String("app_id")) && a.value(QLatin1String("title")) == b.value(QLatin1String("title"));
}

}  // namespace

// What a Niri binding calls: Capture, with no arguments.
class NiriSnapShot::Endpoint : public QDBusVirtualObject {
public:
  explicit Endpoint(NiriSnapShot* owner) : m_owner(owner) {}

  QString introspect(const QString& path) const override {
    if (path != CaptureShortcutConfig::kNiriPath) return {};
    return QStringLiteral("<interface name=\"%1\"><method name=\"Capture\"/></interface>").arg(CaptureShortcutConfig::kNiriInterface);
  }

  bool handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override {
    if (message.path() != CaptureShortcutConfig::kNiriPath || message.interface() != CaptureShortcutConfig::kNiriInterface ||
        message.member() != QLatin1String("Capture")) {
      return false;
    }
    if (!message.arguments().isEmpty()) {
      connection.send(message.createErrorReply(QDBusError::InvalidArgs, QStringLiteral("Capture takes no arguments.")));
      return true;
    }
    connection.send(message.createReply());
    emit m_owner->activated();
    return true;
  }

private:
  NiriSnapShot* m_owner;
};

// The capture in flight: its event stream, and where Niri writes the picture.
struct NiriSnapShot::Capture {
  std::unique_ptr<QLocalSocket> events;
  QByteArray buffer;
  QTemporaryDir directory;
  QString path;
  QJsonObject window;
  bool asked = false;
  QTimer timeout;
};

NiriSnapShot::NiriSnapShot(const Platform& platform, const QString& socket, QObject* parent)
    : SnapShotBackend(parent), m_socket(socket), m_name(appId() + QStringLiteral(".SnapShot")) {
  m_session.mode = QStringLiteral("portal");
  m_session.backend = QStringLiteral("niri");
  m_session.desktop = platform.desktop;
  m_shortcut.canRetry = false;
}

NiriSnapShot::~NiriSnapShot() {
  if (!m_endpoint) return;
  QDBusConnection bus = PortalSnapShot::connection();
  bus.unregisterObject(CaptureShortcutConfig::kNiriPath);
  bus.interface()->unregisterService(m_name);
}

QString NiriSnapShot::socketPath(const QProcessEnvironment& env) {
  if (env.contains(QStringLiteral("FLATPAK_ID")) || env.contains(QStringLiteral("SNAP"))) return {};
  const QString socket = env.value(QStringLiteral("NIRI_SOCKET"));
  return QDir::isAbsolutePath(socket) ? socket : QString();
}

void NiriSnapShot::probe() {
  if (m_session.ready || m_probing) return;
  m_probing = true;
  startEndpoint();
  ask(QStringLiteral("Version"), [this](const QJsonValue& ok, const QString& error) {
    m_probing = false;
    m_session.ready = true;
    if (!error.isEmpty()) {
      m_session.message = error;
    } else {
      static const QRegularExpression version(QStringLiteral("^(?:niri )?(\\d+)\\.(\\d+)"));
      const auto match = version.match(ok.toObject().value(QLatin1String("Version")).toString());
      const int major = match.captured(1).toInt();
      const int minor = match.captured(2).toInt();
      if (!match.hasMatch() || major < 25 || (major == 25 && minor < 11)) m_session.message = kTooOld;
    }
    emit changed();
  });
}

void NiriSnapShot::startEndpoint() {
  QDBusConnection bus = PortalSnapShot::connection();
  auto endpoint = std::make_unique<Endpoint>(this);
  const bool owned = bus.isConnected() &&
                     bus.interface()->registerService(m_name, QDBusConnectionInterface::DontQueueService,
                                                      QDBusConnectionInterface::DontAllowReplacement)
                             .value() == QDBusConnectionInterface::ServiceRegistered;
  if (!owned || !bus.registerVirtualObject(CaptureShortcutConfig::kNiriPath, endpoint.get())) {
    m_shortcut.message = QStringLiteral("Could not start the Niri capture endpoint. Another HAL-C2 instance may be using it.");
    return;
  }
  m_endpoint = std::move(endpoint);
  bus.connect(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"), QStringLiteral("org.freedesktop.DBus"),
              QStringLiteral("NameLost"), this, SLOT(onNameLost(QString)));
  bus.connect(QString(), QStringLiteral("/org/freedesktop/DBus/Local"), QStringLiteral("org.freedesktop.DBus.Local"),
              QStringLiteral("Disconnected"), this, SLOT(onBusDisconnected()));
  m_shortcut.registered = true;
  m_shortcut.message = QStringLiteral("Set up the shortcut to add it to your Niri config.");
}

void NiriSnapShot::onNameLost(const QString& name) {
  if (name == m_name) endpointFailed();
}

void NiriSnapShot::onBusDisconnected() {
  endpointFailed();
}

void NiriSnapShot::endpointFailed() {
  if (!m_shortcut.registered) return;
  m_shortcut.registered = false;
  m_shortcut.message = QStringLiteral("The Niri capture endpoint disconnected. Restart HAL-C2.");
  emit changed();
}

void NiriSnapShot::ask(const QJsonValue& request, std::function<void(const QJsonValue&, const QString&)> done) {
  auto* socket = new QLocalSocket(this);
  auto* timer = new QTimer(socket);
  auto buffer = std::make_shared<QByteArray>();
  auto once = std::make_shared<std::function<void(const QJsonValue&, const QString&)>>(std::move(done));
  const auto finish = [socket, once](const QJsonValue& ok, const QString& error) {
    if (!*once) return;
    const auto callback = std::exchange(*once, nullptr);
    socket->disconnect();
    socket->abort();
    socket->deleteLater();
    callback(ok, error);
  };
  timer->setSingleShot(true);
  connect(timer, &QTimer::timeout, socket, [finish] { finish({}, kTimedOut); });
  connect(socket, &QLocalSocket::errorOccurred, socket, [finish] { finish({}, kUnreachable); });
  connect(socket, &QLocalSocket::readyRead, socket, [socket, buffer, finish] {
    bool tooLong = false;
    const QByteArray line = takeLine(socket, *buffer, &tooLong);
    if (tooLong) return finish({}, QStringLiteral("Niri sent an unexpected reply."));
    if (line.isEmpty()) return;
    const QJsonObject reply = QJsonDocument::fromJson(line).object();
    if (reply.contains(QLatin1String("Err"))) {
      return finish({}, QStringLiteral("Niri: %1").arg(reply.value(QLatin1String("Err")).toString()));
    }
    if (!reply.contains(QLatin1String("Ok"))) return finish({}, QStringLiteral("Niri sent an unexpected reply."));
    finish(reply.value(QLatin1String("Ok")), {});
  });
  connect(socket, &QLocalSocket::connected, socket, [socket, request] {
    const QByteArray message = request.isString() ? '"' + request.toString().toUtf8() + '"' : QJsonDocument(request.toObject()).toJson(QJsonDocument::Compact);
    socket->write(message + '\n');
  });
  timer->start(kTimeoutMs);
  socket->connectToServer(m_socket);
}

void NiriSnapShot::capture() {
  if (!m_session.message.isEmpty()) {
    emit failed(m_session.message);
    return;
  }
  // A second press while one is taken is the same capture.
  if (m_capture) return;
  m_capture = std::make_unique<Capture>();
  if (!m_capture->directory.isValid()) {
    finish(QStringLiteral("Could not prepare the capture."));
    return;
  }
  m_capture->path = m_capture->directory.filePath(QStringLiteral("capture.png"));
  m_capture->timeout.setSingleShot(true);
  connect(&m_capture->timeout, &QTimer::timeout, this, [this] { finish(kTimedOut); });
  m_capture->timeout.start(kTimeoutMs);
  // The stream first: the screenshot's event must not be missed.
  m_capture->events = std::make_unique<QLocalSocket>();
  QLocalSocket* events = m_capture->events.get();
  connect(events, &QLocalSocket::errorOccurred, this, [this] { finish(kUnreachable); });
  connect(events, &QLocalSocket::connected, this, [events] { events->write("\"EventStream\"\n"); });
  connect(events, &QLocalSocket::readyRead, this, [this, events] {
    while (m_capture && m_capture->events.get() == events) {
      bool tooLong = false;
      const QByteArray line = takeLine(events, m_capture->buffer, &tooLong);
      if (tooLong) return finish(QStringLiteral("Niri sent an unexpected reply."));
      if (line.isEmpty()) return;
      onEvent(QJsonDocument::fromJson(line).object());
    }
  });
  events->connectToServer(m_socket);
}

void NiriSnapShot::onEvent(const QJsonObject& event) {
  if (event.contains(QLatin1String("Err"))) {
    finish(QStringLiteral("Niri: %1").arg(event.value(QLatin1String("Err")).toString()));
    return;
  }
  if (event.contains(QLatin1String("WindowsChanged")) && !m_capture->asked) {
    m_capture->asked = true;
    focused();
    return;
  }
  const QJsonObject shot = event.value(QLatin1String("ScreenshotCaptured")).toObject();
  if (m_capture->path.isEmpty() || shot.value(QLatin1String("path")).toString() != m_capture->path) return;
  QImage image(m_capture->path);
  if (image.isNull()) {
    finish(QStringLiteral("Niri returned an unreadable screenshot."));
    return;
  }
  // The title is only the window's while the window is still the one captured.
  ask(QStringLiteral("Windows"), [this, image](const QJsonValue& ok, const QString&) {
    if (!m_capture) return;
    const QJsonArray windows = ok.toObject().value(QLatin1String("Windows")).toArray();
    const bool same = std::any_of(windows.begin(), windows.end(), [&](const QJsonValue& window) { return sameWindow(window.toObject(), m_capture->window); });
    const QString app = same ? m_capture->window.value(QLatin1String("app_id")).toString() : QString();
    const QString title = same ? m_capture->window.value(QLatin1String("title")).toString() : QString();
    retire();
    emit captured(image, app.isEmpty() ? QStringLiteral("Window") : app, title);
  });
}

void NiriSnapShot::focused() {
  ask(QStringLiteral("FocusedWindow"), [this](const QJsonValue& ok, const QString& error) {
    if (!m_capture) return;
    if (!error.isEmpty()) return finish(error);
    const QJsonObject window = ok.toObject().value(QLatin1String("FocusedWindow")).toObject();
    if (window.isEmpty()) return finish(kNoWindow);
    screenshot(window);
  });
}

void NiriSnapShot::screenshot(const QJsonObject& window) {
  m_capture->window = window;
  const QJsonObject action{{QStringLiteral("ScreenshotWindow"),
                            QJsonObject{{QStringLiteral("id"), window.value(QLatin1String("id"))},
                                        {QStringLiteral("write_to_disk"), true},
                                        {QStringLiteral("show_pointer"), false},
                                        {QStringLiteral("path"), m_capture->path}}}};
  ask(QJsonObject{{QStringLiteral("Action"), action}}, [this](const QJsonValue&, const QString& error) {
    if (m_capture && !error.isEmpty()) finish(error);
  });
}

void NiriSnapShot::finish(const QString& failure) {
  retire();
  emit failed(failure);
}

// Ends the capture; its socket or timer may be the one emitting right now, so
// they go once the event loop is back.
void NiriSnapShot::retire() {
  std::shared_ptr<Capture> capture = std::move(m_capture);
  capture->timeout.disconnect(this);
  capture->timeout.stop();
  if (capture->events) capture->events->disconnect(this);
  QMetaObject::invokeMethod(this, [capture] {}, Qt::QueuedConnection);
}

#endif  // HAL_C2_HAS_DBUS
