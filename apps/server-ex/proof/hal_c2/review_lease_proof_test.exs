defmodule HalC2.ReviewLeaseProofTest do
  # A sandboxed code review's lease (#1412): the opener, the review process's stop,
  # deadline, budget and report closes, the broker taking one report, and the reaper
  # timer the gateway's service runs. The review process restarts, the MC goes down
  # and comes back, and the gateway refuses steps. test/hal_c2/open_shell/review_test.exs
  # and the code-review feature's sandbox scenarios run the code; this explores every
  # interleaving of those processes up to the bounds.
  @reads "answers from the review process's tables; changes no lease"
  @turn "puts a bound review's sandbox, workdir and broker in its turn; changes no lease"
  @pure "a pure helper over names, labels or drivers"
  # A sandbox another plugin opened or closed first refuses an open or close before any
  # step of its lease, so the one review the model follows has one opener.
  @link "the review process's links ending: a listener started again, or a connection made again on the next call"

  use HalC2.Proof,
    model: "review_lease.maude",
    module: "REVIEW-LEASE",
    check: "REVIEW-LEASE-PROPS",
    timeout: 600_000,
    code: [
      {:exports, HalC2.OpenShell.Review},
      {:messages, HalC2.OpenShell.Review},
      {:state, HalC2.OpenShell.Review},
      {:exports, HalC2.OpenShell.Broker}
    ],
    covers: %{
      "HalC2.OpenShell.Review.open/1" =>
        ~w(opening stopped-first issue create-provider create-sandbox bind bind-refused),
      "HalC2.OpenShell.Review.close/3" => ~w(stop reported),
      "HalC2.OpenShell.Review.spent/3" => "spent",
      "HalC2.OpenShell.Review.reconcile/0" => ~w(reconcile wiped),
      "HalC2.OpenShell.Review.reap/2" => ~w(reap reap-no-sandboxes reap-no-providers),
      "HalC2.OpenShell.Review.expired/2" => "reap",
      "HalC2.OpenShell.Review handle_call {:opening, _, _}" => ~w(opening stopped-first),
      "HalC2.OpenShell.Review handle_call {:bind, _}" => ~w(bind bind-refused),
      "HalC2.OpenShell.Review handle_call {:close, _, _, _}" => ~w(stop reported close delete),
      "HalC2.OpenShell.Review handle_cast {:spent, _, _, _}" => "spent",
      "HalC2.OpenShell.Review handle_cast :reconcile" => ~w(reconcile wiped),
      "HalC2.OpenShell.Review handle_info {:deadline, _}" => "deadline",
      "HalC2.OpenShell.Review state :timers" => ~w(bind deadline close),
      "HalC2.OpenShell.Review state :spent" => "spent",
      "HalC2.OpenShell.Broker.issue/1" => "issue",
      "HalC2.OpenShell.Broker.revoke/1" => "revoke",
      "HalC2.OpenShell.Broker.grant/1" => ~w(report take),
      "HalC2.OpenShell.Broker.table/0" => "lose"
    },
    abstracts: %{
      "HalC2.OpenShell.Review.start_link/1" => "starts the review process; the model's boot",
      "HalC2.OpenShell.Review.drivers/0" => @pure,
      "HalC2.OpenShell.Review.supported?/1" => @pure,
      "HalC2.OpenShell.Review.command/1" => @pure,
      "HalC2.OpenShell.Review.binding/1" => @reads,
      "HalC2.OpenShell.Review.subprocess/2" => @turn,
      "HalC2.OpenShell.Review.in_sandbox/1" => @turn,
      "HalC2.OpenShell.Review.for_turn/2" => @turn,
      "HalC2.OpenShell.Review.mcp/1" => @turn,
      "HalC2.OpenShell.Review.refusal/2" => @reads,
      "HalC2.OpenShell.Review.ended/1" => @reads,
      "HalC2.OpenShell.Review.opener/1" => @reads,
      "HalC2.OpenShell.Review.ended_text/1" => @pure,
      "HalC2.OpenShell.Review.why/1" => "words for a failed step; the model's open-fails",
      "HalC2.OpenShell.Review.labels/2" => @pure,
      "HalC2.OpenShell.Review.name/1" => @pure,
      "HalC2.OpenShell.Review.role_label/0" => @pure,
      "HalC2.OpenShell.Review.expires_label/0" => @pure,
      "HalC2.OpenShell.Review.home_label/0" =>
        "names the home a sandbox is of; the model is one home, whose reap and reconcile list by it",
      "HalC2.OpenShell.Review.owner/0" => @pure,
      "HalC2.OpenShell.Review handle_call :conn" =>
        "connects to the gateway once; the model's gateway is always reachable",
      "HalC2.OpenShell.Review handle_call :broker" =>
        "starts the broker's listener once; the model's broker is always listening",
      "HalC2.OpenShell.Review handle_info {:EXIT, _, _}" => @link,
      "HalC2.OpenShell.Review handle_info {:EXIT, _, :normal}" => @link,
      "HalC2.OpenShell.Review handle_info _" => "a stray message; changes nothing",
      "HalC2.OpenShell.Review state :conn" => "the gateway connection; the model's is always up",
      "HalC2.OpenShell.Review state :broker" => "the broker's address; no lease depends on it",
      "HalC2.OpenShell.Review state :listener" => @link,
      "HalC2.OpenShell.Broker.listen/0" =>
        "starts the broker's listener; the model's broker is always listening"
    },
    environment: %{
      "open-fails" =>
        "the gateway refuses a step (another environment's sandboxes on it, say), or the sandbox is not ready or its checkout fails or times out",
      "delete-fails" => "the gateway refuses a deletion, or never finishes one it accepted",
      "stop" => "the user stops, discards or replaces the review",
      "spent" => "the agent uses up the review's token budget",
      "report" => "the agent sends its report, as many times and as often as it likes",
      "reject" => "the plugin refuses a report, which the agent may send again",
      "restart" => "the review process crashes and its supervisor starts it again",
      "down" => "the MC goes down, with every process of its own",
      "up" => "the MC comes back",
      "tick" => "the lease runs out"
    },
    scenarios: %{
      "source-control/agent-code-review.feature" => [
        "An untrusted pull request is reviewed in a sandbox, deleted once the agent reports",
        "A sandboxed review takes one report, however many its agent sends",
        "A sandboxed review past its token budget fails and loses its sandbox",
        "Stopping a sandboxed review deletes its sandbox",
        "Review sandboxes past their time are deleted while the MC is down",
        "An MC starting deletes the review sandboxes left from before"
      ]
    }

  @code ~w(opening stopped-first issue create-provider create-sandbox bind bind-refused
           deadline take reported reconcile wiped delete tick)

  test "no interleaving takes two reports or leaves a token or binding on a closed review",
       %{proof: proof} do
    refute_reachable(proof, "start(1, 1, 1, 1)", "unsafe", [])
  end

  test "a review always ends with nothing left on the gateway", %{proof: proof} do
    refute_deadlock(proof, "start(1, 1, 1, 1)", "settled",
      besides: ~w(open-fails delete-fails stop spent report reject restart down up)
    )
  end

  test "an MC that stays up deletes its review's sandbox on its own", %{proof: proof} do
    # A deletion the gateway refuses is the reaper's, below.
    assert_ltl(proof, "start(0, 1, 1, 0)", "<> [] gone", fair: @code)
  end

  test "the reaper deletes the sandbox of a review whose MC never comes back",
       %{proof: proof} do
    assert_ltl(proof, "start(1, 1, 1, 1)", "<> [] gone", fair: @code ++ ["reap"])
  end
end
