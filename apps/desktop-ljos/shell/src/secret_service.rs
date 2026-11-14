//! The Secret Service (freedesktop.org) on the session bus, holding saved
//! environments' credentials the way desktop-qt's SecretServiceStore does, so
//! either client reads what the other kept: items of the default collection
//! with the attributes `application` = `HAL-C2` and `environment` = the id,
//! labelled `HAL-C2 environment <id>`, sent in the `plain` transport.
//!
//! TODO(hal-c2/ljos-ui#457): `ljos_secrets` names its items
//! `service`/`username`, which desktop-qt's are not; once a caller can name
//! them, this goes and `ljos_secrets::SecretService` takes its place.
//!
//! Calls block, as desktop-qt's do: an unlock dialog waits for the user.

use std::cell::Cell;
use std::collections::HashMap;
use std::time::Duration;

use zbus::blocking::fdo::DBusProxy;
use zbus::blocking::{Connection, MessageIterator, connection};
use zbus::message::Type as MessageType;
use zbus::zvariant::{DynamicDeserialize, DynamicType, OwnedObjectPath, OwnedValue, Value};
use zbus::{MatchRule, Message};

use crate::saved_environments::SecretStore;

const BUS_NAME: &str = "org.freedesktop.secrets";
const SERVICE_PATH: &str = "/org/freedesktop/secrets";
const SERVICE: &str = "org.freedesktop.Secret.Service";
const COLLECTION: &str = "org.freedesktop.Secret.Collection";
const ITEM: &str = "org.freedesktop.Secret.Item";
const PROMPT: &str = "org.freedesktop.Secret.Prompt";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
/// The spec's "no object": no prompt, or no collection with the alias.
const NONE: &str = "/";
const APPLICATION: &str = "HAL-C2";
/// How long one call may take; the user answering a prompt is not a call.
const REPLY_WAIT: Duration = Duration::from_secs(25);

type WireSecret = (OwnedObjectPath, Vec<u8>, Vec<u8>, String);

/// The Secret Service store.
pub struct SecretService {
    address: Option<String>,
    /// One refused unlock answers for every read after it, so the saved
    /// environments read at start ask once, not once each; [`ask`] and a
    /// write (pairing, the user's own act) clear it.
    ///
    /// [`ask`]: SecretStore::ask
    refused: Cell<bool>,
}

impl SecretService {
    /// The store on the user's session bus, when a Secret Service answers
    /// there.
    pub fn session() -> Option<SecretService> {
        let store = SecretService {
            address: None,
            refused: Cell::new(false),
        };
        store.available().then_some(store)
    }

    /// The store on the bus at `address` (a test's own bus).
    pub fn at_address(address: impl Into<String>) -> SecretService {
        SecretService {
            address: Some(address.into()),
            refused: Cell::new(false),
        }
    }

    fn bus(&self) -> Result<Connection, String> {
        let builder = match &self.address {
            Some(address) => connection::Builder::address(address.as_str()),
            None => connection::Builder::session(),
        };
        builder
            .and_then(|b| b.method_timeout(REPLY_WAIT).build())
            .map_err(|e| e.to_string())
    }

    fn available(&self) -> bool {
        let Ok(bus) = self.bus() else {
            return false;
        };
        DBusProxy::new(&bus)
            .and_then(|proxy| {
                proxy
                    .name_has_owner(BUS_NAME.try_into()?)
                    .map_err(Into::into)
            })
            .unwrap_or(false)
    }
}

fn attributes(key: &str) -> HashMap<&'static str, &str> {
    HashMap::from([("application", APPLICATION), ("environment", key)])
}

/// A connection and its `plain` session.
struct Session {
    bus: Connection,
    path: OwnedObjectPath,
}

impl Session {
    fn open(bus: Connection) -> Result<Session, String> {
        let (_, path): (OwnedValue, OwnedObjectPath) = reply(&call(
            &bus,
            SERVICE_PATH,
            SERVICE,
            "OpenSession",
            &("plain", Value::from("")),
        )?)?;
        Ok(Session { bus, path })
    }

    fn default_collection(&self) -> Result<OwnedObjectPath, String> {
        let collection: OwnedObjectPath = reply(&call(
            &self.bus,
            SERVICE_PATH,
            SERVICE,
            "ReadAlias",
            &("default",),
        )?)?;
        if collection.as_str() == NONE {
            return Err("The system's keyring has no default collection.".into());
        }
        Ok(collection)
    }

    /// Every item of `key`, unlocked or not.
    fn search(&self, key: &str) -> Vec<OwnedObjectPath> {
        let found = call(
            &self.bus,
            SERVICE_PATH,
            SERVICE,
            "SearchItems",
            &(attributes(key),),
        )
        .and_then(|m| reply::<(Vec<OwnedObjectPath>, Vec<OwnedObjectPath>)>(&m));
        match found {
            Ok((mut unlocked, locked)) => {
                unlocked.extend(locked);
                unlocked
            }
            Err(_) => Vec::new(),
        }
    }

    /// Unlocks `objects`, asking the user when the service says to; an
    /// error when any is still locked after.
    fn unlock(&self, objects: &[OwnedObjectPath], interface: &str) -> Result<(), String> {
        let (_, prompt): (Vec<OwnedObjectPath>, OwnedObjectPath) = reply(&call(
            &self.bus,
            SERVICE_PATH,
            SERVICE,
            "Unlock",
            &(objects,),
        )?)?;
        self.prompt(&prompt)?;
        if objects.iter().any(|o| self.locked(o, interface)) {
            return Err("The system's keyring was not unlocked.".into());
        }
        Ok(())
    }

    fn locked(&self, object: &OwnedObjectPath, interface: &str) -> bool {
        call(
            &self.bus,
            object.as_str(),
            PROPERTIES,
            "Get",
            &(interface, "Locked"),
        )
        .and_then(|m| reply::<OwnedValue>(&m))
        .ok()
        .and_then(|v| bool::try_from(v).ok())
        .unwrap_or(true)
    }

    /// Shows the prompt at `path`, if any, and waits for the user to answer
    /// it or the service to go. Callers check what it did.
    fn prompt(&self, path: &OwnedObjectPath) -> Result<(), String> {
        if path.as_str() == NONE || path.as_str().is_empty() {
            return Ok(());
        }
        let completed = MatchRule::builder()
            .msg_type(MessageType::Signal)
            .path(path.as_str())
            .and_then(|b| b.interface(PROMPT))
            .and_then(|b| b.member("Completed"))
            .map_err(|e| e.to_string())?
            .build();
        let gone = MatchRule::builder()
            .msg_type(MessageType::Signal)
            .sender("org.freedesktop.DBus")
            .and_then(|b| b.interface("org.freedesktop.DBus"))
            .and_then(|b| b.member("NameOwnerChanged"))
            .and_then(|b| b.arg(0, BUS_NAME))
            .map_err(|e| e.to_string())?
            .build();
        // Made before the prompt shows, so its answer cannot be missed.
        let messages = MessageIterator::from(&self.bus);
        let proxy = DBusProxy::new(&self.bus).map_err(|e| e.to_string())?;
        proxy
            .add_match_rule(completed.clone())
            .and_then(|()| proxy.add_match_rule(gone.clone()))
            .map_err(|e| e.to_string())?;
        call(&self.bus, path.as_str(), PROMPT, "Prompt", &("",))?;
        for message in messages {
            let message = message.map_err(|e| e.to_string())?;
            if completed.matches(&message).unwrap_or(false)
                || gone.matches(&message).unwrap_or(false)
            {
                return Ok(());
            }
        }
        Ok(())
    }
}

impl SecretStore for SecretService {
    fn write(&self, key: &str, secret: &str) -> Result<(), String> {
        self.refused.set(false);
        let session = Session::open(self.bus()?)?;
        let collection = session.default_collection()?;
        session.unlock(std::slice::from_ref(&collection), COLLECTION)?;
        let properties = HashMap::from([
            (
                "org.freedesktop.Secret.Item.Label",
                Value::from(format!("HAL-C2 environment {key}")),
            ),
            (
                "org.freedesktop.Secret.Item.Attributes",
                Value::from(attributes(key)),
            ),
        ]);
        let wire = (
            &session.path,
            Vec::<u8>::new(),
            secret.as_bytes(),
            "text/plain",
        );
        let (_, prompt): (OwnedObjectPath, OwnedObjectPath) = reply(&call(
            &session.bus,
            collection.as_str(),
            COLLECTION,
            "CreateItem",
            &(properties, wire, true),
        )?)?;
        session.prompt(&prompt)?;
        if session.search(key).is_empty() {
            return Err("The system's keyring did not keep the credential.".into());
        }
        Ok(())
    }

    fn read(&self, key: &str) -> Option<String> {
        if self.refused.get() {
            return None;
        }
        let session = Session::open(self.bus().ok()?).ok()?;
        let items = session.search(key);
        let item = items.first()?;
        if session.unlock(&items, ITEM).is_err() {
            self.refused.set(true);
            return None;
        }
        let (_, _, value, _): WireSecret = reply(
            &call(
                &session.bus,
                item.as_str(),
                ITEM,
                "GetSecret",
                &(&session.path,),
            )
            .ok()?,
        )
        .ok()?;
        String::from_utf8(value).ok()
    }

    fn remove(&self, key: &str) {
        let Ok(session) = self.bus().and_then(Session::open) else {
            return;
        };
        for item in session.search(key) {
            if let Ok(prompt) = call(&session.bus, item.as_str(), ITEM, "Delete", &())
                .and_then(|m| reply::<OwnedObjectPath>(&m))
            {
                let _ = session.prompt(&prompt);
            }
        }
    }

    fn ask(&self) {
        self.refused.set(false);
    }
}

fn call<B>(
    bus: &Connection,
    path: &str,
    interface: &str,
    method: &str,
    body: &B,
) -> Result<Message, String>
where
    B: zbus::export::serde::Serialize + DynamicType,
{
    bus.call_method(Some(BUS_NAME), path, Some(interface), method, body)
        .map_err(|e| e.to_string())
}

fn reply<R>(message: &Message) -> Result<R, String>
where
    R: for<'d> DynamicDeserialize<'d>,
{
    message.body().deserialize().map_err(|e| e.to_string())
}
