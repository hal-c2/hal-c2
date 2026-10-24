//! The palette's Add project beyond its sources (desktop-qt's
//! AddProjectSteps.cpp): which environment gets the project, one that goes
//! away meanwhile, and the folder browser's paths
//! (features/navigation/palette-add-project.feature). Also the helpers that
//! read the palette as its brick does, through `PaletteModel`.

use hal_c2_shell::controllers::palette::{Palette, PaletteObject};
use hal_c2_shell::store;
use ljos::prelude::{Atom, ObjectId, Value};
use serde_json::{Value as Json, json};

use super::fake_files::fake_files;
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct AddProject {
    highlighted: String,
}

/// The palette's `PaletteModel`.
pub fn palette(world: &World) -> Outcome<ObjectId> {
    match world.engine().singleton::<PaletteObject>() {
        Ok(object) => Ok(object),
        Err(_) => fail!("the shell has no command palette"),
    }
}

fn as_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.as_str().to_owned(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        _ => String::new(),
    }
}

/// A text property of the palette (mode, submenu, query, emptyText, status,
/// submitLabel, submitShortcut).
pub fn prop(world: &World, name: &str) -> Outcome<String> {
    let object = palette(world)?;
    Ok(as_text(&world.engine().read_by_name(object, name)))
}

/// `PaletteModel.<name>(args)`, as the brick calls it.
pub fn invoke(world: &mut World, name: &str, args: &[Value]) -> Outcome<Value> {
    let object = palette(world)?;
    match world.engine().invoke_by_name(object, name, args) {
        Ok(value) => {
            world.pump()?;
            Ok(value)
        }
        Err(error) => fail!("{name}: {error}"),
    }
}

/// Whether `PaletteModel.<name>(args)` answered true.
pub fn invoke_ok(world: &mut World, name: &str, args: &[Value]) -> Outcome<bool> {
    Ok(invoke(world, name, args)? == Value::Bool(true))
}

pub fn is_open(world: &World) -> bool {
    palette(world)
        .map(|object| world.engine().read_by_name(object, "open") == Value::Bool(true))
        .unwrap_or(false)
}

pub fn count(world: &World) -> usize {
    world
        .with::<Palette, _>(|p, _| usize::try_from(p.count()).unwrap_or(0))
        .unwrap_or(0)
}

pub fn highlighted(world: &World) -> i32 {
    world
        .with::<Palette, _>(|p, _| p.highlighted())
        .unwrap_or(-1)
}

pub fn searching(world: &World) -> bool {
    world
        .with::<Palette, _>(|p, _| p.searching())
        .unwrap_or(false)
}

pub fn kind_at(world: &World, row: usize) -> String {
    world
        .with::<Palette, _>(|p, _| p.kind_at(row as i32))
        .unwrap_or_default()
}

pub fn id_at(world: &World, row: usize) -> String {
    world
        .with::<Palette, _>(|p, _| p.id_at(row as i32))
        .unwrap_or_default()
}

/// What row `row` shows under `role` (title, description, group, shortcut,
/// kind, runnable, current).
pub fn role(world: &World, row: usize, role: &str) -> Value {
    let Ok(object) = palette(world) else {
        return Value::Undefined;
    };
    world
        .engine()
        .object_model(object)
        .map_or(Value::Undefined, |model| {
            model.data(world.engine(), row, role)
        })
}

pub fn role_text(world: &World, row: usize, name: &str) -> String {
    as_text(&role(world, row, name))
}

/// The palette, its rows and what it says, for a failure.
pub fn describe(world: &World) -> String {
    let lines: Vec<String> = (0..count(world))
        .map(|row| {
            format!(
                "{} ({}){}",
                role_text(world, row, "title"),
                role_text(world, row, "description"),
                if role(world, row, "runnable") == Value::Bool(true) {
                    ""
                } else {
                    " off"
                }
            )
        })
        .collect();
    let read = |name: &str| prop(world, name).unwrap_or_default();
    format!(
        "the palette ({} \"{}\", query \"{}\") lists [{}] and says \"{}\"",
        read("mode"),
        read("submenu"),
        read("query"),
        lines.join("; "),
        read("emptyText")
    )
}

pub fn row_titled(world: &World, title: &str) -> Option<usize> {
    (0..count(world)).find(|&row| role_text(world, row, "title") == title)
}

/// Types `query` into the palette's field.
pub fn set_query(world: &mut World, query: &str) -> Outcome {
    let object = palette(world)?;
    if let Err(error) = world
        .engine()
        .write_by_name(object, "query", Value::String(Atom::from(query)))
    {
        fail!("query: {error}");
    }
    world.pump()
}

/// Opens the palette in command mode.
pub fn open(world: &mut World) -> Outcome {
    if !is_open(world) {
        invoke(world, "show", &[])?;
    }
    Ok(())
}

fn choose(world: &mut World, title: &str) -> Outcome {
    let row = row_titled(world, title);
    let ran = match row {
        Some(row) => invoke_ok(world, "run", &[Value::Int(row as i32)])?,
        None => false,
    };
    expect!(ran, "{}", describe(world));
    world.sync()
}

/// Add project, then Local folder, as the palette's entries.
fn browse(world: &mut World) -> Outcome {
    {
        let files = fake_files(&mut world.mc);
        for folder in ["/home/sam/code", "/home/sam/code/shop", "/home/sam/code/api"] {
            files.folders.insert(folder.to_owned());
        }
    }
    open(world)?;
    choose(world, "Add project")?;
    // With one environment it asks where the project comes from at once.
    if row_titled(world, "Local folder").is_none() {
        let environment = world.mc.environment_id.clone();
        choose(world, &environment)?;
    }
    choose(world, "Local folder")?;
    expect!(prop(world, "mode")? == "browse", "{}", describe(world));
    Ok(())
}

fn type_path(world: &mut World, path: &str) -> Outcome {
    set_query(world, path)?;
    world.wait_for("the folders to be listed", |w| !searching(w))?;
    world.sync()
}

fn created(world: &World) -> Vec<Json> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "projects.mutate" && rpc.payload["type"] == json!("project.create"))
        .map(|rpc| rpc.payload.clone())
        .collect()
}

pub fn register(steps: &mut Steps) {
    // Which environment.
    steps.step(
        "two environments are connected and one is disconnected",
        |world, _, _| {
            world.mc.join_named("env-b");
            world.mc.join_named("env-c");
            world.mc.set_online("env-c", false);
            world.sync()?;
            world.wait_for("the other environments", |w| {
                store::with(w.engine(), |s| {
                    s.environment_online("env-b")
                        && s.environments().contains(&"env-c".to_owned())
                        && !s.environment_online("env-c")
                })
            })
        },
    );
    steps.step(
        "the palette lists \"This device\" and the other connected environment",
        |world, _, _| {
            expect!(
                prop(world, "submenu")? == "Add project",
                "{}",
                describe(world)
            );
            let own = row_titled(world, &world.mc.environment_id);
            let other = row_titled(world, "env-b");
            let fits = match (own, other) {
                (Some(own), Some(other)) => {
                    role_text(world, own, "description") == "This device"
                        && role(world, own, "runnable") == Value::Bool(true)
                        && role(world, other, "runnable") == Value::Bool(true)
                }
                _ => false,
            };
            expect!(fits, "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        "the disconnected environment cannot be chosen",
        |world, _, _| {
            let Some(row) = row_titled(world, "env-c") else {
                fail!("{}", describe(world));
            };
            let fits = role(world, row, "runnable") != Value::Bool(true)
                && role_text(world, row, "description") == "Not connected"
                && !invoke_ok(world, "run", &[Value::Int(row as i32)])?
                && prop(world, "submenu")? == "Add project";
            expect!(fits, "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        "the user chose an environment for a new project",
        |world, _, _| {
            world.mc.join_named("env-b");
            world.sync()?;
            world.wait_for("the second environment", |w| {
                store::with(w.engine(), |s| s.environment_online("env-b"))
            })?;
            fake_files(&mut world.mc)
                .folders
                .insert("/home/sam/code".into());
            open(world)?;
            choose(world, "Add project")?;
            choose(world, "env-b")?;
            choose(world, "Local folder")?;
            expect!(prop(world, "mode")? == "browse", "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        "that environment disconnects before the project is added",
        |world, _, _| {
            set_query(world, "/srv/shop")?;
            world.mc.set_online("env-b", false);
            world.sync()?;
            world.wait_for("the environment to go", |w| {
                !store::with(w.engine(), |s| s.environment_online("env-b"))
            })?;
            // The user adds the folder they typed.
            invoke(world, "addBrowsedFolder", &[])?;
            world.sync()?;
            let made = created(world);
            expect!(
                made.is_empty(),
                "a project was created: {}",
                show(&json!(made))
            );
            Ok(())
        },
    );

    // The folder browser.
    steps.step("the user is browsing for a project folder", |world, _, _| {
        browse(world)
    });
    steps.step("the user types a path that does not exist", |world, _, _| {
        type_path(world, "~/code/brand-new")?;
        expect!(count(world) == 0, "{}", describe(world));
        Ok(())
    });
    steps.step("no project is active", |world, _, _| {
        let route = world.state("route");
        let kind = at(&route, "kind");
        expect!(
            kind != "thread" && kind != "draft",
            "{}",
            show(&route)
        );
        Ok(())
    });
    steps.step(
        "the user types a relative path while adding a project",
        |world, _, _| {
            browse(world)?;
            type_path(world, "code/shop")?;
            // And it cannot be added.
            let added = invoke_ok(world, "addBrowsedFolder", &[])?;
            let ran = invoke_ok(world, "runHighlighted", &[])?;
            expect!(
                !added && !ran && created(world).is_empty(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("a folder is highlighted", |world, _, _| {
        type_path(world, "~/code/")?;
        let Some(row) = row_titled(world, "api") else {
            fail!("{}", describe(world));
        };
        let object = palette(world)?;
        if let Err(error) = world
            .engine()
            .write_by_name(object, "highlighted", Value::Int(row as i32))
        {
            fail!("highlighted: {error}");
        }
        world.mc.part::<AddProject>().highlighted = id_at(world, row);
        let highlighted = world.mc.part::<AddProject>().highlighted.clone();
        expect!(
            kind_at(world, row) == "folder" && highlighted == "/home/sam/code/api",
            "{}",
            describe(world)
        );
        Ok(())
    });
    // The brick's half, rows under a resting pointer, is tst_CommandPalette.qml's;
    // here the palette leaves them unhighlighted and Enter on what was typed.
    steps.step(
        "the pointer rests where the palette's entries appear",
        |world, _, _| browse(world),
    );
    steps.step(
        "the user types a folder path while adding a project",
        |world, _, _| type_path(world, "/home/sam/code/shop"),
    );
    steps.step(
        "no entry is highlighted until the pointer moves",
        |world, _, _| {
            expect!(
                count(world) > 0 && highlighted(world) < 0,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("Enter adds the folder typed", |world, _, _| {
        expect!(
            invoke_ok(world, "runHighlighted", &[])?,
            "{}",
            describe(world)
        );
        world.sync()?;
        let commands = created(world);
        expect!(
            commands.len() == 1 && commands[0]["workspaceRoot"] == json!("/home/sam/code/shop"),
            "the MC was asked to create {}; {}",
            show(&json!(commands)),
            describe(world)
        );
        Ok(())
    });
    // The button in the field that names the action and its key.
    steps.step(
        &format!("the palette offers {Q} with {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    prop(w, "submitLabel").is_ok_and(|l| l == c[0])
                        && prop(w, "submitShortcut").is_ok_and(|s| s == c[1])
                },
                |w| {
                    format!(
                        "the palette to offer \"{}\" with {}; it offers \"{}\" with {}",
                        c[0],
                        c[1],
                        prop(w, "submitLabel").unwrap_or_default(),
                        prop(w, "submitShortcut").unwrap_or_default()
                    )
                },
            )
        },
    );
    steps.step("the highlighted folder is added as a project", |world, _, _| {
        let commands = created(world);
        let highlighted = world.mc.part::<AddProject>().highlighted.clone();
        expect!(
            commands.len() == 1 && commands[0]["workspaceRoot"] == json!(highlighted),
            "the MC was asked to create {}; {}",
            show(&json!(commands)),
            describe(world)
        );
        expect!(!is_open(world), "{}", describe(world));
        Ok(())
    });
}
