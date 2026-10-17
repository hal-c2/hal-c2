//! The MC as one window's controllers see it: what it hands back runs as
//! that window ([`Bridge::act`]), and closing the window ends what they
//! followed. desktop-qt gets both from the QObject context a window's
//! controllers pass McClient; a Rust closure has none, so the window's
//! controllers are given this wrapper instead.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use ljos::prelude::Engine;

use crate::bridge::{Acting, Bridge};
use crate::json::Json;
use crate::mc::{
    BytesReply, Mc, OnFrame, OnReady, OnStatus, OnStream, Reply, Resume, Status, StreamId,
    StreamMessage, SubId,
};

/// For whom the MC's answers run.
enum To {
    /// One window's controllers: as that window, and not at all once it
    /// is gone.
    Window(Bridge),
    /// The shared controllers: a reply as the window that made the call,
    /// anything else as it comes.
    Asker(Acting),
}

#[derive(Default)]
struct Hooks {
    /// Cleared when the window closes: nothing reaches its controllers
    /// after that.
    open: Cell<bool>,
    ready: RefCell<Vec<OnReady>>,
    status: RefCell<Vec<OnStatus>>,
    /// Whether the forwarder of each list is on the MC yet.
    following_ready: Cell<bool>,
    following_status: Cell<bool>,
}

pub struct WindowMc {
    inner: Rc<dyn Mc>,
    to: To,
    hooks: Rc<Hooks>,
    subscriptions: RefCell<Vec<SubId>>,
    streams: RefCell<Vec<StreamId>>,
}

/// What an answer runs as, decided when it was asked for.
#[derive(Clone)]
struct Bound {
    window: Option<Bridge>,
    /// A window's own: dropped once the window is gone.
    strict: bool,
    hooks: Rc<Hooks>,
}

impl Bound {
    fn run(&self, engine: &Engine, f: impl FnOnce()) {
        if !self.hooks.open.get() {
            return;
        }
        match self.window {
            Some(b) if b.is_open(engine) => b.act(engine, f),
            Some(_) if self.strict => {}
            _ => f(),
        }
    }
}

impl WindowMc {
    /// The MC for `window`'s controllers.
    pub fn for_window(inner: Rc<dyn Mc>, window: Bridge) -> WindowMc {
        WindowMc::new(inner, To::Window(window))
    }

    /// The MC for the shared controllers.
    pub fn shared(inner: Rc<dyn Mc>, acting: Acting) -> WindowMc {
        WindowMc::new(inner, To::Asker(acting))
    }

    fn new(inner: Rc<dyn Mc>, to: To) -> WindowMc {
        let hooks = Rc::new(Hooks::default());
        hooks.open.set(true);
        WindowMc {
            inner,
            to,
            hooks,
            subscriptions: RefCell::default(),
            streams: RefCell::default(),
        }
    }

    /// The window is gone: what it followed is unsubscribed, its streams
    /// closed, its hooks dropped, and nothing more reaches its controllers.
    pub fn close(&self) {
        self.hooks.open.set(false);
        let subscriptions = std::mem::take(&mut *self.subscriptions.borrow_mut());
        for id in subscriptions {
            self.inner.unsubscribe(id);
        }
        let streams = std::mem::take(&mut *self.streams.borrow_mut());
        for id in streams {
            self.inner.close_stream(id);
        }
        let ready = std::mem::take(&mut *self.hooks.ready.borrow_mut());
        let status = std::mem::take(&mut *self.hooks.status.borrow_mut());
        drop((ready, status));
    }

    fn window(&self) -> Option<Bridge> {
        match &self.to {
            To::Window(b) => Some(*b),
            To::Asker(_) => None,
        }
    }

    /// A reply's: as the window, or as whoever asks now.
    fn reply_to(&self) -> Bound {
        let (window, strict) = match &self.to {
            To::Window(b) => (Some(*b), true),
            To::Asker(acting) => (acting.now(), false),
        };
        Bound {
            window,
            strict,
            hooks: self.hooks.clone(),
        }
    }

    /// What keeps coming (frames, stream events): a window's as it, the
    /// shared controllers' as it comes.
    fn follow(&self) -> Bound {
        Bound {
            window: self.window(),
            strict: true,
            hooks: self.hooks.clone(),
        }
    }

    fn bind(&self, reply: Reply) -> Reply {
        let bound = self.reply_to();
        Box::new(move |engine, result| bound.run(engine, || reply(engine, result)))
    }
}

impl Mc for WindowMc {
    fn is_ready(&self) -> bool {
        self.inner.is_ready()
    }

    fn environment(&self) -> String {
        self.inner.environment()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        self.inner
            .call(environment, method, payload, self.bind(reply));
    }

    fn subscribe(&self, shape: Json, mut on_frame: OnFrame, resume: Option<Resume>) -> SubId {
        let bound = self.follow();
        let id = self.inner.subscribe(
            shape,
            Box::new(move |engine, frame| bound.run(engine, || on_frame(engine, frame))),
            resume,
        );
        if self.window().is_some() {
            self.subscriptions.borrow_mut().push(id);
        }
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.subscriptions.borrow_mut().retain(|s| *s != id);
        self.inner.unsubscribe(id);
    }

    fn more(&self, id: SubId, items: u32) {
        self.inner.more(id, items);
    }

    fn on_ready_changed(&self, f: OnReady) {
        let Some(window) = self.window() else {
            self.inner.on_ready_changed(f);
            return;
        };
        self.hooks.ready.borrow_mut().push(f);
        if self.hooks.following_ready.replace(true) {
            return;
        }
        let hooks = Rc::downgrade(&self.hooks);
        self.inner.on_ready_changed(Box::new(move |engine, ready| {
            let Some(hooks) = hooks.upgrade() else { return };
            if !hooks.open.get() || !window.is_open(engine) {
                return;
            }
            // Taken out while they run: one may add another.
            let mut running = std::mem::take(&mut *hooks.ready.borrow_mut());
            window.act(engine, || {
                for f in &mut running {
                    f(engine, ready);
                }
            });
            if hooks.open.get() {
                let mut kept = hooks.ready.borrow_mut();
                running.append(&mut kept);
                *kept = running;
            }
        }));
    }

    fn status(&self) -> Status {
        self.inner.status()
    }

    fn on_status(&self, f: OnStatus) {
        let Some(window) = self.window() else {
            self.inner.on_status(f);
            return;
        };
        self.hooks.status.borrow_mut().push(f);
        if self.hooks.following_status.replace(true) {
            return;
        }
        let hooks = Rc::downgrade(&self.hooks);
        self.inner.on_status(Box::new(move |engine, status| {
            let Some(hooks) = hooks.upgrade() else { return };
            if !hooks.open.get() || !window.is_open(engine) {
                return;
            }
            let mut running = std::mem::take(&mut *hooks.status.borrow_mut());
            window.act(engine, || {
                for f in &mut running {
                    f(engine, status);
                }
            });
            if hooks.open.get() {
                let mut kept = hooks.status.borrow_mut();
                running.append(&mut kept);
                *kept = running;
            }
        }));
    }

    fn retry_now(&self) {
        self.inner.retry_now();
    }

    fn reconnect(&self) {
        self.inner.reconnect();
    }

    fn wake(&self) {
        self.inner.wake();
    }

    fn set_online(&self, online: bool) {
        self.inner.set_online(online);
    }

    fn origin(&self) -> Option<String> {
        self.inner.origin()
    }

    fn open(&self, origin: &str, token: &str) -> Result<(), String> {
        self.inner.open(origin, token)
    }

    fn dispatch_command(&self, environment: &str, command: Json, reply: Reply) {
        self.inner
            .dispatch_command(environment, command, self.bind(reply));
    }

    fn post(&self, path: &str, body: Json, reply: Reply) {
        self.inner.post(path, body, self.bind(reply));
    }

    fn get(&self, path: &str, reply: Reply) {
        self.inner.get(path, self.bind(reply));
    }

    fn open_stream(
        &self,
        path: &str,
        query: &str,
        socket: bool,
        mut on_event: OnStream,
    ) -> Option<StreamId> {
        let bound = self.reply_to();
        let id = self.inner.open_stream(
            path,
            query,
            socket,
            Box::new(move |engine, event| bound.run(engine, || on_event(engine, event))),
        )?;
        if self.window().is_some() {
            self.streams.borrow_mut().push(id);
        }
        Some(id)
    }

    fn send_on_stream(&self, id: StreamId, message: StreamMessage) {
        self.inner.send_on_stream(id, message);
    }

    fn close_stream(&self, id: StreamId) {
        self.streams.borrow_mut().retain(|s| *s != id);
        self.inner.close_stream(id);
    }

    fn upload(&self, relative_url: &str, bytes: Vec<u8>, mime_type: &str, reply: Reply) {
        self.inner
            .upload(relative_url, bytes, mime_type, self.bind(reply));
    }

    fn download(&self, relative_url: &str, reply: BytesReply) {
        let bound = self.reply_to();
        self.inner.download(
            relative_url,
            Box::new(move |engine, result| bound.run(engine, || reply(engine, result))),
        );
    }
}
