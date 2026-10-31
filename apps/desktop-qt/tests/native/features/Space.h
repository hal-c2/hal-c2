#pragma once
// What other steps files need of the Space steps (SpaceSteps.cpp).

#include <QString>

class World;

// Ticks (or unticks) the checklist item `text` of the Space page the user
// is on; false when no Space checklist item says that, which leaves the
// step to another domain's ("the user unticks" a Markdown task).
bool spaceTick(World& world, const QString& text, bool checked);
