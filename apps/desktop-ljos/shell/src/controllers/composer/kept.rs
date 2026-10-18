//! What the composer keeps for the engine rather than its window (desktop-qt
//! keeps it in NativeShell::common for every window): each thread's draft,
//! the stash, the models last sent with, the sends on their way and the
//! sends a quit cut off, all saved beside the drafts ([`set_store_path`]).
//! Other controllers read it here without waiting on the composer.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use ljos::prelude::Engine;
use serde_json::{Map, json};

use super::text::{self, images_signature};
use crate::composer_model::utf16_len;
use crate::controllers::drafts;
use crate::json::Json;
use crate::thread_view::summary::{Obj, as_object};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Attachment {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub data_url: String,
    pub source: Obj,
    /// A file (not an image) goes to the MC when it is added and the message
    /// names the upload (`attachments.createUploadUrl`); an image goes with
    /// its message (`assets.persistChatAttachments`).
    pub file: bool,
    /// Where a file's bytes are: a path on this machine, or a pasted text.
    pub path: String,
    pub content: Vec<u8>,
    pub pasted_text: bool,
    /// A file's upload: "uploading", "failed" (why, in `error`), or empty
    /// once the MC has it as `remote_id` on `environment_id`.
    pub upload: String,
    pub error: String,
    pub remote_id: String,
    pub environment_id: String,
}

/// A terminal selection on the draft; with `citation` a quoted reply
/// (AssistantCitation in packages/contracts/src/assistantCitations.ts) and
/// nothing else; with `review` a note on lines of a diff (a
/// `review-comment` record), `text` being the note.
#[derive(Clone, Debug, PartialEq)]
pub struct Excerpt {
    pub id: String,
    pub terminal_id: String,
    pub terminal_label: String,
    pub line_start: i64,
    pub line_end: i64,
    pub text: String,
    pub citation: Obj,
    pub review: Obj,
}

impl Default for Excerpt {
    fn default() -> Self {
        Excerpt {
            id: String::new(),
            terminal_id: String::new(),
            terminal_label: String::new(),
            line_start: 1,
            line_end: 1,
            text: String::new(),
            citation: Obj::new(),
            review: Obj::new(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Draft {
    /// A new thread's is the draft's own (`drafts::set_text`).
    pub text: String,
    /// In UTF-16 units.
    pub cursor: i64,
    /// The brick's last edit applied here: {clientId, revision}; Null for none.
    pub edit: Json,
    /// The suggestions were dismissed; they return once the text changes.
    pub dismissed: bool,
    /// Chosen in the composer; the thread's own otherwise.
    pub model_selection: Option<Obj>,
    pub runtime_mode: String,
    pub interaction_mode: String,
    /// A new thread's prompt goes to each of these instead: one thread per
    /// model, each in its own worktree.
    pub multiple_models: Option<Vec<Obj>>,
    pub attachments: Vec<Attachment>,
    pub excerpts: Vec<Excerpt>,
}

impl Draft {
    pub fn carries(&self) -> bool {
        !self.attachments.is_empty() || !self.excerpts.is_empty()
    }

    pub fn holds_anything(&self) -> bool {
        !self.text.is_empty() || self.carries()
    }
}

/// A prompt set aside (composer.stash), with what it carried.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StashEntry {
    pub id: String,
    /// ISO, to the millisecond.
    pub created_at: String,
    pub text: String,
    pub attachments: Vec<Attachment>,
    pub excerpts: Vec<Excerpt>,
}

/// A thread's send: the mode changes and the message, in order.
#[derive(Clone, Debug, Default)]
pub struct Send {
    pub target: String,
    pub environment_id: String,
    pub thread_id: String,
    pub commands: Vec<Obj>,
    /// Uploaded first; the message carries what the MC stored.
    pub attachments: Vec<Attachment>,
    /// Given back with the text if the send fails.
    pub excerpts: Vec<Excerpt>,
    /// The text to give back if the send fails; empty for none.
    pub prompt: String,
    pub message_id: String,
}

/// A prompt on its way to the MC, kept with the drafts until the MC answers
/// it: one a quit, crash or dropped connection cut off comes back to its
/// draft once the MC is heard from again (`reconcile_unsent`), unless the
/// MC has it or the user has said something newer there since.
#[derive(Clone, Debug, Default)]
pub struct Unsent {
    /// The thread, or the new thread's draft.
    pub target: String,
    /// The thread it goes to, or a draft's launch makes.
    pub thread: String,
    pub message_id: String,
    /// The thread's newest user message when it was sent, or when its
    /// messages came in after (empty for none); None until they are known.
    pub after: Option<String>,
    pub prompt: String,
    pub attachments: Vec<Attachment>,
    pub excerpts: Vec<Excerpt>,
    /// A send to several models: each model's launch is kept under its id,
    /// and the prompt comes back once, only if none of them started.
    pub batch: String,
    /// Read back from before a restart, or its answer lost with the
    /// connection: waiting to be reconciled.
    pub kept: bool,
    /// The shell's snapshots when its answer was lost: it is reconciled
    /// against a newer one, not rows from before the drop.
    pub seen: u64,
    /// A launch whose answer a drop took, as it was sent: asked again under
    /// its command id, which the MC carries out once, if the shell after the
    /// drop has no thread for it. Not kept across a restart.
    pub launch: Obj,
}

/// The queued message the route thread's composer is editing, and the
/// thread's draft set aside for it.
#[derive(Clone, Debug, Default)]
pub struct QueuedEdit {
    pub thread: String,
    pub run_id: String,
    pub original: String,
    pub saved: String,
    pub saved_cursor: i64,
    pub saving: bool,
}

#[derive(Default)]
pub struct Data {
    pub drafts: HashMap<String, Draft>,
    /// Newest first.
    pub stash: Vec<StashEntry>,
    /// The model last sent with on each provider instance, and the instance
    /// last sent with: a new thread starts from them.
    pub last_models: HashMap<String, Obj>,
    pub last_instance: String,
    /// In the order they were sent.
    pub unsent: Vec<Unsent>,
    /// Each target's send the MC answered last, which its stream may not
    /// have brought yet when the next is sent.
    pub delivered: HashMap<String, String>,
    /// Each thread's sends, the one in flight first: a thread sends one at a
    /// time, in the order the user sent them.
    pub queues: HashMap<String, VecDeque<Send>>,
    pub queued_edit: Option<QueuedEdit>,
    /// Files added to a question's answer, by request then question; not
    /// kept across a restart.
    pub answer_files: HashMap<String, BTreeMap<String, Vec<Attachment>>>,
    path: Option<PathBuf>,
    /// The images last written beside the drafts, so a keystroke does not
    /// rewrite them.
    images: String,
}

#[derive(Default)]
struct Kept(RefCell<Data>);

/// Reads what is kept. `f` must not reach the engine.
pub fn read<R>(engine: &Engine, f: impl FnOnce(&Data) -> R) -> R {
    let kept = engine.extension::<Kept>();
    let data = kept.0.borrow();
    f(&data)
}

/// Changes what is kept. `f` must not reach the engine.
pub fn write<R>(engine: &Engine, f: impl FnOnce(&mut Data) -> R) -> R {
    let kept = engine.extension::<Kept>();
    let mut data = kept.0.borrow_mut();
    f(&mut data)
}

/// The kept draft of `target`, a default one when it has none.
pub fn draft_of(engine: &Engine, target: &str) -> Draft {
    read(engine, |d| {
        d.drafts.get(target).cloned().unwrap_or_default()
    })
}

/// Changes the kept draft of `target`, made when it has none.
pub fn edit_draft<R>(engine: &Engine, target: &str, f: impl FnOnce(&mut Draft) -> R) -> R {
    write(engine, |d| {
        f(d.drafts.entry(target.to_owned()).or_default())
    })
}

/// The thread's (or new thread's) draft text, as the composer last left it.
pub fn draft(engine: &Engine, target: &str) -> String {
    if let Some(kept) = drafts::draft(engine, target) {
        return kept.text;
    }
    read(engine, |d| {
        d.drafts
            .get(target)
            .map(|k| k.text.clone())
            .unwrap_or_default()
    })
}

/// What the sidebar shows for a draft with something in it: the text's
/// first line, else how many attachments and excerpts it carries; nothing
/// for an empty draft.
pub fn draft_preview(engine: &Engine, target: &str) -> Option<String> {
    let text = draft(engine, target);
    let carried = read(engine, |d| {
        d.drafts
            .get(target)
            .map_or(0, |k| k.attachments.len() + k.excerpts.len())
    });
    text::preview_of(&text, carried)
}

/// A draft that became a thread: what the user typed after sending its
/// first message goes on in the thread's composer.
pub fn adopt(engine: &Engine, draft_id: &str, thread_key: &str, text: &str) {
    let adopted = write(engine, |d| {
        let mut carried = d.drafts.remove(draft_id).unwrap_or_default();
        if text.is_empty() && !carried.carries() {
            return false;
        }
        if d.drafts.get(thread_key).is_some_and(Draft::holds_anything) {
            return false;
        }
        carried.edit = Json::Null;
        carried.text = text.to_owned();
        carried.cursor = carried.cursor.clamp(0, utf16_len(text) as i64);
        d.drafts.insert(thread_key.to_owned(), carried);
        true
    });
    if adopted {
        save(engine);
    }
}

/// The draft's terminal excerpts, with their text: {id, terminalId,
/// terminalLabel, lineStart, lineEnd, text}.
pub fn terminal_contexts(engine: &Engine, target: &str) -> Vec<Json> {
    read(engine, |d| {
        d.drafts
            .get(target)
            .into_iter()
            .flat_map(|k| &k.excerpts)
            .filter(|e| e.citation.is_empty() && e.review.is_empty())
            .map(|e| {
                json!({
                    "id": e.id,
                    "terminalId": e.terminal_id,
                    "terminalLabel": e.terminal_label,
                    "lineStart": e.line_start,
                    "lineEnd": e.line_end,
                    "text": e.text,
                })
            })
            .collect()
    })
}

/// The draft's attachments: {id, name, mimeType, sizeBytes, source}.
pub fn attachments(engine: &Engine, target: &str) -> Vec<Json> {
    read(engine, |d| {
        d.drafts
            .get(target)
            .into_iter()
            .flat_map(|k| &k.attachments)
            .map(|a| {
                json!({
                    "id": a.id,
                    "name": a.name,
                    "mimeType": a.mime_type,
                    "sizeBytes": a.size_bytes,
                    "source": a.source,
                })
            })
            .collect()
    })
}

/// Whether `target`'s draft has files still on their way to the MC, or a
/// send in flight that carries the draft's attachments.
pub fn attachments_pending(engine: &Engine, target: &str) -> bool {
    read(engine, |d| {
        let uploading = d
            .drafts
            .get(target)
            .is_some_and(|k| k.attachments.iter().any(|a| a.upload == "uploading"));
        uploading
            || d.queues
                .get(target)
                .is_some_and(|q| q.iter().any(|s| !s.attachments.is_empty()))
    })
}

/// An attachment as the drafts' file keeps it: an image with its bytes
/// (`dataUrl`), a file with its path or pasted text and what the MC knows it
/// as.
pub fn attachment_json(attachment: &Attachment) -> Json {
    let mut kept = json!({
        "id": attachment.id,
        "name": attachment.name,
        "mimeType": attachment.mime_type,
        "sizeBytes": attachment.size_bytes,
        "dataUrl": attachment.data_url,
    });
    if !attachment.source.is_empty() {
        kept["source"] = Json::Object(attachment.source.clone());
    }
    if attachment.file {
        kept["file"] = json!(true);
        kept["path"] = json!(attachment.path);
        kept["dataUrl"] = json!(format!(
            "data:;base64,{}",
            STANDARD.encode(&attachment.content)
        ));
        kept["pastedText"] = json!(attachment.pasted_text);
        kept["remoteId"] = json!(attachment.remote_id);
        kept["environmentId"] = json!(attachment.environment_id);
        kept["upload"] = json!(attachment.upload);
    }
    kept
}

pub fn attachment_of(kept: &Json) -> Option<Attachment> {
    let field = |name: &str| kept[name].as_str().unwrap_or_default().to_owned();
    let data_url = field("dataUrl");
    let file = kept["file"].as_bool().unwrap_or(false);
    if !file && !data_url.starts_with("data:image/") {
        return None;
    }
    let mut attachment = Attachment {
        id: field("id"),
        name: field("name"),
        mime_type: field("mimeType"),
        size_bytes: kept["sizeBytes"].as_f64().unwrap_or(0.0) as i64,
        data_url: if file {
            String::new()
        } else {
            data_url.clone()
        },
        source: as_object(&kept["source"]).clone(),
        ..Attachment::default()
    };
    if !file {
        return Some(attachment);
    }
    attachment.file = true;
    attachment.path = field("path");
    let encoded = data_url.split_once(',').map_or("", |(_, b)| b);
    attachment.content = STANDARD.decode(encoded).unwrap_or_default();
    attachment.pasted_text = kept["pastedText"].as_bool().unwrap_or(false);
    attachment.remote_id = field("remoteId");
    attachment.environment_id = field("environmentId");
    // An upload this shell did not see end has to go again.
    if attachment.remote_id.is_empty() {
        attachment.upload = "failed".into();
        attachment.error = "The upload was interrupted.".into();
    }
    Some(attachment)
}

pub fn excerpt_json(excerpt: &Excerpt) -> Json {
    let mut kept = json!({
        "id": excerpt.id,
        "terminalId": excerpt.terminal_id,
        "terminalLabel": excerpt.terminal_label,
        "lineStart": excerpt.line_start,
        "lineEnd": excerpt.line_end,
        "text": excerpt.text,
    });
    if !excerpt.citation.is_empty() {
        kept["citation"] = Json::Object(excerpt.citation.clone());
    }
    if !excerpt.review.is_empty() {
        kept["review"] = Json::Object(excerpt.review.clone());
    }
    kept
}

pub fn excerpt_of(kept: &Json) -> Excerpt {
    let field = |name: &str| kept[name].as_str().unwrap_or_default().to_owned();
    let line = |name: &str| kept[name].as_f64().map_or(1, |n| n as i64);
    Excerpt {
        id: field("id"),
        terminal_id: field("terminalId"),
        terminal_label: field("terminalLabel"),
        line_start: line("lineStart"),
        line_end: line("lineEnd"),
        text: field("text"),
        citation: as_object(&kept["citation"]).clone(),
        review: as_object(&kept["review"]).clone(),
    }
}

/// Where the drafts' images are kept: `<path minus .json>-images.json`.
fn images_path(path: &Path) -> PathBuf {
    let name = path.to_string_lossy();
    let stem = name.strip_suffix(".json").unwrap_or(&name);
    PathBuf::from(format!("{stem}-images.json"))
}

fn read_json(path: &Path) -> Map<String, Json> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Json>(&bytes).ok())
        .and_then(|json| json.as_object().cloned())
        .unwrap_or_default()
}

/// Where the threads' drafts are kept; loads them from there. Each target's
/// text and choices, as {targets: {<target>: {text, modelSelection,
/// runtimeMode, interactionMode}}, stash: [{id, createdAt, text,
/// attachments, terminalContexts}], unsent, lastInstance, lastModels}, and
/// the drafts' images beside them. The composer publishes what it loaded
/// once it is active.
pub fn load(engine: &Engine, path: Option<PathBuf>) {
    let Some(path) = path else {
        write(engine, |d| d.path = None);
        return;
    };
    let exists = path.exists();
    let stored = read_json(&path);
    let images = std::fs::read(images_path(&path))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Json>(&bytes).ok());
    write(engine, |d| {
        d.path = Some(path.clone());
        if !exists {
            return;
        }
        d.stash.clear();
        for entry in stored
            .get("stash")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
        {
            let field = |name: &str| entry[name].as_str().unwrap_or_default().to_owned();
            let kept = StashEntry {
                id: field("id"),
                created_at: field("createdAt"),
                text: field("text"),
                attachments: list(&entry["attachments"])
                    .filter_map(attachment_of)
                    .collect(),
                excerpts: list(&entry["terminalContexts"]).map(excerpt_of).collect(),
            };
            if !kept.id.is_empty() {
                d.stash.push(kept);
            }
        }
        d.last_instance = stored
            .get("lastInstance")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned();
        for (instance, model) in stored
            .get("lastModels")
            .and_then(Json::as_object)
            .into_iter()
            .flatten()
        {
            d.last_models
                .insert(instance.clone(), as_object(model).clone());
        }
        for (key, entry) in stored
            .get("targets")
            .and_then(Json::as_object)
            .into_iter()
            .flatten()
        {
            let kept = d.drafts.entry(key.clone()).or_default();
            kept.text = entry["text"].as_str().unwrap_or_default().to_owned();
            kept.cursor = utf16_len(&kept.text) as i64;
            if let Some(selection) = entry["modelSelection"].as_object() {
                kept.model_selection = Some(selection.clone());
            }
            kept.runtime_mode = entry["runtimeMode"].as_str().unwrap_or_default().to_owned();
            kept.interaction_mode = entry["interactionMode"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
        }
        let mut unsent_images = Map::new();
        if let Some(images) = &images {
            let targets = as_object(&images["targets"]);
            for (key, list_of) in targets {
                let attachments = &mut d.drafts.entry(key.clone()).or_default().attachments;
                attachments.extend(list(list_of).filter_map(attachment_of));
            }
            unsent_images = as_object(&images["unsent"]).clone();
            d.images = format!(
                "{}\n{}",
                images_signature(targets),
                images_signature(&unsent_images)
            );
        }
        // The sends the app quit or crashed on, waiting to be reconciled.
        d.unsent.clear();
        for entry in stored
            .get("unsent")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
        {
            let field = |name: &str| entry[name].as_str().unwrap_or_default().to_owned();
            let message_id = field("messageId");
            let kept = Unsent {
                target: field("target"),
                thread: field("thread"),
                after: entry["after"].as_str().map(str::to_owned),
                prompt: field("text"),
                attachments: unsent_images
                    .get(&message_id)
                    .map(|l| list(l).filter_map(attachment_of).collect())
                    .unwrap_or_default(),
                excerpts: list(&entry["terminalContexts"]).map(excerpt_of).collect(),
                batch: field("batch"),
                kept: true,
                message_id,
                ..Unsent::default()
            };
            if !kept.target.is_empty() && !kept.message_id.is_empty() {
                d.unsent.push(kept);
            }
        }
    });
}

fn list(value: &Json) -> impl Iterator<Item = &Json> {
    value.as_array().into_iter().flatten()
}

/// What [`images_signature`] says of the JSON of `lists`, without making
/// it: a save compares it with the images last written.
fn signature(lists: &BTreeMap<&str, &[Attachment]>) -> String {
    let mut lines = Vec::new();
    for (key, list) in lists {
        for attachment in *list {
            let (remote_id, upload) = if attachment.file {
                (attachment.remote_id.as_str(), attachment.upload.as_str())
            } else {
                ("", "")
            };
            lines.push(format!("{key}/{}/{remote_id}{upload}", attachment.id));
        }
    }
    lines.join("\n")
}

fn images_json(lists: &BTreeMap<&str, &[Attachment]>) -> Map<String, Json> {
    lists
        .iter()
        .map(|(key, list)| {
            let list = list.iter().map(attachment_json).collect();
            ((*key).to_owned(), Json::Array(list))
        })
        .collect()
}

/// Writes what is kept where [`load`] said, whole or not at all: a write cut
/// short would lose every thread's draft. The images go apart, rewritten
/// only when they change.
pub fn save(engine: &Engine) {
    let written = read(engine, |d| {
        let path = d.path.clone()?;
        let mut targets = Map::new();
        for (key, kept) in &d.drafts {
            // An edited queued message is not the thread's draft.
            let text = match &d.queued_edit {
                Some(edit) if edit.thread == *key => &edit.saved,
                _ => &kept.text,
            };
            let mut entry = Map::new();
            if !text.is_empty() {
                entry.insert("text".into(), json!(text));
            }
            if let Some(selection) = &kept.model_selection {
                entry.insert("modelSelection".into(), Json::Object(selection.clone()));
            }
            if !kept.runtime_mode.is_empty() {
                entry.insert("runtimeMode".into(), json!(kept.runtime_mode));
            }
            if !kept.interaction_mode.is_empty() {
                entry.insert("interactionMode".into(), json!(kept.interaction_mode));
            }
            if !entry.is_empty() {
                targets.insert(key.clone(), Json::Object(entry));
            }
        }
        let stash: Vec<Json> = d
            .stash
            .iter()
            .map(|entry| {
                json!({
                    "id": entry.id,
                    "createdAt": entry.created_at,
                    "text": entry.text,
                    "attachments": entry.attachments.iter().map(attachment_json).collect::<Vec<_>>(),
                    "terminalContexts": entry.excerpts.iter().map(excerpt_json).collect::<Vec<_>>(),
                })
            })
            .collect();
        let mut unsent = Vec::new();
        let mut unsent_images = BTreeMap::new();
        for entry in &d.unsent {
            let mut kept = json!({
                "target": entry.target,
                "thread": entry.thread,
                "messageId": entry.message_id,
                "text": entry.prompt,
            });
            if let Some(after) = &entry.after {
                kept["after"] = json!(after);
            }
            if !entry.batch.is_empty() {
                kept["batch"] = json!(entry.batch);
            }
            if !entry.excerpts.is_empty() {
                kept["terminalContexts"] =
                    Json::Array(entry.excerpts.iter().map(excerpt_json).collect());
            }
            unsent.push(kept);
            if !entry.attachments.is_empty() {
                unsent_images.insert(entry.message_id.as_str(), entry.attachments.as_slice());
            }
        }
        let mut stored = json!({"targets": targets});
        if !stash.is_empty() {
            stored["stash"] = Json::Array(stash);
        }
        if !unsent.is_empty() {
            stored["unsent"] = Json::Array(unsent);
        }
        if !d.last_instance.is_empty() {
            stored["lastInstance"] = json!(d.last_instance);
            let models: Map<String, Json> = d
                .last_models
                .iter()
                .map(|(k, v)| (k.clone(), Json::Object(v.clone())))
                .collect();
            stored["lastModels"] = Json::Object(models);
        }
        let images: BTreeMap<&str, &[Attachment]> = d
            .drafts
            .iter()
            .filter(|(_, kept)| !kept.attachments.is_empty())
            .map(|(key, kept)| (key.as_str(), kept.attachments.as_slice()))
            .collect();
        let joined = format!("{}\n{}", signature(&images), signature(&unsent_images));
        // The images' JSON holds their bytes: made only when it is written.
        let images = (joined != d.images).then(|| {
            let mut kept = json!({"targets": images_json(&images)});
            if !unsent_images.is_empty() {
                kept["unsent"] = Json::Object(images_json(&unsent_images));
            }
            (joined, kept)
        });
        Some((path, stored, images))
    });
    let Some((path, stored, images)) = written else {
        return;
    };
    let _ = drafts::write_atomically(&path, stored.to_string().as_bytes());
    let Some((joined, kept)) = images else {
        return;
    };
    let images_path = images_path(&path);
    let empty =
        kept["targets"].as_object().is_some_and(Map::is_empty) && kept.get("unsent").is_none();
    // Remembered once written, so a failed write is tried again on the next save.
    let done = if empty {
        std::fs::remove_file(&images_path).is_ok() || !images_path.exists()
    } else {
        drafts::write_atomically(&images_path, kept.to_string().as_bytes()).is_ok()
    };
    if done {
        write(engine, |d| d.images = joined);
    }
}

/// A kept attachment of any draft, or of a question's answer, by id.
pub fn find_attachment(engine: &Engine, id: &str) -> Option<Attachment> {
    read(engine, |d| {
        d.drafts
            .values()
            .flat_map(|k| &k.attachments)
            .chain(d.answer_files.values().flat_map(|q| q.values().flatten()))
            .find(|a| a.id == id)
            .cloned()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A save tells changed images by [`signature`], a load by
    /// [`images_signature`] of what it read: were they to differ, every save
    /// after a load would write the images again.
    #[test]
    fn the_saved_signature_is_the_loaded_one() {
        let image = Attachment {
            id: "a".into(),
            data_url: "data:image/png;base64,AAAA".into(),
            ..Attachment::default()
        };
        let file = Attachment {
            id: "b".into(),
            file: true,
            remote_id: "r1".into(),
            upload: String::new(),
            ..Attachment::default()
        };
        let failed = Attachment {
            id: "c".into(),
            file: true,
            upload: "failed".into(),
            ..Attachment::default()
        };
        let one = [image, file];
        let other = [failed];
        let lists = BTreeMap::from([("t2", &other[..]), ("t1", &one[..])]);
        assert_eq!(signature(&lists), images_signature(&images_json(&lists)));
        assert_eq!(signature(&lists), "t1/a/\nt1/b/r1\nt2/c/failed");
    }
}
