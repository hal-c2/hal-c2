//! The composer's @ menu against an MC whose workspace search the test
//! holds and answers (tst_ComposerSuggestionsProp.cpp): the user types and
//! the search answers late, after the text moved on. A bare `@` is never
//! searched, so its menu opens at once and says nothing matches; a word
//! after it says nothing until the search for that word has answered, and an
//! older word's answer (landing late) never counts. The caret is at the end
//! of the text, on one thread whose workspace is present and online.

use hal_c2_shell::composer_model::trigger;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::composer::on_threads;

const SEARCH: &str = "projects.searchEntries";
const NOTHING: &str = "No matching files or folders.";

/// No menu, a bare @, and words after it, at the start of the text or after
/// another word, that the workspace's one file, src/main.cpp, does and does
/// not match.
const TEXTS: [&str; 11] = [
    "", "hello", "@", "@s", "@sr", "@m", "@ss", "@zz", "hello @", "hello @s", "hello@s",
];

/// What the workspace's search finds: the folder src and the file
/// src/main.cpp, each when its last segment contains the query.
fn found(query: &str) -> Vec<serde_json::Value> {
    let query = query.to_lowercase();
    [("src", "directory"), ("src/main.cpp", "file")]
        .into_iter()
        .filter(|(path, _)| path.rsplit('/').next().unwrap_or(path).contains(&query))
        .map(|(path, kind)| json!({"path": path, "kind": kind}))
        .collect()
}

#[derive(Clone, Debug)]
enum Op {
    Type(usize),
    /// The MC holds the searches it is asked from now on.
    Hold,
    /// The MC answers every search it held, the older ones after the text
    /// moved on.
    AnswerHeld,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        3 => (0..TEXTS.len()).prop_map(Op::Type),
        1 => Just(Op::Hold),
        1 => Just(Op::AnswerHeld),
    ]
}

#[derive(Default)]
struct Model {
    text: String,
    holding: bool,
    /// The query last searched, and whether its answer reached the composer.
    searched: String,
    answered: bool,
    asked: usize,
}

impl Model {
    /// The @ word the composer itself reads, so the model does not restate
    /// the trigger rules.
    fn query(&self) -> Option<String> {
        trigger(&self.text, self.text.encode_utf16().count() as i64)
            .filter(|t| t.kind == "path")
            .map(|t| t.query)
    }
}

struct World {
    hub: Hub,
    model: Model,
}

impl World {
    fn answer_all(&self) {
        while let Some(index) = self.hub.mc.pending(SEARCH) {
            let query = self.hub.mc.calls.borrow()[index].2["query"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            self.hub.mc.reply(
                &self.hub.engine,
                index,
                Ok(json!({"entries": found(&query)})),
            );
        }
    }

    fn step(&mut self, op: Op) {
        let m = &mut self.model;
        match op {
            Op::Type(i) => {
                let text = TEXTS[i];
                self.hub.dispatch(
                    "composer.text.set",
                    json!({"target": "env-1:t1", "text": text,
                        "cursor": text.encode_utf16().count()}),
                );
                m.text = text.to_owned();
                // A new word is searched; the same one is not asked again.
                if let Some(query) = m.query().filter(|q| !q.is_empty() && *q != m.searched) {
                    m.searched = query;
                    m.answered = !m.holding;
                    m.asked += 1;
                }
                if !m.holding {
                    self.answer_all();
                }
            }
            Op::Hold => m.holding = true,
            Op::AnswerHeld => {
                m.holding = false;
                if !m.searched.is_empty() {
                    m.answered = true;
                }
                self.answer_all();
            }
        }
    }

    fn check(&self) {
        let m = &self.model;
        let shown = self.hub.published("composer");
        assert_eq!(shown["text"], m.text.as_str());
        let count = shown["suggestions"].as_array().map_or(0, Vec::len);
        let empty = &shown["suggestionsEmptyText"];
        match m.query() {
            None => {
                assert_ne!(shown["triggerKind"], "path");
                assert_eq!((count, empty), (0, &json!(null)), "{shown}");
            }
            Some(query) => {
                assert_eq!(shown["triggerKind"], "path");
                if query.is_empty() {
                    assert_eq!((count, empty), (0, &json!(NOTHING)), "{shown}");
                } else if m.searched != query || !m.answered {
                    assert_eq!((count, empty), (0, &json!(null)), "{shown}");
                } else {
                    let found = found(&query).len();
                    let expected = if found > 0 {
                        json!(null)
                    } else {
                        json!(NOTHING)
                    };
                    assert_eq!((count, empty), (found, &expected), "{shown}");
                }
            }
        }
        // The searches the MC received are exactly the ones the model asked
        // for: a duplicate search for the same word fails here.
        let asked = self
            .hub
            .mc
            .calls
            .borrow()
            .iter()
            .filter(|(_, method, _)| method == SEARCH)
            .count();
        assert_eq!(asked, m.asked);
    }
}

/// A bare `@` opened no menu: it is never searched, so the menu says at
/// once that nothing matches; a word after it waits for its search.
#[test]
fn a_bare_at_opens_the_menu_saying_nothing_matches() {
    let hub = on_threads(&["t1"]);
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "@", "cursor": 1}),
    );
    let shown = hub.published("composer");
    assert_eq!(shown["triggerKind"], "path");
    assert_eq!(shown["suggestionsEmptyText"], NOTHING);
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "@src", "cursor": 4}),
    );
    let shown = hub.published("composer");
    assert_eq!(shown["triggerKind"], "path");
    assert_eq!(shown["suggestionsEmptyText"], json!(null));
    let index = hub.mc.pending(SEARCH).expect("the word is searched");
    hub.mc.reply(&hub.engine, index, Ok(json!({"entries": []})));
    assert_eq!(hub.published("composer")["suggestionsEmptyText"], NOTHING);
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    #[test]
    fn the_at_menu_says_nothing_matches_only_for_a_search_that_answered(
        ops in proptest::collection::vec(op(), 1..30)
    ) {
        let mut world = World { hub: on_threads(&["t1"]), model: Model::default() };
        world.check();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
