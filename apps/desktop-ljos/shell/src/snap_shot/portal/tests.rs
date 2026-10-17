//! The portal protocol against what the portal says, never against a
//! desktop: the machine is driven by inputs, and the message shapes are
//! built, not sent.

use std::cell::RefCell;
use std::collections::HashMap;

use zbus::Message;
use zbus::zvariant::{OwnedValue, Value};

use super::wire::{self, Put};
use super::*;

fn platform(sandboxed: bool) -> Platform {
    Platform {
        portal: true,
        desktop: "gnome".into(),
        sandboxed,
        ..Platform::default()
    }
}

/// A machine and everything it has asked and said.
struct Run {
    machine: Machine,
    calls: Vec<Call>,
    events: Vec<Event>,
}

impl Run {
    fn new() -> Run {
        Run::on(platform(false))
    }

    fn on(platform: Platform) -> Run {
        Run {
            machine: Machine::new(&platform, "hal-c2"),
            calls: Vec::new(),
            events: Vec::new(),
        }
    }

    fn take(&mut self, outs: Vec<Out>) {
        for out in outs {
            match out {
                Out::Call(call) => self.calls.push(call),
                Out::Event(event) => self.events.push(event),
            }
        }
    }

    fn input(&mut self, input: Input) {
        let outs = self.machine.input(input);
        self.take(outs);
    }

    /// The calls made since the last time, oldest first.
    fn calls(&mut self) -> Vec<Call> {
        std::mem::take(&mut self.calls)
    }

    fn events(&mut self) -> Vec<String> {
        std::mem::take(&mut self.events)
            .into_iter()
            .map(|event| match event {
                Event::Changed => "changed".into(),
                Event::Activated => "activated".into(),
                Event::Captured(c) => format!("captured {}x{}", c.image.width(), c.image.height()),
                Event::Failed(message) => format!("failed {message}"),
                Event::After { ms, .. } => format!("after {ms}"),
                Event::Cancel(_) => "cancel".into(),
            })
            .collect()
    }

    /// The timer of the last `After`, from events not yet taken.
    fn timer(&self) -> u64 {
        self.events
            .iter()
            .rev()
            .find_map(|event| match event {
                Event::After { token, .. } => Some(*token),
                _ => None,
            })
            .expect("a timer was asked for")
    }
}

fn response(handle: &str, status: u32, results: Results) -> Input {
    Input::Response {
        handle: handle.into(),
        status,
        results,
    }
}

fn request(token: &str) -> String {
    format!("/org/freedesktop/portal/desktop/request/1_42/{token}")
}

fn token_of(call: &Call) -> String {
    match call {
        Call::Screenshot { token, .. }
        | Call::CreateSession { token, .. }
        | Call::BindShortcuts { token, .. } => token.clone(),
        other => panic!("not a request: {other:?}"),
    }
}

fn bound(id: &str, trigger: &str) -> Bound {
    Bound {
        id: id.into(),
        trigger: trigger.into(),
    }
}

// -- Probing ---------------------------------------------------------------

#[test]
fn probing_names_the_app_once_and_reads_what_the_screenshot_portal_offers() {
    let mut run = Run::new();
    assert!(!run.machine.session().ready);
    let outs = run.machine.probe();
    run.take(outs);
    assert_eq!(
        run.calls(),
        [
            Call::Register {
                app_id: "hal-c2".into()
            },
            Call::Properties
        ]
    );
    // Asking again while asked changes nothing.
    assert!(run.machine.probe().is_empty());

    run.input(Input::Properties(Some((3, 1 | 2 | 8))));
    let session = run.machine.session();
    assert!(session.ready);
    assert_eq!(session.mode, Mode::Portal);
    assert_eq!(session.backend, "screenshot-portal");
    assert_eq!(session.desktop, "gnome");
    assert_eq!(run.events(), ["changed"]);
    // And once known, not again.
    assert!(run.machine.probe().is_empty());
}

#[test]
fn a_portal_without_the_window_target_has_the_user_pick() {
    for found in [Some((2, 8)), Some((3, 1 | 2)), None] {
        let mut run = Run::new();
        let outs = run.machine.probe();
        run.take(outs);
        run.input(Input::Properties(found));
        assert_eq!(run.machine.session().backend, "picker", "{found:?}");
        assert!(run.machine.session().ready);
    }
}

#[test]
fn a_sandboxed_app_is_not_registered_with_the_portal() {
    let mut run = Run::on(platform(true));
    let outs = run.machine.probe();
    run.take(outs);
    assert_eq!(run.calls(), [Call::Properties]);
}

// -- Capturing -------------------------------------------------------------

fn probed(window: bool) -> Run {
    let mut run = Run::new();
    let outs = run.machine.probe();
    run.take(outs);
    run.input(Input::Properties(Some(if window {
        (3, 8)
    } else {
        (2, 0)
    })));
    run.calls();
    run.events();
    run
}

#[test]
fn a_capture_asks_for_the_window_in_front_where_the_portal_has_it() {
    let mut run = probed(true);
    let outs = run.machine.capture();
    run.take(outs);
    let calls = run.calls();
    assert!(matches!(
        calls.as_slice(),
        [Call::Screenshot { window: true, .. }]
    ));
    assert_eq!(run.events(), ["after 120000"]);

    let token = token_of(&calls[0]);
    run.input(response(
        &request(&token),
        0,
        Results {
            uri: Some("file:///tmp/shot.png".into()),
            ..Results::default()
        },
    ));
    assert_eq!(
        run.calls(),
        [Call::Load {
            uri: "file:///tmp/shot.png".into()
        }]
    );
    assert_eq!(run.events(), ["cancel"]);
}

#[test]
fn a_capture_lets_the_user_pick_where_the_portal_cannot_choose() {
    let mut run = probed(false);
    let outs = run.machine.capture();
    run.take(outs);
    assert!(matches!(
        run.calls()[0],
        Call::Screenshot { window: false, .. }
    ));
}

#[test]
fn one_capture_runs_at_a_time_and_the_next_waits_for_its_end() {
    let mut run = probed(true);
    let outs = run.machine.capture();
    run.take(outs);
    let token = token_of(&run.calls()[0]);
    assert!(run.machine.capture().is_empty());

    run.input(response(&request(&token), 1, Results::default()));
    assert_eq!(
        run.events(),
        ["after 120000", "cancel", "failed Snapshot was cancelled."]
    );
    let outs = run.machine.capture();
    assert!(!outs.is_empty());
}

#[test]
fn a_refused_capture_says_so() {
    let mut run = probed(true);
    let outs = run.machine.capture();
    run.take(outs);
    let token = token_of(&run.calls()[0]);
    run.events();
    run.input(response(&request(&token), 2, Results::default()));
    assert_eq!(
        run.events(),
        ["cancel", "failed Your desktop did not allow the snapshot."]
    );
}

#[test]
fn a_call_the_portal_refuses_ends_the_capture() {
    let mut run = probed(true);
    let outs = run.machine.capture();
    run.take(outs);
    let token = token_of(&run.calls()[0]);
    run.events();
    run.input(Input::Replied {
        token,
        handle: Err("boom".into()),
    });
    assert_eq!(
        run.events(),
        ["cancel", "failed Your desktop did not allow the snapshot."]
    );
    assert!(!run.machine.capture().is_empty());
}

#[test]
fn a_capture_nobody_answers_is_closed_and_failed() {
    let mut run = probed(true);
    let outs = run.machine.capture();
    run.take(outs);
    let token = token_of(&run.calls()[0]);
    let timer = run.timer();
    run.events();
    let outs = run.machine.timeout(timer);
    run.take(outs);
    assert_eq!(
        run.calls(),
        [Call::CloseRequest {
            token: token.clone(),
            handle: None
        }]
    );
    assert_eq!(
        run.events(),
        ["cancel", "failed Your desktop did not allow the snapshot."]
    );
    // The answer that comes too late is nobody's.
    run.input(response(&request(&token), 0, Results::default()));
    assert!(run.calls().is_empty());
    assert!(run.events().is_empty());
    // A timer already cancelled does nothing.
    assert!(run.machine.timeout(timer).is_empty());
}

#[test]
fn an_answer_before_the_reply_is_matched_by_its_token_and_after_it_by_its_handle() {
    let mut run = probed(true);
    let outs = run.machine.capture();
    run.take(outs);
    let token = token_of(&run.calls()[0]);
    // A portal that names the request something else.
    run.input(Input::Replied {
        token: token.clone(),
        handle: Ok("/org/freedesktop/portal/desktop/request/1_42/other".into()),
    });
    run.events();
    run.input(response(&request(&token), 1, Results::default()));
    assert!(
        run.events().is_empty(),
        "the token alone no longer names it"
    );
    run.input(response(
        "/org/freedesktop/portal/desktop/request/1_42/other",
        1,
        Results::default(),
    ));
    assert_eq!(run.events(), ["cancel", "failed Snapshot was cancelled."]);
}

#[test]
fn a_loaded_screenshot_is_captured_and_a_bad_one_fails() {
    let mut run = probed(true);
    run.input(Input::Loaded(Ok(Captured {
        image: RgbaImage::new(4, 3),
        app_name: "Window".into(),
        window_title: String::new(),
    })));
    run.input(Input::Loaded(Err("Invalid screenshot file.".into())));
    assert_eq!(
        run.events(),
        ["captured 4x3", "failed Invalid screenshot file."]
    );
}

// -- The capture shortcut ----------------------------------------------------

/// A machine with a bound shortcut: the trigger, the session and the id.
fn bound_run(version: u32) -> (Run, String) {
    let mut run = probed(true);
    let outs = run.machine.bind("CTRL+SHIFT+2");
    run.take(outs);
    let calls = run.calls();
    let generation = match calls.last() {
        Some(Call::Version { generation }) => *generation,
        other => panic!("{other:?}"),
    };
    run.input(Input::Version {
        generation,
        version: Some(version),
    });
    let create = run.calls().pop().unwrap();
    let token = token_of(&create);
    run.input(response(
        &request(&token),
        0,
        Results {
            session_handle: Some("/session/one".into()),
            ..Results::default()
        },
    ));
    let bind = run.calls().pop().unwrap();
    let id = match &bind {
        Call::BindShortcuts { id, .. } => id.clone(),
        other => panic!("{other:?}"),
    };
    run.input(response(
        &request(&token_of(&bind)),
        0,
        Results {
            shortcuts: vec![bound(&id, " Ctrl+Shift+2 ")],
            ..Results::default()
        },
    ));
    run.events();
    (run, id)
}

#[test]
fn binding_walks_the_portal_to_a_registered_shortcut() {
    let mut run = probed(true);
    let outs = run.machine.bind("CTRL+SHIFT+2");
    run.take(outs);
    let shortcut = run.machine.shortcut();
    assert!(shortcut.pending && !shortcut.registered);
    assert_eq!(
        shortcut.message,
        "Waiting for shortcut permission. Approve the desktop prompt if one appears."
    );
    assert!(shortcut.can_retry);
    // Already registered by the probe, so only the version is asked.
    assert_eq!(run.calls(), [Call::Version { generation: 1 }]);

    run.input(Input::Version {
        generation: run.machine.generation,
        version: Some(2),
    });
    let create = run.calls().pop().unwrap();
    assert!(matches!(&create, Call::CreateSession { .. }));
    assert!(run.events().contains(&"after 5000".to_string()));

    run.input(response(
        &request(&token_of(&create)),
        0,
        Results {
            session_handle: Some("/session/one".into()),
            ..Results::default()
        },
    ));
    let bind = run.calls().pop().unwrap();
    let Call::BindShortcuts {
        session,
        id,
        trigger,
        ..
    } = &bind
    else {
        panic!("{bind:?}")
    };
    assert_eq!(session, "/session/one");
    assert_eq!(trigger, "CTRL+SHIFT+2");
    assert!(id.starts_with("hal-c2-snap-shot-") && id.len() == 17 + 16);
    assert!(run.events().contains(&"after 120000".to_string()));

    run.input(response(
        &request(&token_of(&bind)),
        0,
        Results {
            shortcuts: vec![bound("other", "F1"), bound(id, "  Ctrl+Shift+2 ")],
            ..Results::default()
        },
    ));
    let shortcut = run.machine.shortcut();
    assert!(shortcut.registered && !shortcut.pending);
    assert_eq!(shortcut.label, "Ctrl+Shift+2");
    assert_eq!(shortcut.message, "Desktop shortcut: Ctrl+Shift+2");
}

#[test]
fn the_shortcut_id_is_the_triggers_and_stays() {
    let (a, _) = bound_run(2);
    let again = {
        let mut run = probed(true);
        let outs = run.machine.bind("CTRL+SHIFT+2");
        run.take(outs);
        run.machine.shortcut_id.clone()
    };
    assert_eq!(a.machine.shortcut_id, again);
    let other = {
        let mut run = probed(true);
        let outs = run.machine.bind("CTRL+SHIFT+3");
        run.take(outs);
        run.machine.shortcut_id.clone()
    };
    assert_ne!(again, other);
}

#[test]
fn the_shortcut_is_heard_only_from_its_session_and_id() {
    let (mut run, id) = bound_run(2);
    let activated = |session: &str, id: &str| Input::Activated {
        session: session.into(),
        id: id.into(),
    };
    run.input(activated("/session/one", &id));
    assert_eq!(run.events(), ["activated"]);
    run.input(activated("/session/two", &id));
    run.input(activated("/session/one", "other"));
    assert!(run.events().is_empty());
}

#[test]
fn a_shortcut_the_desktop_gave_no_keys_is_not_registered() {
    let (mut run, id) = bound_run(2);
    run.input(Input::ShortcutsChanged {
        session: "/session/one".into(),
        shortcuts: vec![bound(&id, "")],
    });
    let shortcut = run.machine.shortcut();
    assert!(!shortcut.registered);
    assert_eq!(
        shortcut.message,
        "No shortcut is assigned. Open shortcut permissions to choose one."
    );
    run.events();
    run.input(Input::Activated {
        session: "/session/one".into(),
        id,
    });
    assert!(run.events().is_empty());

    // Where the desktop has no permissions to open, it is told where to go.
    let (mut run, id) = bound_run(1);
    run.input(Input::ShortcutsChanged {
        session: "/session/one".into(),
        shortcuts: vec![bound(&id, "")],
    });
    let shortcut = run.machine.shortcut();
    assert!(!shortcut.can_retry);
    assert_eq!(
        shortcut.message,
        "No shortcut is assigned. Choose one in your desktop's shortcut settings."
    );
    // A change for another session is not ours.
    run.input(Input::ShortcutsChanged {
        session: "/session/two".into(),
        shortcuts: vec![bound(&id, "F1")],
    });
    assert!(!run.machine.shortcut().registered);
}

#[test]
fn a_desktop_without_app_shortcuts_says_where_to_choose_one() {
    let mut run = probed(true);
    let outs = run.machine.bind("F5");
    run.take(outs);
    run.input(Input::Version {
        generation: run.machine.generation,
        version: None,
    });
    let shortcut = run.machine.shortcut();
    assert!(!shortcut.pending && !shortcut.registered && shortcut.can_retry);
    assert_eq!(
        shortcut.message,
        "This desktop doesn't offer app shortcuts. Choose a shortcut in your desktop's settings instead."
    );
}

#[test]
fn a_session_that_fails_says_why() {
    let mut run = probed(true);
    let outs = run.machine.bind("F5");
    run.take(outs);
    run.input(Input::Version {
        generation: run.machine.generation,
        version: Some(1),
    });
    let create = run.calls().pop().unwrap();
    run.input(response(
        &request(&token_of(&create)),
        2,
        Results::default(),
    ));
    assert_eq!(
        run.machine.shortcut().message,
        "Your desktop could not create a capture shortcut session."
    );

    // Asked again, and nobody answers.
    let outs = run.machine.bind("F5");
    run.take(outs);
    let generation = match run.calls().pop() {
        Some(Call::Version { generation }) => generation,
        other => panic!("{other:?}"),
    };
    run.input(Input::Version {
        generation,
        version: Some(1),
    });
    let create = run.calls().pop().unwrap();
    assert!(matches!(create, Call::CreateSession { .. }));
    let timer = run.timer();
    let outs = run.machine.timeout(timer);
    run.take(outs);
    assert!(matches!(
        run.calls().as_slice(),
        [Call::CloseRequest { .. }]
    ));
    assert_eq!(
        run.machine.shortcut().message,
        "Shortcut permission request timed out. Try again."
    );
}

#[test]
fn a_refused_binding_says_whether_permissions_can_be_reopened() {
    for (version, message, can_retry) in [
        (
            2,
            "Shortcut permission wasn't granted. Open shortcut permissions to allow it.",
            true,
        ),
        (
            1,
            "Shortcut permission wasn't granted. Allow HAL-C2 in your desktop's shortcut settings.",
            false,
        ),
    ] {
        let mut run = probed(true);
        let outs = run.machine.bind("F5");
        run.take(outs);
        run.input(Input::Version {
            generation: run.machine.generation,
            version: Some(version),
        });
        let create = run.calls().pop().unwrap();
        run.input(response(
            &request(&token_of(&create)),
            0,
            Results {
                session_handle: Some("/session/one".into()),
                ..Results::default()
            },
        ));
        let bind = run.calls().pop().unwrap();
        run.input(response(&request(&token_of(&bind)), 1, Results::default()));
        let shortcut = run.machine.shortcut();
        assert_eq!(shortcut.message, message);
        assert_eq!(shortcut.can_retry, can_retry);
        assert!(!shortcut.registered && !shortcut.pending);
    }
}

#[test]
fn a_new_trigger_drops_the_session_and_a_late_answer_for_it_is_closed() {
    let mut run = probed(true);
    let outs = run.machine.bind("F5");
    run.take(outs);
    run.input(Input::Version {
        generation: run.machine.generation,
        version: Some(2),
    });
    let old = run.calls().pop().unwrap();

    // Rebound before the first session answered.
    let outs = run.machine.bind("F6");
    run.take(outs);
    run.calls();
    run.input(response(
        &request(&token_of(&old)),
        0,
        Results {
            session_handle: Some("/session/stale".into()),
            ..Results::default()
        },
    ));
    assert_eq!(
        run.calls(),
        [Call::CloseSession {
            handle: "/session/stale".into()
        }]
    );
    assert!(run.machine.session_handle.is_empty());
    // A version answer for the first ask is the first's.
    run.input(Input::Version {
        generation: 1,
        version: Some(2),
    });
    assert!(run.calls().is_empty());
}

#[test]
fn the_same_trigger_keeps_its_session_and_a_changed_one_closes_it() {
    let (mut run, _) = bound_run(2);
    assert!(run.machine.bind("CTRL+SHIFT+2").is_empty());
    let outs = run.machine.bind("CTRL+SHIFT+3");
    run.take(outs);
    let calls = run.calls();
    assert_eq!(
        calls[0],
        Call::CloseSession {
            handle: "/session/one".into()
        }
    );
    assert!(matches!(calls.last(), Some(Call::Version { .. })));
}

#[test]
fn releasing_closes_the_session_and_forgets_the_shortcut() {
    let (mut run, _) = bound_run(2);
    let outs = run.machine.release();
    run.take(outs);
    assert_eq!(
        run.calls(),
        [Call::CloseSession {
            handle: "/session/one".into()
        }]
    );
    assert_eq!(run.machine.shortcut(), Shortcut::default());
    assert_eq!(run.events(), ["changed"]);
}

#[test]
fn the_desktop_ending_the_session_or_restarting_is_a_failed_shortcut() {
    let (mut run, _) = bound_run(2);
    run.input(Input::SessionClosed {
        handle: "/session/other".into(),
    });
    assert!(run.machine.shortcut().registered);
    run.input(Input::SessionClosed {
        handle: "/session/one".into(),
    });
    let shortcut = run.machine.shortcut();
    assert!(!shortcut.registered);
    assert_eq!(
        shortcut.message,
        "Your desktop closed the capture shortcut. Retry the shortcut request."
    );

    let (mut run, _) = bound_run(2);
    // A name coming up is not a restart.
    run.input(Input::OwnerChanged { was_owned: false });
    assert!(run.machine.shortcut().registered);
    run.input(Input::OwnerChanged { was_owned: true });
    assert_eq!(
        run.machine.shortcut().message,
        "The desktop shortcut service restarted. Retry the shortcut request."
    );
    // With nothing bound or pending, nothing is lost.
    let mut idle = probed(true);
    idle.input(Input::OwnerChanged { was_owned: true });
    assert_eq!(idle.machine.shortcut(), Shortcut::default());
}

#[test]
fn configuring_reopens_permissions_or_binds_again() {
    let (mut run, _) = bound_run(2);
    let outs = run.machine.configure();
    run.take(outs);
    assert_eq!(
        run.calls(),
        [Call::Configure {
            session: "/session/one".into()
        }]
    );

    // A desktop before version 2 can only be pointed at its settings.
    let (mut run, _) = bound_run(1);
    let outs = run.machine.configure();
    run.take(outs);
    assert!(run.calls().is_empty());
    assert_eq!(
        run.machine.shortcut().message,
        "Open your desktop's shortcut settings and allow HAL-C2's capture shortcut."
    );

    // After the session was lost, it is asked for again.
    let (mut run, _) = bound_run(2);
    run.input(Input::SessionClosed {
        handle: "/session/one".into(),
    });
    run.calls();
    let outs = run.machine.configure();
    run.take(outs);
    assert!(matches!(run.calls().last(), Some(Call::Version { .. })));
    assert!(run.machine.shortcut().pending);

    // With nothing to retry, nothing happens.
    assert!(probed(true).machine.configure().is_empty());
}

// -- The shortcut id ---------------------------------------------------------

#[test]
fn the_shortcut_id_is_desktop_qts() {
    assert_eq!(
        shortcut_id("CTRL+SHIFT+2"),
        "hal-c2-snap-shot-33b6c70257289646"
    );
}

// -- The screenshot file -----------------------------------------------------

fn png(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    RgbaImage::new(width, height)
        .write_to(&mut bytes, ImageFormat::Png)
        .unwrap();
    bytes.into_inner()
}

use std::io::Cursor;

fn uri(path: &std::path::Path) -> String {
    url::Url::from_file_path(path).unwrap().to_string()
}

#[test]
fn a_screenshot_is_read_and_fitted_without_being_removed() {
    let dir = tempfile::tempdir().unwrap();
    let small = dir.path().join("small.png");
    std::fs::write(&small, png(40, 30)).unwrap();
    let captured = load(&uri(&small)).unwrap();
    assert_eq!(captured.image.dimensions(), (40, 30));
    assert_eq!(captured.app_name, "Window");
    assert!(captured.window_title.is_empty());
    assert!(small.exists());

    let wide = dir.path().join("wide.png");
    std::fs::write(&wide, png(5120, 1000)).unwrap();
    let captured = load(&uri(&wide)).unwrap();
    assert_eq!(captured.image.dimensions(), (2560, 500));

    let tall = dir.path().join("tall.png");
    std::fs::write(&tall, png(1000, 3200)).unwrap();
    assert_eq!(load(&uri(&tall)).unwrap().image.dimensions(), (500, 1600));
}

#[test]
fn what_is_not_a_local_png_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let text = dir.path().join("text.png");
    std::fs::write(&text, b"not a picture").unwrap();
    assert_eq!(
        load(&uri(&text)).unwrap_err(),
        "Invalid or oversized window screenshot."
    );
    let truncated = dir.path().join("truncated.png");
    std::fs::write(&truncated, &png(40, 30)[..30]).unwrap();
    assert_eq!(
        load(&uri(&truncated)).unwrap_err(),
        "Invalid or oversized window screenshot."
    );
    for bad in [
        "https://example.com/x.png",
        "not a url",
        "",
        &uri(&dir.path().join("missing.png")),
    ] {
        assert_eq!(load(bad).unwrap_err(), "Invalid screenshot file.", "{bad}");
    }
}

// -- Message shapes ------------------------------------------------------------

/// The call as the message it would be, not sent.
struct Shapes;

impl Put for Shapes {
    fn put<B: serde::Serialize + zbus::zvariant::DynamicType>(
        &self,
        path: &str,
        interface: &str,
        member: &str,
        body: &B,
    ) -> zbus::Result<Message> {
        Message::method_call(path, member)?
            .destination(wire::DESTINATION)?
            .interface(interface)?
            .build(body)
    }
}

fn shape(call: &Call) -> Message {
    wire::invoke(&Shapes, ":1.42", call)
        .expect("a method call")
        .expect("it builds")
}

fn header(message: &Message) -> (String, String, String, String) {
    let header = message.header();
    (
        header.path().unwrap().to_string(),
        header.interface().unwrap().to_string(),
        header.member().unwrap().to_string(),
        message.body().signature().to_string_no_parens(),
    )
}

type Dict = HashMap<String, OwnedValue>;

fn text(dict: &Dict, key: &str) -> String {
    String::try_from(dict[key].try_clone().unwrap()).unwrap()
}

fn flag(dict: &Dict, key: &str) -> bool {
    bool::try_from(dict[key].try_clone().unwrap()).unwrap()
}

#[test]
fn the_window_screenshot_asks_for_the_active_window_without_a_dialog() {
    let message = shape(&Call::Screenshot {
        token: "hal_c2_1".into(),
        window: true,
    });
    assert_eq!(
        header(&message),
        (
            "/org/freedesktop/portal/desktop".into(),
            "org.freedesktop.portal.Screenshot".into(),
            "Screenshot".into(),
            "sa{sv}".into()
        )
    );
    let (parent, options): (String, Dict) = message.body().deserialize().unwrap();
    assert_eq!(parent, "");
    assert_eq!(text(&options, "handle_token"), "hal_c2_1");
    assert!(!flag(&options, "modal"));
    assert!(!flag(&options, "interactive"));
    assert_eq!(
        u32::try_from(options["target"].try_clone().unwrap()).unwrap(),
        8
    );
}

#[test]
fn the_picker_screenshot_is_interactive_and_names_no_target() {
    let message = shape(&Call::Screenshot {
        token: "hal_c2_1".into(),
        window: false,
    });
    let (_, options): (String, Dict) = message.body().deserialize().unwrap();
    assert!(flag(&options, "interactive"));
    assert!(!options.contains_key("target"));
}

#[test]
fn the_shortcut_calls_have_the_global_shortcuts_shapes() {
    let message = shape(&Call::CreateSession {
        token: "hal_c2_2".into(),
        session_token: "hal_c2_3".into(),
    });
    assert_eq!(
        header(&message),
        (
            "/org/freedesktop/portal/desktop".into(),
            "org.freedesktop.portal.GlobalShortcuts".into(),
            "CreateSession".into(),
            "a{sv}".into()
        )
    );
    let (options,): (Dict,) = message.body().deserialize().unwrap();
    assert_eq!(text(&options, "handle_token"), "hal_c2_2");
    assert_eq!(text(&options, "session_handle_token"), "hal_c2_3");

    let message = shape(&Call::BindShortcuts {
        token: "hal_c2_4".into(),
        session: "/org/freedesktop/portal/desktop/session/1_42/hal_c2_3".into(),
        id: "hal-c2-snap-shot-0123456789abcdef".into(),
        trigger: "CTRL+SHIFT+2".into(),
    });
    assert_eq!(header(&message).2, "BindShortcuts");
    assert_eq!(header(&message).3, "oa(sa{sv})sa{sv}");
    let (session, shortcuts, parent, options): (
        zbus::zvariant::OwnedObjectPath,
        Vec<(String, Dict)>,
        String,
        Dict,
    ) = message.body().deserialize().unwrap();
    assert_eq!(
        session.as_str(),
        "/org/freedesktop/portal/desktop/session/1_42/hal_c2_3"
    );
    assert_eq!(parent, "");
    assert_eq!(text(&options, "handle_token"), "hal_c2_4");
    assert_eq!(shortcuts.len(), 1);
    assert_eq!(shortcuts[0].0, "hal-c2-snap-shot-0123456789abcdef");
    assert_eq!(text(&shortcuts[0].1, "description"), "Capture a window");
    assert_eq!(text(&shortcuts[0].1, "preferred_trigger"), "CTRL+SHIFT+2");

    let message = shape(&Call::Configure {
        session: "/org/freedesktop/portal/desktop/session/1_42/hal_c2_3".into(),
    });
    assert_eq!(header(&message).2, "ConfigureShortcuts");
    assert_eq!(header(&message).3, "osa{sv}");
}

#[test]
fn the_housekeeping_calls_have_their_shapes() {
    let message = shape(&Call::Register {
        app_id: "hal-c2".into(),
    });
    assert_eq!(
        header(&message),
        (
            "/org/freedesktop/host/portal/Registry".into(),
            "org.freedesktop.host.portal.Registry".into(),
            "Register".into(),
            "sa{sv}".into()
        )
    );
    let message = shape(&Call::Properties);
    assert_eq!(header(&message).1, "org.freedesktop.DBus.Properties");
    assert_eq!(header(&message).2, "GetAll");
    let (interface,): (String,) = message.body().deserialize().unwrap();
    assert_eq!(interface, "org.freedesktop.portal.Screenshot");
    let message = shape(&Call::Version { generation: 0 });
    assert_eq!(header(&message).2, "Get");
    let (interface, name): (String, String) = message.body().deserialize().unwrap();
    assert_eq!(
        (interface.as_str(), name.as_str()),
        ("org.freedesktop.portal.GlobalShortcuts", "version")
    );

    // A request that never named its handle is closed where its token puts it.
    let message = shape(&Call::CloseRequest {
        token: "hal_c2_1".into(),
        handle: None,
    });
    assert_eq!(
        header(&message),
        (
            "/org/freedesktop/portal/desktop/request/1_42/hal_c2_1".into(),
            "org.freedesktop.portal.Request".into(),
            "Close".into(),
            "".into()
        )
    );
    let message = shape(&Call::CloseRequest {
        token: "hal_c2_1".into(),
        handle: Some("/org/freedesktop/portal/desktop/request/1_42/named".into()),
    });
    assert!(header(&message).0.ends_with("/named"));
    let message = shape(&Call::CloseSession {
        handle: "/org/freedesktop/portal/desktop/session/1_42/hal_c2_3".into(),
    });
    assert_eq!(header(&message).1, "org.freedesktop.portal.Session");
    // Reading the file is not a bus call.
    assert!(wire::invoke(&Shapes, ":1.42", &Call::Load { uri: String::new() }).is_none());
}

/// A signal the portal would send.
fn signal<B: serde::Serialize + zbus::zvariant::DynamicType>(
    path: &str,
    interface: &str,
    member: &str,
    body: &B,
) -> Message {
    Message::signal(path, interface, member)
        .unwrap()
        .sender(":1.7")
        .unwrap()
        .build(body)
        .unwrap()
}

#[test]
fn a_response_signal_is_the_machines_input() {
    let results: HashMap<&str, Value> = HashMap::from([
        ("uri", Value::from("file:///tmp/shot.png")),
        ("session_handle", Value::from("/session/one")),
    ]);
    let ours = request("hal_c2_1");
    let message = signal(
        &ours,
        "org.freedesktop.portal.Request",
        "Response",
        &(0u32, results),
    );
    let Some(Input::Response {
        handle,
        status,
        results,
    }) = wire::parse(&message, ":1.42")
    else {
        panic!("a response")
    };
    assert_eq!(handle, ours);
    assert_eq!(status, 0);
    assert_eq!(results.uri.as_deref(), Some("file:///tmp/shot.png"));
    assert_eq!(results.session_handle.as_deref(), Some("/session/one"));
    assert!(results.shortcuts.is_empty());

    // Another app's request is none of ours.
    let theirs = "/org/freedesktop/portal/desktop/request/1_99/hal_c2_1";
    let message = signal(
        theirs,
        "org.freedesktop.portal.Request",
        "Response",
        &(0u32, HashMap::<&str, Value>::new()),
    );
    assert!(wire::parse(&message, ":1.42").is_none());
}

#[test]
fn the_bound_shortcuts_come_with_their_trigger_descriptions() {
    let entry = |id: &'static str, trigger: &'static str| {
        let entries: HashMap<&str, Value> = HashMap::from([
            ("description", Value::from("Capture a window")),
            ("trigger_description", Value::from(trigger)),
        ]);
        (id, entries)
    };
    let shortcuts = vec![entry("a", "Ctrl+Shift+2"), entry("b", "")];
    let message = signal(
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.GlobalShortcuts",
        "ShortcutsChanged",
        &(
            zbus::zvariant::ObjectPath::try_from("/session/one").unwrap(),
            shortcuts,
        ),
    );
    let Some(Input::ShortcutsChanged { session, shortcuts }) = wire::parse(&message, ":1.42")
    else {
        panic!("a change")
    };
    assert_eq!(session, "/session/one");
    assert_eq!(shortcuts, [bound("a", "Ctrl+Shift+2"), bound("b", "")]);

    // The same list in a Response.
    let results: HashMap<&str, Value> =
        HashMap::from([("shortcuts", Value::from(vec![entry("a", "Ctrl+Shift+2")]))]);
    let message = signal(
        &request("hal_c2_4"),
        "org.freedesktop.portal.Request",
        "Response",
        &(0u32, results),
    );
    let Some(Input::Response { results, .. }) = wire::parse(&message, ":1.42") else {
        panic!("a response")
    };
    assert_eq!(results.shortcuts, [bound("a", "Ctrl+Shift+2")]);
}

#[test]
fn the_other_portal_signals_are_inputs_too() {
    let activated = signal(
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.GlobalShortcuts",
        "Activated",
        &(
            zbus::zvariant::ObjectPath::try_from("/session/one").unwrap(),
            "hal-c2-snap-shot-0123456789abcdef",
            12345u64,
            HashMap::<&str, Value>::new(),
        ),
    );
    let Some(Input::Activated { session, id }) = wire::parse(&activated, ":1.42") else {
        panic!("an activation")
    };
    assert_eq!(
        (session.as_str(), id.as_str()),
        ("/session/one", "hal-c2-snap-shot-0123456789abcdef")
    );

    let closed = signal(
        "/org/freedesktop/portal/desktop/session/1_42/hal_c2_3",
        "org.freedesktop.portal.Session",
        "Closed",
        &HashMap::<&str, Value>::new(),
    );
    assert!(matches!(
        wire::parse(&closed, ":1.42"),
        Some(Input::SessionClosed { handle }) if handle.ends_with("/hal_c2_3")
    ));

    let owner = |old: &str, new: &str, name: &str| {
        signal(
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            &(name.to_owned(), old.to_owned(), new.to_owned()),
        )
    };
    assert!(matches!(
        wire::parse(&owner(":1.7", ":1.8", wire::DESTINATION), ":1.42"),
        Some(Input::OwnerChanged { was_owned: true })
    ));
    assert!(matches!(
        wire::parse(&owner("", ":1.8", wire::DESTINATION), ":1.42"),
        Some(Input::OwnerChanged { was_owned: false })
    ));
    assert!(wire::parse(&owner(":1.7", ":1.8", "org.other"), ":1.42").is_none());
}

#[test]
fn replies_become_inputs() {
    let reply = |call: &Call, message: Message| wire::reply(call, Ok(message));
    let method_return = |body: &dyn Fn(Message) -> zbus::Result<Message>| {
        let call = Message::method_call("/", "X").unwrap().build(&()).unwrap();
        body(call).unwrap()
    };
    // Properties.GetAll: version and targets.
    let props = method_return(&|call| {
        let properties: HashMap<&str, Value> = HashMap::from([
            ("version", Value::from(3u32)),
            ("AvailableTargets", Value::from(9u32)),
        ]);
        Message::method_return(&call.header())?.build(&(properties,))
    });
    assert!(matches!(
        reply(&Call::Properties, props),
        Some(Input::Properties(Some((3, 9))))
    ));
    // Properties.Get: a variant holding the version.
    let version =
        method_return(&|call| Message::method_return(&call.header())?.build(&(Value::from(2u32),)));
    assert!(matches!(
        reply(&Call::Version { generation: 5 }, version),
        Some(Input::Version {
            generation: 5,
            version: Some(2)
        })
    ));
    // A request call answers with its handle.
    let handle = method_return(&|call| {
        Message::method_return(&call.header())?
            .build(&(zbus::zvariant::ObjectPath::try_from("/r/one").unwrap(),))
    });
    let screenshot = Call::Screenshot {
        token: "hal_c2_1".into(),
        window: true,
    };
    assert!(matches!(
        reply(&screenshot, handle),
        Some(Input::Replied { token, handle: Ok(handle) }) if token == "hal_c2_1" && handle == "/r/one"
    ));
    // A refusal is the error, and failing to ask at all is "no".
    let refused = wire::reply(&screenshot, Err(zbus::Error::Failure("no".into())));
    assert!(matches!(
        refused,
        Some(Input::Replied { handle: Err(_), .. })
    ));
    assert!(matches!(
        wire::reply(&Call::Properties, Err(zbus::Error::Failure("no".into()))),
        Some(Input::Properties(None))
    ));
    // Calls nobody waits for have no input.
    assert!(
        wire::reply(
            &Call::Configure {
                session: "/s".into()
            },
            Err(zbus::Error::Failure("x".into()))
        )
        .is_none()
    );
}

// The calls and replies of one backend, where a test can read them.
struct Recording(RefCell<Vec<Call>>, RefCell<Vec<Input>>);

impl Recording {
    fn new() -> std::rc::Rc<Recording> {
        std::rc::Rc::new(Recording(
            RefCell::new(Vec::new()),
            RefCell::new(Vec::new()),
        ))
    }
}

struct Tap(std::rc::Rc<Recording>);

impl Wire for Tap {
    fn send(&mut self, call: Call) {
        self.0.0.borrow_mut().push(call);
    }

    fn arrive(&mut self) -> Vec<Input> {
        std::mem::take(&mut *self.0.1.borrow_mut())
    }
}

#[test]
fn the_backend_sends_calls_and_hands_over_events() {
    let tape = Recording::new();
    let mut portal = Portal::new(
        &platform(false),
        Box::new(Tap(tape.clone())),
        "hal-c2",
        None,
    );
    assert!(!portal.session().ready);
    assert!(portal.probe().is_empty());
    assert_eq!(tape.0.borrow().len(), 2);
    tape.1.borrow_mut().push(Input::Properties(Some((3, 8))));
    let events = portal.arrive();
    assert!(matches!(events.as_slice(), [Event::Changed]));
    assert_eq!(portal.session().backend, "screenshot-portal");

    let events = portal.capture();
    assert!(matches!(
        events.as_slice(),
        [Event::After { ms: 120_000, .. }]
    ));
    let Some(Call::Screenshot { token, .. }) = tape.0.borrow().last().cloned() else {
        panic!("a screenshot")
    };
    tape.1
        .borrow_mut()
        .push(response(&request(&token), 1, Results::default()));
    let events = portal.arrive();
    assert!(matches!(
        events.as_slice(),
        [Event::Cancel(_), Event::Failed(_)]
    ));
}
