//! Settings → Review sandboxes (the shell's `sandboxSettings`,
//! SandboxSettings.qml): the @shared Settings scenarios of
//! features/mc/platform/openshell.feature, against an MC whose
//! `server.getOpenShellStatus` this file fakes from what the scenario says
//! about the machine. desktop-qt's SandboxSettingsSteps.cpp.

use serde_json::{Value, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Steps, show};
use crate::world::World;
use crate::{expect, fail};

const PINNED: &str = "0.1.7";
const INTEL_MAC: &str = "OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta.";
const NOT_INSTALLED: &str = "Run `hal-c2-service openshell install` to install it.";
const FAILURE: &str = "OpenShell's status did not answer within 20 seconds. Try again, or run `hal-c2-service openshell status` on the MC's machine.";

/// What the MC's machine is, as the scenario says.
#[derive(Default)]
struct FakeOpenShell {
    intel_mac: bool,
    /// The user runs a gateway,
    gateway: bool,
    /// and pointed the MC at it.
    pointed: bool,
    failing: bool,
}

fn status(machine: &FakeOpenShell) -> Value {
    let problem = |code: &str, message: &str| json!([{"code": code, "message": message}]);
    let ready = !machine.intel_mac && machine.gateway && machine.pointed;
    json!({
        "supported": !machine.intel_mac,
        "ready": ready,
        "mode": if ready { json!("external") } else { Value::Null },
        "version": if ready { json!(PINNED) } else { Value::Null },
        "pinnedVersion": PINNED,
        "problems": if machine.intel_mac {
            problem("intel-mac", INTEL_MAC)
        } else if ready {
            json!([])
        } else {
            problem("not-installed", NOT_INSTALLED)
        },
    })
}

fn section(world: &World) -> Value {
    world.state("sandboxSettings")
}

/// Waits for the read the page asked for to land.
fn landed(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| section(w)["loading"] == json!(false),
        |w| {
            format!(
                "the sandbox status to land; the section is {}",
                show(&section(w))
            )
        },
    )
}

fn page(world: &World) -> Outcome<Brick> {
    match world.peek_part::<Shown>().and_then(|s| s.0) {
        Some(brick) => Ok(brick),
        None => fail!("the sandbox settings are not open"),
    }
}

fn text(world: &mut World, object_name: &str) -> Outcome<String> {
    let brick = page(world)?;
    let item = brick.item(world, object_name)?;
    Ok(brick.text_of(world, item, "text"))
}

fn expect_summary(world: &mut World, summary: &str) -> Outcome {
    let shown = text(world, "sandboxSummary")?;
    expect!(
        shown == summary,
        "the page says \"{shown}\", not \"{summary}\""
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.extension(|mc| {
        mc.on_rpc("server.getOpenShellStatus", |mc, rpc| {
            if mc.part::<FakeOpenShell>().failing {
                mc.refuse_with(rpc, FAILURE, json!({"_tag": "ServerOpenShellStatusError"}));
            } else {
                let answer = status(mc.part::<FakeOpenShell>());
                mc.reply(rpc, answer);
            }
            Ok(())
        });
    });

    steps.step("a Linux machine with rootless Podman", |_, _, _| Ok(()));
    steps.step("a machine that is an Intel Mac", |world, _, _| {
        world.mc.part::<FakeOpenShell>().intel_mac = true;
        Ok(())
    });
    steps.step(
        "a gateway the user runs, with its CA and a client certificate",
        |world, _, _| {
            world.mc.part::<FakeOpenShell>().gateway = true;
            Ok(())
        },
    );
    steps.step("the user points the MC at it", |world, _, _| {
        world.mc.part::<FakeOpenShell>().pointed = true;
        Ok(())
    });
    steps.step(
        "the MC cannot say whether review sandboxes can run",
        |world, _, _| {
            world.mc.part::<FakeOpenShell>().failing = true;
            Ok(())
        },
    );

    steps.step("the user opens the sandbox settings", |world, _, _| {
        if world.shell_subscriptions() == 0 {
            world.connect()?;
            world.sync()?;
        }
        world.dispatch("settings.open", json!({}))?;
        world.dispatch("settings.navigate", json!({"to": "/settings/sandboxes"}))?;
        landed(world)?;
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nSandboxSettings {}\n",
            900.0,
            700.0,
        )
    });
    steps.step(
        "the MC can say again and the user refreshes the sandbox settings",
        |world, _, _| {
            world.mc.part::<FakeOpenShell>().failing = false;
            let brick = page(world)?;
            brick.click(world, "sandboxRefresh")?;
            landed(world)
        },
    );

    steps.step(
        "they read that OpenShell does not run on an Intel Mac",
        |world, _, _| {
            expect_summary(world, "Review sandboxes can't run on this machine.")?;
            let why = text(world, "sandboxProblem:intel-mac")?;
            expect!(why == INTEL_MAC, "the page does not say why");
            Ok(())
        },
    );
    steps.step(
        "they read that OpenShell is not installed, and how to install it",
        |world, _, _| {
            expect_summary(world, "Review sandboxes can't run here yet.")?;
            let how = text(world, "sandboxProblem:not-installed")?;
            expect!(
                how == NOT_INSTALLED,
                "the page does not say how to install it"
            );
            let detail = text(world, "sandboxDetail")?;
            expect!(
                detail.contains(PINNED),
                "the page does not name the version the MC pins"
            );
            Ok(())
        },
    );
    steps.step(
        "they read that review sandboxes can run here",
        |world, _, _| {
            expect_summary(world, "Review sandboxes can run here.")?;
            let detail = text(world, "sandboxDetail")?;
            expect!(
                detail == format!("OpenShell {PINNED}, a gateway you run."),
                "the detail is \"{detail}\""
            );
            let brick = page(world)?;
            expect!(
                brick.find(world, "sandboxProblem:not-installed")?.is_none(),
                "the page still lists a problem"
            );
            Ok(())
        },
    );
    steps.step(
        "they read that the sandbox status could not be read",
        |world, _, _| {
            expect_summary(
                world,
                "Could not read whether review sandboxes can run here.",
            )?;
            let detail = text(world, "sandboxDetail")?;
            expect!(detail == FAILURE, "the page does not say what the MC said");
            let brick = page(world)?;
            let refresh = brick.item(world, "sandboxRefresh")?;
            expect!(
                brick.flag(world, refresh, "enabled"),
                "the user cannot ask again"
            );
            Ok(())
        },
    );
}
