#include "FakeDesktopPortal.h"

#ifdef HAL_C2_HAS_DBUS

#include <QCoreApplication>
#include <QDBusConnectionInterface>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QDir>
#include <QFile>
#include <QHash>
#include <QProcess>
#include <QUuid>

#include "Harness.h"
#include "PortalSnapShot.h"

namespace {

const QString kService = QStringLiteral("org.freedesktop.portal.Desktop");
const QString kPath = QStringLiteral("/org/freedesktop/portal/desktop");
const QString kShortcuts = QStringLiteral("org.freedesktop.portal.GlobalShortcuts");
const QString kScreenshot = QStringLiteral("org.freedesktop.portal.Screenshot");
const QString kProperties = QStringLiteral("org.freedesktop.DBus.Properties");
const QString kPortalConnection = QStringLiteral("hal-c2-features-portal");
const QString kAppConnection = QStringLiteral("hal-c2-features-app");

// A bus with no service directories: no name is ever started on demand.
const char kConfig[] = R"(<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>%1</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
)";

QProcess*& daemon() {
  static QProcess* process = nullptr;
  return process;
}

// Starts the bus once, and stops the dbus-daemon it started when the app goes.
QString busAddress() {
  static QString address;
  if (!address.isEmpty()) return address;
  const QString config = QDir::temp().filePath(QStringLiteral("hal-c2-features-bus-%1.conf").arg(QCoreApplication::applicationPid()));
  QFile file(config);
  const QString listen = QStringLiteral("unix:abstract=hal-c2-features-%1").arg(QUuid::createUuid().toString(QUuid::Id128));
  if (!file.open(QIODevice::WriteOnly) || file.write(QString::fromLatin1(kConfig).arg(listen).toUtf8()) < 0) {
    fail(QStringLiteral("cannot write the test bus's config to %1").arg(config));
  }
  file.close();
  auto* process = new QProcess;
  process->start(QStringLiteral("dbus-daemon"), {QStringLiteral("--config-file=") + config, QStringLiteral("--nofork"),
                                                  QStringLiteral("--print-address=1")});
  if (!process->waitForStarted(5000)) fail(QStringLiteral("cannot start dbus-daemon: %1").arg(process->errorString()));
  daemon() = process;
  qAddPostRoutine([] {
    QProcess* process = std::exchange(daemon(), nullptr);
    if (!process) return;
    process->kill();
    process->waitForFinished(5000);
    delete process;
  });
  while (!process->canReadLine()) {
    if (!process->waitForReadyRead(5000)) fail(QStringLiteral("dbus-daemon gave no address: %1").arg(QString::fromUtf8(process->readAllStandardError())));
  }
  QFile::remove(config);
  address = QString::fromUtf8(process->readLine()).trimmed();
  return address;
}

// The trigger as a desktop names it: CTRL+SHIFT+2 is Ctrl+Shift+2.
QString describe(const QString& trigger) {
  static const QHash<QString, QString> names{{QStringLiteral("CTRL"), QStringLiteral("Ctrl")},
                                             {QStringLiteral("SHIFT"), QStringLiteral("Shift")},
                                             {QStringLiteral("ALT"), QStringLiteral("Alt")},
                                             {QStringLiteral("LOGO"), QStringLiteral("Super")}};
  QStringList parts;
  for (const QString& part : trigger.split(QLatin1Char('+'))) parts.append(names.value(part, part));
  return parts.join(QLatin1Char('+'));
}

// A caller's part of the portal's request and session paths: :1.5 is 1_5.
QString senderPart(const QDBusMessage& message) {
  return message.service().mid(1).replace(QLatin1Char('.'), QLatin1Char('_'));
}

}  // namespace

FakeDesktopPortal::FakeDesktopPortal() : m_bus(QDBusConnection::connectToBus(busAddress(), kPortalConnection)) {
  if (!m_bus.isConnected()) fail(QStringLiteral("cannot reach the test bus: %1").arg(m_bus.lastError().message()));
  qDBusRegisterMetaType<PortalShortcut>();
  qDBusRegisterMetaType<QList<PortalShortcut>>();
  if (!m_bus.registerVirtualObject(kPath, this, QDBusConnection::SubPath)) fail(QStringLiteral("cannot serve the fake portal"));
  const QDBusConnection app = QDBusConnection::connectToBus(busAddress(), kAppConnection);
  if (!app.isConnected()) fail(QStringLiteral("cannot connect the app to the test bus"));
}

FakeDesktopPortal& FakeDesktopPortal::instance() {
  static FakeDesktopPortal* portal = new FakeDesktopPortal;
  return *portal;
}

QString FakeDesktopPortal::appConnection() {
  instance();
  return kAppConnection;
}

void FakeDesktopPortal::reset() {
  desktop = {};
  creates = closes = configures = 0;
  triggers.clear();
  m_session.clear();
  m_held.reset();
  m_heldScreenshot.reset();
  if (!m_bus.interface()->isServiceRegistered(kService) && !m_bus.registerService(kService)) {
    fail(QStringLiteral("cannot own %1 on the test bus").arg(kService));
  }
  PortalSnapShot::useBus(kAppConnection);
}

int FakeDesktopPortal::promptTimeoutMs() {
  return PortalSnapShot::kPromptTimeoutMs;
}

void FakeDesktopPortal::shortenPrompts() {
  PortalSnapShot::useBus(kAppConnection, PortalSnapShot::kTimeoutMs, 50);
}

QString FakeDesktopPortal::introspect(const QString&) const {
  return {};
}

void FakeDesktopPortal::respond(const QString& request, uint status, const QVariantMap& results) {
  QDBusMessage signal = QDBusMessage::createSignal(request, QStringLiteral("org.freedesktop.portal.Request"), QStringLiteral("Response"));
  signal << status << results;
  m_bus.send(signal);
}

QVariantMap FakeDesktopPortal::granted(const QString& label) const {
  QVariantMap properties{{QStringLiteral("description"), QStringLiteral("Capture a window")}};
  if (!label.isEmpty()) properties.insert(QStringLiteral("trigger_description"), label);
  return {{QStringLiteral("shortcuts"), QVariant::fromValue(QList<PortalShortcut>{{m_shortcutId, properties}})}};
}

bool FakeDesktopPortal::handleMessage(const QDBusMessage& message, const QDBusConnection& connection) {
  const QString member = message.member();
  const QVariantList arguments = message.arguments();
  const auto reply = [&](const QVariantList& values = {}) { connection.send(message.createReply(values)); };

  if (message.interface() == kProperties && member == QLatin1String("GetAll") && arguments.value(0) == kScreenshot) {
    if (desktop.holdScreenshot) {
      message.setDelayedReply(true);
      m_heldScreenshot = message;
      return true;
    }
    if (desktop.screenshotFails) {
      connection.send(message.createErrorReply(QDBusError::Failed, QStringLiteral("The screenshot portal is not answering.")));
      return true;
    }
    reply({QVariantMap{{QStringLiteral("version"), uint(3)}, {QStringLiteral("AvailableTargets"), uint(desktop.windowCapture ? 8 : 1)}}});
    return true;
  }
  if (message.interface() == kProperties && member == QLatin1String("Get") && arguments.value(0) == kShortcuts) {
    reply({QVariant::fromValue(QDBusVariant(desktop.shortcutsVersion))});
    return true;
  }
  if (member == QLatin1String("Register") || (member == QLatin1String("Close") && message.path().contains(QLatin1String("/request/")))) {
    reply();
    return true;
  }
  if (member == QLatin1String("Close")) {
    ++closes;
    if (message.path() == m_session) m_session.clear();
    reply();
    return true;
  }
  if (message.interface() != kShortcuts) {
    connection.send(message.createErrorReply(QDBusError::UnknownMethod, member));
    return true;
  }

  const QVariantMap options = qdbus_cast<QVariantMap>(arguments.value(arguments.size() - 1));
  const QString request = kPath + QStringLiteral("/request/") + senderPart(message) + QLatin1Char('/') +
                          options.value(QStringLiteral("handle_token")).toString();
  if (member == QLatin1String("CreateSession")) {
    ++creates;
    reply({QVariant::fromValue(QDBusObjectPath(request))});
    if (desktop.sessionFails) {
      respond(request, 2, {});
      return true;
    }
    m_session = kPath + QStringLiteral("/session/") + senderPart(message) + QLatin1Char('/') +
                options.value(QStringLiteral("session_handle_token")).toString();
    respond(request, 0, {{QStringLiteral("session_handle"), m_session}});
    return true;
  }
  if (member == QLatin1String("BindShortcuts")) {
    const auto shortcuts = qdbus_cast<QList<PortalShortcut>>(arguments.value(1));
    m_shortcutId = shortcuts.value(0).id;
    m_trigger = shortcuts.value(0).properties.value(QStringLiteral("preferred_trigger")).toString();
    triggers.append(m_trigger);
    reply({QVariant::fromValue(QDBusObjectPath(request))});
    switch (desktop.bind) {
      case Answer::Grant:
        respond(request, 0, granted(desktop.label.isEmpty() ? describe(m_trigger) : desktop.label));
        break;
      case Answer::Unassigned:
        respond(request, 0, granted({}));
        break;
      case Answer::Nothing:
        respond(request, 0, {{QStringLiteral("shortcuts"), QVariant::fromValue(QList<PortalShortcut>{})}});
        break;
      case Answer::Refuse:
        respond(request, 1, {});
        break;
      case Answer::Hold:
        m_held = Held{request};
        break;
    }
    return true;
  }
  if (member == QLatin1String("ConfigureShortcuts")) {
    ++configures;
    reply();
    return true;
  }
  connection.send(message.createErrorReply(QDBusError::UnknownMethod, member));
  return true;
}

void FakeDesktopPortal::answer(bool approve) {
  if (!m_held) fail(QStringLiteral("no shortcut prompt is open"));
  const Held held = *std::exchange(m_held, std::nullopt);
  if (approve) respond(held.request, 0, granted(desktop.label.isEmpty() ? describe(m_trigger) : desktop.label));
  else respond(held.request, 1, {});
}

void FakeDesktopPortal::answerScreenshot() {
  if (!m_heldScreenshot) fail(QStringLiteral("no screenshot check is waiting"));
  const QDBusMessage message = *std::exchange(m_heldScreenshot, std::nullopt);
  desktop.holdScreenshot = false;
  m_bus.send(message.createReply(QVariantList{
      QVariantMap{{QStringLiteral("version"), uint(3)}, {QStringLiteral("AvailableTargets"), uint(desktop.windowCapture ? 8 : 1)}}}));
}

void FakeDesktopPortal::dropService() {
  m_session.clear();
  m_held.reset();
  m_bus.unregisterService(kService);
}

void FakeDesktopPortal::restartService() {
  dropService();
  if (!m_bus.registerService(kService)) fail(QStringLiteral("cannot own %1 again").arg(kService));
}

void FakeDesktopPortal::closeSession() {
  if (m_session.isEmpty()) fail(QStringLiteral("no shortcut session is open"));
  QDBusMessage signal = QDBusMessage::createSignal(std::exchange(m_session, QString()), QStringLiteral("org.freedesktop.portal.Session"),
                                                   QStringLiteral("Closed"));
  signal << QVariantMap{};
  m_bus.send(signal);
}

void FakeDesktopPortal::changeShortcut(const QString& label) {
  if (m_session.isEmpty()) fail(QStringLiteral("no shortcut session is open"));
  desktop.label = label;
  QDBusMessage signal = QDBusMessage::createSignal(kPath, kShortcuts, QStringLiteral("ShortcutsChanged"));
  signal << QVariant::fromValue(QDBusObjectPath(m_session)) << granted(label).value(QStringLiteral("shortcuts"));
  m_bus.send(signal);
}

#endif
