defmodule T3.Steps.Providers.Opencode do
  @moduledoc """
  Steps for `features/providers/opencode.feature`: OpenCode's ACP mode (`opencode acp`),
  played by the scripted fake (`T3.Test.FakeAcp`) behind the instance's binary path.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias T3.Test.FakeAcp

  # A supported OpenCode (1.14.19 is the oldest T3 Code runs) connected to `models`.
  defp models(models),
    do: %{
      "version" => "1.14.19",
      "configOptions" => [
        %{
          "id" => "model",
          "name" => "Model",
          "type" => "select",
          "currentValue" => elem(hd(models), 0),
          "options" => for({value, name} <- models, do: %{"value" => value, "name" => name})
        }
      ]
    }

  @connected [
    {"openai/gpt-5", "OpenAI/GPT-5"},
    {"anthropic/claude-sonnet-4", "Anthropic/Claude Sonnet 4"}
  ]

  step "OpenCode is installed but not enabled", context do
    FakeAcp.install(context, "opencode", models(@connected))
  end

  step "no OpenCode process is started", context do
    T3.Acp.load()
    assert %{"enabled" => false} = FakeAcp.entry("opencode")
    assert FakeAcp.starts(context, "opencode") == []
    context
  end

  step "OpenCode is connected to OpenAI and Anthropic", context do
    FakeAcp.install(context, "opencode", models(@connected))
  end

  step "the user enables OpenCode", context do
    {_, context} = FakeAcp.open_config(context)
    FakeAcp.enable(context, "opencode")
  end

  step "the model picker offers the OpenAI and Anthropic models through OpenCode", context do
    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"models" => [_ | _]}, FakeAcp.find(providers, "opencode"))
      end)

    opencode = FakeAcp.find(providers, "opencode")
    assert opencode["enabled"]

    assert Enum.map(opencode["models"], & &1["slug"]) == [
             "openai/gpt-5",
             "anthropic/claude-sonnet-4"
           ]

    # The command line is OpenCode's ACP mode.
    assert [%{"argv" => [_, "acp"]} | _] = FakeAcp.starts(context)
    context
  end

  step "each model is grouped under its upstream provider", context do
    models = FakeAcp.find(context.providers, "opencode")["models"]

    assert Enum.map(models, &{&1["subProvider"], &1["name"]}) == [
             {"OpenAI", "GPT-5"},
             {"Anthropic", "Claude Sonnet 4"}
           ]

    context
  end

  step "the opencode command is not installed on the node", context do
    FakeAcp.services()
    T3.Acp.forget("opencode")
    missing = Path.join(T3.Test.Node.tmp_dir(context.node, "no-opencode"), "opencode")
    FakeAcp.settings(&put_in(&1, ["providers"], %{"opencode" => %{"binaryPath" => missing}}))
    Map.put(context, :provider, "opencode")
  end

  step "OpenCode is not offered", context do
    assert context.providers != nil
    assert FakeAcp.find(context.providers, "opencode") == nil
    context
  end

  step "the thread runs OpenCode with approval required", context do
    context
    |> FakeAcp.install("opencode", %{}, enabled: true)
    |> FakeAcp.thread("Work", "approval-required")
  end

  step "the thread runs OpenCode with full access", context do
    context
    |> FakeAcp.install("opencode", %{}, enabled: true)
    |> FakeAcp.thread("Work", "full-access")
  end

  step "OpenCode asks to edit a file", context do
    context
    |> FakeAcp.send_message("please edit a file")
    |> Map.put(:expected_request, %{"kind" => "file-change"})
  end

  step "the request is granted without asking the user", context do
    state = FakeAcp.await_run(context, "completed")
    assert T3.StreamState.list(state, "runtime-request") == []

    assert [%{"result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "once"}}}] =
             FakeAcp.answers(context)

    context
  end

  step "OpenCode is picked for text generation", context do
    context = FakeAcp.install(context, "opencode", %{}, enabled: true)

    FakeAcp.settings(
      &Map.put(&1, "textGenerationModelSelection", %{
        "instanceId" => "opencode",
        "model" => "fake/one"
      })
    )

    context
  end

  step "the user connected a new upstream provider in OpenCode", context do
    context = FakeAcp.install(context, "opencode", models(@connected), enabled: true)
    assert [_, _] = FakeAcp.probe("opencode")["models"]
    {_, context} = FakeAcp.open_config(context)

    FakeAcp.configure(context, fn config ->
      Map.merge(
        config,
        models(@connected ++ [{"google/gemini-2.5-pro", "Google/Gemini 2.5 Pro"}])
      )
    end)
  end

  step "the new provider's models are offered", context do
    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"models" => [_, _, _]}, FakeAcp.find(providers, "opencode"))
      end)

    models = FakeAcp.find(providers, "opencode")["models"]

    assert %{"name" => "Gemini 2.5 Pro", "subProvider" => "Google"} =
             Enum.find(models, &(&1["slug"] == "google/gemini-2.5-pro"))

    context
  end

  # --- version gate and compatibility ---

  step "the installed OpenCode is older than 1.14.19", context do
    FakeAcp.install(context, "opencode", Map.put(models(@connected), "version", "1.14.10"))
  end

  step "OpenCode is shown as too old with the version to upgrade to", context do
    {providers, context} =
      FakeAcp.await_providers(
        context,
        &match?(%{"status" => "error"}, FakeAcp.find(&1, "opencode"))
      )

    opencode = FakeAcp.find(providers, "opencode")
    assert opencode["message"] == "OpenCode v1.14.10 is too old. Upgrade to v1.14.19 or newer."
    assert opencode["models"] == []
    context
  end

  step ~r/^OpenCode (?<version>1\.14\.\d+) is installed$/, %{args: [version]} = context do
    FakeAcp.install(context, "opencode", Map.put(models(@connected), "version", version),
      enabled: true
    )
  end

  step "the node checks its providers", context do
    Map.put(context, :entry, FakeAcp.probe(context.provider))
  end

  step "OpenCode is reported as a known broken version for this T3 Code release", context do
    assert %{"status" => "broken", "message" => message} = context.entry["compatibilityAdvisory"]
    assert message =~ "known to be incompatible with this T3 Code release"
    context
  end

  step "the user is told to use OpenCode 1.14.19 or newer", context do
    advisory = context.entry["compatibilityAdvisory"]
    assert advisory["recommendedRange"] == ">=1.14.19"
    assert advisory["message"] =~ "Use >=1.14.19."
    context
  end

  step "OpenCode carries no compatibility warning", context do
    assert %{"status" => "unknown", "message" => nil} = context.entry["compatibilityAdvisory"]
    assert context.entry["status"] == "ready"
    context
  end

  # --- no upstream providers ---

  step "OpenCode has no upstream providers connected", context do
    FakeAcp.install(context, "opencode", %{"configOptions" => []}, enabled: true)
  end

  step "OpenCode is shown with a warning that no providers are connected", context do
    opencode = FakeAcp.find(context.providers, "opencode")
    assert opencode["status"] == "warning"
    assert opencode["message"] =~ "did not report any connected upstream providers"
    context
  end

  # --- approvals ---

  step ~r/^the thread runs OpenCode in (?<mode>approval required|auto-accept edits|full access)$/,
       %{args: [mode]} = context do
    context
    |> FakeAcp.install("opencode", %{}, enabled: true)
    |> FakeAcp.thread("Work", String.replace(mode, " ", "-"))
  end

  step ~r/^OpenCode wants to (?<action>.+)$/, %{args: [action]} = context do
    FakeAcp.send_message(context, "please #{String.trim(action)}")
  end

  step "OpenCode asked to run a command", context do
    context =
      context
      |> FakeAcp.install("opencode", %{}, enabled: true)
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("please run a command")

    Map.put(context, :request, FakeAcp.await_request(context))
  end

  step "OpenCode runs it this time only", context do
    FakeAcp.await_run(context, "completed")
    assert [%{"result" => %{"outcome" => %{"optionId" => "once"}}}] = FakeAcp.answers(context)

    # The next time it asks again.
    context = FakeAcp.send_message(context, "please run a command")
    request = FakeAcp.await_request(context)
    refute request["id"] == context.request["id"]
    assert request["kind"] == "command"
    context
  end

  step "OpenCode runs matching commands without asking again", context do
    FakeAcp.await_run(context, "completed")
    assert [%{"result" => %{"outcome" => %{"optionId" => "always"}}}] = FakeAcp.answers(context)

    context = FakeAcp.send_message(context, "please run a command")
    state = FakeAcp.await_runs(context, 2)
    assert Enum.all?(T3.StreamState.list(state, "run"), &(&1["status"] == "completed"))
    refute Enum.any?(T3.StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))

    assert [_, %{"result" => %{"outcome" => %{"outcome" => "selected"}}}] =
             FakeAcp.answers(context)

    context
  end

  step "OpenCode does not run it", context do
    FakeAcp.await_run(context, "completed")
    assert [%{"result" => %{"outcome" => %{"optionId" => "reject"}}}] = FakeAcp.answers(context)
    context
  end
end
