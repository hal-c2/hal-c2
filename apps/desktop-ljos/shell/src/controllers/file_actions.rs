//! desktop-qt's FileActionsController: what a file of the thread's checkout
//! offers wherever it is named (the Files tab, a file mention, a diff): open
//! it in the Files tab (`files.open {path}`), show it in the file manager
//! (`files.reveal {path}`), open it in an editor (`files.openInEditor {path,
//! editorId}`), copy its mention (`files.copyMention {path}`) or add it to
//! the chat (`files.addToChat {path}`). Paths are relative to the checkout,
//! or full paths of files the agent left outside it. Editors and file
//! managers start on this machine (`workspace::open_in_editor`).
//!
//! It also offers "Copy file contents" (`files.copyContents`, a command
//! listed while the Files tab shows a text file), which copies the open
//! file's text as the viewer has it.
//!
//! It also keeps the Files tab's source kinds (the kinds the user reads as
//! source rather than rendered) in this device's settings (`fileSourceKinds`),
//! and toasts a save the MC refused ("Could not save {path}").

use ljos::prelude::{Engine, ObjectId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::composer_model::path_link;
use crate::controller::{self, Controller, Init};
use crate::controllers::composer;
use crate::controllers::panel::RightPanel;
use crate::controllers::settings::Settings;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::controllers::workspace;
use crate::json::Json;
use crate::thread_view::workspace_files::WorkspaceFiles;

/// The device setting holding the source kinds.
const SOURCE_KINDS: &str = "fileSourceKinds";
/// The command and action copying the open file's text.
pub const COPY_CONTENTS: &str = "files.copyContents";

pub struct FileActions {
    bridge: Bridge,
    active: bool,
}

/// The Files tab's WorkspaceFiles, if the panel has one.
fn files(engine: &Engine) -> Option<ObjectId> {
    controller::with::<RightPanel, _>(engine, |p, _| p.files()).flatten()
}

/// The checkout the files are in: the Files tab's, which keeps the last
/// thread's checkout away from a thread.
fn root(engine: &Engine) -> String {
    files(engine)
        .and_then(|files| WorkspaceFiles::read(engine, files, |f| f.root().to_owned()))
        .unwrap_or_default()
}

/// The kinds the device setting names.
fn kinds(engine: &Engine) -> Vec<String> {
    match Settings::of(engine).device_value(SOURCE_KINDS) {
        Some(Json::Array(kinds)) => kinds
            .iter()
            .filter_map(|k| k.as_str().map(str::to_owned))
            .collect(),
        _ => Vec::new(),
    }
}

/// `path` in `root`; empty without either.
pub fn absolute(root: &str, path: &str) -> String {
    if root.is_empty() || path.is_empty() {
        return String::new();
    }
    // One the agent left outside the workspace is opened by its full path.
    if path.starts_with('/') || path.contains(":\\") {
        return path.to_owned();
    }
    if root.ends_with('/') {
        format!("{root}{path}")
    } else {
        format!("{root}/{path}")
    }
}

/// The folder a path is in.
pub fn folder_of(path: &str) -> &str {
    path.rfind('/').map_or("", |at| &path[..at])
}

/// A file's mention as copied: the composer's link without the space the @
/// menu adds.
pub fn mention(path: &str) -> String {
    let mut link = path_link(path);
    link.pop();
    link
}

fn error(engine: &Engine, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |t, e| {
        t.error(e, title, description);
    });
}

/// The viewer shows a file as text, which can be copied.
fn copyable(engine: &Engine, files: Option<ObjectId>) -> bool {
    files
        .and_then(|files| {
            WorkspaceFiles::read(engine, files, |f| {
                f.file_status() == "ready" && f.media_kind().is_empty()
            })
        })
        .unwrap_or(false)
}

/// Copies the open file's text, saying what came along.
fn copy_contents(engine: &Engine) {
    let files = files(engine);
    if !copyable(engine, files) {
        error(
            engine,
            "No file to copy",
            "Open a text file in the Files panel first.",
        );
        return;
    }
    let Some((text, path, truncated)) = files.and_then(|files| {
        WorkspaceFiles::read(engine, files, |f| {
            (
                f.text().to_owned(),
                f.open_path().to_owned(),
                !f.truncated_notice().is_empty(),
            )
        })
    }) else {
        return;
    };
    if !Bridge::of(engine).copy_to_clipboard(engine, &text) {
        error(engine, "Failed to copy file contents", "");
        return;
    }
    // A file larger than the MC reads whole has only its start in the
    // viewer.
    let description = if truncated {
        format!("Only the first 1 MB of {path}.")
    } else {
        path
    };
    controller::with::<Toasts, _>(engine, |t, e| {
        t.show(
            e,
            "success",
            "File contents copied",
            &description,
            None,
            DEFAULT_TIMEOUT_MS,
        );
    });
}

impl Controller for FileActions {
    fn new(init: Init<'_, Self>) -> Self {
        FileActions {
            bridge: init.bridge,
            active: false,
        }
    }

    /// The Files tab shows the kinds this device keeps, keeps the ones the
    /// user chooses there, and its failed saves are toasted.
    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        let Some(files) = files(engine) else { return };
        self.active = true;
        let settings = Settings::of(engine);
        settings.on_device_changed(move |engine| {
            WorkspaceFiles::set_source_kinds(engine, files, &kinds(engine));
        });
        WorkspaceFiles::set_source_kinds(engine, files, &kinds(engine));
        WorkspaceFiles::on_source_kinds_changed(engine, files, move |engine| {
            let chosen = WorkspaceFiles::source_kinds(engine, files);
            let value = if chosen.is_empty() {
                Json::Null
            } else {
                json!(chosen)
            };
            Settings::of(engine).write_device(engine, SOURCE_KINDS, value);
        });
        WorkspaceFiles::on_save_failed(engine, files, |engine, path, problem| {
            error(engine, &format!("Could not save {path}"), problem);
        });
        let commands = Commands::of(engine);
        commands.add(engine, COPY_CONTENTS, "Copy file contents", copy_contents);
        commands.set_terms(COPY_CONTENTS, &["clipboard", "text", "file"]);
        let follow = move |engine: &Engine| {
            let copyable = copyable(engine, Some(files));
            let commands = Commands::of(engine);
            commands.set_enabled(engine, COPY_CONTENTS, copyable);
            commands.set_listed(engine, COPY_CONTENTS, copyable);
        };
        if let Err(e) = engine.connect_by_name(files, "fileStatusChanged", move |engine, _| {
            follow(engine);
        }) {
            engine.log(
                ljos::prelude::LogLevel::Warning,
                "FileActions",
                e.to_string(),
            );
        }
        follow(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("files.") {
            return false;
        }
        let path = payload["path"].as_str().unwrap_or_default();
        match action {
            "files.open" => {
                self.bridge
                    .dispatch(engine, "panel.open", json!({"tab": "files", "path": path}));
            }
            "files.reveal" | "files.openInEditor" => {
                let reveal = action == "files.reveal";
                let mut target = absolute(&root(engine), path);
                // An MC that cannot select a file shows the folder it is in.
                let selects = workspace::local_config(engine)
                    .get("shellRevealInFileManager")
                    .and_then(Json::as_bool)
                    .unwrap_or(false);
                if reveal && !selects {
                    target = folder_of(&target).to_owned();
                }
                let opened = !target.is_empty()
                    && if reveal && !selects {
                        workspace::open_in_editor(engine, "file-manager", &target, false)
                    } else {
                        let editor = payload["editorId"].as_str().unwrap_or_default();
                        workspace::open_in_editor(engine, editor, &target, reveal)
                    };
                if !opened && reveal {
                    error(
                        engine,
                        "Unable to show the file",
                        "This environment has no file manager.",
                    );
                } else if !opened {
                    error(
                        engine,
                        "Unable to open the file",
                        "This environment has no editor.",
                    );
                }
            }
            "files.copyMention" => {
                if self.bridge.copy_to_clipboard(engine, &mention(path)) {
                    controller::with::<Toasts, _>(engine, |t, e| {
                        t.show(
                            e,
                            "success",
                            "Mention copied",
                            path,
                            None,
                            DEFAULT_TIMEOUT_MS,
                        );
                    });
                } else {
                    error(engine, "Failed to copy mention", "");
                }
            }
            COPY_CONTENTS => copy_contents(engine),
            "files.addToChat" => {
                if !composer::insert_at_end(engine, &path_link(path)) {
                    error(
                        engine,
                        "Unable to add to chat",
                        "Open a chat for this project and try again.",
                    );
                }
            }
            _ => return false,
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::{absolute, folder_of, mention};

    #[test]
    fn paths() {
        assert_eq!(absolute("/repo", "src/a.rs"), "/repo/src/a.rs");
        assert_eq!(absolute("/repo/", "a.rs"), "/repo/a.rs");
        assert_eq!(absolute("", "a.rs"), "");
        assert_eq!(absolute("/repo", ""), "");
        // One outside the checkout is opened by its full path.
        assert_eq!(absolute("/repo", "/tmp/x.txt"), "/tmp/x.txt");
        assert_eq!(absolute("C:\\repo", "D:\\x.txt"), "D:\\x.txt");
        assert_eq!(folder_of("/repo/src/a.rs"), "/repo/src");
        assert_eq!(folder_of(""), "");
    }

    #[test]
    fn mention_has_no_trailing_space() {
        assert_eq!(mention("src/a.rs"), "[a.rs](src/a.rs)");
    }
}
