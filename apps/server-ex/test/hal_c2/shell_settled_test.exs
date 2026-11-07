defmodule HalC2.ShellSettledTest do
  # Uses the MC-wide named Store and Shell processes.
  use ExUnit.Case, async: false

  alias HalC2.{Shell, Store}
  alias HalC2.Shell.Settled

  @moduletag :tmp_dir

  @now 1_800_000_000_000

  defmodule QuietWire do
    @moduledoc false
    def connected, do: []
    def cast(_peer, _message), do: :ok
  end

  defp iso(ms), do: HalC2.Projection.JS.iso(ms)

  # A settled thread of `project` that settled `age` minutes before `@now`.
  defp settled(id, project, age, fields \\ %{}) do
    row =
      Map.merge(
        %{
          "id" => id,
          "projectId" => project,
          "settledOverride" => "settled",
          "settledAt" => iso(@now - age * 60_000)
        },
        fields
      )

    {id, {"thread", row}}
  end

  defp ids(rows), do: rows |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  describe "trim/3" do
    test "keeps each project's newest settled threads and counts the rest" do
      rows =
        for(n <- 1..5, do: settled("a#{n}", "shop", n)) ++
          for(n <- 1..3, do: settled("b#{n}", "docs", n)) ++
          [
            {"shop", {"project", %{"id" => "shop"}}},
            {"live", {"thread", %{"projectId" => "shop"}}}
          ]

      {kept, left_out} = Settled.trim(rows, 2, @now)

      assert ids(kept) == ~w(a1 a2 b1 b2 live shop)
      assert left_out == %{"shop" => 3, "docs" => 1}
    end

    test "keeps older settled threads that are pinned or still snoozed" do
      rows = [
        settled("new", "shop", 1),
        settled("pinned", "shop", 2, %{"pinnedAt" => iso(@now)}),
        settled("snoozed", "shop", 3, %{"snoozedUntil" => iso(@now + 60_000)}),
        settled("woke", "shop", 4, %{"snoozedUntil" => iso(@now - 60_000)})
      ]

      {kept, left_out} = Settled.trim(rows, 1, @now)
      assert ids(kept) == ~w(new pinned snoozed)
      assert left_out == %{"shop" => 1}
    end

    test "leaves rows outside the shelf alone, and a project under the limit whole" do
      rows = [
        settled("one", "shop", 1),
        settled("archived", "shop", 2, %{"archivedAt" => iso(@now)}),
        settled("deleted", "shop", 3, %{"deletedAt" => iso(@now)}),
        settled("agent", "shop", 4, %{"lineage" => %{"relationshipToParent" => "subagent"}}),
        settled("loose", nil, 5)
      ]

      assert Settled.trim(rows, 1, @now) == {rows, %{}}
    end

    test "settledAt ties go by id, and undated threads count as the oldest" do
      rows = [
        settled("b", "shop", 1),
        settled("a", "shop", 1),
        settled("undated", "shop", 0, %{"settledAt" => nil})
      ]

      assert {[{"b", _}], %{"shop" => 2}} = Settled.trim(rows, 1, @now)
    end
  end

  describe "the shell" do
    setup %{tmp_dir: dir} do
      Application.put_env(:hal_c2, :shell_transport, QuietWire)
      on_exit(fn -> Application.delete_env(:hal_c2, :shell_transport) end)
      start_supervised!({Store, path: Path.join(dir, "hal-c2.sqlite")})
      start_supervised!(Shell)

      now = System.os_time(:millisecond)

      # Stored as a stream server stores its row, so a restarted shell reads them back.
      for n <- 1..4 do
        {id, kind_row} = settled("th-#{n}", "shop", n, %{"settledAt" => iso(now - n * 60_000)})
        {:ok, _} = Store.append([{:thread, id, [{"thread", id, %{"s" => %{"id" => id}}}]}])
        :ok = Store.put_shell(id, 1, kind_row)
        Shell.put_row(id, kind_row)
      end

      :ok = Shell.sync()
      :ok
    end

    defp sent(%{rows: rows}), do: rows |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    test "a client that asks for a limit is sent the newest settled threads and the count" do
      reply = Shell.subscribe(self(), %{}, settled_limit: 2)
      assert sent(reply) == ~w(th-1 th-2)
      assert [%{reset: true, settled_left_out: %{"shop" => 2}}] = reply.mcs
    end

    test "a client that does not ask is sent every row, and told nothing more" do
      reply = Shell.subscribe(self(), %{})
      assert sent(reply) == ~w(th-1 th-2 th-3 th-4)
      assert [mc] = reply.mcs
      refute Map.has_key?(mc, :settled_left_out)
    end

    test "a client resuming with a limit is sent what changed, a left-out row included" do
      %{mcs: [%{epoch: epoch, rev: rev}]} = Shell.subscribe(spawn(fn -> :ok end), %{})
      {id, {kind, row}} = settled("th-4", "shop", 4)
      Shell.put_row(id, {kind, Map.put(row, "title", "renamed")})
      :ok = Shell.sync()

      reply = Shell.subscribe(self(), %{Atom.to_string(node()) => {epoch, rev}}, settled_limit: 1)
      assert sent(reply) == ["th-4"]
      assert [%{reset: false} = mc] = reply.mcs
      refute Map.has_key?(mc, :settled_left_out)

      # Once subscribed, a change to a row it was never sent reaches it too.
      {id, {kind, row}} = settled("th-3", "shop", 3)
      Shell.put_row(id, {kind, Map.put(row, "title", "renamed")})
      assert_receive {:hal_c2_shell, {:rows, _, [{"th-3", _}], %{reset: false} = version}}
      refute Map.has_key?(version, :settled_left_out)
    end

    test "the rows a limited client is sent whole after a restart are trimmed again" do
      %{mcs: [%{epoch: before}]} = Shell.subscribe(self(), %{}, settled_limit: 3)

      :ok = Supervisor.terminate_child(HalC2.Shell.Supervisor, Shell)
      {:ok, _} = Supervisor.restart_child(HalC2.Shell.Supervisor, Shell)

      assert_receive {:hal_c2_shell, {:rows, _, rows, %{reset: true, epoch: epoch} = version}}
      assert epoch != before
      assert ids(rows) == ~w(th-1 th-2 th-3)
      assert version.settled_left_out == %{"shop" => 1}
    end
  end
end
