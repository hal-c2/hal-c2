//! desktop-qt's BrowserPage, its logic: one browser tab's page, following
//! the MC's tab (ThreadPreviews) and telling the MC what the page does. The
//! QML half ([`super::BrowserPage`]) runs what [`PageCore::take_effects`]
//! asks for and turns [`PageCore::take_notes`] into signals.
//!
//! What the view did comes in through `report`; the MC hears it as
//! `preview.reportStatus`. One the MC refuses takes the page back to its tab;
//! one the connection could not carry goes again once the MC lists the
//! tabs. The MC's tab moving to an address the page did not report (an
//! agent's `preview.navigate`, another window) asks the view to load it
//! ([`PageNote::LoadRequested`]). The device size is the MC's (`viewport`):
//! `set_viewport` shows the new size at once (`resizing` until the MC
//! answers) and sends `preview.resize`. Refused or timed out, the size the
//! MC has is the size; taken, the size picked is, until the MC's tab says
//! otherwise. One size at a time: `set_viewport` does nothing while
//! `resizing`.

use std::collections::HashMap;

use serde_json::json;

use crate::json::Json;
use crate::thread_view::previews::Unheard;

/// The contract's bounds on what the MC keeps of a page.
const MAX_URL: usize = 2048;
const MAX_TITLE: usize = 512;
/// How many addresses the page went to may wait for the MC to say them back.
const ECHOES: usize = 16;

/// What the QML half tells QML.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PageNote {
    /// url, title, status or exists.
    Tab,
    Viewport,
    Resizing,
    /// The MC's tab went to an address the page did not report.
    LoadRequested(String),
    LoadFailed {
        url: String,
        description: String,
    },
}

/// What the QML half does for the core.
#[derive(Clone, Debug, PartialEq)]
pub enum PageEffect {
    /// `preview.reportStatus`; the answer goes to [`PageCore::heard`] with
    /// `owner`, or [`PageCore::unreported`] when no call was made.
    Report {
        tab: String,
        nav: Json,
        back: bool,
        forward: bool,
        owner: u64,
    },
    Navigate {
        tab: String,
        url: String,
    },
    /// `preview.resize`; the answer goes to [`PageCore::resized`], and
    /// without one in time, [`PageCore::timed_out`].
    Resize {
        tab: String,
        viewport: Json,
        pick: u64,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Echo {
    url: String,
    owners: Vec<u64>,
}

#[derive(Debug, Default)]
pub struct PageCore {
    tab_id: String,
    /// The MC's tab, null while there is none.
    tab: Json,
    /// Where the view is, and the addresses it went to that the MC has not
    /// said back yet, oldest first: saying them back is no news, anything
    /// else is. An address several reports (or a navigation, owner 0) went
    /// to is one echo, kept while any of them may still be heard.
    at: String,
    echoes: Vec<Echo>,
    reports: u64,
    last_report: Option<Json>,
    /// The last report never reached the MC (the connection was down): it
    /// goes again once the MC lists the tabs, unless its tab has moved on.
    unsent: bool,
    /// A report is on its way to the MC, and a newer one waits for its
    /// answer.
    reporting: bool,
    report_queued: bool,
    /// A size picked that the MC's tab does not show yet.
    pending_viewport: Option<Json>,
    /// A newer listing showed another size while the pick waited.
    superseded: bool,
    /// The tabs the MC is yet to answer a size for, and which pick: kept
    /// when the page moves to another tab, so back on that one a second
    /// request waits.
    outstanding: HashMap<String, u64>,
    viewport_pick: u64,
    notes: Vec<PageNote>,
    effects: Vec<PageEffect>,
}

fn nav_of(tab: &Json) -> &Json {
    &tab["navStatus"]
}

fn text<'a>(value: &'a Json, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}

fn object_or_empty(value: &Json) -> Json {
    if value.is_object() {
        value.clone()
    } else {
        json!({})
    }
}

impl PageCore {
    pub fn tab_id(&self) -> &str {
        &self.tab_id
    }

    pub fn url(&self) -> &str {
        text(nav_of(&self.tab), "url")
    }

    pub fn title(&self) -> &str {
        text(nav_of(&self.tab), "title")
    }

    /// idle, loading, loaded or failed.
    pub fn status(&self) -> &'static str {
        match text(nav_of(&self.tab), "_tag") {
            "Loading" => "loading",
            "Success" => "loaded",
            "LoadFailed" => "failed",
            _ => "idle",
        }
    }

    pub fn exists(&self) -> bool {
        self.tab.as_object().is_some_and(|tab| !tab.is_empty())
    }

    /// The size picked while the MC is yet to show it, else the MC's;
    /// `{_tag: "fill"}` from an MC that says nothing.
    pub fn viewport(&self) -> Json {
        if let Some(pending) = &self.pending_viewport {
            return pending.clone();
        }
        match &self.tab["viewport"] {
            Json::Object(viewport) if !viewport.is_empty() => Json::Object(viewport.clone()),
            _ => json!({"_tag": "fill"}),
        }
    }

    /// A size was picked and the MC has not answered it yet.
    pub fn resizing(&self) -> bool {
        self.outstanding.contains_key(&self.tab_id)
    }

    /// The page shows MC tab `tab_id`, which the MC has as `snapshot` (null
    /// when it has none).
    pub fn set_tab(&mut self, tab_id: &str, snapshot: Json) {
        if tab_id == self.tab_id {
            return;
        }
        let resizing = self.resizing();
        tab_id.clone_into(&mut self.tab_id);
        self.last_report = None;
        self.unsent = false;
        // A size picked for the old tab is not the new tab's, but its
        // request is still the MC's to answer: back on that tab, the wait
        // is on.
        self.pending_viewport = None;
        self.superseded = false;
        if resizing != self.resizing() {
            self.notes.push(PageNote::Resizing);
        }
        self.follow(snapshot);
    }

    /// Starts afresh at what the MC has now (another tab, or other
    /// previews): the brick loads `url`.
    pub fn follow(&mut self, snapshot: Json) {
        // The reports on their way were another tab's: a reply that comes
        // after the page is back on that tab is not the one in flight.
        self.reports += 1;
        self.reporting = false;
        self.report_queued = false;
        self.tab = if self.tab_id.is_empty() {
            Json::Null
        } else {
            snapshot
        };
        self.at = self.url().to_owned();
        self.echoes.clear();
        self.notes.push(PageNote::Tab);
        self.notes.push(PageNote::Viewport);
    }

    /// The MC said something of the page's tab: it is now `snapshot`, the
    /// last change by an event of kind `last_event` ("" by a list).
    pub fn refresh(&mut self, snapshot: Json, last_event: &str) {
        if snapshot == self.tab {
            return;
        }
        let before = self.tab["viewport"].clone();
        let was = self.url().to_owned();
        self.tab = snapshot;
        self.notes.push(PageNote::Tab);
        // The tab showing the size picked ends the display of the pick, not
        // the wait on the MC's answer: a request is outstanding until it is
        // answered (or the wait times out), whatever else the tab shows
        // meanwhile. Another size while the pick waits (another window's)
        // leaves the pick shown. Once answered, any size the tab shows ends
        // the display of the pick.
        let resized = self.tab["viewport"] != before;
        let shown = object_or_empty(&self.tab["viewport"]);
        match &self.pending_viewport {
            Some(pending) if *pending == shown || (resized && !self.resizing()) => {
                self.pending_viewport = None;
                self.notes.push(PageNote::Viewport);
            }
            // The newest listing shows another size: when the answer comes,
            // that one stands, not the pick it overtook.
            Some(_) if resized => self.superseded = true,
            None if resized => self.notes.push(PageNote::Viewport),
            _ => {}
        }
        let at = self.url().to_owned();
        // A tab gone: its page starts afresh when one comes. Not at a page
        // yet (a size before the page's first report): where the page went
        // stands.
        if at.is_empty() {
            if !self.exists() {
                self.at.clear();
                self.echoes.clear();
            }
            return;
        }
        // The MC saying back where the page went, in order. News that is
        // not about the address (a size) is not the echo of a report still
        // on its way: at the address the tab already had, a resize event
        // leaves the echoes, even one that changed nothing (the MC restamps
        // it all the same).
        let size_only = at == was && last_event == "resized";
        if !size_only && let Some(echo) = self.echoes.iter().position(|echo| echo.url == at) {
            self.echoes.drain(..=echo);
            return;
        }
        // The tab changed but not its address: not where the page is,
        // which may be somewhere the MC has not heard of yet.
        if at == was || at == self.at {
            return;
        }
        // Somewhere the page did not go by itself: an agent, or another
        // window.
        self.at = at.clone();
        self.unsent = false;
        self.notes.push(PageNote::LoadRequested(at));
    }

    /// The MC listed the tabs: back from a drop with the MC's tab still
    /// where it was, where the page went is news.
    pub fn listed(&mut self) {
        if !std::mem::take(&mut self.unsent) || !self.exists() {
            return;
        }
        let Some(report) = &self.last_report else {
            return;
        };
        // The report as the MC lists it, or not: its address, status, title
        // and history flags all come back.
        let where_ = text(&report["navStatus"], "url");
        let listed = object_or_empty(nav_of(&self.tab)) == report["navStatus"]
            && self.tab["canGoBack"].as_bool().unwrap_or(false) == report["canGoBack"]
            && self.tab["canGoForward"].as_bool().unwrap_or(false) == report["canGoForward"];
        if where_ == self.at && !listed {
            self.send();
        }
    }

    /// What the view did: phase "loading", "loaded" or "failed" (with
    /// Chromium's net error `code` and its `description`).
    #[allow(clippy::too_many_arguments)]
    pub fn report(
        &mut self,
        phase: &str,
        url: &str,
        title: &str,
        code: i64,
        description: &str,
        back: bool,
        forward: bool,
    ) {
        // The MC keeps web addresses of a bounded length; the start page,
        // engine-internal pages and a page's source are not news to it.
        if self.tab_id.is_empty()
            || url.is_empty()
            || url.len() > MAX_URL
            || ["about:", "data:", "chrome", "view-source:"]
                .iter()
                .any(|internal| url.starts_with(internal))
        {
            return;
        }
        let title: String = title.chars().take(MAX_TITLE).collect();
        let nav = if phase == "failed" {
            self.notes.push(PageNote::LoadFailed {
                url: url.to_owned(),
                description: description.to_owned(),
            });
            json!({"url": url, "title": title, "_tag": "LoadFailed", "code": code, "description": description})
        } else {
            let tag = if phase == "loading" {
                "Loading"
            } else {
                "Success"
            };
            json!({"url": url, "title": title, "_tag": tag})
        };
        let report = json!({"navStatus": nav, "canGoBack": back, "canGoForward": forward});
        if self.last_report.as_ref() == Some(&report) {
            return;
        }
        self.last_report = Some(report);
        // One report at a time: the MC takes each call in a task of its
        // own, so two in flight can be applied in either order, leaving its
        // tab at the older. The newest waits for the answer to the last.
        if self.reporting {
            self.report_queued = true;
            url.clone_into(&mut self.at);
            return;
        }
        self.send();
    }

    /// The last report, to the MC.
    fn send(&mut self) {
        self.unsent = false;
        let Some(report) = self.last_report.clone() else {
            return;
        };
        let url = text(&report["navStatus"], "url").to_owned();
        self.reports += 1;
        let owner = self.reports;
        self.reporting = true;
        self.report_queued = false;
        self.went(&url, owner);
        self.effects.push(PageEffect::Report {
            tab: self.tab_id.clone(),
            nav: report["navStatus"].clone(),
            back: report["canGoBack"].as_bool().unwrap_or(false),
            forward: report["canGoForward"].as_bool().unwrap_or(false),
            owner,
        });
    }

    /// No call was made for report `owner`.
    pub fn unreported(&mut self, owner: u64) {
        if owner == self.reports {
            self.reporting = false;
        }
    }

    /// How the MC took report `owner` for tab `tab`.
    pub fn heard(&mut self, tab: &str, owner: u64, unheard: Unheard) {
        if tab != self.tab_id || owner != self.reports {
            return;
        }
        self.reporting = false;
        let url = self
            .echoes
            .iter()
            .find(|echo| echo.owners.contains(&owner))
            .map(|echo| echo.url.clone());
        if unheard == Unheard::Heard {
            if self.report_queued {
                self.send();
            }
            return;
        }
        // Dropped on the way, the MC may have taken it and say it back once
        // listed again: the echo stays. Otherwise the MC will not say it
        // back (and an earlier report's echo for the address is that
        // report's).
        if unheard != Unheard::Dropped
            && let Some(url) = &url
        {
            self.forget_echo(url, owner);
        }
        if unheard != Unheard::Refused {
            // It may not have heard: the page stays where it went, and says
            // so on the way back.
            self.unsent = true;
            if self.report_queued {
                self.send();
            }
            return;
        }
        // Refused: its tab is where the page is.
        self.report_queued = false;
        self.last_report = None;
        let at = self.url().to_owned();
        if at.is_empty() || at == self.at {
            return;
        }
        self.at = at.clone();
        self.notes.push(PageNote::LoadRequested(at));
    }

    fn went(&mut self, url: &str, owner: u64) {
        url.clone_into(&mut self.at);
        if let Some(last) = self.echoes.last_mut()
            && last.url == url
        {
            last.owners.push(owner);
            return;
        }
        self.echoes.push(Echo {
            url: url.to_owned(),
            owners: vec![owner],
        });
        if self.echoes.len() > ECHOES {
            self.echoes.remove(0);
        }
    }

    /// The report `owner` will not be said back: its echoes go, the rest
    /// stay.
    fn forget_echo(&mut self, url: &str, owner: u64) {
        for echo in self.echoes.iter_mut().filter(|echo| echo.url == url) {
            echo.owners.retain(|&o| o != owner);
        }
        self.echoes.retain(|echo| !echo.owners.is_empty());
    }

    /// The user went to `url` (already a web address): `preview.navigate`.
    pub fn navigate(&mut self, url: &str) {
        if self.tab_id.is_empty() || url.is_empty() {
            return;
        }
        self.went(url, 0);
        self.effects.push(PageEffect::Navigate {
            tab: self.tab_id.clone(),
            url: url.to_owned(),
        });
    }

    /// The device size (BrowserPanel's js/browser.js viewportOf).
    pub fn set_viewport(&mut self, viewport: Json) {
        // One size at a time: until the MC answers the last, the size it
        // has (or the one picked) is the size, and a second request could
        // not be told from the first's events.
        if self.tab_id.is_empty() || self.resizing() {
            return;
        }
        self.viewport_pick += 1;
        let pick = self.viewport_pick;
        self.outstanding.insert(self.tab_id.clone(), pick);
        self.pending_viewport = Some(viewport.clone());
        self.superseded = false;
        self.notes.push(PageNote::Resizing);
        self.notes.push(PageNote::Viewport);
        self.effects.push(PageEffect::Resize {
            tab: self.tab_id.clone(),
            viewport,
            pick,
        });
    }

    /// The MC answered pick `pick` for tab `tab`: refused, the MC's size is
    /// the size; taken, the size picked stays shown until the MC's tab has
    /// it (its event may come after the answer, or not at all).
    pub fn resized(&mut self, tab: &str, pick: u64, error: Option<&str>) {
        if self.outstanding.get(tab) != Some(&pick) {
            return;
        }
        let here = tab == self.tab_id;
        let undone = here && (error.is_some() || self.superseded);
        if undone
            || (here
                && self.pending_viewport.as_ref() == Some(&object_or_empty(&self.tab["viewport"])))
        {
            self.pending_viewport = None;
        }
        self.settle(tab, pick);
        if undone {
            self.notes.push(PageNote::Viewport);
        }
    }

    /// The MC did not answer pick `pick` in time: the size it has is the
    /// size.
    pub fn timed_out(&mut self, tab: &str, pick: u64) {
        if self.outstanding.get(tab) != Some(&pick) {
            return;
        }
        let here = tab == self.tab_id;
        if here {
            self.pending_viewport = None;
        }
        self.settle(tab, pick);
        if here {
            self.notes.push(PageNote::Viewport);
        }
    }

    fn settle(&mut self, tab: &str, pick: u64) {
        if self.outstanding.get(tab) != Some(&pick) {
            return;
        }
        self.outstanding.remove(tab);
        if tab == self.tab_id {
            self.notes.push(PageNote::Resizing);
        }
    }

    pub fn take_notes(&mut self) -> Vec<PageNote> {
        std::mem::take(&mut self.notes)
    }

    pub fn take_effects(&mut self) -> Vec<PageEffect> {
        std::mem::take(&mut self.effects)
    }
}

#[cfg(test)]
#[path = "page_prop.rs"]
mod prop;
