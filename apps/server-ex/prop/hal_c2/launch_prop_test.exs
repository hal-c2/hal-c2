defmodule HalC2.LaunchPropTest do
  @moduledoc """
  A state machine over launching threads into a new worktree
  (`HalC2.Orchestration.launch_thread/1`), as a client does that retries a launch
  after a dropped connection: the same launch again later, or a retry that lands
  while the first is still in the MC, at any of the stream calls the launch makes.

  The model is which threads have been launched. After each launch the thread
  exists; the launch that made it (the first, or a retry that overtook it) reports it
  new, and every other one reports it resumed; and the thread has one user message
  and one run, which waits for its worktree (it has the workspace-preparation item),
  whichever launch got there first.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.StreamState

  @moduletag timeout: :infinity

  @threads ~w(l1 l2)
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)

  property "a launch into a new worktree, however retried, has one waiting run",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("launch")
        # No commits, so the worktree is never added: each run waits, then fails,
        # and no turn ever starts in it.
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
        Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Settings,
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
          {Registry, keys: :unique, name: HalC2.Codex.Registry},
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
          HalC2.WorktreeSetup
        ])

        {:ok, _} =
          HalC2.Projects.mutate(%{
            "type" => "project.create",
            "projectId" => "demo",
            "title" => "demo",
            "workspaceRoot" => work
          })

        HalC2.Streams.flush_shell("demo")
        :sys.get_state(HalC2.Shell)

        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :codex_command)
        Application.delete_env(:hal_c2, :streams_hook)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # launched: the threads launched so far.
  def initial_state, do: %{launched: MapSet.new()}

  # `retry_at`: the stream call of the launch at which a retry of it lands, or nil.
  def command(_state),
    do: {:call, __MODULE__, :launch, [oneof(@threads), oneof([nil | Enum.to_list(1..6)])]}

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :launch, [tid, _]}),
    do: %{state | launched: MapSet.put(state.launched, tid)}

  def postcondition(state, {:call, _, :launch, [tid, _]}, {launch, retry, projection}) do
    # The one launch that made the thread reports it new: the first launch of the
    # thread, or its retry when that got there first.
    replies = Enum.reject([launch, retry], &is_nil/1)
    new = if MapSet.member?(state.launched, tid), do: 0, else: 1

    checks = [
      replies: Enum.all?(replies, &match?({:ok, %{"threadId" => ^tid}}, &1)),
      new: Enum.count(replies, &match?({:ok, %{"resumed" => false}}, &1)) == new,
      projection: projection == %{messages: 1, runs: 1, waited: true}
    ]

    failed = for {name, false} <- checks, do: name

    unless failed == [],
      do:
        IO.puts(
          "launch #{tid}: #{inspect(failed)} launch=#{inspect(launch)} retry=#{inspect(retry)} " <>
            inspect(projection)
        )

    failed == []
  end

  # --- the real thing -------------------------------------------------------------

  def launch(tid, retry_at) do
    input = %{
      "commandId" => "launch-#{tid}",
      "threadId" => tid,
      "projectId" => "demo",
      "title" => "Launched",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "runtimeMode" => "full-access",
      "interactionMode" => "default",
      "workspaceStrategy" => %{"type" => "worktree", "baseRef" => "main"},
      "initialMessage" => %{"messageId" => "msg-#{tid}", "text" => "Hello", "attachments" => []}
    }

    if retry_at do
      Process.put(:retry, {input, retry_at})
      Application.put_env(:hal_c2, :streams_hook, {__MODULE__, :retry, []})
    end

    launch = HalC2.Orchestration.launch_thread(input)
    Application.delete_env(:hal_c2, :streams_hook)
    Process.delete(:retry)
    {launch, Process.delete(:retried), projection(tid)}
  end

  # Called by the stream hook before each stream call: the `n`th call on the launched
  # thread's stream retries the launch, in the launch's own process.
  def retry(:ensured, stream_id) do
    case Process.get(:retry) do
      {%{"threadId" => ^stream_id} = input, 1} ->
        Process.delete(:retry)
        Process.put(:retried, HalC2.Orchestration.launch_thread(input))

      {%{"threadId" => ^stream_id} = input, n} ->
        Process.put(:retry, {input, n - 1})

      _ ->
        :ok
    end
  end

  def retry(_stage, _stream_id), do: :ok

  defp projection(tid) do
    state = HalC2.Streams.state(tid)
    runs = StreamState.list(state, "run")
    items = StreamState.get(state, "turn-item")

    %{
      messages: state |> StreamState.list("message") |> Enum.count(&(&1["role"] == "user")),
      runs: length(runs),
      waited: Enum.all?(runs, &Map.has_key?(items, "turn-item:workspace-preparation:#{&1["id"]}"))
    }
  end
end
