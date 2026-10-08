# Sources:
#   apps/server-ex/lib/hal_c2/hot.ex (live module reload, code_change, lingering modules)
#   apps/server-ex/lib/hal_c2/upgrade.ex (server.updateServer, in-place vs restart, outcome.json)
#   apps/server-ex/lib/hal_c2/orchestration.ex (driver_for, runtime: provider routing)
#   apps/server-ex/lib/hal_c2/acp.ex (built-in agents, providerInstances, instances off until enabled)
#   apps/server-ex/lib/hal_c2/mcp.ex (HAL-C2 MCP server)
#   apps/server-ex/lib/hal_c2/text_generation.ex (text generation backends by instance)
#   apps/server-ex/lib/hal_c2/settings.ex (providerInstances, provider_enabled?)
#   apps/server-ex/lib/hal_c2/pull_requests.ex, apps/server-ex/lib/hal_c2/vcs.ex (git hosts)
#   docs/orchestration-v2/provider-capability-system.md (adapter contract)
#   docs/internals/providers.md (route by instance, setup never as a health-check side effect)

Feature: MC plugins
  An MC's extension points are Elixir behaviours. Provider adapters, MCP tool packs,
  git hosts, notification channels and text-generation backends are modules that
  implement one of them. The MC discovers them in a plugins directory, runs each
  under its own supervisor, and lets the user turn each one on or off per environment.

  Background:
    Given an MC with a plugins directory

  @mc
  Scenario Outline: The MC discovers each kind of plugin from its plugins directory
    Given the plugins directory contains a <kind> plugin named "<name>"
    When the MC starts
    Then "<name>" is listed as an installed <kind> plugin

    Examples:
      | kind                    | name           |
      | provider adapter        | acme-agent     |
      | MCP tool pack           | jira-tools     |
      | git host                | gitea          |
      | notification channel    | ntfy           |
      | text-generation backend | local-llama    |

  @mc
  Scenario: A module that implements no known behaviour is ignored with a warning
    Given the plugins directory contains a module that implements no plugin behaviour
    When the MC starts
    Then the MC logs that the module is not a plugin
    And it is not listed as a plugin

  @mc
  Scenario: A plugin that fails to load does not stop the MC
    Given the plugins directory contains "broken" whose code does not load
    When the MC starts
    Then the MC is ready
    And "broken" is listed with its load error

  @mc
  Scenario: A newly discovered plugin is off until the user enables it
    Given the plugins directory gains the plugin "gitea"
    When the MC rescans its plugins
    Then "gitea" is listed as disabled

  @mc
  Scenario: A plugin put in the directory is found when the MC loads new code in place
    Given the plugins directory gains the plugin "gitea"
    When a developer hot-updates the MC
    Then "gitea" is listed as disabled

  @mc
  Scenario: Enabling a plugin starts it for that environment only
    Given two environments each have the plugin "ntfy" installed
    When the user enables "ntfy" on the first environment
    Then "ntfy" runs on the first environment
    And "ntfy" stays disabled on the second environment

  @mc
  Scenario: Disabling a plugin stops it and removes what it contributed
    Given the MCP tool pack "jira-tools" is enabled
    When the user disables "jira-tools"
    Then its tools are no longer offered to agents in new turns
    And its settings are kept for when it is enabled again

  @mc
  Scenario: Re-enabling a plugin restores it with its saved settings
    Given the user disabled "jira-tools" after setting its site URL
    When the user enables "jira-tools"
    Then its tools are offered again with the same site URL

  @mc
  Scenario: The enabled set survives an MC restart
    Given the user enabled "gitea" and disabled "ntfy"
    When the MC restarts
    Then "gitea" is enabled and "ntfy" is disabled

  @mc
  Scenario: A plugin built for an incompatible MC version is refused
    Given the plugin "old-host" declares that it needs an older plugin API
    When the MC starts
    Then "old-host" is listed as incompatible with the version it needs
    And it is not started

  @mc
  Scenario: A plugin that needs a newer MC asks the user to update the MC
    Given the plugin "future-tools" needs a newer plugin API than the MC offers
    When the user tries to enable "future-tools"
    Then the user is told to update the MC first

  @mc
  Scenario: A crashing plugin is restarted without touching the rest of the MC
    Given the notification channel "ntfy" is enabled
    When "ntfy" crashes
    Then its supervisor restarts it
    And running threads and other plugins are unaffected

  @mc
  Scenario: A plugin that keeps crashing is stopped and reported
    Given "ntfy" crashes repeatedly within a short time
    When its restart limit is reached
    Then "ntfy" is stopped and listed as failed with its last error
    And the MC keeps running

  @mc
  Scenario: A failed plugin can be restarted by the user
    Given "ntfy" is listed as failed
    When the user restarts "ntfy"
    Then "ntfy" runs again

  @mc
  Scenario: Each plugin has its own settings, validated by the plugin
    Given the git host "gitea" asks for a base URL and a token
    When the user saves a base URL that is not a URL
    Then the save is refused with the plugin's message
    And the previous settings are kept

  @mc
  Scenario: Secret plugin settings are stored separately and never sent back to clients
    When the user saves a token for "gitea"
    Then the token is stored in the MC's secrets
    And clients only see that a token is set

  @mc
  Scenario: Plugin settings reach every client of the MC
    Given two clients are connected to the same environment
    When the user changes a setting of "gitea" on the first client
    Then the second client shows the new setting

  @mc
  Scenario: A hot upgrade that only changes code keeps provider sessions running
    Given a thread has a running provider session
    When the MC installs a version whose changes need no restart
    Then the new code is loaded in place
    And the provider session and client connections stay up

  @mc
  Scenario: An upgrade that changes the supervision tree restarts the MC
    When the MC installs a version that changes a supervisor
    Then the MC restarts on the new version
    And the outcome of the update is reported when it is ready again

  @mc
  Scenario: A hot upgrade reloads changed plugins in place
    Given the plugin "ntfy" is enabled
    When a new version of "ntfy" is placed in the plugins directory and the MC reloads
    Then "ntfy" runs the new version without an MC restart
    And plugins that did not change keep running untouched

  @mc
  Scenario: A plugin whose new version fails to load keeps running the old one
    Given the plugin "ntfy" is enabled
    When a new version of "ntfy" that fails to load is placed in the plugins directory
    Then the MC keeps running the old version of "ntfy"
    And the failed reload is reported

  @mc
  Scenario: Removing a plugin from the directory stops it on the next scan
    Given the plugin "gitea" is enabled
    When "gitea" is removed from the plugins directory and the MC rescans
    Then "gitea" is stopped and no longer listed

  @mc
  Scenario: A git host plugin adds a remote the source control features understand
    Given the git host plugin "gitea" is enabled with a base URL
    And a project whose remote is on that host
    When the user opens the pull requests for the project
    Then the pull requests come from "gitea"

  @mc
  Scenario: A notification channel plugin receives the MC's notifications
    Given the notification channel "ntfy" is enabled
    When a turn finishes while no client is focused on the thread
    Then "ntfy" delivers the notification

  @mc
  Scenario: A text-generation backend plugin can write titles and commit messages
    Given the text-generation backend "local-llama" is enabled
    And the user picks "local-llama" for text generation
    When a thread needs a title
    Then "local-llama" writes the title

  @mc
  Scenario: An MCP tool pack is offered to agents next to the built-in HAL-C2 tools
    Given the MCP tool pack "jira-tools" is enabled
    When an agent starts a turn in a project that allows MCP
    Then the agent can call the "jira-tools" tools

  @mc
  Scenario: A project that turns off MCP gets no tool pack tools either
    Given the MCP tool pack "jira-tools" is enabled
    And the project has MCP turned off
    When an agent starts a turn in that project
    Then no "jira-tools" tools are offered

  @mc
  Scenario: Every MC in a cluster reports its own plugins
    Given two MCs are connected in a cluster
    And only the second MC has the plugin "gitea"
    When the user lists plugins for each environment
    Then "gitea" is listed for the second environment only
