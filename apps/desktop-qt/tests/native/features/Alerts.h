#pragma once
// What another steps file needs from AlertSteps.cpp.

#include <QString>
#include <QStringList>

class World;

// Alerts are on and the window is somewhere else, so what a thread does next
// reaches the user as a system notification.
void awaitSystemNotifications(World& world);
// The keys of the threads a system notification was shown for, oldest first.
QStringList systemNotifications(World& world);
// The user clicks the system notification about the thread `key`; whether it
// opened anything.
bool clickSystemNotification(World& world, const QString& key);
