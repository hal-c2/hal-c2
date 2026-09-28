# Sources:
#   docs/orchestration-v2/provider-capability-system.md (capability groups, degradation policies, adapter contract)
#   docs/internals/providers.md (route by instance, unknown drivers)
#   docs/user/providers-acp.md
#   apps/server-ex/lib/hal_c2/orchestration.ex (driver_for, runtime, steerable?)
#   apps/server-ex/lib/hal_c2/orchestration/turn_watch.ex (a turn whose process crashes)
#   apps/server-ex/lib/hal_c2/acp.ex (built-in ACP agents, acpRegistry driver)
#   apps/server-ex/lib/hal_c2/acp/catalog.ex, apps/server-ex/lib/hal_c2/acp/thread_runtime.ex
#   apps/server-ex/lib/hal_c2/claude/provider.ex, apps/server-ex/lib/hal_c2/codex/provider.ex
#   apps/server/src/provider/Drivers (one driver per provider)
#   packages/contracts/src/providerInstance.ts (ProviderInstanceMutation, availability unavailable)
#   packages/contracts/src/server.ts (ServerProvider capability flags)

Feature: Agent providers are plugins
  Every agent provider is a plugin. The core knows how to run a turn against the
  adapter contract and nothing about any particular agent. Claude and Codex ship as
  bundled plugins, ACP is the preferred contract for everything else, and each
  plugin declares what it can do so the core offers only what works.

  Background:
    Given a connected environment with the project "shop"

  @node
  Scenario: A registry agent can be added without changing the node
    Given the ACP registry lists the agent "acme"
    When the user adds "acme" as a provider
    Then "acme" can run turns in "shop"
    And no new node version was needed

  @node
  Scenario: A follow-up to an agent that cannot be steered waits for the turn to end
    Given a turn is running on an ACP agent
    When the user sends a follow-up message
    Then the message waits until the running turn finishes
    And it is then sent as the next turn

  @node
  Scenario: A follow-up to an agent that can be steered joins the running turn
    Given a turn is running on Codex
    When the user sends a follow-up message
    Then the message joins the running turn

  @node
  Scenario: Built-in ACP agents do nothing until the user enables them
    Given OpenCode, Grok, Cursor and Pi are installed but not enabled
    When the node starts
    Then none of their processes are started

  @node
  Scenario: The core starts with no provider plugins at all
    Given a node with no provider plugins installed
    When the node starts
    Then the node is ready
    And the user is told to add a provider before starting a thread

  @node
  Scenario: Claude and Codex are bundled plugins that can be turned off
    Given the bundled plugins "claude" and "codex"
    When the user disables the "codex" plugin
    Then Codex is not offered as a provider
    And Claude keeps working

  @node
  Scenario: A bundled provider plugin can be updated separately from the node
    Given the bundled plugin "claude" has a newer version available
    When the user updates "claude"
    Then Claude runs on the new plugin version
    And the node version is unchanged

  @node
  Scenario: A provider plugin written against the adapter contract needs no core change
    Given a provider plugin "acme-native" that implements the adapter contract directly
    When the plugin is installed and enabled
    Then "acme-native" is listed as a provider
    And it can run turns in "shop"

  # The process that calls `TurnWriter.started/1` drives the turn.
  @node
  Scenario: A plugin's turn ends as failed when the process running it crashes
    Given a provider plugin "acme-native" that implements the adapter contract directly
    And the plugin is installed and enabled
    And the plugin "acme-native" is running a turn
    When the process running that turn crashes
    Then the run fails saying the provider's session ended unexpectedly
    And the thread takes its next message

  @node
  Scenario: A turn on an instance whose plugin is missing is refused clearly
    Given a thread that used the instance "acme_work"
    And the plugin behind "acme_work" has been removed
    When the user sends a message in that thread
    Then the message is refused with a message naming the missing provider
    And no other provider runs the turn in its place

  @node
  Scenario: Removing a provider plugin leaves its threads readable
    Given threads in "shop" that ran on "acme"
    When the user removes the "acme" plugin
    Then those threads still show their full history
    And their diffs and checkpoints can still be viewed

  @node
  Scenario: The settings of a removed provider are kept for when it comes back
    Given the instance "acme_work" has custom settings
    When its plugin is removed
    Then the instance is listed as unavailable with its settings preserved
    When the plugin is installed again
    Then "acme_work" works with the same settings

  @node
  Scenario: A thread from a removed provider can continue on another provider
    Given a thread that ran on a provider whose plugin was removed
    When the user switches the thread to Claude and sends a message
    Then the turn runs on Claude with the thread's history as context

  @node
  Scenario Outline: A capability the plugin does not declare changes what the user is offered
    Given a provider plugin that does not declare "<capability>"
    When the user works in a thread on that provider
    Then <outcome>

    Examples:
      | capability          | outcome                                                                        |
      | interrupt           | the stop control is not offered while a turn runs                              |
      | active steering     | a follow-up interrupts the turn and starts again with the message             |
      | fork                | forking copies the history into a new thread and starts a fresh session       |
      | rollback            | reverting restores files and marks the agent context as divergent             |
      | structured approval | no approval prompts are shown and the plugin decides on its own               |
      | plan updates        | no task list is shown for the turn                                             |
      | model switching     | changing the model starts a new thread                                        |
      | interaction mode    | the plan mode toggle is not offered                                           |
      | text generation     | the provider cannot be picked for titles and commit messages                  |
      | native sessions     | there is nothing to import from this provider                                  |
      | usage limits        | the limits view does not list this provider                                   |
      | sign-in             | the user is pointed to the provider's documentation to sign in                |

  @node
  Scenario: A plugin that declares a capability it does not honour is reported
    Given a provider plugin that declares rollback but fails every rollback
    When the user reverts a turn on that provider
    Then the revert fails with the plugin's error
    And the thread is left as it was before the revert

  @node
  Scenario: ACP is the recommended contract for new providers
    Given a new agent that speaks ACP
    When its author publishes it to the ACP registry
    Then users can add it from the registry without a HAL-C2 plugin

  @node
  Scenario: A provider plugin can extend an ACP agent with extra behaviour
    Given a provider plugin "grok" built on the ACP contract
    And it adds a plan capture that plain ACP does not have
    When a Grok turn proposes a plan
    Then the plan is shown as a proposed plan

  @node
  Scenario: Each provider plugin runs under its own supervisor
    Given threads are running on Claude and on an ACP agent
    When the ACP agent's plugin crashes
    Then the Claude threads keep running
    And the ACP agent's threads show that their session ended

  @node
  Scenario: Provider plugins declare the settings their instances need
    Given the provider plugin "acme" declares a binary path and an API key setting
    When the user adds an "acme" instance
    Then the user is asked for a binary path and an API key

  @node
  Scenario: A provider plugin supplies its own icon, colour and name
    Given the provider plugin "acme" declares an icon and an accent colour
    When the user looks at the provider list
    Then "acme" is shown with its own icon and colour

  @node
  Scenario: Provider plugins declare which runtime modes they support
    Given the provider plugin "pi" supports every mode except auto
    When the user opens the runtime access picker for a Pi thread
    Then auto is not offered

  @node
  Scenario: A client shows a provider it has never heard of from the plugin's declaration alone
    Given the node has the provider plugin "acme" that no client knows about
    When the user opens the model picker on any client
    Then "acme" and its models are listed with the plugin's name and icon
