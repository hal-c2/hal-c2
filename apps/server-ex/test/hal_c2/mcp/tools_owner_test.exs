defmodule HalC2.Mcp.ToolsOwnerTest do
  # What an agent hears when the MC a thread moved to fails the call: an error
  # that says why, never a failed request.
  use ExUnit.Case, async: true

  alias HalC2.Mcp.Tools

  defmodule Owner do
    def fails, do: raise(ArgumentError, "no such run")
    def exits, do: exit(:shutdown)
    def answers, do: {:ok, %{"sent" => true}}
  end

  defp on_owner(fun, args \\ []), do: Tools.on_mc(Atom.to_string(node()), Owner, fun, args, 5_000)

  test "an answer from the other MC comes back as it is" do
    assert on_owner(:answers) == {:ok, %{"sent" => true}}
  end

  test "an MC running code without the call says it needs an update" do
    assert {:error, "thread_owner_outdated", message} = on_owner(:added_later)
    assert message =~ "older HAL-C2 code"
  end

  test "a raise or an exit on the other MC is reported with its reason" do
    assert {:error, "thread_owner_failed", raised} = on_owner(:fails)
    assert raised =~ "no such run"
    assert {:error, "thread_owner_failed", exited} = on_owner(:exits)
    assert exited =~ "shutdown"
  end

  test "an MC that cannot be reached is reported as unreachable" do
    assert {:error, "thread_unreachable", _} =
             Tools.on_mc("nobody@nowhere", Owner, :answers, [], 1_000)
  end
end
