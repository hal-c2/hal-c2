# Sources:
#   docs/user/source-control.md
#   packages/contracts/src/vcs.ts (VcsStatusLocalResult, VcsStatusRemoteResult, VcsStatusStreamEvent, VcsDriverKind)
#   packages/contracts/src/rpc.ts (vcs.refreshStatus, subscribeVcsStatus, vcs.init)
#   apps/server-ex/lib/hal_c2/vcs.ex (status, init)
#   apps/server-ex/lib/hal_c2/vcs/watch.ex
#   apps/server/src/git/GitManager.ts, apps/server/src/vcs/VcsStatusBroadcaster.ts (pull request lookup cadence, shared polling, automatic pull)
#   apps/server/src/vcs/VcsProjectConfig.ts, VcsDriverRegistry.ts, VcsProcess.ts (project vcs.json, detection, concurrency)
#   apps/server/src/vcs/GitVcsDriverCore.ts (index lock, unborn HEAD, upstream refresh back-off)
#   apps/server/src/orchestration-v2/RunFinalizationService.ts (which turn ends check the pull request)
#   apps/server-ex/lib/hal_c2/source_control/change_requests.ex (GitLab, Forgejo, Azure DevOps, Bitbucket)
#   apps/server-ex/lib/hal_c2/background_policy.ex (automaticGitFetchInterval)
#   apps/web/src/components/GitActionsControl.tsx (Initialize Git)
#   apps/desktop-qt/qml/HalC2/Bricks/GitActions.qml (Initialize Git, git pill)
#   apps/tui/src/gitActions.logic.ts (mergeVcsStatus, resolveGitQuickAction)
#   apps/tui/src/connection.ts (subscribeVcsStatus)

Feature: Repository status and working tree changes
  The checkout behind a thread reports its branch, its uncommitted changes and how it stands
  against its upstream, and keeps that picture current while someone is looking at it.

  Background:
    Given a connected environment with the project "shop" in a git repository

  @mc
  Scenario: Status reports the branch and the uncommitted files
    Given the user has changed "src/cart.ts" and added "src/tax.ts" on the branch "feature/tax"
    When status is read for "shop"
    Then the status names the branch "feature/tax"
    And it lists both files with their inserted and deleted line counts
    And it says the working tree has changes

  @mc
  Scenario: Status reports how the branch stands against its upstream
    Given "feature/tax" tracks "origin/feature/tax" and is 2 commits ahead and 1 behind
    When status is read for "shop"
    Then the status says the branch has an upstream
    And it reports 2 commits ahead and 1 behind

  # Delivered natively (WorkspaceController follows the checkout's vcs status); no desktop test yet.
  @mc @desktop @tui
  Scenario: Status follows the checkout while the thread is open
    Given the user is looking at a thread in "shop"
    When the agent's turn ends after editing a file
    Then the thread's status shows the new change without the user asking for a refresh

  @mc
  Scenario: Status refreshes after a git action finishes
    Given the user is looking at a thread in "shop" with uncommitted changes
    When the user commits the changes
    Then the thread's status reports a clean working tree

  @mc
  Scenario: The remote side is fetched on the automatic fetch interval
    Given the automatic Git fetch interval is 30 seconds
    And a client in front is showing a thread in "shop"
    When 30 seconds pass
    Then the MC fetches from the remote and the ahead and behind counts are updated

  @mc
  Scenario: A fetch interval of zero never fetches on its own
    Given the automatic Git fetch interval is 0 seconds
    When a client shows a thread in "shop" for several minutes
    Then the MC never fetches from the remote without being asked

  @mc
  Scenario: Nobody watching means no background fetches
    Given no client is showing a thread in "shop"
    When the fetch interval elapses
    Then the MC does not fetch "shop" from the remote

  @mc
  Scenario: Status names the open pull request for a GitHub branch
    Given "feature/tax" has an open draft pull request on GitHub
    When status is read for "shop"
    Then the status carries that pull request with its state open and marked as a draft

  @mc
  Scenario: On the default branch only an open pull request counts
    Given "main" once had a merged pull request from the same branch name
    When status is read on "main"
    Then the status carries no pull request

  @mc
  Scenario Outline: Status names the open change request on other hosts
    Given "shop" has its primary remote on <host>
    And the current branch has an open change request there
    When status is read for "shop"
    Then the status carries that change request

    Examples:
      | host         |
      | GitLab       |
      | Forgejo      |
      | Azure DevOps |
      | Bitbucket    |

  @mc
  Scenario: A folder that is not a repository says so
    Given the project "notes" is not in a git repository
    When status is read for "notes"
    Then the status says it is not a repository

  # Legacy: apps/server/src/git/GitManager.test.ts (status returns an explicit non-repo result for deleted directories)
  @mc @backlog
  Scenario: A folder that has been deleted says it is not a repository
    Given the folder of the project "notes" was deleted
    When status is read for "notes"
    Then the status says it is not a repository
    And no failure is reported

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (statusDetails: unborn HEAD)
  @mc @backlog
  Scenario: A repository with no commits yet still reports its branch and changes
    Given the project "notes" is a git repository with no commits
    And "notes" holds a staged "a.txt" and an untracked "b.txt"
    When status is read for "notes"
    Then the status names the branch the first commit will go on
    And "a.txt" and "b.txt" are listed with their changed line counts

  # Legacy: apps/server/src/vcs/GitVcsDriverCore.ts (readStatusDetailsLocal: index lock)
  @mc @backlog
  Scenario: A checkout whose git index is locked reports that instead of a status
    Given another git process is holding the index lock of "shop"
    When status is read for "shop"
    Then the status read fails with "Git index is locked. Status will resume when the index lock is removed."
    And the next status read after the lock is gone reports the checkout normally

  # Delivered natively (GitController, vcs.init); source-control/git-actions.feature runs it in its own words, not these steps.
  @mc @desktop
  Scenario: Initializing a repository in a plain folder
    Given the project "notes" is not in a git repository
    When the user initializes Git for "notes"
    Then "notes" becomes a git repository
    And the git actions for "notes" become available

  @tui
  Scenario: Initializing a repository from the terminal client
    Given the project "notes" is not in a git repository
    When the user initializes Git for "notes" from the terminal client
    Then "notes" becomes a git repository

  # Legacy: apps/server/src/git/GitManager.ts (lookupStatusPr, resolveLastKnownPr)
  @mc @backlog
  Scenario: A pull request already shown stays when the host cannot be reached
    Given status showed an open pull request for "feature/tax"
    And the host now refuses or cannot be reached
    When status is read for "shop" again
    Then the status still carries that pull request

  # Legacy: apps/server/src/git/GitManager.ts (resolveLastKnownPr: remote identity)
  @mc @backlog
  Scenario: A branch moved to another remote does not keep the old pull request
    Given status showed an open pull request for "feature/tax" on the remote "origin"
    And the host now cannot be reached
    When the branch's remote is changed to a different repository and status is read again
    Then the status carries no pull request

  # Legacy: apps/server/src/git/GitManager.ts (prLookupFailureTtl)
  @mc @backlog
  Scenario: A host that keeps refusing the pull request lookup is asked less and less often
    Given the host refuses the pull request lookup for "feature/tax" every time
    When status is read for "shop" repeatedly
    Then the lookup is retried after 20 seconds, then 40 seconds, doubling up to 15 minutes
    And the first answer that succeeds brings back the normal rhythm

  # Legacy: apps/server/src/git/GitManager.ts (PR_LOOKUP_CACHE_TTL, PR_LOOKUP_NO_OPEN_PR_CACHE_TTL)
  @mc @backlog
  Scenario Outline: How soon status asks the host about a branch's pull request again depends on what it found
    Given the host's last answer for "feature/tax" was <answer>
    When status is read for "shop" over the next minutes
    Then the host is asked again after about <wait>

    Examples:
      | answer                   | wait       |
      | an open pull request     | 1 minute   |
      | a merged pull request    | 5 minutes  |
      | no pull request at all   | 5 minutes  |

  # Legacy: apps/server/src/git/GitManager.ts (isUnpublishedBranch)
  @mc @backlog
  Scenario: A branch that was never pushed makes no call to the host
    Given "feature/new" exists only on this machine and has no upstream
    When status is read for "shop" on "feature/new"
    Then the status carries no pull request
    And the host is not asked about the branch

  # Legacy: apps/server/src/git/GitManager.ts (resolveLookupHeadContext)
  @mc @backlog
  Scenario: A branch cut from the default branch is not given the default branch's pull requests
    Given "feature/tax" was cut from "origin/main" and still tracks it
    And an old pull request once merged "main" into another branch
    When status is read for "shop" on "feature/tax"
    Then the status carries no pull request
    And the thread is not settled because of that old pull request

  # Legacy: apps/server/src/git/GitManager.ts (resolveLookupHeadContext, findRemoteTrackingRemote)
  @mc @backlog
  Scenario Outline: A branch cut from the default branch and pushed under its own name is looked up by that name
    Given "feature/tax" was cut from "origin/main" and still tracks it
    And the remotes <remotes> hold a branch "feature/tax"
    And a pull request is open on the host for "feature/tax"
    When status is read for "shop" on "feature/tax"
    Then the status carries that pull request, found through "<remote>"

    Examples:
      | remotes              | remote |
      | "origin"             | origin |
      | "origin" and "fork"  | origin |
      | "fork"               | fork   |

  # Legacy: apps/server/src/git/GitManager.ts (matchesBranchHeadContext, GITHUB_HEAD_BRANCH_PROBE_LIMIT)
  @mc @backlog
  Scenario: Another fork's branch of the same name is not taken as the branch's pull request
    Given "patch-1" is pushed to "origin" in the user's repository
    And an open pull request on the host comes from a "patch-1" branch of someone else's fork
    When status is read for "shop" on "patch-1"
    Then the status carries no pull request

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (refreshPullRequestStatus), GitManager.ts (refreshMissingPullRequest)
  @mc @backlog
  Scenario: A pull request opened outside HAL-C2 shows up when the next turn ends
    Given a client in front is showing a thread in "shop"
    And the status has no pull request for "feature/tax"
    And someone opened a pull request for it on the host
    When the thread's turn ends
    Then the status carries that pull request without waiting for the slower recheck

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (refreshPullRequestStatus: background policy)
  @mc @backlog
  Scenario: The turn-end pull request check respects the background settings
    Given background work is paused for "shop" by the user's background activity settings
    When a thread's turn ends in "shop"
    Then the host is not asked about the pull request

  # Legacy: apps/server/src/orchestration-v2/RunFinalizationService.ts (observerLive refresh)
  @mc @backlog
  Scenario Outline: The turn-end pull request check runs only for the thread's own branch
    Given a thread in "shop" works on "feature/tax"
    And <situation>
    When the thread's turn ends
    Then the working tree changes are refreshed
    But the host is not asked about the pull request

    Examples:
      | situation                                                 |
      | the checkout is on the default branch                     |
      | the checkout is on a branch other than the thread's       |
      | the checkout has no branch checked out                    |
      | a newer turn of the thread is already running             |

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (refreshPullRequestStatus: resolves the checked-out branch again)
  @mc @backlog
  Scenario: A pull request found for one branch is not shown after the agent checks out another
    Given the status of "shop" carries the pull request of "feature/tax"
    And the agent checks out "feature/other", which has no pull request, during its turn
    When the thread's turn ends
    Then the status carries no pull request

  # Legacy: apps/server/src/git/GitManager.ts (invalidateStatus bumps the lookup epoch)
  @mc @backlog
  Scenario Outline: What the user does asks the host again at once
    Given status showed no pull request for "feature/tax" a moment ago
    When <action>
    Then the next status asks the host about the branch again

    Examples:
      | action                                |
      | the user refreshes the status         |
      | the user pushes the branch            |
      | the user creates the pull request     |

  # Legacy: apps/server/src/git/GitManager.ts (STATUS_RESULT_CACHE_TTL)
  @mc @backlog
  Scenario: Many clients asking for status in the same second cause one read
    Given five clients ask for the status of "shop" within one second
    Then git is asked once for the checkout's status
    And all five get the same answer

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (fingerprints)
  @mc @backlog
  Scenario: A refresh that finds nothing new sends nothing to watchers
    Given a client is watching the status of "shop"
    When the status is refreshed and nothing about the checkout changed
    Then the client receives no update

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (poller per cwd)
  @mc @backlog
  Scenario: Clients watching one checkout share a single background fetch
    Given two clients are watching the status of "shop"
    When the fetch interval elapses
    Then the MC fetches "shop" once
    And both clients receive the result

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (remoteRefreshFailureDelay)
  @mc @backlog
  Scenario: A remote that fails to fetch is retried less and less often
    Given the automatic Git fetch interval is 30 seconds
    And the remote of "shop" cannot be reached
    When a client in front keeps showing a thread in "shop"
    Then the fetch is retried after 30 seconds, then 60 seconds, doubling up to 15 minutes
    And a longer configured interval is never shortened
    And the first fetch that succeeds returns to the configured interval

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (remoteWriteLocks)
  @mc @backlog
  Scenario: A slow background check cannot hide a pull request created while it ran
    Given a background status check for "shop" started before the pull request was created
    When the pull request is created and the slow check then finishes
    Then the status still carries the new pull request

  # Legacy: apps/server/src/vcs/VcsStatusBroadcaster.ts (maybeAutoPull)
  @mc @backlog
  Scenario Outline: A watched checkout that falls behind is pulled when it is safe to
    Given "shop" has automatic pull on
    And "shop" <state>
    When the fetch finds the upstream has new commits
    Then "shop" <result>

    Examples:
      | state                                           | result                       |
      | is a clean checkout of its default branch       | is fast-forwarded            |
      | is a clean checkout of its default branch with commits the upstream lacks | is not pulled |
      | has uncommitted changes                         | is not pulled                |
      | is on a branch other than its default           | is not pulled                |

  # Legacy: apps/server/src/vcs/VcsProjectConfig.ts
  @mc @backlog
  Scenario Outline: A project can say which version control system it uses
    Given the project folder or a folder above it holds "<file>" naming the system "jj"
    When status is read for "shop"
    Then the status is read with the Jujutsu driver

    Examples:
      | file                |
      | .hal-c2/vcs.json    |
      | .t3/vcs.json        |

  # Legacy: apps/server/src/vcs/VcsProjectConfig.ts (a bad file falls back to automatic detection)
  @mc @backlog
  Scenario: A version control file that cannot be read is ignored
    Given the project holds ".hal-c2/vcs.json" that is not valid JSON
    When status is read for "shop"
    Then the system is detected automatically and the status is read

  # Legacy: apps/server/src/vcs/VcsProjectConfig.ts (findConfigPath, configuredKind)
  @mc @backlog
  Scenario Outline: Which version control file the project's choice comes from
    Given <files>
    When status is read for "shop"
    Then the status is read with the <driver> driver

    Examples:
      | files                                                                                    | driver   |
      | ".hal-c2/vcs.json" names "jj" and ".t3/vcs.json" names "git"                              | Jujutsu  |
      | the file names the system as "vcsKind": "jj" at its top level                            | Jujutsu  |
      | the file names the system as "vcs": { "kind": "jj" } and also as "vcsKind": "git"        | Jujutsu  |
      | the file holds comments and trailing commas around "vcs": { "kind": "jj" }               | Jujutsu  |
      | a folder above "shop" names "jj" and "shop" itself holds no file                         | Jujutsu  |

  # Legacy: apps/server/src/vcs/VcsDriverRegistry.ts (resolve), VcsProvisioningService.ts (resolveRequestedKind)
  @mc @backlog
  Scenario Outline: A version control system the MC cannot use is named when it is asked for
    Given <situation>
    When <request>
    Then the request fails with "<message>"

    Examples:
      | situation                                             | request                                  | message                                                 |
      | "shop" is not in any repository                       | a repository action is asked for "shop"  | No supported VCS repository was detected at the folder. |
      | "shop" is a git repository and the project asks for "jj" | a repository action is asked for "shop" | No jj repository was detected at the folder.            |
      | the MC has no driver for "jj"                         | the user initializes "jj" for "notes"    | No jj VCS driver is registered.                         |
      | the system to initialize is left unknown              | the user initializes "notes"             | A concrete VCS driver kind is required for repository provisioning. |

  # Legacy: apps/server/src/vcs/VcsProvisioningService.ts (resolveRequestedKind)
  @mc @backlog
  Scenario: Initializing without naming a system creates a git repository
    Given the project "notes" is not in a git repository
    When the user initializes "notes" without naming a version control system
    Then "notes" becomes a git repository

  # Legacy: apps/server/src/vcs/VcsDriverRegistry.ts (null detections are not cached)
  @mc @backlog
  Scenario: A folder that has just become a repository is noticed at once
    Given status was just read for "notes" and said it is not a repository
    When "notes" is initialized as a git repository
    Then the next status for "notes" reports the repository

  # Legacy: apps/server/src/vcs/VcsProcess.ts (VCS_PROCESS_CONCURRENCY, GITHUB_PROCESS_CONCURRENCY)
  @mc @backlog
  Scenario: Source control commands wait their turn instead of flooding the machine
    Given many threads ask for git work at the same moment
    Then no more than 8 version control commands run at once
    And no more than 4 GitHub CLI commands run at once

  # Legacy: apps/server/src/vcs/VcsProcess.ts (isTransientGitExit, CHECKPOINT_CAPTURE_OPERATION)
  @mc @backlog
  Scenario: A checkpoint is not lost to a brief git lock
    Given git reports a lock file or a vanished file while a checkpoint is being captured
    When the capture command is retried
    Then the checkpoint is captured if the second or third attempt succeeds

  @backlog @mc
  Scenario: A Jujutsu checkout reports its status
    Given the project "shop" is a Jujutsu repository
    When status is read for "shop"
    Then the status reports the Jujutsu driver with its bookmark and working copy changes
