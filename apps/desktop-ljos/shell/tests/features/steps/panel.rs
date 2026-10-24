//! The right panel beside a thread (desktop-qt's PanelSteps.cpp,
//! RightPanelController): its tabs, the Diff tab over the MC's checkpoint
//! diffs, and the Files tab over the MC's workspace
//! (features/source-control/checkpoint-diffs.feature,
//! timeline/checkpoints.feature, files/file-explorer.feature,
//! files/file-viewer-and-editing.feature, navigation/layout.feature's right
//! panel). The MC's side is faked here: one patch per finished turn, and a
//! project's files as a map of paths.

use std::rc::Rc;

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::threads;
use hal_c2_shell::thread_view::diff::DiffModel;
use hal_c2_shell::thread_view::file_tree::FileTreeModel;
use hal_c2_shell::thread_view::thread_diff::{DiffTab, ThreadDiff};
use hal_c2_shell::thread_view::workspace_files::WorkspaceFiles;
use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::{Value as Json, json};

use super::fake_files::{fake_files, with_folders};
use super::files_workspace::{
    describe_tree, ensure_viewer_file, files, flag_prop, int_prop, text_prop, tree, visible_paths,
    wait_for_tree,
};
use super::stream::{
    THREAD, add_item, describe, look_at_thread, role, row_count, set, settle_run, start_run,
};
use crate::brick::{self, Brick, Shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const PROJECT: &str = "shop";

/// The MC's checkpoints: each finished turn's patch.
#[derive(Default)]
struct FakeDiffs {
    patches: std::collections::BTreeMap<i32, String>,
    failing: bool,
    /// `{method, payload}` of each diff asked for.
    asked: Vec<Json>,
    /// The run each turn was.
    runs: std::collections::BTreeMap<i32, String>,
    /// The checkpoints `checkpoint.rollback` commands named, whose rollback
    /// the MC's events have yet to follow (`flush_rollbacks`).
    rollbacks: Vec<i32>,
}

fn patch_adding(path: &str, lines: &[String]) -> String {
    let mut patch = format!(
        "diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n@@ -0,0 +1,{} @@\n",
        lines.len()
    );
    for line in lines {
        patch.push('+');
        patch.push_str(line);
        patch.push('\n');
    }
    patch
}

fn turn_lines(turn: i32) -> Vec<String> {
    vec![
        format!("export const turn = {turn};"),
        "export const done = true;".into(),
    ]
}

/// A turn's diff is the patches of the turns in its range (a fake's
/// stand-in for diffing two checkpoints).
fn answer_diff(mc: &mut FakeMc, rpc: &Rpc, from: i64) -> Outcome {
    let to = rpc.payload["toTurnCount"].as_i64().unwrap_or(0);
    let fake = mc.part::<FakeDiffs>();
    fake.asked
        .push(json!({"method": rpc.method, "payload": rpc.payload}));
    if fake.failing {
        mc.refuse(rpc, &format!("Checkpoint unavailable for turn {to}."));
        return Ok(());
    }
    let mut patch = String::new();
    for turn in (from + 1)..=to {
        patch.push_str(
            fake.patches
                .get(&(turn as i32))
                .map(String::as_str)
                .unwrap_or_default(),
        );
    }
    mc.reply(rpc, json!({"diff": patch}));
    Ok(())
}

fn extension(mc: &mut FakeMc) {
    mc.on_rpc("orchestration.getTurnDiff", |mc, rpc| {
        let from = rpc.payload["fromTurnCount"].as_i64().unwrap_or(0);
        answer_diff(mc, rpc, from)
    });
    mc.on_rpc("orchestration.getFullThreadDiff", |mc, rpc| {
        answer_diff(mc, rpc, 0)
    });
}

fn describe_panel(world: &World) -> String {
    format!("the panel is {}", show(&world.state("panel")))
}

// --- Turns and checkpoints ------------------------------------------------

fn checkpoint_fields(turn: i32, run: &str) -> Json {
    json!({"id": format!("cp-{turn}"), "scopeId": "scope-1", "runId": run,
           "appRunOrdinal": turn, "status": "ready"})
}

/// A turn that finished and left a checkpoint, changing files with `patch`.
fn finish_turn(world: &mut World, turn: i32, patch: String) -> Outcome {
    let run = start_run(world, 0, "running")?;
    add_item(
        world,
        "assistant_message",
        json!({"text": format!("Answer {turn}")}),
    )?;
    settle_run(world, "completed", 30)?;
    set(
        world,
        "checkpoint",
        &format!("cp-{turn}"),
        checkpoint_fields(turn, &run),
    )?;
    let fake = world.mc.part::<FakeDiffs>();
    fake.patches.insert(turn, patch);
    fake.runs.insert(turn, run);
    Ok(())
}

fn finish_turns(world: &mut World, count: i32) -> Outcome {
    for turn in 1..=count {
        let patch = patch_adding(&format!("src/turn{turn}.ts"), &turn_lines(turn));
        finish_turn(world, turn, patch)?;
    }
    Ok(())
}

/// A finished turn that changed `paths`, as its reply lists them: the files'
/// changes, the reply, and the checkpoint the turn left.
fn finish_turn_changing(world: &mut World, turn: i32, paths: &[&str]) -> Outcome {
    let run = start_run(world, 60, "running")?;
    let mut files = Vec::new();
    let mut patch = String::new();
    for path in paths {
        add_item(world, "file_change", json!({"fileName": path}))?;
        files.push(json!({"path": path, "kind": "modified", "additions": 2, "deletions": 0}));
        patch.push_str(&patch_adding(path, &turn_lines(turn)));
    }
    add_item(
        world,
        "assistant_message",
        json!({"text": format!("Answer {turn}")}),
    )?;
    add_item(
        world,
        "checkpoint",
        json!({"checkpointId": format!("cp-{turn}"), "scopeId": "scope-1", "files": files}),
    )?;
    settle_run(world, "completed", 60)?;
    set(
        world,
        "checkpoint",
        &format!("cp-{turn}"),
        checkpoint_fields(turn, &run),
    )?;
    let fake = world.mc.part::<FakeDiffs>();
    fake.patches.insert(turn, patch);
    fake.runs.insert(turn, run);
    Ok(())
}

/// An earlier turn changed another file, so "only that turn" can be told apart.
fn two_turns(world: &mut World, paths: &[&str]) -> Outcome {
    finish_turn_changing(world, 1, &["src/tax.ts"])?;
    finish_turn_changing(world, 2, paths)?;
    world.mc.part::<FakeDiffs>().asked.clear();
    Ok(())
}

/// The turn `turn` of the thread finished with `patch`; `files`, when not
/// empty, are the checkpoint's files as its reply lists them. For other
/// domains' backgrounds.
pub fn finish_turn_with_patch(
    world: &mut World,
    turn: i32,
    patch: &str,
    files: &[Json],
) -> Outcome {
    finish_turn(world, turn, patch.to_owned())?;
    if !files.is_empty() {
        set(
            world,
            "checkpoint",
            &format!("cp-{turn}"),
            json!({"files": files}),
        )?;
    }
    Ok(())
}

/// checkpoint.rollback as the MC does it (lib/hal_c2/orchestration/rollback.ex):
/// the later runs are rolled back and their checkpoints go stale. The effect
/// only notes the target (it runs inside the fake MC, without the world);
/// `flush_rollbacks` writes what the MC's events say, once its command has
/// been answered.
fn roll_back_on_command(world: &mut World) {
    world.mc.effects.push(Rc::new(|mc, command| {
        if command["type"] != "checkpoint.rollback" {
            return;
        }
        let target = text(&command["checkpointId"])
            .split('-')
            .nth(1)
            .and_then(|n| n.parse().ok())
            .unwrap_or(0);
        mc.part::<FakeDiffs>().rollbacks.push(target);
    }));
}

/// The MC's events that follow the rollback commands it answered: for the
/// steps (and other domains') that wait on a rollback's outcome.
pub fn flush_rollbacks(world: &mut World) -> Outcome {
    let targets = std::mem::take(&mut world.mc.part::<FakeDiffs>().rollbacks);
    for target in targets {
        let runs = world.mc.part::<FakeDiffs>().runs.clone();
        for (turn, run) in runs {
            if turn <= target {
                continue;
            }
            set(world, "run", &run, json!({"status": "rolled_back"}))?;
            set(
                world,
                "checkpoint",
                &format!("cp-{turn}"),
                json!({"status": "stale"}),
            )?;
        }
    }
    Ok(())
}

fn rollback_commands(world: &World) -> Vec<Json> {
    world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == "checkpoint.rollback")
        .cloned()
        .collect()
}

/// Waits for the rollback command, then lets the MC's events follow it.
fn wait_for_rollback(world: &mut World) -> Outcome {
    world.wait_for("the rollback to be sent", |w| {
        !rollback_commands(w).is_empty()
    })?;
    flush_rollbacks(world)
}

// --- The Diff tab ---------------------------------------------------------

fn diff_object(world: &World) -> Outcome<ObjectId> {
    match world.with::<RightPanel, _>(|p, _| p.diff())? {
        Some(object) => Ok(object),
        None => fail!("the right panel has no Diff tab"),
    }
}

fn read_diff<R>(world: &World, f: impl FnOnce(&DiffTab) -> R) -> Outcome<R> {
    let object = diff_object(world)?;
    match ThreadDiff::read(world.engine(), object, f) {
        Some(r) => Ok(r),
        None => fail!("the diff is busy"),
    }
}

fn update_diff<R>(world: &World, f: impl FnOnce(&mut DiffTab) -> R) -> Outcome<R> {
    let object = diff_object(world)?;
    match ThreadDiff::update(world.engine(), object, f) {
        Some(r) => Ok(r),
        None => fail!("the diff is busy"),
    }
}

fn diff_model(world: &World) -> Outcome<ObjectId> {
    match ThreadDiff::model(world.engine(), diff_object(world)?) {
        Some(model) => Ok(model),
        None => fail!("the diff has no model"),
    }
}

fn diff_status(world: &World) -> String {
    read_diff(world, |d| d.status().to_owned()).unwrap_or_default()
}

fn diff_paths(world: &World) -> Vec<String> {
    diff_model(world)
        .ok()
        .and_then(|m| DiffModel::read(world.engine(), m, |d| d.paths()))
        .unwrap_or_default()
}

fn file_count(world: &World) -> usize {
    diff_model(world)
        .ok()
        .and_then(|m| DiffModel::read(world.engine(), m, |d| d.file_count()))
        .unwrap_or(0)
}

fn wait_for_diff(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| {
            let status = diff_status(w);
            status != "loading" && status != "idle"
        },
        |w| {
            let message = read_diff(w, |d| d.message().to_owned()).unwrap_or_default();
            format!("the diff to load; it is {} ({message})", diff_status(w))
        },
    )
}

fn open_diff(world: &mut World, turn: i32) -> Outcome {
    world.dispatch("panel.open", json!({"tab": "diff", "turn": turn}))?;
    wait_for_diff(world)
}

fn describe_diff(world: &World) -> String {
    format!(
        "the diff ({}) shows {}",
        diff_status(world),
        diff_paths(world).join(", ")
    )
}

fn expect_diff_of(world: &mut World, paths: &[&str]) -> Outcome {
    wait_for_diff(world)?;
    expect!(
        diff_status(world) == "ready" && diff_paths(world) == paths,
        "{}",
        describe_diff(world)
    );
    Ok(())
}

fn turn_files(from: i32, to: i32) -> Vec<String> {
    (from..=to)
        .map(|turn| format!("src/turn{turn}.ts"))
        .collect()
}

fn as_strs(paths: &[String]) -> Vec<&str> {
    paths.iter().map(String::as_str).collect()
}

fn number(value: &Json) -> i64 {
    value.as_i64().unwrap_or(-1)
}

/// The rows of one file in the diff: its header, then its hunks and lines
/// when expanded.
fn rows_of_file(world: &World, path: &str) -> Outcome<Vec<Json>> {
    let model = diff_model(world)?;
    let engine = world.engine();
    let Some(file) = DiffModel::read(engine, model, |d| d.file_of(path)).flatten() else {
        fail!("{}", describe_diff(world));
    };
    let start = DiffModel::read(engine, model, |d| d.row_of_file(file))
        .flatten()
        .unwrap_or(0);
    let Some(rows) = engine.object_model(model) else {
        fail!("the diff has no rows");
    };
    let mut found = Vec::new();
    for row in start..rows.row_count() {
        let data =
            |role: &str| hal_c2_shell::json::from_value(engine, &rows.data(engine, row, role));
        if number(&data("file")) != file as i64 {
            break;
        }
        found.push(json!({"kind": data("kind"), "expanded": data("expanded"),
                          "sign": data("sign"), "rightSign": data("rightSign")}));
    }
    Ok(found)
}

fn asked_diffs(world: &mut World) -> Vec<Json> {
    world.mc.part::<FakeDiffs>().asked.clone()
}

// --- The thread as the ThreadView brick draws it --------------------------

fn thread_brick(world: &mut World) -> Outcome<Brick> {
    if world.part::<Shown>().0.is_none() {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n",
            820.0,
            1200.0,
        )?;
    }
    brick::shown(world)
}

fn name_of(engine: &Engine, item: ObjectId) -> String {
    match engine.read_by_name(item, "objectName") {
        Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn collect_named(engine: &Engine, item: ObjectId, name: &str, out: &mut Vec<ObjectId>) {
    if name_of(engine, item) == name && engine.read_by_name(item, "visible") == Value::Bool(true) {
        out.push(item);
    }
    for child in engine.children(item) {
        collect_named(engine, child, name, out);
    }
}

fn visible_named(world: &World, brick: &Brick, name: &str) -> Vec<ObjectId> {
    let mut items = Vec::new();
    if let Some(root) = brick.root(world) {
        collect_named(world.engine(), root, name, &mut items);
    }
    items
}

fn model_data(world: &World, item: ObjectId) -> Json {
    let engine = world.engine();
    hal_c2_shell::json::from_value(engine, &engine.read_by_name(item, "modelData"))
}

fn real(world: &World, item: ObjectId, name: &str) -> f64 {
    match world.engine().read_by_name(item, name) {
        Value::Real(d) => d,
        Value::Int(i) => f64::from(i),
        _ => 0.0,
    }
}

/// Clicks the newest item named `name` that `matches` in the open thread.
fn click_in_thread(
    world: &mut World,
    name: &str,
    matches: impl Fn(&World, ObjectId) -> bool,
) -> Outcome {
    let brick = thread_brick(world)?;
    let mut found = None;
    world.wait_for_with(
        |w| {
            // The newest: the one drawn lowest.
            let mut lowest: Option<(ObjectId, f64)> = None;
            for item in visible_named(w, &brick, name) {
                if !matches(w, item) {
                    continue;
                }
                let Ok((_, y)) = brick.at(w, item, 0.0, 0.0) else {
                    continue;
                };
                if lowest.is_none_or(|(_, seen)| y > seen) {
                    lowest = Some((item, y));
                }
            }
            found = lowest.map(|(item, _)| item);
            found.is_some()
        },
        |_| format!("the thread to draw {name}"),
    )?;
    let Some(item) = found else {
        fail!("the thread did not draw {name}");
    };
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)
}

/// The changed-files rows the open thread draws: its "changedFolder" or
/// "changedFile" names, sorted, once each (every turn of the thread has a
/// card of its own).
fn changed_rows(world: &mut World, name: &str) -> Vec<String> {
    let Ok(brick) = thread_brick(world) else {
        return Vec::new();
    };
    let mut names: Vec<String> = visible_named(world, &brick, name)
        .into_iter()
        .map(|item| text(&model_data(world, item)["name"]))
        .collect();
    names.sort();
    names.dedup();
    names
}

// --- Files ----------------------------------------------------------------

fn open_files(world: &mut World) -> Outcome {
    world.dispatch("rightPanel.add", json!({"kind": "files"}))?;
    wait_for_tree(world)
}

fn open_file(world: &mut World, path: &str, line: i64) -> Outcome {
    let mut payload = json!({"tab": "files", "path": path});
    if line > 0 {
        payload["line"] = json!(line);
    }
    world.dispatch("panel.open", payload)?;
    world.wait_for("the file to load", |w| {
        text_prop(w, "fileStatus") != "loading"
    })?;
    wait_for_tree(world)
}

fn children_of(world: &World, folder: &str) -> Vec<String> {
    visible_paths(world)
        .into_iter()
        .filter_map(|path| {
            let (parent, name) = path.rsplit_once('/')?;
            (parent == folder).then(|| name.to_owned())
        })
        .collect()
}

fn expect_shown_under(world: &mut World, names: &[&str], folder: &str) -> Outcome {
    wait_for_tree(world)?;
    let shown = children_of(world, folder);
    for name in names {
        expect!(shown.iter().any(|s| s == name), "{}", describe_tree(world));
    }
    Ok(())
}

/// A text file of `count` numbered lines.
fn lines_of(count: i64) -> String {
    (1..=count)
        .map(|line| format!("const line{line} = {line};\n"))
        .collect()
}

fn update_files<R>(
    world: &World,
    f: impl FnOnce(&mut hal_c2_shell::thread_view::workspace_files::Files) -> R,
) -> Outcome<R> {
    match WorkspaceFiles::update(world.engine(), files(world)?, f) {
        Some(r) => Ok(r),
        None => fail!("the Files tab is busy"),
    }
}

fn update_tree<R>(
    world: &World,
    f: impl FnOnce(&mut hal_c2_shell::thread_view::file_tree::FileTree) -> R,
) -> Outcome<R> {
    match FileTreeModel::update(world.engine(), tree(world)?, f) {
        Some(r) => Ok(r),
        None => fail!("the tree is busy"),
    }
}

fn read_tree<R>(
    world: &World,
    f: impl FnOnce(&hal_c2_shell::thread_view::file_tree::FileTree) -> R,
) -> Outcome<R> {
    match FileTreeModel::read(world.engine(), tree(world)?, f) {
        Some(r) => Ok(r),
        None => fail!("the tree is busy"),
    }
}

/// The tree's rows with their `kind`, `problem` and `path`.
fn tree_rows(world: &World) -> Outcome<Vec<(String, String, String)>> {
    let engine = world.engine();
    let tree = tree(world)?;
    let Some(rows) = engine.object_model(tree) else {
        return Ok(Vec::new());
    };
    let data = |row, role: &str| {
        text(&hal_c2_shell::json::from_value(
            engine,
            &rows.data(engine, row, role),
        ))
    };
    Ok((0..rows.row_count())
        .map(|row| (data(row, "kind"), data(row, "problem"), data(row, "path")))
        .collect())
}

// --- Tabs -----------------------------------------------------------------

fn tab_titles(world: &World) -> Vec<String> {
    let state = world.state("panel");
    at(&state, "tabs")
        .as_array()
        .map(|tabs| tabs.iter().map(|t| text(&t["title"])).collect())
        .unwrap_or_default()
}

fn tab_id_titled(world: &World, title: &str) -> Outcome<String> {
    let state = world.state("panel");
    if let Some(tabs) = at(&state, "tabs").as_array() {
        for tab in tabs {
            if text(&tab["title"]) == title {
                return Ok(text(&tab["id"]));
            }
        }
    }
    fail!("{}", describe_panel(world))
}

/// Where the edge is dragged to.
const DRAGGED_WIDTH: i64 = 720;

fn kind_of(name: &str) -> &'static str {
    match name {
        "diff" => "diff",
        "files" => "files",
        "agents" => "agents",
        "terminal" => "terminal",
        "pull request" => "pull-requests",
        _ => "previews",
    }
}

fn active_id(world: &World) -> String {
    text(at(&world.state("panel"), "activeId"))
}

/// The thread's row with `links` linked pull requests, as the MC sends it.
fn link_pull_requests(world: &mut World, links: i64) -> Outcome {
    let pull_requests: Vec<Json> = (1..=links)
        .map(|number| {
            json!({"host": "github.com", "repository": "acme/shop", "number": number,
                   "url": format!("https://github.com/acme/shop/pull/{number}"),
                   "source": "agent", "snapshot": null})
        })
        .collect();
    let mut row = world
        .mc
        .threads
        .get(THREAD)
        .cloned()
        .unwrap_or_else(|| json!({}));
    row["pullRequests"] = json!(pull_requests);
    world.mc.threads.insert(THREAD.into(), row.clone());
    world.mc.send_row(THREAD, &row);
    world.sync()
}

fn add_project_row(world: &mut World, name: &str) {
    world.mc.projects.insert(
        name.to_owned(),
        json!({"id": name, "title": name, "workspaceRoot": format!("/work/{name}"), "scripts": []}),
    );
}

/// A visit to settings: the panel as it was, and the diffs asked then.
#[derive(Default)]
struct Visit {
    panel: Json,
    asked: usize,
}

fn timeline_texts(world: &World) -> Outcome<Vec<String>> {
    let rows = row_count(world)?;
    Ok((0..rows)
        .map(|row| text(&role(world, row, "text")))
        .collect())
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Backgrounds.
    steps.step(
        &format!("a connected environment with the thread {Q} in the git project {Q}"),
        |world, c, _| {
            add_project_row(world, &c[1]);
            world.connect()?;
            world.sync()?;
            look_at_thread(world, &c[1])
        },
    );
    steps.step(
        &format!("the agent finished (\\d+) turns in {Q} that each edited files"),
        |world, c, _| finish_turns(world, c[0].parse().unwrap_or(0)),
    );
    steps.step(
        &format!("a thread in {Q} with three finished turns"),
        |world, c, _| {
            look_at_thread(world, &c[0])?;
            finish_turns(world, 3)?;
            roll_back_on_command(world);
            Ok(())
        },
    );
    steps.step("the user is looking at a thread", |world, _, _| {
        add_project_row(world, PROJECT);
        world.connect()?;
        world.sync()?;
        look_at_thread(world, PROJECT)
    });

    // The Diff tab.
    steps.step(
        "the user opens the diff of the latest turn",
        |world, _, _| open_diff(world, -1),
    );
    steps.step("the changes of turn (\\d+) are shown", |world, c, _| {
        let turn: i32 = c[0].parse().unwrap_or(0);
        let wanted = turn_files(turn, turn);
        expect_diff_of(world, &as_strs(&wanted))?;
        let asked = asked_diffs(world);
        let last = asked.last().cloned().unwrap_or(Json::Null);
        expect!(
            last["method"] == "orchestration.getTurnDiff"
                && last["payload"]["fromTurnCount"].as_i64() == Some(i64::from(turn) - 1),
            "the diff asked {}",
            show(&last)
        );
        Ok(())
    });
    steps.step(
        "the user can switch to any earlier turn or to all changes",
        |world, _, _| {
            let labels: Vec<String> = read_diff(world, |d| d.choices())?
                .into_iter()
                .map(|(_, label)| label)
                .collect();
            let wanted = [
                "Latest turn",
                "All changes",
                "Turn 3",
                "Turn 2",
                "Turn 1",
                // The checkout itself, beside its turns.
                "Working tree",
                "Branch changes",
            ];
            expect!(labels == wanted, "the picker offers {}", labels.join(", "));
            for turn in 1..=2 {
                update_diff(world, |d| d.select(turn))?;
                let wanted = turn_files(turn, turn);
                expect_diff_of(world, &as_strs(&wanted))?;
            }
            update_diff(world, |d| d.select(0))?;
            let wanted = turn_files(1, 3);
            expect_diff_of(world, &as_strs(&wanted))?;
            let asked = asked_diffs(world);
            expect!(
                asked.last().map(|a| &a["method"])
                    == Some(&json!("orchestration.getFullThreadDiff")),
                "all changes were not asked of the whole thread"
            );
            Ok(())
        },
    );
    // A turn's diff from its reply (timeline/tool-calls.feature).
    steps.step("a turn changed two files", |world, _, _| {
        two_turns(world, &["src/cart.ts", "src/checkout.ts"])
    });
    steps.step(&format!("a turn changed {Q} and {Q}"), |world, c, _| {
        two_turns(world, &[&c[0], &c[1]])
    });
    steps.step("the user opens that turn's changes", |world, _, _| {
        click_in_thread(world, "openTurnDiff", |_, _| true)?;
        world.sync()?;
        wait_for_diff(world)
    });
    steps.step(
        "the diff shows only what that turn changed, split per file",
        |world, _, _| {
            expect_diff_of(world, &["src/cart.ts", "src/checkout.ts"])?;
            let asked = asked_diffs(world);
            expect!(
                asked.len() == 1
                    && asked[0]["method"] == "orchestration.getTurnDiff"
                    && asked[0]["payload"]["fromTurnCount"].as_i64() == Some(1)
                    && asked[0]["payload"]["toTurnCount"].as_i64() == Some(2),
                "the diff asked {} times",
                asked.len()
            );
            let (shown, focus) = read_diff(world, |d| (d.shown_turn(), d.focus_path().to_owned()))?;
            expect!(
                shown == 2 && focus.is_empty(),
                "the diff is of turn {shown}"
            );
            // Each file has its own header and lines.
            for path in diff_paths(world) {
                let rows = rows_of_file(world, &path)?;
                expect!(
                    rows.len() == 4 && rows[0]["kind"] == "file",
                    "{path} has {} rows",
                    rows.len()
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens {Q} from the list of changed files"),
        |world, c, _| {
            // Its folder is closed until opened; the file is there once placed under it.
            click_in_thread(world, "changedFoldersToggle", |_, _| true)?;
            let path = c[0].clone();
            click_in_thread(world, "changedFile", move |w, item| {
                real(w, item, "y") > 0.0 && model_data(w, item)["path"] == path.as_str()
            })?;
            world.sync()?;
            wait_for_diff(world)
        },
    );
    steps.step(
        &format!("the reply lists the folder {Q} with its files hidden"),
        |world, c, _| {
            let wanted = vec![c[0].clone()];
            // The conditions below only read the thread the window draws.
            thread_brick(world)?;
            world.wait_for_with(
                |w| changed_rows_in(w, "changedFolder") == wanted,
                |w| {
                    format!(
                        "the folder {}; the reply lists {}",
                        c[0],
                        changed_rows_in(w, "changedFolder").join(", ")
                    )
                },
            )?;
            let files = changed_rows(world, "changedFile");
            expect!(files.is_empty(), "the reply lists {}", files.join(", "));
            Ok(())
        },
    );
    steps.step(
        "the user (expands|collapses) all folders of the changed files",
        |world, _, _| click_in_thread(world, "changedFoldersToggle", |_, _| true),
    );
    steps.step(
        &format!("{Q} and {Q} are listed under their folder"),
        |world, c, _| {
            let wanted = vec![c[0].clone(), c[1].clone()];
            thread_brick(world)?;
            world.wait_for_with(
                |w| changed_rows_in(w, "changedFile") == wanted,
                |w| {
                    format!(
                        "both files; the reply lists {}",
                        changed_rows_in(w, "changedFile").join(", ")
                    )
                },
            )
        },
    );
    steps.step(&format!("the diff shows only {Q}"), |world, c, _| {
        expect_diff_of(world, &[&c[0]])?;
        let (shown, focus, total) = read_diff(world, |d| {
            (d.shown_turn(), d.focus_path().to_owned(), d.file_total())
        })?;
        expect!(
            shown == 2 && focus == c[0] && total == 2,
            "the diff is of turn {shown}, on {focus} of {total} files"
        );
        expect!(
            rows_of_file(world, &c[0])?.len() == 4,
            "the file's lines are not shown"
        );
        // The way back: every file the turn changed.
        update_diff(world, |d| d.show_all_files())?;
        let focus = read_diff(world, |d| d.focus_path().to_owned())?;
        expect!(
            file_count(world) == 2 && focus.is_empty(),
            "{}",
            describe_diff(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the MC cannot read the checkpoints of {Q}"),
        |world, _, _| {
            world.mc.part::<FakeDiffs>().failing = true;
            Ok(())
        },
    );
    steps.step("the MC can read the checkpoints again", |world, _, _| {
        world.mc.part::<FakeDiffs>().failing = false;
        Ok(())
    });
    steps.step(
        "the user is told the diff could not be loaded",
        |world, _, _| {
            wait_for_diff(world)?;
            let (status, message) = (
                diff_status(world),
                read_diff(world, |d| d.message().to_owned())?,
            );
            expect!(
                status == "error" && message.contains("Checkpoint unavailable"),
                "the diff is {status}: {message}"
            );
            Ok(())
        },
    );
    steps.step("the user asks for the diff again", |world, _, _| {
        update_diff(world, |d| d.reload())?;
        wait_for_diff(world)
    });
    steps.step(
        &format!("turn (\\d+) changed (\\d+) lines of {Q}"),
        |world, c, _| {
            let lines: Vec<String> = (1..=c[1].parse::<i32>().unwrap_or(0))
                .map(|line| format!("export const rate{line} = {line};"))
                .collect();
            let patch = patch_adding(&c[2], &lines);
            world
                .mc
                .part::<FakeDiffs>()
                .patches
                .insert(c[0].parse().unwrap_or(0), patch);
            Ok(())
        },
    );
    steps.step(&format!("{Q} is listed collapsed"), |world, c, _| {
        wait_for_diff(world)?;
        let rows = rows_of_file(world, &c[0])?;
        expect!(
            rows.len() == 1 && rows[0]["expanded"] != true,
            "the file has {} rows",
            rows.len()
        );
        Ok(())
    });
    steps.step(
        &format!("the user expands {Q} in the diff"),
        |world, c, _| set_file_expanded(world, &c[0], true),
    );
    steps.step(
        &format!("the user collapses {Q} in the diff"),
        |world, c, _| set_file_expanded(world, &c[0], false),
    );
    steps.step(
        &format!("the (\\d+) lines of {Q} are shown"),
        |world, c, _| {
            let rows = rows_of_file(world, &c[1])?;
            let added = rows.iter().filter(|row| row["sign"] == "+").count();
            expect!(
                added == c[0].parse::<usize>().unwrap_or(0),
                "{added} added lines are shown"
            );
            Ok(())
        },
    );
    steps.step(
        "the user collapses every file in the diff",
        |world, _, _| update_model(world, |d| d.collapse_all()),
    );
    steps.step("the user expands every file in the diff", |world, _, _| {
        update_model(world, |d| d.expand_all())
    });
    steps.step("only the files' headers are shown", |world, _, _| {
        let model = diff_model(world)?;
        let rows = world
            .engine()
            .object_model(model)
            .map(|m| m.row_count())
            .unwrap_or(0);
        let files = file_count(world);
        expect!(rows == files, "{rows} rows for {files} files");
        Ok(())
    });
    steps.step("every file's lines are shown", |world, _, _| {
        for path in diff_paths(world) {
            expect!(
                rows_of_file(world, &path)?.len() > 1,
                "{path} shows no lines"
            );
        }
        Ok(())
    });
    steps.step(
        &format!("turn (\\d+) rewrote a line of {Q}"),
        |world, c, _| {
            let path = &c[1];
            let patch = format!(
                "diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1,2 +1,2 @@\n const cart = [];\n-export const tax = 0;\n+export const tax = 0.2;\n"
            );
            world
                .mc
                .part::<FakeDiffs>()
                .patches
                .insert(c[0].parse().unwrap_or(0), patch);
            Ok(())
        },
    );
    steps.step("the user shows the diff side by side", |world, _, _| {
        update_model(world, |d| d.set_split(true))
    });
    steps.step("the user shows the diff as one column", |world, _, _| {
        update_model(world, |d| d.set_split(false))
    });
    steps.step(
        &format!("the removed and added line of {Q} are shown side by side"),
        |world, c, _| {
            let rows = rows_of_file(world, &c[0])?;
            let paired = rows
                .iter()
                .any(|row| row["sign"] == "-" && row["rightSign"] == "+");
            expect!(paired, "the rows are {}", show(&Json::Array(rows.clone())));
            Ok(())
        },
    );
    steps.step(
        &format!("the removed and added line of {Q} are shown one above the other"),
        |world, c, _| {
            let rows = rows_of_file(world, &c[0])?;
            let signs: Vec<String> = rows.iter().map(|row| text(&row["sign"])).collect();
            let minus = signs.iter().position(|s| s == "-");
            let plus = signs.iter().position(|s| s == "+");
            expect!(
                matches!((minus, plus), (Some(m), Some(p)) if m < p),
                "the signs are {}",
                signs.join(" ")
            );
            Ok(())
        },
    );

    // Reverting.
    steps.step(
        "the user reverts the thread to the checkpoint after turn (\\d+)",
        |world, c, _| {
            let turn: i32 = c[0].parse().unwrap_or(0);
            open_diff(world, turn)?;
            update_diff(world, |d| d.request_revert(turn))?;
            let asked = read_diff(world, |d| d.revert_turn())?;
            expect!(asked == turn, "the revert was not asked about");
            update_diff(world, |d| d.confirm_revert(true))?;
            world.wait_for("the revert to finish", |w| {
                !read_diff(w, |d| d.reverting()).unwrap_or(false)
            })?;
            world.sync()
        },
    );
    steps.step(
        "the user starts reverting to the checkpoint after turn (\\d+)",
        |world, c, _| {
            let turn: i32 = c[0].parse().unwrap_or(0);
            open_diff(world, turn)?;
            update_diff(world, |d| d.request_revert(turn))
        },
    );
    steps.step("the user rolls back to a checkpoint", |world, _, _| {
        open_diff(world, -1)?;
        update_diff(world, |d| d.request_revert(0))
    });
    steps.step(
        "the user is asked to confirm that the rollback cannot be undone",
        |world, _, _| {
            let asked = read_diff(world, |d| d.revert_turn())?;
            expect!(asked == 3, "the user is asked about turn {asked}");
            expect!(
                rollback_commands(world).is_empty(),
                "a rollback was sent before the user confirmed"
            );
            Ok(())
        },
    );
    steps.step("the user cancels the revert", |world, _, _| {
        update_diff(world, |d| d.cancel_revert())?;
        world.sync()
    });
    steps.step("no rollback is sent", |world, _, _| {
        expect!(rollback_commands(world).is_empty(), "a rollback was sent");
        let asked = read_diff(world, |d| d.revert_turn())?;
        expect!(asked == 0, "the user is still asked to revert");
        Ok(())
    });
    steps.step(
        &format!("the MC refuses rollbacks with {Q}"),
        |world, c, _| {
            world
                .mc
                .refusals
                .insert("checkpoint.rollback".into(), c[0].clone());
            Ok(())
        },
    );
    steps.step(
        "turns 2 and 3 are removed from the conversation",
        |world, _, _| {
            wait_for_rollback(world)?;
            world.wait_for_with(
                |w| {
                    timeline_texts(w).is_ok_and(|texts| {
                        !texts.iter().any(|t| t == "Answer 2" || t == "Answer 3")
                    })
                },
                describe,
            )
        },
    );
    steps.step("turns 1 to 3 are still shown", |world, _, _| {
        world.sync()?;
        let texts = timeline_texts(world)?;
        for turn in 1..=3 {
            expect!(
                texts.contains(&format!("Answer {turn}")),
                "{}",
                describe(world)
            );
        }
        Ok(())
    });
    steps.step(
        "the workspace files match the end of turn (\\d+)",
        |world, c, _| {
            world.wait_for("the rollback to be sent", |w| {
                !rollback_commands(w).is_empty()
            })?;
            let rollback = rollback_commands(world).remove(0);
            expect!(
                rollback["checkpointId"] == format!("cp-{}", c[0])
                    && rollback["scopeId"] == "scope-1"
                    && rollback["restoreFiles"] == true,
                "the rollback was {}",
                show(&rollback)
            );
            flush_rollbacks(world)?;
            // The later turns' checkpoints are gone from the picker.
            let turn: i32 = c[0].parse().unwrap_or(0);
            world.wait_for_with(
                |w| read_diff(w, |d| d.latest_turn()).is_ok_and(|latest| latest == turn),
                |w| {
                    format!(
                        "the latest turn to be {turn}; it is {}",
                        read_diff(w, |d| d.latest_turn()).unwrap_or(-1)
                    )
                },
            )
        },
    );

    // The Files tab.
    steps.step(
        &format!("{Q} holds {Q}, {Q}, {Q} and an ignored {Q} folder"),
        |world, c, _| {
            let fake = fake_files(&mut world.mc);
            for path in [&c[1], &c[2], &c[3]] {
                fake.files.insert(path.clone(), format!("// {path}\n"));
            }
            fake.files.insert(
                format!("{}/left-pad/index.js", c[4]),
                "module.exports = {};\n".into(),
            );
            fake.ignored.insert(c[4].clone());
            look_at_thread(world, &c[0])
        },
    );
    steps.step(&format!("{Q} holds the text file {Q}"), |world, c, _| {
        fake_files(&mut world.mc)
            .files
            .insert(c[1].clone(), lines_of(12));
        look_at_thread(world, &c[0])
    });
    steps.step(&format!("the user expands {Q}"), |world, c, _| {
        let shown = world.with::<RightPanel, _>(|p, _| p.is_open() && p.active_tab() == "files")?;
        if !shown {
            open_files(world)?;
        }
        update_tree(world, |t| t.expand(&c[0]))?;
        wait_for_tree(world)
    });
    steps.step(
        &format!("{Q} and {Q} are shown under {Q}"),
        |world, c, _| expect_shown_under(world, &[&c[0], &c[1]], &c[2]),
    );
    steps.step(&format!("{Q} is shown under {Q}"), |world, c, _| {
        expect_shown_under(world, &[&c[0]], &c[1])
    });
    steps.step(&format!("listing {Q} fails once"), |world, c, _| {
        fake_files(&mut world.mc).fail_once.insert(c[0].clone());
        Ok(())
    });
    steps.step(
        "the user is told the folder could not be loaded",
        |world, _, _| {
            for (kind, problem, _) in tree_rows(world)? {
                if kind == "error" && problem.starts_with("Could not list") {
                    return Ok(());
                }
            }
            fail!("{}", describe_tree(world))
        },
    );
    steps.step("the user retries", |world, _, _| {
        // What failed is what is retried: the file, the project's listing or a folder's.
        if text_prop(world, "fileStatus") == "error" {
            update_files(world, |f| f.reload_file())?;
            return world.wait_for("the file to load", |w| {
                text_prop(w, "fileStatus") != "loading"
            });
        }
        if read_tree(world, |t| t.root_status().to_owned())? == "error" {
            let object = files(world)?;
            world
                .engine()
                .invoke_by_name(object, "reload", &[])
                .map_err(|e| crate::harness::Failure(format!("reload: {e:?}")))?;
        } else if let Some((_, _, path)) = tree_rows(world)?
            .into_iter()
            .find(|(kind, _, _)| kind == "error")
        {
            update_tree(world, |t| t.retry(&path))?;
        }
        wait_for_tree(world)
    });
    steps.step(
        &format!("the environment cannot list {Q}"),
        |world, _, _| {
            fake_files(&mut world.mc).cannot_list = true;
            Ok(())
        },
    );
    steps.step(
        &format!("the environment can list {Q} again"),
        |world, _, _| {
            fake_files(&mut world.mc).cannot_list = false;
            Ok(())
        },
    );
    steps.step("the user opens the Files tab", |world, _, _| {
        open_files(world)
    });
    steps.step(
        "the user is told the files could not be listed",
        |world, _, _| {
            let (status, problem) = read_tree(world, |t| {
                (t.root_status().to_owned(), t.root_problem().to_owned())
            })?;
            expect!(
                status == "error" && problem.starts_with("Could not list"),
                "{}",
                describe_tree(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("the top of {Q} is shown"), |world, _, _| {
        wait_for_tree(world)?;
        expect!(
            visible_paths(world) == ["node_modules", "src", "README.md"],
            "{}",
            describe_tree(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user filters the tree by {Q} and hides non-matches"),
        |world, c, _| {
            open_files(world)?;
            update_files(world, |f| f.set_query(&c[0]))?;
            wait_for_tree(world)
        },
    );
    steps.step(
        &format!("only {Q} and its folders are shown"),
        |world, c, _| {
            expect!(
                visible_paths(world) == with_folders(&c[0]),
                "{}",
                describe_tree(world)
            );
            Ok(())
        },
    );
    steps.step("the user stops filtering", |world, _, _| {
        update_files(world, |f| f.set_query(""))?;
        wait_for_tree(world)
    });
    steps.step("the full tree is shown again", |world, _, _| {
        let filtered = read_tree(world, |t| t.filtered())?;
        expect!(
            !filtered && visible_paths(world) == ["node_modules", "src", "README.md"],
            "{}",
            describe_tree(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user opens {Q} from a message"),
        |world, c, _| open_file(world, &c[0], 0),
    );
    steps.step(
        &format!("the tree reveals and selects {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| read_tree(w, |t| t.selected_path().to_owned()).is_ok_and(|p| p == c[0]),
                describe_tree,
            )?;
            for path in with_folders(&c[0]) {
                expect!(
                    visible_paths(world).contains(&path),
                    "{}",
                    describe_tree(world)
                );
            }
            Ok(())
        },
    );

    // The file viewer.
    steps.step(&format!("{Q} in {Q} is 3 MB"), |world, c, _| {
        let fake = fake_files(&mut world.mc);
        fake.files.insert(c[0].clone(), lines_of(200));
        fake.truncated.insert(c[0].clone(), 3 * 1024 * 1024);
        Ok(())
    });
    // A path has a dot or a slash; a bare name is a thread (ThreadListSteps).
    steps.step(r#"the user opens "([^"]*[./][^"]*)""#, |world, c, _| {
        ensure_viewer_file(world, &c[0]);
        open_file(world, &c[0], 0)
    });
    steps.step(
        &format!("the user opens {Q} at line (\\d+)"),
        |world, c, _| open_file(world, &c[0], c[1].parse().unwrap_or(0)),
    );
    steps.step(
        "the user is told the preview is limited to the first 1 MB of the file",
        |world, _, _| {
            let notice = text_prop(world, "truncatedNotice");
            expect!(
                notice == "Preview limited to the first 1 MB of a 3,145,728 byte file.",
                "the viewer says \"{notice}\""
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} has (\\d+) lines"), |world, c, _| {
        fake_files(&mut world.mc)
            .files
            .insert(c[0].clone(), lines_of(c[1].parse().unwrap_or(0)));
        Ok(())
    });
    steps.step("line (\\d+) is revealed", |world, c, _| {
        let revealed = int_prop(world, "revealLine");
        expect!(
            revealed == c[0].parse::<i64>().unwrap_or(-1),
            "line {revealed} is revealed"
        );
        Ok(())
    });
    steps.step(
        &format!("the user turns word wrap on for {Q}"),
        |world, c, _| {
            open_file(world, &c[0], 0)?;
            update_files(world, |f| f.set_wrap(true))
        },
    );
    steps.step("the user turns word wrap off", |world, _, _| {
        update_files(world, |f| f.set_wrap(false))
    });
    // FilesPanel wraps the viewer's lines to its width while `wrap` is on (tst_FilesPanel.qml).
    steps.step("long lines wrap", |world, _, _| {
        expect!(flag_prop(world, "wrap"), "the viewer does not wrap");
        Ok(())
    });
    steps.step("long lines scroll sideways", |world, _, _| {
        expect!(!flag_prop(world, "wrap"), "the viewer wraps");
        Ok(())
    });
    steps.step(&format!("reading {Q} fails once"), |world, c, _| {
        fake_files(&mut world.mc)
            .read_fails_once
            .insert(c[0].clone());
        Ok(())
    });
    steps.step(
        "the user is told the file could not be read",
        |world, _, _| {
            let (status, problem) = (
                text_prop(world, "fileStatus"),
                text_prop(world, "fileProblem"),
            );
            expect!(
                status == "error" && problem.starts_with("Could not read"),
                "the viewer is {status}: {problem}"
            );
            Ok(())
        },
    );
    steps.step(&format!("the contents of {Q} are shown"), |world, c, _| {
        let contents = fake_files(&mut world.mc)
            .files
            .get(&c[0])
            .cloned()
            .unwrap_or_default();
        let engine = world.engine();
        let rows = WorkspaceFiles::lines(engine, files(world)?)
            .and_then(|m| engine.object_model(m))
            .map(|m| m.row_count())
            .unwrap_or(0);
        let (path, status) = (text_prop(world, "openPath"), text_prop(world, "fileStatus"));
        expect!(
            path == c[0] && status == "ready" && rows == contents.matches('\n').count(),
            "the viewer shows {path} ({status}, {rows} lines)"
        );
        Ok(())
    });
    steps.step("the user closes the file", |world, _, _| {
        update_files(world, |f| f.close_file())
    });
    steps.step("no file is open and the tree is shown", |world, _, _| {
        let (path, status) = (text_prop(world, "openPath"), text_prop(world, "fileStatus"));
        let rows = tree_rows(world)?.len();
        expect!(
            path.is_empty() && status == "none" && rows > 0,
            "the viewer shows \"{path}\"; {}",
            describe_tree(world)
        );
        let shown = world.with::<RightPanel, _>(|p, _| p.is_open() && p.active_tab() == "files")?;
        expect!(shown, "{}", describe_panel(world));
        Ok(())
    });

    // The panel and its tabs (layout.feature).
    steps.step("the right panel is (open|closed)", |world, c, _| {
        let open = c[0] == "open";
        if !world.checking {
            world.with::<RightPanel, _>(|p, engine| p.set_open(engine, open))?;
        }
        world.sync()?;
        expect!(
            at(&world.state("panel"), "isOpen").as_bool() == Some(open),
            "{}",
            describe_panel(world)
        );
        Ok(())
    });
    steps.step("the user toggles the right panel", |world, _, _| {
        world.dispatch("rightPanel.toggle", json!({}))
    });
    steps.step(
        &format!("the right panel has {Q} and {Q} tabs"),
        |world, c, _| {
            for title in [&c[0], &c[1]] {
                world
                    .with::<RightPanel, _>(|p, engine| p.add_tab(engine, &title.to_lowercase()))?;
            }
            expect!(
                tab_titles(world) == [c[0].clone(), c[1].clone()],
                "{}",
                describe_panel(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("the user switches to {Q}"), |world, c, _| {
        let id = tab_id_titled(world, &c[0])?;
        world.dispatch("rightPanel.activate", json!({"id": id}))
    });
    steps.step(&format!("the {Q} tab is active"), |world, c, _| {
        let id = tab_id_titled(world, &c[0])?;
        expect!(active_id(world) == id, "{}", describe_panel(world));
        Ok(())
    });
    steps.step(&format!("the user closes the {Q} tab"), |world, c, _| {
        let id = tab_id_titled(world, &c[0])?;
        world.dispatch("rightPanel.close", json!({"id": id}))
    });
    steps.step(&format!("only the {Q} tab remains"), |world, c, _| {
        let id = tab_id_titled(world, &c[0])?;
        expect!(
            tab_titles(world) == [c[0].clone()] && active_id(world) == id,
            "{}",
            describe_panel(world)
        );
        Ok(())
    });
    // A pull request to show is one linked to the thread (its row's).
    steps.step(
        "the thread can show (diff|files|agents|terminal|pull request|previews)",
        |world, c, _| {
            if c[0] == "pull request" {
                link_pull_requests(world, 1)?;
            }
            Ok(())
        },
    );
    steps.step("the thread has no pull request", |world, _, _| {
        link_pull_requests(world, 0)
    });
    steps.step(
        "the user adds an? (diff|files|agents|terminal|pull request|previews) tab to the right panel",
        |world, c, _| {
            let kind = kind_of(&c[0]);
            let key = if kind == "pull-requests" { "pullRequests" } else { kind };
            expect!(
                at(&world.state("panel"), &format!("canAdd.{key}")).as_bool() == Some(true),
                "{}",
                describe_panel(world)
            );
            world.dispatch("rightPanel.add", json!({"kind": kind}))?;
            world.sync()
        },
    );
    steps.step(
        "an? (diff|files|agents|terminal|pull request|previews) tab opens in the right panel",
        |world, c, _| {
            let kind = kind_of(&c[0]);
            let state = world.state("panel");
            let active = text(at(&state, "activeId"));
            let shown = at(&state, "tabs").as_array().is_some_and(|tabs| {
                tabs.iter()
                    .any(|t| text(&t["id"]) == active && t["kind"] == kind)
            });
            expect!(
                at(&state, "isOpen").as_bool() == Some(true) && shown,
                "{}",
                describe_panel(world)
            );
            Ok(())
        },
    );
    // Its size (the brick's edge drags to a width and dispatches it).
    steps.step("the user drags the right panel's edge", |world, _, _| {
        world.dispatch("rightPanel.resize", json!({"width": DRAGGED_WIDTH}))
    });
    steps.step("the right panel takes the new width", |world, _, _| {
        expect!(
            at(&world.state("panel"), "width").as_i64() == Some(DRAGGED_WIDTH),
            "{}",
            describe_panel(world)
        );
        Ok(())
    });
    steps.step(
        "the user toggles the right panel to fill the window",
        |world, _, _| {
            // The keybinding's command (mod+alt+m, bound by the user).
            let ran =
                Commands::of(world.engine()).run(world.engine(), "rightPanel.toggleMaximized");
            expect!(ran, "{}", describe_panel(world));
            Ok(())
        },
    );
    steps.step("the user toggles it again", |world, _, _| {
        world.dispatch("rightPanel.toggleMaximized", json!({}))
    });
    steps.step("the right panel covers the thread", |world, _, _| {
        expect!(
            at(&world.state("panel"), "maximized").as_bool() == Some(true),
            "{}",
            describe_panel(world)
        );
        Ok(())
    });
    steps.step(
        "the thread is shown beside the right panel",
        |world, _, _| {
            let state = world.state("panel");
            expect!(
                at(&state, "isOpen").as_bool() == Some(true)
                    && at(&state, "maximized").as_bool() != Some(true),
                "{}",
                describe_panel(world)
            );
            Ok(())
        },
    );
    // The thread details column (threadPanel.toggle, the header's info button).
    steps.step(
        "the user toggles the thread details panel",
        |world, _, _| {
            // The keybinding's command, as the header's button dispatches it.
            let ran = Commands::of(world.engine()).run(world.engine(), "threadPanel.toggle");
            expect!(ran, "{}", describe_panel(world));
            world.sync()
        },
    );
    steps.step("the thread details panel is shown", |world, _, _| {
        let open = world.with::<RightPanel, _>(|p, _| p.details_open())?;
        if !world.checking && !open {
            world.dispatch("threadPanel.toggle", json!({}))?;
        }
        world.sync()?;
        let state = world.state("panel");
        let details = at(&state, "details");
        expect!(
            at(&state, "detailsOpen").as_bool() == Some(true)
                && details["project"] == PROJECT
                && details["checkout"] == "Local"
                && details["online"] == true,
            "{}",
            describe_panel(world)
        );
        Ok(())
    });
    steps.step("the thread details panel is hidden", |world, _, _| {
        let state = world.state("panel");
        expect!(
            at(&state, "detailsOpen").as_bool() != Some(true) && at(&state, "details").is_null(),
            "{}",
            describe_panel(world)
        );
        Ok(())
    });
    steps.step(&format!("the thread was forked from {Q}"), |world, c, _| {
        let parent = "thread-parent";
        let row = json!({"id": parent, "title": c[0], "projectId": PROJECT,
                         "createdAt": "2026-09-22T09:00:00Z", "updatedAt": "2026-09-22T09:00:00Z"});
        world.mc.threads.insert(parent.into(), row.clone());
        world.mc.send_row(parent, &row);
        let mut row = world
            .mc
            .threads
            .get(THREAD)
            .cloned()
            .unwrap_or_else(|| json!({}));
        row["lineage"] = json!({"parentThreadId": parent, "relationshipToParent": "fork"});
        world.mc.threads.insert(THREAD.into(), row.clone());
        world.mc.send_row(THREAD, &row);
        world.sync()
    });
    steps.step(
        &format!("the thread details panel names {Q} as the thread it was forked from"),
        |world, c, _| {
            let state = world.state("panel");
            let relations = at(at(&state, "details"), "relations")
                .as_array()
                .cloned()
                .unwrap_or_default();
            expect!(
                relations.len() == 1
                    && relations[0]["title"] == c[0].as_str()
                    && relations[0]["relation"] == "Forked from",
                "{}",
                describe_panel(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens the related thread {Q}"),
        |world, c, _| {
            let state = world.state("panel");
            let relations = at(at(&state, "details"), "relations")
                .as_array()
                .cloned()
                .unwrap_or_default();
            for relation in relations {
                if relation["title"] == c[0].as_str() {
                    world.dispatch(
                        "rightPanel.openThread",
                        json!({"threadKey": relation["threadKey"]}),
                    )?;
                }
            }
            world.sync()
        },
    );
    steps.step(&format!("the thread {Q} is open"), |world, c, _| {
        let key = format!("{}:thread-parent", world.mc.environment_id);
        world.wait_for_with(
            |w| threads::active(w.engine()) == key,
            |_| format!("{} to open", c[0]),
        )
    });
    steps.step(
        "the user looks at what can be added to the right panel",
        |world, _, _| world.sync(),
    );
    steps.step("pull request cannot be added", |world, _, _| {
        let state = world.state("panel");
        expect!(
            at(&state, "canAdd.pullRequests").as_bool() != Some(true)
                && at(&state, "canAdd.diff").as_bool() == Some(true),
            "{}",
            describe_panel(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the Add menu says {Q} for pull request"),
        |world, c, _| {
            expect!(
                text(at(&world.state("panel"), "addReasons.pullRequest")) == c[0],
                "{}",
                describe_panel(world)
            );
            Ok(())
        },
    );
    // A visit to settings: the panel steps aside and comes back as it was, its
    // diff not asked for again, so the kept body (RightPanel's native tabs,
    // tst_RightPanel) keeps its scroll.
    steps.step("the right panel shows a scrolled diff", |world, _, _| {
        finish_turns(world, 3)?;
        open_diff(world, -1)?;
        world.sync()?;
        let panel = world.state("panel");
        let asked = world.mc.part::<FakeDiffs>().asked.len();
        *world.mc.part::<Visit>() = Visit { panel, asked };
        Ok(())
    });
    steps.step("the user opens settings and comes back", |world, _, _| {
        world.dispatch("settings.open", json!({}))?;
        world.sync()?;
        let panel = world.state("panel");
        expect!(panel.is_null(), "settings show the panel {}", show(&panel));
        world.dispatch("settings.back", json!({}))?;
        world.sync()
    });
    // A closed panel's diff does not follow the thread's turns; opening it
    // catches up at once.
    steps.step("the user closes the right panel", |world, _, _| {
        finish_turns(world, 3)?;
        open_diff(world, -1)?;
        world.dispatch("rightPanel.toggle", json!({}))?;
        world.sync()?;
        let open = world.with::<RightPanel, _>(|p, _| p.is_open())?;
        expect!(!open, "{}", describe_panel(world));
        Ok(())
    });
    steps.step(
        "the right panel stops updating until it is opened again",
        |world, _, _| {
            let asked = world.mc.part::<FakeDiffs>().asked.len();
            finish_turn(
                world,
                4,
                patch_adding("src/turn4.ts", &["export const turn = 4;".to_owned()]),
            )?;
            world.sync()?;
            let now = world.mc.part::<FakeDiffs>().asked.len();
            expect!(
                now == asked,
                "the closed panel asked for a diff: {}",
                describe_diff(world)
            );
            world.dispatch("rightPanel.toggle", json!({}))?;
            expect_diff_of(world, &["src/turn4.ts"])?;
            let now = world.mc.part::<FakeDiffs>().asked.len();
            expect!(now == asked + 1, "opening asked {} times", now - asked);
            Ok(())
        },
    );
    steps.step("the diff is at the same scroll position", |world, _, _| {
        let (panel, asked) = {
            let visit = world.mc.part::<Visit>();
            (visit.panel.clone(), visit.asked)
        };
        world.wait_for_with(
            |w| w.state("panel") == panel,
            |w| {
                format!(
                    "the panel as it was, {}; it is {}",
                    show(&panel),
                    show(&w.state("panel"))
                )
            },
        )?;
        let now = world.mc.part::<FakeDiffs>().asked.len();
        expect!(
            diff_status(world) == "ready" && now == asked,
            "the diff was asked for again: {}",
            describe_diff(world)
        );
        Ok(())
    });
}

/// `changed_rows` for a wait's condition, which only has the world to read.
fn changed_rows_in(world: &World, name: &str) -> Vec<String> {
    let Some(shown) = world.peek_part::<Shown>().and_then(|s| s.0) else {
        return Vec::new();
    };
    let mut names: Vec<String> = visible_named(world, &shown, name)
        .into_iter()
        .map(|item| text(&model_data(world, item)["name"]))
        .collect();
    names.sort();
    names.dedup();
    names
}

fn update_model(
    world: &World,
    f: impl FnOnce(&mut hal_c2_shell::thread_view::diff::Diff),
) -> Outcome {
    let model = diff_model(world)?;
    match DiffModel::update(world.engine(), model, f) {
        Some(()) => Ok(()),
        None => fail!("the diff is busy"),
    }
}

fn set_file_expanded(world: &World, path: &str, expanded: bool) -> Outcome {
    let model = diff_model(world)?;
    let engine = world.engine();
    let Some(file) = DiffModel::read(engine, model, |d| d.file_of(path)).flatten() else {
        fail!("{}", describe_diff(world));
    };
    update_model(world, |d| d.set_expanded(file, expanded))
}
