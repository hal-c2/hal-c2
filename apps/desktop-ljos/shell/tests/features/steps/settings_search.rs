//! Settings as the desktop draws them, navigation beside the page it opens
//! (qml/HalC2/Bricks/SettingsNav.qml, SettingsHost.qml): the search's
//! ranking and its slash key, a result opened twice, and restoring this
//! device's defaults (features/settings/search-and-navigation.feature).
//! desktop-qt's SettingsSearchSteps.cpp and SettingsShell.h.

use std::collections::HashMap;
use std::rc::Rc;

use hal_c2_shell::controller;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::Themes;
use hal_c2_shell::json::{self as shell_json, Json};
use ljos::item::KeyEvent;
use ljos::prelude::{ObjectId, Value};
use serde_json::json;

use super::settings::{document_of, fake_config};
use super::settings_scoped_rows::{announce_here, with_capabilities};
use crate::brick::{Brick, Shown};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const TIME_FORMAT: &str = "timestampFormat";
const THEME: &str = "grove";

/// The result the scenario opened last.
#[derive(Default)]
struct Opened {
    target: String,
    section: String,
}

fn settings(world: &World) -> Settings {
    Settings::of(world.engine())
}

fn theme_id(world: &World) -> String {
    controller::with::<Themes, _>(world.engine(), |t, _| t.theme_id()).unwrap_or_default()
}

/// Settings as the default layout draws them, the navigation (`nav`) beside
/// the page of the route's section (`host`), on screen as the world's
/// brick. A brick already on screen is used as it is.
pub fn settings_shell(world: &mut World, width: f64, height: f64) -> Outcome<Brick> {
    if world.part::<Shown>().0.is_none() {
        // As DefaultShell lays them out.
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n\
             import \"HalC2/Bricks/js/settingsPages.js\" as Pages\n\
             Item {\n\
               id: shell\n\
               property alias rows: nav.rows\n\
               readonly property var route: Shell.state.route\n\
               readonly property string settingsSection: route && route.kind === \"settings\" ? Pages.resolve(route.section) : \"\"\n\
               SettingsNav { id: nav; objectName: \"nav\"; width: 260; height: parent.height }\n\
               SettingsHost {\n\
                 objectName: \"host\"; x: 260; width: parent.width - 260; height: parent.height\n\
                 section: shell.settingsSection\n\
               }\n\
             }\n",
            width,
            height,
        )?;
        let mut brick = crate::brick::shown(world)?;
        brick.takes_keys = true;
        // A brick's root fills the window.
        if let Some(root) = brick.root(world) {
            brick.write(world, root, "width", Value::from(width))?;
            brick.write(world, root, "height", Value::from(height))?;
        }
        world.part::<Shown>().0 = Some(brick);
    }
    crate::brick::shown(world)
}

fn shell(world: &mut World) -> Outcome<Brick> {
    settings_shell(world, 900.0, 300.0)
}

pub fn rows(world: &mut World) -> Outcome<Vec<Json>> {
    let brick = shell(world)?;
    let root = brick
        .root(world)
        .ok_or_else(|| Failure("no shell".into()))?;
    Ok(
        match shell_json::from_value(world.engine(), &brick.read(world, root, "rows")) {
            Json::Array(list) => list,
            _ => Vec::new(),
        },
    )
}

pub fn is_result(row: &Json) -> bool {
    row["result"] == json!(true)
}

/// The nav's rows as they stand, for waits that hold only `&World`.
fn rows_now(world: &World) -> Vec<Json> {
    let Some(brick) = world.peek_part::<Shown>().and_then(|shown| shown.0) else {
        return Vec::new();
    };
    let Ok(Some(nav)) = brick.find(world, "nav") else {
        return Vec::new();
    };
    match shell_json::from_value(world.engine(), &brick.read(world, nav, "rows")) {
        Json::Array(list) => list,
        _ => Vec::new(),
    }
}

fn describe_now(world: &World) -> String {
    describe_list(&rows_now(world))
}

fn describe_list(list: &[Json]) -> String {
    let lines: Vec<String> = list
        .iter()
        .map(|row| {
            if is_result(row) {
                format!(
                    "{} ({})",
                    row["title"].as_str().unwrap_or_default(),
                    row["sectionLabel"].as_str().unwrap_or_default()
                )
            } else {
                row["label"].as_str().unwrap_or_default().to_owned()
            }
        })
        .collect();
    format!("settings list {}", lines.join(", "))
}

pub fn describe_rows(world: &mut World) -> String {
    describe_list(&rows(world).unwrap_or_default())
}

fn describe_choices(world: &World) -> String {
    format!(
        "the theme is \"{}\" and the time format {}; the device error is \"{}\"",
        theme_id(world),
        show(
            &settings(world)
                .setting(world.engine(), TIME_FORMAT)
                .unwrap_or(Json::Null)
        ),
        settings(world).device_error()
    )
}

fn change_theme_and_time_format(world: &mut World) -> Outcome {
    let chosen = controller::with::<Themes, _>(world.engine(), |t, engine| t.choose(engine, THEME))
        .unwrap_or(false);
    expect!(chosen, "{}", settings(world).device_error());
    settings(world).set(world.engine(), TIME_FORMAT, json!("24-hour"));
    world.pump()?;
    expect!(changed(world), "{}", describe_choices(world));
    Ok(())
}

fn changed(world: &World) -> bool {
    theme_id(world) == THEME
        && settings(world).setting(world.engine(), TIME_FORMAT) == Some(json!("24-hour"))
}

fn dialog_list(world: &mut World) -> Outcome<ObjectId> {
    shell(world)?.item(world, "restoreList")
}

/// Asks, as the navigation's button does, and waits for the question.
fn ask_to_restore(world: &mut World) -> Outcome {
    let brick = shell(world)?;
    brick.click(world, "restoreDefaults")?;
    world.wait_for("the question about restoring defaults", |world| {
        let (Ok(list), Ok(confirm)) = (
            brick.item(world, "restoreList"),
            brick.item(world, "confirm"),
        ) else {
            return false;
        };
        brick.flag(world, list, "visible") && brick.flag(world, confirm, "visible")
    })
}

fn answer_restore(world: &mut World, accepted: bool) -> Outcome {
    let brick = shell(world)?;
    brick.click(world, if accepted { "confirm" } else { "cancel" })?;
    world.wait_for("the question to close", |world| {
        !brick
            .shows(world, "Restore default settings?")
            .unwrap_or(true)
    })
}

/// Whether the page shows all of the row of a search result.
fn in_view(world: &World, target: &str) -> bool {
    let Some(brick) = world.peek_part::<Shown>().and_then(|shown| shown.0) else {
        return false;
    };
    let (Ok(Some(item)), Ok(Some(host))) = (brick.find(world, target), brick.find(world, "host"))
    else {
        return false;
    };
    let (Ok(at_item), Ok(at_host)) = (
        brick.at(world, item, 0.0, 0.0),
        brick.at(world, host, 0.0, 0.0),
    ) else {
        return false;
    };
    let top = at_item.1 - at_host.1;
    let number = |item, name| {
        brick
            .text_of(world, item, name)
            .parse::<f64>()
            .unwrap_or(f64::NAN)
    };
    brick.flag(world, item, "visible")
        && top >= 0.0
        && top + number(item, "height") <= number(host, "height")
}

/// Waits for the page to bring `target` into view.
fn wait_in_view(world: &mut World, target: &str) -> Outcome {
    world.wait_for_with(
        |world| in_view(world, target),
        |_| format!("the page to bring {target} into view"),
    )
}

/// Types `typed` into whatever has the keyboard, a key at a time.
pub fn type_text(world: &mut World, typed: &str) -> Outcome {
    for ch in typed.chars() {
        let upper = ch.to_ascii_uppercase();
        world.key(&KeyEvent::press(upper as i32).with_text(ch.to_string()))?;
        world.key(&KeyEvent::release(upper as i32))?;
    }
    Ok(())
}

fn open_result(world: &mut World, title: &str) -> Outcome {
    let brick = shell(world)?;
    let field = brick.item(world, "search")?;
    brick.write(
        world,
        field,
        "text",
        Value::from(title.to_lowercase().as_str()),
    )?;
    let list = rows(world)?;
    for (index, row) in list.iter().enumerate() {
        if !is_result(row) || row["title"] != title {
            continue;
        }
        brick.click(world, &format!("settingsRow{index}"))?;
        return world.sync();
    }
    fail!("no result is titled \"{title}\"; {}", describe_rows(world))
}

fn route_target(world: &World) -> String {
    at(&world.state("route"), "target")
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

const BROWSER_ACCESS: &str = "enableAgentBrowserAccess";
const SETTLES: &str = "threadAutoSettlement";

fn scope_of(world: &World) -> Json {
    world.state("settingsScope")
}

/// A project in the sidebar, added when this machine has none by that name.
fn add_project(world: &mut World, title: &str) -> Outcome {
    let sidebar = world.state("sidebar");
    let exists = sidebar["projects"]
        .as_array()
        .is_some_and(|projects| projects.iter().any(|p| p["displayName"] == title));
    if exists {
        return Ok(());
    }
    let row = json!({"id": title, "title": title,
        "workspaceRoot": format!("/work/{title}"), "scripts": []});
    world.mc.projects.insert(title.to_owned(), row.clone());
    world.mc.send_row_of(title, &row, "project");
    world.sync()
}

/// Settings for one project, as the scope's project picker chooses it.
fn pick_project(world: &mut World, title: &str) -> Outcome {
    add_project(world, title)?;
    let find = |w: &World| {
        scope_of(w)["projects"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["title"] == title))
            .map(|row| text(&row["key"]))
            .filter(|key| !key.is_empty())
    };
    world.wait_for_with(
        |w| find(w).is_some(),
        |w| format!("{title} to be offered; the scope is {}", show(&scope_of(w))),
    )?;
    let key = find(world).unwrap_or_default();
    world.dispatch("settingsScope.project", json!({"key": key}))?;
    world.wait_for_with(
        |w| scope_of(w)["kind"] == "project" && scope_of(w)["projectLabel"] == title,
        |w| format!("the project scope; it is {}", show(&scope_of(w))),
    )
}

/// This machine and another, by label: the environment each is, and the one
/// the settings are scoped to.
#[derive(Default)]
struct Environments {
    ids: HashMap<String, String>,
    scoped: String,
}

/// This machine labelled `here` and a linked machine `other`, each saying
/// whether its MC settles threads; both in the settings scope.
fn two_environments(
    world: &mut World,
    here: &str,
    here_settles: bool,
    other: &str,
    other_settles: bool,
) -> Outcome {
    let environment_id = world.mc.environment_id.clone();
    {
        let environments = world.part::<Environments>();
        environments.ids.insert(here.to_owned(), environment_id);
        environments.ids.insert(other.to_owned(), other.to_owned());
    }
    world.mc.label = here.to_owned();
    world.mc.announce_environment();
    announce_here(world, json!({SETTLES: here_settles}))?;
    fake_config(&mut world.mc).elsewhere.insert(
        other.to_owned(),
        with_capabilities(serde_json::Map::new(), json!({SETTLES: other_settles})),
    );
    document_of(&mut world.mc, other).settings = serde_json::Map::new();
    world.mc.join_named(other);
    let settles = |w: &World, label: &str, expected: bool| {
        scope_of(w)["environments"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|environment| environment["label"] == label)
            .is_some_and(|environment| {
                environment["online"].as_bool() == Some(true)
                    && environment["capabilities"]
                        .get(SETTLES)
                        .and_then(Json::as_bool)
                        == Some(expected)
            })
    };
    let (here, other) = (here.to_owned(), other.to_owned());
    world.wait_for_with(
        |w| {
            scope_of(w)["targets"]
                .as_array()
                .is_some_and(|t| t.len() == 2)
                && settles(w, &here, here_settles)
                && settles(w, &other, other_settles)
        },
        |w| {
            format!(
                "{here} and {other} in the scope; it is {}",
                show(&scope_of(w))
            )
        },
    )
}

fn scope_to(world: &mut World, label: &str) -> Outcome {
    let id = world
        .part::<Environments>()
        .ids
        .get(label)
        .cloned()
        .unwrap_or_default();
    world.dispatch("settingsScope.environment", json!({"id": id}))?;
    let label = label.to_owned();
    world.wait_for_with(
        |w| text(&scope_of(w)["environmentId"]) == id,
        move |w| format!("the scope on {label}; it is {}", show(&scope_of(w))),
    )
}

/// The page shows `text` where the opened setting would be.
fn expect_notice(world: &mut World, expected: &str) -> Outcome {
    let brick = shell(world)?;
    let expected = expected.to_owned();
    world.wait_for_with(
        |w| {
            brick
                .find(w, "settingsNotice")
                .ok()
                .flatten()
                .is_some_and(|notice| brick.flag(w, notice, "visible"))
                && brick.shows(w, &expected).unwrap_or(false)
        },
        |w| {
            format!(
                "the notice \"{expected}\"; the route is {}, the scope {}",
                show(&w.state("route")),
                show(&scope_of(w))
            )
        },
    )?;
    let target = route_target(world);
    let setting = brick.find(world, &target)?;
    expect!(
        setting.is_none_or(|item| !brick.flag(world, item, "visible")),
        "{target} shows beside the notice"
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    // Sections.
    steps.step(
        &format!("the user chooses the {Q} section"),
        |world, c, _| {
            // Tall enough to show every section.
            let brick = settings_shell(world, 900.0, 800.0)?;
            let list = rows(world)?;
            for (index, row) in list.iter().enumerate() {
                if row["label"] != c[0].as_str() {
                    continue;
                }
                brick.click(world, &format!("settingsRow{index}"))?;
                return world.sync();
            }
            fail!("no section is named \"{}\"; {}", c[0], describe_rows(world))
        },
    );
    steps.step("the Providers settings are shown", |world, _, _| {
        let brick = shell(world)?;
        world.wait_for_with(
            |world| {
                at(&world.state("route"), "section") == "/settings/providers"
                    && brick
                        .find(world, "host")
                        .ok()
                        .flatten()
                        .is_some_and(|host| {
                            brick.text_of(world, host, "brick") == "ProvidersSettings"
                        })
            },
            |world| {
                let host = brick.find(world, "host").ok().flatten();
                format!(
                    "the route is {}; the host shows section \"{}\", brick \"{}\"",
                    show(&world.state("route")),
                    host.map(|h| brick.text_of(world, h, "section"))
                        .unwrap_or_default(),
                    host.map(|h| brick.text_of(world, h, "brick"))
                        .unwrap_or_default()
                )
            },
        )
    });
    steps.step(
        &format!("{Q} is marked as the current section"),
        |world, c, _| {
            let brick = shell(world)?;
            let list = rows(world)?;
            let mut current = Vec::new();
            for (index, row) in list.iter().enumerate() {
                let item = brick.item(world, &format!("settingsRow{index}"))?;
                if brick.flag(world, item, "current") {
                    current.push(row["label"].as_str().unwrap_or_default().to_owned());
                }
            }
            expect!(
                current == [c[0].clone()],
                "the current section is {}",
                current.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "the \"General\" section has keyboard focus",
        |world, _, _| {
            let brick = shell(world)?;
            expect!(
                rows(world)?.first().map(|row| &row["label"]) == Some(&json!("General")),
                "{}",
                describe_rows(world)
            );
            let row = brick.item(world, "settingsRow0")?;
            let _ = world.engine().invoke_by_name(row, "forceActiveFocus", &[]);
            expect!(
                brick.flag(world, row, "activeFocus"),
                "General did not take the keyboard"
            );
            Ok(())
        },
    );
    steps.step("the user moves down and confirms", |world, _, _| {
        let brick = shell(world)?;
        brick.press(world, "down")?;
        let next = brick.item(world, "settingsRow1")?;
        expect!(
            brick.flag(world, next, "activeFocus"),
            "the next section did not take the keyboard"
        );
        brick.press(world, "enter")?;
        world.sync()
    });
    steps.step("the next section opens", |world, _, _| {
        let next = rows(world)?
            .get(1)
            .map(|row| row["to"].as_str().unwrap_or_default().to_owned())
            .unwrap_or_default();
        let route = world.state("route");
        expect!(
            !next.is_empty()
                && next != "/settings/general"
                && at(&route, "section") == next.as_str(),
            "the route is {}, the next section {next}",
            show(&route)
        );
        Ok(())
    });

    // Searching.
    steps.step(
        &format!("the user has searched settings for {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            brick.click(world, "search")?;
            type_text(world, &c[0])?;
            world.wait_for_with(
                |world| {
                    brick
                        .find(world, "nav")
                        .ok()
                        .flatten()
                        .map(|nav| {
                            let list = shell_json::from_value(
                                world.engine(),
                                &brick.read(world, nav, "rows"),
                            );
                            list.as_array()
                                .and_then(|rows| rows.first())
                                .is_some_and(is_result)
                        })
                        .unwrap_or(false)
                },
                |_| "the search results".to_owned(),
            )
        },
    );
    steps.step("the user opens the first result", |world, _, _| {
        let first = rows(world)?.first().cloned().unwrap_or(Json::Null);
        *world.part::<Opened>() = Opened {
            target: first["targetId"].as_str().unwrap_or_default().to_owned(),
            section: first["to"].as_str().unwrap_or_default().to_owned(),
        };
        shell(world)?.click(world, "settingsRow0")?;
        world.sync()
    });
    steps.step("the section holding that setting opens", |world, _, _| {
        let route = world.state("route");
        let opened = world.part::<Opened>();
        let (target, section) = (opened.target.clone(), opened.section.clone());
        expect!(
            !target.is_empty()
                && at(&route, "section") == section.as_str()
                && at(&route, "target") == target.as_str(),
            "the route is {}; the result was {target} in {section}",
            show(&route)
        );
        Ok(())
    });
    steps.step("the user is told no settings match", |world, _, _| {
        let brick = shell(world)?;
        let none = brick.item(world, "noMatches")?;
        expect!(
            rows(world)?.is_empty()
                && brick.flag(world, none, "visible")
                && brick.shows(world, "No matching settings")?,
            "{}",
            describe_rows(world)
        );
        Ok(())
    });
    steps.step("the user presses escape in the search", |world, _, _| {
        let brick = shell(world)?;
        let field = brick.item(world, "search")?;
        expect!(
            brick.flag(world, field, "activeFocus"),
            "the search does not have the keyboard"
        );
        brick.press(world, "escape")?;
        Ok(())
    });
    steps.step("the search is empty", |world, _, _| {
        let brick = shell(world)?;
        let field = brick.item(world, "search")?;
        let text = brick.text_of(world, field, "text");
        expect!(text.is_empty(), "the search holds \"{text}\"");
        Ok(())
    });
    steps.step("the list of sections is shown again", |world, _, _| {
        let list = rows(world)?;
        expect!(
            list.first()
                .is_some_and(|row| !is_result(row) && row["label"] == "General"),
            "{}",
            describe_rows(world)
        );
        Ok(())
    });

    // The slash key.
    steps.step("the keyboard is not in a text field", |world, _, _| {
        let brick = shell(world)?;
        let row = brick.item(world, "settingsRow0")?;
        let _ = world.engine().invoke_by_name(row, "forceActiveFocus", &[]);
        let search = brick.item(world, "search")?;
        expect!(
            brick.flag(world, row, "activeFocus") && !brick.flag(world, search, "activeFocus"),
            "the first section did not take the keyboard"
        );
        Ok(())
    });
    steps.step("the settings search has keyboard focus", |world, _, _| {
        let brick = shell(world)?;
        let field = brick.item(world, "search")?;
        expect!(
            brick.flag(world, field, "activeFocus"),
            "the search does not have the keyboard"
        );
        // The key started the search; it was not typed into it.
        let text = brick.text_of(world, field, "text");
        expect!(text.is_empty(), "the search holds \"{text}\"");
        Ok(())
    });

    // Ranking.
    steps.step(&format!("the first result is {Q}"), |world, c, _| {
        let title = c[0].clone();
        let brick = shell(world)?;
        world.wait_for_with(
            |world| {
                brick
                    .find(world, "nav")
                    .ok()
                    .flatten()
                    .map(|nav| {
                        let list =
                            shell_json::from_value(world.engine(), &brick.read(world, nav, "rows"));
                        list.as_array()
                            .and_then(|rows| rows.first())
                            .is_some_and(|row| is_result(row) && row["title"] == title.as_str())
                    })
                    .unwrap_or(false)
            },
            |_| format!("the first result to be \"{title}\""),
        )?;
        expect!(brick.shows(world, &c[0])?, "{}", describe_rows(world));
        Ok(())
    });

    // A result opened twice.
    steps.step(
        &format!("the user opened the search result {Q} and scrolled away"),
        |world, c, _| {
            // A window short enough that the setting can be scrolled out of it.
            let brick = settings_shell(world, 900.0, 190.0)?;
            open_result(world, &c[0])?;
            let target = route_target(world);
            expect!(
                !target.is_empty(),
                "the route is {}",
                show(&world.state("route"))
            );
            world.part::<Opened>().target = target.clone();
            wait_in_view(world, &target)?;
            let scroll = brick.item(world, "scroll")?;
            let content_y = brick
                .text_of(world, scroll, "contentY")
                .parse::<f64>()
                .unwrap_or(0.0);
            let content_height = brick
                .text_of(world, scroll, "contentHeight")
                .parse::<f64>()
                .unwrap_or(0.0);
            let height = brick
                .text_of(world, scroll, "height")
                .parse::<f64>()
                .unwrap_or(0.0);
            let end = content_height - height;
            expect!(end > 0.0, "the page does not scroll");
            // Whichever end the setting is not at.
            let away = if content_y > end / 2.0 { 0.0 } else { end };
            brick.write(world, scroll, "contentY", Value::from(away))?;
            expect!(!in_view(world, &target), "{target} is still in view");
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens the search result {Q}(?: again)?"),
        |world, c, _| {
            if let Some(step) = world.on_settings_page.get("openResult").cloned() {
                return step(world, c);
            }
            open_result(world, &c[0])?;
            world.part::<Opened>().target = route_target(world);
            Ok(())
        },
    );
    steps.step("the page brings the setting into view", |world, c, _| {
        if let Some(step) = world.on_settings_page.get("inView").cloned() {
            return step(world, c);
        }
        let target = world.part::<Opened>().target.clone();
        expect!(
            !target.is_empty(),
            "no result was opened; the route is {}",
            show(&world.state("route"))
        );
        wait_in_view(world, &target)
    });
    steps.step(
        "the page brings the setting into view again",
        |world, _, _| {
            let target = world.part::<Opened>().target.clone();
            wait_in_view(world, &target)
        },
    );

    // Restoring defaults.
    steps.step(
        "the user has changed the theme and the time format",
        |world, _, _| change_theme_and_time_format(world),
    );
    steps.step("the user restores default settings", |world, _, _| {
        ask_to_restore(world)
    });
    steps.step(
        "the user is asked to confirm a reset of the theme and the time format",
        |world, _, _| {
            let list = dialog_list(world)?;
            let text = shell(world)?.text_of(world, list, "text");
            expect!(
                text == "This will reset: Theme, Time format.",
                "the question reads \"{text}\""
            );
            // Nothing changes before the user answers.
            expect!(changed(world), "{}", describe_choices(world));
            Ok(())
        },
    );
    steps.step(
        "the user is asked to confirm restoring default settings",
        |world, _, _| {
            change_theme_and_time_format(world)?;
            ask_to_restore(world)?;
            world.answer_question = Some(Rc::new(answer_restore));
            Ok(())
        },
    );
    steps.step(
        "the theme and the time format are back to their defaults",
        |world, _, _| {
            // The time format is the MC's: back once its write is answered.
            world.sync_until_with(
                |w| {
                    let settings = settings(w);
                    let engine = w.engine();
                    theme_id(w).is_empty()
                        && settings.is_default(engine, TIME_FORMAT)
                        && settings.setting(engine, TIME_FORMAT) == settings.default_of(TIME_FORMAT)
                },
                describe_choices,
            )?;
            let brick = shell(world)?;
            let button = brick.item(world, "restoreDefaults")?;
            expect!(
                !brick.flag(world, button, "enabled"),
                "something is still offered to restore"
            );
            Ok(())
        },
    );
    steps.step("every setting keeps its value", |world, _, _| {
        expect!(changed(world), "{}", describe_choices(world));
        Ok(())
    });
    steps.step("saving the theme on this device fails", |world, _, _| {
        change_theme_and_time_format(world)?;
        // A folder where the preferences file is: what the shell holds
        // stays, and nothing more can be saved.
        let Some(path) = settings(world).device_path() else {
            fail!("this device keeps no preferences file");
        };
        let blocked = std::fs::remove_file(&path).is_ok() && std::fs::create_dir_all(&path).is_ok();
        expect!(blocked, "cannot block {}", path.display());
        expect!(changed(world), "{}", describe_choices(world));
        Ok(())
    });
    steps.step(
        "the user confirms restoring default settings",
        |world, _, _| {
            ask_to_restore(world)?;
            answer_restore(world, true)
        },
    );
    steps.step(
        "the theme settings keep their previous values",
        |world, _, _| {
            expect!(changed(world), "{}", describe_choices(world));
            Ok(())
        },
    );
    steps.step(
        "the user is told the theme settings could not be restored",
        |world, _, _| {
            let toasts = world.state("toasts");
            let told = toasts["items"].as_array().is_some_and(|items| {
                items
                    .iter()
                    .any(|toast| toast["title"] == "Couldn’t restore theme settings")
            });
            expect!(told, "the shell shows {}", show(&toasts["items"]));
            Ok(())
        },
    );

    // Focus.
    steps.step(
        "the user has focus in the settings search",
        |world, _, _| {
            let brick = shell(world)?;
            brick.click(world, "search")?;
            let field = brick.item(world, "search")?;
            expect!(
                brick.flag(world, field, "activeFocus"),
                "the search did not take the keyboard"
            );
            Ok(())
        },
    );
    steps.step(
        "the list of sections has focus, on the current section",
        |world, _, _| {
            let brick = shell(world)?;
            let list = brick.item(world, "sections")?;
            let nav = brick.item(world, "nav")?;
            let current = brick.text_of(world, nav, "currentSection");
            let index: usize = brick
                .text_of(world, list, "currentIndex")
                .parse()
                .unwrap_or(usize::MAX);
            let list_rows = rows(world)?;
            let row = list_rows.get(index);
            expect!(
                brick.flag(world, list, "activeFocus")
                    && row.is_some_and(|row| row["to"] == current.as_str()),
                "the sections {} the keyboard, at {}; the section showing is {current}",
                if brick.flag(world, list, "activeFocus") {
                    "have"
                } else {
                    "do not have"
                },
                show(row.unwrap_or(&Json::Null))
            );
            Ok(())
        },
    );
    steps.step(
        "the user presses escape on the settings page",
        |world, _, _| {
            let brick = shell(world)?;
            let host = brick.item(world, "host")?;
            let _ = world.engine().invoke_by_name(host, "forceActiveFocus", &[]);
            brick.press(world, "escape")?;
            world.sync()
        },
    );

    // The project section.
    steps.step(
        "the user is editing (?:settings for )?all projects",
        |world, _, _| {
            shell(world)?;
            world.dispatch("settingsScope.project", json!({"key": ""}))?;
            world.wait_for_with(
                |w| scope_of(w)["kind"] != "project",
                |w| format!("all projects; the scope is {}", show(&scope_of(w))),
            )
        },
    );
    steps.step("there is no project section", |world, _, _| {
        let list = rows(world)?;
        expect!(
            list.iter().all(|row| row["label"] != "Project"),
            "{}",
            describe_rows(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user chooses the project {Q}"),
        |world, c, _| pick_project(world, &c[0]),
    );
    steps.step("the project section is listed first", |world, _, _| {
        world.wait_for_with(
            |w| {
                rows_now(w)
                    .first()
                    .is_some_and(|row| row["label"] == "Project")
            },
            describe_now,
        )
    });

    // What the search finds.
    steps.step(
        "no connected environment has provider settings",
        |world, _, _| {
            shell(world)?;
            world.mc.stop_accepting();
            world.mc.drop_connection();
            world.wait_for("the shell to see the drop", |w| !w.client_ready())
        },
    );
    steps.step(&format!("{Q} is the only result"), |world, c, _| {
        let title = c[0].clone();
        world.wait_for_with(
            |w| {
                let list = rows_now(w);
                list.len() == 1 && list[0]["title"] == title.as_str()
            },
            describe_now,
        )
    });
    steps.step(
        &format!("the user searches settings for {Q} with an accent on the e"),
        |world, c, _| {
            // Typed as the keyboard composes it, which key clicks cannot.
            let brick = shell(world)?;
            let field = brick.item(world, "search")?;
            brick.write(world, field, "text", Value::from(c[0].as_str()))?;
            world.sync()
        },
    );
    steps.step(&format!("{Q} is the first result"), |world, c, _| {
        let title = c[0].clone();
        world.wait_for_with(
            |w| {
                rows_now(w)
                    .first()
                    .is_some_and(|row| row["title"] == title.as_str())
            },
            describe_now,
        )
    });
    steps.step(
        "the results are the unpin, archive and delete confirmations in that order",
        |world, _, _| {
            let titles: Vec<String> = rows(world)?.iter().map(|row| text(&row["title"])).collect();
            expect!(
                titles.iter().take(3).cloned().collect::<Vec<_>>()
                    == [
                        "Unpin confirmation",
                        "Archive confirmation",
                        "Delete confirmation"
                    ],
                "{}",
                describe_rows(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the first result is the {Q} keybinding"),
        |world, c, _| {
            let list = rows(world)?;
            let first = list.first().cloned().unwrap_or(Json::Null);
            expect!(
                first["title"] == c[0].as_str()
                    && first["sectionLabel"] == "Keybindings"
                    && text(&first["targetId"]).starts_with("keybinding:"),
                "{}",
                describe_rows(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the model picker keybinding is listed after {Q}"),
        |world, c, _| {
            let list = rows(world)?;
            let mut setting = None;
            let mut command = None;
            for (index, row) in list.iter().enumerate() {
                if row["title"] == c[0].as_str() {
                    setting = Some(index);
                }
                if row["sectionLabel"] == "Keybindings"
                    && text(&row["title"]).to_lowercase().contains("model picker")
                {
                    command = Some(index);
                }
            }
            expect!(
                matches!((setting, command), (Some(s), Some(k)) if k > s),
                "{}",
                describe_rows(world)
            );
            Ok(())
        },
    );

    // Where a result opens.
    steps.step(
        &format!("the user opens the search result for the {Q} command"),
        |world, c, _| {
            let brick = settings_shell(world, 900.0, 600.0)?;
            let field = brick.item(world, "search")?;
            brick.write(world, field, "text", Value::from(c[0].as_str()))?;
            world.sync()?;
            let list = rows(world)?;
            for (index, row) in list.iter().enumerate() {
                if row["targetId"] != format!("keybinding:{}", c[0]).as_str() {
                    continue;
                }
                world.part::<Opened>().target = text(&row["title"]);
                brick.click(world, &format!("settingsRow{index}"))?;
                return world.sync();
            }
            fail!(
                "no result is the {} command; {}",
                c[0],
                describe_rows(world)
            )
        },
    );
    steps.step(
        "the Keybindings section opens at that command's row",
        |world, _, _| {
            let brick = shell(world)?;
            let label = world.part::<Opened>().target.clone();
            world.wait_for_with(
                |w| {
                    if at(&w.state("route"), "section") != "/settings/keybindings" {
                        return false;
                    }
                    let draft = brick.find(w, "keybindingDraft").ok().flatten();
                    let command = brick.find(w, "command").ok().flatten();
                    draft.is_some_and(|d| brick.flag(w, d, "visible"))
                        && command
                            .is_some_and(|cmd| brick.text_of(w, cmd, "displayText") == label)
                },
                |w| {
                    let command = brick.find(w, "command").ok().flatten();
                    format!(
                        "a new keybinding for \"{label}\"; the route is {}, the command shows \"{}\"",
                        show(&w.state("route")),
                        command
                            .map(|cmd| brick.text_of(w, cmd, "displayText"))
                            .unwrap_or_else(|| "(none)".into())
                    )
                },
            )
        },
    );
    steps.step("window capture is off", |world, _, _| {
        settings_shell(world, 900.0, 300.0)?;
        world.dispatch("settings.navigate", json!({"to": "/settings/snap-shot"}))?;
        world.sync()?;
        let brick = shell(world)?;
        let toggle = brick
            .find(world, "snapShot:enabled")?
            .ok_or_else(|| Failure("the SnapShots page has no capture toggle".into()))?;
        let control = brick.find_in(world, toggle, "control")?;
        expect!(
            control.is_some_and(|item| !brick.flag(world, item, "checked")),
            "window capture is on"
        );
        Ok(())
    });
    steps.step(
        "the window capture toggle is brought into view",
        |world, _, _| {
            world.wait_for_with(
                |w| in_view(w, "snapShot:enabled"),
                |_| "the capture toggle to come into view".to_owned(),
            )
        },
    );

    // Settings some environments, or another scope, hold.
    steps.step(
        &format!("{Q} can settle threads and {Q} cannot"),
        |world, c, _| {
            settings_shell(world, 900.0, 600.0)?;
            two_environments(world, &c[0].clone(), true, &c[1].clone(), false)
        },
    );
    steps.step(
        &format!("the settings are scoped to {Q}, which cannot settle threads"),
        |world, c, _| {
            settings_shell(world, 900.0, 600.0)?;
            world.part::<Environments>().scoped = c[0].clone();
            Ok(())
        },
    );
    steps.step(&format!("{Q} can settle threads"), |world, c, _| {
        let scoped = world.part::<Environments>().scoped.clone();
        two_environments(world, &c[0].clone(), true, &scoped.clone(), false)?;
        scope_to(world, &scoped)
    });
    steps.step("no environment can settle threads", |world, _, _| {
        let scoped = world.part::<Environments>().scoped.clone();
        two_environments(world, "laptop", false, &scoped.clone(), false)?;
        scope_to(world, &scoped)
    });
    steps.step(&format!("{Q} and {Q} can settle threads"), |world, c, _| {
        settings_shell(world, 900.0, 600.0)?;
        two_environments(world, &c[0].clone(), true, &c[1].clone(), true)
    });
    steps.step(
        &format!("the user scopes the settings to {Q}"),
        |world, c, _| scope_to(world, &c[0]),
    );
    steps.step(&format!("{Q} goes offline"), |world, c, _| {
        let id = world
            .part::<Environments>()
            .ids
            .get(&c[0])
            .cloned()
            .unwrap_or_default();
        world.mc.set_online(&id, false);
        let label = c[0].clone();
        world.wait_for_with(
            |w| {
                scope_of(w)["environments"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|environment| environment["id"] == id.as_str())
                    .is_some_and(|environment| environment["online"].as_bool() == Some(false))
            },
            move |w| format!("{label} offline; the scope is {}", show(&scope_of(w))),
        )
    });
    steps.step("the results are found", |world, _, _| {
        let titles: Vec<String> = rows(world)?.iter().map(|row| text(&row["title"])).collect();
        expect!(
            titles.iter().any(|t| t == "Auto-settle merged threads")
                && titles.iter().any(|t| t == "Auto-settle inactive threads"),
            "{}",
            describe_rows(world)
        );
        Ok(())
    });
    steps.step(
        &format!("choosing one offers {Q} and not {Q}"),
        |world, c, _| {
            let brick = shell(world)?;
            let list = rows(world)?;
            for (index, row) in list.iter().enumerate() {
                if row["title"] != "Auto-settle merged threads" {
                    continue;
                }
                brick.click(world, &format!("settingsRow{index}"))?;
                world.sync()?;
                break;
            }
            let (offered, withheld) = {
                let environments = world.part::<Environments>();
                (
                    format!(
                        "choose:{}",
                        environments.ids.get(&c[0]).cloned().unwrap_or_default()
                    ),
                    format!(
                        "choose:{}",
                        environments.ids.get(&c[1]).cloned().unwrap_or_default()
                    ),
                )
            };
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| {
                    brick
                        .find(w, &offered)
                        .ok()
                        .flatten()
                        .is_some_and(|button| {
                            brick.flag(w, button, "visible")
                                && brick.text_of(w, button, "text") == wanted
                        })
                        && brick.find(w, &withheld).ok().flatten().is_none()
                },
                |w| {
                    format!(
                        "{offered} offered and not {withheld}; the notice is {}",
                        brick
                            .find(w, "settingsNotice")
                            .ok()
                            .flatten()
                            .is_some_and(|notice| brick.flag(w, notice, "visible"))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the page says {Q} in place of the settings"),
        |world, c, _| expect_notice(world, &c[0]),
    );
    steps.step(
        &format!("the settings are scoped to the project {Q}"),
        |world, c, _| {
            settings_shell(world, 900.0, 600.0)?;
            world.dispatch("settingsScope.environment", json!({"id": ""}))?;
            pick_project(world, &c[0])
        },
    );
    steps.step(
        "the user opens the search result of a setting that is set per environment",
        |world, _, _| {
            // Automatic Git fetch interval is one setting for all of an
            // environment's projects.
            world.dispatch(
                "settings.openResult",
                json!({"to": "/settings/source-control", "targetId": "fetchInterval"}),
            )?;
            world.sync()
        },
    );
    steps.step(
        "the page says that setting is not available for the selected target and to choose its owning scope",
        |world, _, _| {
            expect_notice(
                world,
                "Automatic Git fetch interval is not available for the selected target. \
                 Choose its owning scope to continue.",
            )
        },
    );
    steps.step(
        "the user can choose the scope there to carry on to the setting",
        |world, _, _| {
            let brick = shell(world)?;
            brick.click(world, "choose:allProjects")?;
            world.wait_for_with(
                |w| {
                    let route = w.state("route");
                    scope_of(w)["kind"] != "project"
                        && brick
                            .find(w, "settingsNotice")
                            .ok()
                            .flatten()
                            .is_none_or(|notice| !brick.flag(w, notice, "visible"))
                        && at(&route, "section") == "/settings/source-control"
                        && at(&route, "target") == "fetchInterval"
                },
                |w| {
                    format!(
                        "the setting in its own scope; the scope is {}, the route {}",
                        show(&scope_of(w)),
                        show(&w.state("route"))
                    )
                },
            )?;
            world.wait_for_with(
                |w| in_view(w, "fetchInterval"),
                |_| "the setting to come into view".to_owned(),
            )
        },
    );
    steps.step("no environment is the primary one", |world, _, _| {
        // Every environment, none of them first.
        shell(world)?;
        two_environments(world, "laptop", false, "server", false)?;
        world.dispatch("settingsScope.environment", json!({"id": ""}))?;
        world.wait_for_with(|w| scope_of(w)["kind"] == "all", |w| show(&scope_of(w)))
    });

    // Restoring, when there is nothing to restore, and the MC's settings.
    steps.step(
        "every setting the restore covers is at its default",
        |world, _, _| {
            let brick = shell(world)?;
            let nav = brick.item(world, "nav")?;
            let changed =
                shell_json::from_value(world.engine(), &brick.read(world, nav, "changedLabels"));
            let labels: Vec<String> = changed.as_array().into_iter().flatten().map(text).collect();
            expect!(labels.is_empty(), "{} changed", labels.join(", "));
            Ok(())
        },
    );
    steps.step("the user looks at the settings page", |world, _, _| {
        shell(world)?;
        world.sync()
    });
    steps.step(
        "restoring default settings cannot be chosen",
        |world, _, _| {
            let brick = shell(world)?;
            let button = brick.item(world, "restoreDefaults")?;
            expect!(
                !brick.flag(world, button, "enabled"),
                "restoring defaults is offered"
            );
            Ok(())
        },
    );
    steps.step("the user turned agent browser access off", |world, _, _| {
        shell(world)?;
        world.wait_for_with(
            |w| {
                let controller = settings(w);
                controller.ready()
                    && controller
                        .disabled_reason(w.engine(), BROWSER_ACCESS)
                        .is_empty()
            },
            |w| {
                format!(
                    "the setting to be editable: {}",
                    settings(w).disabled_reason(w.engine(), BROWSER_ACCESS)
                )
            },
        )?;
        settings(world).set(world.engine(), BROWSER_ACCESS, json!(false));
        world.wait_for_with(
            |w| {
                w.mc.peek::<super::settings::FakeConfig>()
                    .is_some_and(|fake| fake.settings.get(BROWSER_ACCESS) == Some(&json!(false)))
                    && settings(w).setting(w.engine(), BROWSER_ACCESS) == Some(json!(false))
            },
            |w| {
                format!(
                    "the MC holds {}",
                    show(&Json::Object(
                        w.mc.peek::<super::settings::FakeConfig>()
                            .map(|fake| fake.settings.clone())
                            .unwrap_or_default()
                    ))
                )
            },
        )
    });
    steps.step(
        "the confirmation lists agent browser access among the settings it will reset",
        |world, _, _| {
            let list = dialog_list(world)?;
            let text = shell(world)?.text_of(world, list, "text");
            expect!(
                text.contains("Agent browser access"),
                "the question reads \"{text}\""
            );
            world.answer_question = Some(Rc::new(answer_restore));
            Ok(())
        },
    );
    steps.step("agents have browser access again", |world, _, _| {
        world.wait_for_with(
            |w| {
                let held =
                    w.mc.peek::<super::settings::FakeConfig>()
                        .and_then(|fake| fake.settings.get(BROWSER_ACCESS).cloned());
                (held.is_none() || held == Some(json!(true)))
                    && settings(w).setting(w.engine(), BROWSER_ACCESS) == Some(json!(true))
            },
            |w| {
                format!(
                    "the MC holds {}",
                    show(&Json::Object(
                        w.mc.peek::<super::settings::FakeConfig>()
                            .map(|fake| fake.settings.clone())
                            .unwrap_or_default()
                    ))
                )
            },
        )
    });
}
