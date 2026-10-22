defmodule HalC2.MuseTest do
  # One test sets META_API_KEY for the whole VM.
  use ExUnit.Case, async: false

  alias HalC2.Muse
  alias HalC2.Muse.ThreadRuntime
  alias HalC2.StreamState

  test "command ids are UUIDv7s that sort by time" do
    ids = for _ <- 1..3, do: Muse.command_id()

    for id <- ids,
        do:
          assert(id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)

    assert length(Enum.uniq(ids)) == 3
    assert binary_part(hd(ids), 0, 8) <= binary_part(List.last(ids), 0, 8)
  end

  test "the catalog keeps Meta's models once each and refuses another provider's" do
    assert {:ok,
            [%{"slug" => "m1", "name" => "Model One", "isDefault" => true}, %{"name" => "m2"}]} =
             Muse.models(%{
               "providerId" => "meta",
               "models" => [
                 %{
                   "modelId" => "m1",
                   "providerId" => "meta",
                   "displayLabel" => "Model One",
                   "isDefault" => true
                 },
                 %{"modelId" => "m1", "providerId" => "meta"},
                 %{"modelId" => "m2", "providerId" => "meta", "displayLabel" => " "},
                 %{"modelId" => "x", "providerId" => "other"}
               ]
             })

    # A malformed label or tier list does not cost the catalog.
    assert {:ok, [%{"slug" => "m3", "name" => "m3", "capabilities" => %{}}]} =
             Muse.models(%{
               "providerId" => "meta",
               "models" => [
                 %{
                   "modelId" => "m3",
                   "providerId" => "meta",
                   "displayLabel" => 3,
                   "variants" => ["low"],
                   "reasoningEffortVariants" => "low"
                 }
               ]
             })

    assert {:error, _} = Muse.models(%{"providerId" => "other", "models" => []})
    assert {:error, _} = Muse.models(%{})
  end

  test "a model's efforts and descriptions become its reasoning picker" do
    assert %{"optionDescriptors" => [%{"currentValue" => "medium", "options" => options}]} =
             Muse.capabilities(%{
               "variants" => ["low", "medium", "bogus"],
               "defaultReasoningEffort" => "medium",
               "reasoningEffortVariants" => [%{"tier" => "low", "description" => "Fast"}]
             })

    assert [
             %{"id" => "low", "label" => "Low", "description" => "Fast"},
             %{"id" => "medium", "isDefault" => true}
           ] = options

    assert %{"optionDescriptors" => []} = Muse.capabilities(%{"variants" => []})
  end

  test "an effort the model does not offer is left to Muse" do
    capabilities = Muse.capabilities(%{"variants" => ["low", "high"]})
    assert Muse.effort("high", capabilities) == "high"
    assert Muse.effort("max", capabilities) == nil
    assert Muse.effort(nil, capabilities) == nil
    assert Muse.effort("high", Muse.capabilities(%{"variants" => []})) == nil
  end

  test "full access allows all; everything else prompts" do
    assert Muse.approval_mode("full-access") == "allowAll"
    assert Muse.approval_mode("approval-required") == "promptUnmatched"
  end

  test "the host never inherits META_API_KEY and never updates itself" do
    previous = System.get_env("META_API_KEY")
    System.put_env("META_API_KEY", "secret")

    try do
      {:ok, argv, env} = Muse.launch("muse", runtime_mode: "full-access")

      assert [
               "env",
               "-u",
               "META_API_KEY",
               _bin,
               "serve",
               "--trust-workspace",
               "--disable-sandbox"
             ] = argv

      assert {"MUSE_NO_AUTO_UPDATE", "1"} in env
      refute Enum.any?(env, fn {key, _} -> String.upcase(key) == "META_API_KEY" end)
    after
      if previous,
        do: System.put_env("META_API_KEY", previous),
        else: System.delete_env("META_API_KEY")
    end
  end

  test "a v1 runtime state keeps working after a hot update" do
    assert {:ok, %{v: 4, last_ids: nil, started: true, subs: %{}} = state} =
             ThreadRuntime.code_change(1, %{v: 1, last_turn: "provider-turn:x", turn: nil}, nil)

    refute Map.has_key?(state, :last_turn)
  end

  test "a subagent that a v3 runtime showed as a tool call stays one after a hot update" do
    muse = %{
      "sa" => %{"itemId" => "sa", "kind" => "subagent"},
      "t" => %{"itemId" => "t", "kind" => "toolCall"}
    }

    assert {:ok, %{v: 4, subs: %{"sa" => :tool} = subs}} =
             ThreadRuntime.code_change(3, %{v: 3, muse: muse, turn: nil}, nil)

    assert map_size(subs) == 1
  end

  # The migrated `:tool` routing itself: a later revision of that subagent is shown
  # as the tool call the v3 runtime started, and no subagent is created for it.
  @tag :tmp_dir
  test "a subagent migrated to a tool call finishes as one, not also as a subagent",
       %{tmp_dir: dir} do
    start_streams(dir)
    started = subagent_item(%{"status" => "inProgress", "revision" => 1})

    {:ok, state} =
      ThreadRuntime.code_change(3, runtime_state(%{v: 3, muse: %{"sa" => started}}), nil)

    {:noreply, _state} = item_completed(state, %{"revision" => 2})
    stream = HalC2.Streams.Server.state(HalC2.Streams.ensure("thread-1"))
    assert StreamState.list(stream, "subagent") == []

    assert [%{"type" => "dynamic_tool", "status" => "completed"}] =
             StreamState.list(stream, "turn-item")
  end

  # The two together: a subagent migrated to `:tool` by the hot update, whose
  # completing revision is misshapen, finishes as that tool call (its role for
  # a title), not as a crashed turn.
  @tag :tmp_dir
  test "a migrated subagent completed with misshapen fields finishes as a tool call",
       %{tmp_dir: dir} do
    start_streams(dir)
    started = subagent_item(%{"status" => "inProgress", "revision" => 1})

    {:ok, state} =
      ThreadRuntime.code_change(3, runtime_state(%{v: 3, muse: %{"sa" => started}}), nil)

    {:noreply, _state} =
      item_completed(state, %{
        "revision" => 2,
        "objective" => 123,
        "result" => "just text"
      })

    stream = HalC2.Streams.Server.state(HalC2.Streams.ensure("thread-1"))
    assert StreamState.list(stream, "subagent") == []

    assert [%{"type" => "dynamic_tool", "status" => "completed", "title" => "reviewer"}] =
             StreamState.list(stream, "turn-item")
  end

  # No objective to name the task with: what Muse says it is doing is the
  # child's prompt instead of a blank message, its role still the title
  # (upstream's `objective ?? fallbackText ?? ""`).
  @tag :tmp_dir
  test "a subagent whose objective is blank is tasked with what Muse says it is doing",
       %{tmp_dir: dir} do
    start_streams(dir)

    {:noreply, _state} =
      item_completed(runtime_state(), %{
        "objective" => "   ",
        "fallbackText" => "Reading the diff"
      })

    stream = HalC2.Streams.Server.state(HalC2.Streams.ensure("thread-1"))

    assert [%{"status" => "completed", "title" => "reviewer", "prompt" => "Reading the diff"}] =
             StreamState.list(stream, "subagent")
  end

  # The started item names no objective and says nothing yet: the first
  # progress Muse reports fills the child's prompt it was started without.
  @tag :tmp_dir
  test "a subagent started with a blank objective is tasked by its first progress",
       %{tmp_dir: dir} do
    start_streams(dir)
    state = runtime_state()

    {:noreply, state} =
      item_event(state, "item/started", %{"status" => "inProgress", "objective" => "   "})

    {:noreply, state} =
      item_event(state, "item/updated", %{
        "status" => "inProgress",
        "revision" => 2,
        "objective" => "   ",
        "fallbackText" => "Reading the diff"
      })

    {:noreply, _state} =
      item_event(state, "item/completed", %{
        "revision" => 3,
        "objective" => "   ",
        "fallbackText" => "Reading the diff"
      })

    stream = HalC2.Streams.Server.state(HalC2.Streams.ensure("thread-1"))

    assert [%{"status" => "completed", "prompt" => "Reading the diff"} = subagent] =
             StreamState.list(stream, "subagent")

    child = HalC2.Streams.Server.state(HalC2.Streams.ensure(subagent["childThreadId"]))

    assert [%{"role" => "user", "text" => "Reading the diff"}] =
             child
             |> StreamState.list("message")
             |> Enum.filter(&(&1["role"] == "user"))
  end

  # A field in a shape Muse has not sent before degrades the one subagent (its role
  # for a title, no answer to read), not the turn carrying it.
  @tag :tmp_dir
  test "a subagent whose objective and result are not text and a map still ends",
       %{tmp_dir: dir} do
    start_streams(dir)

    {:noreply, _state} =
      item_completed(runtime_state(), %{"objective" => 123, "result" => "just text"})

    stream = HalC2.Streams.Server.state(HalC2.Streams.ensure("thread-1"))

    assert [%{"status" => "completed", "title" => "reviewer", "prompt" => ""} = subagent] =
             StreamState.list(stream, "subagent")

    assert subagent["result"] in [nil, ""]
  end

  defp start_streams(dir) do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
  end

  # A runtime mid-turn on thread-1, as `init/1` and a started turn leave it but for
  # the connection and the Muse host behind it.
  defp runtime_state(fields \\ %{}) do
    {:ok, state} = ThreadRuntime.init("thread-1")

    ids = %{
      driver: "muse",
      instance: "muse",
      thread: "thread-1",
      run: "run-1",
      attempt: nil,
      root_node: "node:root",
      provider_thread: "provider-thread:muse:thread-1",
      provider_turn: "provider-turn:muse:run-1",
      message: "m1"
    }

    Map.merge(
      %{state | conn: self(), session: "session-1", native: "turn-1", turn: %{ids: ids}},
      fields
    )
  end

  defp subagent_item(fields) do
    Map.merge(
      %{
        "itemId" => "sa",
        "kind" => "subagent",
        "status" => "completed",
        "turnId" => "turn-1",
        "revision" => 1,
        "objective" => "Review the diff",
        "role" => "reviewer",
        "result" => %{"text" => "Done."}
      },
      fields
    )
  end

  defp item_completed(state, fields), do: item_event(state, "item/completed", fields)

  defp item_event(state, method, fields) do
    params = %{"sessionId" => "session-1", "item" => subagent_item(fields)}

    ThreadRuntime.handle_info({:json_rpc, self(), {:notification, method, params}}, state)
  end

  describe "approvals" do
    @choices [
      %{
        "choiceId" => "always",
        "decision" => "approvedPolicyAmendment",
        "scope" => "localPersistent"
      },
      %{
        "choiceId" => "session-rule",
        "decision" => "approvedPolicyAmendment",
        "scope" => "session"
      },
      %{"choiceId" => "session", "decision" => "approvedForSession", "scope" => "session"},
      %{"choiceId" => "once", "decision" => "approved", "scope" => "once"},
      %{"choiceId" => "reject", "decision" => "abort", "scope" => "once"}
    ]

    test "each decision takes the narrowest choice that grants it" do
      choices = ThreadRuntime.choices(%{"availableChoices" => @choices})

      assert %{
               "accept" => %{"choiceId" => "once"},
               "acceptForSession" => %{"choiceId" => "session"},
               "acceptAlways" => %{"choiceId" => "always"},
               "cancel" => %{"choiceId" => "reject"},
               # Shell approvals have no "denied"; declining aborts.
               "decline" => %{"choiceId" => "reject"}
             } = choices
    end

    test "a real denial wins over abort" do
      choices =
        ThreadRuntime.choices(%{
          "availableChoices" => [
            %{"choiceId" => "deny", "decision" => "denied", "scope" => "once"},
            %{"choiceId" => "reject", "decision" => "abort", "scope" => "once"}
          ]
        })

      assert %{"decline" => %{"choiceId" => "deny"}, "cancel" => %{"choiceId" => "reject"}} =
               choices
    end

    test "subjects map to request kinds" do
      assert ThreadRuntime.request_kind(%{"kind" => "shell"}) == "command"

      assert ThreadRuntime.request_kind(%{"kind" => "fileAccess", "access" => "read"}) ==
               "file-read"

      assert ThreadRuntime.request_kind(%{"kind" => "fileAccess", "access" => "write"}) ==
               "file-change"

      assert ThreadRuntime.request_kind(%{"kind" => "network"}) == "permission"
    end
  end

  describe "answers" do
    @single %{
      "id" => "q",
      "options" => [%{"label" => "red"}, %{"label" => "green"}],
      "selection" => %{"mode" => "single"}
    }
    @multiple %{
      "id" => "m",
      "options" => [%{"label" => "a"}, %{"label" => "b"}, %{"label" => "c"}],
      "selection" => %{"mode" => "multiple", "maxSelections" => 2}
    }

    test "labels are selections and anything else is free text" do
      assert {:ok, [%{"questionId" => "q", "selectedLabel" => "red"}]} =
               ThreadRuntime.answers([@single], %{"q" => "red"})

      assert {:ok, [%{"questionId" => "q", "freeText" => "purple"}]} =
               ThreadRuntime.answers([@single], %{"q" => "purple"})

      assert {:ok, [%{"selectedLabel" => "green", "note" => "dark"}]} =
               ThreadRuntime.answers([@single], %{"q" => ["green", "dark"]})

      assert {:ok, [%{"selectedLabels" => ["a", "b"]}]} =
               ThreadRuntime.answers([@multiple], %{"m" => ["a", "b"]})
    end

    test "missing, oversized and miscounted answers are refused" do
      assert {:error, _} = ThreadRuntime.answers([@single], %{})
      assert {:error, _} = ThreadRuntime.answers([@single], %{"q" => ["red", "green"]})
      assert {:error, _} = ThreadRuntime.answers([@multiple], %{"m" => ["a", "b", "c"]})
      assert {:error, _} = ThreadRuntime.answers([@single], %{"q" => String.duplicate("x", 501)})
      # Muse counts UTF-16 code units: each of these emoji is two.
      assert {:error, _} = ThreadRuntime.answers([@single], %{"q" => String.duplicate("😀", 251)})
      assert {:ok, _} = ThreadRuntime.answers([@single], %{"q" => String.duplicate("😀", 250)})
    end
  end

  describe "items" do
    test "terminal states never read as success unless Muse says so" do
      assert ThreadRuntime.status(%{"status" => "inProgress"}) == "running"
      assert ThreadRuntime.status(%{"status" => "completed"}) == "completed"
      assert ThreadRuntime.status(%{"status" => "cancelled"}) == "cancelled"
      assert ThreadRuntime.status(%{"status" => "canceled"}) == "cancelled"
      assert ThreadRuntime.status(%{"status" => "failed"}) == "failed"
      assert ThreadRuntime.status(%{"status" => "declined"}) == "failed"

      assert ThreadRuntime.status(%{
               "status" => "completed",
               "kind" => "compaction",
               "outcome" => "skipped"
             }) ==
               "failed"
    end

    test "shell, edit, web and other tools become their turn items" do
      assert {:command, %{"input" => "npm test", "output" => "ok", "exitCode" => 0}} =
               ThreadRuntime.tool(
                 %{
                   "kind" => "toolCall",
                   "tool" => "shell",
                   "args" => ~s({"command":"npm test"}),
                   "visibleOutput" => "ok",
                   "exitCode" => 0
                 },
                 "completed"
               )

      assert {:file, %{"fileName" => "src/a.ts", "oldStr" => "a", "newStr" => "b"}} =
               ThreadRuntime.tool(
                 %{
                   "kind" => "toolCall",
                   "tool" => "edit_file",
                   "args" => ~s({"file_path":"src/a.ts","old_string":"a","new_string":"b"})
                 },
                 "completed"
               )

      assert {:web,
              %{"patterns" => ["elixir"], "results" => [%{"url" => "https://x", "title" => "X"}]}} =
               ThreadRuntime.tool(
                 %{
                   "kind" => "toolCall",
                   "tool" => "web_search",
                   "args" => ~s({"query":"elixir"}),
                   "visibleOutput" =>
                     ~s({"results":[{"url":"https://x","title":"X","snippet":" "}]})
                 },
                 "completed"
               )

      # Arguments still streaming are not JSON yet.
      assert {:tool, %{"toolName" => "grep", "input" => ~s({"pat)}} =
               ThreadRuntime.tool(
                 %{"kind" => "toolCall", "tool" => "grep", "args" => ~s({"pat)},
                 "running"
               )

      # A subagent a v3 runtime showed as a tool call still renders as one.
      assert {:tool, %{"title" => "Muse agent: boom", "output" => "boom"}} =
               ThreadRuntime.tool(%{"kind" => "subagent", "failureReason" => "boom"}, "failed")
    end

    # Every field `tool/2` reads may arrive in a shape Muse has not sent before;
    # each degrades to its fallback instead of raising on the turn.
    test "misshapen fields degrade the item, not the turn" do
      assert {:tool,
              %{
                "title" => "Muse agent: Muse reported failed.",
                "output" => "Muse reported failed.\nok"
              }} =
               ThreadRuntime.tool(
                 %{
                   "kind" => "subagent",
                   "objective" => 123,
                   "role" => %{},
                   "summary" => ["ok", 5],
                   "failureReason" => %{},
                   "result" => "just text",
                   "fallbackText" => 7
                 },
                 "failed"
               )

      assert {:tool, %{"title" => "Workflow", "output" => ""}} =
               ThreadRuntime.tool(
                 %{"kind" => "workflow", "entryId" => 42, "fallbackText" => %{}},
                 "completed"
               )

      assert {:tool, %{"output" => ""}} =
               ThreadRuntime.tool(%{"kind" => 7, "tool" => %{}}, "running")
    end
  end
end
