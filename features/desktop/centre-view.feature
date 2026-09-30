# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/js/centreViews.js (the routes the shell draws itself)
#   apps/desktop-qt/qml/HalC2/Bricks/ThreadView.qml (loading, empty, draft and unreachable states, links, revert)
#   apps/desktop-qt/qml/HalC2/Bricks/Timeline.qml (Revert to here, changed files, a tool call's file)
#   apps/desktop-qt/tests/tst_ThreadView.qml (these scenarios, by name; not run by tst_Features)
#   apps/desktop-qt/tests/native/tst_ShellExamples.cpp (every example layout draws the thread and gives way to settings)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Send a message to start the conversation.)
#   apps/web/src/components/chat/DraftHeroHeadline.tsx (What should we build in {project}?)
#   apps/web/src/components/ChatView.tsx (Revert files too, Revert and keep changes)
#   Shared domain: timeline/*.feature owns what the thread shows; this file owns how the Qt shell
#   draws a thread or draft route's centre.

Feature: The desktop shell draws the thread in the window's centre
  For a thread or a new thread's draft, the Qt shell shows the conversation in the window's
  centre, above the composer. It says when a thread is loading, empty or
  cannot be reached, and its rows lead to their files and back to earlier turns.

  Background:
    Given a connected environment with the project "shop"

  Rule: The centre says what state the thread is in and where its rows lead

    @desktop
    Scenario: A thread route shows the conversation in the centre
      When the user opens a thread
      Then the thread's conversation is shown above the composer
      When the user opens settings
      Then settings take the centre's place

    @desktop
    Scenario: A thread says it is loading without moving
      When the user opens a thread whose rows have not arrived
      Then the centre reads "Loading…"

    @desktop
    Scenario: A thread without messages says how to start
      When the user opens a thread with no messages yet
      Then the centre reads "Send a message to start the conversation."

    @desktop
    Scenario: A new thread's draft says where it will run
      When the user starts a new thread in "shop" on a new worktree from "main"
      Then the centre reads "What should we build in shop?"
      And the centre says the thread runs in a new worktree from "main"

    @desktop
    Scenario: A thread whose node cannot be reached offers a retry
      Given the thread's node cannot be reached
      Then the centre says why the thread cannot be reached
      When the user retries
      Then the shell follows the thread again

    @desktop
    Scenario Outline: Links in a reply lead where they point
      When the user follows the link "<link>" in a reply
      Then <result>

      Examples:
        | link                     | result                                                       |
        | src/cart.ts#L12          | "src/cart.ts" opens in the right panel's files at line 12    |
        | file:///work/shop/a.ts:7 | "/work/shop/a.ts" opens in the right panel's files at line 7 |
        | https://example.com/docs | nothing opens in the right panel                             |

    @desktop
    Scenario: A file a turn changed opens in the right panel
      When the user opens "src/cart.ts" from a reply's changed files
      Then "src/cart.ts" opens in the right panel's diff of that reply's turn
      When the user opens the file a tool call changed
      Then that file opens in the right panel's files

    @desktop
    Scenario: The user cancels a revert
      When the user asks to revert to a reply's turn
      And the user cancels
      Then the thread is not reverted

    @desktop
    Scenario: Jump to latest is a command
      Then "Jump to latest" is a command the shell runs
