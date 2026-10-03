#pragma once
// What another steps file needs from TurnSteps.cpp.

#include <QString>

class World;

// Picks `label` in the agent's pending question, as the question panel does
// (SidebarSteps' "the user picks" does this when no menu is open).
void pickAnswer(World& world, const QString& label);

// Opens a thread of "shop" on a connected MC, unless one is open.
void openTurnThread(World& world);

// The same thread with its agent working on a turn, and a message waiting in
// its queue behind that turn (its run is "run-queued-<text>").
void startWorkingTurn(World& world);
void queueTurnMessage(World& world, const QString& text);
