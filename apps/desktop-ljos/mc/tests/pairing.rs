//! Pairing against an MC in the test's process: the token is spent once, and
//! only on an MC this client speaks to.

// Shared with connection.rs, which drives the socket half.
#[allow(dead_code)]
mod fake_mc;

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::mpsc::{Receiver, channel};

use fake_mc::{Event, FakeMc, PAIRING_TOKEN, Seen, TOKEN};
use hal_c2_mc::pairing::{Client, Link, Outcome, exchange};

fn start() -> (FakeMc, Receiver<Event>, String) {
    let (events, seen) = channel();
    let mc = FakeMc::start(events);
    let origin = mc.origin.origin().ascii_serialization();
    (mc, seen, origin)
}

fn link(origins: &[&str]) -> Link {
    Link {
        origins: origins.iter().map(|o| o.to_string()).collect(),
        token: PAIRING_TOKEN.into(),
    }
}

fn client() -> Client {
    Client {
        label: "Desk top".into(),
        device_type: "desktop".into(),
        os: "linux".into(),
    }
}

/// The exchanges the MC saw so far: it tells before it answers, so every one
/// a finished exchange made is in.
fn exchanges(seen: &Receiver<Event>) -> Vec<String> {
    seen.try_iter()
        .filter_map(|event| match event {
            Event::Mc(Seen::Exchange { form }) => Some(form),
            _ => None,
        })
        .collect()
}

/// An origin nothing listens at.
fn closed_origin() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    format!("http://127.0.0.1:{port}")
}

#[test]
fn a_link_pairs_once_and_says_who_the_client_is() {
    let (_mc, seen, origin) = start();
    let paired = exchange(&link(&[&origin]), &client());
    assert_eq!(paired.outcome, Outcome::Paired);
    assert_eq!(paired.token, TOKEN);
    assert_eq!(paired.origin, origin);
    assert_eq!(paired.descriptor["environmentId"], "env-1");
    let forms = exchanges(&seen);
    assert_eq!(forms.len(), 1);
    for field in [
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange",
        "subject_token=pair-once",
        "client_label=Desk+top",
        "client_device_type=desktop",
        "client_os=linux",
    ] {
        assert!(
            forms[0].split('&').any(|f| f == field),
            "{field} in {}",
            forms[0]
        );
    }

    // Spent: the MC turns it down, and no token comes back.
    let again = exchange(&link(&[&origin]), &client());
    assert_eq!(again.outcome, Outcome::Refused);
    assert!(again.token.is_empty());
}

#[test]
fn an_mc_of_another_protocol_is_never_sent_the_token() {
    let (mc, seen, origin) = start();
    mc.set_protocol(4);
    let result = exchange(&link(&[&origin]), &client());
    assert_eq!(result.outcome, Outcome::Incompatible);
    assert_eq!(result.descriptor["orchestrationProtocolVersion"], 4);
    assert!(exchanges(&seen).is_empty());
}

#[test]
fn an_origin_that_does_not_answer_passes_to_the_next() {
    let (_mc, _seen, origin) = start();
    let closed = closed_origin();
    let result = exchange(&link(&[&closed, &origin]), &client());
    assert_eq!(result.outcome, Outcome::Paired);
    assert_eq!(result.origin, origin);

    let none = exchange(&link(&[&closed]), &client());
    assert_eq!(none.outcome, Outcome::Unreachable);
    assert_eq!(none.origin, closed);
}

#[test]
fn something_else_answering_is_not_an_mc_and_stands() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let other = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0u8; 4096];
        let _ = stream.read(&mut request);
        let body = "<html>a router</html>";
        let _ = write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
    });
    let (_mc, seen, origin) = start();
    let result = exchange(&link(&[&other, &origin]), &client());
    assert_eq!(result.outcome, Outcome::NotMc);
    assert_eq!(result.origin, other);
    assert!(exchanges(&seen).is_empty());
}
