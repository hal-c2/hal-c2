//! What the client keeps of an environment besides its threads (LocalCache's
//! providers and branch lists): the kept-for-later scenarios of
//! connections/connection-health.feature, desktop-qt's
//! ConnectionKeptSteps.cpp. "studio" is a cluster member that goes down
//! while the shell's own MC stays up; "hal-c2" is a project of the MC's own
//! with a git checkout and a worktree of it.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::store;
use serde_json::{Map, Value, json};

use super::settings::{fake_config, send_config};
use super::workspace::fake_git_repo;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const ROOT: &str = "/work/hal-c2";
const WORKTREE: &str = "/work/hal-c2-fix";

#[derive(Default)]
struct Kept {
    project: String,
    /// Every branch of the checkout.
    branches: Vec<String>,
    /// vcs.listRefs calls left unanswered.
    held_lists: Rc<RefCell<usize>>,
}

fn kept(world: &mut World) -> &mut Kept {
    world.mc.part::<Kept>()
}

fn provider(id: &str, name: &str, slug: &str, model: &str) -> Value {
    json!({"instanceId": id, "driver": id, "displayName": name, "enabled": true,
           "installed": true, "status": "ready",
           "models": [{"slug": slug, "name": model}]})
}

/// The model names the composer's picker offers.
fn offered_models(world: &World) -> Vec<String> {
    world.state("modelPicker")["instances"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|instance| instance["models"].as_array().cloned().unwrap_or_default())
        .map(|model| text(&model["name"]))
        .collect()
}

fn workspace(world: &World) -> Value {
    world.state("workspace")
}

fn shown_branches(world: &World) -> Vec<String> {
    workspace(world)["branches"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|branch| text(&branch["name"]))
        .collect()
}

fn loading(world: &World) -> bool {
    workspace(world)["branchesLoading"].as_bool() == Some(true)
}

/// The branch list kept for `cwd` on the MC's environment, once everything
/// asked of the cache is done.
fn kept_refs(world: &World, cwd: &str) -> Outcome<Option<Map<String, Value>>> {
    let Some(cache) = store::cache(world.engine()) else {
        fail!("the shell keeps no cache");
    };
    let found = Rc::new(RefCell::new(None));
    let slot = found.clone();
    cache.load_refs(&world.mc.environment_id, cwd, move |list| {
        *slot.borrow_mut() = Some(list);
    });
    cache.drain();
    let Some(list) = found.borrow_mut().take() else {
        fail!("the cache did not answer");
    };
    Ok(list)
}

fn names(list: &Map<String, Value>) -> Vec<String> {
    list.get("refs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|r| text(&r["name"]))
        .collect()
}

/// The picker of the open checkout shows the list for `query`, as the MC has it.
fn search(world: &mut World, query: &str) -> Outcome {
    world.dispatch("workspace.branch.search", json!({"query": query}))?;
    let wanted = query.to_owned();
    world.wait_for_with(
        move |w| {
            let shown = shown_branches(w);
            !loading(w) && !shown.is_empty() && shown.iter().all(|name| name.contains(&wanted))
        },
        move |w| {
            format!(
                "the branches for {query:?}; the picker shows {}",
                show(&workspace(w))
            )
        },
    )
}

fn page_to_end(world: &mut World) -> Outcome {
    while (shown_branches(world).len() as i64)
        < workspace(world)["branchesTotal"].as_i64().unwrap_or(0)
    {
        let before = shown_branches(world).len();
        world.dispatch("workspace.branch.more", json!({}))?;
        world.wait_for_with(
            move |w| shown_branches(w).len() > before,
            |w| format!("the next page; the picker shows {}", show(&workspace(w))),
        )?;
    }
    Ok(())
}

/// The MC's project "hal-c2", its checkout holding `branches` on main.
fn project(world: &mut World, branches: &[String]) -> Outcome {
    kept(world).branches = branches.to_vec();
    let row = json!({"id": "hal-c2", "title": "hal-c2", "workspaceRoot": ROOT, "scripts": []});
    world.mc.projects.insert("hal-c2".into(), row.clone());
    world.connect()?;
    let name = world.mc.name.clone();
    world
        .mc
        .send_rows(&name, vec![json!(["hal-c2", "project", row])]);
    let names: Vec<&str> = branches.iter().map(String::as_str).collect();
    fake_git_repo(world, ROOT, &names, "main", "main");
    world.sync()
}

/// A thread of "hal-c2", on its root or a worktree, open in the shell.
fn open_thread(world: &mut World, id: &str, worktree: &str) -> Outcome {
    let mut row = json!({"id": id, "title": id, "projectId": "hal-c2", "branch": "main",
                         "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    if !worktree.is_empty() {
        row["worktreePath"] = json!(worktree);
    }
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
    world.sync()?;
    let key = format!("{}:{id}", world.mc.environment_id);
    let route = key.clone();
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Thread(route)))?;
    world.wait_for_with(
        move |w| text(&workspace(w)["threadKey"]) == key,
        |w| {
            format!(
                "the header to show the thread; it shows {}",
                show(&workspace(w))
            )
        },
    )
}

fn drain(world: &mut World) -> Outcome {
    hal_c2_shell::controllers::threads::drain(world.engine());
    world.pump()
}

pub fn register(steps: &mut Steps) {
    // The models an environment last reported.
    steps.step(
        &format!("{Q} last reported the models {Q} and {Q}"),
        |world, c, _| {
            let environment = c[0].clone();
            let project = format!("project-{environment}");
            kept(world).project = project.clone();
            world.connect()?;
            world.mc.join_named(&environment);
            world.mc.send_peer_row_of(
                &environment,
                &project,
                &json!({"id": project, "title": environment,
                        "workspaceRoot": format!("/work/{environment}"), "scripts": []}),
                "project",
            );
            let providers = vec![
                provider("claudeAgent", "Claude", "claude-sonnet", &c[1]),
                provider("codex", "Codex", "gpt-5", &c[2]),
            ];
            fake_config(&mut world.mc).elsewhere.insert(
                environment.clone(),
                Map::from_iter([("providers".to_owned(), Value::Array(providers.clone()))]),
            );
            send_config(
                &world.mc,
                &environment,
                json!({"t": "config.providers", "providers": providers}),
            );
            world.sync()?;
            // A new task there, while it is up, hears them.
            world.draft_id =
                drafts::start(world.engine(), &environment, &project).unwrap_or_default();
            let (a, b) = (c[1].clone(), c[2].clone());
            world.wait_for_with(
                move |w| {
                    let offered = offered_models(w);
                    offered.contains(&a) && offered.contains(&b)
                },
                |w| {
                    format!(
                        "the models to be offered; the picker offers {:?}",
                        offered_models(w)
                    )
                },
            )?;
            world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))?;
            world.on_settings_page.insert(
                "areOffered".into(),
                Rc::new(|world: &mut World, c: &Vec<String>| {
                    let (a, b) = (c[0].clone(), c[1].clone());
                    world.wait_for_with(
                        move |w| {
                            let offered = offered_models(w);
                            offered.contains(&a) && offered.contains(&b)
                        },
                        |w| format!("the picker offers {:?}", offered_models(w)),
                    )
                }),
            );
            Ok(())
        },
    );
    // Down before the app starts again: nothing of it is in memory, and its
    // MC says nothing of its providers.
    steps.step(&format!("{Q} is not reachable"), |world, c, _| {
        world.quit()?;
        world.mc.set_online(&c[0], false);
        fake_config(&mut world.mc).elsewhere.remove(&c[0]);
        world.launch();
        world.connect()?;
        let environment = c[0].clone();
        world.wait_for("the shell to hear its MC", move |w| {
            store::with(w.engine(), |s| s.serves_environment(&environment))
        })?;
        let environment = c[0].clone();
        expect!(
            !store::with(world.engine(), |s| s.environment_online(&environment)),
            "{} is still online",
            c[0]
        );
        Ok(())
    });
    steps.step(
        &format!("the user starts a new task for {Q}"),
        |world, c, _| {
            let project = kept(world).project.clone();
            world.draft_id = drafts::start(world.engine(), &c[0], &project).unwrap_or_default();
            world.wait_for_with(
                |w| workspace(w)["isDraft"].as_bool() == Some(true),
                |w| show(&workspace(w)),
            )
        },
    );

    // Branch lists.
    steps.step(
        &format!("the user searched the branches of {Q} for {Q}"),
        |world, c, _| {
            expect!(c[0] == "hal-c2", "the steps know hal-c2 only");
            // More than a page of them.
            let mut branches = vec!["main".to_owned()];
            for n in 1..=130 {
                branches.push(if n % 3 != 0 {
                    format!("feature/f{n}")
                } else {
                    format!("{}/f{n}", c[1])
                });
            }
            project(world, &branches)?;
            open_thread(world, "t-root", "")?;
            search(world, "")?;
            // Its first page is not the whole list.
            drain(world)?;
            expect!(
                kept_refs(world, ROOT)?.is_none(),
                "the first page was kept as the whole list"
            );
            page_to_end(world)?;
            search(world, &c[1])
        },
    );
    steps.step(
        &format!("the client keeps the branches of {Q} for later"),
        |world, _, _| {
            world.sync()?;
            drain(world)
        },
    );
    steps.step(
        &format!("the matches for {Q} are not kept"),
        |world, c, _| {
            let Some(list) = kept_refs(world, ROOT)? else {
                fail!("the whole list was not kept");
            };
            let kept_names = names(&list);
            let all = kept(world).branches.len();
            expect!(
                kept_names.len() == all
                    && list.get("totalCount").and_then(Value::as_i64) == Some(all as i64),
                "kept {} of {all} branches ({:?} has {} matches)",
                kept_names.len(),
                c[0],
                kept_names.iter().filter(|n| n.contains(&c[0])).count()
            );
            Ok(())
        },
    );
    steps.step(
        "a branch picker opened offline never presents a partial list as the whole one",
        |world, _, _| {
            world.mc.stop_accepting();
            world.mc.drop_connection();
            world.wait_for("the MC to go", |w| !w.mc.connected())?;
            // A search offline has no matches to show, and shows no others as them.
            world.dispatch("workspace.branch.search", json!({"query": "f1"}))?;
            world.wait_for_with(
                |w| !loading(w) && shown_branches(w).is_empty(),
                |w| format!("offline, the search shows {:?}", shown_branches(w)),
            )?;
            // The picker opened offline: the whole list kept.
            world.dispatch("workspace.branch.search", json!({"query": ""}))?;
            drain(world)?;
            world.wait_for_with(
                |w| !loading(w) && !shown_branches(w).is_empty(),
                |w| show(&workspace(w)),
            )?;
            let all = kept(world).branches.len();
            let shown = shown_branches(world).len();
            let total = workspace(world)["branchesTotal"].as_i64().unwrap_or(0);
            expect!(
                shown == all && total == all as i64,
                "offline, the picker shows {shown} of {total} branches"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the client kept the branch list of {Q} and of a worktree of {Q}"),
        |world, _, _| {
            let branches = ["main", "fix/login", "fix/cart"];
            project(world, &branches.map(str::to_owned))?;
            fake_git_repo(world, WORKTREE, &branches, "fix/login", "main");
            open_thread(world, "t-root", "")?;
            search(world, "")?;
            open_thread(world, "t-worktree", WORKTREE)?;
            search(world, "")?;
            drain(world)?;
            expect!(
                kept_refs(world, ROOT)?.is_some() && kept_refs(world, WORKTREE)?.is_some(),
                "both lists are not kept"
            );
            Ok(())
        },
    );
    steps.step(&format!("a branch of {Q} is created"), |world, _, _| {
        world.dispatch("workspace.branch.create", json!({"name": "fix/tax"}))?;
        world.wait_for_with(
            |w| shown_branches(w).iter().any(|b| b == "fix/tax") && !loading(w),
            |w| {
                format!(
                    "the new branch to be listed; the picker shows {}",
                    show(&workspace(w))
                )
            },
        )
    });
    steps.step(
        "neither kept list is offered again until it is read anew",
        |world, _, _| {
            world.sync()?;
            drain(world)?;
            // The worktree's was read anew after the change, and has the new branch.
            let worktree = kept_refs(world, WORKTREE)?;
            let worktree_kept = worktree.as_ref().map(names).unwrap_or_default();
            expect!(
                worktree.is_none() || worktree_kept.iter().any(|b| b == "fix/tax"),
                "the worktree keeps {worktree_kept:?}"
            );
            expect!(
                kept_refs(world, ROOT)?.is_none(),
                "the root's list from before the change is still kept"
            );
            // The root's picker, before its MC answers, offers nothing kept.
            let held = kept(world).held_lists.clone();
            world.mc.on_rpc("vcs.listRefs", move |_, _| {
                *held.borrow_mut() += 1;
                Ok(())
            });
            open_thread(world, "t-root", "")?;
            world.dispatch("workspace.branch.search", json!({"query": ""}))?;
            let held = kept(world).held_lists.clone();
            world.wait_for("the root's list to be asked for", move |_| {
                *held.borrow() > 0
            })?;
            drain(world)?;
            world.sync()?;
            let shown = shown_branches(world);
            expect!(
                shown.is_empty(),
                "the root's picker offers {shown:?} before the MC answers"
            );
            Ok(())
        },
    );
}
