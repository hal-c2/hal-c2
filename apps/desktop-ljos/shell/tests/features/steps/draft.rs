//! The desktop's drafts (DraftController): starting a new thread, the draft
//! in the sidebar and the window, its menu, and the thread it becomes
//! (threads/drafts.feature, threads/creating.feature, navigation/layout.feature),
//! and the draft a window with no thread lands on (navigation/landing.feature).
//! desktop-qt's DraftSteps.cpp.

use hal_c2_shell::controllers::drafts::{self, Draft};
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The project the header named when the user chose it.
#[derive(Default)]
struct HeaderProject(String);

fn last_draft(world: &World) -> Option<Draft> {
    drafts::draft(world.engine(), &world.draft_id)
}

fn sidebar_project_name(world: &World, environment: &str, project: &str) -> String {
    let physical = format!("{environment}:{project}");
    let sidebar = world.state("sidebar");
    at(&sidebar, "localProjects")
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| at(p, "key") == &json!(physical))
        .map_or(physical.clone(), |p| text(&p["displayName"]))
}

/// Where the shell keeps the drafts; a folder in its place makes every save
/// fail.
fn drafts_file(world: &World) -> std::path::PathBuf {
    world.home_dir().join("data/shell-drafts.json")
}

fn sidebar_draft_ids(world: &World) -> Vec<String> {
    at(&world.state("sidebar"), "drafts")
        .as_array()
        .into_iter()
        .flatten()
        .map(|d| text(&d["draftId"]))
        .collect()
}

/// The one draft `sidebar` lists is the draft the steps talk about, reading
/// `label`.
fn expect_listed_draft(world: &World, sidebar: &Value, label: &str) -> Outcome {
    let listed = at(sidebar, "drafts")
        .as_array()
        .cloned()
        .unwrap_or_default();
    expect!(
        listed.len() == 1
            && text(&listed[0]["draftId"]) == world.draft_id
            && text(&listed[0]["label"]) == label,
        "the sidebar lists the drafts {}, not {} reading {label}",
        show(&Value::Array(listed.clone())),
        world.draft_id
    );
    Ok(())
}

/// The window shows a draft in the project named `name`; it becomes the
/// draft the steps talk about.
fn expect_new_draft(world: &mut World, name: &str) -> Outcome {
    world.sync()?;
    let route = world.state("route");
    expect!(
        at(&route, "kind") == "draft",
        "the route is {}",
        show(&route)
    );
    world.draft_id = text(&route["draftId"]);
    let Some(draft) = last_draft(world) else {
        fail!("the shell has no draft {}", world.draft_id);
    };
    let project = sidebar_project_name(world, &draft.environment_id, &draft.project_id);
    expect!(project == name, "the draft is in {project}");
    Ok(())
}

fn expect_route_draft(world: &mut World, id: &str) -> Outcome {
    world.sync()?;
    let route = world.state("route");
    expect!(
        at(&route, "kind") == "draft" && text(&route["draftId"]) == id,
        "the route is {}",
        show(&route)
    );
    Ok(())
}

fn open_projects(world: &mut World, x: f64, y: f64) -> Outcome {
    world.dispatch("draft.project", json!({"x": x, "y": y}))
}

/// The shell keeps to one window (`set_window_opener` is not given one
/// here), so what a second window shows can not be read.
fn second_window() -> Outcome {
    fail!("the headless shell has one window; a second one is not opened")
}

pub fn register(steps: &mut Steps) {
    // The user.
    steps.step("the user starts a new thread", |world, _, _| {
        world.start_new_thread(json!({}))
    });
    steps.step(
        "the user opens the draft from the sidebar",
        |world, _, _| {
            let id = world.draft_id.clone();
            world.dispatch("draft.open", json!({"draftId": id}))
        },
    );
    steps.step(
        r"the user opens the draft's menu at (\d+), (\d+)",
        |world, c, _| {
            let id = world.draft_id.clone();
            world.dispatch(
                "draft.menu",
                json!({"draftId": id, "x": c[0].parse::<f64>().unwrap_or(0.0),
                       "y": c[1].parse::<f64>().unwrap_or(0.0)}),
            )
        },
    );
    steps.step(
        r"the user opens the draft's projects at (\d+), (\d+)",
        |world, c, _| {
            open_projects(
                world,
                c[0].parse().unwrap_or(0.0),
                c[1].parse().unwrap_or(0.0),
            )
        },
    );
    steps.step(
        &format!("the user moves the draft to {Q}"),
        |world, c, _| {
            open_projects(world, 0.0, 0.0)?;
            let menu = world.state("menu");
            expect!(menu.is_object(), "no menu is open");
            let key = world.project_key(&c[0]);
            world.dispatch(
                "menu.select",
                json!({"requestId": menu["requestId"], "id": key}),
            )
        },
    );
    steps.step(
        &format!("the menu offers the projects {Q} and {Q} with {Q} ticked"),
        |world, c, _| {
            let menu = world.state("menu");
            let mut offered = Vec::new();
            let mut ticked = Vec::new();
            for item in at(&menu, "items").as_array().into_iter().flatten() {
                let label = text(&item["label"]);
                if item["checked"] == json!(true) {
                    ticked.push(label.clone());
                }
                offered.push(label);
            }
            offered.sort();
            expect!(
                offered == vec![c[0].clone(), c[1].clone()] && ticked == vec![c[2].clone()],
                "the menu is {}",
                show(&menu)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the composer's caret follows {Q}"),
        |world, c, _| {
            world.sync()?;
            let composer = world.state("composer");
            expect!(
                text(&composer["text"]) == c[0]
                    && composer["cursor"].as_u64() == Some(c[0].chars().count() as u64),
                "the composer shows {}",
                show(&composer)
            );
            Ok(())
        },
    );

    // The MC.
    steps.step("the MC creates the draft's thread", |world, _, _| {
        let Some(draft) = last_draft(world) else {
            fail!("the shell has no draft {}", world.draft_id);
        };
        let row = json!({
            "id": draft.thread_id,
            "projectId": draft.project_id,
            "title": "Started",
            "createdAt": "2026-09-23T09:59:00Z",
            "updatedAt": "2026-09-23T09:59:00Z",
        });
        world
            .mc
            .threads
            .insert(draft.thread_id.clone(), row.clone());
        world.mc.send_row(&draft.thread_id, &row);
        world.sync()
    });

    // The header's project label (navigation/layout.feature).
    steps.step(
        "the user chooses the project name in the header",
        |world, _, _| {
            world.sync()?;
            let name = text(&world.state("workspace")["projectTitle"]);
            expect!(!name.is_empty(), "the header names no project");
            world.part::<HeaderProject>().0 = name;
            world.dispatch("workspace.newThread", json!({}))
        },
    );
    steps.step("a new thread starts in that project", |world, _, _| {
        let name = world.part::<HeaderProject>().0.clone();
        expect_new_draft(world, &name)
    });

    // What the shell shows.
    steps.step(
        &format!("(?:the window shows a new draft|(?:a|the) new thread starts) in {Q}"),
        |world, c, _| expect_new_draft(world, &c[0]),
    );
    steps.step(&format!("a draft thread opens in {Q}"), |world, c, _| {
        world.wait_for("a draft", |w| at(&w.state("route"), "kind") == "draft")?;
        expect_new_draft(world, &c[0])
    });
    steps.step("the window shows the draft", |world, _, _| {
        let id = world.draft_id.clone();
        expect_route_draft(world, &id)
    });
    steps.step("the window shows the draft's thread", |world, _, _| {
        world.sync()?;
        let route = world.state("route");
        let key = text(&route["threadKey"]);
        expect!(
            at(&route, "kind") == "thread"
                && last_draft(world).is_none()
                && key.starts_with(&format!("{}:", world.mc.environment_id)),
            "the route is {}",
            show(&route)
        );
        let id = key.split_once(':').map_or("", |(_, id)| id);
        let title = world
            .mc
            .threads
            .get(id)
            .map(|row| text(&row["title"]))
            .unwrap_or_default();
        expect!(
            title == "Started",
            "the window shows {key}, not the draft's thread"
        );
        Ok(())
    });
    steps.step("the sidebar marks the draft as open", |world, _, _| {
        world.sync()?;
        let sidebar = world.state("sidebar");
        expect!(
            text(&sidebar["activeDraftId"]) == world.draft_id
                && sidebar["activeThreadKey"].is_null(),
            "the sidebar is {}",
            show(&sidebar)
        );
        Ok(())
    });
    steps.step(
        &format!("the sidebar lists the draft reading {Q}"),
        |world, c, _| {
            world.sync()?;
            let sidebar = world.state("sidebar");
            expect_listed_draft(world, &sidebar, &c[0])
        },
    );
    steps.step(
        &format!("the new window's sidebar lists the draft reading {Q}"),
        |_, _, _| second_window(),
    );
    steps.step(
        "(?:the sidebar lists no drafts|the thread list does not list the empty draft)",
        |world, _, _| {
            world.sync()?;
            let ids = sidebar_draft_ids(world);
            expect!(
                ids.is_empty(),
                "the sidebar lists the drafts {}",
                ids.join(", ")
            );
            Ok(())
        },
    );

    // Landing (navigation/landing.feature).
    steps.step("the desktop can not keep its drafts", |world, _, _| {
        let file = drafts_file(world);
        std::fs::create_dir_all(&file).map_err(|e| {
            crate::harness::Failure(format!("could not block {}: {e}", file.display()))
        })
    });
    steps.step("the desktop can keep its drafts again", |world, _, _| {
        let file = drafts_file(world);
        std::fs::remove_dir_all(&file).map_err(|e| {
            crate::harness::Failure(format!("could not unblock {}: {e}", file.display()))
        })
    });
    steps.step(
        "the window says it couldn't start a new thread",
        |world, _, _| {
            world.sync()?;
            let route = world.state("route");
            expect!(
                at(&route, "kind") == "home",
                "the route is {}",
                show(&route)
            );
            let landing = world.state("landing");
            expect!(
                landing["failed"] == json!(true),
                "landing is {}",
                show(&landing)
            );
            Ok(())
        },
    );
    steps.step("the user tries again", |world, _, _| {
        world.dispatch("landing.retry", json!({}))
    });
    steps.step("the user opens a new window", |world, _, _| {
        world.dispatch("window.new", json!({}))?;
        world.sync()
    });
    steps.step(
        "the new window shows the first window's draft",
        |_, _, _| second_window(),
    );

    steps.step(
        &format!("the desktop keeps the draft(?: {Q})?"),
        |world, c, _| {
            world.sync()?;
            let id = c
                .first()
                .filter(|id| !id.is_empty())
                .cloned()
                .unwrap_or_else(|| world.draft_id.clone());
            expect!(
                drafts::draft(world.engine(), &id).is_some(),
                "the desktop keeps no draft {id}"
            );
            Ok(())
        },
    );
    steps.step(r"the desktop keeps (\d+) drafts?", |world, c, _| {
        world.sync()?;
        let kept = drafts::all(world.engine()).len();
        expect!(
            Some(kept) == c[0].parse().ok(),
            "the desktop keeps {kept} drafts"
        );
        Ok(())
    });
}
