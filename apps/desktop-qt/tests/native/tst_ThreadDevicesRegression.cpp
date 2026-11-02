// What the review of the device setup wizard found in ThreadDevices, and
// what showing several devices at once needs of it.

#include <QJsonArray>
#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "ThreadDevices.h"

namespace {

QJsonObject unconfigured() {
  return {{QStringLiteral("hostStatus"), QStringLiteral("disabled")}, {QStringLiteral("onboardingCompleted"), false}};
}

// Two booted devices the thread has open, on the local host.
QJsonObject twoOpen() {
  const auto device = [](const QString& id, const QString& platform) {
    return QJsonObject{{QStringLiteral("hostId"), QStringLiteral("local")}, {QStringLiteral("id"), id},
                       {QStringLiteral("name"), id},  {QStringLiteral("platform"), platform},
                       {QStringLiteral("booted"), true}};
  };
  const auto session = [](const QString& id) {
    return QJsonObject{{QStringLiteral("threadId"), QStringLiteral("thread")}, {QStringLiteral("hostId"), QStringLiteral("local")},
                       {QStringLiteral("deviceId"), id}};
  };
  return {{QStringLiteral("hostStatus"), QStringLiteral("ready")},
          {QStringLiteral("onboardingCompleted"), true},
          {QStringLiteral("hubBasePath"), QStringLiteral("/api/device-hub/mcs/one")},
          {QStringLiteral("devices"), QJsonArray{device(QStringLiteral("UDID-A"), QStringLiteral("ios")),
                                                 device(QStringLiteral("emulator-5554"), QStringLiteral("android"))}},
          {QStringLiteral("sessions"), QJsonArray{session(QStringLiteral("UDID-A")), session(QStringLiteral("emulator-5554"))}}};
}

}  // namespace

class ThreadDevicesRegression : public QObject {
  Q_OBJECT

  static QVariantMap wizard(const ThreadDevices& devices) {
    return devices.view().value(QStringLiteral("wizard")).toMap();
  }

private slots:
  // A check still out when the thread moved left the wizard busy for good.
  void movingToAnotherMcEndsAWizardCheck() {
    FakeMc mc;
    McClient client;
    QList<FakeMc::Rpc> held;
    mc.onRpc(QStringLiteral("device."), [&held](const FakeMc::Rpc& rpc) { held.append(rpc); });
    mc.onShape(QStringLiteral("devices"), [&mc](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), unconfigured()}});
    });
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    QVERIFY(QTest::qWaitFor([&client] { return client.isReady(); }));

    ThreadDevices devices(&client);
    devices.setThread(mc.environmentId, QStringLiteral("thread"), QStringLiteral("one"));
    QVERIFY(QTest::qWaitFor([&devices] { return !wizard(devices).isEmpty(); }));

    devices.wizardCheck();
    QCOMPARE(wizard(devices).value(QStringLiteral("pending")), QStringLiteral("check"));
    QVERIFY(QTest::qWaitFor([&held] { return !held.isEmpty(); }));
    held.clear();

    devices.setThread(mc.environmentId, QStringLiteral("thread"), QStringLiteral("two"));
    QVERIFY(QTest::qWaitFor([&devices] { return !wizard(devices).isEmpty(); }));
    QCOMPARE(wizard(devices).value(QStringLiteral("pending")).toString(), QString());
  }

  // A refused check looked like nothing having happened.
  void aRefusedCheckSaysWhy() {
    FakeMc mc;
    McClient client;
    QList<FakeMc::Rpc> held;
    mc.onRpc(QStringLiteral("device."), [&held](const FakeMc::Rpc& rpc) { held.append(rpc); });
    mc.onShape(QStringLiteral("devices"), [&mc](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), unconfigured()}});
    });
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    QVERIFY(QTest::qWaitFor([&client] { return client.isReady(); }));

    ThreadDevices devices(&client);
    devices.setThread(mc.environmentId, QStringLiteral("thread"), QStringLiteral("one"));
    QVERIFY(QTest::qWaitFor([&devices] { return !wizard(devices).isEmpty(); }));

    devices.wizardCheck();
    QVERIFY(QTest::qWaitFor([&held] { return !held.isEmpty(); }));
    mc.refuse(held.takeLast(), QStringLiteral("Not allowed"));
    QVERIFY(QTest::qWaitFor([&devices] { return wizard(devices).value(QStringLiteral("pending")).toString().isEmpty(); }));
    QCOMPARE(wizard(devices).value(QStringLiteral("error")), QStringLiteral("Not allowed"));

    devices.wizardCheck();
    QVERIFY(wizard(devices).value(QStringLiteral("error")).toString().isEmpty());
  }

  // Two device tabs shown at once both stream; hiding one stops only it, and
  // closing it drops it.
  void twoShownDevicesStreamAtOnce() {
    FakeMc mc;
    McClient client;
    mc.onRpc(QStringLiteral("device."), [](const FakeMc::Rpc&) {});
    mc.onShape(QStringLiteral("devices"), [&mc](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), twoOpen()}});
    });
    // The hub takes each stream's connection and sends nothing yet.
    mc.onRaw(QStringLiteral("/api/device-hub/"), [](QTcpSocket*, const QByteArray&) {});
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    QVERIFY(QTest::qWaitFor([&client] { return client.isReady(); }));

    ThreadDevices devices(&client);
    const QString iphone = ThreadDevices::tabIdOf(QStringLiteral("local"), QStringLiteral("UDID-A"));
    const QString pixel = ThreadDevices::tabIdOf(QStringLiteral("local"), QStringLiteral("emulator-5554"));
    devices.setTabs({iphone, pixel});
    devices.setShown({iphone, pixel});
    devices.setThread(mc.environmentId, QStringLiteral("thread"), QStringLiteral("one"));
    QVERIFY(QTest::qWaitFor([&devices] { return devices.view().value(QStringLiteral("loaded")).toBool(); }));

    DeviceStream* a = devices.tab(iphone)->stream();
    DeviceStream* b = devices.tab(pixel)->stream();
    QVERIFY(a != b);
    QVERIFY(a->status() != QLatin1String("idle"));
    QVERIFY(b->status() != QLatin1String("idle"));
    QCOMPARE(a->platform(), QStringLiteral("ios"));
    QCOMPARE(b->platform(), QStringLiteral("android"));

    QStringList seen;
    connect(a, &DeviceStream::statusChanged, this, [a, &seen] { seen.append(a->status()); });
    devices.setShown({iphone});
    QCOMPARE(b->status(), QStringLiteral("idle"));
    QVERIFY(devices.tab(pixel)->screen().isValid());
    QVERIFY(!seen.contains(QStringLiteral("idle")));

    devices.setTabs({iphone});
    QVERIFY(!devices.tab(pixel));
    QVERIFY(devices.tab(iphone)->shown());
    QVERIFY(!seen.contains(QStringLiteral("idle")));
  }
};

QTEST_GUILESS_MAIN(ThreadDevicesRegression)
#include "tst_ThreadDevicesRegression.moc"
