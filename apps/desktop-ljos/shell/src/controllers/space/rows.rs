//! `SpaceRows`, desktop-qt's list of rows keyed by their `id`, each a map
//! of the roles it names. `set_rows` changes it in place: rows that went
//! are removed, rows that came are inserted, a row that moved is moved,
//! and only a row whose roles changed is redrawn, so delegates (a block
//! being edited) keep their state.

use std::cell::RefCell;
use std::collections::HashSet;
use std::hash::{Hash, Hasher};
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ItemModel, ModelChange, ModelListener, ModelListeners, ObjectId,
    QmlObject, QmlValue, Value, qml_impl,
};
use serde_json::{Map, Value as Json};

pub type Row = Map<String, Json>;

fn row_id(row: &Row) -> String {
    row.get("id")
        .and_then(Json::as_str)
        .unwrap_or("")
        .to_owned()
}

pub struct RowsState {
    roles: Vec<String>,
    rows: RefCell<Vec<Row>>,
    listeners: ModelListeners,
    /// What `set_rows` last did, as "moved <id>", "changed <id>" or "rows
    /// came or went": what a view hears, for whoever follows the rows.
    changes: RefCell<Vec<String>>,
}

impl RowsState {
    fn new(roles: &[&str]) -> RowsState {
        RowsState {
            roles: roles.iter().map(|r| (*r).to_owned()).collect(),
            rows: RefCell::default(),
            listeners: ModelListeners::default(),
            changes: RefCell::default(),
        }
    }

    pub fn rows(&self) -> Vec<Row> {
        self.rows.borrow().clone()
    }

    pub fn count(&self) -> usize {
        self.rows.borrow().len()
    }

    pub fn index_of(&self, id: &str) -> i32 {
        self.rows
            .borrow()
            .iter()
            .position(|r| row_id(r) == id)
            .map_or(-1, |i| i as i32)
    }

    pub fn get(&self, row: i32) -> Row {
        if row < 0 {
            return Row::new();
        }
        self.rows
            .borrow()
            .get(row as usize)
            .cloned()
            .unwrap_or_default()
    }

    pub fn clear_changes(&self) {
        self.changes.borrow_mut().clear();
    }

    pub fn changes(&self) -> Vec<String> {
        self.changes.borrow().clone()
    }

    pub fn set_rows(&self, engine: &Engine, obj: ObjectId, rows: Vec<Row>) {
        let before = self.rows.borrow().len();
        let kept: HashSet<String> = rows.iter().map(row_id).collect();
        let mut i = self.rows.borrow().len();
        while i > 0 {
            i -= 1;
            if kept.contains(&row_id(&self.rows.borrow()[i])) {
                continue;
            }
            self.listeners.emit(
                engine,
                &ModelChange::RowsAboutToBeRemoved { first: i, count: 1 },
            );
            self.rows.borrow_mut().remove(i);
            self.listeners
                .emit(engine, &ModelChange::RowsRemoved { first: i, count: 1 });
            self.changes.borrow_mut().push("rows came or went".into());
        }
        for (i, wanted) in rows.iter().enumerate() {
            let want = row_id(wanted);
            let at = {
                let held = self.rows.borrow();
                (i..held.len()).find(|&j| row_id(&held[j]) == want)
            };
            let Some(at) = at else {
                self.listeners.emit(
                    engine,
                    &ModelChange::RowsAboutToBeInserted { first: i, count: 1 },
                );
                self.rows.borrow_mut().insert(i, wanted.clone());
                self.listeners
                    .emit(engine, &ModelChange::RowsInserted { first: i, count: 1 });
                self.changes.borrow_mut().push("rows came or went".into());
                continue;
            };
            if at != i {
                self.changes
                    .borrow_mut()
                    .push(format!("moved {}", row_id(&self.rows.borrow()[at])));
                let row = self.rows.borrow_mut().remove(at);
                self.rows.borrow_mut().insert(i, row);
                self.listeners.emit(
                    engine,
                    &ModelChange::RowsMoved {
                        from: at,
                        to: i,
                        count: 1,
                    },
                );
            }
            if &self.rows.borrow()[i] != wanted {
                self.rows.borrow_mut()[i] = wanted.clone();
                let roles = self.roles.iter().map(|r| Atom::new(r.as_str())).collect();
                self.listeners.emit(
                    engine,
                    &ModelChange::DataChanged {
                        first: i,
                        count: 1,
                        roles,
                    },
                );
                self.changes.borrow_mut().push(format!("changed {want}"));
            }
        }
        if self.rows.borrow().len() != before {
            let count = i32::try_from(self.rows.borrow().len()).unwrap_or(i32::MAX);
            let _ = engine.set_internal(obj, SpaceRows::COUNT, count);
        }
    }
}

impl ItemModel for RowsState {
    fn row_count(&self) -> usize {
        self.rows.borrow().len()
    }

    fn role_names(&self) -> Vec<Atom> {
        self.roles.iter().map(|r| Atom::new(r.as_str())).collect()
    }

    fn data(&self, _: &Engine, row: usize, role: &str) -> Value {
        self.rows
            .borrow()
            .get(row)
            .and_then(|r| r.get(role))
            .map_or(Value::Undefined, Json::to_value)
    }

    fn row_key(&self, row: usize) -> u64 {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        self.rows.borrow().get(row).map(row_id).hash(&mut hasher);
        hasher.finish()
    }

    fn subscribe(&self, listener: ModelListener) -> u64 {
        self.listeners.add(listener)
    }

    fn unsubscribe(&self, id: u64) {
        self.listeners.remove(id);
    }
}

struct StateCell(Rc<RowsState>);

impl std::fmt::Debug for StateCell {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SpaceRows")
            .field("count", &self.0.count())
            .finish_non_exhaustive()
    }
}

/// One of the Space view's lists (`Spaces.blocks`, `Spaces.pages`, ...).
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "SpaceRows", uncreatable)]
pub struct SpaceRows {
    #[qml(readonly, notify)]
    count: i32,
    #[qml(skip)]
    state: StateCell,
}

impl Default for SpaceRows {
    fn default() -> Self {
        SpaceRows {
            count: 0,
            state: StateCell(Rc::new(RowsState::new(&[]))),
        }
    }
}

/// A rows object the controller drives: its QML object and its state.
#[derive(Clone)]
pub struct Rows {
    pub obj: ObjectId,
    state: Rc<RowsState>,
}

impl Rows {
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        roles: &[&str],
    ) -> Result<Rows, EngineError> {
        let state = Rc::new(RowsState::new(roles));
        let object = SpaceRows {
            count: 0,
            state: StateCell(state.clone()),
        };
        let obj = engine.create_native(object, owner)?;
        engine.set_object_model(obj, Some(state.clone() as Rc<dyn ItemModel>))?;
        Ok(Rows { obj, state })
    }

    pub fn set(&self, engine: &Engine, rows: Vec<Row>) {
        self.state.set_rows(engine, self.obj, rows);
    }

    pub fn rows(&self) -> Vec<Row> {
        self.state.rows()
    }

    pub fn count(&self) -> usize {
        self.state.count()
    }

    pub fn index_of(&self, id: &str) -> i32 {
        self.state.index_of(id)
    }

    pub fn get(&self, row: i32) -> Row {
        self.state.get(row)
    }

    pub fn clear_changes(&self) {
        self.state.clear_changes();
    }

    pub fn changes(&self) -> Vec<String> {
        self.state.changes()
    }
}

fn state_of(cx: &Cx) -> Option<Rc<RowsState>> {
    cx.with::<SpaceRows, _>(|r| r.state.0.clone()).ok()
}

#[qml_impl]
impl SpaceRows {
    #[qml(invokable)]
    fn index_of(cx: &Cx, id: Atom) -> i32 {
        state_of(cx).map_or(-1, |s| s.index_of(id.as_ref()))
    }

    #[qml(invokable)]
    fn get(cx: &Cx, row: i32) -> Value {
        state_of(cx).map_or(Value::Undefined, |s| Json::Object(s.get(row)).to_value())
    }
}
