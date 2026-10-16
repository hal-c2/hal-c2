// Which environments the shell takes to run on this machine (thisMachine):
// by the machine's id where both sides have one, else by being the shell's
// own MC on a loopback address.

#include <QCryptographicHash>
#include <QRegularExpression>
#include <QSysInfo>
#include <QTest>

#include "ThisMachine.h"

namespace {

const QString kHere = QStringLiteral("5e1f00000000000000000000000000000000000000000000000000000000c0de");
const QString kElsewhere = QStringLiteral("a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1");

QJsonObject on(const QString& machine) {
  return {{QStringLiteral("platform"), QJsonObject{{QStringLiteral("machineId"), machine}}}};
}

}  // namespace

class ThisMachineTest : public QObject {
  Q_OBJECT

private slots:
  void cleanup() { thisMachine::setIdForTesting(std::nullopt); }

  void idIsTheHashTheMcServes() {
    const QByteArray raw = QSysInfo::machineUniqueId();
    if (raw.isEmpty()) {
      QCOMPARE(thisMachine::id(), QString());
      return;
    }
    QCOMPARE(thisMachine::id(), QString::fromLatin1(QCryptographicHash::hash(raw, QCryptographicHash::Sha256).toHex()));
    QVERIFY(QRegularExpression(QStringLiteral("^[0-9a-f]{64}$")).match(thisMachine::id()).hasMatch());
  }

  void loopbackHosts() {
    for (const char* host : {"localhost", "LOCALHOST", "127.0.0.1", "127.8.9.10", "::1"}) {
      QVERIFY2(thisMachine::loopbackHost(QString::fromLatin1(host)), host);
    }
    for (const char* host : {"", "192.168.1.20", "100.64.0.7", "devbox", "localhost.example.com", "::2"}) {
      QVERIFY2(!thisMachine::loopbackHost(QString::fromLatin1(host)), host);
    }
  }

  void idsDecideWhenBothAreKnown() {
    thisMachine::setIdForTesting(kHere);
    const QUrl loopback(QStringLiteral("ws://127.0.0.1:3773"));
    const QUrl lan(QStringLiteral("ws://192.168.1.20:3773"));
    // A cluster member on this machine, reached through another MC.
    QVERIFY(thisMachine::hosts(on(kHere), false, lan));
    // An SSH port forward: loopback, but another machine.
    QVERIFY(!thisMachine::hosts(on(kElsewhere), true, loopback));
  }

  void withoutIdsOnlyTheOwnMcOnLoopbackIsHere() {
    thisMachine::setIdForTesting(kHere);
    QVERIFY(thisMachine::hosts({}, true, QUrl(QStringLiteral("ws://localhost:3773"))));
    QVERIFY(thisMachine::hosts({}, true, QUrl(QStringLiteral("ws://[::1]:3773"))));
    QVERIFY(!thisMachine::hosts({}, true, QUrl(QStringLiteral("wss://devbox.tailnet.ts.net"))));
    QVERIFY(!thisMachine::hosts({}, false, QUrl(QStringLiteral("ws://127.0.0.1:3773"))));
    // A machine with no id of its own (Android) goes by the address alone.
    thisMachine::setIdForTesting(QString());
    QVERIFY(thisMachine::hosts(on(kElsewhere), true, QUrl(QStringLiteral("ws://127.0.0.1:3773"))));
    QVERIFY(!thisMachine::hosts(on(kHere), false, QUrl(QStringLiteral("ws://127.0.0.1:3773"))));
    QVERIFY(!thisMachine::hosts(on(kHere), true, QUrl()));
  }
};

QTEST_GUILESS_MAIN(ThisMachineTest)
#include "tst_ThisMachine.moc"
