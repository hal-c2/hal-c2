#pragma once

#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>

#include <functional>
#include <optional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// Tells the user when a thread finishes or waits on them (the web's
// ThreadNotificationCoordinator). It follows the shell's rows, cluster and
// linked environments alike: a thread that completes, asks for approval or
// input, fails or stops at its usage limit alerts once per change. Threads it
// first sees (the snapshot after connecting, a newly linked environment) are
// only remembered, so what finished while the client was away stays quiet.
//
// This device's `notificationMode` (off, notifications, sound,
// notifications-and-sound) and `inAppNotificationsEnabled` decide how: while
// the window has focus, an in-app toast with "Open thread" for any thread but
// the one shown; without focus, a system notification per thread (a newer one
// replaces it), which the window's focus clears. Sound follows the mode alone.
// The platform side is the Presenter, which the app wires to
// NativeNotifications and tests fake.
//
// A thread's alerts can be muted on this device (`mutedAlertThreads`, thread
// keys): it is still followed, so unmuting alerts only what changes after.
// The palette's kToggleMute ("Mute alerts for this thread", the route
// thread) and the thread menu flip it.
class AlertController : public QObject, public NativeController {
  Q_OBJECT

public:
  struct Presenter {
    // Shows, or replaces, the system notification for thread `key`; false when
    // the system does not allow it.
    std::function<bool(const QString& key, const QString& title, const QString& body, bool silent)> show;
    // Closes every system notification shown.
    std::function<void()> clear;
    // Whether system notifications may be shown; off closes them, and clicks
    // on ones still on their way open nothing.
    std::function<void(bool enabled)> setEnabled;
    // `kind` is "completion" or "input".
    std::function<void(const QString& kind)> play;
  };

  AlertController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString&, const QVariant&) override { return false; }

  void setPresenter(Presenter presenter);
  // Whether the window has focus; the application's state unless tests say.
  bool focused() const { return m_focused; }
  void setFocused(bool focused);
  // A system notification for `key` was clicked: shows its thread. False when
  // system notifications are off or the thread is gone.
  bool openThread(const QString& key);

  static inline const QString kToggleMute = QStringLiteral("thread.toggleAlerts");
  static inline const QString kMutedKey = QStringLiteral("mutedAlertThreads");

  bool isMuted(const QString& key) const { return m_muted.contains(key); }
  // Mutes or unmutes thread `key`'s alerts on this device.
  void setMuted(const QString& key, bool muted);

  static bool hasSystemNotifications(const QString& mode) {
    return mode == QLatin1String("notifications") || mode == QLatin1String("notifications-and-sound");
  }
  static bool hasSound(const QString& mode) {
    return mode == QLatin1String("sound") || mode == QLatin1String("notifications-and-sound");
  }

private:
  void readSettings();
  void evaluate();
  // Keeps kToggleMute's title to the route thread.
  void present();

  struct Seen {
    // "runId:status" while the thread waits on the user or stopped.
    QString attention;
    std::optional<qint64> completion;
  };

  NodeClient* m_client;
  ShellStore* m_store;
  Presenter m_presenter;
  QString m_mode = QStringLiteral("off");
  bool m_inApp = false;
  bool m_focused = true;
  QHash<QString, Seen> m_seen;
  QSet<QString> m_muted;
};
