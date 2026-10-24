defmodule HalC2.DelegationPreambleTest do
  use ExUnit.Case, async: true

  alias HalC2.Orchestration.Delegation

  test "names the parent thread by title on one line" do
    preamble = Delegation.preamble(%{"id" => "t1", "title" => "Fix \"it\"\n now"})
    assert preamble =~ ~s(delegated by the thread "Fix \\"it\\" now". )
    assert String.starts_with?(preamble, "You are a HAL-C2 worker delegated by ")
    assert String.ends_with?(preamble, "\n\nTask:\n")
  end

  test "falls back to the thread id for a missing or blank title" do
    for title <- [nil, "", "  \n "] do
      assert Delegation.preamble(%{"id" => "t1", "title" => title}) =~
               "delegated by the thread t1. "
    end
  end
end
