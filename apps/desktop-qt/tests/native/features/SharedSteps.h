#pragma once

#include <QString>

class World;

// "the user removes it", when "it" is the saved environment a connection
// scenario set up (ConnectionHealthSteps.cpp): removes it from Connections
// settings and returns true. False when the scenario has no such environment.
bool removeSavedEnvironment(World& world);

// "<command> is not offered", when the composer's command menu is open
// (UsageLimitsCommandSteps.cpp): fails the step if the menu offers it.
void expectCommandNotOffered(World& world, const QString& command);
