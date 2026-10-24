//! A native settings page's rows (qml/HalC2/Bricks/SettingsPage.qml),
//! driven through the controls the page draws: its switches by clicking
//! them, its lists by picking an option (desktop-qt's SettingsRows.h and
//! SettingsRowsSteps.cpp). Helpers only; the steps are other domains'.

use hal_c2_shell::controllers::settings::{Settings, same};
use hal_c2_shell::json::{self as shell_json, Json};
use ljos::prelude::{ObjectId, Value};
use serde_json::json;

use crate::brick::{self, Brick, Shown};
use crate::harness::{Failure, Outcome, Steps, show, text};
use crate::steps::settings::fake_config;
use crate::world::World;
use crate::{expect, fail};

/// The test window's height: a pointer reaches no further.
const TEST_WINDOW_HEIGHT: f64 = 800.0;

fn settings(world: &World) -> Settings {
    Settings::of(world.engine())
}

fn setting(world: &World, key: &str) -> Json {
    settings(world)
        .setting(world.engine(), key)
        .unwrap_or(Json::Null)
}

fn row_name(key: &str) -> String {
    format!("settingsRow:{key}")
}

/// Settings → General on screen as the world's brick, tall enough to show
/// every row.
pub fn general_page(world: &mut World) -> Outcome<Brick> {
    if world.part::<Shown>().0.is_none() {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nGeneralSettings {}\n",
            800.0,
            3200.0,
        )?;
        // The page fills the window the way a Brick's root does in desktop-qt.
        let page = brick::shown(world)?;
        if let Some(root) = page.root(world) {
            page.write(world, root, "width", Value::from(800.0))?;
            page.write(world, root, "height", Value::from(3200.0))?;
            world.pump()?;
        }
    }
    brick::shown(world)
}

/// The item named `child` inside the page's item named `name` (a row is
/// "settingsRow:<key>", its control "control"); fails the step when there
/// is none.
pub fn page_item(world: &mut World, name: &str, child: &str) -> Outcome<ObjectId> {
    let page = general_page(world)?;
    // Rows are made as the page lays out.
    world.pump()?;
    let Some(row) = page.find(world, name)? else {
        fail!("the page has no {name}");
    };
    match page.find_in(world, row, child)? {
        Some(found) => Ok(found),
        None => fail!("{name} has no {child}"),
    }
}

/// Whether the page lists the row.
pub fn row_shown(world: &mut World, key: &str) -> Outcome<bool> {
    let page = general_page(world)?;
    world.pump()?;
    Ok(match page.find(world, &row_name(key))? {
        Some(row) => page.flag(world, row, "visible"),
        None => false,
    })
}

/// A switch row's state: its setting, or for project grouping whether it
/// groups.
pub fn setting_on(world: &World, key: &str) -> bool {
    match setting(world, key) {
        Json::Bool(on) => on,
        other => text(&other) != "separate",
    }
}

/// Clicks the row's switch unless it already is `on`, and waits for the
/// setting.
pub fn turn_row(world: &mut World, key: &str, on: bool) -> Outcome {
    let page = general_page(world)?;
    let control = page_item(world, &row_name(key), "control")?;
    expect!(
        page.flag(world, control, "enabled"),
        "the {key} switch is disabled"
    );
    if page.flag(world, control, "checked") != on {
        let (x, y) = page.at(world, control, 0.5, 0.5)?;
        if y < TEST_WINDOW_HEIGHT {
            world.click_at(x, y)?;
        } else {
            // The row lies below the test window, past where a pointer
            // reaches: the switch toggles as a click on it does.
            page.write(world, control, "checked", Value::from(on))?;
            world
                .engine()
                .emit_by_name(control, "toggled", &[])
                .map_err(|e| Failure(format!("toggled: {e:?}")))?;
        }
    }
    let key = key.to_owned();
    let shown = key.clone();
    world.wait_for_with(
        move |w| setting_on(w, &key) == on && page.flag(w, control, "checked") == on,
        move |w| {
            format!(
                "{shown} to be {}; it is {}",
                if on { "on" } else { "off" },
                show(&setting(w, &shown))
            )
        },
    )
}

/// Picks the option labelled `label` in the row's list, and waits for the
/// setting.
pub fn choose_row(world: &mut World, key: &str, label: &str) -> Outcome {
    let page = general_page(world)?;
    let control = page_item(world, &row_name(key), "control")?;
    expect!(
        page.flag(world, control, "enabled"),
        "the {key} list is disabled"
    );
    let model = shell_json::from_value(world.engine(), &page.read(world, control, "model"));
    let options = model.as_array().cloned().unwrap_or_default();
    let mut labels = Vec::new();
    for (index, option) in options.iter().enumerate() {
        labels.push(text(&option["label"]));
        if labels[index] != label {
            continue;
        }
        // What picking it from the open list does.
        world
            .engine()
            .emit_by_name(control, "activated", &[Value::from(index as i32)])
            .map_err(|e| crate::harness::Failure(format!("activated: {e:?}")))?;
        world.pump()?;
        let value = option["value"].clone();
        let key = key.to_owned();
        let shown = (key.clone(), value.clone());
        return world.wait_for_with(
            move |w| {
                same(&setting(w, &key), &value)
                    && text(&shell_json::from_value(
                        w.engine(),
                        &page.read(w, control, "currentIndex"),
                    )) == index.to_string()
            },
            move |w| {
                format!(
                    "{} to be {}; it is {}",
                    shown.0,
                    show(&shown.1),
                    show(&setting(w, &shown.0))
                )
            },
        );
    }
    fail!("{key} offers {}, not \"{label}\"", labels.join(", "))
}

/// What the row's list reads.
pub fn row_text(world: &mut World, key: &str) -> Outcome<String> {
    let page = general_page(world)?;
    let control = page_item(world, &row_name(key), "control")?;
    Ok(page.text_of(world, control, "currentText"))
}

/// The row's control is disabled, and setting it anyway writes to no
/// environment.
pub fn expect_row_locked(world: &mut World, key: &str) -> Outcome {
    let page = general_page(world)?;
    let control = page_item(world, &row_name(key), "control")?;
    expect!(
        !page.flag(world, control, "enabled"),
        "the {key} control can be used"
    );
    let written = |world: &mut World| {
        let fake = fake_config(&mut world.mc);
        fake.writes.len() as i64 + fake.documents.values().map(|d| d.version).sum::<i64>()
    };
    let before = written(world);
    let value = setting(world, key);
    let changed = match &value {
        Json::Bool(on) => json!(!on),
        _ => json!("changed"),
    };
    let engine = world.engine().clone();
    settings(world).set(&engine, key, changed);
    world.sync()?;
    expect!(
        written(world) == before && same(&setting(world, key), &value),
        "{key} was changed"
    );
    Ok(())
}

pub fn register(_steps: &mut Steps) {}
