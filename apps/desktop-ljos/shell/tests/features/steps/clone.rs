//! Cloning a repository into a new project (desktop-qt's CloneSteps.cpp):
//! Add project's clone sources in the palette
//! (navigation/palette-add-project.feature) and each clone's toast
//! (files/adding-projects.feature). The fake MC looks repositories up,
//! starts clones (adding their project at once, as the MC does) and reports
//! them on each environment's `projectClones` shape; what git does is the
//! MC's own scenarios'.

use std::collections::HashMap;

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::palette::Palette;
use serde_json::{Value, json};

use super::fake_files::fake_files;
use super::project::FakeProjects;
use super::settings::save_elsewhere;
use super::source_control_settings::set_source_control_host;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const CLONE_PROJECT: &str = "p-shop";
/// Where `~` is on the fake MC: FakeFiles' home.
const HOME: &str = "/home/sam";
/// Another machine of the cluster the scenario's clones run on.
const MEMBER: &str = "beast";

#[derive(Default)]
struct FakeClones {
    /// By environment.
    clones: HashMap<String, Vec<Value>>,
    /// Every projectClone.* and sourceControl.lookupRepository call, as (method, payload).
    calls: Vec<(String, Value)>,
    refuse_start: String,
    refuse_lookup: String,
    /// The source the scenario added a project from, and what the palette
    /// asked on the way ("ask: <placeholder>", "browse: <query>").
    source: String,
    asked: Vec<String>,
}

fn fake(world: &mut World) -> &mut FakeClones {
    world.mc.part::<FakeClones>()
}

/// The environment a shape or call is for; the MC's own when it names none.
fn environment_of(mc: &FakeMc, named: &str) -> String {
    if named.is_empty() {
        mc.environment_id.clone()
    } else {
        named.to_owned()
    }
}

fn publish(mc: &mut FakeMc, environment: &str) {
    let clones = mc
        .part::<FakeClones>()
        .clones
        .get(environment)
        .cloned()
        .unwrap_or_default();
    for id in mc.subscribers("projectClones") {
        let named = text(&mc.shape_of(id)["environment"]);
        if environment_of(mc, &named) != environment {
            continue;
        }
        mc.send(&json!({"t": "projectClones", "id": id, "clones": clones}));
    }
}

fn expand_home(path: &str) -> String {
    match path.strip_prefix('~') {
        Some(rest) => format!("{HOME}{rest}"),
        None => path.to_owned(),
    }
}

fn add_project_row(mc: &mut FakeMc, id: &str, title: &str, root: &str) {
    let row = json!({
        "id": id,
        "title": title,
        "workspaceRoot": root,
        "createdAt": "2026-09-23T10:00:00Z",
        "updatedAt": "2026-09-23T10:00:00Z",
        "scripts": [],
    });
    mc.projects.insert(id.to_owned(), row.clone());
    mc.send_row_of(id, &row, "project");
}

fn extend(mc: &mut FakeMc) {
    mc.on_shape("projectClones", |mc, id, shape| {
        let environment = environment_of(mc, &text(&shape["environment"]));
        let clones = mc
            .part::<FakeClones>()
            .clones
            .get(&environment)
            .cloned()
            .unwrap_or_default();
        mc.send(&json!({"t": "projectClones", "id": id, "clones": clones}));
        Ok(())
    });
    mc.on_rpc("sourceControl.lookupRepository", |mc, rpc| {
        let fake = mc.part::<FakeClones>();
        fake.calls.push((rpc.method.clone(), rpc.payload.clone()));
        if !fake.refuse_lookup.is_empty() {
            let refusal = fake.refuse_lookup.clone();
            mc.refuse(rpc, &refusal);
            return Ok(());
        }
        let provider = text(&rpc.payload["provider"]);
        let repository = text(&rpc.payload["repository"]);
        let host = format!("{provider}.example.com");
        mc.reply(
            rpc,
            json!({
                "provider": provider,
                "nameWithOwner": repository,
                "url": format!("https://{host}/{repository}.git"),
                "sshUrl": format!("git@{host}:{repository}.git"),
            }),
        );
        Ok(())
    });
    // projectClone.start, .cancel and .retry: the namespace's handler.
    mc.on_rpc("projectClone.", |mc, rpc| {
        let fake = mc.part::<FakeClones>();
        fake.calls.push((rpc.method.clone(), rpc.payload.clone()));
        if rpc.method != "projectClone.start" {
            mc.reply(rpc, json!({}));
            return Ok(());
        }
        if !fake.refuse_start.is_empty() {
            let refusal = fake.refuse_start.clone();
            mc.refuse(rpc, &refusal);
            return Ok(());
        }
        let id = text(&rpc.payload["projectId"]);
        let destination = expand_home(&text(&rpc.payload["destinationPath"]));
        mc.reply(rpc, json!({}));
        add_project_row(mc, &id, &text(&rpc.payload["title"]), &destination);
        let environment = environment_of(mc, &rpc.environment);
        mc.part::<FakeClones>()
            .clones
            .entry(environment.clone())
            .or_default()
            .push(json!({
                "projectId": id,
                "remoteUrl": rpc.payload["remoteUrl"],
                "destinationPath": destination,
                "repository": null,
                "phase": "running",
                "stage": "connecting",
                "percent": null,
                "detail": null,
                "error": null,
            }));
        publish(mc, &environment);
        Ok(())
    });
}

// --- The palette -----------------------------------------------------------

fn palette<R>(
    world: &World,
    f: impl FnOnce(&mut Palette, &ljos::prelude::Engine) -> R,
) -> Outcome<R> {
    world.with::<Palette, R>(f)
}

fn describe(world: &World) -> String {
    palette(world, |p, _| {
        let rows: Vec<String> = (0..p.count())
            .filter_map(|row| p.shown_at(row))
            .map(|(title, description)| format!("{title} ({description})"))
            .collect();
        format!(
            "the palette ({}, {} query \"{}\") lists [{}]",
            if p.is_open() { "open" } else { "closed" },
            p.mode(),
            p.query(),
            rows.join("; ")
        )
    })
    .unwrap_or_else(|_| "the palette is busy".into())
}

/// The row titled `title` as the palette lists it now.
fn find_row(world: &World, title: &str) -> Option<i32> {
    palette(world, |p, _| {
        (0..p.count()).find(|row| p.shown_at(*row).is_some_and(|(t, _)| t == title))
    })
    .ok()
    .flatten()
}

/// The row titled `title` once the palette's searches are answered.
fn row_of(world: &mut World, title: &str) -> Outcome<Option<i32>> {
    world.sync()?;
    world.wait_for("the palette's searches to be answered", |w| {
        !palette(w, |p, _| p.searching()).unwrap_or(true)
    })?;
    Ok(find_row(world, title))
}

fn description_of(world: &mut World, title: &str) -> Outcome<String> {
    let Some(row) = row_of(world, title)? else {
        return Ok(String::new());
    };
    Ok(palette(world, |p, _| p.shown_at(row))?
        .map(|(_, description)| description)
        .unwrap_or_default())
}

fn run_row(world: &mut World, title: &str) -> Outcome {
    let row = row_of(world, title)?;
    let ran = match row {
        Some(row) => {
            let engine = world.engine().clone();
            palette(world, |p, _| p.run(&engine, row))?
        }
        None => false,
    };
    expect!(ran, "to run \"{title}\"; {}", describe(world));
    world.sync()
}

/// Add project's sources, once the environment's providers are known.
fn open_sources(world: &mut World) -> Outcome {
    if palette(world, |p, _| p.is_open())? {
        run_row(world, "Add project")?;
    } else {
        let engine = world.engine().clone();
        Commands::of(&engine).run(&engine, "project.add");
    }
    world.wait_for_with(
        |w| {
            find_row(w, "GitHub repository")
                .and_then(|row| palette(w, |p, _| p.shown_at(row)).ok().flatten())
                .is_some_and(|(_, description)| !description.starts_with("Setup Required"))
        },
        |w| format!("the providers to be known; {}", describe(w)),
    )
}

fn remember(world: &mut World) -> Outcome {
    let engine = world.engine().clone();
    let asked = palette(world, |p, _| {
        if p.mode() == "ask" {
            format!("ask: {}", p.placeholder(&engine))
        } else {
            format!("{}: {}", p.mode(), p.query())
        }
    })?;
    fake(world).asked.push(asked);
    Ok(())
}

/// Enter in the palette.
fn enter(world: &mut World, typed: Option<&str>) -> Outcome {
    let engine = world.engine().clone();
    if let Some(typed) = typed {
        palette(world, |p, _| p.set_query(&engine, typed))?;
    }
    row_of(world, "")?;
    let ran = palette(world, |p, _| p.run_highlighted(&engine))?;
    expect!(ran, "{}", describe(world));
    world.sync()
}

fn started(world: &mut World) -> Value {
    fake(world)
        .calls
        .iter()
        .find(|(method, _)| method == "projectClone.start")
        .map_or(Value::Null, |(_, payload)| payload.clone())
}

/// Add project from `source` up to where the MC is asked to clone (or adds
/// the folder).
fn add_from(world: &mut World, source: &str) -> Outcome {
    fake(world).source = source.to_owned();
    if source == "a repository on GitLab" {
        set_source_control_host(&mut world.mc, "gitlab", true);
    }
    open_sources(world)?;
    if source == "a local folder" {
        let files = fake_files(&mut world.mc);
        let home = files.home.clone();
        files.folders.insert(format!("{home}/code"));
        files.folders.insert(format!("{home}/code/shop"));
        run_row(world, "Local folder")?;
        remember(world)?;
        let engine = world.engine().clone();
        palette(world, |p, _| p.set_query(&engine, "~/code/shop"))?;
        row_of(world, "")?;
        let added = palette(world, |p, _| p.add_browsed_folder(&engine))?;
        expect!(added, "{}", describe(world));
        return world.sync();
    }
    let url = source == "a Git URL";
    run_row(
        world,
        if url {
            "Git URL"
        } else if source == "a repository on GitHub" {
            "GitHub repository"
        } else {
            "GitLab repository"
        },
    )?;
    remember(world)?;
    let lookups = fake(world).calls.len();
    enter(
        world,
        Some(if url {
            "https://example.com/acme/shop.git"
        } else {
            "acme/shop"
        }),
    )?;
    if !url {
        world.wait_for_with(
            |w| {
                w.mc.peek::<FakeClones>()
                    .is_some_and(|f| f.calls.len() > lookups)
            },
            |_| "the repository to be looked up".into(),
        )?;
        world.sync()?;
        if !fake(world).refuse_lookup.is_empty() {
            return Ok(());
        }
    }
    world.wait_for_with(
        |w| palette(w, |p, _| p.mode() == "browse").unwrap_or(false),
        describe,
    )?;
    remember(world)?;
    enter(world, None)?;
    world.wait_for_with(
        |w| {
            w.mc.peek::<FakeClones>()
                .is_some_and(|f| f.calls.iter().any(|(m, _)| m == "projectClone.start"))
        },
        |_| "the clone to start".into(),
    )?;
    world.sync()
}

// --- Clones the MC reports ---------------------------------------------------

fn report_clone(world: &mut World, repository: &str, fields: Value, environment: &str) -> Outcome {
    let on = environment_of(&world.mc, environment);
    let destination = format!("{HOME}/shop");
    if on == world.mc.environment_id && !world.mc.projects.contains_key(CLONE_PROJECT) {
        add_project_row(&mut world.mc, CLONE_PROJECT, "shop", &destination);
    }
    let mut clone = json!({
        "projectId": CLONE_PROJECT,
        "remoteUrl": format!("https://github.com/{repository}.git"),
        "destinationPath": destination,
        "repository": {"nameWithOwner": repository},
        "stage": null,
        "percent": null,
        "detail": null,
        "error": null,
    });
    for (key, value) in fields.as_object().into_iter().flatten() {
        clone[key] = value.clone();
    }
    fake(world).clones.insert(on.clone(), vec![clone]);
    publish(&mut world.mc, &on);
    world.sync()
}

fn toast_titled(world: &World, title: &str) -> Option<Value> {
    world.state("toasts")["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|item| item["title"] == title)
        .cloned()
}

fn wait_for_toast(world: &mut World, title: &str) -> Outcome<Value> {
    world.wait_for_with(
        |w| toast_titled(w, title).is_some(),
        |w| {
            format!(
                "the toast \"{title}\"; the shell shows {}",
                show(&w.state("toasts"))
            )
        },
    )?;
    Ok(toast_titled(world, title).unwrap_or(Value::Null))
}

/// Clicks `label` on the toast titled `title`, as the Notifications brick does.
fn choose(world: &mut World, title: &str, label: &str) -> Outcome {
    let toast = wait_for_toast(world, title)?;
    let Some(action) = toast["actions"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|action| action["label"] == label)
    else {
        fail!("no \"{label}\" on {}", show(&toast));
    };
    world.dispatch(
        "notification.action",
        json!({"id": toast["id"], "actionId": action["id"]}),
    )?;
    world.sync()
}

/// The project of the draft the window shows.
fn draft_project(world: &World) -> Value {
    let route = world.state("route");
    if at(&route, "kind") != "draft" {
        return Value::Null;
    }
    let Some(draft) = drafts::draft(world.engine(), &text(&route["draftId"])) else {
        return Value::Null;
    };
    if draft.environment_id != world.mc.environment_id {
        return Value::Null;
    }
    world
        .mc
        .projects
        .get(&draft.project_id)
        .cloned()
        .unwrap_or(Value::Null)
}

pub fn register(steps: &mut Steps) {
    steps.extension(extend);

    // Adding from a source.
    steps.step(
        "the user adds a project from (a local folder|a Git URL|a repository on GitHub|a repository on GitLab)",
        |world, c, _| add_from(world, &c[0]),
    );
    steps.step(
        "the project is added to the chosen environment",
        |world, _, _| {
            let source = fake(world).source.clone();
            let local = source == "a local folder";
            let root = format!("{HOME}/{}", if local { "code/shop" } else { "shop" });
            world.wait_for_with(
                |w| draft_project(w)["workspaceRoot"] == root.as_str(),
                |w| {
                    format!(
                        "a draft in the project at {root}; the route is {}",
                        show(&w.state("route"))
                    )
                },
            )?;
            if local {
                return Ok(());
            }
            // Each source clones from its own address: a URL as given, GitHub
            // over HTTPS, GitLab over SSH.
            let start = started(world);
            let expected = match source.as_str() {
                "a Git URL" => "https://example.com/acme/shop.git",
                "a repository on GitHub" => "https://github.example.com/acme/shop.git",
                _ => "git@gitlab.example.com:acme/shop.git",
            };
            expect!(
                start["remoteUrl"] == expected && start["title"] == "shop",
                "the clone started with {}",
                show(&start)
            );
            expect!(!palette(world, |p, _| p.is_open())?, "{}", describe(world));
            Ok(())
        },
    );

    // A provider that is not set up.
    steps.step("GitLab is not connected", |world, _, _| {
        set_source_control_host(&mut world.mc, "gitlab", false);
        Ok(())
    });
    steps.step(
        "the user looks at repository sources while adding a project",
        |world, _, _| open_sources(world),
    );
    steps.step(&format!("GitLab is marked {Q}"), |world, c, _| {
        let description = description_of(world, "GitLab repository")?;
        expect!(
            description.starts_with(&format!("{} · ", c[0])),
            "{}",
            describe(world)
        );
        // Ready sources come first.
        let github = row_of(world, "GitHub repository")?.unwrap_or(-1);
        let gitlab = row_of(world, "GitLab repository")?.unwrap_or(-1);
        expect!(github < gitlab, "{}", describe(world));
        Ok(())
    });
    steps.step(
        "choosing it opens the source control settings",
        |world, _, _| {
            run_row(world, "GitLab repository")?;
            let route = world.state("route");
            expect!(
                at(&route, "kind") == "settings"
                    && at(&route, "section") == "/settings/source-control"
                    && !palette(world, |p, _| p.is_open())?,
                "{}",
                show(&route)
            );
            Ok(())
        },
    );

    // Where browsing starts.
    steps.step(
        &format!("the add project base directory is {Q}"),
        |world, c, _| {
            save_elsewhere(&mut world.mc, "addProjectBaseDirectory", json!(c[0]), false);
            Ok(())
        },
    );
    steps.step("the add project base directory is empty", |world, _, _| {
        save_elsewhere(&mut world.mc, "addProjectBaseDirectory", json!(""), false);
        Ok(())
    });
    steps.step("the user starts adding a project", |world, _, _| {
        open_sources(world)?;
        run_row(world, "Local folder")?;
        remember(world)
    });
    steps.step(
        &format!("(?:the folder browser opens in|browsing starts at) ({Q}|the home folder)"),
        |world, c, _| {
            // A folder, as the palette browses one: with its separator.
            let mut folder = if c[0] == "the home folder" {
                "~".to_owned()
            } else {
                c[0].trim_matches('"').to_owned()
            };
            if !folder.ends_with('/') {
                folder.push('/');
            }
            let asked = fake(world).asked.clone();
            expect!(
                asked.contains(&format!("browse: {folder}")),
                "{}",
                asked.join("; ")
            );
            Ok(())
        },
    );

    // The steps of a clone.
    steps.step(
        "the user is asked for the repository first",
        |world, _, _| {
            let asked = fake(world).asked.clone();
            expect!(
                asked
                    .first()
                    .is_some_and(|a| a == "ask: Enter Git clone URL"),
                "{}",
                asked.join("; ")
            );
            Ok(())
        },
    );
    steps.step("then for the destination folder", |world, _, _| {
        // In the home folder, under the repository's name.
        let asked = fake(world).asked.clone();
        let start = started(world);
        expect!(
            asked.get(1).is_some_and(|a| a == "browse: ~/shop")
                && start["destinationPath"] == "~/shop",
            "{}",
            asked.join("; ")
        );
        Ok(())
    });
    steps.step(&format!("the destination offered is {Q}"), |world, c, _| {
        let asked = fake(world).asked.clone();
        let start = started(world);
        expect!(
            asked
                .get(1)
                .is_some_and(|a| *a == format!("browse: {}", c[0]))
                && start["destinationPath"] == c[0].as_str(),
            "{}",
            asked.join("; ")
        );
        Ok(())
    });

    // Failures.
    steps.step(
        "adding a project will fail at (the clone|the repository lookup|registration)",
        |world, c, _| {
            if c[0] == "registration" {
                // The MC refuses the project itself.
                world.mc.part::<FakeProjects>().refusal = "Disk is read-only".into();
                fake(world).source = "a local folder".into();
                return Ok(());
            }
            let fake = fake(world);
            if c[0] == "the clone" {
                fake.refuse_start = "destination already exists".into();
                fake.source = "a Git URL".into();
            } else {
                fake.refuse_lookup = "repository not found".into();
                fake.source = "a repository on GitHub".into();
            }
            Ok(())
        },
    );
    steps.step("the user adds the project", |world, _, _| {
        let source = fake(world).source.clone();
        let refused = !fake(world).refuse_start.is_empty();
        add_from(world, &source)?;
        if refused {
            // Refused, so add_from's wait for the start was for the call, not a clone.
            let browsing = palette(world, |p, _| p.is_open() && p.mode() == "browse")?;
            expect!(browsing, "{}", describe(world));
        }
        Ok(())
    });

    // Clone toasts.
    steps.step(
        &format!("a clone of {Q} is receiving objects at (\\d+) percent"),
        |world, c, _| {
            let percent: i64 = c[1].parse().unwrap_or(0);
            report_clone(
                world,
                &c[0],
                json!({"phase": "running", "stage": "receiving", "percent": percent}),
                "",
            )
        },
    );
    steps.step(
        &format!(
            "a clone of {Q} is receiving objects at (\\d+) percent on another machine of the cluster"
        ),
        |world, c, _| {
            world.mc.join_named(MEMBER);
            world.wait_for_with(
                |w| {
                    w.mc.subscribers("projectClones")
                        .iter()
                        .any(|id| w.mc.shape_of(*id)["environment"] == MEMBER)
                },
                |_| "the clones of the other machine to be followed".into(),
            )?;
            let percent: i64 = c[1].parse().unwrap_or(0);
            report_clone(
                world,
                &c[0],
                json!({"phase": "running", "stage": "receiving", "percent": percent}),
                MEMBER,
            )
        },
    );
    steps.step(&format!("a clone of {Q} finished"), |world, c, _| {
        report_clone(
            world,
            &c[0],
            json!({"phase": "done", "stage": "checkout", "percent": 100}),
            "",
        )
    });
    steps.step(&format!("a clone of {Q} failed"), |world, c, _| {
        report_clone(
            world,
            &c[0],
            json!({"phase": "failed", "error": "Repository not found."}),
            "",
        )
    });
    steps.step("the user looks at the app", |world, _, _| world.sync());
    steps.step(&format!("the user sees {Q} with {Q}"), |world, c, _| {
        let toast = wait_for_toast(world, &c[0])?;
        expect!(toast["description"] == c[1].as_str(), "{}", show(&toast));
        Ok(())
    });
    steps.step(
        &format!("the user sees {Q} with its destination folder"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[0])?;
            expect!(
                toast["description"] == format!("{HOME}/shop").as_str(),
                "{}",
                show(&toast)
            );
            Ok(())
        },
    );
    steps.step("the user can cancel the clone", |world, _, _| {
        choose(world, "Cloning acme/shop", "Cancel")?;
        world.wait_for_with(
            |w| {
                w.mc.peek::<FakeClones>().is_some_and(|f| {
                    f.calls.iter().any(|(m, payload)| {
                        m == "projectClone.cancel" && payload["projectId"] == CLONE_PROJECT
                    })
                })
            },
            |_| "the clone to be cancelled".into(),
        )?;
        // The toast stays, to say how the cancel went.
        wait_for_toast(world, "Cloning acme/shop")?;
        Ok(())
    });
    steps.step("the user can open the project", |world, _, _| {
        choose(world, "Cloned acme/shop", "Open project")?;
        world.wait_for_with(
            |w| draft_project(w)["id"] == CLONE_PROJECT,
            |w| show(&w.state("route")),
        )
    });
    steps.step(
        "the user removes the project from the clone's failure notice",
        |world, _, _| choose(world, "Failed to clone acme/shop", "Remove project"),
    );
    steps.step(
        &format!("the project {Q} is no longer listed"),
        |world, c, _| {
            let name = c[0].clone();
            world.wait_for_with(
                |w| {
                    let listed = w.state("sidebar")["projects"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .any(|p| p["displayName"] == name.as_str());
                    !listed && !w.mc.projects.contains_key(CLONE_PROJECT)
                },
                |w| format!("{name} to go; the sidebar is {}", show(&w.state("sidebar"))),
            )
        },
    );
}
