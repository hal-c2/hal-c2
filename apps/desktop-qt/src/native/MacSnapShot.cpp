#include "MacSnapShot.h"

#include <QHash>
#include <QJsonDocument>

namespace {

const QString kScreenRecordingMessage = QStringLiteral("Allow Screen Recording in System Settings, then restart HAL-C2.");
const QString kAccessibilityMessage = QStringLiteral("Allow Accessibility in System Settings, then restart HAL-C2.");
const QString kBothMessage = QStringLiteral("Allow Accessibility and Screen Recording in System Settings, then restart HAL-C2.");

// The largest capture kept (upstream's MAX_CAPTURE_WIDTH and _HEIGHT).
constexpr int kMaxWidth = 2560;
constexpr int kMaxHeight = 1600;

bool isPair(const QJsonObject& shortcut) {
  return shortcut.contains(QLatin1String("kind"));
}

QString pairModifier(const QJsonObject& shortcut) {
  return shortcut.value(QLatin1String("kind")).toString() == QLatin1String("both-shift-keys")
             ? QStringLiteral("shift")
             : shortcut.value(QLatin1String("modifier")).toString();
}

// snapShotModifierPairLabel on Apple: "Option + Option".
QString pairLabel(const QJsonObject& shortcut) {
  static const QHash<QString, QString> names{{QStringLiteral("shift"), QStringLiteral("Shift")},
                                             {QStringLiteral("control"), QStringLiteral("Control")},
                                             {QStringLiteral("alt"), QStringLiteral("Option")},
                                             {QStringLiteral("meta"), QStringLiteral("Command")}};
  const QString name = names.value(pairModifier(shortcut), QStringLiteral("Shift"));
  return QStringLiteral("%1 + %1").arg(name);
}

// A pair is only watched, so other apps still see the keys. Off macOS the
// meta and Alt keys have more to say; on it, nothing.
QString observedMessage(const QJsonObject& shortcut) {
  return QStringLiteral("%1 is observed and cannot be reserved exclusively.").arg(pairLabel(shortcut));
}

// snapShotShortcutRegistrationFailureMessage.
QString refusedMessage(const QJsonObject& shortcut) {
  return isPair(shortcut) ? QStringLiteral("%1 is not available on this system.").arg(pairLabel(shortcut))
                          : QStringLiteral("This shortcut is already used by the system or another app.");
}

}  // namespace

MacSnapShot::MacSnapShot(MacPlatform* platform, QObject* parent)
    : SnapShotBackend(parent), m_platform(platform), m_helper(platform, this) {
  platform->setParent(this);
  m_poll.setInterval(1500);
  connect(&m_poll, &QTimer::timeout, this, &MacSnapShot::refresh);
  connect(platform, &MacPlatform::pressed, this, &MacSnapShot::activated);
  // The system stopped letting the app watch the keys.
  connect(platform, &MacPlatform::watchLost, this, [this] {
    if (!m_asked) return;
    m_holding = false;
    m_shortcut = {};
    m_shortcut.message = refusedMessage(*m_asked);
    emit failed(m_shortcut.message);
    emit changed();
  });
}

MacSnapShot::~MacSnapShot() {
  m_helper.close();
  if (m_holding && m_platform) m_platform->letGo();
}

SnapShotBackend::Session MacSnapShot::session() const {
  Session session;
  session.ready = m_probed;
  session.mode = QStringLiteral("direct");
  session.message = m_message;
  if (m_probed) session.permissions = m_permissions.value_or(Permissions{});
  session.permissionsError = m_permissionsError;
  return session;
}

void MacSnapShot::probe() {
  if (m_probed) return;
  m_probed = true;
  read();
  apply();
  emit changed();
}

void MacSnapShot::refresh() {
  if (!m_probed) return probe();
  const auto permissions = m_permissions;
  const QString error = m_permissionsError;
  const QString message = m_message;
  const bool holding = m_holding;
  read();
  apply();
  // The poll runs while a panel is open: quiet unless something moved.
  if (permissions != m_permissions || error != m_permissionsError || message != m_message || holding != m_holding) emit changed();
}

void MacSnapShot::read() {
  const auto now = m_platform ? m_platform->permissions() : std::nullopt;
  if (!now) {
    // The last answer stands until a read works again.
    m_permissionsError = kCheckFailed;
    return;
  }
  m_permissionsError.clear();
  m_permissions = *now;
}

QString MacSnapShot::permissionMessage() const {
  if (!m_permissions) return {};
  const bool accessibility = !m_includeAccessibility || m_permissions->accessibility;
  if (!accessibility && !m_permissions->screenRecording) return kBothMessage;
  if (!accessibility) return kAccessibilityMessage;
  return m_permissions->screenRecording ? QString() : kScreenRecordingMessage;
}

void MacSnapShot::setIncludeAccessibility(bool include) {
  if (include == m_includeAccessibility) return;
  m_includeAccessibility = include;
  if (!m_probed) return;
  apply();
  emit changed();
}

void MacSnapShot::watchPermissions(bool on) {
  if (on == m_poll.isActive()) return;
  if (!on) return m_poll.stop();
  m_poll.start();
  refresh();
}

void MacSnapShot::bind(const QString& trigger) {
  const QJsonObject shortcut = QJsonDocument::fromJson(trigger.toUtf8()).object();
  if (m_asked == shortcut) return;
  m_asked = shortcut;
  apply(true);
  emit changed();
}

void MacSnapShot::configure() {
  apply(true);
  emit changed();
}

void MacSnapShot::release() {
  m_asked.reset();
  apply();
  emit changed();
}

void MacSnapShot::apply(bool force) {
  if (!m_asked) {
    if (m_holding && m_platform) m_platform->letGo();
    m_holding = false;
    m_shortcut = {};
    m_message.clear();
    return;
  }
  m_message = permissionMessage();
  if (!m_message.isEmpty()) {
    if (m_holding && m_platform) m_platform->letGo();
    m_holding = false;
    m_shortcut = {};
    return;
  }
  // Holding already: an unrelated refresh leaves the watcher alone.
  if (m_holding && !force) return;
  if (m_holding && m_platform) m_platform->letGo();
  const QJsonObject& shortcut = *m_asked;
  const bool held = m_platform && (isPair(shortcut) ? m_platform->watchPair(pairModifier(shortcut)) : m_platform->holdChord(shortcut));
  m_holding = held;
  m_shortcut = {};
  m_shortcut.registered = held;
  m_shortcut.canRetry = false;
  m_shortcut.message = held ? (isPair(shortcut) ? observedMessage(shortcut) : QString()) : refusedMessage(shortcut);
}

bool MacSnapShot::available(const QJsonObject& shortcut, QString* message) {
  if (!m_platform) {
    *message = QStringLiteral("SnapShots are not supported on this platform.");
    return false;
  }
  // The one held now is the one being tried: let it go while trying.
  const bool wasHolding = m_holding;
  if (wasHolding) m_platform->letGo();
  const bool ok = isPair(shortcut) ? m_platform->watchPair(pairModifier(shortcut)) : m_platform->holdChord(shortcut);
  if (ok) m_platform->letGo();
  if (wasHolding) {
    m_holding = false;
    apply(true);
  }
  *message = ok ? (isPair(shortcut) ? observedMessage(shortcut) : QString()) : refusedMessage(shortcut);
  return ok;
}

QString MacSnapShot::requestPermissions(bool includeAccessibility) {
  if (!m_platform) return kCheckFailed;
  auto now = m_platform->permissions().value_or(MacPlatform::Permissions{});
  if (includeAccessibility && !now.accessibility) m_platform->request(MacPlatform::kAccessibility);
  if (!now.screenRecording) {
    m_platform->request(MacPlatform::kScreenRecording);
    now = m_platform->permissions().value_or(now);
    if (!now.screenRecording) m_platform->openSettings(MacPlatform::kScreenRecording);
  }
  now = m_platform->permissions().value_or(now);
  if (!now.screenRecording) {
    m_helper.show(MacPlatform::kScreenRecording);
  } else if (includeAccessibility && !now.accessibility) {
    m_platform->openSettings(MacPlatform::kAccessibility);
    m_helper.show(MacPlatform::kAccessibility);
  }
  refresh();
  if (includeAccessibility && !now.accessibility && !now.screenRecording) return kBothMessage;
  if (includeAccessibility && !now.accessibility) return kAccessibilityMessage;
  return now.screenRecording ? QString() : kScreenRecordingMessage;
}

void MacSnapShot::allow(const QString& permission) {
  if (!m_platform || (permission != MacPlatform::kScreenRecording && permission != MacPlatform::kAccessibility)) return;
  const auto now = m_platform->permissions().value_or(MacPlatform::Permissions{});
  const bool granted = permission == MacPlatform::kScreenRecording ? now.screenRecording : now.accessibility;
  if (!granted) {
    m_platform->request(permission);
    const auto after = m_platform->permissions().value_or(now);
    if (!(permission == MacPlatform::kScreenRecording ? after.screenRecording : after.accessibility)) m_platform->openSettings(permission);
  }
  m_helper.show(permission);
  refresh();
}

QString MacSnapShot::captureError(const MacPlatform::Capture& capture) const {
  const QString summary = QStringLiteral("Could not capture a test snapshot.");
  if (capture.status == QLatin1String("missing")) return summary + QStringLiteral(" No window is available to capture.");
  const bool finding = capture.step == QLatin1String("find-window");
  const QString task = finding ? QStringLiteral("Finding the front window") : QStringLiteral("Capturing the window");
  QString failure;
  if (capture.status == QLatin1String("timed-out")) failure = QStringLiteral("%1 timed out.").arg(task);
  else if (capture.status == QLatin1String("exited") && capture.exitCode >= 0)
    failure = QStringLiteral("%1 failed: screencapture exited with code %2.").arg(task).arg(capture.exitCode);
  else failure = QStringLiteral("%1 failed.").arg(task);
  // macOS can say both permissions are allowed while they belong to another
  // copy of the app.
  return QStringLiteral(
             "%1 %2 macOS grants Screen Recording and Accessibility to each app separately. In System Settings, open Privacy & "
             "Security and check that \"%3\" is allowed for both.")
      .arg(summary, failure, m_platform ? m_platform->appName() : QStringLiteral("HAL-C2"));
}

void MacSnapShot::test() {
  if (!m_platform) {
    emit tested(QStringLiteral("Test capture requires macOS."));
    return;
  }
  m_platform->capture(false, [this, guard = QPointer<MacSnapShot>(this)](const MacPlatform::Capture& result) {
    if (!guard) return;
    // The test image is never kept.
    emit tested(result.ok() ? QString() : captureError(result));
  });
}

void MacSnapShot::capture() {
  if (!m_platform || m_capturing) return;
  m_capturing = true;
  m_platform->capture(m_includeAccessibility, [this, guard = QPointer<MacSnapShot>(this)](const MacPlatform::Capture& result) {
    if (!guard) return;
    m_capturing = false;
    if (!result.ok()) {
      emit failed(result.status == QLatin1String("missing") ? QStringLiteral("No window is available to capture.")
                                                             : QStringLiteral("macOS could not capture the window."));
      return;
    }
    if (result.image.isNull()) {
      emit failed(QStringLiteral("macOS returned an invalid snapshot."));
      return;
    }
    const QImage image = result.image.width() > kMaxWidth || result.image.height() > kMaxHeight
                             ? result.image.scaled(kMaxWidth, kMaxHeight, Qt::KeepAspectRatio, Qt::SmoothTransformation)
                             : result.image;
    emit captured(image, result.app, result.title, result.context);
  });
}
