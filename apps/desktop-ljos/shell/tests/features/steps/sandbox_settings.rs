//! Settings → Review sandboxes (the shell's `sandboxSettings`,
//! SandboxSettings.qml): the @shared Settings scenarios of
//! features/mc/platform/openshell.feature, against an MC whose
//! `server.getOpenShellStatus`, `server.runOpenShellOperation` and
//! openShell shape this file fakes from what the scenario says about the
//! machine. desktop-qt's SandboxSettingsSteps.cpp.

use serde_json::{Value, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Steps, show};
use crate::world::World;
use crate::{expect, fail};

const PINNED: &str = "0.1.7";
const INTEL_MAC: &str = "OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta.";
const NO_MACHINE: &str = "Code reviews that need a sandbox fail here until this machine or another of your cluster can run them.";
const NOT_INSTALLED: &str = "Press Install to install it.";
const NO_PODMAN: &str = "No rootless Podman socket. Install Podman 5 or later with your distribution's package manager, then press Install: it starts Podman's socket for you.";
const FAILURE: &str = "OpenShell's status did not answer within 20 seconds. Refresh to try again.";
const INSTALL_STEPS: [&str; 3] = [
    "Checking this machine",
    "Checking the gateway's configuration",
    "Starting the gateway",
];
const INSTALLED: &str = "OpenShell installed, 0.1.7, listening on https://127.0.0.1:17670.";
const REMOVED: &str = "OpenShell removed.";
const MANAGE_REASON: &str = "Installing and managing OpenShell needs a session that can manage this machine and use its terminal (access:write, terminal:operate). Pair this device with a link that grants them.";

/// What the MC's machine is, as the scenario says.
struct FakeOpenShell {
    intel_mac: bool,
    no_podman: bool,
    /// The user runs a gateway,
    gateway: bool,
    /// and pointed the MC at it.
    pointed: bool,
    failing: bool,
    /// The cluster's machines that can run review sandboxes.
    sandbox_machines: Vec<String>,
    /// A gateway this MC installed and runs.
    managed: bool,
    /// This MC's review sandboxes on it.
    reviews: i64,
    /// Paired without access:write and terminal:operate.
    cannot_manage: bool,
    /// The openShell shape's state: the operation running or last run.
    operation: Value,
    /// Each server.runOpenShellOperation's payload.
    runs: Vec<Value>,
}

impl Default for FakeOpenShell {
    fn default() -> Self {
        Self {
            intel_mac: false,
            no_podman: false,
            gateway: false,
            pointed: false,
            failing: false,
            sandbox_machines: Vec::new(),
            managed: false,
            reviews: 0,
            cannot_manage: false,
            operation: json!({"operation": null, "run": 0, "running": false,
                               "steps": [], "result": null}),
            runs: Vec::new(),
        }
    }
}

fn action(operation: &str, label: &str) -> Value {
    json!({"operation": operation, "label": label})
}

fn status(machine: &FakeOpenShell) -> Value {
    let problem = |code: &str, message: &str| json!([{"code": code, "message": message}]);
    let external = !machine.intel_mac && machine.gateway && machine.pointed;
    let ready = machine.managed || external;
    let actions = if machine.intel_mac {
        json!([])
    } else if machine.managed {
        json!([
            action("check", "Check"),
            action("rotate", "Rotate certificates"),
            action("uninstall", "Uninstall")
        ])
    } else if external {
        json!([
            action("check", "Check"),
            action("uninstall", "Stop using it")
        ])
    } else {
        json!([action("install", "Install")])
    };
    let mut answer = json!({
        "supported": !machine.intel_mac,
        "ready": ready,
        "mode": if machine.managed {
            json!("managed")
        } else if external {
            json!("external")
        } else {
            Value::Null
        },
        "actions": actions,
        "canManage": !machine.cannot_manage,
        "manageReason": if machine.cannot_manage {
            json!(MANAGE_REASON)
        } else {
            Value::Null
        },
        "version": if ready { json!(PINNED) } else { Value::Null },
        "pinnedVersion": PINNED,
        "sandboxMachines": machine.sandbox_machines,
        "problems": if machine.intel_mac {
            problem("intel-mac", INTEL_MAC)
        } else if ready {
            json!([])
        } else {
            problem("not-installed", NOT_INSTALLED)
        },
    });
    // Like the MC: no Podman is a platform problem, and Install starts its
    // socket once it is there.
    if machine.no_podman {
        answer["supported"] = json!(false);
        answer["problems"] = problem("podman-missing", NO_PODMAN);
    }
    answer
}

fn result(ok: bool, code: Value, message: &str, sandboxes: Value, drain: Value) -> Value {
    json!({"ok": ok, "code": code, "message": message,
           "sandboxes": sandboxes, "drain": drain})
}

/// This MC's reviews on the gateway, by the names the MC gives them.
fn review_names(count: i64) -> Value {
    Value::Array(
        (1..=count)
            .map(|at| json!(format!("review-{at}")))
            .collect(),
    )
}

/// Like the MC, a drain deletes only when it names every review there is.
fn drains_all(payload: &Value, count: i64) -> bool {
    let drain = payload["drain"].as_array().cloned().unwrap_or_default();
    (1..=count).all(|at| drain.contains(&json!(format!("review-{at}"))))
}

/// The operation's new state, to everyone following the openShell shape.
fn emit_operation(mc: &mut crate::fake_mc::FakeMc, operation: &Value) {
    mc.part::<FakeOpenShell>().operation = operation.clone();
    for id in mc.subscribers("openShell") {
        mc.send(&json!({"t": "openShell", "id": id, "operation": operation}));
    }
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

fn operation(world: &World) -> Value {
    section(world)["operation"].clone()
}

/// Waits for the operation to end and the status read after it to land.
fn settled(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| {
            let now = operation(w);
            now.is_object()
                && now["running"] != json!(true)
                && section(w)["loading"] == json!(false)
        },
        |w| {
            format!(
                "the operation to end and the status to land; the section is {}",
                show(&section(w))
            )
        },
    )
}

fn expect_text(world: &mut World, object_name: &str, expected: &str) -> Outcome {
    let shown = text(world, object_name)?;
    expect!(
        shown == expected,
        "{object_name} says \"{shown}\", not \"{expected}\""
    );
    Ok(())
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
        mc.on_shape("openShell", |mc, id, _| {
            let operation = mc.part::<FakeOpenShell>().operation.clone();
            mc.send(&json!({"t": "openShell", "id": id, "operation": operation}));
            Ok(())
        });
        // Like the MC, the reply is the operation running, numbered; its
        // steps and outcome go to whoever follows the openShell shape.
        mc.on_rpc("server.runOpenShellOperation", |mc, rpc| {
            mc.part::<FakeOpenShell>().runs.push(rpc.payload.clone());
            if mc.part::<FakeOpenShell>().cannot_manage {
                mc.refuse(rpc, "This session may not access:write.");
                return Ok(());
            }
            let operation = crate::harness::text(&rpc.payload["operation"]);
            let run = mc.part::<FakeOpenShell>().runs.len() as i64;
            let running = json!({"operation": operation, "run": run, "running": true,
                                 "steps": [], "result": null});
            mc.reply(rpc, running.clone());
            emit_operation(mc, &running);
            let finish = |mc: &mut crate::fake_mc::FakeMc, steps: Vec<Value>, outcome: Value| {
                let mut done = running.clone();
                done["running"] = json!(false);
                done["steps"] = Value::Array(steps);
                done["result"] = outcome;
                emit_operation(mc, &done);
            };
            if operation == "install" {
                for at in 1..=INSTALL_STEPS.len() {
                    let mut step = running.clone();
                    step["steps"] = Value::Array(
                        INSTALL_STEPS[..at].iter().map(|s| json!(s)).collect(),
                    );
                    emit_operation(mc, &step);
                }
                mc.part::<FakeOpenShell>().managed = true;
                finish(
                    mc,
                    INSTALL_STEPS.iter().map(|s| json!(s)).collect(),
                    result(true, Value::Null, INSTALLED, Value::Null, Value::Null),
                );
            } else if operation == "uninstall" {
                let reviews = mc.part::<FakeOpenShell>().reviews;
                if reviews > 0 && !drains_all(&rpc.payload, reviews) {
                    // A drain that does not name them all was confirmed
                    // before others started.
                    let confirmed = rpc.payload.get("drain").is_some();
                    let message = format!(
                        "{}{}",
                        if confirmed {
                            "The running reviews changed since you confirmed. "
                        } else {
                            ""
                        },
                        if reviews == 1 {
                            "1 of this MC's review sandboxes is on the gateway. Going ahead deletes it, which stops its review; or let it finish first.".to_owned()
                        } else {
                            format!("{reviews} of this MC's review sandboxes are on the gateway. Going ahead deletes them, which stops their reviews; or let them finish first.")
                        }
                    );
                    finish(
                        mc,
                        Vec::new(),
                        result(
                            false,
                            json!(if confirmed {
                                "sandboxes-changed"
                            } else {
                                "sandboxes-running"
                            }),
                            &message,
                            json!(reviews),
                            review_names(reviews),
                        ),
                    );
                } else {
                    let machine = mc.part::<FakeOpenShell>();
                    machine.reviews = 0;
                    machine.managed = false;
                    finish(
                        mc,
                        vec![json!("Removing the gateway")],
                        result(true, Value::Null, REMOVED, Value::Null, Value::Null),
                    );
                }
            } else {
                finish(
                    mc,
                    Vec::new(),
                    result(
                        true,
                        Value::Null,
                        "OpenShell passed its checks.",
                        Value::Null,
                        Value::Null,
                    ),
                );
            }
            Ok(())
        });
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
    steps.step("a machine that has no Podman", |world, _, _| {
        world.mc.part::<FakeOpenShell>().no_podman = true;
        Ok(())
    });
    steps.step(
        "a machine that is an Intel Mac, in a cluster with \"([^\"]+)\", which can run review sandboxes",
        |world, c, _| {
            let machine = world.mc.part::<FakeOpenShell>();
            machine.intel_mac = true;
            machine.sandbox_machines = vec![c[0].clone()];
            Ok(())
        },
    );
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
        "they read that code reviews that need a sandbox go to \"([^\"]+)\"",
        |world, c, _| {
            let detail = text(world, "sandboxDetail")?;
            let expected = format!("Code reviews that need a sandbox go to {}.", c[0]);
            expect!(detail == expected, "the detail is \"{detail}\"");
            Ok(())
        },
    );
    steps.step(
        "they read that code reviews that need a sandbox fail until a machine of the cluster can run them",
        |world, _, _| {
            let detail = text(world, "sandboxDetail")?;
            expect!(
                detail == NO_MACHINE,
                "the detail is \"{detail}\""
            );
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
    steps.step(
        "they read that Podman must be installed first, and that Install starts its socket",
        |world, _, _| {
            expect_text(world, "sandboxProblem:podman-missing", NO_PODMAN)?;
            let brick = page(world)?;
            let install = brick.find(world, "sandboxAction:install")?;
            expect!(
                install.is_some_and(|item| brick.flag(world, item, "enabled")),
                "the page does not offer Install"
            );
            Ok(())
        },
    );

    steps.step(
        "an OpenShell gateway this MC runs, with a sandbox of this MC's and one of someone else's",
        |world, _, _| {
            let machine = world.mc.part::<FakeOpenShell>();
            machine.managed = true;
            // Someone else's sandbox is the MC's to leave alone; only this
            // MC's are counted.
            machine.reviews = 1;
            Ok(())
        },
    );
    steps.step(
        "the user's device was paired without the right to manage the MC's machine",
        |world, _, _| {
            world.mc.part::<FakeOpenShell>().cannot_manage = true;
            Ok(())
        },
    );

    steps.step(
        &format!("they press {} in the sandbox settings", crate::harness::Q),
        |world, c, _| {
            let mut operation = String::new();
            for value in section(world)["actions"].as_array().into_iter().flatten() {
                if crate::harness::text(&value["label"]) == c[0] {
                    operation = crate::harness::text(&value["operation"]);
                }
            }
            expect!(
                !operation.is_empty(),
                "the page offers no \"{}\"; the section is {}",
                c[0],
                show(&section(world))
            );
            let brick = page(world)?;
            brick.click(world, &format!("sandboxAction:{operation}"))?;
            settled(world)
        },
    );

    steps.step(
        "the sandbox settings show the install's steps",
        |world, _, _| {
            for (at, step) in INSTALL_STEPS.iter().enumerate() {
                expect_text(world, &format!("sandboxStep:{at}"), step)?;
            }
            Ok(())
        },
    );
    steps.step("they read that OpenShell was installed", |world, _, _| {
        expect_text(world, "sandboxResult", INSTALLED)?;
        expect_summary(world, "Review sandboxes can run here.")?;
        expect_text(
            world,
            "sandboxDetail",
            &format!("OpenShell {PINNED}, run by this MC."),
        )
    });
    steps.step(
        "the sandbox settings offer to uninstall it",
        |world, _, _| {
            let brick = page(world)?;
            for operation in ["check", "rotate", "uninstall"] {
                let button = brick.find(world, &format!("sandboxAction:{operation}"))?;
                expect!(
                    button.is_some_and(|item| brick.flag(world, item, "enabled")),
                    "the page does not offer {operation}"
                );
            }
            // Install is offered again only once it is uninstalled.
            expect!(
                brick.find(world, "sandboxAction:install")?.is_none(),
                "the page still offers Install"
            );
            Ok(())
        },
    );
    steps.step("the sandbox settings offer to install it", |world, _, _| {
        let brick = page(world)?;
        let install = brick.find(world, "sandboxAction:install")?;
        expect!(
            install.is_some_and(|item| brick.flag(world, item, "enabled")),
            "the page does not offer Install"
        );
        expect!(
            brick.find(world, "sandboxAction:uninstall")?.is_none(),
            "the page still offers Uninstall"
        );
        expect_text(world, "sandboxProblem:not-installed", NOT_INSTALLED)
    });

    steps.step(
        "they are asked whether to stop (\\d+) reviews?",
        |world, c, _| {
            let count: i64 = c[0].parse().unwrap_or(0);
            let question = format!(
                "Stop {count} review{} and go ahead?",
                if count == 1 { "" } else { "s" }
            );
            let asked = text(world, "sandboxConfirmText")?;
            expect!(asked.starts_with(&question), "the page asks \"{asked}\"");
            // Nothing was stopped yet: the first uninstall asked without
            // draining.
            let runs = world.mc.part::<FakeOpenShell>().runs.clone();
            expect!(
                runs == [json!({"operation": "uninstall"})],
                "the MC was asked {} times",
                runs.len()
            );
            Ok(())
        },
    );
    steps.step("they agree to stop it", |world, _, _| {
        let message = |w: &World| crate::harness::text(&operation(w)["result"]["message"]);
        let asked = message(world);
        let brick = page(world)?;
        brick.click(world, "sandboxConfirmYes")?;
        // The last uninstall's outcome is on the page until this one's lands.
        world.wait_for_with(
            |w| message(w) != asked && section(w)["loading"] == json!(false),
            |w| {
                format!(
                    "the drained uninstall to end; the section is {}",
                    show(&section(w))
                )
            },
        )
    });
    steps.step(
        "another of this MC's reviews starts on the gateway",
        |world, _, _| {
            world.mc.part::<FakeOpenShell>().reviews += 1;
            Ok(())
        },
    );
    steps.step(
        "they are asked again whether to stop (\\d+) reviews, as the reviews changed",
        |world, c, _| {
            let question = format!(
                "Stop {} reviews and go ahead? The running reviews changed since you confirmed.",
                c[0]
            );
            let brick = page(world)?;
            let confirm = brick.item(world, "sandboxConfirm")?;
            let asked = text(world, "sandboxConfirmText")?;
            expect!(
                brick.flag(world, confirm, "visible") && asked.starts_with(&question),
                "the page asks \"{asked}\""
            );
            // The yes named only the review it was asked about.
            let runs = world.mc.part::<FakeOpenShell>().runs.clone();
            expect!(
                runs.last() == Some(&json!({"operation": "uninstall", "drain": ["review-1"]})),
                "the yes did not name the review it asked about"
            );
            Ok(())
        },
    );
    steps.step("no review was stopped", |world, _, _| {
        let machine = world.mc.part::<FakeOpenShell>();
        expect!(
            machine.reviews == 2 && machine.managed,
            "a review was stopped, or OpenShell removed"
        );
        Ok(())
    });
    steps.step(
        "they read that OpenShell was removed, its review stopped first",
        |world, _, _| {
            expect_text(world, "sandboxResult", REMOVED)?;
            let runs = world.mc.part::<FakeOpenShell>().runs.clone();
            expect!(
                runs.last() == Some(&json!({"operation": "uninstall", "drain": ["review-1"]})),
                "the second uninstall did not drain"
            );
            let brick = page(world)?;
            let confirm = brick.item(world, "sandboxConfirm")?;
            expect!(
                !brick.flag(world, confirm, "visible"),
                "the page still asks"
            );
            Ok(())
        },
    );

    steps.step(
        "the sandbox settings' actions are off, and say which access the device lacks",
        |world, _, _| {
            expect_text(world, "sandboxManageReason", MANAGE_REASON)?;
            let brick = page(world)?;
            let install = brick.item(world, "sandboxAction:install")?;
            expect!(!brick.flag(world, install, "enabled"), "Install is on");
            // Nor does the controller run it when asked anyway.
            world.dispatch("sandboxSettings.run", json!({"operation": "install"}))?;
            world.sync()?;
            expect!(
                world.mc.part::<FakeOpenShell>().runs.is_empty(),
                "the MC was asked to install"
            );
            Ok(())
        },
    );
}
