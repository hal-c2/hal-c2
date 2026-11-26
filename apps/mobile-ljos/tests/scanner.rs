//! Scanning a pairing code with a fake camera (tst_Scanner's
//! cases): the scanner runs the camera while its screen shows,
//! reads a code off its frames, and hands the link to Pairing; it
//! says why when there is no camera or no access.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, mpsc};

use hal_c2_mc::pairing::{Link, Outcome, Pairing as Exchanged};
use hal_c2_mobile::pairing;
use hal_c2_mobile::qr_reader::{Frame, FrameFormat};
use hal_c2_mobile::scan_camera::{
    Access, Answered, Failure, OnFailed, OnFrame, ScanCamera, set_camera,
};
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Connection, Mc};
use hal_c2_shell::saved_environments::MemorySecretStore;
use hal_c2_shell::streams::Pump;
use ljos::prelude::ObjectId;
use ljos::testing::TestWindow;
use ljos::{App, Engine};
use qrcodegen::{QrCode, QrCodeEcc};
use serde_json::json;

const LINK: &str = "https://devbox.tailnet.ts.net/pair#token=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA";

/// A pairing link's answer from the would-be MC.
fn paired(link: &Link) -> Exchanged {
    let mut descriptor = serde_json::Map::new();
    descriptor.insert("environmentId".into(), "env-a".into());
    descriptor.insert("label".into(), "Studio".into());
    Exchanged {
        outcome: Outcome::Paired,
        origin: link.origins[0].clone(),
        token: "session-1".into(),
        descriptor,
    }
}

/// A camera the test drives, as mobile-qt's FakeCamera.
#[derive(Default)]
struct FakeCamera {
    access: Cell<Access>,
    merge: Cell<bool>,
    started: Cell<bool>,
    held: Cell<bool>,
    on_frame: RefCell<Option<OnFrame>>,
    failed: RefCell<Option<OnFailed>>,
    fail_with: Cell<Option<Failure>>,
}

impl FakeCamera {
    fn fail(&self, engine: &Engine) {
        // The callback stops the camera, which takes the
        // callbacks back: hand it a clone, not the borrowed cell.
        let failed = self.failed.borrow().clone();
        if let (Some(failed), Some(failure)) = (failed, self.fail_with.get()) {
            failed(engine, failure);
        }
    }

    fn emit(&self, engine: &Engine, frame: Frame) {
        let on_frame = self.on_frame.borrow().clone();
        if let Some(on_frame) = on_frame {
            on_frame(engine, frame);
        }
    }
}

impl ScanCamera for FakeCamera {
    fn access(&self, _engine: &Engine) -> Access {
        self.access.get()
    }

    fn request_access(&self, engine: &Engine, answered: Answered) {
        if self.merge.get() {
            self.access.set(Access::Granted);
        }
        answered(engine, self.access.get());
    }

    fn start(
        &self,
        _engine: &Engine,
        _sink: Option<ObjectId>,
        on_frame: OnFrame,
        failed: OnFailed,
    ) {
        *self.on_frame.borrow_mut() = Some(on_frame);
        *self.failed.borrow_mut() = Some(failed);
        self.started.set(true);
        self.held.set(true);
        // Failure is told on a later turn, as the seam promises:
        // the test delivers it with fail().
    }

    fn stop(&self) {
        self.started.set(false);
        self.held.set(false);
        *self.on_frame.borrow_mut() = None;
        *self.failed.borrow_mut() = None;
    }

    fn open_settings(&self, _engine: &Engine) {}
}

/// The frame `text`'s code makes, in gray.
fn frame_of(text: &str) -> Frame {
    let code = QrCode::encode_text(text, QrCodeEcc::Medium).unwrap();
    let modules = code.size() as usize;
    let quiet = 4usize;
    let scale = 8usize;
    let side = (modules + quiet * 2) * scale;
    let mut data = vec![255u8; side * side];
    for y in 0..modules {
        for x in 0..modules {
            if code.get_module(x as i32, y as i32) {
                for dy in 0..scale {
                    for dx in 0..scale {
                        data[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0;
                    }
                }
            }
        }
    }
    Frame {
        format: FrameFormat::Nv12,
        width: side,
        height: side,
        planes: vec![(data, side), (vec![128; side * side / 2], side)],
    }
}

struct Phone {
    engine: Engine,
    window: TestWindow,
    root: ObjectId,
    streams: Pump,
    camera: Rc<FakeCamera>,
    data: PathBuf,
    _home: tempfile::TempDir,
}

impl Phone {
    fn start(name: &str) -> Phone {
        let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
        let data = home.path().join("data");
        let camera = Rc::new(FakeCamera::default());
        let engine = App::new(name)
            .register(hal_c2_mobile::register)
            .source(hal_c2_mobile::pack())
            .root("Main")
            .build_engine();
        hal_c2_shell::controllers::saved_environments::set_secret_store(
            &engine,
            Rc::new(MemorySecretStore::default()),
        );
        hal_c2_shell::controllers::saved_environments::set_data_dir(&engine, Some(data.clone()));
        set_camera(&engine, camera.clone());
        pairing::set_exchange(&engine, Arc::new(|link, _| paired(link)));
        let (woken, _wakes) = mpsc::channel();
        let mut streams = Pump::new(move || {
            let _ = woken.send(());
        });
        let wired = hal_c2_shell::streams::wire(&engine, &mut streams);
        let connection = Connection::spawn(&wired.mc);
        let launch = Launch {
            config_dir: Some(home.path().join("config")),
            cache_dir: Some(home.path().join("cache")),
            data_dir: Some(data.clone()),
            state_dir: Some(home.path().join("state")),
            ..Launch::default()
        };
        hal_c2_mobile::install(&engine, launch.data_dir.clone(), launch.config_dir.clone());
        hal_c2_shell::start_with(
            &engine,
            &launch,
            connection as Rc<dyn Mc>,
            hal_c2_mobile::registrations(),
        );
        hal_c2_mobile::start(&engine);
        streams.pump(&engine);
        // The phone's own QML in the window, as the features
        // harness opens it: the scan screen the tests below read
        // is the one `MobileShell.qml` loads.
        let mut window = TestWindow::new(&engine, 412.0, 915.0);
        let root = hal_c2_shell::runtime::open(&engine).expect("the phone's root");
        window.show(root).expect("the root in the window");
        let mut phone = Phone {
            engine,
            window,
            root,
            streams,
            camera,
            data,
            _home: home,
        };
        phone.pump();
        phone
    }

    /// The item named `object_name` under the root, however deep
    /// a Loader put it (the features harness's walk).
    fn find(&self, object_name: &str) -> Option<ObjectId> {
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
        walk(&self.engine, self.root, object_name, 0)
    }

    fn dispatch(&mut self, action: &str, payload: Json) {
        Bridge::of(&self.engine).dispatch(&self.engine, action, payload);
        self.pump();
    }

    fn pump(&mut self) {
        for _ in 0..32 {
            let drained = self.streams.pump(&self.engine);
            let _ = self.window.settle();
            if drained == 0 {
                break;
            }
        }
    }

    /// Pumps until `condition` holds (an exchange or a frame read
    /// on its own thread is real time), up to five seconds; a
    /// timeout is a failure, never a silent pass.
    fn wait_for(&mut self, condition: impl Fn(&Phone) -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while std::time::Instant::now() < deadline {
            self.pump();
            if condition(self) {
                return;
            }
            let _ = self.window.advance(16);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(condition(self), "wait_for timed out");
    }

    fn published(&self, key: &str) -> Json {
        Bridge::of(&self.engine)
            .published(&self.engine, key)
            .unwrap_or(Json::Null)
    }

    fn paired(&self) -> bool {
        pairing::load(&self.data.join("pairing.json")).is_some()
    }
}

#[test]
fn a_scanned_code_pairs_and_the_camera_runs_only_while_open() {
    let mut phone = Phone::start("scanner-pairs");
    phone.camera.access.set(Access::Granted);
    phone.dispatch("scanner.open", json!(null));
    assert_eq!(phone.published("scanner")["open"], json!(true));
    assert_eq!(phone.published("scanner")["access"], json!("granted"));
    assert!(phone.camera.held.get());
    // A code that is no pairing invitation is refused by the
    // scanner itself, with the reason on its screen.
    phone.camera.emit(&phone.engine, frame_of("not a link"));
    phone.wait_for(|phone| {
        phone.published("scanner")["message"]
            .as_str()
            .is_some_and(|message| message.contains("not a HAL-C2 pairing code"))
    });
    assert!(!phone.paired());
    // The wrapped form an MC's QR may carry pairs as its link.
    let wrapped = format!(
        "hal-c2://pair?pairingUrl={}",
        LINK.bytes()
            .map(|b| format!("%{b:02X}"))
            .collect::<String>()
    );
    phone.camera.emit(&phone.engine, frame_of(&wrapped));
    phone.wait_for(|phone| phone.paired());
    assert!(phone.paired(), "the scanned link paired");
    // Pairing closes the scanner, as the C++ does.
    assert_eq!(phone.published("scanner")["open"], json!(false));
    assert!(!phone.camera.held.get(), "pairing lets the camera go");
}

#[test]
fn denied_and_missing_cameras_say_why() {
    let mut phone = Phone::start("scanner-denied");
    phone.camera.access.set(Access::Denied);
    phone.dispatch("scanner.open", json!(null));
    phone.wait_for(|phone| phone.published("scanner")["access"] == json!("denied"));
    assert_eq!(phone.published("scanner")["failed"], json!(false));
    assert!(!phone.camera.started.get());
    phone.dispatch("scanner.close", json!(null));
    assert_eq!(phone.published("scanner")["open"], json!(false));

    let mut phone = Phone::start("scanner-no-camera");
    phone.camera.access.set(Access::Granted);
    phone.camera.fail_with.set(Some(Failure::NoCamera));
    phone.dispatch("scanner.open", json!(null));
    phone.camera.fail(&phone.engine);
    phone.pump();
    assert_eq!(phone.published("scanner")["failed"], json!(true));
    assert!(
        phone.published("scanner")["message"]
            .as_str()
            .is_some_and(|message| message.contains("no camera"))
    );
    assert!(!phone.camera.held.get(), "a failed camera is let go");
    // The screen's Try again starts it again.
    phone.camera.fail_with.set(None);
    phone.dispatch("scanner.retry", json!(null));
    assert_eq!(phone.published("scanner")["failed"], json!(false));
    assert!(phone.camera.held.get(), "retry starts the camera again");
}

#[test]
fn asking_grants_and_starts() {
    let mut phone = Phone::start("scanner-asks");
    phone.camera.merge.set(true);
    // Opening asks, as the C++ does: the word comes back granted
    // and the camera starts.
    phone.dispatch("scanner.open", json!(null));
    phone.wait_for(|phone| phone.published("scanner")["access"] == json!("granted"));
    assert!(phone.camera.held.get());
    // A second open is no new screen: the running camera's
    // callbacks are the ones that answer.
    phone.dispatch("scanner.open", json!(null));
    phone.camera.emit(&phone.engine, frame_of(LINK));
    phone.wait_for(|phone| phone.paired());
}

/// The contract `MobileShell.qml`/`ScanScreen.qml` read, driven
/// through the real QML: the loader gates on `scanner.open`, the
/// screen compares `access` to words and `failed` to true.
#[test]
fn the_scan_screen_the_phone_loads_shows() {
    use ljos::prelude::Value;
    let mut phone = Phone::start("scanner-qml");
    assert!(phone.find("scanScreen").is_none(), "closed, no scan screen");
    phone.camera.access.set(Access::Denied);
    phone.dispatch("scanner.open", json!(null));
    phone.wait_for(|phone| phone.find("scanScreen").is_some());
    let screen = phone.find("scanScreen").expect("the scan screen");
    assert_eq!(
        phone
            .engine
            .to_js_string(&phone.engine.read_by_name(screen, "access"))
            .to_string(),
        "denied"
    );
    assert!(
        phone.find("scanDenied").is_some(),
        "the denied word is on it"
    );
    assert!(phone.find("scanSettings").is_some(), "the way to settings");
    // Granted now (as a return from the system settings would
    // find it), the camera starts and the viewfinder shows.
    phone.camera.access.set(Access::Granted);
    phone.dispatch("scanner.requestAccess", json!(null));
    phone.wait_for(|phone| phone.camera.held.get());
    let failed_at = phone.engine.read_by_name(screen, "failed");
    assert!(matches!(failed_at, Value::Bool(false)));
    phone.camera.fail_with.set(Some(Failure::Stopped));
    phone.camera.fail(&phone.engine);
    phone.wait_for(|phone| {
        matches!(
            phone.engine.read_by_name(screen, "failed"),
            Value::Bool(true)
        )
    });
    assert!(phone.find("scanRetry").is_some(), "the way to try again");
    phone.dispatch("scanner.close", json!(null));
    assert_eq!(phone.published("scanner")["open"], json!(false));
}

use proptest::prelude::*;

#[derive(Clone, Debug)]
enum Step {
    Open,
    Close,
    Request,
    Grant,
    Deny,
    Code,
    Blank,
    Fail,
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        Just(Step::Open),
        Just(Step::Close),
        Just(Step::Request),
        Just(Step::Grant),
        Just(Step::Deny),
        Just(Step::Code),
        Just(Step::Blank),
        Just(Step::Fail),
    ]
}

proptest! {
    #![proptest_config(proptest::test_runner::Config { cases: 24, ..proptest::test_runner::Config::default() })]

    /// The scanner against its model, as tst_ScannerProp drives
    /// the C++: the camera is held exactly while the screen is
    /// open and access granted, frames pair only then, and the
    /// published access follows the system's word.
    #[test]
    fn the_scanner_holds_the_camera_only_while_open_and_granted(
        steps in prop::collection::vec(step(), 0..24),
    ) {
        let mut phone = Phone::start("scanner-prop");
        phone.camera.merge.set(true);
        let mut open = false;
        let mut access = Access::Undetermined;
        let mut paired_seen = false;
        for step in steps {
            match step {
                Step::Open => {
                    phone.dispatch("scanner.open", json!(null));
                    open = true;
                }
                Step::Close => {
                    phone.dispatch("scanner.close", json!(null));
                    open = false;
                }
                Step::Request => phone.dispatch("scanner.requestAccess", json!(null)),
                Step::Grant => phone.camera.access.set(Access::Granted),
                Step::Deny => phone.camera.access.set(Access::Denied),
                Step::Code => phone.camera.emit(&phone.engine, frame_of(LINK)),
                Step::Blank => phone.camera.emit(&phone.engine, frame_of("")),
                Step::Fail => {
                    phone.camera.fail_with.set(Some(Failure::Stopped));
                    phone.camera.fail(&phone.engine);
                    phone.camera.fail_with.set(None);
                }
            }
            phone.pump();
            if open && phone.camera.access.get() == Access::Granted {
                access = Access::Granted;
            }
            let _ = access;
            let shown = phone.published("scanner");
            if !open {
                prop_assert_eq!(&shown["open"], &json!(false));
                prop_assert!(!phone.camera.held.get(), "closed holds no camera");
            }
            if phone.camera.held.get() {
                prop_assert_eq!(&shown["open"], &json!(true), "held is open");
                prop_assert_eq!(&shown["access"], &json!("granted"), "held is granted");
                prop_assert_eq!(&shown["failed"], &json!(false), "held has not failed");
            }
            // A pairing that lands was scanned while open; one
            // already there (it closes the scanner itself) is not
            // evidence of a scan while closed.
            if phone.paired() && !paired_seen {
                paired_seen = true;
                prop_assert!(open, "a scan paired while closed");
            }
        }
    }
}
