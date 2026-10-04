#pragma once

#include <QString>

class World;

// The identity steps' side of "<environment> is disconnected"
// (FilesIdentitySteps.cpp): when `environment` is the shell's own MC's, its
// connection drops, and true.
bool disconnectOwnEnvironment(World& world, const QString& environment);

// Their side of "<path> is offered" and "<path> is not offered": while the
// project icon picker is open the image files it offers are meant, and true.
bool checkIconImageOffered(World& world, const QString& path, bool offered);
