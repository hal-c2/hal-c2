#pragma once
// What PluginSteps.cpp (UI plugins) and McPluginSteps.cpp (MC plugins) need
// from each other: the window both draw in, and the plugin list's switches,
// whose steps both files' scenarios share the words of.

#include <QHash>
#include <QJsonValue>
#include <QString>

#include <functional>

#include "FakeMc.h"

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

// A plugin whose MC part a scenario fakes itself and whose package is a real
// one: the package's directory, which `plugins.file` reads, what each of its
// topics holds, and how it answers `plugins.call`.
struct FakePluginPart {
  QString package;
  QHash<QString, QJsonValue> topics;
  std::function<void(const FakeMc::Rpc& rpc)> call;
};
// McPluginSteps.cpp: the scenario's MC runs the plugin `entry` (as `plugins`
// lists it) with `part` as its MC part, and the client lists it running.
void runFakePlugin(World& world, const QJsonObject& entry, const FakePluginPart& part);
FakePluginPart& fakePluginPart(World& world, const QString& id);
// Sends what the plugin's topic holds now to each client watching it.
void publishTopic(World& world, const QString& id, const QString& topic);
// The shown item named `objectName` in the window, once it is (and `ready`).
QQuickItem* waitShownNamed(World& world, const QString& objectName, const std::function<bool(QQuickItem*)>& ready = {});
// The user clicks the tab `title` in the window's strip.
void switchToTab(World& world, const QString& title);
// A thread the plugin started (`plugin` is its {id, kind, listed}), in the shell.
void addPluginThread(World& world, const QString& id, const QString& title, const QJsonObject& plugin);
void openPluginThread(World& world, const QString& id);
