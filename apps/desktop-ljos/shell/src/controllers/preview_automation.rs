//! `previewAutomation`, desktop-qt's PreviewAutomationController: the app's
//! one [`PreviewAutomationHost`], offered to every online MC of the cluster
//! under this machine's client id, driving each browser tab's page
//! ([`BrowserAutomationPage`]). Its `PreviewAutomation` singleton is what
//! the browser brick shows of it: `activity` by tab id, and `reduceMotion`.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use ljos::prelude::{
    Application, Atom, ConnectionId, Cx, Engine, ObjectId, QmlObject, QmlValue, Value, qml_impl,
    qml_singleton,
};
use serde_json::json;

use crate::browser::{self, BrowserPage};
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::client_activity::{focused, now_iso8601};
use crate::controllers::panel::RightPanel;
use crate::controllers::settings::Settings;
use crate::json::Json;
use crate::mc::Mc;
use crate::platform_window;
use crate::preview_automation::{
    AutomationPage, GrabDone, MAX_ENTRIES, PreviewAutomationHost, Reveal, ScriptDone,
    machine_client_id,
};
use crate::store;
use crate::thread_view::previews::ThreadPreviews;

/// What the browser brick shows of the agents' use of its tabs.
#[derive(Debug, Default, QmlObject)]
// Not `uncreatable`: Ljós then cannot make the singleton either.
#[qml(module = "HalC2.Shell", name = "PreviewAutomation")]
#[qml_singleton]
pub struct PreviewAutomationObject {
    /// By tab id: {label, operation, pointer: {x, y}?, actingSince,
    /// userInControl}.
    #[qml(readonly, notify)]
    activity: Value,
    /// No motion in the cue: the system or the Reduce motion setting.
    #[qml(readonly, notify)]
    reduce_motion: bool,
}

#[qml_impl]
impl PreviewAutomationObject {}

pub struct PreviewAutomation {
    mc: Rc<dyn Mc>,
    me: Me<Self>,
    host: Option<PreviewAutomationHost>,
    /// Each page's driver, and the tab it was made for.
    driven: HashMap<ObjectId, (Rc<BrowserAutomationPage>, String)>,
}

impl Controller for PreviewAutomation {
    fn new(init: Init<'_, Self>) -> Self {
        PreviewAutomation {
            mc: init.mc,
            me: init.me,
            host: None,
            driven: HashMap::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        // As in desktop-qt, the host exists wherever the browser can draw
        // pages (the check main.rs makes), so an agent can open one.
        if self.host.is_some() || ljos_webengine::unavailable().is_some() {
            return;
        }
        let home = controller::state_dir(engine)
            .map(|dir| dir.to_string_lossy().into_owned())
            .unwrap_or_default();
        let host = PreviewAutomationHost::new(self.mc.clone(), &machine_client_id(&home));
        host.set_on_activity(publish_activity);
        host.set_on_reveal(reveal);
        self.host = Some(host);
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run_after(engine, |c, engine| c.offer(engine));
        });
        let me = self.me.clone();
        browser::on_pages_changed(engine, move |engine| {
            me.run_after(engine, |c, engine| c.attach_pages(engine));
        });
        if let Ok(app) = engine.singleton::<Application>() {
            let me = self.me.clone();
            let _ = engine.connect_by_name(app, "stateChanged", move |engine, _| {
                me.run_after(engine, |c, engine| c.focus(engine));
            });
        }
        Settings::of(engine).on_settings_changed(publish_motion);
        self.offer(engine);
        self.attach_pages(engine);
        self.focus(engine);
        publish_motion(engine);
    }
}

impl PreviewAutomation {
    fn offer(&mut self, engine: &Engine) {
        let Some(host) = &self.host else { return };
        let mcs: Vec<(String, String)> = store::with(engine, |s| {
            s.environments()
                .into_iter()
                .filter_map(|environment| {
                    let mc = s.mc_serving(&environment);
                    (!mc.is_empty() && s.environment_online(&environment))
                        .then_some((mc, environment))
                })
                .collect()
        });
        host.set_mcs(&mcs);
    }

    fn attach_pages(&mut self, engine: &Engine) {
        let Some(host) = self.host.clone() else {
            return;
        };
        let pages = browser::pages(engine);
        // Gone pages took their drivers with them; a page now showing
        // another tab gets a new one, so the host never mistakes it for the
        // old tab's.
        let stale: Vec<ObjectId> = self
            .driven
            .iter()
            .filter(|(page, (_, tab))| !pages.iter().any(|(t, p)| p == *page && t == tab))
            .map(|(page, _)| *page)
            .collect();
        for page in stale {
            let Some((driver, tab)) = self.driven.remove(&page) else {
                continue;
            };
            driver.release(engine);
            let ours = host
                .attached()
                .iter()
                .any(|(t, p)| *t == tab && same(p, &driver));
            if ours {
                host.detach(engine, &tab);
            }
        }
        for (tab, page) in pages {
            if self.driven.contains_key(&page) {
                continue;
            }
            let Some(previews) = BrowserPage::previews(engine, page) else {
                continue;
            };
            let Some(thread) = ThreadPreviews::read(engine, previews, |p| p.thread().to_owned())
            else {
                continue;
            };
            let driver = BrowserAutomationPage::new(engine, page, &tab, &host);
            self.driven.insert(page, (driver.clone(), tab.clone()));
            host.attach(engine, &thread, &tab, driver);
        }
    }

    fn focus(&mut self, engine: &Engine) {
        if let Some(host) = &self.host {
            host.set_focused(focused(engine));
        }
    }
}

/// The app's host, once the controller made one (a build with the browser).
pub fn host(engine: &Engine) -> Option<PreviewAutomationHost> {
    controller::with::<PreviewAutomation, _>(engine, |c, _| c.host.clone()).flatten()
}

fn same(page: &Rc<dyn AutomationPage>, driver: &Rc<BrowserAutomationPage>) -> bool {
    std::ptr::addr_eq(Rc::as_ptr(page), Rc::as_ptr(driver))
}

/// The host's activity, on the singleton.
fn publish_activity(engine: &Engine, activity: &Json) {
    if let Ok(obj) = engine.singleton::<PreviewAutomationObject>() {
        let _ = Cx::new(engine, obj).set(PreviewAutomationObject::ACTIVITY, activity.to_value());
    }
}

/// Whether the cue keeps still, on the singleton.
fn publish_motion(engine: &Engine) {
    let reduce = platform_window::system_reduced_motion(engine)
        || Settings::of(engine)
            .setting(engine, "reduceMotion")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
    if let Ok(obj) = engine.singleton::<PreviewAutomationObject>() {
        let _ = Cx::new(engine, obj).set(PreviewAutomationObject::REDUCE_MOTION, reduce);
    }
}

/// Shows the tab in the window showing its thread, unless the agent asked
/// to keep it out of sight.
fn reveal(engine: &Engine, reveal: &Reveal) {
    if reveal.show == Some(false) {
        return;
    }
    let shown = Cell::new(false);
    controller::each_window(engine, |engine| {
        if shown.get() {
            return;
        }
        controller::with::<RightPanel, _>(engine, |panel, engine| {
            let Some(previews) = panel.previews() else {
                return;
            };
            let thread = ThreadPreviews::read(engine, previews, |p| {
                (p.environment().to_owned(), p.thread().to_owned())
            });
            if thread != Some((reveal.environment_id.clone(), reveal.thread_id.clone())) {
                return;
            }
            panel.show_tab(engine, &format!("browser:{}", reveal.tab_id));
            shown.set(true);
        });
    });
}

/// What a page logged and the loads of it that failed, and how many loads
/// its view started.
#[derive(Default)]
struct Log {
    console: Vec<Json>,
    failed: Vec<Json>,
    loads: u64,
}

/// A browser page as the host drives it (desktop-qt's BrowserAutomationPage):
/// the page's WebEngineView for what it shows, the page for what it is told.
pub struct BrowserAutomationPage {
    page: ObjectId,
    tab: String,
    log: RefCell<Log>,
    /// The page's own signals, then its current view's.
    connections: RefCell<Vec<ConnectionId>>,
    view_connections: RefCell<Vec<ConnectionId>>,
}

impl BrowserAutomationPage {
    fn new(
        engine: &Engine,
        page: ObjectId,
        tab: &str,
        host: &PreviewAutomationHost,
    ) -> Rc<BrowserAutomationPage> {
        let driver = Rc::new(BrowserAutomationPage {
            page,
            tab: tab.to_owned(),
            log: RefCell::default(),
            connections: RefCell::default(),
            view_connections: RefCell::default(),
        });
        let weak = Rc::downgrade(&driver);
        let mut connections = Vec::new();
        let follow = {
            let (weak, host) = (weak.clone(), host.clone());
            move |engine: &Engine, _: &[Value]| {
                if let Some(driver) = weak.upgrade() {
                    driver.follow(engine, &host);
                }
            }
        };
        connections.extend(engine.connect_by_name(page, "viewChanged", follow).ok());
        let logged = {
            let weak = weak.clone();
            move |engine: &Engine, args: &[Value]| {
                let Some(driver) = weak.upgrade() else { return };
                let arg = |i: usize| args.get(i).map(|v| engine.to_js_string(v));
                let mut entry = json!({
                    "level": arg(0).unwrap_or_default(),
                    "text": arg(1).unwrap_or_default(),
                    "timestamp": now_iso8601(engine),
                });
                if let Some(source) = arg(2).filter(|s| !s.is_empty()) {
                    entry["source"] = json!(source);
                }
                push(&mut driver.log.borrow_mut().console, entry);
            }
        };
        connections.extend(engine.connect_by_name(page, "logged", logged).ok());
        let failed = move |engine: &Engine, args: &[Value]| {
            let Some(driver) = weak.upgrade() else { return };
            let arg = |i: usize| {
                args.get(i)
                    .map(|v| engine.to_js_string(v))
                    .unwrap_or_default()
            };
            let entry = json!({
                "url": arg(0),
                "method": "GET",
                "status": null,
                "failed": true,
                "errorText": arg(1),
                "timestamp": now_iso8601(engine),
            });
            push(&mut driver.log.borrow_mut().failed, entry);
        };
        connections.extend(engine.connect_by_name(page, "loadFailed", failed).ok());
        *driver.connections.borrow_mut() = connections;
        driver.follow(engine, host);
        driver
    }

    /// Follows the page's current view: its loads and its address.
    fn follow(self: &Rc<Self>, engine: &Engine, host: &PreviewAutomationHost) {
        for id in self.view_connections.borrow_mut().drain(..) {
            engine.disconnect(id);
        }
        let Some(view) = BrowserPage::view(engine, self.page) else {
            return;
        };
        let weak: Weak<Self> = Rc::downgrade(self);
        let loading = move |engine: &Engine, _: &[Value]| {
            let Some(driver) = weak.upgrade() else { return };
            if driver.loading(engine) {
                driver.log.borrow_mut().loads += 1;
            }
        };
        let (host, tab) = (host.clone(), self.tab.clone());
        let moved = move |engine: &Engine, _: &[Value]| host.url_changed(engine, &tab);
        let mut connections = self.view_connections.borrow_mut();
        connections.extend(engine.connect_by_name(view, "loadingChanged", loading).ok());
        connections.extend(engine.connect_by_name(view, "urlChanged", moved).ok());
    }

    /// Lets go of the page's signals.
    fn release(&self, engine: &Engine) {
        for id in self.connections.borrow_mut().drain(..) {
            engine.disconnect(id);
        }
        for id in self.view_connections.borrow_mut().drain(..) {
            engine.disconnect(id);
        }
    }

    fn view(&self, engine: &Engine) -> Option<ObjectId> {
        BrowserPage::view(engine, self.page).filter(|v| engine.is_alive(*v))
    }

    fn view_read(&self, engine: &Engine, name: &str) -> Value {
        self.view(engine)
            .map_or(Value::Undefined, |view| engine.read_by_name(view, name))
    }

    fn view_number(&self, engine: &Engine, name: &str) -> f64 {
        match self.view_read(engine, name) {
            Value::Int(n) => f64::from(n),
            Value::Real(n) => n,
            _ => 0.0,
        }
    }

    fn evaluate(&self, engine: &Engine, script: &str, world: i32, done: ScriptDone) {
        if self.view(engine).is_none() {
            return done(engine, None);
        }
        BrowserPage::evaluate(engine, self.page, script, world, move |engine, value| {
            let answer = match value {
                Value::String(s) => Some(s.to_string()),
                _ => None,
            };
            done(engine, answer);
        });
    }
}

fn push(entries: &mut Vec<Json>, entry: Json) {
    entries.push(entry);
    let over = entries.len().saturating_sub(MAX_ENTRIES);
    entries.drain(..over);
}

impl AutomationPage for BrowserAutomationPage {
    fn run_script(&self, engine: &Engine, script: &str, done: ScriptDone) {
        self.evaluate(engine, script, 0, done);
    }

    fn run_isolated(&self, engine: &Engine, script: &str, done: ScriptDone) {
        self.evaluate(engine, script, 1, done);
    }

    fn url(&self, engine: &Engine) -> String {
        match self.view_read(engine, "url") {
            Value::Undefined | Value::Null => String::new(),
            url => engine.to_js_string(&url).to_string(),
        }
    }

    fn title(&self, engine: &Engine) -> String {
        match self.view_read(engine, "title") {
            Value::Undefined | Value::Null => String::new(),
            title => engine.to_js_string(&title).to_string(),
        }
    }

    fn loading(&self, engine: &Engine) -> bool {
        matches!(self.view_read(engine, "loading"), Value::Bool(true))
    }

    fn load(&self, engine: &Engine, url: &str) {
        // The view reports the load to the MC as the user's would be.
        if let Some(view) = self.view(engine) {
            let _ = engine.write_by_name(view, "url", Value::String(Atom::new(url)));
        }
    }

    fn dev_tools_open(&self, engine: &Engine) -> bool {
        BrowserPage::dev_tools(engine, self.page)
    }

    fn on_screen(&self, engine: &Engine) -> bool {
        matches!(self.view_read(engine, "visible"), Value::Bool(true))
            && self.view_number(engine, "width") > 0.0
            && self.view_number(engine, "height") > 0.0
    }

    fn viewport(&self, engine: &Engine) -> (i32, i32) {
        if self.view(engine).is_none() {
            return (0, 0);
        }
        let zoom = BrowserPage::zoom(engine, self.page);
        (
            (self.view_number(engine, "width") / zoom).round() as i32,
            (self.view_number(engine, "height") / zoom).round() as i32,
        )
    }

    fn grab(&self, engine: &Engine, done: GrabDone) {
        if self.view(engine).is_none() {
            return done(engine, None);
        }
        BrowserPage::grab_png(engine, self.page, done);
    }

    fn console_entries(&self, _engine: &Engine) -> Vec<Json> {
        self.log.borrow().console.clone()
    }

    fn failed_loads(&self, _engine: &Engine) -> Vec<Json> {
        self.log.borrow().failed.clone()
    }

    fn loads_started(&self, _engine: &Engine) -> u64 {
        self.log.borrow().loads
    }

    fn resizing(&self, engine: &Engine) -> bool {
        BrowserPage::read(engine, self.page, |core| core.resizing()).unwrap_or(false)
    }

    fn set_viewport(&self, engine: &Engine, size: Option<(i32, i32)>) {
        let viewport = match size {
            None => json!({"_tag": "fill"}),
            Some((width, height)) => json!({"_tag": "freeform", "width": width, "height": height}),
        };
        BrowserPage::update(engine, self.page, |core| core.set_viewport(viewport));
    }

    fn set_color_scheme(&self, engine: &Engine, scheme: &str) {
        let _ = engine.write_by_name(self.page, "appearance", Value::String(Atom::new(scheme)));
    }
}
