# Project files in the Space view

The [Space](spaces.md) view shows your projects' Markdown files beside the Space's own pages, one
section per project, as a tree by folder. Clicking a file edits it in the page editor. The page is
the file: an edit is written to the file, and a change to the file, by an agent, git or the file
viewer, shows on the page. Agents and git keep working on one copy, the file.

## Edit a file

A project's section lists the files that count (see below), and shows only when it has some.
Sections start collapsed, and each device remembers which ones you opened. Collapse a section to put
the project out of the way; the files stay as they are.

From elsewhere, choose **Edit as a page** on a file in the Files tab, in the file viewer, on a file
link in a chat, or from the command palette: it goes to the file in the Space view. Or ask an agent
to open the file as a page; it uses the `hal_c2_page_open_file` tool. A file's page belongs to its
project, not to any of your Spaces, and opening it again goes to the page it already is.

In a thread working in a worktree, the entry reads **Edit the project's copy as a page**: a page
follows the file in the project's own folder, whatever branch is checked out there, not the
worktree's copy. A file only the worktree has can't be edited as a page.

A link in the project (`CLAUDE.md` linking to `AGENTS.md`, say) opens as the file it links to, and
edits go to that file while the link stays a link. If the link and its file are both open as pages, an
edit on either shows on the other. A link that leads out of the project doesn't open.

## Which files count

Without any setup, every Markdown file in the project can be opened. To choose, add a `spaces`
section to the project's `hal-c2.json`:

```json
{ "spaces": { "files": [{ "path": "docs/**/*.md", "kind": "page" }] } }
```

You don't have to write it yourself. A scan proposes the section from the Markdown the project has,
leaving out hidden folders, and writes it into `hal-c2.json`, keeping the rest of the file and its
comments. Run **Scan project for Space files** from the command palette, or ask an agent to run
it (`hal_c2_space_files_scan`). A section someone already wrote is
kept unless you ask the scan to replace it. A section that doesn't match the format counts no files
and leaves the rest of `hal-c2.json` working.

## When both change

When the file changed since the page last read it and you edit the page, the file wins. The page
says so, and what you typed is a version in the page's history that you can restore.

When the file can't be written, for example because it is read-only, the edit is refused and you
are told why; the page and the file stay as they were.

Comments, who is on the page, the page's agent, its history and where it sits in the Space stay with
the page, not in the file. A page that is a file can't update itself or hold charts.

## Moved and deleted files

A file renamed or moved as it is takes its page along, unless more than one file now reads the same,
in which case the page says the file is gone. A deleted file, or one the checked-out branch doesn't
have, leaves the page saying the file is gone; the page keeps what it said, including edits made
since, and follows the file again when it comes back. A file that comes back wins over those edits:
the page says so, and they are versions in its history.

## Pages from before

A file opened as a page of one of your Spaces before this version stays there as an ordinary page
that no longer follows the file. The file itself is unchanged, and editing it from its project
starts a new page.
