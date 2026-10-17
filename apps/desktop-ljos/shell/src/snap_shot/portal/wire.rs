//! The session bus under [`Machine`](super::Machine): each [`Call`] as the
//! portal's D-Bus method call, each portal signal as an [`Input`].
//!
//! Calls go out in order on a worker thread, which also reads the screenshot
//! file ([`load`]); signals arrive on a listener thread. Both leave what they
//! learned in an inbox for [`Wire::arrive`] and run `wake`, so the Engine
//! thread comes for it. Both live as long as the bus connection, which is
//! the app's.

use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};

use zbus::blocking::fdo::DBusProxy;
use zbus::blocking::{Connection, MessageIterator};
use zbus::message::Type as MessageType;
use zbus::zvariant::{
    DeserializeDict, DynamicType, ObjectPath, OwnedObjectPath, OwnedValue, Type, Value,
};
use zbus::{MatchRule, Message};

use super::{Bound, Call, Input, Results, Wire, load};

/// The portal's well-known name, where every call goes.
pub const DESTINATION: &str = "org.freedesktop.portal.Desktop";
const DESKTOP_PATH: &str = "/org/freedesktop/portal/desktop";
const REGISTRY_PATH: &str = "/org/freedesktop/host/portal/Registry";
const REGISTRY: &str = "org.freedesktop.host.portal.Registry";
const SCREENSHOT: &str = "org.freedesktop.portal.Screenshot";
const SHORTCUTS: &str = "org.freedesktop.portal.GlobalShortcuts";
const REQUEST: &str = "org.freedesktop.portal.Request";
const SESSION: &str = "org.freedesktop.portal.Session";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";

type Options = HashMap<&'static str, Value<'static>>;

fn options<const N: usize>(entries: [(&'static str, Value<'static>); N]) -> Options {
    entries.into_iter().collect()
}

/// Where a method call goes: the bus, or in a test the message it would be.
pub trait Put {
    fn put<B: serde::Serialize + DynamicType>(
        &self,
        path: &str,
        interface: &str,
        member: &str,
        body: &B,
    ) -> zbus::Result<Message>;
}

impl Put for Connection {
    fn put<B: serde::Serialize + DynamicType>(
        &self,
        path: &str,
        interface: &str,
        member: &str,
        body: &B,
    ) -> zbus::Result<Message> {
        self.call_method(Some(DESTINATION), path, Some(interface), member, body)
    }
}

/// The path of the Request a `handle_token` names for the connection named
/// `unique` (":1.42"), as the portal derives it.
fn request_path(unique: &str, token: &str) -> String {
    format!("{}{token}", request_prefix(unique))
}

fn request_prefix(unique: &str) -> String {
    format!(
        "/org/freedesktop/portal/desktop/request/{}/",
        unique.trim_start_matches(':').replace('.', "_")
    )
}

/// Makes `call`, the method call [`Call`] stands for; none for the one that
/// is not ([`Call::Load`]). `unique` is this connection's name.
pub fn invoke<P: Put>(bus: &P, unique: &str, call: &Call) -> Option<zbus::Result<Message>> {
    let token = |token: &str| Value::from(token.to_owned());
    Some(match call {
        Call::Register { app_id } => bus.put(
            REGISTRY_PATH,
            REGISTRY,
            "Register",
            &(app_id.as_str(), Options::new()),
        ),
        Call::Properties => bus.put(DESKTOP_PATH, PROPERTIES, "GetAll", &(SCREENSHOT,)),
        Call::Version { .. } => bus.put(DESKTOP_PATH, PROPERTIES, "Get", &(SHORTCUTS, "version")),
        Call::Screenshot {
            token: handle_token,
            window,
        } => {
            let mut options = options([
                ("handle_token", token(handle_token)),
                ("modal", Value::from(false)),
                ("interactive", Value::from(!window)),
            ]);
            if *window {
                options.insert("target", Value::from(super::WINDOW_TARGET));
            }
            bus.put(DESKTOP_PATH, SCREENSHOT, "Screenshot", &("", options))
        }
        Call::CreateSession {
            token: handle_token,
            session_token,
        } => bus.put(
            DESKTOP_PATH,
            SHORTCUTS,
            "CreateSession",
            &(options([
                ("handle_token", token(handle_token)),
                ("session_handle_token", token(session_token)),
            ]),),
        ),
        Call::BindShortcuts {
            token: handle_token,
            session,
            id,
            trigger,
        } => {
            let Ok(session) = ObjectPath::try_from(session.as_str()) else {
                return Some(Err(zbus::Error::Failure("Invalid session handle.".into())));
            };
            let shortcut = options([
                ("description", Value::from("Capture a window")),
                ("preferred_trigger", token(trigger)),
            ]);
            bus.put(
                DESKTOP_PATH,
                SHORTCUTS,
                "BindShortcuts",
                &(
                    session,
                    vec![(id.as_str(), shortcut)],
                    "",
                    options([("handle_token", token(handle_token))]),
                ),
            )
        }
        Call::Configure { session } => {
            let Ok(session) = ObjectPath::try_from(session.as_str()) else {
                return Some(Err(zbus::Error::Failure("Invalid session handle.".into())));
            };
            bus.put(
                DESKTOP_PATH,
                SHORTCUTS,
                "ConfigureShortcuts",
                &(session, "", Options::new()),
            )
        }
        Call::CloseRequest {
            token: handle_token,
            handle,
        } => {
            let path = handle
                .clone()
                .unwrap_or_else(|| request_path(unique, handle_token));
            bus.put(&path, REQUEST, "Close", &())
        }
        Call::CloseSession { handle } => bus.put(handle, SESSION, "Close", &()),
        Call::Load { .. } => return None,
    })
}

/// The Response signal's dictionary; the keys the machine reads.
#[derive(DeserializeDict, Type)]
#[zvariant(signature = "dict")]
struct Answer {
    uri: Option<String>,
    session_handle: Option<String>,
    shortcuts: Option<Vec<(String, HashMap<String, OwnedValue>)>>,
}

/// A shortcut as the portal lists it: its id and its description entries.
type Described = (String, HashMap<String, OwnedValue>);

fn bound(shortcuts: Vec<Described>) -> Vec<Bound> {
    shortcuts
        .into_iter()
        .map(|(id, entries)| Bound {
            id,
            trigger: entries
                .get("trigger_description")
                .and_then(|value| String::try_from(value.try_clone().ok()?).ok())
                .unwrap_or_default(),
        })
        .collect()
}

/// What a signal the listener heard means; none if it is not the portal's,
/// or not for this connection (`unique`'s Requests).
pub fn parse(message: &Message, unique: &str) -> Option<Input> {
    let header = message.header();
    if header.message_type() != MessageType::Signal {
        return None;
    }
    let interface = header.interface()?.as_str();
    let member = header.member()?.as_str();
    let path = header.path().map(|path| path.as_str()).unwrap_or_default();
    let body = message.body();
    match (interface, member) {
        (REQUEST, "Response") => {
            if !path.starts_with(&request_prefix(unique)) {
                return None;
            }
            let (status, answer): (u32, Answer) = body.deserialize().ok()?;
            Some(Input::Response {
                handle: path.to_owned(),
                status,
                results: Results {
                    uri: answer.uri,
                    session_handle: answer.session_handle,
                    shortcuts: bound(answer.shortcuts.unwrap_or_default()),
                    timeout: false,
                },
            })
        }
        (SESSION, "Closed") => Some(Input::SessionClosed {
            handle: path.to_owned(),
        }),
        (SHORTCUTS, "Activated") => {
            let (session, id, _timestamp, _options): (
                OwnedObjectPath,
                String,
                u64,
                HashMap<String, OwnedValue>,
            ) = body.deserialize().ok()?;
            Some(Input::Activated {
                session: session.to_string(),
                id,
            })
        }
        (SHORTCUTS, "ShortcutsChanged") => {
            let (session, shortcuts): (OwnedObjectPath, Vec<Described>) =
                body.deserialize().ok()?;
            Some(Input::ShortcutsChanged {
                session: session.to_string(),
                shortcuts: bound(shortcuts),
            })
        }
        ("org.freedesktop.DBus", "NameOwnerChanged") => {
            let (name, old, _new): (String, String, String) = body.deserialize().ok()?;
            (name == DESTINATION).then_some(Input::OwnerChanged {
                was_owned: !old.is_empty(),
            })
        }
        _ => None,
    }
}

/// What a method reply means for the call that asked.
pub fn reply(call: &Call, reply: zbus::Result<Message>) -> Option<Input> {
    let failed = |e: &zbus::Error| match e {
        zbus::Error::MethodError(_, Some(message), _) => message.clone(),
        e => e.to_string(),
    };
    match call {
        Call::Properties => {
            let found = reply.ok().and_then(|reply| {
                let properties: HashMap<String, OwnedValue> = reply.body().deserialize().ok()?;
                let number = |key: &str| u32::try_from(properties.get(key)?.try_clone().ok()?).ok();
                Some((
                    number("version")?,
                    number("AvailableTargets").unwrap_or_default(),
                ))
            });
            Some(Input::Properties(found))
        }
        Call::Version { generation } => {
            let version = reply.ok().and_then(|reply| {
                let value: OwnedValue = reply.body().deserialize().ok()?;
                u32::try_from(value).ok()
            });
            Some(Input::Version {
                generation: *generation,
                version,
            })
        }
        Call::Screenshot { token, .. }
        | Call::CreateSession { token, .. }
        | Call::BindShortcuts { token, .. } => {
            let handle = reply
                .and_then(|reply| reply.body().deserialize::<OwnedObjectPath>())
                .map(|path| path.to_string())
                .map_err(|e| failed(&e));
            Some(Input::Replied {
                token: token.clone(),
                handle,
            })
        }
        Call::Register { .. }
        | Call::Configure { .. }
        | Call::CloseRequest { .. }
        | Call::CloseSession { .. }
        | Call::Load { .. } => None,
    }
}

struct Shared {
    inbox: Mutex<Vec<Input>>,
    wake: Box<dyn Fn() + Send + Sync>,
}

impl Shared {
    fn inbox(&self) -> MutexGuard<'_, Vec<Input>> {
        // A panic elsewhere leaves the inbox as consistent as any step of it.
        self.inbox.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn push(&self, input: Input) {
        self.inbox().push(input);
        (self.wake)();
    }
}

/// The wire to the session bus.
pub struct System {
    shared: Arc<Shared>,
    jobs: Option<mpsc::Sender<Call>>,
}

impl System {
    /// On the session bus; every call fails without one. `wake` runs on a
    /// thread of the wire's whenever [`Wire::arrive`] has something.
    pub fn new(wake: impl Fn() + Send + Sync + 'static) -> System {
        System::on(Connection::session().ok(), wake)
    }

    /// On `bus`, or failing for `None`.
    pub fn on(bus: Option<Connection>, wake: impl Fn() + Send + Sync + 'static) -> System {
        let shared = Arc::new(Shared {
            inbox: Mutex::new(Vec::new()),
            wake: Box::new(wake),
        });
        let Some(bus) = bus else {
            return System { shared, jobs: None };
        };
        let unique = bus
            .unique_name()
            .map(|name| name.to_string())
            .unwrap_or_default();
        // Subscribed before any call, so no answer is missed.
        if let Some(signals) = subscribe(&bus) {
            let shared = shared.clone();
            let unique = unique.clone();
            let _ = std::thread::Builder::new()
                .name("snap-shot-signals".into())
                .spawn(move || {
                    for message in signals.flatten() {
                        if let Some(input) = parse(&message, &unique) {
                            shared.push(input);
                        }
                    }
                });
        }
        let (jobs, inbox) = mpsc::channel();
        let worker = shared.clone();
        let _ = std::thread::Builder::new()
            .name("snap-shot-calls".into())
            .spawn(move || {
                for call in inbox {
                    if let Call::Load { uri } = &call {
                        worker.push(Input::Loaded(load(uri)));
                    } else if let Some(input) =
                        invoke(&bus, &unique, &call).and_then(|answer| reply(&call, answer))
                    {
                        worker.push(input);
                    }
                }
            });
        System {
            shared,
            jobs: Some(jobs),
        }
    }
}

impl Wire for System {
    fn send(&mut self, call: Call) {
        let Some(jobs) = &self.jobs else {
            // No bus: what the portal would have said is "no".
            let no = || "No desktop portal is running.".to_owned();
            let answer = match &call {
                Call::Load { uri } => Some(Input::Loaded(load(uri))),
                Call::Properties => Some(Input::Properties(None)),
                Call::Version { generation } => Some(Input::Version {
                    generation: *generation,
                    version: None,
                }),
                Call::Screenshot { token, .. }
                | Call::CreateSession { token, .. }
                | Call::BindShortcuts { token, .. } => Some(Input::Replied {
                    token: token.clone(),
                    handle: Err(no()),
                }),
                _ => None,
            };
            if let Some(answer) = answer {
                self.shared.push(answer);
            }
            return;
        };
        let _ = jobs.send(call);
    }

    fn arrive(&mut self) -> Vec<Input> {
        std::mem::take(&mut *self.shared.inbox())
    }
}

/// The portal's signals, and changes of its owner, as one stream so they
/// are handled in the order they came.
fn subscribe(bus: &Connection) -> Option<MessageIterator> {
    let dbus = DBusProxy::new(bus).ok()?;
    let signal = |interface: &'static str| -> Option<MatchRule<'static>> {
        Some(
            MatchRule::builder()
                .msg_type(MessageType::Signal)
                .interface(interface)
                .ok()?
                .build(),
        )
    };
    let owner = MatchRule::builder()
        .msg_type(MessageType::Signal)
        .sender("org.freedesktop.DBus")
        .ok()?
        .interface("org.freedesktop.DBus")
        .ok()?
        .member("NameOwnerChanged")
        .ok()?
        .arg(0, DESTINATION)
        .ok()?
        .build();
    let messages = MessageIterator::from(bus);
    for rule in [
        signal(REQUEST)?,
        signal(SESSION)?,
        signal(SHORTCUTS)?,
        owner,
    ] {
        dbus.add_match_rule(rule).ok()?;
    }
    Some(messages)
}
