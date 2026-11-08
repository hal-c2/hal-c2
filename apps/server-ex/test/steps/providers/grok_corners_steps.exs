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
end
