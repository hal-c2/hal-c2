//! Agents driving this desktop's browser (features/preview/automation.feature),
//! as desktop-qt's PreviewAutomationSteps.cpp: the MC's broker is faked, and
//! a held page stands for the tab, its scripts answered when a step says so.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use hal_c2_shell::browser::BrowserPage;
use hal_c2_shell::controller;
use hal_c2_shell::preview_automation::{
    AutomationPage, GrabDone, PreviewAutomationHost, ScriptDone,
};
use ljos::ObjectId;
use ljos::prelude::{Engine, Value};
use serde_json::{Value as Json, json};

use super::fake;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Steps, text};
use crate::steps::stream::THREAD;
use crate::world::World;
use crate::{expect, fail};

/// A tab's page whose scripts wait until a step answers them.
#[derive(Default)]
struct HeldPage {
    at: RefCell<String>,
    scripts: RefCell<Vec<(String, Option<ScriptDone>)>>,
    loads: RefCell<Vec<String>>,
}

impl HeldPage {
    fn ran(&self, name: &str) -> bool {
        let call = format!("(\"{name}\",");
        self.scripts
            .borrow()
            .iter()
            .any(|(source, _)| source.contains(&call))
    }
}

impl AutomationPage for HeldPage {
    fn run_script(&self, _: &Engine, script: &str, done: ScriptDone) {
        self.scripts
            .borrow_mut()
            .push((script.to_owned(), Some(done)));
    }
    fn url(&self) -> String {
        self.at.borrow().clone()
    }
    fn title(&self) -> String {
        String::new()
    }
    fn loading(&self) -> bool {
        false
    }
    fn load(&self, url: &str) {
        self.loads.borrow_mut().push(url.to_owned());
        *self.at.borrow_mut() = url.to_owned();
    }
    fn dev_tools_open(&self) -> bool {
        false
    }
    fn on_screen(&self) -> bool {
        true
    }
    fn viewport(&self) -> (i32, i32) {
        (1280, 800)
    }
}

/// A browser tab's real page, driven as the desktop's would be.
struct ViewPage {
    page: ObjectId,
    at: String,
}

fn script_text(value: Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.to_string()),
        _ => None,
    }
}

impl AutomationPage for ViewPage {
    fn run_script(&self, engine: &Engine, script: &str, done: ScriptDone) {
        BrowserPage::evaluate(engine, self.page, script, 0, move |e, v| {
            done(e, script_text(v))
        });
    }
    fn run_isolated(&self, engine: &Engine, script: &str, done: ScriptDone) {
        BrowserPage::evaluate(engine, self.page, script, 1, move |e, v| {
            done(e, script_text(v))
        });
    }
    fn grab(&self, engine: &Engine, done: GrabDone) {
        BrowserPage::grab_png(engine, self.page, done);
    }
    fn url(&self) -> String {
        self.at.clone()
    }
    fn title(&self) -> String {
        String::new()
    }
    fn loading(&self) -> bool {
        false
    }
    fn load(&self, _: &str) {}
    fn dev_tools_open(&self) -> bool {
        false
    }
    fn on_screen(&self) -> bool {
        true
    }
    fn viewport(&self) -> (i32, i32) {
        (1280, 800)
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
}

const PASSWORD: &str = "s3cret-Passw0rd";
const PIN: &str = "4417-0096";

/// The thread's browser tab on the dev server's `path`, driven by agents.
fn drive_tab(world: &mut World, path: &str, title: &str, body: &str) -> Outcome {
    super::browser::dev_server(world)?.page(path, title, body);
    super::browser::show_tab(world, path)?;
    super::browser::wait_for_title(world, title)?;
    let page = super::browser::page(world)?;
    let tab = super::browser::browsing(world).tab_id.clone();
    let at = super::browser::server_url(world, path)?;
    let host = host(world)?;
    host.attach(world.engine(), THREAD, &tab, Rc::new(ViewPage { page, at }));
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
}

fn host(world: &mut World) -> Outcome<PreviewAutomationHost> {
    if let Some(host) = &world.part::<Automation>().host {
        return Ok(host.clone());
    }
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    }
    let Some(mc) = controller::mc(world.engine()) else {
        fail!("the shell has no MC");
    };
    let host = PreviewAutomationHost::new(mc, "desktop-test");
    host.set_mcs(&[(world.mc.name.clone(), world.mc.environment_id.clone())]);
    world.part::<Automation>().host = Some(host.clone());
    let name = world.mc.name.clone();
    let waiting = host.clone();
    world.wait_for("the MC to connect the browser host", move |_| {
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
        // picture: longer than one wait, within the request's own 30 s.
        while let Err(waiting) = answer(world, &id) {
            if started.elapsed().as_secs() >= 30 {
                return Err(waiting);
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
