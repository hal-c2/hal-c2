//! LocalTranscriber's state machine, apart from the process it drives: what
//! `status`, `error` and `running` are after each thing that can happen to
//! one helper process, and what to do to the process in answer.
//!
//! It is the C++ class with the QProcess taken out. What happens to the
//! process comes in as a method (`started`, `stdout`, `finished`, ...); what
//! the machine wants done to it (write, signal, arm the kill timer) goes out
//! as [`Effect`]s, which [`Machine::take`] hands over. The QML type carries
//! them out on a real process; the property test carries them out on a fake
//! one, and so reaches every order of events.

use serde_json::Value;

/// How long after a polite stop the helper's group is killed.
pub const KILL_AFTER_MS: u64 = 1000;
/// How much output a helper may write before it is stopped.
const OUTPUT_LIMIT: u64 = 1024 * 1024;
/// How much of the helper's stderr is kept, to say why it failed.
const STDERR_KEPT: usize = 8192;

pub const NOT_EXECUTABLE: &str = "Choose an existing absolute transcription executable path.";
pub const FAILED: &str = "The transcription helper failed.";
pub const NO_SPEECH: &str = "The transcription helper returned no speech.";
pub const TOO_MUCH: &str = "The transcription helper exceeded the output limit.";
pub const INVALID_JSON: &str = "The transcription helper returned invalid JSON.";
pub const UNKNOWN_PHASE: &str = "The transcription helper returned an unknown phase.";
pub const UNEXPECTED: &str = "The transcription helper returned an unexpected message.";

/// What the machine asks of the process and the host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    /// Start the configured program in a session of its own.
    Spawn,
    /// Write `stop\n` to its stdin.
    WriteStop,
    /// Signal every process of the helper's group: SIGKILL when `force`,
    /// else SIGTERM.
    SignalGroup {
        pgid: i64,
        force: bool,
    },
    /// Signal the helper alone, before its group is known.
    SignalProcess {
        force: bool,
    },
    /// (Re)start the single-shot kill timer: after [`KILL_AFTER_MS`] it
    /// calls [`Machine::kill_timer_fired`].
    StartKillTimer,
    StopKillTimer,
    /// The transcript, delivered once the helper is done.
    Ready(String),
}

#[derive(Debug)]
pub struct Machine {
    alive: bool,
    status: &'static str,
    error: String,
    output: Vec<u8>,
    stderr: Vec<u8>,
    transcript: String,
    output_bytes: u64,
    group: i64,
    received: bool,
    cancelled: bool,
    timer: bool,
    fx: Vec<Effect>,
}

impl Default for Machine {
    fn default() -> Self {
        Machine {
            alive: false,
            status: "idle",
            error: String::new(),
            output: Vec::new(),
            stderr: Vec::new(),
            transcript: String::new(),
            output_bytes: 0,
            group: 0,
            received: false,
            cancelled: false,
            timer: false,
            fx: Vec::new(),
        }
    }
}

impl Machine {
    /// Whether a helper process exists, from `start` until it has finished
    /// or failed to start.
    pub fn running(&self) -> bool {
        self.alive
    }

    /// `idle`, `starting`, `recording`, `transcribing` or `cancelling`.
    pub fn status(&self) -> &'static str {
        self.status
    }

    /// Why the last run failed; empty when it did not.
    pub fn error(&self) -> &str {
        &self.error
    }

    /// The group the machine will signal, once the helper started; none
    /// before and after.
    pub fn group(&self) -> Option<i64> {
        (self.group > 0).then_some(self.group)
    }

    /// Whether the kill timer is armed.
    pub fn timer_armed(&self) -> bool {
        self.timer
    }

    /// What the machine asked since the last call.
    pub fn take(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.fx)
    }

    /// Starts a run, with `executable` saying whether the configured program
    /// is an existing absolute executable file. False when a run is going or
    /// the program is not one; the error says which.
    pub fn start(&mut self, executable: bool) -> bool {
        if self.alive {
            return false;
        }
        self.output.clear();
        self.stderr.clear();
        self.transcript.clear();
        self.output_bytes = 0;
        self.received = false;
        self.cancelled = false;
        self.error.clear();
        if !executable {
            self.fail(NOT_EXECUTABLE);
            return false;
        }
        self.set_status("starting");
        self.alive = true;
        self.fx.push(Effect::Spawn);
        true
    }

    /// The user is done speaking: the helper is told to transcribe.
    pub fn finish_recording(&mut self) {
        if self.alive && self.status == "recording" {
            self.fx.push(Effect::WriteStop);
            self.set_status("transcribing");
        }
    }

    /// Stops the helper and drops what it said.
    pub fn cancel(&mut self) {
        if !self.alive || self.cancelled {
            return;
        }
        self.cancelled = true;
        self.set_status("cancelling");
        self.stop_process(false);
        self.fx.push(Effect::StartKillTimer);
        self.timer = true;
    }

    /// The process exists, as `pid`, the leader of its own group.
    pub fn started(&mut self, pid: i64) {
        self.group = pid;
        if self.cancelled || !self.error.is_empty() {
            self.stop_process(false);
        }
    }

    pub fn failed_to_start(&mut self, why: &str) {
        self.alive = false;
        self.fail(why);
        self.set_status("idle");
    }

    pub fn stdout(&mut self, bytes: &[u8]) {
        self.output_bytes += bytes.len() as u64;
        if self.cancelled || !self.error.is_empty() {
            return;
        }
        if self.output_bytes > OUTPUT_LIMIT {
            self.fail(TOO_MUCH);
            return;
        }
        self.output.extend_from_slice(bytes);
        while let Some(newline) = self.output.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.output.drain(..=newline).take(newline).collect();
            self.parse_line(&line);
            if !self.error.is_empty() {
                return;
            }
        }
    }

    pub fn stderr(&mut self, bytes: &[u8]) {
        self.stderr.extend_from_slice(bytes);
        let over = self.stderr.len().saturating_sub(STDERR_KEPT);
        self.stderr.drain(..over);
    }

    /// The helper exited, with `code` when it `normal`ly did (not by a
    /// signal). Everything it wrote has come in before this.
    pub fn finished(&mut self, code: i32, normal: bool) {
        self.alive = false;
        self.fx.push(Effect::StopKillTimer);
        self.timer = false;
        // Whatever the helper left behind goes with it.
        self.stop_process(true);
        self.group = 0;
        if !self.output.is_empty() && self.error.is_empty() && !self.cancelled {
            let rest = std::mem::take(&mut self.output);
            self.parse_line(&rest);
        }
        self.output.clear();
        if !self.cancelled && self.error.is_empty() {
            if !normal || code != 0 {
                let detail = String::from_utf8_lossy(&self.stderr).trim().to_owned();
                self.fail(if detail.is_empty() { FAILED } else { &detail });
            } else if !self.received || self.transcript.trim().is_empty() {
                self.fail(NO_SPEECH);
            }
        }
        let transcript = std::mem::take(&mut self.transcript);
        let deliver = !self.cancelled && self.error.is_empty();
        self.set_status("idle");
        if deliver {
            self.fx.push(Effect::Ready(transcript));
        }
    }

    /// The kill timer ran out: a helper that did not stop politely is killed.
    pub fn kill_timer_fired(&mut self) {
        if !self.timer {
            return;
        }
        self.timer = false;
        self.stop_process(true);
    }

    fn set_status(&mut self, status: &'static str) {
        self.status = status;
    }

    /// Records why the run failed (the first reason stays) and stops a
    /// helper that is still there.
    fn fail(&mut self, error: &str) {
        if !self.error.is_empty() {
            return;
        }
        self.error = error.to_owned();
        if self.alive {
            self.stop_process(false);
            self.fx.push(Effect::StartKillTimer);
            self.timer = true;
        }
    }

    fn stop_process(&mut self, force: bool) {
        self.fx.push(if self.group > 0 {
            Effect::SignalGroup {
                pgid: self.group,
                force,
            }
        } else {
            Effect::SignalProcess { force }
        });
    }

    /// One line of the helper's protocol: `{"type":"status","phase":
    /// "recording"|"transcribing"}` or, once, `{"type":"transcript","text":
    /// "..."}`. Anything else fails the run.
    fn parse_line(&mut self, line: &[u8]) {
        if line.trim_ascii().is_empty() {
            return;
        }
        let Ok(Value::Object(message)) = serde_json::from_slice::<Value>(line) else {
            return self.fail(INVALID_JSON);
        };
        let text_of = |key: &str| message.get(key).and_then(Value::as_str);
        match text_of("type").unwrap_or_default() {
            "status" => match text_of("phase").unwrap_or_default() {
                "recording" => self.set_status("recording"),
                "transcribing" => self.set_status("transcribing"),
                _ => self.fail(UNKNOWN_PHASE),
            },
            "transcript" if !self.received && text_of("text").is_some() => {
                self.received = true;
                self.transcript = text_of("text").unwrap_or_default().to_owned();
            }
            _ => self.fail(UNEXPECTED),
        }
    }
}
