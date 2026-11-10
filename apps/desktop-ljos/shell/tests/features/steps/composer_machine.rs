//! The machine a thread runs on, as the composer's context strip shows
//! and offers it (WorkspaceController::environmentChoices, Composer.qml's
//! hostPicker), with the workspace and branch beside it
//! (features/composer/model-and-mode.feature). Where a balanced thread
//! starts is the MC's to say (load_balancing.rs fakes `hal-c2.placeThread`).
//! desktop-qt's ComposerMachineSteps.cpp.

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::composer::kept;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::workspace;
use ljos::item::{KeyEvent, key};
use ljos::prelude::{ObjectId, Value as QmlValue, file_url};
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::add_project::{count, prop, role_text, searching};
use crate::steps::composer_brick::{composer_brick, composer_item, composer_part};
use crate::steps::launch::FakeLaunches;
use crate::steps::load_balancing::{FakePlacement, share_project};
use crate::steps::palette::act as palette_act;
use crate::steps::settings::save_elsewhere;
use crate::steps::stream::{self, PROJECT};
use crate::steps::workspace::fake_git_repo;
use crate::world::World;
use crate::{expect, fail};

const ROOT: &str = "/work/shop";
const OTHER: &str = "server";
const PROMPT: &str = "Add tax to the cart";
const WORKTREE: &str = "/work/shop-worktrees/tax-line";
const BRANCH: &str = "hal-c2/tax-line";
const THREAD_ID: &str = "t-machine";

/// What the scenario said of the machines.
#[derive(Default)]
struct Machines {
    /// The machine a name scenario looks at.
    looked: String,
    /// The project is a plain folder: its checkout says it is no repository.
    plain_folder: bool,
}

fn machines(world: &mut World) -> &mut Machines {
    world.mc.part::<Machines>()
}

fn workspace(world: &World) -> Value {
    world.state("workspace")
}

fn environments(world: &World) -> Vec<Value> {
    workspace(world)["environments"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn part(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    match composer_part(world, object_name)? {
        Some(item) => Ok(item),
        None => fail!("the composer shows no {object_name}"),
    }
}

fn host_picker(world: &mut World) -> Outcome<ObjectId> {
    part(world, "hostPicker")
}

fn popup_of(brick: &Brick, world: &World, item: ObjectId) -> Outcome<ObjectId> {
    match brick.read(world, item, "popup") {
        QmlValue::Object(popup) => Ok(popup),
        _ => fail!("{} has no popup", brick.text_of(world, item, "objectName")),
    }
}

fn number(brick: &Brick, world: &World, item: ObjectId, name: &str) -> f64 {
    brick.read(world, item, name).to_number()
}

/// The cluster of the MC's own machine, named `own`, and `other`, both
/// with a checkout of "shop".
fn two_machines(world: &mut World, own: &str, other: &str) -> Outcome {
    world.mc.label = own.to_owned();
    world.mc.announce_environment();
    world
        .mc
        .peer_labels
        .insert(other.to_owned(), other.to_owned());
    world.mc.join(&format!("mc-{other}"), other);
    share_project(&mut world.mc, PROJECT);
    let row = world.mc.projects.get(PROJECT).cloned().unwrap_or(json!({}));
    world.mc.send_row_of(PROJECT, &row, "project");
    world.sync()
}

/// The plain folder's checkout answers that it is no repository.
fn say_plain_folder(world: &mut World) -> Outcome {
    world.wait_for("the shell to follow the folder's checkout", |w| {
        w.mc.subscribers("vcs")
            .iter()
            .any(|id| w.mc.shape_of(*id)["cwd"] == json!(ROOT))
    })?;
    for id in world.mc.subscribers("vcs") {
        if world.mc.shape_of(id)["cwd"] != json!(ROOT) {
            continue;
        }
        world.mc.send(&json!({
            "t": "vcs", "id": id,
            "event": {"_tag": "localUpdated", "local": {"isRepo": false}},
        }));
    }
    world.sync()
}

/// The window on a new thread's draft in "shop", the composer on screen.
fn new_thread(world: &mut World) -> Outcome {
    if text(&world.state("route")["kind"]) != "draft" {
        world.open_draft(PROJECT)?;
        world.wait_for_with(
            |w| workspace(w)["isDraft"] == json!(true),
            |w| format!("the draft; the header shows {}", show(&workspace(w))),
        )?;
    }
    if machines(world).plain_folder {
        say_plain_folder(world)?;
    }
    composer_brick(world)?;
    world.sync()
}

/// The entry of the machine choice the user calls `label`.
fn choice_of(world: &World, label: &str) -> Outcome<i64> {
    let offered = environments(world);
    for (i, choice) in offered.iter().enumerate() {
        if text(&choice["label"]) == label {
            return Ok(i as i64);
        }
    }
    fail!("the composer offers {}", show(&Value::Array(offered)))
}

/// Opens the machine choice and takes its entry `index` with the keyboard.
fn pick_machine(world: &mut World, index: i64) -> Outcome {
    let brick = composer_brick(world)?;
    let picker = host_picker(world)?;
    let popup = popup_of(&brick, world, picker)?;
    world.wait_for_with(
        move |w| !brick.flag(w, popup, "visible"),
        move |w| {
            format!(
                "the machine choice to be closed; it is opened {}, the picker reads \"{}\"",
                brick.flag(w, popup, "opened"),
                brick.text_of(w, picker, "displayText")
            )
        },
    )?;
    expect!(
        brick.flag(world, picker, "visible") && brick.flag(world, picker, "enabled"),
        "the machine choice cannot be opened; the header shows {}",
        show(&workspace(world))
    );
    let (x, y) = brick.at(world, picker, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.wait_for("the machine choice to open", |w| {
        brick.flag(w, popup, "opened")
    })?;
    for _ in 0..8 {
        let at = number(&brick, world, picker, "highlightedIndex") as i64;
        if at == index {
            break;
        }
        brick.press(world, if at < index { "down" } else { "up" })?;
    }
    let at = number(&brick, world, picker, "highlightedIndex") as i64;
    expect!(at == index, "the machine choice offers no entry {index}");
    // The combo box picks the row as Return comes back up.
    brick.press(world, "enter")?;
    world.key(&KeyEvent::release(key::RETURN).with_text("\r"))?;
    world.sync()
}

/// The project on two machines, balancing on, and a new thread's draft open.
fn balanced_draft(world: &mut World) -> Outcome {
    two_machines(world, "laptop", OTHER)?;
    save_elsewhere(&mut world.mc, "loadBalancingEnabled", json!(true), false);
    world.wait_for("the shell to read that balancing is on", |w| {
        Settings::of(w.engine())
            .settings()
            .get("loadBalancingEnabled")
            == Some(&json!(true))
    })?;
    // The MC gives the other machine more room.
    world.mc.part::<FakePlacement>().elsewhere = OTHER.into();
    new_thread(world)
}

fn choose_auto_balance(world: &mut World) -> Outcome {
    let index = choice_of(world, "Auto balance")?;
    pick_machine(world, index)?;
    let brick = composer_brick(world)?;
    let picker = host_picker(world)?;
    world.wait_for_with(
        move |w| brick.text_of(w, picker, "displayText") == "Auto balance",
        move |w| {
            format!(
                "Auto balance; the picker reads \"{}\"",
                brick.text_of(w, picker, "displayText")
            )
        },
    )
}

/// Picks "Auto balance" in the machine choice; a draft with files refuses it.
pub(crate) fn pick_auto_balance(world: &mut World) -> Outcome {
    let index = choice_of(world, "Auto balance")?;
    pick_machine(world, index)
}

fn send_first_message(world: &mut World) -> Outcome {
    world.dispatch(
        "composer.submit",
        json!({"text": PROMPT, "intent": "foreground"}),
    )
}

/// A started thread of "shop" on the MC's own machine.
fn have_thread(world: &mut World, more: Value) -> Outcome {
    let mut row = json!({
        "id": THREAD_ID, "title": "Tax line", "projectId": PROJECT,
        "latestUserMessageAt": "2026-09-23T09:00:00Z",
        "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z",
    });
    if let (Some(row), Some(more)) = (row.as_object_mut(), more.as_object()) {
        for (key, value) in more {
            row.insert(key.clone(), value.clone());
        }
    }
    world.mc.threads.insert(THREAD_ID.into(), row.clone());
    world.mc.send_row(THREAD_ID, &row);
    world.sync()
}

/// The window on that thread, its context strip kept on screen.
fn look_at_thread(world: &mut World) -> Outcome {
    // A started thread's strip stays only with the setting that keeps it.
    let engine = world.engine().clone();
    Settings::of(&engine).set(&engine, "persistComposerContextStrip", json!(true));
    let key = format!("{}:{THREAD_ID}", world.mc.environment_id);
    stream::look(world, &key, true)?;
    let wanted = key.clone();
    world.wait_for_with(
        move |w| workspace(w)["threadKey"] == json!(wanted),
        move |w| format!("the thread; the header shows {}", show(&workspace(w))),
    )?;
    composer_brick(world)?;
    world.sync()
}

fn locked_label(world: &mut World) -> Outcome<String> {
    let brick = composer_brick(world)?;
    let label = part(world, "envModeLockedLabel")?;
    Ok(brick.text_of(world, label, "text"))
}

/// The three controls are on screen side by side, none over another.
fn separate_controls(world: &mut World) -> Outcome {
    let brick = composer_brick(world)?;
    let controls = [
        host_picker(world)?,
        part(world, "envModePicker")?,
        part(world, "branchButton")?,
    ];
    world.wait_for_with(
        move |w| {
            controls.iter().all(|item| {
                brick.flag(w, *item, "visible") && number(&brick, w, *item, "width") > 0.0
            })
        },
        move |w| {
            format!(
                "the machine, workspace and branch; the header shows {}",
                show(&workspace(w))
            )
        },
    )?;
    let rects: Vec<(f64, f64, f64, f64, String)> = controls
        .iter()
        .map(|item| {
            let (x, y) = brick.at(world, *item, 0.0, 0.0)?;
            Ok((
                x,
                y,
                number(&brick, world, *item, "width"),
                number(&brick, world, *item, "height"),
                brick.text_of(world, *item, "objectName"),
            ))
        })
        .collect::<Outcome<Vec<_>>>()?;
    for (i, a) in rects.iter().enumerate() {
        for b in &rects[i + 1..] {
            let overlaps = a.0 < b.0 + b.2 && b.0 < a.0 + a.2 && a.1 < b.1 + b.3 && b.1 < a.1 + a.3;
            expect!(!overlaps, "{} and {} overlap", a.4, b.4);
        }
    }
    Ok(())
}

pub fn register(steps: &mut Steps) {
    // The controls side by side (upstream #27114).
    steps.step(
        "the project can run on more than one machine",
        |world, _, _| {
            two_machines(world, "laptop", OTHER)?;
            fake_git_repo(world, ROOT, &["main"], "main", "main");
            Ok(())
        },
    );
    steps.step(
        "the user starts a new thread at the default chat width",
        |world, _, _| new_thread(world),
    );
    steps.step(
        "the composer shows the machine, whether it works locally or in a new worktree, and the branch as separate controls",
        |world, _, _| separate_controls(world),
    );
    // The desktop's strip has no folded control: a narrow window keeps the three.
    steps.step(
        "only a phone-width composer folds the machine and workspace into one control",
        |world, _, _| {
            let item = composer_item(world)?;
            world
                .engine()
                .write_by_name(item, "width", QmlValue::Real(520.0))
                .map_err(|e| {
                    crate::harness::Failure(format!("the composer's width cannot be set: {e:?}"))
                })?;
            world.sync()?;
            separate_controls(world)
        },
    );

    // A plain folder (upstream #21404).
    steps.step(
        "the project is a plain folder with no Git repository",
        |world, _, _| {
            machines(world).plain_folder = true;
            Ok(())
        },
    );
    steps.step(
        "the last thread was started in a new worktree, or a saved draft asked for one",
        |world, _, _| {
            save_elsewhere(
                &mut world.mc,
                "defaultThreadEnvMode",
                json!("worktree"),
                false,
            );
            world.sync()
        },
    );
    steps.step("the thread works in the project's folder", |world, _, _| {
        new_thread(world)?;
        let draft_id = world.draft_id.clone();
        let asked = workspace::checkout(world.engine(), &draft_id).env_mode;
        expect!(
            asked == "worktree",
            "the draft did not ask for a new worktree; the header shows {}",
            show(&workspace(world))
        );
        world.wait_for_with(
            |w| {
                workspace(w)["envMode"] == json!("local") && locked_label_now(w) == "Local checkout"
            },
            |w| {
                format!(
                    "the folder; the label reads \"{}\", the header shows {}",
                    locked_label_now(w),
                    show(&workspace(w))
                )
            },
        )?;
        let where_ = workspace::launch(world.engine(), &draft_id);
        expect!(
            where_.problem.is_empty()
                && Value::Object(where_.strategy.clone()) == json!({"type": "root"}),
            "the thread would start in {} ({})",
            show(&Value::Object(where_.strategy.clone())),
            where_.problem
        );
        Ok(())
    });
    steps.step("no branch or worktree can be chosen", |world, _, _| {
        let brick = composer_brick(world)?;
        let picker = part(world, "envModePicker")?;
        let locked = part(world, "envModeLocked")?;
        let branch = part(world, "branchButton")?;
        let ws = workspace(world);
        expect!(
            !brick.flag(world, picker, "visible")
                && brick.flag(world, locked, "visible")
                && !brick.flag(world, branch, "visible")
                && ws["envModeChangeable"] != json!(true)
                && ws["branchChangeable"] != json!(true),
            "the header shows {}",
            show(&ws)
        );
        // Asking anyway changes nothing.
        world.dispatch("workspace.envMode.set", json!({"mode": "worktree"}))?;
        world.sync()?;
        expect!(
            workspace(world)["envMode"] == json!("local"),
            "the header shows {}",
            show(&workspace(world))
        );
        Ok(())
    });

    // A worktree being checked out (upstream #13590).
    steps.step(
        "the user started a thread in a new worktree",
        |world, _, _| {
            fake_git_repo(world, ROOT, &["main"], "main", "main");
            fake_git_repo(world, WORKTREE, &["main", BRANCH], BRANCH, "main");
            have_thread(world, json!({}))
        },
    );
    steps.step("the worktree is still being checked out", |world, _, _| {
        // The MC holds the run "preparing" until the worktree is there.
        have_thread(
            world,
            json!({"status": "preparing", "activeRunId": "run-1"}),
        )?;
        look_at_thread(world)
    });
    steps.step("the checkout finishes", |world, _, _| {
        have_thread(
            world,
            json!({"status": "running", "activeRunId": "run-1",
                   "branch": BRANCH, "worktreePath": WORKTREE}),
        )
    });
    steps.step(&format!("the workspace label reads {Q}"), |world, c, _| {
        composer_brick(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(
            {
                let wanted = wanted.clone();
                move |w| locked_shown(w) && locked_label_now(w) == wanted
            },
            move |w| {
                format!(
                    "\"{wanted}\"; the label reads \"{}\", the header shows {}",
                    locked_label_now(w),
                    show(&workspace(w))
                )
            },
        )
    });

    // One project for every checkout of a repository (upstream #22242).
    steps.step(
        &format!("{Q} has checkouts on {Q} and {Q}"),
        |world, c, _| {
            expect!(c[0] == "shop", "the open thread's project is shop");
            two_machines(world, &c[1], &c[2])
        },
    );
    steps.step(
        "the user opens the project picker for a new thread",
        |world, _, _| {
            let ran = Commands::of(world.engine()).run(world.engine(), "thread.newIn");
            expect!(ran, "New thread in... is not a command");
            world.sync()
        },
    );
    steps.step(&format!("{Q} is listed once"), |world, c, _| {
        world.wait_for("the palette's New thread in...", |w| {
            prop(w, "submenu").unwrap_or_default() == "New thread in..." && !searching(w)
        })?;
        let titles: Vec<String> = (0..count(world))
            .map(|row| role_text(world, row, "title"))
            .collect();
        expect!(
            titles.iter().filter(|t| **t == c[0]).count() == 1,
            "the palette lists {}",
            titles.join(", ")
        );
        let row = titles.iter().position(|t| *t == c[0]).unwrap_or(0) as i32;
        let ran = palette_act(world, |p, engine| p.run(engine, row))?;
        expect!(ran, "{} cannot be chosen", c[0]);
        let wanted = c[0].clone();
        world.wait_for_with(
            {
                let wanted = wanted.clone();
                move |w| {
                    let ws = workspace(w);
                    ws["isDraft"] == json!(true) && text(&ws["projectTitle"]) == wanted
                }
            },
            move |w| {
                format!(
                    "a draft in {wanted}; the header shows {}",
                    show(&workspace(w))
                )
            },
        )
    });
    steps.step("both machines are offered under it", |world, _, _| {
        let brick = composer_brick(world)?;
        world.sync()?;
        let labels: Vec<String> = environments(world)
            .iter()
            .map(|c| text(&c["label"]).to_owned())
            .collect();
        let picker = host_picker(world)?;
        let shown = brick.flag(world, picker, "visible");
        expect!(
            labels == ["laptop", OTHER] && shown && brick.flag(world, picker, "enabled"),
            "the machine choice offers {} (shown {shown})",
            labels.join(", ")
        );
        Ok(())
    });

    // Auto balance.
    steps.step(
        "the project exists on two connected machines and load balancing is on",
        |world, _, _| balanced_draft(world),
    );
    steps.step(
        "the user chose \"Auto balance\" for a new thread",
        |world, _, _| {
            balanced_draft(world)?;
            choose_auto_balance(world)
        },
    );
    // The draft is open already; a draft with files refuses the choice.
    steps.step(
        "the user chooses \"Auto balance\" as the machine a new thread runs on",
        |world, _, _| pick_auto_balance(world),
    );
    steps.step(
        "the thread starts on the machine with the most room when the first message is sent",
        |world, _, _| {
            send_first_message(world)?;
            world.wait_for("a launch; the MC got none", |w| {
                w.mc.peek::<FakeLaunches>()
                    .is_some_and(|l| !l.calls.is_empty())
            })?;
            let asked = world.mc.part::<FakePlacement>().asked.len();
            let launches = world.mc.part::<FakeLaunches>();
            let (calls, machines) = (launches.calls.len(), launches.machines.clone());
            expect!(
                asked == 1 && calls == 1 && machines.last().map(String::as_str) == Some(OTHER),
                "the MC was asked {asked} times and the thread launched on {}",
                machines.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user chooses the machine {Q} instead"),
        |world, c, _| {
            let index = choice_of(world, &c[0])?;
            pick_machine(world, index)?;
            expect_picker_reads(world, &c[0])?;
            // A machine the user picks is where the thread starts: the MC is not asked.
            world.mc.part::<FakePlacement>().tied = true;
            Ok(())
        },
    );
    steps.step(
        "the draft of a new thread has an attached file",
        |world, _, _| {
            balanced_draft(world)?;
            let dir = world.home_dir().join("documents");
            std::fs::create_dir_all(&dir).map_err(|e| crate::harness::Failure(e.to_string()))?;
            let file = dir.join("schema.sql");
            std::fs::write(&file, "create table carts (id integer);\n")
                .map_err(|e| crate::harness::Failure(e.to_string()))?;
            let item = composer_item(world)?;
            let urls = vec![QmlValue::from(file_url(&file).as_str())];
            world
                .engine()
                .invoke_by_name(item, "attach", &[QmlValue::List(std::sync::Arc::new(urls))])
                .map_err(|e| crate::harness::Failure(format!("attach: {e:?}")))?;
            let draft_id = world.draft_id.clone();
            world.wait_for_with(
                move |w| kept::holds_files(w.engine(), &draft_id),
                |w| {
                    format!(
                        "the file attached; the composer shows {}",
                        show(&w.state("composer")["attachments"])
                    )
                },
            )?;
            expect_picker_reads(world, "laptop")
        },
    );
    steps.step(
        &format!("the user is told {Q} and to remove them first"),
        |world, c, _| {
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| {
                    w.state("toasts")["items"].as_array().is_some_and(|items| {
                        items.iter().any(|t| {
                            text(&t["title"]) == wanted
                                && text(&t["description"]).starts_with(
                                    "Remove attachments before choosing automatic routing",
                                )
                        })
                    })
                },
                |w| format!("the notice; the toasts are {}", show(&w.state("toasts"))),
            )
        },
    );
    steps.step(
        "the thread still runs on the machine it was on",
        |world, _, _| {
            world.sync()?;
            let draft_id = world.draft_id.clone();
            let where_ = workspace::launch(world.engine(), &draft_id);
            let reads = picker_text(world)?;
            expect!(
                reads == "laptop" && where_.environment_id == world.mc.environment_id,
                "the picker reads \"{reads}\" and the thread would start on {}",
                where_.environment_id
            );
            Ok(())
        },
    );

    // The machine's name.
    steps.step(
        "the machine is (the one being used|another one) and its own name is \"([^\"]*)\" and the user named it \"([^\"]*)\"",
        |world, c, _| {
            let own = c[0] == "the one being used";
            // desktop-ljos keeps no name the user saved for a machine: the
            // cluster's name for it is the one it has.
            expect!(
                c[2].is_empty() || !c[1].trim().is_empty() && c[1] != "local",
                "desktop-ljos keeps no name the user saved for a machine (hal-c2/hal-c2#1515)"
            );
            let id = if own {
                two_machines(world, &c[1], OTHER)?;
                world.mc.environment_id.clone()
            } else {
                world.mc.label = "laptop".into();
                world.mc.announce_environment();
                world.mc.peer_labels.insert(OTHER.into(), c[1].clone());
                world.mc.join(&format!("mc-{OTHER}"), OTHER);
                share_project(&mut world.mc, PROJECT);
                let row = world.mc.projects.get(PROJECT).cloned().unwrap_or(json!({}));
                world.mc.send_row_of(PROJECT, &row, "project");
                world.sync()?;
                OTHER.to_owned()
            };
            machines(world).looked = id;
            Ok(())
        },
    );
    steps.step(
        "the user opens the choice of machine for a new thread",
        |world, _, _| {
            new_thread(world)?;
            let brick = composer_brick(world)?;
            let picker = host_picker(world)?;
            let popup = popup_of(&brick, world, picker)?;
            let (x, y) = brick.at(world, picker, 0.5, 0.5)?;
            world.click_at(x, y)?;
            world.wait_for("the machine choice to open", move |w| {
                brick.flag(w, popup, "opened")
            })
        },
    );
    steps.step(&format!("the machine reads {Q}"), |world, c, _| {
        let offered = environments(world);
        let brick = composer_brick(world)?;
        let picker = host_picker(world)?;
        let looked = machines(world).looked.clone();
        for (i, choice) in offered.iter().enumerate() {
            if text(&choice["environmentId"]) != looked {
                continue;
            }
            let label =
                match world
                    .engine()
                    .invoke_by_name(picker, "textAt", &[QmlValue::Int(i as i32)])
                {
                    Ok(value) => ljos_text(&value),
                    Err(_) => text(&choice["label"]).to_owned(),
                };
            let _ = &brick;
            expect!(
                label == c[0],
                "the machine reads \"{label}\"; the choice offers {}",
                show(&Value::Array(offered.clone()))
            );
            return Ok(());
        }
        fail!("the machine choice offers {}", show(&Value::Array(offered)))
    });

    // Whether the machine is shown, and whether it can change (upstream #19900).
    steps.step(
        &format!("the project runs on a remote machine {Q} and no other machine is connected"),
        |world, c, _| {
            world.mc.label = c[0].clone();
            world.served_from(&format!("machine-{}", c[0]))
        },
    );
    steps.step(
        "the project runs on the machine being used and no other machine is connected",
        |world, _, _| {
            world.mc.label = "laptop".into();
            world.mc.announce_environment();
            world.sync()
        },
    );
    steps.step(
        "the user looks at a new thread's composer",
        |world, _, _| new_thread(world),
    );
    steps.step(
        &format!("a thread has started on the machine {Q} in a project on several machines"),
        |world, c, _| {
            two_machines(world, &c[0], "laptop")?;
            have_thread(world, json!({}))
        },
    );
    steps.step("the user looks at the thread's composer", |world, _, _| {
        look_at_thread(world)
    });
    steps.step(&format!("the machine {Q} is shown"), |world, c, _| {
        let brick = composer_brick(world)?;
        let picker = host_picker(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(
            {
                let wanted = wanted.clone();
                move |w| {
                    brick.flag(w, picker, "visible")
                        && brick.text_of(w, picker, "displayText") == wanted
                }
            },
            move |w| {
                format!(
                    "{wanted}; shown {}, the picker reads \"{}\", the header shows {}",
                    brick.flag(w, picker, "visible"),
                    brick.text_of(w, picker, "displayText"),
                    show(&workspace(w))
                )
            },
        )
    });
    steps.step("it cannot be changed", |world, _, _| {
        let brick = composer_brick(world)?;
        let picker = host_picker(world)?;
        expect!(
            !brick.flag(world, picker, "enabled")
                && workspace(world)["environmentChangeable"] != json!(true)
                && environments(world).len() == 1,
            "the machine choice offers {}",
            show(&Value::Array(environments(world)))
        );
        Ok(())
    });
    steps.step(
        "no other machine is offered, by the menu or by the machine shortcut",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let picker = host_picker(world)?;
            expect!(
                !brick.flag(world, picker, "enabled") && environments(world).len() == 1,
                "the machine choice offers {}",
                show(&Value::Array(environments(world)))
            );
            let ran = Commands::of(world.engine()).run(world.engine(), "composer.host");
            expect!(ran, "composer.host is not a command");
            world.sync()?;
            let popup = popup_of(&brick, world, picker)?;
            expect!(
                !brick.flag(world, popup, "visible"),
                "the machine shortcut opened the machine choice"
            );
            Ok(())
        },
    );
    steps.step("no machine is shown", |world, _, _| {
        world.sync()?;
        let brick = composer_brick(world)?;
        let picker = host_picker(world)?;
        expect!(
            !brick.flag(world, picker, "visible")
                && workspace(world)["environmentShown"] != json!(true),
            "the header shows {}",
            show(&workspace(world))
        );
        Ok(())
    });
}

fn ljos_text(value: &QmlValue) -> String {
    match value {
        QmlValue::String(s) => s.to_string(),
        other => format!("{other:?}"),
    }
}

fn picker_text(world: &mut World) -> Outcome<String> {
    let brick = composer_brick(world)?;
    let picker = host_picker(world)?;
    Ok(brick.text_of(world, picker, "displayText"))
}

fn expect_picker_reads(world: &mut World, wanted: &str) -> Outcome {
    let brick = composer_brick(world)?;
    let picker = host_picker(world)?;
    let wanted = wanted.to_owned();
    world.wait_for_with(
        {
            let wanted = wanted.clone();
            move |w| brick.text_of(w, picker, "displayText") == wanted
        },
        move |w| {
            format!(
                "{wanted}; the picker reads \"{}\"",
                brick.text_of(w, picker, "displayText")
            )
        },
    )
}

fn locked_part(world: &World, name: &str) -> Option<(Brick, ObjectId)> {
    let brick = crate::steps::composer_brick::composer_brick_now(world)?;
    let item = crate::steps::composer_brick::composer_part_now(world, name)?;
    Some((brick, item))
}

fn locked_shown(world: &World) -> bool {
    locked_part(world, "envModeLocked").is_some_and(|(b, i)| b.flag(world, i, "visible"))
}

fn locked_label_now(world: &World) -> String {
    locked_part(world, "envModeLockedLabel")
        .map(|(b, i)| b.text_of(world, i, "text"))
        .unwrap_or_default()
}
