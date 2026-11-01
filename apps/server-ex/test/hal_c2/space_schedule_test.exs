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
end
