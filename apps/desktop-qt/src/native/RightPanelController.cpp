#include "RightPanelController.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
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

const QString kTerminalTab = QStringLiteral("terminal:");
const QString kReviewTab = QStringLiteral("pull-request:");

// A review tab's pull request: host, repository and number of "host/repository#number".
struct Reviewed {
  QString host;
  QString repository;
  int number = 0;
};
Reviewed reviewedOf(const QString& key) {
  const qsizetype slash = key.indexOf(QLatin1Char('/'));
  const qsizetype hash = key.lastIndexOf(QLatin1Char('#'));
  if (slash <= 0 || hash <= slash + 1) return {};
  return {key.left(slash), key.mid(slash + 1, hash - slash - 1), key.mid(hash + 1).toInt()};
}

QString titleOf(const QString& id) {
  const QString kind = RightPanelController::kindOf(id);
  if (kind == QLatin1String("pull-request")) return QStringLiteral("PR #%1").arg(reviewedOf(id.mid(kReviewTab.size())).number);
  if (kind == QLatin1String("diff")) return QStringLiteral("Diff");
  if (kind == QLatin1String("agents")) return QStringLiteral("Agents");
  if (kind == QLatin1String("terminal")) return QStringLiteral("Terminal");
  if (kind == QLatin1String("pull-requests")) return QStringLiteral("Pull requests");
  if (kind == QLatin1String("previews")) return QStringLiteral("Previews");
  return QStringLiteral("Files");
}

// How many threads' panels the store keeps.
constexpr qsizetype kStoredThreads = 100;

void toast(QObject* owner, const QString& type, const QString& title, const QString& description) {
  if (auto* toasts = NativeShell::of(owner)->controller<ToastController>()) toasts->show(type, title, description);
}

QString text(const QJsonObject& row, QLatin1StringView field) {
  return row.value(field).toString();
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
          [bridge](const QUrl& url) { bridge->openExternal(url); }, this),
      m_review(
          client, [this](const QString& type, const QString& title, const QString& description) { toast(this, type, title, description); },
          [bridge](const QString& url) { bridge->openExternal(QUrl(url)); }, this) {
  // The add menu offers Pull requests only while the thread has some.
  connect(&m_pullRequests, &ThreadPullRequests::countChanged, this, &RightPanelController::publish);
  connect(&m_pullRequests, &ThreadPullRequests::countChanged, this, &RightPanelController::presentCommands);
  // The review follows its thread's environment going offline and back.
  connect(&m_pullRequests, &ThreadPullRequests::stateChanged, this, [this] { m_review.setOnline(m_pullRequests.online()); });
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
    add(QStringLiteral("rightPanel.toggleMaximized"), [this] { toggleMaximized(); });
    add(QStringLiteral("threadPanel.toggle"), [this] { toggleDetails(); });
    add(QStringLiteral("diff.toggle"), [this] { toggleDiff(); });
    add(QStringLiteral("preview.toggle"), [this] { togglePreviews(); });
    add(QStringLiteral("pullRequest.copyNumber"), [this] {
      if (isOpen() && kindOf(activeTab()) == QLatin1String("pull-request")) m_review.copyNumber();
    });
    keys->commands()->add(QStringLiteral("thread.showPullRequests"), QStringLiteral("Show linked pull requests"), [this] {
      if (m_pullRequests.count() > 0) showTab(QStringLiteral("pull-requests"));
    });
    keys->commands()->add(QStringLiteral("thread.linkPullRequest"), QStringLiteral("Link pull request to thread"),
                          [this] { linkPullRequest(); });
    keys->commands()->setTerms(QStringLiteral("thread.showPullRequests"),
                               {QStringLiteral("pull requests"), QStringLiteral("linked"), QStringLiteral("stack"),
                                QStringLiteral("prs")});
    keys->commands()->setTerms(QStringLiteral("thread.linkPullRequest"),
                               {QStringLiteral("link"), QStringLiteral("pull request"), QStringLiteral("pr"),
                                QStringLiteral("attach"), QStringLiteral("stack")});
  }
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
  } else if (action == QLatin1String("rightPanel.resize")) {
    if (map.contains(QStringLiteral("width"))) {
      setWidth(map.value(QStringLiteral("width")).toInt());
    } else {
      resetWidth();
    }
  } else if (action == QLatin1String("rightPanel.toggleMaximized")) {
    toggleMaximized();
  } else if (action == QLatin1String("threadPanel.toggle")) {
    toggleDetails();
  } else if (action == QLatin1String("rightPanel.review")) {
    reviewPullRequest(map.value(QStringLiteral("key")).toString());
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
    m_thread = threadKey;
    m_recent.removeOne(threadKey);
    m_recent.append(threadKey);
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
  presentCommands();
  update();
}

// The palette offers linking where the thread's environment links pull
// requests to threads, and showing them where it keeps a thread's list, as
// long as there is one to show.
void RightPanelController::presentCommands() {
  auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  if (!m_active || !keys) return;
  const QString threadKey = NativeShell::of(this)->controller<NavigationController>()->threadKey();
  const QString environmentId = threadKey.left(threadKey.indexOf(QLatin1Char(':')));
  const bool many = !threadKey.isEmpty() && m_store->supports(environmentId, QStringLiteral("threadPullRequests"));
  const bool one = !threadKey.isEmpty() && m_store->supports(environmentId, QStringLiteral("threadPullRequestLinking"));
  CommandRegistry* commands = keys->commands();
  commands->setListed(QStringLiteral("thread.linkPullRequest"), many || one);
  commands->setEnabled(QStringLiteral("thread.linkPullRequest"), many || one);
  commands->setListed(QStringLiteral("thread.showPullRequests"), many);
  commands->setEnabled(QStringLiteral("thread.showPullRequests"), many && m_pullRequests.count() > 0);
}

QString RightPanelController::kindOf(const QString& id) {
  if (id.startsWith(kTerminalTab)) return QStringLiteral("terminal");
  if (id.startsWith(kReviewTab)) return QStringLiteral("pull-request");
  return id;
}

QStringList RightPanelController::terminalGroups() const {
  auto* terminals = NativeShell::of(this)->controller<TerminalController>();
  return terminals ? terminals->panelGroups(m_thread) : QStringList();
}

// --- Tabs ----------------------------------------------------------------------------

bool RightPanelController::isOpen() const {
  return m_onThread && current().open;
}

QString RightPanelController::activeTab() const {
  return current().active;
}

QStringList RightPanelController::tabIds() const {
  return current().tabs;
}

bool RightPanelController::isMaximized() const {
  return isOpen() && current().maximized;
}

bool RightPanelController::detailsOpen() const {
  return m_onThread && current().details;
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
  // A closed panel comes back beside the thread.
  if (!open) state.maximized = false;
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
  } else if (kindOf(id) == QLatin1String("pull-request")) {
    if (reviewedOf(id.mid(kReviewTab.size())).number <= 0) return;
    if (!state.tabs.contains(id)) state.tabs.append(id);
  } else if (nativeKinds.contains(id)) {
    if (!state.tabs.contains(id)) state.tabs.append(id);
  } else {
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
  const QStringList before = tabIds();
  if (!state.tabs.removeOne(closing)) return;
  if (state.active == closing) {
    const QStringList after = tabIds();
    const qsizetype at = before.indexOf(closing);
    state.active = after.isEmpty() ? QString() : after.at(std::min(at, after.size() - 1));
    if (after.isEmpty()) {
      state.open = false;
      state.maximized = false;
    }
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
  if (kind == QLatin1String("pull-request")) {
    // The first one still open, else the first.
    QString key;
    for (int row = 0; row < m_pullRequests.rowCount(); ++row) {
      if (key.isEmpty() || m_pullRequests.value(row, ThreadPullRequests::StateRole) == QLatin1String("open")) {
        key = m_pullRequests.value(row, ThreadPullRequests::KeyRole).toString();
        if (m_pullRequests.value(row, ThreadPullRequests::StateRole) == QLatin1String("open")) break;
      }
    }
    reviewPullRequest(key);
    return;
  }
  if (nativeKinds.contains(kind)) showTab(kind);
}

void RightPanelController::reviewPullRequest(const QString& key) {
  if (key.isEmpty() || m_pullRequests.indexOf(key) < 0) return;
  showTab(kReviewTab + key);
}

void RightPanelController::setWidth(int width) {
  width = std::max(width, minimumWidth);
  if (width == m_width) return;
  m_width = width;
  update();
}

void RightPanelController::resetWidth() {
  setWidth(defaultWidth);
}

void RightPanelController::toggleMaximized() {
  if (!isOpen()) return;
  Panel& state = panel();
  state.maximized = !state.maximized;
  update();
}

void RightPanelController::toggleDetails() {
  if (!m_onThread) return;
  Panel& state = panel();
  state.details = !state.details;
  update();
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
    // the node's) goes: the next one shows.
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
    if (!state.open) state.maximized = false;
  }
  const bool open = isOpen();
  m_diff.setActive(open && activeTab() == QLatin1String("diff"));
  m_files.setActive(open && activeTab() == QLatin1String("files"));
  m_agents.setActive(open && activeTab() == QLatin1String("agents"));
  m_previews.setActive(open && activeTab() == QLatin1String("previews"));
  // The review shows the active review tab's pull request, or the last one shown.
  if (m_onThread && kindOf(activeTab()) == QLatin1String("pull-request")) {
    const Reviewed reviewed = reviewedOf(activeTab().mid(kReviewTab.size()));
    m_review.setOnline(m_pullRequests.online());
    m_review.setPullRequest(m_thread.left(m_thread.indexOf(QLatin1Char(':'))),
                            m_store->threadRow(m_thread).value(QLatin1String("projectId")).toString(), reviewed.host, reviewed.repository,
                            reviewed.number);
  }
  m_review.setActive(open && kindOf(activeTab()) == QLatin1String("pull-request"));
  publish();
  save();
  emit changed();
}

void RightPanelController::publish() {
  if (!m_onThread) {
    m_bridge->publish(QStringLiteral("panel"), QVariant());
    return;
  }
  const Panel state = current();
  QVariantList tabs;
  for (const QString& id : state.tabs) {
    tabs.append(QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("kind"), kindOf(id)}, {QStringLiteral("title"), titleOf(id)}});
  }
  // Terminals need the thread's place on an environment the node reaches.
  auto* terminals = NativeShell::of(this)->controller<TerminalController>();
  const bool canTerminal = terminals && terminals->available() && terminals->threadKey() == m_thread;
  m_bridge->publish(QStringLiteral("panel"),
                    QVariantMap{
                        {QStringLiteral("threadKey"), m_thread},
                        {QStringLiteral("isOpen"), state.open},
                        {QStringLiteral("activeId"), state.active},
                        {QStringLiteral("tabs"), tabs},
                        {QStringLiteral("width"), m_width},
                        {QStringLiteral("maximized"), state.open && state.maximized},
                        {QStringLiteral("detailsOpen"), state.details},
                        {QStringLiteral("details"), state.details ? QVariant(threadDetails()) : QVariant()},
                        {QStringLiteral("canAdd"),
                         QVariantMap{{QStringLiteral("diff"), true},
                                     {QStringLiteral("files"), !m_files.root().isEmpty()},
                                     {QStringLiteral("agents"), true},
                                     {QStringLiteral("terminal"), canTerminal},
                                     {QStringLiteral("pullRequests"), m_pullRequests.count() > 0},
                                     {QStringLiteral("pullRequest"), m_pullRequests.count() > 0},
                                     {QStringLiteral("previews"), true}}},
                    });
}

// What the thread details column shows of the thread, from the rows the
// store holds: where it runs, its checkout, and the threads it came from or
// started (its lineage's parent, and every thread whose parent it is).
QVariantMap RightPanelController::threadDetails() const {
  const qsizetype colon = m_thread.indexOf(QLatin1Char(':'));
  const QString environmentId = m_thread.left(colon);
  const QString threadId = m_thread.mid(colon + 1);
  const QJsonObject row = m_store->threadRow(m_thread);
  const QJsonObject project = m_store->projectRow(environmentId, text(row, QLatin1String("projectId")));
  const QJsonObject environment = m_store->environment(environmentId);
  const QString worktree = text(row, QLatin1String("worktreePath"));
  const auto titleOf = [this, &environmentId](const QString& id) {
    const QString title = text(m_store->threadRow(environmentId + QLatin1Char(':') + id), QLatin1String("title"));
    return title.isEmpty() ? QStringLiteral("Unavailable thread") : title;
  };
  QVariantList relations;
  const QJsonObject lineage = row.value(QLatin1String("lineage")).toObject();
  const QString parent = text(lineage, QLatin1String("parentThreadId"));
  if (!parent.isEmpty()) {
    relations.append(QVariantMap{{QStringLiteral("threadKey"), environmentId + QLatin1Char(':') + parent},
                                 {QStringLiteral("title"), titleOf(parent)},
                                 {QStringLiteral("relation"), text(lineage, QLatin1String("relationshipToParent")) == QLatin1String("subagent")
                                                                  ? QStringLiteral("Started as a subagent of")
                                                                  : QStringLiteral("Forked from")}});
  }
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (thread.environmentId != environmentId || thread.archivedAt) continue;
    const QJsonObject childLineage = m_store->threadRow(thread.key()).value(QLatin1String("lineage")).toObject();
    if (text(childLineage, QLatin1String("parentThreadId")) != threadId) continue;
    relations.append(QVariantMap{{QStringLiteral("threadKey"), thread.key()},
                                 {QStringLiteral("title"), thread.title},
                                 {QStringLiteral("relation"), thread.subagent ? QStringLiteral("Subagent") : QStringLiteral("Fork")}});
  }
  return {
      {QStringLiteral("environment"), text(environment, QLatin1String("label")).isEmpty() ? environmentId : text(environment, QLatin1String("label"))},
      {QStringLiteral("online"), m_store->threadOnline(m_thread)},
      {QStringLiteral("project"), text(project, QLatin1String("title"))},
      {QStringLiteral("folder"), worktree.isEmpty() ? text(project, QLatin1String("workspaceRoot")) : worktree},
      {QStringLiteral("checkout"), worktree.isEmpty() ? QStringLiteral("Local") : QStringLiteral("Worktree")},
      {QStringLiteral("branch"), text(row, QLatin1String("branch"))},
      {QStringLiteral("relations"), relations},
  };
}

// --- Kept ----------------------------------------------------------------------------

// The store: {width, threads: [{threadKey, open, tabs, active, details}]},
// the thread shown latest last.

void RightPanelController::setStorePath(const QString& path) {
  m_storePath = path;
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return;
  m_saved = file.readAll();
  const QJsonObject stored = QJsonDocument::fromJson(m_saved).object();
  m_width = std::max(stored.value(QLatin1String("width")).toInt(defaultWidth), minimumWidth);
  for (const QJsonValue& value : stored.value(QLatin1String("threads")).toArray()) {
    const QJsonObject thread = value.toObject();
    const QString threadKey = thread.value(QLatin1String("threadKey")).toString();
    if (threadKey.isEmpty()) continue;
    Panel state;
    for (const QJsonValue& id : thread.value(QLatin1String("tabs")).toArray()) {
      const QString tab = id.toString();
      const QString kind = kindOf(tab);
      const bool known = kind == QLatin1String("pull-request") ? reviewedOf(tab.mid(kReviewTab.size())).number > 0
                                                                : kind != QLatin1String("terminal") && nativeKinds.contains(kind);
      if (known && !state.tabs.contains(tab)) state.tabs.append(tab);
    }
    state.active = thread.value(QLatin1String("active")).toString();
    if (!state.tabs.contains(state.active)) state.active = state.tabs.value(0);
    state.open = thread.value(QLatin1String("open")).toBool() && !state.tabs.isEmpty();
    state.details = thread.value(QLatin1String("details")).toBool();
    m_panels.insert(threadKey, state);
    m_recent.removeOne(threadKey);
    m_recent.append(threadKey);
  }
}

void RightPanelController::save() {
  if (m_storePath.isEmpty()) return;
  QJsonArray threads;
  for (qsizetype at = m_recent.size() - 1; at >= 0 && threads.size() < kStoredThreads; --at) {
    const QString& threadKey = m_recent.at(at);
    const Panel state = m_panels.value(threadKey);
    // Terminal tabs end with the app.
    QJsonArray tabs;
    for (const QString& id : state.tabs) {
      if (kindOf(id) != QLatin1String("terminal")) tabs.append(id);
    }
    if (tabs.isEmpty() && !state.details) continue;
    const bool terminalShown = kindOf(state.active) == QLatin1String("terminal");
    threads.prepend(QJsonObject{{QStringLiteral("threadKey"), threadKey},
                                {QStringLiteral("open"), state.open},
                                {QStringLiteral("tabs"), tabs},
                                {QStringLiteral("active"), terminalShown ? QJsonValue() : QJsonValue(state.active)},
                                {QStringLiteral("details"), state.details}});
  }
  const QByteArray json = QJsonDocument(QJsonObject{{QStringLiteral("width"), m_width}, {QStringLiteral("threads"), threads}})
                              .toJson(QJsonDocument::Compact);
  if (json == m_saved) return;
  QDir().mkpath(QFileInfo(m_storePath).absolutePath());
  QSaveFile file(m_storePath);
  if (!file.open(QIODevice::WriteOnly)) return;
  file.write(json);
  if (file.commit()) m_saved = json;
}
