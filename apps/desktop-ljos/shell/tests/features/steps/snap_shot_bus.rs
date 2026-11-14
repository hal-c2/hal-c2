//! The desktop portal (org.freedesktop.portal.Desktop) as the portal
//! backend's wire, desktop-qt's FakeDesktopPortal: its Screenshot
//! properties and the GlobalShortcuts session, prompt and signals, so
//! [`portal::Portal`] runs as it does on a desktop without a bus. What the
//! portal says waits in the bus until [`settle`] hands it to the shell.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::controllers::snap_shot::deliver;
use hal_c2_shell::snap_shot::portal::{self, Bound, Call, Input, Results, Wire};
use hal_c2_shell::snap_shot::{Backend, Captured, Platform, PortalFactory};
use image::{Rgba, RgbaImage};
use ljos::prelude::Engine;
use serde_json::Value;

const PATH: &str = "/org/freedesktop/portal/desktop";
/// The app's part of the portal's request and session paths.
const SENDER: &str = "1_5";

/// How the desktop answers BindShortcuts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Answer {
    #[default]
    Grant,
    Unassigned,
    Nothing,
    Refuse,
    Hold,
}

#[derive(Clone, Debug)]
pub(crate) struct PortalDesktop {
    pub shortcuts_version: u32,
    /// Captures the window in front; false gives only the picker.
    pub window_capture: bool,
    /// Properties.GetAll(Screenshot) fails, or waits for `answer_screenshot`.
    pub screenshot_fails: bool,
    pub hold_screenshot: bool,
    pub session_fails: bool,
    pub bind: Answer,
    /// The keys the desktop shows for a granted shortcut; else the trigger's.
    pub label: String,
}

impl Default for PortalDesktop {
    fn default() -> PortalDesktop {
        PortalDesktop {
            shortcuts_version: 2,
            window_capture: true,
            screenshot_fails: false,
            hold_screenshot: false,
            session_fails: false,
            bind: Answer::Grant,
            label: String::new(),
        }
    }
}

/// The portal and what it was asked.
#[derive(Default)]
pub(crate) struct Bus {
    /// The shell's backend is the portal on this bus.
    pub active: bool,
    pub desktop: PortalDesktop,
    pub creates: usize,
    pub closes: usize,
    pub configures: usize,
    /// Each BindShortcuts' preferred trigger.
    pub triggers: Vec<String>,
    session: String,
    shortcut_id: String,
    trigger: String,
    /// The held prompt's request.
    held: Option<String>,
    held_screenshot: bool,
    /// Nothing owns the portal's name.
    dropped: bool,
    inbox: Vec<Input>,
}

thread_local! {
    static BUS: Rc<RefCell<Bus>> = Rc::new(RefCell::new(Bus::default()));
}

pub(crate) fn bus() -> Rc<RefCell<Bus>> {
    BUS.with(Rc::clone)
}

/// The trigger as a desktop names it: CTRL+SHIFT+2 is Ctrl+Shift+2.
pub(crate) fn describe(trigger: &str) -> String {
    trigger
        .split('+')
        .map(|part| match part {
            "CTRL" => "Ctrl",
            "SHIFT" => "Shift",
            "ALT" => "Alt",
            "LOGO" => "Super",
            other => other,
        })
        .collect::<Vec<_>>()
        .join("+")
}

impl Bus {
    /// A fresh desktop that owns the portal's name, with no session.
    pub fn reset(&mut self) {
        let active = self.active;
        *self = Bus::default();
        self.active = active;
    }

    /// The user presses the shortcut the desktop holds for HAL-C2.
    pub fn press(&mut self) {
        let session = self.session.clone();
        let id = self.shortcut_id.clone();
        self.inbox.push(Input::Activated { session, id });
    }

    pub fn session_open(&self) -> bool {
        !self.session.is_empty()
    }

    pub fn prompting(&self) -> bool {
        self.held.is_some()
    }

    pub fn screenshot_held(&self) -> bool {
        self.held_screenshot
    }

    fn properties(&self) -> Input {
        let targets = if self.desktop.window_capture { 8 } else { 1 };
        Input::Properties(Some((3, targets)))
    }

    fn granted(&self, label: &str) -> Results {
        Results {
            shortcuts: vec![Bound {
                id: self.shortcut_id.clone(),
                trigger: label.to_owned(),
            }],
            ..Results::default()
        }
    }

    fn label(&self) -> String {
        if self.desktop.label.is_empty() {
            describe(&self.trigger)
        } else {
            self.desktop.label.clone()
        }
    }

    fn respond(&mut self, handle: String, status: u32, results: Results) {
        self.inbox.push(Input::Response {
            handle,
            status,
            results,
        });
    }

    /// The held prompt: the user approves (or refuses) it.
    pub fn answer(&mut self, approve: bool) -> Result<(), String> {
        let request = self.held.take().ok_or("no shortcut prompt is open")?;
        if approve {
            let results = self.granted(&self.label());
            self.respond(request, 0, results);
        } else {
            self.respond(request, 1, Results::default());
        }
        Ok(())
    }

    pub fn answer_screenshot(&mut self) -> Result<(), String> {
        if !std::mem::take(&mut self.held_screenshot) {
            return Err("no screenshot check is waiting".into());
        }
        self.desktop.hold_screenshot = false;
        let input = self.properties();
        self.inbox.push(input);
        Ok(())
    }

    /// The service goes away (and comes back with `restart`).
    pub fn drop_service(&mut self) {
        self.session.clear();
        self.held = None;
        if !self.dropped {
            self.dropped = true;
            self.inbox.push(Input::OwnerChanged { was_owned: true });
        }
    }

    pub fn restart_service(&mut self) {
        self.drop_service();
        self.dropped = false;
        self.inbox.push(Input::OwnerChanged { was_owned: false });
    }

    /// The desktop closes HAL-C2's session.
    pub fn close_session(&mut self) -> Result<(), String> {
        if self.session.is_empty() {
            return Err("no shortcut session is open".into());
        }
        let handle = std::mem::take(&mut self.session);
        self.inbox.push(Input::SessionClosed { handle });
        Ok(())
    }

    /// The desktop reports the shortcut is now on `label`.
    pub fn change_shortcut(&mut self, label: &str) -> Result<(), String> {
        if self.session.is_empty() {
            return Err("no shortcut session is open".into());
        }
        self.desktop.label = label.to_owned();
        let shortcuts = self.granted(label).shortcuts;
        self.inbox.push(Input::ShortcutsChanged {
            session: self.session.clone(),
            shortcuts,
        });
        Ok(())
    }

    fn handle(kind: &str, token: &str) -> String {
        format!("{PATH}/{kind}/{SENDER}/{token}")
    }

    fn call(&mut self, call: Call) {
        if self.dropped {
            let input = match call {
                Call::Properties => Some(Input::Properties(None)),
                Call::Version { generation } => Some(Input::Version {
                    generation,
                    version: None,
                    unreachable: true,
                }),
                Call::Screenshot { token, .. }
                | Call::CreateSession { token, .. }
                | Call::BindShortcuts { token, .. } => Some(Input::Replied {
                    token,
                    handle: Err("The name is not activatable".into()),
                }),
                _ => None,
            };
            self.inbox.extend(input);
            return;
        }
        match call {
            Call::Register { .. } | Call::CloseRequest { .. } => {}
            Call::Properties => {
                if self.desktop.hold_screenshot {
                    self.held_screenshot = true;
                } else if self.desktop.screenshot_fails {
                    self.inbox.push(Input::Properties(None));
                } else {
                    let input = self.properties();
                    self.inbox.push(input);
                }
            }
            Call::Version { generation } => self.inbox.push(Input::Version {
                generation,
                version: Some(self.desktop.shortcuts_version),
                unreachable: false,
            }),
            Call::CreateSession {
                token,
                session_token,
            } => {
                self.creates += 1;
                let request = Bus::handle("request", &token);
                self.inbox.push(Input::Replied {
                    token,
                    handle: Ok(request.clone()),
                });
                if self.desktop.session_fails {
                    self.respond(request, 2, Results::default());
                    return;
                }
                self.session = Bus::handle("session", &session_token);
                let results = Results {
                    session_handle: Some(self.session.clone()),
                    ..Results::default()
                };
                self.respond(request, 0, results);
            }
            Call::BindShortcuts {
                token, id, trigger, ..
            } => {
                self.shortcut_id = id;
                self.trigger = trigger.clone();
                self.triggers.push(trigger);
                let request = Bus::handle("request", &token);
                self.inbox.push(Input::Replied {
                    token,
                    handle: Ok(request.clone()),
                });
                match self.desktop.bind {
                    Answer::Grant => {
                        let results = self.granted(&self.label());
                        self.respond(request, 0, results);
                    }
                    Answer::Unassigned => {
                        let results = self.granted("");
                        self.respond(request, 0, results);
                    }
                    Answer::Nothing => self.respond(request, 0, Results::default()),
                    Answer::Refuse => self.respond(request, 1, Results::default()),
                    Answer::Hold => self.held = Some(request),
                }
            }
            Call::Configure { .. } => self.configures += 1,
            Call::CloseSession { handle } => {
                self.closes += 1;
                if handle == self.session {
                    self.session.clear();
                }
            }
            Call::Screenshot { token, .. } => {
                let request = Bus::handle("request", &token);
                self.inbox.push(Input::Replied {
                    token,
                    handle: Ok(request.clone()),
                });
                let results = Results {
                    uri: Some("file:///portal/screenshot.png".into()),
                    ..Results::default()
                };
                self.respond(request, 0, results);
            }
            Call::Load { .. } => {
                let mut image = RgbaImage::new(320, 200);
                for pixel in image.pixels_mut() {
                    *pixel = Rgba([0, 139, 139, 255]);
                }
                self.inbox.push(Input::Loaded(Ok(Captured {
                    image,
                    app_name: "Window".into(),
                    window_title: String::new(),
                    context: Value::Null,
                })));
            }
        }
    }
}

/// The portal backend's wire to [`bus`].
struct FakeWire(Rc<RefCell<Bus>>);

impl Wire for FakeWire {
    fn send(&mut self, call: Call) {
        self.0.borrow_mut().call(call);
    }

    fn arrive(&mut self) -> Vec<Input> {
        std::mem::take(&mut self.0.borrow_mut().inbox)
    }
}

/// The portal backend on [`bus`], for `reset_with`.
pub(crate) fn factory() -> PortalFactory {
    Rc::new(|platform: &Platform| {
        Box::new(portal::Portal::new(
            platform,
            Box::new(FakeWire(bus())),
            "hal-c2",
            None,
        )) as Box<dyn Backend>
    })
}

/// Hands what the portal said to the shell until it has nothing more to say.
pub(crate) fn settle(engine: &Engine) {
    for _ in 0..64 {
        if bus().borrow().inbox.is_empty() {
            return;
        }
        deliver(engine);
    }
}
