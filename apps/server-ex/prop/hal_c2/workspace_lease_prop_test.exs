defmodule HalC2.WorkspaceLeasePropTest do
  @moduledoc """
  `HalC2.WorkspaceLease` against a model of who holds which folder. Clients (each a
  process inside `with_lease/2`, as a terminal starting or a storage sweep removing a
  worktree is) ask for nested folders, one of them reached through a symbolic link,
  then let go or crash, and for a repository's turns (`HalC2.Vcs`), keyed by the same
  path as one of the folders yet held apart from all of them. No two holders' folders ever overlap, a client waits only
  while a holder or an earlier waiter overlaps its folder, and a waiter is let in, in
  the order it asked, once nothing ahead of it overlaps.

  Every step is observed through the trace of what the lease server received (the
  client's ask, its release, its `:DOWN`), then `held/0`, so no step waits on time.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.WorkspaceLease

  @moduletag timeout: :infinity

  @clients [:c1, :c2, :c3, :c4]
  # "link" is a symbolic link to "a", so it is the same folder. "repo" is the turns of
  # a repository whose git folder is "a": it overlaps only itself.
  @folders [:root, :a, :ab, :c, :link, :repo]

  property "holders never overlap and overlapping waiters go in order",
    numtests: HalC2.Prop.numtests(1000),
    max_size: 30 do
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

  defp start_case do
    {:ok, dir} = HalC2.Paths.real(HalC2.Prop.scratch_home("workspace-lease"))
    for sub <- ["a/b", "c"], do: File.mkdir_p!(Path.join(dir, sub))
    File.ln_s!(Path.join(dir, "a"), Path.join(dir, "link"))
    Process.put(:dir, dir)
    Process.put(:pids, %{})
    {:ok, lease} = WorkspaceLease.start_link(nil)
    :erlang.trace(lease, true, [:receive])
    Process.put(:lease, lease)
  end

  defp end_case do
    for {_client, pid} <- Process.get(:pids), do: Process.exit(pid, :kill)
    lease = Process.get(:lease)
    :erlang.trace(lease, false, [:receive])
    GenServer.stop(lease)
    File.rm_rf!(Process.get(:dir))
    flush()
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  # --- model ------------------------------------------------------------------

  # held: client => folder. waiting: [{client, folder}], in the order they asked.
  def initial_state, do: %{held: %{}, waiting: []}

  def command(state) do
    busy = Map.keys(state.held) ++ Enum.map(state.waiting, &elem(&1, 0))

    frequency(
      [{5, {:call, __MODULE__, :ask, [oneof(@clients), oneof(@folders)]}}] ++
        if(state.held == %{},
          do: [],
          else: [{4, {:call, __MODULE__, :release, [oneof(Map.keys(state.held))]}}]
        ) ++
        if(busy == [], do: [], else: [{2, {:call, __MODULE__, :crash, [oneof(busy)]}}])
    )
  end

  def precondition(state, {:call, _, :ask, [client, _folder]}), do: not busy?(state, client)

  def precondition(state, {:call, _, :release, [client]}), do: Map.has_key?(state.held, client)
  def precondition(state, {:call, _, :crash, [client]}), do: busy?(state, client)

  defp busy?(state, client),
    do: Map.has_key?(state.held, client) or List.keymember?(state.waiting, client, 0)

  def next_state(state, _result, {:call, _, :ask, [client, folder]}) do
    if free?(folder, Map.values(state.held), state.waiting),
      do: put_in(state.held[client], folder),
      else: %{state | waiting: state.waiting ++ [{client, folder}]}
  end

  def next_state(state, _result, {:call, _, cmd, [client]}) when cmd in [:release, :crash] do
    let_in(%{
      held: Map.delete(state.held, client),
      waiting: List.keydelete(state.waiting, client, 0)
    })
  end

  # Each waiter, in order, that no holder and no waiter still ahead of it overlaps.
  defp let_in(state) do
    {held, waiting} =
      Enum.reduce(state.waiting, {state.held, []}, fn {client, folder}, {held, ahead} ->
        if free?(folder, Map.values(held), ahead),
          do: {Map.put(held, client, folder), ahead},
          else: {held, ahead ++ [{client, folder}]}
      end)

    %{held: held, waiting: waiting}
  end

  defp free?(folder, held, waiting) do
    not Enum.any?(held, &overlap?(&1, folder)) and
      not Enum.any?(waiting, &overlap?(elem(&1, 1), folder))
  end

  # The folders as the tree they are on disk, "link" being "a": each with the
  # folders that hold it.
  defp overlap?(a, b) when :repo in [a, b], do: a == b
  defp overlap?(a, b), do: same(a) in up(b) or same(b) in up(a)
  defp same(:link), do: :a
  defp same(folder), do: folder

  defp up(folder),
    do:
      Map.fetch!(
        %{root: [:root], a: [:a, :root], ab: [:ab, :a, :root], c: [:c, :root]},
        same(folder)
      )

  def postcondition(state, call, {seen, held}) do
    expected = next_state(state, nil, call)
    real = Enum.map(Map.values(expected.held), &real/1)
    indexed = held |> Enum.filter(&is_binary/1) |> Enum.with_index()

    overlapping =
      for {a, i} <- indexed,
          {b, j} <- indexed,
          i != j,
          String.starts_with?(a <> "/", b <> "/"),
          do: {a, b}

    seen == :ok and Enum.sort(held) == Enum.sort(real) and overlapping == [] and
      Enum.count(held, &(&1 == real(:repo))) <= 1
  end

  defp real(:repo), do: {:repository, real(:a)}
  defp real(:root), do: Process.get(:dir)
  defp real(:link), do: real(:a)
  defp real(:a), do: Path.join(Process.get(:dir), "a")
  defp real(:ab), do: Path.join(Process.get(:dir), "a/b")
  defp real(:c), do: Path.join(Process.get(:dir), "c")

  # --- commands ---------------------------------------------------------------

  # A client asks for `folder` and holds it until told to let go. Returns once the
  # lease server has the ask, with what it holds then.
  def ask(client, folder) do
    test = self()
    path = path(folder)

    pid =
      spawn(fn ->
        WorkspaceLease.with_lease(path, fn ->
          send(test, {:holding, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    Process.put(:pids, Map.put(Process.get(:pids), client, pid))
    seen = received(&match?({:"$gen_call", {^pid, _}, {:acquire, _}}, &1))
    {seen, WorkspaceLease.held()}
  end

  # A holder that was let in lets go; it must have been told it holds the folder.
  def release(client) do
    pid = Process.get(:pids)[client]

    seen =
      receive do
        {:holding, ^pid} ->
          send(pid, :release)
          received(&match?({:"$gen_cast", {:release, _}}, &1))
      after
        5_000 -> :never_let_in
      end

    {seen, WorkspaceLease.held()}
  end

  # A holder or waiter dies; the server lets go of it when its monitor fires.
  def crash(client) do
    pid = Process.get(:pids)[client]
    Process.exit(pid, :kill)
    seen = received(&match?({:DOWN, _, :process, ^pid, _}, &1))
    {seen, WorkspaceLease.held()}
  end

  defp path(:link), do: Path.join(Process.get(:dir), "link")
  defp path(folder), do: real(folder)

  defp received(wanted) do
    lease = Process.get(:lease)

    receive do
      {:trace, ^lease, :receive, message} ->
        if wanted.(message), do: :ok, else: received(wanted)
    after
      5_000 -> :not_received
    end
  end
end
