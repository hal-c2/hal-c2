#pragma once
// What another steps file needs from LaunchSteps.cpp.

#include <QJsonObject>
#include <QList>

class World;

// Every `orchestration.launchThread` the MC was asked, in order.
QList<QJsonObject> launchCalls(World& world);
