#pragma once

#include <QByteArray>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QStringList>

#include <functional>
#include <optional>

#include "SnapShotBackend.h"

// What GnomeSnapShot asks GNOME Shell over the session bus: the HAL-C2
// extension's state, turning it on or off, and a capture through it. The
// real one is QtDBus (DBusGnomeShell); tests answer in its place.
class GnomeShell : public QObject {
  Q_OBJECT

public:
  struct Extension {
    // Why GNOME could not be asked; the rest is unknown when set.
    QString failure;
    // org.gnome.Shell.Extensions' ShellVersion, "47.2".
    QString shellVersion;
    bool userExtensionsEnabled = true;
    // GetExtensionInfo: unset until GNOME has loaded the extension (at a
    // login after it was installed). 1 is enabled, 3 and 4 failed.
    std::optional<int> state;
    std::optional<double> version;
    QString error;
    // The Version the extension's capture service answers with, 0 when it
    // does not answer.
    int service = 0;
  };

  struct Capture {
    QByteArray png;
    // JSON: title, appName, appIdentifier, processId, bounds.
    QString metadata;
    // Why there is no capture, when there is none.
    QString error;
  };

  explicit GnomeShell(QObject* parent = nullptr) : QObject(parent) {}

  virtual void inspect(std::function<void(const Extension&)> done) = 0;
  // EnableExtension or DisableExtension; done with an error, or empty.
  virtual void setEnabled(bool on, std::function<void(const QString& error)> done) = 0;
  // Takes `busName` for the call (no one else may hold it), then Capture, or
  // CaptureWithFeedback when `feedback` says which effects to show.
  virtual void capture(const QString& busName, std::optional<std::pair<bool, bool>> feedback,
                       std::function<void(const Capture&)> done) = 0;
};

// GNOME captures through HAL-C2's own extension (native/gnome-snap-shot):
// the desktop portal's Screenshot shows a picker there, while the extension
// takes the window in front. Setup installs the extension bundled with the
// app into the user's GNOME Shell extensions, then enables it.
//
// Everything else is `portal`'s: the shortcut, and the capture itself when
// the portal can take the window in front (preferred to the extension).
class GnomeSnapShot : public SnapShotBackend {
  Q_OBJECT

public:
  struct Paths {
    // The bundle: metadata.json, bundle.json and the files it lists.
    QString bundle;
    // $XDG_DATA_HOME: the extension goes to gnome-shell/extensions/<uuid>.
    QString dataHome;
  };

  // Where setup stands (GnomeCaptureSetup.state).
  struct Status {
    // unsupported, not-installed, restart-required, update-required,
    // extensions-disabled, enabled, error or disabled.
    QString status;
    QString message;
  };

  struct Metadata {
    QString uuid;
    double version = 0;
    QStringList shellVersions;
  };

  // Takes `portal` and `shell`.
  GnomeSnapShot(SnapShotBackend* portal, GnomeShell* shell, const Paths& paths, QObject* parent);

  Session session() const override;
  Shortcut shortcut() const override { return m_portal->shortcut(); }
  void probe() override;
  void refresh() override;
  void bind(const QString& trigger) override { m_portal->bind(trigger); }
  void release() override { m_portal->release(); }
  void configure() override { m_portal->configure(); }
  void capture() override;
  void play(const QString& sound) override { m_portal->play(sound); }
  void setEffects(bool flash, bool animate) override;
  std::optional<Setup> setup() const override;
  void perform(const QString& action) override;

  SnapShotBackend* portal() const { return m_portal; }

  static inline const QString kUuid = QStringLiteral("snap-shot@hal-c2.example");

  // The extension's metadata.json in `dir`, if it reads as the HAL-C2 one.
  static std::optional<Metadata> metadata(const QString& dir);
  static Status status(const GnomeShell::Extension& shell, const Metadata& bundled, const std::optional<Metadata>& installed);
  // Puts the bundle's files in place of the installed extension, keeping that
  // one under <dataHome>/hal-c2/extension-backups; empty, or why not.
  static QString install(const Paths& paths);
  // The name the extension answers (captureService.js trusts these two).
  static QString busName(const QString& appId);
  // The extension's PNG as an image no larger than 2560x1600; null with
  // `error` set when it is not one.
  static QImage decode(const QByteArray& png, QString* error);

private:
  // The extension's setup is the one shown: the portal cannot take the
  // window in front, so capture goes through the extension or a picker.
  bool extensionSetup() const;
  bool throughExtension() const;
  void inspect();
  Status current() const;

  QPointer<SnapShotBackend> m_portal;
  GnomeShell* m_shell;
  Paths m_paths;
  std::optional<GnomeShell::Extension> m_extension;
  // A check is under way; and the status before the user asked to check again.
  bool m_inspecting = false;
  std::optional<QString> m_checkingFrom;
  QString m_checkMessage;
  bool m_flash = false;
  bool m_animate = false;
  bool m_capturing = false;
};
