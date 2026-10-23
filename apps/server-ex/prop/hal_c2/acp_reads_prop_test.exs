defmodule HalC2.AcpReadsPropTest do
  @moduledoc """
  How `HalC2.Acp` reads an agent's models, against a model of which read stands. One
  ACP instance is read by reloads (`reload/1`, as Refresh does), boot reads
  (`load/0`), and the read a listing (`entry/1`) starts when nothing is known or
  being read, and forgotten by settings changes. Each read's agent is held until the
  case releases it with the models it answers. Whatever order they finish in, the
  instance shows what the most recently asked-for read that no settings change
  overtook answered; a listing starts no read while one is under way; and a reload
  returns with its own answer in place (#459).
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @instance "grok"
  @max_reads 3

  property "the latest read stands, and a reload returns with what it read",
    numtests: HalC2.Prop.numtests(60),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()
        {history, state, result} = run_commands(__MODULE__, cmds)
        end_case()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # Every probe of the instance's agent connects to the case, says the case's token and
  # where it runs, and waits for the label it then answers as its only model.
  defp start_case do
    dir = HalC2.Prop.scratch_home("acp-reads")
    HalC2.Prop.start_services([HalC2.Settings])
    :ok = HalC2.Settings.watch(self())

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    case_pid = self()
    token = Integer.to_string(System.unique_integer([:positive]))
    acceptor = spawn_link(fn -> accept(listen, case_pid, token) end)

    agents =
      Map.new([:a, :b], fn name ->
        path = Path.join(dir, "agent-#{name}")
        File.write!(path, agent(port, token))
        File.chmod!(path, 0o755)
        {name, path}
      end)

    Process.put(:agents, agents)
    Process.put(:acceptor, {acceptor, listen})
    Process.put(:reads, %{})
    HalC2.Acp.forget(@instance)
    configure(:a)
  end

  # Held agents are let go so their reads end before the next case.
  defp end_case do
    for n <- Map.keys(Process.get(:reads)), do: release(n)
    close_strays()
    HalC2.Acp.forget(@instance)
    {acceptor, listen} = Process.get(:acceptor)
    Process.unlink(acceptor)
    Process.exit(acceptor, :kill)
    :gen_tcp.close(listen)
    HalC2.Prop.stop_services()
  end

  # Ends when the case closes the listening socket. Each connection is checked apart,
  # so one that says nothing cannot hold up the agents behind it.
  defp accept(listen, case_pid, token) do
    with {:ok, socket} <- :gen_tcp.accept(listen) do
      checker = spawn(fn -> receive do: (:owned -> probe(socket, case_pid, token)) end)

      if :gen_tcp.controlling_process(socket, checker) == :ok,
        do: send(checker, :owned),
        else: :gen_tcp.close(socket)

      accept(listen, case_pid, token)
    end
  end

  # Anything on the machine may connect to the case's port, such as a client still
  # retrying a server that had the port before: only a connection that says this
  # case's token is one of its agents, so no other is given a read's label.
  defp probe(socket, case_pid, token) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 10_000),
         [^token, cwd] <- String.split(String.trim(line), " ", parts: 2),
         :ok <- :gen_tcp.controlling_process(socket, case_pid) do
      send(case_pid, {:probe, socket, cwd})
    else
      _ -> :gen_tcp.close(socket)
    end
  end

  defp agent(port, token) do
    """
    #!/usr/bin/env python3
    import json, os, socket, sys
    request = json.loads(sys.stdin.readline())
    case = socket.create_connection(("127.0.0.1", #{port}))
    case.sendall(("#{token} " + os.getcwd() + "\\n").encode())
    label = case.makefile().readline().strip()
    def answer(request, result):
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    answer(request, {"protocolVersion": 1, "agentInfo": {"version": "1.0.0"}, "agentCapabilities": {}})
    model = {"id": "model", "currentValue": label, "options": [{"value": label, "name": label}]}
    answer(json.loads(sys.stdin.readline()), {"sessionId": "s", "configOptions": [model]})
    sys.stdin.read()
    """
  end

  # --- model ------------------------------------------------------------------

  # reads: the reads under way, oldest first, `current` while no later read or settings
  # change superseded them. shown: the read whose answer the instance shows. loading:
  # whether a read is under way that a listing must not duplicate.
  def initial_state, do: %{reads: [], next: 0, shown: nil, loading: false, agent: :a}

  def command(state) do
    starts =
      if length(state.reads) < @max_reads,
        do: [
          {3, {:call, __MODULE__, :reload, [state.next]}},
          {1, {:call, __MODULE__, :boot, [state.next]}},
          {3, {:call, __MODULE__, :list, [state.next, starts_read?(state)]}}
        ],
        else: [{3, {:call, __MODULE__, :list, [state.next, false]}}]

    releases =
      if state.reads == [],
        do: [],
        else: [{5, {:call, __MODULE__, :release, [oneof(Enum.map(state.reads, & &1.n))]}}]

    other = if state.agent == :a, do: :b, else: :a
    frequency(starts ++ releases ++ [{1, {:call, __MODULE__, :configure, [other]}}])
  end

  defp starts_read?(state), do: state.shown == nil and not state.loading

  def precondition(state, {:call, _, cmd, [n]}) when cmd in [:reload, :boot],
    do: n == state.next and length(state.reads) < @max_reads

  def precondition(state, {:call, _, :list, [n, starts]}),
    do: n == state.next and starts == starts_read?(state)

  def precondition(state, {:call, _, :release, [n]}), do: Enum.any?(state.reads, &(&1.n == n))
  def precondition(state, {:call, _, :configure, [agent]}), do: agent != state.agent

  def next_state(state, _result, {:call, _, :reload, [n]}),
    do: %{start(state, n) | shown: nil}

  def next_state(state, _result, {:call, _, :boot, [n]}), do: start(state, n)

  def next_state(state, _result, {:call, _, :list, [n, true]}), do: start(state, n)
  def next_state(state, _result, {:call, _, :list, [_n, false]}), do: state

  def next_state(state, _result, {:call, _, :release, [n]}) do
    {[read], rest} = Enum.split_with(state.reads, &(&1.n == n))
    state = %{state | reads: rest}
    if read.current, do: %{state | shown: n}, else: state
  end

  def next_state(state, _result, {:call, _, :configure, [agent]}),
    do: %{supersede(state) | shown: nil, loading: false, agent: agent}

  defp start(state, n) do
    state = supersede(state)
    %{state | reads: state.reads ++ [%{n: n, current: true}], next: n + 1, loading: true}
  end

  defp supersede(state), do: %{state | reads: Enum.map(state.reads, &%{&1 | current: false})}

  def postcondition(state, {:call, _, :list, _}, result), do: result == shown(state.shown)

  def postcondition(state, {:call, _, :release, [n]}, result) do
    read = Enum.find(state.reads, &(&1.n == n))
    result == if(read.current, do: shown(n), else: shown(state.shown))
  end

  def postcondition(_state, _call, result), do: result == :ok

  defp shown(nil), do: []
  defp shown(n), do: [label(n)]

  defp label(n), do: "r#{n}"

  # --- commands ---------------------------------------------------------------

  def reload(n), do: started(n, Task.async(fn -> HalC2.Acp.reload(@instance) end))
  def boot(n), do: started(n, Task.async(fn -> HalC2.Acp.load() end))

  # A client lists the providers; the read it starts, if any, is read `n`.
  def list(n, starts) do
    drain_strays()
    before = generation()
    %{"models" => models} = HalC2.Acp.entry(@instance)

    # A read's generation is taken when it is asked for, before its task runs, so a
    # duplicate is seen here whether or not its agent's probe has arrived yet (it
    # may never, if this is the case's last command).
    if not starts and generation() not in [before, nil],
      do: raise("a listing started a read while one was under way or models were known")

    if starts, do: :ok = started(n, nil)
    Enum.map(models, & &1["slug"])
  end

  defp generation, do: :persistent_term.get({HalC2.Acp, @instance, :generation}, nil)

  # Lets read `n`'s agent answer and returns, once the read is done, what the
  # instance shows.
  def release(n) do
    {{socket, dir, task}, reads} = Map.pop(Process.get(:reads), n)
    Process.put(:reads, reads)
    :ok = :gen_tcp.send(socket, label(n) <> "\n")

    if task, do: :ok = Task.await(task, 30_000), else: read_done(dir)
    :gen_tcp.close(socket)
    :persistent_term.get({HalC2.Acp, @instance, :models}, nil) |> Kernel.||([]) |> slugs()
  end

  def configure(agent) do
    {_, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            @instance => %{
              "driver" => "grok",
              "enabled" => true,
              "config" => %{"binaryPath" => Map.fetch!(Process.get(:agents), agent)}
            }
          }
        },
        version
      )

    :ok
  end

  defp slugs(models), do: Enum.map(models, & &1["slug"])

  # Read `n`'s agent has started and holds the read.
  defp started(n, task) do
    drain_strays()

    receive do
      {:probe, socket, dir} ->
        Process.put(:reads, Map.put(Process.get(:reads), n, {socket, dir, task}))
        :ok
    after
      10_000 -> raise "read #{n} started no agent"
    end
  end

  # An agent no read the model knows of started: a duplicate read.
  defp drain_strays do
    receive do
      {:probe, socket, _dir} ->
        :gen_tcp.close(socket)
        raise "an agent started that no read asked for"
    after
      0 -> :ok
    end
  end

  defp close_strays do
    receive do
      {:probe, socket, _dir} ->
        :gen_tcp.close(socket)
        close_strays()
    after
      0 -> :ok
    end
  end

  # A read's last broadcast follows the removal of its probe directory, which follows
  # its publication: the first broadcast seen once the directory is gone means the
  # read is done.
  defp read_done(dir) do
    receive do
      {:hal_c2_providers_changed, _} -> if File.exists?(dir), do: read_done(dir), else: :ok
    after
      30_000 -> raise "read in #{dir} did not finish"
    end
  end
end
