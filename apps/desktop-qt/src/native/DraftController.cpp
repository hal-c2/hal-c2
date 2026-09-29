#include "DraftController.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QUuid>

#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"

namespace {

const NativeControllerRegistrar<DraftController> registrar(QStringLiteral("drafts"));

QString newId() {
  return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

}  // namespace

DraftController::DraftController(ShellBridge* bridge, NodeClient*, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_store(store) {
  connect(store, &ShellStore::changed, this, &DraftController::reconcile);
}

void DraftController::setStorePath(const QString& path) {
  m_storePath = path;
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return;
  m_drafts.clear();
  for (const QJsonValue& value : QJsonDocument::fromJson(file.readAll()).array()) {
    const QJsonObject entry = value.toObject();
    Draft draft{entry.value(QLatin1String("id")).toString(),        entry.value(QLatin1String("environmentId")).toString(),
                entry.value(QLatin1String("projectId")).toString(), entry.value(QLatin1String("threadId")).toString(),
                entry.value(QLatin1String("createdAt")).toString(), entry.value(QLatin1String("text")).toString()};
    if (draft.id.isEmpty() || draft.environmentId.isEmpty() || draft.projectId.isEmpty() || draft.threadId.isEmpty()) {
      continue;
    }
    m_drafts.append(draft);
  }
}

void DraftController::activate() {
  if (m_active) return;
  m_active = true;
  reconcile();
}

std::optional<DraftController::Draft> DraftController::draft(const QString& id) const {
  for (const Draft& draft : m_drafts) {
    if (draft.id == id) return draft;
  }
  return std::nullopt;
}

bool DraftController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  // A draft the page opened by itself (its own new-thread shortcut) is one
  // the sidebar lists too.
  if (action == QLatin1String("route.open")) {
    const QString id = map.value(QStringLiteral("draftId")).toString();
    const QString environmentId = map.value(QStringLiteral("environmentId")).toString();
    const QString projectId = map.value(QStringLiteral("projectId")).toString();
    const QString threadId = map.value(QStringLiteral("threadId")).toString();
    if (map.value(QStringLiteral("kind")).toString() == QLatin1String("draft") && !id.isEmpty() && !draft(id) &&
        !environmentId.isEmpty() && !projectId.isEmpty() && !threadId.isEmpty() &&
        !m_store->thread(environmentId + QLatin1Char(':') + threadId)) {
      m_drafts.append({id, environmentId, projectId, threadId, sidebar::formatIso(QDateTime::currentDateTimeUtc()), {}});
      save();
      emit changed();
    }
    return false;
  }
  if (!m_active) return false;
  if (action == QLatin1String("thread.new")) return startNew(map);
  if (action == QLatin1String("draft.delete")) {
    remove(map.value(QStringLiteral("draftId")).toString());
    return true;
  }
  if (action == QLatin1String("draft.menu")) {
    openMenu(map.value(QStringLiteral("draftId")).toString(), map.value(QStringLiteral("x")).toDouble(),
             map.value(QStringLiteral("y")).toDouble());
    return true;
  }
  return false;
}

// The project to start in: the one asked for, else the scoped one, else the
// one the window shows, else the first. A logical project that spans
// environments starts on the member the window shows, else its representative.
bool DraftController::startNew(const QVariantMap& payload) {
  auto* shell = NativeShell::of(this);
  SidebarController* sidebar = shell->sidebar();
  const NavigationController::Route& route = shell->controller<NavigationController>()->route();
  std::optional<std::pair<QString, QString>> shown;
  if (route.kind == QLatin1String("thread")) {
    if (const auto thread = m_store->thread(route.threadKey)) shown = {{thread->environmentId, thread->projectId}};
  } else if (route.kind == QLatin1String("draft")) {
    if (const auto open = draft(route.draftId)) shown = {{open->environmentId, open->projectId}};
  }

  const sidebar::ProjectGroup* group = nullptr;
  const QVariant requested = payload.value(QStringLiteral("projectKey"));
  if (requested.typeId() == QMetaType::QString && !requested.toString().isEmpty()) {
    // A stale key (project removed, environment gone) must not land the
    // thread in whichever project sorts first.
    group = sidebar->group(requested.toString());
    if (!group) return true;
  } else if (sidebar->scope()) {
    group = sidebar->group(*sidebar->scope());
  }
  if (!group && shown) {
    if (const auto key = sidebar->logicalProjectKey(shown->first, shown->second)) group = sidebar->group(*key);
  }
  if (!group && !sidebar->groups().isEmpty()) group = &sidebar->groups().first();
  // No project yet: the sidebar offers to add one.
  if (!group) return true;

  QString environmentId = group->summary.value(QStringLiteral("environmentId")).toString();
  QString projectId = group->summary.value(QStringLiteral("projectId")).toString();
  if (shown && group->memberKeys.contains(shown->first + QLatin1Char(':') + shown->second)) {
    std::tie(environmentId, projectId) = *shown;
  }
  start(environmentId, projectId);
  return true;
}

QString DraftController::start(const QString& environmentId, const QString& projectId) {
  QString id;
  for (const Draft& draft : std::as_const(m_drafts)) {
    if (draft.environmentId == environmentId && draft.projectId == projectId) id = draft.id;
  }
  if (id.isEmpty()) {
    id = newId();
    m_drafts.append({id, environmentId, projectId, newId(), sidebar::formatIso(QDateTime::currentDateTimeUtc()), {}});
    save();
    emit changed();
  }
  NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::draft(id));
  return id;
}

void DraftController::remove(const QString& id) {
  const qsizetype removed = m_drafts.removeIf([&id](const Draft& draft) { return draft.id == id; });
  if (removed == 0) return;
  save();
  emit changed();
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  if (navigation->route() == NavigationController::Route::draft(id)) navigation->replace(NavigationController::Route());
}

void DraftController::promote(const QString& threadKey) {
  const auto found = std::find_if(m_drafts.cbegin(), m_drafts.cend(),
                                  [&threadKey](const Draft& draft) { return draft.threadKey() == threadKey; });
  if (found == m_drafts.cend()) return;
  const QString id = found->id;
  m_drafts.erase(found);
  save();
  emit changed();
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  if (navigation->route() == NavigationController::Route::draft(id)) {
    navigation->replace(NavigationController::Route::thread(threadKey));
  }
}

void DraftController::setText(const QString& id, const QString& text) {
  for (Draft& draft : m_drafts) {
    if (draft.id != id || draft.text == text) continue;
    draft.text = text;
    save();
  }
}

void DraftController::openMenu(const QString& id, double x, double y) {
  if (!draft(id)) return;
  MenuController::Item remove{QStringLiteral("delete"), QStringLiteral("Delete draft"), QStringLiteral("trash")};
  remove.destructive = true;
  NativeShell::of(this)->controller<MenuController>()->open(x, y, {remove}, [this, id](const QString&) { this->remove(id); });
}

void DraftController::reconcile() {
  if (!m_active || !m_store->synchronized()) return;
  QStringList promoted;
  QStringList orphaned;
  for (const Draft& draft : std::as_const(m_drafts)) {
    if (m_store->thread(draft.threadKey())) {
      promoted.append(draft.threadKey());
    } else if (m_store->servesEnvironment(draft.environmentId) &&
               !m_store->project(draft.environmentId + QLatin1Char(':') + draft.projectId)) {
      // The project was removed, here or on another client.
      orphaned.append(draft.id);
    }
  }
  for (const QString& threadKey : std::as_const(promoted)) promote(threadKey);
  for (const QString& id : std::as_const(orphaned)) remove(id);
}

void DraftController::save() const {
  if (m_storePath.isEmpty()) return;
  QJsonArray entries;
  for (const Draft& draft : m_drafts) {
    QJsonObject entry{
        {QStringLiteral("id"), draft.id},
        {QStringLiteral("environmentId"), draft.environmentId},
        {QStringLiteral("projectId"), draft.projectId},
        {QStringLiteral("threadId"), draft.threadId},
        {QStringLiteral("createdAt"), draft.createdAt},
    };
    if (!draft.text.isEmpty()) entry.insert(QStringLiteral("text"), draft.text);
    entries.append(entry);
  }
  QDir().mkpath(QFileInfo(m_storePath).absolutePath());
  QSaveFile file(m_storePath);
  if (!file.open(QIODevice::WriteOnly)) return;
  file.write(QJsonDocument(entries).toJson(QJsonDocument::Compact));
  file.commit();
}
