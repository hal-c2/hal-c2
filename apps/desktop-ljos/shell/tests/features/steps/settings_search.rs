//! Settings as the desktop draws them, navigation beside the page it opens
//! (qml/HalC2/Bricks/SettingsNav.qml, SettingsHost.qml): the search's
//! ranking and its slash key, a result opened twice, and restoring this
//! device's defaults (features/settings/search-and-navigation.feature).
//! desktop-qt's SettingsSearchSteps.cpp and SettingsShell.h.

use std::rc::Rc;

use hal_c2_shell::controller;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::Themes;
use hal_c2_shell::json::{self as shell_json, Json};
use ljos::item::KeyEvent;
use ljos::prelude::{ObjectId, Value};
use serde_json::json;

use crate::brick::{Brick, Shown};
use crate::harness::{Failure, Outcome, Q, Steps, at, show};
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
            &format!("import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n\
             import \"HalC2/Bricks/js/settingsPages.js\" as Pages\n\
             Item {{\n\
               id: shell\n\
               property alias rows: nav.rows\n\
               readonly property var route: Shell.state.route\n\
               readonly property string settingsSection: route && route.kind === \"settings\" ? Pages.resolve(route.section) : \"\"\n\
               SettingsNav {{ id: nav; objectName: \"nav\"; width: 260; height: parent.height }}\n\
               SettingsHost {{\n\
                 objectName: \"host\"; x: 260; width: parent.width - 260; height: parent.height\n\
                 section: shell.settingsSection\n\
               }}\n\
             }}\n"),
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

fn rows(world: &mut World) -> Outcome<Vec<Json>> {
    let brick = shell(world)?;
    let root = brick.root(world).ok_or_else(|| Failure("no shell".into()))?;
    Ok(
        match shell_json::from_value(world.engine(), &brick.read(world, root, "rows")) {
            Json::Array(list) => list,
            _ => Vec::new(),
        },
    )
}

fn is_result(row: &Json) -> bool {
    row["result"] == json!(true)
}

fn describe_rows(world: &mut World) -> String {
    let lines: Vec<String> = rows(world)
        .unwrap_or_default()
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

fn describe_choices(world: &World) -> String {
    format!(
        "the theme is \"{}\" and the time format {}; the device error is \"{}\"",
        theme_id(world),
        show(&settings(world).setting(world.engine(), TIME_FORMAT).unwrap_or(Json::Null)),
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
        let (Ok(list), Ok(confirm)) = (brick.item(world, "restoreList"), brick.item(world, "confirm"))
        else {
            return false;
        };
        brick.flag(world, list, "visible") && brick.flag(world, confirm, "visible")
    })
}

fn answer_restore(world: &mut World, accepted: bool) -> Outcome {
    let brick = shell(world)?;
    brick.click(world, if accepted { "confirm" } else { "cancel" })?;
    world.wait_for("the question to close", |world| {
        !brick.shows(world, "Restore default settings?").unwrap_or(true)
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
    let number = |item, name| brick.text_of(world, item, name).parse::<f64>().unwrap_or(f64::NAN);
    brick.flag(world, item, "visible") && top >= 0.0 && top + number(item, "height") <= number(host, "height")
}

/// Waits for the page to bring `target` into view.
fn wait_in_view(world: &mut World, target: &str) -> Outcome {
    world.wait_for_with(
        |world| in_view(world, target),
        |_| format!("the page to bring {target} into view"),
    )
}

/// Types `typed` into whatever has the keyboard, a key at a time.
fn type_text(world: &mut World, typed: &str) -> Outcome {
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
    brick.write(world, field, "text", Value::from(title.to_lowercase().as_str()))?;
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

pub fn register(steps: &mut Steps) {
    // Sections.
    steps.step(&format!("the user chooses the {Q} section"), |world, c, _| {
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
    });
    steps.step("the Providers settings are shown", |world, _, _| {
        let brick = shell(world)?;
        world.wait_for_with(
            |world| {
                at(&world.state("route"), "section") == "/settings/providers"
                    && brick
                        .find(world, "host")
                        .ok()
                        .flatten()
                        .is_some_and(|host| brick.text_of(world, host, "brick") == "ProvidersSettings")
            },
            |world| {
                let host = brick.find(world, "host").ok().flatten();
                format!(
                    "the route is {}; the host shows section \"{}\", brick \"{}\"",
                    show(&world.state("route")),
                    host.map(|h| brick.text_of(world, h, "section")).unwrap_or_default(),
                    host.map(|h| brick.text_of(world, h, "brick")).unwrap_or_default()
                )
            },
        )
    });
    steps.step(&format!("{Q} is marked as the current section"), |world, c, _| {
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
    });
    steps.step("the \"General\" section has keyboard focus", |world, _, _| {
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
    });
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
            !next.is_empty() && next != "/settings/general" && at(&route, "section") == next.as_str(),
            "the route is {}, the next section {next}",
            show(&route)
        );
        Ok(())
    });

    // Searching.
    steps.step(&format!("the user has searched settings for {Q}"), |world, c, _| {
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
                        let list = shell_json::from_value(world.engine(), &brick.read(world, nav, "rows"));
                        list.as_array()
                            .and_then(|rows| rows.first())
                            .is_some_and(is_result)
                    })
                    .unwrap_or(false)
            },
            |_| "the search results".to_owned(),
        )
    });
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
                        let list = shell_json::from_value(world.engine(), &brick.read(world, nav, "rows"));
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
            let content_y = brick.text_of(world, scroll, "contentY").parse::<f64>().unwrap_or(0.0);
            let content_height = brick.text_of(world, scroll, "contentHeight").parse::<f64>().unwrap_or(0.0);
            let height = brick.text_of(world, scroll, "height").parse::<f64>().unwrap_or(0.0);
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
    steps.step("the page brings the setting into view again", |world, _, _| {
        let target = world.part::<Opened>().target.clone();
        wait_in_view(world, &target)
    });

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
            world.answer_question = Some(Rc::new(|world, accepted| answer_restore(world, accepted)));
            Ok(())
        },
    );
    steps.step(
        "the theme and the time format are back to their defaults",
        |world, _, _| {
            let settings = settings(world);
            let engine = world.engine();
            expect!(
                theme_id(world).is_empty()
                    && settings.is_default(engine, TIME_FORMAT)
                    && settings.setting(engine, TIME_FORMAT) == settings.default_of(TIME_FORMAT),
                "{}",
                describe_choices(world)
            );
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
    steps.step("the user confirms restoring default settings", |world, _, _| {
        ask_to_restore(world)?;
        answer_restore(world, true)
    });
    steps.step("the theme settings keep their previous values", |world, _, _| {
        expect!(changed(world), "{}", describe_choices(world));
        Ok(())
    });
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
}
