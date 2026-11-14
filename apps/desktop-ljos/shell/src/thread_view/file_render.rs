//! What the Files tab draws of a file besides its source: the kind a file
//! renders as, the Markdown its rendered view shows (a CSV file as a table,
//! a task's box as a `task:<n>` link) and the lines its source is cut in.
//! The pure part of desktop-qt's WorkspaceFiles.

/// The rows, columns and characters of a cell a CSV file's table shows.
pub const TABLE_ROW_LIMIT: usize = 100;
pub const TABLE_COLUMN_LIMIT: usize = 30;
pub const TABLE_CELL_LIMIT: usize = 2000;
pub const CSV_ROW_LIMIT: usize = TABLE_ROW_LIMIT;

/// The extension of the last path segment, lowercased; "" without one.
pub fn extension_of(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.rfind('.')
        .map(|dot| name[dot + 1..].to_lowercase())
        .unwrap_or_default()
}

/// What a file of this extension renders as: markdown, csv, html or
/// mermaid; "" for plain text.
pub fn kind_of(extension: &str) -> &'static str {
    match extension {
        "md" | "mdx" | "markdown" | "mdown" | "mkd" => "markdown",
        "csv" | "tsv" => "csv",
        "html" | "htm" => "html",
        "mmd" | "mermaid" => "mermaid",
        _ => "",
    }
}

/// A Mermaid file as the Markdown that draws it: one "mermaid" block,
/// fenced past any run of backticks in it.
pub fn mermaid_block(text: &str) -> String {
    let mut longest = 2;
    let mut run = 0;
    for c in text.chars() {
        run = if c == '`' { run + 1 } else { 0 };
        longest = longest.max(run);
    }
    let fence = "`".repeat(longest + 1);
    let end = if text.ends_with('\n') { "" } else { "\n" };
    format!("{fence}mermaid\n{text}{end}{fence}\n")
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

/// The rows a table shows, quoted delimiters, doubled quotes and
/// multi-line cells in their cell, and whether it left any of the text out
/// (the source view keeps all of it): desktop-qt's parseDelimited.
fn delimited_rows(text: &str, delimiter: char) -> (Vec<Vec<String>>, bool) {
    let chars: Vec<char> = text.chars().collect();
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut row: Vec<String> = Vec::new();
    let mut cell = String::new();
    let mut cell_len = 0;
    let mut quoted = false;
    let mut truncated = false;
    let mut i = usize::from(chars.first() == Some(&'\u{feff}'));
    let mut row_start = i;
    while i < chars.len() {
        let c = chars[i];
        if c == '"' {
            if quoted && chars.get(i + 1) == Some(&'"') {
                if cell_len < TABLE_CELL_LIMIT {
                    cell.push('"');
                    cell_len += 1;
                } else {
                    truncated = true;
                }
                i += 2;
                continue;
            }
            if quoted || cell.is_empty() {
                quoted = !quoted;
                i += 1;
                continue;
            }
        }
        if !quoted && (c == delimiter || c == '\n' || c == '\r') {
            if row.len() < TABLE_COLUMN_LIMIT {
                row.push(std::mem::take(&mut cell));
            } else {
                truncated = true;
                cell.clear();
            }
            cell_len = 0;
            if c != delimiter {
                rows.push(std::mem::take(&mut row));
                if c == '\r' && chars.get(i + 1) == Some(&'\n') {
                    i += 1;
                }
                row_start = i + 1;
                if rows.len() == TABLE_ROW_LIMIT {
                    return (rows, truncated || i + 1 < chars.len());
                }
            }
        } else if cell_len < TABLE_CELL_LIMIT {
            cell.push(c);
            cell_len += 1;
        } else {
            truncated = true;
        }
        i += 1;
    }
    // Anything after the last line ending is a row, a lone "" too.
    if row_start < chars.len() {
        if row.len() < TABLE_COLUMN_LIMIT {
            row.push(cell);
        } else {
            truncated = true;
        }
        rows.push(row);
    }
    (rows, truncated || quoted)
}

/// The delimiter a file of this name and type is read as a table with, or
/// none when it is not read as one: its type decides, and only a plain one
/// falls back to its name.
pub fn preview_delimiter(name: &str, mime_type: &str) -> Option<char> {
    let mime = mime_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if mime == "text/csv" {
        return Some(',');
    }
    if mime == "text/tab-separated-values" {
        return Some('\t');
    }
    if !mime.is_empty() && mime != "text/plain" && mime != "application/octet-stream" {
        return None;
    }
    match extension_of(name).as_str() {
        "csv" => Some(','),
        "tsv" => Some('\t'),
        _ => None,
    }
}

/// A CSV (or TSV) file as a Markdown table, its first record the header,
/// saying so below it when it shows only part of the file; "" for a file
/// without records.
pub fn markdown_table(text: &str, separator: char) -> String {
    let (rows, truncated) = delimited_rows(text, separator);
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
                .replace("\r\n", " ")
                .replace(['\n', '\r'], " ");
            out.push_str(&format!(" {cell} |"));
        }
        out.push('\n');
        out
    };
    let mut table = line(&rows[0]);
    table.push('|');
    table.push_str(&" --- |".repeat(columns));
    table.push('\n');
    for row in &rows[1..] {
        table.push_str(&line(row));
    }
    if truncated {
        table.push_str(&format!(
            "\nTable limited to the first {TABLE_ROW_LIMIT} rows and {TABLE_COLUMN_LIMIT} columns; the source shows the rest.\n"
        ));
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
        assert_eq!(kind_of(&extension_of("docs/flow.mmd")), "mermaid");
        assert_eq!(mermaid_block("a ``` b"), "````mermaid\na ``` b\n````\n");
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
    fn a_long_table_stops_at_the_row_and_column_limits() {
        let csv: String = (0..TABLE_ROW_LIMIT + 50)
            .map(|i| format!("{i}{}\n", ",x".repeat(TABLE_COLUMN_LIMIT + 4)))
            .collect();
        let table = markdown_table(&csv, ',');
        assert!(table.ends_with(
            "\nTable limited to the first 100 rows and 30 columns; the source shows the rest.\n"
        ));
        let rows: Vec<&str> = table.lines().filter(|l| l.starts_with('|')).collect();
        assert_eq!(rows.len(), TABLE_ROW_LIMIT + 1);
        assert_eq!(rows[0].matches(" |").count(), TABLE_COLUMN_LIMIT);
    }

    #[test]
    fn a_table_drops_a_byte_order_mark_and_keeps_a_final_empty_row() {
        assert_eq!(
            markdown_table("\u{feff}name,note\n\"Smith, Jane\",\"one\ntwo\"\n\"\"", ','),
            "| name | note |\n| --- | --- |\n| Smith, Jane | one two |\n|  |  |\n"
        );
    }
}
