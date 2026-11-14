//! The desktop host desktop-qt runs (`apps/desktop-qt/host/main.ts`), run
//! the same way: desktop-qt's BackendProcess. The host finds or starts the
//! MC on this machine (or pairs with the one `--attach` names), waits until
//! it answers, and says so in one JSON line a message on its stdout:
//!
//! - `{"type":"ready","mc":{"origin":…,"token":…}}`: the MC to connect to;
//! - `{"type":"error","message":…}`: why it could not.
//!
//! Anything else it prints, and all of its stderr, is logged as `[host]`.
//! Closing its stdin tells it its parent is going; it stops the MC it
//! started itself (`stop`).
//!
//! What the host says arrives on its reader threads; `events` is meant to
//! post it to the shell's inbox, not to touch the engine.

use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How the host is run: `node <entry> <arguments>`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Options {
    pub node: PathBuf,
    pub entry: PathBuf,
    pub arguments: Vec<String>,
}

/// What the host told the shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// The MC answers here, with this token.
    Ready { origin: String, token: String },
    /// The host could not give the shell an MC, or stopped giving it one.
    Failed(String),
}

/// One line of the host's stdout.
#[derive(Debug, PartialEq, Eq)]
enum Line {
    Ready {
        origin: String,
        token: String,
    },
    Error(String),
    /// JSON of another type, which the shell does not act on.
    Other,
    /// Not JSON: the host's own log.
    Log,
}

fn read_line(line: &str) -> Line {
    let Ok(serde_json::Value::Object(message)) = serde_json::from_str(line) else {
        return Line::Log;
    };
    let text = |v: Option<&serde_json::Value>| {
        v.and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    match message.get("type").and_then(serde_json::Value::as_str) {
        Some("ready") => {
            let mc = message.get("mc");
            Line::Ready {
                origin: text(mc.and_then(|m| m.get("origin"))),
                token: text(mc.and_then(|m| m.get("token"))),
            }
        }
        Some("error") => Line::Error(text(message.get("message"))),
        _ => Line::Other,
    }
}

/// What the host has said so far, as BackendProcess keeps it.
#[derive(Default)]
struct Said {
    /// It announced an MC; a later `ready` is not another.
    announced: bool,
    /// It said why it failed; its exit says nothing more.
    reported: bool,
    /// The shell stopped it; its exit is no failure.
    stopping: bool,
}

impl Said {
    /// What `line` tells the shell, if anything.
    fn hear(&mut self, line: Line) -> Option<Event> {
        match line {
            Line::Ready { origin, token } if !self.announced => {
                self.announced = true;
                if origin.is_empty() || token.is_empty() {
                    self.reported = true;
                    return Some(Event::Failed(
                        "Desktop host announced no MC to connect to.".into(),
                    ));
                }
                Some(Event::Ready { origin, token })
            }
            Line::Error(message) => {
                self.reported = true;
                Some(Event::Failed(message))
            }
            Line::Ready { .. } | Line::Other | Line::Log => None,
        }
    }

    /// What the host's exit tells the shell: nothing when it was stopped or
    /// said why already.
    fn exited(&self, code: i32, crashed: bool) -> Option<Event> {
        if self.stopping || self.reported {
            return None;
        }
        let how = if crashed { "crashed" } else { "normal exit" };
        // A host that dies after announcing took the MC it started with it;
        // say so instead of letting the shell reconnect forever.
        Some(Event::Failed(if self.announced {
            format!("Desktop host exited (code {code}, {how}). Restart HAL-C2 to reconnect.")
        } else {
            format!("Desktop host exited before it was ready (code {code}, {how}).")
        }))
    }
}

type Events = Arc<dyn Fn(Event) + Send + Sync>;

/// The host process, once [`DesktopHost::start`]ed.
pub struct DesktopHost {
    options: Options,
    events: Events,
    state: Arc<Mutex<State>>,
}

#[derive(Default)]
struct State {
    said: Said,
    child: Option<Child>,
    /// Which `start` the running host is; a stopped one's reader thread
    /// hears nothing more of the next.
    run: u64,
}

impl DesktopHost {
    pub fn new(options: Options, events: impl Fn(Event) + Send + Sync + 'static) -> DesktopHost {
        DesktopHost {
            options,
            events: Arc::new(events),
            state: Arc::default(),
        }
    }

    /// Runs the host. A host that cannot be run is a failure.
    pub fn start(&self) {
        let spawned = Command::new(&self.options.node)
            .arg(&self.options.entry)
            .args(&self.options.arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(e) => {
                (self.events)(Event::Failed(format!(
                    "Could not start {} {}: {e}",
                    self.options.node.display(),
                    self.options.entry.display()
                )));
                return;
            }
        };
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let run = {
            // A host started again (the updater's, after a failed install)
            // is a new one: its `ready` attaches and its exit is reported.
            let mut state = self.state.lock().unwrap();
            state.said = Said::default();
            state.child = Some(child);
            state.run += 1;
            state.run
        };
        if let Some(stderr) = stderr {
            std::thread::spawn(move || log_lines(stderr));
        }
        let Some(stdout) = stdout else { return };
        let state = self.state.clone();
        let events = self.events.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let read = read_line(line);
                if read == Line::Log {
                    eprintln!("[host] {line}");
                }
                let event = {
                    let mut state = state.lock().unwrap();
                    if state.run != run {
                        return;
                    }
                    state.said.hear(read)
                };
                if let Some(event) = event {
                    events(event);
                }
            }
            // Its stdout closed: it is going. One `stop` took is stop's.
            let child = {
                let mut state = state.lock().unwrap();
                if state.run != run {
                    return;
                }
                state.child.take()
            };
            let Some(mut child) = child else { return };
            let status = child.wait();
            let event = match status {
                Ok(status) => {
                    let (code, crashed) = exit_of(status);
                    state.lock().unwrap().said.exited(code, crashed)
                }
                Err(_) => state.lock().unwrap().said.exited(-1, true),
            };
            if let Some(event) = event {
                events(event);
            }
        });
    }

    /// Stops the host: closes its stdin, its sign to stop the MC it
    /// started, and asks it to end; after two seconds it is killed.
    pub fn stop(&self) {
        let child = {
            let mut state = self.state.lock().unwrap();
            state.said.stopping = true;
            state.child.take()
        };
        let Some(mut child) = child else { return };
        drop(child.stdin.take());
        terminate(&child);
        if wait_for(&mut child, Duration::from_secs(2)).is_none() {
            let _ = child.kill();
            wait_for(&mut child, Duration::from_secs(1));
        }
    }
}

/// The exit code, and whether a signal ended it (Qt's CrashExit, whose
/// code is then the signal's).
fn exit_of(status: ExitStatus) -> (i32, bool) {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return (signal, true);
        }
    }
    (status.code().unwrap_or(-1), false)
}

/// QProcess::terminate: SIGTERM, or nothing on Windows (where Qt posts
/// WM_CLOSE, which a console host ignores; the kill follows).
fn terminate(child: &Child) {
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(child.id()) {
        // SAFETY: kill with a child's own pid, which it is until it is
        // waited for, and this one is not yet.
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
    }
    #[cfg(not(unix))]
    let _ = child;
}

/// Waits up to `limit` for `child` to end.
fn wait_for(child: &mut Child, limit: Duration) -> Option<ExitStatus> {
    let deadline = Instant::now() + limit;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(20));
            }
            _ => return None,
        }
    }
}

fn log_lines(stream: impl Read) {
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { break };
        if !line.trim().is_empty() {
            eprintln!("[host] {}", line.trim());
        }
    }
}

/// Where desktop-qt's host is: HAL_C2_HOST_ENTRY's default, beside the
/// executable in a release (`share/hal-c2/host`, or the bundle's
/// `Resources/hal-c2/host` on macOS), else this checkout's.
pub fn default_entry(executable_dir: &Path, release: bool) -> PathBuf {
    if !release {
        return Path::new(env!("CARGO_MANIFEST_DIR")).join("../../desktop-qt/host/main.ts");
    }
    let installed = if cfg!(target_os = "macos") {
        "../Resources/hal-c2/host/main.ts"
    } else {
        "../share/hal-c2/host/main.ts"
    };
    executable_dir.join(installed)
}

/// The Node that runs it: HAL_C2_NODE_BIN, else the release's own beside
/// the executable, else `node` from PATH.
pub fn default_node(executable_dir: &Path, release: bool, from_env: Option<&str>) -> PathBuf {
    if let Some(node) = from_env.filter(|n| !n.is_empty()) {
        return node.into();
    }
    if !release {
        return "node".into();
    }
    let installed = if cfg!(target_os = "macos") {
        "../Resources/hal-c2/bin/node"
    } else if cfg!(windows) {
        "../share/hal-c2/bin/node.exe"
    } else {
        "../share/hal-c2/bin/node"
    };
    executable_dir.join(installed)
}

/// The third-party license manifest staged beside the host
/// (scripts/stage-runtime.mjs, or `vp run licenses` in a checkout).
pub fn licenses_beside(entry: &Path) -> PathBuf {
    entry
        .parent()
        .unwrap_or(Path::new("."))
        .join("../licenses/third-party-licenses.json")
}

/// The `--url` link as main.cpp hands it on,
/// `QUrl::fromUserInput(link).toString(QUrl::FullyEncoded)`: trimmed,
/// `http://` added when it names no scheme (a `host:port` is a host and a
/// port, not a scheme), and percent-encoded. A link that is no URL either
/// way is passed as it is, for the host to say so.
pub fn attach_link(link: &str) -> String {
    let link = link.trim();
    let prepended = url::Url::parse(&format!("http://{link}"));
    match url::Url::parse(link) {
        Ok(url) if prepended.as_ref().map_or(true, |p| p.port().is_none()) => url.into(),
        _ => prepended.map_or_else(|_| link.to_owned(), Into::into),
    }
}

/// main.cpp's host arguments: `--attach=<link>` for `--url`, `--dev` for
/// a development shell, `--base-dir=<root>` for `--home-dir`, then what
/// the command line passed that is not a folder.
pub fn arguments(
    attach: Option<&str>,
    dev: bool,
    root: Option<&Path>,
    passed: &[String],
) -> Vec<String> {
    let mut arguments = Vec::new();
    if let Some(link) = attach {
        arguments.push(format!("--attach={}", attach_link(link)));
    }
    if dev {
        arguments.push("--dev".into());
    }
    if let Some(root) = root {
        arguments.push(format!("--base-dir={}", root.display()));
    }
    arguments.extend(passed.iter().cloned());
    arguments
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_ready_line_names_the_mc_once() {
        let mut said = Said::default();
        let ready = r#"{"type":"ready","mc":{"origin":"http://127.0.0.1:3790","token":"t"}}"#;
        assert_eq!(
            said.hear(read_line(ready)),
            Some(Event::Ready {
                origin: "http://127.0.0.1:3790".into(),
                token: "t".into()
            })
        );
        assert_eq!(said.hear(read_line(ready)), None);
    }

    #[test]
    fn a_ready_line_without_an_mc_is_a_failure() {
        let mut said = Said::default();
        assert_eq!(
            said.hear(read_line(r#"{"type":"ready","mc":{"origin":""}}"#)),
            Some(Event::Failed(
                "Desktop host announced no MC to connect to.".into()
            ))
        );
        // It said why: its exit says nothing more.
        assert_eq!(said.exited(1, false), None);
    }

    #[test]
    fn an_error_line_is_the_failure_and_the_exit_adds_nothing() {
        let mut said = Said::default();
        assert_eq!(
            said.hear(read_line(r#"{"type":"error","message":"no MC release"}"#)),
            Some(Event::Failed("no MC release".into()))
        );
        assert_eq!(said.exited(1, false), None);
    }

    #[test]
    fn other_lines_are_the_hosts_log() {
        let mut said = Said::default();
        assert_eq!(read_line("[mc] listening"), Line::Log);
        assert_eq!(read_line(r#"{"type":"exit","code":0}"#), Line::Other);
        assert_eq!(said.hear(read_line("[mc] listening")), None);
    }

    #[test]
    fn an_exit_says_whether_the_mc_was_announced() {
        let said = Said::default();
        assert_eq!(
            said.exited(1, false),
            Some(Event::Failed(
                "Desktop host exited before it was ready (code 1, normal exit).".into()
            ))
        );
        let mut announced = Said::default();
        announced.hear(read_line(
            r#"{"type":"ready","mc":{"origin":"http://h","token":"t"}}"#,
        ));
        assert_eq!(
            announced.exited(9, true),
            Some(Event::Failed(
                "Desktop host exited (code 9, crashed). Restart HAL-C2 to reconnect.".into()
            ))
        );
        announced.stopping = true;
        assert_eq!(announced.exited(0, false), None);
    }

    #[test]
    fn the_arguments_are_main_cpps() {
        assert_eq!(
            arguments(
                Some("http://h/pair#token=x"),
                true,
                Some(Path::new("/scratch/home")),
                &["--verbose".into()]
            ),
            [
                "--attach=http://h/pair#token=x",
                "--dev",
                "--base-dir=/scratch/home",
                "--verbose"
            ]
        );
        assert!(arguments(None, false, None, &[]).is_empty());
    }

    #[test]
    fn the_link_is_normalized_as_qurl_from_user_input() {
        assert_eq!(
            attach_link(" http://h:3773/pair#token=x "),
            "http://h:3773/pair#token=x"
        );
        assert_eq!(
            attach_link("192.168.1.4:3773/pair#token=x"),
            "http://192.168.1.4:3773/pair#token=x"
        );
        assert_eq!(attach_link("localhost:3773"), "http://localhost:3773/");
        assert_eq!(attach_link("h.ts.net/pair"), "http://h.ts.net/pair");
        assert_eq!(
            attach_link("http://h/a b#token=x y"),
            "http://h/a%20b#token=x%20y"
        );
    }

    #[test]
    fn node_comes_from_the_environment_first() {
        let dir = Path::new("/opt/hal-c2/bin");
        assert_eq!(
            default_node(dir, true, Some("/usr/bin/node22")),
            Path::new("/usr/bin/node22")
        );
        assert_eq!(default_node(dir, false, None), Path::new("node"));
        assert_eq!(default_node(dir, false, Some("")), Path::new("node"));
    }

    #[test]
    fn the_licenses_sit_beside_the_host() {
        assert_eq!(
            licenses_beside(Path::new("/opt/share/hal-c2/host/main.ts")),
            Path::new("/opt/share/hal-c2/host/../licenses/third-party-licenses.json")
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_host_that_says_ready_then_exits_is_heard() {
        let (sent, heard) = std::sync::mpsc::channel();
        let host = DesktopHost::new(
            Options {
                node: "sh".into(),
                entry: "-c".into(),
                arguments: vec![
                    r#"echo hello; echo '{"type":"ready","mc":{"origin":"http://h","token":"t"}}'; exit 3"#
                        .into(),
                ],
            },
            move |event| {
                let _ = sent.send(event);
            },
        );
        host.start();
        let wait = Duration::from_secs(10);
        assert_eq!(
            heard.recv_timeout(wait).unwrap(),
            Event::Ready {
                origin: "http://h".into(),
                token: "t".into()
            }
        );
        assert_eq!(
            heard.recv_timeout(wait).unwrap(),
            Event::Failed(
                "Desktop host exited (code 3, normal exit). Restart HAL-C2 to reconnect.".into()
            )
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_stopped_host_ends_without_a_failure() {
        let (sent, heard) = std::sync::mpsc::channel();
        let host = DesktopHost::new(
            Options {
                node: "sh".into(),
                entry: "-c".into(),
                // Ends when its stdin closes, as the host does.
                arguments: vec!["cat >/dev/null".into()],
            },
            move |event| {
                let _ = sent.send(event);
            },
        );
        host.start();
        host.stop();
        assert!(heard.recv_timeout(Duration::from_millis(300)).is_err());
    }

    #[test]
    fn a_host_started_again_is_heard_again() {
        let (sent, heard) = std::sync::mpsc::channel();
        let host = DesktopHost::new(
            Options {
                node: "sh".into(),
                entry: "-c".into(),
                arguments: vec![
                    r#"echo '{"type":"ready","mc":{"origin":"http://h","token":"t"}}'; cat >/dev/null"#
                        .into(),
                ],
            },
            move |event| {
                let _ = sent.send(event);
            },
        );
        let ready = Event::Ready {
            origin: "http://h".into(),
            token: "t".into(),
        };
        host.start();
        assert_eq!(
            heard.recv_timeout(Duration::from_secs(5)),
            Ok(ready.clone())
        );
        host.stop();
        // The updater's restart after a failed install.
        host.start();
        assert_eq!(heard.recv_timeout(Duration::from_secs(5)), Ok(ready));
        host.stop();
        assert!(heard.recv_timeout(Duration::from_millis(300)).is_err());
    }

    #[test]
    fn a_host_that_cannot_run_says_so() {
        let (sent, heard) = std::sync::mpsc::channel();
        let host = DesktopHost::new(
            Options {
                node: "/nonexistent/node".into(),
                entry: "main.ts".into(),
                arguments: Vec::new(),
            },
            move |event| {
                let _ = sent.send(event);
            },
        );
        host.start();
        let Ok(Event::Failed(message)) = heard.try_recv() else {
            panic!("no failure");
        };
        assert!(message.starts_with("Could not start /nonexistent/node main.ts: "));
    }
}
