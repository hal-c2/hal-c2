#pragma once
// What another steps file needs from ThreadMenuSteps.cpp.

#include <QJsonObject>
#include <QString>

#include <functional>

class World;

// A thread by key (`env-a:t1`) or by title.
QString threadKeyOf(World& world, const QString& thread);
// The sidebar section listing the thread `key` (pinned, active, snoozed,
// settled), empty when none does.
QString sidebarSectionOf(World& world, const QString& key);
// Changes the MC's row for the thread `id`, sends it and waits for the shell.
void updateThreadRow(World& world, const QString& id, const std::function<void(QJsonObject&)>& change);
// The MC's rows follow the thread commands it accepts (pin, settle, snooze,
// visit...), as the real projection does.
void projectThreadCommands(World& world);
