# Sources:
#   https://github.com/pingdotgg/t3code/pull/29053

# Upstream #29053: threads carry tags, and a machine's settings can hide tagged threads, for
# example while the user records their screen. There is no tag UI; hiding is display-only.
@priority-low
Feature: Thread tags
  A thread can carry tags. Each machine's settings name the tags to hide and switch hiding on
  or off. Hidden threads leave what the user sees and keep running.

  @backlog @mc
  Scenario: Tagging a thread does not move it in the lists
    Given the threads "Plan billing" and "Fix login" in that order in Active
    When a client tags "Fix login" with "demo"
    Then "Fix login" carries the tag "demo"
    And the threads are still in the same order

  @backlog @mc
  Scenario: Removing a tag leaves the thread's other tags
    Given "Fix login" carries the tags "demo" and "secret"
    When a client removes the tag "demo" from "Fix login"
    Then "Fix login" carries only the tag "secret"

  @backlog @mc
  Scenario: A fork keeps its source's tags
    Given "Plan billing" carries the tag "demo"
    When a client forks "Plan billing"
    Then the fork carries the tag "demo"

  @backlog @shared
  Scenario: Switching hiding on hides tagged threads at once
    Given the machine's settings hide threads tagged "demo" with hiding switched off
    And "Fix login" carries the tag "demo"
    When the settings file is changed to switch hiding on
    Then "Fix login" leaves the thread list, the command palette, mentions and notifications
    And switching hiding off brings it back

  @backlog @shared
  Scenario: A hidden thread keeps running
    Given "Fix login" is hidden by its tag while its agent works
    When the agent's turn finishes
    Then the turn is complete on the MC
    And no notification names "Fix login"

  @backlog @shared
  Scenario: A hidden thread's subagents and side chats are hidden with it
    Given "Fix login" is hidden by its tag
    And "Fix login" has a subagent and a side chat with no tags
    Then neither the subagent nor the side chat is shown

  # Hiding too much while recording is fine; showing too much is not.
  @backlog @shared
  Scenario: A thread that cannot be judged stays hidden while hiding is on
    Given hiding tagged threads is switched on
    And a pull request links a thread this client has not loaded
    When the user looks at the pull request's threads
    Then that thread is not shown

  @backlog @mc
  Scenario: A hidden tag list with a bad entry keeps the rest of the settings
    Given the settings file's hidden tags list holds "demo" and the number 3
    When the MC reads its settings
    Then threads tagged "demo" are hidden
    And the other settings are kept
