//! Compiles the bindings and handlers of the checkout's QML (the bricks and
//! `qml/`, as `Roots::checkout` lays them out) to Rust in `$OUT_DIR/qml.rs`,
//! against the native types `ljostypes.json` describes (tests/shell_tree.rs
//! keeps it current). The shell still compiles the QML from the directories
//! at start-up; a file runs this code while it is the file the code was made
//! from, and dynamically once edited.
//!
//! On stderr (`build/hal_c2_shell-*/stderr` in the target directory): each
//! file's compiled and total expressions, the totals, then why each of the
//! rest runs dynamically.

use std::path::{Path, PathBuf};

fn main() {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("cargo sets it"));
    let dirs = [Path::new("../../desktop-qt/qml"), Path::new("../qml")];
    let files = ljos::build::compile_dirs_with_types_to_rust(
        &dirs,
        "ljostypes.json".as_ref(),
        &out.join("qml.pack"),
    )
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
