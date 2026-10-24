//! Searching threads (features/threads/search.feature). The desktop searches
//! threads in the command palette, which the thread list's Search opens: every
//! environment's threads by title, and the messages of the environments that
//! are online. desktop-qt's ThreadSearchSteps.cpp.

use hal_c2_shell::controllers::palette::Palette;

use super::thread_menu::thread;
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;

#[derive(Default)]
struct ThreadSearch {
    /// The key of the result the user chose.
    chosen: String,
}

fn open(world: &World) -> bool {
    world
        .with::<Palette, _>(|p, _| p.is_open())
        .unwrap_or(false)
}

fn query(world: &World) -> String {
    world
        .with::<Palette, _>(|p, _| p.query().to_owned())
        .unwrap_or_default()
}

fn count(world: &World) -> i32 {
    world.with::<Palette, _>(|p, _| p.count()).unwrap_or(0)
}

fn search(world: &mut World, text: &str) -> Outcome {
    world.sync()?;
    if !open(world) {
        world.with::<Palette, _>(|p, engine| p.show(engine))?;
    }
    world.with::<Palette, _>(|p, engine| p.set_query(engine, text))?;
    world.sync()?;
    world.wait_for("the palette's searches to be answered", |w| {
        !w.with::<Palette, _>(|p, _| p.searching()).unwrap_or(true)
    })
}

/// The threads the palette lists, in order.
fn found(world: &World) -> Vec<String> {
    world
        .with::<Palette, _>(|p, _| {
            (0..p.count())
                .filter(|&row| p.kind_at(row) == "thread")
                .filter_map(|row| p.shown_at(row).map(|(title, _)| title))
                .collect()
        })
        .unwrap_or_default()
}

/// The search is over: the palette is closed, and starts empty the next time.
fn cleared(world: &mut World) -> Outcome<bool> {
    if open(world) {
        return Ok(false);
    }
    world.with::<Palette, _>(|p, engine| p.show(engine))?;
    let empty = query(world).is_empty();
    world.with::<Palette, _>(|p, engine| p.dismiss(engine))?;
    Ok(empty)
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("the environment {Q} has the thread {Q}"),
        |world, c, _| {
            world.mc.join_named(&c[0]);
            world.mc.send_peer_row(
                &c[0],
                "thread-linked",
                &thread("thread-linked", &c[1], "admin", "2026-09-23T09:30:00Z"),
            );
            world.sync()
        },
    );
    steps.step(
        &format!("the user searches threads for {Q}"),
        |world, c, _| search(world, &c[0]),
    );
    steps.step(&format!("{Q} and {Q} are both found"), |world, c, _| {
        let titles = found(world);
        expect!(
            titles.contains(&c[0]) && titles.contains(&c[1]),
            "the search finds {}",
            titles.join(", ")
        );
        Ok(())
    });
    steps.step(
        "results from the reachable environments are shown",
        |world, _, _| {
            let titles = found(world);
            expect!(
                titles.iter().any(|t| t == "Add dark mode"),
                "the search finds {}",
                titles.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user can tell {Q} was not searched"),
        |world, c, _| {
            let status = world.with::<Palette, _>(|p, engine| p.status(engine))?;
            expect!(
                status == format!("Not searched (offline): {}", c[0]),
                "the palette says \"{status}\""
            );
            Ok(())
        },
    );

    // The keyboard.
    steps.step("the thread search shows three results", |world, _, _| {
        let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
        for name in ["one", "two", "three"] {
            let id = format!("thread-quokka-{name}");
            let row = thread(
                &id,
                &format!("Quokka {name}"),
                &project,
                "2026-09-23T09:30:00Z",
            );
            world.mc.threads.insert(id.clone(), row.clone());
            world.mc.send_row(&id, &row);
        }
        search(world, "quokka")?;
        let titles = found(world);
        expect!(
            count(world) == 3 && titles.len() == 3,
            "the search finds {}",
            titles.join(", ")
        );
        world.with::<Palette, _>(|p, _| p.set_highlighted(0))
    });
    steps.step("the user moves down past the last result", |world, _, _| {
        for _ in 0..count(world) {
            world.with::<Palette, _>(|p, _| p.move_by(1))?;
        }
        Ok(())
    });
    steps.step("the first result is highlighted again", |world, _, _| {
        let row = world.with::<Palette, _>(|p, _| p.highlighted())?;
        expect!(row == 0, "row {row} is highlighted");
        Ok(())
    });
    steps.step("the user chooses the highlighted result", |world, _, _| {
        let chosen = world.with::<Palette, _>(|p, _| p.id_at(p.highlighted()))?;
        world.part::<ThreadSearch>().chosen = chosen;
        let ran = world.with::<Palette, _>(|p, engine| p.run_highlighted(engine))?;
        expect!(ran, "nothing ran");
        Ok(())
    });
    steps.step(
        "that thread opens and the search is cleared",
        |world, _, _| {
            let chosen = world.part::<ThreadSearch>().chosen.clone();
            let wanted = chosen.clone();
            world.wait_for_with(
                move |w| super::thread_menu::route_thread(w) == wanted,
                |w| {
                    format!(
                        "the thread to open; the route is {}",
                        show(&w.state("route"))
                    )
                },
            )?;
            expect!(!chosen.is_empty(), "no result was chosen");
            let was_cleared = cleared(world)?;
            expect!(
                was_cleared,
                "the search is still there: \"{}\"",
                query(world)
            );
            Ok(())
        },
    );

    // Leaving.
    steps.step("the user is searching threads", |world, _, _| {
        search(world, "dark")?;
        let titles = found(world);
        expect!(
            titles == ["Add dark mode"],
            "the search finds {}",
            titles.join(", ")
        );
        Ok(())
    });
    steps.step("the user dismisses the search", |world, _, _| {
        world.with::<Palette, _>(|p, engine| p.dismiss(engine))
    });
    steps.step("the full thread list is shown again", |world, _, _| {
        // The search never narrows the list itself: both threads are still there.
        let sidebar = world.state("sidebar");
        let mut titles: Vec<String> = at(&sidebar, "active")
            .as_array()
            .map(|rows| rows.iter().map(|row| text(&row["title"])).collect())
            .unwrap_or_default();
        titles.sort();
        let was_cleared = cleared(world)?;
        expect!(
            was_cleared && titles == ["Add dark mode", "Fix OAuth loop"],
            "the list shows {}",
            titles.join(", ")
        );
        Ok(())
    });
}
