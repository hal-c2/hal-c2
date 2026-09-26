defmodule HalC2.Steps.Providers.Opencode do
  @moduledoc """
  Steps for `features/providers/opencode.feature`: OpenCode's ACP mode (`opencode acp`),
  played by the scripted fake (`HalC2.Test.FakeAcp`) behind the instance's binary path.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Node.World

  # A supported OpenCode (1.14.19 is the oldest HAL-C2 runs) connected to `models`.
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
    HalC2.Acp.load()
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
    HalC2.Acp.forget("opencode")
    missing = Path.join(HalC2.Test.Node.tmp_dir(context.node, "no-opencode"), "opencode")
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
    assert HalC2.StreamState.list(state, "runtime-request") == []

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

  step "OpenCode is reported as a known broken version for this HAL-C2 release", context do
    assert %{"status" => "broken", "message" => message} = context.entry["compatibilityAdvisory"]
    assert message =~ "known to be incompatible with this HAL-C2 release"
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
    assert Enum.all?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "completed"))

    refute Enum.any?(
             HalC2.StreamState.list(state, "runtime-request"),
             &(&1["status"] == "pending")
           )

    assert [_, %{"result" => %{"outcome" => %{"outcome" => "selected"}}}] =
             FakeAcp.answers(context)

    context
  end

  step "OpenCode does not run it", context do
    FakeAcp.await_run(context, "completed")
    assert [%{"result" => %{"outcome" => %{"optionId" => "reject"}}}] = FakeAcp.answers(context)
    context
  end

  # --- models: variants and agents ---------------------------------------------------

  # `opencode acp`'s session options: the current model's reasoning variants
  # (`effort`, with "default" for none) and the primary agents (`mode`).
  defp with_options(config) do
    Map.update!(config, "configOptions", fn options ->
      options ++
        [
          %{
            "id" => "effort",
            "name" => "Effort",
            "category" => "thought_level",
            "type" => "select",
            "currentValue" => "default",
            "options" => for(v <- ~w(default low medium high), do: %{"value" => v, "name" => v})
          },
          %{
            "id" => "mode",
            "name" => "Mode",
            "category" => "mode",
            "type" => "select",
            "currentValue" => "build",
            "options" => for(v <- ~w(build plan), do: %{"value" => v, "name" => v})
          }
        ]
    end)
  end

  step "the user opens the options for an OpenCode model", context do
    context =
      FakeAcp.install(context, "opencode", with_options(models(@connected)), enabled: true)

    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"models" => [_ | _]}, FakeAcp.find(providers, "opencode"))
      end)

    model =
      Enum.find(FakeAcp.find(providers, "opencode")["models"], &(&1["slug"] == "openai/gpt-5"))

    Map.put(
      context,
      :options,
      Map.new(model["capabilities"]["optionDescriptors"], &{&1["id"], &1})
    )
  end

  step "the model's reasoning variants are offered", context do
    assert %{
             "label" => "Reasoning",
             "type" => "select",
             "currentValue" => "medium",
             "options" => options
           } =
             context.options["variant"]

    assert options == [
             %{"id" => "low", "label" => "Low"},
             %{"id" => "medium", "label" => "Medium", "isDefault" => true},
             %{"id" => "high", "label" => "High"}
           ]

    context
  end

  step "OpenCode's primary agents are offered with {string} as the default",
       %{args: [default]} = context do
    assert %{"label" => "Agent", "currentValue" => ^default, "options" => options} =
             context.options["agent"]

    assert Enum.map(options, & &1["id"]) == ["build", "plan"]
    assert [%{"id" => ^default, "label" => "Build"}] = Enum.filter(options, & &1["isDefault"])
    context
  end

  # --- plan mode --------------------------------------------------------------------

  step "the user switches an OpenCode thread to plan mode", context do
    context =
      context
      |> FakeAcp.install("opencode", with_options(models(@connected)), enabled: true)
      |> FakeAcp.thread()

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.interaction-mode.set",
        "commandId" => "cmd-plan-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "interactionMode" => "plan"
      })

    context = FakeAcp.send_message(context, "plan the checkout")
    FakeAcp.await_run(context, "completed")
    context
  end

  step "the turn runs with OpenCode's plan agent", context do
    # The plan agent is chosen on the session before the prompt goes out.
    methods =
      for %{"recv" => %{"method" => method} = msg} <- FakeAcp.log(context),
          method in ["session/set_config_option", "session/prompt"],
          do: {method, msg["params"]["configId"], msg["params"]["value"]}

    assert {_, [{"session/prompt", _, _} | _]} =
             Enum.split_while(methods, &(&1 != {"session/set_config_option", "mode", "plan"}))
             |> then(fn {before, [_ | rest]} -> {before, rest} end)

    refute Enum.any?(methods, &match?({"session/set_config_option", "mode", "build"}, &1))
    context
  end

  # --- external server --------------------------------------------------------------

  # A server elsewhere, played by a small HTTP fake of OpenCode's `/provider` route,
  # set on the instance with its password.
  defp external(context, password, respond) do
    {url, log} =
      HalC2.Test.FakeHttp.start(%{
        "/provider" => fn conn ->
          expected = "Basic " <> Base.encode64("opencode:secret")

          if Plug.Conn.get_req_header(conn, "authorization") == [expected],
            do: respond.(conn),
            else: {401, %{"error" => "unauthorized"}}
        end
      })

    server(context, url, password) |> Map.put(:server_log, log)
  end

  defp server(context, url, password) do
    context = FakeAcp.install(context, "opencode", models(@connected), enabled: true)

    FakeAcp.settings(fn settings ->
      update_in(
        settings,
        ["providers", "opencode"],
        &Map.merge(&1, %{"serverUrl" => url, "serverPassword" => password})
      )
    end)

    Map.put(context, :server_url, url)
  end

  defp inventory(_conn),
    do:
      {200,
       %{
         "all" => [
           %{
             "id" => "anthropic",
             "name" => "Anthropic",
             "models" => %{
               "claude-sonnet-4" => %{"id" => "claude-sonnet-4", "name" => "Claude Sonnet 4"}
             }
           }
         ],
         "connected" => ["anthropic"],
         "default" => %{}
       }}

  step "the OpenCode instance points at a server with the wrong password", context do
    external(context, "wrong", &inventory/1)
  end

  step "the OpenCode instance points at a server that is not running", context do
    # A port nothing listens on.
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    server(context, "http://127.0.0.1:#{port}", nil)
  end

  step "the OpenCode instance uses an external server", context do
    external(context, "secret", &inventory/1)
  end

  step "the user clears the server URL", context do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "halc2.readSettings")

    settings =
      update_in(
        settings,
        ["providers", "opencode"],
        &Map.drop(&1, ["serverUrl", "serverPassword"])
      )

    {_, context} =
      World.call!(context, "halc2.writeSettings", %{"settings" => settings, "version" => version})

    context
  end

  step "OpenCode threads run on a local OpenCode again", context do
    # The inventory comes from the local `opencode acp` again, not the server's.
    {_, context} =
      FakeAcp.await_providers(context, fn providers ->
        slugs =
          for model <- FakeAcp.find(providers, "opencode")["models"] || [], do: model["slug"]

        Enum.sort(slugs) == ["anthropic/claude-sonnet-4", "openai/gpt-5"]
      end)

    served = length(HalC2.Test.FakeHttp.requests(context.server_log))

    context =
      context
      |> Map.put(:provider, "opencode")
      |> FakeAcp.thread("Work", "full-access", %{
        "modelSelection" => %{"instanceId" => "opencode", "model" => "openai/gpt-5"}
      })
      |> FakeAcp.send_message("fix the bug")

    FakeAcp.await_run(context, "completed")
    assert [_ | _] = FakeAcp.received(context, "session/prompt", "opencode")
    assert length(HalC2.Test.FakeHttp.requests(context.server_log)) == served
    context
  end

  step "OpenCode says the server rejected authentication and to check the URL and password",
       context do
    opencode = FakeAcp.find(context.providers, "opencode")
    assert opencode["status"] == "error"
    assert opencode["installed"] == true

    assert opencode["message"] ==
             "OpenCode server rejected authentication. Check the server URL and password."

    # It asked the server, as the `opencode` user with the configured password.
    assert [%{"authorization" => auth} | _] = HalC2.Test.FakeHttp.requests(context.server_log)
    assert auth == "Basic " <> Base.encode64("opencode:wrong")
    context
  end

  step "OpenCode says it could not reach the server at that URL", context do
    opencode = FakeAcp.find(context.providers, "opencode")
    assert opencode["status"] == "error"

    assert opencode["message"] ==
             "Couldn't reach the configured OpenCode server at #{context.server_url}. Check that the server is running and the URL is correct."

    context
  end

  # --- OpenCode Go limits -------------------------------------------------------------

  step "OpenCode is signed in to OpenCode Go and runs locally", context do
    {url, log} =
      HalC2.Test.FakeHttp.start(%{
        "/zen/go/v1/usage" =>
          {200,
           %{
             "usage" => %{
               "rolling" => %{"percent" => 12.5, "resetsAt" => "2026-09-26T15:00:00Z"},
               "weekly" => %{"percent" => 40, "resetsAt" => "2026-09-30T00:00:00Z"},
               "monthly" => %{"percent" => 75, "resetsAt" => "2026-10-01T00:00:00Z"}
             }
           }}
      })

    Application.put_env(:hal_c2, :opencode_go_usage_url, url <> "/zen/go/v1/usage")
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :opencode_go_usage_url) end)
    auth = JSON.encode!(%{"opencode-go" => %{"type" => "api", "key" => "go-key"}})

    context
    |> FakeAcp.install("opencode", models(@connected), enabled: true)
    |> tap(fn _ ->
      FakeAcp.settings(
        &Map.put(&1, "providerInstances", %{
          "opencode" => %{
            "driver" => "opencode",
            "environment" => [%{"name" => "OPENCODE_AUTH_CONTENT", "value" => auth}]
          }
        })
      )
    end)
    |> Map.put(:usage_log, log)
  end

  step "OpenCode Go shows its session, weekly and monthly windows", context do
    assert %{"windows" => windows} = FakeAcp.find(context.providers, "opencode")["usageLimits"]

    assert windows == [
             %{
               "id" => "go_rolling",
               "kind" => "session",
               "label" => "Go · Session",
               "usedPercent" => 12.5,
               "resetsAt" => "2026-09-26T15:00:00.000Z",
               "windowDurationMins" => 300
             },
             %{
               "id" => "go_weekly",
               "kind" => "weekly",
               "label" => "Go · Weekly",
               "usedPercent" => 40,
               "resetsAt" => "2026-09-30T00:00:00.000Z",
               "windowDurationMins" => 10_080
             },
             %{
               "id" => "go_monthly",
               "kind" => "monthly",
               "label" => "Go · Monthly",
               "usedPercent" => 75,
               "resetsAt" => "2026-10-01T00:00:00.000Z"
             }
           ]

    # Read with OpenCode's own Go key.
    assert [_ | _] = requests = HalC2.Test.FakeHttp.requests(context.usage_log)
    assert Enum.all?(requests, &(&1["authorization"] == "Bearer go-key"))
    context
  end

  step "OpenCode's limits are shown as unsupported", context do
    assert %{"windows" => [], "unavailable" => %{"reason" => "unsupported"}} =
             FakeAcp.find(context.providers, "opencode")["usageLimits"]

    context
  end

  # --- a model leaving the catalog --------------------------------------------------

  @gone "openai/gpt-4o"

  step "an OpenCode thread uses a model that OpenCode no longer lists", context do
    context
    |> FakeAcp.install("opencode", Map.put(models(@connected), "rejectUnknownModels", true),
      enabled: true
    )
    |> FakeAcp.thread("Work", "full-access", %{
      "modelSelection" => %{"instanceId" => "opencode", "model" => @gone}
    })
  end

  step "the thread still shows its model", context do
    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"models" => [_ | _]}, FakeAcp.find(providers, "opencode"))
      end)

    opencode = FakeAcp.find(providers, "opencode")
    refute Enum.any?(opencode["models"], &(&1["slug"] == @gone))

    thread_id = World.thread_id(context, context.thread)
    row = World.await_row(thread_id, & &1)
    assert %{"instanceId" => "opencode", "model" => @gone} = row["modelSelection"]
    context
  end

  step "if OpenCode rejects the model the user can pick another and retry", context do
    thread_id = World.thread_id(context, context.thread)
    context = FakeAcp.send_message(context, "fix the bug")
    state = FakeAcp.await_run(context, "failed")

    assert [%{"lastError" => error}] = HalC2.StreamState.list(state, "provider-session")
    assert error =~ "the model #{@gone} is no longer offered"
    assert error =~ "Pick another model"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.model-selection.set",
        "commandId" => "cmd-model-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "modelSelection" => %{"instanceId" => "opencode", "model" => "anthropic/claude-sonnet-4"}
      })

    context = FakeAcp.send_message(context, "fix the bug")
    state = FakeAcp.await_runs(context, 2)

    assert ["failed", "completed"] =
             state
             |> HalC2.StreamState.list("run")
             |> Enum.sort_by(& &1["ordinal"])
             |> Enum.map(& &1["status"])

    assert Enum.any?(
             FakeAcp.received(context, "session/set_config_option"),
             &(&1["params"]["configId"] == "model" and
                 &1["params"]["value"] == "anthropic/claude-sonnet-4")
           )

    context
  end
end
