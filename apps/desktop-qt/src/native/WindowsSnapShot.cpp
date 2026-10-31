#include "WindowsSnapShot.h"

#include <QFileInfo>
#include <QHash>
#include <QJsonDocument>
#include <QRegularExpression>

namespace {

int& captureTimeout() {
  static int ms = 15000;
  return ms;
}

// RegisterHotKey's modifiers (WinUser.h).
constexpr uint kModAlt = 0x0001;
constexpr uint kModControl = 0x0002;
constexpr uint kModShift = 0x0004;
constexpr uint kModWin = 0x0008;
constexpr uint kModNoRepeat = 0x4000;

bool isPair(const QJsonObject& shortcut) {
  return shortcut.contains(QLatin1String("kind"));
}

QString pairModifier(const QJsonObject& shortcut) {
  return shortcut.value(QLatin1String("kind")).toString() == QLatin1String("both-shift-keys")
             ? QStringLiteral("shift")
             : shortcut.value(QLatin1String("modifier")).toString();
}

QString pairLabel(const QString& modifier) {
  QString name = QStringLiteral("Shift");
  if (modifier == QLatin1String("meta")) name = QStringLiteral("Super");
  if (modifier == QLatin1String("control")) name = QStringLiteral("Ctrl");
  if (modifier == QLatin1String("alt")) name = QStringLiteral("Alt");
  return QStringLiteral("%1 + %1").arg(name);
}

}  // namespace

WindowsSnapShot::WindowsSnapShot(WindowsSystem* system, QObject* parent) : SnapShotBackend(parent), m_system(system) {
  m_system->setParent(this);
  m_deadline.setSingleShot(true);
  connect(&m_deadline, &QTimer::timeout, this, &WindowsSnapShot::expire);
  connect(m_system, &WindowsSystem::pressed, this, &SnapShotBackend::activated);
  connect(m_system, &WindowsSystem::grabbed, this, &WindowsSnapShot::onGrabbed);
  connect(m_system, &WindowsSystem::grabFailed, this, &WindowsSnapShot::onGrabFailed);
  // The hook stopped: the pair is no longer watched (setShortcutFailure).
  connect(m_system, &WindowsSystem::watchLost, this, [this] {
    const QJsonObject held = QJsonDocument::fromJson(m_bound.toUtf8()).object();
    if (!isPair(held)) return;
    m_system->stopWatching();
    m_shortcut = {};
    m_shortcut.canRetry = false;
    m_shortcut.message = unavailableMessage(pairModifier(held));
    emit changed();
  });
}

WindowsSnapShot::~WindowsSnapShot() {
  if (m_system) {
    m_system->releaseHotKey();
    m_system->stopWatching();
    if (m_capturing) m_system->cancelGrab();
  }
}

void WindowsSnapShot::setCaptureTimeout(int ms) {
  captureTimeout() = ms;
}

SnapShotBackend::Session WindowsSnapShot::session() const {
  Session session;
  session.ready = true;
  session.mode = QStringLiteral("direct");
  session.feedbackAvailable = true;
  session.setupFree = true;
  return session;
}

// --- The shortcut -----------------------------------------------------------------

std::optional<std::pair<uint, uint>> WindowsSnapShot::hotKey(const QJsonObject& chord) {
  static const QHash<QString, uint> named{
      {QStringLiteral(" "), 0x20},        {QStringLiteral("space"), 0x20},    {QStringLiteral("escape"), 0x1B},
      {QStringLiteral("esc"), 0x1B},      {QStringLiteral("enter"), 0x0D},    {QStringLiteral("tab"), 0x09},
      {QStringLiteral("backspace"), 0x08}, {QStringLiteral("delete"), 0x2E},  {QStringLiteral("insert"), 0x2D},
      {QStringLiteral("home"), 0x24},     {QStringLiteral("end"), 0x23},      {QStringLiteral("pageup"), 0x21},
      {QStringLiteral("pagedown"), 0x22}, {QStringLiteral("arrowleft"), 0x25}, {QStringLiteral("left"), 0x25},
      {QStringLiteral("arrowup"), 0x26},  {QStringLiteral("up"), 0x26},       {QStringLiteral("arrowright"), 0x27},
      {QStringLiteral("right"), 0x27},    {QStringLiteral("arrowdown"), 0x28}, {QStringLiteral("down"), 0x28},
      {QStringLiteral(";"), 0xBA},        {QStringLiteral("="), 0xBB},        {QStringLiteral(","), 0xBC},
      {QStringLiteral("-"), 0xBD},        {QStringLiteral("."), 0xBE},        {QStringLiteral("/"), 0xBF},
      {QStringLiteral("`"), 0xC0},        {QStringLiteral("["), 0xDB},        {QStringLiteral("\\"), 0xDC},
      {QStringLiteral("]"), 0xDD},        {QStringLiteral("'"), 0xDE},
  };
  static const QRegularExpression function(QStringLiteral("^f([1-9]|1\\d|2[0-4])$"));
  const QString key = chord.value(QLatin1String("key")).toString().toLower();
  uint vk = named.value(key);
  if (!vk && key.size() == 1 && ((key[0] >= u'a' && key[0] <= u'z') || (key[0] >= u'0' && key[0] <= u'9'))) {
    vk = key[0].toUpper().unicode();
  }
  if (const auto match = function.match(key); !vk && match.hasMatch()) vk = 0x70 + match.captured(1).toUInt() - 1;
  if (!vk) return std::nullopt;
  const auto on = [&](const char* name) { return chord.value(QLatin1String(name)).toBool(); };
  uint modifiers = kModNoRepeat;
  if (on("ctrlKey") || on("modKey")) modifiers |= kModControl;
  if (on("altKey")) modifiers |= kModAlt;
  if (on("shiftKey")) modifiers |= kModShift;
  if (on("metaKey")) modifiers |= kModWin;
  return std::pair{modifiers, vk};
}

std::optional<std::pair<uint, uint>> WindowsSnapShot::pairKeys(const QString& modifier) {
  if (modifier == QLatin1String("shift")) return std::pair<uint, uint>{0xA0, 0xA1};
  if (modifier == QLatin1String("control")) return std::pair<uint, uint>{0xA2, 0xA3};
  if (modifier == QLatin1String("alt")) return std::pair<uint, uint>{0xA4, 0xA5};
  if (modifier == QLatin1String("meta")) return std::pair<uint, uint>{0x5B, 0x5C};
  return std::nullopt;
}

QString WindowsSnapShot::observedMessage(const QString& modifier) {
  QString message = tr("%1 is observed and cannot be reserved exclusively.").arg(pairLabel(modifier));
  if (modifier == QLatin1String("meta")) message += tr(" This key can also open the system's own menu.");
  if (modifier == QLatin1String("alt")) message += tr(" This key can also activate app menu bars.");
  return message;
}

QString WindowsSnapShot::unavailableMessage(const QString& modifier) {
  return tr("%1 is not available on this system.").arg(pairLabel(modifier));
}

QString WindowsSnapShot::trigger(const QJsonObject& shortcut, QString* error) const {
  if (error) error->clear();
  QJsonObject held;
  if (isPair(shortcut)) {
    const QString modifier = pairModifier(shortcut);
    if (!pairKeys(modifier)) {
      if (error) *error = unavailableMessage(modifier);
      return {};
    }
    held = {{QStringLiteral("kind"), QStringLiteral("modifier-pair")}, {QStringLiteral("modifier"), modifier}};
  } else {
    if (!hotKey(shortcut)) {
      if (error) *error = tr("The system could not register this shortcut.");
      return {};
    }
    for (const char* name : {"key", "metaKey", "ctrlKey", "shiftKey", "altKey", "modKey"}) {
      held.insert(QLatin1String(name), shortcut.value(QLatin1String(name)));
    }
    held.insert(QStringLiteral("key"), shortcut.value(QLatin1String("key")).toString().toLower());
  }
  return QString::fromUtf8(QJsonDocument(held).toJson(QJsonDocument::Compact));
}

void WindowsSnapShot::checkShortcut(const QJsonObject& shortcut, std::function<void(const Check&)> done) {
  QString problem;
  const QString wanted = trigger(shortcut, &problem);
  if (wanted.isEmpty()) {
    done({false, problem});
    return;
  }
  // The one already held is free to keep; asking Windows again would refuse it.
  const bool held = wanted == m_bound && m_shortcut.registered;
  if (isPair(shortcut)) {
    const QString modifier = pairModifier(shortcut);
    const auto keys = *pairKeys(modifier);
    const bool available = held || m_system->canWatchPair(keys.first, keys.second);
    done({available, available ? observedMessage(modifier) : unavailableMessage(modifier)});
    return;
  }
  const auto key = *hotKey(shortcut);
  if (held || m_system->canHoldHotKey(key.first, key.second)) done({true, {}});
  else done({false, tr("This shortcut is already used by the system or another app.")});
}

void WindowsSnapShot::bind(const QString& trigger) {
  m_system->releaseHotKey();
  m_system->stopWatching();
  m_bound = trigger;
  m_shortcut = {};
  m_shortcut.canRetry = false;
  const QJsonObject held = QJsonDocument::fromJson(trigger.toUtf8()).object();
  if (isPair(held)) {
    const QString modifier = pairModifier(held);
    const auto keys = pairKeys(modifier);
    m_shortcut.registered = keys && m_system->watchPair(keys->first, keys->second);
    m_shortcut.message = m_shortcut.registered ? observedMessage(modifier) : unavailableMessage(modifier);
  } else {
    const auto key = hotKey(held);
    m_shortcut.registered = key && m_system->holdHotKey(key->first, key->second);
    if (!m_shortcut.registered) m_shortcut.message = tr("This shortcut is already used by the system or another app.");
  }
  emit changed();
}

void WindowsSnapShot::release() {
  m_system->releaseHotKey();
  m_system->stopWatching();
  m_bound.clear();
  m_shortcut = {};
  m_shortcut.canRetry = false;
  emit changed();
}

// --- Capturing --------------------------------------------------------------------

void WindowsSnapShot::setCues(bool flash, bool animations) {
  m_flash = flash;
  m_animations = animations;
}

QString WindowsSnapShot::appName(const QString& path) {
  const QString name = QFileInfo(QString(path).replace(u'\\', u'/')).fileName().trimmed();
  static const QRegularExpression exe(QStringLiteral("\\.exe$"), QRegularExpression::CaseInsensitiveOption);
  const QString bare = QString(name).remove(exe).trimmed();
  if (!bare.isEmpty()) return bare;
  return name.isEmpty() ? QStringLiteral("Window") : name;
}

// A second press while one is being taken or its cue still shows is ignored;
// a grab still running from before (one that timed out) fails this one rather
// than queue behind it.
void WindowsSnapShot::capture() {
  if (m_capturing || m_system->cueShowing()) return;
  const auto window = m_system->foreground();
  if (!window || window->bounds.isEmpty()) {
    emit failed(kNoWindow);
    return;
  }
  if (m_system->grabbing()) {
    emit failed(kCouldNotCapture);
    return;
  }
  m_capturing = true;
  m_window = *window;
  m_deadline.start(captureTimeout());
  m_system->grab(window->bounds);
}

void WindowsSnapShot::expire() {
  if (!m_capturing) return;
  m_system->cancelGrab();
  fail(kCouldNotCapture);
}

void WindowsSnapShot::fail(const QString& message) {
  m_deadline.stop();
  m_capturing = false;
  emit failed(message);
}

void WindowsSnapShot::onGrabFailed() {
  if (m_capturing) fail(kCouldNotCapture);
}

void WindowsSnapShot::onGrabbed(const QImage& grabbed) {
  if (!m_capturing) return;
  m_deadline.stop();
  m_capturing = false;
  if (grabbed.isNull()) {
    emit failed(kCouldNotCapture);
    return;
  }
  QImage image = grabbed;
  if (image.width() > kMaxWidth || image.height() > kMaxHeight) {
    image = image.scaled(kMaxWidth, kMaxHeight, Qt::KeepAspectRatio, Qt::SmoothTransformation);
  }
  // The flight carries the flash when it runs; without it, a still flash.
  if (m_animations && m_system->animationsEnabled()) {
    m_system->fly(image, m_window.bounds, m_flash);
  } else if (m_flash) {
    m_system->flash(m_window.bounds, false);
  }
  emit captured(image, appName(m_window.program), m_window.title);
}

#ifndef Q_OS_WIN
WindowsSystem* createNativeWindowsSystem(QObject*) {
  return nullptr;
}
#endif
