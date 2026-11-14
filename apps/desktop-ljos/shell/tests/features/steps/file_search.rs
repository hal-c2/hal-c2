//! Finding files by name and text across a project from the command
//! palette's go to file and project search modes (features/files/search.feature,
//! desktop-qt's FileSearchSteps.cpp), against the files FakeFiles holds.

use std::collections::BTreeSet;

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::palette::Palette;
use serde_json::json;

use super::add_project::{
    count, describe, id_at, is_open, kind_at, prop, role_text, searching, set_query,
};
use super::fake_files::fake_files;
use super::files_workspace::{int_prop, open_path};
use super::stream::look_at_thread;
use crate::harness::{Outcome, Q, Steps};
use crate::world::World;
use crate::{expect, fail};

/// The content search's query, kept until the user searches.
#[derive(Default)]
struct PendingSearch {
    query: String,
    regex: bool,
}

/// Waits for the palette's answers from the MC.
fn settle(world: &mut World) -> Outcome {
    world.sync()?;
    world.wait_for("the palette's searches to be answered", |w| !searching(w))
}

fn search_in(world: &mut World, mode: &str, query: &str) -> Outcome {
    let in_mode = is_open(world) && prop(world, "mode")? == mode;
    if !in_mode {
        let mode = mode.to_owned();
        world.with::<Palette, _>(|p, engine| p.toggle_mode(engine, &mode))?;
    }
    set_query(world, query)?;
    settle(world)
}

fn row_of(world: &World, kind: &str, id: &str) -> Option<usize> {
    (0..count(world)).find(|&row| {
        kind_at(world, row) == kind
            && (id.is_empty() || {
                let at = id_at(world, row);
                at == id || at.starts_with(&format!("{id}:"))
            })
    })
}

fn opens(world: &mut World, path: &str, line: i64) -> Outcome {
    world.wait_for_with(
        |w| open_path(w) == path && (line < 0 || int_prop(w, "revealLine") == line),
        |w| {
            format!(
                "the viewer shows \"{}\" at line {}",
                open_path(w),
                int_prop(w, "revealLine")
            )
        },
    )?;
    expect!(!is_open(world), "{}", describe(world));
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("{Q} holds {Q}, {Q}, {Q} and {Q}"),
        |world, c, _| {
            let files = fake_files(&mut world.mc);
            for path in &c[1..5] {
                files.files.insert(path.clone(), format!("// {path}\n"));
            }
            look_at_thread(world, &c[0])
        },
    );
    steps.step(&format!("{Q} contains the line {Q}"), |world, c, _| {
        let file = fake_files(&mut world.mc)
            .files
            .entry(c[0].clone())
            .or_default();
        file.push_str(&c[1]);
        file.push('\n');
        Ok(())
    });

    // Go to file.
    steps.step(
        &format!("the user goes to a file and types {Q}"),
        |world, c, _| search_in(world, "files", &c[0]),
    );
    // "the user picks" a file is SidebarSteps' step, from the open palette.
    steps.step(&format!("{Q} opens in the viewer"), |world, c, _| {
        opens(world, &c[0], -1)
    });
    steps.step("the user is told no files match", |world, _, _| {
        settle(world)?;
        let empty = prop(world, "emptyText")?;
        expect!(
            count(world) == 0 && empty == "No matching files.",
            "{}",
            describe(world)
        );
        Ok(())
    });

    // Project search.
    steps.step(
        &format!("the user searches the project contents for {Q}"),
        |world, c, _| search_in(world, "content", &c[0]),
    );
    steps.step(
        &format!("the user searched the project contents of {Q} for {Q}"),
        |world, c, _| {
            search_in(world, "content", &c[1])?;
            expect!(count(world) > 0, "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        &format!("the matches are grouped under {Q}"),
        |world, c, _| {
            let grouped = row_of(world, "match", &c[0])
                .is_some_and(|row| role_text(world, row, "group") == c[0]);
            expect!(grouped, "{}", describe(world));
            Ok(())
        },
    );
    steps.step("the user opens the match", |world, _, _| {
        let Some(row) = row_of(world, "match", "") else {
            fail!("{}", describe(world));
        };
        let ran = world.with::<Palette, _>(|p, engine| p.run(engine, row as i32))?;
        expect!(ran, "{}", describe(world));
        world.sync()
    });
    steps.step(&format!("{Q} opens at the matching line"), |world, c, _| {
        let contents = fake_files(&mut world.mc)
            .files
            .get(&c[0])
            .cloned()
            .unwrap_or_default();
        let line = contents
            .split('\n')
            .position(|l| l.contains("Total"))
            .map_or(-1, |n| n as i64 + 1);
        opens(world, &c[0], line)
    });
    steps.step(
        "the user sees how many results were found in how many files",
        |world, _, _| {
            let mut files = BTreeSet::new();
            let mut matches = 0;
            for row in 0..count(world) {
                if kind_at(world, row) != "match" {
                    continue;
                }
                matches += 1;
                files.insert(role_text(world, row, "group"));
            }
            let status = prop(world, "status")?;
            expect!(
                matches > 0 && status == format!("{matches} results in {} files", files.len()),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the query is empty", |world, _, _| {
        *world.mc.part::<PendingSearch>() = PendingSearch::default();
        Ok(())
    });
    steps.step(&format!("nothing matches {Q}"), |world, c, _| {
        *world.mc.part::<PendingSearch>() = PendingSearch {
            query: c[0].clone(),
            regex: false,
        };
        Ok(())
    });
    steps.step(
        &format!("the query is the regular expression {Q}"),
        |world, c, _| {
            *world.mc.part::<PendingSearch>() = PendingSearch {
                query: c[0].clone(),
                regex: true,
            };
            Ok(())
        },
    );
    steps.step("no project is open", |world, _, _| {
        world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Usage))?;
        world.sync()
    });
    steps.step("the user searches the project contents", |world, _, _| {
        let pending = world.mc.part::<PendingSearch>();
        let (query, regex) = (pending.query.clone(), pending.regex);
        world.with::<Palette, _>(|p, engine| p.set_use_regex(engine, regex))?;
        search_in(world, "content", &query)
    });
    steps.step(
        &format!("the user switches to the project {Q}"),
        |world, c, _| {
            let row = json!({"id": c[0], "title": c[0], "workspaceRoot": format!("/work/{}", c[0]),
                             "scripts": [],
                             "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z"});
            world.mc.projects.insert(c[0].clone(), row.clone());
            world.mc.send_row_of(&c[0], &row, "project");
            look_at_thread(world, &c[0])
        },
    );
    steps.step("the content search is empty", |world, _, _| {
        settle(world)?;
        let empty = prop(world, "mode")? == "content"
            && prop(world, "query")?.is_empty()
            && count(world) == 0
            && prop(world, "status")?.is_empty();
        expect!(empty, "{}", describe(world));
        Ok(())
    });
}
