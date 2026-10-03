#pragma once
// What another steps file needs from ThreadMenuSteps.cpp.

#include <QJsonArray>
#include <QJsonObject>
#include <QList>
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
// What the MC's `hal-c2.moveDestinations` answers.
void offerMoveDestinations(World& world, const QJsonArray& destinations);
// Runs when the MC accepts a `hal-c2.moveThread`, before it answers: the rows
// that follow the move, and what the answer says besides `status`.
void onThreadMoved(World& world, std::function<void(const QJsonObject& input, QJsonObject& answer)> moved);
// How the MC answers the next moves instead of moving: an error saying `refusal`.
void refuseThreadMoves(World& world, const QString& refusal);
// Every `hal-c2.moveThread` the MC was asked.
QList<QJsonObject> threadMovesAsked(World& world);
