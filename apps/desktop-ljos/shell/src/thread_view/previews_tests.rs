//! ThreadPreviews' core: tst_TimelinePreviewsRegression's cases, the
//! preview scenarios' suggestions, and tst_TimelinePreviewsProp's state
//! machine against a simulated MC.

use std::collections::HashSet;

use ljos::prelude::Value;
use proptest::prelude::*;
use serde_json::json;

use super::super::rows::{Mirror, RowChange, RowSource};
use super::{Effect, Json, MAX_RECENTS, PreviewNote, Previews, Then, shown, web_address};

const ENVIRONMENT: &str = "env-a";
const MC: &str = "mc-a";
const THREAD: &str = "t1";

fn tab(id: &str) -> Json {
    tab_at(id, json!({"_tag": "Idle"}))
}

fn tab_at(id: &str, nav: Json) -> Json {
    json!({"threadId": THREAD, "tabId": id, "navStatus": nav})
}

fn list(sessions: Vec<Json>, revision: i64, epoch: &str) -> Json {
    json!({"sessions": sessions, "serverEpoch": epoch, "revision": revision})
}

fn event(kind: &str, tab: &str, revision: i64, mut fields: Json) -> Json {
    let object = fields.as_object_mut().unwrap();
    object.insert("type".into(), json!(kind));
    object.insert("threadId".into(), json!(THREAD));
    object.insert("tabId".into(), json!(tab));
    object.insert("serverEpoch".into(), json!("epoch-1"));
    object.insert("revision".into(), json!(revision));
    fields
}

fn tab_ids(previews: &Previews) -> Vec<String> {
    (0..previews.row_count())
        .map(|r| match previews.data(r, "tabId") {
            Value::String(a) => a.to_string(),
            _ => String::new(),
        })
        .collect()
}

/// The calls the previews made, held: (method, then).
fn calls(previews: &mut Previews) -> Vec<(&'static str, Then)> {
    previews
        .take_effects()
        .into_iter()
        .filter_map(|effect| match effect {
            Effect::Call { method, then, .. } => Some((method, then)),
            _ => None,
        })
        .collect()
}

fn held(previews: &mut Previews, method: &str) -> Then {
    calls(previews)
        .into_iter()
        .find(|(m, _)| *m == method)
        .map(|(_, then)| then)
        .unwrap_or_else(|| panic!("{method} was asked"))
}

/// Shown and listing: the list call is held.
fn show() -> (Previews, Then) {
    let mut previews = Previews::new();
    previews.set_thread(ENVIRONMENT, THREAD, MC);
    previews.set_active(true);
    let effects = previews.take_effects();
    assert_eq!(effects[0], Effect::Follow(MC.to_owned()));
    let list = effects
        .into_iter()
        .find_map(|e| match e {
            Effect::Call {
                method: "preview.list",
                then,
                ..
            } => Some(then),
            _ => None,
        })
        .expect("the list is asked for");
    (previews, list)
}

fn resets(previews: &mut Previews) -> usize {
    previews
        .take_changes()
        .iter()
        .filter(|c| matches!(c, RowChange::Reset(_)))
        .count()
}

// A tab closed while the first list was on its way came back with that
// list, which was read before the close: events before the list were
// dropped. Nor does the list show it for a moment, resetting the rows for
// nothing.
#[test]
fn a_tab_closed_while_the_list_is_on_its_way_stays_closed() {
    let (mut p, list_call) = show();
    p.take_changes();
    p.on_event(&event("closed", "tab-1", 2, json!({})));
    p.answer(list_call, Ok(list(vec![tab("tab-1")], 1, "epoch-1")));
    assert_eq!(p.status(), "ready");
    assert!(tab_ids(&p).is_empty());
    assert_eq!(resets(&mut p), 0);
}

// An MC that restarted while the client was away kept showing the tabs it
// no longer has: nothing asked for the list again on the reconnect.
#[test]
fn a_reconnect_lists_the_tabs_again() {
    let (mut p, list_call) = show();
    p.answer(list_call, Ok(list(vec![tab("tab-1")], 1, "epoch-1")));
    assert_eq!(tab_ids(&p), ["tab-1"]);
    p.ready_changed(false);
    p.ready_changed(true);
    let again = held(&mut p, "preview.list");
    p.answer(again, Ok(list(vec![], 0, "epoch-2")));
    assert!(tab_ids(&p).is_empty());
}

// A list read before an event the client had already applied was dropped
// whole, so a tab closed while nobody watched stayed shown.
#[test]
fn a_list_older_than_an_event_still_drops_what_it_closed() {
    let (mut p, list_call) = show();
    p.answer(list_call, Ok(list(vec![tab("tab-1")], 1, "epoch-1")));
    p.set_active(false);
    // The MC closes tab-1 (revision 2) unwatched, then lists, then opens
    // tab-2.
    p.set_active(true);
    let again = held(&mut p, "preview.list");
    p.on_event(&event(
        "opened",
        "tab-2",
        3,
        json!({"snapshot": tab("tab-2")}),
    ));
    p.answer(again, Ok(list(vec![], 2, "epoch-1")));
    assert_eq!(tab_ids(&p), ["tab-2"]);
}

// A close the MC refused after the list was read again did not put the tab
// back: the reload made its answer look like one for another thread.
#[test]
fn a_refused_close_after_a_reload_puts_the_tab_back() {
    let (mut p, list_call) = show();
    p.answer(list_call, Ok(list(vec![tab("tab-1")], 1, "epoch-1")));
    p.close("tab-1");
    let close = held(&mut p, "preview.close");
    p.reload();
    let again = held(&mut p, "preview.list");
    p.answer(again, Ok(list(vec![tab("tab-1")], 1, "epoch-1")));
    assert!(tab_ids(&p).is_empty());
    p.answer(close, Err("no".into()));
    assert_eq!(tab_ids(&p), ["tab-1"]);
    let effects = p.take_effects();
    assert!(effects.contains(&Effect::Notify {
        title: "Could not close the browser tab",
        description: "no".into()
    }));
}

// A tab whose snapshot changed only where no row reads it repainted, and a
// list with such a change reset every row.
#[test]
fn a_change_no_role_shows_repaints_nothing() {
    let (mut p, list_call) = show();
    let loaded = json!({"_tag": "Success", "url": "http://localhost:3000/"});
    p.answer(
        list_call,
        Ok(list(vec![tab_at("tab-1", loaded.clone())], 1, "epoch-1")),
    );
    p.take_changes();
    let mut titled = loaded.clone();
    titled["title"] = json!("");
    p.on_event(&event(
        "navigated",
        "tab-1",
        2,
        json!({"snapshot": tab_at("tab-1", titled)}),
    ));
    p.reload();
    let again = held(&mut p, "preview.list");
    let mut later = tab_at("tab-1", loaded);
    later["createdAt"] = json!("2026-09-23T10:00:00Z");
    p.answer(again, Ok(list(vec![later], 2, "epoch-1")));
    assert_eq!(p.take_changes(), []);
}

#[test]
fn a_failed_page_says_why() {
    let (mut p, list_call) = show();
    p.answer(list_call, Ok(list(vec![tab("tab-1")], 1, "epoch-1")));
    p.on_event(&event(
        "failed",
        "tab-1",
        2,
        json!({"url": "http://localhost:9/", "description": "refused"}),
    ));
    assert_eq!(p.data(0, "status"), Value::from("failed"));
    assert_eq!(p.data(0, "problem"), Value::from("refused"));
    assert_eq!(p.data(0, "title"), Value::from("http://localhost:9/"));
    let quiet = tab_at("t", json!({"_tag": "LoadFailed"}));
    assert_eq!(shown(&quiet, "problem"), "The page did not load.");
    assert_eq!(shown(&tab("t"), "title"), "New tab");
}

// The tab suggests the running servers, configured preview addresses and up
// to 10 recent pages, each address once.
#[test]
fn a_new_tab_suggests_servers_configured_pages_and_recent_ones() {
    let mut p = Previews::new();
    p.servers_listed(vec![
        json!({"url": "http://localhost:5173/", "processName": "vite"}),
    ]);
    p.set_configured(vec![
        "http://localhost:5173/".into(),
        "http://localhost:4000/".into(),
    ]);
    p.set_recents(
        (0..12)
            .map(|n| format!("http://localhost:{}/", 7000 + n))
            .collect(),
    );
    let suggestions = p.suggestions();
    assert_eq!(suggestions.len(), 2 + MAX_RECENTS);
    assert_eq!(
        suggestions[0],
        json!({"url": "http://localhost:5173/", "label": "vite", "kind": "server"})
    );
    assert_eq!(suggestions[1]["kind"], "configured");
    assert_eq!(suggestions[2]["kind"], "recent");
    assert_eq!(
        p.take_notes(),
        [PreviewNote::Suggestions, PreviewNote::Suggestions]
    );
}

#[test]
fn navigating_remembers_the_page_and_opens_it() {
    let (mut p, list_call) = show();
    p.answer(list_call, Ok(list(vec![tab("tab-1")], 1, "epoch-1")));
    assert_eq!(p.empty_tab(), "tab-1");
    p.set_recents(vec![
        "http://localhost:3000/".into(),
        "http://a.test/".into(),
    ]);
    p.navigate("tab-1", "  localhost:3000 ");
    let then = held(&mut p, "preview.navigate");
    assert!(matches!(&then, Then::Navigate { url, .. } if url == "http://localhost:3000/"));
    let snapshot = tab_at(
        "tab-1",
        json!({"_tag": "Success", "url": "http://localhost:3000/"}),
    );
    p.answer(then, Ok(snapshot));
    assert_eq!(p.empty_tab(), "");
    assert_eq!(
        p.take_effects(),
        [
            Effect::Remember(vec![
                "http://localhost:3000/".into(),
                "http://a.test/".into()
            ]),
            Effect::Open("http://localhost:3000/".into()),
        ]
    );
    p.navigate("tab-1", "ftp://x");
    assert!(matches!(&p.take_effects()[..], [Effect::Notify { .. }]));
}

#[test]
fn web_addresses_are_read_as_a_browser_would() {
    assert_eq!(
        web_address("example.com").as_deref(),
        Some("http://example.com/")
    );
    assert_eq!(
        web_address("https://a.test/x").as_deref(),
        Some("https://a.test/x")
    );
    assert_eq!(web_address("/tmp/x"), None);
    assert_eq!(web_address("   "), None);
    assert_eq!(web_address("mailto:a@b.c"), None);
}

// tst_TimelinePreviewsProp: a thread's browser tabs against a simulated MC
// that keeps every thread's tabs, changes them and says so with `preview`
// events, and holds each answer until a step answers it, in any order, or
// refuses it. A list is read when the MC takes the call up, when it is
// asked for or any time before it answers: one answered late is older than
// the events sent since, one read late newer than events the client already
// has. The user switches threads, hides and shows the tab, reloads, closes
// tabs and opens new ones; the MC can restart.
//
// After each step the rows are all of the thread shown, each once, and the
// row signals keep a view in step; a row that stayed the same is not
// redrawn, and nothing resets for no change. Once every answer is in, a
// shown list that loaded is the MC's tabs of the thread.

const THREADS: &[&str] = &["t1", "t2"];
const TABS: &[&str] = &["tab-1", "tab-2", "tab-3", "tab-4"];
const URLS: &[&str] = &["", "http://localhost:3000/", "http://localhost:5173/"];
const MAX_TABS: usize = 6;

/// A call the MC holds, and for a list what it read when asked.
struct Held {
    method: &'static str,
    payload: Json,
    then: Then,
    list: Json,
}

struct Sim {
    previews: Previews,
    mirror: Mirror,
    following: bool,
    tabs: Vec<Json>,
    thread_of: std::collections::HashMap<String, String>,
    epoch: u32,
    revision: i64,
    opened: u32,
    held: Vec<Held>,
    // What the user chose: the thread shown and whether the tab is.
    thread: String,
    active: bool,
}

impl Sim {
    fn new() -> Sim {
        let mut previews = Previews::new();
        let mirror = Mirror::of(&mut previews);
        Sim {
            previews,
            mirror,
            following: false,
            tabs: Vec::new(),
            thread_of: std::collections::HashMap::new(),
            epoch: 1,
            revision: 0,
            opened: 0,
            held: Vec::new(),
            thread: String::new(),
            active: false,
        }
    }

    fn epoch(&self) -> String {
        format!("epoch-{}", self.epoch)
    }

    /// Runs what the previews asked for: subscriptions, and calls the MC
    /// reads (a list, when asked) and holds.
    fn pump(&mut self) {
        loop {
            let effects = self.previews.take_effects();
            if effects.is_empty() {
                return;
            }
            for effect in effects {
                match effect {
                    Effect::Follow(mc) => {
                        assert_eq!(mc, MC);
                        self.following = true;
                    }
                    Effect::Unfollow => self.following = false,
                    Effect::Call {
                        method,
                        payload,
                        then,
                        environment,
                    } => {
                        assert_eq!(environment, ENVIRONMENT);
                        let list = if method == "preview.list" {
                            self.list(&payload)
                        } else {
                            Json::Null
                        };
                        self.held.push(Held {
                            method,
                            payload,
                            then,
                            list,
                        });
                    }
                    Effect::Notify { .. } | Effect::Open(_) | Effect::Remember(_) => {}
                }
            }
        }
    }

    /// A PreviewEvent to every watcher, as preview.ex emit/4.
    fn emit(&mut self, tab: &Json, kind: &str, mut fields: Json) {
        self.revision += 1;
        let object = fields.as_object_mut().unwrap();
        object.insert("type".into(), json!(kind));
        object.insert("threadId".into(), tab["threadId"].clone());
        object.insert("tabId".into(), tab["tabId"].clone());
        object.insert("serverEpoch".into(), json!(self.epoch()));
        object.insert("revision".into(), json!(self.revision));
        if self.following {
            self.previews.on_event(&fields);
            self.pump();
        }
    }

    /// The thread's tabs as the MC lists them now.
    fn list(&self, payload: &Json) -> Json {
        let sessions: Vec<Json> = self
            .tabs
            .iter()
            .filter(|t| t["threadId"] == payload["threadId"])
            .cloned()
            .collect();
        json!({"sessions": sessions, "serverEpoch": self.epoch(), "revision": self.revision})
    }

    fn index_of(&self, tab: &str) -> Option<usize> {
        self.tabs.iter().position(|t| t["tabId"] == tab)
    }

    fn new_tab(&mut self, thread: &str, url: &str) -> Json {
        self.opened += 1;
        let id = format!("tab-{}", self.opened);
        self.thread_of.insert(id.clone(), thread.to_owned());
        let mut nav = json!({"_tag": if url.is_empty() { "Idle" } else { "Success" }});
        if !url.is_empty() {
            nav["url"] = json!(url);
        }
        let tab = json!({"threadId": thread, "tabId": id, "navStatus": nav});
        self.tabs.push(tab.clone());
        self.emit(&tab.clone(), "opened", json!({"snapshot": tab}));
        tab
    }

    /// Answers the held call, or refuses it; a list `fresh` is read only
    /// now.
    fn answer(&mut self, at: usize, ok: bool, fresh: bool) {
        let mut call = self.held.remove(at);
        if fresh && call.method == "preview.list" {
            call.list = self.list(&call.payload);
        }
        let result = if !ok || (call.method == "preview.open" && self.tabs.len() >= MAX_TABS) {
            Err("no".to_owned())
        } else if call.method == "preview.list" {
            Ok(call.list)
        } else if call.method == "preview.close" {
            if let Some(index) = self.index_of(call.payload["tabId"].as_str().unwrap()) {
                let tab = self.tabs.remove(index);
                self.emit(&tab, "closed", json!({}));
            }
            Ok(Json::Null)
        } else {
            let thread = call.payload["threadId"].as_str().unwrap().to_owned();
            Ok(self.new_tab(&thread, ""))
        };
        self.previews.answer(call.then, result);
        self.pump();
    }
}

#[derive(Clone, Debug)]
enum Action {
    SetThread(&'static str),
    SetActive(bool),
    Reload,
    UserClose(&'static str),
    UserNewTab,
    /// The MC answers one held call (the `at`th, wrapping), or refuses it;
    /// a list read when asked, or only now.
    Answer(usize, bool, bool),
    /// The MC answers everything it holds, and what those answers make the
    /// client ask.
    AnswerAll,
    /// An agent opens a tab in a thread.
    McOpen(&'static str, &'static str),
    /// A tab goes to a page (or the same one again), or its page names
    /// itself.
    McNavigate(&'static str, &'static str, &'static str),
    /// A tab changes where no row shows it.
    McTouch(&'static str),
    /// A tab's page does not load.
    McFail(&'static str),
    McClose(&'static str),
    /// The MC starts again: the connection drops with what it held
    /// unanswered, and the client reconnects to a new epoch, revisions from
    /// the start, its browser's tabs gone (or, `keep`, some still open).
    McRestart(bool),
}

fn action() -> impl Strategy<Value = Action> {
    let thread = prop::sample::select(THREADS);
    let tab = || prop::sample::select(TABS);
    prop_oneof![
        1 => thread.clone().prop_map(Action::SetThread),
        1 => any::<bool>().prop_map(Action::SetActive),
        1 => Just(Action::Reload),
        1 => tab().prop_map(Action::UserClose),
        1 => Just(Action::UserNewTab),
        2 => (0..4usize, prop::bool::weighted(0.8), any::<bool>())
            .prop_map(|(at, ok, fresh)| Action::Answer(at, ok, fresh)),
        1 => Just(Action::AnswerAll),
        2 => (thread, prop::sample::select(URLS)).prop_map(|(t, u)| Action::McOpen(t, u)),
        1 => (tab(), prop::sample::select(&URLS[1..]), prop::sample::select(&["", "App"][..]))
            .prop_map(|(t, u, title)| Action::McNavigate(t, u, title)),
        1 => tab().prop_map(Action::McTouch),
        1 => tab().prop_map(Action::McFail),
        1 => tab().prop_map(Action::McClose),
        1 => any::<bool>().prop_map(Action::McRestart),
    ]
}

fn rows(previews: &Previews) -> Vec<Vec<Value>> {
    (0..previews.row_count())
        .map(|r| {
            super::ROLES
                .iter()
                .map(|role| previews.data(r, role))
                .collect()
        })
        .collect()
}

fn row_of_tab(tab: &Json) -> Vec<Value> {
    super::ROLES
        .iter()
        .map(|role| Value::from(shown(tab, role).as_str()))
        .collect()
}

fn step(sim: &mut Sim, action: &Action) -> Result<(), TestCaseError> {
    let before = rows(&sim.previews);
    let before_redrawn = sim.mirror.redrawn.len();
    let before_resets = sim.mirror.resets;
    let mut counted = false;
    let mut note = |sim: &mut Sim| {
        let notes = sim.previews.take_notes();
        counted |= notes.contains(&PreviewNote::Count);
    };
    match action {
        Action::SetThread(thread) => {
            (*thread).clone_into(&mut sim.thread);
            sim.previews.set_thread(ENVIRONMENT, thread, MC);
        }
        Action::SetActive(active) => {
            sim.active = *active;
            sim.previews.set_active(*active);
        }
        Action::Reload => sim.previews.reload(),
        Action::UserClose(tab) => sim.previews.close(tab),
        Action::UserNewTab => sim.previews.new_tab(),
        Action::Answer(at, ok, fresh) => {
            if !sim.held.is_empty() {
                let at = at % sim.held.len();
                sim.pump();
                note(sim);
                sim.answer(at, *ok, *fresh);
            }
        }
        Action::AnswerAll => {
            for _ in 0..8 {
                if sim.held.is_empty() {
                    break;
                }
                while !sim.held.is_empty() {
                    sim.answer(0, true, false);
                    note(sim);
                }
            }
        }
        Action::McOpen(thread, url) => {
            if sim.tabs.len() < MAX_TABS {
                sim.new_tab(thread, url);
            }
        }
        Action::McNavigate(tab, url, title) => {
            if let Some(at) = sim.index_of(tab) {
                sim.tabs[at]["navStatus"] = json!({"_tag": "Success", "url": url, "title": title});
                let snapshot = sim.tabs[at].clone();
                sim.emit(
                    &snapshot.clone(),
                    "navigated",
                    json!({"snapshot": snapshot}),
                );
            }
        }
        Action::McTouch(tab) => {
            if let Some(at) = sim.index_of(tab) {
                let touched = sim.tabs[at]["updatedAt"].as_i64().unwrap_or(0) + 1;
                sim.tabs[at]["updatedAt"] = json!(touched);
                let snapshot = sim.tabs[at].clone();
                sim.emit(
                    &snapshot.clone(),
                    "navigated",
                    json!({"snapshot": snapshot}),
                );
            }
        }
        Action::McFail(tab) => {
            if let Some(at) = sim.index_of(tab) {
                let url = sim.tabs[at]["navStatus"]["url"]
                    .as_str()
                    .unwrap_or("")
                    .to_owned();
                sim.tabs[at]["navStatus"] =
                    json!({"_tag": "LoadFailed", "url": url, "description": "refused"});
                let snapshot = sim.tabs[at].clone();
                sim.emit(
                    &snapshot,
                    "failed",
                    json!({"url": url, "description": "refused"}),
                );
            }
        }
        Action::McClose(tab) => {
            if let Some(at) = sim.index_of(tab) {
                let tab = sim.tabs.remove(at);
                sim.emit(&tab, "closed", json!({}));
            }
        }
        Action::McRestart(keep) => {
            // Every call in flight fails as the socket closes, then the MC
            // is back on a new epoch and the subscriptions are sent again.
            for call in std::mem::take(&mut sim.held) {
                sim.previews.answer(call.then, Err("closed".into()));
                note(sim);
            }
            sim.previews.ready_changed(false);
            sim.epoch += 1;
            sim.revision = 0;
            if !keep {
                sim.tabs.clear();
            }
            sim.previews.ready_changed(true);
        }
    }
    sim.pump();
    note(sim);
    // The view follows; a row that stayed the same is not redrawn, and
    // nothing resets for no change.
    sim.mirror.follow(&mut sim.previews);
    let now = rows(&sim.previews);
    prop_assert!(
        now.len() == before.len() || counted,
        "the count changed unsaid"
    );
    prop_assert!(
        sim.mirror.resets == before_resets || now != before,
        "a reset for nothing"
    );
    for (key, _) in &sim.mirror.redrawn[before_redrawn..] {
        let Some(at) = sim.mirror.keys.iter().position(|k| k == key) else {
            continue;
        };
        let tab = &now[at][0];
        if let Some(old) = before.iter().find(|row| row[0] == *tab) {
            prop_assert!(*old != now[at], "a repaint for nothing: {:?}", tab);
        }
    }
    let mut ids = HashSet::new();
    let mut empty = String::new();
    for row in &now {
        let (Value::String(id), Value::String(url)) = (&row[0], &row[1]) else {
            return Err(TestCaseError::fail("tabId and url are text"));
        };
        prop_assert_eq!(sim.thread_of.get(&id.to_string()), Some(&sim.thread));
        prop_assert!(ids.insert(id.to_string()), "{} shown twice", id);
        if empty.is_empty() && url.is_empty() {
            empty = id.to_string();
        }
    }
    prop_assert_eq!(sim.previews.empty_tab(), empty.as_str());
    prop_assert_eq!(sim.previews.count(), now.len());
    if !sim.held.is_empty() || !sim.active || sim.thread.is_empty() {
        return Ok(());
    }
    prop_assert_ne!(sim.previews.status(), "loading");
    if sim.previews.status() != "ready" {
        return Ok(());
    }
    let want: Vec<Vec<Value>> = sim
        .tabs
        .iter()
        .filter(|t| t["threadId"] == sim.thread.as_str())
        .map(row_of_tab)
        .collect();
    prop_assert_eq!(now, want);
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// The previews list is the MC's tabs of the thread shown, redrawn only
    /// where they changed.
    #[test]
    fn the_previews_are_the_mcs_tabs_of_the_thread_shown(
        actions in prop::collection::vec(action(), 1..50)
    ) {
        let mut sim = Sim::new();
        for action in &actions {
            step(&mut sim, action)?;
        }
    }
}
