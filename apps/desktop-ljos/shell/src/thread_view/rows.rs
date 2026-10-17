//! The rows of a pure core as a Ljós list model: what DiffModel,
//! FileTreeModel and ThreadPreviews share.
//!
//! A core changes its rows in one go and records each change as it makes
//! it ([`RowChange`]); [`ListRows::update`] then tells the views of them one
//! at a time. The rows the views know are kept apart from the core's (their
//! keys), so a view that reads a row between two changes reads the row it
//! knows there, not whatever the core has at that index by now.

use std::cell::{Cell, OnceCell, RefCell};
use std::collections::VecDeque;
use std::rc::Rc;

use ljos::prelude::{Atom, Engine, ObjectId, Value};
use ljos_engine::{EngineError, ModelSignals, QmlListModel, RowKey};

/// One change to a core's rows, as it made it.
#[derive(Clone, Debug, PartialEq)]
pub enum RowChange {
    /// Every row may be different: the rows are now these.
    Reset(Vec<RowKey>),
    Inserted {
        first: usize,
        keys: Vec<RowKey>,
    },
    Removed {
        first: usize,
        count: usize,
    },
    /// Roles of `count` rows from `first`; none: any of them.
    Changed {
        first: usize,
        count: usize,
        roles: &'static [&'static str],
    },
}

/// A core whose rows a view follows.
pub trait RowSource {
    /// The roles every row has, in a stable order.
    fn roles(&self) -> &'static [&'static str];
    fn row_count(&self) -> usize;
    /// What identifies the row while it is in the model.
    fn row_key(&self, row: usize) -> RowKey;
    /// `undefined` for a role the row does not have.
    fn data(&self, row: usize, role: &str) -> Value;
    /// The changes made since the last call, in order.
    fn take_changes(&mut self) -> Vec<RowChange>;
}

/// A core and the rows its views were told of.
pub struct ListRows<S> {
    core: RefCell<S>,
    shown: RefCell<Vec<RowKey>>,
    signals: OnceCell<ModelSignals>,
    /// Changes not told yet: one told may make more, which wait their turn.
    pending: RefCell<VecDeque<RowChange>>,
    telling: Cell<bool>,
}

impl<S> std::fmt::Debug for ListRows<S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ListRows")
            .field("shown", &self.shown.borrow().len())
            .finish_non_exhaustive()
    }
}

impl<S: RowSource + 'static> ListRows<S> {
    /// The rows of `core`, which views know as it is now.
    pub fn new(mut core: S) -> Rc<ListRows<S>> {
        core.take_changes();
        let shown = (0..core.row_count()).map(|r| core.row_key(r)).collect();
        Rc::new(ListRows {
            core: RefCell::new(core),
            shown: RefCell::new(shown),
            signals: OnceCell::new(),
            pending: RefCell::default(),
            telling: Cell::new(false),
        })
    }

    /// Makes `obj` the model views read these rows through.
    pub fn attach(self: &Rc<Self>, engine: &Engine, obj: ObjectId) -> Result<(), EngineError> {
        let signals = engine.set_list_model(obj, self.clone() as Rc<dyn QmlListModel>)?;
        let _ = self.signals.set(signals);
        Ok(())
    }

    /// Runs `f` on the core, then tells the views what it changed.
    pub fn update<R>(&self, engine: &Engine, f: impl FnOnce(&mut S) -> R) -> R {
        let result = {
            let mut core = self.core.borrow_mut();
            let result = f(&mut core);
            self.pending.borrow_mut().extend(core.take_changes());
            result
        };
        if !self.telling.replace(true) {
            loop {
                let next = self.pending.borrow_mut().pop_front();
                let Some(change) = next else { break };
                self.tell(engine, change);
            }
            self.telling.set(false);
        }
        result
    }

    /// Reads the core. `f` must not call back into it.
    pub fn read<R>(&self, f: impl FnOnce(&S) -> R) -> R {
        f(&self.core.borrow())
    }

    /// The rows the views know.
    pub fn shown_count(&self) -> usize {
        self.shown.borrow().len()
    }

    fn tell(&self, engine: &Engine, change: RowChange) {
        let signals = self.signals.get();
        match change {
            RowChange::Reset(keys) => {
                *self.shown.borrow_mut() = keys;
                if let Some(s) = signals {
                    s.model_reset(engine);
                }
            }
            RowChange::Inserted { first, keys } => {
                let count = keys.len();
                if let Some(s) = signals {
                    s.rows_about_to_be_inserted(engine, first, count);
                }
                self.shown.borrow_mut().splice(first..first, keys);
                if let Some(s) = signals {
                    s.rows_inserted(engine, first, count);
                }
            }
            RowChange::Removed { first, count } => {
                if let Some(s) = signals {
                    s.rows_about_to_be_removed(engine, first, count);
                }
                self.shown.borrow_mut().drain(first..first + count);
                if let Some(s) = signals {
                    s.rows_removed(engine, first, count);
                }
            }
            RowChange::Changed {
                first,
                count,
                roles,
            } => {
                if let Some(s) = signals {
                    s.data_changed(engine, first, count, roles);
                }
            }
        }
    }

    /// The core's row of the row `row` the views know.
    fn core_row(&self, core: &S, row: usize) -> Option<usize> {
        let key = *self.shown.borrow().get(row)?;
        // Between changes the two agree; while they are told, look it up.
        if row < core.row_count() && core.row_key(row) == key {
            return Some(row);
        }
        (0..core.row_count()).find(|r| core.row_key(*r) == key)
    }
}

impl<S: RowSource + 'static> QmlListModel for ListRows<S> {
    fn row_count(&self) -> usize {
        self.shown.borrow().len()
    }

    fn role_names(&self) -> Vec<Atom> {
        self.core
            .borrow()
            .roles()
            .iter()
            .map(|r| Atom::new(r))
            .collect()
    }

    fn data(&self, row: usize, role: &str) -> Value {
        let core = self.core.borrow();
        self.core_row(&core, row)
            .map_or(Value::Undefined, |at| core.data(at, role))
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.shown
            .borrow()
            .get(row)
            .copied()
            .unwrap_or(row as RowKey)
    }
}

/// A count as QML's `int`.
pub fn int(n: usize) -> i32 {
    i32::try_from(n).unwrap_or(i32::MAX)
}

/// A view kept only by what a core says changed, for tests: the keys and
/// values it holds and the rows it was told to read again. It reads a row
/// when it is told of it, so a value that changed without a signal shows.
#[cfg(test)]
#[derive(Debug, Default)]
pub struct Mirror {
    pub keys: Vec<RowKey>,
    pub values: Vec<Vec<Value>>,
    /// (row key, roles; none: all)
    pub redrawn: Vec<(RowKey, &'static [&'static str])>,
    pub resets: usize,
}

#[cfg(test)]
fn read_row(core: &impl RowSource, key: RowKey, hint: usize) -> Vec<Value> {
    let row = if hint < core.row_count() && core.row_key(hint) == key {
        Some(hint)
    } else {
        (0..core.row_count()).find(|r| core.row_key(*r) == key)
    };
    let roles = core.roles();
    row.map_or_else(
        || vec![Value::Undefined; roles.len()],
        |row| roles.iter().map(|role| core.data(row, role)).collect(),
    )
}

#[cfg(test)]
impl Mirror {
    /// A view of the rows `core` has now; changes before are forgotten.
    pub fn of(core: &mut impl RowSource) -> Mirror {
        core.take_changes();
        let keys: Vec<RowKey> = (0..core.row_count()).map(|r| core.row_key(r)).collect();
        Mirror {
            values: keys
                .iter()
                .enumerate()
                .map(|(i, k)| read_row(core, *k, i))
                .collect(),
            keys,
            ..Mirror::default()
        }
    }

    /// Follows the core's changes, then checks it holds the core's rows as
    /// they are now: none moved or changed without a signal.
    pub fn follow(&mut self, core: &mut impl RowSource) {
        for change in core.take_changes() {
            match change {
                RowChange::Reset(keys) => {
                    self.values = keys
                        .iter()
                        .enumerate()
                        .map(|(i, k)| read_row(core, *k, i))
                        .collect();
                    self.keys = keys;
                    self.resets += 1;
                }
                RowChange::Inserted { first, keys } => {
                    assert!(first <= self.keys.len(), "inserted past the end");
                    let values: Vec<_> = keys
                        .iter()
                        .enumerate()
                        .map(|(i, k)| read_row(core, *k, first + i))
                        .collect();
                    self.values.splice(first..first, values);
                    self.keys.splice(first..first, keys);
                }
                RowChange::Removed { first, count } => {
                    assert!(first + count <= self.keys.len(), "removed past the end");
                    self.keys.drain(first..first + count);
                    self.values.drain(first..first + count);
                }
                RowChange::Changed {
                    first,
                    count,
                    roles,
                } => {
                    assert!(
                        count > 0 && first + count <= self.keys.len(),
                        "redrew past the end"
                    );
                    for at in first..first + count {
                        let key = self.keys[at];
                        let now = read_row(core, key, at);
                        for (r, role) in core.roles().iter().enumerate() {
                            if roles.is_empty() || roles.contains(role) {
                                self.values[at][r] = now[r].clone();
                            }
                        }
                        self.redrawn.push((key, roles));
                    }
                }
            }
        }
        let keys: Vec<RowKey> = (0..core.row_count()).map(|r| core.row_key(r)).collect();
        assert_eq!(self.keys, keys, "the row signals keep the view in step");
        for (row, held) in self.values.iter().enumerate() {
            for (r, role) in core.roles().iter().enumerate() {
                assert_eq!(
                    held[r],
                    core.data(row, role),
                    "row {row} {role} changed without a signal"
                );
            }
        }
    }
}
