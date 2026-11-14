//! The saved-environment catalog against a model of it: any order of saves,
//! forgets, a keyring that refuses or stops giving back, and restarts leaves
//! the records and credentials the model says. A save the keyring refuses
//! changes nothing, and connecting to one blocks exactly when its record or
//! credential is gone.

use std::collections::BTreeMap;
use std::rc::Rc;

use hal_c2_shell::saved_environments::{
    EnvironmentCatalog, MemorySecretStore, SavedEnvironment, credential_missing, profile_missing,
};
use proptest::prelude::*;

const IDS: [&str; 3] = ["studio", "rack", "laptop"];

#[derive(Clone, Debug)]
enum Op {
    Save { id: usize, n: u8, origin: bool },
    Forget { id: usize },
    Refusing(bool),
    Unreadable(bool),
    Restart,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (0..IDS.len(), any::<u8>(), any::<bool>())
            .prop_map(|(id, n, origin)| Op::Save { id, n, origin }),
        2 => (0..IDS.len()).prop_map(|id| Op::Forget { id }),
        1 => any::<bool>().prop_map(Op::Refusing),
        1 => any::<bool>().prop_map(Op::Unreadable),
        1 => Just(Op::Restart),
    ]
}

/// id -> (label, has an origin, credential)
type Model = BTreeMap<String, (String, bool, String)>;

proptest! {
    #[test]
    fn the_catalog_keeps_what_its_model_says(ops in prop::collection::vec(op(), 1..40)) {
        let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
        let path = home.path().join("saved-environments.json");
        let secrets = Rc::new(MemorySecretStore::default());
        let mut catalog = EnvironmentCatalog::open(&path, secrets.clone());
        let mut model = Model::new();
        for op in ops {
            match op {
                Op::Save { id, n, origin } => {
                    let id = IDS[id].to_owned();
                    let label = format!("Label {n}");
                    let credential = format!("session-{n}");
                    let saved = catalog.save(
                        SavedEnvironment {
                            id: id.clone(),
                            label: label.clone(),
                            origin: if origin { "http://127.0.0.1:9".into() } else { String::new() },
                            expires_at: String::new(),
                        },
                        &credential,
                    );
                    if secrets.refusing.get() {
                        prop_assert!(saved.is_err());
                    } else {
                        prop_assert!(saved.is_ok(), "{saved:?}");
                        model.insert(id, (label, origin, credential));
                    }
                }
                Op::Forget { id } => {
                    catalog.forget(IDS[id]);
                    model.remove(IDS[id]);
                }
                Op::Refusing(on) => secrets.refusing.set(on),
                Op::Unreadable(on) => secrets.unreadable.set(on),
                Op::Restart => catalog = EnvironmentCatalog::open(&path, secrets.clone()),
            }
            let listed: BTreeMap<String, String> = catalog
                .environments()
                .iter()
                .map(|e| (e.id.clone(), e.label.clone()))
                .collect();
            let expected: BTreeMap<String, String> =
                model.iter().map(|(id, (label, _, _))| (id.clone(), label.clone())).collect();
            prop_assert_eq!(listed, expected);
            prop_assert!(catalog.damaged().is_empty());
            let unreadable = secrets.refusing.get() || secrets.unreadable.get();
            for id in IDS {
                let connection = catalog.connect(id);
                let blocked = match model.get(id) {
                    None | Some((_, false, _)) => profile_missing(id),
                    Some(_) if unreadable => credential_missing(id),
                    Some(_) => String::new(),
                };
                prop_assert_eq!(&connection.blocked, &blocked);
                if blocked.is_empty() {
                    prop_assert_eq!(&connection.credential, &model[id].2);
                }
            }
            // Nothing is kept in the clear.
            let on_disk = std::fs::read_to_string(&path).unwrap_or_default();
            prop_assert!(!on_disk.contains("session-"));
        }
    }
}
