#pragma once
// The Files tab of the thread the scenario looks at, for the files steps
// (FilesExplorerSteps.cpp, FilesViewerSteps.cpp): the tab's tree and viewer,
// the environment's editors, and what the MC was asked to open.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "FakeFiles.h"
#include "FileTreeModel.h"
#include "Harness.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "WorkspaceFiles.h"
#include "World.h"

namespace filesteps {

inline RightPanelController* panel(World& world) {
  return world.native().controller<RightPanelController>();
}

inline WorkspaceFiles& files(World& world) {
  return *panel(world)->files();
}

inline FileTreeModel& tree(World& world) {
  return *files(world).tree();
}

inline QString describeTree(World& world) {
  return QStringLiteral("the tree (%1) shows [%2]").arg(tree(world).rootStatus(), tree(world).visiblePaths().join(QStringLiteral(", ")));
}

inline bool treeSettled(World& world) {
  if (files(world).searching()) return false;
  FileTreeModel& model = tree(world);
  if (model.rootStatus() == QLatin1String("loading")) return false;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (model.data(model.index(row), FileTreeModel::KindRole).toString() == QLatin1String("loading")) return false;
  }
  return true;
}

inline void waitForTree(World& world) {
  world.waitFor([&] { return treeSettled(world); }, [&] { return QStringLiteral("the tree to settle; %1").arg(describeTree(world)); });
}

// The Files tab, shown.
inline void openFilesTab(World& world) {
  if (!panel(world)->isOpen() || panel(world)->activeTab() != QLatin1String("files")) {
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("files")}});
  }
  waitForTree(world);
}

inline void openFile(World& world, const QString& path) {
  world.bridge().dispatch(QStringLiteral("files.open"), QVariantMap{{QStringLiteral("path"), path}});
  world.waitFor([&] { return files(world).openPath() == path && files(world).fileStatus() != QLatin1String("loading"); },
                [&] { return QStringLiteral("%1 to load; the viewer has \"%2\" (%3)").arg(path, files(world).openPath(), files(world).fileStatus()); });
}

// The MC's config with `fields` changed, announced as it announces a change.
inline void setConfig(World& world, const QJsonObject& fields) {
  FakeConfig& fake = fakeConfig(world.mc);
  for (auto it = fields.begin(); it != fields.end(); ++it) fake.config.insert(it.key(), it.value());
  QJsonObject config = fake.config;
  config.insert(QStringLiteral("settings"), fake.settings);
  for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), config}});
  }
  world.sync();
}

// packages/contracts EDITORS: the id of the editor the scenario names.
inline QString editorId(const QString& label) {
  static const QHash<QString, QString> ids{{QStringLiteral("VS Code"), QStringLiteral("vscode")},
                                           {QStringLiteral("Zed"), QStringLiteral("zed")},
                                           {QStringLiteral("Cursor"), QStringLiteral("cursor")}};
  if (!ids.contains(label)) fail(QStringLiteral("%1 is not an editor these steps know").arg(label));
  return ids.value(label);
}

// Every `shell.openInEditor` the MC was asked.
inline QList<QJsonObject> editorCalls(World& world) {
  world.sync();
  QList<QJsonObject> calls;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("shell.openInEditor")) calls.append(rpc.payload);
  }
  return calls;
}

// The folder of the thread's workspace on its environment.
inline QString workspaceRoot(World& world) {
  return files(world).root();
}

}  // namespace filesteps
