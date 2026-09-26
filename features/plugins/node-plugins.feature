# Sources:
#   apps/server-ex/lib/hal_c2/hot.ex (live module reload, code_change, lingering modules)
#   apps/server-ex/lib/hal_c2/upgrade.ex (server.updateServer, in-place vs restart, outcome.json)
#   apps/server-ex/lib/hal_c2/orchestration.ex (driver_for, runtime: provider routing)
#   apps/server-ex/lib/hal_c2/acp.ex (built-in agents, providerInstances, instances off until enabled)
#   apps/server-ex/lib/hal_c2/mcp.ex (hal-c2 MCP server)
#   apps/server-ex/lib/hal_c2/text_generation.ex (text generation backends by instance)
#   apps/server-ex/lib/hal_c2/settings.ex (providerInstances, provider_enabled?)
#   apps/server-ex/lib/hal_c2/pull_requests.ex, apps/server-ex/lib/hal_c2/vcs.ex (git hosts)
#   docs/orchestration-v2/provider-capability-system.md (adapter contract)
#   docs/internals/providers.md (route by instance, setup never as a health-check side effect)

Feature: Node plugins
  A node's extension points are Elixir behaviours. Provider adapters, MCP tool packs,
  git hosts, notification channels and text-generation backends are modules that
  implement one of them. The node discovers them in a plugins directory, runs each
  under its own supervisor, and lets the user turn each one on or off per environment.

  Background:
    Given a node with a plugins directory

  @node
  Scenario Outline: The node discovers each kind of plugin from its plugins directory
    Given the plugins directory contains a <kind> plugin named "<name>"
    When the node starts
    Then "<name>" is listed as an installed <kind> plugin

    Examples:
      | kind                    | name           |
      | provider adapter        | acme-agent     |
      | MCP tool pack           | jira-tools     |
      | git host                | gitea          |
      | notification channel    | ntfy           |
      | text-generation backend | local-llama    |

  @node
  Scenario: A module that implements no known behaviour is ignored with a warning
    Given the plugins directory contains a module that implements no plugin behaviour
    When the node starts
    Then the node logs that the module is not a plugin
    And it is not listed as a plugin

  @node
  Scenario: A plugin that fails to load does not stop the node
    Given the plugins directory contains "broken" whose code does not load
    When the node starts
    Then the node is ready
    And "broken" is listed with its load error

  @node
  Scenario: A newly discovered plugin is off until the user enables it
    Given the plugins directory gains the plugin "gitea"
    When the node rescans its plugins
    Then "gitea" is listed as disabled

  @node
  Scenario: Enabling a plugin starts it for that environment only
    Given two environments each have the plugin "ntfy" installed
    When the user enables "ntfy" on the first environment
    Then "ntfy" runs on the first environment
    And "ntfy" stays disabled on the second environment

  @node
  Scenario: Disabling a plugin stops it and removes what it contributed
    Given the MCP tool pack "jira-tools" is enabled
    When the user disables "jira-tools"
    Then its tools are no longer offered to agents in new turns
    And its settings are kept for when it is enabled again

  @node
  Scenario: Re-enabling a plugin restores it with its saved settings
    Given the user disabled "jira-tools" after setting its site URL
    When the user enables "jira-tools"
    Then its tools are offered again with the same site URL

  @node
  Scenario: The enabled set survives a node restart
    Given the user enabled "gitea" and disabled "ntfy"
    When the node restarts
    Then "gitea" is enabled and "ntfy" is disabled

  @node
  Scenario: A plugin built for an incompatible node version is refused
    Given the plugin "old-host" declares that it needs an older plugin API
    When the node starts
    Then "old-host" is listed as incompatible with the version it needs
    And it is not started

  @node
  Scenario: A plugin that needs a newer node asks the user to update the node
    Given the plugin "future-tools" needs a newer plugin API than the node offers
    When the user tries to enable "future-tools"
    Then the user is told to update the node first

  @node
  Scenario: A crashing plugin is restarted without touching the rest of the node
    Given the notification channel "ntfy" is enabled
    When "ntfy" crashes
    Then its supervisor restarts it
    And running threads and other plugins are unaffected

  @node
  Scenario: A plugin that keeps crashing is stopped and reported
    Given "ntfy" crashes repeatedly within a short time
    When its restart limit is reached
    Then "ntfy" is stopped and listed as failed with its last error
    And the node keeps running

  @node
  Scenario: A failed plugin can be restarted by the user
    Given "ntfy" is listed as failed
    When the user restarts "ntfy"
    Then "ntfy" runs again

  @node
  Scenario: Each plugin has its own settings, validated by the plugin
    Given the git host "gitea" asks for a base URL and a token
    When the user saves a base URL that is not a URL
    Then the save is refused with the plugin's message
    And the previous settings are kept

  @node
  Scenario: Secret plugin settings are stored separately and never sent back to clients
    When the user saves a token for "gitea"
    Then the token is stored in the node's secrets
    And clients only see that a token is set

  @node
  Scenario: Plugin settings reach every client of the node
    Given two clients are connected to the same environment
    When the user changes a setting of "gitea" on the first client
    Then the second client shows the new setting

  @node
  Scenario: A hot upgrade that only changes code keeps provider sessions running
    Given a thread has a running provider session
    When the node installs a version whose changes need no restart
    Then the new code is loaded in place
    And the provider session and client connections stay up

  @node
  Scenario: An upgrade that changes the supervision tree restarts the node
    When the node installs a version that changes a supervisor
    Then the node restarts on the new version
    And the outcome of the update is reported when it is ready again

  @node
  Scenario: A hot upgrade reloads changed plugins in place
    Given the plugin "ntfy" is enabled
    When a new version of "ntfy" is placed in the plugins directory and the node reloads
    Then "ntfy" runs the new version without a node restart
    And plugins that did not change keep running untouched

  @node
  Scenario: A plugin whose new version fails to load keeps running the old one
    Given the plugin "ntfy" is enabled
    When a new version of "ntfy" that fails to load is placed in the plugins directory
    Then the node keeps running the old version of "ntfy"
    And the failed reload is reported

  @node
  Scenario: Removing a plugin from the directory stops it on the next scan
    Given the plugin "gitea" is enabled
    When "gitea" is removed from the plugins directory and the node rescans
    Then "gitea" is stopped and no longer listed

  @node
  Scenario: A git host plugin adds a remote the source control features understand
    Given the git host plugin "gitea" is enabled with a base URL
    And a project whose remote is on that host
    When the user opens the pull requests for the project
    Then the pull requests come from "gitea"

  @node
  Scenario: A notification channel plugin receives the node's notifications
    Given the notification channel "ntfy" is enabled
    When a turn finishes while no client is focused on the thread
    Then "ntfy" delivers the notification

  @node
  Scenario: A text-generation backend plugin can write titles and commit messages
    Given the text-generation backend "local-llama" is enabled
    And the user picks "local-llama" for text generation
    When a thread needs a title
    Then "local-llama" writes the title

  @node
  Scenario: An MCP tool pack is offered to agents next to the built-in HAL-C2 tools
    Given the MCP tool pack "jira-tools" is enabled
    When an agent starts a turn in a project that allows MCP
    Then the agent can call the "jira-tools" tools

  @node
  Scenario: A project that turns off MCP gets no tool pack tools either
    Given the MCP tool pack "jira-tools" is enabled
    And the project has MCP turned off
    When an agent starts a turn in that project
    Then no "jira-tools" tools are offered

  @node
  Scenario: Every node in a cluster reports its own plugins
    Given two nodes are connected in a cluster
    And only the second node has the plugin "gitea"
    When the user lists plugins for each environment
    Then "gitea" is listed for the second environment only
