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
//! The helper's pipes are read on threads of their own. What they see queues
//! here with the transcriber it is for, and the shell hears of it through
//! the waker ([`set_wake`]): it then calls [`deliver`] on the Engine thread.
//! A headless host (a test) waits on its own waker instead.
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
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::Duration;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ObjectId, QmlObject, QtObject, Value, qml_impl,
};
use ljos_runtime::TimerId;

pub use machine::{Effect, KILL_AFTER_MS, Machine};

use crate::json::{self, Json};

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
    arguments: Value,
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
            arguments: Value::Undefined,
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
    timer: Option<TimerId>,
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
    let arguments = match json::from_value(engine, &arguments) {
        Json::Array(items) => items
            .iter()
            .map(|item| match item {
                Json::String(s) => s.clone(),
                other => other.to_string(),
            })
            .collect(),
        _ => Vec::new(),
    };
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
                    let timer = engine.call_at(at, move |engine| {
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
        engine.cancel_call(timer);
    }
}

/// Runs the helper, and tells the machine how that went.
fn spawn(engine: &Engine, state: &Rc<RefCell<Runtime>>) {
    let (id, run, program, arguments) = {
        let mut rt = state.borrow_mut();
        rt.run += 1;
        (rt.id, rt.run, rt.program.clone(), rt.arguments.clone())
    };
    let shared = Hub::of(engine).shared.clone();
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

/// What the helper's threads leave for the Engine thread.
#[derive(Default)]
struct Shared {
    events: Mutex<Vec<(u64, u64, Event)>>,
    wake: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

enum Event {
    Stdout(Vec<u8>),
    Stderr(Vec<u8>),
    Finished { code: i32, normal: bool },
}

impl Shared {
    fn push(&self, id: u64, run: u64, event: Event) {
        self.events
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((id, run, event));
        let wake = self
            .wake
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(wake) = wake {
            wake();
        }
    }
}

/// A transcriber's object and what it keeps, by its id.
type Entry = (ObjectId, Weak<RefCell<Runtime>>);

/// The engine's transcribers, and the queue their helpers share.
#[derive(Default)]
struct Hub {
    shared: Arc<Shared>,
    transcribers: RefCell<HashMap<u64, Entry>>,
    next: Cell<u64>,
}

impl Hub {
    fn of(engine: &Engine) -> Rc<Hub> {
        engine.extension::<Hub>()
    }
}

/// Says what to run, on any thread, when [`deliver`] has something to do:
/// post a message to the Engine thread, which calls [`deliver`].
pub fn set_wake(engine: &Engine, wake: impl Fn() + Send + Sync + 'static) {
    *Hub::of(engine)
        .shared
        .wake
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(wake));
}

/// Hands each transcriber what its helper wrote and how it ended. On the
/// Engine thread.
pub fn deliver(engine: &Engine) {
    let hub = Hub::of(engine);
    let events = std::mem::take(
        &mut *hub
            .shared
            .events
            .lock()
            .unwrap_or_else(PoisonError::into_inner),
    );
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
        shared: Arc<Shared>,
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
        if let Some(out) = child.stdout.take() {
            read_pipe(out, shared.clone(), id, run, Event::Stdout, done.clone());
        }
        if let Some(err) = child.stderr.take() {
            read_pipe(err, shared.clone(), id, run, Event::Stderr, done.clone());
        }
        drop(done);
        let exited = Arc::new((Mutex::new(false), Condvar::new()));
        let flag = exited.clone();
        std::thread::spawn(move || {
            let status = child.wait().ok();
            // Whatever the helper left behind goes with it, as the end of a
            // QProcess does; its pipes then close.
            signal_group(i64::from(pid), true);
            // The readers end with the pipes. One that does not (something
            // out of the group holds it) is not waited for.
            while drained.recv_timeout(Duration::from_secs(1)).is_ok() {}
            // A helper a signal ended has no code: not a normal exit.
            let code = status.and_then(|s| s.code());
            let (lock, cv) = &*flag;
            *lock.lock().unwrap_or_else(PoisonError::into_inner) = true;
            cv.notify_all();
            shared.push(
                id,
                run,
                Event::Finished {
                    code: code.unwrap_or(0),
                    normal: code.is_some(),
                },
            );
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
    /// and leaves nothing of its group.
    fn drop(&mut self) {
        if !self.has_exited() {
            signal_group(i64::from(self.pid), false);
            let (lock, cv) = &*self.exited;
            let (exited, _) = cv
                .wait_timeout_while(
                    lock.lock().unwrap_or_else(PoisonError::into_inner),
                    Duration::from_millis(KILL_AFTER_MS),
                    |exited| !*exited,
                )
                .unwrap_or_else(PoisonError::into_inner);
            drop(exited);
        }
        signal_group(i64::from(self.pid), true);
    }
}

/// Reads `pipe` to its end, handing each chunk over as `event` of the run.
fn read_pipe(
    mut pipe: impl Read + Send + 'static,
    shared: Arc<Shared>,
    id: u64,
    run: u64,
    event: fn(Vec<u8>) -> Event,
    done: mpsc::Sender<()>,
) {
    std::thread::spawn(move || {
        let mut buffer = vec![0; 64 * 1024];
        while let Ok(n) = pipe.read(&mut buffer) {
            if n == 0 {
                break;
            }
            shared.push(id, run, event(buffer[..n].to_vec()));
        }
        let _ = done.send(());
    });
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

// TODO(ljos#?): not Windows: the helper's group is Unix's, and a signal is
// not sent there. The desktop-ljos shell is built for Linux and macOS.
#[cfg(not(unix))]
fn signal_pid(_: i64, _: bool) {}

#[cfg(not(unix))]
fn signal_group(_: i64, _: bool) {}
