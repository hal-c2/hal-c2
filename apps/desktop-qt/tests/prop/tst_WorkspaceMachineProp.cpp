// WorkspaceController's choice of the machine a new thread runs on: a project
// with a checkout on this machine and another, the user picking either one or
// Auto balance, and the load-balancing setting turning on and off meanwhile.
//
// The model: Auto balance is offered only while balancing is on. A draft starts
// untied on its own machine; picking a machine ties it there, Auto balance
// unties it again. The composer marks the one current choice, and the launch
// goes to the machine the draft is on, tied unless the MC may place it.

#include "Prop.h"

#include <QJsonArray>
#include <QTemporaryDir>

#include <memory>

#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "WorkspaceController.h"

namespace prop = halc2::prop;

namespace {

const QString kOther = QStringLiteral("env-b");
const QString kSetting = QStringLiteral("loadBalancingEnabled");

struct Model {
  bool onOther = false;
  bool tied = false;
  bool balancing = false;
};

struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
  QJsonObject settings;
  QString draftId;

  Sut() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), settings}}}});
    });
    mc.onRpc(QStringLiteral("hal-c2.readSettings"), [this](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("settings"), settings}, {QStringLiteral("version"), 0}});
    });
    mc.label = QStringLiteral("laptop");
    mc.projects.insert(QStringLiteral("p1"), checkout(QStringLiteral("p1"), QStringLiteral("/work/shop")));
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return native->isActive() && native->store()->synchronized(); }));
    // The other machine joins the cluster with its own checkout of the repository.
    mc.peerLabels.insert(kOther, QStringLiteral("server"));
    mc.sendPeerRow(kOther, QStringLiteral("p9"), checkout(QStringLiteral("p9"), QStringLiteral("/srv/shop")), QStringLiteral("project"));
    mc.join(QStringLiteral("mc-b"), kOther);
    draftId = native->controller<DraftController>()->start(mc.environmentId, QStringLiteral("p1"));
    RC_ASSERT(prop::until([this] { return environments().size() == 2; }));
  }

  static QJsonObject checkout(const QString& id, const QString& root) {
    return {{QStringLiteral("id"), id},
            {QStringLiteral("title"), QStringLiteral("shop")},
            {QStringLiteral("workspaceRoot"), root},
            {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}}},
            {QStringLiteral("scripts"), QJsonArray()}};
  }

  QVariantList environments() const {
    return bridge.state()->value(QStringLiteral("workspace")).toMap().value(QStringLiteral("environments")).toList();
  }

  QString keyOf(const QString& environmentId) const {
    for (const QVariant& choice : environments()) {
      if (choice.toMap().value(QStringLiteral("environmentId")).toString() == environmentId) return choice.toMap().value(QStringLiteral("key")).toString();
    }
    return {};
  }

  void pick(const QString& key) {
    bridge.dispatch(QStringLiteral("workspace.environment.set"), QVariantMap{{QStringLiteral("key"), key}});
  }

  // What the composer offers and what a send would launch is what the model has.
  bool shows(const Model& model) const {
    const QVariantList choices = environments();
    const bool offered = !choices.isEmpty() && choices.first().toMap().value(QStringLiteral("key")) == QLatin1String("auto");
    if (offered != model.balancing || choices.size() != (model.balancing ? 3 : 2)) return false;
    const bool balanced = model.balancing && !model.tied;
    const QString machine = model.onOther ? kOther : mc.environmentId;
    int current = 0;
    for (const QVariant& choice : choices) {
      const QVariantMap entry = choice.toMap();
      if (!entry.value(QStringLiteral("current")).toBool()) continue;
      current++;
      const bool expected = balanced ? entry.value(QStringLiteral("key")) == QLatin1String("auto")
                                     : entry.value(QStringLiteral("environmentId")).toString() == machine;
      if (!expected) return false;
    }
    if (current != 1) return false;
    const WorkspaceController::Launch launch = native->controller<WorkspaceController>()->launch(draftId);
    return launch.environmentId == machine && launch.tied == model.tied && launch.problem.isEmpty();
  }
};

using Command = rc::state::Command<Model, Sut>;

struct PickMachine : Command {
  explicit PickMachine(const Model&) {}
  bool other = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.onOther = other;
    model.tied = true;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.pick(sut.keyOf(other ? kOther : sut.mc.environmentId));
    RC_ASSERT(prop::until([&] { return sut.shows(next); }));
  }
  void show(std::ostream& os) const override { os << "PickMachine(" << (other ? "other" : "own") << ")"; }
};

struct ChooseAutoBalance : Command {
  explicit ChooseAutoBalance(const Model&) {}
  void apply(Model& model) const override {
    if (!model.balancing) return;
    model.onOther = false;
    model.tied = false;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.pick(QStringLiteral("auto"));
    RC_ASSERT(prop::until([&] { return sut.shows(next); }));
  }
  void show(std::ostream& os) const override { os << "ChooseAutoBalance"; }
};

struct ChangeSetting : Command {
  explicit ChangeSetting(const Model&) {}
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.balancing = on; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.settings.insert(kSetting, on);
    for (const int id : sut.mc.subscribers(QStringLiteral("config"))) {
      sut.mc.send({{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("id"), id}, {QStringLiteral("settings"), sut.settings}});
    }
    RC_ASSERT(prop::until([&] { return sut.shows(next); }));
  }
  void show(std::ostream& os) const override { os << "ChangeSetting(" << on << ")"; }
};

}  // namespace

class WorkspaceMachineProp : public QObject {
  Q_OBJECT

private slots:
  void model() {
    QVERIFY(rc::check("the machine choice follows the user's picks and the balancing setting, and the launch follows the choice", [] {
      Sut sut;
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<PickMachine, ChooseAutoBalance, ChangeSetting>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceMachineProp)
#include "tst_WorkspaceMachineProp.moc"
