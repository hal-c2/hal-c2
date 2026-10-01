# Sources:
#   apps/server-ex/lib/hal_c2/codex/provider.ex (model/list), apps/server-ex/lib/hal_c2/claude/provider.ex (the bundled manifest's Claude catalog)
#   apps/server-ex/lib/hal_c2/acp.ex (models from the model config option, subProvider)
#   apps/server-ex/lib/hal_c2/settings.ex (textGenerationModelSelection, defaultModelSelection dropped for disabled providers)
#   apps/server-ex/lib/hal_c2/text_generation.ex (defaults and fallback)
#   apps/tui/src/models.ts (flat model picker, effort choices)
#   apps/server/src/provider/ModelManifest.ts, apps/server-ex/priv/model-manifest.json
#   apps/server/src/provider/providerCompatibility.ts (applyProviderCompatibility: remote policy over bundled)
#   apps/web/src/components/settings/ProviderModelsSection.tsx, apps/web/src/components/settings/CustomModelEditor.tsx
#   apps/web/src/components/settings/customModelEditor.logic.ts
#   packages/contracts/src/model.ts (ModelSelection, CustomModelEntry, defaults, aliases)
#   packages/contracts/src/server.ts (ServerProvider models, optionDescriptors)

@node
Feature: Models
  Each provider reports the models it can run. The user picks a model and its options
  per thread, can set defaults, and can add model ids the provider does not list.

  Background:
    Given a connected environment with the project "shop"

  @tui
  Scenario: The TUI model picker lists the models of every enabled provider
    Given Codex and Claude are enabled and Grok is disabled
    When the user opens the model picker in the TUI
    Then Codex and Claude models are listed with their provider names
    And no Grok model is listed

  @tui
  Scenario: The TUI offers the reasoning choices of the selected model
    Given the selected model offers reasoning levels
    When the user opens the effort picker in the TUI
    Then the model's reasoning levels are offered

  Scenario: Models behind an upstream provider name that provider
    Given OpenCode reports the model "Anthropic/Claude Sonnet"
    When the client lists OpenCode's models
    Then "Claude Sonnet" is reported as served by "Anthropic"

  Scenario: A project's default model on a disabled provider falls back to the environment's
    Given the environment defaults to a Codex model
    And the project "shop" defaults to a Grok model
    When the user disables Grok
    Then new threads in "shop" default to the Codex model

  Scenario: Thread titles use the text-generation model with low reasoning by default
    Given the user has not picked a text-generation model
    When a new thread needs a title
    Then Codex writes it with its text-generation model at low reasoning

  Scenario: A text-generation model on an unusable provider falls back
    Given the text-generation model is on Claude and Claude is not installed
    When a new thread needs a title
    Then the first usable provider writes it with its default model

  Scenario: The source control writer model writes commit messages
    Given the project's commit writer model is on Claude
    When a commit needs a message
    Then Claude writes the commit message

  Scenario: The bundled model manifest works offline
    Given the node has never fetched the model manifest
    When the node starts without network access
    Then models are listed from the bundled manifest

  @backlog
  Scenario: A newer manifest is fetched and used
    Given a newer model manifest is published
    When the node refreshes the manifest
    Then the newer models and defaults are offered

  @backlog
  Scenario: An invalid manifest download keeps the last usable manifest
    When the node downloads a manifest that is not valid
    Then the last usable manifest is kept

  @backlog
  Scenario: A bundled manifest newer than the cached one wins
    Given the node was updated with a manifest newer than its cached copy
    When the node starts
    Then the bundled manifest is used

  @backlog
  Scenario: A fetched compatibility policy replaces the bundled one for its provider only
    Given the bundled manifest has compatibility policies for OpenCode and another provider
    And a newer manifest changes only OpenCode's policy
    When the node refreshes the manifest
    Then OpenCode's versions are judged by the fetched policy
    And the other provider keeps its bundled policy

  Scenario: Adding a custom model
    When the user adds the custom model "my-model" to Claude
    Then "my-model" is offered in the model picker for Claude
    And it is saved on the environment

  # The desktop saves an instance's settings in its providerInstances entry, Claude's own too.
  Scenario: A custom model saved on Claude's own instance is offered
    When the user adds the custom model "my-model" to Claude's own instance
    Then "my-model" is offered in the model picker for Claude

  # The settings panel tells the user what is wrong with an id (settings/providers-panel.feature).
  # The backend keeps the model list sound whatever reaches the settings.
  Scenario Outline: A custom model id that cannot be used does not spoil the model list
    When the settings for Claude are saved with <saved>
    Then Claude's models have <listed>

    Examples:
      | saved                                     | listed                                  |
      | an empty custom model id                  | no model with an empty id               |
      | the built-in "claude-haiku-4-5" as custom | "claude-haiku-4-5" once, still built in |
      | the custom model "my-model" twice         | "my-model" once                         |

  Scenario: A custom model can have its own options
    When the user gives the custom model "my-model" a reasoning choice of low or high with high as default
    Then the composer offers low and high for "my-model" with high selected

  Scenario: A Codex custom model without options of its own takes Codex's options
    Given Codex's models offer reasoning levels
    When the user adds the custom model "my-model" to Codex
    Then "my-model" offers the same options as Codex's own models

  @backlog
  Scenario: A custom model's options can be copied from a built-in model
    When the user copies the options of a built-in Claude model into "my-model"
    Then "my-model" offers the same options

  @backlog
  Scenario: Removing a custom model also removes it from favourites
    Given "my-model" is a favourite
    When the user removes the custom model "my-model"
    Then it is no longer offered or listed as a favourite

  @backlog @desktop @mobile
  Scenario: Favourite, hidden and ordered models are remembered on the device
    When the user favourites one model, hides another and moves a third up
    Then the model picker on this device reflects those choices
    And other devices keep their own choices

  @backlog @desktop @mobile
  Scenario: A hidden model can be shown again
    Given the user hid the model "Haiku"
    When the user shows "Haiku" in the picker again
    Then "Haiku" is offered in the model picker

  Scenario: A project can have its own default model
    Given the project "shop" defaults to "Opus"
    When the user starts a new thread in "shop"
    Then the thread uses "Opus"

  @backlog
  Scenario: Old model names still resolve
    Given a thread saved with an older alias of a Codex model
    When the user opens the thread
    Then the thread shows the current name of that model

  @backlog
  Scenario: A provider that needs a new thread to change models says so
    Given a provider that cannot change models inside a thread
    When the user picks another model in an existing thread
    Then the user is offered to start a new thread with that model
