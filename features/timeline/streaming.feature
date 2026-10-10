# Sources:
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (paragraph and turn streaming, flush interval, next queued message)
#   apps/server-ex/lib/hal_c2/projection/timeline.ex (hidden items)
#   packages/contracts/src/orchestrationV2.ts (message.updated, run.created, run.updated, ResponseStreamingMode)
#   apps/web/src/components/settings/SettingsPanels.tsx (Response streaming)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Thinking, Thought, Working for, turn folds, Show full message)
#   apps/web/src/components/chat/MessagesTimeline.logic.ts
#   apps/web/src/components/chat/MessageCopyButton.tsx
#   apps/mobile/src/features/threads/ThreadFeed.tsx (empty conversation placeholder)
#   apps/web/src/timestampFormat.ts (formatDayAwareTimestamp, formatChatTimestampTooltip)
#   apps/tui/src/timeline.ts (Worked for, You stopped after, running turn stays expanded)
#   apps/tui/src/orchestrationV2Adapter.ts (Thinking)
#   apps/tui/src/components/MessagesTimeline.tsx
#   apps/tui/src/components/WorkingIndicator.tsx
#   packages/shared/src/orchestrationTiming.ts (when the working timer counts from, duration wording)
#   packages/shared/src/chatMessages.ts (how long a message the user sent may be before it is shortened)
#   apps/mobile/src/lib/threadActivity.ts (which turns fold and what stays outside the fold)
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

  # A picture reads as its description (remarkThoughtPreview).
  @shared @backlog-mobile @backlog-tui
  Scenario: Reasoning written in Markdown is labelled by its words alone
    Given the agent reasoned in Markdown
    Then the reasoning is labelled "Checking the cart total a chart"

  # TUI: implemented in apps/tui/src/components/WorkingIndicator.tsx
  @shared @backlog-mobile @backlog-tui
  Scenario: A running turn shows how long the agent has been working
    When the agent has been working for 12 seconds
    Then the thread says the agent is working
    And the elapsed time keeps counting

  # Legacy: packages/shared/src/orchestrationTiming.ts (deriveActiveWorkStartedAt: requestedAt floor)
  @backlog @desktop @mobile @tui
  Scenario: The working time counts from the message while the agent is still starting up
    Given the user sent a message and the agent's session is still starting
    When the agent has not yet begun the turn
    Then the thread says the agent is working
    And the elapsed time counts from when the message was sent
    And it does not disappear and come back when the agent begins

  # Legacy: packages/shared/src/orchestrationTiming.ts (formatDuration)
  @backlog @desktop @mobile @tui
  Scenario Outline: A duration is written in hours, minutes and seconds, leaving out empty steps
    When the thread shows a duration of <duration>
    Then it reads "<shown>"

    Examples:
      | duration          | shown   |
      | 340 milliseconds  | 340ms   |
      | 4.26 seconds      | 4.3s    |
      | 38 seconds        | 38s     |
      | 2 minutes         | 2m      |
      | 62 seconds        | 1m 2s   |
      | 1 hour 5 seconds  | 1h 5s   |

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

  # Legacy: packages/shared/src/chatMessages.ts (shouldCollapseUserMessage)
  @backlog @desktop @tui
  Scenario Outline: A message the user sent is shortened only when it is long
    Given the user sent a message of <message>
    When the user looks at it in the conversation
    Then it is <shown>

    Examples:
      | message                           | shown               |
      | 600 characters on one line        | shown in full       |
      | 601 characters on one line        | shortened           |
      | 8 short lines                     | shown in full       |
      | 9 short lines                     | shortened           |
      | only spaces and blank lines       | shown in full       |

  @shared @backlog-mobile
  Scenario: The user copies an assistant reply
    Given the agent has answered
    When the user copies the reply
    Then the reply's markdown is on the clipboard

  @backlog @desktop
  Scenario: A copied reply confirms itself beside its copy button for a moment
    Given the agent has answered
    When the user copies the reply
    Then the copy button shows that the reply was copied
    And that confirmation goes away after about a second

  @backlog @desktop
  Scenario: A reply that cannot be copied says why beside its copy button
    Given the agent has answered
    And the clipboard refuses the copy
    When the user copies the reply
    Then the user sees a "Failed to copy" message beside the copy button with the reason

  @backlog @desktop
  Scenario: A reply that finished with no text says so
    Given the agent's turn ended with a reply that has no text
    Then the reply reads "(empty response)"

  @backlog @mobile
  Scenario: A thread with no conversation yet suggests what to ask
    Given a thread has no messages and no work has started
    When the user opens it
    Then it says there is no conversation yet
    And it suggests asking the agent to inspect the repository, run a command or continue the thread

  @backlog @desktop
  Scenario: A reply still being written is not called empty
    Given the agent has started a reply and written nothing yet
    Then the reply shows no text and no "(empty response)"

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

  # The phone folds a settled turn behind how long it took, but not every turn and not everything in it.
  @backlog @mobile
  Scenario: A turn that failed is not folded
    Given the agent ran three tool calls and the turn then failed
    When the turn settles
    Then the three tool calls are shown one row each
    And the failure is shown after them
    And no "Worked for" row hides them

  @backlog @mobile
  Scenario: A fold keeps the first and last replies and any notice in view
    Given a turn in which the agent wrote a first reply, ran tool calls, wrote a reply in the middle and wrote a final reply
    And a notice from an automation arrived during the turn
    When the turn completes
    Then the tool calls and the reply in the middle fold behind "Worked for"
    And the first reply, the final reply and the notice stay shown

  @backlog @mobile
  Scenario: A turn that only compacted the context has nothing to fold
    Given the only work in a finished turn is a context compaction
    When the turn settles
    Then the compaction is shown on its own
    And no "Worked for" row is added

  @backlog @mobile
  Scenario: A turn that is still streaming a reply is not folded
    Given the run has ended but its last reply is still arriving
    Then the turn's work is shown
    When the reply is complete
    Then the turn's work folds behind how long it took
