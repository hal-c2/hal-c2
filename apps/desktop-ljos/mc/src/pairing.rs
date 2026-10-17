//! Pairing with an MC from a link its operator made (`mix hal_c2.pair`, the
//! Connections page), ported from apps/desktop-qt's `PairingExchange`: what a
//! client that pairs by itself does before it connects. Blocking: run
//! [`exchange`] off the UI thread.

use std::time::Duration;

use serde_json::{Map, Value};
use url::Url;

use crate::PROTOCOL;

const TIMEOUT: Duration = Duration::from_secs(5);
/// A QR code holds under 3000 characters, and a pairing link a fraction of
/// that.
const LONGEST_INVITATION: usize = 2048;

/// Where a link says the MC is, in the order to try (`scheme://host[:port]`),
/// and its single-use token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Link {
    pub origins: Vec<String>,
    pub token: String,
}

/// Reads what the user entered: an http(s) address whose `token` is in the
/// fragment or the query. An address typed without a scheme is tried over
/// HTTPS, then over plain HTTP, which is what an MC on the LAN serves.
/// Nothing when it names no host or no token.
pub fn read_link(entered: &str) -> Option<Link> {
    let text = entered.trim();
    let has_scheme = has_scheme(text);
    let text = if has_scheme {
        text.to_owned()
    } else {
        format!("https://{}", text.trim_start_matches('/'))
    };
    let url = Url::parse(&text).ok()?;
    let scheme = url.scheme().to_owned();
    if !matches!(scheme.as_str(), "http" | "https") || url.host_str().is_none_or(str::is_empty) {
        return None;
    }
    let token = |part: Option<&str>| {
        url::form_urlencoded::parse(part.unwrap_or_default().as_bytes())
            .find(|(name, _)| name == "token")
            .map(|(_, value)| value.trim().to_owned())
            .filter(|t| !t.is_empty())
    };
    let token = token(url.fragment()).or_else(|| token(url.query()))?;
    let schemes = if has_scheme {
        vec![scheme]
    } else {
        vec!["https".to_owned(), "http".to_owned()]
    };
    // A port is written once and means the same for each scheme tried, but a
    // URL drops its own scheme's default (`:443` over https), so what was
    // written is read off whichever scheme keeps it.
    let port = url.port().or_else(|| {
        let other = text.replacen("https://", "http://", 1);
        Url::parse(&other).ok()?.port()
    });
    let origins = schemes
        .into_iter()
        .filter_map(|scheme| {
            let mut origin = url.clone();
            origin.set_scheme(&scheme).ok()?;
            // The port the user wrote stays, even the other scheme's default.
            origin.set_port(port).ok()?;
            Some(origin.origin().ascii_serialization())
        })
        .collect();
    Some(Link { origins, token })
}

fn has_scheme(text: &str) -> bool {
    let Some((scheme, _)) = text.split_once("://") else {
        return false;
    };
    let mut chars = scheme.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-'))
}

/// A pairing link the user did not write: what a camera read off a QR code,
/// or what another app opened this one with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invitation {
    /// The pairing link itself, as the user would have entered it.
    pub link: String,
    /// The MC it would pair with, to say to the user before anything is sent
    /// there: its scheme, host and port, the host in ASCII so that a name
    /// made to look like another shows as what it is (`xn--…`).
    pub address: String,
}

/// Reads such a text: a pairing link written out in full
/// (`http(s)://<address>/pair#token=…`, what an MC's QR code holds), or the
/// app's own link to one, `hal-c2://pair?pairingUrl=<that link,
/// percent-encoded>`. Stricter than [`read_link`], since nobody chose this
/// text: the scheme is never guessed and only http and https pass, the
/// address carries no user name, and the app's link holds exactly one
/// `pairingUrl`, decoded once, which is not itself an app link.
pub fn read_invitation(received: &str) -> Option<Invitation> {
    let mut text = received.trim().to_owned();
    if text.is_empty() || text.chars().count() > LONGEST_INVITATION {
        return None;
    }
    let mut url = Url::parse(&text).ok()?;
    if url.scheme() == "hal-c2" {
        let path = url.path();
        if !url
            .host_str()
            .is_some_and(|h| h.eq_ignore_ascii_case("pair"))
            || !url.username().is_empty()
            || url.password().is_some()
            || url.port().is_some()
            || !(path.is_empty() || path == "/")
        {
            return None;
        }
        // Two of them is one for the user to read and one to be used.
        let carried: Vec<String> = url
            .query_pairs()
            .filter(|(name, _)| name == "pairingUrl")
            .map(|(_, value)| value.into_owned())
            .collect();
        let [carried] = carried.as_slice() else {
            return None;
        };
        text = carried.trim().to_owned();
        url = Url::parse(&text).ok()?;
    }
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none_or(str::is_empty)
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    // With its scheme written, the link has the one origin read_link gives it.
    let address = read_link(&text)?.origins.into_iter().next()?;
    Some(Invitation {
        link: text,
        address,
    })
}

/// What the client says about itself in the exchange; the MC lists it among
/// its clients (apps/server-ex auth.ex).
#[derive(Clone, Debug, Default)]
pub struct Client {
    pub label: String,
    /// desktop | mobile | tablet
    pub device_type: String,
    /// Left out when empty.
    pub os: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Paired,
    /// Nothing answered at any of the link's origins.
    Unreachable,
    /// Something answered that does not describe itself as an MC.
    NotMc,
    /// An MC of another protocol than [`PROTOCOL`].
    Incompatible,
    /// The MC turned the token down: spent, expired, or not its own.
    Refused,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Pairing {
    pub outcome: Outcome,
    /// The origin that answered; the first one tried when none did.
    pub origin: String,
    /// The new session's access token, when paired.
    pub token: String,
    /// The MC's descriptor (environmentId, label,
    /// orchestrationProtocolVersion), once an MC answered.
    pub descriptor: Map<String, Value>,
}

/// Finds the MC among the link's origins by its descriptor
/// (`/.well-known/hal-c2/environment`) and spends the token on a session
/// there (`/oauth/token`). The token is only sent to an MC this client can
/// speak to, so every other outcome leaves it unspent. Only an origin that
/// does not answer at all passes the question on to the next: an answer of
/// any kind stands.
pub fn exchange(link: &Link, client: &Client) -> Pairing {
    let agent = crate::http::agent(Some(TIMEOUT));
    let first = link.origins.first().cloned().unwrap_or_default();
    let result = |outcome, origin: &str, descriptor| Pairing {
        outcome,
        origin: origin.to_owned(),
        token: String::new(),
        descriptor,
    };
    for origin in &link.origins {
        let Some((status, body)) = answer(
            agent
                .get(format!("{origin}/.well-known/hal-c2/environment"))
                .call(),
        ) else {
            continue;
        };
        let descriptor: Map<String, Value> = serde_json::from_slice(&body).unwrap_or_default();
        let named = descriptor
            .get("environmentId")
            .and_then(Value::as_str)
            .is_some_and(|id| !id.is_empty());
        let protocol = descriptor
            .get("orchestrationProtocolVersion")
            .and_then(Value::as_f64);
        let Some(protocol) = protocol.filter(|_| (200..300).contains(&status) && named) else {
            return result(Outcome::NotMc, origin, Map::new());
        };
        if protocol != PROTOCOL as f64 {
            return result(Outcome::Incompatible, origin, descriptor);
        }
        return spend(&agent, origin, link, client, descriptor);
    }
    result(Outcome::Unreachable, &first, Map::new())
}

fn spend(
    agent: &ureq::Agent,
    origin: &str,
    link: &Link,
    client: &Client,
    descriptor: Map<String, Value>,
) -> Pairing {
    let mut form = url::form_urlencoded::Serializer::new(String::new());
    form.append_pair(
        "grant_type",
        "urn:ietf:params:oauth:grant-type:token-exchange",
    )
    .append_pair(
        "subject_token_type",
        "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
    )
    .append_pair("subject_token", &link.token)
    .append_pair("client_label", &client.label)
    .append_pair("client_device_type", &client.device_type);
    if !client.os.is_empty() {
        form.append_pair("client_os", &client.os);
    }
    let sent = agent
        .post(format!("{origin}/oauth/token"))
        .content_type("application/x-www-form-urlencoded")
        .send(form.finish());
    let mut pairing = Pairing {
        outcome: Outcome::Refused,
        origin: origin.to_owned(),
        token: String::new(),
        descriptor,
    };
    match answer(sent) {
        None => pairing.outcome = Outcome::Unreachable,
        Some((status, body)) => {
            let token = serde_json::from_slice::<Value>(&body)
                .ok()
                .and_then(|v| v.get("access_token")?.as_str().map(str::to_owned))
                .unwrap_or_default();
            if (200..300).contains(&status) && !token.is_empty() {
                pairing.outcome = Outcome::Paired;
                pairing.token = token;
            }
        }
    }
    pairing
}

/// The status and body, when the origin answered at all.
fn answer(
    response: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
) -> Option<(u16, Vec<u8>)> {
    let mut response = response.ok()?;
    let status = response.status().as_u16();
    let body = response.body_mut().read_to_vec().unwrap_or_default();
    Some((status, body))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_names_its_origin_and_token() {
        let link = read_link("http://192.168.1.4:3773/pair#token=abc%20").unwrap();
        assert_eq!(link.origins, ["http://192.168.1.4:3773"]);
        assert_eq!(link.token, "abc");
        let link = read_link("  https://mc.example/pair?token=q ").unwrap();
        assert_eq!(link.origins, ["https://mc.example"]);
        assert_eq!(link.token, "q");
    }

    #[test]
    fn a_link_without_a_scheme_tries_https_then_http() {
        let link = read_link("//laptop.local:3773/pair#token=t").unwrap();
        assert_eq!(
            link.origins,
            ["https://laptop.local:3773", "http://laptop.local:3773"]
        );
    }

    #[test]
    fn a_link_needs_a_host_a_token_and_http() {
        assert_eq!(read_link("http://mc.example/pair"), None);
        assert_eq!(read_link("ftp://mc.example/pair#token=t"), None);
        assert_eq!(read_link("#token=t"), None);
        assert_eq!(read_link("http://mc.example/pair#token=%20"), None);
    }

    #[test]
    fn an_invitation_is_a_full_link_or_the_apps_link_to_one() {
        let full = "http://10.0.0.2:3773/pair#token=t";
        assert_eq!(
            read_invitation(full),
            Some(Invitation {
                link: full.into(),
                address: "http://10.0.0.2:3773".into()
            })
        );
        let app = "hal-c2://pair?pairingUrl=http%3A%2F%2F10.0.0.2%3A3773%2Fpair%23token%3Dt";
        assert_eq!(read_invitation(app).unwrap().link, full);
        let unicode = read_invitation("https://bücher.example/pair#token=t").unwrap();
        assert_eq!(unicode.address, "https://xn--bcher-kva.example");
    }

    #[test]
    fn a_port_typed_without_a_scheme_stays_on_both_origins() {
        let link = read_link("10.0.0.2:443/pair#token=t").unwrap();
        assert_eq!(link.origins, ["https://10.0.0.2", "http://10.0.0.2:443"]);
        let link = read_link("10.0.0.2:80/pair#token=t").unwrap();
        assert_eq!(link.origins, ["https://10.0.0.2:80", "http://10.0.0.2"]);
    }

    #[test]
    fn an_invitation_guesses_nothing() {
        for text in [
            "10.0.0.2:3773/pair#token=t",
            "http://user@10.0.0.2/pair#token=t",
            "hal-c2://pair?pairingUrl=a&pairingUrl=b",
            "hal-c2://pair/x?pairingUrl=http%3A%2F%2Fh%2F%23token%3Dt",
            "hal-c2://pair?pairingUrl=hal-c2%3A%2F%2Fpair",
            "hal-c2://other?pairingUrl=http%3A%2F%2Fh%2F%23token%3Dt",
        ] {
            assert_eq!(read_invitation(text), None, "{text}");
        }
        let long = format!("http://h/pair#token={}", "t".repeat(LONGEST_INVITATION));
        assert_eq!(read_invitation(&long), None);
    }
}
