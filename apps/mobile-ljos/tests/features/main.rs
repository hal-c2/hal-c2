//! mobile-qt's Gherkin scenarios (features/) against this shell: the
//! scenarios mobile-qt's runner runs (apps/mobile-qt/tests/
//! tst_Features.cpp's kDefaultGlobs), their steps ported from
//! mobile-qt's (tests/features/*Steps.cpp) to `steps/`, each scenario
//! on a phone of its own (`world.rs`) against an exchange it sets.
//!
//! ```text
//! cargo test -p hal_c2_mobile --test features -- [globs] [--backlog] [--raise] [--list]
//! mise run features:mobile-ljos [globs]
//! ```
//!
//! Globs are relative to features/ and may name scenarios after a colon
//! (`mobile/pairing-and-environments.feature:First launch*`);
//! HAL_C2_FEATURES (space separated) does the same. `--backlog` (or
//! HAL_C2_BACKLOG=1) runs the @backlog and @backlog-mobile scenarios
//! instead, as mobile-qt's runner does.
//!
//! Every run reports each scenario as passing, failing, or undefined (a
//! step no definition matches, or two do), with totals per domain.
//! RATCHET holds the ids (`<file>: <name>`) of the scenarios that pass:
//! the run fails when one of them does not, and `--raise` adds the ones
//! that newly pass (only while none of the held ones fails). The ledger
//! counts this RATCHET as the mobile surface's proof beside mobile-qt's
//! globs (mise-tasks/features/check), as it counts desktop-ljos's.
//!
//! The Gherkin reader is desktop-ljos's, included where it lives so
//! both runs name and pick the same scenarios.

// The helpers are a vocabulary for every domain's steps; a domain not
// ported yet leaves some unused.
#![allow(dead_code)]

#[path = "../../../desktop-ljos/shell/tests/features/gherkin.rs"]
mod gherkin;
mod harness;
mod steps;
mod world;

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use gherkin::{Scenario, Selection};
use harness::{Failure, Steps};
use world::World;

const RATCHET_HEADER: &str = "\
# The phone's scenarios that pass on mobile-ljos, one id per line.
# `cargo test -p hal_c2_mobile --test features` fails when one of them stops
# passing; `-- --raise` adds the ones that newly pass. Never remove a line to
# make a run pass: fix the regression.
";

/// Longer than any scenario takes: one that runs past it is stuck in a
/// turn that never returns.
const HANG: Duration = Duration::from_secs(120);

fn watchdog(id: &str) -> mpsc::Sender<()> {
    let (done, finished) = mpsc::channel::<()>();
    let id = id.to_owned();
    std::thread::spawn(move || {
        if finished.recv_timeout(HANG) == Err(mpsc::RecvTimeoutError::Timeout) {
            println!(
                "HANG  {id}\n        still running after {}s",
                HANG.as_secs()
            );
            std::process::exit(1);
        }
    });
    done
}

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
            other if other.starts_with('-') => {}
            glob => args.globs.push(glob.to_owned()),
        }
    }
    args
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// What mobile-qt runs: tst_Features.cpp's kDefaultGlobs.
fn default_globs(repo: &Path) -> Vec<String> {
    let native = repo.join("apps/mobile-qt/tests/tst_Features.cpp");
    let source = std::fs::read_to_string(&native)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", native.display()));
    let start = source
        .find("kDefaultGlobs{")
        .expect("tst_Features.cpp names kDefaultGlobs");
    let block = &source[start..start + source[start..].find("};").expect("its end")];
    let literal =
        fancy_regex::Regex::new(r#"QStringLiteral\("((?:[^"\\]|\\.)*)"\)"#).expect("a pattern");
    literal
        .captures_iter(block)
        .flatten()
        .map(|captures| captures[1].replace("\\\"", "\""))
        .collect()
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
    static PANICS: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
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
    PANICS.with(|p| p.borrow_mut().clear());
    let outcome = std::panic::catch_unwind(AssertUnwindSafe(|| -> Result<(), Failure> {
        let mut world = World::new();
        for (step, (index, captures)) in scenario.steps.iter().zip(&found) {
            at = (step.line, step.text.clone());
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
            why: match PANICS.with(|p| p.borrow().first().cloned()) {
                Some(panic) => format!("{why}\n        after a caught panic: {panic}"),
                None => why,
            },
        },
        Err(_) => Verdict::Fail {
            line: at.0,
            step: at.1,
            why: format!(
                "panicked: {}",
                PANICS.with(|p| p.borrow().last().cloned().unwrap_or_default())
            ),
        },
    }
}

fn wanted_by(id: &str, globs: &[String], features: &Path) -> bool {
    let Some((file, name)) = id.split_once(": ") else {
        return true;
    };
    if !features.join(file).is_file() {
        return true;
    }
    let name = match name.rsplit_once(" #") {
        Some((base, n)) if n.parse::<usize>().is_ok() => base,
        _ => name,
    };
    globs.iter().any(|glob| {
        let (file_glob, name_glob) = match glob.split_once(':') {
            Some((f, n)) => (f, Some(n)),
            None => (glob.as_str(), None),
        };
        gherkin::wildcard(file_glob, file) && name_glob.is_none_or(|n| gherkin::wildcard(n, name))
    })
}

/// What RATCHET holds; a RATCHET that cannot be read fails the run, as
/// one held nothing would let every scenario stop passing unseen.
fn read_ratchet(path: &Path) -> std::io::Result<BTreeSet<String>> {
    Ok(std::fs::read_to_string(path)?
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_owned)
        .collect())
}

fn write_ratchet(path: &Path, held: &BTreeSet<String>) -> std::io::Result<()> {
    let mut text = RATCHET_HEADER.to_owned();
    for id in held {
        text.push_str(id);
        text.push('\n');
    }
    std::fs::write(path, text)
}

#[cfg(unix)]
fn own_runtime_dir() -> Option<tempfile::TempDir> {
    // SAFETY: getuid has no preconditions.
    let user = PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }));
    let base = if user.is_dir() {
        user
    } else {
        std::env::temp_dir()
    };
    let dir = tempfile::Builder::new()
        .prefix("hc-mf-")
        .tempdir_in(base)
        .ok()?;
    // SAFETY: nothing else runs yet.
    unsafe { std::env::set_var("XDG_RUNTIME_DIR", dir.path()) };
    Some(dir)
}

#[cfg(not(unix))]
fn own_runtime_dir() -> Option<()> {
    None
}

fn main() -> ExitCode {
    // SAFETY: nothing else runs yet.
    unsafe { std::env::set_var("TZ", "UTC") };
    let _runtime = own_runtime_dir();
    std::panic::set_hook(Box::new(|info| {
        PANICS.with(|p| p.borrow_mut().push(info.to_string()));
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
            surface: "mobile",
            backlog: args.backlog,
        },
    );
    if scenarios.is_empty() {
        eprintln!("no scenarios matched {globs:?}");
        return ExitCode::FAILURE;
    }
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
    // Said here: a panic would only be kept by the hook, never printed.
    let held = match read_ratchet(&ratchet_path) {
        Ok(held) => held,
        Err(error) => {
            eprintln!("{}: {error}", ratchet_path.display());
            return ExitCode::FAILURE;
        }
    };

    let started = Instant::now();
    let mut passing = BTreeSet::new();
    let mut failing = BTreeSet::new();
    let mut undefined = BTreeSet::new();
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
        let verdict = {
            let _watch = watchdog(id);
            run(&steps, scenario)
        };
        match verdict {
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
        "\ncoverage of the scenarios mobile-qt runs, by domain (passing / failing / undefined / total):"
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

    let ran: BTreeSet<&String> = ids.iter().collect();
    let whole = default_scope && !args.backlog;
    let regressed: Vec<&String> = held
        .iter()
        .filter(|id| {
            !passing.contains(*id)
                && (whole
                    || ran.contains(id)
                    || (!args.backlog && wanted_by(id, &globs, &features)))
        })
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
