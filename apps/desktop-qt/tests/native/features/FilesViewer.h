#pragma once

#include <QString>

class World;

// The viewer steps' side of "the user is looking at <name>" (AlertSteps.cpp's,
// which means a thread): a path with a folder and an extension is a file to
// open in the viewer, and true.
bool lookAtFile(World& world, const QString& path);

// Their side of "<name> opens" (ThreadMenuSteps.cpp's, which means a thread):
// a path with a folder and an extension is a file the viewer has open, and true.
bool fileOpened(World& world, const QString& path);

// Their side of "the user removes it" (ThemeSteps.cpp's, which means a
// theme): while an attachment is open in its viewer it is removed from there,
// and true.
bool removeViewedAttachment(World& world);
