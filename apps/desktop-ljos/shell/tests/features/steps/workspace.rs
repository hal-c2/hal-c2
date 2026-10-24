//! The workspace header and the composer's context strip (Workspace), and
//! the MC's git behind them (desktop-qt's WorkspaceSteps.cpp):
//! features/navigation/header.feature, navigation/layout.feature,
//! threads/titles.feature, source-control/refs-and-branches.feature and
//! source-control/worktrees-and-setup-scripts.feature.
//!
//! Not ported here, as they sit on helpers other step files own: the
//! editors a `config` shape lists (FakeConfig, SettingsSteps), renaming a
//! managed folder or a provider instance (FilesFolders, ProviderSettings) and
//! the archive's list (ArchivedThreads), and the draft that a branch ties to
//! a machine (LoadBalancing's cluster).

use std::collections::{BTreeMap, HashSet};
use std::rc::Rc;

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::workspace as shell_workspace;
use serde_json::{Value, json};

use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const THREAD: &str = "t1";

#[derive(Clone, Default)]
pub struct Repo {
    /// Most recently committed first.
    pub branches: Vec<String>,
    pub current: String,
    pub default_branch: String,
}

/// The MC's checkouts, by folder: `vcs` status frames, `vcs.listRefs` (the
/// current branch first, the default next, the rest most recently committed
/// first, as the MC orders them), `vcs.switchRef` and `vcs.createRef`.
#[derive(Default)]
pub struct FakeGit {
    pub repos: BTreeMap<String, Repo>,
    /// Git's explanation, when a switch fails.
    pub refuse_switch: String,
    /// Every shell.openInEditor payload.
    pub editor_calls: Vec<Value>,
    /// The cursor of every vcs.listRefs.
    pub ref_pages: Vec<i64>,
}

fn local_status(repo: &Repo) -> Value {
    json!({"isRepo": true, "refName": repo.current, "hasWorkingTreeChanges": false})
}

fn send_status(mc: &mut FakeMc, cwd: &str) {
    let repo = mc
        .part::<FakeGit>()
        .repos
        .get(cwd)
        .cloned()
        .unwrap_or_default();
    for id in mc.subscribers("vcs") {
        if text(&mc.shape_of(id)["cwd"]) != cwd {
            continue;
        }
        mc.send(&json!({"t": "vcs", "id": id, "event": {
            "_tag": "localUpdated", "local": local_status(&repo)}}));
    }
}

fn ordered_refs(repo: &Repo, query: &str) -> Vec<Value> {
    let mut names: Vec<&String> = Vec::new();
    if repo.branches.contains(&repo.current) {
        names.push(&repo.current);
    }
    if repo.default_branch != repo.current && repo.branches.contains(&repo.default_branch) {
        names.push(&repo.default_branch);
    }
    for branch in &repo.branches {
        if !names.contains(&branch) {
            names.push(branch);
        }
    }
    names
        .into_iter()
        .filter(|name| query.is_empty() || name.to_lowercase().contains(&query.to_lowercase()))
        .map(|name| {
            json!({"name": name, "current": *name == repo.current,
                   "isDefault": *name == repo.default_branch, "isRemote": false})
        })
        .collect()
}

/// The orchestration projection of `thread.metadata.update` on the MC's rows.
fn apply_metadata(mc: &mut FakeMc, command: &Value) {
    if command["type"] != "thread.metadata.update" {
        return;
    }
    let id = text(&command["threadId"]);
    let Some(row) = mc.threads.get_mut(&id) else {
        return;
    };
    for field in ["title", "branch", "worktreePath"] {
        if command.get(field).is_none() {
            continue;
        }
        if command[field].is_null() {
            row.as_object_mut().map(|row| row.remove(field));
        } else {
            row[field] = command[field].clone();
        }
    }
    let row = row.clone();
    mc.send_row(&id, &row);
}

fn extension(mc: &mut FakeMc) {
    mc.effects.push(Rc::new(apply_metadata));
    // The checkouts a domain fakes whole (GitSteps) answer first.
    mc.on_shape("vcs", |mc, id, shape| {
        let cwd = text(&shape["cwd"]);
        let event = if let Some(status) = mc.checkouts.get(&cwd).cloned() {
            let status = status(mc);
            json!({"_tag": "snapshot", "local": status["local"], "remote": status["remote"]})
        } else {
            let local = match mc.part::<FakeGit>().repos.get(&cwd) {
                Some(repo) => local_status(repo),
                None => json!({"isRepo": false}),
            };
            json!({"_tag": "snapshot", "local": local, "remote": {}})
        };
        mc.send(&json!({"t": "vcs", "id": id, "event": event}));
        Ok(())
    });
    mc.on_rpc("vcs.listRefs", |mc, rpc| {
        let repo = mc
            .part::<FakeGit>()
            .repos
            .get(&text(&rpc.payload["cwd"]))
            .cloned()
            .unwrap_or_default();
        let all = ordered_refs(&repo, &text(&rpc.payload["query"]));
        let limit = rpc.payload["limit"].as_i64().unwrap_or(100);
        let cursor = rpc.payload["cursor"].as_i64().unwrap_or(0);
        mc.part::<FakeGit>().ref_pages.push(cursor);
        let page: Vec<Value> = all
            .iter()
            .skip(cursor as usize)
            .take(limit as usize)
            .cloned()
            .collect();
        let next = if all.len() as i64 > cursor + limit {
            json!(cursor + limit)
        } else {
            Value::Null
        };
        mc.reply(
            rpc,
            json!({"refs": page, "isRepo": true, "hasPrimaryRemote": false,
                   "nextCursor": next, "totalCount": all.len()}),
        );
        Ok(())
    });
    mc.on_rpc("vcs.switchRef", |mc, rpc| {
        let refuse = mc.part::<FakeGit>().refuse_switch.clone();
        if !refuse.is_empty() {
            mc.refuse(rpc, &refuse);
            return Ok(());
        }
        let cwd = text(&rpc.payload["cwd"]);
        let name = text(&rpc.payload["refName"]);
        mc.part::<FakeGit>()
            .repos
            .entry(cwd.clone())
            .or_default()
            .current = name.clone();
        send_status(mc, &cwd);
        mc.reply(rpc, json!({"refName": name}));
        Ok(())
    });
    mc.on_rpc("vcs.createRef", |mc, rpc| {
        let cwd = text(&rpc.payload["cwd"]);
        let name = text(&rpc.payload["refName"]);
        {
            let repo = mc.part::<FakeGit>().repos.entry(cwd.clone()).or_default();
            repo.branches.insert(0, name.clone());
            if rpc.payload["switchRef"].as_bool() == Some(true) {
                repo.current = name.clone();
            }
        }
        send_status(mc, &cwd);
        mc.reply(rpc, json!({"refName": name}));
        Ok(())
    });
    mc.on_rpc("shell.openInEditor", |mc, rpc| {
        mc.part::<FakeGit>().editor_calls.push(rpc.payload.clone());
        mc.reply(rpc, Value::Null);
        Ok(())
    });
}

fn workspace(world: &World) -> Value {
    world.state("workspace")
}

fn root(project: &str) -> String {
    format!("/work/{project}")
}

/// The project on the MC, sent again when the shell is already connected.
fn put_project(world: &mut World, project: &str, fields: Value) {
    let mut row = world
        .mc
        .projects
        .get(project)
        .cloned()
        .unwrap_or(Value::Null);
    if row.is_null() {
        row =
            json!({"id": project, "title": project, "workspaceRoot": root(project), "scripts": []});
    }
    if let Some(fields) = fields.as_object() {
        for (key, value) in fields {
            row[key] = value.clone();
        }
    }
    world.mc.projects.insert(project.to_owned(), row.clone());
    let name = world.mc.name.clone();
    world
        .mc
        .send_rows(&name, vec![json!([project, "project", row])]);
}

fn put_thread(world: &mut World, id: &str, fields: Value) {
    let mut row = json!({"id": id, "createdAt": "2026-09-23T09:00:00Z",
                         "updatedAt": "2026-09-23T09:00:00Z"});
    if let Some(fields) = fields.as_object() {
        for (key, value) in fields {
            row[key] = value.clone();
        }
    }
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
}

fn git_repo(world: &mut World, project: &str, branches: &[&str], current: &str, default: &str) {
    world.mc.part::<FakeGit>().repos.insert(
        root(project),
        Repo {
            branches: branches.iter().map(|b| (*b).to_owned()).collect(),
            current: current.to_owned(),
            default_branch: default.to_owned(),
        },
    );
}

fn open(world: &mut World, thread_key: &str) -> Outcome {
    let key = thread_key.to_owned();
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Thread(key)))?;
    world.wait_for_with(
        |w| workspace(w)["threadKey"] == thread_key,
        |w| {
            format!(
                "the header to show {thread_key}; it shows {}",
                show(&workspace(w))
            )
        },
    )
}

fn open_draft(world: &mut World, project: &str) -> Outcome {
    world.open_draft(project)?;
    world.wait_for_with(
        |w| workspace(w)["isDraft"].as_bool() == Some(true),
        |w| {
            format!(
                "the header to show the draft; it shows {}",
                show(&workspace(w))
            )
        },
    )
}

fn thread_key(world: &World) -> String {
    format!("{}:{THREAD}", world.mc.environment_id)
}

fn dispatch(world: &mut World, action: &str, payload: Value) -> Outcome {
    world.dispatch(action, payload)?;
    // What it asked of the MC has been answered.
    world.sync()
}

fn branch_names(world: &World) -> Vec<String> {
    workspace(world)["branches"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|b| text(&b["name"]))
        .collect()
}

fn branch_at(world: &World, index: usize) -> Outcome<Value> {
    match workspace(world)["branches"]
        .as_array()
        .and_then(|b| b.get(index))
    {
        Some(branch) => Ok(branch.clone()),
        None => fail!("the branch list is {}", branch_names(world).join(", ")),
    }
}

/// The sidebar's row for the thread, in whichever section.
fn sidebar_row(world: &World, key: &str) -> Option<Value> {
    let sidebar = world.state("sidebar");
    for (_, section) in sidebar.as_object()? {
        for row in section.as_array().into_iter().flatten() {
            if row["key"] == key {
                return Some(row.clone());
            }
        }
    }
    None
}

fn editor_label(id: &str) -> String {
    match id {
        "vscode" => "VS Code",
        "zed" => "Zed",
        "cursor" => "Cursor",
        "default" => "Default Editor",
        other => other,
    }
    .to_owned()
}

fn editor_id(label: &str) -> String {
    for id in ["vscode", "zed", "cursor", "default"] {
        if editor_label(id) == label {
            return id.to_owned();
        }
    }
    label.to_owned()
}

fn titled(world: &World, title: &str) -> bool {
    let row = sidebar_row(world, &thread_key(world));
    row.is_some_and(|row| row["title"] == title) && workspace(world)["threadTitle"] == title
}

fn describe_title(world: &World) -> String {
    let row = sidebar_row(world, &thread_key(world));
    format!(
        "the thread list shows {} and the header {}",
        row.map(|r| show(&r)).unwrap_or_else(|| "no row".into()),
        text(&workspace(world)["threadTitle"])
    )
}

fn current_repo(world: &mut World) -> Repo {
    let project = text(&workspace(world)["projectTitle"]);
    world
        .mc
        .part::<FakeGit>()
        .repos
        .get(&root(&project))
        .cloned()
        .unwrap_or_default()
}

fn expect_editor_call(world: &mut World, editor: &str, cwd: &str) -> Outcome {
    let calls = world.mc.part::<FakeGit>().editor_calls.clone();
    let last = calls.last();
    expect!(
        last.is_some_and(|c| c["editor"] == editor && c["cwd"] == cwd),
        "the MC was asked {}",
        last.map(show).unwrap_or_else(|| "nothing".into())
    );
    Ok(())
}

fn starts_in(world: &mut World, mode: &str, label: &str) -> Outcome {
    let state = workspace(world);
    let draft = world.draft_id.clone();
    let checkout = shell_workspace::checkout(world.engine(), &draft);
    expect!(
        state["envMode"] == mode && state["envModeLabel"] == label && checkout.env_mode == mode,
        "the header shows {}",
        show(&state)
    );
    Ok(())
}

/// A thread the user just finished in a worktree of its own.
fn finished_in(world: &mut World, branch: &str) -> Outcome {
    let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
    let worktree = format!("{}-worktrees/{}", root(&project), branch.replace('/', "-"));
    let row = json!({"id": "t-done", "title": "Tax line", "projectId": project,
        "branch": branch, "worktreePath": worktree,
        "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T10:00:00Z"});
    world.mc.threads.insert("t-done".into(), row.clone());
    world.mc.send_row("t-done", &row);
    world.sync()
}

/// The checkout of the draft the navigation shows.
fn draft_checkout(world: &World) -> shell_workspace::Checkout {
    shell_workspace::checkout(world.engine(), &text(&world.state("route")["draftId"]))
}

fn uses_previous(world: &mut World, branch: &str) -> Outcome {
    world.wait_for_with(
        |w| draft_checkout(w).worktree_path.is_some(),
        |w| {
            format!(
                "the draft to use the previous worktree; the header shows {}",
                show(&workspace(w))
            )
        },
    )?;
    let checkout = draft_checkout(world);
    expect!(
        checkout.branch.as_deref() == Some(branch)
            && checkout.env_mode == "worktree"
            && checkout
                .worktree_path
                .as_deref()
                .is_some_and(|p| p.ends_with(&branch.replace('/', "-"))),
        "the draft is on {} at {}",
        checkout.branch.unwrap_or_else(|| "no branch".into()),
        checkout.worktree_path.unwrap_or_default()
    );
    Ok(())
}

/// Rows of other step files use the checkout of a project with these
/// branches, `current` checked out and the default.
pub fn seed_branches(world: &mut World, project: &str, branches: &[&str], current: &str) {
    git_repo(world, project, branches, current, current);
}

/// Makes `cwd` a git repository with these branches, `current` checked out,
/// and says so to whoever follows it.
pub fn fake_git_repo(
    world: &mut World,
    cwd: &str,
    branches: &[&str],
    current: &str,
    default_branch: &str,
) {
    world.mc.part::<FakeGit>().repos.insert(
        cwd.to_owned(),
        Repo {
            branches: branches.iter().map(|b| (*b).to_owned()).collect(),
            current: current.to_owned(),
            default_branch: default_branch.to_owned(),
        },
    );
    send_status(&mut world.mc, cwd);
}

fn project_row(project: &str) -> Value {
    json!({"id": project, "title": project, "workspaceRoot": root(project), "scripts": []})
}

fn thread_row(title: &str, project: &str) -> Value {
    json!({"id": THREAD, "title": title, "projectId": project,
           "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"})
}

fn first_project(world: &World) -> String {
    world.mc.projects.keys().next().cloned().unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Backgrounds.
    steps.step(
        &format!("a connected environment with the thread {Q} in the project {Q}"),
        |world, c, _| {
            world.mc.projects.insert(c[1].clone(), project_row(&c[1]));
            world
                .mc
                .threads
                .insert(THREAD.into(), thread_row(&c[0], &c[1]));
            world.connect()?;
            let key = thread_key(world);
            open(world, &key)
        },
    );
    steps.step(
        &format!("a connected environment with a thread in the git project {Q} on the branch {Q}"),
        |world, c, _| {
            let mut project = project_row(&c[0]);
            project["repositoryIdentity"] =
                json!({"canonicalKey": format!("github.com/acme/{}", c[0])});
            world.mc.projects.insert(c[0].clone(), project);
            let mut thread = thread_row("Tax line", &c[0]);
            thread["branch"] = json!(c[1]);
            world.mc.threads.insert(THREAD.into(), thread);
            git_repo(world, &c[0], &[&c[1], "main"], &c[1], "main");
            world.connect()?;
            let key = thread_key(world);
            open(world, &key)
        },
    );
    steps.step(
        &format!("a connected environment with the git project {Q} whose default branch is {Q}"),
        |world, c, _| {
            world.mc.projects.insert(c[0].clone(), project_row(&c[0]));
            git_repo(world, &c[0], &[&c[1]], &c[1], &c[1]);
            world.connect()?;
            world.sync()
        },
    );

    // The header.
    steps.step(
        &format!("the header shows the thread {Q} in {Q} on {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let state = workspace(w);
                    state["threadTitle"] == c[0]
                        && state["projectTitle"] == c[1]
                        && state["branch"] == c[2]
                },
                |w| {
                    format!(
                        "the header to show {} in {} on {}; it shows {}",
                        c[0],
                        c[1],
                        c[2],
                        show(&workspace(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the header shows a new thread in {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let state = workspace(w);
                    state["isDraft"].as_bool() == Some(true)
                        && state["threadTitle"] == "New thread"
                        && state["projectTitle"] == c[0]
                },
                |w| {
                    format!(
                        "the header to show a new thread in {}; it shows {}",
                        c[0],
                        show(&workspace(w))
                    )
                },
            )
        },
    );
    steps.step("the user leaves the thread", |world, _, _| {
        world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))
    });

    // Titles.
    steps.step(&format!("the user renames {Q} to {Q}"), |world, c, _| {
        // A managed folder takes the same words; so does a provider instance.
        if super::files_folder::rename_managed_folder(world, &c[0], &c[1])? {
            return Ok(());
        }
        if world.state("providerSettings")["open"] == json!(true) {
            return super::provider_settings::rename_provider_instance(world, &c[0], &c[1]);
        }
        let state = workspace(world);
        expect!(
            state["threadTitle"] == c[0],
            "the header shows {}",
            show(&state)
        );
        dispatch(world, "workspace.rename", json!({"title": c[1]}))
    });
    steps.step(
        &format!("the user renames {Q} to an empty title"),
        |world, c, _| {
            let state = workspace(world);
            expect!(
                state["threadTitle"] == c[0],
                "the header shows {}",
                show(&state)
            );
            dispatch(world, "workspace.rename", json!({"title": "   "}))
        },
    );
    steps.step("the environment rejects the rename", |world, _, _| {
        world.mc.refusals.insert(
            "thread.metadata.update".into(),
            "Thread is being deleted".into(),
        );
        Ok(())
    });
    steps.step(&format!("the thread is listed as {Q}"), |world, c, _| {
        world.wait_for_with(|w| titled(w, &c[0]), describe_title)
    });
    steps.step(&format!("the title stays {Q}"), |world, c, _| {
        world.sync()?;
        expect!(titled(world, &c[0]), "{}", describe_title(world));
        Ok(())
    });
    steps.step(
        &format!("the user picks Rename for {Q} in the thread list"),
        |world, c, _| world.dispatch("workspace.rename.begin", json!({"threadKey": c[0]})),
    );
    steps.step(
        &format!("the header starts editing the title of {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let state = workspace(w);
                    state["threadKey"] == c[0] && state["renameRequestId"].as_i64().unwrap_or(0) > 0
                },
                |w| {
                    format!(
                        "the header to edit {}'s title; it shows {}",
                        c[0],
                        show(&workspace(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the MC has the thread {Q} titled {Q} in {Q}"),
        |world, c, _| {
            put_thread(world, &c[0], json!({"title": c[1], "projectId": c[2]}));
            world.sync()
        },
    );
    steps.step(&format!("the user goes to {Q}"), |world, c, _| {
        open(world, &c[0])
    });

    // Branches.
    steps.step(
        &format!("{Q} has the branches {Q}, {Q} and {Q}"),
        |world, c, _| {
            let repo = world
                .mc
                .part::<FakeGit>()
                .repos
                .entry(root(&c[0]))
                .or_default();
            repo.branches = vec![c[1].clone(), c[2].clone(), c[3].clone()];
            Ok(())
        },
    );
    steps.step(&format!("{Q} has (\\d+) branches"), |world, c, _| {
        let repo = world
            .mc
            .part::<FakeGit>()
            .repos
            .entry(root(&c[0]))
            .or_default();
        repo.branches = vec![repo.current.clone(), repo.default_branch.clone()];
        let wanted: usize = c[1].parse().unwrap_or(0);
        let mut branch = 1;
        while repo.branches.len() < wanted {
            repo.branches.push(format!("feature/{branch:03}"));
            branch += 1;
        }
        Ok(())
    });
    steps.step("the user opens the branch list", |world, _, _| {
        dispatch(world, "workspace.branch.search", json!({"query": ""}))
    });
    // The branch list's ListView asks for more at its end (Composer.qml).
    steps.step(
        "the user scrolls to the end of the branch list",
        |world, _, _| {
            dispatch(world, "workspace.branch.search", json!({"query": ""}))?;
            let shown = branch_names(world).len();
            expect!(shown == 100, "the list opens with {shown} branches");
            dispatch(world, "workspace.branch.more", Value::Null)
        },
    );
    steps.step("the next page of branches is loaded", |world, _, _| {
        world.wait_for_with(
            |w| branch_names(w).len() == 200,
            |w| format!("200 branches; the list has {}", branch_names(w).len()),
        )?;
        let names = branch_names(world);
        let pages = world.mc.part::<FakeGit>().ref_pages.clone();
        let distinct: HashSet<&String> = names.iter().collect();
        expect!(
            pages == [0, 100]
                && names.get(100).map(String::as_str) == Some("feature/099")
                && distinct.len() == 200
                && workspace(world)["branchesTotal"] == 400,
            "the MC was asked for pages at {}; the 101st branch is {}",
            pages.len(),
            names.get(100).cloned().unwrap_or_default()
        );
        // And the next, until the list is whole; then nothing more is asked.
        for _ in 0..3 {
            dispatch(world, "workspace.branch.more", Value::Null)?;
        }
        let pages = world.mc.part::<FakeGit>().ref_pages.len();
        expect!(
            branch_names(world).len() == 400 && pages == 4,
            "the list has {} branches after {pages} pages",
            branch_names(world).len()
        );
        Ok(())
    });
    steps.step("the user copies the thread's branch name", |world, _, _| {
        dispatch(world, "workspace.branch.copy", Value::Null)
    });
    steps.step(&format!("{Q} is on the clipboard"), |world, c, _| {
        let held = world.clipboard();
        expect!(held == c[0], "the clipboard holds \"{held}\"");
        Ok(())
    });
    steps.step(
        &format!("the agent checked out {Q} in the thread's checkout"),
        |world, c, _| {
            // The shell has seen the checkout on the thread's branch first.
            world.wait_for("the shell to follow the checkout", |w| {
                !w.mc.subscribers("vcs").is_empty()
            })?;
            world.sync()?;
            let project = text(&workspace(world)["projectTitle"]);
            let branch = text(&world.mc.threads[THREAD]["branch"]);
            let repo = world
                .mc
                .part::<FakeGit>()
                .repos
                .entry(root(&project))
                .or_default();
            expect!(
                branch == repo.current,
                "the thread is not on the checkout's branch"
            );
            repo.branches.insert(0, c[0].clone());
            repo.current = c[0].clone();
            Ok(())
        },
    );
    steps.step("the status updates", |world, _, _| {
        let cwd = root(&text(&workspace(world)["projectTitle"]));
        send_status(&mut world.mc, &cwd);
        world.sync()
    });
    fn search(world: &mut World, query: &str) -> Outcome {
        dispatch(world, "workspace.branch.search", json!({"query": query}))
    }
    steps.step(
        &format!("the user searches the branch list for {Q}"),
        |world, c, _| search(world, &c[0]),
    );
    steps.step(
        &format!("the user searched the branch list for {Q}"),
        |world, c, _| search(world, &c[0]),
    );
    steps.step(&format!("only {Q} is listed"), |world, c, _| {
        // The archive page lists the same words as the branch list.
        if !super::archived_threads::groups_of(world).is_empty() {
            expect!(
                super::archived_threads::archive_lists_only(world, &c[0]),
                "the archive lists {}",
                show(&world.state("archivedThreads"))
            );
            return Ok(());
        }
        let names = branch_names(world);
        expect!(names == [c[0].clone()], "the list is {}", names.join(", "));
        Ok(())
    });
    steps.step("no ref matches", |world, _, _| {
        let names = branch_names(world);
        expect!(names.is_empty(), "the list is {}", names.join(", "));
        Ok(())
    });
    steps.step(
        &format!("{Q} is marked current and listed first"),
        |world, c, _| {
            let first = branch_at(world, 0)?;
            expect!(
                first["name"] == c[0] && first["current"].as_bool() == Some(true),
                "the first is {}",
                show(&first)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is marked default and listed next"),
        |world, c, _| {
            let next = branch_at(world, 1)?;
            expect!(
                next["name"] == c[0] && next["isDefault"].as_bool() == Some(true),
                "the next is {}",
                show(&next)
            );
            Ok(())
        },
    );
    steps.step(
        "the other branches follow, most recently committed first",
        |world, _, _| {
            let repo = current_repo(world);
            let others: Vec<String> = repo
                .branches
                .iter()
                .filter(|b| **b != repo.current && **b != repo.default_branch)
                .cloned()
                .collect();
            let names = branch_names(world);
            expect!(
                names.iter().skip(2).cloned().collect::<Vec<_>>() == others,
                "the list is {}",
                names.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told how many of the (\\d+) refs are shown and to type to narrow them",
        |world, c, _| {
            let state = workspace(world);
            let total = state["branchesTotal"].as_i64().unwrap_or(0);
            let shown = state["branches"].as_array().map_or(0, Vec::len) as i64;
            // Composer.qml's "Showing N of M refs — type to narrow" shows while
            // some are hidden.
            expect!(
                total == c[0].parse::<i64>().unwrap_or(-1) && shown < total,
                "{shown} of {total} are shown"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user switches the thread to {Q}"),
        |world, c, _| {
            dispatch(world, "workspace.branch.search", json!({"query": ""}))?;
            dispatch(world, "workspace.branch.select", json!({"name": c[0]}))
        },
    );
    steps.step(
        &format!("the MC cannot switch the checkout: {Q}"),
        |world, c, _| {
            world.mc.part::<FakeGit>().refuse_switch = c[0].clone();
            Ok(())
        },
    );
    steps.step(&format!("the checkout is on {Q}"), |world, c, _| {
        let current = current_repo(world).current;
        expect!(current == c[0], "the checkout is on {current}");
        Ok(())
    });
    steps.step(&format!("the thread's branch reads {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| {
                workspace(w)["branch"] == c[0]
                    && w.mc.threads[THREAD]["branch"] == c[0]
                    && workspace(w)["branchSwitchPending"].as_bool() != Some(true)
            },
            |w| {
                format!(
                    "the branch to read {}; the header shows {}, the thread {}",
                    c[0],
                    text(&workspace(w)["branch"]),
                    text(&w.mc.threads[THREAD]["branch"])
                )
            },
        )
    });
    steps.step("the user creates it", |world, _, _| {
        let query = workspace(world)["branchQuery"].clone();
        dispatch(world, "workspace.branch.create", json!({"name": query}))
    });
    steps.step(
        &format!("{Q} is created and the checkout switches to it"),
        |world, c, _| {
            let repo = current_repo(world);
            expect!(
                repo.branches.contains(&c[0]) && repo.current == c[0],
                "the checkout is on {} of {}",
                repo.current,
                repo.branches.join(", ")
            );
            world.wait_for_with(
                |w| workspace(w)["branch"] == c[0] && w.mc.threads[THREAD]["branch"] == c[0],
                |w| {
                    format!(
                        "the thread's branch to read {}; the header shows {}",
                        c[0],
                        show(&workspace(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the thread in {Q} shows the branch {Q}"),
        |world, c, _| {
            let row = sidebar_row(world, &thread_key(world));
            expect!(
                row.as_ref().is_some_and(|r| r["branch"] == c[1])
                    && world.mc.threads[THREAD]["projectId"] == c[0],
                "the thread list shows {}",
                row.map(|r| show(&r)).unwrap_or_else(|| "no row".into())
            );
            Ok(())
        },
    );

    // A new thread's checkout.
    steps.step(
        &format!("the user is writing the first message of a new thread in {Q}"),
        |world, c, _| open_draft(world, &c[0]),
    );
    steps.step(
        &format!("the user starts a thread in a new worktree based on {Q}"),
        |world, c, _| {
            let project = first_project(world);
            let branches = &mut world
                .mc
                .part::<FakeGit>()
                .repos
                .entry(root(&project))
                .or_default()
                .branches;
            if !branches.contains(&c[0]) {
                branches.push(c[0].clone());
            }
            open_draft(world, &project)?;
            dispatch(world, "workspace.envMode.set", json!({"mode": "worktree"}))?;
            dispatch(world, "workspace.branch.search", json!({"query": ""}))?;
            dispatch(world, "workspace.branch.select", json!({"name": c[0]}))?;
            dispatch(
                world,
                "composer.submit",
                json!({"text": "Ship the fix", "intent": "foreground"}),
            )
        },
    );
    steps.step(
        "the user chose a new worktree without a base branch",
        |world, _, _| {
            // A checkout on no branch (a detached head) offers no base to start from.
            let project = first_project(world);
            git_repo(world, &project, &["main"], "", "main");
            send_status(&mut world.mc, &root(&project));
            world.start_new_thread(json!({}))?;
            world.wait_for_with(
                |w| workspace(w)["isDraft"].as_bool() == Some(true),
                |w| {
                    format!(
                        "the header to show the draft; it shows {}",
                        show(&workspace(w))
                    )
                },
            )?;
            dispatch(world, "workspace.envMode.set", json!({"mode": "worktree"}))
        },
    );
    steps.step(
        "the user picks the new worktree checkout mode",
        |world, _, _| dispatch(world, "workspace.envMode.set", json!({"mode": "worktree"})),
    );
    steps.step("the user picks the current checkout mode", |world, _, _| {
        dispatch(world, "workspace.envMode.set", json!({"mode": "local"}))
    });
    steps.step(
        "the user picked the new worktree checkout mode for a new thread",
        |world, _, _| {
            let project = first_project(world);
            open_draft(world, &project)?;
            dispatch(world, "workspace.envMode.set", json!({"mode": "worktree"}))
        },
    );
    steps.step(
        "the thread will start in a worktree of its own instead of the project folder",
        |world, _, _| starts_in(world, "worktree", "New worktree"),
    );
    steps.step(
        "the thread will start in the project folder",
        |world, _, _| starts_in(world, "local", "Current checkout"),
    );
    steps.step(
        &format!("{Q} has a checkout of {Q} at {Q}"),
        |world, c, _| {
            let Some(peer) = world.mc.peers.get(&c[0]).cloned() else {
                fail!("{} is not in the cluster", c[0]);
            };
            let project = format!("{}-copy", c[1]);
            let row = json!({"id": project, "title": c[1], "workspaceRoot": c[2], "scripts": [],
            "repositoryIdentity": {"canonicalKey": format!("github.com/acme/{}", c[1])}});
            world
                .mc
                .send_rows(&peer, vec![json!([project, "project", row])]);
            world.sync()
        },
    );
    steps.step(
        &format!("the user runs the new thread on {Q}"),
        |world, c, _| {
            dispatch(
                world,
                "workspace.environment.set",
                json!({"environmentId": c[0]}),
            )
        },
    );
    steps.step(
        &format!("the new thread will start on {Q} in {Q}"),
        |world, c, _| {
            let state = workspace(world);
            expect!(
                state["activeEnvironmentId"] == c[0] && state["projectRoot"] == c[1],
                "the header shows {}",
                show(&state)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is offered to run the new thread on"),
        |world, c, _| {
            let state = workspace(world);
            let offered = state["environments"]
                .as_array()
                .is_some_and(|e| e.iter().any(|choice| choice["environmentId"] == c[0]));
            expect!(
                offered,
                "the header offers {}",
                show(&state["environments"])
            );
            Ok(())
        },
    );

    // The previous worktree (composer.previousWorktree).
    steps.step(
        &format!("the user just finished a thread in the worktree on {Q}"),
        |world, c, _| finished_in(world, &c[0]),
    );
    steps.step(
        &format!("the user can pick the previous worktree on {Q} for it"),
        |world, c, _| {
            world.wait_for_with(
                |w| text(&workspace(w)["previousWorktree"]["label"]).contains(&c[0]),
                |w| {
                    format!(
                        "the checkout picker to offer the previous worktree; the header shows {}",
                        show(&workspace(w))
                    )
                },
            )?;
            dispatch(world, "workspace.previousWorktree", Value::Null)?;
            uses_previous(world, &c[0])
        },
    );
    steps.step("the native composer has keyboard focus", |world, _, _| {
        world.mc.projects.insert("shop".into(), project_row("shop"));
        git_repo(world, "shop", &["main", "feature/tax"], "main", "main");
        world.connect()?;
        finished_in(world, "feature/tax")?;
        let key = world.project_key("shop");
        world.start_new_thread(json!({"projectKey": key}))?;
        world.wait_for_with(
            |w| workspace(w)["isDraft"].as_bool() == Some(true),
            |w| {
                format!(
                    "the header to show the draft; it shows {}",
                    show(&workspace(w))
                )
            },
        )
    });
    steps.step(
        "the composer switches to the previous worktree",
        |world, _, _| {
            uses_previous(world, "feature/tax")?;
            expect!(
                !world.actions_of("composer.focus").is_empty(),
                "the composer did not take the keyboard back: {}",
                world.describe_brick_actions()
            );
            Ok(())
        },
    );

    // Editors. The ones a `config` shape lists wait on SettingsSteps' fake.
    steps.step(
        &format!("the user opens the thread in {Q}"),
        |world, c, _| {
            dispatch(
                world,
                "workspace.openInEditor",
                json!({"editorId": editor_id(&c[0])}),
            )
        },
    );
    steps.step(
        "the user opens the thread in their editor",
        |world, _, _| dispatch(world, "workspace.openInEditor", Value::Null),
    );
    steps.step(&format!("{Q} opens {Q}"), |world, c, _| {
        expect_editor_call(world, &editor_id(&c[0]), &c[1])
    });
    steps.step(
        &format!("{Q} is the editor offered first"),
        |world, c, _| {
            world.sync()?;
            let state = workspace(world);
            expect!(
                state["preferredEditorId"] == editor_id(&c[0]).as_str(),
                "the header shows {}",
                show(&state)
            );
            Ok(())
        },
    );

    // navigation/layout.feature's header, in its words.
    steps.step(
        "the header shows the project name and the thread title",
        |world, _, _| {
            let named = |w: &World| {
                let state = workspace(w);
                let key = text(&state["threadKey"]);
                let id = key.split_once(':').map_or("", |(_, id)| id).to_owned();
                let thread = w.mc.threads.get(&id).cloned().unwrap_or(Value::Null);
                let project =
                    w.mc.projects
                        .get(&text(&thread["projectId"]))
                        .cloned()
                        .unwrap_or(Value::Null);
                !thread.is_null()
                    && state["threadTitle"] == thread["title"]
                    && state["projectTitle"] == project["title"]
            };
            world.wait_for_with(named, |w| {
                format!(
                    "the header to name the thread and its project; it shows {}",
                    show(&workspace(w))
                )
            })
        },
    );
    steps.step(
        &format!("the user opens the thread's workspace in {Q} from the header"),
        |world, c, _| {
            dispatch(
                world,
                "workspace.openInEditor",
                json!({"editorId": editor_id(&c[0])}),
            )
        },
    );
    steps.step(
        &format!("{Q} opens the thread's workspace folder"),
        |world, c, _| {
            let folder = text(&workspace(world)["projectRoot"]);
            expect!(
                !folder.is_empty(),
                "the header shows {}",
                show(&workspace(world))
            );
            expect_editor_call(world, &editor_id(&c[0]), &folder)
        },
    );
    steps.step(
        &format!("{Q} becomes the preferred editor"),
        |world, c, _| {
            world.sync()?;
            let state = workspace(world);
            expect!(
                state["preferredEditorId"] == editor_id(&c[0]).as_str(),
                "the header shows {}",
                show(&state)
            );
            Ok(())
        },
    );

    // The header's buttons that leave the header.
    steps.step(
        &format!("the checkout's pull request is {Q}"),
        |world, c, _| {
            world.sync()?;
            let remote =
                json!({"pr": {"number": 7, "title": "Tax line", "url": c[0], "state": "open"}});
            for id in world.mc.subscribers("vcs") {
                world.mc.send(&json!({"t": "vcs", "id": id, "event": {
                "_tag": "remoteUpdated", "remote": remote}}));
            }
            world.sync()
        },
    );
    steps.step(
        "the user opens the pull request from the header",
        |world, _, _| dispatch(world, "workspace.openPullRequest", Value::Null),
    );
    steps.step(&format!("the browser opens {Q}"), |world, c, _| {
        let opened = world.opened_urls();
        expect!(
            opened.len() == 1 && opened[0] == c[0],
            "the browser opened {}",
            opened.len()
        );
        Ok(())
    });
    steps.step(
        "the user opens the thread's workspace from the header",
        |world, _, _| dispatch(world, "workspace.openInEditor", Value::Null),
    );
    steps.step(
        "the header does not offer to open the workspace in an editor",
        |world, _, _| {
            world.sync()?;
            let state = workspace(world);
            expect!(
                state.as_object().is_some_and(|o| !o.is_empty())
                    && state["editors"].as_array().is_some_and(Vec::is_empty),
                "the header shows {}",
                show(&state)
            );
            Ok(())
        },
    );
}
