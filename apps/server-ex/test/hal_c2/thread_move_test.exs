defmodule HalC2.ThreadMoveTest do
  # Regressions `prop/hal_c2/thread_move_prop_test.exs` found.
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.Entities
  alias HalC2.Test.{Machines, Mc}
  alias HalC2.Test.Mc.World

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  setup %{tmp_dir: dir} do
    {:ok, context: %{mc: Mc.start(dir), clients: %{}, projects: %{}, threads: %{}}}
  end

  # A restart of `HalC2.ThreadMove` alone used to empty incoming-moves and the archive
  # scratch, taking the files of moves still staging or sending.
  test "a restart of ThreadMove keeps the files of moves in flight" do
    Mc.ensure(HalC2.ThreadMove)
    staged = Path.join([HalC2.Paths.data_dir(), "incoming-moves", "move-1", "attachment"])
    bundle = Path.join([HalC2.Paths.cache_dir(), "thread-bundles", "bundle"])

    for path <- [staged, bundle] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "x")
    end

    stop_supervised!(HalC2.ThreadMove)
    Mc.ensure(HalC2.ThreadMove)

    assert File.exists?(staged)
    assert File.exists?(bundle)
  end

  # The process moving a thread used to leave it `moving`, read-only, when it died
  # mid-transfer while the destination stayed up.
  test "a thread whose mover dies mid-transfer is no longer moving", %{context: context} do
    {context, id, mover} = hold_move(context)
    assert World.thread(context, "Plan")["moving"]

    Process.exit(mover, :kill)

    World.await_stream(id, &(HalC2.StreamState.get(&1, "thread")[id]["moving"] == nil))
    refute_received {:moved, _}
  end

  # A rename while the thread was moving used to be taken, and lost on the destination.
  test "a moving thread refuses to be renamed", %{context: context} do
    {context, id, mover} = hold_move(context)

    assert {:error, "Plan is moving to desktop. Try again once it has arrived."} =
             HalC2.Orchestration.dispatch(%{
               "type" => "thread.metadata.update",
               "threadId" => id,
               "title" => "Renamed"
             })

    assert World.thread(context, "Plan")["title"] == "Plan"
    Process.exit(mover, :kill)
  end

  # Queue changes skipped the moving guard: a resume or cancel was taken on the source
  # after the move had read it, and lost on the destination.
  test "a moving thread refuses changes to its queue", %{context: context} do
    {_context, id, mover} = hold_move(context)

    for command <- [
          %{"type" => "queue.resume", "threadId" => id},
          %{"type" => "queued-run.cancel", "threadId" => id, "runId" => "run-1"}
        ] do
      assert {:error, "Plan is moving to desktop. Try again once it has arrived."} =
               HalC2.Orchestration.dispatch(command)
    end

    Process.exit(mover, :kill)
  end

  # A rename of the record a moved thread left behind used to be taken, and lost: the
  # thread lives on where it moved.
  test "a thread's forwarding record refuses to be renamed, but goes with its project", %{
    context: context
  } do
    root = Path.join(context.mc.home, "shop")
    File.mkdir_p!(root)
    context = World.create_project(context, "shop", %{"workspaceRoot" => root})
    context = World.create_thread(context, "Plan", "shop")
    id = World.thread_id(context, "Plan")
    moved = %{"mc" => "desktop@127.0.0.1", "label" => "desktop", "at" => Entities.now()}

    {:ok, _} =
      HalC2.Streams.commit(id, :thread, [{"thread", id, %{"s" => %{"movedTo" => moved}}}])

    rename = %{"type" => "thread.metadata.update", "threadId" => id, "title" => "Renamed"}
    assert {:error, "Plan has moved to desktop."} = HalC2.Orchestration.dispatch(rename)
    assert World.thread(context, "Plan")["title"] == "Plan"

    assert {:error, "Plan has moved to desktop."} =
             HalC2.Orchestration.dispatch(%{"type" => "queue.resume", "threadId" => id})

    assert {:ok, _} =
             HalC2.Orchestration.dispatch(%{"type" => "thread.delete", "threadId" => id})
  end

  # Settling a cut-off move waited on the destination inside ThreadMove, up to 30 seconds
  # for each thread: its calls timed out and its watchers and movers' exits queued.
  test "ThreadMove keeps answering while a settle waits on its destination", %{context: context} do
    {context, id, mover} = hold_move(context)

    Machines.on(context, "desktop", Application, :put_env, [
      :hal_c2,
      :thread_move_hook,
      {Machines, :hold_move, [self(), :arrived]}
    ])

    Process.exit(mover, :kill)
    assert_receive {:move_held, destination, :arrived, ^id}, 30_000

    # The settle is waiting on `destination`, which has not answered.
    assert %{} = :sys.get_state(HalC2.ThreadMove, 1_000)
    assert World.thread(context, "Plan")["moving"]

    send(destination, :release)
    World.await_stream(id, &(HalC2.StreamState.get(&1, "thread")[id]["moving"] == nil))
  end

  # Starts moving a thread "Plan" from "laptop" to "desktop" and holds it as it sends.
  defp hold_move(context) do
    context = Machines.cluster(context, "laptop", ["desktop"])
    Mc.ensure(HalC2.ThreadMove)
    root = Path.join(context.mc.home, "shop")
    File.mkdir_p!(root)
    context = World.create_project(context, "shop", %{"workspaceRoot" => root})
    peer_root = Path.join(Machines.home(context, "desktop"), "shop")
    Machines.on(context, "desktop", File, :mkdir_p!, [peer_root])
    Machines.on(context, "desktop", Machines, :create_project, ["shop", "shop", peer_root])
    context = World.create_thread(context, "Plan", "shop")
    id = World.thread_id(context, "Plan")

    Application.put_env(:hal_c2, :thread_move_hook, {Machines, :hold_move, [self(), :sending]})
    on_exit(fn -> Application.delete_env(:hal_c2, :thread_move_hook) end)
    test = self()
    spawn(fn -> send(test, {:moved, HalC2.ThreadMove.move(id, "desktop", confirmed: true)}) end)
    assert_receive {:move_held, mover, :sending, ^id}, 30_000
    {context, id, mover}
  end
end
