//! Load balancing on the desktop (features/settings/load-balancing.feature,
//! its settings in connections/environments.feature, and its search result in
//! settings/search-and-navigation.feature): a new thread's first send asks the
//! MC where it starts (`hal-c2.placeThread`) and launches it there, and the
//! Connections page's "Load balancing" group keeps what the MC chooses by in
//! the MC's settings document (desktop-qt's LoadBalancingSteps.cpp).
//!
//! The choosing is the MC's (apps/server-ex, HalC2.LoadBalancing): the fake
//! answers what the scenario says of the machines, and the steps check where
//! the shell then launched the thread.

use std::rc::Rc;

use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::Value as JsValue;
use serde_json::{Map, Value, json};

use super::launch::FakeLaunches;
use super::settings::{fake_config, save_elsewhere};
use crate::brick::{Brick, Shown, shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const SERVER: &str = "server";
const PROMPT: &str = "Add tax to the cart";
const ENABLED: &str = "loadBalancingEnabled";
const WEIGHTS: &str = "loadBalancingWeights";

/// What the scenario says of the machines, and what the MC was asked.
#[derive(Default)]
pub struct FakePlacement {
    /// The project every machine has a checkout of, by its name.
    pub project: String,
    /// The machine the MC starts a new thread on in place of the user's pick:
    /// the one the scenario gives more room, while balancing is on and that
    /// machine is up and has a checkout.
    pub elsewhere: String,
    /// The draft is tied to its machine, so the MC is not to be asked.
    pub tied: bool,
    /// Every `hal-c2.placeThread`, in order.
    pub asked: Vec<Rpc>,
}

fn placement(world: &mut World) -> &mut FakePlacement {
    world.mc.part::<FakePlacement>()
}

fn repository_of(project: &str) -> String {
    format!("github.com/acme/{project}")
}

/// The id of `machine`'s checkout of the shared project `name`.
fn checkout_id(mc: &FakeMc, machine: &str, name: &str) -> String {
    if machine == mc.environment_id {
        name.to_owned()
    } else {
        format!("{name}-on-{machine}")
    }
}

/// Whether the member `machine` lists a checkout of the shared project `name`.
fn has_checkout(mc: &FakeMc, machine: &str, name: &str) -> bool {
    mc.peer_rows
        .get(machine)
        .and_then(|rows| rows.get(&checkout_id(mc, machine, name)))
        .is_some_and(|row| {
            row[2]["repositoryIdentity"]["canonicalKey"] == json!(repository_of(name))
        })
}

/// `hal-c2.placeThread`, asked of the MC the shell is connected to: the
/// user's pick, or the checkout of the machine the scenario gives more room.
fn extend(mc: &mut FakeMc) {
    mc.on_rpc("hal-c2.placeThread", |mc, rpc| {
        mc.part::<FakePlacement>().asked.push(rpc.clone());
        let elsewhere = mc.part::<FakePlacement>().elsewhere.clone();
        let project = mc.part::<FakePlacement>().project.clone();
        let balancing = fake_config(mc).settings.get(ENABLED) == Some(&json!(true));
        if balancing && !mc.offline.contains(&elsewhere) && has_checkout(mc, &elsewhere, &project) {
            let project_id = checkout_id(mc, &elsewhere, &project);
            mc.reply(
                rpc,
                json!({"environmentId": elsewhere, "projectId": project_id}),
            );
            return Ok(());
        }
        mc.reply(
            rpc,
            json!({
                "environmentId": rpc.payload["environmentId"],
                "projectId": rpc.payload["projectId"],
            }),
        );
        Ok(())
    });
}

/// The MC's own machine and one member, each known by its name.
fn cluster(mc: &mut FakeMc, own: &str, member: &str) {
    mc.environment_id = own.to_owned();
    mc.name = format!("mc-{own}");
    mc.label = own.to_owned();
    mc.join_named(member);
}

fn connected(world: &mut World) -> Outcome {
    if world.mc.connections.is_empty() {
        world.connect()?;
    }
    world.sync()
}

fn weights(world: &World) -> Value {
    world
        .mc
        .peek::<super::settings::FakeConfig>()
        .and_then(|config| config.settings.get(WEIGHTS).cloned())
        .unwrap_or_else(|| json!({}))
}

fn balancing(world: &World) -> Value {
    world.state("loadBalancing")
}

/// The Connections page over the shell, which can also say what a settings
/// search finds (settingsPages.js, as SettingsNav.qml asks it).
fn page(world: &mut World, width: f64, height: f64) -> Outcome<Brick> {
    if world.part::<Shown>().0.is_none() {
        let brick = Brick::new(
            world,
            &format!(
                "import QtQuick\nimport HalC2.Bricks\nimport HalC2.Shell\n\
                 import \"qrc:/hal-c2/settings/settingsPages.js\" as Pages\n\
                 ConnectionsSettings {{\n\
                   width: {width}; height: {height}\n\
                   function results(query) {{ return Pages.searchRows(query, Shell.state, []); }}\n\
                 }}\n"
            ),
            width,
            height,
        )?;
        world.part::<Shown>().0 = Some(brick);
    }
    shown(world)
}

fn page_default(world: &mut World) -> Outcome<Brick> {
    page(world, 820.0, 700.0)
}

/// The user opens Settings → Connections; the group is there once the shell
/// has read the MC's settings and lists more than one machine.
fn open_connections(world: &mut World, height: f64) -> Outcome<Brick> {
    connected(world)?;
    world.dispatch("connections.open", json!({}))?;
    world.sync()?;
    expect!(
        text(at(&world.state("route"), "section")) == "/settings/connections",
        "the route is {}",
        show(&world.state("route"))
    );
    page(world, 820.0, height)
}

fn group_visible(world: &mut World) -> Outcome<bool> {
    let brick = page_default(world)?;
    let group = brick.item(world, "load-balancing")?;
    Ok(brick.flag(world, group, "visible"))
}

fn group_open(world: &mut World) -> Outcome<bool> {
    let brick = page_default(world)?;
    let group = brick.item(world, "load-balancing")?;
    Ok(brick.flag(world, group, "open"))
}

fn body_visible(world: &mut World) -> Outcome<bool> {
    let brick = page_default(world)?;
    let body = brick.item(world, "loadBalancingBody")?;
    Ok(brick.flag(world, body, "visible"))
}

fn wait_for_group(world: &mut World) -> Outcome {
    let mut seen = false;
    world.wait_for_with(
        |w| {
            // The group is read through the brick, which needs the world.
            let _ = &mut seen;
            balancing(w)["ready"] == json!(true)
        },
        |w| {
            format!(
                "the Load balancing group; the shell publishes {}",
                show(&w.state("loadBalancing"))
            )
        },
    )?;
    world.wait_for("the Load balancing group to show", group_visible_now)
}

/// Whether the group shows, for a wait that only reads.
fn group_visible_now(world: &World) -> bool {
    let Some(brick) = world.peek_part::<Shown>().and_then(|shown| shown.0) else {
        return false;
    };
    brick
        .find(world, "load-balancing")
        .ok()
        .flatten()
        .is_some_and(|group| brick.flag(world, group, "visible"))
}

fn unfold(world: &mut World) -> Outcome {
    wait_for_group(world)?;
    if !group_open(world)? {
        page_default(world)?.click(world, "loadBalancingFold")?;
    }
    world.wait_for("the group to open", body_shown)
}

fn body_shown(world: &World) -> bool {
    let Some(brick) = world.peek_part::<Shown>().and_then(|shown| shown.0) else {
        return false;
    };
    brick
        .find(world, "loadBalancingBody")
        .ok()
        .flatten()
        .is_some_and(|body| brick.flag(world, body, "visible"))
}

/// The preference `machine`'s row shows.
fn preference(world: &World, machine: &str) -> String {
    let Some(brick) = world.peek_part::<Shown>().and_then(|shown| shown.0) else {
        return String::new();
    };
    brick
        .find(world, &format!("loadPreference:{machine}"))
        .ok()
        .flatten()
        .map(|row| brick.text_of(world, row, "displayText"))
        .unwrap_or_default()
}

/// Whether the group's header is within the page's view.
fn in_view(world: &World) -> bool {
    let Some(brick) = world.peek_part::<Shown>().and_then(|shown| shown.0) else {
        return false;
    };
    let (Some(header), Some(root)) = (
        brick.find(world, "loadBalancingFold").ok().flatten(),
        brick.root(world),
    ) else {
        return false;
    };
    let Ok((_, top)) = brick.at(world, header, 0.0, 0.0) else {
        return false;
    };
    let number = |item, name: &str| {
        brick
            .text_of(world, item, name)
            .parse::<f64>()
            .unwrap_or(0.0)
    };
    top >= 0.0 && top + number(header, "height") <= number(root, "height")
}

/// The user flips the group's switch.
fn turn(world: &mut World, on: bool) -> Outcome {
    open_connections(world, 700.0)?;
    wait_for_group(world)?;
    page_default(world)?.click(world, "loadBalancingEnabled")?;
    world.wait_for_with(
        |w| {
            let saved =
                w.mc.peek::<super::settings::FakeConfig>()
                    .is_some_and(|config| config.settings.get(ENABLED) == Some(&json!(on)));
            saved && balancing(w)["enabled"] == json!(on)
        },
        |w| {
            let held =
                w.mc.peek::<super::settings::FakeConfig>()
                    .map(|config| Value::Object(config.settings.clone()))
                    .unwrap_or(Value::Null);
            format!(
                "load balancing to be {}; the MC holds {}",
                if on { "on" } else { "off" },
                show(&held)
            )
        },
    )
}

/// What a settings search for `query` finds.
fn results(world: &mut World, query: &str) -> Outcome<Vec<Value>> {
    let brick = page_default(world)?;
    let root = brick
        .root(world)
        .ok_or_else(|| Failure("the page has no root".into()))?;
    let found = world
        .engine()
        .invoke_by_name(
            root,
            "results",
            &[JsValue::from(query.to_lowercase().as_str())],
        )
        .map_err(|e| Failure(format!("results: {e:?}")))?;
    Ok(hal_c2_shell::json::from_value(world.engine(), &found)
        .as_array()
        .cloned()
        .unwrap_or_default())
}

fn send_first_message(world: &mut World) -> Outcome {
    world.dispatch(
        "composer.submit",
        json!({"text": PROMPT, "intent": "foreground"}),
    )
}

/// The one thread the shell launched is `machine`'s, in its checkout of the
/// shared project, after asking the MC about the user's pick (or without
/// asking, for a draft tied to its machine); the window then shows it there.
fn starts_on(world: &mut World, machine: &str) -> Outcome {
    world.wait_for("a launch; the MC got none", |w| {
        w.mc.peek::<FakeLaunches>()
            .is_some_and(|launches| !launches.calls.is_empty())
    })?;
    world.sync()?;
    let launches = world.mc.part::<FakeLaunches>();
    let (calls, machines) = (launches.calls.clone(), launches.machines.clone());
    let project = placement(world).project.clone();
    let tied = placement(world).tied;
    let asked = placement(world).asked.clone();
    let launch = calls.last().cloned().unwrap_or(Value::Null);
    expect!(
        calls.len() == 1
            && machines.last().map(String::as_str) == Some(machine)
            && launch["projectId"] == json!(checkout_id(&world.mc, machine, &project))
            && launch["initialMessage"]["text"] == json!(PROMPT),
        "the shell launched {} threads, the last on {}: {}",
        calls.len(),
        machines.last().cloned().unwrap_or_default(),
        show(&launch)
    );
    if tied {
        expect!(
            asked.is_empty(),
            "the MC was asked where to start it: {}",
            show(&asked[0].payload)
        );
    } else {
        let first = asked.first().cloned();
        let own = world.mc.environment_id.clone();
        let ok = first.as_ref().is_some_and(|rpc| {
            asked.len() == 1
                && (rpc.environment.is_empty() || rpc.environment == own)
                && rpc.payload["environmentId"] == json!(own)
                && rpc.payload["projectId"] == json!(project)
                && rpc.payload["instanceId"] == launch["modelSelection"]["instanceId"]
        });
        expect!(
            ok,
            "the MC was asked {} times, first of \"{}\": {}",
            asked.len(),
            first
                .as_ref()
                .map(|rpc| rpc.environment.clone())
                .unwrap_or_default(),
            first.map(|rpc| show(&rpc.payload)).unwrap_or_default()
        );
    }
    let thread_key = format!("{machine}:{}", text(&launch["threadId"]));
    world.wait_for_with(
        |w| {
            w.with::<Navigation, _>(|n, _| n.thread_key().to_owned())
                .is_ok_and(|key| key == thread_key)
        },
        |w| format!("{thread_key}; the route is {}", show(&w.state("route"))),
    )
}

pub fn register(steps: &mut Steps) {
    steps.extension(extend);

    // The machines, as the MC finds them when it is asked.
    steps.step("load balancing is on", |world, _, _| {
        save_elsewhere(&mut world.mc, ENABLED, json!(true), false);
        Ok(())
    });
    steps.step(&format!("{Q} is busy and {Q} is idle"), |world, c, _| {
        placement(world).elsewhere = c[1].clone();
        Ok(())
    });
    steps.step("both machines are equally idle", |world, _, _| {
        placement(world).elsewhere.clear();
        Ok(())
    });
    // A machine the MC passes over. One that is offline is UsageSteps' step.
    steps.step(
        &format!("{Q} (is set to manual only|does not answer in time|is at 95% CPU|has 5% of memory free|does not have the chosen provider signed in|instead has no checkout of the repository)"),
        |world, c, _| {
            let project = placement(world).project.clone();
            if c[1] == "instead has no checkout of the repository" {
                let id = checkout_id(&world.mc, &c[0], &project);
                if let Some(rows) = world.mc.peer_rows.get_mut(&c[0]) {
                    rows.remove(&id);
                }
                return Ok(());
            }
            if c[1] == "is set to manual only" {
                let mut saved = weights(world).as_object().cloned().unwrap_or_default();
                saved.insert(c[0].clone(), json!(0));
                save_elsewhere(&mut world.mc, WEIGHTS, Value::Object(saved), false);
            }
            if placement(world).elsewhere == c[0] {
                placement(world).elsewhere.clear();
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user prefers {Q} and sets {Q} to less often"),
        |world, c, _| {
            connected(world)?;
            world.wait_for_with(
                |w| balancing(w)["ready"] == json!(true),
                |w| {
                    format!(
                        "load balancing's settings; the shell publishes {}",
                        show(&w.state("loadBalancing"))
                    )
                },
            )?;
            for (machine, weight) in [(&c[0], 100), (&c[1], 25)] {
                world.dispatch(
                    "loadBalancing.prefer",
                    json!({"environmentId": machine, "weight": weight}),
                )?;
                world.wait_for_with(
                    |w| weights(w)[machine.as_str()] == json!(weight),
                    |w| format!("{machine} at {weight}; the MC holds {}", show(&weights(w))),
                )?;
            }
            Ok(())
        },
    );
    // The little more room the other has is outweighed by the preferences
    // saved.
    steps.step(
        &format!("{Q} is somewhat busier than {Q}"),
        |world, c, _| {
            let saved = weights(world);
            let of = |machine: &String| saved[machine.as_str()].as_i64().unwrap_or(50);
            placement(world).elsewhere = if of(&c[0]) > of(&c[1]) {
                c[0].clone()
            } else {
                String::new()
            };
            Ok(())
        },
    );

    // The first send.
    steps.step(
        &format!("the user starts a new thread in {Q} on {Q}"),
        |world, c, _| {
            expect!(
                c[1] == world.mc.environment_id,
                "the shell is connected to {}",
                world.mc.environment_id
            );
            connected(world)?;
            world.open_draft(&c[0])?;
            world.wait_for_with(
                |w| w.state("workspace")["isDraft"] == json!(true),
                |w| {
                    format!(
                        "the draft; the header shows {}",
                        show(&w.state("workspace"))
                    )
                },
            )?;
            send_first_message(world)
        },
    );
    steps.step("the user sends the first message", |world, _, _| {
        send_first_message(world)
    });
    steps.step(
        &format!("the thread starts on {Q}(?: in its checkout of {Q})?"),
        |world, c, _| starts_on(world, &c[0]),
    );

    // The settings.
    steps.step("only one machine is connected", |world, _, _| {
        connected(world)
    });
    steps.step("the user opens connection settings", |world, _, _| {
        open_connections(world, 700.0)?;
        Ok(())
    });
    steps.step(
        &format!("{Q} is removed from the cluster"),
        |world, c, _| {
            wait_for_group(world)?;
            world.mc.remove(&c[0]);
            Ok(())
        },
    );
    steps.step("load balancing is not offered", |world, _, _| {
        world.sync()?;
        world.wait_for("the shell to read the MC's settings", |w| {
            Settings::of(w.engine()).ready()
        })?;
        let published = world.state("loadBalancing");
        expect!(
            published.is_null(),
            "the shell publishes {}",
            show(&published)
        );
        expect!(
            !group_visible(world).unwrap_or(false),
            "the Connections page shows the Load balancing group"
        );
        for result in results(world, "load balancing")? {
            expect!(
                text(&result["label"]) != "Load balancing",
                "settings search finds Load balancing"
            );
        }
        Ok(())
    });

    // connections/environments.feature: the group's switch and preferences.
    steps.step("a client paired with two environments", |world, _, _| {
        cluster(&mut world.mc, "laptop", SERVER);
        connected(world)
    });
    steps.step(
        "an environment's saved load weight is (\\d+)",
        |world, c, _| {
            save_elsewhere(&mut world.mc, ENABLED, json!(true), false);
            save_elsewhere(
                &mut world.mc,
                WEIGHTS,
                json!({SERVER: c[0].parse::<i64>().unwrap_or(0)}),
                false,
            );
            Ok(())
        },
    );
    steps.step("the user opens load balancing", |world, _, _| {
        open_connections(world, 700.0)?;
        unfold(world)
    });
    steps.step(&format!("the environment shows {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| preference(w, SERVER) == c[0],
            |w| {
                format!(
                    "{SERVER} to show {}; it shows {}",
                    c[0],
                    preference(w, SERVER)
                )
            },
        )
    });
    steps.step(
        "load balancing is on with preferences set",
        |world, _, _| {
            save_elsewhere(&mut world.mc, ENABLED, json!(true), false);
            let own = world.mc.environment_id.clone();
            let mut weights = Map::new();
            weights.insert(SERVER.into(), json!(100));
            weights.insert(own, json!(25));
            save_elsewhere(&mut world.mc, WEIGHTS, Value::Object(weights), false);
            Ok(())
        },
    );
    steps.step("the user turns load balancing off", |world, _, _| {
        turn(world, false)
    });
    steps.step("turns it on again", |world, _, _| turn(world, true));
    steps.step("the earlier preferences are back", |world, _, _| {
        let own = world.mc.environment_id.clone();
        let mut kept = Map::new();
        kept.insert(SERVER.into(), json!(100));
        kept.insert(own.clone(), json!(25));
        expect!(
            weights(world) == Value::Object(kept),
            "the MC holds {}",
            show(&weights(world))
        );
        unfold(world)?;
        world.wait_for_with(
            |w| preference(w, SERVER) == "Prefer" && preference(w, &own) == "Less often",
            |w| {
                format!(
                    "the preferences; {SERVER} shows {} and {own} shows {}",
                    preference(w, SERVER),
                    preference(w, &own)
                )
            },
        )?;
        let brick = page_default(world)?;
        let row = brick.item(world, &format!("loadPreference:{SERVER}"))?;
        expect!(
            brick.flag(world, row, "enabled"),
            "the preferences cannot be changed"
        );
        Ok(())
    });

    // settings/search-and-navigation.feature: the search result for the
    // group. The page is short, so the group starts below its view.
    steps.step(
        "the \"Load balancing\" group on the Connections page is folded",
        |world, _, _| {
            world.mc.join_named(SERVER);
            open_connections(world, 140.0)?;
            wait_for_group(world)?;
            expect!(
                !group_open(world)? && !in_view(world),
                "the group is open or already in view"
            );
            // The steps are SettingsSearchSteps', which on this page do this.
            // What SettingsNav.qml's result row does when it is clicked.
            world.on_settings_page.insert(
                "openResult".into(),
                Rc::new(|world: &mut World, c: &Vec<String>| {
                    let found = results(world, &c[0])?;
                    for result in &found {
                        if text(&result["label"]) != c[0] {
                            continue;
                        }
                        return world.dispatch(
                            "settings.openResult",
                            json!({"to": result["to"], "targetId": result["targetId"]}),
                        );
                    }
                    fail!("the search finds {}", show(&Value::Array(found)))
                }),
            );
            world.on_settings_page.insert(
                "inView".into(),
                Rc::new(|world: &mut World, _: &Vec<String>| {
                    world.wait_for("the group to be scrolled into view", in_view)
                }),
            );
            Ok(())
        },
    );
    steps.step("the \"Load balancing\" group is open", |world, _, _| {
        world.wait_for_with(
            |w| {
                body_shown(w) && {
                    let brick = w.peek_part::<Shown>().and_then(|shown| shown.0);
                    brick.is_some_and(|brick| {
                        brick
                            .find(w, "load-balancing")
                            .ok()
                            .flatten()
                            .is_some_and(|group| brick.flag(w, group, "open"))
                    })
                }
            },
            |w| {
                format!(
                    "the group to open; the route is {}",
                    show(&w.state("route"))
                )
            },
        )
    });
}

/// The project `name` on every machine of the cluster, as checkouts of one
/// repository: the MC's own under the id `name`, each member's under an id of
/// its own, so a launch says which checkout it is for.
pub fn share_project(mc: &mut FakeMc, name: &str) {
    mc.part::<FakePlacement>().project = name.to_owned();
    let checkout = |id: String, root: String| {
        json!({
            "id": id,
            "title": name,
            "workspaceRoot": root,
            "repositoryIdentity": {"canonicalKey": repository_of(name)},
            "scripts": [],
            "createdAt": "2026-09-01T09:00:00Z",
            "updatedAt": "2026-09-01T09:00:00Z",
        })
    };
    let own = checkout(
        checkout_id(mc, &mc.environment_id, name),
        format!("/work/{name}"),
    );
    mc.projects.insert(name.to_owned(), own);
    for machine in mc.members.clone() {
        let id = checkout_id(mc, &machine, name);
        let row = checkout(id.clone(), format!("/srv/{name}"));
        mc.send_peer_row_of(&machine, &id, &row, "project");
    }
}

/// A cluster of `machine` (the MC's own) and another with more room, both
/// with a checkout of the project this answers.
pub fn cluster_with_room_elsewhere(world: &mut World, machine: &str) -> String {
    let project = "api";
    cluster(&mut world.mc, machine, SERVER);
    share_project(&mut world.mc, project);
    placement(world).elsewhere = SERVER.into();
    project.to_owned()
}
