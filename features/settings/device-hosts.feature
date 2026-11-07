# Sources:
#   https://github.com/pingdotgg/t3code/pull/17440
#   https://github.com/pingdotgg/t3code/pull/21842
#   https://github.com/pingdotgg/t3code/pull/21843
#   https://github.com/pingdotgg/t3code/pull/21844
#   https://github.com/pingdotgg/t3code/pull/21846
#   apps/web/src/components/settings/DeviceHostsSettings.tsx
#   apps/web/src/components/settings/DeviceHostEditor.tsx
#   apps/web/src/components/settings/deviceHostsSettings.logic.ts (updateDeviceHosts)
#   apps/web/src/components/settings/deviceHostConnectionChecks.ts
#   apps/web/src/components/settings/useHostConnectionChecks.ts
#   docs/user/devices.md (SSH device hosts)
#   apps/server-ex/lib/hal_c2/devices.ex (device.testHost, ssh hosts reported unavailable)
#   apps/server-ex/lib/hal_c2/rpc.ex (device.testHost, device.list retryHostId)
#   apps/server/src/device/SshDeviceHost.ts, sshDeviceScript.ts, localSshDeviceHost.ts, DeviceHost.ts,
#     and their tests, DeviceMultiHost.test.ts (the SSH transport, remote helper lifecycle, skipping a host
#     that is this machine, several hosts side by side; all dropped with SSH hosts, a remote machine is
#     an MC of the cluster)

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

    # Upstream #17440: SSH device-host tunnels keep their own connection under ControlMaster.
    # SSH device hosts are dropped; a remote machine's devices come from its own MC.
    @dropped @mc
    Scenario: An SSH device host's tunnel does not share the user's SSH connection
      Given the user's SSH configuration shares connections to "mac-mini"
      When the MC opens a tunnel to the device host "mac-mini"
      Then the tunnel uses a connection of its own
      And closing it leaves no forwards behind

  # Upstream #21846: an EAS Simulator host runs iOS simulators in Expo's cloud for one
  # environment, which holds the Expo credential and starts the sessions. Sessions bill the
  # Expo account until they stop, so every session is bounded. Not an SSH host and not a
  # machine of the cluster, so this is not dropped with SSH hosts.
  Rule: EAS Simulator hosts

    # Upstream #21842: a host holds a label, an optional EAS project and its session bounds.
    @backlog @desktop @priority-low
    Scenario: An EAS Simulator host is added with bounds on its sessions
      When the user adds an EAS Simulator host "Cloud iPhone" to "Laptop" with sessions of at most 60 minutes, 10 idle minutes and 2 at once
      Then "Cloud iPhone" is listed with those limits

    # Upstream #21842: EAS caps a session at 115 minutes and its idle time below its length.
    @backlog @desktop @priority-low
    Scenario Outline: EAS Simulator session limits EAS would refuse cannot be saved
      When the user sets an EAS Simulator host's sessions to <length> minutes with <idle> idle minutes
      Then the host cannot be saved and the user is told why

      Examples:
        | length | idle |
        | 120    | 10   |
        | 30     | 30   |

    # Upstream #21843: the credential is the host's saved token, then EXPO_TOKEN, then the
    # session "eas login" keeps; no Expo CLI is needed.
    @backlog @mc @priority-low
    Scenario Outline: An EAS Simulator host signs in with the first credential it finds
      Given <available>
      When the MC signs in to Expo for the EAS Simulator host
      Then it uses <used>

      Examples:
        | available                                                          | used                   |
        | a token saved for the host, EXPO_TOKEN and an "eas login" session | the saved token        |
        | EXPO_TOKEN and an "eas login" session                              | EXPO_TOKEN             |
        | only an "eas login" session                                        | the "eas login" session |

    # Upstream #21843: the saved token is a secret setting.
    @backlog @mc @priority-low
    Scenario: An EAS Simulator host's token never reaches clients
      Given the EAS Simulator host has a saved access token
      When a client reads the settings
      Then the token is redacted
      And saving the redacted value back keeps the saved token

    # Upstream #21843: a credential that is not printable text is refused without echoing it.
    @backlog @mc @priority-low
    Scenario: A malformed Expo credential is refused naming where it came from
      Given EXPO_TOKEN holds a token with a newline in it
      When the MC signs in to Expo for the EAS Simulator host
      Then the sign-in is refused naming EXPO_TOKEN
      And the token is not shown

    # Upstream #21843: without a project on the host, sessions run under the EAS project the
    # thread's app config names.
    @backlog @mc @priority-low
    Scenario: An EAS Simulator session runs under the thread's EAS project
      Given the EAS Simulator host names no project
      And the thread's project has an app config naming the EAS project "shop-app"
      When the thread opens the host's iPhone
      Then the session runs under "shop-app"

    # Upstream #21844: opening the host's iPhone starts a session and shows it like any device.
    @backlog @mc @desktop @priority-low
    Scenario: Opening an EAS Simulator host's iPhone starts a cloud session
      When the user opens the iPhone of the EAS Simulator host "Cloud iPhone"
      Then an EAS Simulator session starts with the host's limits
      And once it runs the thread shows it like any other device

    # Upstream #21844: powering off stops the session; closing the panel leaves it to its idle limit.
    @backlog @mc @priority-low
    Scenario: Powering off an EAS Simulator stops its session
      Given an EAS Simulator session is running for the thread
      When the user powers the device off
      Then the session is stopped and stops billing the account

    # Upstream #21844: the host refuses to start past its concurrent session limit.
    @backlog @mc @priority-low
    Scenario: An EAS Simulator host refuses a session past its limit
      Given the EAS Simulator host allows 2 sessions at once and 2 are running
      When another thread opens the host's iPhone
      Then the session is refused and the user is told the host's limit is reached

    # Upstream #21844: a session is recorded before it is created, so one a crashed MC left
    # behind is found and stopped; sessions started elsewhere on the account are left alone.
    @backlog @mc @priority-low
    Scenario: EAS Simulator sessions an MC left behind are stopped when it starts again
      Given the MC stopped while an EAS Simulator session it started was running
      And another session on the same Expo account was started elsewhere
      When the MC starts again
      Then the session it started is stopped
      And the other session keeps running

    # Upstream #21844: removing or changing the host, or turning device support off, stops its sessions.
    @backlog @mc @priority-low
    Scenario: Removing an EAS Simulator host stops its sessions
      Given an EAS Simulator session is running on the host "Cloud iPhone"
      When the user removes "Cloud iPhone"
      Then the session is stopped

    # Upstream #21846: the editor checks the account as it opens and on "Check account".
    @backlog @desktop @priority-low
    Scenario: The EAS Simulator editor names the Expo account and its projects
      Given the MC signs in to Expo as "julius" through its "eas login" session
      When the user opens the EAS Simulator host editor
      Then it says the host signs in as "julius" through "eas login"
      And the user can pick the session project from that account's projects

    # Upstream #21846: a rejected token is shown in the editor.
    @backlog @desktop @priority-low
    Scenario: A rejected Expo token is called out in the EAS Simulator editor
      Given the EAS Simulator host's saved token was revoked
      When the user chooses "Check account"
      Then the editor says the token was rejected

    # Upstream #21846: an MC that does not know EAS hosts would drop them on save.
    @backlog @desktop @priority-low
    Scenario: EAS Simulator hosts are offered only for MCs that support them
      Given the environment "Old" runs an MC that does not know EAS Simulator hosts
      When the user opens the Integrations settings for "Old"
      Then no EAS Simulator section is shown
