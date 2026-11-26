//! `pairing`, mobile-qt's Pairing: the environments the phone is paired
//! with. A phone runs no MC and has no host process to hand it one, so it
//! pairs by itself: it reads a pairing link, spends its token on a
//! session with the MC there (`hal_c2_mc::pairing`, desktop-qt's
//! PairingExchange), and keeps that session between runs.
//!
//! The first environment is the shell's own connection, kept here
//! (`pairing.json`). Every other one is paired beside it, as the desktop
//! pairs with other machines: the shell's SavedEnvironments keeps it and
//! gives it a connection of its own. Pairing with the shell's own
//! environment again only renews its session. Forgetting the shell's own
//! puts the first one paired beside it in its place, so the phone is
//! paired while it has any.
//!
//! Publishes `pairing`:
//!   {phase:   unpaired | pairing | paired,
//!    error:   a sentence for the user, "" when none,
//!    link:    what the user last entered or was handed, kept after a
//!             failure, "" once paired,
//!    origin:  the paired MC's origin, "" when unpaired,
//!    label:   the paired MC's label from its descriptor, "" when unpaired,
//!    adding:  a paired device shows the pairing screen, to pair with another,
//!    offered: the address `link` would pair with, while it is a link from
//!             outside the app that waits for the user; "" otherwise}
//!
//! Actions: `pairing.pair {link}`, `pairing.add`, `pairing.cancel`,
//! `pairing.askToForget {id}` (the shell's question first, then the
//! forget) and `pairing.forget {id}`; `id` is one paired beside the
//! shell's own, or none for that one.
//!
//! A session is on the device before the phone says it is paired with it
//! or connects with it. One that cannot be saved is said in `error`, with
//! the link kept and the environments the device had left as they were,
//! though the link is spent.
//!
//! A link from outside the app ([`offer_link`]) is anybody's: it is never
//! paired with by itself. It is put in the pairing screen's field with
//! the address it leads to (`offered`), and the user's own `pairing.pair`
//! is what spends it.
//!
//! [`Core`] is the state machine with no engine and no disk in it; the
//! controller around it does the exchange, the saving and the opening.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use hal_c2_mc::pairing::{self, Client, Link, Outcome, Pairing as Exchanged};
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{self, Controller, Init, Me};
use hal_c2_shell::controllers::connection_health::ConnectionHealth;
use hal_c2_shell::controllers::menus::Menus;
use hal_c2_shell::controllers::saved_environments::SavedEnvironments;
use hal_c2_shell::controllers::toasts::Toasts;
use hal_c2_shell::json::Json;
use hal_c2_shell::saved_environments::SavedEnvironment;
use hal_c2_shell::session::Session;
use ljos::prelude::Engine;
use serde_json::json;

const KEY: &str = "pairing";

/// Spends a pairing link's token on a session; blocking, so it runs off
/// the UI thread (as SavedEnvironments' own pairing).
pub type Exchange = Arc<dyn Fn(&Link, &Client) -> Exchanged + Send + Sync>;

/// One kept environment: the shell's session shape (`pairing.json`).
pub type Environment = Session;

/// Whether `a` and `b` are the same environment: by the id the MC gave
/// it, or by its address while the device does not know the id yet.
fn same(a: &Environment, b: &Environment) -> bool {
    if a.environment_id.is_empty() {
        a.origin == b.origin
    } else {
        a.environment_id == b.environment_id
    }
}

/// What the user is told of a pairing that did not pay
/// (desktop-qt PairingExchange::explain, the phone's wording).
pub fn explain(result: &Exchanged) -> String {
    let address = url::Url::parse(&result.origin)
        .ok()
        .and_then(|u| {
            let host = u.host_str()?.to_owned();
            Some(match u.port() {
                Some(port) => format!("{host}:{port}"),
                None => host,
            })
        })
        .unwrap_or_else(|| result.origin.clone());
    match result.outcome {
        Outcome::Paired => String::new(),
        Outcome::Unreachable => format!(
            "The environment at {address} could not be reached. Check the address, and that this device is on its network."
        ),
        Outcome::NotMc => {
            format!("{address} answered, but it is not a HAL-C2 environment. Check the address.")
        }
        Outcome::Incompatible => {
            let label = result
                .descriptor
                .get("label")
                .and_then(Json::as_str)
                .filter(|l| !l.is_empty())
                .unwrap_or(&address);
            let theirs = result
                .descriptor
                .get("orchestrationProtocolVersion")
                .and_then(Json::as_f64)
                .unwrap_or_default();
            if theirs > hal_c2_mc::PROTOCOL as f64 {
                format!(
                    "This app is too old for {label}. Update the app: the two need compatible versions of HAL-C2."
                )
            } else {
                format!(
                    "{label} runs an older HAL-C2 than this app. Update it: the two need compatible versions of HAL-C2."
                )
            }
        }
        Outcome::Refused => {
            "Pairing failed: the link was already used or has expired. Ask the environment for a fresh one.".into()
        }
    }
}

/// The pairing state machine: Pairing's fields and its rules, nothing
/// else. The exchange and the disk answer through its methods' results.
#[derive(Clone, Debug, Default)]
pub struct Core {
    pub paired: Option<Environment>,
    /// The exchange in flight, if any; an answer to an older one (a
    /// smaller attempt) is ignored.
    pub pairing: bool,
    pub attempt: u64,
    pub error: String,
    pub link: String,
    pub adding: bool,
    pub offered: String,
    /// How many times the device forgot its own environment: a session
    /// the shell opened before the last forget is not remembered.
    pub forgets: u64,
}

/// What [`Core::begin`] decided of a link the user entered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Begun {
    /// Spend it: the attempt to answer with.
    Spend(u64),
    /// Not a pairing link, or an exchange is in flight already.
    Refused,
}

/// What [`Core::offer`] made of a link from outside the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Offered {
    /// Shown on the pairing screen, never spent.
    Shown,
    /// Not a pairing link, with a pairing screen to say so.
    Said,
    /// Not a pairing link, and no pairing screen: a toast says so.
    Toast,
    /// An exchange is in flight: nothing changed.
    Busy,
}

impl Core {
    pub fn phase(&self) -> &'static str {
        if self.pairing {
            "pairing"
        } else if self.paired.is_some() {
            "paired"
        } else {
            "unpaired"
        }
    }

    /// A paired device asks to pair with another: the pairing screen
    /// comes up over the environment it has.
    pub fn add(&mut self) {
        if self.paired.is_none() || self.pairing || self.adding {
            return;
        }
        self.adding = true;
        self.link.clear();
        self.offered.clear();
        self.error.clear();
    }

    /// The way back from `adding`, the environment untouched. Not while
    /// a link is being spent.
    pub fn cancel(&mut self) {
        if !self.adding || self.pairing {
            return;
        }
        self.adding = false;
        self.link.clear();
        self.offered.clear();
        self.error.clear();
    }

    /// The user entered `link` (typed, pasted, or scanned in the app):
    /// spend it, unless one is being spent or it is not a pairing link
    /// (`read` is `pairing::read_link` of it).
    pub fn begin(&mut self, link: &str, read: bool) -> Begun {
        if self.pairing {
            return Begun::Refused;
        }
        // The address was the offered link's, not that of what the user
        // wrote over it.
        if link.trim() != self.link {
            self.offered.clear();
        }
        self.link = link.to_owned();
        if !read {
            self.error =
                "That is not a pairing link. Enter the link the environment gave you, with its token."
                    .into();
            return Begun::Refused;
        }
        self.pairing = true;
        self.error.clear();
        self.attempt += 1;
        Begun::Spend(self.attempt)
    }

    /// A link from outside the app: shown, never spent. `invitation` is
    /// `pairing::read_invitation` of what arrived.
    pub fn offer(&mut self, invitation: Option<(String, String)>) -> Offered {
        // The user's own attempt is waiting for its answer.
        if self.pairing {
            return Offered::Busy;
        }
        let Some((link, address)) = invitation else {
            if self.paired.is_some() && !self.adding {
                return Offered::Toast;
            }
            self.error =
                "The link that opened HAL-C2 is not a pairing link. Nothing was changed.".into();
            return Offered::Said;
        };
        self.link = link;
        self.offered = address;
        self.adding = self.paired.is_some();
        self.error.clear();
        Offered::Shown
    }

    /// An exchange that did not pay, or a session that could not be
    /// saved: the link stays to correct, the environments stay.
    pub fn fail(&mut self, attempt: u64, error: String) -> bool {
        if attempt != self.attempt {
            return false;
        }
        self.pairing = false;
        self.error = error;
        true
    }

    /// The exchange paid and the session is saved as the shell's own.
    pub fn paired_own(&mut self, attempt: u64, next: Environment) -> bool {
        if attempt != self.attempt {
            return false;
        }
        self.pairing = false;
        self.paired = Some(next);
        self.adding = false;
        self.link.clear();
        self.offered.clear();
        self.error.clear();
        true
    }

    /// The exchange paid for one beside the shell's own, and it is saved.
    pub fn paired_beside(&mut self, attempt: u64) -> bool {
        if attempt != self.attempt {
            return false;
        }
        self.pairing = false;
        self.adding = false;
        self.link.clear();
        self.offered.clear();
        self.error.clear();
        true
    }

    /// A session the shell connected with, its own pairing's or one
    /// ConnectionHealth bought pairing again (mobile-qt's
    /// Pairing::remember): the device's own from now on, to be saved;
    /// none when it is the one kept already. A new session at the same
    /// address is the same environment until it says otherwise.
    /// `forgets` is [`Core::forgets`] as the session opened: one
    /// forgotten since is not saved again. One ConnectionHealth was still
    /// buying when the forget landed never opens (`Pairing::forget`
    /// cancels it), so it never reaches here.
    pub fn remember(&mut self, session: &Environment, forgets: u64) -> Option<Environment> {
        if forgets != self.forgets {
            return None;
        }
        let mut next = session.clone();
        if let Some(own) = &self.paired
            && own.origin == next.origin
        {
            if next.label.is_empty() {
                next.label.clone_from(&own.label);
            }
            if next.environment_id.is_empty() {
                next.environment_id.clone_from(&own.environment_id);
            }
        }
        if self.paired.as_ref() == Some(&next) {
            return None;
        }
        self.paired = Some(next.clone());
        Some(next)
    }

    /// The shell's own environment is forgotten, its session already off
    /// the device. An exchange in flight has nobody to answer.
    pub fn forgotten(&mut self) {
        self.attempt += 1;
        self.forgets += 1;
        self.pairing = false;
        self.paired = None;
        self.adding = false;
        self.link.clear();
        self.offered.clear();
        self.error.clear();
    }

    /// What the bricks read.
    pub fn state(&self) -> Json {
        json!({
            "phase": self.phase(),
            "error": self.error,
            "link": self.link,
            "origin": self.paired.as_ref().map(|e| e.origin.as_str()).unwrap_or_default(),
            "label": self.paired.as_ref().map(|e| e.label.as_str()).unwrap_or_default(),
            "adding": self.adding,
            "offered": self.offered,
        })
    }
}

/// The kept session in `pairing.json`, readable by the user alone; none
/// when there is none or it does not name an origin and a token.
pub fn load(path: &std::path::Path) -> Option<Environment> {
    let bytes = std::fs::read(path).ok()?;
    let environment: Environment = serde_json::from_slice(&bytes).ok()?;
    let host = url::Url::parse(&environment.origin)
        .ok()
        .and_then(|u| u.host_str().map(|h| !h.is_empty()))
        .unwrap_or(false);
    (host && !environment.token.is_empty()).then_some(environment)
}

/// Writes `environment` as the session the device keeps, in the place of
/// the one it kept; false, with that one still there, when it cannot.
/// The token is the session: nobody else on the device reads it.
pub fn save(path: &std::path::Path, environment: &Environment) -> bool {
    let done = (|| -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let bytes = serde_json::to_vec(environment).map_err(std::io::Error::other)?;
        let tmp = path.with_extension("json.tmp");
        // One a failed save left behind; made afresh, so it is ours alone
        // from its first byte.
        match std::fs::remove_file(&tmp) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        let written = (|| {
            use std::io::Write;
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            let mut file = options.open(&tmp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            std::fs::rename(&tmp, path)
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        written
    })();
    if let Err(error) = &done {
        eprintln!("[pairing] not saved to {}: {error}", path.display());
    }
    done.is_ok()
}

/// What every start reads: where the session is kept, the device, and the
/// exchange (the system's unless a test says).
#[derive(Default)]
struct Where {
    path: RefCell<Option<PathBuf>>,
    device: RefCell<Option<Client>>,
    exchange: RefCell<Option<Exchange>>,
}

/// Says where the kept session is (`<data>/pairing.json`). Before start.
pub fn set_path(engine: &Engine, path: Option<PathBuf>) {
    *engine.extension::<Where>().path.borrow_mut() = path;
}

/// What an MC lists this device as. Before start.
pub fn set_device(engine: &Engine, device: Client) {
    *engine.extension::<Where>().device.borrow_mut() = Some(device);
}

/// Lets a test spend pairing links without the network. Before start.
pub fn set_exchange(engine: &Engine, exchange: Exchange) {
    *engine.extension::<Where>().exchange.borrow_mut() = Some(exchange);
}

pub struct Pairing {
    bridge: Bridge,
    me: Me<Pairing>,
    core: Core,
    path: Option<PathBuf>,
    device: Client,
    exchange: Exchange,
    /// [`Core::forgets`], read as the shell opens a session, which may be
    /// while this controller is running.
    forgets: Rc<std::cell::Cell<u64>>,
}

impl Controller for Pairing {
    fn new(init: Init<'_, Self>) -> Self {
        let place = init.engine.extension::<Where>();
        let path = place.path.borrow().clone();
        let device = place.device.borrow().clone().unwrap_or_else(crate::device);
        let exchange = place
            .exchange
            .borrow()
            .clone()
            .unwrap_or_else(|| Arc::new(pairing::exchange));
        let mut core = Core::default();
        if let Some(path) = &path {
            core.paired = load(path);
        }
        let forgets = Rc::new(std::cell::Cell::new(core.forgets));
        let me = init.me.clone();
        let opened_at = forgets.clone();
        hal_c2_shell::on_opened(init.engine, move |engine, session| {
            let session = session.clone();
            let at = opened_at.get();
            me.run_after(engine, move |c: &mut Pairing, engine| {
                c.remember(engine, &session, at)
            });
        });
        Pairing {
            bridge: init.bridge,
            me: init.me,
            core,
            path,
            device,
            exchange,
            forgets,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        // Its environments beside the shell's own are listed as this
        // device too.
        let device = self.device.clone();
        controller::with::<SavedEnvironments, _>(engine, |saved, _| saved.set_device(device));
        self.publish(engine);
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
            "pairing.pair" => self.pair(engine, &text("link")),
            "pairing.add" => {
                self.core.add();
                self.publish(engine);
            }
            "pairing.cancel" => {
                self.core.cancel();
                self.publish(engine);
            }
            "pairing.askToForget" => self.ask_to_forget(engine, &text("id")),
            "pairing.forget" => self.forget(engine, &text("id")),
            _ => return false,
        }
        true
    }
}

impl Pairing {
    fn publish(&self, engine: &Engine) {
        self.bridge.publish(engine, KEY, self.core.state());
    }

    /// Connects to the remembered environment, if there is one; else the
    /// first one paired beside a forgotten one takes its place.
    pub fn start(&mut self, engine: &Engine) {
        let Some(environment) = self.core.paired.clone() else {
            if !self.promote(engine, None) {
                self.publish(engine);
            }
            return;
        };
        // An interrupted promote leaves the pairing's own session in the
        // saved environments too: that copy is dropped. One with another
        // session stays, as it may be the newer (a tablet's Settings >
        // Connections saves one there) and the only one that works.
        if !environment.environment_id.is_empty() {
            let id = environment.environment_id.clone();
            let token = environment.token.clone();
            controller::with::<SavedEnvironments, _>(engine, |c, engine| {
                if c.catalog().is_some_and(|catalog| {
                    let copy = catalog.connect(&id);
                    copy.blocked.is_empty() && copy.credential == token
                }) {
                    c.drop_duplicate(engine, &id);
                }
            });
        }
        self.open(engine, &environment);
    }

    /// The environment it paired with, not whichever answers at its
    /// address now: the shell opens expecting its id.
    fn open(&self, engine: &Engine, environment: &Environment) {
        if let Err(error) = hal_c2_shell::open(engine, environment) {
            eprintln!("[pairing] the remembered environment did not open: {error}");
        }
    }

    fn pair(&mut self, engine: &Engine, link: &str) {
        let read = pairing::read_link(link);
        let Begun::Spend(attempt) = self.core.begin(link, read.is_some()) else {
            self.publish(engine);
            return;
        };
        let read = read.expect("begin spends only a read link");
        self.publish(engine);
        let exchange = self.exchange.clone();
        let device = self.device.clone();
        let me = self.me.clone();
        let spawned = ljos::task::spawn(
            engine,
            move || exchange(&read, &device),
            move |engine, result| {
                me.run(engine, move |c, engine| {
                    c.exchanged(engine, attempt, result.ok());
                });
            },
        );
        if spawned.is_err() {
            self.core
                .fail(attempt, "Could not start pairing. Try again.".into());
            self.publish(engine);
        }
    }

    fn exchanged(&mut self, engine: &Engine, attempt: u64, result: Option<Exchanged>) {
        if attempt != self.core.attempt {
            return;
        }
        let Some(result) = result else {
            self.core.fail(
                attempt,
                "The environment could not be reached. Try again.".into(),
            );
            self.publish(engine);
            return;
        };
        if result.outcome != Outcome::Paired {
            self.core.fail(attempt, explain(&result));
            self.publish(engine);
            return;
        }
        let text = |key: &str| {
            result
                .descriptor
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let next = Environment {
            origin: result.origin.clone(),
            token: result.token.clone(),
            label: text("label"),
            environment_id: text("environmentId"),
        };
        const NOT_SAVED: &str = "This environment could not be paired: its session could not be saved on this device. The link is used now, so ask the environment for a fresh one.";
        // An environment beside the one the shell connects to is on a
        // connection of its own, which keeps it before connecting. One
        // the device knew before it described itself is told by address.
        let beside = self
            .core
            .paired
            .as_ref()
            .is_some_and(|own| !same(own, &next));
        if beside {
            let saved = SavedEnvironment {
                id: next.environment_id.clone(),
                label: next.label.clone(),
                origin: next.origin.clone(),
                expires_at: String::new(),
            };
            let token = next.token.clone();
            let refused = controller::with::<SavedEnvironments, _>(engine, |c, engine| {
                c.save(engine, saved, &token).err()
            })
            .unwrap_or_else(|| Some("Saved environments are not available.".into()));
            match refused {
                None => {
                    self.core.paired_beside(attempt);
                }
                Some(why) => {
                    eprintln!("[pairing] not saved beside the environment: {why}");
                    self.core.fail(attempt, NOT_SAVED.into());
                }
            }
            self.publish(engine);
            return;
        }
        // On the device first: a session that is only in memory is gone
        // at the next start. The link is spent by now, and the session
        // it bought is left with the MC.
        let saved = self.path.as_deref().is_some_and(|path| save(path, &next));
        if !saved {
            self.core.fail(attempt, NOT_SAVED.into());
            self.publish(engine);
            return;
        }
        // Nor is it listed beside itself. Dropped, not removed: removing
        // it erases the threads the shell shows of it.
        if !next.environment_id.is_empty() {
            let id = next.environment_id.clone();
            controller::with::<SavedEnvironments, _>(engine, |c, engine| {
                if c.catalog()
                    .is_some_and(|catalog| catalog.find(&id).is_some())
                {
                    c.drop_duplicate(engine, &id);
                }
            });
        }
        self.core.paired_own(attempt, next.clone());
        self.publish(engine);
        self.open(engine, &next);
    }

    /// The shell is connected with `session` already, so it is this
    /// device's whether or not it can be saved: the one on the device is
    /// the one the MC refused, and is what the next start would open.
    fn remember(&mut self, engine: &Engine, session: &Environment, forgets: u64) {
        let Some(next) = self.core.remember(session, forgets) else {
            return;
        };
        if let Some(path) = &self.path
            && !save(path, &next)
        {
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.show(
                    engine,
                    "warning",
                    "Session not saved",
                    "The new session could not be saved on this device. It stays connected, and may need a fresh pairing link the next time HAL-C2 starts.",
                    None,
                    0,
                );
            });
        }
        self.publish(engine);
    }

    /// A link from outside the app: shown, never spent.
    fn offer(&mut self, engine: &Engine, received: &str) {
        let invitation = pairing::read_invitation(received)
            .map(|invitation| (invitation.link, invitation.address));
        match self.core.offer(invitation) {
            Offered::Busy => {}
            Offered::Toast => {
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    toasts.show(
                        engine,
                        "warning",
                        "Not a pairing link",
                        "The link that opened HAL-C2 is not a pairing link. Nothing was changed.",
                        None,
                        0,
                    );
                });
            }
            Offered::Said => self.publish(engine),
            Offered::Shown => {
                self.publish(engine);
                // It is the pairing screen's to show: not under a scanner
                // left open. The close changes the scanner's state, not
                // this one, so nothing here needs publishing again.
                self.bridge.dispatch(engine, "scanner.close", Json::Null);
            }
        }
    }

    fn ask_to_forget(&mut self, engine: &Engine, id: &str) {
        let label = if let Some(label) = self.beside_label(engine, id) {
            label
        } else if self
            .core
            .paired
            .as_ref()
            .is_some_and(|own| id.is_empty() || id == own.environment_id)
        {
            self.core
                .paired
                .as_ref()
                .map(|e| e.label.clone())
                .unwrap_or_default()
        } else {
            return;
        };
        let me = self.me.clone();
        let id = id.to_owned();
        let accepted = Rc::new(move |engine: &Engine| {
            let id = id.clone();
            me.run(engine, move |c, engine| c.forget(engine, &id));
        });
        controller::with::<Menus, _>(engine, |menus, engine| {
            menus.confirm(
                engine,
                &format!(
                    "Forget {}?",
                    if label.is_empty() { "this environment" } else { &label }
                ),
                "This device signs out of the environment and stops showing its projects and threads. Nothing on the environment is deleted. Pair again with a fresh pairing link to come back.",
                "Forget",
                true,
                Some(accepted),
                None,
            );
        });
    }

    /// The label of `id` when it is one paired beside the shell's own.
    fn beside_label(&self, engine: &Engine, id: &str) -> Option<String> {
        if id.is_empty()
            || self
                .core
                .paired
                .as_ref()
                .is_some_and(|own| own.environment_id == id)
        {
            return None;
        }
        controller::with::<SavedEnvironments, _>(engine, |saved, _| {
            saved
                .catalog()?
                .find(id)
                .map(|environment| environment.label.clone())
        })
        .flatten()
    }

    fn forget(&mut self, engine: &Engine, id: &str) {
        // One beside the shell's own goes alone, the others untouched.
        if self.beside_label(engine, id).is_some() {
            controller::with::<SavedEnvironments, _>(engine, |c, engine| c.remove(engine, id));
            self.core.error.clear();
            self.publish(engine);
            return;
        }
        if !id.is_empty()
            && self
                .core
                .paired
                .as_ref()
                .is_none_or(|own| id != own.environment_id)
        {
            return;
        }
        // The session goes from the device first: one that stays would be
        // opened again at the next start, whatever the app says now.
        // Until it is gone, nothing is forgotten, an exchange in flight
        // included.
        if let Some(path) = &self.path
            && let Err(error) = std::fs::remove_file(path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            eprintln!("[pairing] not forgotten: {}: {error}", path.display());
            self.core.error =
                "This environment could not be forgotten: its session could not be deleted from this device."
                    .into();
            self.publish(engine);
            return;
        }
        let had = self.core.paired.is_some();
        let forgotten_id = self
            .core
            .paired
            .as_ref()
            .map(|own| own.environment_id.clone())
            .filter(|own_id| !own_id.is_empty());
        self.core.forgotten();
        self.forgets.set(self.core.forgets);
        // A fresh link ConnectionHealth is spending for it opens nothing:
        // the session it bought would be remembered as this device's.
        controller::with::<ConnectionHealth, _>(engine, |c, engine| c.cancel_pairing(engine));
        if had {
            let (me, at) = (self.me.clone(), self.core.forgets);
            hal_c2_shell::close(engine, move |engine, emptied| {
                if emptied {
                    return;
                }
                // The session is gone, so it is forgotten all the same.
                me.run_after(engine, move |c: &mut Pairing, engine| {
                    if c.core.forgets == at {
                        c.core.error = "The environment is forgotten, but what this device kept of its threads could not be deleted.".into();
                        c.publish(engine);
                    }
                });
            });
        }
        // A saved copy of it (an interrupted promote or re-pair left one)
        // is forgotten too, credential and all, before another takes its
        // place: beside_label does not name the shell's own, so the
        // catalog is asked directly.
        if let Some(own_id) = &forgotten_id {
            let own_id = own_id.clone();
            controller::with::<SavedEnvironments, _>(engine, |c, engine| {
                if c.catalog()
                    .is_some_and(|catalog| catalog.find(&own_id).is_some())
                {
                    c.remove(engine, &own_id);
                }
            });
        }
        // One paired beside it takes its place, so the device stays
        // paired while it has any. Never the one just forgotten, even
        // when removing its saved copy did not take.
        if !self.promote(engine, forgotten_id.as_deref()) {
            self.publish(engine);
        }
        // Closing emptied the rows of those still beside it too: they are
        // sent again.
        if had {
            controller::with::<SavedEnvironments, _>(engine, |c, engine| c.reconnect(engine));
        }
    }

    /// With no environment of its own, the shell connects to the first
    /// one paired beside it that it can, which then is its own; false
    /// when none is.
    fn promote(&mut self, engine: &Engine, except: Option<&str>) -> bool {
        if self.core.paired.is_some() {
            return false;
        }
        let candidate = controller::with::<SavedEnvironments, _>(engine, |saved, _| {
            let catalog = saved.catalog()?;
            catalog.environments().iter().find_map(|environment| {
                if except == Some(environment.id.as_str()) {
                    return None;
                }
                let connection = catalog.connect(&environment.id);
                connection.blocked.is_empty().then(|| Environment {
                    origin: environment.origin.clone(),
                    token: connection.credential.clone(),
                    label: environment.label.clone(),
                    environment_id: environment.id.clone(),
                })
            })
        })
        .flatten();
        let Some(next) = candidate else {
            return false;
        };
        // Kept as the shell's own before it leaves the saved ones: there
        // is always one place on the device it is in.
        let Some(path) = self.path.as_deref() else {
            return false;
        };
        if !save(path, &next) {
            // save says why on stderr; the user hears why the device is
            // not paired, and the saved one stays where it was.
            let name = if next.label.is_empty() {
                "A paired environment"
            } else {
                next.label.as_str()
            };
            self.core.error = format!(
                "{name} could not be connected: its session could not be saved on this device."
            );
            return false;
        }
        let id = next.environment_id.clone();
        controller::with::<SavedEnvironments, _>(engine, |c, engine| c.remove(engine, &id));
        self.core.paired = Some(next.clone());
        self.publish(engine);
        self.open(engine, &next);
        true
    }
}

/// Connects to the remembered environment, if there is one (Pairing::start).
pub fn start(engine: &Engine) {
    controller::with::<Pairing, _>(engine, |pairing, engine| pairing.start(engine));
}

/// A `hal-c2:` link the system opened the app with: shown on the pairing
/// screen, never spent (Pairing::openLink).
pub fn offer_link(engine: &Engine, received: &str) {
    let received = received.to_owned();
    controller::with::<Pairing, _>(engine, |pairing, engine| pairing.offer(engine, &received));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn environment(id: &str) -> Environment {
        Environment {
            origin: "http://mc.example:3780".into(),
            token: "session".into(),
            label: "My MacBook".into(),
            environment_id: id.into(),
        }
    }

    #[test]
    fn a_saved_session_loads_and_a_broken_one_does_not() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing.json");
        assert!(load(&path).is_none());
        assert!(save(&path, &environment("env-1")));
        assert_eq!(load(&path), Some(environment("env-1")));
        std::fs::write(&path, "{}").unwrap();
        assert!(load(&path).is_none());
    }

    #[test]
    fn a_session_bought_pairing_again_is_kept_as_the_same_environment() {
        let mut core = Core {
            paired: Some(environment("env-1")),
            ..Core::default()
        };
        // The shell's own opening of what it keeps changes nothing.
        assert_eq!(core.remember(&environment("env-1"), 0), None);
        // Pair again (ConnectionHealth) names no label or id of its own.
        let again = Environment {
            token: "fresh".into(),
            label: String::new(),
            environment_id: String::new(),
            ..environment("env-1")
        };
        let kept = core.remember(&again, 0).expect("a new session is kept");
        assert_eq!(kept.token, "fresh");
        assert_eq!(kept.label, "My MacBook");
        assert_eq!(kept.environment_id, "env-1");
        assert_eq!(core.paired, Some(kept));
        // One that opened before a forget is not saved back.
        core.forgotten();
        assert_eq!(core.remember(&again, 0), None);
        assert_eq!(core.paired, None);
    }

    #[cfg(unix)]
    #[test]
    fn a_saved_session_is_the_users_alone_over_a_stale_temp() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing.json");
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, "left by a failed save").unwrap();
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(save(&path, &environment("env-1")));
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert!(!tmp.exists());
        assert_eq!(load(&path), Some(environment("env-1")));
    }

    #[test]
    fn pairing_with_a_bad_link_keeps_it_and_says_so() {
        let mut core = Core::default();
        assert_eq!(core.begin("not a link", false), Begun::Refused);
        assert_eq!(core.phase(), "unpaired");
        assert_eq!(core.link, "not a link");
        assert!(core.error.contains("not a pairing link"), "{}", core.error);
    }

    // The pairing prop's two shrunk cases (tests/mobile_prop.proptest-
    // regressions): while a link is spent, neither another link nor the
    // way back changes anything.
    #[test]
    fn a_link_being_spent_holds_off_another_and_the_way_back() {
        let mut core = Core::default();
        let link = "http://mc.example:3780/pair#token=t";
        assert_eq!(core.begin(link, true), Begun::Spend(1));
        assert_eq!(core.begin("not a link", false), Begun::Refused);
        core.cancel();
        assert_eq!(core.phase(), "pairing");
        assert_eq!(core.attempt, 1);
        assert_eq!(core.link, link);
        assert!(core.error.is_empty(), "{}", core.error);
    }

    #[test]
    fn backing_out_of_pairing_with_another_keeps_the_current_one() {
        let mut core = Core {
            paired: Some(environment("env-1")),
            ..Core::default()
        };
        core.add();
        assert!(core.adding);
        core.cancel();
        assert!(!core.adding);
        assert_eq!(core.paired, Some(environment("env-1")));
    }

    #[test]
    fn a_link_from_outside_is_shown_and_never_spent() {
        let mut core = Core::default();
        let shown = core.offer(Some((
            "http://mc.example:3780/pair#token=t".into(),
            "http://mc.example:3780".into(),
        )));
        assert_eq!(shown, Offered::Shown);
        assert_eq!(core.phase(), "unpaired");
        assert_eq!(core.offered, "http://mc.example:3780");
        assert!(!core.adding);
    }
}
