#pragma once

#include <QDateTime>
#include <QHash>
#include <QImage>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QVariantMap>

#include <functional>
#include <optional>

#include "NativeController.h"

class NativeWindow;
class McClient;
class ShellBridge;
class ShellStore;
class SnapShotBackend;

// Snap Shot (the web's SnapShotSettings, SnapShotSetupDialog and
// SnapShotCoordinator over Electron's DesktopSnapShot): the capture
// shortcut takes the window the user is working in and attaches it to the
// current draft. The platform half is a SnapShotBackend (the desktop portal
// on Linux Wayland; unavailable elsewhere for now).
//
// The settings are this device's snapShot* rows (SettingsController). While
// Snap Shot is on the backend holds the saved shortcut; off, it lets it go.
// The desktop is asked what it offers once Snap Shot is on or a window opens
// Settings, SnapShots.
//
// A capture goes where the web's does: the thread or draft the window last
// acted in shows (else the last one it showed, while it still exists, else a
// new draft in the default project), shrunk to the attachment limit, with
// its snap-shot `source`; then the window comes to the front. Sound follows
// snapShotPlaySound and snapShotSound; the flash and the animation need the
// desktop's help, which the portal does not give.
//
// Publishes `snapShot`: the panel's rows and the setup walk-through, every
// string as the web words it. Actions:
//   snapShot.enable {on}, snapShot.setup.open {step?}, snapShot.setup.continue,
//   snapShot.setup.back, snapShot.setup.close {completed?}, snapShot.setup.done,
//   snapShot.record.start, snapShot.record.key {key, modifiers},
//   snapShot.record.modifier {modifier, code, down}, snapShot.record.cancel,
//   snapShot.shortcut.save, snapShot.shortcut.discard,
//   snapShot.shortcut.permissions, snapShot.set {key, value} (accessibility,
//   flash, animations), snapShot.sound {value: off | soft-pop | camera-shutter},
//   snapShot.sound.play {sound}.
class SnapShotController : public QObject, public NativeController {
  Q_OBJECT

public:
  SnapShotController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);
  ~SnapShotController() override;

  void activate() override;
  void attach(NativeWindow* window) override;
  bool handle(const QString& action, const QVariant& payload) override;

  SnapShotBackend* backend() const { return m_backend; }
  // The largest image a capture attaches (PROVIDER_SEND_TURN_MAX_IMAGE_BYTES).
  void setMaxImageBytes(qint64 bytes) { m_maxImageBytes = bytes; }
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

  static inline const QString kSection = QStringLiteral("/settings/snap-shot");
  static constexpr qint64 kMaxImageBytes = 10 * 1024 * 1024;

  // An image within `maxBytes`: the PNG as it is, else JPEG at falling
  // quality and size; nullopt when nothing fits. `mimeType` says which.
  static std::optional<QByteArray> encode(const QImage& image, qint64 maxBytes, QString* mimeType);

private:
  struct Check {
    bool available = false;
    QString message;
  };
  struct Wizard {
    QString step;
    bool wasEnabled = false;
  };

  QVariant setting(const QString& key) const;
  void set(const QString& key, const QVariant& value);
  bool enabled() const;
  QJsonObject savedShortcut() const;
  bool mac() const;
  bool accessReady() const;
  // A window shows Settings, SnapShots: the desktop is asked what it has.
  bool panelOpen() const;
  void follow();
  // Holds the saved shortcut while Snap Shot is on.
  void applyShortcut();

  QString initialStep(const QString& requested) const;
  void openSetup(const QString& requested);
  void closeSetup(bool completed);
  void stopRecording();
  void resetCandidate();
  void record(const QJsonObject& shortcut);
  Check check(const QJsonObject& shortcut) const;
  // The HAL-C2 command already bound to `shortcut`, or empty.
  QString conflict(const QJsonObject& shortcut) const;
  QString label(const QJsonObject& shortcut) const;
  bool shortcutChanged() const;
  bool canSave() const;
  QString shortcutStatus() const;

  void onActivated();
  void onCaptured(const QImage& image, const QString& appName, const QString& windowTitle);
  void onFailed(const QString& message);
  // Where a capture lands in `window`: its thread or draft, else the last one
  // it showed, else a new draft; empty with no project.
  QString target(NativeWindow* window);
  void noteRoute(NativeWindow* window);

  void publish();
  QVariantMap state() const;

  ShellBridge* m_bridge;
  ShellStore* m_store;
  QPointer<SnapShotBackend> m_backend;
  bool m_active = false;
  std::function<QDateTime()> m_now;
  qint64 m_maxImageBytes = kMaxImageBytes;
  // The trigger the backend holds, or empty.
  QString m_bound;
  // Why the saved shortcut cannot be held (a pair, or a key the portal has no
  // name for).
  QString m_shortcutProblem;
  std::optional<Wizard> m_wizard;
  bool m_recording = false;
  // Modifier keys held while recording: "<modifier>:<scan code>".
  QSet<QString> m_held;
  std::optional<QJsonObject> m_candidate;
  std::optional<Check> m_check;
  // Each window's last thread or draft (by window id).
  QHash<QString, QString> m_lastTarget;
  QVariantMap m_published;
};
