//! The draft's images and files, a question's answer files, and the
//! excerpts (terminal selections, quoted replies, review notes) a draft
//! carries.

use std::collections::HashMap;
use std::io::{Cursor, Read};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use ljos::prelude::Engine;
use serde_json::json;

use super::kept::{self, Attachment, Excerpt};
use super::text::{self, CITATION_CONTEXT_LENGTH, MAX_CITATION_LENGTH, left, right};
use super::{Composer, back, later, string, thread_of, toast, toast_error, uuid};
use crate::composer_model as model;
use crate::controllers::keybindings::Keymap;
use crate::json::Json;
use crate::thread_view::summary::{Obj, as_object, text as field};

/// The side of an image's thumbnail.
const THUMBNAIL_SIDE: u32 = 128;

/// What the composer shows of a draft image, its middle square scaled down,
/// as a PNG data URL: the full image would be compared and handed to QML on
/// every keystroke. Empty when the image cannot be read.
pub(super) fn thumbnail(data_url: &str) -> String {
    let encoded = data_url.split_once(',').map_or(data_url, |(_, b)| b);
    let Ok(bytes) = STANDARD.decode(encoded.trim()) else {
        return String::new();
    };
    let Ok(image) = image::load_from_memory(&bytes) else {
        return String::new();
    };
    let (width, height) = (image.width(), image.height());
    let side = width.min(height);
    if side == 0 {
        return String::new();
    }
    let mut square = image.crop_imm((width - side) / 2, (height - side) / 2, side, side);
    if side > THUMBNAIL_SIDE {
        square = square.resize_exact(
            THUMBNAIL_SIDE,
            THUMBNAIL_SIDE,
            image::imageops::FilterType::Triangle,
        );
    }
    let mut png = Cursor::new(Vec::new());
    if square.write_to(&mut png, image::ImageFormat::Png).is_err() {
        return String::new();
    }
    format!(
        "data:image/png;base64,{}",
        STANDARD.encode(png.into_inner())
    )
}

/// How many bytes `encoded` (standard base64, padded) holds, without
/// decoding a screenshot to count them.
fn decoded_len(encoded: &str) -> usize {
    let encoded = encoded.trim_end();
    let padding = encoded
        .bytes()
        .rev()
        .take_while(|&b| b == b'=')
        .count()
        .min(2);
    (encoded.len() / 4 * 3).saturating_sub(padding)
}

/// What the composer shows of each: {id, name, kind, status, error,
/// source}, `source` being a Snap Shot's {appName, windowTitle,
/// accessibility}, the last what its window said of itself; with
/// `previews`, each image's thumbnail as `preview`.
pub(super) fn shown_attachments(
    attachments: &[Attachment],
    previews: Option<&HashMap<String, String>>,
) -> Vec<Json> {
    attachments
        .iter()
        .map(|attachment| {
            let mut entry = json!({
                "id": attachment.id,
                "name": attachment.name,
                "kind": if attachment.file { "file" } else { "image" },
                "status": attachment.upload,
                "error": attachment.error,
                "source": snap_shot(&attachment.source),
            });
            if let Some(previews) = previews
                && !attachment.file
            {
                entry["preview"] = json!(previews.get(&attachment.id).cloned().unwrap_or_default());
            }
            entry
        })
        .collect()
}

/// A Snap Shot's source as the chip shows it; null for anything else.
fn snap_shot(source: &Obj) -> Json {
    if field(source, "kind") != "snap-shot" {
        return Json::Null;
    }
    // The text the window said of itself, else its element tree when any
    // element has a name or value.
    let accessibility = as_object(source.get("accessibility").unwrap_or(&Json::Null));
    let mut said = if field(accessibility, "format") == "flat-text" {
        field(accessibility, "text").trim().to_owned()
    } else {
        field(source, "accessibleText").trim().to_owned()
    };
    fn readable(node: &Obj) -> bool {
        !field(node, "name").is_empty()
            || !field(node, "value").is_empty()
            || node
                .get("children")
                .and_then(Json::as_array)
                .into_iter()
                .flatten()
                .any(|child| readable(as_object(child)))
    }
    if said.is_empty() && readable(as_object(accessibility.get("root").unwrap_or(&Json::Null))) {
        said = serde_json::to_string_pretty(accessibility).unwrap_or_default();
    }
    if said.is_empty() {
        said = if accessibility.is_empty() {
            "The app or capture backend did not provide verified accessibility data."
        } else {
            "Structured accessibility elements were included, but they have no readable names or values."
        }
        .to_owned();
    }
    json!({
        "appName": field(source, "appName"),
        "windowTitle": field(source, "windowTitle"),
        "accessibility": said,
    })
}

/// ChatImageAttachment for each image, as `assets.persistChatAttachments`
/// stores them.
pub(super) fn image_records(attachments: &[Attachment]) -> Vec<Json> {
    attachments
        .iter()
        .filter(|a| !a.file)
        .map(|attachment| {
            let mut image = json!({
                "type": "image",
                "name": attachment.name,
                "mimeType": attachment.mime_type,
                "sizeBytes": attachment.size_bytes,
                "dataUrl": attachment.data_url,
            });
            if !attachment.source.is_empty() {
                image["source"] = Json::Object(attachment.source.clone());
            }
            image
        })
        .collect()
}

/// ChatFileAttachment for each uploaded file.
pub(super) fn file_records(attachments: &[Attachment]) -> Vec<Json> {
    attachments
        .iter()
        .filter(|a| a.file)
        .map(|attachment| {
            let mut file = json!({
                "type": "file",
                "id": attachment.remote_id,
                "name": attachment.name,
                "mimeType": attachment.mime_type,
                "sizeBytes": attachment.size_bytes,
            });
            if attachment.pasted_text {
                file["source"] = json!({"_tag": "pasted-text"});
            }
            file
        })
        .collect()
}

/// An image (a snapshot) joins `target`'s draft.
pub(super) fn attach_image(
    engine: &Engine,
    target: &str,
    name: &str,
    mime_type: &str,
    bytes: &[u8],
    source: Obj,
) {
    if target.is_empty() {
        return;
    }
    let image = Attachment {
        id: uuid(),
        name: name.to_owned(),
        mime_type: mime_type.to_owned(),
        size_bytes: bytes.len() as i64,
        data_url: format!("data:{mime_type};base64,{}", STANDARD.encode(bytes)),
        source,
        ..Attachment::default()
    };
    kept::edit_draft(engine, target, |kept| kept.attachments.push(image));
    kept::save(engine);
}

/// The most of a file a viewer reads.
const PREVIEW_BYTES: u64 = 1024 * 1024;

/// A kept attachment for a viewer: {id, name, mimeType, url (an image's
/// data URL), text (a file's, when it reads as text)}.
pub(super) fn preview(engine: &Engine, id: &str) -> Option<Json> {
    let attachment = kept::find_attachment(engine, id)?;
    let mut shown = json!({
        "id": attachment.id,
        "name": attachment.name,
        "mimeType": attachment.mime_type,
    });
    if !attachment.file {
        shown["url"] = json!(attachment.data_url);
        return Some(shown);
    }
    let bytes = if attachment.path.is_empty() {
        attachment.content
    } else {
        let mut head = Vec::new();
        if let Ok(file) = std::fs::File::open(&attachment.path) {
            let _ = file.take(PREVIEW_BYTES).read_to_end(&mut head);
        }
        head
    };
    if !bytes.is_empty() && !bytes.contains(&0) {
        shown["text"] = json!(String::from_utf8_lossy(&bytes));
    }
    Some(shown)
}

impl Composer {
    /// What the brick read from disk or the clipboard joins the route's
    /// draft: an image as its bytes, any other file by its path, a pasted
    /// text as itself. Files go to the MC at once.
    pub(super) fn attach(&mut self, engine: &Engine, files: &[Json]) -> bool {
        let target = self.target(engine);
        if target.is_empty() {
            return true;
        }
        let environment_id = self.environment_of(engine, &target);
        let mut added = Vec::new();
        let mut pastes = Vec::new();
        let mac = Keymap::of(engine).mac();
        kept::edit_draft(engine, &target, |kept| {
            for file in files {
                let name = string(file, "name");
                let mime_type = string(file, "mimeType");
                if let Some(encoded) = file.get("base64").and_then(Json::as_str) {
                    let size = decoded_len(encoded);
                    kept.attachments.push(Attachment {
                        id: uuid(),
                        name,
                        data_url: format!("data:{mime_type};base64,{encoded}"),
                        mime_type,
                        size_bytes: size as i64,
                        ..Attachment::default()
                    });
                    continue;
                }
                let mut attachment = Attachment {
                    id: uuid(),
                    name,
                    mime_type: if mime_type.is_empty() {
                        "application/octet-stream".into()
                    } else {
                        mime_type
                    },
                    file: true,
                    ..Attachment::default()
                };
                if let Some(pasted) = file.get("text").and_then(Json::as_str) {
                    attachment.content = pasted.as_bytes().to_vec();
                    attachment.pasted_text = true;
                    attachment.mime_type = "text/plain".into();
                    attachment.size_bytes = attachment.content.len() as i64;
                    // nextPastedTextFileName: pasted-text.txt, then
                    // pasted-text-2.txt, ...
                    let taken = |candidate: &str| {
                        kept.attachments
                            .iter()
                            .any(|other| other.name.to_lowercase() == candidate.to_lowercase())
                    };
                    attachment.name = "pasted-text.txt".into();
                    let mut n = 2;
                    while taken(&attachment.name) {
                        attachment.name = format!("pasted-text-{n}.txt");
                        n += 1;
                    }
                    pastes.push((attachment.name.clone(), attachment.size_bytes));
                } else {
                    attachment.path = string(file, "path");
                    attachment.size_bytes =
                        std::fs::metadata(&attachment.path).map_or(0, |m| m.len() as i64);
                }
                added.push(attachment.id.clone());
                kept.attachments.push(attachment);
            }
        });
        for (name, size) in pastes {
            toast(
                engine,
                "info",
                &format!("Large paste attached as {name}"),
                &format!(
                    "{} · Use {} to keep a large paste inline.",
                    text::data_size(size),
                    if mac { "⌘⇧V" } else { "Ctrl+Shift+V" }
                ),
            );
        }
        kept::save(engine);
        self.publish(engine);
        for id in added {
            self.upload_file(engine, &id, &environment_id);
        }
        true
    }

    /// The same for the answer to a question: `question_id`, else the first
    /// of the request that takes a typed answer. A question of fixed choices
    /// takes none.
    pub(super) fn attach_to_answer(
        &mut self,
        engine: &Engine,
        request_id: &str,
        question_id: &str,
        files: &[Json],
    ) -> bool {
        let turn = self.turn_state(engine);
        let Some(request) = turn["questions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|entry| entry["requestId"] == request_id)
        else {
            return true;
        };
        let mut question_id = question_id.to_owned();
        let mut accepts = false;
        for question in request["questions"].as_array().into_iter().flatten() {
            if !question["allowCustomAnswer"].as_bool().unwrap_or(false) {
                continue;
            }
            let id = question["id"].as_str().unwrap_or_default();
            if question_id.is_empty() {
                question_id = id.to_owned();
            }
            if question_id == id {
                accepts = true;
            }
        }
        if !accepts {
            toast_error(engine, "This question cannot accept attachments.", "");
            return true;
        }
        let environment_id = self.environment_of(engine, &self.thread.clone());
        let mut added = Vec::new();
        let mut attached = Vec::new();
        for file in files {
            let mime_type = string(file, "mimeType");
            let mut attachment = Attachment {
                id: uuid(),
                name: string(file, "name"),
                mime_type: if mime_type.is_empty() {
                    "application/octet-stream".into()
                } else {
                    mime_type
                },
                file: true,
                ..Attachment::default()
            };
            if let Some(encoded) = file.get("base64").and_then(Json::as_str) {
                attachment.content = STANDARD.decode(encoded).unwrap_or_default();
                attachment.size_bytes = attachment.content.len() as i64;
            } else if let Some(pasted) = file.get("text").and_then(Json::as_str) {
                attachment.content = pasted.as_bytes().to_vec();
                attachment.size_bytes = attachment.content.len() as i64;
            } else {
                attachment.path = string(file, "path");
                attachment.size_bytes =
                    std::fs::metadata(&attachment.path).map_or(0, |m| m.len() as i64);
            }
            added.push(attachment.id.clone());
            attached.push(attachment);
        }
        kept::write(engine, |d| {
            d.answer_files
                .entry(request_id.to_owned())
                .or_default()
                .entry(question_id.clone())
                .or_default()
                .extend(attached);
        });
        self.publish(engine);
        for id in added {
            self.upload_file(engine, &id, &environment_id);
        }
        true
    }

    /// A folder is named by its path, which only means something where the
    /// MC shares this machine's disk.
    pub(super) fn attach_folders(&mut self, engine: &Engine, target: &str, folders: &[Json]) {
        if !self.bridge.local_folders(engine)
            || self.environment_of(engine, target) != self.mc.environment()
        {
            toast_error(
                engine,
                "Folders can't be dropped into remote environments",
                "Type the folder path with @ instead.",
            );
            return;
        }
        let mut text = kept::draft(engine, target);
        for folder in folders {
            if text.chars().last().is_some_and(|c| !c.is_whitespace()) {
                text.push(' ');
            }
            text.push_str(&model::path_link(folder.as_str().unwrap_or_default()));
        }
        self.set_text_end(engine, target, &text);
    }

    /// `attachments.createUploadUrl`, then the bytes to the URL it answers
    /// with; the message later names the upload, and the MC moves it into
    /// the thread. A file on disk is read on the compute pool first.
    pub(super) fn upload_file(&mut self, engine: &Engine, id: &str, environment_id: &str) {
        let started = with_attachment(engine, id, |attachment| {
            attachment.upload = "uploading".into();
            attachment.error.clear();
            attachment.remote_id.clear();
            attachment.environment_id = environment_id.to_owned();
            (
                attachment.name.clone(),
                attachment.mime_type.clone(),
                attachment.path.clone(),
                attachment.content.clone(),
            )
        });
        let Some((name, mime_type, path, content)) = started else {
            return;
        };
        self.publish(engine);
        let file = File {
            id: id.to_owned(),
            environment_id: environment_id.to_owned(),
            name,
            mime_type,
        };
        if path.is_empty() {
            self.upload_bytes(file, content);
            return;
        }
        self.generation += 1;
        let generation = self.generation;
        self.reading.insert(file.id.clone(), generation);
        let me = self.me.clone();
        let on_pool = path.clone();
        let read_file = file.clone();
        let spawned = ljos::task::spawn(
            engine,
            move || std::fs::read(on_pool).ok(),
            move |engine, read| {
                let file = read_file;
                later(&me, engine, move |c, engine| {
                    // Read again since, as a retry does.
                    if c.reading.get(&file.id) != Some(&generation) {
                        return;
                    }
                    c.reading.remove(&file.id);
                    // Removed while it was read.
                    if kept::find_attachment(engine, &file.id).is_none() {
                        return;
                    }
                    match read.ok().flatten() {
                        Some(bytes) => c.upload_bytes(file, bytes),
                        None => {
                            let why = format!("{} could not be read.", file.name);
                            c.upload_failed(engine, &file.id, &why);
                        }
                    }
                });
            },
        );
        if spawned.is_err() {
            // The pool is full: read here, once.
            self.reading.remove(id);
            match std::fs::read(&path) {
                Ok(bytes) => self.upload_bytes(file, bytes),
                Err(_) => {
                    let why = format!("{} could not be read.", file.name);
                    self.upload_failed(engine, id, &why);
                }
            }
        }
    }

    /// The bytes of `file` to the MC.
    fn upload_bytes(&mut self, file: File, bytes: Vec<u8>) {
        let File {
            id,
            environment_id,
            name,
            mime_type,
        } = file;
        self.mc.call(
            &environment_id,
            "attachments.createUploadUrl",
            json!({"type": "file", "name": name, "mimeType": mime_type, "sizeBytes": bytes.len()}),
            back(&self.me, move |c, engine, result| {
                let (url, remote_id) = match &result {
                    Ok(answer) => (
                        answer["relativeUrl"]
                            .as_str()
                            .unwrap_or_default()
                            .to_owned(),
                        answer["attachmentId"]
                            .as_str()
                            .unwrap_or_default()
                            .to_owned(),
                    ),
                    Err(_) => (String::new(), String::new()),
                };
                if url.is_empty() || remote_id.is_empty() {
                    let why = match result {
                        Err(error) => error.message,
                        Ok(_) => "The environment did not take the upload.".into(),
                    };
                    c.upload_failed(engine, &id, &why);
                    return;
                }
                c.mc.upload(
                    &url,
                    bytes,
                    &mime_type,
                    back(&c.me, move |c, engine, result| {
                        if let Err(error) = result {
                            c.upload_failed(engine, &id, &error.message);
                            return;
                        }
                        with_attachment(engine, &id, |attachment| {
                            attachment.upload.clear();
                            attachment.remote_id = remote_id;
                        });
                        kept::save(engine);
                        c.publish(engine);
                    }),
                );
            }),
        );
    }

    fn upload_failed(&mut self, engine: &Engine, id: &str, why: &str) {
        with_attachment(engine, id, |attachment| {
            attachment.upload = "failed".into();
            attachment.error = why.to_owned();
        });
        kept::save(engine);
        self.publish(engine);
    }

    /// Send guards: nothing leaves while a file is still on its way, or
    /// after one failed.
    pub(super) fn files_block(
        &self,
        engine: &Engine,
        attachments: &[Attachment],
        what: &str,
    ) -> bool {
        let failed = attachments.iter().any(|a| a.upload == "failed");
        let uploading = attachments.iter().any(|a| a.upload == "uploading");
        if failed {
            toast_error(
                engine,
                &format!("Retry or remove failed uploads before {what}."),
                "",
            );
        } else if uploading {
            toast(
                engine,
                "warning",
                "Wait for attachments to finish uploading, or remove failed uploads.",
                "",
            );
        }
        failed || uploading
    }

    /// The selection's text without CRs or blank edges, and a valid line
    /// range; a selection with no text, terminal or label adds nothing.
    pub(super) fn add_terminal_context(&mut self, engine: &Engine, selection: &Json) -> bool {
        let target = self.target(engine);
        if target.is_empty() {
            return true;
        }
        let text = string(selection, "text").replace("\r\n", "\n");
        let text = text.trim_matches('\n').to_owned();
        let terminal_id = string(selection, "terminalId").trim().to_owned();
        let terminal_label = string(selection, "terminalLabel").trim().to_owned();
        if text.is_empty() || terminal_id.is_empty() || terminal_label.is_empty() {
            return true;
        }
        let line_start = (text::number(&selection["lineStart"]).floor() as i64).max(1);
        let line_end = (text::number(&selection["lineEnd"]).floor() as i64).max(line_start);
        kept::edit_draft(engine, &target, |kept| {
            kept.excerpts.push(Excerpt {
                id: uuid(),
                terminal_id,
                terminal_label,
                line_start,
                line_end,
                text,
                ..Excerpt::default()
            });
        });
        self.publish(engine);
        true
    }

    /// A quote the composer holds: one selection of one reply of the thread
    /// it is on, within the citation's limits (AssistantCitation); anything
    /// else adds nothing.
    pub(super) fn add_citation(&mut self, engine: &Engine, selection: &Json) -> bool {
        let target = self.target(engine);
        let Some(thread) = thread_of(engine, &target) else {
            return true;
        };
        let message_id = string(selection, "messageId");
        let quoted = string(selection, "text");
        let start = text::number(&selection["start"]) as i64;
        let end = text::number(&selection["end"]) as i64;
        if message_id.is_empty()
            || quoted.trim().is_empty()
            || model::utf16_len(&quoted) > MAX_CITATION_LENGTH
            || start < 0
            || end <= start
        {
            return true;
        }
        let citation = json!({
            "version": 1,
            "environmentId": thread.environment_id,
            "threadId": thread.id,
            "messageId": message_id,
            "text": quoted,
            "start": start,
            "end": end,
            "prefix": right(&string(selection, "prefix"), CITATION_CONTEXT_LENGTH),
            "suffix": left(&string(selection, "suffix"), CITATION_CONTEXT_LENGTH),
        });
        kept::edit_draft(engine, &target, |kept| {
            kept.excerpts.push(Excerpt {
                id: uuid(),
                citation: as_object(&citation).clone(),
                ..Excerpt::default()
            });
        });
        self.publish(engine);
        true
    }

    /// A note on lines of a diff (COMPOSER_CONTEXT_REVIEW_TEXT_MAX_CHARS and
    /// _DIFF_MAX_CHARS bound it).
    pub(super) fn add_review_comment(&mut self, engine: &Engine, comment: &Json) -> bool {
        let target = self.target(engine);
        if target.is_empty() {
            return true;
        }
        let file_path = string(comment, "filePath").trim().to_owned();
        let note = left(string(comment, "text").trim(), 16000).to_owned();
        if file_path.is_empty() || note.is_empty() {
            return true;
        }
        let first = (text::number(&comment["lineStart"]) as i64).max(1);
        let last = (text::number(&comment["lineEnd"]) as i64).max(first);
        let or = |key: &str, otherwise: &str| match comment.get(key).and_then(Json::as_str) {
            Some(value) => value.to_owned(),
            None => otherwise.to_owned(),
        };
        let review = json!({
            "filePath": file_path,
            "sectionId": or("sectionId", "diff"),
            "sectionTitle": or("sectionTitle", "Diff"),
            "startIndex": text::number(&comment["startIndex"]) as i64,
            "endIndex": text::number(&comment["endIndex"]) as i64,
            "rangeLabel": string(comment, "rangeLabel"),
            "diff": left(&string(comment, "diff"), 32000),
        });
        kept::edit_draft(engine, &target, |kept| {
            kept.excerpts.push(Excerpt {
                id: uuid(),
                line_start: first,
                line_end: last,
                text: note,
                review: as_object(&review).clone(),
                ..Excerpt::default()
            });
        });
        self.publish(engine);
        toast(
            engine,
            "success",
            "Comment added to the prompt",
            &text::review_label(&file_path, first, last),
        );
        true
    }
}

/// A file on its way to the MC.
#[derive(Clone)]
struct File {
    id: String,
    environment_id: String,
    name: String,
    mime_type: String,
}

/// Changes the kept attachment `id`, a draft's or a question's answer's.
fn with_attachment<R>(
    engine: &Engine,
    id: &str,
    f: impl FnOnce(&mut Attachment) -> R,
) -> Option<R> {
    kept::write(engine, |d| {
        d.drafts
            .values_mut()
            .flat_map(|k| k.attachments.iter_mut())
            .chain(
                d.answer_files
                    .values_mut()
                    .flat_map(|q| q.values_mut().flatten()),
            )
            .find(|a| a.id == id)
            .map(f)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_decoded_length_is_counted_from_the_encoding() {
        for bytes in [&b""[..], b"a", b"ab", b"abc", b"abcd", &[0u8; 1000]] {
            assert_eq!(decoded_len(&STANDARD.encode(bytes)), bytes.len());
        }
    }
}
