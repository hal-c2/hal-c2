//! The shell's QML: desktop-qt's bricks (`apps/desktop-qt/qml`) and this
//! app's own (`apps/desktop-ljos/qml`: the entry and the QML half of
//! `HalC2.Shell`), compiled at start-up as one project.
//!
//! Not `App::qml_dir`: it takes one directory and fails the whole start
//! when any file has an error, where Qt (and desktop-qt) fails only what
//! makes an object of the broken file. So the project is put together here
//! from both roots, and a file that does not compile is a failure its users
//! are told of, as `ljos render` loads a project. Compiling ahead of time
//! against the shell's native types is not offered by Ljós yet.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use ljos::MapSource;
use ljos::dev::EngineOracle;
use ljos_compiler::{Project, Severity, compile_file};

/// The project's directories: the bricks' first (its base URL is theirs,
/// so `Qt.resolvedUrl` in a brick finds its icons), then this app's.
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
}

pub struct Loaded {
    pub source: MapSource,
    pub files: usize,
    pub compiled: usize,
    /// The first error of each file that did not compile, by its key.
    pub errors: BTreeMap<String, String>,
}

/// Compiles both roots against the standard modules and `HalC2.Shell`.
pub fn load(roots: &Roots) -> Result<Loaded, String> {
    let bricks = roots
        .bricks
        .canonicalize()
        .map_err(|e| format!("{}: {e}", roots.bricks.display()))?;
    let shell = roots
        .shell
        .canonicalize()
        .map_err(|e| format!("{}: {e}", roots.shell.display()))?;
    // What the compiler knows of the native types: an Engine with them on.
    let snapshot = ljos::engine();
    crate::register(&snapshot);
    let mut project =
        Project::load(&bricks, EngineOracle::from_engine(&snapshot)).map_err(|e| e.to_string())?;
    if shell != bricks {
        overlay(&mut project, &shell)?;
    }
    let mut out = Loaded {
        source: MapSource::new().with_base_url(format!("file://{}", bricks.to_string_lossy())),
        files: 0,
        compiled: 0,
        errors: BTreeMap::new(),
    };
    let keys: Vec<String> = project.files().map(str::to_owned).collect();
    for key in keys {
        out.files += 1;
        match compile_file(&project, &key) {
            Ok(c) if !c.has_errors() => {
                out.compiled += 1;
                out.source.insert(key, c.file);
            }
            Ok(c) => fail(&mut out, key, &c.diagnostics),
            Err(ds) => fail(&mut out, key, &ds),
        }
    }
    Ok(out)
}

fn fail(out: &mut Loaded, key: String, diagnostics: &[ljos_compiler::Diagnostic]) {
    let first = diagnostics
        .iter()
        .find(|d| d.severity == Severity::Error)
        .or(diagnostics.first());
    let why = ljos_compiler::failure_reason(diagnostics);
    out.errors.insert(
        key.clone(),
        first.map_or_else(|| why.clone(), ToString::to_string),
    );
    out.source.insert_failure(key, why);
}

/// Adds `root`'s files and modules to `project` under their keys from
/// `root`, as `Project::load` reads one root.
fn overlay(project: &mut Project<EngineOracle>, root: &Path) -> Result<(), String> {
    let mut qmldirs = Vec::new();
    let mut dirs = vec![root.to_owned()];
    while let Some(dir) = dirs.pop() {
        let entries = std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            if path.is_dir() {
                dirs.push(path);
                continue;
            }
            let Some(key) = key(root, &path) else {
                continue;
            };
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            if let Some(key) = key.strip_suffix(".qml") {
                project.add(key, text);
            } else if key.ends_with(".js") || key.ends_with(".mjs") {
                project.add_script(&key, text);
            } else if name == "qmldir" {
                let dir_key = key
                    .strip_suffix("qmldir")
                    .unwrap_or("")
                    .trim_end_matches('/')
                    .to_owned();
                qmldirs.push((dir_key, text));
            }
        }
    }
    // After the files: a qmldir names types only of files the project has.
    for (dir, text) in qmldirs {
        project.add_qmldir(&dir, &text);
    }
    Ok(())
}

fn key(root: &Path, path: &Path) -> Option<String> {
    Some(
        path.strip_prefix(root)
            .ok()?
            .to_string_lossy()
            .replace('\\', "/"),
    )
}
