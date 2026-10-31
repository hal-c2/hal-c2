#include "PushCrypto.h"

#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/param_build.h>
#include <openssl/rand.h>

#include <memory>

namespace push {

namespace {

constexpr int kSaltSize = 16;
constexpr int kTagSize = 16;
constexpr quint32 kRecordSize = 4096;
// salt, record size, key id length, the sender's 65-byte key.
constexpr int kHeaderSize = kSaltSize + 4 + 1 + 65;

using Key = std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)>;

QByteArray random(int size) {
  QByteArray bytes(size, Qt::Uninitialized);
  if (RAND_bytes(reinterpret_cast<unsigned char*>(bytes.data()), size) != 1) return {};
  return bytes;
}

// A P-256 key from its public point and, for one's own, its private scalar.
Key p256(const QByteArray& publicKey, const QByteArray& privateKey = {}) {
  Key none(nullptr, EVP_PKEY_free);
  std::unique_ptr<OSSL_PARAM_BLD, decltype(&OSSL_PARAM_BLD_free)> build(OSSL_PARAM_BLD_new(), OSSL_PARAM_BLD_free);
  std::unique_ptr<BIGNUM, decltype(&BN_clear_free)> scalar(nullptr, BN_clear_free);
  if (!build) return none;
  OSSL_PARAM_BLD_push_utf8_string(build.get(), OSSL_PKEY_PARAM_GROUP_NAME, "prime256v1", 0);
  OSSL_PARAM_BLD_push_octet_string(build.get(), OSSL_PKEY_PARAM_PUB_KEY, publicKey.constData(), publicKey.size());
  if (!privateKey.isEmpty()) {
    scalar.reset(BN_bin2bn(reinterpret_cast<const unsigned char*>(privateKey.constData()), privateKey.size(), nullptr));
    if (!scalar) return none;
    OSSL_PARAM_BLD_push_BN(build.get(), OSSL_PKEY_PARAM_PRIV_KEY, scalar.get());
  }
  std::unique_ptr<OSSL_PARAM, decltype(&OSSL_PARAM_free)> params(OSSL_PARAM_BLD_to_param(build.get()), OSSL_PARAM_free);
  std::unique_ptr<EVP_PKEY_CTX, decltype(&EVP_PKEY_CTX_free)> context(EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr),
                                                                      EVP_PKEY_CTX_free);
  EVP_PKEY* key = nullptr;
  if (!params || !context || EVP_PKEY_fromdata_init(context.get()) != 1 ||
      EVP_PKEY_fromdata(context.get(), &key, privateKey.isEmpty() ? EVP_PKEY_PUBLIC_KEY : EVP_PKEY_KEYPAIR, params.get()) != 1) {
    return none;
  }
  return Key(key, EVP_PKEY_free);
}

QByteArray publicPoint(EVP_PKEY* key) {
  QByteArray point(65, Qt::Uninitialized);
  size_t size = 0;
  if (EVP_PKEY_get_octet_string_param(key, OSSL_PKEY_PARAM_PUB_KEY, reinterpret_cast<unsigned char*>(point.data()), point.size(), &size) != 1 ||
      size != 65) {
    return {};
  }
  return point;
}

QByteArray sharedSecret(EVP_PKEY* own, EVP_PKEY* peer) {
  std::unique_ptr<EVP_PKEY_CTX, decltype(&EVP_PKEY_CTX_free)> context(EVP_PKEY_CTX_new(own, nullptr), EVP_PKEY_CTX_free);
  size_t size = 0;
  if (!context || EVP_PKEY_derive_init(context.get()) != 1 || EVP_PKEY_derive_set_peer(context.get(), peer) != 1 ||
      EVP_PKEY_derive(context.get(), nullptr, &size) != 1) {
    return {};
  }
  QByteArray secret(int(size), Qt::Uninitialized);
  if (EVP_PKEY_derive(context.get(), reinterpret_cast<unsigned char*>(secret.data()), &size) != 1) return {};
  secret.resize(int(size));
  return secret;
}

QByteArray hmac(const QByteArray& key, const QByteArray& data) {
  unsigned char out[32];
  unsigned int size = 0;
  if (!HMAC(EVP_sha256(), key.constData(), key.size(), reinterpret_cast<const unsigned char*>(data.constData()), data.size(), out, &size)) {
    return {};
  }
  return QByteArray(reinterpret_cast<const char*>(out), int(size));
}

struct Derived {
  QByteArray key;
  QByteArray nonce;
};

// RFC 8291 section 3.4 and RFC 8188 section 2.2: the content key and nonce
// from the ECDH secret, the auth secret, both public keys and the salt.
Derived derive(const QByteArray& ecdh, const QByteArray& auth, const QByteArray& receiverPublic, const QByteArray& senderPublic,
               const QByteArray& salt) {
  const QByteArray info = QByteArrayLiteral("WebPush: info") + '\0' + receiverPublic + senderPublic;
  const QByteArray ikm = hmac(hmac(auth, ecdh), info + '\x01');
  const QByteArray prk = hmac(salt, ikm);
  return {hmac(prk, QByteArrayLiteral("Content-Encoding: aes128gcm") + '\0' + '\x01').left(16),
          hmac(prk, QByteArrayLiteral("Content-Encoding: nonce") + '\0' + '\x01').left(12)};
}

std::optional<QByteArray> gcm(bool encrypting, const Derived& derived, const QByteArray& input, QByteArray tag) {
  std::unique_ptr<EVP_CIPHER_CTX, decltype(&EVP_CIPHER_CTX_free)> context(EVP_CIPHER_CTX_new(), EVP_CIPHER_CTX_free);
  const auto* key = reinterpret_cast<const unsigned char*>(derived.key.constData());
  const auto* nonce = reinterpret_cast<const unsigned char*>(derived.nonce.constData());
  if (!context || EVP_CipherInit_ex(context.get(), EVP_aes_128_gcm(), nullptr, key, nonce, encrypting ? 1 : 0) != 1) return std::nullopt;
  QByteArray output(input.size(), Qt::Uninitialized);
  int written = 0;
  if (EVP_CipherUpdate(context.get(), reinterpret_cast<unsigned char*>(output.data()), &written,
                       reinterpret_cast<const unsigned char*>(input.constData()), input.size()) != 1) {
    return std::nullopt;
  }
  if (!encrypting && EVP_CIPHER_CTX_ctrl(context.get(), EVP_CTRL_GCM_SET_TAG, kTagSize, tag.data()) != 1) return std::nullopt;
  int last = 0;
  if (EVP_CipherFinal_ex(context.get(), reinterpret_cast<unsigned char*>(output.data()) + written, &last) != 1) return std::nullopt;
  if (encrypting) {
    tag.resize(kTagSize);
    if (EVP_CIPHER_CTX_ctrl(context.get(), EVP_CTRL_GCM_GET_TAG, kTagSize, tag.data()) != 1) return std::nullopt;
    output += tag;
  }
  return output;
}

}  // namespace

Keys generateKeys() {
  Key key(EVP_PKEY_Q_keygen(nullptr, nullptr, "EC", "P-256"), EVP_PKEY_free);
  if (!key) return {};
  BIGNUM* scalar = nullptr;
  if (EVP_PKEY_get_bn_param(key.get(), OSSL_PKEY_PARAM_PRIV_KEY, &scalar) != 1) return {};
  QByteArray privateKey(32, Qt::Uninitialized);
  const bool padded = BN_bn2binpad(scalar, reinterpret_cast<unsigned char*>(privateKey.data()), 32) == 32;
  BN_clear_free(scalar);
  if (!padded) return {};
  return {privateKey, publicPoint(key.get()), random(16)};
}

std::optional<QByteArray> decrypt(const QByteArray& body, const Keys& keys) {
  if (!keys.valid() || body.size() < kHeaderSize + kTagSize + 1) return std::nullopt;
  const QByteArray salt = body.left(kSaltSize);
  if (quint8(body.at(kSaltSize + 4)) != 65) return std::nullopt;
  const QByteArray senderPublic = body.mid(kSaltSize + 5, 65);
  const QByteArray record = body.mid(kHeaderSize);
  Key own = p256(keys.publicKey, keys.privateKey);
  Key sender = p256(senderPublic);
  if (!own || !sender) return std::nullopt;
  const QByteArray ecdh = sharedSecret(own.get(), sender.get());
  if (ecdh.isEmpty()) return std::nullopt;
  const Derived derived = derive(ecdh, keys.auth, keys.publicKey, senderPublic, salt);
  std::optional<QByteArray> padded = gcm(false, derived, record.chopped(kTagSize), record.right(kTagSize));
  if (!padded) return std::nullopt;
  // The last record ends in 0x02, then any zeros of padding.
  qsizetype end = padded->size();
  while (end > 0 && padded->at(end - 1) == '\0') --end;
  if (end == 0 || padded->at(end - 1) != '\x02') return std::nullopt;
  return padded->left(end - 1);
}

QByteArray encrypt(const QByteArray& plaintext, const QByteArray& receiverPublicKey, const QByteArray& auth) {
  Key sender(EVP_PKEY_Q_keygen(nullptr, nullptr, "EC", "P-256"), EVP_PKEY_free);
  Key receiver = p256(receiverPublicKey);
  if (!sender || !receiver) return {};
  const QByteArray senderPublic = publicPoint(sender.get());
  const QByteArray ecdh = sharedSecret(sender.get(), receiver.get());
  const QByteArray saltBytes = random(kSaltSize);
  if (senderPublic.isEmpty() || ecdh.isEmpty() || saltBytes.size() != kSaltSize) return {};
  const std::optional<QByteArray> record = gcm(true, derive(ecdh, auth, receiverPublicKey, senderPublic, saltBytes), plaintext + '\x02', {});
  if (!record) return {};
  QByteArray header = saltBytes;
  header.append(char(kRecordSize >> 24)).append(char((kRecordSize >> 16) & 0xff)).append(char((kRecordSize >> 8) & 0xff)).append(char(kRecordSize & 0xff));
  header.append(char(65)).append(senderPublic);
  return header + *record;
}

}  // namespace push
