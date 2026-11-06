#pragma once
// What another steps file needs from ThreadSettleSteps.cpp.

#include <QString>

class World;

// Runs the open thread notice's action named `choice` ("Un-settle"); false
// when the notice offers none of that name.
bool threadNoticeChooses(World& world, const QString& choice);
