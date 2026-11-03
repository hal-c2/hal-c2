defmodule HalC2.PullRequestBranchesTest do
  use ExUnit.Case, async: false

  alias HalC2.PullRequests.Branches

  test "a read under way when its checkout is forgotten answers its callers but is not kept" do
    test = self()

    fetch = fn _cwd, _branch ->
      send(test, {:fetching, self()})

      receive do
        {:answer, answer} -> answer
      end
    end

    start_supervised!({Branches, fetch: fetch})
    reader = Task.async(fn -> Branches.lookup("/a", "x") end)
    assert_receive {:fetching, first}
    :ok = Branches.forget("/a")
    send(first, {:answer, {:ok, %{"number" => 1, "state" => "merged"}}})
    assert {{:ok, %{"number" => 1}}, true} = Task.await(reader)

    reader = Task.async(fn -> Branches.lookup("/a", "x") end)
    assert_receive {:fetching, second}
    send(second, {:answer, {:ok, nil}})
    assert {{:ok, nil}, true} = Task.await(reader)
  end
end
