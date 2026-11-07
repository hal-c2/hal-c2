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

  step "OpenCode is installed and enabled", context do
    FakeAcp.install(context, "opencode", %{}, enabled: true)
  end

  step "the user sends a message to OpenCode", context do
    context = context |> FakeAcp.thread() |> FakeAcp.send_message("hello OpenCode")
    FakeAcp.await_run(context, "completed")
    context
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

  # --- version ---

  # OpenCode's `initialize` names no agentInfo version.
  step "the opencode command prints no version", context do
    FakeAcp.install(context, "opencode", Map.put(models(@connected), "version", nil),
      enabled: true
    )
  end

  step "OpenCode says it could not determine the version and that 1.14.19 or newer is required",
       context do
    opencode = FakeAcp.find(context.providers, "opencode")
    assert opencode["status"] == "error"
    assert opencode["models"] == []

    assert opencode["message"] ==
             "HAL-C2 could not determine the OpenCode version. OpenCode v1.14.19 or newer is required."

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

  # --- the server password as a secret ------------------------------------------------

  @marker "••••••"

  defp settings_file, do: Path.join(HalC2.Paths.config_dir(), "settings.json")

  defp password_file,
    do:
      Path.join([
        HalC2.Paths.data_dir(),
        "secrets",
        "server-password-#{Base.url_encode64("provider-opencode", padding: false)}.bin"
      ])

  # The settings watchers were last told, once they say what `done?` waits for.
  defp told_settings(done?) do
    receive do
      {:hal_c2_settings, _, settings} ->
        if done?.(settings), do: settings, else: told_settings(done?)
    after
      5_000 -> flunk("the settings watchers were not told")
    end
  end

  step "the user saved a password for the external OpenCode server", context do
    context = external(context, "secret", &inventory/1)
    :ok = HalC2.Settings.watch(self())
    context
  end

  step "a client reads the settings or is told they changed", context do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings")

    # Another setting saved as a client saves: the document it read, sent back.
    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{
        "settings" => Map.put(settings, "confirmThreadDelete", false),
        "version" => version
      })

    told = told_settings(&(&1["confirmThreadDelete"] == false))
    Map.merge(context, %{read_settings: settings, told_settings: told})
  end

  step "the password is not in what it receives, only that one is stored", context do
    for settings <- [context.read_settings, context.told_settings] do
      assert get_in(settings, ["providers", "opencode", "serverPassword"]) == @marker
      refute JSON.encode!(settings) =~ "secret"
    end

    context
  end

  step "the password is not written to the settings file", context do
    refute File.read!(settings_file()) =~ "secret"
    assert File.read!(password_file()) == "secret"
    context
  end

  step "saving other settings keeps the stored password", context do
    assert context.told_settings["confirmThreadDelete"] == false
    assert File.read!(password_file()) == "secret"
    # The server is still asked with it.
    requests = length(HalC2.Test.FakeHttp.requests(context.server_log))

    {{:ok, %{"providers" => providers}}, context} =
      World.call_keeping(context, "server.refreshProviders", %{
        "instanceId" => "opencode",
        "refreshModels" => true
      })

    assert FakeAcp.find(providers, "opencode")["status"] != "error"

    assert [%{"authorization" => auth} | _] =
             HalC2.Test.FakeHttp.requests(context.server_log) |> Enum.drop(requests)

    assert auth == "Basic " <> Base.encode64("opencode:secret")
    context
  end

  step "the settings file holds the OpenCode server password in plain text", context do
    context = external(context, "secret", &inventory/1)
    path = settings_file()

    # As an older MC wrote it, while this one is stopped.
    mc =
      HalC2.Test.Mc.restart(context.mc, fn ->
        File.rm(password_file())
        settings = JSON.decode!(File.read!(path))

        File.write!(
          path,
          JSON.encode!(put_in(settings, ["providers", "opencode", "serverPassword"], "secret"))
        )
      end)

    %{context | mc: mc, clients: %{}}
  end

  step "the MC reads the settings", context do
    assert get_in(HalC2.Settings.settings(), ["providers", "opencode", "serverPassword"]) ==
             @marker

    context
  end

  step "the password is kept in the secret store and removed from the settings file", context do
    assert File.read!(password_file()) == "secret"
    refute File.read!(settings_file()) =~ "secret"
    context
  end

  step "OpenCode still reaches the external server with it", context do
    requests = length(HalC2.Test.FakeHttp.requests(context.server_log))

    {reply, context} =
      World.call_keeping(context, "server.refreshProviders", %{
        "instanceId" => "opencode",
        "refreshModels" => true
      })

    assert {:ok, %{"providers" => providers}} = reply
    opencode = FakeAcp.find(providers, "opencode")
    refute opencode["status"] == "error", inspect(opencode)

    assert [%{"authorization" => auth} | _] =
             HalC2.Test.FakeHttp.requests(context.server_log) |> Enum.drop(requests)

    assert auth == "Basic " <> Base.encode64("opencode:secret")
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
    running(context)
  end

  defp running(context) do
    context =
      context |> World.fake_providers() |> World.launch_on(@thread, "opencode", "wait for me")

    World.await_running(context, @thread)
    # The shared follow-up step sends to `running.thread` outside the provider features.
    Map.put(context, :running, %{thread: World.thread_id(context, @thread)})
  end

  # OpenCode on its Claude provider: the turn runs as any other, on an Anthropic model.
  step "an OpenCode turn is running on OpenCode's Claude provider", context do
    running(context)
  end

  # OpenCode 2 fails the prompt with the step's error, naming its kind in `data.errorName`.
  step ~r/^OpenCode stops it for (?<reason>an exhausted quota|a rate limit)$/,
       %{args: [reason]} = context do
    {name, message} =
      case reason do
        "an exhausted quota" -> {"provider.quota", "Quota exceeded for this model."}
        "a rate limit" -> {"provider.rate-limit", "Rate limit exceeded. Try again shortly."}
      end

    fail_waiting(context, %{
      "code" => -32603,
      "message" => message,
      "data" => %{"service" => "session", "errorName" => name}
    })
  end

  # A Claude plan limit reaches OpenCode as a provider error with Claude's own message.
  step ~r/^OpenCode fails it with "(?<message>[^"]+)"$/, %{args: [message]} = context do
    fail_waiting(context, %{
      "code" => -32603,
      "message" => message,
      "data" => %{"service" => "session", "errorName" => "provider.unknown"}
    })
  end

  step "the turn shows it hit a usage limit, not a provider error", context do
    row = limited(context)
    assert row["lastError"] =~ "exceeded"
    Map.put(context, :limited, row)
  end

  step "no reset time is given", context do
    assert context.limited["usageLimitResetAt"] == nil
    context
  end

  step "the turn shows it hit a usage limit that resets at {word}", %{args: [at]} = context do
    {:ok, reset, _} = DateTime.from_iso8601(at)
    {:ok, shown, _} = DateTime.from_iso8601(limited(context)["usageLimitResetAt"])
    assert DateTime.compare(shown, reset) == :eq
    context
  end

  step "the turn shows it hit a usage limit with no reset time given", context do
    assert limited(context)["usageLimitResetAt"] == nil
    context
  end

  # Fails the running fake's waiting prompt with `error` (see fake_acp.py).
  defp fail_waiting(context, error) do
    trace = context.fakes.logs["acp"]
    File.write!(trace <> ".stop", JSON.encode!(error))
    {_, 0} = System.cmd("kill", ["-USR1", File.read!(trace <> ".waiting")])
    context
  end

  defp limited(context) do
    World.await_row(context.running.thread, &(&1["lastErrorClass"] == "usage_limit"))
  end

  # OpenCode ends (or fails) the turn's loop as the steer lands, and answers it in a
  # loop of its own.
  step ~r/^an OpenCode turn is running that (?<how>ends|fails) as it is steered$/,
       %{args: [how]} = context do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(@thread, "opencode", "wait, it #{how} as steered")

    World.await_running(context, @thread)

    context
    |> Map.put(:running, %{thread: World.thread_id(context, @thread)})
    |> Map.put(:thread, @thread)
  end

  # A steer, as the composer sends one into the running turn. Its text says how the
  # fake answers it: "never answered", "keeps working" (a loop that runs until the
  # turn is stopped or steered again), "its loop fails".
  step "the user steers the OpenCode turn with {string}", %{args: [text]} = context do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "message.dispatch",
        "threadId" => context.running.thread,
        "messageId" => "steer-#{System.unique_integer([:positive])}",
        "text" => text,
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"},
        "deliveryIntent" => "steer"
      })

    context
  end

  # The steer's own loop started, after the turn's prompt answered: its message is
  # there and the turn still runs.
  step "OpenCode answers the turn's prompt and the message in a loop of its own", context do
    World.await_value(context, @thread, fn state ->
      Enum.any?(StreamState.list(state, "message"), &String.contains?(&1["id"], ":msg-steer"))
    end)

    World.await_runs(context, @thread, ["running"])
    context
  end

  step "the OpenCode turn is interrupted", context do
    World.await_runs(context, @thread, ["interrupted"])
    context
  end

  # The steer's loop ran last, so its failure is the turn's.
  step "the OpenCode turn fails with {string}", %{args: [error]} = context do
    World.await_runs(context, @thread, ["failed"])

    assert Enum.any?(
             StreamState.list(World.stream(context, @thread), "provider-session"),
             &(&1["lastError"] == error)
           )

    context
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

  # The turn waits for the steer's own loop, so its answer is recorded in the turn.
  step "OpenCode's answer to the message is the turn's", context do
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

  # --- tool calls ------------------------------------------------------------------------

  # A tool as OpenCode's ACP mode reports it: announced by name with no input, then
  # running with its input, then done with `done`'s fields.
  defp opencode_tool(id, kind, name, input, done, locations \\ []) do
    [
      %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => id,
        "title" => name,
        "kind" => kind,
        "status" => "pending",
        "rawInput" => %{},
        "locations" => locations
      },
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => id,
        "status" => "in_progress",
        "rawInput" => input
      },
      Map.merge(%{"sessionUpdate" => "tool_call_update", "toolCallId" => id}, done)
    ]
  end

  defp completed(output, metadata \\ %{}),
    do: %{
      "status" => "completed",
      "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => output}}],
      "rawOutput" => %{"output" => output, "metadata" => metadata}
    }

  # `later`: scripted turns of their own for messages sent afterwards, `%{match => updates}`.
  defp run_tools(context, updates, later \\ %{}) do
    turns =
      for {match, updates} <- Map.put(later, "use the tools", updates),
          do: %{
            "match" => match,
            "steps" => Enum.map(updates, &%{"update" => &1}) ++ [%{"text" => "Done."}]
          }

    context =
      context
      |> FakeAcp.install("opencode", %{"turns" => turns ++ FakeAcp.turns()}, enabled: true)
      |> FakeAcp.thread(@thread)
      |> FakeAcp.send_message("use the tools")

    FakeAcp.await_run(context, "completed")
    context
  end

  defp tool_items(context, type) do
    World.thread_id(context, @thread)
    |> HalC2.Streams.state()
    |> StreamState.list("turn-item")
    |> Enum.filter(&(&1["type"] == type))
  end

  # --- approval kinds ---

  # What OpenCode asks before each kind of work: OpenCode 1 names the permission in
  # the title, OpenCode 2 names the tool doing it and the paths it reaches.
  @asks %{
    "edit, write or patch a file" => [
      %{"title" => "edit", "kind" => "edit", "locations" => [%{"path" => "src/app.ts"}]},
      %{
        "name" => "apply_patch",
        "title" => "src/app.ts",
        "kind" => "edit",
        "locations" => [%{"path" => "src/app.ts"}]
      }
    ],
    "read or search files" => [
      %{
        "name" => "read",
        "title" => ".env",
        "kind" => "read",
        "rawInput" => %{"filePath" => ".env"},
        "locations" => [%{"path" => ".env"}]
      },
      %{
        "name" => "grep",
        "title" => "TODO",
        "kind" => "search",
        "rawInput" => %{"pattern" => "TODO", "path" => "/srv/shared"},
        "locations" => [%{"path" => "/srv/shared"}]
      }
    ],
    "work outside the project folder" => [
      %{
        "title" => "external_directory",
        "kind" => "other",
        "rawInput" => %{"filepath" => "/srv/shared/notes.md", "parentDir" => "/srv/shared"}
      },
      %{
        "name" => "read",
        "title" => "/srv/shared/notes.md",
        "kind" => "read",
        "locations" => [%{"path" => "/srv/shared/notes.md"}]
      }
    ],
    "do anything else" => [
      %{"title" => "webfetch", "kind" => "other", "rawInput" => %{"url" => "https://x.dev"}},
      %{"name" => "webfetch", "title" => "https://x.dev", "kind" => "fetch"},
      %{"name" => "task", "title" => "Look around", "kind" => "think"}
    ],
    ~s(the "bash" permission without saying what for) => [
      %{"name" => "bash", "title" => "bash", "kind" => "execute"}
    ]
  }

  @kinds %{
    "a file change" => "file-change",
    "a file read" => "file-read",
    "a command" => "command"
  }

  step ~r/^OpenCode asks for (?:permission to (?<action>.+)|(?<permission>the "bash" permission without saying what for))$/,
       %{args: args} = context do
    what = Enum.find(args, &(&1 not in [nil, ""]))
    asks = Map.fetch!(@asks, what)

    steps =
      for {call, n} <- Enum.with_index(asks, 1),
          do: %{"permission" => Map.put(call, "toolCallId", "ask-#{n}")}

    context =
      FakeAcp.configure(context, fn config ->
        Map.update(
          config,
          "turns",
          [],
          &[%{"match" => "ask first", "steps" => steps ++ [%{"text" => "Done."}]} | &1]
        )
      end)

    context
    |> FakeAcp.send_message("ask first")
    |> Map.put(:asks, length(asks))
  end

  # Each ask is answered in turn; the next comes once the last was.
  defp approvals(context) do
    approvals =
      for _ <- 1..context.asks do
        request = FakeAcp.await_request(context)
        FakeAcp.respond(context, request["id"], %{"decision" => "accept"})

        World.await_stream(World.thread_id(context, @thread), fn state ->
          StreamState.get(state, "runtime-request")[request["id"]]["status"] != "pending"
        end)

        request
      end

    FakeAcp.await_run(context, "completed")
    approvals
  end

  step ~r/^the user is asked to approve (?<kind>a file change|a file read|a command)$/,
       %{args: [kind]} = context do
    expected = Map.fetch!(@kinds, kind)
    assert Enum.map(approvals(context), & &1["kind"]) == List.duplicate(expected, context.asks)
    context
  end

  step "the approval's text is {string}", %{args: [text]} = context do
    approvals(context)

    assert [%{"prompt" => ^text, "requestKind" => "command"}] =
             tool_items(context, "approval_request")

    context
  end

  # --- compaction ---

  # OpenCode 2 reports a compaction in the session's info (`opencode/compaction`).
  defp compaction(status, extra \\ %{}),
    do: %{
      "update" => %{
        "sessionUpdate" => "session_info_update",
        "_meta" => %{
          "opencode/compaction" => Map.merge(%{"status" => status, "messageId" => "msg_c"}, extra)
        }
      }
    }

  defp compacting(context, match, steps) do
    context
    |> FakeAcp.install("opencode", %{"turns" => [%{"match" => match, "steps" => steps}]},
      enabled: true
    )
    |> FakeAcp.thread(@thread)
  end

  step ~r{^the user sends "/compact" by itself to an OpenCode thread$}, context do
    context
    |> compacting("/compact", [compaction("started"), compaction("completed")])
    |> FakeAcp.send_message("/compact")
  end

  step "OpenCode summarizes its session", context do
    FakeAcp.await_run(context, "completed")
    # OpenCode runs a prompt of "/compact" alone as a compaction of the session.
    assert [%{"params" => %{"prompt" => [%{"type" => "text", "text" => "/compact"}]}}] =
             FakeAcp.received(context, "session/prompt")

    context
  end

  @summary_failure "The model could not summarize the conversation"

  step ~r{^the user sends "/compact" by itself and OpenCode cannot summarize the session$},
       context do
    context
    |> compacting("/compact", [
      compaction("started"),
      compaction("failed", %{"error" => @summary_failure}),
      %{"error" => %{"code" => -32603, "message" => @summary_failure}}
    ])
    |> FakeAcp.send_message("/compact")
  end

  step "the turn fails with OpenCode's reason", context do
    state = FakeAcp.await_run(context, "failed")

    assert Enum.any?(
             StreamState.list(state, "provider-session"),
             &(&1["lastError"] == @summary_failure)
           )

    refute Enum.any?(tool_items(context, "compaction"))
    context
  end

  step "OpenCode compacts its session by itself during a turn", context do
    twice = [compaction("started"), compaction("completed")]

    context
    |> compacting(
      "long work",
      [%{"text" => "Working."}] ++ twice ++ twice ++ [%{"text" => "Done."}]
    )
    |> FakeAcp.send_message("long work")
  end

  step "the work log shows \"Context compacted\" once for that turn", context do
    FakeAcp.await_run(context, "completed")

    assert [%{"title" => "Context compacted", "status" => "completed"}] =
             tool_items(context, "compaction")

    context
  end

  # --- binary path ---

  # The scenario's `$HOME` is a folder with a space in its name, and the setting keeps the
  # `~` the user typed.
  step ~r/^OpenCode's binary path is set to "(?<path>~[^"]*)", a wrapper in a home folder with spaces in its name$/,
       %{args: [path]} = context do
    home = HalC2.Test.Mc.Host.path(context, "/home/sam smith")
    File.mkdir_p!(home)
    previous = System.get_env("HOME")
    System.put_env("HOME", home)
    ExUnit.Callbacks.on_exit(fn -> System.put_env("HOME", previous) end)

    "~" <> rest = path

    context =
      FakeAcp.install(context, "opencode", models(@connected),
        enabled: true,
        path: home <> rest
      )

    FakeAcp.settings(&put_in(&1, ["providers", "opencode", "binaryPath"], path))
    context
  end

  step "the MC checks OpenCode", context do
    Map.put(context, :entry, FakeAcp.probe("opencode"))
  end

  step "OpenCode is ready, with its version and models", context do
    assert %{"status" => "ready", "version" => "1.14.19", "models" => models} = context.entry
    assert Enum.map(models, & &1["slug"]) == Enum.map(@connected, &elem(&1, 0))
    context
  end

  step "its turns run that wrapper", context do
    context = context |> FakeAcp.thread(@thread) |> FakeAcp.send_message("hello")
    FakeAcp.await_run(context, "completed")
    bin = FakeAcp.fake(context).bin

    assert [_ | _] = starts = for(s <- FakeAcp.starts(context), "acp" in s["argv"], do: s)
    assert Enum.all?(starts, &(&1["env"]["FAKE_BIN"] == bin))
    context
  end

  # --- updates ---

  # The latest OpenCode release, as if already read from the registry.
  @latest "1.15.0"

  defp latest(context) do
    :persistent_term.put(
      {HalC2.ProviderUpdates, "opencode"},
      {@latest, System.monotonic_time(:millisecond)}
    )

    ExUnit.Callbacks.on_exit(fn ->
      for key <- [
            {HalC2.ProviderUpdates, "opencode"},
            {HalC2.ProviderUpdates, "opencode", :state},
            {HalC2.ProviderUpdates, "opencode", :offered}
          ],
          do: :persistent_term.erase(key)
    end)

    context
  end

  # A shell line that makes the fake report the latest version from now on.
  defp upgrades(dir),
    do:
      ~s|python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["version"]="#{@latest}"; json.dump(c,open(p,"w"))' '#{Path.join(dir, "config.json")}'|

  # OpenCode's own installer keeps it in `~/.opencode/bin`, and `opencode upgrade`
  # updates it in place.
  step "the opencode command on the MC is OpenCode's own install under the user's home",
       context do
    bin = Path.join(HalC2.Test.Mc.Host.home(context), ".opencode/bin/opencode")

    context =
      context
      |> latest()
      |> FakeAcp.install("opencode", models(@connected), enabled: true, path: bin)

    %{dir: dir, script: script} = FakeAcp.fake(context)

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{dir}' FAKE_BIN="$0"
    if [ "$1" = upgrade ]; then
      echo "$@" >> '#{Path.join(dir, "updates.log")}'
      #{upgrades(dir)}
      exit 0
    fi
    exec python3 -u '#{script}' "$@"
    """)

    context
  end

  # A global npm prefix: `bin/opencode` links into `lib/node_modules/opencode-ai`, and
  # its npm logs what it was asked and installs the latest.
  step "the opencode command on the MC was installed with npm", context do
    prefix = HalC2.Test.Mc.Host.path(context, "/usr/local")
    real = Path.join(prefix, "lib/node_modules/opencode-ai/bin/opencode")
    link = Path.join(prefix, "bin/opencode")

    context =
      context
      |> latest()
      |> FakeAcp.install("opencode", models(@connected), enabled: true, path: real)

    %{dir: dir} = FakeAcp.fake(context)
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(real, link)
    FakeAcp.settings(&put_in(&1, ["providers", "opencode", "binaryPath"], link))
    npm = Path.join(prefix, "bin/npm")

    File.write!(npm, """
    #!/bin/sh
    echo "$@" >> '#{Path.join(prefix, "npm.log")}'
    #{upgrades(dir)}
    """)

    File.chmod!(npm, 0o755)
    Map.put(context, :npm_prefix, prefix)
  end

  step "the user updates OpenCode from HAL-C2", context do
    {reply, context} =
      World.call_keeping(context, "server.updateProvider", %{"provider" => "opencode"})

    Map.put(context, :reply, reply)
  end

  step "OpenCode's own upgrade command is run", context do
    assert File.read!(Path.join(FakeAcp.fake(context).dir, "updates.log")) == "upgrade\n"
    updated(context)
  end

  step "the opencode-ai package is updated by npm", context do
    prefix = context.npm_prefix

    assert File.read!(Path.join(prefix, "npm.log")) ==
             "install -g --prefix #{prefix} opencode-ai@latest\n"

    updated(context)
  end

  # The update succeeded and OpenCode now reports the latest version.
  defp updated(context) do
    assert {:ok, %{"providers" => providers}} = context.reply
    opencode = FakeAcp.find(providers, "opencode")
    assert %{"version" => @latest, "updateState" => %{"status" => "succeeded"}} = opencode
    assert opencode["versionAdvisory"]["status"] == "current"
    context
  end

  # A thread's OpenCode is running, started at 1.14.19, when the CLI on disk is upgraded.
  step "OpenCode was upgraded on disk to 1.15.0 while its running server still reports 1.14.19",
       context do
    context =
      context
      |> latest()
      |> FakeAcp.install("opencode", models(@connected), enabled: true)
      |> FakeAcp.thread(@thread)
      |> FakeAcp.send_message("hello")

    FakeAcp.await_run(context, "completed")
    assert FakeAcp.probe("opencode")["version"] == "1.14.19"
    assert [_] = serving(context)
    FakeAcp.configure(context, &Map.put(&1, "version", @latest))
  end

  step "the user checks for provider updates", context do
    {reply, context} =
      World.call_keeping(context, "server.refreshProviders", %{
        "instanceId" => "opencode",
        "refreshModels" => true
      })

    assert {:ok, %{"providers" => providers}} = reply
    Map.put(context, :providers, providers)
  end

  step "OpenCode is shown as 1.15.0 and up to date", context do
    opencode = FakeAcp.find(context.providers, "opencode")
    assert opencode["version"] == @latest
    assert opencode["versionAdvisory"]["status"] == "current"
    context
  end

  step "the running server is not restarted to find out", context do
    context = FakeAcp.send_message(context, "again")
    FakeAcp.await_runs(context, 2)
    assert [_] = serving(context)
    context
  end

  # The OpenCode processes that served the thread: those in the project, not the
  # throwaway ones that read its version and models.
  defp serving(context) do
    root = World.project(context).root
    for(start <- FakeAcp.starts(context), start["cwd"] == root, "acp" in start["argv"], do: start)
  end

  # --- subagents ---

  step "an OpenCode session is started", context do
    context =
      context
      |> FakeAcp.install("opencode", %{}, enabled: true)
      |> FakeAcp.thread(@thread)
      |> FakeAcp.send_message("hello")

    FakeAcp.await_run(context, "completed")
    context
  end

  step "its task permission is denied, through the config OpenCode is started with", context do
    assert [%{"permission" => %{"task" => "deny"}}] = started_configs(context)
    context
  end

  step "OpenCode is started with its own config", context do
    assert started_configs(context) == [nil]
    context
  end

  # The `OPENCODE_CONFIG_CONTENT` each OpenCode ACP process was started with.
  defp started_configs(context) do
    for(
      %{"start" => %{"env" => env, "argv" => argv}} <- FakeAcp.log(context),
      "acp" in argv,
      do: env["OPENCODE_CONFIG_CONTENT"] && JSON.decode!(env["OPENCODE_CONFIG_CONTENT"])
    )
    |> Enum.uniq()
  end

  # --- to-do list ---

  defp todos(entries) do
    %{
      "sessionUpdate" => "plan",
      "entries" =>
        for(
          {text, status} <- entries,
          do: %{"content" => text, "status" => status, "priority" => "medium"}
        )
    }
  end

  defp todo_lists(context) do
    World.thread_id(context, @thread)
    |> HalC2.Streams.state()
    |> StreamState.list("plan")
    |> Enum.filter(&(&1["kind"] == "todo_list"))
  end

  step "OpenCode updates its to-do list with one item in progress and one done", context do
    done = [{"Write the test", "completed"}, {"Read the code", "completed"}]

    run_tools(
      context,
      [todos([{"Write the test", "in_progress"}, {"Read the code", "completed"}])],
      %{"finish the list" => [todos([{"Write the test", "pending"} | tl(done)]), todos(done)]}
    )
  end

  # The thread's list, as clients title a `todo_list` item.
  step "the thread shows a \"Todo list\" with one step running and one done", context do
    assert [%{"steps" => steps}] = tool_items(context, "todo_list")

    assert Enum.map(steps, &{&1["text"], &1["status"]}) ==
             [{"Write the test", "running"}, {"Read the code", "completed"}]

    assert [%{"status" => "active"}] = todo_lists(context)
    context
  end

  step "the list is finished only once every item is done", context do
    context = FakeAcp.send_message(context, "finish the list")
    FakeAcp.await_runs(context, 2)
    assert [first, second] = Enum.sort_by(todo_lists(context), & &1["createdAt"])
    # The next turn's list replaces the unfinished one, and finishes once all is done.
    assert first["status"] == "superseded" and second["status"] == "completed"
    context
  end

  step "OpenCode runs a shell command", context do
    run_tools(
      context,
      opencode_tool("bash-1", "execute", "bash", %{"command" => "ls src"}, %{
        "title" => "List the sources",
        "status" => "completed",
        "content" => [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "app.ts\n"}}
        ],
        "rawOutput" => %{
          "output" => "app.ts\n",
          "metadata" => %{"exit" => 0, "output" => "app.ts\n", "description" => "List"}
        }
      })
    )
  end

  step "OpenCode edits, writes or patches a file", context do
    diff = %{"type" => "diff", "path" => "src/app.ts", "oldText" => "a", "newText" => "b"}

    run_tools(
      context,
      opencode_tool(
        "edit-1",
        "edit",
        "edit",
        %{"filePath" => "src/app.ts", "oldString" => "a", "newString" => "b"},
        %{"status" => "completed", "content" => [diff]},
        [%{"path" => "src/app.ts"}]
      )
    )
  end

  step "OpenCode fetches a web page or searches the web", context do
    run_tools(
      context,
      opencode_tool(
        "fetch-1",
        "fetch",
        "webfetch",
        %{"url" => "https://example.com/docs"},
        completed("the docs")
      ) ++
        opencode_tool(
          "web-1",
          "other",
          "websearch",
          %{"query" => "opencode acp"},
          completed("results")
        )
    )
  end

  step "OpenCode reads a file, searches files or asks the language server", context do
    run_tools(
      context,
      opencode_tool(
        "read-1",
        "read",
        "read",
        %{"filePath" => "src/app.ts"},
        completed("1: a"),
        [%{"path" => "src/app.ts"}]
      ) ++
        opencode_tool("grep-1", "search", "grep", %{"pattern" => "TODO"}, completed("none")) ++
        opencode_tool(
          "lsp-1",
          "other",
          "lsp",
          %{"operation" => "hover", "filePath" => "src/app.ts"},
          completed("a: string"),
          [%{"path" => "src/app.ts"}]
        )
    )
  end

  step "OpenCode uses any other tool", context do
    run_tools(
      context,
      opencode_tool("skill-1", "other", "skill", %{"name" => "greet"}, completed("loaded"))
    )
  end

  step "the thread shows a command with its output and exit code", context do
    assert [command] = tool_items(context, "command_execution")

    assert %{"input" => "ls src", "status" => "completed", "exitCode" => 0} = command
    assert command["output"] =~ "app.ts"
    context
  end

  step "the thread shows a file change with the file and its diff", context do
    assert [%{"fileName" => "src/app.ts", "diffStr" => diff, "status" => "completed"}] =
             tool_items(context, "file_change")

    assert diff =~ "--- before\na\n+++ after\nb"
    context
  end

  step "the thread shows a web search with what it looked for", context do
    patterns = for item <- tool_items(context, "web_search"), do: item["patterns"]
    assert patterns == [["https://example.com/docs"], ["opencode acp"]]
    context
  end

  step "the thread shows a file search with what it looked for", context do
    assert [read, grep, lsp] = tool_items(context, "file_search")
    assert %{"pattern" => "src/app.ts", "results" => [%{"fileName" => "src/app.ts"}]} = read
    assert grep["pattern"] == "TODO"
    assert %{"results" => [%{"fileName" => "src/app.ts"}]} = lsp
    assert tool_items(context, "dynamic_tool") == []
    context
  end

  step "the thread shows a tool call with its input and output", context do
    assert [%{"toolName" => "skill", "input" => %{"name" => "greet"}, "output" => "loaded"}] =
             tool_items(context, "dynamic_tool")

    context
  end

  step "OpenCode runs {string} and it exits with code {int}",
       %{args: [command, code]} = context do
    run_tools(
      context,
      opencode_tool("bash-1", "execute", "bash", %{"command" => command}, %{
        "status" => "completed",
        "content" => [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "1 test failed\n"}}
        ],
        "rawOutput" => %{
          "output" => "1 test failed\n",
          "metadata" => %{"exit" => code, "output" => "1 test failed\n"}
        }
      })
    )
    |> Map.put(:command, command)
  end

  step "the thread shows the command as failed with exit code {int}",
       %{args: [code]} = context do
    input = context.command

    assert [%{"input" => ^input, "status" => "failed", "exitCode" => ^code}] =
             tool_items(context, "command_execution")

    context
  end

  step "an agent reading the thread is told the command failed", context do
    {:ok, %{"items" => items}} =
      World.mcp_tool(
        context,
        @thread,
        "hal_c2_thread_read",
        %{"threadId" => World.thread_id(context, @thread), "view" => "activity"},
        "opencode"
      )

    assert [%{"status" => "failed"}] = Enum.filter(items, &(&1["type"] == "command_execution"))
    context
  end

  # A tool of each kind as OpenCode 1 runs it, and the item type the thread shows it as.
  @stopped_tools %{
    "a command" =>
      {"command_execution",
       %{
         "toolCallId" => "stop-1",
         "title" => "bash",
         "kind" => "execute",
         "rawInput" => %{"command" => "npm test"},
         "content" => [
           %{"type" => "content", "content" => %{"type" => "text", "text" => "running 3 tests"}}
         ]
       }},
    "a file edit" =>
      {"file_change",
       %{
         "toolCallId" => "stop-1",
         "title" => "edit",
         "kind" => "edit",
         "rawInput" => %{"filePath" => "src/app.ts"},
         "locations" => [%{"path" => "src/app.ts"}]
       }},
    "a subagent task" =>
      {"subagent",
       %{
         "toolCallId" => "stop-1",
         "title" => "task",
         "kind" => "other",
         "rawInput" => %{
           "description" => "Look around",
           "prompt" => "find the bug",
           "subagent_type" => "general"
         }
       }}
  }

  step ~r/^an OpenCode 1 turn is running (?<tool>a command|a file edit|a subagent task)$/,
       %{args: [tool]} = context do
    {type, call} = @stopped_tools[tool]
    aborted = "Tool execution aborted"

    turn = %{
      "match" => "run the tool",
      "steps" => [
        %{
          "update" =>
            call
            |> Map.delete("content")
            |> Map.merge(%{"sessionUpdate" => "tool_call", "status" => "in_progress"})
        },
        %{
          "update" =>
            Map.merge(call, %{"sessionUpdate" => "tool_call_update", "status" => "in_progress"})
        },
        %{
          "waitCancel" => true,
          # OpenCode 1 rewrites the tool it stopped as an error.
          "after" => [
            %{
              "sessionUpdate" => "tool_call_update",
              "toolCallId" => call["toolCallId"],
              "status" => "failed",
              "content" => [
                %{"type" => "content", "content" => %{"type" => "text", "text" => aborted}}
              ],
              "rawOutput" => %{"error" => aborted}
            }
          ]
        }
      ]
    }

    context =
      context
      |> FakeAcp.install("opencode", %{"turns" => [turn | FakeAcp.turns()]}, enabled: true)
      |> FakeAcp.thread(@thread)
      |> FakeAcp.send_message("run the tool")

    # Running, with its output so far.
    World.await_stream(World.thread_id(context, @thread), fn state ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["type"] == type and (type != "command_execution" or &1["output"] != ""))
      )
    end)

    Map.put(context, :stopped_tool, type)
  end

  step ~r/^(?:a command|a file edit|a subagent task) shows as interrupted, not failed$/,
       context do
    FakeAcp.await_run(context, "interrupted")
    assert [%{"status" => "interrupted"}] = tool_items(context, context.stopped_tool)

    for subagent <- subagents(context),
        do: assert(subagent["status"] == "interrupted")

    context
  end

  step "no error text is shown as its output or diff", context do
    [item] = tool_items(context, context.stopped_tool)
    shown = Enum.map(subagents(context), &JSON.encode!/1)
    refute JSON.encode!([item | shown]) =~ "aborted"

    if context.stopped_tool == "command_execution",
      do: assert(item["output"] =~ "running 3 tests")

    context
  end

  defp subagents(context) do
    World.thread_id(context, @thread)
    |> HalC2.Streams.state()
    |> StreamState.list("subagent")
  end

  # OpenCode's ACP mode reports the abort as the prompt's `cancelled` end.
  step "the user stops the turn and OpenCode reports it aborted", context do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @thread)
      })

    context
  end

  step "the turn is shown as interrupted", context do
    World.await_runs(context, @thread, ["interrupted"])

    refute Enum.any?(
             StreamState.list(
               HalC2.Streams.state(World.thread_id(context, @thread)),
               "turn-item"
             ),
             &(&1["type"] == "error")
           )

    context
  end

  # --- the server's owner ---------------------------------------------------------------

  # The thread's `opencode acp --port` process serves its HTTP API; the thread's runtime
  # owns it through its connection.
  step "an OpenCode server was started for a thread", context do
    context = context |> World.fake_providers() |> World.launch_on(@thread, "opencode", "hello")
    World.await_idle(context, @thread)
    [{runtime, _}] = Registry.lookup(HalC2.Acp.Registry, World.thread_id(context, @thread))
    %{conn: conn, server: %{url: url}} = :sys.get_state(runtime)
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(conn).sub)
    assert alive?(os_pid)
    assert {:ok, socket} = connect(url)
    :gen_tcp.close(socket)

    Map.put(context, :opencode_server, %{runtime: runtime, conn: conn, os_pid: os_pid, url: url})
  end

  step "the provider process that owned it crashes", context do
    %{runtime: runtime, conn: conn} = context.opencode_server
    refs = Enum.map([runtime, conn], &Process.monitor/1)
    Process.exit(runtime, :kill)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
    context
  end

  step "the OpenCode server is stopped", context do
    %{os_pid: os_pid, url: url} = context.opencode_server
    refute alive?(os_pid)
    assert {:error, :econnrefused} = connect(url)
    context
  end

  step "no OpenCode process stays owned by the thread", context do
    HalC2.Test.Mc.settle_registry(HalC2.Acp.Registry)
    assert Registry.lookup(HalC2.Acp.Registry, World.thread_id(context, @thread)) == []
    refute Process.alive?(context.opencode_server.conn)
    context
  end

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp connect(url) do
    %URI{host: host, port: port} = URI.parse(url)
    :gen_tcp.connect(to_charlist(host), port, [], 1_000)
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
    three_turns(context)
  end

  # OpenCode compacted the session between the second turn and the third: a user
  # message whose only part is the compaction, and the summary it answered with. Each
  # version's compaction lacks fields a newer client requires (2.1 the part's `auto`,
  # 2.2 its `overflow`), so the MC must read them as they come.
  step ~r/^an OpenCode (?<version>2\.[12]) thread with three turns whose session OpenCode compacted$/,
       %{args: [version]} = context do
    context = three_turns(context)
    {source, turns} = context.opencode

    part =
      if version == "2.1",
        do: %{"type" => "compaction"},
        else: %{"type" => "compaction", "auto" => true}

    file = Path.join([context.fakes.dir, "opencode-sessions", "#{source}.json"])
    messages = file |> File.read!() |> JSON.decode!()
    {before, rest} = Enum.split_while(messages, &(&1["info"]["id"] != turns[3]))

    compaction = [
      %{
        "info" => %{"id" => "msg_compaction", "role" => "user", "sessionID" => source},
        "parts" => [part]
      },
      %{
        "info" => %{
          "id" => "msg_summary",
          "role" => "assistant",
          "sessionID" => source,
          "summary" => true
        },
        "parts" => [%{"type" => "text", "text" => "The story so far."}]
      }
    ]

    File.write!(file, JSON.encode!(before ++ compaction ++ rest))
    context
  end

  # The session file of the thread's OpenCode session, rewritten by `fun`.
  defp edit_session(context, fun) do
    {source, turns} = context.opencode
    file = Path.join([context.fakes.dir, "opencode-sessions", "#{source}.json"])

    file
    |> File.read!()
    |> JSON.decode!()
    |> fun.(turns)
    |> JSON.encode!()
    |> then(&File.write!(file, &1))

    context
  end

  step "OpenCode no longer has the message to return to", context do
    context
    |> three_turns()
    |> edit_session(fn messages, turns ->
      Enum.reject(messages, &(&1["info"]["id"] == turns[2]))
    end)
  end

  step "OpenCode's rewound session kept the wrong turns", context do
    context
    |> three_turns()
    |> edit_session(fn [first | rest], _turns ->
      [put_in(first, ["info", "lostOnFork"], true) | rest]
    end)
  end

  step ~r/^the user reverts (?:an earlier turn|to that turn)$/, context do
    World.rollback(context, @thread, 1, %{"restoreFiles" => false})
  end

  @refusals %{
    "the thread cannot be rolled back while a turn is active" =>
      "Interrupt the current turn before rewinding.",
    "the OpenCode rewind boundary is no longer available" =>
      "The OpenCode rewind boundary is no longer available.",
    "OpenCode did not preserve the requested rewind boundary" =>
      "OpenCode did not preserve the requested rewind boundary."
  }

  step ~r/^it is refused with a message that (?<says>.+)$/, %{args: [says]} = context do
    # The MC names the provider thread it could not roll back ahead of OpenCode's reason.
    assert {:error, message} = context.reply
    assert String.ends_with?(message, Map.fetch!(@refusals, says))
    context
  end

  step "an OpenCode thread that was reverted to its first turn", context do
    context = context |> three_turns() |> World.rollback(@thread, 1, %{"restoreFiles" => false})
    assert {:ok, _} = context.reply
    context
  end

  # The MC keeps the thread's history itself; OpenCode's session is read again when the
  # thread's next turn opens it.
  step "the MC restarts and reads the thread back from OpenCode", context do
    context = %{context | mc: HalC2.Test.Mc.restart(context.mc), clients: %{}}
    send_turn(context, @thread, "where are we")
  end

  step "the turns after the first are not shown again", context do
    {source, turns} = context.opencode
    shown = for run <- World.runs(context, @thread), run["status"] != "rolled_back", do: run

    assert length(shown) == 2
    {fork, kept} = native(context, @thread)
    assert fork != source and kept[1] != turns[1]
    assert %{"sessionId" => ^fork} = last_prompt(context)
    assert {_, ["first", "where are we"]} = session(context, fork)
    context
  end

  # --- session titles ---

  step ~r/^the thread "(?<title>[^"]+)" (?:starts|runs) on OpenCode$/,
       %{args: [title]} = context do
    context
    |> World.fake_providers()
    |> World.run_turns(title, "opencode", ["hello"])
    |> Map.put(:thread, title)
  end

  step "the thread is renamed {string} and the user sends a message",
       %{args: [title]} = context do
    context |> rename(%{"title" => title}) |> send_turn(context.thread, "and now")
  end

  defp rename(context, %{"title" => title}) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "commandId" => "cmd-rename-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread),
        "title" => title
      })

    context
  end

  defp session_title(context) do
    {session, _} = native(context, context.thread)
    File.read!(Path.join([context.fakes.dir, "opencode-sessions", "#{session}.title"]))
  end

  # The trace, in order: each title OpenCode's server was given and each prompt sent.
  defp titles_and_prompts(context) do
    for entry <- World.provider_log(context, "acp"),
        item = title_or_prompt(entry),
        do: item
  end

  defp title_or_prompt(%{"http" => %{"method" => "PATCH", "body" => %{"title" => title}}}),
    do: {:title, title}

  defp title_or_prompt(%{"in" => %{"method" => "session/prompt"}}), do: :prompt
  defp title_or_prompt(_entry), do: nil

  step ~r/^its OpenCode session is titled "(?<title>[^"]+)"$/, %{args: [title]} = context do
    assert session_title(context) == title
    context
  end

  # The fake writes a title of its own at a prompt to a session still untitled.
  step "OpenCode does not write a title of its own", context do
    assert [{:title, title}, :prompt] = titles_and_prompts(context)
    assert session_title(context) == title
    context
  end

  step ~r/^its OpenCode session is titled "(?<title>[^"]+)" before the message reaches OpenCode$/,
       %{args: [title]} = context do
    assert session_title(context) == title
    assert [{:title, _first}, :prompt, {:title, ^title}, :prompt] = titles_and_prompts(context)
    context
  end

  step "a turn under an unchanged name does not retitle the session", context do
    before = titles_and_prompts(context)
    context = send_turn(context, context.thread, "still here")
    assert titles_and_prompts(context) == before ++ [:prompt]
    context
  end

  step "a title that cannot be written does not fail the turn", context do
    kept = session_title(context)

    context =
      context
      |> rename(%{"title" => "an unwritable name"})
      |> send_turn(context.thread, "go on")

    assert List.last(World.runs(context, context.thread))["status"] == "completed"
    assert session_title(context) == kept
    context
  end

  step "the user forks from the second turn and sends a message", context do
    # The fork's first message is what opens OpenCode's fork; the outcome sends it.
    World.fork(context, World.current_thread(context), 2, "fork")
  end

  defp three_turns(context) do
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
