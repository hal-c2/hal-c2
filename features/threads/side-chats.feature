# Sources:
#   https://github.com/pingdotgg/t3code/pull/29752
#   https://github.com/pingdotgg/t3code/pull/26901
#   https://github.com/pingdotgg/t3code/pull/31114
#   https://github.com/pingdotgg/t3code/pull/31709
#   docs/orchestration-v2/thread-lineage-and-context-transfer.md (upstream: side chats are hidden forks)
#   threads/fork-and-lineage.feature (forks and Bring back, which side chats build on)

Feature: Side chats beside a thread
  A side chat asks about a thread without derailing it. It is a hidden fork that opens beside
  the thread with its own composer while the thread keeps running, and it can bring its answer
  back into the thread's next message.

  Background:
    Given a connected environment with the thread "Plan billing"

  # Upstream #26901: side chats, after Claude Code's /btw, Codex's /side and Cursor's side chats.
  @backlog @shared @priority-high
  Scenario Outline: The user opens a side chat beside the thread
    When the user <starts> in "Plan billing"
    Then a side chat of "Plan billing" opens beside it with its own composer
    And "Plan billing" keeps running

    Examples:
      | starts                                        |
      | sends "/side why add clamp next to sum?"      |
      | sends "/btw why add clamp next to sum?"       |
      | chooses "Side chat" where new tabs are opened |

  # Upstream #26901
  @backlog @shared
  Scenario Outline: A side chat cannot be started from <place>
    Given <place>
    Then the user is not offered a side chat

    Examples:
      | place                                                     |
      | a side chat                                               |
      | a subagent's thread, local or delegated from another MC   |
      | a thread whose worktree is still being set up             |
      | a thread on an MC that does not support side chats        |

  # Upstream #26901
  @backlog @mc @priority-high
  Scenario: A side chat of a running thread knows what the run is doing
    Given the agent is still working in "Plan billing" after an earlier run finished
    When the user opens a side chat and asks a question
    Then the side chat starts from the last finished run of "Plan billing"
    And its first message carries a digest of the run in progress, at most 8,000 characters
    And it is told how to read the thread for its live state

  # Upstream #26901
  @backlog @mc
  Scenario: A side chat of a thread in its first run gets that run as its whole context
    Given "Plan billing" is in its first run and has nothing finished
    When the user opens a side chat and asks a question
    Then the side chat's first message carries a digest of that run as its context

  # Upstream #31114: side chats forced Supervised at creation, on the first message and at
  # provider start; they now copy the thread's permission mode (this replaces #26901's rule).
  @backlog @mc @shared @priority-high
  Scenario Outline: A side chat starts with its thread's permission mode
    Given "Plan billing" runs in <mode>
    When the user asks a side chat of it a question
    Then the side chat's first turn runs in <mode>
    And changing the permission mode of "Plan billing" later leaves the side chat's own

    Examples:
      | mode              |
      | full access       |
      | auto-accept edits |
      | supervised        |

  # Upstream #31114: the side chat's own permission picker works on its own.
  @backlog @shared
  Scenario: A side chat's permission mode can be changed on its own
    Given a side chat of "Plan billing" runs in full access
    When the user switches the side chat to supervised
    Then the side chat's next turn asks before it acts
    And "Plan billing" stays in full access

  # Upstream #29752: a side chat's first message compared its model with the parent's latest turn,
  # so it opened with a model change from a run it never showed.
  @backlog @mc @shared
  Scenario: A side chat's first message shows no model change from its thread
    Given the latest turn of "Plan billing" ran on "GPT-5.5"
    When the user asks a side chat of it a question on "Haiku"
    Then the side chat's first message shows no change of model
    But a later side chat message on another model shows the change from the side chat's own turn

  # Upstream #26901
  @backlog @mc
  Scenario: A side chat records no checkpoints of the files it shares with its thread
    When the user asks a side chat of "Plan billing" a question
    Then the side chat records no checkpoints of the files it shares with "Plan billing"

  # Upstream #26901
  @backlog @mc
  Scenario: Rewinding files waits while a side chat may have touched them
    Given a side chat of "Plan billing" is running, or has run a command, changed a file or called a tool
    Then rewinding "Plan billing" with its files is unavailable
    When the user deletes the side chat
    Then rewinding "Plan billing" with its files is available again

  # Upstream #26901
  @backlog @shared @priority-high
  Scenario: Bringing a side chat back adds it to the thread's next message
    Given a side chat of "Plan billing" has finished answering
    And "Plan billing" is not running
    When the user chooses "Bring back" in the side chat
    Then the side chat's work goes with the next message of "Plan billing"
    And while "Plan billing" runs, "Bring back" is unavailable and the MC refuses it

  # Upstream #26901
  @backlog @mc
  Scenario: Side chats stay out of every list
    Given "Plan billing" has a side chat
    Then the side chat is not in the thread list, search, the command palette, pull request links, the activity feed or an agent's thread list
    And its approvals and questions show on the row of "Plan billing"

  # Upstream #26901
  @backlog @shared
  Scenario: A side chat is reopened from its thread's details
    Given "Plan billing" has a side chat the user closed
    When the user opens the side chats in the details of "Plan billing"
    Then the user can reopen it beside the thread
    And reopening the last closed tab reopens it too

  # Upstream #26901
  @backlog @shared @mc
  Scenario Outline: A side chat is deleted when <when>
    Given "Plan billing" has a side chat
    When <when>
    Then the side chat is deleted

    Examples:
      | when                                              |
      | the user closes it before sending anything        |
      | the user deletes it from its header               |
      | "Plan billing" is deleted                         |

  # Upstream #31709: the phone starts side chats with /side and /btw; on a phone the side chat
  # opens as a page of its own, on a tablet beside the thread.
  @backlog @mobile
  Scenario: A side chat started on the phone opens as its own page
    When the user sends "/side why add clamp next to sum?" in "Plan billing" on the phone
    Then a side chat of "Plan billing" opens as a page of its own with the question sent
    And the side chat is listed under the side chats of "Plan billing"

  # Upstream #31709: typed where it is not offered, /side says why it cannot start.
  @backlog @shared
  Scenario: A side chat typed where one cannot start says why
    Given "Plan billing" has no message yet
    When the user sends "/side why add clamp next to sum?" in "Plan billing"
    Then the user is told why a side chat cannot start
    And nothing is sent to "Plan billing"

  # Upstream #31709: as on the desktop, a side chat question is text only.
  @backlog @shared @priority-low
  Scenario: A side chat question carries no attachments
    Given the draft of "Plan billing" holds "/side what is this?" and an image
    When the user sends it
    Then the user is told a side chat takes text only
    And the draft keeps the image

  # Upstream #26901: the phone lists them to answer them.
  @backlog @mobile
  Scenario: The phone lists a thread's side chats so their approvals can be answered
    Given a side chat of "Plan billing" waits for an approval
    When the user opens "Plan billing" on the phone
    Then its side chats are listed
    And the user can open the side chat and answer the approval
