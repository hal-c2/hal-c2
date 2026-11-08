defmodule HalC2.CodexMcpAppPublishPropTest do
  @moduledoc """
  Where a Codex MCP app's stored document goes (`HalC2.Codex.McpApps.publish/3`), which
  a read that returned late races with the thread's deletion. A document published on
  a live thread's item is kept and named by the item; one that arrives after the
  thread was deleted, or for an item the thread does not have, is removed, so no file
  is left that nothing owns or cleans up.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{McpApps, Patch, StreamState}
  alias HalC2.Codex.McpApps, as: CodexApps

  @moduletag timeout: :infinity

  @thread "t1"
  @items ["i1", "i2", "i3"]
  @html "<!doctype html><p>app</p>"
  @mime "text/html;profile=mcp-app"
  @uri "ui://weather/forecast.html"

  property "a document stays only on a live thread's item",
    numtests: HalC2.Prop.numtests(100),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("codex-mcp-app-publish")

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

  # --- model: whether the thread is deleted, and the items holding a document ----------

  def initial_state, do: %{deleted: false, held: MapSet.new()}

  def command(_state) do
    frequency([
      {5, {:call, __MODULE__, :publish, [elements(@items ++ ["gone"])]}},
      {1, {:call, __MODULE__, :delete, []}}
    ])
  end

  # An item completes once, so it is captured once.
  def precondition(state, {:call, _, :publish, [item]}), do: not MapSet.member?(state.held, item)
  def precondition(state, {:call, _, :delete, []}), do: not state.deleted
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :publish, [item]}) do
    if state.deleted or item == "gone",
      do: state,
      else: %{state | held: MapSet.put(state.held, item)}
  end

  def next_state(state, _result, {:call, _, :delete, []}), do: %{state | deleted: true}

  def postcondition(state, {:call, _, :publish, [item]}, result) do
    after_call = next_state(state, result, {:call, __MODULE__, :publish, [item]})
    result == MapSet.member?(after_call.held, item) and files_match?(after_call)
  end

  def postcondition(state, _call, _result), do: files_match?(state)

  # Every document on disk is the one an item holds, and every held item has its own.
  defp files_match?(state) do
    items = StreamState.get(HalC2.Streams.state(@thread), "turn-item")

    held =
      for {id, %{"mcpApp" => %{"attachmentId" => document}}} <- items, do: {id, document}

    on_disk = Enum.sort(documents())

    MapSet.new(Enum.map(held, &elem(&1, 0))) == state.held and
      on_disk == Enum.sort(Enum.map(held, fn {_, document} -> document <> ".html" end))
  end

  # --- what the commands do ------------------------------------------------------------

  def publish(item) do
    contents = [%{"uri" => @uri, "mimeType" => @mime, "text" => @html}]
    app = McpApps.snapshot(@thread, "weather", "get_forecast", @uri, contents)
    CodexApps.publish(@thread, item, %{"mcpApp" => app})
  end

  def delete do
    thread = StreamState.get(HalC2.Streams.state(@thread), "thread")[@thread]
    deleted = Map.put(thread, "deletedAt", HalC2.Orchestration.Entities.now())

    {:ok, _} =
      HalC2.Streams.commit(@thread, :thread, [{"thread", @thread, Patch.diff(thread, deleted)}])

    :ok
  end

  defp documents do
    dir = HalC2.Attachments.dir()

    if File.dir?(dir),
      do: Enum.filter(File.ls!(dir), &String.contains?(&1, "-mcp-app-")),
      else: []
  end

  defp seed do
    changes =
      [
        {"thread", @thread,
         Patch.diff(nil, %{"id" => @thread, "title" => "Weather", "deletedAt" => nil})}
      ] ++
        for item <- @items do
          {"turn-item", item,
           Patch.diff(nil, %{"id" => item, "threadId" => @thread, "type" => "mcp_tool_call"})}
        end

    {:ok, _} = HalC2.Streams.commit(@thread, :thread, changes)
  end
end
