//! What MC plugins add to the desktop (features/plugins/plugin-contributions.feature):
//! a fake MC's `plugins` shape and `plugins.*` calls, the plugin "code-review"
//! with a page, thread looks, a sidebar section and a settings page of its own,
//! and the real DefaultShell window that draws them: desktop-qt's
//! McPluginSteps.cpp, with the helpers Plugins.h declares for it.

use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::{Atom, ObjectId, Value};
use serde_json::{Map, Value as Json, json};

use crate::brick::Brick;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::steps::add_project::{
    invoke_ok, open as open_palette, row_titled, searching, set_query,
};
use crate::steps::keybinding::{describe_key_press, key_ran, press_key};
use crate::steps::plugin::{answer_question, click_item, draws_text, shell, show_plugin_list};
use crate::steps::thread_menu::section_of;
use crate::world::World;
use crate::{expect, fail};

const CODE_REVIEW: &str = "code-review";
const REVIEW_THREAD: &str = "t-review";
const REVIEW_TITLE: &str = "Review acme/shop#7";
const MARKER: &str = "••••••";

/// How a faked plugin answers `plugins.call`.
pub type PluginCall = Rc<dyn Fn(&mut FakeMc, &Rpc) -> Outcome>;

/// A plugin whose MC part a scenario fakes itself and whose package is a real
/// one: the package's directory, which `plugins.file` reads, what each of its
/// topics holds, and how it answers `plugins.call`.
#[derive(Clone, Default)]
pub struct FakePluginPart {
    pub package: String,
    pub topics: HashMap<String, Json>,
    /// What the topics hold on another environment that runs the plugin, by
    /// environment.
    pub topics_on: HashMap<String, HashMap<String, Json>>,
    pub call: Option<PluginCall>,
}

/// The plugins each environment's MC runs, the files of their packages, and
/// what one of them publishes.
#[derive(Default)]
struct FakeMcPlugins {
    plugins: HashMap<String, Vec<Json>>,
    /// "<revision>/<path>", or "*/<path>" for every revision.
    files: HashMap<String, Vec<u8>>,
    /// What `plugins.saveSettings` refuses with, when it does.
    refusal: String,
    reviews: Vec<Json>,
    /// Plugins in the MC's folder that `plugins.rescan` finds, by environment.
    unscanned: HashMap<String, Vec<Json>>,
    /// Plugins faked by other steps, by id.
    parts: HashMap<String, FakePluginPart>,
    /// The page a scenario keeps an eye on, to tell a reload from an update.
    page: Option<ObjectId>,
}

fn environment_of(mc: &FakeMc, environment: &str) -> String {
    if environment.is_empty() {
        mc.environment_id.clone()
    } else {
        environment.to_owned()
    }
}

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64(bytes: &[u8]) -> String {
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(BASE64[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = (data.len() as u32).to_be_bytes().to_vec();
    let mut body = kind.to_vec();
    body.extend_from_slice(data);
    out.extend_from_slice(&body);
    out.extend_from_slice(&crc32(&body).to_be_bytes());
    out
}

/// A 4x4 dark cyan PNG.
fn png() -> Vec<u8> {
    let mut raw = Vec::new();
    for _ in 0..4 {
        raw.extend_from_slice(&[0u8, 0, 139, 139, 0, 139, 139, 0, 139, 139, 0, 139, 139]);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for byte in &raw {
        a = (a + u32::from(*byte)) % 65521;
        b = (b + a) % 65521;
    }
    // zlib, with one stored block.
    let mut z = vec![0x78, 0x01, 0x01];
    z.extend_from_slice(&(raw.len() as u16).to_le_bytes());
    z.extend_from_slice(&(!(raw.len() as u16)).to_le_bytes());
    z.extend_from_slice(&raw);
    z.extend_from_slice(&((b << 16) | a).to_be_bytes());
    let mut header = Vec::new();
    header.extend_from_slice(&4u32.to_be_bytes());
    header.extend_from_slice(&4u32.to_be_bytes());
    header.extend_from_slice(&[8, 2, 0, 0, 0]);
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    out.extend(chunk(b"IHDR", &header));
    out.extend(chunk(b"IDAT", &z));
    out.extend(chunk(b"IEND", &[]));
    out
}

fn reviews_source(version: &str) -> Vec<u8> {
    format!(
        r#"import QtQuick

Item {{
    id: page

    property var plugin
    property string version: "{version}"
    property string filter: "all"
    property var reviews: []
    property string answer: ""
    property int seen: -1

    function ask(environment) {{
        page.answer = "";
        page.plugin.call("reviews", {{ state: "failed" }}, (result, error) => page.answer = error ? "error: " + error : result.from, environment || undefined);
    }}

    function watchAgain(topic) {{
        page.plugin.watch(topic, value => page.seen = value.length);
    }}

    function open(threadId) {{
        page.plugin.openThread(threadId);
    }}

    objectName: "reviewsPage"
    implicitWidth: 400
    implicitHeight: 300
    Component.onCompleted: page.plugin.watch("reviews", value => page.reviews = value)

    Column {{
        Text {{ objectName: "reviewsEnvironments"; text: page.plugin.environments.join(",") }}
        Text {{ objectName: "reviewsList"; text: page.reviews.filter(review => page.filter === "all" || review.state === page.filter).map(review => review.title).join(", ") }}
        Text {{ text: "v" + page.version }}
    }}
}}
"#
    )
    .into_bytes()
}

/// A part that draws `text`, made with the thread it is for when it has one.
fn text_part(text: &str) -> Vec<u8> {
    format!("import QtQuick\nText {{\n    property var plugin\n    property var thread\n    text: {text}\n}}\n")
        .into_bytes()
}

fn plugins_json(plugins: &[Json]) -> Json {
    Json::Array(plugins.to_vec())
}

/// Sends `environment`'s list to the clients following it.
fn push(mc: &mut FakeMc, environment: &str) {
    let list = plugins_json(
        mc.part::<FakeMcPlugins>()
            .plugins
            .get(environment)
            .map(Vec::as_slice)
            .unwrap_or_default(),
    );
    for subscriber in mc.subscribers("plugins") {
        let wanted = text(&mc.shape_of(subscriber)["environment"]);
        if environment_of(mc, &wanted) == environment {
            mc.send(&json!({"t": "plugins", "id": subscriber, "plugins": list}));
        }
    }
}

fn extension(mc: &mut FakeMc) {
    let fake = mc.part::<FakeMcPlugins>();
    let png = png();
    fake.files.insert("*/icon.png".into(), png.clone());
    fake.files.insert("*/screenshots/queue.png".into(), png);
    fake.files
        .insert("*/pages/Reviews.qml".into(), reviews_source("1"));
    fake.files
        .insert("2/pages/Reviews.qml".into(), reviews_source("2"));
    fake.files.insert(
        "*/threads/ReviewMark.qml".into(),
        text_part("\"[review mark]\""),
    );
    fake.files.insert(
        "*/threads/ReviewHeader.qml".into(),
        text_part("thread ? \"Reviewing \" + thread.title : \"\""),
    );
    fake.files.insert(
        "*/slots/Section.qml".into(),
        text_part("\"[code-review section]\""),
    );
    fake.files.insert(
        "*/settings/Settings.qml".into(),
        text_part("\"[code-review settings]\""),
    );
    fake.reviews = vec![
        json!({"title": "Add cache", "state": "passed"}),
        json!({"title": "Fix login", "state": "failed"}),
    ];

    mc.on_shape("plugins", |mc, id, shape| {
        let environment = environment_of(mc, &text(&shape["environment"]));
        let list = plugins_json(
            mc.part::<FakeMcPlugins>()
                .plugins
                .get(&environment)
                .map(Vec::as_slice)
                .unwrap_or_default(),
        );
        mc.send(&json!({"t": "plugins", "id": id, "plugins": list}));
        Ok(())
    });
    mc.on_shape("plugin", |mc, id, shape| {
        let topic = text(&shape["topic"]);
        let plugin = text(&shape["id"]);
        if let Some(part) = mc.part::<FakeMcPlugins>().parts.get(&plugin).cloned() {
            let environment = environment_of(mc, &text(&shape["environment"]));
            let topics = part.topics_on.get(&environment).unwrap_or(&part.topics);
            if let Some(value) = topics.get(&topic) {
                mc.send(&json!({"t": "plugin", "id": id, "topic": topic, "value": value}));
            }
            return Ok(());
        }
        if topic != "reviews" {
            return Ok(());
        }
        let reviews = Json::Array(mc.part::<FakeMcPlugins>().reviews.clone());
        mc.send(&json!({"t": "plugin", "id": id, "topic": "reviews", "value": reviews}));
        Ok(())
    });
    mc.on_rpc("plugins.", |mc, rpc| {
        let environment = environment_of(mc, &rpc.environment);
        let id = text(&rpc.payload["id"]);
        if rpc.method == "plugins.rescan" {
            let fake = mc.part::<FakeMcPlugins>();
            let found = fake.unscanned.remove(&environment).unwrap_or_default();
            fake.plugins
                .entry(environment.clone())
                .or_default()
                .extend(found);
            let list = plugins_json(&fake.plugins[&environment]);
            push(mc, &environment);
            mc.reply(rpc, json!({"plugins": list}));
            return Ok(());
        }
        let fake = mc.part::<FakeMcPlugins>();
        let at_index = fake
            .plugins
            .entry(environment.clone())
            .or_default()
            .iter()
            .position(|each| each["id"] == json!(id));
        let Some(index) = at_index else {
            mc.refuse(rpc, &format!("unknown plugin {id}"));
            return Ok(());
        };
        let revision = text(&fake.plugins[&environment][index]["revision"]);
        let part = fake.parts.get(&id).cloned();
        let changed = |mc: &mut FakeMc, edit: &dyn Fn(&mut Json)| {
            let fake = mc.part::<FakeMcPlugins>();
            let entry = &mut fake.plugins.get_mut(&environment).expect("listed")[index];
            edit(entry);
            let entry = entry.clone();
            mc.reply(rpc, entry);
            push(mc, &environment);
        };
        match rpc.method.as_str() {
            "plugins.file" => {
                let path = text(&rpc.payload["path"]);
                let fake = mc.part::<FakeMcPlugins>();
                let mut bytes = fake
                    .files
                    .get(&format!("{revision}/{path}"))
                    .or_else(|| fake.files.get(&format!("*/{path}")))
                    .cloned()
                    .unwrap_or_default();
                if let Some(part) = &part {
                    bytes = std::fs::read(std::path::Path::new(&part.package).join(&path))
                        .unwrap_or_default();
                }
                if bytes.is_empty() {
                    mc.refuse(rpc, &format!("{path} is not in the package"));
                    return Ok(());
                }
                let binary = path.ends_with(".png");
                let content = if binary {
                    base64(&bytes)
                } else {
                    String::from_utf8_lossy(&bytes).into_owned()
                };
                mc.reply(
                    rpc,
                    json!({"path": path, "encoding": if binary { "base64" } else { "utf8" },
                           "content": content, "revision": revision}),
                );
            }
            "plugins.enable" | "plugins.restart" => {
                changed(mc, &|entry| entry["status"] = json!("running"))
            }
            "plugins.disable" => changed(mc, &|entry| entry["status"] = json!("disabled")),
            "plugins.saveSettings" => {
                let refusal = mc.part::<FakeMcPlugins>().refusal.clone();
                if !refusal.is_empty() {
                    mc.refuse(rpc, &refusal);
                    return Ok(());
                }
                let mut settings = rpc.payload["settings"]
                    .as_object()
                    .cloned()
                    .unwrap_or_default();
                let before =
                    mc.part::<FakeMcPlugins>().plugins[&environment][index]["settings"].clone();
                // The mask keeps the secret it stands for.
                for (key, value) in settings.iter_mut() {
                    if *value == json!(MARKER) {
                        *value = before[key].clone();
                    }
                }
                changed(mc, &|entry| entry["saved"] = Json::Object(settings.clone()));
            }
            "plugins.call" => match &part {
                Some(part) => match &part.call {
                    Some(call) => call(mc, rpc)?,
                    None => mc.refuse(rpc, "no such call"),
                },
                None => mc.reply(rpc, json!({"from": format!("Reviews on {environment}")})),
            },
            _ => mc.refuse(rpc, "no such call"),
        }
        Ok(())
    });
}

fn code_review() -> Json {
    json!({
        "id": CODE_REVIEW,
        "name": "Code review",
        "version": "1.0.0",
        "description": "Agents review the pull requests of the repositories you choose.",
        "author": {"name": "HAL-C2"},
        "icon": "icon.png",
        "screenshots": [{"path": "screenshots/queue.png", "caption": "The review queue"}],
        "status": "running",
        "error": null,
        "lastError": null,
        "revision": "1",
        "runsCode": true,
        "permissions": [
            {"id": "pullRequests:write", "label": "Comment on pull requests",
             "reason": "It posts the reviews it writes.", "granted": true},
            {"id": "threads:create", "label": "Start threads",
             "reason": "Each review runs in a thread of its own.", "granted": true},
        ],
        "settingsSchema": [{"key": "repos", "type": "list", "label": "Repositories"}],
        "settings": {"repos": ["acme/shop"]},
        "contributes": {
            "pages": [{"id": "reviews", "title": "Reviews", "icon": "git-pull-request",
                       "qml": "pages/Reviews.qml"}],
            "threadKinds": [{"kind": "review", "label": "Review",
                             "rowMark": "threads/ReviewMark.qml",
                             "header": "threads/ReviewHeader.qml"}],
        },
    })
}

fn fake(world: &mut World) -> &mut FakeMcPlugins {
    world.mc.part::<FakeMcPlugins>()
}

/// Sends each environment's list to the client following it.
fn announce(world: &mut World) {
    let environments: Vec<String> = fake(world).plugins.keys().cloned().collect();
    for subscriber in world.mc.subscribers("plugins") {
        let wanted = text(&world.mc.shape_of(subscriber)["environment"]);
        let environment = environment_of(&world.mc, &wanted);
        let list = plugins_json(
            fake(world)
                .plugins
                .get(&environment)
                .map(Vec::as_slice)
                .unwrap_or_default(),
        );
        world
            .mc
            .send(&json!({"t": "plugins", "id": subscriber, "plugins": list}));
    }
    let _ = environments;
}

/// Changes plugin `id` on every MC that runs it, and tells the client.
fn change(world: &mut World, id: &str, edit: impl Fn(&mut Json)) -> Outcome {
    let mut found = false;
    for plugins in fake(world).plugins.values_mut() {
        for entry in plugins.iter_mut() {
            if entry["id"] == json!(id) {
                edit(entry);
                found = true;
            }
        }
    }
    expect!(found, "no MC runs {}", id);
    announce(world);
    Ok(())
}

fn change_contributions(
    world: &mut World,
    id: &str,
    edit: impl Fn(&mut Map<String, Json>),
) -> Outcome {
    change(world, id, |entry| {
        let mut parts = entry["contributes"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        edit(&mut parts);
        entry["contributes"] = Json::Object(parts);
    })
}

fn published(world: &World) -> Json {
    world.state("mcPlugins")
}

fn list_of<'a>(value: &'a Json, key: &str) -> &'a [Json] {
    value[key].as_array().map(Vec::as_slice).unwrap_or_default()
}

/// The page whose tab runs on `environment` alone.
fn page_on(world: &World, environment: &str) -> Json {
    list_of(&published(world), "pages")
        .iter()
        .find(|page| page["environments"] == json!([environment]))
        .cloned()
        .unwrap_or(Json::Null)
}

/// Plugin `id` as the client lists it on `environment` ("" for the MC's own).
pub fn listed(world: &World, id: &str, environment: &str) -> Json {
    let wanted = if environment.is_empty() {
        world.mc.environment_id.clone()
    } else {
        environment.to_owned()
    };
    let published = published(world);
    for each in list_of(&published, "environments") {
        if text(&each["id"]) != wanted {
            continue;
        }
        for plugin in list_of(each, "plugins") {
            if plugin["id"] == json!(id) {
                return plugin.clone();
            }
        }
    }
    Json::Null
}

pub fn describe(world: &World) -> String {
    format!(
        "the client has {}; the route is {}",
        show(&published(world)),
        show(&world.state("route"))
    )
}

fn wait_status(world: &mut World, id: &str, status: &str) -> Outcome {
    world.wait_for_with(
        |w| listed(w, id, "")["status"] == json!(status),
        |w| format!("{id} to be {status}; {}", describe(w)),
    )
}

/// The shown item named `name` in the window, else the first hidden one: a
/// thread can have a row in more than one section, or a page a copy that is
/// not on screen.
pub fn named(
    world: &World,
    brick: impl std::borrow::Borrow<Brick>,
    name: &str,
) -> Option<ObjectId> {
    let brick = *brick.borrow();
    brick
        .find_visible(world, name)
        .ok()
        .flatten()
        .or_else(|| brick.find(world, name).ok().flatten())
}

fn item(world: &mut World, name: &str) -> Outcome<Option<ObjectId>> {
    let brick = shell(world)?;
    Ok(named(world, brick, name))
}

fn wait_named_when(
    world: &mut World,
    name: &str,
    ready: impl Fn(&World, Brick, ObjectId) -> bool,
) -> Outcome<ObjectId> {
    let brick = shell(world)?;
    world.wait_for_with(
        |w| {
            matches!(named(w, brick, name), Some(found)
                if brick.flag(w, found, "visible") && ready(w, brick, found))
        },
        |w| {
            let problem = named(w, brick, name)
                .map(|found| brick.text_of(w, found, "problem"))
                .filter(|problem| !problem.is_empty())
                // The label's text is always "%1 failed: %2"; only a shown
                // one is a failure.
                .or_else(|| {
                    named(w, brick, "pluginPageProblem")
                        .filter(|&found| brick.flag(w, found, "visible"))
                        .map(|found| brick.text_of(w, found, "text"))
                })
                .unwrap_or_default();
            let problem = if problem.is_empty() {
                String::new()
            } else {
                format!(" ({problem})")
            };
            format!("{name} to be shown{problem}; {}", describe(w))
        },
    )?;
    match named(world, brick, name) {
        Some(found) => Ok(found),
        None => fail!("{} is not shown", name),
    }
}

fn wait_named(world: &mut World, name: &str) -> Outcome<ObjectId> {
    wait_named_when(world, name, |_, _, _| true)
}

fn count_named(world: &World, brick: &Brick, prefix: bool, name: &str) -> usize {
    // The window has no walk over its items, so the strip is asked: it
    // lists the names of the tabs it draws.
    let _ = (world, brick, prefix, name);
    0
}

fn route_tab(world: &World) -> String {
    text(at(&world.state("route"), "tab"))
}

/// A tab's key by its title.
fn tab_key(world: &mut World, title: &str) -> Outcome<String> {
    if title == "Threads" {
        return Ok("threads".into());
    }
    let find = |w: &World| {
        list_of(&published(w), "pages")
            .iter()
            .find(|page| page["title"] == json!(title))
            .map(|page| text(&page["key"]))
            .unwrap_or_default()
    };
    world.wait_for_with(
        |w| !find(w).is_empty(),
        |w| format!("a page titled {title}; {}", describe(w)),
    )?;
    Ok(find(world))
}

fn wait_tab(world: &mut World, title: &str) -> Outcome {
    let key = tab_key(world, title)?;
    world.wait_for_with(
        |w| route_tab(w) == key,
        |w| format!("the {title} tab to be selected; {}", describe(w)),
    )
}

/// The user clicks a tab in the window's strip.
fn click_tab(world: &mut World, title: &str) -> Outcome {
    let key = tab_key(world, title)?;
    let tab = wait_named(world, &format!("tab:{key}"))?;
    click_item(world, tab)?;
    wait_tab(world, title)
}

/// The plugin's page, drawn in its tab.
fn show_page(world: &mut World, title: &str) -> Outcome<ObjectId> {
    click_tab(world, title)?;
    let page = wait_named(world, "reviewsPage")?;
    fake(world).page = Some(page);
    Ok(page)
}

fn reviews_shown(world: &mut World) -> Outcome<String> {
    let list = wait_named(world, "reviewsList")?;
    let brick = shell(world)?;
    Ok(brick.text_of(world, list, "text"))
}

/// Waits for the reviews list to say `wanted`.
fn wait_reviews(world: &mut World, wanted: &str) -> Outcome {
    let brick = shell(world)?;
    world.wait_for_with(
        |w| {
            named(w, brick, "reviewsList")
                .is_some_and(|list| brick.text_of(w, list, "text") == wanted)
        },
        |w| {
            named(w, brick, "reviewsList")
                .map(|list| brick.text_of(w, list, "text"))
                .unwrap_or_default()
        },
    )
}

pub fn add_thread(world: &mut World, id: &str, title: &str, plugin: Option<Json>) -> Outcome {
    shell(world)?;
    let mut row = json!({"id": id, "title": title, "projectId": "p1",
                         "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    if let Some(plugin) = plugin {
        row["plugin"] = plugin;
    }
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
    world.sync()
}

fn add_review_thread(world: &mut World, listed_in_sidebar: bool) -> Outcome {
    add_thread(
        world,
        REVIEW_THREAD,
        REVIEW_TITLE,
        Some(json!({"id": CODE_REVIEW, "kind": "review", "listed": listed_in_sidebar})),
    )
}

fn key(world: &World, thread: &str) -> String {
    format!("{}:{}", world.mc.environment_id, thread)
}

pub fn open_thread(world: &mut World, thread: &str) -> Outcome {
    let wanted = key(world, thread);
    world.dispatch("thread.open", json!({"key": wanted}))?;
    let wanted = key(world, thread);
    world.wait_for_with(
        |w| text(at(&w.state("route"), "threadKey")) == wanted,
        describe,
    )
}

fn open_settings(world: &mut World, id: &str) -> Outcome<ObjectId> {
    shell(world)?;
    let to = format!("/settings/plugin/{}/{id}", world.mc.environment_id);
    world.dispatch("settings.navigate", json!({"to": to}))?;
    wait_named(world, "pluginSettings")
}

/// Calls the function `name` of `target`, as the shell's own script would.
fn call(world: &mut World, target: ObjectId, name: &str, args: &[Value]) -> Outcome<Value> {
    let result = world
        .engine()
        .invoke_by_name(target, name, args)
        .map_err(|e| Failure(format!("{name} cannot be called: {e:?}")))?;
    world.pump()?;
    Ok(result)
}

fn string(value: &str) -> Value {
    Value::String(Atom::from(value))
}

/// The settings page's own `set(key, value)`, as the fields call it.
fn set_setting(world: &mut World, key: &str, value: Value) -> Outcome {
    let page = wait_named(world, "pluginSettings")?;
    call(world, page, "set", &[string(key), value]).map(|_| ())
}

fn ask_page(world: &mut World, page: ObjectId, environment: &str) -> Outcome {
    call(world, page, "ask", &[string(environment)]).map(|_| ())
}

fn calls_of(world: &World, method: &str) -> Vec<Rpc> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == method)
        .cloned()
        .collect()
}

fn review_mark(world: &World, brick: &Brick) -> Option<ObjectId> {
    named(world, brick, "pluginRowMark").filter(|mark| brick.flag(world, *mark, "visible"))
}

fn plugin_page(world: &mut World) -> Outcome<ObjectId> {
    match fake(world).page {
        Some(page) => Ok(page),
        None => fail!("no page is being watched"),
    }
}

fn card(world: &World, brick: &Brick, list: ObjectId, id: &str) -> Option<ObjectId> {
    brick
        .find_under(
            world,
            list,
            &format!("mcPlugin:{}/{id}", world.mc.environment_id),
        )
        .ok()
        .flatten()
}

/// The pages and tabs the user can see, for a failure.
fn publish_plugin(world: &mut World, environment: &str, entry: Json) {
    fake(world)
        .plugins
        .insert(environment.to_owned(), vec![entry]);
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        &format!("an environment whose MC runs the plugin {Q}"),
        |world, c, _| {
            expect!(c[0] == CODE_REVIEW, "the fake MC has no plugin {}", c[0]);
            let environment = world.mc.environment_id.clone();
            publish_plugin(world, &environment, code_review());
            shell(world)?;
            wait_status(world, &c[0], "running")
        },
    );

    // Pages are tabs.
    steps.step(&format!("{Q} adds the page {Q}"), |world, c, _| {
        let key = tab_key(world, &c[1])?;
        wait_named(world, &format!("tab:{key}")).map(|_| ())
    });
    steps.step("no running plugin adds a page", |world, _, _| {
        change_contributions(world, CODE_REVIEW, |parts| {
            parts.remove("pages");
        })?;
        world.wait_for_with(|w| list_of(&published(w), "pages").is_empty(), describe)
    });
    for shown in ["the shell is shown", "the thread list is shown"] {
        steps.step(shown, |world, _, _| {
            shell(world)?;
            world.sync()
        });
    }
    steps.step(
        &format!("the shell has the tabs {Q} and {Q}"),
        |world, c, _| {
            wait_named(world, "shellTabs")?;
            for title in c {
                let key = tab_key(world, title)?;
                let tab = wait_named(world, &format!("tab:{key}"))?;
                expect!(
                    draws_text(world, tab, title)?,
                    "the {} tab does not say so",
                    title
                );
            }
            Ok(())
        },
    );
    steps.step(&format!("{Q} is selected"), |world, c, _| {
        wait_tab(world, &c[0])
    });
    steps.step("the shell shows the threads with no tabs", |world, _, _| {
        let brick = shell(world)?;
        world.wait_for_with(
            |w| named(w, brick, "shellTabs").is_some_and(|tabs| !brick.flag(w, tabs, "visible")),
            |w| format!("the tabs to go; {}", describe(w)),
        )?;
        let pages_visible =
            item(world, "pluginPages")?.is_some_and(|pages| brick.flag(world, pages, "visible"));
        expect!(
            route_tab(world) == "threads" && !pages_visible,
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user is reading the thread {Q}"),
        |world, c, _| {
            add_thread(world, "t-auth", &c[0], None)?;
            open_thread(world, "t-auth")
        },
    );
    steps.step(
        &format!("the user switches to the {Q} tab"),
        |world, c, _| {
            click_tab(world, &c[0])?;
            if c[0] != "Threads" {
                wait_named(world, "pluginPages")?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("then switches back to the {Q} tab"),
        |world, c, _| click_tab(world, &c[0]),
    );
    steps.step(
        &format!("the thread {Q} is shown where the user left it"),
        |world, _, _| {
            let brick = shell(world)?;
            world.wait_for_with(
                |w| {
                    named(w, brick, "pluginPages")
                        .is_some_and(|pages| !brick.flag(w, pages, "visible"))
                },
                describe,
            )?;
            expect!(
                route_tab(world) == "threads"
                    && text(at(&world.state("route"), "threadKey")) == key(world, "t-auth"),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user filtered the {Q} page to failed reviews"),
        |world, c, _| {
            let page = show_page(world, &c[0])?;
            let brick = shell(world)?;
            brick.write(world, page, "filter", Value::String(Atom::from("failed")))?;
            wait_reviews(world, "Fix login")
        },
    );
    steps.step(
        &format!("the user switches to {Q} and back to {Q}"),
        |world, c, _| {
            click_tab(world, &c[0])?;
            click_tab(world, &c[1])
        },
    );
    steps.step(
        &format!("the {Q} page still shows only failed reviews"),
        |world, _, _| {
            let page = wait_named(world, "reviewsPage")?;
            expect!(Some(page) == fake(world).page, "the page was made again");
            let brick = shell(world)?;
            let shown = reviews_shown(world)?;
            expect!(
                brick.text_of(world, page, "filter") == "failed" && shown == "Fix login",
                "the page shows {}",
                shown
            );
            Ok(())
        },
    );
    for on in [
        "the user is on the {} page",
        "the user is on the {} tab",
        "the {} page is shown",
    ] {
        steps.step(&on.replace("{}", Q), |world, c, _| {
            show_page(world, &c[0]).map(|_| ())
        });
    }
    steps.step("the user opens the thread of a review", |world, _, _| {
        add_review_thread(world, true)?;
        let page = plugin_page(world)?;
        call(world, page, "open", &[string(REVIEW_THREAD)]).map(|_| ())
    });
    steps.step(
        &format!("the {Q} tab is selected with that thread open"),
        |world, c, _| {
            wait_tab(world, &c[0])?;
            let wanted = key(world, REVIEW_THREAD);
            world.wait_for_with(
                |w| text(at(&w.state("route"), "threadKey")) == wanted,
                describe,
            )
        },
    );
    steps.step(
        &format!("the user searches the command palette for {Q}"),
        |world, c, _| {
            shell(world)?;
            open_palette(world)?;
            set_query(world, &c[0])
        },
    );
    steps.step(
        &format!("opening the result switches to the {Q} tab"),
        |world, c, _| {
            let title = c[0].clone();
            let mut row = None;
            world.wait_for_with(
                |w| {
                    if searching(w) {
                        return false;
                    }
                    row = row_titled(w, &title);
                    row.is_some()
                },
                |_| format!("the palette to list {title}"),
            )?;
            let row = row.expect("the palette lists it");
            invoke_ok(world, "run", &[Value::Int(row as i32)])?;
            wait_tab(world, &c[0])
        },
    );
    steps.step(&format!("the {Q} tab is selected"), |world, c, _| {
        if !world.checking {
            click_tab(world, &c[0])?;
        }
        wait_tab(world, &c[0])
    });
    steps.step(
        "the user presses the keybinding for the (next|previous) tab",
        |world, c, _| {
            press_key(
                world,
                if c[0] == "next" {
                    "mod+alt+]"
                } else {
                    "mod+alt+["
                },
            )?;
            let command = format!("tabs.{}", c[0]);
            expect!(key_ran(world, &command), "{}", describe_key_press(world));
            Ok(())
        },
    );
    steps.step(&format!("the {Q} tab is gone"), |world, _, _| {
        let brick = shell(world)?;
        world.wait_for_with(
            |w| {
                list_of(&published(w), "pages").is_empty()
                    && list_of(&w.state("route"), "none").is_empty()
                    && count_named(w, &brick, true, "tab:code-review/reviews@") == 0
                    && named(w, brick, "tab:code-review/reviews@1")
                        .is_none_or(|tab| !brick.flag(w, tab, "visible"))
            },
            describe,
        )
    });
    steps.step("the threads are shown", |world, _, _| {
        let brick = shell(world)?;
        world.wait_for_with(
            |w| {
                route_tab(w) == "threads"
                    && named(w, brick, "pluginPages")
                        .is_some_and(|pages| !brick.flag(w, pages, "visible"))
            },
            describe,
        )
    });
    steps.step(
        &format!("a second environment also runs {Q}"),
        |world, c, _| {
            shell(world)?;
            publish_plugin(world, "work", code_review());
            world.mc.join_named("work");
            world.wait_for_with(
                |w| listed(w, &c[0], "work")["status"] == json!("running"),
                describe,
            )
        },
    );
    steps.step(
        &format!("a second environment runs another version of {Q}"),
        |world, c, _| {
            shell(world)?;
            let mut other = code_review();
            other["revision"] = json!("other");
            publish_plugin(world, "work", other);
            world.mc.join_named("work");
            world.wait_for_with(
                |w| listed(w, &c[0], "work")["status"] == json!("running"),
                describe,
            )
        },
    );
    steps.step(
        &format!("there is a {Q} tab for each environment, named after it"),
        |world, c, _| {
            world.wait_for_with(|w| list_of(&published(w), "pages").len() == 2, describe)?;
            let pages = list_of(&published(world), "pages").to_vec();
            let mut titles = Vec::new();
            for page in &pages {
                let title = text(&page["title"]);
                expect!(
                    title.starts_with(&format!("{} · ", c[0])),
                    "a tab is named {}",
                    title
                );
                wait_named(world, &format!("tab:{}", text(&page["key"])))?;
                titles.push(title);
            }
            expect!(
                titles.first() != titles.last(),
                "both tabs are named {}",
                titles[0]
            );
            Ok(())
        },
    );
    steps.step(
        "each tab's page runs on its own environment only",
        |world, _, _| {
            let mut runs_on: Vec<String> = list_of(&published(world), "pages")
                .iter()
                .map(|page| {
                    page["environments"]
                        .as_array()
                        .map(|list| list.iter().map(text).collect::<Vec<_>>().join(","))
                        .unwrap_or_default()
                })
                .collect();
            runs_on.sort();
            let mut wanted = vec![world.mc.environment_id.clone(), "work".to_owned()];
            wanted.sort();
            expect!(runs_on == wanted, "the pages run on {}", runs_on.join(" "));
            Ok(())
        },
    );
    steps.step(
        &format!("the user is on the {Q} tab of the second environment"),
        |world, _, _| {
            let find = |w: &World| text(&page_on(w, "work")["key"]);
            world.wait_for_with(|w| !find(w).is_empty(), describe)?;
            let key = find(world);
            let tab = wait_named(world, &format!("tab:{key}"))?;
            click_item(world, tab)?;
            world.wait_for_with(|w| route_tab(w) == key, describe)?;
            let page = wait_named(world, "reviewsPage")?;
            fake(world).page = Some(page);
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} stops on the first environment"),
        |world, _, _| {
            let environment = world.mc.environment_id.clone();
            for entry in fake(world).plugins.entry(environment).or_default() {
                entry["status"] = json!("stopped");
            }
            announce(world);
            world.wait_for_with(|w| list_of(&published(w), "pages").len() == 1, describe)
        },
    );
    steps.step(
        &format!("a second environment runs a version of {Q} whose {Q} page could not be fetched"),
        |world, c, _| {
            shell(world)?;
            // An empty file is one the fake MC refuses.
            fake(world)
                .files
                .insert(format!("other/pages/{}.qml", c[1]), Vec::new());
            let mut other = code_review();
            other["revision"] = json!("other");
            publish_plugin(world, "work", other);
            world.mc.join_named("work");
            world.wait_for_with(|w| !text(&page_on(w, "work")["error"]).is_empty(), describe)
        },
    );
    steps.step(
        "the second environment goes offline and comes back with the page",
        |world, _, _| {
            fake(world).files.remove("other/pages/Reviews.qml");
            world.mc.set_online("work", false);
            world.wait_for_with(|w| list_of(&published(w), "pages").len() == 1, describe)?;
            world.mc.set_online("work", true);
            Ok(())
        },
    );
    steps.step(
        &format!("the {Q} tab of the second environment shows its page"),
        |world, _, _| {
            world.wait_for_with(|w| !text(&page_on(w, "work")["url"]).is_empty(), describe)
        },
    );
    steps.step(
        &format!("the second environment updates {Q}"),
        |world, _, _| {
            for entry in fake(world).plugins.entry("work".into()).or_default() {
                entry["revision"] = json!("newer");
            }
            announce(world);
            Ok(())
        },
    );
    steps.step(
        &format!("the user is on the {Q} tab of the version the second environment runs"),
        |world, _, _| {
            world.wait_for_with(|w| route_tab(w) == "code-review/reviews@newer", describe)
        },
    );
    steps.step("the user is still on the same page", |world, _, _| {
        let brick = shell(world)?;
        let page = fake(world).page;
        let shown = page.is_some_and(|page| brick.flag(world, page, "visible"));
        expect!(
            shown,
            "the page was replaced or hidden; tab {}; {}",
            route_tab(world),
            describe(world)
        );
        Ok(())
    });
    steps.step(&format!("there is one {Q} tab"), |world, c, _| {
        let key = tab_key(world, &c[0])?;
        world.wait_for_with(
            |w| {
                let state = published(w);
                let pages = list_of(&state, "pages");
                pages.len() == 1
                    && pages[0]["environments"]
                        .as_array()
                        .is_some_and(|list| list.len() == 2)
            },
            describe,
        )?;
        wait_named(world, &format!("tab:{key}"))?;
        Ok(())
    });
    steps.step(
        "the page can tell each environment's data apart",
        |world, _, _| {
            let page = show_page(world, "Reviews")?;
            let environments = wait_named(world, "reviewsEnvironments")?;
            let brick = shell(world)?;
            let environments = brick.text_of(world, environments, "text");
            let mut runs_on: Vec<String> = environments.split(',').map(str::to_owned).collect();
            runs_on.sort();
            let mut wanted = vec![world.mc.environment_id.clone(), "work".to_owned()];
            wanted.sort();
            expect!(runs_on == wanted, "the page runs on {}", environments);
            for environment in [world.mc.environment_id.clone(), "work".to_owned()] {
                ask_page(world, page, &environment)?;
                let wanted = format!("Reviews on {environment}");
                world.wait_for_with(
                    |w| brick.text_of(w, page, "answer") == wanted,
                    |w| {
                        format!(
                            "the answer from {environment}; the page has {}",
                            brick.text_of(w, page, "answer")
                        )
                    },
                )?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the {Q} page of {Q} fails to load"),
        |world, c, _| {
            fake(world).files.insert(
                "broken/pages/Reviews.qml".into(),
                b"import QtQuick\nItem { this is not QML }\n".to_vec(),
            );
            change(world, &c[1], |entry| entry["revision"] = json!("broken"))
        },
    );
    steps.step(
        &format!("the tab shows that {Q} failed with its message"),
        |world, _, _| {
            let problem = wait_named(world, "pluginPageProblem")?;
            let brick = shell(world)?;
            let said = brick.text_of(world, problem, "text");
            expect!(
                said.starts_with("Code review failed: ") && said.chars().count() > 24,
                "the tab says \"{}\"",
                said
            );
            Ok(())
        },
    );
    steps.step("the other tabs keep working", |world, _, _| {
        click_tab(world, "Threads")?;
        let brick = shell(world)?;
        world.wait_for_with(
            |w| {
                named(w, brick, "pluginPages").is_some_and(|pages| !brick.flag(w, pages, "visible"))
            },
            describe,
        )
    });

    // A plugin's threads.
    steps.step(
        &format!("{Q} started a(?: listed)? {Q} thread"),
        |world, _, _| add_review_thread(world, true),
    );
    steps.step(
        &format!("{Q} started a {Q} thread that is not listed"),
        |world, _, _| add_review_thread(world, false),
    );
    steps.step(
        &format!("the thread's row shows the mark {Q} gives {Q} threads"),
        |world, _, _| {
            let brick = shell(world)?;
            world.wait_for_with(
                |w| {
                    review_mark(w, &brick).is_some_and(|mark| {
                        brick.shows_under(w, mark, "[review mark]").unwrap_or(false)
                    })
                },
                |w| format!("the review mark; {}", describe(w)),
            )
        },
    );
    steps.step("the user opens that thread", |world, _, _| {
        open_thread(world, REVIEW_THREAD)
    });
    steps.step(
        &format!("the plugin's header for {Q} threads is shown above the conversation"),
        |world, _, _| {
            let header =
                wait_named_when(world, "pluginThreadHeader", |w, brick, header| match brick
                    .read(w, header, "height")
                {
                    Value::Real(height) => height > 0.0,
                    Value::Int(height) => height > 0,
                    _ => false,
                })?;
            let brick = shell(world)?;
            expect!(
                brick.text_of(world, header, "look") == "header",
                "the header is not the thread's header"
            );
            Ok(())
        },
    );
    steps.step(
        "the header is given the thread it is shown for",
        |world, _, _| {
            let header = wait_named(world, "pluginThreadHeader")?;
            let brick = shell(world)?;
            let wanted = format!("Reviewing {REVIEW_TITLE}");
            world.wait_for("the header to name the thread", |w| {
                brick.shows_under(w, header, &wanted).unwrap_or(false)
            })
        },
    );
    steps.step("the thread is not in it", |world, _, _| {
        world.sync()?;
        let section = section_of(world, &key(world, REVIEW_THREAD));
        expect!(section.is_empty(), "the thread is listed in {}", section);
        Ok(())
    });
    steps.step(&format!("{Q} is disabled"), |world, c, _| {
        change(world, &c[0], |entry| entry["status"] = json!("disabled"))?;
        wait_status(world, &c[0], "disabled")
    });
    steps.step(
        "the thread is listed and opens as an ordinary thread",
        |world, _, _| {
            let brick = shell(world)?;
            let thread = key(world, REVIEW_THREAD);
            world.wait_for_with(
                |w| !section_of(w, &thread).is_empty() && review_mark(w, &brick).is_none(),
                |w| format!("the thread listed without its mark; {}", describe(w)),
            )?;
            open_thread(world, REVIEW_THREAD)?;
            world.sync()?;
            let header = item(world, "pluginThreadHeader")?;
            expect!(
                header.is_none_or(|header| !brick.flag(world, header, "visible")),
                "the plugin's header is shown"
            );
            Ok(())
        },
    );

    // Settings.
    steps.step(
        &format!("{Q} is listed under its environment with its description, version, author and screenshots"),
        |world, c, _| {
            let list = show_plugin_list(world)?;
            let brick = shell(world)?;
            // The list draws each environment again when what it publishes
            // changes, so the card is looked up afresh each time it is read.
            let environment_name = format!("mcPlugins:{}", world.mc.environment_id);
            let card_name = format!("mcPlugin:{}/{}", world.mc.environment_id, c[0]);
            let find = |w: &World| -> Option<ObjectId> {
                let environment = brick.find_under(w, list, &environment_name).ok().flatten()?;
                if !brick.flag(w, environment, "visible") {
                    return None;
                }
                brick.find_under(w, environment, &card_name).ok().flatten()
            };
            let description = text(&code_review()["description"]);
            world.wait_for_with(
                |w| {
                    find(w).is_some_and(|shown| {
                        brick.find_under(w, shown, "mcPluginByline").ok().flatten().is_some()
                            && brick.shows_under(w, shown, &description).unwrap_or(false)
                    })
                },
                |w| format!("the card with its description; {}", describe(w)),
            )?;
            let shown = find(world).expect("listed");
            let by = brick.find_under(world, shown, "mcPluginByline")?.expect("listed");
            let byline = brick.text_of(world, by, "text");
            expect!(
                byline.contains("1.0.0") && byline.contains("HAL-C2"),
                "the card says \"{}\"",
                byline
            );
            world.wait_for("the screenshot to be drawn", |w| {
                find(w)
                    .and_then(|shown| brick.find_under(w, shown, "mcPluginScreenshot").ok().flatten())
                    .is_some_and(|shot| {
                        brick.flag(w, shot, "visible")
                            && matches!(brick.read(w, shot, "status"), Value::Int(1))
                    })
            })
        },
    );
    steps.step(
        "the user is shown each permission it asks for with its reason",
        |world, _, _| {
            world.wait_for("the shell to ask", |w| w.state("confirmation").is_object())?;
            let question = world.state("confirmation");
            let description = text(&question["description"]);
            expect!(
                question["title"] == json!("Enable \"Code review\"?"),
                "{}",
                show(&question)
            );
            for permission in list_of(&code_review(), "permissions") {
                let line = format!(
                    "{}: {}",
                    text(&permission["label"]),
                    text(&permission["reason"])
                );
                expect!(
                    description.contains(&line),
                    "the question does not say \"{}\": {}",
                    line,
                    description
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} runs only after the user accepts them"),
        |world, c, _| {
            world.sync()?;
            expect!(
                calls_of(world, "plugins.enable").is_empty(),
                "the plugin was enabled before the user accepted"
            );
            answer_question(world, true)?;
            wait_status(world, &c[0], "running")?;
            let accepted = calls_of(world, "plugins.enable")
                .first()
                .map(|rpc| rpc.payload["acceptPermissions"].clone())
                .unwrap_or(Json::Null);
            expect!(
                accepted == json!(["pullRequests:write", "threads:create"]),
                "it was enabled with {}",
                show(&accepted)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user enables {Q} and declines its permissions"),
        |world, c, _| {
            switch_mc_plugin(world, &c[0])?;
            world.wait_for("the shell to ask", |w| w.state("confirmation").is_object())?;
            answer_question(world, false)
        },
    );
    steps.step(&format!("{Q} stays disabled"), |world, c, _| {
        world.sync()?;
        expect!(
            calls_of(world, "plugins.enable").is_empty(),
            "the plugin was enabled"
        );
        expect!(
            listed(world, &c[0], "")["status"] == json!("disabled"),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the plugin {Q} declares a server address and a secret token"),
        |world, c, _| {
            let mut entry = code_review();
            entry["id"] = json!(c[0]);
            entry["name"] = json!("ntfy");
            entry["runsCode"] = json!(false);
            entry["contributes"] = json!({});
            entry["settingsSchema"] = json!([
                {"key": "server", "type": "text", "label": "Server address"},
                {"key": "token", "type": "secret", "label": "Token"},
            ]);
            entry["settings"] = json!({"server": "https://ntfy.sh", "token": MARKER});
            let environment = world.mc.environment_id.clone();
            fake(world)
                .plugins
                .entry(environment)
                .or_default()
                .push(entry);
            announce(world);
            wait_status(world, &c[0], "running")
        },
    );
    steps.step(
        &format!("the plugin {Q} declares a setting that takes JSON"),
        |world, c, _| {
            let mut entry = code_review();
            entry["id"] = json!(c[0]);
            entry["name"] = json!("ntfy");
            entry["runsCode"] = json!(false);
            entry["contributes"] = json!({});
            entry["settingsSchema"] =
                json!([{"key": "topics", "type": "object", "label": "Topics"}]);
            entry["settings"] = json!({"topics": {"alerts": true}});
            let environment = world.mc.environment_id.clone();
            fake(world)
                .plugins
                .entry(environment)
                .or_default()
                .push(entry);
            announce(world);
            wait_status(world, &c[0], "running")
        },
    );
    steps.step(
        "the user changes that setting to JSON that does not parse",
        |world, _, _| {
            let page = wait_named(world, "pluginSettings")?;
            call(
                world,
                page,
                "setJson",
                &[string("topics"), string("{\"alerts\": false}")],
            )?;
            let save = wait_named(world, "pluginSettingsSave")?;
            let brick = shell(world)?;
            expect!(
                brick.flag(world, save, "enabled"),
                "a change that parses cannot be saved"
            );
            call(
                world,
                page,
                "setJson",
                &[string("topics"), string("{\"alerts\": fa")],
            )
            .map(|_| ())
        },
    );
    steps.step(
        "the page says the setting is not valid JSON",
        |world, _, _| {
            let unparsed = wait_named(world, "pluginSettingsUnparsed")?;
            let brick = shell(world)?;
            let said = brick.text_of(world, unparsed, "text");
            expect!(said.contains("Topics"), "{}", said);
            let save = item(world, "pluginSettingsSave")?;
            expect!(
                save.is_some_and(|save| !brick.flag(world, save, "enabled")),
                "the stale value can be saved"
            );
            Ok(())
        },
    );
    steps.step(
        "it can be saved again once the JSON parses",
        |world, _, _| {
            let page = wait_named(world, "pluginSettings")?;
            call(
                world,
                page,
                "setJson",
                &[
                    string("topics"),
                    string("{\"alerts\": false, \"news\": true}"),
                ],
            )?;
            let save = wait_named(world, "pluginSettingsSave")?;
            click_item(world, save)?;
            world.wait_for("the settings to be saved", |w| {
                !calls_of(w, "plugins.saveSettings").is_empty()
            })?;
            let settings = calls_of(world, "plugins.saveSettings")[0].payload["settings"].clone();
            let wanted = json!({"topics": {"alerts": false, "news": true}});
            expect!(settings == wanted, "the MC was sent {}", show(&settings));
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens the settings of {Q}"),
        |world, c, _| open_settings(world, &c[0]).map(|_| ()),
    );
    steps.step(
        "the page shows a field for each declared setting",
        |world, _, _| {
            for setting in ["server", "token"] {
                wait_named(world, &format!("pluginSetting:{setting}"))?;
            }
            Ok(())
        },
    );
    steps.step("saving it stores the settings on the MC", |world, _, _| {
        set_setting(world, "server", string("https://ntfy.example.com"))?;
        let save = wait_named(world, "pluginSettingsSave")?;
        click_item(world, save)?;
        world.wait_for("the settings to be saved", |w| {
            !calls_of(w, "plugins.saveSettings").is_empty()
        })?;
        let settings = calls_of(world, "plugins.saveSettings")[0].payload["settings"].clone();
        expect!(
            settings == json!({"server": "https://ntfy.example.com", "token": MARKER}),
            "the MC was sent {}",
            show(&settings)
        );
        let brick = shell(world)?;
        world.wait_for("the page to be saved", |w| {
            named(w, brick, "pluginSettingsSave")
                .is_some_and(|save| !brick.flag(w, save, "enabled"))
        })
    });
    steps.step(&format!("{Q} adds its own settings page"), |world, c, _| {
        change_contributions(world, &c[0], |parts| {
            parts.insert("settingsPage".into(), json!("settings/Settings.qml"));
        })?;
        world.wait_for_with(
            |w| !text(&listed(w, &c[0], "")["settingsPageUrl"]).is_empty(),
            describe,
        )
    });
    steps.step("the plugin's settings page is shown", |world, _, _| {
        let own = wait_named(world, "pluginOwnSettings")?;
        let brick = shell(world)?;
        world.wait_for("the plugin's page to be drawn", |w| {
            brick
                .shows_under(w, own, "[code-review settings]")
                .unwrap_or(false)
        })?;
        let field = item(world, "pluginSetting:repos")?;
        expect!(
            field.is_none_or(|field| !brick.flag(world, field, "visible")),
            "the generated fields are shown too"
        );
        Ok(())
    });
    steps.step(
        &format!("the user saves settings that {Q} refuses"),
        |world, c, _| {
            fake(world).refusal = "acme/nope is not a repository".into();
            open_settings(world, &c[0])?;
            set_setting(
                world,
                "repos",
                Value::List(std::sync::Arc::new(vec![string("acme/nope")])),
            )?;
            let save = wait_named(world, "pluginSettingsSave")?;
            click_item(world, save)
        },
    );
    steps.step("the plugin's message is shown", |world, _, _| {
        let refusal = wait_named(world, "pluginSettingsRefusal")?;
        let brick = shell(world)?;
        let said = brick.text_of(world, refusal, "text");
        let wanted = fake(world).refusal.clone();
        expect!(said.contains(&wanted), "{}", said);
        Ok(())
    });
    steps.step("the saved settings are unchanged", |world, _, _| {
        let environment = world.mc.environment_id.clone();
        let entry = fake(world)
            .plugins
            .get(&environment)
            .and_then(|list| list.first().cloned())
            .unwrap_or(Json::Null);
        expect!(
            entry.get("saved").is_none(),
            "the MC saved {}",
            show(&entry["saved"])
        );
        // What the user typed stays, to be fixed and saved again.
        let save = wait_named(world, "pluginSettingsSave")?;
        let brick = shell(world)?;
        expect!(
            brick.flag(world, save, "enabled"),
            "the page forgot the change"
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} is listed as failed with its last error"),
        |world, c, _| {
            change(world, &c[0], |entry| {
                entry["status"] = json!("failed");
                entry["lastError"] = json!("exited with status 1");
            })?;
            wait_status(world, &c[0], "failed")
        },
    );
    steps.step(
        &format!("{Q} is listed as (\\w+) because {Q}"),
        |world, c, _| {
            change(world, &c[0], |entry| {
                entry["status"] = json!(c[1]);
                entry["error"] = json!(c[2]);
            })?;
            wait_status(world, &c[0], &c[1])
        },
    );
    steps.step(&format!("the card of {Q} says {Q}"), |world, c, _| {
        let list = show_plugin_list(world)?;
        let brick = shell(world)?;
        let says = |w: &World| {
            card(w, &brick, list, &c[0])
                .and_then(|card| brick.find_under(w, card, "mcPluginStatus").ok().flatten())
                .map(|status| brick.text_of(w, status, "text"))
                .unwrap_or_default()
        };
        world.wait_for_with(
            |w| says(w) == c[1],
            |w| format!("the card says \"{}\"", says(w)),
        )
    });
    steps.step(
        &format!("the card of {Q} offers no restart"),
        |world, c, _| {
            let list = show_plugin_list(world)?;
            let brick = shell(world)?;
            let restart = card(world, &brick, list, &c[0]).and_then(|card| {
                brick
                    .find_under(world, card, "mcPluginRestart")
                    .ok()
                    .flatten()
            });
            expect!(
                restart.is_some_and(|restart| !brick.flag(world, restart, "visible")),
                "the card offers a restart"
            );
            Ok(())
        },
    );
    steps.step("the settings offer no restart", |world, _, _| {
        let failure = wait_named(world, "pluginSettingsFailure")?;
        let brick = shell(world)?;
        // The restart button sits beside the failure message.
        let restart = brick.visible_beside(world, failure, "pluginSettingsRestart")?;
        let hidden = match restart {
            Some(_) => false,
            None => brick
                .find(world, "pluginSettingsRestart")?
                .is_some_and(|restart| !brick.flag(world, restart, "visible")),
        };
        expect!(hidden, "the settings offer a restart");
        Ok(())
    });
    steps.step(&format!("the settings say {Q}"), |world, c, _| {
        let failure = wait_named(world, "pluginSettingsFailure")?;
        let brick = shell(world)?;
        world.wait_for_with(
            |w| brick.text_of(w, failure, "text") == c[0],
            |w| brick.text_of(w, failure, "text"),
        )
    });
    steps.step("the MC runs no plugins", |world, _, _| {
        let environment = world.mc.environment_id.clone();
        fake(world).plugins.entry(environment).or_default().clear();
        announce(world);
        world.wait_for_with(|w| listed(w, CODE_REVIEW, "").is_null(), describe)
    });
    steps.step(
        &format!("the MC's plugins folder gains the plugin {Q}"),
        |world, c, _| {
            let mut entry = code_review();
            entry["id"] = json!(c[0]);
            entry["name"] = json!(c[0]);
            entry["status"] = json!("disabled");
            let environment = world.mc.environment_id.clone();
            fake(world)
                .unscanned
                .entry(environment)
                .or_default()
                .push(entry);
            Ok(())
        },
    );
    steps.step(
        "the user looks for plugins on that environment",
        |world, _, _| {
            let list = show_plugin_list(world)?;
            let brick = shell(world)?;
            let name = format!("mcPlugins:{}", world.mc.environment_id);
            world.wait_for("the environment in the plugin list", |w| {
                matches!(brick.find_under(w, list, &name), Ok(Some(_)))
            })?;
            let environment = brick.find_under(world, list, &name)?.expect("listed");
            match brick.find_under(world, environment, "mcPluginsRescan")? {
                Some(rescan) => click_item(world, rescan),
                None => fail!("the environment has no rescan"),
            }
        },
    );
    steps.step(&format!("{Q} is listed as disabled"), |world, c, _| {
        wait_status(world, &c[0], "disabled")
    });
    steps.step(&format!("the user restarts {Q}"), |world, c, _| {
        open_settings(world, &c[0])?;
        let restart = wait_named(world, "pluginSettingsRestart")?;
        click_item(world, restart)
    });
    steps.step(&format!("{Q} runs again"), |world, c, _| {
        wait_status(world, &c[0], "running")?;
        let restarts = calls_of(world, "plugins.restart").len();
        expect!(restarts == 1, "the plugin was not restarted");
        Ok(())
    });

    // The shell's named places, and the way to the MC part.
    steps.step(&format!("{Q} contributes to {Q}"), |world, c, _| {
        change_contributions(world, &c[0], |parts| {
            parts.insert(
                "slots".into(),
                json!([{"slot": c[1], "qml": "slots/Section.qml"}]),
            );
        })
    });
    steps.step(
        "the plugin's section is shown below the threads",
        |world, _, _| {
            let slot = wait_named(world, "sidebarSectionsSlot")?;
            let brick = shell(world)?;
            world.wait_for_with(
                |w| {
                    brick
                        .shows_under(w, slot, "[code-review section]")
                        .unwrap_or(false)
                },
                describe,
            )
        },
    );
    steps.step(
        &format!("the page asks {Q} for its reviews"),
        |world, _, _| {
            let page = plugin_page(world)?;
            ask_page(world, page, "")
        },
    );
    steps.step(
        &format!("the answer comes from the MC that runs {Q}"),
        |world, c, _| {
            let page = plugin_page(world)?;
            let brick = shell(world)?;
            let wanted = format!("Reviews on {}", world.mc.environment_id);
            world.wait_for_with(
                |w| brick.text_of(w, page, "answer") == wanted,
                |w| {
                    format!(
                        "the answer; the page has {}",
                        brick.text_of(w, page, "answer")
                    )
                },
            )?;
            let payload = calls_of(world, "plugins.call")
                .first()
                .map(|rpc| rpc.payload.clone())
                .unwrap_or(Json::Null);
            expect!(
                payload["id"] == json!(c[0])
                    && payload["method"] == json!("reviews")
                    && payload["input"] == json!({"state": "failed"}),
                "the MC was asked {}",
                show(&payload)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the {Q} page watches the {Q} topic"),
        |world, c, _| {
            show_page(world, &c[0])?;
            world.wait_for("the page to watch the topic", |w| {
                w.mc.subscribers("plugin")
                    .iter()
                    .any(|sub| w.mc.shape_of(*sub)["topic"] == json!(c[1]))
            })?;
            wait_reviews(world, "Add cache, Fix login")
        },
    );
    steps.step(
        &format!("another part of {Q} watches the {Q} topic"),
        |world, c, _| {
            let page = plugin_page(world)?;
            call(world, page, "watchAgain", &[string(&c[1])]).map(|_| ())
        },
    );
    steps.step(
        "the other part is given the last list at once",
        |world, _, _| {
            let page = plugin_page(world)?;
            let brick = shell(world)?;
            let wanted = fake(world).reviews.len() as i32;
            world.wait_for_with(
                |w| matches!(brick.read(w, page, "seen"), Value::Int(seen) if seen == wanted),
                |w| {
                    format!(
                        "the other part has {} reviews",
                        brick.text_of(w, page, "seen")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the MC sends the {Q} topic to the client once"),
        |world, c, _| {
            let following = world
                .mc
                .subscribers("plugin")
                .iter()
                .filter(|sub| world.mc.shape_of(**sub)["topic"] == json!(c[0]))
                .count();
            expect!(
                following == 1,
                "the client follows the topic {} times",
                following
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} publishes a new list of reviews"),
        |world, _, _| {
            fake(world)
                .reviews
                .push(json!({"title": "Bump deps", "state": "running"}));
            let reviews = Json::Array(fake(world).reviews.clone());
            for subscriber in world.mc.subscribers("plugin") {
                world
                    .mc
                    .send(&json!({"t": "plugin", "id": subscriber, "topic": "reviews",
                                      "value": reviews}));
            }
            Ok(())
        },
    );
    steps.step(
        "the page shows the new list without reloading",
        |world, _, _| {
            wait_reviews(world, "Add cache, Fix login, Bump deps")?;
            let page = wait_named(world, "reviewsPage")?;
            expect!(Some(page) == fake(world).page, "the page was made again");
            Ok(())
        },
    );
    steps.step(
        &format!("the MC runs a new version of {Q}"),
        |world, c, _| {
            change(world, &c[0], |entry| {
                entry["revision"] = json!("2");
                entry["version"] = json!("1.1.0");
            })
        },
    );
    steps.step(
        "the page is loaded again from the new version",
        |world, _, _| {
            let brick = shell(world)?;
            world.wait_for_with(
                |w| {
                    named(w, brick, "reviewsPage")
                        .is_some_and(|page| brick.text_of(w, page, "version") == "2")
                },
                describe,
            )?;
            let page = named(world, brick, "reviewsPage").expect("shown");
            expect!(
                Some(page) != fake(world).page && brick.flag(world, page, "visible"),
                "the new page is not shown"
            );
            Ok(())
        },
    );
    steps.step("only the new version's UI parts are kept", |world, _, _| {
        world.wait_for_with(
            |w| text(&page_on(w, &w.mc.environment_id)["url"]).contains("/2/running/"),
            describe,
        )?;
        // The plugin's directory of the cache: <plugin>/<revision>/running/<path>.
        let url = text(&page_on(world, &world.mc.environment_id)["url"]);
        let path = url.strip_prefix("file://").unwrap_or(&url);
        let path = &path[..path.find("/2/running/").unwrap_or(path.len())];
        let folders = |dir: &str| -> Vec<String> {
            let mut names: Vec<String> = std::fs::read_dir(dir)
                .map(|entries| {
                    entries
                        .flatten()
                        .filter(|entry| entry.path().is_dir())
                        .map(|entry| entry.file_name().to_string_lossy().into_owned())
                        .collect()
                })
                .unwrap_or_default();
            names.sort();
            names
        };
        let versions = folders(path);
        let modes = folders(&format!("{path}/2"));
        expect!(
            versions == ["2"] && modes == ["running"],
            "the cache keeps {} and {}",
            versions.join(", "),
            modes.join(", ")
        );
        Ok(())
    });
}

// What PluginSteps and the steps files of the plugins' own features share
// (Plugins.h).

/// The scenario's MC runs the plugin `entry` (as `plugins` lists it) with
/// `part` as its MC part, and the client lists it running.
pub fn run_fake_plugin(world: &mut World, entry: Json, part: FakePluginPart) -> Outcome {
    let id = text(&entry["id"]);
    fake(world).parts.insert(id.clone(), part);
    let environment = world.mc.environment_id.clone();
    publish_plugin(world, &environment, entry);
    shell(world)?;
    announce(world);
    wait_status(world, &id, "running")
}

/// The environment `environment` joins the cluster running the faked plugin
/// `entry` too.
pub fn run_fake_plugin_on(world: &mut World, environment: &str, entry: Json) -> Outcome {
    let id = text(&entry["id"]);
    publish_plugin(world, environment, entry);
    world.mc.join_named(environment);
    world.wait_for_with(
        |w| listed(w, &id, environment)["status"] == json!("running"),
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

/// The shown item named `name` in the window, once it is (and `ready`).
pub fn wait_shown_named(
    world: &mut World,
    name: &str,
    ready: impl Fn(&World, Brick, ObjectId) -> bool,
) -> Outcome<ObjectId> {
    wait_named_when(world, name, ready)
}

/// The user clicks the tab `title` in the window's strip.
pub fn switch_to_tab(world: &mut World, title: &str) -> Outcome {
    click_tab(world, title)?;
    wait_named(world, "pluginPages").map(|_| ())
}

/// A thread the plugin started (`plugin` is its {id, kind, listed}), in the shell.
pub fn add_plugin_thread(world: &mut World, id: &str, title: &str, plugin: Json) -> Outcome {
    add_thread(world, id, title, Some(plugin))
}

pub fn open_plugin_thread(world: &mut World, id: &str) -> Outcome {
    open_thread(world, id)
}

/// Whether the scenario's MC runs a plugin `id`.
pub fn is_mc_plugin(world: &mut World, id: &str) -> bool {
    fake(world)
        .plugins
        .values()
        .any(|plugins| plugins.iter().any(|entry| entry["id"] == json!(id)))
}

/// Flips plugin `id`'s switch in the plugin list ("the user enables/disables").
pub fn switch_mc_plugin(world: &mut World, id: &str) -> Outcome {
    let list = show_plugin_list(world)?;
    let brick = shell(world)?;
    world.wait_for_with(|w| card(w, &brick, list, id).is_some(), describe)?;
    let card = card(world, &brick, list, id).expect("listed");
    match brick.find_under(world, card, "mcPluginToggle")? {
        Some(toggle) => click_item(world, toggle)?,
        None => fail!("the card of {} has no switch", id),
    }
    world.sync()
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

/// `wait_shown_named` with nothing more to wait for.
pub fn shown_named(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    wait_shown_named(world, object_name, |_, _, _| true)
}
