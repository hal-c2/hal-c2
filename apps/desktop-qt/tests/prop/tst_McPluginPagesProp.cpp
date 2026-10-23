// The tab of a plugin page two paired MCs both run (McPluginController)
// against a fake MC whose two environments unpack the plugin's files when
// they are told to. An environment answers its files, drops off the cluster
// and comes back (to unpack them again). Whatever the order of those, the tab
// shows the copy of an environment whose files are ready, and keeps showing
// the one it showed for as long as that one stays ready: the page made from
// its url would otherwise be made again, losing what it held.

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
const QStringList kEnvironments{kLocal, kPeer};

QJsonObject plugin() {
  const auto page = QJsonObject{{QStringLiteral("id"), QStringLiteral("board")},
                                {QStringLiteral("title"), QStringLiteral("Board")},
                                {QStringLiteral("icon"), QStringLiteral("kanban")},
                                {QStringLiteral("qml"), QStringLiteral("pages/Board.qml")}};
  return {{QStringLiteral("id"), QStringLiteral("planner")},
          {QStringLiteral("name"), QStringLiteral("Planner")},
          {QStringLiteral("status"), QStringLiteral("running")},
          {QStringLiteral("revision"), QStringLiteral("r1")},
          {QStringLiteral("contributes"), QJsonObject{{QStringLiteral("pages"), QJsonArray{page}}}}};
}

struct Model {
  QSet<QString> online{kLocal, kPeer};
  QSet<QString> ready;     // online, and its files unpacked
  QSet<QString> cached;    // its files are kept on disk, so unpacking them again takes no call
};

struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QMap<QString, QList<FakeMc::Rpc>> held;
  QSet<QString> releasing;  // environments whose files are answered at once
  QString last;             // the environment the tab was last made from, or none

  Sut() {
    mc.join(kPeer);
    mc.onShape(QStringLiteral("plugins"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("plugins")}, {QStringLiteral("id"), id}, {QStringLiteral("plugins"), QJsonArray{plugin()}}});
    });
    mc.onRpc(QStringLiteral("plugins.file"), [this](const FakeMc::Rpc& rpc) {
      const QString environment = rpc.environment.isEmpty() ? kLocal : rpc.environment;
      if (releasing.contains(environment)) answer(rpc);
      else held[environment].append(rpc);
    });
    mc.onRpc(QStringLiteral("test.barrier"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });
  }

  void answer(const FakeMc::Rpc& rpc) {
    mc.reply(rpc, QJsonObject{{QStringLiteral("path"), rpc.payload.value(QLatin1String("path"))},
                              {QStringLiteral("encoding"), QStringLiteral("utf8")},
                              {QStringLiteral("content"), QStringLiteral("import QtQuick\nItem {}\n")},
                              {QStringLiteral("revision"), QStringLiteral("r1")}});
  }

  void start() {
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native->isActive() && native->store()->synchronized(); })) qFatal("the shell did not start");
  }

  // A fresh shell and cache, both environments online, nothing unpacked.
  void reset() {
    native.reset();
    bridge.reset();
    QDir(home.path()).removeRecursively();
    held.clear();
    releasing.clear();
    last.clear();
    mc.setOnline(kPeer, true);
    start();
    barrier();
  }

  // Waits for what the MC has sent so far to reach the shell.
  void barrier() {
    bool done = false;
    native->client()->call(native.get(), kLocal, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  // The environment the tab's url is from, or none.
  QString shown() const {
    const QVariantList pages = bridge->state()->value(QStringLiteral("mcPlugins")).toMap().value(QStringLiteral("pages")).toList();
    if (pages.isEmpty()) return {};
    const QString url = pages.first().toMap().value(QStringLiteral("url")).toString();
    for (const QString& environment : kEnvironments) {
      if (url.contains(QStringLiteral("/mc-plugins/%1/").arg(environment))) return environment;
    }
    return {};
  }
};

using Command = rc::state::Command<Model, Sut>;

// What the tab shows is the kept copy while it is ready, else a ready one, else nothing.
void check(const Model& model, Sut& sut) {
  // Twice: a request the shell makes on hearing the first round is answered before the second.
  sut.barrier();
  sut.barrier();
  const QString now = sut.shown();
  if (sut.last.isEmpty() || !model.ready.contains(sut.last)) {
    if (model.ready.isEmpty()) RC_ASSERT(now.isEmpty());
    else RC_ASSERT(model.ready.contains(now));
  } else {
    RC_ASSERT(now == sut.last);
  }
  sut.last = now;
}

struct Unpack : Command {
  QString environment = *rc::gen::element(kLocal, kPeer);
  void checkPreconditions(const Model& model) const override { RC_PRE(model.online.contains(environment) && !model.ready.contains(environment)); }
  void apply(Model& model) const override {
    model.ready.insert(environment);
    model.cached.insert(environment);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.releasing.insert(environment);
    for (const FakeMc::Rpc& rpc : std::exchange(sut.held[environment], {})) sut.answer(rpc);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Unpack " << environment.toStdString(); }
};

struct Leave : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.online.contains(kPeer)); }
  void apply(Model& model) const override {
    model.online.remove(kPeer);
    model.ready.remove(kPeer);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.mc.setOnline(kPeer, false);
    sut.releasing.remove(kPeer);
    sut.held.remove(kPeer);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Leave"; }
};

struct Return : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.online.contains(kPeer)); }
  void apply(Model& model) const override {
    model.online.insert(kPeer);
    if (model.cached.contains(kPeer)) model.ready.insert(kPeer);
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

class McPluginPagesProp : public QObject {
  Q_OBJECT

private slots:
  void tab() {
    Sut sut;
    QVERIFY(rc::check("the tab keeps the copy it shows while that copy is ready", [&sut] {
      sut.reset();
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Unpack, Unpack, Leave, Return>());
    }));
  }
};

HAL_C2_PROP_MAIN(McPluginPagesProp)
#include "tst_McPluginPagesProp.moc"
