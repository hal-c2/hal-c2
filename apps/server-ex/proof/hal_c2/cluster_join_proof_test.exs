defmodule HalC2.ClusterJoinProofTest do
  # Every interleaving of the two-step join with two attacker actions: reads, drops,
  # replays, forged admissions, or a stand-in answer with the attacker's certificate.
  use HalC2.Proof,
    model: "cluster_join.maude",
    module: "CLUSTER-JOIN",
    code: [{:exports, HalC2.Cluster.Join}],
    covers: %{
      "HalC2.Cluster.Join.challenge/1" => "challenge",
      "HalC2.Cluster.Join.answer/3" => "answer",
      "HalC2.Cluster.Join.seal/8" => "seal",
      "HalC2.Cluster.Join.open/3" => "admit"
    },
    environment: %{
      "drop" => "the network drops a message",
      "replay" => "the network replays a message; Auth consumes the invite once",
      "read" => "the network reads a message; only clear-secret or clear-entry disclose one",
      "inject" => "the attacker injects an admission with an invalid invite proof",
      "stand-in" => "the attacker answers with its own certificate"
    },
    scenarios: %{
      "connections/cluster.feature" => [
        "A join proves it holds the invite without sending the invite's secret",
        "Someone who changes a join on the way cannot put their own machine in its place",
        "The inviter proves who it is before the joining machine describes itself"
      ]
    }

  test "no attacker certificate is admitted and the secret and entry stay unread",
       %{proof: proof} do
    refute_reachable(proof, "initial", "unsafe", [])
  end
end
