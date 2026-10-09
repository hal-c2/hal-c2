# Sources:
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (paragraph and turn streaming, flush interval, next queued message)
#   apps/server-ex/lib/hal_c2/projection/timeline.ex (hidden items)
#   packages/contracts/src/orchestrationV2.ts (message.updated, run.created, run.updated, ResponseStreamingMode)
#   apps/web/src/components/settings/SettingsPanels.tsx (Response streaming)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Thinking, Thought, Working for, turn folds, Show full message)
#   apps/web/src/components/chat/MessagesTimeline.logic.ts
#   apps/web/src/components/chat/MessageCopyButton.tsx
#   apps/web/src/timestampFormat.ts (formatDayAwareTimestamp, formatChatTimestampTooltip)
#   apps/tui/src/timeline.ts (Worked for, You stopped after, running turn stays expanded)
#   apps/tui/src/orchestrationV2Adapter.ts (Thinking)
#   apps/tui/src/components/MessagesTimeline.tsx
#   apps/tui/src/components/WorkingIndicator.tsx
#   apps/server-ex/lib/hal_c2/web/socket.ex (stream snapshot after a reconnect, resync, unknown MC)
#   apps/server-ex/lib/hal_c2/web/protocol.ex (stream shape by environment)
#   apps/desktop-qt/src/native/ThreadStore.cpp (reload, retrying a thread its MC stopped sending)
#   apps/desktop-qt/src/native/TimelineModel.cpp (the thread's cursor, a catch-up applied whole)
#   apps/server-ex/lib/hal_c2/streams/server.ex (resuming from an offset, a catch-up in several parts)

Feature: Streaming the agent's reply
  While a turn runs, the agent's text and reasoning arrive as they are written. When the
  turn settles, its work folds away so the conversation reads as a list of answers.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  @mc
  Scenario: Paragraph streaming writes whole paragraphs as they finish
    Given the project streams responses by paragraph
    When the agent writes a reply of three paragraphs
    Then each paragraph appears once it is finished
    And an unfinished code block is held back until it closes

  @mc
  Scenario: Turn streaming holds the reply until the turn reaches a boundary
    Given the project streams responses by turn
    When the agent writes a reply
    Then no reply text appears until the agent finishes writing it
    And tool calls and plans still appear as they happen

  # TUI: implemented in apps/tui/src/orchestrationV2Adapter.ts
  @shared @backlog-mobile
  Scenario: Reasoning shows while it is written
    Given the agent is reasoning before it answers
    When the reasoning is streaming
    Then the reasoning is labelled "Thinking"

  # The web's row (MessagesTimeline.tsx, remarkThoughtPreview). The TUI still says "Thought".
  @shared @backlog-mobile @backlog-tui
  Scenario: Finished reasoning is labelled by what was thought
    Given the agent is reasoning before it answers
    When the reasoning is finished
    Then the reasoning is labelled "The cart total needs"

  # TUI: implemented in apps/tui/src/components/WorkingIndicator.tsx
  @shared @backlog-mobile @backlog-tui
  Scenario: A running turn shows how long the agent has been working
    When the agent has been working for 12 seconds
    Then the thread says the agent is working
    And the elapsed time keeps counting

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared @backlog-mobile
  Scenario: A finished turn folds its work behind how long it took
    Given the agent ran four tool calls and then answered
    When the turn completes after 2 minutes
    Then the tool calls fold behind "Worked for 2m"
    And the answer stays visible

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared @backlog-mobile
  Scenario: A folded turn can be opened and closed again
    Given a finished turn is folded behind "Worked for 2m"
    When the user opens the folded work
    Then its tool calls are shown
    When the user closes it again
    Then the tool calls fold away

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared @backlog-mobile
  Scenario Outline: A stopped turn says who stopped it
    Given the user interrupted a turn <when>
    When the turn settles
    Then its work folds behind "<label>"

    Examples:
      | when                   | label                     |
      | after 40 seconds       | You stopped after 40s     |
      | before it did any work | You stopped this response |

  @shared @backlog-mobile
  Scenario: A turn interrupted in this session stays open
    Given the user interrupted the running turn a moment ago
    When the turn settles
    Then its work stays expanded so the user can see where it stopped

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile
  Scenario: A long message can be expanded and collapsed
    Given a message longer than the preview length
    When the user shows the full message
    Then the whole message is shown
    When the user shows less
    Then the message returns to its preview

  @shared @backlog-mobile
  Scenario: The user copies an assistant reply
    Given the agent has answered
    When the user copies the reply
    Then the reply's markdown is on the clipboard

  @shared @backlog-mobile @backlog-tui
  Scenario: Only a turn's last reply carries its time and actions
    Given the agent commented, ran a tool call and then answered
    Then neither message shows its time and actions while the agent works
    When the turn completes after 2 minutes
    And the user opens the folded work
    Then only the answer shows its time and actions

  @shared @backlog-mobile @backlog-tui
  Scenario Outline: A message says when it was sent, in the time format the user chose
    Given this device's "timestampFormat" is set to "<format>"
    When the user sent a message today at 9:05 in the morning
    Then the message is stamped "<stamp>"

    Examples:
      | format  | stamp   |
      | locale  | 9:05 AM |
      | 12-hour | 9:05 AM |
      | 24-hour | 09:05   |

  @shared @backlog-mobile @backlog-tui
  Scenario Outline: A message from an earlier day also says which day it was sent
    When the user sent a message <when> at 9:05 in the morning
    Then the message is stamped "<stamp>"
    And its full time reads "<full>"

    Examples:
      | when                 | stamp                | full                              |
      | yesterday            | yesterday at 9:05 AM | 9:05 AM, 22nd September 2026      |
      | on September 20      | 9/20 9:05 AM         | 9:05 AM, 20th September 2026      |
      | on December 30, 2025 | 12/30/2025 9:05 AM   | 9:05 AM, 30th December 2025       |

  @shared @backlog-mobile @backlog-tui
  Scenario: A reply that finishes while the connection is down is caught up
    Given the agent is writing a reply
    And the MC drops the connection
    When the agent finishes the reply while the shell is disconnected
    And the shell reconnects to the MC
    Then the whole reply is shown
    And the rows shown before are kept
    And the MC sends only what the client lacks

  @shared @backlog-mobile @backlog-tui
  Scenario: A catch-up cut off part-way is not applied twice
    Given the agent is writing a reply
    And the agent finishes the reply while the MC cannot be reached
    When the MC is back and the connection drops again part-way through the catch-up
    Then the whole reply is shown
    And the rows shown before are kept
    And the client asked again from where it was

  @shared @backlog-mobile @backlog-tui
  Scenario: A thread that falls behind is caught up from the MC
    Given the agent is writing a reply
    When the agent writes more than the shell has read
    And the MC tells the shell to resync the thread
    Then the whole reply is shown
    And the rows shown before are kept

  @shared @backlog-mobile @backlog-tui
  Scenario: A thread whose MC leaves the cluster says so until the MC returns
    Given the user is looking at a thread on another MC of the cluster
    And the agent has answered "Use the tax table."
    When that MC leaves the cluster
    Then the thread says its MC cannot be reached
    And the answer "Use the tax table." is still shown
    When that MC rejoins the cluster
    Then the thread follows its MC again
    And the answer "Use the tax table." is still shown

  # MCs join only by clustering; the scenario above is the one way to another machine.
  @dropped @shared
  Scenario: A thread on an environment the MC is linked to says so while the link is down
    Given the user is looking at a thread on an environment the MC is linked to
    And the agent has answered "Deploy when green."
    When that environment becomes unreachable
    Then the thread says its MC cannot be reached
    And the answer "Deploy when green." is still shown
    When that environment is reachable again
    Then the thread follows its MC again
    And the answer "Deploy when green." is still shown

  @desktop
  Scenario: Retrying follows the thread again once its MC sends it
    Given the agent has answered "The cart has tax."
    When the MC stops sending the thread
    Then the thread says its MC cannot be reached
    When the user retries the thread
    Then the thread is still unreachable
    When the MC can send the thread again
    And the user retries the thread
    Then the thread follows its MC again
    And the answer "The cart has tax." is still shown
