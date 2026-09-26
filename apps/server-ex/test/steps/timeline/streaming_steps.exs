defmodule T3.Steps.Timeline.Streaming do
  @moduledoc """
  Steps for `features/timeline/streaming.feature`. The fake Codex writes its reply in
  pieces ("stream paragraphs", "stream a reply") and waits at a gate between pieces
  until the step has seen what the node wrote so far, so every intermediate state of
  the reply is observed without timers.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.StreamState
  alias T3.Test.Node.World

  step ~r/^the project streams responses by (?<mode>paragraph|turn)$/,
       %{args: [mode]} = context do
    T3.Test.Node.ensure(T3.Settings)
    {settings, version} = T3.Settings.get()
    project = World.project(context).id
    overrides = %{project => %{"responseStreamingMode" => mode}}
    {:ok, _} = T3.Settings.put(Map.put(settings, "projectSettingsOverrides", overrides), version)
    context
  end

  step "the agent writes a reply of three paragraphs", context do
    texts =
      follow(context, "stream paragraphs", fn state, texts ->
        case reply(state) do
          "One.\n\n" -> World.open_gate(context, "go-1")
          "One.\n\nTwo.\n\n" -> World.open_gate(context, "go-2")
          _ -> :ok
        end

        record(state, texts)
      end)

    Map.put(context, :texts, texts)
  end

  step "each paragraph appears once it is finished", context do
    assert ["One.\n\n", "One.\n\nTwo.\n\n", "One.\n\nTwo.\n\n```\ncode\n```\n\nThree."] =
             Enum.reject(context.texts, &(&1 == ""))

    context
  end

  step "an unfinished code block is held back until it closes", context do
    for text <- context.texts,
        String.contains?(text, "```\ncode"),
        do: assert(String.contains?(text, "code\n```"))

    context
  end

  step "the agent writes a reply", context do
    texts =
      follow(context, "stream a reply", fn state, texts ->
        tool =
          Enum.find(StreamState.list(state, "turn-item"), &(&1["type"] == "command_execution"))

        plan = Enum.find(StreamState.list(state, "plan"), & &1["steps"])

        # The command's output and the plan are already there; the text is not.
        if tool && tool["output"] == "a.txt\n" && plan && texts[:during_tool] == nil do
          World.open_gate(context, "go-1")
          record(state, Map.put(texts, :during_tool, reply(state)))
        else
          record(state, texts)
        end
      end)

    Map.put(context, :texts, texts)
  end

  step "no reply text appears until the agent finishes writing it", context do
    assert Enum.reject(context.texts.seen, &(&1 == "")) == [
             "Working on it.\n\nStill going.\n\nDone."
           ]

    context
  end

  step "tool calls and plans still appear as they happen", context do
    # Seen while the command ran and the plan was set: the reply had no text yet.
    assert Map.fetch!(context.texts, :during_tool) in [nil, ""]
    context
  end

  # Sends `text` and calls `fun.(state, acc)` on every commit to the thread until its
  # run completes; `record/2` keeps the distinct reply texts in order.
  defp follow(context, text, fun) do
    title = World.current(context)
    {{:ok, _}, context} = World.send_message(context, title, text)
    id = World.thread_id(context, title)
    loop(id, World.stream(context, title), fun, %{seen: []})
  end

  defp loop(id, state, fun, acc) do
    acc = fun.(state, acc)

    if Enum.any?(StreamState.list(state, "run"), &(&1["status"] == "completed")) do
      if Map.keys(acc) == [:seen], do: acc.seen, else: acc
    else
      receive do
        {:t3_stream, ^id, _} -> loop(id, T3.Streams.Server.state(T3.Streams.ensure(id)), fun, acc)
      after
        5_000 -> flunk("the reply stopped at #{inspect(acc)}")
      end
    end
  end

  defp record(state, texts) when is_list(texts), do: record(state, %{seen: texts})[:seen]

  defp record(state, %{seen: seen} = acc) do
    text = reply(state)

    if text in [nil, List.last(seen)],
      do: acc,
      else: %{acc | seen: seen ++ [text]}
  end

  defp reply(state) do
    Enum.find_value(
      StreamState.list(state, "message"),
      &(&1["role"] == "assistant" && &1["text"])
    )
  end
end
