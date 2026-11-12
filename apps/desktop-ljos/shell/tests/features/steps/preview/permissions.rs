//! What a page in a browser tab may ask for: permissions, the clipboard,
//! notifications and links to other apps (BrowserPanel's handlers and
//! `Browser.permissions`), against the loopback dev server, as desktop-qt's
//! BrowserPermissionSteps.cpp. features/preview/surfaces.feature.
//!
//! The page asks from a click, as a page does: the dev server's /ask page is
//! one button over the whole page, and clicking it runs `window.act`. What
//! the page learnt comes back in its title, "result:<what>".
//!
//! Chromium runs on its own clipboard here (main.rs puts it on Ozone's
//! headless platform), so the page copies the text it then reads: the
//! user's own clipboard is never touched.

use hal_c2_shell::browser::{self, permissions::Question};
use serde_json::{Value as Json, json};

use super::browser::{
    dev_server, evaluate, evaluated, panel, read_flag, read_text, server_url, show_tab, state,
    view, view_url, wait_for_engine, wait_for_page,
};
use super::navigation::act;
use crate::harness::{Outcome, Q, Steps};
use crate::steps::alert::{
    await_system_notifications, completes_in_background, system_notifications,
};
use crate::world::World;
use crate::{expect, fail};

/// The scenario's asks so far.
#[derive(Default)]
struct Asking {
    shown: bool,
    /// The outside link the page follows.
    link: String,
}

fn asking(world: &mut World) -> &mut Asking {
    world.mc.part::<Asking>()
}

const ASK: &str = "<button id=ask style=\"position:fixed;left:0;top:0;width:100vw;height:100vh;opacity:0.5\" \
     onclick=\"window.act && window.act()\">Ask</button>\
     <script>function done(what) { document.title = 'result:' + what; }\
     var kRefusedMedia = /^(AbortError|NotAllowedError)$/;</script>";

/// The sites the ledger names, as origins of the dev server: one name each
/// for the loopback.
fn host_for(site: &str) -> Outcome<&'static str> {
    match site {
        "https://example.com" => Ok("localhost"),
        "https://other.example" => Ok("127.0.0.1"),
        _ => fail!("no stand-in for the site {site}"),
    }
}

fn ask_url(world: &mut World, host: &str) -> Outcome<String> {
    Ok(server_url(world, "/ask")?.replace("localhost", host))
}

/// The thread's browser tab on the /ask page of `host`.
fn show_ask(world: &mut World, host: &str) -> Outcome {
    dev_server(world)?.page("/ask", "Ask", ASK);
    if !asking(world).shown {
        show_tab(world, "/ask")?;
        asking(world).shown = true;
    }
    let url = ask_url(world, host)?;
    if evaluated(world, "location.href")? == url {
        return Ok(());
    }
    evaluate(world, &format!("location.href = '{url}'; true"))?;
    wait_for_page(world, &url)
}

/// The page runs `script` from the user's click; `done(what)` reports what
/// it learnt.
fn ask(world: &mut World, script: &str) -> Outcome {
    evaluate(world, "document.title = 'asking'; true")?;
    act(world, script)
}

/// What the page learnt from its last ask.
fn result(world: &mut World) -> Outcome<String> {
    let mut seen = String::new();
    for _ in 0..4 {
        let brick = panel(world)?;
        let got = wait_for_engine(
            world,
            |w| view(w, brick).is_some_and(|v| read_text(w, v, "title").starts_with("result:")),
            |_| String::new(),
        );
        if got.is_ok() {
            break;
        }
    }
    let brick = panel(world)?;
    if let Some(v) = view(world, brick) {
        seen = read_text(world, v, "title");
    }
    match seen.strip_prefix("result:") {
        Some(learnt) => Ok(learnt.to_owned()),
        None => fail!(
            "the page did not learn its answer; it says {seen:?} ({})",
            evaluated(world, "String(window.why)").unwrap_or_default()
        ),
    }
}

/// The question on screen, as `Browser.permissions` puts it.
fn question(world: &World) -> Option<Question> {
    browser::update_permissions(world.engine(), |p| p.question().cloned()).flatten()
}

fn question_kind(world: &World) -> String {
    question(world).map_or(String::new(), |q| q.kind.to_owned())
}

fn question_shown(world: &mut World) -> Outcome<bool> {
    let brick = panel(world)?;
    Ok(brick
        .find_visible(world, "browserQuestion")
        .ok()
        .flatten()
        .is_some())
}

fn question_text(world: &mut World) -> String {
    let Ok(brick) = panel(world) else {
        return String::new();
    };
    brick
        .find_visible(world, "browserQuestionText")
        .ok()
        .flatten()
        .map_or(String::new(), |t| read_text(world, t, "text"))
}

fn wait_for_question(world: &mut World) -> Outcome {
    let brick = panel(world)?;
    wait_for_engine(
        world,
        |w| {
            brick
                .find_visible(w, "browserQuestion")
                .ok()
                .flatten()
                .is_some()
        },
        |w| format!("a question; {}", state(w, brick)),
    )
}

/// The page's work after its last ask has been seen through: a round trip
/// to it.
fn settle(world: &mut World) -> Outcome {
    evaluate(world, "true")?;
    world.sync()
}

fn expect_no_question(world: &mut World) -> Outcome {
    settle(world)?;
    let shown = question_shown(world)?;
    expect!(!shown, "the user was asked {:?}", question_text(world));
    Ok(())
}

// TODO(ljos#407): Chromium refuses the read, and geolocation, without
// asking the view, so the scenarios that read the clipboard fail.
/// Copies text from the page, then reads the clipboard back. The copy needs
/// no asking; the read does.
const READ_CLIPBOARD: &str = "navigator.clipboard.writeText('copied text').then(function () {\
     return navigator.clipboard.readText(); }).then(function (t) { done('read ' + t); },\
     function (e) { window.why = e.message; done('nothing'); });";

fn ask_to_read(world: &mut World) -> Outcome {
    ask(world, READ_CLIPBOARD)
}

fn follow_link(world: &mut World, link: &str) -> Outcome {
    asking(world).link = link.to_owned();
    ask(world, &format!("location.href = '{link}';"))
}

/// How each thing a page can ask for is asked for, and how the page learns
/// the answer.
fn ask_for(what: &str) -> Option<&'static str> {
    Some(match what {
        "to put text on the clipboard" => {
            "navigator.clipboard.writeText('hi').then(function () { done('allowed'); }, function (e) { done('refused'); });"
        }
        "to show notifications" => {
            "Notification.requestPermission().then(function (r) { done(r === 'granted' ? 'allowed' : 'refused'); });"
        }
        "the user's location" => {
            "navigator.geolocation.getCurrentPosition(function () { done('allowed'); },\
             function (e) { done(e.code === e.PERMISSION_DENIED ? 'refused' : 'allowed'); }, {timeout: 3000});"
        }
        "the camera" => {
            "navigator.mediaDevices.getUserMedia({video: true}).then(function (s) { s.getTracks().forEach(function (t) { t.stop(); }); done('allowed'); },\
             function (e) { done(kRefusedMedia.test(e.name) ? 'refused' : 'allowed, but ' + e.name); });"
        }
        "the microphone" => {
            "navigator.mediaDevices.getUserMedia({audio: true}).then(function (s) { s.getTracks().forEach(function (t) { t.stop(); }); done('allowed'); },\
             function (e) { done(kRefusedMedia.test(e.name) ? 'refused' : 'allowed, but ' + e.name); });"
        }
        "the list of installed fonts" => {
            "window.queryLocalFonts().then(function (fonts) { done(fonts.length ? 'allowed' : 'refused'); }, function () { done('refused'); });"
        }
        "to lock the mouse pointer" => {
            "document.onpointerlockchange = function () { if (document.pointerLockElement) { document.exitPointerLock(); done('allowed'); } };\
             document.onpointerlockerror = function () { done('refused'); };\
             try { var locked = document.body.requestPointerLock(); if (locked && locked.catch) locked.catch(function () { done('refused'); }); }\
             catch (e) { done('refused'); }"
        }
        "anything else a page can ask for" => {
            "navigator.mediaDevices.getDisplayMedia({video: true}).then(function (s) { s.getTracks().forEach(function (t) { t.stop(); }); done('allowed'); },\
             function () { done('refused'); });"
        }
        _ => return None,
    })
}

fn opened(world: &World) -> Vec<String> {
    world.opened_urls()
}

fn click(world: &mut World, name: &str) -> Outcome {
    panel(world)?.click(world, name)?;
    world.sync()
}

pub fn register(steps: &mut Steps) {
    // Permissions.
    steps.step("a page in a browser tab asks for (.+)", |world, c, _| {
        let Some(script) = ask_for(&c[0]) else {
            fail!("no way to ask for {}", c[0]);
        };
        show_ask(world, "localhost")?;
        ask(world, script)
    });
    steps.step("the request is (allowed|refused)", |world, c, _| {
        let learnt = result(world)?;
        expect!(learnt == c[0], "the request was {learnt}");
        let shown = question_shown(world)?;
        expect!(!shown, "the user was asked {:?}", question_text(world));
        Ok(())
    });

    // The clipboard.
    steps.step(
        &format!("a page from {Q}(?: in a browser tab)? asks to read the clipboard"),
        |world, c, _| {
            show_ask(world, host_for(&c[0])?)?;
            ask_to_read(world)
        },
    );
    steps.step(
        &format!("the user is asked (?:whether|about) {Q}(?: may see what was copied)?"),
        |world, c, _| {
            if wait_for_question(world).is_err() {
                fail!(
                    "the user was not asked; the page heard {:?}",
                    evaluated(world, "String(window.why)").unwrap_or_default()
                );
            }
            let host = host_for(&c[0])?;
            let text = question_text(world);
            expect!(
                question_kind(world) == "clipboard" && text.contains(host),
                "the user was asked {text:?}"
            );
            Ok(())
        },
    );
    steps.step("the user (allows|blocks) it", |world, c, _| {
        click(
            world,
            if &c[0] == "allows" {
                "browserQuestionAllow"
            } else {
                "browserQuestionRefuse"
            },
        )
    });
    steps.step(
        "the page (reads the clipboard|gets nothing)",
        |world, c, _| {
            let learnt = result(world)?;
            let wanted = if &c[0] == "gets nothing" {
                "nothing"
            } else {
                "read copied text"
            };
            expect!(learnt == wanted, "the page learnt {learnt}");
            let shown = question_shown(world)?;
            expect!(!shown, "the question is still up");
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is not asked again while the browser stays open"),
        |world, _, _| {
            let first = result(world)?;
            ask_to_read(world)?;
            let again = result(world)?;
            expect!(
                again == first,
                "the page learnt {again} the second time, {first} the first"
            );
            expect_no_question(world)
        },
    );
    steps.step(
        &format!("the user allowed {Q} to read the clipboard"),
        |world, c, _| {
            show_ask(world, host_for(&c[0])?)?;
            ask_to_read(world)?;
            wait_for_question(world)?;
            click(world, "browserQuestionAllow")?;
            let learnt = result(world)?;
            expect!(
                learnt == "read copied text",
                "the page could not read the clipboard: {learnt}"
            );
            Ok(())
        },
    );

    // A prompt's default.
    steps.step(
        "a page asks to (read the clipboard|open an outside link)",
        |world, c, _| {
            show_ask(world, "localhost")?;
            if &c[0] == "read the clipboard" {
                ask_to_read(world)?;
            } else {
                follow_link(world, "slack://channel?team=T1")?;
            }
            wait_for_question(world)
        },
    );
    steps.step("the prompt's default choice refuses it", |world, _, _| {
        let link = question_kind(world) == "link";
        let brick = panel(world)?;
        let refuse = brick.item(world, "browserQuestionRefuse")?;
        world.wait_for_with(
            |w| read_flag(w, refuse, "activeFocus"),
            |_| "the refusing choice to have the keyboard".to_owned(),
        )?;
        let pressed = brick.press(world, "enter")?;
        expect!(pressed, "Enter went nowhere");
        world.sync()?;
        let shown = question_shown(world)?;
        expect!(!shown, "Enter did not answer the question");
        if link {
            settle(world)?;
            let opened = opened(world);
            expect!(opened.is_empty(), "the system opened {opened:?}");
        } else {
            let learnt = result(world)?;
            expect!(learnt == "nothing", "the page read the clipboard: {learnt}");
        }
        Ok(())
    });
    steps.step(
        "a request that arrives while another prompt is open is refused without being remembered",
        |world, _, _| {
            // Another site, so the answer just given is not the one that
            // counts.
            show_ask(world, "127.0.0.1")?;
            follow_link(world, "slack://channel?team=T2")?;
            wait_for_question(world)?;
            ask_to_read(world)?;
            let learnt = result(world)?;
            expect!(
                learnt == "nothing",
                "the page read the clipboard behind the question: {learnt}"
            );
            expect!(
                question_kind(world) == "link",
                "the question on screen changed"
            );
            click(world, "browserQuestionRefuse")?;
            ask_to_read(world)?;
            wait_for_question(world)?;
            expect!(
                question_kind(world) == "clipboard",
                "the site was not asked about the clipboard"
            );
            Ok(())
        },
    );

    // Notifications.
    steps.step(
        "a page in a browser tab asks to show notifications",
        |world, _, _| {
            await_system_notifications(world)?;
            show_ask(world, "localhost")?;
            ask(world, ask_for("to show notifications").expect("listed"))?;
            let learnt = result(world)?;
            expect!(learnt == "refused", "the page may show notifications");
            Ok(())
        },
    );
    steps.step(
        "the page tries to raise a system notification",
        |world, _, _| {
            ask(
                world,
                "var n = new Notification('Prize', {body: 'Claim it'}); n.onshow = function () { done('shown'); };\
                 n.onerror = function () { done('refused'); };",
            )?;
            let learnt = result(world)?;
            expect!(learnt == "refused", "the page's notification was {learnt}");
            Ok(())
        },
    );
    steps.step("no system notification appears", |world, _, _| {
        world.sync()?;
        let told = system_notifications(world);
        expect!(told.is_empty(), "notifications appeared for {told:?}");
        Ok(())
    });
    steps.step(
        "the app's own notifications, such as a finished turn, still appear",
        |world, _, _| {
            completes_in_background(world, "Tax fix")?;
            world.sync()?;
            let told = system_notifications(world);
            expect!(told.len() == 1, "{} notifications appeared", told.len());
            Ok(())
        },
    );

    // Links to other apps.
    steps.step(
        &format!("a page in a browser tab follows the link {Q}"),
        |world, c, _| {
            show_ask(world, "localhost")?;
            follow_link(world, &c[0])
        },
    );
    steps.step(
        "the user is asked whether to open this (\\w+) link",
        |world, c, _| {
            wait_for_question(world)?;
            let text = question_text(world);
            expect!(
                question_kind(world) == "link" && text.contains(&c[0]),
                "the user was asked {text:?}"
            );
            Ok(())
        },
    );
    steps.step(
        "the link opens in the system only if the user agrees",
        |world, _, _| {
            settle(world)?;
            let early = opened(world);
            expect!(
                early.is_empty(),
                "the system opened {early:?} before the user agreed"
            );
            click(world, "browserQuestionAllow")?;
            let link = asking(world).link.clone();
            let opened = opened(world);
            expect!(opened == [link], "the system opened {opened:?}");
            Ok(())
        },
    );
    steps.step(
        "a second such link waits until the first question is answered",
        |world, _, _| {
            let before = opened(world).len();
            follow_link(world, "slack://channel?team=T2")?;
            wait_for_question(world)?;
            follow_link(world, "slack://channel?team=T3")?;
            settle(world)?;
            let asked = question(world).map_or(String::new(), |q| q.url);
            expect!(
                asked == "slack://channel?team=T2",
                "the user is asked about {asked}"
            );
            click(world, "browserQuestionRefuse")?;
            wait_for_question(world)?;
            let asked = question(world).map_or(String::new(), |q| q.url);
            expect!(
                asked == "slack://channel?team=T3",
                "the second link was not asked about; {asked}"
            );
            click(world, "browserQuestionAllow")?;
            let opened = opened(world)[before..].to_vec();
            expect!(
                opened == ["slack://channel?team=T3"],
                "the system opened {opened:?}"
            );
            Ok(())
        },
    );

    // A tab that is not shown.
    steps.step(
        "the question is withdrawn and the link does not open",
        |world, _, _| {
            world.wait_for_with(
                |w| question(w).is_none(),
                |w| {
                    format!(
                        "the question to go; it asks about {}",
                        question(w).map_or(String::new(), |q| q.url)
                    )
                },
            )?;
            settle(world)?;
            let opened = opened(world);
            expect!(opened.is_empty(), "the system opened {opened:?}");
            Ok(())
        },
    );
    steps.step(
        &format!("the page in the hidden tab follows the link {Q}"),
        |world, c, _| {
            let brick = panel(world)?;
            expect!(
                view(world, brick).is_none(),
                "the browser tab still shows"
            );
            // No click reaches a hidden page: its script moves it.
            evaluate(
                world,
                &format!(
                    "window.followed = false; setTimeout(function () {{ window.followed = true; location.href = '{}'; }}, 0); true",
                    c[0]
                ),
            )?;
            let followed = (0..50)
                .any(|_| matches!(evaluate(world, "window.followed"), Ok(Json::Bool(true))));
            expect!(followed, "the hidden page did not follow the link");
            Ok(())
        },
    );
    steps.step(
        "the user is not asked about it and the system is not asked to open it",
        |world, _, _| {
            settle(world)?;
            let asked = question(world);
            expect!(
                asked.is_none(),
                "the user is asked about {}",
                asked.map_or(String::new(), |q| q.url)
            );
            let opened = opened(world);
            expect!(opened.is_empty(), "the system opened {opened:?}");
            Ok(())
        },
    );
    steps.step(
        "the user switches back to the browser tab",
        |world, _, _| {
            let tabs = world.state("panel")["tabs"].clone();
            let browser = tabs
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|t| t["id"].as_str())
                .find(|id| id.starts_with("browser:"))
                .map(str::to_owned);
            let Some(browser) = browser else {
                fail!("no browser tab in the panel");
            };
            world.dispatch("rightPanel.activate", json!({"id": browser}))?;
            world.sync()?;
            let brick = panel(world)?;
            wait_for_engine(
                world,
                |w| view(w, brick).is_some() && !view_url(w, brick).is_empty(),
                |w| format!("the browser tab to show; {}", state(w, brick)),
            )
        },
    );
    steps.step(
        &format!("a page in a browser tab follows a link with the scheme {Q} to another app"),
        |world, c, _| {
            let script = match c[0].as_str() {
                "file" => "location.href = 'file:///etc/hosts';",
                "javascript" => "location.href = 'javascript:void(0)';",
                "data" => "location.href = 'data:text/plain,hi';",
                "blob" => {
                    "location.href = URL.createObjectURL(new Blob(['hi'], {type: 'text/plain'}));"
                }
                other => fail!("no link with the scheme {other}"),
            };
            show_ask(world, "localhost")?;
            ask(world, script)
        },
    );
    steps.step("the system is not asked to open it", |world, _, _| {
        expect_no_question(world)?;
        let opened = opened(world);
        expect!(opened.is_empty(), "the system opened {opened:?}");
        Ok(())
    });
}
