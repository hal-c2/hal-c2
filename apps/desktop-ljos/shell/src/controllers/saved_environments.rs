//! `savedEnvironments`, desktop-qt's SavedEnvironmentsController: the
//! environments the user paired this client with beside the one it starts
//! with. Their records and credentials are the
//! [`EnvironmentCatalog`](crate::saved_environments::EnvironmentCatalog)'s,
//! in the launch's data directory.
//!
//! desktop-ljos does not yet hold a connection of its own to each of them
//! (desktop-qt's ShellStore::addLink and McClient::setRoute,
//! hal-c2/hal-c2#1542): a saved environment whose record and credential are
//! whole is listed `closed`; one missing either is `blocked` with what is
//! missing, which no retry mends.
//!
//! Publishes `savedEnvironments`:
//!   {environments: [{id, label, origin, state: closed | blocked, message}],
//!    pairing: a link is being spent, error: why the last pairing failed ("" if
//!    it did not), damaged: where a damaged record file was set aside ("" if
//!    none)}
//! Actions: `savedEnvironments.pair {link}` pairs with the MC a pairing link
//! names and saves it (nothing is listed when its credential cannot be kept);
//! `savedEnvironments.remove {id}`, the way back out: its record and
//! credential go; `savedEnvironments.retry {id}` reads it again now.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use hal_c2_mc::pairing::{self, Client, Link, Outcome, Pairing};
use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::json::Json;
use crate::saved_environments::{
    EnvironmentCatalog, FILE, SavedEnvironment, SecretStore, system_store,
};

/// What every start reads: where the records are and the store their
/// credentials are in (the system's unless a test says).
#[derive(Default)]
struct Where {
    data_dir: RefCell<Option<PathBuf>>,
    secrets: RefCell<Option<Rc<dyn SecretStore>>>,
}

/// Says where the records are kept (the launch's data directory).
pub fn set_data_dir(engine: &Engine, dir: Option<PathBuf>) {
    *engine.extension::<Where>().data_dir.borrow_mut() = dir;
}

/// The store every later start keeps credentials in: the system's
/// ([`system_store`]) unless a test says.
pub fn set_secret_store(engine: &Engine, store: Rc<dyn SecretStore>) {
    *engine.extension::<Where>().secrets.borrow_mut() = Some(store);
}

type Exchange = Arc<dyn Fn(&Link, &Client) -> Pairing + Send + Sync>;

pub struct SavedEnvironments {
    bridge: Bridge,
    me: Me<SavedEnvironments>,
    started: bool,
    catalog: Option<EnvironmentCatalog>,
    /// Why each one it could not connect to is blocked.
    blocked: HashMap<String, String>,
    exchange: Exchange,
    device: Client,
    attempt: u64,
    pairing: bool,
    error: String,
}

impl Controller for SavedEnvironments {
    fn new(init: Init<'_, Self>) -> Self {
        SavedEnvironments {
            bridge: init.bridge,
            me: init.me,
            started: false,
            catalog: None,
            blocked: HashMap::new(),
            exchange: Arc::new(pairing::exchange),
            device: Client {
                label: "HAL-C2 desktop".into(),
                device_type: "desktop".into(),
                os: String::new(),
            },
            attempt: 0,
            pairing: false,
            error: String::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if !self.started {
            self.start(engine);
        }
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let text = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        match action {
            "savedEnvironments.pair" => self.pair(engine, &text("link")),
            "savedEnvironments.remove" => self.remove(engine, &text("id")),
            "savedEnvironments.retry" => {
                self.connect_to(&text("id"));
                self.publish(engine);
            }
            _ => return false,
        }
        true
    }
}

impl SavedEnvironments {
    /// Reads the records again, in the store set last, and connects to each.
    pub fn start(&mut self, engine: &Engine) {
        self.started = true;
        self.blocked.clear();
        let place = engine.extension::<Where>();
        let dir = place.data_dir.borrow().clone();
        let secrets = place.secrets.borrow().clone().unwrap_or_else(system_store);
        self.catalog = dir.map(|dir| EnvironmentCatalog::open(&dir.join(FILE), secrets));
        if let Some(catalog) = &self.catalog {
            if !catalog.damaged().is_empty() {
                eprintln!(
                    "[catalog] a damaged record of saved environments was set aside as {}",
                    catalog.damaged()
                );
            }
            let ids: Vec<String> = catalog
                .environments()
                .iter()
                .map(|e| e.id.clone())
                .collect();
            for id in ids {
                self.connect_to(&id);
            }
        }
        self.publish(engine);
    }

    pub fn catalog(&self) -> Option<&EnvironmentCatalog> {
        self.catalog.as_ref()
    }

    /// The name the user saved `environment_id` under; empty when none.
    pub fn label(&self, environment_id: &str) -> String {
        self.catalog
            .as_ref()
            .and_then(|c| c.find(environment_id))
            .map(|e| e.label.trim().to_owned())
            .unwrap_or_default()
    }

    /// Saves `environment` and its credential, in the place of any with its
    /// id, the way a pairing does; why it could not be saved.
    pub fn save(
        &mut self,
        engine: &Engine,
        environment: SavedEnvironment,
        credential: &str,
    ) -> Result<(), String> {
        let id = environment.id.clone();
        let Some(catalog) = &mut self.catalog else {
            return Err("Saved environments are not available yet.".into());
        };
        catalog.save(environment, credential)?;
        self.connect_to(&id);
        self.publish(engine);
        Ok(())
    }

    /// Lets a test spend pairing links without the network.
    pub fn set_exchange(&mut self, exchange: Exchange) {
        self.exchange = exchange;
    }

    fn connect_to(&mut self, id: &str) {
        let Some(catalog) = &self.catalog else {
            return;
        };
        let connection = catalog.connect(id);
        if connection.blocked.is_empty() {
            self.blocked.remove(id);
        } else {
            // Nothing to connect with: no retry can mend that.
            self.blocked.insert(id.to_owned(), connection.blocked);
        }
    }

    fn pair(&mut self, engine: &Engine, link: &str) {
        let Some(read) = pairing::read_link(link) else {
            return self.finish(
                engine,
                "That is not a pairing link. Paste the whole link the environment gave you.".into(),
            );
        };
        if self.catalog.is_none() {
            return self.finish(engine, "Saved environments are not available yet.".into());
        }
        self.attempt += 1;
        let attempt = self.attempt;
        self.pairing = true;
        self.error.clear();
        self.publish(engine);
        let exchange = self.exchange.clone();
        let device = self.device.clone();
        let me = self.me.clone();
        let spawned = ljos::task::spawn(
            engine,
            move || exchange(&read, &device),
            move |engine, result| {
                me.run(engine, move |c, engine| {
                    if attempt == c.attempt {
                        c.paired(engine, result.ok());
                    }
                });
            },
        );
        if spawned.is_err() {
            self.finish(engine, "Could not start pairing. Try again.".into());
        }
    }

    fn paired(&mut self, engine: &Engine, result: Option<Pairing>) {
        let Some(result) = result else {
            return self.finish(engine, "Could not reach the environment. Try again.".into());
        };
        if result.outcome != Outcome::Paired {
            return self.finish(engine, explain(&result));
        }
        let error = self.add(&result).err().unwrap_or_default();
        self.finish(engine, error);
    }

    /// Saves the environment a pairing paid for, in the place of any with its
    /// id; why it could not be saved.
    fn add(&mut self, result: &Pairing) -> Result<(), String> {
        let Some(catalog) = &mut self.catalog else {
            return Err("Saved environments are not available yet.".into());
        };
        let text = |key: &str| {
            result
                .descriptor
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let id = text("environmentId");
        let mut label = text("label");
        if label.is_empty() {
            label = url::Url::parse(&result.origin)
                .ok()
                .and_then(|u| u.host_str().map(str::to_owned))
                .unwrap_or_default();
        }
        catalog.save(
            SavedEnvironment {
                id: id.clone(),
                label,
                origin: result.origin.clone(),
                expires_at: String::new(),
            },
            &result.token,
        )?;
        self.connect_to(&id);
        Ok(())
    }

    fn finish(&mut self, engine: &Engine, error: String) {
        self.pairing = false;
        self.error = error;
        self.publish(engine);
    }

    fn remove(&mut self, engine: &Engine, id: &str) {
        self.blocked.remove(id);
        if let Some(catalog) = &mut self.catalog {
            catalog.forget(id);
        }
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        let environments: Vec<Json> = self
            .catalog
            .iter()
            .flat_map(|c| c.environments())
            .map(|environment| {
                let blocked = self.blocked.get(&environment.id);
                json!({
                    "id": environment.id,
                    "label": if environment.label.is_empty() { &environment.id } else { &environment.label },
                    "origin": environment.origin,
                    "state": if blocked.is_some() { "blocked" } else { "closed" },
                    "message": blocked.cloned().unwrap_or_default(),
                })
            })
            .collect();
        let damaged = self
            .catalog
            .as_ref()
            .map(|c| c.damaged().to_owned())
            .unwrap_or_default();
        self.bridge.clone().publish(
            engine,
            "savedEnvironments",
            json!({
                "environments": environments,
                "pairing": self.pairing,
                "error": self.error,
                "damaged": damaged,
            }),
        );
    }
}

/// pairing::explain: what the user is told of a pairing that did not pay.
fn explain(result: &Pairing) -> String {
    match result.outcome {
        Outcome::Paired => String::new(),
        Outcome::Unreachable => format!("Nothing answered at {}.", result.origin),
        Outcome::NotMc => format!("{} is not a HAL-C2 environment.", result.origin),
        Outcome::Incompatible => {
            "That environment runs another version of HAL-C2. Update one of them.".into()
        }
        Outcome::Refused => "The pairing link is invalid or expired. Ask for a fresh one.".into(),
    }
}
