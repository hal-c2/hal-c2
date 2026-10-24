//! Reviewing the checkout beside a thread
//! (features/source-control/review-diffs.feature): the Diff tab over the
//! MC's `review.getDiffPreview`, driven through the DiffPanel brick as the
//! user drives it. The MC's side is faked here: the working tree's patch,
//! and the branch's against each base.
//!
//! Not ported (ReviewDiffSteps.cpp's editor steps): "no editor is available
//! on this environment", "the user opens {Q} from the diff" and "... from
//! the commit review". They wait for FakeConfig's `availableEditors` and
//! FilesWorkspace's `OpenedInEditor`, which other files own.

use std::collections::HashMap;

use hal_c2_shell::thread_view::diff::{Diff, DiffModel};
use hal_c2_shell::thread_view::rows::RowSource;
use hal_c2_shell::thread_view::thread_diff::{BRANCH, DiffTab, ThreadDiff};
use ljos::prelude::{ObjectId, Value as Js};
use serde_json::{Value, json};

use crate::brick::{Brick, Shown, shown};
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::world::World;
use crate::{expect, fail};

/// Where the MC puts a thread's worktree: under its data directory, outside
/// the project (HalC2.Vcs.worktree_path/2).
const WORKTREE: &str = "/home/hal-c2/elixir/worktrees/shop/feature-tax";

/// The Diff tab as the DiffPanel brick draws it, short, so a later file is
/// below the fold. `diffSource` is how the steps reach the panel's tab.
const PANEL: &str = "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nItem {\n anchors.fill: parent\n property var diffSource: Panel.diff\n DiffPanel { anchors.fill: parent; source: parent.diffSource }\n}\n";

fn patch_changing(path: &str, added: &[String]) -> String {
    let mut patch = format!(
        "diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1,2 +1,{} @@\n const cart = [];\n-export const tax = 0;\n",
        added.len() + 1
    );
    for line in added {
        patch.push('+');
        patch.push_str(line);
        patch.push('\n');
    }
    patch
}

fn lines(name: &str, count: usize) -> Vec<String> {
    (1..=count)
        .map(|n| format!("export const {name}{n} = {n};"))
        .collect()
}

/// The checkout as `review.getDiffPreview` reports it (HalC2.Review).
struct FakeReview {
    head: String,
    automatic_base: String,
    /// Uncommitted work: a long file first, so jumping to a later one scrolls.
    working_tree: String,
    /// The branch's changes, by the base they are against.
    branch: HashMap<String, String>,
    asked: Vec<Value>,
    installed: bool,
}

impl Default for FakeReview {
    fn default() -> Self {
        let mut long = lines("rate", 60);
        long.push("x".repeat(300));
        let working_tree = patch_changing("src/cart.ts", &long)
            + &patch_changing("src/tax.ts", &lines("band", 3))
            + &patch_changing("README.md", &lines("note", 40));
        let main = patch_changing("src/cart.ts", &lines("rate", 2));
        let branch = HashMap::from([
            ("main".to_owned(), main.clone()),
            (
                "origin/main".to_owned(),
                main + &patch_changing("src/pay.ts", &lines("fee", 2)),
            ),
        ]);
        FakeReview {
            head: "feature/tax".into(),
            automatic_base: "main".into(),
            working_tree,
            branch,
            asked: Vec::new(),
            installed: false,
        }
    }
}

/// The fake review, answering `review.getDiffPreview` from the first time a
/// step asks for it.
fn fake(world: &mut World) -> &mut FakeReview {
    if !world.mc.part::<FakeReview>().installed {
        world.mc.part::<FakeReview>().installed = true;
        world.mc.on_rpc("review.getDiffPreview", |mc, rpc| {
            let fake = mc.part::<FakeReview>();
            fake.asked.push(rpc.payload.clone());
            let base = rpc.payload["baseRef"]
                .as_str()
                .unwrap_or(&fake.automatic_base)
                .to_owned();
            let head = fake.head.clone();
            let source = |kind: &str, title: &str, base_ref: Value, diff: &str| {
                json!({
                    "id": kind, "kind": kind, "title": title,
                    "baseRef": base_ref, "headRef": head, "diff": diff,
                    "diffHash": format!("hash-{}", diff.len()), "truncated": false,
                })
            };
            let result = json!({
                "cwd": rpc.payload["cwd"],
                "generatedAt": "2026-09-23T10:00:00Z",
                "sources": [
                    source("working-tree", "Working tree", Value::Null, &fake.working_tree),
                    source(
                        "branch-range",
                        "Branch",
                        json!(base),
                        fake.branch.get(&base).map(String::as_str).unwrap_or(""),
                    ),
                ],
            });
            mc.reply(rpc, result);
            Ok(())
        });
    }
    world.mc.part::<FakeReview>()
}

/// The Diff tab and the brick drawing it.
#[derive(Clone, Copy)]
struct View {
    brick: Brick,
    tab: ObjectId,
}

fn view_of(brick: Brick, world: &World) -> Option<View> {
    let root = brick.root(world)?;
    match brick.read(world, root, "diffSource") {
        Js::Object(tab) => Some(View { brick, tab }),
        _ => None,
    }
}

impl View {
    fn tab<R>(&self, world: &World, f: impl FnOnce(&DiffTab) -> R) -> Option<R> {
        ThreadDiff::read(world.engine(), self.tab, f)
    }

    fn diff<R>(&self, world: &World, f: impl FnOnce(&Diff) -> R) -> Option<R> {
        let engine = world.engine();
        let model = ThreadDiff::model(engine, self.tab)?;
        DiffModel::read(engine, model, f)
    }

    /// Changes the tab as the user's choice does, and lets the shell settle.
    fn act(&self, world: &mut World, f: impl FnOnce(&mut DiffTab)) -> Outcome {
        ThreadDiff::update(world.engine(), self.tab, f);
        world.pump()
    }

    fn status(&self, world: &World) -> String {
        self.tab(world, |t| t.status().to_owned())
            .unwrap_or_default()
    }

    fn paths(&self, world: &World) -> Vec<String> {
        self.diff(world, |d| d.paths()).unwrap_or_default()
    }

    fn file_count(&self, world: &World) -> usize {
        self.diff(world, |d| d.file_count()).unwrap_or(0)
    }

    fn describe(&self, world: &World) -> String {
        let (status, message) = self
            .tab(world, |t| (t.status().to_owned(), t.message().to_owned()))
            .unwrap_or_default();
        format!(
            "the diff ({status}: {message}) shows {}",
            self.paths(world).join(", ")
        )
    }

    fn loaded(&self, world: &World) -> bool {
        !matches!(self.status(world).as_str(), "loading" | "idle")
    }

    fn wait_loaded(&self, world: &mut World) -> Outcome {
        let view = *self;
        world.wait_for_with(
            |w| view.loaded(w),
            |w| format!("the diff to load; {}", view.describe(w)),
        )
    }

    fn compared_base(&self, world: &World) -> String {
        self.tab(world, |t| t.compared_base().to_owned())
            .unwrap_or_default()
    }

    fn wrap(&self, world: &World) -> bool {
        self.tab(world, |t| t.wrap()).unwrap_or(false)
    }

    fn rows(&self, world: &World) -> Outcome<ObjectId> {
        self.brick.item(world, "diffRows")
    }

    fn number(&self, world: &World, item: ObjectId, name: &str) -> f64 {
        self.brick.text_of(world, item, name).parse().unwrap_or(0.0)
    }

    /// The file whose row is at the top of the list.
    fn file_at_top(&self, world: &World) -> Outcome<String> {
        let rows = self.rows(world)?;
        let index = self.brick.top_index(world, rows)?;
        let path = self
            .diff(world, |d| d.data(index.max(0) as usize, "path"))
            .unwrap_or(Js::Undefined);
        Ok(world.engine().to_js_string(&path).to_string())
    }
}

/// The Diff tab beside the thread, on the checkout's working tree (the
/// thread has no turn yet), as the DiffPanel brick draws it.
fn panel(world: &mut World) -> Outcome<View> {
    if let Some(brick) = world.part::<Shown>().0
        && let Some(view) = view_of(brick, world)
    {
        return Ok(view);
    }
    fake(world);
    world.dispatch("panel.open", json!({"tab": "diff"}))?;
    Brick::show(world, PANEL, 900.0, 420.0)?;
    let brick = shown(world)?;
    let Some(view) = view_of(brick, world) else {
        fail!("the panel has no diff to review");
    };
    view.wait_loaded(world)?;
    let reviewing = view.tab(world, |t| t.reviewing()).unwrap_or(false);
    expect!(
        view.status(world) == "ready" && reviewing,
        "{}",
        view.describe(world)
    );
    Ok(view)
}

/// An entry of the panel's options menu.
fn choose_option(world: &mut World, entry: &str) -> Outcome {
    let view = panel(world)?;
    view.brick.click(world, "diffOptions")?;
    let brick = view.brick;
    world.wait_for(
        "the diff's options to open",
        |w| matches!(brick.find(w, entry), Ok(Some(item)) if brick.flag(w, item, "visible")),
    )?;
    // The menu fades in on the window's clock and is hit-tested once drawn.
    world.advance(300)?;
    world.sync()?;
    brick.click(world, entry)?;
    world.sync()
}

fn comments(world: &World) -> Vec<Value> {
    world.state("composer")["reviewComments"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// A note on lines of the diff, for the prompt.
fn comment_on(world: &mut World, note: &str, first: i32, last: i32, path: &str) -> Outcome {
    let view = panel(world)?;
    let brick = view.brick;
    let Some(file) = view.paths(world).iter().position(|p| p == path) else {
        fail!("the diff does not show {path}: {}", view.describe(world));
    };
    // The line's own button, shown while the pointer is over the line.
    world.wait_for(&format!("line {first} of {path} to be shown"), |w| {
        matches!(brick.line_comment(w, file, first), Ok(Some(_)))
    })?;
    let Some(button) = brick.line_comment(world, file, first)? else {
        fail!("line {first} of {path} went away");
    };
    // The row is as wide as the longest line: its start is what is in view.
    let Js::Object(line) = brick.read(world, button, "parent") else {
        fail!("the comment button is on no line");
    };
    let height: f64 = view.number(world, line, "height");
    let (x, y) = brick.at_px(world, line, 60.0, height / 2.0)?;
    world.hover_at(x + 40.0, y)?;
    world.hover_at(x, y)?;
    world.wait_for("the line to offer a comment", |w| {
        brick.flag(w, button, "visible")
    })?;
    let (bx, by) = brick.at(world, button, 0.5, 0.5)?;
    world.click_at(bx, by)?;
    world.wait_for("the comment box to open", |w| {
        matches!(brick.find(w, "diffCommentLast"), Ok(Some(item)) if brick.flag(w, item, "visible"))
    })?;
    let last_line = brick.item(world, "diffCommentLast")?;
    brick.write(
        world,
        last_line,
        "text",
        Js::from(last.to_string().as_str()),
    )?;
    brick.click(world, "diffCommentNote")?;
    world.type_text(note)?;
    brick.click(world, "diffCommentAdd")?;
    world.sync()
}

/// What a send of "Please fix this" carries to the MC.
fn sent(world: &mut World) -> Outcome<Value> {
    world.dispatch(
        "composer.submit",
        json!({"text": "Please fix this", "intent": "foreground"}),
    )?;
    world.sync()?;
    let message = world
        .mc
        .commands
        .iter()
        .rfind(|command| command["type"] == "message.dispatch")
        .cloned();
    match message {
        Some(message) => Ok(message),
        None => fail!(
            "no message was sent; the MC has {}",
            world.describe_commands()
        ),
    }
}

pub fn register(steps: &mut Steps) {
    // A thread in a worktree of its own: the review is of that checkout,
    // not the project's.
    steps.step(
        "the thread works in a new worktree under the HAL-C2 home",
        |world, _, _| {
            let Some(id) = world.mc.threads.keys().next().cloned() else {
                fail!("the MC has no thread");
            };
            let mut row = world.mc.threads[&id].clone();
            row["worktreePath"] = json!(WORKTREE);
            world.mc.threads.insert(id.clone(), row.clone());
            world.mc.send_row(&id, &row);
            world.wait_for("the thread to be in its worktree", |w| {
                at(&w.state("workspace"), "worktreePath") == WORKTREE
            })
        },
    );
    steps.step("the user reviews the working tree", |world, _, _| {
        panel(world)?;
        Ok(())
    });
    steps.step("the worktree's changes are in the diff", |world, _, _| {
        let view = panel(world)?;
        let asked = fake(world).asked.last().cloned();
        expect!(
            asked.as_ref().is_some_and(|a| a["cwd"] == WORKTREE),
            "the review asked for {}",
            asked.map(|a| show(&a["cwd"])).unwrap_or("nothing".into())
        );
        expect!(
            view.status(world) == "ready" && view.paths(world).iter().any(|p| p == "src/tax.ts"),
            "{}",
            view.describe(world)
        );
        Ok(())
    });

    // Stacked and split.
    steps.step(
        "the user switches the diff to the split view",
        |world, _, _| {
            let view = panel(world)?;
            expect!(
                !view.diff(world, |d| d.split()).unwrap_or(false),
                "the diff is already split"
            );
            choose_option(world, "diffSplit")
        },
    );
    steps.step(
        "the old and new lines are shown side by side",
        |world, _, _| {
            let view = panel(world)?;
            expect!(
                view.diff(world, |d| d.split()).unwrap_or(false),
                "the diff is not split"
            );
            let paired = view
                .diff(world, |d| {
                    let sign = |row, role| match d.data(row, role) {
                        Js::String(s) => s.to_string(),
                        _ => String::new(),
                    };
                    (0..d.row_count())
                        .any(|row| sign(row, "sign") == "-" && sign(row, "rightSign") == "+")
                })
                .unwrap_or(false);
            expect!(paired, "no removed line sits beside an added one");
            // The reverse: one column again.
            choose_option(world, "diffSplit")?;
            expect!(
                !view.diff(world, |d| d.split()).unwrap_or(true),
                "the diff cannot be stacked again"
            );
            Ok(())
        },
    );

    // The base.
    steps.step(
        &format!("the user compares the branch against {Q} instead of {Q}"),
        |world, c, _| {
            let view = panel(world)?;
            view.act(world, |t| t.select(BRANCH))?;
            view.wait_loaded(world)?;
            expect!(
                view.compared_base(world) == c[1] && view.paths(world) == ["src/cart.ts"],
                "{}",
                view.describe(world)
            );
            let brick = view.brick;
            world.wait_for("the base to be offered", |w| {
                matches!(brick.find(w, "diffBaseRef"), Ok(Some(item)) if brick.flag(w, item, "visible"))
            })?;
            brick.click(world, "diffBaseRef")?;
            world.type_text(&c[0])?;
            brick.press(world, "enter")?;
            world.sync()?;
            view.wait_loaded(world)
        },
    );
    steps.step(
        &format!("the diff shows the changes against {Q}"),
        |world, c, _| {
            let view = panel(world)?;
            let head = view.tab(world, |t| t.compared_head().to_owned());
            expect!(
                view.status(world) == "ready"
                    && view.compared_base(world) == c[0]
                    && head.as_deref() == Some("feature/tax")
                    && view.paths(world) == ["src/cart.ts", "src/pay.ts"],
                "{} against {}",
                view.describe(world),
                view.compared_base(world)
            );
            let asked = fake(world).asked.last().cloned().unwrap_or(Value::Null);
            expect!(
                asked["baseRef"] == c[0].as_str(),
                "the MC was asked {}",
                show(&asked)
            );
            // The reverse: no base named, the MC picks again.
            view.act(world, |t| t.set_base_ref(""))?;
            view.wait_loaded(world)?;
            expect!(
                view.compared_base(world) == "main",
                "the branch is compared against {}",
                view.compared_base(world)
            );
            Ok(())
        },
    );

    // The file tree.
    steps.step("the user shows the file tree of the diff", |world, _, _| {
        choose_option(world, "diffTree")
    });
    steps.step("the changed files are listed by folder", |world, _, _| {
        let view = panel(world)?;
        let listed: Vec<String> = view
            .diff(world, |d| d.tree())
            .unwrap_or_default()
            .iter()
            .map(|entry| {
                format!(
                    "{}{}{}",
                    " ".repeat(entry["depth"].as_u64().unwrap_or(0) as usize),
                    entry["name"].as_str().unwrap_or(""),
                    if entry["kind"] == "folder" { "/" } else { "" }
                )
            })
            .collect();
        let wanted = ["src/", " cart.ts", " tax.ts", "README.md"];
        expect!(listed == wanted, "the tree lists [{}]", listed.join(", "));
        let brick = view.brick;
        world.wait_for_with(
            |w| {
                matches!(brick.find(w, "diffTreeRows"), Ok(Some(tree))
                    if brick.flag(w, tree, "visible") && brick.text_of(w, tree, "count") == wanted.len().to_string())
            },
            |w| {
                let count = brick
                    .find(w, "diffTreeRows")
                    .ok()
                    .flatten()
                    .map(|tree| brick.text_of(w, tree, "count"));
                format!("the tree to be drawn; it has {count:?} rows")
            },
        )?;
        expect!(
            brick.shows(world, "tax.ts")? && brick.shows(world, "src")?,
            "the tree does not name its files"
        );
        Ok(())
    });
    steps.step("choosing a file jumps to it", |world, _, _| {
        let view = panel(world)?;
        let brick = view.brick;
        let top = view.file_at_top(world)?;
        expect!(top == "src/cart.ts", "the diff starts at {top}");
        let Some(node) = brick.tree_node(world, "src/tax.ts")? else {
            fail!("the tree does not offer src/tax.ts");
        };
        let (x, y) = brick.at(world, node, 0.5, 0.5)?;
        world.click_at(x, y)?;
        // TODO(ljos#103): positionViewAtIndex to a row not yet laid out is
        // lost when the list reuses items and its rows differ in height.
        world.wait_for_with(
            |w| view.file_at_top(w).is_ok_and(|top| top == "src/tax.ts"),
            |w| {
                format!(
                    "the diff to jump to src/tax.ts (ljos#103); its top is {:?}",
                    view.file_at_top(w)
                )
            },
        )?;
        // The reverse: the tree goes away again.
        choose_option(world, "diffTree")?;
        let tree = brick.item(world, "diffTreeRows")?;
        expect!(
            !brick.flag(world, tree, "visible"),
            "the tree is still shown"
        );
        Ok(())
    });

    // Every file at once.
    steps.step(
        "the user collapses all files and then expands all files",
        |world, _, _| {
            let view = panel(world)?;
            expect!(
                view.diff(world, |d| d.all_expanded()).unwrap_or(false),
                "the files do not start open"
            );
            choose_option(world, "diffExpandAll")?;
            let (rows, files) = view
                .diff(world, |d| (d.row_count(), d.file_count()))
                .unwrap_or_default();
            expect!(rows == files, "{rows} rows for {files} collapsed files");
            choose_option(world, "diffExpandAll")
        },
    );
    steps.step("every file is shown open again", |world, _, _| {
        let view = panel(world)?;
        let open = view
            .diff(world, |d| d.all_expanded() && d.file_count() == 3)
            .unwrap_or(false);
        expect!(open, "{}", view.describe(world));
        for file in 0..view.file_count(world) {
            let (path, shown) = view
                .diff(world, |d| {
                    let start = d.row_of_file(file).unwrap_or(0);
                    let next = d.row_of_file(file + 1).unwrap_or(d.row_count());
                    (d.path(file).unwrap_or("").to_owned(), next - start > 1)
                })
                .unwrap_or_default();
            expect!(shown, "{path} shows no lines");
        }
        Ok(())
    });

    // Wrapping.
    steps.step(
        "the user turns on line wrapping in the diff",
        |world, _, _| {
            let view = panel(world)?;
            let rows = view.rows(world)?;
            // Lines start unwrapped here, whatever the word wrap setting says.
            view.act(world, |t| t.set_wrap(false))?;
            world.wait_for("the long line to scroll sideways", |w| {
                view.number(w, rows, "contentWidth") > view.number(w, rows, "width")
            })?;
            expect!(
                !view.wrap(world),
                "the lines wrap before the user turns wrapping on"
            );
            choose_option(world, "diffWrap")
        },
    );
    steps.step(
        "long lines wrap instead of scrolling sideways",
        |world, _, _| {
            let view = panel(world)?;
            let rows = view.rows(world)?;
            world.wait_for_with(
                |w| {
                    view.wrap(w)
                        && view.number(w, rows, "contentWidth") <= view.number(w, rows, "width")
                },
                |w| {
                    format!(
                        "the rows to fit the view; they are {} wide in {}",
                        view.number(w, rows, "contentWidth"),
                        view.number(w, rows, "width")
                    )
                },
            )?;
            // The reverse.
            choose_option(world, "diffWrap")?;
            expect!(!view.wrap(world), "wrapping cannot be turned off again");
            Ok(())
        },
    );

    // Refreshing.
    steps.step("the user refreshes the diff", |world, _, _| {
        let view = panel(world)?;
        expect!(view.file_count(world) == 3, "{}", view.describe(world));
        // The checkout moved on since the diff was read.
        fake(world).working_tree +=
            &patch_changing("src/checkout.ts", &["export const total = 1;".to_owned()]);
        choose_option(world, "diffReload")?;
        view.wait_loaded(world)
    });
    steps.step("the diff shows the checkout as it is now", |world, _, _| {
        let view = panel(world)?;
        expect!(
            view.status(world) == "ready"
                && view.paths(world).iter().any(|p| p == "src/checkout.ts")
                && view.file_count(world) == 4,
            "{}",
            view.describe(world)
        );
        Ok(())
    });

    // A note on lines of the diff, for the prompt.
    steps.step(
        &format!("the user comments {Q} on lines (\\d+) to (\\d+) of {Q}"),
        |world, c, _| {
            let (first, last) = (c[1].parse().unwrap_or(0), c[2].parse().unwrap_or(0));
            comment_on(world, &c[0], first, last, &c[3])
        },
    );
    steps.step(
        &format!("the user commented on lines (\\d+) to (\\d+) of {Q}"),
        |world, c, _| {
            let (first, last) = (c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0));
            comment_on(world, "Use the tax table", first, last, &c[2])
        },
    );
    steps.step(
        "the composer carries that comment with the file and line range",
        |world, _, _| {
            world.wait_for("the comment to be on the draft", |w| comments(w).len() == 1)?;
            let chip = comments(world).remove(0);
            expect!(
                chip["label"] == "src/cart.ts L10-12" && chip["text"] == "Use the tax table",
                "the composer carries {}",
                show(&chip)
            );
            // Sent, the message names the chip and carries the note, the
            // file and the lines.
            let message = sent(world)?;
            let records = message["context"]["records"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let record = records.first().cloned().unwrap_or(Value::Null);
            let reference = format!(
                "[src/cart.ts L10-12](hal-c2-context://v1/review-comment/{})",
                record["contextId"].as_str().unwrap_or("")
            );
            expect!(
                message["text"] == format!("Please fix this\n\n{reference}").as_str(),
                "the message reads {}",
                show(&message["text"])
            );
            let span = record["endIndex"].as_i64().unwrap_or(0)
                - record["startIndex"].as_i64().unwrap_or(0);
            expect!(
                records.len() == 1
                    && record["kind"] == "review-comment"
                    && record["filePath"] == "src/cart.ts"
                    && record["rangeLabel"] == "+10 to +12"
                    && record["text"] == "Use the tax table"
                    && record["diff"]
                        == "+export const rate9 = 9;\n+export const rate10 = 10;\n+export const rate11 = 11;"
                    && span == 2,
                "the message carries {}",
                show(&Value::Array(records))
            );
            expect!(
                comments(world).is_empty(),
                "the sent comment is still on the draft"
            );
            Ok(())
        },
    );
    steps.step("the user deletes that comment", |world, _, _| {
        world.wait_for("the comment to be on the draft", |w| comments(w).len() == 1)?;
        // The comment's chip on the composer.
        let id = comments(world)[0]["id"].clone();
        world.dispatch("composer.reviewComment.remove", json!({"id": id}))?;
        world.sync()
    });
    steps.step("the composer no longer carries it", |world, _, _| {
        expect!(
            comments(world).is_empty(),
            "the composer carries {}",
            show(&Value::Array(comments(world)))
        );
        let message = sent(world)?;
        expect!(
            message["text"] == "Please fix this" && message.get("context").is_none(),
            "the message carries {}",
            show(&message)
        );
        Ok(())
    });
}
