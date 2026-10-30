// What tests/prop/tst_DeviceToolsProp.cpp found in DeviceTools.

#include <QtTest>

#include "DeviceTools.h"
#include "FakeMc.h"
#include "McClient.h"

class DeviceToolsRegression : public QObject {
  Q_OBJECT

private slots:
  // The settings read on opening the drawer, answered while a change was
  // out, ended the change: the controls came back while it still ran.
  void aReadLandingDuringAChangeKeepsTheDrawerBusy() {
    FakeMc mc;
    McClient client;
    QList<FakeMc::Rpc> held;
    mc.onRpc(QStringLiteral("device."), [&held](const FakeMc::Rpc& rpc) { held.append(rpc); });
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    QVERIFY(QTest::qWaitFor([&client] { return client.isReady(); }));

    DeviceTools tools(&client);
    tools.setOpen(true);
    tools.setTarget(mc.environmentId, QStringLiteral("/hub"), QStringLiteral("local"), QStringLiteral("tablet"), QStringLiteral("ios"));
    tools.choose(QStringLiteral("Appearance"), QStringLiteral("Dark"));
    QVERIFY(QTest::qWaitFor([&held] { return held.size() == 2; }));
    QCOMPARE(held.at(0).method, QStringLiteral("device.detail"));

    mc.reply(held.at(0), QJsonObject{{QStringLiteral("deviceId"), QStringLiteral("tablet")},
                                     {QStringLiteral("settings"), QJsonObject{{QStringLiteral("appearance"), QStringLiteral("light")}}},
                                     {QStringLiteral("foregroundApp"), QJsonValue::Null}});
    QVERIFY(QTest::qWaitFor([&tools] { return tools.view().value(QStringLiteral("loaded")).toBool(); }));
    QVERIFY(tools.view().value(QStringLiteral("pending")).toBool());
  }
};

QTEST_GUILESS_MAIN(DeviceToolsRegression)
#include "tst_DeviceToolsRegression.moc"
