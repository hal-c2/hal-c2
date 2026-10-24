//! The planner plugin's own UI (features/planning/planner.feature): its real
//! package from plugins/planner, drawn by the desktop against a fake of its
//! MC part that publishes `plan`, `runs` and `threads` as the MC part does and
//! answers the calls the UI makes: desktop-qt's PlannerSteps.cpp.
//!
//! `run_plugin_action` and `open_plannerView` are `pub`, as PlannerSteps.cpp
//! exports them: the other steps files try the planner first.

use std::collections::HashMap;
use std::rc::Rc;

use chrono::{Days, NaiveDate};
use hal_c2_shell::json;
use ljos::item::{MouseButtons, PointerEvent};
use ljos::prelude::{ObjectId, Value};
use serde_json::{Map, Value as Json, json};

use super::mc_plugin::{
    FakePluginPart, add_plugin_thread, describe, entry_of, fake_plugin_part, is_mc_plugin,
    manifest, named, open_plugin_thread, package, publish_topic, run_fake_plugin,
    run_fake_plugin_on, shown_named, switch_to_tab,
};
use super::plugin::{click_item, draws_text, shell};
use crate::brick::{Brick, key_event};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const ID: &str = "planner";
const PROJECT: &str = "p1";
/// Every field a view can show, in the order the list draws them.
const FIELDS: [&str; 8] = [
    "status", "owner", "start", "due", "progress", "labels", "project", "links",
];
const TODAY: &str = "2026-10-20";

fn package_dir() -> String {
    package("planner")
}

/// The MC part's state: its settings, the plan and the runs of its actions.
#[derive(Default)]
struct FakePlanner {
    settings: Json,
    /// The manifest's actions, which the settings reset a prompt to.
    default_actions: Json,
    /// How many `plugins.saveSettings` calls are in `settings` already.
    merged: usize,
    order: Vec<String>,
    items: HashMap<String, Json>,
    views: Vec<Json>,
    runs: Vec<Json>,
    slack: bool,
    /// The GitHub boards `boards` lists, and each one's date fields by
    /// `owner/number`.
    boards: Vec<Json>,
    date_fields: HashMap<String, Json>,
    next: u32,
}

/// What the steps remember of the window.
#[derive(Default)]
struct PlannerWorld {
    /// The group a step focused.
    group: String,
}

fn state(mc: &mut FakeMc) -> &mut FakePlanner {
    mc.part::<FakePlanner>()
}

fn next_id(mc: &mut FakeMc, prefix: &str) -> String {
    let fake = state(mc);
    fake.next += 1;
    format!("{prefix}{}", fake.next)
}

fn view(id: &str, name: &str, layout: &str, fields: Json) -> Json {
    let mut view = json!({"id": id, "name": name, "layout": layout,
        "filter": {"text": "", "statuses": [], "labels": [], "projects": [], "owners": [],
                   "hideDone": false},
        "groupBy": "none", "sortBy": "manual", "zoom": "week",
        "fields": ["status", "owner", "start", "due", "progress"],
        "showDependencies": true, "showBaseline": false});
    if let Some(fields) = fields.as_object() {
        for (key, value) in fields {
            view[key] = value.clone();
        }
    }
    view
}

/// The views a new plan has, as the MC part makes them.
fn default_views() -> Vec<Json> {
    vec![
        view("timeline", "Timeline", "gantt", json!({})),
        view("board", "Board", "board", json!({"groupBy": "status"})),
        view("list", "All tasks", "list", json!({})),
    ]
}

fn id_of(mc: &mut FakeMc, title: &str) -> String {
    let fake = state(mc);
    fake.order
        .iter()
        .find(|id| text(&fake.items[*id]["title"]) == title)
        .cloned()
        .unwrap_or_default()
}

/// The task `title`, added to the plan in "api" when it has none.
fn item<'a>(mc: &'a mut FakeMc, title: &str) -> &'a mut Json {
    let mut id = id_of(mc, title);
    if id.is_empty() {
        id = next_id(mc, "t");
        let fake = state(mc);
        fake.order.push(id.clone());
        let order = fake.order.len();
        fake.items.insert(
            id.clone(),
            json!({"id": id, "title": title, "notes": "", "kind": "task", "status": "todo",
                   "start": null, "due": null, "progress": null, "parent": null,
                   "after": [], "labels": [], "owner": null, "projectId": PROJECT,
                   "order": order, "issue": null, "pullRequests": [], "threads": [],
                   "feedback": [], "baseline": null, "syncError": null}),
        );
    }
    state(mc)
        .items
        .get_mut(&id)
        .unwrap_or_else(|| unreachable!())
}

fn dated<'a>(mc: &'a mut FakeMc, title: &str, start: &str, due: &str) -> &'a mut Json {
    let task = item(mc, title);
    task["start"] = json!(start);
    task["due"] = json!(due);
    task
}

/// A plan to look at when a scenario gives none: two tasks of "api".
fn seed_when_empty(mc: &mut FakeMc) {
    if !state(mc).order.is_empty() {
        return;
    }
    let limits = dated(mc, "Rate limits", "2026-10-19", "2026-10-30");
    limits["owner"] = json!("sam");
    limits["labels"] = json!(["backend"]);
    let docs = dated(mc, "Docs", "2026-11-02", "2026-11-06");
    docs["owner"] = json!("dana");
}

fn action_id(mc: &mut FakeMc, label: &str) -> Outcome<String> {
    let actions = state(mc).settings["actions"].clone();
    if let Some(actions) = actions.as_object() {
        for (key, action) in actions {
            if text(&action["label"]) == label {
                return Ok(key.clone());
            }
        }
    }
    fail!("planner has no action {label}")
}

fn parse(day: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(day, "%Y-%m-%d").ok()
}

fn iso(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

fn plus(day: NaiveDate, days: i64) -> NaiveDate {
    if days >= 0 {
        day + Days::new(days as u64)
    } else {
        day - Days::new(days.unsigned_abs())
    }
}

/// What the MC part derives for each item: late, early, its progress, its
/// subtasks.
fn derived(mc: &mut FakeMc) -> Vec<Json> {
    let fake = state(mc);
    let mut items = Vec::new();
    for id in &fake.order {
        let mut task = fake.items[id].clone();
        let status = text(&task["status"]);
        let start = text(&task["start"]);
        let due = text(&task["due"]);
        let mut early = Vec::new();
        for before in task["after"].as_array().into_iter().flatten() {
            let ends = text(
                &fake
                    .items
                    .get(&text(before))
                    .map_or(Json::Null, |b| b["due"].clone()),
            );
            if !start.is_empty() && !ends.is_empty() && ends >= start {
                early.push(before.clone());
            }
        }
        let children = fake
            .items
            .values()
            .filter(|other| text(&other["parent"]) == *id)
            .count();
        let progress = task["progress"].clone();
        task["late"] = json!(
            !due.is_empty() && due.as_str() < TODAY && status != "done" && status != "dropped"
        );
        task["early"] = json!(early);
        task["derivedProgress"] = if progress.is_number() {
            json!(progress.as_f64().unwrap_or(0.0) as i64)
        } else if status == "done" {
            json!(100)
        } else {
            json!(0)
        };
        let baseline = text(&task["baseline"]["due"]);
        task["slip"] = if baseline.is_empty() || due.is_empty() {
            Json::Null
        } else {
            json!(match (parse(&baseline), parse(&due)) {
                (Some(from), Some(to)) => (to - from).num_days(),
                _ => 0,
            })
        };
        task["children"] = json!(children);
        items.push(task);
    }
    items
}

/// A run's thread as `threads` has it: what its mark and header show.
fn thread_of(mc: &mut FakeMc, run: &Json) -> Json {
    let fake = state(mc);
    let item_ids = run["itemIds"].as_array().cloned().unwrap_or_default();
    let titles: Vec<Json> = item_ids
        .iter()
        .map(|id| {
            fake.items
                .get(&text(id))
                .map_or(Json::Null, |task| task["title"].clone())
        })
        .collect();
    let kept = run["changes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|each| each["dismissed"] != json!(true))
        .count();
    let work = run["kind"] == json!("work");
    json!({"runId": run["id"], "kind": run["kind"], "label": run["label"],
           "status": run["status"], "items": titles, "changes": kept,
           "health": run["health"],
           "itemId": if work && !item_ids.is_empty() { item_ids[0].clone() } else { Json::Null }})
}

/// What the MC part publishes: the plan, the runs, and each run's thread.
fn publish(mc: &mut FakeMc) -> Outcome {
    let settings = state(mc).settings.clone();
    let mut actions = Vec::new();
    for (key, action) in settings["actions"].as_object().into_iter().flatten() {
        actions.push(
            json!({"id": key, "label": action["label"], "scope": action["scope"],
                            "kind": action["kind"], "apply": action["apply"]}),
        );
    }
    let runs = state(mc).runs.clone();
    let mut threads = Map::new();
    for run in &runs {
        let thread = text(&run["threadId"]);
        if !thread.is_empty() {
            let of = thread_of(mc, run);
            threads.insert(thread, of);
        }
    }
    let items = derived(mc);
    let views = state(mc).views.clone();
    let channel = text(&settings["slackChannel"]);
    let plan = json!({
        "items": items, "views": views, "updates": [], "today": TODAY, "actions": actions,
        "projects": [{"id": PROJECT, "title": "api", "repository": "acme/api"}],
        "sync": {"repositories": settings["repositories"], "board": settings["board"],
                 "mode": settings["sync"], "problem": null, "unwatched": [], "checkedAt": null,
                 "slack": {"channel": if channel.is_empty() { Json::Null } else { json!(channel) },
                           "problem": null}},
        "planFeedback": []});
    let part = fake_plugin_part(mc, ID)?;
    part.topics.insert("plan".into(), plan);
    part.topics.insert("runs".into(), json!({"runs": runs}));
    part.topics.insert("threads".into(), Json::Object(threads));
    for topic in ["plan", "runs", "threads"] {
        publish_topic(mc, ID, topic)?;
    }
    Ok(())
}

/// A run of the action `label` on `titles` (none for the whole plan), with
/// its thread.
fn add_run<'a>(
    mc: &'a mut FakeMc,
    label: &str,
    titles: &[String],
    status: &str,
) -> Outcome<&'a mut Json> {
    let mut item_ids = Vec::new();
    for title in titles {
        item_ids.push(item(mc, title)["id"].clone());
    }
    let id = next_id(mc, "r");
    let action = action_id(mc, label)?;
    let fake = state(mc);
    fake.runs.push(
        json!({"id": id, "action": action, "label": label, "kind": "action",
                          "status": status, "itemIds": item_ids, "projectId": PROJECT,
                          "threadId": format!("t-run-{id}"),
                          "startedAt": "2026-10-20T09:00:00Z", "summary": "",
                          "feedback": [], "changes": []}),
    );
    Ok(fake.runs.last_mut().unwrap_or_else(|| unreachable!()))
}

/// The run's thread, in the thread list unless the plugin shows its runs only
/// on its page.
fn list_thread(world: &mut World, run: &Json) -> Outcome {
    let listed = state(&mut world.mc).settings["display"] != json!("page");
    add_plugin_thread(
        world,
        &text(&run["threadId"]),
        &text(&run["label"]),
        json!({"id": ID, "kind": run["kind"], "listed": listed}),
    )
}

/// The run proposing that `title` ends on `due`; its index.
fn propose(mc: &mut FakeMc, label: &str, title: &str, due: &str) -> Outcome<Json> {
    if item(mc, title)["due"].is_null() {
        dated(mc, title, "2026-10-21", "2026-10-30");
    }
    let task_id = item(mc, title)["id"].clone();
    let run = add_run(mc, label, &[], "proposed")?;
    run["summary"] = json!("Schema slipped, so API moves.");
    run["changes"] = json!([{"id": "c1", "op": "update", "itemId": task_id,
                             "fields": {"due": due}, "reason": "Schema slipped",
                             "dismissed": false}]);
    Ok(run.clone())
}

/// The MC's live subscriptions to the planner's `plan`.
fn plan_watches(mc: &FakeMc) -> usize {
    mc.subscribers("plugin")
        .into_iter()
        .filter(|id| {
            let shape = mc.shape_of(*id);
            text(&shape["id"]) == ID && text(&shape["topic"]) == "plan"
        })
        .count()
}

/// Every subscription of the planner's `plan` the client made.
fn plan_subscriptions(mc: &FakeMc) -> usize {
    mc.subscriptions
        .iter()
        .filter(|sub| text(&sub["shape"]["id"]) == ID && text(&sub["shape"]["topic"]) == "plan")
        .count()
}

/// The run of the action `label`.
fn run_of(mc: &mut FakeMc, label: &str) -> Outcome<Json> {
    match state(mc)
        .runs
        .iter()
        .find(|run| text(&run["label"]) == label)
    {
        Some(run) => Ok(run.clone()),
        None => fail!("no run of {label}"),
    }
}

fn last_run(mc: &mut FakeMc) -> Outcome<Json> {
    match state(mc).runs.last() {
        Some(run) => Ok(run.clone()),
        None => fail!("the plan has no run"),
    }
}

/// The settings each `plugins.saveSettings` since the last look sent, as the
/// MC part keeps them: a key sent as null goes back to the plugin's.
fn merge_saved(mc: &mut FakeMc) -> Outcome {
    let saves: Vec<Json> = mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "plugins.saveSettings")
        .map(|rpc| rpc.payload["settings"].clone())
        .collect();
    let read = manifest(&package_dir())?;
    let mut defaults = Map::new();
    for each in read["settings"].as_array().into_iter().flatten() {
        defaults.insert(text(&each["key"]), each["default"].clone());
    }
    let fake = state(mc);
    while fake.merged < saves.len() {
        for (key, value) in saves[fake.merged].as_object().into_iter().flatten() {
            fake.settings[key] = if value.is_null() {
                defaults.get(key).cloned().unwrap_or(Json::Null)
            } else {
                value.clone()
            };
        }
        fake.merged += 1;
    }
    Ok(())
}

/// The calls the UI makes, answered as the MC part answers them.
fn answer(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    let method = text(&rpc.payload["method"]);
    let input = rpc.payload["input"].clone();
    if method == "settings" {
        if mc.holding("planner.settings") {
            let held = rpc.clone();
            mc.defer(move |mc| {
                let _ = answer(mc, &held);
            });
            return Ok(());
        }
        // Held, a read is refused once the hold is lifted.
        if mc.holding("planner.refuseSettings") {
            let held = rpc.clone();
            mc.defer(move |mc| mc.refuse(&held, "The plugin stopped."));
            return Ok(());
        }
        merge_saved(mc)?;
        let fake = state(mc);
        let channels = if fake.slack {
            json!([{"id": "C1", "name": "planning"}, {"id": "C2", "name": "releases"}])
        } else {
            json!([])
        };
        let answer = json!({"settings": fake.settings, "defaultActions": fake.default_actions,
            "providers": [{"instanceId": "claudeAgent", "name": "Claude", "models": []}],
            "projects": [{"id": PROJECT, "title": "api"}],
            "repositories": ["acme/api"], "slackChannels": channels,
            "slackConnected": fake.slack});
        mc.reply(rpc, answer);
        return Ok(());
    }
    if method == "boards" {
        let boards = state(mc).boards.clone();
        mc.reply(rpc, json!({"boards": boards, "problems": []}));
        return Ok(());
    }
    if method == "boardFields" {
        let board = text(&input["board"]);
        match state(mc).date_fields.get(&board).cloned() {
            None => mc.refuse(rpc, &format!("{board} was not found.")),
            Some(fields) => mc.reply(rpc, json!({"dateFields": fields})),
        }
        return Ok(());
    }
    let mut result = Json::Null;
    let id = text(&input["id"]);
    if method == "updateItem" || method == "addItem" {
        if method == "updateItem" && !state(mc).items.contains_key(&id) {
            mc.refuse(rpc, &format!("No task {id}."));
            return Ok(());
        }
        let fields = input["fields"].clone();
        let task = if method == "addItem" {
            item(mc, &text(&fields["title"]))
        } else {
            state(mc)
                .items
                .get_mut(&id)
                .unwrap_or_else(|| unreachable!())
        };
        for (key, value) in fields.as_object().into_iter().flatten() {
            task[key] = value.clone();
        }
        result = json!({"item": task});
    } else if method == "moveToMilestone" {
        for (key, held) in [("from", false), ("to", true)] {
            let milestone = text(&input[key]);
            if milestone.is_empty() {
                continue;
            }
            let fake = state(mc);
            let entry = fake.items.entry(milestone).or_insert_with(|| json!({}));
            let mut after: Vec<Json> = entry["after"].as_array().cloned().unwrap_or_default();
            after.retain(|each| text(each) != id);
            if held {
                after.push(json!(id));
            }
            entry["after"] = json!(after);
        }
    } else if method == "removeItem" {
        let fake = state(mc);
        fake.items.remove(&id);
        fake.order.retain(|each| *each != id);
    } else if method == "saveView" {
        let mut saved = input["view"].clone();
        if saved.get("id").is_none() {
            saved["id"] = json!(next_id(mc, "v"));
        }
        let saved = view(
            &text(&saved["id"]),
            &text(&saved["name"]),
            &text(&saved["layout"]),
            saved.clone(),
        );
        let fake = state(mc);
        match fake.views.iter_mut().find(|each| each["id"] == saved["id"]) {
            Some(each) => *each = saved.clone(),
            None => fake.views.push(saved.clone()),
        }
        result = json!({"view": saved});
    } else if method == "run" {
        let action = text(&input["action"]);
        let configured = state(mc).settings["actions"][&action].clone();
        if configured.as_object().is_none_or(Map::is_empty) {
            mc.refuse(rpc, &format!("No action {action}."));
            return Ok(());
        }
        let titles: Vec<String> = input["itemIds"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|each| {
                state(mc)
                    .items
                    .get(&text(each))
                    .map_or(String::new(), |task| text(&task["title"]))
            })
            .collect();
        let run = add_run(mc, &text(&configured["label"]), &titles, "running")?.clone();
        result = json!({"run": run});
    } else if let Some(position) = state(mc)
        .runs
        .iter()
        .position(|run| run["id"] == input["runId"])
    {
        // Held, an apply is refused once the hold is lifted, as when the plan
        // changed under it.
        if method == "apply" && mc.holding("planner.refuseApply") {
            let held = rpc.clone();
            mc.defer(move |mc| mc.refuse(&held, "The plan changed under this run."));
            return Ok(());
        }
        let fake = state(mc);
        if method == "dismissChange" {
            let run = &mut fake.runs[position];
            let mut changes = run["changes"].as_array().cloned().unwrap_or_default();
            for change in &mut changes {
                if change["id"] == input["changeId"] {
                    change["dismissed"] = input["dismissed"].clone();
                }
            }
            run["changes"] = json!(changes);
        } else if method == "apply" {
            let changes = fake.runs[position]["changes"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            for change in changes {
                let target = text(&change["itemId"]);
                if change["dismissed"] == json!(true) || !fake.items.contains_key(&target) {
                    continue;
                }
                for (key, value) in change["fields"].as_object().into_iter().flatten() {
                    fake.items
                        .get_mut(&target)
                        .unwrap_or_else(|| unreachable!())[key] = value.clone();
                }
            }
            fake.runs[position]["status"] = json!("applied");
        } else if method == "discard" {
            fake.runs.remove(position);
        } else {
            mc.refuse(rpc, "no such call");
            return Ok(());
        }
    } else {
        mc.refuse(rpc, "no such call");
        return Ok(());
    }
    mc.reply(rpc, result);
    publish(mc)
}

/// The calls of `method` the UI made, with their input.
fn asked(mc: &FakeMc, method: &str) -> Vec<Json> {
    mc.calls
        .iter()
        .filter(|rpc| rpc.method == "plugins.call" && text(&rpc.payload["method"]) == method)
        .map(|rpc| rpc.payload["input"].clone())
        .collect()
}

fn show_asked(mc: &FakeMc, method: &str) -> String {
    show(&Json::Array(asked(mc, method)))
}

fn wait_asked(world: &mut World, method: &str, input: Json) -> Outcome {
    world.wait_for_with(
        |w| asked(&w.mc, method).contains(&input),
        |w| {
            format!(
                "{method} {} to be asked, not {}",
                show(&input),
                show_asked(&w.mc, method)
            )
        },
    )
}

fn saved_settings(mc: &FakeMc) -> Vec<Json> {
    mc.calls
        .iter()
        .filter(|rpc| rpc.method == "plugins.saveSettings")
        .map(|rpc| rpc.payload["settings"].clone())
        .collect()
}

/// Clicks `target` once it is enabled.
fn click(world: &mut World, target: ObjectId) -> Outcome {
    let brick = shell(world)?;
    let name = brick.text_of(world, target, "objectName");
    world.wait_for_with(
        |w| brick.flag(w, target, "enabled"),
        |_| format!("{name} to be enabled"),
    )?;
    click_item(world, target)
}

fn text_now(w: &World, brick: Brick, object_name: &str) -> Option<String> {
    let found = named(w, brick, object_name)?;
    brick
        .flag(w, found, "visible")
        .then(|| brick.text_of(w, found, "text"))
}

fn text_of(world: &mut World, object_name: &str) -> Outcome<String> {
    let brick = shell(world)?;
    let found = shown_named(world, object_name)?;
    Ok(brick.text_of(world, found, "text"))
}

fn wait_text(world: &mut World, object_name: &str, wanted: &str) -> Outcome {
    let brick = shell(world)?;
    shown_named(world, object_name)?;
    world.wait_for_with(
        |w| text_now(w, brick, object_name).as_deref() == Some(wanted),
        |w| {
            format!(
                "{object_name} to say {wanted}, not {}",
                text_now(w, brick, object_name).unwrap_or_default()
            )
        },
    )
}

/// Whether no item named `object_name` is shown.
fn hidden(w: &World, brick: Brick, object_name: &str) -> bool {
    match brick.find(w, object_name) {
        Ok(Some(found)) => !brick.flag(w, found, "visible"),
        _ => true,
    }
}

fn wait_hidden(world: &mut World, object_name: &str) -> Outcome {
    let brick = shell(world)?;
    world.wait_for_with(
        |w| hidden(w, brick, object_name),
        |_| format!("{object_name} to be hidden"),
    )
}

fn property_json(world: &World, brick: Brick, target: ObjectId, name: &str) -> Json {
    json::from_value(world.engine(), &brick.read(world, target, name))
}

fn real(world: &World, brick: Brick, target: ObjectId, name: &str) -> f64 {
    match brick.read(world, target, name) {
        Value::Int(n) => f64::from(n),
        Value::Real(r) => r,
        _ => 0.0,
    }
}

fn invoke(world: &World, target: ObjectId, function: &str, args: &[Value]) -> Outcome<Value> {
    world
        .engine()
        .invoke_by_name(target, function, args)
        .map_err(|e| crate::harness::Failure(format!("{function}: {e:?}")))
}

fn view_name(world: &World, brick: Brick, page: ObjectId) -> String {
    text(&property_json(world, brick, page, "working")["name"])
}

/// The Planner tab, on the view `name` when one is given.
fn show_planner(world: &mut World, name: &str) -> Outcome<ObjectId> {
    let brick = shell(world)?;
    switch_to_tab(world, "Planner")?;
    // A page that cannot load says why instead.
    world.wait_for_with(
        |w| !hidden(w, brick, "plannerPage") || !hidden(w, brick, "pluginPageProblem"),
        |w| format!("the Planner page to load; {}", describe(w)),
    )?;
    if !hidden(world, brick, "pluginPageProblem") {
        fail!("{}", text_of(world, "pluginPageProblem")?);
    }
    let page = shown_named(world, "plannerPage")?;
    if !name.is_empty() && view_name(world, brick, page) != name {
        let tab = shown_named(world, &format!("plannerView:{name}"))?;
        click(world, tab)?;
    }
    if !name.is_empty() {
        world.wait_for_with(
            |w| view_name(w, brick, page) == name,
            |w| {
                format!(
                    "the view {name} to be shown, not {}",
                    view_name(w, brick, page)
                )
            },
        )?;
    }
    Ok(page)
}

fn day_width(world: &mut World) -> Outcome<f64> {
    let brick = shell(world)?;
    let gantt = shown_named(world, "plannerGantt")?;
    Ok(real(world, brick, gantt, "dayWidth"))
}

/// The user presses `target` at its centre, moves the mouse by `by` in steps
/// and lets go.
fn drag(world: &mut World, target: ObjectId, by: (f64, f64)) -> Outcome {
    let brick = shell(world)?;
    let (x, y) = brick.at(world, target, 0.5, 0.5)?;
    let (x, y) = (x.round(), y.round());
    world.pointer(|now| PointerEvent::press(x, y, now))?;
    for i in 1..=8 {
        let (mx, my) = (
            (x + by.0 * f64::from(i) / 8.0).round(),
            (y + by.1 * f64::from(i) / 8.0).round(),
        );
        world.pointer(|now| PointerEvent::moved(mx, my, MouseButtons::LEFT, now))?;
    }
    let (rx, ry) = ((x + by.0).round(), (y + by.1).round());
    world.pointer(|now| PointerEvent::release(rx, ry, now))?;
    world.sync()
}

/// The key presses that type `typed`.
fn type_text(world: &mut World, typed: &str) -> Outcome {
    let brick = shell(world)?;
    for each in typed.chars() {
        let spelt = if each == ' ' {
            "space".to_owned()
        } else if each.is_uppercase() {
            format!("shift+{}", each.to_lowercase())
        } else if each.is_alphanumeric() {
            each.to_string()
        } else {
            format!("\"{each}\"")
        };
        brick.press(world, &spelt)?;
    }
    world.sync()
}

fn press(world: &mut World, spelt: &str) -> Outcome {
    let brick = shell(world)?;
    key_event(spelt)?;
    brick.press(world, spelt)?;
    Ok(())
}

fn under(world: &mut World, parent: &str, child: &str) -> Outcome<bool> {
    let brick = shell(world)?;
    let column = shown_named(world, parent)?;
    Ok(brick.find_under(world, column, child)?.is_some())
}

fn wait_under(world: &mut World, parent: &str, child: &str, what: String) -> Outcome {
    let brick = shell(world)?;
    let column = shown_named(world, parent)?;
    world.wait_for_with(
        |w| matches!(brick.find_under(w, column, child), Ok(Some(_))),
        |_| what.clone(),
    )
}

/// Whether the mark of the thread row at the top says `wanted`.
fn marked(world: &mut World, wanted: &str, what: String) -> Outcome {
    let brick = shell(world)?;
    world.wait_for_with(
        |w| {
            let Some(host) = named(w, brick, "pluginRowMark") else {
                return false;
            };
            let Ok(Some(mark)) = brick.find_under(w, host, "plannerRowMark") else {
                return false;
            };
            matches!(brick.shows_under(w, mark, wanted), Ok(true))
        },
        |_| what.clone(),
    )
}

fn header_text(world: &World, brick: Brick, header: ObjectId, name: &str) -> String {
    match brick.find_under(world, header, name) {
        Ok(Some(found)) => brick.text_of(world, found, "text"),
        _ => String::new(),
    }
}

fn header_part(world: &World, brick: Brick, header: ObjectId, name: &str) -> Outcome<ObjectId> {
    match brick.find_under(world, header, name)? {
        Some(found) => Ok(found),
        None => fail!("the header has no {name}"),
    }
}

fn set_text_and(world: &mut World, name: &str, typed: &str, signal: &str) -> Outcome {
    let brick = shell(world)?;
    let edit = shown_named(world, name)?;
    brick.write(world, edit, "text", Value::from(typed))?;
    expect!(
        invoke(world, edit, signal, &[]).is_ok(),
        "{name} cannot be edited"
    );
    world.sync()
}

/// Presses the button `target` as a script does.
fn press_button(world: &mut World, target: ObjectId, what: &str) -> Outcome {
    expect!(invoke(world, target, "clicked", &[]).is_ok(), "{what}");
    world.sync()
}

fn wait_enabled(world: &mut World, target: ObjectId, what: &str) -> Outcome {
    let brick = shell(world)?;
    world.wait_for_with(|w| brick.flag(w, target, "enabled"), |_| what.to_owned())
}

fn wait_loaded(world: &mut World) -> Outcome<ObjectId> {
    let brick = shell(world)?;
    let settings = shown_named(world, "plannerSettings")?;
    world.wait_for_with(
        |w| brick.flag(w, settings, "loaded"),
        |_| "the settings to be read".to_owned(),
    )?;
    Ok(settings)
}

fn save_settings(world: &mut World) -> Outcome {
    let save = shown_named(world, "plannerSave")?;
    wait_enabled(world, save, "the settings to be saveable")?;
    press_button(world, save, "the settings cannot be saved")
}

fn set_views<F: Fn(&mut Json)>(mc: &mut FakeMc, name: &str, change: F) {
    for each in &mut state(mc).views {
        if text(&each["name"]) == name {
            change(each);
        }
    }
}

/// Picks entry `wanted` of the combo named `name` once it is offered.
fn pick(world: &mut World, name: &str, wanted: &str) -> Outcome {
    let brick = shell(world)?;
    let combo = shown_named(world, name)?;
    let find = |w: &World| -> Option<i32> {
        let count = real(w, brick, combo, "count") as i32;
        (0..count).find(|i| {
            matches!(invoke(w, combo, "textAt", &[Value::Int(*i)]),
                Ok(Value::String(s)) if s.as_str().starts_with(wanted))
        })
    };
    world.wait_for_with(|w| find(w).is_some(), |_| format!("{wanted} to be offered"))?;
    let index = find(world).unwrap_or(-1);
    expect!(
        invoke(world, combo, "activated", &[Value::Int(index)]).is_ok(),
        "{wanted} cannot be picked"
    );
    world.sync()
}

fn wait_planner_view(world: &mut World, name: &str) -> Outcome {
    let brick = shell(world)?;
    let page = shown_named(world, "plannerPage")?;
    world.wait_for_with(
        |w| view_name(w, brick, page) == name,
        |w| {
            format!(
                "the view {name} to be shown, not {}",
                view_name(w, brick, page)
            )
        },
    )
}

fn open_run(world: &mut World, label: &str) -> Outcome {
    show_planner(world, "")?;
    let toggle = shown_named(world, "plannerRunsToggle")?;
    click(world, toggle)?;
    let run = shown_named(world, &format!("plannerRun:{label}"))?;
    click(world, run)?;
    shown_named(world, "plannerRunDetail")?;
    Ok(())
}

/// The user opens the run `label`'s thread and waits for its header.
fn open_header(world: &mut World, thread: &str, label: &str) -> Outcome<ObjectId> {
    open_plugin_thread(world, thread)?;
    let brick = shell(world)?;
    let header = shown_named(world, "plannerHeader")?;
    world.wait_for_with(
        |w| header_text(w, brick, header, "plannerHeaderTitle") == label,
        |w| {
            format!(
                "the header to be {label}'s, not {}'s",
                header_text(w, brick, header, "plannerHeaderTitle")
            )
        },
    )?;
    Ok(header)
}

fn register_timeline(steps: &mut Steps) {
    steps.step(&format!("an MC running the plugin {Q}"), |world, c, _| {
        expect!(c[0] == ID, "only {ID} is faked");
        let read = manifest(&package_dir())?;
        let mut settings = Map::new();
        for each in read["settings"].as_array().into_iter().flatten() {
            settings.insert(text(&each["key"]), each["default"].clone());
        }
        let default_actions = settings.get("actions").cloned().unwrap_or(json!({}));
        // One prompt the user changed, for the settings to reset to the plugin's.
        let mut actions = default_actions.clone();
        actions["feedback"]["prompt"] = json!("My own feedback prompt.");
        settings.insert("actions".into(), actions);
        let settings = Json::Object(settings);
        let fake = state(&mut world.mc);
        fake.default_actions = default_actions;
        fake.settings = settings.clone();
        fake.views = default_views();
        let part = FakePluginPart {
            package: package_dir(),
            call: Some(Rc::new(answer)),
            ..FakePluginPart::default()
        };
        run_fake_plugin(world, entry_of(ID, &read, &settings), part)?;
        publish(&mut world.mc)
    });

    steps.step(
        &format!("the plan has {Q} from {Q} to {Q}, {Q} waiting for it, and the milestone {Q}"),
        |world, c, _| {
            let first = text(&dated(&mut world.mc, &c[0], &c[1], &c[2])["id"]);
            let after = parse(&c[2]).unwrap_or_default();
            let later = plus(after, 3);
            let waiting = dated(&mut world.mc, &c[3], &iso(later), &iso(plus(later, 4)));
            waiting["after"] = json!([first]);
            let milestone = item(&mut world.mc, &c[4]);
            milestone["kind"] = json!("milestone");
            milestone["due"] = json!(iso(plus(later, 14)));
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("the user switches to the {Q} tab with the view {Q}"),
        |world, c, _| {
            expect!(c[0] == "Planner", "planner has no tab {}", c[0]);
            show_planner(world, &c[1])?;
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} and {Q} are bars on the timeline with an arrow from {Q} to {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            let first = shown_named(world, &format!("plannerBar:{}", c[0]))?;
            let second = shown_named(world, &format!("plannerBar:{}", c[1]))?;
            let starts = brick.at(world, second, 0.0, 0.0)?.0;
            let ends = brick.at(world, first, 1.0, 0.0)?.0;
            expect!(starts > ends, "{} does not start after {} ends", c[1], c[0]);
            shown_named(world, &format!("plannerArrow:{}->{}", c[2], c[3]))?;
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is a milestone marker and today is marked"),
        |world, c, _| {
            let brick = shell(world)?;
            shown_named(world, &format!("plannerMilestone:{}", c[0]))?;
            let today = shown_named(world, "plannerToday")?;
            // Today is the second day of the first task's bar.
            let fake = state(&mut world.mc);
            let first = text(&fake.items[&fake.order[0]]["title"]);
            let bar = shown_named(world, &format!("plannerBar:{first}"))?;
            let here = brick.at(world, today, 0.5, 0.0)?.0;
            let start = brick.at(world, bar, 0.0, 0.0)?.0;
            let day = day_width(world)?;
            expect!(
                here > start + day && here < start + 2.0 * day,
                "today is drawn at {here}, not on the bar's second day from {start}"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the plan has {Q} from {Q} to {Q}"),
        |world, c, _| {
            dated(&mut world.mc, &c[0], &c[1], &c[2]);
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("the user drags the bar of {Q} one week later on the {Q}"),
        |world, c, _| {
            show_planner(world, &c[1])?;
            let bar = shown_named(world, &format!("plannerBar:{}", c[0]))?;
            let by = 7.0 * day_width(world)?;
            drag(world, bar, (by, 0.0))
        },
    );
    steps.step(&format!("{Q} is moved to {Q} to {Q}"), |world, c, _| {
        let id = id_of(&mut world.mc, &c[0]);
        let moved = json!({"id": id, "fields": {"start": c[1], "due": c[2]}});
        wait_asked(world, "updateItem", moved)?;
        // One change, when the bar is let go.
        expect!(
            asked(&world.mc, "updateItem").len() == 1,
            "the MC was asked {}",
            show_asked(&world.mc, "updateItem")
        );
        Ok(())
    });
    steps.step(
        &format!("the user drags the end of the bar of {Q} to {Q}"),
        |world, c, _| {
            show_planner(world, "Timeline")?;
            let due = parse(&text(&item(&mut world.mc, &c[0])["due"])).unwrap_or_default();
            let end = shown_named(world, &format!("plannerBarEnd:{}", c[0]))?;
            let by = (parse(&c[1]).unwrap_or_default() - due).num_days() as f64 * day_width(world)?;
            drag(world, end, (by, 0.0))
        },
    );
    steps.step(&format!("{Q} ends on {Q}"), |world, c, _| {
        let task = item(&mut world.mc, &c[0]).clone();
        let ended = json!({"id": task["id"], "fields": {"start": task["start"], "due": c[1]}});
        wait_asked(world, "updateItem", ended)?;
        expect!(
            asked(&world.mc, "updateItem").len() == 1,
            "the MC was asked {}",
            show_asked(&world.mc, "updateItem")
        );
        Ok(())
    });
}

fn register_board(steps: &mut Steps) {
    steps.step(&format!("the plan has {Q} not started"), |world, c, _| {
        item(&mut world.mc, &c[0])["status"] = json!("todo");
        publish(&mut world.mc)
    });
    steps.step(
        &format!("the user drags {Q} to {Q} on the {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            show_planner(world, &c[2])?;
            let card = shown_named(world, &format!("plannerCard:{}", c[0]))?;
            let column = shown_named(world, &format!("plannerBoardColumn:{}", c[1]))?;
            let to = brick.at(world, column, 0.5, 0.5)?;
            let from = brick.at(world, card, 0.5, 0.5)?;
            drag(world, card, (to.0 - from.0, to.1 - from.1))
        },
    );
    steps.step(&format!("{Q} is in progress"), |world, c, _| {
        let id = id_of(&mut world.mc, &c[0]);
        wait_asked(
            world,
            "updateItem",
            json!({"id": id, "fields": {"status": "doing"}}),
        )?;
        // The board shows it where the MC has it.
        wait_under(
            world,
            "plannerBoardColumn:In progress",
            &format!("plannerCard:{}", c[0]),
            format!("{} to be under In progress", c[0]),
        )
    });

    steps.step(&format!("the plan has {Q} dropped"), |world, c, _| {
        item(&mut world.mc, &c[0])["status"] = json!("dropped");
        publish(&mut world.mc)
    });
    steps.step(&format!("{Q} is under {Q} on the board"), |world, c, _| {
        wait_under(
            world,
            &format!("plannerBoardColumn:{}", c[1]),
            &format!("plannerCard:{}", c[0]),
            format!("{} to be under {}", c[0], c[1]),
        )
    });
    steps.step(
        &format!("the plan has {Q} under {Q} and {Q} under {Q}"),
        |world, c, _| {
            for i in [0, 2] {
                let parent = text(&item(&mut world.mc, &c[i + 1])["id"]);
                item(&mut world.mc, &c[i])["parent"] = json!(parent);
            }
            publish(&mut world.mc)
        },
    );
    steps.step(&format!("the {Q} is grouped by {Q}"), |world, c, _| {
        set_views(&mut world.mc, &c[0], |shown| shown["groupBy"] = json!(c[1]));
        publish(&mut world.mc)
    });
    steps.step(&format!("{Q} is moved under {Q}"), |world, c, _| {
        let moved = json!({"id": id_of(&mut world.mc, &c[0]),
                           "fields": {"parent": id_of(&mut world.mc, &c[1])}});
        wait_asked(world, "updateItem", moved)?;
        wait_under(
            world,
            &format!("plannerBoardColumn:{}", c[1]),
            &format!("plannerCard:{}", c[0]),
            format!("{} to be under {}", c[0], c[1]),
        )
    });
    steps.step(
        &format!("the milestones {Q} and {Q}, with {Q} waiting for {Q}"),
        |world, c, _| {
            let task = text(&item(&mut world.mc, &c[3])["id"]);
            for name in [&c[0], &c[1]] {
                item(&mut world.mc, name)["kind"] = json!("milestone");
            }
            item(&mut world.mc, &c[2])["after"] = json!([task]);
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("{Q} waits for {Q} and {Q} no longer does"),
        |world, c, _| {
            let moved = json!({"id": id_of(&mut world.mc, &c[1]),
                               "from": id_of(&mut world.mc, &c[2]),
                               "to": id_of(&mut world.mc, &c[0])});
            wait_asked(world, "moveToMilestone", moved)?;
            expect!(
                asked(&world.mc, "updateItem").is_empty(),
                "the milestones were changed one at a time: {}",
                show_asked(&world.mc, "updateItem")
            );
            wait_under(
                world,
                &format!("plannerBoardColumn:{}", c[0]),
                &format!("plannerCard:{}", c[1]),
                format!("{} to be under {}", c[1], c[0]),
            )
        },
    );
    steps.step(
        &format!("the plan has {Q} not started and {Q} dropped"),
        |world, c, _| {
            item(&mut world.mc, &c[0])["status"] = json!("todo");
            item(&mut world.mc, &c[1])["status"] = json!("dropped");
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("{Q} and {Q} are in the one column of the board"),
        |world, c, _| {
            let brick = shell(world)?;
            let board = shown_named(world, "plannerBoard")?;
            let columns = |w: &World| -> Vec<String> {
                property_json(w, brick, board, "columns")
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|column| text(&column["label"]))
                    .collect()
            };
            world.wait_for_with(
                |w| columns(w).len() == 1,
                |w| format!("one column on the board, not {}", columns(w).join(", ")),
            )?;
            let label = columns(world).first().cloned().unwrap_or_default();
            let column = shown_named(world, &format!("plannerBoardColumn:{label}"))?;
            for title in [&c[0], &c[1]] {
                world.wait_for_with(
                    |w| {
                        matches!(
                            brick.find_under(w, column, &format!("plannerCard:{title}")),
                            Ok(Some(_))
                        )
                    },
                    |_| format!("{title} to be in the column"),
                )?;
            }
            Ok(())
        },
    );
}

fn register_list(steps: &mut Steps) {
    steps.step(
        &format!("the view {Q} shows the owner and the due date"),
        |world, c, _| {
            seed_when_empty(&mut world.mc);
            set_views(&mut world.mc, &c[0], |shown| {
                shown["fields"] = json!(["status", "owner", "due"])
            });
            publish(&mut world.mc)
        },
    );
    steps.step(
        "each task's owner and due date are columns of the list",
        |world, _, _| {
            let brick = shell(world)?;
            let list = shown_named(world, "plannerList")?;
            for field in ["owner", "due"] {
                shown_named(world, &format!("plannerColumn:{field}"))?;
            }
            let fake = state(&mut world.mc);
            let tasks: Vec<Json> = fake.order.iter().map(|id| fake.items[id].clone()).collect();
            for task in tasks {
                let title = text(&task["title"]);
                let row_name = format!("plannerRow:{title}");
                world.wait_for_with(
                    |w| matches!(brick.find_under(w, list, &row_name), Ok(Some(_))),
                    |_| format!("{title} to be listed"),
                )?;
                let row = brick.find_under(world, list, &row_name)?;
                for field in ["owner", "due"] {
                    let cell = match row {
                        Some(row) => {
                            brick.find_under(world, row, &format!("plannerCell:{field}"))?
                        }
                        None => None,
                    };
                    expect!(
                        cell.is_some_and(
                            |cell| brick.text_of(world, cell, "text") == text(&task[field])
                        ),
                        "{title}'s {field} is not shown"
                    );
                }
            }
            Ok(())
        },
    );

    steps.step(&format!("the user is on the view {Q}"), |world, c, _| {
        seed_when_empty(&mut world.mc);
        publish(&mut world.mc)?;
        show_planner(world, &c[0])?;
        Ok(())
    });
    steps.step(
        "the user groups it by project, zooms to months and saves it",
        |world, _, _| {
            let brick = shell(world)?;
            let group_by = shown_named(world, "plannerGroupBy")?;
            let values = property_json(world, brick, group_by, "values");
            let project = values
                .as_array()
                .and_then(|list| list.iter().position(|v| text(v) == "project"));
            let Some(project) = project else {
                fail!("the view cannot be grouped by project")
            };
            expect!(
                invoke(world, group_by, "activated", &[Value::Int(project as i32)]).is_ok(),
                "the view cannot be grouped by project"
            );
            let month = shown_named(world, "plannerZoom:month")?;
            click(world, month)?;
            let save = shown_named(world, "plannerViewSave")?;
            click(world, save)
        },
    );
    steps.step(
        &format!("{Q} is grouped by project at months on every client"),
        |world, c, _| {
            let brick = shell(world)?;
            world.wait_for_with(
                |w| {
                    let saved = asked(&w.mc, "saveView")
                        .first()
                        .map_or(Json::Null, |a| a["view"].clone());
                    text(&saved["name"]) == c[0]
                        && text(&saved["id"]) == "timeline"
                        && text(&saved["groupBy"]) == "project"
                        && text(&saved["zoom"]) == "month"
                },
                |w| {
                    format!(
                        "the view to be saved grouped by project at months, not {}",
                        show_asked(&w.mc, "saveView")
                    )
                },
            )?;
            // Published back, the saved view is the one shown, unchanged.
            wait_hidden(world, "plannerViewChanged")?;
            shown_named(world, "plannerGroup:api")?;
            let gantt = shown_named(world, "plannerGantt")?;
            expect!(
                brick.text_of(world, gantt, "zoom") == "month",
                "the chart is not at months"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the user types {Q} in the filter"),
        |world, c, _| {
            let filter = shown_named(world, "plannerFilter")?;
            click_item(world, filter)?;
            type_text(world, &c[0])
        },
    );
    steps.step(
        &format!("only tasks matching {Q} are shown"),
        |world, c, _| {
            let fake = state(&mut world.mc);
            let titles: Vec<String> = fake
                .order
                .iter()
                .map(|id| text(&fake.items[id]["title"]))
                .collect();
            for title in titles {
                let row = format!("plannerRow:{title}");
                if title.to_lowercase().contains(&c[0].to_lowercase()) {
                    shown_named(world, &row)?;
                } else {
                    wait_hidden(world, &row)?;
                }
            }
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is marked as changed until it is saved or reverted"),
        |world, c, _| {
            shown_named(world, "plannerViewChanged")?;
            let tab = shown_named(world, &format!("plannerView:{}", c[0]))?;
            expect!(
                draws_text(world, tab, &format!("• {}", c[0]))?,
                "the tab of {} is not marked",
                c[0]
            );
            let revert = shown_named(world, "plannerViewRevert")?;
            click(world, revert)?;
            wait_hidden(world, "plannerViewChanged")?;
            wait_text(world, "plannerFilter", "")?;
            let fake = state(&mut world.mc);
            let titles: Vec<String> = fake
                .order
                .iter()
                .map(|id| text(&fake.items[id]["title"]))
                .collect();
            for title in titles {
                shown_named(world, &format!("plannerRow:{title}"))?;
            }
            expect!(
                asked(&world.mc, "saveView").is_empty(),
                "the filter was saved"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the user tabs from the view {Q} to {Q} and presses Enter"),
        |world, c, _| {
            let brick = shell(world)?;
            let from = shown_named(world, &format!("plannerView:{}", c[0]))?;
            let _ = invoke(world, from, "forceActiveFocus", &[]);
            press(world, "tab")?;
            let next = shown_named(world, &format!("plannerView:{}", c[1]))?;
            world.wait_for_with(
                |w| brick.flag(w, next, "activeFocus"),
                |_| format!("the tab of {} to have the keyboard", c[1]),
            )?;
            press(world, "return")?;
            world.sync()
        },
    );
    steps.step(&format!("the planner shows the view {Q}"), |world, c, _| {
        wait_planner_view(world, &c[0])
    });

    steps.step(
        &format!("the user focuses {Q} on {Q} and presses Enter"),
        |world, c, _| {
            let brick = shell(world)?;
            show_planner(world, &c[1])?;
            let page = shown_named(world, "plannerPage")?;
            let find = |w: &World| -> Option<ObjectId> {
                ["plannerTask:", "plannerCard:", "plannerRow:"]
                    .iter()
                    .find_map(|prefix| {
                        brick
                            .find_under(w, page, &format!("{prefix}{}", c[0]))
                            .ok()
                            .flatten()
                            .filter(|found| brick.flag(w, *found, "visible"))
                    })
            };
            world.wait_for_with(
                |w| find(w).is_some(),
                |_| format!("{} to be shown on {}", c[0], c[1]),
            )?;
            let Some(shown) = find(world) else {
                fail!("{} is gone", c[0])
            };
            expect!(
                brick.flag(world, shown, "activeFocusOnTab"),
                "{} cannot be reached with Tab on {}",
                c[0],
                c[1]
            );
            let _ = invoke(world, shown, "forceActiveFocus", &[]);
            press(world, "return")?;
            world.sync()?;
            world.wait_for_with(
                |w| brick.flag(w, shown, "activeFocus"),
                |_| format!("{} to keep the keyboard", c[0]),
            )
        },
    );
    steps.step(
        &format!("the panel of {Q} is open and {Q} is marked as focused"),
        |world, c, _| {
            let brick = shell(world)?;
            wait_text(world, "plannerItemTitle", &c[0])?;
            let page = shown_named(world, "plannerPage")?;
            let focused = ["plannerTask:", "plannerCard:", "plannerRow:"]
                .iter()
                .find_map(|prefix| {
                    brick
                        .find_under(world, page, &format!("{prefix}{}", c[1]))
                        .ok()
                        .flatten()
                        .filter(|found| brick.flag(world, *found, "activeFocus"))
                });
            let Some(focused) = focused else {
                fail!("{} does not have the keyboard", c[1])
            };
            let border = brick.read(world, focused, "border");
            let width = match border {
                Value::Object(border) => real(world, brick, border, "width"),
                _ => 0.0,
            };
            expect!(width > 0.0, "{} has no focus border", c[1]);
            Ok(())
        },
    );
    steps.step(
        &format!("the user focuses the group {Q} on {Q} and presses Space"),
        |world, c, _| {
            show_planner(world, &c[1])?;
            let group = shown_named(world, &format!("plannerGroup:{}", c[0]))?;
            let _ = invoke(world, group, "forceActiveFocus", &[]);
            world.part::<PlannerWorld>().group = c[0].clone();
            press(world, "space")?;
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} is hidden until the user presses Space again"),
        |world, c, _| {
            let brick = shell(world)?;
            let list = shown_named(world, "plannerList")?;
            let row = format!("plannerRow:{}", c[0]);
            let listed = |w: &World| matches!(brick.find_under(w, list, &row), Ok(Some(_)));
            world.wait_for_with(|w| !listed(w), |_| format!("{} to be folded away", c[0]))?;
            let group = world.part::<PlannerWorld>().group.clone();
            world.wait_for_with(
                |w| {
                    matches!(brick.find_under(w, list, &format!("plannerGroup:{group}")),
                        Ok(Some(found)) if brick.flag(w, found, "activeFocus"))
                        || brick.root(w).is_some_and(|root| {
                            ljos::item::active_focus_item(w.engine(), root).is_some_and(|focused| {
                                brick
                                    .text_of(w, focused, "objectName")
                                    .starts_with("plannerGroup:")
                            })
                        })
                },
                |_| "the group to keep the keyboard once folded".to_owned(),
            )?;
            press(world, "space")?;
            world.wait_for_with(|w| listed(w), |_| format!("{} to be listed again", c[0]))
        },
    );
    steps.step(&format!("the view {Q} shows every field"), |world, c, _| {
        seed_when_empty(&mut world.mc);
        set_views(&mut world.mc, &c[0], |shown| {
            shown["fields"] = json!(FIELDS)
        });
        publish(&mut world.mc)?;
        show_planner(world, &c[0])?;
        Ok(())
    });
    steps.step(
        "the user scrolls the list sideways to its end",
        |world, _, _| {
            let brick = shell(world)?;
            let list = shown_named(world, "plannerList")?;
            world.wait_for_with(
                |w| real(w, brick, list, "contentWidth") > real(w, brick, list, "width"),
                |_| "the list's columns to be wider than it".to_owned(),
            )?;
            // Drags the scroll bar's handle to the far end, the way a mouse user
            // reaches the last columns.
            let bar = shown_named(world, "plannerListScroll")?;
            let size = real(world, brick, bar, "size");
            let from = brick.at(world, bar, size / 2.0, 0.5)?;
            let to = brick.at(world, bar, 1.0, 0.5)?;
            let (fx, fy) = (from.0.round(), from.1.round());
            let (tx, ty) = ((to.0 - 1.0).round(), to.1.round());
            world.pointer(|now| PointerEvent::press(fx, fy, now))?;
            for step in 1..=10 {
                let f = f64::from(step) / 10.0;
                let (x, y) = ((fx + (tx - fx) * f).round(), (fy + (ty - fy) * f).round());
                world.pointer(|now| PointerEvent::moved(x, y, MouseButtons::LEFT, now))?;
            }
            world.pointer(|now| PointerEvent::release(tx, ty, now))?;
            world.sync()
        },
    );
    steps.step("the column of the last field is shown", |world, _, _| {
        let brick = shell(world)?;
        let list = shown_named(world, "plannerList")?;
        let last = FIELDS[FIELDS.len() - 1];
        let column = shown_named(world, &format!("plannerColumn:{last}"))?;
        world.wait_for_with(
            |w| {
                let (Ok(left), Ok(right), Ok(origin)) = (
                    brick.at(w, column, 0.0, 0.0),
                    brick.at(w, column, 1.0, 0.0),
                    brick.at(w, list, 0.0, 0.0),
                ) else {
                    return false;
                };
                left.0 - origin.0 >= 0.0 && right.0 - origin.0 <= real(w, brick, list, "width")
            },
            |_| format!("the {last} column to be inside the list"),
        )
    });
}

fn register_panel(steps: &mut Steps) {
    steps.step(
        &format!("the plan has {Q} ending (\\d+) days before its baseline"),
        |world, c, _| {
            let task = dated(&mut world.mc, &c[0], "2026-10-21", "2026-10-30");
            let days: i64 = c[1].parse().unwrap_or(0);
            let due = plus(parse("2026-10-30").unwrap_or_default(), days);
            task["baseline"] = json!({"start": "2026-10-21", "due": iso(due)});
            publish(&mut world.mc)
        },
    );
    steps.step(&format!("the user opens the task {Q}"), |world, c, _| {
        show_planner(world, "")?;
        let task = shown_named(world, &format!("plannerTask:{}", c[0]))?;
        click(world, task)?;
        wait_text(world, "plannerItemTitle", &c[0])
    });
    steps.step(
        "its panel says it ends (\\d+) days before its baseline",
        |world, c, _| {
            let brick = shell(world)?;
            let wanted = format!("Ends {} days before its baseline", c[0]);
            world.wait_for_with(
                |w| text_now(w, brick, "plannerItemNotices").as_deref() == Some(wanted.as_str()),
                |w| {
                    format!(
                        "the panel says {}",
                        text_now(w, brick, "plannerItemNotices").unwrap_or_default()
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the plan has the milestone {Q} due (\\d+) days after its baseline"),
        |world, c, _| {
            let days: i64 = c[1].parse().unwrap_or(0);
            let milestone = item(&mut world.mc, &c[0]);
            milestone["kind"] = json!("milestone");
            milestone["due"] = json!("2026-10-30");
            milestone["baseline"] =
                json!({"due": iso(plus(parse("2026-10-30").unwrap_or_default(), -days))});
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("the chart reaches back to the baseline of {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            let due =
                parse(&text(&item(&mut world.mc, &c[0])["baseline"]["due"])).unwrap_or_default();
            let gantt = shown_named(world, "plannerGantt")?;
            let first = real(world, brick, gantt, "rangeStart") as i64;
            let epoch = NaiveDate::from_ymd_opt(1970, 1, 1).unwrap_or_default();
            expect!(
                first <= (due - epoch).num_days(),
                "the chart starts on {}, after the baseline's {}",
                iso(plus(epoch, first)),
                iso(due)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the plan has {Q} in the project {Q}"),
        |world, c, _| {
            dated(&mut world.mc, &c[0], "2026-10-21", "2026-10-30")["projectId"] = json!(c[1]);
            publish(&mut world.mc)
        },
    );
    steps.step(&format!("its project reads {Q}"), |world, c, _| {
        let brick = shell(world)?;
        // The MC offers only the project api.
        let combo = shown_named(world, "plannerItemProject")?;
        let shown = brick.text_of(world, combo, "displayText");
        expect!(
            real(world, brick, combo, "currentIndex") as i64 == -1 && shown == c[0],
            "the project reads {shown}"
        );
        Ok(())
    });
    steps.step(
        &format!("the plan has the milestone {Q} without a due date"),
        |world, c, _| {
            seed_when_empty(&mut world.mc);
            item(&mut world.mc, &c[0])["kind"] = json!("milestone");
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("{Q} is listed with no marker on the timeline"),
        |world, c, _| {
            let brick = shell(world)?;
            shown_named(world, &format!("plannerTask:{}", c[0]))?;
            expect!(
                hidden(world, brick, &format!("plannerMilestone:{}", c[0])),
                "{} has a marker",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(&format!("the plan has {Q}"), |world, c, _| {
        dated(&mut world.mc, &c[0], "2026-10-21", "2026-10-30");
        publish(&mut world.mc)
    });
    steps.step(
        &format!("the user opens {Q} and sets its owner to {Q} and its due date to {Q}"),
        |world, c, _| {
            show_planner(world, "")?;
            let task = shown_named(world, &format!("plannerTask:{}", c[0]))?;
            click(world, task)?;
            wait_text(world, "plannerItemTitle", &c[0])?;
            for (field, value) in [("plannerItemOwner", &c[1]), ("plannerItemDue", &c[2])] {
                set_text_and(world, field, value, "editingFinished")?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is owned by {Q} and due {Q}"),
        |world, c, _| {
            let id = id_of(&mut world.mc, &c[0]);
            wait_asked(
                world,
                "updateItem",
                json!({"id": id, "fields": {"owner": c[1]}}),
            )?;
            wait_asked(
                world,
                "updateItem",
                json!({"id": id, "fields": {"due": c[2]}}),
            )?;
            wait_text(world, "plannerItemOwner", &c[1])?;
            wait_text(world, "plannerItemDue", &c[2])
        },
    );
}

fn register_runs(steps: &mut Steps) {
    steps.step(
        &format!("the run of {Q} proposes moving {Q} to end on {Q}"),
        |world, c, _| {
            propose(&mut world.mc, &c[0], &c[1], &c[2])?;
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("the user opens the run on the {Q} tab"),
        |world, c, _| {
            expect!(c[0] == "Planner", "planner has no tab {}", c[0]);
            let label = text(&last_run(&mut world.mc)?["label"]);
            open_run(world, &label)
        },
    );
    steps.step(
        &format!("the bar {Q} would have is drawn beside its current one"),
        |world, c, _| {
            let brick = shell(world)?;
            let ghost = shown_named(world, &format!("plannerGhost:{}", c[0]))?;
            let bar = shown_named(world, &format!("plannerBar:{}", c[0]))?;
            let parent = |w: &World, each: ObjectId| match brick.read(w, each, "parent") {
                Value::Object(p) => Some(p),
                _ => None,
            };
            expect!(
                parent(world, ghost) == parent(world, bar),
                "the proposed bar is not on {}'s row",
                c[0]
            );
            let ends = brick.at(world, bar, 1.0, 0.0)?.0;
            let proposed = brick.at(world, ghost, 1.0, 0.0)?.0;
            expect!(
                proposed > ends,
                "the proposed bar ends at {proposed}, not after {ends}"
            );
            Ok(())
        },
    );
    steps.step(
        "the run list counts only the changes the user keeps",
        |world, _, _| {
            let brick = shell(world)?;
            let label = text(&last_run(&mut world.mc)?["label"]);
            let says = |w: &World| -> String {
                let Some(row) = named(w, brick, &format!("plannerRun:{label}")) else {
                    return String::new();
                };
                match brick.find_under(w, row, "plannerRunState") {
                    Ok(Some(found)) => brick.text_of(w, found, "text"),
                    _ => String::new(),
                }
            };
            let counts = |world: &mut World, wanted: &str| {
                world.wait_for_with(
                    |w| says(w) == wanted,
                    |w| format!("the run list says {}", says(w)),
                )
            };
            let dismiss = |world: &mut World| -> Outcome<ObjectId> {
                let change = shown_named(world, "plannerChange:c1")?;
                match brick.find_under(world, change, "plannerChangeDismiss")? {
                    Some(found) => Ok(found),
                    None => fail!("the change has no plannerChangeDismiss"),
                }
            };
            counts(world, "1 change")?;
            let first = dismiss(world)?;
            click(world, first)?;
            counts(world, "0 changes")?;
            let second = dismiss(world)?;
            click(world, second)?;
            counts(world, "1 change")
        },
    );
    steps.step(
        "the user can dismiss the change, apply the run or discard it",
        |world, _, _| {
            let brick = shell(world)?;
            let run = text(&last_run(&mut world.mc)?["id"]);
            // A changed run draws its changes again.
            let dismiss = |world: &mut World| -> Outcome<ObjectId> {
                let change = shown_named(world, "plannerChange:c1")?;
                match brick.find_under(world, change, "plannerChangeDismiss")? {
                    Some(found) => Ok(found),
                    None => fail!("the change has no plannerChangeDismiss"),
                }
            };
            let first = dismiss(world)?;
            click(world, first)?;
            world.wait_for_with(
                |w| matches!(dismiss_now(w, brick), Some(found) if brick.text_of(w, found, "text") == "Keep"),
                |_| "the change to be dismissed".to_owned(),
            )?;
            wait_asked(
                world,
                "dismissChange",
                json!({"runId": run, "changeId": "c1", "dismissed": true}),
            )?;
            let second = dismiss(world)?;
            click(world, second)?;
            world.wait_for_with(
                |w| matches!(dismiss_now(w, brick), Some(found) if brick.text_of(w, found, "text") == "Dismiss"),
                |_| "the change to be kept".to_owned(),
            )?;
            let discard = shown_named(world, "plannerDiscard")?;
            expect!(brick.flag(world, discard, "enabled"), "the run cannot be discarded");

            let apply = shown_named(world, "plannerApply")?;
            click(world, apply)?;
            wait_asked(world, "apply", json!({"runId": run}))?;
            world.wait_for_with(
                |w| text_now(w, brick, "plannerRunStatus").is_some_and(|said| said.starts_with("Applied")),
                |w| text_now(w, brick, "plannerRunStatus").unwrap_or_default(),
            )?;
            wait_hidden(world, "plannerApply")
        },
    );

    steps.step(
        &format!("a second MC also runs {Q}, whose run of {Q} proposes moving its own {Q}"),
        |world, c, _| {
            expect!(c[0] == ID, "only {ID} is faked");
            seed_when_empty(&mut world.mc);
            publish(&mut world.mc)?;
            let part = fake_plugin_part(&mut world.mc, ID)?.clone();
            // Its task has the id of this MC's first one, as another MC's
            // plan may well have.
            let mut plan = part.topics.get("plan").cloned().unwrap_or(Json::Null);
            let mut task = plan["items"][0].clone();
            task["title"] = json!(c[2]);
            let id = task["id"].clone();
            plan["items"] = json!([task]);
            plan["views"] = json!([]);
            let run_action = action_id(&mut world.mc, &c[1])?;
            let run = json!({"id": "r-work", "action": run_action, "label": c[1], "kind": "action",
                "status": "proposed", "itemIds": [id], "projectId": PROJECT, "threadId": null,
                "startedAt": "2026-10-20T09:00:00Z", "summary": "", "feedback": [],
                "changes": [{"id": "c1", "op": "update", "itemId": id,
                             "fields": {"due": "2026-11-06"}, "reason": ""}]});
            fake_plugin_part(&mut world.mc, ID)?.topics_on.insert(
                "work".into(),
                HashMap::from([
                    ("plan".to_owned(), plan),
                    ("runs".to_owned(), json!({"runs": [run]})),
                    ("threads".to_owned(), json!({})),
                ]),
            );
            let read = manifest(&package_dir())?;
            let settings = state(&mut world.mc).settings.clone();
            run_fake_plugin_on(world, "work", entry_of(ID, &read, &settings))?;
            // Until each MC's copy of the plugin is unpacked the tab borrows
            // another's page, and switching to its own reloads it, closing
            // whatever was open.
            world.wait_for_with(
                |w| {
                    let environments = w.state("mcPlugins")["environments"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    environments.len() == 2
                        && environments.iter().all(|environment| {
                            environment["plugins"].as_array().is_some_and(|plugins| {
                                plugins.first().is_some_and(|first| {
                                    !text(&first["settingsPageUrl"]).is_empty()
                                })
                            })
                        })
                },
                |w| {
                    format!(
                        "both MCs' copies of the planner to be unpacked; {}",
                        describe(w)
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user opens that MC's run on the {Q} tab"),
        |world, c, _| {
            expect!(c[0] == "Planner", "planner has no tab {}", c[0]);
            open_run(world, "Validate progress")
        },
    );
    steps.step(
        &format!("the run is listed with that MC's name and {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            let row = shown_named(world, "plannerRun:Validate progress")?;
            world.wait_for_with(
                |w| matches!(brick.find_under(w, row, "plannerRunTitle"), Ok(Some(_))),
                |_| "the run's title".to_owned(),
            )?;
            let title = brick.find_under(world, row, "plannerRunTitle")?;
            let shown = title
                .map(|title| brick.text_of(world, title, "text"))
                .unwrap_or_default();
            expect!(
                shown == format!("Validate progress (work) · {}", c[0]),
                "the run is listed as {shown}"
            );
            Ok(())
        },
    );
    steps.step(&format!("its change names {Q}"), |world, c, _| {
        let brick = shell(world)?;
        let change = shown_named(world, "plannerChange:c1")?;
        let said = match brick.find_under(world, change, "plannerChangeText")? {
            Some(found) => brick.text_of(world, found, "text"),
            None => fail!("the change has no plannerChangeText"),
        };
        expect!(
            said.starts_with(&format!("{}: ", c[0])),
            "the change says {said}"
        );
        Ok(())
    });
}

/// The shown `plannerChangeDismiss` of the first change, if the window has
/// one.
fn dismiss_now(w: &World, brick: Brick) -> Option<ObjectId> {
    let change = named(w, brick, "plannerChange:c1")?;
    brick
        .find_under(w, change, "plannerChangeDismiss")
        .ok()
        .flatten()
}

fn register_threads(steps: &mut Steps) {
    steps.step(
        &format!("the run of {Q} proposes moving {Q}"),
        |world, c, _| {
            let run = propose(&mut world.mc, &c[0], &c[1], "2026-11-06")?;
            list_thread(world, &run)?;
            publish(&mut world.mc)
        },
    );
    steps.step("the user opens the run's thread", |world, _, _| {
        let thread = text(&last_run(&mut world.mc)?["threadId"]);
        open_plugin_thread(world, &thread)
    });
    steps.step(
        "the action, the state of its run and the apply action are shown above the conversation",
        |world, _, _| {
            let brick = shell(world)?;
            let header = shown_named(world, "plannerHeader")?;
            let thread_header = shown_named(world, "pluginThreadHeader")?;
            expect!(
                brick.find_under(world, thread_header, "plannerHeader")? == Some(header),
                "the header is not the thread's"
            );
            let run = last_run(&mut world.mc)?;
            world.wait_for_with(
                |w| header_text(w, brick, header, "plannerHeaderTitle") == text(&run["label"]),
                |w| header_text(w, brick, header, "plannerHeaderTitle"),
            )?;
            let status = header_text(world, brick, header, "plannerHeaderStatus");
            expect!(
                status.contains("Proposes 1 change"),
                "the header says {status}"
            );
            let apply = header_part(world, brick, header, "plannerHeaderApply")?;
            expect!(
                brick.flag(world, apply, "visible") && brick.flag(world, apply, "enabled"),
                "the run cannot be applied from its thread"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the run of {Q} proposes only that the plan is {Q}"),
        |world, c, _| {
            let run = add_run(&mut world.mc, &c[0], &[], "proposed")?;
            run["summary"] = json!("Schema slipped three days.");
            run["health"] = json!(c[1]);
            let run = run.clone();
            list_thread(world, &run)?;
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("the run can be applied from its thread and from the {Q} tab"),
        |world, c, _| {
            let brick = shell(world)?;
            let header = shown_named(world, "plannerHeader")?;
            world.wait_for_with(
                |w| {
                    header_text(w, brick, header, "plannerHeaderStatus")
                        == "Proposes a status update"
                },
                |w| header_text(w, brick, header, "plannerHeaderStatus"),
            )?;
            let apply = header_part(world, brick, header, "plannerHeaderApply")?;
            expect!(
                brick.flag(world, apply, "visible") && brick.flag(world, apply, "enabled"),
                "the status update cannot be applied from its thread"
            );
            expect!(c[0] == "Planner", "planner has no tab {}", c[0]);
            let label = text(&last_run(&mut world.mc)?["label"]);
            show_planner(world, "")?;
            let toggle = shown_named(world, "plannerRunsToggle")?;
            click(world, toggle)?;
            let run = shown_named(world, &format!("plannerRun:{label}"))?;
            click(world, run)?;
            let apply = shown_named(world, "plannerApply")?;
            expect!(
                brick.flag(world, apply, "enabled"),
                "the status update cannot be applied from the Planner tab"
            );
            Ok(())
        },
    );
    steps.step(
        "the run list says it proposes a status update",
        |world, _, _| {
            let brick = shell(world)?;
            let label = text(&last_run(&mut world.mc)?["label"]);
            let row = shown_named(world, &format!("plannerRun:{label}"))?;
            let says = |w: &World| match brick.find_under(w, row, "plannerRunState") {
                Ok(Some(found)) => brick.text_of(w, found, "text"),
                _ => String::new(),
            };
            world.wait_for_with(
                |w| says(w) == "Status update",
                |w| format!("the run list says {}", says(w)),
            )
        },
    );
    steps.step(
        &format!(
            "the user applies {Q} from its thread and opens the thread of {Q} before the MC answers"
        ),
        |world, c, _| {
            let first = text(&run_of(&mut world.mc, &c[0])?["threadId"]);
            let header = open_header(world, &first, &c[0])?;
            world.mc.hold("planner.refuseApply");
            let brick = shell(world)?;
            let apply = header_part(world, brick, header, "plannerHeaderApply")?;
            click(world, apply)?;
            let run = run_of(&mut world.mc, &c[0])?;
            wait_asked(world, "apply", json!({"runId": run["id"]}))?;
            let second = text(&run_of(&mut world.mc, &c[1])?["threadId"]);
            open_header(world, &second, &c[1])?;
            Ok(())
        },
    );
    steps.step(&format!("the MC refuses to apply {Q}"), |world, c, _| {
        expect!(
            world.mc.holding("planner.refuseApply"),
            "the apply of {} is not waiting on the MC",
            c[0]
        );
        world.mc.answer_held();
        world.sync()
    });
    steps.step(
        &format!("the thread of {Q} can be applied and shows no problem"),
        |world, c, _| {
            let brick = shell(world)?;
            let header = shown_named(world, "plannerHeader")?;
            let title = header_text(world, brick, header, "plannerHeaderTitle");
            expect!(title == c[0], "the header is {title}'s");
            let problem = header_part(world, brick, header, "plannerHeaderProblem")?;
            expect!(
                !brick.flag(world, problem, "visible"),
                "the header says {}",
                brick.text_of(world, problem, "text")
            );
            let apply = header_part(world, brick, header, "plannerHeaderApply")?;
            expect!(
                brick.flag(world, apply, "visible")
                    && brick.flag(world, apply, "enabled")
                    && brick.text_of(world, apply, "text") == "Apply",
                "the run cannot be applied: its button says {}",
                brick.text_of(world, apply, "text")
            );
            Ok(())
        },
    );

    steps.step(
        &format!("{Q} shows its threads in the thread list"),
        |world, c, _| {
            expect!(c[0] == ID, "only {ID} is faked");
            state(&mut world.mc).settings["display"] = json!("both");
            Ok(())
        },
    );
    steps.step(
        "its thread is listed with the planner mark and the state of its run",
        |world, _, _| {
            marked(world, "Running", "the row mark to say Running".to_owned())?;
            // The mark follows the run.
            let fake = state(&mut world.mc);
            let Some(run) = fake.runs.last_mut() else {
                fail!("the plan has no run")
            };
            run["status"] = json!("proposed");
            run["changes"] = json!([{"id": "c1", "op": "update", "itemId": "t1",
                                     "fields": {"due": "2026-11-06"}, "dismissed": false}]);
            publish(&mut world.mc)?;
            marked(world, "1 change", "the row mark to say 1 change".to_owned())
        },
    );

    steps.step(&format!("the work on {Q} is done"), |world, c, _| {
        seed_when_empty(&mut world.mc);
        let run = add_run(&mut world.mc, "Start work", &[c[0].clone()], "done")?;
        run["kind"] = json!("work");
        let run = run.clone();
        list_thread(world, &run)?;
        publish(&mut world.mc)?;
        marked(world, "Done", "the row mark to say Done".to_owned())
    });
    steps.step("its run is discarded", |world, _, _| {
        state(&mut world.mc).runs.pop();
        publish(&mut world.mc)
    });
    steps.step(
        &format!("its thread is listed with the mark {Q}"),
        |world, c, _| marked(world, &c[0], format!("the row mark to say {}", c[0])),
    );

    steps.step(
        &format!(
            "the agent works on {Q} in its thread, which shows the task above the conversation"
        ),
        |world, c, _| {
            let brick = shell(world)?;
            seed_when_empty(&mut world.mc);
            let run = add_run(&mut world.mc, "Start work", &[c[0].clone()], "running")?;
            run["kind"] = json!("work");
            let run = run.clone();
            list_thread(world, &run)?;
            publish(&mut world.mc)?;
            open_plugin_thread(world, &text(&run["threadId"]))?;
            let header = shown_named(world, "plannerHeader")?;
            // The task's status and progress come from the plan alone.
            world.wait_for_with(
                |w| {
                    matches!(brick.find_under(w, header, "plannerHeaderTask"),
                        Ok(Some(task)) if brick.flag(w, task, "visible"))
                },
                |_| "the header to show the task".to_owned(),
            )?;
            expect!(
                plan_watches(&world.mc) == 1,
                "the client follows the plan {} times",
                plan_watches(&world.mc)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens the thread of a run of {Q}"),
        |world, c, _| {
            let run = add_run(&mut world.mc, &c[0], &[], "running")?.clone();
            list_thread(world, &run)?;
            publish(&mut world.mc)?;
            open_header(world, &text(&run["threadId"]), &c[0])?;
            Ok(())
        },
    );
    steps.step(&format!("the work on {Q} is discarded"), |world, c, _| {
        let id = item(&mut world.mc, &c[0])["id"].clone();
        let fake = state(&mut world.mc);
        let before = fake.runs.len();
        fake.runs.retain(|run| {
            !(run["kind"] == json!("work")
                && run["itemIds"]
                    .as_array()
                    .is_some_and(|ids| ids.contains(&id)))
        });
        let removed = before - fake.runs.len();
        expect!(removed == 1, "{removed} work runs on {}", c[0]);
        publish(&mut world.mc)?;
        world.sync()
    });
    steps.step("the header no longer follows the plan", |world, _, _| {
        world.wait_for_with(
            |w| plan_watches(&w.mc) == 0,
            |w| {
                format!(
                    "the client to stop following the plan, {} watches left",
                    plan_watches(&w.mc)
                )
            },
        )?;
        // What the plan publishes next draws no new watch of it.
        let made = plan_subscriptions(&world.mc);
        publish(&mut world.mc)?;
        world.sync()?;
        expect!(
            plan_watches(&world.mc) == 0 && plan_subscriptions(&world.mc) == made,
            "the client follows the plan again"
        );
        Ok(())
    });

    steps.step(
        "its mark says so when the run proposes only a status update",
        |world, _, _| {
            let fake = state(&mut world.mc);
            let Some(run) = fake.runs.last_mut() else {
                fail!("the plan has no run")
            };
            run["status"] = json!("proposed");
            run["changes"] = json!([]);
            run["health"] = json!("on-track");
            publish(&mut world.mc)?;
            marked(
                world,
                "Status update",
                "the row mark to say Status update".to_owned(),
            )
        },
    );
}

fn prompt_of(actions: &Json, id: &str) -> String {
    text(&actions[id]["prompt"])
}

fn register_settings(steps: &mut Steps) {
    steps.step(
        &format!("the user changes the prompt of {Q} and resets {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            wait_loaded(world)?;
            let changed = action_id(&mut world.mc, &c[0])?;
            let prompt = shown_named(world, &format!("plannerActionPrompt:{changed}"))?;
            brick.write(
                world,
                prompt,
                "text",
                Value::from("My own reschedule prompt."),
            )?;
            // The buttons sit below the fold of the settings page, out of the
            // mouse's reach.
            let reset_id = action_id(&mut world.mc, &c[1])?;
            let reset = shown_named(world, &format!("plannerActionReset:{reset_id}"))?;
            wait_enabled(world, reset, "the reset to be enabled")?;
            press_button(world, reset, "the reset cannot be pressed")?;
            save_settings(world)
        },
    );
    steps.step(
        &format!("the prompt of {Q} is saved as changed and {Q} as the plugin's"),
        |world, c, _| {
            world.wait_for_with(
                |w| !saved_settings(&w.mc).is_empty(),
                |_| "the settings to be saved".to_owned(),
            )?;
            let sent = saved_settings(&world.mc)[0].clone();
            let keys: Vec<&String> = sent
                .as_object()
                .map(|o| o.keys().collect())
                .unwrap_or_default();
            expect!(keys == ["actions"], "the MC was sent {}", show(&sent));
            let actions = sent["actions"].clone();
            let changed = action_id(&mut world.mc, &c[0])?;
            let reset = action_id(&mut world.mc, &c[1])?;
            expect!(
                prompt_of(&actions, &changed) == "My own reschedule prompt.",
                "{} was saved as {}",
                c[0],
                show(&actions[&changed])
            );
            let defaults = state(&mut world.mc).default_actions.clone();
            expect!(
                prompt_of(&actions, &reset) == prompt_of(&defaults, &reset),
                "{} was saved as {}",
                c[1],
                show(&actions[&reset])
            );
            // Read again after the save, nothing is left to save.
            let brick = shell(world)?;
            let settings = shown_named(world, "plannerSettings")?;
            world.wait_for_with(
                |w| !brick.flag(w, settings, "dirty"),
                |_| "the settings to be read again".to_owned(),
            )
        },
    );

    steps.step(
        &format!("the user changes the prompt of {Q} and saves, then changes it again before the settings are read back"),
        |world, c, _| {
            let brick = shell(world)?;
            wait_loaded(world)?;
            let id = action_id(&mut world.mc, &c[0])?;
            let prompt = shown_named(world, &format!("plannerActionPrompt:{id}"))?;
            brick.write(world, prompt, "text", Value::from("My own reschedule prompt."))?;
            world.mc.hold("planner.settings");
            let reads = asked(&world.mc, "settings").len();
            save_settings(world)?;
            world.wait_for_with(
                |w| asked(&w.mc, "settings").len() > reads,
                |_| "the save to be answered".to_owned(),
            )?;
            brick.write(world, prompt, "text", Value::from("My second reschedule prompt."))?;
            world.mc.answer_held();
            world.sync()
        },
    );
    steps.step(
        &format!("the user saves a change to the prompt of {Q}, then undoes it and tries to save again before the settings are read back"),
        |world, c, _| {
            let brick = shell(world)?;
            let settings = wait_loaded(world)?;
            let id = action_id(&mut world.mc, &c[0])?;
            let prompt = shown_named(world, &format!("plannerActionPrompt:{id}"))?;
            let before = brick.text_of(world, prompt, "text");
            brick.write(world, prompt, "text", Value::from("My own reschedule prompt."))?;
            world.mc.hold("planner.settings");
            let reads = asked(&world.mc, "settings").len();
            save_settings(world)?;
            world.wait_for_with(
                |w| asked(&w.mc, "settings").len() > reads,
                |_| "the save to be answered".to_owned(),
            )?;
            brick.write(world, prompt, "text", Value::from(before.as_str()))?;
            // Saving again works from what the first save read back, so it
            // has to wait for it.
            let save = shown_named(world, "plannerSave")?;
            if brick.flag(world, save, "enabled") {
                press_button(world, save, "the settings cannot be saved")?;
                world.wait_for_with(
                    |w| asked(&w.mc, "settings").len() > reads + 1,
                    |_| "the second save to be answered".to_owned(),
                )?;
            }
            world.mc.answer_held();
            // Answers arrive in order on the one connection: once a call made
            // after them is answered, every read-back has landed.
            state(&mut world.mc).boards.push(
                json!({"id": "acme/99", "owner": "acme", "number": 99, "title": "Roadmap"}),
            );
            let wanted = state(&mut world.mc).boards.len();
            expect!(
                invoke(world, settings, "listBoards", &[]).is_ok(),
                "the boards cannot be listed"
            );
            world.wait_for_with(
                |w| property_json(w, brick, settings, "boards").as_array().map_or(0, Vec::len) == wanted,
                |_| "the settings to be read back".to_owned(),
            )
        },
    );
    steps.step(
        &format!("the user saves a change to the prompt of {Q}, then undoes it before a read-back that fails"),
        |world, c, _| {
            let brick = shell(world)?;
            let settings = wait_loaded(world)?;
            let id = action_id(&mut world.mc, &c[0])?;
            let prompt = shown_named(world, &format!("plannerActionPrompt:{id}"))?;
            let before = brick.text_of(world, prompt, "text");
            brick.write(world, prompt, "text", Value::from("My own reschedule prompt."))?;
            world.mc.hold("planner.refuseSettings");
            let reads = asked(&world.mc, "settings").len();
            save_settings(world)?;
            world.wait_for_with(
                |w| asked(&w.mc, "settings").len() > reads,
                |_| "the save to be answered".to_owned(),
            )?;
            brick.write(world, prompt, "text", Value::from(before.as_str()))?;
            world.mc.answer_held();
            world.wait_for_with(
                |w| !brick.text_of(w, settings, "problem").is_empty(),
                |_| "the read-back to fail".to_owned(),
            )
        },
    );
    steps.step(
        &format!("the prompt of {Q} is the plugin's again, left to save"),
        |world, c, _| {
            let brick = shell(world)?;
            let settings = shown_named(world, "plannerSettings")?;
            let id = action_id(&mut world.mc, &c[0])?;
            world.wait_for_with(
                |w| !brick.flag(w, settings, "saving"),
                |_| "the settings to be read back".to_owned(),
            )?;
            let saved = prompt_of(
                &property_json(world, brick, settings, "saved")["actions"],
                &id,
            );
            let shown = prompt_of(&property_json(world, brick, settings, "actions"), &id);
            expect!(
                saved == "My own reschedule prompt.",
                "the MC's prompt was read back as {saved}"
            );
            let defaults = state(&mut world.mc).default_actions.clone();
            expect!(
                shown == prompt_of(&defaults, &id),
                "the prompt reads {shown}"
            );
            expect!(
                brick.flag(world, settings, "dirty"),
                "the undo is not left to save"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the prompt of {Q} holds the second change, left to save"),
        |world, c, _| {
            let brick = shell(world)?;
            let settings = shown_named(world, "plannerSettings")?;
            let id = action_id(&mut world.mc, &c[0])?;
            // Read back, the first change is saved.
            world.wait_for_with(
                |w| {
                    prompt_of(&property_json(w, brick, settings, "saved")["actions"], &id)
                        == "My own reschedule prompt."
                },
                |_| "the settings to be read back".to_owned(),
            )?;
            let shown = prompt_of(&property_json(world, brick, settings, "actions"), &id);
            expect!(
                shown == "My second reschedule prompt.",
                "the prompt reads {shown}"
            );
            expect!(
                brick.flag(world, settings, "dirty"),
                "the second change is not left to save"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("{Q} runs its actions on the model {Q} in the project {Q}"),
        |world, c, _| {
            expect!(c[0] == ID, "only {ID} is faked");
            let settings = &mut state(&mut world.mc).settings;
            settings["provider"] = json!("claudeAgent");
            settings["model"] = json!(c[1]);
            settings["defaultProject"] = json!(c[2]);
            Ok(())
        },
    );
    steps.step(
        &format!("the planner's model reads {Q} and its default project {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            // Neither is offered: the agent has no models, and the MC has only
            // the project api.
            for (name, wanted) in [
                ("plannerSetting:model", &c[0]),
                ("plannerSetting:defaultProject", &c[1]),
            ] {
                let combo = shown_named(world, name)?;
                let shown = brick.text_of(world, combo, "displayText");
                expect!(
                    real(world, brick, combo, "currentIndex") as i64 == -1 && shown == *wanted,
                    "{name} reads {shown}"
                );
            }
            Ok(())
        },
    );

    steps.step(
        &format!(
            "the user types {Q} as the actions at once and as the minutes between looks at GitHub"
        ),
        |world, c, _| {
            for key in ["concurrency", "pollMinutes"] {
                set_text_and(world, &format!("plannerSetting:{key}"), &c[0], "textEdited")?;
            }
            Ok(())
        },
    );
    steps.step("neither setting is changed", |world, _, _| {
        let brick = shell(world)?;
        let settings = shown_named(world, "plannerSettings")?;
        let values = property_json(world, brick, settings, "values");
        expect!(
            !brick.flag(world, settings, "dirty"),
            "the settings were changed to {} at once, every {} minutes",
            text(&values["concurrency"]),
            text(&values["pollMinutes"])
        );
        Ok(())
    });
    steps.step(
        &format!("the user changes the prompt of {Q}, clears the actions at once and saves"),
        |world, c, _| {
            let brick = shell(world)?;
            wait_loaded(world)?;
            let id = action_id(&mut world.mc, &c[0])?;
            let prompt = shown_named(world, &format!("plannerActionPrompt:{id}"))?;
            brick.write(
                world,
                prompt,
                "text",
                Value::from("My own reschedule prompt."),
            )?;
            set_text_and(world, "plannerSetting:concurrency", "", "textEdited")?;
            save_settings(world)
        },
    );
    steps.step(
        &format!("nothing is saved, and the settings say {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            let wanted = format!("Not saved: {}", c[0]);
            world.wait_for_with(
                |w| text_now(w, brick, "plannerRefusal").as_deref() == Some(wanted.as_str()),
                |w| {
                    format!(
                        "the settings to say {wanted}, not {}",
                        text_now(w, brick, "plannerRefusal").unwrap_or_default()
                    )
                },
            )?;
            if let Some(sent) = saved_settings(&world.mc).first() {
                fail!("the settings were saved as {}", show(sent));
            }
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} can only be on a task, while {Q} can be on a task or the plan"),
        |world, c, _| {
            let brick = shell(world)?;
            let task_only = action_id(&mut world.mc, &c[0])?;
            let either = action_id(&mut world.mc, &c[1])?;
            shown_named(world, &format!("plannerActionScope:{either}"))?;
            expect!(
                hidden(world, brick, &format!("plannerActionScope:{task_only}")),
                "{} can be put on the plan",
                c[0]
            );
            Ok(())
        },
    );
}

fn register_slack(steps: &mut Steps) {
    steps.step(
        &format!("the MC is connected to Slack as the bot {Q}"),
        |world, _, _| {
            state(&mut world.mc).slack = true;
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} posts to the Slack channel {Q}"),
        |world, c, _| {
            expect!(c[0] == ID, "only {ID} is faked");
            state(&mut world.mc).settings["slackChannel"] = json!(c[1]);
            Ok(())
        },
    );
    steps.step("the MC is connected to Slack", |world, _, _| {
        state(&mut world.mc).slack = true;
        Ok(())
    });
    steps.step("the user opens the planner's settings", |world, _, _| {
        shell(world)?;
        let environment = world.mc.environment_id.clone();
        world.dispatch(
            "settings.navigate",
            json!({"to": format!("/settings/plugin/{environment}/{ID}")}),
        )?;
        wait_loaded(world)?;
        Ok(())
    });
    steps.step(
        &format!("{Q} has the board {Q} {Q} with the date fields {Q} and {Q}"),
        |world, c, _| {
            let number: i64 = c[1]
                .rsplit('/')
                .next()
                .and_then(|n| n.parse().ok())
                .unwrap_or(0);
            let fake = state(&mut world.mc);
            fake.boards
                .push(json!({"id": c[1], "owner": c[0], "number": number, "title": c[2]}));
            fake.date_fields.insert(c[1].clone(), json!([c[3], c[4]]));
            Ok(())
        },
    );
    steps.step(
        &format!("the user picks the board {Q} with {Q} and {Q} as its dates"),
        |world, c, _| {
            pick(world, "plannerBoard", &c[0])?;
            pick(world, "plannerDateField:startField", &c[1])?;
            pick(world, "plannerDateField:targetField", &c[2])?;
            save_settings(world)
        },
    );
    steps.step(
        &format!("{Q} follows the board {Q} with {Q} and {Q} as its dates"),
        |world, c, _| {
            expect!(c[0] == ID, "only {ID} is faked");
            let settings = &mut state(&mut world.mc).settings;
            settings["board"] = json!(c[1]);
            settings["startField"] = json!(c[2]);
            settings["targetField"] = json!(c[3]);
            Ok(())
        },
    );
    steps.step(
        "the user picks None for the board's start date",
        |world, _, _| {
            let brick = shell(world)?;
            let combo = shown_named(world, "plannerDateField:startField")?;
            world.wait_for_with(
                |w| real(w, brick, combo, "currentIndex") as i64 == 1,
                |_| "the board's date fields to be read".to_owned(),
            )?;
            expect!(
                invoke(world, combo, "activated", &[Value::Int(0)]).is_ok(),
                "None cannot be picked"
            );
            world.sync()?;
            save_settings(world)
        },
    );
    steps.step(
        &format!("beside its date fields the settings say {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            let says = |w: &World| text_now(w, brick, "plannerDateFieldsProblem");
            world.wait_for_with(
                |w| says(w).is_some_and(|said| said.contains(c[0].as_str())),
                |w| {
                    format!(
                        "the date fields to say {}, not {}",
                        c[0],
                        says(w).unwrap_or_else(|| "nothing".to_owned())
                    )
                },
            )?;
            // Not the warning of the board list, which is about other boards.
            if !hidden(world, brick, "plannerBoardProblem") {
                fail!(
                    "the board list says {}",
                    text_of(world, "plannerBoardProblem")?
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the date fields are typed in as {Q} and {Q}"),
        |world, c, _| {
            wait_hidden(world, "plannerDateField:startField")?;
            wait_hidden(world, "plannerDateField:targetField")?;
            wait_text(world, "plannerSetting:startField", &c[0])?;
            wait_text(world, "plannerSetting:targetField", &c[1])
        },
    );
    steps.step(
        "the board's date fields are picked from a list",
        |world, _, _| {
            shown_named(world, "plannerDateField:startField")?;
            shown_named(world, "plannerDateField:targetField")?;
            Ok(())
        },
    );
    steps.step("the board's date fields are typed in", |world, _, _| {
        wait_hidden(world, "plannerDateField:startField")?;
        wait_hidden(world, "plannerDateField:targetField")
    });
    steps.step("a screen reader names the settings:", |world, _, _| {
        shown_named(world, "plannerSettings")?;
        // Ljós gap: a test cannot read an item's `Accessible.name` or list an
        // item's children (ljos::item exports neither), so the names a screen
        // reader gives the settings' inputs cannot be collected.
        fail!("a test cannot read the Accessible.name of the settings' inputs on desktop-ljos")
    });
    steps.step(
        &format!("{Q} is saved with no field for its start date"),
        |world, c, _| {
            expect!(c[0] == ID, "only {ID} is faked");
            world.wait_for_with(
                |w| {
                    saved_settings(&w.mc)
                        .last()
                        .is_some_and(|sent| sent.as_object().is_some_and(|o| !o.is_empty()))
                },
                |_| "the settings to be saved".to_owned(),
            )?;
            let sent = saved_settings(&world.mc)
                .last()
                .cloned()
                .unwrap_or(Json::Null);
            // Only what changed is sent; an empty field is no mapping.
            expect!(
                sent == json!({"startField": ""}),
                "the MC was sent {}",
                show(&sent)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is saved following {Q} with {Q} and {Q} as its dates"),
        |world, c, _| {
            expect!(c[0] == ID, "only {ID} is faked");
            world.wait_for_with(
                |w| {
                    saved_settings(&w.mc)
                        .last()
                        .is_some_and(|sent| sent.as_object().is_some_and(|o| !o.is_empty()))
                },
                |_| "the settings to be saved".to_owned(),
            )?;
            let sent = saved_settings(&world.mc)
                .last()
                .cloned()
                .unwrap_or(Json::Null);
            let wanted = json!({"board": c[1], "startField": c[2], "targetField": c[3]});
            expect!(sent == wanted, "the MC was sent {}", show(&sent));
            Ok(())
        },
    );
    steps.step(
        &format!("the channels the bot is in are offered for {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            let channel = shown_named(world, "plannerSlackChannel")?;
            let offered = |w: &World| -> Vec<String> {
                (0..real(w, brick, channel, "count") as i32)
                    .map(|i| match invoke(w, channel, "textAt", &[Value::Int(i)]) {
                        Ok(Value::String(s)) => s.as_str().to_owned(),
                        _ => String::new(),
                    })
                    .collect()
            };
            world.wait_for_with(
                |w| offered(w) == ["None", "#planning", "#releases"],
                |w| format!("the channels to be offered, not {}", offered(w).join(", ")),
            )?;
            let wanted = text(&state(&mut world.mc).settings["slackChannel"]);
            expect!(
                brick.text_of(world, channel, "currentText") == wanted,
                "the planner's channel is not picked"
            );
            // The field the channels are offered in is the one named.
            let mut field = match brick.read(world, channel, "parent") {
                Value::Object(parent) => Some(parent),
                _ => None,
            };
            while let Some(each) = field {
                if draws_text(world, each, &c[0])? {
                    break;
                }
                field = match brick.read(world, each, "parent") {
                    Value::Object(parent) => Some(parent),
                    _ => None,
                };
            }
            expect!(
                match field {
                    Some(field) => !draws_text(world, field, "Announce proposals in Slack")?,
                    None => false,
                },
                "the channels are not offered for {}",
                c[0]
            );
            Ok(())
        },
    );
}

pub fn register(steps: &mut Steps) {
    register_timeline(steps);
    register_board(steps);
    register_list(steps);
    register_panel(steps);
    register_runs(steps);
    register_threads(steps);
    register_settings(steps);
    register_slack(steps);
}

/// The user runs the planner's action `label`, when the MC runs the planner:
/// false when it does not (the caller's own steps go on).
pub fn run_plugin_action(world: &mut World, label: &str) -> Outcome<bool> {
    if !is_mc_plugin(world, ID) {
        return Ok(false);
    }
    let id = action_id(&mut world.mc, label)?;
    let runs = state(&mut world.mc).runs.len();
    show_planner(world, "")?;
    let actions = shown_named(world, "plannerActions")?;
    click(world, actions)?;
    let action = shown_named(world, &format!("plannerAction:{id}"))?;
    click(world, action)?;
    wait_asked(world, "run", json!({"action": id, "itemIds": []}))?;
    world.wait_for_with(
        |w| {
            w.mc.peek::<FakePlanner>()
                .is_some_and(|fake| fake.runs.len() > runs)
        },
        |_| format!("the run of {label} to start"),
    )?;
    // The MC part starts the run's thread as it starts the run.
    let run = last_run(&mut world.mc)?;
    list_thread(world, &run)?;
    Ok(true)
}

/// The user opens the planner's view `name` on the Planner tab, when the MC
/// runs the planner and the plan has a view of that name: false when not.
pub fn open_planner_view(world: &mut World, name: &str) -> Outcome<bool> {
    if !is_mc_plugin(world, ID) {
        return Ok(false);
    }
    if !state(&mut world.mc)
        .views
        .iter()
        .any(|each| text(&each["name"]) == name)
    {
        return Ok(false);
    }
    show_planner(world, name)?;
    Ok(true)
}

#[allow(dead_code)]
fn _unused(_: &Rpc) {
    let _ = at(&Json::Null, "");
}
