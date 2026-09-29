#pragma once

#include <QHash>
#include <QObject>
#include <QStringList>
#include <QVariant>

#include "NativeController.h"
#include "ThreadDiff.h"
#include "WorkspaceFiles.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The right panel beside a thread, as the `Panel` QML singleton: whether it
// is open and which tab shows, per thread (in memory; a thread seen for the
// first time starts closed). The Diff and Files tabs are native (`diff`,
// `files`); every other tab (terminal, pull request, preview, device) is still
// the page's, taken from the `rightPanel` state the page publishes and shown
// in the page's embed.
//
// Publishes `panel` for the RightPanel brick, null away from a thread:
//   {threadKey, isOpen, activeId, tabs: [{id, kind, title, native}],
//    canAdd: {diff, files, terminal, pullRequest}, embedPath}
//
// Actions: `rightPanel.toggle`, `rightPanel.activate {id}`,
// `rightPanel.close {id}`, `rightPanel.add {kind}` (the brick's), and
// `panel.open {tab: "diff"|"files", path?, line?, turn?, turnId?}` (the
// timeline's "view diff" and file links): opens the panel on that tab, the
// diff on a turn (its number, or the run it finished) scrolled to `path`, or
// `path` in the file viewer at `line`. Keybinding commands: rightPanel.toggle,
// rightPanel.close (the active tab) and diff.toggle.
//
// The page follows: `rightPanel.follow {threadKey, open, activeSurfaceId}`
// keeps its panel open only while one of its tabs shows, so it does no work
// behind a native tab. A change the page makes on its own (its keybinding,
// its "view diff", a tab it added) is taken as the user's.
class RightPanelController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(ThreadDiff* diff READ diff CONSTANT)
  Q_PROPERTY(WorkspaceFiles* files READ files CONSTANT)

public:
  // The tab kinds drawn natively; each has a brick in js/panelTabs.js.
  static inline const QStringList nativeKinds{QStringLiteral("diff"), QStringLiteral("files")};

  RightPanelController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  ThreadDiff* diff() { return &m_diff; }
  WorkspaceFiles* files() { return &m_files; }

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
  // diff, files, terminal or pull-request.
  Q_INVOKABLE void addTab(const QString& kind);
  // Shows the Diff tab, or closes the panel when it is showing (mod+d).
  Q_INVOKABLE void toggleDiff();

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
  bool isPageTab(const QString& id) const { return !id.isEmpty() && !nativeKinds.contains(id); }
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
