// Device tabs (ThreadDevices' DeviceTabs) against a fake MC with three
// devices. The panel lists and shows tabs in any order, moves a shown tab
// (the same tabs shown, in another order, as the stage reparenting its body),
// the thread opens and closes devices, and the MC's connection drops. After
// every step each listed tab has a DeviceTab, which streams exactly while it
// is shown and its device is open for the thread, and a tab that kept
// streaming kept its DeviceTab and its stream's target: it never reconnected.

#include "Prop.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QPointer>

#include "FakeMc.h"
#include "McClient.h"
#include "ThreadDevices.h"

namespace prop = halc2::prop;

namespace {

const QString kThread = QStringLiteral("thread");
const QStringList kDevices = {QStringLiteral("UDID-A"), QStringLiteral("emulator-5554"), QStringLiteral("UDID-C")};

QString tabOf(const QString& device) { return ThreadDevices::tabIdOf(QStringLiteral("local"), device); }

rc::Gen<QStringList> someOf(const QStringList& values) {
  return rc::gen::map(rc::gen::container<std::vector<bool>>(values.size(), rc::gen::arbitrary<bool>()), [values](const std::vector<bool>& picks) {
    QStringList picked;
    for (qsizetype n = 0; n < values.size(); ++n) {
      if (picks[n]) picked.append(values.at(n));
    }
    return picked;
  });
}

struct Model {
  QSet<QString> tabs;
  QSet<QString> shown;
  // The devices the thread has open, on the MC.
  QSet<QString> sessions;

  bool streams(const QString& device) const {
    const QString tab = tabOf(device);
    return tabs.contains(tab) && shown.contains(tab) && sessions.contains(device);
  }
};

struct Sut {
  FakeMc mc;
  McClient client;
  ThreadDevices devices{&client};
  QObject barrier;
  QSet<QString> sessions;
  // Each DeviceTab seen, and how often its stream's target changed.
  QHash<DeviceTab*, int> retargets;

  Sut() {
    mc.onRpc(QStringLiteral("device."), [](const FakeMc::Rpc&) {});
    mc.onShape(QStringLiteral("devices"), [this](int id, const QJsonObject&) { send(id); });
    // The hub takes each stream's connection and sends nothing yet.
    mc.onRaw(QStringLiteral("/api/device-hub/"), [](QTcpSocket*, const QByteArray&) {});
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    if (!prop::until([this] { return client.isReady(); })) qFatal("the client did not connect");
    QObject::connect(&devices, &ThreadDevices::tabsChanged, &barrier, [this] { watch(); });
    devices.setThread(mc.environmentId, kThread, QStringLiteral("one"));
    if (!prop::until([this] { return devices.view().value(QStringLiteral("loaded")).toBool(); })) qFatal("no devices state");
  }

  QJsonObject state() const {
    QJsonArray listed, open;
    for (const QString& device : kDevices) {
      const QString platform = device.startsWith(QLatin1String("emulator")) ? QStringLiteral("android") : QStringLiteral("ios");
      listed.append(QJsonObject{{QStringLiteral("hostId"), QStringLiteral("local")}, {QStringLiteral("id"), device},
                                {QStringLiteral("name"), device},  {QStringLiteral("platform"), platform},
                                {QStringLiteral("booted"), true}});
      if (sessions.contains(device))
        open.append(QJsonObject{{QStringLiteral("threadId"), kThread}, {QStringLiteral("hostId"), QStringLiteral("local")},
                                {QStringLiteral("deviceId"), device}});
    }
    return {{QStringLiteral("hostStatus"), QStringLiteral("ready")},
            {QStringLiteral("onboardingCompleted"), true},
            {QStringLiteral("hubBasePath"), QStringLiteral("/api/device-hub/mcs/one")},
            {QStringLiteral("devices"), listed},
            {QStringLiteral("sessions"), open}};
  }

  void send(int id) { mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), state()}}); }

  void announce() {
    for (const int id : mc.subscribers(QStringLiteral("devices"))) send(id);
  }

  void watch() {
    for (const QVariant& value : devices.tabsView()) {
      auto* tab = qobject_cast<DeviceTab*>(value.value<QObject*>());
      if (!tab || retargets.contains(tab)) continue;
      retargets.insert(tab, 0);
      QObject::connect(tab->stream(), &DeviceStream::targetChanged, &barrier, [this, tab] { ++retargets[tab]; });
      QObject::connect(tab, &QObject::destroyed, &barrier, [this, tab] { retargets.remove(tab); });
    }
  }

  // Once this comes back, every frame sent before it has been read.
  bool sync() {
    auto answered = std::make_shared<bool>(false);
    client.call(&barrier, {}, QStringLiteral("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>&) { *answered = true; });
    return prop::until([&] { return *answered; });
  }
};

// Each streaming tab before a step: its DeviceTab and retargets so far.
using Streaming = QHash<QString, std::pair<QPointer<DeviceTab>, int>>;

Streaming streaming(const Model& model, Sut& sut) {
  Streaming now;
  for (const QString& device : kDevices) {
    DeviceTab* tab = sut.devices.tab(tabOf(device));
    if (model.streams(device) && tab) now.insert(device, {tab, sut.retargets.value(tab)});
  }
  return now;
}

void check(const Model& model, Sut& sut, const Streaming& before) {
  RC_ASSERT(sut.sync());
  RC_ASSERT(sut.devices.tabsView().size() == model.tabs.size());
  for (const QString& device : kDevices) {
    const QString id = tabOf(device);
    DeviceTab* tab = sut.devices.tab(id);
    RC_ASSERT((tab != nullptr) == model.tabs.contains(id));
    if (!tab) continue;
    RC_ASSERT(tab->shown() == model.shown.contains(id));
    RC_ASSERT(tab->screen().isValid() == model.sessions.contains(device));
    const bool idle = tab->stream()->status() == QLatin1String("idle");
    RC_ASSERT(idle == !model.streams(device));
    RC_ASSERT(tab->tools()->view().value(QStringLiteral("platform")).toString().isEmpty() == !model.streams(device));
    // Still streaming: the same tab and stream, never pointed elsewhere.
    if (model.streams(device) && before.contains(device)) {
      RC_ASSERT(before.value(device).first.data() == tab);
      RC_ASSERT(sut.retargets.value(tab) == before.value(device).second);
    }
  }
}

using Command = rc::state::Command<Model, Sut>;

template <typename Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    const Streaming streams = streaming(before, sut);
    static_cast<const Self*>(this)->act(before, sut);
    check(expected, sut, streams);
  }
};

QStringList tabsOf(const QStringList& devices) {
  QStringList ids;
  for (const QString& device : devices) ids.append(tabOf(device));
  return ids;
}

struct SetTabs : Step<SetTabs> {
  QStringList tabs = tabsOf(*someOf(kDevices));
  explicit SetTabs(const Model&) {}
  void apply(Model& model) const override { model.tabs = QSet<QString>(tabs.begin(), tabs.end()); }
  void act(const Model&, Sut& sut) const { sut.devices.setTabs(tabs); }
  void show(std::ostream& os) const override { os << "tabs " << tabs.join(QLatin1Char(' ')).toStdString(); }
};

struct SetShown : Step<SetShown> {
  QStringList shown = tabsOf(*someOf(kDevices));
  explicit SetShown(const Model&) {}
  void apply(Model& model) const override { model.shown = QSet<QString>(shown.begin(), shown.end()); }
  void act(const Model&, Sut& sut) const { sut.devices.setShown(shown); }
  void show(std::ostream& os) const override { os << "shown " << shown.join(QLatin1Char(' ')).toStdString(); }
};

// A shown tab moves between the panel and the stage: the same tabs, listed
// and shown in another order.
struct Reparent : Step<Reparent> {
  explicit Reparent(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model& model, Sut& sut) const {
    QStringList tabs(model.tabs.begin(), model.tabs.end()), shown(model.shown.begin(), model.shown.end());
    std::reverse(tabs.begin(), tabs.end());
    std::reverse(shown.begin(), shown.end());
    sut.devices.setTabs(tabs);
    sut.devices.setShown(shown);
  }
  void show(std::ostream& os) const override { os << "reparent"; }
};

struct Session : Step<Session> {
  QString device = *rc::gen::elementOf(std::vector<QString>(kDevices.begin(), kDevices.end()));
  explicit Session(const Model&) {}
  void apply(Model& model) const override {
    if (!model.sessions.remove(device)) model.sessions.insert(device);
  }
  void act(const Model&, Sut& sut) const {
    if (!sut.sessions.remove(device)) sut.sessions.insert(device);
    sut.announce();
  }
  void show(std::ostream& os) const override { os << "toggle the session of " << device.toStdString(); }
};

struct Reconnect : Step<Reconnect> {
  explicit Reconnect(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    sut.mc.drop();
    RC_ASSERT(prop::until([&] { return !sut.client.isReady(); }));
    RC_ASSERT(prop::until([&] { return sut.client.isReady(); }));
  }
  void show(std::ostream& os) const override { os << "the MC's connection drops"; }
};

class tst_ThreadDevicesProp : public QObject {
  Q_OBJECT

private slots:
  void tabs() {
    QVERIFY(rc::check("a device tab streams exactly while shown and open, and keeps its stream while it does", [] {
      Sut sut;
      rc::state::check(Model(), sut, rc::state::gen::execOneOfWithArgs<SetTabs, SetShown, SetShown, Reparent, Session, Session, Reconnect>());
    }));
  }
};

}  // namespace

HAL_C2_PROP_MAIN(tst_ThreadDevicesProp)

#include "tst_ThreadDevicesProp.moc"
