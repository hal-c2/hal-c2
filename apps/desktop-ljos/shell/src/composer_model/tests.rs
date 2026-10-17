use serde_json::json;

use super::*;
use crate::keybindings::{Rule, compile};

fn obj(value: Json) -> Obj {
    as_object(&value).clone()
}

fn at(text: &str, cursor: usize) -> Option<(String, String, usize, usize)> {
    trigger(text, cursor as i64).map(|t| (t.kind, t.query, t.start, t.end))
}

fn some(kind: &str, query: &str, start: usize, end: usize) -> Option<(String, String, usize, usize)> {
    Some((kind.into(), query.into(), start, end))
}

#[test]
fn a_slash_at_a_line_start_asks_for_a_command() {
    assert_eq!(at("/mo", 3), some("slash-command", "mo", 0, 3));
    assert_eq!(at("/", 1), some("slash-command", "", 0, 1));
    assert_eq!(at("first\n/plan", 11), some("slash-command", "plan", 6, 11));
    // Not once the command has a space, nor mid-line.
    assert_eq!(at("/model x", 8), None);
    assert_eq!(at("see /model", 10), None);
}

#[test]
fn no_trigger_after_the_caret() {
    assert_eq!(at("\n/", 0), None);
    assert_eq!(at("\n/model", 0), None);
    assert_eq!(at("\n/mo", 3), some("slash-command", "m", 1, 3));
    assert_eq!(at("\n/mo", 4), some("slash-command", "mo", 1, 4));
}

#[test]
fn an_at_sign_asks_for_a_path() {
    assert_eq!(at("look at @src/ma", 15), some("path", "src/ma", 8, 15));
    assert_eq!(at("@", 1), some("path", "", 0, 1));
    // The token is what is before the caret.
    assert_eq!(at("@src/main.rs", 4), some("path", "src", 0, 4));
    assert_eq!(at("mail@host", 9), None);
}

#[test]
fn a_currency_sign_asks_for_a_skill() {
    assert_eq!(at("run $rev", 8), some("skill", "rev", 4, 8));
    assert_eq!(at("€x", 2), some("skill", "x", 0, 2));
    assert_eq!(at("\t$", 2), some("skill", "", 1, 2));
}

#[test]
fn a_hash_asks_for_a_pull_request() {
    assert_eq!(at("fix #12", 7), some("pull-request", "12", 4, 7));
    assert_eq!(at("#", 1), some("pull-request", "", 0, 1));
    assert_eq!(at("#-x", 3), None);
}

#[test]
fn positions_are_utf16_units() {
    // "😀" is two UTF-16 units.
    assert_eq!(at("😀 @a", 5), some("path", "a", 3, 5));
    assert_eq!(utf16_len("😀a"), 3);
    assert_eq!(slice("😀ab", 2, 3), "a");
    assert_eq!(byte_at("😀ab", 1), 0);
    assert_eq!(at("x", 99), None);
}

fn instance(value: Json) -> Instance {
    instances(&[value]).remove(0)
}

fn codex() -> Instance {
    instance(json!({
        "instanceId": "codex",
        "driver": "codex",
        "enabled": true,
        "status": "ready",
        "slashCommands": [
            {"name": "review", "description": "Review the diff"},
            {"name": "compact", "description": "Compact the context"},
            {"name": "init", "input": {"hint": "Write AGENTS.md"}},
            {"name": "status"},
            {"name": "deploy"},
        ],
        "skills": [
            {"name": "deploy", "enabled": true, "shortDescription": "Ship it"},
            {"name": "lint-fix", "enabled": true, "scope": "repo"},
            {"name": "hidden", "enabled": true, "userInvocable": false},
            {"name": "off", "enabled": false},
            {"name": "Deploy", "enabled": true},
        ],
    }))
}

fn labels(items: &[Suggestion]) -> Vec<&str> {
    items.iter().map(|i| i.label.as_str()).collect()
}

fn slash(query: &str, start: usize) -> Trigger {
    Trigger {
        kind: "slash-command".into(),
        query: query.into(),
        start,
        end: start + 1 + query.len(),
    }
}

#[test]
fn the_slash_menu_lists_the_composers_commands_then_the_providers() {
    let codex = codex();
    let items = slash_items(Some(&codex), &slash("", 0), true, true, true);
    assert_eq!(
        labels(&items),
        [
            "/model",
            "/plan",
            "/default",
            "/review",
            "/compact",
            "/init",
            "/status",
            "/skill:deploy",
            "/skill:lint-fix",
        ]
    );
    let init = items.iter().find(|i| i.label == "/init").unwrap();
    assert_eq!(init.description, "Write AGENTS.md");
    assert_eq!(init.replacement, "/init ");
    assert_eq!(init.id, "provider-slash-command:codex:init");
    let status = items.iter().find(|i| i.label == "/status").unwrap();
    assert_eq!(status.description, "Run provider command");
    let lint = items.iter().find(|i| i.label == "/skill:lint-fix").unwrap();
    assert_eq!(lint.description, "repo skill");
    assert_eq!(lint.replacement, "$lint-fix ");
    // The composer's own commands act, not insert.
    assert_eq!(items[0].replacement, "");
}

#[test]
fn the_slash_menu_hides_what_does_not_apply() {
    let codex = codex();
    // No plan mode, a prompt that is not empty: no /plan, /default or /compact.
    let items = slash_items(Some(&codex), &slash("", 0), false, true, false);
    assert!(!labels(&items).contains(&"/plan"));
    assert!(!labels(&items).contains(&"/compact"));
    // Skills not shown in the / menu.
    let items = slash_items(Some(&codex), &slash("", 0), false, false, true);
    assert!(labels(&items).contains(&"/deploy"));
    assert!(!labels(&items).iter().any(|l| l.starts_with("/skill:")));
    // Provider commands only at the very start of the prompt.
    let items = slash_items(Some(&codex), &slash("", 4), false, true, true);
    assert_eq!(labels(&items), ["/model", "/skill:deploy", "/skill:lint-fix"]);
    // No instance: the composer's only.
    let items = slash_items(None, &slash("", 0), true, true, true);
    assert_eq!(labels(&items), ["/model", "/plan", "/default"]);
}

#[test]
fn the_slash_menu_ranks_by_query() {
    let codex = codex();
    let items = slash_items(Some(&codex), &slash("re", 0), true, true, true);
    assert_eq!(labels(&items)[0], "/review");
    // Leading slashes go; descriptions match too ("plan mode").
    let items = slash_items(Some(&codex), &slash("/mod", 0), true, true, true);
    assert_eq!(labels(&items), ["/model", "/plan", "/default"]);
    // "skill" lists every skill; "skill:" narrows them.
    let items = slash_items(Some(&codex), &slash("skill", 0), true, true, true);
    assert_eq!(labels(&items), ["/skill:deploy", "/skill:lint-fix"]);
    let items = slash_items(Some(&codex), &slash("skill:lint", 0), true, true, true);
    assert_eq!(labels(&items), ["/skill:lint-fix"]);
    // A prefix of "skill" keeps every skill, after any better match.
    let items = slash_items(Some(&codex), &slash("sk", 0), true, true, true);
    assert_eq!(labels(&items), ["/skill:deploy", "/skill:lint-fix"]);
    assert!(slash_items(Some(&codex), &slash("zzz", 0), true, true, true).is_empty());
}

#[test]
fn the_skill_menu_lists_invocable_skills_by_query() {
    let codex = codex();
    let all = Trigger {
        kind: "skill".into(),
        ..Trigger::default()
    };
    let items = skill_items(Some(&codex), &all);
    assert_eq!(labels(&items), ["Deploy", "Lint Fix"]);
    assert_eq!(items[0].description, "Ship it");
    assert_eq!(items[0].replacement, "$deploy ");
    let query = Trigger {
        query: "fix".into(),
        ..all.clone()
    };
    assert_eq!(labels(&skill_items(Some(&codex), &query)), ["Lint Fix"]);
    assert!(skill_items(None, &all).is_empty());
}

#[test]
fn paths_become_file_links() {
    let items = path_items(&[("src/main.rs".into(), false), ("docs".into(), true)]);
    assert_eq!(items[0].id, "path:file:src/main.rs");
    assert_eq!(items[0].label, "main.rs");
    assert_eq!(items[0].description, "src");
    assert_eq!(items[0].replacement, "[main.rs](src/main.rs) ");
    assert_eq!(items[1].id, "path:directory:docs");
    assert_eq!(items[1].description, "");
    assert_eq!(path_link("/a b/[x](y)#?.md"), r"[\[x\](y)#?.md](/a%20b/%5Bx%5D%28y%29%23%3F.md) ");
    assert_eq!(path_link("/work/shop/"), "[shop](/work/shop/) ");
}

#[test]
fn scores_prefer_exact_then_prefix_then_boundary() {
    let score = |value: &str| score_query_match(value, "mod", 0, 2, Some(4), Some(6), Some(100), BOUNDARIES);
    assert_eq!(score("mod"), Some(0));
    assert_eq!(score("model"), Some(4));
    assert_eq!(score("set-model"), Some(4 + 4 * 2 + 6));
    assert_eq!(score("xmodel"), Some(6 + 2 + 3));
    assert_eq!(score("m_o_d"), Some(100 + 2 * 3 + 2 + 2));
    assert_eq!(score("dom"), None);
    assert_eq!(score(""), None);
}

#[test]
fn queued_runs_wait_for_their_message() {
    let run = obj(json!({"id": "run-a", "status": "queued", "queuePosition": 0, "userMessageId": "message:a"}));
    let early = queued([&run], |_| None);
    assert!(early.queue.is_empty() && early.waiting.is_empty());
    let message = obj(json!({"id": "message:a", "text": "also update docs"}));
    let later = queued([&run], |id| (id == "message:a").then_some(&message));
    assert_eq!(later.queue, [json!({"runId": "run-a", "text": "also update docs"})]);
}

#[test]
fn queued_runs_go_by_position_and_notices_wait_apart() {
    let runs = [
        obj(json!({"id": "b", "status": "queued", "queuePosition": 1, "userMessageId": "mb"})),
        obj(json!({"id": "a", "status": "queued", "ordinal": 1, "userMessageId": "ma"})),
        obj(json!({"id": "c", "status": "queued", "queuePosition": 0, "userMessageId": "mc"})),
        obj(json!({"id": "d", "status": "running", "userMessageId": "ma"})),
    ];
    let messages = [
        obj(json!({"id": "ma", "text": "A"})),
        obj(json!({"id": "mb", "text": "B"})),
        obj(json!({"id": "mc", "providerWake": true})),
    ];
    let found = |id: &str| messages.iter().find(|m| text(m, "id") == id);
    let q = queued(runs.iter(), found);
    assert_eq!(
        q.queue,
        [json!({"runId": "a", "text": "A"}), json!({"runId": "b", "text": "B"})]
    );
    assert_eq!(q.waiting.len(), 1);
    assert_eq!(q.waiting[0]["runId"], "c");
    assert_eq!(q.waiting[0]["summary"], "Notification");
}

#[test]
fn instances_group_by_driver_with_defaults_first() {
    let list = instances(&[
        json!({"instanceId": "codex_work", "driver": "codex"}),
        json!({"instanceId": "claudeAgent", "driver": "claudeAgent", "displayName": "Claude"}),
        json!({"instanceId": "codex", "driver": "codex", "accentColor": "#12abEF"}),
        json!({"instanceId": "", "driver": "codex"}),
    ]);
    let ids: Vec<_> = list.iter().map(|i| i.instance_id.as_str()).collect();
    assert_eq!(ids, ["codex", "codex_work", "claudeAgent"]);
    assert_eq!(list[1].display_name, "Codex Work");
    assert_eq!(list[2].display_name, "Claude");
    assert_eq!(list[0].accent_color, "#12abEF");
    assert!(list[0].show_interaction_mode_toggle);
    assert_eq!(initials_of("Codex Work"), "CW");
    assert_eq!(initials_of("codex"), "CO");
    assert_eq!(humanize_slug("myCodex-two"), "My Codex Two");
}

#[test]
fn favourites_toggle() {
    let none = json!([]);
    let one = toggle_favorite(&none, "codex", "gpt-a");
    assert_eq!(one, json!([{"provider": "codex", "model": "gpt-a"}]));
    assert_eq!(toggle_favorite(&one, "codex", "gpt-a"), json!([]));
}

#[test]
fn options_take_the_selection_and_apply_only_what_fits() {
    let model = obj(json!({"capabilities": {"optionDescriptors": [
        {"id": "effort", "type": "select", "label": "Effort",
         "options": [{"id": "low"}, {"id": "high", "isDefault": true}, {"id": "ultrathink"}],
         "promptInjectedValues": ["ultrathink"]},
        {"id": "fast", "type": "boolean", "label": "Fast", "currentValue": false},
        {"id": "agent", "type": "select", "options": [{"id": "plan"}]},
    ]}}));
    let shown = descriptors(&model, &[json!({"id": "effort", "value": "low"})], false);
    assert_eq!(shown.len(), 2, "the plan-only agent option goes without plan mode");
    assert_eq!(shown[0]["currentValue"], "low");
    // A prompt-injected choice reads as the default.
    let shown = descriptors(&model, &[json!({"id": "effort", "value": "ultrathink"})], true);
    assert_eq!(shown[0]["currentValue"], "high");
    assert_eq!(shown.len(), 3);

    let options = shell_options(&shown);
    assert_eq!(options[1], json!({"id": "fast", "label": "Fast", "type": "boolean", "value": false, "choices": []}));

    assert_eq!(apply_option(&shown, "effort", &json!("nope")), None);
    assert_eq!(apply_option(&shown, "fast", &json!("yes")), None);
    let next = apply_option(&shown, "fast", &json!(true)).unwrap();
    assert!(next.contains(&json!({"id": "fast", "value": true})));
    assert!(next.contains(&json!({"id": "effort", "value": "high"})));
}

#[test]
fn runtime_modes_follow_the_instance() {
    assert_eq!(runtime_modes(None).len(), 4);
    let limited = instance(json!({"instanceId": "x", "driver": "x", "supportedRuntimeModes": ["auto", "full-access"]}));
    let values: Vec<_> = runtime_modes(Some(&limited))
        .iter()
        .map(|m| m["value"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(values, ["auto", "full-access"]);
}

#[test]
fn enter_sends_by_the_bindings() {
    let bindings: Vec<_> = [
        Rule::new("mod+shift+enter", "composer.sendAlternate", "composerFocus && turnRunning"),
        Rule::new("mod+alt+enter", "composer.sendBackground", "composerFocus && draftThreadRoute"),
    ]
    .iter()
    .filter_map(compile)
    .collect();
    let idle = enter_intents(&bindings, false, "enter", false, false);
    assert_eq!(idle["singleLine"][""], "foreground");
    assert_eq!(idle["singleLine"]["ctrl"], "foreground");
    assert!(idle["singleLine"].get("shift").is_none());
    assert!(idle["singleLine"].get("ctrl+shift").is_none());
    let running = enter_intents(&bindings, false, "enter", false, true);
    assert_eq!(running["singleLine"]["ctrl+shift"], "alternate");
    let draft = enter_intents(&bindings, false, "mod-enter-multiline", true, false);
    assert_eq!(draft["singleLine"][""], "foreground");
    assert!(draft["multiline"].get("").is_none());
    assert_eq!(draft["multiline"]["ctrl"], "foreground");
    assert_eq!(draft["multiline"]["ctrl+alt"], "background");
}

#[test]
fn a_picker_key_is_the_last_binding_with_the_picker_open() {
    let bindings: Vec<_> = [
        Rule::new("mod+1", "modelPicker.jump.1", "modelPickerOpen"),
        Rule::new("mod+1", "other", "modelPickerOpen"),
    ]
    .iter()
    .filter_map(compile)
    .collect();
    assert_eq!(picker_key(&bindings, false, "modelPicker.jump.1"), Json::Null);
    assert_eq!(picker_key(&bindings[..1], false, "modelPicker.jump.1")["ctrlKey"], true);
}

#[test]
fn a_started_thread_on_a_strict_provider_cannot_change_model() {
    let list = instances(&[json!({"instanceId": "c", "driver": "claudeAgent", "requiresNewThreadForModelChange": true})]);
    assert!(block_reason(&list, "c", "a", "c", "b").is_some());
    assert!(block_reason(&list, "c", "a", "c", "a").is_none());
    assert!(block_reason(&list, "c", "a", "d", "b").is_none());
}
