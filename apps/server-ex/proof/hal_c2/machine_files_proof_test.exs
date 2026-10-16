defmodule HalC2.MachineFilesProofTest do
  # The kernel's requests into another machine's folder, through every interleaving of
  # the helper, the MC on B, the process each request calls A from and A's MC, with A
  # crashing, the link cutting, A leaving, the kernel flushing a request and the helper
  # exiting at any step. prop/hal_c2/machine_files_prop_test.exs runs the code on
  # sequences of calls; this explores every order of the messages between them.
  @outside "reads or reports the folders; no request is answered by it"

  use HalC2.Proof,
    model: "machine_files.maude",
    module: "MACHINE-FILES",
    check: "MACHINE-FILES-PROPS",
    code: [
      {:exports, HalC2.MachineFiles},
      {:messages, HalC2.MachineFiles},
      {:exports, HalC2.MachineFiles.Share}
    ],
    covers: %{
      "HalC2.MachineFiles handle_info {_, {:data, _}}" =>
        ~w(request-gone request-down request-call flush),
      "HalC2.MachineFiles handle_info {:answer, _, _}" => ~w(answer answer-dropped),
      "HalC2.MachineFiles handle_info {_, {:exit_status, _}}" => "helper-exit",
      "HalC2.MachineFiles handle_info :restart" => "restart",
      "HalC2.MachineFiles handle_info {:hal_c2_shell, _}" => ~w(leave join),
      "HalC2.MachineFiles.Share.walk/2" => "share",
      "HalC2.MachineFiles.Share.stat/1" => "share",
      "HalC2.MachineFiles.Share.list/1" => "share",
      "HalC2.MachineFiles.Share.read/3" => "share",
      "HalC2.MachineFiles.Share.write/3" => "share",
      "HalC2.MachineFiles.Share.create/2" => "share",
      "HalC2.MachineFiles.Share.mkdir/2" => "share",
      "HalC2.MachineFiles.Share.remove/2" => "share",
      "HalC2.MachineFiles.Share.rename/2" => "share",
      "HalC2.MachineFiles.Share.setattr/2" => "share",
      "HalC2.MachineFiles.Share.roots/0" => "share"
    },
    abstracts: %{
      "HalC2.MachineFiles.start_link/1" => "starts the process the model is",
      "HalC2.MachineFiles.root/0" => @outside,
      "HalC2.MachineFiles.local_path/3" => @outside,
      "HalC2.MachineFiles.handle_rpc/2" => @outside,
      "HalC2.MachineFiles.message/2" => @outside,
      "HalC2.MachineFiles.await_ready/2" => @outside,
      "HalC2.MachineFiles.sync/1" => @outside,
      "HalC2.MachineFiles.folders/1" => @outside,
      "HalC2.MachineFiles handle_call {:local_path, _, _}" => @outside,
      "HalC2.MachineFiles handle_call :await_ready" => @outside,
      "HalC2.MachineFiles handle_call :sync" => @outside,
      "HalC2.MachineFiles handle_info {:hal_c2_shell, {:rows, _, _}}" =>
        "the sidebar's rows, which change no member",
      "HalC2.MachineFiles handle_info {:EXIT, _, _}" =>
        "the port's link; its exit status is what the model has",
      "HalC2.MachineFiles handle_info _" =>
        "a message of an old helper's port, dropped as the model drops what an exit leaves"
    },
    environment: %{
      "ask" => "the kernel reads or writes a file in the folder",
      "interrupt" => "the program reading is interrupted, and the kernel flushes its request",
      "remote" => ":erpc returns A's answer to the process that called",
      "remote-timeout" => ":erpc gives up: its timeout passed or the link to A went",
      "peer-crash" => "A's MC stops",
      "peer-start" => "A's MC starts again",
      "partition" => "the link between B and A cuts",
      "heal" => "the link comes back"
    },
    scenarios: %{
      "files/files-on-another-machine.feature" => [
        "Only the other machine's projects are shared",
        "Reading from a machine that stops answering fails instead of hanging",
        "The folder of a machine that leaves the cluster goes away"
      ]
    }

  # The code's own steps, and the cluster coming back after a fault: a step that can
  # be taken all along is taken in the end. The kernel asking and the faults are not.
  @fair ~w(request-gone request-down request-call flush remote remote-timeout share answer
           answer-dropped restart peer-start heal)

  for init <- ["start(2)", "outside-start(2)"] do
    test "nothing outside a shared root is read, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "leaked", [])
    end

    test "a request that is over is never replied to, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "replied-late", [])
    end
  end

  test "no request waits forever, whatever fails", %{proof: proof} do
    assert_ltl(proof, "start(2)", "<> [] ~ waiting", fair: @fair)
  end
end
