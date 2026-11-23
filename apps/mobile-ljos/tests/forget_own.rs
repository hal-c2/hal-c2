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
use hal_c2_shell::controllers::{drafts, threads};
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

    /// Saves `id` as Settings > Connections does, with its link listing
    /// thread t-<id>.
    fn listed_beside(&self, id: &str) {
        let saved = SavedEnvironment {
            id: id.into(),
            label: id.into(),
            origin: "http://127.0.0.1:9".into(),
            expires_at: String::new(),
        };
        shell_controller::with::<controller::SavedEnvironments, _>(&self.engine, |c, engine| {
            c.save(engine, saved, &format!("session-{id}"))
        })
        .expect("the controller")
        .expect("saved");
        let listed = serde_json::json!({
            "t": "shell",
            "mcs": [{"mc": format!("mc-{id}"), "environment": {"environmentId": id}, "online": true}],
            "rows": [[format!("mc-{id}"), format!("t-{id}"), "thread", {"id": format!("t-{id}"), "title": id}]],
        });
        let rows = store::get(&self.engine).expect("the store");
        rows.borrow_mut().apply_from(
            listed.as_object().expect("a frame"),
            &Client::Link(id.into()),
        );
        assert!(self.shows(id));
    }

    /// The own MC lists thread t-env-b, and it is kept on disk.
    fn listed_by_own(&self) {
        let listed = serde_json::json!({
            "t": "shell",
            "mcs": [{"mc": "mc-env-b", "environment": {"environmentId": "env-b"}, "online": true}],
            "rows": [["mc-env-b", "t-env-b", "thread", {"id": "t-env-b", "title": "Tax line"}]],
        });
        let rows = store::get(&self.engine).expect("the store");
        rows.borrow_mut()
            .apply(listed.as_object().expect("a frame"));
        store::flush(&self.engine);
        assert!(self.shows("env-b"));
        assert!(self.keeps("Tax line"), "the threads were not kept");
    }

    /// Whether a file of the client cache names `text`.
    fn keeps(&self, text: &str) -> bool {
        if let Some(cache) = store::cache(&self.engine) {
            cache.drain();
        }
        std::fs::read_dir(self._home.path().join("cache"))
            .expect("the cache")
            .filter_map(|file| std::fs::read(file.ok()?.path()).ok())
            .any(|kept| kept.windows(text.len()).any(|at| at == text.as_bytes()))
    }

    fn shows(&self, id: &str) -> bool {
        store::get(&self.engine)
            .expect("the store")
            .borrow()
            .thread_row_on(id, &format!("t-{id}"))
            .is_some()
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
/// one session.
fn restarted(name: &str, beside: &[&str]) -> (Option<String>, Vec<String>, Vec<String>) {
    Phone::start(name, "session-env-b", beside).left()
}

/// The phone with `beside` saved, env-b's copy on another session than its
/// own, as only that outlives a start, after it forgets env-b.
fn forgotten(name: &str, beside: &[&str]) -> (Option<String>, Vec<String>, Vec<String>) {
    let mut phone = Phone::start(name, "session-own", beside);
    let mut saved: Vec<String> = beside.iter().map(|id| (*id).to_owned()).collect();
    saved.sort();
    assert_eq!(phone.left().1, saved, "the start left forget nothing to do");
    phone.dispatch("pairing.forget", "id", "env-b");
    phone.left()
}

/// env-b's saved copy with an open thread held on its link, which `act`
/// takes away: whether the thread is still held there.
fn holds_after_removal(name: &str, act: impl FnOnce(&mut Phone)) -> bool {
    let mut phone = Phone::start(name, "session-own", &[]);
    phone.listed_beside("env-b");
    let mc = shell_controller::mc(&phone.engine).expect("the MC");
    mc.subscribe(
        serde_json::json!({"type": "thread", "environmentId": "env-b", "threadId": "t-env-b"}),
        Box::new(|_, _| {}),
        None,
    );
    let link = shell_controller::with::<controller::SavedEnvironments, _>(&phone.engine, |c, _| {
        c.link("env-b").map(|link| Rc::downgrade(&link))
    })
    .flatten()
    .expect("the copy's link");
    act(&mut phone);
    // Nothing but a subscription held on it keeps a closed link.
    link.upgrade().is_some()
}

#[test]
fn forgetting_own_not_duplicated() {
    assert_eq!(forgotten("control", &[]), (None, vec![], vec![]));
}

#[test]
fn forgetting_own_also_saved_forgets_it() {
    assert_eq!(forgotten("alone", &["env-b"]), (None, vec![], vec![]));
}

#[test]
fn forgetting_own_also_saved_behind_another_promotes_the_other() {
    assert_eq!(
        forgotten("behind", &["env-c", "env-b"]),
        (Some("env-c session-env-c".into()), vec![], vec![])
    );
}

#[test]
fn starting_with_own_also_saved_drops_the_saved_copy() {
    // The live pairing stays, token and all: its credential is in
    // pairing.json, not under its id in the keyring.
    assert_eq!(
        restarted("start", &["env-b", "env-c"]),
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
    // A tablet's Settings > Connections saves a fresh session beside it,
    // and that link lists the threads.
    phone.listed_beside("env-b");

    phone.dispatch("pairing.pair", "link", "http://127.0.0.1:9/?token=again");
    Platform::of(&phone.engine).finish(&phone.engine);
    phone.streams.pump(&phone.engine);

    assert_eq!(
        phone.left(),
        (Some(format!("env-b {FRESH}")), vec![], vec![])
    );
    assert!(phone.shows("env-b"), "pairing again erased the threads");
}

#[test]
fn removing_own_saved_copy_in_settings_keeps_what_it_showed() {
    // Its own MC never answered, so only the pairing says whose it is.
    let mut phone = Phone::start("remove-copy", "session-own", &[]);
    phone.listed_beside("env-b");

    phone.dispatch("savedEnvironments.remove", "id", "env-b");

    assert_eq!(
        phone.left(),
        (Some("env-b session-own".into()), vec![], vec![])
    );
    assert!(phone.shows("env-b"), "removing the copy erased the threads");
}

#[test]
fn removing_own_saved_copy_takes_the_open_thread_off_its_link() {
    let held = holds_after_removal("remove-held", |phone| {
        phone.dispatch("savedEnvironments.remove", "id", "env-b");
    });
    assert!(!held, "the open thread stayed on the closed link");
}

#[test]
fn pairing_again_takes_the_open_thread_off_the_copys_link() {
    let held = holds_after_removal("again-held", |phone| {
        phone.dispatch("pairing.pair", "link", "http://127.0.0.1:9/?token=again");
        Platform::of(&phone.engine).finish(&phone.engine);
        phone.streams.pump(&phone.engine);
    });
    assert!(!held, "the open thread stayed on the closed link");
}

#[test]
fn removing_another_in_settings_erases_what_it_showed() {
    let mut phone = Phone::start("remove-other", "session-own", &[]);
    phone.listed_beside("env-c");

    phone.dispatch("savedEnvironments.remove", "id", "env-c");

    assert!(!phone.shows("env-c"), "removing it kept the threads");
}

#[test]
fn forgetting_own_also_saved_erases_what_it_showed() {
    let mut phone = Phone::start("forget-copy", "session-own", &[]);
    phone.listed_beside("env-b");

    // Closing the own connection ends on the pump, after the copy is removed.
    phone.dispatch("pairing.forget", "id", "env-b");

    assert!(!phone.shows("env-b"), "forgetting kept the threads");
    assert_eq!(
        phone.left(),
        (None, vec![], vec![]),
        "forgetting kept the saved copy"
    );
}

#[test]
fn forgetting_own_closes_its_connection() {
    let mut phone = Phone::start("forget-closes", "session-own", &[]);
    let mc = shell_controller::mc(&phone.engine).expect("the MC");
    assert_eq!(mc.open_for(), "env-b");

    phone.dispatch("pairing.forget", "id", "env-b");

    assert_eq!(mc.open_for(), "", "forgetting left the connection open");
}

#[test]
fn forgetting_own_erases_what_it_kept() {
    let mut phone = Phone::start("forget-kept", "session-own", &[]);
    phone.listed_by_own();

    phone.dispatch("pairing.forget", "id", "env-b");

    assert!(!phone.shows("env-b"), "forgetting kept the threads listed");
    assert!(
        !phone.keeps("Tax line"),
        "forgetting kept the threads on disk"
    );
}

#[test]
fn forgetting_own_before_another_erases_what_it_kept() {
    let mut phone = Phone::start("forget-first", "session-own", &["env-c"]);
    phone.listed_by_own();

    phone.dispatch("pairing.forget", "id", "env-b");

    assert!(!phone.shows("env-b"), "promoting kept the threads listed");
    assert!(
        !phone.keeps("Tax line"),
        "promoting kept the threads on disk"
    );
}

#[test]
fn forgetting_own_drops_its_drafts() {
    let mut phone = Phone::start("forget-drafts", "session-own", &[]);
    drafts::start(&phone.engine, "env-b", "project").expect("a draft");

    phone.dispatch("pairing.forget", "id", "env-b");

    assert!(
        drafts::all(&phone.engine).is_empty(),
        "forgetting kept the draft"
    );
}

#[test]
fn forgetting_own_has_the_others_list_again() {
    let mut phone = Phone::start("forget-others", "session-own", &["env-c", "env-d"]);
    let link = |phone: &Phone| {
        shell_controller::with::<controller::SavedEnvironments, _>(&phone.engine, |c, _| {
            c.link("env-d")
        })
        .flatten()
        .expect("env-d's link")
    };
    let before = link(&phone);

    phone.dispatch("pairing.forget", "id", "env-b");

    // Emptied with env-b's, what env-d lists comes with a new snapshot.
    assert!(
        !Rc::ptr_eq(&before, &link(&phone)),
        "env-d was not asked again"
    );
}

#[test]
fn forgetting_says_so_when_what_was_kept_cannot_be_deleted() {
    use std::os::unix::fs::PermissionsExt;
    let mut phone = Phone::start("forget-stuck", "session-own", &[]);
    phone.listed_by_own();
    let dir = phone._home.path().join("cache");
    let files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("the cache")
        .map(|file| file.expect("a file").path())
        .collect();
    let allow = |dir_mode, file_mode| {
        let set = |path, mode| {
            // Its WAL may go with the connection.
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
        };
        files.iter().for_each(|file| set(file, file_mode));
        set(&dir, dir_mode);
    };
    allow(0o500, 0o400);

    phone.dispatch("pairing.forget", "id", "env-b");
    threads::drain(&phone.engine);
    allow(0o700, 0o600);

    assert!(!phone.shows("env-b"));
    let said = Bridge::of(&phone.engine)
        .published(&phone.engine, "pairing")
        .map(|state| format!("{state:?}"))
        .expect("the pairing's state");
    assert!(said.contains("could not be deleted"), "{said}");
}
