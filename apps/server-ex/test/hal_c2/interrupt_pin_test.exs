defmodule HalC2.InterruptPinTest do
  # Every runtime refuses an interrupt pinned to a run other than the turn it
  # drives, before it reaches its provider (#403), and between turns one pinned to
  # an earlier run than its latest turn's (#474). Codex's whole path is in
  # `turn_lifecycle_test.exs`, and the work left running between turns is stopped
  # through each runtime in `orchestration_test.exs`; here each is checked at the call
  # itself, with only the ids and the work its stop would reach in the state, so a
  # clause that stopped matching first would reach for the provider and fail.
  use ExUnit.Case

  # Between turns a runtime reads the thread's runs to order the pin against its
  # latest turn's (`HalC2.Orchestration.earlier_run?/3`).
  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    :ok
  end

  @runtimes [
    HalC2.Claude.ThreadRuntime,
    HalC2.Acp.ThreadRuntime,
    HalC2.Pi.ThreadRuntime,
    HalC2.Muse.ThreadRuntime,
    HalC2.Codex.ThreadRuntime
  ]

  for runtime <- @runtimes do
    test "#{inspect(runtime)} leaves a turn alone when the interrupt names another run" do
      state = %{turn: %{ids: %{run: "run:running"}}}

      assert {:reply, {:error, "no running turn"}, ^state} =
               unquote(runtime).handle_call({:interrupt, "run:earlier"}, self(), state)
    end

    # Pi and Muse stop nothing between turns, pinned or not; Claude, ACP and Codex
    # would end the work below (and Claude its session, ACP its agent).
    test "#{inspect(runtime)} leaves what a later run left when the interrupt names an earlier one" do
      thread_id = "thread-#{System.unique_integer([:positive])}"

      {:ok, _} =
        HalC2.Streams.commit(
          thread_id,
          :thread,
          for(
            {id, ordinal} <- [{"run:earlier", 1}, {"run:later", 2}],
            do:
              {"run", id, %{"s" => %{"id" => id, "threadId" => thread_id, "ordinal" => ordinal}}}
          )
        )

      state = %{
        thread_id: thread_id,
        turn: nil,
        last_run: "run:later",
        last_ids: %{run: "run:later"},
        prompt: nil,
        session: spawn(fn -> receive do: (_ -> :ok) end),
        work: %{"tool-1" => %{sub: nil, item: %{id: "item-1"}, background: true}},
        background: %{"native-1" => %{item: %{id: "item-1", node: "node-1"}, process: nil}},
        subagents: %{"call-1" => %{background: true, done: false}},
        tasks: %{}
      }

      assert {:reply, {:error, "no running turn"}, ^state} =
               unquote(runtime).handle_call({:interrupt, "run:earlier"}, self(), state)
    end
  end
end
