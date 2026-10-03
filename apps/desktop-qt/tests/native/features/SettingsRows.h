#pragma once
// A native settings page's rows (qml/HalC2/Bricks/SettingsPage.qml), driven
// through the controls the page draws (SettingsRowsSteps.cpp).

#include <QString>

class Brick;
class QQuickItem;
class World;

// Settings → General on screen as World::brick, tall enough to show every row.
Brick& generalPage(World& world);
// The item named `child` inside the page's item named `name` (a row is
// "settingsRow:<key>", its control "control"); fails the step when there is none.
QQuickItem* pageItem(World& world, const QString& name, const QString& child);
// Whether the page lists the row.
bool rowShown(World& world, const QString& key);
// A switch row's state: its setting, or for project grouping whether it groups.
bool settingOn(World& world, const QString& key);
// Clicks the row's switch unless it already is `on`, and waits for the setting.
void turnRow(World& world, const QString& key, bool on);
// Picks the option labelled `label` in the row's list, and waits for the setting.
void chooseRow(World& world, const QString& key, const QString& label);
// What the row's list reads.
QString rowText(World& world, const QString& key);
// The row's control is disabled, and setting it anyway writes to no environment.
void expectRowLocked(World& world, const QString& key);
