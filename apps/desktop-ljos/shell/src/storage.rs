//! Where the shell keeps its files: desktop-qt's StoragePaths, resolved as
//! packages/shared/src/xdgDirs.ts resolves them, the same directories and
//! file names, so the two desktops are one app on a home. What the user
//! writes to change how the app looks and behaves (theme, shell, QML modules,
//! plugins, preferences) is the config home's `shell`.
//!
//!   1. `--home-dir` is one root for everything (`<root>/config`, data, state,
//!      cache);
//!   2. otherwise `HAL_C2_HOME`, unless it is relative or names an old home
//!      (`~/.hal-c2`, `~/.t3`), which only the migration reads;
//!   3. otherwise the XDG variables (only absolute values count) with the
//!      platform defaults. Linux and macOS share `~/.config`, `~/.local/share`,
//!      `~/.local/state` and `~/.cache`; Windows uses `%APPDATA%\hal-c2\config`
//!      and `%LOCALAPPDATA%\hal-c2\<kind>`.
//!
//! [`Profile::Development`] is the same XDG layout in directories named
//! `hal-c2-dev`, and does not read `HAL_C2_HOME`; `--home-dir` still gives it
//! a root.
//!
//! An earlier shell kept its files one `desktop-ljos` level down;
//! [`carry_over`] moves them up once.

use std::path::{Component, Path, PathBuf};

/// The level under each HAL-C2 directory an earlier shell kept its files in.
pub const OLD_CLIENT_DIR: &str = "desktop-ljos";

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StoragePaths {
    /// The explicit root, or none when the shell follows XDG.
    pub root: Option<PathBuf>,
    pub config: PathBuf,
    pub data: PathBuf,
    pub state: PathBuf,
    pub cache: PathBuf,
    /// The user's theme, shell, QML modules, plugins and preferences: the
    /// config home's `shell`, not this client's own level.
    pub shell: PathBuf,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Unix,
    Windows,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Profile {
    #[default]
    Installed,
    Development,
}

/// This process's home directory: `HOME` (`USERPROFILE` on
/// Windows) when set, else the account's own from the OS — the
/// passwd entry on Unix, as the Node host's `os.homedir()` and
/// the MC's `System.user_home!()` fall back — so a shell started
/// without `HOME` still resolves its files against the account's
/// home rather than relative to its working directory.
pub fn user_home() -> PathBuf {
    home_from(std::env::var_os(if cfg!(windows) {
        "USERPROFILE"
    } else {
        "HOME"
    }))
}

fn home_from(var: Option<std::ffi::OsString>) -> PathBuf {
    var.filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(passwd_home)
        .unwrap_or_default()
}

/// The account's home from its passwd entry, when the OS knows one.
#[cfg(unix)]
fn passwd_home() -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    // SAFETY: getpwuid_r writes only through the pointers given,
    // into the entry and buffer owned here; pw_dir is read before
    // either is dropped.
    unsafe {
        let mut entry: libc::passwd = std::mem::zeroed();
        let mut found = std::ptr::null_mut();
        let mut buf = vec![0u8; 4096];
        let status = libc::getpwuid_r(
            libc::getuid(),
            &mut entry,
            buf.as_mut_ptr() as *mut libc::c_char,
            buf.len(),
            &mut found,
        );
        if status != 0 || found.is_null() || entry.pw_dir.is_null() {
            return None;
        }
        let dir = std::ffi::CStr::from_ptr(entry.pw_dir).to_bytes();
        (!dir.is_empty()).then(|| PathBuf::from(std::ffi::OsStr::from_bytes(dir)))
    }
}

#[cfg(not(unix))]
fn passwd_home() -> Option<PathBuf> {
    None
}

impl StoragePaths {
    /// The paths of this process: its environment, home and platform.
    pub fn resolve(home_dir: Option<&Path>, profile: Profile) -> StoragePaths {
        let platform = if cfg!(windows) {
            Platform::Windows
        } else {
            Platform::Unix
        };
        let env = |name: &str| std::env::var(name).ok();
        resolve(home_dir, &env, &user_home(), platform, profile)
    }
}

/// [`StoragePaths::resolve`] over a given environment, for tests.
pub fn resolve(
    home_dir: Option<&Path>,
    env: &dyn Fn(&str) -> Option<String>,
    user_home: &Path,
    platform: Platform,
    profile: Profile,
) -> StoragePaths {
    if let Some(root) = home_dir.filter(|p| !p.as_os_str().is_empty()) {
        let root = if root.is_absolute() {
            root.to_path_buf()
        } else {
            std::env::current_dir().unwrap_or_default().join(root)
        };
        return under(&clean(&root));
    }
    let absolute = |name: &str| {
        env(name)
            .map(|v| v.trim().to_owned())
            .filter(|v| is_absolute(v, platform))
            .map(|v| clean(Path::new(&v)))
    };
    if profile == Profile::Installed
        && let Some(home) = absolute("HAL_C2_HOME")
        && !is_legacy_home(&home, user_home, platform)
    {
        return under(&home);
    }
    let app = match profile {
        Profile::Development => "hal-c2-dev",
        Profile::Installed => "hal-c2",
    };
    if platform == Platform::Windows {
        // Data, state and cache share %LOCALAPPDATA%, so each kind gets its
        // own folder there. An XDG variable is already a base for one kind
        // and gets no nesting.
        let app_data = absolute("APPDATA").unwrap_or_else(|| user_home.join("AppData/Roaming"));
        let local = absolute("LOCALAPPDATA").unwrap_or_else(|| user_home.join("AppData/Local"));
        let kind = |variable: &str, fallback: &Path, name: &str| match absolute(variable) {
            Some(configured) => configured.join(app),
            None => fallback.join(app).join(name),
        };
        return nested(
            None,
            [
                kind("XDG_CONFIG_HOME", &app_data, "config"),
                kind("XDG_DATA_HOME", &local, "data"),
                kind("XDG_STATE_HOME", &local, "state"),
                kind("XDG_CACHE_HOME", &local, "cache"),
            ],
        );
    }
    let kind = |variable: &str, fallback: &str| {
        absolute(variable)
            .unwrap_or_else(|| user_home.join(fallback))
            .join(app)
    };
    nested(
        None,
        [
            kind("XDG_CONFIG_HOME", ".config"),
            kind("XDG_DATA_HOME", ".local/share"),
            kind("XDG_STATE_HOME", ".local/state"),
            kind("XDG_CACHE_HOME", ".cache"),
        ],
    )
}

fn under(root: &Path) -> StoragePaths {
    nested(
        Some(root.to_path_buf()),
        ["config", "data", "state", "cache"].map(|kind| root.join(kind)),
    )
}

/// The HAL-C2 config, data, state and cache directories, and the config's
/// `shell`.
fn nested(root: Option<PathBuf>, [config, data, state, cache]: [PathBuf; 4]) -> StoragePaths {
    StoragePaths {
        root,
        shell: config.join("shell"),
        config,
        data,
        state,
        cache,
    }
}

/// Moves what an earlier shell kept one [`OLD_CLIENT_DIR`] level down into
/// the directory of its kind, as the settings' carry-over does for device
/// preferences: what desktop-qt (or anything else) already keeps there wins,
/// and only what it lacks moves. A folder both have is merged entry by entry.
/// What could not move stays where it was, and the old level goes once it is
/// empty. Run at every start; with nothing at the old level it reads one
/// missing directory per kind.
///
/// Returns each database it left split from its journal, which must not be
/// opened until a later start joins them (or someone does by hand).
///
/// One launch carries over at a time: another waits on the lock in the state
/// directory, so it never opens a database that is halfway up.
pub fn carry_over(paths: &StoragePaths) -> Vec<String> {
    let kinds = [&paths.config, &paths.data, &paths.state, &paths.cache];
    let has_old = |kind: &&PathBuf| {
        std::fs::symlink_metadata(kind.join(OLD_CLIENT_DIR)).is_ok_and(|m| m.is_dir())
    };
    if !kinds.iter().any(has_old) {
        return Vec::new();
    }
    let lock = std::fs::create_dir_all(&paths.state).and_then(|()| {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(paths.state.join(CARRY_OVER_LOCK))?;
        file.lock()?;
        Ok(file)
    });
    let _held = match lock {
        Ok(file) => file,
        Err(error) => {
            return vec![format!(
                "could not take {}: {error}",
                paths.state.join(CARRY_OVER_LOCK).display()
            )];
        }
    };
    let mut stranded = Vec::new();
    for kind in kinds.into_iter().filter(has_old) {
        let old = kind.join(OLD_CLIENT_DIR);
        stranded.extend(merge_into(&old, kind, &|a, b| std::fs::rename(a, b)));
    }
    stranded
}

/// Held while a launch carries over (carry_over); never removed, so two
/// launches always lock the same file.
const CARRY_OVER_LOCK: &str = ".hal-c2-carry-over.lock";

/// SQLite's files beside a database, which belong to it and move with it.
const SQLITE_SIDECARS: [&str; 3] = ["-wal", "-shm", "-journal"];

fn sidecar_base(name: &str) -> Option<&str> {
    SQLITE_SIDECARS
        .iter()
        .find_map(|suffix| name.strip_suffix(suffix))
        .filter(|base| !base.is_empty())
}

fn taken(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

/// Whether something is at path, or why that cannot be told.
fn present(path: &Path) -> std::io::Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

type Rename<'a> = &'a dyn Fn(&Path, &Path) -> std::io::Result<()>;

fn merge_into(from: &Path, to: &Path, rename: Rename) -> Vec<String> {
    let mut stranded = finish_carrying(from, to, rename);
    // A level not seen whole moves nothing: a database could leave its
    // journal behind.
    let names = std::fs::read_dir(from).and_then(|entries| {
        entries
            .map(|entry| entry.map(|e| e.file_name().into_string().ok()))
            .filter_map(Result::transpose)
            .collect::<std::io::Result<Vec<String>>>()
    });
    let names = match names {
        Ok(names) => names,
        Err(error) => {
            stranded.push(format!("could not look in {}: {error}", from.display()));
            return stranded;
        }
    };
    let _ = std::fs::create_dir_all(to);
    for name in names.iter().filter(|n| sidecar_base(n).is_none()) {
        let (source, target) = (from.join(name), to.join(name));
        let foreign_sidecar = SQLITE_SIDECARS
            .iter()
            .any(|suffix| taken(&to.join(format!("{name}{suffix}"))));
        if !taken(&target) && !foreign_sidecar {
            let set: Vec<String> = std::iter::once(name.clone())
                .chain(
                    SQLITE_SIDECARS
                        .iter()
                        .map(|suffix| format!("{name}{suffix}"))
                        .filter(|sidecar| names.contains(sidecar)),
                )
                .collect();
            stranded.extend(move_together(from, to, &set, rename));
        } else if is_dir(&source) && is_dir(&target) {
            stranded.extend(merge_into(&source, &target, rename));
        }
    }
    // A sidecar whose database is gone from both levels has nothing to
    // part from.
    for name in names.iter().filter(|n| sidecar_base(n).is_some()) {
        let base = sidecar_base(name).unwrap_or_default();
        let target = to.join(name);
        let orphan = !names.iter().any(|n| n == base) && !taken(&to.join(base));
        if orphan && !taken(&target) {
            let _ = rename(&from.join(name), &target);
        }
    }
    // Only an emptied directory goes.
    let _ = std::fs::remove_dir(from);
    stranded
}

/// A record, beside the destination, of a database moving with its sidecars:
/// until it goes, the files it names at both levels are one set. The name is
/// carry_over's own, and only a record that starts with CARRYING_HEADER is
/// one; any other file of that name is left alone.
const CARRYING_PREFIX: &str = ".hal-c2-carrying.";
const CARRYING_HEADER: &str = "hal-c2 carry_over: one set\n";

fn carrying_marker(to: &Path, name: &str) -> PathBuf {
    to.join(format!("{CARRYING_PREFIX}{name}"))
}

/// The set a carrying record names, or None when the file is not one.
fn carrying_set(marker: &Path) -> Option<Vec<String>> {
    let text = std::fs::read_to_string(marker).ok()?;
    let set: Vec<String> = text
        .strip_prefix(CARRYING_HEADER)?
        .lines()
        .map(str::to_string)
        .collect();
    let plain = |n: &String| !n.is_empty() && !n.contains(['/', '\\']) && n != "." && n != "..";
    (!set.is_empty() && set.iter().all(plain)).then_some(set)
}

/// Moves a database with its sidecars, or, when one fails to move, puts back
/// what did: a database never lands without the journal holding its
/// committed pages. A move the process does not live to finish is finished
/// on the next start (finish_carrying).
fn move_together(from: &Path, to: &Path, set: &[String], rename: Rename) -> Option<String> {
    let marker = carrying_marker(to, &set[0]);
    if set.len() > 1 {
        // A file already there is someone else's: the set waits.
        let created = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&marker)
            .and_then(|mut file| {
                use std::io::Write;
                file.write_all(format!("{CARRYING_HEADER}{}\n", set.join("\n")).as_bytes())?;
                file.sync_all()
            });
        if created.is_err() {
            return None;
        }
    }
    for (moved, name) in set.iter().enumerate() {
        if rename(&from.join(name), &to.join(name)).is_err() {
            let mut stuck = Vec::new();
            for back in &set[..moved] {
                if let Err(error) = rename(&to.join(back), &from.join(back)) {
                    stuck.push(format!("{back} ({error})"));
                }
            }
            if stuck.is_empty() {
                if set.len() > 1 {
                    let _ = std::fs::remove_file(&marker);
                }
                return None;
            }
            // A set split for good stays recorded, so a later start joins it.
            return Some(format!(
                "{} moved to {} without the rest of its database, and could not go back",
                stuck.join(", "),
                to.display()
            ));
        }
    }
    if set.len() > 1 {
        let _ = std::fs::remove_file(&marker);
    }
    None
}

/// Joins what an interrupted move_together left a level down to the part
/// that already moved, before anything opens it. A set whose files are at
/// both levels is not joined: what sits at the destination is not all its.
/// Returns what it could not join, or could not look at.
fn finish_carrying(from: &Path, to: &Path, rename: Rename) -> Vec<String> {
    let mut stranded = Vec::new();
    // What cannot be looked at may hold a set cut short.
    let entries = match std::fs::read_dir(to) {
        Ok(entries) => entries,
        Err(error) => return vec![format!("could not look in {}: {error}", to.display())],
    };
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                stranded.push(format!("could not look in {}: {error}", to.display()));
                continue;
            }
        };
        let is_record = entry
            .file_name()
            .to_str()
            .is_some_and(|n| n.starts_with(CARRYING_PREFIX));
        if !is_record {
            continue;
        }
        let text = match std::fs::read(entry.path()) {
            Ok(text) => text,
            Err(error) => {
                stranded.push(format!(
                    "could not read {}: {error}",
                    entry.path().display()
                ));
                continue;
            }
        };
        // Cut off in its header: move_together writes the record whole
        // before it moves anything, so the set is whole where it was.
        if CARRYING_HEADER.as_bytes().starts_with(&text) {
            let _ = std::fs::remove_file(entry.path());
            continue;
        }
        let Some(set) = carrying_set(&entry.path()) else {
            continue;
        };
        // Where each part is, at the old level and here; a part that cannot
        // be looked at keeps the record.
        let parts = set
            .iter()
            .map(|n| Ok((n, present(&from.join(n))?, present(&to.join(n))?)))
            .collect::<std::io::Result<Vec<_>>>();
        let parts = match parts {
            Ok(parts) => parts,
            Err(error) => {
                stranded.push(format!(
                    "could not tell where {} in {} is: {error}",
                    set[0],
                    to.display()
                ));
                continue;
            }
        };
        let behind: Vec<&String> = parts.iter().filter(|p| p.1).map(|p| p.0).collect();
        let moved = parts.iter().any(|p| p.2 && !p.1);
        // Nothing of the set moved: it is whole where it was, and the
        // ordinary merge moves it (move_together) or leaves it.
        if !moved {
            let _ = std::fs::remove_file(entry.path());
            continue;
        }
        if parts.iter().any(|p| p.1 && p.2) {
            stranded.push(format!(
                "{} in {} is split from the rest of it in {}, and something else took its place",
                set[0],
                to.display(),
                from.display()
            ));
            continue;
        }
        let failed: Vec<String> = behind
            .iter()
            .filter_map(|n| {
                rename(&from.join(n), &to.join(n))
                    .err()
                    .map(|error| format!("{n} ({error})"))
            })
            .collect();
        if failed.is_empty() {
            let _ = std::fs::remove_file(entry.path());
        } else {
            stranded.push(format!(
                "{} in {} is missing {}, which could not move up from {}",
                set[0],
                to.display(),
                failed.join(", "),
                from.display()
            ));
        }
    }
    stranded
}

fn is_dir(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir())
}

fn is_absolute(path: &str, platform: Platform) -> bool {
    match platform {
        Platform::Unix => path.starts_with('/'),
        Platform::Windows => {
            let b = path.as_bytes();
            (b.len() >= 3
                && b[0].is_ascii_alphabetic()
                && b[1] == b':'
                && matches!(b[2], b'/' | b'\\'))
                || (b.len() >= 2 && matches!(b[0], b'/' | b'\\') && matches!(b[1], b'/' | b'\\'))
        }
    }
}

/// `.` and `..` resolved and trailing separators gone, as QDir::cleanPath.
fn clean(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

fn comparable(path: &Path, platform: Platform) -> String {
    let text = clean(path).to_string_lossy().replace('\\', "/");
    let text = text.trim_end_matches('/').to_owned();
    match platform {
        Platform::Windows => text.to_lowercase(),
        Platform::Unix => text,
    }
}

pub(crate) fn is_legacy_home(dir: &Path, user_home: &Path, platform: Platform) -> bool {
    let candidate = comparable(dir, platform);
    [".hal-c2", ".t3"]
        .iter()
        .any(|name| comparable(&user_home.join(name), platform) == candidate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_home_variable_wins_and_its_absence_falls_back() {
        assert_eq!(
            home_from(Some("/home/from-env".into())),
            PathBuf::from("/home/from-env")
        );
        // Unset and empty take the same account fallback (the
        // passwd entry on Unix), never the empty path itself when
        // the account has a home.
        assert_eq!(home_from(Some("".into())), home_from(None));
        if passwd_home().is_some() {
            assert!(!home_from(None).as_os_str().is_empty());
        }
    }

    fn on_unix(vars: &[(&str, &str)], home_dir: Option<&str>) -> StoragePaths {
        on(
            vars,
            home_dir,
            "/home/me",
            Platform::Unix,
            Profile::Installed,
        )
    }

    fn on(
        vars: &[(&str, &str)],
        home_dir: Option<&str>,
        user_home: &str,
        platform: Platform,
        profile: Profile,
    ) -> StoragePaths {
        let vars: Vec<(String, String)> = vars
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        let env = move |name: &str| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
        resolve(
            home_dir.map(Path::new),
            &env,
            Path::new(user_home),
            platform,
            profile,
        )
    }

    fn s(p: &Path) -> String {
        p.to_string_lossy().replace('\\', "/")
    }

    #[test]
    fn defaults_to_the_xdg_layout() {
        let paths = on_unix(&[], None);
        assert_eq!(paths.root, None);
        assert_eq!(s(&paths.config), "/home/me/.config/hal-c2");
        assert_eq!(s(&paths.data), "/home/me/.local/share/hal-c2");
        assert_eq!(s(&paths.state), "/home/me/.local/state/hal-c2");
        assert_eq!(s(&paths.cache), "/home/me/.cache/hal-c2");
        assert_eq!(s(&paths.shell), "/home/me/.config/hal-c2/shell");
    }

    #[test]
    fn absolute_xdg_variables_move_their_kind_and_relative_ones_do_not() {
        let paths = on_unix(
            &[
                ("XDG_CONFIG_HOME", "/xdg/config"),
                ("XDG_CACHE_HOME", " /xdg/cache/ "),
                ("XDG_STATE_HOME", "./state"),
            ],
            None,
        );
        assert_eq!(s(&paths.config), "/xdg/config/hal-c2");
        assert_eq!(s(&paths.cache), "/xdg/cache/hal-c2");
        assert_eq!(s(&paths.state), "/home/me/.local/state/hal-c2");
    }

    #[test]
    fn hal_c2_home_is_one_root_unless_it_is_an_old_home() {
        let paths = on_unix(
            &[
                ("HAL_C2_HOME", "/srv/hal-c2"),
                ("XDG_CONFIG_HOME", "/xdg/config"),
            ],
            None,
        );
        assert_eq!(paths.root.as_deref(), Some(Path::new("/srv/hal-c2")));
        assert_eq!(s(&paths.data), "/srv/hal-c2/data");
        for old in ["/home/me/.hal-c2", "/home/me/.t3/", "relative"] {
            let paths = on_unix(&[("HAL_C2_HOME", old)], None);
            assert_eq!(paths.root, None, "{old}");
            assert_eq!(s(&paths.config), "/home/me/.config/hal-c2");
        }
    }

    #[test]
    fn home_dir_outranks_hal_c2_home_in_either_profile() {
        let paths = on_unix(&[("HAL_C2_HOME", "/srv/hal-c2")], Some("/scratch/sandbox"));
        assert_eq!(paths.root.as_deref(), Some(Path::new("/scratch/sandbox")));
        assert_eq!(s(&paths.cache), "/scratch/sandbox/cache");
        assert_eq!(s(&paths.shell), "/scratch/sandbox/config/shell");
        let dev = on(
            &[],
            Some("/scratch/sandbox"),
            "/home/me",
            Platform::Unix,
            Profile::Development,
        );
        assert_eq!(s(&dev.data), "/scratch/sandbox/data");
    }

    #[test]
    fn the_development_profile_is_its_own_directories_and_ignores_hal_c2_home() {
        let paths = on(
            &[
                ("HAL_C2_HOME", "/srv/hal-c2"),
                ("XDG_DATA_HOME", "/xdg/data"),
            ],
            None,
            "/home/me",
            Platform::Unix,
            Profile::Development,
        );
        assert_eq!(paths.root, None);
        assert_eq!(s(&paths.config), "/home/me/.config/hal-c2-dev");
        assert_eq!(s(&paths.shell), "/home/me/.config/hal-c2-dev/shell");
        assert_eq!(s(&paths.data), "/xdg/data/hal-c2-dev");
    }

    #[test]
    fn windows_uses_app_data_for_config_and_local_app_data_for_the_rest() {
        let paths = on(
            &[
                ("APPDATA", "C:/Users/me/AppData/Roaming"),
                ("LOCALAPPDATA", "C:/Users/me/AppData/Local"),
                ("XDG_CACHE_HOME", "relative"),
                ("XDG_DATA_HOME", "D:/xdg/data"),
            ],
            None,
            "C:/Users/me",
            Platform::Windows,
            Profile::Installed,
        );
        assert_eq!(
            s(&paths.config),
            "C:/Users/me/AppData/Roaming/hal-c2/config"
        );
        assert_eq!(s(&paths.data), "D:/xdg/data/hal-c2");
        assert_eq!(
            s(&paths.shell),
            "C:/Users/me/AppData/Roaming/hal-c2/config/shell"
        );
        assert_eq!(s(&paths.cache), "C:/Users/me/AppData/Local/hal-c2/cache");
        let old = on(
            &[("HAL_C2_HOME", "c:/USERS/me/.HAL-C2")],
            None,
            "C:/Users/me",
            Platform::Windows,
            Profile::Installed,
        );
        assert_eq!(old.root, None);
    }

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("hal-c2-storage-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn read(path: &Path) -> Option<String> {
        std::fs::read_to_string(path).ok()
    }

    #[test]
    fn an_earlier_shells_files_move_up_without_overwriting_desktop_qts() {
        let root = scratch("carry-over");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = |kind: &Path, name: &str| kind.join(OLD_CLIENT_DIR).join(name);
        // The earlier shell's files.
        write(&old(&paths.data, "shell-drafts.json"), "ljos drafts");
        write(&old(&paths.data, "pairing.json"), "ljos pairing");
        write(&old(&paths.state, "shell-windows.json"), "ljos windows");
        write(
            &old(&paths.state, "shell-windows/w2/shell-panel.json"),
            "ljos w2",
        );
        write(
            &old(&paths.state, "shell-windows/w3/shell-panel.json"),
            "ljos w3",
        );
        write(&old(&paths.cache, "client-cache.sqlite"), "ljos db");
        write(&old(&paths.cache, "client-cache.sqlite-wal"), "ljos wal");
        write(&old(&paths.cache, "mc-plugins/a/plugin.js"), "ljos plugin");
        // What desktop-qt already wrote.
        write(&paths.state.join("shell-windows.json"), "qt windows");
        write(
            &paths.state.join("shell-windows/w2/shell-panel.json"),
            "qt w2",
        );
        write(&paths.cache.join("client-cache.sqlite"), "qt db");

        carry_over(&paths);

        // Moved where nothing was.
        assert_eq!(
            read(&paths.data.join("shell-drafts.json")).as_deref(),
            Some("ljos drafts")
        );
        assert_eq!(
            read(&paths.data.join("pairing.json")).as_deref(),
            Some("ljos pairing")
        );
        assert_eq!(
            read(&paths.state.join("shell-windows/w3/shell-panel.json")).as_deref(),
            Some("ljos w3")
        );
        assert_eq!(
            read(&paths.cache.join("mc-plugins/a/plugin.js")).as_deref(),
            Some("ljos plugin")
        );
        // desktop-qt's own are kept, and the earlier shell's stay put.
        assert_eq!(
            read(&paths.state.join("shell-windows.json")).as_deref(),
            Some("qt windows")
        );
        assert_eq!(
            read(&paths.state.join("shell-windows/w2/shell-panel.json")).as_deref(),
            Some("qt w2")
        );
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite")).as_deref(),
            Some("qt db")
        );
        assert_eq!(
            read(&old(&paths.state, "shell-windows.json")).as_deref(),
            Some("ljos windows")
        );
        // A database's journal never lands beside another database.
        assert!(!paths.cache.join("client-cache.sqlite-wal").exists());
        assert_eq!(
            read(&old(&paths.cache, "client-cache.sqlite-wal")).as_deref(),
            Some("ljos wal")
        );
        // An emptied old level is gone; one with leftovers stays.
        assert!(!paths.data.join(OLD_CLIENT_DIR).exists());
        assert!(paths.state.join(OLD_CLIENT_DIR).exists());

        // A second start changes nothing.
        carry_over(&paths);
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite")).as_deref(),
            Some("qt db")
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_database_moves_with_its_journal() {
        let root = scratch("carry-over-db");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        write(&old.join("client-cache.sqlite-shm"), "shm");
        carry_over(&paths);
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite")).as_deref(),
            Some("db")
        );
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite-wal")).as_deref(),
            Some("wal")
        );
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite-shm")).as_deref(),
            Some("shm")
        );
        assert!(!old.exists());

        // One whose place holds another's journal stays, with its own.
        let root2 = scratch("carry-over-db-foreign");
        let paths = on_unix(&[], Some(root2.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-shm"), "shm");
        write(&paths.cache.join("client-cache.sqlite-wal"), "qt wal");
        carry_over(&paths);
        assert!(!paths.cache.join("client-cache.sqlite").exists());
        assert!(!paths.cache.join("client-cache.sqlite-shm").exists());
        assert_eq!(
            read(&old.join("client-cache.sqlite")).as_deref(),
            Some("db")
        );
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&root2);
    }

    #[test]
    fn a_database_stays_put_when_its_journal_cannot_move() {
        let root = scratch("carry-over-db-partial");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        write(&old.join("client-cache.sqlite-shm"), "shm");
        let stuck_wal = |a: &Path, b: &Path| {
            if a.ends_with("client-cache.sqlite-wal") {
                Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
            } else {
                std::fs::rename(a, b)
            }
        };
        assert!(merge_into(&old, &paths.cache, &stuck_wal).is_empty());
        for name in [
            "client-cache.sqlite",
            "client-cache.sqlite-wal",
            "client-cache.sqlite-shm",
        ] {
            assert!(!paths.cache.join(name).exists(), "{name} moved alone");
            assert!(old.join(name).exists(), "{name} left the old level");
        }

        // The next start, with the journal free to move, takes the set.
        carry_over(&paths);
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite-wal")).as_deref(),
            Some("wal")
        );
        assert!(!old.exists());
        assert!(!carrying_marker(&paths.cache, "client-cache.sqlite").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_database_move_cut_short_is_finished_on_the_next_start() {
        let root = scratch("carry-over-db-interrupted");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        // The process ended after the database moved, before its journal.
        write(
            &carrying_marker(&paths.cache, "client-cache.sqlite"),
            &format!(
                "{CARRYING_HEADER}client-cache.sqlite\nclient-cache.sqlite-wal\nclient-cache.sqlite-shm\n"
            ),
        );
        write(&paths.cache.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        write(&old.join("client-cache.sqlite-shm"), "shm");
        carry_over(&paths);
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite-wal")).as_deref(),
            Some("wal")
        );
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite-shm")).as_deref(),
            Some("shm")
        );
        assert!(!carrying_marker(&paths.cache, "client-cache.sqlite").exists());
        assert!(!old.exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_set_cut_short_before_it_moved_stays_whole_beside_a_new_database() {
        let root = scratch("carry-over-db-clash");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        // Recorded, then the process ended before a file moved, and
        // desktop-qt made its own database since.
        write(
            &carrying_marker(&paths.cache, "client-cache.sqlite"),
            &format!("{CARRYING_HEADER}client-cache.sqlite\nclient-cache.sqlite-wal\n"),
        );
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        write(&paths.cache.join("client-cache.sqlite"), "qt");
        carry_over(&paths);
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite")).as_deref(),
            Some("qt")
        );
        assert!(!paths.cache.join("client-cache.sqlite-wal").exists());
        assert_eq!(
            read(&old.join("client-cache.sqlite-wal")).as_deref(),
            Some("wal")
        );
        assert_eq!(
            read(&old.join("client-cache.sqlite")).as_deref(),
            Some("db")
        );
        assert!(!carrying_marker(&paths.cache, "client-cache.sqlite").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_file_where_the_record_would_go_is_left_alone() {
        let root = scratch("carry-over-db-foreign-record");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        let record = carrying_marker(&paths.cache, "client-cache.sqlite");
        write(&record, "mine");
        write(&paths.cache.join("notes.carrying"), "also mine");
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        carry_over(&paths);
        assert_eq!(read(&record).as_deref(), Some("mine"));
        assert_eq!(
            read(&paths.cache.join("notes.carrying")).as_deref(),
            Some("also mine")
        );
        // The set waits, together, rather than move unrecorded.
        assert!(old.join("client-cache.sqlite").exists());
        assert!(old.join("client-cache.sqlite-wal").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_set_cut_short_before_it_moved_moves_whole_on_the_next_start() {
        let root = scratch("carry-over-db-unmoved");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        // Recorded, then the process ended before a file moved.
        write(
            &carrying_marker(&paths.cache, "client-cache.sqlite"),
            &format!("{CARRYING_HEADER}client-cache.sqlite\nclient-cache.sqlite-wal\n"),
        );
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        carry_over(&paths);
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite")).as_deref(),
            Some("db")
        );
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite-wal")).as_deref(),
            Some("wal")
        );
        assert!(!carrying_marker(&paths.cache, "client-cache.sqlite").exists());
        assert!(!old.exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_database_whose_journal_cannot_join_it_is_reported_until_it_does() {
        let root = scratch("carry-over-db-stranded");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        // The database moved, the process ended, and the journal is stuck.
        write(
            &carrying_marker(&paths.cache, "client-cache.sqlite"),
            &format!("{CARRYING_HEADER}client-cache.sqlite\nclient-cache.sqlite-wal\n"),
        );
        write(&paths.cache.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        let stuck_wal = |a: &Path, b: &Path| {
            if a.ends_with("client-cache.sqlite-wal") {
                Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
            } else {
                std::fs::rename(a, b)
            }
        };
        let stranded = merge_into(&old, &paths.cache, &stuck_wal);
        assert_eq!(stranded.len(), 1, "{stranded:?}");
        assert!(stranded[0].contains("client-cache.sqlite-wal"));
        assert!(carrying_marker(&paths.cache, "client-cache.sqlite").exists());

        // A later start that can move it joins the set and reports nothing.
        assert!(carry_over(&paths).is_empty());
        assert_eq!(
            read(&paths.cache.join("client-cache.sqlite-wal")).as_deref(),
            Some("wal")
        );
        assert!(!carrying_marker(&paths.cache, "client-cache.sqlite").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_set_cut_short_before_it_moved_stays_whole_when_its_journal_cannot_move() {
        let root = scratch("carry-over-db-unmoved-stuck");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        write(
            &carrying_marker(&paths.cache, "client-cache.sqlite"),
            &format!("{CARRYING_HEADER}client-cache.sqlite\nclient-cache.sqlite-wal\n"),
        );
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        let stuck_wal = |a: &Path, b: &Path| {
            if a.ends_with("client-cache.sqlite-wal") {
                Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
            } else {
                std::fs::rename(a, b)
            }
        };
        // Nothing was split, so nothing is reported and nothing splits.
        assert!(merge_into(&old, &paths.cache, &stuck_wal).is_empty());
        assert!(!paths.cache.join("client-cache.sqlite").exists());
        assert_eq!(
            read(&old.join("client-cache.sqlite")).as_deref(),
            Some("db")
        );
        assert_eq!(
            read(&old.join("client-cache.sqlite-wal")).as_deref(),
            Some("wal")
        );
        assert!(!carrying_marker(&paths.cache, "client-cache.sqlite").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn a_destination_that_cannot_be_looked_at_blocks_the_start() {
        use std::os::unix::fs::PermissionsExt;
        let root = scratch("carry-over-unlistable");
        let paths = on_unix(&[], Some(root.to_str().unwrap()));
        let old = paths.cache.join(OLD_CLIENT_DIR);
        write(&old.join("client-cache.sqlite"), "db");
        let to = paths.cache.join("sub");
        write(&to.join("x"), "x");
        std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o300)).unwrap();
        let listable = std::fs::read_dir(&to).is_ok();
        let stranded = finish_carrying(&old, &to, &|a, b| std::fs::rename(a, b));
        std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o700)).unwrap();
        // Root lists what it may not; there is nothing to show then.
        if !listable {
            assert_eq!(stranded.len(), 1, "{stranded:?}");
            assert!(stranded[0].contains("could not look in"));
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_record_cut_off_in_its_header_lets_the_set_move_whole() {
        let root = scratch("carry-over-cut-header");
        let to = root.join("cache");
        let old = to.join(OLD_CLIENT_DIR);
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        let marker = carrying_marker(&to, "client-cache.sqlite");
        write(&marker, &CARRYING_HEADER[..10]);
        assert!(merge_into(&old, &to, &|a, b| std::fs::rename(a, b)).is_empty());
        assert_eq!(read(&to.join("client-cache.sqlite")).as_deref(), Some("db"));
        assert_eq!(
            read(&to.join("client-cache.sqlite-wal")).as_deref(),
            Some("wal")
        );
        assert!(!marker.exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn an_old_level_that_cannot_be_listed_moves_nothing_and_blocks_the_start() {
        use std::os::unix::fs::PermissionsExt;
        let root = scratch("carry-over-old-unlistable");
        let to = root.join("cache");
        let old = to.join(OLD_CLIENT_DIR);
        write(&old.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o300)).unwrap();
        let listable = std::fs::read_dir(&old).is_ok();
        let stranded = merge_into(&old, &to, &|a, b| std::fs::rename(a, b));
        std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o700)).unwrap();
        if !listable {
            assert_eq!(stranded.len(), 1, "{stranded:?}");
            assert!(stranded[0].contains("could not look in"));
            assert_eq!(
                read(&old.join("client-cache.sqlite")).as_deref(),
                Some("db")
            );
            assert_eq!(read(&to.join("client-cache.sqlite")), None);
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn a_set_cut_short_whose_old_level_cannot_be_searched_keeps_its_record() {
        use std::os::unix::fs::PermissionsExt;
        let root = scratch("carry-over-old-unsearchable");
        let to = root.join("cache");
        let old = to.join(OLD_CLIENT_DIR);
        write(&to.join("client-cache.sqlite"), "db");
        write(&old.join("client-cache.sqlite-wal"), "wal");
        let marker = carrying_marker(&to, "client-cache.sqlite");
        write(
            &marker,
            &format!("{CARRYING_HEADER}client-cache.sqlite\nclient-cache.sqlite-wal\n"),
        );
        std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o600)).unwrap();
        let searchable = std::fs::symlink_metadata(old.join("client-cache.sqlite-wal")).is_ok();
        let stranded = finish_carrying(&old, &to, &|a, b| std::fs::rename(a, b));
        std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o700)).unwrap();
        if !searchable {
            assert_eq!(stranded.len(), 1, "{stranded:?}");
            assert!(stranded[0].contains("could not tell where"));
            assert!(marker.exists());
        }
        let _ = std::fs::remove_dir_all(&root);
    }
}
