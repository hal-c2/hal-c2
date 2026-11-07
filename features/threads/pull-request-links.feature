# Sources:
#   https://github.com/pingdotgg/t3code/pull/26983
#   https://github.com/pingdotgg/t3code/pull/23852
#   https://github.com/pingdotgg/t3code/pull/22634
#   https://github.com/pingdotgg/t3code/pull/22832
#   https://github.com/pingdotgg/t3code/pull/20223
#   https://github.com/pingdotgg/t3code/pull/20394
#   https://github.com/pingdotgg/t3code/pull/17365
#   https://github.com/pingdotgg/t3code/pull/18941
#   https://github.com/pingdotgg/t3code/pull/22937
#   https://github.com/pingdotgg/t3code/pull/22399
#   https://github.com/pingdotgg/t3code/pull/24813
#   docs/user/thread-sidebar.md (Link a pull request, agent-managed metadata)
#   apps/web/src/hooks/usePullRequestLinking.ts
#   apps/web/src/hooks/useSupportsMultiplePullRequests.ts
#   apps/web/src/components/ChatView.tsx (relinking to the branch's new pull request, the panel that follows it)
#   apps/web/src/components/chat/ThreadDetailsPrRow.tsx, ThreadDetailsPrRows.tsx (the next step, merge confirmation, Show N more)
#   packages/contracts/src/orchestrationV2.ts (thread.pull-request.link, thread.pull-request.unlink, thread.pull-request-link.sync, thread.pull-request.sync, thread.pull-request-synced)
#   apps/server-ex/lib/hal_c2/orchestration.ex (pull-request link, unlink, sync)
#   apps/server-ex/lib/hal_c2/pull_requests/discovery.ex

Feature: Linking pull requests to threads
  A thread follows the pull request for its branch on its own. The user or the agent can
  point it at a different pull request, or unlink one.

  Background:
    Given a connected environment with the thread "Cart totals" on the branch "feature/cart"

  @mc
  Scenario: A thread finds the pull request for its branch
    Given a pull request is opened for "feature/cart"
    When the environment looks for pull requests
    Then "Cart totals" is linked to that pull request
    And no client needs to be open for this to happen

  # Upstream #23852: discovery kept spending the host's quota every minute with no one using a client.
  @backlog @mc
  Scenario: Looking for branch pull requests every minute waits for a client in the foreground
    Given no client of the environment is in the foreground
    When a minute passes
    Then the environment does not look for branch pull requests
    But a turn that ends on "Cart totals" still looks for its pull request
    And the every-minute look resumes once a client is in the foreground
  # Upstream #26983: the every-minute look asked the host about every hidden subagent thread,
  # which pinned a core on servers running many agents.
  @backlog @mc
  Scenario: Looking for branch pull requests every minute skips subagent threads
    Given "Cart totals" has three subagent threads, each on a branch of its own
    When the environment looks for branch pull requests at startup or each minute
    Then it asks the host only about "Cart totals"
    But a subagent thread whose turn ends still looks for its own pull request


  # Upstream #22634: a GitCafe pull request linked as "/pull/<n>" was stored apart from "/pulls/<n>".
  @backlog @mc @priority-low
  Scenario Outline: A GitCafe pull request is stored in one form however it was linked
    When the user or the agent links "Cart totals" to <link>
    Then the link is stored as "https://git.cafe/team/shop/pulls/42"

    Examples:
      | link                                  |
      | "https://git.cafe/team/shop/pull/42"  |
      | "https://git.cafe/team/shop/pulls/42" |
      | "team/shop" number 42 on git.cafe     |

  # Upstream #22937: Forgejo, Gitea and GitCafe pull request addresses use /pulls/<n>, which
  # discovery did not read a repository from, so their pull requests were never linked.
  @backlog @mc
  Scenario Outline: A thread finds its branch's pull request on a host that uses /pulls/
    Given the project's remote is on <host>
    And a pull request is opened for "feature/cart" at "<url>"
    When the environment looks for pull requests
    Then "Cart totals" is linked to that pull request

    Examples:
      | host                                   | url                                                       |
      | Codeberg                               | https://codeberg.org/team/shop/pulls/42                   |
      | a Forgejo served from a port and path  | http://code.example:3000/forgejo/team/shop/pulls/42/files |
      | GitCafe                                | https://git.cafe/team/shop/pulls/42                       |

  @mc
  Scenario: Archived threads are not linked to new pull requests
    Given "Cart totals" is archived
    When the environment finds a pull request for "feature/cart"
    Then "Cart totals" is not linked to it

  @mc
  Scenario: Linking a different pull request by hand keeps the branch pull request beside it
    Given "Cart totals" is linked to the pull request for "feature/cart"
    When the user links "Cart totals" to pull request 42
    Then "Cart totals" is linked to pull request 42 and the branch pull request

  @mc
  Scenario: Linking the same pull request twice changes nothing
    Given "Cart totals" is linked to pull request 42
    When the user links "Cart totals" to pull request 42 again
    Then "Cart totals" has one link to pull request 42

  @mc
  Scenario: Unlinking a pull request
    Given "Cart totals" is linked to pull request 42
    When the user unlinks pull request 42 from "Cart totals"
    Then "Cart totals" is no longer linked to pull request 42

  @mc
  Scenario: An unlinked layer of a stack stays unlinked
    Given "Cart totals" is linked to a stack of pull requests
    When the user unlinks one layer of the stack
    And the environment refreshes the stack
    Then that layer is not linked again

  @mc
  Scenario: A user can bring back a stack layer they unlinked
    Given the user unlinked a layer of the stack from "Cart totals"
    When the user links that layer again
    Then "Cart totals" is linked to that layer

  @mc
  Scenario: The agent links the pull request it opened
    Given the agent in "Cart totals" opened pull request 43
    When the agent links pull request 43 to its thread
    Then "Cart totals" is linked to pull request 43

  # Upstream #24813: agents missed linking what they opened, so a create command's printed
  # address links the pull request to the thread that ran it.
  @backlog @mc @priority-high
  Scenario Outline: A pull request the agent opens from the shell is linked on its own
    When the agent in "Cart totals" runs <command> and it prints the new pull request's address on its own line
    Then "Cart totals" is linked to that pull request as one the thread created

    Examples:
      | command          |
      | gh pr create     |
      | glab mr create   |

  @backlog @mc
  Scenario Outline: Addresses other commands print are not linked
    When the agent in "Cart totals" runs <command>
    Then no pull request is linked to "Cart totals"

    Examples:
      | command                                                        |
      | gh pr list --json url                                          |
      | gh pr view 120 && gh pr create, printing the address of 120    |
      | echo "gh pr create" with a pull request address in its output  |

  @backlog @mc
  Scenario: A pull request a delegated subagent opens is linked to the subagent's thread
    Given "Cart totals" delegated a task to a subagent
    When the subagent runs gh pr create and it prints the new pull request's address
    Then the subagent's thread is linked to that pull request

  @desktop @mobile @backlog-mobile
  Scenario: Choosing a different pull request from a pull request link
    Given "Cart totals" shows a link to pull request 41
    When the user links pull request 41 to the thread from that link
    Then "Cart totals" is linked to pull request 41

  @desktop @mobile @backlog-mobile
  Scenario: Unlinking returns the thread to its branch pull request
    Given "Cart totals" was linked by hand to pull request 41
    When the user unlinks pull request 41 from the thread
    Then "Cart totals" shows the pull request for "feature/cart" again

  # Upstream #20394: a pull request is linked to a thread by its address, or by its number in
  # the thread's repository.
  @backlog @desktop @mobile
  Scenario Outline: Linking a pull request to the thread by its address or number
    When the user links "<given>" to "Cart totals"
    Then "Cart totals" is linked to pull request 42 of the thread's repository

    Examples:
      | given                                |
      | https://github.com/acme/shop/pull/42 |
      | 42                                   |
      | #42                                  |

  # Upstream #20394: each linked pull request offers the desktop row menu's actions on the phone too.
  @backlog @desktop @mobile
  Scenario Outline: A linked pull request offers its actions
    Given "Cart totals" is linked to the open pull request 42
    When the user chooses "<action>" for pull request 42 of "Cart totals"
    Then <outcome>

    Examples:
      | action             | outcome                                              |
      | Copy link          | the clipboard holds the address of pull request 42   |
      | Open in browser    | pull request 42 opens in the browser                 |
      | Watch for changes  | pull request 42 is watched for changes               |
      | Unlink from thread | "Cart totals" is no longer linked to pull request 42 |

  # Upstream #20394: the MC refuses a watch on these threads, so it is not offered there.
  @backlog @desktop @mobile
  Scenario Outline: Watching is not offered on a thread that cannot be woken
    Given "Cart totals" is <state> and linked to the open pull request 42
    Then watching pull request 42 for changes is not offered

    Examples:
      | state             |
      | archived          |
      | settled           |
      | a subagent thread |

  # Upstream #20394: the link, unlink and watch actions need the orchestration-operate scope.
  @backlog @desktop @mobile
  Scenario: A session that may not operate the thread cannot change its pull requests
    Given the user's session may read "Cart totals" but not operate it
    Then linking, unlinking and watching pull requests is not offered for "Cart totals"

  @mc
  Scenario: Settled threads keep their links
    Given "Cart totals" is settled and linked to pull request 42
    When a new pull request is opened for "feature/cart"
    Then "Cart totals" stays linked to pull request 42

  # Upstream #17365: pull request links stay while a reconnect changes the thread's details
  @backlog @shared
  Scenario: A linked pull request stays shown through a reconnect
    Given "Cart totals" is linked to pull request 42
    When the client reconnects and the thread's title or status has changed meanwhile
    Then "Cart totals" still shows pull request 42

  # Upstream #22832: a draft marked ready, or ready turned back to draft, changes nothing else
  # about the pull request, and the sidebar kept showing the old status.
  @backlog @mc @shared
  Scenario: The sidebar shows a linked pull request leaving draft
    Given "Cart totals" is linked to pull request 42, a draft
    When pull request 42 is marked ready for review
    Then the sidebar shows pull request 42 as open rather than draft
    And so does a client connected to another machine of the cluster

  @desktop @mobile @backlog-mobile
  Scenario: An environment that cannot find pull requests says it needs an update
    Given the environment does not look for branch pull requests
    When the user looks at "Cart totals"
    Then the user is told to update the server to see branch pull requests

  @backlog @desktop
  Scenario Outline: A thread whose pull request is finished follows the new one opened for its branch
    Given "Cart totals" is linked to pull request 42, which was <ended>
    And pull request 57 is open for "feature/cart" and the folder is on "feature/cart"
    When the user opens "Cart totals"
    Then "Cart totals" becomes linked to pull request 57

    Examples:
      | ended  |
      | merged |
      | closed |

  # Upstream #20223: only a finished pull request the environment found by itself is cleared
  # once the folder is on another branch (mc/orchestration/pull-request-links.feature); one the
  # user linked stays.
  @backlog @desktop @priority-low
  Scenario: A finished pull request the user linked is kept while the folder is on another branch
    Given "Cart totals" was linked by hand to pull request 42, which was merged
    And the folder is on "main", which has an open pull request of its own
    When the user opens "Cart totals"
    Then "Cart totals" stays linked to pull request 42

  @backlog @desktop
  Scenario: A side panel showing the finished pull request moves to the new one
    Given "Cart totals" is linked to the merged pull request 42 and the side panel shows it
    When "Cart totals" follows the new pull request 57 for its branch
    Then the side panel shows pull request 57
    But a side panel showing a different pull request is left on it

  @backlog @desktop @priority-low
  Scenario: A thread that could not be moved to its new pull request says so
    Given "Cart totals" is linked to the merged pull request 42 and pull request 57 is open for its branch
    When the environment refuses to link pull request 57
    Then the user sees an "error" toast "Unable to update the thread pull request" with the reason
    And the link is tried again the next time the thread is opened

  @backlog @desktop
  Scenario Outline: The thread's pull request offers the one step that moves it toward merging
    Given "Cart totals" is linked to pull request 42, which is <state>
    When the user looks at the thread's pull request in its details
    Then <offer>

    Examples:
      | state                                              | offer                                                    |
      | open and in conflict with its base                 | it offers "Resolve", which resolves the conflicts in a new thread |
      | a draft the user may mark ready                    | it offers "Ready", which marks it ready for review       |
      | a draft the user may not mark ready                | it offers no step                                        |
      | open with failing checks                           | it offers "Fix", which fixes the failing checks in a new thread |
      | open with checks still running                     | it offers no step and shows the checks running           |
      | open, clean and passing, and the user may merge it | it offers "Merge"                                        |
      | open and passing on a host with no merge method the user may use | it offers no step                          |
      | merged                                             | it offers no step                                        |

  @backlog @desktop
  Scenario: Merging from the thread's details asks first and names the method
    Given "Cart totals" is linked to pull request 42, which may be merged by squash
    When the user chooses "Merge" for it in the thread's details
    Then the user is asked "Merge pull request?" and told it merges #42 using squash
    And nothing is merged unless the user confirms

  # Upstream #22399: the thread details row always merged with a merge commit, ignoring the
  # project's default and the method last chosen, as the pull request panel already honours.
  @backlog @desktop
  Scenario Outline: Merging from the thread's details uses the method the pull request panel would
    Given the repository of pull request 42 allows merge, squash and rebase
    And <preference>
    When the user chooses "Merge" for it in the thread's details
    Then the user is told it merges #42 using <method>

    Examples:
      | preference                                                              | method |
      | the project's default merge method is "rebase"                          | rebase |
      | the default is "Last selected" and the user last chose squash and merge | squash |
      | the default is "Last selected" and the user has not chosen one yet      | merge  |

  @backlog @desktop @priority-low
  Scenario: A merge that was being confirmed is withdrawn when the pull request stops being mergeable
    Given the user is being asked whether to merge pull request 42 from the thread's details
    When the checks of pull request 42 start running again
    Then the question goes away
    And the user is asked again from the start once the checks pass

  @backlog @desktop
  Scenario: The thread's details show its current pull request and fold the rest away
    Given "Cart totals" is linked to pull requests 42, 43 and 44 and 42 is the one for its branch
    When the user looks at the thread's details
    Then only pull request 42 is listed and the user is offered "Show 2 more"
    When the user chooses "Show 2 more"
    Then pull requests 43 and 44 are listed too and the user is offered "Show less"

  @backlog @desktop
  Scenario: Pointing at the thread's pull request summarises it
    Given "Cart totals" is linked to the open pull request 42 "Fix cart totals" from "feature/cart" into "main"
    When the user rests the pointer on it in the thread's details
    Then the summary names its title, number, state, both branches, its checks and how many files and lines it changes

  # Upstream #18941: long badge lists ran below the window.
  @backlog @desktop @priority-low
  Scenario: A long list of linked pull requests scrolls within the window
    Given a thread is linked to 40 pull requests
    When the user opens the list of its pull requests
    Then the list fits in the window and scrolls
    And the user can open the 40th pull request
