defmodule HalC2.MermaidPropTest do
  @moduledoc """
  `HalC2.Mermaid` against a model of its promise: every caller is answered once, with
  what was drawn for its source; a source is drawn once while it is kept or being drawn;
  no more than the limit draw at once, the rest start in the order they were asked for;
  only what the renderer said is kept, the oldest forgotten past the cache's size; a
  source that waits too long for its turn is dropped, its callers told the MC is busy;
  and a source not started yet whose callers have all gone (or their sockets) is dropped,
  while one being drawn is finished for whoever is left.

  Drawings are held by the test until it finishes them with an outcome: a drawing, a
  failure the renderer reports, or a crash. The test also decides when a queued source
  has waited too long, sending the server the message its own timer would. Callers ask without waiting
  (`:gen_server.send_request/2`), so many wait on one drawing at once. Some callers are
  processes of their own, so the test can kill them while they wait, or close the socket
  they ask for, which several may share.
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
  @busy "The MC is busy drawing other diagrams; try again."
  @gone %{
    "status" => "failed",
    "kind" => nil,
    "reason" => "The client asking for this diagram has gone.",
    "line" => nil,
    "column" => nil
  }

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
      Mermaid.start_link(
        name: nil,
        draw: draw,
        limit: @limit,
        cache_size: @cache_size,
        # The test says when a source has waited too long, not the clock.
        wait: 3_600_000
      )

    Process.put(:server, server)
    # request id => source, for callers not answered yet
    Process.put(:asked, %{})
    # source => the drawing's process
    Process.put(:drawers, %{})
    # id => {process, source, its socket's name or nil}, for callers of their own not
    # answered yet
    Process.put(:apart, %{})
    # name => the socket's process
    Process.put(:sockets, %{})
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

    for {_id, {pid, _source, _socket}} <- Process.get(:apart), do: Process.exit(pid, :kill)
    GenServer.stop(server)
    for {_name, socket} <- Process.get(:sockets), do: Process.exit(socket, :kill)
    answered ++ strays()
  end

  defp strays do
    receive do
      {:drawing, source, _pid} -> [{:drawing, source} | strays()]
      {:apart_answer, id, result} -> [{:answered_apart, id, result} | strays()]
    after
      0 -> []
    end
  end

  defp drawn(source), do: %{"status" => "drawn", "kind" => "flowchart", "svg" => source}

  # --- model ------------------------------------------------------------------

  # kept: sources whose result is kept, oldest first, and what was kept for each.
  # running: sources being drawn. queued: sources waiting for a slot, oldest first.
  # waiting: source => callers waiting for it. apart: id => {source, socket's name or nil},
  # for callers of their own still waiting; next: the next one's id.
  def initial_state,
    do: %{kept: [], results: %{}, running: [], queued: [], waiting: %{}, apart: %{}, next: 0}

  defp apart_on(state, socket), do: for({id, {_, ^socket}} <- state.apart, do: id)

  defp sockets(state),
    do: state.apart |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

  def command(state) do
    frequency(
      [{5, {:call, __MODULE__, :ask, [oneof(@sources)]}}] ++
        case @sources -- state.kept do
          [] -> []
          new -> [{3, {:call, __MODULE__, :ask_apart, [oneof(new), state.next, socket()]}}]
        end ++
        case apart_on(state, nil) do
          [] -> []
          ids -> [{2, {:call, __MODULE__, :leave, [oneof(ids)]}}]
        end ++
        case sockets(state) do
          [] -> []
          sockets -> [{2, {:call, __MODULE__, :close, [oneof(sockets)]}}]
        end ++
        if(state.running == [],
          do: [],
          else: [
            {4,
             {:call, __MODULE__, :finish,
              [oneof(state.running), oneof([:drawn, :drawn, :failed, :crash])]}}
          ]
        ) ++
        if(state.queued == [],
          do: [],
          else: [{1, {:call, __MODULE__, :wait_out, [oneof(state.queued)]}}]
        )
    )
  end

  def precondition(state, {:call, _, :finish, [source, _]}), do: source in state.running
  def precondition(state, {:call, _, :wait_out, [source]}), do: source in state.queued

  def precondition(state, {:call, _, :ask_apart, [source, id, _socket]}),
    do: source not in state.kept and id == state.next

  def precondition(state, {:call, _, :leave, [id]}), do: id in apart_on(state, nil)
  def precondition(state, {:call, _, :close, [socket]}), do: socket in sockets(state)
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

  def next_state(state, result, {:call, _, :ask_apart, [source, id, socket]}) do
    state = next_state(state, result, {:call, __MODULE__, :ask, [source]})
    %{state | apart: Map.put(state.apart, id, {source, socket}), next: id + 1}
  end

  def next_state(state, _result, {:call, _, :leave, [id]}), do: depart(state, [id])

  def next_state(state, _result, {:call, _, :close, [socket]}),
    do: depart(state, apart_on(state, socket))

  def next_state(state, _result, {:call, _, :finish, [source, outcome]}) do
    state = %{
      state
      | running: List.delete(state.running, source),
        waiting: Map.delete(state.waiting, source),
        apart: forget_apart(state.apart, source)
    }

    state = if outcome == :drawn, do: keep(state, source), else: state

    case state.queued do
      [next | queued] -> %{state | running: state.running ++ [next], queued: queued}
      [] -> state
    end
  end

  def next_state(state, _result, {:call, _, :wait_out, [source]}) do
    %{
      state
      | queued: List.delete(state.queued, source),
        waiting: Map.delete(state.waiting, source),
        apart: forget_apart(state.apart, source)
    }
  end

  # Callers fewer. A queued source with none left is dropped; one being drawn stays.
  defp depart(state, ids) do
    Enum.reduce(ids, state, fn id, state ->
      {{source, _}, apart} = Map.pop(state.apart, id)
      state = %{state | apart: apart, waiting: Map.update!(state.waiting, source, &(&1 - 1))}

      if state.waiting[source] == 0 and source in state.queued,
        do: %{
          state
          | queued: List.delete(state.queued, source),
            waiting: Map.delete(state.waiting, source)
        },
        else: state
    end)
  end

  defp forget_apart(apart, source), do: Map.reject(apart, fn {_, {s, _}} -> s == source end)

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

  def postcondition(state, {:call, _, :ask_apart, [source, _, _]}, started),
    do: postcondition(state, {:call, __MODULE__, :ask, [source]}, {[], started})

  # A caller leaving starts nothing, and the server's queue is the model's afterwards, so
  # a source no one waits for is no longer queued.
  def postcondition(state, {:call, _, :leave, _} = call, {queued, started}),
    do: queued == next_state(state, nil, call).queued and started == []

  # So does a socket closing, and every caller waiting on it is let go.
  def postcondition(state, {:call, _, :close, [socket]} = call, {answers, queued, started}) do
    answers == List.duplicate(@gone, length(apart_on(state, socket))) and
      queued == next_state(state, nil, call).queued and started == []
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

  # Everyone waiting for a source dropped from the queue is told the MC is busy, and
  # nothing starts in its place.
  def postcondition(state, {:call, _, :wait_out, [source]}, {answers, started}) do
    length(answers) == state.waiting[source] and
      Enum.all?(answers, &match?(%{"status" => "failed", "reason" => @busy}, &1)) and
      started == []
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

  defp socket, do: oneof([nil, :s1, :s2])

  # A caller of its own, `id`, asks for `source` and waits, for the socket named `socket`
  # when there is one. Returns the drawings it started. Its answer, when it comes, is sent
  # to the test.
  def ask_apart(source, id, socket) do
    server = Process.get(:server)
    test = self()
    owner = socket && socket_pid(socket)

    pid =
      spawn(fn ->
        request = :gen_server.send_request(server, {:render, request(source), owner})
        send(test, {:apart_asked, id})
        {:reply, result} = :gen_server.receive_response(request, :infinity)
        send(test, {:apart_answer, id, result})
      end)

    receive do
      {:apart_asked, ^id} -> :ok
    after
      10_000 -> raise "a caller of its own never asked"
    end

    Process.put(:apart, Map.put(Process.get(:apart), id, {pid, source, socket}))
    started(server)
  end

  defp socket_pid(name) do
    case Process.get(:sockets) do
      %{^name => pid} ->
        pid

      sockets ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        Process.put(:sockets, Map.put(sockets, name, pid))
        pid
    end
  end

  # The caller `id` goes before it is answered. Returns the sources the server still has
  # queued, oldest first, and the drawings that started.
  def leave(id) do
    server = Process.get(:server)
    {{pid, _source, nil}, apart} = Map.pop!(Process.get(:apart), id)
    Process.put(:apart, apart)
    kill(pid)
    noticed(server, pid, 100)
    {queued(server), started(server)}
  end

  # The socket named `socket` closes. Returns what its waiting callers were answered, the
  # sources the server still has queued, oldest first, and the drawings that started.
  def close(socket) do
    server = Process.get(:server)
    {pid, sockets} = Map.pop!(Process.get(:sockets), socket)
    Process.put(:sockets, sockets)
    {mine, others} = Enum.split_with(Process.get(:apart), fn {_, {_, _, s}} -> s == socket end)
    Process.put(:apart, Map.new(others))
    kill(pid)

    answers =
      for {id, {caller, _, _}} <- mine do
        receive do
          {:apart_answer, ^id, result} ->
            noticed(server, caller, 100)
            result
        after
          10_000 -> raise "a caller whose socket closed was never let go"
        end
      end

    {answers, queued(server), started(server)}
  end

  defp kill(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    end
  end

  defp queued(server),
    do:
      for({_, %{source: source}, _} <- :queue.to_list(:sys.get_state(server).queued), do: source)

  # Returns once the server no longer holds `pid`, a caller or a drawing gone. The test's
  # word that it went and the server's are two signals in no promised order; each look at
  # the state is one more turn for the server to read its own.
  defp noticed(_server, pid, 0), do: raise("the server never noticed #{inspect(pid)} went")

  defp noticed(server, pid, tries) do
    state = :sys.get_state(server)
    waiters = state.waiting |> Map.values() |> List.flatten()

    if Enum.any?(waiters, &match?({{^pid, _}, _}, &1)) or
         Enum.any?(Map.values(state.running), &match?({_, ^pid, _}, &1)),
       do: noticed(server, pid, tries - 1),
       else: :ok
  end

  # The drawing of `source` ends with `outcome`. Returns the answers of everyone waiting
  # for it and the drawings that started in its place.
  def finish(source, outcome) do
    server = Process.get(:server)
    {drawer, drawers} = Map.pop!(Process.get(:drawers), source)
    Process.put(:drawers, drawers)
    # With no one waiting for it there is no answer to wait on, so wait for the drawing.
    monitor = Process.monitor(drawer)
    send(drawer, {:outcome, outcome})

    receive do
      {:DOWN, ^monitor, :process, _, _} -> noticed(server, drawer, 100)
    end

    {answers_for(source), started(server)}
  end

  defp answers_for(source) do
    {mine, others} = Enum.split_with(Process.get(:asked), fn {_, s} -> s == source end)
    Process.put(:asked, Map.new(others))

    asked =
      for {request, _} <- mine do
        case :gen_server.wait_response(request, 10_000) do
          {:reply, result} -> result
          other -> raise "a caller of #{source} was not answered: #{inspect(other)}"
        end
      end

    {apart, others} =
      Enum.split_with(Process.get(:apart), fn {_, {_, s, _}} -> s == source end)

    Process.put(:apart, Map.new(others))

    asked ++
      for {id, _} <- apart do
        receive do
          {:apart_answer, ^id, result} -> result
        after
          10_000 -> raise "a caller of its own, of #{source}, was not answered"
        end
      end
  end

  # `source` has waited too long for its turn. Returns the answers of everyone waiting
  # for it and the drawings that started.
  def wait_out(source) do
    server = Process.get(:server)

    [ref] =
      for {_key, %{source: ^source}, ref} <- :queue.to_list(:sys.get_state(server).queued),
          do: ref

    send(server, {:waited_too_long, ref})
    {answers_for(source), started(server)}
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
