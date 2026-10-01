defmodule HalC2.Orchestration.HandoffTest do
  use ExUnit.Case, async: true

  alias HalC2.Orchestration.Handoff

  @header "Imported conversation history from the previous HAL-C2 orchestrator. Use it as context; do not repeat it unless the user asks."

  defp user(text), do: %{"type" => "user_message", "text" => text}
  defp assistant(text), do: %{"type" => "assistant_message", "text" => text}

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
