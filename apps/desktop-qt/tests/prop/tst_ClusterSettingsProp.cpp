// Settings → Cluster (ClusterController) against a fake MC whose cluster has
// two other machines, each connected or not and on this machine's version or
// an older one. The user opens and leaves the page, reads it again and sends
// this machine's version to the others; the machines come, go and update on
// their own; the MC holds its answers to give them one by one or all at once,
// so a read can land after a newer read, after the version was sent, or after
// the page was left and opened again. After every step the page shows the
// cluster as the latest read found it, says what the last sending did, and is
// busy exactly while one is out.

#include "Prop.h"

#include <QTemporaryDir>

#include <utility>

#include "ClusterController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

const QString kVersion = QStringLiteral("2.0");
const QStringList kVersions = {QStringLiteral("1.0"), kVersion};
const QStringList kMachines = {QStringLiteral("laptop"), QStringLiteral("studio")};
// The machine that cannot take a version from another one.
const QString kStuck = QStringLiteral("laptop");
const QString kRefusal = QStringLiteral("This MC cannot update itself.");

struct Machine {
  bool connected = true;
  QString version = QStringLiteral("1.0");
  bool operator==(const Machine&) const = default;
};
using Cluster = QMap<QString, Machine>;

Cluster initialCluster() {
  return {{QStringLiteral("laptop"), {}}, {QStringLiteral("studio"), {}}};
}

// What the update the MC answers did, as the page says it.
QString updated(Cluster& cluster) {
  QStringList lines;
  for (auto it = cluster.begin(); it != cluster.end(); ++it) {
    if (!it->connected || it->version == kVersion) continue;
    if (it.key() == kStuck) {
      lines.append(QStringLiteral("%1 could not update: %2").arg(it.key(), kRefusal));
    } else {
      lines.append(QStringLiteral("%1 updated to %2.").arg(it.key(), kVersion));
      it->version = kVersion;
    }
  }
  if (lines.isEmpty()) lines.append(QStringLiteral("Every machine already runs %1.").arg(kVersion));
  return lines.join(QLatin1Char(' '));
}

// A call the MC holds: a read of the cluster asked as the `asked`th request,
// or the update.
struct Held {
  bool update = false;
  int asked = 0;
};

struct Model {
  Cluster mc = initialCluster();
  bool open = false;
  Cluster shown = initialCluster();
  QString notice;
  bool busy = false;
  // Every read and update is a request; only the latest one's answer counts.
  int asked = 0;
  bool holding = false;
  QList<Held> held;

  void ask(Held call) {
    if (holding) held.append(call);
    else perform(call);
  }

  void read() { ask({false, ++asked}); }

  void perform(const Held& call) {
    if (!call.update) {
      if (call.asked == asked) shown = mc;
      return;
    }
    busy = false;
    notice = updated(mc);
    read();
  }
};

// The MC's cluster, held answers and all.
struct FakeCluster {
  Cluster machines = initialCluster();
  bool holding = false;
  QList<std::function<void()>> held;
};

// The app on a fake MC with a home of its own, on the General settings page.
struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  FakeCluster cluster;
  QSet<QString> reached;

  Shell() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onRpc(QStringLiteral("cluster."), [this](const FakeMc::Rpc& rpc) {
      // The MC answers with the cluster as it is when it answers.
      auto answer = [this, rpc] {
        if (rpc.method == QLatin1String("cluster.update")) {
          mc.reply(rpc, updateResult());
        } else {
          mc.reply(rpc, status());
        }
      };
      if (cluster.holding) cluster.held.append(answer);
      else answer();
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.store()->synchronized(); })) qFatal("the shell did not start");
  }

  QJsonObject status() const {
    QJsonArray members;
    for (auto it = cluster.machines.begin(); it != cluster.machines.end(); ++it) {
      members.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("env-") + it.key()},
                                 {QStringLiteral("label"), it.key()},
                                 {QStringLiteral("addresses"), QJsonArray()},
                                 {QStringLiteral("version"), it->version},
                                 {QStringLiteral("connected"), it->connected}});
    }
    return {{QStringLiteral("clustered"), true},
            {QStringLiteral("id"), mc.environmentId},
            {QStringLiteral("label"), QStringLiteral("desk")},
            {QStringLiteral("mc"), mc.name},
            {QStringLiteral("addresses"), QJsonArray()},
            {QStringLiteral("version"), kVersion},
            {QStringLiteral("members"), members}};
  }

  // Each connected machine on another version takes this one, but the stuck one.
  QJsonObject updateResult() {
    QJsonArray members;
    for (auto it = cluster.machines.begin(); it != cluster.machines.end(); ++it) {
      if (!it->connected || it->version == kVersion) continue;
      const bool stuck = it.key() == kStuck;
      members.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("env-") + it.key()},
                                 {QStringLiteral("label"), it.key()},
                                 {QStringLiteral("from"), it->version},
                                 {QStringLiteral("outcome"), stuck ? kRefusal : QStringLiteral("updated")}});
      if (!stuck) it->version = kVersion;
    }
    return {{QStringLiteral("version"), kVersion}, {QStringLiteral("members"), members}};
  }

  void answerOne() { cluster.held.takeFirst()(); }

  void release() {
    cluster.holding = false;
    for (const auto& answer : std::exchange(cluster.held, {})) answer();
  }

  NavigationController* navigation() const { return native.controller<NavigationController>(); }
  QVariantMap page() const { return bridge.state()->value(QStringLiteral("cluster")).toMap(); }

  void open(bool cluster) {
    navigation()->open(NavigationController::Route::settings(cluster ? NavigationController::kClusterSection
                                                                     : QStringLiteral("/settings/general")));
  }

  // Waits for whatever the MC has sent so far to reach the page.
  void barrier() {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  // Off the page, nothing held, the cluster as it starts and the page having read it.
  Model reset() {
    open(false);
    release();
    barrier();
    RC_ASSERT(prop::until([this] { return !page().value(QStringLiteral("busy")).toBool(); }));
    cluster.machines = initialCluster();
    open(true);
    Model model;
    model.open = true;
    check(model);
    open(false);
    reached.clear();
    return {};
  }

  // The page as the model says it shows.
  bool shows(const Model& model) const {
    const QVariantMap state = page();
    Cluster shown;
    for (const QVariant& row : state.value(QStringLiteral("status")).toMap().value(QStringLiteral("members")).toList()) {
      const QVariantMap member = row.toMap();
      shown.insert(member.value(QStringLiteral("label")).toString(),
                   {member.value(QStringLiteral("connected")).toBool(), member.value(QStringLiteral("version")).toString()});
    }
    const QString notice = state.value(QStringLiteral("notice")).toMap().value(QStringLiteral("text")).toString();
    return shown == model.shown && notice == model.notice && state.value(QStringLiteral("busy")).toBool() == model.busy &&
           cluster.held.size() == model.held.size();
  }

  void check(const Model& model) {
    // A reply can prompt a read that reaches the MC a round trip later.
    RC_ASSERT(prop::until([&] { return shows(model); }));
    barrier();
    RC_ASSERT(shows(model));
  }
};

using Command = rc::state::Command<Model, Shell>;

// The user opens Cluster, or leaves for General. Opening reads it afresh and
// drops what the last sending said.
struct Open : Command {
  bool open = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    if (model.open == open) return;
    model.open = open;
    if (!open) return;
    model.notice.clear();
    model.read();
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.open(open);
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Open(" << open << ")"; }
};

struct Refresh : Command {
  void apply(Model& model) const override { model.read(); }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.bridge.dispatch(QStringLiteral("cluster.refresh"), {});
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Refresh"; }
};

// The user sends this machine's version to the others; the page offers it
// while it is open and nothing else is being sent.
struct Update : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.open && !model.busy); }
  void apply(Model& model) const override {
    model.busy = true;
    model.ask({true, ++model.asked});
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (model.held.size() > 0) shell.reached.insert(QStringLiteral("sent behind a read"));
    shell.bridge.dispatch(QStringLiteral("cluster.update"), {});
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Update"; }
};

// A machine connects, drops or moves to another version on its own.
struct Elsewhere : Command {
  QString machine = kMachines.at(*rc::gen::inRange<qsizetype>(0, kMachines.size()));
  bool connected = *rc::gen::arbitrary<bool>();
  QString version = kVersions.at(*rc::gen::inRange<qsizetype>(0, kVersions.size()));

  void apply(Model& model) const override { model.mc[machine] = {connected, version}; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.cluster.machines[machine] = {connected, version};
    shell.check(next);
  }
  void show(std::ostream& os) const override {
    os << "Elsewhere(" << machine.toStdString() << ", " << connected << ", " << version.toStdString() << ")";
  }
};

// The MC holds its cluster answers from here on.
struct Hold : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.holding); }
  void apply(Model& model) const override { model.holding = true; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.cluster.holding = true;
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// The MC answers the oldest call it holds, and holds on.
struct AnswerOne : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.held.isEmpty()); }
  void apply(Model& model) const override { model.perform(model.held.takeFirst()); }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    const Held& call = model.held.first();
    if (!call.update && call.asked != model.asked) shell.reached.insert(QStringLiteral("stale read"));
    if (call.update && model.held.size() > 1) shell.reached.insert(QStringLiteral("update before a read"));
    shell.answerOne();
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "AnswerOne"; }
};

// The MC answers everything it held, in order, and holds nothing more.
struct Release : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.holding); }
  void apply(Model& model) const override {
    model.holding = false;
    for (const Held& call : std::exchange(model.held, {})) model.perform(call);
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.release();
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Release"; }
};

}  // namespace

class ClusterSettingsProp : public QObject {
  Q_OBJECT

private slots:
  void page() {
    Shell shell;
    QVERIFY(rc::check("the cluster page is what the model says, however reads, sending the version and the MC interleave", [&shell] {
      const Model initial = shell.reset();
      shell.check(initial);
      rc::state::check(initial, shell,
                       rc::state::gen::execOneOfWithArgs<Open, Open, Refresh, Update, Update, Elsewhere, Elsewhere, Hold, AnswerOne, AnswerOne,
                                                                         Release>());
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("stale read")), "a read answered after a newer request");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("sent behind a read")), "the version sent while a read was out");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("update before a read")), "an update answered before a later read");
    }));
  }
};

HAL_C2_PROP_MAIN(ClusterSettingsProp)
#include "tst_ClusterSettingsProp.moc"
