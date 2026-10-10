# Sources:
#   docs/user/thread-sidebar.md (Rename, Regenerate title, agent-managed metadata)
#   apps/web/src/hooks/useRenameThread.ts
#   apps/mobile/src/features/threads/thread-title-rename.ts (empty refused, unchanged title sends nothing)
#   apps/web/src/components/threadActionMenu.logic.ts (Rename thread, Regenerate title)
#   apps/web/src/components/Sidebar.tsx (bulk Regenerate titles, rename toasts, double-click rename in place)
#   apps/tui/src/commands.ts (Rename thread)
#   apps/tui/src/components/ThreadOverlays.tsx
#   packages/contracts/src/orchestrationV2.ts (thread.metadata.update, thread.title.regeneration.complete, thread.metadata-updated)
#   apps/server-ex/lib/hal_c2/orchestration.ex (metadata.update, title generation)
#   apps/desktop-qt/src/native/WorkspaceController.cpp (the header's rename)
#   apps/mobile/src/lib/projectThreadStartTurn.ts (the title a task has before one is generated)
#   apps/web/src/components/ChatView.tsx (the title a new thread has before one is generated)

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

  @backlog @mobile
  Scenario: Renaming a thread to the title it already has changes nothing
    When the user renames "Fix login" to " Fix login "
    Then the title stays "Fix login"
    And nothing is sent to the environment

  @desktop @mobile @backlog-mobile
  Scenario: A rename that the environment rejects keeps the old title
    Given the environment rejects the rename
    When the user renames "Fix login" to "Fix OAuth login"
    Then the title stays "Fix login"
    And the user is told "Failed to rename thread"

  @backlog @desktop
  Scenario: Double-clicking a thread in the list renames it in place
    When the user double-clicks "Fix login" in the thread list
    Then its title becomes editable in the list
    When the user types "Fix OAuth login" and presses Enter
    Then the thread is listed as "Fix OAuth login"

  @backlog @desktop
  Scenario: Escape leaves the title as it was when renaming in the list
    Given the user is renaming "Fix login" in the thread list
    When the user types "Fix OAuth login" and presses Escape
    Then the thread is listed as "Fix login"

  @backlog @desktop
  Scenario: Clicking away from an in-place rename keeps the new title
    Given the user is renaming "Fix login" in the thread list
    When the user types "Fix OAuth login" and clicks elsewhere
    Then the thread is listed as "Fix OAuth login"

  @backlog @desktop
  Scenario: Renaming a thread to the title it already has sends nothing
    Given the user is renaming "Fix login" in the thread list
    When the user presses Enter without changing the title
    Then the environment receives no change
    And the user is told nothing

  @backlog @desktop
  Scenario: A double-click with a modifier key does not start a rename
    When the user double-clicks "Fix login" in the thread list while holding Shift
    Then its title does not become editable

  @mc
  Scenario: The first message gives the thread a title
    Given a new thread titled "New thread"
    When the user sends "The login page loops after OAuth callback"
    Then the thread gets a generated title describing the login loop

  @mc
  Scenario: Title generation retries before giving up
    Given the title generator fails twice and then succeeds
    When the user sends the first message of a new thread
    Then the thread gets the generated title
    And no error is shown to the user

  @mc
  Scenario: A generated placeholder title is ignored
    Given the title generator answers "New thread"
    When the user sends the first message of a new thread
    Then the thread keeps its previous title

  @mc
  Scenario: Regenerating a title from the conversation
    Given "Fix login" has a conversation about rate limiting
    When the user asks for a new title
    Then the thread gets a title describing rate limiting

  @mc
  Scenario: Regenerating a title that comes out the same ends the regeneration
    Given the title generator answers "Fix login"
    When the user asks for a new title
    Then the thread keeps the title "Fix login"
    And the thread is no longer marked as regenerating

  @mc
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

  @desktop
  Scenario: Regenerating titles for several threads
    Given the user has selected three threads, one of which is already regenerating
    When the user regenerates titles for the selection
    Then titles are regenerated for the two eligible threads

  @mc
  Scenario: The agent renames the thread it is working in
    Given the agent is working in "Fix login"
    When the agent renames its thread to "Fix OAuth callback loop"
    Then the thread is listed as "Fix OAuth callback loop"

  @mc
  Scenario: A rename that races a worktree move is rejected
    Given the thread's worktree changed after the client last saw it
    When a client updates the thread expecting the old worktree
    Then the update is rejected with "the thread's worktree changed"

  @backlog @mobile
  Scenario Outline: A task started from the phone is titled from what the user wrote until a better title arrives
    When the user starts a task on the phone with <first message>
    Then the thread is first listed as "<title>"

    Examples:
      | first message                              | title             |
      | "  Fix\n the parser  "                      | Fix the parser    |
      | only a space                               | New thread        |
      | only the photo "photo.png"                 | Image: photo.png  |

  @backlog @mobile
  Scenario: A task that starts from a cited reply is titled from the cited words
    Given the user cited "Keep the cache shared.\nRetry!" from an earlier reply
    When the user starts a task on the phone with that citation and no comment
    Then the thread is first listed as "Keep the cache shared. Retry!"

  @backlog @desktop
  Scenario Outline: A thread started without words is first titled after what the user sent
    When the user starts a thread with no text and <sent>
    Then the thread is first listed as "<title>"

    Examples:
      | sent                                               | title                 |
      | the image "cart.png"                               | Image: cart.png       |
      | the file "report.pdf"                              | File: report.pdf      |
      | the image "cart.png" and the file "report.pdf"     | Image: cart.png       |
      | an excerpt of lines 3 to 5 of "Terminal 1"         | Terminal 1 lines 3-5  |
      | nothing but spaces                                 | New thread            |

  @backlog @desktop
  Scenario Outline: A thread started from a comment or an annotation alone is titled after it
    When the user starts a thread with no text and <sent>
    Then the thread is first titled after <named>

    Examples:
      | sent                                  | named                                        |
      | a comment on lines of "src/cart.ts"   | that comment's file and lines, after "Review:" |
      | an annotation of a page in the preview | that annotation's label                      |

  @backlog @desktop
  Scenario: A first title is made of the message's words, not its link markup
    When the user starts a thread with "fix" followed by a reference to "src/cart.ts" and a cited reply
    Then the thread's first title holds the words and the cited text without link markup
    And the citation is sent as written

  @backlog @mobile
  Scenario: A first title is cut short when a comment makes it long
    Given the user cited "Keep the cache shared.\nRetry!" from an earlier reply
    When the user starts a task on the phone with that citation and a comment
    Then the thread is first listed with the cited words and the start of the comment, cut short and ending in "..."
