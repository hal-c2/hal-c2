//! The Providers settings section on the desktop (ProviderSettings): the
//! @desktop scenarios of features/settings/providers-panel.feature and the
//! desktop's side of providers/provider-setup.feature (desktop-qt's
//! ProviderSettingsSteps.cpp). The MC's own environment plays "Laptop", this
//! machine; others are members of its cluster.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use hal_c2_shell::controllers::navigation::{Navigation, PROVIDERS_SECTION, Route};
use hal_c2_shell::controllers::settings::Settings;
use serde_json::{Map, Value, json};
use std::rc::Rc;

use ljos::prelude::{ObjectId, Value as JsValue};

use super::settings::{fake_config, publish_providers, save_elsewhere};
use super::stream::{PROJECT, iso, look_at_thread, now as stream_now};
use crate::brick::{Brick, Shown, shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The MC's side of sign-in (HalC2.ProviderAuth) and updates.
#[derive(Default)]
struct FakeProviders {
    /// Each instance's ProviderAuthState.
    auth: HashMap<String, Value>,
    starts: Vec<String>,
    cancels: Vec<String>,
    logouts: Vec<String>,
    /// The sign-in method each start asked for, "" for the default.
    methods: Vec<String>,
    /// provider.auth.respond payloads.
    responses: Vec<Value>,
    /// provider.auth.complete payloads.
    completes: Vec<Value>,
    terminal_gone: bool,
    /// The credential the agent last asked for.
    credential: String,
    updates: Vec<Rpc>,
    update_refusal: String,
    followed_before: usize,
    /// The instance the scenario last acted on.
    instance_id: String,
    /// The id the add-provider wizard last suggested.
    suggested_id: String,
    /// What the wizard held before the user went back.
    choices: String,
    /// Agents whose managed binary was cleaned up.
    uninstalls: Vec<String>,
    uninstall_refusal: String,
    /// The settings writes made before a custom model's save.
    writes_before: usize,
    /// ACP Registry queries and agents prepared.
    searches: Vec<String>,
    prepares: Vec<String>,
    /// The ACP agent's own sessions and model providers (HalC2.Acp.Sessions).
    acp_sessions: Vec<Value>,
    acp_providers: Vec<Value>,
    acp_imports: Vec<Value>,
    acp_sets: Vec<Value>,
    acp_deletes: Vec<String>,
    acp_disables: Vec<String>,
    acp_logouts: Vec<String>,
    /// The latest provider check a scenario seeded.
    checked_at: Option<DateTime<Utc>>,
    /// Sign-in pages the user continued (server.acceptAcpRegistryUrlAuth),
    /// and whether the environment still waited on them.
    url_auth_accepts: Vec<String>,
    url_auth_expired: bool,
    /// The managed runtime's ProviderInstallState, and the provider.install.*
    /// calls made ("start", "cancel <operationId>", "remove").
    install: Map<String, Value>,
    install_calls: Vec<String>,
    /// Calls the scenario answers itself, one at a time, while held.
    hold_prepares: bool,
    hold_starts: bool,
    held_prepares: Vec<Rpc>,
    held_starts: Vec<Rpc>,
}

/// The ACP Registry's compatible agents, as server.searchAcpRegistry lists
/// them.
fn registry_agents() -> Vec<Value> {
    let agent = |id: &str, name: &str, description: &str| {
        json!({
            "id": id,
            "name": name,
            "version": "1.2.3",
            "description": description,
            "distribution": "npx",
            "icon": format!("https://cdn.agentclientprotocol.com/{id}.svg"),
        })
    };
    // One with a website, one with only a repository, one with neither.
    let mut cli = agent("gemini-cli", "Gemini CLI", "Google's Gemini agent");
    cli["website"] = json!("https://geminicli.com");
    cli["repository"] = json!("https://github.com/google-gemini/gemini-cli");
    let mut lite = agent("gemini-lite", "Gemini Lite", "A smaller Gemini");
    lite["repository"] = json!("https://github.com/example/gemini-lite");
    vec![cli, lite, agent("goose", "Goose", "An open agent")]
}

fn fake(world: &mut World) -> &mut FakeProviders {
    world.mc.part::<FakeProviders>()
}

/// What the scenario has recorded so far, for a wait that only reads.
fn recorded(world: &World) -> &FakeProviders {
    static NONE: std::sync::OnceLock<FakeProviders> = std::sync::OnceLock::new();
    world
        .mc
        .peek::<FakeProviders>()
        .unwrap_or_else(|| NONE.get_or_init(FakeProviders::default))
}

const SIGN_IN_URL: &str = "https://auth.example/gemini";
const URL_AUTH_PAGE: &str = "https://auth.example/gemini/workspace";
const UPDATE_COMMAND: &str = "npm install -g @openai/codex@latest";

fn auth_state(instance_id: &str, fields: Value) -> Value {
    let mut state = json!({
        "instanceId": instance_id,
        "phase": "idle",
        "methods": [{"id": "browser"}],
    });
    merge(&mut state, fields);
    state
}

/// `fields` laid over `into`, as QJsonObject::insert does one key at a time.
fn merge(into: &mut Value, fields: Value) {
    if let Value::Object(fields) = fields {
        for (key, value) in fields {
            into[key] = value;
        }
    }
}

fn send_auth(mc: &mut FakeMc, instance_id: &str, fields: Value) {
    let state = auth_state(instance_id, fields);
    mc.part::<FakeProviders>()
        .auth
        .insert(instance_id.to_owned(), state.clone());
    for id in mc.subscribers("providerAuth") {
        if mc.shape_of(id)["instanceId"] != json!(instance_id) {
            continue;
        }
        mc.send(&json!({"t": "providerAuth", "id": id, "state": state}));
    }
}

/// The managed runtime changes as `patch` says, and every client following
/// it hears.
fn send_install(mc: &mut FakeMc, patch: Value) {
    let state = {
        let install = &mut mc.part::<FakeProviders>().install;
        if let Value::Object(patch) = patch {
            for (key, value) in patch {
                install.insert(key, value);
            }
        }
        Value::Object(install.clone())
    };
    for id in mc.subscribers("providerInstall") {
        mc.send(&json!({"t": "providerInstall", "id": id, "state": state}));
    }
}

fn install_state(mc: &mut FakeMc) -> Value {
    Value::Object(mc.part::<FakeProviders>().install.clone())
}

fn payload_text(rpc: &Rpc, key: &str) -> String {
    text(&rpc.payload[key])
}

fn extend(mc: &mut FakeMc) {
    mc.on_shape("providerAuth", |mc, id, shape| {
        let instance_id = text(&shape["instanceId"]);
        let state = mc
            .part::<FakeProviders>()
            .auth
            .get(&instance_id)
            .cloned()
            .unwrap_or_else(|| auth_state(&instance_id, Value::Null));
        mc.send(&json!({"t": "providerAuth", "id": id, "state": state}));
        Ok(())
    });
    mc.on_rpc("provider.auth.start", |mc, rpc| {
        let instance_id = payload_text(rpc, "instanceId");
        let fake = mc.part::<FakeProviders>();
        fake.starts.push(instance_id.clone());
        fake.methods.push(payload_text(rpc, "methodId"));
        if fake.hold_starts {
            fake.held_starts.push(rpc.clone());
            return Ok(());
        }
        mc.reply(rpc, json!({}));
        send_auth(
            mc,
            &instance_id,
            json!({
                "phase": "waiting",
                "flowId": "flow-1",
                "interaction": {
                    "id": "browser-1",
                    "type": "browser",
                    "url": SIGN_IN_URL,
                    "requiresConsent": false,
                },
            }),
        );
        Ok(())
    });
    mc.on_shape("providerInstall", |mc, id, _| {
        let state = install_state(mc);
        mc.send(&json!({"t": "providerInstall", "id": id, "state": state}));
        Ok(())
    });
    mc.on_rpc("provider.install.start", |mc, rpc| {
        mc.part::<FakeProviders>()
            .install_calls
            .push("start".into());
        send_install(
            mc,
            json!({
                "operationId": "op-1",
                "phase": "downloading",
                "downloadedBytes": 0,
                "message": "Downloading Google's official Antigravity runtime.",
            }),
        );
        let state = install_state(mc);
        mc.reply(rpc, state);
        Ok(())
    });
    mc.on_rpc("provider.install.cancel", |mc, rpc| {
        mc.part::<FakeProviders>()
            .install_calls
            .push(format!("cancel {}", payload_text(rpc, "operationId")));
        send_install(
            mc,
            json!({
                "phase": "cancelled",
                "message": "Installation cancelled. The previous runtime is unchanged.",
            }),
        );
        let state = install_state(mc);
        mc.reply(rpc, state);
        Ok(())
    });
    mc.on_rpc("provider.install.remove", |mc, rpc| {
        mc.part::<FakeProviders>()
            .install_calls
            .push("remove".into());
        send_install(
            mc,
            json!({
                "operationId": null,
                "phase": "idle",
                "downloadedBytes": 0,
                "installedVersion": null,
                "canRemove": false,
                "message": null,
            }),
        );
        let state = install_state(mc);
        mc.reply(rpc, state);
        Ok(())
    });
    mc.on_rpc("server.acceptAcpRegistryUrlAuth", |mc, rpc| {
        let fake = mc.part::<FakeProviders>();
        fake.url_auth_accepts.push(format!(
            "{}/{}",
            payload_text(rpc, "instanceId"),
            payload_text(rpc, "elicitationId")
        ));
        let accepted = !fake.url_auth_expired;
        mc.reply(rpc, json!({"accepted": accepted}));
        Ok(())
    });
    mc.on_rpc("provider.auth.cancel", |mc, rpc| {
        let instance_id = payload_text(rpc, "instanceId");
        mc.part::<FakeProviders>()
            .cancels
            .push(payload_text(rpc, "flowId"));
        mc.reply(rpc, json!({}));
        send_auth(mc, &instance_id, json!({"phase": "cancelled"}));
        Ok(())
    });
    mc.on_rpc("provider.auth.respond", |mc, rpc| {
        let fake = mc.part::<FakeProviders>();
        let terminal = rpc.payload["response"]["type"] == json!("terminal");
        if terminal && fake.terminal_gone {
            mc.refuse(rpc, "No sign-in is waiting for that input.");
            return Ok(());
        }
        fake.responses.push(rpc.payload.clone());
        mc.reply(rpc, json!({}));
        Ok(())
    });
    mc.on_rpc("provider.auth.complete", |mc, rpc| {
        mc.part::<FakeProviders>()
            .completes
            .push(rpc.payload.clone());
        mc.reply(rpc, json!({}));
        Ok(())
    });
    mc.on_rpc("provider.auth.logout", |mc, rpc| {
        mc.part::<FakeProviders>()
            .logouts
            .push(payload_text(rpc, "instanceId"));
        mc.reply(rpc, json!({}));
        Ok(())
    });
    mc.on_rpc("server.uninstallAcpRegistryManagedBinary", |mc, rpc| {
        let fake = mc.part::<FakeProviders>();
        fake.uninstalls.push(payload_text(rpc, "agentId"));
        let refusal = fake.uninstall_refusal.clone();
        if refusal.is_empty() {
            mc.reply(rpc, json!({}));
        } else {
            mc.refuse(rpc, &refusal);
        }
        Ok(())
    });
    mc.on_rpc("server.searchAcpRegistry", |mc, rpc| {
        let query = payload_text(rpc, "query");
        mc.part::<FakeProviders>().searches.push(query.clone());
        let agents: Vec<Value> = registry_agents()
            .into_iter()
            .filter(|agent| {
                text(&agent["id"])
                    .to_lowercase()
                    .contains(&query.to_lowercase())
            })
            .collect();
        mc.reply(rpc, json!({"agents": agents}));
        Ok(())
    });
    mc.on_rpc("server.prepareAcpRegistryAgent", |mc, rpc| {
        let agent_id = payload_text(rpc, "agentId");
        let fake = mc.part::<FakeProviders>();
        fake.prepares.push(agent_id.clone());
        if fake.hold_prepares {
            fake.held_prepares.push(rpc.clone());
            return Ok(());
        }
        mc.reply(
            rpc,
            json!({
                "agentId": agent_id,
                "version": "1.2.3",
                "distribution": "npx",
                "prepared": true,
            }),
        );
        Ok(())
    });
    mc.on_rpc("server.listAcpRegistrySessions", |mc, rpc| {
        let sessions = mc.part::<FakeProviders>().acp_sessions.clone();
        mc.reply(
            rpc,
            json!({
                "sessions": sessions,
                "nextCursor": null,
                "canLoad": true,
                "canResume": false,
                "canDelete": true,
            }),
        );
        Ok(())
    });
    mc.on_rpc("server.importAcpRegistrySession", |mc, rpc| {
        mc.part::<FakeProviders>()
            .acp_imports
            .push(rpc.payload.clone());
        mc.reply(
            rpc,
            json!({"threadId": "thread-imported", "imported": true}),
        );
        Ok(())
    });
    mc.on_rpc("server.deleteAcpRegistrySession", |mc, rpc| {
        let session_id = rpc.payload["sessionId"].clone();
        let fake = mc.part::<FakeProviders>();
        fake.acp_deletes.push(text(&session_id));
        fake.acp_sessions
            .retain(|session| session["sessionId"] != session_id);
        mc.reply(rpc, json!({"deleted": true}));
        Ok(())
    });
    mc.on_rpc("server.listAcpRegistryProviders", |mc, rpc| {
        let providers = mc.part::<FakeProviders>().acp_providers.clone();
        mc.reply(rpc, json!({"providers": providers}));
        Ok(())
    });
    fn current(mc: &mut FakeMc, provider_id: &str, value: Value) {
        for entry in &mut mc.part::<FakeProviders>().acp_providers {
            if entry["providerId"] == json!(provider_id) {
                entry["current"] = value.clone();
            }
        }
    }
    mc.on_rpc("server.setAcpRegistryProvider", |mc, rpc| {
        mc.part::<FakeProviders>()
            .acp_sets
            .push(rpc.payload.clone());
        current(
            mc,
            &payload_text(rpc, "providerId"),
            json!({"apiType": rpc.payload["apiType"], "baseUrl": rpc.payload["baseUrl"]}),
        );
        mc.reply(rpc, json!({"configured": true}));
        Ok(())
    });
    mc.on_rpc("server.disableAcpRegistryProvider", |mc, rpc| {
        let provider_id = payload_text(rpc, "providerId");
        mc.part::<FakeProviders>()
            .acp_disables
            .push(provider_id.clone());
        current(mc, &provider_id, Value::Null);
        mc.reply(rpc, json!({"disabled": true}));
        Ok(())
    });
    mc.on_rpc("server.logoutAcpRegistry", |mc, rpc| {
        mc.part::<FakeProviders>()
            .acp_logouts
            .push(payload_text(rpc, "instanceId"));
        mc.reply(rpc, json!({"loggedOut": true}));
        Ok(())
    });
    mc.on_rpc("server.updateProvider", |mc, rpc| {
        let fake = mc.part::<FakeProviders>();
        fake.updates.push(rpc.clone());
        let refusal = fake.update_refusal.clone();
        if !refusal.is_empty() {
            mc.refuse_with(rpc, &refusal, json!({"_tag": "ServerProviderUpdateError"}));
        }
        // Otherwise the update runs until the scenario finishes it.
        Ok(())
    });
}

fn panel(world: &World) -> Value {
    world.state("providerSettings")
}

fn entry(world: &World, name: &str) -> Value {
    panel(world)["providers"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|provider| provider["name"] == json!(name))
        .cloned()
        .unwrap_or(Value::Null)
}

fn is_empty(value: &Value) -> bool {
    value.is_null() || value.as_object().is_some_and(|o| o.is_empty())
}

fn wait_for_entry(
    world: &mut World,
    name: &str,
    ready: impl Fn(&World, &Value) -> bool,
    what: &str,
) -> Outcome<Value> {
    world.wait_for_with(
        |w| {
            let found = entry(w, name);
            !is_empty(&found) && ready(w, &found)
        },
        |w| format!("{name} {what}; the panel is {}", show(&panel(w))),
    )?;
    Ok(entry(world, name))
}

fn dispatch(world: &mut World, action: &str, name: &str) -> Outcome {
    let found = wait_for_entry(world, name, |_, _| true, "to be listed")?;
    let instance_id = text(&found["instanceId"]);
    fake(world).instance_id = instance_id.clone();
    world.dispatch(
        &format!("providerSettings.{action}"),
        json!({"instanceId": instance_id}),
    )
}

fn open_panel(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    if panel(world)["open"] == json!(true) {
        return Ok(());
    }
    let followed = world.mc.subscribers("config").len();
    fake(world).followed_before = followed;
    world.with::<Navigation, _>(|n, engine| {
        n.open(engine, Route::Settings(PROVIDERS_SECTION.into()))
    })?;
    world.wait_for_with(
        |w| panel(w)["open"] == json!(true),
        |w| {
            format!(
                "the Providers settings to open; they are {}",
                show(&panel(w))
            )
        },
    )
}

fn answer(world: &mut World, accepted: bool) -> Outcome {
    world.wait_for("the user to be asked", |w| {
        w.state("confirmation").is_object()
    })?;
    let question = world.state("confirmation");
    world.dispatch(
        "confirmation.answer",
        json!({"requestId": at(&question, "requestId"), "accepted": accepted}),
    )
}

fn provider(instance_id: &str, driver: &str, name: &str, fields: Value) -> Value {
    let mut entry = json!({
        "instanceId": instance_id,
        "driver": driver,
        "displayName": name,
        "enabled": true,
        "installed": true,
        "status": "ready",
        "version": "1.0.0",
        "auth": {"status": "unknown"},
        "models": [{"slug": format!("{instance_id}-model"), "name": format!("{name} model")}],
    });
    merge(&mut entry, fields);
    entry
}

/// A sign-in method named `name`, its id the name in kebab case.
fn sign_in_method(name: &str) -> Value {
    json!({"id": name.to_lowercase().replace(' ', "-"), "name": name})
}

/// An ACP agent that signs in from HAL-C2.
fn gemini(auth_status: &str) -> Value {
    let mut auth = json!({"status": auth_status});
    if auth_status == "authenticated" {
        auth["email"] = json!("sam@example.com");
    }
    provider(
        "gemini",
        "acpRegistry",
        "Gemini",
        json!({"auth": auth, "setup": {"canAuthenticate": true}}),
    )
}

/// "Gemini" signed in, managing its own sessions and model providers.
fn acp_agent(auth_status: &str) -> Value {
    provider(
        "gemini",
        "acpRegistry",
        "Gemini",
        json!({
            "auth": {"status": auth_status, "canLogout": true},
            "setup": {"canAuthenticate": false},
            "nativeSessions": {
                "canList": true,
                "canLoad": true,
                "canResume": false,
                "canDelete": true,
            },
            "configurableProviders": true,
        }),
    )
}

fn config_providers(world: &mut World) -> Vec<Value> {
    fake_config(&mut world.mc)
        .config
        .get("providers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

/// This machine's providers, replacing the one with the same instance id.
fn offer(world: &mut World, entry: Value) {
    let mut providers = config_providers(world);
    if let Some(index) = providers
        .iter()
        .position(|found| found["instanceId"] == entry["instanceId"])
    {
        providers.remove(index);
    }
    providers.push(entry);
    publish_providers(&mut world.mc, providers);
}

fn join_environment(world: &mut World, environment: &str, providers: Vec<Value>) {
    fake_config(&mut world.mc).elsewhere.insert(
        environment.to_owned(),
        Map::from_iter([("providers".to_owned(), Value::Array(providers))]),
    );
    world.mc.join_named(environment);
}

fn show_environment(world: &mut World, environment: &str) -> Outcome {
    open_panel(world)?;
    world.wait_for_with(
        |w| {
            panel(w)["environments"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|row| row["id"] == json!(environment))
        },
        |w| {
            format!(
                "{environment} to be offered; the panel is {}",
                show(&panel(w))
            )
        },
    )?;
    world.dispatch("providerSettings.environment", json!({"id": environment}))?;
    world.wait_for_with(
        |w| panel(w)["environmentId"] == json!(environment),
        |w| {
            format!(
                "{environment} to be shown; the panel is {}",
                show(&panel(w))
            )
        },
    )
}

fn saved_instances(world: &mut World) -> Map<String, Value> {
    fake_config(&mut world.mc)
        .settings
        .get("providerInstances")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

fn instance_enabled(world: &mut World, instance_id: &str) -> bool {
    saved_instances(world)
        .get(instance_id)
        .and_then(|saved| saved["enabled"].as_bool())
        .unwrap_or(true)
}

fn expect_enabled(world: &mut World, enabled: bool) -> Outcome {
    let instance_id = fake(world).instance_id.clone();
    let what = if enabled {
        "to be on in the saved settings"
    } else {
        "to be off in the saved settings"
    };
    // The saved settings are read once per wait: the MC's, not the shell's.
    world.wait_for_with(
        |w| {
            let found = entry(w, "Claude Work");
            !is_empty(&found)
                && found["enabled"].as_bool().unwrap_or(false) == enabled
                && saved_enabled(w, &instance_id) == enabled
                && (found["headline"] == json!("Disabled")) == !enabled
        },
        |w| format!("Claude Work {what}; the panel is {}", show(&panel(w))),
    )
}

/// What the MC's saved settings say of an instance's `enabled`, for a wait.
fn saved_enabled(world: &World, instance_id: &str) -> bool {
    world
        .mc
        .peek::<super::settings::FakeConfig>()
        .and_then(|config| config.settings.get("providerInstances"))
        .and_then(|instances| instances.get(instance_id))
        .and_then(|saved| saved["enabled"].as_bool())
        .unwrap_or(true)
}

/// This machine's settings gain the instance, as another client would add
/// it, and the machine lists it; it shows once its settings are there to
/// edit.
fn seed_instance(world: &mut World, instance_id: &str, instance: Value, listed: Value) -> Outcome {
    open_panel(world)?;
    let mut instances = saved_instances(world);
    instances.insert(instance_id.to_owned(), instance);
    save_elsewhere(
        &mut world.mc,
        "providerInstances",
        Value::Object(instances),
        false,
    );
    let name = text(&listed["displayName"]);
    offer(world, listed);
    wait_for_entry(
        world,
        &name,
        |_, found| found["editable"] == json!(true),
        "to be editable",
    )?;
    fake(world).instance_id = instance_id.to_owned();
    Ok(())
}

/// "Claude Work", an added Claude instance.
fn seed_work(world: &mut World, name: &str, environment: Value) -> Outcome {
    let mut instance = json!({"driver": "claudeAgent", "displayName": name, "enabled": true});
    if environment.as_array().is_some_and(|rows| !rows.is_empty()) {
        instance["environment"] = environment;
    }
    seed_instance(
        world,
        "claudeAgent_work",
        instance,
        provider("claudeAgent_work", "claudeAgent", name, Value::Null),
    )
}

fn saved_instance(world: &mut World, instance_id: &str) -> Value {
    saved_instances(world)
        .get(instance_id)
        .cloned()
        .unwrap_or(Value::Null)
}

fn picker_instance(world: &World, instance_id: &str) -> Value {
    world.state("modelPicker")["instances"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|shown| shown["instanceId"] == json!(instance_id))
        .cloned()
        .unwrap_or(Value::Null)
}

fn wizard(world: &World) -> Value {
    panel(world)["wizard"].clone()
}

fn wizard_closed(world: &World) -> bool {
    let shown = wizard(world);
    shown.is_null() || shown.as_object().is_some_and(|o| o.is_empty())
}

fn act(world: &mut World, action: &str, payload: Value) -> Outcome {
    world.dispatch(&format!("providerSettings.{action}"), payload)
}

fn open_wizard(world: &mut World) -> Outcome {
    open_panel(world)?;
    world.wait_for_with(
        |w| panel(w)["status"] == json!("ready"),
        |w| {
            format!(
                "the providers to be ready; the panel is {}",
                show(&panel(w))
            )
        },
    )?;
    act(world, "wizardOpen", Value::Null)?;
    world.wait_for_with(
        |w| !is_empty(&wizard(w)),
        |w| format!("the wizard to open; the panel is {}", show(&panel(w))),
    )
}

/// Chooses the driver shown as `driver_label` and names the instance.
fn start_adding(world: &mut World, driver_label: &str, label: Option<&str>) -> Outcome {
    open_wizard(world)?;
    let driver = wizard(world)["drivers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|option| option["label"] == json!(driver_label))
        .map(|option| text(&option["id"]))
        .next_back()
        .unwrap_or_default();
    expect!(
        !driver.is_empty(),
        "the wizard to offer {driver_label}; it is {}",
        show(&wizard(world))
    );
    act(world, "wizardDriver", json!({"driver": driver}))?;
    // The page hands over a label being typed with the step it moves to.
    let mut step = json!({"step": 1});
    if let Some(label) = label {
        step["label"] = json!(label);
    }
    act(world, "wizardStep", step)?;
    world.wait_for_with(
        |w| {
            wizard(w)["driver"] == json!(driver)
                && wizard(w)["step"] == json!(1)
                && label.is_none_or(|label| wizard(w)["label"] == json!(label))
        },
        |w| {
            format!(
                "the identity step for {driver_label}; the wizard is {}",
                show(&wizard(w))
            )
        },
    )?;
    let suggested = text(&wizard(world)["instanceId"]);
    fake(world).suggested_id = suggested;
    Ok(())
}

fn finish_adding(world: &mut World) -> Outcome {
    act(world, "wizardStep", json!({"step": 2}))?;
    act(world, "wizardSubmit", Value::Null)
}

fn toast_items(world: &World) -> Vec<Value> {
    at(&world.state("toasts"), "items")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn toasted(world: &World, title: &str, description: &str) -> bool {
    toast_items(world).iter().any(|toast| {
        toast["title"] == json!(title)
            && (description.is_empty() || toast["description"] == json!(description))
    })
}

fn expect_toast(world: &mut World, title: &str, description: &str) -> Outcome {
    world.wait_for_with(
        |w| toasted(w, title, description),
        |w| {
            format!(
                "a toast \"{title}\"; the shell shows {}",
                show(&w.state("toasts"))
            )
        },
    )
}

fn variables(world: &World, name: &str) -> Vec<Value> {
    entry(world, name)["variables"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn account(world: &World, name: &str) -> Value {
    entry(world, name)["account"].clone()
}

/// The MC's own environment goes away: nothing is accepted, and the
/// connection drops (FilesIdentitySteps' disconnectOwnEnvironment).
fn disconnect_own_environment(world: &mut World, environment: &str) -> Outcome<bool> {
    if environment != world.mc.environment_id {
        return Ok(false);
    }
    world.mc.stop_accepting();
    world.mc.drop_connection();
    world.wait_for("the shell to see the drop", |w| !w.client_ready())?;
    Ok(true)
}

fn hub_list_ready(world: &World) -> bool {
    panel(world)["hubs"].is_array()
}

/// The saved settings, as the MC holds them, shown for a failure.
fn saved_settings(world: &mut World) -> String {
    show(&Value::Object(fake_config(&mut world.mc).settings.clone()))
}

pub fn register(steps: &mut Steps) {
    steps.extension(extend);

    steps.step(
        &format!("the user has opened the Providers settings for the environment {Q}"),
        |world, _, _| open_panel(world),
    );

    // Environments.
    steps.step(
        &format!("the user has environments {Q}, {Q} and this machine"),
        |world, c, _| {
            join_environment(world, &c[0], Vec::new());
            join_environment(world, &c[1], Vec::new());
            Ok(())
        },
    );
    steps.step(
        "the user chooses which environment's providers to show",
        |world, _, _| {
            world.wait_for_with(
                |w| panel(w)["environments"].as_array().map(Vec::len) == Some(3),
                |w| format!("three environments; the panel is {}", show(&panel(w))),
            )
        },
    );
    steps.step(
        "this machine is listed first and the others follow by name",
        |world, _, _| {
            let labels: Vec<String> = panel(world)["environments"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|row| text(&row["label"]))
                .collect();
            expect!(
                labels == ["This machine", "Build box", "Laptop"],
                "the environments are {}",
                labels.join(", ")
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is disconnected"), |world, c, _| {
        if disconnect_own_environment(world, &c[0])? {
            return Ok(());
        }
        join_environment(
            world,
            &c[0],
            vec![provider("codex", "codex", "Codex", Value::Null)],
        );
        world.mc.set_online(&c[0], false);
        Ok(())
    });

    // Usage-limit hubs (settings/usage-limit-sources.feature).
    steps.step(
        "the user adds a hub with a URL and management key but no label",
        |world, _, _| {
            open_panel(world)?;
            world.wait_for_with(hub_list_ready, |w| {
                format!("the hubs to be listed; the panel is {}", show(&panel(w)))
            })?;
            act(
                world,
                "addHub",
                json!({"url": "https://hub.example.ts.net:8318", "key": "hub-key", "label": ""}),
            )
        },
    );
    steps.step(
        "the hub is listed under the hub's host name",
        |world, _, _| {
            let id = "cliproxy-hub.example.ts.net-8318";
            world.wait_for_with(
                |w| {
                    panel(w)["hubs"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .find(|hub| hub["id"] == json!(id))
                        .is_some_and(|hub| hub["label"] == json!("hub.example.ts.net:8318"))
                },
                |w| {
                    format!(
                        "the hub listed by its host; the panel is {}",
                        show(&panel(w))
                    )
                },
            )?;
            // The key went to the MC's secret store, not the document.
            let config = fake_config(&mut world.mc);
            let sealed = config.secrets.get(&format!("hub/{id}")).map(String::as_str)
                == Some("hub-key")
                && config.settings["usageLimitSources"][id]["managementKey"] == json!("••••••");
            expect!(
                sealed,
                "the key sealed on the MC; the settings are {}",
                saved_settings(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user fills in a URL but no management key",
        |world, _, _| {
            open_panel(world)?;
            act(
                world,
                "addHub",
                json!({"url": "https://hub.example", "key": ""}),
            )
        },
    );
    steps.step("the user cannot add the hub", |world, _, _| {
        world.sync()?;
        expect!(fake_config(&mut world.mc).writes.is_empty(), "no hub saved");
        Ok(())
    });
    steps.step(
        &format!("the user removes {Q} and confirms"),
        |world, c, _| {
            open_panel(world)?;
            let find = |w: &World| {
                panel(w)["hubs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|hub| hub["label"] == json!(c[0]))
                    .map(|hub| text(&hub["id"]))
                    .next_back()
                    .unwrap_or_default()
            };
            world.wait_for_with(
                |w| !find(w).is_empty(),
                |w| format!("{} to be listed; the panel is {}", c[0], show(&panel(w))),
            )?;
            let id = find(world);
            act(world, "removeHub", json!({"id": id}))
        },
    );
    steps.step("its key is deleted from the MC", |world, _, _| {
        world.wait_for("the hub's key to be deleted", |w| {
            w.mc.peek::<super::settings::FakeConfig>()
                .is_none_or(|config| !config.secrets.contains_key("hub/team-hub"))
        })?;
        expect!(
            fake_config(&mut world.mc).settings["usageLimitSources"]
                .get("team-hub")
                .is_none(),
            "the hub gone from the settings"
        );
        Ok(())
    });
    // Nothing is sent to the hub: the MC only saved its settings once.
    steps.step("the hub itself is untouched", |world, _, _| {
        let writes = fake_config(&mut world.mc).writes.len();
        expect!(writes == 1, "one settings write; there were {writes}");
        Ok(())
    });
    steps.step(&format!("{Q} reconnects"), |world, c, _| {
        world.mc.set_online(&c[0], true);
        Ok(())
    });
    steps.step(
        &format!("the user shows the providers of {Q}"),
        |world, c, _| show_environment(world, &c[0]),
    );
    steps.step(
        "the user is told to reconnect the device to set up its provider",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    panel(w)["status"] == json!("offline")
                        && text(&panel(w)["description"]).starts_with("Reconnect this device")
                        && panel(w)["providers"]
                            .as_array()
                            .is_none_or(|providers| providers.is_empty())
                },
                |w| {
                    format!(
                        "the panel to ask for a reconnect; it is {}",
                        show(&panel(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the providers of {Q} are listed"),
        |world, c, _| {
            wait_for_entry(
                world,
                "Codex",
                |w, _| {
                    panel(w)["environmentId"] == json!(c[0]) && panel(w)["status"] == json!("ready")
                },
                &format!("of {} to be listed", c[0]),
            )?;
            Ok(())
        },
    );
    steps.step("the user leaves the Providers settings", |world, _, _| {
        world.wait_for("a sign-in to be followed", |w| {
            !w.mc.subscribers("providerAuth").is_empty()
        })?;
        world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))
    });
    steps.step(
        "no provider or sign-in is followed for the panel",
        |world, _, _| {
            let followed = fake(world).followed_before;
            world.wait_for_with(
                |w| {
                    w.mc.subscribers("config").len() == followed
                        && w.mc.subscribers("providerAuth").is_empty()
                },
                |w| {
                    format!(
                        "only the shell's own config to be followed; {} configs and {} sign-ins are",
                        w.mc.subscribers("config").len(),
                        w.mc.subscribers("providerAuth").len()
                    )
                },
            )
        },
    );

    // Turning an instance off and on.
    steps.step(
        &format!("the user turns off the {Q} instance"),
        |world, c, _| {
            let instance_id = "claudeAgent_work";
            let mut instances = saved_instances(world);
            instances.insert(
                instance_id.into(),
                json!({"driver": "claudeAgent", "displayName": c[0], "enabled": true}),
            );
            fake_config(&mut world.mc)
                .settings
                .insert("providerInstances".into(), Value::Object(instances));
            offer(
                world,
                provider(instance_id, "claudeAgent", &c[0], Value::Null),
            );
            wait_for_entry(
                world,
                &c[0],
                |_, found| found["enabled"] == json!(true),
                "to be listed on",
            )?;
            fake(world).instance_id = instance_id.into();
            world.dispatch(
                "providerSettings.enable",
                json!({"instanceId": instance_id, "enabled": false}),
            )
        },
    );
    steps.step("the user turns it back on", |world, _, _| {
        let instance_id = fake(world).instance_id.clone();
        world.dispatch(
            "providerSettings.enable",
            json!({"instanceId": instance_id, "enabled": true}),
        )
    });
    // The model picker leaves out what the environment reports disabled
    // (providers/models.feature); the panel turns it off where the MC reads it.
    steps.step(
        "its models are not offered in new threads",
        |world, _, _| expect_enabled(world, false),
    );
    steps.step("its models are offered again", |world, _, _| {
        expect_enabled(world, true)
    });
    steps.step(&format!("saving settings on {Q} fails"), |world, _, _| {
        fake_config(&mut world.mc).refuse_writes = "The settings file could not be written.".into();
        Ok(())
    });
    steps.step(
        "the user is told the provider settings could not be saved",
        |world, _, _| {
            world.wait_for_with(
                |w| toasted(w, "Could not save provider settings", ""),
                |w| {
                    format!(
                        "a toast that the settings were not saved; the shell shows {}",
                        show(&w.state("toasts"))
                    )
                },
            )
        },
    );
    steps.step(&format!("{Q} stays on"), |world, c, _| {
        world.sync()?;
        let instance_id = fake(world).instance_id.clone();
        expect!(
            entry(world, &c[0])["enabled"] == json!(true) && instance_enabled(world, &instance_id),
            "{} to stay on; the panel is {}",
            c[0],
            show(&panel(world))
        );
        Ok(())
    });

    // Adding an instance.
    steps.step(
        &format!("the user adds (?:a|another) \"?([^\"]*?)\"? (?:provider|instance) labelled {Q}"),
        |world, c, _| {
            start_adding(world, &c[0], Some(&c[1]))?;
            finish_adding(world)
        },
    );
    steps.step(&format!("(?:an|the) instance {Q} exists"), |world, c, _| {
        open_panel(world)?;
        let mut instances = saved_instances(world);
        instances.insert(
            c[0].clone(),
            json!({"driver": c[0].split('_').next().unwrap_or(""), "enabled": true}),
        );
        save_elsewhere(
            &mut world.mc,
            "providerInstances",
            Value::Object(instances),
            false,
        );
        world.wait_for_with(
            |w| {
                panel(w)["providers"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|row| row["instanceId"] == json!(c[0]))
            },
            |w| format!("{} to be listed; the panel is {}", c[0], show(&panel(w))),
        )
    });
    steps.step(
        &format!("an instance with the id {Q} is listed"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    panel(w)["providers"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .any(|row| row["instanceId"] == json!(c[0]))
                        && saved_instance_peek(w, &c[0]).is_some_and(|saved| !is_empty(&saved))
                },
                |w| {
                    format!(
                        "{} to be saved and listed; the panel is {}",
                        c[0],
                        show(&panel(w))
                    )
                },
            )?;
            let saved = saved_instance(world, &c[0]);
            expect!(
                saved["driver"] == json!("claudeAgent")
                    && saved["enabled"] == json!(true)
                    && saved["displayName"] == json!("Work")
                    && panel(world)["wizard"].is_null(),
                "the saved instance is {}, the wizard {}",
                show(&saved),
                show(&panel(world)["wizard"])
            );
            Ok(())
        },
    );
    steps.step("the user is told the instance was added", |world, _, _| {
        expect_toast(
            world,
            "Provider instance added",
            "Claude instance 'claudeAgent_work' was added.",
        )
    });
    steps.step(
        &format!("(?:the suggested instance id|its instance id) is {Q}"),
        |world, c, _| {
            let suggested = fake(world).suggested_id.clone();
            expect!(suggested == c[0], "the wizard suggested {suggested}");
            world.wait_for_with(
                |w| saved_instance_peek(w, &c[0]).is_some_and(|saved| !is_empty(&saved)),
                |w| {
                    format!(
                        "{} to be saved; the settings are {}",
                        c[0],
                        w.mc.peek::<super::settings::FakeConfig>()
                            .map_or(String::new(), |config| show(&Value::Object(
                                config.settings.clone()
                            )))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user (?:enters|sets) the instance id (?:to )?{Q}(?: and continues)?"),
        |world, c, _| {
            start_adding(world, "Codex", None)?;
            act(world, "wizardInstanceId", json!({"instanceId": c[0]}))?;
            act(world, "wizardStep", json!({"step": 2}))
        },
    );
    steps.step(
        &format!("the user stays on the identity step and is told {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| wizard(w)["step"] == json!(1) && wizard(w)["instanceIdError"] == json!(c[0]),
                |w| {
                    format!(
                        "the identity step to say \"{}\"; the wizard is {}",
                        c[0],
                        show(&wizard(w))
                    )
                },
            )
        },
    );
    steps.step(
        "the user is on the configuration step of adding a provider",
        |world, _, _| {
            start_adding(world, "Claude", Some("Work"))?;
            act(world, "wizardAccent", json!({"color": "#22c55e"}))?;
            act(world, "wizardStep", json!({"step": 2}))?;
            act(
                world,
                "wizardField",
                json!({"key": "homePath", "value": "~/.claude-work"}),
            )?;
            world.wait_for_with(
                |w| {
                    wizard(w)["step"] == json!(2)
                        && at(&wizard(w), "fields")[1]["value"] == json!("~/.claude-work")
                },
                |w| format!("the configuration step; the wizard is {}", show(&wizard(w))),
            )?;
            let mut choices = wizard(world);
            if let Value::Object(choices) = &mut choices {
                choices.remove("step");
            }
            fake(world).choices = show(&choices);
            Ok(())
        },
    );
    steps.step("the user goes back to choosing a driver", |world, _, _| {
        act(world, "wizardStep", json!({"step": 0}))
    });
    steps.step("the choices already made are kept", |world, _, _| {
        world.wait_for_with(
            |w| wizard(w)["step"] == json!(0),
            |w| format!("the driver step; the wizard is {}", show(&wizard(w))),
        )?;
        let mut now = wizard(world);
        if let Value::Object(now) = &mut now {
            now.remove("step");
        }
        let held = fake(world).choices.clone();
        expect!(
            show(&now) == held,
            "the wizard held {held} and now {}",
            show(&now)
        );
        Ok(())
    });
    steps.step("the user adds a provider instance", |world, _, _| {
        start_adding(world, "Codex", None)?;
        finish_adding(world)
    });
    steps.step(
        "the user is told the provider instance could not be added",
        |world, _, _| {
            let refusal = fake_config(&mut world.mc).refuse_writes.clone();
            expect_toast(world, "Could not add provider instance", &refusal)?;
            world.wait_for_with(
                |w| !is_empty(&wizard(w)) && wizard(w)["saving"] != json!(true),
                |w| format!("the wizard to stay open; it is {}", show(&wizard(w))),
            )
        },
    );

    // Editing an instance.
    // The picker names an instance as the environment lists it (ComposerModel).
    steps.step(
        &format!("the instance is shown as {Q} in the model picker"),
        |world, c, _| {
            let instance_id = fake(world).instance_id.clone();
            wait_for_entry(
                world,
                &c[0],
                |w, found| {
                    found["label"] == json!(c[0])
                        && listed_name(w, &instance_id).as_deref() == Some(c[0].as_str())
                },
                "to be listed under its new name",
            )?;
            Ok(())
        },
    );
    // An instance's name and accent colour, as the model picker shows them.
    steps.step(
        &format!("the instance {Q}( has a green accent)?"),
        |world, c, _| {
            expect!(
                c[0] == "claudeAgent_work",
                "only claudeAgent_work is seeded, not {}",
                c[0]
            );
            seed_work(world, "Claude Work", Value::Null)?;
            if c[1].is_empty() {
                return Ok(());
            }
            act(
                world,
                "accent",
                json!({"instanceId": c[0], "color": "#22c55e"}),
            )?;
            world.wait_for_with(
                |w| {
                    saved_instance_peek(w, &c[0])
                        .is_some_and(|saved| saved["accentColor"] == json!("#22c55e"))
                },
                |w| {
                    format!(
                        "the accent to be saved; the instance is {}",
                        show(&saved_instance_peek(w, &c[0]).unwrap_or(Value::Null))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user renames it to {Q} and picks a green accent"),
        |world, c, _| {
            let id = fake(world).instance_id.clone();
            act(world, "rename", json!({"instanceId": id, "name": c[0]}))?;
            act(
                world,
                "accent",
                json!({"instanceId": id, "color": "#22c55e"}),
            )
        },
    );
    steps.step("the user clears the accent colour", |world, _, _| {
        let id = fake(world).instance_id.clone();
        act(world, "accent", json!({"instanceId": id, "color": ""}))
    });
    steps.step(
        &format!("the model picker shows {Q} in green"),
        |world, c, _| {
            let id = fake(world).instance_id.clone();
            world.wait_for_with(
                |w| {
                    let shown = picker_instance(w, &id);
                    shown["displayName"] == json!(c[0]) && shown["accentColor"] == json!("#22c55e")
                },
                |w| {
                    format!(
                        "{} in green; the picker lists {}",
                        c[0],
                        show(&w.state("modelPicker"))
                    )
                },
            )
        },
    );
    steps.step("the instance uses the default colour", |world, _, _| {
        let id = fake(world).instance_id.clone();
        world.wait_for_with(
            |w| {
                saved_instance_peek(w, &id).is_none_or(|saved| saved.get("accentColor").is_none())
                    && !is_empty(&picker_instance(w, &id))
                    && picker_instance(w, &id)["accentColor"].is_null()
            },
            |w| {
                format!(
                    "no accent; the instance is {}, the picker lists {}",
                    show(&saved_instance_peek(w, &id).unwrap_or(Value::Null)),
                    show(&w.state("modelPicker"))
                )
            },
        )
    });
    steps.step(
        &format!("the user adds the environment variable {Q} and marks it sensitive"),
        |world, c, _| {
            seed_work(world, "Claude Work", Value::Null)?;
            let id = fake(world).instance_id.clone();
            // desktop-qt's fake MC answers inside the call; here each edit is
            // settled before the next, as a user's are, or a stale save
            // would re-apply an earlier edit over the later one.
            act(world, "addVariable", json!({"instanceId": id}))?;
            for edit in [
                json!({"instanceId": id, "index": 0, "name": c[0]}),
                json!({"instanceId": id, "index": 0, "sensitive": true}),
                json!({"instanceId": id, "index": 0, "value": "sk-secret"}),
            ] {
                act(world, "variable", edit)?;
                world.sync()?;
            }
            Ok(())
        },
    );
    steps.step("its value is stored as a secret", |world, _, _| {
        let id = fake(world).instance_id.clone();
        world.wait_for_with(
            |w| {
                let environment = saved_instance_peek(w, &id)
                    .and_then(|saved| saved["environment"].as_array().cloned())
                    .unwrap_or_default();
                secret_peek(w, &format!("{id}/API_KEY")).as_deref() == Some("sk-secret")
                    && environment.len() == 1
                    && text(&environment[0]["value"]).is_empty()
            },
            |w| {
                format!(
                    "API_KEY to be sealed; the instance is {}",
                    show(&saved_instance_peek(w, &id).unwrap_or(Value::Null))
                )
            },
        )
    });
    steps.step(
        "the page shows it as a stored secret that a new value replaces",
        |world, _, _| {
            wait_for_entry(
                world,
                "Claude Work",
                |_, found| {
                    let rows = found["variables"].as_array().cloned().unwrap_or_default();
                    rows.len() == 1
                        && at(&rows[0], "redacted") == &json!(true)
                        && text(&rows[0]["value"]).is_empty()
                        && rows[0]["placeholder"]
                            == json!("Stored secret, enter a new value to replace")
                },
                "to show a stored secret",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the instance has the environment variable {Q}"),
        |world, c, _| {
            seed_work(
                world,
                "Claude Work",
                json!([{"name": c[0], "value": "sk-secret", "sensitive": true}]),
            )?;
            wait_for_entry(
                world,
                "Claude Work",
                |_, found| found["variables"].as_array().map(Vec::len) == Some(1),
                "to list its variable",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the instance keeps {Q} as a stored secret"),
        |world, c, _| {
            fake_config(&mut world.mc)
                .secrets
                .insert(format!("claudeAgent_work/{}", c[0]), "sk-secret".into());
            seed_work(
                world,
                "Claude Work",
                json!([{"name": c[0], "value": "", "sensitive": true, "valueRedacted": true}]),
            )?;
            wait_for_entry(
                world,
                "Claude Work",
                |_, found| {
                    let rows = found["variables"].as_array().cloned().unwrap_or_default();
                    rows.len() == 1 && at(&rows[0], "redacted") == &json!(true)
                },
                "to show its stored secret",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the user renames the variable {Q} to {Q}"),
        |world, c, _| {
            let rows = variables(world, "Claude Work");
            let id = fake(world).instance_id.clone();
            let Some(index) = rows.iter().position(|row| row["name"] == json!(c[0])) else {
                fail!(
                    "{} to be listed; the rows are {}",
                    c[0],
                    show(&Value::Array(rows))
                );
            };
            act(
                world,
                "variable",
                json!({"instanceId": id, "index": index, "name": c[1]}),
            )
        },
    );
    steps.step(
        &format!("{Q} asks for a new value instead of showing a stored secret"),
        |world, c, _| {
            wait_for_entry(
                world,
                "Claude Work",
                |_, found| {
                    let rows = found["variables"].as_array().cloned().unwrap_or_default();
                    rows.len() == 1
                        && rows[0]["name"] == json!(c[0])
                        && at(&rows[0], "redacted") != &json!(true)
                        && rows[0]["placeholder"] == json!("value")
                },
                &format!("to ask for a value for {}", c[0]),
            )?;
            let id = fake(world).instance_id.clone();
            world.wait_for_with(
                |w| {
                    let environment = saved_instance_peek(w, &id)
                        .and_then(|saved| saved["environment"].as_array().cloned())
                        .unwrap_or_default();
                    environment.len() == 1
                        && environment[0]["name"] == json!(c[0])
                        && environment[0].get("valueRedacted").is_none()
                },
                |w| {
                    format!(
                        "{} to be saved without a secret; the instance is {}",
                        c[0],
                        show(&saved_instance_peek(w, &id).unwrap_or(Value::Null))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the secret stored for {Q} is forgotten"),
        |world, c, _| {
            let key = format!("{}/{}", fake(world).instance_id, c[0]);
            world.wait_for_with(
                |w| secret_peek(w, &key).is_none(),
                |_| format!("the secret of {} to be deleted", c[0]),
            )
        },
    );
    steps.step(
        "Codex was checked (\\d+) minutes ago and Claude (\\d+) minutes ago",
        |world, c, _| {
            open_panel(world)?;
            let now = world.now();
            let (codex, claude): (i64, i64) =
                (c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0));
            let checked =
                |minutes: i64| super::usage::iso_ms(now - chrono::Duration::minutes(minutes));
            offer(
                world,
                provider(
                    "codex",
                    "codex",
                    "Codex",
                    json!({"checkedAt": checked(codex)}),
                ),
            );
            offer(
                world,
                provider(
                    "claudeAgent",
                    "claudeAgent",
                    "Claude",
                    json!({"checkedAt": checked(claude)}),
                ),
            );
            fake(world).checked_at = Some(now - chrono::Duration::minutes(codex.min(claude)));
            Ok(())
        },
    );
    steps.step(
        "the panel says providers were last checked by the latest of them",
        |world, _, _| {
            let want = fake(world).checked_at;
            world.wait_for_with(
                |w| {
                    DateTime::parse_from_rfc3339(&text(&panel(w)["checkedAt"]))
                        .ok()
                        .map(|time| time.with_timezone(&Utc))
                        == want
                },
                |w| {
                    format!(
                        "the panel to say {}; it is {}",
                        want.map_or(String::new(), super::usage::iso_ms),
                        show(&panel(w))
                    )
                },
            )
        },
    );
    // The managed Antigravity runtime (HalC2.Acp.Antigravity.Installation).
    steps.step(
        "the Antigravity runtime (is not installed|is downloading|is installed) on the environment",
        |world, c, _| {
            let installed = c[0] == "is installed";
            let downloading = c[0] == "is downloading";
            fake(world).install = Map::from_iter([
                ("driver".to_owned(), json!("antigravity")),
                (
                    "operationId".to_owned(),
                    if downloading {
                        json!("op-1")
                    } else {
                        Value::Null
                    },
                ),
                (
                    "phase".to_owned(),
                    json!(if downloading { "downloading" } else { "idle" }),
                ),
                (
                    "downloadedBytes".to_owned(),
                    json!(if downloading { 40_000_000 } else { 0 }),
                ),
                ("totalBytes".to_owned(), json!(100_000_000)),
                ("version".to_owned(), json!("1.2.0")),
                (
                    "installedVersion".to_owned(),
                    if installed {
                        json!("1.2.0")
                    } else {
                        Value::Null
                    },
                ),
                ("canRemove".to_owned(), json!(installed)),
                ("message".to_owned(), Value::Null),
            ]);
            open_panel(world)?;
            offer(
                world,
                provider(
                    "antigravity",
                    "antigravity",
                    "Antigravity",
                    json!({
                        "installed": installed,
                        "setup": {"canAuthenticate": true, "canInstall": true},
                    }),
                ),
            );
            wait_for_entry(
                world,
                "Antigravity",
                |_, found| !at(found, "runtime").is_null(),
                "to show its runtime",
            )?;
            Ok(())
        },
    );
    steps.step(
        "the user installs the Antigravity runtime",
        |world, _, _| {
            wait_for_entry(
                world,
                "Antigravity",
                |_, found| {
                    at(found, "runtime.installLabel") == &json!("Install Antigravity")
                        && at(found, "runtime.status") == &json!("100 MB download.")
                },
                "to offer installing its 100 MB runtime",
            )?;
            dispatch(world, "runtimeInstall", "Antigravity")
        },
    );
    steps.step(
        "the download's progress is shown as the environment reports it",
        |world, _, _| {
            wait_for_entry(
                world,
                "Antigravity",
                |_, found| {
                    at(found, "runtime.status") == &json!("Downloading 0.0 MB of 100.0 MB.")
                        && at(found, "runtime.canCancel") == &json!(true)
                        && text(at(found, "runtime.installLabel")).is_empty()
                },
                "to show the download starting",
            )?;
            let calls = fake(world).install_calls.clone();
            expect!(
                calls == ["start"],
                "one install to start; the calls are {}",
                calls.join(", ")
            );
            send_install(&mut world.mc, json!({"downloadedBytes": 25_000_000}));
            wait_for_entry(
                world,
                "Antigravity",
                |_, found| {
                    at(found, "runtime.status") == &json!("Downloading 25.0 MB of 100.0 MB.")
                        && (at(found, "runtime.progress").as_f64().unwrap_or(0.0) - 0.25).abs()
                            < 1e-9
                },
                "to show a quarter downloaded",
            )?;
            Ok(())
        },
    );
    steps.step("the user cancels the installation", |world, _, _| {
        dispatch(world, "runtimeCancel", "Antigravity")
    });
    steps.step("the environment cancels that download", |world, _, _| {
        world.wait_for_with(
            |w| recorded(w).install_calls == ["cancel op-1"],
            |w| {
                format!(
                    "op-1 to be cancelled; the calls are {}",
                    recorded(w).install_calls.join(", ")
                )
            },
        )
    });
    steps.step(
        "the card says the previous runtime is unchanged and offers to retry",
        |world, _, _| {
            wait_for_entry(
                world,
                "Antigravity",
                |_, found| {
                    at(found, "runtime.message")
                        == &json!("Installation cancelled. The previous runtime is unchanged.")
                        && at(found, "runtime.installLabel") == &json!("Retry installation")
                        && at(found, "runtime.canCancel") != &json!(true)
                },
                "to say the download was cancelled",
            )?;
            Ok(())
        },
    );
    steps.step(
        "the user removes the downloaded runtime and confirms",
        |world, _, _| {
            wait_for_entry(
                world,
                "Antigravity",
                |_, found| {
                    at(found, "runtime.canRemove") == &json!(true)
                        && at(found, "runtime.status") == &json!("Installed.")
                },
                "to offer removing its installed runtime",
            )?;
            dispatch(world, "runtimeRemove", "Antigravity")?;
            answer(world, true)
        },
    );
    steps.step("the environment removes it", |world, _, _| {
        world.wait_for_with(
            |w| recorded(w).install_calls == ["remove"],
            |w| {
                format!(
                    "the runtime to be removed; the calls are {}",
                    recorded(w).install_calls.join(", ")
                )
            },
        )
    });
    steps.step(
        "the card offers installing Antigravity again",
        |world, _, _| {
            offer(
                world,
                provider(
                    "antigravity",
                    "antigravity",
                    "Antigravity",
                    json!({
                        "installed": false,
                        "setup": {"canAuthenticate": true, "canInstall": true},
                    }),
                ),
            );
            wait_for_entry(
                world,
                "Antigravity",
                |_, found| {
                    at(found, "runtime.installLabel") == &json!("Install Antigravity")
                        && at(found, "runtime.canRemove") != &json!(true)
                        && at(found, "runtime.status") == &json!("100 MB download.")
                },
                "to offer installing it again",
            )?;
            Ok(())
        },
    );
    // A Cursor instance that signs in from the browser, keeping
    // `CURSOR_API_KEY` as a stored secret.
    steps.step(
        &format!("a Cursor instance keeps its own {Q}"),
        |world, c, _| {
            fake_config(&mut world.mc)
                .secrets
                .insert(format!("cursor_work/{}", c[0]), "crsr-secret".into());
            seed_instance(
                world,
                "cursor_work",
                json!({
                    "driver": "cursor",
                    "displayName": "Cursor Work",
                    "enabled": true,
                    "environment": [{
                        "name": c[0], "value": "", "sensitive": true, "valueRedacted": true,
                    }],
                }),
                provider(
                    "cursor_work",
                    "cursor",
                    "Cursor Work",
                    json!({"setup": {"canAuthenticate": true}}),
                ),
            )
        },
    );
    steps.step(
        "Cursor says its API key is used instead of browser sign-in",
        |world, _, _| {
            wait_for_entry(
                world,
                "Cursor Work",
                |_, found| {
                    at(found, "account.description")
                        == &json!("Using CURSOR_API_KEY. Remove it from this provider's environment to use browser sign-in.")
                        && at(found, "account.canSignIn") != &json!(true)
                },
                "to say the API key replaces browser sign-in",
            )?;
            Ok(())
        },
    );
    steps.step(&format!("the user clears {Q}"), |world, c, _| {
        wait_for_entry(
            world,
            "Cursor Work",
            |_, found| {
                found["secrets"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|secret| secret["name"] == json!(c[0]))
                    .is_some_and(|secret| secret["stored"] == json!(true))
            },
            &format!("to show a stored {}", c[0]),
        )?;
        let id = fake(world).instance_id.clone();
        act(
            world,
            "secret",
            json!({"instanceId": id, "name": c[0], "value": ""}),
        )
    });
    steps.step(
        "Cursor can be signed in from the browser again",
        |world, _, _| {
            let id = fake(world).instance_id.clone();
            wait_for_entry(
                world,
                "Cursor Work",
                |w, found| {
                    let secrets = found["secrets"].as_array().cloned().unwrap_or_default();
                    at(found, "account.canSignIn") == &json!(true)
                        && !secrets.is_empty()
                        && secrets[0]["stored"] != json!(true)
                        && saved_instance_peek(w, &id)
                            .is_none_or(|saved| saved.get("environment").is_none())
                },
                "to offer browser sign-in without a stored key",
            )?;
            Ok(())
        },
    );
    steps.step(&format!("the user removes {Q}"), |world, c, _| {
        // TODO(port): ComposerAttachSteps' removeComposerAttachment and
        // ThemeLibrarySteps' removesTheme answer first for an attachment and a
        // theme; they are not ported yet.
        let rows = variables(world, "Claude Work");
        let id = fake(world).instance_id.clone();
        let Some(index) = rows.iter().position(|row| row["name"] == json!(c[0])) else {
            fail!(
                "{} to be listed; the rows are {}",
                c[0],
                show(&Value::Array(rows))
            );
        };
        act(
            world,
            "removeVariable",
            json!({"instanceId": id, "index": index}),
        )
    });
    steps.step(
        &format!("the instance no longer sets {Q}"),
        |world, c, _| {
            let id = fake(world).instance_id.clone();
            let key = format!("{id}/{}", c[0]);
            world.wait_for_with(
                |w| {
                    saved_instance_peek(w, &id).is_some_and(|saved| {
                        !is_empty(&saved) && saved.get("environment").is_none()
                    }) && variables(w, "Claude Work").is_empty()
                        && secret_peek(w, &key).is_none()
                },
                |w| {
                    format!(
                        "{} to be gone; the instance is {}",
                        c[0],
                        show(&saved_instance_peek(w, &id).unwrap_or(Value::Null))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user deletes the {Q} instance"),
        |world, c, _| {
            seed_work(world, &c[0], Value::Null)?;
            let id = fake(world).instance_id.clone();
            act(world, "delete", json!({"instanceId": id}))
        },
    );
    steps.step("it is no longer listed", |world, _, _| {
        let id = fake(world).instance_id.clone();
        world.wait_for_with(
            |w| {
                !panel(w)["providers"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|row| row["instanceId"] == json!(id))
                    && saved_instance_peek(w, &id).is_none_or(|saved| is_empty(&saved))
            },
            |w| format!("{id} to be gone; the panel is {}", show(&panel(w))),
        )
    });
    steps.step(
        "cleaning up the instance's managed binary fails",
        |world, _, _| {
            fake(world).uninstall_refusal = "The agent's files are in use.".into();
            Ok(())
        },
    );
    steps.step("the user deletes the instance", |world, _, _| {
        seed_instance(
            world,
            "acpRegistry_gemini",
            json!({
                "driver": "acpRegistry",
                "displayName": "Gemini",
                "enabled": true,
                "config": {"agentId": "gemini"},
            }),
            provider("acpRegistry_gemini", "acpRegistry", "Gemini", Value::Null),
        )?;
        let id = fake(world).instance_id.clone();
        act(world, "delete", json!({"instanceId": id}))
    });
    steps.step(
        "the user is told the provider was deleted but managed files remain",
        |world, _, _| {
            let refusal = fake(world).uninstall_refusal.clone();
            expect_toast(
                world,
                "Provider deleted, but managed files remain",
                &refusal,
            )?;
            let id = fake(world).instance_id.clone();
            let uninstalls = fake(world).uninstalls.clone();
            expect!(
                uninstalls == ["gemini"] && is_empty(&saved_instance(world, &id)),
                "gemini to be deleted and cleaned up; cleaned up {}",
                uninstalls.join(", ")
            );
            Ok(())
        },
    );

    // Signing in and out.
    steps.step(
        &format!("{Q} can sign in from HAL-C2 and is signed out"),
        |world, c, _| {
            open_panel(world)?;
            offer(world, gemini("unauthenticated"));
            wait_for_entry(
                world,
                &c[0],
                |_, found| at(found, "account.canSignIn") == &json!(true),
                "to offer signing in",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("(?:{Q} is signed in from HAL-C2|the user is signed in to an ACP agent)"),
        |world, _, _| {
            open_panel(world)?;
            offer(world, gemini("authenticated"));
            wait_for_entry(
                world,
                "Gemini",
                |_, found| at(found, "account.canSignOut") == &json!(true),
                "to offer signing out",
            )?;
            Ok(())
        },
    );
    steps.step(&format!("the user signs in to {Q}"), |world, c, _| {
        dispatch(world, "signIn", &c[0])
    });
    // A sign-in answered after the user switched environments and back.
    steps.step(
        &format!("the user signs in to {Q} while the environment is slow to answer"),
        |world, c, _| {
            fake(world).hold_starts = true;
            dispatch(world, "signIn", &c[0])?;
            world.wait_for("the sign-in to be started", |w| {
                recorded(w).held_starts.len() == 1
            })
        },
    );
    steps.step(
        &format!("the user switches to another environment and back and signs in to {Q} again"),
        |world, c, _| {
            join_environment(world, "Studio", Vec::new());
            show_environment(world, "Studio")?;
            let own = world.mc.environment_id.clone();
            show_environment(world, &own)?;
            wait_for_entry(
                world,
                &c[0],
                |_, found| at(found, "account.canSignIn") == &json!(true),
                "to offer signing in again",
            )?;
            dispatch(world, "signIn", &c[0])?;
            world.wait_for("the second sign-in to be started", |w| {
                recorded(w).held_starts.len() == 2
            })
        },
    );
    steps.step("the first sign-in is answered", |world, _, _| {
        let first = fake(world).held_starts.remove(0);
        world.mc.reply(&first, json!({}));
        world.sync()
    });
    steps.step(
        "the second sign-in is still waiting on the environment",
        |world, _, _| {
            let found = entry(world, "Gemini");
            expect!(
                at(&found, "account.canSignIn") != &json!(true),
                "the second sign-in to stay busy; Gemini is {}",
                show(&found)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is asked to finish signing in in the browser",
        |world, _, _| {
            wait_for_entry(
                world,
                "Gemini",
                |_, found| {
                    at(found, "account.description") == &json!("Finish signing in in your browser.")
                        && at(found, "account.url") == &json!(SIGN_IN_URL)
                        && at(found, "account.canCancel") == &json!(true)
                },
                "to wait on the browser",
            )?;
            Ok(())
        },
    );
    steps.step("the user opens the sign-in page", |world, _, _| {
        dispatch(world, "openSignIn", "Gemini")
    });
    steps.step(
        "the provider's sign-in page opens in the browser",
        |world, _, _| {
            world.wait_for_with(
                |w| w.opened_urls().iter().any(|url| url == SIGN_IN_URL),
                |w| {
                    format!(
                        "{SIGN_IN_URL} to open; opened {}",
                        w.opened_urls().join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("{Q} is waiting for the user to open a sign-in page"),
        |world, c, _| {
            open_panel(world)?;
            offer(world, gemini("authenticated"));
            let mut waiting = gemini("authenticated");
            waiting["auth"]["action"] = json!({
                "elicitationId": "elicit-1",
                "url": URL_AUTH_PAGE,
                "message": "Authorize Gemini to reach your workspace.",
            });
            offer(world, waiting);
            wait_for_entry(
                world,
                &c[0],
                |_, found| at(found, "urlAuth.url") == &json!(URL_AUTH_PAGE),
                "to offer continuing its sign-in page",
            )?;
            Ok(())
        },
    );
    steps.step(
        "the request has expired on the environment",
        |world, _, _| {
            fake(world).url_auth_expired = true;
            Ok(())
        },
    );
    steps.step("the user continues the authentication", |world, _, _| {
        dispatch(world, "continueUrlAuth", "Gemini")
    });
    steps.step(
        "the agent's sign-in page opens in the browser",
        |world, _, _| {
            world.wait_for_with(
                |w| w.opened_urls().iter().any(|url| url == URL_AUTH_PAGE),
                |w| {
                    format!(
                        "{URL_AUTH_PAGE} to open; opened {}",
                        w.opened_urls().join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the environment tells {Q} the page was opened"),
        |world, _, _| {
            world.wait_for_with(
                |w| recorded(w).url_auth_accepts == ["gemini/elicit-1"],
                |w| {
                    format!(
                        "the page to be accepted once; accepted {}",
                        recorded(w).url_auth_accepts.join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        "the user is told the authentication request expired",
        |world, _, _| {
            expect_toast(
                world,
                "Authentication request expired",
                "Refresh the provider and start the authentication flow again.",
            )
        },
    );
    steps.step("the user cancels the sign-in", |world, _, _| {
        wait_for_entry(
            world,
            "Gemini",
            |_, found| at(found, "account.canCancel") == &json!(true),
            "to offer cancelling",
        )?;
        dispatch(world, "cancelSignIn", "Gemini")
    });
    steps.step(
        "the sign-in is cancelled on the environment",
        |world, _, _| {
            world.wait_for_with(
                |w| recorded(w).cancels == ["flow-1"],
                |w| {
                    format!(
                        "the flow to be cancelled; cancelled {}",
                        recorded(w).cancels.join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user can retry signing in to {Q}"),
        |world, c, _| {
            wait_for_entry(
                world,
                &c[0],
                |_, found| {
                    at(found, "account.canSignIn") == &json!(true)
                        && at(found, "account.signInLabel") == &json!("Retry sign-in")
                },
                "to offer another sign-in",
            )?;
            Ok(())
        },
    );
    steps.step(&format!("the sign-in fails with {Q}"), |world, c, _| {
        wait_for_entry(
            world,
            "Gemini",
            |_, found| at(found, "account.canCancel") == &json!(true),
            "to be signing in",
        )?;
        send_auth(
            &mut world.mc,
            "gemini",
            json!({"phase": "failed", "flowId": "flow-1", "message": c[0]}),
        );
        Ok(())
    });
    steps.step(
        &format!("the user is told why the sign-in failed: {Q}"),
        |world, c, _| {
            wait_for_entry(
                world,
                "Gemini",
                |_, found| at(found, "account.error") == &json!(c[0]),
                &format!("to say {}", c[0]),
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} offers the sign-in methods {Q} and {Q}"),
        |world, c, _| {
            open_panel(world)?;
            fake(world).auth.insert(
                "gemini".into(),
                auth_state(
                    "gemini",
                    json!({"methods": [sign_in_method(&c[1]), sign_in_method(&c[2])]}),
                ),
            );
            offer(world, gemini("unauthenticated"));
            wait_for_entry(
                world,
                &c[0],
                |_, found| {
                    at(found, "account.canSignIn") == &json!(true)
                        && at(found, "account.methods").as_array().map(Vec::len) == Some(2)
                },
                "to offer two sign-in methods",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the user chooses {Q} and signs in to {Q}"),
        |world, c, _| {
            let found = entry(world, &c[1]);
            let method_id = at(&found, "account.methods")
                .as_array()
                .into_iter()
                .flatten()
                .find(|method| method["name"] == json!(c[0]))
                .map(|method| text(&method["id"]))
                .unwrap_or_default();
            expect!(
                !method_id.is_empty(),
                "{} to be offered; the panel is {}",
                c[0],
                show(&panel(world))
            );
            act(
                world,
                "signIn",
                json!({"instanceId": "gemini", "methodId": method_id}),
            )
        },
    );
    steps.step(
        &format!("the sign-in starts with the method {Q}"),
        |world, c, _| {
            let id = text(&sign_in_method(&c[0])["id"]);
            world.wait_for_with(
                |w| recorded(w).methods == [id.clone()],
                |w| {
                    format!(
                        "a sign-in with {id}; started with {}",
                        recorded(w).methods.join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the agent's login terminal shows {Q}"),
        |world, c, _| {
            wait_for_entry(
                world,
                "Gemini",
                |_, found| at(found, "account.canCancel") == &json!(true),
                "to be signing in",
            )?;
            send_auth(
                &mut world.mc,
                "gemini",
                json!({
                    "phase": "waiting",
                    "flowId": "flow-1",
                    "interaction": {
                        "id": "terminal",
                        "type": "terminal",
                        "output": c[0],
                        "outputOffset": c[0].chars().count(),
                    },
                }),
            );
            wait_for_entry(
                world,
                "Gemini",
                |_, found| !at(found, "account.terminal").is_null(),
                "to show the login terminal",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the user is asked to complete sign-in in a terminal showing {Q}"),
        |world, c, _| {
            wait_for_entry(
                world,
                "Gemini",
                |_, found| {
                    at(found, "account.description")
                        == &json!("Complete sign-in in the terminal below.")
                        && at(found, "account.terminal.output") == &json!(c[0])
                },
                "to show the login terminal",
            )?;
            Ok(())
        },
    );
    steps.step(
        "the environment no longer has that login terminal",
        |world, _, _| {
            fake(world).terminal_gone = true;
            Ok(())
        },
    );
    steps.step(
        &format!("the user types {Q} in the sign-in terminal"),
        |world, c, _| {
            act(
                world,
                "signInTerminal",
                json!({"instanceId": "gemini", "data": c[0]}),
            )
        },
    );
    steps.step(
        &format!("{Q} reaches the sign-in terminal on the environment"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    recorded(w).responses.iter().any(|response| {
                        let body = &response["response"];
                        response["flowId"] == json!("flow-1")
                            && response["interactionId"] == json!("terminal")
                            && body["type"] == json!("terminal")
                            && body["data"] == json!(c[0])
                    })
                },
                |w| {
                    format!(
                        "{} to reach the terminal; the environment has {} responses",
                        c[0],
                        recorded(w).responses.len()
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the agent asks for the credential {Q}"),
        |world, c, _| {
            wait_for_entry(
                world,
                "Gemini",
                |_, found| at(found, "account.canCancel") == &json!(true),
                "to be signing in",
            )?;
            fake(world).credential = c[0].clone();
            send_auth(
                &mut world.mc,
                "gemini",
                json!({
                    "phase": "waiting",
                    "flowId": "flow-1",
                    "interaction": {
                        "id": "credentials-1",
                        "type": "credentials",
                        "fields": [{"name": c[0], "label": "API key", "secret": true}],
                    },
                }),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user enters {Q} for it and connects"),
        |world, c, _| {
            wait_for_entry(
                world,
                "Gemini",
                |_, found| {
                    at(found, "account.description") == &json!("Enter your credentials below.")
                        && at(found, "account.credentials")
                            .as_array()
                            .is_some_and(|fields| !fields.is_empty())
                },
                "to ask for credentials",
            )?;
            let credential = fake(world).credential.clone();
            act(
                world,
                "signInCredentials",
                json!({"instanceId": "gemini", "values": {credential: c[0]}}),
            )
        },
    );
    steps.step(
        &format!("the environment receives {Q} as {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    recorded(w).responses.iter().any(|response| {
                        let body = &response["response"];
                        response["interactionId"] == json!("credentials-1")
                            && body["type"] == json!("credentials")
                            && body["values"] == json!({c[1].clone(): c[0].clone()})
                    })
                },
                |w| {
                    format!(
                        "the credential to be sent; the environment has {} responses",
                        recorded(w).responses.len()
                    )
                },
            )
        },
    );
    steps.step("the sign-in returns to a local address", |world, _, _| {
        wait_for_entry(
            world,
            "Gemini",
            |_, found| at(found, "account.canCancel") == &json!(true),
            "to be signing in",
        )?;
        send_auth(
            &mut world.mc,
            "gemini",
            json!({
                "phase": "waiting",
                "flowId": "flow-1",
                "interaction": {
                    "id": "browser-1",
                    "type": "browser",
                    "url": SIGN_IN_URL,
                    "requiresConsent": false,
                    "acceptsCallback": true,
                },
            }),
        );
        wait_for_entry(
            world,
            "Gemini",
            |_, found| at(found, "account.acceptsCallback") == &json!(true),
            "to accept a pasted address",
        )?;
        Ok(())
    });
    steps.step(
        &format!("the user pastes {Q} as the final sign-in address"),
        |world, c, _| {
            act(
                world,
                "signInCallback",
                json!({"instanceId": "gemini", "url": c[0]}),
            )
        },
    );
    steps.step(
        &format!("the environment finishes the sign-in with {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let completes = &recorded(w).completes;
                    completes.len() == 1
                        && completes[0]["callbackUrl"] == json!(c[0])
                        && completes[0]["flowId"] == json!("flow-1")
                },
                |w| {
                    format!(
                        "the sign-in to be finished with {}; it was finished {} times",
                        c[0],
                        recorded(w).completes.len()
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user signs out of {Q} and declines"),
        |world, c, _| {
            dispatch(world, "signOut", &c[0])?;
            answer(world, false)
        },
    );
    steps.step("the user signs out and confirms", |world, _, _| {
        dispatch(world, "signOut", "Gemini")?;
        answer(world, true)
    });
    steps.step(&format!("{Q} is still signed in"), |world, c, _| {
        world.sync()?;
        let found = entry(world, &c[0]);
        expect!(
            fake(world).logouts.is_empty() && at(&found, "account.canSignOut") == &json!(true),
            "{} to stay signed in; signed out {}, the panel is {}",
            c[0],
            fake(world).logouts.join(", "),
            show(&panel(world))
        );
        Ok(())
    });
    // The MC stops the threads that share the sign-in as it signs out.
    steps.step(
        "running threads sharing that sign-in stop",
        |world, _, _| {
            world.wait_for_with(
                |w| recorded(w).logouts == ["gemini"],
                |w| {
                    format!(
                        "Gemini to be signed out; signed out {}",
                        recorded(w).logouts.join(", ")
                    )
                },
            )
        },
    );
    steps.step("thread history is kept", |world, _, _| {
        world.sync()?;
        for command in &world.mc.commands {
            expect!(
                !text(&command["type"]).contains("delete"),
                "no thread to be deleted; the MC has {}",
                world.describe_commands()
            );
        }
        Ok(())
    });

    // The health check interval. The environment starts on the "performance"
    // preset (a minute), so each interval below is a change.
    steps.step(
        "the user sets the provider health check interval to (\\d+) seconds",
        |world, c, _| {
            save_elsewhere(
                &mut world.mc,
                "backgroundActivity",
                json!({"schemaVersion": 1, "profile": "performance"}),
                false,
            );
            world.wait_for_with(
                |w| at(&panel(w), "health.seconds") == &json!(60),
                |w| {
                    format!(
                        "the interval to show a minute; the panel is {}",
                        show(&panel(w))
                    )
                },
            )?;
            world.dispatch(
                "providerSettings.healthInterval",
                json!({"seconds": c[0].parse::<i64>().unwrap_or(0)}),
            )
        },
    );
    steps.step(
        "providers are refreshed in the background (every five minutes|never)",
        |world, c, _| {
            let seconds: i64 = if c[0] == "never" { 0 } else { 300 };
            // What the MC reads (HalC2.BackgroundPolicy.settings): a custom
            // profile's override.
            let saved = move |w: &World| {
                let activity =
                    w.mc.peek::<super::settings::FakeConfig>()
                        .map(|config| config.settings.get("backgroundActivity").cloned())
                        .unwrap_or_default()
                        .unwrap_or(Value::Null);
                activity["profile"] == json!("custom")
                    && activity["baseProfile"] == json!("performance")
                    && activity["overrides"]["providerHealthRefreshInterval"].as_i64()
                        == Some(seconds * 1000)
            };
            world.wait_for_with(
                |w| saved(w) && at(&panel(w), "health.seconds") == &json!(seconds),
                |w| {
                    format!(
                        "a {seconds} s interval to be saved; the panel is {}",
                        show(&panel(w))
                    )
                },
            )
        },
    );

    // Updates.
    steps.step(
        &format!("{Q} is behind its latest release"),
        |world, c, _| {
            offer(
                world,
                provider(
                    "codex",
                    "codex",
                    &c[0],
                    json!({
                        "version": "0.50.0",
                        "versionAdvisory": {
                            "status": "behind_latest",
                            "currentVersion": "0.50.0",
                            "latestVersion": "0.51.0",
                            "updateCommand": UPDATE_COMMAND,
                            "canUpdate": true,
                        },
                    }),
                ),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the update command for {Q} cannot be started here"),
        |world, c, _| {
            offer(
                world,
                provider(
                    "codex",
                    "codex",
                    &c[0],
                    json!({
                        "versionAdvisory": {
                            "status": "behind_latest",
                            "latestVersion": "0.51.0",
                            "updateCommand": UPDATE_COMMAND,
                            "canUpdate": false,
                        },
                    }),
                ),
            );
            wait_for_entry(
                world,
                &c[0],
                |_, found| found["canUpdate"] != json!(true),
                "to not update itself",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the installed {Q} is (of limited support|unsupported|known to be broken)(?: for this HAL-C2 release)?"),
        |world, c, _| {
            let status = match c[1].as_str() {
                "of limited support" => "graceful",
                "unsupported" => "unsupported",
                _ => "broken",
            };
            offer(
                world,
                provider(
                    "opencode",
                    "opencode",
                    &c[0],
                    json!({
                        "version": "1.15.0",
                        "compatibilityAdvisory": {
                            "status": status,
                            "recommendedVersion": "1.14.19",
                        },
                    }),
                ),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens the version details of {Q}"),
        |world, c, _| {
            wait_for_entry(
                world,
                &c[0],
                |_, found| found["advisory"].is_object(),
                "to have version details",
            )?;
            Ok(())
        },
    );
    steps.step(
        "the user is told an update is available with the latest version",
        |world, _, _| {
            let advisory = entry(world, "Codex")["advisory"].clone();
            expect!(
                advisory["title"] == json!("Update available")
                    && advisory["detail"] == json!("Install v0.51.0."),
                "the advisory is {}",
                show(&advisory)
            );
            Ok(())
        },
    );
    steps.step(
        "the user can update now or copy the update command",
        |world, _, _| {
            let codex = entry(world, "Codex");
            expect!(
                codex["canUpdate"] == json!(true)
                    && at(&codex, "advisory.updateCommand") == &json!(UPDATE_COMMAND),
                "Codex is {}",
                show(&codex)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is warned {Q} with the version to use for full support"),
        |world, c, _| {
            let advisory = entry(world, "OpenCode")["advisory"].clone();
            expect!(
                advisory["title"] == json!(c[0])
                    && advisory["detail"] == json!("Use v1.14.19 for full support."),
                "the advisory is {}",
                show(&advisory)
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is the recommended version"), |world, c, _| {
        offer(
            world,
            provider(
                "opencode",
                "opencode",
                "OpenCode",
                json!({
                    "version": "1.15.0",
                    "versionAdvisory": {
                        "status": "behind_latest",
                        "latestVersion": "1.16.0",
                        "updateCommand": "npm install -g opencode-ai@latest",
                        "canUpdate": true,
                        "canInstallVersion": true,
                    },
                    "compatibilityAdvisory": {
                        "status": "broken",
                        "message": "OpenCode 1.15.0 is known to break sessions.",
                        "recommendedVersion": c[0],
                    },
                }),
            ),
        );
        Ok(())
    });
    steps.step(
        &format!("the user is offered to install {Q} rather than update to the latest"),
        |world, c, _| {
            let found = wait_for_entry(
                world,
                "OpenCode",
                |_, found| found["installLabel"] == json!(format!("Install {}", c[0])),
                &format!("to offer installing {}", c[0]),
            )?;
            expect!(
                at(&found, "advisory.updateCommand").is_null(),
                "no update to the latest to be offered; OpenCode is {}",
                show(&found)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user installs the recommended version of {Q}"),
        |world, c, _| {
            wait_for_entry(
                world,
                &c[0],
                |_, found| !text(&found["installLabel"]).is_empty(),
                "to offer the recommended version",
            )?;
            dispatch(world, "install", &c[0])
        },
    );
    steps.step(
        &format!("the environment installs {Q} of {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let updates = &recorded(w).updates;
                    updates.len() == 1
                        && updates[0].payload["targetVersion"] == json!(c[0])
                        && updates[0].payload["provider"] == json!(c[1].to_lowercase())
                },
                |w| {
                    format!(
                        "{} {} to be installed; {} updates ran",
                        c[1],
                        c[0],
                        recorded(w).updates.len()
                    )
                },
            )?;
            wait_for_entry(
                world,
                &c[1],
                |_, found| found["updating"] == json!(true),
                "to be shown updating",
            )?;
            Ok(())
        },
    );
    steps.step("the user copies the update command", |world, _, _| {
        dispatch(world, "copyUpdateCommand", "Codex")
    });
    steps.step("the command is on the clipboard", |world, _, _| {
        world.wait_for_with(
            |w| w.clipboard() == UPDATE_COMMAND,
            |w| format!("the clipboard holds \"{}\"", w.clipboard()),
        )
    });
    steps.step(
        "the user is told to run it in a terminal when ready",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    toast_items(w).iter().any(|toast| {
                        toast["description"] == json!("Run it in a terminal when ready.")
                    })
                },
                |w| {
                    format!(
                        "a toast to run it in a terminal; the shell shows {}",
                        show(&w.state("toasts"))
                    )
                },
            )
        },
    );
    steps.step(&format!("the MC reports {Q} updated"), |world, c, _| {
        offer(
            world,
            provider(
                "codex",
                "codex",
                &c[0],
                json!({
                    "version": "0.51.0",
                    "versionAdvisory": {
                        "status": "current",
                        "currentVersion": "0.51.0",
                        "latestVersion": "0.51.0",
                    },
                    "updateState": {"status": "succeeded"},
                }),
            ),
        );
        Ok(())
    });
    steps.step("the Providers settings open", |world, _, _| {
        world.wait_for_with(
            |w| {
                w.with::<Navigation, _>(|n, _| n.route().clone())
                    .is_ok_and(|route| route == Route::Settings(PROVIDERS_SECTION.into()))
            },
            |w| {
                format!(
                    "the Providers settings to open; the window shows {}",
                    show(&w.state("route"))
                )
            },
        )
    });
    steps.step(&format!("updating {Q} fails with {Q}"), |world, c, _| {
        fake(world).update_refusal = c[1].clone();
        Ok(())
    });
    steps.step(&format!("the user updates {Q}"), |world, c, _| {
        wait_for_entry(
            world,
            &c[0],
            |_, found| found["canUpdate"] == json!(true),
            "to offer an update",
        )?;
        dispatch(world, "update", &c[0])
    });
    steps.step(&format!("{Q} is shown updating"), |world, c, _| {
        wait_for_entry(
            world,
            &c[0],
            |w, found| {
                let updates = &recorded(w).updates;
                found["updating"] == json!(true)
                    && updates.len() == 1
                    && updates[0].payload["provider"] == json!("codex")
            },
            "to be updating",
        )?;
        Ok(())
    });
    steps.step("the update finishes", |world, _, _| {
        world.wait_for("an update to have been asked for", |w| {
            !recorded(w).updates.is_empty()
        })?;
        let first = fake(world).updates[0].clone();
        world.mc.reply(&first, json!({}));
        Ok(())
    });
    steps.step(
        &format!("{Q} is no longer shown updating"),
        |world, c, _| {
            wait_for_entry(
                world,
                &c[0],
                |_, found| found["updating"] != json!(true),
                "to be done updating",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the user is told {Q} could not be updated"),
        |world, c, _| {
            let title = format!("Could not update {}", c[0]);
            let refusal = fake(world).update_refusal.clone();
            world.wait_for_with(
                |w| toasted(w, &title, &refusal),
                |w| {
                    format!(
                        "a toast that {} was not updated; the shell shows {}",
                        c[0],
                        show(&w.state("toasts"))
                    )
                },
            )
        },
    );

    // Native sessions.
    steps.step(
        &format!("the agent {Q} has a native session for the project {Q}"),
        |world, c, _| {
            expect!(c[0] == "gemini", "the scenario's agent is gemini");
            acp_session(world, &c[1], false)
        },
    );
    steps.step(
        &format!("the agent {Q} has a native session that was not imported"),
        |world, c, _| {
            expect!(c[0] == "gemini", "the scenario's agent is gemini");
            acp_session(world, "hal-c2", false)
        },
    );
    steps.step(
        "a native session was imported as a thread",
        |world, _, _| acp_session(world, "hal-c2", true),
    );
    steps.step("the user imports that session", |world, _, _| {
        list_sessions(world)?;
        act(
            world,
            "acpImport",
            json!({"instanceId": "gemini", "sessionId": "session-1"}),
        )
    });
    steps.step(
        &format!("a thread continuing the session is created in {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| listed_session(w)["imported"] == json!(true),
                |w| {
                    format!(
                        "the session to show as imported; the section is {}",
                        show(&acp_section(w))
                    )
                },
            )?;
            let imports = fake(world).acp_imports.clone();
            expect!(
                imports.len() == 1
                    && imports[0]["projectId"] == json!(c[0])
                    && imports[0]["sessionId"] == json!("session-1")
                    && imports[0]["title"] == json!("Fix the build"),
                "session-1 to be imported into {}",
                c[0]
            );
            expect_toast(world, "ACP session imported", "")
        },
    );
    steps.step("the user deletes the native session", |world, _, _| {
        list_sessions(world)?;
        act(
            world,
            "acpDelete",
            json!({"instanceId": "gemini", "sessionId": "session-1"}),
        )
    });
    steps.step(
        "the user is told to delete the imported thread first",
        |world, _, _| {
            expect_toast(
                world,
                "Could not delete ACP session",
                "Delete the imported HAL-C2 thread before deleting its native ACP session.",
            )?;
            expect!(
                fake(world).acp_deletes.is_empty() && !is_empty(&listed_session(world)),
                "the session to be kept"
            );
            Ok(())
        },
    );
    steps.step("the user deletes it and confirms", |world, _, _| {
        list_sessions(world)?;
        act(
            world,
            "acpDelete",
            json!({"instanceId": "gemini", "sessionId": "session-1"}),
        )?;
        answer(world, true)
    });
    steps.step("the session is deleted by the agent", |world, _, _| {
        world.wait_for_with(
            |w| recorded(w).acp_deletes == ["session-1"] && is_empty(&listed_session(w)),
            |w| {
                format!(
                    "session-1 to be deleted; the section is {}",
                    show(&acp_section(w))
                )
            },
        )?;
        expect_toast(world, "ACP session deleted", "")
    });

    // Model providers.
    steps.step(
        &format!("the user sets the agent's model provider to {Q} with an authorization header"),
        |world, c, _| {
            list_acp_providers(world)?;
            set_acp_provider(world, &c[0], r#"{"Authorization": "Bearer token"}"#)
        },
    );
    steps.step("the agent uses that base URL", |world, _, _| {
        world.wait_for_with(
            |w| acp_provider(w)["configured"] == json!(true),
            |w| {
                format!(
                    "openai to be configured; the section is {}",
                    show(&acp_section(w))
                )
            },
        )?;
        let set = fake(world).acp_sets.first().cloned().unwrap_or(Value::Null);
        expect!(
            acp_provider(world)["baseUrl"] == set["baseUrl"]
                && set["headers"]["Authorization"] == json!("Bearer token"),
            "the base URL and header to be sent; sent {}",
            show(&set)
        );
        expect_toast(world, "ACP provider configured", "")
    });
    steps.step("the user disables that model provider", |world, _, _| {
        act(
            world,
            "acpDisableProvider",
            json!({"instanceId": "gemini", "providerId": "openai"}),
        )?;
        answer(world, true)
    });
    steps.step("the agent no longer uses it", |world, _, _| {
        world.wait_for_with(
            |w| {
                recorded(w).acp_disables == ["openai"]
                    && !is_empty(&acp_provider(w))
                    && acp_provider(w)["configured"] != json!(true)
            },
            |w| {
                format!(
                    "openai to be disabled; the section is {}",
                    show(&acp_section(w))
                )
            },
        )?;
        expect_toast(world, "ACP provider disabled", "")
    });
    // The headers may hold quotes of their own.
    steps.step("the user saves the headers \"(.*)\"", |world, c, _| {
        list_acp_providers(world)?;
        set_acp_provider(world, "https://api.example.com", &c[0])?;
        expect!(fake(world).acp_sets.is_empty(), "nothing to be sent");
        Ok(())
    });

    // Signing out.
    steps.step(
        &format!("the user logs out of the agent {Q}"),
        |world, c, _| {
            expect!(c[0] == "gemini", "the scenario's agent is gemini");
            open_panel(world)?;
            offer(world, acp_agent("authenticated"));
            world.wait_for_with(
                |w| acp_section(w)["canLogout"] == json!(true),
                |w| {
                    format!(
                        "Gemini to offer logging out; the card is {}",
                        show(&entry(w, "Gemini"))
                    )
                },
            )?;
            act(world, "acpLogout", json!({"instanceId": "gemini"}))
        },
    );
    steps.step(
        "the agent is signed out and its status is read again",
        |world, _, _| {
            expect_toast(world, "Logged out of ACP agent", "")?;
            expect!(
                fake(world).acp_logouts == ["gemini"],
                "gemini to be logged out"
            );
            // The MC reads the agent's status again and lists it signed out.
            let before = text(&entry(world, "Gemini")["headline"]);
            offer(world, acp_agent("unauthenticated"));
            world.wait_for_with(
                |w| text(&entry(w, "Gemini")["headline"]) != before,
                |w| {
                    format!(
                        "Gemini to show signed out; the card is {}",
                        show(&entry(w, "Gemini"))
                    )
                },
            )
        },
    );

    // Custom models.
    steps.step(
        &format!(
            "the user adds the custom model {Q} with a reasoning option offering (\\w+) and (\\w+)"
        ),
        |world, c, _| {
            expect!(c[0] == CUSTOM_MODEL, "the scenario adds my-model");
            add_custom_model(world)?;
            draft_options(
                world,
                json!([editor_option(
                    "reasoningEffort",
                    "Reasoning",
                    vec![editor_choice(&c[1]), editor_choice(&c[2])]
                )]),
            )?;
            save_custom_model(world)?;
            world.wait_for_with(
                |w| {
                    let saved = saved_models(w);
                    saved.len() == 1 && saved[0].get("capabilities").is_some()
                },
                |w| {
                    format!(
                        "my-model to be saved with its option; Codex holds {}",
                        show(&Value::Array(saved_models(w)))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("{Q} is offered in the model picker"),
        |world, c, _| {
            if super::provider_list::expect_model_offered(world, &c[0])? {
                return Ok(());
            }
            choose_custom_model(world)
        },
    );
    steps.step(
        "the composer offers (\\w+) and (\\w+) reasoning for it",
        |world, c, _| {
            let choices = reasoning_choices(world);
            expect!(
                choices == [c[0].clone(), c[1].clone()],
                "the composer offers {}",
                choices.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "the user adds a custom model and copies the options of a built-in model",
        |world, _, _| {
            add_custom_model(world)?;
            act(
                world,
                "modelDraft",
                json!({"instanceId": "codex", "copyFrom": "gpt-5"}),
            )
        },
    );
    steps.step(
        "the custom model starts with the same options",
        |world, _, _| {
            let found = wait_for_entry(
                world,
                "Codex",
                |_, found| {
                    found["modelDraft"]["options"]
                        .as_array()
                        .is_some_and(|options| !options.is_empty())
                },
                "to hold GPT-5's options in the draft",
            )?;
            let copied = found["modelDraft"].clone();
            let options = copied["options"].as_array().cloned().unwrap_or_default();
            let mut choices = Vec::new();
            let mut chosen = String::new();
            for choice in options
                .first()
                .and_then(|option| option["choices"].as_array())
                .into_iter()
                .flatten()
            {
                choices.push(text(&choice["id"]));
                if choice["isDefault"] == json!(true) {
                    chosen = text(&choice["id"]);
                }
            }
            expect!(
                options.len() == 1
                    && options[0]["id"] == json!("reasoningEffort")
                    && choices == ["low", "medium", "high"]
                    && chosen == "medium",
                "the draft starts with {}",
                show(&copied)
            );
            // Saved, it is the built-in model's option.
            save_custom_model(world)?;
            world.wait_for_with(
                |w| {
                    let saved = saved_models(w);
                    let descriptors = saved
                        .first()
                        .and_then(|model| model["capabilities"]["optionDescriptors"].as_array())
                        .cloned()
                        .unwrap_or_default();
                    descriptors.len() == 1
                        && descriptors[0]["options"].as_array().map(Vec::len) == Some(3)
                        && descriptors[0]["currentValue"] == json!("medium")
                },
                |w| {
                    format!(
                        "my-model to be saved with GPT-5's options; Codex holds {}",
                        show(&Value::Array(saved_models(w)))
                    )
                },
            )
        },
    );
    steps.step("the user saves a custom option with (.+)", |world, c, _| {
        add_custom_model(world)?;
        let low = vec![editor_choice("low")];
        let option = match c[0].as_str() {
            "no id" => editor_option("", "Reasoning", low),
            "no label" => editor_option("reasoningEffort", "", low),
            "a choice list with no choices" => {
                editor_option("reasoningEffort", "Reasoning", Vec::new())
            }
            "the same choice twice" => editor_option(
                "reasoningEffort",
                "Reasoning",
                vec![editor_choice("low"), editor_choice("low")],
            ),
            other => fail!("a known problem, not {other}"),
        };
        fake(world).writes_before = fake_config(&mut world.mc).writes.len();
        draft_options(world, json!([option]))?;
        save_custom_model(world)
    });
    steps.step("the user is told the option (.+)", |world, c, _| {
        let message = match c[0].as_str() {
            "needs an id" => "Option 1 needs an id.",
            "needs a label" => "Option 1 needs a label.",
            "needs at least one choice" => "Option 1 needs at least one choice.",
            "uses a choice twice" => "Option 1: choice \"low\" is used twice.",
            other => fail!("a known message, not {other}"),
        };
        let shown = wait_for_entry(
            world,
            "Codex",
            |_, found| found["modelError"] == json!(message),
            &format!("to say the option {}", c[0]),
        )?;
        // Nothing is saved, and the option stays open to fix.
        let writes = fake_config(&mut world.mc).writes.len();
        expect!(
            writes == fake(world).writes_before
                && shown["modelDraft"]["slug"] == json!(CUSTOM_MODEL),
            "the draft to stay unsaved; the entry is {}",
            show(&shown)
        );
        Ok(())
    });
    steps.step(
        "the user adds a custom model with no options",
        |world, _, _| {
            add_custom_model(world)?;
            save_custom_model(world)?;
            world.wait_for_with(
                |w| {
                    saved_models(w) == [json!(CUSTOM_MODEL)]
                        && entry(w, "Codex")["modelDraft"].is_null()
                },
                |w| {
                    format!(
                        "my-model to be saved as its slug alone; Codex holds {}",
                        show(&Value::Array(saved_models(w)))
                    )
                },
            )
        },
    );
    steps.step(
        "the composer uses the provider's default options for it",
        |world, _, _| {
            choose_custom_model(world)?;
            let choices = reasoning_choices(world);
            expect!(
                choices == ["low", "medium", "high"],
                "the composer offers Codex's reasoning for my-model; it offers {}",
                choices.join(", ")
            );
            Ok(())
        },
    );

    // A custom model's id, checked as it is added
    // (ProviderCustomModels::refusal).
    steps.step(
        &format!("Claude already has the custom model {Q}"),
        |world, c, _| {
            let listing = provider(
                "claudeAgent",
                "claudeAgent",
                "Claude",
                json!({"models": [{"slug": "claude-fable-5-1", "name": "Claude Fable 5.1"}]}),
            );
            seed_instance(
                world,
                "claudeAgent",
                json!({
                    "driver": "claudeAgent",
                    "enabled": true,
                    "config": {"customModels": [c[0]]},
                }),
                listing,
            )?;
            wait_for_entry(
                world,
                "Claude",
                |_, found| {
                    found["customModels"]
                        .as_array()
                        .is_some_and(|models| models.len() == 1 && models[0]["slug"] == json!(c[0]))
                },
                "to list its custom model",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the user adds the custom model {Q} to Claude"),
        |world, c, _| {
            fake(world).writes_before = fake_config(&mut world.mc).writes.len();
            // What the page says beside the field.
            world.told_in_place = Some(Rc::new(|w: &World| {
                vec![text(&entry(w, "Claude")["modelError"])]
            }));
            act(
                world,
                "addModel",
                json!({"instanceId": "claudeAgent", "slug": c[0]}),
            )?;
            world.sync()
        },
    );
    steps.step("nothing is saved", |world, _, _| {
        world.sync()?;
        let saved = saved_instance(world, "claudeAgent")["config"]["customModels"].clone();
        let writes = fake_config(&mut world.mc).writes.len();
        let before = fake(world).writes_before;
        expect!(
            writes == before && saved == json!(["my-model"]),
            "Claude holds {} after {} writes",
            show(&saved),
            writes - before.min(writes)
        );
        Ok(())
    });

    // The signed-in account's email on a provider's card, as
    // ProvidersSettings.qml draws it.
    steps.step(&format!("{Q} is signed in as {Q}"), |world, c, _| {
        seed_instance(
            world,
            "claudeAgent_work",
            json!({"driver": "claudeAgent", "displayName": c[0], "enabled": true}),
            provider(
                "claudeAgent_work",
                "claudeAgent",
                &c[0],
                json!({"auth": {"status": "authenticated", "email": c[1]}}),
            ),
        )?;
        wait_for_entry(
            world,
            &c[0],
            |_, found| found["email"] == json!(c[1]),
            "to be signed in",
        )?;
        // AlertSteps' "<text> is shown", on this page.
        world.on_settings_page.insert(
            "isShown".into(),
            Rc::new(|world: &mut World, shown: &Vec<String>| {
                let said = email(world)?;
                expect!(
                    said == shown.first().cloned().unwrap_or_default(),
                    "the card shows \"{said}\""
                );
                Ok(())
            }),
        );
        Ok(())
    });
    steps.step("the account email is shown scrambled", |world, _, _| {
        scrambled(world)
    });
    steps.step("the user reveals the email", |world, _, _| {
        email(world)?;
        shown(world)?.click(world, "email")
    });
    steps.step("the user hides it again", |world, _, _| {
        email(world)?;
        shown(world)?.click(world, "email")
    });
    steps.step("it is scrambled again", |world, _, _| scrambled(world));

    // The wizard's ACP Registry step.
    steps.step(
        &format!("the user searches the ACP Registry for {Q}"),
        |world, c, _| search_registry(world, &c[0]),
    );
    steps.step(
        "the user is told no compatible agents were found and to try a broader search",
        |world, _, _| {
            // The pane shows "No compatible agents found" / "Try a broader search." for an empty answer.
            let shown = registry(world);
            expect!(
                shown["agents"].as_array().is_some_and(Vec::is_empty)
                    && text(&shown["error"]).is_empty(),
                "an empty answer; the registry is {}",
                show(&shown)
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is already configured"), |world, c, _| {
        let instance = json!({
            "driver": "acpRegistry",
            "displayName": "Gemini",
            "config": {"agentId": c[0]},
        });
        let listed = provider("acpRegistry_gemini", "acpRegistry", "Gemini", Value::Null);
        seed_instance(world, "acpRegistry_gemini", instance, listed)
    });
    steps.step(&format!("{Q} is marked as already added"), |world, c, _| {
        let agent = registry_agent(world, &c[0]);
        let other = registry_agent(world, "gemini-lite");
        expect!(
            agent["added"] == json!(true) && !other.is_null() && other["added"] != json!(true),
            "{} alone to be marked added; the registry is {}",
            c[0],
            show(&registry(world))
        );
        // Adding it again does nothing.
        act(world, "registryAdd", json!({"agentId": c[0]}))?;
        expect!(
            fake(world).prepares.is_empty(),
            "no agent to be prepared again"
        );
        Ok(())
    });
    steps.step(
        "the user moves on without choosing an agent",
        |world, _, _| {
            search_registry(world, "")?;
            act(world, "registryManual", json!({"manual": true}))?;
            act(world, "registryManual", json!({"manual": false}))?;
            act(world, "wizardStep", json!({"step": 1}))
        },
    );
    steps.step(
        "the user is asked to select an ACP or configure one manually",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    wizard(w)["step"] == json!(0)
                        && registry(w)["selectionError"]
                            == json!("Select an ACP or configure one manually.")
                },
                |w| {
                    format!(
                        "the selection to be asked for; the wizard is {}",
                        show(&wizard(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user chooses {Q} from the ACP Registry"),
        |world, c, _| {
            search_registry(world, "")?;
            act(world, "registryAdd", json!({"agentId": c[0]}))?;
            world.wait_for_with(
                |w| wizard(w)["step"] == json!(1),
                |w| format!("the identity step; the wizard is {}", show(&wizard(w))),
            )?;
            expect!(
                fake(world).prepares == vec![c[0].clone()],
                "{} to be prepared; prepared {}",
                c[0],
                fake(world).prepares.join(", ")
            );
            fake(world).suggested_id = text(&wizard(world)["instanceId"]);
            act(world, "wizardSubmit", json!({}))
        },
    );
    // A prepare answered after the wizard that asked for it was closed.
    steps.step(
        &format!("the user chose {Q} from the ACP Registry and it is still being prepared"),
        |world, c, _| {
            fake(world).hold_prepares = true;
            search_registry(world, "")?;
            act(world, "registryAdd", json!({"agentId": c[0]}))?;
            world.wait_for("the agent to be prepared", |w| {
                w.mc.peek::<FakeProviders>()
                    .is_some_and(|fake| fake.held_prepares.len() == 1)
            })
        },
    );
    steps.step(
        "the user closes the wizard and opens it again",
        |world, _, _| {
            act(world, "wizardClose", json!({}))?;
            world.wait_for_with(wizard_closed, |w| {
                format!("the wizard to close; it is {}", show(&wizard(w)))
            })?;
            search_registry(world, "")
        },
    );
    steps.step("the agent finishes preparing", |world, _, _| {
        let rpc = fake(world).held_prepares.remove(0);
        let agent_id = text(&rpc.payload["agentId"]);
        world.mc.reply(
            &rpc,
            json!({
                "agentId": agent_id,
                "version": "1.2.3",
                "distribution": "npx",
                "prepared": true,
            }),
        );
        world.sync()
    });
    steps.step(
        "the new wizard still asks which agent to add",
        |world, _, _| {
            let shown = wizard(world);
            let selected = registry(world)["selected"].clone();
            expect!(
                shown["step"] == json!(0)
                    && (selected.is_null() || selected.as_object().is_some_and(|o| o.is_empty()))
                    && registry(world)["busy"] != json!(true)
                    && shown["driver"] != json!("acpRegistry"),
                "the new wizard to be untouched; it is {}",
                show(&shown)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the new instance is named {Q} and runs {Q}"),
        |world, c, _| {
            let id = fake(world).suggested_id.clone();
            world.wait_for_with(
                |w| saved_instance_peek(w, &id).is_some(),
                |w| format!("{id} to be saved; the wizard is {}", show(&wizard(w))),
            )?;
            let saved = saved_instance(world, &id);
            let config = &saved["config"];
            expect!(
                saved["driver"] == json!("acpRegistry")
                    && saved["displayName"] == json!(c[0])
                    && config["agentId"] == json!(c[1])
                    && config["distribution"] == json!("auto")
                    && config["registryIconUrl"]
                        == json!(format!("https://cdn.agentclientprotocol.com/{}.svg", c[1])),
                "{} running {}; saved {}",
                c[0],
                c[1],
                show(&saved)
            );
            world.wait_for_with(wizard_closed, |w| {
                format!("the wizard to close; it is {}", show(&wizard(w)))
            })
        },
    );

    // A registry agent's row in the wizard, as ProvidersSettings.qml draws it.
    steps.step(
        "each agent shows its icon and description",
        |world, _, _| {
            let agents = registry(world)["agents"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            expect!(
                agents.len() == 2,
                "the registry is {}",
                show(&registry(world))
            );
            let brick = pane(world, 1200.0)?;
            for agent in &agents {
                let id = text(&agent["id"]);
                let row = brick.item(world, &format!("registryAgent_{id}"))?;
                let url = format!("https://cdn.agentclientprotocol.com/{id}.svg");
                let icon = descendants(world, row).into_iter().find(|item| {
                    let source = world.engine().read_by_name(*item, "source");
                    !matches!(source, JsValue::Undefined)
                        && world.engine().to_js_string(&source).to_string() == url
                });
                expect!(
                    icon.is_some_and(|icon| brick.flag(world, icon, "visible")),
                    "{id} shows no icon"
                );
                expect!(
                    brick.shows(world, &text(&agent["description"]))?,
                    "{id} shows no description"
                );
            }
            Ok(())
        },
    );
    steps.step(
        "an agent with a website or repository links to it as \"About <agent>\"",
        |world, _, _| {
            let links = [
                ("gemini-cli", "https://geminicli.com", "Gemini CLI"),
                (
                    "gemini-lite",
                    "https://github.com/example/gemini-lite",
                    "Gemini Lite",
                ),
            ];
            let brick = pane(world, 1200.0)?;
            for (id, url, name) in links {
                let row = brick.item(world, &format!("registryAgent_{id}"))?;
                let about = brick.find_in(world, row, "registryAbout")?;
                let visible = about.is_some_and(|about| {
                    brick.flag(world, about, "visible")
                        && brick.text_of(world, about, "text") == format!("About {name}")
                });
                expect!(visible, "{id} has no About link");
                let before = world.opened_urls().len();
                let about = about
                    .ok_or_else(|| crate::harness::Failure(format!("{id} has no About link")))?;
                let (x, y) = brick.at(world, about, 0.5, 0.5)?;
                world.click_at(x, y)?;
                let opened = world.opened_urls()[before..].to_vec();
                expect!(opened == [url], "{id} opened {}", opened.join(", "));
            }
            // One with neither offers no link.
            search_registry(world, "goose")?;
            let brick = pane(world, 1200.0)?;
            let row = brick.item(world, "registryAgent_goose")?;
            let about = brick.find_in(world, row, "registryAbout")?;
            expect!(
                about.is_some_and(|about| !brick.flag(world, about, "visible")),
                "Goose links somewhere"
            );
            Ok(())
        },
    );

    // The models list of a provider's card.
    steps.step(
        "Claude reports a model with fast mode, thinking and reasoning options",
        |world, _, _| {
            let mut effort = reasoning();
            effort["id"] = json!("effort");
            let models = json!([
                {
                    "slug": "claude-opus",
                    "name": "Claude Opus",
                    "capabilities": {"optionDescriptors": [
                        boolean_option("fastMode", "Fast Mode"),
                        boolean_option("thinking", "Thinking"),
                        effort,
                    ]},
                },
                // One that can do none of it, to tell them apart.
                {"slug": "claude-haiku", "name": "Claude Haiku"},
            ]);
            seed_instance(
                world,
                "claudeAgent",
                json!({"driver": "claudeAgent", "enabled": true}),
                provider(
                    "claudeAgent",
                    "claudeAgent",
                    "Claude",
                    json!({"models": models}),
                ),
            )
        },
    );
    steps.step("the user opens (Claude|Codex)'s models", |world, c, _| {
        wait_for_entry(
            world,
            &c[0],
            |_, found| found["models"].as_array().is_some_and(|m| !m.is_empty()),
            "to list its models",
        )?;
        Ok(())
    });
    steps.step(
        &format!("that model is labelled {Q}, {Q} and {Q}"),
        |world, c, _| {
            let models = entry(world, "Claude")["models"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let labels = |index: usize| -> Vec<String> {
                models
                    .get(index)
                    .and_then(|model| model["labels"].as_array())
                    .into_iter()
                    .flatten()
                    .map(text)
                    .collect()
            };
            expect!(
                models.len() == 2
                    && labels(0) == [c[0].clone(), c[1].clone(), c[2].clone()]
                    && labels(1).is_empty(),
                "Claude lists {}",
                show(&Value::Array(models.clone()))
            );
            Ok(())
        },
    );
    steps.step(
        "Codex reports twelve models, two of them favourites and one hidden",
        |world, _, _| {
            let models: Vec<Value> = (1..=12)
                .map(|index| {
                    // Three minis: two by name, one by id alone.
                    let slug = match index {
                        1 | 2 => format!("gpt-5-mini-{index}"),
                        3 => "o4-mini".to_owned(),
                        _ => format!("gpt-5-{index}"),
                    };
                    let name = if index == 3 {
                        "O4 Small".to_owned()
                    } else {
                        slug.to_uppercase()
                    };
                    json!({"slug": slug, "name": name})
                })
                .collect();
            let engine = world.engine();
            let device = Settings::of(engine);
            device.write_device(
                engine,
                "favorites",
                json!([
                    {"provider": "codex", "model": "gpt-5-4"},
                    {"provider": "codex", "model": "gpt-5-5"},
                    // Another instance's favourite is not counted here.
                    {"provider": "claudeAgent", "model": "gpt-5-6"},
                ]),
            );
            device.write_device(
                engine,
                "providerModelPreferences",
                json!({"codex": {"hiddenModels": ["gpt-5-12"]}}),
            );
            seed_instance(
                world,
                "codex",
                json!({"driver": "codex", "enabled": true}),
                provider("codex", "codex", "Codex", json!({"models": models})),
            )
        },
    );
    steps.step(&format!("the list says {Q}"), |world, c, _| {
        let found = entry(world, "Codex");
        let count = found["models"].as_array().map_or(0, Vec::len);
        expect!(
            found["modelSummary"] == json!(c[0]) && count == 12,
            "the list says \"{}\" over {count} models",
            text(&found["modelSummary"])
        );
        Ok(())
    });
    steps.step(
        &format!("the user filters the models by {Q}"),
        |world, c, _| {
            act(
                world,
                "filterModels",
                json!({"instanceId": "codex", "query": c[0]}),
            )
        },
    );
    steps.step(
        &format!("only models whose name or id has {Q} are listed"),
        |world, c, _| {
            let found = entry(world, "Codex");
            let slugs: Vec<String> = found["models"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|model| text(&model["slug"]))
                .collect();
            expect!(
                slugs == ["gpt-5-mini-1", "gpt-5-mini-2", "o4-mini"] && c[0] == "mini",
                "Codex lists {}",
                slugs.join(", ")
            );
            // The count is still of every model.
            expect!(
                text(&found["modelSummary"]).starts_with("12 models"),
                "the list says \"{}\"",
                text(&found["modelSummary"])
            );
            Ok(())
        },
    );
}

const CUSTOM_MODEL: &str = "my-model";

fn saved_instance_peek(world: &World, instance_id: &str) -> Option<Value> {
    let config = world.mc.peek::<super::settings::FakeConfig>()?;
    config
        .settings
        .get("providerInstances")?
        .get(instance_id)
        .cloned()
}

/// The secret stored under `key` ("<instance>/<variable>").
fn secret_peek(world: &World, key: &str) -> Option<String> {
    world
        .mc
        .peek::<super::settings::FakeConfig>()?
        .secrets
        .get(key)
        .cloned()
}

/// The name the model picker lists `instance_id` under.
fn listed_name(world: &World, instance_id: &str) -> Option<String> {
    let shown = picker_instance(world, instance_id);
    shown
        .get("displayName")
        .map(text)
        .filter(|name| !name.is_empty())
}

/// Codex's instance's saved custom models, as its settings hold them.
fn saved_models(world: &World) -> Vec<Value> {
    saved_instance_peek(world, "codex")
        .and_then(|saved| saved["config"]["customModels"].as_array().cloned())
        .unwrap_or_default()
}

/// Codex, whose built-in model offers reasoning.
fn reasoning() -> Value {
    let choices: Vec<Value> = ["low", "medium", "high"]
        .iter()
        .map(|level| json!({"id": level, "label": level, "isDefault": *level == "medium"}))
        .collect();
    json!({"id": "reasoningEffort", "label": "Reasoning", "type": "select", "options": choices})
}

fn boolean_option(id: &str, label: &str) -> Value {
    json!({"id": id, "label": label, "type": "boolean"})
}

fn codex_listing() -> Value {
    provider(
        "codex",
        "codex",
        "Codex",
        json!({"models": [{
            "slug": "gpt-5",
            "name": "GPT-5",
            "capabilities": {"optionDescriptors": [reasoning()]},
        }]}),
    )
}

/// Codex lists its saved custom models after its own, as the MC does
/// (HalC2.Environment's with_custom_models): one without options of its own
/// takes Codex's first model's.
fn list_custom_models(world: &mut World) {
    let mut listing = codex_listing();
    let mut models = listing["models"].as_array().cloned().unwrap_or_default();
    let fallback = models[0]["capabilities"].clone();
    for saved in saved_models(world) {
        let setting = if saved.is_string() {
            json!({"slug": saved})
        } else {
            saved
        };
        let slug = text(&setting["slug"]);
        let name = setting
            .get("name")
            .map_or_else(|| slug.clone(), text);
        models.push(json!({
            "slug": slug,
            "name": name,
            "isCustom": true,
            "capabilities": setting.get("capabilities").cloned().unwrap_or(fallback.clone()),
        }));
    }
    listing["models"] = Value::Array(models);
    offer(world, listing);
}

/// Adds `my-model` to Codex and opens it to edit its options.
fn add_custom_model(world: &mut World) -> Outcome {
    seed_instance(
        world,
        "codex",
        json!({"driver": "codex", "enabled": true}),
        codex_listing(),
    )?;
    act(
        world,
        "addModel",
        json!({"instanceId": "codex", "slug": CUSTOM_MODEL}),
    )?;
    wait_for_entry(
        world,
        "Codex",
        |_, found| {
            found["customModels"]
                .as_array()
                .is_some_and(|models| models.len() == 1 && models[0]["slug"] == json!(CUSTOM_MODEL))
        },
        "to list my-model among its custom models",
    )?;
    act(
        world,
        "editModel",
        json!({"instanceId": "codex", "slug": CUSTOM_MODEL}),
    )?;
    wait_for_entry(
        world,
        "Codex",
        |_, found| found["modelDraft"]["slug"] == json!(CUSTOM_MODEL),
        "to edit my-model",
    )?;
    Ok(())
}

fn editor_choice(id: &str) -> Value {
    json!({"id": id, "label": id, "isDefault": false})
}

fn editor_option(id: &str, label: &str, choices: Vec<Value>) -> Value {
    json!({"id": id, "label": label, "type": "select", "choices": choices})
}

fn draft_options(world: &mut World, options: Value) -> Outcome {
    act(
        world,
        "modelDraft",
        json!({"instanceId": "codex", "options": options}),
    )
}

fn save_custom_model(world: &mut World) -> Outcome {
    act(
        world,
        "saveModel",
        json!({"instanceId": "codex", "slug": CUSTOM_MODEL}),
    )
}

/// A thread on Codex with `my-model` chosen, once the MC lists it.
fn choose_custom_model(world: &mut World) -> Outcome {
    list_custom_models(world);
    let project = json!({
        "id": PROJECT, "title": PROJECT,
        "workspaceRoot": "/work/shop", "scripts": [],
    });
    world.mc.projects.insert(PROJECT.into(), project);
    look_at_thread(world, PROJECT)?;
    world.wait_for_with(
        |w| {
            picker_instance(w, "codex")["models"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|model| {
                    model["slug"] == json!(CUSTOM_MODEL) && model["isCustom"] == json!(true)
                })
        },
        |w| {
            format!(
                "the model picker to offer my-model; it is {}",
                show(&w.state("modelPicker"))
            )
        },
    )?;
    world.dispatch(
        "composer.model.select",
        json!({"instanceId": "codex", "model": CUSTOM_MODEL}),
    )?;
    world.wait_for_with(
        |w| w.state("composer")["selectedModel"] == json!(CUSTOM_MODEL),
        |w| {
            format!(
                "the composer on my-model; it shows {}",
                show(&w.state("composer"))
            )
        },
    )
}

/// The choices the composer offers for its model's reasoning.
fn reasoning_choices(world: &World) -> Vec<String> {
    world.state("composer")["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|option| option["id"] == json!("reasoningEffort"))
        .flat_map(|option| option["choices"].as_array().cloned().unwrap_or_default())
        .map(|choice| text(&choice["id"]))
        .collect()
}

fn registry(world: &World) -> Value {
    wizard(world)["registry"].clone()
}

/// Searches the registry in the wizard and waits for this query's answer.
fn search_registry(world: &mut World, query: &str) -> Outcome {
    open_wizard(world)?;
    act(world, "registrySearch", json!({"query": query}))?;
    world.wait_for_with(
        |w| {
            let shown = registry(w);
            shown["query"] == json!(query)
                && shown["searching"] != json!(true)
                && shown["agents"].is_array()
        },
        |w| {
            format!(
                "the registry's answer to \"{query}\"; the wizard is {}",
                show(&wizard(w))
            )
        },
    )
}

fn registry_agent(world: &World, agent_id: &str) -> Value {
    registry(world)["agents"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|agent| agent["id"] == json!(agent_id))
        .cloned()
        .unwrap_or(Value::Null)
}

fn acp_section(world: &World) -> Value {
    entry(world, "Gemini")["acp"].clone()
}

/// The shown environment's project `title`.
fn acp_project(world: &mut World, title: &str) {
    let now = iso(stream_now());
    let row = json!({
        "id": title, "title": title,
        "workspaceRoot": format!("/work/{title}"),
        "createdAt": now, "updatedAt": now,
        "scripts": [],
    });
    world.mc.projects.insert(title.into(), row.clone());
    world.mc.send_row_of(title, &row, "project");
}

/// Gemini with one native session in `project`, imported as a thread or not.
fn acp_session(world: &mut World, project: &str, imported: bool) -> Outcome {
    open_panel(world)?;
    acp_project(world, project);
    let session = json!({
        "sessionId": "session-1",
        "cwd": format!("/work/{project}"),
        "title": "Fix the build",
        "updatedAt": iso(stream_now()),
        "importedThreadId": if imported { json!("thread-imported") } else { Value::Null },
    });
    fake(world).acp_sessions = vec![session];
    offer(world, acp_agent("authenticated"));
    world.wait_for_with(
        |w| acp_section(w)["projectId"] == json!(project),
        |w| {
            format!(
                "Gemini's sessions to be asked from {project}; the card is {}",
                show(&entry(w, "Gemini"))
            )
        },
    )
}

fn listed_session(world: &World) -> Value {
    acp_section(world)["sessions"]
        .as_array()
        .and_then(|sessions| sessions.first().cloned())
        .unwrap_or(Value::Null)
}

fn list_sessions(world: &mut World) -> Outcome {
    act(world, "acpSessions", json!({"instanceId": "gemini"}))?;
    world.wait_for_with(
        |w| {
            let section = acp_section(w);
            section["sessions"].is_array() && text(&section["busy"]).is_empty()
        },
        |w| {
            format!(
                "Gemini's sessions to be listed; the section is {}",
                show(&acp_section(w))
            )
        },
    )
}

/// Gemini's "openai" model provider, listed from a project.
fn list_acp_providers(world: &mut World) -> Outcome {
    open_panel(world)?;
    acp_project(world, "hal-c2");
    fake(world).acp_providers = vec![json!({
        "providerId": "openai",
        "supported": ["openai"],
        "required": false,
        "current": Value::Null,
    })];
    offer(world, acp_agent("authenticated"));
    world.wait_for_with(
        |w| !text(&acp_section(w)["projectId"]).is_empty(),
        |w| {
            format!(
                "a project to ask Gemini from; the card is {}",
                show(&entry(w, "Gemini"))
            )
        },
    )?;
    act(world, "acpProviders", json!({"instanceId": "gemini"}))?;
    world.wait_for_with(
        |w| acp_section(w)["providers"].as_array().map(Vec::len) == Some(1),
        |w| {
            format!(
                "Gemini's model providers; the section is {}",
                show(&acp_section(w))
            )
        },
    )
}

fn acp_provider(world: &World) -> Value {
    acp_section(world)["providers"]
        .as_array()
        .and_then(|providers| providers.first().cloned())
        .unwrap_or(Value::Null)
}

fn set_acp_provider(world: &mut World, base_url: &str, headers: &str) -> Outcome {
    act(
        world,
        "acpSetProvider",
        json!({
            "instanceId": "gemini",
            "providerId": "openai",
            "apiType": "openai",
            "baseUrl": base_url,
            "headers": headers,
        }),
    )
}

/// The providers settings page in a brick, made when no brick is shown.
fn pane(world: &mut World, height: f64) -> Outcome<Brick> {
    if world.part::<Shown>().0.is_none() {
        let brick = Brick::new(
            world,
            &format!(
                "import QtQuick\nimport HalC2.Bricks\nProvidersSettings {{ width: 900; height: {height} }}\n"
            ),
            900.0,
            height,
        )?;
        world.part::<Shown>().0 = Some(brick);
    }
    world.pump()?;
    shown(world)
}

/// The account email a provider's card shows.
fn email(world: &mut World) -> Outcome<String> {
    let brick = pane(world, 900.0)?;
    let item = brick.item(world, "email")?;
    Ok(brick.text_of(world, item, "text"))
}

fn scrambled(world: &mut World) -> Outcome {
    let brick = pane(world, 900.0)?;
    let item = brick.item(world, "email")?;
    let said = brick.text_of(world, item, "text");
    expect!(
        brick.flag(world, item, "visible")
            && !said.is_empty()
            && !said.contains("ada")
            && !said.contains("example.com"),
        "the card shows \"{said}\""
    );
    Ok(())
}

/// Every item under `item`, `item` included.
fn descendants(world: &World, item: ObjectId) -> Vec<ObjectId> {
    let mut found = vec![item];
    if let JsValue::List(children) = world.engine().read_by_name(item, "children") {
        for child in children.iter() {
            if let JsValue::Object(child) = child {
                found.extend(descendants(world, *child));
            }
        }
    }
    found
}

/// "The user renames <instance> to <name>" in the Providers settings
/// (workspace's steps share the words for thread titles).
pub fn rename_provider_instance(world: &mut World, from: &str, to: &str) -> Outcome {
    seed_work(world, from, Value::Null)?;
    let id = fake(world).instance_id.clone();
    act(world, "rename", json!({"instanceId": id, "name": to}))
}
