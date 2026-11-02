// RightPanelController's tabs and a floating device, as a state machine over
// what the user does with them: opening a device, floating and bringing it
// back, opening and closing the panel, showing and closing tabs. A device
// floats only while the panel is closed and only while its tab exists, so the
// panel's active tab is always the one thing that shows and takes input.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadDevices.h"

#include <QTemporaryDir>

#include <algorithm>
#include <memory>

namespace prop = halc2::prop;

namespace {

const QStringList kTabs = {QStringLiteral("device:local:phone"), QStringLiteral("device:local:tablet"), QStringLiteral("diff"), QStringLiteral("agents")};
const QStringList kDevices = kTabs.mid(0, 2);

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

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};

  Shell() {
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
    if (!prop::until([this] { return native.isActive() && native.store()->threadOnline(QStringLiteral("env-a:t1")); })) qFatal("the shell did not start");
    native.controller<NavigationController>()->open(NavigationController::Route::thread(QStringLiteral("env-a:t1")));
  }

  RightPanelController* panel() { return native.controller<RightPanelController>(); }
  QVariantMap published() const { return bridge.state()->value(QStringLiteral("panel")).toMap(); }
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
};

HAL_C2_PROP_MAIN(RightPanelProp)
#include "tst_RightPanelProp.moc"
