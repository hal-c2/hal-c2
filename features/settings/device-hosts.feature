# Sources:
#   apps/web/src/components/settings/DeviceHostsSettings.tsx
#   apps/web/src/components/settings/DeviceHostEditor.tsx
#   apps/web/src/components/settings/deviceHostsSettings.logic.ts (updateDeviceHosts)
#   apps/web/src/components/settings/deviceHostConnectionChecks.ts
#   apps/web/src/components/settings/useHostConnectionChecks.ts
#   docs/user/devices.md (SSH device hosts)
#   apps/server-ex/lib/hal_c2/devices.ex (device.testHost, ssh hosts reported unavailable)
#   apps/server-ex/lib/hal_c2/rpc.ex (device.testHost, device.list retryHostId)

Feature: Device hosts
  Simulators and emulators on another machine used to be reached over SSH from an environment.
  On hal-c2 every machine is its own MC: a remote machine joins the cluster and its devices
  appear under its own environment, so SSH device hosts are dropped and the MC says so.

  Background:
    Given the user has opened the Integrations settings for the environment "Laptop"

  Rule: The MC explains that SSH device hosts moved to cluster MCs

    @mc
    Scenario: Testing an SSH device host tells the user to add that machine as an MC
      Given a device host "Mac mini" with the SSH target "mac-mini"
      When the MC tests the connection to "Mac mini"
      Then "Mac mini" is reported unavailable
      And the reason says to run HAL-C2 on "mac-mini" and add it to this cluster as an MC

    @mc
    Scenario: A configured SSH device host is listed as unavailable
      Given the settings list a device host "Mac mini"
      When the MC lists devices
      Then "Mac mini" is listed as unavailable with the same reason

    @mc
    Scenario: Retrying an SSH device host keeps it unavailable
      Given "Mac mini" is listed as unavailable
      When the user retries "Mac mini"
      Then "Mac mini" is still unavailable

  Rule: Managing SSH device hosts from settings

    @dropped @desktop
    Scenario: Adding a device host saves it on every selected environment
      When the user adds a device host named "Mac mini" with the SSH target "ada@mac-mini"
      Then "Mac mini" is listed as a device host on each selected environment

    @dropped @desktop
    Scenario: A device host needs a name and an SSH target
      When the user adds a device host without an SSH target
      Then the host cannot be saved

    @dropped @desktop
    Scenario: Editing a device host keeps its identity
      Given "Mac mini" is a device host
      When the user changes its port to 2222
      Then "Mac mini" uses port 2222
      And no second host is added

    @dropped @desktop
    Scenario: Removing a device host closes its device sessions
      Given "Mac mini" is a device host with an open simulator
      When the user removes "Mac mini"
      Then "Mac mini" is no longer listed
      And its device sessions are closed

    @dropped @desktop
    Scenario: An edit that matches several hosts asks the user to pick an environment
      Given two environments list different hosts with the same SSH destination
      When the user edits that destination across all environments
      Then the user is told several hosts match and to select the environment to edit

    @dropped @desktop
    Scenario Outline: Testing a device host reports a result per environment
      Given the environment "<environment>" <state>
      When the user tests the connection to "Mac mini"
      Then the result for "<environment>" is "<result>"

      Examples:
        | environment | state                                   | result                        |
        | Laptop      | reaches the host with Xcode installed   | iOS available                 |
        | Build box   | is the same machine as the host         | already available locally     |
        | Old box     | is disconnected                         | Environment disconnected      |

    @dropped @desktop
    Scenario: A host that some environments cannot reach is reported
      Given "Build box" cannot reach "Mac mini"
      When the user tests the connection to "Mac mini"
      Then the user is told 1 of 2 environments failed and could not connect from "Build box"

    @dropped @desktop
    Scenario: Saving on some environments but not all is reported
      Given saving on "Build box" fails
      When the user adds a device host
      Then the user is told the device hosts were not saved on all environments
