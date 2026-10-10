# Sources:
#   docs/user/background-service.md
#   apps/server-ex/lib/hal_c2/background_policy.ex (profiles, leases, host power, pause rules)
#   apps/server-ex/lib/hal_c2/web/socket.ex (server.reportClientActivity)
#   apps/server-ex/test/mc_parity_test.exs (reportHostPowerState, getBackgroundPolicy, reportClientActivity aligned)
#   apps/server-ex/rel/overlays/bin/hal-c2-service
#   packages/contracts/src/rpc.ts (server.getBackgroundPolicy, server.reportHostPowerState, server.reportClientActivity)
#   apps/web/src/components/settings/SettingsPanels.tsx (background activity profile and dialog)
#   apps/web/src/components/settings/SourceControlSettings.tsx, apps/web/src/components/ui/number-field.tsx (interval steps)
#   apps/server/src/cli (hal-c2 service install, status, restart, uninstall)
#   apps/server/src/serviceLauncher.ts
#   apps/server/src/cloud/bootService.ts (status problems, the lingering prerequisite, restart-pending)
#   apps/server-ex/lib/hal_c2/service.ex
#   apps/tui/src/host/clientActivity.ts (what the terminal client reports)
#   apps/web/src/lib/backgroundActivityReporter.ts (renewal cadence, scopes, interaction)
#   apps/tui/src/host/sections/backgroundActivity.ts (custom intervals)

Feature: Background activity and the background service
  The MC does periodic work such as fetching git and checking providers only
  while someone is looking, and backs off on battery or when the machine is
  locked. The background service keeps the MC running without a client.

  Rule: Background activity follows the user's profile

    @mc
    Scenario Outline: Each profile sets how often background work runs
      Given the background profile is <profile>
      Then git is fetched <fetch> and providers are checked every <health>

      Examples:
        | profile       | fetch             | health       |
        | performance   | every 15 seconds  | 60 seconds   |
        | balanced      | every 30 seconds  | 5 minutes    |
        | battery saver | never             | 15 minutes   |

    @mc
    Scenario Outline: Background work pauses when the host is constrained
      Given the background profile is <profile>
      And the host reports it is <state>
      Then periodic background work <result>

      Examples:
        | profile       | state         | result   |
        | balanced      | locked        | pauses   |
        | balanced      | on low power  | pauses   |
        | balanced      | on battery    | continues |
        | battery saver | on battery    | pauses   |
        | performance   | on low power  | continues |

    @mc
    Scenario: Background work runs only while a client is watching
      Given a client reported it is watching git status for thread "Fix login"
      When the client closes its connection
      Then the MC stops fetching git for "Fix login"

    @mc
    Scenario: A client's activity report expires if not renewed
      Given a client reported it is watching provider status
      When the client does not renew the report for its lifetime
      Then the MC stops checking provider health for it

    @shared @backlog-mobile
    Scenario: Clients report what the user is looking at
      When the user opens a thread in the client
      Then the client tells the MC it is watching that thread's git status

    # Legacy: apps/web/src/lib/backgroundActivityReporter.ts (REPORT_INTERVAL_MS, LEASE_TTL_MS, debounce)
    @backlog @desktop
    Scenario: A client renews its activity report well before the MC would let it lapse
      Given a client connected to an MC
      When nothing changes for a minute
      Then the client has told the MC it is watching at least once every 25 seconds
      And each report asks to be kept for 45 seconds

    @backlog @desktop
    Scenario: A client tells the MC at once when the user comes back to it
      Given the client is in the background
      When the user brings it to the front
      Then the client tells the MC it is in front within a moment

    @backlog @desktop
    Scenario: A burst of changes is reported once
      Given the user switches threads, focus and windows within a fraction of a second
      Then the client sends one report to each MC for that burst

    @backlog @desktop
    Scenario: A client that has been left alone reports itself as not in use
      Given the client is in front
      And the user has not touched it for 45 seconds
      Then the client reports it as in front but not recently used

    @backlog @desktop
    Scenario: Every connected MC hears the client's activity
      Given a client connected to "studio" and "laptop"
      When the client reports its activity
      Then both "studio" and "laptop" receive the report
      And a report that cannot reach "laptop" does not stop the one to "studio"

    @backlog @desktop
    Scenario: Two views of one checkout are reported as one and end together
      Given two views of the same checkout's git status are open
      Then the client reports that checkout once
      When one view is closed
      Then the checkout is still reported
      When the other view is closed
      Then the checkout is no longer reported

    @backlog @desktop
    Scenario: Provider health is always reported and diagnostics only while shown
      Given a client that has just connected
      Then it reports watching provider status
      And it does not report watching diagnostics
      When the user opens diagnostics
      Then it also reports watching diagnostics

    @shared @backlog-mobile
    Scenario: The user sets custom background intervals
      When the user chooses advanced background activity for the environment
      And the user sets git fetch to every 2 minutes and turns off pausing when locked
      Then the MC fetches git every 2 minutes, even when locked

    @backlog @desktop @mobile @tui
    Scenario: Changing the profile keeps the custom intervals
      Given the user set git fetch to every 2 minutes
      When the user changes the background profile to performance
      Then git fetch is still every 2 minutes
      And the other intervals follow the performance profile

    @backlog @desktop @mobile @tui
    Scenario Outline: Background intervals are whole seconds with a floor
      When the user enters <entry> for the <interval> interval
      Then the interval is <result>

      Examples:
        | interval                | entry | result                       |
        | git fetch               | 0     | off, so git is never fetched |
        | git fetch               | 7.4   | 7 seconds                    |
        | git fetch               | -5    | 0 seconds                    |
        | provider health         | empty | the smallest allowed         |

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (host power monitor intervals, minimum 5, normalizeIntervalSeconds)
    @backlog @desktop
    Scenario Outline: Host power checks cannot be set faster than every 5 seconds
      When the user enters <entry> for the <interval> interval
      Then the interval is <result>

      Examples:
        | interval                | entry | result     |
        | active host power check | 2     | 5 seconds  |
        | active host power check | empty | 5 seconds  |
        | idle host power check   | 0     | 5 seconds  |
        | idle host power check   | 12.4  | 12 seconds |

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx, SourceControlSettings.tsx,
    # apps/web/src/components/ui/number-field.tsx (Increase and Decrease, arrow keys; steps of 5 or 30)
    @backlog @desktop
    Scenario Outline: The interval buttons and arrow keys step by the interval's own amount
      Given the <interval> interval is <from> seconds
      When the user chooses Increase, or presses the up arrow in the field
      Then the interval is <up> seconds
      When the user chooses Decrease, or presses the down arrow in the field
      Then the interval is <from> seconds again

      Examples:
        | interval                | from | up  |
        | git fetch               | 60   | 65  |
        | provider health         | 300  | 330 |
        | active host power check | 10   | 15  |
        | idle host power check   | 60   | 90  |

    @backlog @desktop
    Scenario: Decreasing an interval stops at its smallest allowed value
      Given the git fetch interval is 3 seconds
      When the user chooses Decrease
      Then the interval is 0 seconds
      When the user chooses Decrease again
      Then the interval is still 0 seconds

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (BackgroundActivityDialog, resetBackgroundActivitySettings)
    @backlog @desktop
    Scenario: Resetting all background activity settings returns to the default profile
      Given the user set custom background intervals and turned off pausing when locked
      When the user chooses to reset all background activity settings
      Then every interval and every pause rule is back at its default
      And the background profile is the default one

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (background activity profile select, isEnvironmentScope)
    @backlog @desktop
    Scenario: Advanced background activity needs a single environment
      Given the settings apply to "laptop" and "server" together
      When the user looks at the background profile choices
      Then the advanced choice is listed as needing one environment and cannot be chosen
      When the user picks only "laptop"
      Then the advanced choice can be chosen

    # Legacy: apps/web/src/components/settings/SettingsPanels.tsx (BACKGROUND_ACTIVITY_BOOLEAN_OVERRIDES)
    @backlog @desktop
    Scenario Outline: Each pause rule can be turned off separately
      Given the user chose advanced background activity for the environment
      When the user turns off <rule>
      Then <condition> no longer pauses background work
      And the other pause rules keep their setting

      Examples:
        | rule                        | condition                          |
        | pausing when locked         | the host being locked              |
        | pausing on host low power   | the host being in low power mode   |
        | pausing on client low power | the client being in low power mode |
        | pausing on battery          | the host being on battery          |

    @backlog @desktop @mobile @tui
    Scenario: A legacy interval setting shows up as advanced
      Given the settings file still holds a git fetch interval from before profiles existed
      When the user opens background activity
      Then the profile reads as advanced
      And restoring defaults clears the legacy interval too

  Rule: The background service keeps the MC running

    @mc
    Scenario: The service starts the MC again after an update restart
      Given the MC runs under its service
      When the MC stops to finish an update
      Then the service starts it again on the new version

    @mc
    Scenario: The user installs and removes the background service
      When the user installs the background service
      Then the server starts at login and runs without a client
      When the user uninstalls the service
      Then the server no longer starts at login

    @mc
    Scenario Outline: Service status explains what needs fixing
      Given the service <problem>
      When the user checks the service status
      Then the status names the problem and how to fix it

      Examples:
        | problem                                  |
        | cannot linger after logout on Linux      |
        | is disabled                              |
        | is stopped                               |
        | is waiting for a restart                 |

    @mc
    Scenario: Reinstalling repairs a broken service
      Given the service definition was damaged
      When the user installs the background service again
      Then the service runs normally

    @backlog @mc
    Scenario: The service survives an agent process being killed for memory
      Given the background service is running a provider's agent process
      When the system kills that agent process for using too much memory
      Then the service and the MC keep running

    @backlog @mc
    Scenario: The service finds provider tools on the installer's search path
      Given a provider tool that is on the user's PATH at install time
      When the user installs the background service
      Then the service can start that provider tool
      And the folders where providers are usually installed are searched as well

    @backlog @mc
    Scenario: Installing an older version over a newer service is refused
      Given the background service runs version 1.4.0
      When the user installs the background service from version 1.3.0
      Then the install is refused as a downgrade
      And it goes ahead only when the user explicitly allows a downgrade

    @backlog @mc
    Scenario: Installing the service is refused while a remote update is pending
      Given a remote update is waiting to be applied
      When the user installs the background service
      Then the install is refused saying an update is pending
      And the service is left as it was

    @backlog @mc
    Scenario: Installing without starting only rewrites the service files
      When the user installs the background service without starting it
      Then the service definition is rewritten
      And a running service is marked as waiting for a restart

    @backlog @mc
    Scenario: Restarting the service leaves a service for another HAL-C2 home alone
      Given a background service that serves a different HAL-C2 home
      When the user restarts the service from this home
      Then the other home's service is not restarted

    @backlog @mc
    Scenario: A repair that fails does not leave the service stopped
      Given the background service is running
      When the user repairs it and the repair fails
      Then the service that was running before is started again

    @backlog @mc
    Scenario: On Linux the service gets lingering before it is installed
      Given the user's account cannot keep services running after logout
      When the user installs the background service
      Then the installer turns lingering on if it may
      And otherwise the status says to run the loginctl enable-linger command as an administrator

    @backlog @mc
    Scenario: Windows has no background service yet
      Given the MC runs on Windows
      When the user installs the background service
      Then the install fails closed saying the background service is not available on Windows
