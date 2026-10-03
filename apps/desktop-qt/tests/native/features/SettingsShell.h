#pragma once
// What the settings steps files share (SettingsSearchSteps.cpp).

#include <QSize>

class Brick;
class World;

// Settings as the default layout draws them, the navigation (`nav`) beside
// the page of the route's section (`host`), on screen as World::brick. A brick
// already on screen is used as it is.
Brick& settingsShell(World& world, const QSize& size = QSize(900, 300));
