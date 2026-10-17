//! `plan`, desktop-qt's PlanController: what the user does with the plan
//! the route's thread offers (`turn.plan`, the composer's) besides
//! implementing it there:
//!
//! - `plan.implementInNewThread`: a thread beside this one, in the same
//!   project and checkout, whose first message carries out the plan; the
//!   window moves to it. The planning thread keeps its plan card.
//! - `plan.copy`: the plan's markdown, to the clipboard.
//! - `plan.download`: a markdown file of it in the Downloads folder.
//! - `plan.save {path}`: the same file at `path` of the thread's workspace
//!   (`projects.writeFile`).
//!
//! Each says what came of it as a toast. Publishes nothing.

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::LazyLock;

use ljos::prelude::{Engine, PathEnv};
use regex::Regex;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::thread_menu::ThreadMenu;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::Mc;
use crate::store;

const IMPLEMENT_PREFIX: &str = "PLEASE IMPLEMENT THIS PLAN:\n";

pub struct Plan {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Plan>,
    downloads: Option<PathBuf>,
    /// An implementation thread is being started.
    starting: bool,
}

/// The plan's first heading.
fn title_of(markdown: &str) -> String {
    static HEADING: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?m)^\s{0,3}#{1,6}\s+(.+)$").unwrap());
    HEADING
        .captures(markdown)
        .map(|c| c[1].trim().to_owned())
        .unwrap_or_default()
}

/// normalizePlanMarkdownForExport.
fn exported(markdown: &str) -> String {
    format!("{}\n", markdown.trim_end())
}

/// sanitizePlanFileSegment: "tax-line.md" for a plan headed "Tax line".
pub fn file_name(markdown: &str) -> String {
    static PUNCTUATION: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"[`'".,!?()\[\]{}]+"#).unwrap());
    static OTHER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^a-z0-9]+").unwrap());
    let segment = title_of(markdown).to_lowercase();
    let segment = PUNCTUATION.replace_all(&segment, "");
    let segment = OTHER.replace_all(&segment, "-");
    let segment = segment.trim_matches('-');
    format!("{}.md", if segment.is_empty() { "plan" } else { segment })
}

/// Where `name` goes in `folder`, never over a file that is already there:
/// "tax-line (2).md".
fn free_path(folder: &Path, name: &str) -> PathBuf {
    let mut path = folder.join(name);
    let stem = name.strip_suffix(".md").unwrap_or(name);
    let mut n = 2;
    while path.exists() {
        path = folder.join(format!("{stem} ({n}).md"));
        n += 1;
    }
    path
}

fn show(engine: &Engine, kind: &str, title: &str, description: &str) {
    let (kind, title, description) = (kind.to_owned(), title.to_owned(), description.to_owned());
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.show(e, &kind, &title, &description, None, DEFAULT_TIMEOUT_MS);
        });
    });
}

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or("")
}

impl Plan {
    /// Where plan.download writes; the system's Downloads folder unless
    /// tests say.
    pub fn set_download_directory(&mut self, path: Option<PathBuf>) {
        self.downloads = path;
    }

    fn implement_in_new_thread(&mut self, engine: &Engine, thread_key: &str, plan: &Json) {
        if self.starting {
            return;
        }
        let row = store::with(engine, |s| s.thread_row(thread_key).cloned()).unwrap_or_default();
        let row = Json::Object(row);
        let environment = thread_key
            .split_once(':')
            .map_or(thread_key, |(e, _)| e)
            .to_owned();
        let markdown = text(plan, "markdown");
        let heading = title_of(markdown);
        // The same checkout as the planning thread.
        let branch = text(&row, "branch");
        let worktree = text(&row, "worktreePath");
        let mut strategy =
            json!({"type": if worktree.is_empty() { "root" } else { "existing_worktree" }});
        if !worktree.is_empty() {
            strategy["worktreePath"] = json!(worktree);
        }
        if !branch.is_empty() {
            strategy["branch"] = json!(branch);
        }
        let thread_id = hal_c2_mc::new_uuid();
        let runtime_mode = row
            .get("runtimeMode")
            .and_then(Json::as_str)
            .unwrap_or("full-access");
        let title = if heading.is_empty() {
            "Implement plan".to_owned()
        } else {
            format!("Implement {heading}")
        };
        let mut launch = json!({
            "commandId": hal_c2_mc::new_uuid(),
            "creationSource": "web",
            "threadId": thread_id,
            "projectId": row.get("projectId").cloned().unwrap_or(Json::Null),
            "title": title,
            "runtimeMode": runtime_mode,
            "interactionMode": "default",
            "workspaceStrategy": strategy,
        });
        let model = row.get("modelSelection").filter(|m| m.is_object()).cloned();
        if let Some(model) = &model {
            launch["modelSelection"] = model.clone();
        }
        let mut message = json!({
            "type": "message.dispatch",
            "createdBy": "user",
            "creationSource": "web",
            "threadId": thread_id,
            "messageId": hal_c2_mc::new_uuid(),
            "text": format!("{IMPLEMENT_PREFIX}{}", markdown.trim()),
            "attachments": [],
            "titleSeed": title,
            "dispatchMode": {"type": "start_immediately"},
            // The MC marks the plan carried out in the thread that proposed
            // it.
            "sourcePlanRef": {"threadId": text(&row, "id"), "planId": text(plan, "id")},
        });
        if let Some(model) = model {
            message["modelSelection"] = model;
        }
        self.starting = true;
        let failed = |engine: &Engine, me: &Me<Plan>, reason: String| {
            me.run(engine, |p, _| p.starting = false);
            let reason = if reason.is_empty() {
                "An error occurred while creating the new thread.".to_owned()
            } else {
                reason
            };
            show(
                engine,
                "error",
                "Could not start implementation thread",
                &reason,
            );
        };
        let me = self.me.clone();
        let mc = self.mc.clone();
        self.mc.call(
            &environment.clone(),
            "orchestration.launchThread",
            launch,
            Box::new(move |engine, result| {
                if let Err(e) = result {
                    return failed(engine, &me, e.message);
                }
                let key = format!("{environment}:{thread_id}");
                let mc2 = mc.clone();
                let target = environment.clone();
                mc.dispatch_command(
                    &target,
                    message,
                    Box::new(move |engine, result| {
                        if let Err(e) = result {
                            // A thread with nothing in it is not left
                            // behind.
                            mc2.dispatch_command(
                                &environment,
                                json!({"type": "thread.delete", "threadId": thread_id}),
                                Box::new(|_, _| {}),
                            );
                            return failed(engine, &me, e.message);
                        }
                        me.run(engine, |p, _| p.starting = false);
                        Bridge::of(engine).defer(engine, move |engine| {
                            controller::with::<Navigation, _>(engine, |n, e| {
                                n.open(e, Route::Thread(key));
                            });
                        });
                    }),
                );
            }),
        );
    }

    fn download(&self, engine: &Engine, plan: &Json) {
        let markdown = text(plan, "markdown");
        let folder = self.downloads.clone().unwrap_or_else(|| {
            // TODO(ljos#63): the facade does not name `Location`.
            ljos_platform::Location::Download.writable(&PathEnv::from_process(), "", "")
        });
        let path = free_path(&folder, &file_name(markdown));
        match std::fs::create_dir_all(&folder)
            .and_then(|()| std::fs::write(&path, exported(markdown)))
        {
            Ok(()) => show(
                engine,
                "success",
                "Plan downloaded",
                &path.to_string_lossy(),
            ),
            Err(e) => show(engine, "error", "Could not download plan", &e.to_string()),
        }
    }

    fn save(&self, engine: &Engine, thread_key: &str, plan: &Json, path: &str) {
        let environment = thread_key.split_once(':').map_or(thread_key, |(e, _)| e);
        let root = store::with(engine, |s| {
            let row = s.thread_row(thread_key)?;
            let worktree = row.get("worktreePath").and_then(Json::as_str).unwrap_or("");
            if !worktree.is_empty() {
                return Some(worktree.to_owned());
            }
            let project = row.get("projectId").and_then(Json::as_str).unwrap_or("");
            let project = s.project_row(environment, project)?;
            project
                .get("workspaceRoot")
                .and_then(Json::as_str)
                .map(str::to_owned)
        })
        .unwrap_or_default();
        if root.is_empty() {
            return show(
                engine,
                "error",
                "Workspace path is unavailable",
                "This thread does not have a workspace path to save into.",
            );
        }
        let markdown = text(plan, "markdown");
        let relative_path = if path.trim().is_empty() {
            file_name(markdown)
        } else {
            path.trim().to_owned()
        };
        self.mc.call(
            environment,
            "projects.writeFile",
            json!({"cwd": root, "relativePath": relative_path, "contents": exported(markdown)}),
            Box::new(move |engine, result| match result {
                Err(e) => {
                    let reason = if e.message.is_empty() {
                        "An error occurred while saving."
                    } else {
                        &e.message
                    };
                    show(engine, "error", "Could not save plan", reason);
                }
                Ok(answer) => {
                    let saved = answer
                        .get("relativePath")
                        .and_then(Json::as_str)
                        .unwrap_or(&relative_path);
                    show(engine, "success", "Plan saved to workspace", saved);
                }
            }),
        );
    }
}

impl Controller for Plan {
    fn new(init: Init<'_, Self>) -> Self {
        Plan {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            downloads: None,
            starting: false,
        }
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("plan.") {
            return false;
        }
        let thread_key = match navigation::shown(engine) {
            Route::Thread(key) => key,
            _ => String::new(),
        };
        let turn = self.bridge.published(engine, "turn").unwrap_or(Json::Null);
        let plan = turn.get("plan").cloned().unwrap_or(Json::Null);
        // Only the plan the open thread offers.
        let offered = plan.as_object().is_some_and(|p| !p.is_empty());
        if thread_key.is_empty() || text(&turn, "threadKey") != thread_key || !offered {
            return true;
        }
        match action {
            "plan.implementInNewThread" => self.implement_in_new_thread(engine, &thread_key, &plan),
            "plan.copy" => {
                let markdown = exported(text(&plan, "markdown"));
                Bridge::of(engine).defer(engine, move |engine| {
                    controller::with::<ThreadMenu, _>(engine, |m, e| {
                        m.copy(e, &markdown, "Plan copied", "Could not copy plan");
                    });
                });
            }
            "plan.download" => self.download(engine, &plan),
            "plan.save" => self.save(engine, &thread_key, &plan, text(payload, "path")),
            _ => {}
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plan_is_named_after_its_heading() {
        assert_eq!(file_name("# Tax line\n\n- Add it"), "tax-line.md");
        assert_eq!(
            file_name("intro\n  ## Add the `cart`'s (new) total!"),
            "add-the-carts-new-total.md"
        );
        assert_eq!(file_name("no heading"), "plan.md");
        assert_eq!(file_name("# ???"), "plan.md");
    }

    #[test]
    fn an_exported_plan_ends_in_one_newline() {
        assert_eq!(exported("# A\n\n- b  \n\n"), "# A\n\n- b\n");
    }
}
