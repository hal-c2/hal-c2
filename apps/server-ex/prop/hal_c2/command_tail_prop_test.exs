defmodule HalC2.CommandTailPropTest do
  @moduledoc """
  A thread's running commands (`HalC2.Orchestration.CommandTail` and the output path of
  `HalC2.Orchestration.TurnWriter`) against a model of what each promises: a running
  command's output is printed into the tail, which keeps the last 64 KiB and the
  count of bytes printed, never reaching the thread but for `outputSize`; a
  refetch returns the whole tail. A command that ends keeps the provider's output cut
  to the last 256 KiB (or, when it gave none, what was printed, cut to the tail); one
  the turn stopped keeps what it printed. Every ended command, and every command of a
  run that ended, has no tail left.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Orchestration.{CommandTail, TurnWriter}
  alias HalC2.{Store, Streams, StreamState}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @thread "t-prop"
  @ids ["i1", "i2", "i3"]
  @limit 64 * 1024
  @kept 256 * 1024

  property "a running command's output is bounded, fetched whole, and never leaked",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("command-tail")

        HalC2.Prop.start_services([
          {Store, path: Store.home_path()},
          Streams,
          CommandTail
        ])

        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # items: id => %{state: :running | :ended, printed: all text printed so far, kept: the
  # output the thread keeps once ended}
  def initial_state, do: %{items: %{}}

  def command(%{items: items}) do
    created = Map.keys(items)
    running = for {id, %{state: :running}} <- items, do: id

    frequency(
      [{3, {:call, __MODULE__, :create, [oneof(@ids)]}}] ++
        if(running == [],
          do: [],
          else: [
            {8, {:call, __MODULE__, :print, [oneof(running), text()]}},
            {2, {:call, __MODULE__, :finish, [oneof(running), provider_output()]}},
            {1, {:call, __MODULE__, :interrupt, []}},
            {1, {:call, __MODULE__, :run_ends, []}}
          ]
        ) ++
        if(created == [], do: [], else: [{3, {:call, __MODULE__, :refetch, [oneof(created)]}}])
    )
  end

  def precondition(%{items: items}, {:call, _, :create, [id]}), do: not is_map_key(items, id)

  def precondition(%{items: items}, {:call, _, name, [id | _]}) when name in [:print, :finish],
    do: items[id][:state] == :running

  def precondition(%{items: items}, {:call, _, :refetch, [id]}), do: is_map_key(items, id)
  def precondition(_state, _call), do: true

  def next_state(state, _res, {:call, _, :create, [id]}),
    do: put_in(state.items[id], %{state: :running, printed: "", kept: ""})

  def next_state(state, _res, {:call, _, :print, [id, text]}),
    do: update_in(state.items[id].printed, &(&1 <> text))

  def next_state(state, _res, {:call, _, :finish, [id, output]}) do
    item = state.items[id]
    kept = if output == "", do: last(item.printed, @limit), else: last(output, @kept)
    put_in(state.items[id], %{item | state: :ended, kept: kept})
  end

  def next_state(state, _res, {:call, _, :interrupt, []}) do
    items =
      Map.new(state.items, fn
        {id, %{state: :running} = item} ->
          {id, %{item | state: :ended, kept: last(item.printed, @limit)}}

        other ->
          other
      end)

    %{state | items: items}
  end

  def next_state(state, _res, {:call, _, :run_ends, []}) do
    # Whatever was running is gone from memory; the thread learns of it elsewhere
    # (the run's end closes its items), so the model only demands the tail is freed.
    items =
      Map.new(state.items, fn
        {id, %{state: :running} = item} -> {id, %{item | state: :dropped}}
        other -> other
      end)

    %{state | items: items}
  end

  def next_state(state, _res, {:call, _, :refetch, _}), do: state

  # Every item of the model after the call, against the tail and the thread.
  def postcondition(state, call, result) do
    after_call = next_state(state, result, call)

    Enum.all?(after_call.items, fn {id, item} ->
      tail = CommandTail.get(@thread, "item-#{id}")

      case item.state do
        :running ->
          held = last(item.printed, @limit)
          shown = thread_item(id)

          tail == if(item.printed == "", do: nil, else: held) and shown["output"] == "" and
            (item.printed == "" or shown["outputSize"] == byte_size(item.printed))

        :ended ->
          tail == nil and thread_item(id)["output"] == item.kept

        :dropped ->
          tail == nil
      end
    end) and refetched?(call, result, after_call)
  end

  # A refetch returns the whole tail: what the item's printed text ends with.
  defp refetched?({:call, _, :refetch, [id]}, tail, state) do
    case state.items[id] do
      %{state: :running, printed: printed} when printed != "" -> tail == last(printed, @limit)
      _ -> tail == nil
    end
  end

  defp refetched?(_call, _result, _state), do: true

  # --- generators -----------------------------------------------------------------

  defp text do
    frequency([
      {6, oneof(["a\n", "héllo wörld\n", "日本語", "x"])},
      {2, let(n <- integer(1, 20_000), do: String.duplicate("é", n))},
      {1, let(n <- integer(60_000, 90_000), do: String.duplicate("x", n))}
    ])
  end

  defp provider_output do
    frequency([
      {4, ""},
      {2, "ok\n"},
      {1, let(n <- integer(250_000, 300_000), do: String.duplicate("ü", n))}
    ])
  end

  # --- the real thing --------------------------------------------------------------

  def create(id) do
    {:ok, _} =
      Streams.commit(@thread, :thread, [
        {"turn-item", "item-#{id}",
         %{"s" => %{"id" => "item-#{id}", "status" => "running", "output" => ""}}},
        {"node", "node-#{id}", %{"s" => %{"id" => "node-#{id}"}}}
      ])

    :ok
  end

  def print(id, text) do
    state() |> TurnWriter.buffer(id, "output", text) |> TurnWriter.flush(:timer)
    :ok
  end

  def finish(id, output) do
    TurnWriter.finish_item(state(), id, "completed", &Map.put(&1, "output", output))
    :ok
  end

  def interrupt do
    _ = TurnWriter.close_open_items(state(), "interrupted")
    :ok
  end

  def run_ends, do: CommandTail.drop_thread(@thread)
  def refetch(id), do: CommandTail.get(@thread, "item-#{id}")

  defp state do
    %{
      thread_id: @thread,
      turn: %{streaming_mode: "paragraph"},
      items:
        Map.new(
          @ids,
          &{&1, %{id: "item-#{&1}", node: "node-#{&1}", message: nil, kind: :command}}
        ),
      buffer: %{},
      flush_timer: nil
    }
  end

  # The last `limit` bytes of `text` from a whole character, written without
  # `CommandTail.cut/2`.
  defp last(text, limit) do
    chars = String.codepoints(text) |> Enum.reverse()
    take(chars, limit, 0, [])
  end

  defp take([], _limit, _bytes, acc), do: IO.iodata_to_binary(acc)

  defp take([char | rest], limit, bytes, acc) do
    size = byte_size(char)

    if bytes + size > limit,
      do: IO.iodata_to_binary(acc),
      else: take(rest, limit, bytes + size, [char | acc])
  end

  # What the thread holds of an item, for the postcondition that follows each command.
  def thread_item(id) do
    StreamState.get(Streams.Server.state(Streams.ensure(@thread)), "turn-item")["item-#{id}"]
  end
end
