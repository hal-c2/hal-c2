# Sources:
#   https://github.com/pingdotgg/t3code/pull/16473
#   https://github.com/pingdotgg/t3code/pull/17910
#   https://github.com/pingdotgg/t3code/pull/17909
#   https://github.com/pingdotgg/t3code/pull/20211
#   https://github.com/pingdotgg/t3code/pull/20368
#   https://github.com/pingdotgg/t3code/pull/15834
#   https://github.com/pingdotgg/t3code/pull/14847
#   https://github.com/pingdotgg/t3code/pull/15150
#   https://github.com/pingdotgg/t3code/pull/15208
#   https://github.com/pingdotgg/t3code/pull/17563
#   https://github.com/pingdotgg/t3code/pull/19748
#   https://github.com/pingdotgg/t3code/pull/19749
#   https://github.com/pingdotgg/t3code/pull/19437
#   https://github.com/pingdotgg/t3code/pull/16231
#   https://github.com/pingdotgg/t3code/pull/22575
#   https://github.com/pingdotgg/t3code/pull/22713
#   apps/server-ex/lib/hal_c2/storage_cleanup.ex (hourly sweep, worktree rules, browser artifacts)
#   apps/server/src/storageCleanup.ts (deletion effects finished, symbolic links, numbered rotations, settings re-read, independent steps)
#   apps/server/src/workspace/workspaceLease.ts (removal and terminal start share one lease per folder)
#   apps/web/src/components/settings/StorageSettings.tsx (project worktree modes, retention limits and default)
#   packages/contracts/src/settings.ts (storageCleanup, project worktree cleanup)
#   apps/tui/src/host/sections/storage.ts

Feature: Storage cleanup
  The MC can remove worktrees and old files it created so disk use does not
  grow forever. Every rule but the one for temporary files is off until the user
  turns it on, and cleanup errs
  on the side of keeping work.

  Background:
    Given an MC with a project "api"

  Rule: The MC removes worktrees only when nothing can be lost

    @mc
    Scenario Outline: A worktree is removed by the rule the user turned on
      Given the user turned on <rule>
      And a thread's worktree <condition>
      When the MC sweeps storage
      Then the worktree is removed
      And the thread keeps its branch so it can be checked out again

      Examples:
        | rule                                | condition                                     |
        | deleting worktrees of deleted threads | belongs to a deleted thread                 |
        | deleting worktrees idle for 8 days  | has been idle for 9 days                      |
        | deleting merged worktrees           | has a merged pull request                     |
        | deleting unchanged worktrees        | has no commits beyond the default branch      |

    @mc
    Scenario: A settled thread's worktree is removed after the chosen days
      Given the user turned on deleting worktrees of threads settled for 2 days
      And a thread was settled 3 days ago and its session has stopped
      When the MC sweeps storage
      Then the worktree is removed
      And the thread keeps its branch and its history
      When the user sends the thread a new message
      Then its worktree is checked out again from the branch

    @mc @priority-high
    Scenario: A worktree is never removed in the minute after its thread settles
      Given the user turned on deleting worktrees of threads settled for 0 days
      When a thread settles and the MC sweeps storage within a minute
      Then the worktree is kept so the project's settle script can run in it
      And the next sweep after that minute removes it

    @backlog @mc
    Scenario: Delete now runs when settled retention is the only rule on
      Given the only cleanup rule on is deleting worktrees of settled threads
      When the user chooses Delete now in Storage settings
      Then the rule runs once

    @mc
    Scenario Outline: A worktree with something to lose is kept
      Given the user turned on deleting worktrees idle for 8 days
      And an idle thread's worktree <condition>
      When the MC sweeps storage
      Then the worktree is kept

      Examples:
        | condition                               |
        | has uncommitted changes                 |
        | has an open terminal                    |
        | is shared with another thread           |
        | is checked out on a different branch    |
        | holds ignored files besides node_modules |

    # Upstream #17563 made what counts as local changes a choice. HAL-C2 keeps "Any local files"
    # as the default on purpose, where upstream's is "Uncommitted changes": ignored files such as
    # ".env" are often secrets that exist nowhere else, so a worktree holding them is kept unless
    # the user chooses otherwise (hal-c2#1144). The row above is that default.
    @mc @shared @backlog-desktop @backlog-mobile @backlog-tui
    Scenario Outline: The user chooses which local changes keep a worktree
      Given the user turned on deleting worktrees idle for 8 days
      And "Keep worktrees with local changes" is set to <choice>
      And an idle thread's worktree has <changes>
      When the MC sweeps storage
      Then the worktree is <outcome>

      Examples:
        | choice                         | changes                                                 | outcome |
        | "Any local files", the default | only an ignored ".env" file                             | kept    |
        | "Any local files", the default | an untracked file                                       | kept    |
        | "Any local files", the default | only "node_modules"                                     | removed |
        | "Uncommitted changes"          | an untracked file                                       | kept    |
        | "Uncommitted changes"          | only an ignored ".env" file                             | removed |
        | "Edited tracked files"         | an edited tracked file                                  | kept    |
        | "Edited tracked files"         | an untracked file                                       | removed |
        | "Edited tracked files"         | only an ignored ".env" file                             | removed |
        | "Edited tracked files"         | a repository with unpushed commits in an ignored folder | kept    |
        | "Uncommitted changes"          | a repository with unpushed commits in an ignored folder | kept    |
        | "One this MC does not know"    | only an ignored ".env" file                             | kept    |

    # hal-c2#1148 review: what the choice counts is looked for once more inside the worktree's
    # lease, right before removal, and "Edited tracked files" cleans untracked files only then,
    # so a change the agent makes meanwhile loses nothing.
    @mc @priority-high
    Scenario Outline: A worktree changed just as it is being removed is kept with every file
      Given the user turned on deleting worktrees idle for 8 days
      And "Keep worktrees with local changes" is set to <choice>
      And an idle thread's worktree has <changes>
      And the agent <change> just as the sweep removes the worktree
      When the MC sweeps storage
      Then the worktree is kept with every file in it

      Examples:
        | choice                         | changes                     | change                      |
        | "Edited tracked files"         | only an ignored ".env" file | edits a tracked file        |
        | "Uncommitted changes"          | only an ignored ".env" file | adds an untracked file      |
        | "Any local files", the default | only "node_modules"         | adds an ignored ".env" file |

    @backlog @mc @shared
    Scenario: Delete now runs the cleanup rules at once and says what happened
      Given the user turned on worktree cleanup rules
      When the user chooses Delete now in Storage settings
      Then the rules run once, never alongside the automatic sweep
      And the last run lists each worktree removed, kept or failed, with removed sizes, why each was kept, and each failure's reason
      And it shows how much space was recovered

    # Upstream #17910: files hardlinked from a shared store were counted as recovered space; only
    # space the removal really frees is counted.
    @backlog @mc @priority-low
    Scenario: Space still held by another link is not counted as recovered
      Given a worktree about to be removed has dependencies hardlinked from a shared package store
      When the rules remove it
      Then the space recovered leaves out the hardlinked files

    # Upstream #22713: pnpm clones or reflinks its store's files into a worktree on the same
    # disk, and those share their space with the store.
    @backlog @mc @priority-low
    Scenario Outline: Dependencies cloned from a package store count only when they are copies
      Given a worktree about to be removed has pnpm dependencies from a store <where>
      When the rules remove it
      Then the space recovered <counts> those dependencies

      Examples:
        | where                     | counts           |
        | on the same disk          | leaves out       |
        | on another disk           | includes         |

    # Upstream #20211: cleanup results name the machine, the checkout, the full folder and the thread.
    @backlog @mc @shared
    Scenario: Each cleanup result says which machine and folder it was
      Given two machines each kept a worktree named "feature-cart"
      When the user chooses Delete now in Storage settings
      Then each result names its machine, its checkout, its full folder and its thread

    @mc @priority-high
    Scenario: A worktree that gets busy while it is being measured is kept
      Given a worktree about to be removed is being measured
      When its thread starts a turn before the measuring ends
      Then the worktree is kept

    @mc
    Scenario: A thread that becomes active during a sweep keeps its worktree
      Given a worktree about to be removed as idle
      When the user sends a message in its thread before removal
      Then the worktree is kept

    # Legacy: apps/server/src/workspace/workspaceLease.ts (withWorkspaceLease), storageCleanup.ts (cleanWorktree), terminal/Manager.ts (open, restart)
    @mc @priority-high
    Scenario Outline: A terminal started in a worktree and the worktree's removal never overlap
      Given a worktree about to be removed as idle
      When a terminal is <action> in that worktree while the sweep is removing it
      Then the sweep and the terminal's start run one after the other
      And the terminal is never started inside a folder that is being deleted

      Examples:
        | action    |
        | opened    |
        | restarted |

    @mc
    Scenario: Cleanup is off by default
      Given a fresh MC
      When the MC sweeps storage
      Then nothing is removed

    @mc
    Scenario: Changing a cleanup rule sweeps right away
      Given an old worktree that no rule covers
      When the user turns on a rule that covers it
      Then the MC sweeps without waiting for the next hour

    @mc
    Scenario: A project can override the worktree cleanup rules
      Given worktree cleanup is off for the environment
      And project "api" turns on deleting merged worktrees
      When the MC sweeps storage
      Then merged worktrees in "api" are removed
      And merged worktrees in other projects are kept

    @mc
    Scenario: Old browser captures are deleted
      Given the user turned on deleting browser captures after 14 days
      And a capture from 20 days ago
      When the MC sweeps storage
      Then the capture is deleted
      And its old link no longer opens

    @mc
    Scenario: Old rotated logs are deleted
      Given the user turned on deleting rotated logs after 30 days
      When the MC sweeps storage
      Then rotated logs older than 30 days are deleted
      And the current logs are kept

    @mc @priority-high
    Scenario: A deleted thread's worktree is kept until its deletion has finished
      Given the user turned on deleting worktrees of deleted threads
      And a thread was deleted and its cleanup steps have not all finished
      When the MC sweeps storage
      Then its worktree is kept
      When the cleanup steps have finished and the MC sweeps storage again
      Then the worktree is removed

    # hal-c2#1148 review: a failed step is kept a week for diagnosis but never runs again.
    @mc
    Scenario: A deleted thread's cleanup step that failed for good does not keep its worktree
      Given the user turned on deleting worktrees of deleted threads
      And a thread was deleted and one of its cleanup steps failed for good
      When the MC sweeps storage
      Then the worktree is removed

    @mc @priority-high
    Scenario Outline: A worktree with work the default branch lacks is kept by the merge and unchanged rules
      Given the user turned on <rule>
      And a thread's worktree has commits the default branch does not have
      And no merged pull request covers them
      When the MC sweeps storage
      Then the worktree is kept

      Examples:
        | rule                         |
        | deleting merged worktrees    |
        | deleting unchanged worktrees |

    @mc @priority-high
    Scenario Outline: A worktree whose pull request was squash merged is removed only at the merged head
      Given the user turned on deleting merged worktrees
      And a thread's worktree on branch "cart" has commits the default branch does not have
      And GitHub says pull request 42 from "cart" was squash merged <detail>
      When the MC sweeps storage
      Then the worktree is <outcome>

      Examples:
        | detail                                                  | outcome |
        | into the default branch at the worktree's current head  | removed |
        | into the default branch, but the worktree has a later commit | kept |
        | into a release branch at the worktree's current head    | kept    |

    @mc
    Scenario: The unchanged rule does not take a squash merge as merged
      Given the user turned on deleting unchanged worktrees only
      And a thread's worktree whose pull request was squash merged at its current head
      When the MC sweeps storage
      Then the worktree is kept
      And its pull request was not read

    # Upstream #17909: with no local record of the remote's default branch, cleanup asks the remote
    # for it once per sweep and never guesses "main" or "master".
    @mc @priority-high
    Scenario Outline: A repository that does not know its remote's default branch asks the remote
      Given the user turned on deleting merged worktrees
      And the repository's remote was added by hand, so the checkout does not record its default branch
      And <remote>
      When the MC sweeps storage
      Then the worktree <outcome>

      Examples:
        | remote                                                                               | outcome    |
        | the remote says its default is "trunk" and the worktree's commits are on "trunk"     | is removed |
        | the remote says its default is "trunk" and the worktree's commits are only on "main" | is kept    |
        | the remote cannot be asked for its default branch                                    | is kept    |

    @mc @priority-high
    Scenario: An untracked file the repository's status settings hide still keeps the worktree
      Given the user turned on deleting worktrees of deleted threads
      And a deleted thread's worktree is set not to show untracked files in its status
      And it holds an untracked file "notes.txt"
      When the MC sweeps storage
      Then the worktree is kept with "notes.txt"

    @mc
    Scenario Outline: An idle thread's worktree is removed however its last turn ended
      Given the user turned on deleting worktrees idle for 8 days
      And a thread whose last turn <ended> has been idle for 9 days with no pending work
      When the MC sweeps storage
      Then the worktree is removed

      Examples:
        | ended            |
        | completed        |
        | was interrupted  |
        | failed           |
        | was cancelled    |
        | was rolled back  |

    @mc @priority-high
    Scenario: Cleanup never follows a symbolic link out of the folder it cleans
      Given the user turned on deleting browser captures after 14 days
      And the captures folder holds a symbolic link to an old file elsewhere
      When the MC sweeps storage
      Then the file the link points to is untouched
      And the link is left in place

    @backlog @mc @priority-low
    Scenario: Only numbered rotations of a log are deleted
      Given the user turned on deleting rotated logs after 30 days
      And a log file of the current name and a numbered rotation of it are both 40 days old
      And a file in the logs folder that is not a log is 40 days old
      When the MC sweeps storage
      Then the numbered rotation is deleted
      And the log of the current name and the other file are kept

    @backlog @mc @priority-low
    Scenario: Turning a retention rule off during a sweep stops its deletions
      Given a sweep of browser captures is under way
      When the user turns off deleting browser captures
      Then the sweep deletes no further captures

    @backlog @mc @priority-low
    Scenario: A failed cleanup step does not stop the others
      Given the user turned on worktree and rotated log cleanup
      And the worktree cleanup fails
      When the MC sweeps storage
      Then rotated logs older than the limit are still deleted
      And the failure is logged

    @mc
    Scenario: A thread and the subagents working in its worktree count as one owner
      Given the user turned on deleting worktrees idle for 8 days
      And a thread and two subagents it delegated to share its worktree on its branch
      And all three have been idle for 9 days with no pending work
      When the MC sweeps storage
      Then the worktree is removed

    # Upstream #16473: cleanup read only active threads, missing archived threads' worktrees.
    @mc
    Scenario: Cleanup rules reach the worktrees of archived threads
      Given the user turned on deleting worktrees idle for 8 days
      And an archived thread's worktree has been idle for 9 days with nothing to lose
      When the MC sweeps storage
      Then the worktree is removed
      But a worktree an archived thread shares with one that could lose work is kept

    @mc @priority-high
    Scenario Outline: A worktree shared with subagents is kept when one of them could lose work
      Given the user turned on deleting worktrees idle for 8 days
      And a thread and a subagent it delegated to share its worktree
      And <condition>
      When the MC sweeps storage
      Then the worktree is kept with the reason "<reason>"

      Examples:
        | condition                                              | reason                                                      |
        | the subagent is on another branch                      | A subagent thread's branch differs from this worktree's branch |
        | the subagent has no branch                             | A subagent thread's branch differs from this worktree's branch |
        | a forked thread also works in the worktree             | Shared by 3 threads                                         |
        | an unrelated thread also works in the worktree         | Shared by 3 threads                                         |

    @mc
    Scenario: The newest work of a thread's subagents keeps their shared worktree
      Given the user turned on deleting worktrees idle for 8 days
      And a thread idle for 9 days shares its worktree with a subagent that worked 2 days ago
      When the MC sweeps storage
      Then the worktree is kept

    @backlog @mc
    Scenario Outline: A folder in the managed worktrees no thread uses is reported and kept
      Given <kind> in the MC's worktrees directory that no thread, deleted or not, uses
      And it was last changed more than an hour ago
      When the MC sweeps storage
      Then the report lists it as kept with its full path and its size
      And its reason reads "<reason>"
      And its files stay on disk
      And its size does not count toward the bytes recovered

      Examples:
        | kind                  | reason                                                      |
        | a linked git worktree | No thread uses this worktree                                |
        | a plain folder        | No thread uses this folder, and it isn't a git worktree     |

    @backlog @mc
    Scenario Outline: A folder in the managed worktrees is not reported as unused
      Given a folder in the MC's worktrees directory that <situation>
      When the MC sweeps storage
      Then it is not reported as unused

      Examples:
        | situation                                         |
        | an archived, deleted or subagent thread uses      |
        | holds a folder a thread uses                      |
        | is the root of a project, deleted or not          |
        | is a symbolic link                                |
        | was changed within the last hour                  |
        | cannot be read                                    |

    @backlog @mc
    Scenario: Unused worktree folders are listed ahead of the threads' results
      Given 300 threads' worktrees were kept and 2 unused folders were found
      When the MC sweeps storage
      Then the 200-entry report lists failed and removed entries first, then the unused folders, then the other kept entries

    @backlog @mc @priority-low
    Scenario: Measuring unused folders has a time budget per sweep
      Given unused folders too large to measure in 30 seconds
      When the MC sweeps storage
      Then the folders it did not finish measuring are reported with an unknown size
      And they are measured again on the next sweep
      And a folder already measured is not walked again while it stays unused

    # Upstream #20368: worktrees with initialized submodules are removed when nothing in them would be lost.
    @mc
    Scenario: A worktree with initialized submodules is removed when nothing would be lost
      Given the user turned on deleting worktrees idle for 8 days
      And an idle thread's worktree has initialized submodules with nothing to lose
      When the MC sweeps storage
      Then the worktree is removed

    # Upstream #20368: a submodule commit that is not pushed anywhere still keeps the worktree.
    @mc @priority-high
    Scenario: A worktree whose submodule has unpublished work is kept
      Given the user turned on deleting worktrees idle for 8 days
      And an idle thread's worktree has a submodule with a commit not pushed anywhere
      When the MC sweeps storage
      Then the worktree is kept

  Rule: Storage settings

    @shared @backlog-mobile @priority-low
    Scenario: Settings for several machines show mixed values
      Given "laptop" deletes inactive worktrees and "server" does not
      When the user views storage settings for both machines
      Then that rule shows as mixed

    @shared @backlog-mobile @priority-low
    Scenario: The rule for idle threads' temporary files reads seven days until changed
      When the user opens storage settings
      Then deleting idle threads' temporary files reads 7 days

    @shared @backlog-mobile @priority-low
    Scenario: The user chooses the folder for temporary files
      When the user opens storage settings
      And the user sets the temporary files folder to "/mnt/scratch"
      Then the machine's temporary files folder is "/mnt/scratch"

    @shared @backlog-mobile @priority-low
    Scenario: Blanking the temporary files folder goes back to the default
      Given the machine's temporary files folder is set to "/mnt/scratch"
      When the user opens storage settings
      And the user sets the temporary files folder to ""
      Then the machine's temporary files folder is ""

    @shared @backlog-mobile @priority-low
    Scenario: A machine too old for storage cleanup asks to be updated
      Given the selected machine does not support storage cleanup
      When the user opens storage settings
      Then the user is asked to update that machine first

    @mc @shared @backlog @priority-low
    Scenario: A store with much space to reclaim suggests the doctor command
      Given the machine's store cannot give space back while running
      And it has 2.7 GiB it could reclaim
      When the user opens storage settings
      Then a notice offers to reclaim 2.7 GiB
      And the user can copy the doctor command that targets that machine's data
      And the user can dismiss the notice

    # Upstream #22575: with several machines connected the notice is one section, explained
    # once, with a row per machine.
    @shared @backlog @priority-low
    Scenario: Several machines with space to reclaim share one notice
      Given "Office Mac" could reclaim 1.1 GiB and "Studio" 2.4 GiB
      When the user opens storage settings
      Then one notice explains reclaiming space once
      And it lists "Studio" with 2.4 GiB before "Office Mac" with 1.1 GiB
      And each machine's row copies the doctor command for that machine

    # Upstream #22575: dismissing one machine's row hides only that row, and it stays hidden.
    @desktop @backlog @priority-low
    Scenario: Dismissing one machine's reclaim row keeps the others
      Given the reclaim notice lists "Studio" and "Office Mac"
      When the user dismisses the row for "Office Mac"
      Then only "Studio" is listed
      And "Office Mac" stays hidden after HAL-C2 restarts

    @mc @shared @backlog @priority-low
    Scenario Outline: The reclaim notice is not shown
      Given <situation>
      When the user opens storage settings
      Then no reclaim notice is shown

      Examples:
        | situation                                                  |
        | the machine's store has less than 1 GiB it could reclaim   |
        | the machine's store already gives space back while running |
        | the MC runs from a dev checkout with its own dev store     |
        | the user dismissed the notice                              |

    @mc @backlog @priority-low
    Scenario: The store's size is published again only when it changed
      Given a client follows the store's size
      When the log is compacted and nothing it reports changed
      Then the client is sent nothing

    @backlog @desktop @priority-low
    Scenario: A machine too old for project worktree cleanup asks to be updated
      Given the selected machine supports storage cleanup but not per-project worktree cleanup
      When the user opens storage settings for project "api"
      Then the user is told to update the selected machines to configure project worktree cleanup

    @backlog @desktop
    Scenario Outline: A project chooses how its worktrees are cleaned up
      When the user sets automatic worktree cleanup for project "api" to <choice>
      Then <result>

      Examples:
        | choice  | result                                                                           |
        | Inherit | the project follows each machine's cleanup settings and its own rules are removed |
        | Off     | the project's worktrees are kept until the user deletes them                      |
        | Custom  | the project gets its own rules, starting with none turned on                      |

    @backlog @desktop
    Scenario: A project's own rules are shown only when it uses custom rules
      Given project "api" inherits worktree cleanup
      When the user opens storage settings for project "api"
      Then the four worktree rules are not shown
      And choosing custom rules shows them

    @backlog @desktop @priority-low
    Scenario: Several projects with different cleanup modes show as mixed
      Given project "api" uses custom rules and project "web" inherits
      When the user views storage settings for both projects
      Then automatic worktree cleanup shows as mixed
      And the project rules are not shown until one mode is chosen

    @backlog @desktop @priority-low
    Scenario: A project has no artifact or log retention
      When the user opens storage settings for project "api"
      Then only the worktree rules are shown
      And browser artifact and rotated log retention are left to the machine

    @backlog @desktop @priority-low
    Scenario: A retention rule is turned on at eight days
      Given deleting old browser artifacts is off
      When the user turns it on
      Then it deletes artifacts older than 8 days
      And the same default applies to inactive worktrees and rotated logs

    @backlog @desktop @priority-low
    Scenario Outline: A retention period is kept between one day and ten years
      Given deleting old rotated logs is on
      When the user sets the period to <typed>
      Then the period becomes <kept> days

      Examples:
        | typed    | kept |
        | 0        | 1    |
        | 12       | 12   |
        | 5000     | 3650 |

    @backlog @desktop @priority-low
    Scenario: Clearing a retention period keeps the previous one
      Given deleting old rotated logs is on at 30 days
      When the user clears the period and leaves the field
      Then it is still 30 days

    @backlog @desktop
    Scenario: Turning a retention rule off keeps files
      Given deleting old rotated logs is on at 30 days
      When the user turns it off
      Then the rule shows as off
      And no rotated log is deleted by age

  @backlog @shared @priority-low
  Scenario: Worktree location is a per-machine setting
    When the user opens the storage settings
    Then the worktree location is at the top of the worktrees section, empty for the default
    And it is hidden at project scope
