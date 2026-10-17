//! `rewind`, desktop-qt's RewindController: editing from one of the user's
//! messages ("Edit from here"). The conversation rewinds to before that
//! message, and the message's prompt and attachments return to the composer
//! to be changed and sent again.
//!
//! Publishes `rewind`: null, or `{threadKey, rowId, turn}` while the user is
//! asked whether the files go back too.
//!
//! Actions: `rewind.request {rowId}` (a user message's row of the open
//! thread) asks, or says why it cannot rewind; `rewind.confirm
//! {restoreFiles}` fetches the message's attachments from the MC
//! (`assets.createUrl`, then the bytes), rolls the thread back to the
//! checkpoint before the message (`checkpoint.rollback`), and adds the
//! prompt and the attachments to the thread's draft; `rewind.cancel` drops
//! the question. A rewind that cannot happen changes nothing and says why.

use std::path::Path;
use std::rc::Rc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::composer;
use crate::controllers::navigation::{self, Route};
use crate::controllers::threads;
use crate::controllers::toasts::Toasts;
use crate::controllers::workspace;
use crate::json::Json;
use crate::mc::Mc;
use crate::store;
use crate::thread_view::timeline_model::TimelineModel;

/// packages/contracts PROVIDER_SEND_TURN_MAX_ATTACHMENTS.
const MAX_ATTACHMENTS: usize = 100;

type Obj = serde_json::Map<String, Json>;

pub struct Rewind {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Rewind>,
    active: bool,
    /// The thread and message the user is asked about; empty when not
    /// asked.
    thread: String,
    row: String,
    point: Obj,
    /// A rewind is fetching attachments or waiting for the MC.
    working: bool,
}

fn shown_thread(engine: &Engine) -> String {
    match navigation::shown(engine) {
        Route::Thread(key) => key,
        _ => String::new(),
    }
}

fn refuse(engine: &Engine, why: &str) {
    let why = why.to_owned();
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.error(e, "Could not rewind", &why);
        });
    });
}

fn text<'a>(point: &'a Obj, key: &str) -> &'a str {
    point.get(key).and_then(Json::as_str).unwrap_or("")
}

fn text_of(value: &Json, key: &str) -> String {
    value
        .get(key)
        .and_then(Json::as_str)
        .unwrap_or("")
        .to_owned()
}

/// An attachment as the composer takes it back, from the bytes the MC gave:
/// an image carries them, a file of this machine is written for the next
/// message to send again. `Err` is why a file could not be written.
fn as_file(attachment: &Json, bytes: &[u8]) -> Result<Json, String> {
    let name = text_of(attachment, "name");
    let mut file = json!({"name": name, "mimeType": text_of(attachment, "mimeType")});
    if attachment.get("type").and_then(Json::as_str) == Some("image") {
        file["base64"] = STANDARD.encode(bytes).into();
        return Ok(file);
    }
    // Only the name's last part: the MC's names are not trusted with a path.
    let leaf = Path::new(&name)
        .file_name()
        .map_or_else(|| "attachment".into(), |n| n.to_os_string());
    let folder = std::env::temp_dir()
        .join("hal-c2-rewind")
        .join(text_of(attachment, "id").replace(['/', '\\'], "_"));
    let path = folder.join(leaf);
    std::fs::create_dir_all(&folder)
        .and_then(|()| std::fs::write(&path, bytes))
        .map_err(|e| e.to_string())?;
    file["path"] = path.to_string_lossy().into_owned().into();
    Ok(file)
}

impl Rewind {
    fn publish(&self, engine: &Engine) {
        let state = if self.thread.is_empty() {
            Json::Null
        } else {
            json!({
                "threadKey": self.thread,
                "rowId": self.row,
                "turn": self.point.get("turn").cloned().unwrap_or(Json::Null),
            })
        };
        self.bridge.publish(engine, "rewind", state);
    }

    fn cancel(&mut self, engine: &Engine) {
        if self.thread.is_empty() {
            return;
        }
        self.thread.clear();
        self.point.clear();
        self.publish(engine);
    }

    fn request(&mut self, engine: &Engine, row_id: &str) {
        if self.working {
            return;
        }
        let thread = shown_thread(engine);
        let Some(timeline) = (!thread.is_empty())
            .then(|| threads::timeline_of(engine, &thread))
            .flatten()
        else {
            return;
        };
        let Some((point, working)) = TimelineModel::read(engine, timeline, |t| {
            (t.rewind_point_of(row_id), t.working())
        }) else {
            return;
        };
        if point.is_empty() {
            return;
        }
        // The thread's provider may be unable to forget what came after.
        let instance = store::with(engine, |s| {
            s.thread_row(&thread)
                .and_then(|row| row.get("modelSelection"))
                .and_then(|m| m.get("instanceId"))
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_owned()
        });
        let config = workspace::environment_config(engine);
        let providers = config.get("providers").and_then(Json::as_array);
        let forgets = providers.into_iter().flatten().any(|status| {
            status.get("instanceId").and_then(Json::as_str) == Some(instance.as_str())
                && status
                    .get("supportsConversationRollback")
                    .and_then(Json::as_bool)
                    == Some(false)
        });
        if forgets {
            return refuse(
                engine,
                "This provider does not support reverting conversation history. Start a new thread instead.",
            );
        }
        if !store::with(engine, |s| s.thread_online(&thread)) {
            return refuse(
                engine,
                "Reconnect the environment before reverting checkpoints.",
            );
        }
        if working {
            return refuse(
                engine,
                "Interrupt the current turn before reverting checkpoints.",
            );
        }
        if !point.contains_key("checkpointId") {
            return refuse(
                engine,
                "There is no checkpoint before this message to rewind to.",
            );
        }
        self.thread = thread;
        self.row = row_id.to_owned();
        self.point = point;
        self.publish(engine);
    }

    fn confirm(&mut self, engine: &Engine, restore_files: bool) {
        if self.thread.is_empty() || self.working {
            return;
        }
        let thread = self.thread.clone();
        let point = self.point.clone();
        self.cancel(engine);
        if composer::attachments_pending(engine, &thread) {
            return refuse(
                engine,
                "Wait for attachments to finish preparing before rewinding.",
            );
        }
        let attachments = point
            .get("attachments")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        if composer::attachments(engine, &thread).len() + attachments.len() > MAX_ATTACHMENTS {
            return refuse(
                engine,
                "Make room for this message's attachments in the composer before rewinding.",
            );
        }
        // The attachments first: a rewind that cannot give them back does
        // not happen.
        self.working = true;
        self.fetch(thread, point, attachments, Vec::new(), restore_files);
    }

    /// Fetches the first of `attachments` from the MC (`assets.createUrl`,
    /// then the bytes of its signed URL), and goes on to the rest; with none
    /// left, rolls back. `fetched` holds the files so far, as the composer
    /// takes them: an image as {name, mimeType, base64}, a file written under
    /// the temp dir's hal-c2-rewind/<id>/<name> as {name, mimeType, path}.
    fn fetch(
        &mut self,
        thread: String,
        point: Obj,
        mut attachments: Vec<Json>,
        fetched: Vec<Json>,
        restore_files: bool,
    ) {
        if attachments.is_empty() {
            return self.roll_back(thread, point, fetched, restore_files);
        }
        let attachment = attachments.remove(0);
        let field = |key: &str| attachment.get(key).and_then(Json::as_str).unwrap_or("");
        let environment = thread.split_once(':').map_or("", |(e, _)| e).to_owned();
        let request = json!({"resource": {
            "_tag": "attachment",
            "attachmentId": field("id"),
            "fileName": field("name"),
            "mimeType": field("mimeType"),
        }});
        let me = self.me.clone();
        self.mc.call(
            &environment,
            "assets.createUrl",
            request,
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    let url = match result {
                        Ok(created) => text_of(&created, "relativeUrl"),
                        Err(error) => return c.failed(engine, &error.message),
                    };
                    let me = c.me.clone();
                    c.mc.download(
                        &url,
                        Box::new(move |engine, result| {
                            me.run(engine, move |c, engine| {
                                let file = result
                                    .map_err(|e| e.message)
                                    .and_then(|bytes| as_file(&attachment, &bytes));
                                match file {
                                    Ok(file) => {
                                        let mut fetched = fetched;
                                        fetched.push(file);
                                        c.fetch(thread, point, attachments, fetched, restore_files);
                                    }
                                    Err(why) => c.failed(engine, &why),
                                }
                            });
                        }),
                    );
                });
            }),
        );
    }

    /// A fetch that failed: nothing is rewound.
    fn failed(&mut self, engine: &Engine, why: &str) {
        self.working = false;
        refuse(
            engine,
            if why.is_empty() {
                "This message's attachments could not be read."
            } else {
                why
            },
        );
    }

    fn roll_back(&mut self, thread: String, point: Obj, files: Vec<Json>, restore_files: bool) {
        let (environment, thread_id) = thread.split_once(':').unwrap_or(("", &thread));
        let me = self.me.clone();
        let command = json!({
            "type": "checkpoint.rollback",
            "threadId": thread_id,
            "checkpointId": text(&point, "checkpointId"),
            "scopeId": text(&point, "scopeId"),
            "restoreFiles": restore_files,
        });
        let environment = environment.to_owned();
        self.mc.dispatch_command(
            &environment,
            command,
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    c.working = false;
                    if let Err(error) = result {
                        let why = if error.message.is_empty() {
                            "Failed to revert thread state."
                        } else {
                            &error.message
                        };
                        return refuse(engine, why);
                    }
                    c.restore(engine, &thread, &point, files);
                });
            }),
        );
    }

    /// The prompt after what the composer holds, then the attachments, in
    /// the composer of the thread the window still shows.
    fn restore(&self, engine: &Engine, thread: &str, point: &Obj, files: Vec<Json>) {
        let current = composer::draft(engine, thread);
        let prompt = text(point, "text").trim();
        let next = if prompt.is_empty() {
            current
        } else if current.is_empty() {
            prompt.to_owned()
        } else {
            format!("{current}\n\n{prompt}")
        };
        if shown_thread(engine) != thread {
            return;
        }
        let cursor = next.encode_utf16().count();
        let bridge = self.bridge;
        bridge.dispatch(
            engine,
            "composer.text.set",
            json!({"target": thread, "text": next, "cursor": cursor}),
        );
        if !files.is_empty() {
            bridge.dispatch(engine, "composer.attach", json!({"files": files}));
        }
        // After the text, which waits for this controller to return.
        bridge.defer(engine, |engine| {
            Bridge::of(engine).send_to_bricks(engine, "composer.focus", &Json::Null);
        });
    }
}

impl Controller for Rewind {
    fn new(init: Init<'_, Self>) -> Self {
        Rewind {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            thread: String::new(),
            row: String::new(),
            point: Obj::new(),
            working: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        // The question is about the thread it was asked on.
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, _| {
            let me = me.clone();
            Bridge::of(engine).defer(engine, move |engine| {
                me.run(engine, |c, e| {
                    if !c.thread.is_empty() && shown_thread(e) != c.thread {
                        c.cancel(e);
                    }
                });
            });
        });
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("rewind.") {
            return false;
        }
        match action {
            "rewind.request" => {
                let row = payload.get("rowId").and_then(Json::as_str).unwrap_or("");
                self.request(engine, row);
            }
            "rewind.confirm" => {
                let restore = payload
                    .get("restoreFiles")
                    .and_then(Json::as_bool)
                    .unwrap_or(false);
                self.confirm(engine, restore);
            }
            "rewind.cancel" => self.cancel(engine),
            _ => {}
        }
        true
    }
}
