# Sources:
#   https://github.com/pingdotgg/t3code/pull/26901
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

  # Upstream #26901
  @backlog @mc @priority-high
  Scenario: A side chat's first turn asks before it acts
    Given "Plan billing" runs in full access
    When the user asks a side chat of it a question
    Then the side chat's first turn runs supervised
    And it records no checkpoints of the files it shares with "Plan billing"

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

  # Upstream #26901: starting one stays on the desktop for now; the phone lists them to answer them.
  @backlog @mobile
  Scenario: The phone lists a thread's side chats so their approvals can be answered
    Given a side chat of "Plan billing" waits for an approval
    When the user opens "Plan billing" on the phone
    Then its side chats are listed
    And the user can open the side chat and answer the approval
