// What tests/prop/tst_McClientRenewalProp.cpp found in McClient.

#include <QtTest>

#include <QTcpSocket>

#include "FakeMc.h"
#include "McClient.h"

class McClientRenewalRegression : public QObject {
  Q_OBJECT

private slots:
  // A credential about to run out was renewed before a ticket was bought, but
  // a client whose MC took the bare token reconnected with it unrenewed.
  void aBareTokenIsRenewedBeforeItReconnects() {
    FakeMc mc;
    int renewals = 0;
    mc.onRaw(QStringLiteral("/api/auth/session/renew"), [&](QTcpSocket* socket, const QByteArray&) {
      ++renewals;
      socket->readAll();
      const QByteArray body = "{\"expiresAt\":\"" + QDateTime::currentDateTimeUtc().addDays(30).toString(Qt::ISODateWithMs).toUtf8() + "\"}";
      socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + QByteArray::number(body.size()) +
                    "\r\nConnection: close\r\n\r\n" + body);
      socket->disconnectFromHost();
    });
    McClient client;
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"), mc.environmentId);
    QTRY_VERIFY(client.isReady());
    client.setCredentialExpiry(QDateTime::currentDateTimeUtc().addSecs(60));
    const qsizetype sockets = mc.connections.size();
    client.reconnect();
    QTRY_VERIFY(client.isReady() && mc.connections.size() > sockets);
    QCOMPARE(renewals, 1);
    QVERIFY(client.credentialExpiry() > QDateTime::currentDateTimeUtc().addDays(1));
  }
};

QTEST_GUILESS_MAIN(McClientRenewalRegression)
#include "tst_McClientRenewalRegression.moc"
