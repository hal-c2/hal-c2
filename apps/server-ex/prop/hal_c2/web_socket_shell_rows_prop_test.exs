defmodule HalC2.WebSocketShellRowsPropTest do
  @moduledoc """
  One client socket following the sidebar while threads are renamed, against what
  the socket promises a client slow to take its rows: each thread's row reaches it
  once per frame, as the thread is now, and the rows of a frame are in the order the
  threads last changed.

  Commands rename one of a few threads (waiting until the sidebar has it), hold the
  socket busy (`:sys.suspend/1`) and let it take what waited. After every step the
  client must come to hold every thread as the sidebar does; every frame it was sent
  must name a thread at most once, in the order of its last rename before the frame.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Streams
  alias HalC2.Test.WsClient

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @threads ["th-sr-a", "th-sr-b", "th-sr-c"]

  setup do
    saved = for key <- [:port, :home], do: {key, Application.fetch_env(:hal_c2, key)}

    on_exit(fn ->
      :persistent_term.erase({HalC2.Web, :token})

      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  property "a slow client is sent each thread's latest row once, in the order they changed",
    numtests: HalC2.Prop.numtests(40),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            stop()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    Application.put_env(:hal_c2, :port, 0)
    home = HalC2.Prop.scratch_home("web-socket-shell-rows")
    :persistent_term.erase({HalC2.Web, :token})

    sup =
      HalC2.Prop.start_services([
        {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
        HalC2.Streams,
        HalC2.Shell,
        Supervisor.child_spec(HalC2.Web, id: HalC2.Web)
      ])

    [port] =
      for {HalC2.Web, pid, _, _} <- Supervisor.which_children(sup) do
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        port
      end

    _ = HalC2.Shell.subscribe(self())
    for id <- @threads, do: title(id, "#{id} 0")

    {:ok, client} = WsClient.connect(port, "/ws?token=#{HalC2.Web.token()}")
    {%{"t" => "hello"}, client} = WsClient.recv(client, 5_000)

    client =
      WsClient.send_json(client, %{"t" => "sub", "id" => 1, "shape" => %{"type" => "shell"}})

    {%{"t" => "shell", "rows" => rows}, client} = WsClient.recv(client, 5_000)

    [socket] = for {pid, :client} <- :ets.tab2list(HalC2.Shell.Subscribers), do: pid
    put(:client, client)
    put(:socket, socket)
    put(:held, Map.new(for [_mc, id, "thread", row] <- rows, do: {id, row["title"]}))
    put(:titles, Map.new(@threads, &{&1, "#{&1} 0"}))
    put(:changed, [])
    put(:slow, false)
  end

  defp stop do
    if get(:slow), do: :sys.resume(get(:socket))

    for key <- [:client, :socket, :held, :titles, :changed, :slow],
        do: Process.delete({__MODULE__, key})

    HalC2.Prop.stop_services()
  end

  # --- model ------------------------------------------------------------------------

  def initial_state, do: %{slow: false}

  def command(%{slow: slow}) do
    frequency([
      {5, {:call, __MODULE__, :rename, [oneof(@threads)]}},
      {2, if(slow, do: {:call, __MODULE__, :take, []}, else: {:call, __MODULE__, :slow, []})}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :slow, []}), do: %{state | slow: true}
  def next_state(state, _result, {:call, _, :take, []}), do: %{state | slow: false}
  def next_state(state, _result, _call), do: state

  def postcondition(_state, _call, result), do: result == :ok

  # --- commands ---------------------------------------------------------------------

  def rename(id) do
    to = "#{id} #{System.unique_integer([:positive])}"
    title(id, to)
    put(:titles, Map.put(get(:titles), id, to))
    put(:changed, [id | get(:changed)])
    settle()
  end

  def slow do
    :ok = :sys.suspend(get(:socket))
    put(:slow, true)
    :ok
  end

  def take do
    :ok = :sys.resume(get(:socket))
    put(:slow, false)
    settle()
  end

  # --- checking ---------------------------------------------------------------------

  # A slow socket sends nothing yet. A quick one sends rows until the client holds
  # what the sidebar does: each frame's rows in the order of their last change.
  defp settle do
    if get(:slow), do: :ok, else: take_until_held(System.monotonic_time(:millisecond) + 5_000)
  end

  defp take_until_held(deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      get(:held) == get(:titles) ->
        put(:changed, [])
        :ok

      left <= 0 ->
        {:behind, get(:held), get(:titles)}

      true ->
        {frame, client} = WsClient.recv(get(:client), left)
        put(:client, client)

        with :ok <- check(frame), do: take_until_held(deadline)
    end
  end

  defp check(%{"t" => "shell.rows", "id" => 1, "rows" => rows} = frame) do
    ids = for [id, "thread", _row] <- rows, do: id
    # The threads in the order they last changed, of those this frame names.
    order = get(:changed) |> Enum.uniq() |> Enum.reverse() |> Enum.filter(&(&1 in ids))

    if ids == order do
      put(
        :held,
        Enum.reduce(rows, get(:held), fn [id, "thread", row], held ->
          Map.put(held, id, row["title"])
        end)
      )

      :ok
    else
      {:out_of_order, order, frame}
    end
  end

  defp check(frame), do: {:unexpected, frame}

  # Sets a thread's title and waits until the sidebar has it.
  defp title(id, to) do
    {:ok, _} =
      Streams.commit(id, :thread, [{"thread", id, %{"s" => %{"id" => id, "title" => to}}}])

    await_row(id, to)
  end

  defp await_row(id, to) do
    receive do
      {:hal_c2_shell, {:rows, _, rows}} ->
        case List.keyfind(rows, id, 0) do
          {^id, {_kind, %{"title" => ^to}}} -> :ok
          _ -> await_row(id, to)
        end
    after
      5_000 -> raise "#{id}'s row never became #{to}"
    end
  end

  defp get(key), do: Process.get({__MODULE__, key})
  defp put(key, value), do: Process.put({__MODULE__, key}, value)
end
