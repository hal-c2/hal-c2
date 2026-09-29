#include "RightPanelController.h"

#include <QJsonObject>
#include <QUrl>

#include <algorithm>

#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "TerminalController.h"
#include "ThreadStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<RightPanelController> registrar(QStringLiteral("panel"), {QStringLiteral("panel")},
                                                                "Panel");

const QString kRightPanel = QStringLiteral("rightPanel");
const QString kTerminalTab = QStringLiteral("terminal:");

QString titleOf(const QString& kind) {
  if (kind == QLatin1String("diff")) return QStringLiteral("Diff");
  if (kind == QLatin1String("agents")) return QStringLiteral("Agents");
  if (kind == QLatin1String("terminal")) return QStringLiteral("Terminal");
  if (kind == QLatin1String("pull-requests")) return QStringLiteral("Pull requests");
  if (kind == QLatin1String("previews")) return QStringLiteral("Previews");
  return QStringLiteral("Files");
}

void toast(QObject* owner, const QString& type, const QString& title, const QString& description) {
  if (auto* toasts = NativeShell::of(owner)->controller<ToastController>()) toasts->show(type, title, description);
}

}  // namespace

RightPanelController::RightPanelController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(client),
      m_store(store),
      m_diff(client, [this](const QString& type, const QString& title, const QString& description) { toast(this, type, title, description); },
             this),
      m_files(client, this),
      m_agents(this),
      m_pullRequests(
          client, store, [this](const QString& type, const QString& title, const QString& description) { toast(this, type, title, description); },
          [bridge](const QUrl& url) { bridge->openExternal(url); }, this),
      m_previews(
          client, [this](const QString& type, const QString& title, const QString& description) { toast(this, type, title, description); },
          [bridge](const QUrl& url) { bridge->openExternal(url); }, this) {
  // The add menu offers Pull requests only while the thread has some.
  connect(&m_pullRequests, &ThreadPullRequests::countChanged, this, &RightPanelController::publish);
  connect(bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key, const QVariant& value) {
    if (key == kRightPanel) onPage(value);
  });
  connect(store, &ShellStore::changed, this, [this] {
    if (m_active) retarget();
  });
}

void RightPanelController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  connect(shell->controller<NavigationController>(), &NavigationController::changed, this, &RightPanelController::retarget);
  connect(shell->controller<ThreadStore>(), &ThreadStore::activeThreadChanged, this, &RightPanelController::retarget);
  // Its panel groups come and go with their terminals.
  if (auto* terminals = shell->controller<TerminalController>()) {
    connect(terminals, &TerminalController::changed, this, &RightPanelController::update);
  }
  if (auto* keys = shell->controller<KeybindingController>()) {
    const auto add = [keys](const QString& command, std::function<void()> run) {
      keys->commands()->add(command, keybindings::commandLabel(command), std::move(run));
    };
    add(QStringLiteral("rightPanel.toggle"), [this] { toggle(); });
    add(QStringLiteral("rightPanel.close"), [this] { closeTab(); });
    add(QStringLiteral("diff.toggle"), [this] { toggleDiff(); });
    add(QStringLiteral("preview.toggle"), [this] { togglePreviews(); });
    keys->commands()->add(QStringLiteral("thread.showPullRequests"), QStringLiteral("Show linked pull requests"), [this] {
      if (m_pullRequests.count() > 0) showTab(QStringLiteral("pull-requests"));
    });
    keys->commands()->add(QStringLiteral("thread.linkPullRequest"), QStringLiteral("Link pull request to thread"),
                          [this] { linkPullRequest(); });
  }
  m_page = m_bridge->state()->value(kRightPanel).toMap();
  retarget();
}

bool RightPanelController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("rightPanel.toggle")) {
    toggle();
  } else if (action == QLatin1String("rightPanel.activate")) {
    showTab(map.value(QStringLiteral("id")).toString());
  } else if (action == QLatin1String("rightPanel.close")) {
    closeTab(map.value(QStringLiteral("id")).toString());
  } else if (action == QLatin1String("rightPanel.add")) {
    addTab(map.value(QStringLiteral("kind")).toString());
  } else if (action == QLatin1String("rightPanel.openThread")) {
    openThread(map.value(QStringLiteral("threadKey")).toString());
  } else if (action == QLatin1String("panel.open")) {
    open(map.value(QStringLiteral("tab")).toString(), map);
  } else {
    return false;
  }
  return true;
}

// --- Where it is ---------------------------------------------------------------------

void RightPanelController::retarget() {
  auto* shell = NativeShell::of(this);
  const QString threadKey = shell->controller<NavigationController>()->threadKey();
  m_onThread = !threadKey.isEmpty();
  // Away from a thread the tabs keep what they show, for coming back.
  if (m_onThread) {
    if (threadKey != m_thread) {
      m_thread = threadKey;
      m_told.clear();
    }
    const QString environmentId = threadKey.left(threadKey.indexOf(QLatin1Char(':')));
    const QJsonObject row = m_store->threadRow(threadKey);
    const QString threadId = row.value(QLatin1String("id")).toString(threadKey.mid(threadKey.indexOf(QLatin1Char(':')) + 1));
    QString root = row.value(QLatin1String("worktreePath")).toString();
    if (root.isEmpty()) {
      root = m_store->projectRow(environmentId, row.value(QLatin1String("projectId")).toString())
                 .value(QLatin1String("workspaceRoot"))
                 .toString();
    }
    TimelineModel* timeline = shell->controller<ThreadStore>()->timeline(threadKey);
    m_diff.setThread(environmentId, threadId, timeline);
    m_agents.setThread(environmentId, timeline);
    m_files.setTarget(environmentId, root);
    m_pullRequests.setThread(threadKey);
    m_previews.setThread(environmentId, threadId, m_store->nodeServing(environmentId));
  }
  update();
}

QString RightPanelController::kindOf(const QString& id) {
  return id.startsWith(kTerminalTab) ? QStringLiteral("terminal") : id;
}

QStringList RightPanelController::terminalGroups() const {
  auto* terminals = NativeShell::of(this)->controller<TerminalController>();
  return terminals ? terminals->panelGroups(m_thread) : QStringList();
}

// --- The page's tabs -----------------------------------------------------------------

QVariantList RightPanelController::pageTabs() const {
  QVariantList tabs;
  if (m_page.value(QStringLiteral("threadKey")).toString() != m_thread) return tabs;
  for (const QVariant& value : m_page.value(QStringLiteral("surfaces")).toList()) {
    const QVariantMap surface = value.toMap();
    const QString kind = surface.value(QStringLiteral("kind")).toString();
    // The page's diff, files, file, terminal and pull request list tabs are
    // drawn natively instead; its browser tabs are listed under Previews.
    if (nativeKinds.contains(kind) || kind == QLatin1String("file") || kind == QLatin1String("preview")) continue;
    tabs.append(QVariantMap{{QStringLiteral("id"), surface.value(QStringLiteral("id"))},
                            {QStringLiteral("kind"), kind},
                            {QStringLiteral("title"), surface.value(QStringLiteral("title"))},
                            {QStringLiteral("native"), false}});
  }
  return tabs;
}

bool RightPanelController::hasPageTab(const QString& id) const {
  for (const QVariant& tab : pageTabs()) {
    if (tab.toMap().value(QStringLiteral("id")).toString() == id) return true;
  }
  return false;
}

void RightPanelController::onPage(const QVariant& value) {
  const QVariantMap previous = std::exchange(m_page, value.toMap());
  if (!m_active) return;
  const QString threadKey = m_page.value(QStringLiteral("threadKey")).toString();
  if (threadKey != m_thread || threadKey.isEmpty()) return;
  // The page's first word about this thread is its own stored state, not the
  // user's: it is told what to show instead.
  if (previous.value(QStringLiteral("threadKey")).toString() != threadKey) {
    m_told.clear();
    update();
    return;
  }
  const bool pageOpen = m_page.value(QStringLiteral("isOpen")).toBool();
  const QString pageActive = m_page.value(QStringLiteral("activeSurfaceId")).toString();
  const bool openMoved = pageOpen != previous.value(QStringLiteral("isOpen")).toBool();
  const bool activeMoved = pageActive != previous.value(QStringLiteral("activeSurfaceId")).toString();
  const bool asTold = m_told.value(QStringLiteral("open")).toBool() == pageOpen &&
                      (!pageOpen || m_told.value(QStringLiteral("activeSurfaceId")).toString() == pageActive);
  if ((openMoved || activeMoved) && !asTold) {
    if (pageOpen && pageActive == QLatin1String("diff")) {
      showTab(QStringLiteral("diff"));
      return;
    }
    if (pageOpen && (pageActive == QLatin1String("files") || pageActive == QLatin1String("pull-requests"))) {
      showTab(pageActive);
      return;
    }
    if (pageOpen && pageActive.startsWith(QLatin1String("browser:"))) {
      showTab(QStringLiteral("previews"));
      return;
    }
    if (pageOpen && pageActive.startsWith(QLatin1String("file:"))) {
      open(QStringLiteral("files"), {{QStringLiteral("path"), pageActive.mid(5)}});
      return;
    }
    Panel& state = panel();
    if (pageOpen && hasPageTab(pageActive)) {
      state.open = true;
      state.active = pageActive;
    } else if (!pageOpen && openMoved && isPageTab(state.active)) {
      state.open = false;
    }
  }
  update();
}

// --- Tabs ----------------------------------------------------------------------------

bool RightPanelController::isOpen() const {
  return m_onThread && current().open;
}

QString RightPanelController::activeTab() const {
  return current().active;
}

QStringList RightPanelController::tabIds() const {
  QStringList ids = current().tabs;
  for (const QVariant& tab : pageTabs()) ids.append(tab.toMap().value(QStringLiteral("id")).toString());
  return ids;
}

void RightPanelController::toggle() {
  setOpen(!isOpen());
}

void RightPanelController::setOpen(bool open) {
  if (!m_onThread) return;
  Panel& state = panel();
  if (open) {
    const QStringList ids = tabIds();
    if (ids.isEmpty()) {
      state.tabs.append(QStringLiteral("diff"));
      state.active = QStringLiteral("diff");
    } else if (!ids.contains(state.active)) {
      state.active = ids.first();
    }
  }
  state.open = open;
  update();
}

void RightPanelController::open(const QString& tab, const QVariantMap& options) {
  if (!m_onThread || (tab != QLatin1String("diff") && tab != QLatin1String("files"))) return;
  showTab(tab);
  const QString path = options.value(QStringLiteral("path")).toString();
  if (tab == QLatin1String("diff")) {
    const int turn = options.value(QStringLiteral("turn")).toInt();
    const QString run = options.value(QStringLiteral("turnId")).toString();
    if (turn > 0) {
      m_diff.select(turn);
    } else if (!run.isEmpty()) {
      m_diff.selectRun(run);
    }
    if (!path.isEmpty()) m_diff.revealFile(path);
  } else if (!path.isEmpty()) {
    m_files.openFile(path, options.value(QStringLiteral("line")).toInt());
  }
}

void RightPanelController::showTab(const QString& id) {
  if (!m_onThread || id.isEmpty()) return;
  Panel& state = panel();
  if (kindOf(id) == QLatin1String("terminal")) {
    if (!terminalGroups().contains(id.mid(kTerminalTab.size()))) return;
    if (!state.tabs.contains(id)) state.tabs.append(id);
  } else if (nativeKinds.contains(id)) {
    if (!state.tabs.contains(id)) state.tabs.append(id);
  } else if (!hasPageTab(id)) {
    return;
  }
  state.active = id;
  state.open = true;
  update();
}

void RightPanelController::closeTab(const QString& id) {
  if (!m_onThread) return;
  Panel& state = panel();
  const QString closing = id.isEmpty() ? (state.open ? state.active : QString()) : id;
  if (closing.isEmpty()) return;
  if (isPageTab(closing)) {
    // The page drops it and publishes; onPage/update pick the next tab.
    m_bridge->sendToPage(QStringLiteral("rightPanel.close"), QVariantMap{{QStringLiteral("id"), closing}});
    return;
  }
  const QStringList before = tabIds();
  if (!state.tabs.removeOne(closing)) return;
  if (state.active == closing) {
    const QStringList after = tabIds();
    const qsizetype at = before.indexOf(closing);
    state.active = after.isEmpty() ? QString() : after.at(std::min(at, after.size() - 1));
    if (after.isEmpty()) state.open = false;
  }
  if (kindOf(closing) == QLatin1String("terminal")) {
    // Its terminals go too, as the web's closeTerminalSurface.
    if (auto* terminals = NativeShell::of(this)->controller<TerminalController>()) terminals->closeGroup(closing.mid(kTerminalTab.size()));
  }
  update();
}

void RightPanelController::addTab(const QString& kind) {
  if (!m_onThread) return;
  if (kind == QLatin1String("terminal")) {
    // A new terminal of its own, beside the drawer's.
    auto* terminals = NativeShell::of(this)->controller<TerminalController>();
    const QString group = terminals && terminals->threadKey() == m_thread ? terminals->addPanelGroup() : QString();
    if (!group.isEmpty()) showTab(kTerminalTab + group);
    return;
  }
  if (nativeKinds.contains(kind)) {
    showTab(kind);
    return;
  }
  // The page adds its own and makes it active; onPage shows it.
  m_bridge->sendToPage(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), kind}});
}

void RightPanelController::toggleDiff() {
  if (isOpen() && activeTab() == QLatin1String("diff")) {
    setOpen(false);
  } else {
    showTab(QStringLiteral("diff"));
  }
}

void RightPanelController::togglePreviews() {
  if (isOpen() && activeTab() == QLatin1String("previews")) {
    setOpen(false);
  } else {
    showTab(QStringLiteral("previews"));
  }
}

void RightPanelController::linkPullRequest() {
  if (!m_onThread) return;
  showTab(QStringLiteral("pull-requests"));
  m_pullRequests.setLinkOpen(true);
}

void RightPanelController::openThread(const QString& threadKey) {
  if (threadKey.isEmpty()) return;
  NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::thread(threadKey));
}

// --- Out -----------------------------------------------------------------------------

void RightPanelController::update() {
  if (m_onThread) {
    Panel& state = panel();
    // A terminal tab whose terminals all ended (here, in another client, or
    // the node's) goes, and so does a page tab that went away (closed on the
    // page): the next one shows.
    const QStringList groups = terminalGroups();
    const QStringList before = tabIds();
    state.tabs.removeIf([&groups](const QString& id) {
      return kindOf(id) == QLatin1String("terminal") && !groups.contains(id.mid(kTerminalTab.size()));
    });
    if (kindOf(state.active) == QLatin1String("terminal") && !state.tabs.contains(state.active)) {
      const QStringList after = tabIds();
      const qsizetype at = before.indexOf(state.active);
      state.active = after.isEmpty() ? QString() : after.at(std::clamp<qsizetype>(at, 0, after.size() - 1));
      if (after.isEmpty()) state.open = false;
    }
    if (isPageTab(state.active) && m_page.value(QStringLiteral("threadKey")).toString() == m_thread &&
        !hasPageTab(state.active)) {
      const QStringList ids = tabIds();
      state.active = ids.isEmpty() ? QString() : ids.last();
      if (ids.isEmpty()) state.open = false;
    }
  }
  const bool open = isOpen();
  m_diff.setActive(open && activeTab() == QLatin1String("diff"));
  m_files.setActive(open && activeTab() == QLatin1String("files"));
  m_agents.setActive(open && activeTab() == QLatin1String("agents"));
  m_previews.setActive(open && activeTab() == QLatin1String("previews"));
  follow();
  publish();
  emit changed();
}

void RightPanelController::follow() {
  if (!m_onThread) return;
  const Panel state = current();
  const bool pageOpen = state.open && isPageTab(state.active);
  const QVariantMap told{{QStringLiteral("threadKey"), m_thread},
                         {QStringLiteral("open"), pageOpen},
                         {QStringLiteral("activeSurfaceId"), pageOpen ? QVariant(state.active) : QVariant()}};
  if (told == m_told) return;
  // Only a page that has published this thread's panel, and shows something
  // else, is told; a page already showing what the shell wants hears nothing.
  if (m_page.value(QStringLiteral("threadKey")).toString() != m_thread) return;
  m_told = told;
  const bool shown = m_page.value(QStringLiteral("isOpen")).toBool();
  if (shown == pageOpen && (!pageOpen || m_page.value(QStringLiteral("activeSurfaceId")).toString() == state.active)) return;
  m_bridge->sendToPage(QStringLiteral("rightPanel.follow"), told);
}

void RightPanelController::publish() {
  if (!m_onThread) {
    m_bridge->publish(QStringLiteral("panel"), QVariant());
    return;
  }
  const Panel state = current();
  QVariantList tabs;
  for (const QString& id : state.tabs) {
    tabs.append(QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("kind"), kindOf(id)}, {QStringLiteral("title"), titleOf(kindOf(id))}, {QStringLiteral("native"), true}});
  }
  tabs.append(pageTabs());
  const bool pageKnown = m_page.value(QStringLiteral("threadKey")).toString() == m_thread;
  // Terminals need the thread's place on an environment the node reaches.
  auto* terminals = NativeShell::of(this)->controller<TerminalController>();
  const bool canTerminal = terminals && terminals->available() && terminals->threadKey() == m_thread;
  const QVariantMap canAdd = pageKnown ? m_page.value(QStringLiteral("canAdd")).toMap() : QVariantMap();
  const QString environmentId = m_thread.left(m_thread.indexOf(QLatin1Char(':')));
  const QString threadId = m_thread.mid(m_thread.indexOf(QLatin1Char(':')) + 1);
  m_bridge->publish(QStringLiteral("panel"),
                    QVariantMap{
                        {QStringLiteral("threadKey"), m_thread},
                        {QStringLiteral("isOpen"), state.open},
                        {QStringLiteral("activeId"), state.active},
                        {QStringLiteral("tabs"), tabs},
                        {QStringLiteral("canAdd"),
                         QVariantMap{{QStringLiteral("diff"), true},
                                     {QStringLiteral("files"), !m_files.root().isEmpty()},
                                     {QStringLiteral("agents"), true},
                                     {QStringLiteral("terminal"), canTerminal},
                                     {QStringLiteral("pullRequests"), m_pullRequests.count() > 0},
                                     {QStringLiteral("previews"), true},
                                     {QStringLiteral("pullRequest"), canAdd.value(QStringLiteral("pullRequest")).toBool()}}},
                        {QStringLiteral("embedPath"),
                         pageKnown ? m_page.value(QStringLiteral("embedPath")).toString()
                                   : QStringLiteral("/embed/%1/%2").arg(QString::fromUtf8(QUrl::toPercentEncoding(environmentId)),
                                                                        QString::fromUtf8(QUrl::toPercentEncoding(threadId)))},
                    });
}
