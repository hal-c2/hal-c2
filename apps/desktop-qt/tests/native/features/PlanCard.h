#pragma once
// What another steps file needs from TimelineSteps.cpp's plan card.

#include <QString>

class World;

// "the user chooses": a long plan's "Expand plan" or "Collapse plan" on the
// Timeline brick. False for anything else.
bool planCardChooses(World& world, const QString& label);
