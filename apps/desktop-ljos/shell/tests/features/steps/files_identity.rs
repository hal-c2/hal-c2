//! Project and environment identity (desktop-qt's FilesIdentitySteps.cpp;
//! features/files/project-identity.feature): the icons the shell publishes,
//! the pickers as the window draws them (ProjectIconPicker.qml in Settings →
//! Projects, EnvironmentIconPicker.qml), and an environment theme. The MC's
//! side: `assets.createUrl` for a project's favicon and `/api/auth/session`
//! for what this session may do.

use std::io::{Read, Write};
use std::net::Shutdown;

use fancy_regex::Regex;
use hal_c2_shell::controllers::theme::Themes;
use ljos::prelude::Value;
use serde_json::{Value as Json, json};

use super::fake_files::{fake_files, sign_file};
use super::settings::{fake_config, publish_themes};
use crate::brick::{self, Brick};
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

struct FakeIdentity {
    /// What this session may do, as `/api/auth/session` lists it.
    scopes: Vec<String>,
    /// The project the scenario's pickers are for.
    project: String,
}

impl Default for FakeIdentity {
    fn default() -> FakeIdentity {
        FakeIdentity {
            scopes: vec!["orchestration:read".into(), "orchestration:operate".into()],
            project: String::new(),
        }
    }
}

fn icon_of(world: &World, project: &str) -> Json {
    let key = format!("{}:{project}", world.mc.environment_id);
    world.state("projectIcons")[key.as_str()].clone()
}

fn saved_icon(world: &World, project: &str) -> Json {
    world
        .mc
        .projects
        .get(project)
        .map_or(Json::Null, |row| row["projectIcon"].clone())
}

fn is_empty(value: &Json) -> bool {
    match value {
        Json::Null => true,
        Json::Object(map) => map.is_empty(),
        Json::Array(list) => list.is_empty(),
        Json::String(s) => s.is_empty(),
        _ => false,
    }
}

fn picker(world: &World) -> Json {
    world.state("projectIconPicker")
}

fn machine(world: &World, environment: &str) -> Json {
    world.state("environmentIcons")[environment].clone()
}

fn project_of(world: &mut World) -> String {
    world.mc.part::<FakeIdentity>().project.clone()
}

/// What a ProjectIcon draws of the project's icon: "monogram SH", "emoji 🛒",
/// "symbol rocket" or "image <url>".
fn drawn(world: &mut World, project: &str) -> Outcome<String> {
    let qml = format!(
        "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nProjectIcon {{ size: 32; icon: Shell.state.projectIcons?.[\"{}:{project}\"] ?? null }}\n",
        world.mc.environment_id
    );
    let brick = Brick::new(world, &qml, 32.0, 32.0)?;
    let part = |world: &World, name: &str| -> Outcome<_> {
        match brick.find(world, name)? {
            Some(item) => Ok(item),
            None => fail!("the icon has no {name}"),
        }
    };
    let monogram = part(world, "projectIconMonogram")?;
    if brick.flag(world, monogram, "visible") {
        // The letters are the Text inside the monogram's tile.
        let letters = icon_of(world, project);
        let letters = text(&letters["text"]);
        return Ok(
            if brick
                .find_holding(world, "projectIconMonogram", &letters)?
                .is_some()
            {
                format!("monogram {letters}")
            } else {
                "monogram ".to_owned()
            },
        );
    }
    let emoji = part(world, "projectIconEmoji")?;
    if brick.flag(world, emoji, "visible") {
        return Ok(format!("emoji {}", brick.text_of(world, emoji, "text")));
    }
    let symbol = part(world, "projectIconSymbol")?;
    if brick.flag(world, symbol, "visible") {
        return Ok(format!("symbol {}", brick.text_of(world, symbol, "name")));
    }
    let image = part(world, "projectIconImage")?;
    Ok(format!("image {}", brick.text_of(world, image, "source")))
}

/// Settings → Projects on `project`, with the picker the window keeps over it.
fn manage(world: &mut World, project: &str) -> Outcome {
    world.mc.part::<FakeIdentity>().project = project.to_owned();
    world.dispatch("settings.open", json!({}))?;
    world.dispatch("settings.navigate", json!({"to": "/settings/projects"}))?;
    let wanted = project.to_owned();
    let key_of = move |w: &World| -> Option<String> {
        w.state("settingsScope")["projects"]
            .as_array()?
            .iter()
            .find(|row| text(&row["title"]) == wanted)
            .map(|row| text(&row["key"]))
    };
    let finder = key_of.clone();
    world.wait_for_with(
        move |w| finder(w).is_some_and(|key| !key.is_empty()),
        |w| {
            format!(
                "{project} to be offered; the scope is {}",
                show(&w.state("settingsScope"))
            )
        },
    )?;
    let key = key_of(world).unwrap_or_default();
    world.dispatch("settingsScope.project", json!({"key": key}))?;
    let wanted = project.to_owned();
    world.wait_for_with(
        move |w| {
            let panel = w.state("projectSettings");
            text(&panel["status"]) == "ready" && text(&panel["name"]) == wanted
        },
        |w| {
            format!(
                "{project} to be managed; the panel is {}",
                show(&w.state("projectSettings"))
            )
        },
    )?;
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nItem {\n  ProjectSettings { anchors.fill: parent }\n  ProjectIconPicker {}\n}\n",
        900.0,
        800.0,
    )
}

fn open_picker(world: &mut World, project: &str) -> Outcome {
    manage(world, project)?;
    brick::shown(world)?.click(world, "choose")?;
    world.sync()?;
    // The page is a clipped Flickable, which Ljós does not click into yet
    // (issue-clip-anchored-hit-test.md); the button's own dispatch stands in
    // until it does.
    if is_empty(&picker(world)) {
        let key = world.state("projectSettings")["checkouts"][0]["key"].clone();
        world.dispatch(
            "projectIcon.open",
            json!({"projectKey": key, "name": project}),
        )?;
    }
    world.wait_for("the icon picker to open", |w| !is_empty(&picker(w)))?;
    let brick = brick::shown(world)?;
    world.wait_for("the icon picker to show", move |w| {
        brick
            .find(w, "projectIconPicker")
            .ok()
            .flatten()
            .is_some_and(|item| brick.flag(w, item, "opened"))
    })
}

pub fn type_into(world: &mut World, field: &str, typed: &str) -> Outcome {
    let brick = brick::shown(world)?;
    brick.click(world, field)?;
    let item = brick.item(world, field)?;
    expect!(
        brick.flag(world, item, "activeFocus"),
        "{field} did not take the keyboard"
    );
    let _ = world.engine().invoke_by_name(item, "selectAll", &[]);
    for letter in typed.chars() {
        let spelt = match letter {
            ' ' => "space".to_owned(),
            c if c.is_uppercase() => format!("shift+{}", c.to_lowercase()),
            c => c.to_string(),
        };
        brick.press(world, &spelt)?;
    }
    Ok(())
}

fn wait_for_icon(
    world: &mut World,
    project: &str,
    matches: impl Fn(&Json) -> bool + 'static,
) -> Outcome {
    let name = project.to_owned();
    let seen = name.clone();
    world.wait_for_with(
        move |w| matches(&icon_of(w, &seen)),
        move |w| {
            format!(
                "the icon of {name}; it is {} (the MC keeps {})",
                show(&icon_of(w, &name)),
                show(&saved_icon(w, &name))
            )
        },
    )
}

/// An icon as the outline words it.
enum Wanted {
    Symbol(String, String),
    Emoji(String),
    Monogram(String, String),
    Image(String),
}

fn parse_icon(what: &str) -> Outcome<Wanted> {
    let patterns = [
        r#"^the "([^"]+)" symbol in (\w+)$"#,
        r#"^the emoji "([^"]+)"$"#,
        r#"^the monogram "([^"]+)" in (\w+)$"#,
        r#"^the image file "([^"]+)"$"#,
    ];
    for (index, pattern) in patterns.iter().enumerate() {
        let Ok(Some(found)) = Regex::new(pattern).map(|r| r.captures(what).ok().flatten()) else {
            continue;
        };
        let first = found[1].to_owned();
        let second = found.get(2).map(|m| m.as_str().to_owned());
        return Ok(match index {
            0 => Wanted::Symbol(first, second.unwrap_or_default()),
            1 => Wanted::Emoji(first),
            2 => Wanted::Monogram(first, second.unwrap_or_default()),
            _ => Wanted::Image(first),
        });
    }
    fail!("these steps do not know the icon \"{what}\"")
}

/// "the monogram "SH" in rose" and its kin, as the outline words them.
fn pick(world: &mut World, project: &str, what: &str) -> Outcome {
    let icon = parse_icon(what)?;
    open_picker(world, project)?;
    let brick = brick::shown(world)?;
    match icon {
        Wanted::Symbol(name, color) => {
            brick.click(world, "projectIconMode-lucide")?;
            brick.click(world, &format!("projectIconColor-{color}"))?;
            brick.click(world, &format!("projectIconSymbol-{name}"))?;
            brick.click(world, "projectIconSave")?;
        }
        Wanted::Emoji(emoji) => {
            brick.click(world, "projectIconMode-emoji")?;
            // An emoji comes from the system's picker, not from keys.
            world.dispatch("projectIcon.set", json!({"emoji": emoji}))?;
            brick.click(world, "projectIconSave")?;
        }
        Wanted::Monogram(letters, color) => {
            brick.click(world, "projectIconMode-monogram")?;
            brick.click(world, &format!("projectIconColor-{color}"))?;
            type_into(world, "projectIconLetters", &letters)?;
            brick.click(world, "projectIconSave")?;
        }
        Wanted::Image(path) => {
            fake_files(&mut world.mc)
                .files
                .insert(path.clone(), "PNG".into());
            brick.click(world, "projectIconMode-image")?;
            let stem = path.rsplit('/').next().unwrap_or_default();
            let stem = stem.split('.').next().unwrap_or_default();
            type_into(world, "projectIconSearch", stem)?;
            let wanted = path.clone();
            world.wait_for_with(
                {
                    let wanted = wanted.clone();
                    move |w| offers(&picker(w), &wanted)
                },
                |w| format!("{wanted} to be offered; the picker is {}", show(&picker(w))),
            )?;
            brick.click(world, &format!("projectIconImage-{path}"))?;
        }
    }
    world.sync()
}

fn offers(picker: &Json, path: &str) -> bool {
    picker["images"]
        .as_array()
        .is_some_and(|images| images.iter().any(|image| text(image) == path))
}

fn expect_shown(world: &mut World, project: &str, what: &str) -> Outcome {
    let wanted = match parse_icon(what)? {
        Wanted::Symbol(name, color) => {
            wait_for_icon(world, project, {
                let name = name.clone();
                move |icon| {
                    text(&icon["kind"]) == "lucide"
                        && text(&icon["name"]) == name
                        && text(&icon["color"]) == color
                }
            })?;
            format!("symbol {name}")
        }
        Wanted::Emoji(emoji) => {
            wait_for_icon(world, project, {
                let emoji = emoji.clone();
                move |icon| text(&icon["kind"]) == "emoji" && text(&icon["emoji"]) == emoji
            })?;
            format!("emoji {emoji}")
        }
        Wanted::Monogram(letters, color) => {
            wait_for_icon(world, project, {
                let letters = letters.clone();
                move |icon| {
                    text(&icon["kind"]) == "monogram"
                        && text(&icon["text"]) == letters
                        && text(&icon["color"]) == color
                        && icon["automatic"] != json!(true)
                }
            })?;
            format!("monogram {letters}")
        }
        Wanted::Image(path) => {
            wait_for_icon(world, project, {
                let path = path.clone();
                move |icon| text(&icon["kind"]) == "image" && text(&icon["path"]) == path
            })?;
            let row = world
                .mc
                .projects
                .get(project)
                .cloned()
                .unwrap_or(Json::Null);
            expect!(
                text(&row["faviconPath"]) == path && is_empty(&saved_icon(world, project)),
                "the MC keeps {}",
                show(&row)
            );
            let name = path.rsplit('/').next().unwrap_or_default();
            format!("image {}/api/assets/token/v1-{name}", world.mc.origin())
        }
    };
    // Every list draws a project through the one brick.
    let shown = drawn(world, project)?;
    expect!(shown == wanted, "{project} is drawn as \"{shown}\"");
    // The settings page's own word for it follows.
    world.wait_for_with(
        |w| w.state("projectSettings")["icon"]["custom"] == json!(true),
        |w| {
            format!(
                "settings to show it; they show {}",
                show(&w.state("projectSettings")["icon"])
            )
        },
    )
}

/// The MC's `environment` descriptor of its own config, announced as it changes.
fn describe_environment(world: &mut World, machine_kind: &str, keeps_icon: bool) -> Outcome {
    let environment = world.mc.environment_id.clone();
    let mut descriptor = json!({
        "environmentId": environment,
        "capabilities": if keeps_icon { json!({"environmentIcon": true}) } else { json!({}) },
    });
    if !machine_kind.is_empty() {
        descriptor["platform"] = json!({"machine": machine_kind});
    }
    let fake = fake_config(&mut world.mc);
    fake.config.insert("environment".into(), descriptor);
    let mut config = fake.config.clone();
    config.insert("settings".into(), Json::Object(fake.settings.clone()));
    // The frame as the MC sends a whole config: its subscribers hear it.
    for id in world.mc.subscribers("config") {
        if text(&world.mc.shape_of(id)["environment"]) != environment {
            continue;
        }
        world
            .mc
            .send(&json!({"t": "config", "id": id, "config": config}));
    }
    world.sync()
}

/// Picks `kind` in the environment's picker, as Settings → Connections shows it.
fn mark(world: &mut World, environment: &str, kind: &str) -> Outcome {
    let name = environment.to_owned();
    world.wait_for_with(
        {
            let name = name.clone();
            move |w| {
                let icon = machine(w, &name);
                text(&icon["lock"]).is_empty() && !is_empty(&icon)
            }
        },
        |w| {
            format!(
                "the icon of {name} to be changeable; it is {}",
                show(&machine(w, &name))
            )
        },
    )?;
    Brick::show(
        world,
        &format!(
            "import QtQuick\nimport HalC2.Bricks\nEnvironmentIconPicker {{ environmentId: \"{environment}\" }}\n"
        ),
        520.0,
        60.0,
    )?;
    let brick = brick::shown(world)?;
    let combo = brick.item(world, "environmentIconKind")?;
    let icon = machine(world, environment);
    let index = icon["kinds"]
        .as_array()
        .and_then(|kinds| kinds.iter().position(|row| text(&row["kind"]) == kind));
    let enabled = brick.flag(world, combo, "enabled");
    let Some(index) = index.filter(|_| enabled) else {
        fail!("{kind} cannot be picked; the picker is {}", show(&icon));
    };
    let _ = world
        .engine()
        .emit_by_name(combo, "activated", &[Value::Int(index as i32)]);
    world.sync()
}

fn settings_writes(world: &mut World) -> usize {
    fake_config(&mut world.mc).writes.len()
}

/// The user's own environment going away: false when it is another's.
pub fn disconnect_own_environment(world: &mut World, environment: &str) -> Outcome<bool> {
    if environment != world.mc.environment_id {
        return Ok(false);
    }
    world.mc.stop_accepting();
    world.mc.drop_connection();
    world.wait_for("the shell to see the drop", |w| !w.client_ready())?;
    Ok(true)
}

/// Whether the icon picker is open to answer whether it offers `path`.
pub fn check_icon_image_offered(world: &mut World, path: &str, offered: bool) -> Outcome<bool> {
    if is_empty(&picker(world)) {
        return Ok(false);
    }
    let images = picker(world);
    let listed: Vec<String> = images["images"]
        .as_array()
        .map(|images| images.iter().map(text).collect())
        .unwrap_or_default();
    expect!(
        listed.iter().any(|image| image == path) == offered,
        "the picker offers {}",
        listed.join(", ")
    );
    // As the picker lists them.
    if offered {
        let brick = brick::shown(world)?;
        let item = brick.item(world, &format!("projectIconImage-{path}"))?;
        expect!(brick.flag(world, item, "visible"), "{path} is not listed");
    }
    Ok(true)
}

fn serve_session(mc: &mut FakeMc, mut stream: std::net::TcpStream, head: &str) {
    let mut request = vec![0u8; head.len()];
    let _ = stream.read(&mut request);
    let body =
        json!({"authenticated": true, "scopes": mc.part::<FakeIdentity>().scopes}).to_string();
    let _ = write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Both);
}

/// The colour the shell draws as the canvas, as a brick reads the theme.
fn canvas(world: &mut World) -> Outcome<Value> {
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nRectangle { objectName: \"canvas\"; color: Theme.palette.color(\"canvas\", \"#000000\") }\n",
        10.0,
        10.0,
    )?;
    let item = brick.item(world, "canvas")?;
    Ok(brick.read(world, item, "color"))
}

pub fn register(steps: &mut Steps) {
    steps.extension(|mc| {
        // A favicon the project has or the user picked, else the MC's "none"
        // (apps/server-ex attachments.ex).
        mc.on_rpc("assets.createUrl", |mc, rpc| {
            let resource = &rpc.payload["resource"];
            if text(&resource["_tag"]) != "project-favicon" {
                // A workspace's file is FakeFiles'; an attachment timeline's.
                if !sign_file(mc, rpc) {
                    mc.pass_on(rpc)?;
                }
                return Ok(());
            }
            let path = text(&resource["path"]);
            let served = !path.is_empty() && fake_files(mc).files.contains_key(&path);
            let token = if served {
                format!("v1-{}", path.rsplit('/').next().unwrap_or_default())
            } else {
                "project-favicon-missing".to_owned()
            };
            mc.reply(
                rpc,
                json!({"relativeUrl": format!("/api/assets/token/{token}"), "expiresAt": 1790000000000.0}),
            );
            Ok(())
        });
        mc.on_raw("/api/auth/session", |mc, stream, head| {
            serve_session(mc, stream, head);
            Ok(())
        });
    });

    // Monograms.
    steps.step(&format!("the project {Q} has no icon"), |world, c, _| {
        let id = c[0].to_owned();
        let row = json!({
            "id": id, "title": id, "workspaceRoot": format!("/work/{id}"),
            "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z",
            "scripts": [],
        });
        world.mc.projects.insert(id.clone(), row.clone());
        world.mc.send_row_of(&id, &row, "project");
        world.sync()
    });
    steps.step("the user looks at the project list", |world, _, _| {
        // The rows have arrived, and the MC has said none of them has a favicon.
        world.sync()?;
        world.sync()
    });
    steps.step(
        &format!("{Q} shows the monogram {Q} in a colour derived from its name"),
        |world, c, _| {
            // The colour each of these names derives.
            let colour = match c[0].as_str() {
                "Nebula" => "red",
                "Silver Orchard" => "sky",
                "M7 Forge" => "emerald",
                other => fail!("these steps do not know the colour of {other}"),
            };
            let letters = c[1].to_owned();
            wait_for_icon(world, &c[0], {
                let letters = letters.clone();
                move |icon| {
                    text(&icon["kind"]) == "monogram"
                        && text(&icon["text"]) == letters
                        && text(&icon["color"]) == colour
                        && icon["automatic"] == json!(true)
                }
            })?;
            let shown = drawn(world, &c[0])?;
            expect!(
                shown == format!("monogram {letters}"),
                "{} is drawn as \"{shown}\"",
                &c[0]
            );
            Ok(())
        },
    );

    // The picker.
    steps.step(
        &format!("the user sets? the icon of {Q} to (.+)"),
        |world, c, _| pick(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("{Q} shows (.+) everywhere it is listed"),
        |world, c, _| expect_shown(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("the user resets the icon of {Q}"),
        |world, _, _| {
            let brick = brick::shown(world)?;
            world.wait_for("settings to offer the automatic icon", move |w| {
                brick
                    .find(w, "automatic")
                    .ok()
                    .flatten()
                    .is_some_and(|item| brick.flag(w, item, "visible"))
            })?;
            brick.click(world, "automatic")?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user types {Q} as the monogram of {Q}"),
        |world, c, _| {
            open_picker(world, &c[1])?;
            brick::shown(world)?.click(world, "projectIconMode-monogram")?;
            type_into(world, "projectIconLetters", &c[0])?;
            brick::shown(world)?.click(world, "projectIconSave")?;
            world.sync()
        },
    );
    steps.step(&format!("the monogram is saved as {Q}"), |world, c, _| {
        let project = project_of(world);
        let letters = c[0].to_owned();
        wait_for_icon(world, &project, {
            let letters = letters.clone();
            move |icon| text(&icon["kind"]) == "monogram" && text(&icon["text"]) == letters
        })?;
        let saved = saved_icon(world, &project);
        expect!(
            text(&saved["monogramText"]) == letters && is_empty(&picker(world)),
            "the MC keeps {}",
            show(&saved)
        );
        Ok(())
    });
    steps.step("the monogram cannot be saved", |world, _, _| {
        let project = project_of(world);
        let message = "Use one or two letters or numbers.";
        let shown = brick::shown(world)?.shows(world, message)?;
        expect!(
            text(&picker(world)["error"]) == message
                && shown
                && is_empty(&saved_icon(world, &project))
                && icon_of(world, &project)["automatic"] == json!(true),
            "the picker is {} and the MC keeps {}",
            show(&picker(world)),
            show(&saved_icon(world, &project))
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} runs an older server that only knows symbol icons"),
        |world, c, _| {
            // Such a server reads `kind`, `name` and `color` and carries the
            // rest along.
            expect!(
                world.mc.environment_id == c[0],
                "the environment is {}",
                world.mc.environment_id
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user sets the monogram {Q} on {Q}"),
        |world, c, _| pick(world, &c[1], &format!("the monogram \"{}\" in rose", &c[0])),
    );
    steps.step(
        &format!("{Q} keeps a folder symbol with the letters {Q}"),
        |world, c, _| {
            let project = project_of(world);
            let name = project.clone();
            world.wait_for("the icon to be saved", move |w| {
                !is_empty(&saved_icon(w, &name))
            })?;
            let wanted = json!({
                "kind": "lucide", "name": "folder-code", "color": "rose",
                "monogramText": &c[1],
            });
            let saved = saved_icon(world, &project);
            expect!(saved == wanted, "{} keeps {}", &c[0], show(&saved));
            // And this desktop draws the letters.
            let letters = c[1].to_owned();
            wait_for_icon(world, &project, move |icon| text(&icon["text"]) == letters)
        },
    );
    steps.step(
        &format!("the user searches the project for an icon image named {Q}"),
        |world, c, _| {
            let files = &mut fake_files(&mut world.mc).files;
            files.insert(format!("assets/{}.png", &c[0]), "PNG".into());
            files.insert(format!("src/{}.ts", &c[0]), "export {};\n".into());
            open_picker(world, "shop")?;
            brick::shown(world)?.click(world, "projectIconMode-image")?;
            type_into(world, "projectIconSearch", &c[0])?;
            let query = c[0].to_owned();
            world.wait_for_with(
                move |w| {
                    let picker = picker(w);
                    text(&picker["query"]) == query && picker["searching"] != json!(true)
                },
                |w| format!("the search to finish; the picker is {}", show(&picker(w))),
            )
        },
    );

    // Environment icons.
    steps.step(
        &format!("{Q} is detected as a (laptop|server|desktop)"),
        |world, c, _| {
            describe_environment(world, &c[1], true)?;
            let (environment, kind) = (c[0].to_owned(), c[1].to_owned());
            world.wait_for_with(
                {
                    let (environment, kind) = (environment.clone(), kind.clone());
                    move |w| {
                        let icon = machine(w, &environment);
                        text(&icon["detected"]) == kind && text(&icon["kind"]) == kind
                    }
                },
                |w| {
                    format!(
                        "{environment} to be a {kind}; it is {}",
                        show(&machine(w, &environment))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user marks {Q} as a (laptop|server|desktop)(?:, its detected kind)?"),
        |world, c, _| mark(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("the user marked {Q} as a (server|desktop)"),
        |world, c, _| {
            describe_environment(world, "laptop", true)?;
            mark(world, &c[0], &c[1])?;
            let (environment, kind) = (c[0].to_owned(), c[1].to_owned());
            world.wait_for_with(
                {
                    let (environment, kind) = (environment.clone(), kind.clone());
                    move |w| text(&machine(w, &environment)["kind"]) == kind
                },
                |w| show(&machine(w, &environment)),
            )
        },
    );
    steps.step(
        &format!("{Q} shows a (server|laptop|desktop) icon"),
        |world, c, _| {
            let (environment, kind) = (c[0].to_owned(), c[1].to_owned());
            world.wait_for_with(
                {
                    let (environment, kind) = (environment.clone(), kind.clone());
                    move |w| text(&machine(w, &environment)["kind"]) == kind
                },
                |w| {
                    format!(
                        "{environment} to show a {kind}; it is {}",
                        show(&machine(w, &environment))
                    )
                },
            )?;
            let icon = machine(world, &environment);
            let settings = Json::Object(fake_config(&mut world.mc).settings.clone());
            expect!(
                text(&settings["environmentIcon"]) == kind && icon["chosen"] == json!(true),
                "the MC keeps {}",
                show(&settings)
            );
            // As the picker draws it.
            let brick = brick::shown(world)?;
            let drawn = brick.item(world, "environmentIcon")?;
            let name = brick.text_of(world, drawn, "name");
            expect!(name == text(&icon["icon"]), "the picker draws {name}");
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} follows its detected kind again"),
        |world, c, _| {
            let environment = c[0].to_owned();
            world.wait_for_with(
                {
                    let environment = environment.clone();
                    move |w| machine(w, &environment)["chosen"] != json!(true)
                },
                |w| {
                    format!(
                        "the choice to go; {environment} is {}",
                        show(&machine(w, &environment))
                    )
                },
            )?;
            let icon = machine(world, &environment);
            let settings = Json::Object(fake_config(&mut world.mc).settings.clone());
            expect!(
                text(&icon["kind"]) == text(&icon["detected"])
                    && settings.get("environmentIcon").is_none(),
                "the MC keeps {}",
                show(&settings)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} runs a server too old to keep one"),
        |world, _, _| describe_environment(world, "laptop", false),
    );
    steps.step(
        "the user's session cannot change settings",
        |world, _, _| {
            describe_environment(world, "laptop", true)?;
            world.mc.part::<FakeIdentity>().scopes = vec!["orchestration:read".into()];
            Ok(())
        },
    );
    steps.step(
        &format!("the user tries to change the icon of {Q}"),
        |world, c, _| {
            let writes = settings_writes(world);
            world.dispatch(
                "environmentIcon.set",
                json!({"environmentId": &c[0], "kind": "server"}),
            )?;
            // Told as a toast, which "the user is told" reads; nothing is saved.
            world.wait_for("the user to be told", |w| {
                !is_empty(&at(&w.state("toasts"), "items").clone())
            })?;
            expect!(
                settings_writes(world) == writes,
                "the settings were written"
            );
            Ok(())
        },
    );

    // An environment's theme.
    steps.step(&format!("{Q} offers the theme {Q}"), |world, c, _| {
        let theme = json!({
            "id": &c[1], "name": &c[1], "appearance": "dark",
            "canvas": "#1b1626", "accent": "#ff8800",
        });
        publish_themes(&mut world.mc, &c[0], vec![theme.clone()]);
        let wanted = theme.clone();
        world.wait_for("the shell to hear of the theme", move |w| {
            hal_c2_shell::controllers::settings::Settings::of(w.engine()).themes()
                == [wanted.clone()]
        })?;
        let id = c[1].to_owned();
        let offered = world.with::<Themes, _>(|themes, _| themes.available())?;
        expect!(
            offered.iter().any(|theme| text(&theme["id"]) == id),
            "the themes offered are {}",
            show(&Json::Array(offered.clone()))
        );
        Ok(())
    });
    steps.step(&format!("the user picks the theme {Q}"), |world, c, _| {
        // A dark theme, seen in the dark.
        hal_c2_shell::platform_window::set_color_scheme(world.engine(), true, true);
        world.pump()?;
        let id = c[0].to_owned();
        let chosen = world.with::<Themes, _>(|themes, engine| themes.choose(engine, &id))?;
        expect!(chosen, "{id} cannot be chosen");
        world.pump()
    });
    steps.step(
        &format!("the app uses the colours of {Q}"),
        |world, c, _| {
            let id = c[0].to_owned();
            let canvas_wanted = hal_c2_shell::theme::parse_css_color("#1b1626");
            // Resolved first, then drawn.
            let wanted = id.clone();
            world.wait_for_with(
                move |w| {
                    w.with::<Themes, _>(|themes, _| themes.resolved_id())
                        .is_ok_and(|resolved| resolved == wanted)
                },
                |w| {
                    let resolved = w
                        .with::<Themes, _>(|themes, _| themes.resolved_id())
                        .unwrap_or_default();
                    format!("{id}; the shell resolved {resolved}")
                },
            )?;
            world.sync()?;
            let drawn = canvas(world)?;
            expect!(
                matches!((&drawn, canvas_wanted), (Value::Color(got), Some(want)) if *got == want),
                "the shell draws {drawn:?} for the canvas of {id}"
            );
            Ok(())
        },
    );
}
