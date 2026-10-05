#pragma once

#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>

#include <functional>
#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// Tells the user when a thread finishes or waits on them (the web's
// ThreadNotificationCoordinator). It follows the shell's rows, on every
// machine of the cluster: a thread that completes, asks for approval or
// input, fails or stops at its usage limit alerts once per change. Threads it
// first sees (the snapshot after connecting, a machine that joins) are
// only remembered, so what finished while the client was away stays quiet.
//
// This device's `notificationMode` (off, notifications, sound,
// notifications-and-sound) and `inAppNotificationsEnabled` decide how: while
// the window has focus, an in-app toast with "Open thread" for any thread but
// the one shown; without focus, a system notification per thread (a newer one
// replaces it), which the window's focus clears. Sound follows the mode alone.
// Turns that finish without focus are counted on the dock or taskbar badge
// until the window has focus again.
// The platform side is the Presenter, which the app wires to
// NativeNotifications and tests fake.
//
// A thread's alerts can be muted on this device (`mutedAlertThreads`, thread
// keys): it is still followed, so unmuting alerts only what changes after.
// The palette's kToggleMute flips it for the thread shown, titled "Mute
// alerts for this thread" or "Unmute alerts for this thread".
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
    // Whether the system lets the app notify; unset where it never refuses.
    // Choosing system notifications while it does not is undone, with a
    // toast saying how to allow them.
    std::function<bool()> permitted;
    // The dock or taskbar badge: how many turns finished since the window
    // last had focus (0 clears it).
    std::function<void(int count)> badge;
  };

  AlertController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  void attach(NativeWindow* window) override;
  bool handle(const QString&, const QVariant&) override { return false; }

  void setPresenter(Presenter presenter);
  // Whether the window has focus; the application's state unless tests say.
  bool focused() const { return m_focused; }
  void setFocused(bool focused);
  // A system notification for `key` was clicked: shows its thread in the
  // window the user last acted in and raises that window. False when system
  // notifications are off or the thread is gone.
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
  // Keeps kToggleMute's title to the route thread, in every window or one.
  void present();
  void present(NativeWindow* window);

  struct Seen {
    // "runId:status" while the thread waits on the user or stopped.
    QString attention;
    std::optional<qint64> completion;
  };

  McClient* m_client;
  ShellStore* m_store;
  Presenter m_presenter;
  QString m_mode = QStringLiteral("off");
  bool m_inApp = false;
  bool m_focused = true;
  // Turns finished since the window last had focus.
  int m_unseen = 0;
  QHash<QString, Seen> m_seen;
  QSet<QString> m_muted;
  bool m_settingsRead = false;
};
