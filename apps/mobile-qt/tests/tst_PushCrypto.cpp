// Web Push decryption on the phone (src/push/PushCrypto): the RFC 8291
// example the MC's encryption is checked against too
// (apps/server-ex/test/hal_c2/push/web_push_test.exs), and messages the
// phone's own keys open while others' do not.

#include <QTest>

#include "PushCrypto.h"

namespace {

QByteArray b64(const char* text) {
  return QByteArray::fromBase64(QByteArray(text), QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
}

// RFC 8291, Appendix A.
const QByteArray kPlaintext("When I grow up, I want to be a watermelon");
const char* const kUaPublic = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4";
const char* const kUaPrivate = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94";
const char* const kAuth = "BTBZMqHH6r4Tts7J_aSIgg";
const char* const kBody =
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";

}  // namespace

class PushCryptoTest : public QObject {
  Q_OBJECT

private slots:
  void opensTheRfcExample() {
    const push::Keys keys{b64(kUaPrivate), b64(kUaPublic), b64(kAuth)};
    QVERIFY(keys.valid());
    const auto opened = push::decrypt(b64(kBody), keys);
    QVERIFY(opened.has_value());
    QCOMPARE(*opened, kPlaintext);
  }

  void opensWhatWasSentToItsKeys() {
    const push::Keys keys = push::generateKeys();
    QVERIFY(keys.valid());
    const QByteArray json(R"({"v":1,"sentAt":1})");
    const QByteArray first = push::encrypt(json, keys.publicKey, keys.auth);
    const QByteArray second = push::encrypt(json, keys.publicKey, keys.auth);
    QVERIFY(first != second);
    QCOMPARE(push::decrypt(first, keys).value_or(QByteArray()), json);
    QCOMPARE(push::decrypt(second, keys).value_or(QByteArray()), json);
  }

  void refusesWhatIsNotForIt() {
    const push::Keys mine = push::generateKeys();
    const push::Keys theirs = push::generateKeys();
    const QByteArray body = push::encrypt("hello", theirs.publicKey, theirs.auth);
    QVERIFY(!push::decrypt(body, mine).has_value());
    // The right key with another auth secret.
    QVERIFY(!push::decrypt(body, push::Keys{theirs.privateKey, theirs.publicKey, mine.auth}).has_value());
    QByteArray tampered = body;
    tampered[tampered.size() - 1] = char(tampered.at(tampered.size() - 1) ^ 1);
    QVERIFY(!push::decrypt(tampered, theirs).has_value());
    QVERIFY(!push::decrypt(QByteArray("short"), theirs).has_value());
  }
};

QTEST_GUILESS_MAIN(PushCryptoTest)
#include "tst_PushCrypto.moc"
