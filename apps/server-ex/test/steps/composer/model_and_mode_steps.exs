defmodule HalC2.Steps.Composer.ModelAndMode do
  @moduledoc "Steps for `features/composer/model-and-mode.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node.World

  # The runtime mode each permission level is, and what Codex is told for it.
  @modes %{
    "Supervised" => {"approval-required", "untrusted", "readOnly"},
    "Auto-accept edits" => {"auto-accept-edits", "on-request", "workspaceWrite"},
    "Auto" => {"auto", "on-request", "workspaceWrite"},
    "Full access" => {"full-access", "never", "dangerFullAccess"}
  }

  step "a project with an open thread on Codex", context do
    context
    |> World.create_project("shop")
    |> World.create_thread("Open thread", "shop")
    |> Map.put(:current, "Open thread")
    |> then(&World.put_client(&1, World.client(&1)))
    |> World.agents()
  end

  step ~r/^the user sets the permissions to (?<mode>.+)$/, %{args: [mode]} = context do
    {runtime_mode, _, _} = Map.fetch!(@modes, mode)

    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.runtime-mode.set",
        "threadId" => World.thread_id(context, context.current),
        "runtimeMode" => runtime_mode
      })

    assert World.thread(context, context.current)["runtimeMode"] == runtime_mode
    context
  end

  step ~r/^the next turn runs in (?<mode>Supervised|Auto-accept edits|Auto|Full access)$/,
       %{args: [mode]} = context do
    {_, approval, sandbox} = Map.fetch!(@modes, mode)
    turn = next_turn(context)
    assert %{"approvalPolicy" => ^approval, "sandboxPolicy" => %{"type" => ^sandbox}} = turn
    context
  end

  step "the thread is building", context do
    assert World.thread(context, context.current)["interactionMode"] == "default"
    context
  end

  step "the user toggles to planning", context do
    interaction(context, "plan")
  end

  step "the user toggles back", context do
    interaction(context, "default")
  end

  step "the next turn plans instead of making changes", context do
    assert %{"collaborationMode" => %{"mode" => "plan"}} = next_turn(context)
    context
  end

  step "the next turn builds again", context do
    assert %{"collaborationMode" => %{"mode" => "default"}} = next_turn(context)
    context
  end

  defp interaction(context, mode) do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.interaction-mode.set",
        "threadId" => World.thread_id(context, context.current),
        "interactionMode" => mode
      })

    context
  end

  # Sends a message, waits for its turn to finish, and returns what Codex was told.
  defp next_turn(context) do
    thread = context.current
    done = length(World.codex_requests(context, "turn/start"))
    {{:ok, _}, context} = World.send_message(context, thread, "go on")

    World.await_thread(context, thread, fn state ->
      runs = HalC2.StreamState.list(state, "run")
      length(runs) == done + 1 and Enum.all?(runs, &(&1["status"] == "completed"))
    end)

    context |> World.codex_requests("turn/start") |> Enum.at(done)
  end
end
