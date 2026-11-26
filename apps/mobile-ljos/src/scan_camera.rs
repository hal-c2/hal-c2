//! The device's camera as the scanner ([`crate::scanner`]) uses
//! it, mobile-qt's ScanCamera: whether the app may use it, asking
//! for that, frames while it runs, and word of it when it does not.
//! The scenarios put one of their own here, which is how they hand
//! the scanner a picture as a camera frame.
//!
//! The device's own ([`device_camera`]) asks through Ljós's
//! CameraPermission (QtCore, hal-c2/ljos-ui#772: the Android
//! runtime permission behind it), and has no frames to give yet:
//! Ljós has no camera capture type, so a started camera fails
//! NoCamera until a frame producer exists — on Android, CameraX
//! through the JNI template slot (hal-c2/ljos-ui#616), feeding both
//! the preview sink and these frames. That producer is the one
//! piece of the phone's scanning still waiting on Ljós; everything
//! above this seam is ported and tested against a fake.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use hal_c2_shell::schedule::{self, Held};
use ljos::prelude::{Engine, ObjectId, Permission, PermissionStatus, Platform};

use crate::qr_reader::Frame;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Access {
    #[default]
    Undetermined,
    Granted,
    Denied,
}

/// Why a camera that was started gives no frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    /// The device has none.
    NoCamera,
    /// It did not start, or stopped by itself: another app has it,
    /// it was unplugged.
    Stopped,
}

/// The system's word on asking for access, once.
pub type Answered = Rc<dyn Fn(&Engine, Access)>;
/// A frame arrived.
pub type OnFrame = Rc<dyn Fn(&Engine, Frame)>;
/// The camera failed, once, on a later turn than the start.
pub type OnFailed = Rc<dyn Fn(&Engine, Failure)>;

pub trait ScanCamera {
    fn access(&self, engine: &Engine) -> Access;
    /// Asks the user, where the system still does: one that has been
    /// told no for good answers Denied at once. `answered` is
    /// called once.
    fn request_access(&self, engine: &Engine, answered: Answered);
    /// Frames go to `on_frame` from now until stop, and to the
    /// preview `sink` where there is one. A camera says only later
    /// whether it started, and may stop by itself at any time
    /// after: `failed` is called then, once, on a later turn of
    /// the event loop, and never after stop. A camera that failed
    /// is still held until stop.
    fn start(&self, engine: &Engine, sink: Option<ObjectId>, on_frame: OnFrame, failed: OnFailed);
    /// Lets go of the camera; nothing when it was not started.
    fn stop(&self);
    /// The app's page in the system's settings, where access is
    /// given back.
    fn open_settings(&self, engine: &Engine);
}

/// Where a test's camera is, as every start reads it.
#[derive(Default)]
struct Where {
    camera: RefCell<Option<Rc<dyn ScanCamera>>>,
}

/// Lets a test put its own camera here (its FakeCamera). Before start.
pub fn set_camera(engine: &Engine, camera: Rc<dyn ScanCamera>) {
    *engine.extension::<Where>().camera.borrow_mut() = Some(camera);
}

/// This device's camera, or a test's.
pub fn camera(engine: &Engine) -> Rc<dyn ScanCamera> {
    engine
        .extension::<Where>()
        .camera
        .borrow()
        .clone()
        .unwrap_or_else(device_camera)
}

fn access_of(status: PermissionStatus) -> Access {
    match status {
        PermissionStatus::Granted => Access::Granted,
        PermissionStatus::Denied => Access::Denied,
        PermissionStatus::Undetermined => Access::Undetermined,
    }
}

/// This device's camera, through Ljós's permissions: the back one
/// when it has one, once frames can come from anywhere.
pub fn device_camera() -> Rc<dyn ScanCamera> {
    Rc::new(DeviceCamera::default())
}

#[derive(Default)]
struct DeviceCamera {
    /// The CameraPermission object requests are made through.
    permission: RefCell<Option<ObjectId>>,
    /// A failed start answering on a later turn.
    failing: Held,
    started: Cell<bool>,
}

impl DeviceCamera {
    fn permission_object(&self, engine: &Engine) -> Option<ObjectId> {
        if let Some(object) = *self.permission.borrow() {
            return Some(object);
        }
        let object = engine
            .create_by_name("QtCore", "CameraPermission", None)
            .ok()?;
        *self.permission.borrow_mut() = Some(object);
        Some(object)
    }

    fn status(&self, engine: &Engine) -> PermissionStatus {
        Platform::of(engine)
            .permissions()
            .status(Permission::Camera)
    }
}

impl ScanCamera for DeviceCamera {
    fn access(&self, engine: &Engine) -> Access {
        access_of(self.status(engine))
    }

    fn request_access(&self, engine: &Engine, answered: Answered) {
        let access = self.access(engine);
        if access != Access::Undetermined {
            answered(engine, access);
            return;
        }
        let Some(object) = self.permission_object(engine) else {
            answered(engine, Access::Denied);
            return;
        };
        // The answer comes when the status is decided, as
        // QPermission's statusChanged brings it.
        let replied = Rc::new(Cell::new(false));
        let _ = engine.connect_by_name(object, "statusChanged", {
            let answered = answered.clone();
            move |engine, _| {
                if replied.replace(true) {
                    return;
                }
                let status = Platform::of(engine)
                    .permissions()
                    .status(Permission::Camera);
                if status != PermissionStatus::Undetermined {
                    answered(engine, access_of(status));
                } else {
                    replied.set(false);
                }
            }
        });
        let _ = engine.invoke_by_name(object, "request", &[]);
    }

    fn start(
        &self,
        engine: &Engine,
        _sink: Option<ObjectId>,
        _on_frame: OnFrame,
        failed: OnFailed,
    ) {
        // No frames can come from anywhere yet (the seam's note
        // above): failed on a later turn, as a camera that did not
        // start says so.
        self.started.set(true);
        let timer = schedule::after(
            engine,
            "scan camera failed",
            None,
            std::time::Duration::ZERO,
            move |engine| failed(engine, Failure::NoCamera),
        );
        self.failing.hold(engine, timer);
    }

    fn stop(&self) {
        self.started.set(false);
    }

    fn open_settings(&self, engine: &Engine) {
        // The app's page, where the system has one to open; a system
        // with no such page does nothing, as the QML fallback over
        // an unknown scheme does.
        let _ = Platform::of(engine).open_url().open("app-settings:");
    }
}
