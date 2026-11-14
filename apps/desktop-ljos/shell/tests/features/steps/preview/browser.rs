//! The in-app browser (BrowserPanel on Ljós's QtWebEngine, CEF): a thread's
//! browser tab drawn beside it, against a dev server this file serves on the
//! loopback, as desktop-qt's BrowserSteps.cpp.
//! features/preview/surfaces.feature's "The desktop shows the page beside the
//! thread".

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use hal_c2_shell::browser::{self, BrowserPage};
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::json;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use super::{describe, emit_event, fake, read, show_previews, update};
use crate::brick::{self, Brick, Shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

// --- The dev server ---------------------------------------------------------------------

/// What the dev server answers, shared with the thread that serves it.
#[derive(Default)]
struct Served {
    pages: HashMap<String, Vec<u8>>,
    redirects: HashMap<String, String>,
    unfinished: HashMap<String, Vec<u8>>,
    holding: bool,
    /// One path held while the others are answered, when set.
    holding_path: Option<String>,
    held: Vec<(TcpStream, String)>,
    requests: usize,
    /// The path of each request, in order.
    paths: Vec<String>,
}

/// A dev server on the loopback: each path's page, answered and closed.
pub struct DevServer {
    served: Arc<Mutex<Served>>,
    port: u16,
    listener: Option<Arc<TcpListener>>,
}

impl DevServer {
    fn new() -> DevServer {
        DevServer {
            served: Arc::default(),
            port: 0,
            listener: None,
        }
    }

    /// Listens on its port (any free one at first); false when it is taken.
    pub fn listen(&mut self) -> bool {
        if self.listener.is_some() {
            return true;
        }
        // After stop() the accept thread lets go of the old port as soon as
        // the wake-up connection reaches it, which may be a moment later.
        let bound = (0..100).find_map(|attempt| {
            if attempt > 0 {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            TcpListener::bind(("127.0.0.1", self.port)).ok()
        });
        let Some(listener) = bound else {
            return false;
        };
        self.port = listener.local_addr().map_or(0, |a| a.port());
        let listener = Arc::new(listener);
        let (accepting, served) = (listener.clone(), self.served.clone());
        std::thread::spawn(move || {
            for stream in accepting.incoming() {
                let Ok(stream) = stream else { break };
                // stop() wakes the loop with a connection of its own.
                if Arc::strong_count(&accepting) == 1 {
                    break;
                }
                let served = served.clone();
                std::thread::spawn(move || serve(stream, &served));
            }
        });
        self.listener = Some(listener);
        true
    }

    /// Stops listening: the next request is refused.
    pub fn stop(&mut self) {
        if self.listener.take().is_some() {
            let _ = TcpStream::connect(("127.0.0.1", self.port));
        }
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn url(&self, path: &str) -> String {
        format!("http://localhost:{}{path}", self.port)
    }

    /// The page at `path`: a document titled `title` with `body`, which may
    /// script.
    pub fn page(&self, path: &str, title: &str, body: &str) {
        let html = format!(
            "<!doctype html><html><head><meta charset=utf-8><title>{title}</title>\
             <meta name=viewport content=\"width=device-width\"></head>\
             <body style=\"font: 16px sans-serif; margin: 24px\"><h1>{title}</h1>{body}</body></html>"
        );
        self.lock().pages.insert(path.to_owned(), html.into_bytes());
    }

    /// `path` redirects to `to`.
    pub fn redirect(&self, path: &str, to: &str) {
        self.lock().redirects.insert(path.to_owned(), to.to_owned());
    }

    /// The page at `path` comes in part: titled `title`, with `body`, and
    /// the rest never.
    pub fn unfinished(&self, path: &str, title: &str, body: &str) {
        // Past the engine's first read, so it draws what came.
        let html = format!(
            "<!doctype html><html><head><meta charset=utf-8><title>{title}</title></head>\
             <body><p>{body}</p><!-- {} -->",
            ".".repeat(4096)
        );
        self.lock()
            .unfinished
            .insert(path.to_owned(), html.into_bytes());
    }

    /// Requests wait for release() while held.
    pub fn hold(&self) {
        self.lock().holding = true;
    }

    /// Requests for `path` alone wait for release().
    pub fn hold_path(&self, path: &str) {
        self.lock().holding_path = Some(path.to_owned());
    }

    pub fn release(&self) {
        let held = {
            let mut served = self.lock();
            served.holding = false;
            served.holding_path = None;
            std::mem::take(&mut served.held)
        };
        for (stream, path) in held {
            answer(stream, &path, &self.served);
        }
    }

    pub fn requests(&self) -> usize {
        self.lock().requests
    }

    pub fn paths(&self) -> Vec<String> {
        self.lock().paths.clone()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Served> {
        self.served.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Drop for DevServer {
    fn drop(&mut self) {
        self.stop();
    }
}

fn serve(mut stream: TcpStream, served: &Mutex<Served>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(20)));
    let mut request = Vec::new();
    let mut buffer = [0u8; 4096];
    while !request.windows(4).any(|w| w == b"\r\n\r\n") {
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => return,
            Ok(n) => request.extend_from_slice(&buffer[..n]),
        }
    }
    let line = String::from_utf8_lossy(&request);
    let path = line.split(' ').nth(1).unwrap_or("/").to_owned();
    {
        let mut state = served.lock().unwrap_or_else(|e| e.into_inner());
        state.requests += 1;
        state.paths.push(path.clone());
        if state.holding || state.holding_path.as_deref() == Some(path.as_str()) {
            state.held.push((stream, path));
            return;
        }
    }
    answer(stream, &path, served);
}

fn answer(mut stream: TcpStream, path: &str, served: &Mutex<Served>) {
    let reply = {
        let state = served.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(body) = state.unfinished.get(path) {
            let mut reply = b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\
                              Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                .to_vec();
            reply.extend_from_slice(body);
            let _ = stream.write_all(&reply);
            // The rest never comes: the stream stays open with its thread.
            std::thread::sleep(Duration::from_secs(60));
            return;
        }
        if let Some(to) = state.redirects.get(path) {
            format!(
                "HTTP/1.1 302 Found\r\nLocation: {to}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            .into_bytes()
        } else {
            let found = state.pages.get(path);
            let body = found
                .cloned()
                .unwrap_or_else(|| b"<!doctype html><title>Not found</title>".to_vec());
            let mut reply = format!(
                "HTTP/1.1 {}\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n",
                if found.is_some() { "200 OK" } else { "404 Not Found" },
                body.len()
            )
            .into_bytes();
            reply.extend_from_slice(&body);
            reply
        }
    };
    let _ = stream.write_all(&reply);
    let _ = stream.shutdown(Shutdown::Write);
}

// --- The scenario's browsing --------------------------------------------------------------

/// What a browser scenario keeps: the dev server, and the tab it is about.
#[derive(Default)]
pub struct Browsing {
    server: Option<DevServer>,
    pub tab_id: String,
    /// What the user typed in the address field.
    pub typed: String,
}

impl Browsing {
    pub fn server(&self) -> Option<&DevServer> {
        self.server.as_ref()
    }
}

pub fn browsing(world: &mut World) -> &mut Browsing {
    world.mc.part::<Browsing>()
}

pub fn dev_server(world: &mut World) -> Outcome<&mut DevServer> {
    let state = browsing(world);
    if state.server.is_none() {
        let mut server = DevServer::new();
        expect!(server.listen(), "the dev server could not listen");
        server.page("/", "Dev server", "");
        state.server = Some(server);
    }
    Ok(state.server.as_mut().expect("made above"))
}

pub fn server_url(world: &mut World, path: &str) -> Outcome<String> {
    Ok(dev_server(world)?.url(path))
}

/// preview.ex report_status/1 and resize/1, for the pages here.
fn extension(mc: &mut FakeMc) {
    fn update_tab(mc: &mut FakeMc, rpc: &Rpc, keys: &[&str]) -> Option<Json> {
        let tabs = &mut fake(mc).tabs;
        let Some(tab) = tabs.iter_mut().find(|t| t["tabId"] == rpc.payload["tabId"]) else {
            mc.refuse(rpc, "Unknown preview session");
            return None;
        };
        for key in keys {
            if let Some(value) = rpc.payload.get(*key) {
                tab[*key] = value.clone();
            }
        }
        Some(tab.clone())
    }
    mc.on_rpc("preview.reportStatus", |mc, rpc| {
        let Some(tab) = update_tab(mc, rpc, &["navStatus", "canGoBack", "canGoForward"]) else {
            return Ok(());
        };
        let status = &tab["navStatus"];
        if status["_tag"] == "LoadFailed" {
            let fields = json!({"url": status["url"], "title": status["title"],
                                "code": status["code"], "description": status["description"]});
            emit_event(mc, &tab, "failed", fields);
        } else {
            emit_event(mc, &tab, "navigated", json!({"snapshot": tab}));
        }
        mc.reply(rpc, Json::Null);
        Ok(())
    });
    // A size waits while `preview.resize` is held, and is refused while
    // `refusals` has it.
    mc.on_rpc("preview.resize", |mc, rpc| {
        let held = mc.holding(&rpc.method);
        let rpc = rpc.clone();
        let answer = move |mc: &mut FakeMc| {
            if let Some(why) = mc.refusals.get(&rpc.method).cloned() {
                return mc.refuse(&rpc, &why);
            }
            let Some(tab) = update_tab(mc, &rpc, &["viewport"]) else {
                return;
            };
            emit_event(mc, &tab, "resized", json!({"snapshot": tab}));
            mc.reply(&rpc, tab);
        };
        if held {
            mc.defer(answer);
        } else {
            answer(mc);
        }
        Ok(())
    });
}

/// The thread's previews show pages here, as the desktop does (main.rs).
/// Each scenario's app is new, so no permission is kept and DevTools'
/// layout is the default.
pub fn embed(world: &mut World) -> Outcome {
    world.with::<RightPanel, _>(|p, engine| p.set_embedded(engine, true))?;
    world.sync()
}

pub fn active_tab(world: &World) -> String {
    text(at(&world.state("panel"), "activeId"))
}

/// The right panel, drawn, as the user sees it beside the thread.
pub fn draw_panel(world: &mut World) -> Outcome {
    if world.part::<Shown>().0.is_some() {
        return Ok(());
    }
    let qml = "import QtQuick\nimport HalC2.Bricks\nItem { RightPanel { anchors.fill: parent } }\n";
    Brick::show(world, qml, 900.0, 760.0)?;
    if let Some(brick) = &mut world.part::<Shown>().0 {
        brick.takes_keys = true;
    }
    Ok(())
}

/// The drawn panel.
pub fn panel(world: &mut World) -> Outcome<Brick> {
    brick::shown(world)
}

/// The named item showing, or none.
pub fn find(world: &World, brick: Brick, object_name: &str) -> Option<ObjectId> {
    brick.find_visible(world, object_name).ok().flatten()
}

/// The tab's page object.
pub fn page(world: &mut World) -> Outcome<ObjectId> {
    let tab = browsing(world).tab_id.clone();
    match browser::page(world.engine(), &tab) {
        Some(page) => Ok(page),
        None => fail!("no page shows {tab}"),
    }
}

pub fn view(world: &World, brick: Brick) -> Option<ObjectId> {
    find(world, brick, "browserView")
}

pub fn read_text(world: &World, item: ObjectId, name: &str) -> String {
    let engine = world.engine();
    match engine.read_by_name(item, name) {
        Value::Undefined | Value::Null => String::new(),
        value => engine.to_js_string(&value).to_string(),
    }
}

pub fn read_flag(world: &World, item: ObjectId, name: &str) -> bool {
    matches!(world.engine().read_by_name(item, name), Value::Bool(true))
}

pub fn view_url(world: &World, brick: Brick) -> String {
    view(world, brick).map_or(String::new(), |v| read_text(world, v, "url"))
}

pub fn loading(world: &World, brick: Brick) -> bool {
    view(world, brick).is_some_and(|v| read_flag(world, v, "loading"))
}

pub fn failure(world: &World, brick: Brick) -> String {
    if find(world, brick, "browserFailure").is_none() {
        return String::new();
    }
    find(world, brick, "browserFailureMessage")
        .map_or(String::new(), |m| read_text(world, m, "text"))
}

pub fn state(world: &World, brick: Brick) -> String {
    let panel = show(&world.state("panel"));
    let Some(shown) = view(world, brick) else {
        if let Some(why) = ljos_webengine::unavailable() {
            return format!(
                "no browser view (the web engine is unavailable: {why}); the panel is {panel}"
            );
        }
        return format!("no browser view; the panel is {panel}");
    };
    let url = read_text(world, shown, "url");
    let title = read_text(world, shown, "title");
    let busy = if read_flag(world, shown, "loading") {
        "loading"
    } else {
        "idle"
    };
    let zoom = read_text(world, shown, "zoomFactor");
    let failing = failure(world, brick);
    let failing = if failing.is_empty() {
        String::new()
    } else {
        format!(" failing with \"{failing}\"")
    };
    format!(
        "the view is at {url} ({busy}, \"{title}\", zoom {zoom}){failing}; the panel is {panel}; {}",
        describe(world)
    )
}

/// Waits on the page's engine: Chromium runs in its own processes, and on
/// a busy machine it answers more slowly than the fake MC, so its bound is
/// four of a step's waits.
pub fn wait_for_engine(
    world: &mut World,
    mut condition: impl FnMut(&World) -> bool,
    what: impl Fn(&World) -> String,
) -> Outcome {
    let mut tries = 0;
    loop {
        match world.wait_for_with(&mut condition, &what) {
            Err(_) if tries < 3 => tries += 1,
            done => return done,
        }
    }
}

/// Runs `script` in the tab's page, as the preview automation does, and
/// waits for its value.
pub fn evaluate(world: &mut World, script: &str) -> Outcome<Json> {
    let page = page(world)?;
    let brick = panel(world)?;
    let result = std::rc::Rc::new(std::cell::RefCell::new(None));
    let answered = result.clone();
    BrowserPage::evaluate(world.engine(), page, script, 0, move |engine, value| {
        *answered.borrow_mut() = Some(json::from_value(engine, &value));
    });
    let script = script.to_owned();
    wait_for_engine(
        world,
        |_| result.borrow().is_some(),
        |w| format!("the page to run {script}; {}", state(w, brick)),
    )?;
    Ok(result.borrow_mut().take().unwrap_or(Json::Null))
}

pub fn evaluated(world: &mut World, script: &str) -> Outcome<String> {
    Ok(match evaluate(world, script)? {
        Json::String(s) => s,
        other => other.to_string(),
    })
}

/// Waits until the view is idle on what `shown` accepts, and its document
/// (asked, as the view says so before its load starts) answers `script`
/// with `want`.
fn wait_for_document(
    world: &mut World,
    shown: impl Fn(&World, Brick) -> bool,
    script: &str,
    want: &str,
) -> Outcome {
    let brick = panel(world)?;
    for _ in 0..20 {
        wait_for_engine(
            world,
            |w| shown(w, brick) && !loading(w, brick),
            |w| state(w, brick),
        )?;
        if evaluated(world, script)? == want {
            return Ok(());
        }
        // A frame, for the load still on its way.
        let _ = world.wait_for_with(|_| false, |_| String::new());
    }
    fail!("the page did not finish loading: {}", state(world, brick))
}

pub fn wait_for_title(world: &mut World, title: &str) -> Outcome {
    let want = format!("complete {title}");
    let title = title.to_owned();
    wait_for_document(
        world,
        move |w, b| view(w, b).is_some_and(|v| read_text(w, v, "title") == title),
        "document.readyState + ' ' + document.title",
        &want,
    )
}

/// Waits for the tab's view to have loaded `url`.
pub fn wait_for_page(world: &mut World, url: &str) -> Outcome {
    let want = format!("complete {url}");
    let url = url.to_owned();
    wait_for_document(
        world,
        move |w, b| view_url(w, b) == url,
        "document.readyState + ' ' + location.href",
        &want,
    )
}

/// Waits for a browser tab to show, the one the scenario is about from now
/// on, and its page to load `url` (when not empty).
pub fn wait_for_tab(world: &mut World, url: &str) -> Outcome {
    wait_for_engine(
        world,
        |w| active_tab(w).starts_with("browser:"),
        |w| {
            format!(
                "a browser tab to show; the panel is {}",
                show(&w.state("panel"))
            )
        },
    )?;
    browsing(world).tab_id = active_tab(world)["browser:".len()..].to_owned();
    if !url.is_empty() {
        wait_for_page(world, url)?;
    }
    Ok(())
}

/// The thread has one browser tab, drawn, showing the dev server's `path`.
pub fn show_tab(world: &mut World, path: &str) -> Outcome {
    let url = server_url(world, path)?;
    show_previews(world)?;
    embed(world)?;
    draw_panel(world)?;
    update(world, |p| p.open_address(&url))?;
    world.sync()?;
    wait_for_tab(world, &url)
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Opening a page beside the thread.
    steps.step(
        "the thread's dev server is listening locally",
        |world, _, _| {
            let server = dev_server(world)?;
            server.page("/", "Vite App", "");
            let (port, url) = (server.port(), server.url("/"));
            // What the MC's scan of its machine finds.
            fake(&mut world.mc).servers = vec![json!({
            "host": "localhost", "port": port, "url": url,
            "processName": "vite", "pid": 4242, "terminal": null})];
            show_previews(world)?;
            embed(world)?;
            draw_panel(world)
        },
    );
    steps.step("the user opens the preview", |world, _, _| {
        // The dev server's link in the agent's reply, followed.
        let url = server_url(world, "/")?;
        update(world, |p| p.open_address(&url))?;
        world.sync()
    });
    steps.step(
        "the page opens in a browser tab beside the thread instead of a desktop-only notice",
        |world, _, _| {
            let url = server_url(world, "/")?;
            wait_for_tab(world, &url)?;
            let opened = world.opened_urls();
            expect!(opened.is_empty(), "the user's browser opened {opened:?}");
            wait_for_title(world, "Vite App")?;
            let brick = panel(world)?;
            let address = find(world, brick, "browserAddress").map(|a| read_text(world, a, "text"));
            expect!(
                address.as_deref() == Some(url.as_str()),
                "{}",
                state(world, brick)
            );
            // The MC heard where the page is.
            wait_for_engine(
                world,
                |w| {
                    read(w, |p| {
                        p.count() > 0
                            && super::role(p, 0, "status") == "loaded"
                            && super::role(p, 0, "title") == "Vite App"
                    })
                    .unwrap_or(false)
                },
                describe,
            )
        },
    );
    steps.step(
        "a browser tab showing the thread's dev server",
        |world, _, _| show_tab(world, "/"),
    );
    steps.step(
        "a browser tab that (?:fills its space|is not playing audio)",
        |world, _, _| show_tab(world, "/"),
    );
}
