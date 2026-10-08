#pragma once

#include <QObject>
#include <QString>
#include <QTimer>

#include <functional>

#include "NativeController.h"

class McClient;
class ShellBridge;

// The quit shortcut (mod+Q), guarded as this device's `confirmQuit` says
// (apps/desktop/src/window/QuitHold.ts):
//   - "hold" (the default): holding it 1.2 seconds quits, as do two presses
//     within half a second; a single quick press only says how.
//   - "double-click": two presses within half a second quit; one says to
//     press again.
//   - "direct": one press quits.
// It watches the application's key events, so a text field, a terminal or the
// system menu never sees the shortcut. "Still held" is proven by auto-repeat,
// as in Electron: without it only two presses quit. Quit (the palette's
// `app.quit`, the system menu) is immediate.
//
// Publishes `quitHint`: null, or {message} while the hint shows (every window).
class QuitController : public QObject, public NativeController {
  Q_OBJECT

public:
  static constexpr int kHoldMs = 1200;
  static constexpr int kDoublePressMs = 500;
  static constexpr int kReleaseGraceMs = 600;
  // A released hold's hint stays as long as a hold takes.
  static constexpr int kHintLingerMs = 1200;
  static inline const QString kQuit = QStringLiteral("app.quit");

  QuitController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  void attach(NativeWindow* window) override;
  bool handle(const QString&, const QVariant&) override { return false; }

  // Quits now, whatever the setting.
  void quit();
  QString hint() const { return m_hint; }
  // Milliseconds for timing presses and what waits on them; a monotonic clock
  // unless tests say. A test that sets it calls poll() as it moves it.
  void setClock(std::function<qint64()> clock) { m_clock = std::move(clock); }
  // Runs what the clock says is due: a hold given up, a quiet period over, a
  // hint gone. Its timer calls it.
  void poll();

signals:
  // main.cpp quits the application.
  void quitRequested();
  // A hold is complete: the windows can go while the key is released.
  void concealRequested();

protected:
  bool eventFilter(QObject* watched, QEvent* event) override;

private:
  QString mode() const;
  // True when the press is the quit shortcut's, and so not the window's.
  bool keyDown(int key, Qt::KeyboardModifiers modifiers, bool autoRepeat);
  void keyUp(int key);
  void release(bool keepDoublePressHint = false);
  void quitAfterQuietPeriod();
  void watch(qint64 ms, std::function<void()> then);
  void schedule();
  void showHint(const QString& mode);
  void hideHint();
  void publish();

  ShellBridge* m_bridge;
  std::function<qint64()> m_clock;
  QTimer m_timer;
  // Clock deadlines, 0 for none.
  qint64 m_watchAt = 0;
  std::function<void()> m_onWatchdog;
  qint64 m_lingerAt = 0;
  QString m_mode;
  QString m_hintMode;
  QString m_hint;
  bool m_holding = false;
  bool m_notified = false;
  // A hold may complete (from auto-repeats) only once armed.
  bool m_armed = false;
  bool m_quitOnRelease = false;
  qint64 m_heldSince = 0;
  qint64 m_lastPressAt = 0;
  qint64 m_lastRepeatAt = 0;
  qint64 m_repeatCadence = 0;
  bool m_active = false;
};
