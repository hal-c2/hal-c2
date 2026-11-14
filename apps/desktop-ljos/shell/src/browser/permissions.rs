//! desktop-qt's PagePermissions: what the in-app browser's pages may ask
//! for, and the questions they put to the user, one at a time across every
//! tab (`Browser.permissions`).
//!
//! Most requests have a fixed answer ([`PagePermissions::request`]).
//! Reading the clipboard is asked once per site and remembered while the app
//! runs; one that comes while another question is on screen is refused
//! without being remembered, so a page cannot queue prompts behind the one
//! the user is reading. A link to another app ([`PagePermissions::open_link`])
//! waits its turn instead, one per tab: a tab with a link waiting behind the
//! question on screen has its next link refused.
//!
//! Only a tab the user can see asks anything: a page keeps running while its
//! tab is not shown, and its question would sit where nobody sees it,
//! holding up every other. A tab's brick (BrowserPanel) says whether it
//! shows (`set_shown`; hiding a tab drops its questions), shows `question`
//! when it is the tab's, holds the engine's request until the user answers
//! (`answer`), and drops its questions when its page goes (`forget`).

use std::collections::{HashMap, HashSet};

use serde_json::json;

use crate::json::Json;

const CLIPBOARD: &str = "clipboard";
const LINK: &str = "link";

/// What a page gets without asking: writing the clipboard (the engine still
/// wants the user's click), the location, and locking the mouse pointer for
/// games and 3D viewers (Escape frees it). The rest is refused.
const GRANTED: &[&str] = &["clipboard-write", "geolocation", "mouse-lock"];

/// The schemes the engine shows itself (web, local and inline addresses): a
/// link to one is never handed to the system.
const ENGINE_SCHEMES: &[&str] = &[
    "http",
    "https",
    "about",
    "data",
    "blob",
    "file",
    "javascript",
    "view-source",
    "ws",
    "wss",
    "filesystem",
    "chrome",
    "qrc",
    "devtools",
];

pub fn engine_scheme(scheme: &str) -> bool {
    ENGINE_SCHEMES.contains(&scheme.to_ascii_lowercase().as_str())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Question {
    pub id: i64,
    pub tab: String,
    /// clipboard or link.
    pub kind: &'static str,
    pub origin: String,
    pub url: String,
}

impl Question {
    /// `{id, tabId, kind, origin, url}`, as the brick reads it.
    pub fn to_json(&self) -> Json {
        json!({
            "id": self.id,
            "tabId": self.tab,
            "kind": self.kind,
            "origin": self.origin,
            "url": self.url,
        })
    }
}

/// How a request is answered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    Grant,
    Deny,
    /// Question `id` is put to the user.
    Ask(i64),
}

#[derive(Debug, Default)]
pub struct PagePermissions {
    /// The first is on screen.
    questions: Vec<Question>,
    /// A site's remembered clipboard answer.
    clipboard: HashMap<String, bool>,
    /// The tabs the user can see.
    shown: HashSet<String>,
    next: i64,
    /// The question on screen changed since [`PagePermissions::take_changed`].
    changed: bool,
}

impl PagePermissions {
    /// The question on screen.
    pub fn question(&self) -> Option<&Question> {
        self.questions.first()
    }

    /// Whether the question on screen changed since last asked.
    pub fn take_changed(&mut self) -> bool {
        std::mem::take(&mut self.changed)
    }

    /// How a request for `kind` from `origin` in tab `tab` is answered.
    /// `kind` is one of clipboard, clipboard-write, notifications,
    /// geolocation, camera, microphone, camera-and-microphone, screen,
    /// screen-and-audio, mouse-lock, fonts; anything else is refused.
    pub fn request(&mut self, tab: &str, origin: &str, kind: &str) -> Answer {
        if kind != CLIPBOARD {
            return if GRANTED.contains(&kind) {
                Answer::Grant
            } else {
                Answer::Deny
            };
        }
        if let Some(&allow) = self.clipboard.get(origin) {
            return if allow { Answer::Grant } else { Answer::Deny };
        }
        // One question at a time: a page asking again behind it is refused,
        // not queued.
        if !self.questions.is_empty() || origin.is_empty() || !self.shown.contains(tab) {
            return Answer::Deny;
        }
        Answer::Ask(self.ask(tab, CLIPBOARD, origin, ""))
    }

    /// Asks whether the link `url` to another app may open: the id of its
    /// question; 0 when it is never handed to the system (a local or inline
    /// address, or not a link at all), and -1 when it is refused unasked (its
    /// tab is not shown, or already has a link waiting).
    pub fn open_link(&mut self, tab: &str, url: &str) -> i64 {
        let Ok(parsed) = url::Url::parse(url) else {
            return 0;
        };
        if engine_scheme(parsed.scheme()) {
            return 0;
        }
        if !self.shown.contains(tab) {
            return -1;
        }
        let url = parsed.as_str();
        for (at, waiting) in self.questions.iter().enumerate() {
            if waiting.tab != tab || waiting.kind != LINK {
                continue;
            }
            // The engine may ask twice for one click.
            if waiting.url == url {
                return waiting.id;
            }
            // One link of the tab's waits behind the question on screen; a
            // page following links in a loop gets no more.
            if at > 0 {
                return -1;
            }
        }
        let scheme = parsed.scheme().to_ascii_lowercase();
        self.ask(tab, LINK, &scheme, url)
    }

    fn ask(&mut self, tab: &str, kind: &'static str, origin: &str, url: &str) -> i64 {
        self.next += 1;
        self.questions.push(Question {
            id: self.next,
            tab: tab.to_owned(),
            kind,
            origin: origin.to_owned(),
            url: url.to_owned(),
        });
        if self.questions.len() == 1 {
            self.changed = true;
        }
        self.next
    }

    /// The user's answer to question `id`: the question, or none when it is
    /// no longer asked. A clipboard answer is remembered for its site.
    pub fn answer(&mut self, id: i64, allow: bool) -> Option<Question> {
        let at = self.questions.iter().position(|q| q.id == id)?;
        let answered = self.questions.remove(at);
        if answered.kind == CLIPBOARD {
            self.clipboard.insert(answered.origin.clone(), allow);
        }
        if at == 0 {
            self.changed = true;
        }
        Some(answered)
    }

    /// Whether tab `tab` shows where the user can see it; a tab that stops
    /// showing has its questions dropped, as `forget` does.
    pub fn set_shown(&mut self, tab: &str, shown: bool) {
        if shown {
            self.shown.insert(tab.to_owned());
        } else {
            self.forget(tab);
        }
    }

    /// Drops tab `tab`'s questions: its page went.
    pub fn forget(&mut self, tab: &str) {
        self.shown.remove(tab);
        let on_screen = self.questions.first().is_some_and(|q| q.tab == tab);
        self.questions.retain(|q| q.tab != tab);
        if on_screen {
            self.changed = true;
        }
    }

    /// Forgets every answer and question, as quitting the app does.
    pub fn clear(&mut self) {
        self.clipboard.clear();
        if !self.questions.is_empty() {
            self.changed = true;
        }
        self.questions.clear();
    }
}

#[cfg(test)]
#[path = "permissions_prop.rs"]
mod prop;
