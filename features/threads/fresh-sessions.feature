# Sources:
#   https://github.com/pingdotgg/t3code/pull/30323
#   https://github.com/pingdotgg/t3code/pull/30325
#   mc/orchestration/provider-handoff.feature (the handoffs a fresh session bounds)
#   mc/orchestration/mcp-thread-tools.feature (the thread send tool)

Feature: Fresh sessions in the same thread
  A thread normally continues one provider conversation. A fresh session starts a new
  provider conversation in the same thread, with nothing handed over, so a long-lived
  thread can start over without becoming a new thread.

  Background:
    Given a connected environment with the thread "Triage" on Claude

  # Upstream #30323: a fresh send starts a brand-new provider conversation with no handoff.
  @backlog @mc @priority-high
  Scenario: A message sent fresh starts a new provider conversation in the thread
    Given "Triage" has several finished turns
    When a message is sent to "Triage" as a fresh session
    Then the agent starts a new conversation with none of the earlier turns handed over
    And the thread keeps its earlier turns in its history
    And the old Claude session is released once its background work is done

  # Upstream #30323: the latest fresh session is a boundary for every later handoff.
  @backlog @mc @priority-high
  Scenario Outline: Nothing from before a fresh session comes back when <later>
    Given "Triage" ran on Codex, then on Claude, and then started a fresh session on Claude
    When <later>
    Then the agent is given only the turns since the fresh session

    Examples:
      | later                                          |
      | the user switches "Triage" back to Codex       |
      | the agent's session is lost and restarted      |
      | a message queued behind the fresh session runs |

  # Upstream #30323: a message queued before the fresh one joins the new conversation.
  @backlog @mc
  Scenario: A message queued before a fresh session runs in the new conversation
    Given "Triage" is working with "also update docs" queued
    When a message is sent to "Triage" as a fresh session
    Then the fresh message waits for the current turn instead of steering it
    And "also update docs" runs in the new conversation after it

  # Upstream #30323
  @backlog @mc
  Scenario: A fresh session is refused while a fork or a merge back is pending
    Given a merge back into "Triage" is pending
    When a message is sent to "Triage" as a fresh session
    Then it is refused with the reason

  # Upstream #30325: /clear in the composer arms a fresh session for the next message.
  @backlog @shared @priority-high
  Scenario: /clear makes the next message start a fresh session
    When the user sends "/clear" in "Triage"
    Then the composer says the next message starts a fresh session
    When the user sends "start over on the billing bug"
    Then it starts a fresh session
    And the history shows a "New session" divider above it

  # Upstream #30325
  @backlog @shared
  Scenario: Dismissing the fresh-session notice keeps the current session
    Given the user sent "/clear" in "Triage"
    When the user dismisses the notice that the next message starts fresh
    Then the next message continues the current session

  # Upstream #30325: HAL-C2's /clear replaces the provider's own, which would clear a session
  # HAL-C2 still treats as live.
  @backlog @shared
  Scenario: The command list offers HAL-C2's /clear, not the provider's
    When the user types "/clear" in the composer of "Triage"
    Then the suggestions show one "/clear", which starts a fresh session

  # Upstream #30325: the phone keeps /clear with the draft and restores it with a refused message.
  @backlog @mobile
  Scenario: A refused fresh message comes back to the draft still fresh
    Given the user sent "/clear" and then "start over" from the phone
    When the MC refuses "start over"
    Then the draft holds "start over" and still starts a fresh session

  # Upstream #30325
  @backlog @shared
  Scenario: /clear is not offered by an MC that cannot start fresh sessions
    Given "Triage" is on an MC that does not report fresh sessions
    When the user types "/" in the composer
    Then "/clear" is not among the suggestions

  # Upstream #30325: agents can send fresh too.
  @backlog @mc
  Scenario: An agent sends a message to another thread as a fresh session
    Given an agent in "Plan billing" may write to "Triage"
    When it sends "summarise today's errors" to "Triage" as a fresh session
    Then "Triage" starts a fresh session with that message
