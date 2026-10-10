# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/internals/providers.md (route by instance, unknown drivers keep their configuration)
#   apps/server-ex/lib/hal_c2/settings.ex (providerInstances, provider_enabled?, instance_command/2 binaryPath of Codex and Claude)
#   apps/server-ex/lib/hal_c2/provider_secrets.ex (sensitive variables in the secret store)
#   apps/server-ex/lib/hal_c2/acp.ex (instance environment, built-ins off until enabled, binary/3 binaryPath)
#   apps/server-ex/lib/hal_c2/background_policy.ex (providerHealthRefreshInterval)
#   apps/server-ex/lib/hal_c2/environment.ex (providers, refresh_providers)
#   apps/server-ex/lib/hal_c2/orchestration.ex (driver_for)
#   apps/web/src/components/settings/ProviderSettingsPanel.tsx, apps/web/src/components/settings/ProviderInstanceCard.tsx
#   apps/web/src/components/settings/AddProviderInstanceDialog.tsx, apps/web/src/components/settings/AddProviderInstanceWizardSteps.tsx
#   apps/web/src/components/settings/ProviderAccentColorPicker.tsx, apps/web/src/components/settings/providerDriverMeta.ts
#   apps/web/src/components/settings/providerStatus.ts
#   apps/server/src/provider/providerStatusCache.ts (last known status, built-in ordering)
#   apps/server/src/provider/Layers/ProviderInstanceRegistryLive.ts, apps/server/src/provider/Layers/ProviderInstanceRegistryHydration.ts
#   apps/server/src/provider/Layers/ProviderRegistry.ts, apps/server/src/provider/makeManagedServerProvider.ts
#   packages/contracts/src/providerInstance.ts (ProviderInstanceMutation, availability)
#   packages/contracts/src/settings.ts (provider instance settings, environment variables, binaryPath)
#   packages/contracts/src/rpc.ts (server.refreshProviders)
#   apps/desktop-qt/src/native/ProviderSettingsInstances.cpp (rename, accent), ComposerModel.cpp (the picker's name and colour)
#   packages/client-runtime/src/state/providerInstanceDisplay.ts (name from id, initials, accent, account badge)

@mc
Feature: Provider instances
  A provider instance is one configured copy of a provider driver on an environment:
  its own name, account, environment variables and settings. Threads remember the
  instance they ran on, so several accounts of the same provider can live side by side.

  Background:
    Given a connected environment with the project "shop"

  Scenario: A new instance of a built-in agent keeps its own environment variables
    Given the user adds a Grok instance "grok_work" with the variable "XAI_API_KEY"
    When a thread runs on "grok_work"
    Then Grok runs with that variable set

  Scenario: Disabling a provider moves the text-generation choice to a usable provider
    Given Grok is picked for thread titles
    When the user disables Grok
    Then thread titles are written by the first usable provider with its default model

  Scenario: Refreshing provider status checks every provider again
    When the user refreshes the status of every provider
    Then each provider's account and usage are checked again

  Scenario: Refreshing models reloads every provider's model list
    When the user refreshes provider models
    Then Codex and every enabled ACP agent report their models again

  Scenario: Refreshing one provider checks only that provider
    When the user refreshes the provider "grok_work"
    Then only "grok_work" is checked again

  Scenario: Provider changes reach every client of the MC
    Given two clients are connected to the MC
    When the user enables Grok on one client
    Then the other client lists Grok as enabled

  @desktop @mobile @backlog-mobile @backlog-mc
  Scenario: Adding an instance derives its id from its label
    When the user adds a Claude instance labelled "Work"
    Then its instance id is "claudeAgent_work"

  @desktop @mobile @backlog-mobile @backlog-mc
  Scenario: A clashing instance id gets a number
    Given the instance "claudeAgent_work" exists
    When the user adds another Claude instance labelled "Work"
    Then its instance id is "claudeAgent_work_2"

  @desktop @mobile @backlog-mobile @backlog-mc
  Scenario Outline: Instance ids are validated
    When the user sets the instance id to "<id>"
    Then the user is told "<message>"

    Examples:
      | id              | message                                                                   |
      |                 | Instance ID is required.                                                  |
      | 9lives          | Instance ID must start with a letter and use only letters, digits, '-', or '_'. |
      | codex           | An instance named 'codex' already exists.                                 |

  @desktop @mobile @backlog-mobile
  Scenario: An instance can be renamed and given an accent colour
    Given the instance "claudeAgent_work"
    When the user renames it to "Work Claude" and picks a green accent
    Then the model picker shows "Work Claude" in green

  @desktop @mobile @backlog-mobile
  Scenario: Clearing the accent colour goes back to the default
    Given the instance "claudeAgent_work" has a green accent
    When the user clears the accent colour
    Then the instance uses the default colour

  # Legacy: apps/web/src/components/settings/ProviderAccentColorPicker.tsx
  @backlog @desktop
  Scenario Outline: A typed accent colour is taken only as a complete hex value
    Given the instance "claudeAgent_work" has a green accent
    When the user types "<typed>" as its accent colour
    Then the accent colour <result>

    Examples:
      | typed   | result                 |
      | #22c5   | stays green            |
      | 22c55e  | stays green            |
      | #22C55E | becomes #22c55e        |

  # Legacy: apps/web/src/components/settings/ProviderAccentColorPicker.tsx (FALLBACK_ACCENT_COLOR)
  @backlog @desktop
  Scenario: The accent chooser starts from a blue when the instance has none
    Given the instance "claudeAgent_work" has no accent colour
    When the user opens its accent colour chooser
    Then the chooser starts from blue
    And there is no way to clear a colour until one has been picked

  # Legacy: packages/client-runtime/src/state/providerInstanceDisplay.ts (resolveProviderInstanceDisplayName)
  @backlog @desktop @mobile
  Scenario Outline: An instance is named by what the MC calls it, or else by its id
    Given the instance "<id>" which the MC <naming>
    When the user sees the instance in a picker, a thread row or the settings
    Then it is shown as "<shown>"

    Examples:
      | id               | naming                                     | shown              |
      | claudeAgent_work | names "Work Claude"                        | Work Claude        |
      | codex_personal   | names only with the driver's own label     | Codex Personal     |
      | myCustomInstance | does not name                              | My Custom Instance |
      | codex            | names only with the driver's own label     | Codex              |

  # Legacy: packages/client-runtime/src/state/providerInstanceDisplay.ts (providerInstanceInitials, shouldShowInstanceBadge)
  @backlog @desktop @mobile
  Scenario Outline: An instance's icon carries a badge only where the brand alone would be ambiguous
    Given <situation>
    When the user sees the icon of the instance
    Then the icon <badge>

    Examples:
      | situation                                                                  | badge                       |
      | "Codex" is the only instance of its provider and has no accent colour       | has no badge                |
      | "Codex" and "Codex Work" are both instances of the same provider            | has a badge with initials   |
      | "Codex" is the only instance of its provider and has an accent colour       | has a badge with initials   |
      | two agents from the ACP registry that are different agents                  | have no badge               |
      | two instances of the same agent from the ACP registry                       | have a badge with initials  |

  # Legacy: packages/client-runtime/src/state/providerInstanceDisplay.ts (providerInstanceInitials, normalizeProviderAccentColor)
  @backlog @desktop @mobile
  Scenario Outline: A badge shows up to two initials of the instance's name
    Given the instance is shown as "<name>"
    When the user sees its badge
    Then the badge reads "<initials>"

    Examples:
      | name           | initials |
      | Work Claude    | WC       |
      | Personal       | PE       |
      | codex_work     | CW       |
      | Claude Code CLI | CC      |
      | 🙂 Smile       | 🙂S      |

  # Legacy: packages/client-runtime/src/state/providerInstanceDisplay.ts (normalizeProviderAccentColor)
  @backlog @desktop @mobile
  Scenario: A stored accent colour that is not a complete hex value is ignored
    Given the settings give the instance "claudeAgent_work" the accent "green"
    When the user sees the instance in a picker or a thread row
    Then it is shown in its default colour

  Scenario: Deleting a custom instance removes it
    Given the custom instance "claudeAgent_work"
    When the user deletes it
    Then it is no longer listed
    And threads that ran on it keep their history

  Scenario: A built-in provider cannot be deleted but can be reset
    Given the user changed the settings of the built-in Codex
    When the user resets Codex to its defaults
    Then Codex's settings are back to their defaults

  Scenario: An instance whose driver this MC does not have is kept and shown as unavailable
    Given the settings contain the instance "acme_work" for a driver this MC does not have
    When the user opens the provider list
    Then "acme_work" is listed as unavailable with its configuration preserved
    And sending a message on "acme_work" is refused with a clear error

  # ProviderInstanceRegistryLive.ts and ProviderInstanceRegistryHydration.ts
  @backlog
  Scenario: An instance whose configuration is invalid is unavailable and says why
    Given the settings contain a Codex instance "codex_work" whose configuration is not valid
    When the user opens the provider list
    Then "codex_work" is listed as unavailable with the reason that its configuration is invalid
    And the other instances work as before

  @backlog
  Scenario: An instance that fails to start is unavailable and says why
    Given a provider instance whose driver fails while it starts
    When the user opens the provider list
    Then the instance is listed as unavailable with the driver's failure
    And the other instances work as before

  @backlog
  Scenario: Settings from before instances still give each built-in provider an instance
    Given the settings have a Codex entry in the older per-provider shape and no Codex instance
    When the MC starts
    Then Codex is listed as an instance with those settings

  @backlog
  Scenario: An instance entry wins over the older per-provider settings
    Given the settings have both an older Codex entry and a Codex instance with other settings
    When the MC starts
    Then Codex uses the instance's settings

  @backlog
  Scenario: A settings change reaches the provider list without restarting the MC
    Given the user has the provider list open
    When the user adds a provider instance in settings
    Then the new instance appears in the provider list
    And instances the change did not touch keep running

  @backlog
  Scenario: A settings change that cannot be applied leaves the other instances working
    Given the user has the provider list open
    When settings are saved that one instance cannot start with
    Then that instance is listed as unavailable
    And later settings changes are still applied

  Scenario: Sensitive environment variables are stored separately and never sent back
    When the user adds the sensitive variable "ANTHROPIC_AUTH_TOKEN" to a Claude instance
    Then the value is stored in the MC's secrets
    And clients only see that a value is set

  Scenario: A secret variable renamed without a new value has no value
    Given the Claude instance keeps "API_KEY" as a stored secret
    When a client saves it renamed to "OPENAI_KEY" without a new value
    Then clients see "OPENAI_KEY" with no value set
    And the secret of "API_KEY" is forgotten

  Scenario: A variable with an invalid name is not saved
    When the user adds the variable "1BAD" to an instance
    Then the variables are not saved until the name is fixed

  Scenario: A variable can be removed
    Given the instance "grok_work" has the variable "XAI_API_KEY"
    When the user removes that variable
    Then Grok no longer runs with it

  @backlog @desktop @mobile
  Scenario: A client with view-only access cannot change providers
    Given the client has view-only access to the environment
    When the user opens provider settings
    Then the providers are shown but every change is unavailable
    And the user is told this session can only view them

  @desktop @backlog-mc
  Scenario: Provider settings follow the chosen device
    Given the user is connected to the environments "workstation" and "laptop"
    When the user picks "laptop" in provider settings
    Then the providers of "laptop" are shown

  @desktop @backlog-mc
  Scenario: Provider settings for a disconnected device ask the user to reconnect
    Given "laptop" is disconnected
    When the user picks "laptop" in provider settings
    Then the user is told to reconnect that device or pick another one

  # The MC honours providerHealthRefreshInterval (background_policy.ex, provider_usage_limits.ex
  # interval/0); the settings row that edits it is @backlog in settings/providers-panel.feature.
  Scenario: The background health check interval can be changed or turned off
    When the user sets the provider health check interval to 0
    Then providers are no longer checked in the background
    When the user resets the interval
    Then providers are checked on the default interval again

  @desktop @mobile @backlog-mobile @backlog-mc
  Scenario Outline: Provider status headlines
    Given a provider that is <state>
    When the user opens the provider list
    Then the provider reads "<headline>"

    Examples:
      | state                        | headline                  |
      | not checked yet              | Checking provider status  |
      | disabled                     | Disabled                  |
      | not installed                | Not found                 |
      | signed out                   | Not authenticated         |
      | failing its startup checks   | Unavailable               |
      | signed in                    | Authenticated             |

  @backlog @desktop
  Scenario Outline: A provider that works but cannot be fully verified says so
    Given a provider that is <state>
    When the user opens the provider list
    Then the provider reads "<headline>"

    Examples:
      | state                                              | headline         |
      | installed but not fully verified                   | Needs attention  |
      | ready with no way to tell whether it is signed in  | Available        |

  @backlog @desktop
  Scenario: The sign-in plan is named beside the status
    Given Codex is signed in on the "Pro" plan
    When the user opens the provider list
    Then Codex reads "Authenticated · Pro"

  @backlog @desktop
  Scenario Outline: A provider without its own message gets a plain explanation
    Given a provider that is <state> and gave no message
    When the user opens the provider instance
    Then it explains "<detail>"

    Examples:
      | state                      | detail                                                                 |
      | not checked yet            | Waiting for the server to report installation and authentication details. |
      | disabled                   | This provider is installed but disabled for new sessions in HAL-C2.    |
      | not installed              | CLI not detected on PATH.                                              |
      | failing its startup checks | The provider failed its startup checks.                                |

  @backlog @desktop
  Scenario: A problem is not hidden behind an earlier sign-in
    Given Codex was signed in and its latest check failed with "Network unreachable"
    When the user opens the provider list
    Then Codex reads "Unavailable" with "Network unreachable"
    And it is not shown as authenticated

  @backlog @desktop
  Scenario: A provider the user just turned off reads as disabled at once
    Given Codex reports as ready and the user turns it off
    When the settings change is saved but the provider has not been checked again
    Then Codex reads "Disabled"

  # The Node server persists each instance's last status under its instance id and sorts
  # built-in providers first (providerStatusCache.ts hydrateCachedProvider, orderProviderSnapshots).
  @backlog
  Scenario: Providers are listed in a stable order
    Given Codex, Claude, Cursor, Grok, OpenCode, Antigravity and a custom "acme" instance are configured
    When a client lists the providers
    Then they are listed in that order
    And a second instance of one provider follows the first by name

  @backlog
  Scenario: A restarted MC lists the last known status before it checks again
    Given Codex was checked, found installed and signed in, and the MC then restarted
    When a client lists the providers before the first new check finishes
    Then Codex is listed with its last known version, status and sign-in
    And it is checked again in the background

  @backlog
  Scenario: A last known status is not trusted for a provider that changed
    Given Codex was last checked while enabled
    And Codex is now disabled
    When the MC restarts and a client lists the providers
    Then Codex is listed as disabled and not with its old status

  @backlog
  Scenario: Another instance's last known status is not used
    Given the last known status was recorded for "codex_work"
    And "codex_work" now belongs to a different provider
    When the MC restarts and a client lists the providers
    Then "codex_work" is not listed with that status

  @backlog
  Scenario: A last known model list keeps what is still configured
    Given Codex's last known models included a custom model the user has since removed
    And a built-in model it has not reported again
    When the MC restarts and a client lists the providers
    Then the removed custom model is not listed
    And the built-in model is still listed

  @backlog
  Scenario: A damaged last known status is ignored
    Given the last known status of Codex cannot be read
    When the MC restarts and a client lists the providers
    Then Codex is listed as not checked yet
    And it is checked again in the background

  Scenario Outline: A custom binary path runs that executable
    Given the <provider> instance has the binary path "<path>"
    When a thread runs on that instance
    Then "<path>" is started for the thread

    Examples:
      | provider | path                        |
      | Grok     | /opt/grok/bin/grok          |
      | OpenCode | /opt/opencode/bin/opencode  |

  Scenario: An instance's binary path wins over the provider's
    Given Grok's provider settings name the binary path "/usr/local/bin/grok"
    And the instance "grok_work" names the binary path "/opt/grok/bin/grok"
    When a thread runs on "grok_work"
    Then "/opt/grok/bin/grok" is started for the thread

  Scenario: An empty binary path runs the provider found on the path
    Given the Grok instance has an empty binary path
    When a thread runs on that instance
    Then the "grok" executable found on the path is started

  Scenario Outline: A binary path in the user's home directory is expanded
    Given the <provider> instance has the binary path "<path>"
    When a thread runs on that instance
    Then the executable in the user's home directory is started

    Examples:
      | provider | path             |
      | Grok     | ~/bin/grok       |
      | OpenCode | ~/bin/opencode   |

  Scenario Outline: Codex and Claude run from a custom binary path
    Given the <provider> instance has the binary path "<path>"
    When a thread runs on that instance
    Then "<path>" is started for the thread
    And the provider's version and update checks read "<path>"

    Examples:
      | provider | path                    |
      | Codex    | /opt/codex/bin/codex    |
      | Claude   | /opt/claude/bin/claude  |

  Scenario Outline: A binary path with nothing at it lists the provider as not installed
    Given the <provider> instance has a binary path where nothing is installed
    When a client lists the providers
    Then <provider> is listed as not installed
    And its configured binary path is kept

    Examples:
      | provider |
      | Codex    |
      | Claude   |

  Scenario Outline: A second instance's checks read its own binary path
    Given a second <provider> instance "<instance>" with the binary path "<path>"
    When the MC checks the version, update and usage of "<instance>"
    Then each check runs "<path>"
    And none runs the default instance's executable

    Examples:
      | provider | instance    | path                        |
      | Codex    | codex_work  | /opt/codex-work/bin/codex   |
      | Claude   | claude_work | /opt/claude-work/bin/claude |
