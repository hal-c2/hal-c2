# Spaces

A Space holds pages that you and your agents write together: plans, notes, research, anything
you want to keep beside your threads rather than inside one. Open **Spaces** from the command
palette, or from the home screen on the phone. HAL-C2 starts you with a **Personal** Space; make
more to keep subjects apart, and rename them as you go. A Space can only be deleted once it is
empty.

Every device paired with your MC sees the same Spaces, and an edit shows on each of them as it
lands. An open page shows who else is on it: your other devices, and any agent working on it.

## Pages

A page is a list of blocks: paragraphs, headings, checklists, callouts and links to its subpages.
A page can sit inside another page, and you can move it to the top of the Space or into another
page at any time. Comment on a block to leave a note on it, and resolve the comment when it is
dealt with; a resolved comment can be reopened.

A page you move to the trash takes the pages inside it along. It can't be edited there, and
restoring it brings them all back. Deleting it from the trash removes it for good, with its
comments.

Every edit is kept in the page's history, which names who wrote each version, you or an agent's
thread. Restoring a version is an edit of its own, so a restore can be undone by restoring the
version before it.

You can also make a page from a thread, which writes a summary of it (this needs a text
generation provider), import Markdown as a new page, or export a page as Markdown. A page can
update itself on a schedule from an instruction you give it; it rewrites only its generated part
and never what you wrote by hand. See [charts](charts.md) for charts on a page and
[sites](sites.md) to publish one.

## The page's prompt

A page is written from the prompt at the bottom of the page, the same prompt a thread uses. On the
desktop it is the only prompt on screen while a page is open, and it is the thread's prompt again
once you open a thread. Each page keeps its own draft, apart from every other page and thread.

- Plain words become a new block at the end of the page.
- `/` picks the kind of block, and `/visualize` asks for a [chart](charts.md).
- Start with `@agent` to ask an agent to work on the page, such as `@agent tidy this into a
  checklist`. Take `@agent` back out and the words are a block again.

An ask takes what the prompt gives a turn: the model and its effort, the mode, attachments, file
mentions and skills. It runs in the project you last worked in, on the model a new thread there
would use, unless you pick another project or model in the prompt; the prompt says where the ask
will run before you send it. If the ask is refused, your words and attachments stay in the prompt
to try again.

Stop a working agent from the prompt as you would stop a turn. An agent slow to stop can be
stopped again.

## Agents working in a Space

An ask from a page starts an ordinary thread, which shows in the sidebar, and the page links to
it. The page says what its agent is working on, then whether it finished and changed the page,
finished without changing it, was stopped, or failed and why. Dismiss that once you have read it.
Whatever the agent wrote before it stopped or failed stays on the page.

A page has one agent at a time, and a second ask is refused until the first is done. There is no
queue or steering on a page: to tell a working agent more, write in its thread. Its approvals,
questions and plans are asked in its thread too. The agent works in the project's own folder,
never a worktree, and the thread can go elsewhere afterwards.

An agent's edits land live and are versions in the page's history under its thread's name, so
anything it did can be undone by restoring an earlier version. Asking needs no approval of its
own beyond what the agent's mode asks for. An ask is refused on a page in the trash, when no
project is left on the MC, and in a project whose HAL-C2 tools are turned off. Deleting the
agent's thread ends the ask, and the page says so.

An agent in any other thread can work on a page too. While it does, the page shows it by its
thread, and its edits are versions in the history under that thread's name.

## Project files

Each project with Space files, its Markdown unless the project chooses otherwise, has its own
section in the Space sidebar, listing those files by folder. Sections start collapsed, and each
device remembers which ones you opened. Pick a file to edit it in place as a page: the page is the
file, and an edit is written to it. See
[Project files in the Space view](project-files.md) for which files count and what happens when
the page and the file both change.

## Keyboard

`mod+Alt+P` opens Spaces on the desktop, outside a terminal; change it under **Space: Open** in
**Settings → Keybindings**. In the terminal client, press `Ctrl+X` and then `p`.

An ask about the open page can start from the page's menu, the command palette, or a key. It
keeps whatever you had written in the prompt, with `@agent` in front of it.

On the desktop the command is `space.agent.focus`, listed as **Space: Ask an Agent About the
Page**. It has no default key; bind one in **Settings → Keybindings**. In the terminal client,
`A` on a page does the same.

## On the phone and in the terminal

On the phone, a page made from a thread opens once it has been written, even if you went to
look at other Spaces meanwhile.

The terminal client can't draw images, so a page shows each image as text. Its page prompt
attaches images but no other files, and has no stash, vim keys or rich text.
