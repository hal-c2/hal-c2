#pragma once
// What other steps files need from RunNoticeSteps.cpp.

#include <QString>

class World;

// Whether the open thread's notice is about its background work, waiting
// until it reads `title` when it is.
bool backgroundNoticeSays(World& world, const QString& title);
// Dismisses the thread's error, when the scenario showed one; false otherwise.
bool dismissThreadError(World& world);
