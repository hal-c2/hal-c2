defmodule HalC2.ClaudeProviderTest do
  # Claude's models: what the installed Claude Code lists in its `initialize` reply, and
  # the model manifest when it cannot say.
  use ExUnit.Case, async: false

  alias HalC2.Claude.Provider

  @moduletag :tmp_dir
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)

  # Rows shaped as Claude Code 2.1.293 lists them: a `default` row naming the model it
  # resolves to, aliases (`opus`, `sonnet`) with their canonical ids, an id carrying its
  # context window, and an older model without effort levels.
  @reported [
    %{
      "value" => "default",
      "resolvedModel" => "claude-opus-5-5",
      "displayName" => "Default (recommended)",
      "description" => "Opus 5.5 · Best for everyday, complex tasks",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high xhigh max),
      "supportsAdaptiveThinking" => true,
      "supportsFastMode" => true,
      "supportsAutoMode" => true
    },
    %{
      "value" => "opus",
      "resolvedModel" => "claude-opus-5-5",
      "displayName" => "Opus 5.5",
      "description" => "For complex work and everyday tasks",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high xhigh max),
      "supportsAdaptiveThinking" => true,
      "supportsFastMode" => true,
      "supportsAutoMode" => true
    },
    %{
      "value" => "claude-fable-5-1[1m]",
      "resolvedModel" => "claude-fable-5-1[1m]",
      "displayName" => "Fable 5.1",
      "description" => "For your toughest challenges",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high xhigh max),
      "supportsAdaptiveThinking" => true,
      "supportsAutoMode" => true
    },
    %{
      "value" => "sonnet",
      "resolvedModel" => "claude-sonnet-5-5",
      "displayName" => "Sonnet 5.5",
      "description" => "Most efficient for simpler tasks",
      "supportsEffort" => true,
      "supportedEffortLevels" => ~w(low medium high xhigh max),
      "supportsAdaptiveThinking" => true,
      "supportsAutoMode" => true
    },
    %{
      "value" => "claude-haiku-4-5-20251001",
      "resolvedModel" => "claude-haiku-4-5-20251001",
      "displayName" => "Haiku 4.5",
      "description" => "Fastest for quick answers"
    }
  ]

  setup %{tmp_dir: dir} do
    # A `claude` on its own path, so its version reads as the fake's.
    claude = Path.join(dir, "claude")
    File.write!(claude, "#!/bin/sh\nexec python3 -u #{@fake_claude} \"$@\"\n")
    File.chmod!(claude, 0o755)

    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :claude_command, [claude])
    reset()

    on_exit(fn ->
      Application.delete_env(:hal_c2, :claude_command)
      System.delete_env("FAKE_CLAUDE_MODELS")
      reset()
    end)

    start_supervised!(HalC2.Settings)
    :ok
  end

  defp reset do
    :persistent_term.erase({Provider, :models})
    :persistent_term.erase({Provider, :version})
  end

  defp reports(models), do: System.put_env("FAKE_CLAUDE_MODELS", JSON.encode!(models))

  defp models, do: Provider.entry()["models"]

  defp model(slug), do: Enum.find(models(), &(&1["slug"] == slug))

  defp option_ids(model, id) do
    descriptor = Enum.find(model["capabilities"]["optionDescriptors"], &(&1["id"] == id))
    descriptor && Enum.map(descriptor["options"] || [], & &1["id"])
  end

  defp descriptor_ids(model),
    do: Enum.map(model["capabilities"]["optionDescriptors"], & &1["id"])

  test "the models are the ones Claude Code lists, with its default marked" do
    reports(@reported)
    :ok = Provider.load()

    assert [
             %{"slug" => "opus", "name" => "Opus 5.5", "isDefault" => true},
             %{"slug" => "claude-fable-5-1[1m]", "name" => "Fable 5.1", "isDefault" => false},
             %{"slug" => "sonnet", "name" => "Sonnet 5.5", "isDefault" => false},
             %{"slug" => "claude-haiku-4-5-20251001", "name" => "Haiku 4.5"}
           ] = models()

    # A thread saved under the canonical id, or on the CLI's default, finds the alias row.
    assert model("opus")["aliases"] == ["claude-opus-5-5", "default"]
    assert model("sonnet")["aliases"] == ["claude-sonnet-5-5"]
    assert model("claude-fable-5-1[1m]")["aliases"] == []
    assert Enum.all?(models(), &(&1["isCustom"] == false and &1["isLegacy"] == false))
  end

  test "a listed model the manifest knows keeps the manifest's extra options" do
    reports(@reported)
    :ok = Provider.load()

    # The CLI's levels, then what the manifest runs otherwise.
    assert option_ids(model("opus"), "effort") ==
             ~w(low medium high xhigh max ultracode ultrathink)

    assert descriptor_ids(model("opus")) == ~w(effort fastMode contextWindow)

    # An id that names its context window offers no other.
    assert descriptor_ids(model("claude-fable-5-1[1m]")) == ~w(effort)

    # The manifest has no effort for Haiku 4.5, nor does the CLI; thinking stays.
    assert descriptor_ids(model("claude-haiku-4-5-20251001")) == ~w(thinking)
  end

  test "a listed model the manifest does not know offers only what Claude Code reports" do
    reports(@reported)
    :ok = Provider.load()

    assert %{"optionDescriptors" => [effort]} = model("sonnet")["capabilities"]
    assert effort["options"] |> Enum.map(& &1["id"]) == ~w(low medium high xhigh max)
    refute Map.has_key?(effort, "promptInjectedValues")
  end

  test "a listed model runs under the name it was picked by, with its entry's options" do
    reports(@reported)
    :ok = Provider.load()

    assert %{model: "opus[1m]", effort: "xhigh", settings: %{"ultracode" => true}} =
             Provider.launch("opus", %{"effort" => "ultracode"})

    assert %{model: "claude-opus-5-5", effort: nil, prompt_effort: "ultrathink"} =
             Provider.launch("claude-opus-5-5", %{
               "effort" => "ultrathink",
               "contextWindow" => "200k"
             })

    assert %{model: "claude-fable-5-1[1m]", effort: "high"} =
             Provider.launch("claude-fable-5-1[1m]", %{"effort" => "high"})

    # The manifest gates Opus 5.5 on a newer Claude Code than the fake's 2.1.0, but
    # this CLI listed it, so it runs it.
    assert Provider.too_old("claude-opus-5-5") == nil
    assert Provider.too_old("opus") == nil
  end

  test "until Claude Code lists its models, and when it cannot, the manifest stands" do
    manifest = Enum.map(models(), & &1["slug"])
    assert "claude-sonnet-5" in manifest
    # Gated on a newer CLI than the fake's 2.1.0.
    refute "claude-opus-5-5" in manifest
    assert Provider.too_old("claude-opus-5-5") =~ "Claude Code v2.1.0 is too old"
    assert %{model: "claude-opus-5[1m]"} = Provider.launch("opus", %{})

    # A CLI that answers without models (one too old to list them).
    :ok = Provider.load()
    assert Enum.map(models(), & &1["slug"]) == manifest

    reports(@reported)
    :ok = Provider.load()
    assert model("opus")

    # Updated to a version that stops listing them, it goes back to the manifest.
    System.delete_env("FAKE_CLAUDE_MODELS")
    :ok = Provider.load()
    assert Enum.map(models(), & &1["slug"]) == manifest
  end

  test "a CLI that does not start keeps the manifest" do
    Application.put_env(:hal_c2, :claude_command, ["false"])
    reports(@reported)
    :ok = Provider.load()
    assert Enum.any?(models(), &(&1["slug"] == "claude-sonnet-5"))
  end

  test "clients are told when the list changes, and only then" do
    HalC2.Settings.watch(self())
    reports(@reported)

    :ok = Provider.load()
    assert_receive {:hal_c2_providers_changed, _}

    :ok = Provider.load()
    # A call to the settings server returns once it has handled every notice sent before.
    HalC2.Settings.watch(self())
    refute_received {:hal_c2_providers_changed, _}
  end
end
