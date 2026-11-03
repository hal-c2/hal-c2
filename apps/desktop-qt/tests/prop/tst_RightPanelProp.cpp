// RightPanelController's tabs and a floating device, as a state machine over
// what the user does with them: opening a device, floating and bringing it
// back, opening and closing the panel, showing and closing tabs. A device
// floats only while the panel is closed and only while its tab exists, so the
// panel's active tab is always the one thing that shows and takes input.
//
// The stage, too: tabs docked in the thread's centre, moved there and back,
// laid out in panes, focused and dismissed. Whatever the user does, every tab
// is docked in one place, the stage's panes show its own tabs once each, an
// open panel shows one of its tabs, and only what shows works (shownTabs).
// The app restarts, too, and the MC lists some of the thread's browser tabs:
// the stage comes back as it was, less the browser tabs the MC no longer has.
// A PanelStage on its own keeps the same laws and survives being saved.

#include "Prop.h"

#include "Browser.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "PanelStage.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadDevices.h"
#include "ThreadPreviews.h"

#include <QTemporaryDir>

#include <algorithm>
#include <memory>

namespace prop = halc2::prop;

namespace {

const QStringList kTabs = {QStringLiteral("device:local:phone"), QStringLiteral("device:local:tablet"), QStringLiteral("diff"), QStringLiteral("agents")};
const QStringList kDevices = kTabs.mid(0, 2);
// The thread's browser tabs on the MC, and the stage's tabs: those and the browser's.
const QStringList kBrowsers = {QStringLiteral("tab-1"), QStringLiteral("tab-2")};
const QStringList kStageTabs = kTabs + QStringList{QStringLiteral("browser:tab-1"), QStringLiteral("browser:tab-2")};
const QStringList kZones = {QStringLiteral("center"), QStringLiteral("left"), QStringLiteral("right"), QStringLiteral("top"), QStringLiteral("bottom")};

rc::Gen<QString> oneOf(const QStringList& values) {
  return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end()));
}

struct Model {
  QStringList tabs;
  QString active;
  bool open = false;
  QString floating;

  void show(const QString& id) {
    if (!tabs.contains(id)) tabs.append(id);
    active = id;
    open = true;
    floating.clear();
  }
};

// The app on a fake MC, looking at thread t1, kept in `home` across restarts.
// The MC lists `browsers` as t1's browser tabs.
struct Shell {
  struct App {
    FakeMc mc;
    ShellBridge bridge;
    NativeShell native{&bridge};
  };

  QTemporaryDir home;
  QStringList browsers;
  std::unique_ptr<App> app;

  explicit Shell(const QStringList& listed = {}) : browsers(listed) { start(); }

  void restart(const QStringList& listed) {
    app.reset();
    browsers = listed;
    start();
  }

  void start() {
    app = std::make_unique<App>();
    FakeMc& mc = app->mc;
    NativeShell& native = app->native;
    mc.onRpc(QStringLiteral("preview.list"), [this, &mc](const FakeMc::Rpc& rpc) {
      QJsonArray sessions;
      for (const QString& tabId : std::as_const(browsers)) {
        sessions.append(QJsonObject{{QStringLiteral("tabId"), tabId},
                                    {QStringLiteral("threadId"), QStringLiteral("t1")},
                                    {QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("url"), QStringLiteral("http://localhost:5173/")}}}});
      }
      mc.reply(rpc, QJsonObject{{QStringLiteral("sessions"), sessions}, {QStringLiteral("serverEpoch"), QStringLiteral("e1")}, {QStringLiteral("revision"), 1}});
    });
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("title"), QStringLiteral("Thread")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([&native] { return native.isActive() && native.store()->threadOnline(QStringLiteral("env-a:t1")); })) qFatal("the shell did not start");
    native.controller<NavigationController>()->open(NavigationController::Route::thread(QStringLiteral("env-a:t1")));
    // With the browser in the app, the MC's list of browser tabs is read.
    if (panel()->previews()->embedded() && !prop::until([this] { return panel()->previews()->status() == QLatin1String("ready"); })) {
      qFatal("the browser tabs were not listed");
    }
  }

  RightPanelController* panel() { return app->native.controller<RightPanelController>(); }
  QVariantMap published() const { return app->bridge.state()->value(QStringLiteral("panel")).toMap(); }
};

void check(const Model& model, Shell& shell) {
  const QVariantMap panel = shell.published();
  QStringList tabs;
  for (const QVariant& tab : panel.value(QStringLiteral("tabs")).toList()) tabs.append(tab.toMap().value(QStringLiteral("id")).toString());
  RC_ASSERT(tabs == model.tabs);
  RC_ASSERT(panel.value(QStringLiteral("activeId")).toString() == model.active);
  RC_ASSERT(panel.value(QStringLiteral("isOpen")).toBool() == model.open);
  const QString floating = panel.value(QStringLiteral("floatingDevice")).toString();
  RC_ASSERT(floating == model.floating);
  RC_ASSERT(floating.isEmpty() || (!model.open && model.tabs.contains(floating)));
}

using Command = rc::state::Command<Model, Shell>;

struct OpenDevice : Command {
  QString id = *oneOf(kDevices);
  void apply(Model& model) const override { model.show(id); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    emit shell.panel()->device()->opened(id, false);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "OpenDevice(" << id.toStdString() << ")"; }
};

struct Float : Command {
  QString id = *oneOf(kDevices);
  void apply(Model& model) const override {
    if (!model.tabs.contains(id)) return;
    model.floating = id;
    model.open = false;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    emit shell.panel()->device()->floated(id);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Float(" << id.toStdString() << ")"; }
};

struct Unfloat : Command {
  void apply(Model& model) const override {
    if (!model.floating.isEmpty()) model.show(model.floating);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(shell.panel()->handle(QStringLiteral("rightPanel.unfloat"), QVariantMap()));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Unfloat"; }
};

struct SetOpen : Command {
  bool open = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (open) {
      if (model.tabs.isEmpty()) {
        model.tabs.append(QStringLiteral("diff"));
        model.active = QStringLiteral("diff");
      } else if (!model.tabs.contains(model.active)) {
        model.active = model.tabs.first();
      }
      model.floating.clear();
    }
    model.open = open;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.panel()->setOpen(open);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "SetOpen(" << open << ")"; }
};

struct ShowTab : Command {
  QString id = *oneOf(kTabs);
  void apply(Model& model) const override { model.show(id); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.panel()->showTab(id);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "ShowTab(" << id.toStdString() << ")"; }
};

struct CloseTab : Command {
  QString id = *oneOf(kTabs);
  void apply(Model& model) const override {
    const qsizetype at = model.tabs.indexOf(id);
    if (at < 0) return;
    model.tabs.removeAt(at);
    if (model.floating == id) model.floating.clear();
    if (model.active != id) return;
    model.active = model.tabs.isEmpty() ? QString() : model.tabs.at(std::min(at, model.tabs.size() - 1));
    if (model.tabs.isEmpty()) model.open = false;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.panel()->closeTab(id);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "CloseTab(" << id.toStdString() << ")"; }
};

// The stage's laws on its own: panes match the layout, show the stage's tabs
// once each, and one shows while it has tabs; an empty stage is closed.
void checkStage(const PanelStage& stage) {
  RC_ASSERT(PanelStage::layouts.contains(stage.layout));
  RC_ASSERT(stage.panes.size() == PanelStage::paneCount(stage.layout));
  RC_ASSERT(stage.focused >= 0);
  RC_ASSERT(stage.focused < stage.panes.size());
  QStringList seen;
  for (const QString& tab : stage.panes) {
    if (tab.isEmpty()) continue;
    RC_ASSERT(stage.tabs.contains(tab));
    RC_ASSERT(!seen.contains(tab));
    seen.append(tab);
  }
  QStringList tabs = stage.tabs;
  RC_ASSERT(tabs.removeDuplicates() == 0);
  // The Timeline tab is chosen only across the centre.
  RC_ASSERT(!stage.timeline || stage.focus);
  if (stage.isEmpty()) {
    RC_ASSERT(stage.layout == QStringLiteral("single"));
    RC_ASSERT(!stage.focus);
    RC_ASSERT(stage.panes == QStringList{QString()});
  } else {
    RC_ASSERT(!seen.isEmpty());
  }
}

QStringList idsOf(const QVariant& tabs) {
  QStringList ids;
  for (const QVariant& tab : tabs.toList()) ids.append(tab.toMap().value(QStringLiteral("id")).toString());
  return ids;
}

// What the shell publishes, as the stage and the panel's own tabs.
struct Docked {
  QStringList tabs;
  QStringList panel;
  QString active;
  bool open = false;
  PanelStage stage;
  QStringList shown;

  explicit Docked(Shell& shell) {
    const QVariantMap published = shell.published();
    for (const QVariant& tab : published.value(QStringLiteral("tabs")).toList()) {
      const QVariantMap map = tab.toMap();
      tabs.append(map.value(QStringLiteral("id")).toString());
      if (map.value(QStringLiteral("dock")).toString() == QLatin1String("panel")) panel.append(tabs.last());
    }
    active = published.value(QStringLiteral("activeId")).toString();
    open = published.value(QStringLiteral("isOpen")).toBool();
    const QVariantMap staged = published.value(QStringLiteral("stage")).toMap();
    stage.tabs = idsOf(staged.value(QStringLiteral("tabs")));
    stage.panes = staged.value(QStringLiteral("panes")).toStringList();
    stage.layout = staged.value(QStringLiteral("layout")).toString();
    stage.focused = staged.value(QStringLiteral("focusedPane")).toInt();
    stage.focus = staged.value(QStringLiteral("focus")).toBool();
    stage.timeline = staged.value(QStringLiteral("timeline")).toBool();
    stage.chatWidth = staged.value(QStringLiteral("chatWidth")).toInt();
    shown = published.value(QStringLiteral("shownTabs")).toStringList();
    RC_ASSERT(stage == shell.panel()->stage());
  }
};

// Every tab is docked in one place; an open panel shows one of its own; only
// the stage's shown tabs (its focused pane's first) and the panel's work.
void checkDocked(const Docked& docked) {
  checkStage(docked.stage);
  for (const QString& id : docked.stage.tabs) RC_ASSERT(docked.tabs.contains(id));
  for (const QString& id : docked.tabs) RC_ASSERT(docked.panel.contains(id) != docked.stage.contains(id));
  RC_ASSERT(docked.active.isEmpty() || docked.panel.contains(docked.active));
  RC_ASSERT(!docked.open || !docked.active.isEmpty());
  QStringList shown = docked.stage.shown();
  if (docked.open) shown.append(docked.active);
  RC_ASSERT(docked.shown == shown);
}

struct Stage {};

using StageCommand = rc::state::Command<Stage, Shell>;

// Runs `step` on the shell; the stage keeps its laws, and `then` checks what
// the step did from what showed before and after it.
template <typename Step, typename Then>
void stageStep(Shell& shell, Step step, Then then) {
  const Docked before(shell);
  step(shell.panel());
  const Docked after(shell);
  checkDocked(after);
  then(before, after);
}

const auto unchangedTabs = [](const Docked& before, const Docked& after) { RC_ASSERT(after.tabs == before.tabs); };

struct StageShowTab : StageCommand {
  QString id = *oneOf(kStageTabs);
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [this](RightPanelController* panel) { panel->showTab(id); },
              [this](const Docked& before, const Docked& after) {
                // A browser tab the MC does not list is not there to show.
                if (id.startsWith(QLatin1String("browser:")) && !before.tabs.contains(id)) {
                  RC_ASSERT(after.tabs == before.tabs);
                  RC_ASSERT(after.stage == before.stage);
                  return;
                }
                RC_ASSERT(after.tabs.contains(id));
                RC_ASSERT(after.stage.contains(id) == before.stage.contains(id));
                // It shows where it is docked, on the stage in place of the timeline.
                if (after.stage.contains(id)) RC_ASSERT(after.stage.focusedTab() == id && !after.stage.timeline);
                else RC_ASSERT(after.open && after.active == id);
              });
  }
  void show(std::ostream& os) const override { os << "ShowTab(" << id.toStdString() << ")"; }
};

struct StageCloseTab : StageCommand {
  QString id = *oneOf(kStageTabs);
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [this](RightPanelController* panel) { panel->closeTab(id); },
              [this](const Docked& before, const Docked& after) {
                QStringList tabs = before.tabs;
                tabs.removeOne(id);
                RC_ASSERT(after.tabs == tabs);
              });
  }
  void show(std::ostream& os) const override { os << "CloseTab(" << id.toStdString() << ")"; }
};

struct StageSetOpen : StageCommand {
  bool open = *rc::gen::arbitrary<bool>();
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [this](RightPanelController* panel) { panel->setOpen(open); },
              [this](const Docked& before, const Docked& after) {
                RC_ASSERT(after.stage == before.stage);
                if (!open) RC_ASSERT(!after.open);
              });
  }
  void show(std::ostream& os) const override { os << "SetOpen(" << open << ")"; }
};

struct MoveToStage : StageCommand {
  QString id = *oneOf(kStageTabs);
  int pane = *rc::gen::inRange(-1, 4);
  QString zone = *oneOf(kZones);
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [this](RightPanelController* panel) { panel->moveToStage(id, pane, zone); },
              [this](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                RC_ASSERT(after.stage.contains(id) == before.tabs.contains(id));
                // It lands in the focused pane.
                if (before.tabs.contains(id)) RC_ASSERT(after.stage.focusedTab() == id);
              });
  }
  void show(std::ostream& os) const override { os << "MoveToStage(" << id.toStdString() << ", " << pane << ", " << zone.toStdString() << ")"; }
};

struct MoveToPanel : StageCommand {
  QString id = *oneOf(kStageTabs);
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [this](RightPanelController* panel) { panel->moveToPanel(id); },
              [this](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                RC_ASSERT(!after.stage.contains(id));
                if (before.stage.contains(id)) RC_ASSERT(after.open && after.active == id);
                else RC_ASSERT(after.stage == before.stage);
              });
  }
  void show(std::ostream& os) const override { os << "MoveToPanel(" << id.toStdString() << ")"; }
};

struct MoveTab : StageCommand {
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [](RightPanelController* panel) { panel->moveTab(); },
              [](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                // With the timeline away the stage's tab goes back; else the
                // panel's comes over.
                const QString staged = before.stage.focusedTab();
                if (before.stage.timelineHidden() && !staged.isEmpty()) {
                  RC_ASSERT(after.open && after.active == staged);
                } else if (before.open && !before.active.isEmpty()) {
                  RC_ASSERT(after.stage.focusedTab() == before.active && !after.stage.timeline);
                } else if (!staged.isEmpty()) {
                  RC_ASSERT(after.open && after.active == staged);
                }
              });
  }
  void show(std::ostream& os) const override { os << "MoveTab"; }
};

struct SetLayout : StageCommand {
  QString layout = *oneOf(PanelStage::layouts);
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [this](RightPanelController* panel) { panel->setStageLayout(layout); },
              [this](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                RC_ASSERT(after.stage.tabs == before.stage.tabs);
                if (before.stage.isEmpty()) return;
                RC_ASSERT(after.stage.layout == layout);
                RC_ASSERT(!after.stage.timeline);
                // The focused tab stays in view.
                if (!before.stage.focusedTab().isEmpty()) RC_ASSERT(after.stage.focusedTab() == before.stage.focusedTab());
              });
  }
  void show(std::ostream& os) const override { os << "SetLayout(" << layout.toStdString() << ")"; }
};

struct FocusPane : StageCommand {
  int pane = *rc::gen::inRange(-1, 5);
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [this](RightPanelController* panel) { panel->focusPane(pane); },
              [](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                RC_ASSERT(after.stage.panes == before.stage.panes);
              });
  }
  void show(std::ostream& os) const override { os << "FocusPane(" << pane << ")"; }
};

struct ToggleFocus : StageCommand {
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [](RightPanelController* panel) { panel->toggleFocus(); },
              [](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                RC_ASSERT(after.stage.focus == (!before.stage.isEmpty() && !before.stage.focus));
                // Across the centre it shows its tab.
                RC_ASSERT(!after.stage.timeline);
              });
  }
  void show(std::ostream& os) const override { os << "ToggleFocus"; }
};

struct ShowTimeline : StageCommand {
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [](RightPanelController* panel) { panel->showTimeline(); },
              [](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                RC_ASSERT(after.stage.panes == before.stage.panes);
                RC_ASSERT(after.stage.timeline == !before.stage.isEmpty());
                RC_ASSERT(!after.stage.timelineHidden());
              });
  }
  void show(std::ostream& os) const override { os << "ShowTimeline"; }
};

struct OpenInCentre : StageCommand {
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [](RightPanelController* panel) { panel->toggleMaximized(); },
              [](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                const QString staged = before.stage.focusedTab();
                if (before.stage.timelineHidden() && !staged.isEmpty()) {
                  RC_ASSERT(after.open && after.active == staged);
                } else if (before.open && !before.active.isEmpty()) {
                  RC_ASSERT(after.stage.timelineHidden() && after.stage.focusedTab() == before.active);
                }
              });
  }
  void show(std::ostream& os) const override { os << "OpenInCentre"; }
};

struct Dismiss : StageCommand {
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [](RightPanelController* panel) { panel->dismissStage(); },
              [](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                RC_ASSERT(after.stage.isEmpty());
                RC_ASSERT(after.stage.chatWidth == before.stage.chatWidth);
              });
  }
  void show(std::ostream& os) const override { os << "Dismiss"; }
};

struct ChatWidth : StageCommand {
  int width = *rc::gen::inRange(-50, 900);
  void run(const Stage&, Shell& shell) const override {
    stageStep(shell, [this](RightPanelController* panel) { panel->setChatWidth(width); },
              [this](const Docked& before, const Docked& after) {
                unchangedTabs(before, after);
                RC_ASSERT(after.stage.chatWidth == std::max(width, 0));
              });
  }
  void show(std::ostream& os) const override { os << "ChatWidth(" << width << ")"; }
};

// The app quits and starts again, the MC listing some of the browser tabs.
struct Restart : StageCommand {
  QStringList listed = [] {
    QStringList listed;
    for (const QString& tab : kBrowsers) {
      if (*rc::gen::arbitrary<bool>()) listed.append(tab);
    }
    return listed;
  }();
  void run(const Stage&, Shell& shell) const override {
    const Docked before(shell);
    shell.restart(listed);
    const Docked after(shell);
    checkDocked(after);
    // The stage is as it was, less what the MC no longer has; the browser
    // tabs are the MC's.
    PanelStage stage = before.stage;
    QStringList tabs;
    for (const QString& id : before.tabs) {
      if (!id.startsWith(QLatin1String("browser:"))) tabs.append(id);
    }
    for (const QString& tab : kBrowsers) {
      if (listed.contains(tab)) tabs.append(QStringLiteral("browser:") + tab);
      else stage.remove(QStringLiteral("browser:") + tab);
    }
    RC_ASSERT(after.stage == stage);
    QStringList sorted = after.tabs;
    sorted.sort();
    tabs.sort();
    RC_ASSERT(sorted == tabs);
  }
  void show(std::ostream& os) const override { os << "Restart(listing " << listed.join(QLatin1Char(',')).toStdString() << ")"; }
};

// A PanelStage driven directly, by the stage's own operations.
void stageOperation(PanelStage& stage) {
  const QString tab = *oneOf(kTabs);
  const int operation = *rc::gen::inRange(0, 7);
  switch (operation) {
  case 0: stage.add(tab, *rc::gen::inRange(-1, 4), *oneOf(kZones)); break;
  case 1: stage.place(tab, *rc::gen::inRange(-1, 4), *oneOf(kZones)); break;
  case 2: stage.show(tab); break;
  case 3: stage.remove(tab); break;
  case 4: stage.setLayout(*oneOf(PanelStage::layouts)); break;
  case 5:
    // Across the centre or beside it, the Timeline tab chosen or not.
    stage.focus = *rc::gen::arbitrary<bool>();
    stage.timeline = *rc::gen::arbitrary<bool>();
    stage.normalize();
    break;
  default: stage.focusPane(*rc::gen::inRange(-1, 5)); break;
  }
  // Showing, placing or laying out a stage tab chooses the panes again.
  if ((operation <= 2 && stage.contains(tab)) || (operation == 4 && !stage.isEmpty())) RC_ASSERT(!stage.timeline);
}

}  // namespace

class RightPanelProp : public QObject {
  Q_OBJECT

private slots:
  void floatingDevice() {
    QVERIFY(rc::check("a device floats only over a closed panel and with its tab there", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<OpenDevice, Float, Float, Unfloat, SetOpen, ShowTab, CloseTab>());
    }));
  }

  void stage() {
    // The browser in the app, for its tabs.
    Browser::setSupported(true);
    const auto unsupported = qScopeGuard([] { Browser::setSupported(false); });
    QVERIFY(rc::check("every tab is docked in one place and only what shows works", [] {
      Shell shell(kBrowsers);
      rc::state::check(Stage{}, shell,
                       rc::state::gen::execOneOfWithArgs<StageShowTab, StageShowTab, StageCloseTab, StageSetOpen, MoveToStage, MoveToStage, MoveToPanel, MoveTab,
                                                         SetLayout, FocusPane, ToggleFocus, ShowTimeline, OpenInCentre, Dismiss, ChatWidth, Restart>());
    }));
  }

  void stageLaws() {
    QVERIFY(rc::check("a stage keeps its laws and comes back as it was saved", [] {
      PanelStage stage;
      const int steps = *rc::gen::inRange(0, 30);
      for (int step = 0; step < steps; ++step) {
        stageOperation(stage);
        checkStage(stage);
      }
      stage.focus = !stage.isEmpty() && *rc::gen::arbitrary<bool>();
      stage.timeline = stage.focus && *rc::gen::arbitrary<bool>();
      RC_ASSERT(PanelStage::fromJson(stage.toJson(), [](const QString&) { return true; }) == stage);
      // A tab the shell no longer knows is dropped on the way back.
      const QString gone = *oneOf(kTabs);
      PanelStage without = stage;
      without.remove(gone);
      const PanelStage restored = PanelStage::fromJson(stage.toJson(), [&gone](const QString& id) { return id != gone; });
      checkStage(restored);
      RC_ASSERT(restored.tabs == without.tabs);
    }));
  }
};

HAL_C2_PROP_MAIN(RightPanelProp)
#include "tst_RightPanelProp.moc"
