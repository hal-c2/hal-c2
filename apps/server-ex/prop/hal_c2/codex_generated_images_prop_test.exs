defmodule HalC2.CodexGeneratedImagesPropTest do
  @moduledoc """
  A state machine over the images one Codex turn generates
  (`HalC2.Codex.ThreadRuntime`, `HalC2.Codex.GeneratedImages`): Codex starts
  images, saves them (reporting one saved twice, as it can), fails them, sends
  replies as final answers, partial answers or without a phase, and the turn
  ends as Codex reports it (completed, interrupted, failed) or with its
  app-server dying. Images may still be saved after a reported end.

  The promise: the thread shows every reply as Codex sent it until the turn
  ends; then the turn's saved images, each once and in the order saved, are
  appended to its last final reply (one without a phase or a `final_answer`),
  or make a reply of their own when it had none. An image saved after a
  completed turn ended joins the same reply; after a stopped or failed turn, or
  an app-server that died, an image still generating never shows.

  The turn runs on the fake app-server in `test/support/fake_codex.py`, which
  leaves a turn saying "wait" open; the test then plays Codex's side itself.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @tid "codex-images-thread"
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @wait_ms 10_000
  @images 3
  @answers 3

  property "a Codex turn's saved images join its last final reply once",
    numtests: HalC2.Prop.numtests(25),
    max_size: 14 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Prop.restore_env()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("codex-generated-images")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    HalC2.Prop.put_env(:codex_command, ["python3", "-u", @fake_codex])

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      HalC2.Mcp,
      {Registry, keys: :unique, name: HalC2.Codex.Registry},
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

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    selection = %{"instanceId" => "codex", "model" => "gpt-5.4"}

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Codex",
        "modelSelection" => selection,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m1",
        "text" => "wait for it",
        "attachments" => [],
        "modelSelection" => selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await_until(fn ->
      case runtime() do
        {_, %{turn: %{native_turn_id: turn}, native_thread_id: thread}}
        when is_binary(turn) and is_binary(thread) ->
          Process.put(:native_thread, thread)
          Process.put(:native_turn, turn)
          observed().run == "running"

        _ ->
          false
      end
    end)
  end

  # --- model ---------------------------------------------------------------------

  # phase: :running; :reported (Codex reported the turn's end as `ended`, and
  # may still save an image); or :gone (the app-server died). images: image n's
  # state (:running, :saved or :failed); saved: images in the order first saved;
  # late: the images still generating when the turn ended. answers: the phase of
  # each reply sent, in order.
  def initial_state,
    do: %{phase: :running, ended: nil, images: %{}, saved: [], late: [], answers: []}

  def command(%{phase: :running} = state) do
    generating = for {n, :running} <- state.images, do: n
    saveable = for {n, s} <- state.images, s != :failed, do: n

    frequency(
      Enum.concat([
        if(map_size(state.images) < @images,
          do: [{3, {:call, __MODULE__, :start_image, [map_size(state.images) + 1]}}],
          else: []
        ),
        if(saveable != [], do: [{3, {:call, __MODULE__, :save, [oneof(saveable)]}}], else: []),
        if(generating != [],
          do: [{1, {:call, __MODULE__, :fail, [oneof(generating)]}}],
          else: []
        ),
        if(length(state.answers) < @answers,
          do: [
            {2,
             {:call, __MODULE__, :answer,
              [length(state.answers) + 1, oneof(["final_answer", "partial_answer", nil])]}}
          ],
          else: []
        ),
        [
          {2,
           {:call, __MODULE__, :end_turn, [oneof([:completed, :interrupted, :failed, :stream])]}}
        ]
      ])
    )
  end

  def command(%{phase: :reported} = state) do
    late = for n <- state.late, state.images[n] == :running, do: n

    if late == [],
      do: {:call, __MODULE__, :observe, []},
      else:
        frequency([
          {3, {:call, __MODULE__, :save, [oneof(late)]}},
          {1, {:call, __MODULE__, :fail, [oneof(late)]}},
          {1, {:call, __MODULE__, :observe, []}}
        ])
  end

  def command(%{phase: :gone}), do: {:call, __MODULE__, :observe, []}

  def precondition(state, {:call, _, :start_image, [n]}),
    do: state.phase == :running and n == map_size(state.images) + 1 and n <= @images

  def precondition(state, {:call, _, :save, [n]}),
    do:
      (state.phase == :running and state.images[n] in [:running, :saved]) or
        (state.phase == :reported and n in state.late and state.images[n] == :running)

  def precondition(state, {:call, _, :fail, [n]}),
    do:
      state.images[n] == :running and
        (state.phase == :running or (state.phase == :reported and n in state.late))

  def precondition(state, {:call, _, :answer, [k, _phase]}),
    do: state.phase == :running and k == length(state.answers) + 1

  def precondition(state, {:call, _, :end_turn, [_kind]}), do: state.phase == :running
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :start_image, [n]}),
    do: %{state | images: Map.put(state.images, n, :running)}

  # An image saved after a stopped or failed turn ended is not shown.
  def next_state(%{phase: :reported, ended: ended} = state, _result, {:call, _, :save, [n]})
      when ended != :completed,
      do: %{state | images: Map.put(state.images, n, :saved)}

  def next_state(state, _result, {:call, _, :save, [n]}),
    do: %{
      state
      | images: Map.put(state.images, n, :saved),
        saved: if(n in state.saved, do: state.saved, else: state.saved ++ [n])
    }

  def next_state(state, _result, {:call, _, :fail, [n]}),
    do: %{state | images: Map.put(state.images, n, :failed)}

  def next_state(state, _result, {:call, _, :answer, [_k, phase]}),
    do: %{state | answers: state.answers ++ [phase]}

  # Codex can still report the images it was generating unless its app-server died.
  def next_state(state, _result, {:call, _, :end_turn, [kind]}) do
    generating = for {n, :running} <- state.images, do: n

    if kind == :stream,
      do: %{state | phase: :gone, ended: kind},
      else: %{state | phase: :reported, ended: kind, late: generating}
  end

  def next_state(state, _result, _call), do: state

  def postcondition(state, call, seen) do
    expected = next_state(state, nil, call)
    seen.replies == replies(expected)
  end

  # The replies the thread shows: Codex's own, and once the turn ended, the saved
  # images appended to the last final one or, without one, a reply of their own.
  defp replies(%{ended: nil} = state), do: Enum.map(1..length(state.answers)//1, &reply/1)

  defp replies(state) do
    texts = Enum.map(1..length(state.answers)//1, &reply/1)
    embeds = Enum.map(state.saved, &"![](<#{path(&1)}>)")

    final =
      state.answers
      |> Enum.with_index(1)
      |> Enum.filter(fn {phase, _} -> phase in [nil, "final_answer"] end)
      |> List.last()

    cond do
      embeds == [] -> texts
      final == nil -> texts ++ [Enum.join(embeds, "\n\n")]
      true -> List.update_at(texts, elem(final, 1) - 1, &Enum.join([&1 | embeds], "\n\n"))
    end
  end

  defp reply(k), do: "Reply #{k}."
  defp path(n), do: "/images/fox-#{n}.png"

  # --- commands ------------------------------------------------------------------

  def start_image(n), do: image(n, "item/started", %{"status" => "inProgress"})

  def save(n),
    do: image(n, "item/completed", %{"status" => "completed", "savedPath" => path(n)})

  def fail(n),
    do: image(n, "item/completed", %{"status" => "failed", "failure" => "content policy"})

  def answer(k, phase) do
    message = %{"type" => "agentMessage", "id" => "msg-#{k}", "phase" => phase}
    notify("item/started", item(Map.put(message, "text", "")))
    notify("item/completed", item(Map.put(message, "text", reply(k))))
    settle_runtime()
    observed()
  end

  def end_turn(:stream) do
    {_, runtime} = runtime()
    os_pid = HalC2.Subprocess.os_pid(:sys.get_state(runtime.conn).sub)
    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    await_until(fn -> observed().run != "running" end)
    settle_runtime()
    observed()
  end

  def end_turn(kind) do
    turn = %{"id" => Process.get(:native_turn), "status" => Atom.to_string(kind)}

    turn =
      if kind == :failed,
        do: Map.put(turn, "error", %{"message" => "the turn failed"}),
        else: turn

    notify("turn/completed", %{"turn" => turn})
    await_until(fn -> observed().run != "running" end)
    settle_runtime()
    observed()
  end

  def observe, do: observed()

  # --- the real side ---------------------------------------------------------------

  defp image(n, method, fields) do
    image = Map.merge(%{"type" => "imageGeneration", "id" => "image-#{n}"}, fields)
    notify(method, item(image))
    settle_runtime()
    observed()
  end

  defp item(item),
    do: %{
      "threadId" => Process.get(:native_thread),
      "turnId" => Process.get(:native_turn),
      "item" => item
    }

  # As the app-server would send it; the `:settle` call after rides behind it,
  # so what is read back is what its handling committed.
  defp notify(method, params) do
    {pid, runtime} = runtime()
    send(pid, {:json_rpc, runtime.conn, {:notification, method, params}})
  end

  defp settle_runtime do
    case runtime() do
      {pid, _} -> GenServer.call(pid, :settle)
      nil -> :ok
    end
  end

  defp runtime do
    case Registry.lookup(HalC2.Codex.Registry, @tid) do
      [{pid, _}] -> {pid, :sys.get_state(pid)}
      [] -> nil
    end
  end

  defp observed do
    state = current(@tid)
    run = state |> StreamState.list("run") |> List.first()

    %{
      run: run && run["status"],
      replies:
        for(m <- StreamState.list(state, "message"), m["role"] == "assistant", do: m["text"])
    }
  end

  # Wakes on the stream's own commits; what it waited for never happening is
  # the failure the postcondition then shows, so it returns rather than raises.
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

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
end
