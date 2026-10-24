//! The right panel's Previews tab (desktop-qt's PreviewSteps.cpp,
//! ThreadPreviews): a thread's browser tabs as the MC keeps them
//! (`preview.list`, `preview.close`, and PreviewEvents on the `preview`
//! shape), listed and opened in the user's browser.
//! features/preview/surfaces.feature, and remote.feature's forwarded dev
//! servers (`preview.forward`).

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::panel::{PanelObject, RightPanel};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::thread_view::previews::{Previews, ThreadPreviews};
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use super::stream::{
    FakeStreams, PEER, PEER_ENVIRONMENT, PEER_THREAD, PROJECT, THREAD, add_item, look,
    look_at_thread, settle_run, start_run,
};
use crate::brick::{self, Brick};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::{OTHER_MACHINE, World};
use crate::{expect, fail};

/// The MC's browser tabs, oldest change first, and how it answers a close.
struct FakePreviews {
    epoch: String,
    revision: i64,
    tabs: Vec<Json>,
    refuse_close: bool,
    hold_close: bool,
    hold_list: bool,
    lists: usize,
    /// The web servers listening on the MC's machine (DiscoveredLocalServer).
    servers: Vec<Json>,
    /// Every preview.open and preview.navigate payload.
    opens: Vec<Json>,
    navigations: Vec<Json>,
    looking: bool,
    /// The port the connected MC forwards a dev server to, and every
    /// preview.forward with the environment it was sent to.
    forward_port: i64,
    forwards: Vec<Rpc>,
    /// The address in the agent's reply.
    link: String,
}

impl Default for FakePreviews {
    fn default() -> FakePreviews {
        FakePreviews {
            epoch: "epoch-1".into(),
            revision: 0,
            tabs: Vec::new(),
            refuse_close: false,
            hold_close: false,
            hold_list: false,
            lists: 0,
            servers: Vec::new(),
            opens: Vec::new(),
            navigations: Vec::new(),
            looking: false,
            forward_port: 0,
            forwards: Vec::new(),
            link: String::new(),
        }
    }
}

fn fake(mc: &mut FakeMc) -> &mut FakePreviews {
    mc.part::<FakePreviews>()
}

fn tab_at(url: &str, n: usize) -> Json {
    json!({"threadId": THREAD, "tabId": format!("tab-{n}"),
           "navStatus": {"_tag": "Success", "url": url, "title": ""},
           "canGoBack": false, "canGoForward": false, "viewport": {"_tag": "fill"},
           "updatedAt": "2026-09-23T09:00:00Z"})
}

/// A PreviewEvent to every watcher, as preview.ex emit/4.
fn emit_event(mc: &mut FakeMc, tab: &Json, kind: &str, fields: Json) {
    let mut event = fields;
    let epoch = fake(mc).epoch.clone();
    fake(mc).revision += 1;
    let revision = fake(mc).revision;
    event["type"] = json!(kind);
    event["threadId"] = tab["threadId"].clone();
    event["tabId"] = tab["tabId"].clone();
    event["serverEpoch"] = json!(epoch);
    event["revision"] = json!(revision);
    for id in mc.subscribers("preview") {
        mc.send(&json!({"t": "preview", "id": id, "event": event}));
    }
}

fn index_of(tabs: &[Json], tab_id: &str) -> Option<usize> {
    tabs.iter().position(|tab| tab["tabId"] == tab_id)
}

fn extension(mc: &mut FakeMc) {
    // The MC sends nothing on subscribing; events follow as they happen.
    mc.on_shape("preview", |_, _, _| Ok(()));
    mc.on_rpc("preview.list", |mc, rpc| {
        let held = fake(mc).hold_list;
        fake(mc).lists += 1;
        let sessions: Vec<Json> = fake(mc)
            .tabs
            .iter()
            .filter(|tab| tab["threadId"] == rpc.payload["threadId"])
            .cloned()
            .collect();
        // The list as it is now; a held answer arrives after whatever
        // changes next.
        let list = json!({"sessions": sessions, "serverEpoch": fake(mc).epoch,
                          "revision": fake(mc).revision});
        if held {
            let rpc = rpc.clone();
            mc.defer(move |mc| mc.reply(&rpc, list));
            return Ok(());
        }
        mc.reply(rpc, list);
        Ok(())
    });
    // The MC's machine's web servers, to whoever watches (local_servers.ex).
    mc.on_shape("localServers", |mc, id, _| {
        let servers = fake(mc).servers.clone();
        mc.send(&json!({"t": "localServers", "id": id,
                        "list": {"servers": servers, "scannedAt": "2026-09-23T10:00:00Z"}}));
        Ok(())
    });
    // preview.ex open/2 and navigate/2: the tab's snapshot, and its event.
    mc.on_rpc("preview.open", |mc, rpc| {
        fake(mc).opens.push(rpc.payload.clone());
        let n = fake(mc).tabs.len() + 1;
        let url = text(&rpc.payload["url"]);
        let mut tab = tab_at(&url, n);
        tab["threadId"] = rpc.payload["threadId"].clone();
        tab["navStatus"] = if rpc.payload.get("url").is_some() {
            json!({"_tag": "Loading", "url": rpc.payload["url"], "title": ""})
        } else {
            json!({"_tag": "Idle"})
        };
        fake(mc).tabs.push(tab.clone());
        emit_event(mc, &tab, "opened", json!({"snapshot": tab}));
        mc.reply(rpc, tab);
        Ok(())
    });
    mc.on_rpc("preview.navigate", |mc, rpc| {
        fake(mc).navigations.push(rpc.payload.clone());
        let Some(at) = index_of(&fake(mc).tabs, &text(&rpc.payload["tabId"])) else {
            mc.refuse(rpc, "Unknown preview session");
            return Ok(());
        };
        fake(mc).tabs[at]["navStatus"] =
            json!({"_tag": "Success", "url": rpc.payload["url"], "title": ""});
        let tab = fake(mc).tabs[at].clone();
        emit_event(mc, &tab, "navigated", json!({"snapshot": tab}));
        mc.reply(rpc, tab);
        Ok(())
    });
    // preview_forward.ex request/1, on the MC the client is connected to.
    mc.on_rpc("preview.forward", |mc, rpc| {
        fake(mc).forwards.push(rpc.clone());
        // grant.ex: only a port one of the thread's tabs names.
        let port = rpc.payload["port"].as_i64().unwrap_or(0);
        let names = fake(mc).tabs.iter().any(|tab| {
            let url = text(&tab["navStatus"]["url"]);
            tab["threadId"] == rpc.payload["threadId"] && port_of(&url) == port
        });
        if !names {
            mc.refuse(
                rpc,
                "none of the thread's browser tabs is open at that port",
            );
            return Ok(());
        }
        let forwarded = fake(mc).forward_port;
        mc.reply(rpc, json!({"port": forwarded}));
        Ok(())
    });
    mc.on_rpc("preview.close", |mc, rpc| {
        let answer = {
            let rpc = rpc.clone();
            move |mc: &mut FakeMc| {
                if fake(mc).refuse_close {
                    mc.refuse(&rpc, "Preview is busy");
                    return;
                }
                if let Some(at) = index_of(&fake(mc).tabs, &text(&rpc.payload["tabId"])) {
                    let tab = fake(mc).tabs.remove(at);
                    emit_event(mc, &tab, "closed", json!({}));
                }
                mc.reply(&rpc, Json::Null);
            }
        };
        if fake(mc).hold_close {
            mc.defer(answer);
        } else {
            answer(mc);
        }
        Ok(())
    });
}

/// The port of `http://host:port/...`, 80 when it names none.
fn port_of(url: &str) -> i64 {
    let rest = url.split("://").nth(1).unwrap_or(url);
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    host.rsplit_once(':')
        .and_then(|(_, port)| port.parse().ok())
        .unwrap_or(80)
}

// --- The model --------------------------------------------------------------------------

fn model_object(world: &World) -> Outcome<ObjectId> {
    let engine = world.engine();
    let Ok(panel) = engine.singleton::<PanelObject>() else {
        fail!("the shell has no right panel");
    };
    match engine.read_by_name(panel, "previews") {
        Value::Object(object) => Ok(object),
        other => fail!("the panel has no previews: {other:?}"),
    }
}

fn read<R>(world: &World, f: impl FnOnce(&Previews) -> R) -> Outcome<R> {
    let object = model_object(world)?;
    match ThreadPreviews::read(world.engine(), object, f) {
        Some(found) => Ok(found),
        None => fail!("the previews are gone"),
    }
}

fn update<R>(world: &World, f: impl FnOnce(&mut Previews) -> R) -> Outcome<R> {
    let object = model_object(world)?;
    match ThreadPreviews::update(world.engine(), object, f) {
        Some(found) => Ok(found),
        None => fail!("the previews are gone"),
    }
}

fn role(previews: &Previews, row: usize, name: &str) -> String {
    use hal_c2_shell::thread_view::rows::RowSource;
    match previews.data(row, name) {
        Value::String(s) => s.to_string(),
        _ => String::new(),
    }
}

fn describe(world: &World) -> String {
    read(world, |p| {
        let rows: Vec<String> = (0..p.count())
            .map(|row| {
                format!(
                    "{} {} ({})",
                    role(p, row, "tabId"),
                    role(p, row, "url"),
                    role(p, row, "status")
                )
            })
            .collect();
        format!(
            "Previews is {} ({}) and lists {}",
            p.status(),
            p.message(),
            if rows.is_empty() {
                "nothing".to_owned()
            } else {
                rows.join("; ")
            }
        )
    })
    .unwrap_or_else(|f| f.0)
}

fn urls(world: &World) -> Vec<String> {
    read(world, |p| {
        (0..p.count()).map(|row| role(p, row, "url")).collect()
    })
    .unwrap_or_default()
}

fn tab_id_of(world: &World, url: &str) -> Outcome<String> {
    let found = read(world, |p| {
        (0..p.count())
            .find(|row| role(p, *row, "url") == url)
            .map(|row| role(p, row, "tabId"))
    })?;
    match found {
        Some(tab) => Ok(tab),
        None => fail!("{}", describe(world)),
    }
}

fn wait_for_urls(world: &mut World, wanted: &[&str]) -> Outcome {
    let wanted: Vec<String> = wanted.iter().map(|u| (*u).to_owned()).collect();
    world.wait_for_with(
        {
            let wanted = wanted.clone();
            move |w| read(w, |p| p.status()).is_ok_and(|s| s == "ready") && urls(w) == wanted
        },
        describe,
    )
}

/// The MC has the thread's tabs at `addresses` before the user looks.
fn have_tabs(world: &mut World, addresses: &[&str]) {
    let fake = fake(&mut world.mc);
    for url in addresses {
        let n = fake.tabs.len() + 1;
        fake.tabs.push(tab_at(url, n));
        fake.revision += 1;
    }
}

fn project_row(root: &str, scripts: Json) -> Json {
    json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": root, "scripts": scripts})
}

fn panel_shows_previews(world: &World) -> bool {
    world
        .with::<RightPanel, _>(|p, _| p.is_open() && p.active_tab() == "previews")
        .unwrap_or(false)
}

/// Looks at the thread with its Previews tab showing, as mod+shift+j does.
fn show_previews(world: &mut World) -> Outcome {
    if !fake(&mut world.mc).looking {
        fake(&mut world.mc).looking = true;
        world.mc.projects.insert(
            PROJECT.into(),
            project_row(&format!("/work/{PROJECT}"), json!([])),
        );
        world.connect()?;
        world.sync()?;
        look_at_thread(world, PROJECT)?;
    }
    if !panel_shows_previews(world) {
        world.with::<RightPanel, _>(|p, engine| p.toggle_previews(engine))?;
    }
    world.sync()?;
    world.wait_for_with(
        |w| {
            read(w, |p| p.status()).is_ok_and(|s| s == "ready")
                && !w.mc.subscribers("preview").is_empty()
        },
        describe,
    )?;
    let panel = world.state("panel");
    expect!(
        *at(&panel, "activeId") == json!("previews"),
        "{}",
        show(&panel)
    );
    Ok(())
}

/// The thread on the second MC, opened.
fn look_at_peer_thread(world: &mut World) -> Outcome {
    world.mc.send_peer_row(
        PEER_ENVIRONMENT,
        PEER_THREAD,
        &json!({"id": PEER_THREAD, "title": "Remote", "projectId": PROJECT,
                "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
    );
    world.sync()?;
    let streams = world.mc.part::<FakeStreams>();
    streams.thread = PEER_THREAD.into();
    streams.environment = PEER_ENVIRONMENT.into();
    look(world, &format!("{PEER_ENVIRONMENT}:{PEER_THREAD}"), true)
}

/// The browser opened `url` through one forward of the second MC's dev
/// server, asked of the MC the desktop is connected to.
fn opened_through_forward(world: &mut World, url: &str) -> Outcome {
    world.wait_for_with(
        |w| !w.opened_urls().is_empty(),
        |w| {
            format!(
                "the browser to open; {} forwards",
                w.mc.peek::<FakePreviews>().map_or(0, |f| f.forwards.len())
            )
        },
    )?;
    expect!(
        world.opened_urls() == [url.to_owned()],
        "the browser opened {:?}",
        world.opened_urls()
    );
    let environment = world.mc.environment_id.clone();
    let forwards = fake(&mut world.mc).forwards.clone();
    expect!(forwards.len() == 1, "{} forwards were asked for", forwards.len());
    let forward = &forwards[0];
    expect!(
        forward.environment == environment
            && forward.payload
                == json!({"environmentId": PEER_ENVIRONMENT, "threadId": PEER_THREAD, "port": 3000}),
        "the forward asked of {} was {}",
        forward.environment,
        show(&forward.payload)
    );
    Ok(())
}

fn suggested(world: &World, kind: &str) -> Vec<String> {
    read(world, |p| {
        p.suggestions()
            .iter()
            .filter(|s| s["kind"] == kind)
            .map(|s| text(&s["url"]))
            .collect()
    })
    .unwrap_or_default()
}

fn suggestions(world: &World) -> String {
    read(world, |p| show(&Json::Array(p.suggestions()))).unwrap_or_default()
}

fn server(url: &str, process: &str) -> Json {
    json!({"host": "localhost", "port": port_of(url), "url": url,
           "processName": process, "pid": 4242, "terminal": null})
}

/// The panel's toasts, newest last.
fn toast_items(world: &World) -> Vec<Json> {
    at(&world.state("toasts"), "items")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        &format!("the thread has browser tabs at {Q} and {Q}"),
        |world, c, _| {
            have_tabs(world, &[&c[0], &c[1]]);
            Ok(())
        },
    );
    steps.step("the user shows the thread's previews", |world, _, _| {
        show_previews(world)
    });
    steps.step("the user is showing the thread's previews", |world, _, _| {
        show_previews(world)
    });
    steps.step(&format!("{Q} and {Q} are listed"), |world, c, _| {
        wait_for_urls(world, &[&c[0], &c[1]])
    });
    steps.step(&format!("{Q} is listed"), |world, c, _| {
        // The model picker's own "is listed" is the composer picker's owner's:
        // it answers before this does when the picker is open.
        let title = c[0].clone();
        let open = world
            .with::<Palette, _>(|p, _| p.is_open())
            .unwrap_or(false);
        if open {
            world.sync()?;
            let listed = world.with::<Palette, _>(|p, _| {
                (0..p.count()).any(|row| p.shown_at(row).is_some_and(|(t, _)| t == title))
            })?;
            expect!(listed, "the command palette does not list \"{title}\"");
            return Ok(());
        }
        wait_for_urls(world, &[&c[0]])
    });
    steps.step("no browser tabs are listed", |world, _, _| {
        wait_for_urls(world, &[])
    });
    steps.step(
        &format!("the user opens {Q} from the previews"),
        |world, c, _| {
            let tab = tab_id_of(world, &c[0])?;
            update(world, |p| p.open(&tab))?;
            world.sync()
        },
    );

    // What the MC tells every client.
    steps.step(
        &format!("the agent opens a browser tab at {Q}"),
        |world, c, _| {
            let n = fake(&mut world.mc).tabs.len() + 1;
            let tab = tab_at(&c[0], n);
            fake(&mut world.mc).tabs.push(tab.clone());
            emit_event(&mut world.mc, &tab, "opened", json!({"snapshot": tab}));
            world.sync()
        },
    );
    steps.step(
        &format!("the page at {Q} fails to load"),
        |world, c, _| {
            let id = tab_id_of(world, &c[0])?;
            let tab = fake(&mut world.mc)
                .tabs
                .iter()
                .find(|t| t["tabId"] == id)
                .cloned()
                .unwrap_or(Json::Null);
            emit_event(
                &mut world.mc,
                &tab,
                "failed",
                json!({"url": c[0], "title": "", "code": "ERR_CONNECTION_REFUSED",
                       "description": "Connection refused"}),
            );
            world.sync()
        },
    );
    steps.step(
        &format!("the previews say {Q} failed to load"),
        |world, c, _| {
            let id = tab_id_of(world, &c[0])?;
            world.wait_for_with(
                move |w| {
                    read(w, |p| {
                        p.count() > 0
                            && role(p, 0, "tabId") == id
                            && role(p, 0, "status") == "failed"
                            && role(p, 0, "problem") == "Connection refused"
                    })
                    .unwrap_or(false)
                },
                describe,
            )
        },
    );
    steps.step(
        &format!("the tab at {Q} is closed on the MC"),
        |world, c, _| {
            let id = tab_id_of(world, &c[0])?;
            if let Some(at) = index_of(&fake(&mut world.mc).tabs, &id) {
                let tab = fake(&mut world.mc).tabs.remove(at);
                emit_event(&mut world.mc, &tab, "closed", json!({}));
            }
            world.sync()
        },
    );

    // Across an MC restart and out-of-order answers (preview/remote.feature).
    steps.step("the client shows a thread's browser tabs", |world, _, _| {
        have_tabs(world, &["http://localhost:5173", "http://localhost:6006"]);
        show_previews(world)?;
        wait_for_urls(world, &["http://localhost:5173", "http://localhost:6006"])
    });
    steps.step(
        "the MC restarts and a tab change arrives with a new run number",
        |world, _, _| {
            let f = fake(&mut world.mc);
            // A new run keeps none of the old tabs and counts its changes
            // from the start.
            f.epoch = "epoch-2".into();
            f.revision = 0;
            f.tabs.clear();
            f.lists = 0;
            let tab = tab_at("http://localhost:3000", 9);
            f.tabs.push(tab.clone());
            emit_event(&mut world.mc, &tab, "opened", json!({"snapshot": tab}));
            world.sync()
        },
    );
    steps.step("the client lists the thread's tabs again", |world, _, _| {
        world.wait_for_with(
            |w| w.mc.peek::<FakePreviews>().is_some_and(|f| f.lists == 1),
            |w| {
                format!(
                    "one new preview.list; the MC got {}",
                    w.mc.peek::<FakePreviews>().map_or(0, |f| f.lists)
                )
            },
        )
    });
    steps.step(
        "it shows only the tabs the restarted MC has",
        |world, _, _| {
            wait_for_urls(world, &["http://localhost:3000"])?;
            // And follows the new run's changes from there.
            let tab = tab_at("http://localhost:3001", 10);
            fake(&mut world.mc).tabs.push(tab.clone());
            emit_event(&mut world.mc, &tab, "opened", json!({"snapshot": tab}));
            wait_for_urls(world, &["http://localhost:3000", "http://localhost:3001"])
        },
    );
    steps.step(
        "the client has seen a tab change with a newer change number",
        |world, _, _| {
            have_tabs(world, &["http://localhost:5173"]);
            show_previews(world)?;
            wait_for_urls(world, &["http://localhost:5173"])?;
            // The user reloads the list; the MC's answer, read now, is on
            // its way...
            let f = fake(&mut world.mc);
            f.hold_list = true;
            f.lists = 0;
            update(world, |p| p.reload())?;
            world.wait_for("the list to be asked for", |w| {
                w.mc.peek::<FakePreviews>().is_some_and(|f| f.lists == 1)
            })?;
            // ...when the agent opens another tab, which the client hears of
            // first.
            let tab = tab_at("http://localhost:6006", 2);
            fake(&mut world.mc).tabs.push(tab.clone());
            emit_event(&mut world.mc, &tab, "opened", json!({"snapshot": tab}));
            wait_for_urls(world, &["http://localhost:5173", "http://localhost:6006"])
        },
    );
    steps.step("an older tab list arrives", |world, _, _| {
        fake(&mut world.mc).hold_list = false;
        world.mc.answer_held();
        world.sync()
    });
    steps.step("the client keeps the newer tab state", |world, _, _| {
        let ready = read(world, |p| p.status())? == "ready";
        expect!(
            urls(world) == ["http://localhost:5173", "http://localhost:6006"] && ready,
            "{}",
            describe(world)
        );
        // The next change still counts from the newer one.
        let tab = fake(&mut world.mc).tabs.remove(0);
        emit_event(&mut world.mc, &tab, "closed", json!({}));
        wait_for_urls(world, &["http://localhost:6006"])
    });

    // A new browser tab, and what it offers (preview/surfaces.feature,
    // remote.feature).
    steps.step("the side panel is open", |world, _, _| {
        show_previews(world)?;
        let open = world.with::<RightPanel, _>(|p, _| p.is_open())?;
        expect!(open, "{}", show(&world.state("panel")));
        Ok(())
    });
    steps.step("the user opens the side panel's add menu", |world, _, _| {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nItem { RightPanel { anchors.fill: parent } }\n",
            700.0,
            600.0,
        )?;
        let shown = brick::shown(world)?;
        shown.click(world, "panelAdd")?;
        world.wait_for("the add menu to open", move |w| {
            shown.shows(w, "Browser tab").unwrap_or(false)
        })
    });
    steps.step(
        "it offers a browser tab next to diff, files, terminal and pull request",
        |world, _, _| {
            let shown = brick::shown(world)?;
            for entry in ["Diff", "Files", "Terminal", "Pull requests", "Browser tab"] {
                expect!(
                    shown.shows(world, entry)?,
                    "the add menu has no \"{entry}\""
                );
            }
            // Choosing it opens an empty tab on the MC, shown with the
            // thread's others.
            let item = shown.item(world, "panelAddBrowser")?;
            expect!(shown.flag(world, item, "enabled"), "the browser tab entry is off");
            shown.click(world, "panelAddBrowser")?;
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakePreviews>().is_some_and(|f| f.opens.len() == 1)
                        && read(w, |p| p.count()).is_ok_and(|n| n == 1)
                },
                describe,
            )?;
            let first = fake(&mut world.mc).opens[0].clone();
            let panel = world.state("panel");
            let status = read(world, |p| role(p, 0, "status"))?;
            expect!(
                first["threadId"] == THREAD
                    && first.get("url").is_none()
                    && *at(&panel, "activeId") == json!("previews")
                    && status == "idle",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the thread's project has a dev server running and recently visited pages",
        |world, _, _| {
            fake(&mut world.mc).servers = vec![server("http://localhost:5173", "vite")];
            // The project's script names its own preview address.
            world.mc.projects.insert(
                PROJECT.into(),
                project_row(
                    &format!("/work/{PROJECT}"),
                    json!([{"id": "dev", "name": "Dev", "command": "bun dev", "icon": "play",
                            "runOnWorktreeCreate": false, "previewUrl": "http://localhost:3000"}]),
                ),
            );
            fake(&mut world.mc).looking = true;
            world.connect()?;
            world.sync()?;
            look_at_thread(world, PROJECT)?;
            // Twelve pages opened from browser tabs on this device, the
            // newest first.
            let pages: Vec<String> = (1..=12)
                .rev()
                .map(|n| format!("https://docs.example.com/page-{n}"))
                .collect();
            let settings = Settings::of(world.engine());
            expect!(
                settings.write_device(world.engine(), "previewRecentPages", json!(pages)),
                "{}",
                settings.device_error()
            );
            Ok(())
        },
    );
    steps.step("the user opens a new browser tab", |world, _, _| {
        show_previews(world)?;
        world.dispatch("rightPanel.add", json!({"kind": "browser"}))?;
        world.wait_for_with(
            |w| {
                read(w, |p| p.count() == 1 && role(p, 0, "status") == "idle").unwrap_or(false)
            },
            describe,
        )?;
        world.sync()
    });
    steps.step(
        "the tab suggests the running servers, configured preview addresses and up to 10 recent pages",
        |world, _, _| {
            world.wait_for_with(
                |w| suggested(w, "server") == ["http://localhost:5173"],
                |w| {
                    format!(
                        "the MC's server to be suggested; the tab suggests {}",
                        suggestions(w)
                    )
                },
            )?;
            expect!(
                suggested(world, "configured") == ["http://localhost:3000"],
                "{}",
                suggestions(world)
            );
            let recent = suggested(world, "recent");
            expect!(
                recent.len() == 10
                    && recent.first().is_some_and(|u| u == "https://docs.example.com/page-12")
                    && recent.last().is_some_and(|u| u == "https://docs.example.com/page-3"),
                "{}",
                suggestions(world)
            );
            // The empty tab draws them, and one click opens the page.
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPreviewsPanel { source: Panel.previews }\n",
                420.0,
                900.0,
            )?;
            let shown = brick::shown(world)?;
            for url in [
                "http://localhost:5173",
                "http://localhost:3000",
                "https://docs.example.com/page-12",
            ] {
                expect!(shown.shows(world, url)?, "the tab does not draw {url}");
            }
            expect!(
                !shown.shows(world, "https://docs.example.com/page-2")?,
                "an eleventh recent page is drawn"
            );
            shown.click(world, "previewSuggestion-0")?;
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakePreviews>().is_some_and(|f| f.navigations.len() == 1)
                        && w.opened_urls() == ["http://localhost:5173"]
                },
                describe,
            )?;
            let navigated = fake(&mut world.mc).navigations[0]["url"].clone();
            expect!(navigated == "http://localhost:5173", "{}", describe(world));
            wait_for_urls(world, &["http://localhost:5173"])?;
            // And it is the newest recent page from now on.
            world.wait_for("the page to be remembered", |w| {
                suggested(w, "server").len() == 1
                    && Settings::of(w.engine())
                        .device_value("previewRecentPages")
                        .and_then(|pages| pages.get(0).cloned())
                        .is_some_and(|first| first == "http://localhost:5173")
            })
        },
    );
    steps.step(
        "the desktop is connected to an MC on another machine",
        |world, _, _| {
            // The MC's machine runs these; nothing is scanned on the
            // desktop's.
            fake(&mut world.mc).servers = vec![
                server("http://localhost:4321", "astro"),
                server("http://localhost:8080", "caddy"),
            ];
            Bridge::of(world.engine()).set_local_folder_import_enabled(world.engine(), false);
            Ok(())
        },
    );
    steps.step(
        "the suggestions are the dev servers running on the MC's machine",
        |world, _, _| {
            world.wait_for_with(
                |w| suggested(w, "server") == ["http://localhost:4321", "http://localhost:8080"],
                |w| format!("the MC's servers; the tab suggests {}", suggestions(w)),
            )?;
            let count = read(world, |p| p.suggestions().len())?;
            expect!(count == 2, "{}", suggestions(world));
            // Asked of the MC that serves the thread, by name.
            let watchers = world.mc.subscribers("localServers");
            let named = watchers.len() == 1
                && world.mc.shape_of(watchers[0])["mc"] == json!(world.mc.name);
            expect!(named, "{} watch the MC's servers", watchers.len());
            // And the MC's list is followed as it changes.
            fake(&mut world.mc).servers.pop();
            let servers = fake(&mut world.mc).servers.clone();
            world.mc.send(&json!({"t": "localServers", "id": watchers[0],
                "list": {"servers": servers, "scannedAt": "2026-09-23T10:00:05Z"}}));
            world.wait_for_with(
                |w| suggested(w, "server") == ["http://localhost:4321"],
                suggestions,
            )
        },
    );

    // A dev server on the second MC's machine (remote.feature's Rule).
    steps.step(
        "the client is connected to the MC on its own machine",
        |world, _, _| {
            fake(&mut world.mc).looking = true;
            world.mc.projects.insert(
                PROJECT.into(),
                project_row(&format!("/work/{PROJECT}"), json!([])),
            );
            world.connect()?;
            world.sync()
        },
    );
    steps.step(
        "that MC is in a cluster with a second MC on another machine",
        |world, _, _| {
            world.mc.join(PEER, PEER_ENVIRONMENT);
            world.sync()
        },
    );
    steps.step(
        "the desktop's MC runs on another machine and is in a cluster with a second MC",
        |world, _, _| {
            fake(&mut world.mc).looking = true;
            world.mc.projects.insert(
                PROJECT.into(),
                project_row(&format!("/work/{PROJECT}"), json!([])),
            );
            world.connect()?;
            world.served_from(OTHER_MACHINE)?;
            world.mc.join(PEER, PEER_ENVIRONMENT);
            world.sync()
        },
    );
    steps.step(
        &format!("the system browser opens {Q}"),
        |world, c, _| {
            world.wait_for("the browser to open", |w| !w.opened_urls().is_empty())?;
            expect!(
                world.opened_urls() == [c[0].clone()],
                "the browser opened {:?}",
                world.opened_urls()
            );
            Ok(())
        },
    );
    steps.step("nothing is forwarded", |world, _, _| {
        let forwards = fake(&mut world.mc).forwards.len();
        expect!(forwards == 0, "{forwards} forwards were asked for");
        Ok(())
    });
    steps.step(
        "a dev server on the second MC's machine listens on port 3000 for that machine only",
        |world, _, _| {
            // Port 3000 is taken on this machine, so the forward's port
            // differs and shows.
            fake(&mut world.mc).forward_port = 3001;
            Ok(())
        },
    );
    steps.step(
        &format!("a thread on the second MC has a browser tab at {Q}"),
        |world, c, _| {
            let n = fake(&mut world.mc).tabs.len() + 1;
            let mut tab = tab_at(&c[0], n);
            tab["threadId"] = json!(PEER_THREAD);
            let f = fake(&mut world.mc);
            f.tabs.push(tab);
            f.revision += 1;
            look_at_peer_thread(world)?;
            if !panel_shows_previews(world) {
                world.with::<RightPanel, _>(|p, engine| p.toggle_previews(engine))?;
            }
            wait_for_urls(world, &[&c[0]])
        },
    );
    steps.step("the user hides the thread's previews", |world, _, _| {
        if panel_shows_previews(world) {
            world.with::<RightPanel, _>(|p, engine| p.toggle_previews(engine))?;
        }
        world.sync()?;
        world.wait_for("the desktop to stop following the tabs", |w| {
            w.mc.subscribers("preview").is_empty()
        })
    });
    // The desktop no longer follows the tabs, so it hears nothing of this.
    steps.step(
        &format!("another client closes the thread's tab at {Q}"),
        |world, c, _| {
            let at = fake(&mut world.mc).tabs.iter().position(|tab| {
                tab["threadId"] == PEER_THREAD && tab["navStatus"]["url"] == c[0]
            });
            let Some(at) = at else {
                fail!("no tab at {}", c[0]);
            };
            let tab = fake(&mut world.mc).tabs.remove(at);
            emit_event(&mut world.mc, &tab, "closed", json!({}));
            world.sync()
        },
    );
    steps.step("the user opens the tab", |world, _, _| {
        let tab = read(world, |p| role(p, 0, "tabId"))?;
        update(world, |p| p.open(&tab))?;
        world.sync()
    });
    steps.step(
        "the system browser opens the address the desktop's MC forwards to the dev server",
        |world, _, _| opened_through_forward(world, "http://localhost:3001"),
    );
    steps.step(
        &format!("the agent of a thread on the second MC writes {Q}"),
        |world, c, _| {
            look_at_peer_thread(world)?;
            start_run(world, 30, "running")?;
            add_item(world, "assistant_message", json!({"text": c[0]}))?;
            settle_run(world, "completed", 30)?;
            fake(&mut world.mc).link = c[0].clone();
            Ok(())
        },
    );
    // From the link's menu; a Ctrl-click (ThreadView's openLink) asks the
    // same of the panel.
    steps.step("the user opens the link", |world, _, _| {
        let link = fake(&mut world.mc).link.clone();
        world.dispatch("link.menu", json!({"url": link, "x": 10, "y": 10}))?;
        world.wait_for("the link's menu to open", |w| {
            at(&w.state("menu"), "items")
                .as_array()
                .is_some_and(|items| !items.is_empty())
        })?;
        let menu = world.state("menu");
        world.dispatch(
            "menu.select",
            json!({"requestId": at(&menu, "requestId"), "id": "open"}),
        )?;
        world.sync()
    });
    steps.step(
        &format!(
            "the system browser opens {Q} on the address the desktop's MC forwards to the dev server"
        ),
        |world, c, _| opened_through_forward(world, &format!("http://localhost:3001{}", c[0])),
    );
    steps.step(
        &format!("the thread gets a browser tab at {Q}"),
        |world, c, _| {
            world.wait_for("a browser tab to open", |w| {
                w.mc.peek::<FakePreviews>().is_some_and(|f| !f.opens.is_empty())
            })?;
            let opens = fake(&mut world.mc).opens.clone();
            expect!(
                opens == [json!({"threadId": PEER_THREAD, "url": c[0]})],
                "{} tabs were opened: {}",
                opens.len(),
                show(&Json::Array(opens.clone()))
            );
            Ok(())
        },
    );

    // Closing.
    steps.step("the MC refuses to close a browser tab", |world, _, _| {
        have_tabs(world, &["http://localhost:5173", "http://localhost:6006"]);
        fake(&mut world.mc).refuse_close = true;
        show_previews(world)
    });
    steps.step("the user closes the tab", |world, _, _| {
        let tab = tab_id_of(world, "http://localhost:5173")?;
        update(world, |p| p.close(&tab))?;
        expect!(
            urls(world) == ["http://localhost:6006"],
            "{}",
            describe(world)
        );
        world.sync()
    });
    steps.step("the tab returns as it was", |world, _, _| {
        wait_for_urls(world, &["http://localhost:5173", "http://localhost:6006"])?;
        let items = toast_items(world);
        expect!(
            items
                .last()
                .is_some_and(|t| t["title"] == "Could not close the browser tab"),
            "{}",
            show(&Json::Array(items.clone()))
        );
        Ok(())
    });
    steps.step("the user closes a browser tab", |world, _, _| {
        have_tabs(world, &["http://localhost:5173"]);
        show_previews(world)?;
        fake(&mut world.mc).hold_close = true;
        let tab = tab_id_of(world, "http://localhost:5173")?;
        update(world, |p| p.close(&tab))?;
        world.sync()
    });
    steps.step(
        "the tab disappears at once, even if an older update about it arrives",
        |world, _, _| {
            expect!(urls(world).is_empty(), "{}", describe(world));
            // The page finished loading before the close reached the MC.
            let mut tab = fake(&mut world.mc).tabs[0].clone();
            tab["navStatus"] = json!({"_tag": "Success", "url": "http://localhost:5173", "title": "Vite"});
            emit_event(&mut world.mc, &tab, "navigated", json!({"snapshot": tab}));
            world.sync()?;
            expect!(urls(world).is_empty(), "{}", describe(world));
            world.mc.answer_held();
            world.sync()?;
            let gone = fake(&mut world.mc).tabs.is_empty();
            expect!(urls(world).is_empty() && gone, "{}", describe(world));
            Ok(())
        },
    );
}
