//! What the plugins' steps files share of an MC running a plugin (desktop-qt's
//! Plugins.h, the half McPluginSteps.cpp defines): a plugin whose MC part a
//! scenario fakes and whose package is a real one, the window's tabs and
//! plugin threads, and how items of the window are waited for.
//!
//! TODO(port): McPluginSteps.cpp's own steps and the rest of its fake MC (the
//! reviews topic, the files its scenarios serve, `plugins.rescan`, the
//! settings mask and refusal) are not ported; this file holds only what
//! PlannerSteps and CodeReviewSteps call: faked plugins that serve their own
//! package, `plugins.file`, `.enable`, `.disable`, `.restart`,
//! `.saveSettings` and `.call`.

use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::ObjectId;
use serde_json::{Value as Json, json};

use super::plugin::{click_item, shell};
use crate::brick::Brick;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// How a fake plugin answers `plugins.call`.
pub type PluginCall = Rc<dyn Fn(&mut FakeMc, &Rpc) -> Outcome>;

/// A plugin whose MC part a scenario fakes: the package's directory, which
/// `plugins.file` reads, what each of its topics holds, and how it answers
/// `plugins.call`.
#[derive(Clone, Default)]
pub struct FakePluginPart {
    pub package: String,
    pub topics: HashMap<String, Json>,
    /// What the topics hold on another environment that runs the plugin, by
    /// environment.
    pub topics_on: HashMap<String, HashMap<String, Json>>,
    pub call: Option<PluginCall>,
}

/// The plugins each environment's MC runs, and the faked ones by id.
#[derive(Default)]
struct FakeMcPlugins {
    plugins: HashMap<String, Vec<Json>>,
    parts: HashMap<String, FakePluginPart>,
}

fn environment_of(mc: &FakeMc, environment: &str) -> String {
    if environment.is_empty() {
        mc.environment_id.clone()
    } else {
        environment.to_owned()
    }
}

/// Sends the plugin list of `environment` to each client following it.
fn announce_on(mc: &mut FakeMc, environment: &str) {
    let list = mc
        .part::<FakeMcPlugins>()
        .plugins
        .get(environment)
        .cloned()
        .unwrap_or_default();
    for subscriber in mc.subscribers("plugins") {
        let wanted = environment_of(
            mc,
            at(&mc.shape_of(subscriber), "environment")
                .as_str()
                .unwrap_or_default(),
        );
        if wanted == environment {
            mc.send(&json!({"t": "plugins", "id": subscriber, "plugins": list}));
        }
    }
}

fn extension(mc: &mut FakeMc) {
    mc.on_shape("plugins", |mc, id, shape| {
        let environment = environment_of(mc, at(shape, "environment").as_str().unwrap_or_default());
        let list = mc
            .part::<FakeMcPlugins>()
            .plugins
            .get(&environment)
            .cloned()
            .unwrap_or_default();
        mc.send(&json!({"t": "plugins", "id": id, "plugins": list}));
        Ok(())
    });
    mc.on_shape("plugin", |mc, id, shape| {
        let topic = text(&shape["topic"]);
        let environment = environment_of(mc, at(shape, "environment").as_str().unwrap_or_default());
        let Some(part) = mc
            .part::<FakeMcPlugins>()
            .parts
            .get(&text(&shape["id"]))
            .cloned()
        else {
            return Ok(());
        };
        let topics = part.topics_on.get(&environment).unwrap_or(&part.topics);
        if let Some(value) = topics.get(&topic) {
            mc.send(&json!({"t": "plugin", "id": id, "topic": topic, "value": value}));
        }
        Ok(())
    });
    mc.on_rpc("plugins.", |mc, rpc| {
        let environment = environment_of(mc, &rpc.environment);
        let id = text(&rpc.payload["id"]);
        let entry = mc
            .part::<FakeMcPlugins>()
            .plugins
            .get(&environment)
            .and_then(|list| list.iter().find(|each| text(&each["id"]) == id).cloned());
        let Some(mut entry) = entry else {
            mc.refuse(rpc, &format!("unknown plugin {id}"));
            return Ok(());
        };
        let part = mc.part::<FakeMcPlugins>().parts.get(&id).cloned();
        let changed = |mc: &mut FakeMc, entry: &mut Json, status: Option<&str>| {
            if let Some(status) = status {
                entry["status"] = json!(status);
            }
            mc.reply(rpc, entry.clone());
            if let Some(list) = mc.part::<FakeMcPlugins>().plugins.get_mut(&environment)
                && let Some(kept) = list.iter_mut().find(|each| text(&each["id"]) == id)
            {
                *kept = entry.clone();
            }
            announce_on(mc, &environment);
        };
        match rpc.method.as_str() {
            "plugins.file" => {
                let path = text(&rpc.payload["path"]);
                let bytes = part
                    .as_ref()
                    .and_then(|part| {
                        std::fs::read(std::path::Path::new(&part.package).join(&path)).ok()
                    })
                    .unwrap_or_default();
                if bytes.is_empty() {
                    mc.refuse(rpc, &format!("{path} is not in the package"));
                    return Ok(());
                }
                let binary = path.ends_with(".png");
                let content = if binary {
                    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &bytes)
                } else {
                    String::from_utf8_lossy(&bytes).into_owned()
                };
                mc.reply(
                    rpc,
                    json!({"path": path,
                           "encoding": if binary { "base64" } else { "utf8" },
                           "content": content,
                           "revision": entry["revision"]}),
                );
            }
            "plugins.enable" | "plugins.restart" => changed(mc, &mut entry, Some("running")),
            "plugins.disable" => changed(mc, &mut entry, Some("disabled")),
            "plugins.saveSettings" => {
                entry["saved"] = rpc.payload["settings"].clone();
                changed(mc, &mut entry, None);
            }
            "plugins.call" => match part.and_then(|part| part.call) {
                Some(call) => return call(mc, rpc),
                None => mc.refuse(rpc, "no such call"),
            },
            _ => mc.refuse(rpc, "no such call"),
        }
        Ok(())
    });
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);
}

fn published(world: &World) -> Json {
    world.state("mcPlugins")
}

/// What a wait on the plugin pages gave up on.
pub fn describe(world: &World) -> String {
    format!(
        "the client has {}; the route is {}",
        show(&published(world)),
        show(&world.state("route"))
    )
}

/// Plugin `id` as the client lists it on `environment`, null if it does not.
pub fn listed(world: &World, id: &str, environment: &str) -> Json {
    let wanted = environment_of(&world.mc, environment);
    published(world)["environments"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|each| text(&each["id"]) == wanted)
        .flat_map(|each| each["plugins"].as_array().into_iter().flatten())
        .find(|plugin| text(&plugin["id"]) == id)
        .cloned()
        .unwrap_or(Json::Null)
}

/// The scenario's MC runs the plugin `entry` (as `plugins` lists it) with
/// `part` as its MC part, and the client lists it running.
pub fn run_fake_plugin(world: &mut World, entry: Json, part: FakePluginPart) -> Outcome {
    let id = text(&entry["id"]);
    let environment = world.mc.environment_id.clone();
    let fake = world.mc.part::<FakeMcPlugins>();
    fake.parts.insert(id.clone(), part);
    fake.plugins.insert(environment.clone(), vec![entry]);
    shell(world)?;
    announce_on(&mut world.mc, &environment);
    world.wait_for_with(
        |w| text(&listed(w, &id, "")["status"]) == "running",
        |w| format!("{id} to be running; {}", describe(w)),
    )
}

/// The environment `environment` joins the cluster running the faked plugin
/// `entry` too.
pub fn run_fake_plugin_on(world: &mut World, environment: &str, entry: Json) -> Outcome {
    let id = text(&entry["id"]);
    world
        .mc
        .part::<FakeMcPlugins>()
        .plugins
        .insert(environment.to_owned(), vec![entry]);
    world.mc.join_named(environment);
    let environment = environment.to_owned();
    world.wait_for_with(
        |w| text(&listed(w, &id, &environment)["status"]) == "running",
        describe,
    )
}

/// The faked plugin `id`'s MC part (fails the step when it is not faked).
pub fn fake_plugin_part<'a>(mc: &'a mut FakeMc, id: &str) -> Outcome<&'a mut FakePluginPart> {
    match mc.part::<FakeMcPlugins>().parts.get_mut(id) {
        Some(part) => Ok(part),
        None => fail!("no plugin {id} is faked"),
    }
}

/// Sends what the plugin's topic holds now to each client watching it.
pub fn publish_topic(mc: &mut FakeMc, id: &str, topic: &str) -> Outcome {
    let part = fake_plugin_part(mc, id)?.clone();
    for subscriber in mc.subscribers("plugin") {
        let shape = mc.shape_of(subscriber);
        if text(&shape["id"]) != id || text(&shape["topic"]) != topic {
            continue;
        }
        let environment =
            environment_of(mc, at(&shape, "environment").as_str().unwrap_or_default());
        let value = part
            .topics_on
            .get(&environment)
            .unwrap_or(&part.topics)
            .get(topic)
            .cloned()
            .unwrap_or(Json::Null);
        mc.send(&json!({"t": "plugin", "id": subscriber, "topic": topic, "value": value}));
    }
    Ok(())
}

/// Whether the scenario's MC runs a plugin `id`.
pub fn is_mc_plugin(world: &mut World, id: &str) -> bool {
    world
        .mc
        .part::<FakeMcPlugins>()
        .plugins
        .values()
        .any(|list| list.iter().any(|each| text(&each["id"]) == id))
}

/// The item named `object_name` in the window: a shown one if any, else any.
pub fn named(world: &World, brick: Brick, object_name: &str) -> Option<ObjectId> {
    match brick.find_visible(world, object_name) {
        Ok(Some(shown)) => Some(shown),
        _ => brick.find(world, object_name).ok().flatten(),
    }
}

/// The shown item named `object_name` in the window, once it is (and `ready`).
pub fn wait_shown_named(
    world: &mut World,
    object_name: &str,
    ready: impl Fn(&World, Brick, ObjectId) -> bool,
) -> Outcome<ObjectId> {
    let brick = shell(world)?;
    world.wait_for_with(
        |w| {
            named(w, brick, object_name)
                .is_some_and(|found| brick.flag(w, found, "visible") && ready(w, brick, found))
        },
        |w| {
            let problem = named(w, brick, object_name)
                .map(|found| brick.text_of(w, found, "problem"))
                .unwrap_or_default();
            let problem = if problem.is_empty() {
                String::new()
            } else {
                format!(" ({problem})")
            };
            format!("{object_name} to be shown{problem}; {}", describe(w))
        },
    )?;
    match named(world, brick, object_name) {
        Some(found) => Ok(found),
        None => fail!("{object_name} is gone"),
    }
}

/// `wait_shown_named` with nothing more to wait for.
pub fn shown_named(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    wait_shown_named(world, object_name, |_, _, _| true)
}

/// A tab's key by its title.
fn tab_key(world: &mut World, title: &str) -> Outcome<String> {
    if title == "Threads" {
        return Ok("threads".to_owned());
    }
    world.wait_for_with(
        |w| !page_key(w, title).is_empty(),
        |w| format!("a page titled {title}; {}", describe(w)),
    )?;
    Ok(page_key(world, title))
}

fn page_key(world: &World, title: &str) -> String {
    published(world)["pages"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|page| text(&page["title"]) == title)
        .map(|page| text(&page["key"]))
        .unwrap_or_default()
}

/// The user clicks the tab `title` in the window's strip.
pub fn switch_to_tab(world: &mut World, title: &str) -> Outcome {
    let key = tab_key(world, title)?;
    let tab = shown_named(world, &format!("tab:{key}"))?;
    click_item(world, tab)?;
    let wanted = key.clone();
    world.wait_for_with(
        move |w| text(&w.state("route")["tab"]) == wanted,
        |w| format!("the {title} tab to be selected; {}", describe(w)),
    )?;
    shown_named(world, "pluginPages")?;
    Ok(())
}

/// A thread the plugin started (`plugin` is its {id, kind, listed}), in the
/// shell.
pub fn add_plugin_thread(world: &mut World, id: &str, title: &str, plugin: Json) -> Outcome {
    shell(world)?;
    let row = json!({"id": id, "title": title, "projectId": "p1",
                     "createdAt": "2026-09-23T09:00:00Z",
                     "updatedAt": "2026-09-23T09:00:00Z",
                     "plugin": plugin});
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
    world.sync()
}

/// The user opens the plugin thread `id`.
pub fn open_plugin_thread(world: &mut World, id: &str) -> Outcome {
    let key = format!("{}:{id}", world.mc.environment_id);
    world.dispatch("thread.open", json!({"key": key}))?;
    world.wait_for_with(|w| text(&w.state("route")["threadKey"]) == key, describe)
}

/// An entry as `plugins` lists a real package: its manifest, running with its
/// permissions granted.
pub fn entry_of(id: &str, manifest: &Json, settings: &Json) -> Json {
    let permissions: Vec<Json> = manifest["permissions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|each| {
            let mut permission = each.clone();
            permission["label"] = each["id"].clone();
            permission["granted"] = json!(true);
            permission
        })
        .collect();
    json!({"id": id,
           "name": manifest["name"],
           "version": manifest["version"],
           "description": manifest["description"],
           "author": manifest["author"],
           "status": "running",
           "error": null,
           "lastError": null,
           "revision": "1",
           "runsCode": true,
           "permissions": permissions,
           "settingsSchema": manifest["settings"],
           "settings": settings,
           "contributes": manifest["contributes"]})
}

/// The directory of the real package `name` under plugins/.
pub fn package(name: &str) -> String {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../plugins");
    let dir = root.join(name);
    dir.canonicalize()
        .unwrap_or(dir)
        .to_string_lossy()
        .into_owned()
}

/// The package's plugin.json.
pub fn manifest(package: &str) -> Outcome<Json> {
    let path = std::path::Path::new(package).join("plugin.json");
    let read = std::fs::read_to_string(&path);
    expect!(read.is_ok(), "{} cannot be read", path.display());
    Ok(serde_json::from_str(&read.unwrap_or_default()).unwrap_or(Json::Null))
}
