defmodule HalC2.WorkspaceLeaseTest do
  use ExUnit.Case, async: false

  alias HalC2.WorkspaceLease

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, dir} = HalC2.Paths.real(dir)
    for sub <- ["a/b", "c"], do: File.mkdir_p!(Path.join(dir, sub))
    lease = start_supervised!(WorkspaceLease)
    # What the server received is the receipt that an ask arrived, so asks queue in
    # the order the test makes them.
    :erlang.trace(lease, true, [:receive])
    on_exit(fn -> if Process.alive?(lease), do: :erlang.trace(lease, false, [:receive]) end)
    %{dir: dir, lease: lease}
  end

  test "a folder inside a held one waits for it; one beside it does not", %{dir: dir} do
    holder = hold(Path.join(dir, "a"))
    inner = ask(Path.join(dir, "a/b"))
    beside = hold(Path.join(dir, "c"))

    refute_holding(inner, Path.join(dir, "a/b"))
    assert Enum.sort(WorkspaceLease.held()) == [Path.join(dir, "a"), Path.join(dir, "c")]

    let_go(holder)
    assert_holding(inner)
    let_go(inner)
    let_go(beside)
  end

  test "waiters on one folder go in the order they asked, through links too", %{dir: dir} do
    File.ln_s!(Path.join(dir, "a"), Path.join(dir, "link"))
    holder = hold(Path.join(dir, "a"))
    first = ask(dir)
    second = ask(Path.join(dir, "link/b"))

    let_go(holder)
    assert_holding(first)
    refute_holding(second, Path.join(dir, "a/b"))
    let_go(first)
    assert_holding(second)
    assert WorkspaceLease.held() == [Path.join(dir, "a/b")]
    let_go(second)
  end

  test "a holder that dies lets go", %{dir: dir} do
    holder = hold(Path.join(dir, "a"))
    waiter = ask(Path.join(dir, "a"))
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert_holding(waiter)
    let_go(waiter)
  end

  # A process inside `with_lease/2` for `path` until let go, once the server has its ask.
  defp ask(path) do
    test = self()

    pid =
      spawn(fn ->
        WorkspaceLease.with_lease(path, fn ->
          send(test, {:holding, self()})

          receive do
            :release -> send(test, {:released, self()})
          end
        end)
      end)

    lease = Process.whereis(WorkspaceLease)
    assert_receive {:trace, ^lease, :receive, {:"$gen_call", {^pid, _}, {:acquire, _}}}, 5_000
    pid
  end

  defp hold(path) do
    pid = ask(path)
    assert_holding(pid)
    pid
  end

  defp assert_holding(pid), do: assert_receive({:holding, ^pid}, 5_000)

  # The server has the ask (`ask/1`), so `held/0`, answered after it, would list the
  # folder had it let the waiter in.
  defp refute_holding(pid, path) do
    refute path in WorkspaceLease.held()
    refute_received {:holding, ^pid}
  end

  defp let_go(pid) do
    send(pid, :release)
    assert_receive {:released, ^pid}, 5_000
  end
end
