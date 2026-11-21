//! Compiles the checkout's QML (the bricks and `qml/`, as `Roots::checkout`
//! lays them out) into the pack the app runs, `$OUT_DIR/qml.pack`
//! (`hal_c2_shell::pack`), and its bindings and handlers to Rust in
//! `$OUT_DIR/qml.rs`, against the native types `ljostypes.json` describes
//! (tests/shell_tree.rs keeps it current). The pack carries its sources: a
//! user's file in the config dir is compiled against them while the app runs
//! (`App::user_qml`). A file runs the Rust code while it is the file the code
//! was made from, and dynamically once a user's file replaces it.
//!
//! On stderr (`build/hal_c2_shell-*/stderr` in the target directory): each
//! file's compiled and total expressions, the totals, then why each of the
//! rest runs dynamically.

use std::path::{Path, PathBuf};

fn main() {
    // hal-c2-ljos and its web engine helper find CEF's libcef.so beside
    // themselves, where the cef crate copies it (Cargo.toml).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo::rustc-link-arg-bins=-Wl,-rpath,$ORIGIN");
    }
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("cargo sets it"));
    let dirs = [Path::new("../../desktop-qt/qml"), Path::new("../qml")];
    let files = ljos::build::Options::new()
        .with_sources()
        .compile_dirs_with_types_to_rust(&dirs, "ljostypes.json".as_ref(), &out.join("qml.pack"))
        .unwrap_or_else(|e| panic!("{e}"));
    let (mut compiled, mut total) = (0, 0);
    for f in &files {
        let all = f.compiled + f.refused.len();
        (compiled, total) = (compiled + f.compiled, total + all);
        eprintln!("{}\t{all}\t{}", f.compiled, f.key);
    }
    write_assets(&dirs, &out.join("assets.rs"));
    write_qml_files(&dirs, &out.join("qml_files.rs"));
    eprintln!("{compiled}\t{total}\tin {} files", files.len());
    for f in &files {
        for (expr, why) in &f.refused {
            eprintln!("{}#{expr}\t{why}", f.key);
        }
    }
}

/// What the QML loads besides QML and JavaScript, which the pack does not
/// carry: a release has no checkout to read them from (src/assets.rs).
const ASSETS: [&str; 15] = [
    "woff2", "woff", "ttf", "otf", "png", "jpg", "jpeg", "gif", "bmp", "svg", "webp", "glb",
    "gltf", "bin", "ktx2",
];

/// Writes `out`, a list of each asset under `dirs` as (key, bytes), the key
/// its path under its directory as the pack's keys are.
fn write_assets(dirs: &[&Path], out: &Path) {
    let mut found = Vec::new();
    for dir in dirs {
        // Its files are watched already: compile_dirs reports the directories.
        walk(dir, dir, &mut found);
    }
    found.sort();
    let mut text = String::from("&[\n");
    for (key, path) in &found {
        let path = path
            .canonicalize()
            .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        text.push_str(&format!(
            "    ({key:?}, include_bytes!({:?})),\n",
            path.display().to_string()
        ));
    }
    text.push_str("]\n");
    std::fs::write(out, text).unwrap_or_else(|e| panic!("{}: {e}", out.display()));
}

/// Writes `out`, the key of each QML file under `dirs`: what a pack that
/// compiled them all holds, so a release's `--check` can tell a file left
/// out (`hal_c2_shell::unpacked`).
fn write_qml_files(dirs: &[&Path], out: &Path) {
    let mut found = Vec::new();
    for dir in dirs {
        walk_ext(dir, dir, &["qml"], &mut found);
    }
    let mut keys: Vec<String> = found
        .into_iter()
        .map(|(key, _)| key.strip_suffix(".qml").unwrap_or(&key).to_owned())
        .collect();
    keys.sort();
    let mut text = String::from("&[\n");
    for key in &keys {
        text.push_str(&format!("    {key:?},\n"));
    }
    text.push_str("]\n");
    std::fs::write(out, text).unwrap_or_else(|e| panic!("{}: {e}", out.display()));
}

fn walk(root: &Path, dir: &Path, found: &mut Vec<(String, PathBuf)>) {
    walk_ext(root, dir, &ASSETS, found);
}

fn walk_ext(root: &Path, dir: &Path, exts: &[&str], found: &mut Vec<(String, PathBuf)>) {
    let entries = std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
    for entry in entries {
        let path = entry
            .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
            .path();
        if path.is_dir() {
            walk_ext(root, &path, exts, found);
        } else if path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| exts.iter().any(|a| e.eq_ignore_ascii_case(a)))
        {
            let key = path.strip_prefix(root).expect("under its root");
            let key = key
                .components()
                .map(|c| c.as_os_str().to_string_lossy())
                .collect::<Vec<_>>();
            found.push((key.join("/"), path));
        }
    }
}
