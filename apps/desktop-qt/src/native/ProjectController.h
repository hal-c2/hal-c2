#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariant>

#include <optional>
#include <utility>

#include "NativeController.h"

class EnvironmentSettings;
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
// folder browses its folders, CommandPaletteController::browse; Git URL and
// the hosting providers clone, ProjectCloneController). Both browse from the
// environment's `addProjectBaseDirectory` setting, else the home folder.
//
// `project.remove {projectKey}` (`<environmentId>:<projectId>`, or a logical
// project's key for its representative) asks first: it publishes
// `projectRemoval` {projectKey, title, kind (project | checkout), count (the
// entries removed), threadCount, workspaceRoot and environment (one entry's,
// else "")} until `project.remove.confirm` deletes the projects with their
// threads and drafts or `project.remove.cancel` keeps them. Settings asks
// about several of a logical project's checkouts at once (askToRemove).
class ProjectController : public QObject, public NativeController {
  Q_OBJECT

public:
  ProjectController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  static inline const QString kAdd = QStringLiteral("project.add");

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Asks before removing the projects `keys` (`<environmentId>:<projectId>`)
  // as one `kind` ("project" or "checkout") called `title`.
  void askToRemove(const QStringList& keys, const QString& kind, const QString& title);
  // Adds the folder at `path` on `environmentId` as a project, or opens the
  // project already there.
  void addFolder(const QString& environmentId, const QString& path);
  // Where Add project browses on `environmentId` from, as a folder ("~/"
  // unless its settings name another, once they have arrived).
  QString browseStart(const QString& environmentId) const;

private:
  struct Removal {
    QStringList keys;
    QString kind;
    QString title;
  };

  void openFolder(const QString& path);
  // Opens the project's latest thread still in play, else its draft.
  void openProject(const QString& environmentId, const QString& projectId);
  void askToRemove(const QString& projectKey);
  void confirmRemoval();
  // Deletes the first of `keys`, then the rest; a failure stops there.
  void remove(QStringList keys, const QString& title);
  void publish();

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  // The settings of the environment whose sources Add project last showed.
  EnvironmentSettings* m_settings;
  bool m_active = false;
  // The projects waiting for the user's answer.
  std::optional<Removal> m_removal;
  // A project the node created whose row has not reached the shell yet; its
  // draft opens when the row does.
  std::optional<std::pair<QString, QString>> m_created;
};
