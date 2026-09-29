#pragma once
// What another steps file needs from KeybindingSteps.cpp.

#include <QString>

class World;

// What Settings → Keybindings says is wrong with the condition the user typed
// (empty when nothing is), for "the user is told".
QString conditionProblem(World& world);
