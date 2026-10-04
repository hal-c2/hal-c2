#pragma once

#include <QString>

class World;

// The folder explorer's side of steps threads word alike (FilesFolderSteps.cpp):
// done, and true, when the scenario manages folders on disk.
bool renameManagedFolder(World& world, const QString& folder, const QString& name);
bool tryMoveManagedFolder(World& world, const QString& folder);
