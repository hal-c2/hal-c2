#pragma once

class QString;
struct World;

// The Device tab's share of phrases other domains also use ("the user
// chooses …", "… is offered"), whose one step definition lives with the
// domain that had it first. Each returns whether it took the step.
bool deviceChooses(World& world, const QString& what);
bool deviceOpens(World& world, const QString& what);
bool checkDeviceOffered(World& world, const QString& name);
bool checkDeviceCanContinue(World& world);
bool checkDeviceCannotChoose(World& world, const QString& what);
