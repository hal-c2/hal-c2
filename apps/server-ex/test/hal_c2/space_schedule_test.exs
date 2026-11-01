defmodule HalC2.SpaceScheduleTest do
  use ExUnit.Case, async: false

  alias HalC2.{ScheduledTasks, Space, Streams}
  alias HalC2.Space.Schedule

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
end
