#pragma once

#include <QHash>
#include <QObject>
#include <QStringList>
#include <QVariant>

#include "AgentsModel.h"
#include "NativeController.h"
#include "ThreadDiff.h"
#include "ThreadPreviews.h"
#include "ThreadPullRequests.h"
#include "WorkspaceFiles.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The right panel beside a thread, as the `Panel` QML singleton: whether it
// is open and which tab shows, per thread (in memory; a thread seen for the
// first time starts closed). The Diff, Files, Agents, Pull requests and
// Previews tabs are native (`diff`, `files`, `agents`, `pull-requests`,
// `previews`), and so are terminal tabs, one per terminal group
// TerminalController keeps for the panel (`terminal:<group>`; closing the tab
// closes its terminals). The page's browser tabs are not shown: Previews lists
// them and opens them in the user's browser. The other tabs (a pull request's
// review, device) are still the page's, taken from the `rightPanel` state the
// page publishes and shown in the page's embed.
//
// Publishes `panel` for the RightPanel brick, null away from a thread:
//   {threadKey, isOpen, activeId, tabs: [{id, kind, title, native}],
//    canAdd: {diff, files, agents, terminal, pullRequests, previews,
//             pullRequest}, embedPath}
// (`pullRequests`: the thread has linked ones; `pullRequest`: the page can
// open the linked one's review.)
//
// Actions: `rightPanel.toggle`, `rightPanel.activate {id}`,
// `rightPanel.close {id}`, `rightPanel.add {kind}`, `rightPanel.openThread
// {threadKey}` (an Agents row's; the brick's), and
// `panel.open {tab: "diff"|"files", path?, line?, turn?, turnId?}` (the
// timeline's "view diff" and file links): opens the panel on that tab, the
// diff on a turn (its number, or the run it finished) scrolled to `path`, or
// `path` in the file viewer at `line`. Keybinding commands: rightPanel.toggle,
// rightPanel.close (the active tab), diff.toggle and preview.toggle; palette
// commands: thread.showPullRequests and thread.linkPullRequest (the Pull
// requests tab with its link field open).
//
// The page follows: `rightPanel.follow {threadKey, open, activeSurfaceId}`
// keeps its panel open only while one of its tabs shows, so it does no work
// behind a native tab. A change the page makes on its own (its keybinding,
// its "view diff", a tab it added) is taken as the user's.
class RightPanelController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(ThreadDiff* diff READ diff CONSTANT)
  Q_PROPERTY(WorkspaceFiles* files READ files CONSTANT)
  Q_PROPERTY(AgentsModel* agents READ agents CONSTANT)
  Q_PROPERTY(ThreadPullRequests* pullRequests READ pullRequests CONSTANT)
  Q_PROPERTY(ThreadPreviews* previews READ previews CONSTANT)

public:
  // The tab kinds drawn natively; each has a brick in js/panelTabs.js.
  static inline const QStringList nativeKinds{QStringLiteral("diff"), QStringLiteral("files"), QStringLiteral("agents"),
                                              QStringLiteral("terminal"), QStringLiteral("pull-requests"),
                                              QStringLiteral("previews")};
  // A tab's kind: its id, or `terminal` for `terminal:<group>`.
  static QString kindOf(const QString& id);

  RightPanelController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  ThreadDiff* diff() { return &m_diff; }
  WorkspaceFiles* files() { return &m_files; }
  AgentsModel* agents() { return &m_agents; }
  ThreadPullRequests* pullRequests() { return &m_pullRequests; }
  ThreadPreviews* previews() { return &m_previews; }

  bool isOpen() const;
  QString activeTab() const;
  // Every tab of the shown thread, native ones first.
  QStringList tabIds() const;

  // Opens or closes the panel (the header button, mod+alt+b). Opening a
  // panel with no tabs opens the Diff tab.
  Q_INVOKABLE void toggle();
  Q_INVOKABLE void setOpen(bool open);
  // Opens the panel on `tab` (diff or files) with the options of `panel.open`.
  Q_INVOKABLE void open(const QString& tab, const QVariantMap& options = {});
  Q_INVOKABLE void showTab(const QString& id);
  // Closes a tab (empty: the active one); the last one closes the panel.
  Q_INVOKABLE void closeTab(const QString& id = {});
  // diff, files, agents, terminal, pull-requests, previews, or pull-request
  // (the page's review of the linked one).
  Q_INVOKABLE void addTab(const QString& kind);
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
    // The native tabs, in the order they were added.
    QStringList tabs;
    QString active;
  };

  Panel& panel() { return m_panels[m_thread]; }
  Panel current() const { return m_panels.value(m_thread); }
  bool isPageTab(const QString& id) const { return !id.isEmpty() && !nativeKinds.contains(kindOf(id)); }
  // The shown thread's terminal groups in the panel.
  QStringList terminalGroups() const;
  // The page's tabs of the shown thread that it still draws.
  QVariantList pageTabs() const;
  bool hasPageTab(const QString& id) const;
  void retarget();
  void onPage(const QVariant& value);
  void update();
  void follow();
  void publish();

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  ThreadDiff m_diff;
  WorkspaceFiles m_files;
  AgentsModel m_agents;
  ThreadPullRequests m_pullRequests;
  ThreadPreviews m_previews;
  bool m_active = false;
  // The thread the panel shows; kept while the route is elsewhere (settings)
  // so coming back finds the tabs as they were.
  QString m_thread;
  bool m_onThread = false;
  QHash<QString, Panel> m_panels;
  // The page's `rightPanel`, and what it was last told to show.
  QVariantMap m_page;
  QVariantMap m_told;
};
