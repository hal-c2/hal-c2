defmodule HalC2.ClusterProofTest do
  # Members gossiping their member table, between two or three MCs: casts in any order,
  # lost when the receiving cluster process is down, connections dropping, cluster
  # processes crashing and reloading their table, version changes and clocks that
  # disagree. prop/hal_c2/cluster_prop_test.exs runs the code as one MC; this explores
  # every interleaving between MCs up to the bounds.
  @names "names an MC or where it keeps its files; the model names MCs by id"
  @words "words for a refusal; no part of the table"
  @reads "reads the table; changes nothing"
  @off "an MC booted without distribution never clusters; the model's MCs all do"
  @address "which address and port reach a member; the model connects members by id"
  @task "Discovery's bookkeeping of the connection attempt it runs; connect models the attempt"

  use HalC2.Proof,
    model: "cluster.maude",
    module: "CLUSTER",
    check: "CLUSTER-PROPS",
    # Mixed releases add distinct metadata states; exhaustive searches take minutes.
    timeout: 900_000,
    code: [
      {:exports, HalC2.Cluster},
      {:messages, HalC2.Cluster},
      {:state, HalC2.Cluster},
      {:exports, HalC2.Cluster.Distribution},
      {:exports, HalC2.Cluster.Discovery},
      {:messages, HalC2.Cluster.Discovery},
      {:exports, HalC2.Cluster.Epmd}
    ],
    covers: %{
      "HalC2.Cluster.start_link/1" => "restart",
      "HalC2.Cluster.version_changed/0" => "version-changed",
      "HalC2.Cluster.peers/0" => "connect",
      "HalC2.Cluster.admit/1" => "admit",
      "HalC2.Cluster.remove/1" => "remove",
      "HalC2.Cluster.join/1" => ~w(admit merge),
      "HalC2.Cluster.merge/3" => ~w(merge mergeE),
      "HalC2.Cluster.stamp/1" => "stamp",
      "HalC2.Cluster.member?/1" => "member",
      "HalC2.Cluster.verify_peer/3" => "connect",
      "HalC2.Cluster handle_call :peers" => "connect",
      "HalC2.Cluster handle_call {:admit, _}" => "admit",
      "HalC2.Cluster handle_call {:joined, _, _, _}" => "merge",
      "HalC2.Cluster handle_call {:remove, _}" => "remove",
      "HalC2.Cluster handle_cast {:merge, _}" => "merge",
      "HalC2.Cluster handle_cast :version_changed" => ~w(version-changed protocol-changed),
      "HalC2.Cluster handle_info {:nodeup, _}" => "nodeup",
      "HalC2.Cluster handle_info :gossip" => "gossip",
      "HalC2.Cluster.Distribution.start/2" => "restart",
      "HalC2.Cluster.Distribution.connected/0" => ~w(broadcast gossip cut),
      "HalC2.Cluster.Distribution.disconnect/1" => "cut",
      "HalC2.Cluster.Distribution.send/2" => "send",
      "HalC2.Cluster.Distribution.version_changed/1" => ~w(version-changed protocol-changed),
      "HalC2.Cluster.Discovery.poll/0" => "connect",
      "HalC2.Cluster.Discovery.connect/3" => "connect",
      "HalC2.Cluster.Discovery handle_info :poll" => "connect",
      "HalC2.Cluster state :members" => "mc"
    },
    abstracts: %{
      "HalC2.Cluster state :dir" => @names,
      "HalC2.Cluster state :id" => @names,
      "HalC2.Cluster state :fingerprint" => @names,
      "HalC2.Cluster state :off" => @off,
      "HalC2.Cluster state :gossip" =>
        "the timer of the next gossip, kept so an update in place starts one; the model gossips at any time",
      "HalC2.Cluster state :transport" =>
        "which module carries the casts, a fake in tests; the model's links and channels are the real one",
      "HalC2.Cluster.dist_port/0" => @names,
      "HalC2.Cluster.protocol/0" =>
        "epoch models the wire compatibility independently of release versions",
      "HalC2.Cluster.dir/1" => @names,
      "HalC2.Cluster.host/1" => @names,
      "HalC2.Cluster.mc_name/1" => @names,
      "HalC2.Cluster.fingerprint/1" => @names,
      "HalC2.Cluster.status/0" => @reads,
      "HalC2.Cluster handle_call :status" => @reads,
      "HalC2.Cluster handle_call :fingerprint" => @reads,
      "HalC2.Cluster handle_call :entry" =>
        "describes this MC to an inviter, whose admit takes it; changes nothing",
      "HalC2.Cluster.invite/1" => "makes a pairing link; changes no table",
      "HalC2.Cluster.describe/1" => @words,
      "HalC2.Cluster.reason/1" => @words,
      "HalC2.Cluster.detail/1" => @words,
      "HalC2.Cluster handle_call _" => @off,
      "HalC2.Cluster handle_cast _" => @off,
      "HalC2.Cluster handle_info {:nodedown, _}" =>
        "does nothing; the connection dropping is disconnect",
      "HalC2.Cluster.Discovery.start_link/1" => "starts the process connect stands for",
      "HalC2.Cluster.Discovery.behaviour_info/1" => @address,
      "HalC2.Cluster.Discovery.candidates/3" => @address,
      "HalC2.Cluster.Discovery.resolve/1" => @address,
      "HalC2.Cluster.Discovery handle_info {_, _}" => @task,
      "HalC2.Cluster.Discovery handle_info {:DOWN, _, :process, _, _}" => @task,
      "HalC2.Cluster.Discovery handle_info {:EXIT, _, _}" => @task,
      "HalC2.Cluster.Epmd.start_link/0" => @address,
      "HalC2.Cluster.Epmd.register_node/2" => @address,
      "HalC2.Cluster.Epmd.register_node/3" => @address,
      "HalC2.Cluster.Epmd.listen_port_please/2" => @address,
      "HalC2.Cluster.Epmd.port_please/2" => @address,
      "HalC2.Cluster.Epmd.port_please/3" => @address,
      "HalC2.Cluster.Epmd.names/1" => @address,
      "HalC2.Cluster.Epmd.address_please/3" => @address,
      "HalC2.Cluster.Epmd.listen_port/0" => @address,
      "HalC2.Cluster.Epmd.put_listen_port/1" => @address,
      "HalC2.Cluster.Epmd.put/3" => @address,
      "HalC2.Cluster.Epmd.forget/1" => @address,
      "HalC2.Cluster.Epmd.lookup/1" => @address
    },
    environment: %{
      "crash" => "a cluster process dies, and its mailbox with it; its connections stay",
      "disconnect" => "a connection drops, and the casts in flight on it",
      "clock" => "time passes",
      "move" => "an MC that is down comes back at other addresses",
      "pick" => "draws entries for the laws of merge/3"
    },
    scenarios: %{
      "connections/cluster.feature" => [
        "A machine that joins one member reaches every member",
        "A member removed from the cluster can no longer connect",
        "A removed member's projects and threads leave the sidebar",
        "An MC that is not a member is turned away",
        "Members find each other again after restarting",
        "A member whose cluster process restarted learns of a removal it missed",
        "Members remain connected through a compatible release update",
        "Members on different compatible HAL-C2 releases connect",
        "An existing member on an incompatible cluster protocol cannot reconnect",
        "A hot protocol upgrade disconnects incompatible peers"
      ]
    }

  @fair ~w(merge nodeup restart connect gossip)

  test "merging entries does not depend on their order, grouping or repetition",
       %{proof: proof} do
    refute_reachable(proof, "laws", "broken", [])
  end

  # One search per start refutes all five: a removal no admission came after is never
  # undone, nor an admission after every removal; a change outranks everything its MC
  # had heard of; a non-member is never kept connected, nor sent the table.
  for init <- ["two(1, 1, 2, 1, 2, 1)", "three(1, 1, 1, 1, 0, 0)"] do
    test "no change is undone or misordered, and no non-member kept or told, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "unsafe", [])
    end
  end

  test "connected members' tables come to agree, and members on compatible releases connect",
       %{proof: proof} do
    assert_ltl(proof, "two(1, 1, 1, 1, 1, 1)", "<> [] (agreed /\\ meshed)", fair: @fair)
  end

  test "an incompatible protocol never connects", %{proof: proof} do
    refute_reachable(proof, "incompatible", "crossedEpoch", [])
  end

  test "a protocol upgrade drops incompatible connections", %{proof: proof} do
    refute_reachable(proof, "protocolUpgrade", "unsafe", [])
  end

  test "a removal reaches every member that ends up connected", %{proof: proof} do
    formula =
      "(<> [] near(a, b) -> [] (gone(a, c) -> <> gone(b, c))) /\\ " <>
        "(<> [] near(a, b) -> [] (gone(b, c) -> <> gone(a, c)))"

    assert_ltl(proof, "two(0, 1, 1, 0, 1, 0)", formula, fair: @fair)
  end
end
