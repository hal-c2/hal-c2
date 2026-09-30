#pragma once

#include <QHash>
#include <QObject>
#include <QStringList>
#include <QVariant>

#include "AgentsModel.h"
#include "NativeController.h"
#include "PullRequestReview.h"
#include "ThreadDiff.h"
#include "ThreadPreviews.h"
#include "ThreadDevices.h"
#include "ThreadPullRequests.h"
#include "WorkspaceFiles.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The right panel beside a thread, as the `Panel` QML singleton: whether it
// is open, which tabs it has and which one shows, per thread, and the thread
// details column beside it. Every tab is native: Diff, Files, Agents, Pull
// requests and Previews (`diff`, `files`, `agents`, `pull-requests`,
// `previews`), a Pull request review tab per linked pull request reviewed
// (`pull-request:<host>/<repository>#<number>`), the Device picker (`device`)
// and a tab per device streamed (`device:<host>:<device>`, ThreadDevices; an
// agent's device opens its tab unless the user closed it), and a terminal tab per
// terminal group TerminalController keeps for the panel (`terminal:<group>`;
// closing the tab closes its terminals).
//
// Each thread's panel (open, tabs, active tab, thread details shown) and the
// panel's width outlive a restart in the store file (setStorePath); terminal
// tabs do not, their terminals end with the app. Filling the window
// (maximized) lasts until the panel closes or the app quits.
//
// Publishes `panel` for the RightPanel brick, null away from a thread:
//   {threadKey, isOpen, activeId, tabs: [{id, kind, title}], width,
//    maximized, detailsOpen, details,
//    canAdd: {diff, files, agents, terminal, pullRequests, pullRequest,
//             previews, device}}
// (`pullRequests` and `pullRequest`, the review: the thread has linked ones.)
// `details`, while the thread details column shows, else null:
//   {environment, online, project, folder, checkout ("Local"|"Worktree"),
//    branch, relations: [{threadKey, title, relation}]}
// (its parent, and the forks and subagents it started).
//
// Actions: `rightPanel.toggle`, `rightPanel.activate {id}`,
// `rightPanel.close {id}`, `rightPanel.add {kind}`, `rightPanel.resize
// {width?}` (no width: the default), `rightPanel.toggleMaximized`,
// `threadPanel.toggle`, `rightPanel.openThread {threadKey}` (an Agents row's;
// the brick's), `rightPanel.review {key}` (a linked pull request's review), and
// `panel.open {tab: "diff"|"files", path?, line?, turn?, turnId?}` (the
// timeline's "view diff" and file links): opens the panel on that tab, the
// diff on a turn (its number, or the run it finished) scrolled to `path`, or
// `path` in the file viewer at `line`. Keybinding commands: rightPanel.toggle,
// rightPanel.close (the active tab), rightPanel.toggleMaximized,
// threadPanel.toggle, diff.toggle, preview.toggle and pullRequest.copyNumber
// (the reviewed pull request's); palette commands:
// thread.showPullRequests and thread.linkPullRequest (the Pull requests tab
// with its link field open).
class RightPanelController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(ThreadDiff* diff READ diff CONSTANT)
  Q_PROPERTY(WorkspaceFiles* files READ files CONSTANT)
  Q_PROPERTY(AgentsModel* agents READ agents CONSTANT)
  Q_PROPERTY(ThreadPullRequests* pullRequests READ pullRequests CONSTANT)
  Q_PROPERTY(ThreadPreviews* previews READ previews CONSTANT)
  Q_PROPERTY(PullRequestReview* review READ review CONSTANT)
  Q_PROPERTY(ThreadDevices* device READ device CONSTANT)

public:
  // The tab kinds; each has a brick in js/panelTabs.js.
  static inline const QStringList nativeKinds{QStringLiteral("diff"), QStringLiteral("files"), QStringLiteral("agents"),
                                              QStringLiteral("terminal"), QStringLiteral("pull-requests"),
                                              QStringLiteral("previews"), QStringLiteral("pull-request"),
                                              QStringLiteral("device")};
  // A tab's kind: its id, `terminal` for `terminal:<group>`, `pull-request`
  // for `pull-request:<key>`, or `device` for `device:<host>:<device>`.
  static QString kindOf(const QString& id);
  // The panel's width when nothing was chosen, and the least it can be.
  static constexpr int defaultWidth = 540;
  static constexpr int minimumWidth = 360;

  RightPanelController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  // The file each thread's panel is kept in, read now.
  void setStorePath(const QString& path);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  ThreadDiff* diff() { return &m_diff; }
  WorkspaceFiles* files() { return &m_files; }
  AgentsModel* agents() { return &m_agents; }
  ThreadPullRequests* pullRequests() { return &m_pullRequests; }
  ThreadPreviews* previews() { return &m_previews; }
  PullRequestReview* review() { return &m_review; }
  ThreadDevices* device() { return &m_devices; }

  bool isOpen() const;
  QString activeTab() const;
  // Every tab of the shown thread, in the order they were added.
  QStringList tabIds() const;
  int width() const { return m_width; }
  bool isMaximized() const;
  bool detailsOpen() const;

  // Opens or closes the panel (the header button, mod+alt+b). Opening a
  // panel with no tabs opens the Diff tab.
  Q_INVOKABLE void toggle();
  Q_INVOKABLE void setOpen(bool open);
  // Opens the panel on `tab` (diff or files) with the options of `panel.open`.
  Q_INVOKABLE void open(const QString& tab, const QVariantMap& options = {});
  Q_INVOKABLE void showTab(const QString& id);
  // Closes a tab (empty: the active one); the last one closes the panel.
  Q_INVOKABLE void closeTab(const QString& id = {});
  // diff, files, agents, terminal, pull-requests, previews, device (the
  // picker), or pull-request (the review of the thread's first open linked
  // pull request).
  Q_INVOKABLE void addTab(const QString& kind);
  // The review tab of a linked pull request ("host/repository#number").
  Q_INVOKABLE void reviewPullRequest(const QString& key);
  // The width the user dragged the panel's edge to (at least minimumWidth;
  // the brick keeps the thread its room), and back to the default.
  Q_INVOKABLE void setWidth(int width);
  Q_INVOKABLE void resetWidth();
  // The open panel fills the window, or goes back beside the thread.
  Q_INVOKABLE void toggleMaximized();
  // Shows or hides the thread details column (mod+alt+t).
  Q_INVOKABLE void toggleDetails();
  // Keeps the Files tab's tree loaded while it is shown outside the panel
  // (XrFiles, the XR workspace's files).
  Q_INVOKABLE void setFilesShownElsewhere(bool shown);
  // Shows the Diff tab, or closes the panel when it is showing (mod+d).
  Q_INVOKABLE void toggleDiff();
  // Shows the Previews tab, or closes the panel when it is showing.
  Q_INVOKABLE void togglePreviews();
  // The Pull requests tab with its link field open.
  Q_INVOKABLE void linkPullRequest();
  // Opens a subagent's thread (an Agents row's childThreadKey).
  Q_INVOKABLE void openThread(const QString& threadKey);

signals:
  void changed();

private:
  struct Panel {
    bool open = false;
    // In the order they were added.
    QStringList tabs;
    QString active;
    bool maximized = false;
    bool details = false;
    // Device tabs the user closed: an agent opening the device again does not
    // bring them back.
    QStringList dismissed;
  };

  Panel& panel() { return m_panels[m_thread]; }
  Panel current() const { return m_panels.value(m_thread); }
  // The shown thread's terminal groups in the panel.
  QStringList terminalGroups() const;
  void retarget();
  // What the palette shows of the thread's pull request commands.
  void presentCommands();
  void update();
  void publish();
  QVariantMap threadDetails() const;
  void save();
  // A device's tab, in place of the picker (ThreadDevices::opened).
  void openDevice(const QString& id, bool automatic);
  static bool removeTab(Panel& state, const QString& id);
  // Closes `id` in `threadKey`'s panel, shown or not (ThreadDevices::closed).
  void closeTabIn(const QString& threadKey, const QString& id);

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  ThreadDiff m_diff;
  WorkspaceFiles m_files;
  AgentsModel m_agents;
  ThreadPullRequests m_pullRequests;
  ThreadPreviews m_previews;
  PullRequestReview m_review;
  ThreadDevices m_devices;
  bool m_active = false;
  // The thread the panel shows; kept while the route is elsewhere (settings)
  // so coming back finds the tabs as they were.
  QString m_thread;
  bool m_onThread = false;
  bool m_filesShownElsewhere = false;
  QHash<QString, Panel> m_panels;
  // Threads by when their panel was last shown, the latest last: the store
  // keeps the latest kStoredThreads.
  QStringList m_recent;
  int m_width = defaultWidth;
  QString m_storePath;
  QByteArray m_saved;
};
