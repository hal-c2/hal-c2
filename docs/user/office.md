# Office

Office is an MC plugin (see [Plugins](plugins.md)) that shows a machine's
threads as people in a pixel-art office, so you can see at a glance who is
working, who is waiting and who needs you.

## Start

Put the `office` folder from this repository's `plugins/` into your MC's
`plugins` folder. With the MC running, select **Look for plugins** beside the
machine's name in **Settings → Plugins**, then turn Office on there. The **Office** page
shows the machine's office; with more than one machine running the plugin, pick
the machine at the top. **+** and **−** zoom, and **Fit** shows the whole office again.

## What you see

- Each thread is a person at a desk. The workers it delegated to sit at desks
  next to it, and some of them are cats and dogs. A thread looks the same every
  time you open the page, on every device.
- A person at the computer is editing, running commands or tests. One at a
  whiteboard is planning; one at a bookshelf is reading.
- A thread that is waiting or idle takes a break: coffee, the couch, the arcade
  or a chat in the break room.
- A question mark means the thread's agent is asking you something. Click the
  person to open the thread and answer. A red mark means its last turn failed.
- When one agent hands work to another or sends it a message, the two walk up
  to each other and the message shows in a speech bubble.
- New threads walk in through the door, and movers carry their desks in. Desks
  nobody uses are carried back out. The office has 48 desks; past that,
  threads without a desk wait in the break room.
- Threads the Code review plugin started to review a pull request, and the
  workers they delegated to, sit in the review corner under the **REVIEW**
  sign. When it is full they sit at the desks nearest it; other threads sit
  there only when the rest of the office is full.
- Each desk shows its project's icon from the sidebar, on the back of its
  monitor or chair: the monogram in its colour, the emoji or the logo.

Hover a person, or move to it with Tab, for its thread, project, agent and what
it is doing; click it or press Return to open the thread.

## Settings

- **Most people in the office**: threads asking you something come first, then
  working, waiting and idle ones.
- **Keep idle threads for (hours)**: an idle thread leaves once it has been
  quiet this long. Archived and settled threads leave at once. Workers leave
  with the thread that delegated to them, unless they are still working or
  waiting on work of their own.

The page stands still while it is hidden or the app is in the background.
