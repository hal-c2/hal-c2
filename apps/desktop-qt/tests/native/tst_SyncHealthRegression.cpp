// What the sync properties (tests/prop/tst_Sync*Prop.cpp) found in how the
// shell says its connection is doing, each as the plain case that shows it.

#include <QSignalSpy>
#include <QTest>

#include "ConnectionHealthController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"

class tst_SyncHealthRegression : public QObject {
  Q_OBJECT

private slots:
  // A reconnect is not "connected" before the MC's shell snapshot lands on the
  // new socket: the hello's phase change once said so on the strength of the
  // last connection's snapshot, and took it back a moment later.
  void aReconnectIsNotConnectedBeforeItsSnapshot() {
    FakeMc mc;
    ShellBridge bridge;
    McClient client;
    client.setRetryDelays({20});
    ShellStore store(&client);
    ConnectionHealthController health(&bridge, &client, &store);
    // Each published phase with the snapshots the store had then.
    QList<std::pair<QString, quint64>> said;
    connect(&bridge, &ShellBridge::stateEntryChanged, this, [&](const QString& key, const QVariant& value) {
      if (key == QLatin1String("connection")) said.append({value.toMap().value(QStringLiteral("phase")).toString(), store.snapshots()});
    });
    store.open(mc.origin());
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(!said.isEmpty() && said.last().first == QLatin1String("connected"));

    const quint64 before = store.snapshots();
    said.clear();
    mc.drop();
    QTRY_VERIFY(store.snapshots() > before && !said.isEmpty() && said.last().first == QLatin1String("connected"));
    for (const auto& [phase, snapshots] : said) {
      if (phase == QLatin1String("connected")) QVERIFY2(snapshots > before, "connected before the new snapshot");
    }
  }
};

QTEST_MAIN(tst_SyncHealthRegression)
#include "tst_SyncHealthRegression.moc"
