//! desktop-qt's PullRequestLinkPreviews and PullRequestThreadLinks: what a
//! pull request link in the conversation shows and where it opens, and the
//! threads that work on the pull request a review shows.
//!
//! [`LinkPreviews`] (`Panel.linkPreviews`) claims a link that names a pull
//! request (or GitHub's issue page for a `#123`, which may be one) on a host a
//! project reads. Hovering it reads `pullRequests.preview` for its card;
//! following it opens the review beside the thread once the MC read it, and
//! the browser otherwise. A link it does not claim opens as any address does.
//!
//! [`ThreadLinks`] (the review's `threads`) counts the threads that link the
//! pull request (`pullRequests.linkedThreads`), links or unlinks it here, and
//! offers the environment's active threads to link it to.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ObjectId, QmlObject, QmlValue, Value, qml_impl,
};
use serde_json::{Map, json};

use super::pull_requests::{self, Target};
use super::time::{Clock, parse_iso, relative_time};
use crate::json::Json;
use crate::mc::Mc;
use crate::store;

type Open = Rc<dyn Fn(&Engine, &str)>;
type Notify = Rc<dyn Fn(&Engine, &str, &str, &str)>;

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or("")
}

fn warn(engine: &Engine, what: &str, result: Result<(), EngineError>) {
    if let Err(e) = result {
        engine.log(ljos::prelude::LogLevel::Warning, what, e.to_string());
    }
}

/// `host/repository#number`.
fn key_of(target: &Target) -> String {
    format!("{}/{}#{}", target.host, target.repository, target.number)
}

// --- Link previews -------------------------------------------------------------

#[derive(Clone, Debug, Default)]
struct Entry {
    pending: bool,
    preview: Option<Json>,
}

#[derive(Default)]
struct Previews {
    environment: String,
    projects: Vec<Map<String, Json>>,
    epoch: u64,
    entries: HashMap<String, Entry>,
    following: String,
    address: String,
    clock: Clock,
}

impl Previews {
    /// The pull request `url` names, and the project that reads it.
    fn claim(&self, url: &str) -> Option<(Target, String)> {
        if self.environment.is_empty() {
            return None;
        }
        let target = pull_requests::claim(url)?;
        let projects: Vec<&Map<String, Json>> = self.projects.iter().collect();
        let project = pull_requests::project_for(&projects, &target, true);
        (!project.is_empty()).then_some((target, project))
    }

    fn status(&self) -> &'static str {
        match self.entries.get(&self.address) {
            _ if self.address.is_empty() => "",
            None => "",
            Some(entry) if entry.pending => "loading",
            Some(entry) if entry.preview.is_some() => "ready",
            Some(_) => "failed",
        }
    }

    /// As the web's PullRequestLinkPreview wrote it: "Name (@login)", the
    /// login when the name says nothing more, and "ghost" for a deleted
    /// account.
    fn card(&self) -> Json {
        let Some(preview) = self
            .entries
            .get(&self.address)
            .filter(|_| !self.address.is_empty())
            .and_then(|e| e.preview.as_ref())
        else {
            return json!({});
        };
        let state = text(preview, "state");
        let draft = preview
            .get("isDraft")
            .and_then(Json::as_bool)
            .unwrap_or(false);
        let label = match state {
            "merged" => "Merged",
            "closed" => "Closed",
            _ if draft => "Draft",
            _ => "Open",
        };
        let author = preview.get("author").cloned().unwrap_or(Json::Null);
        let (login, name) = (text(&author, "login"), text(&author, "name"));
        let author = if login.is_empty() {
            "ghost".to_owned()
        } else if !name.is_empty() && name != login {
            format!("{name} (@{login})")
        } else {
            login.to_owned()
        };
        let opened = parse_iso(text(preview, "createdAt"), self.clock.zone)
            .map(|at| relative_time(Some(at.min(self.clock.now())), &self.clock))
            .unwrap_or_default();
        json!({
            "repository": text(preview, "repository"),
            "number": preview.get("number").and_then(Json::as_i64).unwrap_or(0),
            "state": if draft && state == "open" { "draft" } else { state },
            "stateLabel": label,
            "title": text(preview, "title"),
            "author": author,
            "opened": opened,
        })
    }
}

/// What a step of the previews leaves to do once they are free.
enum Then {
    Read(String),
    Settle(String),
    Browser(String),
    Ordinary(String),
}

/// The pull request links of the conversation: `Panel.linkPreviews`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "PullRequestLinkPreviews", uncreatable)]
pub struct LinkPreviews {
    /// The claimed link under the pointer, else empty.
    #[qml(readonly, notify)]
    address: Atom,
    /// "", "loading", "ready" or "failed", for `address`.
    #[qml(readonly, notify)]
    status: Atom,
    /// {repository, number, state, stateLabel, title, author, opened} once
    /// `address` is read; {} otherwise.
    #[qml(readonly, notify)]
    card: Value,
    #[qml(skip)]
    inner: Rc<PreviewsInner>,
}

struct PreviewsInner {
    state: RefCell<Previews>,
    mc: Rc<dyn Mc>,
    review: Open,
    browser: Open,
    ordinary: Open,
}

impl std::fmt::Debug for PreviewsInner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PullRequestLinkPreviews")
            .finish_non_exhaustive()
    }
}

fn previews_of(engine: &Engine, obj: ObjectId) -> Option<Rc<PreviewsInner>> {
    engine
        .with::<LinkPreviews, _>(obj, |p| p.inner.clone())
        .ok()
}

impl LinkPreviews {
    /// The previews owned by `owner`, reading on `mc`. `review` opens a
    /// pull request's review by its key, `browser` hands a page to the
    /// browser and `ordinary` opens a link they do not claim.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
        review: impl Fn(&Engine, &str) + 'static,
        browser: impl Fn(&Engine, &str) + 'static,
        ordinary: impl Fn(&Engine, &str) + 'static,
    ) -> Result<ObjectId, EngineError> {
        let inner = Rc::new(PreviewsInner {
            state: RefCell::new(Previews::default()),
            mc,
            review: Rc::new(review),
            browser: Rc::new(browser),
            ordinary: Rc::new(ordinary),
        });
        let object = LinkPreviews {
            address: Atom::new(""),
            status: Atom::new(""),
            card: Value::Undefined,
            inner,
        };
        let obj = engine.create_native(object, owner)?;
        tell_previews(engine, obj);
        Ok(obj)
    }

    /// Claims links of `projects` of `environment` (empty: none).
    pub fn set_context(
        engine: &Engine,
        obj: ObjectId,
        environment: &str,
        projects: Vec<Map<String, Json>>,
    ) {
        let Some(inner) = previews_of(engine, obj) else {
            return;
        };
        let unhover = {
            let mut p = inner.state.borrow_mut();
            p.projects = projects;
            if p.environment == environment {
                // A project gone may leave the hovered link an ordinary one.
                !p.address.is_empty() && p.claim(&p.address).is_none()
            } else {
                p.environment = environment.to_owned();
                p.epoch += 1;
                p.entries.clear();
                p.following.clear();
                p.address.clear();
                false
            }
        };
        if unhover {
            Self::hover(engine, obj, "");
        }
        tell_previews(engine, obj);
    }

    /// The card reads times on `clock`.
    pub fn set_clock(engine: &Engine, obj: ObjectId, clock: Clock) {
        if let Some(inner) = previews_of(engine, obj) {
            inner.state.borrow_mut().clock = clock;
            tell_previews(engine, obj);
        }
    }

    pub fn claims(engine: &Engine, obj: ObjectId, url: &str) -> bool {
        previews_of(engine, obj).is_some_and(|i| i.state.borrow().claim(url).is_some())
    }

    /// The pointer rests on `url` (empty: on no link).
    pub fn hover(engine: &Engine, obj: ObjectId, url: &str) {
        let Some(inner) = previews_of(engine, obj) else {
            return;
        };
        let read = {
            let mut p = inner.state.borrow_mut();
            let address = if p.claim(url).is_some() { url } else { "" };
            let read = !address.is_empty()
                && p.entries
                    .get(address)
                    .is_none_or(|e| !e.pending && e.preview.is_none());
            p.address = address.to_owned();
            read
        };
        if read {
            run(engine, obj, &inner, Then::Read(url.to_owned()));
        }
        tell_previews(engine, obj);
    }

    /// Opens `url`: in the browser when `external`.
    pub fn follow(engine: &Engine, obj: ObjectId, url: &str, external: bool) {
        let Some(inner) = previews_of(engine, obj) else {
            return;
        };
        let then = {
            let mut p = inner.state.borrow_mut();
            p.following.clear();
            if external {
                vec![Then::Browser(url.to_owned())]
            } else if p.claim(url).is_none() {
                vec![Then::Ordinary(url.to_owned())]
            } else {
                // A read that failed on hover may succeed now.
                let entry = p.entries.get(url).cloned();
                let mut then = Vec::new();
                if entry
                    .as_ref()
                    .is_none_or(|e| !e.pending && e.preview.is_none())
                {
                    then.push(Then::Read(url.to_owned()));
                }
                p.following = url.to_owned();
                if entry.is_some_and(|e| !e.pending) && then.is_empty() {
                    then.push(Then::Settle(url.to_owned()));
                }
                then
            }
        };
        for then in then {
            run(engine, obj, &inner, then);
        }
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &Rc<PreviewsInner>, then: Then) {
    match then {
        Then::Browser(url) => (inner.browser)(engine, &url),
        Then::Ordinary(url) => (inner.ordinary)(engine, &url),
        Then::Settle(url) => {
            let review = {
                let mut p = inner.state.borrow_mut();
                p.following.clear();
                let read = p.entries.get(&url).is_some_and(|e| e.preview.is_some());
                p.claim(&url)
                    .filter(|_| read)
                    .map(|(target, _)| key_of(&target))
            };
            match review {
                Some(key) => (inner.review)(engine, &key),
                None => (inner.browser)(engine, &url),
            }
        }
        Then::Read(url) => {
            let asked = {
                let mut p = inner.state.borrow_mut();
                let Some((target, project)) = p.claim(&url) else {
                    return;
                };
                p.entries.insert(
                    url.clone(),
                    Entry {
                        pending: true,
                        preview: None,
                    },
                );
                (p.environment.clone(), p.epoch, target, project)
            };
            tell_previews(engine, obj);
            let (environment, epoch, target, project) = asked;
            let payload = json!({
                "projectId": project,
                "host": target.host,
                "repository": target.repository,
                "number": target.number,
            });
            let weak = Rc::downgrade(inner);
            inner.mc.call(
                &environment,
                "pullRequests.preview",
                payload,
                Box::new(move |engine, result| {
                    let Some(inner) = weak.upgrade() else {
                        return;
                    };
                    let settle = {
                        let mut p = inner.state.borrow_mut();
                        if p.epoch != epoch {
                            return;
                        }
                        let Some(entry) = p.entries.get_mut(&url).filter(|e| e.pending) else {
                            return;
                        };
                        entry.pending = false;
                        entry.preview = result.ok().filter(Json::is_object);
                        p.following == url
                    };
                    tell_previews(engine, obj);
                    if settle {
                        run(engine, obj, &inner, Then::Settle(url));
                    }
                }),
            );
        }
    }
}

fn tell_previews(engine: &Engine, obj: ObjectId) {
    let Some(inner) = previews_of(engine, obj) else {
        return;
    };
    let (address, status, card) = {
        let p = inner.state.borrow();
        (Atom::new(&p.address), Atom::new(p.status()), p.card())
    };
    let result = engine
        .set_internal(obj, LinkPreviews::ADDRESS, address)
        .and_then(|()| engine.set_internal(obj, LinkPreviews::STATUS, status))
        .and_then(|()| engine.set_internal(obj, LinkPreviews::CARD, card.to_value()));
    warn(engine, "PullRequestLinkPreviews", result);
}

#[qml_impl]
impl LinkPreviews {
    /// Whether `url` names a pull request a project here reads.
    #[qml(invokable, name = "claims")]
    fn claims_link(cx: &Cx, url: Atom) -> bool {
        LinkPreviews::claims(cx.engine, cx.this, &url)
    }

    #[qml(invokable, name = "hover")]
    fn hover_link(cx: &Cx, url: Atom) {
        LinkPreviews::hover(cx.engine, cx.this, &url);
    }

    #[qml(invokable, name = "follow")]
    fn follow_link(cx: &Cx, url: Atom, external: Option<bool>) {
        LinkPreviews::follow(cx.engine, cx.this, &url, external.unwrap_or(false));
    }
}

// --- Thread links --------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Shown {
    environment: String,
    thread: String,
    host: String,
    repository: String,
    number: i64,
    url: String,
}

#[derive(Debug, Default)]
struct Links {
    shown: Shown,
    generation: u64,
    /// The threads that link it, or -1 before the MC said.
    count: i64,
    pending: bool,
    picker_open: bool,
    query: String,
}

/// The threads working on the pull request the review shows: its
/// `threads`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "PullRequestThreadLinks", uncreatable)]
pub struct ThreadLinks {
    /// Whether the environment links pull requests to threads.
    #[qml(readonly, notify)]
    available: bool,
    #[qml(readonly, notify)]
    count: i32,
    /// "Linked from 2 threads", or "Linked threads" before it is known.
    #[qml(readonly, notify)]
    label: Atom,
    /// A link or unlink is on its way.
    #[qml(readonly, notify)]
    pending: bool,
    #[qml(readonly, notify)]
    linked_here: bool,
    /// "Unlink from this thread", "Link to this thread" or "Link to thread".
    #[qml(readonly, notify)]
    menu_label: Atom,
    /// Whether the thread picker shows; QML opens and closes it.
    #[qml(notify)]
    picker_open: bool,
    /// What the picker searches; QML writes it as the user types.
    #[qml(notify)]
    query: Atom,
    /// The picker's threads, newest first: [{id, title, project, linked}].
    #[qml(readonly, notify)]
    candidates: Value,
    #[qml(skip)]
    inner: Rc<LinksInner>,
}

struct LinksInner {
    state: RefCell<Links>,
    mc: Rc<dyn Mc>,
    notify: Notify,
    search: Open,
}

impl std::fmt::Debug for LinksInner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PullRequestThreadLinks")
            .finish_non_exhaustive()
    }
}

fn links_of(engine: &Engine, obj: ObjectId) -> Option<Rc<LinksInner>> {
    engine.with::<ThreadLinks, _>(obj, |p| p.inner.clone()).ok()
}

/// Whether thread `id` of `shown`'s environment links its pull request; a
/// dismissed stack layer is the thread's no more.
fn links(store: &store::ShellStore, shown: &Shown, id: &str) -> bool {
    if id.is_empty() || shown.number <= 0 {
        return false;
    }
    let key = format!("{}:{id}", shown.environment);
    store
        .thread_row(&key)
        .and_then(|row| row.get("pullRequests"))
        .and_then(Json::as_array)
        .into_iter()
        .flatten()
        .any(|link| {
            text(link, "source") != "stack-dismissed"
                && link.get("number").and_then(Json::as_i64) == Some(shown.number)
                && text(link, "repository").eq_ignore_ascii_case(&shown.repository)
                && text(link, "host").eq_ignore_ascii_case(&shown.host)
        })
}

/// What [`ThreadLinks`] shows, read from the store.
#[derive(Debug, Default, PartialEq)]
pub struct LinksView {
    pub available: bool,
    pub count: i64,
    pub label: String,
    pub pending: bool,
    pub linked_here: bool,
    pub menu_label: String,
    pub picker_open: bool,
    pub query: String,
    pub candidates: Vec<Json>,
}

fn view(store: &store::ShellStore, l: &Links) -> LinksView {
    let shown = &l.shown;
    let available = shown.number > 0 && store.supports(&shown.environment, "threadPullRequests");
    let label = match l.count {
        ..=0 => "Linked threads".to_owned(),
        1 => "Linked from 1 thread".to_owned(),
        n => format!("Linked from {n} threads"),
    };
    let linked_here = links(store, shown, &shown.thread);
    let menu_label = if linked_here {
        "Unlink from this thread"
    } else if shown.thread.is_empty() {
        "Link to thread"
    } else {
        "Link to this thread"
    };
    let mut candidates = Vec::new();
    if l.picker_open {
        let projects: HashMap<String, String> = store
            .project_rows(&shown.environment)
            .into_iter()
            .map(|p| {
                let field = |k: &str| p.get(k).and_then(Json::as_str).unwrap_or("").to_owned();
                (field("id"), field("title"))
            })
            .collect();
        let search = l.query.trim().to_lowercase();
        let mut threads: Vec<_> = store
            .threads()
            .into_iter()
            .filter(|t| t.environment_id == shown.environment && t.archived_at.is_none())
            .filter(|t| {
                let project = projects.get(&t.project_id).map_or("", String::as_str);
                format!("{} {project}", t.title)
                    .to_lowercase()
                    .contains(&search)
            })
            .collect();
        threads.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        candidates = threads
            .into_iter()
            .map(|t| {
                json!({
                    "id": t.id,
                    "title": if t.title.is_empty() { "Untitled thread" } else { &t.title },
                    "project": projects.get(&t.project_id).cloned().unwrap_or_default(),
                    "linked": links(store, shown, &t.id),
                })
            })
            .collect();
    }
    LinksView {
        available,
        count: l.count,
        label,
        pending: l.pending,
        linked_here,
        menu_label: menu_label.to_owned(),
        picker_open: l.picker_open,
        query: l.query.clone(),
        candidates,
    }
}

impl ThreadLinks {
    /// The links owned by `owner`, asking `mc`; `notify` raises a toast and
    /// `search` searches the threads for an address.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
        notify: impl Fn(&Engine, &str, &str, &str) + 'static,
        search: impl Fn(&Engine, &str) + 'static,
    ) -> Result<ObjectId, EngineError> {
        let inner = Rc::new(LinksInner {
            state: RefCell::new(Links {
                count: -1,
                ..Links::default()
            }),
            mc,
            notify: Rc::new(notify),
            search: Rc::new(search),
        });
        let object = ThreadLinks {
            available: false,
            count: -1,
            label: Atom::new("Linked threads"),
            pending: false,
            linked_here: false,
            menu_label: Atom::new("Link to thread"),
            picker_open: false,
            query: Atom::new(""),
            candidates: Value::Undefined,
            inner,
        };
        let obj = engine.create_native(object, owner)?;
        // QML opens and closes the picker, and types its search.
        engine.connect_by_name(obj, "pickerOpenChanged", move |engine, _| {
            if let Ok(open) = engine.get(obj, ThreadLinks::PICKER_OPEN) {
                ThreadLinks::set_picker_open(engine, obj, open);
            }
        })?;
        engine.connect_by_name(obj, "queryChanged", move |engine, _| {
            if let Ok(query) = engine.get(obj, ThreadLinks::QUERY) {
                ThreadLinks::set_query(engine, obj, &query);
            }
        })?;
        tell_links(engine, obj);
        Ok(obj)
    }

    /// Points `obj` at pull request `target` (number 0: none), from thread
    /// `thread` of `environment`.
    pub fn set_target(
        engine: &Engine,
        obj: ObjectId,
        environment: &str,
        thread: &str,
        target: Target,
    ) {
        let Some(inner) = links_of(engine, obj) else {
            return;
        };
        let target = Shown {
            environment: environment.to_owned(),
            thread: thread.to_owned(),
            host: target.host,
            repository: target.repository,
            number: target.number,
            url: target.url,
        };
        let other = {
            let mut l = inner.state.borrow_mut();
            let s = &l.shown;
            let other = s.environment != target.environment
                || s.host != target.host
                || s.repository != target.repository
                || s.number != target.number;
            l.shown = target;
            if other {
                l.generation += 1;
                l.count = -1;
                l.pending = false;
                l.picker_open = false;
                l.query.clear();
            }
            other
        };
        // Whether this thread or a picker's thread links it follows their
        // rows, which come with each retarget.
        tell_links(engine, obj);
        if other {
            refresh(engine, obj, &inner);
        }
    }

    pub fn clear(engine: &Engine, obj: ObjectId) {
        Self::set_target(engine, obj, "", "", Target::default());
    }

    /// What `obj` shows now.
    pub fn view(engine: &Engine, obj: ObjectId) -> Option<LinksView> {
        let inner = links_of(engine, obj)?;
        let l = inner.state.borrow();
        Some(store::with(engine, |s| view(s, &l)))
    }

    pub fn set_picker_open(engine: &Engine, obj: ObjectId, open: bool) {
        let Some(inner) = links_of(engine, obj) else {
            return;
        };
        let available = Self::view(engine, obj).is_some_and(|v| v.available);
        {
            let mut l = inner.state.borrow_mut();
            if open != l.picker_open && (!open || available) {
                l.picker_open = open;
                l.query.clear();
            }
        }
        tell_links(engine, obj);
    }

    pub fn set_query(engine: &Engine, obj: ObjectId, query: &str) {
        let Some(inner) = links_of(engine, obj) else {
            return;
        };
        let changed = {
            let mut l = inner.state.borrow_mut();
            let changed = l.query != query;
            l.query = query.to_owned();
            changed
        };
        if changed {
            tell_links(engine, obj);
        }
    }

    /// Searches the threads for the pull request's page.
    pub fn search(engine: &Engine, obj: ObjectId) {
        let Some(inner) = links_of(engine, obj) else {
            return;
        };
        let url = inner.state.borrow().shown.url.clone();
        if !url.is_empty() {
            (inner.search)(engine, &url);
        }
    }

    /// Links the pull request to the thread shown, or unlinks it; away from
    /// a thread, opens the picker.
    pub fn toggle_here(engine: &Engine, obj: ObjectId) {
        let Some(inner) = links_of(engine, obj) else {
            return;
        };
        let thread = inner.state.borrow().shown.thread.clone();
        if thread.is_empty() {
            return Self::set_picker_open(engine, obj, true);
        }
        let linked = Self::view(engine, obj).is_some_and(|v| v.linked_here);
        change(engine, obj, &inner, &thread, !linked);
    }

    /// Links the pull request to thread `id`, unless it is already.
    pub fn choose(engine: &Engine, obj: ObjectId, id: &str) {
        let Some(inner) = links_of(engine, obj) else {
            return;
        };
        let linked = {
            let l = inner.state.borrow();
            store::with(engine, |s| links(s, &l.shown, id))
        };
        if !linked {
            change(engine, obj, &inner, id, true);
        }
    }
}

fn refresh(engine: &Engine, obj: ObjectId, inner: &Rc<LinksInner>) {
    let (shown, generation, available) = {
        let l = inner.state.borrow();
        let available = store::with(engine, |s| view(s, &l).available);
        (l.shown.clone(), l.generation, available)
    };
    if !available {
        return;
    }
    let weak = Rc::downgrade(inner);
    inner.mc.call(
        &shown.environment,
        "pullRequests.linkedThreads",
        json!({"host": shown.host, "repository": shown.repository, "number": shown.number}),
        Box::new(move |engine, result| {
            let Some(inner) = weak.upgrade() else {
                return;
            };
            // A failed read keeps the last count, as the web's polling does.
            let Ok(result) = result else {
                return;
            };
            {
                let mut l = inner.state.borrow_mut();
                if l.generation != generation {
                    return;
                }
                l.count = result
                    .get("threads")
                    .and_then(Json::as_array)
                    .map_or(0, |t| t.len() as i64);
            }
            tell_links(engine, obj);
        }),
    );
}

fn change(engine: &Engine, obj: ObjectId, inner: &Rc<LinksInner>, thread: &str, link: bool) {
    let (shown, generation) = {
        let mut l = inner.state.borrow_mut();
        let available = store::with(engine, |s| view(s, &l).available);
        if !available || l.pending || thread.is_empty() || l.shown.url.is_empty() {
            return;
        }
        l.pending = true;
        (l.shown.clone(), l.generation)
    };
    tell_links(engine, obj);
    let mut command = json!({
        "type": if link { "thread.pull-request.link" } else { "thread.pull-request.unlink" },
        "threadId": thread,
        "host": shown.host,
        "repository": shown.repository,
        "number": shown.number,
    });
    if link {
        command["url"] = json!(shown.url);
        command["source"] = json!("manual");
    }
    let weak = Rc::downgrade(inner);
    inner.mc.dispatch_command(
        &shown.environment,
        command,
        Box::new(move |engine, result| {
            let Some(inner) = weak.upgrade() else {
                return;
            };
            {
                let mut l = inner.state.borrow_mut();
                if l.generation != generation {
                    return;
                }
                l.pending = false;
                if result.is_ok() {
                    l.picker_open = false;
                    l.query.clear();
                }
            }
            match result {
                Err(error) => {
                    let title = if link {
                        "Could not link the pull request"
                    } else {
                        "Could not unlink the pull request"
                    };
                    (inner.notify)(engine, "error", title, &error.message);
                    tell_links(engine, obj);
                }
                Ok(_) => {
                    tell_links(engine, obj);
                    refresh(engine, obj, &inner);
                }
            }
        }),
    );
}

fn tell_links(engine: &Engine, obj: ObjectId) {
    let Some(v) = ThreadLinks::view(engine, obj) else {
        return;
    };
    let count = i32::try_from(v.count).unwrap_or(i32::MAX);
    let result = engine
        .set_internal(obj, ThreadLinks::AVAILABLE, v.available)
        .and_then(|()| engine.set_internal(obj, ThreadLinks::COUNT, count))
        .and_then(|()| engine.set_internal(obj, ThreadLinks::LABEL, Atom::new(&v.label)))
        .and_then(|()| engine.set_internal(obj, ThreadLinks::PENDING, v.pending))
        .and_then(|()| engine.set_internal(obj, ThreadLinks::LINKED_HERE, v.linked_here))
        .and_then(|()| engine.set_internal(obj, ThreadLinks::MENU_LABEL, Atom::new(&v.menu_label)))
        .and_then(|()| engine.set_internal(obj, ThreadLinks::PICKER_OPEN, v.picker_open))
        .and_then(|()| engine.set_internal(obj, ThreadLinks::QUERY, Atom::new(&v.query)))
        .and_then(|()| {
            engine.set_internal(
                obj,
                ThreadLinks::CANDIDATES,
                Json::Array(v.candidates).to_value(),
            )
        });
    warn(engine, "PullRequestThreadLinks", result);
}

#[qml_impl]
impl ThreadLinks {
    #[qml(invokable, name = "search")]
    fn search_threads(cx: &Cx) {
        ThreadLinks::search(cx.engine, cx.this);
    }

    #[qml(invokable, name = "toggleHere")]
    fn toggle(cx: &Cx) {
        ThreadLinks::toggle_here(cx.engine, cx.this);
    }

    #[qml(invokable, name = "choose")]
    fn choose_thread(cx: &Cx, id: Atom) {
        ThreadLinks::choose(cx.engine, cx.this, &id);
    }
}
