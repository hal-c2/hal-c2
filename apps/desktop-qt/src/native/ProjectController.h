#pragma once

#include <QObject>
#include <QString>
#include <QVariant>

#include <optional>
#include <utility>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// Adding and removing projects on the node the shell runs against, through
// `projects.mutate`.
//
// `project.add {path}` and `project.folder.open {path}` (the sidebar's folder
// picker, a dropped folder, the folder explorer) open a local folder as a
// project: one already registered opens its latest thread (or its draft), a
// new one is created and opens a draft. A pathless `project.add` runs the
// palette's Add project menu (registered here as `project.add`): the online
// environment to add on when there are several, then its sources (Local
// folder browses its folders, CommandPaletteController::browse).
//
// `project.remove {projectKey}` (`<environmentId>:<projectId>`, or a logical
// project's key for its representative) asks first: it publishes
// `projectRemoval` {projectKey, title, threadCount, workspaceRoot} until
// `project.remove.confirm` deletes the project with its threads and drafts or
// `project.remove.cancel` keeps it.
class ProjectController : public QObject, public NativeController {
  Q_OBJECT

public:
  ProjectController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  static inline const QString kAdd = QStringLiteral("project.add");

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Adds the folder at `path` on `environmentId` as a project, or opens the
  // project already there.
  void addFolder(const QString& environmentId, const QString& path);

private:
  void openFolder(const QString& path);
  // Opens the project's latest thread still in play, else its draft.
  void openProject(const QString& environmentId, const QString& projectId);
  void askToRemove(const QString& projectKey);
  void confirmRemoval();
  void publish();

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  // The `<environmentId>:<projectId>` waiting for the user's answer.
  std::optional<QString> m_removal;
  // A project the node created whose row has not reached the shell yet; its
  // draft opens when the row does.
  std::optional<std::pair<QString, QString>> m_created;
};
