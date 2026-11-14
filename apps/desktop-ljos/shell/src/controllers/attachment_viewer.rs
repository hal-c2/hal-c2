//! desktop-qt's AttachmentViewerController: an attachment opened to look
//! at, of the draft or of a sent message: an image large, a video or audio
//! played, a PDF paged through, Markdown, a table or a page rendered or as
//! its source, any other text as text, and what cannot be shown named as
//! such.
//!
//! Publishes `attachmentViewer`, null while closed: {id, name, kind (image |
//! video | audio | document | markdown | table | page | text | unsupported |
//! loading | failed), url, text, rendered (a table's Markdown), origin
//! ("Draft" | "Sent"), removable, truncated (text stops at the preview
//! limit), problem (why it failed), source (a page's text, fetched when
//! asked for), sourceProblem}. Actions: `attachment.view {id}` (a draft
//! attachment's), `attachment.sent.view {id, name, mimeType}` (of the active
//! thread), `attachment.viewer.retry`, `.mediaFailed` (a player could not
//! play it), `.source` (a page's source, fetched again with a fresh
//! address), `.copy`, `.save`, `.close`, and `.remove`, which takes the
//! attachment off its draft and closes. The viewer closes when its draft
//! attachment leaves the draft any other way (sent, removed from its chip).

use std::path::{Path, PathBuf};
use std::rc::Rc;

use base64::Engine as _;
use ljos::prelude::{Engine, Location, PathEnv};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::composer;
use crate::controllers::navigation::{self, Route};
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::Mc;
use crate::thread_view::{file_render, workspace_files};

const KEY: &str = "attachmentViewer";
const MARKDOWN: [&str; 5] = ["md", "markdown", "mdown", "mkd", "mdx"];
/// A viewer shows the first megabyte of a text.
const PREVIEW_LIMIT: usize = 1024 * 1024;

pub struct AttachmentViewer {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Self>,
    active: bool,
    viewing: String,
    /// The sent attachment on show: {environment, id, name, mimeType};
    /// null for a draft's.
    sent: Json,
    shown: Json,
    /// The temp file holding a document, removed when replaced.
    document: Option<PathBuf>,
    /// Where a save puts its file; the user's Downloads unless tests say.
    save_folder: Option<PathBuf>,
    /// Answers to anything but the latest request are for a viewer since
    /// closed.
    request: u64,
}

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or("")
}

fn mime_of(preview: &Json) -> String {
    text(preview, "mimeType")
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_lowercase()
}

/// video, audio or document when that is what a preview holds; else empty.
fn media_kind(preview: &Json) -> &'static str {
    let mime = mime_of(preview);
    if mime.starts_with("video/") {
        return "video";
    }
    if mime.starts_with("audio/") {
        return "audio";
    }
    if mime == "application/pdf" {
        return "document";
    }
    match workspace_files::media_kind_of(text(preview, "name")) {
        "pdf" => "document",
        kind @ ("video" | "audio") => kind,
        _ => "",
    }
}

/// What the viewer draws a preview as.
pub fn kind_of(preview: &Json) -> &'static str {
    let mime = mime_of(preview);
    let name = text(preview, "name").to_lowercase();
    let extension = name.rsplit_once('.').map_or("", |(_, e)| e);
    let url = text(preview, "url");
    if mime.starts_with("image/") && !url.is_empty() {
        return "image";
    }
    let media = media_kind(preview);
    if !media.is_empty() {
        return if url.is_empty() { "unsupported" } else { media };
    }
    if preview.get("text").is_none() {
        return "unsupported";
    }
    if file_render::preview_delimiter(&name, &mime).is_some() {
        return "table";
    }
    if mime == "text/html" || extension == "html" || extension == "htm" {
        return "page";
    }
    if mime == "text/markdown" || mime == "text/x-markdown" || MARKDOWN.contains(&extension) {
        return "markdown";
    }
    "text"
}

/// The first megabyte of `bytes` as text, cut between characters.
fn whole_text(bytes: &[u8]) -> String {
    let mut kept = &bytes[..bytes.len().min(PREVIEW_LIMIT)];
    while bytes.len() > PREVIEW_LIMIT && !kept.is_empty() && bytes[kept.len()] & 0xC0 == 0x80 {
        kept = &kept[..kept.len() - 1];
    }
    String::from_utf8_lossy(kept).into_owned()
}

fn valid_text(bytes: &[u8]) -> bool {
    std::str::from_utf8(bytes).is_ok() && !bytes.contains(&0)
}

/// `text` with no line longer than a window could usefully wrap.
fn broken_for_display(text: &str) -> String {
    const LONGEST: usize = 2000;
    if text.chars().count() <= LONGEST {
        return text.to_owned();
    }
    let mut broken = String::with_capacity(text.len() + text.len() / LONGEST);
    let mut run = 0usize;
    for c in text.chars() {
        if c == '\n' {
            run = 0;
        } else {
            run += 1;
            if run > LONGEST {
                broken.push('\n');
                run = 1;
            }
        }
        broken.push(c);
    }
    broken
}

type Fetched = Box<dyn FnOnce(&mut AttachmentViewer, &Engine, Vec<u8>, String, String)>;

impl Controller for AttachmentViewer {
    fn new(init: Init<'_, Self>) -> Self {
        AttachmentViewer {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            viewing: String::new(),
            sent: Json::Null,
            shown: Json::Null,
            document: None,
            save_folder: None,
            request: 0,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        // The attachment went from its draft: nothing is left to look at.
        // The composer publishes while it runs, so this waits for it.
        let me = self.me.clone();
        self.bridge.watch(engine, "composer", move |engine, _| {
            let me = me.clone();
            Bridge::of(engine).defer(engine, move |engine| {
                me.run(engine, |c, engine| {
                    if !c.viewing.is_empty()
                        && c.sent.is_null()
                        && composer::attachment_preview(engine, &c.viewing).is_none()
                    {
                        c.close(engine);
                    }
                });
            });
        });
        self.bridge.publish(engine, KEY, Json::Null);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        match action {
            "attachment.view" => self.view(engine, payload),
            "attachment.sent.view" => {
                let Route::Thread(thread) = navigation::shown(engine) else {
                    return true;
                };
                if thread.is_empty() {
                    return true;
                }
                self.viewing = text(payload, "id").to_owned();
                let mut sent = payload.clone();
                sent["environment"] = json!(thread.split(':').next().unwrap_or_default());
                self.sent = sent;
                self.open_sent(engine);
            }
            "attachment.viewer.retry" => {
                if !self.sent.is_null() {
                    self.open_sent(engine);
                } else if !self.viewing.is_empty() {
                    let id = self.viewing.clone();
                    self.view(engine, &json!({"id": id}));
                }
            }
            "attachment.viewer.source" => self.source(engine),
            "attachment.viewer.mediaFailed" => {
                let mut shown = self.shown.clone();
                shown["kind"] = json!("failed");
                shown["problem"] = json!("The attachment is unavailable.");
                self.show(engine, shown);
            }
            "attachment.viewer.copy" => {
                let text = text(&self.shown, "text").to_owned();
                self.bridge.copy_to_clipboard(engine, &text);
            }
            "attachment.viewer.save" => self.save(engine),
            "attachment.viewer.close" => self.close(engine),
            "attachment.viewer.remove" => {
                let id = if self.sent.is_null() {
                    self.viewing.clone()
                } else {
                    String::new()
                };
                self.close(engine);
                if !id.is_empty() {
                    self.bridge
                        .dispatch(engine, "composer.attachment.remove", json!({"id": id}));
                }
            }
            _ => return false,
        }
        true
    }
}

impl AttachmentViewer {
    /// Where a save puts its file; the user's Downloads unless a scenario
    /// says.
    pub fn set_save_folder(&mut self, folder: Option<PathBuf>) {
        self.save_folder = folder;
    }

    fn close(&mut self, engine: &Engine) {
        self.request += 1;
        if self.viewing.is_empty() {
            return;
        }
        self.viewing.clear();
        self.sent = Json::Null;
        self.shown = Json::Null;
        self.bridge.publish(engine, KEY, Json::Null);
    }

    fn show(&mut self, engine: &Engine, preview: Json) {
        self.shown = preview.clone();
        // Laying out one enormous line freezes the window; copying still
        // takes the original.
        let mut shown = preview;
        for field in ["text", "source"] {
            if let Some(value) = shown.get(field).and_then(Json::as_str) {
                shown[field] = json!(broken_for_display(value));
            }
        }
        self.bridge.publish(engine, KEY, shown);
    }

    /// A local copy of a document, the one thing Qt PDF opens, held while
    /// it shows.
    fn keep_document(&mut self, bytes: &[u8]) -> String {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("hal-c2-{}-{n}.pdf", std::process::id()));
        if std::fs::write(&path, bytes).is_err() {
            return String::new();
        }
        if let Some(old) = self.document.replace(path.clone())
            && old != path
        {
            let _ = std::fs::remove_file(old);
        }
        format!("file://{}", path.display())
    }

    fn view(&mut self, engine: &Engine, payload: &Json) {
        let Some(mut preview) = composer::attachment_preview(engine, text(payload, "id")) else {
            return;
        };
        self.viewing = text(&preview, "id").to_owned();
        self.sent = Json::Null;
        self.request += 1;
        // What a draft's player or document view reads: the picked file.
        let media = media_kind(&preview);
        let path = text(&preview, "path").to_owned();
        if let Json::Object(map) = &mut preview {
            map.remove("path");
        }
        if !media.is_empty() && !path.is_empty() {
            if media == "document" {
                let bytes = std::fs::read(&path).unwrap_or_default();
                let url = self.keep_document(&bytes);
                preview["url"] = json!(url);
            } else {
                preview["url"] = json!(format!("file://{path}"));
            }
        }
        let kind = kind_of(&preview);
        preview["kind"] = json!(kind);
        preview["origin"] = json!("Draft");
        preview["removable"] = json!(true);
        if kind == "table"
            && let Some(delimiter) =
                file_render::preview_delimiter(text(&preview, "name"), &mime_of(&preview))
        {
            preview["rendered"] = json!(file_render::markdown_table(
                text(&preview, "text"),
                delimiter
            ));
        }
        self.show(engine, preview);
    }

    fn sign(
        &self,
        done: impl FnOnce(&mut AttachmentViewer, &Engine, String, String, String) + 'static,
    ) {
        let sent = self.sent.clone();
        let me = self.me.clone();
        self.mc.call(
            text(&sent, "environment"),
            "assets.createUrl",
            json!({"resource": {
                "_tag": "attachment",
                "attachmentId": text(&sent, "id"),
                "fileName": text(&sent, "name"),
                "mimeType": text(&sent, "mimeType"),
            }}),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    let relative = result
                        .as_ref()
                        .ok()
                        .map(|created| text(created, "relativeUrl").to_owned())
                        .unwrap_or_default();
                    let error = result.err().map(|e| e.message);
                    if error.is_some() || relative.is_empty() {
                        let said = error
                            .filter(|said| !said.is_empty())
                            .unwrap_or_else(|| "The attachment is unavailable.".to_owned());
                        let problem = if said.starts_with("not connected")
                            || said.ends_with(" is not connected.")
                        {
                            "Reconnect to the environment and try again."
                        } else {
                            "The attachment is unavailable."
                        };
                        return done(c, engine, String::new(), problem.to_owned(), said);
                    }
                    done(c, engine, relative, String::new(), String::new());
                });
            }),
        );
    }

    /// Signs an address anew and reads it, so a viewer open for an hour
    /// still reaches the MC.
    fn fetch(&mut self, done: Fetched) {
        self.request += 1;
        self.read(self.request, done);
    }

    /// The same read, for one thing that outlives the viewer's own: with
    /// `request` 0 no later request drops it, and otherwise `request` must
    /// still be the latest.
    fn read(&self, request: u64, done: Fetched) {
        let mut done = Some(done);
        self.sign(move |c, engine, relative, problem, reason| {
            if request != 0 && request != c.request {
                return;
            }
            let Some(done) = done.take() else {
                return;
            };
            if !problem.is_empty() {
                return done(c, engine, Vec::new(), problem, reason);
            }
            let me = c.me.clone();
            c.mc.download(
                &relative,
                Box::new(move |engine, result| {
                    me.run(engine, move |c, engine| {
                        if request != 0 && request != c.request {
                            return;
                        }
                        match result {
                            Ok(bytes) => done(c, engine, bytes, String::new(), String::new()),
                            Err(error) => {
                                // Without an HTTP answer the MC said
                                // nothing about the file.
                                let problem = if error.message.starts_with("HTTP ") {
                                    "The attachment is unavailable."
                                } else {
                                    "Reconnect to the environment and try again."
                                };
                                done(c, engine, Vec::new(), problem.to_owned(), error.message);
                            }
                        }
                    });
                }),
            );
        });
    }

    fn open_sent(&mut self, engine: &Engine) {
        let shown = json!({
            "id": text(&self.sent, "id"),
            "name": text(&self.sent, "name"),
            "mimeType": text(&self.sent, "mimeType"),
            "origin": "Sent",
            "kind": "loading",
        });
        self.show(engine, shown.clone());
        let media = media_kind(&shown);
        // A player streams what it plays, from an address, rather than
        // holding it here.
        if media == "video" || media == "audio" {
            self.request += 1;
            let request = self.request;
            self.sign(move |c, engine, relative, problem, _reason| {
                if request != c.request {
                    return;
                }
                if !problem.is_empty() {
                    let mut told = shown.clone();
                    told["kind"] = json!("failed");
                    told["problem"] = json!(problem);
                    return c.show(engine, told);
                }
                let mut preview = shown.clone();
                let origin = c.mc.origin().unwrap_or_default();
                preview["url"] = json!(crate::thread_view::workspace_files::resolved(
                    &origin, &relative
                ));
                preview["kind"] = json!(media);
                c.show(engine, preview);
            });
            return;
        }
        self.fetch(Box::new(move |c, engine, bytes, problem, _reason| {
            if !problem.is_empty() {
                let mut told = shown.clone();
                told["kind"] = json!("failed");
                told["problem"] = json!(problem);
                return c.show(engine, told);
            }
            let mut preview = shown.clone();
            let image = mime_of(&shown).starts_with("image/");
            if media_kind(&shown) == "document" {
                let url = c.keep_document(&bytes);
                preview["url"] = json!(url);
            } else if image {
                preview["url"] = json!(format!(
                    "data:{};base64,{}",
                    text(&shown, "mimeType"),
                    base64::engine::general_purpose::STANDARD.encode(&bytes)
                ));
            } else if !bytes.contains(&0) {
                preview["text"] = json!(whole_text(&bytes));
                preview["truncated"] = json!(bytes.len() > PREVIEW_LIMIT);
            }
            let kind = kind_of(&preview);
            preview["kind"] = json!(kind);
            if kind == "table"
                && let Some(delimiter) =
                    file_render::preview_delimiter(text(&shown, "name"), &mime_of(&shown))
            {
                preview["rendered"] = json!(file_render::markdown_table(
                    text(&preview, "text"),
                    delimiter
                ));
            }
            c.show(engine, preview);
        }));
    }

    fn source(&mut self, engine: &Engine) {
        // A draft's page is here already.
        if self.sent.is_null() {
            let mut shown = self.shown.clone();
            shown["source"] = shown.get("text").cloned().unwrap_or(Json::Null);
            self.show(engine, shown);
            return;
        }
        let mut asking = self.shown.clone();
        if let Json::Object(map) = &mut asking {
            map.remove("sourceProblem");
        }
        self.show(engine, asking);
        self.fetch(Box::new(|c, engine, bytes, problem, _reason| {
            let mut shown = c.shown.clone();
            if !problem.is_empty() || !valid_text(&bytes) {
                shown["sourceProblem"] = json!(if problem.is_empty() {
                    "The source could not be loaded.".to_owned()
                } else {
                    problem
                });
            } else {
                shown["source"] = json!(whole_text(&bytes));
            }
            c.show(engine, shown);
        }));
    }

    fn save(&mut self, _engine: &Engine) {
        if self.sent.is_null() {
            return;
        }
        let name = Path::new(text(&self.sent, "name"))
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let folder = self.save_folder.clone();
        // A save does not depend on the viewer: it finishes after a close,
        // and leaves a read under way alone.
        self.read(
            0,
            Box::new(move |_c, engine, bytes, problem, reason| {
                let could_not = format!("Could not save {name}");
                if !problem.is_empty() {
                    let description = if reason.is_empty() {
                        problem
                    } else {
                        format!("{problem} ({reason})")
                    };
                    return toast(engine, "error", &could_not, &description);
                }
                let folder = folder.unwrap_or_else(|| {
                    Location::Download.writable(&PathEnv::from_process(), "", "")
                });
                // A file already there keeps its name and contents.
                let path = free_path(&folder, &name);
                match std::fs::create_dir_all(&folder).and_then(|()| std::fs::write(&path, &bytes))
                {
                    Ok(()) => toast(
                        engine,
                        "success",
                        &format!(
                            "Saved {}",
                            path.file_name()
                                .map(|name| name.to_string_lossy())
                                .unwrap_or_default()
                        ),
                        &path.to_string_lossy(),
                    ),
                    Err(error) => toast(engine, "error", &could_not, &error.to_string()),
                }
            }),
        );
    }
}

fn toast(engine: &Engine, kind: &str, title: &str, description: &str) {
    let (kind, title, description) = (kind.to_owned(), title.to_owned(), description.to_owned());
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.show(e, &kind, &title, &description, None, DEFAULT_TIMEOUT_MS);
        });
    });
}

/// The first of `name`, `name (1)…` not already in `folder`.
fn free_path(folder: &Path, name: &str) -> PathBuf {
    let mut path = folder.join(name);
    let info = Path::new(name);
    let mut copy = 1;
    while path.exists() {
        path = match info.extension().and_then(|suffix| suffix.to_str()) {
            None => folder.join(format!("{name} ({copy})")),
            Some(suffix) => folder.join(format!(
                "{} ({copy}).{suffix}",
                info.file_stem()
                    .map(|stem| stem.to_string_lossy())
                    .unwrap_or_default()
            )),
        };
        copy += 1;
    }
    path
}

#[cfg(test)]
mod tests {
    use super::kind_of;
    use serde_json::json;

    #[test]
    fn kinds() {
        let image = json!({"name": "a.png", "mimeType": "image/png", "url": "data:x"});
        assert_eq!(kind_of(&image), "image");
        // An image whose bytes this machine does not hold has no url.
        assert_eq!(
            kind_of(&json!({"name": "a.png", "mimeType": "image/png"})),
            "unsupported"
        );
        assert_eq!(
            kind_of(
                &json!({"name": "a.pdf", "mimeType": "application/octet-stream", "text": "%PDF", "url": "file:///tmp/a.pdf"})
            ),
            "document"
        );
        assert_eq!(
            kind_of(&json!({"name": "a.bin", "mimeType": "x"})),
            "unsupported"
        );
        assert_eq!(
            kind_of(&json!({"name": "README.MDX", "mimeType": "text/plain", "text": "#"})),
            "markdown"
        );
        assert_eq!(
            kind_of(
                &json!({"name": "notes", "mimeType": "text/markdown; charset=utf-8", "text": "#"})
            ),
            "markdown"
        );
        assert_eq!(
            kind_of(&json!({"name": "a.rs", "mimeType": "text/x-rust", "text": "fn"})),
            "text"
        );
        assert_eq!(
            kind_of(&json!({"name": "a.csv", "mimeType": "text/plain", "text": "a,b"})),
            "table"
        );
        assert_eq!(
            kind_of(&json!({"name": "a.html", "mimeType": "text/plain", "text": "<p>"})),
            "page"
        );
        assert_eq!(
            kind_of(&json!({"name": "a.mp4", "mimeType": "video/mp4", "url": "http://x"})),
            "video"
        );
    }
}
