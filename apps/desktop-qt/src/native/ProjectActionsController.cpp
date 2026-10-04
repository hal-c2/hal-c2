#include "ProjectActionsController.h"

#include <QRegularExpression>

#include "DraftController.h"
#include "EnvironmentSettings.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ProjectScripts.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"
#include "WorkspaceController.h"

namespace {

const NativeControllerRegistrar<ProjectActionsController> registrar(QStringLiteral("projectActions"), {QStringLiteral("projectActions")});

// packages/contracts MAX_SCRIPT_ID_LENGTH.
constexpr int kMaxIdLength = 24;

QString text(const QJsonObject& object, const char* key) {
  return object.value(QLatin1String(key)).toString();
}

QString command(const QString& scriptId) {
  return QStringLiteral("script.%1.run").arg(scriptId);
}

QJsonObject toScript(const projectfile::Script& script, const QString& id) {
  QJsonObject object{{QStringLiteral("id"), id},
                     {QStringLiteral("name"), script.name},
                     {QStringLiteral("command"), script.command},
                     {QStringLiteral("icon"), script.icon},
                     {QStringLiteral("runOnWorktreeCreate"), script.runOnWorktreeCreate}};
  if (script.runOnWorktreeCreate && script.async == false) object.insert(QStringLiteral("async"), false);
  if (!script.previewUrl.isEmpty()) {
    object.insert(QStringLiteral("previewUrl"), script.previewUrl);
    object.insert(QStringLiteral("autoOpenPreview"), script.autoOpenPreview);
  }
  return object;
}

}  // namespace

ProjectActionsController::ProjectActionsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_settings(new EnvironmentSettings(client, this)) {}

QString ProjectActionsController::nextId(const QString& name, const QSet<QString>& taken) {
  static const QRegularExpression other(QStringLiteral("[^a-z0-9]+"));
  static const QRegularExpression edges(QStringLiteral("^-+|-+$"));
  QString base = name.trimmed().toLower().replace(other, QStringLiteral("-")).remove(edges);
  if (base.isEmpty()) base = QStringLiteral("script");
  if (base.size() > kMaxIdLength) {
    base = base.left(kMaxIdLength).remove(edges);
    if (base.isEmpty()) base = QStringLiteral("script");
  }
  if (!taken.contains(base)) return base;
  for (int suffix = 2;; ++suffix) {
    const QString tail = QLatin1Char('-') + QString::number(suffix);
    const QString candidate = base.left(std::max<qsizetype>(1, kMaxIdLength - tail.size())) + tail;
    if (!taken.contains(candidate)) return candidate;
  }
}

void ProjectActionsController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  connect(shell->controller<WorkspaceController>(), &WorkspaceController::placeChanged, this, &ProjectActionsController::follow);
  connect(m_settings, &EnvironmentSettings::changed, this, &ProjectActionsController::applyDefaultWorkspace);
  // Asking for a new thread asks again where it starts: the draft may be the
  // project's untouched one from before hal-c2.json or the setting changed.
  connect(shell->controller<DraftController>(), &DraftController::started, this, [this](const QString& draftId) {
    // One it already placed is the user's to move from then on.
    if (m_applied.contains(draftId)) return;
    m_placed.remove(draftId);
    if (m_shown == draftId) readFile(false);
    follow();
  });
  connect(shell->controller<NavigationController>(), &NavigationController::changed, this, &ProjectActionsController::follow);
  connect(shell->controller<SettingsScopeController>(), &SettingsScopeController::changed, this, [this] {
    if (m_settingsOpen) follow();
  });
  connect(m_store, &ShellStore::changed, this, [this] {
    if (m_settingsOpen) publish();
  });
  if (auto* keys = shell->controller<KeybindingController>()) {
    connect(keys, &KeybindingController::bindingsChanged, this, &ProjectActionsController::publish);
    keys->commands()->add(kAdd, tr("Add project action"), [this] { edit({}); });
    keys->commands()->setTerms(kAdd, {QStringLiteral("script"), QStringLiteral("command"), QStringLiteral("run")});
  }
  follow();
}

void ProjectActionsController::follow() {
  auto* shell = NativeShell::of(this);
  const NavigationController::Route& route = shell->controller<NavigationController>()->route();
  m_settingsOpen = route.kind == QLatin1String("settings") && route.section == QLatin1String("/settings/projects");
  if (m_settingsOpen) {
    // The picked project's hal-c2.json, from its first checkout in the scope.
    auto* scope = shell->controller<SettingsScopeController>();
    QString environment;
    QString cwd;
    if (scope->projectScope()) {
      for (const QString& candidate : scope->targets()) {
        cwd = text(m_store->projectRow(candidate, scope->projectOn(candidate)), "workspaceRoot");
        if (cwd.isEmpty()) continue;
        environment = candidate;
        break;
      }
    }
    m_editor.reset();
    m_project.clear();
    m_scripts = {};
    const QString shown = QStringLiteral("settings\n") + environment + QLatin1Char('\n') + cwd;
    if (environment != m_environment || cwd != m_cwd || shown != m_shown) {
      m_environment = environment;
      m_cwd = cwd;
      m_shown = shown;
      readFile(true);
    }
    publish();
    return;
  }
  const auto& place = shell->controller<WorkspaceController>()->place();
  const QString environment = place ? place->environmentId : QString();
  const QString project = place ? place->projectId : QString();
  if (environment != m_environment || project != m_project) {
    m_environment = environment;
    m_project = project;
    m_editor.reset();
    m_settings->setTargets(environment.isEmpty() ? QStringList() : QStringList{environment});
  }
  m_scripts = place ? place->scripts : QJsonArray();
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) keys->commands()->setEnabled(kAdd, !m_project.isEmpty());
  const QString cwd = place ? place->cwd() : QString();
  const QString shown = !place ? QString() : place->draftId.isEmpty() ? place->threadKey() : place->draftId;
  if (cwd != m_cwd || shown != m_shown) {
    const bool moved = cwd != m_cwd;
    m_cwd = cwd;
    m_shown = shown;
    readFile(moved);
  }
  applyDefaultWorkspace();
  publish();
}

// `moved`: another checkout, whose file is not known yet; the same one keeps
// what was read until the new read lands.
void ProjectActionsController::readFile(bool moved) {
  const int request = ++m_fileRequest;
  m_fileFor.clear();
  if (moved || m_cwd.isEmpty()) {
    m_file.reset();
    m_fileStatus = m_cwd.isEmpty() ? QStringLiteral("missing") : QStringLiteral("loading");
  }
  if (m_cwd.isEmpty()) return;
  const QString shown = m_shown;
  m_client->call(this, m_environment, QStringLiteral("projects.readFile"),
                 QJsonObject{{QStringLiteral("cwd"), m_cwd}, {QStringLiteral("relativePath"), projectfile::kName}},
                 [this, request, shown](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request != m_fileRequest) return;
                   const QJsonObject file = result.toObject();
                   m_fileFor = shown;
                   if (error || file.value(QLatin1String("truncated")).toBool()) {
                     m_file.reset();
                     m_fileStatus = QStringLiteral("missing");
                   } else {
                     m_file = projectfile::parse(file.value(QLatin1String("contents")).toString());
                     m_fileStatus = m_file ? QStringLiteral("valid") : QStringLiteral("invalid");
                   }
                   applyDefaultWorkspace();
                   publish();
                 });
}

// A draft the user has not placed yet starts where the project's default
// says: a saved setting first, then hal-c2.json.
void ProjectActionsController::applyDefaultWorkspace() {
  auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  const auto& place = workspace->place();
  if (!place || place->draftId.isEmpty() || m_placed.contains(place->draftId)) return;
  const std::optional<QJsonObject> settings = m_settings->settings(place->environmentId);
  if (!settings) return;
  const QString key = QStringLiteral("defaultThreadEnvMode");
  QJsonValue saved = SettingsScopeController::overrideOf(*settings, place->projectId, key);
  if (!saved.isString()) saved = settings->value(key);
  QString mode = saved.toString();
  if (mode.isEmpty()) {
    // The file decides, once it has been read.
    if (m_fileFor != place->draftId) return;
    if (m_file) mode = m_file->defaultThreadEnvMode;
  }
  const QString draftId = place->draftId;
  m_placed.insert(draftId);
  WorkspaceController::Checkout checkout = workspace->checkout(draftId);
  const WorkspaceController::Checkout untouched;
  const bool placed = checkout.envMode != untouched.envMode || checkout.branch || checkout.worktreePath || !checkout.environmentId.isEmpty();
  if (placed || mode.isEmpty() || mode == checkout.envMode) return;
  checkout.envMode = mode;
  m_applied.insert(draftId);
  workspace->setCheckout(draftId, checkout);
}

QString ProjectActionsController::shortcutOf(const QString& scriptId) const {
  const auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  if (!keys) return {};
  const QList<keybindings::Binding>& bindings = keys->resolved();
  for (auto it = bindings.crbegin(); it != bindings.crend(); ++it) {
    if (it->command == command(scriptId)) return keybindings::keyText(it->shortcut);
  }
  return {};
}

QList<projectfile::Script> ProjectActionsController::importable() const {
  QList<projectfile::Script> offered;
  if (!m_file) return offered;
  // In settings, against the first selected environment's list.
  QJsonArray listed = m_scripts;
  if (m_settingsOpen) {
    const QList<Target> targets = settingsTargets();
    listed = targets.isEmpty() ? QJsonArray() : scriptsOn(targets.first());
  }
  for (const projectfile::Script& candidate : m_file->scripts) {
    bool have = false;
    for (const QJsonValue& value : listed) {
      const QJsonObject script = value.toObject();
      have = have || text(script, "command") == candidate.command || text(script, "name").compare(candidate.name, Qt::CaseInsensitive) == 0;
    }
    if (!have) offered.append(candidate);
  }
  return offered;
}

void ProjectActionsController::publish() {
  QVariant state;
  if (m_settingsOpen) {
    state = settingsState();
  } else if (!m_project.isEmpty()) {
    const auto* keys = NativeShell::of(this)->controller<KeybindingController>();
    QVariantList scripts;
    for (const QJsonValue& value : m_scripts) {
      const QJsonObject script = value.toObject();
      const QString key = shortcutOf(text(script, "id"));
      scripts.append(QVariantMap{{QStringLiteral("id"), text(script, "id")},
                                 {QStringLiteral("name"), text(script, "name")},
                                 {QStringLiteral("command"), text(script, "command")},
                                 {QStringLiteral("icon"), text(script, "icon")},
                                 {QStringLiteral("setup"), script.value(QLatin1String("runOnWorktreeCreate")).toBool()},
                                 {QStringLiteral("shortcut"), key.isEmpty() || !keys ? QString() : keys->keyLabel(key)}});
    }
    QVariantList imports;
    for (const projectfile::Script& script : importable()) {
      imports.append(QVariantMap{{QStringLiteral("name"), script.name}, {QStringLiteral("command"), script.command}, {QStringLiteral("icon"), script.icon}});
    }
    QVariant editor;
    if (m_editor) {
      editor = QVariantMap{{QStringLiteral("scriptId"), m_editor->scriptId},
                           {QStringLiteral("name"), m_editor->name},
                           {QStringLiteral("command"), m_editor->command},
                           {QStringLiteral("icon"), m_editor->icon},
                           {QStringLiteral("runOnWorktreeCreate"), m_editor->runOnWorktreeCreate},
                           {QStringLiteral("waitForSetup"), m_editor->waitForSetup},
                           {QStringLiteral("keybinding"), m_editor->keybinding},
                           {QStringLiteral("previewUrl"), m_editor->previewUrl},
                           {QStringLiteral("autoOpenPreview"), m_editor->autoOpenPreview},
                           {QStringLiteral("canAutoOpenPreview"), !m_editor->previewUrl.trimmed().isEmpty()},
                           {QStringLiteral("error"), m_editor->error},
                           {QStringLiteral("saving"), m_editor->saving}};
    }
    state = QVariantMap{{QStringLiteral("projectKey"), m_environment + QLatin1Char(':') + m_project},
                        {QStringLiteral("scripts"), scripts},
                        {QStringLiteral("editor"), editor},
                        {QStringLiteral("file"), m_fileStatus},
                        {QStringLiteral("imports"), imports}};
  }
  if (state == m_published) return;
  m_published = state;
  m_bridge->publish(QStringLiteral("projectActions"), state);
}

bool ProjectActionsController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("projectActions."))) return false;
  if (m_active && m_settingsOpen) return handleSettings(action, payload.toMap());
  if (!m_active || m_project.isEmpty()) return true;
  const QVariantMap map = payload.toMap();
  if (action == kAdd) {
    edit({});
  } else if (action == QLatin1String("projectActions.edit")) {
    edit(map.value(QStringLiteral("scriptId")).toString());
  } else if (action == QLatin1String("projectActions.set")) {
    set(map);
  } else if (action == QLatin1String("projectActions.save")) {
    save();
  } else if (action == QLatin1String("projectActions.cancel")) {
    m_editor.reset();
    publish();
  } else if (action == QLatin1String("projectActions.delete")) {
    const QString scriptId = map.value(QStringLiteral("scriptId")).toString();
    askToDelete(scriptId.isEmpty() && m_editor ? m_editor->scriptId : scriptId);
  } else if (action == QLatin1String("projectActions.import")) {
    importScripts(map.value(QStringLiteral("name")).toString());
  } else {
    return false;
  }
  return true;
}

void ProjectActionsController::edit(const QString& scriptId) {
  Editor editor;
  if (!scriptId.isEmpty()) {
    bool found = false;
    for (const QJsonValue& value : m_scripts) {
      const QJsonObject script = value.toObject();
      if (text(script, "id") != scriptId) continue;
      found = true;
      editor.scriptId = scriptId;
      editor.name = text(script, "name");
      editor.command = text(script, "command");
      editor.icon = text(script, "icon");
      editor.runOnWorktreeCreate = script.value(QLatin1String("runOnWorktreeCreate")).toBool();
      editor.waitForSetup = editor.runOnWorktreeCreate && script.value(QLatin1String("async")) == QJsonValue(false);
      editor.keybinding = shortcutOf(scriptId);
      editor.previewUrl = text(script, "previewUrl");
      editor.autoOpenPreview = script.value(QLatin1String("autoOpenPreview")).toBool();
    }
    if (!found) return;
  }
  m_editor = editor;
  publish();
}

void ProjectActionsController::set(const QVariantMap& fields) {
  if (!m_editor || m_editor->saving) return;
  const auto has = [&fields](const char* key) { return fields.contains(QLatin1String(key)); };
  const auto value = [&fields](const char* key) { return fields.value(QLatin1String(key)); };
  if (has("name")) m_editor->name = value("name").toString();
  if (has("command")) m_editor->command = value("command").toString();
  if (has("icon") && projectfile::icons().contains(value("icon").toString())) m_editor->icon = value("icon").toString();
  if (has("runOnWorktreeCreate")) m_editor->runOnWorktreeCreate = value("runOnWorktreeCreate").toBool();
  if (has("waitForSetup")) m_editor->waitForSetup = value("waitForSetup").toBool();
  if (has("keybinding")) m_editor->keybinding = value("keybinding").toString();
  if (has("previewUrl")) m_editor->previewUrl = value("previewUrl").toString();
  // Opening the preview needs an address to open.
  if (has("autoOpenPreview")) m_editor->autoOpenPreview = value("autoOpenPreview").toBool();
  if (m_editor->previewUrl.trimmed().isEmpty()) m_editor->autoOpenPreview = false;
  if (!m_editor->runOnWorktreeCreate) m_editor->waitForSetup = false;
  m_editor->error.clear();
  publish();
}

void ProjectActionsController::save() {
  if (!m_editor || m_editor->saving) return;
  const QString name = m_editor->name.trimmed();
  const QString commandLine = m_editor->command.trimmed();
  const QString key = m_editor->keybinding.trimmed();
  if (name.isEmpty()) {
    m_editor->error = tr("Name is required.");
  } else if (commandLine.isEmpty()) {
    m_editor->error = tr("Command is required.");
  } else if (!key.isEmpty() && !keybindings::parseShortcut(key)) {
    m_editor->error = tr("Invalid keybinding.");
  }
  if (!m_editor->error.isEmpty()) {
    publish();
    return;
  }
  QString id = m_editor->scriptId;
  const bool added = id.isEmpty();
  if (added) {
    // Ids are an environment's: a shortcut names the action by its id alone.
    QSet<QString> taken;
    for (const QJsonObject& project : m_store->projectRows(m_environment)) {
      for (const QJsonValue& value : project.value(QLatin1String("scripts")).toArray()) taken.insert(text(value.toObject(), "id"));
    }
    id = nextId(name, taken);
  }
  QJsonObject next{{QStringLiteral("id"), id},
                   {QStringLiteral("name"), name},
                   {QStringLiteral("command"), commandLine},
                   {QStringLiteral("icon"), m_editor->icon},
                   {QStringLiteral("runOnWorktreeCreate"), m_editor->runOnWorktreeCreate}};
  if (m_editor->runOnWorktreeCreate && m_editor->waitForSetup) next.insert(QStringLiteral("async"), false);
  if (const QString preview = m_editor->previewUrl.trimmed(); !preview.isEmpty()) {
    next.insert(QStringLiteral("previewUrl"), preview);
    next.insert(QStringLiteral("autoOpenPreview"), m_editor->autoOpenPreview);
  }
  QJsonArray scripts;
  for (const QJsonValue& value : m_scripts) {
    QJsonObject script = value.toObject();
    if (text(script, "id") == id) {
      script = next;
    } else if (m_editor->runOnWorktreeCreate) {
      // One setup script: the others stop running on worktree creation.
      script.insert(QStringLiteral("runOnWorktreeCreate"), false);
    }
    scripts.append(script);
  }
  if (added) scripts.append(next);
  m_editor->saving = true;
  publish();
  write(scripts, [this, id, key](const std::optional<QString>& error) {
    if (!m_editor) return;
    m_editor->saving = false;
    if (error) {
      m_editor->error = error->isEmpty() ? tr("Failed to save action.") : *error;
      publish();
      return;
    }
    m_editor.reset();
    bind(id, key);
    publish();
  });
}

void ProjectActionsController::askToDelete(const QString& scriptId) {
  QString name;
  for (const QJsonValue& value : m_scripts) {
    if (text(value.toObject(), "id") == scriptId) name = text(value.toObject(), "name");
  }
  if (scriptId.isEmpty() || name.isEmpty()) return;
  const QString project = m_environment + QLatin1Char(':') + m_project;
  NativeShell::of(this)->controller<MenuController>()->confirm(
      tr("Delete action \"%1\"?").arg(name), tr("This action cannot be undone."), tr("Delete action"), true,
      [this, scriptId, project] {
        // Still the project the question was about.
        if (project == m_environment + QLatin1Char(':') + m_project) remove(scriptId);
      });
}

void ProjectActionsController::remove(const QString& id) {
  QJsonArray scripts;
  for (const QJsonValue& value : m_scripts) {
    if (text(value.toObject(), "id") != id) scripts.append(value);
  }
  if (scripts.size() == m_scripts.size()) return;
  write(scripts, [this, id](const std::optional<QString>& error) {
    if (error) {
      NativeShell::of(this)->controller<ToastController>()->error(tr("Failed to save project actions"), *error);
      return;
    }
    if (m_editor && m_editor->scriptId == id) m_editor.reset();
    bind(id, {});
    publish();
  });
}

void ProjectActionsController::importScripts(const QString& name) {
  QJsonArray scripts = m_scripts;
  QSet<QString> taken;
  for (const QJsonObject& project : m_store->projectRows(m_environment)) {
    for (const QJsonValue& value : project.value(QLatin1String("scripts")).toArray()) taken.insert(text(value.toObject(), "id"));
  }
  bool setup = false;
  for (const QJsonValue& value : scripts) setup = setup || value.toObject().value(QLatin1String("runOnWorktreeCreate")).toBool();
  for (projectfile::Script script : importable()) {
    if (!name.isEmpty() && script.name != name) continue;
    // The project keeps the setup script it has.
    if (setup) script.runOnWorktreeCreate = false;
    setup = setup || script.runOnWorktreeCreate;
    const QString id = nextId(script.name, taken);
    taken.insert(id);
    scripts.append(toScript(script, id));
  }
  if (scripts.size() == m_scripts.size()) return;
  write(scripts, [this](const std::optional<QString>& error) {
    if (error) NativeShell::of(this)->controller<ToastController>()->error(tr("Failed to import action."), *error);
  });
}

void ProjectActionsController::write(const QJsonArray& scripts, std::function<void(const std::optional<QString>&)> done) {
  // A project whose list Settings made its override keeps it there.
  const std::optional<QJsonObject> settings = m_settings->settings(m_environment);
  if (settings && projectScripts::overrideOf(*settings, m_project).isArray()) {
    const QString environment = m_environment;
    const QString project = m_project;
    m_settings->change(
        [environment, project, scripts](QJsonObject document, const QString& environmentId) {
          if (environmentId != environment) return document;
          return SettingsScopeController::withOverride(document, project, QStringLiteral("defaultProjectScripts"), scripts);
        },
        [environment, done = std::move(done)](const QHash<QString, QString>& failed, int) {
          done(failed.contains(environment) ? std::optional<QString>(failed.value(environment)) : std::nullopt);
        });
    return;
  }
  m_client->call(this, m_environment, QStringLiteral("projects.mutate"),
                 QJsonObject{{QStringLiteral("type"), QStringLiteral("project.update")}, {QStringLiteral("projectId"), m_project}, {QStringLiteral("scripts"), scripts}},
                 [done = std::move(done)](const QJsonValue&, const std::optional<QString>& error) { done(error); });
}

void ProjectActionsController::bind(const QString& scriptId, const QString& key) {
  const QString previous = shortcutOf(scriptId);
  if (key == previous) return;
  const QString environment = m_environment;
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  const auto told = [toasts](const QJsonValue&, const std::optional<QString>& error) {
    if (error) toasts->error(tr("Failed to save project actions"), *error);
  };
  if (!key.isEmpty()) {
    QJsonObject rule{{QStringLiteral("key"), key}, {QStringLiteral("command"), command(scriptId)}};
    if (!previous.isEmpty()) rule.insert(QStringLiteral("replace"), QJsonObject{{QStringLiteral("key"), previous}, {QStringLiteral("command"), command(scriptId)}});
    m_client->call(this, environment, QStringLiteral("hal-c2.upsertKeybinding"), rule, told);
    return;
  }
  // Another project's action of the same id still runs from it.
  for (const QJsonObject& project : m_store->projectRows(environment)) {
    if (text(project, "id") == m_project) continue;
    for (const QJsonValue& value : project.value(QLatin1String("scripts")).toArray()) {
      if (text(value.toObject(), "id") == scriptId) return;
    }
  }
  m_client->call(this, environment, QStringLiteral("hal-c2.removeKeybinding"),
                 QJsonObject{{QStringLiteral("key"), previous}, {QStringLiteral("command"), command(scriptId)}}, told);
}

// --- Settings → Project ---------------------------------------------------------------

QList<ProjectActionsController::Target> ProjectActionsController::settingsTargets() const {
  auto* scope = NativeShell::of(this)->controller<SettingsScopeController>();
  QList<Target> result;
  const bool project = scope->projectScope();
  // At project scope only the environments whose server keeps project overrides.
  const QStringList old = project ? scope->lacking(QStringLiteral("projectSettingsOverrides")) : QStringList();
  for (const QString& environmentId : scope->targets()) {
    const auto settings = scope->settings(environmentId);
    if (!settings || old.contains(environmentId)) continue;
    result.append({environmentId, project ? scope->projectOn(environmentId) : QString(), *settings});
  }
  return result;
}

QJsonArray ProjectActionsController::scriptsOn(const Target& target) const {
  if (target.projectId.isEmpty()) return target.settings.value(QLatin1String("defaultProjectScripts")).toArray();
  return projectScripts::resolve(target.settings, target.projectId,
                                 m_store->projectRow(target.environmentId, target.projectId).value(QLatin1String("scripts")).toArray());
}

bool ProjectActionsController::handleSettings(const QString& action, const QVariantMap& input) {
  auto* scope = NativeShell::of(this)->controller<SettingsScopeController>();
  const auto taken = [this] {
    QSet<QString> ids;
    for (const Target& target : settingsTargets()) {
      for (const QJsonValue& script : scriptsOn(target)) ids.insert(text(script.toObject(), "id"));
      for (const QJsonValue& script : target.settings.value(QLatin1String("defaultProjectScripts")).toArray()) ids.insert(text(script.toObject(), "id"));
    }
    return ids;
  };
  // One action is the setup script.
  const auto appended = [](QJsonArray scripts, const QJsonObject& script) {
    if (script.value(QLatin1String("runOnWorktreeCreate")).toBool()) {
      for (qsizetype i = 0; i < scripts.size(); ++i) {
        QJsonObject other = scripts.at(i).toObject();
        other.insert(QStringLiteral("runOnWorktreeCreate"), false);
        scripts.replace(i, other);
      }
    }
    scripts.append(script);
    return scripts;
  };
  if (action == kAdd) {
    projectfile::Script script;
    script.name = input.value(QStringLiteral("name")).toString().trimmed();
    script.command = input.value(QStringLiteral("command")).toString().trimmed();
    if (script.name.isEmpty() || script.command.isEmpty()) return true;
    if (projectfile::icons().contains(input.value(QStringLiteral("icon")).toString())) script.icon = input.value(QStringLiteral("icon")).toString();
    script.runOnWorktreeCreate = input.value(QStringLiteral("runOnWorktreeCreate")).toBool();
    script.previewUrl = input.value(QStringLiteral("previewUrl")).toString().trimmed();
    script.autoOpenPreview = input.value(QStringLiteral("autoOpenPreview")).toBool();
    const QJsonObject next = toScript(script, nextId(script.name, taken()));
    writeSettings([next, appended](QJsonArray scripts) { return QJsonValue(appended(scripts, next)); }, tr("Failed to save project actions"));
  } else if (action == QLatin1String("projectActions.delete")) {
    const QString id = input.value(QStringLiteral("scriptId")).toString();
    if (id.isEmpty()) return true;
    writeSettings([id](QJsonArray scripts) {
      for (qsizetype i = scripts.size() - 1; i >= 0; --i) {
        if (text(scripts.at(i).toObject(), "id") == id) scripts.removeAt(i);
      }
      return QJsonValue(scripts);
    }, tr("Failed to save project actions"));
  } else if (action == QLatin1String("projectActions.reset")) {
    // No list of its own: the environment's defaults again.
    if (scope->projectScope()) writeSettings([](QJsonArray) { return QJsonValue(QJsonValue::Undefined); }, tr("Failed to save project actions"));
  } else if (action == QLatin1String("projectActions.import")) {
    const QString name = input.value(QStringLiteral("name")).toString();
    QSet<QString> ids = taken();
    QList<QJsonObject> added;
    for (const projectfile::Script& script : importable()) {
      if (!name.isEmpty() && script.name != name) continue;
      const QString id = nextId(script.name, ids);
      ids.insert(id);
      added.append(toScript(script, id));
    }
    if (added.isEmpty()) return true;
    writeSettings([added, appended](QJsonArray scripts) {
      for (const QJsonObject& script : added) scripts = appended(scripts, script);
      return QJsonValue(scripts);
    }, tr("Failed to import action."));
  }
  return true;
}

void ProjectActionsController::writeSettings(const std::function<QJsonValue(QJsonArray)>& transform, const QString& failureTitle) {
  auto* scope = NativeShell::of(this)->controller<SettingsScopeController>();
  const QList<Target> targets = settingsTargets();
  if (targets.isEmpty()) {
    NativeShell::of(this)->controller<ToastController>()->error(tr("Actions not saved"), tr("No available machine, or another action change is saving."));
    return;
  }
  // What each project's list is now, by its id on its environment.
  QHash<QString, QJsonArray> current;
  for (const Target& target : targets) current.insert(target.projectId, scriptsOn(target));
  const bool project = scope->projectScope();
  const QString key = QStringLiteral("defaultProjectScripts");
  scope->write(
      [transform, current, project, key](QJsonObject settings, const QString& projectId) {
        if (project) {
          // An environment left out (too old for overrides) is not written to.
          if (!current.contains(projectId)) return settings;
          return SettingsScopeController::withOverride(settings, projectId, key, transform(current.value(projectId)));
        }
        const QJsonValue next = transform(settings.value(key).toArray());
        settings.insert(key, next.isArray() ? next : QJsonValue(QJsonArray()));
        return settings;
      },
      failureTitle);
}

QVariantMap ProjectActionsController::settingsState() const {
  auto* scope = NativeShell::of(this)->controller<SettingsScopeController>();
  const auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  const QList<Target> targets = settingsTargets();
  const QJsonArray listed = targets.isEmpty() ? QJsonArray() : scriptsOn(targets.first());
  const bool project = scope->projectScope();
  bool mixed = false;
  bool own = false;
  for (const Target& target : targets) {
    mixed = mixed || scriptsOn(target) != listed;
    own = own || (project && !projectScripts::inherits(target.settings, target.projectId,
                                                       m_store->projectRow(target.environmentId, target.projectId).value(QLatin1String("scripts")).toArray()));
  }
  QVariantList scripts;
  for (const QJsonValue& value : listed) {
    const QJsonObject script = value.toObject();
    const QString key = shortcutOf(text(script, "id"));
    scripts.append(QVariantMap{{QStringLiteral("id"), text(script, "id")},
                               {QStringLiteral("name"), text(script, "name")},
                               {QStringLiteral("command"), text(script, "command")},
                               {QStringLiteral("icon"), text(script, "icon")},
                               {QStringLiteral("setup"), script.value(QLatin1String("runOnWorktreeCreate")).toBool()},
                               {QStringLiteral("preview"), !text(script, "previewUrl").isEmpty()},
                               {QStringLiteral("shortcut"), key.isEmpty() || !keys ? QString() : keys->keyLabel(key)}});
  }
  QVariantList imports;
  for (const projectfile::Script& script : importable()) {
    imports.append(QVariantMap{{QStringLiteral("name"), script.name}, {QStringLiteral("command"), script.command}, {QStringLiteral("icon"), script.icon}});
  }
  return {{QStringLiteral("settings"), true},
          {QStringLiteral("projectKey"), scope->projectKey()},
          {QStringLiteral("project"), project},
          {QStringLiteral("available"), !targets.isEmpty()},
          {QStringLiteral("scripts"), scripts},
          {QStringLiteral("mixed"), mixed},
          {QStringLiteral("own"), own},
          {QStringLiteral("editor"), QVariant()},
          {QStringLiteral("file"), m_fileStatus},
          {QStringLiteral("imports"), imports}};
}
