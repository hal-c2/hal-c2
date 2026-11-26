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
- A thread that is waiting or idle sits back at its desk, and now and then takes
  a short break: coffee, the couch, the arcade or a chat in the break room. At
  its desk, a waiting thread's screen often shows a game, a cat video, a meme
  or some shopping.
- A question mark means the thread's agent is asking you something. Click the
  person to open the thread and answer. A red mark means its last turn failed.
- When one agent hands work to another or sends it a message, the two walk up
  to each other and the message shows in a speech bubble. A very long message
  shows as "…". The office shows talks as they happen: what was said before you
  opened it, or more than thirty seconds ago, is not played.
- New threads walk in through the door, and movers carry their desks in. Desks
  nobody uses are carried back out. The office starts with 48 desks, 8 of them
  in the review corner, and grows by groups of desks when more threads come, so
  every thread has a desk. It grows sideways in a wide window and down in a
  tall one, whichever shows it bigger, and rearranges itself when you resize
  the window that way; everyone keeps their desk and walks to it.
- Threads the Code review plugin started to review a pull request, and the
  workers they delegated to, sit together in the review corner. When it is
  full they sit at the desks nearest it; other threads never sit there.
- Each desk shows the icon its project has in the sidebar. Reviewers hot-desk,
  so their desks show none.

Hover a person, or move to it with Tab, for its thread, project, agent and what
it is doing; click it or press Return to open the thread.

## Settings

- **Most people in the office**: threads asking you something come first, then
  working, waiting and idle ones.
- **Keep idle threads for (hours)**: an idle thread leaves this long after its
  agent stopped working. Archived and settled threads leave at once. Workers
  leave with the thread that delegated to them, unless they are still working
  or waiting on work of their own.

The page stands still while it is hidden or the app is in the background. When
you come back after more than a few seconds it shows the office as it is now,
without playing what happened meanwhile.
