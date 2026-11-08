defmodule HalC2.Orchestration.HandoffTest do
  use ExUnit.Case, async: true

  alias HalC2.Orchestration.Handoff

  @header "Imported conversation history from the previous HAL-C2 orchestrator. Use it as context; do not repeat it unless the user asks."

  defp user(text), do: %{"type" => "user_message", "text" => text}
  defp assistant(text), do: %{"type" => "assistant_message", "text" => text}

  # Clients let a started thread change provider when its session says so.
  test "every provider's session says it takes a handoff from another provider" do
    for driver <- ["codex", "claudeAgent", "opencode", "cursor"] do
      session = HalC2.Orchestration.Entities.provider_session("s", "/w", "m", "t", driver, driver)
      assert session["capabilities"]["sessions"]["supportsProviderSwitchingViaHandoff"]
    end
  end

  test "a short imported conversation is kept whole, oldest first" do
    items = [user("hi"), %{"type" => "command_execution", "input" => "ls"}, assistant("hello")]
    assert Handoff.legacy_summary(items) == "#{@header}\n\nUser:\nhi\n\nAssistant:\nhello"
  end

  test "the newest messages win, and the first that does not fit keeps its end cut at a word" do
    words = fn prefix -> Enum.map_join(1..4_000, " ", &"#{prefix}#{&1}") end
    oldest = user("oldest message")
    older = user(words.("w"))
    newest = assistant(String.duplicate("n", 20_000))

    summary = Handoff.legacy_summary([oldest, older, newest])
    assert String.length(summary) <= 32_000
    refute summary =~ "oldest message"

    [@header, "User:\n... " <> kept, "Assistant:\n" <> reply] = String.split(summary, "\n\n")
    assert reply == String.duplicate("n", 20_000)
    # The kept end of the older message starts at a whole word and runs to its end.
    assert [first | _] = String.split(kept, " ")
    assert first =~ ~r/^w\d+$/
    assert String.ends_with?(older["text"], " " <> kept)
  end

  test "a message with no word break inside the budget is cut where the budget ends" do
    body = String.duplicate("x", 40_000)
    summary = Handoff.legacy_summary([user(body)])
    assert String.length(summary) == 32_000
    assert [@header, "User:\n... " <> kept] = String.split(summary, "\n\n")
    assert kept == String.duplicate("x", String.length(kept))
  end

  # Folds `{kind, entity}` pairs into a thread's state, one event each.
  defp state(entities) do
    entities
    |> Enum.with_index(1)
    |> Enum.reduce(HalC2.StreamState.new(), fn {{kind, entity}, seq}, state ->
      HalC2.StreamState.apply_event(state, %{
        seq: seq,
        kind: kind,
        entity: entity["id"],
        patch: %{"s" => entity}
      })
    end)
  end

  # A finished run: its request, a command when given, and its answer.
  defp turn(ordinal, request, answer, command \\ nil) do
    run = "run-#{ordinal}"
    at = fn step -> "2026-10-01T10:0#{ordinal}:0#{step}Z" end

    message = fn role, text, step ->
      {"message",
       %{"id" => "#{role}-#{ordinal}", "runId" => run, "role" => role, "text" => text}
       |> Map.put("createdAt", at.(step))}
    end

    [
      {"run", %{"id" => run, "ordinal" => ordinal, "status" => "completed"}},
      message.("user", request, 0),
      command &&
        {"turn-item",
         Map.merge(
           %{"id" => "command-#{ordinal}", "runId" => run, "type" => "command_execution"},
           Map.put(command, "startedAt", at.(1))
         )},
      message.("assistant", answer, 2)
    ]
    |> Enum.filter(& &1)
  end

  test "a command is handed over between its request and the answer, with how it ended" do
    command = %{
      "input" => "mix test",
      "status" => "failed",
      "exitCode" => 2,
      "output" => "1 failure\n"
    }

    running = %{"input" => "sleep 100", "status" => "running"}

    state =
      state(
        turn(1, "run the tests", "one test fails", command) ++
          [
            {"turn-item",
             %{"id" => "c", "runId" => "run-1", "type" => "command_execution"}
             |> Map.merge(running)}
          ]
      )

    assert Handoff.transcript(state, 2) ==
             "## Run 1\n\nUser: run the tests\n\nCommand: mix test\nExit code: 2\n1 failure\n\nAssistant: one test fails"
  end

  test "a command cut short by an interrupt is handed over as interrupted" do
    command = %{"input" => "mix test", "status" => "interrupted", "output" => "Compiling\n"}

    state =
      state(turn(1, "run the tests", "", command))
      |> HalC2.StreamState.apply_event(%{
        seq: 100,
        kind: "run",
        entity: "run-1",
        patch: %{"s" => %{"id" => "run-1", "ordinal" => 1, "status" => "interrupted"}}
      })

    assert Handoff.transcript(state, 2) ==
             "## Run 1 (interrupted)\n\nUser: run the tests\n\nCommand: mix test\nInterrupted before it finished\nCompiling"
  end

  # Found by the Claude session property: a refused `/compact` on an empty thread
  # handed "User: /compact" to the next model, so its `/compact` was not refused.
  test "a bare /compact or /logout is not handed over as conversation" do
    state =
      state(
        turn(1, "/compact", "") ++
          turn(2, " /LOGOUT ", "") ++
          [{"run", %{"id" => "run-1", "ordinal" => 1, "status" => "failed"}}]
      )

    assert Handoff.transcript(state, 3) == nil

    assert Handoff.transcript(state(turn(1, "/compact", "") ++ turn(2, "hi", "hello")), 3) ==
             "## Run 2\n\nUser: hi\n\nAssistant: hello"
  end

  test "a failed command with no exit code is handed over as failed" do
    command = %{"input" => "mix test", "status" => "failed", "output" => "1 failure\n"}

    assert Handoff.transcript(state(turn(1, "run the tests", "one fails", command)), 2) ==
             "## Run 1\n\nUser: run the tests\n\nCommand: mix test\nFailed\n1 failure\n\nAssistant: one fails"
  end

  test "long command output keeps its end" do
    output = String.duplicate("a", 3_000) <> "\n3 tests, 0 failures"

    command = %{
      "input" => "mix test",
      "status" => "completed",
      "exitCode" => 0,
      "output" => output
    }

    assert [_, _, "Command: mix test\nExit code: 0\n... " <> kept, _] =
             state(turn(1, "run the tests", "all green", command))
             |> Handoff.transcript(2)
             |> String.split("\n\n")

    assert String.length(kept) == 2_000
    assert String.ends_with?(kept, "\n3 tests, 0 failures")
  end

  test "a history too long keeps every request, the newest run whole, and condenses the oldest" do
    long = String.duplicate("x", 40_000)

    state =
      state(
        turn(1, "the original request", "first " <> long, %{
          "input" => "mix test",
          "status" => "failed",
          "exitCode" => 1
        }) ++
          turn(2, "second request", "second " <> long) ++
          turn(3, "newest request", "done", %{
            "input" => "ls",
            "status" => "completed",
            "exitCode" => 0
          })
      )

    transcript = Handoff.transcript(state, 4)
    assert String.length(transcript) <= 60_000

    assert [note, "## Run 1: condensed", "User: the original request", outcomes, final | rest] =
             String.split(transcript, "\n\n")

    assert note =~ "A run marked condensed keeps what the user said"
    assert outcomes == "Commands, as each last ended:\n- mix test: Exit code: 1"
    # The final answer keeps its start and end, with a mark where it was cut.
    assert "Assistant: first xxx" <> _ = final
    assert final =~ ~r/\[\.\.\. \d+ characters cut here \.\.\.\]/
    assert String.length(final) < 2_100

    assert rest == [
             "## Run 2",
             "User: second request",
             "Assistant: second " <> long,
             "## Run 3",
             "User: newest request",
             "Command: ls\nExit code: 0",
             "Assistant: done"
           ]
  end

  # A newest run whose one step was too long for its share once went request only, and
  # the older run took the room whole: its newest steps, counted as `-0`, were all of them.
  test "the newest run's one long answer goes before an older run's" do
    long = String.duplicate("x", 35_000)

    for {newest, kept} <- [{long, :whole}, {long <> long, :cut}] do
      state =
        state(
          turn(1, "Try three", "oldest-start " <> long) ++
            turn(2, "Try four", newest <> " newest-end")
        )

      transcript = Handoff.transcript(state, 3)
      assert String.length(transcript) <= 60_000

      assert [
               _note,
               "## Run 1: condensed",
               "User: Try three",
               "Assistant: oldest-start x" <> _ | rest
             ] =
               String.split(transcript, "\n\n")

      case kept do
        :whole ->
          assert rest == ["## Run 2", "User: Try four", "Assistant: #{newest} newest-end"]

        :cut ->
          assert ["## Run 2: newest steps only", "User: Try four", answer] = rest

          assert answer =~
                   ~r/\AAssistant: x+\n\[\.\.\. \d+ characters cut here \.\.\.\]\nx+ newest-end\z/

          # It takes what the older run does not need.
          assert String.length(answer) > 50_000
      end
    end
  end

  test "a history exactly its budget long is whole" do
    run = fn ordinal ->
      %{
        ordinal: ordinal,
        provider: nil,
        status: "completed",
        entries: [{:user, "User: hi"}],
        files: []
      }
    end

    whole = "## Run 1\n\nUser: hi\n\n## Run 2\n\nUser: hi"
    assert Handoff.history([run.(1), run.(2)], String.length(whole)) == whole
  end

  # proof/models/handoff_history.maude found it: what was said fitting whole with no room
  # left for the newest run's answer once went whole and hid it, where a smaller budget
  # cut what was said to show it.
  test "a bigger budget never hides the newest run's last step" do
    runs = [
      history_run(1, [{:user, "User: " <> String.duplicate("ask ", 1_000)}]),
      history_run(2, [
        {:user, "User: and now?"},
        {:assistant, "Assistant: " <> String.duplicate("done ", 600)}
      ])
    ]

    for max_chars <- 3_000..7_000//100 do
      history = Handoff.history(runs, max_chars)
      assert String.length(history) <= max_chars
      assert history =~ "Assistant: done", "hidden at #{max_chars}"
    end
  end

  # The property found this: a newest run's one step too short to cut could only be
  # shown with the run in full, its long notice whole, so a budget that kept an older
  # run hid it.
  test "a newest run's one short step is shown without its notices whole" do
    files = for n <- 1..10, do: %{"path" => "f#{n}", "kind" => "modified", "additions" => n}

    runs = [
      history_run(1, [{:user, "User: hi"}]),
      %{history_run(2, [{:user, "User: " <> String.duplicate("x", 725)}]) | files: files},
      history_run(3, [
        {:command, %{text: "Command: ls\nExit code: 0\nx", input: "ls", ended: "Exit code: 0"}},
        {:notice, %{text: "Notice: " <> String.duplicate("x", 347), line: "Notice: restarted"}}
      ])
    ]

    shown =
      for max_chars <- 0..2_000, do: (Handoff.history(runs, max_chars) || "") =~ "Command: ls\n"

    first = Enum.find_index(shown, & &1)
    assert first
    assert Enum.all?(Enum.drop(shown, first))
  end

  # The model found these too: in less room than the note that every run is left out
  # takes, there is no history; and a lone run cut to fit still says it is cut.
  test "a history too small for its note is none, and a lone cut run keeps its note" do
    runs = [history_run(1, [{:user, "User: " <> String.duplicate("ask ", 1_000)}])]
    note = "[This history is condensed to fit. Run 1 is left out.]"

    assert Handoff.history(runs, 0) == nil
    assert Handoff.history(runs, String.length(note) - 1) == nil
    assert Handoff.history(runs, 600) == note

    cut = Handoff.history(runs, 1_000)
    assert String.length(cut) <= 1_000

    assert "[This history is condensed to fit. What the user said is cut where it is marked.]" <>
             "\n\n## Run 1\n\nUser: ask" <> _ = cut
  end

  defp history_run(ordinal, entries),
    do: %{ordinal: ordinal, provider: nil, status: "completed", entries: entries, files: []}

  defp item(ordinal, id, fields),
    do: {"turn-item", Map.merge(%{"id" => id, "runId" => "run-#{ordinal}"}, fields)}

  test "a message the MC sent is a notice, and one another agent sent is said as theirs" do
    message = fn id, fields, at ->
      {"message",
       Map.merge(
         %{"id" => id, "runId" => "run-1", "role" => "user", "createdAt" => at},
         fields
       )}
    end

    state =
      state([
        {"run", %{"id" => "run-1", "ordinal" => 1, "status" => "completed"}},
        message.("m1", %{"text" => "fix the build"}, "2026-10-01T10:00:00Z"),
        message.(
          "m2",
          %{
            "text" => "<delegated_task_result>green</delegated_task_result>",
            "notification" => %{"summary" => "A delegated task finished"}
          },
          "2026-10-01T10:00:01Z"
        ),
        message.(
          "m3",
          %{"text" => "the worker's report", "createdBy" => "agent", "senderThreadId" => "w"},
          "2026-10-01T10:00:02Z"
        )
      ])

    assert Handoff.transcript(state, 2) ==
             Enum.join(
               [
                 "## Run 1",
                 "User: fix the build",
                 "Notice: <delegated_task_result>green</delegated_task_result>",
                 "Sent by another agent: the worker's report"
               ],
               "\n\n"
             )
  end

  test "the user's answers to the agent's questions are handed over with what was asked" do
    state =
      state(
        turn(1, "pick a database", "using postgres") ++
          [
            item(1, "ask", %{
              "type" => "user_input_request",
              "startedAt" => "2026-10-01T10:01:01Z",
              "questions" => [
                %{"id" => "q1", "question" => "Which database?"},
                %{"id" => "q2", "question" => "Which regions?"}
              ],
              "questionAnswer" => %{"answers" => %{"q2" => ["eu", "us"], "q1" => "postgres"}}
            })
          ]
      )

    assert Handoff.transcript(state, 2) ==
             Enum.join(
               [
                 "## Run 1",
                 "User: pick a database",
                 "Asked: Which database?\nAnswered: postgres\nAsked: Which regions?\nAnswered: eu, us",
                 "Assistant: using postgres"
               ],
               "\n\n"
             )
  end

  test "the files a run changed are handed over after it" do
    files =
      for n <- 1..12,
          do: %{
            "path" => "lib/f#{n}.ex",
            "kind" => if(n == 1, do: "added", else: "modified"),
            "additions" => n,
            "deletions" => 0
          }

    state =
      state(
        turn(1, "refactor", "done") ++
          [
            item(1, "cp", %{
              "type" => "checkpoint",
              "files" => files,
              "completedAt" => "2026-10-01T10:01:09Z"
            })
          ]
      )

    assert [_, _, _, "Files changed: lib/f1.ex (added) +1 -0, lib/f2.ex +2 -0" <> rest] =
             String.split(Handoff.transcript(state, 2), "\n\n")

    assert String.ends_with?(rest, "lib/f10.ex +10 -0 and 2 more")
  end

  # The source of a fork at run 1, with run 2 after it on one provider thread.
  # `first` is run 1's native turn id (nil: none was recorded; :gone: its
  # provider turn is not recorded at all).
  defp fork_source(first) do
    turn = fn ordinal, native ->
      {"provider-turn",
       %{
         "id" => "pturn-#{ordinal}",
         "providerThreadId" => "pthread-1",
         "runAttemptId" => "attempt-#{ordinal}",
         "nativeTurnRef" => %{"driver" => "x", "nativeId" => native},
         "ordinal" => ordinal,
         "status" => "completed"
       }}
    end

    state(
      [
        {"run-attempt", %{"id" => "attempt-1", "runId" => "run-1"}},
        {"run-attempt", %{"id" => "attempt-2", "runId" => "run-2"}},
        if(first == :gone, do: nil, else: turn.(1, first)),
        turn.(2, "native-2")
      ]
      |> Enum.filter(& &1)
    )
  end

  @point %{
    "runId" => "run-1",
    "providerThreadRef" => %{"driver" => "x", "nativeId" => "native-thread-1"}
  }

  test "a native fork cuts after the recorded turn" do
    assert Handoff.fork_boundary(fork_source("native-1"), @point, "codex") ==
             {:native, "native-1"}

    assert Handoff.fork_boundary(fork_source("native-1"), @point, "claudeAgent") ==
             {:native, "native-1"}
  end

  test "a fork point whose turn is not recorded cannot be honoured" do
    assert {:error, message} = Handoff.fork_boundary(fork_source(:gone), @point, "codex")
    assert message =~ "Cannot fork Codex thread from that turn"
  end

  test "Codex trims the turns after a fork point it kept no reference for" do
    assert Handoff.fork_boundary(fork_source(nil), @point, "codex") == {:trim, 1, "native-2"}
  end

  test "Claude cannot fork from a turn with no recorded message position" do
    assert {:error, message} = Handoff.fork_boundary(fork_source(nil), @point, "claudeAgent")
    assert message =~ "no message position was recorded"
    # A synthetic turn id is no position either.
    assert {:error, _} = Handoff.fork_boundary(fork_source("turn:1"), @point, "claudeAgent")
  end

  test "turns of runs rolled back since are not after the boundary" do
    source =
      HalC2.StreamState.apply_event(fork_source(nil), %{
        seq: 100,
        kind: "run",
        entity: "run-2",
        patch: %{"s" => %{"id" => "run-2", "ordinal" => 2, "status" => "rolled_back"}}
      })

    assert Handoff.fork_boundary(source, @point, "codex") == {:trim, 0, nil}
    assert Handoff.fork_boundary(source, @point, "claudeAgent") == {:trim, 0, nil}
  end

  test "no recorded provider turns at all is unknown, not an error" do
    assert Handoff.fork_boundary(state([]), @point, "codex") == :unknown
  end

  test "the note that messages were left out counts against the budget" do
    # The two runs whole, with their headings and the blank lines between their five
    # parts, are one character over 60,000; condensed, they must fit with the note.
    fixed =
      String.length(
        "## Run 1" <>
          "User: first" <> "Assistant: " <> "## Run 2" <> "User: second" <> "Assistant: "
      ) + 100 + 5 * 2

    answer = String.duplicate("y", 60_001 - fixed)

    state = state(turn(1, "first", String.duplicate("x", 100)) ++ turn(2, "second", answer))

    assert "[This history is condensed to fit." <> _ = transcript = Handoff.transcript(state, 3)
    assert String.length(transcript) <= 60_000
  end

  # A thread a restart left a note on, about the background work its last turn left.
  defp noted do
    state([
      {"thread", %{"id" => "t", "restartNote" => "The server stopped and ended `npm run dev`."}},
      {"provider-thread",
       %{"id" => "pt", "nativeThreadRef" => %{"driver" => "claudeAgent", "nativeId" => "n"}}}
    ])
  end

  defp plan(state, message) do
    ids = %{
      driver: "claudeAgent",
      run: "run-2",
      message: message,
      thread: "t",
      provider_thread: "pt"
    }

    Handoff.plan(
      state,
      HalC2.StreamState.get(state, "provider-thread")["pt"],
      ids,
      2,
      "2026-10-01T10:02:00Z",
      %{text: "", attachments: []}
    )
  end

  defp consumes_note?(changes),
    do: Enum.any?(changes, &match?({"thread", "t", %{"u" => ["restartNote"]}}, &1))

  test "the user's next turn after a restart hears its note, and takes it" do
    plan = plan(noted(), "message:user-2")
    assert plan.context =~ "<server_restart>\nThe server stopped and ended `npm run dev`."
    assert consumes_note?(plan.changes)
  end

  # The continuation says what the restart ended itself; one never sent leaves the note.
  test "the restart's own continuation takes its note without repeating it" do
    plan = plan(noted(), "message:restart-continuation:run-1")
    refute (plan.context || "") =~ "<server_restart>"
    assert consumes_note?(plan.changes)
  end

  describe "what a provider thread missed" do
    # Runs alternate between the provider thread "pt" and another, "po": `{ordinal,
    # provider thread, status, request, extra run fields}`, each answered when completed.
    defp runs(specs) do
      for {ordinal, owner, status, request, extra} <- specs,
          {kind, entity} <- turn(ordinal, request, "answer #{ordinal}"),
          kind != "message" or entity["role"] == "user" or status == "completed" do
        if kind == "run",
          do:
            {kind,
             Map.merge(entity, %{"providerThreadId" => owner, "status" => status})
             |> Map.merge(extra)},
          else: {kind, entity}
      end
    end

    defp provider_thread(fields),
      do:
        {"provider-thread",
         Map.merge(
           %{
             "id" => "pt",
             "nativeThreadRef" => %{"driver" => "claudeAgent", "nativeId" => "n"}
           },
           fields
         )}

    defp plan_run(state, ordinal) do
      ids = %{driver: "claudeAgent", run: "run-#{ordinal}", thread: "t", provider_thread: "pt"}

      Handoff.plan(
        state,
        HalC2.StreamState.get(state, "provider-thread")["pt"],
        ids,
        ordinal,
        "2026-10-01T10:09:00Z",
        %{text: "next", attachments: []}
      )
    end

    # A wake's turn is the provider thread's own: it answered it itself.
    test "a delta leaves out the provider thread's own completed runs between the ones it missed" do
      state =
        state(
          runs([
            {1, "pt", "completed", "one", %{}},
            {2, "po", "completed", "two", %{}},
            {3, "pt", "completed", "woke", %{}},
            {4, "po", "completed", "four", %{}}
          ]) ++ [provider_thread(%{"lastRunOrdinal" => 1})]
        )

      plan = plan_run(state, 5)
      assert plan.context =~ "User: two"
      assert plan.context =~ "User: four"
      refute plan.context =~ "woke"
      refute plan.new_conversation
      assert plan.unconfirmed_since == 1
    end

    test "a run refused before it reached a provider is in no handoff" do
      state =
        state(
          runs([
            {1, "pt", "completed", "one", %{}},
            {2, "po", "failed", "refused", %{"refused" => true}},
            {3, "po", "completed", "three", %{}}
          ]) ++ [provider_thread(%{"lastRunOrdinal" => 1})]
        )

      plan = plan_run(state, 4)
      assert plan.context =~ "User: three"
      refute plan.context =~ "refused"
      refute Handoff.transcript(state, 4) =~ "refused"
    end

    # Run 4 handed over run 3 and was never answered; background work keeps the
    # conversation from being replaced. Run 2 had what run 1 did.
    defp unconfirmed(report) do
      state(
        runs([
          {1, "po", "completed", "zero", %{}},
          {2, "pt", "completed", "one", %{}},
          {3, "po", "completed", "two", %{}},
          {4, "pt", "interrupted", "three", %{"sentTokens" => 100}}
        ]) ++
          [
            provider_thread(%{
              "lastRunOrdinal" => 4,
              "unconfirmedRunId" => "run-4",
              "unconfirmedSince" => 2,
              "pendingBackgroundTasks" => [%{"taskId" => "task-1", "taskType" => "local_bash"}]
            })
          ] ++ report
      )
    end

    test "an unconfirmed handoff goes again into a busy conversation, only what came after it" do
      plan = plan_run(unconfirmed([]), 5)
      refute plan.new_conversation
      assert plan.refusal == nil
      assert plan.context =~ "User: two"
      assert plan.context =~ "User: three"
      refute plan.context =~ "User: zero"
      refute plan.context =~ "User: one"
      assert plan.unconfirmed_since == 2
    end

    test "an unconfirmed handoff with no room in a busy conversation is refused" do
      full =
        {"provider-turn",
         %{
           "id" => "pturn-1",
           "ordinal" => 2,
           "providerThreadId" => "pt",
           "tokenUsage" => %{"usedTokens" => 120_000, "maxTokens" => 128_000}
         }}

      plan = plan_run(unconfirmed([full]), 5)
      refute plan.new_conversation
      assert %{"code" => "conversation_busy"} = plan.refusal
    end

    test "an unconfirmed handoff with no background work starts a new conversation" do
      state =
        unconfirmed([])
        |> HalC2.StreamState.apply_event(%{
          seq: 1_000,
          kind: "provider-thread",
          entity: "pt",
          patch: %{"u" => ["pendingBackgroundTasks"]}
        })

      plan = plan_run(state, 5)
      assert plan.new_conversation
      assert plan.context =~ "User: zero"
      assert plan.unconfirmed_since == 0
    end

    # A rewind dropped run 5; the background work an earlier run started still runs.
    test "a rewound run leaves the background work earlier runs started in the way of a new conversation" do
      state =
        unconfirmed(runs([{5, "pt", "rolled_back", "dropped", %{}}]))

      plan = plan_run(state, 6)
      refute plan.new_conversation
      assert plan.context =~ "User: three"
      refute plan.context =~ "dropped"
    end

    # Its last run opened a conversation and failed before saying its id: the session
    # still holds that conversation, which the whole thread would go into again.
    test "a provider thread that lost its conversation's id leaves the session holding one" do
      runs =
        runs([
          {1, "pt", "completed", "one", %{"startedAt" => "2026-10-01T10:01:00Z"}},
          {2, "po", "completed", "two", %{}}
        ])

      lost = provider_thread(%{"nativeThreadRef" => nil, "lastRunOrdinal" => 1})

      plan = plan_run(state(runs ++ [lost]), 3)
      assert plan.new_conversation
      assert plan.context =~ "User: one"
      assert plan.context =~ "User: two"

      busy =
        provider_thread(%{
          "nativeThreadRef" => nil,
          "lastRunOrdinal" => 1,
          "pendingBackgroundTasks" => [%{"taskId" => "task-1", "taskType" => "local_bash"}]
        })

      refute plan_run(state(runs ++ [busy]), 3).new_conversation
    end

    # Its only run ended while its session started for it: the session took no turn,
    # and lets go of nothing; the next run waits behind that start instead of failing
    # on a session too busy to let go.
    test "a provider thread no run began in starts its first conversation in the session" do
      runs = runs([{1, "pt", "interrupted", "one", %{}}])
      unopened = provider_thread(%{"nativeThreadRef" => nil})

      plan = plan_run(state(runs ++ [unopened]), 2)
      refute plan.new_conversation
      assert plan.refusal == nil
    end

    # A thread moved with the provider's session after a handoff that was never
    # confirmed: the session may lack it, and the MC it came from cannot send it again.
    test "a carried session whose handoff is unconfirmed gives way to a new conversation" do
      runs = runs([{1, "po", "completed", "one", %{}}, {2, "pt", "interrupted", "two", %{}}])

      carried = fn fields ->
        provider_thread(
          Map.merge(
            %{
              "nativeThreadRef" => nil,
              "lastRunOrdinal" => 2,
              "carriedSession" => %{"driver" => "claudeAgent", "path" => "/s.jsonl"}
            },
            fields
          )
        )
      end

      assert %{carried: true} = plan_run(state(runs ++ [carried.(%{})]), 3).fork

      plan = plan_run(state(runs ++ [carried.(%{"unconfirmedRunId" => "run-2"})]), 3)
      assert plan.fork == nil
      assert plan.context =~ "User: one"
      assert plan.context =~ "User: two"

      assert Enum.any?(plan.changes, fn
               {"provider-thread", "pt", patch} -> inspect(patch) =~ "carriedSession"
               _ -> false
             end)
    end
  end

  describe "a message too big for a new conversation" do
    defp big_plan(entities, message) do
      state = state([{"provider-thread", %{"id" => "pt"}} | entities])
      ids = %{driver: "codex", run: "run-1", thread: "t", provider_thread: "pt"}

      Handoff.plan(
        state,
        HalC2.StreamState.get(state, "provider-thread")["pt"],
        ids,
        1,
        "2026-10-01T10:09:00Z",
        message
      )
    end

    defp window(tokens),
      do:
        {"provider-turn",
         %{
           "id" => "pturn-0",
           "ordinal" => 0,
           "providerThreadId" => "pt",
           "tokenUsage" => %{"usedTokens" => 0, "maxTokens" => tokens}
         }}

    test "is refused only in a window the provider named" do
      long = %{text: String.duplicate("word ", 100_000), attachments: []}

      assert %{"code" => "context_window_exceeded"} = big_plan([window(128_000)], long).refusal
      assert big_plan([], long).refusal == nil
      assert big_plan([window(1_000_000)], long).refusal == nil
    end

    # A file goes to the provider as its path; the agent reads what it needs of it.
    test "is not made of what its attachments are estimated to take" do
      files = for n <- 1..100, do: %{type: "file", name: "f#{n}.txt", size_bytes: 400}

      assert big_plan([window(32_000)], %{text: "look", attachments: files}).refusal == nil

      assert Handoff.room(HalC2.StreamState.new(), nil, %{text: "", attachments: files}).message ==
               100 * 100
    end
  end
end
