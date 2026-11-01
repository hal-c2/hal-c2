defmodule HalC2.SpaceScheduleTest do
  use ExUnit.Case, async: false

  alias HalC2.{ScheduledTasks, Space, Streams}
  alias HalC2.Space.{Pages, Schedule}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(Streams)
    start_supervised!(ScheduledTasks)

    {:ok, space} = Space.create("Work")
    {:ok, page} = Space.create_page(space["id"], "Status")
    cadence = %{"type" => "interval", "everyMs" => 7_200_000}
    {:ok, _} = Schedule.set(space["id"], page["id"], "Summarise", cadence)
    %{space: space["id"], page: page["id"], cadence: cadence}
  end

  test "a Space's stream that stops answering does not stop the scheduler", ctx do
    stream = Streams.ensure(Space.stream_id(ctx.space))
    :sys.suspend(stream)
    on_exit(fn -> if Process.alive?(stream), do: :sys.resume(stream) end)

    {:ok, _} =
      ScheduledTasks.put_page_task(%{
        "id" => "page:" <> ctx.page,
        "title" => "Page update",
        "page" => %{"spaceId" => ctx.space, "pageId" => ctx.page},
        "prompt" => "Summarise more",
        "schedule" => ctx.cadence
      })

    assert :ok = ScheduledTasks.reconcile_pages(ctx.space)
    assert {:ok, %{"tasks" => []}} = ScheduledTasks.list()

    # What could not be shown is shown on the next change.
    :sys.resume(stream)
    assert :ok = ScheduledTasks.reconcile_pages(ctx.space)
    assert {:ok, %{page: page}} = Space.page(ctx.space, ctx.page)
    assert page["schedule"]["instruction"] == "Summarise more"
  end

  test "a restore the stream did not answer is settled on a later tick", ctx do
    {:ok, _} = Space.trash_page(ctx.space, ctx.page)
    assert [%{"nextRunAt" => nil}] = ScheduledTasks.page_tasks()

    # The restore commits, and only then does its reconcile find the stream stopped.
    {:ok, _} = Space.transact(ctx.space, &Pages.restore(&1, ctx.page))
    stream = Streams.ensure(Space.stream_id(ctx.space))
    :sys.suspend(stream)
    on_exit(fn -> if Process.alive?(stream), do: :sys.resume(stream) end)

    assert :ok = ScheduledTasks.reconcile_pages(ctx.space)
    assert [%{"nextRunAt" => nil}] = ScheduledTasks.page_tasks()

    :sys.resume(stream)
    send(ScheduledTasks, :tick)
    assert [%{"nextRunAt" => next}] = ScheduledTasks.page_tasks()
    assert next
  end

  test "a scheduler from before page tasks settled apart still ticks once updated", ctx do
    scheduler = Process.whereis(ScheduledTasks)
    :sys.replace_state(scheduler, &Map.drop(&1, [:unsettled, :silent]))

    # What `HalC2.Hot` does for a process whose module changed.
    :ok = :sys.suspend(scheduler)
    :ok = :sys.change_code(scheduler, ScheduledTasks, nil, :hot)
    :ok = :sys.resume(scheduler)

    send(ScheduledTasks, :tick)
    assert :ok = ScheduledTasks.reconcile_pages(ctx.space)
    assert Process.whereis(ScheduledTasks) == scheduler
  end

  describe "a Space's stream that does not answer" do
    setup ctx do
      Application.put_env(:hal_c2, :scheduled_tasks_pages_timeout_ms, 200)
      on_exit(fn -> Application.delete_env(:hal_c2, :scheduled_tasks_pages_timeout_ms) end)

      {:ok, other} = Space.create("Other")
      {:ok, page} = Space.create_page(other["id"], "Status")
      {:ok, _} = Schedule.set(other["id"], page["id"], "Summarise", ctx.cadence)

      stream = Streams.ensure(Space.stream_id(ctx.space))
      :sys.suspend(stream)
      on_exit(fn -> if Process.alive?(stream), do: :sys.resume(stream) end)

      %{other: other["id"], other_page: page["id"], stream: stream}
    end

    test "has what it did not take written by a later tick", ctx do
      {:ok, _} =
        ScheduledTasks.put_page_task(%{
          "id" => "page:" <> ctx.page,
          "title" => "Page update",
          "page" => %{"spaceId" => ctx.space, "pageId" => ctx.page},
          "prompt" => "Summarise more",
          "schedule" => ctx.cadence
        })

      # A stream that stops loses the write it never read, so only the tick can bring it.
      ref = Process.monitor(ctx.stream)
      Process.exit(ctx.stream, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}

      send(ScheduledTasks, :tick)
      assert [_, _] = ScheduledTasks.page_tasks()

      assert {:ok, %{page: page}} = Space.page(ctx.space, ctx.page)
      assert page["schedule"]["instruction"] == "Summarise more"
    end

    test "is waited on once, not by every change until the next tick", ctx do
      {:ok, _} =
        ScheduledTasks.put_page_task(%{
          "id" => "page:" <> ctx.page,
          "title" => "Page update",
          "page" => %{"spaceId" => ctx.space, "pageId" => ctx.page},
          "prompt" => "Summarise more",
          "schedule" => ctx.cadence
        })

      # Waiting on the stopped stream again would outlast this call's five seconds.
      Application.put_env(:hal_c2, :scheduled_tasks_pages_timeout_ms, 60_000)
      {:ok, _} = Schedule.set(ctx.other, ctx.other_page, "Other summary", ctx.cadence)
      assert {:ok, %{page: other}} = Space.page(ctx.other, ctx.other_page)
      assert other["schedule"]["instruction"] == "Other summary"

      Application.put_env(:hal_c2, :scheduled_tasks_pages_timeout_ms, 200)
      :sys.resume(ctx.stream)
      send(ScheduledTasks, :tick)
      assert [_, _] = ScheduledTasks.page_tasks()

      assert {:ok, %{page: page}} = Space.page(ctx.space, ctx.page)
      assert page["schedule"]["instruction"] == "Summarise more"
    end

    test "does not keep another Space's task from settling at boot", ctx do
      stop_supervised!(ScheduledTasks)
      {:ok, _} = Space.transact(ctx.other, &Pages.trash(&1, ctx.other_page))
      start_supervised!(ScheduledTasks)

      tasks = Map.new(ScheduledTasks.page_tasks(), &{&1["page"]["pageId"], &1})
      assert tasks[ctx.other_page]["held"] == true
      assert tasks[ctx.page]["nextRunAt"]
    end

    test "does not keep another Space's page from showing a change", ctx do
      for {space, page} <- [{ctx.space, ctx.page}, {ctx.other, ctx.other_page}] do
        {:ok, _} =
          ScheduledTasks.put_page_task(%{
            "id" => "page:" <> page,
            "title" => "Page update",
            "page" => %{"spaceId" => space, "pageId" => page},
            "prompt" => "Summarise more",
            "schedule" => ctx.cadence
          })
      end

      assert {:ok, %{page: page}} = Space.page(ctx.other, ctx.other_page)
      assert page["schedule"]["instruction"] == "Summarise more"
    end
  end
end
