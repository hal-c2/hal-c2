defmodule HalC2.CodeReviewClaimsProofTest do
  # The code-review plugin on two or three machines of a cluster watching one pull
  # request: looks that leave the review to a machine that queued or claimed the head,
  # runs that claim the commit they checked out under a :global lock across the
  # machines connected then, posts under a lock of their own, and the looks again at
  # once when a machine leaves or :peer_claims says no other machine has a review left
  # to it. Machines crash, partition and have their plugin restart; checkouts fail, the
  # agent hits its usage limit, which pauses its machine and keeps its queue from the
  # others, and the pull request gets a push.
  # prop/hal_c2/code_review_claims_prop_test.exs runs the code one step at a time; this
  # explores every interleaving between machines up to the bounds.
  @reads "answers from the plugin's state; changes no claim"
  @user "the user's own ask, which means to review or forget again (and ends a pause); the model's reviews start on their own"
  @pause "the pause after three failed runs holds the queue back as the usage limit's does, which the model has"
  @shown "what the page and the threads show; no part of a claim"
  @look "the parts of a look the model leaves out: which pull requests, their sizes and comments; it has one pull request, automatically reviewed"
  @agent "the review thread and its agent; the model's runs end when they claim or step back"
  @host "a host function no claim or post goes through"

  use HalC2.Proof,
    model: "code_review_claims.maude",
    module: "CODE-REVIEW-CLAIMS",
    check: "CODE-REVIEW-CLAIMS-PROPS",
    timeout: 1_200_000,
    code: [
      {:exports, HalC2Plugins.CodeReview},
      {:messages, HalC2Plugins.CodeReview},
      {:state, HalC2Plugins.CodeReview},
      {:exports, HalC2Plugins.CodeReview.Checkout},
      {:exports, HalC2.Plugins.Host}
    ],
    covers: %{
      "HalC2Plugins.CodeReview.claims/1" => ~w(peers started defer post peer-claims restartingBy),
      "HalC2Plugins.CodeReview.claims_changed/0" => ~w(note peer-claims),
      "HalC2Plugins.CodeReview handle_call {:looked, _}" => ~w(polled pump),
      "HalC2Plugins.CodeReview handle_call {:publish, _}" =>
        ~w(publish post-lock post refused covered),
      "HalC2Plugins.CodeReview handle_call {:published, _, _, _}" => "published",
      "HalC2Plugins.CodeReview handle_call {:report, _, _}" => "report",
      "HalC2Plugins.CodeReview handle_call {:started, _, _, _}" => "started",
      "HalC2Plugins.CodeReview handle_cast {:turn_finished, _, _, _}" => "turn-finished",
      "HalC2Plugins.CodeReview handle_cast {:elsewhere, _, _, _}" => ~w(elsewhere peer-claims),
      "HalC2Plugins.CodeReview handle_cast {:start_failed, _, _, _}" => "start-failed",
      "HalC2Plugins.CodeReview handle_info :poll" => ~w(look peers),
      "HalC2Plugins.CodeReview handle_info {:polled, _}" => ~w(polled pump away orAway),
      "HalC2Plugins.CodeReview handle_info {:resume, _}" => ~w(resume pump),
      "HalC2Plugins.CodeReview handle_info {:DOWN, _, :process, _, _}" => "polled",
      "HalC2Plugins.CodeReview handle_info {:nodedown, _}" => ~w(nodedown relook on),
      "HalC2Plugins.CodeReview handle_info :peer_claims" => "peer-claims",
      "HalC2Plugins.CodeReview handle_info {:elsewhere_seen, _, _, _}" =>
        ~w(elsewhere-seen relook shown restarting away orAway),
      "HalC2Plugins.CodeReview state :reviews" => ~w(rv rowOf withHeld applied queued holding),
      "HalC2Plugins.CodeReview state :looked" => "polled",
      "HalC2Plugins.CodeReview state :polling" => "poll",
      "HalC2Plugins.CodeReview state :paused_until" => ~w(paused shareOf pump resume),
      "HalC2Plugins.CodeReview state :claimed_at" => ~w(started older polled),
      "HalC2Plugins.CodeReview.Checkout.prepare/5" => ~w(checkout claim lock),
      "HalC2Plugins.CodeReview.Checkout.remove/2" => "defer",
      "HalC2.Plugins.Host.peers/4" =>
        ~w(peers started defer post peer-claims note heldBy restart),
      "HalC2.Plugins.Host.peer/3" => ~w(hardBy softBy publishedBy),
      "HalC2.Plugins.Host.pull_requests/3" => ~w(peers post)
    },
    abstracts: %{
      "HalC2Plugins.CodeReview.prompt/3" => @agent,
      "HalC2Plugins.CodeReview handle_call :snapshot" => @reads,
      "HalC2Plugins.CodeReview handle_call :reviews" => @reads,
      "HalC2Plugins.CodeReview handle_call {:for_thread, _}" => @reads,
      "HalC2Plugins.CodeReview handle_call {:start, _, _}" => @user,
      "HalC2Plugins.CodeReview handle_call {:dismiss, _, _, _}" => @user,
      "HalC2Plugins.CodeReview handle_call {:discard, _}" => @user,
      "HalC2Plugins.CodeReview handle_call {:settings, _}" =>
        "a save applies from the next step: the model looks at any time, starts a queued review in the step that queues it and has no display",
      "HalC2Plugins.CodeReview handle_cast {:launched, _}" => @shown,
      "HalC2Plugins.CodeReview handle_info {:EXIT, _, _}" => @shown,
      "HalC2Plugins.CodeReview handle_info _" =>
        "nodeup and the rest change nothing; connect stands for a nodeup",
      "HalC2Plugins.CodeReview state :settings" => @look,
      "HalC2Plugins.CodeReview state :problem" => @shown,
      "HalC2Plugins.CodeReview state :unwatched" => @shown,
      "HalC2Plugins.CodeReview state :checked_at" => @shown,
      "HalC2Plugins.CodeReview state :threads" => @shown,
      "HalC2Plugins.CodeReview state :paused_reason" => @shown,
      "HalC2Plugins.CodeReview state :failures" => @pause,
      "HalC2Plugins.CodeReview state :poll_backoff" =>
        "how long until the next look; the model looks at any time",
      "HalC2Plugins.CodeReview state :timer" =>
        "when the next look is; the model looks at any time",
      "HalC2Plugins.CodeReview state :lister" => @shown,
      "HalC2Plugins.CodeReview.Checkout.read/4" => @agent,
      "HalC2Plugins.CodeReview.Checkout.diff_lines/3" => @agent,
      "HalC2Plugins.CodeReview.Checkout.position/4" => @agent,
      "HalC2.Plugins.Host.publish/3" => @shown,
      "HalC2.Plugins.Host.data_dir/1" => @host,
      "HalC2.Plugins.Host.projects/1" => @look,
      "HalC2.Plugins.Host.providers/1" => @host,
      "HalC2.Plugins.Host.issues/3" => @host,
      "HalC2.Plugins.Host.thread/2" => @agent,
      "HalC2.Plugins.Host.launch_thread/4" => @agent,
      "HalC2.Plugins.Host.organize_thread/3" => @shown,
      "HalC2.Plugins.Host.granted?/2" => @host,
      "HalC2.Plugins.Host.slack/3" => @host
    },
    environment: %{
      "push" => "a commit is pushed to the pull request",
      "crash" => "a machine goes down, and its connections and the locks held on it",
      "bounce" => "the plugin's server alone goes down, its node connected throughout",
      "restart" => "the plugin, and its machine if down, come back: init/1 and load/0",
      "partition" => "a connection drops",
      "connect" => "Discovery connects two machines that are up"
    },
    scenarios: %{
      "source-control/agent-code-review.feature" => [
        "Two machines watching the same repository review a pull request once",
        "A machine on its own reviews",
        "The review moves to another machine when its machine leaves before starting it",
        "The review moves to another machine when its machine's agent reaches its usage limit",
        "A commit two machines reviewed while apart is posted once",
        "A commit a machine posted just before it restarted is published without posting it again"
      ]
    }

  # The code's own steps, which do not stop while they can happen. The end of a pause
  # is not among them: the reviews get done without it.
  @fair ~w(look peers polled checkout claim lock started defer elsewhere nodedown
           peer-claims elsewhere-seen)

  # The plugin is loaded by the plugin host at run time; the facts need its compiled
  # module, docs included.
  setup_all do
    plugin = Path.expand("../../../../plugins/code-review/mc", __DIR__)
    dir = Path.join(Mix.Project.build_path(), "proof-plugins/code-review")
    File.mkdir_p!(dir)
    files = Enum.map(~w(checkout.ex code_review.ex), &Path.join(plugin, &1))
    docs = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)

    try do
      {:ok, _, _} = Kernel.ParallelCompiler.compile_to_path(files, dir, return_diagnostics: true)
    after
      Code.put_compiler_option(:docs, docs)
    end

    Code.prepend_path(dir)
    Enum.each([HalC2Plugins.CodeReview, HalC2Plugins.CodeReview.Checkout], &Code.ensure_loaded!/1)
    :ok
  end

  # Looks, crashes, partitions, plugin restarts, failed checkouts and usage limits in two
  # machines; looks in three.
  @safe ~w[two(2,0,0,0,0,0,0) two(1,0,1,0,0,0,0) two(1,0,0,1,0,0,0) two(1,0,0,0,1,0,0)
           two(1,0,0,0,0,1,1) three(1,0,0,0,0,0,0) both(2,1)]

  for init <- @safe do
    test "no machine claims, starts or posts a commit a connected machine it locked has, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "unsafe", [])
    end
  end

  test "a push does not start or post a commit twice", %{proof: proof} do
    refute_reachable(proof, "two(1,1,0,0,0,0,0)", "unsafe", [])
  end

  test "a push and a push back do not start or post a commit twice", %{proof: proof} do
    refute_reachable(proof, "pushedBack", "unsafe", [])
  end

  test "a machine that stops before it saves its post does not post the commit again, nor does another",
       %{proof: proof} do
    for init <- ~w[apart(0,1) apart(1,0)], do: refute_reachable(proof, init, "unsafe", [])
  end

  test "a machine that stepped back for a restarting plugin looks again once it is back",
       %{proof: proof} do
    assert_ltl(proof, "both(0,1)", "<> [] reviewed", fair: ["restart" | @fair])
  end

  test "two machines looking in turn get the head reviewed", %{proof: proof} do
    assert_ltl(proof, "live(0,0,0,0,0,0)", "<> [] reviewed", fair: @fair)
  end

  # One periodic look between the machines: with any number the check runs past the
  # timeout. Repeated looks are left to the claims property, which looks again at will.
  test "the review gets done when a plugin restarts while both machines start it",
       %{proof: proof} do
    assert_ltl(proof, "both(1,1)", "<> [] reviewed", fair: ["restart" | @fair])
  end

  test "the review moves to another machine when its machine leaves before starting it",
       %{proof: proof} do
    for init <- ~w[left(1,0,0) left(0,1,0)] do
      assert_ltl(proof, init, "[] steady(a) -> <> [] reviewed", fair: @fair)
    end
  end

  test "the review moves to another machine when its machine pauses before starting it",
       %{proof: proof} do
    assert_ltl(proof, "left(0,0,1)", "<> [] reviewed", fair: @fair)
  end

  test "a review queued behind another moves to another machine when its machine pauses",
       %{proof: proof} do
    assert_ltl(proof, "behind(0,0,1)", "<> [] reviewed", fair: ["turn-finished" | @fair])
  end
end
