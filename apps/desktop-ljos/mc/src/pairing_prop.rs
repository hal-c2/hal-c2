//! Properties of the pairing links (`pairing.rs`), ported from
//! apps/desktop-qt/tests/prop/tst_PairingExchangeProp.cpp: a link printed
//! reads back, one typed without its scheme is tried over HTTPS then HTTP,
//! an invitation reads back the same wrapped in the app's link or not, and
//! text nobody chose is no invitation unless it is a plain pairing link.
//! The exchange against scripted MCs is in `pairing_exchange_prop.rs`.

use proptest::prelude::*;

use crate::pairing::{Invitation, read_invitation, read_link};

/// A pairing link as an MC's QR code or the user writes it.
#[derive(Clone, Debug)]
struct Printed {
    scheme: &'static str,
    /// The host as written, and as the origin spells it (punycode).
    host: &'static str,
    ascii_host: &'static str,
    port: Option<u16>,
    path: &'static str,
    token: String,
    /// The token in the fragment, as an MC's QR code has it, or in the query.
    in_fragment: bool,
}

impl Printed {
    fn address(&self) -> String {
        match self.port {
            Some(port) => format!("{}:{port}", self.host),
            None => self.host.to_owned(),
        }
    }

    fn print(&self, with_scheme: bool) -> String {
        let scheme = if with_scheme {
            format!("{}://", self.scheme)
        } else {
            String::new()
        };
        let sign = if self.in_fragment { '#' } else { '?' };
        let token = url::form_urlencoded::byte_serialize(self.token.as_bytes())
            .collect::<String>()
            .replace('+', "%20");
        format!("{scheme}{}{}{sign}token={token}", self.address(), self.path)
    }

    /// The origin of this link's host and port under `scheme`, as it reads
    /// back: the port the user wrote stays, but not where it is the
    /// scheme's own.
    fn origin(&self, scheme: &str) -> String {
        let default = if scheme == "https" { 443 } else { 80 };
        match self.port.filter(|port| *port != default) {
            Some(port) => format!("{scheme}://{}:{port}", self.ascii_host),
            None => format!("{scheme}://{}", self.ascii_host),
        }
    }
}

/// What `mix hal_c2.pair` makes, and what an MC may yet: base64 of either
/// kind, and characters a link has to escape.
fn token() -> impl Strategy<Value = String> {
    let alphabet: Vec<char> = "abcXYZ0129-_+/=~.&#%?é ".chars().collect();
    proptest::collection::vec(proptest::sample::select(alphabet), 1..24).prop_map(|chars| {
        // A token is read trimmed.
        let text: String = chars.into_iter().collect();
        let text = text.trim();
        if text.is_empty() {
            "t".into()
        } else {
            text.into()
        }
    })
}

fn printed() -> impl Strategy<Value = Printed> {
    (
        prop_oneof![Just("http"), Just("https")],
        prop_oneof![
            Just(("127.0.0.1", "127.0.0.1")),
            Just(("devbox.tailnet.ts.net", "devbox.tailnet.ts.net")),
            Just(("localhost", "localhost")),
            Just(("mc.example", "mc.example")),
            Just(("bücher.example", "xn--bcher-kva.example")),
            Just(("[::1]", "[::1]")),
        ],
        prop_oneof![
            Just(None),
            Just(Some(80)),
            Just(Some(443)),
            Just(Some(3797)),
            Just(Some(65535)),
        ],
        prop_oneof![Just("/"), Just("/pair"), Just("")],
        token(),
        any::<bool>(),
    )
        .prop_map(
            |(scheme, (host, ascii_host), port, path, token, in_fragment)| Printed {
                scheme,
                host,
                ascii_host,
                port,
                path,
                token,
                in_fragment,
            },
        )
}

/// The app's own link to `link`.
fn wrapped(link: &str) -> String {
    format!(
        "hal-c2://pair?pairingUrl={}",
        url::form_urlencoded::byte_serialize(link.as_bytes())
            .collect::<String>()
            .replace('+', "%20")
    )
}

proptest! {
    #[test]
    fn a_printed_link_reads_back_to_its_origin_and_token(link in printed()) {
        let read = read_link(&link.print(true)).expect("a link");
        prop_assert_eq!(&read.token, &link.token);
        prop_assert_eq!(&read.origins, &[link.origin(link.scheme)]);
        // As the user may paste it.
        let pasted = read_link(&format!("  {}\n", link.print(true))).expect("a pasted link");
        prop_assert_eq!(pasted, read);
    }

    #[test]
    fn a_link_typed_without_its_scheme_is_tried_over_https_then_http(link in printed()) {
        let read = read_link(&link.print(false)).expect("a link");
        prop_assert_eq!(&read.token, &link.token);
        prop_assert_eq!(&read.origins, &[link.origin("https"), link.origin("http")]);
    }

    #[test]
    fn an_invitation_is_its_link_read_back_the_same_wrapped_or_not(link in printed()) {
        let plain = link.print(true);
        let invitation = read_invitation(&plain).expect("an invitation");
        prop_assert_eq!(&invitation.link, &plain);
        prop_assert_eq!(&invitation.address, &link.origin(link.scheme));
        // The address is ASCII, whatever the host looks like.
        prop_assert!(invitation.address.is_ascii());
        prop_assert_eq!(read_invitation(&invitation.link), Some(invitation.clone()));
        prop_assert_eq!(read_invitation(&wrapped(&plain)), Some(invitation.clone()));
        // And read_link pairs with the address it showed.
        let read = read_link(&invitation.link).expect("a link");
        prop_assert_eq!(&read.origins, std::slice::from_ref(&invitation.address));
        prop_assert_eq!(&read.token, &link.token);
    }

    #[test]
    fn text_nobody_chose_is_no_invitation_unless_it_is_a_plain_pairing_link(link in printed()) {
        let plain = link.print(true);
        let carried = |link: &str| {
            url::form_urlencoded::byte_serialize(link.as_bytes()).collect::<String>().replace('+', "%20")
        };
        let hostile: Vec<String> = vec![
            // A user name before the host, to make it read as another.
            format!("{}://{}@evil.example/#token={}", link.scheme, link.host, link.token),
            format!("{}://user:pw@{}{}#token=x", link.scheme, link.address(), link.path),
            // Schemes other than http and https.
            format!("ftp://{}/#token=x", link.address()),
            "javascript:alert(1)//#token=x".into(),
            "file:///etc/passwd#token=x".into(),
            // A guessed scheme.
            link.print(false),
            // No token.
            format!("{}://{}/pair", link.scheme, link.address()),
            format!("{}://{}/pair#token=", link.scheme, link.address()),
            // The app's link, bent.
            format!("{}&pairingUrl={}", wrapped(&plain), carried(&plain)),
            wrapped(&wrapped(&plain)),
            format!("hal-c2://unpair?pairingUrl={}", carried(&plain)),
            format!("hal-c2://pair/more?pairingUrl={}", carried(&plain)),
            format!("hal-c2://pair:1?pairingUrl={}", carried(&plain)),
            "hal-c2://pair".into(),
            // Too long for a QR code's link.
            format!("{plain}{}", "a".repeat(2048)),
        ];
        for text in &hostile {
            prop_assert_eq!(read_invitation(text), None::<Invitation>, "{}", text);
        }
    }
}
