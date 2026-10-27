defmodule HalC2.Orchestration.DelegationTest do
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.{Delegation, Recovery}
  alias HalC2.StreamState

  @moduletag :tmp_dir
  @at "2026-09-23T10:00:00.000Z"

  setup %{tmp_dir: dir} do
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)

    for name <- [
          HalC2.Codex.Registry,
          HalC2.Claude.Registry,
          HalC2.Acp.Registry,
          HalC2.Pi.Registry
        ],
        do: start_supervised!({Registry, keys: :unique, name: name}, id: name)

    on_exit(fn -> Application.delete_env(:hal_c2, :delegation_hook) end)
    :ok
  end

  # Called by the code under test at its stages (`hook/2` in Delegation).
  def hook(fun, stage, id), do: fun.(stage, id)

  defp hook_with(fun),
    do: Application.put_env(:hal_c2, :delegation_hook, {__MODULE__, :hook, [fun]})

  defp thread(id, extra \\ %{}) do
    {"thread", id,
     %{
       "s" =>
         Map.merge(
           %{"id" => id, "title" => id, "createdAt" => @at, "updatedAt" => @at},
           extra
         )
     }}
  end

  defp run(id, ordinal, status, extra \\ %{}) do
    {"run", id,
     %{
       "s" =>
         Map.merge(
           %{"id" => id, "ordinal" => ordinal, "status" => status, "requestedAt" => @at},
           extra
         )
     }}
  end

  # A parent working on `pr` with one task running in child `c`; the child has a
  # run in `child_status`.
  defp delegate(child_status, task_extra \\ %{}) do
    task =
      Map.merge(
        %{
          "id" => "task",
          "origin" => "app_owned",
          "childThreadId" => "c",
          "completionWake" => "always",
          "completionDelivery" => %{"state" => "pending", "observedByRunId" => nil},
          "status" => "running",
          "runId" => "pr",
          "startedAt" => @at
        },
        task_extra
      )

    {:ok, _} =
      HalC2.Streams.commit("p", :thread, [
        thread("p", %{"runtimeMode" => "full-access", "interactionMode" => "default"}),
        run("pr", 1, "running"),
        {"subagent", "task", %{"s" => task}},
        {"node", "task",
         %{"s" => %{"id" => "task", "kind" => "subagent", "status" => "running"}}},
        {"turn-item", "turn-item:subagent:task",
         %{
           "s" => %{
             "id" => "turn-item:subagent:task",
             "nodeId" => "task",
             "ordinal" => 1,
             "type" => "subagent",
             "status" => "running"
           }
         }}
      ])

    {:ok, _} =
      HalC2.Streams.commit("c", :thread, [
        thread("c", %{
          "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => "p"}
        }),
        run("cr", 1, child_status, completed(child_status))
        | preparation(child_status)
      ])

    :ok
  end

  # A run waiting on its worktree has the "Preparing workspace" item the MC gives it.
  defp preparation("preparing"),
    do: [
      {"turn-item", "turn-item:workspace-preparation:cr",
       %{
         "s" => %{
           "id" => "turn-item:workspace-preparation:cr",
           "runId" => "cr",
           "ordinal" => 1,
           "type" => "command_execution",
           "status" => "running"
         }
       }}
    ]

  defp preparation(_status), do: []

  defp completed(status) when status in ["running", "queued"], do: %{}
  defp completed(_), do: %{"completedAt" => @at}

  defp end_child(status) do
    _ =
      HalC2.Streams.transact("c", :thread, fn state ->
        {[
           HalC2.Orchestration.upsert(state, "run", "cr", fn run ->
             Map.merge(run, %{"status" => status, "completedAt" => @at})
           end)
         ], :ok}
      end)

    :ok
  end

  defp task do
    "p"
    |> HalC2.Streams.ensure()
    |> HalC2.Streams.Server.state()
    |> StreamState.get("subagent")
    |> Map.get("task")
  end

  defp item do
    "p"
    |> HalC2.Streams.ensure()
    |> HalC2.Streams.Server.state()
    |> StreamState.get("turn-item")
    |> Map.get("turn-item:subagent:task")
  end

  defp woken? do
    "p"
    |> HalC2.Streams.ensure()
    |> HalC2.Streams.Server.state()
    |> StreamState.get("message")
    |> Map.has_key?("message:delegate-result:task")
  end

  describe "a task whose child was interrupted at boot" do
    test "is interrupted, with its timeline item, when the project does not continue it" do
      :ok = HalC2.Shell.subscribe(self())
      delegate("running")
      # Recovery reads the sidebar rows: both threads' must be there, the parent's for
      # its task to be reconciled and the child's for its run to be settled.
      for id <- ["p", "c"],
          do: assert_receive({:hal_c2_shell, {:rows, _, [{^id, {"thread", _}}]}}, 1_000)

      assert "c" in Recovery.run()
      assert task()["status"] == "running"
      assert item()["status"] == "running"

      Recovery.continue()

      assert %{"status" => "interrupted", "completionDelivery" => %{"state" => "disposed"}} =
               task()

      assert item()["status"] == "interrupted"
    end
  end

  describe "a task whose child thread was never created" do
    test "fails at boot but is left alone once a launch may be under way" do
      {:ok, _} =
        HalC2.Streams.commit("p", :thread, [
          thread("p"),
          {"subagent", "task",
           %{
             "s" => %{
               "id" => "task",
               "origin" => "app_owned",
               "childThreadId" => "c",
               "status" => "running",
               "completionDelivery" => %{"state" => "pending"}
             }
           }},
          {"node", "task",
           %{"s" => %{"id" => "task", "kind" => "subagent", "status" => "running"}}}
        ])

      assert Delegation.reconcile("p", false) == 0
      assert task()["status"] == "running"
      assert Delegation.reconcile("p") == 1
      assert %{"status" => "failed", "completionDelivery" => %{"state" => "disposed"}} = task()
    end
  end

  describe "a task whose child passed a held run that was then cancelled" do
    # The held run is numbered above the run that passed it, but it never
    # started: the child ended with the passed run, answer and all.
    test "settles from the run that passed it, not the cancelled held run" do
      :ok = delegate("failed")

      {:ok, _} =
        HalC2.Streams.commit("c", :thread, [
          run("cr2", 2, "completed", %{"completedAt" => @at}),
          {"message", "m2",
           %{"s" => %{"id" => "m2", "runId" => "cr2", "role" => "assistant", "text" => "done"}}},
          run("cr3", 3, "cancelled", %{"completedAt" => @at, "queueHeld" => true})
        ])

      assert Delegation.reconcile("p") == 1
      assert %{"status" => "completed", "result" => "done"} = task()
    end
  end

  describe "a task whose child fails or is cancelled while its worktree is prepared" do
    # Nothing but `fail_prepared/4` ends such a child's run, so it must tell the caller.
    for {status, failure, text} <- [
          {"failed", %{"message" => "no space left"},
           "Workspace preparation failed: no space left"},
          {"cancelled", nil, "Workspace preparation was cancelled."}
        ] do
      test "the caller's task settles #{status} with why" do
        delegate("preparing")
        :ok = HalC2.Streams.watch("p", self())

        assert :ok =
                 HalC2.Orchestration.fail_prepared(
                   "c",
                   "cr",
                   unquote(status),
                   unquote(Macro.escape(failure))
                 )

        await_settled()
        assert %{"status" => unquote(status), "result" => unquote(text)} = task()
        assert item()["status"] == unquote(status)
      end
    end

    defp await_settled do
      if task()["status"] == "running" do
        assert_receive {:hal_c2_stream, "p", _}, 5_000
        await_settled()
      end
    end
  end

  describe "a request the provider instance refuses" do
    test "ends the task failed instead of leaving it running" do
      delegate("running")

      assert {:error, _} =
               Delegation.request(%{
                 "parentThreadId" => "p",
                 "parentRunId" => "pr",
                 "task" => "x",
                 "modelSelection" => %{"instanceId" => "ghost", "model" => "m"}
               })

      failed =
        "p"
        |> HalC2.Streams.ensure()
        |> HalC2.Streams.Server.state()
        |> StreamState.list("subagent")
        |> Enum.find(&(&1["id"] != "task"))

      assert %{"status" => "failed", "completionDelivery" => %{"state" => "disposed"}} = failed
    end
  end

  describe "a wait that times out as the child ends" do
    test "answers with the end and does not leave the caller to be woken" do
      delegate("running", %{"completionWake" => "settled_only"})

      hook_with(fn
        :expiring, _ ->
          end_child("completed")
          Delegation.finished("c", "cr", "completed")

        _, _ ->
          :ok
      end)

      assert {:ok, %{"status" => "completed"} = answer} = Delegation.wait("p", "task", 1)
      refute answer["waitTimedOut"]
      assert task()["completionDelivery"]["state"] == "acknowledged"
      refute woken?()
    end
  end

  describe "a cancel as the interrupted child reports" do
    test "leaves the task cancelled and wakes nobody" do
      delegate("running")

      hook_with(fn
        :cancelling, _ ->
          end_child("interrupted")
          Delegation.finished("c", "cr", "interrupted")

        _, _ ->
          :ok
      end)

      assert {:ok, %{"status" => "cancelled"}} = Delegation.cancel("p", "task")
      assert %{"status" => "cancelled", "completionDelivery" => %{"state" => "disposed"}} = task()
      refute woken?()
    end

    test "is refused for a task that already ended" do
      delegate("completed")
      Delegation.finished("c", "cr", "completed")
      assert task()["status"] == "completed"

      assert {:error, "task_not_cancellable", _} = Delegation.cancel("p", "task")
      assert task()["status"] == "completed"
    end
  end

  # An open background command of the child's run, as a provider leaves it when its
  # turn ends with the command still running.
  defp background(status) do
    {:ok, _} =
      HalC2.Streams.commit("c", :thread, [
        {"turn-item", "turn-item:bg",
         %{
           "s" => %{
             "id" => "turn-item:bg",
             "runId" => "cr",
             "ordinal" => 1,
             "type" => "command_execution",
             "status" => status,
             "input" => "npm run dev"
           }
         }}
      ])

    :ok
  end

  defp answered(message_id, run_id, text) do
    {:ok, _} =
      HalC2.Streams.commit("c", :thread, [
        {"message", message_id,
         %{"s" => %{"id" => message_id, "runId" => run_id, "role" => "assistant", "text" => text}}}
      ])

    :ok
  end

  describe "a task whose child ends a turn with background work running (hal-c2/hal-c2#508)" do
    test "waits for the work and the turn after it, and settles once with the last answer" do
      delegate("completed")
      answered("m1", "cr", "Started the monitor.")
      background("running")

      Delegation.finished("c", "cr", "completed")
      assert task()["status"] == "running"
      refute woken?()
      assert {:ok, %{"workState" => "waiting_for_children"}} = Delegation.task_status("p", "task")

      # The work ends ahead of the provider's wake run: nothing settles in between.
      background("completed")
      {:ok, _} = HalC2.Streams.commit("c", :thread, [run("cr2", 2, "running")])
      Delegation.finished("c", "cr", "completed")
      assert task()["status"] == "running"
      assert {:ok, %{"workState" => "working"}} = Delegation.task_status("p", "task")

      answered("m2", "cr2", "The tests pass.")

      {:ok, _} =
        HalC2.Streams.commit("c", :thread, [run("cr2", 2, "completed", %{"completedAt" => @at})])

      Delegation.finished("c", "cr2", "completed")
      Delegation.finished("c", "cr2", "completed")

      assert %{"status" => "completed", "result" => "The tests pass."} = task()
      assert woken?()
      assert {:ok, %{"workState" => "result_available"}} = Delegation.task_status("p", "task")
    end

    test "keeps the last answer when a later turn says nothing or is rolled back" do
      delegate("completed")
      answered("m1", "cr", "The tests pass.")

      {:ok, _} =
        HalC2.Streams.commit("c", :thread, [
          run("cr2", 2, "completed", %{"completedAt" => @at}),
          run("cr3", 3, "rolled_back", %{"completedAt" => @at})
        ])

      answered("m3", "cr3", "Never mind.")
      Delegation.finished("c", "cr2", "completed")

      assert %{"status" => "completed", "result" => "The tests pass."} = task()
    end
  end

  # Found by the delegation property: the periodic check met a child between its
  # creation and its first run, and settled the task cancelled.
  describe "a task whose child has not started its first run" do
    test "is not settled by a check for a quiet child" do
      delegate("running", %{"childThreadId" => "c0"})

      {:ok, _} =
        HalC2.Streams.commit("c0", :thread, [
          thread("c0", %{
            "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => "p"}
          })
        ])

      assert :ok = Delegation.settle_if_quiet("c0")
      assert task()["status"] == "running"
      refute woken?()
    end
  end

  describe "a report that raises" do
    test "is retried and settles the task" do
      delegate("completed")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      hook_with(fn
        :reporting, _ ->
          if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0, do: raise("busy")

        _, _ ->
          :ok
      end)

      assert Delegation.report("c", "cr", "completed", 2, 0) == :ok
      assert Agent.get(counter, & &1) == 2
      assert task()["status"] == "completed"
    end
  end

  # `p`, itself working on `ptask` for `g`, with nothing left but the task in `c`: once
  # that ends, so does `ptask`. Neither result wakes its caller.
  defp delegate_nested do
    disposed = %{"state" => "disposed", "observedByRunId" => nil}
    delegate("completed", %{"completionDelivery" => disposed})

    {:ok, _} =
      HalC2.Streams.commit("g", :thread, [
        thread("g"),
        run("gr", 1, "running"),
        {"subagent", "ptask",
         %{
           "s" => %{
             "id" => "ptask",
             "origin" => "app_owned",
             "childThreadId" => "p",
             "completionDelivery" => disposed,
             "status" => "running",
             "runId" => "gr",
             "startedAt" => @at
           }
         }},
        {"node", "ptask",
         %{"s" => %{"id" => "ptask", "kind" => "subagent", "status" => "running"}}}
      ])

    {:ok, _} =
      HalC2.Streams.commit("p", :thread, [
        thread("p", %{
          "runtimeMode" => "full-access",
          "interactionMode" => "default",
          "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => "g"}
        }),
        run("pr", 1, "completed", %{"completedAt" => @at})
      ])

    :ok
  end

  defp task(parent_id, task_id) do
    parent_id
    |> HalC2.Streams.ensure()
    |> HalC2.Streams.Server.state()
    |> StreamState.get("subagent")
    |> Map.get(task_id)
  end

  describe "a report whose check of the caller's own task fails" do
    test "checks the caller again when retried, though its own task has ended" do
      delegate_nested()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      hook_with(fn
        :settling, "p" ->
          if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0, do: exit(:busy)

        _, _ ->
          :ok
      end)

      assert Delegation.report("c", "cr", "completed", 2, 0) == :ok
      assert task()["status"] == "completed"
      assert task("g", "ptask")["status"] == "completed"
    end
  end

  describe "the periodic check meeting a thread that fails" do
    test "settles the other quiet tasks and still answers" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      on_exit(fn -> Application.delete_env(:hal_c2, :idle_session_check_ms) end)

      delegate("completed")

      {:ok, _} =
        HalC2.Streams.commit("p", :thread, [
          {"subagent", "task2",
           %{
             "s" => %{
               "id" => "task2",
               "origin" => "app_owned",
               "childThreadId" => "c2",
               "completionDelivery" => %{"state" => "disposed", "observedByRunId" => nil},
               "status" => "running",
               "runId" => "pr",
               "startedAt" => @at
             }
           }},
          {"node", "task2",
           %{"s" => %{"id" => "task2", "kind" => "subagent", "status" => "running"}}}
        ])

      {:ok, _} =
        HalC2.Streams.commit("c2", :thread, [
          thread("c2", %{
            "lineage" => %{"relationshipToParent" => "subagent", "parentThreadId" => "p"}
          }),
          run("c2r", 1, "completed", %{"completedAt" => @at})
        ])

      for id <- ~w(p c c2), do: id |> HalC2.Streams.ensure() |> HalC2.Streams.Server.flush_shell()

      hook_with(fn
        :settling, "c" -> exit(:busy)
        _, _ -> :ok
      end)

      pid = start_supervised!(HalC2.Orchestration.IdleSessions)

      assert HalC2.Orchestration.IdleSessions.check() == []
      assert Process.whereis(HalC2.Orchestration.IdleSessions) == pid
      assert task()["status"] == "running"
      assert task("p", "task2")["status"] == "completed"
    end
  end

  describe "a task whose result is delivered" do
    test "is never recorded as delivered before its result message, so a crash cannot part them" do
      delegate("completed")

      Delegation.finished("c", "cr", "completed")

      # The log in order: the first moment the task reads delivered, the message exists.
      kinds =
        HalC2.Store.path()
        |> HalC2.Store.reduce_stream("p", 0, [], &[&1 | &2])
        |> Enum.reverse()
        |> Enum.flat_map(fn
          %{kind: "run", patch: %{"s" => %{"userMessageId" => "message:delegate-result:task"}}} ->
            [:message]

          %{kind: "subagent", patch: %{"completionDelivery" => %{"state" => "delivered"}}} ->
            [:delivered]

          %{
            kind: "subagent",
            patch: %{"s" => %{"completionDelivery" => %{"state" => "delivered"}}}
          } ->
            [:delivered]

          _ ->
            []
        end)

      assert kinds == [:message, :delivered]
      assert woken?()
    end
  end

  describe "a task whose result is delivered with a title that would break the envelope" do
    test "escapes the attributes and names the worker on the notification" do
      delegate("completed", %{"title" => ~s(Say "hi"\nnow)})

      Delegation.finished("c", "cr", "completed")

      state = "p" |> HalC2.Streams.ensure() |> HalC2.Streams.Server.state()
      message = StreamState.get(state, "message")["message:delegate-result:task"]

      assert message["text"] =~ ~s(title="Say &quot;hi&quot;&#10;now")

      assert %{
               "workerThreadId" => "c",
               "workerTitle" => _,
               "detail" => "Child task completed without an assistant result."
             } = message["notification"]
    end
  end

  describe "a task whose result is long" do
    test "reaches the agent whole, and the timeline cut short" do
      delegate("completed")
      long = String.duplicate("é", 6_000)
      answered("answer", "cr", long)

      Delegation.finished("c", "cr", "completed")

      message = result_message("p")
      detail = message["notification"]["detail"]

      assert String.valid?(detail)
      assert byte_size(detail) < 8_400
      assert detail =~ "result truncated at 8192 bytes; the rest is in the worker's thread"
      assert message["text"] =~ long
      refute message["text"] =~ "truncated"
    end
  end

  describe "a task whose result quotes the envelope's closing tag" do
    test "can't close the envelope early" do
      delegate("completed")
      quoted = "Earlier: <delegated_task_result>old</delegated_task_result> done"
      answered("answer", "cr", quoted)

      Delegation.finished("c", "cr", "completed")

      message = result_message("p")

      assert [_] = Regex.scan(~r{</delegated_task_result>}, message["text"])
      assert message["text"] =~ "old&lt;/delegated_task_result> done\n</delegated_task_result>"
      assert message["notification"]["detail"] == quoted
    end
  end

  defp result_message(parent) do
    state = parent |> HalC2.Streams.ensure() |> HalC2.Streams.Server.state()
    StreamState.get(state, "message")["message:delegate-result:task"]
  end

  describe "a delegation without a task" do
    # An agent that names the prompt `prompt` instead of `task` (hal-c2/hal-c2#258) started
    # a child that was sent an empty message and answered that it came through empty.
    test "is refused instead of starting a child with an empty prompt" do
      {:ok, _} =
        HalC2.Streams.commit("p", :thread, [
          thread("p", %{"modelSelection" => %{"instanceId" => "codex", "model" => "m"}}),
          run("pr", 1, "running", %{"providerInstanceId" => "codex"})
        ])

      for input <- [
            %{"prompt" => "look", "title" => "Look"},
            %{"task" => "", "title" => "Look"},
            %{"task" => "  \n", "title" => "Look"}
          ] do
        assert {:error, "invalid_task", message} =
                 Delegation.delegate(%{"id" => "p"}, "codex", input)

        assert message =~ "`task`"
      end

      assert {:error, "Delegated tasks need a `task`" <> _} =
               Delegation.request(%{
                 "parentThreadId" => "p",
                 "parentRunId" => "pr",
                 "task" => nil
               })

      assert StreamState.list(HalC2.Streams.state("p"), "subagent") == []
    end
  end

  describe "a parent with no runtime or interaction mode" do
    test "starts its task instead of looping" do
      {:ok, _} =
        HalC2.Streams.commit("p", :thread, [
          thread("p", %{"modelSelection" => %{"instanceId" => "codex", "model" => "m"}}),
          run("pr", 1, "running", %{"providerInstanceId" => "codex"})
        ])

      assert {:ok, %{"taskId" => _}} =
               Delegation.delegate(%{"id" => "p"}, "codex", %{"task" => "look"})
    end
  end
end
