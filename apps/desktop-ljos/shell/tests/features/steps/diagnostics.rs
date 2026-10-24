//! The native Diagnostics settings page: the @desktop and @shared scenarios
//! of features/settings/diagnostics.feature, against an MC whose `server.*`
//! diagnostics calls this file fakes. desktop-qt's DiagnosticsSteps.cpp.

use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::settings::{fake_config, send_config};
use crate::world::World;
use crate::{expect, fail};
use hal_c2_shell::controllers::settings::Settings;

const LOGS: &str = "/home/user/.local/state/hal-c2/elixir/logs";
const AGENT_PID: i64 = 4102;

#[derive(Default)]
struct FakeDiagnostics {
    /// Every server.signalProcess payload.
    signals: Vec<Value>,
    /// Every shell.openInEditor payload.
    editor_calls: Vec<Value>,
}

/// A provider session and a terminal under the MC.
fn processes() -> Value {
    let process = |pid: i64, ppid: i64, command: &str, depth: i64| {
        json!({
            "pid": pid, "ppid": ppid, "pgid": pid, "status": "S",
            "cpuPercent": 2.5, "rssBytes": 52428800, "elapsed": "00:42",
            "startTimeMs": 1767225600000_i64 + pid, "command": command,
            "depth": depth, "childPids": [],
        })
    };
    json!({
        "serverPid": 4000,
        "readAt": "2026-01-01T00:00:00.000Z",
        "processCount": 4,
        "totalRssBytes": 104857600,
        "totalCpuPercent": 5.0,
        "processes": [
            process(AGENT_PID, 4000, "codex app-server", 0),
            process(4210, 4000, "/bin/zsh -l", 0),
            // What the shell runs, and a helper of the MC's own.
            process(4211, 4210, "bun dev", 1),
            process(4300, 4000, "epmd -daemon", 0),
        ],
    })
}

fn extend(mc: &mut FakeMc) {
    mc.on_rpc("server.getProcessDiagnostics", |mc, rpc| {
        mc.reply(rpc, processes());
        Ok(())
    });
    mc.on_rpc("server.getProcessResourceHistory", |mc, rpc| {
        mc.reply(
            rpc,
            json!({
                "windowMs": rpc.payload["windowMs"], "sampleIntervalMs": 5000,
                "retainedSampleCount": 0, "totalCpuSecondsApprox": 0,
                "topProcesses": [], "buckets": [],
            }),
        );
        Ok(())
    });
    mc.on_rpc("server.getTraceDiagnostics", |mc, rpc| {
        mc.reply(
            rpc,
            json!({"recordCount": 0, "failureCount": 0, "slowSpanCount": 0, "parseErrorCount": 0}),
        );
        Ok(())
    });
    mc.on_rpc("server.signalProcess", |mc, rpc| {
        mc.part::<FakeDiagnostics>().signals.push(rpc.payload.clone());
        mc.reply(
            rpc,
            json!({"pid": rpc.payload["pid"], "signal": rpc.payload["signal"], "signaled": true}),
        );
        Ok(())
    });
}

fn fake(world: &mut World) -> &mut FakeDiagnostics {
    world.mc.part::<FakeDiagnostics>()
}

fn diagnostics(world: &World) -> Value {
    world.state("diagnostics")
}

fn open(world: &mut World) -> Outcome {
    world.dispatch("settings.open", json!({}))?;
    world.dispatch("settings.navigate", json!({"to": "/settings/diagnostics"}))?;
    world.wait_for_with(
        |w| {
            at(&diagnostics(w), "processes.rows")
                .as_array()
                .is_some_and(|rows| !rows.is_empty())
        },
        |w| {
            format!(
                "the processes to be listed; diagnostics are {}",
                show(&diagnostics(w))
            )
        },
    )
}

fn ensure_connected(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    Ok(())
}

/// The MC's config as it announces a change, with `editors` as its editors.
fn set_editors(world: &mut World, editors: Value) -> Outcome {
    let config = fake_config(&mut world.mc);
    config.config.insert("availableEditors".into(), editors);
    let mut frame = config.config.clone();
    frame.insert("settings".into(), Value::Object(config.settings.clone()));
    let environment = world.mc.environment_id.clone();
    send_config(
        &world.mc,
        &environment,
        json!({"t": "config", "config": frame}),
    );
    world.sync()
}

/// Whether the process `pid` has a visible row on the page.
fn listed(world: &mut World, brick: Brick, pid: i64) -> Outcome<bool> {
    world.pump()?;
    let name = format!("process:{pid}");
    Ok(brick
        .find_visible(world, &name)?
        .is_some())
}

fn fold_of(world: &mut World, brick: Brick, id: &str) -> Outcome<ObjectId> {
    world.pump()?;
    let Some(group) = brick.find(world, &format!("processGroup:{id}"))? else {
        fail!("the page has no {id} group");
    };
    match brick.find_under(world, group, "fold")? {
        Some(fold) => Ok(fold),
        None => fail!("the {id} group cannot be folded"),
    }
}

fn click_item(world: &mut World, brick: Brick, item: ObjectId) -> Outcome {
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)
}

pub fn register(steps: &mut Steps) {
    steps.extension(extend);

    // Process groups (settings/resource-telemetry.feature).
    steps.step("the user watches the resource monitor", |world, _, _| {
        ensure_connected(world)?;
        open(world)?;
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nDiagnosticsSettings {}\n",
            900.0,
            1400.0,
        )
    });
    steps.step(
        "processes are grouped as server, provider and terminal",
        |world, _, _| {
            let mut shown = Vec::new();
            for group in at(&diagnostics(world), "processes.groups")
                .as_array()
                .cloned()
                .unwrap_or_default()
            {
                let names: Vec<String> = at(&group, "rows")
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .iter()
                    .map(|row| text(at(row, "name")))
                    .collect();
                shown.push(format!("{}: {}", text(at(&group, "label")), names.join(", ")));
            }
            // A shell's child goes with its terminal.
            expect!(
                shown == ["Server: epmd", "Provider: codex", "Terminal: zsh, bun"],
                "the groups are {}",
                shown.join("; ")
            );
            let brick = crate::brick::shown(world)?;
            world.pump()?;
            for id in ["server", "provider", "terminal"] {
                let group = brick.find(world, &format!("processGroup:{id}"))?;
                let visible = group.is_some_and(|g| brick.flag(world, g, "visible"));
                expect!(visible, "the page has no {id} group");
            }
            Ok(())
        },
    );
    steps.step(
        "each group can be collapsed and expanded again",
        |world, _, _| {
            let brick = crate::brick::shown(world)?;
            let first = [("server", 4300), ("provider", AGENT_PID), ("terminal", 4210)];
            for (id, pid) in first {
                expect!(listed(world, brick, pid)?, "{pid} is not listed");
                let fold = fold_of(world, brick, id)?;
                click_item(world, brick, fold)?;
                expect!(!listed(world, brick, pid)?, "the {id} group did not collapse");
                // The others stay open.
                for (other, other_pid) in first {
                    if other != id {
                        expect!(
                            listed(world, brick, other_pid)?,
                            "{other_pid} went with the {id} group"
                        );
                    }
                }
                let fold = fold_of(world, brick, id)?;
                click_item(world, brick, fold)?;
                expect!(listed(world, brick, pid)?, "the {id} group did not expand");
            }
            Ok(())
        },
    );

    steps.step(
        "an MC running a provider session and a terminal",
        |world, _, _| {
            let config = fake_config(&mut world.mc);
            config
                .config
                .insert("availableEditors".into(), json!(["zed", "cursor"]));
            config
                .config
                .insert("observability".into(), json!({"logsDirectoryPath": LOGS}));
            // Over the workspace's fake: this page's calls are this file's to read.
            world.mc.on_rpc("shell.openInEditor", |mc, rpc| {
                mc.part::<FakeDiagnostics>()
                    .editor_calls
                    .push(rpc.payload.clone());
                mc.reply(rpc, Value::Null);
                Ok(())
            });
            world.connect()?;
            world.sync()
        },
    );

    steps.step("the user force kills a process", |world, _, _| {
        open(world)?;
        world.dispatch(
            "diagnostics.signal",
            json!({"pid": AGENT_PID, "signal": "SIGKILL"}),
        )?;
        world.sync()
    });
    steps.step(
        "the user is asked to confirm because the process cannot handle it",
        |world, _, _| {
            let question = world.state("confirmation");
            expect!(
                text(at(&question, "title"))
                    == format!(
                        "Send SIGKILL to process {AGENT_PID}? This cannot be handled by the process."
                    ),
                "the question is {}",
                show(&question)
            );
            expect!(
                fake(world).signals.is_empty(),
                "the signal went before the user answered"
            );
            Ok(())
        },
    );
    steps.step("cancelling leaves the process running", |world, _, _| {
        let question = world.state("confirmation");
        world.dispatch(
            "confirmation.answer",
            json!({"requestId": at(&question, "requestId"), "accepted": false}),
        )?;
        world.sync()?;
        let sent = fake(world).signals.len();
        expect!(sent == 0, "{sent} signals were sent");
        expect!(world.state("confirmation").is_null(), "the question stays");
        Ok(())
    });

    steps.step("the user opens the logs folder", |world, _, _| {
        // The user last opened something in Cursor.
        let engine = world.engine().clone();
        Settings::of(&engine).write_device(&engine, "lastEditor", json!("cursor"));
        open(world)?;
        world.dispatch("diagnostics.openLogs", json!({}))?;
        world.sync()
    });
    steps.step(
        "it opens in the user's preferred editor",
        |world, _, _| {
            world.wait_for("the logs folder to open", |w| {
                w.mc.peek::<FakeDiagnostics>()
                    .is_some_and(|f| !f.editor_calls.is_empty())
            })?;
            let call = fake(world).editor_calls.last().cloned().unwrap_or_default();
            expect!(
                call == json!({"cwd": LOGS, "editor": "cursor"}),
                "the MC was asked for {}",
                show(&call)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("if no editor is available the user is told {Q}"),
        |world, c, _| {
            set_editors(world, json!([]))?;
            fake(world).editor_calls.clear();
            world.dispatch("diagnostics.openLogs", json!({}))?;
            world.sync()?;
            let error = at(&diagnostics(world), "logs.error").clone();
            expect!(text(&error) == c[0], "the user is told {}", show(&error));
            expect!(
                fake(world).editor_calls.is_empty(),
                "an editor was asked anyway"
            );
            Ok(())
        },
    );
}
