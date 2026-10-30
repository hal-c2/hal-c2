// The Tools drawer (DeviceTools) against a fake MC with two devices, each
// with an appearance of its own. The user opens and closes the drawer,
// moves between devices and asks for a change; the MC holds its answers,
// so a read can land after the drawer moved to the other device and a
// change can be refused. After every step the drawer shows the current
// device's settings as the latest landed answer left them, is busy
// exactly while a change is out, and keeps the old value when refused.

#include "Prop.h"

#include <QJsonObject>

#include "DeviceTools.h"
#include "FakeMc.h"
#include "McClient.h"

namespace prop = halc2::prop;

namespace {

const QStringList kDevices = {QStringLiteral("phone"), QStringLiteral("tablet")};

rc::Gen<QString> oneOf(const QStringList& values) {
  return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end()));
}
const QString kRefusal = QStringLiteral("Not allowed");

// A call the MC holds: the read a drawer asked, or the change to `value`.
struct Held {
  QString device;
  int generation = 0;
  bool action = false;
  QString value;
  bool operator==(const Held&) const = default;
};

struct Model {
  // What each device reports, on the MC's side.
  QMap<QString, QString> mc{{kDevices.at(0), QStringLiteral("light")}, {kDevices.at(1), QStringLiteral("dark")}};
  bool refusing = false;
  // The drawer as shown.
  QString target;
  bool open = false;
  bool loaded = false;
  bool pending = false;
  QString shown;
  QString error;
  // Retargeting starts a new generation: only its answers count.
  int generation = 0;
  QList<Held> held;

  void read() { held.append({target, generation, false, {}}); }

  void answerOne() {
    const Held call = held.takeFirst();
    if (!call.action) {
      if (call.generation == generation) {
        shown = mc.value(call.device);
        loaded = true;
      }
      return;
    }
    // An answer for a device the drawer has left ends nothing it shows.
    const bool current = call.generation == generation;
    if (current) pending = false;
    if (refusing) {
      if (current) error = kRefusal;
      return;
    }
    mc[call.device] = call.value;
    if (current) {
      shown = call.value;
      loaded = true;
    }
  }
};

// The drawer on a fake MC whose answers are all held.
struct Sut {
  FakeMc mc;
  McClient client;
  DeviceTools tools{&client};
  QObject barrier;
  QMap<QString, QString> settings{{kDevices.at(0), QStringLiteral("light")}, {kDevices.at(1), QStringLiteral("dark")}};
  bool refusing = false;
  QList<FakeMc::Rpc> held;

  Sut() {
    mc.onRpc(QStringLiteral("device."), [this](const FakeMc::Rpc& rpc) { held.append(rpc); });
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    if (!prop::until([this] { return client.isReady(); })) qFatal("the client did not connect");
  }

  QJsonObject detail(const FakeMc::Rpc& rpc) const {
    const QString device = rpc.payload.value(QLatin1String("deviceId")).toString();
    return {{QStringLiteral("deviceId"), device},
            {QStringLiteral("settings"), QJsonObject{{QStringLiteral("appearance"), settings.value(device)}}},
            {QStringLiteral("foregroundApp"), QJsonValue::Null}};
  }

  void answerOne() {
    const FakeMc::Rpc rpc = held.takeFirst();
    if (rpc.method == QLatin1String("device.action")) {
      if (refusing) return mc.refuse(rpc, kRefusal);
      settings[rpc.payload.value(QLatin1String("deviceId")).toString()] = rpc.payload.value(QLatin1String("value")).toString();
    }
    mc.reply(rpc, detail(rpc));
  }

  // Once this comes back, every answer sent before it has been read.
  bool sync() {
    auto answered = std::make_shared<bool>(false);
    client.call(&barrier, {}, QStringLiteral("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>&) { *answered = true; });
    return prop::until([&] { return *answered; });
  }

  void target(const QString& device) {
    tools.setTarget(mc.environmentId, QStringLiteral("/hub"), QStringLiteral("local"), device,
                    device.isEmpty() ? QString() : QStringLiteral("ios"));
  }
};

void check(const Model& model, Sut& sut) {
  RC_ASSERT(sut.sync());
  const QVariantMap view = sut.tools.view();
  RC_ASSERT(view.value(QStringLiteral("open")).toBool() == model.open);
  RC_ASSERT(view.value(QStringLiteral("loaded")).toBool() == model.loaded);
  RC_ASSERT(view.value(QStringLiteral("pending")).toBool() == model.pending);
  RC_ASSERT(view.value(QStringLiteral("error")).toString() == model.error);
  RC_ASSERT(sut.held.size() == model.held.size());
  if (model.loaded) {
    RC_ASSERT(view.value(QStringLiteral("settings")).toMap().value(QStringLiteral("appearance")).toString() == model.shown);
  }
}

using Command = rc::state::Command<Model, Sut>;

template <typename Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(before, sut);
    check(expected, sut);
  }
};

struct Target : Step<Target> {
  QString device = *oneOf(kDevices);
  explicit Target(const Model&) {}
  void apply(Model& model) const override {
    if (device == model.target) return;
    model.target = device;
    ++model.generation;
    model.loaded = false;
    model.pending = false;
    model.error.clear();
    model.shown.clear();
    if (model.open) model.read();
  }
  void act(const Model&, Sut& sut) const { sut.target(device); }
  void show(std::ostream& os) const override { os << "target " << device.toStdString(); }
};

struct SetOpen : Step<SetOpen> {
  bool open = *rc::gen::arbitrary<bool>();
  explicit SetOpen(const Model&) {}
  void apply(Model& model) const override {
    if (open == model.open) return;
    model.open = open;
    if (open && !model.target.isEmpty()) {
      model.loaded = false;
      model.read();
    }
  }
  void act(const Model&, Sut& sut) const { sut.tools.setOpen(open); }
  void show(std::ostream& os) const override { os << (open ? "open" : "close"); }
};

struct Choose : Step<Choose> {
  QString choice = *rc::gen::weightedElement<QString>({{1, QStringLiteral("Dark")}, {1, QStringLiteral("Light")}});
  explicit Choose(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.target.isEmpty()); }
  void apply(Model& model) const override {
    // A second change while one is out never reaches the device.
    if (model.pending) return;
    model.pending = true;
    model.error.clear();
    model.held.append({model.target, model.generation, true, choice.toLower()});
  }
  void act(const Model&, Sut& sut) const { sut.tools.choose(QStringLiteral("Appearance"), choice); }
  void show(std::ostream& os) const override { os << "appearance " << choice.toStdString(); }
};

struct Refusing : Step<Refusing> {
  bool refusing = *rc::gen::arbitrary<bool>();
  explicit Refusing(const Model&) {}
  void apply(Model& model) const override { model.refusing = refusing; }
  void act(const Model&, Sut& sut) const { sut.refusing = refusing; }
  void show(std::ostream& os) const override { os << (refusing ? "the MC refuses" : "the MC answers"); }
};

struct Answer : Step<Answer> {
  explicit Answer(const Model& model) { RC_PRE(!model.held.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.held.isEmpty()); }
  void apply(Model& model) const override { model.answerOne(); }
  void act(const Model&, Sut& sut) const { sut.answerOne(); }
  void show(std::ostream& os) const override { os << "the MC answers one"; }
};

struct AnswerAll : Step<AnswerAll> {
  explicit AnswerAll(const Model& model) { RC_PRE(!model.held.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.held.isEmpty()); }
  void apply(Model& model) const override {
    while (!model.held.isEmpty()) model.answerOne();
  }
  void act(const Model&, Sut& sut) const {
    while (!sut.held.isEmpty()) sut.answerOne();
  }
  void show(std::ostream& os) const override { os << "the MC answers all"; }
};

class tst_DeviceToolsProp : public QObject {
  Q_OBJECT

private slots:
  void tools() {
    QVERIFY(rc::check("the tools show the current device's settings and stay busy while a change is out", [] {
      Sut sut;
      rc::state::check(Model(), sut, rc::state::gen::execOneOfWithArgs<Target, SetOpen, Choose, Choose, Refusing, Answer, Answer, AnswerAll>());
    }));
  }
};

}  // namespace

HAL_C2_PROP_MAIN(tst_DeviceToolsProp)

#include "tst_DeviceToolsProp.moc"
