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
// its window picker, and the GlobalShortcuts portal for the shortcut. Niri
// outside a sandbox captures over its own socket (NiriSnapShot). macOS
// (MacSnapShot) and Windows (WindowsSnapShot) capture directly. X11 is
// unavailable for now
// (UnavailableSnapShot).
//
// A backend answers from what it has already found out: `session()` is not
// ready until `probe()` has asked the desktop, and `bind()` leaves the
// shortcut pending until the desktop answers. Each change emits `changed`.
class SnapShotBackend : public QObject {
  Q_OBJECT

public:
  // What macOS allows this app.
  struct Permissions {
    bool screenRecording = false;
    bool accessibility = false;
    bool operator==(const Permissions&) const = default;
  };

  struct Session {
    // The desktop has been asked; until then nothing else here is known.
    bool ready = false;
    // portal | direct (macOS, Windows) | unavailable
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
    // Captures can carry the app's text and controls; otherwise only an image.
    bool appText = false;
    // The desktop is being asked again (`refresh()`) and has not answered.
    bool checking = false;
    // Where capture needs privacy permissions the user grants one at a time
    // (macOS), what is allowed; a failed check keeps the last answer and says
    // so in `permissionsError`.
    std::optional<Permissions> permissions;
    QString permissionsError;
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

  // Whether a shortcut can be the capture shortcut, and what to tell the user.
  struct Check {
    bool available = false;
    QString message;
  };

  explicit SnapShotBackend(QObject* parent = nullptr) : QObject(parent) {}

  virtual Session session() const = 0;
  virtual Shortcut shortcut() const { return {}; }
  // Asks the desktop what it offers; idempotent.
  virtual void probe() {}
  // Asks again after the user may have changed what the desktop allows.
  virtual void refresh() { probe(); }
  // What `bind` takes for `shortcut`: portalTrigger's for a portal, the
  // shortcut's JSON in direct mode; empty with `error` set when this desktop
  // cannot hold it.
  virtual QString trigger(const QJsonObject& shortcut, QString* error) const;
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
  // Whether `shortcut` can be held here: `done` answers once, maybe at once.
  // Unavailable with no message is a check that failed; a message on an
  // available shortcut in direct mode is shown (it may only be observed). A
  // portal names the shortcut's keys (portalTrigger) and confirms it only when
  // it is bound.
  virtual void checkShortcut(const QJsonObject& shortcut, std::function<void(const Check&)> done);
  // Pauses the capture shortcut while a new one is recorded, or ends the
  // pause; false when it could not, with the desktop's reason if it gave one.
  // The controller ignores the shortcut while it records, so a backend only
  // acts when it must let the OS go.
  virtual bool pause(bool paused, QString* reason) {
    Q_UNUSED(paused);
    Q_UNUSED(reason);
    return true;
  }
  // Shows the desktop's shortcut permissions again.
  virtual void configure() {}
  // Captures (or has the user pick) a window: `captured` or `failed`.
  virtual void capture() {}
  // The permissions below are for a backend whose session has `permissions`.
  // Captures include the app's text, which needs Accessibility too.
  virtual void setIncludeAccessibility(bool include) { Q_UNUSED(include); }
  // Checks the permissions again and again while setup shows them.
  virtual void watchPermissions(bool on) { Q_UNUSED(on); }
  // One permission's Allow (screen-recording | accessibility).
  virtual void allow(const QString& permission) { Q_UNUSED(permission); }
  // Asks for what capture needs; why it still cannot, or empty.
  virtual QString requestPermissions(bool includeAccessibility) {
    Q_UNUSED(includeAccessibility);
    return {};
  }
  // A capture that is thrown away, to prove capture works: `tested`.
  virtual void test() { emit tested({}); }
  // Plays a capture sound: soft-pop (Whoosh) or camera-shutter (Click).
  virtual void play(const QString& sound);
  // Tests hear the sounds instead of the speakers; null restores them.
  static void setSoundPlayer(std::function<void(const QString&)> player);

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
  static QProcessEnvironment environment();
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
  // `context` is what the attachment's source says of the app's text
  // ({accessibleText, accessibility}), when the backend could read it.
  void captured(const QImage& image, const QString& appName, const QString& windowTitle, const QJsonObject& context = {});
  void failed(const QString& message);
  // A test capture finished: why it failed, or empty.
  void tested(const QString& error);
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
