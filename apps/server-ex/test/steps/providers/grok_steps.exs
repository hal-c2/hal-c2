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
      &(length(&1["pendingBackgroundTasks"] || []) == 2)
    )

    context
  end

  step "Grok left a persistent monitor running", context do
    background_thread(context, "watch the log")
  end

  step "{string} lists the command and the subagent as background work",
       %{args: [thread]} = context do
    assert ["command_execution", "subagent"] =
             World.row(context, thread)["pendingBackgroundTasks"]
             |> Enum.map(& &1["taskType"])
             |> Enum.sort()

    context
  end

  step "{string} lists only the subagent as background work", %{args: [thread]} = context do
    World.await_row(
      World.thread_id(context, thread),
      &match?([%{"taskType" => "subagent"}], &1["pendingBackgroundTasks"])
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
    World.await_row(id, &(&1["pendingBackgroundTasks"] == []))
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
    World.await_row(id, &(&1["pendingBackgroundTasks"] == []))

    assert %{"mon-1" => "running"} =
             background_items(World.state(context, context.thread))

    context
  end

  defp background_thread(context, text) do
    turns = [
      %{"match" => "work in the background", "steps" => @background},
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
