//! The in-app browser: desktop-qt's Browser, BrowserPage and
//! PagePermissions, with Ljós's web engine drawing the pages.
//!
//! `Browser` (the QML singleton) holds what this device remembers of how
//! DevTools dock and the Devices view look, the pages' permissions, and a
//! registry of the pages by MC tab id ([`page`]), for what drives pages
//! from Rust (preview automation, the keybindings). A `BrowserPage` is the
//! Rust half of one browser tab (BrowserPanel): [`page::PageCore`] is its
//! logic, and this runs what it asks for on the tab's ThreadPreviews.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use ljos::prelude::{
    Atom, ConnectionId, Cx, Engine, EngineError, ObjectId, QmlObject, QmlValue, TimerId, Value,
    Version, qml_impl,
};
use serde_json::json;

use crate::controllers::settings::Settings;
use crate::json::{self, Json};
use crate::thread_view::previews::{ThreadPreviews, Unheard};

pub mod page;
pub mod permissions;

use page::{PageCore, PageEffect, PageNote};

const MODULE: &str = "HalC2.Shell";
/// How long the MC has to answer a size.
const RESIZE_TIMEOUT: Duration = Duration::from_millis(5000);

const DOCK_KEY: &str = "browserDevToolsDock";
const SHARE_KEY: &str = "browserDevToolsShare";
const DEVICES_VIEW_KEY: &str = "browserDevicesView";
const PRESETS_KEY: &str = "browserDevicesPresetIds";
const DEVICES_3D_KEY: &str = "browserDevices3d";

fn default_presets() -> Vec<String> {
    ["iphone-12-pro", "ipad-air", "desktop"]
        .map(str::to_owned)
        .to_vec()
}

fn warn(engine: &Engine, result: Result<(), EngineError>) {
    if let Err(e) = result {
        engine.log(ljos::prelude::LogLevel::Warning, "Browser", e.to_string());
    }
}

static SUPPORTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Whether this run draws pages in the panel's browser tabs: the app says so
/// once its web engine can run (main.rs), and a test once it embeds.
/// Without it a thread's pages are the Previews tab's, opened in the
/// system browser.
pub fn set_supported(supported: bool) {
    SUPPORTED.store(supported, std::sync::atomic::Ordering::Relaxed);
}

pub fn supported() -> bool {
    SUPPORTED.load(std::sync::atomic::Ordering::Relaxed)
}

/// Registers the browser's types and Ljós's web engine (`QtWebEngine`).
pub fn register(engine: &Engine) {
    ljos_webengine::register(engine);
    engine
        .register_module(ljos::module!("HalC2.Shell" 1.0 => [BrowserPage, PagePermissionsObject]));
    engine.register_singleton::<BrowserObject>(MODULE, Version::new(1, 0));
    // A page gone leaves the registry.
    engine.on_destroyed(|engine, gone| {
        let pages = Pages::of(engine);
        let before = pages.0.borrow().len();
        pages.0.borrow_mut().retain(|_, page| !gone.contains(page));
        if pages.0.borrow().len() != before {
            pages_changed(engine);
        }
    });
}

/// Reads what this device remembers once its preferences are read, and
/// again whenever they change (another window).
pub fn start(engine: &Engine) {
    load(engine);
    Settings::of(engine).on_device_changed(load);
}

// --- Browser --------------------------------------------------------------------

/// The `Browser` singleton.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Browser", uncreatable)]
#[ljos::prelude::qml_singleton]
pub struct BrowserObject {
    /// The profile pages share: none, so they use the engine's default.
    #[qml(constant, readonly)]
    profile: Value,
    /// "bottom" or "right".
    #[qml(notify, write = Self::keep_dock)]
    dev_tools_dock: Atom,
    /// The share of the page DevTools take (0.2–0.8).
    #[qml(notify, write = Self::keep_share)]
    dev_tools_share: f64,
    /// Whether a browser tab opens on its Devices view, which presets it
    /// shows there (js/browser.js's preset ids, plus "desktop"), and whether
    /// on their 3D bodies.
    #[qml(notify, write = Self::keep_devices_view)]
    devices_view: bool,
    #[qml(notify, write = Self::keep_presets)]
    devices_preset_ids: Vec<String>,
    #[qml(notify, write = Self::keep_devices_3d)]
    devices3d: bool,
    /// What pages may ask for, and the question the user is being asked.
    #[qml(readonly, notify)]
    permissions: Value,
}

impl Default for BrowserObject {
    fn default() -> Self {
        BrowserObject {
            profile: Value::Null,
            dev_tools_dock: Atom::new("bottom"),
            dev_tools_share: 0.4,
            devices_view: false,
            devices_preset_ids: default_presets(),
            devices3d: false,
            permissions: Value::Null,
        }
    }
}

/// What `key` reads as on this device: its value made what the property
/// holds, or the default when the device has none.
fn loaded(settings: &Settings, key: &str) -> Json {
    let read = settings.device_value(key);
    match key {
        DOCK_KEY => json!(match read.as_ref().and_then(Json::as_str) {
            Some("right") => "right",
            _ => "bottom",
        }),
        SHARE_KEY => json!(
            read.as_ref()
                .and_then(Json::as_f64)
                .map_or(0.4, |share| share.clamp(0.2, 0.8))
        ),
        PRESETS_KEY => json!(read.as_ref().and_then(Json::as_array).map_or_else(
            default_presets,
            |ids| {
                ids.iter()
                    .filter_map(Json::as_str)
                    .map(str::to_owned)
                    .collect()
            }
        )),
        _ => json!(read.as_ref().and_then(Json::as_bool).unwrap_or(false)),
    }
}

/// Writes `value` under `key` once the write is done, unless it is what the
/// device reads as: what `load` set comes back here, and a write that fails
/// tells the device changed, which loads again.
fn keep(cx: &Cx, key: &'static str, value: Json) {
    cx.engine.call_at(cx.engine.now(), move |engine| {
        let settings = Settings::of(engine);
        if loaded(&settings, key) != value {
            settings.write_device(engine, key, value);
        }
    });
}

impl BrowserObject {
    fn keep_dock(cx: &Cx, dock: Atom) -> Option<Atom> {
        let dock = if dock.as_str() == "right" {
            dock
        } else {
            Atom::new("bottom")
        };
        keep(cx, DOCK_KEY, json!(dock.as_str()));
        Some(dock)
    }

    fn keep_share(cx: &Cx, share: f64) -> Option<f64> {
        let share = if share.is_finite() {
            share.clamp(0.2, 0.8)
        } else {
            0.4
        };
        keep(cx, SHARE_KEY, json!(share));
        Some(share)
    }

    fn keep_devices_view(cx: &Cx, shown: bool) -> Option<bool> {
        keep(cx, DEVICES_VIEW_KEY, json!(shown));
        Some(shown)
    }

    fn keep_presets(cx: &Cx, ids: Vec<String>) -> Option<Vec<String>> {
        keep(cx, PRESETS_KEY, json!(ids));
        Some(ids)
    }

    fn keep_devices_3d(cx: &Cx, shown: bool) -> Option<bool> {
        keep(cx, DEVICES_3D_KEY, json!(shown));
        Some(shown)
    }
}

#[qml_impl]
impl BrowserObject {
    /// A page came or went.
    #[qml(signal)]
    fn pages_changed();
}

fn browser(engine: &Engine) -> Option<ObjectId> {
    let browser = engine.singleton::<BrowserObject>().ok()?;
    // Its permissions are made with it, the first time it is asked for.
    let made = engine
        .with::<BrowserObject, _>(browser, |b| matches!(b.permissions, Value::Object(_)))
        .unwrap_or(true);
    if !made {
        let permissions = engine.create_native(
            PagePermissionsObject {
                question: question_json(None).to_value(),
                inner: Rc::default(),
            },
            Some(browser),
        );
        match permissions {
            Ok(permissions) => warn(
                engine,
                engine.set_internal(
                    browser,
                    BrowserObject::PERMISSIONS,
                    Value::Object(permissions),
                ),
            ),
            Err(e) => warn(engine, Err(e)),
        }
        tell_question(engine);
    }
    Some(browser)
}

/// The browser's PagePermissions.
pub fn permissions(engine: &Engine) -> Option<ObjectId> {
    let browser = browser(engine)?;
    match engine
        .with::<BrowserObject, _>(browser, |b| b.permissions.clone())
        .ok()?
    {
        Value::Object(permissions) => Some(permissions),
        _ => None,
    }
}

fn load(engine: &Engine) {
    let Some(browser) = browser(engine) else {
        return;
    };
    let settings = Settings::of(engine);
    let read = |key| loaded(&settings, key);
    let dock = read(DOCK_KEY);
    let presets: Vec<String> = read(PRESETS_KEY)
        .as_array()
        .map(|ids| {
            ids.iter()
                .filter_map(Json::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let flag = |key| read(key).as_bool().unwrap_or(false);
    let mut result = engine.set_internal(
        browser,
        BrowserObject::DEV_TOOLS_DOCK,
        Atom::new(dock.as_str().unwrap_or("bottom")),
    );
    result = result.and_then(|()| {
        engine.set_internal(
            browser,
            BrowserObject::DEV_TOOLS_SHARE,
            read(SHARE_KEY).as_f64().unwrap_or(0.4),
        )
    });
    result = result.and_then(|()| {
        engine.set_internal(browser, BrowserObject::DEVICES_VIEW, flag(DEVICES_VIEW_KEY))
    });
    result = result
        .and_then(|()| engine.set_internal(browser, BrowserObject::DEVICES_PRESET_IDS, presets));
    result = result.and_then(|()| {
        engine.set_internal(browser, BrowserObject::DEVICES3D, flag(DEVICES_3D_KEY))
    });
    warn(engine, result);
}

/// The pages by MC tab id.
#[derive(Default)]
struct Pages(RefCell<HashMap<String, ObjectId>>);

impl Pages {
    fn of(engine: &Engine) -> Rc<Pages> {
        engine.extension::<Pages>()
    }
}

/// What runs whenever a page comes, goes or shows another tab.
type PagesListener = Rc<dyn Fn(&Engine)>;

#[derive(Default)]
struct PagesListeners(RefCell<Vec<PagesListener>>);

/// Runs `f` whenever a page comes, goes or shows another tab.
pub fn on_pages_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    engine
        .extension::<PagesListeners>()
        .0
        .borrow_mut()
        .push(Rc::new(f));
}

fn pages_changed(engine: &Engine) {
    let listeners = engine.extension::<PagesListeners>().0.borrow().clone();
    for f in listeners {
        f(engine);
    }
    if let Some(browser) = browser(engine) {
        warn(
            engine,
            BrowserObject::emit_pages_changed(&Cx::new(engine, browser)),
        );
    }
}

/// The page showing MC tab `tab`, while one does.
pub fn page(engine: &Engine, tab: &str) -> Option<ObjectId> {
    let page = *Pages::of(engine).0.borrow().get(tab)?;
    engine.is_alive(page).then_some(page)
}

/// The pages, by tab id.
pub fn pages(engine: &Engine) -> Vec<(String, ObjectId)> {
    let pages = Pages::of(engine);
    let pages = pages.0.borrow();
    let mut list: Vec<_> = pages
        .iter()
        .filter(|(_, page)| engine.is_alive(**page))
        .map(|(tab, page)| (tab.clone(), *page))
        .collect();
    list.sort();
    list
}

// --- PagePermissions -----------------------------------------------------------

/// `Browser.permissions`: [`permissions::PagePermissions`] for QML.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "PagePermissions", uncreatable)]
pub struct PagePermissionsObject {
    /// The question on screen, `{id, tabId, kind, origin, url}`, or `{}`
    /// as desktop-qt's empty map, so a brick may read its fields.
    #[qml(readonly, notify)]
    question: Value,
    #[qml(skip)]
    inner: Rc<RefCell<permissions::PagePermissions>>,
}

/// Runs `f` on the permissions, then shows the question on screen.
pub fn update_permissions<R>(
    engine: &Engine,
    f: impl FnOnce(&mut permissions::PagePermissions) -> R,
) -> Option<R> {
    let obj = permissions(engine)?;
    let inner = engine
        .with::<PagePermissionsObject, _>(obj, |p| p.inner.clone())
        .ok()?;
    let (result, changed) = {
        let mut inner = inner.borrow_mut();
        let result = f(&mut inner);
        (result, inner.take_changed())
    };
    if changed {
        tell_question(engine);
    }
    Some(result)
}

fn tell_question(engine: &Engine) {
    let Some(obj) = permissions(engine) else {
        return;
    };
    let Ok(question) =
        engine.with::<PagePermissionsObject, _>(obj, |p| p.inner.borrow().question().cloned())
    else {
        return;
    };
    let value = question_json(question).to_value();
    warn(
        engine,
        engine.set_internal(obj, PagePermissionsObject::QUESTION, value),
    );
}

fn question_json(question: Option<permissions::Question>) -> Json {
    question.map_or_else(|| json!({}), |q| q.to_json())
}

#[qml_impl]
impl PagePermissionsObject {
    /// A page of tab `tabId` at `origin` asks for `kind`: `{answer: "grant"
    /// | "deny" | "ask", id}`, `id` naming the question while it is asked.
    #[qml(invokable)]
    fn request(cx: &Cx, tab_id: Atom, origin: Atom, kind: Atom) -> Json {
        let answer = update_permissions(cx.engine, |p| p.request(&tab_id, &origin, &kind));
        match answer {
            Some(permissions::Answer::Grant) => json!({"answer": "grant", "id": 0}),
            Some(permissions::Answer::Ask(id)) => json!({"answer": "ask", "id": id}),
            _ => json!({"answer": "deny", "id": 0}),
        }
    }

    /// A page of tab `tabId` goes to `url`: 0 when the engine shows it,
    /// else the question asking to hand it to another app (refused: -1).
    #[qml(invokable)]
    fn open_link(cx: &Cx, tab_id: Atom, url: Atom) -> f64 {
        update_permissions(cx.engine, |p| p.open_link(&tab_id, &url)).unwrap_or(-1) as f64
    }

    /// The user answered question `id`: the question it was, `{}` when none.
    #[qml(invokable)]
    fn answer(cx: &Cx, id: f64, allow: bool) -> Json {
        question_json(update_permissions(cx.engine, |p| p.answer(id as i64, allow)).flatten())
    }

    #[qml(invokable)]
    fn set_shown(cx: &Cx, tab_id: Atom, shown: bool) {
        update_permissions(cx.engine, |p| p.set_shown(&tab_id, shown));
    }

    #[qml(invokable)]
    fn forget(cx: &Cx, tab_id: Atom) {
        update_permissions(cx.engine, |p| p.forget(&tab_id));
    }
}

// --- BrowserPage ---------------------------------------------------------------

type Evaluated = Box<dyn FnOnce(&Engine, Value)>;

#[derive(Default)]
struct PageInner {
    core: RefCell<PageCore>,
    /// The previews followed, and the connections to their signals.
    previews: Cell<Option<ObjectId>>,
    connections: RefCell<Vec<ConnectionId>>,
    timers: RefCell<HashMap<(String, u64), TimerId>>,
    enrolled: RefCell<String>,
    requests: Cell<i32>,
    evaluations: RefCell<HashMap<i32, Evaluated>>,
    grabs: RefCell<HashMap<i32, Evaluated>>,
}

impl std::fmt::Debug for PageInner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PageInner").finish_non_exhaustive()
    }
}

/// One browser tab's page, made by its brick (BrowserPanel) beside the
/// WebEngineView that draws it: see [`page`]. Zoom, appearance, mute and
/// DevTools are the page's own, not the MC's.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "BrowserPage")]
pub struct BrowserPage {
    /// The thread's ThreadPreviews.
    #[qml(notify, write = Self::keep_previews)]
    previews: Value,
    /// The MC's tab id.
    #[qml(notify, write = Self::keep_tab_id)]
    tab_id: Atom,
    /// The MC's address, title and status (idle, loading, loaded, failed)
    /// for the tab.
    #[qml(readonly, notify)]
    url: Atom,
    #[qml(readonly, notify)]
    title: Atom,
    #[qml(readonly, notify)]
    status: Atom,
    #[qml(readonly, notify)]
    exists: bool,
    /// {_tag: "fill"} or {_tag: "preset"|"freeform", width, height,
    /// presetId?}.
    #[qml(readonly, notify)]
    viewport: Value,
    /// A size was picked and the MC has not answered it yet.
    #[qml(readonly, notify)]
    resizing: bool,
    #[qml(notify, write = Self::keep_zoom)]
    zoom: f64,
    /// system, light or dark: the page's prefers-color-scheme.
    #[qml(notify, write = Self::keep_appearance)]
    appearance: Atom,
    #[qml(notify)]
    muted: bool,
    #[qml(notify)]
    dev_tools: bool,
    /// The WebEngineView showing the page, set by the brick.
    #[qml(notify)]
    view: Value,
    #[qml(skip)]
    inner: Rc<PageInner>,
}

impl Default for BrowserPage {
    fn default() -> Self {
        BrowserPage {
            previews: Value::Null,
            tab_id: Atom::new(""),
            url: Atom::new(""),
            title: Atom::new(""),
            status: Atom::new("idle"),
            exists: false,
            viewport: json!({"_tag": "fill"}).to_value(),
            resizing: false,
            zoom: 1.0,
            appearance: Atom::new("system"),
            muted: false,
            dev_tools: false,
            view: Value::Null,
            inner: Rc::default(),
        }
    }
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<PageInner>> {
    engine.with::<BrowserPage, _>(obj, |p| p.inner.clone()).ok()
}

fn snapshot(engine: &Engine, inner: &PageInner) -> Json {
    let tab = inner.core.borrow().tab_id().to_owned();
    match inner.previews.get() {
        Some(previews) if !tab.is_empty() => {
            ThreadPreviews::read(engine, previews, |p| p.tab(&tab)).unwrap_or(Json::Null)
        }
        _ => Json::Null,
    }
}

impl BrowserPage {
    fn keep_previews(cx: &Cx, previews: Value) -> Option<Value> {
        let obj = cx.this;
        let to = match &previews {
            Value::Object(previews) => Some(*previews),
            _ => None,
        };
        cx.engine.call_at(cx.engine.now(), move |engine| {
            BrowserPage::set_previews(engine, obj, to);
        });
        Some(previews)
    }

    fn keep_tab_id(cx: &Cx, tab: Atom) -> Option<Atom> {
        let obj = cx.this;
        let to = tab.as_str().to_owned();
        cx.engine.call_at(cx.engine.now(), move |engine| {
            BrowserPage::set_tab(engine, obj, &to);
        });
        Some(tab)
    }

    fn keep_zoom(_cx: &Cx, zoom: f64) -> Option<f64> {
        Some(if zoom.is_finite() {
            zoom.clamp(0.25, 5.0)
        } else {
            1.0
        })
    }

    fn keep_appearance(_cx: &Cx, appearance: Atom) -> Option<Atom> {
        Some(match appearance.as_str() {
            "light" | "dark" => appearance,
            _ => Atom::new("system"),
        })
    }

    /// Follows `previews` (None: none).
    pub fn set_previews(engine: &Engine, obj: ObjectId, previews: Option<ObjectId>) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        if inner.previews.get() == previews {
            return;
        }
        for id in inner.connections.borrow_mut().drain(..) {
            engine.disconnect(id);
        }
        inner.previews.set(previews);
        if let Some(previews) = previews {
            let mut connections = Vec::new();
            let changed = engine
                .signal_index(previews, "tabChanged")
                .and_then(|signal| {
                    engine.connect_to(previews, signal, obj, move |engine, args| {
                        let tab = args.first().map(|v| json::from_value(engine, v));
                        let Some(inner) = inner_of(engine, obj) else {
                            return;
                        };
                        let mine = inner.core.borrow().tab_id().to_owned();
                        if tab.as_ref().and_then(Json::as_str) == Some(mine.as_str()) {
                            BrowserPage::refresh(engine, obj);
                        }
                    })
                });
            let listed = engine.signal_index(previews, "listed").and_then(|signal| {
                engine.connect_to(previews, signal, obj, move |engine, _| {
                    BrowserPage::update(engine, obj, PageCore::listed);
                })
            });
            for made in [changed, listed] {
                match made {
                    Ok(id) => connections.push(id),
                    Err(e) => warn(engine, Err(e)),
                }
            }
            *inner.connections.borrow_mut() = connections;
        }
        let tab = snapshot(engine, &inner);
        BrowserPage::update(engine, obj, |core| core.follow(tab));
        // A page's previews say whose thread its tab is.
        if !inner.enrolled.borrow().is_empty() {
            pages_changed(engine);
        }
    }

    /// Shows MC tab `tab`.
    pub fn set_tab(engine: &Engine, obj: ObjectId, tab: &str) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        if inner.core.borrow().tab_id() == tab {
            return;
        }
        // Registered under its tab id while it shows it.
        let was = std::mem::replace(&mut *inner.enrolled.borrow_mut(), tab.to_owned());
        {
            let pages = Pages::of(engine);
            let mut pages = pages.0.borrow_mut();
            if !was.is_empty() && pages.get(&was) == Some(&obj) {
                pages.remove(&was);
            }
            if !tab.is_empty() {
                pages.insert(tab.to_owned(), obj);
            }
        }
        let snapshot = match inner.previews.get() {
            Some(previews) if !tab.is_empty() => {
                ThreadPreviews::read(engine, previews, |p| p.tab(tab)).unwrap_or(Json::Null)
            }
            _ => Json::Null,
        };
        BrowserPage::update(engine, obj, |core| core.set_tab(tab, snapshot));
        pages_changed(engine);
    }

    fn refresh(engine: &Engine, obj: ObjectId) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let tab = inner.core.borrow().tab_id().to_owned();
        let Some(previews) = inner.previews.get() else {
            return;
        };
        let (snapshot, event) = ThreadPreviews::read(engine, previews, |p| {
            (p.tab(&tab), p.last_event(&tab).to_owned())
        })
        .unwrap_or((Json::Null, String::new()));
        BrowserPage::update(engine, obj, |core| core.refresh(snapshot, &event));
    }

    /// Runs `f` on the page's core, then tells QML what changed and does
    /// what it asked. None when `obj` is not a live page.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut PageCore) -> R,
    ) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let (result, notes, effects) = {
            let mut core = inner.core.borrow_mut();
            let result = f(&mut core);
            (result, core.take_notes(), core.take_effects())
        };
        tell(engine, obj, &inner, &notes);
        for effect in effects {
            run(engine, obj, &inner, effect);
        }
        Some(result)
    }

    /// Reads the page's core.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&PageCore) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let core = inner.core.borrow();
        Some(f(&core))
    }

    /// Runs `script` in the page (`world` 0 the page's own, 1 the
    /// application's); `done` gets its result, undefined when there was
    /// none. Answered by the brick (`evaluated`); dropped with the page.
    pub fn evaluate(
        engine: &Engine,
        obj: ObjectId,
        script: &str,
        world: i32,
        done: impl FnOnce(&Engine, Value) + 'static,
    ) {
        let Some(inner) = inner_of(engine, obj) else {
            return done(engine, Value::Undefined);
        };
        let request = next_request(&inner);
        inner
            .evaluations
            .borrow_mut()
            .insert(request, Box::new(done));
        warn(
            engine,
            BrowserPage::emit_evaluate_requested(
                &Cx::new(engine, obj),
                request,
                Atom::new(script),
                world,
            ),
        );
    }

    /// The page's picture as the view draws it, answered by the brick
    /// (`grabbed`): undefined when it could not take one.
    pub fn grab(engine: &Engine, obj: ObjectId, done: impl FnOnce(&Engine, Value) + 'static) {
        let Some(inner) = inner_of(engine, obj) else {
            return done(engine, Value::Undefined);
        };
        let request = next_request(&inner);
        inner.grabs.borrow_mut().insert(request, Box::new(done));
        warn(
            engine,
            BrowserPage::emit_grab_requested(&Cx::new(engine, obj), request),
        );
    }

    /// The page's picture as a PNG, {mimeType: "image/png", data (base64),
    /// width, height}: None when the view could not take one.
    pub fn grab_png(
        engine: &Engine,
        obj: ObjectId,
        done: impl FnOnce(&Engine, Option<Json>) + 'static,
    ) {
        Self::grab(engine, obj, move |engine, image| {
            let png =
                ljos::item::grabbed_image(engine, &image).and_then(|picture| png_of(&picture));
            done(engine, png);
        });
    }

    /// A keybinding for the showing page: preview.refresh, preview.focusUrl,
    /// preview.zoomIn, preview.zoomOut or preview.resetZoom.
    pub fn command(engine: &Engine, obj: ObjectId, command: &str) {
        warn(
            engine,
            BrowserPage::emit_command_requested(&Cx::new(engine, obj), Atom::new(command)),
        );
    }

    /// The WebEngineView showing the page.
    pub fn view(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        match engine
            .with::<BrowserPage, _>(obj, |p| p.view.clone())
            .ok()?
        {
            Value::Object(view) => Some(view),
            _ => None,
        }
    }

    /// The ThreadPreviews the page follows.
    pub fn previews(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        inner_of(engine, obj)?
            .previews
            .get()
            .filter(|p| engine.is_alive(*p))
    }

    /// How far the page is zoomed in, 1 at none.
    pub fn zoom(engine: &Engine, obj: ObjectId) -> f64 {
        engine
            .with::<BrowserPage, _>(obj, |p| p.zoom)
            .ok()
            .filter(|z| *z > 0.0)
            .unwrap_or(1.0)
    }

    /// Whether the page has DevTools open.
    pub fn dev_tools(engine: &Engine, obj: ObjectId) -> bool {
        engine
            .with::<BrowserPage, _>(obj, |p| p.dev_tools)
            .unwrap_or(false)
    }
}

fn next_request(inner: &PageInner) -> i32 {
    let request = inner.requests.get().wrapping_add(1).max(1);
    inner.requests.set(request);
    request
}

/// Whether the page's view is there and has not loaded anything.
fn view_is_empty(engine: &Engine, obj: ObjectId) -> bool {
    BrowserPage::view(engine, obj).is_some_and(|view| match engine.read_by_name(view, "url") {
        Value::Undefined | Value::Null => true,
        url => engine.to_js_string(&url).is_empty(),
    })
}

fn tell(engine: &Engine, obj: ObjectId, inner: &PageInner, notes: &[PageNote]) {
    let cx = Cx::new(engine, obj);
    for note in notes {
        let result = match note {
            PageNote::Tab => {
                let (url, title, status, exists) = {
                    let core = inner.core.borrow();
                    (
                        Atom::new(core.url()),
                        Atom::new(core.title()),
                        Atom::new(core.status()),
                        core.exists(),
                    )
                };
                let empty = !url.as_str().is_empty() && view_is_empty(engine, obj);
                let at = url.clone();
                engine
                    .set_internal(obj, BrowserPage::URL, url)
                    .and_then(|()| engine.set_internal(obj, BrowserPage::TITLE, title))
                    .and_then(|()| engine.set_internal(obj, BrowserPage::STATUS, status))
                    .and_then(|()| engine.set_internal(obj, BrowserPage::EXISTS, exists))
                    // The brick loads where the tab is when tabIdChanged
                    // fires, but the page hears of its tab a tick later
                    // (keep_tab_id, keep_previews), and TODO(ljos#438) of
                    // its view once the brick is made: a view that has
                    // shown nothing yet loads it now.
                    .and_then(|()| {
                        if empty {
                            BrowserPage::emit_load_requested(&cx, at)
                        } else {
                            Ok(())
                        }
                    })
            }
            PageNote::Viewport => {
                let viewport = inner.core.borrow().viewport().to_value();
                engine.set_internal(obj, BrowserPage::VIEWPORT, viewport)
            }
            PageNote::Resizing => {
                let resizing = inner.core.borrow().resizing();
                engine.set_internal(obj, BrowserPage::RESIZING, resizing)
            }
            PageNote::LoadRequested(url) => BrowserPage::emit_load_requested(&cx, Atom::new(url)),
            PageNote::LoadFailed { url, description } => {
                BrowserPage::emit_load_failed(&cx, Atom::new(url), Atom::new(description))
            }
        };
        warn(engine, result);
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &PageInner, effect: PageEffect) {
    let Some(previews) = inner.previews.get() else {
        // No previews to tell: nothing is on its way.
        if let PageEffect::Report { owner, .. } = effect {
            inner.core.borrow_mut().unreported(owner);
        }
        return;
    };
    match effect {
        PageEffect::Report {
            tab,
            nav,
            back,
            forward,
            owner,
        } => {
            let heard_tab = tab.clone();
            let called = ThreadPreviews::report(
                engine,
                previews,
                &tab,
                nav,
                back,
                forward,
                move |engine, why: Unheard| {
                    BrowserPage::update(engine, obj, |core| core.heard(&heard_tab, owner, why));
                },
            );
            if !called {
                BrowserPage::update(engine, obj, |core| core.unreported(owner));
            }
        }
        PageEffect::Navigate { tab, url } => {
            ThreadPreviews::update(engine, previews, |p| p.navigate(&tab, &url));
        }
        PageEffect::Resize {
            tab,
            viewport,
            pick,
        } => {
            let key = (tab.clone(), pick);
            let timer_key = key.clone();
            let timer = engine.call_at(engine.now() + RESIZE_TIMEOUT, move |engine| {
                if let Some(inner) = inner_of(engine, obj) {
                    inner.timers.borrow_mut().remove(&timer_key);
                }
                let (tab, pick) = &timer_key;
                BrowserPage::update(engine, obj, |core| core.timed_out(tab, *pick));
            });
            inner.timers.borrow_mut().insert(key.clone(), timer);
            ThreadPreviews::resize_tab(engine, previews, &tab, viewport, move |engine, error| {
                if let Some(inner) = inner_of(engine, obj)
                    && let Some(timer) = inner.timers.borrow_mut().remove(&key)
                {
                    engine.cancel_call(timer);
                }
                let (tab, pick) = &key;
                BrowserPage::update(engine, obj, |core| {
                    core.resized(tab, *pick, error.as_deref())
                });
            });
        }
    }
}

#[qml_impl]
impl BrowserPage {
    /// The MC's tab went to an address the page did not report: the view
    /// loads it.
    #[qml(signal)]
    fn load_requested(url: Atom);

    /// For the brick: run `script` and answer `evaluated(request, result)`.
    #[qml(signal)]
    fn evaluate_requested(request: i32, script: Atom, world: i32);

    /// For the brick: take the view's picture and answer `grabbed(request,
    /// image)`.
    #[qml(signal)]
    fn grab_requested(request: i32);

    /// A keybinding for the showing page.
    #[qml(signal)]
    fn command_requested(command: Atom);

    /// The page logged `text` (level info, warning or error).
    #[qml(signal)]
    fn logged(level: Atom, text: Atom, source: Atom);

    #[qml(signal)]
    fn load_failed(url: Atom, description: Atom);

    /// What the view did: phase "loading", "loaded" or "failed" (with
    /// Chromium's net error `code` and its `description`).
    #[qml(invokable)]
    #[allow(clippy::too_many_arguments)]
    fn report(
        cx: &Cx,
        phase: Atom,
        url: Atom,
        title: Atom,
        code: f64,
        description: Atom,
        can_go_back: bool,
        can_go_forward: bool,
    ) {
        BrowserPage::update(cx.engine, cx.this, |core| {
            core.report(
                &phase,
                &url,
                &title,
                code as i64,
                &description,
                can_go_back,
                can_go_forward,
            )
        });
    }

    /// The user went to `url` (already a web address): `preview.navigate`.
    #[qml(invokable)]
    fn navigate(cx: &Cx, url: Atom) {
        BrowserPage::update(cx.engine, cx.this, |core| core.navigate(&url));
    }

    /// The device size (BrowserPanel's js/browser.js viewportOf).
    #[qml(invokable)]
    fn set_viewport(cx: &Cx, viewport: Json) {
        let viewport = if viewport.is_object() {
            viewport
        } else {
            json!({})
        };
        BrowserPage::update(cx.engine, cx.this, |core| core.set_viewport(viewport));
    }

    #[qml(invokable)]
    fn evaluated(cx: &Cx, request: f64, result: Value) {
        let Some(inner) = inner_of(cx.engine, cx.this) else {
            return;
        };
        let done = inner.evaluations.borrow_mut().remove(&(request as i32));
        if let Some(done) = done {
            done(cx.engine, result);
        }
    }

    #[qml(invokable)]
    fn grabbed(cx: &Cx, request: f64, image: Value) {
        let Some(inner) = inner_of(cx.engine, cx.this) else {
            return;
        };
        let done = inner.grabs.borrow_mut().remove(&(request as i32));
        if let Some(done) = done {
            done(cx.engine, image);
        }
    }

    /// What the page logged (WebEngineView's javaScriptConsoleMessage).
    #[qml(invokable)]
    fn console_message(cx: &Cx, level: f64, message: Atom, line: f64, source: Atom) {
        let level = match level as i64 {
            i64::MIN..=0 => "info",
            1 => "warning",
            _ => "error",
        };
        let at = if source.is_empty() {
            String::new()
        } else {
            format!("{source}:{}", line as i64)
        };
        warn(
            cx.engine,
            BrowserPage::emit_logged(cx, Atom::new(level), message, Atom::new(&at)),
        );
    }
}

/// A grabbed picture (premultiplied) as a PNG, as `BrowserPage::grab_png`
/// hands it on.
fn png_of(picture: &ljos::item::ImageHandle) -> Option<Json> {
    let (width, height) = (picture.width(), picture.height());
    let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
    for y in 0..height {
        for x in 0..width {
            let [r, g, b, a] = picture.pixel(x, y);
            let straight = |c: u8| {
                if a == 0 {
                    0
                } else {
                    ((u32::from(c) * 255 + u32::from(a) / 2) / u32::from(a)).min(255) as u8
                }
            };
            rgba.extend_from_slice(&[straight(r), straight(g), straight(b), a]);
        }
    }
    let image = image::RgbaImage::from_raw(width, height, rgba)?;
    let mut png = std::io::Cursor::new(Vec::new());
    image.write_to(&mut png, image::ImageFormat::Png).ok()?;
    use base64::Engine as _;
    Some(json!({
        "mimeType": "image/png",
        "data": base64::engine::general_purpose::STANDARD.encode(png.into_inner()),
        "width": width,
        "height": height,
    }))
}
