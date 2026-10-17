defmodule HalC2.PreviewForwardProofTest do
  # A forwarded dev server between the client's MC and the thread's: the listener and
  # its grant, one connection's pipe pair with its chunks and acks, the tab closing, and
  # a fault (a killed listener or grant, a stopped MC, a parting) at any point.
  # prop/hal_c2/preview_forward_prop_test.exs runs the code on sequences of calls on one
  # MC; this explores every interleaving of both MCs' processes, for a few chunks a way.
  @outside "a call or message no interleaving between the MCs depends on"
  @fair ~w(granted refused unavailable accept ask ask-failed dial-call dial-gone answer
           answer-failed dial dial-refused tcp data ack closed down killed
           grant-closed grant-down listener-down)

  use HalC2.Proof,
    model: "preview_forward.maude",
    module: "PREVIEW-FORWARD",
    check: "PREVIEW-FORWARD-PROPS",
    # Its liveness check takes about two minutes alone, and longer on a CI runner.
    timeout: 900_000,
    code: [
      {:exports, HalC2.PreviewForward},
      {:messages, HalC2.PreviewForward.Listener},
      {:messages, HalC2.PreviewForward.Grant},
      {:messages, HalC2.PreviewForward.Pipe},
      {:state, HalC2.PreviewForward.Listener},
      {:state, HalC2.PreviewForward.Grant},
      {:state, HalC2.PreviewForward.Pipe}
    ],
    covers: %{
      "HalC2.PreviewForward.forward/4" => ~w(granted refused unavailable),
      "HalC2.PreviewForward.grant/3" => ~w(granted refused),
      "HalC2.PreviewForward.dial/2" => ~w(dial-call dial-gone),
      "HalC2.PreviewForward.Listener handle_info {:accepted, _}" => ~w(accept reset),
      "HalC2.PreviewForward.Listener handle_info {:DOWN, _, :process, _, _}" => "listener-down",
      "HalC2.PreviewForward.Listener handle_info {:EXIT, _, _}" => "killed",
      "HalC2.PreviewForward.Listener state :grant" => ~w(granted listener-down),
      "HalC2.PreviewForward.Listener state :ref" => "listener-down",
      "HalC2.PreviewForward.Listener state :sockets" => ~w(accept reset),
      "HalC2.PreviewForward.Listener state :pipes" => ~w(accept killed),
      "HalC2.PreviewForward.Grant handle_call {:dial, _}" => "dial-call",
      "HalC2.PreviewForward.Grant handle_info {:hal_c2_preview, _, %{\"threadId\" => _}}" =>
        "grant-closed",
      "HalC2.PreviewForward.Grant handle_info {:DOWN, _, :process, _, _}" => "grant-down",
      "HalC2.PreviewForward.Grant handle_info {:EXIT, _, _}" => "down",
      "HalC2.PreviewForward.Grant state :thread" => "grant-closed",
      "HalC2.PreviewForward.Grant state :port" => ~w(grant-closed dial),
      "HalC2.PreviewForward.Grant state :owner" => "grant-down",
      "HalC2.PreviewForward.Pipe handle_info {:socket, _}" =>
        ~w(ask ask-failed answer answer-failed),
      "HalC2.PreviewForward.Pipe handle_info {:tcp, _, _}" => "tcp",
      "HalC2.PreviewForward.Pipe handle_info {:preview_forward, :data, _}" => "data",
      "HalC2.PreviewForward.Pipe handle_info {:preview_forward, :ack}" => "ack",
      "HalC2.PreviewForward.Pipe handle_info {:tcp_closed, _}" => "closed",
      "HalC2.PreviewForward.Pipe handle_info {:tcp_error, _, _}" => "closed",
      "HalC2.PreviewForward.Pipe handle_info {:DOWN, _, :process, _, _}" => "down",
      "HalC2.PreviewForward.Pipe state :side" => ~w(ask dial),
      "HalC2.PreviewForward.Pipe state :grant" => "ask",
      "HalC2.PreviewForward.Pipe state :socket" => ~w(accept dial dial-refused closed),
      "HalC2.PreviewForward.Pipe state :peer" => ~w(answer data ack down),
      "HalC2.PreviewForward.Pipe state :unacked" => ~w(tcp ack),
      "HalC2.PreviewForward.Pipe state :armed" => ~w(tcp ack closed)
    },
    abstracts: %{
      "HalC2.PreviewForward.request/1" => "forward/4 behind the RPC's input checks",
      "HalC2.PreviewForward.listening/0" => @outside,
      "HalC2.PreviewForward.loopback?/2" =>
        "whether a tab names the port, which the model's tab stands for",
      "HalC2.PreviewForward.Grant handle_info {:hal_c2_preview, _, _}" =>
        "another thread's tab changes, which the grant ignores",
      "HalC2.PreviewForward.Listener handle_call :port" => @outside,
      "HalC2.PreviewForward.Listener state :port" => @outside
    },
    environment: %{
      "connect" => "the browser connects to the forward's port",
      "write" => "the browser or the dev server writes",
      "shut" => "the browser or the dev server closes its end",
      "close-tab" => "the thread's last tab at the port closes or navigates away",
      "kill" => "the listener or the grant is killed",
      "crash" => "an MC stops",
      "split" => "the MCs lose each other"
    },
    scenarios: %{
      "preview/remote.feature" => [
        "A forwarded dev server keeps its live connections",
        "A forward closes with the last tab that uses it",
        "A forward to an MC that stops answering closes"
      ]
    }

  test "no more chunks a way are unacked than the window", %{proof: proof} do
    refute_reachable(proof, "initial(3, 2, 2, 1)", "overdrawn", [])
  end

  test "chunks arrive in order, each once", %{proof: proof} do
    refute_reachable(proof, "initial(3, 2, 2, 1)", "disordered", [])
  end

  test "a forward lasts while its tab names the port and nothing fails", %{proof: proof} do
    refute_reachable(proof, "initial(2, 1, 1, 1)", "torn", [])
  end

  test "a connection one end closes delivers all it wrote first", %{proof: proof} do
    refute_reachable(proof, "initial(2, 1, 1, 1)", "lost", [])
  end

  test "a forward whose tab closes, or that a fault strikes, ends on both MCs",
       %{proof: proof} do
    assert_ltl(proof, "initial(1, 0, 1, 1)", "[] (over -> <> ended)", fair: @fair)
  end

  test "a connection one end closes ends on both MCs", %{proof: proof} do
    assert_ltl(proof, "initial(1, 1, 1, 1)", "[] (shut -> <> gone)", fair: @fair)
  end
end
