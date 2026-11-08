defmodule HalC2.UnrecordedChildStreamTest do
  # hal-c2#1285 (review of #1398): a full disk refuses a native subagent's thread too,
  # and that write, while the runtime ran dry, threw away the whole message: the stop
  # of the turn the store failed, or the turn's own end, which then never reached
  # TurnWatch, so the run stayed running after the store recovered.
  use ExUnit.Case, async: false

  alias HalC2.Orchestration
  alias HalC2.Orchestration.Unrecorded
  alias HalC2.Test.Mc

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Mc.start(Path.join(dir, "mc"))
    on_exit(fn -> Application.delete_env(:hal_c2, :store_hook) end)
    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse, [~w(t child)]})
    :ok
  end

  # The store refuses every change to the streams named, as a full disk does.
  def refuse(ids, :append_change, id) do
    if id in ids and self() == Process.whereis(HalC2.Store), do: raise("the disk is full")
    :ok
  end

  def refuse(_ids, _stage, _id), do: :ok

  # The runtime's stop, which `Unrecorded` calls for the turn the store failed.
  def handle_call(:interrupt, _from, state) do
    send(self(), :stopped)
    {:reply, :ok, state}
  end

  defp write(stream) do
    HalC2.Streams.transact(stream, :thread, fn state ->
      {[Orchestration.upsert(state, "message", "m1", &Map.put(&1 || %{}, "text", "hi"))], :ok}
    end)
  end

  test "a refused write to a subagent's thread still lets the runtime stop the failed turn" do
    handle = fn :event, state ->
      :ok = write("t")
      :ok = write("child")
      send(self(), :handled)
      {:noreply, state}
    end

    state = %{thread_id: "t", turn: %{ids: %{run: "run-1"}}}

    assert {:noreply, %{unrecorded: %{run: "run-1"}}} =
             Unrecorded.handle_info(__MODULE__, :event, state, handle)

    assert_received :handled
    assert_received :stopped
  end

  test "a refused write to another stream outside a dry turn still raises" do
    assert_raise HalC2.Streams.Unrecorded, fn -> write("child") end
  end
end
