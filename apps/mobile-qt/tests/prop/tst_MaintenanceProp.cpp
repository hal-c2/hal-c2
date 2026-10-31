// The phone's maintenance of its environments (src/Maintenance) against a
// model of what the user started and what the MCs answered: the page opened
// and left, server updates of a service and of a desktop host that asks
// first, every machine at once, provider updates answered, failed, held and
// cut off, the connection lost and back, and new app releases. Nothing starts
// where the phone may not operate, and what the page says matches.

#include "Prop.h"

#include <QDir>
#include <QJsonArray>

#include <array>
#include <memory>
#include <optional>
#include <vector>

#include "Maintenance.h"
#include "McClient.h"
#include "NativeShell.h"
#include "PairableMc.h"
#include "PluginController.h"
#include "SettingsController.h"
#include "ShellBridge.h"

namespace {

using S = QString;

// The paired MC's own environment, a service, and a cluster member whose
// desktop app hosts it.
constexpr int kMachines = 2;
const std::array<const char*, kMachines> kIds{"env-a", "laptop"};
const std::array<const char*, kMachines> kLabels{"server", "laptop"};
const S kSession = S("session-prop");

enum class End { Succeeded, Unchanged, Failed };

const char* name(End end) {
  switch (end) {
    case End::Succeeded: return "succeeded";
    case End::Unchanged: return "unchanged";
    case End::Failed: return "failed";
  }
  return "?";
}

S version(int minor) { return S("1.%1.0").arg(minor); }

struct Machine {
  int version = 0;
  // The server update's last outcome: succeeded or not.
  std::optional<bool> updated;
  int serverCalls = 0;
  // Its Codex: behind its latest release, updating, and how its last update ended.
  bool behind = true;
  bool running = false;
  End holding = End::Succeeded;  // how the MC ends the update it holds
  std::optional<End> provider;
  bool cutOff = false;  // the last update ended with the connection
  int providerCalls = 0;
};

struct Model {
  bool open = false;
  bool connected = true;
  // The session's scopes have been read since the phone connected.
  bool session = false;
  // The member's providers have been read once.
  bool peerKnown = false;
  int app = 1;
  std::vector<int> confirming;
  std::array<Machine, kMachines> machines;
};

bool may(const Model& m) { return m.connected && m.session; }
bool behindApp(const Model& m, int i) { return m.app > m.machines[i].version; }

// The MC's answer to a server update of machine `i`.
void updateServer(Model& m, int i, bool fails) {
  Machine& machine = m.machines[i];
  ++machine.serverCalls;
  machine.updated = !fails;
  if (!fails) machine.version = m.app;
}

void endProvider(Machine& machine, End end) {
  machine.running = false;
  machine.cutOff = false;
  machine.provider = end;
  if (end == End::Succeeded) machine.behind = false;
}

// A paired phone with the MC's other member, its RPCs answered as the test says.
struct Sut {
  Sut() : home(QDir::homePath() + S("/phone-XXXXXX")), mc(S("a"), S("server")) {
    FakeMc& fake = mc.mc;
    mc.sessions.append(kSession);
    fake.descriptors.insert(S(kIds[0]), describe(0, {{S("serverSelfUpdate"), S("hot-upgrade")}}));
    fake.descriptors.insert(S(kIds[1]), describe(0, {{S("serverSelfUpdate"), S("desktop-managed")}, {S("desktopAppUpdate"), true}}));
    fake.peerLabels.insert(S(kIds[1]), S(kLabels[1]));
    fake.join(S("mc-laptop"), S(kIds[1]));
    fake.onShape(S("config"), [this](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != S(kIds[0])) return;
      mc.mc.send({{S("t"), S("config")}, {S("id"), id}, {S("mc"), mc.mc.name}, {S("config"), QJsonObject{{S("providers"), providers(0)}, {S("settings"), QJsonObject()}}}});
    });
    fake.onRpc(S("server.refreshProviders"), [this](const FakeMc::Rpc& rpc) { mc.mc.reply(rpc, QJsonObject{{S("providers"), providers(machineOf(rpc))}}); });
    fake.onRpc(S("server.updateProvider"), [this](const FakeMc::Rpc& rpc) {
      ++providerCalls[machineOf(rpc)];
      if (hold) {
        held.append({rpc, end});
        return;
      }
      answerProvider(rpc, end);
    });
    fake.onRpc(S("server.updateServer"), [this](const FakeMc::Rpc& rpc) {
      const int i = machineOf(rpc);
      ++serverCalls[i];
      if (fails) return mc.mc.refuse(rpc, S("Disk is full"));
      const S target = rpc.payload.value(QLatin1String("targetVersion")).toString();
      mc.mc.reply(rpc, QJsonObject{{S("targetVersion"), target}, {S("method"), S("hot-upgrade")}});
      QJsonObject descriptor = mc.mc.descriptors.value(S(kIds[i]));
      descriptor.insert(S("serverVersion"), target);
      mc.mc.descriptors.insert(S(kIds[i]), descriptor);
      if (i == 0) {
        mc.mc.announceEnvironment();
      } else {
        mc.mc.join(S("mc-laptop"), S(kIds[1]));
      }
    });

    const QDir dir(home.path());
    dir.mkpath(S("config"));
    bridge = std::make_unique<ShellBridge>();
    shell = std::make_unique<NativeShell>(bridge.get());
    shell->client()->setRetryDelays({20});
    shell->setStoreDirs(dir.filePath(S("state")), dir.filePath(S("data")));
    shell->controller<SettingsController>()->setDevicePath(dir.filePath(S("config/preferences.json")));
    shell->controller<PluginController>()->setConfigDir(dir.filePath(S("config")));
    maintenance = std::make_unique<Maintenance>(bridge.get(), shell.get());
    maintenance->setAppVersion(version(1));
    shell->client()->open(mc.mc.origin(), kSession);
    RC_ASSERT(halc2::prop::until([&] { return machines().size() == kMachines && !provider(0).isEmpty() && online(1); }));
  }
  ~Sut() {
    maintenance.reset();
    shell.reset();
    bridge.reset();
    halc2::prop::settle();
  }

  QJsonObject describe(int minor, const QJsonObject& selfUpdate) const {
    QJsonObject capabilities = mc.mc.capabilities;
    for (auto it = selfUpdate.begin(); it != selfUpdate.end(); ++it) capabilities.insert(it.key(), it.value());
    return {{S("serverVersion"), version(minor)}, {S("capabilities"), capabilities}};
  }

  int machineOf(const FakeMc::Rpc& rpc) const { return rpc.environment == S(kIds[1]) ? 1 : 0; }

  QJsonArray providers(int i) const {
    QJsonObject codex{{S("instanceId"), S("codex")},
                      {S("driver"), S("codex")},
                      {S("enabled"), true},
                      {S("installed"), true},
                      {S("versionAdvisory"), QJsonObject{{S("status"), behind[i] ? S("behind_latest") : S("current")},
                                                         {S("canUpdate"), true},
                                                         {S("latestVersion"), S("0.51.0")}}}};
    if (!state[i].isEmpty()) codex.insert(S("updateState"), state[i]);
    return {codex, QJsonObject{{S("instanceId"), S("claudeAgent")}, {S("driver"), S("claudeAgent")}, {S("enabled"), false}}};
  }

  // The MC's own providers changed: its config says so.
  void pushProviders() {
    for (const int id : mc.mc.subscribers(S("config"))) {
      mc.mc.send({{S("t"), S("config.providers")}, {S("id"), id}, {S("providers"), providers(0)}});
    }
  }

  void answerProvider(const FakeMc::Rpc& rpc, End how) {
    const int i = machineOf(rpc);
    state[i] = QJsonObject{{S("status"), S(name(how))}};
    if (how == End::Failed) state[i].insert(S("message"), S("npm is not installed"));
    if (how == End::Succeeded) behind[i] = false;
    if (i == 0) pushProviders();
    mc.mc.reply(rpc, QJsonObject{{S("providers"), providers(i)}});
  }

  QVariantMap published() const { return bridge->state()->value(S("maintenance")).toMap(); }
  QVariantList machines() const { return published().value(S("machines")).toList(); }
  QVariantMap machine(int i) const {
    for (const QVariant& each : machines()) {
      if (each.toMap().value(S("environmentId")).toString() == S(kIds[i])) return each.toMap();
    }
    return {};
  }
  bool online(int i) const { return machine(i).value(S("online")).toBool(); }
  QVariantMap provider(int i) const {
    const QVariantList providers = machine(i).value(S("providers")).toList();
    return providers.isEmpty() ? QVariantMap() : providers.first().toMap();
  }
  bool settled() const {
    for (int i = 0; i < kMachines; ++i) {
      if (machine(i).value(S("updating")).toBool()) return false;
    }
    return true;
  }

  void dispatch(const S& action, const QVariantMap& payload = {}) { bridge->dispatch(action, payload); }

  // What the page shows agrees with the model.
  void check(const Model& m) const {
    const QVariantMap state = published();
    RC_ASSERT(state.value(S("appVersion")).toString() == version(m.app));
    RC_ASSERT(state.value(S("confirm")).isNull() == m.confirming.empty());
    RC_ASSERT(machines().size() == kMachines);
    int updatable = 0;
    for (int i = 0; i < kMachines; ++i) {
      const Machine& model = m.machines[i];
      const QVariantMap shown = machine(i);
      RC_ASSERT(shown.value(S("blocked")).toString().isEmpty() == may(m));
      RC_ASSERT(shown.value(S("target")).toString() == (behindApp(m, i) ? version(m.app) : S()));
      RC_ASSERT(!shown.value(S("updating")).toBool());
      if (i == 0 || m.connected) RC_ASSERT(shown.value(S("version")).toString() == version(model.version));
      const QVariant outcome = shown.value(S("outcome"));
      RC_ASSERT(outcome.isNull() == !model.updated.has_value());
      if (model.updated) RC_ASSERT(outcome.toMap().value(S("ok")).toBool() == *model.updated);
      RC_ASSERT(serverCalls[i] == model.serverCalls);
      RC_ASSERT(providerCalls[i] == model.providerCalls);
      if (may(m) && behindApp(m, i)) ++updatable;
      // A turned-off provider is not this machine's to update.
      const QVariantList providers = shown.value(S("providers")).toList();
      RC_ASSERT(providers.size() == ((i == 0 || m.peerKnown) ? 1 : 0));
      if (providers.isEmpty()) continue;
      const QVariantMap codex = providers.first().toMap();
      RC_ASSERT(codex.value(S("instanceId")).toString() == S("codex"));
      RC_ASSERT(codex.value(S("updating")).toBool() == model.running);
      RC_ASSERT(codex.value(S("canUpdate")).toBool() == (may(m) && model.behind && !model.running));
      const bool failed = model.provider == End::Failed || (model.cutOff && !model.running);
      RC_ASSERT(codex.value(S("failed")).toBool() == (!model.running && model.provider.has_value() && failed));
      const S outcomeText = codex.value(S("outcome")).toString();
      if (model.running || !model.provider) {
        RC_ASSERT(outcomeText.isEmpty());
      } else if (model.cutOff) {
        RC_ASSERT(outcomeText == S("Failed: disconnected"));
      } else {
        switch (*model.provider) {
          case End::Succeeded: RC_ASSERT(outcomeText == S("Updated")); break;
          case End::Unchanged: RC_ASSERT(outcomeText == S("Already up to date")); break;
          case End::Failed: RC_ASSERT(outcomeText == S("Failed: npm is not installed")); break;
        }
      }
    }
    RC_ASSERT(state.value(S("updatable")).toInt() == updatable);
  }

  QTemporaryDir home;
  PairableMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> shell;
  std::unique_ptr<Maintenance> maintenance;
  // What the MC answers next, and what it holds.
  bool fails = false;
  bool hold = false;
  End end = End::Succeeded;
  struct Held {
    FakeMc::Rpc rpc;
    End end;
  };
  QList<Held> held;
  std::array<bool, kMachines> behind{true, true};
  std::array<QJsonObject, kMachines> state;
  std::array<int, kMachines> serverCalls{};
  std::array<int, kMachines> providerCalls{};
};

using Command = rc::state::Command<Model, Sut>;

// The user opens Settings → Maintenance: the session and the member's providers are read.
struct Open : Command {
  void apply(Model& m) const override {
    m.open = true;
    if (m.connected) {
      m.session = true;
      m.peerKnown = true;
    }
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.dispatch(S("maintenance.open"));
    if (next.connected) RC_ASSERT(halc2::prop::until([&] { return s.machine(0).value(S("blocked")).toString().isEmpty() && !s.provider(1).isEmpty(); }));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Open"; }
};

// And leaves it; a question it asked goes with it.
struct Close : Command {
  void apply(Model& m) const override {
    m.open = false;
    m.confirming.clear();
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.dispatch(S("maintenance.close"));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Close"; }
};

// The user updates one machine's server; the MC answers at once, or refuses.
struct Update : Command {
  int machine = *rc::gen::inRange(0, kMachines);
  bool fails = *rc::gen::element(false, false, true);

  void apply(Model& m) const override {
    if (!may(m) || !behindApp(m, machine)) return;
    if (machine == 0) {
      updateServer(m, 0, fails);
    } else {
      // A desktop app closes to update: asked first.
      m.confirming = {1};
    }
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.fails = fails;
    s.dispatch(S("maintenance.update"), {{S("environment"), S(kIds[machine])}});
    RC_ASSERT(halc2::prop::until([&] { return s.settled() && s.serverCalls[0] == next.machines[0].serverCalls; }));
    if (machine == 0 && next.machines[0].updated == true) {
      RC_ASSERT(halc2::prop::until([&] { return s.machine(0).value(S("version")).toString() == version(next.machines[0].version); }));
    }
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Update(" << kLabels[machine] << (fails ? ", fails" : "") << ")"; }
};

// "Update all machines": the service at once, the desktop host once confirmed.
struct UpdateAll : Command {
  bool fails = *rc::gen::element(false, false, true);

  void apply(Model& m) const override {
    if (!may(m)) return;
    if (behindApp(m, 0)) updateServer(m, 0, fails);
    if (behindApp(m, 1)) m.confirming = {1};
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.fails = fails;
    s.dispatch(S("maintenance.updateAll"));
    RC_ASSERT(halc2::prop::until([&] {
      return s.settled() && s.serverCalls[0] == next.machines[0].serverCalls &&
             s.machine(0).value(S("version")).toString() == version(next.machines[0].version);
    }));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "UpdateAll" << (fails ? "(fails)" : ""); }
};

// The user confirms the desktop apps relaunch.
struct Confirm : Command {
  bool fails = *rc::gen::element(false, false, true);

  void apply(Model& m) const override {
    for (const int i : std::exchange(m.confirming, {})) {
      if (may(m) && behindApp(m, i)) updateServer(m, i, fails);
    }
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.fails = fails;
    s.dispatch(S("maintenance.confirm"));
    RC_ASSERT(halc2::prop::until([&] {
      return s.settled() && s.serverCalls[1] == next.machines[1].serverCalls &&
             (!next.connected || s.machine(1).value(S("version")).toString() == version(next.machines[1].version));
    }));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Confirm" << (fails ? "(fails)" : ""); }
};

struct Cancel : Command {
  void apply(Model& m) const override { m.confirming.clear(); }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.dispatch(S("maintenance.cancel"));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Cancel"; }
};

// The user updates Codex on one machine; the MC ends it, or holds it.
struct UpdateProvider : Command {
  int machine = *rc::gen::inRange(0, kMachines);
  End end = *rc::gen::element(End::Succeeded, End::Unchanged, End::Failed);
  bool hold = *rc::gen::element(false, false, true);

  bool starts(const Model& m) const {
    const Machine& at = m.machines[machine];
    return may(m) && (machine == 0 || m.peerKnown) && at.behind && !at.running;
  }
  void apply(Model& m) const override {
    if (!starts(m)) return;
    Machine& at = m.machines[machine];
    ++at.providerCalls;
    if (hold) {
      at.running = true;
      at.holding = end;
      at.provider.reset();
      at.cutOff = false;
    } else {
      endProvider(at, end);
    }
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.hold = hold;
    s.end = end;
    s.dispatch(S("maintenance.updateProvider"), {{S("environment"), S(kIds[machine])}, {S("instanceId"), S("codex")}});
    RC_ASSERT(halc2::prop::until([&] {
      return s.providerCalls[machine] == next.machines[machine].providerCalls &&
             s.provider(machine).value(S("updating")).toBool() == next.machines[machine].running &&
             s.provider(machine).value(S("canUpdate")).toBool() == (may(next) && next.machines[machine].behind && !next.machines[machine].running);
    }));
    s.hold = false;
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "UpdateProvider(" << kLabels[machine] << ", " << name(end) << (hold ? ", held" : "") << ")"; }
};

// The MC ends the provider updates it held.
struct Release : Command {
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.connected);
    RC_PRE(m.machines[0].running || m.machines[1].running);
  }
  void apply(Model& m) const override {
    for (Machine& machine : m.machines) {
      if (machine.running) endProvider(machine, machine.holding);
    }
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    for (const Sut::Held& each : std::exchange(s.held, {})) s.answerProvider(each.rpc, each.end);
    RC_ASSERT(halc2::prop::until([&] { return !s.provider(0).value(S("updating")).toBool() && !s.provider(1).value(S("updating")).toBool(); }));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Release"; }
};

// The MC goes away: what the phone waited on ends with the connection.
struct Disconnect : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.connected); }
  void apply(Model& m) const override {
    m.connected = false;
    m.session = false;
    for (Machine& machine : m.machines) {
      if (!machine.running) continue;
      machine.running = false;
      machine.provider = End::Failed;
      machine.cutOff = true;
    }
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.held.clear();
    s.mc.mc.stopAccepting();
    s.mc.mc.drop();
    RC_ASSERT(halc2::prop::until([&] { return !s.shell->client()->isReady(); }));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Disconnect"; }
};

// And comes back: an open page reads the session again.
struct Reconnect : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.connected); }
  void apply(Model& m) const override {
    m.connected = true;
    if (m.open) {
      m.session = true;
      m.peerKnown = true;
    }
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.mc.mc.startAccepting();
    RC_ASSERT(halc2::prop::until([&] { return s.shell->client()->isReady() && s.online(1); }));
    if (next.open) RC_ASSERT(halc2::prop::until([&] { return s.machine(0).value(S("blocked")).toString().isEmpty(); }));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Reconnect"; }
};

// A newer app: every machine is behind it again.
struct NewApp : Command {
  void apply(Model& m) const override { ++m.app; }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.maintenance->setAppVersion(version(next.app));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "NewApp"; }
};

// Codex on the MC's own machine falls behind again.
struct NewCodex : Command {
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.connected);
    RC_PRE(!m.machines[0].behind);
  }
  void apply(Model& m) const override { m.machines[0].behind = true; }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.behind[0] = true;
    s.pushProviders();
    RC_ASSERT(halc2::prop::until([&] { return s.provider(0).value(S("canUpdate")).toBool() == (may(next) && !next.machines[0].running); }));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "NewCodex"; }
};

QJsonArray releases(const std::vector<std::pair<int, int>>& made) {
  // (minor, kind): 0 stable, 1 nightly, 2 draft, 3 not an MC tag.
  QJsonArray releases;
  for (const auto& [minor, kind] : made) {
    S tag = S("mc-v") + version(minor);
    if (kind == 1) tag += S("-nightly.20261030.%1").arg(minor);
    if (kind == 3) tag = S("desktop-v") + version(minor);
    releases.append(QJsonObject{{S("tag_name"), tag}, {S("draft"), kind == 2}});
  }
  return releases;
}

}  // namespace

class tst_MaintenanceProp : public QObject {
  Q_OBJECT

private slots:
  void maintenanceMatchesItsModel() {
    QVERIFY(rc::check("the phone's maintenance matches its model", [] {
      Sut sut;
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Open, Close, Update, UpdateAll, Confirm, Cancel, UpdateProvider, Release, Disconnect, Reconnect,
                                                         NewApp, NewCodex>());
    }));
  }

  // The newest release on a channel is the first the index lists on it that is
  // a published MC release, whatever else the index lists around it.
  void newestReleaseIsTheFirstOnTheChannel() {
    QVERIFY(rc::check("newestOn takes the first published MC release on the channel", [] {
      const auto made = *rc::gen::container<std::vector<std::pair<int, int>>>(
          rc::gen::pair(rc::gen::inRange(0, 9), rc::gen::inRange(0, 4)));
      const bool nightly = *rc::gen::arbitrary<bool>();
      std::optional<S> expected;
      for (const auto& [minor, kind] : made) {
        if (kind == (nightly ? 1 : 0)) {
          expected = version(minor) + (nightly ? S("-nightly.20261030.%1").arg(minor) : S());
          break;
        }
      }
      const std::optional<S> found = maintenance::newestOn(releases(made), nightly ? S("nightly") : S("stable"));
      RC_ASSERT(found == expected);
      if (found) RC_ASSERT(maintenance::channelOf(*found) == (nightly ? S("nightly") : S("stable")));
    }));
  }
};

HAL_C2_PROP_MAIN(tst_MaintenanceProp)
#include "tst_MaintenanceProp.moc"
