#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QString>

#include <optional>

#include "CommandRegistry.h"
#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// Cloning a repository into a new project, as the web's Add project and its
// ProjectCloneToastCoordinator do.
//
// Add project's sources (ProjectController) list "Git URL" and each hosting
// provider's repository, ready ones first; whether a provider is ready comes
// from `server.discoverSourceControl`, and one that is not ("Setup Required")
// opens the Source Control settings instead. Choosing a ready source asks for
// the repository in the palette (a provider's is looked up,
// `sourceControl.lookupRepository`), then browses for where it goes with the
// repository's folder name pinned to the path, in the folder Add project
// browses from (ProjectController::browseStart). Enter there starts the clone
// (`projectClone.start`): the MC adds the project at once and clones in the
// background, and the new project's draft opens.
//
// Every clone the MC reports (the `projectClones` shape of each online
// environment of the cluster) has one toast, changed in place as
// git moves on: running (Cancel), done (Open project), failed or cancelled
// (Retry, Remove project).
class ProjectCloneController : public QObject, public NativeController {
  Q_OBJECT

public:
  ProjectCloneController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString&, const QVariant&) override { return false; }

  // Add project's clone sources on `environmentId`, after Local folder.
  QList<CommandRegistry::Choice> sources(const QString& environmentId);

private:
  // Where a clone comes from: "url" or a provider kind (github, gitlab, ...).
  struct Source {
    QString kind;
    QString label;
    QString hint;
  };
  struct Readiness {
    bool ready = false;
    QString hint;
  };
  // What the user chose to clone, once its address is known.
  struct Chosen {
    QString environmentId;
    QString remoteUrl;
    QString directoryName;
  };
  struct Discovery {
    std::optional<QJsonObject> result;
    bool asking = false;
  };
  // A clone's toast and what it last showed.
  struct Tracked {
    QString toastId;
    QString shown;
    QString phase;
  };

  Readiness readiness(const QString& environmentId, const QString& kind) const;
  void discover(const QString& environmentId);
  void askRepository(const QString& environmentId, const Source& source);
  void submitRepository(const QString& environmentId, const Source& source, const QString& input);
  void askDestination(const Chosen& chosen);
  void start(const Chosen& chosen, const QString& destination);
  // False, with the web's "Environment unavailable", when it is not connected.
  bool connected(const QString& environmentId);
  void openProject(const QString& environmentId, const QString& projectId);
  void follow();
  void reconcile(const QString& environmentId, const QJsonArray& clones);
  void cloneAction(const QString& environmentId, const QString& method, const QString& projectId,
                   const QString& failure);
  void removeProject(const QString& environmentId, const QString& projectId);

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  QHash<QString, Discovery> m_discovery;
  // A lookup or a start on its way, which Enter does not repeat.
  bool m_busy = false;
  int m_lookup = 0;
  // A project whose clone started and whose row has not reached the shell
  // yet; its draft opens when the row does.
  std::optional<std::pair<QString, QString>> m_started;
  // The `projectClones` subscription of each online environment.
  QHash<QString, int> m_subscriptions;
  // Toasts by environment, then project id.
  QHash<QString, QHash<QString, Tracked>> m_toasts;
};
