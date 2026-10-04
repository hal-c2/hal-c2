#pragma once
// What another steps file needs from MoveSteps.cpp: the cluster of machines
// threads/moving-between-machines.feature builds, whose steps share words
// with other domains'. Each answers false when the scenario built no such
// cluster, and the caller goes on as before.

#include <QString>

#include "FakeMc.h"

class World;

// Answers `hal-c2.moveDestinations` and `hal-c2.moveThread` as the machines'
// MCs do, their rows following the move.
bool answerMachineMove(FakeMc& mc, const FakeMc::Rpc& rpc);
// Shows the thread titled `title` on the machine it lives on.
bool showMachineThread(World& world, const QString& title);
// Checks that a move does not offer `machine`, from the menu or the palette.
bool machineNotOffered(World& world, const QString& machine);
