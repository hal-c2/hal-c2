//! The capture sounds, played by the desktop's own player: there is no audio
//! module, and the players read files, so each sound is unpacked into the
//! cache once.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// desktop-qt's copies, so there is one recording of each.
const WHOOSH: &[u8] =
    include_bytes!("../../../../desktop-qt/src/native/sounds/snap-shot-whoosh.oga");
const CLICK: &[u8] = include_bytes!("../../../../desktop-qt/src/native/sounds/snap-shot-click.oga");

/// The sound's file name and what it holds: `camera-shutter` is Click, any
/// other name Whoosh.
fn sound(name: &str) -> (&'static str, &'static [u8]) {
    if name == "camera-shutter" {
        ("snap-shot-click.oga", CLICK)
    } else {
        ("snap-shot-whoosh.oga", WHOOSH)
    }
}

/// Where the sound is unpacked in `dir`, unpacking it when it is not there.
fn unpack(dir: &Path, name: &str) -> Option<PathBuf> {
    let (file, bytes) = sound(name);
    let path = dir.join(file);
    if path.exists() {
        return Some(path);
    }
    std::fs::create_dir_all(dir).ok()?;
    // Written whole beside the name, so a player never reads half a sound.
    let partial = dir.join(format!("{file}.{}.part", std::process::id()));
    std::fs::write(&partial, bytes).ok()?;
    if std::fs::rename(&partial, &path).is_err() {
        let _ = std::fs::remove_file(&partial);
        return path.exists().then_some(path);
    }
    Some(path)
}

/// The first of the desktop's players on PATH, and how it is asked to play
/// `path`.
fn player(
    path: &Path,
    path_var: Option<std::ffi::OsString>,
) -> Option<(PathBuf, Vec<std::ffi::OsString>)> {
    let found = |name: &str| {
        std::env::split_paths(path_var.as_deref()?)
            .map(|dir| dir.join(name))
            .find(|candidate| candidate.is_file())
    };
    let file = path.as_os_str().to_owned();
    if let Some(player) = found("pw-play") {
        return Some((player, vec![file]));
    }
    if let Some(player) = found("paplay") {
        return Some((player, vec![file]));
    }
    found("canberra-gtk-play").map(|player| (player, vec!["-f".into(), file]))
}

/// Plays the capture sound `name` (`soft-pop` or `camera-shutter`) from
/// `dir`, a cache directory; silent without one or without a player.
pub fn play(dir: Option<&Path>, name: &str) {
    let Some(path) = dir.and_then(|dir| unpack(dir, name)) else {
        return;
    };
    let Some((player, arguments)) = player(&path, std::env::var_os("PATH")) else {
        return;
    };
    let child = Command::new(player)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(mut child) = child {
        // Reaped where it cannot hold the caller up.
        std::thread::spawn(move || child.wait());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_sound_is_unpacked_once_under_its_name() {
        let dir = tempfile::tempdir().unwrap();
        let click = unpack(dir.path(), "camera-shutter").unwrap();
        let whoosh = unpack(dir.path(), "soft-pop").unwrap();
        assert!(click.ends_with("snap-shot-click.oga"));
        assert!(whoosh.ends_with("snap-shot-whoosh.oga"));
        assert_eq!(std::fs::read(&click).unwrap(), CLICK);
        assert_eq!(std::fs::read(&whoosh).unwrap(), WHOOSH);
        // A sound that is there is not written again.
        std::fs::write(&click, b"kept").unwrap();
        assert_eq!(unpack(dir.path(), "camera-shutter").unwrap(), click);
        assert_eq!(std::fs::read(&click).unwrap(), b"kept");
        // An unknown name is the Whoosh, as desktop-qt plays it.
        assert_eq!(unpack(dir.path(), "").unwrap(), whoosh);
    }

    #[test]
    fn the_player_is_the_first_the_path_has() {
        let bin = tempfile::tempdir().unwrap();
        let path = std::env::join_paths([bin.path()]).unwrap();
        let sound = Path::new("/cache/snap-shot-click.oga");
        assert!(player(sound, Some(path.clone())).is_none());
        std::fs::write(bin.path().join("canberra-gtk-play"), b"").unwrap();
        let (found, arguments) = player(sound, Some(path.clone())).unwrap();
        assert!(found.ends_with("canberra-gtk-play"));
        assert_eq!(arguments, ["-f", "/cache/snap-shot-click.oga"]);
        std::fs::write(bin.path().join("paplay"), b"").unwrap();
        let (found, arguments) = player(sound, Some(path.clone())).unwrap();
        assert!(found.ends_with("paplay"));
        assert_eq!(arguments, ["/cache/snap-shot-click.oga"]);
        std::fs::write(bin.path().join("pw-play"), b"").unwrap();
        assert!(player(sound, Some(path)).unwrap().0.ends_with("pw-play"));
        assert!(player(sound, None).is_none());
    }
}
