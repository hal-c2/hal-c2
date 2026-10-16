//! What counts as a plain local folder, and where a path may reach: the
//! checks `LocalFolderModel` makes before it shows or changes anything.
//! Paths are text with `/` separators, as QML hands them over.

use std::fs;
use std::path::Path;

/// `path` is `root` or inside it. Whole components: `/ab` is not in `/a`.
pub fn within(path: &str, root: &str) -> bool {
    path == root
        || path
            .strip_prefix(root)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// `path` without doubled or trailing separators (`.` and `..` never get
/// here: [`plain_entry`] refuses them first).
pub fn clean(path: &str) -> String {
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let lead = if path.starts_with('/') { "/" } else { "" };
    format!("{lead}{}", parts.join("/"))
}

/// The folder (or, unless `directory_only`, file) at `path`, as its real
/// path; none when it is not there or any part of the way to it is a link.
///
/// Every component is checked before canonicalising: canonicalising alone
/// would hide a link that escapes the folder the user chose.
pub fn plain_entry(path: &str, directory_only: bool) -> Option<String> {
    let native = native(path);
    if native.is_empty() || native.contains('\0') || !Path::new(&native).is_absolute() {
        return None;
    }
    if native.split('/').any(|part| part == "." || part == "..") {
        return None;
    }
    let meta = fs::metadata(&native).ok()?;
    if !meta.is_dir() && (directory_only || !meta.is_file()) {
        return None;
    }
    let mut current = clean(&native);
    loop {
        if fs::symlink_metadata(&current).ok()?.is_symlink() {
            return None;
        }
        match Path::new(&current).parent() {
            Some(parent) if !parent.as_os_str().is_empty() => {
                current = parent.to_string_lossy().into_owned();
            }
            _ => break,
        }
    }
    fs::canonicalize(&native).ok().map(|p| text(&p))
}

pub fn plain_directory(path: &str) -> Option<String> {
    plain_entry(path, true)
}

/// A filesystem root or the home folder: too much to manage.
pub fn broad_directory(path: &str) -> bool {
    if Path::new(path).parent().is_none() {
        return true;
    }
    home().is_some_and(|home| home == path)
}

/// The home folder as its real path.
fn home() -> Option<String> {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))?;
    fs::canonicalize(home).ok().map(|p| text(&p))
}

/// Something is there, a dangling link included.
pub fn occupied(path: &str) -> bool {
    fs::symlink_metadata(path).is_ok()
}

pub fn text(path: &Path) -> String {
    native(&path.to_string_lossy())
}

/// `path` with `/` separators.
pub fn text_of(path: &str) -> String {
    native(path)
}

#[cfg(windows)]
fn native(path: &str) -> String {
    path.replace('\\', "/")
}

#[cfg(not(windows))]
fn native(path: &str) -> String {
    path.to_owned()
}
