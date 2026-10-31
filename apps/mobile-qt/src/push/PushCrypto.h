#pragma once

#include <QByteArray>

#include <optional>

// Web Push message encryption (RFC 8291, aes128gcm of RFC 8188), which is how
// an MC's pushes reach the phone through the user's UnifiedPush distributor
// without the distributor reading them. The phone makes its keys once
// (generateKeys), hands the MC the public half and the auth secret with its
// registration (hal-c2.registerPush), and opens each message with decrypt.
// encrypt is the MC's half, which the phone's scenarios send with.
namespace push {

struct Keys {
  // The P-256 private scalar, 32 bytes.
  QByteArray privateKey;
  // The public point, uncompressed: 65 bytes starting 0x04 (`p256dh`).
  QByteArray publicKey;
  // 16 random bytes (`auth`).
  QByteArray auth;

  bool valid() const { return privateKey.size() == 32 && publicKey.size() == 65 && auth.size() == 16; }
};

Keys generateKeys();

// The plaintext of one aes128gcm message for `keys`; nothing when it is not
// one, or not for them.
std::optional<QByteArray> decrypt(const QByteArray& body, const Keys& keys);

// One aes128gcm record for the receiver's public key and auth secret, with a
// fresh sender key and salt.
QByteArray encrypt(const QByteArray& plaintext, const QByteArray& receiverPublicKey, const QByteArray& auth);

}  // namespace push
