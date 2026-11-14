//! desktop-qt's PreviewHistory: the pages this device's browser tabs
//! visited, kept per project for a new tab to suggest
//! ([`super::previews::Previews::suggestions`]): the newest first, each page
//! once, under its tidy address ([`tidy`]). A project keeps its last
//! [`PAGES_PER_PROJECT`] pages, and the device the [`PROJECTS_KEPT`]
//! projects used last.
//!
//! A visit is timed by when the page loaded (the MC's `updatedAt`), so news
//! no newer than what is kept (a thread listing the title it last saw of a
//! page another thread has loaded since) changes nothing. A page taken off
//! the list comes back only with a later visit. A tab only showing a page it
//! loaded before (listed again, resized, its back and forward changing) is
//! no visit: [`PreviewHistory::seen`] leaves the page's time and place as
//! they were.

use serde_json::{Map, json};

use crate::json::Json;
use crate::this_machine;

pub const PAGES_PER_PROJECT: usize = 50;
pub const PROJECTS_KEPT: usize = 20;
/// Times before this are not when a page was visited: pages kept before
/// visits were timed ([`PreviewHistory::keep_untimed`]) are timed 1, 2, ...
/// ms since the epoch.
pub const TIMED_SINCE: i64 = 24 * 3600 * 1000;

/// A page as a project lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Page {
    pub url: String,
    pub title: String,
    /// ms since the epoch.
    pub at: i64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Entry {
    url: String,
    title: String,
    at: i64,
    /// When a tab last reported the title, at or after `at`: an older report
    /// does not replace it.
    titled: i64,
    /// Taken off the list at `at`: an older visit does not bring it back.
    removed: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Project {
    key: String,
    used: i64,
    /// Newest first.
    entries: Vec<Entry>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PreviewHistory {
    /// The one used last first.
    projects: Vec<Project>,
}

/// The address a page is kept under: an http or https URL with a host, its
/// credentials dropped, this machine's loopback hosts as localhost and a
/// bare "/" path as none; "" for anything else.
pub fn tidy(url: &str) -> String {
    let Ok(parsed) = url::Url::parse(url.trim()) else {
        return String::new();
    };
    let Some(host) = parsed.host_str().filter(|h| !h.is_empty()) else {
        return String::new();
    };
    if !matches!(parsed.scheme(), "http" | "https") {
        return String::new();
    }
    let host = if this_machine::loopback_host(host) {
        "localhost"
    } else {
        host
    };
    let mut tidy = format!("{}://{host}", parsed.scheme());
    if let Some(port) = parsed.port() {
        tidy.push_str(&format!(":{port}"));
    }
    if parsed.path() != "/" {
        tidy.push_str(parsed.path());
    }
    if let Some(query) = parsed.query() {
        tidy.push('?');
        tidy.push_str(query);
    }
    if let Some(fragment) = parsed.fragment() {
        tidy.push('#');
        tidy.push_str(fragment);
    }
    tidy
}

/// How a row shows a tidy address: without its scheme
/// ("localhost:5173/docs").
pub fn shown(url: &str) -> String {
    let rest = url.find("://").map_or(url, |at| &url[at + 3..]);
    rest.strip_suffix('/').unwrap_or(rest).to_owned()
}

/// Puts the entry in its place by time, a tie in front, and trims the
/// project.
fn place(project: &mut Project, entry: Entry) {
    project.entries.retain(|kept| kept.url != entry.url);
    let at = project
        .entries
        .iter()
        .position(|kept| kept.at <= entry.at)
        .unwrap_or(project.entries.len());
    project.entries.insert(at, entry);
    // The newest PAGES_PER_PROJECT pages, and as many pages taken off: one
    // taken off before the oldest page of a full list could only come back
    // to be dropped again.
    let (mut pages, mut removed, mut oldest) = (0, 0, 0);
    project.entries.retain(|kept| {
        if !kept.removed {
            if pages == PAGES_PER_PROJECT {
                return false;
            }
            pages += 1;
            if pages == PAGES_PER_PROJECT {
                oldest = kept.at;
            }
            return true;
        }
        removed += 1;
        removed <= PAGES_PER_PROJECT
    });
    if pages == PAGES_PER_PROJECT {
        project
            .entries
            .retain(|kept| !(kept.removed && kept.at < oldest));
    }
}

fn number(value: Option<&Json>) -> i64 {
    value.and_then(Json::as_i64).unwrap_or(0)
}

fn string(value: Option<&Json>) -> &str {
    value.and_then(Json::as_str).unwrap_or("")
}

impl PreviewHistory {
    fn find(&mut self, project: &str) -> Option<&mut Project> {
        self.projects.iter_mut().find(|kept| kept.key == project)
    }

    fn take_or_new(&self, project: &str, used: i64) -> Project {
        self.projects
            .iter()
            .find(|kept| kept.key == project)
            .cloned()
            .unwrap_or_else(|| Project {
                key: project.to_owned(),
                used,
                entries: Vec::new(),
            })
    }

    fn place_project(&mut self, project: Project) {
        self.projects.retain(|kept| kept.key != project.key);
        let at = self
            .projects
            .iter()
            .position(|kept| kept.used <= project.used)
            .unwrap_or(self.projects.len());
        self.projects.insert(at, project);
        self.projects.truncate(PROJECTS_KEPT);
    }

    /// A tab of `project` loaded `url` at `at`; whether anything kept
    /// changed.
    pub fn visit(&mut self, project: &str, url: &str, title: &str, at: i64) -> bool {
        let key = tidy(url);
        if project.is_empty() || key.is_empty() {
            return false;
        }
        let before = self.projects.clone();
        let mut kept = self.take_or_new(project, at);
        let mut entry = Entry {
            url: key.clone(),
            title: title.to_owned(),
            at,
            titled: at,
            removed: false,
        };
        for known in kept.entries.iter().filter(|known| known.url == key) {
            if at < known.at || (known.removed && at == known.at) {
                return false;
            }
            // A load that reports no title keeps the one the page had.
            if title.is_empty() && !known.removed {
                entry.title.clone_from(&known.title);
            }
        }
        place(&mut kept, entry);
        kept.used = kept.used.max(at);
        self.place_project(kept);
        self.projects != before
    }

    /// The user takes `url` off `project`'s list at `at`.
    pub fn remove(&mut self, project: &str, url: &str, at: i64) -> bool {
        let key = tidy(url);
        let Some(kept) = self.find(project) else {
            return false;
        };
        let Some(known) = kept
            .entries
            .iter()
            .find(|entry| entry.url == key && !entry.removed)
            .map(|entry| entry.at)
        else {
            return false;
        };
        if key.is_empty() {
            return false;
        }
        let removed = at.max(known);
        place(
            kept,
            Entry {
                url: key,
                title: String::new(),
                at: removed,
                titled: removed,
                removed: true,
            },
        );
        true
    }

    /// A tab shows a page it loaded before: a visit only if nothing is kept
    /// for the page, else a newer title for it in its place; a page taken
    /// off stays off.
    pub fn seen(&mut self, project: &str, url: &str, title: &str, at: i64) -> bool {
        let key = tidy(url);
        if project.is_empty() || key.is_empty() {
            return false;
        }
        if let Some(kept) = self.find(project)
            && let Some(known) = kept.entries.iter_mut().find(|known| known.url == key)
        {
            if known.removed || title.is_empty() || title == known.title || at < known.titled {
                return false;
            }
            title.clone_into(&mut known.title);
            known.titled = at;
            return true;
        }
        self.visit(project, url, title, at)
    }

    /// The recent pages kept before they were kept per project (one list,
    /// newest first), filed under `project` older than any visit.
    pub fn keep_untimed(&mut self, project: &str, urls: &[String]) -> bool {
        let mut changed = false;
        for (n, url) in urls.iter().enumerate().rev() {
            changed |= self.visit(project, url, "", (urls.len() - n) as i64);
        }
        changed
    }

    /// The project's pages, newest first.
    pub fn pages(&self, project: &str) -> Vec<Page> {
        self.projects
            .iter()
            .filter(|kept| kept.key == project)
            .flat_map(|kept| &kept.entries)
            .filter(|entry| !entry.removed)
            .map(|entry| Page {
                url: entry.url.clone(),
                title: entry.title.clone(),
                at: entry.at,
            })
            .collect()
    }

    /// The projects kept, the one used last first.
    pub fn projects(&self) -> Vec<String> {
        self.projects.iter().map(|kept| kept.key.clone()).collect()
    }

    /// As the device keeps it (`previewHistory`), desktop-qt's shape.
    pub fn to_json(&self) -> Json {
        let projects = self.projects.iter().map(|kept| {
            let pages: Vec<Json> = kept
                .entries
                .iter()
                .map(|entry| {
                    let mut page = Map::new();
                    page.insert("url".into(), json!(entry.url));
                    page.insert("at".into(), json!(entry.at));
                    if !entry.title.is_empty() {
                        page.insert("title".into(), json!(entry.title));
                    }
                    if entry.titled != entry.at {
                        page.insert("titledAt".into(), json!(entry.titled));
                    }
                    if entry.removed {
                        page.insert("removed".into(), json!(true));
                    }
                    Json::Object(page)
                })
                .collect();
            json!({"project": kept.key, "used": kept.used, "pages": pages})
        });
        Json::Array(projects.collect())
    }

    /// Read back through visit and remove, so a hand-edited or older file is
    /// kept tidy too. Both lists are kept newest first; read oldest first, a
    /// tie in the order it was kept.
    pub fn from_json(value: Option<&Json>) -> PreviewHistory {
        let mut history = PreviewHistory::default();
        let projects = value
            .and_then(Json::as_array)
            .map_or(&[][..], Vec::as_slice);
        for project in projects.iter().rev() {
            let key = string(project.get("project"));
            let mut pages: Vec<&Json> = project
                .get("pages")
                .and_then(Json::as_array)
                .map_or(&[][..], Vec::as_slice)
                .iter()
                .rev()
                .collect();
            pages.sort_by_key(|page| number(page.get("at")));
            for page in pages {
                let url = string(page.get("url"));
                let at = number(page.get("at"));
                if page.get("removed").and_then(Json::as_bool) != Some(true) {
                    history.visit(key, url, string(page.get("title")), at);
                    let titled = number(page.get("titledAt"));
                    let tidied = tidy(url);
                    if titled > at
                        && let Some(kept) = history.find(key)
                    {
                        for known in &mut kept.entries {
                            if known.url == tidied && known.at == at && !known.removed {
                                known.titled = titled;
                            }
                        }
                    }
                } else {
                    let tidied = tidy(url);
                    if !key.is_empty() && !tidied.is_empty() {
                        // Never shown on the way in, so it pushes no page out.
                        let mut kept = history.take_or_new(key, 0);
                        place(
                            &mut kept,
                            Entry {
                                url: tidied,
                                title: String::new(),
                                at,
                                titled: at,
                                removed: true,
                            },
                        );
                        history.place_project(kept);
                    }
                }
            }
            if let Some(kept) = history.find(key) {
                let mut moved = kept.clone();
                moved.used = moved.used.max(number(project.get("used")));
                history.place_project(moved);
            }
        }
        history
    }
}

#[cfg(test)]
#[path = "preview_history_prop.rs"]
mod prop;
