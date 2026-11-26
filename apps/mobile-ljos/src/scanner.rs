//! `scanner`, mobile-qt's Scanner: pairing by pointing the camera
//! at a code. It owns the asking for the camera and runs it while
//! the scan screen shows, reads its frames off the drawing thread
//! ([`crate::qr_reader`]), and hands what a code says to Pairing
//! as the link it is. The camera itself is behind
//! [`crate::scan_camera`]'s seam.
//!
//! Publishes `scanner`:
//!   {scanning: frames are being read,
//!    access:   0 unknown, 1 asking or unasked, 2 granted, 3 denied,
//!    failed:   "" while the camera runs,
//!    message:  a sentence for the user, "" when none}
//!
//! Actions: `scanner.open {sink}` (the preview's sink, for the
//! frame producer that will feed it), `scanner.close`,
//! `scanner.requestAccess`, `scanner.openSettings`.

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

/// The published access numbers, as the screen reads them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum AccessState {
    #[default]
    Unknown = 0,
    Unasked = 1,
    Granted = 2,
    Denied = 3,
}

pub struct Scanner {
    bridge: Bridge,
    me: Me<Scanner>,
    camera: Rc<dyn ScanCamera>,
    /// The preview's sink, for the frame producer beside the camera.
    sink: Option<ObjectId>,
    open: bool,
    active: bool,
    access: AccessState,
    asking: bool,
    /// Read on open, when the system's word cannot change as the page shows.
    remembered: AccessState,
    failed: String,
    started: bool,
    message: String,
    /// Runs since the screen opened: the answers to a screen that
    /// has gone are dropped.
    generation: u64,
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
                        // Access may have been given back in the system's settings.
                        if active && c.open && c.access == AccessState::Denied {
                            c.access = AccessState::Unasked;
                            c.message.clear();
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
            access: AccessState::Unknown,
            asking: false,
            remembered: AccessState::Unknown,
            failed: String::new(),
            started: false,
            message: String::new(),
            generation: 0,
            reading: Rc::new(Cell::new(false)),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        match action {
            "scanner.open" => {
                // The sink reaches the controller as the QML value
                // it is where the bridge carries one; the producer
                // that will feed it is the Android side's (see
                // scan_camera), so nothing here needs it yet.
                let _ = payload;
                self.open_with(engine, None);
            }
            "scanner.close" => self.close(engine),
            "scanner.requestAccess" => self.request_access(engine),
            "scanner.openSettings" => self.camera.open_settings(engine),
            _ => return false,
        }
        true
    }
}

impl Scanner {
    pub fn open_with(&mut self, engine: &Engine, sink: Option<ObjectId>) {
        self.generation += 1;
        self.sink = sink;
        self.open = true;
        self.message.clear();
        self.access = if self.remembered == AccessState::Unknown {
            AccessState::Unasked
        } else {
            self.remembered
        };
        self.update(engine);
    }

    pub fn close(&mut self, engine: &Engine) {
        self.generation += 1;
        self.open = false;
        self.sink = None;
        self.update(engine);
        self.bridge.publish(engine, KEY, json!(null));
    }

    fn request_access(&mut self, engine: &Engine) {
        if self.asking {
            return;
        }
        self.message.clear();
        if self.access == AccessState::Granted {
            self.update(engine);
            return;
        }
        self.asking = true;
        self.publish(engine);
        let generation = self.generation;
        let me = self.me.clone();
        self.camera.request_access(
            engine,
            Rc::new(move |engine, access| {
                // A camera that answers at once (a test's, or a
                // system that has decided) still lands after this
                // controller returns.
                me.run_after(engine, move |c: &mut Scanner, engine| {
                    c.asking = false;
                    if generation != c.generation {
                        c.publish(engine);
                        return;
                    }
                    match access {
                        Access::Granted => c.access = AccessState::Granted,
                        Access::Denied => {
                            c.access = AccessState::Denied;
                            c.message = "Camera access was denied.".into();
                        }
                        Access::Undetermined => {
                            c.message = "Camera access was not decided. Try again.".into();
                        }
                    }
                    c.remembered = c.access;
                    c.update(engine);
                });
            }),
        );
    }

    /// The camera runs while the screen shows, the app is in front,
    /// and access is granted.
    fn update(&mut self, engine: &Engine) {
        if self.open
            && self.access == AccessState::Unasked
            && self.remembered == AccessState::Unknown
        {
            // The word is read here, after what open published: on
            // iOS the word is cached without the app having told the
            // OS about cameras.
            self.remembered = match self.camera.access(engine) {
                Access::Granted => AccessState::Granted,
                Access::Denied => AccessState::Denied,
                Access::Undetermined => AccessState::Unasked,
            };
            if self.remembered != AccessState::Unasked {
                self.access = self.remembered;
            }
        }
        let run = self.open && self.active && self.access == AccessState::Granted;
        if run == self.started {
            self.publish(engine);
            return;
        }
        self.started = run;
        if !run {
            self.camera.stop();
            self.publish(engine);
            return;
        }
        self.failed.clear();
        let generation = self.generation;
        let me = self.me.clone();
        let reading = self.reading.clone();
        self.camera.start(
            engine,
            self.sink,
            Rc::new(move |engine, frame| {
                let me = me.clone();
                let reading = reading.clone();
                me.run(engine, move |c: &mut Scanner, engine| {
                    if generation == c.generation {
                        c.frame(engine, frame, &reading, generation);
                    }
                });
            }),
            Rc::new({
                let me = self.me.clone();
                move |engine, failure| {
                    me.run(engine, move |c: &mut Scanner, engine| {
                        if generation != c.generation {
                            return;
                        }
                        c.failed = match failure {
                            Failure::NoCamera => "This device has no camera.".into(),
                            Failure::Stopped => {
                                "The camera stopped. Close anything else using it, then try again."
                                    .into()
                            }
                        };
                        c.publish(engine);
                    });
                }
            }),
        );
        self.publish(engine);
    }

    fn frame(&mut self, engine: &Engine, frame: Frame, reading: &Rc<Cell<bool>>, generation: u64) {
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
                    if generation == c.generation {
                        c.read(engine, texts);
                    }
                });
            },
        );
        if spawned.is_err() {
            reading.set(false);
        }
    }

    fn read(&mut self, engine: &Engine, texts: Vec<String>) {
        // Offline, pairing waits for the connection (read()).
        for text in texts {
            self.bridge
                .dispatch(engine, "pairing.pair", json!({"link": text}));
        }
    }

    fn publish(&self, engine: &Engine) {
        if !self.open {
            self.bridge.publish(engine, KEY, json!(null));
            return;
        }
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "scanning": self.started && self.failed.is_empty(),
                "access": self.access as i32,
                "failed": self.failed,
                "message": self.message,
            }),
        );
    }
}
