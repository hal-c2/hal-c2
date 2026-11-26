// The grace a reconnect gets before it is shown (src/native/ConnectionGrace,
// ConnectionHealthController's `settling`), over any order of the client's
// phases and the grace's timer running out: a connection is held back only
// while it comes back up within the grace since it was last connected, never
// before it first was, and never once a problem or the grace's end spent it.

#include "Prop.h"

#include <string>
#include <utility>
#include <vector>

#include "ConnectionGrace.h"

namespace {

// What the controller makes of each of the client's phases: the icon's state
// it publishes (ConnectionHealthController::update).
const std::vector<std::pair<std::string, std::string>> kPhases{
    {"connecting", "connecting"},          // a first attempt, or a socket the MC has not described itself on
    {"connected", "ready"},                // ready, the MC's snapshot landed
    {"retrying", "retrying"},              // after a failure
    {"offline", "offline"},                // no network
    {"refused", "needsPairing"},           // the MC refused the credential
    {"blocked", "blocked"},                // another protocol
    {"shellProblem", "blocked"},           // ready, but the MC will not send the shell
};

bool comingUp(const std::string& state) {
  return state == "connecting" || state == "retrying";
}

struct Model {
  std::string state = "connecting";  // what the controller published last
  bool everConnected = false;
  // Connected since the last problem and the grace's last end.
  bool sinceConnected = false;

  bool settling() const { return everConnected && sinceConnected && comingUp(state); }
};

struct Sut {
  ConnectionGrace grace;
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& expected, const Sut& sut) {
  RC_ASSERT(sut.grace.settling() == expected.settling());
  if (!expected.everConnected) RC_ASSERT(!sut.grace.settling());
}

// The client's phase changes, and the controller publishes again.
struct Phase : Command {
  std::pair<std::string, std::string> phase = *rc::gen::elementOf(kPhases);

  explicit Phase(const Model&) {}

  void apply(Model& model) const override {
    const std::string& state = phase.second;
    model.state = state;
    if (state == "ready") {
      model.everConnected = true;
      model.sinceConnected = true;
    } else if (!comingUp(state)) {
      model.sinceConnected = false;
    }
  }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.grace.see(QString::fromStdString(phase.second));
    check(expected, sut);
  }

  void show(std::ostream& os) const override { os << "Phase(" << phase.first << ")"; }
};

// The grace's timer runs out. It runs only while a reconnect is settling.
struct GraceRunsOut : Command {
  explicit GraceRunsOut(const Model&) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.settling()); }

  void apply(Model& model) const override { model.sinceConnected = false; }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.grace.expire();
    check(expected, sut);
    RC_ASSERT(!sut.grace.settling());
  }

  void show(std::ostream& os) const override { os << "GraceRunsOut"; }
};

}  // namespace

class ConnectionGraceProp : public QObject {
  Q_OBJECT

private slots:
  void settlesOnlyAReconnectWithinItsGrace() {
    QVERIFY(rc::check("a connection is held back only while it comes back within the grace since it was last connected", [] {
      Sut sut;
      // A fresh launch: connecting, never connected.
      sut.grace.see(QStringLiteral("connecting"));
      RC_ASSERT(!sut.grace.settling());
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Phase, Phase, Phase, GraceRunsOut>());
    }));
  }
};

HAL_C2_PROP_MAIN(ConnectionGraceProp)
#include "tst_ConnectionGraceProp.moc"
