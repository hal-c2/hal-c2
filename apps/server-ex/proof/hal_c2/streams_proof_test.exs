defmodule HalC2.StreamsProofTest do
  # One stream's server against two callers that go through ensure/1 and then call it
  # (commit, transact, subscribe), the subscriber that monitors it, a registry that
  # lags a process's death, and a server that idles out, crashes, or takes time in
  # terminate/2 with its name still taken. prop/hal_c2/streams_prop_test.exs waits for
  # a stream to be down before its next command; this explores every interleaving.
  @read "a read of the stream, or a page of it; the stream's lifetime is the same as for a commit"
  @sidebar "writes the sidebar row; terminate/2 flushes it, which the stopping state stands for"
  @ignored "ignored: a relay's or a linked process's normal exit changes nothing"

  use HalC2.Proof,
    model: "streams.maude",
    module: "STREAMS",
    check: "STREAMS-PROPS",
    code: [
      {:exports, HalC2.Streams},
      {:exports, HalC2.Streams.Server},
      {:messages, HalC2.Streams.Server},
      {:state, HalC2.Streams.Server},
      {:calls, HalC2.Streams, :hook}
    ],
    covers: %{
      "HalC2.Streams.ensure/1" => ~w(ensure lookup alive not-alive start-child already-started),
      "HalC2.Streams.with_server/3" => ~w(call call-noproc retry give-up),
      "HalC2.Streams hook(:ensured)" => "call",
      "HalC2.Streams.commit/3" => "commit",
      "HalC2.Streams.transact/3" => ~w(transact transact-nothing transact-raises),
      "HalC2.Streams.subscribe/3" => "subscribe",
      "HalC2.Streams.subscribe/4" => "subscribe",
      "HalC2.Streams.follow/4" => "subscribe",
      "HalC2.Streams.watch/2" => "subscribe",
      "HalC2.Streams.unsubscribe/2" => "unsubscribe",
      "HalC2.Streams.Server.commit/3" => "commit",
      "HalC2.Streams.Server.transact/3" => ~w(transact transact-nothing transact-raises),
      "HalC2.Streams.Server.subscribe/3" => "subscribe",
      "HalC2.Streams.Server.subscribe/4" => "subscribe",
      "HalC2.Streams.Server.follow/4" => "subscribe",
      "HalC2.Streams.Server.watch/2" => "subscribe",
      "HalC2.Streams.Server.unsubscribe/2" => "unsubscribe",
      "HalC2.Streams.Server handle_call {:subscribe, _, _, _}" => "subscribe",
      "HalC2.Streams.Server handle_call {:commit, _, _}" => "commit",
      "HalC2.Streams.Server handle_call {:transact, _, _}" =>
        ~w(transact transact-nothing transact-raises),
      "HalC2.Streams.Server handle_cast {:unsubscribe, _}" => "cast-unsubscribe",
      "HalC2.Streams.Server handle_info {:DOWN, _, :process, _, _}" => "monitor-down",
      "HalC2.Streams.Server handle_info :timeout" => "timeout",
      "HalC2.Streams.Server handle_info {:EXIT, _, _}" => "linked-exit",
      "HalC2.Streams.Server state :stream" => "durable",
      "HalC2.Streams.Server state :subscribers" => "srv"
    },
    abstracts: %{
      "HalC2.Streams.Server state :v" => "the version of the state, which no step changes",
      "HalC2.Streams.Server state :id" => "names the stream; the model has one",
      "HalC2.Streams.Server state :path" => "where the stream is stored; the model has the log",
      "HalC2.Streams.Server state :snapshot_seq" =>
        "when the next snapshot is due; a snapshot changes no event or subscriber",
      "HalC2.Streams.Server state :shell_scheduled" => @sidebar,
      "HalC2.Streams.Server state :relays" =>
        "the relays of subscribers on other MCs; stream_relay.maude models them",
      "HalC2.Streams.start_link/1" => "starts the supervisor tree; the model starts with it up",
      "HalC2.Streams.flush_shell/1" => "the same call as a commit that appends nothing",
      "HalC2.Streams.more/3" => @read,
      "HalC2.Streams.Server.more/3" => @read,
      "HalC2.Streams.Server.state/1" => @read,
      "HalC2.Streams.Server.flush_shell/1" => "the same call as a commit that appends nothing",
      "HalC2.Streams.Server.start_link/1" => "start-child, which starts the server and names it",
      "HalC2.Streams.Server.handle/1" => "names what a client's copy is a copy of",
      "HalC2.Streams.Server.idle_stop/0" =>
        "the length of the idle timeout, which the model leaves to the timeout rule",
      "HalC2.Streams.Server handle_call {:commit, _, []}" =>
        "commits nothing, so nothing changes",
      "HalC2.Streams.Server handle_call {:more, _, _}" => @read,
      "HalC2.Streams.Server handle_call :state" => @read,
      "HalC2.Streams.Server handle_call :flush_shell" => @sidebar,
      "HalC2.Streams.Server handle_cast {:more, _, _}" => @read,
      "HalC2.Streams.Server handle_info :shell" => @sidebar,
      "HalC2.Streams.Server handle_info {:EXIT, _, :normal}" => @ignored
    },
    environment: %{
      "subscriber-dies" => "a subscriber's process dies and its server is sent a DOWN",
      "finish" => "terminate/2 returns, the process exits and the calls queued for it exit",
      "call-exit" =>
        "a call to a process that exits, queued or not yet read, exits with its reason",
      "server-down" => "a monitor tells its process the monitored one is gone",
      "kill" => "a server is killed in the middle of a step, terminate/2 never run",
      "crash-in-commit" => "a commit appends and fails before it answers or sends",
      "deregister" => "the Registry drops the entry of a process it saw die"
    },
    scenarios: %{
      "mc/platform/websocket-protocol.feature" => [
        "A thread stream with no subscribers stops after five minutes",
        "A write that reaches a stream as it stops still lands"
      ]
    }

  # Faults and the stop of an idle stream; the code's own steps may not stop.
  @faults ~w(timeout linked-exit kill subscriber-dies crash-in-commit)
  @fair ~w(ensure lookup alive not-alive start-child already-started call call-noproc retry
           give-up subscribe commit transact transact-nothing transact-raises cast-unsubscribe
           monitor-down unsubscribe server-down finish call-exit deregister)

  # A caller tries three times, so a call survives two stops in its way.
  for init <- ["warm(3, 2, 0, 0)", "cold(3, 1, 1, 0)"] do
    test "a commit is answered with the event stored and sent, or exits with nothing stored, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "badA", [])
    end

    test "a stream never times out with subscribers, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "badB", [])
    end

    test "only one server runs per stream, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "badC", [])
    end

    test "a call never exits for a server that stopped, when it has a try to spare, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "badD", [])
    end
  end

  for init <- ["warm(3, 1, 0, 0)", "warm(3, 0, 1, 0)"] do
    test "every call gets an answer or an exit, from #{init}", %{proof: proof} do
      refute_deadlock(proof, unquote(init), "settled", besides: @faults)
    end
  end

  for init <- ["few(3, 1, 0)", "few(3, 0, 1)"] do
    test "a subscription becomes live or ends, while the code takes its steps, from #{init}",
         %{proof: proof} do
      formula = "[] (subscribing(3) -> <> ~ subscribing(3))"
      assert_ltl(proof, unquote(init), formula, fair: @fair)
    end
  end

  test "a subscriber whose server went gets its DOWN, while the code takes its steps", %{
    proof: proof
  } do
    formula = "[] (orphaned(3) -> <> ~ orphaned(3))"
    assert_ltl(proof, "few(3, 0, 1)", formula, fair: @fair)
  end
end
