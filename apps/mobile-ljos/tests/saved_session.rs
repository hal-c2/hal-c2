//! A saved primary session at an address that answers as another
//! environment now, over the real client and a loopback socket.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use hal_c2_mc::{PROTOCOL, Phase};
use hal_c2_mobile::pairing::{self, Environment};
use hal_c2_shell::Launch;
use hal_c2_shell::mc::{Connection, Mc};
use hal_c2_shell::streams::Pump;
use ljos::App;

/// How long the block may take before it counts as never coming.
const PATIENCE: Duration = Duration::from_secs(10);

/// An MC that describes itself as env-2, whatever it is asked: its origin,
/// and the path of each request it got.
fn another_environment() -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port");
    let origin = format!("http://{}", listener.local_addr().expect("its address"));
    let (asked, requests) = mpsc::channel();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut lines = BufReader::new(&stream).lines();
            let Some(Ok(first)) = lines.next() else {
                continue;
            };
            // The rest of the head, so closing does not reset the answer.
            for line in lines.by_ref() {
                if line.map_or(true, |line| line.is_empty()) {
                    break;
                }
            }
            let _ = asked.send(first.split(' ').nth(1).unwrap_or_default().to_owned());
            let body =
                format!(r#"{{"environmentId":"env-2","orchestrationProtocolVersion":{PROTOCOL}}}"#);
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        }
    });
    (origin, requests)
}

#[test]
fn a_saved_session_is_blocked_where_another_environment_answers() {
    let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).expect("a home for the phone");
    let (origin, requests) = another_environment();
    let path = home.path().join("data/pairing.json");
    let saved = Environment {
        origin,
        token: "session".into(),
        label: "My MacBook".into(),
        environment_id: "env-1".into(),
        expires_at: String::new(),
    };
    assert!(pairing::save(&path, &saved));

    let engine = App::new("saved-session")
        .register(hal_c2_mobile::register)
        .source(hal_c2_mobile::pack())
        .root("Main")
        .build_engine();
    let (woken, wakes) = mpsc::channel();
    let mut streams = Pump::new(move || {
        let _ = woken.send(());
    });
    let wired = hal_c2_shell::streams::wire(&engine, &mut streams);
    let connection = Connection::spawn(&wired.mc);
    let launch = Launch {
        config_dir: Some(home.path().join("config")),
        cache_dir: Some(home.path().join("cache")),
        data_dir: Some(home.path().join("data")),
        state_dir: Some(home.path().join("state")),
        ..Launch::default()
    };
    hal_c2_mobile::install(&engine, launch.data_dir.clone(), launch.config_dir.clone());
    hal_c2_shell::start_with(
        &engine,
        &launch,
        connection.clone() as Rc<dyn Mc>,
        hal_c2_mobile::registrations(),
    );
    hal_c2_mobile::start(&engine);

    let deadline = Instant::now() + PATIENCE;
    loop {
        streams.pump(&engine);
        let status = connection.status();
        if status.phase == Phase::Blocked {
            assert_eq!(
                status.failure, "mismatch",
                "blocked, but not for the environment"
            );
            break;
        }
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(
            !left.is_zero(),
            "env-2 was not blocked: the connection is {:?}",
            status.phase
        );
        let _ = wakes.recv_timeout(left);
    }

    let asked: Vec<String> = requests.try_iter().collect();
    assert_eq!(
        asked,
        ["/.well-known/hal-c2/environment"],
        "only the descriptor was asked: no ticket, no socket"
    );
    assert_eq!(
        pairing::load(&path),
        Some(saved),
        "env-1 is still the pairing"
    );
}
