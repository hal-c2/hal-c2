//! Saved environments (the `savedEnvironments` controller and its
//! EnvironmentCatalog) in features/connections/connection-health.feature,
//! after desktop-qt's ConnectionCatalogSteps: records and credentials that
//! have gone, a damaged record file, and a keyring that refuses.
//!
//! The saved environment is "studio", served by a FakeMc of its own
//! (World::other_mc); the World's keyring is a MemorySecretStore
//! (World::secrets).

use std::io::Write;
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use hal_c2_mc::Phase;
use hal_c2_mc::pairing::{Outcome as Paid, Pairing};
use hal_c2_shell::controllers::saved_environments::SavedEnvironments;
use hal_c2_shell::saved_environments::SavedEnvironment;
use serde_json::{Map, Value, json};

use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

pub const STUDIO: &str = "studio";
const STUDIO_SESSION: &str = "studio-session";
const DAMAGED: &str = r#"{"version": 1, "environments": [{"id": "studio", "label": "Stu"#;

/// The other environment's MC, "Studio".
fn studio(world: &mut World) -> &mut crate::fake_mc::FakeMc {
    world.other_mc("mc-studio", |mc| {
        mc.environment_id = STUDIO.into();
        mc.label = "Studio".into();
    })
}

fn studio_origin(world: &mut World) -> String {
    studio(world).origin()
}

/// Answers a raw request with `body`, as JSON.
fn respond(mut stream: TcpStream, status: u16, body: &Value) {
    let body = body.to_string();
    let head = format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        if status < 300 { "OK" } else { "Refused" },
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body.as_bytes());
}

/// What studio's own connection says of itself.
fn studio_phase(world: &World) -> Option<Phase> {
    world
        .with::<SavedEnvironments, _>(|c, _| c.link(STUDIO).map(|l| l.status().phase))
        .ok()
        .flatten()
}

fn wait_for_state(world: &mut World, id: &str, state: &str) -> Outcome {
    world.wait_for_with(
        |w| state_of(w, id) == state,
        |w| format!("{id} to be {state}; saved environments are {}", describe(w)),
    )
}

/// Saved as pairing saves it, and connected.
fn save_studio(world: &mut World) -> Outcome {
    let origin = studio_origin(world);
    let saved = world.with::<SavedEnvironments, _>(|c, engine| {
        c.save(
            engine,
            SavedEnvironment {
                id: STUDIO.into(),
                label: "Studio".into(),
                origin,
                expires_at: String::new(),
            },
            STUDIO_SESSION,
        )
    })?;
    if let Err(refused) = saved {
        fail!("studio could not be saved: {refused}");
    }
    world.pump()?;
    wait_for_state(world, STUDIO, "connected")?;
    world.wait_for_with(
        |w| {
            w.with::<SavedEnvironments, _>(|_, engine| {
                hal_c2_shell::store::with(engine, |s| s.link_serving(STUDIO).is_some())
            })
            .unwrap_or(false)
        },
        |w| {
            format!(
                "the shell to hear Studio; saved environments are {}",
                describe(w)
            )
        },
    )
}

/// The shell's connections before the scenario reconnected it.
#[derive(Default)]
struct Before(usize);

fn record_file(world: &World) -> PathBuf {
    world
        .home_dir()
        .join("data")
        .join("saved-environments.json")
}

fn listed(world: &World) -> Vec<Value> {
    world.state("savedEnvironments")["environments"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn describe(world: &World) -> String {
    show(&world.state("savedEnvironments"))
}

fn state_of(world: &World, id: &str) -> String {
    listed(world)
        .iter()
        .find(|e| text(&e["id"]) == id)
        .map(|e| text(&e["state"]))
        .unwrap_or_default()
}

/// Reads the records again, as the app does when it starts.
fn read_again(world: &mut World) -> Outcome {
    world.with::<SavedEnvironments, _>(|c, engine| c.start(engine))?;
    world.pump()
}

/// Writes the record file as `environments`, and reads it again.
fn write_records(world: &mut World, environments: Value) -> Outcome {
    let records = json!({"version": 1, "environments": environments});
    std::fs::write(record_file(world), records.to_string())
        .map_err(|e| crate::harness::Failure(format!("cannot write the record file: {e}")))?;
    read_again(world)
}

/// Whether a saved environment is what a scenario's "the connection is
/// blocked" is about, and then that it is: blocked, and not retried.
pub fn saved_environment_blocked(world: &mut World) -> Outcome<bool> {
    if listed(world).is_empty() {
        return Ok(false);
    }
    world.wait_for_with(
        |w| state_of(w, STUDIO) == "blocked",
        |w| {
            format!(
                "studio to be blocked; saved environments are {}",
                describe(w)
            )
        },
    )?;
    Ok(true)
}

/// Every file under `dir` that holds `needle`.
fn files_holding(dir: &Path, needle: &str) -> Vec<String> {
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return found;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            found.extend(files_holding(&path, needle));
        } else if std::fs::read(&path)
            .is_ok_and(|bytes| bytes.windows(needle.len()).any(|w| w == needle.as_bytes()))
        {
            found.push(path.display().to_string());
        }
    }
    found
}

/// Pairing "studio" sells its session, without the network: the exchange is
/// pairing::exchange's, the storage under test is the app's.
fn pair_studio(world: &mut World) -> Outcome {
    world.with::<SavedEnvironments, _>(|c, _| {
        c.set_exchange(Arc::new(|link, _| {
            let mut descriptor = Map::new();
            descriptor.insert("environmentId".into(), json!(STUDIO));
            descriptor.insert("label".into(), json!("Studio"));
            Pairing {
                outcome: Paid::Paired,
                origin: link.origins.first().cloned().unwrap_or_default(),
                token: STUDIO_SESSION.into(),
                descriptor,
            }
        }));
    })?;
    let origin = studio_origin(world);
    world.dispatch(
        "savedEnvironments.pair",
        json!({"link": format!("{origin}/pair#token=studio-pairing")}),
    )?;
    world.wait_for_with(
        |w| w.state("savedEnvironments")["pairing"] == json!(false),
        |w| format!("the pairing to end; saved environments are {}", describe(w)),
    )
}

pub fn register(steps: &mut Steps) {
    // Only the environment with the bad credential stops.
    steps.step("two paired environments", |world, _, _| {
        world.wait_for("the first environment to be connected", |w| {
            w.client().is_ready()
        })?;
        save_studio(world)
    });
    steps.step("one of them revoked this client", |world, _, _| {
        // Studio turns its session away, the socket and its ticket alike (router.ex).
        let refuse = |_: &mut crate::fake_mc::FakeMc, stream: TcpStream, _: &str| {
            let refusal =
                json!({"_tag": "EnvironmentAuthInvalidError", "reason": "invalid_credential"});
            respond(stream, 401, &refusal);
            Ok(())
        };
        let mc = studio(world);
        mc.on_raw(&format!("/ws?token={STUDIO_SESSION}"), refuse);
        mc.on_raw("/api/auth/websocket-ticket", refuse);
        Ok(())
    });
    steps.step("the client connects to both", |world, _, _| {
        let before = world.mc.connections.len();
        world.part::<Before>().0 = before;
        world.client().reconnect();
        let link = world.with::<SavedEnvironments, _>(|c, _| c.link(STUDIO))?;
        let Some(link) = link else {
            fail!(
                "studio has no connection; saved environments are {}",
                describe(world)
            );
        };
        link.reconnect();
        world.pump()?;
        wait_for_state(world, STUDIO, "refused")?;
        world.wait_for("the first environment to connect again", |w| {
            let before = w.peek_part::<Before>().map_or(0, |b| b.0);
            w.client().is_ready() && w.mc.connections.len() > before
        })
    });
    steps.step("the other environment stays connected", |world, _, _| {
        // What the shell says of it follows its connection.
        world.wait_for_with(
            |w| w.state("connection")["phase"] == json!("connected"),
            |w| {
                format!(
                    "the shell to say the first environment is connected; it says {}",
                    show(&w.state("connection"))
                )
            },
        )?;
        let first = world.client().status();
        expect!(
            world.client().is_ready() && first.phase == Phase::Ready,
            "the first environment is {:?} ({})",
            first.phase,
            first.failure_message
        );
        // Studio stopped on its own: it waits for the user to pair again.
        expect!(
            state_of(world, STUDIO) == "refused" && studio_phase(world) == Some(Phase::Refused),
            "saved environments are {}",
            describe(world)
        );
        Ok(())
    });

    // A saved environment whose record or credential has gone.
    steps.step(
        &format!("{Q} is saved but (its connection record is gone|its credential is gone)"),
        |world, c, _| {
            let id = c[0].clone();
            if c[1].contains("record") {
                // Listed, with nothing to say where it is.
                world
                    .secrets
                    .secrets
                    .borrow_mut()
                    .insert(id.clone(), STUDIO_SESSION.into());
                write_records(world, json!([{"id": id, "label": "Studio"}]))
            } else {
                world.secrets.secrets.borrow_mut().remove(&id);
                let origin = studio_origin(world);
                write_records(
                    world,
                    json!([{"id": id, "label": "Studio", "origin": origin}]),
                )
            }
        },
    );

    // A damaged record of saved environments.
    steps.step(
        "the desktop app's record of saved environments is damaged",
        |world, _, _| {
            // Cut off as a crash mid-write leaves it, while the app was closed.
            let path = record_file(world);
            world.quit()?;
            std::fs::write(&path, DAMAGED)
                .map_err(|e| crate::harness::Failure(format!("cannot write {path:?}: {e}")))?;
            Ok(())
        },
    );
    steps.step(
        "the app starts with no saved environments",
        |world, _, _| {
            // "the app starts" is desktop_update's.
            world.wait_for_with(
                |w| !w.state("savedEnvironments").is_null(),
                |_| "the saved environments to be read".into(),
            )?;
            let none = world.with::<SavedEnvironments, _>(|c, _| {
                c.catalog().is_some_and(|c| c.environments().is_empty())
            })?;
            expect!(
                listed(world).is_empty() && none,
                "saved environments are {}",
                describe(world)
            );
            // And the record file in its place is one it reads.
            let records: Value = std::fs::read_to_string(record_file(world))
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
                .unwrap_or_default();
            expect!(
                records["version"] == json!(1) && records["environments"] == json!([]),
                "the record file is now {}",
                show(&records)
            );
            Ok(())
        },
    );
    steps.step(
        "the damaged record is kept apart so it can be inspected",
        |world, _, _| {
            let aside = text(&world.state("savedEnvironments")["damaged"]);
            let path = PathBuf::from(&aside);
            let kept = std::fs::read_to_string(&path).unwrap_or_default();
            expect!(
                !aside.is_empty()
                    && path.parent() == record_file(world).parent()
                    && kept == DAMAGED,
                "the damaged record was kept as \"{aside}\"; saved environments are {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user can pair again without clearing anything by hand",
        |world, _, _| {
            pair_studio(world)?;
            let saved = world.secrets.secrets.borrow().get(STUDIO).cloned();
            expect!(
                listed(world).len() == 1 && saved.as_deref() == Some(STUDIO_SESSION),
                "saved environments are {}",
                describe(world)
            );
            wait_for_state(world, STUDIO, "connected")
        },
    );

    // A keyring that refuses.
    steps.step(
        "the system's secure storage is unavailable to the app",
        |world, _, _| {
            world.secrets.refusing.set(true);
            Ok(())
        },
    );
    steps.step("the user pairs a new environment", |world, _, _| {
        pair_studio(world)
    });
    steps.step(
        "the user is told the environment could not be saved",
        |world, _, _| {
            let error = text(&world.state("savedEnvironments")["error"]);
            expect!(
                error == "Studio could not be saved: The system's secure storage is not available.",
                "the user was told \"{error}\""
            );
            Ok(())
        },
    );
    steps.step("the environment is not listed as saved", |world, _, _| {
        let found = world.with::<SavedEnvironments, _>(|c, _| {
            c.catalog().and_then(|c| c.find(STUDIO)).is_some()
        })?;
        expect!(
            listed(world).is_empty() && !found,
            "saved environments are {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "its credential is not written to disk in the clear",
        |world, _, _| {
            let holding = files_holding(world.home_dir(), STUDIO_SESSION);
            let kept = world.secrets.secrets.borrow().is_empty();
            expect!(
                holding.is_empty() && kept,
                "the credential is in {}",
                if holding.is_empty() {
                    "the keyring".to_owned()
                } else {
                    holding.join(", ")
                }
            );
            Ok(())
        },
    );
}
