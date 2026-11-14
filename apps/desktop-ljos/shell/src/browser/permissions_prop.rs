//! desktop-qt's tst_PagePermissionsProp: over any order of tabs asking,
//! following links to other apps, the user answering (the question on
//! screen or a stale one), tabs showing and hiding, tabs closing and the app
//! quitting: one question is on screen at a time and it is the oldest still
//! waiting; only a tab the user can see asks, so no question waits on a
//! hidden tab; a site is asked once about the clipboard and its answer kept,
//! a clipboard request behind another question is refused without being
//! kept, a link waits its turn, the same link from one tab is asked once and
//! a tab has at most one link waiting behind the question on screen; local
//! and inline addresses are never asked about, and the question is said to
//! change exactly when the one on screen does.

use std::collections::{BTreeMap, BTreeSet};

use proptest::prelude::*;

use super::{Answer, PagePermissions};

const TABS: &[&str] = &["t1", "t2", "t3"];
const ORIGINS: &[&str] = &["", "http://a.test", "http://b.test"];
const KINDS: &[&str] = &[
    "clipboard",
    "clipboard",
    "clipboard-write",
    "notifications",
    "geolocation",
    "camera",
    "microphone",
    "mouse-lock",
    "fonts",
    "screen",
    "bogus",
    "",
];
const LINKS: &[&str] = &[
    "slack://a",
    "slack://b",
    "slack://c",
    "mailto:ada@example.com",
    "https://x.test/",
    "data:text/plain,hi",
    "file:///etc/hosts",
    "javascript:void(0)",
    "",
    "no scheme",
];

#[derive(Clone, Debug)]
struct Asked {
    id: i64,
    tab: &'static str,
    kind: &'static str,
    origin: String,
    url: String,
}

#[derive(Clone, Debug)]
struct Model {
    questions: Vec<Asked>,
    clipboard: BTreeMap<String, bool>,
    shown: BTreeSet<&'static str>,
    next: i64,
}

impl Model {
    fn front(&self) -> i64 {
        self.questions.first().map_or(0, |q| q.id)
    }

    fn ask(&mut self, tab: &'static str, kind: &'static str, origin: &str, url: &str) -> i64 {
        self.next += 1;
        self.questions.push(Asked {
            id: self.next,
            tab,
            kind,
            origin: origin.to_owned(),
            url: url.to_owned(),
        });
        self.next
    }

    fn drop_tab(&mut self, tab: &str) {
        self.questions.retain(|q| q.tab != tab);
    }
}

/// Whether the system is ever asked to open `url`.
fn outside(url: &str) -> bool {
    url.starts_with("slack:") || url.starts_with("mailto:")
}

#[derive(Clone, Debug)]
enum Action {
    Request(&'static str, &'static str, &'static str),
    OpenLink(&'static str, &'static str),
    /// The question on screen, or a stale id; allow.
    Answer(bool, i64, bool),
    Show(&'static str, bool),
    Forget(&'static str),
    Clear,
}

fn action() -> impl Strategy<Value = Action> {
    let tab = || prop::sample::select(TABS);
    prop_oneof![
        2 => (tab(), prop::sample::select(ORIGINS), prop::sample::select(KINDS))
            .prop_map(|(t, o, k)| Action::Request(t, o, k)),
        3 => (tab(), prop::sample::select(LINKS)).prop_map(|(t, u)| Action::OpenLink(t, u)),
        2 => (any::<bool>(), 0..8i64, any::<bool>()).prop_map(|(s, id, a)| Action::Answer(s, id, a)),
        1 => (tab(), any::<bool>()).prop_map(|(t, s)| Action::Show(t, s)),
        1 => tab().prop_map(Action::Forget),
        1 => Just(Action::Clear),
    ]
}

fn step(
    model: &mut Model,
    sut: &mut PagePermissions,
    action: &Action,
) -> Result<(), TestCaseError> {
    let before = model.front();
    match *action {
        Action::Request(tab, origin, kind) => {
            let wanted = if kind != "clipboard" {
                if matches!(kind, "clipboard-write" | "geolocation" | "mouse-lock") {
                    Answer::Grant
                } else {
                    Answer::Deny
                }
            } else if let Some(&allow) = model.clipboard.get(origin) {
                if allow { Answer::Grant } else { Answer::Deny }
            } else if !model.questions.is_empty() || origin.is_empty() || !model.shown.contains(tab)
            {
                Answer::Deny
            } else {
                Answer::Ask(model.ask(tab, "clipboard", origin, ""))
            };
            prop_assert_eq!(sut.request(tab, origin, kind), wanted);
        }
        Action::OpenLink(tab, url) => {
            let wanted = if !outside(url) {
                0
            } else if !model.shown.contains(tab) {
                -1
            } else if let Some(waiting) = model
                .questions
                .iter()
                .find(|q| q.tab == tab && q.url == url)
            {
                waiting.id
            } else if model
                .questions
                .iter()
                .skip(1)
                .any(|q| q.tab == tab && q.kind == "link")
            {
                -1
            } else {
                let scheme = url.split(':').next().unwrap_or("");
                model.ask(tab, "link", scheme, url)
            };
            prop_assert_eq!(sut.open_link(tab, url), wanted);
        }
        Action::Answer(on_screen, stale, allow) => {
            let id = if on_screen { model.front() } else { stale };
            let answered = model
                .questions
                .iter()
                .position(|q| q.id == id)
                .map(|at| model.questions.remove(at));
            if let Some(q) = &answered
                && q.kind == "clipboard"
            {
                model.clipboard.insert(q.origin.clone(), allow);
            }
            let got = sut.answer(id, allow);
            prop_assert_eq!(got.is_none(), answered.is_none());
            if let (Some(got), Some(want)) = (got, answered) {
                prop_assert_eq!(got.id, want.id);
                prop_assert_eq!(got.kind, want.kind);
                prop_assert_eq!(got.tab, want.tab);
            }
        }
        Action::Show(tab, shown) => {
            if shown {
                model.shown.insert(tab);
            } else {
                model.shown.remove(tab);
                model.drop_tab(tab);
            }
            sut.set_shown(tab, shown);
        }
        Action::Forget(tab) => {
            model.shown.remove(tab);
            model.drop_tab(tab);
            sut.forget(tab);
        }
        Action::Clear => {
            model.questions.clear();
            model.clipboard.clear();
            sut.clear();
        }
    }
    match (sut.question(), model.questions.first()) {
        (None, None) => {}
        (Some(got), Some(want)) => {
            prop_assert_eq!(got.id, want.id);
            prop_assert_eq!(&got.tab, want.tab);
            prop_assert_eq!(got.kind, want.kind);
            prop_assert_eq!(&got.origin, &want.origin);
            prop_assert_eq!(&got.url, &want.url);
        }
        (got, want) => {
            return Err(TestCaseError::fail(format!(
                "{got:?} on screen, not {want:?}"
            )));
        }
    }
    prop_assert_eq!(
        sut.take_changed(),
        before != model.front(),
        "said to change"
    );
    // No question waits where nobody sees it, and a tab has at most one link
    // behind the question on screen.
    let mut behind = BTreeMap::new();
    for (at, waiting) in model.questions.iter().enumerate() {
        prop_assert!(model.shown.contains(waiting.tab));
        if at > 0 && waiting.kind == "link" {
            let n = behind.entry(waiting.tab).or_insert(0);
            *n += 1;
            prop_assert!(*n <= 1);
        }
    }
    Ok(())
}

proptest! {
    #[test]
    fn one_question_is_on_screen_at_a_time(actions in prop::collection::vec(action(), 1..60)) {
        let mut model = Model {
            questions: Vec::new(),
            clipboard: BTreeMap::new(),
            shown: TABS.iter().copied().collect(),
            next: 0,
        };
        let mut sut = PagePermissions::default();
        for tab in TABS {
            sut.set_shown(tab, true);
        }
        for action in &actions {
            step(&mut model, &mut sut, action)?;
        }
    }
}
