//! Where the shell keeps its files: desktop-qt's StoragePaths, resolved as
//! packages/shared/src/xdgDirs.ts resolves them, with every directory one
//! `desktop-ljos` level down so this client and desktop-qt never share state
//! (a cache or a pairing one wrote is not the other's to read). What the user
//! writes to change how the app looks and behaves (theme, shell, QML modules,
//! plugins, preferences) is the config home's `shell`, shared with desktop-qt.
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

use std::path::{Component, Path, PathBuf};

/// The level under each HAL-C2 directory that is this client's own.
pub const CLIENT_DIR: &str = "desktop-ljos";

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

/// The HAL-C2 config, data, state and cache directories, each with this
/// client's level, and the config's shared `shell`.
fn nested(root: Option<PathBuf>, [config, data, state, cache]: [PathBuf; 4]) -> StoragePaths {
    StoragePaths {
        root,
        shell: config.join("shell"),
        config: config.join(CLIENT_DIR),
        data: data.join(CLIENT_DIR),
        state: state.join(CLIENT_DIR),
        cache: cache.join(CLIENT_DIR),
    }
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
    fn defaults_to_the_xdg_layout_one_level_down() {
        let paths = on_unix(&[], None);
        assert_eq!(paths.root, None);
        assert_eq!(s(&paths.config), "/home/me/.config/hal-c2/desktop-ljos");
        assert_eq!(s(&paths.data), "/home/me/.local/share/hal-c2/desktop-ljos");
        assert_eq!(s(&paths.state), "/home/me/.local/state/hal-c2/desktop-ljos");
        assert_eq!(s(&paths.cache), "/home/me/.cache/hal-c2/desktop-ljos");
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
        assert_eq!(s(&paths.config), "/xdg/config/hal-c2/desktop-ljos");
        assert_eq!(s(&paths.cache), "/xdg/cache/hal-c2/desktop-ljos");
        assert_eq!(s(&paths.state), "/home/me/.local/state/hal-c2/desktop-ljos");
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
        assert_eq!(s(&paths.data), "/srv/hal-c2/data/desktop-ljos");
        for old in ["/home/me/.hal-c2", "/home/me/.t3/", "relative"] {
            let paths = on_unix(&[("HAL_C2_HOME", old)], None);
            assert_eq!(paths.root, None, "{old}");
            assert_eq!(s(&paths.config), "/home/me/.config/hal-c2/desktop-ljos");
        }
    }

    #[test]
    fn home_dir_outranks_hal_c2_home_in_either_profile() {
        let paths = on_unix(&[("HAL_C2_HOME", "/srv/hal-c2")], Some("/scratch/sandbox"));
        assert_eq!(paths.root.as_deref(), Some(Path::new("/scratch/sandbox")));
        assert_eq!(s(&paths.cache), "/scratch/sandbox/cache/desktop-ljos");
        assert_eq!(s(&paths.shell), "/scratch/sandbox/config/shell");
        let dev = on(
            &[],
            Some("/scratch/sandbox"),
            "/home/me",
            Platform::Unix,
            Profile::Development,
        );
        assert_eq!(s(&dev.data), "/scratch/sandbox/data/desktop-ljos");
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
        assert_eq!(s(&paths.config), "/home/me/.config/hal-c2-dev/desktop-ljos");
        assert_eq!(s(&paths.shell), "/home/me/.config/hal-c2-dev/shell");
        assert_eq!(s(&paths.data), "/xdg/data/hal-c2-dev/desktop-ljos");
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
            "C:/Users/me/AppData/Roaming/hal-c2/config/desktop-ljos"
        );
        assert_eq!(s(&paths.data), "D:/xdg/data/hal-c2/desktop-ljos");
        assert_eq!(
            s(&paths.shell),
            "C:/Users/me/AppData/Roaming/hal-c2/config/shell"
        );
        assert_eq!(
            s(&paths.cache),
            "C:/Users/me/AppData/Local/hal-c2/cache/desktop-ljos"
        );
        let old = on(
            &[("HAL_C2_HOME", "c:/USERS/me/.HAL-C2")],
            None,
            "C:/Users/me",
            Platform::Windows,
            Profile::Installed,
        );
        assert_eq!(old.root, None);
    }
}
