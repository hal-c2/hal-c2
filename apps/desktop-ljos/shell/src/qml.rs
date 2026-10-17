//! The shell's QML: desktop-qt's bricks (`apps/desktop-qt/qml`) and this
//! app's own (`apps/desktop-ljos/qml`: the entry and the QML half of
//! `HalC2.Shell`), compiled at start-up as one import path
//! (`App::qml_dirs`).

use std::path::{Path, PathBuf};

use ljos::dev::Compiled;

/// The import path: the bricks' root first, then this app's.
#[derive(Clone, Debug)]
pub struct Roots {
    pub bricks: PathBuf,
    pub shell: PathBuf,
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
        }
    }

    /// `dir` holding both: `dir/HalC2/Bricks` and the entry (a release lays
    /// them out so).
    pub fn one(dir: PathBuf) -> Roots {
        Roots {
            bricks: dir.clone(),
            shell: dir,
        }
    }

    /// Both, once when they are the same directory.
    pub fn dirs(&self) -> Result<Vec<PathBuf>, String> {
        let canonical = |p: &Path| {
            p.canonicalize()
                .map_err(|e| format!("{}: {e}", p.display()))
        };
        let mut dirs = vec![canonical(&self.bricks)?, canonical(&self.shell)?];
        dirs.dedup();
        Ok(dirs)
    }
}

/// Compiles the roots against the standard modules and `HalC2.Shell`, as
/// `App::qml_dirs` does for the app, printing nothing: for `--check` and
/// the tests, which count and show what it found themselves.
pub fn compile(roots: &Roots) -> Result<Compiled, String> {
    let dirs = roots.dirs()?;
    let snapshot = ljos::engine();
    crate::register(&snapshot);
    let paths: Vec<&Path> = dirs.iter().map(PathBuf::as_path).collect();
    ljos::dev::compile_quiet(&paths, Some(&snapshot))
}
