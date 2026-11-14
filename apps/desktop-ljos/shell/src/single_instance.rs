//! One running shell per HAL-C2 home, desktop-qt's SingleInstance. A later
//! launch (`hal-c2-ljos ~/code/api`) hands the folders it names to the shell
//! already running and exits, so no second MC starts on the same home. The
//! channel is a local socket named after the home's state directory: a socket
//! file in the runtime directory (`$XDG_RUNTIME_DIR/hal-c2`, else the state
//! directory itself) on Linux and macOS, a namespaced pipe on Windows.
//!
//! The running shell answers on socket threads, never on the engine's:
//! `listen`'s `open` is called off the UI thread and is meant to post the
//! folders to the shell's inbox, not to touch controllers.
//!
//! The socket's name is its own (`hal-c2-ljos-…`), so a Qt desktop and this
//! shell on one home do not see each other.

use interprocess::local_socket::{
    GenericFilePath, GenericNamespaced, ListenerOptions, Name, Stream, prelude::*,
};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::JoinHandle;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(1);

/// Short and unique per home: socket paths are length-limited. FNV-1a over the
/// state directory's path, 64 bits, which a name only has to tell homes apart.
fn server_name(state_dir: &Path) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in state_dir.to_string_lossy().bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("hal-c2-ljos-{hash:016x}")
}

/// Where the shell on this home listens: the socket file's path, or the bare
/// name of the Windows pipe (and of a socket whose path would be too long for
/// one, which then lives in the temporary directory). `runtime_dir` is
/// `$XDG_RUNTIME_DIR`; only an absolute one counts, as for the other XDG
/// variables.
pub fn address(state_dir: &Path, runtime_dir: Option<&str>, windows: bool) -> String {
    let name = server_name(state_dir);
    if windows {
        return name;
    }
    let dir = match runtime_dir
        .map(str::trim)
        .filter(|d| Path::new(d).is_absolute())
    {
        Some(runtime) => Path::new(runtime).join("hal-c2"),
        None => state_dir.to_path_buf(),
    };
    let path = dir.join(&name).to_string_lossy().into_owned();
    // sockaddr_un holds about a hundred bytes.
    if path.len() < 100 {
        path
    } else {
        std::env::temp_dir()
            .join(name)
            .to_string_lossy()
            .into_owned()
    }
}

/// [`address`] for the running process.
pub fn address_here(state_dir: &Path) -> String {
    address(
        state_dir,
        std::env::var("XDG_RUNTIME_DIR").ok().as_deref(),
        cfg!(windows),
    )
}

fn name_of(address: &str) -> std::io::Result<Name<'_>> {
    if cfg!(windows) {
        address.to_ns_name::<GenericNamespaced>()
    } else {
        address.to_fs_name::<GenericFilePath>()
    }
}

/// The later launch: hands `folders` to the shell already running on this
/// home. False when none is, and the caller starts up as usual.
pub fn forward(state_dir: &Path, folders: &[String]) -> bool {
    forward_at(address_here(state_dir), folders)
}

fn forward_at(address: String, folders: &[String]) -> bool {
    let line = format!("{}\n", serde_json::json!({ "open": folders }));
    // The socket calls block, so a hung peer is waited on by a thread.
    let (done, answer) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = done.send(ask(&address, &line));
    });
    answer.recv_timeout(TIMEOUT).unwrap_or(false)
}

fn ask(address: &str, line: &str) -> bool {
    let Ok(name) = name_of(address) else {
        return false;
    };
    let Ok(stream) = Stream::connect(name) else {
        return false;
    };
    let mut stream = BufReader::new(stream);
    if stream.get_mut().write_all(line.as_bytes()).is_err() {
        return false;
    }
    let mut reply = String::new();
    // The running shell answers once it has the line.
    stream.read_line(&mut reply).is_ok() && reply.trim() == "ok"
}

/// The running shell's end: listens for later launches until dropped, then
/// removes its socket.
pub struct Listener {
    address: String,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

/// Listens on this home for later launches; `open` gets the folders each
/// names, on a socket thread. None when a shell already listens on the home
/// (a launch that names no folder never asked it: that shell keeps its
/// socket, and this one has none) or when the socket cannot be made.
pub fn listen(
    state_dir: &Path,
    open: impl Fn(Vec<String>) + Send + Sync + 'static,
) -> Option<Listener> {
    listen_at(address_here(state_dir), open)
}

fn listen_at(
    address: String,
    open: impl Fn(Vec<String>) + Send + Sync + 'static,
) -> Option<Listener> {
    // A socket left by a run that crashed is in the way and is removed. One
    // that still takes connections belongs to a running shell.
    if Stream::connect(name_of(&address).ok()?).is_ok() {
        return None;
    }
    if !cfg!(windows) {
        let path = PathBuf::from(&address);
        let _ = std::fs::remove_file(&path);
        std::fs::create_dir_all(path.parent()?).ok()?;
    }
    let listener = ListenerOptions::new()
        .name(name_of(&address).ok()?)
        .create_sync()
        .ok()?;
    let stop = Arc::new(AtomicBool::new(false));
    let open = Arc::new(open);
    let thread = {
        let stop = stop.clone();
        std::thread::spawn(move || {
            for connection in listener.incoming() {
                if stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(connection) = connection else { continue };
                let open = open.clone();
                std::thread::spawn(move || serve(connection, &*open));
            }
        })
    };
    Some(Listener {
        address,
        stop,
        thread: Some(thread),
    })
}

/// One later launch: its line of `{"open": [...]}`, answered `ok` before the
/// folders are handed over.
fn serve(connection: Stream, open: &dyn Fn(Vec<String>)) {
    let mut connection = BufReader::new(connection);
    let mut line = String::new();
    if connection.read_line(&mut line).unwrap_or(0) == 0 {
        return;
    }
    let folders = serde_json::from_str::<serde_json::Value>(&line)
        .ok()
        .and_then(|v| {
            v.get("open")?.as_array().map(|folders| {
                folders
                    .iter()
                    .map(|f| f.as_str().unwrap_or_default().to_owned())
                    .collect::<Vec<_>>()
            })
        })
        .unwrap_or_default();
    let stream = connection.get_mut();
    if stream
        .write_all(b"ok\n")
        .and_then(|_| stream.flush())
        .is_ok()
    {
        open(folders);
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // A connection wakes the thread blocked in accept so it sees the flag.
        if let Ok(name) = name_of(&self.address) {
            let _ = Stream::connect(name);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        if !cfg!(windows) {
            let _ = std::fs::remove_file(&self.address);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "hal-c2-single-instance-{}-{tag}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_address_is_named_after_the_home() {
        let a = address(Path::new("/home/me/.local/state/hal-c2"), None, false);
        let b = address(Path::new("/home/me/.local/state/hal-c2-dev"), None, false);
        assert_ne!(a, b);
        assert!(
            a.starts_with("/home/me/.local/state/hal-c2/hal-c2-ljos-"),
            "{a}"
        );
        assert_eq!(
            a,
            address(Path::new("/home/me/.local/state/hal-c2"), None, false)
        );
    }

    #[test]
    fn an_absolute_runtime_directory_holds_the_socket() {
        let state = Path::new("/home/me/.local/state/hal-c2");
        let a = address(state, Some(" /run/user/1000 "), false);
        assert!(a.starts_with("/run/user/1000/hal-c2/hal-c2-ljos-"), "{a}");
        // A relative one is ignored.
        let b = address(state, Some("run"), false);
        assert!(b.starts_with("/home/me/.local/state/hal-c2/"), "{b}");
    }

    #[test]
    fn windows_and_too_long_paths_use_the_bare_name() {
        let state = Path::new("C:/Users/me/AppData/Local/hal-c2/state");
        let name = address(state, Some("/run/user/1000"), true);
        assert!(
            name.starts_with("hal-c2-ljos-") && !name.contains('/'),
            "{name}"
        );
        let long = PathBuf::from(format!("/{}", "x".repeat(120)));
        let a = address(&long, None, false);
        // In the temporary directory, however long its own path is.
        assert_eq!(
            Path::new(&a),
            std::env::temp_dir().join(name_suffix(&a)),
            "{a}"
        );
        assert!(name_suffix(&a).starts_with("hal-c2-ljos-"), "{a}");
    }

    fn name_suffix(address: &str) -> String {
        address.rsplit('/').next().unwrap().to_owned()
    }

    #[cfg(unix)]
    #[test]
    fn a_later_launch_hands_its_folders_to_the_running_one() {
        let state = scratch("handoff");
        let address = address(&state, None, false);
        let seen = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
        let (told, heard) = mpsc::channel();
        let listener = {
            let seen = seen.clone();
            listen_at(address.clone(), move |folders| {
                seen.lock().unwrap().push(folders);
                told.send(()).unwrap();
            })
        }
        .expect("listens");

        // A second instance on the home finds the first and does not listen.
        assert!(listen_at(address.clone(), |_| {}).is_none());
        assert!(forward_at(
            address.clone(),
            &["/code/api".into(), "/code/web".into()]
        ));
        heard.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(*seen.lock().unwrap(), [vec!["/code/api", "/code/web"]]);

        drop(listener);
        // Once the first is gone nothing answers, and the socket is cleared.
        assert!(!forward_at(address.clone(), &[]));
        assert!(!Path::new(&address).exists());
        let _ = std::fs::remove_dir_all(&state);
    }

    #[cfg(unix)]
    #[test]
    fn a_socket_left_by_a_crashed_run_is_replaced() {
        let state = scratch("stale");
        let address = address(&state, None, false);
        // A file where the socket goes, as a killed run leaves behind.
        std::fs::write(&address, b"").unwrap();
        assert!(!forward_at(address.clone(), &[]));
        let listener = listen_at(address.clone(), |_| {}).expect("replaces the stale socket");
        assert!(forward_at(address.clone(), &[]));
        drop(listener);
        let _ = std::fs::remove_dir_all(&state);
    }
}
