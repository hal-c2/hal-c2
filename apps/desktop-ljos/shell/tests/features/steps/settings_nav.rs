//! The settings navigation as the desktop draws it (qml/HalC2/Bricks/
//! SettingsNav.qml; desktop-qt's SettingsNavSteps.cpp): its search, its
//! results from the keyboard, and a query set from elsewhere
//! (features/navigation/focus.feature). And the settings the command palette
//! finds, from the same table (js/settingsPages.js), with the keybinding
//! commands after them (navigation/command-palette.feature).

use ljos::item::{KeyEvent, key};
use ljos::prelude::Value;
use serde_json::json;

use super::add_project::{
    describe, id_at, invoke, invoke_ok, is_open, kind_at, role_text, set_query,
};
use super::settings_search::{describe_rows, is_result, rows, settings_shell, type_text};
use crate::brick::Brick;
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::world::World;
use crate::{expect, fail};

/// The result `the settings search lists` found.
#[derive(Default)]
struct NavState {
    result: usize,
}

fn nav(world: &mut World) -> Outcome<Brick> {
    settings_shell(world, 900.0, 900.0)
}

fn search_text(world: &mut World) -> Outcome<String> {
    let brick = nav(world)?;
    let field = brick.item(world, "search")?;
    Ok(brick.text_of(world, field, "text"))
}

fn describe_search(world: &mut World) -> String {
    format!(
        "the search is \"{}\", {}",
        search_text(world).unwrap_or_default(),
        describe_rows(world)
    )
}

/// Types into the search field, as the user does.
fn search(world: &mut World, query: &str) -> Outcome {
    let brick = nav(world)?;
    brick.click(world, "search")?;
    let field = brick.item(world, "search")?;
    expect!(
        brick.flag(world, field, "activeFocus"),
        "the settings search did not take the keyboard"
    );
    type_text(world, query)?;
    expect!(search_text(world)? == query, "{}", describe_search(world));
    Ok(())
}

fn result_titled(world: &mut World, title: &str) -> Outcome<usize> {
    let list = rows(world)?;
    match list
        .iter()
        .position(|row| is_result(row) && row["title"] == title)
    {
        Some(index) => Ok(index),
        None => fail!(
            "no result is titled \"{title}\"; {}",
            describe_search(world)
        ),
    }
}

/// The palette gets its settings from the brick's own table, as
/// CommandPalette.qml hands it.
fn hand_palette_its_settings(world: &mut World) -> Outcome {
    Brick::new(
        world,
        "import QtQuick\nimport HalC2.Shell\n\
         import \"HalC2/Bricks/js/settingsPages.js\" as Pages\n\
         Item { Component.onCompleted: PaletteModel.setSettingsSections(Pages.paletteEntries(Qt.platform.os)) }\n",
        10.0,
        10.0,
    )?;
    world.pump()
}

fn palette_row(world: &World, matches: impl Fn(&str, &str, &str) -> bool) -> Option<usize> {
    (0..super::add_project::count(world)).find(|&row| {
        matches(
            &kind_at(world, row),
            &id_at(world, row),
            &role_text(world, row, "title"),
        )
    })
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("the user searche[sd] settings for {Q}"),
        |world, c, _| search(world, &c[0]),
    );
    steps.step("each result names its section", |world, _, _| {
        let list = rows(world)?;
        expect!(!list.is_empty(), "{}", describe_search(world));
        for row in &list {
            expect!(
                is_result(row) && !row["sectionLabel"].as_str().unwrap_or_default().is_empty(),
                "{}",
                describe_search(world)
            );
        }
        // And draws it: the first result's row shows its title and its section.
        let brick = nav(world)?;
        let title = list[0]["title"].as_str().unwrap_or_default();
        let section = list[0]["sectionLabel"].as_str().unwrap_or_default();
        expect!(
            brick.shows(world, title)? && brick.shows(world, section)?,
            "{}",
            describe_search(world)
        );
        Ok(())
    });
    steps.step(&format!("the settings search lists {Q}"), |world, c, _| {
        search(world, &c[0].to_lowercase())?;
        let index = result_titled(world, &c[0])?;
        world.mc.part::<NavState>().result = index;
        Ok(())
    });
    steps.step("the user presses Space on that result", |world, _, _| {
        let brick = nav(world)?;
        let index = world.mc.part::<NavState>().result;
        let row = brick.item(world, &format!("settingsRow{index}"))?;
        let _ = world.engine().invoke_by_name(row, "forceActiveFocus", &[]);
        expect!(
            brick.flag(world, row, "activeFocus"),
            "the result did not take the keyboard"
        );
        brick.press(world, "space")?;
        // A button is pressed by Space down and clicked by Space up.
        world.key(&KeyEvent::release(key::SPACE))?;
        world.sync()
    });
    steps.step(
        &format!("the section holding {Q} opens with {Q} highlighted"),
        |world, c, _| {
            expect!(
                c[0] == "Theme" && c[1] == c[0],
                "the steps know the \"Theme\" setting"
            );
            let route = world.state("route");
            expect!(
                at(&route, "kind") == "settings"
                    && at(&route, "section") == "/settings/appearance"
                    && at(&route, "target") == "themes",
                "the route is {}",
                show(&route)
            );
            Ok(())
        },
    );
    steps.step("the settings search is empty", |world, _, _| {
        expect!(search_text(world)?.is_empty(), "{}", describe_search(world));
        Ok(())
    });
    steps.step("the section list is shown again", |world, _, _| {
        let list = rows(world)?;
        let brick = nav(world)?;
        expect!(
            list.first()
                .is_some_and(|row| !is_result(row) && row["label"] == "General")
                && brick.shows(world, "General")?,
            "{}",
            describe_search(world)
        );
        Ok(())
    });
    steps.step(
        "the user cleared the settings search with Escape",
        |world, _, _| {
            search(world, "theme")?;
            nav(world)?.press(world, "escape")?;
            expect!(search_text(world)?.is_empty(), "{}", describe_search(world));
            Ok(())
        },
    );
    steps.step(
        &format!("the app sets the settings search to {Q}"),
        |world, c, _| world.dispatch("settings.search", json!({"query": c[0]})),
    );
    steps.step(&format!("the settings search shows {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        world.pump()?;
        expect!(search_text(world)? == wanted, "{}", describe_search(world));
        // And searches for it.
        let list = rows(world)?;
        expect!(
            list.first().is_some_and(is_result),
            "{}",
            describe_search(world)
        );
        Ok(())
    });

    // The command palette's settings.
    steps.step(
        &format!("the {Q} setting is listed before the {Q} shortcut"),
        |world, c, _| {
            hand_palette_its_settings(world)?;
            let setting = palette_row(world, |kind, id, title| {
                kind == "setting" && title == c[0] && id.contains('#')
            });
            let shortcut = palette_row(world, |kind, id, title| {
                kind == "setting" && title.starts_with(c[1].as_str()) && id.contains('?')
            });
            expect!(
                matches!((setting, shortcut), (Some(s), Some(k)) if k > s),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user searches the palette for {Q} and chooses the setting"),
        |world, c, _| {
            hand_palette_its_settings(world)?;
            if !is_open(world) {
                invoke(world, "show", &[])?;
            }
            set_query(world, &c[0])?;
            let row = palette_row(world, |kind, _, title| {
                kind == "setting" && title.eq_ignore_ascii_case(&c[0])
            });
            expect!(row.is_some(), "{}", describe(world));
            let ran = invoke_ok(world, "run", &[Value::Int(row.unwrap_or(0) as i32)])?;
            expect!(ran, "{}", describe(world));
            world.sync()
        },
    );
    steps.step(
        "settings open with the word wrap setting highlighted",
        |world, _, _| {
            let route = world.state("route");
            expect!(
                at(&route, "kind") == "settings"
                    && at(&route, "section") == "/settings/appearance"
                    && at(&route, "target") == "settingsRow:wordWrap",
                "the route is {}",
                show(&route)
            );
            expect!(!is_open(world), "the palette is still open");
            Ok(())
        },
    );
}
