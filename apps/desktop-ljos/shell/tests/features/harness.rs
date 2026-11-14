//! What a steps file needs, as desktop-qt's Harness.h: failing a step and
//! registering step definitions. Each domain's steps live in their own file
//! under `steps/` and register themselves from its `register`:
//!
//! ```ignore
//! pub fn register(steps: &mut Steps) {
//!     steps.step(&format!("the user does {Q}"), |world, c, _| {
//!         ...
//!         Ok(())
//!     });
//! }
//! ```

use std::fmt;

use fancy_regex::Regex;
use serde_json::Value;

use crate::fake_mc::FakeMc;
use crate::gherkin::{Step, Table};
use crate::world::World;

/// Why a step failed.
#[derive(Debug)]
pub struct Failure(pub String);

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<String> for Failure {
    fn from(message: String) -> Failure {
        Failure(message)
    }
}

impl From<&str> for Failure {
    fn from(message: &str) -> Failure {
        Failure(message.to_owned())
    }
}

/// What a step, or anything it calls that may fail it, returns.
pub type Outcome<T = ()> = Result<T, Failure>;

/// Fails the step: `fail!("{key} is not shown")`.
#[macro_export]
macro_rules! fail {
    ($($arg:tt)*) => {
        return Err($crate::harness::Failure(format!($($arg)*)))
    };
}

/// Fails the step unless `cond`: `expect!(shown, "{key} is not shown")`.
#[macro_export]
macro_rules! expect {
    ($cond:expr, $($arg:tt)*) => {
        {
            let held: bool = $cond;
            if !held {
                return Err($crate::harness::Failure(format!($($arg)*)));
            }
        }
    };
}

/// A quoted capture: `"([^"]*)"`.
pub const Q: &str = "\"([^\"]*)\"";

pub type Captures = Vec<String>;
pub type StepFn = Box<dyn Fn(&mut World, &Captures, &Table) -> Outcome>;

/// A domain's fake MC handlers, put on every new MC (desktop-qt's
/// `FakeMc::Extension`).
pub type Extension = fn(&mut FakeMc);

struct Definition {
    pattern: Regex,
    source: String,
    run: StepFn,
}

/// Every step definition, and the MC extensions the steps files bring.
#[derive(Default)]
pub struct Steps {
    definitions: Vec<Definition>,
    pub(crate) extensions: Vec<Extension>,
}

impl Steps {
    /// A step matching the whole of `pattern` (a regular expression, as
    /// QRegularExpression reads it). Two definitions matching one step fail
    /// it as ambiguous.
    pub fn step(
        &mut self,
        pattern: &str,
        run: impl Fn(&mut World, &Captures, &Table) -> Outcome + 'static,
    ) {
        let anchored = format!("^(?:{pattern})$");
        let regex = Regex::new(&anchored)
            .unwrap_or_else(|e| panic!("the step pattern {pattern:?} is not valid: {e}"));
        self.definitions.push(Definition {
            pattern: regex,
            source: pattern.to_owned(),
            run: Box::new(run),
        });
    }

    /// Puts `extend`'s handlers on every scenario's MC.
    pub fn extension(&mut self, extend: Extension) {
        self.extensions.push(extend);
    }

    /// The one definition `step` matches and what it captured.
    pub fn find(&self, step: &Step) -> Result<(usize, Captures), Failure> {
        let mut found: Option<(usize, Captures)> = None;
        for (index, definition) in self.definitions.iter().enumerate() {
            let Ok(Some(captures)) = definition.pattern.captures(&step.text) else {
                continue;
            };
            if let Some((other, _)) = &found {
                return Err(Failure(format!(
                    "ambiguous step: {} (/{}/ and /{}/)",
                    step.text, self.definitions[*other].source, definition.source
                )));
            }
            let captured = (1..captures.len())
                .map(|i| {
                    captures
                        .get(i)
                        .map(|m| m.as_str().to_owned())
                        .unwrap_or_default()
                })
                .collect();
            found = Some((index, captured));
        }
        found.ok_or_else(|| Failure(format!("undefined step: {}", step.text)))
    }

    pub fn run(
        &self,
        index: usize,
        world: &mut World,
        captures: &Captures,
        table: &Table,
    ) -> Outcome {
        (self.definitions[index].run)(world, captures, table)
    }

    pub fn len(&self) -> usize {
        self.definitions.len()
    }
}

/// JSON as a failure message shows it.
pub fn show(value: &Value) -> String {
    value.to_string()
}

/// `a.b.c` into nested objects; null where there is nothing.
pub fn at<'a>(value: &'a Value, path: &str) -> &'a Value {
    let mut current = value;
    for part in path.split('.') {
        current = current.get(part).unwrap_or(&Value::Null);
    }
    current
}

/// A JSON value's text as QVariant::toString gives it: a string as it is,
/// a number or a bool spelt out, null and anything else empty.
pub fn text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}
