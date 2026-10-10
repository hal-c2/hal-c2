#include "ProjectController.h"

#include <QFileInfo>
#include <QJsonObject>
#include <QRegularExpression>
#include <QUuid>

#include "CommandPaletteController.h"
#include "DraftController.h"
#include "EnvironmentSettings.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "ProjectCloneController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ProjectController> registrar(QStringLiteral("projects"),
                                                             {QStringLiteral("projectRemoval")});

// A folder ends in its separator, a backslash for a Windows path.
QString asFolder(const QString& path) {
  const QString trimmed = path.trimmed();
  if (trimmed.isEmpty() || trimmed.endsWith(QLatin1Char('/'))) return trimmed;
  static const QRegularExpression windowsPath(QStringLiteral(R"(^(?:[A-Za-z]:[\\/]|\\\\))"));
  const bool posix = trimmed.startsWith(QLatin1Char('/')) || trimmed.startsWith(QLatin1Char('~'));
  const bool windows = windowsPath.match(trimmed).hasMatch() || (!posix && trimmed.contains(QLatin1Char('\\')));
  if (windows && trimmed.endsWith(QLatin1Char('\\'))) return trimmed;
  return trimmed + (windows ? QLatin1Char('\\') : QLatin1Char('/'));
}

}  // namespace

ProjectController::ProjectController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_settings(new EnvironmentSettings(client, this)) {
  // A removal asked about a project that went away meanwhile has nothing to ask.
  connect(store, &ShellStore::changed, this, [this] {
    if (m_removal) {
      m_removal->keys.removeIf([this](const QString& key) { return !m_store->project(key); });
      if (m_removal->keys.isEmpty()) m_removal.reset();
      // Its threads may have changed too.
      publish();
    }
    if (m_created && m_store->project(m_created->first + QLatin1Char(':') + m_created->second)) {
      const auto [environmentId, projectId] = *std::exchange(m_created, std::nullopt);
      NativeShell::of(this)->controller<DraftController>()->start(environmentId, projectId);
    }
  });
}

void ProjectController::activate() {
  if (m_active) return;
  m_active = true;
  auto* commands = NativeShell::of(this)->controller<KeybindingController>()->commands();
  // Add project: an environment first when there is a choice, then
  // how to add: a local folder, or a clone (ProjectCloneController).
  const auto sources = [this](const QString& environmentId) {
    // Its settings say where browsing starts, by the time a source is chosen.
    m_settings->setTargets({environmentId});
    CommandRegistry::Choice folder{QStringLiteral("local-folder"), tr("Local folder"), tr("Browse a folder on disk")};
    folder.terms = {QStringLiteral("folder"), QStringLiteral("directory"), QStringLiteral("browse")};
    folder.keepOpen = true;
    folder.run = [this, environmentId] {
      CommandPaletteController::BrowseOptions options;
      options.query = browseStart(environmentId);
      NativeShell::of(this)->controller<CommandPaletteController>()->browse(
          environmentId,
          [this, environmentId](const QString& path) { addFolder(environmentId, path, QStringLiteral("Failed to add project")); },
          options);
    };
    return QList<CommandRegistry::Choice>{folder} +
           NativeShell::of(this)->controller<ProjectCloneController>()->sources(environmentId);
  };
  commands->addMenu(kAdd, tr("Add project"), [this, sources] {
    QStringList online;
    for (const QString& environmentId : m_store->environments()) {
      if (m_store->environmentOnline(environmentId)) online.append(environmentId);
    }
    if (online.size() == 1) return sources(online.constFirst());
    const QString own = m_store->environmentOf(m_client->mc());
    QList<CommandRegistry::Choice> environments;
    for (const QString& environmentId : m_store->environments()) {
      const QJsonObject descriptor = m_store->environment(environmentId);
      CommandRegistry::Choice choice{environmentId, descriptor.value(QLatin1String("label")).toString(environmentId)};
      const bool connected = online.contains(environmentId);
      choice.description = !connected ? tr("Not connected") : environmentId == own ? tr("This device") : environmentId;
      choice.enabled = connected;
      choice.terms = {environmentId, environmentId == own ? QStringLiteral("this device") : QString()};
      choice.submenu = [sources, environmentId] { return sources(environmentId); };
      environments.append(choice);
    }
    return environments;
  });
  commands->setTerms(kAdd, {QStringLiteral("add project"), QStringLiteral("folder"), QStringLiteral("directory"),
                            QStringLiteral("browse"), QStringLiteral("environment")});
  publish();
}

QString ProjectController::browseStart(const QString& environmentId) const {
  const std::optional<QJsonObject> settings = m_settings->settings(environmentId);
  const QString base = settings ? asFolder(settings->value(QLatin1String("addProjectBaseDirectory")).toString()) : QString();
  return base.isEmpty() ? QStringLiteral("~/") : base;
}

bool ProjectController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap map = payload.toMap();
  // `project.launch {path}`: a folder the app was started with (main.cpp),
  // which always gets a new thread.
  const bool launched = action == QLatin1String("project.launch");
  if (launched || action == QLatin1String("project.add") || action == QLatin1String("project.folder.open")) {
    const QString path = map.value(QStringLiteral("path")).toString();
    // Without a folder, the palette's Add project.
    if (path.isEmpty()) return NativeShell::of(this)->controller<KeybindingController>()->commands()->run(kAdd);
    // Where this machine's folders are not the MC's (an MC elsewhere),
    // nothing opens.
    if (!m_bridge->localFolders()) return true;
    openFolder(path, launched);
    return true;
  }
  if (action == QLatin1String("project.remove")) {
    const QString key = map.value(QStringLiteral("projectKey")).toString();
    // From the folder explorer the removal is confirmed in Settings → Project, on that project.
    if (map.value(QStringLiteral("inSettings")).toBool()) {
      const auto project = m_store->project(key);
      const auto logical = project ? NativeShell::of(this)->sidebar()->logicalProjectKey(project->environmentId, project->id) : std::nullopt;
      if (logical) {
        m_bridge->dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), *logical}});
        m_bridge->dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/projects")}});
      }
    }
    askToRemove(key);
    return true;
  }
  if (action == QLatin1String("project.remove.confirm")) {
    confirmRemoval();
    return true;
  }
  if (action == QLatin1String("project.remove.cancel")) {
    m_removal.reset();
    publish();
    return true;
  }
  return false;
}

void ProjectController::openFolder(const QString& path, bool newThread) {
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  const QFileInfo folder(path);
  if (!folder.isDir()) {
    toasts->error(QStringLiteral("Could not open folder"), path + QStringLiteral(" is not a folder on this machine."));
    return;
  }
  const QString own = m_store->environmentOf(m_client->mc());
  if (!m_client->isReady() || own.isEmpty()) {
    toasts->error(QStringLiteral("Could not open folder"), QStringLiteral("The environment is not connected."));
    return;
  }
  addFolder(own, folder.canonicalFilePath(), QStringLiteral("Could not open folder"), newThread);
}

void ProjectController::addFolder(const QString& environmentId, const QString& root, const QString& failureTitle, bool newThread) {
  // The environment chosen went away while the folder was being picked.
  if (!m_store->environmentOnline(environmentId)) {
    const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString(environmentId);
    NativeShell::of(this)->controller<ToastController>()->error(QStringLiteral("Environment unavailable"),
                                                                tr("%1 is not connected.").arg(label));
    return;
  }
  const QString normalized = sidebar::normalizePath(root);
  for (const sidebar::Project& project : m_store->projects()) {
    if (project.environmentId == environmentId && sidebar::normalizePath(project.workspaceRoot) == normalized) {
      if (newThread) {
        NativeShell::of(this)->controller<DraftController>()->start(environmentId, project.id);
      } else {
        openProject(environmentId, project.id);
      }
      return;
    }
  }
  const QString projectId = QUuid::createUuid().toString(QUuid::WithoutBraces);
  const QJsonObject command{
      {QStringLiteral("type"), QStringLiteral("project.create")},
      {QStringLiteral("projectId"), projectId},
      {QStringLiteral("workspaceRoot"), root},
  };
  m_client->call(this, environmentId, QStringLiteral("projects.mutate"), command,
                 [this, environmentId, projectId, failureTitle](const QJsonValue&, const std::optional<QString>& error) {
                   if (error) {
                     NativeShell::of(this)->controller<ToastController>()->error(failureTitle, *error);
                     return;
                   }
                   // A draft for a project the shell has no row for would be dropped
                   // as orphaned, so it waits for the row if the answer came first.
                   if (m_store->project(environmentId + QLatin1Char(':') + projectId)) {
                     NativeShell::of(this)->controller<DraftController>()->start(environmentId, projectId);
                   } else {
                     m_created = {environmentId, projectId};
                   }
                 });
}

void ProjectController::openProject(const QString& environmentId, const QString& projectId) {
  std::optional<sidebar::Thread> latest;
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (thread.environmentId != environmentId || thread.projectId != projectId || thread.archivedAt ||
        thread.subagent || thread.settledOverride == QStringLiteral("settled")) {
      continue;
    }
    const auto at = [](const sidebar::Thread& t) {
      return sidebar::parseIso(t.latestUserMessageAt).value_or(sidebar::parseIso(t.updatedAt).value_or(0));
    };
    if (!latest || at(thread) > at(*latest)) latest = thread;
  }
  if (latest) {
    NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::thread(latest->key()));
  } else {
    NativeShell::of(this)->controller<DraftController>()->start(environmentId, projectId);
  }
}

void ProjectController::askToRemove(const QString& projectKey) {
  QString key = projectKey;
  if (!m_store->project(key)) {
    const sidebar::ProjectGroup* group = NativeShell::of(this)->sidebar()->group(projectKey);
    if (!group) return;
    key = group->summary.value(QStringLiteral("environmentId")).toString() + QLatin1Char(':') +
          group->summary.value(QStringLiteral("projectId")).toString();
  }
  const auto project = m_store->project(key);
  if (!project) return;
  askToRemove({key}, QStringLiteral("project"), project->title);
}

void ProjectController::askToRemove(const QStringList& keys, const QString& kind, const QString& title) {
  if (keys.isEmpty()) return;
  m_removal = Removal{keys, kind, title};
  publish();
}

void ProjectController::confirmRemoval() {
  if (!m_removal) return;
  const Removal removal = *std::exchange(m_removal, std::nullopt);
  publish();
  remove(removal.keys, removal.title);
}

void ProjectController::remove(QStringList keys, const QString& title) {
  if (keys.isEmpty()) return;
  const auto project = m_store->project(keys.takeFirst());
  if (!project) {
    remove(keys, title);
    return;
  }
  const QJsonObject command{
      {QStringLiteral("type"), QStringLiteral("project.delete")},
      {QStringLiteral("projectId"), project->id},
      // Its threads go with it; the confirmation said so.
      {QStringLiteral("force"), true},
  };
  // Leave the project now if the window shows it, before its rows vanish.
  auto* shell = NativeShell::of(this);
  auto* navigation = shell->controller<NavigationController>();
  const NavigationController::Route& route = navigation->route();
  bool showing = false;
  if (route.kind == QLatin1String("thread")) {
    const auto thread = m_store->thread(route.threadKey);
    showing = thread && thread->environmentId == project->environmentId && thread->projectId == project->id;
  } else if (route.kind == QLatin1String("draft")) {
    const auto draft = shell->controller<DraftController>()->draft(route.draftId);
    showing = draft && draft->environmentId == project->environmentId && draft->projectId == project->id;
  }
  m_client->call(this, project->environmentId, QStringLiteral("projects.mutate"), command,
                 [this, showing, keys, title](const QJsonValue&, const std::optional<QString>& error) {
                   auto* shell = NativeShell::of(this);
                   if (error) {
                     shell->controller<ToastController>()->error(QStringLiteral("Failed to remove project"), *error);
                     return;
                   }
                   // Its drafts go as its row does (DraftController).
                   if (showing) shell->controller<NavigationController>()->replace(NavigationController::Route());
                   remove(keys, title);
                 });
}

void ProjectController::publish() {
  if (!m_active) return;
  const auto project = m_removal ? m_store->project(m_removal->keys.first()) : std::nullopt;
  if (!project) {
    m_bridge->publish(QStringLiteral("projectRemoval"), QVariant::fromValue(nullptr));
    return;
  }
  int threadCount = 0;
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (m_removal->keys.contains(thread.environmentId + QLatin1Char(':') + thread.projectId) && !thread.archivedAt) {
      ++threadCount;
    }
  }
  const bool one = m_removal->keys.size() == 1;
  m_bridge->publish(QStringLiteral("projectRemoval"),
                    QVariantMap{
                        {QStringLiteral("projectKey"), project->key()},
                        {QStringLiteral("title"), m_removal->title},
                        {QStringLiteral("kind"), m_removal->kind},
                        {QStringLiteral("count"), m_removal->keys.size()},
                        {QStringLiteral("workspaceRoot"), one ? project->workspaceRoot : QString()},
                        {QStringLiteral("environment"),
                         one ? m_store->environment(project->environmentId).value(QLatin1String("label")).toString() : QString()},
                        {QStringLiteral("threadCount"), threadCount},
                    });
}
