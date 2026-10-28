//! `notifications`: system notifications on a private bus, never the
//! session's, with a fake notification service on it
//! (features/timeline/notifications.feature, "System notifications").
//! Waits are on receipts: `flush` for the replies, the click callback for
//! the signals.
#![cfg(all(unix, not(target_os = "macos")))]

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use hal_c2_shell::controllers::alerts::Presenter;
use hal_c2_shell::notifications::NativeNotifications;
use zbus::blocking::Connection;
use zbus::blocking::connection::Builder;
use zbus::blocking::fdo::DBusProxy;
use zbus::zvariant::OwnedValue;

const SERVICE: &str = "org.freedesktop.Notifications";
const PATH: &str = "/org/freedesktop/Notifications";

/// Only a failed test waits this long.
const NEVER: Duration = Duration::from_secs(10);

/// A dbus-daemon of the test's own, stopped by the PID it was started with.
struct Bus {
    daemon: Child,
    address: String,
}

impl Bus {
    fn start(test: &str) -> Bus {
        let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
            .join("notifications-bus")
            .join(test);
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("bus.conf");
        // Abstract, so no socket file (and no path length limit); named for
        // this process and test, so no other bus is it.
        let socket = format!("hal-c2-notifications-{}-{test}", std::process::id());
        std::fs::write(
            &config,
            format!(
                r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:abstract={socket}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#
            ),
        )
        .unwrap();
        let mut daemon = Command::new("dbus-daemon")
            .arg(format!("--config-file={}", config.display()))
            .args(["--nofork", "--print-address"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .spawn()
            .expect("dbus-daemon runs");
        // Printed once it listens.
        let mut address = String::new();
        BufReader::new(daemon.stdout.take().unwrap())
            .read_line(&mut address)
            .unwrap();
        Bus {
            daemon,
            address: address.trim().to_owned(),
        }
    }

    fn connect(&self) -> Connection {
        Builder::address(self.address.as_str())
            .unwrap()
            .build()
            .unwrap()
    }

    /// The desktop's notification service, played by a fake.
    fn service(&self) -> Service {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let (said, heard) = mpsc::channel();
        let conn = Builder::address(self.address.as_str())
            .unwrap()
            .serve_at(
                PATH,
                Fake {
                    calls: calls.clone(),
                    next: Mutex::new(0),
                    said: Mutex::new(said),
                },
            )
            .unwrap()
            .name(SERVICE)
            .unwrap()
            .build()
            .unwrap();
        Service { conn, calls, heard }
    }

    fn notifications(&self) -> (NativeNotifications, mpsc::Receiver<String>) {
        let (clicked, clicks) = mpsc::channel();
        let clicked = Mutex::new(clicked);
        let n = NativeNotifications::on(Some(self.connect()), move |key| {
            let _ = clicked.lock().unwrap().send(key);
        });
        // The service is looked for on the worker.
        n.flush();
        (n, clicks)
    }
}

impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
    }
}

struct Fake {
    calls: Arc<Mutex<Vec<String>>>,
    next: Mutex<u32>,
    said: Mutex<mpsc::Sender<String>>,
}

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl Fake {
    #[allow(clippy::too_many_arguments)]
    fn notify(
        &self,
        app_name: String,
        replaces_id: u32,
        app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        hints: HashMap<String, OwnedValue>,
        expire_timeout: i32,
    ) -> u32 {
        let mut hints: Vec<_> = hints.iter().map(|(k, v)| format!("{k}={}", **v)).collect();
        hints.sort();
        let call = format!(
            "notify {app_name} replaces={replaces_id} icon={app_icon} {summary:?} {body:?} \
             {actions:?} [{}] timeout={expire_timeout}",
            hints.join(" ")
        );
        self.calls.lock().unwrap().push(call);
        let mut next = self.next.lock().unwrap();
        *next += 1;
        *next
    }

    fn close_notification(&self, id: u32) {
        let call = format!("close {id}");
        self.calls.lock().unwrap().push(call.clone());
        let _ = self.said.lock().unwrap().send(call);
    }
}

struct Service {
    conn: Connection,
    calls: Arc<Mutex<Vec<String>>>,
    /// Each close, as it is asked for.
    heard: mpsc::Receiver<String>,
}

impl Service {
    fn calls(&self) -> Vec<String> {
        std::mem::take(&mut *self.calls.lock().unwrap())
    }

    fn emit(&self, member: &str, body: &(u32, impl serde::Serialize + zbus::zvariant::Type)) {
        emit(&self.conn, member, body);
    }

    fn click(&self, id: u32) {
        self.emit("ActionInvoked", &(id, "default"));
    }

    fn closed(&self) -> String {
        self.heard
            .recv_timeout(NEVER)
            .expect("a close was asked for")
    }
}

/// Sends a signal of the service's from `conn`, and returns once the bus
/// has passed it on: one round trip after it, on the same connection.
fn emit(
    conn: &Connection,
    member: &str,
    body: &(u32, impl serde::Serialize + zbus::zvariant::Type),
) {
    conn.emit_signal(None::<()>, PATH, SERVICE, member, body)
        .unwrap();
    DBusProxy::new(conn).unwrap().get_id().unwrap();
}

fn replaces(call: &str) -> &str {
    call.split(' ')
        .find(|w| w.starts_with("replaces="))
        .unwrap()
}

#[test]
fn a_notification_carries_the_alert() {
    let bus = Bus::start("carries");
    let service = bus.service();
    let (n, _) = bus.notifications();
    assert!(n.supported());
    n.set_enabled(true);
    assert!(n.show("env-a:tax", "Thread completed", "Fix <b> & \"c\"", true, -7));
    n.flush();
    assert_eq!(
        service.calls(),
        ["notify HAL-C2 replaces=0 icon=hal-c2 \"Thread completed\" \
             \"Fix &lt;b&gt; &amp; &quot;c&quot;\" [\"default\", \"Open thread\"] \
             [desktop-entry=\"hal-c2\" suppress-sound=true] timeout=-1"]
    );
    assert_eq!(n.last_error(), "");
}

// The service is looked for on the worker, not by the caller: what is shown
// before it is found still reaches it.
#[test]
fn a_notification_shown_while_the_service_is_looked_for_reaches_it() {
    let bus = Bus::start("early");
    let service = bus.service();
    let n = NativeNotifications::on(Some(bus.connect()), |_| {});
    n.set_enabled(true);
    assert!(n.show("tax", "Thread completed", "Tax fix", true, -1));
    n.flush();
    assert_eq!(service.calls().len(), 1);
    assert_eq!(n.last_error(), "");
}

#[test]
fn a_newer_alert_replaces_its_threads_notification() {
    let bus = Bus::start("replaces");
    let service = bus.service();
    let (n, _) = bus.notifications();
    n.set_enabled(true);
    assert!(n.show("tax", "Approval needed", "Tax fix", true, -1));
    n.flush();
    assert!(n.show("tax", "Thread completed", "Tax fix", true, -1));
    assert!(n.show("docs", "Thread completed", "Docs", true, -1));
    n.flush();
    let calls = service.calls();
    let replaced: Vec<_> = calls.iter().map(|c| replaces(c)).collect();
    assert_eq!(replaced, ["replaces=0", "replaces=1", "replaces=0"]);
}

#[test]
fn clicking_an_older_notification_opens_its_own_thread() {
    let bus = Bus::start("click");
    let service = bus.service();
    let (n, clicks) = bus.notifications();
    n.set_enabled(true);
    n.show("tax", "Thread completed", "Tax fix", true, -1);
    n.show("docs", "Thread completed", "Docs", true, -1);
    n.flush();
    // Only the notification's default action opens it, and only the
    // service's own signals count.
    service.emit("ActionInvoked", &(2u32, "other"));
    let impostor = bus.connect();
    emit(&impostor, "ActionInvoked", &(2u32, "default"));
    service.click(1);
    assert_eq!(clicks.recv_timeout(NEVER).unwrap(), "tax");
    service.click(2);
    assert_eq!(clicks.recv_timeout(NEVER).unwrap(), "docs");
}

#[test]
fn a_notification_the_desktop_closed_is_forgotten() {
    let bus = Bus::start("closed");
    let service = bus.service();
    let (n, clicks) = bus.notifications();
    n.set_enabled(true);
    n.show("tax", "Thread completed", "Tax fix", true, -1);
    n.show("docs", "Thread completed", "Docs", true, -1);
    n.flush();
    service.emit("NotificationClosed", &(1u32, 2u32));
    service.click(1);
    service.click(2);
    // The first click is of a notification gone, so the second's key is the
    // first heard, and the close was handled before it.
    assert_eq!(clicks.recv_timeout(NEVER).unwrap(), "docs");
    service.calls();
    n.show("tax", "Thread completed", "Tax fix", true, -1);
    n.flush();
    assert_eq!(replaces(&service.calls()[0]), "replaces=0");
}

#[test]
fn turning_notifications_off_closes_them() {
    let bus = Bus::start("off");
    let service = bus.service();
    let (n, _) = bus.notifications();
    n.set_enabled(true);
    n.show("tax", "Thread completed", "Tax fix", true, -1);
    n.show("docs", "Thread completed", "Docs", true, -1);
    n.flush();
    n.set_enabled(false);
    let mut closed = [service.closed(), service.closed()];
    closed.sort();
    assert_eq!(closed, ["close 1", "close 2"]);
    assert!(!n.show("tax", "Thread completed", "Tax fix", true, -1));
}

#[test]
fn a_notification_still_on_its_way_when_turned_off_is_closed() {
    let bus = Bus::start("late");
    let service = bus.service();
    let (n, _) = bus.notifications();
    n.set_enabled(true);
    n.show("tax", "Thread completed", "Tax fix", true, -1);
    // Whether the reply came before or after, what it shows is closed.
    n.set_enabled(false);
    assert_eq!(service.closed(), "close 1");
}

#[test]
fn clearing_closes_every_notification() {
    let bus = Bus::start("clear");
    let service = bus.service();
    let (n, _) = bus.notifications();
    let presenter: &dyn Presenter = &n;
    presenter.set_enabled(true);
    assert!(presenter.show("tax", "Thread completed", "Tax fix", true));
    n.flush();
    presenter.clear();
    assert_eq!(service.closed(), "close 1");
    // Still on: what comes next shows.
    assert!(presenter.show("tax", "Thread completed", "Tax fix", true));
    n.flush();
    assert_eq!(replaces(service.calls().last().unwrap()), "replaces=0");
}

#[test]
fn nothing_shows_while_off_or_without_a_thread() {
    let bus = Bus::start("disabled");
    let service = bus.service();
    let (n, _) = bus.notifications();
    assert!(!n.enabled());
    assert!(!n.show("tax", "Thread completed", "Tax fix", true, -1));
    n.set_enabled(true);
    assert!(!n.show("", "Thread completed", "Tax fix", true, -1));
    n.flush();
    assert!(service.calls().is_empty());
}

#[test]
fn without_a_notification_service_nothing_is_allowed() {
    let bus = Bus::start("unsupported");
    let (n, _) = bus.notifications();
    assert!(!n.supported());
    assert_eq!(Presenter::permitted(&n), Some(false));
    n.set_enabled(true);
    assert!(!n.show("tax", "Thread completed", "Tax fix", true, -1));
    assert_eq!(
        n.last_error(),
        "Native notifications require a Linux desktop notification service."
    );

    // No bus at all is the same.
    let none = NativeNotifications::on(None, |_| {});
    none.set_enabled(true);
    assert!(!none.supported());
    assert!(!none.show("tax", "Thread completed", "Tax fix", true, -1));
}
