#pragma once

#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QUrl>

#include <memory>

#include "push/PushInbox.h"
#include "push/PushSystem.h"

class NativeShell;
class Pairing;
class ShellBridge;

// The phone's notifications: the MC it is paired with pushes alerts and the
// activity card (apps/server-ex HalC2.Push) through the UnifiedPush
// distributor the user picked, to an endpoint this registers with it
// (`hal-c2.registerPush`), and the push inbox decides what of each push the
// system shows. While the app is open it works the card out itself from the
// rows it shows, so it is right the moment the app comes back.
//
// Publishes `notifications`:
//   {supported:    the build can receive pushes,
//    permission:   granted | denied | ask, the system's word on notifications,
//    enabled:      allowed, and a distributor gave an endpoint,
//    distributors: [{id, label}] installed,
//    distributor:  the id picked, "" when none,
//    choosing:     the user is asked which distributor to use,
//    liveActivity: the activity card is on,
//    liveUpdates:  Android 16's live update settings exist,
//    quietHours:   null | {start, end, allowApprovals} (minutes after midnight),
//    muted:        the keys of the threads whose alerts are muted,
//    message:      a sentence for the user, "" when none}
//
// Actions: `notifications.enable` (asks for permission and a distributor,
// as needed), `notifications.disable` and `notifications.openSettings` (the
// system's settings, where notifications are turned off),
// `notifications.pickDistributor {id}`, `notifications.setLiveActivity {on}`,
// `notifications.openLiveUpdateSettings`, `notifications.setQuietHours
// {quietHours}`, and `alerts.setMuted {key, muted}` for one thread.
//
// It also takes `hal-c2://threads/<environment>/<thread>`, the link a
// tapped notification opens the app with, and shows that thread once the
// phone has it; other `hal-c2:` links go to Pairing.
class Notifications : public QObject {
  Q_OBJECT

public:
  Notifications(ShellBridge* bridge, NativeShell* shell, Pairing* pairing, std::shared_ptr<PushSystem> system, const QString& dataDir,
                QObject* parent = nullptr);

  // Asks the distributor for its endpoint again, as each start should. Once,
  // when the shell is set up.
  void start();

public slots:
  // A `hal-c2:` link the system opened the app with. From Android's thread,
  // so it is passed on to this one.
  void openLink(const QUrl& url);

private:
  bool handle(const QString& action, const QVariant& payload);
  void enable();
  void subscribe();
  void setLiveActivity(bool on);
  // The user forgot the environment: it stops pushing to this phone.
  void forgetEnvironment();
  // The app came to the front or left it.
  void activeChanged(bool active);
  void registerPush();
  // The card for what the shell shows now; `force` puts it up even when it
  // is what it was.
  void updateActivity(bool force);
  void show(const QJsonObject& effects);
  void openPending();
  QJsonObject quietHours();
  push::Device device() const;
  void publish();

  ShellBridge* m_bridge;
  NativeShell* m_shell;
  Pairing* m_pairing;
  std::shared_ptr<PushSystem> m_system;
  push::Inbox m_inbox;
  PushSystem::Permission m_permission = PushSystem::Permission::Ask;
  bool m_active = false;
  bool m_choosing = false;
  QString m_message;
  // What the MC was last sent, so the same registration is sent once per
  // connection.
  QJsonObject m_registered;
  // The activity last put up from the shell's rows.
  QJsonObject m_activity;
  // The thread a tapped notification asked for, until the phone has it.
  QString m_pending;
};
