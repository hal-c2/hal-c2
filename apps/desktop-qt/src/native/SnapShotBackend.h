#pragma once

#include <QImage>
#include <QJsonObject>
#include <QObject>
#include <QProcessEnvironment>
#include <QList>
#include <QString>

#include <functional>
#include <optional>

// The platform half of Snap Shot (SnapShotController): whether this session
// can capture, the global capture shortcut, and the capture itself.
//
// Linux Wayland captures through xdg-desktop-portal (PortalSnapShot): the
// Screenshot portal's active-window target where the desktop offers it, else
// its window picker, and the GlobalShortcuts portal for the shortcut. X11,
// macOS and Windows are unavailable for now (UnavailableSnapShot).
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
    // portal | unavailable
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

  // A desktop whose capture has to be set up first (GNOME's extension, a
  // capture helper): what the access step says and offers. The controller
  // shows it as given; only perform() changes anything.
  struct Setup {
    // Capture works and setup can go on to the shortcut.
    bool accessReady = false;
    QString heading;
    QString body;
    // The access step's button: a perform() action, or empty to check again
    // (or continue, once ready) with actionLabel.
    QString action;
    QString actionLabel;
    // What the desktop said, when it explains a failure.
    QString details;
    // Said after checking again changed nothing; empty otherwise.
    QString checkMessage;
    // The capture row while capture is on and access is not ready.
    QString status;
    // Why capture effects are off; empty to leave it to feedbackAvailable.
    QString effects;
    struct Option {
      QString action;
      QString label;
      QString note;
    };
    // Advanced: undoing what setup did, and the like.
    QList<Option> advanced;
  };

  explicit SnapShotBackend(QObject* parent = nullptr) : QObject(parent) {}

  virtual Session session() const = 0;
  virtual Shortcut shortcut() const { return {}; }
  // Asks the desktop what it offers; idempotent.
  virtual void probe() {}
  // Asks again after the user may have changed what the desktop allows.
  virtual void refresh() { probe(); }
  // Binds the capture shortcut to `trigger` (portalTrigger's), replacing the
  // one before; pending until the desktop answers.
  virtual void bind(const QString& trigger) { Q_UNUSED(trigger); }
  // Lets the capture shortcut go.
  virtual void release() {}
  // Shows the desktop's shortcut permissions again.
  virtual void configure() {}
  // Captures (or has the user pick) a window: `captured` or `failed`.
  virtual void capture() {}
  // Plays a capture sound: soft-pop (Whoosh) or camera-shutter (Click).
  virtual void play(const QString& sound);
  // The capture effects the user wants, for a desktop that can show them.
  virtual void setEffects(bool flash, bool animate) { Q_UNUSED(flash); Q_UNUSED(animate); }
  // The setup this desktop needs before it captures; none by default.
  virtual std::optional<Setup> setup() const { return std::nullopt; }
  // Runs a setup step the user chose (install-extension, remove-kde-helper,
  // ...): `changed` once done, `setupFailed` if not. A step this desktop does
  // not have is refused and changes nothing.
  virtual void perform(const QString& action) { emit setupFailed(unsupportedSetup(action)); }

  // Why `action` cannot run in this session.
  static QString unsupportedSetup(const QString& action);

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
  void captured(const QImage& image, const QString& appName, const QString& windowTitle);
  void failed(const QString& message);
  // A setup step failed; shown in setup, not as a toast.
  void setupFailed(const QString& message);
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
