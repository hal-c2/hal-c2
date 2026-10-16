//! `licenses`, desktop-qt's LicensesController: Settings → Open source
//! licenses, the third-party notices this app ships, read from the manifest
//! staged beside it (scripts/third-party-licenses.ts writes it;
//! [`set_manifest_path`] says where). No MC is asked, so it reads with none
//! connected. The manifest is read when the page opens, and again on retry.
//!
//! Publishes `licenses`: {status: loading | ready | error, message, query,
//! total, entries: [{key, name, version, license, where, sourceUrl}] (those
//! the query matches), openKey, noticeText (the open entry's)}.
//!
//! Actions: `licenses.search {query}`, `licenses.open {key}` (the open one
//! again, or null, closes it), `licenses.retry`.

use std::cell::RefCell;
use std::path::{Path, PathBuf};

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::json::Json;

pub const SECTION: &str = "/settings/open-source-licenses";

/// Where every window reads the manifest from.
#[derive(Default)]
struct ManifestPath(RefCell<Option<PathBuf>>);

/// Says where the manifest is (the launch does, before the controllers start;
/// each test does for its own).
pub fn set_manifest_path(engine: &Engine, path: &Path) {
    *engine.extension::<ManifestPath>().0.borrow_mut() = Some(path.to_owned());
}

/// What a bundle id of the manifest is shown as; an id without a label shows
/// as it is.
fn bundle_label(bundle: &str) -> &str {
    match bundle {
        "android" => "Android",
        "assets" => "Assets",
        "desktop" => "Desktop",
        "desktop-qt" => "Qt desktop",
        "device-tools" => "Device tools",
        "ios" => "iOS",
        "mobile" => "Mobile",
        "mobile-qt" => "Qt mobile",
        "server" => "Server",
        "web" => "Web",
        other => other,
    }
}

struct Entry {
    key: String,
    name: String,
    version: String,
    license: String,
    notice_text: String,
    source_url: String,
    bundles: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Status {
    Loading,
    Ready,
    Error,
}

pub struct Licenses {
    bridge: Bridge,
    me: Me<Licenses>,
    active: bool,
    status: Status,
    message: String,
    query: String,
    open_key: String,
    entries: Vec<Entry>,
}

impl Controller for Licenses {
    fn new(init: Init<'_, Self>) -> Self {
        Licenses {
            bridge: init.bridge,
            me: init.me,
            active: false,
            status: Status::Loading,
            message: String::new(),
            query: String::new(),
            open_key: String::new(),
            entries: Vec::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        // Read when the page opens, until it has read.
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            if opened(route) {
                me.run(engine, |licenses, engine| licenses.open(engine));
            }
        });
        self.publish(engine);
        if self
            .bridge
            .published(engine, "route")
            .is_some_and(|r| opened(&r))
        {
            self.open(engine);
        }
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("licenses.") {
            return false;
        }
        let text = |key: &str| payload.get(key).and_then(Json::as_str).unwrap_or_default();
        match action {
            "licenses.search" => self.query = text("query").to_owned(),
            "licenses.open" => {
                let key = text("key");
                self.open_key = if key == self.open_key {
                    String::new()
                } else {
                    key.to_owned()
                };
            }
            "licenses.retry" => {
                self.load(engine);
                return true;
            }
            _ => {}
        }
        self.publish(engine);
        true
    }
}

/// Whether the route is the licenses page.
fn opened(route: &Json) -> bool {
    route.get("kind").and_then(Json::as_str) == Some("settings")
        && route.get("section").and_then(Json::as_str) == Some(SECTION)
}

impl Licenses {
    fn open(&mut self, engine: &Engine) {
        if self.status != Status::Ready {
            self.load(engine);
        }
    }

    fn fail(&mut self, engine: &Engine, message: String) {
        self.status = Status::Error;
        self.message = message;
        self.entries.clear();
        self.publish(engine);
    }

    // decodeThirdPartyLicenseManifest: schema 1, each entry with bundles, a
    // license, a name and its notice text.
    fn load(&mut self, engine: &Engine) {
        self.status = Status::Loading;
        self.entries.clear();
        let path = engine.extension::<ManifestPath>().0.borrow().clone();
        let Some(file) = path.and_then(|p| std::fs::read(p).ok()) else {
            return self.fail(engine, "The license manifest could not load.".into());
        };
        let manifest: Json = serde_json::from_slice(&file).unwrap_or(Json::Null);
        let entries = manifest.get("entries").and_then(Json::as_array);
        let (true, Some(entries)) = (
            manifest.get("schemaVersion").and_then(Json::as_f64) == Some(1.0),
            entries,
        ) else {
            return self.fail(
                engine,
                "The open-source license manifest has an unsupported format.".into(),
            );
        };
        let mut loaded = Vec::new();
        for (index, value) in entries.iter().enumerate() {
            let text = |key: &str| {
                value
                    .get(key)
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned()
            };
            let bundles: Vec<String> = value
                .get("bundles")
                .and_then(Json::as_array)
                .map(|b| {
                    b.iter()
                        .map(|b| b.as_str().unwrap_or_default().to_owned())
                        .collect()
                })
                .unwrap_or_default();
            let mut entry = Entry {
                key: String::new(),
                name: text("name"),
                version: text("version"),
                license: text("license"),
                notice_text: text("noticeText"),
                source_url: text("sourceUrl"),
                bundles,
            };
            if entry.name.is_empty() || entry.license.is_empty() || entry.bundles.is_empty() {
                return self.fail(
                    engine,
                    format!("License entry {} has an invalid shape.", index + 1),
                );
            }
            entry.key = format!("{}:{}@{}", text("kind"), entry.name, entry.version);
            loaded.push(entry);
        }
        self.entries = loaded;
        self.status = Status::Ready;
        self.message.clear();
        self.publish(engine);
    }

    // filterThirdPartyLicenseEntries: every word of the query is in the name,
    // version, license or a bundle.
    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let query = self.query.trim().to_lowercase();
        let terms: Vec<&str> = query.split_whitespace().collect();
        let nullable = |s: &str| if s.is_empty() { Json::Null } else { json!(s) };
        let mut listed = Vec::new();
        let mut notice_text = "";
        for entry in &self.entries {
            let searchable = format!(
                "{} {} {} {}",
                entry.name,
                entry.version,
                entry.license,
                entry.bundles.join(" ")
            )
            .to_lowercase();
            if !terms.iter().all(|term| searchable.contains(term)) {
                continue;
            }
            let places: Vec<&str> = entry.bundles.iter().map(|b| bundle_label(b)).collect();
            listed.push(json!({
                "key": entry.key,
                "name": entry.name,
                "version": nullable(&entry.version),
                "license": entry.license,
                "where": places.join(", "),
                "sourceUrl": nullable(&entry.source_url),
            }));
            if entry.key == self.open_key {
                notice_text = &entry.notice_text;
            }
        }
        let status = match self.status {
            Status::Loading => "loading",
            Status::Ready => "ready",
            Status::Error => "error",
        };
        self.bridge.publish(
            engine,
            "licenses",
            json!({
                "status": status,
                "message": nullable(&self.message),
                "query": self.query,
                "total": self.entries.len(),
                "entries": listed,
                "openKey": if notice_text.is_empty() { Json::Null } else { json!(self.open_key) },
                "noticeText": nullable(notice_text),
            }),
        );
    }
}
