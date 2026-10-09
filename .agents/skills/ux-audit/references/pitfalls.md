# Sandbox and safety pitfalls

## The seeded data points at real things

- `--seed` copies the database, but its projects and worktrees are the
  developer's real checkouts on disk. Never send a turn, run a project
  action or script, commit, push, open or merge a pull request, revert to a
  checkpoint, delete a worktree or remove a project in a seeded project. All
  of these act on real repositories, and a turn starts a real, billed agent.
- For mutating flows, make a scratch project: `git init` a directory under
  `$UX_AUDIT_DIR/scratch/` with a commit or two, add it through the app,
  and do your sending, committing, reverting and removing there. Pick the
  cheapest model and a prompt that keeps the agent busy for a minute
  without spending much ("count slowly to 60, one number per line"), so
  there is time to queue and steer. Keep turns few.
- Some controls act on real accounts and the real machine even outside a
  project. Open them, read them, and cancel:
  - Usage › Limits "Use reset" redeems a real reset credit.
  - The Updates toast's Update button runs a real CLI update.
  - "Open on the host" may open a browser or editor on the developer's
    desktop, outside the sandbox.
- The composer saves drafts. Clear what you typed into a seeded thread's
  composer before leaving it, and check that it is empty.
- The sandbox's MC starts no turn nobody sent (`HAL_C2_MC_NO_AUTO_TURNS`):
  a seeded thread with an armed resume, a queued message or a turn the
  snapshot cut off stays put. Start it only through `mise run desktop:cua`
  and `ux mc-start`, which set that; a bare `mix hal_c2.server` on the
  scratch home sends those turns in the real projects.
- Seed only the database, never `settings.json`.
- Pairing links, access tokens and real conversation content show up in
  screenshots. The report stays local. Issues embed screenshots only with
  `--upload-shots`, after you have checked them (each shot's `.json` tree
  holds its text, which is quicker to search than the image). Do not put
  secrets or tokens in a finding.

## Never touch the live install

- Seed only through `--seed`, which snapshots read-only. Never point
  `HAL_C2_CUA_HOME`, `HAL_C2_HOME` or `--home-dir` at `~/.local/share/hal-c2*`,
  `~/.config/hal-c2*`, `~/.t3` or `~/.hal-c2`.
- Stop what you started with `mise run desktop:cua:stop`, or only the MC
  with `ux mc-stop`, which checks that the port's owner is this sandbox's
  MC. Never kill by pattern. Other HAL-C2 apps, MCs and
  agents run on this machine, and one of them is the session that launched
  you.

## cua-driver in the sandbox

- Coordinates belong to the session's last `get_window_state` screenshot.
  A click without one fails with `screenshot_context_missing`, and a click
  after the layout moved lands on the old layout. Shoot, then click.
- `desktop:cua:call` already sets foreground delivery. Background delivery
  crashes Qt's xcb plugin. If the app dies, `app.log` says why, and
  `mise run desktop:cua` relaunches it.
- The AT-SPI tree may elide or omit custom-drawn items. When the tree and the
  screenshot disagree, believe the screenshot and log the tree gap as an
  accessibility finding.
- `type_text` sends key events to the focused window. Click the field first.
- `hotkey` takes punctuation as the character (`ux key ctrl '['`), not as
  an X keysym name like `bracketleft`.
- `set_window_frame` does not stick under sway; use `ux size`. The first
  click after the window starts floating is swallowed: click again after
  a fresh shot.
