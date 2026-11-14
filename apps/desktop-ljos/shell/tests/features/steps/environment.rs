//! An environment's icon that cannot be changed, as
//! features/connections/environments.feature words it (Identity's lock, the
//! EnvironmentIconPicker brick). The two environments are the cluster's: this
//! machine and "server". desktop-qt's EnvironmentSteps.cpp.

use serde_json::{Value, json};

use super::settings::fake_config;
use crate::brick::{Brick, Shown};
use crate::expect;
use crate::harness::{Steps, at, show, text};
use crate::world::World;

const ENVIRONMENT: &str = "server";

#[derive(Default)]
struct Environments {
    /// The environment whose icon the scenario tries to change.
    icon_of: String,
    writes_before: usize,
}

fn writes(world: &World) -> usize {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "hal-c2.writeSettings")
        .count()
}

pub fn register(steps: &mut Steps) {
    // An icon that cannot be changed (Identity's lock, the
    // EnvironmentIconPicker brick).
    steps.step("the environment is not connected", |world, _, _| {
        world.mc.part::<Environments>().icon_of = ENVIRONMENT.into();
        world.mc.set_online(ENVIRONMENT, false);
        world.sync()
    });
    steps.step("the environment's server predates icons", |world, _, _| {
        // Its descriptor names no `environmentIcon` capability.
        let environment = world.mc.environment_id.clone();
        let fake = fake_config(&mut world.mc);
        fake.config.insert(
            "environment".into(),
            json!({"environmentId": environment, "capabilities": {}}),
        );
        let mut config = Value::Object(fake.config.clone());
        config["settings"] = Value::Object(fake.settings.clone());
        for id in world.mc.subscribers("config") {
            if text(&world.mc.shape_of(id)["environment"]) != world.mc.environment_id {
                continue;
            }
            world
                .mc
                .send(&json!({"t": "config", "id": id, "config": config}));
        }
        world.sync()
    });
    steps.step(
        "the user tries to change the environment's icon",
        |world, _, _| {
            if world.mc.part::<Environments>().icon_of.is_empty() {
                let own = world.mc.environment_id.clone();
                world.mc.part::<Environments>().icon_of = own;
            }
            let before = writes(world);
            let environment = world.mc.part::<Environments>().icon_of.clone();
            world.mc.part::<Environments>().writes_before = before;
            world.dispatch(
                "environmentIcon.set",
                json!({"environmentId": environment, "kind": "desktop"}),
            )
        },
    );
    steps.step(
        "the client says (connect to the environment to change its icon|the server is too old to keep an icon and should update|this session cannot change the environment's settings)",
        |world, c, _| {
            let said = if c[0].starts_with("connect") {
                "Connect to this environment to change its icon."
            } else if c[0].starts_with("the server") {
                "This environment's server is too old to keep an icon. Update it to choose one."
            } else {
                "Your session on this environment cannot change its settings."
            };
            world.wait_for_with(
                |w| {
                    at(&w.state("toasts"), "items")
                        .as_array()
                        .is_some_and(|toasts| {
                            toasts.iter().any(|toast| {
                                toast["title"] == "Icon not changed" && toast["description"] == said
                            })
                        })
                },
                |w| {
                    format!(
                        "\"{said}\"; the toasts are {}",
                        show(&w.state("toasts"))
                    )
                },
            )?;
            // Nothing was saved, and Connections settings says the same
            // beside the picker, which takes no choice.
            world.sync()?;
            let (written, before) = (writes(world), world.mc.part::<Environments>().writes_before);
            expect!(written == before, "the settings were written");
            let environment = world.mc.part::<Environments>().icon_of.clone();
            let brick = Brick::new(
                world,
                &format!(
                    "import QtQuick\nimport HalC2.Bricks\nEnvironmentIconPicker {{ width: 600; environmentId: \"{environment}\" }}\n"
                ),
                600.0,
                80.0,
            )?;
            world.part::<Shown>().0 = Some(brick);
            let kind = brick.item(world, "environmentIconKind")?;
            let enabled = brick.flag(world, kind, "enabled");
            expect!(
                brick.shows(world, said)? && !enabled,
                "the picker does not say \"{said}\""
            );
            Ok(())
        },
    );
}
