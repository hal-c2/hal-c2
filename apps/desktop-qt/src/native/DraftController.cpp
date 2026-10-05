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

#include "KeybindingController.h"
#include "Keybindings.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<DraftController> registrar(QStringLiteral("drafts"), {QStringLiteral("landing")});

QString newId() {
  return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

}  // namespace

DraftController::DraftController(ShellBridge* bridge, McClient*, ShellStore* store, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_store(store),
      m_kept(NativeShell::of(this)->shell()->common<Kept>()),
      m_drafts(m_kept.drafts) {
  connect(store, &ShellStore::changed, this, &DraftController::reconcile);
}

void DraftController::setStorePath(const QString& path) {
  m_kept.path = path;
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
  auto* shell = NativeShell::of(this);
  auto* commands = shell->controller<KeybindingController>()->commands();
  const QString newThread = QStringLiteral("chat.new");
  commands->add(newThread, keybindings::commandLabel(newThread), [this] { startNew({}); });
  commands->setTerms(newThread, {QStringLiteral("new thread"), QStringLiteral("chat"), QStringLiteral("create"),
                                 QStringLiteral("draft")});
  // The web's chat.newLocal: the contextual create, never a project chooser.
  const QString newLocal = QStringLiteral("chat.newLocal");
  commands->add(newLocal, keybindings::commandLabel(newLocal), [this] {
    if (const sidebar::ProjectGroup* group = defaultGroup()) startIn(*group);
  });
  commands->setListed(newLocal, false);
  commands->addMenu(QStringLiteral("thread.newIn"), tr("New thread in..."), [this] {
    // The window's project first, then the sidebar's order.
    QList<CommandRegistry::Choice> choices;
    SidebarController* sidebar = NativeShell::of(this)->sidebar();
    const auto shown = shownProject();
    const auto current = shown ? sidebar->logicalProjectKey(shown->first, shown->second) : std::nullopt;
    for (const sidebar::ProjectGroup& group : sidebar->groups()) {
      CommandRegistry::Choice choice;
      choice.id = group.key;
      choice.title = group.summary.value(QStringLiteral("displayName")).toString();
      choice.description = group.summary.value(QStringLiteral("workspaceRoot")).toString();
      for (const sidebar::Project& member : group.members) choice.terms << member.title << member.workspaceRoot;
      choice.run = [this, key = group.key] {
        if (const sidebar::ProjectGroup* chosen = NativeShell::of(this)->sidebar()->group(key)) startIn(*chosen);
      };
      if (current == group.key) {
        choices.prepend(choice);
      } else {
        choices.append(choice);
      }
    }
    return choices;
  });
  commands->addMenu(QStringLiteral("draft.moveTo"), tr("Move draft to..."), [this] {
    QList<CommandRegistry::Choice> choices;
    const NavigationController::Route& route = NativeShell::of(this)->controller<NavigationController>()->route();
    const auto shown = shownProject();
    SidebarController* sidebar = NativeShell::of(this)->sidebar();
    const auto current = shown ? sidebar->logicalProjectKey(shown->first, shown->second) : std::nullopt;
    for (const sidebar::ProjectGroup& group : sidebar->groups()) {
      CommandRegistry::Choice choice;
      choice.id = group.key;
      choice.title = group.summary.value(QStringLiteral("displayName")).toString();
      choice.description = group.summary.value(QStringLiteral("workspaceRoot")).toString();
      choice.current = current == group.key;
      choice.run = [this, draftId = route.draftId, key = group.key] { moveTo(draftId, key); };
      choices.append(choice);
    }
    return choices;
  });
  commands->setTerms(QStringLiteral("draft.moveTo"), {QStringLiteral("move draft"), QStringLiteral("project"), QStringLiteral("change project")});
  commands->setTerms(QStringLiteral("thread.newIn"), {QStringLiteral("new thread"), QStringLiteral("project"), QStringLiteral("pick"),
                                    QStringLiteral("choose"), QStringLiteral("select")});
  connect(shell->controller<NavigationController>(), &NavigationController::changed, this, [this] {
    present();
    land();
  });
  connect(m_store, &ShellStore::changed, this, [this] {
    present();
    land();
  });
  // The sidebar's groups and scope.
  connect(m_bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key) {
    if (key == QLatin1String("sidebar")) present();
  });
  m_bridge->publish(QStringLiteral("landing"), QVariantMap{{QStringLiteral("failed"), m_landingFailed}});
  present();
  // NavigationController lands the window once it has checked the route it
  // restored.
}

// "New thread in <project>", naming where it starts, while the window shows a
// project or the list is scoped to one.
void DraftController::present() {
  auto* shell = NativeShell::of(this);
  auto* commands = shell->controller<KeybindingController>()->commands();
  const QString newThread = QStringLiteral("chat.new");
  const sidebar::ProjectGroup* group = shownProject() || shell->sidebar()->scope() ? defaultGroup() : nullptr;
  commands->setTitle(newThread, group ? tr("New thread in %1").arg(group->summary.value(QStringLiteral("displayName")).toString())
                                      : keybindings::commandLabel(newThread));
  commands->setListed(newThread, group != nullptr);
  commands->setListed(QStringLiteral("draft.moveTo"),
                      shell->controller<NavigationController>()->route().kind == QLatin1String("draft") && shell->sidebar()->groups().size() > 1);
}

std::optional<std::pair<QString, QString>> DraftController::shownProject() const {
  const NavigationController::Route& route = NativeShell::of(this)->controller<NavigationController>()->route();
  if (route.kind == QLatin1String("thread")) {
    if (const auto thread = m_store->thread(route.threadKey)) return {{thread->environmentId, thread->projectId}};
  } else if (route.kind == QLatin1String("draft")) {
    if (const auto open = draft(route.draftId)) return {{open->environmentId, open->projectId}};
  }
  return std::nullopt;
}

std::optional<DraftController::Draft> DraftController::draft(const QString& id) const {
  for (const Draft& draft : m_drafts) {
    if (draft.id == id) return draft;
  }
  return std::nullopt;
}

bool DraftController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("thread.new")) return startNew(map);
  if (action == QLatin1String("landing.retry")) {
    setLandingFailed(false);
    land();
    return true;
  }
  if (action == QLatin1String("draft.delete")) {
    remove(map.value(QStringLiteral("draftId")).toString());
    return true;
  }
  if (action == QLatin1String("draft.project")) {
    openProjects(map.value(QStringLiteral("x")).toDouble(), map.value(QStringLiteral("y")).toDouble());
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
  const sidebar::ProjectGroup* group = nullptr;
  const QVariant requested = payload.value(QStringLiteral("projectKey"));
  if (requested.typeId() == QMetaType::QString && !requested.toString().isEmpty()) {
    // A stale key (project removed, environment gone) must not land the
    // thread in whichever project sorts first.
    group = NativeShell::of(this)->sidebar()->group(requested.toString());
    if (!group) return true;
  } else {
    // The web's chat.new: with several projects, none of them showing or in
    // scope, it asks which one.
    SidebarController* sidebar = NativeShell::of(this)->sidebar();
    if (!shownProject() && !sidebar->scope() && sidebar->groups().size() > 1) {
      NativeShell::of(this)->controller<KeybindingController>()->commands()->run(QStringLiteral("thread.newIn"));
      return true;
    }
    group = defaultGroup();
  }
  // No project yet: the sidebar offers to add one.
  if (group) startIn(*group);
  return true;
}

const sidebar::ProjectGroup* DraftController::defaultGroup() const {
  SidebarController* sidebar = NativeShell::of(this)->sidebar();
  const sidebar::ProjectGroup* group = sidebar->scope() ? sidebar->group(*sidebar->scope()) : nullptr;
  if (const auto shown = shownProject(); !group && shown) {
    if (const auto key = sidebar->logicalProjectKey(shown->first, shown->second)) group = sidebar->group(*key);
  }
  if (!group && !sidebar->groups().isEmpty()) group = &sidebar->groups().first();
  return group;
}

// A logical project that spans environments starts on the member the window
// shows, else its representative.
void DraftController::startIn(const sidebar::ProjectGroup& group) {
  QString environmentId = group.summary.value(QStringLiteral("environmentId")).toString();
  QString projectId = group.summary.value(QStringLiteral("projectId")).toString();
  const auto shown = shownProject();
  if (shown && group.memberKeys.contains(shown->first + QLatin1Char(':') + shown->second)) {
    std::tie(environmentId, projectId) = *shown;
  }
  if (start(environmentId, projectId).isEmpty()) {
    NativeShell::of(this)->controller<ToastController>()->error(
        tr("Couldn't start a new thread"), tr("The project is still available. Try opening the draft again."));
  }
}

QString DraftController::start(const QString& environmentId, const QString& projectId) {
  QString id;
  for (const Draft& draft : std::as_const(m_drafts)) {
    if (draft.environmentId == environmentId && draft.projectId == projectId) id = draft.id;
  }
  if (id.isEmpty()) {
    id = newId();
    m_drafts.append({id, environmentId, projectId, newId(), sidebar::formatIso(QDateTime::currentDateTimeUtc()), {}});
    // A draft that would not survive a restart is not started.
    if (!save()) {
      m_drafts.removeLast();
      return {};
    }
    changedEverywhere();
  }
  NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::draft(id));
  emit started(id);
  return id;
}

// Home passes through (NavigationController), so the draft takes its place
// rather than stacking on it, as the web's replace navigation does.
void DraftController::land() {
  if (!m_active || !m_store->synchronized()) return;
  if (NativeShell::of(this)->controller<NavigationController>()->route().kind != QLatin1String("home")) {
    setLandingFailed(false);
    return;
  }
  if (m_landingFailed) return;
  const auto project = sidebar::mostRecentProject(m_store->projects(), m_store->threads());
  if (project && start(project->environmentId, project->id).isEmpty()) setLandingFailed(true);
}

void DraftController::setLandingFailed(bool failed) {
  if (m_landingFailed == failed) return;
  m_landingFailed = failed;
  m_bridge->publish(QStringLiteral("landing"), QVariantMap{{QStringLiteral("failed"), failed}});
}

void DraftController::remove(const QString& id) {
  const qsizetype removed = m_drafts.removeIf([&id](const Draft& draft) { return draft.id == id; });
  if (removed == 0) return;
  save();
  changedEverywhere();
  for (DraftController* drafts : everyWindow()) {
    auto* navigation = NativeShell::of(drafts)->controller<NavigationController>();
    if (navigation->route() == NavigationController::Route::draft(id)) navigation->replace(NavigationController::Route());
  }
}

void DraftController::promote(const QString& threadKey) {
  const auto found = std::find_if(m_drafts.cbegin(), m_drafts.cend(),
                                  [&threadKey](const Draft& draft) { return draft.threadKey() == threadKey; });
  if (found != m_drafts.cend()) promote(found->id, threadKey);
}

void DraftController::promote(QString id, const QString& threadKey) {
  const auto found = std::find_if(m_drafts.cbegin(), m_drafts.cend(), [&id](const Draft& draft) { return draft.id == id; });
  if (found == m_drafts.cend()) return;
  m_drafts.erase(found);
  save();
  changedEverywhere();
  for (DraftController* drafts : everyWindow()) {
    auto* navigation = NativeShell::of(drafts)->controller<NavigationController>();
    if (navigation->route() == NavigationController::Route::draft(id)) {
      navigation->replace(NavigationController::Route::thread(threadKey));
    }
  }
}

void DraftController::setText(const QString& id, const QString& text) {
  for (Draft& draft : m_drafts) {
    if (draft.id != id || draft.text == text) continue;
    draft.text = text;
    save();
  }
}

// A background send took the draft's thread id: the draft stays for the next
// prompt under a fresh one, so the launched thread's row does not end it.
void DraftController::renew(const QString& id) {
  for (Draft& draft : m_drafts) {
    if (draft.id != id) continue;
    draft.threadId = newId();
    draft.text.clear();
    save();
    changedEverywhere();
  }
}

void DraftController::openMenu(const QString& id, double x, double y) {
  if (!draft(id)) return;
  MenuController::Item remove{QStringLiteral("delete"), QStringLiteral("Delete draft"), QStringLiteral("trash")};
  remove.destructive = true;
  NativeShell::of(this)->controller<MenuController>()->open(x, y, {remove}, [this, id](const QString&) { this->remove(id); });
}

// The sidebar's projects, the open draft's ticked; picking another moves the draft (moveTo).
void DraftController::openProjects(double x, double y) {
  auto* shell = NativeShell::of(this);
  auto* navigation = shell->controller<NavigationController>();
  if (navigation->route().kind != QLatin1String("draft")) return;
  SidebarController* sidebar = shell->sidebar();
  const auto shown = shownProject();
  const auto current = shown ? sidebar->logicalProjectKey(shown->first, shown->second) : std::nullopt;
  QList<MenuController::Item> items;
  for (const sidebar::ProjectGroup& group : sidebar->groups()) {
    MenuController::Item item{group.key, group.summary.value(QStringLiteral("displayName")).toString(), {}};
    item.checked = current == group.key;
    items.append(item);
  }
  shell->controller<MenuController>()->open(x, y, items, [this, from = navigation->route().draftId](const QString& key) { moveTo(from, key); });
}

void DraftController::moveTo(const QString& from, const QString& projectKey) {
  const sidebar::ProjectGroup* group = NativeShell::of(this)->sidebar()->group(projectKey);
  const auto left = draft(from);
  if (!group || !left) return;
  startIn(*group);
  const QString to = NativeShell::of(this)->controller<NavigationController>()->route().draftId;
  const auto opened = draft(to);
  if (to == from || !opened || !opened->text.isEmpty() || left->text.isEmpty()) return;
  // Through the composer, which the window now shows `to` in, so the caret
  // lands after the text.
  m_bridge->dispatch(QStringLiteral("composer.text.set"),
                     QVariantMap{{QStringLiteral("target"), to}, {QStringLiteral("text"), left->text}, {QStringLiteral("cursor"), left->text.size()}});
  setText(from, {});
  changedEverywhere();
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

QList<DraftController*> DraftController::everyWindow() const {
  QList<DraftController*> all;
  for (const auto& window : NativeShell::of(this)->shell()->windows()) {
    if (auto* drafts = window->controller<DraftController>()) all.append(drafts);
  }
  return all;
}

void DraftController::changedEverywhere() {
  for (DraftController* drafts : everyWindow()) emit drafts->changed();
}

bool DraftController::save() const {
  if (m_kept.path.isEmpty()) return true;
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
  QDir().mkpath(QFileInfo(m_kept.path).absolutePath());
  QSaveFile file(m_kept.path);
  if (!file.open(QIODevice::WriteOnly)) return false;
  file.write(QJsonDocument(entries).toJson(QJsonDocument::Compact));
  return file.commit();
}
