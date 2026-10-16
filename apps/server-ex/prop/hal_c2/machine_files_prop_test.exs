defmodule HalC2.MachineFilesPropTest do
  @moduledoc """
  `HalC2.MachineFiles` against a model of the cluster and the helper's connection.
  The helper is the test process (as in `test/hal_c2/machine_files_test.exs`): what
  the MC sends it arrives here, and its 9P requests are sent from here, each one
  waited on for its reply.

  The promises modelled: the helper starts with the first member and is ready once
  it attaches; a member's folder is there while it is a member and gone once it
  leaves; a request into the folder of a member that is down fails with EHOSTDOWN at
  once, and is answered again when it is back; one into a folder that went is
  ENOENT; nothing outside a shared root is answered (the member here shares none);
  a helper that exits is started again with a fresh connection, its old fids gone;
  and `local_path/3` says where a member's file is here, or why it is not.

  A member that is up is this MC (its Share answers over a local `:erpc`); one that
  is down is a node no one is connected to.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.MachineFiles

  @moduletag timeout: :infinity

  @root "/state/machines"
  @names ["devbox", "lab"]
  @fids [1, 2, 3]
  # Nothing is shared under it: the member here has no projects at that path.
  @outside "nowhere-machine-files-prop"
  @reply_timeout 5_000

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
    Application.put_env(:hal_c2, :machine_files_prop, self())
    {:ok, cluster} = Agent.start(fn -> %{} end)
    Process.put(:cluster, cluster)

    environments = fn ->
      for {name, up} <- Agent.get(cluster, & &1) do
        mc = if up, do: node(), else: :"#{name}@nowhere"
        {mc, %{"environmentId" => "env-#{name}", "label" => name}}
      end
    end

    HalC2.Prop.start_services([
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
  end

  defp teardown do
    HalC2.Prop.stop_services()
    Agent.stop(Process.delete(:cluster))
    Application.delete_env(:hal_c2, :machine_files_prop)
  end

  defp server do
    [{_, pid, _, _}] = Supervisor.which_children(Process.get({HalC2.Prop, :services}))
    pid
  end

  # --- model ------------------------------------------------------------------

  # members: name => up?; opened: the helper has started; fids: fid => the folder it
  # was walked to on the helper's current connection.
  def initial_state, do: %{members: %{}, opened: false, fids: %{}}

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
            {2, {:call, __MODULE__, :set_up, [oneof(members), boolean()]}}
          ]
        ) ++
        if(state.opened,
          do: [
            {3, {:call, __MODULE__, :open_folder, [oneof(@fids), oneof(@names)]}},
            {4, {:call, __MODULE__, :read_in, [oneof(@fids)]}},
            {1, {:call, __MODULE__, :crash, []}}
          ],
          else: []
        )
    )
  end

  def precondition(state, {:call, _, :join, [name, _up, first]}),
    do: not Map.has_key?(state.members, name) and first == not state.opened

  def precondition(state, {:call, _, cmd, [name | _]}) when cmd in [:leave, :set_up],
    do: Map.has_key?(state.members, name)

  def precondition(state, {:call, _, cmd, _}) when cmd in [:open_folder, :read_in, :crash],
    do: state.opened

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :join, [name, up, _first]}),
    do: %{state | members: Map.put(state.members, name, up), opened: true}

  def next_state(state, _result, {:call, _, :leave, [name]}),
    do: %{state | members: Map.delete(state.members, name)}

  def next_state(state, _result, {:call, _, :set_up, [name, up]}),
    do: %{state | members: Map.put(state.members, name, up)}

  def next_state(state, _result, {:call, _, :open_folder, [fid, name]}) do
    if Map.has_key?(state.members, name),
      do: %{state | fids: Map.put(state.fids, fid, name)},
      else: state
  end

  def next_state(state, _result, {:call, _, :crash, []}), do: %{state | fids: %{}}
  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :open_folder, [_fid, name]}, result) do
    # The folder itself is this machine's, there whether the member is up or not.
    if Map.has_key?(state.members, name), do: result == :walked, else: result == {:error, 2}
  end

  def postcondition(state, {:call, _, :read_in, [fid]}, result) do
    case Map.fetch(state.fids, fid) do
      :error -> result == {:error, 9}
      {:ok, folder} -> result == {:error, read_error(state, folder)}
    end
  end

  def postcondition(state, {:call, _, :local_path, [name]}, result) do
    case Map.fetch(state.members, name) do
      :error -> result == {:error, :not_a_member, nil}
      {:ok, true} -> result == {:ok, "#{@root}/#{name}/home/me/a.ts"}
      {:ok, false} -> result == {:error, :unavailable, name}
    end
  end

  def postcondition(_state, _call, result), do: result == :ok

  # A gone folder is not there; a member down cannot be reached; one up shares
  # nothing outside its roots.
  defp read_error(state, folder) do
    case Map.fetch(state.members, folder) do
      :error -> 2
      {:ok, false} -> 112
      {:ok, true} -> 2
    end
  end

  # --- commands ---------------------------------------------------------------

  def join(name, up, first) do
    cluster(&Map.put(&1, name, up))
    if first, do: connect(), else: :ok
  end

  def leave(name), do: cluster(&Map.delete(&1, name))
  def set_up(name, up), do: cluster(&Map.put(&1, name, up))

  def open_folder(fid, name) do
    case walk(0, fid, [name]) do
      {111, <<1::16-little, _qid::binary-size(13)>>} -> :walked
      other -> errno(other)
    end
  end

  def read_in(fid), do: errno(walk(fid, 9, [@outside]))

  def local_path(name), do: MachineFiles.local_path("env-#{name}", "/home/me/a.ts", server())

  def crash do
    send(server(), {self(), {:exit_status, 1}})
    connect()
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
