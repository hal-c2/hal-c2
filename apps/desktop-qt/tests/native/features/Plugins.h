#pragma once
// What PluginSteps.cpp (UI plugins) and McPluginSteps.cpp (MC plugins) need
// from each other: the window both draw in, and the plugin list's switches,
// whose steps both files' scenarios share the words of.

#include <QString>

class QQuickItem;
class QQuickWindow;
class World;

// PluginSteps.cpp: the desktop's own window, drawn by DefaultShell, connected.
QQuickWindow* pluginShell(World& world);
// The item named `objectName` under `root`, or null.
QQuickItem* findNamed(QQuickItem* root, const QString& objectName);
// Clicks `target` in the window, as the user does.
void clickItem(World& world, QQuickItem* target);
// Settings → Plugins, open in the window.
QQuickItem* showPluginList(World& world);
// Whether `item`, or a visible item under it, draws `text`.
bool drawsText(const QQuickItem* item, const QString& text);
// Answers the confirmation the shell asks.
void answerQuestion(World& world, bool accepted);

// McPluginSteps.cpp: whether the scenario's MC runs a plugin `id`, and
// flipping its switch in the plugin list ("the user enables/disables").
bool isMcPlugin(World& world, const QString& id);
void switchMcPlugin(World& world, const QString& id);
