//! The Files tab's core: what features/files/file-explorer.feature and
//! file-viewer-and-editing.feature say of searching, opening, editing and
//! saving, and tst_WorkspaceFilesRegression's search and write cases. The
//! listings and the object around the core are in
//! `tests/workspace_files.rs`.

use serde_json::json;

use super::*;

fn files_in(root: &str) -> Files {
    let mut files = Files::new();
    files.set_target("env-a", root);
    files.take_effects();
    files.take_signals();
    files
}

/// The calls the core asked for, as (method, payload, what answers them).
fn calls(files: &mut Files) -> Vec<(&'static str, Json, Then)> {
    files
        .take_effects()
        .into_iter()
        .filter_map(|effect| match effect {
            Effect::Call {
                method,
                payload,
                then,
                ..
            } => Some((method, payload, then)),
            _ => None,
        })
        .collect()
}

fn call(files: &mut Files) -> (&'static str, Json, Then) {
    let mut asked = calls(files);
    assert_eq!(asked.len(), 1, "one call");
    asked.remove(0)
}

fn contents(text: &str) -> Result<Json, String> {
    Ok(json!({"contents": text}))
}

/// `path` opened and read as `text`.
fn opened(files: &mut Files, path: &str, text: &str) {
    assert!(files.open_file(path, 0));
    let (_, _, then) = call(files);
    files.answer(then, contents(text));
    files.take_effects();
    files.take_signals();
}

// --- Search ---

// A query typed with no workspace said a search was on its way, forever.
#[test]
fn a_query_without_a_workspace_is_not_searching() {
    let mut files = Files::new();
    files.set_query("x");
    assert!(!files.facts().searching);
    assert!(calls(&mut files).is_empty());
}

#[test]
fn typing_waits_for_a_pause_and_asks_with_the_query_trimmed() {
    let mut files = files_in("/w");
    files.set_query(" lib ");
    assert!(files.facts().searching);
    assert!(files.take_effects().contains(&Effect::SearchTimer(true)));
    files.search();
    let (method, payload, _) = call(&mut files);
    assert_eq!(method, "projects.searchEntries");
    assert_eq!(
        payload,
        json!({"cwd": "/w", "query": "lib", "limit": SEARCH_LIMIT})
    );
}

#[test]
fn matches_replace_the_tree_and_clearing_the_query_restores_it() {
    let mut files = files_in("/w");
    files.set_query("lib");
    files.search();
    let (_, _, then) = call(&mut files);
    files.answer(
        then,
        Ok(json!({"entries": [{"path": "src/lib.rs", "kind": "file"}], "truncated": true})),
    );
    let facts = files.facts();
    assert!(!facts.searching);
    assert!(facts.search_truncated);
    let shown = files.take_effects();
    assert!(matches!(&shown[..], [Effect::SetSearch(Some(found))] if found.len() == 1));
    files.set_query("");
    assert!(files.take_effects().contains(&Effect::SetSearch(None)));
    assert!(!files.facts().search_truncated);
}

#[test]
fn a_search_that_fails_says_so_and_shows_no_matches() {
    let mut files = files_in("/w");
    files.set_query("x");
    files.search();
    let (_, _, then) = call(&mut files);
    files.answer(then, Err(String::new()));
    assert_eq!(files.facts().search_problem, "Unable to search files.");
    assert!(
        files
            .take_effects()
            .contains(&Effect::SetSearch(Some(Vec::new())))
    );
}

// Typing on while a search is on its way answered the older query.
#[test]
fn an_older_search_answered_late_is_dropped() {
    let mut files = files_in("/w");
    files.set_query("a");
    files.search();
    let (_, _, older) = call(&mut files);
    files.set_query("ab");
    files.take_effects();
    files.answer(older, Ok(json!({"entries": []})));
    assert!(files.facts().searching);
    assert!(files.take_effects().is_empty());
}

// Switching workspace while a search was on its way showed the old
// workspace's matches in the new one.
#[test]
fn a_search_of_the_workspace_left_is_dropped() {
    let mut files = files_in("/w1");
    files.set_query("x");
    files.search();
    let (_, _, then) = call(&mut files);
    assert!(files.set_target("env-a", "/w2"));
    files.take_effects();
    files.answer(
        then,
        Ok(json!({"entries": [{"path": "x", "kind": "file"}]})),
    );
    let facts = files.facts();
    assert!(!facts.searching && facts.query.is_empty());
    assert!(files.take_effects().is_empty());
}

#[test]
fn the_workspace_already_shown_is_not_a_new_one() {
    let mut files = files_in("/w");
    assert!(!files.set_target("env-a", "/w"));
    assert!(files.set_target("env-b", "/w"));
}

#[test]
fn a_reveal_is_not_about_a_search() {
    let mut files = files_in("/w");
    files.set_query("x");
    assert!(files.reveal("src/a.rs"));
    assert_eq!(files.query(), "");
    assert_eq!(files.revealing(), "src/a.rs");
    // The user looking for something else lets go of the file.
    files.set_query("y");
    assert_eq!(files.revealing(), "");
}

#[test]
fn a_file_outside_the_workspace_is_not_revealed() {
    let mut files = files_in("/w");
    assert!(!files.reveal("/etc/hosts"));
    assert!(!files.reveal(""));
}

// --- Opening ---

#[test]
fn nothing_opens_without_a_workspace_or_a_path() {
    let mut files = Files::new();
    assert!(!files.open_file("a.rs", 0));
    let mut files = files_in("/w");
    assert!(!files.open_file("", 0));
    assert!(calls(&mut files).is_empty());
}

#[test]
fn opening_a_file_reads_it_and_shows_its_lines() {
    let mut files = files_in("/w");
    assert!(files.open_file("src/a.rs", 2));
    assert_eq!(files.facts().file_status, "loading");
    let (method, payload, then) = call(&mut files);
    assert_eq!(method, "projects.readFile");
    assert_eq!(payload, json!({"cwd": "/w", "relativePath": "src/a.rs"}));
    files.take_signals();
    files.answer(then, contents("one\ntwo\nthree\n"));
    let facts = files.facts();
    assert_eq!(facts.file_status, "ready");
    // The requested line, clamped to the lines there are.
    assert_eq!(facts.reveal_line, 2);
    assert_eq!(files.text(), "one\ntwo\nthree\n");
    assert!(
        files
            .take_effects()
            .contains(&Effect::Lines("one\ntwo\nthree\n".into()))
    );
    let signals = files.take_signals();
    assert!(signals.contains(&Sig::Rendered) && signals.contains(&Sig::RevealRequested));
}

// A requested line past the end of the file is revealed at the last.
#[test]
fn a_line_past_the_end_is_revealed_at_the_last_line() {
    let mut files = files_in("/w");
    assert!(files.open_file("a.txt", 99));
    let (_, _, then) = call(&mut files);
    files.answer(then, contents("a\nb\n"));
    assert_eq!(files.facts().reveal_line, 2);
}

#[test]
fn opening_the_file_shown_only_goes_to_the_line() {
    let mut files = files_in("/w");
    opened(&mut files, "a.txt", "a\nb\nc\n");
    assert!(files.open_file("a.txt", 3));
    assert!(calls(&mut files).is_empty());
    assert_eq!(files.facts().reveal_line, 3);
    assert!(files.take_signals().contains(&Sig::RevealRequested));
}

#[test]
fn a_file_that_cannot_be_read_says_so_and_can_be_read_again() {
    let mut files = files_in("/w");
    assert!(files.open_file("a.txt", 0));
    let (_, _, then) = call(&mut files);
    files.answer(then, Err(String::new()));
    let facts = files.facts();
    assert_eq!(facts.file_status, "error");
    assert_eq!(facts.file_problem, "Unable to read this file.");
    files.reload_file();
    assert_eq!(files.facts().file_status, "loading");
    assert_eq!(call(&mut files).0, "projects.readFile");
}

// A file read twice, the older answer last, kept the older text.
#[test]
fn an_older_read_answered_late_is_dropped() {
    let mut files = files_in("/w");
    assert!(files.open_file("a.txt", 0));
    let (_, _, older) = call(&mut files);
    files.reload_file();
    let (_, _, newer) = call(&mut files);
    files.answer(newer, contents("new"));
    files.answer(older, contents("old"));
    assert_eq!(files.text(), "new");
}

#[test]
fn a_file_read_after_it_was_closed_is_dropped() {
    let mut files = files_in("/w");
    assert!(files.open_file("a.txt", 0));
    let (_, _, then) = call(&mut files);
    files.close_file();
    files.answer(then, contents("late"));
    let facts = files.facts();
    assert_eq!((facts.file_status, facts.open_path.as_str()), ("none", ""));
    assert_eq!(files.text(), "");
}

#[test]
fn a_part_of_a_file_says_how_much_and_opens_read_only() {
    let mut files = files_in("/w");
    assert!(files.open_file("big.log", 0));
    let (_, _, then) = call(&mut files);
    files.answer(
        then,
        Ok(json!({"contents": "x", "truncated": true, "byteLength": 3_145_728})),
    );
    let facts = files.facts();
    assert_eq!(
        facts.truncated_notice,
        "Preview limited to the first 1 MB of a 3,145,728 byte file."
    );
    assert!(!facts.editable);
    assert_eq!(
        facts.read_only_reason,
        "Files larger than 1 MB open read-only."
    );
}

#[test]
fn an_empty_file_is_marked_empty() {
    let mut files = files_in("/w");
    opened(&mut files, "a.txt", "");
    assert!(files.facts().file_empty);
}

#[test]
fn a_file_outside_the_project_opens_read_only() {
    let mut files = files_in("/w");
    opened(&mut files, "/etc/hosts", "127.0.0.1\n");
    let facts = files.facts();
    assert!(!facts.editable);
    assert_eq!(
        facts.read_only_reason,
        "Files outside the project open read-only."
    );
}

// --- Rendering ---

#[test]
fn markdown_renders_until_the_user_reads_its_source() {
    let mut files = files_in("/w");
    opened(&mut files, "README.md", "- [ ] a\n");
    assert_eq!(files.facts().render_kind, "markdown");
    assert!(files.rendered());
    assert_eq!(files.rendered_text(), "- [☐](task:0) a\n");
    files.set_rendered(false);
    assert!(!files.rendered());
    assert_eq!(files.source_kinds(), ["markdown"]);
    assert!(files.take_signals().contains(&Sig::SourceKinds));
    // The choice is the kind's, not the file's.
    opened(&mut files, "docs/other.md", "x");
    assert!(!files.rendered());
    files.set_rendered(true);
    assert!(files.rendered());
    assert!(files.source_kinds().is_empty());
}

#[test]
fn a_plain_file_has_nothing_to_render() {
    let mut files = files_in("/w");
    opened(&mut files, "src/a.rs", "fn a() {}\n");
    assert_eq!(files.facts().render_kind, "");
    files.set_rendered(false);
    assert!(files.source_kinds().is_empty());
}

#[test]
fn a_table_is_drawn_for_a_csv_file() {
    let mut files = files_in("/w");
    opened(&mut files, "t.csv", "a,b\n1,2\n");
    assert_eq!(
        files.rendered_text(),
        "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
    );
}

#[test]
fn wrap_follows_the_setting_until_the_user_chooses() {
    let mut files = Files::new();
    assert!(!files.wrap());
    files.set_default_wrap(true);
    assert!(files.wrap());
    files.set_wrap(false);
    files.set_default_wrap(true);
    assert!(!files.wrap());
}

// --- Editing and saving ---

fn editing(files: &mut Files, path: &str, text: &str) {
    opened(files, path, text);
    files.set_editing(true);
    files.take_effects();
    files.take_signals();
}

#[test]
fn only_a_file_that_can_be_edited_is_edited() {
    let mut files = files_in("/w");
    files.set_editing(true);
    assert!(!files.facts().editing);
    opened(&mut files, "/etc/hosts", "x");
    files.set_editing(true);
    assert!(!files.facts().editing);
}

#[test]
fn an_edit_is_written_once_the_user_stops_typing() {
    let mut files = files_in("/w");
    editing(&mut files, "a.txt", "one\n");
    files.edit("one\ntwo\n");
    assert!(files.facts().unsaved);
    let effects = files.take_effects();
    assert!(effects.contains(&Effect::SaveTimer(true)));
    assert!(calls(&mut files).is_empty());
    files.save_due();
    let (method, payload, then) = call(&mut files);
    assert_eq!(method, "projects.writeFile");
    assert_eq!(
        payload,
        json!({"cwd": "/w", "relativePath": "a.txt", "contents": "one\ntwo\n"})
    );
    files.answer(then, Ok(json!({})));
    let facts = files.facts();
    assert!(!facts.unsaved && facts.save_problem.is_empty());
}

#[test]
fn typing_on_during_a_write_is_written_after_it() {
    let mut files = files_in("/w");
    editing(&mut files, "a.txt", "");
    files.edit("a");
    files.save_due();
    let (_, _, first) = call(&mut files);
    files.edit("ab");
    // One write at a time.
    files.save_due();
    assert!(calls(&mut files).is_empty());
    files.answer(first, Ok(json!({})));
    assert!(files.facts().unsaved);
    assert!(files.take_effects().contains(&Effect::SaveTimer(true)));
    files.save_due();
    let (_, payload, then) = call(&mut files);
    assert_eq!(payload["contents"], "ab");
    files.answer(then, Ok(json!({})));
    assert!(!files.facts().unsaved);
}

#[test]
fn a_write_the_mc_refuses_keeps_the_edit_and_says_so() {
    let mut files = files_in("/w");
    editing(&mut files, "a.txt", "");
    files.edit("a");
    files.save_due();
    let (_, _, then) = call(&mut files);
    files.take_signals();
    files.answer(then, Err(String::new()));
    let facts = files.facts();
    assert!(facts.unsaved);
    assert_eq!(facts.save_problem, "Unable to save this file.");
    assert_eq!(
        files.take_signals(),
        [Sig::SaveFailed {
            path: "a.txt".into(),
            problem: "Unable to save this file.".into()
        }]
    );
    // The next edit writes both, and clears the complaint.
    files.edit("ab");
    assert!(files.facts().save_problem.is_empty());
    files.save_due();
    assert_eq!(call(&mut files).1["contents"], "ab");
}

// Closing the file writes what was typed first, and a failure is still
// heard of after the file is gone.
#[test]
fn closing_the_file_writes_the_edit_first() {
    let mut files = files_in("/w");
    editing(&mut files, "a.txt", "");
    files.edit("a");
    files.close_file();
    let (method, payload, then) = call(&mut files);
    assert_eq!(method, "projects.writeFile");
    assert_eq!(payload["relativePath"], "a.txt");
    assert!(matches!(&then, Then::Write { closing: true, .. }));
    files.take_signals();
    files.answer(then, Err("disk full".into()));
    assert_eq!(
        files.take_signals(),
        [Sig::SaveFailed {
            path: "a.txt".into(),
            problem: "disk full".into()
        }]
    );
    // Nothing of the file is left to complain on.
    assert!(files.facts().save_problem.is_empty());
}

#[test]
fn leaving_the_workspace_writes_the_edit_there() {
    let mut files = files_in("/w1");
    editing(&mut files, "a.txt", "");
    files.edit("a");
    assert!(files.set_target("env-a", "/w2"));
    let (_, payload, _) = call(&mut files);
    assert_eq!(payload["cwd"], "/w1");
}

#[test]
fn opening_another_file_writes_the_edit_and_stops_editing() {
    let mut files = files_in("/w");
    editing(&mut files, "a.txt", "");
    files.edit("a");
    assert!(files.open_file("b.txt", 0));
    let asked = calls(&mut files);
    assert_eq!(
        asked.iter().map(|c| c.0).collect::<Vec<_>>(),
        ["projects.writeFile", "projects.readFile"]
    );
    assert!(!files.facts().editing);
}

#[test]
fn leaving_the_editor_writes_the_edit_now() {
    let mut files = files_in("/w");
    editing(&mut files, "a.txt", "");
    files.edit("a");
    files.set_editing(false);
    assert_eq!(call(&mut files).0, "projects.writeFile");
}

// Ticking a Markdown task writes the file.
#[test]
fn ticking_a_task_writes_the_file() {
    let mut files = files_in("/w");
    opened(&mut files, "todo.md", "- [ ] a\n- [x] b\n");
    files.toggle_task(0);
    let effects = files.take_effects();
    assert!(effects.contains(&Effect::Lines("- [x] a\n- [x] b\n".into())));
    let write = effects
        .into_iter()
        .find_map(|e| match e {
            Effect::Call { payload, then, .. } => Some((payload, then)),
            _ => None,
        })
        .expect("a write");
    assert_eq!(write.0["contents"], "- [x] a\n- [x] b\n");
    assert_eq!(files.rendered_text(), "- [☑](task:0) a\n- [☑](task:1) b\n");
    files.answer(write.1, Ok(json!({})));
    assert!(!files.facts().unsaved);
}

#[test]
fn a_task_in_a_file_that_is_not_markdown_stays_as_it_is() {
    let mut files = files_in("/w");
    opened(&mut files, "todo.txt", "- [ ] a\n");
    files.toggle_task(0);
    assert_eq!(files.text(), "- [ ] a\n");
    assert!(files.take_effects().is_empty());
}

// --- Following the agent ---

#[test]
fn a_shown_tab_follows_the_workspace_and_a_hidden_one_waits() {
    let mut files = files_in("/w");
    files.set_mutation("m1".into());
    files.set_active(true);
    assert_eq!(files.follow("m1".into()), Followed::Nothing);
    assert_eq!(files.follow("m2".into()), Followed::Refresh);
    files.set_active(false);
    assert_eq!(files.follow("m3".into()), Followed::Nothing);
    assert!(files.take_stale());
    assert!(!files.take_stale());
}

#[test]
fn a_new_thread_starts_from_its_own_mutation() {
    let mut files = files_in("/w");
    files.set_active(false);
    files.follow("m2".into());
    files.set_mutation("m9".into());
    assert!(!files.take_stale());
}

#[test]
fn entries_are_read_from_a_listing() {
    let found = entries_of(&json!({"entries": [
        {"path": "src", "kind": "directory"},
        {"path": "a.log", "kind": "file", "ignored": true},
    ]}));
    assert_eq!(
        found,
        [
            Entry::new("src", true, false),
            Entry::new("a.log", false, true)
        ]
    );
    assert!(entries_of(&json!({})).is_empty());
}
