#include "NavigationController.h"

#include <algorithm>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>

#include "DraftController.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"

namespace {

const NativeControllerRegistrar<NavigationController> registrar(QStringLiteral("navigation"), {QStringLiteral("route")});

// Enough to walk back through a session, not a history log.
constexpr qsizetype kBackStackLimit = 50;

const QStringList kKinds{
    QStringLiteral("home"),         QStringLiteral("thread"), QStringLiteral("draft"), QStringLiteral("settings"),
    QStringLiteral("pullRequests"), QStringLiteral("usage"),
};

QVariant nullable(const QString& value) {
  return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value);
}

// Home is on the way somewhere: the window lands in a draft from it, and back
// should not return to the landing.
bool passesThrough(const NavigationController::Route& route) {
  return route.kind == QLatin1String("home");
}

}  // namespace

std::optional<NavigationController::Route> NavigationController::Route::fromVariant(const QVariant& value) {
  const QVariantMap map = value.toMap();
  Route route{map.value(QStringLiteral("kind")).toString(), map.value(QStringLiteral("threadKey")).toString(),
              map.value(QStringLiteral("draftId")).toString(), map.value(QStringLiteral("projectKey")).toString(),
              map.value(QStringLiteral("section")).toString()};
  if (!kKinds.contains(route.kind)) return std::nullopt;
  if (route.kind == QLatin1String("thread") && route.threadKey.isEmpty()) return std::nullopt;
  if (route.kind == QLatin1String("draft") && route.draftId.isEmpty()) return std::nullopt;
  // Only the fields the kind has, so two ways of saying one route compare equal.
  Route clean = of(route.kind);
  if (route.kind == QLatin1String("thread")) clean.threadKey = route.threadKey;
  if (route.kind == QLatin1String("draft")) clean.draftId = route.draftId;
  if (route.kind == QLatin1String("settings")) clean.section = route.section;
  return clean;
}

QVariantMap NavigationController::Route::toVariant() const {
  return {
      {QStringLiteral("kind"), kind},
      {QStringLiteral("threadKey"), nullable(threadKey)},
      {QStringLiteral("draftId"), nullable(draftId)},
      {QStringLiteral("projectKey"), nullable(projectKey)},
      {QStringLiteral("section"), nullable(section)},
  };
}

NavigationController::NavigationController(ShellBridge* bridge, McClient*, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_store(store) {
  // The window title follows the open thread's.
  connect(store, &ShellStore::changed, this, [this] {
    leaveVanishedThread();
    publish();
  });
}

void NavigationController::setStorePath(const QString& path) {
  m_storePath = path;
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return;
  const auto restored = Route::fromVariant(QJsonDocument::fromJson(file.readAll()).object().toVariantMap());
  if (!restored) return;
  m_route = *restored;
}

void NavigationController::activate() {
  if (m_active) return;
  m_active = true;
  // A thread deleted since the last run is not coming back; one on an
  // environment the MC does not serve yet may still arrive.
  if (!m_route.threadKey.isEmpty() && m_store->servesEnvironment(m_route.threadKey.section(QLatin1Char(':'), 0, 0)) &&
      !m_store->thread(m_route.threadKey)) {
    m_route = Route();
    save();
  }
  // Nor is a draft that was sent or deleted.
  if (m_route.kind == QLatin1String("draft")) {
    const auto* drafts = NativeShell::of(this)->controller<DraftController>();
    if (drafts && !drafts->draft(m_route.draftId)) {
      m_route = Route();
      save();
    }
  }
  publish();
  // The places the palette offers; they have no default keys.
  auto* commands = NativeShell::of(this)->controller<KeybindingController>()->commands();
  commands->add(kOpenSettings, tr("Open settings"), [this] { open(Route::settings()); });
  commands->add(kOpenUsage, tr("Open usage"), [this] { open(Route::of(QStringLiteral("usage"))); });
  commands->add(kOpenPullRequests, tr("Open pull requests"), [this] { open(Route::of(QStringLiteral("pullRequests"))); });
  commands->setTerms(kOpenSettings, {QStringLiteral("settings"), QStringLiteral("preferences"),
                                     QStringLiteral("configuration"), QStringLiteral("keybindings")});
  commands->setTerms(kOpenUsage, {QStringLiteral("usage"), QStringLiteral("use"), QStringLiteral("tokens"),
                                  QStringLiteral("cost"), QStringLiteral("spend"), QStringLiteral("limits"),
                                  QStringLiteral("stats"), QStringLiteral("analytics")});
  commands->setTerms(kOpenPullRequests, {QStringLiteral("pull requests"), QStringLiteral("prs"), QStringLiteral("pr"),
                                         QStringLiteral("github"), QStringLiteral("review"), QStringLiteral("merge"),
                                         QStringLiteral("branch")});
  // Offered while some environment has a source control provider for them.
  const auto present = [this, commands] {
    const QStringList environments = m_store->environments();
    commands->setListed(kOpenPullRequests, std::any_of(environments.cbegin(), environments.cend(), [this](const QString& id) {
                          return m_store->supports(id, QStringLiteral("pullRequests"));
                        }));
  };
  connect(m_store, &ShellStore::changed, this, present);
  present();
  m_threadSeen = m_store->thread(m_route.threadKey).has_value();
  // With the route checked, a window with no thread lands on a draft.
  if (auto* drafts = NativeShell::of(this)->controller<DraftController>()) drafts->land();
}

void NavigationController::leaveVanishedThread() {
  if (!m_active || m_route.kind != QLatin1String("thread")) return;
  // The open thread moved to another machine: the window follows it there.
  if (m_store->movedTo(m_route.threadKey)) {
    replace(Route::thread(m_route.threadKey));
    return;
  }
  if (m_store->thread(m_route.threadKey)) {
    m_threadSeen = true;
    return;
  }
  if (!m_threadSeen || NativeShell::of(this)->sidebar()->parking(m_route.threadKey)) return;
  replace(Route());
}

bool NavigationController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("thread.open")) {
    const QString key = map.value(QStringLiteral("key")).toString();
    if (!key.isEmpty()) open(Route::thread(key));
  } else if (action == QLatin1String("draft.open")) {
    const QString id = map.value(QStringLiteral("draftId")).toString();
    if (!id.isEmpty()) open(Route::draft(id));
  } else if (action == QLatin1String("settings.open")) {
    if (m_route.kind != QLatin1String("settings")) open(Route::settings());
  } else if (action == QLatin1String("settings.back")) {
    back();
  } else if (action == QLatin1String("pullRequests.open")) {
    open(Route::of(QStringLiteral("pullRequests")));
  } else if (action == QLatin1String("usage.open")) {
    open(Route::of(QStringLiteral("usage")));
  } else if (action == QLatin1String("cluster.open")) {
    open(Route::settings(kClusterSection));
  } else if (action == QLatin1String("cluster.close")) {
    if (m_route == Route::settings(kClusterSection)) back();
  } else if (action == QLatin1String("keybindings.open")) {
    open(Route::settings(kKeybindingsSection));
  } else if (action == QLatin1String("connections.open")) {
    open(Route::settings(kConnectionsSection));
  } else if (action == QLatin1String("connections.close")) {
    if (m_route == Route::settings(kConnectionsSection)) back();
  } else if (action == QLatin1String("settings.navigate") || action == QLatin1String("settings.openResult")) {
    // Any settings section, from anywhere. Within settings it is one step back.
    const QString to = map.value(QStringLiteral("to")).toString();
    const QString target = action == QLatin1String("settings.openResult")
                               ? map.value(QStringLiteral("targetId")).toString()
                               : QString();
    if (to != QLatin1String("/settings") && !to.startsWith(QLatin1String("/settings/"))) return true;
    open(Route::settings(to));
    reveal(target);
  } else {
    return false;
  }
  return true;
}

void NavigationController::back() {
  const Route from = m_route;
  go(m_backStack.isEmpty() ? Route() : m_backStack.takeLast(), true);
  if (m_route != from) m_forwardStack.append(from);
}

// Where back left, as the browser's forward: gone once the user goes
// somewhere new.
void NavigationController::forward() {
  if (m_forwardStack.isEmpty()) return;
  const Route to = m_forwardStack.takeLast();
  QList<Route> rest = m_forwardStack;
  go(to, false);
  m_forwardStack = rest;
}

void NavigationController::go(Route route, bool replace) {
  // A thread that moved to another machine opens where it lives now, so links
  // and alerts from before the move still find it.
  for (int hops = 0; hops < 8 && route.kind == QLatin1String("thread"); ++hops) {
    const auto moved = m_store->movedTo(route.threadKey);
    if (!moved) break;
    route.threadKey = *moved;
  }
  if (route != m_route) {
    m_target.clear();
    const bool settingsToSettings =
        route.kind == QLatin1String("settings") && m_route.kind == QLatin1String("settings");
    if (!replace) m_forwardStack.clear();
    if (!replace && !settingsToSettings && !passesThrough(m_route)) {
      m_backStack.removeAll(m_route);
      m_backStack.append(m_route);
      if (m_backStack.size() > kBackStackLimit) m_backStack.removeFirst();
    }
    m_route = route;
    m_threadSeen = m_store->thread(route.threadKey).has_value();
    save();
    publish();
    emit changed();
  }
}

void NavigationController::publish() {
  if (!m_active) return;
  QString title;
  if (m_route.kind == QLatin1String("thread")) {
    if (const auto thread = m_store->thread(m_route.threadKey)) title = thread->title;
  } else if (m_route.kind == QLatin1String("draft")) {
    title = QStringLiteral("New thread");
  } else if (m_route.kind == QLatin1String("settings")) {
    title = QStringLiteral("Settings");
  } else if (m_route.kind == QLatin1String("pullRequests")) {
    title = QStringLiteral("Pull requests");
  } else if (m_route.kind == QLatin1String("usage")) {
    title = QStringLiteral("Usage");
  }
  QVariantMap state = m_route.toVariant();
  state.insert(QStringLiteral("title"), title);
  state.insert(QStringLiteral("canGoBack"), !m_backStack.isEmpty());
  state.insert(QStringLiteral("target"), m_target);
  state.insert(QStringLiteral("targetSeq"), m_targetSeq);
  m_bridge->publish(QStringLiteral("route"), state);
}

void NavigationController::reveal(const QString& target) {
  if (target.isEmpty()) return;
  m_target = target;
  ++m_targetSeq;
  publish();
}

void NavigationController::save() const {
  if (m_storePath.isEmpty()) return;
  QDir().mkpath(QFileInfo(m_storePath).absolutePath());
  QSaveFile file(m_storePath);
  if (!file.open(QIODevice::WriteOnly)) return;
  file.write(QJsonDocument(QJsonObject::fromVariantMap(m_route.toVariant())).toJson(QJsonDocument::Compact));
  file.commit();
}
