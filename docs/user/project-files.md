# Project files in a Space

A project's Markdown files can be opened as pages of a Space. The page is the file: an edit on the
page is written to the file, and a change to the file, by an agent, git or the file viewer, shows on
the page. Agents and git keep working on one copy, the file.

## Open a file

Ask an agent to open the file in a Space; it uses the `hal_c2_page_open_file` tool. Opening the
same file again, from any Space, goes to the page it already is, and brings it back from the trash.
A file opened from a thread's worktree goes to the page of the project's own folder: a page follows
the file in the project's folder, whatever branch is checked out there.

## Which files count

Without any setup, every Markdown file in the project can be opened. To choose, add a `spaces`
section to the project's `hal-c2.json`:

```json
{ "spaces": { "files": [{ "path": "docs/**/*.md", "kind": "page" }] } }
```

You don't have to write it yourself. A scan proposes the section from the Markdown the project has,
leaving out hidden folders, and writes it into `hal-c2.json`, keeping the rest of the file and its
comments. Ask an agent to run it (`hal_c2_space_files_scan`). A section someone already wrote is
kept unless you ask the scan to replace it. A section that doesn't match the format counts no files
and leaves the rest of `hal-c2.json` working.

## When both change

When the file changed since the page last read it and you edit the page, the file wins. The page
says so, and what you typed is a version in the page's history that you can restore.

Comments, who is on the page, the page's agent, its history and where it sits in the Space stay with
the page, not in the file. A page that is a file can't update itself or hold charts.

## Moved and deleted files

A file renamed or moved as it is takes its page along. A deleted file, or one the checked-out branch
doesn't have, leaves the page saying the file is gone; the page keeps what it said, and follows the
file again when it comes back.

## Stop following the file

Unlink the page to make it an ordinary page. The file stays as it is, and opening it again makes a
new page.
