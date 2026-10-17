//! `LocalTranscriber` as trusted QML uses it: a real helper (a shell script
//! written under the target's temp dir) speaking the line protocol, driven
//! through `start`, `finishRecording` and `cancel`. The helper's output
//! arrives on threads; a test waits on the waker, then delivers, and never
//! sleeps. The state machine's orders of events are src/local_transcriber's
//! property test.

#![cfg(unix)]

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Mutex, mpsc};
use std::time::Duration;

use common::{call, shell, text};
use hal_c2_shell::local_transcriber::{Effect, Machine, deliver, set_wake};
use hal_c2_shell::mc::Disconnected;
use ljos::prelude::QmlValue;
use ljos::prelude::{Engine, ObjectId, Value};

const MAIN: &str = r#"
import QtQml
import HalC2.Shell

QtObject {
    id: root
    property string program: ""
    property var arguments: []
    property string heard: ""
    property int heardCount: 0
    readonly property bool running: t.running
    readonly property string status: t.status
    readonly property string error: t.error
    property int changes: 0

    property LocalTranscriber transcriber: LocalTranscriber {
        id: t
        program: root.program
        arguments: root.arguments
        onTranscriptReady: function (text) { root.heard = text; root.heardCount += 1 }
        onStateChanged: root.changes += 1
    }
    function start() { return t.start() }
    function finish() { t.finishRecording() }
    function cancel() { t.cancel() }
}
"#;

struct Fixture {
    engine: Engine,
    root: ObjectId,
    woken: mpsc::Receiver<()>,
    dir: PathBuf,
}

impl Fixture {
    fn new(test: &str) -> Fixture {
        let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
        let (wake, woken) = mpsc::channel();
        let wake = Mutex::new(wake);
        set_wake(&engine, move || {
            let _ = wake.lock().unwrap().send(());
        });
        let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
            .join("local-transcriber")
            .join(test);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Fixture {
            engine,
            root,
            woken,
            dir,
        }
    }

    /// An executable script `name` with `body` under the test's directory.
    fn helper(&self, name: &str, body: &str) -> String {
        let path = self.dir.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn set(&self, name: &str, value: Value) {
        self.engine
            .write_by_name(self.root, name, value)
            .expect("property is writable");
    }

    fn start(&self, program: &str) -> bool {
        self.set("program", Value::string(program));
        call(&self.engine, self.root, "start", &[]).to_boolean()
    }

    fn get(&self, name: &str) -> String {
        text(&self.engine, self.root, name)
    }

    /// Delivers what the helper wrote until `done` holds.
    fn until(&self, what: &str, done: impl Fn(&Fixture) -> bool) {
        while !done(self) {
            self.woken
                .recv_timeout(Duration::from_secs(30))
                .unwrap_or_else(|_| {
                    panic!(
                        "waiting for {what}: status {} error {:?}",
                        self.get("status"),
                        self.get("error")
                    )
                });
            deliver(&self.engine);
        }
    }
}

#[test]
fn a_helper_records_is_told_to_stop_and_says_what_it_heard() {
    let f = Fixture::new("heard");
    let helper = f.helper(
        "helper.sh",
        r#"echo '{"type":"status","phase":"recording"}'
read line
[ "$line" = stop ] || exit 3
echo '{"type":"status","phase":"transcribing"}'
echo '{"type":"transcript","text":"hello there"}'"#,
    );
    assert!(f.start(&helper));
    assert_eq!(f.get("status"), "starting");
    f.until("recording", |f| f.get("status") == "recording");
    assert_eq!(f.get("running"), "true");
    call(&f.engine, f.root, "finish", &[]);
    assert_eq!(f.get("status"), "transcribing");
    f.until("the end", |f| f.get("running") == "false");
    assert_eq!(f.get("status"), "idle");
    assert_eq!(f.get("error"), "");
    assert_eq!(f.get("heard"), "hello there");
    assert_eq!(f.get("heardCount"), "1");
}

#[test]
fn arguments_are_passed_as_they_are() {
    let f = Fixture::new("arguments");
    let helper = f.helper(
        "helper.sh",
        r#"printf '{"type":"transcript","text":"%s|%s"}\n' "$1" "$2""#,
    );
    f.set("arguments", serde_json::json!(["a b", "$HOME"]).to_value());
    assert!(f.start(&helper));
    f.until("the end", |f| f.get("running") == "false");
    assert_eq!(f.get("heard"), "a b|$HOME");
}

#[test]
fn a_cancelled_run_says_nothing_and_leaves_no_helper() {
    let f = Fixture::new("cancel");
    let pid_file = f.dir.join("pid");
    // The helper starts a child of its own and waits for it.
    let helper = f.helper(
        "helper.sh",
        &format!(
            r#"echo '{{"type":"status","phase":"recording"}}'
sleep 600 &
echo $! > {}
wait"#,
            pid_file.display()
        ),
    );
    assert!(f.start(&helper));
    f.until("recording", |f| f.get("status") == "recording");
    // The echo above came before the pid was written.
    while !std::fs::read_to_string(&pid_file).is_ok_and(|s| s.ends_with('\n')) {
        std::thread::yield_now();
    }
    let child: i32 = std::fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    call(&f.engine, f.root, "cancel", &[]);
    assert_eq!(f.get("status"), "cancelling");
    f.until("the end", |f| f.get("running") == "false");
    assert_eq!(f.get("status"), "idle");
    assert_eq!(f.get("error"), "");
    assert_eq!(f.get("heardCount"), "0");
    // SAFETY: signal 0 only asks whether the process exists.
    let alive = |pid| unsafe { libc::kill(pid, 0) == 0 };
    // Gone, or a zombie awaiting its reaper: the group was signalled.
    let zombie =
        std::fs::read_to_string(format!("/proc/{child}/stat")).is_ok_and(|s| s.contains(") Z "));
    assert!(!alive(child) || zombie, "the helper's child outlived it");
}

#[test]
fn a_helper_that_fails_says_what_it_wrote_to_stderr() {
    let f = Fixture::new("fails");
    let helper = f.helper("helper.sh", "echo 'no microphone' >&2\nexit 1");
    assert!(f.start(&helper));
    f.until("the end", |f| f.get("running") == "false");
    assert_eq!(f.get("error"), "no microphone");
    assert_eq!(f.get("heardCount"), "0");
    // A new run starts clean.
    let fine = f.helper("fine.sh", r#"echo '{"type":"transcript","text":"ok"}'"#);
    assert!(f.start(&fine));
    assert_eq!(f.get("error"), "");
    f.until("the end", |f| f.get("running") == "false");
    assert_eq!(f.get("heard"), "ok");
}

#[test]
fn only_an_absolute_executable_file_starts() {
    let f = Fixture::new("not-executable");
    for program in ["", "helper.sh", "/no/such/helper"] {
        assert!(!f.start(program), "{program:?}");
        assert_eq!(
            f.get("error"),
            "Choose an existing absolute transcription executable path."
        );
        assert_eq!(f.get("status"), "idle");
        assert_eq!(f.get("running"), "false");
    }
    let plain = f.dir.join("plain");
    std::fs::write(&plain, "#!/bin/sh\n").unwrap();
    assert!(!f.start(&plain.to_string_lossy()));
}

#[test]
fn the_protocol_is_read_a_line_at_a_time_and_a_bad_line_fails_the_run() {
    let mut m = Machine::default();
    assert!(m.start(true));
    assert_eq!(m.take(), vec![Effect::Spawn]);
    m.started(41);
    // A line split across chunks, and two in one.
    m.stdout(br#"{"type":"status","phase":"reco"#);
    assert_eq!(m.status(), "starting");
    m.stdout(b"rding\"}\n{\"type\":\"status\",\"phase\":\"transcribing\"}\n");
    assert_eq!(m.status(), "transcribing");
    m.stdout(b"not json\n");
    assert_eq!(m.error(), "The transcription helper returned invalid JSON.");
    // The helper is asked to stop, and killed when it does not.
    assert!(m.take().contains(&Effect::SignalGroup {
        pgid: 41,
        force: false
    }));
    assert!(m.timer_armed());
    m.kill_timer_fired();
    assert!(m.take().contains(&Effect::SignalGroup {
        pgid: 41,
        force: true
    }));
    m.finished(0, false);
    assert_eq!(m.status(), "idle");
    assert!(!m.running());
    // The first reason stays, and nothing is delivered.
    assert_eq!(m.error(), "The transcription helper returned invalid JSON.");
    assert!(!m.take().iter().any(|e| matches!(e, Effect::Ready(_))));
}

#[test]
fn a_transcript_comes_once_and_only_as_the_helper_ends() {
    let say = |bytes: &[u8]| {
        let mut m = Machine::default();
        m.start(true);
        m.started(7);
        m.take();
        m.stdout(bytes);
        m
    };
    let mut m = say(b"{\"type\":\"transcript\",\"text\":\"hi\"}\n");
    assert!(m.running());
    assert!(m.error().is_empty());
    m.finished(0, true);
    assert!(m.take().contains(&Effect::Ready("hi".into())));
    // A second transcript is unexpected; an unknown phase and type are.
    let m = say(
        b"{\"type\":\"transcript\",\"text\":\"a\"}\n{\"type\":\"transcript\",\"text\":\"b\"}\n",
    );
    assert_eq!(
        m.error(),
        "The transcription helper returned an unexpected message."
    );
    let m = say(b"{\"type\":\"status\",\"phase\":\"dancing\"}\n");
    assert_eq!(
        m.error(),
        "The transcription helper returned an unknown phase."
    );
    // Blank lines are nothing; an empty transcript is no speech.
    let mut m = say(b"\n  \n{\"type\":\"transcript\",\"text\":\"  \"}\n");
    assert!(m.error().is_empty());
    m.finished(0, true);
    assert_eq!(m.error(), "The transcription helper returned no speech.");
}
