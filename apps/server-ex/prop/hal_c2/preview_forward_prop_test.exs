defmodule HalC2.PreviewForwardPropTest do
  @moduledoc """
  `HalC2.PreviewForward` against a model of what a forward promises: the
  thread's tabs and the ports they name, the forwards listening, and the
  connections open through them. Commands open, navigate and close tabs, ask
  for forwards (at a dev server's port, a port nothing listens on, a port no
  tab names, the MC's own cluster port), connect through them, carry bytes,
  close a connection from either end, kill a forward's grant or listener, and
  restart `HalC2.Preview`, which holds the tabs.

  The promise: a port is forwarded exactly while one of the thread's tabs
  names it and it is not the MC's own; asked again it is the same forward on
  the same port; and a forward that ends, however it ends, closes every
  connection through it.

  As in `test/hal_c2/preview_forward_test.exs`, the forward goes to this MC
  itself, and the dev servers listen on 127.0.0.2, where the thread's MC is
  told to dial, so the forward's 127.0.0.1 and ::1 stay free.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.PreviewForward
  alias HalC2.PreviewForward.Listener
  alias HalC2.Test.DevServer

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @dev {127, 0, 0, 2}
  @registry HalC2.PreviewForward.Registry
  @threads ["th-a", "th-b"]
  # Ports by name (`port/1`): two dev servers, one nothing listens on, and
  # the MC's cluster port.

  property "a port is forwarded while a tab names it, and its connections end with it",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("preview-forward")
        Application.put_env(:hal_c2, :preview_forward_loopback, [@dev])
        servers = start_dev_servers()
        HalC2.Prop.start_services([HalC2.Preview, PreviewForward])
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        for server <- servers, do: DevServer.stop(server)
        Application.delete_env(:hal_c2, :preview_forward_loopback)
        flush()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # tabs: slot => {thread, port name}; forwards: {thread, port name} => the
  # reply to the first ask; conns: slot => {thread, port name}. Slots number
  # tabs and connections, so a command names one without its real id.
  def initial_state, do: %{next: 0, tabs: %{}, forwards: %{}, conns: %{}}

  def command(state) do
    frequency(
      [
        {3, {:call, __MODULE__, :open_tab, [state.next, oneof(@threads), port()]}},
        {1, {:call, __MODULE__, :forward, [oneof(@threads), port()]}},
        {1, {:call, __MODULE__, :restart_preview, []}}
      ] ++
        if(state.tabs == %{},
          do: [],
          else: [
            # Mostly at a port a tab names, so forwards exist to connect through.
            {4, named_forward(state)},
            {2, {:call, __MODULE__, :navigate_tab, [tab(state), port()]}},
            {2, {:call, __MODULE__, :close_tab, [tab(state)]}}
          ]
        ) ++
        if(state.forwards == %{},
          do: [],
          else: [
            {6, {:call, __MODULE__, :connect, [state.next, forward(state)]}},
            {1, {:call, __MODULE__, :kill_grant, [forward(state)]}},
            {1, {:call, __MODULE__, :kill_listener, [forward(state)]}}
          ]
        ) ++
        if(state.conns == %{},
          do: [],
          else: [
            {5, {:call, __MODULE__, :round_trip, [conn(state)]}},
            {2, {:call, __MODULE__, :close_conn, [conn(state), oneof([:browser, :dev_server])]}}
          ]
        )
    )
  end

  # Mostly the dev servers, which connections stay open through.
  defp port, do: frequency([{3, :web}, {2, :api}, {1, :dead}, {1, :reserved}])

  defp tab(state), do: oneof(Map.keys(state.tabs))

  defp named_forward(state) do
    let {thread, port} <- oneof(Map.values(state.tabs)) do
      {:call, __MODULE__, :forward, [thread, port]}
    end
  end

  defp forward(state), do: oneof(Map.keys(state.forwards))
  defp conn(state), do: oneof(Map.keys(state.conns))

  def precondition(state, {:call, _, :navigate_tab, [slot, _]}), do: is_map_key(state.tabs, slot)
  def precondition(state, {:call, _, :close_tab, [slot]}), do: is_map_key(state.tabs, slot)

  def precondition(state, {:call, _, :connect, [slot, key]}),
    do: slot == state.next and is_map_key(state.forwards, key)

  def precondition(state, {:call, _, :open_tab, [slot | _]}), do: slot == state.next

  def precondition(state, {:call, _, kill, [key]}) when kill in [:kill_grant, :kill_listener],
    do: is_map_key(state.forwards, key)

  def precondition(state, {:call, _, :round_trip, [slot]}), do: is_map_key(state.conns, slot)
  def precondition(state, {:call, _, :close_conn, [slot, _]}), do: is_map_key(state.conns, slot)
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :open_tab, [slot, thread, port]}),
    do: %{state | next: slot + 1, tabs: Map.put(state.tabs, slot, {thread, port})}

  def next_state(state, _result, {:call, _, :navigate_tab, [slot, port]}) do
    {thread, _} = state.tabs[slot]
    settle(%{state | tabs: Map.put(state.tabs, slot, {thread, port})})
  end

  def next_state(state, _result, {:call, _, :close_tab, [slot]}),
    do: settle(%{state | tabs: Map.delete(state.tabs, slot)})

  def next_state(state, _result, {:call, _, :restart_preview, []}),
    do: settle(%{state | tabs: %{}})

  def next_state(state, result, {:call, _, :forward, [thread, port]}) do
    if forwarded?(state, thread, port),
      do: %{state | forwards: Map.put_new(state.forwards, {thread, port}, result)},
      else: state
  end

  def next_state(state, _result, {:call, _, :connect, [slot, {_, port} = key]}) do
    # Nothing listens on the dead port: the connection closes as it opens.
    conns = if port == :dead, do: state.conns, else: Map.put(state.conns, slot, key)
    %{state | next: slot + 1, conns: conns}
  end

  def next_state(state, _result, {:call, _, kill, [key]})
      when kill in [:kill_grant, :kill_listener],
      do: drop_conns(%{state | forwards: Map.delete(state.forwards, key)})

  def next_state(state, _result, {:call, _, :close_conn, [slot, _]}),
    do: %{state | conns: Map.delete(state.conns, slot)}

  def next_state(state, _result, _call), do: state

  # What the tabs no longer name stops forwarding, with its connections.
  defp settle(state) do
    forwards =
      Map.filter(state.forwards, fn {{thread, port}, _} -> named?(state, thread, port) end)

    drop_conns(%{state | forwards: forwards})
  end

  defp drop_conns(state),
    do: %{
      state
      | conns: Map.filter(state.conns, fn {_, key} -> is_map_key(state.forwards, key) end)
    }

  defp named?(state, thread, port),
    do: Enum.any?(state.tabs, fn {_, tab} -> tab == {thread, port} end)

  defp forwarded?(state, thread, port), do: port != :reserved and named?(state, thread, port)

  def postcondition(state, {:call, _, :forward, [thread, port]}, result) do
    cond do
      port == :reserved -> result == {:error, :reserved}
      not named?(state, thread, port) -> result == {:error, :not_open}
      # Asked again: the same forward, on the same port.
      is_map_key(state.forwards, {thread, port}) -> result == state.forwards[{thread, port}]
      true -> match?({:ok, local} when is_integer(local), result)
    end and
      listening_as_modelled?(next_state(state, result, {:call, nil, :forward, [thread, port]}))
  end

  def postcondition(state, {:call, _, :connect, [_, {_, :dead}]}, result),
    do: result == {:error, :closed} and listening_as_modelled?(state)

  def postcondition(_state, {:call, _, :connect, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :round_trip, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :close_conn, _}, result), do: result == :ok

  # Every call that can end forwards: the ones the model ends have stopped
  # listening, and each connection through them is closed.
  def postcondition(state, call, result) do
    next = next_state(state, result, call)

    result == :ok and listening_as_modelled?(next) and
      Enum.all?(Map.keys(state.conns) -- Map.keys(next.conns), &(closed(&1) == :closed))
  end

  defp listening_as_modelled?(state) do
    listening = for {{_, thread, port}, _} <- PreviewForward.listening(), do: {thread, port}
    Enum.sort(listening) == state.forwards |> Map.keys() |> Enum.map(&real_key/1) |> Enum.sort()
  end

  defp real_key({thread, port}), do: {thread, port(port)}

  # --- commands ---------------------------------------------------------------

  def open_tab(slot, thread, port) do
    {:ok, %{"tabId" => tab}} = HalC2.Preview.open(%{"threadId" => thread, "url" => url(port)})
    Process.put({:tab, slot}, {thread, tab})
    :ok
  end

  def navigate_tab(slot, port) do
    {thread, tab} = Process.get({:tab, slot})
    input = %{"threadId" => thread, "tabId" => tab, "url" => url(port)}
    {:ok, _} = HalC2.Preview.navigate(input)
    settle_forwards()
  end

  def close_tab(slot) do
    {thread, tab} = Process.get({:tab, slot})
    {:ok, nil} = HalC2.Preview.close(%{"threadId" => thread, "tabId" => tab})
    settle_forwards()
  end

  def restart_preview do
    refs = for {_, listener} <- listeners(), do: Process.monitor(listener)
    :ok = HalC2.Prop.restart_service(HalC2.Preview)
    for ref <- refs, do: receive(do: ({:DOWN, ^ref, :process, _, _} -> :ok))
    :ok
  end

  def forward(thread, port), do: PreviewForward.forward(node(), thread, port(port))

  def connect(slot, {thread, port}) do
    {:ok, local} = Listener.port(listener({thread, port}))
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, local, [:binary, active: false])

    if port == :dead do
      reply = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.close(socket)
      reply
    else
      :ok = :gen_tcp.send(socket, "hello")

      with {:ok, "hello"} <- :gen_tcp.recv(socket, 5, 5_000),
           {:ok, dev} <- accepted() do
        Process.put({:conn, slot}, {socket, dev})
        :ok
      end
    end
  end

  def round_trip(slot) do
    {socket, _} = Process.get({:conn, slot})
    data = :crypto.strong_rand_bytes(100_000)
    :ok = :gen_tcp.send(socket, data)

    case :gen_tcp.recv(socket, byte_size(data), 5_000) do
      {:ok, ^data} -> :ok
      other -> other
    end
  end

  def close_conn(slot, :browser) do
    {socket, dev} = Process.get({:conn, slot})
    :gen_tcp.close(socket)

    receive do
      {:dev_server, :closed, ^dev} -> :ok
    after
      5_000 -> {:error, :dev_server_open}
    end
  end

  def close_conn(slot, :dev_server) do
    {socket, dev} = Process.get({:conn, slot})
    send(dev, :close)

    case :gen_tcp.recv(socket, 0, 5_000) do
      {:error, :closed} -> :ok
      other -> other
    end
  end

  def kill_grant(key) do
    listener = listener(real_key(key))
    ref = Process.monitor(listener)
    Process.exit(:sys.get_state(listener).grant, :kill)
    receive(do: ({:DOWN, ^ref, :process, _, _} -> :ok))
  end

  def kill_listener(key) do
    listener = listener(real_key(key))
    ref = Process.monitor(listener)
    Process.exit(listener, :kill)
    receive(do: ({:DOWN, ^ref, :process, _, _} -> :ok))
  end

  # --- helpers ----------------------------------------------------------------

  # Waits until every grant has seen the tab change (`HalC2.Preview` sent it
  # before it replied), and every listener whose grant it ended has stopped.
  defp settle_forwards do
    for {_, listener} <- listeners() do
      ref = Process.monitor(listener)

      alive? =
        try do
          _ = :sys.get_state(:sys.get_state(listener).grant)
          true
        catch
          :exit, _ -> false
        end

      if alive?,
        do: Process.demonitor(ref, [:flush]),
        else: receive(do: ({:DOWN, ^ref, :process, _, _} -> :ok))
    end

    :ok
  end

  # :closed once the connection in `slot` is closed at the browser's end.
  defp closed(slot) do
    {socket, _} = Process.get({:conn, slot})

    case :gen_tcp.recv(socket, 0, 5_000) do
      {:error, :closed} -> :closed
      other -> other
    end
  end

  defp accepted do
    receive do
      {:dev_server, :accepted, dev} -> {:ok, dev}
    after
      5_000 -> {:error, :not_accepted}
    end
  end

  defp listeners, do: Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

  defp listener({thread, port}) when is_atom(port), do: listener(real_key({thread, port}))

  defp listener({thread, port}) do
    [{pid, _}] = Registry.lookup(@registry, {node(), thread, port})
    pid
  end

  defp url(port), do: "http://localhost:#{port(port)}/"

  defp port(:reserved), do: HalC2.Cluster.dist_port()
  defp port(name), do: Process.get({:port, name})

  # The dev servers' ports, and one nothing listens on, for this case.
  defp start_dev_servers do
    servers =
      for name <- [:web, :api] do
        {port, server} = DevServer.echo(@dev, 0, self())
        Process.put({:port, name}, port)
        server
      end

    {:ok, socket} = :gen_tcp.listen(0, ip: @dev)
    {:ok, dead} = :inet.port(socket)
    :gen_tcp.close(socket)
    Process.put({:port, :dead}, dead)
    servers
  end

  defp flush do
    receive do
      {:dev_server, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
