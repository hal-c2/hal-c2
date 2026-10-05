#pragma once
// What another steps file needs from KeybindingSteps.cpp.

#include <QEvent>
#include <QString>
#include <QVariantMap>

class World;

// What Settings → Keybindings says is wrong with the condition the user typed
// (empty when nothing is), for "the user is told".
QString conditionProblem(World& world);

// Sends a key event through the application to a window, as the platform
// does before any shortcut sees it. False when an application-wide filter
// (the quit shortcut's) took it, so the window never did.
bool sendKey(World& world, QEvent::Type type, int key, Qt::KeyboardModifiers modifiers, bool autoRepeat = false);

// Where the keyboard is for the scenario's next key presses ({terminal,
// composer, editable}; empty for the native chrome), connecting the shell first.
void setKeyFocus(World& world, const QVariantMap& focus);
// Presses a key as keybindings.json spells it ("mod+z"), as "the user presses" does.
void pressKey(World& world, const QString& key);
// Whether the last press ran `command`, and what it did, for a failure.
bool keyRan(World& world, const QString& command);
QString describeKeyPress(World& world);
// What received the last key the window did not take ("composer", "terminal", "window").
QString keyDeliveredTo(World& world);
