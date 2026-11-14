//! Reviewing the checkout beside a thread
//! (features/source-control/review-diffs.feature): the Diff tab over the
//! MC's `review.getDiffPreview`, driven through the DiffPanel brick as the
//! user drives it. The MC's side is faked here: the working tree's patch,
//! and the branch's against each base.
//! The user's editor is WorkspaceSteps' ([`super::workspace::have_editor`]).

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use hal_c2_shell::thread_view::diff::{Diff, DiffModel};
use hal_c2_shell::thread_view::rows::RowSource;
use hal_c2_shell::thread_view::thread_diff::{BRANCH, DiffTab, ThreadDiff};
use ljos::prelude::{ApplicationState, ObjectId, Value as Js};
use serde_json::{Value, json};

use crate::brick::{Brick, Shown, shown};
use hal_c2_shell::controllers::navigation::{Navigation, Route};

use crate::harness::{Failure, Outcome, Q, Steps, at, show};
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
    /// Too large to carry every file's patch: the MC counts each file and
    /// cuts the patch short; a file's own patch is asked for with `file`.
    truncated: bool,
    /// Files it counts but has no patch for.
    unpatched: Vec<Value>,
    /// Files whose own patch is still cut short.
    partial: HashSet<String>,
    /// The next ask for these files' patch fails.
    failing: HashSet<String>,
    /// The checkout no longer has the diff a file is asked from.
    gone: bool,
    /// The MC has no patch of the working tree at all.
    no_source: bool,
    /// What the panel said while it loaded, in order.
    statuses: Rc<RefCell<Vec<String>>>,
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
            truncated: false,
            unpatched: Vec::new(),
            partial: HashSet::new(),
            failing: HashSet::new(),
            gone: false,
            no_source: false,
            statuses: Rc::default(),
        }
    }
}

fn hash_of(text: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

/// Each file's part of a patch, by its path.
fn files_of(patch: &str) -> Vec<(String, String)> {
    let mut starts: Vec<(usize, String)> = Vec::new();
    let mut offset = 0;
    for line in patch.split_inclusive('\n') {
        if let Some(rest) = line.trim_end_matches('\n').strip_prefix("diff --git a/")
            && let Some((_, path)) = rest.split_once(" b/")
        {
            starts.push((offset, path.to_owned()));
        }
        offset += line.len();
    }
    starts
        .iter()
        .enumerate()
        .map(|(i, (start, path))| {
            let end = starts.get(i + 1).map_or(patch.len(), |next| next.0);
            (path.clone(), patch[*start..end].to_owned())
        })
        .collect()
}

/// The counts the MC keeps beside a patch it cut short.
fn stats_of(patch: &str) -> Vec<Value> {
    files_of(patch)
        .into_iter()
        .map(|(path, part)| {
            let added = part
                .lines()
                .filter(|l| l.starts_with('+') && !l.starts_with("+++"))
                .count();
            let removed = part
                .lines()
                .filter(|l| l.starts_with('-') && !l.starts_with("---"))
                .count();
            json!({"path": path, "previousPath": null, "additions": added, "deletions": removed})
        })
        .collect()
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
            let file = rpc.payload["file"]["path"]
                .as_str()
                .unwrap_or("")
                .to_owned();
            if !file.is_empty() && fake.failing.remove(&file) {
                mc.refuse(rpc, "git diff timed out");
                return Ok(());
            }
            let head = fake.head.clone();
            let source = |kind: &str, title: &str, base_ref: Value, whole: &str| {
                let mut diff = whole.to_owned();
                let mut cut = false;
                let mut out = json!({
                    "id": kind, "kind": kind, "title": title,
                    "baseRef": base_ref, "headRef": head,
                });
                if !file.is_empty() {
                    // One file's own patch.
                    diff = files_of(whole)
                        .into_iter()
                        .filter(|(path, _)| *path == file)
                        .map(|(_, part)| part)
                        .next_back()
                        .unwrap_or_default();
                    cut = fake.partial.contains(&file);
                    if cut {
                        diff.push_str("\n\n[truncated]");
                    }
                } else if fake.truncated && kind == "working-tree" {
                    let mut stats = stats_of(whole);
                    stats.extend(fake.unpatched.iter().cloned());
                    out["files"] = Value::Array(stats);
                    diff = files_of(whole)
                        .into_iter()
                        .next()
                        .map(|(_, part)| part)
                        .unwrap_or_default()
                        + "\n\n[truncated]";
                    cut = true;
                }
                out["diffHash"] = json!(format!("hash-{}-{}", whole.len(), hash_of(whole)));
                out["diff"] = json!(diff);
                out["truncated"] = json!(cut);
                out
            };
            let mut sources = Vec::new();
            // A checkout that moved on has no diff the file was listed from.
            let gone = fake.gone && !file.is_empty();
            if !(fake.no_source || gone) {
                sources.push(source(
                    "working-tree",
                    "Working tree",
                    Value::Null,
                    &fake.working_tree,
                ));
            }
            if !gone {
                sources.push(source(
                    "branch-range",
                    "Branch",
                    json!(base),
                    fake.branch.get(&base).map(String::as_str).unwrap_or(""),
                ));
            }
            let result = json!({
                "cwd": rpc.payload["cwd"],
                "generatedAt": "2026-09-23T10:00:00Z",
                "sources": sources,
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
    Ok(view)
}

/// The header of `path`'s file, scrolled into view as the user would.
fn file_header(world: &mut World, view: View, path: &str) -> Outcome<ObjectId> {
    let Some(file) = view.paths(world).iter().position(|p| p == path) else {
        fail!("the diff does not show {path}: {}", view.describe(world));
    };
    let row = view
        .diff(world, |d| d.row_of_file(file))
        .flatten()
        .unwrap_or(0);
    let rows = view.rows(world)?;
    world
        .engine()
        .invoke_by_name(
            rows,
            "positionViewAtIndex",
            &[Js::Int(row as i32), Js::Int(0)],
        )
        .map_err(|e| Failure(format!("positionViewAtIndex: {e:?}")))?;
    world.sync()?;
    let brick = view.brick;
    let name = format!("diffFile-{path}");
    world.wait_for(&format!("the header of {path} to be shown"), |w| {
        matches!(brick.find_visible(w, &name), Ok(Some(_)))
    })?;
    match brick.find_visible(world, &name)? {
        Some(header) => Ok(header),
        None => fail!("the header of {path} went away"),
    }
}

/// The list of bases to compare the branch against, open and loaded.
fn open_bases(world: &mut World, view: View) -> Outcome<ObjectId> {
    let brick = view.brick;
    let bases = brick.item(world, "diffBases")?;
    if !brick.flag(world, bases, "opened") {
        brick.click(world, "diffBasePicker")?;
    }
    world.wait_for("the list of bases to open", |w| {
        brick.flag(w, bases, "opened") && !view.tab(w, |t| t.bases_loading()).unwrap_or(true)
    })?;
    Ok(bases)
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
    let view = open_comment(world, first, last, path)?;
    let brick = view.brick;
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

/// The DiffPanel itself, under the brick's host item.
fn diff_panel(world: &World, view: View) -> Outcome<ObjectId> {
    view.brick.item(world, "diffPanel")
}

/// Steps change the background's thread ("t1") or another of the
/// scenario's.
fn write_to(world: &mut World, thread: &str) {
    let environment = world.mc.environment_id.clone();
    let streams = world.mc.part::<super::stream::FakeStreams>();
    streams.thread = thread.to_owned();
    streams.environment = environment;
}

/// Picks `label` ("Branch changes", "Turn 2") from what the tab can show.
fn pick(world: &mut World, label: &str) -> Outcome {
    let view = panel(world)?;
    let find = |w: &World| {
        view.tab(w, |t| t.choices())
            .unwrap_or_default()
            .into_iter()
            .find(|(_, l)| l == label)
            .map(|(value, _)| value)
    };
    world.wait_for_with(
        |w| find(w).is_some(),
        |w| {
            format!(
                "the diff to offer {label}; it offers {:?}",
                view.tab(w, |t| t.choices()).unwrap_or_default()
            )
        },
    )?;
    let Some(value) = find(world) else {
        fail!("{label} went away");
    };
    view.act(world, |t| t.select(value))?;
    world.sync()?;
    view.wait_loaded(world)
}

fn selection(world: &World, view: View) -> i32 {
    view.tab(world, |t| t.selection()).unwrap_or(0)
}

/// The branch's changes against its base.
fn review_branch(world: &mut World) -> Outcome<View> {
    let view = panel(world)?;
    if selection(world, view) != BRANCH {
        pick(world, "Branch changes")?;
    }
    expect!(
        selection(world, view) == BRANCH && view.status(world) != "error",
        "{}",
        view.describe(world)
    );
    Ok(view)
}

/// The bases the list shows, by label.
fn bases_shown(world: &World, view: View) -> Vec<String> {
    let labels: Vec<String> = view
        .tab(world, |t| t.base_choices())
        .unwrap_or_default()
        .iter()
        .filter_map(|c| c["label"].as_str().map(str::to_owned))
        .collect();
    labels
        .into_iter()
        .filter(|label| {
            matches!(
                view.brick
                    .find_visible(world, &format!("diffBaseChoice-{label}")),
                Ok(Some(_))
            )
        })
        .collect()
}

/// Types `text` in the search of the bases.
fn search_bases(world: &mut World, text: &str) -> Outcome<View> {
    let view = review_branch(world)?;
    open_bases(world, view)?;
    view.brick.click(world, "diffBaseRef")?;
    world.type_text(text)?;
    world.sync()?;
    Ok(view)
}

/// Picks a base as the user does: the one listed, else the ref typed.
fn pick_base(world: &mut World, wanted: &str) -> Outcome {
    let view = review_branch(world)?;
    let brick = view.brick;
    let bases = open_bases(world, view)?;
    if wanted != "Automatic" {
        brick.click(world, "diffBaseRef")?;
        world.type_text(wanted)?;
        world.sync()?;
    }
    if bases_shown(world, view).iter().any(|b| b == wanted) {
        brick.click(world, &format!("diffBaseChoice-{wanted}"))?;
    } else {
        brick.press(world, "enter")?;
    }
    world.sync()?;
    view.wait_loaded(world)?;
    expect!(
        !brick.flag(world, bases, "opened"),
        "the list of bases stayed open"
    );
    Ok(())
}

fn file_index(world: &World, view: View, path: &str) -> Outcome<usize> {
    match view.diff(world, |d| d.file_of(path)).flatten() {
        Some(file) => Ok(file),
        None => fail!("{path} is not in the diff; {}", view.describe(world)),
    }
}

/// A shown item of `path`'s heading.
fn in_heading(world: &mut World, view: View, path: &str, name: &str) -> Outcome<ObjectId> {
    let brick = view.brick;
    for _ in 0..50 {
        let header = file_header(world, view, path)?;
        if let Some(item) = brick.find_under(world, header, name)?
            && brick.flag(world, item, "visible")
        {
            return Ok(item);
        }
        world.advance(50)?;
    }
    fail!("the heading of {path} does not show {name}")
}

/// Clicks `item` at its centre.
fn click_item(world: &mut World, view: View, item: ObjectId) -> Outcome {
    let (x, y) = view.brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

fn expanded(world: &World, view: View, path: &str) -> bool {
    view.diff(world, |d| d.file_of(path).is_some_and(|f| d.expanded(f)))
        .unwrap_or(false)
}

fn state_of(world: &World, view: View, path: &str) -> String {
    view.diff(world, |d| {
        d.file_of(path)
            .map(|f| d.state(f).to_owned())
            .unwrap_or_else(|| "missing".into())
    })
    .unwrap_or_default()
}

/// Clicks `path`'s heading, which opens or closes its file.
fn toggle_in_diff(world: &mut World, view: View, path: &str) -> Outcome {
    let header = file_header(world, view, path)?;
    let height = view.number(world, header, "height").max(1.0);
    let (x, y) = view.brick.at(world, header, 0.3, 16.0 / height)?;
    world.click_at(x, y)?;
    world.sync()
}

/// Opens `path`'s file by its heading.
fn open_in_diff(world: &mut World, path: &str) -> Outcome {
    let view = panel(world)?;
    file_index(world, view, path)?;
    expect!(!expanded(world, view, path), "{path} is open already");
    toggle_in_diff(world, view, path)?;
    expect!(expanded(world, view, path), "{path} did not open");
    Ok(())
}

/// The lines `path` shows.
fn lines_of(world: &World, view: View, path: &str) -> usize {
    view.diff(world, |d| {
        let Some(file) = d.file_of(path) else {
            return 0;
        };
        let start = d.row_of_file(file).unwrap_or(0);
        let next = d.row_of_file(file + 1).unwrap_or(d.row_count());
        next.saturating_sub(start + 1)
    })
    .unwrap_or(0)
}

fn tree_listing(world: &World, view: View) -> Vec<String> {
    view.diff(world, |d| d.tree())
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
        .collect()
}

/// The file tree shown beside the diff.
fn show_tree(world: &mut World, view: View) -> Outcome<ObjectId> {
    let brick = view.brick;
    let tree = brick.item(world, "diffTreeRows")?;
    if !brick.flag(world, tree, "visible") {
        choose_option(world, "diffTree")?;
    }
    world.wait_for("the file tree to be shown", |w| {
        brick.flag(w, tree, "visible")
    })?;
    Ok(tree)
}

/// The tree's row for `path`.
fn tree_node(world: &mut World, path: &str) -> Outcome<ObjectId> {
    let view = panel(world)?;
    let brick = view.brick;
    show_tree(world, view)?;
    world.wait_for_with(
        |w| matches!(brick.tree_node(w, path), Ok(Some(_))),
        |w| {
            format!(
                "the tree to list {path}; it lists {}",
                tree_listing(w, view).join(", ")
            )
        },
    )?;
    match brick.tree_node(world, path)? {
        Some(node) => Ok(node),
        None => fail!("the tree no longer lists {path}"),
    }
}

fn choose_in_tree(world: &mut World, path: &str) -> Outcome {
    let view = panel(world)?;
    let node = tree_node(world, path)?;
    click_item(world, view, node)
}

/// The visible items called `name`.
fn count_visible(world: &World, brick: Brick, name: &str) -> usize {
    (0..)
        .take_while(|n| matches!(brick.find_visible_nth(world, name, *n), Ok(Some(_))))
        .count()
}

/// The list scrolled to its end, away from `path`.
fn scroll_away(world: &mut World, view: View, path: &str) -> Outcome {
    let rows = view.rows(world)?;
    world
        .engine()
        .invoke_by_name(rows, "positionViewAtEnd", &[])
        .map_err(|e| Failure(format!("positionViewAtEnd: {e:?}")))?;
    world.sync()?;
    world.wait_for("the diff to scroll away", |w| {
        view.file_at_top(w).is_ok_and(|top| top != path)
    })
}

/// The run of the checkpoint the thread's turn `turn` left.
fn run_of(world: &mut World, turn: i32) -> String {
    let streams = world.mc.part::<super::stream::FakeStreams>();
    streams
        .threads
        .get(&streams.thread)
        .and_then(|entities| entities.get(&format!("checkpoint\ncp-{turn}")))
        .and_then(|checkpoint| checkpoint["runId"].as_str())
        .unwrap_or_default()
        .to_owned()
}

/// A thread of the project "shop" beside the background's.
fn add_thread(world: &mut World, id: &str, title: &str, fields: Value) -> Outcome {
    let mut row = json!({"id": id, "title": title, "projectId": "shop", "branch": "feature/tax",
                         "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    if let (Some(row), Value::Object(fields)) = (row.as_object_mut(), fields) {
        row.extend(fields);
    }
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
    world.sync()
}

fn id_of_title(world: &World, title: &str) -> Outcome<String> {
    match world
        .mc
        .threads
        .iter()
        .find(|(_, row)| row["title"] == title)
    {
        Some((id, _)) => Ok(id.clone()),
        None => fail!("no thread is called {title}"),
    }
}

fn open_thread(world: &mut World, id: &str) -> Outcome {
    let key = format!("{}:{id}", world.mc.environment_id);
    let route = key.clone();
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Thread(route)))?;
    world.wait_for(&format!("the thread {id} to open"), |w| {
        at(&w.state("workspace"), "threadKey").as_str() == Some(key.as_str())
    })?;
    // Its Diff tab, should the thread not have it open.
    world.dispatch("panel.open", json!({"tab": "diff"}))?;
    world.sync()
}

/// The first record of the context a message carried.
fn first_record(message: &Value) -> Value {
    message["context"]["records"][0].clone()
}

/// A note with a code block pasted in.
const FENCED_NOTE: &str =
    "Use this instead:\n```ts\nexport const rate = taxTable[band];\n```\nThanks";

/// The message a scenario sent.
#[derive(Default)]
struct SentReview(Value);

/// The comment box on lines `first` to `last` of `path`.
fn open_comment(world: &mut World, first: i32, last: i32, path: &str) -> Outcome<View> {
    let view = panel(world)?;
    let brick = view.brick;
    let file = file_index(world, view, path)?;
    world.wait_for(&format!("line {first} of {path} to be shown"), |w| {
        matches!(brick.line_comment(w, file, first), Ok(Some(_)))
    })?;
    let Some(button) = brick.line_comment(world, file, first)? else {
        fail!("line {first} of {path} went away");
    };
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
    click_item(world, view, button)?;
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
    Ok(view)
}

/// The keys of the scenario go to the shown brick.
fn keys_to_brick(world: &mut World) {
    if let Some(brick) = &mut world.part::<Shown>().0 {
        brick.takes_keys = true;
    }
}

fn popup_opened(world: &World, view: View, name: &str) -> bool {
    view.brick
        .find(world, name)
        .ok()
        .flatten()
        .is_some_and(|popup| view.brick.flag(world, popup, "opened"))
}

/// Shows `why` once the pointer rests on `item`.
fn hover_shows(world: &mut World, view: View, item: ObjectId, why: &str) -> Outcome {
    let (x, y) = view.brick.at(world, item, 0.5, 0.5)?;
    world.hover_at(x - 30.0, y)?;
    world.hover_at(x, y)?;
    for _ in 0..20 {
        if view.brick.shows(world, why)? {
            return Ok(());
        }
        world.advance(100)?;
    }
    fail!("the pointer on it does not show {why}")
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
    steps.step(
        &format!("the user opens {Q} from the diff"),
        |world, c, _| {
            super::workspace::have_editor(world, &c[0])?;
            let view = panel(world)?;
            let brick = view.brick;
            let header = file_header(world, view, &c[0])?;
            let button = brick.find_under(world, header, "diffOpenInEditor")?;
            let Some(button) = button.filter(|b| brick.flag(world, *b, "visible")) else {
                fail!("{} cannot be opened from the diff", c[0]);
            };
            let (x, y) = brick.at(world, button, 0.5, 0.5)?;
            world.click_at(x, y)?;
            world.sync()
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
            let bases = open_bases(world, view)?;
            let wanted = &c[0];
            if wanted != "Automatic" {
                brick.click(world, "diffBaseRef")?;
                world.type_text(wanted)?;
                world.sync()?;
            }
            match brick.find_visible(world, &format!("diffBaseChoice-{wanted}"))? {
                Some(choice) => {
                    let (x, y) = brick.at(world, choice, 0.5, 0.5)?;
                    world.click_at(x, y)?;
                }
                None => {
                    brick.press(world, "enter")?;
                }
            }
            world.sync()?;
            view.wait_loaded(world)?;
            expect!(
                !brick.flag(world, bases, "opened"),
                "the list of bases stayed open"
            );
            Ok(())
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
        world.wait_for_with(
            |w| view.file_at_top(w).is_ok_and(|top| top == "src/tax.ts"),
            |w| {
                format!(
                    "the diff to jump to src/tax.ts; its top is {:?}",
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

    // Too narrow to wrap.
    steps.step("the user wraps long lines in the diff", |world, _, _| {
        let view = panel(world)?;
        let rows = view.rows(world)?;
        view.act(world, |t| t.set_wrap(true))?;
        world.wait_for("the long lines to wrap", |w| {
            view.number(w, rows, "contentWidth") <= view.number(w, rows, "width")
        })
    });
    steps.step(
        "the diff has room for fewer than forty characters of code",
        |world, _, _| {
            let view = panel(world)?;
            // A sheet in a 900px window.
            world.resize(380.0, 420.0)?;
            let root = diff_panel(world, view)?;
            world.wait_for_with(
                |w| view.number(w, root, "codeWidth") < view.number(w, root, "wrapFloor"),
                |w| {
                    format!(
                        "a line of code to have less than {}px; it has {}",
                        view.number(w, root, "wrapFloor"),
                        view.number(w, root, "codeWidth")
                    )
                },
            )
        },
    );
    steps.step(
        "long lines scroll sideways under their line numbers",
        |world, _, _| {
            let view = panel(world)?;
            let rows = view.rows(world)?;
            let root = diff_panel(world, view)?;
            world.wait_for_with(
                |w| {
                    !view.brick.flag(w, root, "wrap")
                        && view.number(w, rows, "contentWidth") > view.number(w, rows, "width")
                },
                |w| {
                    format!(
                        "the rows to scroll sideways; they are {} wide in {}",
                        view.number(w, rows, "contentWidth"),
                        view.number(w, rows, "width")
                    )
                },
            )?;
            expect!(
                view.wrap(world),
                "the narrow panel turned the wrap setting off"
            );
            Ok(())
        },
    );
    steps.step("they wrap again once the diff is wider", |world, _, _| {
        let view = panel(world)?;
        let rows = view.rows(world)?;
        let root = diff_panel(world, view)?;
        world.resize(900.0, 420.0)?;
        world.wait_for_with(
            |w| {
                view.brick.flag(w, root, "wrap")
                    && view.number(w, rows, "contentWidth") <= view.number(w, rows, "width")
            },
            |w| {
                format!(
                    "the rows to wrap again; they are {} wide in {}",
                    view.number(w, rows, "contentWidth"),
                    view.number(w, rows, "width")
                )
            },
        )
    });

    // Following the checkout.
    steps.step("the user is reviewing the working tree", |world, _, _| {
        let view = panel(world)?;
        expect!(
            selection(world, view) == -1
                && view.tab(world, |t| t.reviewing()).unwrap_or(false)
                && view.status(world) == "ready",
            "{}",
            view.describe(world)
        );
        let statuses = fake(world).statuses.clone();
        let tab = view.tab;
        world
            .engine()
            .connect_by_name(tab, "statusChanged", move |engine, _| {
                let status = engine.to_js_string(&engine.read_by_name(tab, "status"));
                statuses.borrow_mut().push(status.to_string());
            })
            .map_err(|e| Failure(format!("statusChanged: {e:?}")))?;
        // What the agent's edit of src/cart.ts (the Files steps' "the agent
        // changes") leaves.
        write_to(world, "t1");
        let mut cart = lines("rate", 60);
        cart.push("x".repeat(300));
        cart.push("export const agent = true;".into());
        fake(world).working_tree = patch_changing("src/cart.ts", &cart)
            + &patch_changing("src/tax.ts", &lines("band", 3))
            + &patch_changing("README.md", &lines("note", 40));
        Ok(())
    });
    fn never_loading(world: &mut World) -> Outcome {
        let statuses = fake(world).statuses.borrow().clone();
        expect!(
            !statuses.iter().any(|s| s == "loading"),
            "the diff went {} meanwhile",
            statuses.join(", ")
        );
        Ok(())
    }
    steps.step(
        "the diff shows the new changes without the user refreshing",
        |world, _, _| {
            let view = panel(world)?;
            world.wait_for_with(
                |w| view.diff(w, |d| d.additions()) == Some(105),
                |w| {
                    format!(
                        "the agent's line to be shown; the diff adds {:?} lines",
                        view.diff(w, |d| d.additions())
                    )
                },
            )?;
            never_loading(world)
        },
    );
    steps.step(
        "coming back to the window after working elsewhere shows the checkout as it is now",
        |world, _, _| {
            let view = panel(world)?;
            ljos::testing::set_application_state(world.engine(), ApplicationState::Inactive);
            world.sync()?;
            // Changed elsewhere, with nothing in the thread to say so.
            fake(world).working_tree +=
                &patch_changing("src/checkout.ts", &["export const total = 1;".to_owned()]);
            ljos::testing::set_application_state(world.engine(), ApplicationState::Active);
            world.wait_for_with(
                |w| view.paths(w).iter().any(|p| p == "src/checkout.ts"),
                |w| view.describe(w),
            )?;
            never_loading(world)
        },
    );

    // The branch's base.
    steps.step(
        &format!("the branch {Q} was started from {Q}"),
        |world, c, _| {
            let fake = fake(world);
            fake.head = c[0].clone();
            fake.automatic_base = c[1].clone();
            Ok(())
        },
    );
    steps.step("the user reviews the branch changes", |world, _, _| {
        review_branch(world).map(drop)
    });
    steps.step(
        &format!("the diff compares against {Q} and the choice of base reads {Q}"),
        |world, c, _| {
            let view = panel(world)?;
            let picker = view.brick.item(world, "diffBasePicker")?;
            let shown = view.brick.text_of(world, picker, "text");
            expect!(
                view.status(world) == "ready" && view.compared_base(world) == c[0] && shown == c[1],
                "{} against {}, the base reads {shown}",
                view.describe(world),
                view.compared_base(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user picks {Q} (?:as the base|again)"),
        |world, c, _| pick_base(world, &c[0]),
    );
    steps.step(&format!("the diff compares against {Q}"), |world, c, _| {
        let view = panel(world)?;
        let whole = fake(world).branch.get(&c[0]).cloned().unwrap_or_default();
        let wanted: Vec<String> = files_of(&whole).into_iter().map(|(p, _)| p).collect();
        expect!(
            view.status(world) == "ready"
                && view.compared_base(world) == c[0]
                && view.paths(world) == wanted,
            "{} against {}",
            view.describe(world),
            view.compared_base(world)
        );
        let picker = view.brick.item(world, "diffBasePicker")?;
        let shown = view.brick.text_of(world, picker, "text");
        let automatic = c[0] == fake(world).automatic_base
            && view
                .tab(world, |t| t.base_ref().is_empty())
                .unwrap_or(false);
        let reads = if automatic {
            "Automatic"
        } else {
            c[0].as_str()
        };
        expect!(shown == reads, "the base reads {shown}");
        Ok(())
    });
    steps.step(
        &format!("{Q} exists on the remote and has no local branch"),
        |world, c, _| {
            super::workspace::fake_git_branches(world, "/work/shop", &[], &[&c[0]]);
            Ok(())
        },
    );
    steps.step(&format!("{Q} exists locally and as {Q}"), |world, c, _| {
        super::workspace::fake_git_branches(world, "/work/shop", &[&c[0]], &[&c[1]]);
        Ok(())
    });
    steps.step(
        &format!("the user searches the bases to compare against for {Q}"),
        |world, c, _| search_bases(world, &c[0]).map(drop),
    );
    steps.step(
        "the user opens the bases to compare against",
        |world, _, _| {
            let view = review_branch(world)?;
            open_bases(world, view).map(drop)
        },
    );
    steps.step(
        &format!("{Q} is offered and marked as remote only"),
        |world, c, _| {
            let view = panel(world)?;
            let wanted = vec![c[0].clone()];
            world.wait_for_with(
                |w| bases_shown(w, view) == wanted,
                |w| {
                    format!(
                        "only {} to be offered; {} are",
                        wanted[0],
                        bases_shown(w, view).join(", ")
                    )
                },
            )?;
            let brick = view.brick;
            let choice = brick.item(world, &format!("diffBaseChoice-{}", c[0]))?;
            expect!(
                brick
                    .find_under(world, choice, "diffBaseRemoteOnly")?
                    .is_some(),
                "{} is not marked as remote only",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(
        "a search that matches nothing says no refs match",
        |world, _, _| {
            let view = panel(world)?;
            world.type_text("zzz")?;
            world.sync()?;
            let brick = view.brick;
            let empty = brick.item(world, "diffBaseEmpty")?;
            world.wait_for_with(
                |w| bases_shown(w, view).is_empty() && brick.flag(w, empty, "visible"),
                |w| {
                    format!(
                        "nothing to be offered; {} are",
                        bases_shown(w, view).join(", ")
                    )
                },
            )?;
            let text = brick.text_of(world, empty, "text");
            expect!(text == "No matching refs.", "the list says {text}");
            Ok(())
        },
    );
    steps.step(&format!("{Q} is offered once"), |world, c, _| {
        let view = panel(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(
            |w| bases_shown(w, view).contains(&wanted),
            |w| {
                format!(
                    "{wanted} to be offered; {} are",
                    bases_shown(w, view).join(", ")
                )
            },
        )?;
        let shown = bases_shown(world, view);
        expect!(
            shown.iter().filter(|b| **b == c[0]).count() == 1
                && !shown.contains(&format!("origin/{}", c[0])),
            "the bases are {}",
            shown.join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("searching for {Q} finds that same entry"),
        |world, c, _| {
            let view = search_bases(world, &c[0])?;
            world.wait_for_with(
                |w| bases_shown(w, view) == ["release"],
                |w| {
                    format!(
                        "the search to find release; it finds {}",
                        bases_shown(w, view).join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("choosing it compares against the local {Q}"),
        |world, c, _| {
            let view = panel(world)?;
            view.brick
                .click(world, &format!("diffBaseChoice-{}", c[0]))?;
            world.sync()?;
            view.wait_loaded(world)?;
            let asked = fake(world).asked.last().cloned().unwrap_or(Value::Null);
            expect!(
                view.tab(world, |t| t.base_ref() == c[0]).unwrap_or(false)
                    && view.compared_base(world) == c[0]
                    && asked["baseRef"] == c[0].as_str(),
                "the MC was asked {}",
                show(&asked)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is reviewing the changes of {Q}"),
        |world, c, _| {
            let view = review_branch(world)?;
            let head = view
                .tab(world, |t| t.compared_head().to_owned())
                .unwrap_or_default();
            expect!(head == c[0], "the diff is of {head}");
            Ok(())
        },
    );
    steps.step(&format!("{Q} is not among the bases"), |world, c, _| {
        let view = panel(world)?;
        // The checkout's other branch is, so the refs are listed.
        world.wait_for_with(
            |w| bases_shown(w, view).iter().any(|b| b == "main"),
            |w| {
                format!(
                    "main to be offered; {} are",
                    bases_shown(w, view).join(", ")
                )
            },
        )?;
        let shown = bases_shown(world, view);
        expect!(!shown.contains(&c[0]), "the bases are {}", shown.join(", "));
        Ok(())
    });

    // A diff too large to load whole.
    steps.step(
        "the changes are too large for the diff to carry every file's patch",
        |world, _, _| {
            let fake = fake(world);
            fake.truncated = true;
            fake.unpatched
                .push(json!({"path": "assets/data.bin", "previousPath": null,
                                       "additions": 5000, "deletions": 0}));
            Ok(())
        },
    );
    steps.step("the user reviews the changes", |world, _, _| {
        panel(world).map(drop)
    });
    steps.step(
        "the diff says it is incomplete while its totals still cover every change",
        |world, _, _| {
            let view = panel(world)?;
            expect!(
                view.status(world) == "ready"
                    && view.tab(world, |t| t.truncated()).unwrap_or(false),
                "{}",
                view.describe(world)
            );
            let note = view.brick.item(world, "diffTruncated")?;
            expect!(
                view.brick.flag(world, note, "visible"),
                "the diff does not say it is incomplete"
            );
            let (files, added, removed) = view
                .diff(world, |d| (d.file_count(), d.additions(), d.deletions()))
                .unwrap_or_default();
            expect!(
                files == 4 && added == 104 + 5000 && removed == 3,
                "{files} files, +{added} -{removed}"
            );
            for path in view.paths(world) {
                let state = state_of(world, view, &path);
                expect!(
                    !expanded(world, view, &path) && state == "unloaded",
                    "{path} is {state}"
                );
            }
            Ok(())
        },
    );
    steps.step(
        "a file's changes are loaded when the user opens that file",
        |world, _, _| {
            let asked = fake(world).asked.len();
            // Nothing is asked for a file before it is opened.
            expect!(asked == 1, "the MC was asked {asked} times");
            open_in_diff(world, "src/tax.ts")?;
            let view = panel(world)?;
            world.wait_for_with(
                |w| state_of(w, view, "src/tax.ts").is_empty(),
                |w| {
                    format!(
                        "src/tax.ts to load; it is {}",
                        state_of(w, view, "src/tax.ts")
                    )
                },
            )?;
            let last = fake(world).asked.last().cloned().unwrap_or(Value::Null);
            expect!(
                last["file"]["path"] == "src/tax.ts",
                "the MC was asked {}",
                show(&last)
            );
            let shown = lines_of(world, view, "src/tax.ts");
            expect!(shown > 3, "src/tax.ts shows {shown} lines");
            // The others are still unloaded.
            expect!(
                state_of(world, view, "src/cart.ts") == "unloaded",
                "src/cart.ts was loaded too"
            );
            Ok(())
        },
    );
    steps.step(
        "a file whose changes cannot be loaded says no patch is available for it",
        |world, _, _| {
            let path = "assets/data.bin";
            open_in_diff(world, path)?;
            let view = panel(world)?;
            let note = in_heading(world, view, path, "diffFileNote")?;
            let brick = view.brick;
            world.wait_for_with(
                |w| brick.text_of(w, note, "text") == "No patch available for this file.",
                |w| {
                    format!(
                        "the file to say why; it says {}",
                        brick.text_of(w, note, "text")
                    )
                },
            )
        },
    );

    // One file's changes.
    steps.step(
        &format!("{Q} has changes too large to show in full"),
        |world, c, _| {
            let fake = fake(world);
            fake.truncated = true;
            fake.partial.insert(c[0].clone());
            Ok(())
        },
    );
    steps.step(
        &format!("loading the changes of {Q} failed"),
        |world, c, _| {
            let fake = fake(world);
            fake.truncated = true;
            fake.failing.insert(c[0].clone());
            Ok(())
        },
    );
    steps.step(&format!("the user opens {Q} in the diff"), |world, c, _| {
        open_in_diff(world, &c[0])
    });
    steps.step("the file is marked as a partial preview", |world, _, _| {
        let view = panel(world)?;
        in_heading(world, view, "src/cart.ts", "diffFilePartial")?;
        expect!(
            lines_of(world, view, "src/cart.ts") > 0,
            "the partial file shows no lines"
        );
        Ok(())
    });
    steps.step(
        "the mark explains that the file is too large to show in full and that the counts include all changes",
        |world, _, _| {
            let view = panel(world)?;
            let mark = in_heading(world, view, "src/cart.ts", "diffFilePartial")?;
            let why = "This file is too large to show in full. Counts include all changes.";
            expect!(
                !view.brick.shows(world, why)?,
                "the explanation is shown before the pointer is over the mark"
            );
            hover_shows(world, view, mark, why)
        },
    );
    steps.step(
        "the file offers to retry loading the diff",
        |world, _, _| {
            let view = panel(world)?;
            in_heading(world, view, "src/cart.ts", "diffFileRetry")?;
            let note = in_heading(world, view, "src/cart.ts", "diffFileNote")?;
            let text = view.brick.text_of(world, note, "text");
            expect!(text == "git diff timed out", "the file says {text}");
            Ok(())
        },
    );
    steps.step(
        "the user retries and the environment answers",
        |world, _, _| {
            let view = panel(world)?;
            let retry = in_heading(world, view, "src/cart.ts", "diffFileRetry")?;
            click_item(world, view, retry)
        },
    );
    steps.step(&format!("the changes of {Q} are shown"), |world, c, _| {
        let view = panel(world)?;
        let path = c[0].clone();
        world.wait_for_with(
            |w| state_of(w, view, &path).is_empty() && lines_of(w, view, &path) > 60,
            |w| {
                format!(
                    "{path} to show its lines; it is {} with {}",
                    state_of(w, view, &path),
                    lines_of(w, view, &path)
                )
            },
        )
    });
    steps.step(
        "the user opened a diff and the checkout was changed so that this diff no longer exists",
        |world, _, _| {
            fake(world).truncated = true;
            let view = panel(world)?;
            expect!(
                view.tab(world, |t| t.truncated()).unwrap_or(false) && view.file_count(world) == 3,
                "{}",
                view.describe(world)
            );
            let fake = fake(world);
            fake.gone = true;
            fake.working_tree = patch_changing("src/tax.ts", &lines("band", 3));
            Ok(())
        },
    );
    steps.step(&format!("the file says {Q}"), |world, c, _| {
        let view = panel(world)?;
        let note = in_heading(world, view, "src/cart.ts", "diffFileNote")?;
        let brick = view.brick;
        world.wait_for_with(
            |w| brick.text_of(w, note, "text") == c[0],
            |w| format!("the file says {}", brick.text_of(w, note, "text")),
        )
    });
    steps.step(
        "the files that still differ are listed again",
        |world, _, _| {
            let view = panel(world)?;
            expect!(
                view.status(world) == "ready"
                    && view.paths(world) == ["src/tax.ts", "src/checkout.ts"],
                "{}",
                view.describe(world)
            );
            Ok(())
        },
    );

    // Nothing to show.
    steps.step(
        "the user reviews a selection that changed nothing",
        |world, _, _| {
            write_to(world, "t1");
            super::panel::finish_turn_with_patch(world, 1, "", &[])?;
            panel(world).map(drop)
        },
    );
    steps.step(
        "the user reviews a selection the MC has no patch for",
        |world, _, _| {
            fake(world).no_source = true;
            panel(world).map(drop)
        },
    );
    steps.step(&format!("the diff says {Q}"), |world, c, _| {
        let view = panel(world)?;
        let brick = view.brick;
        let message = brick.item(world, "diffMessage")?;
        world.wait_for_with(
            |w| brick.flag(w, message, "visible") && brick.shows(w, &c[0]).unwrap_or(false),
            |w| format!("the diff to say {}; {}", c[0], view.describe(w)),
        )
    });

    // Each thread's own choice.
    steps.step(
        &format!(
            "the user reviews {Q} in the thread {Q} and the branch against {Q} in the thread {Q}"
        ),
        |world, c, _| {
            // The background's thread is the first.
            if let Some(row) = world.mc.threads.get_mut("t1") {
                row["title"] = json!(c[1]);
            }
            write_to(world, "t1");
            for (turn, name) in [(1, "one"), (2, "two"), (3, "three")] {
                let patch = patch_changing(
                    &format!("src/turn{turn}.ts"),
                    &[format!("export const {name} = {turn};")],
                );
                super::panel::finish_turn_with_patch(world, turn, &patch, &[])?;
            }
            pick(world, &c[0])?;
            let view = panel(world)?;
            expect!(
                view.tab(world, |t| t.shown_turn()) == Some(2),
                "{}",
                view.describe(world)
            );
            add_thread(world, "fees", &c[3], json!({}))?;
            open_thread(world, "fees")?;
            pick_base(world, &c[2])?;
            expect!(
                view.compared_base(world) == c[2],
                "{}",
                view.describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user switches between {Q} and {Q}"),
        |world, c, _| {
            let id = id_of_title(world, &c[0])?;
            open_thread(world, &id)?;
            let view = panel(world)?;
            world.wait_for_with(|w| view.status(w) == "ready", |w| view.describe(w))
        },
    );
    steps.step(
        "each thread shows its own selection with its own base",
        |world, _, _| {
            let view = panel(world)?;
            // Tax, open now.
            world.wait_for_with(
                |w| selection(w, view) == 2 && view.status(w) == "ready",
                |w| format!("Tax to show turn 2; {}", view.describe(w)),
            )?;
            expect!(
                view.paths(world) == ["src/turn2.ts"],
                "{}",
                view.describe(world)
            );
            open_thread(world, "fees")?;
            world.wait_for_with(
                |w| selection(w, view) == BRANCH && view.status(w) == "ready",
                |w| format!("Fees to show its branch; {}", view.describe(w)),
            )?;
            expect!(
                view.tab(world, |t| t.base_ref() == "origin/main")
                    .unwrap_or(false)
                    && view.compared_base(world) == "origin/main",
                "Fees compares against {}",
                view.compared_base(world)
            );
            let picker = view.brick.item(world, "diffBasePicker")?;
            expect!(
                view.brick.text_of(world, picker, "text") == "origin/main",
                "the base does not read origin/main"
            );
            Ok(())
        },
    );
    steps.step(
        "a thread that was never reviewed opens on the working tree without needing git status",
        |world, _, _| {
            // A worktree whose git status the MC never sends.
            let worktree = "/work/shop-new";
            add_thread(
                world,
                "fresh",
                "New work",
                json!({"worktreePath": worktree}),
            )?;
            open_thread(world, "fresh")?;
            let view = panel(world)?;
            world.wait_for_with(
                |w| {
                    view.tab(w, |t| t.reviewing()).unwrap_or(false)
                        && selection(w, view) == -1
                        && view.status(w) == "ready"
                },
                |w| format!("the working tree; {}", view.describe(w)),
            )?;
            let asked = fake(world).asked.last().cloned().unwrap_or(Value::Null);
            expect!(
                asked["cwd"] == worktree && asked.get("baseRef").is_none(),
                "the MC was asked {}",
                show(&asked)
            );
            Ok(())
        },
    );

    // A turn that is rolled back.
    steps.step(
        &format!("the user is reviewing {Q} of the thread"),
        |world, c, _| {
            write_to(world, "t1");
            for turn in 1..=3 {
                let patch = patch_changing(
                    &format!("src/turn{turn}.ts"),
                    &[format!("export const turn = {turn};")],
                );
                super::panel::finish_turn_with_patch(world, turn, &patch, &[])?;
            }
            pick(world, &c[0])?;
            let view = panel(world)?;
            expect!(
                selection(world, view) == 3 && view.status(world) == "ready",
                "{}",
                view.describe(world)
            );
            Ok(())
        },
    );
    steps.step("the thread is rolled back to turn (\\d+)", |world, c, _| {
        let kept: i32 = c[0].parse().unwrap_or(0);
        // As the MC's rollback does: the later runs are rolled back,
        // their checkpoints stale.
        for turn in kept + 1..=3 {
            let run = run_of(world, turn);
            super::stream::set(world, "run", &run, json!({"status": "rolled_back"}))?;
            super::stream::set(
                world,
                "checkpoint",
                &format!("cp-{turn}"),
                json!({"status": "stale"}),
            )?;
        }
        world.sync()
    });
    steps.step("the diff shows the latest turn", |world, _, _| {
        let view = panel(world)?;
        world.wait_for_with(
            |w| {
                view.tab(w, |t| t.latest_turn() == 2 && t.shown_turn() == 2)
                    .unwrap_or(false)
                    && view.status(w) == "ready"
            },
            |w| {
                format!(
                    "turn 2; the diff shows turn {:?} of {:?}: {}",
                    view.tab(w, |t| t.shown_turn()),
                    view.tab(w, |t| t.latest_turn()),
                    view.describe(w)
                )
            },
        )?;
        expect!(
            view.paths(world) == ["src/turn2.ts"],
            "{}",
            view.describe(world)
        );
        let picker = view.brick.item(world, "diffTurnPicker")?;
        let picked = view.brick.text_of(world, picker, "currentText");
        expect!(picked.contains("Latest"), "the picker reads {picked}");
        Ok(())
    });

    // The file tree.
    steps.step(&format!("{Q} is collapsed in the diff"), |world, c, _| {
        let view = panel(world)?;
        toggle_in_diff(world, view, &c[0])?;
        expect!(!expanded(world, view, &c[0]), "{} did not collapse", c[0]);
        Ok(())
    });
    steps.step(
        &format!("the user (?:chooses {Q} in the file tree|scrolls away and chooses {Q} again)"),
        |world, c, _| {
            let path = c
                .iter()
                .find(|p| !p.is_empty())
                .cloned()
                .unwrap_or_default();
            let view = panel(world)?;
            // Somewhere else first, so choosing it has to scroll.
            scroll_away(world, view, &path)?;
            choose_in_tree(world, &path)
        },
    );
    steps.step(
        &format!("{Q} (?:opens and is scrolled to|is scrolled to again)"),
        |world, c, _| {
            let view = panel(world)?;
            let path = c[0].clone();
            world.wait_for_with(
                |w| expanded(w, view, &path) && view.file_at_top(w).is_ok_and(|top| top == path),
                |w| {
                    format!(
                        "{path} open at the top; the top is {:?}",
                        view.file_at_top(w)
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user closed the folder {Q} in the diff's file tree"),
        |world, c, _| {
            fake(world).working_tree += &patch_changing(
                &format!("{}/money.ts", c[0]),
                &["export const cents = 100;".to_owned()],
            );
            choose_in_tree(world, &c[0])?;
            let view = panel(world)?;
            expect!(
                !view.diff(world, |d| d.folder_open(&c[0])).unwrap_or(true),
                "{} is still open",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(
        &format!("a refresh brings a new changed file in {Q}"),
        |world, c, _| {
            let path = format!("{}/round.ts", c[0]);
            fake(world).working_tree +=
                &patch_changing(&path, &["export const round = Math.round;".to_owned()]);
            choose_option(world, "diffReload")?;
            let view = panel(world)?;
            view.wait_loaded(world)?;
            world.wait_for_with(|w| view.paths(w).contains(&path), |w| view.describe(w))
        },
    );
    steps.step(&format!("{Q} stays closed"), |world, c, _| {
        let view = panel(world)?;
        expect!(
            !view.diff(world, |d| d.folder_open(&c[0])).unwrap_or(true),
            "{} opened again",
            c[0]
        );
        tree_node(world, &c[0])?;
        let shown = count_visible(world, view.brick, "diffTreeNode");
        expect!(
            shown == 5,
            "the tree shows {shown} rows of {}",
            tree_listing(world, view).join(", ")
        );
        Ok(())
    });
    steps.step("the new file is listed in it", |world, _, _| {
        let view = panel(world)?;
        let listed = tree_listing(world, view);
        let folder = listed.iter().position(|l| l == " lib/");
        expect!(
            folder.is_some_and(|f| listed[f + 1..]
                .starts_with(&["  money.ts".to_owned(), "  round.ts".to_owned()])),
            "the tree lists {}",
            listed.join(", ")
        );
        // The way back: opened, the folder shows it.
        choose_in_tree(world, "src/lib")?;
        tree_node(world, "src/lib/round.ts").map(drop)
    });
    steps.step(
        &format!("the diff changes {Q} before {Q} before {Q}"),
        |world, c, _| {
            let fake = fake(world);
            fake.working_tree.clear();
            for path in c {
                fake.working_tree +=
                    &patch_changing(path, &["export const changed = true;".to_owned()]);
            }
            Ok(())
        },
    );
    steps.step(
        "each folder sits where its first changed file is",
        |world, _, _| {
            let view = panel(world)?;
            let listed = tree_listing(world, view);
            expect!(
                listed == ["src/", " b.ts", " a.ts", "docs/", " a.md"],
                "the tree lists {}",
                listed.join(", ")
            );
            tree_node(world, "docs/a.md").map(drop)
        },
    );
    steps.step(
        &format!("{Q} was a regular file and is now a symbolic link"),
        |world, c, _| {
            let path = &c[0];
            // As git shows a type change: the file deleted, and a link of
            // its name added.
            fake(world).working_tree = format!(
                "diff --git a/{path} b/{path}\ndeleted file mode 100644\n--- a/{path}\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-const cart = [];\n-export const tax = 0;\n\
                 diff --git a/{path} b/{path}\nnew file mode 120000\n--- /dev/null\n+++ b/{path}\n@@ -0,0 +1 @@\n+lib/cart.ts\n\\ No newline at end of file\n"
            ) + &patch_changing("src/tax.ts", &lines("band", 3));
            Ok(())
        },
    );
    steps.step(&format!("{Q} is listed once as modified"), |world, c, _| {
        let view = panel(world)?;
        let nodes: Vec<Value> = view
            .diff(world, |d| d.tree())
            .unwrap_or_default()
            .into_iter()
            .filter(|node| node["path"] == c[0].as_str())
            .collect();
        expect!(
            nodes.len() == 1 && nodes[0]["change"] == "modified",
            "{} is listed {} times, {}",
            c[0],
            nodes.len(),
            show(&Value::Array(nodes.clone()))
        );
        tree_node(world, &c[0]).map(drop)
    });

    // A file's heading.
    steps.step(
        &format!("the user copies the path of {Q} from its heading in the diff"),
        |world, c, _| {
            world.set_clipboard("");
            let view = panel(world)?;
            let copy = in_heading(world, view, &c[0], "diffCopyPath")?;
            click_item(world, view, copy)
        },
    );
    steps.step("the user is told the path was copied", |world, _, _| {
        super::terminal::wait_for_toast(world, "Path copied")
    });
    steps.step(
        &format!("the environment has a file manager and the editors {Q}, {Q}"),
        |world, c, _| {
            expect!(
                c[0] == "VS Code" && c[1] == "Zed",
                "only VS Code and Zed are faked"
            );
            super::workspace::set_editors(world, json!(["file-manager", "vscode", "zed"]))
        },
    );
    steps.step("the environment has no file manager", |world, _, _| {
        super::workspace::set_editors(world, json!(["vscode", "zed"]))
    });
    steps.step(
        "the environment has nothing that can open files",
        |world, _, _| super::workspace::set_editors(world, json!([])),
    );
    steps.step(
        &format!("the user opens the menu of {Q} in the diff"),
        |world, c, _| {
            let view = panel(world)?;
            // Its heading drawn, with or without the menu's button.
            in_heading(world, view, &c[0], "diffCopyPath")?;
            world.sync()?;
            let brick = view.brick;
            let header = file_header(world, view, &c[0])?;
            if let Some(button) = brick
                .find_under(world, header, "diffFileMenu")?
                .filter(|b| brick.flag(world, *b, "visible"))
            {
                click_item(world, view, button)?;
                world.wait_for("the menu to open", |w| {
                    popup_opened(w, view, "diffFileActions")
                })?;
            }
            Ok(())
        },
    );
    fn menu_offers(world: &mut World) -> Outcome<Vec<&'static str>> {
        let view = panel(world)?;
        Ok([
            "diffFileOpen",
            "diffFileReveal",
            "diffFileEditor-vscode",
            "diffFileEditor-zed",
        ]
        .into_iter()
        .filter(|name| matches!(view.brick.find_visible(world, name), Ok(Some(_))))
        .collect())
    }
    steps.step(
        "open, reveal in the file manager and open with either editor",
        |world, _, _| {
            let offered = menu_offers(world)?;
            expect!(offered.len() == 4, "the menu offers {}", offered.join(", "));
            // Opening with Zed opens the file there.
            let view = panel(world)?;
            view.brick.click(world, "diffFileEditor-zed")?;
            world.sync()?;
            let calls = super::files_workspace::editor_calls(world)?;
            expect!(
                calls.len() == 1
                    && calls[0]["editor"] == "zed"
                    && calls[0]["cwd"] == "/work/shop/src/cart.ts",
                "the MC was asked {}",
                show(&Value::Array(calls.clone()))
            );
            Ok(())
        },
    );
    steps.step("only opening with the editors is offered", |world, _, _| {
        let offered = menu_offers(world)?;
        expect!(
            offered == ["diffFileEditor-vscode", "diffFileEditor-zed"],
            "the menu offers {}",
            offered.join(", ")
        );
        Ok(())
    });
    steps.step("no menu is shown", |world, _, _| {
        let view = panel(world)?;
        let brick = view.brick;
        let header = file_header(world, view, "src/cart.ts")?;
        let menu = brick
            .find_under(world, header, "diffFileMenu")?
            .filter(|b| brick.flag(world, *b, "visible"));
        expect!(menu.is_none(), "the file offers a menu");
        Ok(())
    });
    steps.step(
        &format!("the thread works in {Q} of the repository"),
        |world, c, _| {
            let mut project = world.mc.projects.get("shop").cloned().unwrap_or(json!({}));
            project["workspaceRoot"] = json!(format!("/work/shop/{}", c[0]));
            project["repositoryIdentity"] =
                json!({"canonicalKey": "github.com/acme/shop", "rootPath": "/work/shop"});
            world.mc.projects.insert("shop".into(), project.clone());
            world.mc.send_row_of("shop", &project, "project");
            // The repository's changes, in the thread's folder and beside it.
            fake(world).working_tree = patch_changing(
                "packages/api/server.ts",
                &["export const port = 80;".to_owned()],
            ) + &patch_changing(
                &format!("{}/src/app.ts", c[0]),
                &["export const app = true;".to_owned()],
            );
            world.sync()?;
            panel(world)?;
            let wanted = format!("/work/shop/{}", c[0]);
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeReview>()
                        .and_then(|f| f.asked.last())
                        .is_some_and(|a| a["cwd"] == wanted.as_str())
                },
                |w| {
                    format!(
                        "the review of the thread's folder; the MC was asked {}",
                        w.mc.peek::<FakeReview>()
                            .and_then(|f| f.asked.last())
                            .map(show)
                            .unwrap_or_default()
                    )
                },
            )
        },
    );
    steps.step(
        "nothing is opened because the file is not in the thread's folder",
        |world, _, _| {
            let calls = super::files_workspace::editor_calls(world)?;
            expect!(
                calls.is_empty(),
                "the MC was asked to open {}",
                show(&Value::Array(calls.clone()))
            );
            let view = panel(world)?;
            let button = in_heading(world, view, "packages/api/server.ts", "diffOpenInEditor")?;
            expect!(
                !view.brick.flag(world, button, "enabled"),
                "the file can be opened"
            );
            hover_shows(world, view, button, "Not in this thread's folder")
        },
    );
    steps.step(&format!("{Q} opens as {Q}"), |world, c, _| {
        let view = panel(world)?;
        let button = in_heading(world, view, &c[0], "diffOpenInEditor")?;
        expect!(
            view.brick.flag(world, button, "enabled"),
            "{} cannot be opened",
            c[0]
        );
        click_item(world, view, button)?;
        let calls = super::files_workspace::editor_calls(world)?;
        expect!(
            calls.len() == 1
                && calls[0]["cwd"] == format!("/work/shop/packages/web/{}", c[1]).as_str(),
            "the MC was asked {}",
            show(&Value::Array(calls.clone()))
        );
        Ok(())
    });

    // Keyboard and pasted notes.
    steps.step(
        &format!("the user comments with a code block fenced by three backticks on lines (\\d+) to (\\d+) of {Q}"),
        |world, c, _| {
            let (first, last) = (c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0));
            let view = open_comment(world, first, last, &c[2])?;
            let brick = view.brick;
            // Pasted, newlines and all.
            let note = brick.item(world, "diffCommentNote")?;
            brick.write(world, note, "text", Js::from(FENCED_NOTE))?;
            brick.click(world, "diffCommentAdd")?;
            world.sync()
        },
    );
    steps.step("the message with that comment is sent", |world, _, _| {
        world.wait_for_with(
            |w| comments(w).len() == 1,
            |w| {
                format!(
                    "the comment; the composer is {}",
                    show(&w.state("composer"))
                )
            },
        )?;
        let message = sent(world)?;
        world.mc.part::<SentReview>().0 = message;
        Ok(())
    });
    steps.step(
        "the provider receives the comment and the quoted lines with the code kept in one piece",
        |world, _, _| {
            let record = first_record(&world.mc.part::<SentReview>().0);
            expect!(
                record["text"] == FENCED_NOTE
                    && record["diff"]
                        == "+export const rate9 = 9;\n+export const rate10 = 10;\n+export const rate11 = 11;",
                "the message carries {}",
                show(&record)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the quoted lines carry the language of {Q}"),
        |world, c, _| {
            let record = first_record(&world.mc.part::<SentReview>().0);
            expect!(
                record["filePath"] == c[0].as_str() && record["fenceLanguage"] == "ts",
                "the quoted lines carry {}",
                show(&record["fenceLanguage"])
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is writing the comment {Q} on {Q} lines (\\d+) to (\\d+)"),
        |world, c, _| {
            let (first, last) = (c[2].parse().unwrap_or(0), c[3].parse().unwrap_or(0));
            let view = open_comment(world, first, last, &c[1])?;
            view.brick.click(world, "diffCommentNote")?;
            world.type_text(&c[0])?;
            keys_to_brick(world);
            Ok(())
        },
    );
    steps.step(
        &format!("the user is writing an empty comment on {Q} lines (\\d+) to (\\d+)"),
        |world, c, _| {
            let (first, last) = (c[1].parse().unwrap_or(0), c[2].parse().unwrap_or(0));
            let view = open_comment(world, first, last, &c[0])?;
            view.brick.click(world, "diffCommentNote")?;
            keys_to_brick(world);
            Ok(())
        },
    );
    steps.step("the comment is added to the composer", |world, _, _| {
        world.wait_for_with(
            |w| comments(w).len() == 1,
            |w| {
                format!(
                    "the comment; the composer is {}",
                    show(&w.state("composer"))
                )
            },
        )?;
        let chip = comments(world).remove(0);
        expect!(
            chip["label"] == "src/cart.ts L10-12" && chip["text"] == "Use the tax table",
            "the composer carries {}",
            show(&chip)
        );
        let view = panel(world)?;
        expect!(
            !popup_opened(world, view, "diffCommentPopup"),
            "the comment box stayed open"
        );
        Ok(())
    });
    steps.step("nothing is added to the composer", |world, _, _| {
        expect!(
            comments(world).is_empty(),
            "the composer carries {}",
            show(&Value::Array(comments(world)))
        );
        let view = panel(world)?;
        expect!(
            popup_opened(world, view, "diffCommentPopup"),
            "the comment box closed"
        );
        Ok(())
    });
}
