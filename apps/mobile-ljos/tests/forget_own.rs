//! Forgetting the phone's own environment when an interrupted promote or
//! re-pair left it in the saved environments too (#1746): the saved copy
//! and its credential go with it, and at start the saved copy of the
//! pairing is dropped (pairing.json is written first, so it is newer).

use std::rc::Rc;
use std::sync::mpsc;

use hal_c2_mobile::pairing::{self, Environment};
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::saved_environments as controller;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Connection, Mc};
use hal_c2_shell::saved_environments::{
    EnvironmentCatalog, FILE, MemorySecretStore, SavedEnvironment,
};
use hal_c2_shell::streams::Pump;
use ljos::App;

/// The phone restarted with env-b its own and `beside` in the catalog;
/// `forget` says whether it then forgets env-b. What is left: the pairing
/// (id and session), the catalog's ids, and the keyring's sessions.
fn restarted(
    name: &str,
    beside: &[&str],
    forget: bool,
) -> (Option<String>, Vec<String>, Vec<String>) {
    let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let data = home.path().join("data");
    let path = data.join("pairing.json");
    let secrets = Rc::new(MemorySecretStore::default());
    assert!(pairing::save(
        &path,
        &Environment {
            origin: "http://127.0.0.1:9".into(),
            token: "session-env-b".into(),
            label: "env-b".into(),
            environment_id: "env-b".into(),
        }
    ));
    let mut catalog = EnvironmentCatalog::open(&data.join(FILE), secrets.clone());
    for id in beside {
        catalog
            .save(
                SavedEnvironment {
                    id: (*id).into(),
                    label: (*id).into(),
                    origin: "http://127.0.0.1:9".into(),
                    expires_at: String::new(),
                },
                &format!("session-{id}"),
            )
            .unwrap();
    }
    drop(catalog);
    let engine = App::new(name)
        .register(hal_c2_mobile::register)
        .source(hal_c2_mobile::pack())
        .root("Main")
        .build_engine();
    controller::set_secret_store(&engine, secrets.clone());
    controller::set_data_dir(&engine, Some(data.clone()));
    let (woken, _wakes) = mpsc::channel();
    let mut streams = Pump::new(move || {
        let _ = woken.send(());
    });
    let wired = hal_c2_shell::streams::wire(&engine, &mut streams);
    let connection = Connection::spawn(&wired.mc);
    let launch = Launch {
        config_dir: Some(home.path().join("config")),
        cache_dir: Some(home.path().join("cache")),
        data_dir: Some(data.clone()),
        state_dir: Some(home.path().join("state")),
        ..Launch::default()
    };
    hal_c2_mobile::install(&engine, launch.data_dir.clone(), launch.config_dir.clone());
    hal_c2_shell::start_with(
        &engine,
        &launch,
        connection as Rc<dyn Mc>,
        hal_c2_mobile::registrations(),
    );
    hal_c2_mobile::start(&engine);
    streams.pump(&engine);
    if forget {
        let payload: Json = [("id", "env-b")].into_iter().collect();
        Bridge::of(&engine).dispatch(&engine, "pairing.forget", payload);
        streams.pump(&engine);
    }
    let own = pairing::load(&path).map(|kept| format!("{} {}", kept.environment_id, kept.token));
    let catalog = EnvironmentCatalog::open(&data.join(FILE), secrets.clone());
    let mut listed: Vec<String> = catalog
        .environments()
        .iter()
        .map(|environment| environment.id.clone())
        .collect();
    listed.sort();
    let mut kept: Vec<String> = secrets.secrets.borrow().values().cloned().collect();
    kept.sort();
    (own, listed, kept)
}

#[test]
fn forgetting_own_not_duplicated() {
    assert_eq!(restarted("control", &[], true), (None, vec![], vec![]));
}

#[test]
fn forgetting_own_also_saved_forgets_it() {
    assert_eq!(restarted("alone", &["env-b"], true), (None, vec![], vec![]));
}

#[test]
fn forgetting_own_also_saved_behind_another_promotes_the_other() {
    assert_eq!(
        restarted("behind", &["env-c", "env-b"], true),
        (Some("env-c session-env-c".into()), vec![], vec![])
    );
}

#[test]
fn starting_with_own_also_saved_drops_the_saved_copy() {
    // The live pairing stays, token and all: its credential is in
    // pairing.json, not under its id in the keyring.
    assert_eq!(
        restarted("start", &["env-b", "env-c"], false),
        (
            Some("env-b session-env-b".into()),
            vec!["env-c".to_string()],
            vec!["session-env-c".to_string()]
        )
    );
}
