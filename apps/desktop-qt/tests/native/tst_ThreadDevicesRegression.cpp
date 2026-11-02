// What the review of the device setup wizard found in ThreadDevices.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "ThreadDevices.h"

namespace {

QJsonObject unconfigured() {
  return {{QStringLiteral("hostStatus"), QStringLiteral("disabled")}, {QStringLiteral("onboardingCompleted"), false}};
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
};

QTEST_GUILESS_MAIN(ThreadDevicesRegression)
#include "tst_ThreadDevicesRegression.moc"
