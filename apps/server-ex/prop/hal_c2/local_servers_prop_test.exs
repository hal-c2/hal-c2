defmodule HalC2.LocalServersPropTest do
  @moduledoc """
  A state machine over `HalC2.LocalServers`' watchers: clients subscribing under refs
  with preview addresses of their own, letting go of one ref, going down, and scans
  (the machine's listeners and every probe stubbed: each address answers with a page).

  After each command:

  - the addresses kept for a client are those of the refs it still holds, and none for
    a client with no ref left, whether it let go of its last or went down;
  - what a client was last told holds addresses of its own only, never another
    client's, and nothing at all once it has no ref left;
  - after a scan a client is told exactly the addresses of the refs it holds.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.LocalServers

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @clients [:c1, :c2, :c3]
  @refs [:a, :b]
  @urls for port <- 3001..3004, do: "http://localhost:#{port}/"

  property "a client's addresses follow the refs it holds",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        Application.put_env(:hal_c2, :local_servers_listeners, [])
        Application.put_env(:hal_c2, :local_servers_probe, fn _ -> true end)
        HalC2.Prop.start_services([LocalServers])
        for client <- @clients, do: spawn_client(client)
        {history, state, result} = run_commands(__MODULE__, cmds)
        for client <- @clients, do: Process.exit(pid(client), :kill)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :local_servers_listeners)
        Application.delete_env(:hal_c2, :local_servers_probe)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # subs: client => %{ref => urls}; scanned: whether no change since the last scan;
  # told: client => the addresses it may have been told since that scan (a ref let go
  # of keeps its addresses in the last list until the next scan).
  def initial_state, do: %{subs: %{}, scanned: true, told: %{}}

  def command(_s) do
    oneof([
      {:call, __MODULE__, :subscribe,
       [oneof(@clients), oneof(@refs), resize(3, list(oneof(@urls)))]},
      {:call, __MODULE__, :subscribe,
       [oneof(@clients), oneof(@refs), resize(3, list(oneof(@urls)))]},
      {:call, __MODULE__, :unsubscribe, [oneof(@clients), oneof(@refs)]},
      {:call, __MODULE__, :down, [oneof(@clients)]},
      {:call, __MODULE__, :scan, []}
    ])
  end

  def precondition(_s, _call), do: true

  def next_state(s, _res, {:call, _, :subscribe, [client, ref, urls]}) do
    %{
      s
      | subs: Map.update(s.subs, client, %{ref => urls}, &Map.put(&1, ref, urls)),
        told: Map.update(s.told, client, urls, &Enum.uniq(&1 ++ urls)),
        scanned: false
    }
  end

  def next_state(s, _res, {:call, _, :unsubscribe, [client, ref]}) do
    refs = Map.delete(s.subs[client] || %{}, ref)

    if refs == %{},
      do: gone(s, client),
      else: %{s | subs: Map.put(s.subs, client, refs), scanned: false}
  end

  def next_state(s, _res, {:call, _, :down, [client]}), do: gone(s, client)

  def next_state(s, _res, {:call, _, :scan, []}),
    do: %{
      s
      | scanned: true,
        told: Map.new(s.subs, fn {client, _} -> {client, own(s, client)} end)
    }

  defp gone(s, client),
    do: %{s | subs: Map.delete(s.subs, client), told: Map.delete(s.told, client), scanned: false}

  def postcondition(before, {:call, _, :subscribe, [client, _, _]} = call, {:ok, list}) do
    next = next_state(before, nil, call)
    reply = urls_of(list)
    reply -- next.told[client] == [] and state_ok?(next)
  end

  def postcondition(before, {:call, _, _, _} = call, _result),
    do: state_ok?(next_state(before, nil, call))

  defp state_ok?(s) do
    state = :sys.get_state(LocalServers)

    kept =
      Map.new(state.configured, fn {client, refs} -> {name(client), Map.new(refs)} end)

    kept == s.subs and
      Enum.all?(@clients, fn client ->
        told = state.sent[pid(client)]

        cond do
          not is_map_key(s.subs, client) ->
            told == nil

          told == nil ->
            false

          true ->
            sent = urls_of(%{"servers" => told})
            sent -- s.told[client] == [] and (not s.scanned or Enum.sort(sent) == own(s, client))
        end
      end)
  end

  # --- wrappers ---------------------------------------------------------------

  def subscribe(client, ref, urls), do: LocalServers.subscribe_urls(pid(client), urls, ref)

  def unsubscribe(client, ref) do
    LocalServers.unsubscribe(pid(client), ref)
    :sys.get_state(LocalServers)
    :ok
  end

  # What the monitor sends when the client dies; the client itself lives on.
  def down(client) do
    send(LocalServers, {:DOWN, make_ref(), :process, pid(client), :killed})
    :sys.get_state(LocalServers)
    :ok
  end

  def scan do
    send(LocalServers, :scan)
    :sys.get_state(LocalServers)
    :ok
  end

  # --- helpers ----------------------------------------------------------------

  defp own(s, client) do
    (s.subs[client] || %{}) |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()
  end

  defp urls_of(%{"servers" => servers}), do: Enum.map(servers, & &1["url"])

  defp name(pid), do: Enum.find(@clients, &(pid(&1) == pid))

  defp spawn_client(client) do
    pid = spawn(fn -> loop() end)
    Process.put({:client, client}, pid)
  end

  defp loop do
    receive do
      _ -> loop()
    end
  end

  defp pid(client), do: Process.get({:client, client})
end
