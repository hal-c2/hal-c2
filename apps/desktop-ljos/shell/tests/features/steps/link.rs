//! A link's menu and what following a link opened, shared by the terminal's
//! links (terminal/links-and-graphics.feature) and a reply's
//! (timeline/scrolling-and-links.feature): desktop-qt's LinkSteps.cpp.

use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::thread_view::workspace_files::WorkspaceFiles;
use serde_json::{Value, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The shell's menu (the menu controller) a reply's link opened; empty for
/// none.
fn shell_menu_items(world: &World) -> Vec<Value> {
    at(&world.state("menu"), "items")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

const TERMINAL_ENTRIES: [&str; 2] = ["terminalOpenLink", "terminalCopyLink"];

/// The shown brick, when one is.
fn brick(world: &mut World) -> Option<Brick> {
    world.part::<Shown>().0
}

/// The open menu's entries: the shell's, else the terminal's link entries.
fn offered(world: &mut World) -> Outcome<Vec<String>> {
    let mut labels: Vec<String> = shell_menu_items(world)
        .iter()
        .map(|item| text(&item["label"]))
        .collect();
    let Some(brick) = brick(world) else {
        return Ok(labels);
    };
    if !labels.is_empty() {
        return Ok(labels);
    }
    for name in TERMINAL_ENTRIES {
        let item = brick.item(world, name)?;
        let height = brick.read(world, item, "height").to_number();
        if brick.flag(world, item, "visible") && height > 0.0 {
            labels.push(brick.text_of(world, item, "text"));
        }
    }
    Ok(labels)
}

pub fn register(steps: &mut Steps) {
    steps.step(&format!("the menu offers {Q} and {Q}"), |world, c, _| {
        let labels = offered(world)?;
        expect!(
            labels.contains(&c[0]) && labels.contains(&c[1]),
            "the menu offers {}",
            labels.join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("the user chooses {Q} from the link's menu"),
        |world, c, _| {
            let menu = world.state("menu");
            for item in shell_menu_items(world) {
                if text(&item["label"]) == c[0] {
                    world.dispatch(
                        "menu.select",
                        json!({"requestId": at(&menu, "requestId"), "id": item["id"]}),
                    )?;
                    return world.sync();
                }
            }
            if let Some(brick) = brick(world) {
                for name in TERMINAL_ENTRIES {
                    let item = brick.item(world, name)?;
                    if brick.text_of(world, item, "text") == c[0] {
                        let menu = brick.read(world, item, "menu");
                        brick.click(world, name)?;
                        // What it chose is done once the menu has gone.
                        if let ljos::prelude::Value::Object(menu) = menu {
                            world.wait_for("the terminal's menu to close", move |w| {
                                !brick.flag(w, menu, "visible")
                            })?;
                        }
                        return world.sync();
                    }
                }
            }
            let offered = offered(world)?;
            fail!("the menu offers {}", offered.join(", "))
        },
    );
    steps.step(
        &format!("{Q} opens in the system browser"),
        |world, c, _| {
            let opened = world.opened_urls();
            expect!(
                opened == [c[0].clone()],
                "the browser opened {}",
                show(&json!(opened))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the Files tab shows {Q} at line (\\d+)"),
        |world, c, _| {
            let files = world.with::<RightPanel, _>(|p, _| p.files())?;
            let Some(files) = files else {
                fail!("the right panel has no Files tab");
            };
            let status = |w: &World| {
                WorkspaceFiles::read(w.engine(), files, |f| f.file_status()).unwrap_or("")
            };
            world.wait_for("the file to be read", move |w| status(w) != "loading")?;
            let (open, line) = WorkspaceFiles::read(world.engine(), files, |f| {
                (f.open_path().to_owned(), f.facts().reveal_line)
            })
            .unwrap_or_default();
            let tab = world.with::<RightPanel, _>(|p, _| p.active_tab())?;
            expect!(
                tab == "files" && open == c[0] && line.to_string() == c[1],
                "the {tab} tab shows \"{open}\" at line {line}"
            );
            Ok(())
        },
    );
    steps.step("nothing is opened", |world, _, _| {
        let mut opened: Vec<String> = world.opened_urls();
        for rpc in &world.mc.calls {
            if rpc.method == "shell.openInEditor" {
                opened.push("the editor".into());
            }
        }
        // A reply's links, as the timeline brick records them (MarkdownSteps).
        if let Some(brick) = brick(world)
            && let Some(root) = brick.root(world)
        {
            let links = hal_c2_shell::json::from_value(
                world.engine(),
                &brick.read(world, root, "activated"),
            );
            for link in links.as_array().into_iter().flatten() {
                opened.push(text(link));
            }
        }
        expect!(opened.is_empty(), "{} was opened", opened.join(", "));
        Ok(())
    });
}
