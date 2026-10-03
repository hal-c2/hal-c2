#pragma once

class World;

// "the user removes it", when "it" is the saved environment a connection
// scenario set up (ConnectionHealthSteps.cpp): removes it from Connections
// settings and returns true. False when the scenario has no such environment.
bool removeSavedEnvironment(World& world);
