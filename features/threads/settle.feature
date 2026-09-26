# Sources:
#   docs/user/thread-sidebar.md (Settling, Auto-settle rules)
#   apps/web/src/components/threadActionMenu.logic.ts (Settle thread, Un-settle thread)
#   apps/web/src/components/settings/SettingsPanels.tsx (General: auto-settle rules)
#   apps/desktop-qt/qml/T3/Bricks/Sidebar.qml (Settled section, settled limit)
#   apps/desktop-qt/qml/T3/Bricks/SidebarThreadRow.qml (Settle, Un-settle)
#   apps/tui/src/components/Sidebar.logic.ts (Settled section, paging)
#   apps/tui/src/commands.ts (Settle, Un-settle)
#   packages/contracts/src/orchestrationV2.ts (thread.settle, thread.auto-settle, thread.unsettle, thread.settled, thread.unsettled)
#   apps/server-ex/lib/t3/orchestration.ex (settle, unsettle)
#   apps/server-ex/lib/t3/orchestration/settlement.ex

Feature: Settling threads
  Settling marks a thread as done without archiving it. Threads also settle on their own
  after a quiet spell or when their pull request merges.

  Background:
    Given a connected environment with the idle thread "Ship checkout" in the project "shop"

  @desktop @tui
  Scenario: Settling a thread
    When the user settles "Ship checkout"
    Then "Ship checkout" moves to the settled section

  @desktop @tui
  Scenario: Un-settling a thread
    Given "Ship checkout" is settled
    When the user un-settles "Ship checkout"
    Then "Ship checkout" returns to the top of the active threads

  @tui
  Scenario: Settling reports the result
    When the user settles "Ship checkout" from the command palette
    Then the status line reads "Settled."

  @tui
  Scenario: A failed settle is reported
    Given the environment rejects the settle
    When the user settles "Ship checkout"
    Then the status line reports that the settle failed and why
    And "Ship checkout" stays active

  @backlog @desktop @mobile
  Scenario: Settling a pinned thread removes the pin
    Given "Ship checkout" is pinned
    When the user settles "Ship checkout"
    Then "Ship checkout" is settled and no longer pinned

  @backlog @desktop @mobile
  Scenario: Settling dismisses questions the agent is waiting on
    Given the agent in "Ship checkout" asked a question in the background
    When the user settles "Ship checkout"
    Then the question is dismissed

  @backlog @desktop @mobile
  Scenario: Settling a snoozed thread ends the snooze
    Given "Ship checkout" is snoozed until tomorrow
    When the user settles "Ship checkout"
    Then "Ship checkout" is settled and no longer snoozed

  @desktop @tui
  Scenario: A thread whose pull request merges moves to the settled section on its own
    Given "Ship checkout" is linked to a pull request
    When the pull request is merged on GitHub
    Then "Ship checkout" moves to the settled section without the user settling it

  @backlog @mobile
  Scenario: A thread whose pull request merges leaves the phone's active list on its own
    Given "Ship checkout" is linked to a pull request
    When the pull request is merged on GitHub
    Then "Ship checkout" is shown as settled on the phone

  @node
  Scenario: A thread settles after a quiet spell
    Given the auto-settle rule is "after 3 days of inactivity"
    When "Ship checkout" has had no activity for 3 days
    Then "Ship checkout" is settled automatically

  @node
  Scenario: A thread settles when its pull request merges
    Given "Ship checkout" is linked to a pull request
    When the pull request is merged
    Then "Ship checkout" is settled automatically

  @node
  Scenario: A closed pull request settles an idle thread
    Given "Ship checkout" is linked to a pull request
    And the user has not written since the pull request was closed
    When the settle sweep runs
    Then "Ship checkout" is settled automatically

  # A pull request the user linked by hand keeps the thread active while it is open;
  # one only discovered from the branch does not.
  @node
  Scenario: An open pull request found on the branch does not keep a quiet thread active
    Given "Ship checkout" is on a branch with an open pull request
    And the auto-settle rule is "after 3 days of inactivity"
    When "Ship checkout" has had no activity for 3 days
    Then "Ship checkout" is settled automatically

  @node
  Scenario Outline: Work in progress keeps a thread from settling on its own
    Given "Ship checkout" has had no activity for 3 days
    And "Ship checkout" <state>
    When the settle sweep runs
    Then "Ship checkout" stays active

    Examples:
      | state                                     |
      | has an agent run in progress              |
      | is waiting for an approval or an answer   |
      | is still snoozed                          |
      | received a message from the user just now |

  @node
  Scenario: A thread resumed after its pull request merged does not settle again from that merge
    Given "Ship checkout" was linked to a pull request that merged last week
    When the user sends a new message in "Ship checkout"
    And the settle sweep runs
    Then "Ship checkout" stays active

  @node
  Scenario: Un-settling keeps a thread from settling until there is new activity
    Given "Ship checkout" settled automatically
    When the user un-settles "Ship checkout"
    And the settle sweep runs
    Then "Ship checkout" stays active

  @node
  Scenario: An automatic settle that races new activity is dropped
    Given the settle sweep decided to settle "Ship checkout"
    When the user writes in "Ship checkout" before the settle is applied
    Then "Ship checkout" stays active

  @node
  Scenario: A project can have its own quiet spell
    Given the environment settles threads after 3 days
    And the project "shop" settles threads after 1 day
    When "Ship checkout" has had no activity for 1 day
    Then "Ship checkout" is settled automatically

  @node
  Scenario: Changing the rules does not reopen settled threads
    Given "Ship checkout" settled automatically after 3 days
    When the user changes the rule to "after 7 days of inactivity"
    Then "Ship checkout" stays settled

  @node
  Scenario: The settle sweep runs again when something relevant changes
    When an agent run ends, a pull request changes or the auto-settle settings change
    Then the settle sweep runs without waiting for the next minute

  # docs/user/thread-sidebar.md says pinning does not prevent automatic settlement, but
  # both servers skip pinned threads and hal-c2 keeps that: a pin means "leave this alone".
  # The docs line is stale. Engine detail: node/orchestration/auto-settle.feature.
  @node
  Scenario: A pinned thread is never settled on its own
    Given "Ship checkout" is pinned
    And the auto-settle rule is "after 3 days of inactivity"
    When "Ship checkout" has had no activity for 3 days
    Then "Ship checkout" stays active and pinned

  @backlog @desktop @mobile
  Scenario Outline: Choosing auto-settle rules for an environment
    When the user sets auto-settle to <rule> for <scope>
    Then threads on <affected> follow the new rule

    Examples:
      | rule                | scope                  | affected          |
      | after 7 days        | the environment "home" | "home" only       |
      | never on inactivity | all environments       | every environment |
      | when the PR merges  | all environments       | every environment |

  @backlog @desktop @mobile
  Scenario: Different rules across environments are shown as mixed
    Given "home" settles after 3 days and "work" settles after 7 days
    When the user looks at the auto-settle rules for all environments
    Then the quiet spell is shown as mixed

  @backlog @desktop @mobile
  Scenario: An offline environment keeps its auto-settle rules
    Given the environment "work" is offline
    When the user changes the auto-settle rules for all environments
    Then "work" keeps its previous rules
    And the user can see "work" was not updated
