defmodule HalC2.Steps.Threads.SidebarSettled do
  @moduledoc """
  Steps for the settled shelf of `features/threads/sidebar-list.feature` that the MC
  answers: a client that asks for a settled limit on its shell subscribe.

  The settled threads are sidebar rows put the way a stream server puts its own
  (`HalC2.Shell.put_row/2`), copies of one real thread's row: hundreds of real
  streams would only slow the scenario down without changing what the shell sends.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Projection.JS
  alias HalC2.Test.{Mc, WsClient}
  alias HalC2.Test.Mc.World

  # What the Qt clients would ask for: the shelf's first page.
  @limit 25

  step "{string} has {int} settled threads, one of them pinned and one snoozed",
       %{args: [project, count]} = context do
    context = context |> World.create_project(project) |> World.create_thread("Template", project)
    template = World.row(context, "Template")
    now = System.os_time(:millisecond)

    # "Settled 1" settled last; the pinned and snoozed ones are the two oldest.
    settled =
      for n <- 1..count do
        id = "th-settled-#{n}"

        row =
          Map.merge(template, %{
            "id" => id,
            "title" => "Settled #{n}",
            "settledOverride" => "settled",
            "settledAt" => JS.iso(now - n * 60_000),
            "pinnedAt" => if(n == count, do: JS.iso(now)),
            "snoozedUntil" => if(n == count - 1, do: JS.iso(now + 86_400_000))
          })

        HalC2.Shell.put_row(id, {"thread", row})
        id
      end

    :ok = HalC2.Shell.sync()

    Map.merge(context, %{
      settled: settled,
      settled_project: World.project(context, project).id,
      pinned: List.last(settled),
      snoozed: Enum.at(settled, -2)
    })
  end

  step "a client connects for the first time", context do
    client =
      context.mc
      |> Mc.connect()
      |> WsClient.send_json(%{
        "t" => "sub",
        "id" => 1,
        "shape" => %{"type" => "shell"},
        "settledLimit" => @limit
      })

    {frame, _client} = Mc.await(client, &(&1["t"] == "shell"))
    mc = Atom.to_string(node())

    Map.merge(context, %{
      sent: MapSet.new(for [^mc, id, "thread", _row] <- frame["rows"], do: id),
      sent_mc: Enum.find(frame["mcs"], &(&1["mc"] == mc))
    })
  end

  step "it is sent the {int} newest settled threads and the pinned and snoozed ones",
       %{args: [newest]} = context do
    expected = MapSet.new(Enum.take(context.settled, newest) ++ [context.pinned, context.snoozed])
    assert MapSet.intersection(context.sent, MapSet.new(context.settled)) == expected
    # Threads outside the shelf are sent as ever.
    assert World.thread_id(context, "Template") in context.sent
    context
  end

  step "it is told how many settled threads of {string} were left out", context do
    left_out = length(context.settled) - (@limit + 2)
    assert context.sent_mc["settledLeftOut"] == %{context.settled_project => left_out}
    context
  end
end
