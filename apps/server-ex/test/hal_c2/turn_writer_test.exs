defmodule HalC2.Orchestration.TurnWriterTest do
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.TurnWriter
  alias HalC2.StreamState

  @moduletag :tmp_dir

  test "only whole paragraphs and closed code fences are ready" do
    assert TurnWriter.split_ready("First") == {"", "First"}
    assert TurnWriter.split_ready("First\n\nSec") == {"First\n\n", "Sec"}
    assert TurnWriter.split_ready("Intro\n\n```ts\nx()\n\n") == {"Intro\n\n", "```ts\nx()\n\n"}
    assert TurnWriter.split_ready("```ts\nx()\n```\nrest") == {"```ts\nx()\n```\n", "rest"}
    # A no-break space is content, not a blank line.
    assert TurnWriter.split_ready("a\n \nb") == {"", "a\n \nb"}
  end

  describe "timed flushes" do
    setup %{tmp_dir: dir} do
      start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
      start_supervised!(HalC2.Streams)
      start_supervised!(HalC2.Orchestration.CommandTail)

      {:ok, _} =
        HalC2.Streams.commit("t1", :thread, [
          {"turn-item", "i1", %{"s" => %{"id" => "i1", "text" => ""}}},
          {"turn-item", "i2", %{"s" => %{"id" => "i2", "output" => ""}}}
        ])

      :ok
    end

    defp state(mode) do
      %{
        thread_id: "t1",
        turn: %{streaming_mode: mode},
        items: %{
          "a" => %{id: "i1", message: nil, kind: :assistant},
          "c" => %{id: "i2", node: "n2", message: nil, kind: :command}
        },
        buffer: %{},
        flush_timer: nil
      }
    end

    defp text(id) do
      StreamState.get(HalC2.Streams.Server.state(HalC2.Streams.ensure("t1")), "turn-item")[id]
    end

    test "paragraph mode writes finished paragraphs; the rest waits for the item's end" do
      state =
        state("paragraph")
        |> TurnWriter.buffer("a", "text", "First\n\nSec")
        |> TurnWriter.buffer("c", "output", "$ ls\n")
        |> TurnWriter.flush(:timer)

      assert text("i1")["text"] == "First\n\n"
      # Command output is not held back, and does not go to the log.
      assert HalC2.Orchestration.CommandTail.get("t1", "i2") == "$ ls\n"
      assert text("i2")["output"] == ""
      assert text("i2")["outputSize"] == 5

      state = state |> TurnWriter.buffer("a", "text", "ond\n\nThi") |> TurnWriter.flush(:timer)
      # Within 400 ms of the last paragraph nothing more is written.
      assert text("i1")["text"] == "First\n\n"

      _ = TurnWriter.flush(state)
      assert text("i1")["text"] == "First\n\nSecond\n\nThi"
    end

    test "a running command keeps its last 64K and the thread none of it" do
      alias HalC2.Orchestration.CommandTail
      line = String.duplicate("x", 1023) <> "\n"
      state = state("paragraph")

      for n <- 1..100 do
        state |> TurnWriter.buffer("c", "output", line) |> TurnWriter.flush(:timer)
        assert text("i2")["outputSize"] == n * 1024
      end

      assert byte_size(CommandTail.get("t1", "i2")) == CommandTail.limit()
      assert text("i2")["output"] == ""

      {:ok, _} = HalC2.Streams.commit("t1", :thread, [{"node", "n2", %{"s" => %{"id" => "n2"}}}])
      _ = TurnWriter.finish_item(state, "c", "completed", & &1)
      # The thread keeps what was printed last, and the tail is gone.
      assert byte_size(text("i2")["output"]) == CommandTail.limit()
      assert CommandTail.get("t1", "i2") == nil
    end

    test "a command the turn stopped keeps what it printed and frees its tail" do
      alias HalC2.Orchestration.CommandTail
      {:ok, _} = HalC2.Streams.commit("t1", :thread, [{"node", "n2", %{"s" => %{"id" => "n2"}}}])

      {:ok, _} =
        HalC2.Streams.commit("t1", :thread, [
          {"turn-item", "i2", %{"s" => %{"status" => "running"}}}
        ])

      state = state("paragraph")
      state |> TurnWriter.buffer("c", "output", "partial\n") |> TurnWriter.flush(:timer)

      _ = TurnWriter.close_open_items(state, "interrupted")
      assert text("i2")["output"] == "partial\n"
      assert CommandTail.get("t1", "i2") == nil

      # A run that ends with a command still running leaves no tail either.
      CommandTail.append("t1", "i9", "left")
      CommandTail.drop_thread("t1")
      assert CommandTail.get("t1", "i9") == nil
    end

    test "a retry item left open is retitled by how the turn ended" do
      retry = %{"attempt" => 1, "maxAttempts" => 5, "retryDelayMs" => nil}

      {:ok, _} =
        HalC2.Streams.commit("t1", :thread, [
          {"turn-item", "i3",
           %{
             "s" => %{
               "id" => "i3",
               "status" => "running",
               "title" => "Provider retry",
               "retry" => retry
             }
           }},
          {"node", "n3", %{"s" => %{"id" => "n3", "status" => "running"}}}
        ])

      state = %{
        state("paragraph")
        | items: %{"r" => %{id: "i3", node: "n3", message: nil, kind: :error}}
      }

      for {status, title} <- [
            {"completed", "Provider recovered"},
            {"failed", "Provider error"},
            {"interrupted", "Provider retry stopped"}
          ] do
        {:ok, _} =
          HalC2.Streams.commit("t1", :thread, [
            {"turn-item", "i3", %{"s" => %{"status" => "running", "title" => "Provider retry"}}}
          ])

        _ = TurnWriter.close_open_items(state, status)
        assert text("i3")["title"] == title
        assert text("i3")["status"] == status
        assert text("i3")["retry"] == retry
      end
    end

    test "turn mode writes assistant text only at a boundary" do
      state =
        state("turn") |> TurnWriter.buffer("a", "text", "One\n\nTwo") |> TurnWriter.flush(:timer)

      assert text("i1")["text"] == ""
      _ = TurnWriter.flush(state)
      assert text("i1")["text"] == "One\n\nTwo"
    end

    test "a completed command whose output says it failed is marked failed" do
      {:ok, _} = HalC2.Streams.commit("t1", :thread, [{"node", "n2", %{"s" => %{"id" => "n2"}}}])

      for {output, failed} <- [
            {"zsh: command not found: vpx\n", true},
            {"cat: x: No such file or directory\n", true},
            {"Process exited with exit code 1\n", true},
            {"Cannot find path 'C:\\x' because it does not exist.", true},
            {"Process exited with exit code 0\n", nil},
            {"ok\n", nil}
          ] do
        _ =
          TurnWriter.finish_item(
            state("paragraph"),
            "c",
            "completed",
            &Map.put(&1, "output", output)
          )

        assert text("i2")["outputIndicatesFailure"] == failed, output

        HalC2.Streams.commit("t1", :thread, [
          {"turn-item", "i2", %{"u" => ["outputIndicatesFailure"]}}
        ])
      end
    end
  end

  describe "a turn's first output" do
    setup %{tmp_dir: dir} do
      start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
      start_supervised!(HalC2.Streams)

      {:ok, _} =
        HalC2.Streams.commit("t1", :thread, [
          {"provider-thread", "pt",
           %{"s" => %{"id" => "pt", "threadId" => "t1", "unconfirmedRunId" => "run-2"}}}
        ])

      :ok
    end

    # Pi never says it started a turn, so its output is what confirms one.
    defp writer(run, driver \\ "pi") do
      ids = %{
        thread: "t1",
        run: run,
        root_node: "node-#{run}",
        provider_thread: "pt",
        driver: driver
      }

      %{thread_id: "t1", turn: %{ids: ids}, items: %{}, buffer: %{}, flush_timer: nil}
    end

    defp mark do
      state = HalC2.Streams.Server.state(HalC2.Streams.ensure("t1"))
      StreamState.get(state, "provider-thread")["pt"]["unconfirmedRunId"]
    end

    # An older run's output arriving after a newer run handed history over says nothing
    # of whether that handoff reached the provider (#1233).
    test "confirms only its own run's handoff, however late it arrives" do
      _ = TurnWriter.ensure_item(writer("run-1"), "late", :assistant)
      assert mark() == "run-2"

      _ = TurnWriter.ensure_item(writer("run-2"), "answer", :assistant)
      assert mark() == nil
    end

    # A provider that says when it starts the turn confirms the run then
    # (`TurnWriter.confirmed/2`): an item before it can be left over from earlier work.
    test "confirms nothing for a provider that says when it starts the turn" do
      for driver <- ~w(codex claudeAgent muse) do
        _ = TurnWriter.ensure_item(writer("run-2", driver), "output-#{driver}", :assistant)
        assert mark() == "run-2"
      end
    end
  end

  # Codex, Muse or an ACP agent found the conversation to resume gone and opened a new
  # one, which gets the whole thread (#1233).
  describe "a fresh start" do
    setup %{tmp_dir: dir} do
      start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
      start_supervised!(HalC2.Streams)

      changes =
        for {kind, entity} <- [
              {"run", %{"id" => "run-1", "ordinal" => 1, "status" => "completed"}},
              {"message",
               %{
                 "id" => "user-1",
                 "runId" => "run-1",
                 "role" => "user",
                 "text" => "the first ask",
                 "createdAt" => "2026-10-01T10:01:00Z"
               }},
              {"run",
               %{"id" => "run-2", "ordinal" => 2, "status" => "running", "sentTokens" => 3}},
              {"provider-thread",
               %{
                 "id" => "pt",
                 "threadId" => "t1",
                 "lastRunOrdinal" => 2,
                 "nativeSinceRunOrdinal" => 1,
                 "contextUsage" => %{"usedTokens" => 90_000, "maxTokens" => 100_000}
               }}
            ],
            do: {kind, entity["id"], %{"s" => entity}}

      {:ok, _} = HalC2.Streams.commit("t1", :thread, changes)
      :ok
    end

    test "hands over the whole thread and marks the run until the provider confirms it" do
      ids = %{thread: "t1", run: "run-2", provider_thread: "pt", driver: "codex"}

      turn = %{
        ids: ids,
        text: "next",
        fresh: %{thread: "t1", ordinal: 2, merged: nil, moved: nil, restart: nil, text: "next"}
      }

      {state, turn} = HalC2.Orchestration.Handoff.fresh_start(%{fresh_start: true}, turn)
      refute Map.has_key?(state, :fresh_start)
      assert turn.text =~ "the first ask"
      assert String.ends_with?(turn.text, "next")

      stream = HalC2.Streams.Server.state(HalC2.Streams.ensure("t1"))
      provider_thread = StreamState.get(stream, "provider-thread")["pt"]

      assert %{"unconfirmedRunId" => "run-2", "unconfirmedSince" => 0} = provider_thread
      assert provider_thread["nativeSinceRunOrdinal"] == 2
      refute Map.has_key?(provider_thread, "contextUsage")
      assert StreamState.get(stream, "run")["run-2"]["sentTokens"] > 3
    end

    # A start that outlived its caller's timeout opens its conversation after the next
    # run was planned for the old one. That run waits behind the start and goes on in the
    # new conversation, which holds none of the thread, so its own mark says too little:
    # the start's mark stands for the whole thread, and the run after hands it over.
    test "a fresh start a later run overtook marks the whole thread unconfirmed" do
      mark = %{"lastRunOrdinal" => 3, "unconfirmedRunId" => "run-3", "unconfirmedSince" => 1}
      {:ok, _} = HalC2.Streams.commit("t1", :thread, [{"provider-thread", "pt", %{"s" => mark}}])
      ids = %{thread: "t1", run: "run-2", provider_thread: "pt", driver: "codex"}

      turn = %{
        ids: ids,
        text: "next",
        fresh: %{thread: "t1", ordinal: 2, merged: nil, moved: nil, restart: nil, text: "next"}
      }

      {_state, _turn} = HalC2.Orchestration.Handoff.fresh_start(%{fresh_start: true}, turn)

      stream = HalC2.Streams.Server.state(HalC2.Streams.ensure("t1"))

      assert %{"lastRunOrdinal" => 3, "unconfirmedRunId" => "run-2", "unconfirmedSince" => 0} =
               StreamState.get(stream, "provider-thread")["pt"]
    end
  end

  describe "a finished command" do
    setup %{tmp_dir: dir} do
      start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
      start_supervised!(HalC2.Streams)
      start_supervised!(HalC2.Orchestration.CommandTail)

      {:ok, _} =
        HalC2.Streams.commit("t1", :thread, [
          {"turn-item", "i1", %{"s" => %{"id" => "i1", "output" => ""}}},
          {"node", "n1", %{"s" => %{"id" => "n1"}}}
        ])

      :ok
    end

    defp finish(status, output) do
      %{
        thread_id: "t1",
        items: %{"c" => %{id: "i1", node: "n1", message: nil, kind: :command}},
        buffer: %{},
        flush_timer: nil
      }
      |> TurnWriter.finish_item("c", status, &Map.put(&1, "output", output))

      StreamState.get(HalC2.Streams.Server.state(HalC2.Streams.ensure("t1")), "turn-item")["i1"]
    end

    for output <- [
          "cat: x: No such file or directory",
          "zsh: command not found: foo",
          "/bin/bash: line 1: foo: command not found",
          "./run.sh: line 3: foo: command not found",
          "/usr/bin/env: 'python': No such file or directory",
          "<exited with exit code 1>",
          "Cannot find path 'C:\\x' because it does not exist."
        ] do
      test "is marked failed when the provider finished it but its output says #{inspect(output)}" do
        assert finish("completed", unquote(output))["outputIndicatesFailure"] == true
      end
    end

    test "is marked failed when a long output ends in a non-zero exit code" do
      output = String.duplicate("compiling lib/a.ex\n", 4_000) <> "Exit code 1\n"
      assert finish("completed", output)["outputIndicatesFailure"] == true
    end

    for output <- [
          "# handles ENOENT gracefully\n",
          "  if (!found) throw new Error(\"command not found\")\n",
          "lib/a.ex:12:  # no such file is fine here\n",
          "12:  # no such file is fine here\n",
          "Makefile:12: no such file is fine here\n",
          "lib/foo.ex:      {:error, :enoent} -> :ok\n",
          "src/a.ts: // no such file here\n"
        ] do
      test "stays a success when its output only mentions #{inspect(output)}" do
        refute Map.has_key?(finish("completed", unquote(output)), "outputIndicatesFailure")
      end
    end

    test "stays a success when its output only mentions a zero exit code" do
      refute Map.has_key?(
               finish("completed", "exited with exit code 0"),
               "outputIndicatesFailure"
             )
    end
  end
end
