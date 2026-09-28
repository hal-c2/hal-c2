defmodule HalC2.ClusterMembersTest do
  use ExUnit.Case, async: true

  alias HalC2.Cluster

  defp entry(fields) do
    Map.merge(
      %{
        "fingerprint" => String.duplicate("a", 64),
        "label" => "box",
        "addresses" => ["10.0.0.2:4370"],
        "admittedAt" => 1,
        "removedAt" => nil,
        "updatedAt" => 1
      },
      Map.new(fields, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  test "a removal outlives an older admission and yields to a newer one" do
    admitted = %{"b" => entry(admittedAt: 1)}
    removed = %{"b" => entry(removedAt: 5, updatedAt: 5)}

    merged = Cluster.merge(admitted, removed, "a")
    refute Cluster.member?(merged["b"])
    # A member that was away and still has the old admission does not undo it.
    refute Cluster.member?(Cluster.merge(removed, admitted, "a")["b"])

    readmitted = Cluster.merge(merged, %{"b" => entry(admittedAt: 9, updatedAt: 9)}, "a")
    assert Cluster.member?(readmitted["b"])
  end

  test "the entry updated last carries the label and addresses" do
    ours = %{"b" => entry(updatedAt: 3)}
    theirs = %{"b" => entry(label: "laptop", addresses: ["10.0.0.9:4370"], updatedAt: 4)}

    assert %{"label" => "laptop", "addresses" => ["10.0.0.9:4370"]} =
             Cluster.merge(ours, theirs, "a")["b"]

    assert Cluster.merge(theirs, ours, "a") == Cluster.merge(ours, theirs, "a")
  end

  test "only a machine speaks for itself, and malformed entries are dropped" do
    own = %{"a" => entry(label: "me")}
    incoming = %{"a" => entry(removedAt: 9, updatedAt: 9), "c" => %{"fingerprint" => 1}}
    assert Cluster.merge(own, incoming, "a") == own
  end
end
