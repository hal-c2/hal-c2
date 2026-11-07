# Sources:
#   https://github.com/pingdotgg/t3code/pull/25437
#   https://github.com/pingdotgg/t3code/pull/24871
#   https://github.com/pingdotgg/t3code/pull/21314
#   https://github.com/pingdotgg/t3code/pull/23863
#   https://github.com/pingdotgg/t3code/pull/23904
#   https://github.com/pingdotgg/t3code/pull/16668
#   https://github.com/pingdotgg/t3code/pull/18835
#   https://github.com/pingdotgg/t3code/pull/18775
#   https://github.com/pingdotgg/t3code/pull/18120
#   https://github.com/pingdotgg/t3code/pull/21155
#   https://github.com/pingdotgg/t3code/pull/24781
#   https://github.com/pingdotgg/t3code/pull/26183
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

  # Upstream #24781: agents woken by a watch re-linked or re-watched the pull request.
  @backlog @mc
  Scenario: A wake says the pull request stays linked and watched
    When its checks start failing and the MC reads "acme/app#12" again
    Then the message to the agent of "t1" says "acme/app#12" stays linked and watched
    And it tells the agent not to link, watch or list it again

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

  # Upstream #18120: Forgejo comments keep their edit time, so an edited comment is news
  # once, the way a new comment is.
  @mc @backlog
  Scenario: An edited comment wakes the thread once
    Given the agent of "t1" was woken for a comment from the owner
    When the owner edits that comment and the MC reads "acme/app#12" again
    Then the agent of "t1" is woken once about "acme/app#12"
    When the MC reads "acme/app#12" again
    Then the agent of "t1" is not woken again

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

  # Upstream #21314: a wake queued before another provider took over ran on the old provider.
  @backlog @mc @priority-high
  Scenario: A wake queued before a provider takeover runs on the provider that took over
    Given a wake about "acme/app#12" is queued for "t1" while it works on Codex
    When Claude takes over "t1" before the wake is delivered
    Then the wake runs on Claude with the thread's current model and options
    And "t1" stays on Claude

  # Upstream #21314: a queued wake was spent on a provider still at its usage limit.
  @backlog @mc
  Scenario: A queued wake waits while the thread's provider is at its usage limit
    Given "t1" is on Codex and Codex has reached its usage limit
    And a wake about "acme/app#12" is queued for "t1"
    When the queue resumes
    Then the wake stays queued until Codex is usable again

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

  # Upstream #21155: a watch that ends keeps the check and conflict state it reported, so
  # watching the pull request again does not repeat news the thread already got.
  @mc @backlog
  Scenario Outline: A thread brought back is not told again what it heard before
    Given the agent of "t1" was woken because the checks of "acme/app#12" passed
    And thread "t1" is <put away>
    When a client <brings it back> "t1"
    And the MC reads "acme/app#12" again with nothing changed
    Then the agent of "t1" is not woken

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
  Scenario Outline: A handover cut short completes on a child put away since
    Given thread "worker" works on a task "t1" delegated and links pull request "acme/app#14", which the MC has read once
    And the task of "worker" ended without handing its pull requests over
    And thread "worker" is <put away>
    When the owner comments and the MC reads "acme/app#14" again
    And the MC reads "acme/app#14" again
    Then thread "worker" no longer links "acme/app#14"
    And the agent of "t1" is woken once about "acme/app#14"
    And the message says "New comment from owner-1."

    Examples:
      | put away |
      | settled  |
      | archived |

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

  # Upstream #18775: a failed optional check stopped a Forgejo watch from passing.
  @backlog @mc @priority-low
  Scenario: A Forgejo watch passes when the required checks pass
    Given a thread watches the checks of a Forgejo pull request whose branch requires "ci/test"
    When "ci/test" passes and an optional "ci/lint" fails
    Then the thread hears that the required checks passed

  # Upstream #26183: required-check globs became backtracking regexes, and a pattern with many
  # stars blocked the server for every client.
  @backlog @mc @priority-high
  Scenario: A Forgejo required-check pattern with many wildcards does not stall the MC
    Given a thread watches the checks of a Forgejo pull request whose branch requires "*a*a*a*a*a*a*a*a*a*a*a*a*b"
    When the MC compares it with check names 200 characters long
    Then the comparison finishes at once
    And other clients of the MC are answered meanwhile

  # Upstream #26183: "*" and "**" match any run of characters, "/" included, and "?" one
  # character; patterns with classes, choices or escapes are reported as not evaluable.
  @backlog @mc @priority-low
  Scenario Outline: A Forgejo required-check pattern is matched as a glob
    Given a thread watches the checks of a Forgejo pull request whose branch requires "<pattern>"
    When a check named "<name>" reports
    Then the requirement <result>

    Examples:
      | pattern | name          | result                       |
      | ci/*    | ci/test/linux | matches it                   |
      | ci/**   | ci/test/linux | matches it                   |
      | ci/tes? | ci/test       | matches it                   |
      | ci/tes? | ci/tests      | does not match it            |
      | ci/[ab] | ci/a          | is reported as not evaluable |

  # Upstream #16668: Forgejo reports a job that did not run as "skipped", which was read as pending
  # and kept the watch open after every job had finished.
  @backlog @mc @priority-low
  Scenario Outline: A Forgejo job that did not run does not keep the watch waiting
    Given a thread watches the checks of a Forgejo pull request
    When "ci/test" passes and "ci/docs" reports "<state>"
    Then the watch counts "ci/docs" as <counted> and the checks as finished

    Examples:
      | state   | counted |
      | skipped | skipped |
      | warning | neutral |

  # Upstream #24871: Forgejo dates statuses to the second, so a pending status could replace the
  # final one it shared a second with.
  @backlog @mc @priority-low
  Scenario: A Forgejo check that finished within a second of starting counts as finished
    Given a thread watches the checks of a Forgejo pull request
    When "ci/test" reports pending and then success in the same second
    Then the watch counts "ci/test" as passed
    And the thread is woken with "All checks passed"

  # Upstream #23904: the watch said the required checks passed while other jobs still ran, and
  # never woke the thread when they finished.
  @backlog @mc
  Scenario: A watch that reported required checks early wakes once more when the rest finish
    Given a thread watches the checks of a pull request whose branch requires "ci/test"
    And the thread heard that "ci/test" passed while "ci/e2e" was still running
    When "ci/e2e" passes on the same commit
    Then the thread is woken once with "All 2 checks passed"
    And a later optional job on that commit does not wake it again

  # Upstream #23863: a GitHub workflow that skips the change, such as a docs-only one, reports no
  # checks at all, and the watch waited forever.
  @backlog @mc
  Scenario: A watched GitHub pull request with no checks wakes the thread once
    Given a thread watches the checks of a GitHub pull request
    When no check appears on its latest commit for more than 15 minutes
    Then the thread is woken once, told no checks have reported
    And the message does not say the checks passed
    And neither a restart nor watching it again wakes the thread for that commit again

  # Upstream #25437: nothing on the host changed when the 15 minutes passed, so the notice waited
  # for the next full reread, about 30 minutes in.
  @backlog @mc @priority-low
  Scenario: A watched pull request with no checks is told within minutes of the deadline
    Given a thread watches the checks of a GitHub pull request
    And nothing about the pull request changes on GitHub
    When 15 minutes pass with no check on its latest commit
    Then the thread is told no checks have reported within the next two minutes
    And its comments are not read any more often

  # Upstream #23863: a watch whose checks were seen is not told that none reported.
  @backlog @mc @priority-low
  Scenario: A GitHub pull request whose checks were seen does not count as having none
    Given a thread watches a GitHub pull request whose checks were seen running on its latest commit
    When no check is listed for more than 15 minutes
    Then the thread is not told no checks have reported

  # Upstream #18835: an edit beyond the first page of replies kept the cached reply.
  @backlog @mc @priority-low
  Scenario: An edited reply deep in a review thread reaches the watching agent
    Given a thread watches a review thread with more replies than fit in one page
    When a reviewer edits a reply on a later page
    Then the thread reads the edited reply
