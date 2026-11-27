defmodule HalC2.CodeReviewClaimsProofTest do
  # The code-review plugin on two or three machines of a cluster watching one pull
  # request: looks that leave the review to a machine that queued or claimed the head,
  # runs that claim the commit they checked out under a :global lock across the
  # machines connected then, posts under a lock of their own, and the looks again at
  # once when a machine leaves or :peer_claims says no other machine has a review left
  # to it. Machines crash, partition and have their plugin restart; checkouts fail, the
  # agent hits its usage limit, which pauses its machine and keeps its queue from the
  # others, and the pull request gets a push. Apart, two or three machines count their
  # starts against the review limits under a lock of their own, with what the others
  # started, and run them once those in reach heard. A machine that cannot open review
  # sandboxes offers its run to the connected machines, which may refuse it, go down or
  # find they cannot either.
  # prop/hal_c2/code_review_claims_prop_test.exs runs the code one step at a time; this
  # explores every interleaving between machines up to the bounds.
  @reads "answers from the plugin's state; changes no claim"
  @user "the user's own ask, which means to review or forget again (and ends a pause); the model's reviews start on their own"
  @pause "the pause after three failed runs holds the queue back as the usage limit's does, which the model has"
  @shown "what the page and the threads show; no part of a claim"
  @stop "the user's Stop, which reaches the machine that took the review as well; the model's reviews are never stopped"
  @look "the parts of a look the model leaves out: which pull requests, their sizes and comments; it has one pull request, automatically reviewed"
  @agent "the review thread and its agent; the model's runs end when they claim or step back"
  @host "a host function no claim or post goes through"
  @trust "who stands behind a pull request and the user's approval of one; the model's pull request is trusted"
  # Not a protocol between processes, so no model of its own: one machine's rows, read
  # once and then forwarded one way from HalC2.Shell's broadcasts to the linked caller,
  # deciding nothing. A change between the read and the watch is not lost because the
  # caller watches first and then reads, and one that comes twice is the same row; the
  # relay dies with the caller (linked and monitoring it), so a pending delivery has
  # nowhere to go and nothing to undo.
  @rows "this machine's thread rows for the office plugin, read or relayed one way from HalC2.Shell to the linked caller (watch first, then read: a change in between comes again); no claim or post goes through them"

  use HalC2.Proof,
    model: "code_review_claims.maude",
    module: "CODE-REVIEW-CLAIMS",
    check: "CODE-REVIEW-CLAIMS-PROPS",
    # three(1,0,0,0,0,0,0) has run past 20 minutes on a slow runner, on a model that
    # passes in a 13-minute job on a fast one.
    timeout: 1_800_000,
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
      "HalC2Plugins.CodeReview handle_call {:looked, _, :asked}" => ~w(polled pump resume),
      "HalC2Plugins.CodeReview handle_call {:publish, _, _, _}" =>
        ~w(publish post-lock post refused covered),
      "HalC2Plugins.CodeReview handle_call {:published, _, _, _}" => "published",
      "HalC2Plugins.CodeReview handle_call {:report, _, _}" => "report",
      "HalC2Plugins.CodeReview handle_call {:started, _, _, _}" => "started",
      "HalC2Plugins.CodeReview handle_cast {:turn_finished, _, _, _}" => "turn-finished",
      "HalC2Plugins.CodeReview handle_cast {:elsewhere, _, _, _}" => ~w(elsewhere peer-claims),
      "HalC2Plugins.CodeReview handle_call {:handed, _, _, _}" => ~w(offer elsewhere peer-claims),
      "HalC2Plugins.CodeReview handle_cast {:start_failed, _, _, _}" =>
        ~w(start-failed sandbox-failed),
      "HalC2Plugins.CodeReview.take/1" => ~w(offer answers takes taken),
      "HalC2Plugins.CodeReview handle_call {:take, _, _}" => ~w(offer takes failedAt taken),
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
      "HalC2Plugins.CodeReview handle_call {:budget, _, _, _}" =>
        ~w(count count-lock bblocked admit over toldOf restartingOf membersOf ledgers join plus without part),
      "HalC2Plugins.CodeReview handle_call {:told, _, _, _, _}" => ~w(counted untold),
      "HalC2Plugins.CodeReview handle_call {:count_start, _}" => ~w(tell join),
      "HalC2Plugins.CodeReview.starts/0" => ~w(admit over ledgers),
      "HalC2Plugins.CodeReview.count_start/1" => ~w(tell heard counted),
      "HalC2Plugins.CodeReview state :starts" => ~w(bm join count),
      "HalC2Plugins.CodeReview state :machines" => ~w(bm plus membersOf without part),
      "HalC2Plugins.CodeReview.Checkout.prepare/6" => ~w(checkout claim lock),
      "HalC2Plugins.CodeReview.Checkout.remove/2" => "defer",
      "HalC2.Plugins.Host.peers/4" =>
        ~w(peers started defer post peer-claims note heldBy restart admit tell toldOf restartingOf muted),
      "HalC2.Plugins.Host.peer/3" => ~w(hardBy softBy publishedBy),
      "HalC2.Plugins.Host.pull_requests/3" => ~w(peers post),
      "HalC2.Plugins.Host.cluster_machines/1" => ~w(members membersOf admit over),
      "HalC2.Plugins.Host.sandboxes_ready?/1" => ~w(nosb unboxed handoff checkout takes),
      "HalC2.Plugins.Host.peer_call/5" => ~w(offer answers),
      "HalC2.Plugins.Host.open_sandbox/3" => "sandbox-failed"
    },
    abstracts: %{
      "HalC2Plugins.CodeReview.prompt/3" => @agent,
      "HalC2Plugins.CodeReview handle_call :snapshot" => @reads,
      "HalC2Plugins.CodeReview handle_call :reviews" => @reads,
      "HalC2Plugins.CodeReview handle_call :settings" => @reads,
      "HalC2Plugins.CodeReview handle_call {:for_thread, _}" => @reads,
      "HalC2Plugins.CodeReview handle_call {:review_thread?, _}" => @reads,
      "HalC2Plugins.CodeReview handle_call {:start, _, _}" => @user,
      "HalC2Plugins.CodeReview handle_call :resume" =>
        "the user's ask to end this machine's pause now, which the model's resume does at any time; no cluster claim goes through it",
      "HalC2Plugins.CodeReview handle_call {:dismiss, _, _, _}" => @user,
      "HalC2Plugins.CodeReview handle_call {:approve, _, _}" => @trust,
      "HalC2Plugins.CodeReview handle_call {:unapprove, _}" => @trust,
      "HalC2Plugins.CodeReview.neutral/1" => @agent,
      "HalC2Plugins.CodeReview.closed/1" =>
        "closes the code fences the agent's prose leaves open; text, no claim or run state",
      "HalC2Plugins.CodeReview.comment_body/2" =>
        "the text of an inline comment as posted; no claim or run state",
      "HalC2Plugins.CodeReview.existing_comments/4" =>
        "the review comments the agent's prompt quotes; text, no claim or run state",
      "HalC2Plugins.CodeReview handle_call {:preview, _}" => @reads,
      "HalC2Plugins.CodeReview handle_call {:discard, _}" => @user,
      "HalC2Plugins.CodeReview handle_call {:settings, _}" =>
        "a save applies from the next step: the model looks at any time, starts a queued review in the step that queues it and has no display",
      "HalC2Plugins.CodeReview handle_cast {:launched, _}" => @shown,
      "HalC2Plugins.CodeReview handle_info {:EXIT, _, _}" => @shown,
      "HalC2Plugins.CodeReview handle_info {:nodeup, _}" =>
        "a machine back in reach no longer shows out of reach, nor a review held while it was apart as held; " <>
          @shown,
      "HalC2Plugins.CodeReview handle_info _" =>
        "nodeup and the rest change nothing; connect stands for a nodeup",
      "HalC2Plugins.CodeReview state :settings" => @look,
      "HalC2Plugins.CodeReview state :problem" => @shown,
      "HalC2Plugins.CodeReview state :unwatched" => @shown,
      "HalC2Plugins.CodeReview state :checked_at" => @shown,
      "HalC2Plugins.CodeReview state :threads" => @shown,
      "HalC2Plugins.CodeReview state :snapshot" =>
        "the `reviews` last sent to clients, so an unchanged one is not sent again; " <>
          @shown,
      "HalC2Plugins.CodeReview state :paused_reason" => @shown,
      "HalC2Plugins.CodeReview state :failures" => @pause,
      "HalC2Plugins.CodeReview state :poll_backoff" =>
        "how long until the next look; the model looks at any time",
      "HalC2Plugins.CodeReview state :timer" =>
        "when the next look is; the model looks at any time",
      "HalC2Plugins.CodeReview state :lister" => @shown,
      "HalC2Plugins.CodeReview.Checkout.read/4" => @agent,
      "HalC2Plugins.CodeReview.Checkout.diff_lines/4" => @agent,
      "HalC2Plugins.CodeReview.Checkout.regular?/3" =>
        "whether a commit has a regular file at a path, which the agent's prompt says of .gitmodules; no claim or run state",
      "HalC2Plugins.CodeReview.Checkout.position/4" => @agent,
      "HalC2Plugins.CodeReview.Checkout.submodules/3" =>
        "fills in the submodules of a checkout prepare made, before its claim, and fails nothing; the model's checkout has no files",
      "HalC2Plugins.CodeReview.Checkout.start/0" =>
        "the table of the attempt refs a machine's runs hold, made when its plugin starts; no claim or post goes through it",
      "HalC2Plugins.CodeReview.Checkout.release/0" =>
        "a run lets its attempt's refs go once its review has started; the model's checkout has one head and no refs",
      "HalC2.Plugins.Host.publish/3" => @shown,
      "HalC2.Plugins.Host.data_dir/1" => @host,
      "HalC2.Plugins.Host.stop_thread/2" => @agent,
      "HalC2.Plugins.Host.projects/1" => @look,
      "HalC2.Plugins.Host.providers/1" => @host,
      "HalC2.Plugins.Host.issues/3" => @host,
      "HalC2.Plugins.Host.open_pull_request/3" => @host,
      "HalC2.Plugins.Host.thread/2" => @agent,
      "HalC2.Plugins.Host.threads/1" => @rows,
      "HalC2.Plugins.Host.watch_threads/1" => @rows,
      "HalC2Plugins.CodeReview handle_call {:run, _, _}" => @agent,
      "HalC2.Plugins.Host.launch_thread/4" => @agent,
      "HalC2.Plugins.Host.organize_thread/3" => @shown,
      "HalC2.Plugins.Host.granted?/2" => @host,
      "HalC2.Plugins.Host.slack/3" => @host,
      "HalC2.Plugins.Host.close_sandbox/3" => @agent,
      "HalC2.Plugins.Host.sandbox_ended/2" => @agent,
      "HalC2Plugins.CodeReview.sandboxed?/2" => @host,
      "HalC2Plugins.CodeReview handle_call {:stop, _}" => @user,
      "HalC2Plugins.CodeReview handle_call {:untake, _}" => @stop,
      "HalC2Plugins.CodeReview.untake/1" => @stop,
      "HalC2.Plugins.Host.pull_request_trust/2" => @trust,
      "HalC2.Plugins.Host.pull_request_fetch/2" =>
        "where a Forgejo checkout fetches from and with what token; read before the checkout, it fails the run before any claim as a failed checkout does, which the model has",
      "HalC2.Plugins.Host.left_cluster?/2" =>
        "a machine the user switched off or removed from the cluster stops counting with the others; the model's machines stay in it",
      "HalC2.Plugins.Host.steer/4" => @host,
      "HalC2.Plugins.Host.notice/5" => @shown,
      "HalC2.Plugins.Host.generate/3" => @host,
      "HalC2.Plugins.Host.history/3" => @host,
      "HalC2.Plugins.Host.project_threads/2" => @host,
      "HalC2.Plugins.Host.thread_project/2" => @host,
      "HalC2.Plugins.Host.feed_backlog/1" => @host,
      "HalC2.Plugins.Host.run_active?/3" => @host,
      "HalC2.Plugins.Host.provider_instances/3" => @host,
      "HalC2.Plugins.Host.added_instances/2" => @host,
      "HalC2.Plugins.Host.released_instances/2" => @host,
      "HalC2.Plugins.Host.seal_records/3" => @host
    },
    environment: %{
      "push" => "a commit is pushed to the pull request",
      "crash" => "a machine goes down, and its connections and the locks held on it",
      "bounce" => "the plugin's server alone goes down, its node connected throughout",
      "restart" => "the plugin, and its machine if down, come back: init/1 and load/0",
      "partition" => "a connection drops",
      "mute" =>
        "a connected machine does not answer the others' Host.peers/4 in time, too busy, say",
      "unmute" => "it answers again, telling no one",
      "connect" => "Discovery connects two machines that are up",
      "break" =>
        "a machine that could open review sandboxes no longer can: its gateway or container runtime stopped, say"
    },
    scenarios: %{
      "source-control/agent-code-review.feature" => [
        "Two machines watching the same repository review a pull request once",
        "A machine on its own reviews",
        "The review moves to another machine when its machine leaves before starting it",
        "The review moves to another machine when its machine's agent reaches its usage limit",
        "A commit two machines reviewed while apart is posted once",
        "A commit a machine posted just before it restarted is published without posting it again",
        "Machines out of each other's reach each have only their share of the limits",
        "A machine that cannot run review sandboxes leaves the review to one that can",
        "A review that needs a sandbox fails when no machine of the cluster can run it"
      ]
    }

  # The code's own steps, which do not stop while they can happen. The end of a pause
  # is not among them: the reviews get done without it.
  @fair ~w(look peers polled checkout claim lock started defer elsewhere nodedown
           peer-claims elsewhere-seen)

  # The same with a machine that cannot open review sandboxes handing its runs over.
  # Its checks are tagged as shards, which CI runs as jobs of their own: with the rest
  # they outrun one job.
  @handing ~w(handoff offer) ++ @fair

  # The plugin is loaded by the plugin host at run time; the facts need its compiled
  # module, docs included.
  setup_all do
    plugin = Path.expand("../../../../plugins/code-review/mc", __DIR__)
    dir = Path.join(Mix.Project.build_path(), "proof-plugins/code-review")
    files = Enum.map(~w(checkout.ex code_review.ex), &Path.join(plugin, &1))
    HalC2.Proof.compile_plugin(files, dir)
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

  # The limit of two between two machines, apart, restarting or down at any step; of
  # three between three.
  @limited ~w[limited(2,2,0,0) limited(2,1,1,0) limited(2,1,0,1) limited(3,2,0,0) limited3(1,0)]

  test "machines out of each other's reach run no more reviews than the limits allow",
       %{proof: proof} do
    for init <- @limited, do: refute_reachable(proof, init, "unsafe", [])
  end

  # Members of the cluster that have never answered each other, which may meet at any
  # step: with the machines the limits count with learned only from those that answered,
  # each spends the whole limit (strangers(2,0,0) runs three reviews against two).
  @strangers ~w[strangers(2,0,0) strangers(2,1,0) strangers(2,0,1) strangers(3,1,0) stranger3(0)]

  test "members of a cluster that never met run no more reviews than the limits allow",
       %{proof: proof} do
    for init <- @strangers, do: refute_reachable(proof, init, "unsafe", [])
  end

  # A machine that does not answer in time may stop doing so at any step and answer
  # again at any later one: once for one of the two, twice for both.
  test "no machine claims, starts or posts a commit over a connected machine that does not answer",
       %{proof: proof} do
    for init <- ~w[quiet(1) quiet(2) quietApart(2)],
        do: refute_reachable(proof, init, "unsafe", [])
  end

  test "machines that do not answer each other in time run no more reviews than the limits allow",
       %{proof: proof} do
    for init <- ~w[hushed(2,2) hushed(3,1)], do: refute_reachable(proof, init, "unsafe", [])
  end

  test "a machine that stepped back for one that did not answer leaves it the review",
       %{proof: proof} do
    assert_ltl(proof, "quiet(1)", "<> [] reviewed", fair: ["unmute" | @fair])
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

  # A machine that cannot open review sandboxes, and one that can: a periodic look, and
  # apart from it pushes, crashes, partitions, plugin restarts, usage limits, the one
  # that can finding it cannot after all, and a machine not answering the offer in
  # time. A periodic look with any of the others runs past minutes.
  @boxless ~w[boxless(1,0,0,0,0,0,0,0) boxless(0,1,0,0,0,0,0,0) boxless(0,0,1,0,0,0,0,0)
              boxless(0,0,0,1,0,0,0,0) boxless(0,0,0,0,1,0,0,0) boxless(0,0,0,0,0,1,0,0)
              boxless(0,0,0,0,0,0,1,0) boxless(0,0,0,0,0,0,0,1)]

  for init <- @boxless do
    @tag shard: :handoff
    test "no machine claims, starts or posts a commit a connected machine it locked has, as one hands its run over, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "unsafe", [])
    end
  end

  @tag shard: :handoff
  test "a machine that cannot run review sandboxes leaves the review to one that can",
       %{proof: proof} do
    assert_ltl(proof, "handed(0,inf)", "<> [] boxed", fair: @handing)
  end

  # One test per start: each gets a Maude of its own, and a check in one that searched
  # before pays for that search's memory.
  # A shard of their own: gone(0,1,0) alone takes a quarter of the rest.
  for init <- ~w[gone(1,0,0) gone(0,1,0)] do
    @tag shard: :leaving
    test "the review moves on when the machine that took it leaves before starting it, from #{init}",
         %{proof: proof} do
      assert_ltl(proof, unquote(init), "[] steady(a) -> <> [] boxed", fair: @handing)
    end
  end

  # A machine that finds it cannot after all hands the run on if it finds out before
  # its claim, and otherwise fails it there: either way the review settles on a machine,
  # which says why it failed, and does not go back and forth. handed(1,1) looks once more
  # after the first looks; with looks forever the search runs past half an hour on a
  # runner, and with more of them, longer.
  for init <- ~w[handed(1,1) gone(0,0,1) gone(0,0,2)] do
    @tag shard: :handoff
    test "a review settles when the machine that took it cannot open its sandbox after all, from #{init}",
         %{proof: proof} do
      assert_ltl(proof, unquote(init), "<> [] settled", fair: ["sandbox-failed" | @handing])
    end
  end

  for init <- ~w[stranded(1,0) stranded(0,1)] do
    @tag shard: :handoff
    test "no machine claims a commit twice as the machines that took it go or cannot, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "unsafe", [])
    end
  end
end
