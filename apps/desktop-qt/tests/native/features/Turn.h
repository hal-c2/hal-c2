#pragma once
// What another steps file needs from TurnSteps.cpp.

#include <QString>

class World;

// Picks `label` in the agent's pending question, as the question panel does
// (SidebarSteps' "the user picks" does this when no menu is open).
void pickAnswer(World& world, const QString& label);

// Opens a thread of "shop" on a connected node, unless one is open.
void openTurnThread(World& world);
