#pragma once
// What another steps file needs from QtScenariosSteps.cpp.

#include <QString>

class World;

// Clicks the action labelled `label` on the notification that offers it,
// when one does ("the user chooses ...").
bool notificationChooses(World& world, const QString& label);
