# Sources:
#   apps/server-ex/lib/hal_c2/plugins/host.ex (Host.provider_instances/3 and the record of what each plugin added, gated by providers:configure)
#   apps/server-ex/lib/hal_c2/plugins.ex (a plugin's instances leave settings once it is off, removed or stops asking)
#   apps/server-ex/lib/hal_c2/plugins/package.ex (permission ids and their labels)
#   apps/server-ex/lib/hal_c2/settings.ex (every save keeps that record the host's, and drops the ids it deletes)
#   apps/server-ex/lib/hal_c2/provider_secrets.ex (sensitive variables sealed on every settings write)
#   packages/contracts/src/plugin.ts (PluginPermissionId)
#   packages/contracts/src/providerInstance.ts (ProviderInstanceConfig, ProviderInstanceId)
#   docs/user/plugins.md
#
# The MC scenarios run from apps/server-ex with
#   mise exec -- mix features plugins/plugin-providers.feature

Feature: Provider instances a plugin adds
  A plugin that routes agents somewhere of its own, a proxy it runs, say, adds provider
  instances for them to Settings → Providers and keeps them set up as it changes: an
  ordinary instance the user can rename, switch off or delete like any other. It needs
  `providers:configure`. Each goes under the instance id `plugin_<plugin id>_<name>`, and
  the MC records which ones the plugin added: that record, not the id, is what the plugin
  reaches, so an instance of the user's is never its, whatever it is called. The save
  that deletes one of them ends the plugin's hold on that id, and no client's save hands
  a plugin one. They last
  only while the plugin is installed, on and granted the permission; the ones the MC took
  out are listed to the plugin as such until it puts or removes them, or the user takes
  the id, so it can tell them from ones the user deleted.

  Background:
    Given an MC with the user's own provider instance "claude-work"

  @mc
  Scenario: A plugin adds a provider instance of its own
    Given a plugin granted "providers:configure"
    When it puts the instance "claude" for Claude named "Claude via the proxy"
    Then Settings → Providers has the instance "plugin_host-probe_claude" named "Claude via the proxy"
    And the plugin lists only the instance "claude"

  @mc
  Scenario: A plugin keeps its instance set up by replacing it
    Given a plugin granted "providers:configure"
    And it put the instance "claude" for Claude with the base URL "http://127.0.0.1:8317"
    When it puts the instance "claude" for Claude with the base URL "http://127.0.0.1:8318"
    Then the instance "plugin_host-probe_claude" runs Claude with the base URL "http://127.0.0.1:8318"

  @mc
  Scenario: A plugin removes its instance
    Given a plugin granted "providers:configure"
    And it put the instance "claude" for Claude named "Claude via the proxy"
    When it removes the instance "claude"
    Then Settings → Providers has no instance "plugin_host-probe_claude"
    And the user's instance "claude-work" is as it was

  @mc
  Scenario: A secret a plugin gives its instance is sealed like the user's
    Given a plugin granted "providers:configure"
    When it puts the instance "claude" for Claude with the sensitive variable "ANTHROPIC_AUTH_TOKEN" set to "sk-proxy"
    Then the settings document holds "ANTHROPIC_AUTH_TOKEN" of "plugin_host-probe_claude" redacted
    And the agent of "plugin_host-probe_claude" is given "ANTHROPIC_AUTH_TOKEN" as "sk-proxy"

  @mc
  Scenario: A plugin never reaches the user's instances
    Given a plugin granted "providers:configure"
    When it lists its instances
    Then "claude-work" is not among them
    When it removes the instance "claude-work"
    Then the user's instance "claude-work" is as it was

  @mc
  Scenario: An instance of the user's under the id a plugin would use stays the user's
    Given the user added an instance of their own as "plugin_host-probe_claude"
    And a plugin granted "providers:configure"
    When it puts the instance "claude" for Claude named "Claude via the proxy"
    Then the MC refuses the call saying it "is a provider instance of the user's"
    And the user's instance "plugin_host-probe_claude" is as it was
    And the plugin lists no instances
    When it removes the instance "claude"
    Then the user's instance "plugin_host-probe_claude" is as it was

  @mc
  Scenario Outline: A name that cannot be an instance id of the plugin's is refused
    Given a plugin granted "providers:configure"
    When it puts the instance <name> for Claude named "Claude via the proxy"
    Then the MC refuses the call saying it "cannot name a provider instance"

    Examples:
      | name                                                            |
      | "Claude"                                                        |
      | "claude_work"                                                   |
      | "../claude-work"                                                |
      | ""                                                              |
      | "a-name-long-enough-to-make-the-instance-id-longer-than-sixty4" |

  @mc
  Scenario: A plugin without the permission is refused
    Given a plugin granted "threads:read"
    When it puts the instance "claude" for Claude named "Claude via the proxy"
    Then the MC refuses the call naming "providers:configure"
    And Settings → Providers has no instance "plugin_host-probe_claude"

  Rule: A plugin's instances leave with it, and come back when it does

    @mc
    Scenario: Turning the plugin off takes its instances out of Settings → Providers
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      When the user turns the plugin off
      Then Settings → Providers has no instance "plugin_host-probe_claude"
      And the user's instance "claude-work" is as it was

    @mc
    Scenario: Turned on again, the plugin adds its instances back under the same id
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      And the user turned the plugin off
      When the user turns the plugin on again
      Then the plugin lists "claude" as taken out while it was off
      When it puts the instance "claude" for Claude named "Claude via the proxy"
      Then Settings → Providers has the instance "plugin_host-probe_claude" named "Claude via the proxy"
      And the plugin lists nothing as taken out while it was off

    @mc
    Scenario: An id the user takes while the plugin is off is not listed as taken out
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      And the user turned the plugin off
      When the user adds an instance of their own as "plugin_host-probe_claude"
      And the user turns the plugin on again
      Then the plugin lists nothing as taken out while it was off
      And the user's instance "plugin_host-probe_claude" is as it was

    @mc
    Scenario: An instance taken out that the plugin removes is not listed as taken out
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      And the user turned the plugin off
      When the user turns the plugin on again
      And it removes the instance "claude"
      Then the plugin lists nothing as taken out while it was off
      And Settings → Providers has no instance "plugin_host-probe_claude"

    @mc
    Scenario: Removing the plugin takes its instances out of Settings → Providers
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      When the plugin is removed from the MC
      Then Settings → Providers has no instance "plugin_host-probe_claude"

    @mc
    Scenario: An update that stops asking for the permission takes its instances away
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      When an update of the plugin no longer asks for "providers:configure"
      Then Settings → Providers has no instance "plugin_host-probe_claude"

    @mc
    Scenario: An instance the user deleted stays deleted until the plugin adds it again
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      When the user deletes the instance "plugin_host-probe_claude" in Settings → Providers
      Then Settings → Providers has no instance "plugin_host-probe_claude"
      And the plugin lists no instances
      And the plugin lists nothing as taken out while it was off

    @mc
    Scenario Outline: An instance of the user's named like a plugin's never leaves with one
      Given the user added an instance of their own as <id>
      And a plugin granted "providers:configure"
      When the user turns the plugin off
      Then the user's instance <id> is as it was

      Examples:
        | id                         |
        | "plugin_host-probe_work"   |
        | "plugin_x_y"               |

    @mc
    Scenario: An instance the user adds where they deleted the plugin's is theirs
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      And the user deleted the instance "plugin_host-probe_claude" in Settings → Providers
      When the user adds an instance of their own as "plugin_host-probe_claude"
      And the user turns the plugin off
      Then the user's instance "plugin_host-probe_claude" is as it was

    @mc
    Scenario: An instance the user puts in place of the plugin's before the MC reconciles is theirs
      Given a plugin granted "providers:configure"
      And it put the instance "claude" for Claude named "Claude via the proxy"
      When the user deletes "plugin_host-probe_claude" and adds one of their own under that id, saving twice at once
      And the user turns the plugin off
      Then the user's instance "plugin_host-probe_claude" is as it was

  Rule: Settings → Providers shows whose an instance is

    # The instance id carries the plugin's id; the clients do not show it apart yet (hal-c2/hal-c2#1645).
    @desktop @mobile @tui @backlog
    Scenario: An instance a plugin added is marked as the plugin's
      Given the plugin "CLIProxyAPI" added the instance "Claude via CLIProxyAPI"
      When the user opens Settings → Providers
      Then "Claude via CLIProxyAPI" is marked as added by the plugin "CLIProxyAPI"
      And the user can still rename, switch off or delete it
