//! The right panel's Agents tab (AgentsModel): the thread's subagents and
//! running commands, from the MC's `stream` shape as the MC writes them
//! (apps/server-ex delegation.ex: a `subagent` entity and its `subagent` turn
//! item). features/timeline/plans-and-subagents.feature: desktop-qt's
//! AgentsSteps.cpp.

use std::collections::HashMap;

use chrono::{DateTime, Duration, Timelike, Utc};
use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::thread_view::agents::{Agents, AgentsModel};
use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use super::stream::{FakeStreams, add_item, iso, now, set, start_run};
use crate::brick::Brick;
use crate::harness::{Failure, Outcome, Q, Steps, text};
use crate::world::World;
use crate::{expect, fail};

/// The subagents the steps started, by title, and the command running.
#[derive(Default)]
struct FakeAgents {
    ids: HashMap<String, String>,
    last: String,
    command: String,
    /// A list over the model that notes the rows it dropped (a reset since the
    /// tab opened would lose the user's scroll) and counts the redraws of
    /// the end times since the day turned over.
    views: Option<Brick>,
}

fn agents_object(world: &World) -> Outcome<ObjectId> {
    world
        .with::<RightPanel, _>(|p, _| p.agents())?
        .ok_or_else(|| Failure("the panel has no Agents tab".into()))
}

fn core<R>(world: &World, f: impl FnOnce(&Agents) -> R) -> Outcome<R> {
    let obj = agents_object(world)?;
    AgentsModel::read_core(world.engine(), obj, f)
        .ok_or_else(|| Failure("the Agents tab is busy".into()))
}

fn value(world: &World, row: usize, role: &str) -> Value {
    core(world, |a| a.value(row, role))
        .ok()
        .flatten()
        .unwrap_or(Value::Null)
}

fn describe_agents(world: &World) -> String {
    let count = core(world, Agents::count).unwrap_or(0);
    let rows: Vec<String> = (0..count)
        .map(|row| {
            let field = |role: &str| text(&value(world, row, role));
            format!(
                "{} {} {} \"{}\" {} ({}) \"{}\" \"{}\"",
                field("section"),
                field("kind"),
                field("agentId"),
                field("title"),
                field("statusLabel"),
                field("elapsed"),
                field("detail"),
                field("ended")
            )
        })
        .collect();
    let ticking = core(world, Agents::ticking).unwrap_or(false);
    format!(
        "the Agents tab lists {}{}",
        if rows.is_empty() {
            "nothing".to_owned()
        } else {
            rows.join("; ")
        },
        if ticking { ", ticking" } else { "" }
    )
}

fn row_titled(world: &World, title: &str) -> Outcome<usize> {
    let count = core(world, Agents::count)?;
    (0..count)
        .find(|row| text(&value(world, *row, "title")) == title)
        .ok_or_else(|| Failure(describe_agents(world)))
}

/// The page counting the model's resets and end-time redraws: its list over
/// `Panel.agents`, each row drawing its end time.
fn counting(world: &mut World) -> Outcome<Brick> {
    Brick::new(
        world,
        "import QtQuick\nimport HalC2.Shell\n\
         Item {\n\
           property var dropped: []\n\
           property int redraws: 0\n\
           ListView {\n\
             anchors.fill: parent\n\
             model: Panel.agents\n\
             delegate: Item {\n\
               id: row\n\
               width: 100\n\
               height: 10\n\
               required property string ended\n\
               required property string agentId\n\
               onEndedChanged: parent.parent.parent.redraws++\n\
               Component.onDestruction: parent.parent.parent.dropped.push(agentId)\n\
             }\n\
           }\n\
         }\n",
        400.0,
        600.0,
    )
}

fn dropped_rows(world: &mut World) -> Outcome<Vec<String>> {
    let Some(views) = world.mc.part::<FakeAgents>().views else {
        fail!("the Agents tab has not been opened");
    };
    let root = views
        .root(world)
        .ok_or_else(|| Failure("no counting view".into()))?;
    let dropped = views.read(world, root, "dropped");
    Ok(hal_c2_shell::json::from_value(world.engine(), &dropped)
        .as_array()
        .map(|ids| ids.iter().map(text).collect())
        .unwrap_or_default())
}

fn counted(world: &mut World, what: &str) -> Outcome<i64> {
    let Some(views) = world.mc.part::<FakeAgents>().views else {
        fail!("the Agents tab has not been opened");
    };
    let root = views
        .root(world)
        .ok_or_else(|| Failure("no counting view".into()))?;
    Ok(views.read(world, root, what).to_number() as i64)
}

/// The next local midnight the Agents tab waits for, a second past it; the
/// end times it redraws are counted from then on. The tab reads its times on
/// the world's clock, in UTC.
fn past_midnight(world: &mut World) -> Outcome<DateTime<Utc>> {
    let now = world.now();
    let midnight = (now + Duration::days(1))
        .with_hour(0)
        .and_then(|t| t.with_minute(0))
        .and_then(|t| t.with_second(0))
        .and_then(|t| t.with_nanosecond(0))
        .ok_or_else(|| Failure("no midnight".into()))?;
    let waits = core(world, Agents::next_day)?;
    expect!(
        waits == Some(midnight),
        "the end times are next redrawn at {waits:?}, not midnight; {}",
        describe_agents(world)
    );
    Ok(midnight + Duration::seconds(1))
}

/// A subagent the agent delegated `since` seconds ago, as delegation.ex
/// records it.
fn start_subagent(world: &mut World, title: &str, since: i64) -> Outcome {
    if world.mc.part::<FakeStreams>().run.is_empty() {
        start_run(world, 0, "running")?;
    }
    world.set_time(now());
    let (thread, run) = {
        let fake = world.mc.part::<FakeStreams>();
        (fake.thread.clone(), fake.run.clone())
    };
    let slug = title.to_lowercase().replace(' ', "-");
    let id = format!("task-{slug}");
    let started = iso(now() - Duration::seconds(since));
    set(
        world,
        "subagent",
        &id,
        json!({"id": id, "threadId": thread, "runId": run,
               "childThreadId": format!("thread-{slug}"),
               "prompt": format!("write the {}", title.to_lowercase()),
               "title": title, "model": "gpt-5.5", "status": "running",
               "startedAt": started, "completedAt": null, "updatedAt": started}),
    )?;
    add_item(
        world,
        "subagent",
        json!({"id": format!("turn-item:subagent:{id}"), "status": "running",
               "subagentId": id, "childThreadId": format!("thread-{slug}"),
               "startedAt": started}),
    )?;
    let agents = world.mc.part::<FakeAgents>();
    agents.ids.insert(title.to_owned(), id.clone());
    agents.last = id;
    Ok(())
}

fn settle_subagent(world: &mut World, id: &str, fields: Value) -> Outcome {
    set(world, "subagent", id, fields.clone())?;
    set(
        world,
        "turn-item",
        &format!("turn-item:subagent:{id}"),
        fields,
    )
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("the agent started the subagents {Q} and {Q}"),
        |world, c, _| {
            start_subagent(world, &c[0], 90)?;
            start_subagent(world, &c[1], 80)
        },
    );
    steps.step(
        &format!("the agent started the subagent {Q} (\\d+) seconds ago"),
        |world, c, _| start_subagent(world, &c[0], c[1].parse().unwrap_or(0)),
    );
    steps.step(
        &format!("{Q} finished (\\d+) seconds after it started"),
        |world, c, _| {
            let id = world
                .mc
                .part::<FakeAgents>()
                .ids
                .get(&c[0])
                .cloned()
                .unwrap_or_default();
            let started = world
                .mc
                .part::<FakeStreams>()
                .threads
                .get(super::stream::THREAD)
                .and_then(|entities| entities.get(&format!("subagent\n{id}")))
                .map(|entity| text(&entity["startedAt"]))
                .unwrap_or_default();
            let Ok(started) = DateTime::parse_from_rfc3339(&started) else {
                fail!("{} did not start: {started:?}", c[0]);
            };
            let after = started.with_timezone(&Utc) + Duration::seconds(c[1].parse().unwrap_or(0));
            settle_subagent(
                world,
                &id,
                json!({"status": "completed", "completedAt": iso(after)}),
            )
        },
    );
    steps.step(&format!("the subagent finishes with {Q}"), |world, c, _| {
        let id = world.mc.part::<FakeAgents>().last.clone();
        settle_subagent(
            world,
            &id,
            json!({"status": "completed", "result": c[0], "completedAt": iso(now())}),
        )
    });

    steps.step(
        &format!("the agent is running the command {Q}"),
        |world, c, _| {
            start_run(world, 0, "running")?;
            let command = add_item(
                world,
                "command_execution",
                json!({"input": c[0], "status": "running", "startedAt": iso(now())}),
            )?;
            world.mc.part::<FakeAgents>().command = command;
            Ok(())
        },
    );
    steps.step("the command finishes", |world, _, _| {
        let command = world.mc.part::<FakeAgents>().command.clone();
        set(
            world,
            "turn-item",
            &command,
            json!({"status": "completed", "exitCode": 0}),
        )
    });

    steps.step("the user opens the Agents tab", |world, _, _| {
        world.dispatch("rightPanel.add", json!({"kind": "agents"}))?;
        world.sync()?;
        expect!(
            text(&world.state("panel")["activeId"]) == "agents",
            "the Agents tab is not shown"
        );
        let views = counting(world)?;
        world.mc.part::<FakeAgents>().views = Some(views);
        world.sync()
    });
    steps.step("the user switches to the Diff tab", |world, _, _| {
        world.dispatch("rightPanel.add", json!({"kind": "diff"}))?;
        world.sync()
    });

    steps.step(
        &format!("the Agents tab lists {Q} as {Q} and {Q} as {Q}"),
        |world, c, _| {
            let first = row_titled(world, &c[0])?;
            let second = row_titled(world, &c[2])?;
            expect!(
                first < second
                    && text(&value(world, first, "statusLabel")) == c[1]
                    && text(&value(world, second, "statusLabel")) == c[3],
                "{}",
                describe_agents(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the Agents tab lists {Q} as {Q} with {Q}"),
        |world, c, _| {
            let row = row_titled(world, &c[0])?;
            expect!(
                text(&value(world, row, "statusLabel")) == c[1]
                    && text(&value(world, row, "detail")) == c[2],
                "{}",
                describe_agents(world)
            );
            Ok(())
        },
    );
    steps.step("the Agents tab lists, in order:", |world, _, table| {
        let count = core(world, Agents::count)?;
        let mut same = count == table.len();
        for (row, wanted) in table.iter().enumerate() {
            if !same {
                break;
            }
            same = text(&value(world, row, "title")) == wanted[0]
                && text(&value(world, row, "section")) == wanted[1].to_lowercase();
        }
        expect!(same, "{}", describe_agents(world));
        Ok(())
    });
    steps.step(&format!("{Q} is shown to have ended {Q}"), |world, c, _| {
        let row = row_titled(world, &c[0])?;
        let ended = text(&value(world, row, "ended"));
        expect!(ended == c[1], "{}", describe_agents(world));
        Ok(())
    });
    steps.step(
        "the Agents tab never started its list over",
        |world, _, _| {
            // A reset draws every row anew: a row dropped that the list still
            // holds. (A row that left, such as a command that finished, is
            // dropped too.)
            let dropped = dropped_rows(world)?;
            let count = core(world, Agents::count)?;
            let kept: Vec<String> = (0..count)
                .map(|row| text(&value(world, row, "agentId")))
                .filter(|id| dropped.contains(id))
                .collect();
            expect!(
                kept.is_empty(),
                "the list started over, drawing {} anew; {}",
                kept.join(", "),
                describe_agents(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is shown to have taken {Q}"), |world, c, _| {
        let row = row_titled(world, &c[0])?;
        expect!(
            text(&value(world, row, "elapsed")) == c[1],
            "{}",
            describe_agents(world)
        );
        Ok(())
    });
    steps.step("a second passes", |world, _, _| {
        // The model's own once-a-second timer, without waiting a second for it.
        expect!(core(world, Agents::ticking)?, "{}", describe_agents(world));
        let next = world.now() + Duration::seconds(1);
        world.set_time(next);
        let obj = agents_object(world)?;
        AgentsModel::tick(world.engine(), obj);
        Ok(())
    });
    steps.step("the day turns over", |world, _, _| {
        // The model's own midnight timer, without waiting for midnight.
        let next = past_midnight(world)?;
        world.set_time(next);
        let obj = agents_object(world)?;
        AgentsModel::redraw_ended(world.engine(), obj);
        world.sync()
    });
    steps.step(
        "the day turns over while the desktop sleeps",
        |world, _, _| {
            // Midnight passed, and the midnight timer has yet to fire.
            let next = past_midnight(world)?;
            world.set_time(next);
            world.sync()
        },
    );
    steps.step(
        "the Agents tab redraws when each subagent ended",
        |world, _, _| {
            expect!(counted(world, "redraws")? > 0, "{}", describe_agents(world));
            Ok(())
        },
    );
    steps.step("the Agents tab's times stand still", |world, _, _| {
        expect!(!core(world, Agents::ticking)?, "{}", describe_agents(world));
        Ok(())
    });
    steps.step(
        &format!("the Agents tab lists the running command {Q}"),
        |world, c, _| {
            let row = row_titled(world, &c[0])?;
            expect!(
                text(&value(world, row, "kind")) == "command"
                    && value(world, row, "running") == json!(true),
                "{}",
                describe_agents(world)
            );
            Ok(())
        },
    );
    steps.step("the Agents tab lists no running command", |world, _, _| {
        let count = core(world, Agents::count)?;
        for row in 0..count {
            expect!(
                text(&value(world, row, "kind")) != "command",
                "{}",
                describe_agents(world)
            );
        }
        Ok(())
    });

    steps.step(
        &format!("the user opens {Q} from the Agents tab"),
        |world, c, _| {
            let row = row_titled(world, &c[0])?;
            let child = text(&value(world, row, "childThreadKey"));
            world.dispatch("rightPanel.openThread", json!({"threadKey": child}))?;
            world.sync()
        },
    );
    steps.step("the subagent's thread is shown", |world, _, _| {
        let shown = world.with::<Navigation, _>(|n, _| n.thread_key().to_owned())?;
        let last = world.mc.part::<FakeAgents>().last.clone();
        let child = format!(
            "{}:thread-{}",
            world.mc.environment_id,
            last.strip_prefix("task-").unwrap_or(&last)
        );
        expect!(
            shown == child,
            "the route shows \"{shown}\", not \"{child}\""
        );
        Ok(())
    });
}
