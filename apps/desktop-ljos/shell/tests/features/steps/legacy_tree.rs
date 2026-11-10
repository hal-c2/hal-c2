//! The legacy sidebar (legacySidebarEnabled): one tree of threads per
//! project, folded, trimmed to a few threads, sorted, dragged into place,
//! and each project's menu (threads/sidebar-list.feature). The tree is
//! `sidebar.tree` and Sidebar.qml's rows; a project's menu is the shell's
//! `menu`. desktop-qt's LegacyTreeSteps.cpp.

use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json as shell_json;
use ljos::prelude::Value as QmlValue;
use serde_json::{Value, json};

use super::project::FakeProjects;
use super::settings_rows::{general_page, page_item, row_shown, turn_row};
use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

fn write_device(world: &mut World, key: &str, value: Value) -> Outcome {
    expect!(
        Settings::of(world.engine()).write_device(world.engine(), key, value),
        "{key} was not written"
    );
    world.sync()
}

fn tree(world: &World) -> Vec<Value> {
    at(&world.state("sidebar"), "tree")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn mode(world: &World) -> String {
    text(&at(&world.state("sidebar"), "mode"))
}

fn member_key(world: &World, project_id: &str) -> String {
    format!("{}:{project_id}", world.mc.environment_id)
}

/// The tree's project the MC's project `project_id` is a folder of.
fn tree_project(world: &World, project_id: &str) -> Outcome<Value> {
    let member = member_key(world, project_id);
    for project in tree(world) {
        let members: Vec<String> = at(&project, "memberKeys")
            .as_array()
            .into_iter()
            .flatten()
            .map(|k| text(k))
            .collect();
        if members.contains(&member) {
            return Ok(project);
        }
    }
    fail!(
        "the tree lists no {project_id}: {}",
        show(&Value::Array(tree(world)))
    )
}

fn titles(project: &Value) -> Vec<String> {
    project["threads"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| text(&row["title"]))
        .collect()
}

fn tree_names(world: &World) -> Vec<String> {
    tree(world)
        .iter()
        .map(|project| text(&project["displayName"]))
        .collect()
}

fn add_thread(
    world: &mut World,
    id: &str,
    project: &str,
    title: &str,
    created_at: &str,
    last_written: &str,
) {
    let row = json!({
        "id": id,
        "projectId": project,
        "title": title,
        "createdAt": created_at,
        "updatedAt": last_written,
        "latestUserMessageAt": last_written,
    });
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
}

fn add_project(world: &mut World, id: &str, root: &str, identity: Value) {
    let mut row = json!({
        "id": id,
        "title": id,
        "workspaceRoot": root,
        "createdAt": "2026-09-23T09:00:00Z",
        "updatedAt": "2026-09-23T09:00:00Z",
        "scripts": [],
    });
    if identity != json!({}) {
        row["repositoryIdentity"] = identity;
    }
    world.mc.projects.insert(id.to_owned(), row.clone());
    world.mc.send_row_of(id, &row, "project");
}

/// The thread list as the window draws it, its rows as Sidebar.qml builds
/// them.
fn thread_list(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0 {
        return Ok(brick);
    }
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nSidebar { height: 900 }\n",
        256.0,
        900.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

fn list_rows(brick: &Brick, world: &World) -> Vec<Value> {
    let Some(root) = brick.root(world) else {
        return Vec::new();
    };
    let rows = brick.read(world, root, "rows");
    shell_json::from_value(world.engine(), &rows)
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The titles of the thread rows the list draws under the project
/// `project_id`.
fn drawn_titles(world: &mut World, project_id: &str) -> Outcome<Vec<String>> {
    world.sync()?;
    let brick = thread_list(world)?;
    let key = text(&tree_project(world, project_id)?["key"]);
    let mut out = Vec::new();
    let mut under = false;
    for row in list_rows(&brick, world) {
        let kind = text(&row["kind"]);
        if kind == "project" {
            under = text(&row["item"]["key"]) == key;
        }
        if under && kind == "thread" {
            out.push(text(&row["item"]["title"]));
        }
    }
    Ok(out)
}

fn click(world: &mut World, object_name: &str) -> Outcome {
    world.sync()?;
    let brick = thread_list(world)?;
    brick.click(world, object_name)?;
    world.sync()
}

/// Picks the menu entry along `path`, each step an entry's label (a grouped
/// project's folder entries are named by their folder, so a step may be
/// the start of one).
fn choose(world: &mut World, path: &[&str]) -> Outcome {
    world.sync()?;
    let menu = world.state("menu");
    expect!(menu.is_object(), "no menu is open");
    let mut items: Vec<Value> = at(&menu, "items").as_array().cloned().unwrap_or_default();
    let mut id = String::new();
    for label in path {
        let found = items.iter().find(|item| {
            let offered = text(&item["label"]);
            offered == *label || offered.starts_with(&format!("{label} "))
        });
        // A project of one folder has no folder entries to pass through.
        if found.is_none() && label.starts_with('/') {
            continue;
        }
        let Some(found) = found else {
            fail!(
                "the menu has no {label}: {}",
                show(&Value::Array(items.clone()))
            );
        };
        id = text(&found["id"]);
        items = found["children"].as_array().cloned().unwrap_or_default();
    }
    expect!(
        items.is_empty(),
        "{} opens a further menu",
        path.join(" \u{2192} ")
    );
    world.dispatch(
        "menu.select",
        json!({"requestId": menu["requestId"], "id": id}),
    )?;
    world.sync()
}

fn open_project_menu(world: &mut World, project_id: &str) -> Outcome {
    world.sync()?;
    let key = tree_project(world, project_id)?["key"].clone();
    world.dispatch(
        "sidebar.project.menu",
        json!({"projectKey": key, "x": 10, "y": 10}),
    )
}

fn folder_of(world: &World, project_id: &str) -> String {
    world
        .mc
        .projects
        .get(project_id)
        .map_or_else(String::new, |row| text(&row["workspaceRoot"]))
}

fn sort_value(label: &str) -> Outcome<&'static str> {
    match label {
        "Last user message" => Ok("updated_at"),
        "Created at" => Ok("created_at"),
        "Manual" => Ok("manual"),
        _ => fail!("no sort order is called {label}"),
    }
}

fn sort_by(world: &mut World, what: &str, label: &str) -> Outcome {
    world.dispatch("sidebar.options", json!({"x": 10, "y": 10}))?;
    choose(
        world,
        &[
            if what == "projects" {
                "Sort projects"
            } else {
                "Sort threads"
            },
            label,
        ],
    )?;
    let key = if what == "projects" {
        "sidebarProjectSortOrder"
    } else {
        "sidebarThreadSortOrder"
    };
    let wanted = sort_value(label)?;
    world.wait_for_with(
        |w| {
            Settings::of(w.engine())
                .device_value(key)
                .and_then(|v| v.as_str().map(str::to_owned))
                .is_some_and(|v| v == wanted)
        },
        |_| format!("{key} to be {wanted}"),
    )
}

fn toast_items(world: &World) -> Vec<Value> {
    at(&world.state("toasts"), "items")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The rows of Settings → General's "Legacy features", which starts folded:
/// opened when `key`'s row is not shown yet.
fn show_legacy_row(world: &mut World, key: &str) -> Outcome {
    if row_shown(world, key)? {
        return Ok(());
    }
    let page = general_page(world)?;
    let fold = page_item(world, "settingsSection:Legacy features", "fold")?;
    let (x, y) = page.at(world, fold, 0.5, 0.5)?;
    world.click_at(x, y)?;
    let key = key.to_owned();
    let mut shown = false;
    for _ in 0..50 {
        if row_shown(world, &key)? {
            shown = true;
            break;
        }
        world.pump()?;
    }
    expect!(shown, "Settings to show {key}");
    Ok(())
}

fn arranged_order(world: &World, names: &[String]) -> Vec<String> {
    names
        .iter()
        .map(|name| format!("{}:/work/{name}", world.mc.environment_id))
        .collect()
}

/// thread_order's "the user drags X above Y", when the two are the tree's
/// projects: the first's header dropped on the second's.
pub fn drag_project(world: &mut World, dragged: &str, target: &str) -> Outcome<bool> {
    world.sync()?;
    let before = tree_names(world);
    if !before.iter().any(|n| n == dragged) || !before.iter().any(|n| n == target) {
        return Ok(false);
    }
    let at = |name: &str| before.iter().position(|n| n == name).unwrap_or(0);
    expect!(
        at(dragged) > at(target),
        "{dragged} is already above {target}"
    );
    world.dispatch(
        "sidebar.project.drop",
        json!({
            "projectKey": tree_project(world, dragged)?["key"],
            "targetKey": tree_project(world, target)?["key"],
        }),
    )?;
    world.sync()?;
    Ok(true)
}

pub fn register(steps: &mut Steps) {
    // The switch.
    steps.step(
        "the user has not turned on the legacy sidebar",
        |world, _, _| {
            world.sync()?;
            expect!(
                Settings::of(world.engine())
                    .device_value("legacySidebarEnabled")
                    .and_then(|v| v.as_bool())
                    != Some(true),
                "the legacy sidebar is on"
            );
            expect!(
                mode(world) == "attention",
                "the thread list is a {}",
                mode(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user has turned on the legacy sidebar",
        |world, _, _| {
            write_device(world, "legacySidebarEnabled", json!(true))?;
            expect!(
                mode(world) == "tree",
                "the thread list is a {}",
                mode(world)
            );
            Ok(())
        },
    );
    // Settings → General's legacy Sidebar row, which the web labelled
    // "Sidebar (legacy)".
    steps.step(
        r#"the user turns (on|off) "Sidebar \(legacy\)" in settings"#,
        |world, c, _| {
            show_legacy_row(world, "legacySidebarEnabled")?;
            turn_row(world, "legacySidebarEnabled", c[0] == "on")
        },
    );
    steps.step(
        "the thread list shows each project with its own threads beneath it",
        |world, _, _| {
            world.wait_for_with(
                |w| mode(w) == "tree",
                |w| format!("the tree; the list is a {}", mode(w)),
            )?;
            let sections = world.state("sidebar");
            for section in ["pinned", "active", "settled"] {
                expect!(
                    sections[section].as_array().is_none_or(Vec::is_empty),
                    "the {section} section is still listed"
                );
            }
            for project in ["shop", "docs"] {
                let rows = tree_project(world, project)?["threads"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                expect!(
                    rows.len() == 2,
                    "{project} lists {}",
                    show(&Value::Array(rows.clone()))
                );
                // The threads "%1 has 2 threads" made for it.
                for row in &rows {
                    let key = text(&row["key"]);
                    let id = key.split_once(':').map_or(key.as_str(), |(_, id)| id);
                    expect!(
                        id.starts_with(&format!("{project}-")),
                        "{project} lists {}",
                        show(row)
                    );
                }
            }
            Ok(())
        },
    );
    steps.step(
        "the thread list is grouped by attention again",
        |world, _, _| {
            world.wait_for_with(
                |w| mode(w) == "attention",
                |w| format!("the sections; the list is a {}", mode(w)),
            )?;
            expect!(tree(world).is_empty(), "the tree is still listed");
            let active = world.state("sidebar")["active"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            expect!(
                active.len() == 4,
                "Active lists {}",
                show(&Value::Array(active))
            );
            Ok(())
        },
    );

    // Folding, on the project's header.
    steps.step(
        &format!(r"the user (?:folds|unfolds) {Q}(?: in the thread list)?"),
        |world, c, _| {
            let key = text(&tree_project(world, &c[0])?["key"]);
            click(world, &format!("projectHeader:{key}"))
        },
    );
    steps.step(&format!("the threads of {Q} are hidden"), |world, c, _| {
        let drawn = drawn_titles(world, &c[0])?;
        expect!(
            drawn.is_empty() && tree_project(world, &c[0])?["expanded"] != json!(true),
            "{} shows {}",
            c[0],
            drawn.join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("the threads of {Q} are shown again"),
        |world, c, _| {
            let drawn = drawn_titles(world, &c[0])?;
            expect!(drawn.len() == 2, "{} shows {}", c[0], drawn.join(", "));
            Ok(())
        },
    );

    // A few threads, and the rest on asking.
    steps.step(
        &format!(r"{Q} has (\d+) threads and the list shows (\d+) threads per project"),
        |world, c, _| {
            // Thread n was written in last at minute n, so the highest
            // are the most recent.
            for n in 1..=c[1].parse::<i64>().unwrap_or(0) {
                let at = format!("2026-09-23T09:{n:02}:00Z");
                add_thread(
                    world,
                    &format!("{}-{n}", c[0]),
                    &c[0],
                    &format!("Thread {n}"),
                    "2026-09-23T08:00:00Z",
                    &at,
                );
            }
            write_device(
                world,
                "sidebarThreadPreviewCount",
                json!(c[2].parse::<i64>().unwrap_or(0)),
            )
        },
    );
    steps.step(
        &format!("the user looks at {Q} in the thread list"),
        |world, c, _| drawn_titles(world, &c[0]).map(|_| ()),
    );
    steps.step(
        &format!(r"the (\d+) most recent threads of {Q} are shown"),
        |world, c, _| {
            let count = c[0].parse::<usize>().unwrap_or(0);
            let drawn = drawn_titles(world, &c[1])?;
            let all = world.mc.threads.len();
            let expected: Vec<String> = (all.saturating_sub(count) + 1..=all)
                .rev()
                .map(|n| format!("Thread {n}"))
                .collect();
            expect!(drawn == expected, "{} shows {}", c[1], drawn.join(", "));
            Ok(())
        },
    );
    steps.step(
        &format!(r"(?:all|only) (\d+) threads of {Q} are shown"),
        |world, c, _| {
            let drawn = drawn_titles(world, &c[1])?;
            expect!(
                drawn.len() == c[0].parse::<usize>().unwrap_or(usize::MAX),
                "{} shows {}",
                c[1],
                drawn.join(", ")
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} offers to show (more|less)"), |world, c, _| {
        world.sync()?;
        let brick = thread_list(world)?;
        let key = text(&tree_project(world, &c[0])?["key"]);
        let more = brick.item(world, &format!("projectMore:{key}"))?;
        expect!(
            brick.flag(world, more, "visible")
                && brick.shows(
                    world,
                    if c[1] == "more" {
                        "Show more"
                    } else {
                        "Show less"
                    },
                )?,
            "{} offers {}",
            c[0],
            show(&tree_project(world, &c[0])?["more"])
        );
        Ok(())
    });
    steps.step("the user asks to show (?:more|less)", |world, _, _| {
        let mut key = String::new();
        for project in tree(world) {
            if !project["more"].is_null() {
                key = text(&project["key"]);
            }
        }
        expect!(!key.is_empty(), "no project offers more or less");
        click(world, &format!("projectMore:{key}"))
    });

    // How many, typed into Settings → General.
    steps.step(
        r"the user sets the visible thread count to (\d+)",
        |world, c, _| {
            show_legacy_row(world, "sidebarThreadPreviewCount")?;
            let page = general_page(world)?;
            let count = page_item(world, "settingsRow:sidebarThreadPreviewCount", "control")?;
            let value: f64 = c[0].parse().unwrap_or(0.0);
            page.write(world, count, "value", QmlValue::from(value))?;
            world
                .engine()
                .emit_by_name(count, "valueModified", &[])
                .map_err(|e| crate::harness::Failure(format!("valueModified: {e:?}")))?;
            world.sync()
        },
    );
    steps.step(
        r"each project shows (\d+) threads before offering more",
        |world, c, _| {
            world.sync()?;
            let shop = tree_project(world, "shop")?;
            expect!(
                titles(&shop).len() == c[0].parse::<usize>().unwrap_or(usize::MAX)
                    && shop["more"] == json!("more"),
                "shop shows {}, offering {}",
                titles(&shop).join(", "),
                show(&shop["more"])
            );
            Ok(())
        },
    );

    // Sorting, from the list's sort menu.
    steps.step(
        &format!("{Q}, {Q} and {Q} have threads started and written at different times"),
        |world, c, _| {
            let blog = &c[2];
            add_project(world, blog, &format!("/work/{blog}"), json!({}));
            let at = |time: &str| format!("2026-09-23T{time}:00Z");
            // Written in last: shop, docs, blog. Started last: docs,
            // shop, blog.
            add_thread(world, "cart", &c[0], "Cart", &at("09:00"), &at("09:50"));
            add_thread(
                world,
                "checkout",
                &c[0],
                "Checkout",
                &at("09:30"),
                &at("09:10"),
            );
            add_thread(world, "guide", &c[1], "Guide", &at("09:40"), &at("09:20"));
            add_thread(world, "faq", &c[1], "FAQ", &at("09:05"), &at("09:45"));
            add_thread(world, "post", blog, "Post", &at("09:20"), &at("09:30"));
            world.sync()
        },
    );
    steps.step(
        &format!("the user once arranged the projects {Q}, {Q} and {Q} by hand"),
        |world, c, _| {
            let order = arranged_order(world, c);
            write_device(world, "sidebarProjectOrder", json!(order))
        },
    );
    steps.step(
        &format!("the user sorts (projects|threads) by {Q}"),
        |world, c, _| sort_by(world, &c[0], &c[1]),
    );
    steps.step(&format!("projects are sorted {Q}"), |world, c, _| {
        let value = sort_value(&c[0])?;
        write_device(world, "sidebarProjectSortOrder", json!(value))
    });
    for (phrase, expected) in [
        (
            "by the latest message the user sent in each",
            vec!["shop", "docs", "blog"],
        ),
        (
            "by when each project's threads were started",
            vec!["docs", "shop", "blog"],
        ),
        (
            "in the order the user arranged them",
            vec!["blog", "shop", "docs"],
        ),
    ] {
        steps.step(
            &format!("projects are listed {phrase}"),
            move |world, _, _| {
                world.sync()?;
                expect!(
                    tree_names(world) == expected,
                    "the projects are {}",
                    tree_names(world).join(", ")
                );
                Ok(())
            },
        );
    }
    for (phrase, shop, docs) in [
        (
            "by the latest message the user sent in each",
            vec!["Cart", "Checkout"],
            vec!["FAQ", "Guide"],
        ),
        (
            "by when each thread was started",
            vec!["Checkout", "Cart"],
            vec!["Guide", "FAQ"],
        ),
    ] {
        steps.step(
            &format!("threads are listed {phrase}"),
            move |world, _, _| {
                world.sync()?;
                let shop_titles = titles(&tree_project(world, "shop")?);
                let docs_titles = titles(&tree_project(world, "docs")?);
                expect!(
                    shop_titles == shop && docs_titles == docs,
                    "shop lists {}, docs {}",
                    shop_titles.join(", "),
                    docs_titles.join(", ")
                );
                Ok(())
            },
        );
    }

    // Dragging a project's header onto another's.
    steps.step("the user's order is remembered", |world, _, _| {
        let order = Settings::of(world.engine()).device_value("sidebarProjectOrder");
        let expected = arranged_order(world, &tree_names(world));
        let kept: Vec<String> = order
            .as_ref()
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
            .map(|v| text(v))
            .collect();
        expect!(
            kept == expected,
            "the device keeps {}",
            show(&order.unwrap_or(Value::Null))
        );
        Ok(())
    });
    steps.step("dragging a project does not move it", |world, _, _| {
        world.sync()?;
        let before = tree_names(world);
        let order = Settings::of(world.engine()).device_value("sidebarProjectOrder");
        for project in tree(world) {
            expect!(
                project["draggable"] != json!(true),
                "{} can be dragged",
                text(&project["displayName"])
            );
        }
        let projects = tree(world);
        world.dispatch(
            "sidebar.project.drop",
            json!({
                "projectKey": projects.last().map(|p| p["key"].clone()).unwrap_or(Value::Null),
                "targetKey": projects.first().map(|p| p["key"].clone()).unwrap_or(Value::Null),
            }),
        )?;
        world.sync()?;
        expect!(
            tree_names(world) == before
                && Settings::of(world.engine()).device_value("sidebarProjectOrder") == order,
            "the projects are {}",
            tree_names(world).join(", ")
        );
        Ok(())
    });

    // Renaming, from the project's menu.
    steps.step(
        &format!("the user renames {Q} from its menu to {Q}"),
        |world, c, _| {
            open_project_menu(world, &c[0])?;
            choose(world, &["Rename"])?;
            let renaming = world.state("projectRename");
            expect!(
                text(&renaming["title"]) == c[0],
                "the rename dialog is {}",
                show(&renaming)
            );
            world.dispatch("project.rename.submit", json!({"title": c[1]}))?;
            world.sync()
        },
    );
    steps.step(&format!("{Q} is now called {Q}"), |world, c, _| {
        let wanted = c[1].clone();
        world.wait_for_with(
            move |w| tree_names(w).contains(&wanted) && w.state("projectRename").is_null(),
            |w| format!("the projects are {}", tree_names(w).join(", ")),
        )?;
        let sent = world.mc.part::<FakeProjects>().mutations.clone();
        expect!(
            sent.len() == 1
                && text(&sent[0]["projectId"]) == c[0]
                && text(&sent[0]["title"]) == c[1],
            "the MC was sent {}",
            sent.len()
        );
        Ok(())
    });
    steps.step("nothing is sent and the dialog closes", |world, _, _| {
        world.sync()?;
        expect!(
            world.mc.part::<FakeProjects>().mutations.is_empty(),
            "a change was sent"
        );
        expect!(
            world.state("projectRename").is_null(),
            "the rename dialog is still open"
        );
        Ok(())
    });
    steps.step(
        &format!("the environment refuses to rename {Q}"),
        |world, _, _| {
            world.mc.part::<FakeProjects>().refusal = "Project titles are locked.".into();
            Ok(())
        },
    );

    // Grouping, from the project's menu.
    steps.step(
        &format!("{Q} sits in the repository folder {Q}, as {Q} does in another copy of it"),
        |world, c, _| {
            let identity =
                |root: &str| json!({"canonicalKey": "github.com/acme/shop", "rootPath": root});
            add_project(
                world,
                &c[0],
                &format!("/work/acme/{}", c[0]),
                identity("/work/acme"),
            );
            add_project(world, &c[1], "/work/acme", identity("/work/acme"));
            add_project(
                world,
                &c[2],
                &format!("/home/sam/acme/{}", c[0]),
                identity("/home/sam/acme"),
            );
            world.sync()
        },
    );
    steps.step(
        "the device groups projects by repository path",
        |world, _, _| {
            write_device(
                world,
                "sidebarProjectGroupingMode",
                json!("repository_path"),
            )
        },
    );
    steps.step(
        &format!("the user groups {Q} by {Q} from its menu"),
        |world, c, _| {
            open_project_menu(world, &c[0])?;
            let choice = if c[1] == "the device's default" {
                "Use global default".to_owned()
            } else {
                c[1].clone()
            };
            let folder = folder_of(world, &c[0]);
            choose(world, &["Group into...", &folder, &choice])
        },
    );
    for (phrase, expected) in [
        (
            "with the other folders of its repository",
            vec!["shop", "acme"],
        ),
        (
            "with the folders of its repository path",
            vec!["shop", "shop-copy"],
        ),
        ("on its own", vec!["shop"]),
        // By repository path.
        (
            "the way the device's default says",
            vec!["shop", "shop-copy"],
        ),
    ] {
        steps.step(&format!("{Q} is grouped {phrase}"), move |world, c, _| {
            world.sync()?;
            let mut members: Vec<String> = at(&tree_project(world, &c[0])?, "memberKeys")
                .as_array()
                .into_iter()
                .flatten()
                .map(|k| text(k))
                .collect();
            let mut wanted: Vec<String> = expected
                .iter()
                .map(|project| member_key(world, project))
                .collect();
            members.sort();
            wanted.sort();
            expect!(
                members == wanted,
                "{} is grouped with {}",
                c[0],
                members.join(", ")
            );
            Ok(())
        });
    }

    // Removing, from the project's menu.
    steps.step(
        &format!("the user removes {Q} from its menu"),
        |world, c, _| {
            open_project_menu(world, &c[0])?;
            choose(world, &["Remove"])
        },
    );
    steps.step(&format!("the user is offered {Q}"), |world, c, _| {
        world.sync()?;
        for toast in toast_items(world) {
            for action in at(&toast, "actions").as_array().into_iter().flatten() {
                if text(&action["label"]) == c[0] {
                    return Ok(());
                }
            }
        }
        fail!("the toasts are {}", show(&Value::Array(toast_items(world))))
    });
    steps.step(
        &format!("the user chooses {Q} and confirms"),
        |world, c, _| {
            world.sync()?;
            for toast in toast_items(world) {
                for action in at(&toast, "actions").as_array().into_iter().flatten() {
                    if text(&action["label"]) != c[0] {
                        continue;
                    }
                    world.dispatch(
                        "notification.action",
                        json!({"id": toast["id"], "actionId": action["id"]}),
                    )?;
                    world.sync()?;
                    let removal = world.state("projectRemoval");
                    expect!(removal.is_object(), "no removal is asked about");
                    world.dispatch("project.remove.confirm", json!({}))?;
                    world.sync()?;
                    return Ok(());
                }
            }
            fail!("the toasts are {}", show(&Value::Array(toast_items(world))))
        },
    );
    steps.step(
        &format!(r"{Q} and its (\d+) threads are removed"),
        |world, c, _| {
            let gone = c[0].clone();
            world.wait_for_with(
                move |w| !tree_names(w).contains(&gone),
                |w| format!("the projects are {}", tree_names(w).join(", ")),
            )?;
            let left = world
                .mc
                .threads
                .values()
                .filter(|row| text(&row["projectId"]) == c[0])
                .count();
            expect!(
                !world.mc.projects.contains_key(&c[0]) && left == 0,
                "{left} threads of {} are left",
                c[0]
            );
            let sent = world.mc.part::<FakeProjects>().mutations.clone();
            expect!(
                sent.last().is_some_and(|m| m["force"] == json!(true)),
                "the removal was not forced"
            );
            Ok(())
        },
    );
}
