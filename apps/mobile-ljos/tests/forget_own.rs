//! Forgetting the phone's own environment when an interrupted promote or
//! re-pair left it in the saved environments too (#1746): the saved copy
//! and its credential go with it. At start the saved copy is dropped only
//! when it holds the pairing's own session: a tablet's Settings >
//! Connections saves a newer one there.

use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, mpsc};

use hal_c2_mc::pairing::{Link, Outcome, Pairing as Exchanged};
use hal_c2_mobile::pairing::{self, Environment};
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller as shell_controller;
use hal_c2_shell::controllers::saved_environments as controller;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Connection, Mc};
use hal_c2_shell::saved_environments::{
    EnvironmentCatalog, FILE, MemorySecretStore, SavedEnvironment,
};
use hal_c2_shell::store::{self, Client};
use hal_c2_shell::streams::Pump;
use ljos::prelude::Platform;
use ljos::{App, Engine};

/// The session pairing env-b again buys.
const FRESH: &str = "session-env-b-fresh";

/// env-b's answer to a pairing link.
fn paired_again(link: &Link) -> Exchanged {
    let mut descriptor = serde_json::Map::new();
    descriptor.insert("environmentId".into(), "env-b".into());
    descriptor.insert("label".into(), "env-b".into());
    Exchanged {
        outcome: Outcome::Paired,
        origin: link.origins[0].clone(),
        token: FRESH.into(),
        descriptor,
    }
}

/// The phone started over what the device kept.
struct Phone {
    engine: Engine,
    streams: Pump,
    path: PathBuf,
    data: PathBuf,
    secrets: Rc<MemorySecretStore>,
    _home: tempfile::TempDir,
}

impl Phone {
    /// Started with env-b its own on `own` and `beside` in the catalog,
    /// each of those on `session-<id>`.
    fn start(name: &str, own: &str, beside: &[&str]) -> Phone {
        let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
        let data = home.path().join("data");
        let path = data.join("pairing.json");
        let secrets = Rc::new(MemorySecretStore::default());
        assert!(pairing::save(
            &path,
            &Environment {
                origin: "http://127.0.0.1:9".into(),
                token: own.into(),
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
        pairing::set_exchange(&engine, Arc::new(|link, _| paired_again(link)));
        hal_c2_mobile::install(&engine, launch.data_dir.clone(), launch.config_dir.clone());
        hal_c2_shell::start_with(
            &engine,
            &launch,
            connection as Rc<dyn Mc>,
            hal_c2_mobile::registrations(),
        );
        hal_c2_mobile::start(&engine);
        streams.pump(&engine);
        Phone {
            engine,
            streams,
            path,
            data,
            secrets,
            _home: home,
        }
    }

    fn dispatch(&mut self, action: &str, key: &str, value: &str) {
        let payload: Json = [(key, value)].into_iter().collect();
        Bridge::of(&self.engine).dispatch(&self.engine, action, payload);
        self.streams.pump(&self.engine);
    }

    /// What is left: the pairing (id and session), the catalog's ids, and
    /// the keyring's sessions.
    fn left(&self) -> (Option<String>, Vec<String>, Vec<String>) {
        let own =
            pairing::load(&self.path).map(|kept| format!("{} {}", kept.environment_id, kept.token));
        let catalog = EnvironmentCatalog::open(&self.data.join(FILE), self.secrets.clone());
        let mut listed: Vec<String> = catalog
            .environments()
            .iter()
            .map(|environment| environment.id.clone())
            .collect();
        listed.sort();
        let mut kept: Vec<String> = self.secrets.secrets.borrow().values().cloned().collect();
        kept.sort();
        (own, listed, kept)
    }
}

/// The phone restarted as an interrupted promote leaves it, env-b's two on
/// one session; `forget` says whether it then forgets env-b.
fn restarted(
    name: &str,
    beside: &[&str],
    forget: bool,
) -> (Option<String>, Vec<String>, Vec<String>) {
    let mut phone = Phone::start(name, "session-env-b", beside);
    if forget {
        phone.dispatch("pairing.forget", "id", "env-b");
    }
    phone.left()
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

#[test]
fn starting_keeps_a_saved_copy_with_another_session() {
    // The saved one may be the only session that works.
    assert_eq!(
        Phone::start("newer", "session-refused", &["env-b"]).left(),
        (
            Some("env-b session-refused".into()),
            vec!["env-b".to_string()],
            vec!["session-env-b".to_string()]
        )
    );
}

#[test]
fn pairing_again_beside_itself_keeps_what_it_showed() {
    let mut phone = Phone::start("again", "session-refused", &[]);
    let engine = &phone.engine;
    // A tablet's Settings > Connections saves a fresh session beside it,
    // and that link lists the threads.
    let saved = SavedEnvironment {
        id: "env-b".into(),
        label: "env-b".into(),
        origin: "http://127.0.0.1:9".into(),
        expires_at: String::new(),
    };
    shell_controller::with::<controller::SavedEnvironments, _>(engine, |c, engine| {
        c.save(engine, saved, "session-env-b")
    })
    .expect("the controller")
    .expect("saved");
    let listed = serde_json::json!({
        "t": "shell",
        "mcs": [{"mc": "mc-b", "environment": {"environmentId": "env-b"}, "online": true}],
        "rows": [["mc-b", "t-b", "thread", {"id": "t-b", "title": "thread of env-b"}]],
    });
    let rows = store::get(engine).expect("the store");
    rows.borrow_mut().apply_from(
        listed.as_object().expect("a frame"),
        &Client::Link("env-b".into()),
    );
    assert!(rows.borrow().thread_row_on("env-b", "t-b").is_some());

    phone.dispatch("pairing.pair", "link", "http://127.0.0.1:9/?token=again");
    Platform::of(&phone.engine).finish(&phone.engine);
    phone.streams.pump(&phone.engine);

    assert_eq!(
        phone.left(),
        (Some(format!("env-b {FRESH}")), vec![], vec![])
    );
    assert!(
        rows.borrow().thread_row_on("env-b", "t-b").is_some(),
        "pairing again erased the threads"
    );
}
