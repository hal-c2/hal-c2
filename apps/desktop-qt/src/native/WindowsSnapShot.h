#pragma once

#include <QImage>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QRect>
#include <QTimer>

#include <optional>

#include "SnapShotBackend.h"

// What WindowsSnapShot needs from Windows, so its logic runs without it: the
// native one is src/native/win/WindowsSystem.cpp (built only on Windows); the
// feature tests give a fake.
class WindowsSystem : public QObject {
  Q_OBJECT

public:
  // The window in front: its HWND, title, bounds on the screen (physical
  // pixels) and the path of the program that owns it ("" when unknown).
  struct Window {
    quintptr id = 0;
    QString title;
    QRect bounds;
    QString program;
  };

  explicit WindowsSystem(QObject* parent = nullptr) : QObject(parent) {}

  virtual std::optional<Window> foreground() = 0;
  // Takes a picture of `bounds` on the screen, off the UI thread: `grabbed`
  // or `grabFailed`, once. `grabbing` holds until then, even after a cancel.
  virtual void grab(const QRect& bounds) = 0;
  virtual bool grabbing() const = 0;
  // The caller stopped waiting; a late answer is dropped.
  virtual void cancelGrab() = 0;

  // A key chord as a system hotkey (RegisterHotKey): MOD_* flags and a
  // virtual key. One at a time; `pressed` each time it is pressed.
  virtual bool holdHotKey(uint modifiers, uint key) = 0;
  virtual void releaseHotKey() = 0;
  // Whether `holdHotKey` would take it now, without keeping it.
  virtual bool canHoldHotKey(uint modifiers, uint key) = 0;
  // Both keys of a modifier, by their left and right virtual keys, through a
  // low-level keyboard hook: `pressed` when the second goes down while the
  // first is held. `watchLost` if the hook stops.
  virtual bool watchPair(uint left, uint right) = 0;
  virtual void stopWatching() = 0;
  virtual bool canWatchPair(uint left, uint right) = 0;

  // Windows' "Animate controls and elements inside windows".
  virtual bool animationsEnabled() const = 0;
  // A brief white flash over `bounds`, fading when `animated`.
  virtual void flash(const QRect& bounds, bool animated) = 0;
  // The captured image flying from `bounds` into HAL-C2, flashing first when
  // `flash`.
  virtual void fly(const QImage& image, const QRect& bounds, bool flash) = 0;

signals:
  void pressed();
  void watchLost();
  void grabbed(const QImage& image);
  void grabFailed(const QString& message);
};

// The Windows half of DesktopSnapShot ("direct" capture): no setup, the
// shortcut held by the system (a chord as a hotkey, a modifier pair through
// the keyboard hook), and the window in front grabbed off the screen at its
// bounds, shrunk to 2560x1600, with Windows' flash and flight as the cues.
class WindowsSnapShot : public SnapShotBackend {
  Q_OBJECT

public:
  WindowsSnapShot(WindowsSystem* system, QObject* parent);
  ~WindowsSnapShot() override;

  Session session() const override;
  Shortcut shortcut() const override { return m_shortcut; }
  void bind(const QString& trigger) override;
  void release() override;
  void capture() override;
  QString trigger(const QJsonObject& shortcut, QString* error) const override;
  Availability check(const QJsonObject& shortcut) const override;
  bool watchesPairs() const override { return true; }
  void setCues(bool flash, bool animations) override;

  WindowsSystem* system() const { return m_system; }
  bool capturing() const { return m_capturing; }
  // The capture's deadline passed (its timer calls this).
  void expire();

  // How long a capture waits for the picture; 15 s, as upstream.
  static void setCaptureTimeout(int ms);

  static inline const QString kCouldNotCapture = QStringLiteral("Could not capture the active window.");
  static inline const QString kNoWindow = QStringLiteral("The active window is not available for capture.");
  static constexpr int kMaxWidth = 2560;
  static constexpr int kMaxHeight = 1600;

  // A chord's RegisterHotKey arguments (MOD_* | MOD_NOREPEAT, VK_*); nullopt
  // for a key Windows has no virtual key for.
  static std::optional<std::pair<uint, uint>> hotKey(const QJsonObject& chord);
  // The left and right virtual keys of a modifier: shift, control, alt, meta.
  static std::optional<std::pair<uint, uint>> pairKeys(const QString& modifier);
  // What a capture's attachment calls the program at `path`: "Code" for
  // C:\...\Code.exe, "Window" with none.
  static QString appName(const QString& path);
  // "Super + Super is observed and cannot be reserved exclusively. ..."
  static QString observedMessage(const QString& modifier);
  static QString unavailableMessage(const QString& modifier);

private:
  void onGrabbed(const QImage& image);
  void onGrabFailed();
  void fail(const QString& message);

  QPointer<WindowsSystem> m_system;
  Shortcut m_shortcut;
  // The shortcut held, as `trigger` gave it.
  QString m_bound;
  bool m_flash = true;
  bool m_animations = true;
  bool m_capturing = false;
  WindowsSystem::Window m_window;
  QTimer m_deadline;
};

// The Windows the app runs on, or nullptr where it is not built
// (src/native/win/WindowsSystem.cpp).
WindowsSystem* createNativeWindowsSystem(QObject* parent);
