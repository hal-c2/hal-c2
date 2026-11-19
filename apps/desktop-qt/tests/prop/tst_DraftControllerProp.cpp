// DraftController as machines leave the cluster, against a fake MC. The
// machine joins with a project and leaves, removed from here or from another
// client; the user writes drafts for it and for this machine, goes home (which
// lands on the most recent project's draft) and removes the machine in Cluster
// settings, the MC holding each answer to give it before or after it says the
// machine went. After every step the drafts the user wrote are kept until
// their machine is removed, and nothing at all is kept for a machine that went
// (hal-c2#1589).

#include "Prop.h"

#include <QTemporaryDir>

#include <utility>

#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

const QString kBox = QStringLiteral("Build box");
const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");
// The machine's project is the most recent, so home lands on its draft.
const QString kLater = QStringLiteral("2026-09-24T09:00:00Z");

QJsonObject project(const QString& id, const QString& at) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("title"), id},
          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + id},
          {QStringLiteral("scripts"), QJsonArray()},
          {QStringLiteral("createdAt"), at},
          {QStringLiteral("updatedAt"), at}};
}

struct Model {
  bool joined = false;
  // The removals the MC has not answered yet.
  int asked = 0;
  // The drafts the user wrote, per machine.
  int local = 0;
  int box = 0;
};

// The app on a fake MC with a project of its own, on a home of its own.
struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QList<FakeMc::Rpc> removals;
  QSet<QString> reached;

  Shell() {
    mc.projects.insert(QStringLiteral("shop"), project(QStringLiteral("shop"), kAt));
    mc.onRpc(QStringLiteral("cluster."), [this](const FakeMc::Rpc& rpc) {
      if (rpc.method == QLatin1String("cluster.remove")) removals.append(rpc);
      else mc.reply(rpc, QJsonObject());
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.store()->synchronized(); })) qFatal("the shell did not start");
  }

  DraftController* drafts() const { return native.controller<DraftController>(); }
  ShellStore* store() { return native.store(); }

  // Waits for whatever the MC has sent so far to reach the shell.
  void barrier() {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  // The drafts kept for the environment, and how many of them the user wrote in.
  std::pair<int, int> kept(const QString& environment) const {
    int all = 0;
    int written = 0;
    for (const DraftController::Draft& draft : drafts()->drafts()) {
      if (draft.environmentId != environment) continue;
      ++all;
      if (!draft.text.isEmpty()) ++written;
    }
    return {all, written};
  }

  void check(const Model& model) {
    barrier();
    RC_ASSERT(store()->servesEnvironment(kBox) == model.joined);
    RC_ASSERT(int(removals.size()) == model.asked);
    const auto [box, boxWritten] = kept(kBox);
    RC_ASSERT(kept(mc.environmentId).second == model.local);
    RC_ASSERT(boxWritten == model.box);
    // Not even an empty draft is kept for a machine that went.
    if (!model.joined) RC_ASSERT(box == 0);
  }

  // Nothing held, the machine gone, no drafts, and the window home.
  Model reset() {
    for (const FakeMc::Rpc& rpc : std::exchange(removals, {})) mc.reply(rpc, QJsonObject());
    if (mc.peers.contains(kBox)) mc.remove(kBox);
    barrier();
    RC_ASSERT(prop::until([this] { return !store()->servesEnvironment(kBox); }));
    for (const DraftController::Draft& draft : drafts()->drafts()) drafts()->remove(draft.id);
    native.controller<NavigationController>()->open(NavigationController::Route());
    Model model;
    check(model);
    return model;
  }
};

using Command = rc::state::Command<Model, Shell>;

// The machine joins the cluster with its project.
struct Join : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.joined); }
  void apply(Model& model) const override { model.joined = true; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.mc.join(kBox);
    shell.mc.sendPeerRow(kBox, QStringLiteral("ops"), project(QStringLiteral("ops"), kLater), QStringLiteral("project"));
    RC_ASSERT(prop::until([&shell] { return bool(shell.store()->project(kBox + QStringLiteral(":ops"))); }));
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Join"; }
};

// The user writes in the project's draft on this machine or on the other, and
// the window shows it.
struct Write : Command {
  bool box = *rc::gen::arbitrary<bool>();

  void checkPreconditions(const Model& model) const override { RC_PRE(!box || model.joined); }
  void apply(Model& model) const override {
    int& written = box ? model.box : model.local;
    // One draft per project, written in again.
    written = 1;
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    const QString id = box ? shell.drafts()->start(kBox, QStringLiteral("ops"))
                           : shell.drafts()->start(shell.mc.environmentId, QStringLiteral("shop"));
    RC_ASSERT(!id.isEmpty());
    shell.drafts()->setText(id, QStringLiteral("roll back the deploy"));
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Write(" << (box ? "Build box" : "here") << ")"; }
};

// The window goes home, which lands on the most recent project's draft.
struct Home : Command {
  void apply(Model&) const override {}
  void run(const Model& model, Shell& shell) const override {
    shell.native.controller<NavigationController>()->open(NavigationController::Route());
    shell.check(model);
  }
  void show(std::ostream& os) const override { os << "Home"; }
};

// The user removes the machine in Cluster settings; the MC holds its answer.
struct Remove : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.joined); }
  void apply(Model& model) const override { ++model.asked; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    RC_ASSERT(prop::until([&] { return int(shell.removals.size()) == next.asked; }));
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Remove"; }
};

// The MC answers the oldest removal, and the machine's drafts go.
struct Answer : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.asked > 0); }
  void apply(Model& model) const override {
    --model.asked;
    model.box = 0;
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (model.joined) shell.reached.insert(QStringLiteral("answered first"));
    else shell.reached.insert(QStringLiteral("answered after"));
    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Answer"; }
};

// The MC says the machine went, removed here or from another client, its rows
// and everything kept for it going with it.
struct Leave : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.joined); }
  void apply(Model& model) const override {
    model.joined = false;
    model.box = 0;
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.mc.remove(kBox);
    RC_ASSERT(prop::until([&shell] { return !shell.store()->servesEnvironment(kBox); }));
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Leave"; }
};

}  // namespace

class DraftControllerProp : public QObject {
  Q_OBJECT

private slots:
  void drafts() {
    Shell shell;
    QVERIFY(rc::check("nothing is kept for a machine that went, whichever comes first of the answer and its going", [&shell] {
      const Model initial = shell.reset();
      shell.reached.clear();
      rc::state::check(initial, shell,
                       rc::state::gen::execOneOfWithArgs<Join, Join, Write, Write, Home, Remove, Remove, Answer, Answer, Leave>());
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("answered first")), "a removal answered while the machine was listed");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("answered after")), "a removal answered after the machine went");
    }));
  }
};

HAL_C2_PROP_MAIN(DraftControllerProp)
#include "tst_DraftControllerProp.moc"
