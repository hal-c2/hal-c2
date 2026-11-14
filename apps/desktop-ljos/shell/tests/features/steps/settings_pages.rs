//! The native settings pages' rows, driven as the rows drive the settings
//! store: setting, resetting and reading a row's value, wherever the row
//! keeps it (desktop-qt's SettingsPagesSteps.cpp):
//! features/settings/general.feature, navigation/appearance.feature.

use hal_c2_shell::controllers::settings::{Settings, same};
use hal_c2_shell::json::Json;
use serde_json::{Map, Value, json};

use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::settings::FakeConfig;
use crate::world::World;

/// The rows the scenarios name, and a value off each one's default.
fn row(name: &str) -> (&'static str, Json) {
    match name {
        "project grouping" => ("sidebarProjectGroupingMode", json!("separate")),
        "auto-settle on merge" => ("sidebarAutoSettleOnMerge", json!(false)),
        "contrast" => ("appearanceContrast", json!(120)),
        "glass opacity" => ("glassOpacity", json!(60)),
        "environment identification" => ("environmentIdentificationMode", json!("pill")),
        "diff colors" => ("diffColorScheme", json!("blue-orange")),
        "composer context" => ("persistComposerContextStrip", json!(true)),
        "panel animations" => ("panelAnimationDurationMs", json!(200)),
        "font smoothing" => ("fontSmoothing", json!(false)),
        "word wrapping" => ("wordWrap", json!(false)),
        _ => ("fontFamilySans", json!("")),
    }
}

const ROWS: &str = "(project grouping|auto-settle on merge|contrast|glass opacity|environment identification|\
diff colors|composer context|panel animations|font smoothing|word wrapping|the interface font)";

const SETTLE_DAYS: &str = "sidebarAutoSettleAfterDays";

fn settings(world: &World) -> Settings {
    Settings::of(world.engine())
}

fn setting(world: &World, key: &str) -> Json {
    settings(world)
        .setting(world.engine(), key)
        .unwrap_or(Json::Null)
}

fn default_of(world: &World, key: &str) -> Json {
    settings(world).default_of(key).unwrap_or(Json::Null)
}

fn is_default(world: &World, key: &str) -> bool {
    settings(world).is_default(world.engine(), key)
}

fn mc_settings(world: &World) -> Map<String, Json> {
    world
        .mc
        .peek::<FakeConfig>()
        .map(|fake| fake.settings.clone())
        .unwrap_or_default()
}

fn describe(world: &World, key: &str) -> String {
    let (value, fallback) = (setting(world, key), default_of(world, key));
    let mc = Value::Object(mc_settings(world));
    format!(
        "{key} is {} (default {}); the MC holds {}",
        show(&value),
        show(&fallback),
        show(&mc)
    )
}

fn ready(world: &mut World) -> Outcome {
    if settings(world).ready() {
        return Ok(());
    }
    if world.mc.connections.is_empty() {
        world.connect()?;
    }
    world.wait_for("the shell to read the MC's settings", |w| {
        settings(w).ready()
    })
}

/// Sets a row as its control does, and waits for the store that keeps it.
fn set(world: &mut World, key: &str, value: Json) -> Outcome {
    let engine = world.engine().clone();
    settings(world).set(&engine, key, value.clone());
    world.pump()?;
    let (k, v) = (key.to_owned(), value.clone());
    let shown = key.to_owned();
    world.wait_for_with(
        move |w| same(&setting(w, &k), &v),
        move |w| describe(w, &shown),
    )?;
    if !settings(world).on_device(key) {
        // The MC stores a default as its absence, and null as null.
        let (k, v) = (key.to_owned(), value);
        let shown = key.to_owned();
        world.wait_for_with(
            move |w| {
                let stored = mc_settings(w).get(&k).cloned();
                if is_default(w, &k) {
                    stored.is_none_or(|s| same(&s, &v))
                } else {
                    stored.is_some_and(|s| same(&s, &v))
                }
            },
            move |w| describe(w, &shown),
        )?;
    }
    Ok(())
}

fn open_section(world: &mut World, section: &str) -> Outcome {
    ready(world)?;
    world.dispatch("settings.open", json!({}))?;
    world.dispatch("settings.navigate", json!({"to": section}))?;
    let section = section.to_owned();
    world.wait_for_with(
        move |w| text(at(&w.state("route"), "section")) == section,
        |w| format!("the route is {}", show(&w.state("route"))),
    )
}

fn at_default(world: &mut World, key: &str) -> Outcome {
    world.sync()?;
    let ok = is_default(world, key) && same(&setting(world, key), &default_of(world, key));
    expect!(ok, "{}", describe(world, key));
    if settings(world).on_device(key) {
        let device = settings(world).device();
        expect!(
            !device.contains_key(key),
            "this device holds {}",
            show(&Value::Object(device))
        );
    }
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.step("the user has opened the General settings", |world, _, _| {
        open_section(world, "/settings/general")
    });
    steps.step("the user is in Settings → Appearance", |world, _, _| {
        open_section(world, "/settings/appearance")
    });

    // Any row.
    steps.step(
        &format!("the user (?:turned|changed) {ROWS}(?: off)?"),
        |world, c, _| {
            let (key, changed) = row(&c[0]);
            world.setting_row = key.to_owned();
            set(world, key, changed)?;
            expect!(!is_default(world, key), "{}", describe(world, key));
            Ok(())
        },
    );
    steps.step(
        &format!("the user set the interface font to {Q}"),
        |world, c, _| {
            world.setting_row = "fontFamilySans".into();
            set(world, "fontFamilySans", json!(c[0]))
        },
    );
    steps.step(&format!("the user resets {ROWS}"), |world, c, _| {
        let key = row(&c[0]).0;
        let engine = world.engine().clone();
        settings(world).reset(&engine, key);
        world.pump()?;
        world.wait_for_with(move |w| is_default(w, key), move |w| describe(w, key))
    });
    steps.step(
        &format!("{ROWS} is (?:back )?(?:at|to) its default"),
        |world, c, _| {
            let key = row(&c[0]).0;
            world.setting_row = key.to_owned();
            ready(world)?;
            at_default(world, key)
        },
    );
    steps.step(
        "the interface uses the system default font",
        |world, _, _| {
            at_default(world, "fontFamilySans")?;
            let value = setting(world, "fontFamilySans");
            expect!(value == json!(""), "{}", describe(world, "fontFamilySans"));
            Ok(())
        },
    );
    steps.step(
        "the row (?:no longer offers a|offers no) reset",
        |world, _, _| {
            let key = world.setting_row.clone();
            expect!(is_default(world, &key), "{}", describe(world, &key));
            Ok(())
        },
    );

    // Inactive settling: a switch over the days, null being off.
    steps.step("\"Auto-settle inactive threads\" is off", |world, _, _| {
        set(world, SETTLE_DAYS, Json::Null)
    });
    steps.step("the user turns it on", |world, _, _| {
        // What the row's switch does (js/settingsRows.js settleFromToggle).
        let fallback = default_of(world, SETTLE_DAYS);
        set(world, SETTLE_DAYS, fallback)
    });
    steps.step(
        "the number of days before settling is shown with its default",
        |world, _, _| {
            let ok = same(
                &setting(world, SETTLE_DAYS),
                &default_of(world, SETTLE_DAYS),
            ) && same(&default_of(world, SETTLE_DAYS), &json!(3));
            expect!(ok, "{}", describe(world, SETTLE_DAYS));
            Ok(())
        },
    );
    steps.step("the user can change the number of days", |world, _, _| {
        set(world, SETTLE_DAYS, json!(7))
    });
}
