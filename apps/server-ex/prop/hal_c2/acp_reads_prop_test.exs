defmodule HalC2.AcpReadsPropTest do
  @moduledoc """
  How `HalC2.Acp` reads an agent, against a model of which read stands. One ACP
  instance is read by reloads (`reload/1`, as Refresh does), boot reads (`load/0`),
  and the read a listing (`entry/1`) starts when nothing is known or being read, and
  forgotten by settings changes and `forget/1`. Each read's agent is held until the
  case releases it, to answer with models, refuse, say it is signed out, or send
  what makes the read raise. Whatever order they finish in, the instance shows what
  the most recently asked-for read that nothing overtook answered; a listing starts
  no read while one is under way, and does once the current read raised (#438); and
  a reload returns with its own answer in place (#459), and one that fails leaves the
  models shown before it.

  A live session's writers (`put_models/2`, `put_commands/2`,
  `put_unauthenticated/1`) land at any point between: they stand until a forget or a
  current read's own answer replaces them, and no superseded read touches them.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @instance "acpRegistry_prop"
  @agent_id "prop-agent"
  @max_reads 3

  property "the latest read and the session's writers stand, whatever order they land in",
    numtests: HalC2.Prop.numtests(120),
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
        File.write!(path, agent(port, token, name))
        File.chmod!(path, 0o755)
        {name, path}
      end)

    Process.put(:agents, agents)
    Process.put(:acceptor, {acceptor, listen})
    Process.put(:reads, %{})

    # A registry instance, as only those take `put_commands/2`; the catalog is in memory
    # and the agent comes from `:acp_commands`, so nothing reaches the network.
    :persistent_term.put(
      {HalC2.Acp.Catalog, :index},
      {System.system_time(:millisecond),
       [
         %{
           "id" => @agent_id,
           "name" => "Prop agent",
           "version" => "1.0.0",
           # A build for this machine, so the instance counts as ready to run.
           "distribution" => %{
             "binary" => %{HalC2.Acp.Catalog.platform() => %{"archive" => "", "cmd" => "./prop"}}
           }
         }
       ]}
    )

    HalC2.Acp.forget(@instance)
    configure(:a)
  end

  # Held agents are let go so their reads end before the next case.
  defp end_case do
    for n <- Map.keys(Process.get(:reads)), do: release(n, :answers)
    close_strays()
    HalC2.Acp.forget(@instance)
    Application.delete_env(:hal_c2, :acp_commands)
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
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

  defp agent(port, token, name) do
    """
    #!/usr/bin/env python3
    import json, os, socket, sys
    request = json.loads(sys.stdin.readline())
    case = socket.create_connection(("127.0.0.1", #{port}))
    case.sendall(("#{token} " + os.getcwd() + "\\n").encode())
    label, outcome = case.makefile().readline().split()
    def send(message):
        print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)
    def answer(request, result):
        send({"id": request["id"], "result": result})
    answer(request, {"protocolVersion": 1, "agentInfo": {"version": "1.0.0"}, "agentCapabilities": {}})
    model = {"id": "model", "currentValue": label, "options": [{"value": label, "name": label}]}
    if #{if name == :b, do: "True", else: "False"}:
        session = {"sessionId": "s", "models": {"currentModelId": label, "availableModels": [{"modelId": label, "name": label}]}}
    else:
        session = {"sessionId": "s", "configOptions": [model]}
    request = json.loads(sys.stdin.readline())
    if outcome == "answers":
        answer(request, session)
    elif outcome == "raises":
        answer(request, 42)
    elif outcome == "refuses":
        send({"id": request["id"], "error": {"code": -32603, "message": label + " refused"}})
    else:
        send({"id": request["id"], "error": {"code": -32000, "message": "sign in"}})
    sys.stdin.read()
    """
  end

  # --- model ------------------------------------------------------------------

  # reads: the reads under way, oldest first, `current` while no later read or forget
  # superseded them. shown: the models the instance shows. failure: its current read's
  # refusal. signed_out and commands: what a read or a session said of them. loading:
  # whether a read is under way that a listing must not duplicate.
  def initial_state do
    %{
      reads: [],
      next: 0,
      shown: nil,
      failure: nil,
      signed_out: false,
      commands: [],
      loading: false,
      agent: :a
    }
  end

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
        else: [
          {5,
           {:call, __MODULE__, :release,
            [
              oneof(Enum.map(state.reads, & &1.n)),
              frequency([{3, :answers}, {3, :raises}, {1, :refuses}, {1, :signed_out}])
            ]}}
        ]

    other = if state.agent == :a, do: :b, else: :a

    frequency(
      starts ++
        releases ++
        [
          {1, {:call, __MODULE__, :configure, [other]}},
          {1, {:call, __MODULE__, :forget, []}},
          {1, {:call, __MODULE__, :put_models, [oneof(["s0", "s1"])]}},
          {1, {:call, __MODULE__, :put_commands, [oneof(["c0", "c1"])]}},
          {1, {:call, __MODULE__, :put_unauthenticated, []}}
        ]
    )
  end

  defp starts_read?(state),
    do: state.shown == nil and state.failure == nil and not state.loading

  def precondition(state, {:call, _, cmd, [n]}) when cmd in [:reload, :boot],
    do: n == state.next and length(state.reads) < @max_reads

  def precondition(state, {:call, _, :list, [n, starts]}),
    do: n == state.next and starts == starts_read?(state)

  def precondition(state, {:call, _, :release, [n, _outcome]}),
    do: Enum.any?(state.reads, &(&1.n == n))

  def precondition(state, {:call, _, :configure, [agent]}), do: agent != state.agent
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :reload, [n]}),
    do: start(forgotten(state), n, state.shown)

  def next_state(state, _result, {:call, _, :boot, [n]}), do: start(state, n)

  def next_state(state, _result, {:call, _, :list, [n, true]}), do: start(state, n)
  def next_state(state, _result, {:call, _, :list, [_n, false]}), do: state

  def next_state(state, _result, {:call, _, :release, [n, outcome]}) do
    {[read], rest} = Enum.split_with(state.reads, &(&1.n == n))
    state = %{state | reads: rest}
    if read.current, do: state |> answered(n, outcome) |> kept(read.kept), else: state
  end

  def next_state(state, _result, {:call, _, :configure, [agent]}),
    do: %{forgotten(state) | agent: agent}

  def next_state(state, _result, {:call, _, :forget, []}), do: forgotten(state)

  def next_state(state, _result, {:call, _, :put_models, [label]}), do: %{state | shown: label}

  def next_state(state, _result, {:call, _, :put_commands, [name]}),
    do: %{state | commands: [name]}

  def next_state(state, _result, {:call, _, :put_unauthenticated, []}),
    do: %{state | signed_out: true}

  # A reload keeps the models shown before it (`kept`), for a check that fails.
  defp start(state, n, kept \\ nil) do
    state = supersede(state)

    %{
      state
      | reads: state.reads ++ [%{n: n, current: true, kept: kept}],
        next: n + 1,
        loading: true
    }
  end

  defp supersede(state), do: %{state | reads: Enum.map(state.reads, &%{&1 | current: false})}

  defp forgotten(state) do
    %{
      supersede(state)
      | shown: nil,
        failure: nil,
        signed_out: false,
        commands: [],
        loading: false
    }
  end

  # What the current read's end does to the instance.
  defp answered(state, n, :answers),
    do: %{state | shown: label(n), failure: nil, signed_out: false}

  defp answered(state, n, :refuses), do: %{state | failure: label(n) <> " refused"}
  defp answered(state, _n, :signed_out), do: %{state | failure: :signed_out, signed_out: true}
  defp answered(state, _n, :raises), do: %{state | loading: false}

  # A current reload that read no models (it failed, and no session reported any
  # meanwhile) leaves the models from before it shown.
  defp kept(%{shown: nil} = state, kept), do: %{state | shown: kept}
  defp kept(state, _kept), do: state

  def postcondition(state, {:call, _, cmd, _} = call, result)
      when cmd in [:release, :forget, :put_models, :put_commands, :put_unauthenticated],
      do: result == view(next_state(state, nil, call))

  def postcondition(state, {:call, _, :list, _}, result), do: result == view(state)
  def postcondition(_state, _call, result), do: result == :ok

  # What the instance is to say it holds.
  defp view(state) do
    %{
      models: List.wrap(state.shown),
      failure: state.failure,
      signed_out: state.signed_out,
      commands: state.commands
    }
  end

  defp label(n), do: "r#{n}"

  # --- commands ---------------------------------------------------------------

  def reload(n), do: started(n, Task.async(fn -> HalC2.Acp.reload(@instance) end))
  def boot(n), do: started(n, Task.async(fn -> HalC2.Acp.load() end))

  # A client lists the providers; the read it starts, if any, is read `n`.
  def list(n, starts) do
    drain_strays()
    before = generation()
    entry = HalC2.Acp.entry(@instance)

    # A read's generation is taken when it is asked for, before its task runs, so a
    # duplicate is seen here whether or not its agent's probe has arrived yet (it
    # may never, if this is the case's last command).
    if not starts and generation() not in [before, nil],
      do: raise("a listing started a read while one was under way or models were known")

    if starts, do: :ok = started(n, nil)

    %{
      models: slugs(entry["models"]),
      failure: failure(if(entry["status"] == "error", do: entry["message"])),
      signed_out: entry["auth"]["status"] == "unauthenticated",
      commands: names(entry["slashCommands"])
    }
  end

  defp generation, do: :persistent_term.get({HalC2.Acp, @instance, :generation}, nil)

  # Lets read `n`'s agent end as `outcome` and returns, once the read is done, what
  # the instance holds.
  def release(n, outcome) do
    {{socket, dir, task}, reads} = Map.pop(Process.get(:reads), n)
    Process.put(:reads, reads)
    :ok = :gen_tcp.send(socket, "#{label(n)} #{outcome}\n")

    if task, do: :ok = Task.await(task, 30_000), else: read_done(dir)
    :gen_tcp.close(socket)
    held()
  end

  def forget do
    HalC2.Acp.forget(@instance)
    held()
  end

  def put_models(label) do
    :ok =
      HalC2.Acp.put_models(@instance, [
        %{"id" => "model", "currentValue" => label, "options" => [%{"value" => label}]}
      ])

    held()
  end

  def put_commands(name) do
    :ok = HalC2.Acp.put_commands(@instance, [%{"name" => name}])
    held()
  end

  def put_unauthenticated do
    :ok = HalC2.Acp.put_unauthenticated(@instance)
    held()
  end

  defp held do
    %{
      models: slugs(term(:models) || []),
      failure: failure(term(:error)),
      signed_out: term(:unauthenticated) == true,
      commands: names(term(:commands) || [])
    }
  end

  defp term(key), do: :persistent_term.get({HalC2.Acp, @instance, key}, nil)

  # A refusal says the agent's message; a sign-out says the MC's own.
  defp failure(nil), do: nil
  defp failure("r" <> _ = message), do: message
  defp failure(_message), do: :signed_out

  def configure(agent) do
    {_, version} = HalC2.Settings.get()
    path = Map.fetch!(Process.get(:agents), agent)
    Application.put_env(:hal_c2, :acp_commands, %{@instance => [path]})

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            @instance => %{
              "driver" => "acpRegistry",
              "enabled" => true,
              "config" => %{"agentId" => @agent_id, "binaryPath" => path}
            }
          }
        },
        version
      )

    :ok
  end

  defp slugs(models), do: Enum.map(models, & &1["slug"])
  defp names(commands), do: Enum.map(commands, & &1["name"])

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
