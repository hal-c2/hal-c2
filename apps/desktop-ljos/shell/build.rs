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
    eprintln!("{compiled}\t{total}\tin {} files", files.len());
    for f in &files {
        for (expr, why) in &f.refused {
            eprintln!("{}#{expr}\t{why}", f.key);
        }
    }
}
