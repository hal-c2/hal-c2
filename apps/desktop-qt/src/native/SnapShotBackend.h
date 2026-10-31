#pragma once

#include <QImage>
#include <QJsonObject>
#include <QObject>
#include <QProcessEnvironment>
#include <QString>

#include <functional>
#include <optional>

// The platform half of Snap Shot (SnapShotController): whether this session
// can capture, the global capture shortcut, and the capture itself.
//
// Linux Wayland captures through xdg-desktop-portal (PortalSnapShot): the
// Screenshot portal's active-window target where the desktop offers it, else
// its window picker, and the GlobalShortcuts portal for the shortcut. macOS
// captures directly (MacSnapShot). X11 and Windows are unavailable for now
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
    // portal | direct (macOS) | unavailable
    QString mode = QStringLiteral("unavailable");
    // A portal's: screenshot-portal (the window in front) or picker (the
    // user chooses a window each time).
    QString backend;
    // gnome, kde, hyprland or niri (XDG_CURRENT_DESKTOP), else empty.
    QString desktop;
    // Why capture is unavailable or needs attention; empty when neither.
    QString message;
    // The desktop can flash the captured window and animate it (never yet).
    bool feedbackAvailable = false;
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

  explicit SnapShotBackend(QObject* parent = nullptr) : QObject(parent) {}

  virtual Session session() const = 0;
  virtual Shortcut shortcut() const { return {}; }
  // Asks the desktop what it offers; idempotent.
  virtual void probe() {}
  // Asks again after the user may have changed what the desktop allows.
  virtual void refresh() { probe(); }
  // Binds the capture shortcut to `trigger` (portalTrigger's; in direct mode
  // the shortcut's JSON), replacing the one before; pending until the
  // desktop answers.
  virtual void bind(const QString& trigger) { Q_UNUSED(trigger); }
  // Lets the capture shortcut go.
  virtual void release() {}
  // Shows the desktop's shortcut permissions again.
  virtual void configure() {}
  // Captures (or has the user pick) a window: `captured` or `failed`.
  virtual void capture() {}
  // Whether `shortcut` can be held here, and what to tell the user about it
  // (direct mode; a portal is asked when the shortcut is saved).
  virtual bool available(const QJsonObject& shortcut, QString* message) {
    Q_UNUSED(shortcut);
    Q_UNUSED(message);
    return false;
  }
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
  // platform) and the portal.
  using PortalFactory = std::function<SnapShotBackend*(const Platform&, QObject* parent)>;
  static void setEnvironment(const std::optional<QProcessEnvironment>& env);
  static void setPortalFactory(PortalFactory factory);

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
