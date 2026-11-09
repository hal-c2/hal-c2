defmodule HalC2.McpAppContextPropTest do
  @moduledoc """
  What a thread's MCP apps tell the model (`HalC2.McpApps.update_model_context/1`,
  `model_context/1`) and how Codex gets it (`HalC2.Codex.McpApps.context_entries/1`).
  Each app's latest update replaces its last and a blank one clears it; what is kept
  is cut to 16 KiB at a character boundary. Only apps whose run is still in the
  thread's history count: a rollback past an app's run drops its context, and a fork
  keeps the context of the apps it copies, apart from the source from then on. Codex
  gets each app's context whole, in entries it does not cut, in order.

  A thread "t1" has three finished runs, each with one app. Rollbacks are written as
  the run statuses `HalC2.Orchestration.Rollback` leaves; forks are real
  (`HalC2.Orchestration.Fork.fork/1`).
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{McpApps, Patch, StreamState}

  @moduletag timeout: :infinity

  @source "t1"
  @ordinals [1, 2, 3]

  property "an app's latest context reaches the model while its run is in the thread",
    numtests: HalC2.Prop.numtests(100),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("mcp-app-context")

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams
        ])

        seed()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # threads: id -> %{runs: ordinal -> :in | :rolled_back, apps: ordinal -> text};
  # the thread's apps are one per run, `item(ordinal)`.
  def initial_state,
    do: %{threads: %{@source => %{runs: Map.new(@ordinals, &{&1, :in}), apps: %{}}}, forks: 0}

  def command(state) do
    thread = elements(Map.keys(state.threads))

    frequency([
      {5, {:call, __MODULE__, :update, [thread, elements(@ordinals), text()]}},
      {2, {:call, __MODULE__, :rollback, [thread, elements([0 | @ordinals])]}},
      {2, {:call, __MODULE__, :fork, [thread, elements(@ordinals), "f#{state.forks + 1}"]}}
    ])
  end

  # Only an app the thread holds: a fork holds the ones up to its fork point.
  def precondition(state, {:call, _, :update, [thread, ordinal, _]}),
    do: Map.has_key?(state.threads[thread][:runs] || %{}, ordinal)

  def precondition(state, {:call, _, :rollback, [thread, _]}),
    do: Map.has_key?(state.threads, thread)

  # A fork starts after a finished run, one still in the thread.
  def precondition(state, {:call, _, :fork, [thread, ordinal, _]}),
    do: get_in(state.threads, [thread, :runs, ordinal]) == :in

  def next_state(state, _result, {:call, _, :update, [thread, ordinal, spec]}) do
    text = expand(spec)

    update_in(state.threads[thread].apps, fn apps ->
      if String.trim(text) == "",
        do: Map.delete(apps, ordinal),
        else: Map.put(apps, ordinal, cut(text))
    end)
  end

  def next_state(state, _result, {:call, _, :rollback, [thread, ordinal]}) do
    update_in(state.threads[thread].runs, fn runs ->
      Map.new(runs, fn {n, status} -> {n, if(n > ordinal, do: :rolled_back, else: status)} end)
    end)
  end

  def next_state(state, _result, {:call, _, :fork, [thread, ordinal, fork]}) do
    source = state.threads[thread]
    copied = fn map -> Map.filter(map, fn {n, _} -> n <= ordinal end) end

    %{
      state
      | threads:
          Map.put(state.threads, fork, %{runs: copied.(source.runs), apps: copied.(source.apps)}),
        forks: state.forks + 1
    }
  end

  # After every step, every thread's model context is what its model holds.
  def postcondition(state, {:call, _, _, _} = call, result) do
    after_call = next_state(state, result, call)
    result_ok?(call, result) and Enum.all?(after_call.threads, &context_matches?/1)
  end

  defp result_ok?({:call, _, :update, _}, result), do: result == {:ok, nil}
  defp result_ok?({:call, _, :fork, _}, result), do: result == :ok
  defp result_ok?(_call, _result), do: true

  defp context_matches?({thread, %{runs: runs, apps: apps}}) do
    expected =
      for {n, text} <- apps, runs[n] == :in, into: %{}, do: {"mcp_app_" <> key(n), text}

    actual = McpApps.model_context(thread)

    # Codex's entries, rejoined per app in key order, are each app's context whole.
    joined =
      thread
      |> HalC2.Codex.McpApps.context_entries()
      |> Enum.sort()
      |> Enum.group_by(fn {key, _} -> String.replace(key, ~r/_\d\d$/, "") end, fn {_, entry} ->
        entry
      end)
      |> Map.new(fn {key, entries} -> {key, Enum.map_join(entries, & &1["value"])} end)

    entries_fit? =
      thread
      |> HalC2.Codex.McpApps.context_entries()
      |> Enum.all?(fn {_, %{"kind" => "untrusted", "value" => value}} ->
        byte_size(value) <= HalC2.Mcp.Instructions.codex_entry_bytes() and String.valid?(value)
      end)

    Map.new(actual) == expected and length(actual) == map_size(expected) and joined == expected and
      entries_fit?
  end

  # --- what the commands do --------------------------------------------------------

  def update(thread, ordinal, spec) do
    McpApps.update_model_context(%{
      "threadId" => thread,
      "itemId" => item(ordinal),
      "content" => [%{"type" => "text", "text" => expand(spec)}]
    })
  end

  def rollback(thread, ordinal) do
    state = HalC2.Streams.state(thread)

    changes =
      for run <- StreamState.list(state, "run"),
          run["ordinal"] > ordinal,
          run["status"] != "rolled_back",
          do: {"run", run["id"], Patch.diff(run, %{run | "status" => "rolled_back"})}

    if changes != [], do: {:ok, _} = HalC2.Streams.commit(thread, :thread, changes)
    :ok
  end

  def fork(thread, ordinal, fork) do
    HalC2.Orchestration.Fork.fork(%{
      "commandId" => "cmd-#{fork}",
      "sourceThreadId" => thread,
      "targetThreadId" => fork,
      "sourcePoint" => %{"type" => "run", "runId" => run(ordinal)}
    })
  end

  # --- the thread ------------------------------------------------------------------

  # Each app's document is a real file with the `-mcp-app-` marker the publisher gives
  # it: a fork copies the document (`Attachments.copy/2`) and drops an app without one.
  defp seed do
    File.mkdir_p!(HalC2.Attachments.dir())

    for n <- @ordinals do
      File.write!(Path.join(HalC2.Attachments.dir(), document(n) <> ".html"), "<p>app #{n}</p>")
    end

    thread = %{"id" => @source, "title" => "Weather", "deletedAt" => nil}

    changes =
      [create("thread", @source, thread)] ++
        Enum.flat_map(@ordinals, fn n ->
          [
            create("run", run(n), %{
              "id" => run(n),
              "threadId" => @source,
              "ordinal" => n,
              "status" => "completed"
            }),
            create("turn-item", item(n), %{
              "id" => item(n),
              "threadId" => @source,
              "runId" => run(n),
              "type" => "mcp_tool_call",
              "mcpApp" => %{
                "server" => "weather",
                "tool" => "get_forecast",
                "attachmentId" => document(n)
              }
            })
          ]
        end)

    {:ok, _} = HalC2.Streams.commit(@source, :thread, changes)
  end

  defp create(kind, id, entity), do: {kind, id, Patch.diff(nil, entity)}

  defp document(n), do: "#{HalC2.Attachments.thread_segment(@source)}-mcp-app-doc#{n}"
  defp run(n), do: "run:#{n}"
  defp item(n), do: "turn-item:codex:app-#{n}"
  defp key(n), do: "turn-item_codex_app-#{n}"

  # --- texts -----------------------------------------------------------------------

  # Small to print: a blank update, a short one, or a character repeated, over 16 KiB
  # for some, of one to four UTF-8 bytes so the cut can land inside one.
  defp text do
    oneof([
      {:text, oneof(["", "  \n"])},
      {:text, oneof(["sunny", "rain in Oslo", "ünïcödé"])},
      {:repeat, oneof(["a", "é", "€", "𝄞"]), oneof([10, 4_000, 5_000, 16_384, 17_000])}
    ])
  end

  defp expand({:text, text}), do: text
  defp expand({:repeat, char, count}), do: String.duplicate(char, count)

  # The longest run of whole characters within 16 KiB.
  defp cut(text) do
    text
    |> String.codepoints()
    |> Enum.reduce_while({"", 0}, fn char, {kept, bytes} ->
      if bytes + byte_size(char) <= 16 * 1024,
        do: {:cont, {kept <> char, bytes + byte_size(char)}},
        else: {:halt, {kept, bytes}}
    end)
    |> elem(0)
  end
end
