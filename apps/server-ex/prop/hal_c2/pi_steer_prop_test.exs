defmodule HalC2.PiSteerPropTest do
  @moduledoc """
  A state machine over one Pi thread (`HalC2.Pi.ThreadRuntime`) driven through the
  orchestration commands a client sends: send a message whose turn works (after a tool
  that returns an image, or one that hands tasks to Pi's own subagents, or not) until it is steered or stopped (or Pi aborts it itself, which reads as interrupted), either taking the steer into its running work or settling just
  before the steer lands (so Pi answers it in a run of its own), or just before two
  steers sent at once land; steer the running turn, with a message Pi takes, one it
  refuses, one it refuses only once the run settled (which finds the turn over, so it
  is sent as a message of its own), one Pi exits on before answering (which fails
  the turn, so it is sent on its own too), or one Pi never answers once the run settled
  (which the runtime takes as taken once its answer budget, shortened here, runs out);
  steer it twice at once, including a declined steer held behind one Pi never answers
  (in either order); steer it twice staggered, the second dispatched while the first
  is still in flight, so a held refusal outlives the first steer's own answer budget;
  steer `/compact` and stop the turn while the compaction runs, then run a turn
  during which the abandoned compaction's late events land (Pi's `abort` does not
  stop a compaction) followed by that turn's own compaction; or stop it while a
  compaction that fails without any events runs, so only the task's own reply ends
  the abandonment, and the next compaction must still show; send a message while the
  abandoned compaction still runs, which Pi starts only once it ends and shows nothing
  for until then (the turn watchdog must not settle it as idle); send a message Pi's
  extensions take a few seconds to start on, plainly or through a prompt template,
  reading idle all the while (it must not be settled as idle either); send a message
  while Pi compacts after the turn before it, which Pi 1.4 rejects, so it waits for the
  compaction to end and is then delivered once (also when Pi says it compacts only as
  that message reaches it: with history to hand over, the compaction it then shows
  confirms none of it); steer a turn while it compacts, which
  holds the steer until the compaction ends, or stop that turn with the steer still
  held, which Pi must then never take; interrupt it. Send a message after whose turn
  a Pi extension wakes Pi, which runs as a turn of its own (or which settles before
  its run comes, and whose run is then cancelled from the queue, after which Pi's
  next wake still gets a run; or which settles while its run's delivery still tries,
  after which Pi wakes again, and the first delivery is refused, so the second run
  shows both; or which Pi exits at before its run comes, after which a new Pi wakes,
  and the first run still ends failed; or whose delivery the thread refuses while a
  later turn runs; or which Pi exits at, after which a new Pi's wake joins it, and one
  of the two deliveries is refused, the later once the earlier's run took the cut part,
  or the earlier before the later's run takes it); or one after which Pi
  resumes an extension's work without a word, so the next message Pi turns back as
  busy and HAL-C2 queues it behind that work, in the same turn (and, with history to
  hand over, the work Pi does before it delivers the message confirms none of it). Send two messages,
  then an extension command that moves Pi's session back to before the second
  (`navigateTree`): only the second's run is rolled back, and the turns after find
  their place in Pi's session past the branch it abandoned.

  Turns run on the fake `pi --mode rpc` in `test/support/fake_pi_rpc.py`. The model
  checks that each turn ends once, with the status it should, that every steer's
  answer is recorded in the thread, whichever way Pi ran it, that a steer Pi refused
  is an error for its sender that leaves the turn running, that no compaction
  shows in a turn except that turn's own, that an image a tool returned is stored
  with the thread and listed on that turn's tool item, and that each task a turn
  handed Pi's own subagents shows the way it ended, or, still working, ends with
  its turn, and that a wake the runtime keeps work for waits only on deliveries still
  pending (none once a command has run; the wake commands also check as they go).
  Messages resent on their own
  at once may run in either order, so runs and replies compare as sets. After each command the test
  waits on the thread's stream until the runs it ended have ended and a running turn
  began saying "Working on it.".
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "pi-thread"
  @model %{"instanceId" => "pi", "model" => "fake/one"}
  @fake_pi Path.expand("../../test/support/fake_pi_rpc.py", __DIR__)
  # A 1x1 PNG, the image the "shows" turn's tool returns.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  @turns [
    %{"match" => "joins", "steps" => [%{"text" => "Working on it."}, %{"waitAbort" => true}]},
    # A "joins" turn whose tool first returns an image: it is stored with the thread.
    %{
      "match" => "shows",
      "steps" => [
        %{
          "tool" => "screenshot",
          "content" => [
            %{"type" => "text", "text" => "Took it."},
            %{"type" => "image", "data" => @png, "mimeType" => "image/png"}
          ],
          "details" => %{"width" => 1}
        },
        %{"text" => "Working on it."},
        %{"waitAbort" => true}
      ]
    },
    # A "joins" turn that first hands three tasks to Pi's own subagents (its example
    # extension): one has finished, one exited with an error, one works on with the turn.
    %{
      "match" => "delegates",
      "steps" => [
        %{
          "event" => %{
            "type" => "tool_execution_start",
            "toolCallId" => "call-subagent",
            "toolName" => "subagent",
            "args" => %{}
          }
        },
        %{
          "event" => %{
            "type" => "tool_execution_update",
            "toolCallId" => "call-subagent",
            "toolName" => "subagent",
            "partialResult" => %{
              "details" => %{
                "results" => [
                  %{"agent" => "a", "task" => "one", "finished" => true, "exitCode" => 0},
                  %{"agent" => "b", "task" => "two", "finished" => true, "exitCode" => 1},
                  %{"agent" => "c", "task" => "three", "exitCode" => -1}
                ]
              }
            }
          }
        },
        %{"text" => "Working on it."},
        %{"waitAbort" => true}
      ]
    },
    %{"match" => "ends", "steps" => [%{"text" => "Working on it."}, %{"settleOnSteer" => 1}]},
    %{"match" => "pair", "steps" => [%{"text" => "Working on it."}, %{"settleOnSteer" => 2}]},
    # The abandoned compaction's late events land in this turn while its
    # task is still out (the fake's 30-second answer never arrives), followed
    # by a compaction of this turn's own: both are dropped while it is out.
    %{
      "match" => "late",
      "steps" => [
        %{"text" => "Working on it."},
        %{"event" => %{"type" => "compaction_start", "reason" => "manual"}},
        %{
          "event" => %{
            "type" => "compaction_end",
            "aborted" => false,
            "result" => %{
              "summary" => "The stopped compaction.",
              "tokensBefore" => 1000,
              "estimatedTokensAfter" => 200
            }
          }
        },
        %{"event" => %{"type" => "compaction_start", "reason" => "manual"}},
        %{
          "event" => %{
            "type" => "compaction_end",
            "aborted" => false,
            "result" => %{
              "summary" => "This turn's compaction.",
              "tokensBefore" => 1000,
              "estimatedTokensAfter" => 200
            }
          }
        },
        %{"text" => "Done."}
      ]
    },
    # A turn Pi starts only once the compaction it is still finishing ends:
    # until then it shows nothing and calls itself neither streaming nor
    # (by `isStreaming`) busy, only `isCompacting`.
    %{
      "match" => "behind",
      "afterCompaction" => true,
      "steps" => [%{"text" => "Working on it."}, %{"waitAbort" => true}]
    },
    # A turn whose agent starts only after its extensions' hooks ran for a
    # while (2.5 s: over two of the watchdog's 1 s idle checks), then works
    # as a "joins" turn does.
    %{
      "match" => "slow",
      "startDelaySec" => 2.5,
      "steps" => [%{"text" => "Working on it."}, %{"waitAbort" => true}]
    },
    # A turn Pi aborts itself (an extension, a compaction, a session swap):
    # it reads as interrupted though nobody stopped it.
    %{
      "match" => "aborts",
      "steps" => [
        %{"text" => "Working on it."},
        %{
          "event" => %{
            "type" => "message_end",
            "message" => %{"role" => "assistant", "stopReason" => "aborted"}
          }
        }
      ]
    },
    # A turn Pi compacts in before it works on: a steer sent then waits for the
    # compaction to end (Pi 1.4 rejects any prompt while it compacts).
    %{
      "match" => "compacts",
      "steps" => [%{"text" => "Working on it."}, %{"compactFor" => 1.5}, %{"waitAbort" => true}]
    },
    # As "compacts", with a compaction that outlasts the stop's grace.
    %{
      "match" => "holds",
      "steps" => [%{"text" => "Working on it."}, %{"compactFor" => 20}, %{"waitAbort" => true}]
    },
    # A turn after which Pi compacts for a while (its own threshold compaction).
    %{
      "match" => "aftercompact",
      "compactAfter" => 3,
      "steps" => [%{"text" => "Done."}]
    },
    # As "aftercompact", but Pi says it compacts only as the next prompt reaches it
    # (held until the test lets it), just before turning that prompt back.
    %{
      "match" => "unheard",
      "compactAfter" => 3,
      "compactUnheard" => true,
      "compactUnheardUntil" => "unheard-go",
      "steps" => [%{"text" => "Done."}]
    },
    # A turn after which a Pi extension wakes Pi: the work is a turn of its own.
    %{
      "match" => "wakes",
      "steps" => [%{"text" => "Done."}],
      "wake" => %{"text" => "Continue.", "steps" => [%{"text" => "Woke up."}]}
    },
    # A turn after which a Pi extension wakes Pi to work until stopped.
    %{
      "match" => "hands",
      "steps" => [%{"text" => "Done."}],
      "wake" => %{
        "text" => "Carry on.",
        "steps" => [%{"text" => "Carrying on."}, %{"waitAbort" => true}]
      }
    },
    # A turn after which a Pi extension wakes Pi, which exits once the file
    # "exit-now" exists.
    %{
      "match" => "strays",
      "steps" => [%{"text" => "Done."}],
      "wake" => %{
        "text" => "Carry on.",
        "steps" => [%{"text" => "Going on."}, %{"until" => "exit-now"}, %{"exit" => 1}]
      }
    },
    # A turn after which a Pi extension wakes Pi twice, the second time once the
    # first wake settled and the file "wake-again" exists.
    %{
      "match" => "twice",
      "steps" => [%{"text" => "Done."}],
      "wake" => %{
        "text" => "Continue.",
        "steps" => [%{"text" => "Woke up."}],
        "wake" => %{
          "text" => "Continue again.",
          "startUntil" => "wake-again",
          "steps" => [%{"text" => "Woke again."}]
        }
      }
    },
    # A turn after which a Pi extension wakes Pi to say something else.
    %{
      "match" => "dozes",
      "steps" => [%{"text" => "Done."}],
      "wake" => %{"text" => "Continue.", "steps" => [%{"text" => "Dozed off."}]}
    },
    # A turn after which Pi resumes an extension's work, saying nothing until a
    # prompt reaches it.
    # A turn after which Pi resumes an extension's work without a word, and runs a
    # command once a message follows it, but only once the file "follow-go" exists;
    # it delivers the message once "follow-deliver" does.
    %{
      "match" => "follows",
      "steps" => [%{"text" => "Done."}],
      "wake" => %{
        "text" => "Continue.",
        "quiet" => true,
        "steps" => [
          %{"waitFollowUp" => true},
          %{"answerFollowUps" => "follow-go"},
          %{"tool" => "bash", "args" => %{"command" => "make lint"}, "output" => "ok"},
          %{"answerFollowUps" => "follow-deliver"}
        ]
      }
    },
    %{
      "match" => "quietly",
      "steps" => [%{"text" => "Done."}],
      "wake" => %{"text" => "Continue.", "quiet" => true, "steps" => [%{"text" => "Resumed."}]}
    },
    # A turn that compacts on its own (an auto-compaction): its compaction shows.
    %{
      "match" => "own",
      "steps" => [
        %{"text" => "Working on it."},
        %{"event" => %{"type" => "compaction_start", "reason" => "threshold"}},
        %{
          "event" => %{
            "type" => "compaction_end",
            "aborted" => false,
            "result" => %{
              "summary" => "This turn's compaction.",
              "tokensBefore" => 1000,
              "estimatedTokensAfter" => 200
            }
          }
        },
        %{"text" => "Done."}
      ]
    }
  ]
  @finished ~w(completed failed interrupted cancelled rolled_back)
  @active ~w(preparing starting running waiting)
  @wait_ms 10_000
  @answer_ms 2_000

  property "a Pi thread records every steer's answer in the turn it steered",
    numtests: HalC2.Prop.numtests(20),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("pi-steer")
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
        bin = install_fake(home)

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Codex.Registry},
            id: :codex_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
            id: :claude_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
            id: :acp_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
            id: :pi_registry
          ),
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
          HalC2.Settings
        ])

        HalC2.Acp.forget("pi")
        Application.put_env(:hal_c2, :pi_steer_answer_ms, @answer_ms)
        # Long enough that a working turn's first event always lands first:
        # the fake calls itself idle whenever it is asked.
        Application.put_env(:hal_c2, :pi_turn_watchdog_ms, 1_000)

        {:ok, _} =
          HalC2.Settings.put(
            %{"providers" => %{"pi" => %{"enabled" => true, "binaryPath" => bin}}},
            0
          )

        create(work)
        Application.put_env(:hal_c2, :pi_prop_fake_dir, Path.join(home, "fake-pi"))
        :ok = HalC2.Streams.subscribe(@tid, self(), nil)
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Acp.forget("pi")
        Application.delete_env(:hal_c2, :pi_steer_answer_ms)
        Application.delete_env(:hal_c2, :pi_turn_watchdog_ms)
        Application.delete_env(:hal_c2, :pi_prop_fake_dir)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # runs: [{msg, status}] in the order they were made; turn: the running turn's msg;
  # how: whether its work takes a steer in, settles as one lands, or as two land;
  # replies: the steers answered, in order; abandoned: a stopped steered compaction
  # still out (`:events`: Pi will finish it and its events land in a later turn;
  # `:replied`: Pi answered it with a failure and no events, so the task's reply
  # alone ended the abandonment and nothing is left to drop);
  # compactions: the compaction summaries shown, in order; images: the turns whose
  # tool returned an image; pending: the ids of the wake deliveries still pending
  # (sent or trying, neither run nor refused), none once a command has run, since each
  # resolves the deliveries it started (the wake commands check them as they go).
  def initial_state,
    do: %{
      pending: [],
      runs: [],
      turn: nil,
      how: nil,
      replies: [],
      next: 1,
      abandoned: :none,
      compactions: [],
      images: [],
      subagents: []
    }

  # With an abandoned compaction still out (its task has not answered),
  # the next turn may be the one its late events land in.
  def command(%{turn: nil, abandoned: :events, next: next}) do
    frequency([
      {2, {:call, __MODULE__, :send_late, [id(next)]}},
      {2, {:call, __MODULE__, :send_behind, [id(next)]}},
      {1, {:call, __MODULE__, :send, [id(next), oneof([:joins, :ends, :pair, :aborts])]}}
    ])
  end

  # With an abandoned compaction answered and gone, the next turn may be one
  # that compacts on its own: that compaction must show.
  def command(%{turn: nil, abandoned: :replied, next: next}) do
    frequency([
      {2, {:call, __MODULE__, :send_own, [id(next)]}},
      {1, {:call, __MODULE__, :send, [id(next), oneof([:joins, :ends, :pair, :aborts])]}}
    ])
  end

  def command(%{turn: nil, next: next}) do
    frequency([
      {5,
       {:call, __MODULE__, :send,
        [id(next), oneof([:joins, :ends, :pair, :aborts, :shows, :delegates])]}},
      {2, {:call, __MODULE__, :send, [id(next), oneof([:compacts, :holds])]}},
      {2,
       {:call, __MODULE__, :send_compacted, [id(next), id(next + 1), oneof([:heard, :unheard])]}},
      {1, {:call, __MODULE__, :send_handled, [id(next)]}},
      {1, {:call, __MODULE__, :send_silent, [id(next)]}},
      {1, {:call, __MODULE__, :send_slow, [id(next), oneof(["", "/review "])]}},
      {1, {:call, __MODULE__, :send_woken, [id(next)]}},
      {1, {:call, __MODULE__, :send_into_wake, [id(next), id(next + 1)]}},
      {1, {:call, __MODULE__, :send_handed_into_wake, [id(next), id(next + 1)]}},
      {1, {:call, __MODULE__, :send_rewound, [id(next), id(next + 1), id(next + 2)]}},
      {1, {:call, __MODULE__, :send_wake_taken, [id(next), id(next + 1), id(next + 2)]}},
      {1, {:call, __MODULE__, :send_wake_settled, [id(next), id(next + 1), id(next + 2)]}},
      {1, {:call, __MODULE__, :send_wake_refused, [id(next), id(next + 1)]}},
      {1, {:call, __MODULE__, :send_wake_superseded, [id(next), id(next + 1)]}},
      {1, {:call, __MODULE__, :send_wake_cut, [id(next), id(next + 1)]}},
      {1,
       {:call, __MODULE__, :send_wake_refused_in_turn, [id(next), id(next + 1), id(next + 2)]}},
      {1,
       {:call, __MODULE__, :send_wake_cut_refused,
        [id(next), id(next + 1), id(next + 2), oneof([:later, :earlier])]}}
    ])
  end

  # A turn waiting behind the abandoned compaction takes no steer: Pi has
  # not started it. It can only be stopped.
  def command(%{how: :behind}), do: {:call, __MODULE__, :interrupt, []}

  # A turn compacting before it works takes a steer once the compaction ends;
  # one whose compaction outlasts the test is stopped with the steer held.
  def command(%{how: :compacts, next: next}), do: {:call, __MODULE__, :steer, [id(next), :taken]}
  def command(%{how: :holds, next: next}), do: {:call, __MODULE__, :steer_held_stop, [id(next)]}

  # A turn that settles as two steers land waits for both: it is steered twice at once,
  # or with a message Pi refuses before it waits on.
  def command(%{how: :pair, next: next}) do
    frequency([
      {3,
       {:call, __MODULE__, :steer_pair,
        [
          id(next),
          id(next + 1),
          oneof([
            {:taken, :taken},
            {:taken, :declined},
            {:declined, :declined},
            {:declined, :joins},
            {:declined, :ignored},
            {:ignored, :declined}
          ])
        ]}},
      {2,
       {:call, __MODULE__, :steer_staggered,
        [id(next), id(next + 1), oneof([{:declined, :ignored}, {:ignored, :declined}])]}},
      {1, {:call, __MODULE__, :steer, [id(next), :refused]}},
      {1, {:call, __MODULE__, :interrupt, []}}
    ])
  end

  def command(%{next: next}) do
    frequency([
      {3, {:call, __MODULE__, :steer, [id(next), :taken]}},
      {1, {:call, __MODULE__, :steer, [id(next), :refused]}},
      {1, {:call, __MODULE__, :steer, [id(next), :declined]}},
      {1, {:call, __MODULE__, :steer, [id(next), :vanishes]}},
      {1, {:call, __MODULE__, :steer, [id(next), :ignored]}},
      {3, {:call, __MODULE__, :steer_compact_stop, [id(next)]}},
      {1, {:call, __MODULE__, :steer_compact_stop_fail, [id(next)]}},
      {1, {:call, __MODULE__, :interrupt, []}}
    ])
  end

  # Padded, so the fake takes two steers sent at once in the order they were made.
  defp id(n), do: "m" <> String.pad_leading(Integer.to_string(n), 3, "0")

  # Pi's compaction events are dropped while an abandoned one is out, so a
  # prompt it rejects would wait on that one's (never sent) answer.
  def precondition(state, {:call, _, :send, [_, how]}) when how in [:compacts, :holds],
    do: state.turn == nil and state.abandoned == :none

  def precondition(state, {:call, _, :send_compacted, _}),
    do: state.turn == nil and state.abandoned == :none

  def precondition(%{turn: turn}, {:call, _, :send, _}), do: turn == nil
  def precondition(%{turn: turn}, {:call, _, :send_handled, _}), do: turn == nil
  def precondition(%{turn: turn}, {:call, _, :send_slow, _}), do: turn == nil

  # A silent turn stops the session, which also ends any abandonment; keep it
  # to when none is out, like a stopped steered compaction.
  def precondition(state, {:call, _, :send_silent, _}),
    do: state.turn == nil and state.abandoned == :none

  def precondition(state, {:call, _, call, _})
      when call in [
             :send_woken,
             :send_into_wake,
             :send_handed_into_wake,
             :send_rewound,
             :send_wake_taken,
             :send_wake_settled,
             :send_wake_refused,
             :send_wake_superseded,
             :send_wake_cut,
             :send_wake_refused_in_turn,
             :send_wake_cut_refused
           ],
      do: state.turn == nil and state.abandoned == :none

  def precondition(state, {:call, _, :send_late, _}),
    do: state.turn == nil and state.abandoned == :events

  def precondition(state, {:call, _, :send_behind, _}),
    do: state.turn == nil and state.abandoned == :events

  def precondition(%{how: :behind}, {:call, _, call, _}), do: call == :interrupt
  def precondition(%{how: :compacts}, {:call, _, call, args}), do: {call, args} |> taken?()
  def precondition(%{how: :holds}, {:call, _, call, _}), do: call == :steer_held_stop
  def precondition(_state, {:call, _, :steer_held_stop, _}), do: false

  def precondition(state, {:call, _, :send_own, _}),
    do: state.turn == nil and state.abandoned == :replied

  def precondition(%{how: how}, {:call, _, :steer_pair, _}), do: how == :pair
  def precondition(%{how: how}, {:call, _, :steer_staggered, _}), do: how == :pair

  # A steered compaction stopped mid-flight needs a turn still working, and
  # no earlier abandoned compaction still out (its late events come first).
  def precondition(state, {:call, _, :steer_compact_stop, _}),
    do: state.how == :joins and state.abandoned == :none

  def precondition(state, {:call, _, :steer_compact_stop_fail, _}),
    do: state.how == :joins and state.abandoned == :none

  def precondition(%{how: :pair}, {:call, _, :steer, [_, kind]}), do: kind == :refused
  # A turn taking a steer in answers it; one that settled as it landed never does.
  def precondition(%{how: how}, {:call, _, :steer, [_, :ignored]}), do: how == :ends
  def precondition(%{turn: turn}, {:call, _, _, _}), do: turn != nil

  defp taken?({:steer, [_, :taken]}), do: true
  defp taken?(_call), do: false

  # Pi aborts this turn itself: it ends interrupted at once.
  def next_state(state, _result, {:call, _, :send, [msg, :aborts]}) do
    %{state | next: state.next + 1, runs: state.runs ++ [{msg, "interrupted"}]}
  end

  # An extension command Pi handles without the agent: no work ever shows,
  # Pi reports idle, and the turn completes.
  def next_state(state, _result, {:call, _, :send_handled, [msg]}) do
    %{state | next: state.next + 1, runs: state.runs ++ [{msg, "completed"}]}
  end

  # Pi reads idle for a few seconds before its agent starts: the turn is
  # not settled as idle, and once started it works as a "joins" turn.
  def next_state(state, _result, {:call, _, :send_slow, [msg, _prefix]}) do
    runs = state.runs ++ [{msg, "running"}]
    %{state | next: state.next + 1, runs: runs, turn: msg, how: :joins}
  end

  # Pi never reports work and stops answering checks: the session is
  # stopped and the turn fails (the next send starts a fresh Pi).
  def next_state(state, _result, {:call, _, :send_silent, [msg]}) do
    %{state | next: state.next + 1, runs: state.runs ++ [{msg, "failed"}], abandoned: :none}
  end

  # The turn completes, then the extension's work runs as a turn of its own.
  def next_state(state, _result, {:call, _, :send_woken, [msg]}) do
    runs = state.runs ++ [{msg, "completed"}, {:woken, "completed"}]
    %{state | next: state.next + 1, runs: runs}
  end

  # The second message, turned back while Pi works unannounced, waits behind that work
  # and shows it in its own turn: no turn of the wake's own.
  def next_state(state, _result, {:call, _, call, [a, b]})
      when call in [:send_into_wake, :send_handed_into_wake] do
    %{state | next: state.next + 2, runs: state.runs ++ [{a, "completed"}, {b, "completed"}]}
  end

  # Pi's extension moved its session back to before `b`: `b`'s run is rolled back, and
  # every earlier one stays as it was.
  def next_state(state, _result, {:call, _, :send_rewound, [a, b, c]}) do
    runs = state.runs ++ [{a, "completed"}, {b, "rolled_back"}, {c, "completed"}]
    %{state | next: state.next + 3, runs: runs}
  end

  # `b` took over the work Pi woke to after `a` and was stopped, and the wake's own run,
  # queued behind it, was cancelled: Pi's next wake, after `c`, runs as a turn of its own.
  def next_state(state, _result, {:call, _, :send_wake_taken, [a, b, c]}) do
    woke = [{a, "completed"}, {b, "interrupted"}, {:woken, "cancelled"}]
    runs = state.runs ++ woke ++ [{c, "completed"}, {:woken, "completed"}]
    %{state | next: state.next + 3, runs: runs}
  end

  # The wake after `a` settled before its run came; `b` ran with the wake left for that
  # run, which queued behind `b` and was cancelled, and `b` was stopped: Pi's next wake,
  # after `c`, runs as a turn of its own.
  def next_state(state, _result, {:call, _, :send_wake_settled, [a, b, c]}) do
    woke = [{a, "completed"}, {b, "interrupted"}, {:woken, "cancelled"}]
    runs = state.runs ++ woke ++ [{c, "completed"}, {:woken, "completed"}]
    %{state | next: state.next + 3, runs: runs}
  end

  # The thread refused the wake after `a`, and Pi exited at that work: no turn shows it,
  # and Pi's next wake, after `c`, runs as a turn of its own.
  def next_state(state, _result, {:call, _, :send_wake_refused, [a, c]}) do
    runs = state.runs ++ [{a, "completed"}, {c, "completed"}, {:woken, "completed"}]
    %{state | next: state.next + 2, runs: runs}
  end

  # Pi woke twice after `a`, and the first wake's delivery was refused: the second's
  # run shows both, and Pi's next wake, after `c`, runs as a turn of its own.
  def next_state(state, _result, {:call, _, :send_wake_superseded, [a, c]}) do
    woke = [{a, "completed"}, {:woken, "completed"}]
    runs = state.runs ++ woke ++ [{c, "completed"}, {:woken, "completed"}]
    %{state | next: state.next + 2, runs: runs}
  end

  # Pi exited at the wake after `a` before its run came: that run ends failed, though a
  # new Pi woke after `c` meanwhile, whose wake runs as a turn of its own.
  def next_state(state, _result, {:call, _, :send_wake_cut, [a, c]}) do
    runs = [{a, "completed"}, {:woken, "failed"}, {c, "completed"}, {:woken, "completed"}]
    %{state | next: state.next + 2, runs: state.runs ++ runs}
  end

  # The wake after `a` settled before its run came, and its delivery was refused while
  # `b` ran, and `b` was stopped: no turn shows the wake, and Pi's next wake, after `c`,
  # runs as a turn of its own.
  def next_state(state, _result, {:call, _, :send_wake_refused_in_turn, [a, b, c]}) do
    woke = [{a, "completed"}, {b, "interrupted"}]
    runs = state.runs ++ woke ++ [{c, "completed"}, {:woken, "completed"}]
    %{state | next: state.next + 3, runs: runs}
  end

  # Pi exited at the wake after `a`, and a new Pi's wake after `c` joined it. With the
  # later delivery refused once the earlier's run took the cut part (which ends
  # failed), the new Pi's work shows in no turn; with the earlier delivery refused, the
  # later's run takes the cut part, and the new Pi's work gets a run of its own. Either
  # way, Pi's next wake, after `d`, runs as a turn of its own.
  def next_state(state, _result, {:call, _, :send_wake_cut_refused, [a, c, d, which]}) do
    rest = if which == :earlier, do: [{:woken, "completed"}], else: []
    woke = [{a, "completed"}, {:woken, "failed"}, {c, "completed"}] ++ rest
    runs = state.runs ++ woke ++ [{d, "completed"}, {:woken, "completed"}]
    %{state | next: state.next + 3, runs: runs}
  end

  # Once its tool returned the image, a "shows" turn works as a "joins" turn.
  def next_state(state, _result, {:call, _, :send, [msg, :shows]}) do
    runs = state.runs ++ [{msg, "running"}]

    %{
      state
      | next: state.next + 1,
        runs: runs,
        turn: msg,
        how: :joins,
        images: state.images ++ [msg]
    }
  end

  # Its subagents that ended keep their ending; the one still working ends with
  # the turn (`:with_run`).
  def next_state(state, _result, {:call, _, :send, [msg, :delegates]}) do
    runs = state.runs ++ [{msg, "running"}]
    subagents = [{msg, "completed"}, {msg, "failed"}, {msg, :with_run}]

    %{
      state
      | next: state.next + 1,
        runs: runs,
        turn: msg,
        how: :joins,
        subagents: state.subagents ++ subagents
    }
  end

  def next_state(state, _result, {:call, _, :send, [msg, how]}) do
    runs = state.runs ++ [{msg, "running"}]
    %{state | next: state.next + 1, runs: runs, turn: msg, how: how}
  end

  # The abandoned compaction's events land in this turn while its task is
  # still out, so they show nothing — and neither does a compaction of this
  # turn's own right after them: only the task's reply (or Pi going away)
  # ends the abandonment, and this one's reply never lands. The turn itself
  # runs to its end.
  def next_state(state, _result, {:call, _, :send_late, [msg]}) do
    %{state | next: state.next + 1, runs: state.runs ++ [{msg, "completed"}]}
  end

  # Pi shows nothing for this turn while it finishes the abandoned
  # compaction, which outlasts the test: the turn runs on, not settled as
  # idle. Stopped, Pi drops it before it starts; the compaction runs on.
  def next_state(state, _result, {:call, _, :send_behind, [msg]}) do
    runs = state.runs ++ [{msg, "running"}]
    %{state | next: state.next + 1, runs: runs, turn: msg, how: :behind}
  end

  # The abandoned compaction is already answered and gone, so this turn's
  # own compaction shows as it would have. The turn runs to its end.
  def next_state(state, _result, {:call, _, :send_own, [msg]}) do
    %{
      state
      | next: state.next + 1,
        runs: state.runs ++ [{msg, "completed"}],
        abandoned: :none,
        compactions: state.compactions ++ ["This turn's compaction."]
    }
  end

  # Staggered or at once, the pair's outcomes are the same.
  def next_state(state, result, {:call, mod, :steer_staggered, args}),
    do: next_state(state, result, {:call, mod, :steer_pair, args})

  # Pi takes the first, then the second, each after the run settled.
  def next_state(state, _result, {:call, _, :steer_pair, [a, b, kinds]}) do
    state = %{state | next: state.next + 2}

    case kinds do
      {:taken, :taken} ->
        end_turn(%{state | replies: state.replies ++ [a, b]}, "completed")

      # The second, declined once nothing else is out, ends the turn and runs on its own.
      {:taken, :declined} ->
        state = end_turn(%{state | replies: state.replies ++ [a]}, "completed")
        %{state | runs: state.runs ++ [{b, "completed"}], replies: state.replies ++ [b]}

      # Both find the turn over, and run on their own.
      {:declined, :declined} ->
        state = end_turn(state, "completed")
        own = [{a, "completed"}, {b, "completed"}]
        %{state | runs: state.runs ++ own, replies: state.replies ++ [a, b]}

      # The second starts work that runs on, so the first, declined, is an error for its
      # sender; the turn's work takes the next steer in.
      {:declined, :joins} ->
        %{state | how: :joins}

      # The unanswered one is taken as taken once its budget runs out, which is the
      # last steer out either way: the turn ends with it and no reply, and the
      # declined one, held until then, finds the turn over and runs on its own.
      {:declined, :ignored} ->
        state = end_turn(state, "completed")
        %{state | runs: state.runs ++ [{a, "completed"}], replies: state.replies ++ [a]}

      {:ignored, :declined} ->
        state = end_turn(state, "completed")
        %{state | runs: state.runs ++ [{b, "completed"}], replies: state.replies ++ [b]}
    end
  end

  # Held until the turn's compaction ended, then taken: the compaction shows.
  def next_state(%{how: :compacts} = state, _result, {:call, _, :steer, [msg, :taken]}) do
    compactions = state.compactions ++ ["Compacted mid-turn."]
    state = %{state | next: state.next + 1, replies: state.replies ++ [msg]}
    end_turn(%{state | compactions: compactions}, "completed")
  end

  # Stopped with the steer held: its sender hears the stop, Pi never takes it,
  # and the compaction outlasting the grace restarts Pi, so it shows unfinished.
  def next_state(state, _result, {:call, _, :steer_held_stop, _}),
    do:
      end_turn(
        %{state | next: state.next + 1, compactions: state.compactions ++ [nil]},
        "interrupted"
      )

  # The first completes; the second, sent while Pi compacts after it, waits
  # for the compaction, which then ends in the second's turn and shows there.
  def next_state(state, _result, {:call, _, :send_compacted, [a, b, _heard]}) do
    %{
      state
      | next: state.next + 2,
        runs: state.runs ++ [{a, "completed"}, {b, "running"}],
        turn: b,
        how: :joins,
        compactions: state.compactions ++ ["Compacted after the turn."]
    }
  end

  # Pi never answers: once the budget ran out the steer is taken, and the turn ends with
  # it and no reply.
  def next_state(state, _result, {:call, _, :steer, [_msg, :ignored]}),
    do: end_turn(%{state | next: state.next + 1}, "completed")

  # Pi exits with the steer unanswered: the turn fails, and the message runs on its own.
  # The dead Pi also takes any abandoned compaction with it: its events never land.
  def next_state(state, _result, {:call, _, :steer, [msg, :vanishes]}) do
    state = end_turn(%{state | abandoned: :none}, "failed")

    %{
      state
      | next: state.next + 1,
        runs: state.runs ++ [{msg, "completed"}],
        replies: state.replies ++ [msg]
    }
  end

  def next_state(state, _result, {:call, _, :steer, [_msg, :refused]}),
    do: %{state | next: state.next + 1}

  # Declined once the run settled: the turn is over, so the message runs on its own.
  def next_state(%{how: :ends} = state, _result, {:call, _, :steer, [msg, :declined]}) do
    state = end_turn(state, "completed")

    %{
      state
      | next: state.next + 1,
        runs: state.runs ++ [{msg, "completed"}],
        replies: state.replies ++ [msg]
    }
  end

  def next_state(state, _result, {:call, _, :steer, [msg, _taken_or_declined]}) do
    state = %{state | next: state.next + 1, replies: state.replies ++ [msg]}
    end_turn(state, "completed")
  end

  # The steered compaction's caller is answered as a stopped turn's steer is,
  # and the turn ends interrupted; Pi goes on compacting, so its events are
  # still to land in a later turn, where they must show nothing.
  def next_state(state, _result, {:call, _, :steer_compact_stop, _}),
    do: end_turn(%{state | next: state.next + 1, abandoned: :events}, "interrupted")

  # As above, but Pi answers the abandoned compaction with a failure and no
  # events: the task's reply alone ends the abandonment, and a later turn's
  # own compaction must show as it would have.
  def next_state(state, _result, {:call, _, :steer_compact_stop_fail, _}),
    do: end_turn(%{state | next: state.next + 1, abandoned: :replied}, "interrupted")

  def next_state(state, _result, {:call, _, :interrupt, _}), do: end_turn(state, "interrupted")

  defp end_turn(%{turn: turn} = state, status) do
    runs = Enum.map(state.runs, fn {m, s} -> if m == turn, do: {m, status}, else: {m, s} end)
    %{state | runs: runs, turn: nil, how: nil}
  end

  def postcondition(state, call, {reply, projection}) do
    model = next_state(state, nil, call)

    replied? =
      case call do
        {:call, _, :steer, [_, :refused]} -> match?({:error, _}, reply)
        {:call, _, :steer_pair, [_, _, {:declined, :joins}]} -> match?([{:error, _}, :ok], reply)
        {:call, _, :steer_pair, _} -> reply == [:ok, :ok]
        {:call, _, :steer_staggered, _} -> reply == [:ok, :ok]
        _ -> reply == :ok
      end

    replied? and wakes_ok?(model.pending) and
      Enum.sort(projection.runs) == Enum.sort(model.runs) and
      Enum.sort(projection.replies) == Enum.sort(model.replies) and
      projection.compactions == model.compactions and
      Enum.sort(projection.images) == Enum.sort(model.images) and
      Enum.sort(projection.subagents) == Enum.sort(subagents(model))
  end

  defp subagents(model) do
    for {msg, status} <- model.subagents do
      if status == :with_run,
        do: {msg, model.runs |> Enum.find(&(elem(&1, 0) == msg)) |> elem(1)},
        else: {msg, status}
    end
  end

  # --- commands ---------------------------------------------------------------------

  defp create(work) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Pi",
        "modelSelection" => @model,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })
  end

  # `how`: whether the turn's work takes a steer in (:joins) or settles as it lands (:ends).
  def send(msg, how) do
    result = Orchestration.dispatch(message(msg, "#{how} #{msg}", "queue_after_active", "auto"))
    # A turn Pi aborts itself runs to its end; the others work on.
    reply(result, if(how == :aborts, do: unfinished_runs(), else: []))
  end

  # A turn a Pi extension wakes Pi after: the projection is taken once the wake's own
  # turn ended.
  def send_woken(msg) do
    woke = woken_runs(current())
    result = Orchestration.dispatch(message(msg, "wakes #{msg}", "queue_after_active", "auto"))
    {answer(result), woken(woke + 1, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # Sends `a`, after which Pi resumes an extension's work unannounced, then `b`, which
  # Pi turns back as busy: `b` must reach Pi once more, queued behind that work, and its
  # turn must show the work.
  def send_into_wake(a, b) do
    first = Orchestration.dispatch(message(a, "quietly #{a}", "queue_after_active", "auto"))
    done = settled(unfinished_runs(), System.monotonic_time(:millisecond) + @wait_ms)
    second = Orchestration.dispatch(message(b, "plain #{b}", "queue_after_active", "auto"))
    projection = settled(unfinished_runs(), System.monotonic_time(:millisecond) + @wait_ms)
    state = current()
    run = Enum.find(runs(state), &(&1["userMessageId"] == b)) || %{}

    shown =
      Enum.any?(
        StreamState.list(state, "message"),
        &(&1["runId"] == run["id"] and &1["text"] == "Resumed.")
      )

    queued = for {%{"accepted" => "plain " <> ^b, "followUp" => true}, _} <- fake_log(), do: b

    reply =
      cond do
        match?({:timeout, _}, done) -> {:error, "#{a} never ended"}
        queued != [b] -> {:error, "Pi queued #{b} #{length(queued)} times"}
        not shown -> {:error, "#{b}'s turn does not show the resumed work"}
        true -> answer(first) |> both(answer(second))
      end

    {reply, projection}
  end

  # Sends `a`, after which Pi resumes an extension's work unannounced, then `b`, which
  # Pi turns back as busy and HAL-C2 sends again as a follow-up, with history `b` hands
  # over (its mark, `unconfirmedRunId`). Pi answers that it queued `b` and runs a command
  # of the wake's before it delivers `b`: that command is in `b`'s turn but confirms
  # nothing, so the mark stands until Pi delivers `b`, and goes once `b` completes.
  def send_handed_into_wake(a, b) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    dir = Application.get_env(:hal_c2, :pi_prop_fake_dir)
    first = Orchestration.dispatch(message(a, "follows #{a}", "queue_after_active", "auto"))
    done = settled(unfinished_runs(), deadline.())
    second = Orchestration.dispatch(message(b, "plain #{b}", "queue_after_active", "auto"))
    run = await(&Enum.find(runs(&1), fn run -> run["userMessageId"] == b end), deadline.())
    queued = await_log(&match?(%{"accepted" => "plain " <> ^b, "followUp" => true}, &1))

    # The history `b` hands over, as a handoff into Pi marks it.
    mark = fn state ->
      with {:ok, %{"providerThreadId" => id}} <- run,
           do: StreamState.get(state, "provider-thread")[id]["unconfirmedRunId"]
    end

    with {:ok, %{"id" => id, "providerThreadId" => thread}} <- run do
      {:ok, _} =
        HalC2.Streams.commit(@tid, :thread, [
          {"provider-thread", thread,
           %{"s" => %{"unconfirmedRunId" => id, "unconfirmedSince" => 0}}}
        ])
    end

    File.touch!(Path.join(dir, "follow-go"))

    command =
      with {:ok, %{"id" => id}} <- run,
           do:
             await(
               fn state ->
                 Enum.find(
                   StreamState.list(state, "turn-item"),
                   &(&1["runId"] == id and &1["type"] == "command_execution")
                 )
               end,
               deadline.()
             )

    held = mark.(current())
    File.touch!(Path.join(dir, "follow-deliver"))
    projection = settled(unfinished_runs(), deadline.())
    after_b = mark.(current())
    File.rm(Path.join(dir, "follow-go"))
    File.rm(Path.join(dir, "follow-deliver"))

    reply =
      cond do
        match?({:timeout, _}, done) -> {:error, "#{a} never ended"}
        run == :timeout or queued == :timeout -> {:error, "Pi never queued #{b}"}
        command == :timeout -> {:error, "#{b}'s turn does not show the wake's command"}
        held != elem(run, 1)["id"] -> {:error, "the wake's command confirmed #{b}'s handoff"}
        after_b != nil -> {:error, "#{b} completed with its handoff unconfirmed"}
        true -> answer(first) |> both(answer(second))
      end

    {reply, projection}
  end

  # Until the fake has logged an entry `pred` holds of.
  defp await_log(pred, deadline \\ System.monotonic_time(:millisecond) + @wait_ms) do
    cond do
      Enum.any?(fake_log(), fn {entry, _} -> pred.(entry) end) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        receive do
        after
          10 -> await_log(pred, deadline)
        end
    end
  end

  # Sends `a` and `b`, plain turns, then `c`, an extension command that moves Pi's session
  # back to just before `b` (`navigateTree`): `b` must be rolled back and nothing before
  # it, and `c`'s own turn left nothing on Pi's branch, so a revert needs no fork for it.
  # The turns after it then find their place in Pi's session past the abandoned branch.
  def send_rewound(a, b, c) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    first = Orchestration.dispatch(message(a, "plain #{a}", "queue_after_active", "auto"))
    done_a = settled(unfinished_runs(), deadline.())
    second = Orchestration.dispatch(message(b, "plain #{b}", "queue_after_active", "auto"))
    done_b = settled(unfinished_runs(), deadline.())
    fake_config(&Map.put(&1, "rewindCommands", %{"/rewind" => "plain #{b}"}))
    third = Orchestration.dispatch(message(c, "/rewind #{c}", "queue_after_active", "auto"))
    projection = settled(unfinished_runs(), deadline.())
    state = current()
    run = Enum.find(runs(state), &(&1["userMessageId"] == c)) || %{}

    turn =
      Enum.find(StreamState.list(state, "provider-turn"), &(&1["ordinal"] == run["ordinal"])) ||
        %{}

    reply =
      cond do
        match?({:timeout, _}, done_a) or match?({:timeout, _}, done_b) ->
          {:error, "#{a} or #{b} never ended"}

        not match?(%{"nativeTurnRef" => nil}, turn) ->
          {:error, "#{c}'s turn has a place in Pi's session: #{inspect(turn["nativeTurnRef"])}"}

        true ->
          answer(first) |> both(answer(second)) |> both(answer(third))
      end

    {reply, projection}
  end

  # Sends `a`, after which Pi works on by itself, and holds the wake's message until `b`
  # has taken that work over; the message then queues behind `b`, where it is cancelled,
  # and `b` is stopped. Then `c`, after which Pi wakes again: that wake must get a run,
  # and once it ended the idle runtime must let Pi go.
  def send_wake_taken(a, b, c) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :hold_wake, [self()]})
    first = Orchestration.dispatch(message(a, "hands #{a}", "queue_after_active", "auto"))

    held =
      receive do
        {:wake_held, pid} -> pid
      after
        @wait_ms -> nil
      end

    Application.delete_env(:hal_c2, :wake_hook)
    second = Orchestration.dispatch(message(b, "plain #{b}", "queue_after_active", "auto"))

    taken =
      await(
        fn state ->
          run = Enum.find(runs(state), &(&1["userMessageId"] == b))
          run["status"] == "running" and working?(state, run)
        end,
        deadline.()
      )

    if held, do: Kernel.send(held, :go)

    queued =
      await(
        &Enum.find(runs(&1), fn run ->
          woken_id(run["userMessageId"]) == :woken and run["status"] == "queued"
        end),
        deadline.()
      )

    cancel =
      with {:ok, run} <- queued,
           do:
             Orchestration.dispatch(%{
               "type" => "queued-run.cancel",
               "threadId" => @tid,
               "runId" => run["id"]
             })

    stop = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})
    stopped = settled(unfinished_runs(), deadline.())
    {reply, projection} = wakes_again(c, deadline)

    reply =
      cond do
        held == nil ->
          {:error, "#{a}'s wake never asked the thread for a run"}

        taken == :timeout ->
          {:error, "#{b} never took over the wake"}

        queued == :timeout ->
          {:error, "the wake's run never queued behind #{b}"}

        match?({:timeout, _}, stopped) ->
          {:error, "#{b} never ended"}

        true ->
          [first, second, cancel, stop]
          |> Enum.map(&answer/1)
          |> Enum.reduce(&both/2)
          |> both(reply)
      end

    {reply, projection}
  end

  # Sends `a`, after which Pi works on by itself and settles while the wake's message is
  # held, then `b`, which leaves the settled wake alone. The message then queues behind
  # `b`, where it is cancelled, and `b` is stopped. Then `c`, after which Pi wakes again:
  # that wake must get a run, and once it ended the idle runtime must let Pi go.
  def send_wake_settled(a, b, c) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :hold_wake, [self()]})
    first = Orchestration.dispatch(message(a, "wakes #{a}", "queue_after_active", "auto"))

    held =
      receive do
        {:wake_held, pid} -> pid
      after
        @wait_ms -> nil
      end

    Application.delete_env(:hal_c2, :wake_hook)
    settled_wake = if held, do: wake_settled(deadline.()), else: :timeout
    second = Orchestration.dispatch(message(b, "joins #{b}", "queue_after_active", "auto"))

    started =
      await(
        fn state ->
          run = Enum.find(runs(state), &(&1["userMessageId"] == b))
          run["status"] == "running" and working?(state, run)
        end,
        deadline.()
      )

    if held, do: Kernel.send(held, :go)

    queued =
      await(
        &Enum.find(runs(&1), fn run ->
          woken_id(run["userMessageId"]) == :woken and run["status"] == "queued"
        end),
        deadline.()
      )

    cancel =
      with {:ok, run} <- queued,
           do:
             Orchestration.dispatch(%{
               "type" => "queued-run.cancel",
               "threadId" => @tid,
               "runId" => run["id"]
             })

    stop = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})
    stopped = settled(unfinished_runs(), deadline.())
    {reply, projection} = wakes_again(c, deadline)

    reply =
      cond do
        held == nil ->
          {:error, "#{a}'s wake never asked the thread for a run"}

        settled_wake != :ok ->
          {:error, "Pi never settled the wake after #{a}"}

        started == :timeout ->
          {:error, "#{b} never ran"}

        queued == :timeout ->
          {:error, "the wake's run never queued behind #{b}"}

        match?({:timeout, _}, stopped) ->
          {:error, "#{b} never ended"}

        true ->
          [first, second, cancel, stop]
          |> Enum.map(&answer/1)
          |> Enum.reduce(&both/2)
          |> both(reply)
      end

    {reply, projection}
  end

  # Returns once the runtime has had Pi's settle of a wake whose run has not come: a
  # debug hook on the runtime reports the settle, so nothing polls.
  defp wake_settled(deadline) do
    [{runtime, _}] = Registry.lookup(HalC2.Pi.Registry, @tid)
    test = self()

    report = fn
      _, {:in, {:json_rpc, _, {:notification, "agent_settled", _}}}, _ ->
        Kernel.send(test, :wake_settled)
        :done

      acc, _, _ ->
        acc
    end

    :ok = :sys.install(runtime, {:wake_settled, report, nil})

    result =
      case :sys.get_state(runtime) do
        %{wake: %{open: false}} ->
          :ok

        _ ->
          receive do
            :wake_settled ->
              # The runtime has handled the settle it was just given.
              if match?(%{wake: %{open: false}}, :sys.get_state(runtime)), do: :ok, else: :open
          after
            max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
          end
      end

    :sys.remove(runtime, :wake_settled)

    receive do
      :wake_settled -> :ok
    after
      0 -> :ok
    end

    result
  end

  # Sends `a`, after which Pi works on by itself, refuses the wake's every try, and has Pi
  # exit at that work. Then `c`, after which Pi wakes again: that wake must get a run, and
  # once it ended the idle runtime must let Pi go.
  def send_wake_refused(a, c) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    exit_now = Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "exit-now")
    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :refuse_wake, [self()]})
    Application.put_env(:hal_c2, :wake_pause, {__MODULE__, :no_pause, []})
    first = Orchestration.dispatch(message(a, "strays #{a}", "queue_after_active", "auto"))

    refused =
      receive do
        {:wake_refused, task} ->
          # Every try refused, the runtime heard (`on_dropped`) before the task ended.
          ref = Process.monitor(task)
          receive(do: ({:DOWN, ^ref, _, _, _} -> :ok))
          forget_refusals()
      after
        @wait_ms -> :timeout
      end

    Application.delete_env(:hal_c2, :wake_hook)
    Application.delete_env(:hal_c2, :wake_pause)

    exited =
      with :ok <- refused,
           [{runtime, _}] <- Registry.lookup(HalC2.Pi.Registry, @tid),
           %{conn: conn} when is_pid(conn) <- :sys.get_state(runtime) do
        ref = Process.monitor(conn)
        File.touch!(exit_now)
        receive(do: ({:DOWN, ^ref, _, _, _} -> :ok))
        # The runtime has had the connection's exit.
        :sys.get_state(runtime)
        :ok
      end

    File.rm(exit_now)
    {reply, projection} = wakes_again(c, deadline)

    reply =
      cond do
        refused != :ok -> {:error, "#{a}'s wake never asked the thread for a run"}
        exited != :ok -> {:error, "Pi never exited at the refused wake"}
        true -> answer(first) |> both(reply)
      end

    {reply, projection}
  end

  # Sends `a`, after which Pi wakes, settles, and wakes again, each wake's delivery held
  # at its first try. The first delivery is then refused at every try, and the second
  # let go: its run must show the work of both wakes. Then `c`, after which Pi wakes
  # again: that wake must get a run, and once it ended the idle runtime must let Pi go.
  def send_wake_superseded(a, c) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :answer_wake, [self()]})
    Application.put_env(:hal_c2, :wake_pause, {__MODULE__, :no_pause, []})
    again = Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "wake-again")
    woke = woken_runs(current())
    first = Orchestration.dispatch(message(a, "twice #{a}", "queue_after_active", "auto"))
    earlier = receive(do: ({:wake_try, task, _id} -> task), after: (@wait_ms -> nil))
    File.touch!(again)
    later = receive(do: ({:wake_try, task, _id} -> task), after: (@wait_ms -> nil))
    File.rm(again)

    refused =
      case [earlier, later] do
        [earlier, later] when is_pid(earlier) and is_pid(later) ->
          refuse_every_try(earlier)
          # The runtime has had the refusal.
          [{runtime, _}] = Registry.lookup(HalC2.Pi.Registry, @tid)
          :sys.get_state(runtime)
          Kernel.send(later, {:answer, :ok})
          :ok

        _ ->
          :timeout
      end

    Application.delete_env(:hal_c2, :wake_hook)
    Application.delete_env(:hal_c2, :wake_pause)
    shown = woken(woke + 1, deadline.())
    state = current()

    texts =
      for run <- runs(state),
          woken_id(run["userMessageId"]) == :woken,
          message <- StreamState.list(state, "message"),
          message["runId"] == run["id"],
          do: message["text"]

    {reply, projection} = wakes_again(c, deadline)

    reply =
      cond do
        refused != :ok -> {:error, "Pi's two wakes after #{a} never asked the thread for runs"}
        match?({:timeout, _}, shown) -> {:error, "the second wake after #{a} got no run"}
        not Enum.any?(texts, &(&1 =~ "Woke up.")) -> {:error, "the run lost the first wake"}
        not Enum.any?(texts, &(&1 =~ "Woke again.")) -> {:error, "the run lost the second wake"}
        true -> answer(first) |> both(reply)
      end

    {reply, projection}
  end

  # Sends `a`, after which Pi works on by itself, and holds the wake's message while Pi
  # exits at that work. Then `c`, whose turn a new Pi runs, after which it wakes: the
  # first wake's run must end failed, and the second wake must get a run of its own,
  # after which the idle runtime must let Pi go.
  def send_wake_cut(a, c) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    exit_now = Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "exit-now")
    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :answer_wake, [self()]})
    woke = woken_runs(current())
    first = Orchestration.dispatch(message(a, "strays #{a}", "queue_after_active", "auto"))
    earlier = receive(do: ({:wake_try, task, _id} -> task), after: (@wait_ms -> nil))

    exited =
      with true <- is_pid(earlier),
           [{runtime, _}] <- Registry.lookup(HalC2.Pi.Registry, @tid),
           %{conn: conn} when is_pid(conn) <- :sys.get_state(runtime) do
        ref = Process.monitor(conn)
        File.touch!(exit_now)
        receive(do: ({:DOWN, ^ref, _, _, _} -> :ok))
        # The runtime has had the connection's exit.
        :sys.get_state(runtime)
        :ok
      end

    File.rm(exit_now)
    second = Orchestration.dispatch(message(c, "wakes #{c}", "queue_after_active", "auto"))
    later = receive(do: ({:wake_try, task, _id} -> task), after: (@wait_ms -> nil))
    if earlier, do: Kernel.send(earlier, {:answer, :ok})
    cut = woken(woke + 1, deadline.())
    if later, do: Kernel.send(later, {:answer, :ok})
    Application.delete_env(:hal_c2, :wake_hook)
    projection = woken(woke + 2, deadline.())

    released =
      if match?({:timeout, _}, projection),
        do: :skipped,
        else: Orchestration.release_session(@tid)

    reply =
      cond do
        exited != :ok -> {:error, "Pi never exited at the wake after #{a}"}
        later == nil -> {:error, "the new Pi never woke after #{c}"}
        match?({:timeout, _}, cut) -> {:error, "the wake after #{a} got no run"}
        released == :skipped -> {:error, "Pi's wake after #{c} got no run"}
        released != :ok -> {:error, "the idle runtime kept Pi: #{inspect(released)}"}
        true -> answer(first) |> both(answer(second))
      end

    {reply, projection}
  end

  # Sends `a`, after which Pi works on by itself and settles while the wake's delivery is
  # held, then `b`, which runs while the delivery is refused at every try, and is
  # stopped. Then `c`, after which Pi wakes again: that wake must get a run that shows
  # nothing of the refused one, and once it ended the idle runtime must let Pi go.
  def send_wake_refused_in_turn(a, b, c) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :answer_wake, [self()]})
    Application.put_env(:hal_c2, :wake_pause, {__MODULE__, :no_pause, []})
    before = run_ids()
    first = Orchestration.dispatch(message(a, "dozes #{a}", "queue_after_active", "auto"))

    {held, id} =
      receive(do: ({:wake_try, task, id} -> {task, id}), after: (@wait_ms -> {nil, nil}))

    settled_wake = if held, do: wake_settled(deadline.()), else: :timeout
    waiting = wakes_ok?([id])
    second = Orchestration.dispatch(message(b, "joins #{b}", "queue_after_active", "auto"))

    started =
      await(
        fn state ->
          run = Enum.find(runs(state), &(&1["userMessageId"] == b))
          run["status"] == "running" and working?(state, run)
        end,
        deadline.()
      )

    refused = if held && started != :timeout, do: refuse_every_try(held), else: :timeout
    # The runtime has had the refusal.
    refused_kept = wakes_ok?([])
    Application.delete_env(:hal_c2, :wake_hook)
    Application.delete_env(:hal_c2, :wake_pause)
    stop = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})
    stopped = settled(unfinished_runs(), deadline.())
    {reply, projection} = wakes_again(c, deadline)

    reply =
      cond do
        held == nil ->
          {:error, "#{a}'s wake never asked the thread for a run"}

        settled_wake != :ok ->
          {:error, "Pi never settled the wake after #{a}"}

        started == :timeout ->
          {:error, "#{b} never ran"}

        refused != :ok ->
          {:error, "the wake's delivery was never refused"}

        match?({:timeout, _}, stopped) ->
          {:error, "#{b} never ended"}

        shown?("Dozed off.", before) ->
          {:error, "the refused wake after #{a} shows in a turn"}

        not waiting ->
          {:error, "the settled wake waits on no delivery of its own"}

        not refused_kept ->
          {:error, "the runtime kept the wake refused while #{b} ran"}

        true ->
          [first, second, stop] |> Enum.map(&answer/1) |> Enum.reduce(&both/2) |> both(reply)
      end

    {reply, projection}
  end

  # Sends `a`, after which Pi works on by itself, and holds the wake's delivery while Pi
  # exits at that work. Then `c`, whose turn a new Pi runs, after which it wakes and
  # settles, its delivery held too: that wake joins the cut one. With `which` :later,
  # the first delivery's run takes the cut part (it ends failed), and the second
  # delivery is refused: the new Pi's work must show in no turn. With :earlier, the
  # first delivery is refused, and the second's run takes the cut part: the new Pi's
  # work must get a run of its own. The runtime's wake must wait only on pending
  # deliveries throughout. Then `d`, after which Pi wakes again: that wake must get a
  # run, and once it ended the idle runtime must let Pi go.
  def send_wake_cut_refused(a, c, d, which) do
    deadline = fn -> System.monotonic_time(:millisecond) + @wait_ms end
    exit_now = Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "exit-now")
    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :answer_wake, [self()]})
    Application.put_env(:hal_c2, :wake_pause, {__MODULE__, :no_pause, []})
    woke = woken_runs(current())
    before = run_ids()
    first = Orchestration.dispatch(message(a, "strays #{a}", "queue_after_active", "auto"))
    {earlier, a_id} = next_wake_try()

    exited =
      with true <- is_pid(earlier),
           [{runtime, _}] <- Registry.lookup(HalC2.Pi.Registry, @tid),
           %{conn: conn} when is_pid(conn) <- :sys.get_state(runtime) do
        ref = Process.monitor(conn)
        File.touch!(exit_now)
        receive(do: ({:DOWN, ^ref, _, _, _} -> :ok))
        # The runtime has had the connection's exit.
        :sys.get_state(runtime)
        :ok
      end

    File.rm(exit_now)
    checks = [cut: wakes_ok?([a_id])]
    second = Orchestration.dispatch(message(c, "dozes #{c}", "queue_after_active", "auto"))
    {later, c_id} = next_wake_try()
    checks = checks ++ [joined: wakes_ok?([a_id, c_id])]

    {ran, checks} =
      cond do
        later == nil ->
          {:timeout, checks}

        which == :later ->
          Kernel.send(earlier, {:answer, :ok})
          cut = woken(woke + 1, deadline.())
          checks = checks ++ [ran_cut: wakes_ok?([c_id])]
          refused = if match?({:timeout, _}, cut), do: :timeout, else: refuse_every_try(later)
          {refused, checks ++ [refused: wakes_ok?([])]}

        which == :earlier ->
          refused = refuse_every_try(earlier)
          checks = checks ++ [refused: wakes_ok?([c_id])]
          Kernel.send(later, {:answer, :ok})
          # The run took the cut part, and the rest asks for a run of its own.
          {again, again_id} = next_wake_try()
          checks = checks ++ [asked_again: again != nil and wakes_ok?([again_id])]
          if again, do: Kernel.send(again, {:answer, :ok})
          rest = woken(woke + 2, deadline.())
          {if(refused == :ok and again != nil, do: rest, else: :timeout), checks}
      end

    Application.delete_env(:hal_c2, :wake_hook)
    Application.delete_env(:hal_c2, :wake_pause)
    {reply, projection} = wakes_again(d, deadline)
    failed = for {name, false} <- checks, do: name

    reply =
      cond do
        exited != :ok ->
          {:error, "Pi never exited at the wake after #{a}"}

        later == nil ->
          {:error, "the new Pi never woke after #{c}"}

        ran == :timeout or match?({:timeout, _}, ran) ->
          {:error, "a wake after #{a} got no run"}

        which == :later and shown?("Dozed off.", before) ->
          {:error, "the refused wake after #{c} shows"}

        which == :earlier and not shown?("Dozed off.", before) ->
          {:error, "the wake after #{c} is lost"}

        failed != [] ->
          {:error, "the wake waited on deliveries not pending at #{inspect(failed)}"}

        true ->
          answer(first) |> both(answer(second)) |> both(reply)
      end

    {reply, projection}
  end

  defp next_wake_try,
    do: receive(do: ({:wake_try, task, id} -> {task, id}), after: (@wait_ms -> {nil, nil}))

  # Whether a run of the thread other than the runs `before` says `text`.
  defp shown?(text, before) do
    state = current()

    Enum.any?(
      StreamState.list(state, "message"),
      &(&1["runId"] not in [nil | before] and &1["text"] =~ text)
    )
  end

  defp run_ids, do: Enum.map(runs(current()), & &1["id"])

  # The wake invariant (`HalC2.Pi.ThreadRuntime`, Wakes): a wake the runtime keeps work
  # for waits on deliveries, all of them among `pending`; one with none shows nothing.
  defp wakes_ok?(pending) do
    wake =
      case Registry.lookup(HalC2.Pi.Registry, @tid) do
        [{runtime, _}] -> :sys.get_state(runtime).wake
        [] -> nil
      end

    case wake do
      nil -> true
      %{buffer: nil, ids: []} -> true
      %{buffer: [_ | _], ids: [_ | _] = ids} -> ids -- pending == []
      _ -> false
    end
  end

  # The wake hook: each try, named by the wake message's id, waits for the test's answer
  # (`{:answer, result}`).
  def answer_wake(test, command) do
    Kernel.send(test, {:wake_try, self(), command["messageId"]})

    receive do
      {:answer, result} -> result
    after
      @wait_ms -> {:error, "no answer"}
    end
  end

  # Refuses a delivery's every try; the runtime has heard (`on_dropped`) once it ends.
  defp refuse_every_try(task) do
    ref = Process.monitor(task)
    refuse_tries(task, ref)
  end

  defp refuse_tries(task, ref) do
    Kernel.send(task, {:answer, {:error, "refused"}})

    receive do
      {:wake_try, ^task, _id} -> refuse_tries(task, ref)
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      @wait_ms -> :timeout
    end
  end

  # Sends `c`, after whose turn Pi wakes: the wake must get a run of its own, and once it
  # ended the runtime, idle, must let Pi go.
  defp wakes_again(c, deadline) do
    woke = woken_runs(current())
    sent = Orchestration.dispatch(message(c, "wakes #{c}", "queue_after_active", "auto"))
    projection = woken(woke + 1, deadline.())

    released =
      if match?({:timeout, _}, projection),
        do: :skipped,
        else: Orchestration.release_session(@tid)

    reply =
      cond do
        released == :skipped -> {:error, "Pi's wake after #{c} got no run"}
        released != :ok -> {:error, "the idle runtime kept Pi: #{inspect(released)}"}
        true -> answer(sent)
      end

    {reply, projection}
  end

  # The wake hook: holds the wake's message until the test lets it go.
  def hold_wake(test, _command) do
    Kernel.send(test, {:wake_held, self()})

    receive do
      :go -> :ok
    after
      @wait_ms -> :ok
    end
  end

  # The wake hook: the thread refuses every try.
  def refuse_wake(test, _command) do
    Kernel.send(test, {:wake_refused, self()})
    {:error, "refused"}
  end

  def no_pause(_attempt), do: 0

  # The refused wake's other tries.
  defp forget_refusals do
    receive do
      {:wake_refused, _task} -> forget_refusals()
    after
      0 -> :ok
    end
  end

  defp await(pred, deadline) do
    flush()
    state = current()

    if found = pred.(state) do
      {:ok, found}
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await(pred, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
      end
    end
  end

  defp working?(state, run),
    do:
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["runId"] == run["id"] and &1["type"] == "assistant_message")
      )

  # The runs a wake started that have ended.
  defp woken_runs(state),
    do:
      Enum.count(
        runs(state),
        &(woken_id(&1["userMessageId"]) == :woken and &1["status"] in @finished)
      )

  defp woken(count, deadline) do
    flush()
    state = current()

    if woken_runs(state) >= count do
      settled([], deadline)
    else
      receive do
        {:hal_c2_stream, @tid, _} -> woken(count, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, projection(state)}
      end
    end
  end

  # A wake's message is not one the test sent.
  defp woken_id(msg), do: if(msg =~ ~r/^m\d{3}$/, do: msg, else: :woken)

  # A turn the abandoned compaction's late events land in while its task is
  # still out (the "late" script sends them, then this turn's own compaction:
  # both are dropped). It runs to its end, so the projection is taken once
  # its run finished and its items are recorded.
  def send_late(msg) do
    result = Orchestration.dispatch(message(msg, "late #{msg}", "queue_after_active", "auto"))
    {answer(result), settled(unfinished_runs(), System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # A turn the fake starts only once the abandoned compaction ends. It shows
  # nothing until then, so the projection is taken once the watchdog has
  # checked Pi four times since the prompt: past the two idle checks that
  # would settle it (and the one a fresh session's opening makes).
  def send_behind(msg) do
    checks = state_checks()
    result = Orchestration.dispatch(message(msg, "behind #{msg}", "queue_after_active", "auto"))
    {answer(result), behind(msg, checks + 4, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  defp behind(msg, checks, deadline) do
    state = current()
    run = Enum.find(runs(state), &(&1["userMessageId"] == msg))

    cond do
      (run && run["status"] not in ~w(preparing starting)) and state_checks() >= checks ->
        projection(state)

      System.monotonic_time(:millisecond) > deadline ->
        {:timeout, projection(state)}

      true ->
        receive do
        after
          20 -> behind(msg, checks, deadline)
        end
    end
  end

  # How many `get_state` checks the fake has received.
  defp state_checks do
    log = Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "log.jsonl")

    case File.read(log) do
      {:ok, text} -> text |> String.split(~s("type": "get_state")) |> length() |> Kernel.-(1)
      _ -> 0
    end
  end

  # An extension command the fake answers without agent work: the turn
  # completes once the watchdog hears Pi is idle.
  def send_handled(msg) do
    result = Orchestration.dispatch(message(msg, "/stats #{msg}", "queue_after_active", "auto"))
    {answer(result), settled(unfinished_runs(), System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # A message whose agent starts late, plain or through a prompt template
  # (`prefix`): the projection is taken once it is running and has said
  # "Working on it." (settled as idle, it would have completed first).
  def send_slow(msg, prefix) do
    text = "#{prefix}slow #{msg}"
    reply(Orchestration.dispatch(message(msg, text, "queue_after_active", "auto")), [])
  end

  # A prompt Pi answers and then never reports on, with its state checks
  # failing: the watchdog stops the session and the turn fails. The checks
  # are made to fail only for this turn (its session is already open).
  def send_silent(msg) do
    fake_config(&Map.put(&1, "failCommands", ["get_state"]))
    result = Orchestration.dispatch(message(msg, "silent #{msg}", "queue_after_active", "auto"))
    projection = settled(unfinished_runs(), System.monotonic_time(:millisecond) + @wait_ms)
    fake_config(&Map.delete(&1, "failCommands"))
    {answer(result), projection}
  end

  # A turn that compacts on its own (the "own") after an abandoned compaction
  # was answered with a failure: its compaction must show.
  def send_own(msg) do
    result = Orchestration.dispatch(message(msg, "own #{msg}", "queue_after_active", "auto"))
    {answer(result), settled(unfinished_runs(), System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # `kind`: whether Pi takes the steer (:taken), which ends the turn, refuses it, refuses
  # it only once the run settled (:declined), which a turn taking it in takes, exits
  # before answering it (:vanishes), or never answers it once the run settled (:ignored).
  def steer(msg, kind) do
    {text, ending} = steer_text(msg, kind)
    result = Orchestration.dispatch(message(msg, text, "start_immediately", "steer"))
    # A steer sent on its own runs to its end too.
    ending = if kind in [:declined, :vanishes], do: ending ++ active_runs(), else: ending
    reply(result, ending)
  end

  defp steer_text(msg, :taken), do: {"steer #{msg}", active_runs()}
  defp steer_text(msg, :refused), do: {"refuse #{msg}", []}
  defp steer_text(msg, :declined), do: {"steer #{msg}, declined once settled", active_runs()}
  defp steer_text(msg, :vanishes), do: {"steer #{msg}, vanish on it", active_runs()}
  defp steer_text(msg, :ignored), do: {"steer #{msg}, ignore it", active_runs()}
  # A steer whose own run matches the "joins" turn, which works on.
  defp steer_text(msg, :joins), do: {"steer #{msg}, joins the work", []}

  # Two steers sent at once, `kinds` as for `steer/2`.
  def steer_pair(a, b, {kind_a, kind_b}) do
    {text_a, ending} = steer_text(a, kind_a)
    {text_b, _} = steer_text(b, kind_b)

    replies =
      [{a, text_a}, {b, text_b}]
      |> Enum.map(fn {msg, text} ->
        Task.async(fn ->
          answer(Orchestration.dispatch(message(msg, text, "start_immediately", "steer")))
        end)
      end)
      |> Task.await_many(@wait_ms)

    # Unless the turn works on, every run it left, the ones sent on their own included,
    # runs to its end.
    ending = if kind_b == :joins, do: [], else: ending ++ unfinished_runs()
    {replies, settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # Two steers staggered: the second is dispatched while the first is still in
  # flight, so whichever is declined is held behind the unanswered one's whole
  # answer budget (and the settling after it) before its sender hears. Its
  # caller must still hear the refusal, not a timeout taken as taken.
  def steer_staggered(a, b, {kind_a, kind_b}) do
    {text_a, ending} = steer_text(a, kind_a)
    {text_b, _} = steer_text(b, kind_b)

    first =
      Task.async(fn ->
        answer(Orchestration.dispatch(message(a, text_a, "start_immediately", "steer")))
      end)

    reply_b = answer(Orchestration.dispatch(message(b, text_b, "start_immediately", "steer")))
    replies = [Task.await(first, @wait_ms), reply_b]
    ending = ending ++ unfinished_runs()
    {replies, settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  def interrupt do
    ending = active_runs()
    reply(Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid}), ending)
  end

  # Sends `a`, after which Pi compacts for a while rejecting prompts (as Pi
  # 1.4 does), then `b` at once. `b` must reach Pi once, after the compaction.
  # `:unheard`: Pi says it compacts only as `b`'s prompt reaches it, with history `b`
  # hands over (its mark, `unconfirmedRunId`). The compaction then shows in `b`'s turn
  # before Pi turns `b` back, and confirms nothing: the mark stands until Pi takes `b`.
  def send_compacted(a, b, heard) do
    fake_config(&Map.put(&1, "rejectWhileCompacting", true))
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    text = if heard == :heard, do: "aftercompact #{a}", else: "unheard #{a}"
    first = Orchestration.dispatch(message(a, text, "queue_after_active", "auto"))
    done = settled(unfinished_runs(), deadline)
    second = Orchestration.dispatch(message(b, "joins #{b}", "queue_after_active", "auto"))
    held = if heard == :unheard, do: unheard_mark(b), else: :ok
    projection = settled([], System.monotonic_time(:millisecond) + @wait_ms)
    taken = if heard == :unheard, do: handoff_mark(b), else: nil
    fake_config(&Map.delete(&1, "rejectWhileCompacting"))
    log = fake_log()
    accepted = for {%{"accepted" => "joins " <> ^b}, i} <- log, do: i

    compaction =
      for {%{"compaction" => phase}, i} <- log, i < List.first(accepted, 0), do: phase

    reply =
      cond do
        match?({:timeout, _}, done) -> {:error, "#{a} never ended"}
        length(accepted) != 1 -> {:error, "Pi took #{b} #{length(accepted)} times"}
        List.last(compaction) != "end" -> {:error, "Pi took #{b} while it compacted"}
        held != :ok -> held
        taken != nil -> {:error, "#{b} works with its handoff unconfirmed"}
        true -> answer(first) |> both(answer(second))
      end

    {reply, projection}
  end

  # Marks the history `b`'s run hands over before Pi hears of `b`, lets Pi turn `b`
  # back, and checks the compaction Pi announced first left the mark standing.
  defp unheard_mark(b) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    dir = Application.get_env(:hal_c2, :pi_prop_fake_dir)
    run = await(&Enum.find(runs(&1), fn run -> run["userMessageId"] == b end), deadline)

    with {:ok, %{"id" => id, "providerThreadId" => thread}} <- run do
      {:ok, _} =
        HalC2.Streams.commit(@tid, :thread, [
          {"provider-thread", thread,
           %{"s" => %{"unconfirmedRunId" => id, "unconfirmedSince" => 0}}}
        ])
    end

    File.touch!(Path.join(dir, "unheard-go"))
    rejected = await_log(&match?(%{"rejected" => "joins " <> ^b}, &1))

    shown =
      with {:ok, %{"id" => id}} <- run,
           do:
             await(
               fn state ->
                 Enum.find(
                   StreamState.list(state, "turn-item"),
                   &(&1["runId"] == id and &1["type"] == "compaction")
                 )
               end,
               deadline
             )

    # The rejection has reached the runtime once it holds the prompt again.
    [{pid, _}] = Registry.lookup(HalC2.Pi.Registry, @tid)
    turned_back = await_until(fn -> :sys.get_state(pid).prompt_held == :rejected end, deadline)
    mark = handoff_mark(b)
    File.rm(Path.join(dir, "unheard-go"))

    cond do
      run == :timeout or rejected == :timeout -> {:error, "Pi never turned #{b} back"}
      shown == :timeout -> {:error, "#{b}'s turn does not show the compaction"}
      turned_back == :timeout -> {:error, "the runtime never held #{b} again"}
      mark != elem(run, 1)["id"] -> {:error, "the compaction confirmed #{b}'s handoff"}
      true -> :ok
    end
  end

  defp handoff_mark(b) do
    state = current()

    with %{"providerThreadId" => id} <- Enum.find(runs(state), &(&1["userMessageId"] == b)),
         do: StreamState.get(state, "provider-thread")[id]["unconfirmedRunId"]
  end

  defp await_until(done?, deadline) do
    cond do
      done?.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        receive do
        after
          20 -> await_until(done?, deadline)
        end
    end
  end

  defp both(:ok, second), do: second
  defp both(first, _second), do: first

  # Steers the turn while Pi compacts, waits until the runtime holds the
  # steer, then stops the turn: the sender hears and Pi never takes it.
  def steer_held_stop(msg) do
    ending = active_runs()
    text = "steer #{msg}"

    steered =
      Task.async(fn ->
        Orchestration.dispatch(message(msg, text, "start_immediately", "steer"))
      end)

    held = await_held(System.monotonic_time(:millisecond) + @wait_ms)
    {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})

    result =
      case Task.yield(steered, @wait_ms) || Task.shutdown(steered, :brutal_kill) do
        {:ok, reply} -> reply
        _ -> {:error, "held steer never answered"}
      end

    projection = settled(ending, System.monotonic_time(:millisecond) + @wait_ms)

    reply =
      cond do
        not held -> {:error, "the steer was never held"}
        Enum.any?(fake_log(), &match?({%{"accepted" => ^text}, _}, &1)) -> {:error, "Pi took it"}
        true -> answer(result)
      end

    {reply, projection}
  end

  defp await_held(deadline) do
    held =
      case Registry.lookup(HalC2.Pi.Registry, @tid) do
        [{pid, _}] -> :sys.get_state(pid).held_steers != []
        _ -> false
      end

    cond do
      held ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        receive do
        after
          20 -> await_held(deadline)
        end
    end
  end

  # The fake's log, each entry with its position.
  defp fake_log do
    Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "log.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.with_index()
  end

  # Steers `/compact` at a Pi whose compaction outlasts the test, then stops
  # the turn while it runs: the steer is answered and no compaction state may
  # leak into whatever turn comes next.
  def steer_compact_stop(msg) do
    ending = active_runs()
    before = compact_count()

    steered =
      Task.async(fn ->
        Orchestration.dispatch(message(msg, "/compact", "start_immediately", "steer"))
      end)

    await_compact(before + 1, System.monotonic_time(:millisecond) + @wait_ms)
    {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})

    result =
      case Task.yield(steered, @wait_ms) || Task.shutdown(steered, :brutal_kill) do
        {:ok, reply} -> reply
        _ -> {:error, "steered compact never answered"}
      end

    {answer(result), settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # As `steer_compact_stop/1`, but Pi's delayed answer is a failure with no
  # compaction events: only the compaction task's own reply can end the
  # abandonment. Waits until that answer is on the wire (the fake logs it),
  # then puts the fake's slow compaction back.
  def steer_compact_stop_fail(msg) do
    ending = active_runs()
    before = compact_count()
    answered = answered_count()

    fake_config(&Map.merge(&1, %{"compactDelaySec" => 1, "compactError" => "nothing to compact"}))

    steered =
      Task.async(fn ->
        Orchestration.dispatch(message(msg, "/compact", "start_immediately", "steer"))
      end)

    await_compact(before + 1, System.monotonic_time(:millisecond) + @wait_ms)
    {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})

    result =
      case Task.yield(steered, @wait_ms) || Task.shutdown(steered, :brutal_kill) do
        {:ok, reply} -> reply
        _ -> {:error, "steered compact never answered"}
      end

    await_answered(answered + 1, System.monotonic_time(:millisecond) + @wait_ms)

    fake_config(fn cfg ->
      cfg |> Map.delete("compactError") |> Map.put("compactDelaySec", 30)
    end)

    {answer(result), settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # The fake logged Pi's `compact`, so the runtime's compaction task is out.
  defp compact_count do
    log = Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "log.jsonl")

    case File.read(log) do
      {:ok, text} -> text |> String.split(~s("type": "compact")) |> length() |> Kernel.-(1)
      _ -> 0
    end
  end

  defp await_compact(count, deadline) do
    if compact_count() < count and System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        20 -> await_compact(count, deadline)
      end
    end
  end

  # How many delayed compactions the fake has answered (it logs each answer
  # once it is on the wire).
  defp answered_count do
    log = Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "log.jsonl")

    case File.read(log) do
      {:ok, text} -> text |> String.split("compact_answered") |> length() |> Kernel.-(1)
      _ -> 0
    end
  end

  defp await_answered(count, deadline) do
    if answered_count() < count and System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        20 -> await_answered(count, deadline)
      end
    end
  end

  # Rewrites the fake's config; the fake reads it again on every command.
  defp fake_config(fun) do
    path = Path.join(Application.get_env(:hal_c2, :pi_prop_fake_dir), "config.json")
    File.write!(path, JSON.encode!(fun.(JSON.decode!(File.read!(path)))))
  end

  defp message(msg, text, mode, intent) do
    %{
      "type" => "message.dispatch",
      "threadId" => @tid,
      "messageId" => msg,
      "text" => text,
      "attachments" => [],
      "modelSelection" => @model,
      "dispatchMode" => %{"type" => mode},
      "deliveryIntent" => intent
    }
  end

  # --- the real side ----------------------------------------------------------------

  defp install_fake(home) do
    dir = Path.join(home, "fake-pi")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "config.json"),
      JSON.encode!(%{
        "turns" => @turns,
        # Pi reports how full its conversation is after every turn, so a later one
        # resumes it rather than a new one taking the whole thread.
        "usage" => %{"totalTokens" => 1_050, "input" => 1_000, "output" => 50},
        "compactDelaySec" => 30,
        "handledCommands" => ["/stats"],
        # `send_rewound/3` names where each rewind goes.
        "rewindCommands" => %{},
        # Only an extension's command settles after two idle checks; a
        # prompt template expands into an agent prompt like any message.
        "commands" => [
          %{"name" => "stats", "source" => "extension"},
          %{"name" => "rewind", "source" => "extension"},
          %{"name" => "review", "source" => "prompt"}
        ],
        "silentCommands" => ["silent"]
      })
    )

    bin = Path.join([dir, "bin", "pi"])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{dir}' FAKE_BIN="$0"
    exec python3 -u '#{@fake_pi}' "$@"
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  defp current, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp active_runs, do: for(run <- runs(current()), run["status"] in @active, do: run["id"])

  defp unfinished_runs,
    do: for(run <- runs(current()), run["status"] not in @finished, do: run["id"])

  defp reply(result, ending),
    do: {answer(result), settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}

  defp answer({:ok, %{}}), do: :ok
  defp answer({:error, message}), do: {:error, message}
  defp answer(other), do: {:unexpected, other}

  # Waits until the runs in `ending` ended, nothing is starting, and a running turn
  # began saying "Working on it.", after which the fake waits.
  defp settled(ending, deadline) do
    flush()
    state = current()
    by_id = Map.new(runs(state), &{&1["id"], &1})

    working? = fn run ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["runId"] == run["id"] and &1["type"] == "assistant_message")
      )
    end

    quiet? =
      not Enum.any?(runs(state), &(&1["status"] in ~w(preparing starting))) and
        Enum.all?(ending, &(by_id[&1] == nil or by_id[&1]["status"] in @finished)) and
        Enum.all?(runs(state), &(&1["status"] not in @active or working?.(&1)))

    if quiet? do
      projection(state)
    else
      receive do
        {:hal_c2_stream, @tid, _} -> settled(ending, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, projection(state)}
      end
    end
  end

  defp flush do
    receive do
      {:hal_c2_stream, @tid, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp projection(state) do
    %{
      runs: for(run <- runs(state), do: {woken_id(run["userMessageId"]), run["status"]}),
      compactions:
        for(
          item <- state |> StreamState.list("turn-item") |> Enum.sort_by(& &1["ordinal"]),
          item["type"] == "compaction",
          do: item["summary"]
        ),
      # The turns whose tool item lists an image stored with the thread.
      images:
        for(
          item <- StreamState.list(state, "turn-item"),
          item["type"] == "dynamic_tool",
          %{"type" => "image"} = image <- item["attachments"] || [],
          File.read(HalC2.Attachments.path(image) || "") == {:ok, Base.decode64!(@png)},
          run <- runs(state),
          run["id"] == item["runId"],
          do: run["userMessageId"]
        ),
      # The status of each entry Pi's own subagents have, by the message whose turn
      # handed out its task.
      subagents:
        for(
          item <- StreamState.list(state, "turn-item"),
          item["type"] == "subagent",
          run <- runs(state),
          run["id"] == item["runId"],
          do: {run["userMessageId"], item["status"]}
        ),
      # Pi answers a steer it took in "steered: <text>", and one it ran on its own
      # "Reply to <text> after [...]".
      replies:
        for(
          m <- state |> StreamState.list("message") |> Enum.sort_by(& &1["createdAt"]),
          m["role"] == "assistant",
          [_, msg] <- [Regex.run(~r/^(?:steered: |Reply to )steer (m\d+)/, m["text"] || "")],
          do: msg
        )
    }
  end
end
