defmodule HalC2.SessionReleaseRegistryTest do
  # Every built-in runtime unregisters itself in `handle_call(:release)` before it
  # answers, so "released" implies "gone from its registry" without racing the
  # Registry's own asynchronous cleanup of a dead pid. That line is copy-pasted in
  # five runtimes; this pins it per runtime, so dropping it (or unregistering the
  # wrong registry) in one of them fails here even though no property model runs
  # that provider.
  use ExUnit.Case, async: false

  @runtimes [
    {HalC2.Codex.ThreadRuntime, HalC2.Codex.Registry},
    {HalC2.Claude.ThreadRuntime, HalC2.Claude.Registry},
    {HalC2.Acp.ThreadRuntime, HalC2.Acp.Registry},
    {HalC2.Pi.ThreadRuntime, HalC2.Pi.Registry},
    {HalC2.Muse.ThreadRuntime, HalC2.Muse.Registry}
  ]

  setup do
    for {_runtime, registry} <- @runtimes do
      start_supervised!(
        Supervisor.child_spec({Registry, keys: :unique, name: registry}, id: registry)
      )
    end

    :ok
  end

  for {runtime, registry} <- @runtimes do
    test "a released #{inspect(runtime)} session is gone from #{inspect(registry)} when the release returns" do
      runtime = unquote(runtime)
      registry = unquote(registry)

      pid =
        start_supervised!(Supervisor.child_spec({runtime, "t1"}, id: {runtime, "t1"}))

      assert [{^pid, _}] = Registry.lookup(registry, "t1")

      # With the Registry's partitions suspended, its own cleanup of the dead pid
      # cannot run (lookups read its tables directly), so only the unregister in
      # `handle_call(:release)` can make the lookup below empty.
      partitions =
        for {_id, child, :worker, _} <-
              Supervisor.which_children(Process.whereis(registry)),
            is_pid(child),
            do: child

      # No partitions suspended would leave the assertion racing the Registry's
      # own cleanup, no longer pinning the unregister: fail loudly instead if
      # a Registry restructure ever stops reporting worker partitions.
      assert partitions != []
      Enum.each(partitions, &:sys.suspend/1)

      try do
        assert :ok = GenServer.call(pid, :release)
        assert Registry.lookup(registry, "t1") == []
      after
        Enum.each(partitions, &:sys.resume/1)
      end
    end
  end
end
