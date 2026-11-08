defmodule HalC2.Orchestration.RunShape do
  @moduledoc """
  What plugins granted `runs:shape` add to a provider conversation
  (`HalC2.Plugins.shape_run/1`): context ahead of its first message, and tools turned
  off. They are asked once, as the conversation starts, and the answer is kept on its
  provider thread (`pluginShape`), so every later turn of the conversation runs with the
  same tools off: a provider whose tool list changed mid-conversation would lose its
  prompt cache (Claude relaunches with `--resume` when its launch changes). A
  conversation the provider starts afresh because the one to resume was gone
  (`HalC2.Orchestration.Handoff.fresh_start/2`) gets the kept context again without
  asking.

  What `deniedTools` names depends on the provider (`tool_unit/1`): Claude's tool names,
  Codex's capabilities (`HalC2.Codex.ThreadRuntime`), and nothing for the others, which
  get the context alone.
  """

  alias HalC2.Orchestration
  alias HalC2.Orchestration.{Entities, Handoff, TurnWriter}
  alias HalC2.StreamState

  @tool_units %{"claudeAgent" => "tool", "codex" => "capability"}
  @message_chars 8_000

  @doc "What a provider's `deniedTools` name: `\"tool\"`, `\"capability\"`, or nil for none."
  def tool_unit(driver), do: @tool_units[driver]

  @doc """
  `turn` as the plugins shape it, right before it starts: `text` with the context ahead
  of it when the turn starts a new conversation, and `denied_tools` and `shape_context`
  from the conversation's shape (none when it has none).
  """
  def apply(thread_id, turn) do
    id = Map.get(turn.ids, :provider_thread)

    stored =
      id &&
        (thread_id |> HalC2.Streams.state() |> StreamState.get("provider-thread") |> Map.get(id) ||
           %{})["pluginShape"]

    if id && TurnWriter.new_conversation?(turn) do
      shape = ask(thread_id, turn)
      if shape != stored, do: keep(thread_id, id, shape)

      turn
      |> with_shape(shape)
      |> Map.update!(:text, &Handoff.prompt(shape && shape["context"], &1))
    else
      with_shape(turn, stored)
    end
  end

  defp with_shape(turn, shape) do
    shape = shape || %{}

    turn
    |> Map.put(
      :denied_tools,
      if(tool_unit(Entities.driver(turn.ids)), do: shape["deniedTools"] || [], else: [])
    )
    |> Map.put(:shape_context, shape["context"])
  end

  defp ask(thread_id, turn) do
    driver = Entities.driver(turn.ids)

    HalC2.Plugins.shape_run(%{
      "threadId" => thread_id,
      "runId" => turn.ids.run,
      "projectId" => Map.get(turn, :project_id),
      "cwd" => Map.get(turn, :cwd),
      "instanceId" => Entities.instance(turn.ids),
      "provider" => driver,
      "model" => Map.get(turn, :model),
      "message" =>
        turn |> Map.get(:message, "") |> to_string() |> String.slice(0, @message_chars),
      "toolUnit" => tool_unit(driver)
    })
  end

  # The conversation's shape, or none, replacing what an earlier conversation of the
  # provider thread had.
  defp keep(thread_id, id, shape) do
    HalC2.Streams.transact(thread_id, :thread, fn stream ->
      if StreamState.get(stream, "provider-thread")[id] do
        {[
           Orchestration.upsert(stream, "provider-thread", id, fn provider_thread ->
             if shape,
               do: Map.put(provider_thread, "pluginShape", shape),
               else: Map.delete(provider_thread, "pluginShape")
           end)
         ], :ok}
      else
        {[], :ok}
      end
    end)
  end
end
