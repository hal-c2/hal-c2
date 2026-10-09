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

  # A settle asked the destination whether it held the thread, not whether the move
  # had arrived. "desktop" took "Plan" and began moving it back before "laptop" had let
  # go; desktop's settle heard "laptop" holds it and let go, and so did "laptop".
  # Found by proof/hal_c2/thread_move_proof_test.exs.
  test "a move back settled before the first move let go keeps the thread", %{context: context} do
    {context, id, mover} = hold_move(context, :accepted)
    test = self()

    Machines.on(context, "desktop", Application, :put_env, [
      :hal_c2,
      :thread_move_hook,
      {Machines, :hold_move, [test, :sending]}
    ])

    spawn(fn ->
      back =
        Machines.on(context, "desktop", HalC2.ThreadMove, :move, [id, "laptop", [confirmed: true]])

      send(test, {:moved_back, back})
    end)

    assert_receive {:move_held, back, :sending, ^id}, 30_000
    Machines.on(context, "desktop", HalC2.ThreadMove, :settle, [id])

    send(mover, :release)
    assert_receive {:moved, {:ok, %{"status" => "moved"}}}, 30_000
    send(back, :release)
    assert_receive {:moved_back, _}, 30_000

    assert holders(context, id) == ["desktop"]
  end

  # The same question let a thread live on two machines. "desktop" took "Plan" and moved
  # it on to "server" before "laptop" let go; laptop's settle heard "desktop" does not
  # hold it and released it, and its mover died before it could let go.
  # Found by proof/hal_c2/thread_move_proof_test.exs.
  test "a move settled after the thread moved on is let go", %{context: context} do
    {context, id, mover} = hold_move(context, :accepted, ["desktop", "server"])

    assert {:ok, %{"status" => "moved"}} =
             Machines.on(context, "desktop", HalC2.ThreadMove, :move, [
               id,
               "server",
               [confirmed: true]
             ])

    HalC2.ThreadMove.settle(id)
    Process.exit(mover, :kill)

    assert holders(context, id) == ["server"]
  end

  # The mover let go of a thread without asking whether it was still in its move. A
  # settle on "laptop" had let go already, and "desktop" moved the thread back, so the
  # mover's let-go turned the thread that came back into a forwarding record.
  # Found by proof/hal_c2/thread_move_proof_test.exs.
  test "a thread that came back before its mover let go stays", %{context: context} do
    {context, id, mover} = hold_move(context, :accepted)
    HalC2.ThreadMove.settle(id)

    assert {:ok, %{"status" => "moved"}} =
             Machines.on(context, "desktop", HalC2.ThreadMove, :move, [
               id,
               "laptop",
               [confirmed: true]
             ])

    send(mover, :release)
    assert_receive {:moved, {:ok, %{"status" => "moved"}}}, 30_000

    assert holders(context, id) == ["laptop"]
  end

  # The mover checked the thread was still in its move, then stopped its session, with
  # nothing between: a settle let go meanwhile, "desktop" moved the thread back, and the
  # mover stopped the session of the thread that came back. One lets go at a time now.
  # Found by proof/hal_c2/thread_move_proof_test.exs.
  test "a settle waits for the mover letting go, so a thread that comes back keeps its session",
       %{context: context} do
    {context, id, mover} = hold_move(context, :letting_go)
    Application.delete_env(:hal_c2, :thread_move_hook)

    assert HalC2.ThreadMove.settle(id) == [id]

    assert {:error, _} =
             Machines.on(context, "desktop", HalC2.ThreadMove, :move, [
               id,
               "laptop",
               [confirmed: true]
             ])

    send(mover, :release)
    assert_receive {:moved, {:ok, %{"status" => "moved"}}}, 30_000

    assert HalC2.ThreadMove.settle(id) == []
    assert holders(context, id) == ["desktop"]
  end

  # The thread kept every move that ever brought it anywhere, and carried them all in
  # each archive. The last move from each machine is all `arrived?/2` needs.
  test "a thread moved back and forth keeps the last move from each machine", %{
    context: context
  } do
    {context, id, mover} = hold_move(context)
    Application.delete_env(:hal_c2, :thread_move_hook)
    send(mover, :release)
    assert_receive {:moved, {:ok, %{"status" => "moved"}}}, 30_000

    assert {:ok, %{"status" => "moved"}} =
             Machines.on(context, "desktop", HalC2.ThreadMove, :move, [
               id,
               "laptop",
               [confirmed: true]
             ])

    assert {:ok, %{"status" => "moved"}} =
             HalC2.ThreadMove.move(id, "desktop", confirmed: true)

    moves = Machines.on(context, "desktop", HalC2.ThreadArchive, :local_thread, [id])["moves"]
    assert map_size(moves) == 2
    assert holders(context, id) == ["desktop"]
  end

  # Starts moving a thread "Plan" from "laptop" to "desktop" and holds it at `stage`.
  # Each of `others` joins the cluster with a project "shop".
  defp hold_move(context, stage \\ :sending, others \\ ["desktop"]) do
    context = Machines.cluster(context, "laptop", others)
    Mc.ensure(HalC2.ThreadMove)
    root = Path.join(context.mc.home, "shop")
    File.mkdir_p!(root)
    context = World.create_project(context, "shop", %{"workspaceRoot" => root})

    for label <- others do
      peer_root = Path.join(Machines.home(context, label), "shop")
      Machines.on(context, label, File, :mkdir_p!, [peer_root])
      Machines.on(context, label, Machines, :create_project, ["shop", "shop", peer_root])
    end

    context = World.create_thread(context, "Plan", "shop")
    id = World.thread_id(context, "Plan")

    Application.put_env(:hal_c2, :thread_move_hook, {Machines, :hold_move, [self(), stage]})
    on_exit(fn -> Application.delete_env(:hal_c2, :thread_move_hook) end)
    test = self()
    spawn(fn -> send(test, {:moved, HalC2.ThreadMove.move(id, "desktop", confirmed: true)}) end)
    assert_receive {:move_held, mover, ^stage, ^id}, 30_000
    {context, id, mover}
  end

  # The machines that hold the thread, not a forwarding record.
  defp holders(context, id) do
    for {label, _} <- context.machines,
        thread = Machines.on(context, label, HalC2.ThreadArchive, :local_thread, [id]),
        thread["movedTo"] == nil,
        do: label
  end
end
