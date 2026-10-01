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
#   packages/contracts/src/providerInstance.ts (ProviderInstanceMutation, availability)
#   packages/contracts/src/settings.ts (provider instance settings, environment variables, binaryPath)
#   packages/contracts/src/rpc.ts (server.refreshProviders)
#   apps/desktop-qt/src/native/ProviderSettingsInstances.cpp (rename, accent), ComposerModel.cpp (the picker's name and colour)

@node
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

  Scenario: Provider changes reach every client of the node
    Given two clients are connected to the node
    When the user enables Grok on one client
    Then the other client lists Grok as enabled

  @backlog @desktop @mobile
  Scenario: Adding an instance derives its id from its label
    When the user adds a Claude instance labelled "Work"
    Then its instance id is "claudeAgent_work"

  @backlog @desktop @mobile
  Scenario: A clashing instance id gets a number
    Given the instance "claudeAgent_work" exists
    When the user adds another Claude instance labelled "Work"
    Then its instance id is "claudeAgent_work_2"

  @backlog @desktop @mobile
  Scenario Outline: Instance ids are validated
    When the user sets the instance id to "<id>"
    Then the user is told "<message>"

    Examples:
      | id              | message                                                                   |
      |                 | Instance ID is required.                                                  |
      | 9lives          | Instance ID must start with a letter and use only letters, digits, '-', or '_'. |
      | codex           | An instance named 'codex' already exists.                                 |

  @desktop @mobile @backlog-mobile @backlog-node
  Scenario: An instance can be renamed and given an accent colour
    Given the instance "claudeAgent_work"
    When the user renames it to "Work Claude" and picks a green accent
    Then the model picker shows "Work Claude" in green

  @desktop @mobile @backlog-mobile @backlog-node
  Scenario: Clearing the accent colour goes back to the default
    Given the instance "claudeAgent_work" has a green accent
    When the user clears the accent colour
    Then the instance uses the default colour

  @backlog
  Scenario: Deleting a custom instance removes it
    Given the custom instance "claudeAgent_work"
    When the user deletes it
    Then it is no longer listed
    And threads that ran on it keep their history

  Scenario: A built-in provider cannot be deleted but can be reset
    Given the user changed the settings of the built-in Codex
    When the user resets Codex to its defaults
    Then Codex's settings are back to their defaults

  # Today apps/server-ex orchestration.ex driver_for/1 runs any unknown non-ACP instance on the
  # Codex runtime instead of refusing the turn.
  @backlog
  Scenario: An instance whose driver this node does not have is kept and shown as unavailable
    Given the settings contain the instance "acme_work" for a driver this node does not have
    When the user opens the provider list
    Then "acme_work" is listed as unavailable with its configuration preserved
    And sending a message on "acme_work" is refused with a clear error

  Scenario: Sensitive environment variables are stored separately and never sent back
    When the user adds the sensitive variable "ANTHROPIC_AUTH_TOKEN" to a Claude instance
    Then the value is stored in the node's secrets
    And clients only see that a value is set

  Scenario: A secret variable renamed without a new value has no value
    Given the Claude instance keeps "API_KEY" as a stored secret
    When a client saves it renamed to "OPENAI_KEY" without a new value
    Then clients see "OPENAI_KEY" with no value set
    And the secret of "API_KEY" is forgotten

  @backlog
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

  @backlog @desktop
  Scenario: Provider settings follow the chosen device
    Given the user is connected to the environments "workstation" and "laptop"
    When the user picks "laptop" in provider settings
    Then the providers of "laptop" are shown

  @backlog @desktop
  Scenario: Provider settings for a disconnected device ask the user to reconnect
    Given "laptop" is disconnected
    When the user picks "laptop" in provider settings
    Then the user is told to reconnect that device or pick another one

  # The node honours providerHealthRefreshInterval (background_policy.ex, provider_usage_limits.ex
  # interval/0); the settings row that edits it is @backlog in settings/providers-panel.feature.
  Scenario: The background health check interval can be changed or turned off
    When the user sets the provider health check interval to 0
    Then providers are no longer checked in the background
    When the user resets the interval
    Then providers are checked on the default interval again

  @backlog @desktop @mobile
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

  @backlog
  Scenario Outline: A binary path with nothing at it lists the provider as not installed
    Given the <provider> instance has a binary path where nothing is installed
    When a client lists the providers
    Then <provider> is listed as not installed
    And its configured binary path is kept

    Examples:
      | provider |
      | Codex    |
      | Claude   |

  @backlog
  Scenario Outline: A second instance's checks read its own binary path
    Given a second <provider> instance "<instance>" with the binary path "<path>"
    When the node checks the version, update and usage of "<instance>"
    Then each check runs "<path>"
    And none runs the default instance's executable

    Examples:
      | provider | instance    | path                        |
      | Codex    | codex_work  | /opt/codex-work/bin/codex   |
      | Claude   | claude_work | /opt/claude-work/bin/claude |
