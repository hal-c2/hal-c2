# Sources:
#   docs/user/background-service.md
#   apps/server-ex/lib/hal_c2/background_policy.ex (profiles, leases, host power, pause rules)
#   apps/server-ex/lib/hal_c2/web/socket.ex (server.reportClientActivity)
#   apps/server-ex/test/node_parity_test.exs (reportHostPowerState, getBackgroundPolicy, reportClientActivity aligned)
#   apps/server-ex/rel/overlays/bin/hal-c2-service
#   packages/contracts/src/rpc.ts (server.getBackgroundPolicy, server.reportHostPowerState, server.reportClientActivity)
#   apps/web/src/components/settings/SettingsPanels.tsx (background activity profile and dialog)
#   apps/server/src/cli (hal-c2 service install, status, restart, uninstall)
#   apps/server/src/serviceLauncher.ts

Feature: Background activity and the background service
  The node does periodic work such as fetching git and checking providers only
  while someone is looking, and backs off on battery or when the machine is
  locked. The background service keeps the node running without a client.

  Rule: Background activity follows the user's profile

    @node
    Scenario Outline: Each profile sets how often background work runs
      Given the background profile is <profile>
      Then git is fetched <fetch> and providers are checked every <health>

      Examples:
        | profile       | fetch             | health       |
        | performance   | every 15 seconds  | 60 seconds   |
        | balanced      | every 30 seconds  | 5 minutes    |
        | battery saver | never             | 15 minutes   |

    @node
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

    @node
    Scenario: Background work runs only while a client is watching
      Given a client reported it is watching git status for thread "Fix login"
      When the client closes its connection
      Then the node stops fetching git for "Fix login"

    @node
    Scenario: A client's activity report expires if not renewed
      Given a client reported it is watching provider status
      When the client does not renew the report for its lifetime
      Then the node stops checking provider health for it

    @backlog @shared
    Scenario: Clients report what the user is looking at
      When the user opens a thread in the client
      Then the client tells the node it is watching that thread's git status

    @backlog @shared
    Scenario: The user sets custom background intervals
      When the user chooses advanced background activity for the environment
      And the user sets git fetch to every 2 minutes and turns off pausing when locked
      Then the node fetches git every 2 minutes, even when locked

  Rule: The background service keeps the node running

    @node
    Scenario: The service starts the node again after an update restart
      Given the node runs under its service
      When the node stops to finish an update
      Then the service starts it again on the new version

    @backlog @node
    Scenario: The user installs and removes the background service
      When the user installs the background service
      Then the server starts at login and runs without a client
      When the user uninstalls the service
      Then the server no longer starts at login

    @backlog @node
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

    @backlog @node
    Scenario: Reinstalling repairs a broken service
      Given the service definition was damaged
      When the user installs the background service again
      Then the service runs normally
