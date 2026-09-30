# Sources:
#   docs/user/thread-sidebar.md (Rename, Regenerate title, agent-managed metadata)
#   apps/web/src/hooks/useRenameThread.ts
#   apps/web/src/components/threadActionMenu.logic.ts (Rename thread, Regenerate title)
#   apps/web/src/components/Sidebar.tsx (bulk Regenerate titles, rename toasts)
#   apps/tui/src/commands.ts (Rename thread)
#   apps/tui/src/components/ThreadOverlays.tsx
#   packages/contracts/src/orchestrationV2.ts (thread.metadata.update, thread.title.regeneration.complete, thread.metadata-updated)
#   apps/server-ex/lib/hal_c2/orchestration.ex (metadata.update, title generation)
#   apps/desktop-qt/src/native/WorkspaceController.cpp (the header's rename)

Feature: Thread titles
  Threads get a title from their first message. The user or the agent can rename a
  thread or ask for a fresh title.

  Background:
    Given a connected environment with the thread "Fix login" in the project "shop"

  @tui
  Scenario: Renaming a thread
    When the user renames "Fix login" to "Fix OAuth login"
    Then the thread is listed as "Fix OAuth login"
    And every connected client shows the new title

  @desktop @mobile @backlog-mobile
  Scenario: Renaming a thread from the desktop and phone
    When the user renames "Fix login" to "Fix OAuth login"
    Then the thread is listed as "Fix OAuth login"

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: A thread title cannot be empty
    When the user renames "Fix login" to an empty title
    Then the title stays "Fix login"
    And the user is told "Thread title cannot be empty"

  @desktop @mobile @backlog-mobile
  Scenario: A rename that the environment rejects keeps the old title
    Given the environment rejects the rename
    When the user renames "Fix login" to "Fix OAuth login"
    Then the title stays "Fix login"
    And the user is told "Failed to rename thread"

  @node
  Scenario: The first message gives the thread a title
    Given a new thread titled "New thread"
    When the user sends "The login page loops after OAuth callback"
    Then the thread gets a generated title describing the login loop

  @node
  Scenario: Title generation retries before giving up
    Given the title generator fails twice and then succeeds
    When the user sends the first message of a new thread
    Then the thread gets the generated title
    And no error is shown to the user

  @node
  Scenario: A generated placeholder title is ignored
    Given the title generator answers "New thread"
    When the user sends the first message of a new thread
    Then the thread keeps its previous title

  @node
  Scenario: Regenerating a title from the conversation
    Given "Fix login" has a conversation about rate limiting
    When the user asks for a new title
    Then the thread gets a title describing rate limiting

  @node
  Scenario: Regenerating a title that comes out the same ends the regeneration
    Given the title generator answers "Fix login"
    When the user asks for a new title
    Then the thread keeps the title "Fix login"
    And the thread is no longer marked as regenerating

  @node
  Scenario: Regenerating the title of an empty conversation does nothing
    Given the thread has no messages
    When the user asks for a new title
    Then the thread keeps its title
    And the thread is no longer marked as regenerating

  @desktop @mobile @backlog-mobile
  Scenario: The title cannot be regenerated twice at once
    Given a new title is already being generated for "Fix login"
    When the user opens the thread menu
    Then regenerating the title is unavailable and shows it is in progress

  @desktop @mobile @backlog-mobile
  Scenario: The title cannot be regenerated on an environment that needs an update
    Given the environment does not support title regeneration
    When the user opens the thread menu
    Then regenerating the title is unavailable

  @backlog @desktop
  Scenario: Regenerating titles for several threads
    Given the user has selected three threads, one of which is already regenerating
    When the user regenerates titles for the selection
    Then titles are regenerated for the two eligible threads

  @node
  Scenario: The agent renames the thread it is working in
    Given the agent is working in "Fix login"
    When the agent renames its thread to "Fix OAuth callback loop"
    Then the thread is listed as "Fix OAuth callback loop"

  @node
  Scenario: A rename that races a worktree move is rejected
    Given the thread's worktree changed after the client last saw it
    When a client updates the thread expecting the old worktree
    Then the update is rejected with "the thread's worktree changed"
