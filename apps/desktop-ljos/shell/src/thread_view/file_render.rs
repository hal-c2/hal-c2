//! What the Files tab draws of a file besides its source: the kind a file
//! renders as, the Markdown its rendered view shows (a CSV file as a table,
//! a task's box as a `task:<n>` link) and the lines its source is cut in.
//! The pure part of desktop-qt's WorkspaceFiles.

/// The rows of a CSV file its table shows.
pub const CSV_ROW_LIMIT: usize = 500;

/// The extension of the last path segment, lowercased; "" without one.
pub fn extension_of(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.rfind('.')
        .map(|dot| name[dot + 1..].to_lowercase())
        .unwrap_or_default()
}

/// What a file of this extension renders as: markdown, csv or html; "" for
/// plain text.
pub fn kind_of(extension: &str) -> &'static str {
    match extension {
        "md" | "mdx" | "markdown" | "mdown" | "mkd" => "markdown",
        "csv" | "tsv" => "csv",
        "html" | "htm" => "html",
        _ => "",
    }
}

/// 3145728 as "3,145,728".
pub fn grouped(n: i64) -> String {
    let digits = n.unsigned_abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    if n < 0 { format!("-{out}") } else { out }
}

/// The lines of `text`: (offset, length) in bytes, a trailing `\r` left out
/// of its line, and the longest line in UTF-16 units (Qt's characters). A
/// text that ends with a newline has no empty line after it.
pub fn line_spans(text: &str) -> (Vec<(usize, usize)>, usize) {
    let mut spans = Vec::new();
    let mut longest = 0;
    let mut at = 0;
    while at < text.len() {
        let end = text[at..].find('\n').map_or(text.len(), |n| at + n);
        let mut length = end - at;
        if length > 0 && text.as_bytes()[end - 1] == b'\r' {
            length -= 1;
        }
        spans.push((at, length));
        longest = longest.max(text[at..at + length].encode_utf16().count());
        at = end + 1;
    }
    (spans, longest)
}

/// How many lines `text` has.
pub fn line_count(text: &str) -> usize {
    let mut count = 0;
    let mut at = 0;
    while at < text.len() {
        count += 1;
        at = text[at..].find('\n').map_or(text.len(), |n| at + n) + 1;
    }
    count
}

/// Whether `line` is a list item that is a task: the offset of the box's
/// `[` and whether it is ticked. `^(\s*(?:[-*+]|\d+[.)])[ \t]+)\[([ xX])\]`
/// followed by a space, a tab or the end.
fn task_in(line: &str) -> Option<(usize, bool)> {
    let rest = line.trim_start();
    let mut at = line.len() - rest.len();
    let marker = rest.as_bytes();
    let digits = marker.iter().take_while(|b| b.is_ascii_digit()).count();
    at += if digits > 0 {
        if !matches!(marker.get(digits), Some(b'.' | b')')) {
            return None;
        }
        digits + 1
    } else if matches!(marker.first(), Some(b'-' | b'*' | b'+')) {
        1
    } else {
        return None;
    };
    let spaces = line.as_bytes()[at..]
        .iter()
        .take_while(|b| matches!(b, b' ' | b'\t'))
        .count();
    if spaces == 0 {
        return None;
    }
    at += spaces;
    let tail = line.as_bytes();
    if tail.get(at) != Some(&b'[') || tail.get(at + 2) != Some(&b']') {
        return None;
    }
    let mark = *tail.get(at + 1)?;
    if !matches!(mark, b' ' | b'x' | b'X') {
        return None;
    }
    match tail.get(at + 3) {
        None | Some(b' ' | b'\t') => Some((at, mark != b' ')),
        Some(_) => None,
    }
}

/// The tasks of `markdown` outside fenced code, in order: the offset of
/// each box's `[` and whether it is ticked.
pub fn tasks(markdown: &str) -> Vec<(usize, bool)> {
    let mut found = Vec::new();
    let mut fenced = false;
    let mut at = 0;
    while at <= markdown.len() {
        let end = markdown[at..].find('\n').map_or(markdown.len(), |n| at + n);
        let line = &markdown[at..end];
        let trimmed = line.trim();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fenced = !fenced;
        } else if !fenced && let Some((offset, checked)) = task_in(line) {
            found.push((at + offset, checked));
        }
        at = end + 1;
    }
    found
}

/// Markdown whose task boxes are links (`[☐](task:0)`) the rendered view
/// answers with a toggle.
pub fn with_task_links(markdown: &str) -> String {
    let mut out = markdown.to_owned();
    for (index, (offset, checked)) in tasks(markdown).into_iter().enumerate().rev() {
        let link = format!("[{}](task:{index})", if checked { "☑" } else { "☐" });
        out.replace_range(offset..offset + 3, &link);
    }
    out
}

/// `markdown` with its `index`th task ticked or unticked, or None without
/// one.
pub fn toggled(markdown: &str, index: usize) -> Option<String> {
    let (offset, checked) = *tasks(markdown).get(index)?;
    let mut out = markdown.to_owned();
    out.replace_range(offset + 1..offset + 2, if checked { " " } else { "x" });
    Some(out)
}

/// The cells of at most `limit` records: commas (or tabs) apart, quotes
/// around a cell that holds one, a doubled quote for a quote.
fn csv_rows(text: &str, separator: char, limit: usize) -> Vec<Vec<String>> {
    let chars: Vec<char> = text.chars().collect();
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut row: Vec<String> = Vec::new();
    let mut cell = String::new();
    let mut quoted = false;
    let end_row = |rows: &mut Vec<Vec<String>>, row: &mut Vec<String>, cell: &mut String| {
        row.push(std::mem::take(cell));
        if row.len() > 1 || !row[0].is_empty() {
            rows.push(std::mem::take(row));
        } else {
            row.clear();
        }
    };
    let mut i = 0;
    while i < chars.len() && rows.len() < limit {
        let c = chars[i];
        if quoted {
            if c == '"' && chars.get(i + 1) == Some(&'"') {
                cell.push('"');
                i += 1;
            } else if c == '"' {
                quoted = false;
            } else {
                cell.push(c);
            }
        } else if c == '"' && cell.is_empty() {
            quoted = true;
        } else if c == separator {
            row.push(std::mem::take(&mut cell));
        } else if c == '\n' {
            end_row(&mut rows, &mut row, &mut cell);
        } else if c != '\r' {
            cell.push(c);
        }
        i += 1;
    }
    if rows.len() < limit && (!cell.is_empty() || !row.is_empty()) {
        end_row(&mut rows, &mut row, &mut cell);
    }
    rows
}

/// A CSV (or TSV) file as a Markdown table, its first record the header;
/// "" for a file without records.
pub fn markdown_table(text: &str, separator: char) -> String {
    let rows = csv_rows(text, separator, CSV_ROW_LIMIT + 1);
    if rows.is_empty() {
        return String::new();
    }
    let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
    let line = |row: &[String]| {
        let mut out = String::from("|");
        for column in 0..columns {
            let cell = row.get(column).map_or("", String::as_str);
            let cell = cell
                .replace('\\', "\\\\")
                .replace('|', "\\|")
                .replace('\n', " ");
            out.push_str(&format!(" {cell} |"));
        }
        out.push('\n');
        out
    };
    let mut table = line(&rows[0]);
    table.push('|');
    table.push_str(&" --- |".repeat(columns));
    table.push('\n');
    for row in rows.iter().take(CSV_ROW_LIMIT + 1).skip(1) {
        table.push_str(&line(row));
    }
    if rows.len() > CSV_ROW_LIMIT {
        table.push_str(&format!("\nShowing the first {CSV_ROW_LIMIT} rows.\n"));
    }
    table
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_renders_by_its_extension() {
        assert_eq!(kind_of(&extension_of("docs/README.MD")), "markdown");
        assert_eq!(kind_of(&extension_of("a/b.tsv")), "csv");
        assert_eq!(kind_of(&extension_of("index.htm")), "html");
        assert_eq!(kind_of(&extension_of("src/main.rs")), "");
        assert_eq!(kind_of(&extension_of("a.d/Makefile")), "");
    }

    #[test]
    fn byte_counts_group_by_thousands() {
        assert_eq!(grouped(0), "0");
        assert_eq!(grouped(999), "999");
        assert_eq!(grouped(1_000), "1,000");
        assert_eq!(grouped(3_145_728), "3,145,728");
    }

    #[test]
    fn lines_split_on_newlines_and_drop_a_carriage_return() {
        let (spans, longest) = line_spans("ab\r\n\ncde");
        assert_eq!(spans, vec![(0, 2), (4, 0), (5, 3)]);
        assert_eq!(longest, 3);
        assert_eq!(line_spans("a\n").0, vec![(0, 1)]);
        assert_eq!(line_spans("\n").0, vec![(0, 0)]);
        assert!(line_spans("").0.is_empty());
        assert_eq!(line_count("a\nb\n"), 2);
        assert_eq!(line_count("a\n\nb"), 3);
        assert_eq!(line_count(""), 0);
    }

    #[test]
    fn tasks_are_list_items_outside_code() {
        let md = "- [ ] one\n  * [x] two\n1. [X] three\n- [y] no\n-[ ] no\n```\n- [ ] code\n```\n- [ ]\n- [ ]x\n";
        let found = tasks(md);
        let checked: Vec<bool> = found.iter().map(|t| t.1).collect();
        assert_eq!(checked, [false, true, true, false]);
        assert!(found.iter().all(|(at, _)| md.as_bytes()[*at] == b'['));
    }

    #[test]
    fn task_boxes_become_links_and_toggle() {
        let md = "# Todo\n- [ ] a\n- [x] b\n";
        assert_eq!(
            with_task_links(md),
            "# Todo\n- [☐](task:0) a\n- [☑](task:1) b\n"
        );
        assert_eq!(
            toggled(md, 0).as_deref(),
            Some("# Todo\n- [x] a\n- [x] b\n")
        );
        assert_eq!(
            toggled(md, 1).as_deref(),
            Some("# Todo\n- [ ] a\n- [ ] b\n")
        );
        assert_eq!(toggled(md, 2), None);
    }

    #[test]
    fn csv_becomes_a_table_with_quotes_and_pipes_escaped() {
        let csv = "name,note\n\"a, b\",\"say \"\"hi\"\"\"\nc|d,\n";
        assert_eq!(
            markdown_table(csv, ','),
            "| name | note |\n| --- | --- |\n| a, b | say \"hi\" |\n| c\\|d |  |\n"
        );
        assert_eq!(
            markdown_table("a\tb\n1\t2", '\t'),
            "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
        );
        assert_eq!(markdown_table("", ','), "");
    }

    #[test]
    fn a_long_table_stops_at_the_row_limit() {
        let csv: String = (0..CSV_ROW_LIMIT + 50)
            .map(|i| format!("{i},x\n"))
            .collect();
        let table = markdown_table(&csv, ',');
        assert!(table.ends_with(&format!("\nShowing the first {CSV_ROW_LIMIT} rows.\n")));
        assert_eq!(
            table.lines().filter(|l| l.starts_with('|')).count(),
            CSV_ROW_LIMIT + 2
        );
    }
}
