// The phone back from the background (src/Resume) against a model of the app's
// states as the system reports them, time passing in and out of them, and its
// MC dropping it and coming back. A connection that still looks ready after a
// long enough stay away is replaced once, at once; anything else is left as it
// is: a short stay, a shade over the app, a connection already down.

#include <qpa/qwindowsysteminterface.h>

#include <memory>
#include <optional>

#include "FakeMc.h"
#include "McClient.h"
#include "Prop.h"
#include "Resume.h"

namespace {

constexpr int kThreshold = 10000;

const char* name(Qt::ApplicationState state) {
  switch (state) {
    case Qt::ApplicationActive:
      return "active";
    case Qt::ApplicationInactive:
      return "inactive";
    case Qt::ApplicationHidden:
      return "hidden";
    case Qt::ApplicationSuspended:
      return "suspended";
  }
  return "?";
}

struct Model {
  Qt::ApplicationState state = Qt::ApplicationActive;
  qint64 now = 0;
  // When the app went to the background, while it is there.
  std::optional<qint64> since;
  bool up = true;
  // How many connections the MC has taken.
  qsizetype connections = 1;
};

struct Sut {
  FakeMc mc;
  McClient client;
  qint64 now = 0;
  std::unique_ptr<Resume> resume;

  Sut() {
    setState(Qt::ApplicationActive);
    // A drop waits: only what the steps do reconnects.
    client.setRetryDelays({600000});
    resume = std::make_unique<Resume>(&client);
    RC_ASSERT(resume->threshold() == kThreshold);
    resume->setClock([this] { return now; });
    client.open(mc.origin(), QStringLiteral("token"));
    RC_ASSERT(halc2::prop::until([this] { return client.isReady(); }));
  }

  static void setState(Qt::ApplicationState state) {
    QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(state);
  }
};

void expectSame(const Model& model, Sut& sut) {
  RC_ASSERT(QGuiApplication::applicationState() == model.state);
  if (model.up) {
    RC_ASSERT(halc2::prop::until([&] { return sut.client.isReady() && sut.mc.connections.size() >= model.connections; }));
  }
  QCoreApplication::processEvents();
  RC_ASSERT(sut.mc.connections.size() == model.connections);
  RC_ASSERT(sut.client.isReady() == model.up);
}

using Command = rc::state::Command<Model, Sut>;

template <class Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    static_cast<const Self*>(this)->act(model, sut);
    expectSame(next, sut);
  }
};

// The app goes behind another, is suspended, or has a shade drawn over it.
struct Leave : Step<Leave> {
  Qt::ApplicationState state = *rc::gen::element(Qt::ApplicationInactive, Qt::ApplicationHidden, Qt::ApplicationSuspended);

  explicit Leave(const Model&) {}
  void apply(Model& model) const override {
    if (state != Qt::ApplicationInactive && !model.since) model.since = model.now;
    model.state = state;
  }
  void act(const Model&, Sut&) const {
    Sut::setState(state);
  }
  void show(std::ostream& os) const override {
    os << "Leave(" << name(state) << ")";
  }
};

struct Pass : Step<Pass> {
  int ms = *rc::gen::oneOf(rc::gen::inRange(0, 3000), rc::gen::just(kThreshold - 1), rc::gen::just(kThreshold), rc::gen::inRange(0, 60000));

  explicit Pass(const Model&) {}
  void apply(Model& model) const override {
    model.now += ms;
  }
  void act(const Model&, Sut& sut) const {
    sut.now += ms;
  }
  void show(std::ostream& os) const override {
    os << "Pass(" << ms << " ms)";
  }
};

// The app is in the foreground again.
struct Return : Step<Return> {
  explicit Return(const Model&) {}
  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.state != Qt::ApplicationActive);
  }
  void apply(Model& model) const override {
    if (model.since && model.now - *model.since >= kThreshold && model.up) ++model.connections;
    model.since.reset();
    model.state = Qt::ApplicationActive;
  }
  void act(const Model&, Sut&) const {
    Sut::setState(Qt::ApplicationActive);
  }
  void show(std::ostream& os) const override {
    os << "Return";
  }
};

// The MC drops the phone and takes no other connection for now.
struct Drop : Step<Drop> {
  explicit Drop(const Model&) {}
  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.up);
  }
  void apply(Model& model) const override {
    model.up = false;
  }
  void act(const Model&, Sut& sut) const {
    sut.mc.stopAccepting();
    sut.mc.drop();
    RC_ASSERT(halc2::prop::until([&] { return sut.client.phase() == McClient::Phase::Retrying; }));
  }
  void show(std::ostream& os) const override {
    os << "Drop";
  }
};

// The MC takes connections again, and the phone tries.
struct ComeBack : Step<ComeBack> {
  explicit ComeBack(const Model&) {}
  void checkPreconditions(const Model& model) const override {
    RC_PRE(!model.up);
  }
  void apply(Model& model) const override {
    model.up = true;
    ++model.connections;
  }
  void act(const Model&, Sut& sut) const {
    sut.mc.startAccepting();
    sut.client.retryNow();
  }
  void show(std::ostream& os) const override {
    os << "ComeBack";
  }
};

}  // namespace

class ResumeProp : public QObject {
  Q_OBJECT

private slots:
  void replacesAfterALongStay() {
    QVERIFY(rc::check("a ready connection is replaced once on return from a long stay away, and nothing else is", [] {
      Sut sut;
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Leave, Leave, Pass, Pass, Return, Return, Drop, ComeBack>());
    }));
  }
};

HAL_C2_PROP_MAIN(ResumeProp)
#include "tst_ResumeProp.moc"
