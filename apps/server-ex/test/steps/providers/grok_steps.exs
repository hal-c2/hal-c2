defmodule T3.Steps.Providers.Grok do
  @moduledoc """
  Steps for `features/providers/grok.feature`: Grok as an ACP agent, played by the
  scripted fake (`T3.Test.FakeAcp`) behind the instance's binary path.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias T3.Test.FakeAcp
  alias T3.Test.Node.World

  @models [
    %{"value" => "grok-code-fast-1", "name" => "Grok Code Fast"},
    %{"value" => "grok-4", "name" => "Grok 4"}
  ]

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
    # What the node's boot runs, then a client reading the provider list.
    T3.Acp.load()
    assert %{"enabled" => false} = FakeAcp.entry("grok")
    assert FakeAcp.starts(context, "grok") == []
    context
  end

  step "the grok command is not installed on the node", context do
    FakeAcp.services()
    T3.Acp.forget("grok")
    missing = Path.join(T3.Test.Node.tmp_dir(context.node, "no-grok"), "grok")
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
    T3.Test.Node.ensure(T3.Usage)
    root = T3.Test.Node.tmp_dir(context.node, "homes")
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
        |> T3.StreamState.list("turn-item")
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
             T3.StreamState.list(state, "provider-session"),
             &(&1["lastError"] == "Grok usage limit reached. Try again later.")
           )

    context
  end

  # --- usage limits ---------------------------------------------------------------

  step "Grok is signed in with a Grok account", context do
    home = T3.Test.Node.tmp_dir(context.node, "grok-home")

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
    requests = T3.Test.FakeHttp.requests(context.billing)
    assert [_ | _] = requests

    assert Enum.all?(
             requests,
             &match?(%{"authorization" => "Bearer grok-token", "query" => "format=credits"}, &1)
           )

    context
  end

  step "the Grok instance uses an API key", context do
    # A signed-in account is on the machine too; the key is what Grok would use.
    home = T3.Test.Node.tmp_dir(context.node, "grok-home")
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

    assert T3.Test.FakeHttp.requests(context.billing) == []
    context
  end

  # xAI's billing API, played by `T3.Test.FakeHttp`.
  defp billing(context, response) do
    {url, log} = T3.Test.FakeHttp.start(%{"/v1/billing" => {200, response}})
    Application.put_env(:t3, :grok_billing_url, url <> "/v1/billing?format=credits")
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :grok_billing_url) end)
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

  @child_session "0f8e2a4c-5b6d-4e7f-8a9b-1c2d3e4f5a6b"

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

  # The agent has started answering: the prompt reached it.
  defp await_answer(context) do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      Enum.any?(T3.StreamState.list(state, "turn-item"), &(&1["type"] == "assistant_message"))
    end)
  end
end
