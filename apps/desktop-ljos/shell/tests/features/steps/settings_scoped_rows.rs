//! Settings → General's rows of the MC across the settings scope: rows an
//! environment cannot honour, and values the environments disagree on
//! (features/settings/general.feature). desktop-qt's
//! SettingsScopedRowsSteps.cpp.

use hal_c2_shell::controllers::settings_scope::SettingsScope;
use serde_json::{Map, Value, json};

use crate::brick::Brick;
use crate::expect;
use crate::harness::{Outcome, Q, Steps, show};
use crate::steps::settings::{FakeConfig, document_of, fake_config, send_config};
use crate::steps::settings_rows::{choose_row, general_page, page_item};
use crate::world::World;

const OTHER: &str = "Build box";
const SETTLES: &str = "threadAutoSettlement";
const CONTINUES: &str = "threadRestartContinuation";
const STREAMING: &str = "responseStreamingMode";
const CONTINUE: &str = "continueThreadsAfterServerUpdate";

/// The MC's saved settings.
pub fn held_all(world: &World) -> Value {
    world
        .mc
        .peek::<FakeConfig>()
        .map_or(Value::Null, |config| Value::Object(config.settings.clone()))
}

/// The MC's saved value of `key`.
pub fn held(world: &World, key: &str) -> Value {
    held_all(world)[key].clone()
}

/// What the other machine saved of `key`.
pub fn held_elsewhere(world: &World, environment: &str, key: &str) -> Value {
    world
        .mc
        .peek::<FakeConfig>()
        .and_then(|config| config.documents.get(environment))
        .map_or(Value::Null, |document| {
            document.settings.get(key).cloned().unwrap_or(Value::Null)
        })
}

pub fn with_capabilities(
    mut config: Map<String, Value>,
    capabilities: Value,
) -> Map<String, Value> {
    let mut environment = config
        .get("environment")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    environment.insert("capabilities".into(), capabilities);
    config.insert("environment".into(), Value::Object(environment));
    config
}

/// This machine's MC says what it can do, as its `config` snapshot does.
fn announce_here(world: &mut World, capabilities: Value) -> Outcome {
    let fake = fake_config(&mut world.mc);
    fake.config = with_capabilities(fake.config.clone(), capabilities);
    let mut config = fake.config.clone();
    config.insert("settings".into(), Value::Object(fake.settings.clone()));
    let (environment, name) = (world.mc.environment_id.clone(), world.mc.name.clone());
    send_config(
        &world.mc,
        &environment,
        json!({"t": "config", "mc": name, "config": config}),
    );
    world.sync()
}

/// Another machine the MC is linked to, with its own settings: in the scope
/// once its settings arrive.
fn link_other(world: &mut World, capabilities: Value, settings: Map<String, Value>) -> Outcome {
    fake_config(&mut world.mc)
        .elsewhere
        .insert(OTHER.into(), with_capabilities(Map::new(), capabilities));
    document_of(&mut world.mc, OTHER).settings = settings;
    world.mc.join_named(OTHER);
    world.wait_for_with(
        |w| {
            let scope = SettingsScope::of(w.engine());
            scope.targets().len() == 2 && scope.settings(OTHER).is_some()
        },
        |w| {
            format!(
                "both environments in the scope; it is {}",
                show(&w.state("settingsScope"))
            )
        },
    )
}

fn everything() -> Value {
    json!({SETTLES: true, CONTINUES: true})
}

/// Whether the page lists the row now (the page lays rows out as it goes).
fn listed(world: &World, page: Brick, key: &str) -> bool {
    match page.find(world, &format!("settingsRow:{key}")) {
        Ok(Some(row)) => page.flag(world, row, "visible"),
        _ => false,
    }
}

const SETTLING_ROWS: [&str; 2] = ["sidebarAutoSettleOnMerge", "sidebarAutoSettleAfterDays"];

fn control_enabled(world: &World, page: Brick) -> bool {
    let Ok(Some(row)) = page.find(world, &format!("settingsRow:{CONTINUE}")) else {
        return false;
    };
    match page.find_in(world, row, "control") {
        Ok(Some(control)) => page.flag(world, control, "enabled"),
        _ => false,
    }
}

fn display_text(world: &World, page: Brick) -> String {
    let Ok(Some(row)) = page.find(world, &format!("settingsRow:{STREAMING}")) else {
        return String::new();
    };
    match page.find_in(world, row, "control") {
        Ok(Some(control)) => page.text_of(world, control, "displayText"),
        _ => String::new(),
    }
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the settings scope includes an environment whose MC does not settle threads",
        |world, _, _| {
            announce_here(world, everything())?;
            // While every environment settles threads the rows are there.
            let page = general_page(world)?;
            world.wait_for("the auto-settle rows to be shown", move |w| {
                SETTLING_ROWS.iter().all(|row| listed(w, page, row))
            })?;
            link_other(world, json!({CONTINUES: true}), Map::new())
        },
    );
    steps.step("the auto-settle rows are not shown", |world, _, _| {
        let page = general_page(world)?;
        world.wait_for("the auto-settle rows to go", move |w| {
            SETTLING_ROWS.iter().all(|row| !listed(w, page, row))
        })?;
        // The rest of the section stays.
        expect!(
            listed(world, page, "autoResumeLimitedThreads"),
            "the other Organization rows went too"
        );
        Ok(())
    });

    steps.step(
        "the settings scope includes an environment that cannot continue threads after restarts",
        |world, _, _| {
            announce_here(world, everything())?;
            let page = general_page(world)?;
            world.wait_for("the continuation switch to be offered", move |w| {
                control_enabled(w, page)
            })?;
            link_other(world, json!({SETTLES: true}), Map::new())
        },
    );
    steps.step("the continuation switch is disabled", |world, _, _| {
        let page = general_page(world)?;
        world.wait_for("the continuation switch to be disabled", move |w| {
            !control_enabled(w, page)
        })
    });
    steps.step(
        "it explains that every selected environment must support restart continuation",
        |world, _, _| {
            let page = general_page(world)?;
            let status = page_item(world, &format!("settingsRow:{CONTINUE}"), "status")?;
            let shown = page.text_of(world, status, "text");
            expect!(
                page.flag(world, status, "visible")
                    && shown
                        == "All selected connected environments must support restart continuation.",
                "the row says \"{shown}\""
            );
            Ok(())
        },
    );

    steps.step(
        "the settings scope covers two environments with different streaming modes",
        |world, _, _| {
            announce_here(world, everything())?;
            let mut settings = Map::new();
            settings.insert(STREAMING.into(), json!("turn"));
            link_other(world, everything(), settings)
        },
    );
    steps.step(
        &format!("the response streaming row reads {Q}"),
        |world, c, _| {
            let page = general_page(world)?;
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| display_text(w, page) == wanted,
                |w| format!("the row reads \"{}\"", display_text(w, page)),
            )?;
            expect!(
                page.shows(world, "The selected targets use different streaming modes.")?,
                "the row does not say the modes differ"
            );
            Ok(())
        },
    );
    steps.step(
        "choosing a mode writes it to both environments",
        |world, _, _| {
            choose_row(world, STREAMING, "Wait for the full response")?;
            world.wait_for_with(
                |w| {
                    held(w, STREAMING) == json!("turn")
                        && held_elsewhere(w, OTHER, STREAMING) == json!("turn")
                },
                |w| {
                    format!(
                        "both to hold turn; this machine holds {}, {OTHER} holds {}",
                        show(&held_all(w)),
                        show(&held_elsewhere(w, OTHER, STREAMING))
                    )
                },
            )?;
            let page = general_page(world)?;
            world.wait_for_with(
                |w| display_text(w, page) == "Wait for the full response",
                |w| format!("the row reads \"{}\"", display_text(w, page)),
            )
        },
    );
}
