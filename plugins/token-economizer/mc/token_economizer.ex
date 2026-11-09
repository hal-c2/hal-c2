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
  steers the agent once with a redirect and, once the agent took it, says so in a notice;
  if the turn still looks stuck after that, a notice offers to stop it. The plugin never
  stops a turn itself: the person decides.

  What counts as stuck is learned per project and agent, from turns that ended green
  (`LoopGuard.Envelope`), kept in the plugin's data directory. Until a project has
  enough of them the guard watches and does nothing. The paid judge, the user's text
  generation model, runs only when the free gate opens, in a process of its own; its
  verdict is read at the turn's next call. The judge's jobs and the deliveries are the
  plugin's tasks, which end with it: a job is stopped once its segment or turn is over, a
  delivery once the mode no longer delivers.

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
  the turns under way as partial, and the turns heard until the events that were still
  waiting (`"waiting"`) have been, and a partial turn does not teach the envelope. A
  restarted process takes everything its feed still holds as such events. The
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
    # The deadline travels with the ask: handled after it, the answer would
    # never reach the conversation, so nothing may be staged on its behalf.
    deadline = System.monotonic_time(:millisecond) + 250
    GenServer.call(__MODULE__, {:shape_run, run, deadline}, 250)
  catch
    :exit, _ -> nil
  end

  # --- server ---------------------------------------------------------------------------

  @impl GenServer
  def init(settings) do
    {:ok, sup} = Task.Supervisor.start_link()
    {staged, staged_order} = read_staged()

    {:ok,
     %{
       settings: settings,
       # The plugin's tasks, linked to it: `tasks` is pid => {thread id, :judge | :delivery}.
       sup: sup,
       tasks: %{},
       # thread id => %{run, project, instance, guard, calls, kept, partial},
       # the turn under way
       turns: %{},
       # Events still to hear that the feed may have queued before ones it missed. A
       # process restarted while its feed ran cannot tell which those are, so it is all
       # the feed holds.
       missing: Host.feed_backlog(@id),
       # {project id, provider} => tracker
       trackers: %{},
       # project id => micro-skills state, loaded on first use
       skills: %{},
       # The projects with micro-skills of their own, read from disk once
       # (nil until then) and added to as facts are saved.
       known_skills: nil,
       # The shape of the listing last published, turn counts aside: the
       # topic is republished only when what a person would see changes.
       published_skills: nil,
       # {thread id, provider instance} => the fact ids staged for that
       # conversation, oldest first in staged_order and capped, so it cannot
       # grow for good. Kept on disk too: a conversation staged before the MC
       # restarted is resumed, not staged again, and still counts its facts.
       staged: staged,
       staged_order: staged_order,
       stats: %{"turns" => 0, "nudges" => 0, "aborts" => 0, "judgeCalls" => 0, "judgeTokens" => 0},
       # The latest redirects and stop offers, newest first.
       recent: []
     }}
  end

  @doc "What the `loopGuard` topic and the `status` call carry."
  def status(state) do
    Map.merge(state.stats, %{
      "mode" => if(on?(state), do: if(shadow?(state), do: "watch", else: "nudge"), else: "off"),
      "watching" => if(on?(state), do: map_size(state.turns), else: 0),
      "recent" => state.recent
    })
  end

  defp publish(state) do
    Host.publish(@id, @topic, status(state))
    state
  end

  @impl GenServer
  def handle_call({:settings, settings}, _from, state) do
    was_on = on?(state)
    was_micro = micro_on?(state)

    # The level and pinned thresholds shape each tracker: read them afresh. The
    # micro-skills' caps shape only what is staged, so the projects' learning
    # stays as it is, some of it maybe never saved, and takes the new caps.
    state = %{state | settings: settings, trackers: %{}, published_skills: nil}
    caps = EnvFacts.new(skills_caps(state))

    state = %{
      state
      | skills:
          Map.new(state.skills, fn {project_id, skills} ->
            {project_id, %{skills | max_facts: caps.max_facts, max_tokens: caps.max_tokens}}
          end)
    }

    # Learning switched under a turn leaves what it folds from incomplete
    # either way (its calls were not all kept, or its context predates the
    # switch): the turns under way are partial, and read back whole. So does
    # the guard switched on under one, which folded none of its calls so far
    # and must not teach the envelope from the rest.
    state =
      if micro_on?(state) != was_micro or (on?(state) and not was_on) do
        %{
          state
          | turns: Map.new(state.turns, fn {id, turn} -> {id, %{turn | partial: true}} end)
        }
      else
        state
      end

    state =
      cond do
        not on?(state) and not micro_on?(state) ->
          # Nothing listens: the turns under way are dropped, and the next
          # turn is heard from its start again.
          %{cancel(state, fn _ -> true end) | turns: %{}}

        # The guard off leaves the turns to the micro-skills, which still
        # learn from them; it judges and delivers nothing.
        not on?(state) ->
          state |> cancel(fn _ -> true end) |> stop_redirects()

        # Watching delivers nothing: a redirect on its way is stopped, and did not land.
        shadow?(state) ->
          state |> cancel(&match?({_, :delivery}, &1)) |> stop_redirects()

        true ->
          state
      end

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

  def handle_call({:shape_run, run, deadline}, _from, state) do
    if micro_on?(state) and is_binary(run["projectId"]) and
         System.monotonic_time(:millisecond) <= deadline do
      {skills, state} = skills_for(state, run["projectId"])
      {text, skills} = EnvFacts.render(skills)
      state = put_in(state.skills[run["projectId"]], skills)

      # The render itself can cross the deadline (a project's first load):
      # past it the answer is discarded, so stage nothing for it either.
      if System.monotonic_time(:millisecond) <= deadline do
        # Staged per conversation, not per thread: a thread carried on by
        # another provider instance (another driver, or another account of
        # the same one) gets its own staging, and each fold credits the
        # conversation it belongs to. Saved once the answer is on its way.
        # A run naming no conversation still gets the facts, but stages
        # nothing: no turn could be credited to it.
        key = {run["threadId"], run["instanceId"] || run["provider"]}
        reply = if(text == "", do: nil, else: %{"context" => text})

        if is_binary(elem(key, 0)) and is_binary(elem(key, 1)) do
          state = stage(state, key, EnvFacts.injected_ids(skills))
          {:reply, reply, state, {:continue, :save_staged}}
        else
          {:reply, reply, state}
        end
      else
        {:reply, nil, state}
      end
    else
      {:reply, nil, state}
    end
  end

  def handle_call({:observe, event}, _from, state) do
    state =
      if on?(state) or micro_on?(state) do
        state |> missed(event) |> hear(event) |> suspect(event)
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_continue(:save_staged, state) do
    save_staged(state)
    {:noreply, state}
  end

  @staged_kept 128

  @doc "The file that keeps what each conversation was staged."
  def staged_path, do: Path.join(Host.data_dir(@id), "staged.json")

  # `[[thread id, instance, ids], ...]`, oldest first; anything unreadable
  # is no staging, which costs a conversation's credit, never the plugin.
  defp read_staged do
    entries =
      with {:ok, text} <- File.read(staged_path()),
           {:ok, %{"staged" => entries}} when is_list(entries) <- JSON.decode(text) do
        for [thread_id, instance, ids] <- entries,
            is_binary(thread_id) and is_binary(instance) and is_list(ids) and
              Enum.all?(ids, &is_binary/1),
            do: {{thread_id, instance}, ids}
      else
        _ -> []
      end

    entries =
      entries
      |> Enum.reverse()
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.take(@staged_kept)
      |> Enum.reverse()

    {Map.new(entries), Enum.map(entries, &elem(&1, 0))}
  end

  # As `save_tracker/2`: a failed write costs persistence, never the plugin.
  defp save_staged(state) do
    path = staged_path()
    tmp = path <> ".tmp"

    entries =
      for {thread_id, instance} = key <- state.staged_order,
          do: [thread_id, instance, state.staged[key]]

    with :ok <- File.write(tmp, JSON.encode!(%{"staged" => entries})),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("token-economizer: staging not saved to #{path}: #{inspect(reason)}")
        :error
    end
  end

  # Remembers what a thread's conversation was staged, keeping the latest
  # conversations only: an evicted thread's later turns count no prevented
  # waste, and learn from failures as an unstaged conversation does.
  defp stage(state, key, ids) do
    order = (state.staged_order -- [key]) ++ [key]
    {evicted, order} = Enum.split(order, max(length(order) - @staged_kept, 0))
    staged = Map.drop(Map.put(state.staged, key, ids), evicted)

    %{state | staged: staged, staged_order: order}
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

  # A delivery's outcome. A redirect that reached its turn starts the turn's next segment,
  # whose judge job is not the old one's; one that did not leaves the guard to offer a
  # stop. The status says which, even when the turn has ended since.
  def handle_info({:delivered, thread_id, run_id, entry, result}, state) do
    landed = match?({:ok, _}, result)

    unless landed,
      do:
        Logger.info(
          "token-economizer: #{entry["action"]} not delivered to #{thread_id}: #{inspect(result)}"
        )

    state =
      case {entry["action"], state.turns[thread_id]} do
        {"nudge", %{run: ^run_id, guard: %{redirecting: true} = guard}} ->
          state = if landed, do: cancel_judge(state, thread_id), else: state
          put_in(state.turns[thread_id].guard, Turn.redirected(guard, landed))

        _ ->
          state
      end

    {:noreply, state |> remember(Map.put(entry, "delivered", landed)) |> publish()}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | tasks: Map.delete(state.tasks, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  # --- turns ------------------------------------------------------------------------------

  # The feed says what it missed on the next event it delivers, and how many events were
  # waiting behind that one then: those and it may have been sent before the missed
  # ones, and a turn that starts in them may have lost what was missed. So the turns
  # under way are partial, and so is each turn heard until they have been heard.
  defp missed(state, %{"dropped" => n, "waiting" => waiting})
       when is_integer(n) and n > 0 and is_integer(waiting) do
    turns = Map.new(state.turns, fn {id, turn} -> {id, %{turn | partial: true}} end)
    %{state | turns: turns, missing: max(state.missing, waiting + 1)}
  end

  defp missed(state, _), do: state

  defp suspect(%{missing: 0} = state, _event), do: state

  defp suspect(state, event) do
    state = %{state | missing: state.missing - 1}

    case state.turns[event["threadId"]] do
      nil -> state
      _turn -> put_in(state.turns[event["threadId"]].partial, true)
    end
  end

  defp hear(
         state,
         %{"type" => "turn.started", "threadId" => thread_id, "runId" => run_id} = event
       ) do
    # The envelope is the driver's (`claudeAgent`, `codex`); what was staged
    # is the conversation's, on the instance that holds it.
    project = {event["projectId"], event["provider"] || event["instanceId"]}

    turn = %{
      run: run_id,
      project: project,
      instance: event["instanceId"] || event["provider"],
      guard: Turn.new("#{thread_id}:#{run_id}"),
      # The turn's calls, newest first, for the micro-skills to fold at its
      # end; `:history` once there were more than are kept, and the turn is
      # read back from the thread instead.
      calls: [],
      kept: 0,
      partial: false
    }

    # A turn under way whose end was missed did not end normally.
    state |> close(thread_id, false) |> put_in([:turns, thread_id], turn)
  end

  defp hear(state, %{"type" => "turn.item", "threadId" => thread_id, "runId" => run_id} = item) do
    case {state.turns[thread_id], call_of(item)} do
      {%{run: ^run_id} = turn, {name, args, result, code} = call} ->
        state = if micro_on?(state), do: keep_call(state, thread_id, call), else: state

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

  # The most calls a turn under way keeps in memory, each cut to what the feed
  # gives a plugin. A turn that runs longer is read back from the thread at
  # its end, as a partial one is; what the guard folds is not affected.
  @calls_kept 256

  defp keep_call(state, thread_id, call) do
    update_in(state.turns[thread_id], fn
      %{calls: :history} = turn -> turn
      %{kept: @calls_kept} = turn -> %{turn | calls: :history}
      turn -> %{turn | calls: [call | turn.calls], kept: turn.kept + 1}
    end)
  end

  # Ends the thread's turn under way, if any. One that ended green, with calls, and was
  # heard whole feeds its project's envelope.
  defp close(state, thread_id, stopped_normally) do
    case Map.pop(state.turns, thread_id) do
      {nil, _} ->
        state

      {turn, turns} ->
        state = cancel_judge(%{state | turns: turns}, thread_id)

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
            |> EnvFacts.seed_injected(Map.get(state.staged, {thread_id, turn.instance}, []))
            |> EnvFacts.update_turn(calls, turn.run)

          save_skills(project_id, skills)

          state
          |> know_skill(project_id)
          |> put_in([:skills, project_id], skills)
          |> publish_skills()
      end
    else
      state
    end
  end

  defp fold_calls(_thread_id, %{partial: false, calls: calls}) when is_list(calls),
    do: Enum.reverse(calls)

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

    state =
      if job,
        do:
          state
          |> start_judge(thread_id, turn.run, job, thr["judge_confidence"])
          |> update_in([:stats, "judgeCalls"], &(&1 + 1)),
        else: state

    {guard, state} = act(state, thread_id, turn.run, guard, decision)
    put_in(state.turns[thread_id].guard, guard)
  end

  defp act(state, _thread_id, _run_id, guard, nil), do: {guard, state}

  defp act(state, thread_id, run_id, guard, {:nudge, reason}) do
    {body, guard} = Turn.nudge_body(guard)
    short = reason |> String.split(":") |> hd()
    entry = entry(thread_id, run_id, "nudge", reason, guard)
    state = update_in(state.stats["nudges"], &(&1 + 1))

    Logger.info(
      "token-economizer: nudged #{thread_id} (#{reason}, #{guard.cum_turns} tool calls)"
    )

    if shadow?(state) do
      state = cancel_judge(state, thread_id)
      entry = Map.put(entry, "delivered", false)
      {Turn.after_nudge(guard), state |> remember(entry) |> publish()}
    else
      # The thread says the agent was redirected only once the provider took it, which
      # it refuses once the run is over, or while it works if it cannot take a message.
      state =
        deliver(state, thread_id, run_id, entry, fn ->
          with {:ok, _} = steered <- Host.steer(@id, thread_id, run_id, body) do
            Host.notice(
              @id,
              thread_id,
              run_id,
              "TokenEconomizer nudged this turn (#{short}): the same failure kept recurring.",
              title: "Loop guard"
            )

            steered
          end
        end)

      {Turn.redirect(guard), state}
    end
  end

  defp act(state, thread_id, run_id, %{abort_delivered: false} = guard, {:abort, reason}) do
    # Still stuck once the redirects are spent. The plugin never stops a turn itself, so
    # the last rung is a notice that offers to.
    short = reason |> String.split(":") |> hd()

    Logger.info(
      "token-economizer: #{thread_id} still stuck (#{reason}, #{guard.cum_turns} tool calls)"
    )

    guard = %{guard | abort_delivered: true}
    state = update_in(state.stats["aborts"], &(&1 + 1))
    entry = entry(thread_id, run_id, "stop", reason, guard)

    if shadow?(state) do
      {guard, state |> remember(Map.put(entry, "delivered", false)) |> publish()}
    else
      redirected = if guard.redirects > 0, do: " after a redirect", else: ""

      text =
        "TokenEconomizer: this turn still looks stuck#{redirected} (#{short}, #{guard.cum_turns} tool calls). " <>
          "Stop it here if it should not go on."

      state =
        deliver(state, thread_id, run_id, entry, fn ->
          Host.notice(@id, thread_id, run_id, text, title: "Loop guard", interrupt: true)
        end)

      {guard, state}
    end
  end

  defp act(state, _thread_id, _run_id, guard, {:abort, _}), do: {guard, state}

  defp entry(thread_id, run_id, action, reason, guard) do
    %{
      "threadId" => thread_id,
      "runId" => run_id,
      "action" => action,
      "reason" => reason,
      "toolCalls" => guard.cum_turns,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp remember(state, entry), do: %{state | recent: Enum.take([entry | state.recent], @recent)}

  # Steering and notices go through orchestration; the guard does not wait on them, and
  # hears how each went (`{:delivered, ...}`).
  defp deliver(state, thread_id, run_id, entry, fun) do
    server = self()

    spawn_task(state, thread_id, :delivery, fn ->
      result =
        try do
          fun.()
        catch
          kind, reason -> {:error, Exception.format_banner(kind, reason)}
        end

      send(server, {:delivered, thread_id, run_id, entry, result})
    end)
  end

  # A new job replaces any the turn still has out, one gone stale: its answer would not
  # be read.
  defp start_judge(state, thread_id, run_id, job, threshold) do
    server = self()

    state
    |> cancel_judge(thread_id)
    |> spawn_task(thread_id, :judge, fn ->
      verdict =
        try do
          Judge.run(
            job["digest"],
            threshold,
            &Host.generate(@id, &1, &2),
            job["redirect"] != false
          )
        rescue
          e ->
            Logger.warning("token-economizer: the judge failed: #{Exception.message(e)}")
            nil
        end

      send(server, {:verdict, thread_id, run_id, job["id"], verdict})
    end)
  end

  defp spawn_task(state, thread_id, kind, fun) do
    {:ok, pid} = Task.Supervisor.start_child(state.sup, fun)
    Process.monitor(pid)
    put_in(state.tasks[pid], {thread_id, kind})
  end

  # Stops the tasks `fun` picks. What one sent before it stopped may still come, and is
  # read as from a job or redirect no longer out.
  defp cancel(state, fun) do
    {gone, kept} = Map.split_with(state.tasks, fn {_pid, task} -> fun.(task) end)
    Enum.each(Map.keys(gone), &Task.Supervisor.terminate_child(state.sup, &1))
    %{state | tasks: kept}
  end

  # A thread's judge jobs, once their segment or turn is over: a paid answer no one reads.
  defp cancel_judge(state, thread_id), do: cancel(state, &(&1 == {thread_id, :judge}))

  # A redirect on its way when delivering stopped did not land.
  defp stop_redirects(state) do
    turns =
      Map.new(state.turns, fn {id, turn} ->
        {id,
         update_in(
           turn.guard,
           &if(&1.redirecting, do: Turn.redirected(&1, false), else: &1)
         )}
      end)

    %{state | turns: turns}
  end

  # --- settings and the envelope's files ----------------------------------------------

  # The micro-skills' mode: upstream's `on` gains the paid proposer in a later
  # version; today it and `envfacts` both learn the free environment facts. The
  # host checks a save against plugin.json's choices but not a stored value (a
  # settings file edited by hand): anything else is off.
  defp micro_mode(state) do
    mode = state.settings["microSkills"]
    if mode in ["envfacts", "on"], do: mode, else: "off"
  end

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
        saved = read_skills(project_id)
        skills = EnvFacts.load(saved, skills_caps(state))

        # A fact the load left out for holding a credential leaves the file too.
        with %{"facts" => %{} = facts} <- saved,
             true <- map_size(skills.facts) < map_size(facts) do
          save_skills(project_id, skills)
        end

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

  # As `save_tracker/2`: a failed write costs persistence, never the plugin.
  # Callers that answer a person (drop and restore) report the failure; a
  # turn's fold keeps what it learned in memory.
  defp save_skills(project_id, skills) do
    path = micro_skills_path(project_id)
    tmp = path <> ".tmp"
    saved = Map.merge(EnvFacts.dump(skills), %{"projectId" => project_id})

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, JSON.encode!(saved)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("token-economizer: micro-skills not saved to #{path}: #{inspect(reason)}")

        :error
    end
  end

  # The projects with micro-skills of their own: from disk once, then as
  # state remembers them (a save adds its project), so no turn ever re-reads
  # every project's file to build the listing.
  defp known_skills(state) do
    case state.known_skills do
      nil ->
        known = MapSet.new(saved_project_ids())
        {known, %{state | known_skills: known}}

      known ->
        {known, state}
    end
  end

  defp know_skill(state, project_id) do
    {known, state} = known_skills(state)
    %{state | known_skills: MapSet.put(known, project_id)}
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
    {known, state} = known_skills(state)
    ids = known |> MapSet.union(MapSet.new(Map.keys(state.skills))) |> Enum.sort()

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

  # Publishes the listing when what a person would see in it changed: a
  # turn that taught nothing new only moves a turn count, and clients are
  # not sent every project's facts again for that.
  defp publish_skills(state) do
    {view, state} = micro_skills_view(state, nil)
    shape = listing_shape(view)

    if shape == state.published_skills do
      state
    else
      Host.publish(@id, @skills_topic, view)
      %{state | published_skills: shape}
    end
  end

  defp listing_shape(view) do
    Map.update!(view, "projects", fn projects ->
      Enum.map(projects, &Map.delete(&1, "turns"))
    end)
  end

  defp drop_or_restore(state, input, action) do
    with %{"projectId" => project_id, "id" => id} when is_binary(project_id) and is_binary(id) <-
           input || %{} do
      {skills, state} = skills_for(state, project_id)

      case if(action == :drop, do: EnvFacts.drop(skills, id), else: EnvFacts.restore(skills, id)) do
        {:ok, skills} ->
          case save_skills(project_id, skills) do
            :ok ->
              state =
                state
                |> know_skill(project_id)
                |> put_in([:skills, project_id], skills)
                |> publish_skills()

              {view, state} = micro_skills_view(state, project_id)
              {:reply, {:ok, view}, state}

            :error ->
              {:reply,
               {:error,
                "That could not be saved, so it has not been " <>
                  if(action == :drop, do: "dropped.", else: "restored.")}, state}
          end

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

  # A write that fails (a full disk, a data directory gone read-only) costs one turn's
  # lesson, which the tracker in memory still holds: never the plugin and every turn
  # it is guarding.
  defp save_tracker({project_id, provider} = project, tracker) do
    path = envelope_path(project)
    tmp = path <> ".tmp"

    saved =
      Map.merge(Envelope.dump(tracker), %{"projectId" => project_id, "provider" => provider})

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, JSON.encode!(saved)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("token-economizer: envelope not saved to #{path}: #{inspect(reason)}")
        :error
    end
  end

  # --- what a call was ------------------------------------------------------------------

  # What a plugin hears of a command's input at most (`TurnWriter.observed_item/1`).
  @observed_chars 4_000

  @doc """
  A turn item as the loop guard folds it, `{name, args, result, exit_code}`, or nil for
  an item that is not a tool call, or one that never ran (cancelled, as an edit or a
  command the person declined is). A failed call's exit code is the provider's, else 1;
  a successful command's is 0 only when the command's exit status covers the work it ran
  (`Turn.exit_status_covers/1`), else unknown: `python repro.py | tail` exits with
  `tail`'s status.

  A plugin hears only the last `#{@observed_chars}` characters of a command
  (`HalC2.Orchestration.TurnWriter.observed_item/1`), so a longer one may have lost its
  start, a heredoc's opening line with it, and what is left can be the body of a file it
  writes. Its text is not read at all.
  """
  def call_of(%{"status" => status}) when status in ["cancelled", "declined"], do: nil

  def call_of(%{"itemType" => type, "status" => status} = item) do
    failed = status == "failed"
    output = text(item["output"])

    case type do
      "command_execution" ->
        command = text(item["input"])
        command = if String.length(command) >= @observed_chars, do: "", else: command

        code =
          cond do
            is_integer(item["exitCode"]) and item["exitCode"] != 0 -> item["exitCode"]
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
        name = item["tool"] || item["title"] || type
        parsed = args(item["input"])

        # A shell run as a dynamic tool gets a command's exit reading: 0 only
        # when the command's exit status covers the work it ran, as above.
        code =
          cond do
            failed ->
              1

            status == "completed" and String.downcase(name) in ["bash", "shell"] and
                Turn.exit_status_covers(text(parsed["command"] || parsed["cmd"])) ->
              0

            true ->
              nil
          end

        {name, parsed, output, code}

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
