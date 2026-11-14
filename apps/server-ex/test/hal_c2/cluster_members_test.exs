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

  test "a removal outlives admissions that have not seen it and yields to an authorized rejoin" do
    admitted = %{"b" => entry(admittedAt: 1)}
    removed = %{"b" => entry(removedAt: 5, updatedAt: 5)}

    merged = Cluster.merge(admitted, removed, "a")
    refute Cluster.member?(merged["b"])
    # A member that was away and still has the old admission does not undo it.
    refute Cluster.member?(Cluster.merge(removed, admitted, "a")["b"])

    # A timestamp alone does not authorize a rejoin: the admission must carry the removal
    # it answers, as the local join path stamps it.
    stale = %{"b" => entry(admittedAt: 9, updatedAt: 9)}
    refute Cluster.member?(Cluster.merge(merged, stale, "a")["b"])

    readmission = %{"b" => entry(admittedAt: 9, removedAt: 5, updatedAt: 9)}
    readmitted = Cluster.merge(merged, readmission, "a")
    assert Cluster.member?(readmitted["b"])
    assert Cluster.merge(readmission, removed, "a") == readmitted
  end

  test "a removal after an admission outranks it when the admitting clock ran ahead" do
    ahead = System.os_time(:millisecond) + :timer.hours(1)
    admitted = %{"b" => entry(admittedAt: ahead, updatedAt: ahead)}

    removed_at = Cluster.stamp(admitted)
    assert removed_at > ahead
    removal = %{"b" => entry(admittedAt: ahead, removedAt: removed_at, updatedAt: removed_at)}

    refute Cluster.member?(Cluster.merge(admitted, removal, "a")["b"])

    # Admitting it again, after seeing the removal, outranks that in turn.
    readmitted_at = Cluster.stamp(removal)
    assert readmitted_at > removed_at

    readmission = %{
      "b" => entry(admittedAt: readmitted_at, removedAt: removed_at, updatedAt: readmitted_at)
    }

    assert Cluster.member?(Cluster.merge(removal, readmission, "a")["b"])
  end

  test "a partitioned member's far-future admission cannot undo a removal on heal" do
    # A removed R at 5 while partitioned from B. B still pins R and has its admission
    # from a clock far ahead; neither B nor R has seen A's removal.
    a = %{"r" => entry(admittedAt: 1, removedAt: 5, updatedAt: 5)}
    b = %{"r" => entry(admittedAt: 9, updatedAt: 9)}
    assert Cluster.member?(b["r"])

    healed = Cluster.merge(a, b, "a")
    refute Cluster.member?(healed["r"])
    assert Cluster.merge(b, a, "b") == healed

    # A fresh invite admitted after seeing the tombstone carries it, so the rejoin also
    # takes effect on B when its next gossip arrives.
    rejoin = %{"r" => entry(admittedAt: 10, removedAt: 5, updatedAt: 10)}
    readmitted = Cluster.merge(healed, rejoin, "a")
    assert Cluster.member?(readmitted["r"])
    assert Cluster.merge(b, readmitted, "b") == readmitted
  end

  test "the entry updated last carries the label and addresses" do
    ours = %{"b" => entry(updatedAt: 3)}
    theirs = %{"b" => entry(label: "laptop", addresses: ["10.0.0.9:4370"], updatedAt: 4)}

    assert %{"label" => "laptop", "addresses" => ["10.0.0.9:4370"]} =
             Cluster.merge(ours, theirs, "a")["b"]

    assert Cluster.merge(theirs, ours, "a") == Cluster.merge(ours, theirs, "a")
  end

  test "updates made in the same millisecond settle on one entry whichever side merges" do
    ours = %{"b" => entry(label: "box", updatedAt: 4)}
    theirs = %{"b" => entry(label: "laptop", addresses: ["10.0.0.9:4370"], updatedAt: 4)}

    assert Cluster.merge(ours, theirs, "a") == Cluster.merge(theirs, ours, "a")
  end

  test "updates made in the same millisecond settle on one entry in whatever order they arrive" do
    # Each merge raises admittedAt, which must not change which update wins the next one.
    updates = [
      entry(addresses: ["10.0.0.2:4370"], admittedAt: 1, label: "x", updatedAt: 5),
      entry(addresses: ["10.0.0.1:4370"], admittedAt: 3, label: "y", updatedAt: 5),
      entry(addresses: ["10.0.0.2:4370"], admittedAt: 2, label: "z", updatedAt: 5)
    ]

    results =
      for [first, second, third] <- permutations(updates) do
        Enum.reduce([first, second, third], %{}, &Cluster.merge(&2, %{"b" => &1}, "a"))
      end

    assert length(Enum.uniq(results)) == 1
  end

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  test "only a machine speaks for itself, and malformed entries are dropped" do
    own = %{"a" => entry(label: "me")}

    incoming = %{
      "a" => entry(label: "me", removedAt: 9, updatedAt: 9),
      "c" => %{"fingerprint" => 1}
    }

    merged = Cluster.merge(own, incoming, "a")
    assert Map.keys(merged) == ["a"]
    # Only the time of a copy that says the same is taken.
    assert merged["a"] == %{own["a"] | "updatedAt" => 9}
  end

  test "a machine's own changes outrank a member's later copy of its entry" do
    # The inviter's clock ran ahead when it admitted "a"; "a" then moved, stamped earlier.
    own = %{"a" => entry(addresses: ["10.0.0.9:4370"], updatedAt: 5)}
    copy = %{"a" => entry(addresses: ["10.0.0.2:4370"], admittedAt: 8, updatedAt: 8)}

    merged = Cluster.merge(own, copy, "a")
    assert merged["a"]["addresses"] == ["10.0.0.9:4370"]
    assert merged["a"]["admittedAt"] == 1
    # The member that holds the copy takes the move.
    assert Cluster.merge(copy, merged, "b")["a"]["addresses"] == ["10.0.0.9:4370"]
  end

  test "a member's later copy that says the same lends its time to the machine's next change" do
    # The inviter's clock ran an hour ahead when it re-admitted "a", as "a" was.
    ahead = System.os_time(:millisecond) + 3_600_000
    own = %{"a" => entry(updatedAt: 5)}
    copy = %{"a" => entry(admittedAt: ahead, updatedAt: ahead)}

    merged = Cluster.merge(own, copy, "a")
    assert merged["a"]["admittedAt"] == 1
    assert Cluster.stamp(merged) > ahead
  end
end
