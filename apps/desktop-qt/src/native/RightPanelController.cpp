#include "RightPanelController.h"
#include "MenuController.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>
#include <QUrl>

#include <algorithm>
#include <utility>

#include "Browser.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "LayoutController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "SpaceController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThisMachine.h"
#include "TerminalController.h"
#include "ThreadStore.h"
#include "ToastController.h"
#include "CommandPaletteController.h"

namespace {

const NativeControllerRegistrar<RightPanelController> registrar(QStringLiteral("panel"), {QStringLiteral("panel")},
                                                                "Panel");

const QString kTerminalTab = QStringLiteral("terminal:");
const QString kReviewTab = QStringLiteral("pull-request:");
const QString kDeviceTab = QStringLiteral("device:");
const QString kBrowserTab = QStringLiteral("browser:");

// A conversation link that names a project file rather than an address:
// "src/cart.ts", "src/cart.ts#L12" or "src/cart.ts:12:3", as ThreadView's
// openLink reads it. Empty for web, mail and the app's own links.
struct FileLink {
  QString path;
  int line = 0;
};

FileLink fileLink(const QString& link) {
  static const QRegularExpression address(QStringLiteral("^(https?|mailto|hal-c2):"), QRegularExpression::CaseInsensitiveOption);
  if (address.match(link).hasMatch()) return {};
  QString path = link;
  if (path.startsWith(QLatin1String("file://"), Qt::CaseInsensitive)) path = path.mid(7);
  static const QRegularExpression anchor(QStringLiteral("#L(\\d+)"));
  static const QRegularExpression position(QStringLiteral(":(\\d+)(:\\d+)?$"));
  QRegularExpressionMatch line = anchor.match(path);
  if (!line.hasMatch()) line = position.match(path);
  path.remove(QRegularExpression(QStringLiteral("#.*$"))).remove(QRegularExpression(QStringLiteral("(:\\d+)+$")));
  return {QUrl::fromPercentEncoding(path.toUtf8()), line.hasMatch() ? line.captured(1).toInt() : 0};
}

// `path` as the workspace at `root` names it: as it is when relative, "" when outside it.
QString relativeTo(const QString& path, const QString& root) {
  if (!QDir::isAbsolutePath(path)) return QDir::cleanPath(path);
  if (root.isEmpty()) return {};
  const QString relative = QDir(root).relativeFilePath(path);
  return relative.startsWith(QLatin1String("..")) ? QString() : relative;
}

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

QString titleOf(const QString& id, const ThreadDevices& devices) {
  const QString kind = RightPanelController::kindOf(id);
  if (kind == QLatin1String("device")) return id.startsWith(kDeviceTab) ? devices.titleOf(id) : QStringLiteral("Device");
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

RightPanelController::RightPanelController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
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
          [bridge](const QString& url) { bridge->openExternal(QUrl(url)); }, this),
      m_reviewThreads(
          client, store, [this](const QString& type, const QString& title, const QString& description) { toast(this, type, title, description); },
          [this](const QString& query) {
            // The threads that link it: the command palette searching its address.
            if (auto* palette = NativeShell::of(this)->controller<CommandPaletteController>()) {
              palette->show();
              palette->setQuery(query);
            }
          },
          this),
      m_devices(client, this),
      m_linkPreviews(
          [this](const QString& environmentId, const QJsonObject& ref, PullRequestLinkPreviews::Reply reply) {
            m_client->call(this, environmentId, QStringLiteral("pullRequests.preview"), ref,
                           [reply = std::move(reply)](const QJsonValue& result, const std::optional<QString>& error) {
                             reply(error || !result.isObject() ? std::nullopt : std::optional(result.toObject()));
                           });
          },
          [this](const QString& key) {
            if (m_onThread) showTab(kReviewTab + key);
          },
          [this](const QString& url) { m_bridge->openExternal(QUrl(url)); }, [this](const QString& url) { openAddress(url); }, this) {
  m_review.setThreads(&m_reviewThreads);
  m_previews.setConnectedHere([this] { return thisMachine::hosts(*m_store, *m_client, m_client->environment()); });
  // The pages this device opened from a browser tab, kept with its preferences.
  m_previews.setRecents(
      [this] {
        const auto* settings = NativeShell::of(this)->controller<SettingsController>();
        return settings ? settings->deviceValue(QStringLiteral("previewRecentPages")).toStringList() : QStringList();
      },
      [this](const QStringList& urls) {
        if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) settings->writeDevice(QStringLiteral("previewRecentPages"), urls);
      });
  // A note on the diff's lines joins the prompt and is said to have.
  connect(&m_diff, &ThreadDiff::commentRequested, this, [this](const QVariantMap& comment) {
    m_bridge->dispatch(QStringLiteral("composer.reviewComment.add"), comment);
  });
  connect(&m_files, &WorkspaceFiles::commentRequested, this, [this](const QVariantMap& comment) {
    m_bridge->dispatch(QStringLiteral("composer.reviewComment.add"), comment);
  });
  connect(&m_files, &WorkspaceFiles::previewReady, &m_previews, &ThreadPreviews::openPage);
  connect(&m_files, &WorkspaceFiles::previewRefused, this, [this](const QString& reason) {
    toast(this, QStringLiteral("error"), QStringLiteral("Could not open the file in the browser"), reason);
  });
  // With the in-app browser each of the thread's MC browser tabs is a tab here.
  m_previews.setEmbedded(Browser::supported());
  connect(&m_previews, &ThreadPreviews::showRequested, this, [this](const QString& tabId) { showTab(kBrowserTab + tabId); });
  connect(&m_previews, &ThreadPreviews::tabChanged, this, &RightPanelController::followBrowserTabs);
  connect(&m_previews, &ThreadPreviews::statusChanged, this, &RightPanelController::followBrowserTabs);
  connect(&m_devices, &ThreadDevices::opened, this, &RightPanelController::openDevice);
  connect(&m_devices, &ThreadDevices::floated, this, &RightPanelController::floatDevice);
  connect(&m_devices, &ThreadDevices::closed, this, &RightPanelController::closeTabIn);
  connect(&m_devices, &ThreadDevices::namesChanged, this, &RightPanelController::publish);
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
  // Diffs and file previews wrap long lines as Settings → Appearance says,
  // until the user says otherwise in the panel.
  if (auto* settings = shell->controller<SettingsController>()) {
    const auto follow = [this, settings] {
      const bool wrap = settings->setting(QStringLiteral("wordWrap")).toBool();
      m_diff.setDefaultWrap(wrap);
      m_files.setDefaultWrap(wrap);
      // Settings → General's diff defaults: how a diff opens.
      m_diff.setDefaultIgnoreWhitespace(settings->setting(QStringLiteral("diffIgnoreWhitespace")).toBool());
      const bool split = settings->setting(QStringLiteral("diffLayout")).toString() == QLatin1String("split");
      const bool collapsed = settings->setting(QStringLiteral("diffFilesCollapsed")).toBool();
      for (DiffModel* model : {m_diff.model(), m_review.model()}) {
        model->setSplit(split);
        model->setCollapsedByDefault(collapsed);
      }
    };
    connect(settings, &SettingsController::deviceChanged, this, follow);
    follow();
    connect(settings, &SettingsController::deviceChanged, this, &RightPanelController::openProactively);
    connect(&m_pullRequests, &ThreadPullRequests::countChanged, this, &RightPanelController::openProactively);
    connect(&m_diff, &ThreadDiff::turnsChanged, this, &RightPanelController::openProactively);
    // The layout toggle in a diff's toolbar changes the setting too.
    for (DiffModel* model : {m_diff.model(), m_review.model()}) {
      connect(model, &DiffModel::splitChanged, this, [settings, model] {
        const QString layout = model->split() ? QStringLiteral("split") : QStringLiteral("stacked");
        if (settings->setting(QStringLiteral("diffLayout")).toString() != layout) settings->set(QStringLiteral("diffLayout"), layout);
      });
    }
  }
  if (auto* settings = shell->controller<SettingsController>(); settings && Browser::supported()) {
    Browser::instance()->setStore([settings](const QString& key) { return settings->deviceValue(key); },
                                  [settings](const QString& key, const QVariant& value) { settings->writeDevice(key, value); });
  }
  // Its panel groups come and go with their terminals.
  if (auto* terminals = shell->controller<TerminalController>()) {
    connect(terminals, &TerminalController::changed, this, &RightPanelController::update);
  }
  if (auto* keys = shell->controller<KeybindingController>()) {
    const auto add = [keys](const QString& command, std::function<void()> run) {
      keys->commands()->add(command, keybindings::commandLabel(command), std::move(run));
    };
    add(QStringLiteral("rightPanel.toggle"), [this] { toggle(); });
    // mod+w closes the innermost thing: the active tab, else the window.
    add(QStringLiteral("rightPanel.close"), [this] {
      if (m_onThread && ((panel().open && !panel().active.isEmpty()) || !panel().stage.focusedTab().isEmpty())) {
        closeTab();
      } else {
        m_bridge->windowCommand(QStringLiteral("close"));
      }
    });
    add(QStringLiteral("rightPanel.toggleMaximized"), [this] { toggleMaximized(); });
    // The stage: palette entries, and keys for moving a tab and the timeline.
    add(QStringLiteral("stage.moveTab"), [this] { moveTab(); });
    add(QStringLiteral("stage.toggleFocus"), [this] { toggleFocus(); });
    add(QStringLiteral("stage.nextPane"), [this] {
      if (m_onThread && !panel().stage.isEmpty()) focusPane((panel().stage.focused + 1) % panel().stage.panes.size());
    });
    add(QStringLiteral("stage.dismiss"), [this] { dismissStage(); });
    for (const QString& layout : PanelStage::layouts) {
      add(QStringLiteral("stage.layout.") + layout, [this, layout] { setStageLayout(layout); });
    }
    add(QStringLiteral("threadPanel.toggle"), [this] { toggleDetails(); });
    add(QStringLiteral("diff.toggle"), [this] { toggleDiff(); });
    add(QStringLiteral("preview.toggle"), [this] { togglePreviews(); });
    // The page in the browser tab showing does these (BrowserPanel): the
    // panel's, else the one in the stage's focused pane.
    for (const QString& command : {QStringLiteral("preview.refresh"), QStringLiteral("preview.focusUrl"), QStringLiteral("preview.zoomIn"),
                                   QStringLiteral("preview.zoomOut"), QStringLiteral("preview.resetZoom")}) {
      add(command, [this, command] {
        if (!m_onThread) return;
        const QString tab = isOpen() && kindOf(activeTab()) == QLatin1String("browser") ? activeTab() : current().stage.focusedTab();
        if (kindOf(tab) != QLatin1String("browser")) return;
        if (BrowserPage* page = Browser::page(tab.mid(kBrowserTab.size()))) emit page->commandRequested(command);
      });
    }
    add(QStringLiteral("pullRequest.copyNumber"), [this] {
      const QStringList shown = shownTabs();
      if (std::any_of(shown.begin(), shown.end(), [](const QString& id) { return kindOf(id) == QLatin1String("pull-request"); })) m_review.copyNumber();
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
  } else if (action == QLatin1String("link.menu")) {
    // A link in the conversation: opening and copying it, and linking the
    // pull request it names to the thread. A path opens in the files.
    const QString url = map.value(QStringLiteral("url")).toString();
    const FileLink file = fileLink(url);
    const bool isFile = !file.path.isEmpty();
    QList<MenuController::Item> items{
        isFile ? MenuController::Item{QStringLiteral("open"), tr("Open file"), QStringLiteral("file")}
               : MenuController::Item{QStringLiteral("open"), tr("Open link"), QStringLiteral("external-link")},
        {QStringLiteral("copy"), isFile ? tr("Copy path") : tr("Copy link"), QStringLiteral("copy")}};
    // A dev server's link opens in the panel's browser; the user's own is a choice.
    if (!isFile && m_onThread && m_previews.embedded() && ThreadPreviews::opensHere(QUrl(url))) {
      items.insert(1, {QStringLiteral("external"), tr("Open in system browser"), QStringLiteral("globe")});
    }
    const QString environmentId = m_thread.left(m_thread.indexOf(QLatin1Char(':')));
    // A file of the project that is Space content opens as a page too.
    auto* spaces = NativeShell::of(this)->controller<SpaceController>();
    const QString relative = isFile ? relativeTo(file.path, m_files.root()) : QString();
    if (m_onThread && spaces && !relative.isEmpty() && spaces->isSpaceFile(environmentId, m_projectId, relative)) {
      items.insert(1, {QStringLiteral("open-in-space"), m_onWorktree ? tr("Open the project's copy in a Space") : tr("Open in a Space"),
                       QStringLiteral("book")});
    }
    if (m_onThread && ThreadPullRequests::parseUrl(url) &&
        (m_store->supports(environmentId, QStringLiteral("threadPullRequests")) ||
         m_store->supports(environmentId, QStringLiteral("threadPullRequestLinking")))) {
      items.append({QStringLiteral("link-pull-request"), tr("Link pull request to thread"), QStringLiteral("git-pull-request")});
    }
    NativeShell::of(this)->controller<MenuController>()->open(
        map.value(QStringLiteral("x")).toDouble(), map.value(QStringLiteral("y")).toDouble(), items,
        [this, url, file, environmentId, project = m_projectId, relative](const QString& id) {
          if (id == QLatin1String("open-in-space")) {
            if (auto* spaces = NativeShell::of(this)->controller<SpaceController>()) spaces->openFile(environmentId, project, relative);
          } else if (id == QLatin1String("open")) {
            if (file.path.isEmpty()) {
              openAddress(url);
            } else {
              open(QStringLiteral("files"), {{QStringLiteral("path"), file.path}, {QStringLiteral("line"), file.line}});
            }
          } else if (id == QLatin1String("external")) {
            m_bridge->openExternal(QUrl(url));
          } else if (id == QLatin1String("copy")) {
            m_bridge->setClipboardText(file.path.isEmpty() ? url : file.path);
          } else {
            showTab(QStringLiteral("pull-requests"));
            m_pullRequests.link(url);
          }
        });
  } else if (action == QLatin1String("pullRequest.linkMenu")) {
    // The right-click on a pull request's number: copy first, since that is
    // why one right-clicks a number rather than clicks it, then its page,
    // named for the host the user lands on.
    const QString url = map.value(QStringLiteral("url")).toString();
    const std::optional<PullRequestLink> link = PullRequestLinks::parse(url);
    const QString provider = map.value(QStringLiteral("provider"), link ? link->provider : QString()).toString();
    NativeShell::of(this)->controller<MenuController>()->open(
        map.value(QStringLiteral("x")).toDouble(), map.value(QStringLiteral("y")).toDouble(),
        {{QStringLiteral("copy-link"), tr("Copy link"), QStringLiteral("copy")},
         {QStringLiteral("open-external"), PullRequestLinks::openOnHostLabel(provider), QStringLiteral("external-link")}},
        [this, url](const QString& id) {
          if (id == QLatin1String("copy-link") && !m_bridge->setClipboardText(url)) {
            toast(this, QStringLiteral("error"), tr("Could not copy the link"), {});
          } else if (id == QLatin1String("open-external") && !m_bridge->openExternal(QUrl(url))) {
            toast(this, QStringLiteral("error"), tr("Could not open the link"), {});
          }
        });
  } else if (action == QLatin1String("rightPanel.rename")) {
    renameTab(map.value(QStringLiteral("id")).toString(), map.value(QStringLiteral("title")).toString());
  } else if (action == QLatin1String("rightPanel.unfloat")) {
    unfloat();
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
  } else if (action == QLatin1String("rightPanel.dock")) {
    const QString id = map.value(QStringLiteral("id")).toString();
    if (map.value(QStringLiteral("dock")).toString() == QLatin1String("panel")) {
      moveToPanel(id);
    } else {
      // `focus`: with the timeline put away (Open in centre).
      if (m_onThread && map.value(QStringLiteral("focus")).toBool() && panel().tabs.contains(id)) panel().stage.focus = true;
      moveToStage(id, map.value(QStringLiteral("pane"), -1).toInt(), map.value(QStringLiteral("zone"), QStringLiteral("center")).toString());
    }
  } else if (action == QLatin1String("stage.sideBySide")) {
    sideBySide(map.value(QStringLiteral("id")).toString(), map.value(QStringLiteral("with")).toString());
  } else if (action == QLatin1String("stage.show")) {
    showTab(map.value(QStringLiteral("id")).toString());
  } else if (action == QLatin1String("stage.layout")) {
    setStageLayout(map.value(QStringLiteral("layout")).toString());
  } else if (action == QLatin1String("stage.focusPane")) {
    focusPane(map.value(QStringLiteral("pane")).toInt());
  } else if (action == QLatin1String("stage.toggleFocus")) {
    toggleFocus();
  } else if (action == QLatin1String("stage.resize")) {
    setChatWidth(map.value(QStringLiteral("width")).toInt());
  } else if (action == QLatin1String("stage.dismiss")) {
    dismissStage();
  } else if (action == QLatin1String("threadPanel.toggle")) {
    toggleDetails();
  } else if (action == QLatin1String("rightPanel.review")) {
    reviewPullRequest(map.value(QStringLiteral("key")).toString());
  } else if (action == QLatin1String("rightPanel.linkPullRequest")) {
    // A pull request a message mentions: the tab shows it once it is linked.
    if (m_onThread) {
      showTab(QStringLiteral("pull-requests"));
      m_pullRequests.link(map.value(QStringLiteral("url")).toString());
    }
  } else if (action == QLatin1String("rightPanel.reviewProject")) {
    // A pull request of the thread's project that is not linked to it.
    if (m_onThread) showTab(kReviewTab + map.value(QStringLiteral("key")).toString());
  } else if (action == QLatin1String("rightPanel.openThread")) {
    openThread(map.value(QStringLiteral("threadKey")).toString());
  } else if (action == QLatin1String("panel.open")) {
    open(map.value(QStringLiteral("tab")).toString(), map);
  } else if (action == QLatin1String("thread.openLink")) {
    // A link in the conversation: a pull request opens beside the thread,
    // anything else as an address (openAddress).
    m_linkPreviews.follow(map.value(QStringLiteral("url")).toString(), map.value(QStringLiteral("external")).toBool());
  } else if (action == QLatin1String("thread.openAddress")) {
    // A web address in the conversation (ThreadView's openLink).
    openAddress(map.value(QStringLiteral("url")).toString());
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
    const QString projectRoot = m_store->projectRow(environmentId, row.value(QLatin1String("projectId")).toString())
                                    .value(QLatin1String("workspaceRoot"))
                                    .toString();
    QString root = row.value(QLatin1String("worktreePath")).toString();
    // A page follows the project folder's file, never the worktree's copy.
    m_onWorktree = !root.isEmpty() && QDir::cleanPath(root) != QDir::cleanPath(projectRoot);
    if (root.isEmpty()) root = projectRoot;
    TimelineModel* timeline = shell->controller<ThreadStore>()->timeline(threadKey);
    m_diff.setThread(environmentId, threadId, timeline);
    m_diff.setCheckout(root);
    m_agents.setThread(environmentId, timeline);
    m_files.setTarget(environmentId, root, threadId);
    // Which of the project's files open in a Space, for the tab's menus and the links.
    m_projectId = row.value(QLatin1String("projectId")).toString();
    const QString listed = environmentId + QLatin1Char(':') + m_projectId + QLatin1Char('@') + m_client->environment();
    if (auto* spaces = shell->controller<SpaceController>(); spaces && std::exchange(m_listedFiles, listed) != listed) {
      spaces->listFiles(environmentId, m_projectId);
    }
    m_files.setTimeline(timeline);
    m_pullRequests.setThread(threadKey);
    m_previews.setThread(environmentId, threadId, m_store->mcServing(environmentId));
    // The project's own preview addresses (its scripts' previewUrl).
    QStringList configured;
    const QJsonObject project = m_store->projectRow(environmentId, row.value(QLatin1String("projectId")).toString());
    for (const QJsonValue& script : project.value(QLatin1String("scripts")).toArray()) {
      const QString url = script.toObject().value(QLatin1String("previewUrl")).toString();
      if (!url.isEmpty()) configured.append(url);
    }
    m_previews.setConfigured(configured);
    m_devices.setThread(environmentId, threadId, m_store->mcServing(environmentId));
    // Its pull request links read on the thread's environment.
    const bool reads = m_store->supports(environmentId, QStringLiteral("pullRequests"));
    m_linkPreviews.setContext(reads ? environmentId : QString(), reads ? m_store->projectRows(environmentId) : QList<QJsonObject>());
    openProactively();
  }
  presentCommands();
  update();
}

void RightPanelController::openProactively() {
  if (!m_active || !m_onThread) return;
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  if (!settings || !settings->setting(QStringLiteral("proactivePanelsEnabled")).toBool()) return;
  // Linked pull requests first: the one there is, else their list.
  QStringList links;
  for (int row = 0; row < m_pullRequests.rowCount(); ++row) links.append(m_pullRequests.value(row, ThreadPullRequests::KeyRole).toString());
  QString target = links.join(QLatin1Char('\n'));
  if (target.isEmpty()) {
    // Otherwise the latest turn's diff, when it changed at least 3 files or 50 lines.
    const QJsonObject checkpoint = m_diff.latestCheckpoint();
    const QJsonArray files = checkpoint.value(QLatin1String("files")).toArray();
    int lines = 0;
    for (const QJsonValue& file : files) {
      lines += file.toObject().value(QLatin1String("additions")).toInt() + file.toObject().value(QLatin1String("deletions")).toInt();
    }
    if (files.size() >= 3 || lines >= 50) target = QStringLiteral("diff:") + checkpoint.value(QLatin1String("id")).toString();
  }
  if (target.isEmpty() || m_proactive.value(m_thread) == target) return;
  m_proactive.insert(m_thread, target);
  if (target.startsWith(QLatin1String("diff:"))) {
    // A pull request under review keeps the panel.
    if (!(panel().open && kindOf(panel().active) == QLatin1String("pull-request"))) showTab(QStringLiteral("diff"));
  } else if (links.size() == 1) {
    reviewPullRequest(links.first());
  } else {
    showTab(QStringLiteral("pull-requests"));
  }
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
  if (id.startsWith(kDeviceTab)) return QStringLiteral("device");
  if (id.startsWith(kBrowserTab)) return QStringLiteral("browser");
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
    const QStringList ids = panelTabs(state);
    if (ids.isEmpty()) {
      // The Diff tab, or the first of these the stage does not have.
      for (const QString kind : {QStringLiteral("diff"), QStringLiteral("agents"), QStringLiteral("previews")}) {
        if (state.tabs.contains(kind)) continue;
        state.tabs.append(kind);
        state.active = kind;
        break;
      }
      if (state.active.isEmpty()) return;
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
    // One file of the turn is shown alone; the turn's diff shows them all.
    if (options.value(QStringLiteral("only")).toBool()) {
      m_diff.focusFile(path);
    } else {
      m_diff.showAllFiles();
      if (!path.isEmpty()) m_diff.revealFile(path);
    }
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
  } else if (id.startsWith(kDeviceTab)) {
    if (ThreadDevices::targetOf(id).first.isEmpty()) return;
    if (!state.tabs.contains(id)) state.tabs.append(id);
  } else if (id.startsWith(kBrowserTab)) {
    if (m_previews.tab(id.mid(kBrowserTab.size())).isEmpty()) return;
    if (!state.tabs.contains(id)) state.tabs.append(id);
  } else if (nativeKinds.contains(id)) {
    if (!state.tabs.contains(id)) state.tabs.append(id);
  } else {
    return;
  }
  if (state.floating == id) state.floating.clear();
  // A tab on the stage shows there.
  if (state.stage.contains(id)) {
    state.stage.show(id);
  } else {
    state.active = id;
    state.open = true;
  }
  update();
}

// Takes `id` out of `state`; the next tab shows in its place.
bool RightPanelController::removeTab(Panel& state, const QString& id) {
  const QStringList before = panelTabs(state);
  if (!state.tabs.removeOne(id)) return false;
  state.titles.remove(id);
  if (state.floating == id) state.floating.clear();
  if (id.startsWith(kDeviceTab) && !state.dismissed.contains(id)) state.dismissed.append(id);
  state.stage.remove(id);
  if (state.active == id) nextActive(state, before);
  return true;
}

QStringList RightPanelController::panelTabs(const Panel& state) {
  QStringList ids;
  for (const QString& id : state.tabs) {
    if (!state.stage.contains(id)) ids.append(id);
  }
  return ids;
}

void RightPanelController::nextActive(Panel& state, const QStringList& before) {
  const QStringList after = panelTabs(state);
  const qsizetype at = std::max<qsizetype>(before.indexOf(state.active), 0);
  state.active = after.isEmpty() ? QString() : after.at(std::min(at, after.size() - 1));
  if (after.isEmpty()) state.open = false;
}

void RightPanelController::closeTabIn(const QString& threadKey, const QString& id) {
  if (m_onThread && threadKey == m_thread) return closeTab(id);
  const auto found = m_panels.find(threadKey);
  if (found != m_panels.end() && removeTab(*found, id)) save();
}

// A dev server on the thread's machine opens through the connected MC's
// forward to it (ThreadPreviews::openAddress); anything else as it is.
void RightPanelController::openAddress(const QString& url) {
  if (m_onThread) {
    m_previews.openAddress(url);
  } else {
    m_bridge->openExternal(QUrl(url));
  }
}

void RightPanelController::closeTab(const QString& id) {
  if (!m_onThread) return;
  Panel& state = panel();
  // The panel's tab, else the stage's focused one.
  const QString closing = !id.isEmpty() ? id : state.open && !state.active.isEmpty() ? state.active : state.stage.focusedTab();
  if (closing.isEmpty() || !state.tabs.contains(closing)) return;
  // A browser tab is the MC's: closing it here closes it there.
  if (closing.startsWith(kBrowserTab)) m_previews.close(closing.mid(kBrowserTab.size()));
  auto* terminals = kindOf(closing) == QLatin1String("terminal") ? NativeShell::of(this)->controller<TerminalController>() : nullptr;
  if (!terminals) {
    if (removeTab(state, closing)) update();
    return;
  }
  // Its terminals go too: asked once for all of them.
  const QString group = closing.mid(kTerminalTab.size());
  const QString thread = m_thread;
  terminals->confirmClose(terminals->groupTerminals(group), [this, terminals, thread, closing, group] {
    if (!m_onThread || thread != m_thread || !removeTab(panel(), closing)) return;
    terminals->closeGroup(group);
    update();
  });
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
  if (kind == QLatin1String("browser")) {
    // A new browser tab: an empty one on the MC, shown here once it is
    // (showRequested), else filled from the Previews tab.
    if (!m_previews.embedded()) showTab(QStringLiteral("previews"));
    m_previews.newTab();
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

void RightPanelController::openDevice(const QString& id, bool automatic) {
  if (!m_onThread) return;
  Panel& state = panel();
  if (automatic && (state.dismissed.contains(id) || state.tabs.contains(id))) return;
  state.dismissed.removeOne(id);
  // The device takes the picker's place, on the panel or the stage.
  if (!state.tabs.contains(id)) {
    const qsizetype picker = state.tabs.indexOf(QStringLiteral("device"));
    if (picker >= 0) state.tabs[picker] = id;
  } else {
    state.tabs.removeOne(QStringLiteral("device"));
  }
  state.stage.rename(QStringLiteral("device"), id);
  if (state.active == QLatin1String("device")) state.active = id;
  showTab(id);
}

void RightPanelController::floatDevice(const QString& id) {
  if (!m_onThread || !panel().tabs.contains(id)) return;
  Panel& state = panel();
  // A device on the stage floats from the panel.
  state.stage.remove(id);
  state.floating = id;
  state.open = false;
  if (state.active.isEmpty() || state.stage.contains(state.active)) state.active = id;
  update();
}

void RightPanelController::unfloat() {
  if (!m_onThread) return;
  Panel& state = panel();
  if (state.floating.isEmpty()) return;
  const QString id = state.floating;
  state.floating.clear();
  showTab(id);
}

void RightPanelController::renameTab(const QString& id, const QString& title) {
  if (!m_onThread || !panel().tabs.contains(id)) return;
  Panel& state = panel();
  const QString trimmed = title.trimmed();
  if (trimmed.isEmpty()) state.titles.remove(id);
  else state.titles.insert(id, trimmed);
  update();
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
  if (!m_onThread) return;
  Panel& state = panel();
  if (state.stage.focus && !state.stage.focusedTab().isEmpty()) {
    // Back: the tab returns to the panel, and the timeline shows.
    state.stage.focus = false;
    moveToPanel(state.stage.focusedTab());
  } else if (isOpen() && !state.active.isEmpty()) {
    const QString id = state.active;
    state.stage.focus = true;
    moveToStage(id);
  } else if (!state.stage.isEmpty()) {
    toggleFocus();
  }
}

void RightPanelController::moveToStage(const QString& id, int pane, const QString& zone) {
  if (!m_onThread) return;
  Panel& state = panel();
  if (!state.tabs.contains(id)) return;
  const QStringList before = panelTabs(state);
  if (state.floating == id) state.floating.clear();
  state.stage.add(id, pane, zone);
  if (state.active == id) nextActive(state, before);
  update();
}

void RightPanelController::moveToPanel(const QString& id) {
  if (!m_onThread) return;
  Panel& state = panel();
  if (!state.stage.remove(id)) return;
  state.active = id;
  state.open = true;
  update();
}

void RightPanelController::sideBySide(const QString& id, const QString& other) {
  if (!m_onThread || id == other) return;
  Panel& state = panel();
  if (!state.tabs.contains(id) || !state.tabs.contains(other)) return;
  const QStringList before = panelTabs(state);
  for (const QString& tab : {id, other}) {
    if (state.floating == tab) state.floating.clear();
    if (!state.stage.contains(tab)) state.stage.tabs.append(tab);
  }
  state.stage.layout = QStringLiteral("columns");
  state.stage.panes = {id, other};
  state.stage.focused = 0;
  state.stage.normalize();
  if (!state.active.isEmpty() && !panelTabs(state).contains(state.active)) nextActive(state, before);
  update();
}

void RightPanelController::moveTab() {
  if (!m_onThread) return;
  const Panel& state = panel();
  // With the timeline away the stage is what the user looks at.
  if (state.stage.focus && !state.stage.focusedTab().isEmpty()) {
    moveToPanel(state.stage.focusedTab());
  } else if (isOpen() && !state.active.isEmpty()) {
    moveToStage(state.active);
  } else if (!state.stage.focusedTab().isEmpty()) {
    moveToPanel(state.stage.focusedTab());
  }
}

void RightPanelController::setStageLayout(const QString& layout) {
  if (!m_onThread) return;
  panel().stage.setLayout(layout);
  update();
}

void RightPanelController::focusPane(int pane) {
  if (!m_onThread) return;
  panel().stage.focusPane(pane);
  update();
}

void RightPanelController::toggleFocus() {
  if (!m_onThread || panel().stage.isEmpty()) return;
  panel().stage.focus = !panel().stage.focus;
  update();
}

void RightPanelController::setChatWidth(int width) {
  if (!m_onThread) return;
  panel().stage.chatWidth = std::max(width, 0);
  update();
}

void RightPanelController::dismissStage() {
  if (!m_onThread || panel().stage.isEmpty()) return;
  Panel& state = panel();
  // The focused tab, else the first shown (the focused pane can be empty).
  const QString shown = state.stage.shown().value(0);
  state.stage.clear();
  state.active = shown;
  state.open = true;
  update();
}

QStringList RightPanelController::shownTabs() const {
  if (!m_onThread) return {};
  const Panel state = current();
  QStringList ids = state.stage.shown();
  if (state.open && !state.active.isEmpty()) ids.append(state.active);
  return ids;
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

// The shown thread's browser tabs are its MC tabs: one the MC lists that is
// not here yet comes in behind the others, and one it no longer has goes.
void RightPanelController::followBrowserTabs() {
  if (!m_onThread || !m_previews.embedded() || m_previews.status() != QLatin1String("ready")) return;
  Panel& state = panel();
  QStringList listed;
  for (int row = 0; row < m_previews.rowCount(); ++row) {
    listed.append(kBrowserTab + m_previews.data(m_previews.index(row), ThreadPreviews::TabIdRole).toString());
  }
  bool changed = false;
  for (const QString& id : QStringList(state.tabs)) {
    if (id.startsWith(kBrowserTab) && !listed.contains(id)) changed = removeTab(state, id) || changed;
  }
  for (const QString& id : std::as_const(listed)) {
    if (!state.tabs.contains(id)) {
      state.tabs.append(id);
      changed = true;
    }
  }
  if (changed) {
    update();
  } else {
    // A page's title is its tab's.
    publish();
  }
}

QString RightPanelController::browserTitle(const QString& id) const {
  const QJsonObject nav = m_previews.tab(id.mid(kBrowserTab.size())).value(QLatin1String("navStatus")).toObject();
  const QString title = nav.value(QLatin1String("title")).toString();
  if (!title.isEmpty()) return title;
  const QUrl url(nav.value(QLatin1String("url")).toString());
  return url.isEmpty() ? QStringLiteral("New tab") : url.host() + (url.port() > 0 ? QStringLiteral(":%1").arg(url.port()) : QString());
}

// --- Out -----------------------------------------------------------------------------

void RightPanelController::update() {
  if (m_onThread) {
    Panel& state = panel();
    // A device floats only while the panel is closed: open, the panel's
    // active tab is what shows and takes input.
    if (state.open) state.floating.clear();
    // A terminal tab whose terminals all ended (here, in another client, or
    // the MC's) goes: the next one shows.
    const QStringList groups = terminalGroups();
    const QStringList before = panelTabs(state);
    const QStringList ended = state.tabs.filter(kTerminalTab);
    for (const QString& id : ended) {
      if (groups.contains(id.mid(kTerminalTab.size()))) continue;
      state.tabs.removeOne(id);
      state.stage.remove(id);
    }
    if (!state.active.isEmpty() && !panelTabs(state).contains(state.active)) nextActive(state, before);
    if (panelTabs(state).isEmpty()) state.open = false;
  }
  // Each body works while a tab of its kind shows; a body of one kind shows
  // the first of its tabs.
  const QStringList shown = shownTabs();
  const auto first = [&shown](const QString& kind) {
    for (const QString& id : shown) {
      if (kindOf(id) == kind) return id;
    }
    return QString();
  };
  m_diff.setActive(shown.contains(QStringLiteral("diff")));
  m_files.setActive(shown.contains(QStringLiteral("files")));
  m_agents.setActive(shown.contains(QStringLiteral("agents")));
  if (m_previews.embedded()) {
    // The thread's browser tabs are followed while it shows; its machine's
    // servers while the overview or an empty browser tab offers them.
    m_previews.setActive(m_onThread);
    const bool empty = std::any_of(shown.begin(), shown.end(), [this](const QString& id) {
      return kindOf(id) == QLatin1String("browser") &&
             m_previews.tab(id.mid(kBrowserTab.size())).value(QLatin1String("navStatus")).toObject().value(QLatin1String("url")).toString().isEmpty();
    });
    m_previews.setSuggesting(shown.contains(QStringLiteral("previews")) || empty);
  } else {
    m_previews.setActive(shown.contains(QStringLiteral("previews")));
  }
  // Each device tab streams while it shows: a floating device keeps
  // streaming while the panel is closed.
  QStringList deviceTabs, shownDevices = shown;
  if (m_onThread) {
    for (const QString& id : current().tabs) {
      if (id.startsWith(kDeviceTab)) deviceTabs.append(id);
    }
    if (!current().floating.isEmpty()) shownDevices.append(current().floating);
  }
  m_devices.setTabs(deviceTabs);
  m_devices.setShown(shownDevices);
  // The review shows the shown review tab's pull request, or the last one shown.
  const QString reviewing = first(QStringLiteral("pull-request"));
  if (!reviewing.isEmpty()) {
    const Reviewed reviewed = reviewedOf(reviewing.mid(kReviewTab.size()));
    m_review.setOnline(m_pullRequests.online());
    m_review.setPullRequest(m_thread.left(m_thread.indexOf(QLatin1Char(':'))),
                            m_store->threadRow(m_thread).value(QLatin1String("projectId")).toString(), reviewed.host, reviewed.repository,
                            reviewed.number);
    m_reviewThreads.setTarget(environmentId(), m_thread.mid(m_thread.indexOf(QLatin1Char(':')) + 1), reviewed.host, reviewed.repository,
                              reviewed.number, m_pullRequests.urlOf(activeTab().mid(kReviewTab.size())));
  }
  m_review.setActive(!reviewing.isEmpty());
  publish();
  save();
  emit changed();
}

void RightPanelController::publish() {
  if (!m_onThread) {
    m_publishedThread.clear();
    m_bridge->publish(QStringLiteral("panel"), QVariant());
    return;
  }
  const Panel state = current();
  // Opening or closing within a thread slides for as long as the user set
  // (LayoutController); a thread's own layout, shown on arriving, snaps.
  int transitionMs = 0;
  if (m_thread == m_publishedThread && state.open != m_publishedOpen) {
    if (auto* layout = NativeShell::of(this)->controller<LayoutController>()) transitionMs = layout->panelAnimationMs();
  }
  m_publishedThread = m_thread;
  m_publishedOpen = state.open;
  const auto tabOf = [this, &state](const QString& id) {
    return QVariantMap{{QStringLiteral("id"), id},
                       {QStringLiteral("kind"), kindOf(id)},
                       {QStringLiteral("title"), state.titles.value(id, id.startsWith(kBrowserTab) ? browserTitle(id) : titleOf(id, m_devices))},
                       {QStringLiteral("dock"), state.stage.contains(id) ? QStringLiteral("stage") : QStringLiteral("panel")}};
  };
  QVariantList tabs;
  for (const QString& id : state.tabs) tabs.append(tabOf(id));
  QVariantList staged;
  for (const QString& id : state.stage.tabs) staged.append(tabOf(id));
  // Terminals need the thread's place.
  auto* terminals = NativeShell::of(this)->controller<TerminalController>();
  const bool canTerminal = terminals && terminals->available() && terminals->threadKey() == m_thread;
  m_bridge->publish(QStringLiteral("panel"),
                    QVariantMap{
                        {QStringLiteral("threadKey"), m_thread},
                        // The project whose Space files the tab offers: none on another MC,
                        // whose files this MC's Spaces do not follow.
                        {QStringLiteral("spaceProjectId"), environmentId() == m_client->environment() ? m_projectId : QString()},
                        {QStringLiteral("onWorktree"), m_onWorktree},
                        {QStringLiteral("isOpen"), state.open},
                        {QStringLiteral("transitionMs"), transitionMs},
                        {QStringLiteral("activeId"), state.active},
                        {QStringLiteral("floatingDevice"), state.floating.isEmpty() ? QVariant() : QVariant(state.floating)},
                        {QStringLiteral("tabs"), tabs},
                        {QStringLiteral("width"), m_width},
                        {QStringLiteral("stage"), state.stage.toVariant(staged)},
                        {QStringLiteral("shownTabs"), shownTabs()},
                        {QStringLiteral("detailsOpen"), state.details},
                        {QStringLiteral("details"), state.details ? QVariant(threadDetails()) : QVariant()},

                        {QStringLiteral("canAdd"),
                         QVariantMap{{QStringLiteral("diff"), true},
                                     {QStringLiteral("files"), !m_files.root().isEmpty()},
                                     {QStringLiteral("agents"), true},
                                     {QStringLiteral("terminal"), canTerminal},
                                     {QStringLiteral("pullRequests"), m_pullRequests.count() > 0},
                                     {QStringLiteral("pullRequest"), m_pullRequests.count() > 0},
                                     {QStringLiteral("previews"), true},
                                     {QStringLiteral("browser"), true},
                                     {QStringLiteral("device"), true}}},
                        // Why a kind cannot be added, for the Add menu to show under it.
                        {QStringLiteral("addReasons"),
                         QVariantMap{{QStringLiteral("files"), m_files.root().isEmpty() ? tr("Files are only available when a project is open.") : QString()},
                                     {QStringLiteral("pullRequests"), m_pullRequests.count() > 0 ? QString() : tr("No linked pull requests are available for this thread.")},
                                     {QStringLiteral("pullRequest"), m_pullRequests.count() > 0 ? QString() : tr("This thread's branch has no pull request yet.")}}},
                    });
}

// How a started thread is doing, for the details column's grouping:
// "running" (working or waiting on the user), "failed", else "finished".
static QString relationStatus(const sidebar::Thread& thread) {
  const QString status = sidebar::status(thread);
  if (status == QLatin1String("working") || status == QLatin1String("approval") || status == QLatin1String("input")) return QStringLiteral("running");
  if (status == QLatin1String("failed") || status == QLatin1String("limited")) return QStringLiteral("failed");
  return QStringLiteral("finished");
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
                                 {QStringLiteral("relation"), thread.subagent ? QStringLiteral("Subagent") : QStringLiteral("Fork")},
                                 {QStringLiteral("status"), relationStatus(thread)}});
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

// The store: {width, threads: [{threadKey, open, tabs, active, details,
// titles, stage (PanelStage::toJson), dismissed (device tabs the user closed)}]},
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
                         : tab.startsWith(kDeviceTab)          ? !ThreadDevices::targetOf(tab).first.isEmpty()
                                                                : kind != QLatin1String("terminal") && nativeKinds.contains(kind);
      if (known && !state.tabs.contains(tab)) state.tabs.append(tab);
    }
    // A browser tab on the stage comes back there: the MC's list keeps it
    // once the thread shows, or takes it off (followBrowserTabs).
    state.stage = PanelStage::fromJson(thread.value(QLatin1String("stage")).toObject(), [this, &state](const QString& id) {
      return state.tabs.contains(id) || (m_previews.embedded() && id.startsWith(kBrowserTab));
    });
    for (const QString& id : std::as_const(state.stage.tabs)) {
      if (!state.tabs.contains(id)) state.tabs.append(id);
    }
    const QStringList docked = panelTabs(state);
    state.active = thread.value(QLatin1String("active")).toString();
    if (!docked.contains(state.active)) state.active = docked.value(0);
    state.open = thread.value(QLatin1String("open")).toBool() && !docked.isEmpty();
    state.details = thread.value(QLatin1String("details")).toBool();
    for (const QJsonValue& id : thread.value(QLatin1String("dismissed")).toArray()) state.dismissed.append(id.toString());
    const QJsonObject titles = thread.value(QLatin1String("titles")).toObject();
    for (auto it = titles.begin(); it != titles.end(); ++it) {
      if (state.tabs.contains(it.key()) && !it.value().toString().isEmpty()) state.titles.insert(it.key(), it.value().toString());
    }
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
    // Browser tabs are the MC's, listed again when the thread shows (the
    // stage's are kept, for the list to put back there).
    for (const QString& id : state.tabs) {
      if (kindOf(id) != QLatin1String("terminal") && kindOf(id) != QLatin1String("browser")) tabs.append(id);
    }
    PanelStage stage = state.stage;
    for (const QString& id : state.stage.tabs) {
      if (kindOf(id) == QLatin1String("terminal")) stage.remove(id);
    }
    if (tabs.isEmpty() && stage == PanelStage() && !state.details) continue;
    const bool terminalShown = kindOf(state.active) == QLatin1String("terminal") || kindOf(state.active) == QLatin1String("browser");
    QJsonObject titles;
    for (auto it = state.titles.begin(); it != state.titles.end(); ++it) titles.insert(it.key(), it.value());
    threads.prepend(QJsonObject{{QStringLiteral("threadKey"), threadKey},
                                {QStringLiteral("open"), state.open},
                                {QStringLiteral("tabs"), tabs},
                                {QStringLiteral("active"), terminalShown ? QJsonValue() : QJsonValue(state.active)},
                                {QStringLiteral("details"), state.details},
                                {QStringLiteral("titles"), titles},
                                {QStringLiteral("stage"), stage.toJson()},
                                {QStringLiteral("dismissed"), QJsonArray::fromStringList(state.dismissed)}});
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
