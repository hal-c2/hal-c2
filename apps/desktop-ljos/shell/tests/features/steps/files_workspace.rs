//! The Files tab of the thread the scenario looks at, for the files steps
//! (desktop-qt's FilesWorkspace.h): the tab's tree and viewer, the
//! environment's editors, and what the MC was asked to open. No steps.

use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::thread_view::file_tree::FileTreeModel;
use hal_c2_shell::thread_view::workspace_files::WorkspaceFiles;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use crate::brick::{self, Brick};
use crate::harness::{Outcome, show};
use crate::world::World;
use crate::{expect, fail};

/// The config this MC serves the Files steps set (`setConfig`), by key.
#[derive(Default)]
pub struct ConfigFields(pub serde_json::Map<String, Json>);

/// The `WorkspaceFiles` of the right panel.
pub fn files(world: &World) -> Outcome<ObjectId> {
    match world.with::<RightPanel, _>(|p, _| p.files())? {
        Some(object) => Ok(object),
        None => fail!("the right panel has no Files tab"),
    }
}

fn read(world: &World, name: &str) -> Value {
    match files(world) {
        Ok(object) => world.engine().read_by_name(object, name),
        Err(_) => Value::Undefined,
    }
}

/// A text property of the Files tab (openPath, fileStatus, fileProblem,
/// mediaKind, mediaUrl, root, text, truncatedNotice, ...).
pub fn text_prop(world: &World, name: &str) -> String {
    match read(world, name) {
        Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

pub fn flag_prop(world: &World, name: &str) -> bool {
    read(world, name) == Value::Bool(true)
}

pub fn int_prop(world: &World, name: &str) -> i64 {
    match read(world, name) {
        Value::Int(i) => i64::from(i),
        Value::Real(d) => d as i64,
        _ => 0,
    }
}

pub fn open_path(world: &World) -> String {
    text_prop(world, "openPath")
}

pub fn file_status(world: &World) -> String {
    text_prop(world, "fileStatus")
}

/// The folder of the thread's workspace on its environment.
pub fn workspace_root(world: &World) -> String {
    text_prop(world, "root")
}

/// The environment the Files tab follows.
pub fn environment(world: &World) -> String {
    world
        .with::<RightPanel, _>(|p, engine| {
            p.files()
                .and_then(|o| WorkspaceFiles::read(engine, o, |f| f.environment().to_owned()))
                .unwrap_or_default()
        })
        .unwrap_or_default()
}

pub fn tree(world: &World) -> Outcome<ObjectId> {
    match WorkspaceFiles::tree(world.engine(), files(world)?) {
        Some(tree) => Ok(tree),
        None => fail!("the Files tab has no tree"),
    }
}

pub fn visible_paths(world: &World) -> Vec<String> {
    tree(world)
        .ok()
        .and_then(|t| FileTreeModel::read(world.engine(), t, |tree| tree.visible_paths()))
        .unwrap_or_default()
}

pub fn root_status(world: &World) -> String {
    tree(world)
        .ok()
        .and_then(|t| FileTreeModel::read(world.engine(), t, |tree| tree.root_status().to_owned()))
        .unwrap_or_default()
}

pub fn describe_tree(world: &World) -> String {
    format!(
        "the tree ({}) shows [{}]",
        root_status(world),
        visible_paths(world).join(", ")
    )
}

fn tree_settled(world: &World) -> bool {
    if flag_prop(world, "searching") || root_status(world) == "loading" {
        return false;
    }
    let Ok(tree) = tree(world) else { return false };
    let engine = world.engine();
    let Some(model) = engine.object_model(tree) else {
        return true;
    };
    !(0..model.row_count()).any(|row| {
        matches!(model.data(engine, row, "kind"), Value::String(s) if s.as_str() == "loading")
    })
}

pub fn wait_for_tree(world: &mut World) -> Outcome {
    world.wait_for_with(tree_settled, |w| {
        format!("the tree to settle; {}", describe_tree(w))
    })
}

/// The Files tab, shown.
pub fn open_files_tab(world: &mut World) -> Outcome {
    let shown = world.with::<RightPanel, _>(|p, _| p.is_open() && p.active_tab() == "files")?;
    if !shown {
        world.dispatch("rightPanel.add", json!({"kind": "files"}))?;
    }
    wait_for_tree(world)
}

pub fn open_file(world: &mut World, path: &str) -> Outcome {
    world.dispatch("files.open", json!({"path": path}))?;
    world.wait_for_with(
        |w| open_path(w) == path && file_status(w) != "loading",
        |w| {
            format!(
                "{path} to load; the viewer has \"{}\" ({})",
                open_path(w),
                file_status(w)
            )
        },
    )
}

/// The MC's config with `fields` changed, announced as it announces a change.
pub fn set_config(world: &mut World, fields: Json) -> Outcome {
    if let Json::Object(fields) = fields {
        world.mc.part::<ConfigFields>().0.extend(fields);
    }
    let config = Json::Object(world.mc.part::<ConfigFields>().0.clone());
    let environment = world.mc.environment_id.clone();
    for id in world.mc.subscribers("config") {
        if world.mc.shape_of(id)["environment"] != json!(environment) {
            continue;
        }
        world
            .mc
            .send(&json!({"t": "config", "id": id, "config": config}));
    }
    world.sync()
}

/// packages/contracts EDITORS: the id of the editor the scenario names.
pub fn editor_id(label: &str) -> Outcome<&'static str> {
    match label {
        "VS Code" => Ok("vscode"),
        "Zed" => Ok("zed"),
        "Cursor" => Ok("cursor"),
        _ => fail!("{label} is not an editor these steps know"),
    }
}

/// Every `shell.openInEditor` the MC was asked.
pub fn editor_calls(world: &mut World) -> Outcome<Vec<Json>> {
    world.sync()?;
    Ok(world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "shell.openInEditor")
        .map(|rpc| rpc.payload.clone())
        .collect())
}

/// The Files tab as the right panel draws it.
pub fn show_panel(world: &mut World) -> Outcome<Brick> {
    open_files_tab(world)?;
    let current = world
        .part::<brick::Shown>()
        .0
        .and_then(|b| b.root(world))
        .map(|root| world.engine().read_by_name(root, "objectName"));
    let is_panel = matches!(current, Some(Value::String(s)) if s.as_str() == "filesPanel");
    if !is_panel {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nFilesPanel { source: Panel.files }\n",
            540.0,
            700.0,
        )?;
    }
    brick::shown(world)
}

/// The entry named `entry` of the menu `menu_name` the panel keeps.
fn menu_entry(
    world: &World,
    brick: Brick,
    menu_name: &str,
    entry: &str,
) -> Outcome<Option<ObjectId>> {
    let Some(menu) = brick.find(world, menu_name)? else {
        fail!("the Files tab has no {menu_name}");
    };
    let engine = world.engine();
    let count = match engine.read_by_name(menu, "count") {
        Value::Int(n) => n,
        _ => 0,
    };
    for index in 0..count {
        if let Ok(Value::Object(item)) = engine.invoke_by_name(menu, "itemAt", &[Value::Int(index)])
            && engine.read_by_name(item, "objectName") == Value::from(entry)
        {
            return Ok(Some(item));
        }
    }
    Ok(None)
}

/// Chooses `entry` from the menu of `path`'s row.
pub fn choose(world: &mut World, path: &str, entry: &str) -> Outcome {
    let brick = show_panel(world)?;
    let Some(menu) = brick.find(world, "fileEntryMenu")? else {
        fail!("the Files tab has no entry menu");
    };
    brick.write(world, menu, "path", Value::from(path))?;
    let item = menu_entry(world, brick, "fileEntryMenu", entry)?;
    let offered = item.is_some_and(|i| brick.flag(world, i, "enabled"));
    expect!(offered, "the menu does not offer {entry}");
    if let Some(item) = item
        && let Err(error) = world.engine().invoke_by_name(item, "triggered", &[])
    {
        fail!("triggered: {error}");
    }
    world.pump()
}

/// What the MC was asked, for a failure.
pub fn show_calls(calls: &[Json]) -> String {
    show(&json!(calls))
}

/// A file the viewer's scenarios name without saying what it holds: made,
/// when the project has none at `path`, with contents of its kind.
pub fn ensure_viewer_file(world: &mut World, path: &str) {
    let files = super::fake_files::fake_files(&mut world.mc);
    if files.files.contains_key(path) {
        return;
    }
    let contents = match path.rsplit('.').next().map(str::to_lowercase).as_deref() {
        Some("md") => "# Guide\n\nHow the **cart** adds up.\n\n- one\n- two\n",
        Some("csv") => "order,total\n1001,12.50\n1002,\"7,25\"\n",
        Some("html") => "<html><body><h1>Shop</h1><p>Open <b>daily</b>.</p></body></html>\n",
        _ => "export const value = 1;\nexport const other = 2;\n",
    };
    files.files.insert(path.to_owned(), contents.to_owned());
}

/// The file another surface (a diff's open in editor) last opened, and the
/// editor it chose; empty when none did.
#[derive(Default)]
pub struct OpenedInEditor {
    pub path: String,
    pub editor: String,
}

/// Answers a `config` subscription with the fields `set_config` set so far.
pub fn serve_config(mc: &mut crate::fake_mc::FakeMc) {
    mc.on_shape("config", |mc, id, _| {
        let config = Json::Object(mc.part::<ConfigFields>().0.clone());
        mc.send(&json!({"t": "config", "id": id, "config": config}));
        Ok(())
    });
}
