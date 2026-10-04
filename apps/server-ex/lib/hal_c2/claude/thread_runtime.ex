defmodule HalC2.Claude.ThreadRuntime do
  @moduledoc """
  Runs one thread's Claude turns through the `claude` CLI (`HalC2.Claude.Session`) and
  writes them into the thread's log.

  One CLI process serves every turn of the thread: each message is another user
  message on its stream-json input. If the process has gone, or the turn is on
  another model or other model options, the next turn starts a new one with
  `--resume` on the recorded session id. Text and thinking stream from partial
  messages and are written as appends; tool calls become command, file-change,
  web-search, or generic tool items, finished by their tool results.

  Work Claude runs in the background outlives the turn that started it: a subagent
  (the `Agent` tool) is a provider-native subagent (`NativeSubagent`), and a
  background Bash call's command item stays running after its tool result, which
  only acknowledges the launch. Both end on the task's `task_notification`, and with
  the turn when it is interrupted or fails, or with the process. While they run, the
  thread lists them as background work (`HalC2.Projection.BackgroundWork`), which
  keeps the idle reaper from stopping the process.

  When background work ends between the MC's turns, Claude answers its notification
  with a turn of its own (a "wake"). Its messages wait for a run of their own, which
  the runtime asks the thread for (`wake/2`); that run replays them and follows the
  rest to Claude's `result`.
  """

  use GenServer, restart: :temporary

  require Logger

  import HalC2.Orchestration.TurnWriter

  alias HalC2.Claude.Provider
  alias HalC2.Claude.Session
  alias HalC2.Orchestration
  alias HalC2.Orchestration.{Entities, NativeSubagent}
  alias HalC2.StreamState

  @state_version 9

  @signed_out "Claude could not authenticate. For subscription login, run `claude auth login` " <>
                "on this environment's machine, then start a new thread. For API-key " <>
                "authentication, check this instance's configured credentials."

  # runtimeMode -> the CLI's permission mode; prompts it raises become approval
  # requests the user answers in the client. In auto, Claude Code's classifier
  # decides what it would otherwise ask.
  @permission_modes %{
    "full-access" => "bypassPermissions",
    "auto-accept-edits" => "acceptEdits",
    "auto" => "auto",
    "approval-required" => "default"
  }

  @file_tools ~w(Edit Write MultiEdit NotebookEdit)
  @web_tools ~w(WebSearch WebFetch)
  # Claude's subagent tool; "Task" before Claude Code 2.1.
  @agent_tools ~w(Agent Task)
  @task_status %{"completed" => "completed", "failed" => "failed", "stopped" => "cancelled"}

  def driver, do: "claudeAgent"

  @spec start_turn(String.t(), map) :: :ok
  def start_turn(thread_id, turn),
    do: thread_id |> ensure() |> GenServer.call({:start_turn, turn}, 60_000)

  @spec interrupt(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def interrupt(thread_id, _run_id) do
    case Registry.lookup(HalC2.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, :interrupt, 15_000)
      [] -> {:error, "no active Claude turn in this thread"}
    end
  end

  @doc "Adds a message (`%{text, attachments}`) to the running turn of `run_id`; Claude takes it at once."
  @spec steer(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def steer(thread_id, run_id, message) do
    case Registry.lookup(HalC2.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:steer, run_id, message})
      [] -> {:error, "no running turn"}
    end
  end

  @doc """
  Answers a prompt: a permission's `%{"decision" => ProviderApprovalDecision}`,
  AskUserQuestion's `%{"answers" => answers}`, or `%{"dismissed" => true}`.
  """
  @spec respond(String.t(), String.t(), map) :: :ok | {:error, String.t()}
  def respond(thread_id, request_id, response) do
    case Registry.lookup(HalC2.Claude.Registry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, {:respond, request_id, response})
      [] -> {:error, "no pending request"}
    end
  end

  @doc """
  Rewinds the conversation: drops the live session, so the next turn resumes the
  recorded session at the new head (`nativeConversationHeadRef`), or starts a new
  one when the rollback goes back to the thread's start.
  """
  @spec rollback(String.t(), map) :: {:ok, map} | {:error, String.t()}
  def rollback(thread_id, %{head: head}) do
    reply =
      case Registry.lookup(HalC2.Claude.Registry, thread_id) do
        [{pid, _}] -> GenServer.call(pid, :rollback, 30_000)
        [] -> :ok
      end

    with :ok <- reply do
      {:ok,
       if(head,
         do: %{"nativeConversationHeadRef" => Entities.provider_ref(head, "claudeAgent")},
         else: %{"nativeThreadRef" => nil, "nativeConversationHeadRef" => nil}
       )}
    end
  end

  def start_link(thread_id),
    do:
      GenServer.start_link(__MODULE__, thread_id,
        name: {:via, Registry, {HalC2.Claude.Registry, thread_id}}
      )

  defp ensure(thread_id) do
    # Under its provider plugin, so a crash there stays with this provider.
    case DynamicSupervisor.start_child(
           HalC2.Plugins.sessions("claudeAgent"),
           {__MODULE__, thread_id}
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(thread_id) do
    {:ok,
     %{
       v: @state_version,
       thread_id: thread_id,
       session: nil,
       session_id: nil,
       turn: nil,
       items: %{},
       buffer: %{},
       flush_timer: nil,
       # Streamed content blocks of the message in flight: index -> native item key.
       blocks: %{},
       message_id: nil,
       interrupted: false,
       # Open prompts: request id -> `{:permission, control id, tool, suggested rules}`
       # or `{:question, control id, input}`.
       requests: %{},
       # The session's permission mode, switched before a turn that needs another.
       permission_mode: nil,
       # How the session's CLI was started (`Provider.launch/2`); a turn on another model
       # or other model options restarts it.
       launch: nil,
       # A steer ends the turn's current part with an "aborted" result; that one
       # result is not the end of the turn.
       steered: false,
       # Subagents and background commands still running, by tool use id:
       # `%{sub: NativeSubagent handle | nil, item: command item | nil, background: bool}`.
       work: %{},
       # Claude's task ids -> the tool use id of their work, or nil for a task that is
       # not work (ambient, a foreground command) or has ended.
       tasks: %{},
       # The latest turn's ids, which work Claude starts between turns joins.
       last_ids: nil,
       # A turn Claude runs by itself (`wake/2`) that no run follows yet:
       # `%{open: bool, buffer: [message] | nil}`, `open` until its `result`, `buffer` its
       # messages newest first, nil once the thread refused it a run.
       wake: nil
     }}
  end

  # The run of a wake: nothing is sent to Claude. What it said so far is replayed into
  # the run, which then follows it to its `result`.
  @impl true
  def handle_call({:start_turn, %{wake: true} = turn}, _from, state) do
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:claudeAgent:#{turn.ids.run}")
    launch = state.launch || Provider.launch(turn.model, Map.get(turn, :options, %{}))
    turn = turn |> Map.put(:ids, ids) |> Map.put(:launch, launch)
    wake = state.wake || %{open: false, buffer: nil}
    buffer = Enum.reverse(wake.buffer || [])

    state = %{
      state
      | turn: turn,
        items: %{},
        blocks: %{},
        interrupted: false,
        last_ids: ids,
        wake: nil
    }

    started(state)
    state = Enum.reduce(buffer, state, &receive_message/2)

    # Replayed to its end, or Claude is still at it; a wake a user's turn took over
    # (`take_wake/2`) leaves its run nothing to show.
    state =
      cond do
        state.turn == nil ->
          state

        state.session == nil and (wake.open or buffer != []) ->
          end_turn(state, "failed", "Claude exited")

        wake.open ->
          state

        true ->
          end_turn(state, "completed", nil)
      end

    {:reply, :ok, state}
  end

  def handle_call({:start_turn, turn}, _from, state) do
    ids = Map.put(turn.ids, :provider_turn, "provider-turn:claudeAgent:#{turn.ids.run}")
    # The CLI also takes its MCP server at launch: a credential renewed since (the old
    # one lapsed, or the project's agent access changed) needs a new process to reach it.
    launch =
      turn.model
      |> Provider.launch(Map.get(turn, :options, %{}))
      |> auto_compact(Entities.instance(ids))
      |> Map.put(:mcp, HalC2.Mcp.for_agent(state.thread_id, Entities.instance(ids)))

    turn = turn |> Map.put(:ids, ids) |> Map.put(:launch, launch)
    state = %{state | turn: turn, items: %{}, blocks: %{}, interrupted: false, last_ids: ids}
    session = state.session

    # A model the installed CLI is too old for is refused here, naming the version.
    opened =
      case Provider.too_old(turn.model) do
        nil -> open_session(state, turn)
        message -> {:error, {:too_old, message}}
      end

    case opened do
      {:error, {:too_old, message}} ->
        finish(state, "failed", message)
        {:reply, :ok, %{state | turn: nil}}

      {:ok, state, turn} ->
        state = %{state | turn: turn}
        started(state)
        {state, opts} = take_wake(state, session)
        Session.send_message(state.session, claude_content(turn), opts)

        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning("claude turn failed to start: #{inspect(reason)}")
        finish(state, "failed", start_failure("Claude", reason))
        {:reply, :ok, %{state | turn: nil}}
    end
  end

  def handle_call(:interrupt, _from, %{turn: turn, session: session} = state)
      when turn != nil and session != nil do
    Session.control(session, "interrupt")
    {:reply, :ok, %{state | interrupted: true}}
  end

  # Between turns, stopping the thread stops the work it left running in the background,
  # with the process that runs it; the next turn resumes the conversation.
  def handle_call(:interrupt, _from, %{turn: nil, session: session} = state)
      when session != nil and state.work != %{} do
    state = end_work(state, "interrupted")
    GenServer.stop(session)
    {:reply, :ok, %{state | session: nil, permission_mode: nil}}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, "no running turn"}, state}

  # The message reads like the turn's own: its effort prefix, files and images.
  def handle_call({:steer, run_id, message}, _from, %{turn: %{ids: %{run: run_id}}} = state)
      when state.session != nil do
    content = claude_content(Map.put(message, :launch, state.turn.launch))
    Session.send_message(state.session, content, priority: "now")
    {:reply, :ok, %{state | steered: true}}
  end

  def handle_call(:rollback, _from, %{turn: nil} = state) do
    state = end_work(state, "interrupted")
    if state.session, do: GenServer.stop(state.session)
    {:reply, :ok, %{state | session: nil, session_id: nil, permission_mode: nil, wake: nil}}
  end

  def handle_call(:rollback, _from, state),
    do: {:reply, {:error, "Interrupt the current turn before rewinding."}, state}

  def handle_call({:steer, _run_id, _message}, _from, state),
    do: {:reply, {:error, "no running turn"}, state}

  def handle_call({:respond, request_id, response}, _from, state) do
    case Map.pop(state.requests, request_id) do
      {nil, _} ->
        {:reply, {:error, "no pending request #{request_id}"}, state}

      # The answers go back as the tool's input, keyed by question text.
      {{:question, control_id, input}, requests} ->
        {answer, status} =
          if response["dismissed"],
            do: {{:deny, "The user dismissed the question."}, "cancelled"},
            else:
              {{:allow, Map.put(input, "answers", claude_answers(response["answers"]))},
               "resolved"}

        Session.answer_permission(state.session, control_id, answer)
        state = resolve_request(%{state | requests: requests}, request_id, response, status)
        {:reply, :ok, state}

      # A dismissed dialog is cancelled, and Claude does what it does without an answer.
      {{:dialog, control_id, question}, requests} ->
        {answer, status} =
          if response["dismissed"],
            do: {:cancelled, "cancelled"},
            else:
              {{:completed, resume_choice(claude_answers(response["answers"])[question])},
               "resolved"}

        Session.answer_dialog(state.session, control_id, answer)
        state = resolve_request(%{state | requests: requests}, request_id, response, status)
        {:reply, :ok, state}

      {{:permission, control_id, tool, suggestions}, requests} ->
        decision = response["decision"] || "decline"

        answer =
          case decision do
            "accept" ->
              :allow

            session when session in ["acceptForSession", "acceptAlways"] ->
              {:allow_session, session_rules(tool, suggestions)}

            _ ->
              {:deny, "The user declined."}
          end

        Session.answer_permission(state.session, control_id, answer)
        state = resolve_request(%{state | requests: requests}, request_id, decision)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:claude, _session, {:message, message}}, state),
    do: {:noreply, receive_message(message, state)}

  # The thread would not run the wake (`wake/2`): its messages go on as between turns.
  def handle_info(:wake_refused, %{turn: nil, wake: %{buffer: [_ | _] = buffer} = wake} = state) do
    state = %{state | wake: if(wake.open, do: %{wake | buffer: nil})}
    {:noreply, buffer |> Enum.reverse() |> Enum.reduce(state, &message/2)}
  end

  def handle_info(:wake_refused, state), do: {:noreply, state}

  def handle_info(
        {:claude, session, {:permission, id, _tool, _input, _context}},
        %{turn: nil} = state
      ) do
    Session.answer_permission(session, id, {:deny, "No turn is running."})
    {:noreply, state}
  end

  # Plan mode's plan: captured for the user, and Claude stops to wait for them.
  def handle_info({:claude, session, {:permission, id, "ExitPlanMode", input, _}}, state) do
    state =
      state
      |> flush()
      |> ensure_item("plan:#{id}", :plan)
      |> finish_plan("plan:#{id}", input["plan"] || "")

    Session.answer_permission(
      session,
      id,
      {:deny,
       "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."}
    )

    {:noreply, state}
  end

  def handle_info({:claude, _session, {:permission, id, "AskUserQuestion", input, _}}, state) do
    {state, request_id} = open_question(flush(state), id, claude_questions(input))
    request = {:question, id, input}
    {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
  end

  def handle_info({:claude, _session, {:permission, id, tool, input, context}}, state) do
    {kind, prompt} =
      cond do
        tool == "Bash" -> {"command", input["command"]}
        tool in @file_tools -> {"file-change", input["file_path"]}
        tool in ["Read", "Glob", "Grep"] -> {"file-read", input["file_path"] || input["pattern"]}
        true -> {"permission", tool}
      end

    {state, request_id} = open_request(flush(state), id, kind, prompt)
    request = {:permission, id, tool, context["permission_suggestions"]}
    {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
  end

  def handle_info({:claude, session, {:dialog, id, _kind, _payload}}, %{turn: nil} = state) do
    Session.answer_dialog(session, id, :cancelled)
    {:noreply, state}
  end

  # Claude asks before it continues a long, old conversation (`resume_return`).
  def handle_info({:claude, _session, {:dialog, id, "resume_return", payload}}, state) do
    question = resume_question(payload)
    {state, request_id} = open_question(flush(state), id, [question])
    request = {:dialog, id, question["id"]}
    {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}
  end

  def handle_info({:EXIT, session, _reason}, %{session: session} = state) do
    state =
      if state.turn,
        do: end_turn(state, "failed", "Claude exited"),
        else: end_work(state, "failed")

    # A wake waiting for its run ends there, cut short.
    wake = if match?(%{buffer: [_ | _]}, state.wake), do: %{state.wake | open: false}
    {:noreply, %{state | session: nil, wake: wake}}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, :timer)}
  def handle_info(_other, state), do: {:noreply, state}

  # The process runs the background work, so it ends with it: released when idle, or
  # stopped with its thread. Its writes may fail when the MC itself is stopping; the
  # next boot ends what is left (`HalC2.Orchestration.Recovery`).
  @impl true
  def terminate(_reason, state) do
    unless HalC2.Orchestration.Recovery.stopping?(), do: end_work(state, "interrupted")
    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def code_change(_old, state, _extra),
    do:
      {:ok,
       state
       |> Map.put_new(:work, %{})
       |> Map.put_new(:tasks, %{})
       |> Map.put_new(:last_ids, nil)
       |> Map.put_new(:wake, nil)
       |> Map.put_new(:permission_mode, nil)
       |> Map.put_new(:steered, false)
       |> Map.put_new(:launch, nil)
       |> Map.update!(:launch, &upgrade_launch(&1, state))
       |> Map.update!(:requests, &upgrade_requests/1)
       |> Map.put(:v, @state_version)}

  # A session started before launches recorded their MCP server has the thread's own.
  defp upgrade_launch(%{} = launch, %{last_ids: %{} = ids, thread_id: thread_id})
       when not is_map_key(launch, :mcp),
       do: Map.put(launch, :mcp, HalC2.Mcp.for_agent(thread_id, Entities.instance(ids)))

  defp upgrade_launch(launch, _state), do: launch

  # Allowing for the session keeps the CLI's own suggested rules, scoped to this
  # session, or allows the whole tool when it suggested none.
  defp session_rules(tool, suggestions) do
    case suggestions do
      [_ | _] ->
        Enum.map(suggestions, &Map.put(&1, "destination", "session"))

      _ ->
        [
          %{
            "type" => "addRules",
            "rules" => [%{"toolName" => tool}],
            "behavior" => "allow",
            "destination" => "session"
          }
        ]
    end
  end

  # Before session approvals, a pending permission held only its control id.
  defp upgrade_requests(requests),
    do:
      Map.new(requests, fn
        {id, control_id} when is_binary(control_id) -> {id, {:permission, control_id, nil, nil}}
        other -> other
      end)

  # AskUserQuestion's questions; each is keyed by its text, as Claude keys answers.
  defp claude_questions(input) do
    for {question, index} <- Enum.with_index(input["questions"] || [], 1),
        text = String.trim(question["question"] || ""),
        text != "" do
      %{
        "id" => text,
        "header" => non_empty(question["header"], "Question #{index}"),
        "question" => text,
        "options" =>
          for option <- question["options"] || [],
              label = String.trim(option["label"] || ""),
              label != "" do
            %{"label" => label, "description" => non_empty(option["description"], label)}
          end,
        "multiSelect" => question["multiSelect"] == true
      }
    end
  end

  @resume_compact "Compact and continue"
  @resume_never "Don't ask again"

  # The question of Claude's resume dialog: how old and how large the conversation is,
  # and what to do about it. Clients recognize the question and its "never" answer by
  # these words.
  defp resume_question(payload) do
    minutes = whole(payload["sessionAgeMinutes"])

    age =
      if minutes >= 60, do: "#{div(minutes, 60)}h #{rem(minutes, 60)}m", else: "#{minutes}m"

    tokens =
      payload["estimatedTokens"]
      |> whole()
      |> Integer.to_string()
      |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

    text = "This session is #{age} old and uses #{tokens} tokens. Compact it before continuing?"

    %{
      "id" => text,
      "header" => "Resume session",
      "question" => text,
      "options" => [
        %{
          "label" => @resume_compact,
          "description" => "Resume with a summary and use fewer tokens."
        },
        %{
          "label" => "Keep full history",
          "description" => "Resume without changing the conversation."
        },
        %{
          "label" => @resume_never,
          "description" => "Keep full history and skip future resume prompts."
        }
      ],
      "multiSelect" => false
    }
  end

  defp whole(number) when is_number(number), do: max(0, trunc(number))
  defp whole(_other), do: 0

  # What Claude does with the answer: compacts first, continues as it is, or continues
  # and never asks again.
  defp resume_choice(@resume_compact), do: "compact"
  defp resume_choice(@resume_never), do: "never"
  defp resume_choice(_answer), do: "continue"

  defp claude_answers(answers) do
    for {question, value} <- answers || %{}, into: %{} do
      {question, if(is_list(value), do: Enum.join(value, ", "), else: to_string(value || ""))}
    end
  end

  defp non_empty(value, default) when is_binary(value),
    do: if(String.trim(value) == "", do: default, else: String.trim(value))

  defp non_empty(_value, default), do: default

  # The message, with where its files are; images go inline as content blocks.
  defp claude_content(turn) do
    attachments = Map.get(turn, :attachments, [])

    text =
      turn.text
      |> Provider.prompt(turn.launch.prompt_effort)
      |> HalC2.Attachments.prompt_text(attachments)

    case HalC2.Attachments.native_images(attachments) do
      [] ->
        text

      images ->
        [%{"type" => "text", "text" => text}] ++
          for {mime, data} <- images,
              do: %{
                "type" => "image",
                "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
              }
    end
  end

  # Plan mode, or the thread's runtime mode.
  defp permission_mode(turn) do
    if Map.get(turn, :interaction_mode) == "plan",
      do: "plan",
      else: Map.get(@permission_modes, turn.runtime_mode, "default")
  end

  # A session carried from another machine that this Claude cannot open (a newer
  # Claude Code wrote it, say) ends before it answers `initialize`. The turn then starts
  # a new session with the handoff instead, and the user is told.
  defp open_session(%{session: nil} = state, %{fork: %{carried: true} = fork} = turn) do
    case ensure_session(state, turn) do
      {:ok, state} ->
        if opened?(state.session),
          do: {:ok, state, turn},
          else: handed_over(%{state | session: nil}, turn, fork)

      {:error, _reason} ->
        handed_over(state, turn, fork)
    end
  end

  defp open_session(state, turn) do
    with {:ok, state} <- ensure_session(state, turn), do: {:ok, state, turn}
  end

  defp opened?(session) do
    receive do
      {:claude, ^session, {:initialized, _reply}} -> true
      {:EXIT, ^session, _reason} -> false
    after
      20_000 -> true
    end
  end

  defp handed_over(state, turn, fork) do
    turn = %{
      turn
      | fork: nil,
        text: HalC2.Orchestration.Handoff.prompt(fork[:fallback], turn.text)
    }

    with {:ok, state} <- ensure_session(state, turn) do
      not_carried(state, turn, fork)
      {:ok, state, turn}
    end
  end

  defp not_carried(state, turn, fork) do
    at = Entities.now()
    id = "turn-item:claudeAgent:session-not-carried:#{turn.ids.run}"
    here = HalC2.ThreadArchive.label()
    mine = claude_version(turn)
    written = written_version(fork[:path])

    why =
      if mine && written && fork[:from] && Version.compare(mine, written) == :lt,
        do:
          ": Claude Code there (#{mine}) is older than on #{fork[:from]} (#{written}), which wrote it. It started a new session",
        else: ", so it started a new one"

    message =
      "Claude on #{here} could not continue its own session#{why} with a summary of the conversation."

    commit(state, fn stream ->
      [
        Orchestration.create(
          "turn-item",
          id,
          Entities.turn_item(
            turn.ids,
            id,
            "error",
            Orchestration.next_ordinal(stream),
            "completed",
            at,
            %{
              "title" => "Session not carried",
              "failure" => %{
                "class" => "provider_error",
                "message" => String.slice(message, 0, 4096),
                "code" => "session_not_carried",
                "retryable" => false
              }
            }
          )
        )
      ]
    end)
  end

  # The version `claude --version` reports here, as the turn would run it.
  defp claude_version(turn) do
    [command | args] = command(turn)
    env = Enum.to_list(HalC2.Settings.instance_env(Entities.instance(turn.ids)))

    case System.cmd(command, args ++ ["--version"], env: env, stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> List.first() |> semver()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The newest Claude Code version that wrote an entry of the transcript at `path`.
  defp written_version(path) when is_binary(path) do
    path
    |> File.stream!()
    |> Stream.map(&JSON.decode/1)
    |> Stream.flat_map(fn
      {:ok, %{"version" => version}} when is_binary(version) -> List.wrap(semver(version))
      _ -> []
    end)
    |> Enum.max(Version, fn -> nil end)
  rescue
    _ -> nil
  end

  defp written_version(_path), do: nil

  defp semver(text) when is_binary(text) do
    case Version.parse(text) do
      {:ok, version} -> version
      :error -> nil
    end
  end

  defp semver(_text), do: nil

  # The CLI takes its model, options and MCP server at launch, so a turn on others
  # resumes the conversation in a new process.
  defp ensure_session(%{session: session} = state, turn)
       when session != nil and state.launch != turn.launch do
    state = end_work(state, "interrupted")
    GenServer.stop(session)
    ensure_session(%{state | session: nil}, turn)
  end

  defp ensure_session(%{session: session} = state, turn) when session != nil do
    mode = permission_mode(turn)

    if state.permission_mode != mode do
      _ = Session.control(session, "set_permission_mode", %{"mode" => mode})
    end

    {:ok, %{state | permission_mode: mode}}
  end

  defp ensure_session(state, turn) do
    Process.flag(:trap_exit, true)

    opts = [
      handler: self(),
      cd: turn.cwd,
      model: turn.launch.model,
      effort: turn.launch.effort,
      settings: turn.launch.settings,
      permission_mode: permission_mode(turn),
      resume: fork_or(turn, :thread, turn.native_thread_id),
      resume_at: fork_or(turn, :turn, Map.get(turn, :head)),
      fork_session: Map.get(turn, :fork) != nil,
      partial_messages: true,
      mcp: turn.launch.mcp,
      # The instance's variables in settings (such as CLAUDE_CONFIG_DIR) reach Claude.
      env: Enum.to_list(HalC2.Settings.instance_env(Entities.instance(turn.ids))),
      log: state.thread_id
    ]

    case Session.start_link(Keyword.put(opts, :command, command(turn))) do
      {:ok, session} ->
        {:ok,
         %{state | session: session, permission_mode: permission_mode(turn), launch: turn.launch}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The `claude` the turn's instance runs: its binary path in settings, else the one on PATH.
  defp command(turn),
    do:
      HalC2.Settings.instance_command(
        Entities.instance(turn.ids),
        Application.get_env(:hal_c2, :claude_command) || ["claude"]
      )

  # A fork's first turn resumes the source session at the fork point, as a new session.
  defp fork_or(%{fork: %{} = fork}, key, _default), do: Map.fetch!(fork, key)
  defp fork_or(_turn, _key, default), do: default

  # --- messages ------------------------------------------------------------------

  # Claude runs one turn at a time and ends each with one `result`, so which turn a
  # result ends follows from the order: a wake Claude is running when a user's turn
  # starts ends first (`take_wake/2`), and between the MC's turns every result is a
  # wake's.
  defp receive_message(message, %{turn: nil, wake: %{buffer: buffer} = wake} = state)
       when is_list(buffer) do
    open = if result?(message), do: false, else: wake.open or wake?(message)
    %{state | wake: %{open: open, buffer: [message | buffer]}}
  end

  defp receive_message(message, %{turn: nil, wake: %{buffer: nil}} = state) do
    state = message(message, state)
    if result?(message), do: %{state | wake: nil}, else: state
  end

  defp receive_message(message, %{turn: nil, wake: nil} = state) do
    if wake?(message), do: wake(state, message), else: message(message, state)
  end

  # The result of the wake a user's turn took over; the user's own follows it. An
  # interrupt ends the user's turn with the first.
  defp receive_message(%{"type" => "result"}, %{wake: %{open: true}} = state)
       when not state.interrupted,
       do: %{state | wake: nil}

  defp receive_message(message, state), do: message(message, state)

  defp result?(message), do: match?(%{"type" => "result"}, message)

  defp wake?(%{"type" => type}) when type in ~w(assistant user stream_event), do: true
  defp wake?(_message), do: false

  # Claude started a turn by itself: the thread gets a message for it, from the agent,
  # whose run (`handle_call({:start_turn, %{wake: true}})`) queues behind any other.
  # Off this process, since starting the run calls back into it.
  defp wake(state, message) do
    runtime = self()
    thread_id = state.thread_id

    Task.start(fn ->
      stream = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
      latest = stream |> StreamState.list("run") |> Enum.max_by(& &1["ordinal"], fn -> %{} end)
      message_id = Entities.new_id("message")

      with {:error, reason} <-
             Orchestration.dispatch(%{
               "type" => "message.dispatch",
               "commandId" => "command:claude-wake:#{message_id}",
               "threadId" => thread_id,
               "messageId" => message_id,
               "text" => "Background task completed.",
               "attachments" => [],
               "modelSelection" => latest["modelSelection"],
               "dispatchMode" => %{"type" => "queue_after_active"},
               "createdBy" => "agent",
               "creationSource" => "provider",
               "providerWake" => true
             }) do
        Logger.warning("claude wake in #{thread_id} has no run: #{inspect(reason)}")
        send(runtime, :wake_refused)
      end
    end)

    %{state | wake: %{open: not result?(message), buffer: [message]}}
  end

  # A user's turn that starts while Claude runs a wake takes it over: what the wake said
  # so far joins the turn, and the message steers it, so the wake's `result` comes
  # before the turn's own instead of the two being one (`receive_message/2`). A new
  # process (`session` was another) ended the wake. A wake that already ended keeps
  # its messages for its own run.
  defp take_wake(%{wake: %{open: true} = wake} = state, session) do
    state =
      (wake.buffer || [])
      |> Enum.reverse()
      |> Enum.reject(&result?/1)
      |> Enum.reduce(%{state | wake: nil}, &message/2)

    if state.session == session,
      do: {%{state | wake: %{open: true, buffer: []}}, [priority: "now"]},
      else: {state, []}
  end

  defp take_wake(state, _session), do: {state, []}

  defp message(%{"type" => "rate_limit_event", "rate_limit_info" => %{} = info}, state) do
    HalC2.ProviderUsageLimits.claude_event(info)
    rate_limit(info, state)
  end

  # Background work reports its progress and end after its turn is over.
  defp message(%{"type" => "system", "subtype" => "task_notification"} = task, state) do
    tool = state.tasks[task["task_id"]] || task["tool_use_id"]
    status = Map.get(@task_status, task["status"], "failed")
    state = if state.work[tool], do: end_work(state, tool, status, task["summary"]), else: state
    %{state | tasks: Map.delete(state.tasks, task["task_id"])}
  end

  # A task Claude started without telling this runtime (between turns, or before it
  # was upgraded to record them) is recorded on its first progress.
  defp message(%{"type" => "system", "subtype" => "task_progress"} = task, state) do
    state =
      if is_map_key(state.tasks, task["task_id"]), do: state, else: task_started(state, task)

    text = non_empty(task["summary"], non_empty(task["description"], ""))

    case state.work[state.tasks[task["task_id"]]] do
      %{sub: %{} = sub} when text != "" -> NativeSubagent.progress(sub, text)
      _ -> :ok
    end

    state
  end

  defp message(
         %{
           "type" => "system",
           "subtype" => "task_updated",
           "patch" => %{"is_backgrounded" => true}
         } =
           task,
         state
       ) do
    case state.work[state.tasks[task["task_id"]]] do
      nil -> state
      work -> put_in(state.work[state.tasks[task["task_id"]]], %{work | background: true})
    end
  end

  # Claude starts tasks between turns too: in the turn a task notification wakes it
  # for, or resuming a subagent (SendMessage).
  defp message(%{"type" => "system", "subtype" => "task_started"} = task, state),
    do: task_started(state, task)

  # Between turns, a wake the thread would not run (`wake/2`) records only the work
  # Claude starts: its subagents and background commands, and their launches' results.
  defp message(
         %{"type" => "assistant", "message" => %{"content" => content}},
         %{turn: nil} = state
       )
       when is_list(content) do
    case with_ids(state) do
      %{last_ids: nil} = state ->
        state

      state ->
        state = %{state | turn: %{ids: state.last_ids}}

        content
        |> Enum.filter(&background_launch?/1)
        |> Enum.reduce(state, &assistant_block(&1, nil, nil, &2))
        |> Map.put(:turn, nil)
    end
  end

  defp message(%{"type" => "user", "message" => %{"content" => content}}, %{turn: nil} = state)
       when is_list(content) do
    Enum.reduce(content, state, fn
      %{"type" => "tool_result", "tool_use_id" => tool_id} = result, state
      when is_map_key(state.work, tool_id) ->
        tool_result(state, tool_id, result)

      _, state ->
        state
    end)
  end

  defp message(_message, %{turn: nil} = state), do: state

  defp message(%{"type" => "system", "subtype" => "init", "session_id" => session_id}, state) do
    ids = state.turn.ids

    if session_id != state.session_id do
      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-thread",
            ids.provider_thread,
            &Map.put(&1, "nativeThreadRef", Entities.provider_ref(session_id, "claudeAgent"))
          )
        ]
      end)
    end

    %{state | session_id: session_id}
  end

  defp message(%{"type" => "stream_event", "event" => event}, state),
    do: stream_event(event, state)

  defp message(
         %{"type" => "assistant", "message" => %{"id" => id, "content" => content}} = message,
         state
       ) do
    # The last assistant message is where a rollback to this turn resumes.
    state = if message["uuid"], do: put_in(state.turn[:head], message["uuid"]), else: state

    # A signed-out CLI answers with an auth error; the turn fails with how to sign in.
    state =
      if message["error"] == "authentication_failed" and message["parent_tool_use_id"] == nil and
           state.turn != nil,
         do: put_in(state.turn[:auth_failure], @signed_out),
         else: state

    content
    |> Enum.with_index()
    |> Enum.reduce(flush(state), fn {block, index}, state ->
      assistant_block(block, id, index, state)
    end)
    |> Map.put(:blocks, %{})
  end

  defp message(%{"type" => "user", "message" => %{"content" => content}}, state)
       when is_list(content) do
    Enum.reduce(content, state, fn
      %{"type" => "tool_result", "tool_use_id" => tool_id} = result, state ->
        tool_result(state, tool_id, result)

      _, state ->
        state
    end)
  end

  # The part of a steered turn that the new message cut short; the turn goes on.
  # Claude compacted the conversation: the timeline says so, and the context meter
  # takes the size Claude reports for what is left.
  defp message(
         %{"type" => "system", "subtype" => "compact_boundary"} = message,
         %{turn: turn} = state
       )
       when turn != nil do
    meta = message["compact_metadata"] || %{}
    native = message["uuid"] || "compaction:#{turn.ids.provider_turn}"
    count = fn key -> if is_number(meta[key]) and meta[key] > 0, do: round(meta[key]) end
    before = count.("pre_tokens")
    left = count.("post_tokens")

    fields =
      %{"driver" => "claudeAgent", "title" => "Context compacted"}
      |> then(&if(before, do: Map.put(&1, "beforeTokenCount", before), else: &1))
      |> then(&if(left, do: Map.put(&1, "afterTokenCount", left), else: &1))

    state =
      state
      |> flush()
      |> ensure_item(native, :compaction, fields)
      |> finish_item(native, "completed", & &1)

    if left do
      usage = %{"usedTokens" => left, "updatedAt" => Entities.now()}

      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-turn",
            turn.ids.provider_turn,
            &Map.put(&1, "tokenUsage", usage)
          )
        ]
      end)
    end

    state
  end

  defp message(%{"type" => "result", "terminal_reason" => reason}, %{steered: true} = state)
       when reason in ["aborted_streaming", "aborted_tools"] and not state.interrupted,
       do: %{state | steered: false}

  defp message(%{"type" => "result"} = result, state) do
    state = %{state | steered: false}

    status =
      cond do
        state.interrupted -> "interrupted"
        result["is_error"] == true or result["subtype"] != "success" -> "failed"
        true -> "completed"
      end

    failure =
      if status == "failed", do: state.turn[:auth_failure] || failure(result, state.turn)

    end_turn(state, status, failure)
  end

  defp message(_message, state), do: state

  # A rejected window pauses Claude inside the turn; the turn's end reports it as a
  # usage limit resetting at the latest window's reset, as the Node adapter does.
  defp rate_limit(_info, %{turn: nil} = state), do: state

  defp rate_limit(info, state) do
    type = info["rateLimitType"] || "unknown"

    overage? =
      info["overageStatus"] in ["allowed", "allowed_warning"] or info["isUsingOverage"] == true or
        info["overageInUse"] == true

    limits = Map.get(state.turn, :limits, %{})

    limits =
      cond do
        info["status"] == "rejected" and not overage? ->
          Map.put(limits, type, reset_at(info["resetsAt"]))

        info["status"] in ["allowed", "allowed_warning"] or overage? ->
          Map.delete(limits, type)

        true ->
          limits
      end

    put_in(state.turn[:limits], limits)
  end

  defp reset_at(seconds) when is_number(seconds) and seconds > 0,
    do: HalC2.Projection.JS.iso(trunc(seconds * 1000))

  defp reset_at(_), do: nil

  # A turn stopped by a usage limit fails with a structured `usage_limit` failure.
  defp failure(result, turn) do
    limits = Map.get(turn, :limits, %{})
    reason = result["terminal_reason"]
    api_status = result["api_error_status"]

    limited? =
      reason == "blocking_limit" or (result["subtype"] == "success" and api_status == 429) or
        (limits != %{} and (result["subtype"] != "success" or api_status in [nil, 429]) and
           reason in [nil, "api_error", "blocking_limit"])

    if limited? do
      resets = Map.values(limits)

      %{
        "class" => "usage_limit",
        "message" =>
          result["result"] ||
            "Claude usage limit reached. Send the message again once the limit resets.",
        "code" =>
          if(api_status, do: "api_error_#{api_status}", else: reason || result["subtype"]),
        "retryable" => nil,
        "resetAt" => if(resets != [] and nil not in resets, do: Enum.max(resets))
      }
    else
      result["result"] || result["subtype"]
    end
  end

  # Partial messages: text and thinking stream into their items as they arrive.
  defp stream_event(%{"type" => "message_start", "message" => %{"id" => id}}, state),
    do: %{state | message_id: id, blocks: %{}}

  defp stream_event(
         %{
           "type" => "content_block_start",
           "index" => index,
           "content_block" => %{"type" => type}
         },
         state
       )
       when type in ["text", "thinking"] do
    key = block_key(state.message_id, index)
    kind = if type == "text", do: :assistant, else: :reasoning
    state |> ensure_item(key, kind) |> put_in([:blocks, index], key)
  end

  defp stream_event(%{"type" => "content_block_delta", "index" => index, "delta" => delta}, state) do
    text = delta["text"] || delta["thinking"]

    case {state.blocks[index], text} do
      {nil, _} -> state
      {_, nil} -> state
      {key, text} -> buffer(state, key, "text", text)
    end
  end

  defp stream_event(_event, state), do: state

  # A complete assistant message: finishes streamed blocks with their final text,
  # and creates items for blocks that did not stream (tool calls, unstreamed text).
  defp assistant_block(%{"type" => "text", "text" => text}, id, index, state) do
    key = block_key(id, index)

    state
    |> ensure_item(key, :assistant)
    |> finish_item(key, "completed", &Map.merge(&1, %{"text" => text, "streaming" => false}))
  end

  defp assistant_block(%{"type" => "thinking", "thinking" => text}, id, index, state) do
    key = block_key(id, index)

    state
    |> ensure_item(key, :reasoning)
    |> finish_item(key, "completed", &Map.merge(&1, %{"text" => text, "streaming" => false}))
  end

  # Claude's todo list: one per run, updated in place.
  defp assistant_block(%{"type" => "tool_use", "name" => "TodoWrite"} = block, _id, _index, state) do
    steps =
      for {todo, index} <- Enum.with_index(get_in(block, ["input", "todos"]) || [], 1),
          text = non_empty(todo["content"], ""),
          text != "" do
        status =
          case todo["status"] do
            "completed" -> "completed"
            "in_progress" -> "running"
            _ -> "pending"
          end

        %{"id" => "step-#{index}", "text" => text, "status" => status}
      end

    write_todo(state, "todos:#{state.turn.ids.run}", steps)
  end

  # Shown as their question card and plan instead.
  defp assistant_block(%{"type" => "tool_use", "name" => name}, _id, _index, state)
       when name in ["AskUserQuestion", "ExitPlanMode"],
       do: state

  # A subagent; its task's messages end it (`task_started`, `task_notification`).
  defp assistant_block(
         %{"type" => "tool_use", "id" => tool_id, "name" => name} = block,
         _,
         _,
         state
       )
       when name in @agent_tools and not is_map_key(state.work, tool_id) do
    input = block["input"] || %{}
    state = flush(state)

    sub =
      NativeSubagent.start(work_ids(state), tool_id, %{
        "prompt" => input["prompt"],
        "title" => input["description"],
        "model" => input["model"]
      })

    put_in(state.work[tool_id], %{
      sub: sub,
      item: nil,
      background: input["run_in_background"] == true
    })
  end

  defp assistant_block(%{"type" => "tool_use", "name" => name}, _id, _index, state)
       when name in @agent_tools,
       do: state

  # SendMessage to a subagent Claude started earlier resumes it: the message is the
  # subagent's, shown in its own thread and not as a tool call of this one. The
  # subagent is found in the thread's record, so this holds after the MC restarted.
  defp assistant_block(
         %{"type" => "tool_use", "id" => tool_id, "name" => "SendMessage"} = block,
         _id,
         _index,
         state
       )
       when not is_map_key(state.items, tool_id) do
    input = block["input"] || %{}

    cond do
      is_map_key(state.work, tool_id) ->
        state

      entity = resumable(state, input["to"]) ->
        state = flush(state)
        sub = NativeSubagent.resume(work_ids(state), entity, input["message"])
        put_in(state.work[tool_id], %{sub: sub, item: nil, background: true})

      true ->
        tool_block(block, state)
    end
  end

  defp assistant_block(%{"type" => "tool_use"} = block, _id, _index, state),
    do: tool_block(block, state)

  defp assistant_block(_block, _id, _index, state), do: state

  # The subagent of this thread that Claude knows as the agent `to` (its task id).
  defp resumable(state, to) when is_binary(to) do
    HalC2.Streams.ensure(state.thread_id)
    |> HalC2.Streams.Server.state()
    |> StreamState.list("subagent")
    |> Enum.find(&(&1["origin"] == "provider_native" and &1["nativeTaskId"] == to))
  end

  defp resumable(_state, _to), do: nil

  defp tool_block(%{"id" => tool_id, "name" => name} = block, state) do
    input = block["input"] || %{}

    # A background command's tool result only says it started; its task ends it. A
    # monitor (the `Monitor` tool) always runs on: it is background work of its own
    # kind, never a command.
    state =
      if (name == "Bash" and input["run_in_background"] == true) or name == "Monitor",
        do: put_in(state.work[tool_id], %{sub: nil, item: nil, background: true}),
        else: state

    {kind, fields} =
      cond do
        name == "Bash" ->
          {:command, %{"input" => input["command"] || "", "output" => ""}}

        name in @file_tools ->
          {:file, %{"fileName" => input["file_path"] || input["notebook_path"] || name}}

        name in @web_tools ->
          {:web, %{"patterns" => Enum.filter([input["query"], input["url"]], &is_binary/1)}}

        true ->
          {:tool, %{"toolName" => name, "input" => input}}
      end

    ensure_item(state, tool_id, kind, fields)
  end

  defp tool_result(state, tool_id, result) do
    case state.work[tool_id] do
      nil ->
        item_result(state, tool_id, result)

      work ->
        cond do
          result["is_error"] == true or not work.background ->
            work_result(state, tool_id, work, result)

          # A background subagent runs on; the call that started it (SendMessage's, say)
          # is done.
          work.sub ->
            item_result(state, tool_id, result)

          true ->
            launched(state, tool_id, work, result)
        end
    end
  end

  defp background_launch?(%{"type" => "tool_use", "name" => name}) when name in @agent_tools,
    do: true

  defp background_launch?(%{"type" => "tool_use", "name" => "Bash", "input" => input}),
    do: input["run_in_background"] == true

  defp background_launch?(_block), do: false

  # A background launch's acknowledgement: a command's item leaves the turn's items, so
  # the turn's end does not close it, and keeps running with the acknowledgement as its
  # output. A launch that failed ends the work.
  defp launched(state, tool_id, work, result) do
    case Map.pop(state.items, tool_id) do
      {nil, _} ->
        state

      {item, items} ->
        output = result_text(result["content"])

        commit(
          state,
          &[
            Orchestration.upsert(&1, "turn-item", item.id, fn e ->
              Map.put(e, "output", output)
            end)
          ]
        )

        %{state | items: items, work: %{state.work | tool_id => %{work | item: item}}}
    end
  end

  defp work_result(state, tool_id, work, result) do
    status = if result["is_error"] == true, do: "failed", else: "completed"
    output = result_text(result["content"])
    state = if work.sub, do: end_work(state, tool_id, status, output), else: state
    state = %{state | work: Map.delete(state.work, tool_id)}
    item_result(state, tool_id, result)
  end

  defp item_result(state, tool_id, result) do
    case state.items[tool_id] do
      nil ->
        state

      %{kind: kind} ->
        status = if result["is_error"] == true, do: "failed", else: "completed"
        output = result_text(result["content"])

        finish_item(state, tool_id, status, fn entity ->
          case kind do
            :command -> Map.put(entity, "output", output)
            :file -> Map.put(entity, "diffStr", output)
            :tool -> Map.put(entity, "output", output)
            _ -> entity
          end
        end)
    end
  end

  defp end_turn(state, status, failure) do
    state = flush(state)

    # Items and prompts still open when the turn ends are closed with it; background
    # work goes on after a completed turn.
    state =
      if status == "completed",
        do: end_work(state, &(not &1.background), status),
        else: end_work(state, status)

    state = close_open_items(state, status)

    state =
      Enum.reduce(Map.keys(state.requests), state, &resolve_request(&2, &1, nil, "cancelled"))

    if head = state.turn[:head] do
      commit(state, fn stream ->
        [
          Orchestration.upsert(
            stream,
            "provider-turn",
            state.turn.ids.provider_turn,
            &Map.put(&1, "nativeTurnRef", Entities.provider_ref(head, "claudeAgent"))
          )
        ]
      end)
    end

    finish(state, status, failure)
    # Only a wake waiting for its own run outlives the turn.
    wake = if match?(%{buffer: [_ | _]}, state.wake), do: state.wake
    %{state | turn: nil, items: %{}, blocks: %{}, requests: %{}, wake: wake}
  end

  defp block_key(message_id, index), do: "#{message_id}:#{index}"

  # Claude registered a task for a tool call: a subagent's or a command's, which says
  # whether it runs in the background. Other tasks (a workflow, say) show as subagents.
  # Ambient tasks, such as watchers, are not activity.
  defp task_started(state, %{"task_id" => task_id} = task) do
    tool = task["tool_use_id"] || task_id
    background? = task["is_backgrounded"] == true

    cond do
      task["ambient"] == true or task["skip_transcript"] == true ->
        %{state | tasks: Map.put(state.tasks, task_id, nil)}

      work = state.work[tool] ->
        work = %{work | background: work.background or background?}
        # Claude's name for the subagent, which a later SendMessage addresses.
        if work.sub, do: name_subagent(state, work.sub, task_id)

        %{
          state
          | work: Map.put(state.work, tool, work),
            tasks: Map.put(state.tasks, task_id, tool)
        }

      background? and match?(%{kind: :command}, state.items[tool]) ->
        work = %{sub: nil, item: nil, background: true}

        %{
          state
          | work: Map.put(state.work, tool, work),
            tasks: Map.put(state.tasks, task_id, tool)
        }

      task["task_type"] == "local_bash" ->
        %{state | tasks: Map.put(state.tasks, task_id, nil)}

      true ->
        subagent_task(with_ids(state), tool, task)
    end
  end

  defp name_subagent(state, sub, task_id) do
    commit(state, fn stream ->
      [
        Orchestration.upsert(stream, "subagent", sub.id, fn
          nil -> nil
          entity -> Map.put(entity, "nativeTaskId", task_id)
        end)
      ]
    end)
  end

  # No run to join: nothing is recorded.
  defp subagent_task(%{turn: nil, last_ids: nil} = state, _tool, _task), do: state

  defp subagent_task(state, tool, %{"task_id" => task_id} = task) do
    state = flush(state)

    sub =
      NativeSubagent.start(work_ids(state), tool, %{
        "prompt" => task["prompt"] || task["description"],
        "title" => task["description"]
      })

    name_subagent(state, sub, task_id)
    work = %{sub: sub, item: nil, background: task["is_backgrounded"] != false}

    %{
      state
      | work: Map.put(state.work, tool, work),
        tasks: Map.put(state.tasks, task_id, tool)
    }
  end

  # Ends the work `which` picks (all of it by default) with `status`.
  defp end_work(state, which \\ fn _ -> true end, status)

  defp end_work(state, which, status) when is_function(which) do
    Enum.reduce(state.work, state, fn {tool, work}, state ->
      if which.(work), do: end_work(state, tool, status, nil), else: state
    end)
  end

  # Ends one piece of work: its subagent with the task's `result`, or its command item.
  defp end_work(state, tool, status, result) do
    case state.work[tool] do
      %{sub: %{} = sub} ->
        NativeSubagent.finish(sub, status, result)

      %{item: %{id: item_id, node: node_id}} ->
        at = Entities.now()
        done = %{"status" => status, "completedAt" => at}

        commit(state, fn stream ->
          [
            Orchestration.upsert(stream, "turn-item", item_id, fn item ->
              item
              |> Map.merge(Map.put(done, "updatedAt", at))
              |> then(&if(result, do: Map.put(&1, "output", result), else: &1))
            end),
            Orchestration.upsert(stream, "node", node_id, &Map.merge(&1, done))
          ]
        end)

      _ ->
        :ok
    end

    %{
      state
      | work: Map.delete(state.work, tool),
        tasks: Map.new(state.tasks, fn {task, t} -> {task, if(t != tool, do: t)} end)
    }
  end

  # The ids work joins: the running turn's, or between turns the latest one's.
  # The instance's `autoCompactWindow` (the tokens after which Claude compacts by
  # itself) goes to the CLI with its other settings; unset leaves Claude's default.
  defp auto_compact(launch, instance) do
    with window when is_binary(window) <-
           HalC2.Settings.instance_setting(instance, "autoCompactWindow"),
         {tokens, ""} when tokens >= 100_000 and tokens <= 1_000_000 <-
           Integer.parse(String.trim(window)) do
      %{launch | settings: Map.put(launch.settings, "autoCompactWindow", tokens)}
    else
      _ -> launch
    end
  end

  defp work_ids(%{turn: %{ids: ids}}), do: ids
  defp work_ids(state), do: state.last_ids

  # Fills in the latest turn's ids from the thread when this runtime has not run one
  # (it started, or was upgraded, after that turn).
  defp with_ids(%{turn: nil, last_ids: nil} = state) do
    stream = HalC2.Streams.Server.state(HalC2.Streams.ensure(state.thread_id))

    case stream
         |> StreamState.list("run")
         |> Enum.max_by(& &1["ordinal"], fn -> nil end) do
      nil ->
        state

      run ->
        ids = %{
          driver: driver(),
          instance: run["providerInstanceId"] || driver(),
          thread: state.thread_id,
          run: run["id"],
          attempt: run["activeAttemptId"],
          root_node: run["rootNodeId"],
          provider_thread: run["providerThreadId"]
        }

        %{state | last_ids: ids}
    end
  end

  defp with_ids(state), do: state

  defp result_text(content) when is_binary(content), do: content

  defp result_text(content) when is_list(content),
    do: Enum.map_join(content, "", fn block -> block["text"] || "" end)

  defp result_text(_), do: ""
end
