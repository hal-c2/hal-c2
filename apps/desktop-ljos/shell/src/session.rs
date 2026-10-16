//! The MC this client paired with, kept so a later start reconnects without
//! pairing again: `<data>/pairing.json`, as the phone keeps its own
//! (apps/mobile-qt Pairing.cpp), readable by its owner only since the token
//! is a session's credential.

use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const FILE: &str = "pairing.json";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub origin: String,
    pub token: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub environment_id: String,
}

pub fn path(data_dir: &Path) -> PathBuf {
    data_dir.join(FILE)
}

/// The session kept in `data_dir`; none when there is none, or it names no
/// MC or no token.
pub fn load(data_dir: &Path) -> Option<Session> {
    let text = std::fs::read(path(data_dir)).ok()?;
    serde_json::from_slice::<Session>(&text)
        .ok()
        .filter(|s| !s.origin.is_empty() && !s.token.is_empty())
}

/// Keeps `session` in `data_dir`, replacing the one there whole: a crash
/// leaves the old one or the new one, never half of either.
pub fn save(data_dir: &Path, session: &Session) -> std::io::Result<()> {
    std::fs::create_dir_all(data_dir)?;
    let target = path(data_dir);
    let partial = data_dir.join(format!("{FILE}.partial"));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&partial)?;
    // A partial file left by an older run keeps its mode; this one is the
    // owner's only either way.
    #[cfg(unix)]
    std::fs::set_permissions(
        &partial,
        std::os::unix::fs::PermissionsExt::from_mode(0o600),
    )?;
    file.write_all(&serde_json::to_vec_pretty(session).map_err(std::io::Error::other)?)?;
    file.sync_all()?;
    std::fs::rename(&partial, &target)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> Session {
        Session {
            origin: "http://127.0.0.1:3773".into(),
            token: "t".into(),
            label: "Laptop".into(),
            environment_id: "env-1".into(),
        }
    }

    #[test]
    fn a_kept_session_is_read_back() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load(dir.path()), None);
        save(&dir.path().join("data"), &session()).unwrap();
        assert_eq!(load(&dir.path().join("data")), Some(session()));
        let text = std::fs::read_to_string(dir.path().join("data").join(FILE)).unwrap();
        assert!(text.contains("\"environmentId\": \"env-1\""), "{text}");
    }

    #[cfg(unix)]
    #[test]
    fn only_its_owner_reads_it() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        save(dir.path(), &session()).unwrap();
        let mode = std::fs::metadata(path(dir.path()))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn one_without_a_token_is_none() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(path(dir.path()), r#"{"origin":"http://h","token":""}"#).unwrap();
        assert_eq!(load(dir.path()), None);
        std::fs::write(path(dir.path()), "not json").unwrap();
        assert_eq!(load(dir.path()), None);
    }
}
