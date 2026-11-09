# The plugin's MC modules are compiled when the plugin starts, not with the MC: compiled
# here to beams of their own, which keep the docs and source the coverage reads.
"../../../../plugins/token-economizer/mc/*.ex"
|> Path.expand(__DIR__)
|> Path.wildcard()
|> HalC2.Proof.compile_plugin(Path.join(Mix.Project.build_path(), "plugins/token-economizer"))

defmodule HalC2.TokenEconomizerLoopGuardProofTest do
  # TokenEconomizer's loop guard: one thread's turns, heard by the plugin through a feed
  # that may miss an event, with judge verdicts that come back late or never, judge jobs
  # going stale, and redirects and notices delivered by a task of their own, so they may
  # land after their turn ended or the next began, and the MC may refuse a redirect or
  # send it on without hearing it taken.
  # prop/hal_c2/token_economizer_prop_test.exs runs one turn's guard itself.
  #
  # Each part of the design is a switch in the model, and turning one off finds the
  # flaw it closes (each search takes well under a second):
  #
  #   - Taking whichever verdict comes back while a job is out, not the job out's own:
  #     a job put out before a redirect answers after the next segment's job went out,
  #     and the new segment is redirected or offered a stop on what the agent did
  #     before the redirect. Verdicts are keyed to their job.
  #   - A redirect that keeps the job out, or the verdict already back: either is read
  #     in the new segment, with the same result. A redirect starts its segment clean.
  #   - A guard that goes on deciding after its stop offer offers the turn a stop again
  #     at its next stuck call.
  #   - A job that never answers blocks the judge for the rest of the turn, and a turn
  #     stuck for good is never redirected nor offered a stop. A job out longer than the
  #     stale time stops blocking.
  #   - A redirect that does not name its run steers the thread's next turn when it is
  #     delivered after its own ended, or runs as a turn of its own when none is under
  #     way. The MC refuses a plugin's redirect once its run is over.
  #   - Delivering the redirect's notice before the redirect: the MC refuses the redirect
  #     and the thread says the agent was redirected when it was not. The notice goes
  #     out after the redirect, once the MC took it.
  #   - A turn under way when the feed missed an event (a failing check, say) teaches
  #     the envelope a turn that did not end green. It is partial, and teaches nothing.
  #   - Marking only the turn under way when the feed says it missed one: the feed
  #     misses the newest event and says so on the next it delivers, which it queued
  #     first, so a turn that starts in the events still queued, its failing call
  #     missed, is heard whole and teaches. The turns heard until those are heard are
  #     partial too.
  #   - Teaching every turn that closes teaches the ones that ended failing or that the
  #     person stopped.
  #   - Starting the next segment as the redirect goes out, not once the MC took it: the
  #     next stuck call is offered a stop before the redirect has reached the agent (and
  #     a refused redirect would have spent the segment). Until the task says, the guard
  #     decides nothing, and a refused redirect leaves the segment as it was.
  #   - Leaving a judge job asked when its turn ends, when a redirect starts the next
  #     segment, or when it went stale and a new job replaces it: the judge is paid for
  #     a verdict nobody reads. Its jobs are stopped.
  #   - Counting a redirect the provider's runtime still held unanswered as landed: if it
  #     never hands it over, every later call reads as started before it and decides
  #     nothing, so a turn stuck for good is never offered its stop. One not heard
  #     taken is refused as far as the guard is concerned, and gets no notice.
  #   - Weighing every call heard after the redirect landed in the new segment: a call
  #     already under way when the agent was sent the redirect, whose end the plugin
  #     hears after the task's word, is judged or found stuck in the segment the agent
  #     has not acted in yet. A call that did not start after the place the redirect
  #     landed counts for the turn only, and decides nothing.
  @model "the turn the plugin hears; the MC's side of it is the model's environment"
  @judge "what the judge is told and how its verdict is read, below the model's stuck or productive"
  @text "the words of a redirect or a notice; the model delivers them, whatever they say"
  @calls "how the guard counts a call, below the model's sign of trouble or none: prop/hal_c2/token_economizer_prop_test.exs and test/hal_c2/token_economizer_loop_guard_test.exs"

  use HalC2.Proof,
    model: "token_economizer_loop_guard.maude",
    module: "TOKEN-ECONOMIZER-LOOP-GUARD",
    check: "TOKEN-ECONOMIZER-LOOP-GUARD-PROPS",
    timeout: 600_000,
    code: [
      {:exports, HalC2Plugins.TokenEconomizer},
      {:messages, HalC2Plugins.TokenEconomizer},
      {:state, HalC2Plugins.TokenEconomizer},
      {:exports, HalC2Plugins.TokenEconomizer.LoopGuard.Turn}
    ],
    covers: %{
      "HalC2Plugins.TokenEconomizer handle_call {:observe, _}" =>
        ~w(hear-start hear-finish hear-other calm early backstop judge mark close),
      "HalC2Plugins.TokenEconomizer handle_info {:verdict, _, _, _, _}" => ~w(verdict arrive),
      "HalC2Plugins.TokenEconomizer handle_info {:delivered, _, _, _, _}" => "steered",
      "HalC2Plugins.TokenEconomizer state :turns" => ~w(watching turn),
      "HalC2Plugins.TokenEconomizer state :missing" => "gap",
      "HalC2Plugins.TokenEconomizer state :trackers" => ~w(taught close),
      "HalC2Plugins.TokenEconomizer state :settings" => ~w(cfg budget),
      "HalC2Plugins.TokenEconomizer state :tasks" => ~w(task asking drop),
      "HalC2Plugins.TokenEconomizer.learns?/2" => ~w(close taught),
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.new/1" => "fresh",
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.fold/6" =>
        ~w(calm early backstop judge see act ask),
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.verdict/3" => ~w(verdict arrive),
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.redirect/1" => "act",
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.redirected/3" => ~w(steered seg heard),
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.resolved_proxy/2" => ~w(close see),
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.judge_stale_s/0" => "stale"
    },
    abstracts: %{
      "HalC2Plugins.TokenEconomizer handle_call {:settings, _}" =>
        "the settings are fixed for a run of the model; a change reads the trackers afresh and, with the guard and learning both off, drops the turns",
      "HalC2Plugins.TokenEconomizer handle_call :status" => "reads the counts, changes nothing",
      "HalC2Plugins.TokenEconomizer handle_call {:micro_skills, _}" =>
        "reads a project's learned facts, changes nothing the guard decides; their lifecycle is prop/hal_c2/token_economizer_micro_skills_prop_test.exs",
      "HalC2Plugins.TokenEconomizer handle_call {:micro_skill_drop, _}" =>
        "a person's word drops a learned fact; the guard never reads the facts",
      "HalC2Plugins.TokenEconomizer handle_call {:micro_skill_restore, _}" =>
        "a person's word restores a dropped fact; the guard never reads the facts",
      "HalC2Plugins.TokenEconomizer handle_call {:shape_run, _, _}" =>
        "stages learned facts ahead of a new conversation's first message; it neither steers nor notices a turn under way, and decides nothing for the guard",
      "HalC2Plugins.TokenEconomizer handle_info _" => "any other message is ignored",
      "HalC2Plugins.TokenEconomizer handle_info :sweep" =>
        "drops a turn whose run the MC says ended, its end lost, closing it as the next turn's start does (`hear-start`, `close`): prop/hal_c2/token_economizer_plugin_prop_test.exs",
      "HalC2Plugins.TokenEconomizer state :active?" =>
        "how a sweep asks the MC whether a run is under way",
      "HalC2Plugins.TokenEconomizer state :ended" =>
        "the runs the last sweep found ended, which decide only when a lost end's turn is dropped",
      "HalC2Plugins.TokenEconomizer state :sweep" => "the next sweep's timer",
      "HalC2Plugins.TokenEconomizer handle_info {:DOWN, _, :process, _, _}" =>
        "forgets a task that ended; what it did came in a message of its own",
      "HalC2Plugins.TokenEconomizer state :sup" =>
        "the supervisor of the plugin's tasks, which end with the plugin",
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.after_nudge/1" =>
        "watching decides as if each redirect were taken at once, and delivers nothing; the model delivers",
      "HalC2Plugins.TokenEconomizer state :stats" => "counts for the topic, which decide nothing",
      "HalC2Plugins.TokenEconomizer state :skills" =>
        "what each project's turns taught the micro-skills; folded as a turn closes, read by nothing the guard decides",
      "HalC2Plugins.TokenEconomizer state :known_skills" =>
        "the projects with learned facts, for the listing; the guard never reads it",
      "HalC2Plugins.TokenEconomizer state :published_skills" =>
        "the shape of the listing last published, so an unchanged one is not sent again; it decides nothing",
      "HalC2Plugins.TokenEconomizer state :staged" =>
        "the fact ids staged for a thread's conversation, for counting the waste they prevented; the guard never reads them",
      "HalC2Plugins.TokenEconomizer state :staged_order" =>
        "the staged conversations' order, for keeping only the latest; the guard never reads it",
      "HalC2Plugins.TokenEconomizer state :recent" =>
        "the latest actions for the topic, which decide nothing",
      "HalC2Plugins.TokenEconomizer.status/1" => "what the topic carries, which decides nothing",
      "HalC2Plugins.TokenEconomizer.envelope_path/1" =>
        "where a project's envelope is kept; the model keeps what it taught",
      "HalC2Plugins.TokenEconomizer.staged_path/0" =>
        "where what each conversation was staged is kept; the guard never reads it",
      "HalC2Plugins.TokenEconomizer.micro_skills_path/1" =>
        "where a project's learned facts are kept; their lifecycle is prop/hal_c2/token_economizer_micro_skills_prop_test.exs",
      "HalC2Plugins.TokenEconomizer.call_of/1" => @calls,
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.judge_base_gap/0" =>
        "the judge's rate limit only spaces jobs out by calls, which a stuck turn keeps making",
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.live_digest/2" => @judge,
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.verification_state/1" => @judge,
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.runner_verdict/1" => @calls,
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.status_of_tests/1" => @calls,
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.exit_status_covers/1" => @calls,
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.summary/2" => "what the log says of a turn",
      "HalC2Plugins.TokenEconomizer.LoopGuard.Turn.nudge_body/1" => @text
    },
    environment: %{
      "start" => @model <> ": the MC starts the thread's next turn",
      "call" => @model <> ": the agent makes a call, a check that fails or anything else",
      "finish" => @model <> ": the agent ends its turn",
      "interrupt" => @model <> ": the person stops the turn from the stop offer",
      "drop" =>
        "the feed misses the newest event, one that found its queue full, and says so with the next it delivers",
      "answer" => "the judge, the user's text model, answers its job",
      "lose" => "a judge job that never answers",
      "refuse" =>
        "the MC refuses a redirect, as Host.steer/4 does for a provider that cannot take a message while it works",
      "hold" =>
        "the provider's runtime does not answer a steer in time and still holds it (HalC2.RuntimeSteer), so Host.steer/4's receipt says it is not confirmed",
      "late" => "the provider's runtime hands a steer it held to its run, still under way",
      "lose-held" =>
        "the provider's runtime never hands on a steer it held, its turn no longer the current one",
      "deliver" =>
        "the plugin's delivery task, Host.notice/5 and Host.steer/4 through the MC; a notice lands in a run that ended, a plugin's steer only in its run while it is under way"
    },
    scenarios: %{
      "plugins/token-economizer-loop-guard.feature" => [
        "A stuck turn is redirected once and the thread says so",
        "With no redirects allowed, a stuck turn is offered a stop and goes on until the person stops it",
        "Only a turn that ended green teaches the project's envelope"
      ]
    }

  # Keyed, Reset, Once, Stale, Aimed, Told, Whole, Green, Window, Landed, Cancel, Early.
  @design "true, true, true, true, true, true, true, true, true, true, true, true"
  # After the switches: the budget, the calls each turn makes, the turns, the events the
  # feed may miss, the judge jobs that may never answer, whether one that answers may go
  # stale first, whether the judge may find a turn productive, and whether every call
  # goes to the judge.
  @two_turns "2, 2, 1, 1, true, true, false"
  @faults ~w(drop lose)

  # A verdict is read only in its own segment, a redirect lands only in its turn and its
  # notice only after it, a stop is offered at most once and never before the redirect
  # landed, no call under way when it landed is weighed after it, no judge job outlives
  # its segment, and only a green turn heard whole teaches. A redirect the provider's
  # runtime holds (holding/2) lands late, in its own run, or never.
  test "over two turns, with an event missed, a judge job lost and a redirect refused or held, the guard is safe",
       %{proof: proof} do
    refute_reachable(proof, "holding(1, start(#{@design}, 1, #{@two_turns}))", "unsafe", [])
  end

  test "with no redirects allowed the same holds", %{proof: proof} do
    refute_reachable(proof, "start(#{@design}, 0, #{@two_turns})", "unsafe", [])
  end

  # A verdict from before a redirect needs a job out, the redirect, then a call to read
  # it in: four calls in one turn.
  test "in one long turn, no verdict from before a redirect is read after it", %{proof: proof} do
    refute_reachable(proof, "start(#{@design}, 1, 4, 1, 1, 1, true, true, false)", "unsafe", [])
  end

  test "turns never get stuck, with an event missed and a judge job lost", %{proof: proof} do
    refute_deadlock(proof, "start(#{@design}, 1, #{@two_turns})", "over", besides: @faults)
  end

  test "in one long turn with a judge job lost, a held redirect keeps the guard safe",
       %{proof: proof} do
    refute_reachable(
      proof,
      "holding(1, start(#{@design}, 1, 3, 1, 0, 1, true, true, false))",
      "unsafe",
      []
    )
  end

  # A held redirect doubles the two-turn search for a stuck state, too close to its
  # timeout, and it lands only in its own run, so its turn is searched alone, with every
  # fault.
  test "a turn whose redirect its runtime holds never gets stuck, with an event missed and a judge job lost",
       %{proof: proof} do
    refute_deadlock(
      proof,
      "holding(1, start(#{@design}, 1, 3, 1, 1, 1, true, true, false))",
      "over",
      besides: @faults
    )
  end

  test "every turn closes when the feed misses nothing", %{proof: proof} do
    assert_ltl(proof, "start(#{@design}, 1, 2, 2, 0, 1, true, true, false)", "<> finished", [])
  end

  # A turn that calls for good is an infinite state space unless a job that answers
  # answers before it goes stale; the searches above cover the late answers.
  test "a turn stuck for good is redirected, then offered a stop the person takes, even when a judge job never answers",
       %{proof: proof} do
    assert_ltl(proof, "start(#{@design}, 1, loop, 1, 0, 1, false, false, true)", "<> finished",
      fair:
        ~w(start call hear-start hear-finish judge answer stale verdict deliver steered interrupt)
    )
  end

  # Counting a held redirect as landed fails here: held, never handed over, every later
  # call reads as started before it.
  test "a turn stuck for good whose redirect its runtime holds, and never hands over, is still offered a stop",
       %{proof: proof} do
    assert_ltl(
      proof,
      "holding(1, start(#{@design}, 1, loop, 1, 0, 1, false, false, true))",
      "<> finished",
      fair:
        ~w(start call hear-start hear-finish judge answer stale verdict deliver steered interrupt)
    )
  end
end
