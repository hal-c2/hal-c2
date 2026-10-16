//! `ThreadPreviews` as the Preview tab binds it: the tabs listed and
//! followed over an MC that answers when the test says, the invokables, the
//! properties, and what goes to the toast, the browser and the recent pages.

mod common;

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use common::{call, number, text};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Disconnected, Mc, McError, OnFrame, OnReady, Reply, Resume, SubId};
use hal_c2_shell::thread_view::previews::ThreadPreviews;
use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::json;

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    id: root
    property var previews: null
    readonly property string status: root.previews ? root.previews.status : "none"
    readonly property string emptyTab: root.previews ? root.previews.emptyTab : "none"
    readonly property int count: root.previews ? root.previews.count : -1
    function labels() {
        const out = [];
        for (let i = 0; i < rows.count; ++i)
            out.push(rows.itemAt(i).label);
        return out.join("|");
    }
    function suggested() {
        return root.previews.suggestions.map(s => s.kind + ":" + s.url).join(",");
    }
    Column {
        Repeater {
            id: rows
            model: root.previews
            delegate: Item {
                required property string tabId
                required property string title
                required property string status
                readonly property string label: tabId + " " + title + " " + status
            }
        }
    }
}
"#;

/// An MC that holds every answer until the test gives it, and hands frames
/// to whoever follows a shape.
#[derive(Default)]
struct HoldingMc {
    calls: RefCell<Vec<(String, Json, Reply)>>,
    follows: RefCell<HashMap<u64, (String, OnFrame)>>,
    next: Cell<u64>,
}

impl HoldingMc {
    fn answer(&self, engine: &Engine, method: &str, result: Result<Json, &str>) -> Json {
        let at = self
            .calls
            .borrow()
            .iter()
            .position(|(m, _, _)| m == method)
            .unwrap_or_else(|| panic!("{method} was asked"));
        let (_, payload, reply) = self.calls.borrow_mut().remove(at);
        reply(
            engine,
            result.map_err(|message| McError {
                message: message.into(),
                detail: Json::Null,
            }),
        );
        payload
    }

    fn methods(&self) -> Vec<String> {
        self.calls
            .borrow()
            .iter()
            .map(|(m, _, _)| m.clone())
            .collect()
    }

    fn followed(&self) -> Vec<String> {
        let mut shapes: Vec<String> = self
            .follows
            .borrow()
            .values()
            .map(|(s, _)| s.clone())
            .collect();
        shapes.sort();
        shapes
    }

    fn send(&self, engine: &Engine, kind: &str, frame: Json) {
        let Json::Object(frame) = frame else {
            panic!("a frame is an object")
        };
        let ids: Vec<u64> = self
            .follows
            .borrow()
            .iter()
            .filter(|(_, (s, _))| s == kind)
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            let follow = self.follows.borrow_mut().remove(&id);
            if let Some((shape, mut on_frame)) = follow {
                on_frame(engine, &frame);
                self.follows.borrow_mut().insert(id, (shape, on_frame));
            }
        }
    }
}

impl Mc for HoldingMc {
    fn is_ready(&self) -> bool {
        true
    }

    fn environment(&self) -> String {
        "env-1".into()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        assert_eq!(environment, "env-1");
        self.calls
            .borrow_mut()
            .push((method.into(), payload, reply));
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, _: Option<Resume>) -> SubId {
        assert_eq!(shape["mc"], "mc-1");
        self.next.set(self.next.get() + 1);
        let kind = shape["type"].as_str().unwrap_or_default().to_owned();
        self.follows
            .borrow_mut()
            .insert(self.next.get(), (kind, on_frame));
        SubId(self.next.get())
    }

    fn unsubscribe(&self, id: SubId) {
        self.follows.borrow_mut().remove(&id.0);
    }

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, _: OnReady) {}
}

fn tab(id: &str, nav: Json) -> Json {
    json!({"threadId": "t1", "tabId": id, "navStatus": nav})
}

#[derive(Default)]
struct Seen {
    toasts: Vec<String>,
    opened: Vec<String>,
}

struct Fixture {
    engine: Engine,
    root: ObjectId,
    previews: ObjectId,
    mc: Rc<HoldingMc>,
    seen: Rc<RefCell<Seen>>,
    recents: Rc<RefCell<Vec<String>>>,
}

fn fixture() -> Fixture {
    let engine = common::engine(
        common::compile(&[("Main", MAIN)], &[]),
        Rc::new(Disconnected::default()),
    );
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    let mc = Rc::new(HoldingMc::default());
    let seen = Rc::new(RefCell::new(Seen::default()));
    let (toasts, opened) = (seen.clone(), seen.clone());
    let previews = ThreadPreviews::create(
        &engine,
        None,
        mc.clone(),
        move |_, kind, title, description| {
            toasts
                .borrow_mut()
                .toasts
                .push(format!("{kind}: {title}: {description}"));
        },
        move |_, url| opened.borrow_mut().opened.push(url.to_owned()),
    )
    .expect("the previews are made");
    let recents = Rc::new(RefCell::new(vec!["http://a.test/".to_owned()]));
    let (read_from, write_to) = (recents.clone(), recents.clone());
    ThreadPreviews::set_recents(
        &engine,
        previews,
        move |_| read_from.borrow().clone(),
        move |_, urls| *write_to.borrow_mut() = urls.to_vec(),
    );
    engine
        .write_by_name(root, "previews", Value::Object(previews))
        .unwrap();
    Fixture {
        engine,
        root,
        previews,
        mc,
        seen,
        recents,
    }
}

impl Fixture {
    fn labels(&self) -> String {
        self.engine
            .to_js_string(&call(&self.engine, self.root, "labels", &[]))
            .to_string()
    }

    fn suggested(&self) -> String {
        self.engine
            .to_js_string(&call(&self.engine, self.root, "suggested", &[]))
            .to_string()
    }

    /// The thread's tab shown, listing `sessions`.
    fn show(&self, sessions: Vec<Json>) {
        ThreadPreviews::update(&self.engine, self.previews, |p| {
            p.set_thread("env-1", "t1", "mc-1");
            p.set_active(true);
        });
        assert_eq!(self.mc.followed(), ["localServers", "preview"]);
        assert_eq!(text(&self.engine, self.root, "status"), "loading");
        let asked = self.mc.answer(
            &self.engine,
            "preview.list",
            Ok(json!({"sessions": sessions, "serverEpoch": "e1", "revision": 1})),
        );
        assert_eq!(asked, json!({"threadId": "t1"}));
    }

    fn event(&self, kind: &str, tab: &str, revision: i64, snapshot: Option<Json>) {
        let mut event = json!({"type": kind, "threadId": "t1", "tabId": tab, "serverEpoch": "e1", "revision": revision});
        if let Some(snapshot) = snapshot {
            event["snapshot"] = snapshot;
        }
        self.mc.send(
            &self.engine,
            "preview",
            json!({"t": "preview", "event": event}),
        );
    }
}

#[test]
fn the_tabs_list_and_follow_the_mc() {
    let f = fixture();
    assert_eq!(f.suggested(), "recent:http://a.test/");
    f.show(vec![
        tab("tab-1", json!({"_tag": "Idle"})),
        tab(
            "tab-2",
            json!({"_tag": "Success", "url": "http://localhost:5173/", "title": "Vite"}),
        ),
    ]);
    assert_eq!(text(&f.engine, f.root, "status"), "ready");
    assert_eq!(number(&f.engine, f.root, "count"), 2.0);
    assert_eq!(f.labels(), "tab-1 New tab idle|tab-2 Vite loaded");
    assert_eq!(text(&f.engine, f.root, "emptyTab"), "tab-1");

    f.mc.send(
        &f.engine,
        "localServers",
        json!({"t": "localServers", "list": {"servers": [{"url": "http://localhost:5173/", "processName": "vite"}]}}),
    );
    assert_eq!(
        f.suggested(),
        "server:http://localhost:5173/,recent:http://a.test/"
    );

    // An agent's page loads; another tab closes on the MC.
    f.event(
        "navigated",
        "tab-1",
        2,
        Some(tab(
            "tab-1",
            json!({"_tag": "Loading", "url": "http://localhost:3000/"}),
        )),
    );
    f.event("closed", "tab-2", 3, None);
    assert_eq!(f.labels(), "tab-1 http://localhost:3000/ loading");
    assert_eq!(number(&f.engine, f.root, "count"), 1.0);
    assert_eq!(text(&f.engine, f.root, "emptyTab"), "");

    // Hidden, the tab stops following.
    ThreadPreviews::update(&f.engine, f.previews, |p| p.set_active(false));
    assert!(f.mc.followed().is_empty());
}

#[test]
fn navigating_opens_the_page_and_remembers_it() {
    let f = fixture();
    f.show(vec![tab("tab-1", json!({"_tag": "Idle"}))]);
    call(
        &f.engine,
        f.previews,
        "navigate",
        &[Value::from("tab-1"), Value::from("ftp://x")],
    );
    assert_eq!(
        f.seen.borrow().toasts,
        ["error: Could not open the page: \"ftp://x\" is not a web address."]
    );
    assert!(f.mc.methods().is_empty());

    call(
        &f.engine,
        f.previews,
        "navigate",
        &[Value::from("tab-1"), Value::from("localhost:3000")],
    );
    let asked = f.mc.answer(
        &f.engine,
        "preview.navigate",
        Ok(tab(
            "tab-1",
            json!({"_tag": "Success", "url": "http://localhost:3000/", "title": "App"}),
        )),
    );
    assert_eq!(asked["url"], "http://localhost:3000/");
    assert_eq!(f.labels(), "tab-1 App loaded");
    assert_eq!(f.seen.borrow().opened, ["http://localhost:3000/"]);
    assert_eq!(
        *f.recents.borrow(),
        ["http://localhost:3000/", "http://a.test/"]
    );
    assert_eq!(
        f.suggested(),
        "recent:http://localhost:3000/,recent:http://a.test/"
    );
}

#[test]
fn a_closed_tab_goes_at_once_and_a_refused_close_puts_it_back_where_it_was() {
    let f = fixture();
    f.show(vec![
        tab("tab-1", json!({"_tag": "Idle"})),
        tab("tab-2", json!({"_tag": "Idle"})),
    ]);
    call(&f.engine, f.previews, "close", &[Value::from("tab-1")]);
    assert_eq!(f.labels(), "tab-2 New tab idle");
    f.mc.answer(&f.engine, "preview.close", Err("busy"));
    assert_eq!(f.labels(), "tab-1 New tab idle|tab-2 New tab idle");
    assert_eq!(
        f.seen.borrow().toasts,
        ["error: Could not close the browser tab: busy"]
    );

    call(&f.engine, f.previews, "newTab", &[]);
    f.mc.answer(
        &f.engine,
        "preview.open",
        Ok(tab("tab-3", json!({"_tag": "Idle"}))),
    );
    assert_eq!(number(&f.engine, f.root, "count"), 3.0);

    // A failed list keeps what it showed and says why.
    call(&f.engine, f.previews, "reload", &[]);
    f.mc.answer(&f.engine, "preview.list", Err("gone"));
    assert_eq!(text(&f.engine, f.root, "status"), "failed");
    assert_eq!(text(&f.engine, f.previews, "message"), "gone");
    assert_eq!(number(&f.engine, f.root, "count"), 3.0);
}
