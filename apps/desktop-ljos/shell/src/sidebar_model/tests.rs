//! The sidebar's rules, as desktop-qt's tst_SidebarRegression and the web
//! sidebar's logic tests state them.

use super::*;

const AT: &str = "2026-09-23T09:00:00Z";

fn now() -> i64 {
    parse_iso(Some(AT)).unwrap()
}

fn row(id: &str) -> Map<String, Value> {
    json!({
        "id": id, "projectId": "p1", "title": id, "createdAt": AT, "updatedAt": AT,
    })
    .as_object()
    .cloned()
    .unwrap()
}

fn with(mut row: Map<String, Value>, extra: Value) -> Map<String, Value> {
    for (k, v) in extra.as_object().unwrap() {
        row.insert(k.clone(), v.clone());
    }
    row
}

fn all() -> Capabilities {
    Capabilities {
        settlement: true,
        snooze: true,
        visited_tracking: true,
        pinning: true,
        title_regeneration: true,
    }
}

fn build_all(threads: &[Thread]) -> View {
    build(threads, &Input::default(), &None, &|_| all(), now())
}

#[test]
fn snoozed_ties_read_the_same_every_time() {
    let snoozed = |env: &str, id: &str| {
        thread_from_row(
            env,
            &with(row(id), json!({"snoozedUntil": "2026-09-23T12:00:00Z"})),
        )
    };
    let own = snoozed("env-a", "t2");
    let peer = snoozed("b", "t1");
    let expected = vec!["b:t1".to_owned(), "env-a:t2".to_owned()];
    assert_eq!(
        build_all(&[own.clone(), peer.clone()]).ordered_keys,
        expected
    );
    assert_eq!(build_all(&[peer, own]).ordered_keys, expected);
}

#[test]
fn a_rows_age_is_not_its_last_tidy_up() {
    let message = "2026-09-23T06:00:00Z";
    let settled_at = "2026-09-23T07:00:00Z";
    let pinned = with(
        row("t1"),
        json!({"latestUserMessageAt": message, "pinnedAt": AT}),
    );
    let settled = with(
        row("t2"),
        json!({"latestUserMessageAt": message, "settledOverride": "settled", "settledAt": settled_at}),
    );
    let view = build_all(&[
        thread_from_row("env-a", &pinned),
        thread_from_row("env-a", &settled),
        thread_from_row("env-a", &row("t3")),
    ]);
    let time_at = |section: &str| {
        view.state[section][0]["timeAt"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    assert_eq!(time_at("pinned"), message);
    assert_eq!(time_at("settled"), settled_at);
    // A thread nobody has written in yet has only its update time.
    assert_eq!(time_at("active"), AT);
}

#[test]
fn a_row_reads_its_run_and_pending_request() {
    let thread = thread_from_row(
        "env",
        &with(
            row("t"),
            json!({
                "status": "running", "latestRunId": "r1", "activeRunId": "r1",
                "latestRunStartedAt": "2026-09-23T08:55:00Z",
                "lineage": {"relationshipToParent": "subagent"},
                "pendingRuntimeRequest": {"kind": "approval"},
                "plugin": {"id": "slack", "kind": "dm", "listed": false},
            }),
        ),
    );
    assert_eq!(thread.interaction_mode, "default");
    assert!(thread.subagent);
    assert!(!thread.listed);
    assert_eq!(thread.plugin_id, "slack");
    assert!(thread.has_pending_approvals && !thread.has_pending_user_input);
    let run = thread.latest_run.as_ref().unwrap();
    assert_eq!(run.status, "running");
    assert_eq!(run.completed_at, None);
    assert_eq!(status(&thread), "approval");

    let working = Thread {
        has_pending_approvals: false,
        ..thread
    };
    assert_eq!(status(&working), "working");
    assert_eq!(status_label(&working).as_deref(), Some("Working"));
    assert_eq!(working_label(&working, now()), "5m");
}

#[test]
fn an_idle_row_from_before_completion_stamps_closes_at_its_update() {
    let thread = thread_from_row("env", &with(row("t"), json!({"latestRunId": "r1"})));
    let run = thread.latest_run.unwrap();
    assert_eq!(run.status, "completed");
    assert_eq!(run.completed_at.as_deref(), Some(AT));
    assert_eq!(thread.runtime.unwrap().status, "idle");
}

#[test]
fn statuses_by_runtime() {
    let of = |extra: Value| status(&thread_from_row("e", &with(row("t"), extra)));
    assert_eq!(of(json!({})), "ready");
    assert_eq!(
        of(json!({"latestRunId": "r", "status": "queued"})),
        "working"
    );
    assert_eq!(of(json!({"latestRunId": "r", "status": "idle"})), "waiting");
    assert_eq!(
        of(json!({"latestRunId": "r", "status": "failed", "lastErrorClass": "usage_limit"})),
        "limited"
    );
    assert_eq!(
        of(json!({"latestRunId": "r", "status": "failed"})),
        "failed"
    );
    assert_eq!(
        of(json!({"pendingRuntimeRequest": {"kind": "user_input"}})),
        "input"
    );
    assert_eq!(
        of(json!({"pendingRuntimeRequest": {"kind": "auth_refresh"}})),
        "ready"
    );
    assert_eq!(most_urgent_status(&["failed", "working", "input"]), "input");
    assert_eq!(most_urgent_status(&[]), "ready");
}

#[test]
fn completed_is_unread_only_after_a_visit_before_it() {
    let base = json!({"latestRunId": "r", "latestRunCompletedAt": "2026-09-23T08:00:00Z"});
    let visited = |at: Value| {
        let mut extra = base.clone();
        extra["lastVisitedAt"] = at;
        thread_from_row("e", &with(row("t"), extra))
    };
    assert!(unread(&visited("2026-09-23T07:00:00Z".into())));
    assert!(!unread(&visited("2026-09-23T08:30:00Z".into())));
    // Never visited: nothing to compare against.
    assert!(!unread(&visited(Value::Null)));
    assert!(unread(&visited("garbage".into())));
    assert_eq!(
        status_label(&visited("2026-09-23T07:00:00Z".into())).as_deref(),
        Some("Completed")
    );
}

#[test]
fn sections_follow_capabilities_and_hide_what_is_not_listed() {
    let threads = [
        thread_from_row(
            "e",
            &with(
                row("snoozed"),
                json!({"snoozedUntil": "2026-09-23T10:00:00Z"}),
            ),
        ),
        thread_from_row(
            "e",
            &with(row("settled"), json!({"settledOverride": "settled"})),
        ),
        thread_from_row("e", &with(row("pinned"), json!({"pinnedAt": AT}))),
        thread_from_row("e", &row("active")),
        thread_from_row("e", &with(row("archived"), json!({"archivedAt": AT}))),
        thread_from_row(
            "e",
            &with(
                row("sub"),
                json!({"lineage": {"relationshipToParent": "subagent"}}),
            ),
        ),
        thread_from_row(
            "e",
            &with(
                row("unlisted"),
                json!({"plugin": {"id": "x", "listed": false}}),
            ),
        ),
        thread_from_row("other", &row("scoped-out")),
    ];
    let ids = |list: &[Thread]| list.iter().map(|t| t.id.clone()).collect::<Vec<_>>();
    let scope: HashSet<String> = ["e:p1".to_owned()].into();
    let sections = partition(&threads, Some(&scope), &|_| all(), now());
    assert_eq!(ids(&sections.snoozed), ["snoozed"]);
    assert_eq!(ids(&sections.settled), ["settled"]);
    assert_eq!(ids(&sections.pinned), ["pinned"]);
    assert_eq!(ids(&sections.active), ["active"]);
    // An environment without the capabilities never shelves a thread.
    let none = partition(&threads, Some(&scope), &|_| Capabilities::default(), now());
    assert_eq!(ids(&none.active).len(), 3);
    assert!(none.snoozed.is_empty() && none.settled.is_empty());
}

#[test]
fn a_snoozed_thread_wakes_when_it_raises_its_hand() {
    let snoozed =
        json!({"snoozedUntil": "2026-09-23T12:00:00Z", "snoozedAt": "2026-09-23T08:00:00Z"});
    let quiet = thread_from_row("e", &with(row("t"), snoozed.clone()));
    assert!(effective_snoozed(&quiet, now()));
    assert_eq!(woke_at(&quiet, now()), None);
    assert_eq!(wake_label("2026-09-23T12:00:00Z", now()), "3h");
    assert_eq!(wake_label("2026-09-23T09:00:30Z", now()), "1m");
    assert_eq!(wake_label("garbage", now()), "now");

    let mut done = snoozed.clone();
    done["latestRunId"] = "r".into();
    done["latestRunCompletedAt"] = "2026-09-23T08:30:00Z".into();
    let done = thread_from_row("e", &with(row("t"), done));
    assert!(!effective_snoozed(&done, now()));
    assert_eq!(
        woke_at(&done, now()).as_deref(),
        Some("2026-09-23T08:30:00Z")
    );

    // A run that finished before the snooze does not wake it.
    let mut old = snoozed.clone();
    old["latestRunId"] = "r".into();
    old["latestRunCompletedAt"] = "2026-09-23T07:00:00Z".into();
    assert!(effective_snoozed(
        &thread_from_row("e", &with(row("t"), old)),
        now()
    ));

    // Malformed data never hides a thread; a past wake shows until visited.
    let past = with(row("t"), json!({"snoozedUntil": "2026-09-23T08:00:00Z"}));
    let past = thread_from_row("e", &past);
    assert!(!effective_snoozed(&past, now()));
    assert_eq!(
        visible_woke_at(&past, now()).as_deref(),
        Some("2026-09-23T08:00:00Z")
    );
    let seen = Thread {
        last_visited_at: Some("2026-09-23T08:30:00Z".into()),
        ..past.clone()
    };
    assert_eq!(visible_woke_at(&seen, now()), None);
    let settled = Thread {
        settled_override: Some("settled".into()),
        ..past
    };
    assert_eq!(visible_woke_at(&settled, now()), None);
}

#[test]
fn a_thread_with_a_queued_turn_cannot_snooze() {
    let fresh = thread_from_row(
        "e",
        &with(
            row("t"),
            json!({"latestUserMessageAt": "2026-09-23T08:59:00Z"}),
        ),
    );
    assert!(has_queued_turn_start(&fresh, now()));
    assert!(!can_snooze(&fresh, now()));
    let stale = thread_from_row(
        "e",
        &with(
            row("t"),
            json!({"latestUserMessageAt": "2026-09-23T08:00:00Z"}),
        ),
    );
    assert!(can_snooze(&stale, now()));
}

#[test]
fn pinned_and_active_order_by_their_keys_then_by_age() {
    let threads = [
        thread_from_row(
            "e",
            &with(row("old"), json!({"createdAt": "2026-09-20T00:00:00Z"})),
        ),
        thread_from_row("e", &with(row("keyed-b"), json!({"activeOrderKey": "n"}))),
        thread_from_row("e", &with(row("keyed-a"), json!({"activeOrderKey": "d"}))),
        thread_from_row("e", &row("new")),
        thread_from_row("e", &with(row("pin-new"), json!({"pinnedAt": AT}))),
        thread_from_row(
            "e",
            &with(
                row("pin-keyed"),
                json!({"pinnedAt": AT, "pinOrderKey": "m", "createdAt": "2026-09-01T00:00:00Z"}),
            ),
        ),
    ];
    assert_eq!(
        build_all(&threads).ordered_keys,
        [
            "e:pin-keyed",
            "e:pin-new",
            "e:new",
            "e:old",
            "e:keyed-a",
            "e:keyed-b"
        ]
    );
}

#[test]
fn the_settled_shelf_stops_at_its_limit_but_keeps_the_open_thread() {
    let threads: Vec<Thread> = (0..SETTLED_PAGE + 5)
        .map(|n| {
            let at = format!("2026-09-{:02}T00:00:00Z", 1 + n % 20);
            thread_from_row(
                "e",
                &with(
                    row(&format!("t{n:03}")),
                    json!({"settledOverride": "settled", "settledAt": at}),
                ),
            )
        })
        .collect();
    let last = build_all(&threads).ordered_keys.last().unwrap().clone();
    let input = Input {
        active_thread_key: Some(last.clone()),
        ..Input::default()
    };
    let view = build(&threads, &input, &None, &|_| all(), now());
    let shown = view.state["settled"].as_array().unwrap();
    assert_eq!(view.state["settledTotal"], SETTLED_PAGE + 5);
    assert_eq!(shown.len(), SETTLED_PAGE + 1);
    assert_eq!(shown.last().unwrap()["key"], last.as_str());
    assert_eq!(view.parked_keys.len(), SETTLED_PAGE + 5);
}

fn settled(id: &str, extra: Value) -> Thread {
    thread_from_row("e", &with(row(id), with_settled(extra)))
}

fn with_settled(extra: Value) -> Value {
    let mut base = json!({"settledOverride": "settled", "settledAt": AT});
    for (k, v) in extra.as_object().unwrap() {
        base[k] = v.clone();
    }
    base
}

fn reviews() -> Value {
    json!({"plugin": {"id": "code-review", "kind": "review", "listed": true}})
}

fn settled_titles(view: &View) -> Vec<String> {
    view.state["settled"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["key"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn the_settled_shelf_lists_the_limit_it_is_given_and_says_its_page() {
    let threads: Vec<Thread> = (0..7)
        .map(|n| settled(&format!("t{n}"), json!({})))
        .collect();
    let input = Input {
        settled_limit: 5,
        settled_page: 3,
        ..Input::default()
    };
    let view = build(&threads, &input, &None, &|_| all(), now());
    assert_eq!(settled_titles(&view).len(), 5);
    assert_eq!(view.state["settledTotal"], 7);
    assert_eq!(view.state["settledPage"], 3);
    assert_eq!(build_all(&threads).state["settledPage"], SETTLED_PAGE);
}

#[test]
fn settled_plugin_threads_stay_out_of_the_shelf_and_its_count_unless_asked() {
    let threads = [
        settled("own", json!({})),
        settled("review-1", reviews()),
        settled("review-2", reviews()),
    ];
    let hidden = build_all(&threads);
    assert_eq!(settled_titles(&hidden), ["e:own"]);
    assert_eq!(hidden.state["settledTotal"], 1);
    // Nor are they rows to move through or to select.
    assert_eq!(hidden.ordered_keys, ["e:own"]);

    let shown = build(
        &threads,
        &Input {
            show_settled_plugin_threads: true,
            ..Input::default()
        },
        &None,
        &|_| all(),
        now(),
    );
    assert_eq!(shown.state["settledTotal"], 3);
    assert_eq!(settled_titles(&shown).len(), 3);
}

#[test]
fn the_open_settled_plugin_thread_stays_listed() {
    let threads = [settled("own", json!({})), settled("review-1", reviews())];
    let input = Input {
        active_thread_key: Some("e:review-1".into()),
        ..Input::default()
    };
    let view = build(&threads, &input, &None, &|_| all(), now());
    assert_eq!(settled_titles(&view).len(), 2);
    assert_eq!(view.state["settledTotal"], 2);
}

#[test]
fn plugin_threads_are_hidden_before_the_shelf_pages() {
    // Three of five are the plugin's: a page of two still fills with the user's.
    let threads = [
        settled("a", json!({"settledAt": "2026-09-23T08:05:00Z"})),
        settled("r1", with_settled(reviews())),
        settled("b", json!({"settledAt": "2026-09-23T08:04:00Z"})),
        settled("r2", with_settled(reviews())),
        settled("r3", with_settled(reviews())),
    ];
    let input = Input {
        settled_limit: 2,
        settled_page: 2,
        ..Input::default()
    };
    let view = build(&threads, &input, &None, &|_| all(), now());
    assert_eq!(settled_titles(&view), ["e:a", "e:b"]);
    assert_eq!(view.state["settledTotal"], 2);
}

#[test]
fn rows_carry_their_project_offline_state_and_selection() {
    let projects = [project_from_row(
        "e",
        &json!({"id": "p1", "title": "Shop", "workspaceRoot": "/w/shop", "updatedAt": AT})
            .as_object()
            .unwrap()
            .clone(),
    )];
    let threads = [
        thread_from_row("e", &with(row("t1"), json!({"branch": "main"}))),
        thread_from_row(
            "e",
            &with(row("t2"), json!({"latestRunId": "r", "status": "running"})),
        ),
    ];
    let groups = group_projects(&projects, &GroupingSettings::default(), "e", &threads);
    let input = Input {
        projects: groups,
        local_environment_id: Some("e".into()),
        offline_environments: ["e".to_owned()].into(),
        selected_keys: ["e:t2".to_owned(), "e:gone".to_owned()].into(),
        jump_labels: vec!["Ctrl+1".into()],
        show_jump_hints: true,
        describe_wake: Some(Box::new(|u: &str| format!("at {u}"))),
        ..Input::default()
    };
    let view = build(&threads, &input, &None, &|_| all(), now());
    let state = &view.state;
    assert_eq!(state["projects"][0]["displayName"], "Shop");
    assert_eq!(state["projects"][0]["threadCount"], 2);
    assert_eq!(state["projects"][0]["status"], "working");
    assert_eq!(state["localProjects"][0]["key"], "e:p1");
    assert_eq!(state["selectedKeys"], json!(["e:t2"]));
    let first = &state["active"][0];
    assert_eq!(first["projectKey"], "e:/w/shop");
    assert_eq!(first["offline"], true);
    assert_eq!(first["canSettle"], false);
    assert_eq!(first["jumpLabel"], "Ctrl+1");
    assert_eq!(state["active"][1]["jumpLabel"], Value::Null);
    assert_eq!(first["preview"]["project"], "Shop");
}

fn project(env: &str, id: &str, root: &str, extra: Value) -> Project {
    let base =
        json!({"id": id, "title": id, "workspaceRoot": root, "createdAt": AT, "updatedAt": AT});
    project_from_row(env, &with(base.as_object().unwrap().clone(), extra))
}

#[test]
fn projects_group_by_repository_across_machines() {
    let identity = |root: &str| json!({"repositoryIdentity": {"canonicalKey": "github.com/me/shop", "rootPath": root, "name": "shop"}});
    let projects = [
        project("a", "p1", "/w/shop", identity("/w/shop")),
        project("b", "p2", "/home/b/shop/", identity("/home/b/shop")),
        project("b", "p3", "/home/b/shop/web", identity("/home/b/shop")),
        project("a", "p4", "/w/other", json!({})),
    ];
    let by = |mode: &str| {
        let settings = GroupingSettings {
            mode: mode.into(),
            sort_order: "manual".into(),
            ..GroupingSettings::default()
        };
        group_projects(&projects, &settings, "b", &[])
            .into_iter()
            .map(|g| (g.key, g.member_keys))
            .collect::<Vec<_>>()
    };
    assert_eq!(
        by("repository"),
        [
            (
                "github.com/me/shop".to_owned(),
                vec!["a:p1".to_owned(), "b:p2".into(), "b:p3".into()]
            ),
            ("a:/w/other".to_owned(), vec!["a:p4".to_owned()]),
        ]
    );
    let paths = by("repository_path");
    assert_eq!(paths[0].1, ["a:p1", "b:p2"]);
    assert_eq!(paths[1].0, "github.com/me/shop::web");
    assert_eq!(by("separate").len(), 4);

    let groups = group_projects(&projects, &GroupingSettings::default(), "b", &[]);
    let shop = groups
        .iter()
        .find(|g| g.key == "github.com/me/shop")
        .unwrap();
    // The preferred environment represents; differing titles fall back to the name.
    assert_eq!(shop.summary["environmentId"], "b");
    assert_eq!(shop.summary["displayName"], "shop");
}

#[test]
fn a_folder_override_beats_the_mode() {
    let projects = [project(
        "a",
        "p1",
        "/w/shop",
        json!({"repositoryIdentity": {"canonicalKey": "k", "rootPath": "/w/shop"}}),
    )];
    let settings = GroupingSettings {
        overrides: [("a:/w/shop".to_owned(), "separate".to_owned())].into(),
        ..GroupingSettings::default()
    };
    assert_eq!(
        group_projects(&projects, &settings, "", &[])[0].key,
        "a:/w/shop"
    );
}

#[test]
fn projects_sort_by_their_latest_thread() {
    let projects = [
        project(
            "e",
            "p1",
            "/one",
            json!({"updatedAt": "2026-09-01T00:00:00Z"}),
        ),
        project(
            "e",
            "p2",
            "/two",
            json!({"updatedAt": "2026-09-10T00:00:00Z"}),
        ),
    ];
    let threads = [thread_from_row(
        "e",
        &with(
            row("t"),
            json!({"projectId": "p1", "latestUserMessageAt": "2026-09-20T00:00:00Z"}),
        ),
    )];
    let order = |sort: &str| {
        let settings = GroupingSettings {
            sort_order: sort.into(),
            ..GroupingSettings::default()
        };
        group_projects(&projects, &settings, "", &threads)
            .into_iter()
            .map(|g| g.key)
            .collect::<Vec<_>>()
    };
    assert_eq!(order("updated_at"), ["e:/one", "e:/two"]);
    assert_eq!(order("manual"), ["e:/one", "e:/two"]);
    assert_eq!(most_recent_project(&projects, &threads).unwrap().id, "p1");
    assert_eq!(most_recent_project(&projects, &[]).unwrap().id, "p2");
}

#[test]
fn windows_paths_fold() {
    assert_eq!(normalize_path(" C:/Work/Shop/ "), "c:\\work\\shop");
    assert_eq!(normalize_path("C:\\"), "c:\\");
    assert_eq!(normalize_path("/work/shop//"), "/work/shop");
    assert_eq!(normalize_path("/"), "/");
}

#[test]
fn a_deleted_thread_falls_back_to_its_projects_latest() {
    let threads = [
        thread_from_row("e", &row("gone")),
        thread_from_row(
            "e",
            &with(row("older"), json!({"updatedAt": "2026-09-01T00:00:00Z"})),
        ),
        thread_from_row(
            "e",
            &with(
                row("newer"),
                json!({"latestUserMessageAt": "2026-09-22T00:00:00Z", "updatedAt": "2026-09-01T00:00:00Z"}),
            ),
        ),
        thread_from_row("e", &with(row("archived"), json!({"archivedAt": AT}))),
        thread_from_row("e", &with(row("elsewhere"), json!({"projectId": "p2"}))),
    ];
    assert_eq!(
        fallback_after_delete(&threads, "e:gone", "updated_at").as_deref(),
        Some("e:newer")
    );
    assert_eq!(
        fallback_after_delete(&threads, "e:elsewhere", "updated_at"),
        None
    );
    assert_eq!(
        fallback_after_delete(&threads, "e:missing", "updated_at"),
        None
    );
}

#[test]
fn order_keys_sit_between_their_neighbours() {
    assert_eq!(order_key_between(None, None).as_deref(), Some("n"));
    for (a, b) in [
        (None, Some("b")),
        (Some("y"), None),
        (Some("m"), Some("n")),
        (Some("az"), Some("b")),
    ] {
        let key = order_key_between(a, b).unwrap();
        assert!(valid_order_key(&key), "{key}");
        assert!(a.is_none_or(|a| a < key.as_str()), "{a:?} < {key}");
        assert!(b.is_none_or(|b| key.as_str() < b), "{key} < {b:?}");
    }
    assert_eq!(order_key_between(Some("n"), Some("m")), None);
    assert_eq!(order_key_between(Some("na"), None), None);
    let spread = spread_order_keys(30);
    assert_eq!(spread.len(), 30);
    assert!(spread.windows(2).all(|w| w[0] < w[1]));
    assert!(spread.iter().all(|k| valid_order_key(k)));
}

#[test]
fn a_move_between_keyed_neighbours_writes_one_key() {
    let ordered: Vec<String> = ["x", "moved", "y"].map(String::from).into();
    let keys: HashMap<String, Nullable> = [
        ("x".to_owned(), Some("d".to_owned())),
        ("moved".to_owned(), Some("t".to_owned())),
        ("y".to_owned(), Some("h".to_owned())),
        ("hidden".to_owned(), Some("f".to_owned())),
    ]
    .into();
    let plan = plan_reorder(&ordered, &keys, "moved");
    assert_eq!(plan.len(), 1);
    let key = &plan[0].order_key;
    assert!(
        "d" < key.as_str() && key.as_str() < "h" && key != "f",
        "{key}"
    );
}

#[test]
fn a_move_next_to_a_keyless_neighbour_respreads_the_section() {
    let ordered: Vec<String> = ["a", "moved", "b"].map(String::from).into();
    let keys: HashMap<String, Nullable> = [
        ("a".to_owned(), None),
        ("moved".to_owned(), None),
        ("b".to_owned(), Some("m".to_owned())),
    ]
    .into();
    let plan = plan_reorder(&ordered, &keys, "moved");
    let mut assigned: HashMap<String, String> =
        plan.into_iter().map(|a| (a.key, a.order_key)).collect();
    for key in &ordered {
        assigned
            .entry(key.clone())
            .or_insert_with(|| keys[key].clone().unwrap());
    }
    assert!(assigned["a"] < assigned["moved"] && assigned["moved"] < assigned["b"]);
    assert!(plan_reorder(&ordered, &keys, "absent").is_empty());
}

#[test]
fn custom_snoozes_read_durations_and_local_dates() {
    let now = Utc.timestamp_millis_opt(now()).unwrap();
    let duration = |amount: &str, unit: &str| {
        resolve_custom_snooze(
            &CustomSnooze {
                mode: "duration".into(),
                amount: amount.into(),
                unit: unit.into(),
                ..CustomSnooze::default()
            },
            now,
            &Utc,
        )
    };
    assert_eq!(
        duration("1.5", "hours").as_deref(),
        Some("2026-09-23T10:30:00.000Z")
    );
    assert_eq!(
        duration("2", "days").as_deref(),
        Some("2026-09-25T09:00:00.000Z")
    );
    assert_eq!(duration("0", "hours"), None);
    assert_eq!(duration("nope", "hours"), None);

    let oslo = FixedOffset::east_opt(2 * 3600).unwrap();
    let date = |date: &str, time: &str| {
        resolve_custom_snooze(
            &CustomSnooze {
                mode: "date".into(),
                date: date.into(),
                time: time.into(),
                ..CustomSnooze::default()
            },
            now,
            &oslo,
        )
    };
    assert_eq!(
        date("2026-09-25", "08:30").as_deref(),
        Some("2026-09-25T06:30:00.000Z")
    );
    assert_eq!(date("2026-09-23", "10:00"), None, "in the past");
    assert_eq!(date("2026-9-25", "08:30"), None);
    assert_eq!(date("2026-09-25", "25:00"), None);
}

#[test]
fn a_skipped_hour_is_not_a_snooze_time() {
    // A zone that jumps 02:00 -> 03:00 on 2026-03-29, as Europe does.
    #[derive(Clone, Copy, Debug)]
    struct Spring;
    impl chrono::Offset for Spring {
        fn fix(&self) -> FixedOffset {
            FixedOffset::east_opt(3600).unwrap()
        }
    }
    impl TimeZone for Spring {
        type Offset = Spring;
        fn from_offset(_: &Spring) -> Spring {
            Spring
        }
        fn offset_from_local_date(&self, _: &NaiveDate) -> chrono::LocalResult<Spring> {
            chrono::LocalResult::Single(Spring)
        }
        fn offset_from_local_datetime(&self, local: &NaiveDateTime) -> chrono::LocalResult<Spring> {
            let gap = NaiveDate::from_ymd_opt(2026, 3, 29)
                .unwrap()
                .and_hms_opt(2, 0, 0)
                .unwrap();
            if *local >= gap && *local < gap + Duration::hours(1) {
                chrono::LocalResult::None
            } else {
                chrono::LocalResult::Single(Spring)
            }
        }
        fn offset_from_utc_date(&self, _: &NaiveDate) -> Spring {
            Spring
        }
        fn offset_from_utc_datetime(&self, _: &NaiveDateTime) -> Spring {
            Spring
        }
    }
    let now = Utc.with_ymd_and_hms(2026, 3, 1, 0, 0, 0).unwrap();
    let at = |time: &str| {
        resolve_custom_snooze(
            &CustomSnooze {
                mode: "date".into(),
                date: "2026-03-29".into(),
                time: time.into(),
                ..CustomSnooze::default()
            },
            now,
            &Spring,
        )
    };
    assert_eq!(at("02:30"), None);
    assert!(at("03:30").is_some());
}

#[test]
fn presets_step_by_calendar_days() {
    let zone = FixedOffset::east_opt(0).unwrap();
    // A Wednesday morning.
    let now = zone.with_ymd_and_hms(2026, 9, 23, 9, 0, 0).unwrap();
    let presets = snooze_presets(&now, "24-hour");
    let ids: Vec<&str> = presets.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(
        ids,
        ["hour", "three-hours", "evening", "tomorrow", "next-week"]
    );
    assert_eq!(presets[0].when_label, "10:00");
    assert_eq!(presets[2].snoozed_until, "2026-09-23T18:00:00.000Z");
    assert_eq!(presets[3].snoozed_until, "2026-09-24T09:00:00.000Z");
    assert_eq!(presets[4].snoozed_until, "2026-09-28T09:00:00.000Z");
    assert_eq!(presets[4].when_label, "Mon 09:00");

    // Late in the day there is no evening; on a Sunday tomorrow is next week.
    let sunday_night = zone.with_ymd_and_hms(2026, 9, 27, 17, 30, 0).unwrap();
    let ids: Vec<String> = snooze_presets(&sunday_night, "12-hour")
        .into_iter()
        .map(|p| p.id)
        .collect();
    assert_eq!(ids, ["hour", "three-hours", "tomorrow"]);
}

#[test]
fn wake_descriptions_name_the_day() {
    let zone = FixedOffset::east_opt(0).unwrap();
    let now = zone.with_ymd_and_hms(2026, 9, 23, 9, 0, 0).unwrap();
    let describe = |at: &str| wake_description(at, &now, "12-hour");
    assert_eq!(describe("2026-09-23T17:30:00Z"), "5:30 PM");
    assert_eq!(describe("2026-09-24T09:00:00Z"), "tomorrow 9:00 AM");
    assert_eq!(describe("2026-09-28T00:00:00Z"), "Mon 12:00 AM");
    assert_eq!(describe("2026-10-05T09:00:00Z"), "Oct 5, 9:00 AM");
    assert_eq!(describe("nope"), "");
}

#[test]
fn iso_round_trips_through_milliseconds() {
    let ms = parse_iso(Some("2026-09-23T09:00:00.250+02:00")).unwrap();
    assert_eq!(
        format_iso(&Utc.timestamp_millis_opt(ms).unwrap()),
        "2026-09-23T07:00:00.250Z"
    );
    assert_eq!(parse_iso(Some("")), None);
    assert_eq!(parse_iso(Some("yesterday")), None);
}
