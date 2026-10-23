defmodule HalC2.InterruptPinTest do
  # Every runtime refuses an interrupt pinned to a run other than the turn it
  # drives, before it reaches its provider (#403). Codex's whole path is in
  # `turn_lifecycle_test.exs`; the others are checked at the call itself, with
  # only the turn's ids in the state, so a clause that stopped matching first
  # would reach for the provider connection and fail here.
  use ExUnit.Case, async: true

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
  end
end
