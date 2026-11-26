//! Web Push message encryption (RFC 8291, aes128gcm of RFC 8188),
//! mobile-qt's push/PushCrypto in pure Rust: how an MC's pushes reach
//! the phone through the user's UnifiedPush distributor without the
//! distributor reading them. The phone makes its keys once
//! ([`generate_keys`]), hands the MC the public half and the auth
//! secret with its registration (`hal-c2.registerPush`), and opens
//! each message with [`decrypt`]. [`encrypt`] is the MC's half, which
//! the phone's scenarios send with.
//!
//! The C++ used OpenSSL EVP; here the P-256 key agreement is `p256`
//! (ring cannot rebuild a private key from the scalar the inbox
//! keeps) and HMAC-SHA256 with AES-128-GCM is `ring`, which the MC
//! client's rustls already brings. One record per message, as the
//! C++ read and wrote them: a body of several records (a plaintext
//! over the record size less its tag and delimiter) is refused, as
//! it was there.

use p256::elliptic_curve::point::AffineCoordinates;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{ProjectivePoint, PublicKey, SecretKey};
use ring::aead::{AES_128_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use ring::hmac::{HMAC_SHA256, Key, sign};
use ring::rand::{SecureRandom, SystemRandom};

const SALT_SIZE: usize = 16;
const TAG_SIZE: usize = 16;
const RECORD_SIZE: u32 = 4096;
/// salt, record size, key id length, the sender's 65-byte key.
const HEADER_SIZE: usize = SALT_SIZE + 4 + 1 + 65;

/// This phone's push keys, as the inbox keeps them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Keys {
    /// The P-256 private scalar, 32 bytes.
    pub private_key: Vec<u8>,
    /// The public point, uncompressed: 65 bytes starting 0x04 (`p256dh`).
    pub public_key: Vec<u8>,
    /// 16 random bytes (`auth`).
    pub auth: Vec<u8>,
}

impl Keys {
    pub fn valid(&self) -> bool {
        self.private_key.len() == 32 && self.public_key.len() == 65 && self.auth.len() == 16
    }
}

fn random(size: usize) -> Option<Vec<u8>> {
    let mut bytes = vec![0u8; size];
    SystemRandom::new().fill(&mut bytes).ok()?;
    Some(bytes)
}

/// One P-256 key pair from a fresh scalar: the scalar and its
/// uncompressed public point.
fn key_pair() -> Option<(Vec<u8>, Vec<u8>)> {
    // A scalar of 32 random bytes is a key but for the few at or over
    // the curve order; asking the curve settles it.
    loop {
        let scalar = random(32)?;
        if let Ok(secret) = SecretKey::from_slice(&scalar) {
            let public = secret.public_key().to_sec1_bytes().to_vec();
            return Some((scalar, public));
        }
    }
}

pub fn generate_keys() -> Keys {
    let Some((private_key, public_key)) = key_pair() else {
        return Keys::default();
    };
    let Some(auth) = random(16) else {
        return Keys::default();
    };
    Keys {
        private_key,
        public_key,
        auth,
    }
}

fn shared_secret(private_key: &[u8], peer_public: &[u8]) -> Option<Vec<u8>> {
    // Raw ECDH (the shared point's x), as EVP_PKEY_derive gave the
    // C++: elliptic-curve's ecdh feature would do this, but it also
    // wants hkdf, which no crate here otherwise needs.
    let secret = SecretKey::from_slice(private_key).ok()?;
    let peer = PublicKey::from_sec1_bytes(peer_public).ok()?;
    let shared = (ProjectivePoint::from(*peer.as_affine()) * secret.to_nonzero_scalar().as_ref())
        .to_affine();
    // The identity point has no x to share; it is not a 65-byte point.
    if shared.to_encoded_point(false).as_bytes().len() != 65 {
        return None;
    }
    Some(shared.x().to_vec())
}

fn hmac(key: &[u8], data: &[u8]) -> Vec<u8> {
    sign(&Key::new(HMAC_SHA256, key), data).as_ref().to_vec()
}

struct Derived {
    key: Vec<u8>,
    nonce: Vec<u8>,
}

/// RFC 8291 section 3.4 and RFC 8188 section 2.2: the content key and
/// nonce from the ECDH secret, the auth secret, both public keys and
/// the salt.
fn derive(
    ecdh: &[u8],
    auth: &[u8],
    receiver_public: &[u8],
    sender_public: &[u8],
    salt: &[u8],
) -> Derived {
    let mut info = b"WebPush: info\0".to_vec();
    info.extend_from_slice(receiver_public);
    info.extend_from_slice(sender_public);
    let mut expand = info.clone();
    expand.push(1);
    let ikm = hmac(&hmac(auth, ecdh), &expand);
    let prk = hmac(salt, &ikm);
    Derived {
        key: hmac(&prk, b"Content-Encoding: aes128gcm\0\x01")[..16].to_vec(),
        nonce: hmac(&prk, b"Content-Encoding: nonce\0\x01")[..12].to_vec(),
    }
}

fn seal(derived: &Derived, plaintext: &[u8]) -> Option<Vec<u8>> {
    let key = LessSafeKey::new(UnboundKey::new(&AES_128_GCM, &derived.key).ok()?);
    let nonce = Nonce::try_assume_unique_for_key(&derived.nonce).ok()?;
    let mut record = plaintext.to_vec();
    key.seal_in_place_append_tag(nonce, Aad::empty(), &mut record)
        .ok()?;
    Some(record)
}

fn open(derived: &Derived, record: &[u8]) -> Option<Vec<u8>> {
    let key = LessSafeKey::new(UnboundKey::new(&AES_128_GCM, &derived.key).ok()?);
    let nonce = Nonce::try_assume_unique_for_key(&derived.nonce).ok()?;
    let mut padded = record.to_vec();
    let plain = key.open_in_place(nonce, Aad::empty(), &mut padded).ok()?;
    Some(plain.to_vec())
}

/// The plaintext of one aes128gcm message for `keys`; nothing when it
/// is not one, or not for them.
pub fn decrypt(body: &[u8], keys: &Keys) -> Option<Vec<u8>> {
    if !keys.valid() || body.len() < HEADER_SIZE + TAG_SIZE + 1 {
        return None;
    }
    let salt = &body[..SALT_SIZE];
    if body[SALT_SIZE + 4] != 65 {
        return None;
    }
    let sender_public = &body[SALT_SIZE + 5..HEADER_SIZE];
    let record = &body[HEADER_SIZE..];
    let ecdh = shared_secret(&keys.private_key, sender_public)?;
    let derived = derive(&ecdh, &keys.auth, &keys.public_key, sender_public, salt);
    let padded = open(&derived, record)?;
    // The last record ends in 0x02, then any zeros of padding.
    let mut end = padded.len();
    while end > 0 && padded[end - 1] == 0 {
        end -= 1;
    }
    if end == 0 || padded[end - 1] != 2 {
        return None;
    }
    Some(padded[..end - 1].to_vec())
}

/// One aes128gcm record for the receiver's public key and auth
/// secret, with a fresh sender key and salt; empty when it cannot be
/// made.
pub fn encrypt(plaintext: &[u8], receiver_public_key: &[u8], auth: &[u8]) -> Vec<u8> {
    let made = (|| {
        let (sender_private, sender_public) = key_pair()?;
        let ecdh = shared_secret(&sender_private, receiver_public_key)?;
        let salt = random(SALT_SIZE)?;
        let mut padded = plaintext.to_vec();
        padded.push(2);
        let record = seal(
            &derive(&ecdh, auth, receiver_public_key, &sender_public, &salt),
            &padded,
        )?;
        let mut body = salt;
        body.extend_from_slice(&RECORD_SIZE.to_be_bytes());
        body.push(65);
        body.extend_from_slice(&sender_public);
        body.extend_from_slice(&record);
        Some(body)
    })();
    made.unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};

    fn b64(text: &str) -> Vec<u8> {
        URL_SAFE_NO_PAD.decode(text).expect("the RFC's base64url")
    }

    // RFC 8291, Appendix A: the example the MC's encryption is checked
    // against too (apps/server-ex/test/hal_c2/push/web_push_test.exs),
    // carried from mobile-qt's tst_PushCrypto.
    #[test]
    fn opens_the_rfc_example() {
        let keys = Keys {
            private_key: b64("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"),
            public_key: b64(
                "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
            ),
            auth: b64("BTBZMqHH6r4Tts7J_aSIgg"),
        };
        assert!(keys.valid());
        let opened = decrypt(
            &b64(
                "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
            ),
            &keys,
        );
        assert_eq!(
            opened.as_deref(),
            Some(b"When I grow up, I want to be a watermelon".as_slice())
        );
    }

    #[test]
    fn opens_what_was_sent_to_its_keys() {
        let keys = generate_keys();
        assert!(keys.valid());
        let json = br#"{"v":1,"sentAt":1}"#;
        let first = encrypt(json, &keys.public_key, &keys.auth);
        let second = encrypt(json, &keys.public_key, &keys.auth);
        assert_ne!(first, second);
        assert_eq!(decrypt(&first, &keys).as_deref(), Some(json.as_slice()));
        assert_eq!(decrypt(&second, &keys).as_deref(), Some(json.as_slice()));
    }

    #[test]
    fn refuses_what_is_not_for_it() {
        let mine = generate_keys();
        let theirs = generate_keys();
        let body = encrypt(b"hello", &theirs.public_key, &theirs.auth);
        assert_eq!(decrypt(&body, &mine), None);
        // The right key with another auth secret.
        let wrong_auth = Keys {
            auth: mine.auth.clone(),
            ..theirs.clone()
        };
        assert_eq!(decrypt(&body, &wrong_auth), None);
        let mut tampered = body.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert_eq!(decrypt(&tampered, &theirs), None);
        assert_eq!(decrypt(b"short", &theirs), None);
    }
}
