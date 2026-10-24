//! The window's layout the shell keeps itself (Layout): hiding and showing
//! the thread list from its button, the header and mod+b, remembered on this
//! device (navigation/layout.feature's sidebar, threads/sidebar-list.feature,
//! navigation/appearance.feature's motion). That DefaultShell hides the list,
//! gives the thread the width in one step and swaps in the settings sections
//! is in tst_ShellExamples. desktop-qt's LayoutSteps.cpp.

use std::cell::Cell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::layout::{
    CONTENT_MIN_WIDTH, Layout, SIDEBAR_MIN_WIDTH, SIDEBAR_WIDTH,
};
use hal_c2_shell::controllers::settings::Settings;
use serde_json::{Value, json};

use crate::expect;
use crate::harness::{Outcome, Steps, at, show};
use crate::world::World;

/// How often the shell told the window its layout changed since the scenario
/// last acted on it.
#[derive(Default)]
struct LayoutChanges {
    count: Rc<Cell<i32>>,
    watching: bool,
}

fn layout_of(world: &World) -> Outcome<(bool, i32)> {
    world.with::<Layout, _>(|l, _| (l.sidebar_collapsed(), l.sidebar_width()))
}

fn collapsed(world: &World) -> bool {
    at(&world.state("layout"), "sidebarCollapsed")
        .as_bool()
        .unwrap_or(false)
}

fn width(world: &World) -> i64 {
    at(&world.state("layout"), "sidebarWidth")
        .as_i64()
        .unwrap_or(0)
}

fn overlay(world: &World) -> bool {
    at(&world.state("layout"), "sidebarOverlay")
        .as_bool()
        .unwrap_or(false)
}

fn watch(world: &mut World) {
    let engine = world.engine().clone();
    let changes = world.part::<LayoutChanges>();
    changes.count.set(0);
    if changes.watching {
        return;
    }
    changes.watching = true;
    let count = changes.count.clone();
    Bridge::of(&engine).watch(&engine, "layout", move |_, _| count.set(count.get() + 1));
}

/// The sidebar's own button and the header's show button both dispatch it.
fn toggle(world: &mut World) -> Outcome {
    watch(world);
    world.dispatch("sidebar.toggle", Value::Null)
}

fn published(world: &mut World) -> Outcome {
    // A starting shell reads the device's layout once the event loop runs.
    world.wait_for("the shell publishes its layout", |w| {
        !w.state("layout").is_null()
    })
}

fn expect_collapsed(world: &mut World, want: bool) -> Outcome {
    published(world)?;
    expect!(
        collapsed(world) == want,
        "the window's layout is {}",
        show(&world.state("layout"))
    );
    let (held, _) = layout_of(world)?;
    expect!(
        held == want,
        "the layout controller disagrees with what it published"
    );
    Ok(())
}

fn drag(world: &mut World, to: i64) -> Outcome {
    published(world)?;
    world.dispatch("layout.window", json!({"width": 1280}))?;
    world.dispatch("sidebar.resize", json!({"width": to}))
}

pub fn register(steps: &mut Steps) {
    steps.step("the sidebar is (shown|hidden)", |world, c, _| {
        let hidden = c[0] == "hidden";
        if world.checking {
            return expect_collapsed(world, hidden);
        }
        published(world)?;
        if collapsed(world) != hidden {
            world.dispatch("sidebar.toggle", Value::Null)?;
        }
        expect_collapsed(world, hidden)
    });
    steps.step(
        "the user (?:toggles the sidebar|asks to show the sidebar|hides the thread list|shows the thread list)",
        |world, _, _| toggle(world),
    );
    steps.step("the user presses the sidebar shortcut", |world, _, _| {
        watch(world);
        let engine = world.engine().clone();
        let ran = Commands::of(&engine).run(&engine, "sidebar.toggle");
        expect!(ran, "sidebar.toggle is not a keybinding command");
        world.pump()
    });
    steps.step("the main view takes the full width", |world, _, _| {
        expect_collapsed(world, true)
    });
    steps.step("the thread list is back", |world, _, _| {
        expect_collapsed(world, false)
    });
    // One change of the layout per toggle: the window lays out once, with no
    // animated width in between.
    steps.step(
        "the (?:thread view is resized once, not on every frame|sidebar appears without animation)",
        |world, _, _| {
            let count = world.part::<LayoutChanges>().count.get();
            expect!(count == 1, "the layout changed {count} times");
            Ok(())
        },
    );
    // The thread list's width: dragging its edge sends `sidebar.resize`, a
    // double click resets it, and the window says how wide it is.
    steps.step(
        "the user (?:drags the sidebar to a new width|resized the sidebar)",
        |world, _, _| {
            drag(world, 340)?;
            expect!(width(world) == 340, "{}", show(&world.state("layout")));
            Ok(())
        },
    );
    steps.step("the sidebar has the width the user chose", |world, _, _| {
        published(world)?;
        let (_, held) = layout_of(world)?;
        expect!(
            width(world) == 340 && held == 340,
            "{}",
            show(&world.state("layout"))
        );
        Ok(())
    });
    steps.step(
        "the user drags the sidebar narrower than its minimum",
        |world, _, _| drag(world, 90),
    );
    steps.step("the sidebar stops at its minimum width", |world, _, _| {
        expect!(
            width(world) == i64::from(SIDEBAR_MIN_WIDTH),
            "{}",
            show(&world.state("layout"))
        );
        Ok(())
    });
    steps.step(
        "the window becomes narrower than the sidebar allows",
        |world, _, _| {
            world.dispatch("sidebar.resize", json!({"width": 340}))?;
            world.dispatch("layout.window", json!({"width": 780}))
        },
    );
    steps.step("the sidebar shrinks to fit", |world, _, _| {
        // The thread keeps its room; the list gets what is left.
        expect!(
            width(world) == i64::from(780 - CONTENT_MIN_WIDTH),
            "{}",
            show(&world.state("layout"))
        );
        // And is its own width again in a window with room.
        world.dispatch("layout.window", json!({"width": 1280}))?;
        expect!(width(world) == 340, "{}", show(&world.state("layout")));
        Ok(())
    });
    // A window with no room for the list at its minimum beside the thread:
    // the layout then draws the list over the thread (tst_ShellWindow).
    steps.step(
        "the window becomes too narrow for the sidebar beside the thread",
        |world, _, _| world.dispatch("layout.window", json!({"width": 640})),
    );
    steps.step(
        "the sidebar opens over the thread at its minimum width",
        |world, _, _| {
            expect!(
                overlay(world) && !collapsed(world) && width(world) == i64::from(SIDEBAR_MIN_WIDTH),
                "{}",
                show(&world.state("layout"))
            );
            Ok(())
        },
    );
    steps.step("the window becomes wide again", |world, _, _| {
        world.dispatch("layout.window", json!({"width": 1280}))
    });
    steps.step("the sidebar is back beside the thread", |world, _, _| {
        expect!(!overlay(world), "{}", show(&world.state("layout")));
        expect_collapsed(world, false)
    });
    steps.step("the user resets the sidebar width", |world, _, _| {
        world.dispatch("sidebar.resize", Value::Null)
    });
    steps.step("the sidebar returns to its default width", |world, _, _| {
        expect!(
            width(world) == i64::from(SIDEBAR_WIDTH),
            "{}",
            show(&world.state("layout"))
        );
        // Nothing is left on the device to restore.
        let engine = world.engine().clone();
        expect!(
            !Settings::of(&engine).device().contains_key("sidebarWidth"),
            "the device still holds a width"
        );
        Ok(())
    });
    // The window is in settings; DefaultShell draws SettingsNav where the
    // thread list was (tst_ShellExamples).
    steps.step(
        "the (?:thread list is hidden|settings sections are shown in its place)",
        |world, _, _| {
            let route = world.state("route");
            expect!(
                at(&route, "kind") == "settings",
                "the route is {}",
                show(&route)
            );
            Ok(())
        },
    );
}
