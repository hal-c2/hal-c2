//! The Files tab's core: what features/files/file-explorer.feature and
//! file-viewer-and-editing.feature say of searching, opening, editing and
//! saving, and tst_WorkspaceFilesRegression's search and write cases. The
//! listings and the object around the core are in
//! `tests/workspace_files.rs`.

use serde_json::json;

use super::*;

fn files_in(root: &str) -> Files {
    let mut files = Files::new();
    files.set_target("env-a", root, "");
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

fn contents(text: &str) -> Result<Json, McError> {
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
    files.answer(then, Err(McError::new("")));
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
    assert!(files.set_target("env-a", "/w2", ""));
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
    assert!(!files.set_target("env-a", "/w", ""));
    assert!(files.set_target("env-b", "/w", ""));
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
    files.answer(then, Err(McError::new("")));
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

// A file outside the workspace is written back by its full path.
#[test]
fn a_file_outside_the_project_is_edited_by_its_full_path() {
    let mut files = files_in("/w");
    editing(&mut files, "/etc/hosts", "127.0.0.1\n");
    assert!(files.facts().editable && files.facts().editing);
    files.edit("127.0.0.1 me\n");
    files.save_due();
    let (method, payload, _) = call(&mut files);
    assert_eq!(method, "projects.writeFile");
    assert_eq!(payload["relativePath"], "/etc/hosts");
}

const REFUSAL: &str = "Saving a file outside the project needs terminal access, which this device was not paired with.";

/// What the MC says to a full-path write from a session without terminal
/// access.
fn terminal_required() -> Result<Json, McError> {
    Err(McError {
        message: "terminal:operate is required".into(),
        detail: json!({
            "_tag": "EnvironmentScopeRequiredError",
            "requiredScope": "terminal:operate",
        }),
    })
}

// tst_WorkspaceFilesRegression: a write by full path refused for want of
// terminal access left the edit pending, and opening a project file next
// wrote that edit into it.
#[test]
fn an_edit_refused_outside_the_workspace_is_not_written_to_the_next_file() {
    let mut files = Files::new();
    files.set_target("env-b", "/w", "");
    editing(&mut files, "/tmp/y.txt", "y\n");
    files.edit("y edited\n");
    files.save_due();
    let (_, _, then) = call(&mut files);
    files.take_signals();
    files.answer(then, terminal_required());
    let facts = files.facts();
    assert_eq!(facts.save_problem, REFUSAL);
    assert!(!facts.editable && !facts.editing && facts.unsaved);
    assert_eq!(facts.read_only_reason, REFUSAL);
    let signals = files.take_signals();
    assert!(signals.contains(&Sig::SaveFailed {
        path: "/tmp/y.txt".into(),
        problem: REFUSAL.into()
    }));
    // The view shows the edit that was not saved, to copy.
    assert!(
        files
            .take_effects()
            .contains(&Effect::Lines("y edited\n".into()))
    );
    assert!(files.open_file("a.txt", 0));
    let asked = calls(&mut files);
    assert_eq!(
        asked.iter().map(|c| c.0).collect::<Vec<_>>(),
        ["projects.readFile"]
    );
}

// Once refused, the environment's other outside files open read-only, its
// project files and other environments' outside files do not.
#[test]
fn a_refusal_makes_that_environments_outside_files_read_only() {
    let mut files = Files::new();
    files.set_target("env-b", "/w", "");
    editing(&mut files, "/tmp/y.txt", "");
    files.edit("y");
    files.save_due();
    let (_, _, then) = call(&mut files);
    files.answer(then, terminal_required());
    opened(&mut files, "/tmp/x.txt", "x");
    assert_eq!(files.facts().read_only_reason, REFUSAL);
    opened(&mut files, "a.txt", "a");
    assert!(files.facts().editable);
    files.set_target("env-a", "/w", "");
    opened(&mut files, "/tmp/x.txt", "x");
    assert!(files.facts().editable);
}

// Any other refusal keeps the file editable, the edit to be written with the
// next one.
#[test]
fn another_refusal_of_an_outside_write_keeps_it_editable() {
    let mut files = files_in("/w");
    editing(&mut files, "/tmp/y.txt", "");
    files.edit("y");
    files.save_due();
    let (_, _, then) = call(&mut files);
    files.answer(then, Err(McError::new("not a text file")));
    let facts = files.facts();
    assert!(facts.editable && facts.editing && facts.unsaved);
    assert_eq!(facts.save_problem, "not a text file");
}

// --- Media ---

const NOW: i64 = 1_790_000_000_000;

/// A Files on "/w" for thread t1, its clock at NOW.
fn media_files() -> Files {
    let mut files = Files::new();
    files.set_context("http://127.0.0.1:3773", NOW);
    files.set_target("env-a", "/w", "t1");
    files.take_effects();
    files.take_signals();
    files
}

/// The signing asked for: (environment, resource, then).
fn signing(files: &mut Files) -> (String, Json, Then) {
    let asked: Vec<_> = files
        .take_effects()
        .into_iter()
        .filter_map(|effect| match effect {
            Effect::Call {
                environment,
                method: "assets.createUrl",
                payload,
                then,
            } => Some((environment, payload["resource"].clone(), then)),
            _ => None,
        })
        .collect();
    assert_eq!(asked.len(), 1, "one signing");
    asked.into_iter().next().expect("a signing")
}

/// A signing's answer: `relative`, good for `seconds`.
fn signed(relative: &str, seconds: i64) -> Result<Json, McError> {
    Ok(json!({"relativeUrl": relative, "expiresAt": NOW + seconds * 1000}))
}

#[test]
fn media_kinds_follow_the_extension() {
    for (path, kind) in [
        ("assets/logo.png", "image"),
        ("a/B.JPG", "image"),
        ("icon.svg", "image"),
        ("media/intro.mp4", "video"),
        ("clip.webm", "video"),
        ("media/theme.mp3", "audio"),
        ("a.wav", "audio"),
        ("a.ogg", "audio"),
        ("a.m4a", "audio"),
        ("a.flac", "audio"),
        ("docs/manual.pdf", "pdf"),
        ("public/index.html", ""),
        ("src/app.ts", ""),
        ("Makefile", ""),
        ("logo.png/README", ""),
    ] {
        assert_eq!(media_kind_of(path), kind, "{path}");
    }
}

// An image is signed for, never read; a load that fails is retried with a
// new URL; and a URL that has run out is signed again when the file is
// opened again or the tab shows.
#[test]
fn an_image_is_signed_loaded_and_signed_again() {
    let mut files = media_files();
    assert!(files.open_file("assets/logo.png", 0));
    assert_eq!(files.file_status(), "loading");
    let (environment, resource, then) = signing(&mut files);
    assert_eq!(environment, "env-a");
    assert_eq!(
        resource,
        json!({"_tag": "workspace-file", "threadId": "t1", "path": "assets/logo.png"})
    );
    files.answer(then, signed("/api/assets/one/logo.png", 3600));
    let facts = files.facts();
    assert_eq!(facts.file_status, "ready");
    assert_eq!(facts.media_kind, "image");
    assert_eq!(
        facts.media_url,
        "http://127.0.0.1:3773/api/assets/one/logo.png"
    );
    assert!(!facts.editable && !facts.file_empty);

    // A failure of a URL no longer shown changes nothing.
    files.media_failed("http://elsewhere/logo.png");
    assert_eq!(files.file_status(), "ready");
    let url = files.media_url().to_owned();
    files.media_failed(&url);
    let facts = files.facts();
    assert_eq!(facts.file_status, "error");
    assert_eq!(facts.file_problem, "The image could not be loaded.");
    assert!(facts.media_url.is_empty());
    files.reload_file();
    let (_, _, then) = signing(&mut files);
    // Good for less than the minute kept in hand: run out at once.
    files.answer(then, signed("/api/assets/two/logo.png", 30));
    assert_eq!(files.file_status(), "ready");
    assert!(files.media_url().ends_with("/api/assets/two/logo.png"));

    assert!(files.open_file("assets/logo.png", 0));
    let (_, _, then) = signing(&mut files);
    files.answer(then, signed("/api/assets/three/logo.png", 30));
    files.set_active(true);
    let (_, _, then) = signing(&mut files);
    files.answer(then, signed("/api/assets/four/logo.png", 3600));
    // A URL that still works is kept.
    files.set_active(false);
    files.set_active(true);
    assert!(files.open_file("assets/logo.png", 0));
    assert!(calls(&mut files).is_empty());
    assert!(files.media_url().ends_with("/api/assets/four/logo.png"));
    // ...until the clock passes the minute before it runs out.
    files.set_context("http://127.0.0.1:3773", NOW + 3_540_000);
    assert!(files.open_file("assets/logo.png", 0));
    assert_eq!(signing(&mut files).2, Then::Sign(files.file_request));

    // Closing the file lets the URL go.
    files.close_file();
    assert!(files.media_url().is_empty());
}

// The browser is handed a URL that works: the one shown while it lasts, else
// a new one once signed.
#[test]
fn the_browser_gets_a_url_that_works() {
    let opened_urls = |files: &mut Files| -> Vec<String> {
        files
            .take_signals()
            .into_iter()
            .filter_map(|s| match s {
                Sig::MediaOpened(url) => Some(url),
                _ => None,
            })
            .collect()
    };
    let mut files = media_files();
    assert!(files.open_file("media/intro.mp4", 0));
    let (_, _, then) = signing(&mut files);
    files.answer(then, signed("/api/assets/one/intro.mp4", 3600));
    files.take_signals();
    files.open_media();
    assert_eq!(opened_urls(&mut files), [files.media_url().to_owned()]);

    files.reload_file();
    let (_, _, then) = signing(&mut files);
    files.answer(then, signed("/api/assets/two/intro.mp4", 30));
    files.take_signals();
    files.open_media();
    let (_, _, then) = signing(&mut files);
    assert!(opened_urls(&mut files).is_empty());
    files.answer(then, signed("/api/assets/three/intro.mp4", 3600));
    assert_eq!(
        opened_urls(&mut files),
        ["http://127.0.0.1:3773/api/assets/three/intro.mp4"]
    );

    // A file opened before the new URL arrives is not handed over.
    files.reload_file();
    let (_, _, then) = signing(&mut files);
    files.answer(then, signed("/api/assets/four/intro.mp4", 30));
    files.open_media();
    signing(&mut files);
    assert!(files.open_file("media/other.mp4", 0));
    let (_, _, then) = signing(&mut files);
    files.take_signals();
    files.answer(then, signed("/api/assets/six/other.mp4", 3600));
    assert!(opened_urls(&mut files).is_empty());
}

// Of two opens signed out of order, the later one's URL is shown.
#[test]
fn the_latest_open_wins() {
    let mut files = media_files();
    assert!(files.open_file("a.png", 0));
    let (_, _, first) = signing(&mut files);
    assert!(files.open_file("b.png", 0));
    let (_, _, second) = signing(&mut files);
    files.answer(second, signed("/api/assets/b/b.png", 3600));
    files.answer(first, signed("/api/assets/a/a.png", 3600));
    assert_eq!(files.open_path(), "b.png");
    assert!(files.media_url().ends_with("/api/assets/b/b.png"));
}

// A file outside the workspace is signed as a media file; with no thread, the
// workspace's folder names it; a file the MC will not sign says why.
#[test]
fn the_resource_follows_the_path_and_the_thread() {
    let mut files = media_files();
    assert!(files.open_file("/home/me/shot.png", 0));
    let (_, resource, then) = signing(&mut files);
    assert_eq!(
        resource,
        json!({"_tag": "media-file", "threadId": "t1", "path": "/home/me/shot.png"})
    );
    files.answer(then, Err(McError::new("Media file was not found.")));
    assert_eq!(files.file_status(), "error");
    assert_eq!(files.facts().file_problem, "Media file was not found.");

    files.set_target("env-a", "/draft", "");
    assert!(files.open_file("media/theme.mp3", 0));
    let (_, resource, _) = signing(&mut files);
    assert_eq!(
        resource,
        json!({"_tag": "draft-workspace-file", "cwd": "/draft", "path": "media/theme.mp3"})
    );
}

// A full path is the thread's machine's: on Windows it has a drive or a
// share, and with forward slashes it was signed as a workspace file.
#[test]
fn a_windows_path_is_a_media_file() {
    let mut files = media_files();
    files.set_target("env-a", "C:/w", "t1");
    for path in [
        "C:/Users/me/shot.png",
        "D:\\shots\\b.png",
        "\\\\server\\share\\c.png",
    ] {
        assert!(files.open_file(path, 0));
        assert_eq!(signing(&mut files).1["_tag"], "media-file", "{path}");
    }
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
    assert!(files.open_file("big.log", 0));
    let (_, _, then) = call(&mut files);
    files.answer(then, Ok(json!({"contents": "x", "truncated": true})));
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
    files.answer(then, Err(McError::new("")));
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
    files.answer(then, Err(McError::new("disk full")));
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
    assert!(files.set_target("env-a", "/w2", ""));
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
