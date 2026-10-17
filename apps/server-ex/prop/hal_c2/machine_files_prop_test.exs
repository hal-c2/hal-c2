defmodule HalC2.MachineFilesPropTest do
  @moduledoc """
  `HalC2.MachineFiles` against a model of the cluster and the helper's connection.
  The helper is the test process (as in `test/hal_c2/machine_files_test.exs`): what
  the MC sends it arrives here, and its 9P requests are sent from here, each one
  waited on for its reply.

  The promises modelled: the helper starts with the first member and is ready once
  it attaches; a member's folder is there while it is a member and gone once it
  leaves; a request into the folder of a member that is down fails with EHOSTDOWN at
  once, and is answered again when it is back; a fid in a folder whose member
  left, or that another machine took the name of, is stale (ESTALE) and never
  reaches the machine there now; nothing outside a shared root is answered (the member
  here shares one project); a file opened there is held open on its machine exactly
  while a fid here has it open, and never after the helper's connection ends; a helper
  that exits is started again with a fresh connection, its old fids gone; and
  `local_path/3` says where a member's file is here, or why it is not.

  A member that is up is this MC (its Share answers over a local `:erpc`); one that
  is down is a node no one is connected to.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.MachineFiles
  alias HalC2.MachineFiles.{Session, Share}
  alias HalC2.{Shell, Store}

  @moduletag timeout: :infinity

  @root "/state/machines"
  @names ["devbox", "lab"]
  @fids [1, 2, 3]
  # Fids walked on to the shared file and opened.
  @files [4, 5]
  # Nothing is shared under it: the member here has no projects at that path.
  @outside "nowhere-machine-files-prop"
  @reply_timeout 5_000

  defmodule QuietWire do
    @moduledoc false
    def connected, do: []
    def cast(_peer, _message), do: :ok
  end

  defmodule FakeHelper do
    @moduledoc false
    def available, do: :ok
    def prepare(_root), do: :ok
    def unmount(_root), do: :ok
    def close(_port), do: :ok

    def open(root, _opts) do
      test = Application.fetch_env!(:hal_c2, :machine_files_prop)
      Kernel.send(test, {:opened, root})
      {:ok, test, 4242}
    end

    def send(test, iodata), do: Kernel.send(test, {:to_helper, IO.iodata_to_binary(iodata)})
  end

  property "members' folders follow the cluster, and a member that is down never holds a request",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        teardown()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp setup do
    home = HalC2.Prop.scratch_home("machine-files")
    shop = Path.join(home, "shop")
    File.mkdir_p!(shop)
    File.write!(Path.join(shop, "a.ts"), "a")
    Process.put(:file, Path.join(shop, "a.ts"))
    Application.put_env(:hal_c2, :shell_transport, QuietWire)
    Application.put_env(:hal_c2, :machine_files_prop, self())
    {:ok, cluster} = Agent.start(fn -> %{} end)
    Process.put(:cluster, cluster)

    environments = fn ->
      for {name, %{up: up, env: env}} <- Agent.get(cluster, & &1) do
        mc = if up, do: node(), else: :"#{name}@nowhere"
        {mc, %{"environmentId" => env, "label" => name}}
      end
    end

    HalC2.Prop.start_services([
      {Store, path: Path.join(home, "hal-c2.sqlite")},
      Shell,
      {
        MachineFiles,
        # Restarted at once every time, so a case with many crashes does not wait.
        enabled: true,
        subscribe: false,
        name: nil,
        root: @root,
        helper: FakeHelper,
        backoff_base: 0,
        environments: environments
      }
    ])

    Shell.put_row("shop", {"project", %{"id" => "shop", "workspaceRoot" => shop}})
    :ok = Shell.sync()
  end

  defp teardown do
    HalC2.Prop.stop_services()
    Agent.stop(Process.delete(:cluster))
    Application.delete_env(:hal_c2, :machine_files_prop)
    Application.delete_env(:hal_c2, :shell_transport)
    File.rm_rf!(Application.fetch_env!(:hal_c2, :home))
  end

  defp server do
    children = Supervisor.which_children(Process.get({HalC2.Prop, :services}))
    {_, pid, _, _} = List.keyfind(children, MachineFiles, 0)
    pid
  end

  # --- model ------------------------------------------------------------------

  # members: name => %{up, env}, env the machine with that label now; opened: the
  # helper has started; fids: fid => the folder it was walked to on the helper's
  # current connection, or :gone once that folder's machine left it; files: the fids
  # that have the shared file open on that connection.
  def initial_state, do: %{members: %{}, opened: false, fids: %{}, files: MapSet.new()}

  def command(state) do
    members = Map.keys(state.members)

    frequency(
      [
        {3, {:call, __MODULE__, :join, [oneof(@names), boolean(), not state.opened]}},
        {2, {:call, __MODULE__, :local_path, [oneof(@names)]}}
      ] ++
        if(members == [],
          do: [],
          else: [
            {1, {:call, __MODULE__, :leave, [oneof(members)]}},
            {1, {:call, __MODULE__, :replace, [oneof(members)]}},
            {2, {:call, __MODULE__, :set_up, [oneof(members), boolean()]}}
          ]
        ) ++
        if(state.opened,
          do: [
            {3, {:call, __MODULE__, :open_folder, [oneof(@fids), oneof(@names)]}},
            {4, {:call, __MODULE__, :read_in, [oneof(@fids)]}},
            {3, {:call, __MODULE__, :open_file, [oneof(@fids), oneof(@files)]}},
            {2, {:call, __MODULE__, :close_file, [oneof(@files)]}},
            {1, {:call, __MODULE__, :crash, []}}
          ],
          else: []
        )
    )
  end

  def precondition(state, {:call, _, :join, [name, _up, first]}),
    do: not Map.has_key?(state.members, name) and first == not state.opened

  def precondition(state, {:call, _, cmd, [name | _]}) when cmd in [:leave, :replace, :set_up],
    do: Map.has_key?(state.members, name)

  def precondition(state, {:call, _, cmd, _})
      when cmd in [:open_folder, :read_in, :open_file, :close_file, :crash],
      do: state.opened

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :join, [name, up, _first]}) do
    member = %{up: up, env: "env-#{name}"}
    %{state | members: Map.put(state.members, name, member), opened: true}
  end

  def next_state(state, _result, {:call, _, :leave, [name]}),
    do: left(%{state | members: Map.delete(state.members, name)}, name)

  def next_state(state, _result, {:call, _, :replace, [name]}),
    do: left(update_in(state.members[name].env, &other_env(name, &1)), name)

  def next_state(state, _result, {:call, _, :set_up, [name, up]}),
    do: put_in(state.members[name].up, up)

  def next_state(state, _result, {:call, _, :open_folder, [fid, name]}) do
    if Map.has_key?(state.members, name),
      do: %{state | fids: Map.put(state.fids, fid, name)},
      else: state
  end

  def next_state(state, _result, {:call, _, :open_file, [fid, file]}) do
    case opens(state, fid) do
      :opened -> %{state | files: MapSet.put(state.files, file)}
      _ -> state
    end
  end

  def next_state(state, _result, {:call, _, :close_file, [file]}),
    do: %{state | files: MapSet.delete(state.files, file)}

  def next_state(state, _result, {:call, _, :crash, []}),
    do: %{state | fids: %{}, files: MapSet.new()}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :open_folder, [_fid, name]}, result) do
    # The folder itself is this machine's, there whether the member is up or not.
    if Map.has_key?(state.members, name), do: result == :walked, else: result == {:error, 2}
  end

  def postcondition(state, {:call, _, :read_in, [fid]}, result) do
    case Map.fetch(state.fids, fid) do
      :error -> result == {:error, 9}
      {:ok, :gone} -> result == {:error, 116}
      # A member down cannot be reached; one up shares nothing outside its roots.
      {:ok, folder} -> result == {:error, if(state.members[folder].up, do: 2, else: 112)}
    end
  end

  # What is held open on the member is what fids here have open: no more, no less.
  def postcondition(state, {:call, _, :open_file, [fid, file]} = call, {result, held}) do
    result == opens(state, fid) and
      held == MapSet.size(next_state(state, nil, call).files) and
      (result != :opened or MapSet.member?(next_state(state, nil, call).files, file))
  end

  def postcondition(state, {:call, _, :close_file, [file]}, held),
    do: held == MapSet.size(MapSet.delete(state.files, file))

  def postcondition(_state, {:call, _, :crash, []}, {result, held}),
    do: result == :ok and held == 0

  # Asked by the environment id the label's first machine has.
  def postcondition(state, {:call, _, :local_path, [name]}, result) do
    first = "env-#{name}"

    case Map.fetch(state.members, name) do
      {:ok, %{env: ^first, up: true}} -> result == {:ok, "#{@root}/#{name}/home/me/a.ts"}
      {:ok, %{env: ^first, up: false}} -> result == {:error, :unavailable, name}
      _ -> result == {:error, :not_a_member, nil}
    end
  end

  def postcondition(_state, _call, result), do: result == :ok

  # What opening the shared file from `fid` gets.
  defp opens(state, fid) do
    case Map.fetch(state.fids, fid) do
      :error -> {:error, 9}
      {:ok, :gone} -> {:error, 116}
      {:ok, folder} -> if state.members[folder].up, do: :opened, else: {:error, 112}
    end
  end

  defp left(state, name),
    do: %{
      state
      | fids: Map.new(state.fids, fn {fid, at} -> {fid, if(at == name, do: :gone, else: at)} end)
    }

  defp other_env(name, env),
    do: if(env == "env-#{name}", do: "env-#{name}-b", else: "env-#{name}")

  # --- commands ---------------------------------------------------------------

  def join(name, up, first) do
    cluster(&Map.put(&1, name, %{up: up, env: "env-#{name}"}))
    if first, do: connect(), else: :ok
  end

  def leave(name), do: cluster(&Map.delete(&1, name))
  # Another machine with the same label: the first left, and this one joined.
  def replace(name), do: cluster(&update_in(&1[name].env, fn env -> other_env(name, env) end))
  def set_up(name, up), do: cluster(&put_in(&1[name].up, up))

  def open_folder(fid, name) do
    case walk(0, fid, [name]) do
      {111, <<1::16-little, _qid::binary-size(13)>>} -> :walked
      other -> errno(other)
    end
  end

  def read_in(fid), do: errno(walk(fid, 9, [@outside]))

  def local_path(name), do: MachineFiles.local_path("env-#{name}", "/home/me/a.ts", server())

  def open_file(fid, file) do
    names = Process.get(:file) |> Path.split() |> tl()

    result =
      case walk(fid, file, names) do
        {111, _qids} ->
          case t(3, 12, <<file::32-little, 0::32-little>>) do
            {13, _qid_iounit} -> :opened
            other -> errno(other)
          end

        other ->
          errno(other)
      end

    {result, held()}
  end

  def close_file(file) do
    {121, ""} = t(4, 120, <<file::32-little>>)
    held()
  end

  def crash do
    send(server(), {self(), {:exit_status, 1}})
    result = connect()
    {result, held()}
  end

  # The files held open on the member once what was let go is gone: those the
  # session holds, and an extra one for each pin nothing holds that stays.
  defp held do
    pins = Session.pins(:sys.get_state(server()).session)
    stray = for pin <- pins_alive() -- pins, not gone?(pin), do: pin
    length(pins) + length(stray)
  end

  defp pins_alive do
    for pid <- Process.list(),
        Process.info(pid, :current_function) == {:current_function, {Share, :wait, 2}},
        do: pid
  end

  defp gone?(pin) do
    ref = Process.monitor(pin)

    receive do
      {:DOWN, ^ref, :process, ^pin, _} -> true
    after
      @reply_timeout -> Process.demonitor(ref, [:flush]) && false
    end
  end

  # The cluster changes as `HalC2.Shell` would tell of it.
  defp cluster(change) do
    Agent.update(Process.get(:cluster), change)
    pid = server()
    send(pid, {:hal_c2_shell, {:mc, :changed, :up}})
    MachineFiles.sync(pid)
  end

  # The helper starts and the kernel attaches, as a mount does.
  defp connect do
    receive do
      {:opened, @root} ->
        with {101, _} <- t(0xFFFF, 100, <<8192::32-little>> <> s("9P2000.L")),
             {105, _} <-
               t(
                 1,
                 104,
                 <<0::32-little, 0xFFFFFFFF::32-little>> <>
                   s("me") <> s("") <> <<1000::32-little>>
               ) do
          MachineFiles.await_ready(server())
        end
    after
      @reply_timeout -> :not_opened
    end
  end

  defp walk(fid, newfid, names) do
    body =
      <<fid::32-little, newfid::32-little, length(names)::16-little>> <>
        Enum.map_join(names, &s/1)

    t(2, 110, body)
  end

  defp t(tag, type, body) do
    send(
      server(),
      {self(), {:data, <<byte_size(body) + 7::32-little, type, tag::16-little>> <> body}}
    )

    receive do
      {:to_helper, <<_size::32-little, kind, ^tag::16-little, reply::binary>>} -> {kind, reply}
    after
      @reply_timeout -> :no_reply
    end
  end

  defp errno({7, <<errno::32-little>>}), do: {:error, errno}
  defp errno(other), do: {:unexpected, other}

  defp s(value), do: <<byte_size(value)::16-little>> <> value
end
