# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/activity-log.md
#   packages/client-runtime/src/halC2ToolSummary.test.ts (summary counting rules)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Tool calls group, Tool call failed, tool statuses, workEntryIconName)
#   apps/web/src/components/chat/V2ItemInspector.tsx (call details, file changes, Open diff)
#   apps/web/src/components/chat/ChangedFilesTree.tsx
#   apps/web/src/components/DiffPanel.tsx
#   apps/tui/src/timeline.ts (+N previous tool calls, changed files per message)
#   apps/tui/src/worklog.ts (tool statuses)
#   apps/tui/src/diffSplit.ts
#   apps/tui/src/components/MessagesTimeline.tsx (changed-files tree, open diff per turn and per file)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (command, file, web and tool items)
#   packages/contracts/src/rpc.ts (orchestration.getTurnDiff, orchestration.getFullThreadDiff)

Feature: Tool calls and file changes
  The agent's work shows as tool calls between its messages. Calls group into a short
  summary, open into their details, and file changes lead to a diff of the turn.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared @backlog-mobile
  Scenario: Consecutive tool calls in a running turn show only the latest
    Given the agent has run five tool calls in a row in the running turn
    Then the latest tool call is shown
    And the other four are behind "+4 previous tool calls"

  @shared @backlog-mobile
  Scenario: The previous tool calls can be shown and hidden again
    Given the agent has run five tool calls in a row in the running turn
    When the user shows the previous tool calls
    Then all five tool calls are shown
    When the user hides them again
    Then the other four are behind "+4 previous tool calls"

  @shared @backlog-mobile @backlog-tui
  Scenario: A group of tool calls reads as a summary of what the agent did
    Given the agent ran two commands and sent messages to three threads
    When the user reads the activity group
    Then it reads "Ran 2 commands and sent messages to 3 threads"

  @shared @backlog-mobile @backlog-tui
  Scenario: A summary names at most two kinds of work
    Given the agent ran commands, changed files, searched the web and read files
    When the user reads the activity group
    Then the summary names commands and file changes
    And it counts the rest instead of naming them

  @shared @backlog-mobile @backlog-tui
  Scenario: Failed calls are not counted as work done
    Given the agent sent three messages and one of them failed
    When the user reads the activity group
    Then the summary counts two messages sent

  @shared @backlog-mobile @backlog-tui
  Scenario: A group opens into each call's details
    Given a collapsed group of tool calls
    When the user opens the group
    Then each call shows its command or input, its status and its exit code
    When the user closes the group
    Then the calls collapse back into the summary

  # TUI: implemented in apps/tui/src/worklog.ts
  @shared @backlog-mobile
  Scenario Outline: A tool call shows how it ended
    Given the agent's tool call <ended>
    Then the call is marked "<status>"

    Examples:
      | ended                    | status   |
      | is still running         | Running  |
      | failed                   | Failed   |
      | was declined by the user | Declined |
      | was interrupted          | Stopped  |

  @shared @backlog-mobile
  Scenario Outline: A tool call's icon says what kind of work it was
    Given the agent's most recent tool call <call>
    Then the call is shown with the "<icon>" icon

    Examples:
      | call               | icon           |
      | ran a command      | terminal       |
      | changed a file     | square-pen     |
      | searched the files | search         |
      | searched the web   | globe          |
      | called an MCP tool | wrench         |
      | asked for approval | message-circle |

  @mc @shared @backlog-mobile
  Scenario Outline: An ACP agent's read, search and fetch tools keep their meaning
    Given an ACP agent's tool call is of kind "<provider kind>"
    When the MC projects the call
    Then the timeline shows it as <timeline kind>

    Examples:
      | provider kind | timeline kind |
      | read          | a file read   |
      | search        | a file search |
      | fetch         | a web search  |

  # OpenCode announces a tool call before it has its input and names it once it runs.
  @mc
  Scenario Outline: An ACP read or search named only once it runs still says what it looked for
    Given an ACP agent announces a call of kind "<provider kind>" and names its input <when>
    When the MC projects the call
    Then the timeline shows it as <timeline kind>

    Examples:
      | provider kind | when             | timeline kind |
      | read          | while it runs    | a file read   |
      | search        | while it runs    | a file search |
      | read          | when it finishes | a file read   |
      | search        | when it finishes | a file search |

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile
  Scenario: Files changed by a turn are listed under its reply
    Given the agent changed "src/cart.ts" and "src/checkout.ts" in one turn
    When the turn completes
    Then the reply lists both files with their added and removed lines

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile
  Scenario: The user opens the diff of one turn
    Given a turn changed two files
    When the user opens that turn's changes
    Then the diff shows only what that turn changed, split per file

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile
  Scenario: The user opens the diff of a single changed file
    Given a turn changed "src/cart.ts" and "src/checkout.ts"
    When the user opens "src/cart.ts" from the list of changed files
    Then the diff shows only "src/cart.ts"

  @mc
  Scenario: The MC serves a turn's diff and the whole thread's diff
    Given a thread with three finished turns
    When a client asks for the diff of the second turn
    Then it receives the changes made during the second turn
    When a client asks for the whole thread's diff
    Then it receives the changes from before the first turn to after the last
