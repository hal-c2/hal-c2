defmodule HalC2.GrokPromptCompletionPropTest do
  @moduledoc """
  A state machine over Grok turns (`HalC2.Acp.ThreadRuntime`) whose prompts
  Grok may never answer: a turn ends by whichever settles it first, Grok's
  `x.ai/session/prompt_complete` notice (naming the running prompt, an
  earlier one, some other one, or none) or the prompt's own answer, with an
  interrupt in between if the user stops the turn first. The store may also
  refuse one of the running turn's writes (a full disk, hal-c2#1285): the MC
  then stops the turn itself, its run fails, and a Grok that never answers
  that stop has its process stopped once its time is out.

  The promise: every turn ends exactly once, with the status its settler
  says, and no notice or late answer ends a turn other than its own. A
  notice for a prompt a later turn replaced (`grok_done` in the runtime)
  settles nothing, and an unnamed notice settles the one prompt waiting.

  Turns run on the scripted fake in `test/support/fake_acp_scripted.py`:
  each turn's prompt waits for a release file, so the test chooses when (or
  whether) Grok answers it, and plays the completion notices itself, as
  the connection would deliver them.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @tid "grok-prompt-thread"
  @script Path.expand("../../test/support/fake_acp_scripted.py", __DIR__)
  @model %{"instanceId" => "grok", "model" => "grok-code-fast-1"}
  @active ~w(preparing starting running waiting)
  @wait_ms 10_000
  # More turns than a case's commands can send (`max_size` below).
  @turns 16

  property "a Grok turn ends once, by its own notice, answer or stop deadline, never another's",
    numtests: HalC2.Prop.numtests(15),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()
        Application.put_env(:hal_c2, :antigravity_cancel_timeout_ms, 3_600_000)
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :antigravity_cancel_timeout_ms)
        HalC2.Test.Machines.refuse_changes(nil)
        HalC2.Acp.forget("grok")

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model -------------------------------------------------------------------

  # runs: every turn's status, in the order sent; current: the running
  # turn's number; interrupted: its user stop landed; unanswered: the turns
  # whose prompt the fake has not answered yet, oldest first (a turn the MC
  # already ended by notice stays here until its late answer is released);
  # unrecorded: the store refused one of the running turn's writes.
  def initial_state,
    do: %{runs: [], current: nil, interrupted: false, unrecorded: false, unanswered: [], next: 1}

  def command(state) do
    notices =
      {:call, __MODULE__, :notice, [oneof([:current, :stale, :unnamed, :other])]}

    frequency(
      [{3, notices}] ++
        if(state.current == nil,
          do: [{4, {:call, __MODULE__, :send, [state.next]}}],
          else: []
        ) ++
        if(state.unanswered != [],
          do: [{3, {:call, __MODULE__, :answer, [hd(state.unanswered)]}}],
          else: []
        ) ++
        if(state.current != nil and not state.interrupted,
          do: [
            {1, {:call, __MODULE__, :interrupt, []}},
            {2, {:call, __MODULE__, :fail_write, []}}
          ],
          else: []
        ) ++
        if(state.unrecorded, do: [{3, {:call, __MODULE__, :outlast, []}}], else: [])
    )
  end

  def precondition(state, {:call, _, :send, [n]}),
    do: state.current == nil and n == state.next

  def precondition(state, {:call, _, :answer, [n]}),
    do: state.unanswered != [] and hd(state.unanswered) == n

  def precondition(state, {:call, _, call, []}) when call in [:interrupt, :fail_write],
    do: state.current != nil and not state.interrupted

  def precondition(state, {:call, _, :outlast, []}), do: state.unrecorded

  def precondition(_state, {:call, _, :notice, [_]}), do: true
  def precondition(_state, _call), do: false

  def next_state(state, _result, {:call, _, :send, [n]}) do
    %{
      state
      | runs: state.runs ++ ["running"],
        current: n,
        interrupted: false,
        unanswered: state.unanswered ++ [n],
        next: n + 1
    }
  end

  # Only a notice naming the running prompt, or naming none while it alone
  # waits in the runtime, settles the turn. The fake may hold older prompts
  # the MC already settled; those are abandoned requests, not waiting ones.
  def next_state(state, _result, {:call, _, :notice, [target]}) do
    if state.current != nil and target in [:current, :unnamed],
      do: end_turn(state),
      else: state
  end

  def next_state(state, _result, {:call, _, :answer, [n]}) do
    state = %{state | unanswered: tl(state.unanswered)}
    if state.current == n, do: end_turn(state), else: state
  end

  def next_state(state, _result, {:call, _, :interrupt, []}),
    do: %{state | interrupted: true}

  # The MC stops the turn the store failed, as the user's stop does.
  def next_state(state, _result, {:call, _, :fail_write, []}),
    do: %{state | interrupted: true, unrecorded: true}

  # Grok's process is stopped, and the prompts it held with it.
  def next_state(state, _result, {:call, _, :outlast, []}),
    do: %{end_turn(state) | unanswered: []}

  # However a turn the store failed ends, its run fails.
  defp end_turn(state) do
    status =
      cond do
        state.unrecorded -> "failed"
        state.interrupted -> "interrupted"
        true -> "completed"
      end

    runs = List.replace_at(state.runs, state.current - 1, status)
    %{state | runs: runs, current: nil, interrupted: false, unrecorded: false}
  end

  def postcondition(state, {:call, _, _, _} = call, seen) do
    seen == next_state(state, nil, call).runs
  end

  # --- commands ------------------------------------------------------------------

  def send(n) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{n}",
        "text" => "turn-#{n}-please",
        "attachments" => [],
        "modelSelection" => @model,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await_until(fn ->
      match?({_pid, %{grok_prompt: id}} when is_binary(id), runtime()) and
        length(observed()) >= n and List.last(observed()) == "running"
    end)

    case runtime() do
      {_pid, %{grok_prompt: id}} -> Process.put({:prompt_id, n}, id)
      _ -> :ok
    end

    observed()
  end

  def notice(target) do
    case runtime() do
      {pid, state} ->
        prompt =
          case target do
            :current -> state.grok_prompt
            :stale -> stale_id(state.grok_prompt)
            :unnamed -> nil
            :other -> "hal-c2-xai-prompt-999"
          end

        params =
          %{"sessionId" => state.session_id, "stopReason" => "end_turn"}
          |> then(&if(prompt, do: Map.put(&1, "promptId", prompt), else: &1))

        send(
          pid,
          {:json_rpc, state.conn, {:notification, "x.ai/session/prompt_complete", params}}
        )

        :sys.get_state(pid)

      nil ->
        :ok
    end

    settled()
  end

  # The newest recorded prompt id that is not the running one.
  defp stale_id(current) do
    Process.get()
    |> Enum.flat_map(fn
      {{:prompt_id, n}, id} when id != current -> [{n, id}]
      _ -> []
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> {0, "hal-c2-xai-prompt-999"} end)
    |> elem(1)
  end

  def answer(n) do
    File.write!(Path.join(Process.get(:fake_dir), "answer-#{n}"), "")

    # When this answer is the running turn's, it ends the turn; a late one
    # is dropped whenever it lands, so there is nothing to wait for.
    running? =
      case runtime() do
        {_pid, %{grok_prompt: id}} -> id != nil and Process.get({:prompt_id, n}) == id
        _ -> false
      end

    if running? do
      await_until(fn -> match?({_pid, %{turn: nil}}, runtime()) or runtime() == nil end)
    end

    settled()
  end

  def interrupt do
    {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid})
    await_until(fn -> match?({_pid, %{interrupted: true}}, runtime()) end)
    settled()
  end

  # The store refuses the running turn's task list, so the MC stops the turn, which
  # Grok does not answer while its prompt waits.
  def fail_write do
    {pid, %{conn: conn, session_id: session}} = runtime()
    entry = %{"content" => "Save", "status" => "in_progress", "priority" => "medium"}

    params = %{
      "sessionId" => session,
      "update" => %{"sessionUpdate" => "plan", "entries" => [entry]}
    }

    HalC2.Test.Machines.refuse_changes(@tid)
    send(pid, {:json_rpc, conn, {:notification, "session/update", params}})
    %{unrecorded: %{}, interrupted: true} = :sys.get_state(pid)
    HalC2.Test.Machines.refuse_changes(nil)
    settled()
  end

  # The time Grok has to answer the MC's stop runs out: its process is stopped and
  # the turn ends. The property's bound is an hour, so only this ends it.
  def outlast do
    {pid, %{turn: %{ids: %{run: run}}}} = runtime()
    send(pid, {:antigravity_cancel_timeout, run})
    await_until(fn -> match?({_pid, %{turn: nil}}, runtime()) or runtime() == nil end)
    settled()
  end

  # --- the real side ---------------------------------------------------------------

  # The stream's runs once it agrees with the runtime on whether a turn is
  # running: an ended turn's status can lag behind its checkpoint.
  defp settled do
    sync_runtime()

    await_until(fn ->
      active? = Enum.any?(observed(), &(&1 == "running"))

      case runtime() do
        {_pid, %{turn: nil}} -> not active?
        {_pid, %{}} -> active?
        nil -> not active?
      end
    end)

    observed()
  end

  defp sync_runtime do
    case runtime() do
      {pid, _} -> :sys.get_state(pid)
      nil -> :ok
    end
  end

  defp runtime do
    case Registry.lookup(HalC2.Acp.Registry, @tid) do
      [{pid, _}] -> {pid, :sys.get_state(pid)}
      [] -> nil
    end
  end

  # Every run's status in order; an active run reads as "running", whatever
  # its start-up phase.
  defp observed do
    HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    |> StreamState.list("run")
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.map(fn run ->
      if run["status"] in @active, do: "running", else: run["status"]
    end)
  end

  defp await_until(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait_ms

    if fun.() do
      :ok
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_until(fun, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
      end
    end
  end

  defp start_case do
    home = HalC2.Prop.scratch_home("grok-prompt-completion")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    {:ok, _} = Application.ensure_all_started(:erlexec)

    fake = Path.join(home, "fake")
    File.mkdir_p!(fake)
    Process.put(:fake_dir, fake)

    turns =
      for n <- 1..@turns do
        %{
          "match" => "turn-#{n}-please",
          "steps" => [%{"waitFile" => "answer-#{n}"}, %{"text" => "done #{n}"}]
        }
      end

    config = %{
      "configOptions" => [
        %{
          "id" => "model",
          "name" => "Model",
          "type" => "select",
          "currentValue" => "grok-code-fast-1",
          "options" => [
            %{"value" => "grok-code-fast-1", "name" => "Grok Code Fast"},
            %{"value" => "grok-4", "name" => "Grok 4"}
          ]
        }
      ],
      "turns" => turns
    }

    File.write!(Path.join(fake, "config.json"), JSON.encode!(config))
    bin = Path.join([fake, "bin", "grok"])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{fake}' FAKE_BIN="$0"
    exec python3 -u '#{@script}' "$@"
    """)

    File.chmod!(bin, 0o755)

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      HalC2.Mcp,
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
      HalC2.Settings,
      HalC2.Acp.UrlAuth
    ])

    HalC2.Acp.forget("grok")
    {settings, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(
        put_in(settings, [Access.key("providers", %{}), Access.key("grok", %{})], %{
          "enabled" => true,
          "binaryPath" => bin
        }),
        version
      )

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Grok prompts",
        "modelSelection" => @model,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
  end
end
