//! Agents driving this desktop's browser (features/preview/automation.feature),
//! as desktop-qt's PreviewAutomationSteps.cpp: the MC's broker is faked, and
//! the app's own host answers it. A real tab is driven by the page the app
//! attached for it; a held page stands for a tab whose scripts are answered
//! when a step says so.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use hal_c2_shell::controllers::preview_automation;
use hal_c2_shell::preview_automation::{
    AutomationPage, Changed, PreviewAutomationHost, ScriptDone,
};
use ljos::prelude::Engine;
use serde_json::{Value as Json, json};

use super::fake;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, text};
use crate::steps::stream::THREAD;
use crate::world::World;
use crate::{expect, fail};

/// A tab's page whose scripts wait until a step answers them.
#[derive(Default)]
struct HeldPage {
    at: RefCell<String>,
    scripts: RefCell<Vec<(String, Option<ScriptDone>)>>,
    loads: RefCell<Vec<String>>,
    /// What the host asked to be told when the page changes.
    changed: RefCell<Option<Changed>>,
}

impl HeldPage {
    fn ran(&self, name: &str) -> bool {
        let call = format!("(\"{name}\",");
        self.scripts
            .borrow()
            .iter()
            .any(|(source, _)| source.contains(&call))
    }

    /// How many times the page ran the script `name`.
    fn runs(&self, name: &str) -> usize {
        let call = format!("(\"{name}\",");
        self.scripts
            .borrow()
            .iter()
            .filter(|(source, _)| source.contains(&call))
            .count()
    }

    /// Answers the latest run of `name` still waiting with `answer`.
    fn answer(&self, engine: &Engine, name: &str, answer: &str) -> bool {
        let call = format!("(\"{name}\",");
        let done = self
            .scripts
            .borrow_mut()
            .iter_mut()
            .rev()
            .filter(|(source, _)| source.contains(&call))
            .find_map(|(_, done)| done.take());
        let Some(done) = done else { return false };
        done(engine, Some(answer.to_owned()));
        true
    }
}

impl AutomationPage for HeldPage {
    fn run_script(&self, _: &Engine, script: &str, done: ScriptDone) {
        self.scripts
            .borrow_mut()
            .push((script.to_owned(), Some(done)));
    }
    fn url(&self, _: &Engine) -> String {
        self.at.borrow().clone()
    }
    fn title(&self, _: &Engine) -> String {
        String::new()
    }
    fn loading(&self, _: &Engine) -> bool {
        false
    }
    fn load(&self, _: &Engine, url: &str) {
        self.loads.borrow_mut().push(url.to_owned());
        *self.at.borrow_mut() = url.to_owned();
    }
    fn dev_tools_open(&self, _: &Engine) -> bool {
        false
    }
    fn on_screen(&self, _: &Engine) -> bool {
        true
    }
    fn viewport(&self, _: &Engine) -> (i32, i32) {
        (1280, 800)
    }
    fn set_on_change(&self, _: &Engine, changed: Changed) {
        *self.changed.borrow_mut() = Some(changed);
    }
}

#[derive(Default)]
struct Automation {
    host: Option<PreviewAutomationHost>,
    held: Option<Rc<HeldPage>>,
    requests: usize,
    last: String,
    /// The browser tab an agent drives on a real page.
    driven: String,
    took_ms: u128,
    /// The condition an agent waits for on the held page.
    waiting_for: String,
}

const NOT_MET: &str = r#"{"ok":true,"value":false}"#;
const MET: &str = r#"{"ok":true,"value":true}"#;

fn held(world: &mut World) -> Outcome<Rc<HeldPage>> {
    match world.part::<Automation>().held.clone() {
        Some(page) => Ok(page),
        None => fail!("no held page"),
    }
}

/// Answers the page's look at the condition, once it has looked.
fn answer_look(world: &mut World, answer: &str) -> Outcome {
    let page = held(world)?;
    let waiting = page.clone();
    world.wait_for("the page to be looked at", move |_| {
        waiting
            .scripts
            .borrow()
            .iter()
            .any(|(source, done)| source.contains("(\"check\",") && done.is_some())
    })?;
    page.answer(world.engine(), "check", answer);
    world.pump()
}

const PASSWORD: &str = "s3cret-Passw0rd";
const PIN: &str = "4417-0096";

/// The thread's browser tab on the dev server's `path`, driven by agents.
fn drive_tab(world: &mut World, path: &str, title: &str, body: &str) -> Outcome {
    super::browser::dev_server(world)?.page(path, title, body);
    super::browser::show_tab(world, path)?;
    super::browser::wait_for_title(world, title)?;
    let tab = super::browser::browsing(world).tab_id.clone();
    // The app attaches the tab's page to its host on its own.
    let host = host(world)?;
    let attached = tab.clone();
    world.wait_for("the app to give its host the tab's page", move |_| {
        host.has_page(&attached)
    })?;
    world.part::<Automation>().driven = tab;
    Ok(())
}

fn error_of(answer: &Json) -> String {
    text(&answer["error"]["message"])
}

/// What the MC was answered, by request id.
#[derive(Default)]
struct Answers(HashMap<String, Json>);

fn extension(mc: &mut FakeMc) {
    // preview_automation.ex: a host is told its connection once it is offered.
    mc.on_shape("previewAutomation", |mc, id, _| {
        mc.send(&json!({"t": "previewAutomation", "id": id,
                        "event": {"type": "connected", "connectionId": "connection-1"}}));
        Ok(())
    });
    mc.on_rpc("previewAutomation.respond", |mc, rpc| {
        let id = text(&rpc.payload["requestId"]);
        mc.part::<Answers>().0.insert(id, rpc.payload.clone());
        mc.reply(rpc, Json::Null);
        Ok(())
    });
    // A host says whether its window has the focus once it is connected.
    mc.on_rpc("previewAutomation.focusHost", |mc, rpc| {
        mc.reply(rpc, Json::Null);
        Ok(())
    });
}

/// The app's host, once the MC connected it.
fn host(world: &mut World) -> Outcome<PreviewAutomationHost> {
    if let Some(host) = &world.part::<Automation>().host {
        return Ok(host.clone());
    }
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    }
    // The app's controllers, the host's among them, start on the MC's
    // first snapshot.
    world.wait_for("the app to start its browser host", |w| {
        preview_automation::host(w.engine()).is_some()
    })?;
    let Some(host) = preview_automation::host(world.engine()) else {
        fail!("the app has no browser host");
    };
    world.part::<Automation>().host = Some(host.clone());
    let name = world.mc.name.clone();
    let waiting = host.clone();
    world.wait_for("the MC to connect the app's browser host", move |_| {
        !waiting.connection_id(&name).is_empty()
    })?;
    Ok(host)
}

/// A held page for `tab` of the thread, at `at`.
fn held_page(world: &mut World, tab: &str, at: &str) -> Outcome<Rc<HeldPage>> {
    let host = host(world)?;
    let page = Rc::new(HeldPage::default());
    *page.at.borrow_mut() = at.to_owned();
    host.attach(world.engine(), THREAD, tab, page.clone());
    world.part::<Automation>().held = Some(page.clone());
    Ok(page)
}

fn ask(
    world: &mut World,
    operation: &str,
    input: Json,
    timeout_ms: i64,
    tab: &str,
) -> Outcome<String> {
    host(world)?;
    let state = world.part::<Automation>();
    state.requests += 1;
    let id = format!("request-{}", state.requests);
    state.last = id.clone();
    let request = json!({"requestId": id, "threadId": THREAD,
                         "tabId": if tab.is_empty() { Json::Null } else { json!(tab) },
                         "tabIdExplicit": !tab.is_empty(), "operation": operation,
                         "input": input, "timeoutMs": timeout_ms});
    let Some(&subscriber) = world.mc.subscribers("previewAutomation").last() else {
        fail!("the browser host is not subscribed");
    };
    world
        .mc
        .send(&json!({"t": "previewAutomation", "id": subscriber,
                          "event": {"type": "request", "connectionId": "connection-1",
                                    "request": request}}));
    world.pump()?;
    Ok(id)
}

fn answered(world: &mut World, id: &str) -> Option<Json> {
    world.mc.part::<Answers>().0.get(id).cloned()
}

fn answer(world: &mut World, id: &str) -> Outcome<Json> {
    let key = id.to_owned();
    world.wait_for_with(
        move |w| {
            w.mc.peek::<Answers>()
                .is_some_and(|a| a.0.contains_key(&key))
        },
        |w| {
            let answers =
                w.mc.peek::<Answers>()
                    .map(|a| a.0.keys().cloned().collect::<Vec<_>>());
            format!("an answer to {id}; answered {answers:?}")
        },
    )?;
    Ok(answered(world, id).unwrap_or_default())
}

fn opens(world: &mut World) -> usize {
    fake(&mut world.mc).opens.len()
}

/// Opens port `port` of the MC's environment, and stands a held page in for
/// the tab the MC made.
fn open_port(world: &mut World, port: i64, url: Option<&str>) -> Outcome {
    let mut input = json!({"target": {"kind": "environment-port", "port": port}});
    if let Some(url) = url {
        input["url"] = json!(url);
    }
    let before = opens(world);
    ask(world, "open", input, 15_000, "")?;
    world.wait_for("the browser to open a tab", move |w| {
        w.mc.peek::<super::FakePreviews>()
            .is_some_and(|f| f.opens.len() > before)
    })?;
    let (tab, at) = {
        let f = fake(&mut world.mc);
        (
            format!("tab-{}", f.tabs.len()),
            text(&f.opens.last().unwrap()["url"]),
        )
    };
    held_page(world, &tab, &at)?;
    let last = world.part::<Automation>().last.clone();
    answer(world, &last)?;
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Snapshots and passwords.
    steps.step(
        "an agent's current tab shows a sign-in form with a password typed in",
        |world, _, _| {
            let body = format!(
                "<form><label>Email <input id=email value=ada@example.com></label>\
                 <label>Password <input id=password type=password></label>\
                 <label>Code <input id=code style=\"-webkit-text-security: disc\"></label>\
                 <p>PIN <span id=pin style=\"-webkit-text-security: disc\">{PIN}</span></p>\
                 <button type=button>Sign in</button></form>"
            );
            drive_tab(world, "/sign-in", "Sign in", &body)?;
            super::browser::evaluate(
                world,
                &format!(
                    "document.getElementById('password').value = '{PASSWORD}'; \
                     document.getElementById('code').value = '{PASSWORD}'; true"
                ),
            )?;
            Ok(())
        },
    );
    steps.step(
        "an agent's current tab shows a password field whose value changes while the snapshot is taken",
        |world, _, _| {
            drive_tab(
                world,
                "/busy",
                "Busy",
                "<input id=password type=password><script>var n = 0; setInterval(function () { \
                 document.getElementById('password').value = 'p' + (n++); }, 1);</script>",
            )
        },
    );
    steps.step("the agent takes a snapshot", |world, _, _| {
        let tab = world.part::<Automation>().driven.clone();
        let started = std::time::Instant::now();
        let id = ask(world, "snapshot", json!({}), 30_000, &tab)?;
        // A busy page is read three times, each with three tries at its
        // picture: longer than one wait, within the request's own 30 s. The
        // deadline is wall time checked every pass: a wait charges a slow pass
        // only a slice of its time, so one busy enough would outlast the
        // runner's hang limit before a plain wait gave up.
        let key = id.clone();
        while answered(world, &id).is_none() {
            if started.elapsed().as_secs() >= 30 {
                fail!("no answer to {id} within 30 s");
            }
            let key = key.clone();
            // Only a wait running out goes round again; a pump's own
            // failure is the step's.
            if let Err(e) = world.wait_for_with(
                move |w| {
                    started.elapsed().as_secs() >= 30
                        || w.mc
                            .peek::<Answers>()
                            .is_some_and(|a| a.0.contains_key(&key))
                },
                |_| "an answer to the snapshot".to_owned(),
            ) && !e.0.starts_with("timed out waiting for ")
            {
                return Err(e);
            }
        }
        world.part::<Automation>().took_ms = started.elapsed().as_millis();
        Ok(())
    });
    steps.step(
        "the snapshot shows the password field with its value masked",
        |world, _, _| {
            let id = world.part::<Automation>().last.clone();
            let snapshot = answer(world, &id)?;
            expect!(
                snapshot["ok"] == json!(true),
                "the snapshot failed: {snapshot}"
            );
            let elements = &snapshot["result"]["interactiveElements"];
            let listed = elements.as_array().is_some_and(|all| {
                all.iter()
                    .any(|e| e["selector"] == "#password" && e["name"] == "Password")
            });
            expect!(listed, "the password field is not listed: {elements}");
            Ok(())
        },
    );
    steps.step(
        "the password appears nowhere in the page text, including fields drawn as dots",
        |world, _, _| {
            let id = world.part::<Automation>().last.clone();
            let mut result = answer(world, &id)?["result"].take();
            if let Some(fields) = result.as_object_mut() {
                fields.remove("screenshot");
            }
            let said = result.to_string();
            expect!(
                !said.contains(PASSWORD) && !said.contains(PIN),
                "the snapshot says {}",
                said.chars().take(2000).collect::<String>()
            );
            // What else the page says is still there.
            let visible = text(&result["visibleText"]);
            expect!(
                visible.contains("PIN") && visible.contains('\u{2022}'),
                "the page text is {visible}"
            );
            Ok(())
        },
    );
    steps.step(
        "the tool fails saying the page was too busy to read safely",
        |world, _, _| {
            let id = world.part::<Automation>().last.clone();
            let snapshot = answer(world, &id)?;
            expect!(
                snapshot["ok"] == json!(false)
                    && error_of(&snapshot).contains("too busy to read safely"),
                "the snapshot answered {snapshot}"
            );
            Ok(())
        },
    );
    steps.step(r"it answers within (\d+) seconds", |world, captures, _| {
        let took = world.part::<Automation>().took_ms;
        let limit: u128 = captures[0].parse().unwrap_or(0);
        expect!(took < limit * 1000, "it answered after {took}ms");
        Ok(())
    });

    steps.step(
        "an agent's click is queued behind another action in the same browser",
        |world, _, _| {
            let page = held_page(world, "tab-1", "http://localhost:5173/")?;
            ask(
                world,
                "evaluate",
                json!({"expression": "1"}),
                15_000,
                "tab-1",
            )?;
            world.wait_for("the first action to reach the page", move |_| {
                page.scripts.borrow().len() == 1
            })?;
            ask(world, "click", json!({"selector": "#buy"}), 600, "tab-1")?;
            Ok(())
        },
    );
    steps.step(
        "the click's time limit passes before its turn comes",
        |world, _, _| {
            let click = answer(world, "request-2")?;
            let error = click["error"].to_string();
            expect!(
                click["ok"] == false && error.contains("PreviewAutomationTimeoutError"),
                "the click was answered {click}"
            );
            // Then the action ahead of it finishes.
            let page = world
                .part::<Automation>()
                .held
                .clone()
                .expect("a held page");
            let done = page.scripts.borrow_mut()[0].1.take();
            if let Some(done) = done {
                done(
                    world.engine(),
                    Some(r#"{"done":true,"value":"1"}"#.to_owned()),
                );
            }
            answer(world, "request-1")?;
            world.sync()
        },
    );
    steps.step("the click is never performed", |world, _, _| {
        let page = world
            .part::<Automation>()
            .held
            .clone()
            .expect("a held page");
        let scripts = page.scripts.borrow().len();
        expect!(
            scripts == 1 && !page.ran("clickTarget"),
            "the page ran {scripts} scripts"
        );
        Ok(())
    });

    // A wait for a condition: looked at once, then each time the page
    // changes, until it is met or its deadline.
    steps.step(
        &format!(r"an agent waits up to (\d+) seconds for {Q} on a page that does not show it"),
        |world, c, _| {
            let seconds: i64 = c[0].parse().unwrap_or(0);
            held_page(world, "tab-1", "http://localhost:5173/")?;
            world.part::<Automation>().waiting_for = c[1].clone();
            ask(
                world,
                "waitFor",
                json!({"selector": c[1], "timeoutMs": seconds * 1000}),
                (seconds + 30) * 1000,
                "tab-1",
            )?;
            answer_look(world, NOT_MET)
        },
    );
    steps.step(
        r"(\d+) seconds pass and nothing on the page changes",
        |world, c, _| {
            let seconds: u64 = c[0].parse().unwrap_or(0);
            world.advance(seconds * 1000)?;
            world.pump()
        },
    );
    steps.step("the page was looked at once", |world, _, _| {
        let looks = held(world)?.runs("check");
        expect!(looks == 1, "the page was looked at {looks} times");
        Ok(())
    });
    steps.step(
        &format!("the page changes and now shows {Q}"),
        |world, c, _| {
            let wanted = world.part::<Automation>().waiting_for.clone();
            expect!(c[0] == wanted, "the agent waits for {wanted:?}");
            let page = held(world)?;
            let changed = page.changed.borrow().clone();
            let Some(changed) = changed else {
                fail!("the host never asked to hear of the page's changes");
            };
            changed(world.engine());
            // At most a frame after the last look.
            world.advance(16)?;
            world.pump()?;
            answer_look(world, MET)
        },
    );
    steps.step("the wait succeeds before its deadline", |world, _, _| {
        let last = world.part::<Automation>().last.clone();
        let waited = answer(world, &last)?;
        expect!(waited["ok"] == true, "the wait was answered {waited}");
        let looks = held(world)?.runs("check");
        expect!(looks == 2, "the page was looked at {looks} times");
        Ok(())
    });
    steps.step(
        r"the wait fails because the condition did not match within (\d+)ms",
        |world, c, _| {
            let last = world.part::<Automation>().last.clone();
            let waited = answer(world, &last)?;
            let said = format!("did not match within {}ms", &c[0]);
            expect!(
                waited["ok"] == false && error_of(&waited).contains(&said),
                "the wait was answered {waited}"
            );
            Ok(())
        },
    );

    steps.step(
        r"an agent opens a preview of port (\d+) in its environment",
        |world, c, _| open_port(world, c[0].parse().unwrap_or(0), None),
    );
    steps.step(
        r#"an agent opens a preview of port (\d+) in its environment and also gives the address "([^"]*)""#,
        |world, c, _| open_port(world, c[0].parse().unwrap_or(0), Some(&c[1])),
    );
    steps.step(
        r"the tab opens on that environment's port (\d+)",
        |world, c, _| {
            let last = world.part::<Automation>().last.clone();
            let opened = answer(world, &last)?;
            let url = text(&opened["result"]["url"]);
            let wanted = format!("http://localhost:{}/", &c[0]);
            expect!(
                opened["ok"] == true && url == wanted,
                "the open was answered {opened}"
            );
            let asked = fake(&mut world.mc)
                .opens
                .last()
                .map(|o| text(&o["url"]))
                .unwrap_or_default();
            expect!(asked == wanted, "the tab was opened at {asked:?}");
            Ok(())
        },
    );
    steps.step("the agent did not have to navigate the tab afterwards", |world, _, _| {
        let requests = world.part::<Automation>().requests;
        let navigations = fake(&mut world.mc).navigations.len();
        let loads = world.part::<Automation>().held.as_ref().map_or(0, |p| p.loads.borrow().len());
        expect!(
            requests == 1 && navigations == 0 && loads == 0,
            "the agent asked {requests} times, the tab navigated {navigations} times and loaded {loads}"
        );
        Ok(())
    });
}
