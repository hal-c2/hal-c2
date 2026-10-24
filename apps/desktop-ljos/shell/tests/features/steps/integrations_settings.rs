//! The native Integrations settings section (device settings and Slack
//! settings): the @desktop device and Slack scenarios of
//! features/settings/integrations.feature. The MC fakes HalC2.Devices: its
//! DeviceServiceState follows each environment's settings document,
//! `device.configure` saves there, and its own state goes to `devices`
//! watchers. It fakes HalC2.Slack too: `slack.connect` takes any tokens but a
//! refused bot token, and its status goes to `slack` watchers, unless the MC
//! turns the shape down as one that cannot reach HalC2.Slack does.
//! desktop-qt's IntegrationsSettingsSteps.cpp.

use std::collections::HashSet;

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Map, Value, json};

use crate::expect;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::settings::{document_of, fake_config, save_elsewhere, save_on};
use crate::world::World;

#[derive(Default)]
struct FakeDevices {
    /// Environments whose hub tool is behind.
    outdated: HashSet<String>,
    fail_updates: bool,
}

fn environment_of(mc: &FakeMc, environment: &str) -> String {
    if environment.is_empty() {
        mc.environment_id.clone()
    } else {
        environment.to_owned()
    }
}

fn settings_of(mc: &mut FakeMc, environment: &str) -> Map<String, Value> {
    if environment == mc.environment_id {
        fake_config(mc).settings.clone()
    } else {
        document_of(mc, environment).settings.clone()
    }
}

/// HalC2.Devices' state on `environment`: iOS here, Android missing; another
/// machine says which it is, so the one shown can be told apart.
fn device_state(mc: &mut FakeMc, environment: &str) -> Value {
    let settings = settings_of(mc, environment);
    let flag = |key: &str| settings.get(key).and_then(Value::as_bool).unwrap_or(false);
    let enabled = flag("enableDeviceSupport");
    let tool =
        json!({"requiredVersion": "1.4.0", "installedVersions": ["1.4.0"], "runningVersion": null});
    let mut hub = tool.clone();
    if mc.part::<FakeDevices>().outdated.contains(environment) {
        hub["installedVersions"] = json!(["1.3.0"]);
    }
    let here = environment == mc.environment_id;
    json!({
        "supportsHostRetry": true,
        "supportsToolUpdate": true,
        "supportsToolInspection": true,
        "hosts": [{
            "id": "local", "kind": "local", "label": "This host",
            "platforms": [
                {"platform": "ios", "available": here,
                 "reason": format!("Xcode is not installed on {environment}.")},
                {"platform": "android", "available": false,
                 "reason": "The Android SDK was not found."},
            ],
            "tools": {"hub": hub, "agent": tool},
            "hubInstalled": true,
            "agentDeviceInstalled": true,
        }],
        "hostStatus": if enabled { "ready" } else { "disabled" },
        "hostStatuses": {},
        "devices": if here && enabled {
            json!([{"id": "iphone", "platform": "ios", "name": "iPhone 17"}])
        } else {
            json!([])
        },
        "sessions": [],
        "onboardingCompleted": enabled,
        "agentAccessEnabled": flag("enableAgentDeviceAccess"),
        "hubBasePath": "/api/device-hub",
        "revision": 0,
    })
}

fn broadcast(mc: &mut FakeMc) {
    let environment = mc.environment_id.clone();
    let state = device_state(mc, &environment);
    for id in mc.subscribers("devices") {
        mc.send(&json!({"t": "devices", "id": id, "state": state}));
    }
}

fn serve_devices(mc: &mut FakeMc) {
    mc.on_shape("devices", |mc, id, _| {
        let environment = mc.environment_id.clone();
        let state = device_state(mc, &environment);
        mc.send(&json!({"t": "devices", "id": id, "state": state}));
        Ok(())
    });
    mc.on_rpc("device.", |mc, rpc| {
        let environment = environment_of(mc, &rpc.environment);
        if mc.holding("device") {
            // Answered once released, late: the change is still saving until then.
            let rpc = rpc.clone();
            mc.defer(move |mc| {
                let state = device_state(mc, &environment);
                mc.reply(&rpc, state);
            });
            return Ok(());
        }
        if rpc.method == "device.configure" {
            let refusal = if environment == mc.environment_id {
                fake_config(mc).refuse_writes.clone()
            } else {
                document_of(mc, &environment).refuse_writes.clone()
            };
            if !refusal.is_empty() {
                mc.refuse(rpc, &refusal);
                return Ok(());
            }
            if let Some(enabled) = rpc.payload["enabled"].as_bool() {
                save_on(mc, &environment, "enableDeviceSupport", json!(enabled));
            }
            if let Some(enabled) = rpc.payload["agentAccessEnabled"].as_bool() {
                save_on(mc, &environment, "enableAgentDeviceAccess", json!(enabled));
            }
        } else if rpc.method == "device.list" && rpc.payload.get("updateTool").is_some() {
            let fake = mc.part::<FakeDevices>();
            if fake.fail_updates {
                mc.refuse(rpc, "Could not update device tool: command failed");
                return Ok(());
            }
            fake.outdated.remove(&environment);
        }
        let state = device_state(mc, &environment);
        mc.reply(rpc, state);
        if environment == mc.environment_id {
            broadcast(mc);
        }
        Ok(())
    });
}

/// HalC2.Slack on the MC: the tokens it holds and the status it shows.
#[derive(Default)]
struct FakeSlack {
    bot_token: String,
    app_token: String,
    state: String,
    error: String,
}

impl FakeSlack {
    fn off() -> Self {
        FakeSlack {
            state: "off".into(),
            ..Default::default()
        }
    }
}

/// While set, why the MC turns the slack shape down.
#[derive(Default)]
struct SlackUnreachable {
    reason: String,
}

const REFUSED_BOT: &str = "xoxb-refused";
const UNREACHABLE: &str = "MC unavailable: noconnection";
const BOT_TOKEN: &str = "xoxb-desktop-bot";
const APP_TOKEN: &str = "xapp-desktop-app";

fn slack_status(mc: &mut FakeMc) -> Value {
    let fake = mc.part::<FakeSlack>();
    let state = if fake.state.is_empty() {
        "off"
    } else {
        &fake.state
    };
    let up = state == "connected";
    let either = |value: &str| if up { json!(value) } else { Value::Null };
    json!({
        "state": state,
        "team": either("acme"),
        "teamId": either("T0ACME"),
        "bot": either("HAL"),
        "botUserId": either("UHAL"),
        "error": if fake.error.is_empty() { Value::Null } else { json!(fake.error) },
        "tokensSet": !fake.bot_token.is_empty(),
    })
}

fn slack_broadcast(mc: &mut FakeMc) {
    let status = slack_status(mc);
    for id in mc.subscribers("slack") {
        mc.send(&json!({"t": "slack", "id": id, "status": status}));
    }
}

/// The scopes, events and Socket Mode of HalC2.Slack.manifest/0, in short.
const MANIFEST: &str = "display_information:\n  name: HAL-C2\nfeatures:\n  bot_user:\n    display_name: HAL-C2\noauth_config:\n  scopes:\n    bot:\n      - app_mentions:read\n      - channels:history\n      - channels:read\n      - chat:write\n      - commands\n      - users:read\nsettings:\n  event_subscriptions:\n    bot_events:\n      - app_mention\n      - message.channels\n  socket_mode_enabled: true\n";

fn serve_slack(mc: &mut FakeMc) {
    mc.on_shape("slack", |mc, id, _| {
        let reason = mc.part::<SlackUnreachable>().reason.clone();
        if !reason.is_empty() {
            mc.send(&json!({"t": "error", "id": id, "reason": reason}));
            mc.forget(id);
            return Ok(());
        }
        let status = slack_status(mc);
        mc.send(&json!({"t": "slack", "id": id, "status": status}));
        Ok(())
    });
    mc.on_rpc("slack.", |mc, rpc| {
        match rpc.method.as_str() {
            "slack.connect" => {
                let bot = text(&rpc.payload["botToken"]);
                if bot == REFUSED_BOT {
                    let error = "Slack refused the bot token: invalid_auth".to_owned();
                    *mc.part::<FakeSlack>() = FakeSlack {
                        state: "failed".into(),
                        error: error.clone(),
                        ..Default::default()
                    };
                    mc.refuse(rpc, &error);
                } else {
                    *mc.part::<FakeSlack>() = FakeSlack {
                        bot_token: bot,
                        app_token: text(&rpc.payload["appToken"]),
                        state: "connected".into(),
                        error: String::new(),
                    };
                    let status = slack_status(mc);
                    mc.reply(rpc, status);
                }
            }
            "slack.disconnect" => {
                *mc.part::<FakeSlack>() = FakeSlack::off();
                let status = slack_status(mc);
                mc.reply(rpc, status);
            }
            "slack.manifest" => {
                mc.reply(rpc, json!({"manifest": MANIFEST}));
                return Ok(());
            }
            _ => {
                let status = slack_status(mc);
                mc.reply(rpc, status);
                return Ok(());
            }
        }
        slack_broadcast(mc);
        Ok(())
    });
}

fn section(world: &World) -> Value {
    world.state("deviceSettings")
}

fn open_integrations(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    let integrations = Route::Settings("/settings/integrations".into());
    world.with::<Navigation, _>(|n, engine| {
        if *n.route() != integrations {
            n.open(engine, integrations);
        }
    })
}

/// Connects once the Givens have set the MC up, then waits for the section.
fn ready(world: &mut World) -> Outcome {
    open_integrations(world)?;
    world.wait_for_with(
        |w| {
            let section = section(w);
            section["open"] == true && section["loaded"] == true
        },
        |w| {
            format!(
                "the device settings to load; they are {}",
                show(&section(w))
            )
        },
    )
}

fn slack_section(world: &World) -> Value {
    world.state("slackSettings")
}

/// Connects once the Givens have set the MC up, then waits for the Slack
/// section to load, or to fail to.
fn slack_ready(world: &mut World) -> Outcome {
    open_integrations(world)?;
    world.wait_for_with(
        |w| {
            let slack = slack_section(w);
            slack["open"] == true && (slack["loaded"] == true || slack["failed"] == true)
        },
        |w| {
            format!(
                "the Slack settings to load; they are {}",
                show(&slack_section(w))
            )
        },
    )
}

fn slack_connect(world: &mut World, bot: &str) -> Outcome {
    slack_ready(world)?;
    world.wait_for_with(
        |w| slack_section(w)["editable"] == true,
        |w| {
            format!(
                "Slack to be editable; the section is {}",
                show(&slack_section(w))
            )
        },
    )?;
    world.dispatch(
        "slackSettings.connect",
        json!({"botToken": bot, "appToken": APP_TOKEN}),
    )
}

fn turn(world: &mut World, tool: &'static str, enabled: bool) -> Outcome {
    ready(world)?;
    world.wait_for_with(
        |w| at(&section(w), &format!("{tool}.enabled")) == true,
        |w| {
            format!(
                "the {tool} switch to be usable; the section is {}",
                show(&section(w))
            )
        },
    )?;
    world.dispatch(
        &format!("deviceSettings.{tool}"),
        json!({"enabled": enabled}),
    )
}

fn expect_stored(world: &mut World, key: &'static str, value: bool) -> Outcome {
    world.wait_for_with(
        |w| {
            w.mc.peek::<crate::steps::settings::FakeConfig>()
                .is_some_and(|c| c.settings.get(key) == Some(&json!(value)))
        },
        |w| {
            format!(
                "{key} to be stored as {}; the section is {}",
                if value { "on" } else { "off" },
                show(&section(w))
            )
        },
    )?;
    let tool = if key == "enableDeviceSupport" {
        "hub"
    } else {
        "agent"
    };
    world.wait_for_with(
        |w| at(&section(w), &format!("{tool}.on")) == value,
        |w| {
            format!(
                "the switch to show it; the section is {}",
                show(&section(w))
            )
        },
    )
}

fn has_toast(world: &World, title: &str, description: &str) -> bool {
    at(&world.state("toasts"), "items")
        .as_array()
        .is_some_and(|items| {
            items
                .iter()
                .any(|t| t["title"] == title && t["description"] == description)
        })
}

pub fn register(steps: &mut Steps) {
    steps.extension(serve_devices);
    steps.extension(serve_slack);

    // The section opens once the scenario's Givens have shaped the MC (ready()).
    steps.step(
        "the user has opened the Integrations settings",
        |_, _, _| Ok(()),
    );

    steps.step("the device hub is on", |world, _, _| {
        save_elsewhere(&mut world.mc, "enableDeviceSupport", json!(true), true);
        Ok(())
    });
    steps.step("agent device access is on", |world, _, _| {
        save_elsewhere(&mut world.mc, "enableAgentDeviceAccess", json!(true), true);
        Ok(())
    });
    steps.step("the user turns on the device hub", |world, _, _| {
        turn(world, "hub", true)
    });
    steps.step("the user turns off the device hub", |world, _, _| {
        turn(world, "hub", false)
    });
    steps.step("the user turns on agent device access", |world, _, _| {
        turn(world, "agent", true)
    });
    steps.step("the user turns off agent device access", |world, _, _| {
        turn(world, "agent", false)
    });
    // The C++ pattern repeats its first capture; the regex engine has no
    // backreferences, so the two words are compared here.
    steps.step(
        "agent device access is stored as (on|off) and shown as (on|off)",
        |world, c, _| {
            expect!(c[0] == c[1], "stored as {} but shown as {}", c[0], c[1]);
            expect_stored(world, "enableAgentDeviceAccess", c[0] == "on")
        },
    );
    steps.step("the device hub is stored as on", |world, _, _| {
        expect_stored(world, "enableDeviceSupport", true)
    });
    steps.step("the device hub is stored as off", |world, _, _| {
        expect_stored(world, "enableDeviceSupport", false)
    });
    steps.step("agent device access is stored as off", |world, _, _| {
        expect_stored(world, "enableAgentDeviceAccess", false)
    });
    steps.step(
        &format!("the user is told device settings were not saved on all environments and could not update {Q}"),
        |world, c, _| {
            let name = c[0].clone();
            world.wait_for_with(
                |w| has_toast(w, "Device settings not saved on all environments", &format!("Could not update {name}.")),
                |w| format!("the failed save to be reported; the shell shows {}", show(&w.state("toasts"))),
            )?;
            let laptop = document_of(&mut world.mc, "Laptop").settings.get("enableDeviceSupport") == Some(&json!(true));
            let here = fake_config(&mut world.mc).settings.get("enableDeviceSupport") == Some(&json!(true));
            expect!(laptop && here, "the other environments to have saved it");
            Ok(())
        },
    );

    steps.step("the device tools are still being checked", |world, _, _| {
        ready(world)?;
        world.mc.hold("device");
        world.dispatch("deviceSettings.check", json!({}))?;
        world.wait_for_with(
            |w| section(w)["pending"] == "check",
            |w| {
                format!(
                    "the check to be running; the section is {}",
                    show(&section(w))
                )
            },
        )
    });
    steps.step(
        "the user leaves the Integrations settings and comes back",
        |world, _, _| {
            world.with::<Navigation, _>(|n, engine| {
                n.open(engine, Route::Settings("/settings/general".into()))
            })?;
            world.wait_for_with(
                |w| section(w)["open"] != true,
                |w| {
                    format!(
                        "the device settings to close; they are {}",
                        show(&section(w))
                    )
                },
            )?;
            world.mc.answer_held();
            ready(world)
        },
    );
    steps.step("the device hub can be changed again", |world, _, _| {
        world.wait_for_with(
            |w| {
                let section = section(w);
                text(&section["pending"]).is_empty() && at(&section, "hub.enabled") == true
            },
            |w| {
                format!(
                    "the hub switch to be free; the section is {}",
                    show(&section(w))
                )
            },
        )?;
        turn(world, "hub", true)?;
        expect_stored(world, "enableDeviceSupport", true)
    });

    steps.step("the device hub tool update fails", |world, _, _| {
        let environment = world.mc.environment_id.clone();
        let fake = world.mc.part::<FakeDevices>();
        fake.outdated.insert(environment);
        fake.fail_updates = true;
        Ok(())
    });
    steps.step("the user updates the device hub tool", |world, _, _| {
        ready(world)?;
        world.wait_for_with(
            |w| at(&section(w), "hub.update") == "Update to v1.4.0",
            |w| {
                format!(
                    "an update to be offered; the section is {}",
                    show(&section(w))
                )
            },
        )?;
        world.dispatch("deviceSettings.update", json!({"tool": "hub"}))
    });
    steps.step(
        "the user is told to check this host's network connection and try again",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let section = section(w);
                    at(&section, "updateError.tool") == "hub"
                        && text(at(&section, "updateError.message"))
                            .contains("Check this host's network connection and try again")
                },
                |w| {
                    format!(
                        "the failed update to be explained; the section is {}",
                        show(&section(w))
                    )
                },
            )
        },
    );

    steps.step(
        &format!("the user is editing settings across {Q} and {Q}"),
        |world, c, _| {
            // This machine is the first; the other is another member of the cluster.
            world.mc.label = c[0].clone();
            fake_config(&mut world.mc)
                .elsewhere
                .insert(c[1].clone(), Map::new());
            document_of(&mut world.mc, &c[1])
                .settings
                .insert("enableDeviceSupport".into(), json!(true));
            world.mc.join_named(&c[1]);
            save_elsewhere(&mut world.mc, "enableDeviceSupport", json!(true), true);
            ready(world)?;
            world.dispatch("settingsScope.environment", json!({"id": ""}))
        },
    );
    steps.step("the user looks at simulator support", |world, _, _| {
        world.wait_for_with(
            |w| {
                section(w)["platforms"]
                    .as_array()
                    .is_some_and(|p| p.len() == 2)
            },
            |w| {
                format!(
                    "simulator support to show; the section is {}",
                    show(&section(w))
                )
            },
        )
    });
    steps.step(
        &format!("the iOS and Android status of {Q} is shown"),
        |world, c, _| {
            let name = c[0].clone();
            world.wait_for_with(
                |w| text(&section(w)["statusNote"]).starts_with(&format!("Status for {name}.")),
                |w| {
                    format!(
                        "the status to be {name}'s; the section is {}",
                        show(&section(w))
                    )
                },
            )?;
            let section = section(world);
            let platforms = section["platforms"].as_array().cloned().unwrap_or_default();
            expect!(
                platforms.len() == 2
                    && platforms[0]["platform"] == "iOS"
                    && platforms[0]["ready"] == true
                    && platforms[1]["platform"] == "Android"
                    && platforms[1]["message"] == "The Android SDK was not found.",
                "this machine's iOS and Android status; the section is {}",
                show(&section)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told to select an environment to inspect its simulator support",
        |world, _, _| {
            let section = section(world);
            expect!(
                text(&section["statusNote"])
                    .ends_with("Select an environment to inspect its simulator support."),
                "the note; the section is {}",
                show(&section)
            );
            Ok(())
        },
    );

    steps.step("Slack is connected", |world, _, _| {
        *world.mc.part::<FakeSlack>() = FakeSlack {
            bot_token: BOT_TOKEN.into(),
            app_token: APP_TOKEN.into(),
            state: "connected".into(),
            error: String::new(),
        };
        Ok(())
    });
    steps.step(
        "the user enters a Slack bot token and app token and connects",
        |world, _, _| slack_connect(world, BOT_TOKEN),
    );
    steps.step(
        "the user connects Slack with a bot token Slack refuses",
        |world, _, _| slack_connect(world, REFUSED_BOT),
    );
    steps.step(
        &format!("Slack shows as connected to the workspace {Q} as the bot {Q}"),
        |world, c, _| {
            let (team, bot) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                |w| {
                    let slack = slack_section(w);
                    slack["state"] == "connected"
                        && slack["team"] == team
                        && slack["bot"] == bot
                        && text(&slack["pending"]).is_empty()
                },
                |w| {
                    format!(
                        "Slack to show as connected; the section is {}",
                        show(&slack_section(w))
                    )
                },
            )
        },
    );
    steps.step(
        "the tokens show as set but are never shown again",
        |world, _, _| {
            let fake = world.mc.part::<FakeSlack>();
            expect!(
                fake.bot_token == BOT_TOKEN && fake.app_token == APP_TOKEN,
                "the MC to have been given both tokens"
            );
            let slack = slack_section(world);
            let shown = show(&slack);
            expect!(
                slack["tokensSet"] == true
                    && !shown.contains(BOT_TOKEN)
                    && !shown.contains(APP_TOKEN),
                "the tokens to show only as set; the section is {shown}"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("Slack shows as not connected with Slack's reason {Q}"),
        |world, c, _| {
            let reason = c[0].clone();
            world.wait_for_with(
                |w| {
                    let slack = slack_section(w);
                    slack["state"] == "failed"
                        && text(&slack["error"]).ends_with(&reason)
                        && slack["tokensSet"] != true
                        && text(&slack["pending"]).is_empty()
                },
                |w| {
                    format!(
                        "Slack to show Slack's reason; the section is {}",
                        show(&slack_section(w))
                    )
                },
            )
        },
    );
    steps.step("the user disconnects Slack", |world, _, _| {
        slack_ready(world)?;
        world.wait_for_with(
            |w| {
                let slack = slack_section(w);
                slack["tokensSet"] == true && slack["editable"] == true
            },
            |w| {
                format!(
                    "Slack to be connected; the section is {}",
                    show(&slack_section(w))
                )
            },
        )?;
        world.dispatch("slackSettings.disconnect", json!({}))
    });
    steps.step("Slack shows as not connected", |world, _, _| {
        world.wait_for_with(
            |w| {
                let slack = slack_section(w);
                slack["state"] == "off"
                    && text(&slack["team"]).is_empty()
                    && text(&slack["pending"]).is_empty()
            },
            |w| {
                format!(
                    "Slack to show as not connected; the section is {}",
                    show(&slack_section(w))
                )
            },
        )
    });
    steps.step("the tokens are forgotten", |world, _, _| {
        let forgotten = world.mc.part::<FakeSlack>().bot_token.is_empty()
            && slack_section(world)["tokensSet"] != true;
        expect!(
            forgotten,
            "the tokens to be gone; the section is {}",
            show(&slack_section(world))
        );
        Ok(())
    });
    // The MC tells its plugins (mix features proves that); here, that the MC was asked.
    steps.step("plugins are told Slack is not connected", |world, _, _| {
        expect!(
            world
                .mc
                .calls
                .iter()
                .any(|rpc| rpc.method == "slack.disconnect"),
            "the MC to have been asked to disconnect Slack"
        );
        Ok(())
    });
    steps.step("the user opens the Slack section", |world, _, _| {
        world.set_clipboard("");
        slack_ready(world)
    });
    steps.step(
        "the MC cannot reach the environment's Slack connection",
        |world, _, _| {
            world.mc.part::<SlackUnreachable>().reason = UNREACHABLE.into();
            Ok(())
        },
    );
    steps.step(
        "the user is told Slack could not load, and why",
        |world, _, _| {
            let slack = slack_section(world);
            expect!(
                slack["failed"] == true
                    && slack["error"] == UNREACHABLE
                    && slack["loaded"] != true
                    && slack["editable"] != true,
                "Slack to have failed to load with the MC's reason; the section is {}",
                show(&slack)
            );
            Ok(())
        },
    );
    steps.step(
        "the MC can reach it again and the user tries again",
        |world, _, _| {
            world.mc.part::<SlackUnreachable>().reason.clear();
            world.dispatch("slackSettings.retry", json!({}))
        },
    );
    steps.step(
        "it offers to copy a Slack app manifest with the scopes, events and Socket Mode HAL-C2 needs",
        |world, _, _| {
            world.dispatch("slackSettings.copyManifest", json!({}))?;
            world.wait_for_with(
                |w| w.clipboard() == MANIFEST,
                |w| format!("the manifest to be copied; the clipboard holds {}", w.clipboard()),
            )?;
            let copied = world.clipboard();
            for needed in [
                "app_mentions:read",
                "chat:write",
                "commands",
                "app_mention",
                "socket_mode_enabled: true",
            ] {
                expect!(copied.contains(needed), "the manifest to name {needed}");
            }
            world.wait_for_with(
                |w| {
                    at(&w.state("toasts"), "items")
                        .as_array()
                        .is_some_and(|items| items.iter().any(|t| t["title"] == "Slack app manifest copied"))
                },
                |w| format!("the copy to be confirmed; the shell shows {}", show(&w.state("toasts"))),
            )
        },
    );
}
