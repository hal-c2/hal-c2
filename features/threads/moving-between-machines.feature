# Sources:
#   AGENTS.md (What the fork adds: threads move between machines, including the agent's own session)
#   docs/user/thread-migration.md (Keeping a recovery copy: no whole-thread export command yet)
#   docs/user/portable-handoffs.md (the fallback when a native session cannot be carried)
#   apps/server/scripts/thread-transfer.ts (legacy archive: format "hal-c2-thread-export" version 1,
#     thread events, projection rows, attachments and terminal logs as base64 with sha256; target
#     project inferred from the workspace root or the only project, else named)
#   apps/server-ex/lib/hal_c2/streams.ex, apps/server-ex/lib/hal_c2/stream_state.ex (a thread is one
#     event stream owned by one MC)
#   apps/server-ex/lib/hal_c2/shell.ex, apps/server-ex/lib/hal_c2/cluster.ex (cluster-wide sidebar keyed
#     by MC, offline members keep their rows)
#   apps/server-ex/lib/hal_c2/checkpoint.ex (checkpoints are hidden commits under
#     refs/hal-c2/orchestration-v2/checkpoints/... in the project's repository)
#   apps/server-ex/lib/hal_c2/attachments.ex (attachments live in the MC's data, served by the
#     MC that owns the thread)
#   apps/server-ex/lib/hal_c2/terminal/history.ex (a terminal's scrollback)
#   apps/server-ex/lib/hal_c2/agent_sessions.ex (a remote URL as host/owner/repo, shared by every clone)
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex (native session when the provider can, else a
#     trimmed transcript)
#   apps/server-ex/lib/hal_c2/mcp/tools/threads.ex (agent-facing thread tools and their error codes)
#   Shared domain: providers/portable-sessions.feature owns how each provider's native session is
#   carried; threads/migration-and-handoffs.feature owns the transcript handoff and its budget;
#   connections/cluster.feature owns forming the cluster and the shared sidebar;
#   mc/orchestration/checkpoints-and-rollback.feature owns capturing checkpoints.
#
# Decisions recorded here:
#   - A move keeps the thread's id. The machine it left keeps only a forwarding record, so links,
#     notifications and forks that name the thread still find it.
#   - The destination owns the thread only once it has confirmed the whole thing; until then the
#     source keeps it, unchanged and read-only. A move that fails leaves the thread where it was.
#   - Terminal scrollback travels as history. Running terminals do not: they belong to the source
#     machine and are closed when the thread leaves, after the user is told.
#   - Moving has no default shortcut. It is rare and deliberate; the menu, the palette and the
#     agent tool are enough.
#   - Export and import copy a thread between machines that are not in one cluster. Exporting
#     leaves the thread on the source; the user decides what to do with it there.
#   - An agent that moves its own thread cannot stop its running turn to do it, so the move waits
#     for the turn to end. Moving another thread needs the same full-access, default-mode caller
#     as other environment-wide changes (mc/orchestration/mcp-server.feature).
#   - Proposed names: palette entry action:move-thread, agent tool hal_c2_thread_move, CLI tasks
#     mix hal_c2.thread.export and mix hal_c2.thread.import, archive extension .hal-c2-thread
#     (format "hal-c2-thread-export" version 2; version 1 is the previous server's).

Feature: Moving a thread and its agent to another machine
  A thread can leave the machine it lives on and continue on another one. Its conversation,
  attachments and checkpoints go with it, and so does the agent's own session when the
  provider can carry it, so the agent picks up where it left off rather than from a summary.

  Background:
    Given a cluster of the machines "laptop" and "desktop"
    And the project "shop" on each machine is a checkout of the same repository
    And the thread "Alpha" lives on "laptop" in "shop"

  Rule: Moving within a cluster

    @shared @backlog-mobile @backlog-tui
    Scenario: The user moves a thread to another machine
      When the user moves "Alpha" to "desktop"
      Then "Alpha" is listed under "desktop"
      And "Alpha" is no longer listed under "laptop"
      And the user is looking at "Alpha" on "desktop"

    @shared @backlog-mobile @backlog-tui
    Scenario: Only machines that can take the thread are offered
      Given the cluster also has the machine "server", which is offline
      When the user chooses where to move "Alpha"
      Then "desktop" is offered
      And "server" is shown as offline and cannot be chosen
      And "laptop" is not offered

    @backlog @shared
    Scenario: Moving is not offered on a machine that is alone
      Given "laptop" is not in a cluster
      When the user opens the menu for "Alpha"
      Then moving to another machine is not offered
      And exporting "Alpha" to a file is offered

    @mc
    Scenario Outline: The destination project is a checkout of the same repository
      Given "desktop" instead has <projects>
      When the user moves "Alpha" to "desktop"
      Then <outcome>

      Examples:
        | projects                                               | outcome                                                     |
        | one project that is a checkout of the same repository  | "Alpha" moves into that project                             |
        | two projects that are checkouts of the same repository | the user is asked which of the two to move "Alpha" into     |
        | no checkout of the repository                          | the user is asked to pick a project or add one on "desktop" |

    @mc
    Scenario: A checkout of the same repository is recognised by its remote
      Given "shop" on "laptop" is at "~/code/shop" with the remote "git@github.com:acme/shop.git"
      And "desktop" has "~/src/shop-app" with the remote "https://github.com/acme/shop"
      When the user moves "Alpha" to "desktop"
      Then "Alpha" moves into the project at "~/src/shop-app"

    @mc
    Scenario: The user can choose a project that is not the same repository
      Given "desktop" instead has no checkout of the repository of "shop"
      When the user moves "Alpha" to "desktop" into the project "scratch"
      Then "Alpha" moves into "scratch"
      And the user is told checkpoints stay behind because "scratch" is a different repository

    @mc
    Scenario: A worktree thread gets its own worktree on the destination
      Given "Alpha" works in its own worktree on the branch "feature/cart"
      When the user moves "Alpha" to "desktop"
      Then "Alpha" works in a new worktree of "shop" on "desktop" on the branch "feature/cart"
      And the branch has the commits it had on "laptop", including ones never pushed
      And the worktree holds the files as they were at the end of the last run of "Alpha"

    @mc
    Scenario: A thread working in the project's own checkout does not touch the destination's files
      Given "Alpha" works directly in the checkout of "shop" with uncommitted changes
      When the user moves "Alpha" to "desktop"
      Then the checkout of "shop" on "desktop" is left as it was
      And the user is told the uncommitted changes stayed on "laptop"

    @mc
    Scenario: The source's worktree is left for the user
      Given "Alpha" works in its own worktree on "laptop"
      When "Alpha" moves to "desktop"
      Then the worktree on "laptop" is still there with its files
      And it no longer belongs to any thread

  Rule: What travels with the thread

    @mc
    Scenario Outline: The thread keeps who it is
      Given "Alpha" has <detail>
      When "Alpha" moves to "desktop"
      Then "Alpha" on "desktop" still has <detail>

      Examples:
        | detail                                             |
        | its id and title                                   |
        | its agent, model, permission and interaction modes |
        | its parent, root thread and the run it forked from |
        | its pin, snooze, archive and settle state          |
        | its linked pull request                            |
        | its unread state                                   |
        | a pending merge-back from one of its forks         |

    @mc
    Scenario Outline: The thread keeps what happened in it
      Given "Alpha" has <history>
      When "Alpha" moves to "desktop"
      Then "Alpha" on "desktop" shows <history> as it was

      Examples:
        | history                                         |
        | its messages with their times and authors       |
        | its tool activity, plans and answered approvals |
        | its runs and their outcomes                     |
        | its attachments                                 |
        | the scrollback of its terminals                 |

    @mc
    Scenario: Attachments are served by the machine the thread now lives on
      Given "Alpha" has an image attachment
      When "Alpha" moves to "desktop"
      And a client opens the image in "Alpha"
      Then "desktop" serves the image

    @mc
    Scenario: Checkpoints are carried into the destination's repository
      Given "Alpha" has checkpoints for runs 1 to 3
      When "Alpha" moves to "desktop"
      Then the checkpoints of runs 1 to 3 exist in the repository of "shop" on "desktop"
      And the diff of each of those runs is the same as it was on "laptop"

    @mc
    Scenario: A moved thread can be rewound to a run from before the move
      Given "Alpha" had runs 1 to 3 on "laptop" and moved to "desktop"
      When the user rewinds "Alpha" to run 1
      Then the workspace of "Alpha" on "desktop" is as it was after run 1

    @mc
    Scenario: Checkpoints stay behind when the destination is a different repository
      Given "Alpha" has checkpoints for runs 1 to 3
      When "Alpha" moves to "desktop" into a project that is not the same repository
      Then runs 1 to 3 have no diff on "desktop"
      And "Alpha" cannot be rewound to a run from before the move
      And the user was told this before the move began

    @mc
    Scenario: Running terminals stay on the source and are closed
      Given "Alpha" has a terminal running a development server
      When the user moves "Alpha" to "desktop"
      Then the user is told the terminal will be closed and asked to confirm
      And after the move the terminal on "laptop" is closed
      And its scrollback is readable in "Alpha" on "desktop"

    @mc
    Scenario: Forks and subagent threads stay where they are and keep their lineage
      Given "Beta" on "laptop" is a fork of "Alpha"
      When "Alpha" moves to "desktop"
      Then "Beta" stays on "laptop"
      And "Beta" still names "Alpha" as its parent
      And opening the parent of "Beta" opens "Alpha" on "desktop"

  Rule: The agent continues on the destination

    @mc
    Scenario: The agent's own session moves with the thread
      Given "Alpha" runs on an agent whose provider can carry its session
      When "Alpha" moves to "desktop"
      And the user sends a message in "Alpha"
      Then the agent on "desktop" continues its own session from "laptop"
      And it receives no transcript of the earlier conversation

    @mc
    Scenario: An agent whose session cannot be carried gets the conversation handed over
      Given "Alpha" runs on an agent whose provider cannot carry its session
      When "Alpha" moves to "desktop"
      And the user sends a message in "Alpha"
      Then a new agent session starts on "desktop"
      And the agent receives the trimmed account of the conversation that a handoff gives

    @shared @backlog-mobile @backlog-tui
    Scenario Outline: The user is told how the agent continues
      Given "Alpha" runs on an agent whose provider <can> carry its session
      When the user moves "Alpha" to "desktop"
      Then the user is told "<message>"

      Examples:
        | can    | message                                                                         |
        | can    | Alpha moved to desktop. The agent continues its own session there.              |
        | cannot | Alpha moved to desktop. The agent there will get a summary of the conversation. |

    @mc
    Scenario: A carried session that fails to resume falls back to the handoff
      Given "Alpha" moved to "desktop" with its agent's session
      And the agent on "desktop" cannot open the carried session
      When the user sends a message in "Alpha"
      Then a new agent session starts with the trimmed account of the conversation
      And the user is told the agent could not continue its own session

    @mc
    Scenario: The agent is told where the project now lives
      Given "shop" is at "~/code/shop" on "laptop" and at "~/src/shop-app" on "desktop"
      And "Alpha" moved to "desktop"
      When the user sends the first message in "Alpha" since the move
      Then the agent is told the project moved from "~/code/shop" to "~/src/shop-app"

  Rule: Moving back

    @shared @backlog-mobile @backlog-tui
    Scenario: A moved thread can be moved back
      Given "Alpha" was moved from "laptop" to "desktop"
      And the user worked in "Alpha" on "desktop"
      When the user moves "Alpha" to "laptop"
      Then "Alpha" is listed under "laptop" with the work done on "desktop"
      And the agent on "laptop" continues the session as it was on "desktop"

    @mc
    Scenario: Moving back does not bring back an old copy
      Given "Alpha" went from "laptop" to "desktop" and back to "laptop"
      When the user opens "Alpha" on "laptop"
      Then it shows the runs made on "desktop"
      And none of its runs appear twice

  Rule: Finding a thread that moved

    @backlog @shared
    Scenario: A link to a moved thread opens it where it lives now
      Given the user copied a link to "Alpha" while it lived on "laptop"
      And "Alpha" has since moved to "desktop"
      When the user follows the link
      Then "Alpha" opens on "desktop"

    @shared @backlog-mobile @backlog-tui
    Scenario: A notification from before the move opens the thread where it lives now
      Given the user was notified that "Alpha" finished while it lived on "laptop"
      And "Alpha" has since moved to "desktop"
      When the user opens the notification
      Then "Alpha" opens on "desktop"

    @mc
    Scenario: A link to a moved thread works while the machine it left is offline
      Given "Alpha" moved from "laptop" to "desktop"
      And "laptop" is asleep
      When a client asks for "Alpha" by its id
      Then it is served by "desktop"

    @mc
    Scenario: A thread that moved and was then deleted is reported as deleted
      Given "Alpha" moved to "desktop" and was deleted there
      When the user follows an old link to "Alpha"
      Then the user is told the thread was deleted

  Rule: Other clients see the move

    @backlog @shared
    Scenario: Another client sees the thread move
      Given a phone and the desktop app both follow the cluster's threads
      When the user moves "Alpha" to "desktop" from the desktop app
      Then the phone lists "Alpha" under "desktop" and no longer under "laptop"
      And the phone did not have to reconnect

    @shared @backlog-mobile @backlog-tui
    Scenario: A client looking at the thread follows it to its new machine
      Given the phone is showing "Alpha"
      When "Alpha" is moved to "desktop" from another client
      Then the phone keeps showing "Alpha"
      And a message sent from the phone reaches "Alpha" on "desktop"

    @shared @backlog-mobile @backlog-tui
    Scenario: A client sees that a thread is moving
      Given the phone lists "Alpha"
      When "Alpha" starts moving to "desktop"
      Then the phone shows "Alpha" as moving to "desktop" until it arrives

  Rule: A move that cannot happen changes nothing

    @mc
    Scenario: A thread with a turn running is not moved
      Given the agent is working in "Alpha"
      When the user moves "Alpha" to "desktop"
      Then the user is told "Alpha is running. Stop it or wait for it to finish before moving it."
      And "Alpha" stays on "laptop" and keeps running

    @mc
    Scenario: A thread waiting for an answer is not moved
      Given the agent in "Alpha" is waiting for the user to approve a command
      When the user moves "Alpha" to "desktop"
      Then the user is told to answer or stop "Alpha" before moving it
      And "Alpha" stays on "laptop"

    @shared @backlog-mobile @backlog-tui
    Scenario: The user can stop the turn and move the thread in one step
      Given the agent is working in "Alpha"
      When the user moves "Alpha" to "desktop" and chooses to stop it first
      Then the running turn of "Alpha" is interrupted
      And "Alpha" moves to "desktop"

    @shared @backlog-mobile @backlog-tui
    Scenario: A message cannot be sent while the thread is moving
      Given "Alpha" is moving to "desktop"
      When the user writes a message in "Alpha"
      Then the message is kept as a draft
      And it can be sent once "Alpha" has arrived on "desktop"

    @mc
    Scenario Outline: A move the destination cannot take is refused before anything is copied
      Given <situation>
      When the user moves "Alpha" to "desktop"
      Then the user is told "<message>"
      And "Alpha" stays on "laptop" as it was
      And nothing of "Alpha" is left on "desktop"

      Examples:
        | situation                                                | message                                                                   |
        | "desktop" is offline                                     | desktop is offline. Alpha was not moved.                                  |
        | "desktop" does not have the agent "Alpha" runs on        | desktop does not have Claude. Alpha was not moved.                        |
        | the agent "Alpha" runs on is not signed in on "desktop"  | Claude is not signed in on desktop. Sign in there, then move Alpha again. |
        | the directory of the chosen project on "desktop" is gone | The project folder on desktop no longer exists. Alpha was not moved.      |
        | "desktop" has too little free disk space for "Alpha"     | desktop does not have enough free space for Alpha. Alpha was not moved.   |

    @backlog @shared
    Scenario: A thread whose agent is missing on the destination can move onto another agent
      Given "desktop" does not have the agent "Alpha" runs on
      When the user moves "Alpha" to "desktop" and picks Codex there
      Then "Alpha" moves to "desktop" on Codex
      And the next message hands the conversation over to Codex

    @mc
    Scenario: A move that breaks off part way leaves the thread on the source
      Given "Alpha" is being copied to "desktop"
      When "desktop" goes offline before it has confirmed the thread
      Then "Alpha" stays on "laptop" and can be used again
      And the user is told the move did not finish and can be tried again

    @mc
    Scenario: A destination that comes back after a broken-off move discards its partial copy
      Given a move of "Alpha" to "desktop" broke off part way
      When "desktop" comes back online
      Then "desktop" does not list "Alpha"
      And the space used by the partial copy is freed

    @mc
    Scenario: The source going offline after the destination confirmed does not undo the move
      Given "desktop" has confirmed it holds "Alpha"
      When "laptop" goes offline before it has let go of "Alpha"
      Then "Alpha" lives on "desktop"
      And when "laptop" comes back it lists "Alpha" only under "desktop"

    @mc
    Scenario: A thread cannot be moved twice at once
      Given the cluster also has the machine "server"
      And "Alpha" is moving to "desktop"
      When another client moves "Alpha" to "server"
      Then the second move is refused because "Alpha" is already moving

  Rule: Moving threads from the list

    @shared @backlog-mobile @backlog-tui
    Scenario: Moving from the thread's menu
      When the user opens the menu for "Alpha"
      Then moving to another machine is offered

    @shared @backlog-mobile @backlog-tui
    Scenario: Moving from the command palette
      Given the user is looking at "Alpha"
      When the user asks the command palette to move the thread to another machine
      Then the user is asked which machine to move "Alpha" to

    @backlog @desktop
    Scenario: Moving several selected threads
      Given "Alpha" and "Beta" on "laptop" are selected
      When the user moves the selection to "desktop"
      Then "Alpha" and "Beta" each move to "desktop"
      And a thread that cannot move stays on "laptop" and is named with its reason

  Rule: Agents can move threads

    @mc
    Scenario: An agent moves another thread
      Given the thread "caller" runs in full-access mode
      And "Alpha" is idle
      When the agent of "caller" moves "Alpha" to "desktop"
      Then "Alpha" moves to "desktop"
      And the agent receives where "Alpha" now lives and whether its session was carried

    @mc
    Scenario: An agent moving its own thread moves once its turn ends
      Given the agent is working in "Alpha"
      When the agent of "Alpha" moves its own thread to "desktop"
      Then the agent is told the move will happen when its turn ends
      And when the turn ends "Alpha" moves to "desktop"

    @mc
    Scenario: An agent can list the machines a thread can move to
      When the agent of "Alpha" asks where "Alpha" can move
      Then it receives each machine with whether it is online and which of its projects can take "Alpha"

    @mc
    Scenario Outline: An agent's move that cannot be made
      Given <situation>
      When the agent of "caller" moves "Alpha" to <machine>
      Then it fails with code "<code>"

      Examples:
        | situation                          | machine   | code               |
        | "Alpha" has a turn running         | "desktop" | thread_not_movable |
        | "desktop" is offline               | "desktop" | mc_unavailable     |
        | the cluster has no machine "attic" | "attic"   | invalid_request    |
        | "caller" runs in plan mode         | "desktop" | capability_denied  |

  Rule: Moving between machines outside a cluster

    @mc
    Scenario: Exporting a thread from the command line
      When the user exports "Alpha" on "laptop" to the file "alpha.hal-c2-thread"
      Then the file holds the thread with its history, attachments, terminal scrollback, checkpoints and the agent's session
      And "Alpha" stays on "laptop" unchanged

    @mc
    Scenario: Importing a thread from the command line into a chosen project
      Given "desktop" has left the cluster
      And the file "alpha.hal-c2-thread" was exported from "laptop"
      When the user imports the file on "desktop" into the project "shop"
      Then "Alpha" is listed under "desktop" in "shop" with everything a move carries

    @mc
    Scenario Outline: Importing without naming a project
      Given "desktop" instead has <projects>
      When the user imports "alpha.hal-c2-thread" on "desktop" without naming a project
      Then <outcome>

      Examples:
        | projects                                               | outcome                                                   |
        | one project that is a checkout of the same repository  | "Alpha" is imported into that project                     |
        | two projects that are checkouts of the same repository | the import is refused and asks the user to name one       |
        | no checkout of the repository                          | the import is refused and asks the user to name a project |

    @mc
    Scenario: Importing the same file twice finds the thread already there
      Given "alpha.hal-c2-thread" was imported on "desktop"
      When the user imports it on "desktop" again
      Then the user is told "Alpha" is already on "desktop"
      And there is still one "Alpha"

    @mc
    Scenario: A file from a newer HAL-C2 is refused
      Given "alpha.hal-c2-thread" was exported by a newer HAL-C2 in a format "desktop" does not know
      When the user imports it on "desktop"
      Then the user is told the file needs a newer HAL-C2
      And nothing is imported

    @mc
    Scenario: A file exported by the previous server is imported without the agent's session
      Given a thread file exported by the previous server
      When the user imports it on "desktop"
      Then the thread is listed with its history, attachments and terminal scrollback
      And its next message hands the conversation over to the agent

    @mc
    Scenario: A damaged file is refused
      Given one of the attachments in "alpha.hal-c2-thread" does not match its checksum
      When the user imports it on "desktop"
      Then the user is told the file is damaged
      And nothing is imported

    @backlog @shared
    Scenario: Exporting a thread from the app
      When the user exports "Alpha" to a file
      Then the user is offered a place to save or share the file
      And "Alpha" stays where it is

    @backlog @shared
    Scenario: Importing a thread file from the app
      Given the user has the file "alpha.hal-c2-thread"
      When the user imports it into "shop" on "desktop"
      Then "Alpha" opens on "desktop"
      And the user is told whether the agent continues its own session
