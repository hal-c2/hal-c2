# Sources:
#   apps/server-ex/lib/hal_c2/upgrade.ex (release check, restart path, outcome, errors)
#   apps/server-ex/lib/hal_c2/upgrade/source.ex (local cache, cluster peer, release download, checksum)
#   apps/server-ex/lib/hal_c2/hot.ex (in-place load, code_change, reload_cluster)
#   apps/server-ex/lib/hal_c2/recovery.ex (continuing cut-off turns)
#   apps/server-ex/lib/mix/tasks/hal_c2.upgrade.ex
#   apps/server-ex/rel/overlays/bin/hal-c2-service
#   docs/internals/server-updates.md

Feature: Hot code upgrade
  The MC updates itself. When the new release only changes code, it loads in
  place and nothing restarts. When it cannot, it installs the release and
  restarts through its service, then reports how the update ended.

  Background:
    Given an MC running release "1.3.0"

  @mc
  Scenario: A code-only update loads without a restart
    Given release "1.3.1" changes only code
    When the user updates the MC to "1.3.1"
    Then the MC runs "1.3.1"
    And open connections, terminals and agent sessions stay up

  @mc
  Scenario: An update that changes the runtime restarts the MC
    Given release "1.4.0" changes a native library
    And the MC runs under its service
    When the user updates the MC to "1.4.0"
    Then the MC installs "1.4.0" and restarts
    And after reconnecting the client is told the update committed

  @mc
  Scenario: A release that fails to boot is reported as rolled back
    Given release "1.4.0" cannot boot
    When the user updates the MC to "1.4.0"
    Then the MC comes back on "1.3.0"
    And the client is told the update rolled back

  @mc
  Scenario: Turns cut off by the restart continue afterwards
    Given continuing threads after restarts is on for the project
    And an agent is mid-turn in thread "Fix login"
    When the MC restarts to finish an update
    Then "Fix login" is asked to continue where it left off
    But a thread the user wrote in since, archived or deleted is left alone

  @mc
  Scenario: The MC fetches the release from the nearest place that has it
    Given a cluster peer already downloaded "1.4.0"
    When the user updates the MC to "1.4.0"
    Then the MC fetches the release from the peer instead of the internet

  @mc
  Scenario: A downloaded release that fails its checksum is not installed
    Given the downloaded "1.4.0" release does not match its checksum
    When the user updates the MC to "1.4.0"
    Then the update fails and the MC keeps running "1.3.0"

  @mc
  Scenario Outline: An update the MC refuses
    Given <situation>
    When the user updates the MC to "<version>"
    Then the user is told the update cannot run because <reason>

    Examples:
      | situation                                     | version | reason                                   |
      | the MC runs from a source checkout          | 1.4.0   | a checkout updates with mix hal_c2.upgrade   |
      | the MC already runs "1.3.0"                 | 1.3.0   | it already runs that version             |
      | the MC was not started by its service       | 1.4.0   | nothing would restart it                 |

  @mc
  Scenario: A developer upgrades every MC in a cluster from one build
    Given three connected MCs
    When the developer upgrades the cluster to a new build
    Then the first MC receives the build
    And the other MCs fetch it from the first
