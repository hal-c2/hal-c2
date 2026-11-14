//! `savedEnvironments`, desktop-qt's SavedEnvironmentsController: the
//! environments the user paired this client with beside the one it starts
//! with. Their records and credentials are the
//! [`EnvironmentCatalog`](crate::saved_environments::EnvironmentCatalog)'s,
//! in the launch's data directory.
//!
//! Each saved environment has a connection of its own (a link, from
//! [`Mc::spawn_link`]): the store lists what it serves beside the shell's own
//! ([`store::add_link`]), and the shell's calls and subscriptions for it go
//! through it ([`Mc::set_route`]). One whose record or credential is missing
//! is `blocked` with what is missing, which no retry mends.
//!
//! Publishes `savedEnvironments`:
//!   {environments: [{id, label, origin, state: connected | connecting |
//!    reconnecting | offline | refused | blocked | closed, message}],
//!    pairing: a link is being spent, error: why the last pairing failed ("" if
//!    it did not), damaged: where a damaged record file was set aside ("" if
//!    none)}
//! Actions: `savedEnvironments.pair {link}` pairs with the MC a pairing link
//! names and saves it (nothing is listed when its credential cannot be kept);
//! `savedEnvironments.remove {id}`, the way back out: its connection, record
//! and credential go; `savedEnvironments.retry {id}` tries its connection
//! again now, or reads its credential again (asking the keyring anew).

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use chrono::{DateTime, SecondsFormat, Utc};
use hal_c2_mc::Phase;
use hal_c2_mc::pairing::{self, Client, Link, Outcome, Pairing};
use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::json::Json;
use crate::mc::Mc;
use crate::saved_environments::{
    EnvironmentCatalog, FILE, SavedEnvironment, SecretStore, system_store,
};
use crate::store;

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

/// A saved environment's connection, and which one it is: a status from a
/// link since replaced is not its successor's.
#[derive(Clone)]
struct Linked {
    mc: Rc<dyn Mc>,
    generation: u64,
}

type Links = Rc<RefCell<HashMap<String, Linked>>>;

pub struct SavedEnvironments {
    bridge: Bridge,
    me: Me<SavedEnvironments>,
    /// The shell's own connection: links are spawned from it and it routes
    /// to them.
    mc: Rc<dyn Mc>,
    links: Links,
    generation: Cell<u64>,
    secrets: Option<Rc<dyn SecretStore>>,
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
        let links: Links = Rc::default();
        // What the shell asks of a saved environment goes to its connection.
        let weak = init.engine.downgrade();
        let routes = links.clone();
        init.mc.set_route(Rc::new(move |environment, mc| {
            let engine = weak.upgrade()?;
            let served = store::get(&engine).and_then(|s| {
                let s = s.try_borrow().ok()?;
                if mc.is_empty() {
                    s.link_serving(environment)
                } else {
                    s.link_of(mc)
                }
            });
            if !mc.is_empty() && served.is_none() {
                return None;
            }
            let id = served.unwrap_or_else(|| environment.to_owned());
            let links = routes.try_borrow().ok()?;
            links.get(&id).map(|l| l.mc.clone())
        }));
        SavedEnvironments {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            links,
            generation: Cell::new(0),
            secrets: None,
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
                let id = text("id");
                let link = self.link(&id);
                if let Some(link) = link {
                    link.retry_now();
                } else {
                    if let Some(secrets) = &self.secrets {
                        secrets.ask();
                    }
                    self.connect_to(engine, &id);
                }
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
        let ids: Vec<String> = self.links.borrow().keys().cloned().collect();
        for id in ids {
            self.disconnect(engine, &id, false);
        }
        self.blocked.clear();
        let place = engine.extension::<Where>();
        let dir = place.data_dir.borrow().clone();
        let secrets = place.secrets.borrow().clone().unwrap_or_else(system_store);
        self.secrets = Some(secrets.clone());
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
                self.connect_to(engine, &id);
            }
        }
        self.publish(engine);
    }

    /// The connection to `id`, while it has one.
    pub fn link(&self, id: &str) -> Option<Rc<dyn Mc>> {
        self.links.borrow().get(id).map(|l| l.mc.clone())
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
        self.connect_to(engine, &id);
        self.publish(engine);
        Ok(())
    }

    /// Lets a test spend pairing links without the network.
    pub fn set_exchange(&mut self, exchange: Exchange) {
        self.exchange = exchange;
    }

    /// Connects to `id` anew, or says why it cannot.
    fn connect_to(&mut self, engine: &Engine, id: &str) {
        let Some(catalog) = &self.catalog else {
            return;
        };
        let connection = catalog.connect(id);
        self.disconnect(engine, id, false);
        if !connection.blocked.is_empty() {
            // Nothing to connect with: no retry can mend that.
            self.blocked.insert(id.to_owned(), connection.blocked);
            return;
        }
        self.blocked.remove(id);
        // Its timings are the shell's own (tests shorten them there).
        let Some(link) = self.mc.spawn_link() else {
            return;
        };
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        link.set_credential_expiry(expiry(&connection.environment.expires_at));
        let me = self.me.clone();
        let owner = id.to_owned();
        link.on_status(Box::new(move |engine, _| {
            let owner = owner.clone();
            me.run_after(engine, move |c, engine| {
                c.status_changed(engine, &owner, generation)
            });
        }));
        self.links.borrow_mut().insert(
            id.to_owned(),
            Linked {
                mc: link.clone(),
                generation,
            },
        );
        store::add_link(engine, id, link.clone());
        let environment = &connection.environment;
        if let Err(error) = link.open_expecting(&environment.origin, &connection.credential, id) {
            self.blocked.insert(id.to_owned(), error);
            self.disconnect(engine, id, false);
        }
    }

    /// Ends the connection to `id`; with `forget`, what it listed goes too.
    fn disconnect(&mut self, engine: &Engine, id: &str, forget: bool) {
        let Some(link) = self.links.borrow_mut().remove(id) else {
            return;
        };
        store::remove_link(engine, id, forget);
        link.mc.close();
    }

    /// A status from the link `generation` of `id`: a renewed credential is
    /// kept, and the state shown again.
    fn status_changed(&mut self, engine: &Engine, id: &str, generation: u64) {
        let Some(link) = self.links.borrow().get(id).cloned() else {
            return;
        };
        if link.generation != generation {
            return;
        }
        if let (Some(catalog), Some(expires_at)) = (&mut self.catalog, link.mc.credential_expiry())
        {
            let saved = catalog.find(id).map(|e| expiry(&e.expires_at));
            if saved.is_some_and(|saved| saved != Some(expires_at)) {
                catalog.set_expiry(id, &expires_at.to_rfc3339_opts(SecondsFormat::Millis, true));
            }
        }
        self.publish(engine);
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
        let error = self.add(engine, &result).err().unwrap_or_default();
        self.finish(engine, error);
    }

    /// Saves the environment a pairing paid for, in the place of any with its
    /// id; why it could not be saved.
    fn add(&mut self, engine: &Engine, result: &Pairing) -> Result<(), String> {
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
        self.connect_to(engine, &id);
        Ok(())
    }

    fn finish(&mut self, engine: &Engine, error: String) {
        self.pairing = false;
        self.error = error;
        self.publish(engine);
    }

    fn remove(&mut self, engine: &Engine, id: &str) {
        self.disconnect(engine, id, true);
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
                let (state, message) = match self.blocked.get(&environment.id) {
                    Some(blocked) => ("blocked", blocked.clone()),
                    None => match self.link(&environment.id) {
                        Some(link) => {
                            let status = link.status();
                            let ready = status.phase == Phase::Ready;
                            let message = if ready { String::new() } else { status.failure_message };
                            (state(status.phase), message)
                        }
                        None => ("closed", String::new()),
                    },
                };
                json!({
                    "id": environment.id,
                    "label": if environment.label.is_empty() { &environment.id } else { &environment.label },
                    "origin": environment.origin,
                    "state": state,
                    "message": message,
                })
            })
            .collect();
        let damaged = self
            .catalog
            .as_ref()
            .map(|c| c.damaged().to_owned())
            .unwrap_or_default();
        self.bridge.publish(
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

impl Drop for SavedEnvironments {
    fn drop(&mut self) {
        self.mc.set_route(Rc::new(|_, _| None));
        for (_, link) in self.links.borrow_mut().drain() {
            link.mc.close();
        }
    }
}

/// What a saved environment's connection shows as its state.
fn state(phase: Phase) -> &'static str {
    match phase {
        Phase::Ready => "connected",
        Phase::Connecting => "connecting",
        Phase::Retrying => "reconnecting",
        Phase::Offline => "offline",
        Phase::Refused => "refused",
        Phase::Blocked => "blocked",
        Phase::Closed => "closed",
    }
}

/// A saved credential's expiry; None when it has none (or it is unreadable).
fn expiry(expires_at: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(expires_at)
        .ok()
        .map(|t| t.with_timezone(&Utc))
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
