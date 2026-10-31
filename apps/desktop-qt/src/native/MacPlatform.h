#pragma once

#include <QImage>
#include <QJsonObject>
#include <QObject>
#include <QRect>
#include <QString>

#include <functional>
#include <optional>

#include "SnapShotBackend.h"

// What Snap Shot asks of macOS (MacSnapShot, MacPermissionHelper): the
// privacy permissions it needs, the capture shortcut, the window in front and
// System Settings' window. MacPlatform.mm is the real one (TCC,
// CGEventTap, Carbon hot keys, CGWindowList, screencapture, an NSPanel),
// built only on Apple; the native tests stand in a fake.
//
// Everything runs in the app's own process: watching both Shift keys needs
// no second app, so nothing else ever shows in the Dock.
class MacPlatform : public QObject {
  Q_OBJECT

public:
  // screen-recording | accessibility, as MacSnapShot names them.
  static inline const QString kScreenRecording = QStringLiteral("screen-recording");
  static inline const QString kAccessibility = QStringLiteral("accessibility");

  using Permissions = SnapShotBackend::Permissions;

  // A capture of the window in front, or where it failed: `step` find-window
  // or capture-window, `status` missing (no window), timed-out, exited (with
  // `exitCode`) or failed. `context` is the app's text, when it was asked for
  // and could be read ({accessibleText, accessibility}).
  struct Capture {
    QImage image;
    QString app;
    QString title;
    QString step;
    QString status;
    int exitCode = -1;
    QJsonObject context;
    bool ok() const { return step.isEmpty(); }
  };

  // System Settings' window, while it is open.
  struct SettingsWindow {
    bool open = false;
    bool frontmost = false;
    QRect bounds;
  };

  explicit MacPlatform(QObject* parent = nullptr) : QObject(parent) {}

  // The app as Privacy & Security lists it.
  virtual QString appName() const { return QStringLiteral("HAL-C2"); }

  // What macOS allows this app now; nullopt when it could not be asked.
  virtual std::optional<Permissions> permissions() = 0;
  // Asks for `permission`: the system's own prompt the first time, after
  // which only System Settings can change it.
  virtual void request(const QString& permission) = 0;
  // Opens `permission`'s list in System Settings, Privacy & Security.
  virtual void openSettings(const QString& permission) = 0;

  // Watches both keys of `modifier` (shift, control, alt, meta) being
  // pressed together; false when the system will not let the app watch keys.
  // `pressed` each time, `watchLost` if the system stops it later.
  virtual bool watchPair(const QString& modifier) = 0;
  // Holds a key chord ({key, metaKey, ctrlKey, shiftKey, altKey, modKey});
  // false when the system or another app already has it.
  virtual bool holdChord(const QJsonObject& shortcut) = 0;
  // Lets go of what watchPair or holdChord took.
  virtual void letGo() = 0;

  // Captures the window in front, with the app's text if `includeText`:
  // `done` once, on this thread.
  virtual void capture(bool includeText, std::function<void(const Capture&)> done) = 0;

  // nullopt when the system will not say where its windows are.
  virtual std::optional<SettingsWindow> settingsWindow() = 0;
  // The small panel beside System Settings (MacPermissionHelper): shown at
  // `bounds` without taking focus, saying `text`, the app draggable from it.
  virtual void showHelper(const QRect& bounds, const QString& text) = 0;
  virtual void hideHelper() = 0;
  virtual void closeHelper() = 0;
  virtual bool helperFocused() = 0;
  // Shows the app in Finder, for dragging it from there instead.
  virtual void revealApp() = 0;
  // Brings the app's window back to the front.
  virtual void focusApp() = 0;

  // This Mac's, or nullptr where there is none (off Apple, or a test's
  // factory says so).
  static MacPlatform* create(QObject* parent);
  // Tests stand in a platform of their own; MacSnapShot is then created
  // whatever the OS. An empty factory goes back to the real one.
  using Factory = std::function<MacPlatform*(QObject* parent)>;
  static void setFactory(Factory factory);
  static bool overridden();

signals:
  void pressed();
  void watchLost();
  // The user closed the permission panel.
  void helperDismissed();
  // The user chose to see the app in Finder from the permission panel.
  void helperRevealRequested();
};
