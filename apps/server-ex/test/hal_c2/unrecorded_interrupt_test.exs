defmodule HalC2.UnrecordedInterruptTest do
  # hal-c2#1285 (Copilot on #1398): the stop `Unrecorded` starts for a turn the store
  # failed took the runtime's state as the third element of whatever its
  # `handle_call(:interrupt, ...)` returned, so a `{:noreply, state}` crashed the
  # runtime and a `{:stop, reason, reply, state}` left it with the reply as its state.
  use ExUnit.Case, async: false

  alias HalC2.Orchestration
  alias HalC2.Orchestration.Unrecorded
  alias HalC2.Test.Mc

  @moduletag :tmp_dir

  defmodule NoReply do
    def handle_call(:interrupt, _from, state), do: {:noreply, Map.put(state, :stopped, true)}
  end

  defmodule Stop do
    def handle_call(:interrupt, _from, state),
      do: {:stop, :normal, :ok, Map.put(state, :stopped, true)}
  end

  setup %{tmp_dir: dir} do
    Mc.start(Path.join(dir, "mc"))
    on_exit(fn -> Application.delete_env(:hal_c2, :store_hook) end)
    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse, ["t"]})
    :ok
  end

  # The store refuses every change to the thread, as a full disk does.
  def refuse(id, :append_change, id) do
    if self() == Process.whereis(HalC2.Store), do: raise("the disk is full")
    :ok
  end

  def refuse(_id, _stage, _other), do: :ok

  defp handle(:event, state) do
    :ok =
      HalC2.Streams.transact("t", :thread, fn stream ->
        {[Orchestration.upsert(stream, "message", "m1", &Map.put(&1 || %{}, "text", "hi"))], :ok}
      end)

    {:noreply, state}
  end

  for module <- [NoReply, Stop] do
    test "a stop answered with #{inspect(module)}'s shape still stops the failed turn" do
      state = %{thread_id: "t", turn: %{ids: %{run: "run-1"}}}

      assert {:noreply, %{stopped: true, unrecorded: %{run: "run-1"}}} =
               Unrecorded.handle_info(unquote(module), :event, state, &handle/2)
    end
  end
end
