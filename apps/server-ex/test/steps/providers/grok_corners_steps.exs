defmodule HalC2.Steps.Providers.GrokCorners do
  @moduledoc """
  More steps for `features/providers/grok.feature`: the corners of model and reasoning
  selection, questions and plans, tool naming, monitors and background work. Grok is the
  scripted fake (`HalC2.Test.FakeAcp`) behind the instance's binary path.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc.World

  # --- model and reasoning selection -------------------------------------------------

  @picked "grok-4"

  # Grok reports its models the way `session/new` does: the model it is on, and for each
  # model the reasoning level it starts at.
  defp session_models(effort) do
    %{
      "configOptions" => [],
      "sessionModels" => %{
        "currentModelId" => @picked,
        "availableModels" => [
          %{
            "modelId" => @picked,
            "name" => "Grok 4",
            "_meta" =>
              %{"supportsReasoningEffort" => true}
              |> then(&if(effort, do: Map.put(&1, "reasoningEffort", effort), else: &1))
          },
          %{"modelId" => "grok-code-fast-1", "name" => "Grok Code Fast"}
        ]
      }
    }
  end

  defp model_thread(context, effort, model, reasoning) do
    options = if reasoning, do: [%{"id" => "reasoningEffort", "value" => reasoning}], else: []

    context
    |> FakeAcp.install("grok", session_models(effort), enabled: true)
    |> FakeAcp.thread("Work", "full-access", %{
      "modelSelection" => %{"instanceId" => "grok", "model" => model, "options" => options}
    })
    |> Map.put(:current_thread, "Work")
  end

  defp run_turn(context) do
    context = FakeAcp.send_message(context, "hello grok")
    FakeAcp.await_run(context, "completed")
    context
  end

  defp model_calls(context), do: FakeAcp.received(context, "session/set_model")

  step "a Grok session that started on the model Grok picked", context do
    Map.put(context, :grok_effort, nil)
  end

  step "a Grok session running on a model at the reasoning level Grok chose", context do
    Map.put(context, :grok_effort, "high")
  end

  step "a Grok thread whose saved reasoning level is not a plain word", context do
    model_thread(context, "medium", @picked, "extra high!")
  end

  step "a turn runs with Grok's default model chosen", context do
    context |> model_thread(context.grok_effort, "grok-build", nil) |> run_turn()
  end

  step "a turn runs with Grok's default model and a reasoning level chosen", context do
    context |> model_thread(context.grok_effort, "grok-build", "low") |> run_turn()
  end

  step "a turn runs on that model with no reasoning level chosen", context do
    context |> model_thread(context.grok_effort, @picked, nil) |> run_turn()
  end

  step "a turn runs on that model at reasoning {string} and the next with no reasoning level chosen",
       %{args: [level]} = context do
    context = context |> model_thread(context.grok_effort, @picked, level) |> run_turn()

    context
    |> FakeAcp.send_message("again", nil, %{
      "modelSelection" => %{"instanceId" => "grok", "model" => @picked, "options" => []}
    })
    |> tap(&FakeAcp.await_runs(&1, 2))
  end

  step "a turn at reasoning {string} during which Grok reports its options, then one with no level chosen",
       %{args: [level]} = context do
    # A mid-session options report names no models, so it says nothing of their levels.
    report = %{"update" => %{"sessionUpdate" => "config_option_update", "configOptions" => []}}

    context =
      context
      |> model_thread(context.grok_effort, @picked, level)
      |> FakeAcp.configure("grok", fn config ->
        Map.update!(config, "turns", &[%{"match" => "hello grok", "steps" => [report]} | &1])
      end)
      |> run_turn()

    context
    |> FakeAcp.send_message("again", nil, %{
      "modelSelection" => %{"instanceId" => "grok", "model" => @picked, "options" => []}
    })
    |> tap(&FakeAcp.await_runs(&1, 2))
  end

  step "Grok is asked for {string} and then for the level the model started at",
       %{args: [level]} = context do
    started = context.grok_effort

    assert [
             %{"params" => %{"modelId" => @picked, "_meta" => %{"reasoningEffort" => ^level}}},
             %{"params" => %{"modelId" => @picked, "_meta" => %{"reasoningEffort" => ^started}}}
           ] = model_calls(context)

    context
  end

  step "the run records the model the session is on, with no notice", context do
    state = FakeAcp.await_run(context, "completed")
    assert [%{"appliedModel" => @picked}] = HalC2.StreamState.list(state, "run")
    refute Enum.any?(HalC2.StreamState.list(state, "turn-item"), &(&1["type"] == "system_notice"))
    context
  end

  step "Grok is not asked to switch models", context do
    assert model_calls(context) == []
    context
  end

  step "the turn runs without that reasoning level", context do
    FakeAcp.await_run(context, "completed")

    for %{"params" => params} <- model_calls(context),
        do: refute(get_in(params, ["_meta", "reasoningEffort"]))

    # The session is already on that model and level: nothing about it is sent again.
    assert model_calls(context) == []
    context
  end

  step "Grok is asked for that reasoning level on the model the session already has",
       context do
    assert [%{"params" => %{"modelId" => @picked, "_meta" => %{"reasoningEffort" => "low"}}}] =
             model_calls(context)

    context
  end

  step "Grok is not asked to change its reasoning level", context do
    assert model_calls(context) == []
    context
  end

  # --- questions ---------------------------------------------------------------------

  # Grok asks `questions` in one turn and then says it is done; the turn waits on the
  # answer.
  defp ask(context, questions) do
    turns = [
      %{
        "match" => "ask me",
        "steps" => [
          %{
            "request" => %{
              "method" => "x.ai/ask_user_question",
              "params" => %{"toolCallId" => "q-1", "mode" => "default", "questions" => questions}
            }
          },
          %{"text" => "Thanks."}
        ]
      }
      | FakeAcp.turns()
    ]

    context
    |> FakeAcp.install("grok", %{"configOptions" => [], "turns" => turns}, enabled: true)
    |> FakeAcp.thread("Work", "approval-required")
    |> FakeAcp.send_message("ask me")
    |> then(&Map.put(&1, :question, FakeAcp.await_request(&1)))
  end

  defp question_item(context) do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      state
      |> HalC2.StreamState.list("turn-item")
      |> Enum.find(&(&1["type"] == "user_input_request"))
    end)
  end

  defp answer_to_grok(context, status \\ "completed") do
    FakeAcp.await_run(context, status)
    assert [%{"result" => result}] = FakeAcp.answers(context)
    result
  end

  defp options(labels), do: for(label <- labels, do: %{"label" => label})

  step "Grok asks a question with no options", context do
    ask(context, [%{"question" => "Proceed?", "options" => []}])
  end

  step "Grok asks a question that allows several answers", context do
    ask(context, [
      %{"question" => "Which?", "multiSelect" => true, "options" => options(["A", "B", "C"])}
    ])
  end

  step "Grok asks a question that leaves out whether several answers are allowed", context do
    ask(context, [%{"question" => "Which?", "options" => options(["A", "B"])}])
  end

  step "Grok asks a question and the user types an answer of their own", context do
    context = ask(context, [%{"question" => "Which?", "options" => options(["A", "B"])}])
    FakeAcp.respond(context, context.question["id"], %{"answers" => %{"Which?" => "Neither"}})
  end

  step "Grok asks a question and the turn is stopped before an answer", context do
    context = ask(context, [%{"question" => "Which?", "options" => options(["A", "B"])}])

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "run.interrupt",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, context.thread)
      })

    context
  end

  step "the user is offered \"OK\" to continue", context do
    assert [%{"multiSelect" => false, "options" => [%{"label" => "OK"}]}] =
             question_item(context)["questions"]

    context
  end

  step "the user can pick several options", context do
    assert [%{"multiSelect" => true, "options" => [_, _, _]}] =
             question_item(context)["questions"]

    context
  end

  step "the user can pick one option only", context do
    assert [%{"multiSelect" => false, "options" => [_, _]}] = question_item(context)["questions"]
    context
  end

  step "Grok receives the typed text as its \"Other\" answer", context do
    assert %{
             "outcome" => "accepted",
             "answers" => %{"Which?" => ["Other"]},
             "annotations" => %{"Which?" => %{"notes" => "Neither"}}
           } = answer_to_grok(context)

    context
  end

  step "Grok is told the question was cancelled", context do
    assert %{"outcome" => "cancelled"} = answer_to_grok(context, "interrupted")
    context
  end

  step "Grok asked two questions at once", context do
    context =
      ask(context, [
        %{"question" => "Zebra?", "options" => options(["yes", "no"])},
        %{"question" => "Apple?", "options" => options(["red", "green"])}
      ])

    context
  end

  step "the user answers the second question before the first", context do
    FakeAcp.respond(context, context.question["id"], %{
      "answers" => %{"Apple?" => "red", "Zebra?" => "no"}
    })
  end

  step "Grok receives the answers in the order it asked, each under the question's own text",
       context do
    FakeAcp.await_run(context, "completed")
    path = Path.join(FakeAcp.fake(context).dir, "log.jsonl")
    line = path |> File.read!() |> String.split("\n") |> Enum.find(&(&1 =~ "\"accepted\""))
    assert line =~ ~r/"Zebra\?": \["no"\].*"Apple\?": \["red"\]/
    context
  end

  @previews [
    %{"label" => "Small", "preview" => "[]"},
    %{"label" => "Large", "preview" => "[    ]"}
  ]

  step "Grok asked a question whose options carry previews", context do
    Map.put(context, :preview_options, @previews)
  end

  step "the user answers a question that allows one answer", context do
    context = ask(context, [%{"question" => "Size?", "options" => context.preview_options}])
    FakeAcp.respond(context, context.question["id"], %{"answers" => %{"Size?" => "Large"}})
  end

  step "the user answers a question that allows several answers", context do
    context =
      ask(context, [
        %{"question" => "Size?", "multiSelect" => true, "options" => context.preview_options}
      ])

    FakeAcp.respond(context, context.question["id"], %{"answers" => %{"Size?" => ["Large"]}})
  end

  step "Grok's answer carries the chosen option's preview", context do
    assert %{"annotations" => %{"Size?" => %{"preview" => "[    ]"}}} = answer_to_grok(context)
    context
  end

  step "Grok's answer carries no preview", context do
    result = answer_to_grok(context)
    refute Map.has_key?(result, "annotations")
    context
  end

  # --- plans -------------------------------------------------------------------------

  @draft "# Plan\n\n1. Add the form"

  # Grok's session folder under a Grok home this scenario owns.
  defp plan_home(context) do
    home = Path.join(System.tmp_dir!(), "grok-home-#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(home) end)
    Map.put(context, :plan_home, home)
  end

  defp with_home(context), do: if(context[:plan_home], do: context, else: plan_home(context))

  defp plan_path(context, name \\ "plan.md"),
    do: Path.join([context.plan_home, "sessions", "-work-shop", "sess-1", name])

  defp exit_plan(content) do
    %{
      "request" => %{
        "method" => "x.ai/exit_plan_mode",
        "params" =>
          %{"toolCallId" => "plan-1"}
          |> then(&if(content, do: Map.put(&1, "planContent", content), else: &1))
      }
    }
  end

  defp write_file(id, path, content) do
    %{
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => id,
        "title" => "Write",
        "kind" => "edit",
        "status" => "completed",
        "locations" => [%{"path" => path}],
        "rawInput" => %{"file_path" => path, "content" => content}
      }
    }
  end

  # A turn of Grok in plan mode that does `steps`, on an instance whose Grok home is
  # this scenario's. The thread is the one "a Grok thread in plan mode" made.
  defp plan_turn(context, steps) do
    context = if context[:plan_home], do: context, else: plan_home(context)

    turns = [
      %{"match" => "plan it", "steps" => steps ++ [%{"text" => "Done."}]} | FakeAcp.turns()
    ]

    FakeAcp.configure(context, "grok", &Map.put(&1, "turns", turns))

    FakeAcp.settings(
      &Map.put(&1, "providerInstances", %{
        "grok" => %{
          "driver" => "grok",
          "environment" => [%{"name" => "GROK_HOME", "value" => context.plan_home}]
        }
      })
    )

    context = FakeAcp.send_message(context, "plan it")
    FakeAcp.await_run(context, "completed")
    context
  end

  defp plans(context) do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      case Enum.filter(HalC2.StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan")) do
        [] -> nil
        plans -> plans
      end
    end)
  end

  step "a Grok thread in plan mode whose plan file has been written", context do
    context
    |> plan_home()
    |> FakeAcp.install("grok", %{"configOptions" => []}, enabled: true)
    |> FakeAcp.thread("Work", "approval-required", %{"interactionMode" => "plan"})
  end

  step "Grok presents its plan", context do
    plan_turn(context, [exit_plan(@draft)])
  end

  step "Grok leaves plan mode without writing a plan", context do
    plan_turn(context, [exit_plan(nil)])
  end

  step "Grok presents its plan without including the plan's text", context do
    context = with_home(context)
    plan_turn(context, [write_file("w1", plan_path(context), @draft), exit_plan(nil)])
  end

  step "Grok writes the plan file of its own session", context do
    context = with_home(context)

    plan_turn(context, [
      write_file("w1", plan_path(context), "# First draft"),
      write_file("w2", plan_path(context), @draft),
      write_file("w3", "/work/shop/plan.md", "workspace notes")
    ])
  end

  step "Grok writes \"plan.md\" under the sessions folder of the Grok home the instance sets",
       context do
    context = with_home(context)
    plan_turn(context, [write_file("w1", plan_path(context), @draft)])
  end

  step "Grok writes \"plan.md\" under the sessions folder with different letter case, Windows",
       context do
    context = with_home(context)
    Application.put_env(:hal_c2, :os_type, {:win32, :nt})
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :os_type) end)

    path =
      Path.join([context.plan_home, "SESSIONS", "-Work-Shop", "Sess-1", "PLAN.md"])

    plan_turn(context, [write_file("w1", path, @draft)])
  end

  step "Grok writes \"plan.md\" at a path that climbs out of the sessions folder with \"..\"",
       context do
    context = with_home(context)
    path = Path.join([context.plan_home, "sessions", "..", "elsewhere", "sess-1", "plan.md"])
    plan_turn(context, [write_file("w1", path, @draft)])
  end

  step "Grok writes its plan file in two plan-mode turns", context do
    context = with_home(context)
    context = plan_turn(context, [write_file("w1", plan_path(context), "# First plan")])
    plan_turn(context, [write_file("w2", plan_path(context), "# Revised plan")])
  end

  step "both plans are kept, each as its own plan", context do
    thread = World.thread_id(context, context.thread)

    plans =
      World.await_stream(thread, fn state ->
        case Enum.filter(HalC2.StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan")) do
          [_, _ | _] = plans -> plans
          _ -> nil
        end
      end)

    assert plans |> Enum.map(& &1["markdown"]) |> Enum.sort() == [
             "# First plan",
             "# Revised plan"
           ]

    context
  end

  step "the plan is shown for the user to review", context do
    assert [%{"markdown" => @draft}] = plans(context)
    context
  end

  step "Grok is told to stop and wait for feedback or a request to implement it", context do
    assert [%{"result" => %{"outcome" => "abandoned", "feedback" => feedback}}] =
             FakeAcp.answers(context)

    assert feedback =~ "Stop here and wait for the user's feedback or implementation request"
    context
  end

  step "the plan reads \"No plan written yet\"", context do
    assert [%{"markdown" => "# No plan written yet" <> _}] = plans(context)
    context
  end

  step "the thread's plan follows what Grok wrote", context do
    assert [%{"markdown" => @draft}] = plans(context)
    context
  end

  step "a file named \"plan.md\" that Grok edits in the workspace is shown as an ordinary edit",
       context do
    # The workspace file is a tool call of the turn, not the plan.
    thread = World.thread_id(context, context.thread)

    World.await_stream(thread, fn state ->
      state
      |> HalC2.StreamState.list("turn-item")
      |> Enum.find(&(&1["type"] != "plan" and JSON.encode!(&1) =~ "/work/shop/plan.md"))
    end)

    assert [%{"markdown" => @draft}] = plans(context)
    context
  end

  step "the plan shown is the plan file's content", context do
    assert [%{"markdown" => @draft}] = plans(context)
    context
  end

  step "the write is shown as the plan", context do
    assert [%{"markdown" => @draft}] = plans(context)
    context
  end

  step "the write is shown as an ordinary edit", context do
    assert [] == proposed_plans_now(context)
    context
  end

  defp proposed_plans_now(context) do
    context.thread
    |> then(&World.thread_id(context, &1))
    |> HalC2.Streams.state()
    |> HalC2.StreamState.list("plan")
    |> Enum.filter(&(&1["kind"] == "proposed_plan"))
  end

  # --- tool names and command results ------------------------------------------------

  # Grok runs one tool call, `call` merged over a finished tool titled "Tool", in a turn.
  defp run_call(context, call, opts \\ []) do
    update =
      Map.merge(
        %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t-1",
          "title" => "Tool",
          "status" => "completed"
        },
        call
      )

    turns = [
      %{
        "match" => "run it",
        "steps" => [
          %{"update" => update}
          | if(opts[:hang], do: [%{"hang" => true}], else: [%{"text" => "Done."}])
        ]
      }
      | FakeAcp.turns()
    ]

    context =
      context
      |> FakeAcp.install("grok", %{"configOptions" => [], "turns" => turns}, enabled: true)
      |> FakeAcp.thread("Work", "full-access")
      |> FakeAcp.send_message("run it")

    unless opts[:hang], do: FakeAcp.await_run(context, "completed")
    context
  end

  defp tool_item(context) do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      state
      |> HalC2.StreamState.list("turn-item")
      |> Enum.find(&(&1["toolName"] || &1["input"] || &1["type"] == "subagent"))
    end)
  end

  defp named(context, name) do
    item = tool_item(context)
    assert (item["toolName"] || item["title"] || item["input"]) == name
    context
  end

  step "Grok runs a tool that carries a description titled \"Tool\"", context do
    run_call(context, %{"rawInput" => %{"description" => "Lint the code"}})
  end

  step "Grok runs a monitor described as \"watch the build\" titled \"Tool\"", context do
    run_call(context, %{
      "rawInput" => %{"variant" => "monitor", "description" => "watch the build"}
    })
  end

  step "Grok runs a monitor with no description titled \"Tool\"", context do
    run_call(context, %{"rawInput" => %{"variant" => "monitor"}})
  end

  step "Grok runs a subagent task with no description titled \"Tool\"", context do
    run_call(context, %{"rawInput" => %{"variant" => "task"}})
  end

  step "Grok runs a check on a background task titled \"Tool\"", context do
    run_call(context, %{"rawInput" => %{"variant" => "taskoutput"}})
  end

  @long String.duplicate("make ", 20)

  step "Grok runs a command of more than 80 characters titled \"Tool\"", context do
    run_call(context, %{"rawInput" => %{"command" => @long}})
  end

  step "Grok runs a command titled \"Tool\" whose 77th character falls inside an emoji",
       context do
    run_call(context, %{
      "rawInput" => %{"command" => String.duplicate("a", 76) <> "😀" <> String.duplicate("b", 20)}
    })
  end

  step("the tool call is named that description", context, do: named(context, "Lint the code"))

  step("the tool call is named \"Monitor: watch the build\"", context,
    do: named(context, "Monitor: watch the build")
  )

  step("the tool call is named \"Monitor\"", context, do: named(context, "Monitor"))
  step("the tool call is named \"Task\"", context, do: named(context, "Task"))
  step("the tool call is named \"Task output\"", context, do: named(context, "Task output"))

  step "the tool call is named the command's first 77 characters followed by \"...\"",
       context do
    named(context, String.slice(@long, 0, 77) <> "...")
  end

  step "the tool call is named by the command up to just before that emoji, followed by \"...\"",
       context do
    named(context, String.duplicate("a", 76) <> "...")
  end

  step "Grok runs a command titled \"Tool\" of 41 emoji, 41 characters but 82 UTF-16 units",
       context do
    run_call(context, %{"rawInput" => %{"command" => String.duplicate("😀", 41)}})
  end

  step "the tool call is named by the first 38 emoji followed by \"...\"", context do
    named(context, String.duplicate("😀", 38) <> "...")
  end

  step "the name holds no replacement character", context do
    item = tool_item(context)
    refute (item["toolName"] || item["input"] || "") =~ "\uFFFD"
    context
  end

  defp bash(code, output, status \\ "completed") do
    %{
      "kind" => "execute",
      "rawInput" => %{"command" => "make"},
      "status" => status,
      "rawOutput" => %{"type" => "Bash", "exit_code" => code, "output" => output}
    }
  end

  step "Grok reports a command result with exit code 0 and no output yet", context do
    run_call(context, bash(0, "", "in_progress"), hang: true)
  end

  step "Grok reports a command result with exit code 0, no output, and says it completed",
       context do
    run_call(context, bash(0, ""))
  end

  step "Grok reports a command result with exit code 0 and its output", context do
    run_call(context, bash(0, "built"))
  end

  step "Grok reports a command result with a non-zero exit code", context do
    run_call(context, bash(2, "boom"))
  end

  step "Grok reports a command result with the text \"Exit Code: -1\"", context do
    run_call(context, %{
      "kind" => "execute",
      "rawInput" => %{"command" => "make"},
      "content" => [
        %{"type" => "content", "content" => %{"type" => "text", "text" => "Exit Code: -1"}}
      ]
    })
  end

  defp command_status(context) do
    World.await_stream(World.thread_id(context, context.thread), fn state ->
      state
      |> HalC2.StreamState.list("turn-item")
      |> Enum.find(&(&1["type"] == "command_execution" or &1["input"] == "make"))
    end)["status"]
  end

  step "the command result is shown as in progress", context do
    assert command_status(context) in ["running", "in_progress", "inProgress"]
    context
  end

  step "the command result is shown as completed", context do
    assert command_status(context) == "completed"
    context
  end

  step "the command result is shown as failed", context do
    assert command_status(context) == "failed"
    context
  end

  step "Grok runs a tool and gives it no title", context do
    run_call(context, %{
      "title" => "",
      "kind" => "execute",
      "rawInput" => %{"command" => "mix test"}
    })
  end

  step "the tool call is named after the command, file or search it works on", context do
    named(context, "mix test")
  end
end
