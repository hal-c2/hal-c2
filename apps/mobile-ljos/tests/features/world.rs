//! The phone as main.rs builds it, one per scenario, as mobile-qt's
//! World (tests/World.*) and desktop-ljos's: a device of its own, an
//! empty home, and a pairing exchange the scenario sets
//! ([`World::set_exchange`]) in place of an MC that sells sessions, so a
//! scenario over pairing needs no socket. A scenario that pairs with a
//! real environment's rows wants the fake pairable MC mobile-qt has;
//! that is the harness's next piece (its scenarios stay undefined here
//! until then, as desktop-ljos's RATCHET grew).
//!
//! The window is a phone (412x915) until a step resizes it, which is
//! how a tablet, a rotation and a fold will be told. Steps act as a
//! user does: a touch (a finger's pointer) on the item with the
//! objectName, text typed into what has the keyboard.

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use hal_c2_mobile::pairing::Exchange;
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Connection, Mc};
use hal_c2_shell::streams::Pump;
use ljos::App;
use ljos::item::{KeyEvent, PointerEvent};
use ljos::prelude::{Engine, ObjectId, Value};
use ljos::testing::TestWindow;

use crate::harness::{Failure, Outcome};
use crate::{expect, fail};

/// A phone's window until a step gives it another size.
pub const PHONE: (f64, f64) = (412.0, 915.0);
/// The longest a step waits for anything, as desktop-ljos's World.
const WAIT: Duration = Duration::from_secs(5);

struct Shell {
    engine: Engine,
    window: TestWindow,
    streams: Pump,
    root: ObjectId,
}

pub struct World {
    home: tempfile::TempDir,
    shell: Option<Shell>,
    /// The exchange pairing spends links with; the network's until a
    /// step says (`hal_c2_mc::pairing::exchange`).
    exchange: Option<Exchange>,
    /// Where pairing.json goes instead of the home's data (a device
    /// with no room to save a session).
    pairing_path: Option<PathBuf>,
    /// The link the scenario is about.
    pub link: String,
    /// The window's size; a phone's until a step resizes it.
    size: (f64, f64),
}

impl World {
    pub fn new() -> World {
        let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).expect("a home for the phone");
        for dir in ["config/shell", "data", "state", "cache"] {
            std::fs::create_dir_all(home.path().join(dir)).expect("the phone's directories");
        }
        World {
            home,
            shell: None,
            // An MC that sells a session for every link, until a step
            // says otherwise: the harness's PairableMc stand-in.
            exchange: Some(fake_exchange(hal_c2_mc::pairing::Outcome::Paired, None)),
            pairing_path: None,
            link: String::new(),
            size: PHONE,
        }
    }

    pub fn home(&self) -> &Path {
        self.home.path()
    }

    /// Where the phone keeps its pairing (`<home>/data/pairing.json`, or
    /// what a step put in its place).
    pub fn pairing_file(&self) -> PathBuf {
        self.pairing_path
            .clone()
            .unwrap_or_else(|| self.home.path().join("data/pairing.json"))
    }

    pub fn is_open(&self) -> bool {
        self.shell.is_some()
    }

    pub fn set_exchange(&mut self, exchange: Exchange) {
        self.exchange = Some(exchange);
    }

    /// The device has no room to save a session: pairing.json would go
    /// under a file, so writing it fails and the old one stays.
    pub fn fill_storage(&mut self) {
        let blocker = self.home.path().join("full");
        std::fs::write(&blocker, "full").expect("a file in the way");
        self.pairing_path = Some(blocker.join("pairing.json"));
    }

    /// Opens the app as main.rs does, on this scenario's home.
    pub fn open(&mut self) -> Outcome {
        if self.shell.is_some() {
            // Back to the front is all an open app's opening is here.
            return self.pump();
        }
        let home = self.home.path().to_path_buf();
        let roots = hal_c2_mobile::roots().with_user(home.join("config/shell"));
        let dirs = roots.dirs().map_err(Failure)?;
        let engine = App::new("features-mobile")
            .locale("en_US")
            .register(hal_c2_mobile::register)
            .qml_dirs(dirs, "Main")
            .map_err(|e| Failure(e.to_string()))?
            .build_engine();
        let mut window = TestWindow::new(&engine, self.size.0, self.size.1);
        let mut streams = Pump::new(|| {});
        let wired = hal_c2_shell::streams::wire(&engine, &mut streams);
        let connection = Connection::spawn(&wired.mc);
        if let Some(exchange) = &self.exchange {
            hal_c2_mobile::pairing::set_exchange(&engine, exchange.clone());
        }
        let launch = Launch {
            config_dir: Some(home.join("config/shell")),
            qml: Some(roots),
            cache_dir: Some(home.join("cache")),
            data_dir: Some(home.join("data")),
            state_dir: Some(home.join("state")),
            browser_storage: Some("hal-c2-mobile-features".into()),
            ..Launch::default()
        };
        hal_c2_mobile::install(&engine, launch.data_dir.clone(), launch.config_dir.clone());
        if let Some(path) = &self.pairing_path {
            hal_c2_mobile::pairing::set_path(&engine, Some(path.clone()));
        }
        hal_c2_shell::start_with(
            &engine,
            &launch,
            connection as Rc<dyn Mc>,
            hal_c2_mobile::registrations(),
        );
        Bridge::of(&engine).set_local_folder_import_enabled(&engine, false);
        hal_c2_mobile::start(&engine);
        hal_c2_shell::theme::set_application_font(&engine);
        let root = hal_c2_shell::runtime::open(&engine, false).map_err(Failure)?;
        window.show(root).map_err(|e| Failure(e.to_string()))?;
        self.shell = Some(Shell {
            engine,
            window,
            streams,
            root,
        });
        self.pump()
    }

    pub fn engine(&self) -> &Engine {
        &self.shell.as_ref().expect("the app is running").engine
    }

    /// Hands everything waiting to whoever it is for, and lets the
    /// scene come to rest.
    pub fn pump(&mut self) -> Outcome {
        let Some(shell) = &mut self.shell else {
            return Ok(());
        };
        for _ in 0..32 {
            let drained = shell.streams.pump(&shell.engine);
            shell.window.settle().map_err(|e| Failure(e.to_string()))?;
            if drained == 0 {
                break;
            }
        }
        Ok(())
    }

    /// Pumps until `condition` holds, for up to five seconds of real
    /// time (an exchange on its own thread is real time), moving the
    /// window's clock with it.
    pub fn wait_for(
        &mut self,
        mut condition: impl FnMut(&World) -> bool,
        what: impl Fn(&World) -> String,
    ) -> Outcome {
        let started = Instant::now();
        loop {
            self.pump()?;
            if condition(self) {
                return Ok(());
            }
            if started.elapsed() >= WAIT {
                return Err(Failure(format!("timed out waiting for {}", what(self))));
            }
            if let Some(shell) = &mut self.shell {
                let _ = shell.window.advance(16);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// What `Shell.state[key]` holds; null while the app is closed.
    pub fn state(&self, key: &str) -> Json {
        self.shell
            .as_ref()
            .and_then(|shell| Bridge::of(&shell.engine).published(&shell.engine, key))
            .unwrap_or(Json::Null)
    }

    /// `Shell.dispatch(action, payload)`, as a brick sends it.
    pub fn dispatch(&mut self, action: &str, payload: Json) -> Outcome {
        let engine = self.engine().clone();
        Bridge::of(&engine).dispatch(&engine, action, payload);
        self.pump()
    }

    /// The item named `object_name` under the root, if there is one,
    /// however deep a Loader put it.
    pub fn find(&self, object_name: &str) -> Option<ObjectId> {
        let shell = self.shell.as_ref()?;
        fn walk(engine: &Engine, item: ObjectId, name: &str, depth: usize) -> Option<ObjectId> {
            if depth > 64 {
                return None;
            }
            if engine
                .to_js_string(&engine.read_by_name(item, "objectName"))
                .to_string()
                == name
            {
                return Some(item);
            }
            for child in engine.children(item) {
                if let Some(found) = walk(engine, child, name, depth + 1) {
                    return Some(found);
                }
            }
            None
        }
        walk(&shell.engine, shell.root, object_name, 0)
    }

    /// The item named `object_name`, which must be there.
    pub fn item(&self, object_name: &str) -> Outcome<ObjectId> {
        self.find(object_name)
            .ok_or_else(|| Failure(format!("no item named {object_name}")))
    }

    pub fn read(&self, item: ObjectId, name: &str) -> Value {
        self.engine().read_by_name(item, name)
    }

    pub fn text_of(&self, item: ObjectId, name: &str) -> String {
        self.engine()
            .to_js_string(&self.read(item, name))
            .to_string()
    }

    pub fn flag(&self, item: ObjectId, name: &str) -> bool {
        matches!(self.read(item, name), Value::Bool(true))
    }

    /// The item's centre in window coordinates.
    fn at(&self, item: ObjectId) -> Outcome<(f64, f64)> {
        let engine = self.engine();
        let (width, height) = (
            engine.read_by_name(item, "width").to_number(),
            engine.read_by_name(item, "height").to_number(),
        );
        match engine.invoke_by_name(
            item,
            "mapToItem",
            &[
                Value::Null,
                Value::from(width / 2.0),
                Value::from(height / 2.0),
            ],
        ) {
            Ok(Value::Point(point)) => Ok((point.x, point.y)),
            other => fail!("no point for the item: {other:?}"),
        }
    }

    /// A finger on the item named `object_name`, at its centre: a
    /// press and release through the window, as a tap reaches it. The
    /// events are the mouse's, which one finger is to what is under it
    /// in Qt and in Ljós both; naming them a finger's
    /// (`PointerSource::FINGER`) is not in the Ljós facade yet
    /// (hal-c2/ljos-ui#623), so a step that must tell touch from mouse — a
    /// MultiPointTouchArea with `mouseEnabled: false` — cannot be
    /// driven here until then.
    pub fn touch(&mut self, object_name: &str) -> Outcome {
        let item = self.item(object_name)?;
        let (visible, enabled) = (self.flag(item, "visible"), self.flag(item, "enabled"));
        expect!(
            visible && enabled,
            "{object_name} cannot be touched (visible {visible}, enabled {enabled})"
        );
        let (x, y) = self.at(item)?;
        let now = self
            .shell
            .as_ref()
            .expect("the app is running")
            .window
            .now();
        let shell = self.shell.as_mut().expect("the app is running");
        shell.window.pointer(&PointerEvent::press(x, y, now));
        shell.window.pointer(&PointerEvent::release(x, y, now));
        self.pump()
    }

    /// Types `text` into what has the keyboard, a key at a time.
    pub fn type_text(&mut self, text: &str) -> Outcome {
        let shell = self.shell.as_mut().expect("the app is running");
        expect!(
            shell.window.commit(text),
            "nothing with the keyboard took {text:?}"
        );
        self.pump()
    }

    /// A hardware key (the system Back is Escape's chord here until the
    /// harness has the host's Back; steps that need it come with it).
    pub fn key(&mut self, event: &KeyEvent) -> Outcome<bool> {
        let taken = self
            .shell
            .as_mut()
            .expect("the app is running")
            .window
            .key(event);
        self.pump()?;
        Ok(taken)
    }

    /// The window at another size, as a rotation, a split or a fold.
    pub fn resize(&mut self, width: f64, height: f64) -> Outcome {
        self.size = (width, height);
        if let Some(shell) = &mut self.shell {
            shell
                .window
                .resize(width, height)
                .map_err(|e| Failure(e.to_string()))?;
        }
        self.pump()
    }

    /// A `hal-c2:` link the system opens the app with.
    pub fn follow_link(&mut self, link: &str) -> Outcome {
        let engine = self.engine().clone();
        hal_c2_mobile::pairing::offer_link(&engine, link);
        self.pump()
    }
}

/// A pairing exchange that never reaches the network: `outcome` for
/// every link, with `next` as what a paid one bought.
pub fn fake_exchange(
    outcome: hal_c2_mc::pairing::Outcome,
    next: Option<(String, String, String)>,
) -> Exchange {
    Arc::new(move |link, _client| {
        let (label, environment_id, token) = next
            .clone()
            .unwrap_or_else(|| ("My MacBook".into(), "env-phone".into(), "session-1".into()));
        let mut descriptor = serde_json::Map::new();
        descriptor.insert("environmentId".into(), environment_id.into());
        descriptor.insert("label".into(), label.into());
        descriptor.insert(
            "orchestrationProtocolVersion".into(),
            hal_c2_mc::PROTOCOL.into(),
        );
        hal_c2_mc::pairing::Pairing {
            outcome,
            origin: link.origins.first().cloned().unwrap_or_default(),
            token: if outcome == hal_c2_mc::pairing::Outcome::Paired {
                token
            } else {
                String::new()
            },
            descriptor,
        }
    })
}
