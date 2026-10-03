#pragma once
// What another steps file needs from LaunchSteps.cpp.

#include <QJsonObject>
#include <QList>

class World;

// Every `orchestration.launchThread` payload the MC got, oldest first.
QList<QJsonObject> launchCalls(World& world);
