//! DiffModel's core: tst_WorkspaceDiffRegression's DiffModel case, the
//! review-diff scenarios' rows, and tst_WorkspaceDiffProp's state machine.

use ljos::prelude::Value;
use proptest::prelude::*;
use serde_json::json;

use super::super::rows::{Mirror, RowSource};
use super::{AUTO_EXPAND_LINES, Diff, DiffNote};

fn s(v: &Value) -> String {
    match v {
        Value::String(a) => (**a).to_owned(),
        _ => String::new(),
    }
}

fn n(v: &Value) -> i32 {
    match v {
        Value::Int(i) => *i,
        Value::Real(r) => *r as i32,
        _ => 0,
    }
}

fn b(v: &Value) -> bool {
    matches!(v, Value::Bool(true))
}

fn patch_of(files: &[&str]) -> String {
    files
        .iter()
        .map(|f| format!("diff --git a/{f} b/{f}\n--- a/{f}\n+++ b/{f}\n@@ -1 +1 @@\n-old\n+new\n"))
        .collect()
}

fn column(diff: &Diff, role: &str) -> Vec<String> {
    (0..diff.row_count())
        .map(|r| {
            let v = diff.data(r, role);
            match v {
                Value::Int(i) => i.to_string(),
                Value::Bool(x) => x.to_string(),
                _ => s(&v),
            }
        })
        .collect()
}

const SAMPLE: &str = "\
diff --git a/src/app.rs b/src/app.rs
index 1234567..89abcde 100644
--- a/src/app.rs
+++ b/src/app.rs
@@ -10,4 +10,5 @@ fn main() {
 keep
-gone
-also gone
+added
+added too
+and more
 tail
diff --git a/old/name.txt b/new/name.txt
similarity index 90%
rename from old/name.txt
rename to new/name.txt
diff --git a/logo.png b/logo.png
new file mode 100644
Binary files /dev/null and b/logo.png differ
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,1 +0,0 @@
-bye
\\ No newline at end of file
";

#[test]
fn a_patch_is_read_into_files() {
    let mut diff = Diff::new();
    diff.set_patch(SAMPLE);
    assert_eq!(diff.file_count(), 4);
    assert_eq!(
        diff.paths(),
        ["src/app.rs", "new/name.txt", "logo.png", "gone.txt"]
    );
    assert_eq!((diff.additions(), diff.deletions()), (3, 3));
    // Hunk headers aside.
    assert_eq!(diff.max_columns(), "\\ No newline at end of file".len());
    let headers: Vec<usize> = (0..4).map(|f| diff.row_of_file(f).unwrap()).collect();
    let at = |f: usize, role: &str| diff.data(headers[f], role);
    assert_eq!(s(&at(1, "change")), "renamed");
    assert_eq!(s(&at(1, "previousPath")), "old/name.txt");
    assert_eq!(s(&at(2, "change")), "added");
    assert!(b(&at(2, "binary")));
    assert_eq!(s(&at(3, "change")), "deleted");
    assert_eq!(s(&at(3, "previousPath")), "");
    assert_eq!((n(&at(0, "additions")), n(&at(0, "deletions"))), (3, 2));
    assert_eq!(diff.file_of("gone.txt"), Some(3));
    assert_eq!(diff.file_of("nope"), None);
    assert_eq!(diff.row_of_file(9), None);
}

#[test]
fn an_expanded_file_shows_its_hunks_and_lines() {
    let mut diff = Diff::new();
    diff.set_patch(SAMPLE);
    assert!(diff.all_expanded(), "a small patch opens expanded");
    assert_eq!(
        column(&diff, "kind")[..9],
        [
            "file", "hunk", "line", "line", "line", "line", "line", "line", "line"
        ]
    );
    assert_eq!(
        column(&diff, "sign")[2..9],
        [" ", "-", "-", "+", "+", "+", " "]
    );
    assert_eq!(column(&diff, "text")[2..4], ["keep", "gone"]);
    assert_eq!(
        column(&diff, "oldLine")[2..9],
        ["10", "11", "12", "0", "0", "0", "13"]
    );
    assert_eq!(
        column(&diff, "newLine")[2..9],
        ["10", "0", "0", "11", "12", "13", "14"]
    );
    assert_eq!(s(&diff.data(1, "path")), "@@ -10,4 +10,5 @@ fn main() {");
    // The deleted file's lines, the last saying it had no newline.
    let last = diff.row_count() - 1;
    assert_eq!(s(&diff.data(last, "sign")), "\\");
    assert_eq!(s(&diff.data(last, "text")), " No newline at end of file");
}

#[test]
fn split_puts_removals_beside_the_additions_after_them() {
    let mut diff = Diff::new();
    diff.set_patch(SAMPLE);
    diff.take_notes();
    let mut mirror = Mirror::of(&mut diff);
    diff.set_split(true);
    mirror.follow(&mut diff);
    assert_eq!(mirror.resets, 1);
    assert_eq!(diff.take_notes(), [DiffNote::Split]);
    let pairs: Vec<(String, String, String, String)> = (2..7)
        .map(|r| {
            (
                s(&diff.data(r, "sign")),
                s(&diff.data(r, "text")),
                s(&diff.data(r, "rightSign")),
                s(&diff.data(r, "rightText")),
            )
        })
        .collect();
    let want = |l: &str, lt: &str, r: &str, rt: &str| (l.into(), lt.into(), r.into(), rt.into());
    assert_eq!(
        pairs,
        [
            want(" ", "keep", " ", "keep"),
            want("-", "gone", "+", "added"),
            want("-", "also gone", "+", "added too"),
            want("", "", "+", "and more"),
            want(" ", "tail", " ", "tail"),
        ]
    );
    assert_eq!(n(&diff.data(5, "oldLine")), 0);
    assert_eq!(n(&diff.data(5, "newLine")), 13);
}

#[test]
fn a_big_patch_or_the_setting_opens_collapsed() {
    let mut big = String::from("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,4001 +1,4001 @@\n");
    for _ in 0..=AUTO_EXPAND_LINES {
        big.push_str(" same\n");
    }
    let mut diff = Diff::new();
    diff.set_patch(&big);
    assert!(!diff.expanded(0));
    assert_eq!(diff.row_count(), 1);

    let mut diff = Diff::new();
    diff.set_collapsed_by_default(true);
    diff.set_patch(&patch_of(&["a", "b"]));
    assert_eq!(column(&diff, "kind"), ["file", "file"]);
}

/// tst_WorkspaceDiffRegression: expansionChanged fired once per file on
/// expand all, and on every toggle even when allExpanded stayed false.
#[test]
fn expanding_says_once_that_all_are_expanded() {
    let mut diff = Diff::new();
    diff.set_collapsed_by_default(true);
    diff.set_patch(&patch_of(&["a", "b", "c"]));
    diff.take_notes();
    let mut mirror = Mirror::of(&mut diff);
    diff.set_expanded(0, true);
    mirror.follow(&mut diff);
    assert_eq!(diff.take_notes(), []);
    diff.expand_all();
    mirror.follow(&mut diff);
    assert_eq!(diff.take_notes(), [DiffNote::Expansion]);
    assert!(diff.all_expanded());
    diff.expand_all();
    assert_eq!(diff.take_notes(), []);
    assert_eq!(column(&diff, "kind").len(), 3 * 4);
}

#[test]
fn the_same_patch_again_changes_nothing() {
    let mut diff = Diff::new();
    diff.set_patch(&patch_of(&["a"]));
    assert_eq!(diff.take_notes(), [DiffNote::Patch]);
    diff.take_changes();
    diff.set_patch(&patch_of(&["a"]));
    assert_eq!(diff.take_notes(), []);
    assert_eq!(diff.take_changes(), []);
}

#[test]
fn a_comment_quotes_the_lines_of_one_side() {
    let mut diff = Diff::new();
    diff.set_patch(SAMPLE);
    assert_eq!(
        diff.excerpt(0, "new", 11, 12),
        json!({"startIndex": 3, "endIndex": 4, "diff": "+added\n+added too", "rangeLabel": "+11 to +12"})
    );
    assert_eq!(
        diff.excerpt(0, "old", 11, 11),
        json!({"startIndex": 1, "endIndex": 1, "diff": "-gone", "rangeLabel": "-11"})
    );
    assert_eq!(
        diff.excerpt(0, "new", 14, 10)["rangeLabel"],
        json!("10 to 14"),
        "mixed signs, and the ends swapped"
    );
    assert_eq!(diff.excerpt(0, "new", 0, 3), json!({}));
    assert_eq!(diff.excerpt(0, "new", 90, 99), json!({}));
}

#[test]
fn the_tree_puts_folders_before_files() {
    let mut diff = Diff::new();
    diff.set_patch(&patch_of(&["z.txt", "src/b.rs", "src/a/c.rs", "a.txt"]));
    let tree: Vec<(String, String, u64)> = diff
        .tree()
        .iter()
        .map(|n| {
            (
                n["kind"].as_str().unwrap().to_owned(),
                n["path"].as_str().unwrap().to_owned(),
                n["depth"].as_u64().unwrap(),
            )
        })
        .collect();
    let row = |k: &str, p: &str, d: u64| (k.to_owned(), p.to_owned(), d);
    assert_eq!(
        tree,
        [
            row("folder", "src", 0),
            row("folder", "src/a", 1),
            row("file", "src/a/c.rs", 2),
            row("file", "src/b.rs", 1),
            row("file", "a.txt", 0),
            row("file", "z.txt", 0),
        ]
    );
    assert_eq!(diff.tree()[2]["file"], json!(2));
}

// ---- tst_WorkspaceDiffProp: the rows while patches, expansion, split and
// the "open collapsed" setting change. ----

const PATHS: &[&str] = &["a.txt", "src/b.cpp", "src/c/d.h", "e"];
// Line contents that look like the patch's own headers.
const TEXTS: &[&str] = &[
    "",
    "x",
    "-- y",
    "++ z",
    "@@ w",
    "diff --git a/q b/q",
    "long line of text",
];
const NO_NEWLINE: &str = " No newline at end of file";

#[derive(Clone, Debug)]
struct Hunk {
    old_start: i32,
    new_start: i32,
    /// Each line with its sign: '+', '-', ' ' or '\\'.
    lines: Vec<(u8, String)>,
}

impl Hunk {
    fn header(&self) -> String {
        let olds = self
            .lines
            .iter()
            .filter(|(s, _)| *s != b'+' && *s != b'\\')
            .count();
        let news = self
            .lines
            .iter()
            .filter(|(s, _)| *s != b'-' && *s != b'\\')
            .count();
        format!(
            "@@ -{},{olds} +{},{news} @@ fn",
            self.old_start, self.new_start
        )
    }
}

#[derive(Clone, Debug)]
struct File {
    path: String,
    previous_path: String,
    change: &'static str,
    binary: bool,
    hunks: Vec<Hunk>,
}

impl File {
    fn count(&self, wanted: u8) -> usize {
        self.hunks
            .iter()
            .flat_map(|h| &h.lines)
            .filter(|(s, _)| *s == wanted)
            .count()
    }

    fn line_count(&self) -> usize {
        self.hunks.iter().map(|h| 1 + h.lines.len()).sum()
    }
}

fn patch_of_files(files: &[File]) -> String {
    let mut patch = String::new();
    for file in files {
        let before = if file.previous_path.is_empty() {
            &file.path
        } else {
            &file.previous_path
        };
        patch += &format!("diff --git a/{before} b/{}\n", file.path);
        match file.change {
            "added" => patch += "new file mode 100644\n",
            "deleted" => patch += "deleted file mode 100644\n",
            "renamed" => {
                patch += &format!(
                    "similarity index 90%\nrename from {}\nrename to {}\n",
                    file.previous_path, file.path
                )
            }
            _ => {}
        }
        if file.binary {
            patch += &format!("Binary files a/{0} and b/{0} differ\n", file.path);
            continue;
        }
        if file.hunks.is_empty() {
            continue;
        }
        patch += "index 1234567..89abcde 100644\n";
        patch += &if file.change == "added" {
            "--- /dev/null\n".to_owned()
        } else {
            format!("--- a/{before}\n")
        };
        patch += &if file.change == "deleted" {
            "+++ /dev/null\n".to_owned()
        } else {
            format!("+++ b/{}\n", file.path)
        };
        for hunk in &file.hunks {
            patch += &hunk.header();
            patch.push('\n');
            for (sign, text) in &hunk.lines {
                patch.push(char::from(*sign));
                patch += if *sign == b'\\' { NO_NEWLINE } else { text };
                patch.push('\n');
            }
        }
    }
    patch
}

fn hunk() -> impl Strategy<Value = Hunk> {
    (
        1..40i32,
        1..40i32,
        prop::collection::vec(
            (
                prop::sample::select(vec![b' ', b'+', b'-']),
                prop::sample::select(TEXTS),
            ),
            1..7,
        ),
        prop::bool::weighted(1.0 / 6.0),
    )
        .prop_map(|(old_start, new_start, lines, no_newline)| {
            let mut lines: Vec<(u8, String)> =
                lines.into_iter().map(|(s, t)| (s, t.to_owned())).collect();
            if no_newline {
                lines.push((b'\\', String::new()));
            }
            Hunk {
                old_start,
                new_start,
                lines,
            }
        })
}

/// A hunk too long for the patch to open expanded.
fn big_hunk() -> Hunk {
    Hunk {
        old_start: 1,
        new_start: 1,
        lines: vec![(b' ', "same".to_owned()); AUTO_EXPAND_LINES + 1],
    }
}

fn files() -> impl Strategy<Value = Vec<File>> {
    let one = (
        any::<prop::sample::Index>(),
        prop::sample::select(vec!["modified", "added", "deleted", "renamed"]),
        prop::bool::weighted(1.0 / 7.0),
        prop::collection::vec(hunk(), 1..3),
        0..2usize,
        prop::bool::weighted(1.0 / 31.0),
    );
    prop::collection::vec(one, 0..4).prop_map(|specs| {
        let mut paths: Vec<&str> = PATHS.to_vec();
        let mut files = Vec::new();
        for (pick, change, binary, mut hunks, renamed_hunks, big) in specs {
            let path = paths.remove(pick.index(paths.len()));
            let binary = change != "renamed" && binary;
            if binary {
                hunks.clear();
            }
            let only = match change {
                "added" => Some(b'+'),
                "deleted" => Some(b'-'),
                _ => None,
            };
            for hunk in &mut hunks {
                for (sign, _) in &mut hunk.lines {
                    if let Some(only) = only.filter(|_| *sign != b'\\') {
                        *sign = only;
                    }
                }
            }
            if change == "renamed" {
                hunks.truncate(renamed_hunks);
            }
            if change == "modified" && !binary && big {
                hunks.push(big_hunk());
            }
            files.push(File {
                path: path.to_owned(),
                previous_path: if change == "renamed" {
                    format!("old/{path}")
                } else {
                    String::new()
                },
                change,
                binary,
                hunks,
            });
        }
        files
    })
}

#[derive(Clone, Debug, Default)]
struct Model {
    files: Vec<File>,
    patch: String,
    expanded: Vec<bool>,
    split: bool,
    collapsed_by_default: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Row {
    kind: String,
    file: i32,
    path: String,
    text: String,
    sign: String,
    old_line: i32,
    new_line: i32,
    right_text: String,
    right_sign: String,
    expanded: bool,
}

struct Line {
    sign: u8,
    text: String,
    old_line: i32,
    new_line: i32,
}

impl Model {
    fn all_expanded(&self) -> bool {
        self.expanded.iter().all(|e| *e)
    }

    fn rows(&self) -> Vec<Row> {
        let mut rows = Vec::new();
        for (f, file) in self.files.iter().enumerate() {
            rows.push(Row {
                kind: "file".into(),
                file: f as i32,
                path: file.path.clone(),
                expanded: self.expanded[f],
                ..Row::default()
            });
            if !self.expanded[f] {
                continue;
            }
            // Every line of the file, numbered, and the hunk headers among them.
            let mut lines = Vec::new();
            for hunk in &file.hunks {
                lines.push(Line {
                    sign: b'@',
                    text: hunk.header(),
                    old_line: 0,
                    new_line: 0,
                });
                let (mut old, mut new) = (hunk.old_start, hunk.new_start);
                for (sign, text) in &hunk.lines {
                    let mut line = Line {
                        sign: *sign,
                        text: if *sign == b'\\' {
                            NO_NEWLINE.into()
                        } else {
                            text.clone()
                        },
                        old_line: 0,
                        new_line: 0,
                    };
                    if *sign == b' ' || *sign == b'-' {
                        line.old_line = old;
                        old += 1;
                    }
                    if *sign == b' ' || *sign == b'+' {
                        line.new_line = new;
                        new += 1;
                    }
                    lines.push(line);
                }
            }
            let mut row = |left: Option<usize>, right: Option<usize>| {
                let any = &lines[left.or(right).unwrap()];
                let hunk = any.sign == b'@';
                let mut out = Row {
                    kind: if hunk { "hunk" } else { "line" }.into(),
                    file: f as i32,
                    path: if hunk {
                        any.text.clone()
                    } else {
                        file.path.clone()
                    },
                    expanded: true,
                    ..Row::default()
                };
                if let Some(l) = left {
                    out.text = lines[l].text.clone();
                    out.sign = if hunk {
                        String::new()
                    } else {
                        char::from(lines[l].sign).to_string()
                    };
                    out.old_line = lines[l].old_line;
                }
                if let Some(l) = if self.split { right } else { left } {
                    out.new_line = lines[l].new_line;
                }
                if let Some(r) = right.filter(|_| self.split && !hunk) {
                    out.right_text = lines[r].text.clone();
                    out.right_sign = char::from(lines[r].sign).to_string();
                }
                rows.push(out);
            };
            if !self.split {
                for l in 0..lines.len() {
                    row(Some(l), None);
                }
                continue;
            }
            // Side by side: a run of removals beside the additions that follow it.
            let mut l = 0;
            while l < lines.len() {
                let sign = lines[l].sign;
                if sign != b'-' && sign != b'+' {
                    row(Some(l), (sign != b'\\').then_some(l));
                    l += 1;
                    continue;
                }
                let mut removed = l;
                while removed < lines.len() && lines[removed].sign == b'-' {
                    removed += 1;
                }
                let mut added = removed;
                while added < lines.len() && lines[added].sign == b'+' {
                    added += 1;
                }
                for k in 0..(removed - l).max(added - removed) {
                    row(
                        (k < removed - l).then_some(l + k),
                        (k < added - removed).then_some(removed + k),
                    );
                }
                l = added;
            }
        }
        rows
    }
}

fn rows_of(diff: &Diff) -> Vec<Row> {
    (0..diff.row_count())
        .map(|r| Row {
            kind: s(&diff.data(r, "kind")),
            file: n(&diff.data(r, "file")),
            path: s(&diff.data(r, "path")),
            text: s(&diff.data(r, "text")),
            sign: s(&diff.data(r, "sign")),
            old_line: n(&diff.data(r, "oldLine")),
            new_line: n(&diff.data(r, "newLine")),
            right_text: s(&diff.data(r, "rightText")),
            right_sign: s(&diff.data(r, "rightSign")),
            expanded: b(&diff.data(r, "expanded")),
        })
        .collect()
}

#[derive(Clone, Debug)]
enum Action {
    SetPatch(Vec<File>),
    /// The same turn's diff read again.
    SamePatch,
    SetExpanded {
        file: prop::sample::Index,
        expand: bool,
        toggle: bool,
    },
    All(bool),
    Split(bool),
    CollapsedByDefault(bool),
}

fn action() -> impl Strategy<Value = Action> {
    prop_oneof![
        2 => files().prop_map(Action::SetPatch),
        1 => Just(Action::SamePatch),
        3 => (any::<prop::sample::Index>(), any::<bool>(), any::<bool>())
            .prop_map(|(file, expand, toggle)| Action::SetExpanded { file, expand, toggle }),
        1 => any::<bool>().prop_map(Action::All),
        1 => any::<bool>().prop_map(Action::Split),
        1 => any::<bool>().prop_map(Action::CollapsedByDefault),
    ]
}

fn step(
    model: &mut Model,
    diff: &mut Diff,
    mirror: &mut Mirror,
    action: &Action,
) -> Result<(), TestCaseError> {
    let before = model.clone();
    match action {
        Action::SetPatch(files) => {
            let patch = patch_of_files(files);
            if patch != model.patch {
                let total: usize = files.iter().map(File::line_count).sum();
                let open = !model.collapsed_by_default && total <= AUTO_EXPAND_LINES;
                model.files = files.clone();
                model.patch = patch.clone();
                model.expanded = vec![open; files.len()];
            }
            diff.set_patch(&patch);
        }
        Action::SamePatch => diff.set_patch(&model.patch),
        Action::SetExpanded {
            file,
            expand,
            toggle,
        } => {
            if model.files.is_empty() {
                return Ok(());
            }
            let file = file.index(model.files.len());
            model.expanded[file] = if *toggle {
                !model.expanded[file]
            } else {
                *expand
            };
            if *toggle {
                diff.toggle(file);
            } else {
                diff.set_expanded(file, *expand);
            }
        }
        Action::All(expand) => {
            model.expanded.fill(*expand);
            if *expand {
                diff.expand_all();
            } else {
                diff.collapse_all();
            }
        }
        Action::Split(split) => {
            model.split = *split;
            diff.set_split(*split);
        }
        Action::CollapsedByDefault(collapsed) => {
            model.collapsed_by_default = *collapsed;
            diff.set_collapsed_by_default(*collapsed);
        }
    }
    // The rows, the header facts, and that each property's signal fired
    // once if it changed and never if not.
    prop_assert_eq!(diff.file_count(), model.files.len());
    for (f, file) in model.files.iter().enumerate() {
        let header = diff.row_of_file(f).unwrap();
        prop_assert_eq!(s(&diff.data(header, "change")), file.change);
        prop_assert_eq!(
            s(&diff.data(header, "previousPath")),
            file.previous_path.clone()
        );
        prop_assert_eq!(b(&diff.data(header, "binary")), file.binary);
        prop_assert_eq!(
            n(&diff.data(header, "additions")) as usize,
            file.count(b'+')
        );
        prop_assert_eq!(
            n(&diff.data(header, "deletions")) as usize,
            file.count(b'-')
        );
        prop_assert_eq!(diff.file_of(&file.path), Some(f));
    }
    let additions: usize = model.files.iter().map(|f| f.count(b'+')).sum();
    let deletions: usize = model.files.iter().map(|f| f.count(b'-')).sum();
    prop_assert_eq!(diff.additions(), additions);
    prop_assert_eq!(diff.deletions(), deletions);
    prop_assert_eq!(rows_of(diff), model.rows());
    prop_assert_eq!(diff.all_expanded(), model.all_expanded());
    prop_assert_eq!(diff.split(), model.split);
    let notes = diff.take_notes();
    let count = |note: DiffNote| notes.iter().filter(|n| **n == note).count();
    prop_assert_eq!(
        count(DiffNote::Patch),
        usize::from(before.patch != model.patch)
    );
    prop_assert_eq!(
        count(DiffNote::Split),
        usize::from(before.split != model.split)
    );
    prop_assert_eq!(
        count(DiffNote::Expansion),
        usize::from(before.all_expanded() != model.all_expanded())
    );
    mirror.follow(diff);
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// The diff shows each file's lines while it is expanded, and says when
    /// that changes.
    #[test]
    fn the_diff_shows_each_files_lines_while_it_is_expanded(
        actions in prop::collection::vec(action(), 1..40)
    ) {
        let mut model = Model::default();
        let mut diff = Diff::new();
        let mut mirror = Mirror::of(&mut diff);
        for action in &actions {
            step(&mut model, &mut diff, &mut mirror, action)?;
        }
    }
}
