defmodule HalC2.CodexThreadSourceTest do
  use ExUnit.Case, async: true
  alias HalC2.Codex.ThreadRuntime

  test "ordinary thread sources preserve the active runtime" do
    state = %{memory_threads: %{}, turn: %{id: "active"}}

    for source <- ["vscode", "cli", nil, %{}, %{"subAgent" => "other"}] do
      message =
        {:json_rpc, self(),
         {:notification, "thread/started",
          %{"thread" => %{"id" => "ordinary", "source" => source}}}}

      assert {:noreply, ^state} = ThreadRuntime.handle_info(message, state)
    end
  end

  test "both memory source representations are tracked" do
    for fields <- [
          %{"threadSource" => "memory_consolidation", "source" => "vscode"},
          %{"source" => %{"subAgent" => "memory_consolidation"}}
        ] do
      message =
        {:json_rpc, self(),
         {:notification, "thread/started", %{"thread" => Map.put(fields, "id", "memory")}}}

      assert {:noreply, %{memory_threads: %{"memory" => true}}} =
               ThreadRuntime.handle_info(message, %{memory_threads: %{}})
    end
  end
end
