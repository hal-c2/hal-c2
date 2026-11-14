//! `Spaces` and `space`, desktop-qt's SpaceController: follows the
//! `spaces` index and the selected Space's stream while the Space view
//! (route kind `space`) is open, shows them as the `Spaces` singleton's
//! rows, and makes every change with the MC's `space.*` calls, which the
//! streams then show. A refusal is said in a toast and kept in `error`.
//!
//! Publishes `space`: {error, busy, drawing, written, addingImage,
//! generatingImage, imageProviders, files, picking, projects}. The
//! actions it handles are the `space.*` ones SpaceController.h lists.
//!
//! What the composer reads, at any time: [`prompt_page`],
//! [`prompt_images`], [`image_providers`], [`generating_image`];
//! [`on_prompt_page_changed`], [`on_agent_ask_requested`],
//! [`on_image_offer_changed`] and [`on_changed`] run once the controller
//! is done.

pub mod history;
pub mod markdown;
pub mod projects;
pub mod rows;
pub mod stream;

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, ObjectId, Prop, QmlObject, QmlValue, Value, qml_impl, qml_singleton,
};
use serde_json::{Value as JsonValue, json};

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{Navigation, Route, at_kind};
use crate::controllers::settings::Settings;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::{Frame, Mc, SubId};
use crate::store;
use crate::this_machine;

use history::{History, Next, Request};
use markdown::{list_items, markdown_frame};
use projects::Projects;
use rows::{Row, Rows};
use stream::{Entity, SpaceStream, sorted, text};

/// The `SpaceRows` and `SpaceHistory` types, for what the bricks compile against.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [
        rows::SpaceRows,
        SpaceHistoryObject,
    ]));
}

pub const OPEN: &str = "space.open";
pub const PAGE_FROM_THREAD: &str = "space.pageFromThread";
pub const HISTORY_COMMAND: &str = "space.history.open";
pub const ASK_AGENT: &str = "space.agent.focus";
pub const DECK_FROM_PAGE: &str = "space.deck.fromOpenPage";
pub const PRESENT_DECK: &str = "space.deck.presentOpen";
pub const PICK_FILE: &str = "space.files.pick";
pub const SCAN_FILES: &str = "space.files.scanProject";
const EXPANDED_KEY: &str = "spaceExpandedProjects";
const EXPANDED_FOLDERS_KEY: &str = "spaceExpandedFolders";

const HISTORY_REFRESH_MS: i64 = 1000;
const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024;
const ADDRESS_MARGIN_MS: i64 = 60_000;
const ADDRESS_AT_LEAST_MS: i64 = 5 * 60_000;
const ADDRESS_RETRY_MS: i64 = 30_000;
const REBUILD_SOON_MS: i64 = 50;
const VIEWERS_RETRY_MS: i64 = 1000;

type Listener = Rc<dyn Fn(&Engine)>;
/// Told how the user answered an agent's ask: thread, request, answer, allowed.
type AskAnswered = Rc<dyn Fn(&Engine, &str, &str, bool)>;
/// Told whether the user allowed what was asked.
type Answered = Rc<dyn Fn(&Engine, bool)>;
/// Handed a string once a lookup settles.
type Settled = Rc<dyn Fn(&Engine, String)>;
/// Handed a page's exported text.
type Exported = Rc<dyn Fn(&mut Space, &Engine, String)>;

/// What is read without the controller, and who is told.
#[derive(Default)]
struct Shared {
    prompt_page: RefCell<String>,
    prompt_images: RefCell<String>,
    changed: RefCell<Vec<Listener>>,
    prompt_page_changed: RefCell<Vec<Listener>>,
    agent_ask_requested: RefCell<Vec<Listener>>,
    agent_ask_answered: RefCell<Vec<AskAnswered>>,
    image_offer_changed: RefCell<Vec<Listener>>,
}

/// Told when an `askAgent`'s call lands: (pageId, request, made).
pub fn on_agent_ask_answered(engine: &Engine, f: impl Fn(&Engine, &str, &str, bool) + 'static) {
    shared(engine)
        .agent_ask_answered
        .borrow_mut()
        .push(Rc::new(f));
}

fn tell_answered(engine: &Engine, page: &str, request: &str, made: bool) {
    let (page, request) = (page.to_owned(), request.to_owned());
    for f in shared(engine).agent_ask_answered.borrow().clone() {
        let (page, request) = (page.clone(), request.clone());
        Bridge::of(engine).defer(engine, move |engine| f(engine, &page, &request, made));
    }
}

fn shared(engine: &Engine) -> Rc<Shared> {
    Bridge::of(engine).extension::<Shared>(engine)
}

fn tell(engine: &Engine, listeners: Vec<Listener>) {
    for f in listeners {
        Bridge::of(engine).defer(engine, move |engine| f(engine));
    }
}

/// The page the timeline's prompt writes on: the selected page while it is
/// on show and out of the trash, else empty.
pub fn prompt_page(engine: &Engine) -> String {
    shared(engine).prompt_page.borrow().clone()
}

/// The Space whose images the prompt makes an image for: the open Space
/// while its images are on show, else empty.
pub fn prompt_images(engine: &Engine) -> String {
    shared(engine).prompt_images.borrow().clone()
}

pub fn on_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).changed.borrow_mut().push(Rc::new(f));
}

pub fn on_prompt_page_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine)
        .prompt_page_changed
        .borrow_mut()
        .push(Rc::new(f));
}

pub fn on_agent_ask_requested(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine)
        .agent_ask_requested
        .borrow_mut()
        .push(Rc::new(f));
}

pub fn on_image_offer_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine)
        .image_offer_changed
        .borrow_mut()
        .push(Rc::new(f));
}

fn toast(engine: &Engine, kind: &str, title: &str, description: &str) {
    let (kind, title, description) = (kind.to_owned(), title.to_owned(), description.to_owned());
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.show(
                e,
                &kind,
                &title,
                &description,
                None,
                crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
            );
        });
    });
}

fn toast_action(
    engine: &Engine,
    title: String,
    description: String,
    label: String,
    run: impl Fn(&Engine) + 'static,
) {
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.show(
                e,
                "info",
                &title,
                &description,
                Some(crate::controllers::toasts::Action::new(label, run)),
                crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
            );
        });
    });
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

fn by_agent(author: Option<&JsonValue>) -> bool {
    author
        .and_then(JsonValue::as_object)
        .is_some_and(|a| a.get("type").and_then(JsonValue::as_str) == Some("agent"))
}

fn trashed(entity: &Entity) -> bool {
    !text(entity, "trashedAt").is_empty()
}

fn str_of(value: &Json, field: &str) -> String {
    value
        .get(field)
        .and_then(Json::as_str)
        .unwrap_or("")
        .to_owned()
}

fn obj(value: &Json, field: &str) -> Entity {
    value
        .get(field)
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default()
}

/// `Spaces` in QML: what the Space bricks bind.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Spaces", uncreatable)]
#[qml_singleton]
pub struct SpacesObject {
    #[qml(constant, readonly)]
    spaces: Value,
    #[qml(constant, readonly)]
    pages: Value,
    #[qml(constant, readonly)]
    trash: Value,
    #[qml(constant, readonly)]
    blocks: Value,
    #[qml(constant, readonly)]
    comments: Value,
    #[qml(constant, readonly)]
    history: Value,
    #[qml(constant, readonly)]
    decks: Value,
    #[qml(constant, readonly)]
    deck_trash: Value,
    #[qml(constant, readonly)]
    slides: Value,
    #[qml(constant, readonly)]
    images: Value,
    #[qml(constant, readonly)]
    image_trash: Value,
    #[qml(constant, readonly)]
    projects: Value,
    #[qml(notify, readonly)]
    space_id: Atom,
    #[qml(notify, readonly)]
    space_name: Atom,
    #[qml(notify, readonly)]
    page_id: Atom,
    #[qml(notify, readonly)]
    file_space_id: Atom,
    #[qml(notify, readonly)]
    page: Value,
    #[qml(notify, readonly)]
    agent: Value,
    #[qml(notify, readonly)]
    deck_id: Atom,
    #[qml(notify, readonly)]
    deck: Value,
    #[qml(notify, readonly)]
    presenting: bool,
    #[qml(notify, readonly)]
    slide: Value,
    #[qml(notify, readonly)]
    slide_number: i32,
    #[qml(notify, readonly)]
    slide_count: i32,
    #[qml(notify, readonly)]
    status: Atom,
    #[qml(notify, readonly)]
    viewers: Value,
}

impl Default for SpacesObject {
    fn default() -> Self {
        SpacesObject {
            spaces: Value::Null,
            pages: Value::Null,
            trash: Value::Null,
            blocks: Value::Null,
            comments: Value::Null,
            history: Value::Null,
            decks: Value::Null,
            deck_trash: Value::Null,
            slides: Value::Null,
            images: Value::Null,
            image_trash: Value::Null,
            projects: Value::Null,
            space_id: Atom::new(""),
            space_name: Atom::new(""),
            page_id: Atom::new(""),
            file_space_id: Atom::new(""),
            page: Value::Null,
            agent: Value::Null,
            deck_id: Atom::new(""),
            deck: Value::Null,
            presenting: false,
            slide: Value::Null,
            slide_number: 0,
            slide_count: 0,
            status: Atom::new("loading"),
            viewers: Value::Null,
        }
    }
}

/// `Spaces.history` in QML.
#[derive(Debug, Default, QmlObject)]
#[qml(module = "HalC2.Shell", name = "SpaceHistory", uncreatable)]
pub struct SpaceHistoryObject {
    #[qml(notify, readonly)]
    shown: bool,
    #[qml(notify, readonly)]
    page_id: Atom,
    #[qml(constant, readonly)]
    versions: Value,
    #[qml(constant, readonly)]
    blocks: Value,
    #[qml(notify, readonly)]
    loading: bool,
    #[qml(notify, readonly)]
    failed: bool,
    #[qml(notify, readonly)]
    has_more: bool,
    #[qml(notify, readonly)]
    reading: bool,
    #[qml(notify, readonly)]
    version: Value,
}

#[qml_impl]
impl SpaceHistoryObject {
    #[qml(signal)]
    fn changed();
}

struct Pending {
    block_id: String,
    value: Json,
    token: i64,
    answered_at: String,
}

struct Address {
    url: String,
    expires_at: i64,
}

/// A one-shot timer of the controller's, restarted by stopping it first.
struct OneShot {
    timer: Cell<Option<ObjectId>>,
}

impl OneShot {
    fn new() -> OneShot {
        OneShot {
            timer: Cell::new(None),
        }
    }

    fn active(&self) -> bool {
        self.timer.get().is_some()
    }

    fn stop(&self, engine: &Engine) {
        if let Some(timer) = self.timer.take() {
            controller::stop_timer(engine, timer);
        }
    }
}

const BLOCK_ROLES: [&str; 22] = [
    "id",
    "kind",
    "text",
    "level",
    "language",
    "checked",
    "linkedPageId",
    "linkedTitle",
    "byAgent",
    "openComments",
    "chart",
    "imageId",
    "imageState",
    "imageUrl",
    "imageWidth",
    "imageHeight",
    "markdownAbove",
    "markdownLead",
    "markdownTail",
    "markdownBelow",
    "listBullets",
    "listNumbers",
];

const IMAGE_ROLES: [&str; 8] = [
    "id",
    "name",
    "prompt",
    "mimeType",
    "width",
    "height",
    "generatedBy",
    "url",
];

pub struct Space {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Space>,
    // The streams, shared with their subscriptions' resumes.
    index: Rc<RefCell<SpaceStream>>,
    space_stream: Rc<RefCell<SpaceStream>>,
    file_stream: Rc<RefCell<SpaceStream>>,
    unreachable: bool,
    file_unreachable: bool,
    space_id: String,
    page_id: String,
    awaited_space: String,
    awaited_page: String,
    file_space_id: String,
    file_shown: bool,
    awaited_file_page: String,
    viewers: Row,
    viewers_page: String,
    deck_id: String,
    awaited_deck: String,
    presenting: bool,
    slide_id: String,
    slide_index: i32,
    pending: HashMap<String, Pending>,
    tokens: i64,
    images_shown: bool,
    addresses: HashMap<String, Address>,
    signing: HashSet<String>,
    now: Rc<dyn Fn() -> i64>,
    address_refresh: OneShot,
    address_refresh_due: Cell<Option<i64>>,
    rebuild_soon: OneShot,
    history_refresh: OneShot,
    viewers_retry: OneShot,
    viewers_retry_ms: i64,
    spaces: Rows,
    pages: Rows,
    trash: Rows,
    blocks: Rows,
    comments: Rows,
    decks: Rows,
    deck_trash: Rows,
    slides: Rows,
    images: Rows,
    image_trash: Rows,
    project_rows: Rows,
    history_versions: Rows,
    history_blocks: Rows,
    history: History,
    history_obj: ObjectId,
    projects: Projects,
    active: bool,
    open: bool,
    listed: bool,
    index_subscription: Option<SubId>,
    space_subscription: Option<SubId>,
    file_subscription: Option<SubId>,
    followed_file_space: String,
    opening: i64,
    viewers_subscription: Option<SubId>,
    followed_space: String,
    followed_viewers: String,
    page_shown_by_steps: bool,
    page_shown: bool,
    error: String,
    writing: i64,
    drawing: i64,
    adding_images: i64,
    generating_images: i64,
    image_providers: Row,
    written: String,
    files: Row,
    picking: String,
    last_picked: String,
    listing: HashMap<String, i64>,
    files_wanted: HashSet<String>,
    file_tokens: i64,
    synced: String,
    history_offset: i64,
    remembering_expanded: bool,
}

impl Space {
    fn arm(
        &self,
        engine: &Engine,
        timer: &OneShot,
        ms: i64,
        f: impl Fn(&mut Space, &Engine) + 'static,
    ) {
        timer.stop(engine);
        let native = ljos::prelude::Timer {
            interval: i32::try_from(ms.clamp(0, i64::from(i32::MAX))).unwrap_or(i32::MAX),
            repeat: false,
            running: true,
            ..ljos::prelude::Timer::default()
        };
        let Ok(id) = engine.create_native(native, None) else {
            return;
        };
        timer.timer.set(Some(id));
        let me = self.me.clone();
        let f = Rc::new(f);
        let connected = engine.connect_by_name(id, "triggered", move |engine, _| {
            let f = f.clone();
            me.run(engine, move |c, engine| f(c, engine));
        });
        if connected.is_err() || engine.complete(id).is_err() {
            timer.stop(engine);
        }
    }

    fn thread_title(&self, engine: &Engine, thread_id: &str) -> String {
        let key = format!("{}:{thread_id}", self.mc.environment());
        let title = store::with(engine, |s| {
            s.thread(&key).map(|t| t.title).unwrap_or_default()
        });
        if title.is_empty() {
            "a thread".into()
        } else {
            title
        }
    }

    fn project_title(&self, engine: &Engine, project_id: &str) -> String {
        let environment = self.mc.environment();
        store::with(engine, |s| {
            s.project_row(&environment, project_id)
                .map(|r| text(r, "title"))
                .unwrap_or_default()
        })
    }

    // --- The streams, read as copies ------------------------------------

    fn shown_stream(&self) -> Rc<RefCell<SpaceStream>> {
        if self.file_shown {
            self.file_stream.clone()
        } else {
            self.space_stream.clone()
        }
    }

    /// The Space the open page is of: the file's project Space, else the
    /// selected one.
    pub fn shown_space_id(&self) -> String {
        if self.file_shown {
            self.file_space_id.clone()
        } else {
            self.space_id.clone()
        }
    }

    pub fn file_space_id(&self) -> String {
        if self.file_shown {
            self.file_space_id.clone()
        } else {
            String::new()
        }
    }

    /// The project Space followed for a file's page, on show or awaited.
    fn file_space_followed(&self) -> String {
        self.file_space_id.clone()
    }

    fn title_of(&self, page_id: &str) -> String {
        let mut page = self.shown_stream().borrow().entity("page", page_id);
        if page.is_empty() {
            page = self.space_stream.borrow().entity("page", page_id);
        }
        let title = text(&page, "title");
        let title = title.trim();
        if title.is_empty() {
            "Untitled".into()
        } else {
            title.to_owned()
        }
    }

    pub fn space_name(&self) -> String {
        text(&self.index.borrow().entity("space", &self.space_id), "name")
    }

    pub fn status(&self) -> String {
        if self.unreachable || (self.file_shown && self.file_unreachable) {
            return "unreachable".into();
        }
        let live = if self.space_id.is_empty() {
            self.index.borrow().live()
        } else {
            self.space_stream.borrow().live()
        };
        if live {
            "live".into()
        } else {
            "loading".into()
        }
    }

    fn live_page(&self, page: &Entity) -> bool {
        let stream = self.shown_stream();
        let stream = stream.borrow();
        let pages = stream.of("page");
        let mut seen: HashSet<String> = HashSet::new();
        let mut at = page.clone();
        while !at.is_empty() {
            if trashed(&at) {
                return false;
            }
            let parent = text(&at, "parentPageId");
            if parent.is_empty() || seen.contains(&parent) {
                break;
            }
            seen.insert(parent.clone());
            at = pages.get(&parent).cloned().unwrap_or_default();
        }
        true
    }

    pub fn page(&self, engine: &Engine) -> Row {
        let page = self.shown_stream().borrow().entity("page", &self.page_id);
        if page.is_empty() {
            return Row::new();
        }
        let thread = text(&page, "sourceThreadId");
        let mut row = Row::new();
        row.insert("id".into(), json!(self.page_id));
        row.insert("title".into(), json!(self.title_of(&self.page_id)));
        row.insert("parentPageId".into(), json!(text(&page, "parentPageId")));
        row.insert("trashed".into(), json!(!self.live_page(&page)));
        row.insert("sourceThreadId".into(), json!(thread));
        row.insert(
            "sourceThreadTitle".into(),
            json!(if thread.is_empty() {
                String::new()
            } else {
                self.thread_title(engine, &thread)
            }),
        );
        row.insert("schedule".into(), Json::Object(update_of(&page)));
        row.insert("writtenAt".into(), json!(text(&page, "writtenAt")));
        row.insert("site".into(), Json::Object(self.site_of(&self.page_id)));
        row.insert(
            "file".into(),
            Json::Object(self.file_of(engine, &self.page_id)),
        );
        row
    }

    pub fn site_of(&self, page_id: &str) -> Row {
        let stream = self.shown_stream();
        let stream = stream.borrow();
        for site in stream.of("site").values() {
            if text(site, "pageId") != page_id {
                continue;
            }
            let mut row = Row::new();
            row.insert("url".into(), json!(text(site, "url")));
            row.insert(
                "localOnly".into(),
                json!(
                    site.get("localOnly")
                        .and_then(JsonValue::as_bool)
                        .unwrap_or(false)
                ),
            );
            row.insert(
                "behind".into(),
                json!(
                    site.get("behind")
                        .and_then(JsonValue::as_bool)
                        .unwrap_or(false)
                ),
            );
            row.insert("publishedAt".into(), json!(text(site, "publishedAt")));
            return row;
        }
        Row::new()
    }

    pub fn file_of(&self, engine: &Engine, page_id: &str) -> Row {
        let mut page = self.shown_stream().borrow().entity("page", page_id);
        if page.is_empty() {
            page = self.space_stream.borrow().entity("page", page_id);
        }
        let file = page
            .get("file")
            .and_then(JsonValue::as_object)
            .cloned()
            .unwrap_or_default();
        if file.is_empty() {
            return Row::new();
        }
        let project = text(&file, "projectId");
        let title = self.project_title(engine, &project);
        let mut row = Row::new();
        row.insert("projectId".into(), json!(project));
        row.insert(
            "projectTitle".into(),
            json!(if title.is_empty() {
                "a project".into()
            } else {
                title
            }),
        );
        row.insert("path".into(), json!(text(&file, "path")));
        row.insert(
            "missing".into(),
            json!(
                file.get("missing")
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false)
            ),
        );
        row.insert(
            "unwritten".into(),
            json!(
                file.get("unwritten")
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false)
            ),
        );
        row.insert("conflictAt".into(), json!(text(&file, "conflictAt")));
        row
    }

    pub fn agent(&self, engine: &Engine) -> Row {
        let agent = self
            .shown_stream()
            .borrow()
            .entity("pageAgent", &self.page_id);
        if agent.is_empty() {
            return Row::new();
        }
        let thread = text(&agent, "threadId");
        let mut row = Row::new();
        row.insert("status".into(), json!(text(&agent, "status")));
        row.insert("request".into(), json!(text(&agent, "request")));
        row.insert("threadId".into(), json!(thread.clone()));
        row.insert(
            "threadTitle".into(),
            json!(self.thread_title(engine, &thread)),
        );
        row.insert(
            "edited".into(),
            json!(
                agent
                    .get("edited")
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false)
            ),
        );
        row.insert("error".into(), json!(text(&agent, "error")));
        row
    }

    pub fn deck(&self) -> Row {
        let deck = self.space_stream.borrow().entity("deck", &self.deck_id);
        if deck.is_empty() {
            return Row::new();
        }
        let mut row = Row::new();
        row.insert("id".into(), json!(self.deck_id));
        row.insert("title".into(), json!(text(&deck, "title")));
        row.insert("trashed".into(), json!(trashed(&deck)));
        row
    }

    pub fn slide(&self) -> Row {
        if self.presenting {
            self.slides.get(self.slide_index)
        } else {
            Row::new()
        }
    }

    pub fn slide_number(&self) -> i32 {
        if self.presenting {
            self.slide_index + 1
        } else {
            0
        }
    }

    pub fn slide_count(&self) -> i32 {
        if self.presenting {
            self.slides.count() as i32
        } else {
            0
        }
    }

    // --- What the streams say -------------------------------------------

    pub fn receive_index(&mut self, engine: &Engine, frame: &Frame) {
        let was = std::mem::replace(&mut self.unreachable, false);
        if self.index.borrow_mut().receive(frame) || was {
            self.rebuild(engine);
        }
    }

    pub fn receive_space(&mut self, engine: &Engine, frame: &Frame) {
        let was = std::mem::replace(&mut self.unreachable, false);
        if self.space_stream.borrow_mut().receive(frame) || was {
            self.rebuild(engine);
        }
    }

    pub fn receive_file_space(&mut self, engine: &Engine, frame: &Frame) {
        if self.file_space_id.is_empty() {
            return;
        }
        let was = std::mem::replace(&mut self.file_unreachable, false);
        if self.file_stream.borrow_mut().receive(frame) || was {
            self.rebuild(engine);
        }
    }

    pub fn set_unreachable(&mut self, engine: &Engine, unreachable: bool) {
        if std::mem::replace(&mut self.unreachable, unreachable) != unreachable {
            self.rebuild(engine);
        }
    }

    pub fn set_file_unreachable(&mut self, engine: &Engine) {
        if self.file_space_id.is_empty() {
            return;
        }
        if !std::mem::replace(&mut self.file_unreachable, true) {
            self.rebuild(engine);
        }
    }

    pub fn receive_viewers(&mut self, engine: &Engine, page_id: &str, frame: &Frame) {
        if page_id != self.page_id
            || frame.get("t").and_then(JsonValue::as_str) != Some("spacePresence")
        {
            return;
        }
        let mut devices: Vec<String> = Vec::new();
        let mut agents: Vec<String> = Vec::new();
        if let Some(viewers) = frame.get("viewers").and_then(JsonValue::as_array) {
            for viewer in viewers {
                let Some(row) = viewer.as_object() else {
                    continue;
                };
                if row.get("type").and_then(JsonValue::as_str) == Some("agent") {
                    agents.push(text(row, "title"));
                } else if let Some(list) = row.get("devices").and_then(JsonValue::as_array) {
                    devices.extend(list.iter().filter_map(|d| d.as_str().map(str::to_owned)));
                }
            }
        }
        self.viewers_page = page_id.to_owned();
        let mut viewers = Row::new();
        viewers.insert("devices".into(), json!(devices));
        viewers.insert("agents".into(), json!(agents));
        if viewers == self.viewers {
            return;
        }
        self.viewers = viewers;
        self.sync_viewers(engine);
    }

    pub fn clear_viewers(&mut self, engine: &Engine) {
        self.viewers_page.clear();
        if self.viewers.is_empty() {
            return;
        }
        self.viewers.clear();
        self.sync_viewers(engine);
    }

    fn sync_viewers(&self, engine: &Engine) {
        if let Ok(obj) = self.bridge.singleton::<SpacesObject>(engine) {
            let _ = engine.set_internal(
                obj,
                SpacesObject::VIEWERS,
                Json::Object(self.viewers.clone()).to_value(),
            );
        }
    }
}

/// "Every 2 hours", "Every day at 07:30", "Mon, Wed at 09:00".
pub fn cadence_label(cadence: &Entity) -> String {
    if cadence.get("type").and_then(JsonValue::as_str) == Some("interval") {
        let minutes = cadence
            .get("everyMs")
            .and_then(JsonValue::as_f64)
            .map_or(0, |ms| ms as i64 / 60_000);
        if minutes == 60 {
            return "Every hour".into();
        }
        if minutes > 0 && minutes % 60 == 0 {
            return format!("Every {} hours", minutes / 60);
        }
        return if minutes == 1 {
            "Every minute".into()
        } else {
            format!("Every {minutes} minutes")
        };
    }
    const NAMES: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let mut days: Vec<&str> = Vec::new();
    if let Some(weekdays) = cadence.get("weekdays").and_then(JsonValue::as_array) {
        for day in weekdays {
            if let Some(d) = day.as_i64()
                && let Some(name) = usize::try_from(d).ok().and_then(|i| NAMES.get(i))
            {
                days.push(name);
            }
        }
    }
    format!(
        "{} at {}",
        if days.is_empty() || days.len() == NAMES.len() {
            "Every day".into()
        } else {
            days.join(", ")
        },
        text(cadence, "timeOfDay")
    )
}

/// What the MC shows of a page's update plus its `cadenceLabel`.
pub fn update_of(page: &Entity) -> Row {
    let schedule = page
        .get("schedule")
        .and_then(JsonValue::as_object)
        .cloned()
        .unwrap_or_default();
    if schedule.is_empty() {
        return Row::new();
    }
    let mut update = schedule.clone();
    let cadence = schedule
        .get("cadence")
        .and_then(JsonValue::as_object)
        .cloned()
        .unwrap_or_default();
    update.insert("cadenceLabel".into(), json!(cadence_label(&cadence)));
    update
}

impl Space {
    // --- Selection -------------------------------------------------------

    pub fn select_space(&mut self, engine: &Engine, id: &str) {
        if !self.index.borrow().has("space", id) {
            return;
        }
        if id == self.space_id {
            if self.leave_file(engine) {
                self.rebuild(engine);
            }
            return;
        }
        self.leave_file(engine);
        self.switch_space(engine, id);
    }

    fn switch_space(&mut self, engine: &Engine, id: &str) {
        self.space_id = id.to_owned();
        if !self.file_shown {
            self.page_id.clear();
        }
        self.deck_id.clear();
        self.presenting = false;
        if id != self.awaited_space {
            self.awaited_page.clear();
            self.awaited_deck.clear();
        }
        self.space_stream.borrow_mut().clear();
        if !self.file_shown {
            self.pending.clear();
        }
        self.addresses.clear();
        self.signing.clear();
        if !id.is_empty() {
            self.rebuild(engine);
        } else {
            self.sync_singleton(engine);
        }
        if self.open {
            self.follow_space(engine);
        }
    }

    fn leave_file(&mut self, engine: &Engine) -> bool {
        let was_shown = std::mem::replace(&mut self.file_shown, false);
        self.awaited_file_page.clear();
        if self.file_space_id.is_empty() {
            return was_shown;
        }
        self.file_space_id.clear();
        self.file_stream.borrow_mut().clear();
        self.file_unreachable = false;
        if self.open {
            self.follow_file_space(engine);
        }
        was_shown
    }

    pub fn select_page(&mut self, engine: &Engine, id: &str) {
        if self.file_shown && self.file_stream.borrow().has("page", id) {
            if id == self.page_id && self.deck_id.is_empty() && self.awaited_file_page.is_empty() {
                return;
            }
            self.awaited_file_page.clear();
        } else if self.space_stream.borrow().has("page", id) {
            if id == self.page_id && self.deck_id.is_empty() && self.file_space_id.is_empty() {
                return;
            }
            self.leave_file(engine);
        } else {
            return;
        }
        self.page_id = id.to_owned();
        self.deck_id.clear();
        self.presenting = false;
        self.rebuild(engine);
    }

    pub fn select_deck(&mut self, engine: &Engine, id: &str) {
        if (id == self.deck_id && self.file_space_id.is_empty())
            || !self.space_stream.borrow().has("deck", id)
        {
            return;
        }
        self.leave_file(engine);
        self.deck_id = id.to_owned();
        self.presenting = false;
        self.rebuild(engine);
    }

    pub fn open_file_page(&mut self, engine: &Engine, space_id: &str, page_id: &str) {
        if space_id.is_empty() || page_id.is_empty() {
            return;
        }
        self.awaited_space.clear();
        self.awaited_page.clear();
        self.awaited_deck.clear();
        let another = space_id != self.file_space_id;
        if another {
            self.file_space_id = space_id.to_owned();
            self.file_stream.borrow_mut().clear();
            self.file_unreachable = false;
            if self.file_shown {
                self.page_id.clear();
            }
        }
        self.awaited_file_page = page_id.to_owned();
        self.rebuild(engine);
        if another && self.open {
            self.follow_file_space(engine);
        }
    }

    pub fn await_space(&mut self, engine: &Engine, id: &str) {
        self.awaited_space = id.to_owned();
        self.select_space(engine, id);
    }

    pub fn await_page(&mut self, engine: &Engine, id: &str) {
        self.awaited_deck.clear();
        self.awaited_file_page.clear();
        self.awaited_page = if self.space_stream.borrow().has("page", id) {
            String::new()
        } else {
            id.to_owned()
        };
        self.select_page(engine, id);
    }

    pub fn await_deck(&mut self, engine: &Engine, id: &str) {
        self.awaited_page.clear();
        self.awaited_file_page.clear();
        self.awaited_deck = if self.space_stream.borrow().has("deck", id) {
            String::new()
        } else {
            id.to_owned()
        };
        self.select_deck(engine, id);
    }

    pub fn set_images_shown(&mut self, engine: &Engine, shown: bool) {
        if std::mem::replace(&mut self.images_shown, shown) != shown {
            self.rebuild(engine);
        }
    }

    pub fn images_shown(&self) -> bool {
        self.images_shown
    }

    // --- Presenting ------------------------------------------------------

    pub fn present(&mut self, engine: &Engine, id: &str) -> bool {
        let deck = self.space_stream.borrow().entity("deck", id);
        if deck.is_empty() || trashed(&deck) {
            return false;
        }
        self.select_deck(engine, id);
        if self.slides.count() == 0 {
            return false;
        }
        self.presenting = true;
        self.slide_index = 0;
        self.slide_id = text(&self.slides.get(0), "id");
        self.sync_singleton(engine);
        self.follow_viewers(engine);
        true
    }

    pub fn step(&mut self, engine: &Engine, by: i32) {
        if !self.presenting {
            return;
        }
        let at = (self.slide_index + by).clamp(0, self.slides.count() as i32 - 1);
        if at == self.slide_index {
            return;
        }
        self.slide_index = at;
        self.slide_id = text(&self.slides.get(at), "id");
        self.sync_singleton(engine);
    }

    pub fn leave(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.presenting, false) {
            self.sync_singleton(engine);
            self.follow_viewers(engine);
        }
    }

    fn follow_presenter(&mut self) {
        if !self.presenting {
            return;
        }
        let deck = self.space_stream.borrow().entity("deck", &self.deck_id);
        let count = self.slides.count();
        if deck.is_empty() || trashed(&deck) || count == 0 {
            self.presenting = false;
            return;
        }
        let at = self.slides.index_of(&self.slide_id);
        self.slide_index = if at >= 0 {
            at
        } else {
            self.slide_index.min(count as i32 - 1)
        };
        self.slide_id = text(&self.slides.get(self.slide_index), "id");
    }

    // --- The user's own edits, shown until the MC answers ----------------

    pub fn pend(&mut self, engine: &Engine, block_id: &str, field: &str, value: Json) -> i64 {
        self.tokens += 1;
        let token = self.tokens;
        self.pending.insert(
            format!("{block_id}\n{field}"),
            Pending {
                block_id: block_id.to_owned(),
                value,
                token,
                answered_at: String::new(),
            },
        );
        self.rebuild(engine);
        token
    }

    pub fn settle(&mut self, engine: &Engine, token: i64, block: Option<Entity>) {
        let key = self
            .pending
            .iter()
            .find(|(_, p)| p.token == token)
            .map(|(k, _)| k.clone());
        let Some(key) = key else { return };
        match block {
            None => {
                self.pending.remove(&key);
            }
            Some(block) => {
                let at = text(&block, "updatedAt");
                if let Some(p) = self.pending.get_mut(&key) {
                    p.answered_at = if at.is_empty() { " ".into() } else { at };
                }
            }
        }
        self.rebuild(engine);
    }

    pub fn pending(&self, block_id: &str, field: &str) -> bool {
        self.pending.contains_key(&format!("{block_id}\n{field}"))
    }

    fn block_of(&self, id: &str) -> Entity {
        let block = self.space_stream.borrow().entity("block", id);
        if block.is_empty() {
            self.file_stream.borrow().entity("block", id)
        } else {
            block
        }
    }

    fn reconcile(&mut self) {
        let mut gone: Vec<String> = Vec::new();
        for (key, p) in &self.pending {
            let block = self.block_of(&p.block_id);
            let caught_up = !p.answered_at.is_empty() && text(&block, "updatedAt") >= p.answered_at;
            if block.is_empty() || caught_up {
                gone.push(key.clone());
            }
        }
        for key in gone {
            self.pending.remove(&key);
        }
    }

    // --- Image addresses -------------------------------------------------

    pub fn set_image_address(
        &mut self,
        engine: &Engine,
        image_id: &str,
        url: &str,
        expires_at: i64,
    ) {
        if !self.signing.remove(image_id) {
            return;
        }
        let at_least = (self.now)() + ADDRESS_AT_LEAST_MS;
        self.addresses.insert(
            image_id.to_owned(),
            Address {
                url: url.to_owned(),
                expires_at: expires_at.max(at_least),
            },
        );
        if !self.rebuild_soon.active() {
            self.arm(engine, &self.rebuild_soon, REBUILD_SOON_MS, |c, engine| {
                c.rebuild_soon.stop(engine);
                c.rebuild(engine);
            });
        }
    }

    pub fn image_address_failed(&mut self, engine: &Engine, image_id: &str) {
        self.signing.remove(image_id);
        let remaining = self.address_refresh_due.get().map(|due| due - now_ms());
        if !self.address_refresh.active() || remaining.is_some_and(|r| r > ADDRESS_RETRY_MS) {
            self.address_refresh_due
                .set(Some(now_ms() + ADDRESS_RETRY_MS));
            self.arm(
                engine,
                &self.address_refresh,
                ADDRESS_RETRY_MS,
                |c, engine| {
                    c.address_refresh.stop(engine);
                    c.rebuild(engine);
                },
            );
        }
    }

    fn image_fields(&self, image_id: &str) -> Row {
        let stream = self.shown_stream();
        let stream = stream.borrow();
        let image = stream.of("image").get(image_id);
        let state = if image_id.is_empty() {
            ""
        } else if image.is_none() {
            "deleted"
        } else if trashed(image.expect("found")) {
            "trashed"
        } else {
            "shown"
        };
        let mut row = Row::new();
        row.insert("imageId".into(), json!(image_id));
        row.insert("imageState".into(), json!(state));
        row.insert(
            "imageUrl".into(),
            json!(if state == "shown" {
                self.addresses
                    .get(image_id)
                    .map_or("", |a| a.url.as_str())
                    .to_owned()
            } else {
                String::new()
            }),
        );
        row.insert(
            "imageWidth".into(),
            json!(
                image
                    .and_then(|i| i.get("width"))
                    .and_then(JsonValue::as_i64)
                    .unwrap_or(0)
            ),
        );
        row.insert(
            "imageHeight".into(),
            json!(
                image
                    .and_then(|i| i.get("height"))
                    .and_then(JsonValue::as_i64)
                    .unwrap_or(0)
            ),
        );
        row
    }

    fn images_to_sign(&mut self, wanted: &HashSet<String>) -> Vec<String> {
        let now = (self.now)();
        let mut needed: Vec<String> = Vec::new();
        for id in wanted {
            if self.signing.contains(id) {
                continue;
            }
            if let Some(address) = self.addresses.get(id)
                && address.expires_at - ADDRESS_MARGIN_MS > now
            {
                continue;
            }
            self.signing.insert(id.clone());
            needed.push(id.clone());
        }
        needed.sort();
        needed
    }

    fn arm_address_refresh(&self, engine: &Engine, wanted: &HashSet<String>) {
        let mut due: Option<i64> = None;
        for id in wanted {
            let Some(address) = self.addresses.get(id) else {
                continue;
            };
            if self.signing.contains(id) {
                continue;
            }
            due = Some(due.map_or(address.expires_at, |d: i64| d.min(address.expires_at)));
        }
        let Some(due) = due else {
            self.address_refresh.stop(engine);
            self.address_refresh_due.set(None);
            return;
        };
        let delay = (due - ADDRESS_MARGIN_MS - (self.now)()).max(0);
        self.address_refresh_due.set(Some(now_ms() + delay));
        self.arm(engine, &self.address_refresh, delay, |c, engine| {
            c.address_refresh.stop(engine);
            c.rebuild(engine);
        });
    }

    // --- Keeping the selection on what the streams hold ------------------

    fn reselect(&mut self, engine: &Engine) -> bool {
        let (has_awaited, has_copy, has_space, first_space) = {
            let index = self.index.borrow();
            let spaces = index.of("space");
            let made = sorted(spaces.values().cloned().collect(), "createdAt");
            (
                spaces.contains_key(&self.awaited_space),
                index.has_copy(),
                spaces.contains_key(&self.space_id),
                made.first().map(|s| text(s, "id")),
            )
        };
        if has_awaited {
            if self.awaited_space != self.space_id {
                let awaited = self.awaited_space.clone();
                self.select_space(engine, &awaited);
                self.awaited_space.clear();
                return true;
            }
            self.awaited_space.clear();
        }
        if has_copy && !has_space {
            if let Some(first) = first_space {
                self.switch_space(engine, &first);
                return true;
            }
            if !self.space_id.is_empty() {
                self.switch_space(engine, "");
            }
        }
        if self.space_stream.borrow().has("page", &self.awaited_page)
            && !self.awaited_page.is_empty()
        {
            self.leave_file(engine);
            self.page_id = std::mem::take(&mut self.awaited_page);
            self.deck_id.clear();
            self.presenting = false;
        }
        if self.space_stream.borrow().has("deck", &self.awaited_deck)
            && !self.awaited_deck.is_empty()
        {
            self.leave_file(engine);
            self.deck_id = std::mem::take(&mut self.awaited_deck);
            self.presenting = false;
        }
        let (file_has, file_copy, file_has_page) = {
            let file = self.file_stream.borrow();
            (
                !self.awaited_file_page.is_empty() && file.has("page", &self.awaited_file_page),
                file.has_copy(),
                file.has("page", &self.page_id),
            )
        };
        if file_has {
            self.file_shown = true;
            self.page_id = std::mem::take(&mut self.awaited_file_page);
            self.deck_id.clear();
            self.presenting = false;
        } else if self.file_shown
            && self.awaited_file_page.is_empty()
            && file_copy
            && !file_has_page
        {
            self.leave_file(engine);
        }
        false
    }

    // --- The rows ---------------------------------------------------------

    pub fn rebuild(&mut self, engine: &Engine) {
        self.rebuild_soon.stop(engine);
        if self.reselect(engine) {
            return;
        }
        self.reconcile();

        let spaces: Vec<Row> = {
            let index = self.index.borrow();
            sorted(index.of("space").values().cloned().collect(), "createdAt")
                .iter()
                .map(|space| {
                    let mut row = Row::new();
                    row.insert("id".into(), json!(text(space, "id")));
                    row.insert("name".into(), json!(text(space, "name")));
                    row
                })
                .collect()
        };
        self.spaces.set(engine, spaces);

        // The tree, depth first, each page's subpages in the order made.
        let (tree, in_trash, space_has_copy, page_held) = {
            let stream = self.space_stream.borrow();
            let pages = stream.of("page");
            let mut children: HashMap<String, Vec<Entity>> = HashMap::new();
            let mut in_trash: Vec<Entity> = Vec::new();
            for page in pages.values() {
                if trashed(page) {
                    in_trash.push(page.clone());
                    continue;
                }
                let parent = text(page, "parentPageId");
                let key = if pages.contains_key(&parent) {
                    parent
                } else {
                    String::new()
                };
                children.entry(key).or_default().push(page.clone());
            }
            for list in children.values_mut() {
                *list = sorted(std::mem::take(list), "createdAt");
            }
            let mut tree: Vec<Row> = Vec::new();
            let mut placed: HashSet<String> = HashSet::new();
            // title_of borrows the stream again; read the tree from copies.
            let titles: HashMap<String, String> = pages
                .keys()
                .map(|id| {
                    let title = text(&pages[id], "title");
                    let title = title.trim();
                    (
                        id.clone(),
                        if title.is_empty() {
                            "Untitled".into()
                        } else {
                            title.to_owned()
                        },
                    )
                })
                .collect();
            fn place_titled(
                children: &HashMap<String, Vec<Entity>>,
                titles: &HashMap<String, String>,
                parent: &str,
                depth: i64,
                tree: &mut Vec<Row>,
                placed: &mut HashSet<String>,
            ) {
                for page in children.get(parent).into_iter().flatten() {
                    let id = text(page, "id");
                    if placed.contains(&id) {
                        continue;
                    }
                    placed.insert(id.clone());
                    let mut row = Row::new();
                    row.insert("id".into(), json!(id));
                    row.insert(
                        "title".into(),
                        json!(
                            titles
                                .get(&id)
                                .cloned()
                                .unwrap_or_else(|| "Untitled".into())
                        ),
                    );
                    row.insert("depth".into(), json!(depth));
                    row.insert("parentPageId".into(), json!(parent));
                    row.insert(
                        "hasChildren".into(),
                        json!(children.get(&id).is_some_and(|c| !c.is_empty())),
                    );
                    row.insert(
                        "fromThread".into(),
                        json!(!text(page, "sourceThreadId").is_empty()),
                    );
                    tree.push(row);
                    place_titled(children, titles, &id, depth + 1, tree, placed);
                }
            }
            place_titled(&children, &titles, "", 0, &mut tree, &mut placed);
            (
                tree,
                in_trash,
                stream.has_copy(),
                pages.contains_key(&self.page_id),
            )
        };
        let first_page = tree.first().map(|r| {
            r.get("id")
                .and_then(JsonValue::as_str)
                .unwrap_or("")
                .to_owned()
        });
        self.pages.set(engine, tree);
        if !self.file_shown && space_has_copy && !page_held {
            self.page_id = first_page.unwrap_or_default();
        }

        let mut latest = sorted(in_trash, "trashedAt");
        latest.reverse();
        let trash: Vec<Row> = latest
            .iter()
            .map(|page| {
                let id = text(page, "id");
                let mut row = Row::new();
                row.insert("id".into(), json!(id));
                row.insert("title".into(), json!(self.title_of(&id)));
                row.insert("trashedAt".into(), json!(text(page, "trashedAt")));
                row
            })
            .collect();
        self.trash.set(engine, trash);

        // The open page's comments and blocks.
        let (mut page_comments, page_blocks, images_held, file_images_held) = {
            let shown = self.shown_stream();
            let shown = shown.borrow();
            let comments: Vec<Entity> = shown
                .of("comment")
                .values()
                .filter(|c| text(c, "pageId") == self.page_id)
                .cloned()
                .collect();
            let blocks: Vec<Entity> = shown
                .of("block")
                .values()
                .filter(|b| text(b, "pageId") == self.page_id)
                .cloned()
                .collect();
            let space_images: Vec<Entity> = {
                let space = self.space_stream.borrow();
                space.of("image").values().cloned().collect()
            };
            let file_images: HashSet<String> = {
                let file = self.file_stream.borrow();
                file.of("image").keys().cloned().collect()
            };
            (comments, blocks, space_images, file_images)
        };
        let mut open: HashMap<String, i64> = HashMap::new();
        for comment in &page_comments {
            if text(comment, "resolvedAt").is_empty() {
                *open.entry(text(comment, "blockId")).or_default() += 1;
            }
        }
        let image_ids: HashSet<String> = images_held.iter().map(|i| text(i, "id")).collect();
        self.addresses
            .retain(|id, _| image_ids.contains(id) || file_images_held.contains(id));

        let mut wanted: HashSet<String> = HashSet::new();
        let mut on_page: HashSet<String> = HashSet::new();
        let ordered = sorted(page_blocks, "order");
        let items = list_items(&ordered);
        let mut blocks: Vec<Row> = Vec::new();
        for (i, block) in ordered.iter().enumerate() {
            let id = text(block, "id");
            on_page.insert(id.clone());
            let image_id = if text(block, "kind") == "image" {
                text(block, "imageId")
            } else {
                String::new()
            };
            let fields = self.image_fields(&image_id);
            if fields.get("imageState").and_then(JsonValue::as_str) == Some("shown") {
                wanted.insert(image_id.clone());
            }
            let linked = text(block, "linkedPageId");
            let shown_value = |this: &Space, field: &str, value: Json| -> Json {
                this.pending
                    .get(&format!("{id}\n{field}"))
                    .map_or(value, |p| p.value.clone())
            };
            let mut row = Row::new();
            row.insert("id".into(), json!(id));
            row.insert("kind".into(), json!(text(block, "kind")));
            row.insert(
                "text".into(),
                shown_value(self, "text", json!(text(block, "text"))),
            );
            row.insert(
                "level".into(),
                json!(block.get("level").and_then(JsonValue::as_i64).unwrap_or(2)),
            );
            row.insert("language".into(), json!(text(block, "language")));
            let checked = shown_value(
                self,
                "checked",
                json!(
                    block
                        .get("checked")
                        .and_then(JsonValue::as_bool)
                        .unwrap_or(false)
                ),
            );
            row.insert("checked".into(), json!(checked.as_bool().unwrap_or(false)));
            row.insert("linkedPageId".into(), json!(linked));
            row.insert(
                "linkedTitle".into(),
                json!(if linked.is_empty() {
                    String::new()
                } else {
                    self.title_of(&linked)
                }),
            );
            row.insert("byAgent".into(), json!(by_agent(block.get("createdBy"))));
            row.insert(
                "openComments".into(),
                json!(open.get(&id).copied().unwrap_or(0)),
            );
            row.insert(
                "chart".into(),
                block.get("chart").cloned().unwrap_or_else(|| json!({})),
            );
            for (k, v) in fields {
                row.insert(k, v);
            }
            for (k, v) in markdown_frame(block, items.get(i).and_then(|o| o.as_ref())) {
                row.insert(k, v);
            }
            blocks.push(row);
        }
        self.blocks.set(engine, blocks);
        for image_id in self.history.images_read() {
            if self
                .image_fields(&image_id)
                .get("imageState")
                .and_then(JsonValue::as_str)
                == Some("shown")
            {
                wanted.insert(image_id);
            }
        }
        self.sync_history(engine, true);

        let mut kept: Vec<Row> = Vec::new();
        let mut binned: Vec<Row> = Vec::new();
        let mut newest = sorted(images_held, "createdAt");
        newest.reverse();
        for image in &newest {
            let id = text(image, "id");
            if self.images_shown {
                wanted.insert(id.clone());
            }
            let mut row = Row::new();
            row.insert("id".into(), json!(id));
            row.insert("name".into(), json!(text(image, "name")));
            row.insert("prompt".into(), json!(text(image, "prompt")));
            row.insert("mimeType".into(), json!(text(image, "mimeType")));
            row.insert(
                "width".into(),
                json!(image.get("width").and_then(JsonValue::as_i64).unwrap_or(0)),
            );
            row.insert(
                "height".into(),
                json!(image.get("height").and_then(JsonValue::as_i64).unwrap_or(0)),
            );
            row.insert(
                "generatedBy".into(),
                json!(
                    image
                        .get("generatedBy")
                        .and_then(JsonValue::as_object)
                        .map(|by| text(by, "instanceId"))
                        .unwrap_or_default()
                ),
            );
            row.insert(
                "url".into(),
                json!(self.addresses.get(&id).map_or("", |a| a.url.as_str())),
            );
            if trashed(image) {
                binned.push(row);
            } else {
                kept.push(row);
            }
        }
        self.images.set(engine, kept);
        self.image_trash.set(engine, binned);

        page_comments.sort_by(|a, b| {
            let a_resolved = !text(a, "resolvedAt").is_empty();
            let b_resolved = !text(b, "resolvedAt").is_empty();
            b_resolved
                .cmp(&a_resolved)
                .then_with(|| text(a, "createdAt").cmp(&text(b, "createdAt")))
                .then_with(|| text(a, "id").cmp(&text(b, "id")))
        });
        let comments: Vec<Row> = page_comments
            .iter()
            .map(|comment| {
                let block_id = text(comment, "blockId");
                let block = self.shown_stream().borrow().entity("block", &block_id);
                let mut row = Row::new();
                row.insert("id".into(), json!(text(comment, "id")));
                row.insert("blockId".into(), json!(block_id.clone()));
                row.insert("blockText".into(), json!(text(&block, "text")));
                row.insert(
                    "blockGone".into(),
                    json!(!block_id.is_empty() && !on_page.contains(&block_id)),
                );
                row.insert("body".into(), json!(text(comment, "body")));
                row.insert(
                    "resolved".into(),
                    json!(!text(comment, "resolvedAt").is_empty()),
                );
                row.insert("byAgent".into(), json!(by_agent(comment.get("author"))));
                row.insert("createdAt".into(), json!(text(comment, "createdAt")));
                row
            })
            .collect();
        self.comments.set(engine, comments);
        if self.viewers_page != self.page_id {
            self.clear_viewers(engine);
        }

        let (deck_rows, deck_trash_rows, slide_rows) = {
            let stream = self.space_stream.borrow();
            let decks = stream.of("deck");
            if stream.has_copy() && !decks.contains_key(&self.deck_id) && !self.deck_id.is_empty() {
                // Cleared below; the borrow ends first.
            }
            let mut live_decks: Vec<Entity> = Vec::new();
            let mut trashed_decks: Vec<Entity> = Vec::new();
            for deck in decks.values() {
                if trashed(deck) {
                    trashed_decks.push(deck.clone());
                } else {
                    live_decks.push(deck.clone());
                }
            }
            let deck_rows: Vec<Row> = sorted(live_decks, "createdAt")
                .iter()
                .map(|deck| {
                    let mut row = Row::new();
                    row.insert("id".into(), json!(text(deck, "id")));
                    row.insert("title".into(), json!(text(deck, "title")));
                    row
                })
                .collect();
            let mut trashed_decks = sorted(trashed_decks, "trashedAt");
            trashed_decks.reverse();
            let deck_trash_rows: Vec<Row> = trashed_decks
                .iter()
                .map(|deck| {
                    let mut row = Row::new();
                    row.insert("id".into(), json!(text(deck, "id")));
                    row.insert("title".into(), json!(text(deck, "title")));
                    row.insert("trashedAt".into(), json!(text(deck, "trashedAt")));
                    row
                })
                .collect();
            let deck_slides: Vec<Entity> = stream
                .of("slide")
                .values()
                .filter(|s| text(s, "deckId") == self.deck_id)
                .cloned()
                .collect();
            let slide_rows: Vec<Row> = sorted(deck_slides, "order")
                .iter()
                .map(|slide| {
                    let mut row = Row::new();
                    row.insert("id".into(), json!(text(slide, "id")));
                    row.insert("title".into(), json!(text(slide, "title")));
                    row.insert("body".into(), json!(text(slide, "body")));
                    row
                })
                .collect();
            let deck_held = decks.contains_key(&self.deck_id);
            (
                deck_rows,
                deck_trash_rows,
                (slide_rows, stream.has_copy(), deck_held),
            )
        };
        let (slide_rows, deck_copy, deck_held) = slide_rows;
        if deck_copy && !deck_held {
            self.deck_id.clear();
        }
        self.decks.set(engine, deck_rows);
        self.deck_trash.set(engine, deck_trash_rows);
        self.slides.set(engine, slide_rows);
        self.follow_presenter();
        self.sync_projects(engine);
        self.sync_singleton(engine);
        tell(engine, shared(engine).changed.borrow().clone());
        self.follow_history(engine);
        self.follow_viewers(engine);
        let needed = self.images_to_sign(&wanted);
        self.arm_address_refresh(engine, &wanted);
        if !needed.is_empty() {
            self.sign_images(engine, needed);
        }
    }

    fn sync_projects(&mut self, engine: &Engine) {
        if self.projects.dirty {
            self.projects.dirty = false;
            let rows = self.projects.build();
            self.project_rows.set(engine, rows);
        }
        if self.projects.expanded_changed {
            self.projects.expanded_changed = false;
            self.remember_expanded(engine);
        }
    }

    fn sync_history(&mut self, engine: &Engine, repaint: bool) {
        // A history that stopped reading shows no version's blocks, as SpaceHistory::stopReading.
        if repaint || (self.history.changed && !self.history.reading()) {
            let blocks = {
                let this: &Space = self;
                this.history
                    .blocks(&|id| this.title_of(id), &|id| this.image_fields(id))
            };
            self.history_blocks.set(engine, blocks);
        }
        if !self.history.changed {
            return;
        }
        self.history.changed = false;
        let versions = self.history.versions();
        self.history_versions.set(engine, versions);
        let obj = self.history_obj;
        let _ = engine.set_internal(obj, SpaceHistoryObject::SHOWN, self.history.shown());
        let _ = engine.set_internal(
            obj,
            SpaceHistoryObject::PAGE_ID,
            Atom::new(self.history.page_id()),
        );
        let _ = engine.set_internal(obj, SpaceHistoryObject::LOADING, self.history.loading());
        let _ = engine.set_internal(obj, SpaceHistoryObject::FAILED, self.history.failed());
        let _ = engine.set_internal(obj, SpaceHistoryObject::HAS_MORE, self.history.has_more());
        let _ = engine.set_internal(obj, SpaceHistoryObject::READING, self.history.reading());
        let _ = engine.set_internal(
            obj,
            SpaceHistoryObject::VERSION,
            Json::Object(self.history.version()).to_value(),
        );
        let _ = SpaceHistoryObject::emit_changed(&Cx::new(engine, obj));
        if self.history.images_arrived {
            self.history.images_arrived = false;
            if !self.rebuild_soon.active() {
                self.arm(engine, &self.rebuild_soon, REBUILD_SOON_MS, |c, engine| {
                    c.rebuild_soon.stop(engine);
                    c.rebuild(engine);
                });
            }
        }
    }

    fn sync_singleton(&self, engine: &Engine) {
        let Ok(obj) = self.bridge.singleton::<SpacesObject>(engine) else {
            return;
        };
        let _ = engine.set_internal(obj, SpacesObject::SPACE_ID, Atom::new(&self.space_id));
        let _ = engine.set_internal(obj, SpacesObject::SPACE_NAME, Atom::new(&self.space_name()));
        let _ = engine.set_internal(obj, SpacesObject::PAGE_ID, Atom::new(&self.page_id));
        let _ = engine.set_internal(
            obj,
            SpacesObject::FILE_SPACE_ID,
            Atom::new(&self.file_space_id()),
        );
        let _ = engine.set_internal(
            obj,
            SpacesObject::PAGE,
            Json::Object(self.page(engine)).to_value(),
        );
        let _ = engine.set_internal(
            obj,
            SpacesObject::AGENT,
            Json::Object(self.agent(engine)).to_value(),
        );
        let _ = engine.set_internal(obj, SpacesObject::DECK_ID, Atom::new(&self.deck_id));
        let _ = engine.set_internal(
            obj,
            SpacesObject::DECK,
            Json::Object(self.deck()).to_value(),
        );
        let _ = engine.set_internal(obj, SpacesObject::PRESENTING, self.presenting);
        let _ = engine.set_internal(
            obj,
            SpacesObject::SLIDE,
            Json::Object(self.slide()).to_value(),
        );
        let _ = engine.set_internal(obj, SpacesObject::SLIDE_NUMBER, self.slide_number());
        let _ = engine.set_internal(obj, SpacesObject::SLIDE_COUNT, self.slide_count());
        let _ = engine.set_internal(obj, SpacesObject::STATUS, Atom::new(&self.status()));
        let _ = engine.set_internal(
            obj,
            SpacesObject::VIEWERS,
            Json::Object(self.viewers.clone()).to_value(),
        );
    }

    // --- Following the MC -------------------------------------------------

    fn set_open(&mut self, engine: &Engine, open: bool) {
        if std::mem::replace(&mut self.open, open) == open {
            return;
        }
        if open {
            self.follow(engine);
            let environment = self.mc.environment();
            let projects = store::with(engine, |s| {
                s.project_rows(&environment)
                    .iter()
                    .map(|r| text(r, "id"))
                    .collect::<Vec<_>>()
            });
            for project in projects {
                self.list_files(engine, &environment, &project);
            }
        } else {
            self.leave(engine);
            self.unfollow();
            self.history.close();
            self.sync_history(engine, false);
            self.history_refresh.stop(engine);
            self.page_shown = false;
            if !std::mem::take(&mut self.picking).is_empty() {
                self.publish(engine);
            }
        }
        self.follow_viewers(engine);
    }

    fn follow(&mut self, engine: &Engine) {
        if !self.mc.is_ready() || self.mc.environment().is_empty() {
            return;
        }
        if !self.listed {
            self.call(engine, "list", json!({}), |c, _, _| {
                c.listed = true;
            });
        }
        if self.index_subscription.is_none() {
            let me = self.me.clone();
            let stream = self.index.clone();
            let shape = space_shape(&self.mc.environment(), "spaces");
            self.index_subscription = Some(self.mc.subscribe(
                shape,
                Box::new(move |engine, frame| {
                    let frame = frame.clone();
                    me.run_after(engine, move |c, engine| {
                        let kind = frame.get("t").and_then(JsonValue::as_str).unwrap_or("");
                        if kind == "error" || kind == "end" {
                            c.set_unreachable(engine, true);
                        } else {
                            c.receive_index(engine, &frame);
                        }
                    });
                }),
                Some(Box::new(move || {
                    stream
                        .try_borrow_mut()
                        .map(|mut s| {
                            let resume = s.subscribing();
                            resume.as_object().cloned().unwrap_or_default()
                        })
                        .unwrap_or_default()
                })),
            ));
        }
        self.follow_space(engine);
        self.follow_file_space(engine);
    }

    fn follow_space(&mut self, _engine: &Engine) {
        if self.followed_space == self.space_id
            && (self.space_subscription.is_some() || self.space_id.is_empty())
        {
            return;
        }
        if let Some(id) = self.space_subscription.take() {
            self.mc.unsubscribe(id);
        }
        self.followed_space.clone_from(&self.space_id);
        if self.followed_space.is_empty() || !self.mc.is_ready() {
            return;
        }
        let followed = self.followed_space.clone();
        let me = self.me.clone();
        let stream = self.space_stream.clone();
        let resume_stream = self.space_stream.clone();
        let resume_for = followed.clone();
        let shape = space_shape(&self.mc.environment(), &format!("space:{followed}"));
        self.space_subscription = Some(self.mc.subscribe(
            shape,
            Box::new(move |engine, frame| {
                let frame = frame.clone();
                let followed = followed.clone();
                me.run_after(engine, move |c, engine| {
                    if followed != c.space_id {
                        return;
                    }
                    let kind = frame.get("t").and_then(JsonValue::as_str).unwrap_or("");
                    if kind == "error" || kind == "end" {
                        c.set_unreachable(engine, true);
                    } else {
                        c.receive_space(engine, &frame);
                    }
                });
            }),
            Some(Box::new(move || {
                let _ = &stream;
                resume_stream
                    .try_borrow_mut()
                    .map(|mut s| {
                        let _ = &resume_for;
                        s.subscribing().as_object().cloned().unwrap_or_default()
                    })
                    .unwrap_or_default()
            })),
        ));
    }

    fn follow_file_space(&mut self, _engine: &Engine) {
        let wanted = self.file_space_followed();
        if self.followed_file_space == wanted
            && (self.file_subscription.is_some() || wanted.is_empty())
        {
            return;
        }
        if let Some(id) = self.file_subscription.take() {
            self.mc.unsubscribe(id);
        }
        self.followed_file_space.clone_from(&wanted);
        if wanted.is_empty() || !self.mc.is_ready() {
            return;
        }
        let me = self.me.clone();
        let stream = self.file_stream.clone();
        let shape = space_shape(&self.mc.environment(), &format!("space:{wanted}"));
        self.file_subscription = Some(self.mc.subscribe(
            shape,
            Box::new(move |engine, frame| {
                let frame = frame.clone();
                let wanted = wanted.clone();
                me.run_after(engine, move |c, engine| {
                    if wanted != c.file_space_followed() {
                        return;
                    }
                    let kind = frame.get("t").and_then(JsonValue::as_str).unwrap_or("");
                    if kind == "error" || kind == "end" {
                        c.set_file_unreachable(engine);
                    } else {
                        c.receive_file_space(engine, &frame);
                    }
                });
            }),
            Some(Box::new(move || {
                stream
                    .try_borrow_mut()
                    .map(|mut s| s.subscribing().as_object().cloned().unwrap_or_default())
                    .unwrap_or_default()
            })),
        ));
    }

    fn unfollow(&mut self) {
        if let Some(id) = self.index_subscription.take() {
            self.mc.unsubscribe(id);
        }
        if let Some(id) = self.space_subscription.take() {
            self.mc.unsubscribe(id);
        }
        if let Some(id) = self.file_subscription.take() {
            self.mc.unsubscribe(id);
        }
        self.followed_space.clear();
        self.followed_file_space.clear();
    }

    fn page_on_show(&self) -> bool {
        self.open
            && self.mc.is_ready()
            && self.deck_id.is_empty()
            && !self.images_shown
            && (!self.page_shown_by_steps || self.page_shown)
    }

    /// The page the prompt writes on, as page_on_show but connected or not.
    fn prompt_page_here(&self, engine: &Engine) -> String {
        let shown = self.open
            && self.deck_id.is_empty()
            && !self.images_shown
            && (!self.page_shown_by_steps || self.page_shown);
        if shown
            && self
                .page(engine)
                .get("trashed")
                .and_then(JsonValue::as_bool)
                != Some(true)
        {
            self.page_id.clone()
        } else {
            String::new()
        }
    }

    fn follow_viewers(&mut self, engine: &Engine) {
        self.sync_shown_file(engine);
        let shared = shared(engine);
        *shared.prompt_page.borrow_mut() = self.prompt_page_here(engine);
        *shared.prompt_images.borrow_mut() = if self.open && self.images_shown {
            self.space_id.clone()
        } else {
            String::new()
        };
        tell(engine, shared.prompt_page_changed.borrow().clone());
        let page = if self.page_on_show() {
            self.page_id.clone()
        } else {
            String::new()
        };
        if page == self.followed_viewers {
            return;
        }
        if let Some(id) = self.viewers_subscription.take() {
            self.mc.unsubscribe(id);
        }
        self.followed_viewers.clone_from(&page);
        self.clear_viewers(engine);
        if page.is_empty() {
            return;
        }
        self.subscribe_viewers(engine);
    }

    fn subscribe_viewers(&mut self, engine: &Engine) {
        let page = self.followed_viewers.clone();
        let me = self.me.clone();
        let shape = json!({
            "type": "spacePresence",
            "environment": self.mc.environment(),
            "spaceId": self.shown_space_id(),
            "pageId": page,
        });
        let on_page = page.clone();
        self.viewers_subscription = Some(self.mc.subscribe(
            shape,
            Box::new(move |engine, frame| {
                let frame = frame.clone();
                let on_page = on_page.clone();
                me.run_after(engine, move |c, engine| {
                    if frame.get("t").and_then(JsonValue::as_str) == Some("error") {
                        if let Some(id) = c.viewers_subscription.take() {
                            c.mc.unsubscribe(id);
                        }
                        c.clear_viewers(engine);
                        let ms = c.viewers_retry_ms;
                        c.arm(engine, &c.viewers_retry, ms, |c, engine| {
                            c.viewers_retry.stop(engine);
                            if c.viewers_subscription.is_none() && !c.followed_viewers.is_empty() {
                                c.subscribe_viewers(engine);
                            }
                        });
                        return;
                    }
                    c.receive_viewers(engine, &on_page, &frame);
                });
            }),
            None,
        ));
        let _ = engine;
    }

    fn sync_shown_file(&mut self, engine: &Engine) {
        let page = if self.page_on_show() && !self.file_of(engine, &self.page_id).is_empty() {
            self.page_id.clone()
        } else {
            String::new()
        };
        if page == self.synced {
            return;
        }
        self.synced.clone_from(&page);
        if page.is_empty() {
            return;
        }
        let environment = self.mc.environment();
        self.mc.call(
            &environment,
            "space.page.syncFile",
            json!({"spaceId": self.shown_space_id(), "pageId": page}),
            Box::new(|_, _| {}),
        );
    }

    fn follow_history(&mut self, engine: &Engine) {
        if !self.history.shown() {
            return;
        }
        if !self.deck_id.is_empty() {
            self.history_refresh.stop(engine);
            self.history.close();
            self.sync_history(engine, false);
        } else if self.history.page_id() != self.page_id {
            let page = self.page_id.clone();
            self.open_history(engine, &page);
        } else if self.shown_stream().borrow().offset() != self.history_offset {
            self.history_offset = self.shown_stream().borrow().offset();
            if !self.history_refresh.active() {
                self.arm(
                    engine,
                    &self.history_refresh,
                    HISTORY_REFRESH_MS,
                    |c, engine| {
                        c.history_refresh.stop(engine);
                        let next = c.history.refresh();
                        c.ask_history(engine, next);
                    },
                );
            }
        }
    }

    fn open_history(&mut self, engine: &Engine, page: &str) {
        self.history_refresh.stop(engine);
        self.history_offset = self.shown_stream().borrow().offset();
        let next = self.history.open(page);
        self.sync_history(engine, false);
        self.ask_history(engine, next);
    }

    fn ask_history(&mut self, engine: &Engine, request: Next) {
        let Some(request) = request else { return };
        let token = request.token;
        self.call_full(
            engine,
            "page.history",
            request.payload,
            move |c, engine, result| {
                let result = result.as_object().cloned().unwrap_or_default();
                let next = c.history.receive(token, &result);
                c.sync_history(engine, false);
                c.ask_history(engine, next);
            },
            move |c, engine, _detail| {
                let next = c.history.receive_failed(token);
                c.sync_history(engine, false);
                c.ask_history(engine, next);
                String::new()
            },
        );
    }

    // --- Calling the MC -----------------------------------------------------

    /// `space.<method>` with the selected Space's id unless the payload
    /// names one. A refusal is said in the MC's words, or in what
    /// `refused` returns for its detail ("" keeps the MC's).
    fn call_full(
        &mut self,
        engine: &Engine,
        method: &str,
        mut payload: Json,
        done: impl Fn(&mut Space, &Engine, Json) + 'static,
        refused: impl Fn(&mut Space, &Engine, Entity) -> String + 'static,
    ) {
        if method != "list"
            && method != "create"
            && method != "page.openFile"
            && !method.starts_with("files.")
            && payload.get("spaceId").is_none()
        {
            let on_file = |this: &Space, kind: &str, field: &str| {
                payload.get(field).is_some_and(|_| {
                    this.file_stream
                        .borrow()
                        .has(kind, &str_of(&payload, field))
                })
            };
            let file = !self.file_space_followed().is_empty()
                && (on_file(self, "page", "pageId")
                    || on_file(self, "block", "blockId")
                    || on_file(self, "comment", "commentId"));
            let space = if file {
                self.file_space_followed()
            } else {
                self.space_id.clone()
            };
            if let Some(map) = payload.as_object_mut() {
                map.insert("spaceId".into(), json!(space));
            }
        }
        if !self.error.is_empty() {
            self.error.clear();
            self.publish(engine);
        }
        let me = self.me.clone();
        let done = Rc::new(done);
        let refused = Rc::new(refused);
        let environment = self.mc.environment();
        self.mc.call(
            &environment,
            &format!("space.{method}"),
            payload,
            Box::new(move |engine, result| {
                let done = done.clone();
                let refused = refused.clone();
                me.run_after(engine, move |c, engine| match result {
                    Ok(result) => done(c, engine, result),
                    Err(error) => {
                        let detail = error.detail.as_object().cloned().unwrap_or_default();
                        let said = refused(c, engine, detail);
                        let message = if said.is_empty() { error.message } else { said };
                        c.refuse(engine, &message);
                    }
                });
            }),
        );
    }

    fn call(
        &mut self,
        engine: &Engine,
        method: &str,
        payload: Json,
        done: impl Fn(&mut Space, &Engine, Json) + 'static,
    ) {
        self.call_full(engine, method, payload, done, |_, _, _| String::new());
    }

    fn call_plain(&mut self, engine: &Engine, method: &str, payload: Json) {
        self.call(engine, method, payload, |_, _, _| {});
    }

    fn refuse(&mut self, engine: &Engine, message: &str) {
        self.error = message.to_owned();
        self.publish(engine);
        toast(engine, "error", message, "");
    }

    fn publish(&self, engine: &Engine) {
        let mut projects: Vec<Json> = Vec::new();
        if !self.picking.is_empty() {
            let environment = self.mc.environment();
            projects = store::with(engine, |s| {
                s.project_rows(&environment)
                    .iter()
                    .map(|r| json!({"id": text(r, "id"), "title": text(r, "title")}))
                    .collect()
            });
        }
        self.bridge.publish(
            engine,
            "space",
            json!({
                "error": self.error,
                "busy": self.writing > 0,
                "drawing": self.drawing > 0,
                "written": self.written,
                "addingImage": self.adding_images > 0,
                "generatingImage": self.generating_images > 0,
                "imageProviders": Json::Object(self.image_providers.clone()),
                "files": Json::Object(self.files.clone()),
                "picking": self.picking,
                "projects": projects,
            }),
        );
    }
}

fn space_shape(environment: &str, stream: &str) -> Json {
    json!({"type": "stream", "environment": environment, "stream": stream})
}

impl Space {
    // --- Project Space files ------------------------------------------------

    pub fn set_browser_open(&mut self, engine: &Engine, open: bool) {
        self.set_open(engine, open);
    }

    pub fn set_page_shown(&mut self, engine: &Engine, shown: bool) {
        if std::mem::replace(&mut self.page_shown, shown) != shown {
            self.follow_viewers(engine);
        }
    }

    pub fn set_page_shown_by_steps(&mut self) {
        self.page_shown_by_steps = true;
    }

    pub fn set_viewers_retry_ms(&mut self, ms: i64) {
        self.viewers_retry_ms = ms;
    }

    pub fn set_clock(&mut self, clock: Rc<dyn Fn() -> i64>) {
        self.now = clock;
    }

    fn refresh_projects(&mut self, engine: &Engine) {
        let environment = self.mc.environment();
        let projects = store::with(engine, |s| {
            s.project_rows(&environment)
                .iter()
                .map(|r| projects::Project {
                    id: text(r, "id"),
                    title: text(r, "title"),
                })
                .collect::<Vec<_>>()
        });
        let ids: Vec<String> = projects.iter().map(|p| p.id.clone()).collect();
        self.projects.set_projects(projects);
        self.sync_projects(engine);
        if !self.open {
            return;
        }
        for id in ids {
            if !self.files.contains_key(&id) && !self.listing.contains_key(&id) {
                self.list_files(engine, &environment.clone(), &id);
            }
        }
    }

    /// Asks the MC for `project_id`'s Space files, this MC's only.
    pub fn list_files(&mut self, _engine: &Engine, environment: &str, project_id: &str) {
        if project_id.is_empty() || environment != self.mc.environment() {
            return;
        }
        self.files_wanted.insert(project_id.to_owned());
        if !self.mc.is_ready() {
            return;
        }
        self.file_tokens += 1;
        let token = self.file_tokens;
        self.listing.insert(project_id.to_owned(), token);
        let me = self.me.clone();
        let project = project_id.to_owned();
        self.mc.call(
            environment,
            "space.files.list",
            json!({"projectId": project_id}),
            Box::new(move |engine, result| {
                let project = project.clone();
                me.run_after(engine, move |c, engine| {
                    if c.listing.get(&project).copied() != Some(token) {
                        return;
                    }
                    match result {
                        Err(error) => {
                            if error.message == "disconnected" {
                                return;
                            }
                            c.listing.remove(&project);
                            let mut listed = Row::new();
                            listed.insert("config".into(), json!(""));
                            listed.insert("paths".into(), json!({}));
                            listed.insert("error".into(), json!(error.message));
                            c.files.insert(project.clone(), Json::Object(listed));
                            c.projects.set_files(&project, HashMap::new());
                            c.sync_projects(engine);
                            c.publish(engine);
                        }
                        Ok(result) => {
                            let result = result.as_object().cloned().unwrap_or_default();
                            c.receive_files(engine, &project, &result);
                        }
                    }
                });
            }),
        );
    }

    fn receive_files(&mut self, engine: &Engine, project: &str, result: &Entity) {
        let mut paths = Row::new();
        let mut pages: HashMap<String, String> = HashMap::new();
        if let Some(files) = result.get("files").and_then(JsonValue::as_array) {
            for value in files {
                let Some(file) = value.as_object() else {
                    continue;
                };
                let page = obj(&Json::Object(file.clone()), "page");
                let relative = text(file, "relativePath");
                pages.insert(relative.clone(), text(&page, "pageId"));
                let mut entry = Row::new();
                entry.insert("kind".into(), json!(text(file, "kind")));
                entry.insert("spaceId".into(), json!(text(&page, "spaceId")));
                entry.insert("pageId".into(), json!(text(&page, "pageId")));
                entry.insert("title".into(), json!(text(&page, "title")));
                paths.insert(relative, Json::Object(entry));
            }
        }
        let mut listed = Row::new();
        listed.insert("config".into(), json!(text(result, "config")));
        listed.insert("paths".into(), Json::Object(paths));
        self.files.insert(project.to_owned(), Json::Object(listed));
        self.projects.set_files(project, pages);
        self.sync_projects(engine);
        self.publish(engine);
    }

    /// Whether the project's Space files, as listed, have this file.
    pub fn is_space_file(&self, environment: &str, project: &str, relative_path: &str) -> bool {
        if environment != self.mc.environment() {
            return false;
        }
        let path = relative_path.strip_prefix("./").unwrap_or(relative_path);
        self.files
            .get(project)
            .and_then(JsonValue::as_object)
            .and_then(|listed| listed.get("paths"))
            .and_then(JsonValue::as_object)
            .is_some_and(|paths| paths.contains_key(path))
    }

    // Kept as "environment:project", so each MC's projects keep their own.
    fn remember_expanded(&mut self, engine: &Engine) {
        let environment = self.mc.environment();
        if environment.is_empty() || self.remembering_expanded {
            return;
        }
        self.remembering_expanded = true;
        let settings = Settings::of(engine);
        let mut keys: Vec<String> = settings
            .device_value(EXPANDED_KEY)
            .and_then(|v| {
                v.as_array().map(|list| {
                    list.iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect::<Vec<_>>()
                })
            })
            .unwrap_or_default()
            .into_iter()
            .filter(|k| !k.starts_with(&format!("{environment}:")))
            .collect();
        for project in self.projects.expanded_projects() {
            keys.push(format!("{environment}:{project}"));
        }
        if keys.is_empty() {
            settings.write_device(engine, EXPANDED_KEY, Json::Null);
        } else {
            settings.write_device(engine, EXPANDED_KEY, json!(keys));
        }
        let mut folders = settings
            .device_value(EXPANDED_FOLDERS_KEY)
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        let here = self.projects.expanded_folders();
        if here.is_empty() {
            folders.remove(&environment);
        } else {
            folders.insert(environment.clone(), Json::Object(here));
        }
        if folders.is_empty() {
            settings.write_device(engine, EXPANDED_FOLDERS_KEY, Json::Null);
        } else {
            settings.write_device(engine, EXPANDED_FOLDERS_KEY, Json::Object(folders));
        }
        self.remembering_expanded = false;
    }

    fn restore_expanded(&mut self, engine: &Engine) {
        let environment = self.mc.environment();
        if environment.is_empty() || self.remembering_expanded {
            return;
        }
        let settings = Settings::of(engine);
        let prefix = format!("{environment}:");
        let ids: Vec<String> = settings
            .device_value(EXPANDED_KEY)
            .and_then(|v| {
                v.as_array().map(|list| {
                    list.iter()
                        .filter_map(|v| v.as_str())
                        .filter_map(|k| k.strip_prefix(&prefix).map(str::to_owned))
                        .collect::<Vec<_>>()
                })
            })
            .unwrap_or_default();
        let folders = settings
            .device_value(EXPANDED_FOLDERS_KEY)
            .and_then(|v| v.as_object().cloned())
            .and_then(|all| {
                all.get(&environment)
                    .and_then(JsonValue::as_object)
                    .cloned()
            })
            .unwrap_or_default();
        self.projects.restore_expanded(ids, &folders);
        self.sync_projects(engine);
    }

    fn open_route(&self, engine: &Engine) {
        controller::with::<Navigation, _>(engine, |n, engine| {
            n.open(engine, Route::Space);
        });
    }

    fn scan_files(&mut self, engine: &Engine, project: &str, replace: bool) {
        let mut scan = json!({"projectId": project});
        if replace {
            scan["replace"] = json!(true);
        }
        let project = project.to_owned();
        self.call(engine, "files.scan", scan, move |c, engine, result| {
            let result = result.as_object().cloned().unwrap_or_default();
            let mut title = c.project_title(engine, &project);
            if title.is_empty() {
                title = "the project".into();
            }
            let mut entries: Vec<String> = Vec::new();
            if let Some(list) = result.get("entries").and_then(JsonValue::as_array) {
                for entry in list {
                    entries.push(
                        entry
                            .as_object()
                            .map(|e| text(e, "path"))
                            .unwrap_or_default(),
                    );
                }
            }
            let found = entries.join(", ");
            match text(&result, "status").as_str() {
                "written" => toast(
                    engine,
                    "success",
                    &format!("Wrote the spaces section of {title}"),
                    &found,
                ),
                "current" => toast(
                    engine,
                    "info",
                    &format!("The spaces section of {title} is up to date"),
                    &found,
                ),
                "kept" => {
                    let project = project.clone();
                    let me = c.me.clone();
                    toast_action(
                        engine,
                        format!("{title} keeps the spaces section someone wrote"),
                        format!("The scan would write: {found}"),
                        "Replace it".into(),
                        move |engine| {
                            me.run(engine, |c, engine| c.scan_files(engine, &project, true));
                        },
                    );
                }
                _ => toast(
                    engine,
                    "info",
                    &format!("{title} has no Markdown files for a Space"),
                    "",
                ),
            }
            let environment = c.mc.environment();
            c.list_files(engine, &environment, &project);
        });
    }

    fn project_here(&self, engine: &Engine) -> String {
        let environment = self.mc.environment();
        let key = controller::with::<Navigation, _>(engine, |n, _| n.thread_key().to_owned())
            .unwrap_or_default();
        if key.split(':').next().unwrap_or("") == environment {
            let project = store::with(engine, |s| {
                s.thread_row(&key)
                    .map_or(String::new(), |r| text(r, "projectId"))
            });
            if !project.is_empty() {
                return project;
            }
        }
        if !self.last_picked.is_empty() {
            let held = store::with(engine, |s| {
                s.project_row(&environment, &self.last_picked).is_some()
            });
            if held {
                return self.last_picked.clone();
            }
        }
        store::with(engine, |s| {
            s.project_rows(&environment)
                .first()
                .map_or(String::new(), |r| text(r, "id"))
        })
    }

    /// The project's file as a page, in the project's section.
    pub fn open_file(
        &mut self,
        engine: &Engine,
        environment: &str,
        project: &str,
        relative_path: &str,
    ) {
        if environment != self.mc.environment() {
            self.refuse(
                engine,
                "A file is edited as a page only from a project on this machine.",
            );
            return;
        }
        if !self.written.is_empty() {
            self.written.clear();
            self.publish(engine);
        }
        self.file_tokens += 1;
        let token = self.file_tokens;
        self.opening = token;
        let project = project.to_owned();
        let relative = relative_path.to_owned();
        let relative_refused = relative.clone();
        self.call_full(
            engine,
            "page.openFile",
            json!({"projectId": project, "relativePath": relative}),
            move |c, engine, result| {
                let environment = c.mc.environment();
                c.list_files(engine, &environment, &project);
                if c.opening != token {
                    return;
                }
                c.opening = 0;
                c.picking.clear();
                let result = result.as_object().cloned().unwrap_or_default();
                let page = obj(&Json::Object(result.clone()), "page");
                c.written = text(&page, "id");
                c.publish(engine);
                c.open_route(engine);
                c.projects.reveal(&project, &relative);
                c.sync_projects(engine);
                let space = text(&result, "spaceId");
                let written = c.written.clone();
                c.open_file_page(engine, &space, &written);
            },
            move |c, _engine, detail| {
                if c.opening == token {
                    c.opening = 0;
                }
                match text(&detail, "reason").as_str() {
                    "notSpaceFile" => format!(
                        "{relative_refused} is not a file this project shows in the Space sidebar. Add it to the spaces section of its hal-c2.json, or scan the project for Space files."
                    ),
                    "notFound" => format!("There is no file {relative_refused} in this project."),
                    "invalid" => format!("{relative_refused} is outside the project."),
                    _ => String::new(),
                }
            },
        );
    }

    pub fn export_page(&mut self, engine: &Engine, page_id: &str, done: Exported) {
        self.call(
            engine,
            "page.exportMarkdown",
            json!({"pageId": page_id}),
            move |c, engine, result| {
                let result = result.as_object().cloned().unwrap_or_default();
                done(c, engine, text(&result, "markdown"));
            },
        );
    }

    pub fn import_markdown(&mut self, engine: &Engine, markdown: &str) {
        self.call(
            engine,
            "page.importMarkdown",
            json!({"markdown": markdown}),
            |c, engine, result| {
                let result = result.as_object().cloned().unwrap_or_default();
                let page = obj(&Json::Object(result), "page");
                let id = text(&page, "id");
                c.await_page(engine, &id);
                toast(engine, "success", "Page imported", "");
            },
        );
    }

    fn write_from_thread(&mut self, engine: &Engine, space: &str, thread_id: &str) {
        self.writing += 1;
        self.publish(engine);
        toast(
            engine,
            "loading",
            "Writing a page from the thread\u{2026}",
            "",
        );
        let space_owned = space.to_owned();
        self.call_full(
            engine,
            "page.createFromThread",
            json!({"spaceId": space, "threadId": thread_id}),
            move |c, engine, result| {
                c.writing = (c.writing - 1).max(0);
                let result = result.as_object().cloned().unwrap_or_default();
                let page = obj(&Json::Object(result), "page");
                c.written = text(&page, "id");
                c.publish(engine);
                c.open_route(engine);
                c.await_space(engine, &space_owned);
                let written = c.written.clone();
                c.await_page(engine, &written);
                toast(engine, "success", "Page written from the thread", "");
            },
            |c, engine, detail| {
                c.writing = (c.writing - 1).max(0);
                c.publish(engine);
                if detail.get("_tag").and_then(JsonValue::as_str)
                    != Some("SpaceTextGenerationError")
                {
                    return String::new();
                }
                let why = text(&detail, "message");
                if text(&detail, "reason") == "unavailable" {
                    return "Text generation is unavailable, so no page was written. Set up a provider that can generate text in Settings, then try again.".into();
                }
                if why.is_empty() {
                    "Text generation failed, so no page was written.".into()
                } else {
                    format!("Text generation failed, so no page was written: {why}")
                }
            },
        );
    }

    pub fn page_from_thread(&mut self, engine: &Engine, thread_key: &str) {
        let colon = thread_key.find(':');
        let environment = colon.map_or("", |i| &thread_key[..i]);
        if environment != self.mc.environment() {
            self.refuse(
                engine,
                "A page can be made only from a thread on this machine. Move the thread here first.",
            );
            return;
        }
        let thread_id = colon.map_or("", |i| &thread_key[i + 1..]).to_owned();
        if !self.space_id.is_empty() {
            let space = self.space_id.clone();
            self.write_from_thread(engine, &space, &thread_id);
            return;
        }
        self.call(engine, "list", json!({}), move |c, engine, result| {
            c.listed = true;
            let first = result
                .get("spaces")
                .and_then(JsonValue::as_array)
                .and_then(|spaces| spaces.first())
                .and_then(JsonValue::as_object)
                .map(|space| text(space, "id"))
                .unwrap_or_default();
            if first.is_empty() {
                return;
            }
            c.write_from_thread(engine, &first, &thread_id);
        });
    }

    // --- Images ---------------------------------------------------------------

    fn sign_images(&mut self, _engine: &Engine, images: Vec<String>) {
        for id in images {
            let file = !self.file_space_followed().is_empty()
                && self.file_stream.borrow().has("image", &id);
            let space = if file {
                self.file_space_followed()
            } else {
                self.space_id.clone()
            };
            let me = self.me.clone();
            let environment = self.mc.environment();
            let origin = self.mc.origin().unwrap_or_default();
            let on_id = id.clone();
            self.mc.call(
                &environment,
                "assets.createUrl",
                json!({
                    "resource": {
                        "_tag": "space-image",
                        "spaceId": space,
                        "imageId": id,
                        "disposition": "inline",
                    }
                }),
                Box::new(move |engine, result| {
                    let on_id = on_id.clone();
                    let origin = origin.clone();
                    me.run_after(engine, move |c, engine| match result {
                        Err(_) => c.image_address_failed(engine, &on_id),
                        Ok(result) => {
                            let signed = result.as_object().cloned().unwrap_or_default();
                            let relative = text(&signed, "relativeUrl");
                            let url = if relative.starts_with('/') {
                                format!("{origin}{relative}")
                            } else {
                                relative
                            };
                            let expires = signed
                                .get("expiresAt")
                                .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
                                .unwrap_or(0);
                            c.set_image_address(engine, &on_id, &url, expires);
                        }
                    });
                }),
            );
        }
    }

    fn add_image_file(&mut self, engine: &Engine, url: &str) {
        let path = crate::bridge::local_path(url).unwrap_or_else(|| url.to_owned());
        let name = PathBuf::from(&path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let Ok(bytes) = std::fs::read(&path) else {
            self.refuse(engine, &format!("Could not read {path}."));
            return;
        };
        if path.is_empty() {
            self.refuse(engine, &format!("Could not read {path}."));
            return;
        }
        if bytes.len() as u64 > MAX_IMAGE_BYTES {
            self.refuse(
                engine,
                &format!("{name} is larger than the 10 MB an image may be."),
            );
            return;
        }
        let Some(mime) = image_kind(&bytes) else {
            self.refuse(
                engine,
                &format!("{name} is not a PNG, JPEG, GIF or WebP image."),
            );
            return;
        };
        self.error.clear();
        self.adding_images += 1;
        self.publish(engine);
        let space = self.space_id.clone();
        let me = self.me.clone();
        let environment = self.mc.environment();
        let failed = Rc::new(move |c: &mut Space, engine: &Engine, why: String| {
            c.adding_images = (c.adding_images - 1).max(0);
            c.refuse(engine, &why);
        });
        let failed1 = failed.clone();
        let size = bytes.len();
        self.mc.call(
            &environment,
            "attachments.createUploadUrl",
            json!({"name": name, "mimeType": mime, "sizeBytes": size}),
            Box::new(move |engine, result| {
                let failed1 = failed1.clone();
                let bytes = bytes.clone();
                let name = name.clone();
                let space = space.clone();
                me.run_after(engine, move |c, engine| {
                    let result = match result {
                        Err(error) => return failed1(c, engine, error.message),
                        Ok(result) => result,
                    };
                    let upload = result.as_object().cloned().unwrap_or_default();
                    let attachment = text(&upload, "attachmentId");
                    let relative = text(&upload, "relativeUrl");
                    let me = c.me.clone();
                    let failed2 = failed1.clone();
                    c.mc.upload(
                        &relative,
                        bytes,
                        mime,
                        Box::new(move |engine, up| {
                            let failed2 = failed2.clone();
                            let name = name.clone();
                            let space = space.clone();
                            let attachment = attachment.clone();
                            me.run_after(engine, move |c, engine| {
                                if let Err(error) = up {
                                    return failed2(c, engine, error.message);
                                }
                                c.adding_images = (c.adding_images - 1).max(0);
                                c.publish(engine);
                                c.call_plain(
                                    engine,
                                    "image.add",
                                    json!({
                                        "spaceId": space,
                                        "attachmentId": attachment,
                                        "name": name,
                                    }),
                                );
                            });
                        }),
                    );
                });
            }),
        );
    }

    // --- The page's agent, and making an image --------------------------------

    pub fn ask_agent(
        &mut self,
        engine: &Engine,
        page_id: &str,
        ask: Entity,
        answered: Option<Answered>,
    ) {
        let mut payload = Json::Object(ask);
        payload["pageId"] = json!(page_id);
        let request = str_of(&payload, "request");
        let page = page_id.to_owned();
        let page2 = page.clone();
        let request2 = request.clone();
        let answered2 = answered.clone();
        self.call_full(
            engine,
            "page.askAgent",
            payload,
            move |_c, engine, _result| {
                if let Some(answered) = &answered {
                    answered(engine, true);
                }
                tell_answered(engine, &page, &request, true);
            },
            move |_c, engine, _detail| {
                if let Some(answered) = &answered2 {
                    answered(engine, false);
                }
                tell_answered(engine, &page2, &request2, false);
                String::new()
            },
        );
    }

    /// The project a page's agent works in, empty when there is none.
    pub fn agent_target(&self, engine: &Engine, done: Settled) {
        let environment = self.mc.environment();
        self.mc.call(
            &environment,
            "space.page.agentTarget",
            json!({}),
            Box::new(move |engine, result| {
                let project = match result {
                    Ok(result) => result
                        .get("projectId")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_owned(),
                    Err(_) => String::new(),
                };
                done(engine, project);
            }),
        );
        let _ = engine;
    }

    pub fn image_providers(&self) -> Row {
        self.image_providers.clone()
    }

    pub fn generating_image(&self) -> bool {
        self.generating_images > 0
    }

    pub fn generate_image(
        &mut self,
        engine: &Engine,
        prompt: &str,
        selection: Entity,
        answered: Option<Answered>,
    ) {
        let mut generate = json!({"prompt": prompt});
        if !selection.is_empty() {
            generate["modelSelection"] = Json::Object(selection);
        }
        self.generating_images += 1;
        self.publish(engine);
        tell(engine, shared(engine).image_offer_changed.borrow().clone());
        toast(engine, "loading", "Generating an image\u{2026}", "");
        let answered2 = answered.clone();
        self.call_full(
            engine,
            "image.generate",
            generate,
            move |c, engine, _| {
                c.generating_images = (c.generating_images - 1).max(0);
                if let Some(answered) = &answered {
                    answered(engine, true);
                }
                c.publish(engine);
                tell(engine, shared(engine).image_offer_changed.borrow().clone());
                toast(engine, "success", "Image generated", "");
            },
            move |c, engine, detail| {
                c.generating_images = (c.generating_images - 1).max(0);
                if let Some(answered) = &answered2 {
                    answered(engine, false);
                }
                c.publish(engine);
                tell(engine, shared(engine).image_offer_changed.borrow().clone());
                if detail.get("_tag").and_then(JsonValue::as_str)
                    != Some("SpaceImageGenerationError")
                {
                    return String::new();
                }
                let why = text(&detail, "message");
                match text(&detail, "reason").as_str() {
                    "failed" => {
                        if why.is_empty() {
                            "Image generation failed, so no image was made.".into()
                        } else {
                            format!("Image generation failed, so no image was made: {why}")
                        }
                    }
                    "unavailable" => "Image generation is unavailable, so no image was made. Set up Codex or Grok in Settings, then try again.".into(),
                    _ => why,
                }
            },
        );
    }

    // --- Accessors for steps and other controllers ------------------------------

    pub fn space_id(&self) -> &str {
        &self.space_id
    }

    pub fn page_id(&self) -> &str {
        &self.page_id
    }

    pub fn deck_id(&self) -> &str {
        &self.deck_id
    }

    pub fn presenting(&self) -> bool {
        self.presenting
    }

    pub fn viewers(&self) -> Row {
        self.viewers.clone()
    }

    pub fn rows(&self, name: &str) -> Vec<Row> {
        match name {
            "spaces" => self.spaces.rows(),
            "pages" => self.pages.rows(),
            "trash" => self.trash.rows(),
            "blocks" => self.blocks.rows(),
            "comments" => self.comments.rows(),
            "decks" => self.decks.rows(),
            "deckTrash" => self.deck_trash.rows(),
            "slides" => self.slides.rows(),
            "images" => self.images.rows(),
            "imageTrash" => self.image_trash.rows(),
            "projects" => self.project_rows.rows(),
            _ => Vec::new(),
        }
    }

    pub fn rows_object(&self, name: &str) -> Option<Rows> {
        match name {
            "blocks" => Some(self.blocks.clone()),
            "pages" => Some(self.pages.clone()),
            _ => None,
        }
    }

    pub fn history(&self) -> &History {
        &self.history
    }

    pub fn history_blocks(&self) -> Vec<Row> {
        self.history_blocks.rows()
    }

    pub fn project_is_expanded(&self, project_id: &str) -> bool {
        self.projects.is_expanded(project_id)
    }

    pub fn stream_live(&self, name: &str) -> bool {
        match name {
            "index" => self.index.borrow().live(),
            "space" => self.space_stream.borrow().live(),
            "file" => self.file_stream.borrow().live(),
            _ => false,
        }
    }

    pub fn stream_entity(&self, name: &str, kind: &str, id: &str) -> Entity {
        match name {
            "index" => self.index.borrow().entity(kind, id),
            "space" => self.space_stream.borrow().entity(kind, id),
            "file" => self.file_stream.borrow().entity(kind, id),
            _ => Entity::new(),
        }
    }

    /// The ids of every `kind` entity the named stream's copy holds.
    pub fn stream_ids(&self, name: &str, kind: &str) -> Vec<String> {
        let ids = |stream: &SpaceStream| stream.of(kind).keys().cloned().collect();
        match name {
            "index" => ids(&self.index.borrow()),
            "space" => ids(&self.space_stream.borrow()),
            "file" => ids(&self.file_stream.borrow()),
            _ => Vec::new(),
        }
    }

    pub fn error(&self) -> &str {
        &self.error
    }

    pub fn is_open(&self) -> bool {
        self.open
    }
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3])
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The image kind `image/png`, `image/jpeg`, `image/gif` or `image/webp`
/// of its magic, empty for anything else.
fn image_kind(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF8") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

impl Space {
    fn set_model_once(&self, engine: &Engine, obj: ObjectId, prop: Prop<Value>, rows: &Rows) {
        let _ = engine.set_internal(obj, prop, Value::Object(rows.obj));
    }

    /// A navigation "threadId": bare, or "<env>:<id>".
    fn thread_key_of(&self, thread_id: &str) -> String {
        if thread_id.contains(':') {
            thread_id.to_owned()
        } else {
            format!("{}:{thread_id}", self.mc.environment())
        }
    }

    fn open_thread(&self, engine: &Engine, thread_id: &str) {
        let key = self.thread_key_of(thread_id);
        Bridge::of(engine).defer(engine, move |engine| {
            controller::with::<Navigation, _>(engine, |n, engine| {
                n.open(engine, Route::Thread(key));
            });
        });
    }

    fn show_file(&mut self, engine: &Engine, page_id: &str) {
        let file = self.file_of(engine, page_id);
        if file.is_empty() {
            self.refuse(engine, "This page is not a project file.");
            return;
        }
        let environment = self.mc.environment();
        let project = text(&file, "projectId");
        let root = store::with(engine, |s| {
            s.project_row(&environment, &project)
                .map(|r| clean_path(&text(r, "workspaceRoot")))
                .unwrap_or_default()
        });
        let threads = store::with(engine, |s| s.threads());
        let mut latest: Option<(String, String)> = None;
        let mut latest_on_root = false;
        for thread in &threads {
            if thread.environment_id != environment
                || thread.project_id != project
                || thread.archived_at.is_some()
                || thread.subagent
            {
                continue;
            }
            let worktree = store::with(engine, |s| {
                s.thread_row(&thread.key())
                    .map_or(String::new(), |r| text(r, "worktreePath"))
            });
            let here = worktree.is_empty() || clean_path(&worktree) == root;
            let better = match &latest {
                None => true,
                Some((_, at)) => {
                    (here && !latest_on_root) || (here == latest_on_root && &thread.updated_at > at)
                }
            };
            if better {
                latest = Some((thread.id.clone(), thread.updated_at.clone()));
                latest_on_root = here;
            }
        }
        let Some((id, _)) = latest else {
            let title = text(&file, "projectTitle");
            self.refuse(
                engine,
                &format!("Start a thread in {title} to see its files."),
            );
            return;
        };
        self.open_thread(engine, &format!("{environment}:{id}"));
        let path = text(&file, "path");
        Bridge::of(engine).defer(engine, move |engine| {
            Bridge::of(engine).dispatch(
                engine,
                "panel.open",
                json!({"tab": "files", "path": path}),
            );
        });
    }

    fn present_deck(&mut self, engine: &Engine, id: &str) {
        if self.present(engine, id) {
            return;
        }
        let deck = self.space_stream.borrow().entity("deck", id);
        let message = if !deck.is_empty() && !trashed(&deck) {
            "This deck has no slides to present."
        } else {
            "Restore this deck from the trash to present it."
        };
        self.refuse(engine, message);
    }
}

fn clean_path(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("/");
    if path.starts_with('/') {
        format!("/{joined}")
    } else {
        joined
    }
}

impl Controller for Space {
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        let bridge = init.bridge;
        let me = init.me.clone();
        let singleton = bridge
            .singleton::<SpacesObject>(engine)
            .expect("Spaces singleton");
        let owner = Some(singleton);
        let rows = |roles: &[&str]| Rows::create(engine, owner, roles).expect("Space rows");
        let spaces = rows(&["id", "name"]);
        let pages = rows(&[
            "id",
            "title",
            "depth",
            "parentPageId",
            "hasChildren",
            "fromThread",
        ]);
        let trash = rows(&["id", "title", "trashedAt"]);
        let blocks = rows(&BLOCK_ROLES);
        let comments = rows(&[
            "id",
            "blockId",
            "blockText",
            "blockGone",
            "body",
            "resolved",
            "byAgent",
            "createdAt",
        ]);
        let decks = rows(&["id", "title"]);
        let deck_trash = rows(&["id", "title", "trashedAt"]);
        let slides = rows(&["id", "title", "body"]);
        let images = rows(&IMAGE_ROLES);
        let image_trash = rows(&IMAGE_ROLES);
        let project_rows = rows(&[
            "id",
            "kind",
            "projectId",
            "path",
            "name",
            "depth",
            "expanded",
            "pageId",
        ]);
        let history_versions = rows(&[
            "id",
            "version",
            "at",
            "byAgent",
            "byUpdate",
            "byFile",
            "threadTitle",
            "restoredFromAt",
        ]);
        let history_blocks = rows(&BLOCK_ROLES);
        let history_obj = engine
            .create_native(SpaceHistoryObject::default(), owner)
            .expect("Space history");
        let _ = engine.set_internal(
            history_obj,
            SpaceHistoryObject::VERSIONS,
            Value::Object(history_versions.obj),
        );
        let _ = engine.set_internal(
            history_obj,
            SpaceHistoryObject::BLOCKS,
            Value::Object(history_blocks.obj),
        );
        let _ = engine.set_internal(
            history_obj,
            SpaceHistoryObject::VERSION,
            Json::Object(Row::new()).to_value(),
        );
        let hook_me = me.clone();
        store::on_changed(engine, move |engine| {
            hook_me.run(engine, |c, engine| {
                c.refresh_projects(engine);
                // A thread's title or a project's changed: what names them follows.
                if c.open {
                    c.rebuild(engine);
                } else {
                    c.sync_singleton(engine);
                }
            });
        });
        let hook_me = me.clone();
        init.mc.on_ready_changed(Box::new(move |engine, ready| {
            hook_me.run(engine, move |c, engine| {
                if ready {
                    c.set_unreachable(engine, false);
                }
            });
        }));
        let space = Space {
            bridge,
            mc: init.mc.clone(),
            me: me.clone(),
            index: Rc::new(RefCell::new(SpaceStream::new())),
            space_stream: Rc::new(RefCell::new(SpaceStream::new())),
            file_stream: Rc::new(RefCell::new(SpaceStream::new())),
            unreachable: false,
            file_unreachable: false,
            space_id: String::new(),
            page_id: String::new(),
            awaited_space: String::new(),
            awaited_page: String::new(),
            file_space_id: String::new(),
            file_shown: false,
            awaited_file_page: String::new(),
            viewers: Row::new(),
            viewers_page: String::new(),
            deck_id: String::new(),
            awaited_deck: String::new(),
            presenting: false,
            slide_id: String::new(),
            slide_index: 0,
            pending: HashMap::new(),
            tokens: 0,
            images_shown: false,
            addresses: HashMap::new(),
            signing: HashSet::new(),
            now: Rc::new(now_ms),
            address_refresh: OneShot::new(),
            address_refresh_due: Cell::new(None),
            rebuild_soon: OneShot::new(),
            history_refresh: OneShot::new(),
            viewers_retry: OneShot::new(),
            viewers_retry_ms: VIEWERS_RETRY_MS,
            spaces: spaces.clone(),
            pages: pages.clone(),
            trash: trash.clone(),
            blocks: blocks.clone(),
            comments: comments.clone(),
            decks: decks.clone(),
            deck_trash: deck_trash.clone(),
            slides: slides.clone(),
            images: images.clone(),
            image_trash: image_trash.clone(),
            project_rows: project_rows.clone(),
            history_versions,
            history_blocks,
            history: History::new(),
            history_obj,
            projects: Projects::new(),
            active: false,
            open: false,
            listed: false,
            index_subscription: None,
            space_subscription: None,
            file_subscription: None,
            followed_file_space: String::new(),
            opening: 0,
            viewers_subscription: None,
            followed_space: String::new(),
            followed_viewers: String::new(),
            page_shown_by_steps: false,
            page_shown: false,
            error: String::new(),
            writing: 0,
            drawing: 0,
            adding_images: 0,
            generating_images: 0,
            image_providers: Row::new(),
            written: String::new(),
            files: Row::new(),
            picking: String::new(),
            last_picked: String::new(),
            listing: HashMap::new(),
            files_wanted: HashSet::new(),
            file_tokens: 0,
            synced: String::new(),
            history_offset: -1,
            remembering_expanded: false,
        };
        for (prop, model) in [
            (SpacesObject::SPACES, &spaces),
            (SpacesObject::PAGES, &pages),
            (SpacesObject::TRASH, &trash),
            (SpacesObject::BLOCKS, &blocks),
            (SpacesObject::COMMENTS, &comments),
            (SpacesObject::DECKS, &decks),
            (SpacesObject::DECK_TRASH, &deck_trash),
            (SpacesObject::SLIDES, &slides),
            (SpacesObject::IMAGES, &images),
            (SpacesObject::IMAGE_TRASH, &image_trash),
            (SpacesObject::PROJECTS, &project_rows),
        ] {
            space.set_model_once(engine, singleton, prop, model);
        }
        let _ = engine.set_internal(singleton, SpacesObject::HISTORY, Value::Object(history_obj));
        space
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let commands = Commands::of(engine);
        let me = self.me.clone();
        commands.add(engine, OPEN, "Open Space", move |engine| {
            controller::with::<Navigation, _>(engine, |n, engine| {
                n.open(engine, Route::Space);
            });
        });
        commands.set_terms(OPEN, &["space", "pages", "notes", "docs", "wiki"]);
        commands.add(engine, PAGE_FROM_THREAD, "Create page from thread", {
            let me = me.clone();
            move |engine| {
                let key =
                    controller::with::<Navigation, _>(engine, |n, _| n.thread_key().to_owned())
                        .unwrap_or_default();
                me.run(engine, move |c, engine| {
                    if key.is_empty() {
                        c.refuse(engine, "Open a thread to make a page from it.");
                    } else {
                        c.page_from_thread(engine, &key);
                    }
                });
            }
        });
        commands.set_terms(PAGE_FROM_THREAD, &["space", "page", "summary", "summarise"]);
        commands.add(engine, HISTORY_COMMAND, "Show page history", {
            let me = me.clone();
            move |engine| {
                controller::with::<Navigation, _>(engine, |n, engine| {
                    n.open(engine, Route::Space);
                });
                me.run(engine, |c, engine| {
                    if c.page_id.is_empty() || !c.deck_id.is_empty() {
                        c.refuse(engine, "Open a page to see its history.");
                    } else {
                        let page = c.page_id.clone();
                        c.open_history(engine, &page);
                    }
                });
            }
        });
        commands.set_terms(
            HISTORY_COMMAND,
            &["space", "page", "versions", "restore", "undo"],
        );
        commands.add(engine, ASK_AGENT, "Ask an agent about this page", {
            let me = me.clone();
            move |engine| {
                controller::with::<Navigation, _>(engine, |n, engine| {
                    n.open(engine, Route::Space);
                });
                me.run(engine, |c, engine| {
                    if c.page_id.is_empty() {
                        c.refuse(engine, "Open a page to ask an agent about it.");
                    } else if c.page(engine).get("trashed").and_then(JsonValue::as_bool)
                        == Some(true)
                    {
                        c.refuse(engine, "Restore the page to ask an agent about it.");
                    } else {
                        tell(engine, shared(engine).agent_ask_requested.borrow().clone());
                    }
                });
            }
        });
        commands.set_terms(ASK_AGENT, &["space", "page", "agent", "tidy", "@agent"]);
        commands.add(engine, DECK_FROM_PAGE, "Make a deck from page", {
            let me = me.clone();
            move |engine| {
                me.run(engine, |c, engine| {
                    if !c.open || c.page_id.is_empty() || !c.deck_id.is_empty() {
                        c.refuse(engine, "Open a page in a Space to make a deck from it.");
                    } else {
                        let page = c.page_id.clone();
                        c.call(
                            engine,
                            "deck.createFromPage",
                            json!({"pageId": page}),
                            |c, engine, result| {
                                let result = result.as_object().cloned().unwrap_or_default();
                                let deck = obj(&Json::Object(result), "deck");
                                let id = text(&deck, "id");
                                c.await_deck(engine, &id);
                            },
                        );
                    }
                });
            }
        });
        commands.set_terms(DECK_FROM_PAGE, &["space", "slides", "presentation"]);
        commands.add(engine, PRESENT_DECK, "Present deck", {
            let me = me.clone();
            move |engine| {
                me.run(engine, |c, engine| {
                    if !c.open || c.deck_id.is_empty() {
                        c.refuse(engine, "Open a deck in a Space to present it.");
                    } else {
                        let deck = c.deck_id.clone();
                        c.present_deck(engine, &deck);
                    }
                });
            }
        });
        commands.set_terms(
            PRESENT_DECK,
            &["space", "slides", "presentation", "slideshow"],
        );
        commands.add(engine, PICK_FILE, "Edit a project file as a page", {
            let me = me.clone();
            move |engine| {
                me.run(engine, |c, engine| {
                    c.handle(engine, PICK_FILE, &json!({}));
                });
            }
        });
        commands.set_terms(PICK_FILE, &["space", "page", "file", "markdown", "docs"]);
        commands.add(engine, SCAN_FILES, "Scan project for Space files", {
            let me = me.clone();
            move |engine| {
                me.run(engine, |c, engine| {
                    let project = c.project_here(engine);
                    if project.is_empty() {
                        c.refuse(
                            engine,
                            "Add a project on this machine to scan it for Space files.",
                        );
                    } else {
                        c.scan_files(engine, &project, false);
                    }
                });
            }
        });
        commands.set_terms(
            SCAN_FILES,
            &["space", "files", "markdown", "hal-c2.json", "config"],
        );
        let watched = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = at_kind(route, "space");
            // Space publishes the route itself (opening a page from a
            // thread), so this can come while it runs.
            watched.run_after(engine, move |c, engine| c.set_open(engine, open));
        });
        let watched = self.me.clone();
        self.mc.on_ready_changed(Box::new(move |engine, ready| {
            watched.run(engine, move |c, engine| {
                if ready && c.open {
                    c.follow(engine);
                }
                if ready {
                    c.refresh_projects(engine);
                    c.restore_expanded(engine);
                    let wanted: Vec<String> = c.files_wanted.iter().cloned().collect();
                    let environment = c.mc.environment();
                    for project in wanted {
                        c.list_files(engine, &environment.clone(), &project);
                    }
                }
                c.follow_viewers(engine);
            });
        }));
        self.refresh_projects(engine);
        self.restore_expanded(engine);
        let route = self.bridge.published(engine, "route");
        self.set_open(engine, route.is_some_and(|r| at_kind(&r, "space")));
        self.publish(engine);
        self.sync_singleton(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("space.") {
            return false;
        }
        let field = |name: &str| str_of(payload, name);
        let pick = |names: &[&str]| -> Entity {
            let mut out = Entity::new();
            for name in names {
                if let Some(value) = payload.get(name) {
                    out.insert((*name).into(), value.clone());
                }
            }
            out
        };
        let or_null = |mut out: Entity, name: &str| -> Entity {
            if payload.get(name).is_some() {
                let value = str_of(payload, name);
                out.insert(
                    name.into(),
                    if value.is_empty() {
                        Json::Null
                    } else {
                        json!(value)
                    },
                );
            }
            out
        };
        let page_id = if payload.get("pageId").is_some() {
            field("pageId")
        } else {
            self.page_id.clone()
        };
        let deck_id = if payload.get("deckId").is_some() {
            field("deckId")
        } else {
            self.deck_id.clone()
        };
        match action {
            OPEN => {
                self.open_route(engine);
                if payload.get("spaceId").is_some() {
                    self.await_space(engine, &field("spaceId"));
                }
                if payload.get("pageId").is_some() {
                    self.await_page(engine, &page_id);
                }
            }
            "space.select" => {
                self.opening = 0;
                self.select_space(engine, &field("spaceId"));
            }
            "space.pageShown" => {
                self.page_shown = payload
                    .get("shown")
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false);
                self.follow_viewers(engine);
            }
            "space.openFile" => {
                let environment = if payload.get("environmentId").is_some() {
                    field("environmentId")
                } else {
                    self.mc.environment()
                };
                self.open_file(
                    engine,
                    &environment,
                    &field("projectId"),
                    &field("relativePath"),
                );
            }
            "space.files.list" => {
                let environment = self.mc.environment();
                self.list_files(engine, &environment, &field("projectId"));
            }
            PICK_FILE => {
                let project = if payload.get("projectId").is_some() {
                    field("projectId")
                } else {
                    self.project_here(engine)
                };
                if project.is_empty() {
                    self.refuse(
                        engine,
                        "Add a project on this machine to edit its files as pages.",
                    );
                } else {
                    self.open_route(engine);
                    self.picking.clone_from(&project);
                    self.last_picked.clone_from(&project);
                    self.publish(engine);
                    let environment = self.mc.environment();
                    self.list_files(engine, &environment, &project);
                }
            }
            "space.files.pickClose" => {
                if !std::mem::take(&mut self.picking).is_empty() {
                    self.publish(engine);
                }
            }
            "space.files.scan" => {
                let project = if payload.get("projectId").is_some() {
                    field("projectId")
                } else {
                    self.project_here(engine)
                };
                if project.is_empty() {
                    self.refuse(
                        engine,
                        "Add a project on this machine to scan it for Space files.",
                    );
                } else {
                    let replace = payload
                        .get("replace")
                        .and_then(JsonValue::as_bool)
                        .unwrap_or(false);
                    self.scan_files(engine, &project, replace);
                }
            }
            "space.project.setExpanded" => {
                let expanded = payload
                    .get("expanded")
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false);
                let path = field("path");
                if !path.is_empty() {
                    self.projects
                        .set_folder_expanded(&field("projectId"), &path, expanded);
                } else {
                    self.projects.set_expanded(&field("projectId"), expanded);
                }
                self.sync_projects(engine);
            }
            "space.page.showFile" => self.show_file(engine, &page_id),
            "space.selectPage" => {
                self.opening = 0;
                self.select_page(engine, &page_id);
            }
            "space.create" => {
                self.call(
                    engine,
                    "create",
                    Json::Object(pick(&["name"])),
                    |c, engine, result| {
                        let result = result.as_object().cloned().unwrap_or_default();
                        let space = obj(&Json::Object(result), "space");
                        let id = text(&space, "id");
                        c.await_space(engine, &id);
                    },
                );
            }
            "space.rename" => {
                self.call_plain(engine, "rename", Json::Object(pick(&["spaceId", "name"])));
            }
            "space.delete" => {
                self.call_plain(engine, "delete", Json::Object(pick(&["spaceId"])));
            }
            "space.page.create" => {
                let mut create = or_null(pick(&["spaceId"]), "parentPageId");
                let title = field("title").trim().to_owned();
                create.insert(
                    "title".into(),
                    json!(if title.is_empty() {
                        "Untitled".into()
                    } else {
                        title.clone()
                    }),
                );
                let link_from = if payload.get("link").and_then(JsonValue::as_bool) == Some(true) {
                    field("parentPageId")
                } else {
                    String::new()
                };
                self.call(engine, "page.create", Json::Object(create), move |c, engine, result| {
                    let result = result.as_object().cloned().unwrap_or_default();
                    let page = obj(&Json::Object(result), "page");
                    let id = text(&page, "id");
                    if !link_from.is_empty() && !id.is_empty() {
                        c.call_plain(
                            engine,
                            "block.insert",
                            json!({
                                "pageId": link_from,
                                "kind": "subpage_link",
                                "text": if title.is_empty() { "Untitled".into() } else { title.clone() },
                                "linkedPageId": id,
                            }),
                        );
                    }
                    let id = text(&page, "id");
                    c.await_page(engine, &id);
                });
            }
            "space.page.rename" => {
                self.call_plain(
                    engine,
                    "page.rename",
                    json!({"pageId": page_id, "title": field("title")}),
                );
            }
            "space.page.move" => {
                let mut moved = or_null(pick(&["spaceId"]), "parentPageId");
                moved.insert("pageId".into(), json!(page_id));
                if !moved.contains_key("parentPageId") {
                    moved.insert("parentPageId".into(), Json::Null);
                }
                self.call_plain(engine, "page.move", Json::Object(moved));
            }
            "space.page.trash" => {
                self.call_plain(engine, "page.trash", json!({"pageId": page_id}));
            }
            "space.page.restore" => {
                self.call_plain(engine, "page.restore", json!({"pageId": page_id}));
            }
            "space.page.delete" => {
                self.call_plain(engine, "page.delete", json!({"pageId": page_id}));
            }
            "space.page.schedule.set" => {
                let mut set = pick(&["spaceId", "instruction", "cadence"]);
                set.insert("pageId".into(), json!(page_id));
                self.call_plain(engine, "page.schedule.set", Json::Object(set));
            }
            "space.page.schedule.setEnabled" => {
                let mut set = pick(&["spaceId", "enabled"]);
                set.insert("pageId".into(), json!(page_id));
                self.call_plain(engine, "page.schedule.setEnabled", Json::Object(set));
            }
            "space.page.schedule.runNow" => {
                self.call_plain(engine, "page.schedule.runNow", json!({"pageId": page_id}));
            }
            "space.page.schedule.remove" => {
                self.call_plain(engine, "page.schedule.remove", json!({"pageId": page_id}));
            }
            "space.page.copyMarkdown" => {
                let bridge = self.bridge;
                self.export_page(
                    engine,
                    &page_id,
                    Rc::new(move |_c, engine, markdown| {
                        bridge.copy_to_clipboard(engine, &markdown);
                        toast(engine, "success", "Page copied as Markdown", "");
                    }),
                );
            }
            "space.page.publish" => {
                let mut publish = json!({"pageId": page_id});
                let reached = self.mc.origin().unwrap_or_default();
                if payload.get("tailscale").and_then(JsonValue::as_bool) == Some(true) {
                    publish["tailscale"] = json!(true);
                } else if !this_machine::loopback_host(&this_machine::origin_host(&reached)) {
                    publish["baseUrl"] = json!(reached);
                }
                self.call_plain(engine, "page.publish", publish);
            }
            "space.page.unpublish" => {
                self.call_plain(engine, "page.unpublish", json!({"pageId": page_id}));
            }
            "space.page.copySiteLink" => {
                let url = text(&self.site_of(&page_id), "url");
                if url.is_empty() {
                    self.refuse(engine, "This page is not published.");
                } else {
                    self.bridge.copy_to_clipboard(engine, &url);
                    toast(engine, "success", "Site link copied", "");
                }
            }
            "space.page.saveMarkdown" => {
                let path = percent_decode(
                    field("url")
                        .strip_prefix("file://")
                        .map(|rest| rest.strip_prefix("localhost").unwrap_or(rest))
                        .unwrap_or(""),
                );
                self.export_page(
                    engine,
                    &page_id,
                    Rc::new(move |c, engine, markdown| {
                        if path.is_empty() || std::fs::write(&path, markdown.as_bytes()).is_err() {
                            let message = format!("Could not save the page to {path}.");
                            c.refuse(engine, &message);
                        } else {
                            toast(engine, "success", "Page saved as Markdown", &path);
                        }
                    }),
                );
            }
            "space.page.importMarkdown" => {
                self.import_markdown(engine, &field("markdown"));
            }
            "space.page.importFile" => {
                let path = crate::bridge::local_path(&field("url")).unwrap_or_default();
                match std::fs::read_to_string(&path) {
                    Ok(markdown) if !path.is_empty() => self.import_markdown(engine, &markdown),
                    _ => {
                        let message = format!("Could not read {path}.");
                        self.refuse(engine, &message);
                    }
                }
            }
            PAGE_FROM_THREAD => self.page_from_thread(engine, &field("threadKey")),
            "space.block.insert" => {
                let mut insert = or_null(
                    pick(&[
                        "spaceId",
                        "kind",
                        "text",
                        "checked",
                        "linkedPageId",
                        "imageId",
                    ]),
                    "afterBlockId",
                );
                insert.insert("pageId".into(), json!(page_id));
                self.call_plain(engine, "block.insert", Json::Object(insert));
            }
            "space.block.update" | "space.block.setChecked" => {
                let tick = action == "space.block.setChecked";
                let block_id = field("blockId");
                let name = if tick { "checked" } else { "text" };
                let value = payload.get(name).cloned().unwrap_or(Json::Null);
                let token = self.pend(engine, &block_id, name, value.clone());
                let mut body = Entity::new();
                body.insert("blockId".into(), json!(block_id));
                body.insert(name.into(), value);
                self.call_full(
                    engine,
                    if tick {
                        "block.setChecked"
                    } else {
                        "block.update"
                    },
                    Json::Object(body),
                    move |c, engine, result| {
                        let block = obj(&result, "block");
                        c.settle(engine, token, Some(block));
                    },
                    move |c, engine, _detail| {
                        c.settle(engine, token, None);
                        String::new()
                    },
                );
            }
            "space.block.move" => {
                let moved = or_null(pick(&["spaceId", "blockId"]), "afterBlockId");
                self.call_plain(engine, "block.move", Json::Object(moved));
            }
            "space.block.visualize" => {
                let mut ask = or_null(pick(&["spaceId", "request", "blockId"]), "afterBlockId");
                ask.insert("pageId".into(), json!(page_id));
                self.drawing += 1;
                self.publish(engine);
                self.call_full(
                    engine,
                    "block.visualize",
                    Json::Object(ask),
                    |c, engine, _| {
                        c.drawing = (c.drawing - 1).max(0);
                        c.publish(engine);
                    },
                    |c, engine, _| {
                        c.drawing = (c.drawing - 1).max(0);
                        c.publish(engine);
                        String::new()
                    },
                );
            }
            "space.block.delete" => {
                self.call_plain(
                    engine,
                    "block.delete",
                    Json::Object(pick(&["spaceId", "blockId"])),
                );
            }
            "space.comment.add" => {
                let mut add = pick(&["spaceId", "blockId", "body"]);
                add.insert("pageId".into(), json!(page_id));
                self.call_plain(engine, "comment.add", Json::Object(add));
            }
            "space.comment.resolve" => {
                self.call_plain(
                    engine,
                    "comment.resolve",
                    Json::Object(pick(&["spaceId", "commentId"])),
                );
            }
            "space.comment.reopen" => {
                self.call_plain(
                    engine,
                    "comment.reopen",
                    Json::Object(pick(&["spaceId", "commentId"])),
                );
            }
            HISTORY_COMMAND => self.open_history(engine, &page_id.clone()),
            "space.history.close" => {
                self.history_refresh.stop(engine);
                self.history.close();
                self.sync_history(engine, false);
            }
            "space.agent.ask" => {
                let mut ask = Entity::new();
                ask.insert("request".into(), json!(field("request")));
                self.ask_agent(engine, &page_id, ask, None);
            }
            "space.agent.stop" => {
                self.call_plain(engine, "page.stopAgent", json!({"pageId": page_id}));
            }
            "space.agent.dismiss" => {
                self.call_plain(engine, "page.dismissAgent", json!({"pageId": page_id}));
            }
            "space.agent.openThread" => {
                let agent = self.agent(engine);
                let thread = text(&agent, "threadId");
                let key = format!("{}:{thread}", self.mc.environment());
                let held = store::with(engine, |s| s.thread(&key).is_some());
                if !held {
                    toast(engine, "info", "The agent's thread is not available.", "");
                } else {
                    self.open_thread(engine, &key);
                }
            }
            "space.history.more" => {
                let next = self.history.more();
                self.sync_history(engine, false);
                self.ask_history(engine, next);
            }
            "space.history.read" => {
                let version = payload
                    .get("version")
                    .and_then(JsonValue::as_i64)
                    .unwrap_or(0);
                let request: Request = self.history.read(version);
                self.sync_history(engine, false);
                let token = request.token;
                self.call_full(
                    engine,
                    "page.version",
                    request.payload,
                    move |c, engine, result| {
                        let result = result.as_object().cloned().unwrap_or_default();
                        c.history.receive_version(token, &result);
                        c.sync_history(engine, true);
                    },
                    move |c, engine, _detail| {
                        c.history.failed_version(token);
                        c.sync_history(engine, false);
                        String::new()
                    },
                );
            }
            "space.history.back" => {
                self.history.stop_reading();
                self.sync_history(engine, true);
            }
            "space.history.restore" => {
                let restore = json!({
                    "pageId": self.history.page_id(),
                    "version": payload.get("version").and_then(JsonValue::as_i64).unwrap_or(0),
                });
                self.call(engine, "page.restoreVersion", restore, |c, engine, _| {
                    c.history.stop_reading();
                    c.history_refresh.stop(engine);
                    let next = c.history.refresh();
                    c.sync_history(engine, true);
                    c.ask_history(engine, next);
                    toast(engine, "success", "Version restored", "");
                });
            }
            "space.selectDeck" => {
                self.opening = 0;
                self.select_deck(engine, &deck_id);
            }
            "space.deck.create" => {
                self.call(
                    engine,
                    "deck.create",
                    Json::Object(pick(&["spaceId", "title"])),
                    |c, engine, result| {
                        let result = result.as_object().cloned().unwrap_or_default();
                        let deck = obj(&Json::Object(result), "deck");
                        let id = text(&deck, "id");
                        c.await_deck(engine, &id);
                    },
                );
            }
            "space.deck.createFromPage" => {
                self.call(
                    engine,
                    "deck.createFromPage",
                    json!({"pageId": page_id}),
                    |c, engine, result| {
                        let result = result.as_object().cloned().unwrap_or_default();
                        let deck = obj(&Json::Object(result), "deck");
                        let id = text(&deck, "id");
                        c.await_deck(engine, &id);
                    },
                );
            }
            "space.deck.rename" => {
                let mut rename = pick(&["spaceId", "title"]);
                rename.insert("deckId".into(), json!(deck_id));
                self.call_plain(engine, "deck.rename", Json::Object(rename));
            }
            "space.deck.trash" => {
                self.call_plain(engine, "deck.trash", json!({"deckId": deck_id}));
            }
            "space.deck.restore" => {
                self.call_plain(engine, "deck.restore", json!({"deckId": deck_id}));
            }
            "space.deck.delete" => {
                self.call_plain(engine, "deck.delete", json!({"deckId": deck_id}));
            }
            "space.slide.insert" => {
                let mut insert = or_null(pick(&["spaceId", "title", "body"]), "afterSlideId");
                insert.insert("deckId".into(), json!(deck_id));
                self.call_plain(engine, "slide.insert", Json::Object(insert));
            }
            "space.slide.update" => {
                self.call_plain(
                    engine,
                    "slide.update",
                    Json::Object(pick(&["spaceId", "slideId", "title", "body"])),
                );
            }
            "space.slide.move" => {
                let moved = or_null(pick(&["spaceId", "slideId"]), "afterSlideId");
                self.call_plain(engine, "slide.move", Json::Object(moved));
            }
            "space.slide.delete" => {
                self.call_plain(
                    engine,
                    "slide.delete",
                    Json::Object(pick(&["spaceId", "slideId"])),
                );
            }
            "space.deck.present" => self.present_deck(engine, &deck_id.clone()),
            "space.deck.step" => {
                let by = payload.get("by").and_then(JsonValue::as_i64).unwrap_or(0) as i32;
                self.step(engine, by);
            }
            "space.deck.leave" => self.leave(engine),
            "space.images.show" => {
                let shown = payload
                    .get("shown")
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false);
                self.set_images_shown(engine, shown);
            }
            "space.image.providers" => {
                self.call(engine, "image.providers", json!({}), |c, engine, result| {
                    c.image_providers = result.as_object().cloned().unwrap_or_default();
                    c.publish(engine);
                    tell(engine, shared(engine).image_offer_changed.borrow().clone());
                });
            }
            "space.image.addFile" => self.add_image_file(engine, &field("url")),
            "space.image.generate" => {
                let selection = payload
                    .get("modelSelection")
                    .and_then(JsonValue::as_object)
                    .cloned()
                    .unwrap_or_default();
                self.generate_image(engine, &field("prompt"), selection, None);
            }
            "space.image.trash" | "space.image.restore" | "space.image.delete" => {
                let method = &action["space.".len()..];
                self.call_plain(engine, method, Json::Object(pick(&["spaceId", "imageId"])));
            }
            _ => return false,
        }
        true
    }
}
