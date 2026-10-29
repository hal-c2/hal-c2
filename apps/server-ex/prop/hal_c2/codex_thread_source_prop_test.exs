defmodule HalC2.CodexThreadSourcePropTest do
  use ExUnit.Case, async: true
  use PropCheck
  alias HalC2.Codex.ThreadRuntime

  property "ordinary source notifications preserve runtime state in any sequence" do
    forall sources <- list(oneof([binary(), exactly(nil), exactly(%{})])) do
      state = %{memory_threads: %{"existing" => true}, turn: %{id: "active"}}

      Enum.reduce(sources, state, fn source, current ->
        {:noreply, next} =
          ThreadRuntime.handle_info(
            {:json_rpc, self(),
             {:notification, "thread/started",
              %{"thread" => %{"id" => "ordinary", "source" => source}}}},
            current
          )

        next
      end) == state
    end
  end
end
