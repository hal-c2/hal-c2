# Sources:
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (paragraph and turn streaming, flush interval, next queued message)
#   apps/server-ex/lib/hal_c2/projection/timeline.ex (hidden items)
#   packages/contracts/src/orchestrationV2.ts (message.updated, run.created, run.updated, ResponseStreamingMode)
#   apps/web/src/components/settings/SettingsPanels.tsx (Response streaming)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Thinking, Thought, Working for, turn folds, Show full message)
#   apps/web/src/components/chat/MessagesTimeline.logic.ts
#   apps/web/src/components/chat/MessageCopyButton.tsx
#   apps/tui/src/timeline.ts (Worked for, You stopped after, running turn stays expanded)
#   apps/tui/src/orchestrationV2Adapter.ts (Thinking)
#   apps/tui/src/components/MessagesTimeline.tsx
#   apps/tui/src/components/WorkingIndicator.tsx
#   apps/server-ex/lib/hal_c2/web/socket.ex (stream snapshot after a reconnect, resync, unknown node)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (stream shape by node)

Feature: Streaming the agent's reply
  While a turn runs, the agent's text and reasoning arrive as they are written. When the
  turn settles, its work folds away so the conversation reads as a list of answers.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  @node
  Scenario: Paragraph streaming writes whole paragraphs as they finish
    Given the project streams responses by paragraph
    When the agent writes a reply of three paragraphs
    Then each paragraph appears once it is finished
    And an unfinished code block is held back until it closes

  @node
  Scenario: Turn streaming holds the reply until the turn reaches a boundary
    Given the project streams responses by turn
    When the agent writes a reply
    Then no reply text appears until the agent finishes writing it
    And tool calls and plans still appear as they happen

  # TUI: implemented in apps/tui/src/orchestrationV2Adapter.ts
  @shared @backlog-mobile @backlog-tui
  Scenario Outline: Reasoning shows while it is written and stays readable afterwards
    Given the agent is reasoning before it answers
    When the reasoning is <state>
    Then the reasoning is labelled "<label>"

    Examples:
      | state     | label    |
      | streaming | Thinking |
      | finished  | Thought  |

  # TUI: implemented in apps/tui/src/components/WorkingIndicator.tsx
  @shared @backlog-mobile @backlog-tui
  Scenario: A running turn shows how long the agent has been working
    When the agent has been working for 12 seconds
    Then the thread says the agent is working
    And the elapsed time keeps counting

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared @backlog-mobile @backlog-tui
  Scenario: A finished turn folds its work behind how long it took
    Given the agent ran four tool calls and then answered
    When the turn completes after 2 minutes
    Then the tool calls fold behind "Worked for 2m"
    And the answer stays visible

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared @backlog-mobile @backlog-tui
  Scenario: A folded turn can be opened and closed again
    Given a finished turn is folded behind "Worked for 2m"
    When the user opens the folded work
    Then its tool calls are shown
    When the user closes it again
    Then the tool calls fold away

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared @backlog-mobile @backlog-tui
  Scenario Outline: A stopped turn says who stopped it
    Given the user interrupted a turn <when>
    When the turn settles
    Then its work folds behind "<label>"

    Examples:
      | when                   | label                     |
      | after 40 seconds       | You stopped after 40s     |
      | before it did any work | You stopped this response |

  @shared @backlog
  Scenario: A turn interrupted in this session stays open
    Given the user interrupted the running turn a moment ago
    When the turn settles
    Then its work stays expanded so the user can see where it stopped

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog
  Scenario: A long message can be expanded and collapsed
    Given a message longer than the preview length
    When the user shows the full message
    Then the whole message is shown
    When the user shows less
    Then the message returns to its preview

  @shared @backlog-mobile @backlog-tui
  Scenario: The user copies an assistant reply
    Given the agent has answered
    When the user copies the reply
    Then the reply's markdown is on the clipboard

  @shared @backlog-mobile @backlog-tui
  Scenario: A reply that finishes while the connection is down is caught up
    Given the agent is writing a reply
    And the node drops the connection
    When the agent finishes the reply while the shell is disconnected
    And the shell reconnects to the node
    Then the whole reply is shown
    And the rows shown before are kept

  @shared @backlog-mobile @backlog-tui
  Scenario: A thread that falls behind is caught up from the node
    Given the agent is writing a reply
    When the agent writes more than the shell has read
    And the node tells the shell to resync the thread
    Then the whole reply is shown
    And the rows shown before are kept

  @shared @backlog-mobile @backlog-tui
  Scenario: A thread whose node leaves the cluster says so until the node returns
    Given the user is looking at a thread on another node of the cluster
    And the agent has answered "Use the tax table."
    When that node leaves the cluster
    Then the thread says its node cannot be reached
    And the answer "Use the tax table." is still shown
    When that node rejoins the cluster
    Then the thread follows its node again
    And the answer "Use the tax table." is still shown
