//! The pages a new browser tab suggests (Previews::suggestions over
//! PreviewHistory): the pages the device's tabs visited, per project, as the
//! fake MC's tab snapshots say they loaded, with the servers and configured
//! addresses beside them, as desktop-qt's BrowserHistorySteps.cpp.
//! features/preview/surfaces.feature.

use chrono::{DateTime, SecondsFormat, Utc};
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json;
use hal_c2_shell::thread_view::preview_history::{self, PROJECTS_KEPT, PreviewHistory};
use hal_c2_shell::thread_view::previews::MAX_RECENTS;
use ljos::prelude::ObjectId;
use serde_json::{Value as Json, json};

use super::super::stream::{
    FakeStreams, PEER, PEER_ENVIRONMENT, PEER_THREAD, PROJECT, THREAD, look,
};
use super::browser::{self, embed};
use super::{describe, emit_event, fake, look_at_peer_thread, read, tab_at};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

/// When the pages loaded: a second apart, the first an hour ago.
#[derive(Default)]
struct Visits {
    clock: i64,
    /// The pages of "the same page twice", in the order visited.
    visited: Vec<String>,
    /// The page visited before the scenario, as visited() kept it.
    before: Option<(String, String, i64)>,
}

fn visits(world: &mut World) -> &mut Visits {
    world.mc.part::<Visits>()
}

fn project_key(world: &World, project: &str) -> String {
    format!("{}:{project}", world.mc.environment_id)
}

fn history(world: &World) -> PreviewHistory {
    PreviewHistory::from_json(
        Settings::of(world.engine())
            .device_value("previewHistory")
            .as_ref(),
    )
}

fn first_page(world: &World, project: &str) -> Option<preview_history::Page> {
    history(world)
        .pages(&project_key(world, project))
        .into_iter()
        .next()
}

fn iso(ms: i64) -> String {
    DateTime::<Utc>::from_timestamp_millis(ms)
        .unwrap_or_default()
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn now_ms(world: &World) -> i64 {
    world.now().timestamp_millis()
}

fn tick(world: &mut World) -> i64 {
    let visits = visits(world);
    if visits.clock == 0 {
        visits.clock = Utc::now().timestamp_millis() - 3600 * 1000;
    }
    visits.clock += 1000;
    visits.clock
}

fn write_history(world: &World, kept: &PreviewHistory) -> Outcome {
    let settings = Settings::of(world.engine());
    expect!(
        settings.write_device(world.engine(), "previewHistory", kept.to_json()),
        "{}",
        settings.device_error()
    );
    Ok(())
}

/// The device visited `url` in the project `ago` ms before the world's now,
/// before the scenario.
fn visited(world: &mut World, url: &str, title: &str, ago: i64) -> Outcome {
    let at = now_ms(world) - ago;
    visits(world).before = Some((url.to_owned(), title.to_owned(), at));
    let mut kept = history(world);
    kept.visit(&project_key(world, PROJECT), url, title, at);
    write_history(world, &kept)
}

/// The MC's browser tab of `thread` loaded `url`, titled `title`, just now:
/// its snapshot changes, and its watchers hear.
fn load(world: &mut World, thread: &str, url: &str, title: &str) {
    let stamp = iso(tick(world));
    let previews = fake(&mut world.mc);
    let at = match previews.tabs.iter().position(|t| t["threadId"] == thread) {
        Some(at) => at,
        None => {
            let mut tab = tab_at(url, previews.tabs.len() + 1);
            tab["threadId"] = json!(thread);
            previews.tabs.push(tab);
            previews.tabs.len() - 1
        }
    };
    let tab = &mut previews.tabs[at];
    tab["navStatus"] = json!({"_tag": "Success", "url": url, "title": title});
    tab["updatedAt"] = json!(stamp);
    let tab = tab.clone();
    emit_event(&mut world.mc, &tab, "navigated", json!({"snapshot": tab}));
}

/// The MC is reached and the thread's pages show in tabs here, so its tabs
/// are followed while it shows.
fn follow(world: &mut World) -> Outcome {
    if fake(&mut world.mc).looking {
        return Ok(());
    }
    fake(&mut world.mc).looking = true;
    world.connect()?;
    world.sync()
}

/// Looks at `thread` of `project`, and waits for its tabs to be listed.
fn look_at(world: &mut World, thread: &str, project: &str) -> Outcome {
    follow(world)?;
    if !world.mc.projects.contains_key(project) {
        world.mc.projects.insert(
            project.into(),
            json!({"id": project, "title": project, "workspaceRoot": format!("/work/{project}"),
                   "scripts": []}),
        );
    }
    let row = world.mc.projects[project].clone();
    world.mc.send_row_of(project, &row, "project");
    let row = json!({"id": thread, "title": thread, "projectId": project,
                     "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    world.mc.threads.insert(thread.into(), row.clone());
    world.mc.send_row(thread, &row);
    world.sync()?;
    let environment = world.mc.environment_id.clone();
    let streams = world.mc.part::<FakeStreams>();
    streams.thread = thread.into();
    streams.environment = environment.clone();
    let lists = fake(&mut world.mc).lists;
    look(world, &format!("{environment}:{thread}"), false)?;
    // Each thread its own previews: embedded, as the desktop's are.
    embed(world)?;
    let key = format!("{environment}:{thread}");
    world.wait_for_with(
        move |w| {
            w.state("panel")["threadKey"] == key.as_str()
                && read(w, |p| p.status() == "ready").unwrap_or(false)
                && w.mc
                    .peek::<super::FakePreviews>()
                    .is_some_and(|f| f.lists > lists)
        },
        describe,
    )?;
    world.sync()
}

/// The thread's previews, shown beside it.
fn draw_embedded(world: &mut World) -> Outcome {
    super::show_previews(world)?;
    embed(world)?;
    browser::draw_panel(world)
}

/// Opens an empty browser tab in the thread shown, and waits for the MC to
/// have it.
fn open_new_tab(world: &mut World) -> Outcome {
    let rows = read(world, |p| p.count())?;
    world.dispatch("rightPanel.add", json!({"kind": "browser"}))?;
    world.wait_for_with(
        |w| read(w, |p| p.count() == rows + 1 && !p.empty_tab().is_empty()).unwrap_or(false),
        describe,
    )?;
    world.sync()
}

fn recent(world: &World) -> Vec<Json> {
    read(world, |p| {
        p.suggestions()
            .into_iter()
            .filter(|s| s["kind"] == "recent")
            .collect()
    })
    .unwrap_or_default()
}

fn recent_urls(world: &World) -> Vec<String> {
    recent(world).iter().map(|p| text(&p["url"])).collect()
}

fn describe_recent(world: &World) -> String {
    format!("the recent pages are {}", show(&Json::Array(recent(world))))
}

/// A drawn row of the start page: what it suggests and how it reads.
struct Row {
    name: String,
    suggestion: Json,
    title: String,
    detail: String,
    forget: Option<ObjectId>,
}

/// The start page's rows as drawn in the tab showing.
fn rows(world: &World) -> Vec<Row> {
    let Some(brick) = world.peek_part::<brick::Shown>().and_then(|s| s.0) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for index in 0.. {
        let name = format!("browserSuggestion-{index}");
        let Some(item) = brick.find_visible(world, &name).ok().flatten() else {
            break;
        };
        let under = |object_name: &str| brick.find_in(world, item, object_name).ok().flatten();
        let read_text = |item: Option<ObjectId>| {
            item.map_or(String::new(), |i| brick.text_of(world, i, "text"))
        };
        let forget = under(&format!("browserSuggestionForget-{index}"))
            .filter(|f| brick.flag(world, *f, "visible"));
        found.push(Row {
            suggestion: json::from_value(world.engine(), &brick.read(world, item, "modelData")),
            title: read_text(under("browserSuggestionTitle")),
            detail: read_text(under("browserSuggestionDetail")),
            forget,
            name,
        });
    }
    found
}

fn describe_rows(world: &World) -> String {
    let shown: Vec<String> = rows(world)
        .iter()
        .map(|r| {
            format!(
                "{} | {} ({})",
                r.title,
                r.detail,
                text(&r.suggestion["url"])
            )
        })
        .collect();
    format!(
        "the start page lists {}",
        if shown.is_empty() {
            "nothing".to_owned()
        } else {
            shown.join("; ")
        }
    )
}

fn row_for(world: &World, url: &str) -> Option<Row> {
    rows(world).into_iter().find(|r| r.suggestion["url"] == url)
}

/// The new tab's start page, drawn in the side panel.
fn start_page(world: &mut World) -> Outcome {
    browser::wait_for_tab(world, "")?;
    let brick = brick::shown(world)?;
    world.wait_for("the start page to show", |w| {
        brick
            .find_visible(w, "browserStart")
            .ok()
            .flatten()
            .is_some()
    })?;
    world.sync()
}

fn shown_brick(world: &mut World) -> Outcome<Brick> {
    brick::shown(world)
}

pub fn register(steps: &mut Steps) {
    // What a new tab offers.
    steps.step(
        "the thread's project has no running dev server and no recent pages",
        |world, _, _| {
            draw_embedded(world)?;
            let key = project_key(world, PROJECT);
            expect!(
                history(world).pages(&key).is_empty(),
                "the project has recent pages"
            );
            Ok(())
        },
    );
    steps.step(&format!("the new tab says {Q}"), |world, c, _| {
        start_page(world)?;
        let brick = shown_brick(world)?;
        expect!(
            brick.shows(world, &c[0])?,
            "the tab does not say \"{}\"; {}",
            c[0],
            describe_rows(world)
        );
        Ok(())
    });
    steps.step(
        "it says to type a URL above or run a dev script and that localhost servers will show up automatically",
        |world, _, _| {
            let brick = shown_brick(world)?;
            expect!(
                brick.shows(
                    world,
                    "Type a URL above or run a dev script. Servers on localhost show up here automatically."
                )?,
                "the start page does not say how to start"
            );
            expect!(rows(world).is_empty(), "{}", describe_rows(world));
            Ok(())
        },
    );
    steps.step(
        &format!("the user visited {Q} titled {Q} a few minutes ago"),
        |world, c, _| {
            visited(world, &c[0], &c[1], 5 * 60 * 1000 + 20 * 1000)?;
            draw_embedded(world)
        },
    );
    steps.step(
        &format!("the user visited {Q} which has no title"),
        |world, c, _| {
            visited(world, &c[0], "", 5 * 60 * 1000)?;
            draw_embedded(world)
        },
    );
    steps.step(&format!("the page is listed as {Q}"), |world, c, _| {
        start_page(world)?;
        let title = c[0].clone();
        world.wait_for_with(
            move |w| {
                let listed = rows(w);
                listed.len() == 1 && listed[0].title == title
            },
            describe_rows,
        )
    });
    steps.step(
        &format!("beneath it are {Q} and how long ago it was visited"),
        |world, c, _| {
            let detail = rows(world)
                .first()
                .map(|r| r.detail.clone())
                .unwrap_or_default();
            expect!(
                detail == format!("{} · 5m ago", c[0]),
                "{}",
                describe_rows(world)
            );
            Ok(())
        },
    );
    steps.step(
        "another browser tab of the thread showing that page is resized",
        |world, _, _| {
            let Some((url, title, at)) = visits(world).before.clone() else {
                fail!("no page was visited before");
            };
            // The tab loaded the page when it was visited...
            let previews = fake(&mut world.mc);
            let mut tab = tab_at(&url, previews.tabs.len() + 1);
            tab["navStatus"] = json!({"_tag": "Success", "url": url, "title": title});
            tab["updatedAt"] = json!(iso(at));
            previews.tabs.push(tab.clone());
            emit_event(&mut world.mc, &tab, "navigated", json!({"snapshot": tab}));
            world.sync()?;
            // ...and is resized now, which the MC stamps too (preview.ex
            // resize).
            tab["viewport"] = json!({"_tag": "device", "width": 390, "height": 844});
            tab["updatedAt"] = json!(iso(now_ms(world)));
            *fake(&mut world.mc).tabs.last_mut().expect("pushed above") = tab.clone();
            emit_event(&mut world.mc, &tab, "resized", json!({"snapshot": tab}));
            world.sync()
        },
    );
    steps.step(
        "the row still says when the page was visited, not when the tab was resized",
        |world, _, _| {
            let url = visits(world)
                .before
                .clone()
                .map(|b| b.0)
                .unwrap_or_default();
            let detail = rows(world)
                .first()
                .map(|r| r.detail.clone())
                .unwrap_or_default();
            let want = format!(
                "{} · 5m ago",
                preview_history::shown(&preview_history::tidy(&url))
            );
            expect!(detail == want, "{}", describe_rows(world));
            Ok(())
        },
    );
    steps.step(
        &format!("the device kept the recent pages {Q} and {Q} before it kept them per project"),
        |world, c, _| {
            let settings = Settings::of(world.engine());
            expect!(
                settings.write_device(world.engine(), "previewRecentPages", json!([c[0], c[1]])),
                "{}",
                settings.device_error()
            );
            draw_embedded(world)
        },
    );
    steps.step(
        &format!("the pages are listed as {Q} then {Q}, with no time to show"),
        |world, c, _| {
            start_page(world)?;
            let (first, second) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| {
                    let listed = rows(w);
                    listed.len() == 2 && listed[0].detail == first && listed[1].detail == second
                },
                describe_rows,
            )
        },
    );
    steps.step(
        "the device keeps them under the project from now on",
        |world, _, _| {
            let old = Settings::of(world.engine()).device_value("previewRecentPages");
            expect!(old.is_none(), "{}", show(&old.unwrap_or_default()));
            let key = project_key(world, PROJECT);
            expect!(
                history(world).pages(&key).len() == 2,
                "{}",
                show(&history(world).to_json())
            );
            Ok(())
        },
    );
    steps.step("the row offers to remove it from history", |world, _, _| {
        let forget = rows(world).into_iter().next().and_then(|r| r.forget);
        expect!(forget.is_some(), "{}", describe_rows(world));
        let brick = shown_brick(world)?;
        let found = brick.find_visible(world, "browserSuggestionForget-0")?;
        expect!(found == forget, "{}", describe_rows(world));
        Ok(())
    });
    steps.step(
        &format!("a new browser tab lists the recent page {Q}"),
        |world, c, _| {
            visited(world, &c[0], "", 60 * 1000)?;
            draw_embedded(world)?;
            open_new_tab(world)?;
            start_page(world)?;
            let url = c[0].clone();
            world.wait_for_with(move |w| row_for(w, &url).is_some(), describe_rows)
        },
    );
    steps.step(
        &format!("the user removes {Q} from the recent pages"),
        |world, c, _| {
            let Some(row) = row_for(world, &c[0]).filter(|r| r.forget.is_some()) else {
                fail!("{}", describe_rows(world));
            };
            let brick = shown_brick(world)?;
            let name = row
                .name
                .replace("browserSuggestion-", "browserSuggestionForget-");
            brick.click(world, &name)
        },
    );
    steps.step("the page is no longer listed", |world, _, _| {
        world.wait_for_with(
            |w| rows(w).is_empty() && recent(w).is_empty(),
            describe_rows,
        )
    });
    steps.step(
        "it does not come back when the user opens another new tab",
        |world, _, _| {
            open_new_tab(world)?;
            start_page(world)?;
            expect!(
                rows(world).is_empty() && recent(world).is_empty(),
                "{}",
                describe_rows(world)
            );
            let key = project_key(world, PROJECT);
            expect!(
                history(world).pages(&key).is_empty(),
                "the device still keeps the page"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is visited again on an MC whose clock is behind this device's"),
        |world, c, _| {
            // The MC stamps the load just after the scenario's now, weeks
            // before this device's clock.
            let now = now_ms(world);
            visits(world).clock = now;
            expect!(
                now < Utc::now().timestamp_millis(),
                "the MC's clock is not behind this device's"
            );
            load(world, THREAD, &c[0], "");
            Ok(())
        },
    );
    steps.step(
        "a thread on another MC, whose clock is ahead, has a page open",
        |world, _, _| {
            let previews = fake(&mut world.mc);
            let mut tab = tab_at("http://localhost:4000/ahead", previews.tabs.len() + 1);
            tab["threadId"] = json!(PEER_THREAD);
            tab["updatedAt"] = json!("2031-01-01T00:00:00Z");
            previews.tabs.push(tab);
            previews.revision += 1;
            world.mc.join(PEER, PEER_ENVIRONMENT);
            world.sync()?;
            look_at_peer_thread(world)?;
            world.wait_for_with(
                |w| {
                    text(&w.state("panel")["threadKey"]).ends_with(PEER_THREAD)
                        && read(w, |p| p.status() == "ready" && p.count() == 1).unwrap_or(false)
                },
                describe,
            )
        },
    );
    steps.step("the user goes back to the thread", |world, _, _| {
        look_at(world, THREAD, PROJECT)?;
        start_page(world)
    });
    steps.step(&format!("a new tab lists {Q} again"), |world, c, _| {
        let url = c[0].clone();
        world.wait_for_with(
            move |w| first_page(w, PROJECT).is_some_and(|p| p.url == url),
            |w| show(&history(w).to_json()),
        )?;
        open_new_tab(world)?;
        start_page(world)?;
        let url = c[0].clone();
        world.wait_for_with(move |w| row_for(w, &url).is_some(), describe_rows)
    });
    steps.step(
        &format!("the project configures {Q} and {Q} as preview addresses"),
        |world, c, _| {
            let scripts: Vec<Json> = [&c[0], &c[1]]
                .iter()
                .enumerate()
                .map(|(n, url)| {
                    json!({"id": format!("dev-{n}"), "name": "Dev", "command": "bun dev",
                           "icon": "play", "runOnWorktreeCreate": false, "previewUrl": url})
                })
                .collect();
            world.mc.projects.insert(
                PROJECT.into(),
                json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": format!("/work/{PROJECT}"),
                       "scripts": scripts}),
            );
            look_at(world, THREAD, PROJECT)
        },
    );
    steps.step(
        &format!("the page {Q} is suggested once, with the anchor of the first"),
        |world, c, _| {
            let first = text(&world.mc.projects[PROJECT]["scripts"][0]["previewUrl"]);
            let configured: Vec<String> = read(world, |p| {
                p.suggestions()
                    .iter()
                    .filter(|s| s["kind"] == "configured")
                    .map(|s| text(&s["url"]))
                    .collect()
            })?;
            let bare = first.split('#').next().unwrap_or_default();
            expect!(
                configured == [first.clone()] && bare == c[0],
                "{}",
                read(world, |p| show(&Json::Array(p.suggestions())))?
            );
            Ok(())
        },
    );

    // Opening a suggested server.
    steps.step(
        "a new browser tab suggests a dev server on port (\\d+)",
        |world, _, _| {
            // The test's own server stands in for the port named: nothing
            // else on this machine is loaded.
            let server = browser::dev_server(world)?;
            let (port, url) = (server.port(), server.url("/"));
            let url = url.trim_end_matches('/').to_owned();
            fake(&mut world.mc).servers = vec![json!({
                "host": "localhost", "port": port, "url": url,
                "processName": "vite", "pid": 4242, "terminal": null})];
            draw_embedded(world)?;
            open_new_tab(world)?;
            start_page(world)?;
            let wanted = url.clone();
            world.wait_for_with(move |w| row_for(w, &wanted).is_some(), describe_rows)?;
            visits(world).visited = vec![url];
            Ok(())
        },
    );
    steps.step("the user opens the suggestion", |world, _, _| {
        let url = visits(world).visited.first().cloned().unwrap_or_default();
        let Some(row) = row_for(world, &url) else {
            fail!("{}", describe_rows(world));
        };
        shown_brick(world)?.click(world, &row.name)
    });
    steps.step(
        "the page opens in a browser tab beside the thread",
        |world, _, _| {
            let url = visits(world).visited.first().cloned().unwrap_or_default();
            let wanted = url.clone();
            world.wait_for_with(
                move |w| {
                    w.mc.peek::<super::FakePreviews>().is_some_and(|f| {
                        f.navigations
                            .last()
                            .is_some_and(|n| text(&n["url"]).starts_with(&wanted))
                    })
                },
                describe,
            )?;
            let brick = shown_brick(world)?;
            browser::wait_for_engine(
                world,
                |w| browser::view_url(w, brick).starts_with(&url),
                describe,
            )?;
            let opened = world.opened_urls();
            expect!(opened.is_empty(), "the user's browser opened {opened:?}");
            Ok(())
        },
    );
    steps.step(
        "the server is remembered among the recent pages",
        |world, _, _| {
            let url = visits(world).visited.first().cloned().unwrap_or_default();
            let tidy = preview_history::tidy(&url);
            world.wait_for("the server to be remembered", move |w| {
                first_page(w, PROJECT).is_some_and(|p| p.url == tidy)
            })
        },
    );

    // Visits, filed per project.
    steps.step(
        &format!("the user (?:visits {Q} in a browser tab of a project|visited {Q} in a project's browser tab)"),
        |world, c, _| {
            let url = if c[0].is_empty() { c[1].clone() } else { c[0].clone() };
            look_at(world, THREAD, PROJECT)?;
            load(world, THREAD, &url, "");
            world.wait_for("the visit to be remembered", move |w| {
                first_page(w, PROJECT).is_some_and(|p| p.url == url)
            })
        },
    );
    steps.step(
        "the user opens a new browser tab in another thread of that project",
        |world, _, _| {
            look_at(world, "thread-2", PROJECT)?;
            open_new_tab(world)
        },
    );
    steps.step(
        "the user opens a new browser tab in a different project",
        |world, _, _| {
            look_at(world, "thread-garden", "garden")?;
            open_new_tab(world)
        },
    );
    steps.step(&format!("{Q} is among the recent pages"), |world, c, _| {
        let url = c[0].clone();
        world.wait_for_with(move |w| recent_urls(w).contains(&url), describe_recent)
    });
    steps.step(
        &format!("{Q} is not among the recent pages"),
        |world, c, _| {
            world.sync()?;
            expect!(
                !recent_urls(world).contains(&c[0]),
                "{}",
                describe_recent(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user visits {Q} titled {Q} in a browser tab of a thread of the project"),
        |world, c, _| {
            look_at(world, THREAD, PROJECT)?;
            load(world, THREAD, &c[0], &c[1]);
            let title = c[1].clone();
            world.wait_for("the visit to be remembered", move |w| {
                first_page(w, PROJECT).is_some_and(|p| p.title == title)
            })
        },
    );
    steps.step(
        "the user restarts HAL-C2 and opens a new browser tab in that project",
        |world, _, _| {
            // The MC keeps no tab of it: what is suggested is what the
            // device kept.
            fake(&mut world.mc).tabs.clear();
            world.restart()?;
            world.connect()?;
            world.sync()?;
            look_at(world, THREAD, PROJECT)?;
            open_new_tab(world)
        },
    );
    steps.step(
        &format!("{Q} at {Q} is among the recent pages"),
        |world, c, _| {
            let (title, url) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| {
                    recent(w)
                        .iter()
                        .any(|p| p["url"] == url.as_str() && p["title"] == title.as_str())
                },
                describe_recent,
            )
        },
    );
    steps.step(
        &format!("an agent loads {Q} titled {Q} in a thread's browser tab"),
        |world, c, _| {
            // The tab was open before; the side panel is not.
            let previews = fake(&mut world.mc);
            let mut tab = tab_at("", 1);
            tab["navStatus"] = json!({"_tag": "Idle"});
            previews.tabs.push(tab);
            look_at(world, THREAD, PROJECT)?;
            load(world, THREAD, &c[0], &c[1]);
            Ok(())
        },
    );
    steps.step("the browser is not shown for that thread", |world, _, _| {
        let shown = world
            .with::<RightPanel, _>(|p, _| p.is_open() && p.active_tab().starts_with("browser:"))?;
        expect!(!shown, "{}", show(&world.state("panel")));
        Ok(())
    });
    steps.step(
        "the user opens a new browser tab in that project",
        |world, _, _| open_new_tab(world),
    );
    steps.step(
        &format!("{Q} is the title of {Q} among the recent pages"),
        |world, c, _| {
            let (title, url) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| {
                    recent(w)
                        .iter()
                        .find(|p| p["url"] == url.as_str())
                        .is_some_and(|p| p["title"] == title.as_str())
                },
                describe_recent,
            )
        },
    );
    steps.step(
        &format!("thread {Q} loaded {Q} titled {Q}"),
        |world, c, _| {
            let thread = format!("thread-{}", c[0]);
            follow(world)?;
            load(world, &thread, &c[1], &c[2]);
            look_at(world, &thread, PROJECT)?;
            let title = c[2].clone();
            world.wait_for("the visit to be remembered", move |w| {
                first_page(w, PROJECT).is_some_and(|p| p.title == title)
            })
        },
    );
    steps.step(
        &format!("thread {Q} of the same project later loaded it titled {Q}"),
        |world, c, _| {
            let thread = format!("thread-{}", c[0]);
            let url = first_page(world, PROJECT)
                .map(|p| p.url)
                .unwrap_or_default();
            load(world, &thread, &url, &c[1]);
            look_at(world, &thread, PROJECT)?;
            let title = c[1].clone();
            world.wait_for("the later visit to be remembered", move |w| {
                first_page(w, PROJECT).is_some_and(|p| p.title == title)
            })
        },
    );
    steps.step(
        &format!("the user switches back to thread {Q}"),
        |world, c, _| {
            // Its tab is listed again, with the title it last had.
            look_at(world, &format!("thread-{}", c[0]), PROJECT)
        },
    );
    steps.step(
        &format!("{Q} is titled {Q} among the recent pages"),
        |world, c, _| {
            let pages = history(world).pages(&project_key(world, PROJECT));
            expect!(
                pages.len() == 1 && pages[0].url == c[0] && pages[0].title == c[1],
                "the device keeps {pages:?}"
            );
            let first = recent(world).first().map(|p| text(&p["title"]));
            expect!(
                first.as_deref() == Some(c[1].as_str()),
                "{}",
                describe_recent(world)
            );
            Ok(())
        },
    );

    // Kept tidy, and bounded.
    steps.step(&format!("the user visits {Q} then {Q}"), |world, c, _| {
        look_at(world, THREAD, PROJECT)?;
        load(world, THREAD, &c[0], "");
        load(world, THREAD, &c[1], "");
        let clock = visits(world).clock;
        world.wait_for("the visits to be remembered", move |w| {
            first_page(w, PROJECT).is_some_and(|p| p.at == clock)
        })
    });
    steps.step(&format!("the user visits {Q}"), |world, c, _| {
        look_at(world, THREAD, PROJECT)?;
        load(world, THREAD, &c[0], "");
        let clock = visits(world).clock;
        world.wait_for("the visit to be remembered", move |w| {
            first_page(w, PROJECT).is_some_and(|p| p.at == clock)
        })
    });
    steps.step("the user visits the same page twice", |world, _, _| {
        look_at(world, THREAD, PROJECT)?;
        let pages: Vec<String> = ["a", "b", "a"]
            .iter()
            .map(|p| format!("http://localhost:5173/{p}"))
            .collect();
        visits(world).visited = pages.clone();
        for url in &pages {
            load(world, THREAD, url, "");
        }
        let clock = visits(world).clock;
        world.wait_for("the visits to be remembered", move |w| {
            first_page(w, PROJECT).is_some_and(|p| p.at == clock)
        })
    });
    steps.step(
        "the recent pages list one page for that local server",
        |world, _, _| {
            world.sync()?;
            expect!(
                recent_urls(world) == ["http://localhost:5173"],
                "{}",
                describe_recent(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the recent pages list {Q} without credentials"),
        |world, c, _| {
            world.sync()?;
            expect!(
                recent_urls(world) == [c[0].clone()],
                "{}",
                describe_recent(world)
            );
            let kept = Settings::of(world.engine()).device_value("previewHistory");
            expect!(
                !show(&kept.unwrap_or_default()).contains("secret"),
                "the device keeps the password"
            );
            Ok(())
        },
    );
    steps.step(
        "the recent pages list the page once, as the most recent",
        |world, _, _| {
            world.sync()?;
            expect!(
                recent_urls(world) == ["http://localhost:5173/a", "http://localhost:5173/b"],
                "{}",
                describe_recent(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user has visited fifty one different pages in a project",
        |world, _, _| {
            look_at(world, THREAD, PROJECT)?;
            for n in 1..=51 {
                load(
                    world,
                    THREAD,
                    &format!("http://localhost:5173/page-{n}"),
                    "",
                );
            }
            world.wait_for("the visits to be remembered", |w| {
                first_page(w, PROJECT).is_some_and(|p| p.url == "http://localhost:5173/page-51")
            })
        },
    );
    steps.step(
        "the recent pages remember the fifty most recent ones",
        |world, _, _| {
            let pages = history(world).pages(&project_key(world, PROJECT));
            expect!(
                pages.len() == 50
                    && pages[0].url == "http://localhost:5173/page-51"
                    && pages[49].url == "http://localhost:5173/page-2",
                "the device keeps {} pages, {:?} to {:?}",
                pages.len(),
                pages.first().map(|p| &p.url),
                pages.last().map(|p| &p.url)
            );
            // A new tab shows the newest ten of them.
            expect!(
                recent(world).len() == MAX_RECENTS,
                "{}",
                describe_recent(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user has browsed in twenty one projects",
        |world, _, _| {
            follow(world)?;
            for n in 1..=21 {
                let thread = format!("thread-p{n}");
                let project = format!("project-{n}");
                load(world, &thread, &format!("http://localhost:5173/p{n}"), "");
                look_at(world, &thread, &project)?;
                let key = project_key(world, &project);
                world.wait_for("the visit to be remembered", move |w| {
                    history(w).projects().first() == Some(&key)
                })?;
            }
            Ok(())
        },
    );
    steps.step(
        "the history of the project used longest ago is forgotten",
        |world, _, _| {
            let projects = history(world).projects();
            expect!(
                projects.len() == PROJECTS_KEPT
                    && !projects.contains(&project_key(world, "project-1"))
                    && projects.contains(&project_key(world, "project-2")),
                "{projects:?}"
            );
            Ok(())
        },
    );
}
