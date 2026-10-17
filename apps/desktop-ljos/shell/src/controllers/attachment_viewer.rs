//! desktop-qt's AttachmentViewerController: an attachment of the draft
//! opened to look at, an image large, Markdown rendered or as its source,
//! any other text as text, and what cannot be shown named as such.
//!
//! Publishes `attachmentViewer`, null while closed: {id, name, mimeType,
//! kind (image | markdown | text | unsupported), url, text, origin
//! ("Draft")}. Actions: `attachment.view {id}` (a draft attachment's),
//! `attachment.viewer.close`, and `attachment.viewer.remove`, which takes
//! the attachment off its draft and closes. The viewer closes when its
//! attachment leaves the draft any other way (sent, removed from its chip).

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::composer;
use crate::json::Json;

const KEY: &str = "attachmentViewer";
const MARKDOWN: [&str; 5] = ["md", "markdown", "mdown", "mkd", "mdx"];

pub struct AttachmentViewer {
    bridge: Bridge,
    me: Me<Self>,
    active: bool,
    viewing: String,
}

/// What the viewer draws a preview as.
pub fn kind_of(preview: &Json) -> &'static str {
    let mime = preview["mimeType"]
        .as_str()
        .unwrap_or_default()
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    let name = preview["name"].as_str().unwrap_or_default().to_lowercase();
    let extension = name.rsplit_once('.').map(|(_, e)| e).unwrap_or_default();
    let url = preview["url"].as_str().unwrap_or_default();
    if mime.starts_with("image/") && !url.is_empty() {
        return "image";
    }
    // A PDF, a video or anything binary came with no text this machine can
    // show.
    if mime == "application/pdf" || extension == "pdf" || preview.get("text").is_none() {
        return "unsupported";
    }
    if mime == "text/markdown" || mime == "text/x-markdown" || MARKDOWN.contains(&extension) {
        return "markdown";
    }
    "text"
}

impl Controller for AttachmentViewer {
    fn new(init: Init<'_, Self>) -> Self {
        AttachmentViewer {
            bridge: init.bridge,
            me: init.me,
            active: false,
            viewing: String::new(),
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
            "attachment.view" => {
                let id = payload["id"].as_str().unwrap_or_default();
                let Some(mut preview) = composer::attachment_preview(engine, id) else {
                    return true;
                };
                self.viewing = preview["id"].as_str().unwrap_or_default().to_owned();
                preview["kind"] = json!(kind_of(&preview));
                preview["origin"] = json!("Draft");
                self.bridge.publish(engine, KEY, preview);
            }
            "attachment.viewer.close" => self.close(engine),
            "attachment.viewer.remove" => {
                let id = std::mem::take(&mut self.viewing);
                self.bridge.publish(engine, KEY, Json::Null);
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
    fn close(&mut self, engine: &Engine) {
        if self.viewing.is_empty() {
            return;
        }
        self.viewing.clear();
        self.bridge.publish(engine, KEY, Json::Null);
    }
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
                &json!({"name": "a.pdf", "mimeType": "application/octet-stream", "text": "%PDF"})
            ),
            "unsupported"
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
    }
}
