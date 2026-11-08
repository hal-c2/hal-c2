defmodule HalC2.UnrecordedTurnsProofTest do
  # A turn whose events the store cannot record (#1285): the provider runtime that
  # drives it on without writing and stops its provider turn, TurnWatch holding the
  # run's end in memory until the store takes it, a user's stop, the thread's next
  # message, and boot recovery, through every interleaving of the store failing and
  # recovering, the provider ending its turn or ignoring a stop, the runtime crashing
  # and the MC restarting. Codex stands for every runtime: its stop is the one that can
  # time out and leave its provider turn running for the next message to stop first.
  # A stop Muse refuses, or ACP answers at once, ends the turn inside the runtime's
  # call instead, and the failure goes with that turn too.
  #
  # What the store wrote is the truth here: no side file. An MC that restarts while
  # TurnWatch holds an end loses it, and boot recovery ends the run as interrupted at
  # boot, so the properties that a failure reads as failed, and its provider turn as
  # it ended, hold but for a run an MC restart forgot.
  @items "writes a turn's items and streamed text; dry, it writes nothing, and the [unrecorded] step stands for the first that fails"
  @steer "adds a message to the turn the runtime drives; no run or provider turn ends"

  use HalC2.Proof,
    model: "unrecorded_turns.maude",
    module: "UNRECORDED-TURNS",
    check: "UNRECORDED-TURNS-PROPS",
    code: [
      {:exports, HalC2.Orchestration.Unrecorded},
      {:exports, HalC2.Orchestration.TurnWatch},
      {:messages, HalC2.Orchestration.TurnWatch},
      {:messages, HalC2.Codex.ThreadRuntime}
    ],
    covers: %{
      # Every message of a runtime goes through it: one whose write fails while a turn
      # runs fails the run and stops the turn, and from then on the runtime is dry
      # until the turn's end is handed over.
      "HalC2.Orchestration.Unrecorded.handle_info/4" => ~w(unrecorded hand-over deadline),
      # And every call: one that ends a dry turn (a stop the provider refuses) hands its
      # end over, and the failure goes with the turn.
      "HalC2.Orchestration.Unrecorded.handle_call/4" => ~w(interrupt-dry interrupt-driven),
      "HalC2.Orchestration.TurnWatch.claim/2" => "take",
      "HalC2.Orchestration.TurnWatch.release/1" => "finish",
      "HalC2.Orchestration.TurnWatch.driven?/1" => ~w(interrupt-driven interrupt-undriven),
      "HalC2.Orchestration.TurnWatch.unrecorded/3" => ~w(unrecorded hand-over deadline),
      "HalC2.Orchestration.TurnWatch handle_call {:claim, _, _, _}" => "take",
      "HalC2.Orchestration.TurnWatch handle_cast {:release, _}" => "finish",
      "HalC2.Orchestration.TurnWatch handle_cast {:unrecorded, _, _, _}" =>
        ~w(unrecorded hand-over deadline record),
      "HalC2.Orchestration.TurnWatch handle_call {:driven?, _}" =>
        ~w(interrupt-driven interrupt-undriven),
      "HalC2.Orchestration.TurnWatch handle_info {:DOWN, _, :process, _, _}" => "gone",
      "HalC2.Orchestration.TurnWatch handle_info {:retry, _}" => "record",
      "HalC2.Orchestration.TurnWatch handle_info {:attempted, _, _}" => ~w(record attempt-failed),
      "HalC2.Codex.ThreadRuntime handle_call {:start_turn, _}" => ~w(take refuse-start),
      "HalC2.Codex.ThreadRuntime handle_call :interrupt" => ~w(interrupt-driven unrecorded),
      "HalC2.Codex.ThreadRuntime handle_call {:interrupt, _}" => "interrupt-driven",
      "HalC2.Codex.ThreadRuntime handle_call {:interrupt, _, _}" => "interrupt-driven",
      "HalC2.Codex.ThreadRuntime handle_info {:interrupt_deadline, _}" => "deadline",
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:notification, _, _}}" =>
        ~w(finish hand-over leftover-end ignored-end unrecorded),
      # A Codex goal's grace ends its run as Codex's turn end does; a stale one changes
      # nothing.
      "HalC2.Codex.ThreadRuntime handle_info {:goal_grace, _}" =>
        ~w(finish hand-over unrecorded ignored-end),
      # Every message, the wrapper's clause included: one it does not know is ignored.
      "HalC2.Codex.ThreadRuntime handle_info _" => ~w(unrecorded hand-over ignored-end),
      "HalC2.Codex.ThreadRuntime handle_call _" => ~w(take refuse-start interrupt-driven)
    },
    abstracts: %{
      "HalC2.Orchestration.TurnWatch.attempted/2" =>
        "for tests: waits on TurnWatch's next try; changes nothing",
      "HalC2.Orchestration.TurnWatch handle_call {:attempted, _}" =>
        "for tests: answers when a try fails or records; changes nothing",
      "HalC2.Orchestration.TurnWatch.start_link/1" =>
        "starts the process TurnWatch's rules run in",
      "HalC2.Codex.ThreadRuntime handle_info {:EXIT, _, _}" =>
        "the app-server exiting under a turn is turns.maude's; one left over goes with it, its provider turn recorded as interrupted, as [crash] kills it",
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:invalid, _}}" =>
        "closes the app-server, as it exiting does (turns.maude)",
      "HalC2.Codex.ThreadRuntime handle_call {:steer, _, _}" => @steer,
      "HalC2.Codex.ThreadRuntime handle_call {:respond, _, _}" => @items,
      "HalC2.Codex.ThreadRuntime handle_call {:rollback, _}" =>
        "rolls back the checkout between turns; no run changes",
      "HalC2.Codex.ThreadRuntime handle_call {:upload_feedback, _}" =>
        "sends feedback; no run changes",
      "HalC2.Codex.ThreadRuntime handle_call :settle" => "a barrier for tests; changes nothing",
      "HalC2.Codex.ThreadRuntime handle_call :release" =>
        "stops an idle session; turns.maude holds it, and a dry runtime is never idle",
      "HalC2.Codex.ThreadRuntime handle_call {:adopt, %{dir: _, snapshot: _}}" =>
        "programs here stop with the MC; a failed adoption settles as restart does",
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:request, _, _, _}}" => @items,
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:request, _, \"item/tool/requestUserInput\", _}}" =>
        @items,
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:request, _, \"mcpServer/elicitation/request\", _}}" =>
        @items,
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, _}" =>
        "drops what an app-server it stopped for another instance sent; the model has one",
      "HalC2.Codex.ThreadRuntime handle_info :flush" => @items,
      "HalC2.Codex.ThreadRuntime handle_info {:json_rpc, _, {:checkpoint, _}}" =>
        "saves state to a file for a later boot; no run changes",
      "HalC2.Codex.ThreadRuntime handle_info :durable_save" =>
        "saves state to a file for a later boot; no run changes"
    },
    environment: %{
      "fail" => "the store refuses writes (a full disk)",
      "recover" => "the store takes writes again",
      "own-end" => "the provider ends its turn on its own, completed or failed",
      "stop" => "the provider stops its turn when asked",
      "ignore" => "the provider ignores a stop until the runtime's deadline is out",
      "crash" => "the runtime's process crashes, its app-server with it",
      "restart" => "the MC stops and starts again",
      # Orchestration's own steps, proved in turns.maude: the order of a thread's runs
      # and what boot recovery does.
      "dispatch" => "the thread's next message starts once the earlier run ended",
      "settle" => "boot recovery (Recovery.run/0) ends the runs left active, at boot"
    },
    scenarios: %{
      "mc/orchestration/runs.feature" => [
        "A run whose events cannot be recorded stops its provider turn",
        "A run failure that could not be recorded is recorded once storage recovers",
        "A follow-up first stops a provider turn an earlier failed run left running",
        "A run whose events cannot be recorded keeps how its provider turn ended",
        "A run whose events cannot be recorded leaves the next run to record as usual"
      ]
    }

  # Every path is finite: the store fails, the runtime crashes and the MC restarts at
  # most `faults` times, and each provider turn ends once. A depth of 40 is past the
  # longest path at four faults, so each bounded search sees every state.
  @depth 40
  @faults ~w(fail crash restart)

  # init(faults, a user's stop of r1, parts of the fix switched off).
  @inits ["init(3, false, empty)", "init(3, true, empty)", "init(4, true, empty)"]

  for init <- @inits do
    test "a run's end is recorded once, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "twice", depth: @depth)
    end

    test "a failure the store refused is recorded at the time it failed, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "late", depth: @depth)
    end

    test "a run the store failed reads as failed, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "lost", depth: @depth)
    end

    test "a provider turn's own ending is not overwritten, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "overwritten", depth: @depth)
    end

    test "a run whose turn the store took fails only for what it heard, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "misfiled", depth: @depth)
    end

    test "a follow-up never runs alongside a left-over provider turn, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "twoTurns", depth: @depth)
    end

    test "an active run always has something to end it, from #{init}", %{proof: proof} do
      refute_reachable(proof, unquote(init), "orphan", depth: @depth)
    end

    test "nothing is left waiting, from #{init}", %{proof: proof} do
      refute_deadlock(proof, unquote(init), "quiet", besides: @faults)
    end
  end

  # With every path finite, a path that ends does so in a state the deadlock search
  # vouches for; this says the same of the runs themselves, along every path.
  for init <- ["init(3, false, empty)", "init(3, true, empty)"] do
    test "no run stays active for ever, from #{init}", %{proof: proof} do
      formula =
        "[] (failing(r1) -> <> ~ unended(r1)) /\\ <> [] (~ unended(r1) /\\ ~ unended(r2))"

      assert_ltl(proof, unquote(init), formula, [])
    end
  end

  # Each part of the fix, switched off, lets in the bad state it keeps out.
  for {part, bad, what} <- [
        {"noRetry", "orphan", "TurnWatch trying a refused end again"},
        {"nowTime", "late", "the end keeping the time the run failed"},
        {"overwrite", "overwritten", "the end keeping how its provider turn ended"},
        {"noLeftoverStop", "twoTurns", "the next message stopping a left-over provider turn"},
        {"noInterrupt", "twoTurns", "the failed turn's provider turn being stopped"},
        {"notDriven", "lost", "a held end counting as driven, so a stop leaves it"},
        {"noActiveCheck", "twice", "abandon/5 leaving a run that already ended"},
        {"keepMark", "misfiled", "the failure going with its turn when a call ends it"}
      ] do
    test "without #{what}, #{bad} is reachable", %{proof: proof} do
      assert_reachable(proof, unquote("init(2, true, off(#{part}))"), unquote(bad), depth: @depth)
    end
  end
end
