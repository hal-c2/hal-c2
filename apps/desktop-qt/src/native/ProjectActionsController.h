#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QVariant>

#include <functional>
#include <optional>

#include "NativeController.h"
#include "ProjectFile.h"

class EnvironmentSettings;
class McClient;
class ShellBridge;
class ShellStore;

// The actions of the project the window shows (its route's thread or draft),
// beyond running them (WorkspaceController, TerminalController): adding,
// editing and deleting them, their shortcuts, and what the checkout's
// hal-c2.json offers. Actions are the project's `scripts`, saved with
// `projects.mutate` (project.update); a shortcut is the `script.<id>.run`
// rule of the environment's keybindings.json.
//
// Publishes `projectActions`, null away from a project:
//   {projectKey, scripts: [{id, name, command, icon, setup, shortcut}],
//    editor: {scriptId (empty for a new one), name, command, icon,
//             runOnWorktreeCreate, waitForSetup, keybinding, previewUrl,
//             autoOpenPreview, canAutoOpenPreview, error, saving} | null,
//    file: "loading" | "missing" | "invalid" | "valid",
//    imports: [{name, command, icon}]}   // hal-c2.json's, not yet the project's
//
// Actions: `projectActions.add`, `projectActions.edit {scriptId}`,
// `projectActions.set {<field>: value, ...}` (the editor's fields),
// `projectActions.save`, `projectActions.cancel`,
// `projectActions.delete {scriptId?}` (the editor's without one), which asks
// first (MenuController's confirmation), and `projectActions.import {name?}`
// (every offered one without a name).
// Palette command `projectActions.add` ("Add project action").
//
// In Settings → Project the same list is the settings scope's instead:
// with no project picked the selected
// environments' `defaultProjectScripts`, which every project without a list of
// its own offers (ProjectScripts.h), else the picked project's own list, kept
// as its `defaultProjectScripts` override on each environment with a checkout
// (an environment too old for overrides is left out). The state then also has
// {settings: true, project (one is picked), available, mixed (the
// environments' lists differ), own (the project has its own list)}, a script
// also says `preview`, and the actions are `projectActions.add {name,
// command, ...}` (added at once), `projectActions.delete {scriptId}`,
// `projectActions.reset` (a project inherits again) and
// `projectActions.import {name?}`.
//
// A project's own list is written where it is kept: its override once it has
// one, else its row's `scripts` (`projects.mutate`).
//
// It also gives a new thread's draft the project's default workspace: the
// project's or environment's `defaultThreadEnvMode` setting, else what
// hal-c2.json says, else the current checkout.
class ProjectActionsController : public QObject, public NativeController {
  Q_OBJECT

public:
  ProjectActionsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  static inline const QString kAdd = QStringLiteral("projectActions.add");

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // A new action's id: its name in lower case with dashes, numbered when taken.
  static QString nextId(const QString& name, const QSet<QString>& taken);

private:
  struct Editor {
    QString scriptId;
    QString name;
    QString command;
    QString icon = QStringLiteral("play");
    bool runOnWorktreeCreate = false;
    bool waitForSetup = false;
    QString keybinding;
    QString previewUrl;
    bool autoOpenPreview = false;
    QString error;
    bool saving = false;
  };

  void follow();
  void readFile(bool moved);
  void publish();
  void edit(const QString& scriptId);
  void set(const QVariantMap& fields);
  void save();
  void askToDelete(const QString& scriptId);
  void remove(const QString& scriptId);
  void importScripts(const QString& name);
  // Replaces the project's scripts; `done` hears why it failed, or nothing.
  void write(const QJsonArray& scripts, std::function<void(const std::optional<QString>&)> done);
  // Moves `scriptId`'s shortcut to `key`, or drops it when empty and no
  // other project of the environment has an action of that id.
  void bind(const QString& scriptId, const QString& key);
  QString shortcutOf(const QString& scriptId) const;
  QList<projectfile::Script> importable() const;
  void applyDefaultWorkspace();

  // Settings → Project: the scope's targets and their lists.
  struct Target {
    QString environmentId;
    QString projectId;  // empty for the environment's defaults
    QJsonObject settings;
  };
  QList<Target> settingsTargets() const;
  QJsonArray scriptsOn(const Target& target) const;
  bool handleSettings(const QString& action, const QVariantMap& input);
  // Applies `transform` to each target's list; undefined drops a project's own list.
  void writeSettings(const std::function<QJsonValue(QJsonArray)>& transform, const QString& failureTitle);
  QVariantMap settingsState() const;

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  EnvironmentSettings* m_settings;
  bool m_active = false;
  // The route is Settings → Project.
  bool m_settingsOpen = false;
  // The project shown: its environment, id and scripts, and its checkout.
  QString m_environment;
  QString m_project;
  QString m_cwd;
  QJsonArray m_scripts;
  std::optional<Editor> m_editor;
  // The checkout's hal-c2.json.
  QString m_fileStatus = QStringLiteral("missing");
  std::optional<projectfile::File> m_file;
  // The thread or draft the file was last read for: each one shown reads it
  // again, so an edited file is seen without a restart.
  QString m_fileFor;
  QString m_shown;
  int m_fileRequest = 0;
  // Drafts whose default workspace was decided.
  QSet<QString> m_placed;
  // Those it moved off the current checkout.
  QSet<QString> m_applied;
  QVariant m_published;
};
