// What tests/prop/tst_PairingExchangeProp.cpp could not reach in readInvitation.

#include <QtTest>

#include "PairingExchange.h"

namespace {

QString wrapped(const QString& link) { return QStringLiteral("hal-c2://pair?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(link)); }

// A pairing link of `size` characters or a little over.
QString linkOf(qsizetype size) {
  QString link = QStringLiteral("https://mc.example.test:8443/pair?");
  while (link.size() < size) link += QStringLiteral("&a=b");
  return link + QStringLiteral("#token=abc");
}

}  // namespace

class PairingExchangeRegression : public QObject {
  Q_OBJECT

private slots:
  // The cap on an invitation's length counted the app's own link, which holds
  // the pairing link percent-encoded: a link of 1500 characters is some 3000
  // wrapped, and was turned away for being too long.
  void aLinkWithinTheCapIsReadWrappedToo() {
    const QString link = linkOf(1500);
    QVERIFY(wrapped(link).size() > 2048);
    const auto plain = pairing::readInvitation(link);
    QVERIFY(plain);
    QCOMPARE(plain->link, link);
    const auto carried = pairing::readInvitation(wrapped(link));
    QVERIFY(carried);
    QCOMPARE(carried->link, link);
    QCOMPARE(carried->address, plain->address);
  }

  // The cap on the link itself holds whether or not it is wrapped.
  void aLinkOverTheCapIsTurnedAwayWrappedOrNot() {
    const QString link = linkOf(2100);
    QVERIFY(!pairing::readInvitation(link));
    QVERIFY(!pairing::readInvitation(wrapped(link)));
  }

  // The wrapper has a cap of its own, so that nothing is decoded however long.
  void aWrapperBeyondAnyLinkIsTurnedAway() {
    QVERIFY(!pairing::readInvitation(wrapped(linkOf(1500)) + QString(8000, QLatin1Char('a'))));
  }
};

QTEST_GUILESS_MAIN(PairingExchangeRegression)
#include "tst_PairingExchangeRegression.moc"
