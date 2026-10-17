//! desktop-qt's FileActionsController: what a file of the thread's checkout
//! offers wherever it is named (the Files tab, a file mention, a diff): open
//! it in the Files tab (`files.open {path}`), show it in the file manager
//! (`files.reveal {path}`), open it in an editor (`files.openInEditor {path,
//! editorId}`), copy its mention (`files.copyMention {path}`) or add it to
//! the chat (`files.addToChat {path}`). Paths are relative to the checkout.
//!
//! TODO(port): desktop-qt also keeps the Files tab's source kinds in the
//! device settings (`fileSourceKinds`, through WorkspaceFiles'
//! setSourceKinds/sourceKindsChanged) and toasts its saveFailed ("Could not
//! save {path}"); both wait for `RightPanelController::files()`.

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::composer_model::path_link;
use crate::controller::{self, Controller, Init};
use crate::controllers::composer;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::controllers::workspace;
use crate::json::Json;

pub struct FileActions {
    bridge: Bridge,
}

/// The checkout the files are in.
///
/// TODO(port): desktop-qt reads `RightPanelController::files()->root()`,
/// which keeps the last thread's checkout away from a thread; until the
/// panel's WorkspaceFiles is here this is the route thread's checkout.
fn root(engine: &Engine) -> String {
    workspace::place(engine)
        .map(|place| place.cwd().to_owned())
        .unwrap_or_default()
}

/// `path` in `root`; empty without either.
pub fn absolute(root: &str, path: &str) -> String {
    if root.is_empty() || path.is_empty() {
        return String::new();
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

impl Controller for FileActions {
    fn new(init: Init<'_, Self>) -> Self {
        FileActions {
            bridge: init.bridge,
        }
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
                let selects = workspace::environment_config(engine)
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
        assert_eq!(folder_of("/repo/src/a.rs"), "/repo/src");
        assert_eq!(folder_of(""), "");
    }

    #[test]
    fn mention_has_no_trailing_space() {
        assert_eq!(mention("src/a.rs"), "[a.rs](src/a.rs)");
    }
}
