# Sources:
#   /home/olafura/dev/opentui-qml src/runtime/plugins.ts (listPlugins, unregisterPlugin)
#   apps/server-ex/lib/hal_c2/acp/catalog.ex (registry search, install, checksums, uninstall refused while referenced)
#   apps/server-ex/lib/hal_c2/usage_limit_sources.ex (secrets sealed in the MC, marker shown to clients)
#   apps/server-ex/lib/hal_c2/plugins.ex (plugins.list per environment, permissions with their grant)
#   apps/web/src/components/settings/AcpRegistrySearchStep.tsx (search, Add, Added)
#   packages/contracts/src/rpc.ts (server.searchAcpRegistry, server.prepareAcpRegistryAgent, server.uninstallAcpRegistryManagedBinary)

Feature: Plugin catalog
  The user can see every plugin installed on each surface and on each environment,
  where it came from, which version it is, what it is allowed to do, and whether an
  update is waiting. Nothing gets more access than the user granted.

  @tui
  Scenario: The TUI lists its loaded plugins with their kind and file
    Given the TUI loaded the QML plugin "clock" and the script plugin "metrics"
    When the user lists the installed plugins
    Then "clock" and "metrics" are listed with their kind and source file

  @mc
  Scenario: The ACP registry can be searched for agents that run on this machine
    When the user searches the ACP registry for "code"
    Then at most 20 matching agents are listed, best match first
    And agents that cannot run on this platform are left out

  @mc
  Scenario: An agent binary from the registry is checked before it is used
    Given the registry lists a checksum for the agent "acme"
    When the user adds "acme" and the download does not match the checksum
    Then the install fails saying the checksum did not match
    And no instance of "acme" is created

  @mc
  Scenario: An agent download over plain HTTP from another host is refused
    Given the registry points the agent "acme" at a plain HTTP address on another machine
    When the user adds "acme"
    Then the install is refused

  @mc
  Scenario: A registry agent still in use cannot be uninstalled
    Given the instance "acme_work" uses the registry agent "acme"
    When the user tries to uninstall "acme"
    Then the agent's files are kept
    # Neither server explains why: both answer {removed: false} while an instance uses it.
    And the MC reports that nothing was removed

  @mc
  Scenario: The registry keeps working offline from its last copy
    Given the MC fetched the registry earlier
    And the registry cannot be reached now
    When the user searches the registry
    Then results come from the last fetched copy

  @backlog @desktop @mobile @tui
  Scenario: Each surface lists its installed UI plugins with version and source
    Given the plugins "quota" from a paired MC and "clock" from a local file are installed
    When the user opens the plugin list
    Then each plugin shows its version and where it came from

  @mc
  Scenario: The MC's plugins are listed per environment
    Given two environments with different MC plugins
    When the user opens the plugin list for the second environment
    Then only that environment's MC plugins are listed

  @backlog @desktop @mobile
  Scenario: The plugin list has a section for each environment's MC plugins
    Given two environments with different MC plugins
    When the user opens the plugin list
    Then each environment's MC plugins are listed under that environment

  @backlog @desktop @mobile @tui
  Scenario: An available update is shown next to the installed version
    Given the plugin "quota" version 1.0 is installed from a paired MC
    And the paired MC offers "quota" version 1.1
    When the user opens the plugin list
    Then "quota" shows that version 1.1 is available

  @backlog @desktop @mobile @tui
  Scenario: Updating a plugin replaces it and keeps its settings
    Given "quota" has an update and custom settings
    When the user updates "quota"
    Then "quota" runs the new version with the same settings

  @backlog @desktop @mobile @tui
  Scenario: A failed plugin update keeps the installed version
    Given "quota" has an update that fails to load
    When the user updates "quota"
    Then the user is told the update failed
    And the previous version keeps running

  @backlog @desktop @mobile @tui
  Scenario: A plugin can be rolled back to the version before the last update
    Given "quota" was updated from 1.0 to 1.1
    When the user rolls "quota" back
    Then "quota" 1.0 runs again

  @backlog @desktop @mobile @tui
  Scenario Outline: The trust level of a plugin depends on its source
    Given a plugin from <source>
    When the user installs it
    Then it is marked as <trust>

    Examples:
      | source                                | trust                     |
      | a signed release from HAL-C2         | signed                    |
      | a paired MC                         | from that MC            |
      | a local file                          | local                     |
      | a pasted URL                          | unverified                |

  @desktop @mobile @tui @backlog-desktop @backlog-mobile
  Scenario: An unverified plugin asks for confirmation before it loads
    When the user installs a plugin from a pasted URL
    Then the user is warned that the plugin is not signed
    And the plugin loads only after the user confirms

  @backlog @desktop @mobile @tui
  Scenario: A plugin whose signature does not match is refused
    Given a plugin that claims a signature which does not match its contents
    When the user installs it
    Then the install is refused as tampered

  @backlog @desktop @mobile @tui
  Scenario: The user sees the permissions a plugin asks for before installing
    Given the plugin "team-status" asks to read thread titles and to reach the network
    When the user starts installing "team-status"
    Then the requested permissions are listed
    And the user can accept or cancel

  @backlog @desktop @mobile @tui
  Scenario: Declining a plugin's permissions cancels the install
    Given the plugin "team-status" asks to reach the network
    When the user declines the requested permissions
    Then "team-status" is not installed

  @backlog @desktop @mobile @tui
  Scenario: A plugin cannot use a permission it did not ask for
    Given the plugin "clock" asked for no network access
    When "clock" tries to reach the network
    Then the request is blocked
    And the attempt is reported for "clock"

  @backlog @desktop @mobile @tui
  Scenario: An update that asks for more permissions needs the user's approval
    Given "team-status" is installed with read access to thread titles
    And its update also asks to send messages
    When the user updates "team-status"
    Then the user is asked to approve the new permission before the update runs

  @backlog @desktop @mobile @tui
  Scenario: A granted permission can be revoked later
    Given "team-status" was granted network access
    When the user revokes that permission
    Then "team-status" can no longer reach the network

  @mc
  Scenario: MC plugins report the permissions they were granted on that environment
    Given the MC plugin "gitea" was granted access to project remotes
    When the user opens "gitea" in the plugin list
    Then the granted permissions are shown

  @backlog @desktop @mobile
  Scenario: The plugin list shows an MC plugin's granted permissions
    Given the MC plugin "gitea" was granted access to project remotes
    When the user opens "gitea" in the plugin list
    Then "Read project remotes" is shown as granted

  @backlog @desktop @mobile @tui
  Scenario: Removing a plugin from the catalog deletes it and its settings
    Given "quota" is installed with custom settings
    When the user removes "quota" and confirms
    Then "quota" is no longer listed
    And its settings are deleted
