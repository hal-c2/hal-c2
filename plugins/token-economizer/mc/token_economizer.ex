# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/plugin/controller.py and tokeneconomizer/plugin/hosts.py,
# with the micro-skills' staging from tokeneconomizer/microskills/stage.py and
# tokeneconomizer/plugin/fold.py (microsoft/TokenEconomizer@cb42207e3e09), into Elixir
# for HAL-C2's MC. Changed: the guard hears the MC's turns (`observe/2`) instead of an
# agent's hooks, steers a turn through the MC instead of answering a hook, stages its
# facts through `shape_run/2` instead of a session-start hook, and keeps its state in
# one process.

defmodule HalC2Plugins.TokenEconomizer do
  @moduledoc """
  TokenEconomizer's MC part: the loop guard and the micro-skills.

  It hears every thread's turns. Each turn gets a guard (`LoopGuard.Turn`) that folds its
  tool calls as they end. When the guard finds the turn stuck in a loop, the plugin
  steers the agent once with a redirect and says so in a notice; if the turn still looks
  stuck after that, a notice offers to stop it. The plugin never stops a turn itself:
  the person decides.

  What counts as stuck is learned per project and agent, from turns that ended green
  (`LoopGuard.Envelope`), kept in the plugin's data directory. Until a project has
  enough of them the guard watches and does nothing. The paid judge, the user's text
  generation model, runs only when the free gate opens, in a process of its own; its
  verdict is read at the turn's next call.

  The micro-skills learn short environment facts per project from the same
  turns (`MicroSkills.EnvFacts`), kept in the data directory: which way of
  running the tests works here, which tool is not installed, which hosts
  refuse connections. A fact that has earned its place goes ahead of the
  first message of a new provider conversation (`shape_run/2`), never into
  one under way. The `microSkills` call lists a project's facts with the
  evidence behind them; `microSkills.drop` drops one for good (it is not
  learned again) and `microSkills.restore` lets it be learned again. The
  `microSkills` topic carries the same listing, published as facts change.

  A turn whose start the plugin missed is not watched. Missed events (`"dropped"`) mark
  the turns under way as partial, and a partial turn does not teach the envelope. The
  micro-skills read a partial turn back from the thread (`Host.history/3`) so a missed
  event in the middle of it teaches nothing half-seen; a turn never folded twice.

  The topic `loopGuard` carries `status/1`: counts since the MC started and the latest
  redirects and stop offers. It is published when a turn ends and when the guard acts,
  never per tool call.
  """
  @behaviour HalC2.Plugins.Extension
  use GenServer

  require Logger

  alias HalC2.Plugins.Host
  alias HalC2Plugins.TokenEconomizer.LoopGuard.{Envelope, Judge, Turn}
  alias HalC2Plugins.TokenEconomizer.MicroSkills.EnvFacts

  @id "token-economizer"
  @topic "loopGuard"
  @skills_topic "microSkills"
  @recent 20
  # The thresholds a person may pin, after upstream's `LOOPGUARD_KEYS`: `{kind, least,
  # most}`. A count takes a whole number, so 12.5 calls is refused rather than truncated.
  @pinnable %{
    "min_turns" => {:count, 1, nil},
    "edit_churn" => {:count, 1, nil},
    "distinct_edit_files" => {:count, 1, nil},
    "error_outputs" => {:count, 1, nil},
    "stagnation" => {:share, 0.0, 1.0},
    "envelope_pct" => {:share, 1.0, 100.0},
    "envelope_margin" => {:share, 0.1, nil},
    "envelope_min_samples" => {:count, 1, nil},
    "backstop_mult" => {:share, 0.1, nil},
    "judge_confidence" => {:share, 0.0, 1.0},
    "gate_min_turns" => {:count, 1, nil},
    "gate_error_outputs" => {:count, 1, nil}
  }

  # --- extension ------------------------------------------------------------------------

  @impl HalC2.Plugins.Extension
  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl HalC2.Plugins.Extension
  def settings_changed(pid, settings, _old), do: GenServer.call(pid, {:settings, settings})

  @impl HalC2.Plugins.Extension
  # Choices are checked by the host against plugin.json; these are what it cannot check.
  def validate_settings(settings) do
    nudges = settings["loopGuardNudges"] || 1
    thresholds = settings["loopGuardThresholds"] || %{}
    max_facts = settings["microSkillsMaxFacts"]
    max_tokens = settings["microSkillsMaxTokens"]

    cond do
      not (is_number(nudges) and nudges >= 0 and nudges == trunc(nudges)) ->
        {:error, "loopGuardNudges: give a whole number, 0 or more."}

      max_facts != nil and
          not (is_number(max_facts) and max_facts >= 1 and max_facts == trunc(max_facts)) ->
        {:error, "microSkillsMaxFacts: give a whole number, 1 or more."}

      max_tokens != nil and
          not (is_number(max_tokens) and max_tokens >= 1 and max_tokens == trunc(max_tokens)) ->
        {:error, "microSkillsMaxTokens: give a whole number, 1 or more."}

      not is_map(thresholds) ->
        {:error, "loopGuardThresholds: give an object of threshold names and values."}

      (unknown = Enum.sort(Map.keys(thresholds) -- Map.keys(@pinnable))) != [] ->
        {:error,
         "loopGuardThresholds: #{Enum.join(unknown, ", ")} #{if length(unknown) == 1, do: "is not a threshold", else: "are not thresholds"}; " <>
           "the thresholds are #{@pinnable |> Map.keys() |> Enum.sort() |> Enum.join(", ")}."}

      bad = Enum.find(Enum.sort(thresholds), fn {k, v} -> not pinnable?(@pinnable[k], v) end) ->
        {name, _} = bad
        {:error, "loopGuardThresholds: #{name} takes #{range(@pinnable[name])}."}

      true ->
        :ok
    end
  end

  defp pinnable?({kind, least, most}, v) do
    is_number(v) and v >= least and (most == nil or v <= most) and
      (kind != :count or v == trunc(v))
  end

  defp range({kind, least, most}) do
    what = if kind == :count, do: "a whole number", else: "a number"
    least = if kind == :count, do: trunc(least), else: least
    if most, do: "#{what} from #{least} to #{most}", else: "#{what}, #{least} or more"
  end

  @impl HalC2.Plugins.Extension
  def call("status", _input, _context), do: {:ok, GenServer.call(__MODULE__, :status)}

  def call("microSkills", input, _context),
    do: GenServer.call(__MODULE__, {:micro_skills, input})

  def call("microSkills.drop", input, _context),
    do: GenServer.call(__MODULE__, {:micro_skill_drop, input})

  def call("microSkills.restore", input, _context),
    do: GenServer.call(__MODULE__, {:micro_skill_restore, input})

  def call(method, _input, _context), do: {:error, "Unknown method #{method}."}

  @impl HalC2.Plugins.Extension
  # The feed waits for each event, so a guard is never folded out of order and missed
  # events are counted where they were missed.
  def observe(event, _context), do: GenServer.call(__MODULE__, {:observe, event}, 15_000)

  @impl HalC2.Plugins.Extension
  # Asked as a conversation starts, and never allowed to hold it back: answers
  # from the facts already learned, or nothing.
  def shape_run(run, _context) do
    GenServer.call(__MODULE__, {:shape_run, run}, 250)
  catch
    :exit, _ -> nil
  end

  # --- server ---------------------------------------------------------------------------

  @impl GenServer
  def init(settings) do
    {:ok,
     %{
       settings: settings,
       # thread id => %{run, project, guard, partial}, the turn under way
       turns: %{},
       # {project id, provider} => tracker
       trackers: %{},
       # project id => micro-skills state, loaded on first use
       skills: %{},
       # thread id => the fact ids staged for its conversation
       staged: %{},
       stats: %{"turns" => 0, "nudges" => 0, "aborts" => 0, "judgeCalls" => 0, "judgeTokens" => 0},
       # The latest redirects and stop offers, newest first.
       recent: []
     }}
  end

  @doc "What the `loopGuard` topic and the `status` call carry."
  def status(state) do
    Map.merge(state.stats, %{
      "mode" => if(on?(state), do: if(shadow?(state), do: "watch", else: "nudge"), else: "off"),
      "watching" => map_size(state.turns),
      "recent" => state.recent
    })
  end

  defp publish(state) do
    Host.publish(@id, @topic, status(state))
    state
  end

  @impl GenServer
  def handle_call({:settings, settings}, _from, state) do
    # The level and pinned thresholds shape each tracker, and the micro-skills'
    # caps shape what is staged: read them afresh.
    state = %{state | settings: settings, trackers: %{}, skills: %{}}
    state = if on?(state) or micro_on?(state), do: state, else: %{state | turns: %{}}
    {:reply, :ok, state |> publish() |> publish_skills()}
  end

  def handle_call(:status, _from, state), do: {:reply, status(state), state}

  def handle_call({:micro_skills, input}, _from, state) do
    {view, state} = micro_skills_view(state, project_id(input))
    {:reply, {:ok, view}, state}
  end

  def handle_call({:micro_skill_drop, input}, _from, state),
    do: drop_or_restore(state, input, :drop)

  def handle_call({:micro_skill_restore, input}, _from, state),
    do: drop_or_restore(state, input, :restore)

  def handle_call({:shape_run, run}, _from, state) do
    if micro_on?(state) and is_binary(run["projectId"]) do
      {skills, state} = skills_for(state, run["projectId"])
      {text, skills} = EnvFacts.render(skills)
      state = put_in(state.skills[run["projectId"]], skills)
      state = put_in(state.staged[run["threadId"]], EnvFacts.injected_ids(skills))
      {:reply, if(text == "", do: nil, else: %{"context" => text}), state}
    else
      {:reply, nil, state}
    end
  end

  def handle_call({:observe, event}, _from, state) do
    state =
      if on?(state) or micro_on?(state) do
        state |> missed(event["dropped"]) |> hear(event)
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:verdict, thread_id, run_id, job_id, verdict}, state) do
    tokens = (is_map(verdict) && verdict["_tokens"]) || 0
    state = update_in(state.stats["judgeTokens"], &(&1 + tokens))

    state =
      case state.turns[thread_id] do
        %{run: ^run_id} = turn ->
          put_in(state.turns[thread_id].guard, Turn.verdict(turn.guard, job_id, verdict))

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- turns ------------------------------------------------------------------------------

  defp missed(state, n) when is_integer(n) and n > 0,
    do: %{state | turns: Map.new(state.turns, fn {id, turn} -> {id, %{turn | partial: true}} end)}

  defp missed(state, _), do: state

  defp hear(
         state,
         %{"type" => "turn.started", "threadId" => thread_id, "runId" => run_id} = event
       ) do
    project = {event["projectId"], event["provider"] || event["instanceId"]}

    turn = %{
      run: run_id,
      project: project,
      guard: Turn.new("#{thread_id}:#{run_id}"),
      # The turn's calls, newest first, for the micro-skills to fold at its end.
      calls: [],
      partial: false
    }

    # A turn under way whose end was missed did not end normally.
    state |> close(thread_id, false) |> put_in([:turns, thread_id], turn)
  end

  defp hear(state, %{"type" => "turn.item", "threadId" => thread_id, "runId" => run_id} = item) do
    case {state.turns[thread_id], call_of(item)} do
      {%{run: ^run_id} = turn, {name, args, result, code} = call} ->
        state =
          if micro_on?(state),
            do: update_in(state.turns[thread_id].calls, &[call | &1]),
            else: state

        if on?(state), do: fold(state, thread_id, turn, name, args, result, code), else: state

      _ ->
        state
    end
  end

  defp hear(
         state,
         %{"type" => "turn.finished", "threadId" => thread_id, "runId" => run_id} = event
       ) do
    case state.turns[thread_id] do
      %{run: ^run_id} -> close(state, thread_id, event["status"] == "completed")
      _ -> state
    end
  end

  defp hear(state, _event), do: state

  # Ends the thread's turn under way, if any. One that ended green, with calls, and was
  # heard whole feeds its project's envelope.
  defp close(state, thread_id, stopped_normally) do
    case Map.pop(state.turns, thread_id) do
      {nil, _} ->
        state

      {turn, turns} ->
        state = %{state | turns: turns}

        state =
          if on?(state) do
            state = update_in(state.stats["turns"], &(&1 + 1))
            summary = Turn.summary(turn.guard, stopped_normally)

            Logger.debug(
              "token-economizer: turn #{inspect(Map.put(summary, "partial", turn.partial))}"
            )

            if not turn.partial and Turn.resolved_proxy(turn.guard, stopped_normally) do
              {tracker, state} = tracker(state, turn.project)
              tracker = Envelope.record_turn(tracker, turn.guard, stopped_normally)
              save_tracker(turn.project, tracker)
              publish(put_in(state.trackers[turn.project], tracker))
            else
              publish(state)
            end
          else
            state
          end

        fold_skills(state, thread_id, turn)
    end
  end

  # A finished turn folds into its project's micro-skills, once. A partial one
  # (the feed missed events in it) is read back whole from the thread, so what
  # was half heard is never half learned; if it cannot be read back, it is not
  # learned from at all.
  defp fold_skills(state, thread_id, turn) do
    {project_id, _provider} = turn.project

    if micro_on?(state) and is_binary(project_id) do
      case fold_calls(thread_id, turn) do
        nil ->
          state

        calls ->
          {skills, state} = skills_for(state, project_id)

          skills =
            skills
            |> EnvFacts.seed_injected(Map.get(state.staged, thread_id, []))
            |> EnvFacts.update_turn(calls, turn.run)

          save_skills(project_id, skills)
          state |> put_in([:skills, project_id], skills) |> publish_skills()
      end
    else
      state
    end
  end

  defp fold_calls(_thread_id, %{partial: false} = turn), do: Enum.reverse(turn.calls)

  defp fold_calls(thread_id, turn) do
    case Host.history(@id, thread_id, limit: 10) do
      {:ok, turns} ->
        case Enum.find(turns, &(&1["runId"] == turn.run)) do
          nil -> nil
          found -> found["items"] |> Enum.map(&call_of/1) |> Enum.reject(&is_nil/1)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp fold(state, thread_id, turn, name, args, result, code) do
    {tracker, state} = tracker(state, turn.project)
    envelope = Envelope.envelope(tracker)
    thr = Envelope.turn_thresholds(tracker, thresholds(state))
    # The judge is woken only by a sign of trouble, once a turn has run `min_turns`
    # calls; never merely because the turn outran this project's usual length, which
    # interactive turns do all the time.
    thr =
      Map.merge(thr, %{
        "gate_over_envelope" => false,
        "gate_min_turns" => max(thr["gate_min_turns"], thr["min_turns"])
      })

    {guard, decision, job} =
      Turn.fold(turn.guard, name, args, result, code,
        envelope: envelope,
        thr: thr,
        # No judge before the project has an envelope: the guard does not act on a
        # project whose usual turns it has not learned.
        judge: envelope != nil,
        nudge_budget: nudges(state),
        now: System.monotonic_time(:second)
      )

    if job, do: start_judge(thread_id, turn.run, job, thr["judge_confidence"])
    state = if job, do: update_in(state.stats["judgeCalls"], &(&1 + 1)), else: state
    {guard, state} = act(state, thread_id, turn.run, guard, decision)
    put_in(state.turns[thread_id].guard, guard)
  end

  defp act(state, _thread_id, _run_id, guard, nil), do: {guard, state}

  defp act(state, thread_id, run_id, guard, {:nudge, reason}) do
    {body, guard} = Turn.nudge_body(guard)
    guard = Turn.after_nudge(guard)
    short = reason |> String.split(":") |> hd()

    Logger.info(
      "token-economizer: nudged #{thread_id} (#{reason}, #{guard.cum_turns} tool calls)"
    )

    unless shadow?(state) do
      # The notice first, so the thread says why before the agent acts on the redirect.
      deliver(fn ->
        Host.notice(
          @id,
          thread_id,
          run_id,
          "TokenEconomizer nudged this turn (#{short}): the same failure kept recurring.",
          title: "Loop guard"
        )

        Host.steer(@id, thread_id, run_id, body)
      end)
    end

    state = update_in(state.stats["nudges"], &(&1 + 1))
    {guard, state |> remember(thread_id, run_id, "nudge", reason, guard) |> publish()}
  end

  defp act(state, thread_id, run_id, %{abort_delivered: false} = guard, {:abort, reason}) do
    # Still stuck once the redirects are spent. The plugin never stops a turn itself, so
    # the last rung is a notice that offers to.
    short = reason |> String.split(":") |> hd()

    Logger.info(
      "token-economizer: #{thread_id} still stuck (#{reason}, #{guard.cum_turns} tool calls)"
    )

    unless shadow?(state) do
      redirected = if guard.nudges_done > 0, do: " after a redirect", else: ""

      text =
        "TokenEconomizer: this turn still looks stuck#{redirected} (#{short}, #{guard.cum_turns} tool calls). " <>
          "Stop it here if it should not go on."

      deliver(fn ->
        Host.notice(@id, thread_id, run_id, text, title: "Loop guard", interrupt: true)
      end)
    end

    guard = %{guard | abort_delivered: true}
    state = update_in(state.stats["aborts"], &(&1 + 1))
    {guard, state |> remember(thread_id, run_id, "stop", reason, guard) |> publish()}
  end

  defp act(state, _thread_id, _run_id, guard, {:abort, _}), do: {guard, state}

  defp remember(state, thread_id, run_id, action, reason, guard) do
    entry = %{
      "threadId" => thread_id,
      "runId" => run_id,
      "action" => action,
      "reason" => reason,
      "toolCalls" => guard.cum_turns,
      "delivered" => not shadow?(state),
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    %{state | recent: Enum.take([entry | state.recent], @recent)}
  end

  # Steering and notices go through orchestration; the guard does not wait on them.
  defp deliver(fun), do: Task.start(fun)

  defp start_judge(thread_id, run_id, job, threshold) do
    server = self()

    Task.start(fn ->
      verdict =
        try do
          Judge.run(job["digest"], threshold, &Host.generate(@id, &1, &2))
        rescue
          e ->
            Logger.warning("token-economizer: the judge failed: #{Exception.message(e)}")
            nil
        end

      send(server, {:verdict, thread_id, run_id, job["id"], verdict})
    end)
  end

  # --- settings and the envelope's files ----------------------------------------------

  # The micro-skills' mode: upstream's `on` gains the paid proposer in a later
  # version; today it and `envfacts` both learn the free environment facts.
  defp micro_mode(state), do: state.settings["microSkills"] || "envfacts"
  defp micro_on?(state), do: micro_mode(state) != "off"

  defp skills_caps(state) do
    cap = fn key ->
      case state.settings[key] do
        value when is_number(value) and value >= 1 -> trunc(value)
        _ -> nil
      end
    end

    [max_facts: cap.("microSkillsMaxFacts"), max_tokens: cap.("microSkillsMaxTokens")]
  end

  defp skills_for(state, project_id) do
    case state.skills[project_id] do
      nil ->
        skills = EnvFacts.load(read_skills(project_id), skills_caps(state))
        {skills, put_in(state.skills[project_id], skills)}

      skills ->
        {skills, state}
    end
  end

  @doc "The file that keeps a project's micro-skills."
  def micro_skills_path(project_id) do
    key =
      :crypto.hash(:sha256, to_string(project_id))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    Path.join([Host.data_dir(@id), "micro-skills", key <> ".json"])
  end

  defp read_skills(project_id) do
    with {:ok, text} <- File.read(micro_skills_path(project_id)),
         {:ok, %{} = saved} <- JSON.decode(text) do
      saved
    else
      _ -> %{}
    end
  end

  defp save_skills(project_id, skills) do
    path = micro_skills_path(project_id)
    File.mkdir_p!(Path.dirname(path))
    saved = Map.merge(EnvFacts.dump(skills), %{"projectId" => project_id})
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(saved))
    File.rename!(tmp, path)
  end

  # The projects with micro-skills files of their own, beside those loaded.
  defp saved_project_ids do
    case Path.join([Host.data_dir(@id), "micro-skills"]) |> File.ls() do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          with true <- String.ends_with?(name, ".json"),
               {:ok, text} <-
                 File.read(Path.join([Host.data_dir(@id), "micro-skills", name])),
               {:ok, %{"projectId" => project_id}} when is_binary(project_id) <-
                 JSON.decode(text) do
            [project_id]
          else
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp project_id(%{"projectId" => project_id}) when is_binary(project_id), do: project_id
  defp project_id(_input), do: nil

  # What the `microSkills` call and topic carry: one project's facts when it is
  # named, else every project's, each in `EnvFacts.view/1`'s shape.
  defp micro_skills_view(state, nil) do
    ids = Enum.uniq(Map.keys(state.skills) ++ saved_project_ids())

    {projects, state} =
      Enum.map_reduce(ids, state, fn project_id, state ->
        {skills, state} = skills_for(state, project_id)
        {Map.merge(%{"projectId" => project_id}, EnvFacts.view(skills)), state}
      end)

    {%{"mode" => micro_mode(state), "projects" => projects}, state}
  end

  defp micro_skills_view(state, project_id) do
    {skills, state} = skills_for(state, project_id)

    {%{
       "mode" => micro_mode(state),
       "projects" => [Map.merge(%{"projectId" => project_id}, EnvFacts.view(skills))]
     }, state}
  end

  defp publish_skills(state) do
    {view, state} = micro_skills_view(state, nil)
    Host.publish(@id, @skills_topic, view)
    state
  end

  defp drop_or_restore(state, input, action) do
    with %{"projectId" => project_id, "id" => id} when is_binary(project_id) and is_binary(id) <-
           input || %{} do
      {skills, state} = skills_for(state, project_id)

      case if(action == :drop, do: EnvFacts.drop(skills, id), else: EnvFacts.restore(skills, id)) do
        {:ok, skills} ->
          save_skills(project_id, skills)
          state = state |> put_in([:skills, project_id], skills) |> publish_skills()
          {view, state} = micro_skills_view(state, project_id)
          {:reply, {:ok, view}, state}

        {:error, message} ->
          {:reply, {:error, message}, state}
      end
    else
      _ -> {:reply, {:error, "Give a projectId and an id."}, state}
    end
  end

  defp on?(state), do: state.settings["loopGuard"] != "off"
  # Watching decides as the guard would, and delivers nothing: what it would have done
  # is in the plugin's status and log.
  defp shadow?(state), do: state.settings["loopGuard"] == "watch"
  defp nudges(state), do: trunc(state.settings["loopGuardNudges"] || 1)
  defp level(state), do: state.settings["loopGuardLevel"] || "default"
  defp thresholds(state), do: state.settings["loopGuardThresholds"] || %{}

  defp tracker(state, project) do
    case state.trackers[project] do
      nil ->
        tracker = Envelope.new(level(state), thresholds(state), read_tracker(project))
        {tracker, put_in(state.trackers[project], tracker)}

      tracker ->
        {tracker, state}
    end
  end

  @doc "The file that keeps the envelope of `project`, `{project id, provider}`."
  def envelope_path({project_id, provider}) do
    key =
      :crypto.hash(:sha256, "#{project_id}\n#{provider}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    Path.join([Host.data_dir(@id), "envelopes", key <> ".json"])
  end

  defp read_tracker(project) do
    with {:ok, text} <- File.read(envelope_path(project)),
         {:ok, %{} = saved} <- JSON.decode(text) do
      saved
    else
      _ -> %{}
    end
  end

  defp save_tracker({project_id, provider} = project, tracker) do
    path = envelope_path(project)
    File.mkdir_p!(Path.dirname(path))

    saved =
      Map.merge(Envelope.dump(tracker), %{"projectId" => project_id, "provider" => provider})

    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(saved))
    File.rename!(tmp, path)
  end

  # --- what a call was ------------------------------------------------------------------

  @doc """
  A turn item as the loop guard folds it, `{name, args, result, exit_code}`, or nil for
  an item that is not a tool call. A command's exit code is the provider's when it gave
  one; else a failed call's is 1 and a successful one's 0 only when the command's exit
  status covers the work it ran (`Turn.exit_status_covers/1`), else unknown.
  """
  def call_of(%{"itemType" => type, "status" => status} = item) do
    failed = status == "failed"
    output = text(item["output"])

    case type do
      "command_execution" ->
        command = text(item["input"])

        code =
          cond do
            is_integer(item["exitCode"]) -> item["exitCode"]
            failed -> 1
            status == "completed" and Turn.exit_status_covers(command) -> 0
            true -> nil
          end

        {"bash", %{"command" => command}, output, code}

      "file_change" ->
        {"edit", %{"path" => item["path"]}, if(failed, do: output, else: ""), if(failed, do: 1)}

      "file_search" ->
        {"grep", args(item["input"]), output, if(failed, do: 1)}

      type when type in ["dynamic_tool", "web_search"] ->
        {item["tool"] || item["title"] || type, args(item["input"]), output, if(failed, do: 1)}

      _ ->
        nil
    end
  end

  def call_of(_), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  defp args(input) when is_binary(input) do
    case JSON.decode(input) do
      {:ok, %{} = args} -> args
      _ -> %{}
    end
  end

  defp args(%{} = input), do: input
  defp args(_), do: %{}
end
