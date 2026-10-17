//! The shell's QML: desktop-qt's bricks (`apps/desktop-qt/qml`) and this
//! app's own (`apps/desktop-ljos/qml`: the entry and the QML half of
//! `HalC2.Shell`), compiled at start-up as one import path.
//!
//! What `App::qml_dirs` does, but for the base URL: the facade gives its
//! components none, so a brick's `Qt.resolvedUrl` (its icons) would point
//! nowhere. TODO(ljos#49).

use std::path::{Path, PathBuf};

use ljos::MapSource;
use ljos::dev::OnError;

/// The import path: the bricks' root first (its base URL is theirs, so
/// `Qt.resolvedUrl` in a brick finds its icons), then this app's.
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

    fn dirs(&self) -> Result<Vec<PathBuf>, String> {
        let canonical = |p: &Path| {
            p.canonicalize()
                .map_err(|e| format!("{}: {e}", p.display()))
        };
        let mut dirs = vec![canonical(&self.bricks)?, canonical(&self.shell)?];
        dirs.dedup();
        Ok(dirs)
    }
}

/// Compiles the roots against the standard modules and `HalC2.Shell`,
/// printing what the compiler says. [`OnError::Record`] is the app's: a
/// file with an error fails only what makes an object of it, as in Qt.
pub fn compile(roots: &Roots, on_error: OnError) -> Result<MapSource, String> {
    let dirs = roots.dirs()?;
    let snapshot = ljos::engine();
    crate::register(&snapshot);
    let paths: Vec<&Path> = dirs.iter().map(PathBuf::as_path).collect();
    let source = ljos::dev::compile_dirs(&paths, Some(&snapshot), on_error)?;
    Ok(source.with_base_url(format!("file://{}", dirs[0].to_string_lossy())))
}

/// How many `.qml` files the roots hold, for `--check` to say: a
/// `MapSource` does not tell what it holds.
pub fn count(roots: &Roots) -> Result<usize, String> {
    let mut count = 0;
    let mut dirs = roots.dirs()?;
    while let Some(dir) = dirs.pop() {
        let entries = std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        for entry in entries.flatten() {
            let path = entry.path();
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|e| e == "qml") {
                count += 1;
            }
        }
    }
    Ok(count)
}
