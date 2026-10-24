//! The auto-settle rules in Settings → General, per environment
//! (threads/settle.feature): the settings rows over the settings scope,
//! against the MC's settings documents (FakeConfig). desktop-qt's
//! ThreadSettleSettingsSteps.cpp.

use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::settings_scope::SettingsScope;
use serde_json::{Map, Value, json};

use super::settings::{document_of, fake_config, save_on};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::expect;

const DAYS: &str = "sidebarAutoSettleAfterDays";
const ON_MERGE: &str = "sidebarAutoSettleOnMerge";

#[derive(Default)]
struct SettleRules {
    key: String,
    value: Value,
}

fn scope(world: &World) -> Value {
    world.state("settingsScope")
}

/// The rules as Settings → General's rows read them across the scope.
fn rules(world: &World) -> Value {
    let engine = world.engine();
    let settings = Settings::of(engine);
    let rule = |key: &str| {
        json!({"value": settings.setting(engine, key).unwrap_or(Value::Null),
               "mixed": settings.mixed(engine, key)})
    };
    json!({DAYS: rule(DAYS), ON_MERGE: rule(ON_MERGE), "offline": settings.unreachable(engine)})
}

fn document_for(world: &mut World, environment: &str) -> Map<String, Value> {
    if environment.is_empty() {
        fake_config(&mut world.mc).settings.clone()
    } else {
        document_of(&mut world.mc, environment).settings.clone()
    }
}

/// Another machine of the cluster, settling after three days and not on merge.
fn add_environment(world: &mut World, name: &str) {
    if world.mc.members.iter().any(|m| m == name) {
        return;
    }
    fake_config(&mut world.mc)
        .elsewhere
        .entry(name.to_owned())
        .or_default();
    let document = document_of(&mut world.mc, name);
    document.settings.insert(DAYS.into(), json!(3));
    document.settings.insert(ON_MERGE.into(), json!(false));
    world.mc.join_named(name);
}

/// This machine settles after three days and not on merge, like the others.
fn start(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    if fake_config(&mut world.mc).settings.contains_key(ON_MERGE) {
        return Ok(());
    }
    save_on(&mut world.mc, "", DAYS, json!(3));
    save_on(&mut world.mc, "", ON_MERGE, json!(false));
    world.sync()
}

/// Settings → General with the scope on `environment` ("" for all), ready on
/// `targets` environments.
fn open(world: &mut World, environment: &str, targets: usize) -> Outcome {
    world.dispatch("settings.open", json!({}))?;
    world.dispatch("settings.navigate", json!({"to": "/settings/general"}))?;
    let mut id = String::new();
    if !environment.is_empty() {
        let find = |w: &World| {
            scope(w)["environments"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|row| row["label"] == json!(environment))
                .map(|row| text(&row["id"]))
        };
        world.wait_for_with(
            |w| find(w).is_some(),
            |w| format!("{environment} to be offered; the scope is {}", show(&scope(w))),
        )?;
        id = find(world).unwrap_or_default();
    }
    world.dispatch("settingsScope.environment", json!({"id": id}))?;
    world.wait_for_with(
        |w| {
            // Every environment's document has been read.
            let engine = w.engine();
            let scope_controller = SettingsScope::of(engine);
            let known = scope_controller.read(|_, _| Some(json!(true))).known;
            scope(w)["editable"].as_bool() == Some(true)
                && scope_controller.targets().len() == targets
                && known == targets
        },
        |w| {
            format!(
                "the rules of {targets} environments; the scope is {}, the rules {}",
                show(&scope(w)),
                show(&rules(w))
            )
        },
    )
}

fn set(world: &mut World, key: &str, value: Value) -> Outcome {
    let rules = world.mc.part::<SettleRules>();
    rules.key = key.to_owned();
    rules.value = value.clone();
    // As the row's control does (SettingsRow.qml).
    let engine = world.engine().clone();
    Settings::of(&engine).set(&engine, key, value);
    world.sync()
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user sets auto-settle to (after 7 days|never on inactivity|when the PR merges) for (the environment \"home\"|all environments)",
        |world, c, _| {
            start(world)?;
            for name in ["home", "work"] {
                add_environment(world, name);
            }
            let all = c[1] == "all environments";
            open(world, if all { "" } else { "home" }, if all { 3 } else { 1 })?;
            match c[0].as_str() {
                "after 7 days" => set(world, DAYS, json!(7)),
                "never on inactivity" => set(world, DAYS, Value::Null),
                _ => set(world, ON_MERGE, json!(true)),
            }
        },
    );
    steps.step(
        "threads on (\"home\" only|every environment) follow the new rule",
        |world, c, _| {
            let (key, value) = {
                let changed = world.mc.part::<SettleRules>();
                (changed.key.clone(), changed.value.clone())
            };
            let everywhere = c[0] == "every environment";
            let has = |w: &mut World, environment: &str| {
                let document = document_for(w, environment);
                document.contains_key(&key) && document[&key] == value
            };
            world.wait_for_with(
                |w| {
                    let document = w.mc.peek::<super::settings::FakeConfig>().and_then(|f| f.documents.get("home"));
                    document.is_some_and(|d| d.settings.contains_key(&key) && d.settings[&key] == value)
                },
                |w| {
                    let home = w
                        .mc
                        .peek::<super::settings::FakeConfig>()
                        .and_then(|f| f.documents.get("home"))
                        .map(|d| Value::Object(d.settings.clone()))
                        .unwrap_or(Value::Null);
                    let writes = w
                        .mc
                        .peek::<super::settings::FakeConfig>()
                        .map_or(0, |f| f.writes.len());
                    format!(
                        "home to take the rule; it has {}, the MC was asked {writes} writes, the shell shows {}",
                        show(&home),
                        show(&w.state("toasts"))
                    )
                },
            )?;
            world.sync()?;
            let (work, here) = (has(world, "work"), has(world, ""));
            expect!(
                work == everywhere && here == everywhere,
                "work has {}, this machine {}",
                show(&Value::Object(document_for(world, "work"))),
                show(&Value::Object(document_for(world, "")))
            );
            Ok(())
        },
    );

    steps.step(
        &format!("{Q} settles after (\\d+) days and {Q} settles after (\\d+) days"),
        |world, c, _| {
            start(world)?;
            add_environment(world, &c[0]);
            add_environment(world, &c[2]);
            let (first, second) = (c[1].parse::<i64>().unwrap_or(0), c[3].parse::<i64>().unwrap_or(0));
            document_of(&mut world.mc, &c[0])
                .settings
                .insert(DAYS.into(), json!(first));
            document_of(&mut world.mc, &c[2])
                .settings
                .insert(DAYS.into(), json!(second));
            Ok(())
        },
    );
    steps.step(
        "the user looks at the auto-settle rules for all environments",
        |world, _, _| open(world, "", 3),
    );
    steps.step("the quiet spell is shown as mixed", |world, _, _| {
        // SettingsRow.qml says "Mixed" for a rule whose environments differ.
        world.wait_for_with(
            |w| at(&rules(w), &format!("{DAYS}.mixed")).as_bool() == Some(true),
            |w| format!("a mixed quiet spell; the rules are {}", show(&rules(w))),
        )?;
        let rules = rules(world);
        expect!(
            at(&rules, &format!("{ON_MERGE}.mixed")).as_bool() != Some(true),
            "the rules are {}",
            show(&rules)
        );
        Ok(())
    });

    steps.step(
        "the user changes the auto-settle rules for all environments",
        |world, _, _| {
            start(world)?;
            add_environment(world, "home");
            // "work" is linked and out of reach: this machine and "home" take the change.
            open(world, "", 2)?;
            set(world, DAYS, json!(7))
        },
    );
    steps.step(&format!("{Q} keeps its previous rules"), |world, c, _| {
        world.wait_for("home to take the rule", |w| {
            w.mc.peek::<super::settings::FakeConfig>()
                .and_then(|f| f.documents.get("home"))
                .is_some_and(|d| d.settings.get(DAYS) == Some(&json!(7)))
        })?;
        world.sync()?;
        let document = document_for(world, &c[0]);
        expect!(
            !document.contains_key(DAYS),
            "{} has {}",
            c[0],
            show(&Value::Object(document))
        );
        Ok(())
    });
    steps.step(
        &format!("the user can see {Q} was not updated"),
        |world, c, _| {
            let toasts = world.state("toasts");
            let told = toasts["items"].as_array().is_some_and(|items| {
                items
                    .iter()
                    .any(|item| text(&item["title"]) == format!("Not updated: {}", c[0]))
            });
            let rules = rules(world);
            expect!(
                told && rules["offline"] == json!([c[0]]),
                "the shell shows {}, the rules {}",
                show(&toasts),
                show(&rules)
            );
            Ok(())
        },
    );
}

