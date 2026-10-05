#pragma once
// What another steps file needs from ThemeLibrarySteps.cpp.

#include <QString>

class World;

// "The user removes <name>" while the window shows Settings → Appearance:
// asks to remove this device's theme of that name (one is made up when the
// scenario has none). False anywhere else.
bool removesTheme(World& world, const QString& name);
