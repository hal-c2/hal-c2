//! Project files in the Space sidebar and the page's prompt
//! (features/space/project-files.feature, features/space/prompt.feature):
//! desktop-qt's SpaceSteps.cpp, from "Project files in the Space sidebar" to
//! its end, and the project-file helpers it calls.

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::space::rows::Row;
use hal_c2_shell::controllers::space::{HISTORY_COMMAND, PICK_FILE, SCAN_FILES};
use ljos::prelude::Value as Qml;
use serde_json::{Map, Value, json};

use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::files_workspace as filesteps;
use crate::steps::space::{
    act, block_texts, column, current, describe, expect_shown, given, given_space, id_of_page,
    listed, look, open_spaces, row_text, settle_history, with_space,
};
use crate::steps::space_fake as fake;
use crate::steps::stream::{self, FakeStreams, PROJECT, THREAD};
use crate::world::World;
use crate::{expect, fail};

mod prompt;

// --- Project files, as the client offers them --------------------------------

/// The project `id` on this MC, with a thread of it the user could show its
/// files in.
fn ensure_project(world: &mut World, id: &str) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    }
    if !world.mc.projects.contains_key(id) {
        let row =
            json!({"id": id, "title": id, "workspaceRoot": format!("/work/{id}"), "scripts": []});
        world.mc.projects.insert(id.into(), row.clone());
        world.mc.send_row_of(id, &row, "project");
    }
    if !world.mc.threads.contains_key(THREAD) {
        let row = json!({"id": THREAD, "title": "Tax line", "projectId": id,
                         "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
        world.mc.threads.insert(THREAD.into(), row.clone());
        world.mc.send_row(THREAD, &row);
    }
    world.sync()
}

/// The Space files of `project` the client was last told of:
/// {relativePath: {kind, spaceId, pageId, title}}.
fn listed_files(world: &World, project: &str) -> Map<String, Value> {
    world.state("space")["files"][project]["paths"]
        .as_object()
        .cloned()
        .unwrap_or_default()
}

fn wait_for_files(world: &mut World, project: &str) -> Outcome {
    let p = project.to_owned();
    let q = project.to_owned();
    world.wait_for_with(
        move |w| !listed_files(w, &p).is_empty(),
        move |w| format!("the Space files of {q} to be listed; {}", describe(w)),
    )
}

/// A thread of `project` on show, on a worktree of it when `worktree`
/// (stream.rs's look_at_thread, with the worktree's path).
fn look_at_thread_on(world: &mut World, project: &str, worktree: bool) -> Outcome {
    if !worktree {
        return stream::look_at_thread(world, project);
    }
    let row = json!({"id": THREAD, "title": "Tax line", "projectId": project,
                     "worktreePath": format!("/work/{project}-worktree"),
                     "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    world.mc.threads.insert(THREAD.into(), row.clone());
    world.mc.send_row(THREAD, &row);
    world.sync()?;
    let environment = world.mc.environment_id.clone();
    let fake = world.mc.part::<FakeStreams>();
    fake.thread = THREAD.into();
    fake.environment = environment.clone();
    stream::look(world, &format!("{environment}:{THREAD}"), true)
}

/// The Files tab of a thread of `project`, on a worktree of it when
/// `worktree`, with its Space files known.
fn browse_files(world: &mut World, project: &str, worktree: bool) -> Outcome {
    look_at_thread_on(world, project, worktree)?;
    filesteps::show_panel(world)?;
    wait_for_files(world, project)
}

/// The Space `name`, made when the MC has none, as the scenario's.
fn space_named(world: &mut World, name: &str) -> Outcome<String> {
    for space in fake::all(&mut world.mc, fake::INDEX, "space") {
        if text(&space["name"]) == name {
            let id = text(&space["id"]);
            fake::fake(&mut world.mc).current = id.clone();
            return Ok(id);
        }
    }
    given_space(world, name)?;
    current(world)
}

/// Whether a toast's title starts with `start` (SpaceSteps.cpp's toldOf).
fn told_starting(world: &World, start: &str) -> bool {
    world.state("toasts")["items"]
        .as_array()
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| text(&item["title"]).starts_with(start))
        })
}

fn route_kind_is_space(world: &World) -> bool {
    world
        .with::<Navigation, _>(|n, _| matches!(n.route(), Route::Space))
        .unwrap_or(false)
}

fn shown_page(world: &World) -> Row {
    with_space(world, |s, engine| s.page(engine)).unwrap_or_default()
}

/// The page open in the Space view is `title`, in the Space `space` when one
/// is named.
fn expect_opened(world: &mut World, title: &str, space: &str) -> Outcome {
    let (t, s) = (title.to_owned(), space.to_owned());
    let what = if space.is_empty() {
        format!("the page {title} to be open")
    } else {
        format!("the page {title} to be open in {space}")
    };
    expect_shown(world, &what, move |w| {
        route_kind_is_space(w)
            && row_text(&shown_page(w), "title") == t
            && (s.is_empty() || with_space(w, |v, _| v.space_name()).unwrap_or_default() == s)
    })
}

fn shown_file(world: &World) -> Map<String, Value> {
    shown_page(world)
        .get("file")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

fn file_text(file: &Map<String, Value>, field: &str) -> String {
    text(file.get(field).unwrap_or(&Value::Null))
}

fn file_flag(file: &Map<String, Value>, field: &str) -> bool {
    file.get(field).and_then(Value::as_bool).unwrap_or(false)
}

/// The page `title` of a project's Space, with that Space.
fn file_page(world: &mut World, title: &str) -> Outcome<(String, Value)> {
    for space in fake::all(&mut world.mc, fake::INDEX, "projectSpace") {
        let id = text(&space["id"]);
        for page in fake::all(&mut world.mc, &fake::stream_of(&id), "page") {
            if text(&page["title"]) == title {
                return Ok((id, page));
            }
        }
    }
    fail!("no project's Space has the page {title}")
}

/// The Space the MC keeps for `project`'s files, empty when it has none yet
/// (space_fake.rs's project_space, without making one).
fn project_space_of(world: &World, project: &str) -> String {
    world
        .mc
        .peek::<FakeStreams>()
        .and_then(|streams| streams.threads.get(fake::INDEX))
        .into_iter()
        .flat_map(|entities| entities.iter())
        .filter(|(key, _)| key.starts_with("projectSpace\n"))
        .find(|(_, space)| text(&space["projectId"]) == project)
        .map(|(_, space)| text(&space["id"]))
        .unwrap_or_default()
}

/// The rows of the sidebar's project sections.
fn section_rows(world: &World) -> Vec<Row> {
    with_space(world, |s, _| s.rows("projects")).unwrap_or_default()
}

fn section_row(world: &World, kind: &str, project: &str, path: &str) -> Option<Row> {
    section_rows(world).into_iter().find(|row| {
        row_text(row, "kind") == kind
            && row_text(row, "projectId") == project
            && row_text(row, "path") == path
    })
}

fn expanded(row: &Row) -> bool {
    row.get("expanded")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn describe_sections(world: &World) -> String {
    let rows: Vec<String> = section_rows(world)
        .iter()
        .map(|row| {
            format!(
                "{} {} {}{}",
                row_text(row, "kind"),
                row_text(row, "projectId"),
                row_text(row, "path"),
                if expanded(row) { " (expanded)" } else { "" }
            )
        })
        .collect();
    format!(
        "the sections are [{}]; {}",
        rows.join(", "),
        describe(world)
    )
}

/// The Space view, on the scenario's Space when it has one.
fn look_at_sidebar(world: &mut World) -> Outcome {
    if fake::fake(&mut world.mc).current.is_empty() {
        open_spaces(world)
    } else {
        let space = current(world)?;
        look(world, &space)
    }
}

/// The section of `project`, shown in the Space view.
fn look_at_section(world: &mut World, project: &str) -> Outcome {
    look_at_sidebar(world)?;
    let (p, q) = (project.to_owned(), project.to_owned());
    world.wait_for_with(
        move |w| section_row(w, "project", &p, "").is_some(),
        move |w| format!("a section of {q}; {}", describe_sections(w)),
    )
}

fn set_section(world: &mut World, project: &str, open: bool) -> Outcome {
    look_at_section(world, project)?;
    act(
        world,
        "space.project.setExpanded",
        json!({"projectId": project, "expanded": open}),
    )?;
    let (p, q) = (project.to_owned(), project.to_owned());
    world.wait_for_with(
        move |w| section_row(w, "project", &p, "").is_some_and(|r| expanded(&r) == open),
        move |w| {
            format!(
                "the section of {q} to be {}; {}",
                if open { "expanded" } else { "collapsed" },
                describe_sections(w)
            )
        },
    )
}

fn wait_for_folder(world: &mut World, project: &str, path: &str, open: bool) -> Outcome {
    let (p, f) = (project.to_owned(), path.to_owned());
    let (q, g) = (project.to_owned(), path.to_owned());
    world.wait_for_with(
        move |w| section_row(w, "folder", &p, &f).is_some_and(|r| expanded(&r) == open),
        move |w| {
            format!(
                "the folder {g} of {q} to be {}; {}",
                if open { "expanded" } else { "collapsed" },
                describe_sections(w)
            )
        },
    )
}

fn set_folder(world: &mut World, project: &str, path: &str, open: bool) -> Outcome {
    look_at_section(world, project)?;
    let (p, f) = (project.to_owned(), path.to_owned());
    let (q, g) = (project.to_owned(), path.to_owned());
    world.wait_for_with(
        move |w| section_row(w, "folder", &p, &f).is_some(),
        move |w| {
            format!(
                "the section of {q} to show the folder {g}; {}",
                describe_sections(w)
            )
        },
    )?;
    act(
        world,
        "space.project.setExpanded",
        json!({"projectId": project, "path": path, "expanded": open}),
    )?;
    wait_for_folder(world, project, path, open)
}

/// The sidebar drawn, the folder's row given the keyboard, and Right or Left
/// pressed on it.
fn fold_from_keyboard(world: &mut World, project: &str, path: &str, open: bool) -> Outcome {
    look_at_section(world, project)?;
    let is_sidebar = world
        .part::<brick::Shown>()
        .0
        .and_then(|b| b.root(world))
        .map(|root| world.engine().read_by_name(root, "objectName"))
        .is_some_and(|name| matches!(name, Qml::String(s) if s.as_str() == "spaceSidebar"));
    if !is_sidebar {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nSpaceSidebar { objectName: \"spaceSidebar\"; width: 280; height: 700 }\n",
            280.0,
            700.0,
        )?;
    }
    let brick = brick::shown(world)?;
    let name = format!("spaceProjectFolder:{project}:{path}");
    let (n, p, f) = (name.clone(), project.to_owned(), path.to_owned());
    world.wait_for_with(
        move |w| brick.find_visible(w, &n).ok().flatten().is_some(),
        move |w| {
            format!(
                "the sidebar to draw the folder {f} of {p}; {}",
                describe_sections(w)
            )
        },
    )?;
    let Some(row) = brick.find_visible(world, &name)? else {
        fail!("the sidebar draws no folder {path} of {project}");
    };
    if let Err(error) = world.engine().invoke_by_name(row, "forceActiveFocus", &[]) {
        fail!("forceActiveFocus: {error:?}");
    }
    world.pump()?;
    expect!(
        brick.flag(world, row, "activeFocus"),
        "the folder {path} of {project} took no keyboard focus"
    );
    brick.press(world, if open { "right" } else { "left" })?;
    world.sync()?;
    wait_for_folder(world, project, path, open)
}

/// The file's page on show in the page editor, from its project's Space, its
/// row showing in the section: its section and its folders opened for it.
fn expect_file_page(world: &mut World, title: &str, project: &str) -> Outcome {
    expect_opened(world, title, "")?;
    let p = project.to_owned();
    let what = format!("the page {title} to be shown from its row in the section of {project}");
    world.wait_for_with(
        move |w| {
            let space = project_space_of(w, &p);
            let path = file_text(&shown_file(w), "path");
            !space.is_empty()
                && with_space(w, |s, _| s.file_space_id()).unwrap_or_default() == space
                && section_row(w, "project", &p, "").is_some_and(|r| expanded(&r))
                && with_space(w, |s, _| s.project_is_expanded(&p)).unwrap_or(false)
                && !path.is_empty()
                && section_row(w, "file", &p, &path).is_some()
        },
        move |w| format!("{what}; {}", describe_sections(w)),
    )
}

/// The user picks the page's file in its project's section, the client's way
/// to a file's page; the MC reads the file again each time.
fn look_at_file_page(world: &mut World, title: &str) -> Outcome {
    let (space, page) = file_page(world, title)?;
    let id = text(&page["id"]);
    let file = &page["file"];
    // Not by its row: a file that is gone has none, and its page says so.
    look_at_sidebar(world)?;
    act(
        world,
        "space.openFile",
        json!({"projectId": file["projectId"], "relativePath": file["path"]}),
    )?;
    let t = title.to_owned();
    world.wait_for_with(
        move |w| {
            with_space(w, |s, _| s.file_space_id() == space && s.page_id() == id).unwrap_or(false)
        },
        move |w| {
            format!(
                "the page {t} to be shown from its project's Space; {}",
                describe(w)
            )
        },
    )
}

/// The project of the thread on show.
fn shown_project(world: &World) -> String {
    let key = world
        .with::<Navigation, _>(|n, _| n.thread_key().to_owned())
        .unwrap_or_default();
    let id = key.rsplit(':').next().unwrap_or_default();
    world
        .mc
        .threads
        .get(id)
        .map(|t| text(&t["projectId"]))
        .unwrap_or_default()
}

fn route_is_thread(world: &World) -> bool {
    world
        .with::<Navigation, _>(|n, _| matches!(n.route(), Route::Thread(_)))
        .unwrap_or(false)
}

/// The panel's entry `entry` of the menu `menu_name` (files_workspace.rs's
/// menu_entry, which is its own).
fn menu_entry(
    world: &World,
    brick: Brick,
    menu_name: &str,
    entry: &str,
) -> Outcome<Option<ljos::prelude::ObjectId>> {
    let Some(menu) = brick.find(world, menu_name)? else {
        fail!("the Files tab has no {menu_name}");
    };
    let engine = world.engine();
    let count = match engine.read_by_name(menu, "count") {
        Qml::Int(n) => n,
        _ => 0,
    };
    for index in 0..count {
        if let Ok(Qml::Object(item)) = engine.invoke_by_name(menu, "itemAt", &[Qml::Int(index)])
            && engine.read_by_name(item, "objectName") == Qml::from(entry)
        {
            return Ok(Some(item));
        }
    }
    Ok(None)
}

fn unescape(said: &str) -> String {
    said.replace("\\n", "\n")
}

fn run_command(world: &mut World, command: &str) -> Outcome<bool> {
    let ran = Commands::of(world.engine()).run(world.engine(), command);
    world.pump()?;
    Ok(ran)
}

pub fn register(steps: &mut Steps) {
    register_sections(steps);
    register_pages(steps);
    prompt::register(steps);
}

fn register_sections(steps: &mut Steps) {
    steps.step(
        &format!("{Q} has the file {Q} reading {Q}"),
        |world, c, _| {
            ensure_project(world, &c[0])?;
            fake::set_file(&mut world.mc, &c[0], &c[1], &unescape(&c[2]));
            Ok(())
        },
    );
    steps.step(
        &format!("the project {Q} has the file {Q} reading {Q}"),
        |world, c, _| {
            ensure_project(world, &c[0])?;
            fake::set_file(&mut world.mc, &c[0], &c[1], &unescape(&c[2]));
            Ok(())
        },
    );
    steps.step(
        &format!("the project {Q} has no Space files"),
        |world, c, _| ensure_project(world, &c[0]),
    );
    steps.step(&format!("the user is in the Space {Q}"), |world, c, _| {
        let space = space_named(world, &c[0])?;
        look(world, &space)
    });
    steps.step(
        &format!("the sidebar's project sections are {Q}"),
        |world, c, _| {
            open_spaces(world)?;
            let wanted = listed(&c[0]);
            let said = c[0].clone();
            world.wait_for_with(
                move |w| {
                    let projects: Vec<String> = section_rows(w)
                        .iter()
                        .filter(|row| row_text(row, "kind") == "project")
                        .map(|row| row_text(row, "projectId"))
                        .collect();
                    projects == wanted
                },
                move |w| {
                    format!(
                        "the project sections to be {said}; {}",
                        describe_sections(w)
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the section of {Q} is collapsed"),
        |world, c, _| {
            look_at_section(world, &c[0])?;
            let (p, q) = (c[0].clone(), c[0].clone());
            world.wait_for_with(
                move |w| {
                    !section_rows(w).iter().any(|row| {
                        row_text(row, "projectId") == p
                            && (row_text(row, "kind") != "project" || expanded(row))
                    })
                },
                move |w| {
                    format!(
                        "the section of {q} to be collapsed; {}",
                        describe_sections(w)
                    )
                },
            )
        },
    );
    steps.step(&format!("the section of {Q} is expanded"), |world, c, _| {
        look_at_section(world, &c[0])?;
        let (p, q) = (c[0].clone(), c[0].clone());
        world.wait_for_with(
            move |w| section_row(w, "project", &p, "").is_some_and(|r| expanded(&r)),
            move |w| {
                format!(
                    "the section of {q} to be expanded; {}",
                    describe_sections(w)
                )
            },
        )
    });
    steps.step(
        &format!("the user (?:expands|expanded) the section of {Q}"),
        |world, c, _| set_section(world, &c[0], true),
    );
    steps.step(
        &format!("the user collapses the section of {Q}"),
        |world, c, _| set_section(world, &c[0], false),
    );
    steps.step(
        &format!("the folder {Q} of {Q} is collapsed"),
        |world, c, _| {
            look_at_section(world, &c[1])?;
            wait_for_folder(world, &c[1], &c[0], false)?;
            let (p, f) = (c[1].clone(), format!("{}/", c[0]));
            let (q, g) = (c[1].clone(), c[0].clone());
            world.wait_for_with(
                move |w| {
                    !section_rows(w).iter().any(|row| {
                        row_text(row, "projectId") == p && row_text(row, "path").starts_with(&f)
                    })
                },
                move |w| {
                    format!(
                        "nothing in the folder {g} of {q} to show; {}",
                        describe_sections(w)
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user (?:expands|expanded) the folder {Q} of {Q}"),
        |world, c, _| set_folder(world, &c[1], &c[0], true),
    );
    steps.step(
        &format!("the user collapses the folder {Q} of {Q}"),
        |world, c, _| set_folder(world, &c[1], &c[0], false),
    );
    steps.step(
        &format!("the user expands the folder {Q} of {Q} from the keyboard"),
        |world, c, _| fold_from_keyboard(world, &c[1], &c[0], true),
    );
    steps.step(
        &format!("the user collapses the folder {Q} of {Q} from the keyboard"),
        |world, c, _| fold_from_keyboard(world, &c[1], &c[0], false),
    );
    steps.step(
        &format!("the section of {Q} shows {Q} in the folder {Q}"),
        |world, c, _| {
            look_at_section(world, &c[0])?;
            let (project, name, folder) = (c[0].clone(), c[1].clone(), c[2].clone());
            let said = format!("the section of {} to show {} in {}", c[0], c[1], c[2]);
            world.wait_for_with(
                move |w| {
                    let rows = section_rows(w);
                    rows.windows(2).any(|pair| {
                        let (dir, file) = (&pair[0], &pair[1]);
                        let depth = |r: &Row| r.get("depth").and_then(Value::as_i64).unwrap_or(0);
                        row_text(dir, "kind") == "folder"
                            && row_text(dir, "projectId") == project
                            && row_text(dir, "path") == folder
                            && row_text(file, "kind") == "file"
                            && row_text(file, "path") == format!("{folder}/{name}")
                            && row_text(file, "name") == name
                            && depth(file) == depth(dir) + 1
                    })
                },
                move |w| format!("{said}; {}", describe_sections(w)),
            )
        },
    );
    steps.step("the client starts again", |world, _, _| {
        world.restart()?;
        world.connect()
    });
    steps.step(
        &format!("the user picks {Q} in the section of {Q}"),
        |world, c, _| {
            // Through its folders, as the user opens them to reach it.
            let parts: Vec<&str> = c[0].split('/').collect();
            for i in 1..parts.len() {
                set_folder(world, &c[1], &parts[..i].join("/"), true)?;
            }
            let (p, f) = (c[1].clone(), c[0].clone());
            let said = format!("the section of {} to show {}", c[1], c[0]);
            world.wait_for_with(
                move |w| section_row(w, "file", &p, &f).is_some(),
                move |w| format!("{said}; {}", describe_sections(w)),
            )?;
            act(
                world,
                "space.openFile",
                json!({"projectId": c[1], "relativePath": c[0]}),
            )
        },
    );
    steps.step(
        &format!("the page editor shows the page {Q}"),
        |world, c, _| expect_opened(world, &c[0], ""),
    );
    steps.step(
        &format!("the page editor shows the page {Q} in the section of {Q}"),
        |world, c, _| expect_file_page(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("the page {Q} is not among the pages of {Q}"),
        |world, c, _| {
            let space = space_named(world, &c[1])?;
            let (shown, name) =
                with_space(world, |s, _| (s.space_id().to_owned(), s.space_name()))?;
            expect!(shown == space, "the sidebar shows {name}, not {}", c[1]);
            expect!(
                !column(world, "pages", "title").contains(&c[0]),
                "the sidebar lists {} among the pages of {}",
                c[0],
                c[1]
            );
            let pages = fake::all(&mut world.mc, &fake::stream_of(&space), "page");
            expect!(
                !pages.iter().any(|page| text(&page["title"]) == c[0]),
                "the MC put {} in {}",
                c[0],
                c[1]
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is editing {Q} of {Q} from its section"),
        |world, c, _| {
            set_section(world, &c[1], true)?;
            act(
                world,
                "space.openFile",
                json!({"projectId": c[1], "relativePath": c[0]}),
            )?;
            let (project, path) = (c[1].clone(), c[0].clone());
            let said = format!("{} to be shown from its section", c[0]);
            world.wait_for_with(
                move |w| {
                    let space = project_space_of(w, &project);
                    !space.is_empty()
                        && with_space(w, |s, _| s.file_space_id()).unwrap_or_default() == space
                        && file_text(&shown_file(w), "path") == path
                },
                move |w| format!("{said}; {}", describe(w)),
            )
        },
    );
    steps.step(
        &format!("the user picks the page {Q} in the sidebar"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act(world, "space.selectPage", json!({"pageId": page}))
        },
    );
}

fn register_pages(steps: &mut Steps) {
    steps.step(
        &format!("the user is browsing the files of {Q}"),
        |world, c, _| {
            let worktree = fake::fake(&mut world.mc).on_worktree;
            browse_files(world, &c[0], worktree)
        },
    );
    steps.step(
        &format!("the user picks \"Edit as a page\" on {Q}"),
        |world, c, _| {
            filesteps::choose(world, &c[0], "fileEntryEditAsPage")?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user is reading {Q} in the file viewer"),
        |world, c, _| {
            browse_files(world, PROJECT, false)?;
            filesteps::open_file(world, &c[0])
        },
    );
    steps.step(
        "the user picks \"Edit as a page\" in the file viewer",
        |world, _, _| {
            let brick = brick::shown(world)?;
            world.wait_for("the viewer to offer editing the file as a page", move |w| {
                brick
                    .find(w, "fileEditAsPage")
                    .ok()
                    .flatten()
                    .is_some_and(|item| brick.flag(w, item, "visible"))
            })?;
            brick.click(world, "fileEditAsPage")?;
            world.sync()
        },
    );
    steps.step(
        &format!("the agent's message in a thread of {Q} links {Q}"),
        |world, c, _| {
            stream::look_at_thread(world, &c[0])?;
            wait_for_files(world, &c[0])?;
            stream::add_item(
                world,
                "assistant_message",
                json!({"text": format!("See [the guide]({}).", c[1])}),
            )?;
            fake::fake(&mut world.mc).link = c[1].clone();
            Ok(())
        },
    );
    steps.step(
        "the user picks \"Edit as a page\" on that link",
        |world, _, _| {
            let link = fake::fake(&mut world.mc).link.clone();
            world.dispatch("link.menu", json!({"url": link, "x": 10, "y": 10}))?;
            world.wait_for("the link's menu to open", |w| {
                w.state("menu")["items"]
                    .as_array()
                    .is_some_and(|items| !items.is_empty())
            })?;
            let menu = world.state("menu");
            let items = menu["items"].as_array().cloned().unwrap_or_default();
            expect!(
                items.iter().any(|item| item["id"] == "edit-as-page"),
                "the link's menu offers {}",
                show(&Value::Array(items.clone()))
            );
            world.dispatch(
                "menu.select",
                json!({"requestId": menu["requestId"], "id": "edit-as-page"}),
            )?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user asks the command palette to edit {Q} of {Q} as a page"),
        |world, c, _| {
            ensure_project(world, &c[1])?;
            expect!(
                run_command(world, PICK_FILE)?,
                "the palette has no command to edit a file as a page"
            );
            let (p, q) = (c[1].clone(), c[1].clone());
            world.wait_for_with(
                move |w| text(&w.state("space")["picking"]) == p,
                move |w| format!("the files of {q} to be offered; {}", describe(w)),
            )?;
            wait_for_files(world, &c[1])?;
            let files = listed_files(world, &c[1]);
            expect!(
                files.contains_key(&c[0]),
                "{} is not offered: {}",
                c[0],
                show(&Value::Object(files.clone()))
            );
            act(
                world,
                "space.openFile",
                json!({"projectId": c[1], "relativePath": c[0]}),
            )
        },
    );
    steps.step(
        &format!("the user asks the command palette to scan {Q} for Space files"),
        |world, c, _| {
            ensure_project(world, &c[0])?;
            expect!(
                run_command(world, SCAN_FILES)?,
                "the palette has no command to scan for Space files"
            );
            world.sync()
        },
    );
    steps.step(
        "the user is told the scan wrote the spaces section",
        |world, _, _| {
            expect_shown(
                world,
                "a toast that the scan wrote the spaces section",
                |w| told_starting(w, "Wrote the spaces section"),
            )
        },
    );
    steps.step(
        &format!("{Q} offers no \"Edit as a page\""),
        |world, c, _| {
            let brick = brick::shown(world)?;
            let Some(menu) = brick.find(world, "fileEntryMenu")? else {
                fail!("the Files tab has no entry menu");
            };
            brick.write(world, menu, "path", Qml::from(c[0].as_str()))?;
            let item = menu_entry(world, brick, "fileEntryMenu", "fileEntryEditAsPage")?;
            expect!(
                item.is_none_or(
                    |i| !brick.flag(world, i, "visible") && !brick.flag(world, i, "enabled")
                ),
                "the menu of {} offers editing it as a page",
                c[0]
            );
            // The Markdown beside it is offered, so the menu is not merely waiting.
            brick.write(world, menu, "path", Qml::from("docs/guide.md"))?;
            expect!(
                item.is_some_and(|i| brick.flag(world, i, "enabled")),
                "the menu of docs/guide.md does not offer editing it as a page"
            );
            Ok(())
        },
    );
    // The worktree's copy is the thread's alone; the MC lists and opens the
    // project folder's files.
    steps.step(
        &format!("a thread of {Q} works in a worktree where {Q} reads {Q}"),
        |world, c, _| {
            ensure_project(world, &c[0])?;
            fake::fake(&mut world.mc).on_worktree = true;
            Ok(())
        },
    );
    steps.step(
        &format!("the user picks \"Edit the project's copy as a page\" on {Q}"),
        |world, c, _| {
            let worktree = fake::fake(&mut world.mc).on_worktree;
            browse_files(world, PROJECT, worktree)?;
            filesteps::choose(world, &c[0], "fileEntryEditAsPage")?;
            let brick = brick::shown(world)?;
            let item = menu_entry(world, brick, "fileEntryMenu", "fileEntryEditAsPage")?;
            let said = item
                .map(|i| brick.text_of(world, i, "text"))
                .unwrap_or_default();
            expect!(
                said == "Edit the project's copy as a page",
                "the entry did not say it edits the project's copy: {said}"
            );
            world.sync()
        },
    );
    steps.step(&format!("the page {Q} shows {Q}"), |world, c, _| {
        // Already open where the file opened it, its project's Space rather
        // than the scenario's.
        if row_text(&shown_page(world), "title") != c[0] {
            look_at_file_page(world, &c[0])?;
        }
        let said = c[1].clone();
        expect_shown(
            world,
            &format!("the page {} to say {}", c[0], c[1]),
            move |w| block_texts(w).contains(&said),
        )
    });
    steps.step(&format!("the user has opened {Q} of {Q}"), |world, c, _| {
        ensure_project(world, &c[1])?;
        let answer = fake::call(
            &mut world.mc,
            "page.openFile",
            &json!({"projectId": c[1], "relativePath": c[0]}),
        );
        expect!(
            answer.error.is_empty(),
            "the MC refused space.page.openFile: {}",
            answer.error
        );
        world.sync()
    });
    steps.step(&format!("the user shows the page {Q}"), |world, c, _| {
        look_at_file_page(world, &c[0])
    });
    steps.step(
        &format!("the page says it is the file {Q} of {Q}"),
        |world, c, _| {
            let (path, project) = (c[0].clone(), c[1].clone());
            expect_shown(
                world,
                &format!("the page to say it is {} of {}", c[0], c[1]),
                move |w| {
                    let file = shown_file(w);
                    file_text(&file, "path") == path
                        && file_text(&file, "projectTitle") == project
                        && !file_flag(&file, "missing")
                        && file_text(&file, "conflictAt").is_empty()
                },
            )?;
            world.wait_for("showing the page to read its file again", |w| {
                w.mc.peek::<fake::FakeSpaces>()
                    .is_some_and(|f| f.syncs >= 1)
            })
        },
    );
    steps.step(
        &format!("the user shows the file of the page {Q}"),
        |world, c, _| {
            look_at_file_page(world, &c[0])?;
            expect_shown(world, "the page to say it is a file", |w| {
                !shown_file(w).is_empty()
            })?;
            let page = with_space(world, |s, _| s.page_id().to_owned())?;
            act(world, "space.page.showFile", json!({"pageId": page}))
        },
    );
    steps.step(
        &format!("the file viewer shows {Q} of {Q}"),
        |world, c, _| {
            let (path, project) = (c[0].clone(), c[1].clone());
            let (p, q) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| {
                    route_is_thread(w)
                        && shown_project(w) == project
                        && filesteps::open_path(w) == path
                },
                move |w| {
                    format!(
                        "the Files tab of {q} to show {p}; it shows \"{}\" of {}",
                        filesteps::open_path(w),
                        shown_project(w)
                    )
                },
            )
        },
    );
    steps.step("the thread's row changes (\\d+) times", |world, c, _| {
        fake::fake(&mut world.mc).listings = 0;
        let times: i64 = c[0].parse().unwrap_or(0);
        for i in 0..times {
            let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or_default();
            row["updatedAt"] = json!(format!("2026-09-23T09:{:02}:00Z", i + 1));
            world.mc.threads.insert(THREAD.into(), row.clone());
            world.mc.send_row(THREAD, &row);
        }
        world.sync()
    });
    steps.step(
        &format!("the MC is not asked for the files of {Q} again"),
        |world, _, _| {
            world.sync()?;
            let listings = fake::fake(&mut world.mc).listings;
            if listings != 0 {
                fail!("the MC was asked for them {listings} more times");
            }
            Ok(())
        },
    );
    steps.step(
        &format!("a newer thread of {Q} works in a worktree"),
        |world, c, _| {
            ensure_project(world, &c[0])?;
            let id = "thread-worktree";
            let row = json!({"id": id, "title": "Draft", "projectId": c[0],
                             "worktreePath": format!("/work/{}-worktree", c[0]),
                             "createdAt": "2026-09-23T10:00:00Z", "updatedAt": "2026-09-23T10:00:00Z"});
            world.mc.threads.insert(id.into(), row.clone());
            world.mc.send_row(id, &row);
            world.sync()
        },
    );
    steps.step(
        &format!("the file viewer shows the project's own {Q} of {Q}"),
        |world, c, _| {
            let key = format!("{}:{THREAD}", world.mc.environment_id);
            let (k, path) = (key.clone(), c[0].clone());
            let (project, p) = (c[1].clone(), c[0].clone());
            world.wait_for_with(
                move |w| {
                    w.with::<Navigation, _>(|n, _| n.thread_key() == k)
                        .unwrap_or(false)
                        && filesteps::open_path(w) == path
                },
                move |w| {
                    format!(
                        "the Files tab of {project}'s thread on its folder ({key}) to show {p}; the route is {}, showing \"{}\"",
                        w.with::<Navigation, _>(|n, _| n.thread_key().to_owned())
                            .unwrap_or_default(),
                        filesteps::open_path(w)
                    )
                },
            )
        },
    );
    steps.step(&format!("an agent in {Q} deleted {Q}"), |world, c, _| {
        fake::remove_file(&mut world.mc, &c[0], &c[1]);
        // As the MC's watcher sees it go.
        let (space, page) = fake::page_of_file(&mut world.mc, &c[0], &c[1]);
        if page.as_object().is_some_and(|p| !p.is_empty()) {
            fake::lose_file(&mut world.mc, &space, &page);
        }
        world.sync()
    });
    steps.step("the page says its file is gone", |world, _, _| {
        expect_shown(world, "the page to say its file is gone", |w| {
            file_flag(&shown_file(w), "missing")
        })
    });
    steps.step(
        &format!("the file won over the user's edit of {Q}"),
        |world, c, _| {
            let (space, found) = file_page(world, &c[0])?;
            let page = text(&found["id"]);
            given(
                world,
                "block.insert",
                json!({"spaceId": space, "pageId": page, "kind": "paragraph",
                       "text": "An edit of mine.", "checked": false}),
            )?;
            let file = &found["file"];
            let (project, path) = (text(&file["projectId"]), text(&file["path"]));
            let contents = fake::files_of(&mut world.mc, &project)
                .get(&path)
                .cloned()
                .unwrap_or_default();
            fake::set_file(
                &mut world.mc,
                &project,
                &path,
                &format!("{contents}\n\nAn agent's line."),
            );
            let at = fake::stamp(&mut world.mc);
            fake::take_file(&mut world.mc, &space, &page, &json!({"conflictAt": at}));
            fake::note_edits(&mut world.mc, &space, &fake::file_author());
            world.sync()
        },
    );
    steps.step(
        "the page says the file changed under the user's edit and the edit is in its history",
        |world, _, _| {
            expect_shown(world, "the page to say the file won", |w| {
                !file_text(&shown_file(w), "conflictAt").is_empty()
            })?;
            // The page on show is its project Space's, not the scenario's.
            let (page, history) = with_space(world, |s, _| {
                (s.page_id().to_owned(), s.history().page_id().to_owned())
            })?;
            if history != page {
                act(world, HISTORY_COMMAND, json!({"pageId": page}))?;
            }
            settle_history(world)?;
            expect_shown(
                world,
                "the history to hold the file's version over the user's edit",
                |w| {
                    let versions = with_space(w, |s, _| s.history().versions()).unwrap_or_default();
                    let by_file =
                        |r: &Row| r.get("byFile").and_then(Value::as_bool).unwrap_or(false);
                    versions.len() >= 2 && by_file(&versions[0]) && !by_file(&versions[1])
                },
            )
        },
    );
    steps.step(
        &format!("{Q} of {Q} was rewritten outside HAL-C2 to {Q}"),
        |world, c, _| {
            fake::set_file(&mut world.mc, &c[1], &c[0], &unescape(&c[2]));
            Ok(())
        },
    );
}
