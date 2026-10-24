//! The MC's settings document and this device's preferences, as the
//! desktop's settings store keeps them (desktop-qt's SettingsSteps.cpp and
//! FakeConfig.h): features/settings/saving-settings.feature.
//!
//! The MC's side is [`FakeConfig`]: one versioned document,
//! `hal-c2.readSettings` / `hal-c2.writeSettings` refusing a stale version
//! as the MC does, and the `config` frames for each environment's
//! subscribers. Other domains change it through [`fake_config`],
//! [`publish_themes`] and [`save_elsewhere`].

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::controllers::settings::Settings;
use serde_json::{Map, Value, json};

use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// Another environment's settings document: read, written and published as
/// this MC's own is.
#[derive(Default, Clone)]
pub struct Document {
    pub settings: Map<String, Value>,
    pub version: i64,
    pub refuse_writes: String,
}

#[derive(Default)]
pub struct FakeConfig {
    pub settings: Map<String, Value>,
    pub version: i64,
    /// ServerConfig, less settings.
    pub config: Map<String, Value>,
    /// EnvironmentTheme[] by environment.
    pub themes: HashMap<String, Vec<Value>>,
    /// Usage-limit source snapshots, by environment.
    pub sources: HashMap<String, Vec<Value>>,
    /// Other environments' ServerConfig, by environment.
    pub elsewhere: HashMap<String, Map<String, Value>>,
    pub documents: HashMap<String, Document>,
    /// Every writeSettings payload, in order, and whether each was saved.
    pub writes: Vec<Value>,
    pub saved: Vec<bool>,
    pub hold_reads: bool,
    /// Another client saves right after each read.
    pub edit_on_read: bool,
    pub refuse_writes: String,
    /// Sensitive provider variables sealed out of the document, by
    /// "<instance>/<name>" (HalC2.ProviderSecrets), and hub management keys
    /// by "hub/<source id>" (HalC2.UsageLimitSources).
    pub secrets: BTreeMap<String, String>,
}

pub fn fake_config(mc: &mut FakeMc) -> &mut FakeConfig {
    mc.part::<FakeConfig>()
}

fn config_subscribers(mc: &FakeMc, environment: &str) -> Vec<i64> {
    mc.subscribers("config")
        .into_iter()
        .filter(|id| text(&mc.shape_of(*id)["environment"]) == environment)
        .collect()
}

/// `frame` to each of the environment's config subscribers.
pub fn send_config(mc: &FakeMc, environment: &str, frame: Value) {
    for id in config_subscribers(mc, environment) {
        let mut with_id = frame.clone();
        with_id["id"] = json!(id);
        mc.send(&with_id);
    }
}

/// Another machine of the cluster keeps its own settings document.
fn owns_document(fake: &FakeConfig, environment: &str) -> bool {
    fake.documents.contains_key(environment) || fake.elsewhere.contains_key(environment)
}

/// The document as HalC2.ProviderSecrets.seal keeps it: each sensitive
/// provider variable's value moved to the secret store, a redacted one kept
/// when a secret is stored under its name, and the secrets of variables gone.
fn sealed(fake: &mut FakeConfig, mut settings: Map<String, Value>) -> Map<String, Value> {
    if let Some(Value::Object(instances)) = settings.get_mut("providerInstances") {
        for (id, instance) in instances.iter_mut() {
            let Some(instance) = instance.as_object_mut() else {
                continue;
            };
            let mut kept = HashSet::new();
            if let Some(Value::Array(environment)) = instance.get_mut("environment") {
                for variable in environment.iter_mut() {
                    let Some(variable) = variable.as_object_mut() else {
                        continue;
                    };
                    if variable.get("sensitive") != Some(&Value::Bool(true)) {
                        continue;
                    }
                    let key = format!("{id}/{}", text(&variable["name"]));
                    let value = text(variable.get("value").unwrap_or(&Value::Null));
                    kept.insert(key.clone());
                    if variable.get("valueRedacted") == Some(&Value::Bool(true))
                        && fake.secrets.contains_key(&key)
                    {
                        variable.insert("value".into(), json!(""));
                    } else if !value.is_empty() {
                        fake.secrets.insert(key, value);
                        variable.insert("value".into(), json!(""));
                        variable.insert("valueRedacted".into(), json!(true));
                    } else {
                        fake.secrets.remove(&key);
                        variable.remove("valueRedacted");
                    }
                }
            }
            let prefix = format!("{id}/");
            fake.secrets
                .retain(|secret, _| !secret.starts_with(&prefix) || kept.contains(secret));
        }
    }
    // As HalC2.UsageLimitSources.seal_keys: a hub's management key moves to
    // the secret store, the marker stays, and a dropped hub's key is deleted.
    const MARKER: &str = "••••••";
    let mut hubs = Map::new();
    if let Some(Value::Object(sources)) = settings.get_mut("usageLimitSources") {
        for (id, hub) in sources.iter_mut() {
            let key = text(&hub["managementKey"]);
            if !key.is_empty() && key != MARKER {
                fake.secrets.insert(format!("hub/{id}"), key);
                hub["managementKey"] = json!(MARKER);
            }
        }
        hubs = sources.clone();
    }
    fake.secrets.retain(|secret, _| {
        secret
            .strip_prefix("hub/")
            .is_none_or(|hub| hubs.contains_key(hub))
    });
    settings
}

/// Sends `config.themes` to the environment's config subscribers.
pub fn publish_themes(mc: &mut FakeMc, environment: &str, themes: Vec<Value>) {
    fake_config(mc)
        .themes
        .insert(environment.to_owned(), themes.clone());
    send_config(
        mc,
        environment,
        json!({"t": "config.themes", "themes": themes}),
    );
}

/// Another client's save: the document moves on, announced as
/// `config.settings` unless `quietly`.
pub fn save_elsewhere(mc: &mut FakeMc, key: &str, value: Value, quietly: bool) {
    let fake = fake_config(mc);
    fake.settings.insert(key.to_owned(), value);
    fake.version += 1;
    if quietly {
        return;
    }
    let settings = fake.settings.clone();
    let environment = mc.environment_id.clone();
    send_config(
        mc,
        &environment,
        json!({"t": "config.settings", "settings": settings}),
    );
}

/// The same on the environment's document ("" or the MC's own for this
/// MC's), as the MC saves a setting it owns.
pub fn save_on(mc: &mut FakeMc, environment: &str, key: &str, value: Value) {
    if environment.is_empty() || environment == mc.environment_id {
        save_elsewhere(mc, key, value, false);
        return;
    }
    let document = document_of(mc, environment);
    document.settings.insert(key.to_owned(), value);
    document.version += 1;
    let settings = document.settings.clone();
    send_config(
        mc,
        environment,
        json!({"t": "config.settings", "settings": settings}),
    );
}

/// Another environment's document, made on first use; its config snapshot
/// carries it.
pub fn document_of<'a>(mc: &'a mut FakeMc, environment: &str) -> &'a mut Document {
    fake_config(mc)
        .documents
        .entry(environment.to_owned())
        .or_default()
}

/// The MC's providers become `providers`, announced as `config.providers`.
pub fn publish_providers(mc: &mut FakeMc, providers: Vec<Value>) {
    fake_config(mc)
        .config
        .insert("providers".into(), Value::Array(providers.clone()));
    let environment = mc.environment_id.clone();
    send_config(
        mc,
        &environment,
        json!({"t": "config.providers", "providers": providers}),
    );
}

fn on_config_shape(mc: &mut FakeMc, id: i64, shape: &Value) -> Outcome {
    let environment = text(&shape["environment"]);
    let fake = fake_config(mc);
    let (themes, sources) = (
        fake.themes.get(&environment).cloned().unwrap_or_default(),
        fake.sources.get(&environment).cloned(),
    );
    // As the MC answers: the snapshot, then what it publishes.
    if environment == mc.environment_id {
        let fake = fake_config(mc);
        let mut config = fake.config.clone();
        config.insert("settings".into(), Value::Object(fake.settings.clone()));
        mc.send(&json!({"t": "config", "id": id, "mc": mc.name, "config": config}));
    } else if owns_document(fake_config(mc), &environment) {
        let fake = fake_config(mc);
        let mut config = fake
            .elsewhere
            .get(&environment)
            .cloned()
            .unwrap_or_default();
        let settings = fake
            .documents
            .get(&environment)
            .map(|d| d.settings.clone())
            .unwrap_or_default();
        config.insert("settings".into(), Value::Object(settings));
        mc.send(&json!({"t": "config", "id": id, "config": config}));
    }
    mc.send(&json!({"t": "config.themes", "id": id, "themes": themes}));
    if let Some(sources) = sources {
        mc.send(&json!({"t": "config.usageLimitSources", "id": id, "sources": sources}));
    }
    Ok(())
}

fn read_settings(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    let fake = fake_config(mc);
    if owns_document(fake, &rpc.environment) {
        let document = fake
            .documents
            .get(&rpc.environment)
            .cloned()
            .unwrap_or_default();
        mc.reply(
            rpc,
            json!({"settings": document.settings, "version": document.version}),
        );
        return Ok(());
    }
    if fake.hold_reads {
        return Ok(());
    }
    let (settings, version, edit) = (fake.settings.clone(), fake.version, fake.edit_on_read);
    mc.reply(rpc, json!({"settings": settings, "version": version}));
    if edit {
        let n = settings
            .get("otherEdits")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        save_elsewhere(mc, "otherEdits", json!(n + 1), true);
    }
    Ok(())
}

fn write_settings(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    let version = rpc.payload["version"].as_i64().unwrap_or(-1);
    let written = match &rpc.payload["settings"] {
        Value::Object(settings) => settings.clone(),
        _ => Map::new(),
    };
    let fake = fake_config(mc);
    if owns_document(fake, &rpc.environment) {
        let document = fake.documents.entry(rpc.environment.clone()).or_default();
        if !document.refuse_writes.is_empty() {
            let refusal = document.refuse_writes.clone();
            mc.refuse(rpc, &refusal);
        } else if version != document.version {
            mc.refuse_with(rpc, "settings changed", json!({"_tag": "StaleSettings"}));
        } else {
            document.settings = written;
            document.version += 1;
            let (settings, version) = (document.settings.clone(), document.version);
            mc.reply(rpc, json!({"version": version}));
            send_config(
                mc,
                &rpc.environment,
                json!({"t": "config.settings", "settings": settings}),
            );
        }
        return Ok(());
    }
    fake.writes.push(rpc.payload.clone());
    if !fake.refuse_writes.is_empty() {
        fake.saved.push(false);
        let refusal = fake.refuse_writes.clone();
        mc.refuse(rpc, &refusal);
        return Ok(());
    }
    if version != fake.version {
        fake.saved.push(false);
        mc.refuse_with(
            rpc,
            "settings changed",
            json!({"_tag": "StaleSettings", "message": "settings changed"}),
        );
        return Ok(());
    }
    fake.saved.push(true);
    let before = match fake.settings.get("providerInstances") {
        Some(Value::Object(before)) => before.clone(),
        _ => Map::new(),
    };
    fake.settings = sealed(fake, written);
    fake.version += 1;
    let (settings, version) = (fake.settings.clone(), fake.version);
    mc.reply(rpc, json!({"version": version}));
    let environment = mc.environment_id.clone();
    send_config(
        mc,
        &environment,
        json!({"t": "config.settings", "settings": settings}),
    );
    // A dropped hub's accounts leave what the MC publishes.
    let fake = fake_config(mc);
    if let Some(sources) = fake.sources.get(&environment).cloned() {
        let hubs = settings.get("usageLimitSources");
        let kept: Vec<Value> = sources
            .iter()
            .filter(|source| hubs.is_some_and(|h| h.get(text(&source["id"])).is_some()))
            .cloned()
            .collect();
        if kept.len() != sources.len() {
            fake.sources.insert(environment.clone(), kept.clone());
            send_config(
                mc,
                &environment,
                json!({"t": "config.usageLimitSources", "sources": kept}),
            );
        }
    }
    // As HalC2.Settings provider_enabled? reads it: an instance's own entry
    // first, then its driver's; an added instance that was removed is no
    // longer listed, and one's name and colour show as HalC2.Environment
    // lists them.
    let fake = fake_config(mc);
    let mut providers = fake
        .config
        .get("providers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let empty = Map::new();
    let instances = settings
        .get("providerInstances")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    let mut changed = false;
    providers.retain(|entry| {
        let id = text(&entry["instanceId"]);
        let gone = before.contains_key(&id)
            && !instances.contains_key(&id)
            && id != text(&entry["driver"]);
        changed |= gone;
        !gone
    });
    for entry in providers.iter_mut() {
        let id = text(&entry["instanceId"]);
        let instance = instances
            .get(&id)
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let Some(entry) = entry.as_object_mut() else {
            continue;
        };
        for key in ["displayName", "accentColor"] {
            let value = text(instance.get(key).unwrap_or(&Value::Null))
                .trim()
                .to_owned();
            // No provider lists an accent of its own, so a cleared one goes.
            if value.is_empty()
                && key == "accentColor"
                && !instance.is_empty()
                && entry.contains_key(key)
            {
                entry.remove(key);
                changed = true;
            }
            if value.is_empty() || entry.get(key) == Some(&json!(value)) {
                continue;
            }
            entry.insert(key.into(), json!(value));
            changed = true;
        }
        let enabled = match instance.get("enabled") {
            Some(enabled) => enabled.clone(),
            None => at(
                &Value::Object(settings.clone()),
                &format!("providers.{id}.enabled"),
            )
            .clone(),
        };
        if !enabled.is_boolean() || entry.get("enabled") == Some(&enabled) {
            continue;
        }
        entry.insert("enabled".into(), enabled);
        changed = true;
    }
    if changed {
        publish_providers(mc, providers);
    }
    Ok(())
}

fn settings(world: &World) -> Settings {
    Settings::of(world.engine())
}

fn wait_ready(world: &mut World) -> Outcome {
    world.wait_for("the shell to read the settings", |w| settings(w).ready())
}

/// How the shell's last change went: `Some(error)` once it is done.
#[derive(Default)]
struct Turned(Rc<RefCell<Option<Option<String>>>>);

fn turn(world: &mut World, key: &str, on: bool) -> Outcome {
    // Connected, the shell reads the settings next; unless the MC holds
    // them back.
    if !fake_config(&mut world.mc).hold_reads {
        wait_ready(world)?;
    }
    let outcome = Rc::new(RefCell::new(None));
    world.part::<Turned>().0 = outcome.clone();
    let done = outcome.clone();
    let key = key.to_owned();
    let engine = world.engine().clone();
    settings(world).change(
        &engine,
        move |document| {
            let mut document = document.clone();
            document.insert(key.clone(), json!(on));
            document
        },
        move |_, error| *done.borrow_mut() = Some(error),
    );
    world.wait_for("the change to be saved or given up", move |_| {
        outcome.borrow().is_some()
    })
}

fn preferences_path(world: &World) -> PathBuf {
    world.config_dir().join("preferences.json")
}

fn is_on(state: &str) -> bool {
    state == "on"
}

pub fn register(steps: &mut Steps) {
    steps.extension(|mc| {
        mc.on_shape("config", on_config_shape);
        mc.on_rpc("hal-c2.readSettings", read_settings);
        mc.on_rpc("hal-c2.writeSettings", write_settings);
    });

    // The MC's document.
    steps.step(
        &format!(r"the MC's settings are at version (\d+) with {Q} on"),
        |world, c, _| {
            let fake = fake_config(&mut world.mc);
            fake.version = c[0].parse().unwrap_or(0);
            fake.settings.insert(c[1].clone(), json!(true));
            Ok(())
        },
    );
    steps.step("the MC holds back its settings", |world, _, _| {
        fake_config(&mut world.mc).hold_reads = true;
        Ok(())
    });
    steps.step(
        &format!("another client saved {Q} on without the desktop hearing of it"),
        |world, c, _| {
            wait_ready(world)?;
            save_elsewhere(&mut world.mc, &c[0], json!(true), true);
            Ok(())
        },
    );
    steps.step(&format!("another client saves {Q} on"), |world, c, _| {
        wait_ready(world)?;
        save_elsewhere(&mut world.mc, &c[0], json!(true), false);
        Ok(())
    });
    steps.step(
        "another client saves the settings each time the desktop reads them",
        |world, _, _| {
            wait_ready(world)?;
            fake_config(&mut world.mc).edit_on_read = true;
            save_elsewhere(&mut world.mc, "otherEdits", json!(1), true);
            Ok(())
        },
    );
    steps.step(
        &format!("the MC refuses to save settings with {Q}"),
        |world, c, _| {
            fake_config(&mut world.mc).refuse_writes = c[0].clone();
            Ok(())
        },
    );
    steps.step(&format!("the MC restarts with {Q} on"), |world, c, _| {
        let fake = fake_config(&mut world.mc);
        fake.settings = Map::from_iter([(c[0].clone(), json!(true))]);
        fake.version = 0;
        world.mc.drop_connection();
        world.wait_for("the shell to see the drop", |w| !w.client_ready())
    });
    steps.step(
        &format!("the MC's configuration lists the provider {Q}"),
        |world, c, _| {
            fake_config(&mut world.mc)
                .config
                .insert("providers".into(), json!([{"provider": c[0]}]));
            Ok(())
        },
    );
    steps.step(&format!("the MC's providers become {Q}"), |world, c, _| {
        let providers = json!([{"provider": c[0]}]);
        fake_config(&mut world.mc)
            .config
            .insert("providers".into(), providers.clone());
        let environment = world.mc.environment_id.clone();
        send_config(
            &world.mc,
            &environment,
            json!({"t": "config.providers", "providers": providers}),
        );
        Ok(())
    });

    // The shell's side.
    steps.step(
        &format!("the desktop (?:turns|turned) {Q} (on|off)"),
        |world, c, _| turn(world, &c[0], is_on(&c[1])),
    );
    steps.step(
        r"the desktop holds the MC's settings at version (\d+)",
        |world, c, _| {
            let version: i64 = c[0].parse().unwrap_or(-1);
            world.wait_for_with(
                move |w| settings(w).ready() && settings(w).version() == version,
                move |w| {
                    let s = settings(w);
                    format!(
                        "version {version}; the shell holds version {} ({})",
                        s.version(),
                        if s.ready() { "read" } else { "not read" }
                    )
                },
            )
        },
    );
    steps.step(&format!("the desktop holds {Q} (on|off)"), |world, c, _| {
        let (key, on) = (c[0].clone(), is_on(&c[1]));
        let state = c[1].clone();
        let shown = key.clone();
        world.wait_for_with(
            move |w| settings(w).ready() && settings(w).value(&key) == Some(json!(on)),
            move |w| {
                format!(
                    "{shown} {state}; the shell holds {}",
                    show(&Value::Object(settings(w).settings()))
                )
            },
        )
    });
    steps.step(&format!("the desktop reports {Q}"), |world, c, _| {
        let outcome = world.part::<Turned>().0.borrow().clone().flatten();
        expect!(
            outcome.as_deref() == Some(c[0].as_str()),
            "the change ended with {}",
            outcome.as_deref().unwrap_or("no error")
        );
        let error = settings(world).error();
        expect!(error == c[0], "the store reports \"{error}\"");
        Ok(())
    });
    steps.step(
        &format!("the desktop's configuration lists the provider {Q}"),
        |world, c, _| {
            let provider = c[0].clone();
            world.wait_for_with(
                move |w| {
                    let config = Value::Object(settings(w).config());
                    text(&config["providers"][0]["provider"]) == provider
                },
                |w| {
                    format!(
                        "the provider in {}",
                        show(&Value::Object(settings(w).config()))
                    )
                },
            )
        },
    );

    // What the MC was sent.
    steps.step(
        r"the MC saved the change at version (\d+)",
        |world, c, _| {
            let fake = fake_config(&mut world.mc);
            expect!(fake.saved.last() == Some(&true), "the MC saved nothing");
            let version = fake
                .writes
                .last()
                .map(|w| text(&w["version"]))
                .unwrap_or_default();
            expect!(version == c[0], "saved at version {version}");
            Ok(())
        },
    );
    steps.step(&format!("the MC holds {Q} (on|off)"), |world, c, _| {
        let fake = fake_config(&mut world.mc);
        expect!(
            fake.settings.get(&c[0]) == Some(&json!(is_on(&c[1]))),
            "the MC holds {}",
            show(&Value::Object(fake.settings.clone()))
        );
        Ok(())
    });
    steps.step(&format!("the MC does not hold {Q} off"), |world, c, _| {
        let fake = fake_config(&mut world.mc);
        expect!(
            fake.settings.get(&c[0]) != Some(&json!(false)),
            "the MC holds {}",
            show(&Value::Object(fake.settings.clone()))
        );
        Ok(())
    });
    steps.step(
        "the MC refused the desktop's first save as stale",
        |world, _, _| {
            let saved = &fake_config(&mut world.mc).saved;
            let answers: Vec<&str> = saved
                .iter()
                .map(|s| if *s { "saved" } else { "refused" })
                .collect();
            expect!(
                saved.len() >= 2 && !saved[0] && saved[saved.len() - 1],
                "the MC's answers to the saves were [{}]",
                answers.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the MC's settings were not written", |world, _, _| {
        world.sync()?;
        let writes = fake_config(&mut world.mc).writes.len();
        expect!(writes == 0, "the MC was sent {writes} write(s)");
        Ok(())
    });

    // This device's preferences.
    steps.step(
        &format!("this device's preferences say {Q} is {Q}"),
        |world, c, _| {
            let path = preferences_path(world);
            let document = json!({ c[0].clone(): c[1] });
            std::fs::write(&path, document.to_string())
                .map_err(|e| Failure(format!("cannot write {}: {e}", path.display())))
        },
    );
    steps.step(
        &format!("this device's {Q} is set to {Q}"),
        |world, c, _| {
            let engine = world.engine().clone();
            let mut device = settings(world).device();
            device.insert(c[0].clone(), json!(c[1]));
            expect!(
                settings(world).set_device_settings(&engine, device),
                "the preferences were not saved"
            );
            world.pump()
        },
    );
    steps.step(
        "this device's preferences cannot be saved",
        |world, _, _| {
            // A file where the preferences' directory would be.
            let blocker = world.config_dir().join("blocked");
            if let Err(e) = std::fs::write(&blocker, b"") {
                fail!("cannot write {}: {e}", blocker.display());
            }
            let engine = world.engine().clone();
            settings(world).set_device_path(&engine, Some(blocker.join("preferences.json")));
            world.pump()
        },
    );
    steps.step("the desktop shell starts", |world, _, _| {
        // main.rs reads this device's preferences before anything else.
        let engine = world.engine().clone();
        let path = preferences_path(world);
        settings(world).set_device_path(&engine, Some(path));
        world.connect()?;
        world.wait_for("the shell to start", |w| w.active())
    });
    steps.step(
        &format!("the desktop saves the device preference {Q} as {Q}"),
        |world, c, _| {
            let engine = world.engine().clone();
            settings(world).write_device(&engine, &c[0], json!(c[1]));
            world.pump()
        },
    );
    steps.step(
        &format!("this device's preferences file holds {Q} as {Q}"),
        |world, c, _| {
            let path = preferences_path(world);
            let Ok(bytes) = std::fs::read(&path) else {
                fail!("there is no {}", path.display());
            };
            let saved: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            expect!(
                saved[&c[0]] == json!(c[1]),
                "the file holds {}",
                show(&saved)
            );
            Ok(())
        },
    );
    steps.step(
        "the desktop reports this device's preferences could not be saved",
        |world, _, _| {
            let error = settings(world).device_error();
            expect!(
                error.starts_with("Cannot save"),
                "the store reports \"{error}\""
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the device preference {Q} is not set"),
        |world, c, _| {
            let device = settings(world).device();
            expect!(
                !device.contains_key(&c[0]),
                "this device holds {}",
                show(&Value::Object(device))
            );
            Ok(())
        },
    );
}
