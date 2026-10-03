#pragma once
// What another steps file needs from PanelSteps.cpp.

#include <QJsonArray>
#include <QString>

class World;

// The current thread's turn `turn` finishes and leaves a checkpoint whose diff
// is `patch`; `files` ([{path, additions, deletions}]) is what the checkpoint
// says it changed.
void finishTurnWithPatch(World& world, int turn, const QString& patch, const QJsonArray& files = {});
