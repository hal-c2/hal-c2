# Sources:
#   apps/server-ex/lib/hal_c2/storage_cleanup.ex (hourly sweep, worktree rules, browser artifacts)
#   apps/web/src/components/settings/StorageSettings.tsx
#   packages/contracts/src/settings.ts (storageCleanup, project worktree cleanup)

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
