//! The first-run gate and the welcome wizard on the desktop (Onboarding):
//! the @desktop scenarios of features/navigation/welcome-wizard.feature:
//! desktop-qt's OnboardingSteps.cpp.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use hal_c2_shell::controllers::onboarding::Onboarding;
use hal_c2_shell::controllers::settings::Settings;
use serde_json::{Value, json};

use super::settings::fake_config;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The MC's `agentSessions.*`: what a scan finds, and what importing does.
#[derive(Default)]
struct FakeSessions {
    candidates: Vec<Value>,
    refuse_import: String,
    hold_import: bool,
    held_imports: Vec<Rpc>,
    imports: Vec<Value>,
    /// What the setup terminal was sent (terminal.write payloads).
    writes: Vec<Value>,
    /// The preferences file as it was before it became unreadable.
    saved_preferences: Vec<u8>,
    saved_modified: Option<std::time::SystemTime>,
}

fn fake(world: &mut World) -> &mut FakeSessions {
    world.mc.part::<FakeSessions>()
}

fn answer_import(mc: &mut FakeMc, rpc: &Rpc) {
    mc.reply(rpc, json!({"importedCount": 2, "skippedCount": 0}));
}

fn onboarding(world: &World) -> Value {
    world.state("onboarding")
}

fn act(world: &mut World, action: &str, payload: Value) -> Outcome {
    world.dispatch(action, payload)?;
    world.sync()
}

fn preferences_path(world: &World) -> PathBuf {
    world.config_dir().join("preferences.json")
}

/// The MC's own computer, its config as the MC publishes it.
fn describe_computer(world: &mut World, label: &str) {
    world.mc.label = label.to_owned();
    let config = fake_config(&mut world.mc);
    config.config.insert("cwd".into(), json!("/home/ada"));
    config
        .config
        .insert("environment".into(), json!({"platform": {"os": "linux"}}));
}

fn driver_of(agent: &str) -> &'static str {
    if agent == "Claude Code" {
        "claudeAgent"
    } else {
        "codex"
    }
}

/// An agent on the MC's computer, as its provider probe reports it.
fn give_agent(world: &mut World, agent: &str, state: &str, instance_id: &str) {
    let driver = driver_of(agent);
    let installed = state != "not installed";
    let signed_in = state == "installed and signed in";
    let mut provider = json!({
        "instanceId": if instance_id.is_empty() { driver } else { instance_id },
        "driver": driver,
        "enabled": true,
        "installed": installed,
        "status": if signed_in { "ready" } else { "error" },
        "auth": {"status": if !installed { "unknown" } else if signed_in { "authenticated" } else { "unauthenticated" }},
    });
    if !installed {
        provider["message"] = json!(format!("{agent} is not installed."));
    }
    let config = fake_config(&mut world.mc);
    let mut providers = config
        .config
        .get("providers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    providers.retain(|p| text(&p["driver"]) != driver);
    providers.push(provider);
    config.config.insert("providers".into(), json!(providers));
}

fn open_hal_c2(world: &mut World) -> Outcome {
    world.connect()?;
    world.wait_for_with(
        |w| {
            let state = onboarding(w);
            text(&state["gate"]) != "pending" || !state["recovery"].is_null()
        },
        |w| format!("the gate to decide; it is {}", show(&onboarding(w))),
    )
}

fn open_wizard(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        open_hal_c2(world)?;
    }
    world.wait_for_with(
        |w| text(&onboarding(w)["gate"]) == "wizard",
        |w| format!("the wizard; the gate is {}", show(&onboarding(w))),
    )
}

fn computer(world: &World, label: &str) -> Value {
    onboarding(world)["computers"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|entry| text(&entry["label"]) == label)
        .cloned()
        .unwrap_or(Value::Null)
}

fn flag(value: &Value, key: &str) -> bool {
    value[key].as_bool().unwrap_or(false)
}

/// Another computer of the cluster, named `label`.
fn join_computer(world: &mut World, label: &str, online: bool) {
    if !online {
        world.mc.offline.insert(label.to_owned());
    }
    world.mc.join_named(label);
}

fn continue_to(world: &mut World, step: &str) -> Outcome {
    for _ in 0..2 {
        if text(&onboarding(world)["step"]) == step {
            break;
        }
        world.wait_for_with(
            |w| {
                let state = onboarding(w);
                flag(&state, "canContinue") || text(&state["step"]) != "connection"
            },
            |w| {
                format!(
                    "to be able to continue; the wizard is {}",
                    show(&onboarding(w))
                )
            },
        )?;
        act(world, "onboarding.continue", Value::Null)?;
    }
    world.wait_for_with(
        |w| text(&onboarding(w)["step"]) == step,
        |w| format!("the {step} step; the wizard is {}", show(&onboarding(w))),
    )
}

fn card(world: &World, agent: &str, label: &str) -> Value {
    onboarding(world)["agents"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|section| text(&section["label"]) == label)
        .flat_map(|section| section["cards"].as_array().into_iter().flatten())
        .find(|entry| text(&entry["name"]) == agent)
        .cloned()
        .unwrap_or(Value::Null)
}

/// The agents step, with the MC's providers checked.
fn check_agents(world: &mut World) -> Outcome {
    open_wizard(world)?;
    continue_to(world, "agents")?;
    world.wait_for_with(
        |w| {
            let state = onboarding(w);
            let Some(first) = state["agents"].as_array().and_then(|s| s.first()) else {
                return false;
            };
            // An agent the MC does not report stays "checking".
            first["cards"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|entry| text(&entry["state"]) != "checking")
        },
        |w| {
            format!(
                "the agents to be checked; the wizard is {}",
                show(&onboarding(w))
            )
        },
    )
}

/// Opens the setup terminal for `agent` on the MC's computer.
fn set_up(world: &mut World, agent: &str) -> Outcome {
    world.mc.on_rpc("terminal.write", |mc, rpc| {
        mc.part::<FakeSessions>().writes.push(rpc.payload.clone());
        mc.pass_on(rpc)
    });
    check_agents(world)?;
    let environment = world.mc.environment_id.clone();
    act(
        world,
        "onboarding.agent",
        json!({"environmentId": environment, "driver": driver_of(agent)}),
    )?;
    world.wait_for_with(
        |w| {
            let status = text(&onboarding(w)["terminal"]["status"]);
            status == "ready" || status == "openFailed"
        },
        |w| format!("the setup terminal; the wizard is {}", show(&onboarding(w))),
    )
}

fn terminal_inputs(world: &World) -> Vec<Value> {
    world
        .mc
        .subscriptions
        .iter()
        .map(|subscription| subscription["shape"].clone())
        .filter(|shape| text(&shape["type"]) == "terminal")
        .collect()
}

fn candidate(path: &str, git: Value, threads: i64, last_active_at: &str) -> Value {
    json!({
        "path": path,
        "title": path.rsplit('/').next().unwrap_or(path),
        "sources": ["claudeAgent", "codex"],
        "threadCount": threads,
        "lastActiveAt": last_active_at,
        "alreadyImported": false,
        "git": git,
    })
}

fn repository(name: &str) -> Value {
    json!({"remoteKey": format!("github.com/{name}"), "repository": name})
}

/// A busy recent repository (selected by default), a quiet one, and a plain folder.
fn find_projects(world: &mut World) {
    fake(world).candidates = vec![
        candidate(
            "/home/ada/api",
            repository("acme/api"),
            5,
            "2026-09-22T10:00:00.000Z",
        ),
        candidate(
            "/home/ada/site",
            repository("acme/site"),
            1,
            "2026-09-21T10:00:00.000Z",
        ),
        candidate(
            "/home/ada/notes",
            Value::Null,
            4,
            "2026-09-20T10:00:00.000Z",
        ),
    ];
}

fn import_state(world: &World) -> Value {
    onboarding(world)["import"].clone()
}

fn reach_import(world: &mut World) -> Outcome {
    open_wizard(world)?;
    continue_to(world, "agents")?;
    continue_to(world, "import")?;
    world.wait_for_with(
        |w| {
            let state = import_state(w);
            let scans = state["scans"].as_array().cloned().unwrap_or_default();
            !scans.is_empty() && scans.iter().all(|scan| !flag(scan, "pending"))
        },
        |w| format!("the scans; the wizard is {}", show(&onboarding(w))),
    )
}

fn import_keys(world: &World) -> Vec<Value> {
    let mut keys = Vec::new();
    for scan in import_state(world)["scans"]
        .as_array()
        .into_iter()
        .flatten()
    {
        for group in scan["repositories"].as_array().into_iter().flatten() {
            for entry in group["candidates"].as_array().into_iter().flatten() {
                keys.push(entry["key"].clone());
            }
        }
        for entry in scan["other"]["candidates"].as_array().into_iter().flatten() {
            keys.push(entry["key"].clone());
        }
    }
    keys
}

fn import_project(world: &mut World) -> Outcome {
    fake(world).candidates = vec![candidate(
        "/home/ada/api",
        repository("acme/api"),
        5,
        "2026-09-22T10:00:00.000Z",
    )];
    reach_import(world)?;
    let keys = import_keys(world);
    act(
        world,
        "onboarding.project",
        json!({"keys": keys, "selected": true}),
    )?;
    act(world, "onboarding.import", Value::Null)
}

fn app_opens(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| {
            let state = onboarding(w);
            text(&state["gate"]) == "app" && state["recovery"].is_null()
        },
        |w| format!("the app; the gate is {}", show(&onboarding(w))),
    )
}

fn device_settings(world: &World) -> serde_json::Map<String, Value> {
    Settings::of(world.engine()).device()
}

/// The wizard or its recovery page is showing `text` as its title.
pub fn onboarding_shows(world: &World, text_shown: &str) -> bool {
    let state = onboarding(world);
    match text(&state["recovery"]).as_str() {
        "settings" => return text_shown == "Could not read settings",
        "connection" => return text_shown == "Still connecting",
        _ => {}
    }
    text(&state["gate"]) == "wizard" && text_shown == "Set up HAL-C2"
}

/// The wizard tells the user `text`: a pairing, setup terminal or import error.
pub fn onboarding_tells(world: &World, told: &str) -> bool {
    let state = onboarding(world);
    if state["pairingError"] == json!(told) || state["import"]["error"] == json!(told) {
        return true;
    }
    text(&state["terminal"]["status"]) == "openFailed"
        && told == "Could not open the setup terminal."
}

/// Chooses the import step's "Select all" or "Select none", opening the
/// wizard at that step with projects to choose from; false for other choices.
pub fn onboarding_chooses(world: &mut World, choice: &str) -> Outcome<bool> {
    if choice != "Select all" && choice != "Select none" {
        return Ok(false);
    }
    if text(&onboarding(world)["step"]) != "import" {
        find_projects(world);
        reach_import(world)?;
    }
    let action = if choice == "Select all" {
        "onboarding.selectAll"
    } else {
        "onboarding.selectNone"
    };
    act(world, action, Value::Null)?;
    Ok(true)
}

pub fn register(steps: &mut Steps) {
    steps.extension(|mc| {
        mc.on_rpc("agentSessions.scan", |mc, rpc| {
            let candidates = mc.part::<FakeSessions>().candidates.clone();
            mc.reply(rpc, json!({"candidates": candidates}));
            Ok(())
        });
        mc.on_rpc("agentSessions.import", |mc, rpc| {
            let sessions = mc.part::<FakeSessions>();
            sessions.imports.push(rpc.payload.clone());
            let refuse = sessions.refuse_import.clone();
            if !refuse.is_empty() {
                mc.refuse(rpc, &refuse);
                return Ok(());
            }
            if sessions.hold_import {
                sessions.held_imports.push(rpc.clone());
                return Ok(());
            }
            answer_import(mc, rpc);
            Ok(())
        });
    });

    // ---- When the wizard appears ----
    steps.step("a fresh installation with no workspace", |world, _, _| {
        expect!(
            world.mc.projects.is_empty()
                && world.mc.threads.is_empty()
                && !preferences_path(world).exists(),
            "the installation is not fresh"
        );
        Ok(())
    });
    steps.step("a workspace that already has projects", |world, _, _| {
        world.mc.projects.insert(
            "shop".into(),
            json!({"id": "shop", "title": "shop", "workspaceRoot": "/work/shop", "scripts": []}),
        );
        Ok(())
    });
    steps.step("the user opens HAL-C2", |world, _, _| open_hal_c2(world));
    steps.step("the app opens without the wizard", |world, _, _| {
        app_opens(world)?;
        // Saved quietly, so the next start decides without the MC.
        world.wait_for("setup to be saved as done", |w| {
            !text(
                &device_settings(w)
                    .get("onboardingCompletedAt")
                    .cloned()
                    .unwrap_or_default(),
            )
            .is_empty()
        })
    });
    steps.step(
        "the app cannot confirm the workspace during startup",
        |world, _, _| {
            world.mc.hold_snapshot = true;
            world.with::<Onboarding, _>(|c, e| c.set_decision_timeout(e, 20))
        },
    );
    steps.step("the user reloads", |world, _, _| {
        world.mc.connections.clear();
        // Long enough for the step after to see it waiting again.
        world.with::<Onboarding, _>(|c, e| c.set_decision_timeout(e, 60000))?;
        act(world, "onboarding.reload", Value::Null)
    });
    steps.step("the app tries again", |world, _, _| {
        world.wait_for("the shell to connect again", |w| {
            !w.mc.connections.is_empty() && w.shell_subscriptions() >= 1
        })?;
        let state = onboarding(world);
        expect!(
            text(&state["gate"]) == "pending" && state["recovery"].is_null(),
            "the gate to wait again; it is {}",
            show(&state)
        );
        Ok(())
    });
    steps.step("the saved settings cannot be read", |world, _, _| {
        let path = preferences_path(world);
        let saved = br#"{"onboardingCompletedAt":"2026-09-01T10:00:00.000Z","sidebarWidth":312}"#;
        if std::fs::write(&path, saved).is_err() {
            fail!("cannot write {}", path.display());
        }
        fake(world).saved_preferences = saved.to_vec();
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o0));
        fake(world).saved_modified = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        let engine = world.engine().clone();
        Settings::of(&engine).reload_device(&engine);
        expect!(
            Settings::of(&engine).device_unreadable(),
            "the preferences are readable"
        );
        Ok(())
    });
    steps.step("the saved settings are left untouched", |world, _, _| {
        let path = preferences_path(world);
        let info = std::fs::metadata(&path);
        let modified = info.as_ref().ok().and_then(|m| m.modified().ok());
        let size = info.as_ref().map(|m| m.len() as usize).unwrap_or(0);
        expect!(
            modified == fake(world).saved_modified && size == fake(world).saved_preferences.len(),
            "the preferences were written"
        );
        Ok(())
    });
    steps.step(
        "storage becomes available and the user retries",
        |world, _, _| {
            let path = preferences_path(world);
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            act(world, "onboarding.retry", Value::Null)
        },
    );
    steps.step(
        "the app continues with the saved settings",
        |world, _, _| {
            app_opens(world)?;
            let device = Value::Object(device_settings(world));
            expect!(
                device["sidebarWidth"].as_i64() == Some(312)
                    && text(&device["onboardingCompletedAt"]) == "2026-09-01T10:00:00.000Z",
                "the device settings are {}",
                show(&device)
            );
            let kept = std::fs::read(preferences_path(world)).ok();
            expect!(
                kept.as_deref() == Some(fake(world).saved_preferences.as_slice()),
                "the preferences were rewritten"
            );
            Ok(())
        },
    );
    steps.step("the settings cannot be saved", |world, _, _| {
        open_wizard(world)?;
        // A file where the preferences' directory would be.
        let blocker = world.config_dir().join("blocked");
        if std::fs::write(&blocker, b"").is_err() {
            fail!("cannot write {}", blocker.display());
        }
        let engine = world.engine().clone();
        Settings::of(&engine).set_device_path(&engine, Some(blocker.join("preferences.json")));
        Ok(())
    });
    steps.step("the user finishes the wizard", |world, _, _| {
        reach_import(world)?;
        act(world, "onboarding.skip", Value::Null)
    });

    // ---- Connect your computers ----
    steps.step(
        &format!("the user opened HAL-C2 from a desktop app named {Q}"),
        |world, c, _| {
            world.mc.label = c[0].clone();
            open_wizard(world)
        },
    );
    steps.step(&format!("{Q} is connected and selected"), |world, c, _| {
        world.wait_for_with(
            |w| {
                let entry = computer(w, &c[0]);
                flag(&entry, "connected") && flag(&entry, "selected")
            },
            |w| {
                format!(
                    "{} connected and selected; the wizard is {}",
                    c[0],
                    show(&onboarding(w))
                )
            },
        )
    });
    steps.step(
        "a saved computer and a computer discovered through HAL-C2 Connect",
        |world, _, _| {
            world.mc.label = "studio".into();
            join_computer(world, "laptop", true);
            open_wizard(world)?;
            world.mc.join("mc-b", "env-found");
            world.sync()
        },
    );
    steps.step("both computers are selected", |world, _, _| {
        world.wait_for_with(
            |w| {
                let selected: Vec<String> = onboarding(w)["computers"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|entry| flag(entry, "selected"))
                    .map(|entry| text(&entry["environmentId"]))
                    .collect();
                selected.iter().any(|id| id == "laptop")
                    && selected.iter().any(|id| id == "env-found")
            },
            |w| format!("both selected; the wizard is {}", show(&onboarding(w))),
        )
    });
    steps.step(
        &format!("a selected, connected computer {Q}"),
        |world, c, _| {
            join_computer(world, &c[0], true);
            open_wizard(world)?;
            world.wait_for_with(
                |w| {
                    let entry = computer(w, &c[0]);
                    flag(&entry, "connected") && flag(&entry, "selected")
                },
                |w| format!("{} selected; the wizard is {}", c[0], show(&onboarding(w))),
            )
        },
    );
    steps.step(&format!("the user unchecks {Q}"), |world, c, _| {
        let id = computer(world, &c[0])["environmentId"].clone();
        act(
            world,
            "onboarding.select",
            json!({"environmentId": id, "selected": false}),
        )
    });
    steps.step(
        &format!("{Q} is not set up by the wizard"),
        |world, c, _| {
            continue_to(world, "agents")?;
            let sections = onboarding(world)["agents"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            expect!(
                !sections.is_empty() && sections.iter().all(|s| text(&s["label"]) != c[0]),
                "the wizard sets up {}",
                show(&json!(sections))
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} stays connected"), |world, c, _| {
        expect!(
            flag(&computer(world, &c[0]), "connected") && world.mc.members.contains(&c[0]),
            "{} is no longer connected; the wizard is {}",
            c[0],
            show(&onboarding(world))
        );
        Ok(())
    });
    steps.step(
        "the user adds a computer by pasting an invite link",
        |world, _, _| {
            world.mc.on_rpc("cluster.join", |mc, rpc| {
                let link = text(&rpc.payload["link"]);
                if link != "http://desk:3773/pair#token=abc" {
                    fail!("joined with {link}");
                }
                mc.join_named("desk");
                mc.pass_on(rpc)
            });
            open_wizard(world)?;
            act(
                world,
                "onboarding.pair",
                json!({"pairingUrl": " http://desk:3773/pair#token=abc "}),
            )
        },
    );
    steps.step("the computer connects and is selected", |world, _, _| {
        world.wait_for_with(
            |w| {
                let entry = computer(w, "desk");
                flag(&entry, "connected")
                    && flag(&entry, "selected")
                    && !flag(&onboarding(w), "pairing")
            },
            |w| format!("desk selected; the wizard is {}", show(&onboarding(w))),
        )
    });
    steps.step(
        "the user adds a computer with an invite link that fails",
        |world, _, _| {
            world.mc.on_rpc("cluster.join", |mc, rpc| {
                mc.refuse(rpc, "the pairing link is invalid or expired");
                Ok(())
            });
            open_wizard(world)?;
            act(
                world,
                "onboarding.pair",
                json!({"pairingUrl": "http://desk:3773/pair#token=old"}),
            )
        },
    );
    steps.step("a selected computer is still connecting", |world, _, _| {
        join_computer(world, "laptop", false);
        open_wizard(world)?;
        world.wait_for_with(
            |w| flag(&computer(w, "laptop"), "selected"),
            |w| format!("laptop selected; the wizard is {}", show(&onboarding(w))),
        )
    });
    steps.step("the user cannot continue yet", |world, _, _| {
        expect!(
            !flag(&onboarding(world), "canContinue"),
            "the user can continue"
        );
        act(world, "onboarding.continue", Value::Null)?;
        expect!(
            text(&onboarding(world)["step"]) == "connection",
            "the wizard moved on"
        );
        Ok(())
    });
    steps.step("that computer connects", |world, _, _| {
        world.mc.set_online("laptop", true);
        world.sync()
    });
    steps.step("the user can continue", |world, _, _| {
        world.wait_for_with(
            |w| flag(&onboarding(w), "canContinue"),
            |w| {
                format!(
                    "to be able to continue; the wizard is {}",
                    show(&onboarding(w))
                )
            },
        )
    });

    // ---- Check your agents ----
    steps.step(
        &format!(
            "the computer {Q} has (Claude Code|Codex) (not installed|installed but signed out|installed and signed in)"
        ),
        |world, c, _| {
            describe_computer(world, &c[0]);
            give_agent(world, &c[1], &c[2], "");
            Ok(())
        },
    );
    steps.step("the wizard checks agents", |world, _, _| {
        check_agents(world)
    });
    steps.step(
        &format!("(Claude Code|Codex) on {Q} offers (Install|Sign in|nothing to do)"),
        |world, c, _| {
            let shown = card(world, &c[0], &c[1]);
            let state = text(&shown["state"]);
            let offer = match state.as_str() {
                "install" => "Install".to_owned(),
                "signIn" => "Sign in".to_owned(),
                "ready" => "nothing to do".to_owned(),
                _ => state,
            };
            expect!(
                offer == c[2],
                "{} offers {offer}; the wizard is {}",
                c[0],
                show(&onboarding(world))
            );
            Ok(())
        },
    );
    steps.step(&format!("Codex is not installed on {Q}"), |world, c, _| {
        describe_computer(world, &c[0]);
        give_agent(world, "Codex", "not installed", "");
        Ok(())
    });
    steps.step("the user chooses to install Codex", |world, _, _| {
        set_up(world, "Codex")
    });
    steps.step(
        &format!("a terminal opens on {Q} with the vendor's installer command ready"),
        |world, c, _| {
            let installer = "curl -fsSL https://chatgpt.com/codex/install.sh | sh";
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeSessions>().is_some_and(|f| {
                        f.writes
                            .iter()
                            .any(|write| text(&write["data"]) == installer)
                    })
                },
                |w| {
                    let writes =
                        w.mc.peek::<FakeSessions>()
                            .map(|f| f.writes.clone())
                            .unwrap_or_default();
                    format!(
                        "the installer typed; the terminal was sent {}",
                        show(&json!(writes))
                    )
                },
            )?;
            let inputs = terminal_inputs(world);
            let last = inputs.last().cloned().unwrap_or(Value::Null);
            expect!(
                !inputs.is_empty()
                    && text(&last["environment"]) == world.mc.environment_id
                    && world.mc.label == c[0]
                    && text(&last["input"]["cwd"]) == "/home/ada",
                "the terminal opened as {}",
                show(&last)
            );
            expect!(
                !onboarding(world)["terminal"].is_null(),
                "the wizard has no terminal to show"
            );
            Ok(())
        },
    );
    steps.step(
        "the user is asked to review the command and press Enter to run it",
        |world, _, _| {
            let terminal = onboarding(world)["terminal"].clone();
            expect!(
                text(&terminal["status"]) == "ready",
                "the terminal is {}",
                show(&terminal)
            );
            for write in &fake(world).writes {
                let data = text(&write["data"]);
                expect!(
                    !data.contains('\r') && !data.contains('\n'),
                    "the command was run: {data}"
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the Codex instance on {Q} has its own home directory and a secret variable"),
        |world, c, _| {
            describe_computer(world, &c[0]);
            give_agent(world, "Codex", "installed but signed out", "codex_work");
            let config = fake_config(&mut world.mc);
            config.settings.insert(
                "providerInstances".into(),
                json!({"codex_work": {
                    "driver": "codex",
                    "config": {"binaryPath": "~/bin/codex work", "homePath": "/home/ada/.codex-work"},
                    "environment": [{"name": "OPENAI_API_KEY", "sensitive": true, "valueRedacted": true}],
                }}),
            );
            config
                .secrets
                .insert("codex_work/OPENAI_API_KEY".into(), "sk-secret".into());
            Ok(())
        },
    );
    steps.step("the user chooses to sign in to Codex", |world, _, _| {
        set_up(world, "Codex")
    });
    steps.step(
        "the terminal runs with that home and variable",
        |world, _, _| {
            // The MC starts it with the instance's env and home (HalC2.Terminal).
            let inputs = terminal_inputs(world);
            let last = inputs.last().cloned().unwrap_or(Value::Null);
            expect!(
                !inputs.is_empty() && text(&last["input"]["providerInstanceId"]) == "codex_work",
                "the terminal opened as {}",
                show(&last)
            );
            world.wait_for("the instance's own sign-in command to be typed", |w| {
                w.mc.peek::<FakeSessions>().is_some_and(|f| {
                    f.writes
                        .iter()
                        .any(|write| text(&write["data"]) == "~/'bin/codex work' login")
                })
            })
        },
    );
    steps.step(
        "the secret stays redacted where the user can see it",
        |world, _, _| {
            expect!(
                !show(&onboarding(world)).contains("sk-secret"),
                "the wizard shows the secret"
            );
            for input in terminal_inputs(world) {
                expect!(
                    !show(&input).contains("sk-secret"),
                    "the shell sent the secret"
                );
            }
            for write in &fake(world).writes {
                expect!(
                    !show(write).contains("sk-secret"),
                    "the terminal was sent the secret"
                );
            }
            Ok(())
        },
    );
    steps.step(&format!("terminals cannot start on {Q}"), |world, c, _| {
        describe_computer(world, &c[0]);
        give_agent(world, "Codex", "not installed", "");
        world.mc.on_shape("terminal", |mc, id, _| {
            mc.forget(id);
            mc.send(&json!({"t": "error", "id": id,
                    "reason": "Terminal limit reached on this machine"}));
            Ok(())
        });
        Ok(())
    });

    // ---- Import your projects ----
    steps.step("every listed project is selected", |world, _, _| {
        let state = import_state(world);
        expect!(
            state["total"].as_i64() == Some(3) && state["selectedCount"].as_i64() == Some(3),
            "the import is {}",
            show(&state)
        );
        Ok(())
    });
    steps.step("no project is selected", |world, _, _| {
        let state = import_state(world);
        expect!(
            state["total"].as_i64() == Some(3) && state["selectedCount"].as_i64() == Some(0),
            "the import is {}",
            show(&state)
        );
        Ok(())
    });
    steps.step("reading thread history will fail", |world, _, _| {
        fake(world).refuse_import = "cannot read ~/.codex/sessions".into();
        Ok(())
    });
    steps.step("the user imports a project", |world, _, _| {
        import_project(world)
    });

    // ---- Moving through the wizard ----
    steps.step(
        "the user continues without importing projects",
        |world, _, _| {
            reach_import(world)?;
            act(world, "onboarding.skip", Value::Null)
        },
    );
    steps.step("the app opens", |world, _, _| app_opens(world));
    steps.step("the user is on the import step", |world, _, _| {
        join_computer(world, "laptop", true);
        open_wizard(world)?;
        world.wait_for("laptop to be offered", |w| !computer(w, "laptop").is_null())?;
        act(
            world,
            "onboarding.select",
            json!({"environmentId": "laptop", "selected": false}),
        )?;
        reach_import(world)
    });
    steps.step(
        "the user returns to the connect step from the progress bar",
        |world, _, _| act(world, "onboarding.stage", json!({"index": 0})),
    );
    steps.step(
        "the connect step is shown with the earlier choices",
        |world, _, _| {
            let state = onboarding(world);
            expect!(
                text(&state["step"]) == "connection"
                    && !flag(&computer(world, "laptop"), "selected")
                    && flag(&state["computers"][0], "selected"),
                "the wizard is {}",
                show(&state)
            );
            Ok(())
        },
    );
    steps.step("an import is running", |world, _, _| {
        fake(world).hold_import = true;
        import_project(world)?;
        world.wait_for("the import to start", |w| {
            w.mc.peek::<FakeSessions>()
                .is_some_and(|f| !f.held_imports.is_empty())
        })
    });
    steps.step(
        "the user cannot move to another step until it finishes",
        |world, _, _| {
            expect!(
                flag(&onboarding(world), "importing"),
                "no import is running"
            );
            for index in [0, 1] {
                act(world, "onboarding.stage", json!({"index": index}))?;
                expect!(
                    text(&onboarding(world)["step"]) == "import",
                    "the wizard moved to {}",
                    text(&onboarding(world)["step"])
                );
            }
            act(world, "onboarding.skip", Value::Null)?;
            expect!(
                text(&onboarding(world)["gate"]) == "wizard",
                "the wizard closed mid-import"
            );
            // Once it lands, the app opens on the imported project.
            let held = std::mem::take(&mut fake(world).held_imports);
            for rpc in &held {
                answer_import(&mut world.mc, rpc);
            }
            app_opens(world)
        },
    );
}
