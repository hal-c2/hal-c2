//! Compiles the phone's QML (the bricks, this app's entry and stubs, and
//! mobile-qt's `HalC2.Mobile`, as `hal_c2_mobile::roots` lays them out)
//! into the pack the app runs, `$OUT_DIR/qml.pack`
//! (`hal_c2_mobile::pack`), and its bindings and handlers to Rust in
//! `$OUT_DIR/qml.rs`, against the native types desktop-ljos's
//! `ljostypes.json` describes — as desktop-ljos's build.rs, whose pack
//! carries its sources for the user's files in the config dir
//! (`App::user_qml`). The files beside the bricks' QML (fonts, icons,
//! models) are desktop-ljos's assets list's, built in by its build.rs
//! and installed by `hal_c2_shell::start_with`; the phone's own QML
//! directories carry no such files.
//!
//! On stderr (`build/hal_c2_mobile-*/stderr` in the target directory):
//! each file's compiled and total expressions, the totals, then why
//! each of the rest runs dynamically.

use std::path::{Path, PathBuf};

fn main() {
    // hal-c2-mobile-ljos and its web engine helper find CEF's libcef.so
    // beside themselves, where the cef crate copies it (Cargo.toml), as
    // desktop-ljos's bins do.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo::rustc-link-arg-bins=-Wl,-rpath,$ORIGIN");
    }
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("cargo sets it"));
    let dirs = [
        Path::new("../desktop-qt/qml"),
        Path::new("qml"),
        Path::new("../mobile-qt/qml"),
    ];
    let files = ljos::build::Options::new()
        .with_sources()
        .compile_dirs_with_types_to_rust(
            &dirs,
            "../desktop-ljos/shell/ljostypes.json".as_ref(),
            &out.join("qml.pack"),
        )
        .unwrap_or_else(|e| panic!("{e}"));
    let (mut compiled, mut total) = (0, 0);
    for f in &files {
        let all = f.compiled + f.refused.len();
        (compiled, total) = (compiled + f.compiled, total + all);
        eprintln!("{}\t{all}\t{}", f.compiled, f.key);
    }
    write_qml_files(&dirs, &out.join("qml_files.rs"));
    eprintln!("{compiled}\t{total}\tin {} files", files.len());
    for f in &files {
        for (expr, why) in &f.refused {
            eprintln!("{}#{expr}\t{why}", f.key);
        }
    }
}

/// Writes `out`, the key of each QML file under `dirs`: what a pack that
/// compiled them all holds, so a release's `--check` can tell a file left
/// out (`hal_c2_mobile::unpacked`), as desktop-ljos's build.rs.
fn write_qml_files(dirs: &[&Path], out: &Path) {
    let mut found = Vec::new();
    for dir in dirs {
        walk(dir, dir, &mut found);
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
    let entries = std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
    for entry in entries {
        let path = entry
            .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
            .path();
        if path.is_dir() {
            walk(root, &path, found);
        } else if path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("qml"))
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
