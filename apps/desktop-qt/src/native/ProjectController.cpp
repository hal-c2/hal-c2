#include "ProjectController.h"

#include <QFileInfo>
#include <QJsonObject>
#include <QUuid>

#include "DraftController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ProjectController> registrar(QStringLiteral("projects"),
                                                             {QStringLiteral("projectRemoval")});

}  // namespace

ProjectController::ProjectController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
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
  publish();
}

bool ProjectController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("project.add") || action == QLatin1String("project.folder.open")) {
    const QString path = map.value(QStringLiteral("path")).toString();
    // Without a folder, or where local folders mean nothing (a remote page),
    // the page's own add-project flow.
    if (path.isEmpty() || !m_bridge->localFolderImportEnabled()) return false;
    openFolder(path);
    return true;
  }
  if (action == QLatin1String("project.remove")) {
    askToRemove(map.value(QStringLiteral("projectKey")).toString());
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

void ProjectController::openFolder(const QString& path) {
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  const QFileInfo folder(path);
  if (!folder.isDir()) {
    toasts->error(QStringLiteral("Could not open folder"), path + QStringLiteral(" is not a folder on this machine."));
    return;
  }
  const QString root = folder.canonicalFilePath();
  const QString own = m_store->environmentOf(m_client->node());
  if (!m_client->isReady() || own.isEmpty()) {
    toasts->error(QStringLiteral("Could not open folder"), QStringLiteral("The environment is not connected."));
    return;
  }
  const QString normalized = sidebar::normalizePath(root);
  for (const sidebar::Project& project : m_store->projects()) {
    if (project.environmentId == own && sidebar::normalizePath(project.workspaceRoot) == normalized) {
      openProject(own, project.id);
      return;
    }
  }
  const QString projectId = QUuid::createUuid().toString(QUuid::WithoutBraces);
  const QJsonObject command{
      {QStringLiteral("type"), QStringLiteral("project.create")},
      {QStringLiteral("projectId"), projectId},
      {QStringLiteral("workspaceRoot"), root},
  };
  m_client->call(own, QStringLiteral("projects.mutate"), command,
                 [this, own, projectId](const QJsonValue&, const std::optional<QString>& error) {
                   if (error) {
                     NativeShell::of(this)->controller<ToastController>()->error(QStringLiteral("Could not open folder"),
                                                                                 *error);
                     return;
                   }
                   // A draft for a project the shell has no row for would be dropped
                   // as orphaned, so it waits for the row if the answer came first.
                   if (m_store->project(own + QLatin1Char(':') + projectId)) {
                     NativeShell::of(this)->controller<DraftController>()->start(own, projectId);
                   } else {
                     m_created = {own, projectId};
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
  m_client->call(project->environmentId, QStringLiteral("projects.mutate"), command,
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
