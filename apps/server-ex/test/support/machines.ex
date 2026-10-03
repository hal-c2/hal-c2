defmodule HalC2.Test.Machines do
  @moduledoc """
  Several machines in one scenario, by label. The scenario's MC (`context.mc`, this
  VM) is the first; each other one is a `:peer` running the whole MC in its own
  directory under the scenario's, with `HAL_C2_LABEL` naming it.

  A member of the cluster is a distributed peer connected to this VM. A machine that
  is not in a cluster is a peer driven over stdio: it never joins this VM's cluster.
  `on/5` runs a function on a machine either way. `context.machines` maps each label
  to `:local` or `%{mc, peer, home, mode, environment}`.
  """

  import ExUnit.Assertions

  alias HalC2.Test.Mc

  @support Path.expand(".", __DIR__)

  @doc """
  Makes this VM the machine `local` in a cluster and starts each of `others` as a
  member. Returns the context with `:machines`.
  """
  def cluster(context, local, others) do
    Mc.World.put_env("HAL_C2_LABEL", local)
    for {key, value} <- sessions(context.mc.home), do: Mc.World.put_env(key, value)
    Mc.World.put_app_env(:agent_sessions_home, user_home(context.mc.home))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(user_home(context.mc.home)) end)
    distribute()
    context = %{context | mc: Mc.restart(context.mc)}

    Enum.reduce(others, Map.put(context, :machines, %{local => :local}), fn label, context ->
      put_in(context, [:machines, label], start(context, label, :cluster))
    end)
  end

  @doc "Starts `label` as a member (`:cluster`) or a machine on its own (`:alone`)."
  def start(context, label, mode, home \\ nil) do
    home = home || Mc.tmp_dir(context.mc, label)

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

    {:ok, peer, mc} =
      case :peer.start(opts) do
        {:ok, peer} -> {:ok, peer, nil}
        {:ok, peer, mc} -> {:ok, peer, mc}
      end

    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    machine = %{mc: mc, peer: peer, home: home, mode: mode, label: label}

    app_env =
      [start_mc: true, home: home, port: 0, agent_sessions_home: user_home(home)] ++
        fakes(home)

    for {key, value} <- app_env,
        do: :ok = call(machine, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = call(machine, Application, :ensure_all_started, [:hal_c2], 30_000)

    if mode == :cluster do
      assert_receive {:hal_c2_shell, {:environment, ^mc, %{"environmentId" => environment}}},
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
  def stop(%{peer: peer, mc: mc, mode: mode}) do
    :peer.stop(peer)
    if mode == :cluster, do: assert_receive({:hal_c2_shell, {:mc, ^mc, :down}}, 5_000)
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

  defp call(%{mode: :cluster, mc: mc}, mod, fun, args, timeout),
    do: :erpc.call(mc, mod, fun, args, timeout)

  defp call(%{mode: :alone, peer: peer}, mod, fun, args, timeout),
    do: :peer.call(peer, mod, fun, args, timeout)

  @doc "The Erlang MC of a machine."
  def mc_of(context, label) do
    case machine(context, label) do
      :local -> node()
      %{mc: mc} -> mc
    end
  end

  @doc "A machine's data directories' root: its home."
  def home(context, label) do
    case machine(context, label) do
      :local -> context.mc.home
      %{home: home} -> home
    end
  end

  @doc """
  A machine's user home, where its agents keep their sessions: "~" in a feature.
  Each machine's Claude, Codex and Pi homes are the defaults under it. It sits beside
  the machine's HAL-C2 home, not inside it, as a real user's does.
  """
  def user_home(context, label) when is_binary(label), do: user_home(home(context, label))
  def user_home(home) when is_binary(home), do: home <> "-user"

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

  @doc "This MC's own sidebar rows, as `{kind, row}`, once pending ones are written."
  def rows do
    for %{id: id} <- HalC2.Store.list_streams(HalC2.Store.path()),
        do: HalC2.Streams.flush_shell(id)

    for {_id, kind, row} <- HalC2.Store.list_shell(HalC2.Store.path()), do: {kind, row}
  end

  @doc "A stream's entities of `kind` on this MC."
  def entities(stream_id, kind) do
    HalC2.Streams.Server.state(HalC2.Streams.ensure(stream_id))
    |> HalC2.StreamState.list(kind)
  end

  @doc "The ids of this MC's streams."
  def streams, do: for(%{id: id} <- HalC2.Store.list_streams(HalC2.Store.path()), do: id)

  @doc "Threads this MC is receiving in a move (`HalC2.ThreadMove.accept/2`)."
  def incoming_moves do
    dir = Path.join(HalC2.Paths.data_dir(), "incoming-moves")
    if File.dir?(dir), do: File.ls!(dir), else: []
  end

  @doc "The sha256 of each file this MC holds for moves that have not finished arriving."
  def incoming_move_files do
    for path <- Path.wildcard(Path.join([HalC2.Paths.data_dir(), "incoming-moves", "*", "*"])),
        do: :crypto.hash(:sha256, File.read!(path))
  end

  @doc "The bundles this MC holds that it made for a thread's archive."
  def archive_bundles do
    dir = Path.join(HalC2.Paths.cache_dir(), "thread-bundles")
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

  @doc "The diff of a thread's runs `from` to `to` on this MC (`HalC2.Checkpoint.turn_diff/5`)."
  def turn_diff(id, from, to) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
    HalC2.Checkpoint.turn_diff(state, id, from, to, false)
  end

  @doc "Creates a project on this MC and waits until its row is stored."
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
  Sends `text` to the thread `id` on this MC and waits for its run to finish;
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

  @doc "Deletes a project on this MC."
  def delete_project(id) do
    {:ok, _} = HalC2.Projects.mutate(%{"type" => "project.delete", "projectId" => id})
    HalC2.Streams.flush_shell(id)
  end

  @doc """
  Makes the scripted fake Pi (`fake_pi_rpc.py`) this MC's `pi`, keeping its
  `config.json` and `log.jsonl` in `dir`.
  """
  def install_pi(dir) do
    bin = Path.join([dir, "bin", "pi"])
    File.mkdir_p!(Path.dirname(bin))
    turns = %{"turns" => HalC2.Test.FakeAcp.pi_turns()}
    File.write!(Path.join(dir, "config.json"), JSON.encode!(turns))

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{dir}' FAKE_BIN="$0"
    exec python3 -u '#{Path.join(@support, "fake_pi_rpc.py")}' "$@"
    """)

    File.chmod!(bin, 0o755)
    HalC2.Acp.forget("pi")

    put_settings(fn settings ->
      put_in(settings, [Access.key("providers", %{}), Access.key("pi", %{})], %{
        "enabled" => true,
        "binaryPath" => bin
      })
    end)
  end

  @doc """
  Makes the fake ACP agent (`fake_acp.py`) this MC's `instance`, enabled, with each
  prompt it is sent logged to `acp-inputs.jsonl` and every message to
  `acp-trace.jsonl` in `dir`. With `agent_id` the
  instance is an ACP registry agent's.
  """
  def install_acp(dir, instance, agent_id \\ nil) do
    File.mkdir_p!(dir)

    command = [
      "env",
      "FAKE_ACP_INPUT_LOG=" <> Path.join(dir, "acp-inputs.jsonl"),
      "FAKE_ACP_TRACE=" <> Path.join(dir, "acp-trace.jsonl"),
      "python3",
      "-u",
      Path.join(@support, "fake_acp.py")
    ]

    commands = Application.get_env(:hal_c2, :acp_commands, %{})
    Application.put_env(:hal_c2, :acp_commands, Map.put(commands, instance, command))
    HalC2.Acp.forget(instance)

    # The registry lists the agent, as if it had been fetched just now.
    if agent_id do
      agent = %{"id" => agent_id, "name" => agent_id, "version" => "1.0.0", "distribution" => %{}}
      now = System.system_time(:millisecond)
      :persistent_term.put({HalC2.Acp.Catalog, :index}, {now, [agent]})
    end

    put_settings(fn settings ->
      if agent_id do
        entry = %{
          "driver" => "acpRegistry",
          "enabled" => true,
          "config" => %{"agentId" => agent_id}
        }

        instances = Map.put(settings["providerInstances"] || %{}, instance, entry)
        Map.put(settings, "providerInstances", instances)
      else
        put_in(settings, [Access.key("providers", %{}), Access.key(instance, %{})], %{
          "enabled" => true
        })
      end
    end)
  end

  @doc "Sets the variable `name` on the provider instance `instance` (a built-in one) here."
  def put_instance_env(instance, name, value) do
    put_settings(fn settings ->
      instances = settings["providerInstances"] || %{}
      entry = Map.get(instances, instance, %{"driver" => instance, "enabled" => true})
      entry = Map.put(entry, "environment", [%{"name" => name, "value" => value}])
      Map.put(settings, "providerInstances", Map.put(instances, instance, entry))
    end)
  end

  defp put_settings(fun) do
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(fun.(settings), version)
    :ok
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

  # Makes this VM a named MC, as a clustered MC boots.
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
