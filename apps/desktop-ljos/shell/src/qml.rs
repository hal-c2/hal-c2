//! The shell's QML: desktop-qt's bricks (`apps/desktop-qt/qml`) and this
//! app's own (`apps/desktop-ljos/qml`: the entry and the QML half of
//! `HalC2.Shell`), with the user's (`<config>/qml` and `<config>/shell.qml`)
//! when there is a config dir, compiled at start-up as one import path
//! (`App::qml_dirs`) and again for each reload (src/runtime.rs).

use std::path::{Path, PathBuf};

use ljos::dev::Compiled;

/// The key of the built-in shell, `qml/Main.qml`.
pub const DEFAULT_SHELL: &str = "Main";

/// The key of `<config>/shell.qml` in what [`compile`] makes.
pub const USER_SHELL: &str = "shell";

/// The import path: the user's modules, the bricks' root, this app's, any
/// further roots an app over this shell brings (the phone's `HalC2.Mobile`),
/// then the user's shell.
#[derive(Clone, Debug)]
pub struct Roots {
    pub bricks: PathBuf,
    pub shell: PathBuf,
    /// Roots after this app's own, each once: another app's modules over
    /// the same bricks and `HalC2.Shell` (apps/mobile-ljos's phone QML).
    pub extra: Vec<PathBuf>,
    /// The config dir. Its `qml` comes first, so the user's modules and
    /// brick overrides win (desktop-qt prepends it to the import path), and
    /// its `shell.qml`, with the files beside it, is [`USER_SHELL`].
    pub user: Option<PathBuf>,
}

impl Roots {
    /// Where they are in this checkout.
    pub fn checkout() -> Roots {
        let app = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("shell/ is in the app");
        Roots {
            bricks: app.join("../desktop-qt/qml"),
            shell: app.join("qml"),
            extra: Vec::new(),
            user: None,
        }
    }

    /// `dir` holding both: `dir/HalC2/Bricks` and the entry (a release lays
    /// them out so).
    pub fn one(dir: PathBuf) -> Roots {
        Roots {
            bricks: dir.clone(),
            shell: dir,
            extra: Vec::new(),
            user: None,
        }
    }

    /// These with the user's files in `config_dir`.
    pub fn with_user(self, config_dir: PathBuf) -> Roots {
        Roots {
            user: Some(config_dir),
            ..self
        }
    }

    /// The directories, in order, each once. `<config>/qml` only while it is
    /// there, as desktop-qt looks on each load, and the config dir only
    /// while it has a `shell.qml`, so that its plugins are not compiled for
    /// nothing.
    pub fn dirs(&self) -> Result<Vec<PathBuf>, String> {
        let canonical = |p: &Path| {
            p.canonicalize()
                .map_err(|e| format!("{}: {e}", p.display()))
        };
        let user = self.user.as_deref();
        let mut dirs = Vec::new();
        if let Some(modules) = user.map(|u| u.join("qml")).filter(|m| m.is_dir()) {
            dirs.push(canonical(&modules)?);
        }
        dirs.push(canonical(&self.bricks)?);
        dirs.push(canonical(&self.shell)?);
        for root in &self.extra {
            dirs.push(canonical(root)?);
        }
        if let Some(user) = user.filter(|u| u.join("shell.qml").is_file()) {
            dirs.push(canonical(user)?);
        }
        let mut once = Vec::new();
        for dir in dirs {
            if !once.contains(&dir) {
                once.push(dir);
            }
        }
        Ok(once)
    }

    /// What a reload follows: all of the config dir (its `qml` and
    /// `shell.qml` may be made later) and the roots.
    pub fn watched(&self) -> Vec<PathBuf> {
        let mut dirs: Vec<PathBuf> = self.user.iter().cloned().collect();
        dirs.push(self.bricks.clone());
        if self.shell != self.bricks {
            dirs.push(self.shell.clone());
        }
        for root in &self.extra {
            if !dirs.contains(root) {
                dirs.push(root.clone());
            }
        }
        dirs
    }
}

/// Compiles the roots against the standard modules and `HalC2.Shell`, as
/// `App::qml_dirs` does for the app, printing nothing: for `--check`, the
/// runtime's reloads and the tests, which show what it found themselves.
pub fn compile(roots: &Roots) -> Result<Compiled, String> {
    let dirs = roots.dirs()?;
    let snapshot = ljos::engine();
    crate::register(&snapshot);
    let paths: Vec<&Path> = dirs.iter().map(PathBuf::as_path).collect();
    ljos::dev::compile_quiet(&paths, Some(&snapshot)).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn another_apps_roots_come_after_this_ones_and_before_the_users_shell() {
        let dir = tempfile::tempdir().unwrap();
        let made = |name: &str| {
            let path = dir.path().join(name);
            std::fs::create_dir_all(&path).unwrap();
            path.canonicalize().unwrap()
        };
        let (bricks, shell, phone, user) =
            (made("bricks"), made("shell"), made("phone"), made("user"));
        std::fs::write(user.join("shell.qml"), "").unwrap();
        let roots = Roots {
            bricks: bricks.clone(),
            shell: shell.clone(),
            extra: vec![phone.clone(), bricks.clone()],
            user: Some(user.clone()),
        };
        assert_eq!(
            roots.dirs().unwrap(),
            [bricks.clone(), shell.clone(), phone.clone(), user.clone()]
        );
        assert_eq!(roots.watched(), [user, bricks, shell, phone]);
    }
}
