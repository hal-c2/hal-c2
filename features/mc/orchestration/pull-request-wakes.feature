# Sources:
#   https://github.com/hal-c2/hal-c2/issues/518
#   apps/server-ex/lib/hal_c2/pull_requests/wakes.ex
#   apps/server-ex/lib/hal_c2/pull_requests/sync.ex (the sweep that reads each link's host state)
#   apps/server-ex/lib/hal_c2/pull_requests/github.ex (@summary_selection: the review and comment marker)
#   https://github.com/hal-c2/hal-c2/issues/662
#   apps/server-ex/lib/hal_c2/orchestration/delegation.ex (results are notifications that wake the agent; a finished task hands its links to its caller)
#   apps/server-ex/lib/hal_c2/mcp/tools/pull_requests.ex (list_thread_pull_requests, unlink_pull_request)
#   packages/contracts/src/orchestration.ts (ThreadPullRequestLink heard, ThreadPullRequestSnapshot activity)
#   packages/contracts/src/orchestrationV2.ts (OrchestrationV2Notification pull_request source)
Feature: A thread hears when a pull request it owns needs attention
  A thread owns the pull requests it links, while it is neither settled nor
  archived. When one of them changes in a way worth acting on, the MC tells the
  thread's agent, the way a delegated task's result does: a notification in the
  timeline that wakes the agent once the thread is idle. What the thread heard
  is remembered, so the same news never wakes it twice. Unlinking the pull
  request or settling the thread stops the wakes.

  Background:
    Given an MC with a project "demo" on GitHub "acme/app"
    And thread "t1" in "demo" links pull request "acme/app#12", which the MC has read once

  @mc
  Scenario Outline: A change worth acting on wakes the thread
    When <change> and the MC reads "acme/app#12" again
    Then the agent of "t1" is woken once about "acme/app#12"
    And the message says "<says>"
    And the timeline of "t1" shows the notification "<summary>"

    Examples:
      | change                                            | says                                          | summary                     |
      | its checks start failing                          | Checks are failing.                           | acme/app#12: checks failing |
      | a member publishes a review that asks for changes | New review from member-1 (changes requested). | acme/app#12: new review     |
      | the owner comments                                | New comment from owner-1.                     | acme/app#12: new comment    |
      | it comes to conflict with its base branch         | It conflicts with its base branch.            | acme/app#12: merge conflict |

  # A thread whose pull requests are all done settles on its own, unless the user
  # keeps it active or another of them is still open.
  @mc
  Scenario Outline: A merge or a close wakes a thread that does not settle on its own
    Given the user keeps "t1" active
    When <change> and the MC reads "acme/app#12" again
    Then the agent of "t1" is woken once about "acme/app#12"
    And the message says "<says>"

    Examples:
      | change                       | says                           |
      | it is merged                 | It was merged.                 |
      | it is closed without merging | It was closed without merging. |

  @mc
  Scenario: A merge that settles the thread settles it instead of waking it
    When it is merged and the MC reads "acme/app#12" again
    Then thread "t1" settles
    And the agent of "t1" is not woken

  @mc
  Scenario Outline: Reviews and comments wake the thread only from authors it trusts
    When <author> comments and the MC reads "acme/app#12" again
    Then the agent of "t1" <woken>

    Examples:
      | author                                | woken                              |
      | a collaborator                        | is woken once about "acme/app#12"  |
      | the account the MC is signed in as    | is woken once about "acme/app#12"  |
      | Copilot                               | is woken once about "acme/app#12"  |
      | Codex                                 | is woken once about "acme/app#12"  |
      | a contributor from outside the repository | is not woken                   |

  @mc
  Scenario Outline: Changes that are not worth acting on wake nothing
    When <change> and the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken

    Examples:
      | change                                               |
      | its title changes                                    |
      | its checks start running                             |
      | its checks pass without having failed                |
      | a member starts a review without publishing it       |

  @mc
  Scenario: Checks that pass after the thread heard they failed are worth one notice
    Given the agent of "t1" was woken because the checks of "acme/app#12" failed
    When its checks pass and the MC reads "acme/app#12" again
    Then the agent of "t1" is woken once about "acme/app#12"
    And the message says "Checks pass again."
    When the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken again

  @mc
  Scenario: Changes that land before the thread can take them share one wake
    Given the agent of "t1" is working
    When its checks start failing and the MC reads "acme/app#12" again
    And the owner comments and the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken
    When the turn of "t1" ends
    Then the agent of "t1" is woken once about "acme/app#12"
    And the message says "Checks are failing."
    And the message says "New comment from owner-1."

  # The account the MC reads GitHub as is often the one the agent posts with, so what
  # it posts while the thread works is the agent's own.
  @mc
  Scenario: A comment the agent posts while it works does not wake it
    Given the agent of "t1" is working
    When the agent comments as the account the MC is signed in as and the MC reads "acme/app#12" again
    And the turn of "t1" ends
    Then the agent of "t1" is not woken

  @mc
  Scenario: A review that lands while the agent works still wakes it after the agent's own comment
    Given the agent of "t1" is working
    When a member publishes a review that asks for changes and the MC reads "acme/app#12" again
    And the agent comments as the account the MC is signed in as and the MC reads "acme/app#12" again
    And the turn of "t1" ends
    Then the agent of "t1" is woken once about "acme/app#12"
    And the message says "New review from member-1 (changes requested)."

  @mc
  Scenario: The message names the pull request and how to read more
    When its checks start failing and the MC reads "acme/app#12" again
    Then the agent of "t1" is woken once about "acme/app#12"
    And the message says "acme/app#12 https://github.com/acme/app/pull/12"
    And the message says "gh pr checks https://github.com/acme/app/pull/12"
    And the message says "gh api repos/acme/app/pulls/12/reviews"
    And the message says "list_thread_pull_requests"

  @mc
  Scenario: News the thread already heard does not wake it again
    Given the agent of "t1" was woken because the checks of "acme/app#12" failed
    When the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken again

  @mc
  Scenario: A restart does not wake a thread for what it already heard
    Given the agent of "t1" was woken because the checks of "acme/app#12" failed
    When the MC restarts and reads "acme/app#12" again
    Then the agent of "t1" is not woken again

  @mc
  Scenario: A newly linked pull request is a baseline, not news
    Given pull request "acme/app#13" has failing checks, a conflict and a comment from its owner
    When a client links pull request "acme/app#13" to "t1" and the MC reads it
    Then the agent of "t1" is not woken

  @mc
  Scenario: A pull request linked to two threads wakes both
    Given thread "t2" in "demo" also links pull request "acme/app#12", which the MC has read once
    When its checks start failing and the MC reads "acme/app#12" again
    Then the agent of "t1" is woken once about "acme/app#12"
    And the agent of "t2" is woken once about "acme/app#12"

  @mc
  Scenario Outline: A settled or archived thread is never woken
    Given thread "t1" is <put away>
    When its checks start failing and the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken

    Examples:
      | put away |
      | settled  |
      | archived |

  @mc
  Scenario Outline: A thread brought back hears what it missed in one message
    Given thread "t1" is <put away>
    When the owner comments and the MC reads "acme/app#12" again
    And its checks start failing and the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken
    When a client <brings it back> "t1"
    And the MC reads "acme/app#12" again
    Then the agent of "t1" is woken once about "acme/app#12"
    And the message says "New comment from owner-1."
    And the message says "Checks are failing."

    Examples:
      | put away | brings it back |
      | settled  | unsettles      |
      | archived | unarchives     |

  # A delegated task's child stops owning its pull requests when its task ends, so
  # their reviews wake the thread that delegated it, which may have handed the work
  # to a newer task, instead of reviving the old child beside it.
  @mc
  Scenario: A finished task's pull requests pass to the thread that delegated it
    Given thread "worker" works on a task "t1" delegated and links pull request "acme/app#14", which the MC has read once
    When the task of "worker" ends
    Then thread "t1" links "acme/app#14"
    And thread "worker" no longer links "acme/app#14"
    When a member publishes a review that asks for changes and the MC reads "acme/app#14" again
    Then the agent of "worker" is not woken
    And the agent of "t1" is woken once about "acme/app#14"

  @mc
  Scenario: News the finished task was not told yet reaches the thread that delegated it
    Given thread "worker" works on a task "t1" delegated and links pull request "acme/app#14", which the MC has read once
    And the agent of "worker" is working
    When the owner comments and the MC reads "acme/app#14" again
    And the task of "worker" ends
    And the MC reads "acme/app#14" again
    Then the agent of "worker" is not woken
    And the agent of "t1" is woken once about "acme/app#14"
    And the message says "New comment from owner-1."

  @mc
  Scenario: The thread that delegated keeps what it heard of a pull request it links too
    Given thread "worker" works on a task "t1" delegated and links pull request "acme/app#12", which the MC has read once
    And the agent of "worker" is working
    And the agent of "t1" was woken because the checks of "acme/app#12" failed
    When the task of "worker" ends
    Then thread "worker" no longer links "acme/app#12"
    When the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken again
    And the agent of "worker" is not woken

  @mc
  Scenario: A handover cut short completes once there is news
    Given thread "worker" works on a task "t1" delegated and links pull request "acme/app#14", which the MC has read once
    And the task of "worker" ended without handing its pull requests over
    When the owner comments and the MC reads "acme/app#14" again
    And the MC reads "acme/app#14" again
    Then thread "worker" no longer links "acme/app#14"
    And the agent of "worker" is not woken
    And the agent of "t1" is woken once about "acme/app#14"
    And the message says "New comment from owner-1."

  @mc
  Scenario: Unlinking the pull request stops the wakes
    When a client unlinks pull request "acme/app#12" from "t1"
    And its checks start failing and the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken

  @mc
  Scenario: A host that cannot be reached wakes nothing
    Given the host cannot be reached
    When the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken
    And thread "t1" still shows "acme/app#12" as open
