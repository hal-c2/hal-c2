#pragma once

#include <QImage>
#include <QJsonObject>
#include <QObject>
#include <QProcessEnvironment>
#include <QString>

#include <functional>
#include <optional>

class WindowsSystem;

// The platform half of Snap Shot (SnapShotController): whether this session
// can capture, the global capture shortcut, and the capture itself.
//
// Linux Wayland captures through xdg-desktop-portal (PortalSnapShot): the
// Screenshot portal's active-window target where the desktop offers it, else
// its window picker, and the GlobalShortcuts portal for the shortcut. Windows
// captures directly (WindowsSnapShot). X11 and macOS are unavailable for now
// (UnavailableSnapShot).
//
// A backend answers from what it has already found out: `session()` is not
// ready until `probe()` has asked the desktop, and `bind()` leaves the
// shortcut pending until the desktop answers. Each change emits `changed`.
class SnapShotBackend : public QObject {
  Q_OBJECT

public:
  struct Session {
    // The desktop has been asked; until then nothing else here is known.
    bool ready = false;
    // portal | direct | unavailable
    QString mode = QStringLiteral("unavailable");
    // A portal's: screenshot-portal (the window in front) or picker (the
    // user chooses a window each time).
    QString backend;
    // gnome, kde, hyprland or niri (XDG_CURRENT_DESKTOP), else empty.
    QString desktop;
    // Why capture is unavailable or needs attention; empty when neither.
    QString message;
    // The desktop can flash the captured window and animate it.
    bool feedbackAvailable = false;
    // Capture needs no setup (Windows): turning it on is enough.
    bool setupFree = false;
  };

  // Whether a shortcut can be held, and what to tell the user about it.
  struct Availability {
    bool available = false;
    QString message;
  };

  struct Shortcut {
    bool registered = false;
    // Waiting on the desktop's permission prompt.
    bool pending = false;
    // What the desktop says the shortcut is, when it says.
    QString label;
    QString message;
    // The desktop can be asked to show its shortcut permissions again.
    bool canRetry = true;
  };

  explicit SnapShotBackend(QObject* parent = nullptr) : QObject(parent) {}

  virtual Session session() const = 0;
  virtual Shortcut shortcut() const { return {}; }
  // Asks the desktop what it offers; idempotent.
  virtual void probe() {}
  // Asks again after the user may have changed what the desktop allows.
  virtual void refresh() { probe(); }
  // What `bind` takes for `shortcut` (portalTrigger's, here); empty with
  // `error` set when this desktop cannot hold it.
  virtual QString trigger(const QJsonObject& shortcut, QString* error) const { return portalTrigger(shortcut, error); }
  // Whether `shortcut` can be saved, for a shortcut that collides with no
  // system one (DesktopSnapShot.checkShortcut).
  virtual Availability check(const QJsonObject& shortcut) const;
  // The desktop can watch both keys of one modifier as the shortcut.
  virtual bool watchesPairs() const { return false; }
  // The capture cues the user chose (snapShotFlash, snapShotAnimations).
  virtual void setCues(bool flash, bool animations) {
    Q_UNUSED(flash);
    Q_UNUSED(animations);
  }
  // Binds the capture shortcut to `trigger`, replacing the one before;
  // pending until the desktop answers.
  virtual void bind(const QString& trigger) { Q_UNUSED(trigger); }
  // Lets the capture shortcut go.
  virtual void release() {}
  // Shows the desktop's shortcut permissions again.
  virtual void configure() {}
  // Captures (or has the user pick) a window: `captured` or `failed`.
  virtual void capture() {}
  // Plays a capture sound: soft-pop (Whoosh) or camera-shutter (Click).
  virtual void play(const QString& sound);

  // The backend this session gets.
  static SnapShotBackend* create(QObject* parent);

  // Where a process with `env` captures: through the portal, and on which
  // desktop, or not at all and why.
  struct Platform {
    bool portal = false;
    QString desktop;
    QString message;
  };
  static Platform detect(const QProcessEnvironment& env, bool onLinux);

  // Tests stand in for the process environment (a Linux desktop's, on any
  // platform, or Windows' when it has OS=Windows_NT), the portal and Windows.
  using PortalFactory = std::function<SnapShotBackend*(const Platform&, QObject* parent)>;
  using WindowsFactory = std::function<WindowsSystem*(QObject* parent)>;
  static void setEnvironment(const std::optional<QProcessEnvironment>& env);
  static void setPortalFactory(PortalFactory factory);
  static void setWindowsFactory(WindowsFactory factory);

  // The portal's trigger for a key chord ({key, metaKey, ctrlKey, shiftKey,
  // altKey, modKey}), "CTRL+SHIFT+2"; empty with `error` set when the portal
  // cannot take it (a modifier pair, or a key it has no name for).
  static QString portalTrigger(const QJsonObject& shortcut, QString* error);

signals:
  void changed();
  // The capture shortcut was pressed.
  void activated();
  void captured(const QImage& image, const QString& appName, const QString& windowTitle);
  void failed(const QString& message);
};

// Where capture is not supported: only the reason.
class UnavailableSnapShot : public SnapShotBackend {
  Q_OBJECT

public:
  UnavailableSnapShot(const QString& message, QObject* parent) : SnapShotBackend(parent), m_message(message) {}

  Session session() const override {
    Session session;
    session.ready = true;
    session.message = m_message;
    return session;
  }

private:
  QString m_message;
};
