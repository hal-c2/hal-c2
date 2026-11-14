//! A page's history as the user looks through it, desktop-qt's
//! SpaceHistory: its versions a stretch at a time, and the one being read.
//! It sends nothing itself: what changes it hands back the request to
//! send, whose answer comes back with its token. An answer to anything
//! since replaced is dropped, and only one stretch is asked for at a
//! time, so a refresh wanted meanwhile follows the answer.

use serde_json::{Value, json};

use super::markdown::{list_items, markdown_frame};
use super::rows::Row;
use super::stream::{Entity, text};

pub struct Request {
    pub token: i64,
    pub payload: Value,
}

pub type Next = Option<Request>;

fn by_agent(author: Option<&Value>) -> bool {
    author
        .and_then(Value::as_object)
        .is_some_and(|a| a.get("type").and_then(Value::as_str) == Some("agent"))
}

fn by_type(author: Option<&Value>, kind: &str) -> bool {
    author
        .and_then(Value::as_object)
        .is_some_and(|a| a.get("type").and_then(Value::as_str) == Some(kind))
}

#[derive(Default)]
pub struct History {
    page_id: String,
    versions: Vec<Row>,
    tokens: i64,
    list_token: i64,
    read_token: i64,
    appending: bool,
    stale: bool,
    failed: bool,
    reading: bool,
    next_before: i64,
    refreshing: bool,
    version: Row,
    read: Vec<Entity>,
    /// Set when something QML reads changed; the controller syncs and clears.
    pub changed: bool,
    /// A version with images came: they want addresses.
    pub images_arrived: bool,
}

impl History {
    pub fn new() -> History {
        History {
            next_before: -1,
            ..History::default()
        }
    }

    pub fn shown(&self) -> bool {
        !self.page_id.is_empty()
    }

    pub fn page_id(&self) -> &str {
        &self.page_id
    }

    pub fn loading(&self) -> bool {
        self.list_token != 0
    }

    pub fn failed(&self) -> bool {
        self.failed
    }

    pub fn has_more(&self) -> bool {
        self.next_before >= 0
    }

    pub fn reading(&self) -> bool {
        self.reading
    }

    pub fn version(&self) -> Row {
        self.version.clone()
    }

    pub fn versions(&self) -> Vec<Row> {
        self.versions.clone()
    }

    /// Starts over on the newest versions of `page_id`.
    pub fn open(&mut self, page_id: &str) -> Next {
        self.close_inner();
        self.page_id = page_id.to_owned();
        if !page_id.is_empty() {
            self.tokens += 1;
            self.list_token = self.tokens;
        }
        self.changed = true;
        if page_id.is_empty() {
            return None;
        }
        Some(Request {
            token: self.list_token,
            payload: json!({"pageId": page_id}),
        })
    }

    fn close_inner(&mut self) {
        self.page_id.clear();
        self.list_token = 0;
        self.appending = false;
        self.refreshing = false;
        self.stale = false;
        self.failed = false;
        self.next_before = -1;
        self.versions.clear();
        self.stop_reading_inner();
    }

    pub fn close(&mut self) {
        self.close_inner();
        self.changed = true;
    }

    /// The next stretch, when there is one and none is on its way.
    pub fn more(&mut self) -> Next {
        if !self.shown() || self.loading() || !self.has_more() {
            return None;
        }
        self.tokens += 1;
        self.list_token = self.tokens;
        self.appending = true;
        self.failed = false;
        self.changed = true;
        Some(Request {
            token: self.list_token,
            payload: json!({"pageId": self.page_id, "before": self.next_before}),
        })
    }

    /// The versions held, anew: the page was written. Waits for a stretch
    /// on its way.
    pub fn refresh(&mut self) -> Next {
        if !self.shown() {
            return None;
        }
        if self.loading() {
            self.stale = true;
            return None;
        }
        self.tokens += 1;
        self.list_token = self.tokens;
        self.refreshing = true;
        self.failed = false;
        self.changed = true;
        let limit = (self.versions.len() as i64).clamp(30, 100);
        Some(Request {
            token: self.list_token,
            payload: json!({"pageId": self.page_id, "limit": limit}),
        })
    }

    fn settled(&mut self) -> Next {
        self.list_token = 0;
        self.appending = false;
        self.refreshing = false;
        self.changed = true;
        if !std::mem::take(&mut self.stale) {
            return None;
        }
        self.refresh()
    }

    /// The answer to a `space.page.history`, and what to ask next.
    pub fn receive(&mut self, token: i64, result: &Entity) -> Next {
        if token == 0 || token != self.list_token {
            return None;
        }
        let had = self.versions.clone();
        let mut rows: Vec<Row> = if self.appending {
            had.clone()
        } else {
            Vec::new()
        };
        let mut held: std::collections::HashSet<String> = rows
            .iter()
            .map(|r| r.get("id").and_then(Value::as_str).unwrap_or("").to_owned())
            .collect();
        if let Some(versions) = result.get("versions").and_then(Value::as_array) {
            for value in versions {
                let Some(version) = value.as_object() else {
                    continue;
                };
                let number = version.get("version").and_then(Value::as_i64).unwrap_or(0);
                let id = number.to_string();
                if held.contains(&id) {
                    continue;
                }
                held.insert(id.clone());
                let author = version.get("author");
                let mut row = Row::new();
                row.insert("id".into(), json!(id));
                row.insert("version".into(), json!(number));
                row.insert("at".into(), json!(text(version, "at")));
                row.insert("byAgent".into(), json!(by_agent(author)));
                row.insert("byUpdate".into(), json!(by_type(author, "schedule")));
                row.insert("byFile".into(), json!(by_type(author, "file")));
                row.insert("threadTitle".into(), json!(text(version, "threadTitle")));
                row.insert(
                    "restoredFromAt".into(),
                    json!(text(version, "restoredFromAt")),
                );
                rows.push(row);
            }
        }
        let mut next_before = result
            .get("nextBefore")
            .and_then(Value::as_i64)
            .unwrap_or(-1);
        let oldest = had
            .iter()
            .position(|r| r.get("version").and_then(Value::as_i64) == Some(next_before));
        if self.refreshing
            && next_before >= 0
            && let Some(oldest) = oldest
            && oldest + 1 < had.len()
        {
            rows.extend(had[oldest + 1..].iter().cloned());
            next_before = self.next_before;
        }
        self.versions = rows;
        self.next_before = next_before;
        self.failed = false;
        self.settled()
    }

    pub fn receive_failed(&mut self, token: i64) -> Next {
        if token == 0 || token != self.list_token {
            return None;
        }
        self.failed = true;
        self.settled()
    }

    /// Asks for one version to read, and leaves the one being read.
    pub fn read(&mut self, version: i64) -> Request {
        self.stop_reading_inner();
        self.reading = true;
        self.tokens += 1;
        self.read_token = self.tokens;
        self.changed = true;
        Request {
            token: self.read_token,
            payload: json!({"pageId": self.page_id, "version": version}),
        }
    }

    fn stop_reading_inner(&mut self) {
        self.reading = false;
        self.read_token = 0;
        self.version.clear();
        self.read.clear();
    }

    pub fn stop_reading(&mut self) {
        self.stop_reading_inner();
        self.changed = true;
    }

    /// The answer to a `space.page.version`. A failed one goes back to the list.
    pub fn receive_version(&mut self, token: i64, result: &Entity) {
        if token == 0 || token != self.read_token {
            return;
        }
        self.read_token = 0;
        self.read = result
            .get("blocks")
            .and_then(Value::as_array)
            .map(|blocks| {
                blocks
                    .iter()
                    .filter_map(|b| b.as_object().cloned())
                    .collect()
            })
            .unwrap_or_default();
        let mut version = Row::new();
        version.insert(
            "version".into(),
            json!(result.get("version").and_then(Value::as_i64).unwrap_or(0)),
        );
        version.insert("at".into(), json!(text(result, "at")));
        version.insert("title".into(), json!(text(result, "title")));
        self.version = version;
        self.changed = true;
        if !self.images_read().is_empty() {
            self.images_arrived = true;
        }
    }

    pub fn failed_version(&mut self, token: i64) {
        if token == 0 || token != self.read_token {
            return;
        }
        self.stop_reading();
    }

    /// The images of the version being read, which want addresses as the
    /// page's own do.
    pub fn images_read(&self) -> Vec<String> {
        self.read
            .iter()
            .filter(|b| text(b, "kind") == "image")
            .map(|b| text(b, "imageId"))
            .collect()
    }

    /// The version being read as rows, as the page's blocks are.
    pub fn blocks(
        &self,
        title_of: &dyn Fn(&str) -> String,
        image_fields: &dyn Fn(&str) -> Row,
    ) -> Vec<Row> {
        let items = list_items(&self.read);
        let mut rows = Vec::new();
        for (i, block) in self.read.iter().enumerate() {
            let linked = text(block, "linkedPageId");
            let image = text(block, "kind") == "image";
            let mut row = Row::new();
            row.insert("id".into(), json!(text(block, "id")));
            row.insert("kind".into(), json!(text(block, "kind")));
            row.insert("text".into(), json!(text(block, "text")));
            row.insert(
                "level".into(),
                json!(block.get("level").and_then(Value::as_i64).unwrap_or(2)),
            );
            row.insert("language".into(), json!(text(block, "language")));
            row.insert(
                "checked".into(),
                json!(
                    block
                        .get("checked")
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
                ),
            );
            row.insert("linkedPageId".into(), json!(linked));
            row.insert(
                "linkedTitle".into(),
                json!(if linked.is_empty() {
                    String::new()
                } else {
                    title_of(&linked)
                }),
            );
            row.insert("byAgent".into(), json!(by_agent(block.get("updatedBy"))));
            row.insert("openComments".into(), json!(0));
            row.insert(
                "chart".into(),
                block.get("chart").cloned().unwrap_or_else(|| json!({})),
            );
            let image_id = if image {
                text(block, "imageId")
            } else {
                String::new()
            };
            for (k, v) in image_fields(&image_id) {
                row.insert(k, v);
            }
            for (k, v) in markdown_frame(block, items.get(i).and_then(|o| o.as_ref())) {
                row.insert(k, v);
            }
            rows.push(row);
        }
        rows
    }
}
