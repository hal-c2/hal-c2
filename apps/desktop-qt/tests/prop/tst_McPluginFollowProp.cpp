// The plugin list's section for a cluster member (McPluginController) against
// a fake MC that may not know that member: the MC refuses its `plugins` shape
// as an unknown environment, as it does right after it restarts, until the
// cluster learns the member again and announces it. Whatever the order of
// that and of the member going offline and coming back, the member's section
// is there whenever it is online and the MC has known it since it was last
// announced, and never while it is offline.

#include "Prop.h"

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

const QString kLocal = QStringLiteral("env-a");
const QString kPeer = QStringLiteral("b");

QJsonObject plugin() {
  return {{QStringLiteral("id"), QStringLiteral("planner")},
          {QStringLiteral("name"), QStringLiteral("Planner")},
          {QStringLiteral("status"), QStringLiteral("running")},
          {QStringLiteral("revision"), QStringLiteral("r1")}};
}

struct Model {
  bool online = true;
  bool known = true;   // the MC answers the member's `plugins` shape
  bool listed = true;  // the member has a section
};

struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  bool known = true;

  Sut() {
    mc.join(kPeer);
    mc.onShape(QStringLiteral("plugins"), [this](int id, const QJsonObject& shape) {
      if (!known && shape.value(QLatin1String("environment")).toString() == kPeer) {
        mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("unknown environment")}});
        mc.forget(id);
        return;
      }
      mc.send({{QStringLiteral("t"), QStringLiteral("plugins")}, {QStringLiteral("id"), id}, {QStringLiteral("plugins"), QJsonArray{plugin()}}});
    });
    mc.onRpc(QStringLiteral("plugins.file"), [this](const FakeMc::Rpc& rpc) { mc.refuse(rpc, QStringLiteral("no files")); });
    mc.onRpc(QStringLiteral("test.barrier"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });
  }

  // A fresh shell, the member online and known.
  void reset() {
    native.reset();
    bridge.reset();
    QDir(home.path()).removeRecursively();
    known = true;
    mc.setOnline(kPeer, true);
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native->isActive() && native->store()->synchronized(); })) qFatal("the shell did not start");
    // The model starts with both sections listed: a shape still on its way
    // when the first command runs could otherwise meet a forgetful MC.
    if (!prop::until([this] { return listed(kLocal) && listed(kPeer); })) qFatal("the sections were not listed");
  }

  // Waits for what the MC has sent so far to reach the shell.
  void barrier() {
    bool done = false;
    native->client()->call(native.get(), kLocal, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  bool listed(const QString& environment) const {
    const QVariantList environments = bridge->state()->value(QStringLiteral("mcPlugins")).toMap().value(QStringLiteral("environments")).toList();
    for (const QVariant& each : environments) {
      const QVariantMap entry = each.toMap();
      if (entry.value(QStringLiteral("id")).toString() == environment) return !entry.value(QStringLiteral("plugins")).toList().isEmpty();
    }
    return false;
  }
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& model, Sut& sut) {
  // Twice: what the shell asks on hearing the first round is answered before the second.
  sut.barrier();
  sut.barrier();
  RC_ASSERT(sut.listed(kLocal));
  RC_ASSERT(sut.listed(kPeer) == model.listed);
}

// The MC no longer knows the member, as after it restarts; what it already
// follows stays.
struct Forget : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.known); }
  void apply(Model& model) const override { model.known = false; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.known = false;
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Forget"; }
};

// The cluster learns the member and announces it.
struct Learn : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.known); }
  void apply(Model& model) const override {
    model.known = true;
    model.listed = model.online;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.known = true;
    sut.mc.join(kPeer);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Learn"; }
};

// The member is announced again, known or not.
struct Announce : Command {
  void apply(Model& model) const override { model.listed = model.listed || (model.known && model.online); }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.mc.join(kPeer);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Announce"; }
};

struct Leave : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.online); }
  void apply(Model& model) const override {
    model.online = false;
    model.listed = false;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.mc.setOnline(kPeer, false);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Leave"; }
};

struct Return : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.online); }
  void apply(Model& model) const override {
    model.online = true;
    model.listed = model.known;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.mc.setOnline(kPeer, true);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Return"; }
};

}  // namespace

class McPluginFollowProp : public QObject {
  Q_OBJECT

private slots:
  void member() {
    Sut sut;
    QVERIFY(rc::check("a member's section is there while it is online and known since its last announcement", [&sut] {
      sut.reset();
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Forget, Learn, Announce, Leave, Return>());
    }));
  }
};

HAL_C2_PROP_MAIN(McPluginFollowProp)
#include "tst_McPluginFollowProp.moc"
