//! The desktop host, in process: what desktop-qt runs as a Node
//! process (`apps/desktop-qt/host/main.ts`, its BackendProcess),
//! desktop-ljos runs on a thread of its own through
//! [`crate::mc_launcher`], so no Node process finds or starts the MC.
//! The surface is the host's: [`DesktopHost::start`] looks for the MC
//! (or pairs with the one `--attach` names), [`Event`] says where it
//! answers or why there is none, and [`DesktopHost::stop`] stops the
//! MC this shell started itself — a found one keeps running.
//!
//! What the launch learns arrives on its worker thread; `events` is
//! meant to post it to the shell's inbox, not to touch the engine.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::mc_launcher::{self, Live, StartedMc};

/// How the host is run: the host arguments (`--attach`, `--dev`,
/// `--base-dir`, as main.cpp hands them on) and what a launch is
/// resolved against.
#[derive(Clone, Default)]
pub struct Options {
    pub arguments: Vec<String>,
    pub live: Option<Live>,
}

/// What the host told the shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// The MC answers here, with this token.
    Ready { origin: String, token: String },
    /// The host could not give the shell an MC, or stopped giving it one.
    Failed(String),
}

type Events = Arc<dyn Fn(Event) + Send + Sync>;

/// The host, once [`DesktopHost::start`]ed.
pub struct DesktopHost {
    options: Options,
    events: Events,
    state: Arc<Mutex<State>>,
}

#[derive(Default)]
struct State {
    /// The MC this shell started, watched until it ends or is stopped.
    mc: Option<StartedMc>,
    /// The shell stopped it; its exit is no failure.
    stopping: bool,
    /// Which `start` is running; a stopped one's worker hears nothing
    /// more of the next.
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

    /// Finds or starts the MC. A launch that cannot give the shell
    /// one is a failure.
    pub fn start(&self) {
        let run = {
            // A host started again (the updater's, after a failed
            // install) is a new one: its `ready` attaches and its
            // MC's exit is reported.
            let mut state = self.state.lock().unwrap();
            state.stopping = false;
            state.run += 1;
            state.run
        };
        let options = self.options.clone();
        let state = self.state.clone();
        let events = self.events.clone();
        std::thread::spawn(move || {
            let result = launch(&options);
            let mut watch = false;
            let event = match result {
                Ok((access, started)) => {
                    watch = started.is_some();
                    let replaced = {
                        let mut state = state.lock().unwrap();
                        if state.run != run || state.stopping {
                            // Superseded or stopped while starting:
                            // the MC just started is nobody's.
                            drop(state);
                            if let Some(mut started) = started {
                                started.stop(Duration::from_millis(1_500));
                            }
                            return;
                        }
                        if let Some(started) = started {
                            state.mc.replace(started)
                        } else {
                            None
                        }
                    };
                    if let Some(mut replaced) = replaced {
                        replaced.stop(Duration::from_millis(1_500));
                    }
                    Event::Ready {
                        origin: access.origin,
                        token: access.token,
                    }
                }
                Err(message) => Event::Failed(message),
            };
            if state.lock().unwrap().run == run {
                events(event);
                // Ready is said before the MC's end can be: the watch
                // only ever follows it.
                if watch {
                    watch_mc(run, state.clone(), events.clone());
                }
            }
        });
    }

    /// Stops the MC this shell started: SIGTERM to its process
    /// group, and a kill after the grace. A found MC is left alone.
    pub fn stop(&self) {
        let mc = {
            let mut state = self.state.lock().unwrap();
            state.stopping = true;
            state.mc.take()
        };
        if let Some(mut mc) = mc {
            mc.stop(Duration::from_secs(2));
        }
    }
}

/// One launch: the arguments read, then found, started or attached.
fn launch(options: &Options) -> Result<(mc_launcher::Access, Option<StartedMc>), String> {
    let args = mc_launcher::parse_host_args(&options.arguments)?;
    let live = options.live.clone().unwrap_or_else(|| {
        Live::process(
            bundled_mc(&executable_dir()),
            source_mc(),
            PathBuf::from("node"),
        )
    });
    match &args.attach {
        Some(url) => mc_launcher::attach(url, args.base_dir.as_deref(), &live).map(|a| (a, None)),
        None => mc_launcher::standalone(&args, &live),
    }
}

/// Reports the started MC's end, unless the shell stopped it or
/// another MC holds its files (then the shell's MC is that one, with
/// the same files' token, and it carries on).
fn watch_mc(run: u64, state: Arc<Mutex<State>>, events: Events) {
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_millis(200));
            let status = {
                let mut state = state.lock().unwrap();
                if state.run != run || state.stopping {
                    return;
                }
                match state.mc.as_mut().and_then(StartedMc::try_wait) {
                    Some(status) => {
                        state.mc.take();
                        status
                    }
                    None => continue,
                }
            };
            let code = mc_launcher::exit_code(status);
            if code == mc_launcher::HOME_IN_USE {
                return;
            }
            events(Event::Failed(format!(
                "The MC exited (code {code}, {}). Restart HAL-C2 to reconnect.",
                if status.code().is_some() {
                    "normal exit"
                } else {
                    "crashed"
                }
            )));
            return;
        }
    });
}

fn executable_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
        .unwrap_or_default()
}

/// The installed app's files beside the executable
/// (`share/hal-c2`, or the bundle's `Resources/hal-c2` on macOS),
/// where the release stages the MC, Node and the licenses
/// (mise-tasks/release/desktop-ljos).
fn share_dir(executable_dir: &Path) -> PathBuf {
    if cfg!(target_os = "macos") {
        executable_dir.join("../Resources/hal-c2")
    } else {
        executable_dir.join("../share/hal-c2")
    }
}

/// The MC release bundled with the installed app.
pub fn bundled_mc(executable_dir: &Path) -> PathBuf {
    share_dir(executable_dir).join("hal-c2-mc/bin/hal_c2")
}

/// This checkout's MC, for a shell run from source.
pub fn source_mc() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../server-ex")
}

/// The Node the MC runs its JavaScript sidecars on: HAL_C2_NODE_BIN,
/// else the release's own beside the executable, else `node` from
/// PATH. The host itself needs no Node anymore.
pub fn default_node(executable_dir: &Path, release: bool, from_env: Option<&str>) -> PathBuf {
    if let Some(node) = from_env.filter(|n| !n.is_empty()) {
        return node.into();
    }
    if !release {
        return "node".into();
    }
    share_dir(executable_dir).join(if cfg!(windows) {
        "bin/node.exe"
    } else {
        "bin/node"
    })
}

/// The third-party license manifest: staged with the release
/// (scripts/stage-runtime.mjs), or `vp run licenses`'s in a checkout.
pub fn licenses_default(executable_dir: &Path, release: bool) -> PathBuf {
    if release {
        share_dir(executable_dir).join("licenses/third-party-licenses.json")
    } else {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../desktop-qt/licenses/third-party-licenses.json")
    }
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
    use std::sync::mpsc;

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

    fn host_with(arguments: Vec<String>, live: Live) -> (DesktopHost, mpsc::Receiver<Event>) {
        let (sent, heard) = mpsc::channel();
        let host = DesktopHost::new(
            Options {
                arguments,
                live: Some(live),
            },
            move |event| {
                let _ = sent.send(event);
            },
        );
        (host, heard)
    }

    fn live_in(temp: &tempfile::TempDir, vars: Vec<(String, String)>) -> Live {
        Live {
            env: Arc::new(move |name| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())),
            user_home: temp.path().to_path_buf(),
            platform: crate::storage::Platform::Unix,
            bundled: temp.path().join("bundled/bin/hal_c2"),
            source: temp.path().join("server-ex"),
            node: "node".into(),
            timeout: Duration::from_secs(5),
        }
    }

    #[test]
    fn a_bad_host_argument_is_the_failure() {
        let temp = tempfile::tempdir().unwrap();
        let (host, heard) = host_with(vec!["--frobnicate".into()], live_in(&temp, vec![]));
        host.start();
        assert_eq!(
            heard.recv_timeout(Duration::from_secs(5)).unwrap(),
            Event::Failed("Unknown desktop host argument: --frobnicate".into())
        );
    }

    #[test]
    fn an_mc_already_running_on_the_home_is_the_ready_one() {
        // A runtime record for this (live) process, and its token, in
        // the home the launch is given: found, nothing started.
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let state = home.join("state/elixir");
        let data = home.join("data/elixir");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::create_dir_all(&data).unwrap();
        std::fs::write(
            state.join("server-runtime.json"),
            format!(
                r#"{{"origin":"http://127.0.0.1:3793","pid":{}}}"#,
                std::process::id()
            ),
        )
        .unwrap();
        std::fs::write(data.join("access-token"), "found-token\n").unwrap();
        // Where a source MC would run from, without one being started.
        let source = temp.path().join("server-ex");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("mix.exs"), "").unwrap();
        let (host, heard) = host_with(
            vec![format!("--base-dir={}", home.display())],
            live_in(&temp, vec![]),
        );
        host.start();
        assert_eq!(
            heard.recv_timeout(Duration::from_secs(10)).unwrap(),
            Event::Ready {
                origin: "http://127.0.0.1:3793".into(),
                token: "found-token".into()
            }
        );
        // Stopping leaves a found MC (this process) alone, and says
        // nothing more.
        host.stop();
        assert!(heard.recv_timeout(Duration::from_millis(300)).is_err());
    }
}
