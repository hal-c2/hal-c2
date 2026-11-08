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

  step "Grok is not asked to switch models", context do
    assert model_calls(context) == []
    context
  end

  step "the turn runs without that reasoning level", context do
    FakeAcp.await_run(context, "completed")

    for %{"params" => params} <- model_calls(context),
        do: refute(get_in(params, ["_meta", "reasoningEffort"]))

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
end
