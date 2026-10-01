defmodule HalC2.Steps.Providers.Models do
  @moduledoc """
  Steps for `features/providers/models.feature`: the models each provider reports, the
  defaults a new thread and text generation start from, and how they fall back.
  Providers run on the test fakes (`HalC2.Test.Node.World.fake_providers/2`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node.World

  # --- the TUI's pickers (they flatten the node's provider list, `apps/tui/src/models.ts`) ---

  step "Codex and Claude are enabled and Grok is disabled", context do
    context = World.fake_providers(context)
    World.merge_settings(%{"providers" => %{"grok" => %{"enabled" => false}}})
    context
  end

  step "the user opens the model picker in the TUI", context do
    {providers, context} = World.provider_list(context)
    Map.put(context, :model_options, flatten(providers))
  end

  step "Codex and Claude models are listed with their provider names", context do
    for instance <- ~w(codex claudeAgent) do
      options = Enum.filter(context.model_options, &(&1.instance == instance))
      assert options != [], "no #{instance} model in #{inspect(context.model_options)}"
      assert Enum.all?(options, &(&1.provider_label == instance and &1.label != ""))
    end

    context
  end

  step "no Grok model is listed", context do
    refute Enum.any?(context.model_options, &(&1.instance == "grok"))
    context
  end

  step "the selected model offers reasoning levels", context do
    System.put_env(
      "FAKE_CODEX_MODELS",
      JSON.encode!([
        %{
          "model" => "gpt-6-luna",
          "displayName" => "GPT-6 Luna",
          "isDefault" => true,
          "defaultReasoningEffort" => "medium",
          "supportedReasoningEfforts" =>
            for(effort <- ~w(low medium high), do: %{"reasoningEffort" => effort})
        }
      ])
    )

    context = World.fake_providers(context)
    HalC2.Codex.Provider.load()
    Map.put(context, :selection, %{"instanceId" => "codex", "model" => "gpt-6-luna"})
  end

  step "the user opens the effort picker in the TUI", context do
    %{"models" => models} = World.provider(context, "codex")
    model = Enum.find(models, &(&1["slug"] == context.selection["model"]))
    descriptors = get_in(model, ["capabilities", "optionDescriptors"]) || []
    # The TUI offers the reasoning select, else the model's first select.
    Map.put(context, :effort_picker, Enum.find(descriptors, &(&1["type"] == "select")))
  end

  step "the model's reasoning levels are offered", context do
    picker = context.effort_picker || flunk("the model offers no reasoning choice")
    assert picker["id"] == "reasoningEffort"

    assert Enum.map(picker["options"], &{&1["id"], &1["label"]}) ==
             [{"low", "Low"}, {"medium", "Medium"}, {"high", "High"}]

    assert picker["currentValue"] == "medium"
    context
  end

  # --- models the providers report --------------------------------------------------------

  step "OpenCode reports the model {string}", %{args: [name]} = context do
    System.put_env("FAKE_ACP_MODELS", JSON.encode!([name]))
    context = World.fake_providers(context)
    World.merge_settings(%{"providers" => %{"opencode" => %{"enabled" => true}}})
    HalC2.Acp.reload("opencode")
    context
  end

  step "the client lists OpenCode's models", context do
    %{"models" => models} = World.provider(context, "opencode")
    Map.put(context, :models, models)
  end

  step "{string} is reported as served by {string}", %{args: [name, sub]} = context do
    assert %{"subProvider" => ^sub} = Enum.find(context.models, &(&1["name"] == name)),
           "no #{inspect(name)} in #{inspect(context.models)}"

    context
  end

  # --- defaults -----------------------------------------------------------------------------

  step "the environment defaults to a Codex model", context do
    World.merge_settings(%{"defaultModelSelection" => codex_default()})
    context
  end

  step "the project {string} defaults to a Grok model", %{args: [project]} = context do
    World.merge_settings(%{"providers" => %{"grok" => %{"enabled" => true}}})
    selection = %{"instanceId" => "grok", "model" => "grok-build"}
    override(context, project, %{"defaultModelSelection" => selection})
    assert project_settings(context, project)["defaultModelSelection"] == selection
    context
  end

  step "new threads in {string} default to the Codex model", %{args: [project]} = context do
    assert project_settings(context, project)["defaultModelSelection"] == codex_default()
    context
  end

  step "the project {string} defaults to {string}", %{args: [project, name]} = context do
    context = World.fake_providers(context)
    %{"models" => models} = World.provider(context, "claudeAgent")
    model = Enum.find(models, &(&1["name"] =~ name)) || flunk("Claude has no #{name}")

    override(context, project, %{
      "defaultModelSelection" => %{"instanceId" => "claudeAgent", "model" => model["slug"]}
    })

    context
  end

  step "the thread uses {string}", %{args: [name]} = context do
    title = World.current_thread(context)
    id = World.thread_id(context, title)
    row = World.await_row(id, &(&1["modelSelection"] != nil))
    %{"instanceId" => instance, "model" => slug} = row["modelSelection"]
    %{"models" => models} = World.provider(context, instance)
    assert Enum.find(models, &(&1["slug"] == slug))["name"] =~ name
    context
  end

  # --- text generation ----------------------------------------------------------------------

  step "the user has not picked a text-generation model", context do
    context = World.text_writers(context, [:codex])
    {settings, _} = HalC2.Settings.get()
    refute settings["textGenerationModelSelection"]
    context
  end

  step "Codex writes it with its text-generation model at low reasoning", context do
    assert {:ok, %{"title" => _}} = context.title_result
    assert [%{"argv" => argv}] = World.text_calls(context)
    pairs = Enum.chunk_every(argv, 2, 1)
    assert ["--model", "gpt-6-luna"] in pairs
    assert ["--config", ~s(model_reasoning_effort="low")] in pairs
    context
  end

  step "the text-generation model is on Claude and Claude is not installed", context do
    context = World.text_writers(context, [:codex])

    World.merge_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}
    })

    context
  end

  step "the first usable provider writes it with its default model", context do
    assert {:ok, %{"title" => title}} = context.title_result
    assert title =~ "codex"
    assert [%{"argv" => ["exec" | _] = argv}] = World.text_calls(context)
    assert ["--model", "gpt-6-luna"] in Enum.chunk_every(argv, 2, 1)
    context
  end

  step "the project's commit writer model is on Claude", context do
    context = World.text_writers(context, [:claude, :codex])

    override(context, nil, %{
      "sourceControlWriterModelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}
    })

    context
  end

  step "Claude writes the commit message", context do
    assert {:ok, %{"subject" => subject}} = context.commit_result
    assert subject =~ "claude"
    assert [%{"argv" => ["-p" | _] = argv}] = World.text_calls(context)
    assert ["--model", "haiku"] in Enum.chunk_every(argv, 2, 1)
    context
  end

  # --- the bundled manifest ----------------------------------------------------------------

  # The manifest is compiled into the node (`HalC2.Claude.Provider`); a download
  # would be a file in its home.
  step "the node has never fetched the model manifest", context do
    assert downloaded_manifests(context) == []
    context
  end

  step "the node starts without network access", context do
    %{context | node: HalC2.Test.Node.restart(context.node), clients: %{}}
  end

  step "models are listed from the bundled manifest", context do
    bundled =
      Application.app_dir(:hal_c2, "priv/model-manifest.json")
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["providers", "claudeAgent"])

    {providers, context} = World.provider_list(context)
    claude = Enum.find(providers, &(&1["instanceId"] == "claudeAgent"))

    # Every listed model is the manifest's, in its order; the installed CLI's version
    # decides which of them it can run.
    listed = Enum.map(claude["models"], &{&1["slug"], &1["name"]})
    assert listed != []

    assert listed ==
             for(
               model <- bundled["models"],
               List.keymember?(listed, model["slug"], 0),
               do: {model["slug"], model["name"]}
             )

    # Listing them asked nobody: there is still no downloaded copy.
    assert downloaded_manifests(context) == []
    context
  end

  # --- custom models --------------------------------------------------------------------------

  step "the user adds the custom model {string} to Claude", %{args: [slug]} = context do
    add_custom_model(World.fake_providers(context), slug)
  end

  step "the user adds the custom model {string} to Claude's own instance",
       %{args: [slug]} = context do
    context = World.fake_providers(context)

    {{:ok, %{"settings" => settings, "version" => version}}, context} =
      World.call(context, "hal-c2.readSettings")

    settings =
      put_in(
        settings,
        [Access.key("providerInstances", %{}), Access.key("claudeAgent", %{})],
        %{"driver" => "claudeAgent", "config" => %{"customModels" => [slug]}}
      )

    {{:ok, _}, context} =
      World.call(context, "hal-c2.writeSettings", %{"settings" => settings, "version" => version})

    Map.put(context, :custom_model, slug)
  end

  step "Codex's models offer reasoning levels", context do
    System.put_env(
      "FAKE_CODEX_MODELS",
      JSON.encode!([
        %{
          "model" => "gpt-6-luna",
          "displayName" => "GPT-6 Luna",
          "isDefault" => true,
          "defaultReasoningEffort" => "medium",
          "supportedReasoningEfforts" =>
            for(effort <- ~w(low medium high), do: %{"reasoningEffort" => effort})
        }
      ])
    )

    context = World.fake_providers(context)
    HalC2.Codex.Provider.load()
    context
  end

  step "the user adds the custom model {string} to Codex", %{args: [slug]} = context do
    add_custom_model(World.fake_providers(context), slug, "codex")
  end

  step "{string} offers the same options as Codex's own models", %{args: [slug]} = context do
    {providers, _context} = World.provider_list(context)
    codex = Enum.find(providers, &(&1["instanceId"] == "codex"))
    [own | _] = codex["models"]
    custom = Enum.find(codex["models"], &(&1["slug"] == slug)) || flunk("#{slug} is not offered")
    assert %{"isCustom" => true} = custom
    assert [_ | _] = own["capabilities"]["optionDescriptors"]
    assert custom["capabilities"] == own["capabilities"]
    context
  end

  step "{string} is offered in the model picker for Claude", %{args: [slug]} = context do
    assert %{"isCustom" => true, "name" => ^slug} = claude_model(context, slug)
    context
  end

  step "it is saved on the environment", context do
    # Written to the node's settings file, so it outlives the client and a restart.
    saved = context.node.home |> Path.join("settings.json") |> File.read!() |> JSON.decode!()
    assert context.custom_model in get_in(saved, ["providers", "claudeAgent", "customModels"])
    context
  end

  step ~r/^the user gives the custom model "(?<slug>[^"]+)" a reasoning choice of (?<a>\w+) or (?<b>\w+) with (?<default>\w+) as default$/,
       %{args: [slug, a, b, default]} = context do
    options =
      for id <- [a, b] do
        option = %{"id" => id, "label" => String.capitalize(id)}
        if id == default, do: Map.put(option, "isDefault", true), else: option
      end

    capabilities = %{
      "optionDescriptors" => [
        %{"id" => "effort", "label" => "Reasoning", "type" => "select", "options" => options}
      ]
    }

    add_custom_model(World.fake_providers(context), %{
      "slug" => slug,
      "capabilities" => capabilities
    })
  end

  step ~r/^the composer offers (?<a>\w+) and (?<b>\w+) for "(?<slug>[^"]+)" with (?<selected>\w+) selected$/,
       %{args: [a, b, slug, selected]} = context do
    [descriptor] = claude_model(context, slug)["capabilities"]["optionDescriptors"]
    assert Enum.map(descriptor["options"], & &1["id"]) == [a, b]
    assert Enum.find(descriptor["options"], & &1["isDefault"])["id"] == selected
    context
  end

  # --- helpers ------------------------------------------------------------------------------

  # Saves a custom model the way the settings panel does: read, add, write back.
  defp add_custom_model(context, setting, driver \\ "claudeAgent") do
    {{:ok, %{"settings" => settings, "version" => version}}, context} =
      World.call(context, "hal-c2.readSettings")

    settings =
      update_in(
        settings,
        [
          Access.key("providers", %{}),
          Access.key(driver, %{}),
          Access.key("customModels", [])
        ],
        &(&1 ++ [setting])
      )

    {{:ok, _}, context} =
      World.call(context, "hal-c2.writeSettings", %{"settings" => settings, "version" => version})

    Map.put(context, :custom_model, setting)
  end

  defp downloaded_manifests(context),
    do: Path.wildcard(Path.join(context.node.home, "**/*manifest*"))

  defp claude_model(context, slug) do
    {providers, _context} = World.provider_list(context)
    claude = Enum.find(providers, &(&1["instanceId"] == "claudeAgent"))
    Enum.find(claude["models"], &(&1["slug"] == slug)) || flunk("#{slug} is not offered")
  end

  defp codex_default, do: %{"instanceId" => "codex", "model" => "gpt-5.4"}

  defp override(context, project, fields) do
    id = World.project(context, project).id
    World.merge_settings(%{"projectSettingsOverrides" => %{id => fields}})
  end

  defp project_settings(context, project),
    do: HalC2.Settings.for_project(World.project(context, project).id)

  # `flattenModelOptions`: every model of each enabled, available provider.
  defp flatten(providers) do
    for provider <- providers,
        provider["enabled"] != false,
        provider["availability"] != "unavailable",
        model <- provider["models"] do
      %{
        instance: provider["instanceId"],
        model: model["slug"],
        label: model["shortName"] || model["name"] || model["slug"],
        provider_label: provider["displayName"] || provider["driver"] || provider["instanceId"]
      }
    end
  end
end
