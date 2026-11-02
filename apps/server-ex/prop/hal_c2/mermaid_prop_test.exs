defmodule HalC2.MermaidPropTest do
  @moduledoc """
  `HalC2.Mermaid` against a model of its promise: every caller is answered once, with
  what was drawn for its source; a source is drawn once while it is kept or being drawn;
  no more than the limit draw at once, the rest start in the order they were asked for;
  and only what the renderer said is kept, the oldest forgotten past the cache's size.

  Drawings are held by the test until it finishes them with an outcome: a drawing, a
  failure the renderer reports, or a crash. Callers ask without waiting
  (`:gen_server.send_request/2`), so many wait on one drawing at once.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Mermaid

  @moduletag timeout: :infinity
  # The drawings that crash on purpose log their crash.
  @moduletag :capture_log

  @sources ~w(a b c d)
  @limit 2
  @cache_size 2
  @failed %{"status" => "failed", "kind" => nil, "reason" => "no", "line" => nil, "column" => nil}

  property "every caller gets what was drawn for its source, drawn once",
    numtests: HalC2.Prop.numtests(200),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()
        {history, state, result} = run_commands(__MODULE__, cmds)
        leftovers = end_case()

        (result == :ok and leftovers == [])
        |> when_fail(
          IO.puts(
            HalC2.Prop.report(cmds, history, state, result) <>
              "\nleftovers: #{inspect(leftovers)}"
          )
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start_case do
    test = self()

    draw = fn request ->
      send(test, {:drawing, request.source, self()})

      receive do
        {:outcome, :drawn} -> {:ok, drawn(request.source)}
        {:outcome, :failed} -> {:error, @failed}
        {:outcome, :crash} -> raise "the renderer crashed"
      end
    end

    {:ok, server} =
      Mermaid.start_link(name: nil, draw: draw, limit: @limit, cache_size: @cache_size)

    Process.put(:server, server)
    # request id => source, for callers not answered yet
    Process.put(:asked, %{})
    # source => the drawing's process
    Process.put(:drawers, %{})
  end

  # Whatever a case left behind that it should not have: an answer nobody expected, a
  # drawing nobody asked for.
  defp end_case do
    server = Process.get(:server)
    :sys.get_state(server)

    answered =
      for {request, source} <- Process.get(:asked),
          {:reply, result} <- [:gen_server.wait_response(request, 0)],
          do: {:answered, source, result}

    GenServer.stop(server)
    answered ++ stray_drawings()
  end

  defp stray_drawings do
    receive do
      {:drawing, source, _pid} -> [{:drawing, source} | stray_drawings()]
    after
      0 -> []
    end
  end

  defp drawn(source), do: %{"status" => "drawn", "kind" => "flowchart", "svg" => source}

  # --- model ------------------------------------------------------------------

  # kept: sources whose result is kept, oldest first, and what was kept for each.
  # running: sources being drawn. queued: sources waiting for a slot, oldest first.
  # waiting: source => callers waiting for it.
  def initial_state, do: %{kept: [], results: %{}, running: [], queued: [], waiting: %{}}

  def command(state) do
    frequency(
      [{5, {:call, __MODULE__, :ask, [oneof(@sources)]}}] ++
        if(state.running == [],
          do: [],
          else: [
            {4,
             {:call, __MODULE__, :finish,
              [oneof(state.running), oneof([:drawn, :drawn, :failed, :crash])]}}
          ]
        )
    )
  end

  def precondition(state, {:call, _, :finish, [source, _]}), do: source in state.running
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :ask, [source]}) do
    cond do
      source in state.kept ->
        state

      Map.has_key?(state.waiting, source) ->
        update_in(state.waiting[source], &(&1 + 1))

      length(state.running) < @limit ->
        %{state | running: state.running ++ [source], waiting: Map.put(state.waiting, source, 1)}

      true ->
        %{state | queued: state.queued ++ [source], waiting: Map.put(state.waiting, source, 1)}
    end
  end

  def next_state(state, _result, {:call, _, :finish, [source, outcome]}) do
    state = %{
      state
      | running: List.delete(state.running, source),
        waiting: Map.delete(state.waiting, source)
    }

    state = if outcome == :drawn, do: keep(state, source), else: state

    case state.queued do
      [next | queued] -> %{state | running: state.running ++ [next], queued: queued}
      [] -> state
    end
  end

  defp keep(state, source) do
    kept = state.kept ++ [source]
    results = Map.put(state.results, source, drawn(source))

    if length(kept) > @cache_size do
      [oldest | kept] = kept
      %{state | kept: kept, results: Map.delete(results, oldest)}
    else
      %{state | kept: kept, results: results}
    end
  end

  # An ask is answered at once only from what is kept; it starts a drawing when the
  # source is new and a slot is free.
  def postcondition(state, {:call, _, :ask, [source]}, {answers, started}) do
    new? = source not in state.kept and not Map.has_key?(state.waiting, source)

    answers == if(source in state.kept, do: [state.results[source]], else: []) and
      started == if(new? and length(state.running) < @limit, do: [source], else: [])
  end

  # Every caller waiting for the source gets its outcome, and the oldest queued source
  # starts in the slot it frees.
  def postcondition(state, {:call, _, :finish, [source, outcome]}, {answers, started}) do
    expected =
      case outcome do
        :drawn -> drawn(source)
        :failed -> @failed
        :crash -> :failed_by_crash
      end

    length(answers) == state.waiting[source] and
      Enum.all?(answers, fn answer ->
        if expected == :failed_by_crash,
          do: match?(%{"status" => "failed"}, answer),
          else: answer == expected
      end) and
      started == Enum.take(state.queued, 1)
  end

  # --- commands ---------------------------------------------------------------

  # A caller asks and does not wait. Returns the answers it got at once and the
  # drawings it started.
  def ask(source) do
    server = Process.get(:server)
    request = :gen_server.send_request(server, {:render, request(source)})
    # Its answer, if the server had one, is in this process's mailbox after this.
    :sys.get_state(server)

    answers =
      case :gen_server.wait_response(request, 0) do
        {:reply, result} ->
          [result]

        :timeout ->
          Process.put(:asked, Map.put(Process.get(:asked), request, source))
          []
      end

    {answers, started(server)}
  end

  # The drawing of `source` ends with `outcome`. Returns the answers of everyone waiting
  # for it and the drawings that started in its place.
  def finish(source, outcome) do
    server = Process.get(:server)
    {drawer, drawers} = Map.pop!(Process.get(:drawers), source)
    Process.put(:drawers, drawers)
    send(drawer, {:outcome, outcome})

    {mine, others} = Enum.split_with(Process.get(:asked), fn {_, s} -> s == source end)
    Process.put(:asked, Map.new(others))

    answers =
      for {request, _} <- mine do
        case :gen_server.wait_response(request, 10_000) do
          {:reply, result} -> result
          other -> raise "a caller of #{source} was not answered: #{inspect(other)}"
        end
      end

    {answers, started(server)}
  end

  # The drawings the server started since the last command. Every one it started has
  # been handed to a task once the server answers; the task says so on its own clock,
  # so the test waits for those the server holds and no others.
  defp started(server) do
    running = map_size(:sys.get_state(server).running)
    known = map_size(Process.get(:drawers))
    for _ <- 1..(running - known)//1, do: await_drawing()
  end

  defp await_drawing do
    receive do
      {:drawing, source, pid} ->
        Process.put(:drawers, Map.put(Process.get(:drawers), source, pid))
        source
    after
      10_000 -> raise "a drawing the server started never began"
    end
  end

  defp request(source), do: %{source: source, format: "svg", theme: "light"}
end
