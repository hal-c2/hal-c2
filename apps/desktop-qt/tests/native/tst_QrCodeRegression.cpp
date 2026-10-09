// What tests/fuzz/tst_QrCodeFuzz.cpp found in qr::encode: a NUL byte in the
// text ended it, so the text after the NUL was not in the code.

#include <QtTest>

#include "QrCode.h"

namespace {

bool sameCode(const qr::Code& a, const qr::Code& b) {
  return a.size == b.size && a.modules == b.modules;
}

}  // namespace

class tst_QrCodeRegression : public QObject {
  Q_OBJECT

private slots:
  void textAfterNulIsEncoded() {
    const QString before = QStringLiteral("a");
    const QString after = QStringLiteral("b");
    const qr::Code whole = qr::encode(before + QChar(0) + after);
    QVERIFY(!whole.isNull());
    QVERIFY2(!sameCode(whole, qr::encode(before)), "the code of \"a\\0b\" is the code of \"a\"");
  }

  void nulThenTooLongIsNoCode() {
    const QString text = QChar(0) + QString(3000, QLatin1Char('a'));
    QVERIFY(qr::encode(text).isNull());
  }
};

QTEST_APPLESS_MAIN(tst_QrCodeRegression)
#include "tst_QrCodeRegression.moc"
