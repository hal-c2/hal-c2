#include "QuitController.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QKeyEvent>

#include <algorithm>

#include "../ShellBridge.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "SettingsController.h"

namespace {

const NativeControllerRegistrar<QuitController> registrar(QStringLiteral("quit"), {QStringLiteral("quitHint")}, nullptr,
                                                          NativeControllerScope::Shared);

const QString kHold = QStringLiteral("hold");
const QString kDoublePress = QStringLiteral("double-click");
const QString kDirect = QStringLiteral("direct");

// Qt calls Command Control on macOS, so this is mod either way.
constexpr int kModifierKey = Qt::Key_Control;

}  // namespace

QuitController::QuitController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {
  m_clock = [timer = std::make_shared<QElapsedTimer>()] {
    if (!timer->isValid()) timer->start();
    // Never 0, which means "no press yet".
    return timer->elapsed() + 1;
  };
  m_watchdog.setSingleShot(true);
  m_watchdog.callOnTimeout(this, [this] {
    if (auto then = std::exchange(m_onWatchdog, nullptr)) then();
  });
  m_linger.setSingleShot(true);
  m_linger.setInterval(kHintLingerMs);
  m_linger.callOnTimeout(this, [this] {
    m_hint.clear();
    publish();
  });
  // From the start: quitting needs no MC.
  if (QCoreApplication* app = QCoreApplication::instance()) app->installEventFilter(this);
}

void QuitController::activate() {
  if (m_active) return;
  m_active = true;
  publish();
}

void QuitController::attach(NativeWindow* window) {
  if (auto* keys = window->controller<KeybindingController>()) {
    keys->commands()->add(kQuit, tr("Quit HAL-C2"), [this] { quit(); });
    keys->commands()->setTerms(kQuit, {QStringLiteral("quit"), QStringLiteral("exit")});
  }
}

void QuitController::quit() {
  release();
  m_lastPressAt = 0;
  emit quitRequested();
}

QString QuitController::mode() const {
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  const QVariant value = settings ? settings->setting(QStringLiteral("confirmQuit")) : QVariant();
  // The old setting was a boolean.
  if (value.typeId() == QMetaType::Bool) return value.toBool() ? kHold : kDirect;
  const QString mode = value.toString();
  return mode == kDirect || mode == kDoublePress ? mode : kHold;
}

// Key events reach a window first and then its focused item, each through the
// application; only the window's delivery counts.
bool QuitController::eventFilter(QObject* watched, QEvent* event) {
  if (!watched->isWindowType()) return false;
  switch (event->type()) {
  case QEvent::ShortcutOverride: {
    // Claimed, so no shortcut (the macOS menu's Quit among them) takes it.
    auto* key = static_cast<QKeyEvent*>(event);
    if (key->key() == Qt::Key_Q && key->modifiers() == Qt::ControlModifier) {
      key->accept();
      return true;
    }
    return false;
  }
  case QEvent::KeyPress: {
    auto* key = static_cast<QKeyEvent*>(event);
    return keyDown(key->key(), key->modifiers(), key->isAutoRepeat());
  }
  case QEvent::KeyRelease: {
    auto* key = static_cast<QKeyEvent*>(event);
    // X11 pairs every auto-repeat press with a release.
    if (!key->isAutoRepeat()) keyUp(key->key());
    return false;
  }
  default:
    return false;
  }
}

bool QuitController::keyDown(int key, Qt::KeyboardModifiers modifiers, bool autoRepeat) {
  const qint64 now = m_clock();
  const bool modifierDown = modifiers.testFlag(Qt::ControlModifier);
  const bool isQ = key == Qt::Key_Q;
  if (autoRepeat && modifierDown && isQ) {
    m_repeatCadence = now - (m_lastRepeatAt == 0 ? m_heldSince : m_lastRepeatAt);
    m_lastRepeatAt = now;
  }
  if (m_quitOnRelease) {
    // Q still down pushes the quiet period back.
    if (isQ) quitAfterQuietPeriod();
    return true;
  }
  const bool other = modifiers & (Qt::AltModifier | Qt::ShiftModifier | Qt::MetaModifier);
  if (!modifierDown || other || !isQ) {
    // Pressing mod again starts the second press: it must not end the first.
    if (key == kModifierKey && !other) return false;
    // Any other key cancels the hold and the first press.
    if (!autoRepeat) {
      m_lastPressAt = 0;
      release();
    }
    return false;
  }
  if (autoRepeat) {
    if (m_mode == kHold && m_armed && now - m_heldSince >= kHoldMs) {
      m_armed = false;
      m_quitOnRelease = true;
      emit concealRequested();
      quitAfterQuietPeriod();
    }
    return true;
  }

  const qint64 previousPressAt = m_lastPressAt;
  m_lastPressAt = now;
  // A fresh press supersedes the hold, or the hint left after a release.
  if (m_holding || m_notified) release();
  // Every mode takes two presses.
  if (previousPressAt != 0 && now - previousPressAt <= kDoublePressMs) {
    quit();
    return true;
  }
  const QString mode = this->mode();
  if (mode == kDirect) {
    quit();
    return true;
  }
  m_holding = true;
  m_heldSince = now;
  m_mode = mode;
  m_notified = true;
  showHint(mode);
  if (mode == kDoublePress) {
    watch(kDoublePressMs, [this] { release(); });
    return true;
  }
  m_armed = true;
  // No auto-repeat by then means the key was released, or repeat is off:
  // either way, no quitting.
  watch(kHoldMs + kReleaseGraceMs, [this] { release(); });
  return true;
}

void QuitController::keyUp(int key) {
  if (key == Qt::Key_Q) {
    const bool shouldQuit = m_quitOnRelease;
    release(true);
    if (shouldQuit) emit quitRequested();
  } else if (key == kModifierKey) {
    if (m_quitOnRelease) quitAfterQuietPeriod();
    else release(true);
  }
}

void QuitController::release(bool keepDoublePressHint) {
  if (!m_holding && !m_notified) return;
  const bool keepHint = keepDoublePressHint && m_mode == kDoublePress && m_notified;
  m_holding = false;
  m_armed = false;
  m_quitOnRelease = false;
  m_lastRepeatAt = 0;
  m_repeatCadence = 0;
  if (keepHint) return;
  m_mode.clear();
  m_watchdog.stop();
  m_onWatchdog = nullptr;
  if (m_notified) {
    m_notified = false;
    hideHint();
  }
}

// Quits once the key has gone quiet, so its repeats cannot reach the next app.
// A slow repeat rate waits for two of its cadences.
void QuitController::quitAfterQuietPeriod() {
  watch(std::max<qint64>(kReleaseGraceMs, m_repeatCadence * 2), [this] { quit(); });
}

void QuitController::watch(int ms, std::function<void()> then) {
  m_onWatchdog = std::move(then);
  m_watchdog.start(ms);
}

void QuitController::showHint(const QString& mode) {
  m_linger.stop();
  m_hintMode = mode;
  auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  const QString shortcut = keys ? keys->keyLabel(QStringLiteral("mod+q")) : QStringLiteral("Ctrl+Q");
  m_hint = mode == kHold ? tr("Hold %1 or press twice to quit").arg(shortcut) : tr("Press %1 again to quit").arg(shortcut);
  publish();
}

// A double press's hint goes with its window; a hold's lingers.
void QuitController::hideHint() {
  if (m_hintMode == kDoublePress) {
    m_hint.clear();
    publish();
  } else {
    m_linger.start();
  }
}

void QuitController::publish() {
  m_bridge->publish(QStringLiteral("quitHint"),
                    m_hint.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(QVariantMap{{QStringLiteral("message"), m_hint}}));
}
