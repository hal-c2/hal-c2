//! UI plugins on the desktop (features/plugins/ui-plugins.feature,
//! plugin-catalog.feature): plugin files in the shell's config directory,
//! loaded into the real DefaultShell window by the bricks' PluginRegistry, and
//! the plugin controller's list, switches and URL installs: desktop-qt's
//! PluginSteps.cpp.
//!
//! The helpers the other plugin steps files share (`shell`, `find_named`,
//! `click_item`, `show_plugin_list`, `draws_text`, `answer_question`) are
//! `pub`, as Plugins.h declares them.

use std::io::{Read, Write};
use std::net::Shutdown;
use std::time::Duration;

use hal_c2_shell::json;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use crate::brick::{Brick, Shown, shown};
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// What the MC's web server hands out as plugin files, and what was asked of it.
#[derive(Default)]
struct FakePluginSite {
    files: std::collections::HashMap<String, String>,
    requests: Vec<String>,
}

#[derive(Default)]
struct PluginWorld {
    url: String,
    plugin: String,
    draft: String,
    /// The desktop's window, once shown, and its root.
    window: Option<(Brick, ObjectId)>,
}

fn extension(mc: &mut FakeMc) {
    mc.on_raw("/plugin-files/", |mc, mut stream, head| {
        let target = head
            .lines()
            .next()
            .and_then(|line| line.split(' ').nth(1))
            .unwrap_or_default()
            .to_owned();
        // The request is still on the socket (`head` only peeked at it): read
        // to its end, for the socket to close quietly.
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut buffer = [0u8; 4096];
        let mut seen = String::new();
        while !seen.contains("\r\n\r\n") {
            match stream.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => seen.push_str(&String::from_utf8_lossy(&buffer[..n])),
            }
        }
        let fake = mc.part::<FakePluginSite>();
        fake.requests.push(target.clone());
        let name = target.rsplit('/').next().unwrap_or_default().to_owned();
        let body = fake.files.get(&name).cloned().unwrap_or_default();
        let response = if body.is_empty() {
            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_owned()
        } else {
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
        };
        let _ = stream.write_all(response.as_bytes());
        let _ = stream.flush();
        let _ = stream.shutdown(Shutdown::Both);
        Ok(())
    });
}

/// A plugin as the terminal client's fixtures write one: "[id]" in its slot.
fn plugin_source(id: &str, slot: &str, label: &str) -> String {
    let label = if label.is_empty() {
        format!("[{id}]")
    } else {
        label.to_owned()
    };
    format!(
        "import OpenTUI\nPlugin {{\n  pluginId: \"{id}\"\n  order: 0\n  Contribution {{ slot: \"{slot}\"\n    Text {{ objectName: \"plugin-{id}\"; text: \"{label}\" }} }}\n}}\n"
    )
}

fn plugin_path(world: &World, id: &str) -> std::path::PathBuf {
    let dir = text(&world.state("plugins")["dir"]);
    let dir = if dir.is_empty() {
        world.config_dir().join("plugins")
    } else {
        dir.into()
    };
    dir.join(format!("{id}.qml"))
}

fn write_file(path: &std::path::Path, content: &str) -> Outcome {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    std::fs::write(path, content)
        .map_err(|e| crate::harness::Failure(format!("cannot write {}: {e}", path.display())))
}

fn plugins(world: &World) -> Json {
    world.state("plugins")
}

fn entry(list: &Json, id: &str) -> Json {
    list.as_array()
        .and_then(|list| list.iter().find(|e| e["id"] == json!(id)))
        .cloned()
        .unwrap_or(Json::Null)
}

fn loaded(world: &World, id: &str) -> Json {
    entry(&plugins(world)["items"], id)
}

fn disabled(world: &World, id: &str) -> Json {
    entry(&plugins(world)["disabled"], id)
}

fn failed(world: &World, id: &str) -> Json {
    entry(&plugins(world)["failed"], id)
}

fn describe(world: &World) -> String {
    let mut state = plugins(world);
    if let Some(map) = state.as_object_mut() {
        map.remove("files");
    }
    // TODO(ljos#105): a plugin file is QML text, which the shell cannot
    // compile while it runs.
    let gap = if show(&state).contains("has no compiler") {
        " (ljos#105)"
    } else {
        ""
    };
    format!("the plugins are {}{gap}", show(&state))
}

fn count(value: &Json) -> usize {
    value.as_array().map_or(0, Vec::len)
}

/// The desktop's own window, drawn by DefaultShell as the app draws it.
pub fn shell(world: &mut World) -> Outcome<Brick> {
    if let Some((brick, _)) = world.part::<PluginWorld>().window {
        return Ok(brick);
    }
    if world.shell_subscriptions() == 0 {
        // A desktop already set up: a project, so the welcome wizard stays away.
        if world.mc.projects.is_empty() {
            world.mc.projects.insert(
                "p1".to_owned(),
                json!({"id": "p1", "title": "p1", "workspaceRoot": "/work/p1", "scripts": []}),
            );
        }
        world.connect()?;
        world.sync()?;
    }
    Brick::show(
        world,
        "import HalC2.Bricks\nDefaultShell { width: 1200; height: 800 }\n",
        1200.0,
        800.0,
    )?;
    let brick = shown(world)?;
    let Some(root) = brick.root(world) else {
        fail!("the default shell did not load")
    };
    world.part::<PluginWorld>().window = Some((brick, root));
    Ok(brick)
}

/// The item named `object_name` under `root`, or none.
pub fn find_named(
    world: &mut World,
    root: ObjectId,
    object_name: &str,
) -> Outcome<Option<ObjectId>> {
    let brick = shell(world)?;
    brick.find_under(world, root, object_name)
}

fn item(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    let brick = shell(world)?;
    match brick.find(world, object_name)? {
        Some(found) => Ok(found),
        None => fail!("the window has no {object_name}"),
    }
}

fn slot_object(name: &str) -> Outcome<&'static str> {
    Ok(match name {
        "sidebar.footer" => "sidebarFooterSlot",
        "composer.actions" => "composerActionsSlot",
        "statusbar" => "statusbarSlot",
        other => fail!("the desktop has no slot {other}"),
    })
}

fn shown_in(world: &mut World, slot: &str) -> Outcome<Vec<String>> {
    let brick = shell(world)?;
    let found = item(world, slot_object(slot)?)?;
    let value = json::from_value(world.engine(), &brick.read(world, found, "shown"));
    Ok(value
        .as_array()
        .map(|list| list.iter().map(text).collect())
        .unwrap_or_default())
}

/// Whether `item`, or a visible item under it, draws `text`.
pub fn draws_text(world: &mut World, item: ObjectId, text: &str) -> Outcome<bool> {
    let brick = shell(world)?;
    brick.shows_under(world, item, text)
}

fn slot_draws(world: &mut World, slot: &str, text: &str) -> Outcome<bool> {
    let found = item(world, slot_object(slot)?)?;
    draws_text(world, found, text)
}

/// `shown_in` for a wait's condition: a failure is "not yet".
fn is_shown_in(world: &World, brick: Brick, slot: &str, id: &str) -> bool {
    let Ok(object) = slot_object(slot) else {
        return false;
    };
    let Ok(Some(found)) = brick.find(world, object) else {
        return false;
    };
    let value = json::from_value(world.engine(), &brick.read(world, found, "shown"));
    value
        .as_array()
        .is_some_and(|list| list.iter().any(|shown| shown == &json!(id)))
}

fn wait_loaded(world: &mut World, id: &str) -> Outcome {
    shell(world)?;
    let wanted = id.to_owned();
    world.wait_for_with(
        |w| !loaded(w, &wanted).is_null(),
        |w| format!("{id} to load; {}", describe(w)),
    )
}

fn load_plugin(world: &mut World, id: &str, slot: &str) -> Outcome {
    write_file(&plugin_path(world, id), &plugin_source(id, slot, ""))?;
    wait_loaded(world, id)
}

fn wait_shown(world: &mut World, slot: &str, id: &str, label: &str) -> Outcome {
    let brick = shell(world)?;
    let text = if label.is_empty() {
        format!("[{id}]")
    } else {
        label.to_owned()
    };
    let object = slot_object(slot)?;
    world.wait_for_with(
        |w| {
            let Ok(Some(found)) = brick.find(w, object) else {
                return false;
            };
            is_shown_in(w, brick, slot, id)
                && brick.shows_under(w, found, &text).unwrap_or(false)
                && brick.flag(w, found, "visible")
        },
        |w| {
            let shown = brick
                .find(w, object)
                .ok()
                .flatten()
                .map(|found| {
                    show(&json::from_value(
                        w.engine(),
                        &brick.read(w, found, "shown"),
                    ))
                })
                .unwrap_or_default();
            format!(
                "{slot} to show \"{text}\"; it shows {shown}; {}",
                describe(w)
            )
        },
    )?;
    // A plugin that names no colour is drawn in the theme's text colour,
    // readable on it. The theme's own colour cannot be read from here (Ljós
    // has no singleton lookup), so this holds it to a colour that is set and
    // not black.
    let found = item(world, &format!("plugin-{id}"))?;
    match brick.read(world, found, "color") {
        Value::Color(colour) => {
            expect!(
                colour.is_valid() && colour != ljos::prelude::Color::BLACK,
                "the plugin's text is {colour:?}"
            );
        }
        other => fail!("the plugin's text colour is {other:?}"),
    }
    Ok(())
}

fn disable(world: &mut World, id: &str) -> Outcome {
    world.dispatch("plugins.disable", json!({"id": id}))?;
    let wanted = id.to_owned();
    world.wait_for_with(
        |w| loaded(w, &wanted).is_null() && !disabled(w, &wanted).is_null(),
        describe,
    )
}

fn question(world: &World) -> Json {
    world.state("confirmation")
}

/// Answers the confirmation the shell asks.
pub fn answer_question(world: &mut World, accepted: bool) -> Outcome {
    let asked = question(world);
    expect!(asked.is_object(), "no question is asked");
    world.dispatch(
        "confirmation.answer",
        json!({"requestId": asked["requestId"], "accepted": accepted}),
    )
}

fn toasted(world: &World, kind: &str, title: &str) -> bool {
    at(&world.state("toasts"), "items")
        .as_array()
        .is_some_and(|toasts| {
            toasts
                .iter()
                .any(|toast| toast["title"] == json!(title) && toast["type"] == json!(kind))
        })
}

/// Settings → Plugins, open in the window.
pub fn show_plugin_list(world: &mut World) -> Outcome<ObjectId> {
    let brick = shell(world)?;
    world.dispatch("settings.navigate", json!({"to": "/settings/plugins"}))?;
    world.wait_for_with(
        |w| {
            matches!(brick.find(w, "pluginsSettings"), Ok(Some(page)) if brick.flag(w, page, "visible"))
        },
        |w| format!("the plugin list; the window shows {}", show(&w.state("route"))),
    )?;
    brick.item(world, "pluginsSettings")
}

/// Clicks `target` in the window, as the user does.
pub fn click_item(world: &mut World, target: ObjectId) -> Outcome {
    let brick = shell(world)?;
    let visible = brick.flag(world, target, "visible");
    let enabled = brick.flag(world, target, "enabled");
    expect!(
        visible && enabled,
        "{} cannot be clicked",
        brick.text_of(world, target, "objectName")
    );
    let (x, y) = brick.at(world, target, 0.5, 0.5)?;
    world.click_at(x, y)
}

/// The plugin list's row for `id`, once it is listed.
fn plugin_row(world: &mut World, id: &str) -> Outcome<(Brick, ObjectId)> {
    let page = show_plugin_list(world)?;
    let brick = shell(world)?;
    let name = format!("plugin:{id}");
    world.wait_for_with(
        |w| matches!(brick.find_under(w, page, &name), Ok(Some(_))),
        describe,
    )?;
    match brick.find_under(world, page, &name)? {
        Some(row) => Ok((brick, row)),
        None => fail!("the plugin list has no {name}"),
    }
}

fn detail(world: &mut World, id: &str) -> Outcome<String> {
    let (brick, row) = plugin_row(world, id)?;
    match brick.find_under(world, row, "pluginDetail")? {
        Some(detail) => Ok(brick.text_of(world, detail, "text")),
        None => fail!("{id}'s row has no detail"),
    }
}

fn toggle(world: &mut World, id: &str) -> Outcome {
    let (brick, row) = plugin_row(world, id)?;
    match brick.find_under(world, row, "pluginToggle")? {
        Some(switch) => click_item(world, switch)?,
        None => fail!("{id}'s row has no switch"),
    }
    world.sync()
}

fn paste_url(world: &mut World, url: &str) -> Outcome {
    let page = show_plugin_list(world)?;
    let brick = shell(world)?;
    let Some(field) = brick.find_under(world, page, "pluginUrl")? else {
        fail!("the plugin list has no address field")
    };
    brick.write(world, field, "text", Value::from(url))?;
    let Some(load) = brick.find_under(world, page, "pluginLoad")? else {
        fail!("the plugin list has no load button")
    };
    click_item(world, load)?;
    world.part::<PluginWorld>().url = url.to_owned();
    world.wait_for("the question about the unsigned plugin", |w| {
        question(w).is_object()
    })
}

fn serve(world: &mut World, id: &str) -> String {
    world
        .mc
        .part::<FakePluginSite>()
        .files
        .insert(format!("{id}.qml"), plugin_source(id, "statusbar", ""));
    world.part::<PluginWorld>().plugin = id.to_owned();
    format!("{}/plugin-files/{id}.qml", world.mc.origin())
}

fn forget_window(world: &mut World) {
    world.part::<PluginWorld>().window = None;
    world.part::<Shown>().0 = None;
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        "a client whose shell exposes the slots \"sidebar.footer\", \"composer.actions\" and \"statusbar\"",
        |world, _, _| {
            let brick = shell(world)?;
            for name in ["sidebar.footer", "composer.actions", "statusbar"] {
                let found = item(world, slot_object(name)?)?;
                expect!(
                    brick.text_of(world, found, "name") == name,
                    "the shell has no slot {name}"
                );
            }
            expect!(count(&plugins(world)["items"]) == 0, "{}", describe(world));
            Ok(())
        },
    );

    // The same file as the terminal client loads.
    steps.step(
        &format!("the plugin {Q} contributes to {Q}"),
        |world, c, _| {
            write_file(&plugin_path(world, &c[0]), &plugin_source(&c[0], &c[1], ""))?;
            world.part::<PluginWorld>().plugin = c[0].clone();
            Ok(())
        },
    );
    steps.step(
        "the same plugin file is loaded on the desktop app",
        |world, _, _| {
            let id = world.part::<PluginWorld>().plugin.clone();
            wait_loaded(world, &id)
        },
    );
    steps.step(
        &format!("the desktop sidebar footer shows {Q}"),
        |world, c, _| {
            wait_shown(world, "sidebar.footer", &c[0], "")?;
            let shown = shown_in(world, "sidebar.footer")?;
            expect!(shown == vec![c[0].clone()], "{}", shown.join(", "));
            Ok(())
        },
    );
    steps.step(
        &format!("the plugin file {Q} uses only shared components"),
        |world, c, _| {
            let id = c[0].replace(".qml", "");
            write_file(
                &plugin_path(world, &id),
                &plugin_source(&id, "sidebar.footer", ""),
            )?;
            world.part::<PluginWorld>().plugin = id;
            Ok(())
        },
    );
    // The desktop's part of it; the other surfaces are their runners'.
    steps.step(
        "it is loaded on the desktop app, the mobile app and the TUI",
        |world, _, _| {
            let id = world.part::<PluginWorld>().plugin.clone();
            wait_loaded(world, &id)
        },
    );
    steps.step(
        &format!("each surface shows {Q} in its sidebar footer"),
        |world, c, _| wait_shown(world, "sidebar.footer", &c[0], ""),
    );

    steps.step(
        &format!("the plugin {Q} contributes only to {Q}"),
        |world, c, _| {
            write_file(&plugin_path(world, &c[0]), &plugin_source(&c[0], &c[1], ""))?;
            world.part::<PluginWorld>().plugin = c[0].clone();
            Ok(())
        },
    );
    steps.step(
        "it is loaded on a surface without that slot",
        |world, _, _| {
            let id = world.part::<PluginWorld>().plugin.clone();
            wait_loaded(world, &id)
        },
    );
    steps.step(
        "the plugin is listed as loaded with no visible contributions",
        |world, _, _| {
            let id = world.part::<PluginWorld>().plugin.clone();
            let plugin = loaded(world, &id);
            expect!(
                plugin["slots"] == json!(["thread.hovercard"]) && count(&plugin["shown"]) == 0,
                "{}",
                describe(world)
            );
            for slot in ["sidebar.footer", "composer.actions", "statusbar"] {
                let none = shown_in(world, slot)?.is_empty()
                    && !slot_draws(world, slot, &format!("[{id}]"))?;
                expect!(none, "{slot} shows it");
            }
            // And the plugin list says so.
            let said = detail(world, &id)?;
            expect!(
                said.starts_with("Loaded, with nothing shown in this app"),
                "the list says \"{said}\""
            );
            Ok(())
        },
    );
    steps.step("no error is reported", |world, _, _| {
        world.sync()?;
        expect!(count(&plugins(world)["failed"]) == 0, "{}", describe(world));
        for toast in at(&world.state("toasts"), "items")
            .as_array()
            .into_iter()
            .flatten()
        {
            expect!(toast["type"] != json!("error"), "{}", show(toast));
        }
        Ok(())
    });

    // From a pasted address.
    steps.step(
        "the user pastes the URL of a plugin file and confirms loading it",
        |world, _, _| {
            let url = serve(world, "team-status");
            paste_url(world, &url)?;
            answer_question(world, true)
        },
    );
    steps.step("the plugin is downloaded, checked and loaded", |world, _, _| {
        let id = world.part::<PluginWorld>().plugin.clone();
        let wanted = id.clone();
        world.wait_for_with(
            |w| !loaded(w, &wanted).is_null(),
            |w| {
                format!(
                    "{wanted} to load; {}; the file is {}; the site was asked for {}; the toasts are {}",
                    describe(w),
                    if plugin_path(w, &wanted).exists() { "kept" } else { "missing" },
                    w.mc.peek::<FakePluginSite>()
                        .map_or(String::new(), |site| site.requests.join(", ")),
                    show(&w.state("toasts"))
                )
            },
        )?;
        let requests = world.mc.part::<FakePluginSite>().requests.clone();
        expect!(
            requests == vec![format!("/plugin-files/{id}.qml")],
            "{}",
            requests.join(", ")
        );
        let kept = std::fs::read_to_string(plugin_path(world, &id)).unwrap_or_default();
        expect!(
            kept == plugin_source(&id, "statusbar", ""),
            "{} is not the file served",
            plugin_path(world, &id).display()
        );
        wait_shown(world, "statusbar", &id, "")?;
        let title = format!("Plugin \"{id}\" loaded.");
        world.wait_for_with(
            |w| toasted(w, "success", &title),
            |w| show(&w.state("toasts")),
        )
    });
    steps.step(
        "the plugin is listed with that URL as its source",
        |world, _, _| {
            let (id, url) = {
                let kept = world.part::<PluginWorld>();
                (kept.plugin.clone(), kept.url.clone())
            };
            expect!(
                loaded(world, &id)["url"] == json!(url),
                "{}",
                describe(world)
            );
            let said = detail(world, &id)?;
            expect!(said.ends_with(&url), "the list says \"{said}\"");
            Ok(())
        },
    );
    steps.step(
        "the user pastes a plugin URL that cannot be reached",
        |world, _, _| {
            // Nothing listens there.
            paste_url(world, "http://127.0.0.1:9/gone.qml")?;
            answer_question(world, true)
        },
    );
    steps.step(
        "the user is told the plugin could not be downloaded",
        |world, _, _| {
            world.wait_for_with(
                |w| toasted(w, "error", "The plugin could not be downloaded"),
                |w| show(&w.state("toasts")),
            )
        },
    );
    steps.step("nothing is loaded", |world, _, _| {
        world.sync()?;
        expect!(
            count(&plugins(world)["items"]) == 0 && !plugin_path(world, "gone").exists(),
            "{}",
            describe(world)
        );
        let shown = shown_in(world, "statusbar")?;
        expect!(shown.is_empty(), "{}", shown.join(", "));
        Ok(())
    });
    steps.step(
        "the user installs a plugin from a pasted URL",
        |world, _, _| {
            shell(world)?;
            let url = serve(world, "team-status");
            world.part::<PluginWorld>().url = url.clone();
            world.dispatch("plugins.install", json!({"url": url}))
        },
    );
    steps.step(
        "the user is warned that the plugin is not signed",
        |world, _, _| {
            let asked = question(world);
            let description = text(&asked["description"]);
            expect!(
                description.contains("not signed") && description.contains("127.0.0.1"),
                "the shell asks {}",
                show(&asked)
            );
            Ok(())
        },
    );
    steps.step(
        "the plugin loads only after the user confirms",
        |world, _, _| {
            let id = world.part::<PluginWorld>().plugin.clone();
            world.sync()?;
            expect!(
                world.mc.part::<FakePluginSite>().requests.is_empty()
                    && loaded(world, &id).is_null()
                    && !plugin_path(world, &id).exists(),
                "the plugin was fetched before the answer; {}",
                describe(world)
            );
            answer_question(world, true)?;
            let wanted = id.clone();
            world.wait_for_with(
                |w| !loaded(w, &wanted).is_null(),
                |w| format!("{wanted} to load; {}", describe(w)),
            )?;
            wait_shown(world, "statusbar", &id, "")
        },
    );

    // Turning one off and on.
    steps.step(&format!("the plugin {Q} is loaded"), |world, c, _| {
        load_plugin(world, &c[0], "statusbar")?;
        wait_shown(world, "statusbar", &c[0], "")
    });
    steps.step(&format!("the user disables {Q}"), |world, c, _| {
        // The plugin list's own switch.
        toggle(world, &c[0])
    });
    steps.step("\"statusbar\" shows its built-in content", |world, _, _| {
        let brick = shell(world)?;
        let slot = item(world, "statusbarSlot")?;
        world.wait_for_with(
            |w| is_empty_slot(w, brick, "statusbar") && brick.flag(w, slot, "builtInVisible"),
            |w| format!("statusbar shows {}", slot_shows(w, brick, "statusbar")),
        )?;
        expect!(
            !slot_draws(world, "statusbar", "[clock]")?,
            "the clock is still drawn"
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} stays in the installed list as disabled"),
        |world, c, _| {
            let id = c[0].clone();
            let wanted = id.clone();
            world.wait_for_with(
                |w| !disabled(w, &wanted).is_null() && loaded(w, &wanted).is_null(),
                describe,
            )?;
            expect!(
                plugin_path(world, &id).exists(),
                "{} was deleted",
                plugin_path(world, &id).display()
            );
            let brick = shell(world)?;
            let page = show_plugin_list(world)?;
            let name = format!("plugin:{id}");
            world.wait_for_with(
                |w| {
                    let Ok(Some(row)) = brick.find_under(w, page, &name) else {
                        return false;
                    };
                    matches!(brick.find_under(w, row, "pluginDetail"), Ok(Some(d))
                        if brick.text_of(w, d, "text").starts_with("Disabled"))
                },
                describe,
            )
        },
    );
    steps.step(&format!("the plugin {Q} is disabled"), |world, c, _| {
        load_plugin(world, &c[0], "statusbar")?;
        wait_shown(world, "statusbar", &c[0], "")?;
        disable(world, &c[0])?;
        let brick = shell(world)?;
        world.wait_for_with(
            |w| is_empty_slot(w, brick, "statusbar"),
            |_| "the clock to leave the status bar".to_owned(),
        )
    });
    steps.step(&format!("the user enables {Q}"), |world, c, _| {
        toggle(world, &c[0])
    });
    steps.step("\"statusbar\" shows the clock again", |world, _, _| {
        wait_shown(world, "statusbar", "clock", "")?;
        expect!(
            count(&plugins(world)["disabled"]) == 0,
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(&format!("the user disabled {Q}"), |world, c, _| {
        load_plugin(world, &c[0], "statusbar")?;
        disable(world, &c[0])
    });
    steps.step("the client restarts", |world, _, _| {
        forget_window(world);
        world.restart()?;
        shell(world)?;
        world.sync()
    });
    steps.step(&format!("{Q} is still disabled"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(|w| !disabled(w, &wanted).is_null(), describe)?;
        world.sync()?;
        let shown = shown_in(world, "statusbar")?;
        expect!(
            loaded(world, &c[0]).is_null()
                && shown.is_empty()
                && !slot_draws(world, "statusbar", &format!("[{}]", c[0]))?,
            "{}",
            describe(world)
        );
        Ok(())
    });

    // A plugin file saved while the app runs.
    steps.step(
        &format!("the client runs in dev mode with the plugin {Q} loaded from a file"),
        |world, c, _| {
            load_plugin(world, &c[0], "statusbar")?;
            wait_shown(world, "statusbar", &c[0], "")?;
            // Something of the shell's to keep: a thread open with words in its draft.
            let route = show(&world.state("route"));
            let kept = world.part::<PluginWorld>();
            kept.plugin = c[0].clone();
            kept.draft = route;
            Ok(())
        },
    );
    steps.step(
        "the developer saves a change to that file",
        |world, _, _| {
            let id = world.part::<PluginWorld>().plugin.clone();
            write_file(
                &plugin_path(world, &id),
                &plugin_source(&id, "statusbar", &format!("[{id} v2]")),
            )
        },
    );
    steps.step(
        &format!("{Q} is replaced by the new version"),
        |world, c, _| {
            wait_shown(world, "statusbar", &c[0], &format!("[{} v2]", c[0]))?;
            let shown = shown_in(world, "statusbar")?;
            expect!(
                !slot_draws(world, "statusbar", &format!("[{}]", c[0]))?
                    && shown == vec![c[0].clone()],
                "the old version is still drawn"
            );
            expect!(count(&plugins(world)["failed"]) == 0, "{}", describe(world));
            Ok(())
        },
    );
    steps.step("the rest of the shell keeps its state", |world, _, _| {
        let (window, draft) = {
            let kept = world.part::<PluginWorld>();
            (kept.window, kept.draft.clone())
        };
        let same = match (window, shell(world)?.root(world)) {
            (Some((_, kept)), Some(now)) => kept == now,
            _ => false,
        };
        expect!(
            same && show(&world.state("route")) == draft && world.active(),
            "the window shows {}",
            show(&world.state("route"))
        );
        Ok(())
    });
    steps.step(
        "the developer saves a version that fails to load",
        |world, _, _| {
            let id = world.part::<PluginWorld>().plugin.clone();
            write_file(
                &plugin_path(world, &id),
                &format!(
                    "import OpenTUI\nPlugin {{\n  pluginId: \"{id}\"\n  Contribution {{ slot: \"statusbar\"\n    Text {{ text: \n}}\n"
                ),
            )
        },
    );
    steps.step(&format!("a plugin error names {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(|w| !failed(w, &wanted).is_null(), describe)?;
        let message = text(&failed(world, &c[0])["message"]);
        expect!(
            message.contains("line ") && message.contains("the last working version keeps running"),
            "{message}"
        );
        Ok(())
    });
    steps.step(
        &format!("the previous version of {Q} keeps running"),
        |world, c, _| {
            world.sync()?;
            let shown = shown_in(world, "statusbar")?;
            expect!(
                !loaded(world, &c[0]).is_null()
                    && shown == vec![c[0].clone()]
                    && slot_draws(world, "statusbar", &format!("[{}]", c[0]))?,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // What went wrong, where the user looks.
    steps.step(&format!("the plugin {Q} failed to load"), |world, c, _| {
        write_file(
            &plugin_path(world, &c[0]),
            "import OpenTUI\nText { text: \"not a plugin\" }\n",
        )?;
        shell(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(|w| !failed(w, &wanted).is_null(), describe)
    });
    steps.step("the user opens the plugin list", |world, _, _| {
        show_plugin_list(world).map(|_| ())
    });
    steps.step(
        &format!("{Q} is shown with its error message"),
        |world, c, _| {
            let page = show_plugin_list(world)?;
            let brick = shell(world)?;
            let name = format!("pluginFailure:{}", c[0]);
            world.wait_for_with(
                |w| {
                    matches!(brick.find_under(w, page, &name), Ok(Some(f)) if brick.flag(w, f, "visible"))
                },
                describe,
            )?;
            let Some(failure) = brick.find_under(world, page, &name)? else {
                fail!("the plugin list has no {name}")
            };
            let said = brick.text_of(world, failure, "text");
            expect!(
                said == format!("{}: the file's root object is not a Plugin", c[0]),
                "the list says \"{said}\""
            );
            expect!(loaded(world, &c[0]).is_null(), "{}", describe(world));
            Ok(())
        },
    );
}

fn slot_shows(world: &World, brick: Brick, slot: &str) -> String {
    let Ok(object) = slot_object(slot) else {
        return String::new();
    };
    brick
        .find(world, object)
        .ok()
        .flatten()
        .map(|found| {
            show(&json::from_value(
                world.engine(),
                &brick.read(world, found, "shown"),
            ))
        })
        .unwrap_or_default()
}

fn is_empty_slot(world: &World, brick: Brick, slot: &str) -> bool {
    let shown = slot_shows(world, brick, slot);
    shown == "[]" || shown == "null"
}
