//! A state machine property over [`Machine`] and a fake helper process: the
//! owner starts, finishes and cancels runs, the helper writes lines of every
//! kind, writes to stderr, exits, and the kill timer runs out, in any order.
//! It checks what the QML sees (`running` is whether a helper exists, a
//! failed run is never delivered, one run delivers once and only what the
//! helper said) and what the helper is done to (a cancelled or failed run is
//! stopped politely and then killed, and an ended one leaves nothing of its
//! group).

use proptest::prelude::*;

use super::machine::*;

/// The lines a helper may write, and the way it may break them up.
#[derive(Clone, Debug)]
enum Said {
    Recording,
    Transcribing,
    BadPhase,
    Transcript(&'static str),
    Blank,
    Garbage,
    NotAnObject,
    WrongType,
    /// A line that stops without its newline.
    Unfinished,
    /// More than the limit allows, in one write.
    Flood,
}

#[derive(Clone, Debug)]
enum Action {
    Start { executable: bool, spawns: bool },
    FinishRecording,
    Cancel,
    Say(Said),
    Stderr(&'static str),
    Exit { code: i32, normal: bool },
    TimerFires,
}

fn said() -> impl Strategy<Value = Said> {
    prop_oneof![
        3 => Just(Said::Recording),
        2 => Just(Said::Transcribing),
        1 => Just(Said::BadPhase),
        3 => prop::sample::select(vec!["把 src/auth.ts 里的 verifyToken 改掉", "", "  \n ", "ok"])
            .prop_map(Said::Transcript),
        1 => Just(Said::Blank),
        1 => Just(Said::Garbage),
        1 => Just(Said::NotAnObject),
        1 => Just(Said::WrongType),
        1 => Just(Said::Unfinished),
        1 => Just(Said::Flood),
    ]
}

fn action() -> impl Strategy<Value = Action> {
    prop_oneof![
        4 => (prop::bool::weighted(0.9), prop::bool::weighted(0.9))
            .prop_map(|(executable, spawns)| Action::Start { executable, spawns }),
        3 => Just(Action::FinishRecording),
        3 => Just(Action::Cancel),
        8 => said().prop_map(Action::Say),
        2 => prop::sample::select(vec!["", "Fixture failure", "  trailing \n"]).prop_map(Action::Stderr),
        4 => (prop::sample::select(vec![0, 0, 1, 2]), prop::bool::weighted(0.8))
            .prop_map(|(code, normal)| Action::Exit { code, normal }),
        2 => Just(Action::TimerFires),
    ]
}

/// The helper as the real one is to the machine: it exists from a spawn that
/// works until it exits, and what the machine asks of it lands here.
#[derive(Default)]
struct Fake {
    pid: i64,
    next_pid: i64,
    /// A helper exists.
    present: bool,
    /// The helper was sent `stop`.
    told_to_stop: bool,
    /// What it was sent since the last check: (to the group, forced).
    signals: Vec<(bool, bool)>,
    delivered: Vec<String>,
    armed: bool,
}

/// The reference for one run: what the helper said that should be delivered.
#[derive(Default)]
struct Run {
    /// The first transcript the helper wrote, whole lines only.
    transcript: Option<&'static str>,
    cancelled: bool,
}

impl Fake {
    /// Does what the machine asks; returns the effects for the checks.
    fn carry_out(&mut self, machine: &mut Machine, spawns: bool) -> Vec<Effect> {
        let mut all = Vec::new();
        loop {
            let effects = machine.take();
            if effects.is_empty() {
                return all;
            }
            for effect in &effects {
                match effect {
                    Effect::Spawn if spawns => {
                        self.next_pid += 1;
                        self.pid = 1000 + self.next_pid;
                        self.present = true;
                        self.told_to_stop = false;
                        machine.started(self.pid);
                    }
                    Effect::Spawn => machine.failed_to_start("No such file"),
                    Effect::WriteStop => self.told_to_stop = true,
                    Effect::SignalGroup { pgid, force } => {
                        assert_eq!(*pgid, self.pid, "the group is the helper's");
                        self.signals.push((true, *force));
                    }
                    Effect::SignalProcess { force } => self.signals.push((false, *force)),
                    Effect::StartKillTimer => self.armed = true,
                    Effect::StopKillTimer => self.armed = false,
                    Effect::Ready(text) => self.delivered.push(text.clone()),
                }
            }
            all.extend(effects);
        }
    }
}

fn bytes_of(said: &Said) -> Vec<u8> {
    match said {
        Said::Recording => b"{\"type\":\"status\",\"phase\":\"recording\"}\n".to_vec(),
        Said::Transcribing => b"{\"type\":\"status\",\"phase\":\"transcribing\"}\n".to_vec(),
        Said::BadPhase => b"{\"type\":\"status\",\"phase\":\"dancing\"}\n".to_vec(),
        Said::Transcript(text) => format!(
            "{{\"type\":\"transcript\",\"text\":{}}}\n",
            serde_json::json!(text)
        )
        .into_bytes(),
        Said::Blank => b"  \n".to_vec(),
        Said::Garbage => b"not json\n".to_vec(),
        Said::NotAnObject => b"[1,2]\n".to_vec(),
        Said::WrongType => b"{\"type\":\"dance\"}\n".to_vec(),
        Said::Unfinished => b"{\"type\":\"status\"".to_vec(),
        Said::Flood => vec![b'x'; 1024 * 1024 + 1],
    }
}

fn run_actions(actions: Vec<Action>) {
    let mut machine = Machine::default();
    let mut fake = Fake::default();
    let mut run = Run::default();
    // What the first error of this run was.
    let mut first_error = String::new();
    for action in actions {
        let was_error = machine.error().to_owned();
        let was_running = machine.running();
        let was_cancelled = run.cancelled;
        let effects = match action {
            Action::Start { executable, spawns } => {
                let started = machine.start(executable);
                assert_eq!(started, !was_running && executable, "start takes a run");
                if !was_running {
                    run = Run::default();
                    first_error.clear();
                    fake.delivered.clear();
                    if !executable {
                        assert_eq!(machine.error(), NOT_EXECUTABLE);
                    }
                }
                let effects = fake.carry_out(&mut machine, spawns);
                if started && !spawns {
                    assert!(
                        !machine.running(),
                        "a helper that cannot start is not running"
                    );
                    assert!(!machine.error().is_empty());
                }
                effects
            }
            Action::FinishRecording => {
                let recording = was_running && machine.status() == "recording";
                machine.finish_recording();
                let effects = fake.carry_out(&mut machine, true);
                assert_eq!(effects.contains(&Effect::WriteStop), recording);
                if recording {
                    assert_eq!(machine.status(), "transcribing");
                }
                effects
            }
            Action::Cancel => {
                machine.cancel();
                let effects = fake.carry_out(&mut machine, true);
                if was_running && !was_cancelled {
                    run.cancelled = true;
                    assert_eq!(machine.status(), "cancelling");
                    assert!(effects.contains(&Effect::SignalGroup {
                        pgid: fake.pid,
                        force: false
                    }));
                    assert!(effects.contains(&Effect::StartKillTimer));
                } else {
                    assert!(effects.is_empty(), "nothing to cancel");
                }
                effects
            }
            Action::Say(said) if fake.present => {
                let bytes = bytes_of(&said);
                // A whole transcript line counts only while the run is
                // listening: not cancelled, nothing wrong yet.
                let heard = !run.cancelled && machine.error().is_empty();
                machine.stdout(&bytes);
                if heard
                    && machine.error().is_empty()
                    && let Said::Transcript(text) = said
                    && run.transcript.is_none()
                {
                    run.transcript = Some(text);
                }
                fake.carry_out(&mut machine, true)
            }
            Action::Stderr(text) if fake.present => {
                machine.stderr(text.as_bytes());
                fake.carry_out(&mut machine, true)
            }
            Action::Exit { code, normal } if fake.present => {
                let delivered_before = fake.delivered.len();
                let errored = !machine.error().is_empty();
                machine.finished(code, normal);
                fake.present = false;
                let effects = fake.carry_out(&mut machine, true);
                assert!(!machine.running());
                assert_eq!(machine.status(), "idle");
                assert!(
                    !machine.timer_armed() && !fake.armed,
                    "the timer ends with the helper"
                );
                assert_eq!(machine.group(), None);
                assert!(
                    effects.contains(&Effect::SignalGroup {
                        pgid: fake.pid,
                        force: true
                    }),
                    "what the helper left behind goes with it"
                );
                let delivered = fake.delivered.len() - delivered_before;
                if run.cancelled || errored || !machine.error().is_empty() {
                    assert_eq!(delivered, 0, "a failed or cancelled run says nothing");
                } else {
                    // Delivered exactly what the helper said, once.
                    assert_eq!(delivered, 1);
                    assert_eq!(
                        Some(fake.delivered.last().unwrap().as_str()),
                        run.transcript
                    );
                    assert!(code == 0 && normal);
                    assert!(!fake.delivered.last().unwrap().trim().is_empty());
                }
                if !run.cancelled && !errored && (code != 0 || !normal) {
                    assert!(!machine.error().is_empty(), "a helper that failed says so");
                }
                effects
            }
            Action::TimerFires => {
                let armed = machine.timer_armed();
                machine.kill_timer_fired();
                fake.armed = false;
                let effects = fake.carry_out(&mut machine, true);
                if armed {
                    assert!(effects.contains(&Effect::SignalGroup {
                        pgid: fake.pid,
                        force: true
                    }));
                } else {
                    assert!(effects.is_empty());
                }
                effects
            }
            // The helper is not there to write or exit.
            _ => Vec::new(),
        };

        // After every step.
        assert_eq!(
            machine.running(),
            fake.present,
            "running is whether a helper exists"
        );
        if !machine.running() {
            assert_eq!(machine.status(), "idle");
            assert!(!machine.timer_armed());
        } else {
            assert_ne!(machine.status(), "idle");
            assert_eq!(machine.group(), Some(fake.pid));
            if machine.status() == "cancelling" {
                assert!(run.cancelled);
            }
        }
        // A run that fails with its helper still there is asked to stop, and
        // killed if it does not.
        if was_error.is_empty() && !machine.error().is_empty() && machine.running() {
            assert!(effects.contains(&Effect::StartKillTimer));
            assert!(effects.contains(&Effect::SignalGroup {
                pgid: fake.pid,
                force: false
            }));
        }
        assert_eq!(
            machine.timer_armed(),
            fake.armed,
            "the timer is the machine's"
        );
        // The first error stays until the next run.
        if !machine.error().is_empty() {
            if first_error.is_empty() {
                first_error = machine.error().to_owned();
            }
            assert_eq!(machine.error(), first_error);
        } else {
            assert!(first_error.is_empty(), "an error stays until the next run");
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn any_order_of_start_finish_cancel_output_and_exit(
        actions in prop::collection::vec(action(), 0..48),
    ) {
        run_actions(actions);
    }
}
