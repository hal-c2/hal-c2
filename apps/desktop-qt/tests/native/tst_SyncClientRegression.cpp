// What the sync properties (tests/prop/tst_Sync*Prop.cpp) found in the
// client's connection to its MC, each as the plain case that shows it.

#include <QJsonObject>
#include <QSignalSpy>
#include <QTest>

#include <optional>

#include "FakeMc.h"
#include "McClient.h"

class tst_SyncClientRegression : public QObject {
  Q_OBJECT

private slots:
  // A call the MC holds while the client reconnects was carried by the socket
  // reconnect() closed: it is answered "disconnected", as after a drop,
  // instead of never.
  void reconnectFailsTheCallsInFlight() {
    FakeMc mc;
    mc.onRpc(QStringLiteral("prop.held"), [&mc](const FakeMc::Rpc& rpc) { mc.defer([&mc, rpc] { mc.reply(rpc, true); }); });
    McClient client;
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());

    QObject caller;
    QStringList replies;
    client.call(&caller, {}, QStringLiteral("prop.held"), {}, [&replies](const QJsonValue&, const std::optional<QString>& error) {
      replies.append(error.value_or(QStringLiteral("result")));
    });
    QTRY_COMPARE(mc.calls.size(), 1);

    client.reconnect();
    QCOMPARE(replies, QStringList{QStringLiteral("disconnected")});
    QTRY_VERIFY(client.isReady());
    // The held answer goes nowhere: the connection it was for is gone.
    mc.answerHeld();
    bool barrier = false;
    client.call(&caller, {}, QStringLiteral("test.barrier"), {}, [&barrier](const QJsonValue&, const std::optional<QString>&) { barrier = true; });
    QTRY_VERIFY(barrier);
    QCOMPARE(replies, QStringList{QStringLiteral("disconnected")});
  }

  // close() answers what was in flight too; a client being destroyed answers
  // nobody, its callers going with it.
  void closeFailsTheCallsInFlight() {
    FakeMc mc;
    mc.onRpc(QStringLiteral("prop.held"), [&mc](const FakeMc::Rpc& rpc) { mc.defer([&mc, rpc] { mc.reply(rpc, true); }); });
    QObject caller;
    QStringList replies;
    const auto record = [&replies](const QJsonValue&, const std::optional<QString>& error) { replies.append(error.value_or(QStringLiteral("result"))); };
    {
      McClient client;
      client.open(mc.origin(), QStringLiteral("token"));
      QTRY_VERIFY(client.isReady());
      client.call(&caller, {}, QStringLiteral("prop.held"), {}, record);
      QTRY_COMPARE(mc.calls.size(), 1);
      client.close();
      QCOMPARE(replies, QStringList{QStringLiteral("disconnected")});

      client.open(mc.origin(), QStringLiteral("token"));
      QTRY_VERIFY(client.isReady());
      client.call(&caller, {}, QStringLiteral("prop.held"), {}, record);
      QTRY_COMPARE(mc.calls.size(), 2);
    }
    QCOMPARE(replies, QStringList{QStringLiteral("disconnected")});
  }

  // The calls a drop fails are answered in the order they were made, not in
  // the call table's hash order.
  void aDropFailsTheCallsInTheOrderMade() {
    FakeMc mc;
    mc.onRpc(QStringLiteral("prop.held"), [&mc](const FakeMc::Rpc& rpc) { mc.defer([&mc, rpc] { mc.reply(rpc, true); }); });
    McClient client;
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());
    QObject caller;
    QList<int> order;
    QList<int> made;
    for (int n = 0; n < 40; ++n) {
      made.append(n);
      client.call(&caller, {}, QStringLiteral("prop.held"), {}, [&order, n](const QJsonValue&, const std::optional<QString>&) { order.append(n); });
    }
    QTRY_COMPARE(mc.calls.size(), 40);
    client.close();
    QCOMPARE(order, made);
  }

  // Opened again without a close (pairing anew), the client kept its old socket
  // open beside the new one, and read the frames of both.
  void openedAgainItHoldsOneSocket() {
    FakeMc mc;
    McClient client;
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());
    QTRY_COMPARE(mc.openSockets(), 1);
    QCOMPARE(mc.connections.size(), 2);
  }

  // A socket the MC took and never said hello on left the client connecting
  // for good.
  void aSocketWithoutHelloIsGivenUpOn() {
    FakeMc mc;
    mc.sayHello = false;
    McClient client;
    client.setRetryDelays({20});
    client.setSetupTimeout(200);
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_COMPARE(client.phase(), McClient::Phase::Retrying);
    QCOMPARE(client.failure(), QStringLiteral("timeout"));
    mc.sayHello = true;
    QTRY_VERIFY(client.isReady());
  }

  // Every hello started the delays over, so an MC that dropped each connection
  // as soon as it was up was asked again every half second.
  void aConnectionThatDropsAtOnceIsRetriedMoreSlowly() {
    FakeMc mc;
    McClient client;
    client.setRetryDelays({20, 40, 80});
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());
    QList<int> delays;
    for (int i = 0; i < 3; ++i) {
      mc.drop();
      QTRY_COMPARE(client.phase(), McClient::Phase::Retrying);
      delays.append(client.retryDelay());
      QTRY_VERIFY(client.isReady());
    }
    QCOMPARE(delays, (QList<int>{20, 40, 80}));
  }

  // One that held starts them over.
  void aConnectionThatHeldStartsTheDelaysOver() {
    FakeMc mc;
    McClient client;
    client.setRetryDelays({20, 40, 80});
    client.setSteadyAfter(50);
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());
    mc.drop();
    QTRY_COMPARE(client.phase(), McClient::Phase::Retrying);
    QCOMPARE(client.retryDelay(), 20);
    QTRY_VERIFY(client.isReady());
    QTest::qWait(100);
    mc.drop();
    QTRY_COMPARE(client.phase(), McClient::Phase::Retrying);
    QCOMPARE(client.retryDelay(), 20);
  }
};

QTEST_MAIN(tst_SyncClientRegression)
#include "tst_SyncClientRegression.moc"
