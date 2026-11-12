//! Moving about in a browser tab: the address field, loads that fail or
//! stop, back and forward, a page's source, DevTools, popups, mute and the
//! user's own browser, against the loopback dev server, as desktop-qt's
//! BrowserSteps.cpp. features/preview/surfaces.feature.

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::{ObjectId, Value};
use serde_json::Value as Json;

use super::browser::{
    self, active_tab, dev_server, draw_panel, embed, evaluate, evaluated, failure, find, loading,
    panel, read_flag, read_text, server_url, show_tab, state, view, view_url, wait_for_engine,
    wait_for_page, wait_for_tab, wait_for_title,
};
use super::{describe, fake, read, show_previews, toast_items, update};
use crate::harness::{Outcome, Q, Steps, show};
use crate::world::World;
use crate::{expect, fail};

/// Runs a command as its keybinding does.
pub(super) fn run(world: &mut World, command: &str) -> Outcome {
    let ran = Commands::of(world.engine()).run(world.engine(), command);
    world.pump()?;
    expect!(ran, "{command} did not run");
    Ok(())
}

/// The browser panel item, its functions to call.
pub(super) fn browser_panel(world: &mut World) -> Outcome<ObjectId> {
    panel(world)?.item(world, "browserPanel")
}

pub(super) fn call(
    world: &mut World,
    item: ObjectId,
    function: &str,
    args: &[Value],
) -> Outcome<Value> {
    let called = world.engine().invoke_by_name(item, function, args);
    world.pump()?;
    match called {
        Ok(value) => Ok(value),
        Err(e) => fail!("{function} failed: {e:?}"),
    }
}

/// The panel loads `url`, as a link the user followed (`tell`: the MC
/// hears of it).
fn go(world: &mut World, url: &str) -> Outcome {
    let panel = browser_panel(world)?;
    call(world, panel, "go", &[Value::from(url), Value::Bool(true)])?;
    Ok(())
}

fn address(world: &mut World) -> Outcome<ObjectId> {
    panel(world)?.item(world, "browserAddress")
}

fn address_text(world: &mut World) -> Outcome<String> {
    let field = address(world)?;
    Ok(read_text(world, field, "text"))
}

fn address_focused(world: &mut World) -> Outcome<bool> {
    let field = address(world)?;
    Ok(read_flag(world, field, "activeFocus"))
}

fn address_problem(world: &mut World) -> Outcome<String> {
    let panel = browser_panel(world)?;
    Ok(read_text(world, panel, "addressProblem"))
}

/// Types `text` over the whole address and presses Enter.
fn type_address(world: &mut World, text: &str, enter: bool) -> Outcome {
    let field = address(world)?;
    call(world, field, "forceActiveFocus", &[])?;
    call(world, field, "selectAll", &[])?;
    world.type_text(text)?;
    if enter {
        panel(world)?.press(world, "enter")?;
    }
    Ok(())
}

/// The dev server's address without its "http://".
fn bare(url: &str) -> &str {
    url.strip_prefix("http://").unwrap_or(url)
}

/// Opens `item` from `menu`, and waits for the menu to close behind it.
pub(super) fn choose(world: &mut World, menu: &str, item: &str) -> Outcome {
    let brick = panel(world)?;
    brick.click(world, menu)?;
    wait_for_engine(
        world,
        |w| find(w, brick, item).is_some(),
        |_| format!("{menu} to offer {item}"),
    )?;
    brick.click(world, item)?;
    wait_for_engine(
        world,
        |w| find(w, brick, item).is_none(),
        |_| format!("{menu} to close"),
    )
}

/// Chromium's net error for each name the ledger uses.
fn net_error(name: &str) -> Option<i32> {
    Some(match name {
        "ERR_NAME_NOT_RESOLVED" => -105,
        "ERR_CONNECTION_REFUSED" => -102,
        "ERR_CONNECTION_TIMED_OUT" => -118,
        "ERR_INTERNET_DISCONNECTED" => -106,
        "ERR_CERT_AUTHORITY_INVALID" => -202,
        "ERR_TOO_MANY_REDIRECTS" => -310,
        _ => return None,
    })
}

fn wait_to_fail(world: &mut World) -> Outcome {
    let brick = panel(world)?;
    wait_for_engine(
        world,
        |w| !failure(w, brick).is_empty(),
        |w| format!("the page to fail; {}", state(w, brick)),
    )
}

fn popup_view(world: &World, window: ObjectId) -> Option<ObjectId> {
    match world.engine().read_by_name(window, "view") {
        Value::Object(view) => Some(view),
        _ => None,
    }
}

fn popup_count(world: &World) -> usize {
    popups_of(world).len()
}

/// The popup windows the page opened: the panel's windows holding a page.
fn popups_of(world: &World) -> Vec<ObjectId> {
    let Some(shown) = world.peek_part::<crate::brick::Shown>().and_then(|s| s.0) else {
        return Vec::new();
    };
    let Some(panel) = shown.find(world, "browserPanel").ok().flatten() else {
        return Vec::new();
    };
    // The tab's own view is the panel's too; a popup is a window of its own.
    let tab = shown.find(world, "browserView").ok().flatten();
    world
        .engine()
        .children(panel)
        .into_iter()
        .filter(|child| popup_view(world, *child).is_some_and(|v| Some(v) != tab))
        .collect()
}

fn first_popup(world: &World) -> Option<ObjectId> {
    popups_of(world).into_iter().next()
}

fn size_of(world: &World, item: ObjectId) -> (f64, f64) {
    let read = |name: &str| read_text(world, item, name).parse::<f64>().unwrap_or(0.0);
    (read("width"), read("height"))
}

fn run_in(world: &mut World, view: ObjectId, script: &str) -> Outcome {
    call(world, view, "runJavaScript", &[Value::from(script)])?;
    Ok(())
}

// TODO(ljos#389): Ljós's devToolsView never loads DevTools yet.
fn devtools_shown(world: &mut World, right: bool) -> Outcome {
    let brick = panel(world)?;
    wait_for_engine(
        world,
        |w| {
            find(w, brick, "browserDevToolsView").is_some_and(|tools| {
                !read_flag(w, tools, "loading")
                    && read_text(w, tools, "url").starts_with("devtools:")
            })
        },
        |w| format!("DevTools to load; {}", state(w, brick)),
    )?;
    let tools = brick.item(world, "browserDevToolsView")?;
    wait_for_engine(
        world,
        |w| read_text(w, tools, "title").contains("DevTools"),
        |w| {
            format!(
                "DevTools to name the page; they are \"{}\"",
                read_text(w, tools, "title")
            )
        },
    )?;
    let Some(shown) = view(world, brick) else {
        fail!("{}", state(world, brick));
    };
    let (vx, vy) = brick.at(world, shown, 0.0, 0.0)?;
    let (vw, vh) = size_of(world, shown);
    let (tx, ty) = brick.at(world, tools, 0.0, 0.0)?;
    let (tw, th) = size_of(world, tools);
    let placed = if right {
        tx >= vx + vw - 0.5 && th > vh / 2.0
    } else {
        ty >= vy + vh - 0.5 && tw >= vw - 0.5
    };
    expect!(
        placed,
        "DevTools are at {tx},{ty} ({tw}x{th}); the page is at {vx},{vy} ({vw}x{vh})"
    );
    Ok(())
}

fn offers(world: &mut World, icon: &str, what: &str) -> Outcome {
    let brick = panel(world)?;
    let button = brick.item(world, "browserReload")?;
    let icon = icon.to_owned();
    wait_for_engine(
        world,
        |w| read_flag(w, button, "enabled") && read_text(w, button, "iconName") == icon,
        |w| {
            format!(
                "the tab to offer to {what}; its button shows {}; {}",
                read_text(w, button, "iconName"),
                state(w, brick)
            )
        },
    )
}

/// A button over the whole page, as desktop-qt's BrowserPermissionSteps.cpp:
/// the user's click on it runs `window.act`, as a page acts on a click.
const ACT: &str = "<button style=\"position:fixed;left:0;top:0;width:100vw;height:100vh;opacity:0.5\" \
     onclick=\"window.act && window.act()\">Act</button>";

/// The page runs `script` from the user's click. Chromium opens a window
/// only from a user's gesture, and a script the view runs has none.
pub(super) fn act(world: &mut World, script: &str) -> Outcome {
    evaluate(
        world,
        &format!(
            "window.acted = false; window.act = function () {{ if (window.acted) return; window.acted = true; {script} }}; true"
        ),
    )?;
    // A page that has just replaced another takes no input until it has
    // drawn, so the user clicks again until it does; the page acts once.
    for _ in 0..50 {
        let brick = panel(world)?;
        let Some(page) = view(world, brick) else {
            fail!("the tab has no page; {}", state(world, brick));
        };
        let height = read_text(world, page, "height")
            .parse::<f64>()
            .unwrap_or(0.0);
        let (x, y) = brick.at_px(world, page, 16.0, height - 16.0)?;
        world.click_at(x, y)?;
        if evaluate(world, "window.acted")? == Json::Bool(true) {
            return Ok(());
        }
    }
    fail!("the page did not take the user's click")
}

/// A page whose link and script open new windows.
fn sign_in_page(world: &mut World) -> Outcome {
    let server = dev_server(world)?;
    server.page(
        "/",
        "Dev server",
        &format!("{ACT}<a id=away href=/away target=_blank>Docs</a>\
         <script>window.addEventListener('message', function (e) {{ document.title = 'Signed in as ' + e.data; }});\
         function signIn() {{ window.open('/sign-in', 'sign-in', 'width=420,height=560'); }}</script>"),
    );
    server.page("/sign-in", "Sign in", "");
    server.page("/away", "Away", "");
    show_tab(world, "/")
}

fn open_popup(world: &mut World) -> Outcome {
    act(world, "signIn();")?;
    let brick = panel(world)?;
    wait_for_engine(
        world,
        |w| {
            popup_count(w) == 1
                && first_popup(w)
                    .and_then(|p| popup_view(w, p))
                    .is_some_and(|v| read_text(w, v, "title") == "Sign in")
        },
        |w| {
            let windows: Vec<String> = popups_of(w)
                .into_iter()
                .map(|p| match popup_view(w, p) {
                    Some(v) => format!(
                        "{} at {:?} titled {:?}",
                        read_text(w, p, "objectName"),
                        read_text(w, v, "url"),
                        read_text(w, v, "title")
                    ),
                    None => "a window with no page".into(),
                })
                .collect();
            format!("a sign-in window; windows {windows:?}; {}", state(w, brick))
        },
    )
}

fn first_tab_url(world: &World) -> String {
    read(world, |p| {
        if p.count() == 0 {
            String::new()
        } else {
            super::role(p, 0, "url")
        }
    })
    .unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    register_loads(steps);
    register_address(steps);
    register_history(steps);
    register_tools(steps);
    register_windows(steps);
}

fn register_loads(steps: &mut Steps) {
    // The start page.
    steps.step(
        "the user adds a browser tab from the side panel",
        |world, _, _| {
            world.dispatch("rightPanel.add", serde_json::json!({"kind": "browser"}))?;
            wait_for_tab(world, "")
        },
    );
    steps.step(
        "the start page offers the dev server to open",
        |world, _, _| {
            let url = server_url(world, "")?;
            let brick = panel(world)?;
            wait_for_engine(
                world,
                |w| {
                    find(w, brick, "browserStart").is_some()
                        && find(w, brick, "browserSuggestion-0").is_some_and(|first| {
                            let data = w.engine().read_by_name(first, "modelData");
                            let data = hal_c2_shell::json::from_value(w.engine(), &data);
                            data["url"].as_str().is_some_and(|u| u.starts_with(&url))
                        })
                },
                |w| format!("the start page to offer {url}; {}", state(w, brick)),
            )
        },
    );
    steps.step("the user picks it", |world, _, _| {
        panel(world)?.click(world, "browserSuggestion-0")
    });
    steps.step("the tab loads the dev server", |world, _, _| {
        let url = server_url(world, "/")?;
        wait_for_page(world, &url)?;
        let brick = panel(world)?;
        expect!(
            find(world, brick, "browserStart").is_none(),
            "the start page still shows"
        );
        wait_for_engine(world, |w| first_tab_url(w) == url, describe)?;
        let opened = world.opened_urls();
        expect!(opened.is_empty(), "the user's browser opened {opened:?}");
        Ok(())
    });

    // Failing pages.
    steps.step(
        r"a browser tab whose page fails with (\w+)",
        |world, captures, _| {
            show_tab(world, "/")?;
            let code = captures[0].as_str();
            match code {
                // TODO(ljos#387): neither reaches the panel as a failed load
                // yet; the engine shows its own error page instead.
                // TODO(ljos#395): either load stalls the engine past the
                // runner's watchdog. Once it does not, ERR_CONNECTION_REFUSED
                // stops the dev server and asks again
                // (`dev_server(world)?.stop()`, then
                // `run(world, "preview.refresh")`), and ERR_TOO_MANY_REDIRECTS
                // goes to a path that redirects to itself
                // (`dev_server(world)?.redirect("/loop", "/loop")`).
                "ERR_CONNECTION_REFUSED" | "ERR_TOO_MANY_REDIRECTS" => {
                    fail!("the engine stalls on {code} (ljos#395)");
                }
                _ => {
                    // What the network does not do on the loopback, as the
                    // engine says it.
                    let Some(number) = net_error(code) else {
                        fail!("no net error is named {code}");
                    };
                    let url = server_url(world, "/")?;
                    let panel = browser_panel(world)?;
                    call(
                        world,
                        panel,
                        "failed",
                        &[
                            Value::from(number),
                            Value::from(code),
                            Value::from(url.as_str()),
                        ],
                    )?;
                }
            }
            wait_to_fail(world)
        },
    );
    steps.step(
        &format!("the tab says {Q} and {Q}"),
        |world, captures, _| {
            let brick = panel(world)?;
            let says = brick.shows(world, &captures[0])?;
            expect!(
                says && failure(world, brick) == captures[1],
                "{}",
                state(world, brick)
            );
            Ok(())
        },
    );
    steps.step("the user can reload the page", |world, _, _| {
        let server = dev_server(world)?;
        server.listen();
        server.page("/loop", "Dev server", "");
        server.redirect("/loop", "/");
        panel(world)?.click(world, "browserFailureReload")?;
        wait_for_title(world, "Dev server")?;
        let brick = panel(world)?;
        expect!(failure(world, brick).is_empty(), "{}", state(world, brick));
        Ok(())
    });
    steps.step(
        "a browser tab whose page starts another load before the first finishes",
        |world, _, _| {
            show_tab(world, "/")?;
            let server = dev_server(world)?;
            server.page("/next", "Next", "");
            server.page("/slow", "Slow", "");
            // The page leaves for a page that is slow to answer, then changes
            // its mind while that page is still on its way.
            server.hold();
            evaluate(
                world,
                "location.href = '/slow'; setTimeout(function () { location.href = '/next'; }, 0); true",
            )?;
            let brick = panel(world)?;
            wait_for_engine(
                world,
                |w| asked_for(w, "/next"),
                |w| format!("the page to ask for /next; {}", state(w, brick)),
            )?;
            dev_server(world)?.release();
            wait_for_title(world, "Next")
        },
    );
    steps.step(
        "the tab does not say the page failed to load",
        |world, _, _| {
            let brick = panel(world)?;
            expect!(failure(world, brick).is_empty(), "{}", state(world, brick));
            wait_for_engine(
                world,
                |w| {
                    read(w, |p| {
                        p.count() > 0 && super::role(p, 0, "status") == "loaded"
                    })
                    .unwrap_or(false)
                },
                describe,
            )
        },
    );
    steps.step("a browser tab whose page failed to load", |world, _, _| {
        // TODO(ljos#387, ljos#395): the refused load never reaches the
        // panel yet, and stalls the engine past the runner's watchdog. Once
        // it does not, the dev server stops and the tab asks again
        // (`dev_server(world)?.stop()`, `run(world, "preview.refresh")`,
        // then `wait_to_fail(world)`).
        show_tab(world, "/")?;
        fail!("the engine stalls on ERR_CONNECTION_REFUSED (ljos#395)")
    });
    steps.step("the load is reported as having stopped", |world, _, _| {
        let brick = panel(world)?;
        let Some(shown) = view(world, brick) else {
            fail!("{}", state(world, brick));
        };
        call(world, shown, "stop", &[])?;
        world.sync()
    });
    steps.step(
        "the tab still says the page failed to load",
        |world, _, _| {
            let brick = panel(world)?;
            expect!(
                failure(world, brick) == "Connection refused",
                "{}",
                state(world, brick)
            );
            Ok(())
        },
    );
    steps.step("the user reloads the page", |world, _, _| {
        let server = dev_server(world)?;
        server.listen();
        server.hold();
        panel(world)?.click(world, "browserReload")?;
        wait_for_engine(
            world,
            |w| requests(w) > 0,
            |_| "the page to be asked for again".to_owned(),
        )
    });
    steps.step(
        "the failure is cleared while the new load runs",
        |world, _, _| {
            let brick = panel(world)?;
            wait_for_engine(world, |w| failure(w, brick).is_empty(), |w| state(w, brick))?;
            expect!(loading(world, brick), "{}", state(world, brick));
            dev_server(world)?.release();
            wait_for_title(world, "Dev server")
        },
    );
    steps.step(
        "the agent restarts the dev server and the user reloads the tab",
        |world, _, _| {
            let server = dev_server(world)?;
            server.stop();
            server.page("/", "Dev server, restarted", "");
            let port = server.port();
            expect!(
                server.listen(),
                "the dev server could not listen again on {port}"
            );
            // mod+r, with the page focused.
            run(world, "preview.refresh")
        },
    );
    steps.step(
        "the page reloads without the user leaving the thread",
        |world, _, _| {
            wait_for_title(world, "Dev server, restarted")?;
            let tab = format!("browser:{}", browser::browsing(world).tab_id);
            let brick = panel(world)?;
            expect!(
                active_tab(world) == tab && world.opened_urls().is_empty(),
                "{}",
                state(world, brick)
            );
            Ok(())
        },
    );

    // Stopping a load.
    steps.step(
        "a browser tab whose page is still loading",
        |world, _, _| {
            show_tab(world, "/")?;
            dev_server(world)?.unfinished("/slow", "Half", "The first half");
            let url = server_url(world, "/slow")?;
            go(world, &url)?;
            // The first half drawn, the rest on its way.
            let brick = panel(world)?;
            wait_for_engine(
                world,
                |w| {
                    view(w, brick).is_some_and(|v| read_text(w, v, "title") == "Half")
                        && loading(w, brick)
                },
                |w| format!("the first half of the page; {}", state(w, brick)),
            )
        },
    );
    steps.step(
        "the tab offers to stop loading instead of reloading",
        |world, _, _| offers(world, "x", "stop"),
    );
    steps.step("the tab offers to reload again", |world, _, _| {
        offers(world, "rotate-cw", "reload")
    });
    steps.step("the user stops the load", |world, _, _| {
        let brick = panel(world)?;
        brick.click(world, "browserReload")?;
        wait_for_engine(
            world,
            |w| !loading(w, brick),
            |w| format!("the load to stop; {}", state(w, brick)),
        )
    });
    steps.step("the tab keeps what had loaded", |world, _, _| {
        let url = server_url(world, "/slow")?;
        let brick = panel(world)?;
        expect!(
            view_url(world, brick) == url && failure(world, brick).is_empty(),
            "{}",
            state(world, brick)
        );
        let shown = evaluated(
            world,
            "document.title + ': ' + document.body.innerText.trim()",
        )?;
        expect!(
            shown == "Half: The first half",
            "the page shows \"{shown}\""
        );
        Ok(())
    });
}

fn requests(world: &World) -> usize {
    world
        .mc
        .peek::<browser::Browsing>()
        .and_then(browser::Browsing::server)
        .map_or(0, |s| s.requests())
}

fn asked_for(world: &World, path: &str) -> bool {
    world
        .mc
        .peek::<browser::Browsing>()
        .and_then(browser::Browsing::server)
        .is_some_and(|s| s.paths().iter().any(|p| p == path))
}

fn register_address(steps: &mut Steps) {
    steps.step(
        "the user types the address of another of its pages without \"http://\" and presses Enter",
        |world, _, _| {
            dev_server(world)?.page("/docs", "Docs", "");
            let port = dev_server(world)?.port();
            let typed = format!("localhost:{port}/docs");
            browser::browsing(world).typed = typed.clone();
            type_address(world, &typed, true)
        },
    );
    steps.step("the tab loads that page over http", |world, _, _| {
        let url = format!("http://{}", browser::browsing(world).typed);
        wait_for_page(world, &url)?;
        wait_for_title(world, "Docs")
    });
    steps.step(
        "the address field shows the page's address",
        |world, _, _| {
            let brick = panel(world)?;
            let field = address(world)?;
            wait_for_engine(
                world,
                |w| read_text(w, field, "text") == view_url(w, brick),
                |w| {
                    format!(
                        "the field shows {}; {}",
                        read_text(w, field, "text"),
                        state(w, brick)
                    )
                },
            )?;
            expect!(
                !address_focused(world)?,
                "the address field kept the keyboard"
            );
            Ok(())
        },
    );
    steps.step(
        "the user has typed a different address in the field",
        |world, _, _| {
            type_address(world, "example.com", false)?;
            let text = address_text(world)?;
            expect!(text == "example.com", "the field says \"{text}\"");
            Ok(())
        },
    );
    steps.step("the field shows the page's address again", |world, _, _| {
        let url = server_url(world, "/")?;
        let text = address_text(world)?;
        expect!(text == url, "the field says \"{text}\"");
        Ok(())
    });
    steps.step("the field no longer has focus", |world, _, _| {
        expect!(
            !address_focused(world)?,
            "the address field kept the keyboard"
        );
        Ok(())
    });
    steps.step("the user focuses the address field", |world, _, _| {
        // mod+l, with the page focused.
        run(world, "preview.focusUrl")
    });
    steps.step(
        "the whole address is selected, ready to be replaced",
        |world, _, _| {
            expect!(
                address_focused(world)?,
                "the address field does not have the keyboard"
            );
            let field = address(world)?;
            let selected = read_text(world, field, "selectedText");
            let url = server_url(world, "/")?;
            expect!(selected == url, "\"{selected}\" is selected");
            Ok(())
        },
    );
    steps.step(
        &format!("the user types {Q} in the address field and presses Enter"),
        |world, captures, _| type_address(world, &captures[0], true),
    );
    // The desktop opens a tab at an address as a new tab, typed into.
    steps.step(
        &format!("a client opens a browser tab for the thread at {Q}"),
        |world, captures, _| {
            show_previews(world)?;
            embed(world)?;
            draw_panel(world)?;
            update(world, |p| p.new_tab())?;
            world.sync()?;
            wait_for_tab(world, "")?;
            let field = address(world)?;
            call(world, field, "forceActiveFocus", &[])?;
            world.type_text(&captures[0])?;
            panel(world)?.press(world, "enter")?;
            world.sync()
        },
    );
    steps.step(
        &format!("the thread has a new tab loading {Q}"),
        |world, captures, _| {
            // The address as typed, or with the root path a browser gives it.
            let want = captures[0].clone();
            let is = move |url: &str| url == want || url == format!("{want}/");
            let brick = panel(world)?;
            let navigated = |w: &World| -> Option<String> {
                let fake = w.mc.peek::<super::FakePreviews>()?;
                (fake.navigations.len() == 1)
                    .then(|| fake.navigations[0]["url"].as_str().unwrap_or("").to_owned())
            };
            wait_for_engine(
                world,
                |w| navigated(w).is_some_and(|u| is(&u)) && is(&view_url(w, brick)),
                |w| {
                    let fake = w.mc.peek::<super::FakePreviews>();
                    format!(
                        "the tab to load; the MC was asked for {} (opened {}); the toasts are {}; {}",
                        fake.map_or(String::new(), |f| show(&Json::from(f.navigations.clone()))),
                        fake.map_or(String::new(), |f| show(&Json::from(f.opens.clone()))),
                        show(&w.state("toasts")),
                        state(w, brick)
                    )
                },
            )?;
            // In the one tab the MC opened.
            let fake = fake(&mut world.mc);
            expect!(
                fake.tabs.len() == 1 && fake.tabs[0]["tabId"] == fake.navigations[0]["tabId"],
                "the MC opened {} tabs",
                fake.tabs.len()
            );
            Ok(())
        },
    );
    steps.step("no tab opens", |world, _, _| {
        // The new tab stays empty: the MC is not asked to open a page in it.
        world.sync()?;
        let brick = panel(world)?;
        let asked = fake(&mut world.mc).navigations.len();
        expect!(
            asked == 0 && view_url(world, brick).is_empty(),
            "{}",
            state(world, brick)
        );
        Ok(())
    });
    steps.step(
        "the client is told the address cannot be opened",
        |world, _, _| {
            let problem = address_problem(world)?;
            expect!(
                problem.contains("Only http and https pages open here"),
                "the field says \"{problem}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told to enter an http or https URL",
        |world, _, _| {
            world.sync()?;
            let problem = address_problem(world)?;
            expect!(
                problem.contains("Enter an http or https URL"),
                "the field says \"{problem}\""
            );
            // Beside what was typed, still there to be put right.
            expect!(
                address_focused(world)?,
                "the address field lost the keyboard, so the problem is not shown"
            );
            let url = server_url(world, "/")?;
            expect!(
                address_text(world)? != url,
                "the field put the page's address back"
            );
            Ok(())
        },
    );
    steps.step(
        "the tab stays on (?:its page|the thread's dev server)",
        |world, _, _| {
            world.sync()?;
            let url = server_url(world, "/")?;
            let brick = panel(world)?;
            let asked = fake(&mut world.mc).navigations.len();
            expect!(
                view_url(world, brick) == url && asked == 0,
                "{}",
                state(world, brick)
            );
            Ok(())
        },
    );
    steps.step(
        "the address field says only web addresses can be opened",
        |world, _, _| {
            let problem = address_problem(world)?;
            expect!(problem.contains("http"), "the field says \"{problem}\"");
            Ok(())
        },
    );
}

fn register_history(steps: &mut Steps) {
    // A page's source.
    steps.step("the user views the page's source", |world, _, _| {
        // What the page's context menu's View page source does: the engine
        // asks for a window at the page's source, which the tab shows.
        // TODO(ljos#386): triggerWebAction(WebEngineView.ViewSource)
        // once Ljós's WebEngineView has it; until then the request it makes.
        let brick = panel(world)?;
        let Some(shown) = view(world, brick) else {
            fail!("{}", state(world, brick));
        };
        let source = format!("view-source:{}", read_text(world, shown, "url"));
        let panel = browser_panel(world)?;
        call(
            world,
            panel,
            "go",
            &[Value::from(source.as_str()), Value::Bool(false)],
        )?;
        Ok(())
    });
    steps.step(
        &format!("the user types the page's address after {Q} and presses Enter"),
        |world, captures, _| {
            let url = server_url(world, "/")?;
            type_address(world, &format!("{}{}", captures[0], bare(&url)), true)
        },
    );
    // TODO(ljos#388): Ljós's view reports the page's own url for its source yet.
    steps.step(
        "the tab shows the (other )?page's source",
        |world, captures, _| {
            let path = if captures[0].is_empty() {
                "/"
            } else {
                "/other"
            };
            let source = format!("view-source:{}", server_url(world, path)?);
            let brick = panel(world)?;
            wait_for_engine(
                world,
                |w| view_url(w, brick) == source && !loading(w, brick),
                |w| format!("the tab to show {source}; {}", state(w, brick)),
            )?;
            // Over the start page, with the address it has.
            expect!(
                find(world, brick, "browserStart").is_none(),
                "the start page covers the source"
            );
            let text = address_text(world)?;
            expect!(text == source, "the address field says \"{text}\"");
            Ok(())
        },
    );
    steps.step("the MC's tab stays on the page", |world, _, _| {
        world.sync()?;
        let url = server_url(world, "/")?;
        let fake = fake(&mut world.mc);
        let reported = fake
            .tabs
            .first()
            .and_then(|t| t["navStatus"]["url"].as_str())
            .unwrap_or("")
            .to_owned();
        let asked = fake.navigations.len();
        expect!(
            asked == 0 && reported == url,
            "the MC was asked for {asked} pages and told of {reported}"
        );
        let toasts = toast_items(world);
        expect!(
            toasts.is_empty(),
            "the toasts are {}",
            show(&world.state("toasts"))
        );
        Ok(())
    });
    // From the address field: Chromium skips, going back, a page that moved
    // on by script without the user's gesture.
    steps.step(
        "the user opens another page from the address field",
        |world, _, _| {
            dev_server(world)?.page("/other", "Other", "");
            let url = server_url(world, "/other")?;
            type_address(world, bare(&url), true)?;
            wait_for_title(world, "Other")
        },
    );
    steps.step("the tab shows the other page", |world, _, _| {
        let url = server_url(world, "/other")?;
        wait_for_page(world, &url)
    });
    // Back is triggered, not clicked, once the view can go back and is idle,
    // as desktop-qt does.
    steps.step("the user goes back in the tab", |world, _, _| {
        let brick = panel(world)?;
        for _ in 0..20 {
            wait_for_engine(
                world,
                |w| {
                    find(w, brick, "browserBack").is_some_and(|b| read_flag(w, b, "enabled"))
                        && !loading(w, brick)
                },
                |w| format!("Back to be available; {}", state(w, brick)),
            )?;
            if evaluated(world, "document.readyState")? == "complete" {
                let back = brick.item(world, "browserBack")?;
                call(world, back, "clicked", &[])?;
                return Ok(());
            }
        }
        fail!("the page did not finish loading: {}", state(world, brick))
    });
    // Where the tab can go.
    steps.step(
        "a browser tab whose page (is the only one it has shown|follows an earlier page|is the first page, reached by going back)",
        |world, captures, _| {
            show_tab(world, "/")?;
            if captures[0].starts_with("is the only") {
                return Ok(());
            }
            dev_server(world)?.page("/other", "Other", "");
            let other = server_url(world, "/other")?;
            go(world, &other)?;
            wait_for_page(world, &other)?;
            if captures[0].starts_with("follows") {
                return Ok(());
            }
            let brick = panel(world)?;
            wait_for_engine(
                world,
                |w| find(w, brick, "browserBack").is_some_and(|b| read_flag(w, b, "enabled")),
                |w| format!("Back to be available; {}", state(w, brick)),
            )?;
            brick.click(world, "browserBack")?;
            let url = server_url(world, "/")?;
            wait_for_page(world, &url)
        },
    );
    steps.step(
        "going (back|forward) is (available|unavailable)",
        |world, captures, _| {
            let name = if captures[0] == "back" {
                "browserBack"
            } else {
                "browserForward"
            };
            let brick = panel(world)?;
            let button = brick.item(world, name)?;
            let available = captures[1] == "available";
            let (way, said) = (captures[0].clone(), captures[1].clone());
            wait_for_engine(
                world,
                |w| read_flag(w, button, "enabled") == available,
                |w| format!("going {way} to be {said}; {}", state(w, brick)),
            )
        },
    );
}

fn register_tools(steps: &mut Steps) {
    // DevTools.
    steps.step("the user opens DevTools for the tab", |world, _, _| {
        panel(world)?.click(world, "browserDevTools")
    });
    steps.step("DevTools for that page show below it", |world, _, _| {
        devtools_shown(world, false)
    });
    steps.step("the user docks DevTools to the right", |world, _, _| {
        choose(world, "browserMore", "browserDevToolsDock")
    });
    steps.step("DevTools show beside the page", |world, _, _| {
        devtools_shown(world, true)
    });
    steps.step(
        "the next browser tab opens DevTools on the right",
        |world, _, _| {
            let dock = Settings::of(world.engine()).device_value("browserDevToolsDock");
            expect!(
                dock.as_ref().and_then(Json::as_str) == Some("right"),
                "the dock is not kept on this device: {dock:?}"
            );
            Ok(())
        },
    );

    // Mute.
    steps.step("the user mutes the tab from its menu", |world, _, _| {
        choose(world, "browserMore", "browserMuteItem")
    });
    steps.step(
        "the tab stays silent when its page starts playing sound",
        |world, _, _| {
            let brick = panel(world)?;
            let page = browser::page(world)?;
            let muted = view(world, brick).is_some_and(|v| read_flag(world, v, "audioMuted"));
            let page_muted = read_flag(world, page, "muted");
            expect!(muted && page_muted, "{}", state(world, brick));
            // The chrome says so, and unmutes.
            expect!(
                find(world, brick, "browserMute").is_some(),
                "the tab does not show it is muted"
            );
            Ok(())
        },
    );
    steps.step("a muted browser tab", |world, _, _| {
        show_tab(world, "/")?;
        choose(world, "browserMore", "browserMuteItem")
    });
    steps.step("the tab moves to another page", |world, _, _| {
        dev_server(world)?.page("/other", "Other", "");
        evaluate(world, "location.href = '/other'; true")?;
        wait_for_title(world, "Other")
    });
    steps.step("the tab is still muted", |world, _, _| {
        let brick = panel(world)?;
        let muted = view(world, brick).is_some_and(|v| read_flag(world, v, "audioMuted"));
        expect!(muted, "{}", state(world, brick));
        Ok(())
    });

    // Popups.
    steps.step(
        "a page in a browser tab starts a sign-in flow in a popup",
        |world, _, _| {
            sign_in_page(world)?;
            open_popup(world)
        },
    );
    steps.step(
        // TODO(ljos#390): Ljós's popup is a new page with no window.opener yet.
        "the popup opens as a real window that can report back to the page",
        |world, _, _| {
            let Some(window) = first_popup(world) else {
                fail!("no sign-in window");
            };
            let width = read_text(world, window, "width");
            let visible = read_flag(world, window, "visible");
            expect!(
                visible && width == "420",
                "the sign-in window is {width} wide, {}",
                if visible { "shown" } else { "hidden" }
            );
            let Some(popup) = popup_view(world, window) else {
                fail!("the popup has no page");
            };
            run_in(
                world,
                popup,
                "window.opener.postMessage('ada', '*'); window.close();",
            )?;
            wait_for_title(world, "Signed in as ada")?;
            wait_for_engine(
                world,
                |w| popup_count(w) == 0,
                |_| "the sign-in window to close itself".to_owned(),
            )
        },
    );
    steps.step(
        "the user follows a link on the page that targets a new window",
        |world, _, _| {
            sign_in_page(world)?;
            act(world, "document.getElementById('away').click();")
        },
    );
    steps.step("the page loads in the same browser tab", |world, _, _| {
        let away = server_url(world, "/away")?;
        wait_for_page(world, &away)?;
        let brick = panel(world)?;
        expect!(
            popup_count(world) == 0 && world.opened_urls().is_empty(),
            "{}",
            state(world, brick)
        );
        wait_for_engine(world, |w| first_tab_url(w) == away, describe)
    });
    steps.step(
        "a sign-in popup opened by a page in a browser tab",
        |world, _, _| {
            sign_in_page(world)?;
            open_popup(world)
        },
    );
    steps.step("the popup tries to open another popup", |world, _, _| {
        let Some(popup) = first_popup(world).and_then(|w| popup_view(world, w)) else {
            fail!("no sign-in window");
        };
        run_in(
            world,
            popup,
            "var w = window.open('/sign-in', 'more', 'width=300,height=300'); document.title = 'Asked';",
        )?;
        wait_for_engine(
            world,
            |w| read_text(w, popup, "title") == "Asked",
            |_| "the sign-in window to ask for another".to_owned(),
        )
    });
    steps.step("the second popup is refused", |world, _, _| {
        world.sync()?;
        let count = popup_count(world);
        expect!(count == 1, "{count} windows are open");
        let Some(window) = first_popup(world) else {
            fail!("no sign-in window");
        };
        let nested = world
            .engine()
            .children(window)
            .into_iter()
            .chain(popup_view(world, window).map_or_else(Vec::new, |v| world.engine().children(v)))
            .filter(|child| popup_view(world, *child).is_some())
            .count();
        expect!(nested == 0, "the sign-in window opened another");
        Ok(())
    });

    // The user's own browser.
    steps.step(
        "the user opens the page in the system browser from the tab's menu",
        |world, _, _| choose(world, "browserMore", "browserOpenExternal"),
    );
    steps.step(
        "the user's browser opens the page's address",
        |world, _, _| {
            let url = server_url(world, "/")?;
            wait_for_engine(
                world,
                |w| w.opened_urls() == vec![url.clone()],
                |w| format!("the browser opened {:?}", w.opened_urls()),
            )
        },
    );
}

/// Windows a page opens by itself, as desktop-qt's BrowserPermissionSteps.cpp.
fn register_windows(steps: &mut Steps) {
    fn open_window(world: &mut World, script: &str) -> Outcome {
        dev_server(world)?.page("/", "Dev server", ACT);
        show_tab(world, "/")?;
        act(world, script)
    }
    steps.step(&format!("the page opens a window at {Q}"), |world, c, _| {
        let address = c[0].replace('\\', "\\\\").replace('\'', "\\'");
        open_window(world, &format!("window.opened = window.open('{address}');"))
    });
    steps.step("the page opens a blank window", |world, _, _| {
        open_window(world, "window.opened = window.open();")
    });
    steps.step(
        "no tab or window opens and the page is told it was refused",
        |world, _, _| {
            // Each round trip lets the engine answer the page's request.
            let refused = (0..50).any(|_| {
                matches!(
                    evaluate(world, "!window.opened || window.opened.closed"),
                    Ok(Json::Bool(true))
                )
            });
            expect!(refused, "the page was not told its window was refused");
            world.sync()?;
            let windows = popup_count(world);
            expect!(windows == 0, "{windows} windows opened");
            let tabs = read(world, |p| p.count()).unwrap_or_default();
            expect!(tabs == 1, "the thread has {tabs} tabs");
            let opened = world.opened_urls();
            expect!(opened.is_empty(), "the system opened {opened:?}");
            Ok(())
        },
    );
    steps.step(
        "the page(?: and its address)? stays? as (?:it was|they were)",
        |world, _, _| {
            let home = server_url(world, "/")?;
            let seen = evaluated(world, "location.href + ' ' + document.title")?;
            expect!(seen == format!("{home} Dev server"), "the page is {seen}");
            let tab = first_tab_url(world);
            expect!(tab == home, "the MC's tab is at {tab}");
            Ok(())
        },
    );
}
