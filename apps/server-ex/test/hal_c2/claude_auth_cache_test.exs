defmodule HalC2.ClaudeAuthCacheTest do
  use ExUnit.Case, async: false

  alias HalC2.Claude.AuthCache

  setup do
    stop_owner()
    on_exit(&stop_owner/0)
  end

  # Regression: a service ahead of the cache in the MC's start order read Claude's
  # sign-in, which made the table's owner; the supervisor's own start then failed
  # with `already started` and the MC did not boot.
  test "the MC's supervisor takes over an owner made by an earlier read" do
    table = AuthCache.table()
    :ets.insert(table, {:key, :landed})
    owner = Process.whereis(AuthCache)

    assert {:ok, sup} = Supervisor.start_link([AuthCache], strategy: :one_for_one)
    assert [{AuthCache, ^owner, :worker, _}] = Supervisor.which_children(sup)
    assert :ets.lookup(table, :key) == [{:key, :landed}]

    Supervisor.stop(sup)
    refute Process.alive?(owner)
  end

  defp stop_owner do
    if pid = Process.whereis(AuthCache) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
    end
  end
end
