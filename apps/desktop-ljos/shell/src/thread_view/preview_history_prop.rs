//! The pages a new browser tab suggests ([`PreviewHistory`]), over any order
//! of visits, removals and the device saving and reading them back:
//! desktop-qt's tst_PreviewHistoryProp. Each project lists every tidy
//! address once, the newest first, a visit no newer than what is kept
//! changes nothing, a page taken off comes back only with a later visit, a
//! tab only showing a page it loaded before neither moves nor retimes it,
//! the pages kept before visits were timed sit below every visit, a project
//! keeps its fifty newest pages and the device the twenty projects used
//! last, and what is saved reads back as it was.

use proptest::prelude::*;

use super::{PAGES_PER_PROJECT, PROJECTS_KEPT, PreviewHistory, TIMED_SINCE, tidy};

/// An address as a tab reports it, and the one it is kept under.
#[derive(Clone, Debug)]
struct Address {
    url: String,
    tidy: String,
}

fn addresses() -> Vec<Address> {
    let mut all = Vec::new();
    let hosts = [
        ("localhost", "localhost"),
        ("127.0.0.1", "localhost"),
        ("example.com", "example.com"),
        ("user:secret@example.com", "example.com"),
    ];
    let paths = [
        ("", ""),
        ("/", ""),
        ("/docs", "/docs"),
        ("/docs?page=2", "/docs?page=2"),
    ];
    for scheme in ["http", "https"] {
        for (host, tidy_host) in hosts {
            for port in ["", ":5173"] {
                for (path, tidy_path) in paths {
                    all.push(Address {
                        url: format!("{scheme}://{host}{port}{path}"),
                        tidy: format!("{scheme}://{tidy_host}{port}{tidy_path}"),
                    });
                }
            }
        }
    }
    // Not a page a tab is kept for.
    for url in ["ftp://example.com/docs", "about:blank"] {
        all.push(Address {
            url: url.into(),
            tidy: String::new(),
        });
    }
    all
}

fn project_key(n: usize) -> String {
    format!("env-a:project-{n}")
}

#[derive(Clone, Debug, Default)]
struct Entry {
    url: String,
    title: String,
    at: i64,
    titled: i64,
    removed: bool,
    /// When it was put in place.
    seq: u64,
}

#[derive(Clone, Debug, Default)]
struct Project {
    key: String,
    used: i64,
    seq: u64,
    entries: Vec<Entry>,
}

struct Model {
    /// The one used last first.
    projects: Vec<Project>,
    /// Pages kept untimed are older.
    now: i64,
    seq: u64,
}

impl Model {
    fn new() -> Model {
        Model {
            projects: Vec::new(),
            now: TIMED_SINCE + 1000,
            seq: 0,
        }
    }

    fn find(&mut self, key: &str) -> Option<&mut Project> {
        self.projects.iter_mut().find(|p| p.key == key)
    }

    /// Newest first, the last put in place first on a tie; the newest fifty
    /// pages, fifty pages taken off, and none taken off before a full
    /// list's oldest.
    fn order(project: &mut Project) {
        project
            .entries
            .sort_by(|a, b| b.at.cmp(&a.at).then(b.seq.cmp(&a.seq)));
        let (mut pages, mut removed) = (0, 0);
        let mut kept: Vec<Entry> = Vec::new();
        for entry in &project.entries {
            let keep = if entry.removed {
                removed += 1;
                removed <= PAGES_PER_PROJECT
            } else {
                pages += 1;
                pages <= PAGES_PER_PROJECT
            };
            if keep {
                kept.push(entry.clone());
            }
        }
        if pages >= PAGES_PER_PROJECT {
            let oldest = kept
                .iter()
                .filter(|e| !e.removed)
                .nth(PAGES_PER_PROJECT - 1)
                .map_or(0, |e| e.at);
            kept.retain(|e| !(e.removed && e.at < oldest));
        }
        project.entries = kept;
    }

    fn put(seq: &mut u64, project: &mut Project, mut entry: Entry) {
        project.entries.retain(|kept| kept.url != entry.url);
        *seq += 1;
        entry.seq = *seq;
        project.entries.push(entry);
        Model::order(project);
    }

    fn visit(&mut self, key: &str, address: &Address, title: &str, at: i64) {
        if address.tidy.is_empty() {
            return;
        }
        let mut project = self.find(key).cloned().unwrap_or(Project {
            key: key.into(),
            used: at,
            ..Project::default()
        });
        let mut entry = Entry {
            url: address.tidy.clone(),
            title: title.into(),
            at,
            titled: at,
            ..Entry::default()
        };
        for known in project.entries.iter().filter(|k| k.url == address.tidy) {
            if at < known.at || (known.removed && at == known.at) {
                return;
            }
            if title.is_empty() && !known.removed {
                entry.title.clone_from(&known.title);
            }
        }
        Model::put(&mut self.seq, &mut project, entry);
        project.used = project.used.max(at);
        self.seq += 1;
        project.seq = self.seq;
        self.projects.retain(|kept| kept.key != key);
        self.projects.push(project);
        self.projects
            .sort_by(|a, b| b.used.cmp(&a.used).then(b.seq.cmp(&a.seq)));
        self.projects.truncate(PROJECTS_KEPT);
    }

    fn seen(&mut self, key: &str, address: &Address, title: &str, at: i64) {
        if address.tidy.is_empty() {
            return;
        }
        if let Some(project) = self.find(key)
            && let Some(known) = project.entries.iter_mut().find(|k| k.url == address.tidy)
        {
            if !known.removed && !title.is_empty() && title != known.title && at >= known.titled {
                title.clone_into(&mut known.title);
                known.titled = at;
            }
            return;
        }
        self.visit(key, address, title, at);
    }

    fn remove(&mut self, key: &str, address: &Address, at: i64) {
        let Model { projects, seq, .. } = self;
        let Some(project) = projects.iter_mut().find(|p| p.key == key) else {
            return;
        };
        if address.tidy.is_empty() {
            return;
        }
        let Some(known) = project
            .entries
            .iter()
            .find(|k| k.url == address.tidy && !k.removed)
            .map(|k| k.at)
        else {
            return;
        };
        let removed = at.max(known);
        let entry = Entry {
            url: address.tidy.clone(),
            at: removed,
            titled: removed,
            removed: true,
            ..Entry::default()
        };
        Model::put(seq, project, entry);
    }
}

fn check(model: &Model, history: &PreviewHistory) -> Result<(), TestCaseError> {
    let keys: Vec<String> = model.projects.iter().map(|p| p.key.clone()).collect();
    prop_assert_eq!(history.projects(), keys);
    for project in &model.projects {
        let expected: Vec<String> = project
            .entries
            .iter()
            .filter(|e| !e.removed)
            .map(|e| format!("{} {} {}", e.url, e.title, e.at))
            .collect();
        let kept: Vec<String> = history
            .pages(&project.key)
            .iter()
            .map(|p| format!("{} {} {}", p.url, p.title, p.at))
            .collect();
        prop_assert_eq!(kept, expected);
    }
    // Pages of a project not kept are forgotten.
    prop_assert!(history.pages(&project_key(99)).is_empty());
    Ok(())
}

#[derive(Clone, Debug)]
enum Action {
    /// A tab of a project loads a page, some time around the last.
    Visit {
        project: usize,
        address: usize,
        title: &'static str,
        delta: i64,
    },
    /// A tab shows a page it loaded before: listed again, resized, or its
    /// back and forward changed. `kept` picks, mostly, a page the model
    /// keeps.
    Seen {
        project: usize,
        address: usize,
        title: &'static str,
        delta: i64,
        kept: Option<usize>,
    },
    /// The device kept recent pages before it kept them per project.
    Untimed { project: usize, pages: Vec<usize> },
    /// The user takes a page off a project's list.
    Remove {
        project: usize,
        address: usize,
        delta: i64,
    },
    /// A project's tab goes through many pages, one a tick.
    Browse { project: usize, pages: usize },
    /// The device saves the history and reads it back, as a restart does.
    Reload,
}

fn title() -> impl Strategy<Value = &'static str> {
    prop_oneof![Just(""), Just("Docs"), Just("Home")]
}

fn action(count: usize) -> impl Strategy<Value = Action> {
    prop_oneof![
        3 => (0..24usize, 0..count, title(), -3..4i64).prop_map(|(project, address, title, delta)| {
            Action::Visit { project, address, title, delta }
        }),
        2 => (0..24usize, 0..count, title(), -3..4i64, prop::option::weighted(0.75, any::<usize>()))
            .prop_map(|(project, address, title, delta, kept)| Action::Seen {
                project, address, title, delta, kept,
            }),
        1 => (0..24usize, prop::collection::vec(0..count, 0..11))
            .prop_map(|(project, pages)| Action::Untimed { project, pages }),
        1 => (0..24usize, 0..count, -3..2i64)
            .prop_map(|(project, address, delta)| Action::Remove { project, address, delta }),
        1 => (0..24usize, 1..60usize).prop_map(|(project, pages)| Action::Browse { project, pages }),
        1 => Just(Action::Reload),
    ]
}

fn browsed(n: usize) -> Address {
    let url = format!("http://localhost:5173/p{n}");
    Address {
        url: url.clone(),
        tidy: url,
    }
}

fn step(
    all: &[Address],
    model: &mut Model,
    history: &mut PreviewHistory,
    action: &Action,
) -> Result<(), TestCaseError> {
    match action {
        Action::Visit {
            project,
            address,
            title,
            delta,
        } => {
            let (key, address, at) = (project_key(*project), &all[*address], model.now + delta);
            let changed = history.visit(&key, &address.url, title, at);
            if address.tidy.is_empty() {
                prop_assert!(!changed);
            }
            model.now = model.now.max(at);
            model.visit(&key, address, title, at);
        }
        Action::Seen {
            project,
            address,
            title,
            delta,
            kept,
        } => {
            let mut target = (*project, &all[*address]);
            let known: Vec<(usize, &Address)> = (0..24)
                .flat_map(|n| {
                    let key = project_key(n);
                    model
                        .projects
                        .iter()
                        .filter(move |p| p.key == key)
                        .flat_map(|p| &p.entries)
                        .flat_map(move |e| {
                            all.iter().filter(|a| a.tidy == e.url).map(move |a| (n, a))
                        })
                })
                .collect();
            if let Some(pick) = kept
                && !known.is_empty()
            {
                target = known[pick % known.len()];
            }
            let (key, address, at) = (project_key(target.0), target.1, model.now + delta);
            let places = |h: &PreviewHistory| -> Vec<String> {
                h.pages(&key)
                    .iter()
                    .map(|p| format!("{} {}", p.url, p.at))
                    .collect()
            };
            let before = places(history);
            let projects = history.projects();
            history.seen(&key, &address.url, title, at);
            // A page kept, or taken off, keeps its time and its place, and
            // so does its project.
            let kept_already = model
                .projects
                .iter()
                .any(|p| p.key == key && p.entries.iter().any(|e| e.url == address.tidy));
            if kept_already {
                prop_assert_eq!(places(history), before);
                prop_assert_eq!(history.projects(), projects);
            }
            model.now = model.now.max(at);
            model.seen(&key, address, title, at);
        }
        Action::Untimed { project, pages } => {
            let key = project_key(*project);
            let urls: Vec<String> = pages.iter().map(|&n| all[n].url.clone()).collect();
            history.keep_untimed(&key, &urls);
            // Below every page visited since visits were timed.
            let mut untimed = false;
            for page in history.pages(&key) {
                if page.at < TIMED_SINCE {
                    untimed = true;
                } else {
                    prop_assert!(!untimed, "a timed page sits below an untimed one");
                }
            }
            for (n, &page) in pages.iter().enumerate().rev() {
                model.visit(&key, &all[page], "", (pages.len() - n) as i64);
            }
        }
        Action::Remove {
            project,
            address,
            delta,
        } => {
            let (key, address, at) = (project_key(*project), &all[*address], model.now + delta);
            history.remove(&key, &address.url, at);
            model.remove(&key, address, at);
        }
        Action::Browse { project, pages } => {
            let key = project_key(*project);
            for n in 0..*pages {
                model.now += 1;
                history.visit(&key, &browsed(n).url, "", model.now);
                model.visit(&key, &browsed(n), "", model.now);
            }
        }
        Action::Reload => {
            let saved = history.to_json();
            *history = PreviewHistory::from_json(Some(&saved));
            prop_assert_eq!(history.to_json(), saved);
        }
    }
    check(model, history)
}

proptest! {
    #[test]
    fn an_address_is_kept_under_its_tidy_form(at in 0..addresses().len()) {
        let address = &addresses()[at];
        prop_assert_eq!(tidy(&address.url), address.tidy.clone());
        prop_assert_eq!(tidy(&tidy(&address.url)), address.tidy.clone());
    }

    #[test]
    fn the_history_follows_its_model(actions in prop::collection::vec(action(addresses().len()), 1..40)) {
        let all = addresses();
        let mut model = Model::new();
        let mut history = PreviewHistory::default();
        for action in &actions {
            step(&all, &mut model, &mut history, action)?;
        }
    }
}
