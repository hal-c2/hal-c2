# Sources:
#   apps/server-ex/lib/hal_c2/storage_cleanup.ex (hourly sweep, worktree rules, browser artifacts)
#   apps/server/src/storageCleanup.ts (deletion effects finished, symbolic links, numbered rotations, settings re-read, independent steps)
#   apps/server/src/workspace/workspaceLease.ts (removal and terminal start share one lease per folder)
#   apps/web/src/components/settings/StorageSettings.tsx (project worktree modes, retention limits and default)
#   packages/contracts/src/settings.ts (storageCleanup, project worktree cleanup)
#   apps/tui/src/host/sections/storage.ts

Feature: Storage cleanup
  The MC can remove worktrees and old files it created so disk use does not
  grow forever. Every rule is off until the user turns it on, and cleanup errs
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

    @mc
    Scenario: A thread that becomes active during a sweep keeps its worktree
      Given a worktree about to be removed as idle
      When the user sends a message in its thread before removal
      Then the worktree is kept

    # Legacy: apps/server/src/workspace/workspaceLease.ts (withWorkspaceLease), storageCleanup.ts (cleanWorktree), terminal/Manager.ts (open, restart)
    @mc @backlog
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

    @backlog @mc
    Scenario: A deleted thread's worktree is kept until its deletion has finished
      Given the user turned on deleting worktrees of deleted threads
      And a thread was deleted and its cleanup steps have not all finished
      When the MC sweeps storage
      Then its worktree is kept
      When the cleanup steps have finished and the MC sweeps storage again
      Then the worktree is removed

    @backlog @mc
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

    @backlog @mc
    Scenario: Cleanup never follows a symbolic link out of the folder it cleans
      Given the user turned on deleting browser captures after 14 days
      And the captures folder holds a symbolic link to an old file elsewhere
      When the MC sweeps storage
      Then the file the link points to is untouched
      And the link is left in place

    @backlog @mc
    Scenario: Only numbered rotations of a log are deleted
      Given the user turned on deleting rotated logs after 30 days
      And a log file of the current name and a numbered rotation of it are both 40 days old
      And a file in the logs folder that is not a log is 40 days old
      When the MC sweeps storage
      Then the numbered rotation is deleted
      And the log of the current name and the other file are kept

    @backlog @mc
    Scenario: Turning a retention rule off during a sweep stops its deletions
      Given a sweep of browser captures is under way
      When the user turns off deleting browser captures
      Then the sweep deletes no further captures

    @backlog @mc
    Scenario: A failed cleanup step does not stop the others
      Given the user turned on worktree and rotated log cleanup
      And the worktree cleanup fails
      When the MC sweeps storage
      Then rotated logs older than the limit are still deleted
      And the failure is logged

  Rule: Storage settings

    @shared @backlog-mobile
    Scenario: Settings for several machines show mixed values
      Given "laptop" deletes inactive worktrees and "server" does not
      When the user views storage settings for both machines
      Then that rule shows as mixed

    @shared @backlog-mobile
    Scenario: A machine too old for storage cleanup asks to be updated
      Given the selected machine does not support storage cleanup
      When the user opens storage settings
      Then the user is asked to update that machine first

    @backlog @desktop
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

    @backlog @desktop
    Scenario: Several projects with different cleanup modes show as mixed
      Given project "api" uses custom rules and project "web" inherits
      When the user views storage settings for both projects
      Then automatic worktree cleanup shows as mixed
      And the project rules are not shown until one mode is chosen

    @backlog @desktop
    Scenario: A project has no artifact or log retention
      When the user opens storage settings for project "api"
      Then only the worktree rules are shown
      And browser artifact and rotated log retention are left to the machine

    @backlog @desktop
    Scenario: A retention rule is turned on at eight days
      Given deleting old browser artifacts is off
      When the user turns it on
      Then it deletes artifacts older than 8 days
      And the same default applies to inactive worktrees and rotated logs

    @backlog @desktop
    Scenario Outline: A retention period is kept between one day and ten years
      Given deleting old rotated logs is on
      When the user sets the period to <typed>
      Then the period becomes <kept> days

      Examples:
        | typed    | kept |
        | 0        | 1    |
        | 12       | 12   |
        | 5000     | 3650 |

    @backlog @desktop
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
