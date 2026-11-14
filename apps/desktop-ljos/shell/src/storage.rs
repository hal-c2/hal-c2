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

impl StoragePaths {
    /// The paths of this process: its environment, home and platform.
    pub fn resolve(home_dir: Option<&Path>, profile: Profile) -> StoragePaths {
        let platform = if cfg!(windows) {
            Platform::Windows
        } else {
            Platform::Unix
        };
        let user_home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
            .map(PathBuf::from)
            .unwrap_or_default();
        let env = |name: &str| std::env::var(name).ok();
        resolve(home_dir, &env, &user_home, platform, profile)
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
pub fn carry_over(paths: &StoragePaths) {
    for kind in [&paths.config, &paths.data, &paths.state, &paths.cache] {
        let old = kind.join(OLD_CLIENT_DIR);
        if std::fs::symlink_metadata(&old).is_ok_and(|m| m.is_dir()) {
            merge_into(&old, kind, &|a, b| std::fs::rename(a, b));
        }
    }
}

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

type Rename<'a> = &'a dyn Fn(&Path, &Path) -> std::io::Result<()>;

fn merge_into(from: &Path, to: &Path, rename: Rename) {
    let Ok(entries) = std::fs::read_dir(from) else {
        return;
    };
    let names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
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
            move_together(from, to, &set, rename);
        } else if is_dir(&source) && is_dir(&target) {
            merge_into(&source, &target, rename);
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
}

/// Moves a database with its sidecars, or, when one fails to move, puts back
/// what did: a database never lands without the journal holding its
/// committed pages.
fn move_together(from: &Path, to: &Path, set: &[String], rename: Rename) {
    for (moved, name) in set.iter().enumerate() {
        if rename(&from.join(name), &to.join(name)).is_err() {
            for back in &set[..moved] {
                let _ = rename(&to.join(back), &from.join(back));
            }
            return;
        }
    }
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

fn is_legacy_home(dir: &Path, user_home: &Path, platform: Platform) -> bool {
    let candidate = comparable(dir, platform);
    [".hal-c2", ".t3"]
        .iter()
        .any(|name| comparable(&user_home.join(name), platform) == candidate)
}

#[cfg(test)]
mod tests {
    use super::*;

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
        merge_into(&old, &paths.cache, &stuck_wal);
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
        let _ = std::fs::remove_dir_all(&root);
    }
}
