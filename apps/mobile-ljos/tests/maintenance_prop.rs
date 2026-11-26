//! Maintenance's published view against a model of its machines,
//! in the spirit of mobile-qt's RapidCheck prop
//! (tests/prop/tst_MaintenanceProp, which drives the whole shell
//! against a fake MC): here the pure core is driven through
//! session answers, release checks, updates that start, answer,
//! come back or give up, and provider updates, and after each step
//! the published state must agree — blocked text, targets, the
//! updatable count, groups of a provider behind on several
//! machines, and outcomes only for updates that ended.

use hal_c2_mobile::maintenance::{Core, Machine, Outcome, Release, Session, can_update_provider};
use proptest::prelude::*;
use serde_json::{Map, Value as Json, json};

fn machine(id: &str, version: &str, capabilities: Map<String, Json>) -> Machine {
    Machine {
        environment_id: id.into(),
        label: format!("Machine {id}"),
        version: version.into(),
        online: true,
        local: id == "env-a",
        capabilities,
    }
}

fn caps(self_update: &str, desktop_app: bool) -> Map<String, Json> {
    let mut caps = Map::new();
    if !self_update.is_empty() {
        caps.insert("serverSelfUpdate".into(), json!(self_update));
    }
    caps.insert("desktopAppUpdate".into(), json!(desktop_app));
    caps
}

fn provider(instance: &str, behind: bool, status: &str) -> Json {
    json!({
        "instanceId": instance,
        "driver": "codex",
        "enabled": true,
        "installed": true,
        "versionAdvisory": {
            "status": if behind { "behind_latest" } else { "current" },
            "canUpdate": true,
            "currentVersion": "0.50.0",
            "latestVersion": "0.51.0",
        },
        "updateState": {"status": status},
    })
}

#[derive(Clone, Debug)]
enum Action {
    Session(u8),
    Release(String, bool),
    Answer(String, bool),
    ComeBack(String),
    GiveUp(String),
    ProviderEnd(String, bool),
    Disconnect,
    Reconnect,
    NewApp,
}

fn env() -> impl Strategy<Value = String> {
    prop_oneof![Just("env-a".to_string()), Just("env-b".to_string())]
}

fn action() -> impl Strategy<Value = Action> {
    prop_oneof![
        (0u8..5).prop_map(Action::Session),
        (env(), any::<bool>()).prop_map(|(id, newer)| Action::Release(id, newer)),
        (env(), any::<bool>()).prop_map(|(id, ok)| Action::Answer(id, ok)),
        env().prop_map(Action::ComeBack),
        env().prop_map(Action::GiveUp),
        (env(), any::<bool>()).prop_map(|(id, ok)| Action::ProviderEnd(id, ok)),
        Just(Action::Disconnect),
        Just(Action::Reconnect),
        Just(Action::NewApp),
    ]
}

proptest! {
    #[test]
    fn the_published_state_agrees_with_the_machines(
        actions in prop::collection::vec(action(), 0..30),
    ) {
        let mut core = Core::default();
        let mut ready = true;
        let mut app = 1u32;
        let mut versions = [0u32, 0];
        let behind = [true, true];
        for action in actions {
            match action {
                Action::Session(word) => {
                    core.session = match word {
                        0 => Session::Unknown,
                        1 => Session::Reading,
                        2 => Session::May,
                        3 => Session::MayNot,
                        _ => Session::Failed,
                    };
                }
                Action::Release(id, newer) => {
                    core.releases.insert(id, Release {
                        checking: false,
                        text: String::new(),
                        available: if newer { format!("0.{}.0", app + 2) } else { String::new() },
                    });
                }
                Action::Answer(id, ok) => {
                    // An update starts and the MC answers it.
                    let left = format!("0.{}.0", versions[usize::from(id != "env-a")]);
                    if ok {
                        core.reconnecting.insert(id, left);
                    } else {
                        core.outcomes.insert(id.clone(), Outcome { ok: false, text: "failed".into() });
                    }
                }
                Action::ComeBack(id) => {
                    let index = usize::from(id != "env-a");
                    versions[index] = app;
                }
                Action::GiveUp(id) => {
                    if let Some(left) = core.reconnecting.remove(&id) {
                        core.outcomes.insert(id.clone(), Outcome { ok: false, text: "gave up".into() });
                        core.gave_up_on.insert(id, left);
                    }
                }
                Action::ProviderEnd(id, ok) => {
                    let key = format!("{id}\ncodex");
                    core.provider_updates.remove(&key);
                    core.provider_outcomes.insert(key, Outcome { ok, text: if ok { "Updated".into() } else { "Failed: x".into() } });
                }
                Action::Disconnect => ready = false,
                Action::Reconnect => ready = true,
                Action::NewApp => app += 1,
            }
            let app_version = format!("0.{app}.0");
            let machines = vec![
                machine("env-a", &format!("0.{}.0", versions[0]), caps("hot-upgrade", false)),
                machine("env-b", &format!("0.{}.0", versions[1]), caps("desktop-managed", true)),
            ];
            let settled = core.settle(&machines);
            for id in settled {
                core.reconnecting.remove(&id);
            }
            let local = vec![provider("codex", behind[0], "")];
            core.providers.insert("env-b".into(), vec![provider("codex", behind[1], "")]);
            let state = core.state(&machines, &app_version, ready, &local);
            // The updatable count is the machines updateAll reaches.
            prop_assert_eq!(
                state["updatable"].as_u64(),
                Some(core.updatable(&machines, &app_version, ready).len() as u64)
            );
            for (index, shown) in state["machines"].as_array().unwrap().iter().enumerate() {
                let machine = &machines[index];
                // Nothing starts where it is blocked, and a target
                // only names a newer version or the release found.
                if !shown["blocked"].as_str().unwrap_or_default().is_empty() {
                    for provider in shown["providers"].as_array().unwrap() {
                        prop_assert_eq!(provider["canUpdate"].as_bool(), Some(false));
                    }
                }
                let target = shown["target"].as_str().unwrap_or_default();
                if !target.is_empty() {
                    let release = core.releases.get(&machine.environment_id);
                    prop_assert!(
                        release.is_some_and(|r| r.available == target)
                            || target == app_version,
                        "target {target} from nowhere"
                    );
                    let command = format!("npx hal-c2@{target}");
                    prop_assert_eq!(shown["command"].as_str(), Some(command.as_str()));
                } else {
                    prop_assert_eq!(shown["command"].as_str(), Some(""));
                }
                for provider in shown["providers"].as_array().unwrap() {
                    if provider["canUpdate"].as_bool() == Some(true) {
                        let held = if machine.local {
                            &local[0]
                        } else {
                            &core.providers["env-b"][0]
                        };
                        prop_assert!(can_update_provider(held.as_object().unwrap()));
                    }
                }
            }
            // A group only counts a provider behind on several machines.
            for group in state["groups"].as_array().unwrap() {
                prop_assert!(group["count"].as_u64().unwrap_or(0) > 1);
            }
        }
    }
}
