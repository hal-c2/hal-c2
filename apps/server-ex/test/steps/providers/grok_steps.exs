defmodule HalC2.Steps.Providers.Grok do
  @moduledoc """
  Steps for `features/providers/grok.feature`: Grok as an ACP agent, played by the
  scripted fake (`HalC2.Test.FakeAcp`) behind the instance's binary path.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc.World

  @models [
    %{"value" => "grok-code-fast-1", "name" => "Grok Code Fast"},
    %{"value" => "grok-4", "name" => "Grok 4"}
  ]

  @child_session "0f8e2a4c-5b6d-4e7f-8a9b-1c2d3e4f5a6b"

  defp signed_in_config,
    do: %{
      "configOptions" => [
        %{
          "id" => "model",
          "name" => "Model",
          "type" => "select",
          "currentValue" => "grok-code-fast-1",
          "options" => @models
        }
      ]
    }

  # --- enabling -------------------------------------------------------------------

  step "Grok is installed but not enabled", context do
    FakeAcp.install(context, "grok", signed_in_config())
  end

  step "no Grok process is started", context do
    # What the MC's boot runs, then a client reading the provider list.
    HalC2.Acp.load()
    assert %{"enabled" => false} = FakeAcp.entry("grok")
    assert FakeAcp.starts(context, "grok") == []
    context
  end

  step "the grok command is not installed on the MC", context do
    FakeAcp.services()
    HalC2.Acp.forget("grok")
    missing = Path.join(HalC2.Test.Mc.tmp_dir(context.mc, "no-grok"), "grok")
    FakeAcp.settings(&put_in(&1, ["providers"], %{"grok" => %{"binaryPath" => missing}}))
    Map.put(context, :provider, "grok")
  end

  # Shared by the Grok, OpenCode and Pi features.
  step "the user opens the list of agents to enable", context do
    FakeAcp.services()
    {_, context} = FakeAcp.open_config(context)
    context
  end

  step "Grok is not offered", context do
    assert context.providers != nil
    assert FakeAcp.find(context.providers, "grok") == nil
    context
  end

  step "the grok command is installed and signed in", context do
    FakeAcp.install(context, "grok", signed_in_config())
  end

  step "the grok command is installed but not signed in", context do
    FakeAcp.install(context, "grok", Map.put(signed_in_config(), "authRequired", true))
  end

  step "Grok's models are offered in the model picker", context do
    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"models" => [_ | _]}, FakeAcp.find(providers, "grok"))
      end)

    grok = FakeAcp.find(providers, "grok")
    assert grok["enabled"]
    assert Enum.map(grok["models"], & &1["slug"]) == ["grok-code-fast-1", "grok-4"]
    assert Enum.find(grok["models"], & &1["isDefault"])["slug"] == "grok-code-fast-1"
    context
  end

  step "Grok is shown as signed out with a hint to sign in", context do
    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"auth" => %{"status" => "unauthenticated"}}, FakeAcp.find(providers, "grok"))
      end)

    grok = FakeAcp.find(providers, "grok")
    assert grok["message"] =~ "grok login"
    context
  end

  # --- turns ----------------------------------------------------------------------

  step "the thread runs Grok with approval required", context do
    context
    |> FakeAcp.install("grok", signed_in_config(), enabled: true)
    |> FakeAcp.thread("Work", "approval-required")
  end

  step "Grok asks to run a command", context do
    FakeAcp.send_message(context, "please run a command")
  end

  step "the user's decision is sent back to Grok", context do
    request = context[:request] || FakeAcp.await_request(context)
    context = FakeAcp.respond(context, request["id"], %{"decision" => "accept"})
    FakeAcp.await_run(context, "completed")

    assert [%{"result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "once"}}}] =
             FakeAcp.answers(context)

    # Approval required is Grok's own default permission mode.
    assert [%{"argv" => [_ | args]}] = FakeAcp.starts(context)
    assert args == ["--permission-mode", "default", "agent", "stdio"]
    context
  end

  step "a Grok turn is running", context do
    context =
      context
      |> FakeAcp.install("grok", signed_in_config(), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("start a long task")

    FakeAcp.await_run(context, "running")
    await_answer(context)
    context
  end

  step "Grok is told to cancel the turn", context do
    FakeAcp.await_run(context, "interrupted")
    [%{"params" => %{"sessionId" => session}}] = FakeAcp.received(context, "session/cancel")
    [%{"params" => %{"sessionId" => ^session}} | _] = FakeAcp.received(context, "session/prompt")
    context
  end

  # --- text generation ------------------------------------------------------------

  step "Grok is picked for text generation", context do
    context = FakeAcp.install(context, "grok", signed_in_config(), enabled: true)

    FakeAcp.settings(
      &Map.put(&1, "textGenerationModelSelection", %{
        "instanceId" => "grok",
        "model" => "grok-code-fast-1"
      })
    )

    context
  end

  # --- usage ----------------------------------------------------------------------

  step "Grok has written transcripts on this machine", context do
    FakeAcp.services()
    HalC2.Test.Mc.ensure(HalC2.Usage)
    root = HalC2.Test.Mc.tmp_dir(context.mc, "homes")
    grok = Path.join(root, "grok")
    session = Path.join([grok, "sessions", "s-1"])
    File.mkdir_p!(session)

    line = %{
      "timestamp" => System.os_time(:millisecond),
      "params" => %{
        "sessionId" => "s-1",
        "update" => %{
          "sessionUpdate" => "turn_completed",
          "prompt_id" => "p-1",
          "usage" => %{
            "inputTokens" => 1_200,
            "cachedReadTokens" => 200,
            "outputTokens" => 300,
            "costUsdTicks" => 25_000_000_000
          }
        }
      }
    }

    File.write!(Path.join(session, "updates.jsonl"), JSON.encode!(line) <> "\n")

    # Only this scenario's homes are read, never the machine's own.
    FakeAcp.settings(fn settings ->
      settings
      |> Map.put("providers", %{
        "claudeAgent" => %{"homePath" => Path.join(root, "claude")},
        "codex" => %{"homePath" => Path.join(root, "codex")}
      })
      |> Map.put("providerInstances", %{
        "grok" => %{
          "driver" => "grok",
          "environment" => [%{"name" => "GROK_HOME", "value" => grok}]
        }
      })
    end)

    context
  end

  step "the user opens the usage summary", context do
    today = Date.utc_today() |> Date.to_iso8601()

    {summary, context} =
      World.call!(context, "server.getUsageSummary", %{
        "sinceDay" => today,
        "untilDay" => today,
        "timeZone" => "UTC"
      })

    Map.put(context, :usage, summary)
  end

  step "Grok's tokens and cost are included", context do
    buckets = for b <- context.usage["buckets"], b["provider"] == "grok", do: b
    assert [_ | _] = buckets, "no Grok usage in #{inspect(context.usage["buckets"])}"
    assert Enum.sum(Enum.map(buckets, & &1["totals"]["outputTokens"])) == 300
    assert Enum.sum(Enum.map(buckets, & &1["totals"]["cachedInputTokens"])) == 200

    assert_in_delta Enum.sum(Enum.map(buckets, &(&1["costUsd"] || &1["totals"]["costUsd"]))),
                    2.5,
                    0.001

    context
  end

  # --- backlog: sign-in, commands, reasoning ---------------------------------------

  step "the Grok instance has an xAI API key in its environment", context do
    context = FakeAcp.install(context, "grok", signed_in_config())

    FakeAcp.settings(
      &Map.put(&1, "providerInstances", %{
        "grok" => %{
          "driver" => "grok",
          "environment" => [%{"name" => "XAI_API_KEY", "value" => "xai-test-key"}]
        }
      })
    )

    context
  end

  step "Grok shows that it uses an xAI API key", context do
    grok = FakeAcp.find(context.providers, "grok")

    assert %{"status" => "authenticated", "type" => "api_key", "label" => "xAI API key"} =
             grok["auth"]

    context
  end

  step "the user types a slash in a Grok thread", context do
    config =
      Map.put(signed_in_config(), "initMeta", %{
        "availableCommands" => [
          %{"name" => "always-approve", "description" => "Approve every tool"},
          %{"name" => "context", "description" => "Show context usage"},
          %{
            "name" => "review",
            "description" => "Review the changes",
            "input" => %{"hint" => "path"}
          }
        ]
      })

    context = FakeAcp.install(context, "grok", config, enabled: true)

    {_, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"slashCommands" => [_, _ | _]}, FakeAcp.find(providers, "grok"))
      end)

    Map.put(context, :commands, FakeAcp.find(context.providers, "grok")["slashCommands"])
  end

  step "Grok's own always-approve command is not offered", context do
    names = Enum.map(context.commands, & &1["name"])
    refute "always-approve" in names
    # Grok's /context finishes without output, so it is left out too.
    refute "context" in names

    assert %{"description" => "Review the changes", "input" => %{"hint" => "path"}} =
             Enum.find(context.commands, &(&1["name"] == "review"))

    context
  end

  step ~r/^"\/(?<name>[a-z-]+)" is offered$/, %{args: [name]} = context do
    assert %{"description" => description} = Enum.find(context.commands, &(&1["name"] == name))
    assert description != ""
    context
  end

  step "the user opens the options for a Grok model that supports reasoning", context do
    config =
      Map.put(signed_in_config(), "initMeta", %{
        "modelState" => %{
          "currentModelId" => "grok-code-fast-1",
          "availableModels" => [
            %{"modelId" => "grok-code-fast-1", "name" => "Grok Code Fast"},
            %{
              "modelId" => "grok-4",
              "name" => "Grok 4",
              "_meta" => %{
                "reasoningEffort" => "high",
                "reasoningEfforts" => [
                  %{"value" => "low", "label" => "Low"},
                  %{"value" => "high", "label" => "High", "default" => true}
                ]
              }
            }
          ]
        }
      })

    context = FakeAcp.install(context, "grok", config, enabled: true)

    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"models" => [_ | _]}, FakeAcp.find(providers, "grok"))
      end)

    models = FakeAcp.find(providers, "grok")["models"]
    Map.merge(context, %{model: Enum.find(models, &(&1["slug"] == "grok-4")), models: models})
  end

  step "the reasoning levels Grok offers for that model are shown", context do
    assert %{"capabilities" => %{"optionDescriptors" => [descriptor]}} = context.model

    assert %{"id" => "reasoningEffort", "label" => "Reasoning", "type" => "select"} = descriptor
    assert descriptor["currentValue"] == "high"

    assert descriptor["options"] == [
             %{"id" => "low", "label" => "Low"},
             %{"id" => "high", "label" => "High", "isDefault" => true}
           ]

    # A model that advertises none has no reasoning option.
    assert Enum.find(context.models, &(&1["slug"] == "grok-code-fast-1"))["capabilities"] == nil
    context
  end

  # --- backlog: plans and questions -------------------------------------------------

  step "Grok proposes a plan", context do
    turns = [
      %{
        "match" => "plan the work",
        "steps" => [
          %{
            "request" => %{
              "method" => "x.ai/exit_plan_mode",
              "params" => %{
                "toolCallId" => "plan-1",
                "planContent" => "# Plan\n\n1. Add the form"
              }
            }
          }
        ]
      }
      | FakeAcp.turns()
    ]

    context =
      context
      |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("plan the work")

    FakeAcp.await_run(context, "completed")

    # Grok's own approval gate is abandoned so the turn ends here.
    assert [%{"result" => %{"outcome" => "abandoned", "feedback" => feedback}}] =
             FakeAcp.answers(context)

    assert feedback =~ "captured your proposed plan"
    Map.put(context, :expected_plan, "# Plan\n\n1. Add the form")
  end

  step "Grok asks the user a question", context do
    turns = [
      %{
        "match" => "pick a database",
        "steps" => [
          %{
            "request" => %{
              "method" => "x.ai/ask_user_question",
              "params" => %{
                "toolCallId" => "q-1",
                "mode" => "default",
                "questions" => [
                  %{
                    "question" => "Which database?",
                    "options" => [%{"label" => "Postgres"}, %{"label" => "SQLite"}]
                  }
                ]
              }
            }
          },
          %{"text" => "Using it."}
        ]
      }
      | FakeAcp.turns()
    ]

    context
    |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
    |> FakeAcp.thread("Work", "approval-required")
    |> FakeAcp.send_message("pick a database")
  end

  step "the question is shown and the answer is sent back to Grok", context do
    request = FakeAcp.await_request(context)
    assert request["kind"] == "user_input"

    item =
      World.await_stream(World.thread_id(context, context.thread), fn state ->
        state
        |> HalC2.StreamState.list("turn-item")
        |> Enum.find(&(&1["type"] == "user_input_request"))
      end)

    assert [%{"question" => "Which database?", "options" => options}] = item["questions"]
    assert Enum.map(options, & &1["label"]) == ["Postgres", "SQLite"]

    context =
      FakeAcp.respond(context, request["id"], %{"answers" => %{"Which database?" => "SQLite"}})

    FakeAcp.await_run(context, "completed")

    assert [
             %{
               "result" => %{
                 "outcome" => "accepted",
                 "answers" => %{"Which database?" => ["SQLite"]}
               }
             }
           ] =
             FakeAcp.answers(context)

    context
  end

  # --- backlog: rollback and limits -------------------------------------------------

  step "a Grok thread with two turns", context do
    context =
      context
      |> FakeAcp.install("grok", signed_in_config(), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("first")

    FakeAcp.await_runs(context, 1)
    context = FakeAcp.send_message(context, "second")
    FakeAcp.await_runs(context, 2)
    context
  end

  # The timeline offers reverting by what the thread's provider reports.
  step "the user looks at the first turn", context do
    {_, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"version" => "1.0.0"}, FakeAcp.find(providers, "grok"))
      end)

    context
  end

  step "reverting to it is not offered", context do
    assert %{"supportsConversationRollback" => false} = FakeAcp.find(context.providers, "grok")
    context
  end

  step "Grok stops because the account hit its usage limit", context do
    turns = [
      %{
        "match" => "keep going",
        "steps" => [%{"error" => %{"code" => -32003, "message" => "Rate limit exceeded"}}]
      }
    ]

    context
    |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
    |> FakeAcp.thread()
    |> FakeAcp.send_message("keep going")
  end

  step "the thread says Grok's usage limit was reached", context do
    state = FakeAcp.await_run(context, "failed")

    assert Enum.any?(
             HalC2.StreamState.list(state, "provider-session"),
             &(&1["lastError"] == "Grok usage limit reached. Try again later.")
           )

    context
  end

  # --- usage limits ---------------------------------------------------------------

  step "Grok is signed in with a Grok account", context do
    home = HalC2.Test.Mc.tmp_dir(context.mc, "grok-home")

    File.write!(
      Path.join(home, "auth.json"),
      JSON.encode!(%{
        "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828" => %{"key" => "grok-token"}
      })
    )

    context
    |> billing(%{
      "config" => %{
        "creditUsagePercent" => 42.5,
        "currentPeriod" => %{
          "type" => "USAGE_PERIOD_TYPE_MONTHLY",
          "end" => "2026-10-01T00:00:00Z"
        }
      }
    })
    |> FakeAcp.install("grok", signed_in_config(), enabled: true)
    |> grok_env([%{"name" => "GROK_HOME", "value" => home}])
  end

  step "Grok shows how much of its billing period is used and when it resets", context do
    assert %{"windows" => [window]} = FakeAcp.find(context.providers, "grok")["usageLimits"]

    assert window == %{
             "id" => "subscription",
             "kind" => "monthly",
             "label" => "Monthly",
             "usedPercent" => 42.5,
             "resetsAt" => "2026-10-01T00:00:00.000Z"
           }

    # Read with the Grok account's own sign-in.
    requests = HalC2.Test.FakeHttp.requests(context.billing)
    assert [_ | _] = requests

    assert Enum.all?(
             requests,
             &match?(%{"authorization" => "Bearer grok-token", "query" => "format=credits"}, &1)
           )

    context
  end

  step "the Grok instance uses an API key", context do
    # A signed-in account is on the machine too; the key is what Grok would use.
    home = HalC2.Test.Mc.tmp_dir(context.mc, "grok-home")
    key = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
    File.write!(Path.join(home, "auth.json"), JSON.encode!(%{key => %{"key" => "grok-token"}}))

    context
    |> billing(%{"config" => %{"creditUsagePercent" => 10}})
    |> FakeAcp.install("grok", signed_in_config(), enabled: true)
    |> grok_env([
      %{"name" => "GROK_HOME", "value" => home},
      %{"name" => "XAI_API_KEY", "value" => "xai-test-key"}
    ])
  end

  step "Grok's limits are shown as unsupported", context do
    assert %{"windows" => [], "unavailable" => %{"reason" => "unsupported"}} =
             FakeAcp.find(context.providers, "grok")["usageLimits"]

    assert HalC2.Test.FakeHttp.requests(context.billing) == []
    context
  end

  # --- models on refresh -----------------------------------------------------------

  defp model_config(slugs) do
    %{
      "configOptions" => [
        %{
          "id" => "model",
          "name" => "Model",
          "type" => "select",
          "currentValue" => hd(slugs),
          "options" => for(slug <- slugs, do: %{"value" => slug, "name" => slug})
        }
      ]
    }
  end

  @four ~w(grok-code-fast-1 grok-4 gateway-one gateway-two)

  step "Grok offered the models of a model gateway", context do
    context = FakeAcp.install(context, "grok", model_config(@four), enabled: true)
    {_, context} = await_models(context, @four)
    context
  end

  step "Grok offered four models", context do
    context = FakeAcp.install(context, "grok", model_config(@four), enabled: true)
    {_, context} = await_models(context, @four)
    context
  end

  step "Grok was disconnected from the gateway", context do
    FakeAcp.configure(context, fn config ->
      Map.merge(config, model_config(~w(grok-code-fast-1 grok-4)))
    end)
  end

  step "the user refreshes Grok", context do
    {reply, context} =
      World.call_keeping(context, "server.refreshProviders", %{
        "instanceId" => "grok",
        "refreshModels" => true
      })

    case reply do
      {:ok, %{"providers" => providers}} -> Map.put(context, :providers, providers)
      _ -> context
    end
  end

  step "only the models Grok now offers are in the model picker", context do
    {_, context} = await_models(context, ~w(grok-code-fast-1 grok-4))
    context
  end

  step "the MC checks Grok and Grok lists no models", context do
    FakeAcp.configure(context, fn config ->
      Map.put(config, "configOptions", [
        %{"id" => "model", "name" => "Model", "type" => "select", "options" => []}
      ])
    end)

    FakeAcp.probe("grok")
    context
  end

  step "the MC checks Grok and Grok fails to start a session", context do
    FakeAcp.configure(context, fn config ->
      Map.put(config, "sessionError", %{"code" => -32002, "message" => "no session"})
    end)

    FakeAcp.probe("grok")
    context
  end

  step "Grok shows a warning", context do
    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"status" => "warning"}, FakeAcp.find(providers, "grok"))
      end)

    assert FakeAcp.find(providers, "grok")["message"] =~ "Model options may be incomplete"
    context
  end

  step "the four models are still offered", context do
    grok = FakeAcp.find(context.providers, "grok") || FakeAcp.entry("grok")
    assert Enum.map(grok["models"], & &1["slug"]) == @four
    context
  end

  defp await_models(context, slugs) do
    FakeAcp.await_providers(context, fn providers ->
      case FakeAcp.find(providers, "grok") do
        %{"models" => models} -> Enum.map(models, & &1["slug"]) == slugs
        _ -> false
      end
    end)
  end

  # --- sign-in refreshing ----------------------------------------------------------

  step "Grok's sign-in expired and Grok is refreshing it", context do
    config =
      Map.put(signed_in_config(), "sessionErrorOnce", %{
        "code" => -32000,
        "message" => "Authentication required"
      })

    FakeAcp.install(context, "grok", config)
  end

  step "the MC checks Grok and is told Grok is signed out", context do
    FakeAcp.enable(context, "grok")
  end

  step "the MC checks once more", context do
    {_, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"auth" => %{"status" => "authenticated"}}, FakeAcp.find(providers, "grok"))
      end)

    assert length(FakeAcp.received(context, "session/new")) >= 2
    context
  end

  step "Grok is reported signed in", context do
    assert %{"auth" => %{"status" => "authenticated"}} =
             FakeAcp.find(context.providers, "grok")

    context
  end

  # --- updates -----------------------------------------------------------------------

  @latest "9.9.9"

  # The newest Grok release, as if already read from the registry.
  defp seed_latest(context) do
    # What an earlier scenario's Grok was offered must not stand as this one's.
    :persistent_term.erase({HalC2.ProviderUpdates, "grok", :offered})
    :persistent_term.erase({HalC2.ProviderUpdates, "grok", :state})

    :persistent_term.put(
      {HalC2.ProviderUpdates, "grok"},
      {@latest, System.monotonic_time(:millisecond)}
    )

    ExUnit.Callbacks.on_exit(fn ->
      for key <- [
            {HalC2.ProviderUpdates, "grok"},
            {HalC2.ProviderUpdates, "grok", :state},
            {HalC2.ProviderUpdates, "grok", :offered},
            {HalC2.ProviderUpdates, {:cask, "grok-build"}}
          ],
          do: :persistent_term.erase(key)
    end)

    context
  end

  defp outdated(context, extra \\ %{}, opts \\ []) do
    config =
      signed_in_config()
      |> Map.merge(%{"version" => "1.0.0", "updatedVersion" => @latest})
      |> Map.merge(extra)

    context
    |> seed_latest()
    |> FakeAcp.install("grok", config, Keyword.merge([enabled: true], opts))
  end

  step "Grok was installed by its own installer and a newer version is released", context do
    outdated(context)
  end

  step "Grok was installed by its own installer and this Grok instance has its own Grok home",
       context do
    home = HalC2.Test.Mc.tmp_dir(context.mc, "grok-own-home")

    context
    |> outdated()
    |> grok_env([%{"name" => "GROK_HOME", "value" => home}])
    |> Map.put(:grok_home, home)
  end

  step "Grok was installed with npm 12 and a newer version is released", context do
    prefix = HalC2.Test.Mc.tmp_dir(context.mc, "grok-npm")
    real = Path.join(prefix, "lib/node_modules/@xai-official/grok/bin/grok")
    outdated(context, %{"updateRequiresAllowScripts" => true}, path: real)
  end

  step "Grok is reported behind the latest version with an update command", context do
    {providers, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"version" => "1.0.0"}, FakeAcp.find(providers, "grok"))
      end)

    advisory = FakeAcp.find(providers, "grok")["versionAdvisory"]
    assert advisory["status"] == "behind_latest"
    assert advisory["latestVersion"] == @latest
    assert advisory["canUpdate"] == true
    assert String.ends_with?(advisory["updateCommand"], " update")
    context
  end

  step "the user updates Grok", context do
    {reply, context} =
      World.call_keeping(context, "server.updateProvider", %{"provider" => "grok"})

    assert {:ok, _} = reply

    context
    |> Map.put(:reply, reply)
    |> then(fn context ->
      case reply do
        {:ok, %{"providers" => providers}} -> Map.put(context, :providers, providers)
        _ -> context
      end
    end)
  end

  step "Grok's updater runs against that home and not the default one", context do
    updates =
      Enum.filter(FakeAcp.starts(context), fn start ->
        Enum.at(start["argv"], 1) == "update"
      end)

    assert [update] = updates
    assert update["env"]["GROK_HOME"] == context.grok_home
    context
  end

  step "Grok is reported current", context do
    assert {:ok, %{"providers" => providers}} = context.reply
    grok = FakeAcp.find(providers, "grok")
    assert grok["version"] == @latest
    assert grok["versionAdvisory"]["status"] == "current"
    context
  end

  step "the new Grok binary is installed", context do
    config =
      context
      |> FakeAcp.fake()
      |> Map.fetch!(:dir)
      |> Path.join("config.json")
      |> File.read!()
      |> JSON.decode!()

    assert config["version"] == @latest
    context
  end

  # A Homebrew prefix whose Caskroom holds Grok; its brew reports the cask's
  # version when asked. The brew is written only when `brew: true`.
  defp cask_install(context, opts) do
    # Reading the cask's version is a local brew call, allowed in tests where
    # the npm registry check is off.
    Application.put_env(:hal_c2, :provider_update_checks, true)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:hal_c2, :provider_update_checks, false)
    end)

    prefix = HalC2.Test.Mc.tmp_dir(context.mc, "homebrew")
    real = Path.join(prefix, "Caskroom/grok-build/1.0.0/grok")
    context = outdated(context, %{}, path: real)

    if Keyword.get(opts, :brew, true) do
      brew = Path.join(prefix, "bin/brew")
      File.mkdir_p!(Path.dirname(brew))

      File.write!(brew, """
      #!/bin/sh
      echo '{"casks":[{"version":"1.0.60"}]}'
      """)

      File.chmod!(brew, 0o755)
      Map.put(context, :brew, brew)
    else
      context
    end
  end

  step "Grok's executable lives in the Homebrew cask that installed it", context do
    cask_install(context, brew: true)
  end

  step "Grok's executable sits in a Homebrew cask under a different prefix than the brew on the path",
       context do
    cask_install(context, brew: false)
  end

  step "the user opens Grok's update details", context do
    {_, context} =
      FakeAcp.await_providers(
        context,
        fn providers ->
          case FakeAcp.find(providers, "grok") do
            %{"version" => "1.0.0", "versionAdvisory" => %{"latestVersion" => "1.0.60"}} ->
              true

            %{"version" => "1.0.0", "versionAdvisory" => %{"canUpdate" => false}} ->
              true

            _ ->
              false
          end
        end,
        15_000
      )

    context
  end

  step "Grok is compared against the version that cask would install", context do
    advisory = FakeAcp.find(context.providers, "grok")["versionAdvisory"]
    assert advisory["latestVersion"] == "1.0.60"
    assert advisory["status"] == "behind_latest"
    context
  end

  step "the update command upgrades that cask through Homebrew and not Grok's own updater",
       context do
    advisory = FakeAcp.find(context.providers, "grok")["versionAdvisory"]
    assert advisory["updateCommand"] == "#{context.brew} upgrade --cask grok-build"
    context
  end

  step "no update command is offered for Grok", context do
    advisory = FakeAcp.find(context.providers, "grok")["versionAdvisory"]
    assert advisory["updateCommand"] == nil
    assert advisory["canUpdate"] == false
    context
  end

  step "the Grok instance's executable cannot be resolved", context do
    context = outdated(context)

    {_, context} =
      FakeAcp.await_providers(context, fn providers ->
        match?(%{"version" => "1.0.0"}, FakeAcp.find(providers, "grok"))
      end)

    File.rm!(FakeAcp.fake(context).bin)
    context
  end

  step "Grok is reported behind the latest version with no update command", context do
    grok = FakeAcp.entry("grok")
    assert grok["version"] == "1.0.0"
    assert grok["versionAdvisory"]["status"] == "behind_latest"
    assert grok["versionAdvisory"]["updateCommand"] == nil
    assert grok["versionAdvisory"]["canUpdate"] == false
    context
  end

  # --- health ------------------------------------------------------------------------

  step "Grok is turned off in the provider settings", context do
    FakeAcp.install(context, "grok", signed_in_config())
  end

  step "the MC is still looking for the grok command", context do
    config = Map.put(signed_in_config(), "waitForFileOn", %{"initialize" => "release-init"})
    context = FakeAcp.install(context, "grok", config, enabled: true)
    gate = Path.join(FakeAcp.fake(context).dir, "release-init")
    ExUnit.Callbacks.on_exit(fn -> File.write(gate, "") end)
    Map.put(context, :init_gate, gate)
  end

  step "the grok version check does not finish in time", context do
    # The probe's own limit is ten seconds; the scenario exercises what a
    # timeout reports, so it shortens the limit rather than waiting it out.
    Application.put_env(:hal_c2, :grok_version_timeout_ms, 200)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :grok_version_timeout_ms) end)
    config = Map.put(signed_in_config(), "versionHang", true)
    FakeAcp.install(context, "grok", config, enabled: true)
  end

  step "the grok version check exits with an error", context do
    config = Map.put(signed_in_config(), "versionExit", 3)
    FakeAcp.install(context, "grok", config, enabled: true)
  end

  step "the grok command is installed but signed out", context do
    FakeAcp.install(context, "grok", Map.put(signed_in_config(), "authRequired", true),
      enabled: true
    )
  end

  step "Grok cannot report its model options", context do
    if context[:fakes] && context.fakes["grok"] do
      # The metadata probe fails once; a later session of Grok's still runs.
      context = FakeAcp.configure(context, &Map.put(&1, "failInitializeTimes", 1))
      HalC2.Acp.forget("grok")
      context = FakeAcp.enable(context, "grok")

      {_, context} =
        FakeAcp.await_providers(context, fn providers ->
          match?(%{"status" => "warning"}, FakeAcp.find(providers, "grok"))
        end)

      context
    else
      config =
        Map.put(signed_in_config(), "initError", %{"code" => -32002, "message" => "no init"})

      FakeAcp.install(context, "grok", config, enabled: true)
    end
  end

  step "Grok is shown with the message {string}", %{args: [message]} = context do
    {providers, context} =
      FakeAcp.await_providers(
        context,
        fn providers ->
          match?(%{"message" => ^message}, FakeAcp.find(providers, "grok"))
        end,
        15_000
      )

    assert FakeAcp.find(providers, "grok")["message"] == message
    if context[:init_gate], do: File.write!(context.init_gate, "")
    context
  end

  step "Grok takes {int} seconds to answer when it starts", %{args: [seconds]} = context do
    config = Map.put(signed_in_config(), "delaysMs", %{"initialize" => seconds * 1_000})
    FakeAcp.install(context, "grok", config, enabled: true)
  end

  step "the MC checks Grok", context do
    {_, context} = FakeAcp.open_config(context)
    context
  end

  step "Grok is reported ready", context do
    {_, context} =
      FakeAcp.await_providers(
        context,
        fn providers -> match?(%{"status" => "ready"}, FakeAcp.find(providers, "grok")) end,
        40_000
      )

    context
  end

  step "{string} takes {int} seconds to answer", %{args: [_command, seconds]} = context do
    config = Map.put(signed_in_config(), "versionDelayMs", seconds * 1_000)
    FakeAcp.install(context, "grok", config, enabled: true)
  end

  step "Grok is not reported as timed out", context do
    {providers, context} =
      FakeAcp.await_providers(
        context,
        fn providers -> match?(%{"status" => "ready"}, FakeAcp.find(providers, "grok")) end,
        20_000
      )

    refute (FakeAcp.find(providers, "grok")["message"] || "") =~ "timed out"
    context
  end

  step "the user sends a message to Grok", context do
    context
    |> FakeAcp.thread()
    |> FakeAcp.send_message("hello grok")
  end

  step "Grok answers it", context do
    FakeAcp.await_run(context, "completed")
    context
  end

  step "Grok is listed with a warning, not as unavailable", context do
    grok = FakeAcp.entry("grok")
    assert grok["status"] == "warning"
    assert grok["availability"] == "available"
    context
  end

  # --- probe environment ---------------------------------------------------------------

  step "the MC's environment lets Grok update itself", context do
    :persistent_term.erase({HalC2.ProviderUpdates, "grok", :offered})
    :persistent_term.erase({HalC2.ProviderUpdates, "grok", :state})

    context
    |> FakeAcp.install("grok", signed_in_config(), enabled: true)
    |> grok_env([%{"name" => "GROK_DISABLE_AUTOUPDATER", "value" => "0"}])
  end

  step "the MC checks Grok's health by reading its version", context do
    FakeAcp.probe("grok")
    Map.put(context, :probe_kind, :version)
  end

  step "the MC checks Grok's health by listing its models", context do
    FakeAcp.probe("grok")
    Map.put(context, :probe_kind, :models)
  end

  step "the MC checks Grok's health by starting an agent connection", context do
    FakeAcp.probe("grok")
    Map.put(context, :probe_kind, :connection)
  end

  step "Grok runs with its automatic updater turned off", context do
    starts = FakeAcp.starts(context)
    assert starts != []

    relevant =
      case context.probe_kind do
        :version -> Enum.filter(starts, &(Enum.at(&1["argv"], 1) == "--version"))
        _ -> Enum.reject(starts, &(Enum.at(&1["argv"], 1) == "--version"))
      end

    assert relevant != []
    assert Enum.all?(relevant, &(&1["env"]["GROK_DISABLE_AUTOUPDATER"] == "1"))
    context
  end

  step "Grok's health, sign-in and models are still reported", context do
    grok = FakeAcp.entry("grok")
    assert grok["status"] == "ready"
    assert grok["auth"]["status"] == "authenticated"
    assert grok["models"] != []
    context
  end

  step "Grok writes a commit message or title", context do
    FakeAcp.settings(
      &Map.put(&1, "textGenerationModelSelection", %{
        "instanceId" => "grok",
        "model" => "grok-code-fast-1"
      })
    )

    root = World.project(context).root
    assert {:ok, _} = HalC2.TextGeneration.thread_title(root, "Fix the login form")
    context
  end

  step "Grok runs with the MC's environment unchanged", context do
    starts = FakeAcp.starts(context)

    # An update is followed by a health probe of the new binary; the updater's
    # own start is the one that must keep the caller's environment.
    start =
      Enum.find(Enum.reverse(starts), &(Enum.at(&1["argv"], 1) == "update")) ||
        List.last(starts)

    assert start, "Grok was not started"
    assert start["env"]["GROK_DISABLE_AUTOUPDATER"] == "0"
    context
  end

  # --- start-up environment and compatibility -------------------------------------------

  step "the MC starts the grok command", context do
    context = FakeAcp.install(context, "grok", signed_in_config(), enabled: true)
    FakeAcp.probe("grok")
    context
  end

  step "the command's environment carries {string} set to {string}",
       %{args: [name, value]} = context do
    starts = FakeAcp.starts(context)
    assert starts != []
    assert Enum.all?(starts, &(&1["env"][name] == value))
    context
  end

  step "Grok version {string} is installed", %{args: [version]} = context do
    config = Map.put(signed_in_config(), "version", version)
    FakeAcp.install(context, "grok", config, enabled: true)
  end

  step "Grok is reported as {string} for this HAL-C2 release",
       %{args: [status]} = context do
    {providers, context} =
      FakeAcp.await_providers(
        context,
        fn providers ->
          match?(
            %{"compatibilityAdvisory" => %{"status" => ^status}},
            FakeAcp.find(providers, "grok")
          )
        end,
        15_000
      )

    assert FakeAcp.find(providers, "grok")["compatibilityAdvisory"]["status"] == status
    context
  end

  # --- prompt completion -------------------------------------------------------------

  # The id the last prompt sent to Grok carries.
  defp prompt_id(context) do
    [%{"params" => %{"_meta" => %{"promptId" => id}}} | _] =
      Enum.reverse(FakeAcp.received(context, "session/prompt"))

    id
  end

  # Waits until the runtime has taken everything sent to it so far.
  defp sync_runtime(context), do: :sys.get_state(runtime_pid(context))

  defp run_status(context) do
    context
    |> then(&World.state(&1, &1.thread))
    |> HalC2.StreamState.list("run")
    |> Enum.max_by(& &1["requestedAt"], fn -> %{} end)
    |> Map.get("status")
  end

  step "Grok reports the turn complete but never answers the prompt request", context do
    # Notices for a subagent's session and for finished background work first:
    # neither ends this turn.
    grok_says(context, "session/update", %{
      "sessionId" => @child_session,
      "update" => %{
        "sessionUpdate" => "turn_completed",
        "prompt_id" => prompt_id(context)
      }
    })

    grok_says(context, "x.ai/session_notification", %{
      "sessionId" => session(context),
      "update" => %{
        "sessionUpdate" => "turn_completed",
        "prompt_id" => "task-completed-task-sh"
      }
    })

    sync_runtime(context)
    context = Map.put(context, :still_running, run_status(context) == "running")

    grok_says(context, "session/update", %{
      "sessionId" => session(context),
      "update" => %{
        "sessionUpdate" => "turn_completed",
        "prompt_id" => prompt_id(context),
        "stop_reason" => "end_turn"
      }
    })

    context
  end

  step "a completion notice for a subagent's session or for finished background work does not complete it",
       context do
    assert context.still_running
    context
  end

  step "Grok reports the turn complete with a rate limit and never answers the prompt request",
       context do
    grok_says(context, "x.ai/session/prompt_complete", %{
      "sessionId" => session(context),
      "promptId" => prompt_id(context),
      "stopReason" => "rate_limit"
    })

    context
  end

  step "a Grok turn has completed", context do
    context =
      context
      |> FakeAcp.install("grok", signed_in_config(), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("first")

    FakeAcp.await_run(context, "completed")
    Map.put(context, :done_prompt, prompt_id(context))
  end

  step "Grok reports that turn complete again while the next turn is running", context do
    context = FakeAcp.send_message(context, "start a long task")
    FakeAcp.await_run(context, "running")
    await_answer(context)

    grok_says(context, "x.ai/session/prompt_complete", %{
      "sessionId" => session(context),
      "promptId" => context.done_prompt,
      "stopReason" => "end_turn"
    })

    sync_runtime(context)
    context
  end

  step "the next turn is still running", context do
    assert run_status(context) == "running"
    context
  end

  step "Grok reports the turn complete with a stop reason HAL-C2 does not know", context do
    grok_says(context, "_x.ai/session/prompt_complete", %{
      "sessionId" => session(context),
      "promptId" => prompt_id(context),
      "stopReason" => "something_new"
    })

    context
  end

  step "the turn completes as an ordinary end of turn", context do
    FakeAcp.await_run(context, "completed")
    context
  end

  step "the user sends a message in a Grok thread", context do
    context =
      context
      |> FakeAcp.install("grok", signed_in_config(), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("hello grok")

    FakeAcp.await_run(context, "completed")
    context
  end

  step "the prompt sent to Grok carries a prompt id and a request id of its own", context do
    context = FakeAcp.send_message(context, "and again")
    FakeAcp.await_runs(context, 2)

    metas =
      for %{"params" => %{"_meta" => meta}} <- FakeAcp.received(context, "session/prompt"),
          do: meta

    assert [first, second] = metas
    assert first["promptId"] == first["requestId"]
    assert second["promptId"] == second["requestId"]
    assert first["promptId"] != second["promptId"]
    context
  end

  step "Grok's cancel request carries the cancel trigger {string}",
       %{args: [trigger]} = context do
    FakeAcp.await_run(context, "interrupted")

    assert [%{"params" => %{"_meta" => %{"cancelTrigger" => ^trigger}}}] =
             FakeAcp.received(context, "session/cancel")

    context
  end

  # Grok's notices in every spelling: each run drives the notice the outline
  # names and watches what it does to its thread.
  step "Grok sends {string}", %{args: [notice]} = context do
    context = Map.put(context, :notice, notice)

    cond do
      String.contains?(notice, "ask_user_question") ->
        question_turn(context, notice)

      String.contains?(notice, "exit_plan_mode") ->
        plan_turn(context, notice)

      String.contains?(notice, "task_backgrounded") ->
        backgrounded_turn(context, notice)

      String.contains?(notice, "task_completed") ->
        context = background_thread(context, "work in the background")

        grok_says(context, notice, %{
          "sessionId" => session(context),
          "update" => %{
            "sessionUpdate" => "task_completed",
            "task_snapshot" => %{"task_id" => "task-sh"}
          }
        })

        context

      true ->
        context =
          context
          |> FakeAcp.install("grok", signed_in_config(), enabled: true)
          |> FakeAcp.thread()
          |> FakeAcp.send_message("start a long task")

        FakeAcp.await_run(context, "running")
        await_answer(context)
        id = prompt_id(context)

        params =
          if String.contains?(notice, "prompt_complete") do
            %{"sessionId" => session(context), "promptId" => id, "stopReason" => "end_turn"}
          else
            %{
              "sessionId" => session(context),
              "update" => %{
                "sessionUpdate" => "turn_completed",
                "prompt_id" => id,
                "stop_reason" => "end_turn"
              }
            }
          end

        grok_says(context, notice, params)
        context
    end
  end

  step "HAL-C2 treats it as the turn completing", context do
    FakeAcp.await_run(context, "completed")
    context
  end

  step "HAL-C2 treats it as a task moving to the background", context do
    World.await_row(
      World.thread_id(context, context.thread),
      &match?([%{"taskType" => "command_execution"}], &1["runningBackgroundTasks"])
    )

    context
  end

  step "HAL-C2 treats it as a background task ending", context do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      background_items(state)["sh-1"] == "completed"
    end)

    context
  end

  step "HAL-C2 treats it as a question for the user", context do
    request = FakeAcp.await_request(context)
    assert request["kind"] == "user_input"

    context =
      FakeAcp.respond(context, request["id"], %{"answers" => %{"Which database?" => "SQLite"}})

    FakeAcp.await_run(context, "completed")
    context
  end

  step "HAL-C2 treats it as a plan to review", context do
    FakeAcp.await_run(context, "completed")
    state = World.state(context, context.thread)

    assert Enum.any?(
             HalC2.StreamState.list(state, "turn-item"),
             &(&1["type"] == "proposed_plan")
           )

    context
  end

  defp question_turn(context, method) do
    turns = [
      %{
        "match" => "pick a database",
        "steps" => [
          %{
            "request" => %{
              "method" => method,
              "params" => %{
                "toolCallId" => "q-1",
                "questions" => [
                  %{
                    "question" => "Which database?",
                    "options" => [%{"label" => "Postgres"}, %{"label" => "SQLite"}]
                  }
                ]
              }
            }
          },
          %{"text" => "Using it."}
        ]
      }
      | FakeAcp.turns()
    ]

    context
    |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
    |> FakeAcp.thread("Work", "approval-required")
    |> FakeAcp.send_message("pick a database")
  end

  defp plan_turn(context, method) do
    turns = [
      %{
        "match" => "plan the work",
        "steps" => [
          %{
            "request" => %{
              "method" => method,
              "params" => %{
                "toolCallId" => "plan-1",
                "planContent" => "# Plan\n\n1. Add the form"
              }
            }
          }
        ]
      }
      | FakeAcp.turns()
    ]

    context =
      context
      |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
      |> FakeAcp.thread("Work", "approval-required")
      |> FakeAcp.send_message("plan the work")

    context
  end

  # A long command whose tool call is still open when Grok backgrounds it.
  defp backgrounded_turn(context, method) do
    turns = [
      %{
        "match" => "run the dev server",
        "steps" => [
          %{
            "update" => %{
              "sessionUpdate" => "tool_call",
              "toolCallId" => "sh-1",
              "title" => "npm run dev",
              "kind" => "execute",
              "status" => "in_progress",
              "rawInput" => %{"command" => "npm run dev"}
            }
          },
          %{"waitFile" => "release-bg"},
          %{"text" => "Started it."}
        ]
      }
      | FakeAcp.turns()
    ]

    context =
      context
      |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("run the dev server")

    release = Path.join(FakeAcp.fake(context).dir, "release-bg")
    ExUnit.Callbacks.on_exit(fn -> File.write(release, "") end)

    # The tool call reached the thread; Grok now backgrounds it.
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      background_items(state)["sh-1"] == "running"
    end)

    grok_says(context, method, %{
      "sessionId" => session(context),
      "update" => %{"task_id" => "task-sh", "tool_call_id" => "sh-1"}
    })

    sync_runtime(context)
    File.write!(release, "")
    FakeAcp.await_run(context, "completed")
    context
  end

  # --- images and compaction -----------------------------------------------------------

  step "Grok reports at start-up that it does not take images", context do
    # The fake's capabilities say promptCapabilities.image is false.
    context
    |> FakeAcp.install("grok", signed_in_config(), enabled: true)
    |> FakeAcp.thread()
  end

  step "the user sends a Grok message with a screenshot attached", context do
    dir = Path.join(context.mc.home, "attachments")
    File.mkdir_p!(dir)
    id = "att-shot"

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8Xw8AAwMCAO+ip1sAAAAASUVORK5CYII="
      )

    File.write!(Path.join(dir, id <> ".png"), png)

    FakeAcp.send_message(context, "look at this", nil, %{
      "attachments" => [
        %{
          "type" => "image",
          "id" => id,
          "name" => "shot.png",
          "mimeType" => "image/png",
          "sizeBytes" => byte_size(png)
        }
      ]
    })
  end

  step "Grok receives the screenshot as an image with the message", context do
    FakeAcp.await_run(context, "completed")
    [%{"params" => %{"prompt" => prompt}}] = FakeAcp.received(context, "session/prompt")
    assert Enum.any?(prompt, &match?(%{"type" => "image", "mimeType" => "image/png"}, &1))
    context
  end

  step "a Grok thread with history", context do
    context =
      context
      |> FakeAcp.install("grok", signed_in_config(), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("first")

    FakeAcp.await_run(context, "completed")
    context
  end

  # --- unnamed completion notices and plain failures --------------------------------

  step "two prompts are waiting on the same Grok session", context do
    context =
      context
      |> FakeAcp.install("grok", signed_in_config(), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("start a long task")

    FakeAcp.await_run(context, "running")
    await_answer(context)

    # A second prompt of the same turn is still out with Grok.
    extra = make_ref()
    pid = runtime_pid(context)

    :sys.replace_state(pid, fn state ->
      %{state | prompts: Map.put(state.prompts, extra, :steer)}
    end)

    Map.put(context, :extra_prompt, extra)
  end

  step "Grok reports a turn complete without naming a prompt", context do
    grok_says(context, "x.ai/session/prompt_complete", %{
      "sessionId" => session(context),
      "stopReason" => "end_turn"
    })

    sync_runtime(context)
    context
  end

  step "neither prompt is completed", context do
    assert run_status(context) == "running"
    context
  end

  step "the same notice completes the prompt when only one is waiting", context do
    pid = runtime_pid(context)

    :sys.replace_state(pid, fn state ->
      %{state | prompts: Map.delete(state.prompts, context.extra_prompt)}
    end)

    grok_says(context, "x.ai/session/prompt_complete", %{
      "sessionId" => session(context),
      "stopReason" => "end_turn"
    })

    FakeAcp.await_run(context, "completed")
    context
  end

  step "Grok refuses a message with an error that is not its rate-limit error", context do
    turns = [
      %{
        "match" => "keep going",
        "steps" => [
          %{"error" => %{"code" => -32603, "message" => "Rate limit headers were malformed"}}
        ]
      }
    ]

    context
    |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
    |> FakeAcp.thread()
    |> FakeAcp.send_message("keep going")
  end

  defp last_error(context) do
    context
    |> FakeAcp.await_run("failed")
    |> HalC2.StreamState.list("provider-session")
    |> Enum.find_value(& &1["lastError"])
  end

  step "the turn fails with Grok's message and error code", context do
    assert last_error(context) == "Rate limit headers were malformed (-32603)"
    context
  end

  step "it is not reported as a usage limit, even when the message mentions a rate limit",
       context do
    refute last_error(context) =~ "usage limit reached"
    context
  end

  # --- how background work ends -------------------------------------------------------

  step "Grok left a command running in the background", context do
    context = background_thread(context, "work in the background")

    World.await_row(
      World.thread_id(context, context.thread),
      &(length(&1["runningBackgroundTasks"] || []) == 2)
    )

    context
  end

  step "Grok left a subagent running in the background", context do
    context = background_thread(context, "work in the background")

    World.await_row(
      World.thread_id(context, context.thread),
      &(length(&1["runningBackgroundTasks"] || []) == 2)
    )

    context
  end

  step "Grok left a subagent named {string} running in the background",
       %{args: [name]} = context do
    context = background_thread(context, "work in the background")

    World.await_row(
      World.thread_id(context, context.thread),
      &(length(&1["runningBackgroundTasks"] || []) == 2)
    )

    Map.put(context, :subagent_name, name)
  end

  defp task_ended(context, snapshot) do
    grok_says(context, "x.ai/task_completed", %{
      "sessionId" => session(context),
      "update" => %{
        "sessionUpdate" => "task_completed",
        "task_snapshot" => Map.put(snapshot, "task_id", "task-sh")
      }
    })

    context
  end

  step "Grok reports the command ended with the status {string}", %{args: [status]} = context do
    task_ended(context, %{"status" => status})
  end

  step "Grok reports the command ended with no status and exit code 0", context do
    task_ended(context, %{"exit_code" => 0})
  end

  step "Grok reports the command ended with no status and a non-zero exit code", context do
    task_ended(context, %{"exit_code" => 3})
  end

  defp await_command(context, status) do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      background_items(state)["sh-1"] == status
    end)

    context
  end

  step "the command is shown as completed", context do
    await_command(context, "completed")
  end

  step "the command is shown as stopped", context do
    await_command(context, "cancelled")
  end

  step "Grok tries to kill it and the kill fails", context do
    context = FakeAcp.send_message(context, "try to stop the dev server")
    FakeAcp.await_runs(context, 2)
    context
  end

  step "the command is still listed as background work", context do
    assert %{"sh-1" => "running"} = background_items(World.state(context, context.thread))

    assert Enum.any?(
             World.row(context, context.thread)["runningBackgroundTasks"] || [],
             &(&1["taskType"] == "command_execution")
           )

    context
  end

  defp subagent_says(context, text) do
    grok_says(context, "session/update", %{
      "sessionId" => session(context),
      "update" => %{
        "sessionUpdate" => "user_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      }
    })

    context
  end

  step ~r/^Grok says the subagent (?<outcome>.+)$/, %{args: [outcome]} = context do
    name = if context[:subagent_name], do: ~s[ ("#{context.subagent_name}")], else: ""
    subagent_says(context, ~s[Background subagent "#{@child_session}"#{name} #{outcome}.])
  end

  step "text passes through the thread that talks about background subagents without being Grok's notice",
       context do
    context =
      subagent_says(
        context,
        "Background subagents like #{@child_session} are still working on it."
      )

    sync_runtime(context)
    [subagent] = HalC2.StreamState.list(World.state(context, context.thread), "subagent")
    Map.put(context, :subagent, subagent)
  end

  step "Grok starts a subagent in the background and the launching tool call returns", context do
    background_thread(context, "work in the background")
  end

  step "the subagent's thread is still running", context do
    [subagent] = HalC2.StreamState.list(World.state(context, context.thread), "subagent")
    assert subagent["status"] == "running"
    context
  end

  step "it finishes when Grok reports the subagent's result", context do
    # A plain "completed." counts as success although the result that
    # follows mentions errors: only the outcome sentence decides.
    context =
      subagent_says(
        context,
        ~s[Background subagent "#{@child_session}" (type: "general") completed. It fixed 2 errors along the way.]
      )

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      case HalC2.StreamState.list(state, "subagent") do
        [%{"status" => "completed"}] -> true
        _ -> false
      end
    end)

    context
  end

  # xAI's billing API, played by `HalC2.Test.FakeHttp`.
  defp billing(context, response) do
    {url, log} = HalC2.Test.FakeHttp.start(%{"/v1/billing" => {200, response}})
    Application.put_env(:hal_c2, :grok_billing_url, url <> "/v1/billing?format=credits")
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :grok_billing_url) end)
    Map.put(context, :billing, log)
  end

  defp grok_env(context, environment) do
    FakeAcp.settings(
      &Map.put(&1, "providerInstances", %{
        "grok" => %{"driver" => "grok", "environment" => environment}
      })
    )

    context
  end

  # --- subagents -------------------------------------------------------------------

  # Grok's `task` tool: the child's answer streams under its own session, before the
  # tool call names that session ("Agent ID: ...") and completes.
  step "Grok starts a subagent", context do
    call = %{
      "toolCallId" => "task-1",
      "title" => "task",
      "kind" => "other",
      "status" => "in_progress",
      "rawInput" => %{
        "description" => "Survey the modules",
        "prompt" => "List the modules in lib",
        "subagent_type" => "general-purpose"
      }
    }

    turns = [
      %{
        "match" => "survey the code",
        "steps" => [
          %{"update" => Map.put(call, "sessionUpdate", "tool_call")},
          %{
            "sessionId" => @child_session,
            "update" => %{
              "sessionUpdate" => "agent_message_chunk",
              "content" => %{"type" => "text", "text" => "lib has three modules"}
            }
          },
          %{
            "update" => %{
              "sessionUpdate" => "tool_call_update",
              "toolCallId" => "task-1",
              "status" => "completed",
              "content" => [
                %{
                  "type" => "content",
                  "content" => %{
                    "type" => "text",
                    "text" => "Agent ID: #{@child_session}\nlib has three modules"
                  }
                }
              ]
            }
          },
          %{"text" => "The subagent found three modules."}
        ]
      }
      | FakeAcp.turns()
    ]

    context =
      context
      |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("survey the code")

    FakeAcp.await_run(context, "completed")

    Map.merge(context, %{
      subagent_prompt: "List the modules in lib",
      subagent_answer: "lib has three modules"
    })
  end

  # Grok's turn stays open until it is cancelled, with its subagent still working.
  step "Grok is running a subagent", context do
    call = %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "task-1",
      "title" => "task",
      "kind" => "other",
      "status" => "in_progress",
      "rawInput" => %{"description" => "Survey the modules", "prompt" => "List the modules"}
    }

    turns = [
      %{"match" => "survey the code", "steps" => [%{"update" => call}, %{"waitCancel" => true}]}
      | FakeAcp.turns()
    ]

    context =
      context
      |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message("survey the code")

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(HalC2.StreamState.list(state, "subagent"), &(&1["status"] == "running"))
    end)

    Map.put(
      context,
      :running,
      hd(HalC2.StreamState.list(FakeAcp.await_run(context, "running"), "run"))["id"]
    )
  end

  step "the subagent, its node and its turn item have failed", context do
    state = FakeAcp.await_run(context, "failed")
    [subagent] = HalC2.StreamState.list(state, "subagent")
    assert subagent["status"] == "failed"
    assert HalC2.StreamState.get(state, "node")[subagent["id"]]["status"] == "failed"

    assert [%{"status" => "failed"}] =
             Enum.filter(
               HalC2.StreamState.list(state, "turn-item"),
               &(&1["subagentId"] == subagent["id"])
             )

    context
  end

  # --- background work ------------------------------------------------------------

  # Grok's background shell (task-sh, from tool sh-1) and a subagent spawned in the
  # background (spawn-1, session @child_session), both acknowledged in the turn.
  @background [
    %{
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "sh-1",
        "title" => "npm run dev",
        "kind" => "execute",
        "status" => "in_progress",
        "rawInput" => %{"command" => "npm run dev"}
      }
    },
    %{
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "sh-1",
        "status" => "completed",
        "content" => [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "Started."}}
        ],
        "rawOutput" => %{"type" => "BackgroundTaskStarted", "task_id" => "task-sh"}
      }
    },
    %{
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "spawn-1",
        "title" => "task",
        "kind" => "other",
        "status" => "in_progress",
        "rawInput" => %{"description" => "Survey the repo", "prompt" => "List the repo"}
      }
    },
    %{
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "spawn-1",
        "status" => "completed",
        "content" => [
          %{
            "type" => "content",
            "content" => %{
              "type" => "text",
              "text" =>
                "Subagent started in background.\nsubagent_id: #{@child_session}\n" <>
                  "Use get_command_or_subagent_output."
            }
          }
        ]
      }
    },
    %{"text" => "Both are running."}
  ]

  # A later turn that kills the background shell.
  @kill [
    %{
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "kill-1",
        "title" => "kill_command_or_subagent",
        "kind" => "other",
        "status" => "in_progress",
        "rawInput" => %{"task_id" => "task-sh"}
      }
    },
    %{
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "kill-1",
        "status" => "completed"
      }
    },
    %{"text" => "Stopped the dev server."}
  ]

  # A persistent monitor, which Grok never ends.
  @monitor [
    %{
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "mon-1",
        "title" => "monitor",
        "kind" => "other",
        "status" => "in_progress",
        "rawInput" => %{"command" => "tail -f log/dev.log"}
      }
    },
    %{
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "mon-1",
        "status" => "completed",
        "rawOutput" => %{"type" => "Monitor", "task_id" => "mon-1", "persistent" => true}
      }
    },
    %{"text" => "Watching the log."}
  ]

  step "Grok left a command and a subagent running in the background", context do
    context = background_thread(context, "work in the background")

    World.await_row(
      World.thread_id(context, context.thread),
      &(length(&1["runningBackgroundTasks"] || []) == 2)
    )

    context
  end

  step "Grok left a persistent monitor running", context do
    background_thread(context, "watch the log")
  end

  step "{string} lists the command and the subagent as background work",
       %{args: [thread]} = context do
    assert ["command_execution", "subagent"] =
             World.row(context, thread)["runningBackgroundTasks"]
             |> Enum.map(& &1["taskType"])
             |> Enum.sort()

    context
  end

  step "{string} lists only the subagent as background work", %{args: [thread]} = context do
    World.await_row(
      World.thread_id(context, thread),
      &match?([%{"taskType" => "subagent"}], &1["runningBackgroundTasks"])
    )

    context
  end

  step "the MC keeps Grok's session of {string} while they run", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    idle_now()
    HalC2.Test.Mc.ensure(HalC2.Orchestration.IdleSessions)
    refute id in HalC2.Orchestration.IdleSessions.check()
    assert [_] = Registry.lookup(HalC2.Acp.Registry, id)
    context
  end

  step "Grok reports the command and the subagent ended", context do
    grok_says(context, "x.ai/task_completed", %{
      "sessionId" => session(context),
      "update" => %{
        "sessionUpdate" => "task_completed",
        "task_snapshot" => %{"task_id" => "task-sh"}
      }
    })

    grok_says(context, "session/update", %{
      "sessionId" => session(context),
      "update" => %{
        "sessionUpdate" => "user_message_chunk",
        "content" => %{
          "type" => "text",
          "text" =>
            ~s[Background subagent "#{@child_session}" (type: "general") completed successfully.]
        }
      }
    })

    context
  end

  step "the MC can release Grok's session of {string}", %{args: [thread]} = context do
    id = World.thread_id(context, thread)
    World.await_row(id, &(&1["runningBackgroundTasks"] == []))
    idle_now()
    HalC2.Test.Mc.ensure(HalC2.Orchestration.IdleSessions)
    assert id in HalC2.Orchestration.IdleSessions.check()
    context
  end

  step ~r/^Grok's (?<which>command|command and subagent) (?:is|are) (?<status>completed|interrupted|cancelled)$/,
       %{args: [which, status]} = context do
    expected = if which == "command", do: ["sh-1"], else: ["sh-1", "spawn-1"]

    World.await_stream(World.thread_id(context, context.thread), fn state ->
      items = background_items(state)
      Enum.all?(expected, &(items[&1] == status))
    end)

    context
  end

  step "Grok's agent process for {string} stops", context do
    ref = Process.monitor(context.grok_conn)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    context
  end

  step "the user asks Grok to stop the dev server", context do
    context = FakeAcp.send_message(context, "stop the dev server")
    FakeAcp.await_runs(context, 2)
    context
  end

  step "Grok's monitor is not listed as background work", context do
    id = World.thread_id(context, context.thread)
    World.await_row(id, &(&1["runningBackgroundTasks"] == []))

    assert %{"mon-1" => "running"} =
             background_items(World.state(context, context.thread))

    context
  end

  # A later turn whose kill of the background shell does not go through.
  @kill_failed [
    %{
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "kill-2",
        "title" => "kill_command_or_subagent",
        "kind" => "other",
        "status" => "in_progress",
        "rawInput" => %{"task_id" => "task-sh"}
      }
    },
    %{
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "kill-2",
        "status" => "failed"
      }
    },
    %{"text" => "I could not stop it."}
  ]

  defp background_thread(context, text) do
    turns = [
      %{"match" => "work in the background", "steps" => @background},
      %{"match" => "try to stop the dev server", "steps" => @kill_failed},
      %{"match" => "stop the dev server", "steps" => @kill},
      %{"match" => "watch the log", "steps" => @monitor}
      | FakeAcp.turns()
    ]

    context =
      context
      |> FakeAcp.install("grok", Map.put(signed_in_config(), "turns", turns), enabled: true)
      |> FakeAcp.thread()
      |> FakeAcp.send_message(text)

    FakeAcp.await_run(context, "completed")
    [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, World.thread_id(context, context.thread))
    Map.put(context, :grok_conn, :sys.get_state(pid).conn)
  end

  # The status of each of Grok's background tool calls, by native id.
  defp background_items(state) do
    for item <- HalC2.StreamState.list(state, "turn-item"),
        id = (item["nativeItemRef"] || %{})["nativeId"],
        id in ~w(sh-1 spawn-1 mon-1),
        into: %{},
        do: {id, item["status"]}
  end

  defp runtime_pid(context) do
    [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, World.thread_id(context, context.thread))
    pid
  end

  defp session(context), do: :sys.get_state(runtime_pid(context)).session_id

  # A frame from Grok after its turn, as the agent's connection delivers it.
  defp grok_says(context, method, params) do
    pid = runtime_pid(context)
    send(pid, {:json_rpc, :sys.get_state(pid).conn, {:notification, method, params}})
  end

  # Any session counts as idle from now on.
  defp idle_now do
    Application.put_env(:hal_c2, :session_idle_ms, 0)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :session_idle_ms) end)
  end

  # The agent has started answering: the prompt reached it.
  defp await_answer(context) do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(HalC2.StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)
  end
end
