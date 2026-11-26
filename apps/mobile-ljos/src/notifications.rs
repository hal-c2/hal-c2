//! `notifications`, mobile-qt's Notifications: the MC it is paired
//! with pushes alerts and the activity card (the MC's HalC2.Push)
//! through the UnifiedPush distributor the user picked, to an
//! endpoint this registers with it (`hal-c2.registerPush`), and the
//! push inbox ([`crate::push_inbox`]) decides what of each push the
//! system shows. While the app is open it works the card out itself
//! from the rows it shows, so it is right the moment the app comes
//! back. The device's side is [`crate::push_system`]'s seam: a host
//! build's supports no push, as mobile-qt's off Android.
//!
//! Publishes `notifications`:
//!   {supported:    the build can receive pushes,
//!    permission:   granted | denied | ask, the system's word,
//!    enabled:      allowed, and a distributor gave an endpoint,
//!    distributors: [{id, label}] installed,
//!    distributor:  the id picked, "" when none,
//!    choosing:     the user is asked which distributor to use,
//!    liveActivity: the activity card is on,
//!    liveUpdates:  Android 16's live update settings exist,
//!    quietHours:   null | {start, end, allowApprovals},
//!    muted:        the keys of the threads whose alerts are muted,
//!    message:      a sentence for the user, "" when none}
//!
//! Actions: `notifications.enable`, `notifications.disable`,
//! `notifications.openSettings`, `notifications.pickDistributor {id}`,
//! `notifications.cancelPick`, `notifications.setLiveActivity {on}`,
//! `notifications.openLiveUpdateSettings`,
//! `notifications.setQuietHours {quietHours}`, and
//! `alerts.setMuted {key, muted}` for one thread (the shell's
//! AlertController's, as in the C++).
//!
//! It also takes `hal-c2://threads/<environment>/<thread>`, the link
//! a tapped notification opens the app with, and shows that thread
//! once the phone has it; other `hal-c2:` links go to Pairing
//! ([`open_link`]).

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{self, Controller, Init, Me};
use hal_c2_shell::controllers::alerts::{AlertController, MUTED_KEY};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::Mc;
use hal_c2_shell::sidebar_model::Thread;
use hal_c2_shell::store;
use hal_c2_shell::thread_view::time::{Zone, parse_iso};
use ljos::prelude::{Engine, Value};
use serde_json::{Map, json};

use crate::pairing;
use crate::push_inbox::{self, ActivityRow, Device, Inbox};
use crate::push_system::{Permission, PushSystem, device_push_system};

const KEY: &str = "notifications";
const FINISHED_MS: i64 = 15 * 60 * 1000;

/// Where the inbox's file is and the device's push system (a test's
/// unless the device's), as every start reads them.
#[derive(Default)]
struct Where {
    data_dir: RefCell<Option<PathBuf>>,
    system: RefCell<Option<Rc<dyn PushSystem>>>,
}

/// Says where the push inbox is kept (`<data>/push.json`). Before start.
pub fn set_data_dir(engine: &Engine, dir: Option<PathBuf>) {
    *engine.extension::<Where>().data_dir.borrow_mut() = dir;
}

/// Lets a test put its own push system here. Before start.
pub fn set_system(engine: &Engine, system: Rc<dyn PushSystem>) {
    *engine.extension::<Where>().system.borrow_mut() = Some(system);
}

fn epoch(iso: Option<&String>) -> i64 {
    iso.and_then(|text| parse_iso(text, Zone::utc()))
        .map_or(0, |at| at.timestamp_millis())
}

/// The phase of a thread as the MC's activity rows have it, and when
/// it last changed or finished; none when it has none to show.
pub fn phase_of(thread: &Thread, now: i64) -> Option<(&'static str, i64)> {
    let mut at = epoch(Some(&thread.updated_at));
    if thread.has_pending_user_input {
        return Some(("waiting_for_input", at));
    }
    if thread.has_pending_approvals {
        return Some(("waiting_for_approval", at));
    }
    let run = thread.latest_run.as_ref()?;
    match run.status.as_str() {
        "preparing" | "starting" | "queued" | "requested" => Some(("starting", at)),
        "running" | "waiting" => Some(("running", at)),
        "completed" | "failed" => {
            at = epoch(run.completed_at.as_ref());
            if at == 0 || at < now - FINISHED_MS {
                return None;
            }
            Some((
                if run.status == "completed" {
                    "completed"
                } else {
                    "failed"
                },
                at,
            ))
        }
        _ => None,
    }
}

pub struct Notifications {
    bridge: Bridge,
    me: Me<Notifications>,
    mc: Rc<dyn Mc>,
    system: Rc<dyn PushSystem>,
    inbox: Option<Inbox>,
    permission: Permission,
    active: bool,
    choosing: bool,
    message: String,
    /// What the MC was last sent, so the same registration is sent
    /// once per connection.
    registered: Json,
    /// The activity last put up from the shell's rows.
    activity: Json,
    /// The thread a tapped notification asked for, until the phone
    /// has it.
    pending: String,
}

impl Controller for Notifications {
    fn new(init: Init<'_, Self>) -> Self {
        let place = init.engine.extension::<Where>();
        let system = place
            .system
            .borrow()
            .clone()
            .unwrap_or_else(device_push_system);
        let inbox = place.data_dir.borrow().as_deref().map(Inbox::new);
        let permission = system.permission();
        let me = init.me.clone();
        let mc = init.mc.clone();
        system.set_changed(Rc::new(move |engine| {
            let mc = mc.clone();
            me.run(engine, move |c: &mut Notifications, engine| {
                // A distributor that let go of the phone: the MC
                // stops pushing to it.
                if c.inbox_value("endpoint")
                    .as_str()
                    .unwrap_or_default()
                    .is_empty()
                    && mc.is_ready()
                {
                    c.registered = Json::Null;
                    let environment = mc.environment();
                    mc.call(
                        &environment,
                        "hal-c2.unregisterPush",
                        json!({}),
                        Box::new(|_, _| {}),
                    );
                }
                c.register_push(engine);
                c.publish(engine);
            });
        }));
        // Synchronous, as the C++ signal: the unregister call goes
        // out while the connection it is for still hears it.
        pairing::on_forgetting(init.engine, move |engine| {
            controller::with::<Notifications, _>(engine, |c, engine| c.forget_environment(engine));
        });
        init.mc.on_ready_changed(Box::new({
            let me = init.me.clone();
            move |engine, ready| {
                me.run(engine, move |c: &mut Notifications, engine| {
                    c.registered = Json::Null;
                    if ready {
                        c.register_push(engine);
                    }
                    c.publish(engine);
                });
            }
        }));
        store::on_changed(init.engine, {
            let me = init.me.clone();
            move |engine| {
                me.run(engine, move |c: &mut Notifications, engine| {
                    c.update_activity(engine, false);
                    c.open_pending(engine);
                });
            }
        });
        Settings::of(init.engine).on_device_changed({
            let me = init.me.clone();
            move |engine| {
                me.run(engine, move |c: &mut Notifications, engine| {
                    c.register_push(engine);
                    c.publish(engine);
                });
            }
        });
        if let Ok(app) = init.engine.singleton::<ljos::prelude::Application>() {
            let me = init.me.clone();
            let _ = init
                .engine
                .connect_by_name(app, "activeChanged", move |engine, _| {
                    let active = matches!(engine.read_by_name(app, "active"), Value::Bool(true));
                    me.run(engine, move |c: &mut Notifications, engine| {
                        c.active_changed(engine, active)
                    });
                });
        }
        Notifications {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            system,
            inbox,
            permission,
            active: false,
            choosing: false,
            message: String::new(),
            registered: Json::Null,
            activity: Json::Null,
            pending: String::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
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
            "notifications.enable" => self.enable(engine),
            "notifications.disable" | "notifications.openSettings" => {
                // Android has no way back from "allowed" but its own
                // settings.
                self.system.open_settings();
            }
            "notifications.openLiveUpdateSettings" => self.system.open_live_update_settings(),
            "notifications.pickDistributor" => self.pick_distributor(engine, &text("id")),
            "notifications.cancelPick" => {
                self.choosing = false;
                self.publish(engine);
            }
            "notifications.setLiveActivity" => {
                let on = payload.get("on").and_then(Json::as_bool).unwrap_or(false);
                self.set_live_activity(engine, on);
            }
            "notifications.setQuietHours" => {
                let value = payload.get("quietHours").cloned().unwrap_or(Json::Null);
                self.set_inbox_value("quietHours", value);
                self.register_push(engine);
                self.publish(engine);
            }
            "alerts.setMuted" => {
                // Mutes are the desktop's (AlertController), which
                // the registration follows (deviceChanged).
                let key = text("key");
                let muted = payload
                    .get("muted")
                    .and_then(Json::as_bool)
                    .unwrap_or(false);
                controller::with::<AlertController, _>(engine, |alerts, engine| {
                    alerts.set_muted(engine, &key, muted);
                });
            }
            _ => return false,
        }
        true
    }
}

impl Notifications {
    fn inbox_value(&self, key: &str) -> Json {
        self.inbox
            .as_ref()
            .map_or(Json::Null, |inbox| inbox.value(key))
    }

    fn set_inbox_value(&self, key: &str, value: Json) {
        if let Some(inbox) = &self.inbox {
            inbox.set_value(key, value);
        }
    }

    fn live_activity(&self) -> bool {
        self.inbox.as_ref().is_some_and(Inbox::live_activity)
    }

    /// Asks the distributor for its endpoint again, as each start
    /// should. Once, when the shell is set up.
    pub fn start(&mut self, engine: &Engine) {
        // The channels exist before anything is posted, so the
        // system settings list them.
        if self.system.supported() {
            self.system.show(&push_inbox::channels());
        }
        // A distributor's endpoint can change while the app is away,
        // and one that was force-stopped forgets it: asking again on
        // each start keeps it current.
        let distributor = self
            .inbox_value("distributor")
            .as_str()
            .unwrap_or_default()
            .to_owned();
        if self.system.supported()
            && !distributor.is_empty()
            && self.permission == Permission::Granted
        {
            self.system.subscribe(&distributor);
        }
        let active = engine
            .singleton::<ljos::prelude::Application>()
            .is_ok_and(|app| matches!(engine.read_by_name(app, "active"), Value::Bool(true)));
        self.active_changed(engine, active);
    }

    fn enable(&mut self, engine: &Engine) {
        if !self.system.supported() {
            return;
        }
        self.message.clear();
        self.permission = self.system.permission();
        if self.permission == Permission::Granted {
            self.subscribe(engine);
            return;
        }
        if self.permission == Permission::Denied {
            self.message =
                "HAL-C2 is not allowed to notify. Allow it in the system settings.".into();
            self.publish(engine);
            return;
        }
        let me = self.me.clone();
        self.system.request_permission(
            engine,
            Rc::new(move |engine, permission| {
                me.run(engine, move |c: &mut Notifications, engine| {
                    c.permission = permission;
                    if permission == Permission::Granted {
                        c.subscribe(engine);
                    } else {
                        c.message =
                            "HAL-C2 is not allowed to notify. Allow it in the system settings."
                                .into();
                        c.publish(engine);
                    }
                });
            }),
        );
    }

    fn subscribe(&mut self, engine: &Engine) {
        let installed = self.system.distributors();
        let mut chosen = self
            .inbox_value("distributor")
            .as_str()
            .unwrap_or_default()
            .to_owned();
        if !installed.iter().any(|d| d.id == chosen) {
            chosen = if installed.len() == 1 {
                installed[0].id.clone()
            } else {
                String::new()
            };
        }
        if !chosen.is_empty() {
            self.set_inbox_value("distributor", json!(chosen));
            self.message.clear();
            self.system.subscribe(&chosen);
        } else if installed.is_empty() {
            self.message =
                "Install a UnifiedPush distributor, such as ntfy, to receive notifications.".into();
        } else {
            self.choosing = true;
        }
        self.publish(engine);
    }

    fn pick_distributor(&mut self, engine: &Engine, id: &str) {
        let installed = self.system.distributors();
        if !installed.iter().any(|d| d.id == id) {
            return;
        }
        let previous = self
            .inbox_value("distributor")
            .as_str()
            .unwrap_or_default()
            .to_owned();
        if previous != id && !previous.is_empty() {
            self.system.unsubscribe();
            self.set_inbox_value("endpoint", json!(""));
        }
        self.set_inbox_value("distributor", json!(id));
        self.choosing = false;
        self.subscribe(engine);
    }

    fn set_live_activity(&mut self, engine: &Engine, on: bool) {
        self.permission = self.system.permission();
        if on && self.permission != Permission::Granted {
            self.message = "Ongoing activity needs notification permission. Allow notifications for HAL-C2 in the system settings.".into();
            self.publish(engine);
            return;
        }
        self.message.clear();
        if let Some(inbox) = &self.inbox {
            let effects = inbox.set_live_activity(on);
            self.system.show(&effects);
        }
        self.activity = Json::Null;
        if on {
            self.update_activity(engine, true);
        }
        self.register_push(engine);
        self.publish(engine);
    }

    /// The user forgot the environment: it stops pushing to this phone.
    fn forget_environment(&mut self, engine: &Engine) {
        // The MC forgets the phone if it still hears it; one that
        // does not pushes to an endpoint the distributor dropped, and
        // to keys the phone no longer has.
        if self.mc.is_ready() {
            let environment = self.mc.environment();
            self.mc.call(
                &environment,
                "hal-c2.unregisterPush",
                json!({}),
                Box::new(|_, _| {}),
            );
        }
        self.registered = Json::Null;
        self.activity = Json::Null;
        self.pending.clear();
        let distributor = self
            .inbox_value("distributor")
            .as_str()
            .unwrap_or_default()
            .to_owned();
        if self.system.supported() && !distributor.is_empty() {
            self.system.unsubscribe();
        }
        if let Some(inbox) = &self.inbox {
            let effects = inbox.forget();
            self.system.show(&effects);
        }
        // A fresh endpoint, for the next environment paired with.
        if self.system.supported()
            && !distributor.is_empty()
            && self.permission == Permission::Granted
        {
            self.system.subscribe(&distributor);
        }
        self.publish(engine);
    }

    /// The app came to the front or left it.
    fn active_changed(&mut self, engine: &Engine, active: bool) {
        self.active = active;
        push_inbox::set_foreground(active);
        if !active {
            return;
        }
        // Allowed or blocked in the system's settings while away.
        self.permission = self.system.permission();
        self.register_push(engine);
        self.update_activity(engine, true);
        self.publish(engine);
    }

    fn quiet_hours(&self) -> Map<String, Json> {
        self.inbox_value("quietHours")
            .as_object()
            .cloned()
            .unwrap_or_default()
    }

    fn register_push(&mut self, engine: &Engine) {
        let endpoint = self
            .inbox_value("endpoint")
            .as_str()
            .unwrap_or_default()
            .to_owned();
        if !self.mc.is_ready()
            || !self.system.supported()
            || self.permission != Permission::Granted
            || endpoint.is_empty()
        {
            return;
        }
        let Some(inbox) = &self.inbox else {
            return;
        };
        let keys = inbox.keys();
        if !keys.valid() {
            return;
        }
        let muted = Settings::of(engine)
            .device_value(MUTED_KEY)
            .filter(Json::is_array)
            .unwrap_or_else(|| json!([]));
        let mut quiet = Json::Null;
        let hours = self.quiet_hours();
        if !hours.is_empty() {
            // The MC keeps quiet hours by this phone's clock, so it
            // is sent again when that moves (active_changed).
            let mut hours = hours;
            hours.insert(
                "utcOffsetMinutes".into(),
                json!(chrono::Local::now().offset().local_minus_utc() / 60),
            );
            quiet = Json::Object(hours);
        }
        use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
        let registration = json!({
            "endpoint": endpoint,
            "keys": {
                "p256dh": URL_SAFE_NO_PAD.encode(&keys.public_key),
                "auth": URL_SAFE_NO_PAD.encode(&keys.auth),
            },
            "distributor": self.inbox_value("distributor").as_str().unwrap_or_default(),
            "liveActivity": inbox.live_activity(),
            "mutedThreads": muted,
            "quietHours": quiet,
        });
        if registration == self.registered {
            return;
        }
        self.registered = registration.clone();
        let environment = self.mc.environment();
        let me = self.me.clone();
        let sent = registration.clone();
        self.mc.call(
            &environment,
            "hal-c2.registerPush",
            registration,
            Box::new(move |engine, result| {
                if let Err(error) = result {
                    let message = error.message.clone();
                    me.run(engine, move |c: &mut Notifications, engine| {
                        if c.registered == sent {
                            c.registered = Json::Null;
                        }
                        c.message = format!(
                            "The phone could not be registered for notifications: {message}"
                        );
                        c.publish(engine);
                    });
                }
            }),
        );
    }

    /// The card for what the shell shows now; `force` puts it up even
    /// when it is what it was.
    fn update_activity(&mut self, engine: &Engine, force: bool) {
        let Some(inbox) = &self.inbox else {
            return;
        };
        // Before the rows are in, the shell knows of no work: no
        // reason to end a card.
        if !self.active || !self.system.supported() || !inbox.live_activity() {
            return;
        }
        if !store::with(engine, |store| store.synchronized()) {
            return;
        }
        let now = self.system.now();
        let rows: Vec<ActivityRow> = store::with(engine, |store| {
            let mut rows = Vec::new();
            for thread in store.threads().iter() {
                if thread.subagent || thread.archived_at.is_some() || !thread.listed {
                    continue;
                }
                let Some((phase, at)) = phase_of(thread, now) else {
                    continue;
                };
                let project = store
                    .project(&format!("{}:{}", thread.environment_id, thread.project_id))
                    .map(|project| project.title)
                    .unwrap_or_default();
                rows.push(ActivityRow {
                    phase: phase.into(),
                    title: thread.title.clone(),
                    project,
                    environment_id: thread.environment_id.clone(),
                    thread_id: thread.id.clone(),
                    at,
                });
            }
            rows
        });
        let activity = push_inbox::activity(rows, now);
        let mut compared = activity.as_object().cloned().unwrap_or_default();
        compared.remove("expiresAt");
        let compared = Json::Object(compared);
        if !force && compared == self.activity {
            return;
        }
        self.activity = compared;
        let message = json!({
            "v": 1,
            "sentAt": now as f64,
            "local": true,
            "activity": activity,
        });
        let effects = inbox.deliver(
            message.as_object().expect("a message object"),
            &self.device(),
        );
        self.system.show(&effects);
    }

    fn open_pending(&mut self, engine: &Engine) {
        if self.pending.is_empty() {
            return;
        }
        // A notification from before the thread moved opens it where
        // it lives now.
        let key = store::with(engine, |store| {
            let key = store.located(&self.pending);
            store.thread(&key).map(|_| key)
        });
        let Some(key) = key else {
            return;
        };
        self.pending.clear();
        controller::with::<Navigation, _>(engine, |navigation, engine| {
            if *navigation.route() != Route::Thread(key.clone()) {
                navigation.open(engine, Route::Thread(key));
            }
        });
    }

    fn device(&self) -> Device {
        Device {
            now: self.system.now(),
            foreground: self.active,
            permitted: self.permission == Permission::Granted,
            sdk: self.system.sdk(),
        }
    }

    fn publish(&self, engine: &Engine) {
        let distributors: Vec<Json> = self
            .system
            .distributors()
            .iter()
            .map(|d| json!({"id": d.id, "label": d.label}))
            .collect();
        let quiet = self.quiet_hours();
        let muted = Settings::of(engine)
            .device_value(MUTED_KEY)
            .and_then(|value| {
                value.as_array().map(|keys| {
                    keys.iter()
                        .filter_map(|key| key.as_str().map(str::to_owned))
                        .collect::<Vec<_>>()
                })
            })
            .unwrap_or_default();
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "supported": self.system.supported(),
                "permission": self.permission.name(),
                "enabled": self.system.supported()
                    && self.permission == Permission::Granted
                    && !self.inbox_value("endpoint").as_str().unwrap_or_default().is_empty(),
                "distributors": distributors,
                "distributor": self.inbox_value("distributor").as_str().unwrap_or_default(),
                "choosing": self.choosing,
                "liveActivity": self.live_activity()
                    && self.permission == Permission::Granted,
                "liveUpdates": self.system.sdk() >= 36,
                "quietHours": if quiet.is_empty() { Json::Null } else { Json::Object(quiet) },
                "muted": muted,
                "message": self.message,
            }),
        );
    }
}

/// Asks the distributor for its endpoint again, as each start should
/// (Notifications::start). After `hal_c2_shell::start_with`.
pub fn start(engine: &Engine) {
    controller::with::<Notifications, _>(engine, |notifications, engine| {
        notifications.start(engine)
    });
}

/// A `hal-c2:` link the system opened the app with: a thread link
/// shows that thread once the phone has it; other links go to
/// Pairing (Notifications::openLink).
pub fn open_link(engine: &Engine, received: &str) {
    let (environment, thread) = push_inbox::parse_thread_link(received);
    if environment.is_empty() {
        pairing::offer_link(engine, received);
        return;
    }
    controller::with::<Notifications, _>(engine, |notifications, engine| {
        notifications.pending = format!("{environment}:{thread}");
        notifications.open_pending(engine);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use hal_c2_shell::sidebar_model::RunSummary;

    fn thread(status: &str, completed_at: Option<&str>) -> Thread {
        Thread {
            updated_at: "2026-09-23T10:00:00.000Z".into(),
            latest_run: Some(RunSummary {
                status: status.into(),
                completed_at: completed_at.map(str::to_owned),
                ..RunSummary::default()
            }),
            listed: true,
            ..Thread::default()
        }
    }

    #[test]
    fn phases_read_as_the_qt_client() {
        let now = epoch(Some(&"2026-09-23T10:10:00.000Z".to_owned()));
        assert_eq!(
            phase_of(&thread("running", None), now).map(|(p, _)| p),
            Some("running")
        );
        assert_eq!(
            phase_of(&thread("queued", None), now).map(|(p, _)| p),
            Some("starting")
        );
        assert_eq!(
            phase_of(&thread("completed", Some("2026-09-23T10:05:00.000Z")), now).map(|(p, _)| p),
            Some("completed")
        );
        // Finished over 15 minutes ago: nothing to show.
        assert_eq!(
            phase_of(&thread("failed", Some("2026-09-23T09:50:00.000Z")), now),
            None
        );
        let mut waiting = thread("running", None);
        waiting.has_pending_approvals = true;
        assert_eq!(
            phase_of(&waiting, now).map(|(p, _)| p),
            Some("waiting_for_approval")
        );
        waiting.has_pending_user_input = true;
        assert_eq!(
            phase_of(&waiting, now).map(|(p, _)| p),
            Some("waiting_for_input")
        );
    }
}
