defmodule HalC2.Steps.Providers.Opencode do
  @moduledoc """
  Steps for `features/providers/opencode.feature`: OpenCode's ACP mode (`opencode acp`),
  played by the scripted fake (`HalC2.Test.FakeAcp`) behind the instance's binary path.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.StreamState
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc.World

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

  @thread "Work"

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

  step "the opencode command is not installed on the MC", context do
    FakeAcp.services()
    HalC2.Acp.forget("opencode")
    missing = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "no-opencode"), "opencode")
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

  step "the MC checks its providers", context do
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
      World.call!(context, "hal-c2.readSettings")

    settings =
      update_in(
        settings,
        ["providers", "opencode"],
        &Map.drop(&1, ["serverUrl", "serverPassword"])
      )

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{"settings" => settings, "version" => version})

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

  # OpenCode has no background tasks: what its turn left running ends with it.
  step "OpenCode ends a turn with a command still running", context do
    turn = %{
      "match" => "leave a command running",
      "steps" => [
        %{
          "update" => %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "cmd-bg",
            "title" => "npm run dev",
            "kind" => "execute",
            "status" => "in_progress",
            "rawInput" => %{"command" => "npm run dev"}
          }
        },
        %{"text" => "Started it."}
      ]
    }

    context =
      context
      |> FakeAcp.install("opencode", %{"turns" => [turn | FakeAcp.turns()]}, enabled: true)
      |> FakeAcp.thread(@thread)
      |> FakeAcp.send_message("leave a command running")

    FakeAcp.await_run(context, "completed")
    context
  end

  step "an OpenCode turn is running", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "opencode", "wait for me")

    World.await_running(context, @thread)
    # The shared follow-up step sends to `running.thread` outside the provider features.
    Map.put(context, :running, %{thread: World.thread_id(context, @thread)})
  end

  # The MC talks to OpenCode over ACP, so its event stream is the agent's connection.
  step "an OpenCode turn is streaming", context do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "opencode", "wait for me")

    World.await_running(context, @thread)
    World.await_provider_log(context, "acp", &(get_in(&1, ["in", "method"]) == "session/prompt"))
    context
  end

  # OpenCode's own pid, from its connection (never found by name).
  step "the event stream ends unexpectedly", context do
    [{runtime, _}] = Registry.lookup(HalC2.Acp.Registry, World.thread_id(context, @thread))
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(:sys.get_state(runtime).conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    context
  end

  step "the turn fails saying OpenCode exited unexpectedly", context do
    state = World.await_runs(context, @thread, ["failed"])

    assert Enum.any?(
             StreamState.list(state, "provider-session"),
             &(&1["lastError"] == "OpenCode exited unexpectedly")
           )

    context
  end

  # The thread a provider feature's scenario started (`World.launch_on/5`).
  step "the thread takes the next message", context do
    assert %{"status" => "completed", "ordinal" => 2} =
             World.finish_turn(context, World.current_thread(context), "Carry on")

    context
  end

  # OpenCode's running loop takes a second `session/prompt` into the turn.
  step "OpenCode receives the message during the running turn", context do
    World.await_provider_log(
      context,
      "acp",
      &(get_in(&1, ["in", "method"]) == "session/prompt" and
          get_in(&1, ["in", "params", "prompt"]) == [
            %{"type" => "text", "text" => "look here instead"}
          ])
    )

    World.await_runs(context, @thread, ["completed"])
    assert "steered: look here instead" in World.replies(context, @thread)
    context
  end

  # OpenCode names the command, and sends its output, only in in-progress updates.
  step "the running command reads {string} with the output {string}",
       %{args: [input, output]} = context do
    World.await_stream(World.thread_id(context, @thread), fn state ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(match?(%{"type" => "command_execution", "status" => "running", "input" => ^input}, &1) and
            String.trim(&1["output"]) == output)
      )
    end)

    context
  end

  # --- rewind and fork over OpenCode's server -------------------------------------------

  # A turn sent to the thread `title` and finished.
  defp send_turn(context, title, text) do
    count = length(World.runs(context, title))
    context = World.post_message(context, title, text)
    World.await_value(context, title, &(length(StreamState.list(&1, "run")) > count))
    World.await_idle(context, title)
    context
  end

  # The forks OpenCode's server was asked for, as the fake traced them: `%{"path", "body"}`.
  defp forks(context) do
    for %{"http" => %{"method" => "POST", "path" => path} = request} <-
          World.provider_log(context, "acp"),
        String.ends_with?(path, "/fork"),
        do: request
  end

  # The thread's OpenCode session, and each of its turns' OpenCode message by ordinal.
  defp native(context, title) do
    state = World.stream(context, title)
    thread = StreamState.get(state, "thread")[World.thread_id(context, title)]
    provider_thread = StreamState.get(state, "provider-thread")[thread["activeProviderThreadId"]]

    turns =
      for turn <- StreamState.list(state, "provider-turn"),
          turn["providerThreadId"] == provider_thread["id"],
          into: %{},
          do: {turn["ordinal"], get_in(turn, ["nativeTurnRef", "nativeId"])}

    {get_in(provider_thread, ["nativeThreadRef", "nativeId"]), turns}
  end

  # An OpenCode session as the fake keeps it: its messages' ids, and its users' texts.
  defp session(context, id) do
    messages =
      Path.join([context.fakes.dir, "opencode-sessions", "#{id}.json"])
      |> File.read!()
      |> JSON.decode!()

    {Enum.map(messages, & &1["info"]["id"]),
     for(%{"info" => %{"role" => "user"}, "parts" => [%{"text" => text}]} <- messages, do: text)}
  end

  defp last_prompt(context) do
    context
    |> World.provider_log("acp")
    |> Enum.filter(&(get_in(&1, ["in", "method"]) == "session/prompt"))
    |> List.last()
    |> get_in(["in", "params"])
  end

  step "an OpenCode thread with three turns", context do
    context =
      context
      |> World.fake_providers()
      |> World.run_turns(@thread, "opencode", ~w(first second third))

    {source, turns} = native(context, @thread)
    {ids, texts} = session(context, source)
    assert texts == ~w(first second third)
    # Each turn is named by its own OpenCode message.
    assert Enum.all?(1..3, &(turns[&1] in ids))
    Map.put(context, :opencode, {source, turns})
  end

  # OpenCode forked the session before the second turn's message; the thread goes on
  # in the fork, whose copy of the first turn now names it.
  step "OpenCode's session is rewound to that point", context do
    assert {:ok, _} = context.reply
    {source, turns} = context.opencode
    assert [%{"path" => path, "body" => %{"messageID" => before}}] = forks(context)
    assert path == "/session/#{source}/fork" and before == turns[2]

    {fork, kept} = native(context, @thread)
    assert fork != source
    assert {[first | _], ["first"]} = session(context, fork)
    assert kept[1] == first

    context = send_turn(context, @thread, "where are we")

    assert %{"sessionId" => ^fork, "prompt" => [%{"text" => "where are we"}]} =
             last_prompt(context)

    assert {_, ["first", "where are we"]} = session(context, fork)
    assert {_, ~w(first second third)} = session(context, source)
    context
  end

  # The fork's first turn opened a fork of the source's session, cut before the third
  # turn's message, with no transcript in its prompt.
  step "the new thread continues from a fork of OpenCode's session", context do
    assert {:ok, _} = context.reply
    {source, turns} = context.opencode
    context = send_turn(context, "fork", "where are we")

    assert [%{"path" => path, "body" => %{"messageID" => before}}] = forks(context)
    assert path == "/session/#{source}/fork" and before == turns[3]

    {fork, _} = native(context, "fork")
    assert fork != source

    assert %{"sessionId" => ^fork, "prompt" => [%{"text" => "where are we"}]} =
             last_prompt(context)

    assert {_, ["first", "second", "where are we"]} = session(context, fork)
    assert {_, ~w(first second third)} = session(context, source)
    context
  end
end
