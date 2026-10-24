//! The Gherkin reader and the choice of scenarios, as desktop-qt's
//! (apps/desktop-qt/tests/native/features/Runner.cpp), so both runs name and
//! pick the same scenarios: tags, Feature, Rule, Background, Scenario,
//! Scenario Outline with Examples, and data tables. Doc strings are not used.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub type Table = Vec<Vec<String>>;

#[derive(Clone, Debug)]
pub struct Step {
    pub text: String,
    pub table: Table,
    pub line: usize,
    /// A Then (or an And or But after one): a step that both sets and
    /// checks, such as "the appearance is Light", checks here.
    pub outcome: bool,
}

#[derive(Clone, Debug)]
pub struct Scenario {
    /// The file, relative to features/.
    pub file: String,
    pub name: String,
    pub tags: Vec<String>,
    pub steps: Vec<Step>,
}

impl Scenario {
    /// desktop-qt's row name: `<file>: <name>`.
    pub fn row(&self) -> String {
        format!("{}: {}", self.file, self.name)
    }
}

/// A table row's cells; a cell's own bar is written `\|`.
fn cells(line: &str) -> Vec<String> {
    let line = line.trim().replace("\\|", "\u{E000}");
    let mut cells: Vec<String> = line
        .split('|')
        .map(|cell| cell.trim().replace('\u{E000}', "|"))
        .collect();
    if !cells.is_empty() {
        cells.remove(0);
    }
    cells.pop();
    cells
}

struct Current {
    name: String,
    tags: Vec<String>,
    steps: Vec<Step>,
    outline: bool,
    /// Each Examples table: its tags, then header and rows.
    examples: Vec<(Vec<String>, Table)>,
}

/// Where the next step or table row goes.
#[derive(Clone, Copy, PartialEq)]
enum Into {
    Nowhere,
    FeatureBackground,
    RuleBackground,
    Scenario,
}

/// The scenarios of the feature file `text`, named `file`.
pub fn parse(file: &str, text: &str) -> Vec<Scenario> {
    let mut scenarios = Vec::new();
    let mut pending: Vec<String> = Vec::new();
    let mut feature_tags: Vec<String> = Vec::new();
    let mut rule_tags: Vec<String> = Vec::new();
    let mut feature_background: Vec<Step> = Vec::new();
    let mut rule_background: Vec<Step> = Vec::new();
    let mut into = Into::Nowhere;
    let mut in_rule = false;
    let mut current: Option<Current> = None;
    let mut in_examples = false;
    let mut outcome = false;

    let flush = |current: &mut Option<Current>,
                 scenarios: &mut Vec<Scenario>,
                 feature_background: &[Step],
                 rule_background: &[Step]| {
        let Some(c) = current.take() else { return };
        let background: Vec<Step> = feature_background
            .iter()
            .chain(rule_background)
            .cloned()
            .collect();
        if !c.outline {
            let mut steps = background.clone();
            steps.extend(c.steps.iter().cloned());
            scenarios.push(Scenario {
                file: file.to_owned(),
                name: c.name.clone(),
                tags: c.tags.clone(),
                steps,
            });
        }
        for (example_tags, table) in &c.examples {
            let Some(header) = table.first() else {
                continue;
            };
            for row in &table[1..] {
                let substitute = |text: &str| {
                    let mut text = text.to_owned();
                    for (column, name) in header.iter().enumerate() {
                        let value = row.get(column).map(String::as_str).unwrap_or_default();
                        text = text.replace(&format!("<{name}>"), value);
                    }
                    text
                };
                let mut steps = background.clone();
                for step in &c.steps {
                    let mut step = step.clone();
                    step.text = substitute(&step.text);
                    for cells in &mut step.table {
                        for cell in cells.iter_mut() {
                            *cell = substitute(cell);
                        }
                    }
                    steps.push(step);
                }
                let mut tags = c.tags.clone();
                tags.extend(example_tags.iter().cloned());
                scenarios.push(Scenario {
                    file: file.to_owned(),
                    name: format!("{} [{}]", c.name, row.join(", ")),
                    tags,
                    steps,
                });
            }
        }
    };

    for (index, raw) in text.split('\n').enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('@') {
            pending.extend(line.split_whitespace().map(str::to_owned));
            continue;
        }
        if line.starts_with("Feature:") {
            feature_tags = std::mem::take(&mut pending);
            into = Into::Nowhere;
        } else if line.starts_with("Rule:") {
            flush(
                &mut current,
                &mut scenarios,
                &feature_background,
                &rule_background,
            );
            in_rule = true;
            rule_tags = std::mem::take(&mut pending);
            rule_background.clear();
            into = Into::Nowhere;
        } else if line.starts_with("Background:") {
            flush(
                &mut current,
                &mut scenarios,
                &feature_background,
                &rule_background,
            );
            into = if in_rule {
                Into::RuleBackground
            } else {
                Into::FeatureBackground
            };
            in_examples = false;
        } else if [
            "Scenario Outline:",
            "Scenario Template:",
            "Scenario:",
            "Example:",
        ]
        .iter()
        .any(|k| line.starts_with(k))
        {
            flush(
                &mut current,
                &mut scenarios,
                &feature_background,
                &rule_background,
            );
            let colon = line.find(':').unwrap_or(0);
            let mut tags = feature_tags.clone();
            tags.extend(rule_tags.iter().cloned());
            tags.append(&mut pending);
            current = Some(Current {
                name: line[colon + 1..].trim().to_owned(),
                tags,
                steps: Vec::new(),
                outline: line.starts_with("Scenario Outline:")
                    || line.starts_with("Scenario Template:"),
                examples: Vec::new(),
            });
            into = Into::Scenario;
            in_examples = false;
        } else if line.starts_with("Examples:") || line.starts_with("Scenarios:") {
            if let Some(c) = current.as_mut() {
                c.examples.push((std::mem::take(&mut pending), Vec::new()));
                in_examples = true;
            }
            into = Into::Nowhere;
        } else if line.starts_with('|') {
            if in_examples {
                if let Some((_, table)) = current.as_mut().and_then(|c| c.examples.last_mut()) {
                    table.push(cells(line));
                }
            } else {
                let steps = match into {
                    Into::FeatureBackground => Some(&mut feature_background),
                    Into::RuleBackground => Some(&mut rule_background),
                    Into::Scenario => current.as_mut().map(|c| &mut c.steps),
                    Into::Nowhere => None,
                };
                if let Some(step) = steps.and_then(|s| s.last_mut()) {
                    step.table.push(cells(line));
                }
            }
        } else if let Some((keyword, rest)) = step_keyword(line) {
            let steps = match into {
                Into::FeatureBackground => Some(&mut feature_background),
                Into::RuleBackground => Some(&mut rule_background),
                Into::Scenario => current.as_mut().map(|c| &mut c.steps),
                Into::Nowhere => None,
            };
            if let Some(steps) = steps {
                if keyword != "And" && keyword != "But" {
                    outcome = keyword == "Then";
                }
                steps.push(Step {
                    text: rest.to_owned(),
                    table: Vec::new(),
                    line: index + 1,
                    outcome,
                });
            }
        }
        // Anything else is a description.
    }
    flush(
        &mut current,
        &mut scenarios,
        &feature_background,
        &rule_background,
    );
    scenarios
}

/// `^(Given|When|Then|And|But|\*)\s+(.*)$`
fn step_keyword(line: &str) -> Option<(&str, &str)> {
    for keyword in ["Given", "When", "Then", "And", "But", "*"] {
        if let Some(rest) = line.strip_prefix(keyword)
            && rest.starts_with(char::is_whitespace)
        {
            return Some((keyword, rest.trim_start()));
        }
    }
    None
}

/// Qt's `QRegularExpression::fromWildcard` without path rules: `*` is any
/// run of characters (`/` too), `?` any one, `[...]` a class; the whole text
/// must match.
pub fn wildcard(glob: &str, text: &str) -> bool {
    let glob: Vec<char> = glob.chars().collect();
    let text: Vec<char> = text.chars().collect();
    matches(&glob, &text)
}

fn matches(glob: &[char], text: &[char]) -> bool {
    match glob.first() {
        None => text.is_empty(),
        Some('*') => (0..=text.len()).any(|skip| matches(&glob[1..], &text[skip..])),
        Some('?') => !text.is_empty() && matches(&glob[1..], &text[1..]),
        Some('[') => {
            let Some(end) = glob.iter().skip(2).position(|&c| c == ']').map(|p| p + 2) else {
                return text.first() == Some(&'[') && matches(&glob[1..], &text[1..]);
            };
            let Some(&c) = text.first() else { return false };
            let class = &glob[1..end];
            let (negated, class) = match class.first() {
                Some('!') | Some('^') => (true, &class[1..]),
                _ => (false, class),
            };
            let mut hit = false;
            let mut i = 0;
            while i < class.len() {
                if i + 2 < class.len() && class[i + 1] == '-' {
                    hit |= class[i] <= c && c <= class[i + 2];
                    i += 3;
                } else {
                    hit |= class[i] == c;
                    i += 1;
                }
            }
            hit != negated && matches(&glob[end + 1..], &text[1..])
        }
        Some(&g) => text.first() == Some(&g) && matches(&glob[1..], &text[1..]),
    }
}

/// Every `.feature` file under `dir`, relative to it, sorted.
fn feature_files(dir: &Path) -> Vec<String> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(root, &path, out);
            } else if path.extension().is_some_and(|e| e == "feature")
                && let Ok(relative) = path.strip_prefix(root)
            {
                out.push(relative.to_string_lossy().replace('\\', "/"));
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort();
    out
}

/// Which scenarios a run is for.
pub struct Selection<'a> {
    pub surface: &'a str,
    /// Only `@backlog` and `@backlog-<surface>` scenarios, instead of none of them.
    pub backlog: bool,
}

/// The scenarios under `features_dir` of the files `globs` names, as
/// desktop-qt's `collectScenarios`: a glob may name scenarios after a colon
/// (`navigation/appearance.feature:System*`), and a scenario must carry
/// `@<surface>` or `@shared`, not `@dropped` or `@blocked`; backlog ones are
/// left out, or with `backlog` are the only ones kept.
pub fn collect(features_dir: &Path, globs: &[String], selection: &Selection) -> Vec<Scenario> {
    // Each file, with the scenario names wanted from it (none: all of them).
    let mut files: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for relative in feature_files(features_dir) {
        for glob in globs {
            let (file_glob, name) = match glob.find(':') {
                Some(colon) => (&glob[..colon], Some(&glob[colon + 1..])),
                None => (glob.as_str(), None),
            };
            if !wildcard(file_glob, &relative) {
                continue;
            }
            let names = files.entry(relative.clone()).or_default();
            match name {
                None => {
                    names.clear();
                    break;
                }
                Some(name) => names.push(name.to_owned()),
            }
        }
    }
    let surface_tag = format!("@{}", selection.surface);
    let backlog_tag = format!("@backlog-{}", selection.surface);
    let mut scenarios = Vec::new();
    for (file, names) in files {
        let path: PathBuf = features_dir.join(&file);
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        for scenario in parse(&file, &text) {
            if !names.is_empty() && !names.iter().any(|n| wildcard(n, &scenario.name)) {
                continue;
            }
            let has = |tag: &str| scenario.tags.iter().any(|t| t == tag);
            // `@shared` is `@desktop @mobile @tui` (features/README.md).
            if !has(&surface_tag) && !has("@shared") {
                continue;
            }
            if has("@dropped") || has("@blocked") {
                continue;
            }
            let backlog = has("@backlog") || has(&backlog_tag);
            if backlog != selection.backlog {
                continue;
            }
            scenarios.push(scenario);
        }
    }
    scenarios
}
