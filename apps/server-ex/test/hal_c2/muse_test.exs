defmodule HalC2.MuseTest do
  # One test sets META_API_KEY for the whole VM.
  use ExUnit.Case, async: false

  alias HalC2.Muse
  alias HalC2.Muse.ThreadRuntime

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

  test "a subagent a v3 runtime showed as a tool call stays one after a hot update" do
    muse = %{
      "sa" => %{"itemId" => "sa", "kind" => "subagent"},
      "t" => %{"itemId" => "t", "kind" => "toolCall"}
    }

    assert {:ok, %{v: 4, subs: %{"sa" => :tool} = subs}} =
             ThreadRuntime.code_change(3, %{v: 3, muse: muse, turn: nil}, nil)

    assert map_size(subs) == 1
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
    end
  end
end
