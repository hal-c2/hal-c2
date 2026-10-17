//! `TimelineModel` in `HalC2.Shell`: the [`Timeline`] as the Timeline brick
//! binds it (`Timeline { model: Threads.timeline }`), desktop-qt's
//! TimelineModel QObject.
//!
//! The brick reads the rows through Ljós's `ItemModel`, the properties and
//! invokables off the object, and listens for `rowsAboutToBeInserted` and
//! `rowsInserted` to hold its place when earlier turns land above it.
//!
//! Whoever owns the timeline (ThreadStore) makes it with
//! [`TimelineModel::create`] and drives the core through
//! [`TimelineModel::update`]; what the core says comes out again as row
//! signals, property changes and the model's signals, and to each
//! [`TimelineModel::observe`]r (for attachmentWanted, earlierWanted,
//! turnChanged and the rest).
//!
//! The rows the views know are kept apart from the core's: the core has
//! already changed when its changes are told, one at a time, so a view
//! reading a row between two of them reads it as the changes so far left it.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::hash::{Hash, Hasher};
use std::rc::Rc;

use ljos::prelude::ClipboardMode;
use ljos::prelude::{Atom, Cx, Engine, ObjectId, Platform, QmlObject, Value, qml_impl};
use ljos::prelude::{EngineError, ItemModel, ModelChange, ModelListener, ModelListeners};

use super::timeline::{FLUSH_DELAY_MS, Out, Role, Timeline};
use crate::json::{self, Json};

/// Hears each of a timeline's changes after its views have.
pub type Observer = Rc<dyn Fn(&Engine, &Out)>;

/// The core and the rows its views were told of.
struct Rows {
    core: RefCell<Timeline>,
    /// The ids of the rows as the views know them.
    shown: RefCell<Vec<String>>,
    listeners: ModelListeners,
    /// Changes the core made that are not told yet: one told may make more
    /// (a view toggles a row as it hears of it), which wait their turn.
    pending: RefCell<VecDeque<Out>>,
    telling: Cell<bool>,
    flush_timer: Cell<Option<ObjectId>>,
    observers: RefCell<Vec<Observer>>,
}

impl Rows {
    fn new(core: Timeline) -> Rows {
        Rows {
            core: RefCell::new(core),
            shown: RefCell::default(),
            listeners: ModelListeners::default(),
            pending: RefCell::default(),
            telling: Cell::new(false),
            flush_timer: Cell::new(None),
            observers: RefCell::default(),
        }
    }

    /// The core's row of the row `row` the views know.
    fn core_row(&self, core: &Timeline, row: usize) -> Option<usize> {
        let shown = self.shown.borrow();
        let id = shown.get(row)?;
        // Between changes the two agree; while they are told, look it up.
        if core.row_id(row) == Some(id.as_str()) {
            return Some(row);
        }
        core.index_of(id)
    }
}

impl ItemModel for Rows {
    fn row_count(&self) -> usize {
        self.shown.borrow().len()
    }

    fn role_names(&self) -> Vec<Atom> {
        Role::ALL.iter().map(|r| Atom::new(r.name())).collect()
    }

    fn data(&self, engine: &Engine, row: usize, role: &str) -> Value {
        let Some(role) = Role::from_name(role) else {
            return Value::Undefined;
        };
        let core = self.core.borrow();
        let value = self.core_row(&core, row).and_then(|at| core.data(at, role));
        drop(core);
        value.map_or(Value::Undefined, |v| json::to_value(engine, &v))
    }

    fn row_key(&self, row: usize) -> u64 {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        self.shown.borrow().get(row).hash(&mut hasher);
        hasher.finish()
    }

    fn subscribe(&self, listener: ModelListener) -> u64 {
        self.listeners.add(listener)
    }

    fn unsubscribe(&self, id: u64) {
        self.listeners.remove(id);
    }
}

/// [`Rows`] with the `Debug` the object needs.
struct RowsCell(Rc<Rows>);

impl std::fmt::Debug for RowsCell {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Rows")
            .field("shown", &self.0.shown.borrow().len())
            .finish_non_exhaustive()
    }
}

/// A thread's conversation as rows: `Threads.timeline`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "TimelineModel", uncreatable)]
pub struct TimelineModel {
    /// "environmentId:threadId"
    #[qml(constant, readonly)]
    thread_key: Atom,
    #[qml(readonly, notify)]
    count: i32,
    /// loading, live or unreachable.
    #[qml(readonly, notify)]
    status: Atom,
    /// Why it is unreachable.
    #[qml(readonly, notify)]
    problem: Atom,
    #[qml(readonly, notify)]
    working: bool,
    /// When the running turn started, ISO 8601; empty when none runs.
    #[qml(readonly, notify)]
    working_since: Atom,
    #[qml(readonly, notify)]
    has_earlier: bool,
    #[qml(readonly, notify)]
    loading_earlier: bool,
    #[qml(skip)]
    rows: RowsCell,
}

fn rows_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Rows>> {
    engine
        .with::<TimelineModel, _>(obj, |m| m.rows.0.clone())
        .ok()
}

fn json_of(engine: &Engine, obj: super::summary::Obj) -> Value {
    json::to_value(engine, &Json::Object(obj))
}

fn text_of(engine: &Engine, value: &Value) -> String {
    match value {
        Value::Undefined | Value::Null => String::new(),
        v => engine.to_js_string(v).to_string(),
    }
}

impl TimelineModel {
    /// The model of `timeline` (configured: its clock, cache, titles, a
    /// copy restored), owned by `owner`. It shows the rows the timeline
    /// already has.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        timeline: Timeline,
    ) -> Result<ObjectId, EngineError> {
        let rows = Rc::new(Rows::new(timeline));
        let model = TimelineModel {
            thread_key: Atom::new(rows.core.borrow().thread_key()),
            count: 0,
            status: Atom::new(""),
            problem: Atom::new(""),
            working: false,
            working_since: Atom::new(""),
            has_earlier: false,
            loading_earlier: false,
            rows: RowsCell(rows.clone()),
        };
        let obj = engine.create_native(model, owner)?;
        engine.set_object_model(obj, Some(rows.clone() as Rc<dyn ItemModel>))?;
        TimelineModel::update(engine, obj, |_| ());
        // What the core says only when it changes.
        for out in [Out::StatusChanged, Out::WorkingChanged, Out::EarlierChanged] {
            sync(engine, obj, &rows, &out);
        }
        Ok(obj)
    }

    /// Runs `f` on the timeline of `obj`, then tells everyone what it
    /// changed. None when `obj` is not a live TimelineModel.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut Timeline) -> R,
    ) -> Option<R> {
        let rows = rows_of(engine, obj)?;
        let result = {
            let mut core = rows.core.borrow_mut();
            let result = f(&mut core);
            rows.pending.borrow_mut().extend(core.take_out());
            result
        };
        if !rows.telling.replace(true) {
            loop {
                let next = rows.pending.borrow_mut().pop_front();
                let Some(out) = next else { break };
                tell(engine, obj, &rows, &out);
            }
            rows.telling.set(false);
        }
        Some(result)
    }

    /// Reads the timeline of `obj`. `f` must not call back into it.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Timeline) -> R) -> Option<R> {
        let rows = rows_of(engine, obj)?;
        let core = rows.core.borrow();
        Some(f(&core))
    }

    /// Calls `f` with each change of the timeline of `obj`, once its views
    /// have heard of it.
    pub fn observe(engine: &Engine, obj: ObjectId, f: impl Fn(&Engine, &Out) + 'static) {
        if let Some(rows) = rows_of(engine, obj) {
            rows.observers.borrow_mut().push(Rc::new(f));
        }
    }
}

/// Tells the views, the object's properties and signals, and the observers
/// of one change.
fn tell(engine: &Engine, obj: ObjectId, rows: &Rows, out: &Out) {
    let cx = Cx::new(engine, obj);
    let int = |n: usize| i32::try_from(n).unwrap_or(i32::MAX);
    match out {
        Out::Removed { first, count } => {
            let (first, count) = (*first, *count);
            rows.listeners
                .emit(engine, &ModelChange::RowsAboutToBeRemoved { first, count });
            rows.shown.borrow_mut().drain(first..first + count);
            rows.listeners
                .emit(engine, &ModelChange::RowsRemoved { first, count });
        }
        Out::Inserted { first, ids } => {
            let (first, count) = (*first, ids.len());
            let last = int(first + count - 1);
            rows.listeners
                .emit(engine, &ModelChange::RowsAboutToBeInserted { first, count });
            let _ =
                TimelineModel::emit_rows_about_to_be_inserted(&cx, Value::Null, int(first), last);
            rows.shown
                .borrow_mut()
                .splice(first..first, ids.iter().cloned());
            rows.listeners
                .emit(engine, &ModelChange::RowsInserted { first, count });
            let _ = TimelineModel::emit_rows_inserted(&cx, Value::Null, int(first), last);
        }
        Out::Moved { from, to } => {
            {
                let mut shown = rows.shown.borrow_mut();
                let id = shown.remove(*from);
                shown.insert(*to, id);
            }
            rows.listeners.emit(
                engine,
                &ModelChange::RowsMoved {
                    from: *from,
                    to: *to,
                    count: 1,
                },
            );
        }
        Out::DataChanged { first, last, roles } => {
            let roles = roles.iter().map(|r| Atom::new(r.name())).collect();
            rows.listeners.emit(
                engine,
                &ModelChange::DataChanged {
                    first: *first,
                    count: last - first + 1,
                    roles,
                },
            );
        }
        Out::FlushTimer(start) => {
            if let Some(timer) = rows.flush_timer.take() {
                engine.destroy(timer);
            }
            if *start {
                rows.flush_timer.set(flush_after(engine, obj));
            }
        }
        Out::TurnChanged => drop(TimelineModel::emit_turn_changed(&cx)),
        Out::CheckpointsChanged => drop(TimelineModel::emit_checkpoints_changed(&cx)),
        Out::AgentsChanged => drop(TimelineModel::emit_agents_changed(&cx)),
        Out::WorkspaceChanged => drop(TimelineModel::emit_workspace_changed(&cx)),
        Out::TimesChanged => drop(TimelineModel::emit_times_changed(&cx)),
        Out::AttachmentWanted(id) => {
            drop(TimelineModel::emit_attachment_wanted(&cx, Atom::new(id)))
        }
        Out::EarlierWanted(items) => drop(TimelineModel::emit_earlier_wanted(
            &cx,
            i32::try_from(*items).unwrap_or(i32::MAX),
        )),
        Out::CountChanged | Out::StatusChanged | Out::WorkingChanged | Out::EarlierChanged => {
            sync(engine, obj, rows, out)
        }
    }
    let observers: Vec<Observer> = rows.observers.borrow().clone();
    for observe in observers {
        observe(engine, out);
    }
}

/// Reads a property the core changed into the object.
fn sync(engine: &Engine, obj: ObjectId, rows: &Rows, out: &Out) {
    let core = rows.core.borrow();
    let result = match out {
        Out::CountChanged => {
            let count = rows.shown.borrow().len();
            drop(core);
            engine.set_internal(
                obj,
                TimelineModel::COUNT,
                i32::try_from(count).unwrap_or(i32::MAX),
            )
        }
        Out::StatusChanged => {
            let (status, problem) = (Atom::new(core.status()), Atom::new(core.problem()));
            drop(core);
            engine
                .set_internal(obj, TimelineModel::STATUS, status)
                .and_then(|()| engine.set_internal(obj, TimelineModel::PROBLEM, problem))
        }
        Out::WorkingChanged => {
            let since = core.working_since().map_or_else(String::new, |at| {
                at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
            });
            let working = core.working();
            drop(core);
            engine
                .set_internal(obj, TimelineModel::WORKING, working)
                .and_then(|()| {
                    engine.set_internal(obj, TimelineModel::WORKING_SINCE, Atom::new(&since))
                })
        }
        Out::EarlierChanged => {
            let (has, loading) = (core.has_earlier(), core.loading_earlier());
            drop(core);
            engine
                .set_internal(obj, TimelineModel::HAS_EARLIER, has)
                .and_then(|()| engine.set_internal(obj, TimelineModel::LOADING_EARLIER, loading))
                .and_then(|()| TimelineModel::emit_earlier_changed(&Cx::new(engine, obj)))
        }
        _ => Ok(()),
    };
    if let Err(e) = result {
        engine.log(
            ljos::prelude::LogLevel::Warning,
            "TimelineModel",
            e.to_string(),
        );
    }
}

/// A single shot of the flush timer, owned by the model.
fn flush_after(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
    let native = ljos::prelude::Timer {
        interval: FLUSH_DELAY_MS,
        repeat: false,
        running: true,
        ..ljos::prelude::Timer::default()
    };
    let timer = engine.create_native(native, Some(obj)).ok()?;
    engine
        .connect_by_name(timer, "triggered", move |engine, _| {
            TimelineModel::update(engine, obj, Timeline::flush);
        })
        .ok()?;
    engine.complete(timer).ok()?;
    Some(timer)
}

#[qml_impl]
impl TimelineModel {
    /// Before rows are inserted at `first..=last` (`parent` is null), as a
    /// Qt model says it.
    #[qml(signal)]
    fn rows_about_to_be_inserted(parent: Value, first: i32, last: i32);
    #[qml(signal)]
    fn rows_inserted(parent: Value, first: i32, last: i32);
    #[qml(signal)]
    fn turn_changed();
    #[qml(signal)]
    fn checkpoints_changed();
    #[qml(signal)]
    fn agents_changed();
    #[qml(signal)]
    fn workspace_changed();
    #[qml(signal)]
    fn times_changed();
    #[qml(signal)]
    fn earlier_changed();
    #[qml(signal)]
    fn attachment_wanted(id: Atom);
    #[qml(signal)]
    fn earlier_wanted(items: i32);

    /// "Working for 12s", or "" when no turn runs.
    #[qml(invokable)]
    fn working_label(cx: &Cx) -> String {
        TimelineModel::read(cx.engine, cx.this, Timeline::working_label).unwrap_or_default()
    }

    /// The long time of a row, or of one call of a work row.
    #[qml(invokable)]
    fn time_title(cx: &Cx, row_id: Value, entry_id: Value) -> String {
        let (row, entry) = (text_of(cx.engine, &row_id), text_of(cx.engine, &entry_id));
        TimelineModel::read(cx.engine, cx.this, |t| t.time_title(&row, &entry)).unwrap_or_default()
    }

    #[qml(invokable)]
    fn load_earlier(cx: &Cx) {
        TimelineModel::update(cx.engine, cx.this, Timeline::load_earlier);
    }

    /// Opens or closes a fold or a work group.
    #[qml(invokable)]
    fn toggle(cx: &Cx, row_id: Atom) {
        TimelineModel::update(cx.engine, cx.this, |t| t.toggle(&row_id));
    }

    /// The row of `rowId`, or -1.
    #[qml(invokable)]
    fn index_of(cx: &Cx, row_id: Atom) -> i32 {
        let rows = rows_of(cx.engine, cx.this);
        rows.and_then(|r| r.shown.borrow().iter().position(|id| **id == *row_id))
            .map_or(-1, |at| i32::try_from(at).unwrap_or(-1))
    }

    /// {checkpointId, scopeId, turn} a reply reverts to; {} when it cannot.
    #[qml(invokable)]
    fn checkpoint_of(cx: &Cx, row_id: Atom) -> Value {
        let found = TimelineModel::read(cx.engine, cx.this, |t| t.checkpoint_of(&row_id));
        json_of(cx.engine, found.unwrap_or_default())
    }

    /// The run a reply finished, for its actions; "" when none.
    #[qml(invokable)]
    fn finished_run_of(cx: &Cx, row_id: Atom) -> String {
        TimelineModel::read(cx.engine, cx.this, |t| t.finished_run_of(&row_id)).unwrap_or_default()
    }

    /// {turn, checkpointId, text, ...} a user message is edited from; {}
    /// when it cannot be.
    #[qml(invokable)]
    fn rewind_point_of(cx: &Cx, row_id: Atom) -> Value {
        let found = TimelineModel::read(cx.engine, cx.this, |t| t.rewind_point_of(&row_id));
        json_of(cx.engine, found.unwrap_or_default())
    }

    /// Puts a message's text on the clipboard; false when the row has none
    /// or the clipboard refused it.
    #[qml(invokable)]
    fn copy(cx: &Cx, row_id: Atom) -> bool {
        let text = TimelineModel::read(cx.engine, cx.this, |t| t.copy_text(&row_id)).flatten();
        let Some(text) = text else {
            return false;
        };
        Platform::of(cx.engine)
            .clipboard()
            .set_text(ClipboardMode::Clipboard, &text)
            .is_ok()
    }

    /// An image on screen wants its address (attachmentWanted, once).
    #[qml(invokable)]
    fn load_attachment(cx: &Cx, id: Atom) {
        TimelineModel::update(cx.engine, cx.this, |t| t.load_attachment(&id));
    }
}
