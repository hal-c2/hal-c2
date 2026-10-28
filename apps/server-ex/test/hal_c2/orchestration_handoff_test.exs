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
             "User: run the tests\n\nCommand: mix test\nExit code: 2\n1 failure\n\nAssistant: one test fails"
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
             "User: run the tests\n\nCommand: mix test\nInterrupted before it finished\nCompiling"
  end

  test "a failed command with no exit code is handed over as failed" do
    command = %{"input" => "mix test", "status" => "failed", "output" => "1 failure\n"}

    assert Handoff.transcript(state(turn(1, "run the tests", "one fails", command)), 2) ==
             "User: run the tests\n\nCommand: mix test\nFailed\n1 failure\n\nAssistant: one fails"
  end

  test "long command output keeps its end" do
    output = String.duplicate("a", 3_000) <> "\n3 tests, 0 failures"

    command = %{
      "input" => "mix test",
      "status" => "completed",
      "exitCode" => 0,
      "output" => output
    }

    assert [_, "Command: mix test\nExit code: 0\n... " <> kept, _] =
             state(turn(1, "run the tests", "all green", command))
             |> Handoff.transcript(2)
             |> String.split("\n\n")

    assert String.length(kept) == 2_000
    assert String.ends_with?(kept, "\n3 tests, 0 failures")
  end

  test "a transcript too long keeps the newest turn and the first request, and drops entries whole" do
    long = String.duplicate("x", 40_000)

    state =
      state(
        turn(1, "the original request", "first " <> long) ++
          turn(2, "second request", "second " <> long) ++
          turn(3, "newest request", "done", %{
            "input" => "ls",
            "status" => "completed",
            "exitCode" => 0
          })
      )

    assert Handoff.transcript(state, 4) ==
             Enum.join(
               [
                 "[earlier messages omitted]",
                 "User: the original request",
                 "User: second request",
                 "Assistant: second " <> long,
                 "User: newest request",
                 "Command: ls\nExit code: 0",
                 "Assistant: done"
               ],
               "\n\n"
             )
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
    assert Handoff.fork_boundary(fork_source(nil), @point, "codex") == {:trim, 1}
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

    assert Handoff.fork_boundary(source, @point, "codex") == {:trim, 0}
    assert Handoff.fork_boundary(source, @point, "claudeAgent") == {:trim, 0}
  end

  test "no recorded provider turns at all is unknown, not an error" do
    assert Handoff.fork_boundary(state([]), @point, "codex") == :unknown
  end

  test "the note that messages were left out counts against the budget" do
    # The two requests and the newest answer are 60,000 characters with what joins them,
    # so they no longer fit once the note is counted.
    fixed = String.length("User: first" <> "User: second" <> "Assistant: ") + 3 * 2
    answer = String.duplicate("y", 60_000 - fixed)

    state = state(turn(1, "first", String.duplicate("x", 100)) ++ turn(2, "second", answer))

    assert "[earlier messages omitted]\n\n" <> _ = transcript = Handoff.transcript(state, 3)
    assert String.length(transcript) <= 60_000
  end
end
