//! Bringing a server up to this app's version (ServerUpdateController):
//! the offer in the window's ConnectionNotice, Update all and each
//! machine's action in Connections settings (ServerUpdatesList,
//! ServerUpdateAction), against the fake MC's descriptors
//! (features/settings/updates.feature, Rule "Updating a server").
//! "server" is the MC's own environment; any other machine is a member
//! of its cluster. desktop-qt's UpdateServerSteps.cpp.

use std::collections::HashMap;

use hal_c2_shell::controllers::connection_health::ConnectionHealth;
use hal_c2_shell::controllers::server_updates::ServerUpdates;
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::expect;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, show};
use crate::world::World;

const OWN: &str = "server";
const BEHIND: &str = "1.3.0";
const METHOD: &str = "server.updateServer";

/// What the scenario said of the app and the server's answers.
#[derive(Clone)]
struct Updates {
    app_version: String,
    machine: String,
    /// How `server.updateServer` answers, by environment id: the
    /// version it reconnected on, or "!" and why it failed. None: held.
    answers: HashMap<String, String>,
    held: Vec<Rpc>,
}

impl Default for Updates {
    fn default() -> Updates {
        Updates {
            app_version: "1.4.0".into(),
            machine: String::new(),
            answers: HashMap::new(),
            held: Vec::new(),
        }
    }
}

/// The brick the scenario is looking at.
#[derive(Default)]
struct Shown(Option<Brick>);

fn updates(world: &mut World) -> &mut Updates {
    world.mc.part::<Updates>()
}

fn id_of(world: &World, name: &str) -> String {
    if name == OWN {
        world.mc.environment_id.clone()
    } else {
        name.to_owned()
    }
}

fn set_app_version(world: &mut World) -> Outcome {
    let version = updates(world).app_version.clone();
    world.with::<ConnectionHealth, _>(|health, engine| {
        health.set_client_version(engine, &version);
    })?;
    world.with::<ServerUpdates, _>(|updates, engine| updates.refresh(engine))?;
    Ok(())
}

fn server_updates(world: &World) -> Value {
    world.state("serverUpdates")
}

fn machine(world: &World, name: &str) -> Option<Value> {
    let id = id_of(world, name);
    server_updates(world)["machines"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|machine| machine["environmentId"] == id.as_str())
        .cloned()
}

fn describe(world: &World) -> String {
    format!(
        "serverUpdates is {}; confirmation {}; toasts {}",
        show(&server_updates(world)),
        show(&world.state("confirmation")),
        show(&world.state("toasts"))
    )
}

/// Says what `name`'s descriptor offers, the shell connected and
/// hearing it. self_update: the `serverSelfUpdate` capability, empty
/// for a checkout.
fn describe_machine(
    world: &mut World,
    name: &str,
    version: &str,
    self_update: &str,
    desktop_app_update: bool,
) -> Outcome {
    let mut capabilities = json!({"desktopAppUpdate": desktop_app_update});
    if !self_update.is_empty() {
        capabilities["serverSelfUpdate"] = json!(self_update);
    }
    let id = id_of(world, name);
    world.mc.descriptor_fields.insert(
        id.clone(),
        json!({"serverVersion": version, "capabilities": capabilities}),
    );
    updates(world).machine = name.to_owned();
    if name == OWN && world.mc.label.is_empty() {
        world.mc.label = OWN.into();
    }
    if world.shell_subscriptions() < 1 {
        world.connect()?;
    } else if name == OWN {
        world.mc.announce_environment();
    } else {
        world
            .mc
            .peer_labels
            .insert(name.to_owned(), name.to_owned());
        world.mc.join(&format!("mc-{name}"), name);
    }
    if name != OWN && !world.mc.members.iter().any(|member| member == name) {
        world.mc.join_named(name);
    }
    world.sync()?;
    set_app_version(world)?;
    let (name, version) = (name.to_owned(), version.to_owned());
    world.wait_for_with(
        |w| machine(w, &name).is_some_and(|machine| machine["version"] == version.as_str()),
        |w| format!("{name} on {version}; {}", describe(w)),
    )
}

/// The scenario's machine, behind and updating itself, unless a step
/// described it already.
fn ensure_machine(world: &mut World, name: &str, self_update: &str) -> Outcome {
    if !world.mc.descriptor_fields.contains_key(&id_of(world, name)) {
        return describe_machine(world, name, BEHIND, self_update, true);
    }
    Ok(())
}

/// One machine's offer as Connections settings shows it.
fn action(world: &mut World, name: &str) -> Outcome<Brick> {
    let brick = Brick::new(
        world,
        &format!(
            "import QtQuick\nimport HalC2.Bricks\nItem {{ ServerUpdateAction {{ environmentId: \"{}\" }} }}\n",
            id_of(world, name)
        ),
        600.0,
        120.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

/// The window's connection notice, its panel opened as soon as it shows,
/// as a click on its icon would.
fn notice(world: &mut World) -> Outcome<Brick> {
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nItem { ConnectionNotice {\n onVisibleChanged: if (visible) open = true\n Component.onCompleted: if (visible) open = true\n }\n}\n",
        900.0,
        600.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

fn shown(world: &World) -> Brick {
    world
        .peek_part::<Shown>()
        .and_then(|shown| shown.0)
        .expect("a brick")
}

fn visible(world: &World, brick: Brick, object_name: &str) -> bool {
    brick
        .find(world, object_name)
        .ok()
        .flatten()
        .is_some_and(|item| brick.flag(world, item, "visible"))
}

fn click_update(world: &mut World, name: &str) -> Outcome {
    let brick = action(world, name)?;
    expect!(
        visible(world, brick, "serverUpdateButton"),
        "no update is offered for {name}; {}",
        describe(world)
    );
    brick.click(world, "serverUpdateButton")
}

fn update_calls(world: &World) -> Vec<Rpc> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == METHOD)
        .cloned()
        .collect()
}

fn toast_items(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn wait_for_toast(world: &mut World, title: &str) -> Outcome<Value> {
    let wanted = title.to_owned();
    world.wait_for_with(
        |w| {
            toast_items(w)
                .iter()
                .any(|item| item["title"] == wanted.as_str())
        },
        |w| format!("the toast \"{wanted}\"; {}", describe(w)),
    )?;
    Ok(toast_items(world)
        .into_iter()
        .find(|item| item["title"] == title)
        .unwrap_or(Value::Null))
}

fn question(world: &mut World) -> Outcome<Value> {
    world.wait_for_with(
        |w| w.state("confirmation").is_object(),
        |w| format!("a question; {}", describe(w)),
    )?;
    Ok(world.state("confirmation"))
}

fn answer(world: &mut World, accepted: bool) -> Outcome {
    let asked = question(world)?;
    world.dispatch(
        "confirmation.answer",
        json!({"requestId": asked["requestId"], "accepted": accepted}),
    )
}

fn extend(mc: &mut FakeMc) {
    mc.on_rpc(METHOD, |mc, rpc: &Rpc| {
        let environment = if rpc.environment.is_empty() {
            mc.environment_id.clone()
        } else {
            rpc.environment.clone()
        };
        let held = {
            let updates = mc.part::<Updates>();
            match updates.answers.get(&environment).cloned() {
                None => {
                    updates.held.push(rpc.clone());
                    None
                }
                Some(answer) => Some(answer),
            }
        };
        if let Some(answer) = held {
            if let Some(reason) = answer.strip_prefix('!') {
                mc.refuse(rpc, reason);
            } else {
                mc.reply(
                    rpc,
                    json!({"targetVersion": answer, "method": "hot-upgrade"}),
                );
            }
        }
        Ok(())
    });
}

pub fn register(steps: &mut Steps) {
    steps.extension(extend);

    // The offer in the conversation.
    steps.step(
        &format!("the app is newer than the server on {Q}"),
        |world, c, _| describe_machine(world, &c[0].clone(), BEHIND, "boot-service", true),
    );
    steps.step(&format!("the user opens a thread on {Q}"), |world, c, _| {
        expect!(c[0] == OWN, "threads here are on the MC's own environment");
        // The notice stands over every view of the window, the thread's included.
        notice(world)?;
        Ok(())
    });
    steps.step(
        &format!("the user is offered to update {Q}"),
        |world, c, _| {
            let brick = shown(world);
            world.wait_for_with(|w| visible(w, brick, "serverUpdateButton"), describe)?;
            let warning = world.state("connection")["versionWarning"].clone();
            let button = brick.item(world, "serverUpdateButton")?;
            expect!(
                brick.shows(world, &crate::harness::text(&warning["text"]))?
                    && crate::harness::text(&warning["text"]).contains(&c[0])
                    && brick.text_of(world, button, "text") == "Update server",
                "the notice is {}; {}",
                show(&warning),
                describe(world)
            );
            Ok(())
        },
    );

    // Updating one.
    steps.step(&format!("{Q} is behind the app"), |world, c, _| {
        describe_machine(world, &c[0].clone(), BEHIND, "boot-service", true)
    });
    steps.step(
        &format!("the user updates {Q} and it reconnects on {Q}"),
        |world, c, _| {
            updates(world).app_version = c[1].clone();
            ensure_machine(world, &c[0].clone(), "boot-service")?;
            set_app_version(world)?;
            let id = id_of(world, &c[0]);
            updates(world).answers.insert(id, c[1].clone());
            click_update(world, &c[0].clone())
        },
    );
    steps.step(
        &format!("the user is told {Q} was updated and reconnected on {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &format!("{} updated", c[0]))?;
            expect!(
                toast["type"] == "success"
                    && toast["description"] == format!("Reconnected on hal-c2@{}.", c[1]).as_str(),
                "the toast is {}",
                show(&toast)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user updates {Q} and the update fails with {Q}"),
        |world, c, _| {
            ensure_machine(world, &c[0].clone(), "boot-service")?;
            let id = id_of(world, &c[0]);
            updates(world).answers.insert(id, format!("!{}", c[1]));
            click_update(world, &c[0].clone())
        },
    );
    steps.step(
        &format!("{Q} keeps running on its current version"),
        |world, c, _| {
            world.sync()?;
            let now = machine(world, &c[0]);
            // Still behind, offered again, and not stuck updating.
            let brick = action(world, &c[0].clone())?;
            expect!(
                now.as_ref().is_some_and(|machine| {
                    machine["version"] == BEHIND
                        && machine["behind"] == json!(true)
                        && machine["updating"] != json!(true)
                }) && visible(world, brick, "serverUpdateButton"),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // A desktop app's server.
    steps.step(
        &format!("{Q} is served by the desktop app on that machine(?: and is behind)?"),
        |world, c, _| describe_machine(world, &c[0].clone(), BEHIND, "desktop-managed", true),
    );
    steps.step(
        "this client cannot update that desktop app",
        |world, _, _| {
            let name = updates(world).machine.clone();
            describe_machine(world, &name, BEHIND, "desktop-managed", false)
        },
    );
    steps.step(
        &format!("the user updates the server on {Q}"),
        |world, c, _| {
            ensure_machine(world, &c[0].clone(), "boot-service")?;
            click_update(world, &c[0].clone())
        },
    );
    steps.step(
        &format!("the user is asked to confirm the desktop app on {Q} will close and relaunch"),
        |world, c, _| {
            let asked = question(world)?;
            expect!(
                crate::harness::text(&asked["title"]).contains(&c[0])
                    && asked["description"] == "It will close and relaunch on that machine."
                    && update_calls(world).is_empty(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("nothing is updated", |world, _, _| {
        world.sync()?;
        let name = updates(world).machine.clone();
        let now = machine(world, &name);
        expect!(
            update_calls(world).is_empty()
                && now.is_some_and(|machine| machine["updating"] != json!(true)),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user looks at the update offer for {Q}"),
        |world, c, _| {
            action(world, &c[0].clone())?;
            Ok(())
        },
    );
    steps.step(
        "the user is told to update the desktop app on that machine to update the server",
        |world, _, _| {
            let brick = shown(world);
            expect!(
                brick.shows(
                    world,
                    "Update the desktop app on that machine to update this server."
                )?,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("no update button is offered", |world, _, _| {
        expect!(
            !visible(world, shown(world), "serverUpdateButton"),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user updates {Q} and its desktop app relaunches on {Q}"),
        |world, c, _| {
            updates(world).app_version = c[1].clone();
            ensure_machine(world, &c[0].clone(), "desktop-managed")?;
            set_app_version(world)?;
            let id = id_of(world, &c[0]);
            updates(world).answers.insert(id, c[1].clone());
            click_update(world, &c[0].clone())?;
            answer(world, true)
        },
    );
    steps.step(
        &format!("the user is told {Q} was updated and the desktop app relaunched on {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &format!("{} updated", c[0]))?;
            expect!(
                toast["type"] == "success"
                    && toast["description"]
                        == format!("Desktop app relaunched on {}.", c[1]).as_str(),
                "the toast is {}",
                show(&toast)
            );
            Ok(())
        },
    );

    // Update all.
    steps.step(
        &format!("{Q} is hosted by the desktop app and {Q} is a service"),
        |world, c, _| {
            describe_machine(world, &c[1].clone(), BEHIND, "boot-service", true)?;
            describe_machine(world, &c[0].clone(), BEHIND, "desktop-managed", true)
        },
    );
    steps.step("the user updates all machines", |world, _, _| {
        let brick = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\nItem { ServerUpdatesList { width: 600 } }\n",
            600.0,
            300.0,
        )?;
        world.part::<Shown>().0 = Some(brick);
        expect!(
            visible(world, brick, "serverUpdatesAll"),
            "{}",
            describe(world)
        );
        brick.click(world, "serverUpdatesAll")
    });
    steps.step(
        &format!("the user is asked to confirm that the desktop app on {Q} will relaunch"),
        |world, c, _| {
            let asked = question(world)?;
            expect!(
                crate::harness::text(&asked["title"]).contains(&c[0])
                    && asked["description"] == "They will close and relaunch on those machines."
                    && update_calls(world).is_empty(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} updates independently of {Q}"),
        |world, c, _| {
            answer(world, true)?;
            world.wait_for_with(
                |w| {
                    w.mc.peek::<Updates>()
                        .is_some_and(|updates| updates.held.len() == 2)
                },
                |w| format!("both updates to start; {}", describe(w)),
            )?;
            // The service answers while the desktop app is still on its way.
            let own = id_of(world, &c[0]);
            let held = updates(world).held.clone();
            let app_version = updates(world).app_version.clone();
            for rpc in &held {
                let environment = if rpc.environment.is_empty() {
                    world.mc.environment_id.clone()
                } else {
                    rpc.environment.clone()
                };
                if environment == own {
                    world.mc.reply(rpc, json!({"targetVersion": app_version}));
                }
            }
            wait_for_toast(world, &format!("{} updated", c[0]))?;
            let other = machine(world, &c[1]);
            expect!(
                other
                    .as_ref()
                    .is_some_and(|machine| machine["updating"] == json!(true))
                    && machine(world, &c[0])
                        .is_some_and(|machine| machine["updating"] != json!(true)),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // The command for a server started by hand.
    steps.step(
        &format!("the user copies the update command for {Q}"),
        |world, c, _| {
            ensure_machine(world, &c[0].clone(), "")?;
            let brick = action(world, &c[0].clone())?;
            let button = brick.item(world, "serverUpdateButton")?;
            expect!(
                visible(world, brick, "serverUpdateButton")
                    && brick.text_of(world, button, "text") == "Copy update command",
                "{}",
                describe(world)
            );
            brick.click(world, "serverUpdateButton")
        },
    );
    steps.step(
        "the command for the matching version is on the clipboard",
        |world, _, _| {
            let wanted = format!("npx hal-c2@{}", updates(world).app_version);
            expect!(
                world.clipboard() == wanted,
                "the clipboard holds {}",
                world.clipboard()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user sees an? {Q} toast {Q} saying to run the command on {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[1])?;
            let app_version = updates(world).app_version.clone();
            expect!(
                toast["type"] == c[0].as_str()
                    && toast["description"]
                        == format!("Run `npx hal-c2@{app_version}` on {} to update it.", c[2])
                            .as_str(),
                "the toast is {}",
                show(&toast)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user sees an? {Q} toast {Q} with the reason"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[1])?;
            expect!(
                toast["type"] == c[0].as_str()
                    && crate::harness::text(&toast["description"])
                        .starts_with("The clipboard could not be written."),
                "the toast is {}",
                show(&toast)
            );
            Ok(())
        },
    );

    // Dismissing the notice.
    steps.step(
        &format!("the user dismissed the update notice for {Q}"),
        |world, c, _| {
            updates(world).app_version = c[0].clone();
            describe_machine(world, OWN, BEHIND, "boot-service", true)?;
            let brick = notice(world)?;
            world.wait_for_with(|w| visible(w, brick, "connectionDismissWarning"), describe)?;
            brick.click(world, "connectionDismissWarning")
        },
    );
    steps.step("the user reconnects to the same server", |world, _, _| {
        world.restart()?;
        world.connect()?;
        world.sync()?;
        set_app_version(world)?;
        world.wait_for_with(
            |w| w.state("connection")["phase"] == "connected",
            |w| show(&w.state("connection")),
        )
    });
    steps.step(
        &format!("the notice for {Q} does not return"),
        |world, c, _| {
            world.sync()?;
            let warning = world.state("connection")["versionWarning"].clone();
            let brick = notice(world)?;
            expect!(
                updates(world).app_version == c[0]
                    && warning.is_null()
                    && !visible(world, brick, "connectionNotice"),
                "the notice is {}",
                show(&warning)
            );
            Ok(())
        },
    );
    steps.step(&format!("a notice for {Q} does appear"), |world, c, _| {
        updates(world).app_version = c[0].clone();
        set_app_version(world)?;
        let brick = notice(world)?;
        world.wait_for_with(
            |w| visible(w, brick, "connectionNotice") && visible(w, brick, "serverUpdateButton"),
            describe,
        )?;
        expect!(
            world.state("connection")["versionWarning"]["clientVersion"] == c[0].as_str(),
            "{}",
            describe(world)
        );
        Ok(())
    });
}
