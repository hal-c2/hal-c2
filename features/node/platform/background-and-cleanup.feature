# Sources:
#   apps/server-ex/lib/t3/background_policy.ex (presets, leases, run_scope_work?)
#   apps/server-ex/lib/t3/vcs/watch.ex (automatic git fetch and status under the policy)
#   apps/server-ex/lib/t3/provider_usage_limits.ex, usage_limit_sources.ex (provider health refresh)
#   apps/server-ex/lib/t3/storage_cleanup.ex (worktree and browser artifact sweeps)
#   apps/server-ex/lib/t3/web/socket.ex (server.reportClientActivity lease per socket)
#   packages/contracts/src/server.ts (server.reportClientActivity, server.reportHostPowerState,
#     server.getBackgroundPolicy, subscribeBackgroundPolicy)
#   packages/contracts/src/settings.ts (backgroundActivity, storageCleanup)
#   apps/web/src/components/settings/SettingsPanels.tsx (background activity, storage cleanup)
#   docs/internals/resource-telemetry.md (host power feed)

Feature: Background work and storage cleanup on the node
  The node only does periodic work that a client in front is looking at, and within the
  user's power settings. It sweeps away worktrees and artifacts the user said may go.

  Background:
    Given a running node

  @node
  Scenario Outline: Background activity presets
    Given the background activity profile is "<profile>"
    Then git fetches run every <fetch>
    And provider health refreshes every <health>
    And background work pauses when <pauses>

    Examples:
      | profile       | fetch      | health     | pauses                                                          |
      | performance   | 15 seconds | 1 minute   | the host is locked                                              |
      | balanced      | 30 seconds | 5 minutes  | the host is locked or low on power, or the client is low power  |
      | battery-saver | never      | 15 minutes | locked, low power on either side, or on battery                 |

  @node
  Scenario: A custom profile overrides one preset value
    Given a custom background profile based on "balanced" with git fetch every minute
    Then git fetches run every minute
    And the other values come from "balanced"

  @node
  Scenario: A client in front keeps a checkout's status fresh
    Given a client in front reports it shows a checkout's status
    Then the node refreshes that checkout's git status periodically

  @node
  Scenario: Nobody looking means no background work
    Given no client reports it shows a checkout
    Then the node does not poll that checkout's git status

  @node
  Scenario: A client lease expires unless renewed
    Given a client reported activity with the default lease 46 seconds ago and did not renew it
    Then the node treats that client as gone for background work

  @node
  Scenario: A lease cannot be longer than two minutes
    When a client reports activity with a ten-minute lease
    Then the node holds the lease for two minutes at most

  @node
  Scenario: One connection holds at most sixteen leases
    When one connection reports activity for twenty different client views
    Then the node holds at most sixteen leases for it

  @node
  Scenario: A client's leases end with its socket
    Given a client holds activity leases
    When its socket closes
    Then its leases end at once

  @node
  Scenario: The performance profile works for clients in the background too
    Given the background activity profile is "performance"
    And a client in the background shows a checkout
    Then the node still refreshes that checkout

  @node
  Scenario: A locked host pauses background work
    Given the host reports it is locked
    Then the node pauses periodic git and provider refreshes

  @node
  Scenario: A client reads the policy the node applies
    When a client asks for the background policy
    # BackgroundPolicySnapshot (TS and node) carries no profile or pause reason.
    Then it receives the host's power state, the active client leases and whether background work may run

  @node
  Scenario: A client following the background policy sees it change
    Given a client follows the background policy
    When the host goes onto battery
    Then the client receives the new policy

  @node
  Scenario: A node without a desktop host learns host power from the operating system
    Given a node started without the desktop app
    When the laptop it runs on switches to battery
    Then the node's background policy sees the host on battery

  @node
  Scenario: The first cleanup sweep runs a minute after start and then hourly
    When the node starts
    Then it sweeps storage after about a minute
    And again every hour

  @node
  Scenario: Changing the cleanup settings sweeps again
    When the user changes the storage cleanup settings
    Then the node sweeps with the new settings

  @node
  Scenario Outline: A thread's worktree is removed by the rule the user chose
    Given worktree cleanup removes worktrees <rule>
    And a thread's worktree <condition>
    When the node sweeps storage
    Then the worktree is removed
    And the thread keeps its branch and path

    Examples:
      | rule                             | condition                                  |
      | after 7 idle days                | has been idle for 8 days                   |
      | once merged                      | belongs to a merged pull request           |
      | once their thread is deleted     | belongs to a deleted thread                |
      | when unchanged from default      | has a branch already in the default branch |

  @node
  Scenario Outline: A worktree the sweep must not touch
    Given worktree cleanup removes worktrees after 7 idle days
    And a thread's worktree idle for 8 days <reason>
    When the node sweeps storage
    Then the worktree is kept

    Examples:
      | reason                                 |
      | is used by two threads                 |
      | has uncommitted changes                |
      | has ignored files other than node_modules |
      | has a terminal open in it              |
      | has a running provider session         |
      | belongs to a thread that is running    |
      | is another project's root              |

  @node
  Scenario: A project can turn worktree cleanup off
    Given worktree cleanup is on for the environment
    And one project overrides it to off
    When the node sweeps storage
    Then that project's worktrees are kept

  @node
  Scenario: The sweep checks everything again just before removal
    Given a worktree qualified for removal when the sweep began
    And a terminal opened in it during the sweep
    Then the worktree is kept

  @node
  Scenario: A removed worktree can be checked out again
    Given the sweep removed a thread's worktree
    When the user continues the thread
    Then the worktree can be recreated from the thread's branch

  @node
  Scenario: Old browser artifacts are removed by age
    Given browser artifacts are kept for 3 days
    When the node sweeps storage
    Then artifacts older than 3 days are removed
    And newer ones stay
