#pragma once
// What another steps file needs from WindowSteps.cpp: the quit shortcut, timed
// on a clock the steps move.

#include <QString>

class World;

// mod+Q goes down and comes up `heldMs` later (auto-repeating while held);
// `releaseMod` false keeps mod down for another press.
void pressQuitShortcut(World& world, qint64 heldMs, bool releaseMod = true);
void advanceQuitClock(World& world, qint64 ms);
// How often the app was asked to quit, and what the quit hint says.
int quitRequests(World& world);
QString quitShortcutHint(World& world);
