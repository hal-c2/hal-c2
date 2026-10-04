#pragma once
// What another steps file needs from AlertSteps.cpp: the fake of the desktop's
// notification service, sound and badge that stands in for NativeNotifications.

#include <QMap>
#include <QString>
#include <QStringList>

class World;

// Whether the app's window has the user's attention, and whether the system
// lets the app notify.
void setAlertFocus(World& world, bool focused);
void setAlertsAllowed(World& world, bool allowed);

struct AlertsSeen {
  QMap<QString, QStringList> shown;  // the system notifications on screen, by thread key: {title, body}
  QStringList closed;                // the keys of those dismissed
  QStringList sounds;                // every sound played ("completion", "input")
  int badge = 0;                     // the app's badge
};
AlertsSeen alertsSeen(World& world);

// Clicks the system notification for thread `key`; `raised` gets the ids of
// the windows brought to the front. False when the click opens nothing.
bool clickNotification(World& world, const QString& key, QStringList* raised = nullptr);

// Alerts are on and the window is somewhere else, so what a thread does next
// reaches the user as a system notification.
void awaitSystemNotifications(World& world);
// The keys of the threads a system notification was shown for, oldest first.
QStringList systemNotifications(World& world);
// The user clicks the system notification about the thread `key`; whether it
// opened anything.
bool clickSystemNotification(World& world, const QString& key);
