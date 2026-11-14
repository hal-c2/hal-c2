//! The environments the client saved by pairing with them, beside the one it
//! starts with: desktop-qt's EnvironmentCatalog and SecretStore.
//!
//! The records sit in one file, `saved-environments.json` in the client's
//! data directory (the `desktop-ljos` level, never desktop-qt's): each one's
//! id, label, origin and when its credential expires, in desktop-qt's shape.
//! The credentials never do: they go to a [`SecretStore`] under the
//! environment's id. A record is saved only once its credential is kept, so a
//! store that refuses leaves nothing listed.
//!
//! A record file the client cannot read is not overwritten: it is moved aside
//! (`saved-environments.json.damaged-<UTC time>`) for someone to inspect, and
//! an empty one is written in its place, so the app starts with none and can
//! pair again. A record without an address, or one whose credential the store
//! no longer has, is still listed, but connecting to it is blocked with what
//! is missing ([`EnvironmentCatalog::connect`]).

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use serde_json::{Map, Value, json};

pub const FILE: &str = "saved-environments.json";
const VERSION: i64 = 1;

/// Where the client keeps the credentials of the environments it saved, out
/// of its own files: the system's secure storage. Calls may block (an unlock
/// dialog), as desktop-qt's do.
pub trait SecretStore {
    /// Keeps `secret` under `key`; why not when the store refuses.
    fn write(&self, key: &str, secret: &str) -> Result<(), String>;
    /// None when the store has none under `key`, or cannot be read.
    fn read(&self, key: &str) -> Option<String>;
    fn remove(&self, key: &str);
    /// The user asked for a credential (Retry): a store whose unlock they
    /// refused may ask them again. Reads otherwise do not ask twice.
    fn ask(&self) {}
}

/// This system's store, holding what desktop-qt holds where desktop-qt
/// holds it, so a user switching clients stays signed in: the Secret
/// Service on Linux ([`crate::secret_service`]), the login Keychain on
/// macOS, the Credential Manager on Windows. A desktop with none refuses
/// every write: a credential is never written to disk in the clear.
pub fn system_store() -> Rc<dyn SecretStore> {
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        match crate::secret_service::SecretService::session() {
            Some(store) => Rc::new(store),
            None => Rc::new(UnavailableSecretStore(Some(
                "No keyring answers on this desktop (the Secret Service: GNOME Keyring, KWallet or KeePassXC).",
            ))),
        }
    }
    #[cfg(any(target_os = "macos", windows))]
    {
        Rc::new(SystemSecretStore(ljos_secrets::SecretStore::system()))
    }
    #[cfg(not(any(unix, windows)))]
    {
        Rc::new(UnavailableSecretStore(None))
    }
}

/// desktop-qt's service name: the Keychain's service. On Windows desktop-qt's
/// targets are `HAL-C2:<id>`, `ljos_secrets`' `<id>.HAL-C2`.
///
/// TODO(hal-c2/ljos-ui#457): name Windows' targets as
/// desktop-qt does once `ljos_secrets` lets a caller.
#[cfg(any(target_os = "macos", windows))]
const SERVICE: &str = "HAL-C2";

/// `ljos_secrets`' store under desktop-qt's service name.
#[cfg(any(target_os = "macos", windows))]
struct SystemSecretStore(ljos_secrets::SecretStore);

#[cfg(any(target_os = "macos", windows))]
impl SecretStore for SystemSecretStore {
    fn write(&self, key: &str, secret: &str) -> Result<(), String> {
        self.0
            .write(SERVICE, key, secret.as_bytes())
            .map_err(|e| e.to_string())
    }
    fn read(&self, key: &str) -> Option<String> {
        let secret = self.0.read(SERVICE, key).ok()??;
        secret.as_str().map(str::to_owned)
    }
    fn remove(&self, key: &str) {
        let _ = self.0.remove(SERVICE, key);
    }
}

/// Refuses to keep anything: a system without secure storage, and why.
pub struct UnavailableSecretStore(pub Option<&'static str>);

impl SecretStore for UnavailableSecretStore {
    fn write(&self, _: &str, _: &str) -> Result<(), String> {
        Err(self
            .0
            .unwrap_or("This system has no secure storage for credentials.")
            .into())
    }
    fn read(&self, _: &str) -> Option<String> {
        None
    }
    fn remove(&self, _: &str) {}
}

/// Keeps secrets in memory, for tests: one kept across a restart is the same
/// keyring, `refusing` turns it into one not available to the app, and
/// `unreadable` into one that takes writes but gives nothing back.
#[derive(Default)]
pub struct MemorySecretStore {
    pub secrets: RefCell<HashMap<String, String>>,
    pub refusing: std::cell::Cell<bool>,
    pub unreadable: std::cell::Cell<bool>,
}

impl SecretStore for MemorySecretStore {
    fn write(&self, key: &str, secret: &str) -> Result<(), String> {
        if self.refusing.get() {
            return Err("The system's secure storage is not available.".into());
        }
        self.secrets
            .borrow_mut()
            .insert(key.to_owned(), secret.to_owned());
        Ok(())
    }
    fn read(&self, key: &str) -> Option<String> {
        if self.refusing.get() || self.unreadable.get() {
            return None;
        }
        self.secrets.borrow().get(key).cloned()
    }
    fn remove(&self, key: &str) {
        self.secrets.borrow_mut().remove(key);
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SavedEnvironment {
    pub id: String,
    pub label: String,
    /// Empty when the record does not say.
    pub origin: String,
    /// When the credential runs out (ISO 8601); empty when it never does or
    /// is unknown.
    pub expires_at: String,
}

impl SavedEnvironment {
    /// Whether the record says where the environment is.
    pub fn complete(&self) -> bool {
        !self.id.is_empty()
            && url::Url::parse(&self.origin)
                .is_ok_and(|u| u.host_str().is_some_and(|h| !h.is_empty()))
    }

    fn named(&self) -> &str {
        if self.label.is_empty() {
            &self.id
        } else {
            &self.label
        }
    }
}

/// What connecting to an environment takes: its record and credential, or
/// why it is blocked.
#[derive(Clone, Debug, Default)]
pub struct Connection {
    pub environment: SavedEnvironment,
    pub credential: String,
    pub blocked: String,
}

pub fn profile_missing(id: &str) -> String {
    format!("Connection profile {id} is unavailable.")
}

pub fn credential_missing(id: &str) -> String {
    format!("Connection credential {id} is unavailable.")
}

pub struct EnvironmentCatalog {
    path: PathBuf,
    secrets: Rc<dyn SecretStore>,
    environments: Vec<SavedEnvironment>,
    damaged: String,
}

/// The records `bytes` holds, or none when it is not a record file of this
/// version: not JSON, not an object, another version, or no list.
fn parse(bytes: &[u8]) -> Option<Vec<SavedEnvironment>> {
    let root: Map<String, Value> = serde_json::from_slice(bytes).ok()?;
    if root.get("version").and_then(Value::as_i64) != Some(VERSION) {
        return None;
    }
    let text = |record: &Value, key: &str| {
        record
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let environments = root
        .get("environments")?
        .as_array()?
        .iter()
        .map(|record| SavedEnvironment {
            id: text(record, "id"),
            label: text(record, "label"),
            origin: text(record, "origin"),
            expires_at: text(record, "expiresAt"),
        })
        // Without an id nothing can name it, not even to say it is broken.
        .filter(|environment| !environment.id.is_empty())
        .collect();
    Some(environments)
}

impl EnvironmentCatalog {
    /// The catalog at `path`, read; a damaged file is moved aside
    /// ([`EnvironmentCatalog::damaged`]).
    pub fn open(path: &Path, secrets: Rc<dyn SecretStore>) -> EnvironmentCatalog {
        let mut catalog = EnvironmentCatalog {
            path: path.to_owned(),
            secrets,
            environments: Vec::new(),
            damaged: String::new(),
        };
        catalog.load();
        catalog
    }

    fn load(&mut self) {
        self.environments.clear();
        let Ok(bytes) = std::fs::read(&self.path) else {
            return;
        };
        if let Some(parsed) = parse(&bytes) {
            self.environments = parsed;
            return;
        }
        // Kept apart as it was, never over one set aside before, and an empty
        // catalog in its place.
        let stamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%3fZ");
        let stamped = format!("{}.damaged-{stamp}", self.path.display());
        let mut aside = PathBuf::from(&stamped);
        let mut n = 2;
        while aside.exists() {
            aside = PathBuf::from(format!("{stamped}-{n}"));
            n += 1;
        }
        if std::fs::rename(&self.path, &aside).is_ok() {
            self.damaged = aside.display().to_string();
        } else {
            eprintln!(
                "[catalog] the damaged {} could not be moved aside",
                self.path.display()
            );
        }
        self.write();
    }

    pub fn environments(&self) -> &[SavedEnvironment] {
        &self.environments
    }

    pub fn find(&self, id: &str) -> Option<&SavedEnvironment> {
        self.environments.iter().find(|e| e.id == id)
    }

    /// Where the last damaged record file was moved to; empty when none was.
    pub fn damaged(&self) -> &str {
        &self.damaged
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Keeps the credential, then the record, in the place of any of the
    /// same id. Why not, for the user, when it could not; nothing changed
    /// then.
    pub fn save(&mut self, environment: SavedEnvironment, credential: &str) -> Result<(), String> {
        let named = environment.named().to_owned();
        // What the store had: one not saved leaves it as it was. None is also
        // what a store that cannot be read gives.
        let previous = self.secrets.read(&environment.id);
        if let Err(why) = self.secrets.write(&environment.id, credential) {
            return Err(format!("{named} could not be saved: {why}"));
        }
        let before = self.environments.clone();
        let id = environment.id.clone();
        self.environments.retain(|kept| kept.id != id);
        self.environments.push(environment);
        if self.write() {
            return Ok(());
        }
        self.environments = before;
        match previous {
            Some(previous) => {
                let _ = self.secrets.write(&id, &previous);
            }
            // A credential no record names is not left behind; one a record
            // names stays, since what it replaced could not be read.
            None if self.find(&id).is_none() => self.secrets.remove(&id),
            None => {}
        }
        Err(format!(
            "{named} could not be saved: the record of saved environments could not be written."
        ))
    }

    /// The record and the credential both go.
    pub fn forget(&mut self, id: &str) {
        self.secrets.remove(id);
        let before = self.environments.len();
        self.environments.retain(|kept| kept.id != id);
        if self.environments.len() != before {
            self.write();
        }
    }

    /// A renewed credential runs out at `expires_at`.
    pub fn set_expiry(&mut self, id: &str, expires_at: &str) {
        let Some(environment) = self.environments.iter_mut().find(|e| e.id == id) else {
            return;
        };
        if environment.expires_at != expires_at {
            environment.expires_at = expires_at.to_owned();
            self.write();
        }
    }

    pub fn connect(&self, id: &str) -> Connection {
        let Some(environment) = self.find(id).filter(|e| e.complete()) else {
            return Connection {
                environment: self.find(id).cloned().unwrap_or(SavedEnvironment {
                    id: id.to_owned(),
                    ..SavedEnvironment::default()
                }),
                credential: String::new(),
                blocked: profile_missing(id),
            };
        };
        match self.secrets.read(id).filter(|c| !c.is_empty()) {
            Some(credential) => Connection {
                environment: environment.clone(),
                credential,
                blocked: String::new(),
            },
            None => Connection {
                environment: environment.clone(),
                credential: String::new(),
                blocked: credential_missing(id),
            },
        }
    }

    /// The file, replaced whole: a crash leaves the old one or the new one.
    fn write(&self) -> bool {
        let records: Vec<Value> = self
            .environments
            .iter()
            .map(|environment| {
                let mut record = json!({"id": environment.id, "label": environment.label});
                if !environment.origin.is_empty() {
                    record["origin"] = json!(environment.origin);
                }
                if !environment.expires_at.is_empty() {
                    record["expiresAt"] = json!(environment.expires_at);
                }
                record
            })
            .collect();
        let body = json!({"version": VERSION, "environments": records});
        let Some(dir) = self.path.parent() else {
            return false;
        };
        if std::fs::create_dir_all(dir).is_err() {
            return false;
        }
        let partial = self.path.with_extension("json.partial");
        let Ok(text) = serde_json::to_vec_pretty(&body) else {
            return false;
        };
        std::fs::write(&partial, text).is_ok() && std::fs::rename(&partial, &self.path).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn studio() -> SavedEnvironment {
        SavedEnvironment {
            id: "studio".into(),
            label: "Studio".into(),
            origin: "http://studio:3773".into(),
            expires_at: String::new(),
        }
    }

    #[test]
    fn a_refused_credential_leaves_nothing_listed() {
        let dir = tempfile::tempdir().unwrap();
        let store = Rc::new(MemorySecretStore::default());
        store.refusing.set(true);
        let mut catalog = EnvironmentCatalog::open(&dir.path().join(FILE), store.clone());
        let refused = catalog.save(studio(), "secret").unwrap_err();
        assert_eq!(
            refused,
            "Studio could not be saved: The system's secure storage is not available."
        );
        assert!(catalog.environments().is_empty());
        assert!(!dir.path().join(FILE).exists());
    }

    #[test]
    fn a_damaged_file_is_set_aside_and_replaced_by_an_empty_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        std::fs::write(&path, b"{\"version\": 1, \"environments\": [{\"id\"").unwrap();
        let catalog = EnvironmentCatalog::open(&path, Rc::new(MemorySecretStore::default()));
        assert!(catalog.environments().is_empty());
        let aside = std::fs::read(catalog.damaged()).unwrap();
        assert_eq!(aside, b"{\"version\": 1, \"environments\": [{\"id\"");
        let written: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(written, json!({"version": 1, "environments": []}));
    }

    #[test]
    fn what_is_missing_blocks_the_connection() {
        let dir = tempfile::tempdir().unwrap();
        let store = Rc::new(MemorySecretStore::default());
        let mut catalog = EnvironmentCatalog::open(&dir.path().join(FILE), store.clone());
        assert_eq!(catalog.connect("studio").blocked, profile_missing("studio"));
        catalog.save(studio(), "secret").unwrap();
        assert_eq!(catalog.connect("studio").credential, "secret");
        store.remove("studio");
        assert_eq!(
            catalog.connect("studio").blocked,
            credential_missing("studio")
        );
    }
}
