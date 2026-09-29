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

namespace {

const NativeControllerRegistrar<NavigationController> registrar(QStringLiteral("navigation"), {QStringLiteral("route")});

// Enough to walk back through a session, not a history log.
constexpr qsizetype kBackStackLimit = 50;

const QStringList kKinds{
    QStringLiteral("home"),     QStringLiteral("thread"),       QStringLiteral("draft"), QStringLiteral("newThread"),
    QStringLiteral("settings"), QStringLiteral("pullRequests"), QStringLiteral("usage"),
};

QVariant nullable(const QString& value) {
  return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value);
}

// Home and a new thread are on the way somewhere: the page lands in a draft
// from either, and back should not return to the landing.
bool passesThrough(const NavigationController::Route& route) {
  return route.kind == QLatin1String("home") || route.kind == QLatin1String("newThread");
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
  if (route.kind == QLatin1String("newThread")) clean.projectKey = route.projectKey;
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

NavigationController::NavigationController(ShellBridge* bridge, NodeClient*, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_store(store) {
  // The window title follows the open thread's.
  connect(store, &ShellStore::changed, this, &NavigationController::publish);
}

void NavigationController::setStorePath(const QString& path) {
  m_storePath = path;
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return;
  const auto restored = Route::fromVariant(QJsonDocument::fromJson(file.readAll()).object().toVariantMap());
  if (!restored) return;
  m_route = *restored;
  m_restored = true;
}

void NavigationController::activate() {
  if (m_active) return;
  m_active = true;
  // A thread deleted since the last run is not coming back; one on an
  // environment the node does not serve may be the page's to show.
  if (!m_route.threadKey.isEmpty() && m_store->servesEnvironment(m_route.threadKey.section(QLatin1Char(':'), 0, 0)) &&
      !m_store->thread(m_route.threadKey)) {
    m_route = m_pageRoute.value_or(Route());
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
  m_restored = false;
  publish();
  follow();
  // The pages the palette offers; they have no default keys.
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
}

void NavigationController::pageReady() {
  m_pageRoute.reset();
  if (m_active) follow();
}

bool NavigationController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  // Where the page's own links and redirects took it, even before the shell
  // takes over, so it starts from where the user is.
  if (action == QLatin1String("route.open")) {
    const auto route = Route::fromVariant(map);
    if (!route) return true;
    m_pageRoute = *route;
    // Loading, the page lands on its start page and redirects; that is not
    // where the user left off. Where they click to is.
    if (m_restored && map.value(QStringLiteral("replace")).toBool()) return true;
    m_restored = false;
    // Behind the shell's own pages the page only lands and redirects.
    if (isNativeSection(m_route)) return true;
    // The page went back (its own back button, Escape in settings).
    if (!m_backStack.isEmpty() && m_backStack.constLast() == *route) {
      m_backStack.removeLast();
      go(*route, true, false);
    } else {
      go(*route, map.value(QStringLiteral("replace")).toBool(), false);
    }
    return true;
  }
  if (!m_active) return false;
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
    // The page moves between its own sections (and scrolls to a result); the
    // route only learns where it went.
    const QString to = map.value(QStringLiteral("to")).toString();
    // A link to one of the shell's own pages opens it instead.
    if (isNativeSection(Route::settings(to))) {
      open(Route::settings(to));
      return true;
    }
    if (m_route.kind == QLatin1String("settings") && to.startsWith(QLatin1String("/settings/"))) {
      m_pageRoute = Route::settings(to);
      go(Route::settings(to), true, false);
    }
    return false;
  } else {
    return false;
  }
  return true;
}

void NavigationController::back() {
  if (m_backStack.isEmpty()) {
    go(Route(), true, true);
    return;
  }
  go(m_backStack.takeLast(), true, true);
}

void NavigationController::go(const Route& route, bool replace, bool followPage) {
  if (route != m_route) {
    const bool settingsToSettings =
        route.kind == QLatin1String("settings") && m_route.kind == QLatin1String("settings");
    if (!replace && !settingsToSettings && !passesThrough(m_route)) {
      m_backStack.removeAll(m_route);
      m_backStack.append(m_route);
      if (m_backStack.size() > kBackStackLimit) m_backStack.removeFirst();
    }
    m_route = route;
    save();
    publish();
    emit changed();
  }
  if (followPage && m_active) follow();
}

void NavigationController::follow() {
  if (m_pageRoute == m_route) return;
  // Home is the page's own landing: nothing to tell a page that has not said
  // where it is.
  if (!m_pageRoute && m_route.kind == QLatin1String("home")) return;
  // The page cannot show the shell's own pages; it stays where it was.
  if (isNativeSection(m_route)) return;
  m_pageRoute = m_route;
  QVariantMap follow = m_route.toVariant();
  // The page opens the shell's draft as its own composer draft, for the
  // thread id the draft will become.
  if (m_route.kind == QLatin1String("draft")) {
    if (const auto* drafts = NativeShell::of(this)->controller<DraftController>()) {
      if (const auto draft = drafts->draft(m_route.draftId)) {
        follow.insert(QStringLiteral("environmentId"), draft->environmentId);
        follow.insert(QStringLiteral("projectId"), draft->projectId);
        follow.insert(QStringLiteral("threadId"), draft->threadId);
      }
    }
  }
  m_bridge->sendToPage(QStringLiteral("route.follow"), follow);
}

void NavigationController::publish() {
  if (!m_active) return;
  QString title;
  if (m_route.kind == QLatin1String("thread")) {
    if (const auto thread = m_store->thread(m_route.threadKey)) title = thread->title;
  } else if (m_route.kind == QLatin1String("draft") || m_route.kind == QLatin1String("newThread")) {
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
  m_bridge->publish(QStringLiteral("route"), state);
}

void NavigationController::save() const {
  // A new thread is on its way to a draft; the draft is what to come back to.
  if (m_storePath.isEmpty() || m_route.kind == QLatin1String("newThread")) return;
  QDir().mkpath(QFileInfo(m_storePath).absolutePath());
  QSaveFile file(m_storePath);
  if (!file.open(QIODevice::WriteOnly)) return;
  file.write(QJsonDocument(QJsonObject::fromVariantMap(m_route.toVariant())).toJson(QJsonDocument::Compact));
  file.commit();
}
