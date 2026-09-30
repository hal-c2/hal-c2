#pragma once
// What another steps file needs from KeybindingSteps.cpp.

#include <QEvent>
#include <QString>

class World;

// What Settings → Keybindings says is wrong with the condition the user typed
// (empty when nothing is), for "the user is told".
QString conditionProblem(World& world);

// Sends a key event through the application to a window, as the platform
// does before any shortcut sees it. False when an application-wide filter
// (the quit shortcut's) took it, so the window never did.
bool sendKey(World& world, QEvent::Type type, int key, Qt::KeyboardModifiers modifiers, bool autoRepeat = false);
