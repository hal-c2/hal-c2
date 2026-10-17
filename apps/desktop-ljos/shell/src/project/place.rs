//! Where the route's thread is and its checkout's git status, as
//! desktop-qt's WorkspaceController keeps them for the controllers that read
//! them (`place()`, `git()`, `gitError()`, `checkout()`, `refreshGit()` and
//! their change signals).
//!
//! TODO(port): WorkspaceController::{place, git, gitError, checkout,
//! setCheckout, refreshGit, placeChanged, gitChanged}. The workspace port
//! (`controllers/workspace.rs`) owns all of it and has these same free
//! functions and types; once it merges, `Git`, `ProjectActions` and
//! `ProjectSettings` import them from there and this module goes. Until
//! then nothing feeds it: tests (and whoever stands in for the workspace)
//! call the `set_*` functions, which the workspace does not have.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::Map;

use crate::bridge::Bridge;
use crate::json::Json;

/// A new thread's checkout, or the mode picked for a server thread that has
/// not started yet.
#[derive(Clone, Debug, PartialEq)]
pub struct Checkout {
    /// "local" or "worktree".
    pub env_mode: String,
    pub start_from_origin: bool,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    /// "Run on" another machine's checkout; empty keeps the draft's own.
    pub environment_id: String,
    pub project_id: String,
}

impl Default for Checkout {
    fn default() -> Self {
        Checkout {
            env_mode: "local".into(),
            start_from_origin: false,
            branch: None,
            worktree_path: None,
            environment_id: String::new(),
            project_id: String::new(),
        }
    }
}

/// Where the route's thread is and what its terminals start in.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Place {
    pub environment_id: String,
    pub thread_id: String,
    pub project_id: String,
    /// Empty for a server thread.
    pub draft_id: String,
    /// Empty while the MC does not know the project.
    pub root: String,
    /// Empty without a worktree.
    pub worktree_path: String,
    pub scripts: Vec<Json>,
}

impl Place {
    pub fn thread_key(&self) -> String {
        format!("{}:{}", self.environment_id, self.thread_id)
    }

    pub fn cwd(&self) -> &str {
        if self.worktree_path.is_empty() {
            &self.root
        } else {
            &self.worktree_path
        }
    }
}

/// The checkout's git status as the MC's `vcs` shape has it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Git {
    pub local: Map<String, Json>,
    /// Empty while unknown.
    pub remote: Map<String, Json>,
}

type Hook = Rc<dyn Fn(&Engine)>;

#[derive(Default)]
struct Shared {
    place: RefCell<Option<Place>>,
    git: RefCell<Option<Git>>,
    git_error: RefCell<String>,
    checkouts: RefCell<HashMap<String, Checkout>>,
    refreshes: Cell<u32>,
    place_changed: RefCell<Vec<Hook>>,
    git_changed: RefCell<Vec<Hook>>,
}

fn shared(engine: &Engine) -> Rc<Shared> {
    engine.extension::<Shared>()
}

/// Runs each hook once no controller is running.
fn emit(engine: &Engine, hooks: &RefCell<Vec<Hook>>) {
    let hooks = hooks.borrow().clone();
    for hook in hooks {
        Bridge::of(engine).defer(engine, move |engine| hook(engine));
    }
}

/// The route's thread or draft: where it is, its root and worktree; none
/// on another page, or for a thread the shell does not list (yet).
pub fn place(engine: &Engine) -> Option<Place> {
    shared(engine).place.borrow().clone()
}

/// The route's checkout status; none while unknown or not followed.
pub fn git(engine: &Engine) -> Option<Git> {
    shared(engine).git.borrow().clone()
}

/// Why the checkout's status could not be followed (a machine that is
/// unreachable).
pub fn git_error(engine: &Engine) -> String {
    shared(engine).git_error.borrow().clone()
}

/// After the route's thread, its root or worktree changed.
pub fn on_place_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).place_changed.borrow_mut().push(Rc::new(f));
}

/// After [`git`] changed.
pub fn on_git_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).git_changed.borrow_mut().push(Rc::new(f));
}

/// A draft's checkout as the user left it (defaults for one never touched).
pub fn checkout(engine: &Engine, draft_id: &str) -> Checkout {
    shared(engine)
        .checkouts
        .borrow()
        .get(draft_id)
        .cloned()
        .unwrap_or_default()
}

/// Sets a draft's checkout (a new thread on another thread's branch).
pub fn set_checkout(engine: &Engine, draft_id: &str, checkout: Checkout) {
    shared(engine)
        .checkouts
        .borrow_mut()
        .insert(draft_id.to_owned(), checkout);
}

/// Asks the MC to read the route's checkout status again.
pub fn refresh_git(engine: &Engine) {
    let shared = shared(engine);
    shared.refreshes.set(shared.refreshes.get() + 1);
}

/// How many times [`refresh_git`] was called.
pub fn git_refreshes(engine: &Engine) -> u32 {
    shared(engine).refreshes.get()
}

/// Moves the route to `place` (none: off a thread), telling who listens.
pub fn set_place(engine: &Engine, place: Option<Place>) {
    let shared = shared(engine);
    if *shared.place.borrow() == place {
        return;
    }
    *shared.place.borrow_mut() = place;
    emit(engine, &shared.place_changed);
}

/// Sets the checkout status the route's `git()` answers, telling who listens.
pub fn set_git(engine: &Engine, git: Option<Git>, error: &str) {
    let shared = shared(engine);
    *shared.git.borrow_mut() = git;
    *shared.git_error.borrow_mut() = error.to_owned();
    emit(engine, &shared.git_changed);
}
