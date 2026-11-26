//! `scanner`, mobile-qt's Scanner: pairing by pointing the camera
//! at a code. It owns the asking for the camera and runs it while
//! the scan screen shows, reads its frames off the drawing thread
//! ([`crate::qr_reader`]), and hands what a code says to Pairing
//! as the link it is. The camera itself is behind
//! [`crate::scan_camera`]'s seam.
//!
//! Publishes `scanner`, as `MobileShell.qml` and `ScanScreen.qml`
//! read it (mobile-qt's Scanner::publish):
//!   {open:    the scan screen shows,
//!    access:  "asking" | "granted" | "denied" | "unknown",
//!    failed:  the camera gives no picture,
//!    message: a sentence for the user, "" when none}
//!
//! Actions: `scanner.open`, `scanner.close`,
//! `scanner.preview {sink}` (the preview's sink, for the frame
//! producer that will feed it), `scanner.settings`,
//! `scanner.retry`; `scanner.requestAccess` and
//! `scanner.openSettings` are kept as aliases of the asking and
//! the settings.

use std::cell::Cell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{Controller, Init, Me};
use hal_c2_shell::json::Json;
use ljos::prelude::{Application, Engine, ObjectId, Value};
use serde_json::json;

use crate::qr_reader::{self, Frame};
use crate::scan_camera::{self, Access, Failure, ScanCamera};

const KEY: &str = "scanner";

pub struct Scanner {
    bridge: Bridge,
    me: Me<Scanner>,
    camera: Rc<dyn ScanCamera>,
    /// The preview's sink, for the frame producer beside the camera.
    sink: Option<ObjectId>,
    open: bool,
    active: bool,
    access: Access,
    asking: bool,
    failed: bool,
    started: bool,
    message: String,
    /// The camera run in flight: each start is a new one, and a
    /// frame read (or a failure) from an older run is dropped,
    /// however soon a new run follows.
    run: u64,
    /// A frame is being read.
    reading: Rc<Cell<bool>>,
}

impl Controller for Scanner {
    fn new(init: Init<'_, Self>) -> Self {
        let camera = scan_camera::camera(init.engine);
        if let Ok(app) = init.engine.singleton::<Application>() {
            let me = init.me.clone();
            let _ = init
                .engine
                .connect_by_name(app, "activeChanged", move |engine, _| {
                    let active = matches!(engine.read_by_name(app, "active"), Value::Bool(true));
                    me.run(engine, move |c: &mut Scanner, engine| {
                        c.active = active;
                        // Behind another app the camera is off; back
                        // at the front, the user may have been to
                        // the system's settings to allow it.
                        if active && c.open && !c.asking {
                            c.access = c.camera.access(engine);
                        }
                        c.update(engine);
                    });
                });
        }
        Scanner {
            bridge: init.bridge,
            me: init.me,
            camera,
            sink: None,
            open: false,
            active: true,
            access: Access::Undetermined,
            asking: false,
            failed: false,
            started: false,
            message: String::new(),
            run: 0,
            reading: Rc::new(Cell::new(false)),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        match action {
            "scanner.open" => self.open(engine),
            "scanner.close" => self.close(engine),
            "scanner.preview" => self.preview(engine),
            "scanner.settings" | "scanner.openSettings" => self.camera.open_settings(engine),
            "scanner.retry" => self.retry(engine),
            "scanner.requestAccess" => self.request_access(engine),
            _ => return false,
        }
        true
    }
}

impl Scanner {
    pub fn open(&mut self, engine: &Engine) {
        if self.open {
            return;
        }
        self.open = true;
        self.access = self.camera.access(engine);
        // Asked whenever the app does not have it: only the system
        // knows whether it will still put the question, and it
        // answers at once when it will not.
        if self.access != Access::Granted && !self.asking {
            self.ask(engine);
        }
        self.update(engine);
    }

    pub fn close(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        self.open = false;
        self.failed = false;
        self.message.clear();
        self.sink = None;
        self.update(engine);
    }

    /// The screen's preview is up. The sink reaches the controller
    /// as a QML value the bridge cannot carry as an object yet,
    /// and no frame producer feeds it on this host (scan_camera's
    /// note), so for now the action only says the screen is there:
    /// the camera's frames come through the seam's callback.
    fn preview(&mut self, engine: &Engine) {
        self.update(engine);
    }

    fn retry(&mut self, engine: &Engine) {
        if !self.open || !self.failed {
            return;
        }
        self.failed = false;
        self.message.clear();
        self.update(engine);
    }

    fn request_access(&mut self, engine: &Engine) {
        self.message.clear();
        if self.access == Access::Granted || self.asking {
            self.update(engine);
            return;
        }
        self.ask(engine);
        self.publish(engine);
    }

    fn ask(&mut self, engine: &Engine) {
        self.asking = true;
        let me = self.me.clone();
        self.camera.request_access(
            engine,
            Rc::new(move |engine, answered| {
                // A camera that answers at once (a test's, or a
                // system that has decided) still lands after this
                // controller returns.
                me.run_after(engine, move |c: &mut Scanner, engine| {
                    c.asking = false;
                    c.access = answered;
                    c.update(engine);
                });
            }),
        );
    }

    fn failure(&mut self, engine: &Engine, why: Failure) {
        // The camera's to let go of, for whichever app has it now;
        // what a frame from before held is dropped with it (found
        // checks the run).
        self.camera.stop();
        self.started = false;
        self.failed = true;
        self.message = match why {
            Failure::NoCamera => {
                "This device has no camera. Go back and enter the pairing link instead.".into()
            }
            Failure::Stopped => "The camera cannot be used right now. Another app may be using it: close that app and try again, or go back and enter the pairing link.".into(),
        };
        self.publish(engine);
    }

    /// The camera runs while the screen shows, the app is in
    /// front, access is granted and it has not failed.
    fn update(&mut self, engine: &Engine) {
        let wanted = self.open && !self.failed && self.access == Access::Granted && self.active;
        if wanted && !self.started {
            self.started = true;
            self.run += 1;
            let run = self.run;
            let me = self.me.clone();
            let reading = self.reading.clone();
            self.camera.start(
                engine,
                self.sink,
                Rc::new(move |engine, frame| {
                    let me = me.clone();
                    let reading = reading.clone();
                    // A camera may deliver its first frame from
                    // inside start: take it after update returns.
                    me.run_after(engine, move |c: &mut Scanner, engine| {
                        if c.started && run == c.run {
                            c.frame(engine, frame, &reading, run);
                        }
                    });
                }),
                Rc::new({
                    let me = self.me.clone();
                    move |engine, failure| {
                        me.run(engine, move |c: &mut Scanner, engine| {
                            if run == c.run && c.started {
                                c.failure(engine, failure);
                            }
                        });
                    }
                }),
            );
        } else if !wanted && self.started {
            self.camera.stop();
            self.started = false;
        }
        self.publish(engine);
    }

    fn frame(&mut self, engine: &Engine, frame: Frame, reading: &Rc<Cell<bool>>, run: u64) {
        if !self.started || reading.get() {
            return;
        }
        let Some(picture) = qr_reader::luminance(&frame) else {
            return;
        };
        reading.set(true);
        let me = self.me.clone();
        let done = reading.clone();
        let spawned = ljos::task::spawn(
            engine,
            move || qr_reader::read(&picture),
            move |engine, texts| {
                done.set(false);
                let texts = texts.unwrap_or_default();
                me.run(engine, move |c: &mut Scanner, engine| {
                    // Read off a frame from before the camera
                    // stopped, even if it runs again.
                    if c.started && run == c.run {
                        c.found(engine, texts);
                    }
                });
            },
        );
        if spawned.is_err() {
            reading.set(false);
        }
    }

    fn found(&mut self, engine: &Engine, texts: Vec<String>) {
        if texts.is_empty() {
            return;
        }
        for text in &texts {
            if let Some(invitation) = hal_c2_mc::pairing::read_invitation(text) {
                let link = invitation.link;
                self.close(engine);
                self.bridge
                    .dispatch(engine, "pairing.pair", json!({"link": link}));
                return;
            }
        }
        self.message = "That is not a HAL-C2 pairing code. Scan the code under Settings → Connections on the machine that runs HAL-C2.".into();
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        let access = if self.asking {
            "asking"
        } else {
            match self.access {
                Access::Granted => "granted",
                Access::Denied => "denied",
                Access::Undetermined => "unknown",
            }
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": self.open,
                "access": access,
                "failed": self.failed,
                "message": self.message,
            }),
        );
    }
}
