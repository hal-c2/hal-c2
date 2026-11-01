// WorkspaceController's choice of where a new thread works, with the composer's
// models beside it: the user picks the current checkout, a new worktree or the
// previous worktree, picks a second model and drops it, flips the switch for
// starting from origin, and the "Start new worktrees from origin" setting
// changes meanwhile.
//
// The model: several models fix the choice on a new worktree and offer nothing
// else. Otherwise the choice is the user's. Coming to a new worktree takes the
// setting's word on origin, the switch overrides it for this draft, and neither
// ever writes the setting.

#include "Prop.h"

#include <QJsonArray>
#include <QTemporaryDir>

#include <memory>

#include "ComposerController.h"
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

const QString kWorktree = QStringLiteral("/work/p1-worktrees/tax");
const QString kSetting = QStringLiteral("newWorktreesStartFromOrigin");

enum class Where { Checkout, New, Previous };

struct Model {
  Where where = Where::Checkout;
  bool severalModels = false;
  bool setting = true;  // the setting's default
  bool fromOrigin = false;

  void comesToNew() {
    if (where != Where::New) fromOrigin = setting;
    where = Where::New;
  }
};

struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
  QJsonObject settings;
  int settingsSaves = 0;
  int version = 0;

  Sut() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), settings}, {QStringLiteral("providers"), providers()}}}});
    });
    mc.onRpc(QStringLiteral("hal-c2.readSettings"), [this](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("settings"), settings}, {QStringLiteral("version"), version}});
    });
    mc.onRpc(QStringLiteral("hal-c2.writeSettings"), [this](const FakeMc::Rpc& rpc) {
      settingsSaves++;
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")}, {QStringLiteral("title"), QStringLiteral("p1")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")}, {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")}, {QStringLiteral("title"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")}, {QStringLiteral("worktreePath"), kWorktree},
                                                        {QStringLiteral("branch"), QStringLiteral("feature/tax")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-10-16T08:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-10-16T08:00:00Z")}});
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return native->isActive() && native->store()->synchronized(); }));
    native->controller<DraftController>()->start(mc.environmentId, QStringLiteral("p1"));
    RC_ASSERT(prop::until([this] { return state().value(QStringLiteral("isDraft")).toBool() && !state().value(QStringLiteral("previousWorktree")).isNull(); }));
    RC_ASSERT(prop::until([this] { return !bridge.state()->value(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList().isEmpty(); }));
    bridge.dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}});
  }

  static QJsonArray providers() {
    const auto provider = [](const QString& id, const QString& model) {
      return QJsonObject{{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), id}, {QStringLiteral("displayName"), id},
                         {QStringLiteral("enabled"), true}, {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")},
                         {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), model}, {QStringLiteral("name"), model}}}}};
    };
    return {provider(QStringLiteral("codex"), QStringLiteral("gpt-5")), provider(QStringLiteral("claudeAgent"), QStringLiteral("claude-opus"))};
  }

  QVariantMap state() const { return bridge.state()->value(QStringLiteral("workspace")).toMap(); }

  // What the shell shows is what the model has.
  void matches(const Model& model) const {
    const QVariantMap now = state();
    RC_ASSERT(now.value(QStringLiteral("envModeChangeable")).toBool() == !model.severalModels);
    RC_ASSERT(now.value(QStringLiteral("previousWorktree")).isNull() == (model.severalModels || model.where == Where::Previous));
    RC_ASSERT(!now.value(QStringLiteral("envModeHint")).toString().isEmpty() == model.severalModels);
    const QString label = model.where == Where::New ? QStringLiteral("New worktree") : model.where == Where::Previous ? QStringLiteral("Current worktree") : QStringLiteral("Current checkout");
    RC_ASSERT(now.value(QStringLiteral("envModeLabel")).toString() == label);
    if (model.where == Where::New) RC_ASSERT(now.value(QStringLiteral("startFromOrigin")).toBool() == model.fromOrigin);
    RC_ASSERT(settingsSaves == 0);
  }
};

using Command = rc::state::Command<Model, Sut>;

struct ChooseMode : Command {
  explicit ChooseMode(const Model&) {}
  bool worktree = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (model.severalModels) return;
    if (worktree) {
      model.comesToNew();
    } else if (model.where == Where::New) {
      model.where = Where::Checkout;
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.bridge.dispatch(QStringLiteral("workspace.envMode.set"), QVariantMap{{QStringLiteral("mode"), worktree ? QStringLiteral("worktree") : QStringLiteral("local")}});
    sut.matches(next);
  }
  void show(std::ostream& os) const override { os << "ChooseMode(" << (worktree ? "worktree" : "local") << ")"; }
};

struct UsePrevious : Command {
  explicit UsePrevious(const Model&) {}
  void apply(Model& model) const override {
    if (!model.severalModels) model.where = Where::Previous;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.bridge.dispatch(QStringLiteral("workspace.previousWorktree"));
    sut.matches(next);
  }
  void show(std::ostream& os) const override { os << "UsePrevious"; }
};

struct ToggleSecondModel : Command {
  explicit ToggleSecondModel(const Model&) {}
  void apply(Model& model) const override {
    if (!model.severalModels) model.comesToNew();
    model.severalModels = !model.severalModels;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.bridge.dispatch(QStringLiteral("composer.model.multiple.toggle"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), QStringLiteral("claude-opus")}});
    sut.matches(next);
  }
  void show(std::ostream& os) const override { os << "ToggleSecondModel"; }
};

struct Flip : Command {
  explicit Flip(const Model&) {}
  bool enabled = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(model.where == Where::New); }
  void apply(Model& model) const override { model.fromOrigin = enabled; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.bridge.dispatch(QStringLiteral("workspace.startFromOrigin.set"), QVariantMap{{QStringLiteral("enabled"), enabled}});
    sut.matches(next);
  }
  void show(std::ostream& os) const override { os << "Flip(" << enabled << ")"; }
};

struct ChangeSetting : Command {
  explicit ChangeSetting(const Model&) {}
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.setting = on; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.settings.insert(kSetting, on);
    sut.version++;
    for (const int id : sut.mc.subscribers(QStringLiteral("config"))) {
      sut.mc.send({{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("id"), id}, {QStringLiteral("settings"), sut.settings}});
    }
    RC_ASSERT(prop::until([&] { return sut.native->controller<SettingsController>()->setting(kSetting).toBool() == on; }));
    sut.matches(next);
  }
  void show(std::ostream& os) const override { os << "ChangeSetting(" << on << ")"; }
};

}  // namespace

class WorkspaceChoiceProp : public QObject {
  Q_OBJECT

private slots:
  void model() {
    QVERIFY(rc::check("the workspace choice follows the models chosen, the setting and the user, and never writes the setting", [] {
      Sut sut;
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<ChooseMode, ChooseMode, UsePrevious, ToggleSecondModel, Flip, ChangeSetting>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceChoiceProp)
#include "tst_WorkspaceChoiceProp.moc"
