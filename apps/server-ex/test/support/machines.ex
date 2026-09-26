defmodule HalC2.Test.Machines do
  @moduledoc """
  Several machines in one scenario, by label. The scenario's node (`context.node`, this
  VM) is the first; each other one is a `:peer` running the whole node in its own
  directory under the scenario's, with `HAL_C2_LABEL` naming it.

  A member of the cluster is a distributed peer connected to this VM. A machine that
  is not in a cluster is a peer driven over stdio: it never joins this VM's cluster.
  `on/5` runs a function on a machine either way. `context.machines` maps each label
  to `:local` or `%{node, peer, home, mode, environment}`.
  """

  import ExUnit.Assertions

  alias HalC2.Test.Node

  @support Path.expand(".", __DIR__)

  @doc """
  Makes this VM the machine `local` in a cluster and starts each of `others` as a
  member. Returns the context with `:machines`.
  """
  def cluster(context, local, others) do
    Node.World.put_env("HAL_C2_LABEL", local)
    for {key, value} <- sessions(context.node.home), do: Node.World.put_env(key, value)
    Node.World.put_app_env(:agent_sessions_home, user_home(context.node.home))
    distribute()
    context = %{context | node: Node.restart(context.node)}

    Enum.reduce(others, Map.put(context, :machines, %{local => :local}), fn label, context ->
      put_in(context, [:machines, label], start(context, label, :cluster))
    end)
  end

  @doc "Starts `label` as a member (`:cluster`) or a machine on its own (`:alone`)."
  def start(context, label, mode, home \\ nil) do
    home = home || Node.tmp_dir(context.node, label)

    env =
      for {key, value} <- [{"HAL_C2_LABEL", label} | sessions(home)],
          do: {String.to_charlist(key), String.to_charlist(value)}

    args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    opts =
      case mode do
        :cluster ->
          %{
            name: :"hal_c2_#{label}#{System.unique_integer([:positive])}",
            host: ~c"127.0.0.1",
            longnames: true,
            args: args,
            env: env
          }

        :alone ->
          %{connection: :standard_io, args: args, env: env}
      end

    {:ok, peer, node} =
      case :peer.start(opts) do
        {:ok, peer} -> {:ok, peer, nil}
        {:ok, peer, node} -> {:ok, peer, node}
      end

    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    machine = %{node: node, peer: peer, home: home, mode: mode, label: label}

    app_env =
      [start_node: true, home: home, port: 0, agent_sessions_home: user_home(home)] ++
        fakes(home)

    for {key, value} <- app_env,
        do: :ok = call(machine, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = call(machine, Application, :ensure_all_started, [:hal_c2], 30_000)

    if mode == :cluster do
      assert_receive {:hal_c2_shell, {:environment, ^node, %{"environmentId" => environment}}},
                     10_000

      Map.put(machine, :environment, environment)
    else
      machine
    end
  end

  @doc "Takes `label` out of the cluster: it keeps its files and runs on its own."
  def leave(context, label) do
    machine = machine(context, label)
    stop(machine)
    put_in(context, [:machines, label], start(context, label, :alone, machine.home))
  end

  @doc "Stops a peer machine, as a machine that goes offline."
  def stop(%{peer: peer, node: node, mode: mode}) do
    :peer.stop(peer)
    if mode == :cluster, do: assert_receive({:hal_c2_shell, {:node, ^node, :down}}, 5_000)
    :ok
  end

  def machine(context, label) do
    case context[:machines][label] do
      nil -> flunk("no machine #{inspect(label)} in this scenario")
      machine -> machine
    end
  end

  @doc "Runs `mod.fun(args)` on the machine `label` (or a machine map)."
  def on(context, label, mod, fun, args, timeout \\ 60_000)

  def on(context, label, mod, fun, args, timeout) when is_binary(label),
    do: call(machine(context, label), mod, fun, args, timeout)

  defp call(machine, mod, fun, args, timeout \\ 60_000)
  defp call(:local, mod, fun, args, _timeout), do: apply(mod, fun, args)

  defp call(%{mode: :cluster, node: node}, mod, fun, args, timeout),
    do: :erpc.call(node, mod, fun, args, timeout)

  defp call(%{mode: :alone, peer: peer}, mod, fun, args, timeout),
    do: :peer.call(peer, mod, fun, args, timeout)

  @doc "The Erlang node of a machine."
  def node_of(context, label) do
    case machine(context, label) do
      :local -> node()
      %{node: node} -> node
    end
  end

  @doc "A machine's data directories' root: its home."
  def home(context, label) do
    case machine(context, label) do
      :local -> context.node.home
      %{home: home} -> home
    end
  end

  @doc """
  A machine's user home, where its agents keep their sessions: "~" in a feature.
  Each machine's Claude, Codex and Pi homes are the defaults under it.
  """
  def user_home(context, label) when is_binary(label), do: user_home(home(context, label))
  def user_home(home) when is_binary(home), do: Path.join(home, "user")

  # The fake agents keep sessions the way the real ones do, in the machine's own homes.
  defp sessions(home) do
    user = user_home(home)

    [
      {"FAKE_SESSIONS", "1"},
      {"CLAUDE_CONFIG_DIR", Path.join(user, ".claude")},
      {"CODEX_HOME", Path.join(user, ".codex")},
      {"PI_CODING_AGENT_DIR", Path.join(user, ".pi/agent")}
    ]
  end

  # --- run on a machine ----------------------------------------------------------------

  @doc "This node's own sidebar rows, as `{kind, row}`, once pending ones are written."
  def rows do
    for %{id: id} <- HalC2.Store.list_streams(HalC2.Store.path()),
        do: HalC2.Streams.flush_shell(id)

    for {_id, kind, row} <- HalC2.Store.list_shell(HalC2.Store.path()), do: {kind, row}
  end

  @doc "A stream's entities of `kind` on this node."
  def entities(stream_id, kind) do
    HalC2.Streams.Server.state(HalC2.Streams.ensure(stream_id))
    |> HalC2.StreamState.list(kind)
  end

  @doc "The ids of this node's streams."
  def streams, do: for(%{id: id} <- HalC2.Store.list_streams(HalC2.Store.path()), do: id)

  @doc "Threads this node is receiving in a move (`HalC2.ThreadMove.accept/2`)."
  def incoming_moves do
    dir = Path.join(HalC2.Paths.data_dir(), "incoming-moves")
    if File.dir?(dir), do: File.ls!(dir), else: []
  end

  @doc """
  A `:thread_move_hook` that holds a move at `stage`: it tells `test` with
  `{:move_held, pid, stage, thread_id}` and waits for `:release` sent to `pid`.
  """
  def hold_move(test, stage, stage, id) do
    send(test, {:move_held, self(), stage, id})

    receive do
      :release -> :ok
    end
  end

  def hold_move(_test, _held, _stage, _id), do: :ok

  @doc "The diff of a thread's runs `from` to `to` on this node (`HalC2.Checkpoint.turn_diff/5`)."
  def turn_diff(id, from, to) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
    HalC2.Checkpoint.turn_diff(state, id, from, to, false)
  end

  @doc "Creates a project on this node and waits until its row is stored."
  def create_project(id, title, root) do
    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => id,
        "title" => title,
        "workspaceRoot" => root
      })

    HalC2.Streams.flush_shell(id)
  end

  @doc """
  Sends `text` to the thread `id` on this node and waits for its run to finish;
  returns the run.
  """
  def send_message(id, text, selection \\ %{"instanceId" => "codex", "model" => "gpt-5.4"}) do
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    ordinal = length(entities(id, "run")) + 1

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => id,
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => text,
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"},
        "createdBy" => "user",
        "creationSource" => "web"
      })

    await_run(id, ordinal)
  end

  defp await_run(id, ordinal) do
    run =
      Enum.find(
        entities(id, "run"),
        &(&1["ordinal"] == ordinal and &1["status"] in ~w(completed failed interrupted))
      )

    if run do
      run
    else
      receive do
        {:hal_c2_stream, ^id, _} -> await_run(id, ordinal)
      after
        15_000 -> raise "run #{ordinal} of #{id} never finished"
      end
    end
  end

  @doc "Deletes a project on this node."
  def delete_project(id) do
    {:ok, _} = HalC2.Projects.mutate(%{"type" => "project.delete", "projectId" => id})
    HalC2.Streams.flush_shell(id)
  end

  # Each machine's providers are the test fakes, logging under its own home.
  defp fakes(home) do
    fake = &Path.join(@support, &1)

    [
      codex_command: [
        "env",
        "FAKE_CODEX_INPUT_LOG=" <> Path.join(home, "codex-inputs.jsonl"),
        "FAKE_CODEX_REQUEST_LOG=" <> Path.join(home, "codex-methods.log"),
        "FAKE_CODEX_SESSION_LOG=" <> Path.join(home, "codex-sessions.jsonl"),
        "FAKE_CODEX_LOG=" <> Path.join(home, "codex-requests.log"),
        "python3",
        "-u",
        fake.("fake_codex.py")
      ],
      claude_command: [
        "env",
        "FAKE_CLAUDE_ARGV_LOG=" <> Path.join(home, "claude-argv.jsonl"),
        "FAKE_CLAUDE_INPUT_LOG=" <> Path.join(home, "claude-inputs.jsonl"),
        "python3",
        "-u",
        fake.("fake_claude.py")
      ]
    ]
  end

  # Makes this VM a named node, as a clustered node boots.
  defp distribute do
    unless :erlang.is_alive() do
      {_, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start(:"hal_c2_machines#{System.unique_integer([:positive])}@127.0.0.1", %{
          name_domain: :longnames
        })

      ExUnit.Callbacks.on_exit(fn -> :net_kernel.stop() end)
    end

    :ok
  end
end
