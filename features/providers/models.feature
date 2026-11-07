# Sources:
#   https://github.com/pingdotgg/t3code/pull/16816
#   https://github.com/pingdotgg/t3code/pull/14314
#   https://github.com/pingdotgg/t3code/pull/17307
#   https://github.com/pingdotgg/t3code/pull/16903
#   https://github.com/pingdotgg/t3code/pull/18840
#   https://github.com/pingdotgg/t3code/pull/14152 (carry: Claude Sonnet 5.5 in the catalog, @backlog)
#   apps/server-ex/lib/hal_c2/codex/provider.ex (model/list, aliases), apps/server-ex/lib/hal_c2/claude/provider.ex (the models Claude Code lists, else the manifest's Claude catalog)
#   apps/server-ex/lib/hal_c2/model_manifest.ex (bundled, fetched and cached manifest; policies)
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

@mc
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
    Given the MC has never fetched the model manifest
    When the MC starts without network access
    Then models are listed from the bundled manifest

  Scenario: A newer manifest is fetched and used
    Given a newer model manifest is published
    When the MC refreshes the manifest
    Then the newer models and defaults are offered

  Scenario: An invalid manifest download keeps the last usable manifest
    When the MC downloads a manifest that is not valid
    Then the last usable manifest is kept

  # Upstream #14152 adds Claude Sonnet 5.5. The bundled manifest does not list it yet.
  @backlog
  Scenario: The Claude catalog lists Claude Sonnet 5.5
    Given the MC uses its bundled model manifest
    When the MC has read Claude's model list
    Then "claude-sonnet-5-5" is offered in the model picker for Claude

  # Upstream #16903: Haiku 5.5 joins the current Claude models; Opus 5 and Sonnet 5 move to legacy.
  @backlog
  Scenario: The Claude catalog's current models are the 5.5 family and Fable 5.1
    Given the MC uses its bundled model manifest
    When the user opens the model picker for Claude
    Then the current models are "Fable 5.1", "Opus 5.5", "Sonnet 5.5" and "Haiku 5.5"
    And "Opus 5" and "Sonnet 5" are listed as legacy
    And the aliases "opus", "sonnet" and "haiku" pick the 5.5 models

  @backlog
  Scenario: Claude Haiku 5.5 offers reasoning effort but not fast mode
    Given the installed Claude is version 2.1.293 or newer
    When the user opens the options for "Haiku 5.5"
    Then the user can choose low, medium, high, extra high, max or ultrathink, with medium first
    And there is no fast mode

  # ClaudeModelManifest.ts hasValidClaudeManifestAdapters: the rest of the manifest being
  # sound does not save a Claude catalog whose version range or profile is malformed.
  @backlog
  Scenario Outline: A manifest with a malformed Claude catalog is refused as a whole
    When the MC downloads a manifest whose Claude catalog has <problem>
    Then the last usable manifest is kept

    Examples:
      | problem                                                  |
      | a model gated by a version that is not a semantic version |
      | a model whose minimum version is not below its maximum   |
      | a profile with a malformed effort or context window map  |

  Scenario: A bundled manifest newer than the cached one wins
    Given the MC was updated with a manifest newer than its cached copy
    When the MC starts
    Then the bundled manifest is used

  Scenario: A fetched compatibility policy replaces the bundled one for its provider only
    Given the bundled manifest has compatibility policies for OpenCode and another provider
    And a newer manifest changes only OpenCode's policy
    When the MC refreshes the manifest
    Then OpenCode's versions are judged by the fetched policy
    And the other provider keeps its bundled policy

  # Refresh rules of apps/server/src/provider/ModelManifest.ts (TTL one hour, retry five
  # minutes, ten second download limit).
  @backlog
  Scenario: The manifest is downloaded at most once an hour
    Given the MC fetched the model manifest less than an hour ago
    When the MC would refresh the manifest
    Then no download is made

  @backlog
  Scenario: A failed manifest download is retried after five minutes
    Given the MC's last manifest download failed two minutes ago
    When the MC would refresh the manifest
    Then no download is made
    When five minutes have passed since the failed download
    Then the manifest is downloaded again

  @backlog
  Scenario: A manifest download that takes too long is abandoned
    Given the manifest server does not answer within ten seconds
    When the MC refreshes the manifest
    Then the last usable manifest is kept
    And no error is shown to the user

  @backlog
  Scenario: Refreshing the manifest by hand ignores the schedule
    Given the MC fetched the model manifest a minute ago
    When the user refreshes the models
    Then the manifest is downloaded again

  @backlog
  Scenario: The manifest is not downloaded when provider update checks are off
    Given the user turned off provider update checks
    When the MC would refresh the manifest
    Then no download is made
    And the bundled or last cached manifest is used

  @backlog
  Scenario: The manifest names a provider's default model
    Given a provider reports "model-a" as its default
    And the manifest names "model-b" as that provider's default
    When the MC has read the provider's model list
    Then "model-b" is the default
    And the names that pointed at "model-a" as the default now point at "model-b"

  @backlog
  Scenario: A manifest default the provider does not offer is ignored
    Given a provider reports "model-a" as its default
    And the manifest names a default that the provider does not list
    When the MC has read the provider's model list
    Then "model-a" stays the default

  @backlog
  Scenario: Custom models are never marked legacy by the manifest
    Given the user added a custom model that the manifest does not list
    When the MC has read the provider's model list
    Then the custom model is not labelled legacy

  @backlog
  Scenario: A Codex model is judged by its family
    Given the manifest lists "gpt-6-astra" as a current Codex model
    And Codex reports a dated variant of "gpt-6-astra"
    When the MC has read the Codex model list
    Then the variant is not labelled legacy

  @backlog @mc
  Scenario: A model the manifest does not know yet stays with the current models
    Given Codex reports a new model that the manifest does not list
    When the MC has read the Codex model list
    Then the new model is offered with the current models, not under legacy
    And only models the manifest marks as legacy are labelled legacy

  @backlog @mc @shared
  Scenario: The model picker says which CLI update unlocks a new model
    Given the manifest lists a current Codex model that needs Codex "0.140.0" or newer
    And the installed Codex is older and does not offer it
    When the user opens the model picker for Codex
    Then the model is not offered
    And the picker says to update Codex to v0.140.0 or newer to use it, with a way to the provider's settings

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

  # Every provider that takes custom models; Antigravity has none.
  @backlog
  Scenario: A named custom model with a built-in's id renames the built-in
    When the settings for Codex are saved with the custom model "gpt-5.5" named "Team GPT"
    Then Codex's models list "gpt-5.5" once, still built in, named "Team GPT"
    And no client shows its old short name

  Scenario: A custom model can have its own options
    When the user gives the custom model "my-model" a reasoning choice of low or high with high as default
    Then the composer offers low and high for "my-model" with high selected

  Scenario: A Codex custom model without options of its own takes Codex's options
    Given Codex's models offer reasoning levels
    When the user adds the custom model "my-model" to Codex
    Then "my-model" offers the same options as Codex's own models

  Scenario: A custom model's options can be copied from a built-in model
    When the user copies the options of a built-in Claude model into "my-model"
    Then "my-model" offers the same options

  @backlog
  Scenario: Removing a custom model also removes it from favourites
    Given "my-model" is a favourite
    When the user removes the custom model "my-model"
    Then it is no longer offered or listed as a favourite

  @desktop @mobile @backlog-mobile @backlog-mc
  Scenario: Favourite, hidden and ordered models are remembered on the device
    When the user favourites one model, hides another and moves a third up
    Then the model picker on this device reflects those choices
    And other devices keep their own choices

  @desktop @mobile @backlog-mobile @backlog-mc
  Scenario: A hidden model can be shown again
    Given the user hid the model "Haiku"
    When the user shows "Haiku" in the picker again
    Then "Haiku" is offered in the model picker

  # Upstream #16816 moves favourites and hidden models from each device onto the environment;
  # the per-device scenario above stays true for the desktop until the MC keeps them.
  @backlog @mc @shared
  Scenario: Favourite and hidden models follow the environment to every client
    Given the desktop and the phone are connected to the same environment
    When the user favourites "Opus" and hides "Haiku" on the desktop
    Then the phone's model picker lists "Opus" as a favourite and leaves "Haiku" out, without reloading
    When the user shows "Haiku" again on the phone
    Then the desktop offers "Haiku" again

  @backlog @mc
  Scenario: Model preferences saved on a device move to the environment once
    Given a client kept favourite and hidden models on its device before the environment kept them
    When it connects to an environment that keeps none yet
    Then the environment takes the device's favourites and hidden models
    And a list the user cleared stays cleared

  @backlog @mc
  Scenario: Changes to model preferences from two clients do not undo each other
    Given the desktop favourites "Opus" while the phone hides "Haiku" at the same time
    Then the environment keeps "Opus" as a favourite and "Haiku" hidden

  @backlog @mobile
  Scenario: The phone can hide and restore models
    When the user opens "Manage hidden models" from the phone's model picker
    Then the user can hide a model and restore a hidden one

  @backlog @mc
  Scenario: Hidden models are left out of the models agents delegate to
    Given the user hid "Haiku" and added the custom model "my-model"
    When an agent asks the MC for its orchestrator capabilities
    Then "Haiku" is not listed and "my-model" is

  Scenario: A project can have its own default model
    Given the project "shop" defaults to "Opus"
    When the user starts a new thread in "shop"
    Then the thread uses "Opus"

  Scenario: Old model names still resolve
    Given a thread saved with an older alias of a Codex model
    When the user opens the thread
    Then the thread shows the current name of that model

  Scenario: A provider that needs a new thread to change models says so
    Given a provider that cannot change models inside a thread
    When the user picks another model in an existing thread
    Then the user is offered to start a new thread with that model
