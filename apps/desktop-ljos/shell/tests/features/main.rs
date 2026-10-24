//! desktop-qt's Gherkin scenarios (features/) against this shell: the
//! scenarios desktop-qt's runners run (apps/desktop-qt/tests/native/
//! tst_Features.cpp's kDefaultGlobs, and the ones tst_Scenarios.qml mirrors),
//! their steps ported from desktop-qt's (tests/native/features/*Steps.cpp)
//! to `steps/`, each scenario on a shell of its own (`world.rs`) against a
//! fake MC on loopback (`fake_mc.rs`).
//!
//! ```text
//! cargo test -p hal_c2_shell --test features -- [globs] [--backlog] [--raise] [--list]
//! mise run features:desktop-ljos [globs]
//! ```
//!
//! Globs are relative to features/ and may name scenarios after a colon
//! (`threads/snooze.feature:Snoozing*`); HAL_C2_FEATURES (space separated)
//! does the same. `--backlog` (or HAL_C2_BACKLOG=1) runs the @backlog and
//! @backlog-desktop scenarios instead, as desktop-qt's runner does.
//!
//! Every run reports each scenario as passing, failing, or undefined (a step
//! no definition matches, or two do), with totals per domain. RATCHET holds
//! the ids (`<file>: <name>`) of the scenarios that pass: the run fails when
//! one of them does not, and `--raise` adds the ones that newly pass (only
//! while none of the held ones fails).

// The helpers are a vocabulary for every domain's steps; a domain not
// ported yet leaves some unused.
#![allow(dead_code)]

mod brick;
mod fake_mc;
mod gherkin;
mod harness;
mod steps;
mod world;

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

use gherkin::{Scenario, Selection};
use harness::{Failure, Steps};
use world::World;

const RATCHET_HEADER: &str = "\
# The desktop-qt scenarios that pass on desktop-ljos, one id per line.
# `cargo test -p hal_c2_shell --test features` fails when one of them stops
# passing; `-- --raise` adds the ones that newly pass. Never remove a line to
# make a run pass: fix the regression.
";

struct Args {
    globs: Vec<String>,
    backlog: bool,
    raise: bool,
    list: bool,
}

fn args() -> Args {
    let mut args = Args {
        globs: Vec::new(),
        backlog: std::env::var("HAL_C2_BACKLOG").is_ok_and(|v| !v.is_empty()),
        raise: false,
        list: false,
    };
    for arg in std::env::args().skip(1) {
        match arg.as_str() {
            "--backlog" => args.backlog = true,
            "--raise" => args.raise = true,
            "--list" => args.list = true,
            // What cargo and libtest pass along (--nocapture, --quiet, ...).
            other if other.starts_with('-') => {}
            glob => args.globs.push(glob.to_owned()),
        }
    }
    args
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// What desktop-qt runs: tst_Features.cpp's kDefaultGlobs, the
/// `qt-scenarios.feature` files whose sources name tst_Scenarios.qml, and
/// the scenarios tst_Scenarios.qml names in a `// Scenario:` comment.
fn default_globs(repo: &Path) -> Vec<String> {
    let mut globs = Vec::new();
    let native = repo.join("apps/desktop-qt/tests/native/tst_Features.cpp");
    let source = std::fs::read_to_string(&native)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", native.display()));
    let start = source
        .find("kDefaultGlobs{")
        .expect("tst_Features.cpp names kDefaultGlobs");
    let block = &source[start..start + source[start..].find("};").expect("its end")];
    let literal =
        fancy_regex::Regex::new(r#"QStringLiteral\("((?:[^"\\]|\\.)*)"\)"#).expect("a pattern");
    for captures in literal.captures_iter(block).flatten() {
        globs.push(captures[1].replace("\\\"", "\""));
    }
    let features = repo.join("features");
    for directory in std::fs::read_dir(&features).into_iter().flatten().flatten() {
        let file = directory.path().join("qt-scenarios.feature");
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue;
        };
        let sources = text
            .lines()
            .take_while(|l| l.starts_with('#'))
            .any(|l| l.contains("tests/tst_Scenarios.qml"));
        if sources {
            globs.push(format!(
                "{}/qt-scenarios.feature",
                directory.file_name().to_string_lossy()
            ));
        }
    }
    let qml = repo.join("apps/desktop-qt/tests/tst_Scenarios.qml");
    let comment =
        fancy_regex::Regex::new(r"//\s*Scenario:\s*(.+?)\s*\(features/([^)]+\.feature)\)")
            .expect("a pattern");
    for line in std::fs::read_to_string(&qml).unwrap_or_default().lines() {
        if let Ok(Some(captures)) = comment.captures(line) {
            globs.push(format!("{}:{}", &captures[2], &captures[1]));
        }
    }
    globs
}

enum Verdict {
    Pass,
    Fail {
        line: usize,
        step: String,
        why: String,
    },
    Undefined {
        line: usize,
        why: String,
    },
}

thread_local! {
    static PANIC: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Runs `scenario` on a world of its own.
fn run(steps: &Steps, scenario: &Scenario) -> Verdict {
    let mut found = Vec::with_capacity(scenario.steps.len());
    for step in &scenario.steps {
        match steps.find(step) {
            Ok(definition) => found.push(definition),
            Err(Failure(why)) => {
                return Verdict::Undefined {
                    line: step.line,
                    why,
                };
            }
        }
    }
    let mut at = (0, String::new());
    let outcome = std::panic::catch_unwind(AssertUnwindSafe(|| -> Result<(), Failure> {
        let mut world = World::new(&steps.extensions);
        for (step, (index, captures)) in scenario.steps.iter().zip(&found) {
            at = (step.line, step.text.clone());
            world.checking = step.outcome;
            steps.run(*index, &mut world, captures, &step.table)?;
            world.pump()?;
        }
        Ok(())
    }));
    match outcome {
        Ok(Ok(())) => Verdict::Pass,
        Ok(Err(Failure(why))) => Verdict::Fail {
            line: at.0,
            step: at.1,
            why,
        },
        Err(_) => Verdict::Fail {
            line: at.0,
            step: at.1,
            why: format!("panicked: {}", PANIC.with(|p| p.borrow().clone())),
        },
    }
}

fn read_ratchet(path: &Path) -> BTreeSet<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_owned)
        .collect()
}

fn write_ratchet(path: &Path, held: &BTreeSet<String>) -> std::io::Result<()> {
    let mut text = RATCHET_HEADER.to_owned();
    for id in held {
        text.push_str(id);
        text.push('\n');
    }
    std::fs::write(path, text)
}

fn main() -> ExitCode {
    // Snooze presets and wake labels are wall-clock times: pin them to UTC,
    // as tst_Features.cpp does. Before any other thread starts.
    // SAFETY: nothing else runs yet.
    unsafe { std::env::set_var("TZ", "UTC") };
    std::panic::set_hook(Box::new(|info| {
        PANIC.with(|p| *p.borrow_mut() = info.to_string());
    }));
    let args = args();
    let repo = repo();
    let features = repo.join("features");
    let from_env = std::env::var("HAL_C2_FEATURES")
        .ok()
        .filter(|v| !v.trim().is_empty());
    let default_scope = args.globs.is_empty() && from_env.is_none();
    let globs = if !args.globs.is_empty() {
        args.globs.clone()
    } else if let Some(globs) = &from_env {
        globs.split_whitespace().map(str::to_owned).collect()
    } else {
        default_globs(&repo)
    };
    let scenarios = gherkin::collect(
        &features,
        &globs,
        &Selection {
            surface: "desktop",
            backlog: args.backlog,
        },
    );
    if scenarios.is_empty() {
        eprintln!("no scenarios matched {globs:?}");
        return ExitCode::FAILURE;
    }
    // desktop-qt's rows: two scenarios of one name in a file are told apart
    // by their order.
    let mut seen: HashMap<String, usize> = HashMap::new();
    let ids: Vec<String> = scenarios
        .iter()
        .map(|s| {
            let row = s.row();
            let n = seen.entry(row.clone()).or_default();
            *n += 1;
            if *n == 1 { row } else { format!("{row} #{n}") }
        })
        .collect();
    if args.list {
        for id in &ids {
            println!("{id}");
        }
        return ExitCode::SUCCESS;
    }
    let mut steps = Steps::default();
    steps::register(&mut steps);
    let ratchet_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/features/RATCHET");
    let held = read_ratchet(&ratchet_path);

    let started = Instant::now();
    let mut passing = BTreeSet::new();
    let mut failing = BTreeSet::new();
    let mut undefined = BTreeSet::new();
    // Per domain: passing, failing, undefined.
    let mut domains: BTreeMap<String, [usize; 3]> = BTreeMap::new();
    let mut wanted: HashMap<String, usize> = HashMap::new();
    for (scenario, id) in scenarios.iter().zip(&ids) {
        let domain = scenario
            .file
            .split('/')
            .next()
            .unwrap_or_default()
            .to_owned();
        let counts = domains.entry(domain).or_default();
        match run(&steps, scenario) {
            Verdict::Pass => {
                counts[0] += 1;
                println!("PASS  {id}");
                passing.insert(id.clone());
            }
            Verdict::Fail { line, step, why } => {
                counts[1] += 1;
                println!(
                    "FAIL  {id}\n        features/{}:{line}  {step}\n        {why}",
                    scenario.file
                );
                failing.insert(id.clone());
            }
            Verdict::Undefined { line, why } => {
                counts[2] += 1;
                println!(
                    "UNDEF {id}\n        features/{}:{line}  {why}",
                    scenario.file
                );
                *wanted.entry(why).or_default() += 1;
                undefined.insert(id.clone());
            }
        }
    }

    println!(
        "\ncoverage of the scenarios desktop-qt runs, by domain (passing / failing / undefined / total):"
    );
    for (domain, [p, f, u]) in &domains {
        println!("  {domain:<16} {p:>5} {f:>5} {u:>5} {:>6}", p + f + u);
    }
    println!(
        "  {:<16} {:>5} {:>5} {:>5} {:>6}   in {:.1}s",
        "total",
        passing.len(),
        failing.len(),
        undefined.len(),
        ids.len(),
        started.elapsed().as_secs_f64()
    );
    if !wanted.is_empty() {
        let mut wanted: Vec<_> = wanted.into_iter().collect();
        wanted.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        println!("\nthe steps most scenarios wait for:");
        for (why, count) in wanted.iter().take(20) {
            println!("  {count:>5}  {why}");
        }
    }

    // What the ratchet holds and this run did not pass. A held scenario the
    // run did not pick is missing only when the run was for all of them (the
    // backlog is not what RATCHET holds).
    let ran: BTreeSet<&String> = ids.iter().collect();
    let whole = default_scope && !args.backlog;
    let regressed: Vec<&String> = held
        .iter()
        .filter(|id| !passing.contains(*id) && (whole || ran.contains(id)))
        .collect();
    if !regressed.is_empty() {
        println!(
            "\n{} scenario(s) RATCHET holds do not pass:",
            regressed.len()
        );
        for id in &regressed {
            let why = if failing.contains(*id) {
                "fails"
            } else if undefined.contains(*id) {
                "undefined"
            } else {
                "missing"
            };
            println!("  {why:<9} {id}");
        }
        if args.raise {
            println!("not raising RATCHET while a held scenario does not pass");
        }
        return ExitCode::FAILURE;
    }
    let new: Vec<&String> = passing.iter().filter(|id| !held.contains(*id)).collect();
    if args.raise && args.backlog {
        // A backlog scenario that passes loses its tag first; then it is held.
        println!("\nnot raising RATCHET from a backlog run");
    } else if args.raise {
        if new.is_empty() {
            println!(
                "\nRATCHET holds every passing scenario already ({})",
                held.len()
            );
        } else {
            let raised: BTreeSet<String> =
                held.iter().chain(new.iter().copied()).cloned().collect();
            if let Err(e) = write_ratchet(&ratchet_path, &raised) {
                eprintln!("cannot write {}: {e}", ratchet_path.display());
                return ExitCode::FAILURE;
            }
            println!("\nRATCHET raised by {} to {}", new.len(), raised.len());
        }
    } else if !new.is_empty() {
        println!(
            "\n{} scenario(s) pass that RATCHET does not hold yet: `-- --raise` adds them",
            new.len()
        );
    }
    ExitCode::SUCCESS
}
