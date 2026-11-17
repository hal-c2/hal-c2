//! `LocalTranscriber` in `HalC2.Shell`, desktop-qt's QObject of the same
//! name (src/LocalTranscriber.h): trusted local QML may opt into one
//! explicitly configured transcription helper. It runs `program` with
//! `arguments` (no shell), reads the helper's line protocol from its stdout
//! (`machine.rs` says what the lines mean) and tells `finishRecording()`
//! through its stdin. `transcriptReady(text)` says what was said.
//!
//! The helper runs in a session of its own, so that stopping it also stops
//! a recorder it started and left behind; the group is signalled when the
//! run is cancelled, fails, ends, or the object goes away.
//!
//! The helper's pipes are read on threads of their own. What they see goes
//! on the "local-transcriber" side stream ([`wire`]) with the transcriber it
//! is for, and the stream's handler hands it over on the Engine thread.
//!
//! DECISION: that stream waits ([`Feed`]): every chunk of the helper's
//! output matters, in order. A reader whose stream is full waits, so the
//! helper's pipe fills and the helper waits in its write; nothing is dropped
//! and at most [`CAPACITY`] chunks wait for the UI.
//!
//! Where Qt reports `started` later, once the process exists, this reports
//! it as soon as `start()` has spawned the helper.

mod machine;
#[cfg(test)]
mod prop;

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{ChildStdin, Command, Stdio};
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::Duration;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ObjectId, QmlObject, QtObject, Value, qml_impl,
};

pub use machine::{Effect, KILL_AFTER_MS, Machine};

use crate::streams::{Feed, Wire};

/// How many chunks of the helpers' output wait for the UI at most: a chunk
/// is one read of up to 64 KiB, so at most 4 MiB waits.
pub const CAPACITY: usize = 64;

/// Adds the type to the `HalC2.Shell` module.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [LocalTranscriber]));
}

#[derive(QmlObject)]
#[qml(module = "HalC2.Shell", name = "LocalTranscriber", extends = QtObject)]
pub struct LocalTranscriber {
    #[qml(base)]
    base: QtObject,
    /// The helper's absolute path: an executable file, or `start()` fails.
    #[qml(notify)]
    program: Atom,
    /// Its arguments, a list of strings, passed as they are.
    #[qml(notify)]
    arguments: Vec<String>,
    #[qml(notify, readonly)]
    running: bool,
    /// `idle`, `starting`, `recording`, `transcribing` or `cancelling`.
    #[qml(notify, readonly)]
    status: Atom,
    #[qml(notify, readonly)]
    error: Atom,
    #[qml(skip)]
    state: Rc<RefCell<Runtime>>,
}

impl Default for LocalTranscriber {
    fn default() -> Self {
        LocalTranscriber {
            base: QtObject::default(),
            program: Atom::from(""),
            arguments: Vec::new(),
            running: false,
            status: Atom::from("idle"),
            error: Atom::from(""),
            state: Rc::default(),
        }
    }
}

#[qml_impl]
impl LocalTranscriber {
    #[qml(signal)]
    fn configuration_changed();
    #[qml(signal)]
    fn state_changed();
    #[qml(signal)]
    fn transcript_ready(text: Atom);

    #[qml(on_complete)]
    fn completed(cx: &Cx) -> Result<(), EngineError> {
        let (e, me) = (cx.engine, cx.this);
        let hub = Hub::of(e);
        let id = hub.next.get() + 1;
        hub.next.set(id);
        let state = e.with::<LocalTranscriber, _>(me, |t| t.state.clone())?;
        state.borrow_mut().id = id;
        hub.transcribers
            .borrow_mut()
            .insert(id, (me, Rc::downgrade(&state)));
        for property in [Self::PROGRAM.index, Self::ARGUMENTS.index] {
            e.watch(me, property, move |e, _| {
                let _ = e.emit_by_name(me, "configurationChanged", &[]);
            })?;
        }
        Ok(())
    }

    /// Starts a run; false when one is going or `program` is not an
    /// executable file (`error` says so).
    #[qml(invokable)]
    fn start(cx: &Cx) -> bool {
        let (e, me) = (cx.engine, cx.this);
        let Some((program, arguments)) = configuration(e, me) else {
            return false;
        };
        let executable = is_executable(&program);
        let Some(state) = state_of(e, me) else {
            return false;
        };
        {
            let mut rt = state.borrow_mut();
            rt.program = program;
            rt.arguments = arguments;
        }
        let started = state.borrow_mut().machine.start(executable);
        apply(e, me, &state);
        started
    }

    /// The speaker is done: the helper transcribes what it recorded.
    #[qml(invokable)]
    fn finish_recording(cx: &Cx) {
        step(cx.engine, cx.this, |m| m.finish_recording());
    }

    /// Stops the run; nothing it said is delivered.
    #[qml(invokable)]
    fn cancel(cx: &Cx) {
        step(cx.engine, cx.this, |m| m.cancel());
    }
}

/// Everything a transcriber keeps beside its properties.
#[derive(Default)]
struct Runtime {
    id: u64,
    machine: Machine,
    program: String,
    arguments: Vec<String>,
    process: Option<Process>,
    timer: Option<crate::schedule::Schedule>,
    /// Which spawn the process's events are for: an earlier run's are late.
    run: u64,
    /// The `running` and `status` the properties show.
    shown: Option<(bool, &'static str)>,
}

fn state_of(engine: &Engine, obj: ObjectId) -> Option<Rc<RefCell<Runtime>>> {
    engine
        .with::<LocalTranscriber, _>(obj, |t| t.state.clone())
        .ok()
}

/// `program` and `arguments` as written.
fn configuration(engine: &Engine, obj: ObjectId) -> Option<(String, Vec<String>)> {
    let (program, arguments) = engine
        .with::<LocalTranscriber, _>(obj, |t| (t.program.to_string(), t.arguments.clone()))
        .ok()?;
    Some((program, arguments))
}

/// QFileInfo's test: an absolute path to an executable file.
fn is_executable(program: &str) -> bool {
    let path = Path::new(program);
    if !path.is_absolute() || !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    true
}

/// Lets `f` tell the machine something, then does what it asked.
fn step(engine: &Engine, obj: ObjectId, f: impl FnOnce(&mut Machine)) {
    if let Some(state) = state_of(engine, obj) {
        f(&mut state.borrow_mut().machine);
        apply(engine, obj, &state);
    }
}

/// Carries out what the machine asked of the process and the timer, then
/// shows what it ended up as. Spawning can tell the machine more, which can
/// ask for more.
fn apply(engine: &Engine, obj: ObjectId, state: &Rc<RefCell<Runtime>>) {
    let mut ready = Vec::new();
    loop {
        let effects = state.borrow_mut().machine.take();
        if effects.is_empty() {
            break;
        }
        for effect in effects {
            match effect {
                Effect::Spawn => spawn(engine, state),
                Effect::WriteStop => {
                    if let Some(process) = &mut state.borrow_mut().process {
                        process.write_stop();
                    }
                }
                Effect::SignalGroup { pgid, force } => signal_group(pgid, force),
                Effect::SignalProcess { force } => {
                    if let Some(process) = &state.borrow().process {
                        process.signal(force);
                    }
                }
                Effect::StartKillTimer => {
                    stop_timer(engine, state);
                    let at = engine.now() + Duration::from_millis(KILL_AFTER_MS);
                    let timer =
                        crate::schedule::at(engine, "transcriber kill", None, at, move |engine| {
                            if let Some(state) = state_of(engine, obj) {
                                state.borrow_mut().timer = None;
                                step(engine, obj, |m| m.kill_timer_fired());
                            }
                        });
                    state.borrow_mut().timer = Some(timer);
                }
                Effect::StopKillTimer => stop_timer(engine, state),
                Effect::Ready(text) => ready.push(text),
            }
        }
    }
    show(engine, obj, state);
    for text in ready {
        let _ = engine.emit_by_name(obj, "transcriptReady", &[Value::String(Atom::from(&*text))]);
    }
}

fn stop_timer(engine: &Engine, state: &Rc<RefCell<Runtime>>) {
    let timer = state.borrow_mut().timer.take();
    if let Some(timer) = timer {
        timer.cancel(engine);
    }
}

/// Runs the helper, and tells the machine how that went.
fn spawn(engine: &Engine, state: &Rc<RefCell<Runtime>>) {
    let (id, run, program, arguments) = {
        let mut rt = state.borrow_mut();
        rt.run += 1;
        (rt.id, rt.run, rt.program.clone(), rt.arguments.clone())
    };
    let Some(shared) = Hub::of(engine).shared.borrow().clone() else {
        state
            .borrow_mut()
            .machine
            .failed_to_start("the shell has no stream for the helper's output");
        return;
    };
    match Process::spawn(&program, &arguments, shared, id, run) {
        Ok(process) => {
            let pid = i64::from(process.pid);
            let mut rt = state.borrow_mut();
            rt.process = Some(process);
            rt.machine.started(pid);
        }
        Err(e) => state.borrow_mut().machine.failed_to_start(&e.to_string()),
    }
}

/// Makes the properties what the machine says, and says when the state
/// changed.
fn show(engine: &Engine, obj: ObjectId, state: &Rc<RefCell<Runtime>>) {
    let (running, status, error) = {
        let rt = state.borrow();
        (
            rt.machine.running(),
            rt.machine.status(),
            rt.machine.error().to_owned(),
        )
    };
    let before = state.borrow_mut().shown.replace((running, status));
    let changed = before.unwrap_or((false, "idle")) != (running, status);
    engine.batch(|| {
        let _ = engine.set_internal(obj, LocalTranscriber::RUNNING, running);
        let _ = engine.set_internal(obj, LocalTranscriber::STATUS, Atom::from(status));
        let _ = engine.set_internal(obj, LocalTranscriber::ERROR, Atom::from(&*error));
    });
    if changed {
        let _ = engine.emit_by_name(obj, "stateChanged", &[]);
    }
}

/// What the helper's threads hand the Engine thread: a transcriber's id,
/// its run, and what happened.
type Shared = Feed<(u64, u64, Event)>;

enum Event {
    Stdout(Vec<u8>),
    Stderr(Vec<u8>),
    Finished { code: i32, normal: bool },
}

/// A transcriber's object and what it keeps, by its id.
type Entry = (ObjectId, Weak<RefCell<Runtime>>);

/// The engine's transcribers, and the stream their helpers share.
#[derive(Default)]
struct Hub {
    shared: RefCell<Option<Shared>>,
    transcribers: RefCell<HashMap<u64, Entry>>,
    next: Cell<u64>,
}

impl Hub {
    fn of(engine: &Engine) -> Rc<Hub> {
        engine.extension::<Hub>()
    }
}

/// Makes the "local-transcriber" stream the helpers started from now on
/// feed.
pub fn wire(engine: &Engine, wire: &mut impl Wire) {
    let feed = Feed::new(wire, "local-transcriber", CAPACITY, |engine, run| {
        deliver(engine, run)
    });
    *Hub::of(engine).shared.borrow_mut() = Some(feed);
}

/// Hands each transcriber what its helper wrote and how it ended. On the
/// Engine thread.
fn deliver(engine: &Engine, events: impl Iterator<Item = (u64, u64, Event)>) {
    let hub = Hub::of(engine);
    for (id, run, event) in events {
        let found = hub.transcribers.borrow().get(&id).cloned();
        let Some((obj, state)) = found else { continue };
        let Some(state) = state.upgrade().filter(|_| engine.is_alive(obj)) else {
            hub.transcribers.borrow_mut().remove(&id);
            continue;
        };
        // A helper of an earlier run, or one that has finished, says no more.
        if state.borrow().run != run || state.borrow().process.is_none() {
            continue;
        }
        let finished = matches!(event, Event::Finished { .. });
        step(engine, obj, |m| match &event {
            Event::Stdout(bytes) => m.stdout(bytes),
            Event::Stderr(bytes) => m.stderr(bytes),
            Event::Finished { code, normal } => m.finished(*code, *normal),
        });
        if finished {
            state.borrow_mut().process = None;
        }
    }
}

/// The helper: its pid, and its stdin.
struct Process {
    pid: u32,
    stdin: Option<ChildStdin>,
    /// Set by the thread that waits for the helper, for the destructor.
    exited: Arc<(Mutex<bool>, Condvar)>,
}

impl Process {
    /// Starts `program` in a session of its own, with threads for its
    /// output and one for its end. Output comes before the end: a helper's
    /// group is killed when it exits, which closes the pipes it shared with
    /// anything it left behind.
    fn spawn(
        program: &str,
        arguments: &[String],
        shared: Shared,
        id: u64,
        run: u64,
    ) -> std::io::Result<Process> {
        let mut command = Command::new(program);
        command
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            // SAFETY: setsid is async-signal-safe and touches nothing of
            // this process's memory.
            unsafe {
                command.pre_exec(|| {
                    libc::setsid();
                    Ok(())
                });
            }
        }
        let mut child = command.spawn()?;
        let pid = child.id();
        let stdin = child.stdin.take();
        let (done, drained) = mpsc::channel();
        // Readers waiting for the UI to take what they read, not for the
        // pipe: those are waited for however long the UI takes.
        let handing = Arc::new(AtomicUsize::new(0));
        let reader = Reader {
            shared: shared.clone(),
            id,
            run,
            done,
            handing: handing.clone(),
        };
        if let Some(out) = child.stdout.take() {
            reader.clone().read(out, Event::Stdout);
        }
        if let Some(err) = child.stderr.take() {
            reader.read(err, Event::Stderr);
        }
        let exited = Arc::new((Mutex::new(false), Condvar::new()));
        let flag = exited.clone();
        std::thread::spawn(move || {
            let status = child.wait().ok();
            // Whatever the helper left behind goes with it, as the end of a
            // QProcess does; its pipes then close.
            signal_group(i64::from(pid), true);
            // The readers end with the pipes. One that does not (something
            // out of the group holds it) is not waited for; one handing
            // output to the UI is, so the end comes after all of it.
            loop {
                match drained.recv_timeout(Duration::from_secs(1)) {
                    Ok(()) => {}
                    Err(mpsc::RecvTimeoutError::Timeout) if handing.load(Ordering::Acquire) > 0 => {
                    }
                    Err(_) => break,
                }
            }
            // A helper a signal ended has no code: not a normal exit.
            let code = status.and_then(|s| s.code());
            let (lock, cv) = &*flag;
            *lock.lock().unwrap_or_else(PoisonError::into_inner) = true;
            cv.notify_all();
            let finished = Event::Finished {
                code: code.unwrap_or(0),
                normal: code.is_some(),
            };
            // Refused only once the UI is gone, and nobody hears it then.
            let _ = shared.send((id, run, finished));
        });
        Ok(Process { pid, stdin, exited })
    }

    fn write_stop(&mut self) {
        if let Some(stdin) = &mut self.stdin {
            let _ = stdin.write_all(b"stop\n").and_then(|_| stdin.flush());
        }
    }

    /// Signals the helper alone: SIGKILL when `force`, else SIGTERM.
    fn signal(&self, force: bool) {
        signal_pid(i64::from(self.pid), force);
    }

    fn has_exited(&self) -> bool {
        *self.exited.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Drop for Process {
    /// ~LocalTranscriber: asks the helper to stop, kills it a second later,
    /// and leaves nothing of its group. The second is waited out on a
    /// thread of its own: the one dropping it is the UI's.
    fn drop(&mut self) {
        let pid = i64::from(self.pid);
        if self.has_exited() {
            signal_group(pid, true);
            return;
        }
        signal_group(pid, false);
        let exited = self.exited.clone();
        std::thread::spawn(move || {
            let (lock, cv) = &*exited;
            let (exited, _) = cv
                .wait_timeout_while(
                    lock.lock().unwrap_or_else(PoisonError::into_inner),
                    Duration::from_millis(KILL_AFTER_MS),
                    |exited| !*exited,
                )
                .unwrap_or_else(PoisonError::into_inner);
            drop(exited);
            signal_group(pid, true);
        });
    }
}

/// What a thread reading one of the helper's pipes hands its chunks to.
#[derive(Clone)]
struct Reader {
    shared: Shared,
    id: u64,
    run: u64,
    /// Dropped when the reader ends.
    done: mpsc::Sender<()>,
    handing: Arc<AtomicUsize>,
}

impl Reader {
    /// Reads `pipe` to its end, handing each chunk over as `event` of the
    /// run. The UI gone, it stops reading.
    fn read(self, mut pipe: impl Read + Send + 'static, event: fn(Vec<u8>) -> Event) {
        std::thread::spawn(move || {
            let mut buffer = vec![0; 64 * 1024];
            while let Ok(n) = pipe.read(&mut buffer) {
                if n == 0 {
                    break;
                }
                self.handing.fetch_add(1, Ordering::AcqRel);
                let sent = self
                    .shared
                    .send((self.id, self.run, event(buffer[..n].to_vec())));
                self.handing.fetch_sub(1, Ordering::AcqRel);
                if sent.is_err() {
                    break;
                }
            }
            drop(self.done);
        });
    }
}

#[cfg(unix)]
fn signal_pid(pid: i64, force: bool) {
    // SAFETY: kill only sends a signal.
    unsafe {
        libc::kill(
            pid as libc::pid_t,
            if force { libc::SIGKILL } else { libc::SIGTERM },
        );
    }
}

/// Signals every process of the helper's group.
#[cfg(unix)]
fn signal_group(pgid: i64, force: bool) {
    signal_pid(-pgid, force);
}

// Not Windows: the helper's group is Unix's, and a signal is
// not sent there. The desktop-ljos shell is built for Linux and macOS.
#[cfg(not(unix))]
fn signal_pid(_: i64, _: bool) {}

#[cfg(not(unix))]
fn signal_group(_: i64, _: bool) {}
