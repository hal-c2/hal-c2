//! ThreadPullRequests' core: the URL and number forms the link field takes
//! (ThreadPullRequestLinkSteps, features/pull-requests/), the tab's
//! replies, and a state machine of link, unlink and refresh against a
//! simulated MC.

use ljos::prelude::Value;
use proptest::prelude::*;
use serde_json::json;

use super::super::rows::{Mirror, RowSource};
use super::{
    Effect, Json, Note, PullRequests, Repositories, Shown, Target, Then, key_of, parse_url,
    resolve, shown,
};

const ENVIRONMENT: &str = "env-a";

fn thread(id: &str) -> String {
    format!("{ENVIRONMENT}:{id}")
}

fn target(host: &str, repository: &str, number: i64, url: &str) -> Option<Target> {
    Some(Target {
        host: host.into(),
        repository: repository.into(),
        number,
        url: url.into(),
    })
}

#[test]
fn a_url_names_its_host_repository_and_number() {
    let cases = [
        (
            "https://github.com/Acme/App/pull/12",
            target(
                "github.com",
                "acme/app",
                12,
                "https://github.com/Acme/App/pull/12",
            ),
        ),
        (
            "  https://github.com/acme/app/pull/12/files  ",
            target(
                "github.com",
                "acme/app",
                12,
                "https://github.com/acme/app/pull/12/files",
            ),
        ),
        (
            "https://codeberg.org/acme/app/pulls/3",
            target(
                "codeberg.org",
                "acme/app",
                3,
                "https://codeberg.org/acme/app/pulls/3",
            ),
        ),
        // Forgejo keeps a port that is not the scheme's.
        (
            "http://git.local:3000/acme/app/pulls/3",
            target(
                "git.local:3000",
                "acme/app",
                3,
                "http://git.local:3000/acme/app/pulls/3",
            ),
        ),
        (
            "https://git.local:443/acme/app/pulls/3",
            target(
                "git.local",
                "acme/app",
                3,
                "https://git.local:443/acme/app/pulls/3",
            ),
        ),
        (
            "https://gitlab.com/group/sub/app/-/merge_requests/9",
            target(
                "gitlab.com",
                "group/sub/app",
                9,
                "https://gitlab.com/group/sub/app/-/merge_requests/9",
            ),
        ),
        (
            "https://bitbucket.org/acme/app/pull-requests/4",
            target(
                "bitbucket.org",
                "acme/app",
                4,
                "https://bitbucket.org/acme/app/pull-requests/4",
            ),
        ),
        (
            "https://dev.azure.com/Org/Proj/_git/Repo/pullrequest/5",
            target(
                "dev.azure.com",
                "org/proj/_git/repo",
                5,
                "https://dev.azure.com/Org/Proj/_git/Repo/pullrequest/5",
            ),
        ),
    ];
    for (url, want) in cases {
        assert_eq!(parse_url(url), want, "{url}");
    }
    for url in [
        "ftp://github.com/acme/app/pull/1",
        "https://github.com/acme/app/pull/0",
        "https://github.com/acme/app/pull/99999999999",
        "https://github.com/acme/app/issues/1",
        "https://example.com/acme/app/pull-requests/1",
        "not a url",
        "#12",
    ] {
        assert_eq!(parse_url(url), None, "{url}");
    }
}

fn repositories() -> Repositories {
    Repositories {
        readable: vec![
            ("github.com".into(), "acme/app".into()),
            ("dev.azure.com".into(), "org/proj/_git/repo".into()),
        ],
        own: ("github.com".into(), "acme/app".into()),
    }
}

#[test]
fn the_link_field_takes_a_url_or_a_number_of_the_threads_own_repository() {
    let mine = repositories();
    assert_eq!(
        resolve("#7", &mine),
        Ok(Target {
            host: "github.com".into(),
            repository: "acme/app".into(),
            number: 7,
            url: "https://github.com/acme/app/pull/7".into(),
        })
    );
    assert_eq!(resolve(" 7 ", &mine).map(|t| t.number), Ok(7));
    // Any repository on a host a project reads.
    assert_eq!(
        resolve("https://github.com/other/lib/pull/3", &mine).map(|t| t.repository),
        Ok("other/lib".into())
    );
    // Azure DevOps reads only the repositories it has a checkout of,
    // however they are reached.
    assert!(
        resolve(
            "https://org.visualstudio.com/proj/_git/repo/pullrequest/2",
            &mine
        )
        .is_ok()
    );
    assert!(
        resolve(
            "https://dev.azure.com/org/proj/_git/repo/pullrequest/2",
            &mine
        )
        .is_ok()
    );
    assert!(
        resolve(
            "https://dev.azure.com/org/proj/_git/other/pullrequest/2",
            &mine
        )
        .is_err()
    );

    assert_eq!(
        resolve("  ", &mine),
        Err("Paste a pull request URL or enter 123 / #123.".into())
    );
    assert_eq!(
        resolve("#0", &mine),
        Err("Use a pull request URL, 123, or #123.".into())
    );
    assert_eq!(
        resolve("twelve", &mine),
        Err("Use a pull request URL, 123, or #123.".into())
    );
    assert_eq!(
        resolve("https://gitlab.com/acme/app/-/merge_requests/1", &mine),
        Err("No project in this environment can read gitlab.com/acme/app.".into())
    );
    let elsewhere = Repositories {
        own: Default::default(),
        ..mine
    };
    assert_eq!(
        resolve("#7", &elsewhere),
        Err("Paste a full URL to link a pull request from another repository.".into())
    );
}

fn link(number: i64, snapshot: Json) -> Json {
    let mut link = json!({
        "host": "github.com",
        "repository": "acme/app",
        "number": number,
        "url": format!("https://github.com/acme/app/pull/{number}"),
        "source": "manual",
    });
    if !snapshot.is_null() {
        link["snapshot"] = snapshot;
    }
    link
}

fn online(links: Vec<Json>) -> Shown {
    Shown {
        links,
        online: true,
        notice: String::new(),
        project_id: "p1".into(),
    }
}

#[test]
fn a_row_shows_what_the_host_last_said() {
    let synced = json!({
        "host": "GitHub.com",
        "repository": "Acme/App",
        "number": 4,
        "url": "https://github.com/acme/app/pull/4",
        "source": "stack",
        "stack": {"layers": [{"number": 3}, {"number": 4}, {"number": 5}]},
        "snapshot": {
            "title": "Speed up",
            "state": "open",
            "isDraft": true,
            "checksState": "failing",
            "reviewDecision": "changes-requested",
            "mergeability": "conflicting",
            "additions": 10,
            "headBranch": "fast",
            "baseBranch": "main",
        },
    });
    let s = |role| shown(&synced, role);
    assert_eq!(key_of(&synced), "github.com/acme/app#4");
    assert_eq!(s("state"), Value::from("draft"));
    assert_eq!(s("stateLabel"), Value::from("Draft"));
    assert_eq!(s("checksLabel"), Value::from("Checks failing"));
    assert_eq!(s("reviewLabel"), Value::from("Changes requested"));
    assert_eq!(s("conflicting"), Value::Bool(true));
    assert_eq!(s("additions"), Value::Int(10));
    assert_eq!(s("deletions"), Value::Int(-1));
    assert_eq!(s("branches"), Value::from("fast → main"));
    assert_eq!(s("sourceLabel"), Value::from("Found in the stack"));
    assert_eq!(s("stackLabel"), Value::from("Layer 2 of 3"));
    assert_eq!(s("unlinkLabel"), Value::from("Dismiss from thread"));

    let waiting = link(9, Json::Null);
    assert_eq!(shown(&waiting, "state"), Value::from("unknown"));
    assert_eq!(
        shown(&waiting, "stateLabel"),
        Value::from("Waiting for host state")
    );
    assert_eq!(shown(&waiting, "stackLabel"), Value::from(""));
    assert_eq!(
        shown(&waiting, "unlinkLabel"),
        Value::from("Unlink from thread")
    );
}

#[test]
fn a_thread_shows_its_links_and_a_sync_redraws_them_in_place() {
    let mut prs = PullRequests::new();
    let mut mirror = Mirror::of(&mut prs);
    prs.set_thread(
        &thread("t1"),
        online(vec![
            link(1, Json::Null),
            link(2, json!({"state": "merged"})),
            json!({"host": "github.com", "repository": "acme/app", "number": 3, "source": "stack-dismissed"}),
        ]),
    );
    let notes = prs.take_notes();
    assert!(notes.contains(&Note::Count) && notes.contains(&Note::Project));
    mirror.follow(&mut prs);
    assert_eq!(mirror.resets, 1);
    assert_eq!(prs.count(), 2, "a dismissed stack layer is not shown");
    assert_eq!(prs.open_count(), 1, "one not synced yet counts as open");
    assert_eq!(prs.index_of("github.com/acme/app#2"), Some(1));
    assert_eq!(prs.state(1), "merged");

    prs.set_thread(
        &thread("t1"),
        online(vec![
            link(1, json!({"state": "open"})),
            link(2, json!({"state": "merged"})),
        ]),
    );
    let notes = prs.take_notes();
    assert!(!notes.contains(&Note::Count));
    mirror.follow(&mut prs);
    assert_eq!(mirror.resets, 1, "the same rows change in place");
    assert_eq!(mirror.redrawn.len(), 2);

    // The store saying the same again changes nothing.
    prs.set_thread(
        &thread("t1"),
        online(vec![
            link(1, json!({"state": "open"})),
            link(2, json!({"state": "merged"})),
        ]),
    );
    assert!(prs.take_notes().is_empty());
    assert!(prs.take_changes().is_empty());
}

fn dispatched(prs: &mut PullRequests) -> Vec<(Json, Then)> {
    prs.take_effects()
        .into_iter()
        .filter_map(|e| match e {
            Effect::Dispatch {
                environment,
                command,
                then,
            } => {
                assert_eq!(environment, ENVIRONMENT);
                Some((command, then))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn linking_dispatches_the_link_and_a_refusal_is_the_problem() {
    let mut prs = PullRequests::new();
    prs.set_thread(&thread("t1"), online(vec![]));
    prs.set_link_open(true);
    prs.link("nope", &repositories());
    assert_eq!(prs.problem(), "Use a pull request URL, 123, or #123.");
    assert!(dispatched(&mut prs).is_empty());

    prs.link("#7", &repositories());
    assert!(prs.linking());
    assert_eq!(prs.problem(), "");
    let [(command, then)] = dispatched(&mut prs).try_into().unwrap();
    assert_eq!(
        command,
        json!({
            "type": "thread.pull-request.link",
            "threadId": "t1",
            "host": "github.com",
            "repository": "acme/app",
            "number": 7,
            "url": "https://github.com/acme/app/pull/7",
            "source": "manual",
        })
    );
    // One at a time.
    prs.link("#8", &repositories());
    assert!(dispatched(&mut prs).is_empty());

    prs.answer(then.clone(), Err("no such pull request".into()));
    assert!(!prs.linking());
    assert_eq!(
        prs.problem(),
        "Could not link the pull request: no such pull request"
    );
    assert!(prs.link_open(), "the field stays open to correct it");

    prs.link("#7", &repositories());
    let [(_, then)] = dispatched(&mut prs).try_into().unwrap();
    prs.answer(then, Ok(json!({})));
    assert!(!prs.link_open(), "a link landed closes the field");
}

#[test]
fn a_link_in_flight_does_not_follow_to_another_thread() {
    let mut prs = PullRequests::new();
    prs.set_thread(&thread("t1"), online(vec![]));
    prs.link("#7", &repositories());
    let [(_, then)] = dispatched(&mut prs).try_into().unwrap();
    prs.set_thread(&thread("t2"), online(vec![]));
    assert!(!prs.linking(), "the next thread can link at once");
    prs.link("#8", &repositories());
    assert!(prs.linking());
    let _ = dispatched(&mut prs);
    // The first thread's answer is not the second's.
    prs.answer(then, Err("late".into()));
    assert!(prs.linking());
    assert_eq!(prs.problem(), "");
}

#[test]
fn unlinking_a_stack_layer_or_a_link_dispatches_the_unlink() {
    let mut prs = PullRequests::new();
    prs.set_thread(&thread("t1"), online(vec![link(5, Json::Null)]));
    prs.unlink("github.com/acme/app#6");
    assert!(dispatched(&mut prs).is_empty());
    prs.unlink("github.com/acme/app#5");
    let [(command, then)] = dispatched(&mut prs).try_into().unwrap();
    assert_eq!(
        command,
        json!({
            "type": "thread.pull-request.unlink",
            "threadId": "t1",
            "host": "github.com",
            "repository": "acme/app",
            "number": 5,
        })
    );
    prs.answer(then, Err("gone".into()));
    assert_eq!(
        prs.take_effects(),
        vec![Effect::Notify {
            title: "Could not unlink pull request #5".into(),
            description: "gone".into(),
        }]
    );
}

#[test]
fn the_projects_open_pull_requests_leave_out_the_linked_ones() {
    let mut prs = PullRequests::new();
    prs.set_thread(&thread("t1"), online(vec![link(1, Json::Null)]));
    prs.load_project(false);
    let effects = prs.take_effects();
    let [
        Effect::Call {
            method: "pullRequests.list",
            payload,
            then,
            ..
        },
    ] = effects.as_slice()
    else {
        panic!("{effects:?}");
    };
    assert_eq!(
        *payload,
        json!({"state": "open", "involvement": "all", "projectId": "p1", "limit": 50})
    );
    // Once per thread.
    prs.load_project(false);
    assert!(prs.take_effects().is_empty());
    let entry = |n: i64| {
        json!({
            "host": "GitHub.com", "repository": "acme/app", "number": n,
            "title": format!("PR {n}"), "author": {"login": "ada"},
            "headBranch": "b", "baseBranch": "main", "isDraft": n == 2,
            "url": format!("https://github.com/acme/app/pull/{n}"),
        })
    };
    prs.answer(then.clone(), Ok(json!({"entries": [entry(1), entry(2)]})));
    assert_eq!(
        prs.project_open(),
        vec![json!({
            "key": "github.com/acme/app#2",
            "number": 2,
            "title": "PR 2",
            "author": "ada",
            "branches": "b → main",
            "draft": true,
            "url": "https://github.com/acme/app/pull/2",
        })]
    );
    // Unlinking 1 brings it back.
    prs.take_notes();
    prs.set_thread(&thread("t1"), online(vec![]));
    assert!(prs.take_notes().contains(&Note::Project));
    assert_eq!(prs.project_open().len(), 2);

    // A failed read is the problem, and is tried again.
    prs.load_project(true);
    let effects: [Effect; 1] = prs.take_effects().try_into().unwrap();
    let [Effect::Call { then, .. }] = effects else {
        panic!("a list call");
    };
    prs.answer(then, Err("rate limited".into()));
    assert_eq!(prs.project_problem(), "rate limited");
    prs.load_project(false);
    assert_eq!(prs.take_effects().len(), 1);
}

#[test]
fn a_refresh_reads_every_link_again_and_tells_a_failure_once() {
    let mut prs = PullRequests::new();
    prs.set_thread(
        &thread("t1"),
        online(vec![link(1, Json::Null), link(2, Json::Null)]),
    );
    prs.refresh();
    assert!(prs.refreshing());
    let thens: Vec<Then> = prs
        .take_effects()
        .into_iter()
        .filter_map(|e| match e {
            Effect::Call {
                method: "pullRequests.invalidate",
                payload,
                then,
                ..
            } => {
                assert!(payload["reference"]["number"].is_i64());
                Some(then)
            }
            _ => None,
        })
        .collect();
    assert_eq!(thens.len(), 2);
    prs.refresh();
    assert!(
        prs.take_effects().iter().all(|e| !matches!(
            e,
            Effect::Call {
                method: "pullRequests.invalidate",
                ..
            }
        )),
        "one refresh at a time"
    );
    prs.answer(thens[0].clone(), Err("offline host".into()));
    prs.answer(thens[1].clone(), Err("offline host".into()));
    assert!(!prs.refreshing());
    assert_eq!(
        prs.take_effects(),
        vec![Effect::Notify {
            title: "Could not refresh pull requests".into(),
            description: "offline host".into(),
        }]
    );
}

#[test]
fn offline_nothing_is_asked() {
    let mut prs = PullRequests::new();
    let shown = Shown {
        online: false,
        ..online(vec![link(1, Json::Null)])
    };
    prs.set_thread(&thread("t1"), shown);
    prs.link("#2", &repositories());
    prs.unlink("github.com/acme/app#1");
    prs.refresh();
    prs.load_project(true);
    assert!(prs.take_effects().is_empty());
    assert!(!prs.linking() && !prs.refreshing());
}

#[test]
fn open_and_copy_take_the_links_page() {
    let mut prs = PullRequests::new();
    prs.set_thread(&thread("t1"), online(vec![link(3, Json::Null)]));
    prs.open("github.com/acme/app#3");
    prs.copy_link("github.com/acme/app#3");
    prs.open("github.com/acme/app#4");
    let page = "https://github.com/acme/app/pull/3".to_owned();
    assert_eq!(
        prs.take_effects(),
        vec![Effect::Open(page.clone()), Effect::Copy(page)]
    );
}

// The state machine: the user links, unlinks, refreshes and switches
// threads while the MC answers in any order, syncs links from the host and
// the environment comes and goes. The store pushes the thread's row to the
// tab each time the MC changes it, as the right panel does.

#[derive(Clone, Debug)]
enum Action {
    Show(usize),
    Link(i64),
    Unlink(usize),
    Refresh,
    /// The MC answers the held call at this index, or refuses it.
    Answer(usize, bool),
    /// The host's state for a link of the thread shown.
    Sync(usize, &'static str),
    Online(bool),
}

fn action() -> impl Strategy<Value = Action> {
    prop_oneof![
        1 => (0..3usize).prop_map(Action::Show),
        3 => (1..6i64).prop_map(Action::Link),
        2 => (0..6usize).prop_map(Action::Unlink),
        2 => Just(Action::Refresh),
        5 => ((0..8usize), prop::bool::weighted(0.75)).prop_map(|(i, ok)| Action::Answer(i, ok)),
        2 => ((0..6usize), prop::sample::select(vec!["open", "merged", "closed"]))
            .prop_map(|(i, s)| Action::Sync(i, s)),
        1 => any::<bool>().prop_map(Action::Online),
    ]
}

/// A call or command the MC holds: what it was for, and the thread shown
/// (and how many times a thread was shown) when it was made.
struct Held {
    then: Then,
    command: Json,
    shown: u64,
}

struct Sim {
    prs: PullRequests,
    mirror: Mirror,
    /// The MC's links, per thread.
    links: [Vec<Json>; 3],
    thread: usize,
    shown: u64,
    online: bool,
    held: Vec<Held>,
    round: u64,
    failed_rounds: Vec<u64>,
    told: Vec<String>,
}

impl Sim {
    fn new() -> Sim {
        let mut prs = PullRequests::new();
        let mirror = Mirror::of(&mut prs);
        let mut sim = Sim {
            prs,
            mirror,
            links: Default::default(),
            thread: 0,
            shown: 0,
            online: true,
            held: Vec::new(),
            round: 0,
            failed_rounds: Vec::new(),
            told: Vec::new(),
        };
        sim.push();
        sim
    }

    fn thread_key(&self) -> String {
        thread(&format!("t{}", self.thread))
    }

    /// The store hands the tab the thread's row.
    fn push(&mut self) {
        let key = self.thread_key();
        if key != self.prs.thread() {
            self.shown += 1;
        }
        let shown = Shown {
            links: self.links[self.thread].clone(),
            online: self.online,
            notice: String::new(),
            project_id: "p1".into(),
        };
        self.prs.set_thread(&key, shown);
        self.pump();
    }

    fn pump(&mut self) {
        for effect in self.prs.take_effects() {
            match effect {
                Effect::Call {
                    environment, then, ..
                } => {
                    assert_eq!(environment, ENVIRONMENT);
                    if let Then::Invalidate { round, .. } = then {
                        self.round = round;
                    }
                    self.held.push(Held {
                        then,
                        command: Json::Null,
                        shown: self.shown,
                    });
                }
                Effect::Dispatch {
                    environment,
                    command,
                    then,
                } => {
                    assert_eq!(environment, ENVIRONMENT);
                    self.held.push(Held {
                        then,
                        command,
                        shown: self.shown,
                    });
                }
                Effect::Notify { title, .. } => self.told.push(title),
                Effect::Open(_) | Effect::Copy(_) => {}
            }
        }
    }

    /// The MC carries out a command it accepted.
    fn apply(&mut self, command: &Json) {
        let thread_id = command["threadId"].as_str().unwrap();
        let at: usize = thread_id[1..].parse().unwrap();
        let number = command["number"].as_i64().unwrap();
        let links = &mut self.links[at];
        let exists = links.iter().any(|l| l["number"] == number);
        match command["type"].as_str().unwrap() {
            "thread.pull-request.link" if !exists => links.push(link(number, Json::Null)),
            "thread.pull-request.unlink" => links.retain(|l| l["number"] != number),
            _ => {}
        }
    }
}

fn step(sim: &mut Sim, action: &Action) -> Result<(), TestCaseError> {
    let count = sim.prs.count();
    let rounds_told = sim
        .told
        .iter()
        .filter(|t| *t == "Could not refresh pull requests")
        .count();
    let (was_online, held) = (sim.online, sim.held.len());
    sim.prs.take_notes();
    match action {
        Action::Show(at) => {
            sim.thread = *at;
            sim.push();
        }
        Action::Link(number) => {
            let mine = repositories();
            sim.prs.link(&format!("#{number}"), &mine);
            sim.pump();
        }
        Action::Unlink(row) => {
            if let Some(key) = sim.prs.keys().get(*row).cloned() {
                sim.prs.unlink(&key);
                sim.pump();
            }
        }
        Action::Refresh => {
            sim.prs.refresh();
            sim.pump();
        }
        Action::Answer(at, ok) => {
            if sim.held.is_empty() {
                return Ok(());
            }
            let held = sim.held.remove(at % sim.held.len());
            let result = if *ok {
                if !held.command.is_null() {
                    sim.apply(&held.command);
                }
                Ok(json!({"entries": []}))
            } else {
                if let Then::Invalidate { round, .. } = held.then
                    && !sim.failed_rounds.contains(&round)
                {
                    sim.failed_rounds.push(round);
                }
                Err("refused".to_owned())
            };
            sim.prs.answer(held.then, result);
            sim.pump();
            sim.push();
        }
        Action::Sync(at, state) => {
            let links = &mut sim.links[sim.thread];
            if let Some(link) = links.get_mut(*at) {
                link["snapshot"] = json!({"state": state, "title": "synced"});
                sim.push();
            }
        }
        Action::Online(online) => {
            sim.online = *online;
            sim.push();
        }
    }
    let notes = sim.prs.take_notes();
    sim.mirror.follow(&mut sim.prs);

    // The rows are the MC's links of the thread shown.
    let want: Vec<String> = sim.links[sim.thread].iter().map(key_of).collect();
    prop_assert_eq!(sim.prs.keys(), want);
    prop_assert!(
        sim.prs.count() == count || notes.contains(&Note::Count),
        "the count changed unsaid"
    );
    // Linking and refreshing are what the MC still holds for this thread.
    let linking = sim
        .held
        .iter()
        .any(|h| h.shown == sim.shown && matches!(h.then, Then::Link { .. }));
    prop_assert_eq!(sim.prs.linking(), linking);
    let refreshing = sim.held.iter().any(|h| {
        h.shown == sim.shown
            && matches!(h.then, Then::Invalidate { round, .. } if round == sim.round)
    });
    prop_assert_eq!(sim.prs.refreshing(), refreshing);
    // A failed refresh is told once.
    let now_told = sim
        .told
        .iter()
        .filter(|t| *t == "Could not refresh pull requests")
        .count();
    prop_assert!(now_told <= rounds_told + 1);
    prop_assert!(now_told <= sim.failed_rounds.len());
    prop_assert!(now_told > 0 || sim.failed_rounds.is_empty());
    // Offline, nothing is asked.
    if !was_online && !sim.online {
        prop_assert!(sim.held.len() <= held, "asked offline");
    }
    let linked: Vec<String> = sim.prs.keys();
    for open in sim.prs.project_open() {
        prop_assert!(!linked.contains(&open["key"].as_str().unwrap_or("").to_owned()));
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// The tab shows the MC's links of the thread shown; linking and
    /// refreshing end when the MC answers, or the thread changes.
    #[test]
    fn the_tab_is_the_mcs_links_of_the_thread_shown(
        actions in prop::collection::vec(action(), 1..60)
    ) {
        let mut sim = Sim::new();
        for action in &actions {
            step(&mut sim, action)?;
        }
    }
}
