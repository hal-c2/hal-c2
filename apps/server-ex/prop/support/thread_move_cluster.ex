defmodule HalC2.Prop.ThreadMoveCluster do
  @moduledoc """
  A cluster of MCs for the thread move properties: each machine is a `:peer` running the
  whole MC in a scratch home, connected to this VM and, through it, to the others. This
  VM only drives them; it is not an MC. Peers take a few seconds to start, so a property
  starts its cluster once and its cases share it, each with threads of its own.

  Distribution runs on 127.0.0.1 with ports `epmd` hands out, never a cluster port.

  The functions under "on a machine" run on a peer (`on/4`).
  """

  @support Path.expand("../../test/support", __DIR__)

  @doc """
  Starts a machine for each label; returns `%{label => %{mc, peer, home}}`. A peer stops
  with the process that started it, and ExUnit's `setup_all` process ends before the
  tests run, so the peers belong to a process of their own until `stop/1`.
  """
  def start(labels) do
    distribute()
    root = HalC2.Prop.scratch_home("thread_move")
    driver = self()

    owner =
      spawn(fn ->
        machines = Map.new(labels, fn label -> {label, start_machine(root, label)} end)
        send(driver, {:machines, self(), machines})

        receive do
          :stop -> for {_, %{peer: peer}} <- machines, do: :peer.stop(peer)
        end
      end)

    machines =
      receive do
        {:machines, ^owner, machines} -> machines
      after
        120_000 -> raise "the machines never started"
      end

    # Every machine knows every other one's sidebar, so a move finds its destination.
    for {_, %{mc: mc}} <- machines, do: :ok = :erpc.call(mc, HalC2.Shell, :subscribe, [self()])
    await_cluster(machines)
    Map.new(machines, fn {label, machine} -> {label, Map.put(machine, :owner, owner)} end)
  end

  def stop(machines) do
    %{owner: owner} = machines |> Map.values() |> hd()
    ref = Process.monitor(owner)
    send(owner, :stop)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end

  defp distribute do
    unless :erlang.is_alive() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = :"hal_c2_prop_tm#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
    end

    :ok
  end

  defp start_machine(root, label) do
    home = Path.join(root, label)
    user = home <> "-user"

    env =
      for {key, value} <- [
            {"HAL_C2_LABEL", label},
            {"FAKE_SESSIONS", "1"},
            {"CLAUDE_CONFIG_DIR", Path.join(user, ".claude")},
            {"CODEX_HOME", Path.join(user, ".codex")},
            {"PI_CODING_AGENT_DIR", Path.join(user, ".pi/agent")}
          ],
          do: {String.to_charlist(key), String.to_charlist(value)}

    {:ok, peer, mc} =
      :peer.start(%{
        name: :"hal_c2_tm_#{label}#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1]),
        env: env
      })

    app_env = [
      start_mc: true,
      home: home,
      port: 0,
      agent_sessions_home: user,
      codex_command: [
        "env",
        "FAKE_CODEX_LOG=" <> Path.join(home, "codex-requests.log"),
        "python3",
        "-u",
        Path.join(@support, "fake_codex.py")
      ]
    ]

    # Loaded first, so its own defaults do not replace these.
    :ok = :erpc.call(mc, __MODULE__, :load_mc, [])

    for {key, value} <- app_env,
        do: :ok = :erpc.call(mc, Application, :put_env, [:hal_c2, key, value])

    :ok = :erpc.call(mc, __MODULE__, :start_mc, [], 60_000)
    :ok = :erpc.call(mc, __MODULE__, :create_project, ["proj-#{label}", Path.join(home, "shop")])
    %{mc: mc, peer: peer, home: home, label: label}
  end

  defp await_cluster(machines) do
    all = machines |> Map.values() |> Enum.map(& &1.mc) |> Enum.sort()

    known? =
      Enum.all?(machines, fn {_, %{mc: mc}} ->
        known = for {n, _} <- :erpc.call(mc, HalC2.Shell, :environments, []), do: n
        Enum.sort(known) == all
      end)

    unless known? do
      receive do
        {:hal_c2_shell, _} -> await_cluster(machines)
      after
        30_000 -> raise "the machines never formed a cluster"
      end
    end
  end

  @doc "Runs `fun(args)` of this module on the machine `mc`."
  def on(mc, fun, args, timeout \\ 60_000), do: :erpc.call(mc, __MODULE__, fun, args, timeout)

  # --- on a machine ----------------------------------------------------------------

  @doc """
  Loads the MC without PropCheck, one of its applications under `MIX_ENV=prop` that
  starts only under Mix, which a peer does not run.
  """
  def load_mc do
    {:ok, [{:application, :hal_c2, spec}]} = :file.consult(:code.where_is_file(~c"hal_c2.app"))
    spec = Keyword.update!(spec, :applications, &(&1 -- [:propcheck]))
    :ok = :application.load({:application, :hal_c2, spec})
  end

  def start_mc do
    {:ok, _} = Application.ensure_all_started(:hal_c2)
    :ok
  end

  def create_project(id, root) do
    File.mkdir_p!(root)

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => id,
        "title" => id,
        "workspaceRoot" => root
      })

    HalC2.Streams.flush_shell(id)
  end

  @doc """
  A thread in `project` with a little history: messages, one with an attachment larger
  than a move sends at once, so a move copies it in pieces.
  """
  def create_thread(id, project, title) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => id,
        "projectId" => project,
        "title" => title,
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
      })

    attachment = "att-#{id}"
    path = Path.join(HalC2.Attachments.dir(), attachment <> ".bin")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(:crypto.hash(:sha256, id), div(1_200_000, 32)))

    messages =
      for n <- 1..3 do
        %{
          "id" => "#{id}-m#{n}",
          "threadId" => id,
          "role" => "user",
          "text" => "message #{n} of #{title}",
          "attachments" => if(n == 1, do: [%{"id" => attachment, "type" => "file"}], else: [])
        }
      end

    :ok =
      HalC2.Streams.transact(id, :thread, fn state ->
        {for(
           m <- messages,
           do: HalC2.Orchestration.upsert(state, "message", m["id"], fn _ -> m end)
         ), :ok}
      end)

    HalC2.Streams.flush_shell(id)
    :ok
  end

  def rename(id, title) do
    HalC2.Orchestration.dispatch(%{
      "type" => "thread.metadata.update",
      "threadId" => id,
      "title" => title
    })
  end

  @doc """
  What this machine has of the thread `id`: `:none`, `:forward` (a forwarding record),
  `{:moving, title}` or `{:live, title, messages, attachment}`, where `attachment` is the
  sha256 of the first message's attachment as stored here.
  """
  def copy(id) do
    case HalC2.ThreadArchive.local_thread(id) do
      nil ->
        :none

      %{"movedTo" => %{}} ->
        :forward

      %{"moving" => %{}} = thread ->
        {:moving, thread["title"]}

      thread ->
        state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
        messages = HalC2.StreamState.list(state, "message")

        attachment =
          case HalC2.Attachments.path(%{"id" => "att-#{id}"}) do
            nil -> nil
            path -> :crypto.hash(:sha256, File.read!(path))
          end

        {:live, thread["title"], messages |> Enum.map(& &1["text"]) |> Enum.sort(), attachment}
    end
  end

  @doc "The copies this machine is receiving (`incoming-moves`) and its archive scratch."
  def leftovers do
    incoming = Path.join(HalC2.Paths.data_dir(), "incoming-moves")
    if File.dir?(incoming), do: File.ls!(incoming), else: []
  end

  @doc """
  Moves the thread in a process of its own, which sends `{:move_result, ref, result}` to
  `driver`; returns the process.
  """
  def start_move(id, to, project, driver, ref) do
    spawn(fn ->
      send(
        driver,
        {:move_result, ref, HalC2.ThreadMove.move(id, to, project: project, confirmed: true)}
      )
    end)
  end

  @doc "Holds the move of `id` at `stage` on this machine, once (`hook/3`)."
  def hold(id, stage, driver) do
    Application.put_env(:hal_c2, :thread_move_hook, {__MODULE__, :hook, [driver]})
    holds = Application.get_env(:hal_c2, :thread_move_prop_holds, %{})
    Application.put_env(:hal_c2, :thread_move_prop_holds, Map.put(holds, id, stage))
  end

  def unhold(id) do
    holds = Application.get_env(:hal_c2, :thread_move_prop_holds, %{})
    Application.put_env(:hal_c2, :thread_move_prop_holds, Map.delete(holds, id))
  end

  @doc """
  The `:thread_move_hook`: at the held stage it tells `driver` with `{:move_held, pid,
  stage, id}` and waits for `:go`, or `:crash` to end the process there.
  """
  def hook(driver, stage, id) do
    holds = Application.get_env(:hal_c2, :thread_move_prop_holds, %{})

    if holds[id] == stage do
      unhold(id)
      send(driver, {:move_held, self(), stage, id})

      receive do
        :go -> :ok
        :crash -> exit(:cut_off)
      end
    else
      :ok
    end
  end

  @doc "Stops `child` of the MC's supervisor and starts it again, as a crash would."
  def restart(child) do
    :ok = Supervisor.terminate_child(HalC2.Supervisor, child)
    {:ok, _} = Supervisor.restart_child(HalC2.Supervisor, child)
    # `HalC2.ThreadMove` settles what it finds as its first message.
    if child == HalC2.ThreadMove, do: :sys.get_state(HalC2.ThreadMove)
    :ok
  end

  @doc "Tells `pid` whenever the thread `id` changes here."
  def watch(id, pid), do: HalC2.Streams.watch(id, pid)
end
