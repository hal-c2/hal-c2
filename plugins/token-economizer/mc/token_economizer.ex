# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/plugin/controller.py and tokeneconomizer/plugin/hosts.py,
# with the micro-skills' staging from tokeneconomizer/microskills/stage.py and
# tokeneconomizer/plugin/fold.py (microsoft/TokenEconomizer@cb42207e3e09), into Elixir
# for HAL-C2's MC. Changed: the guard hears the MC's turns (`observe/2`) instead of an
# agent's hooks, steers a turn through the MC instead of answering a hook, stages its
# facts through `shape_run/2` instead of a session-start hook, and keeps its state in
# one process. Tool pruning is ported in `tool_prune_evidence.ex`; here it is fed the
# same turns and shapes each new provider conversation (`shape_run/2`) beside the facts.

defmodule HalC2Plugins.TokenEconomizer do
  @moduledoc """
  TokenEconomizer's MC part: the loop guard, the micro-skills and tool pruning.

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
  plugin's tasks, which end with it: a job is stopped once its segment or turn is over or
  the guard is turned off; a delivery under way always finishes, whatever the mode.

  The micro-skills learn short environment facts per project from the same
  turns (`MicroSkills.EnvFacts`), kept in the data directory: which way of
  running the tests works here, which tool is not installed, which hosts
  refuse connections. A fact that has earned its place goes ahead of the
  first message of a new provider conversation (`shape_run/2`), never into
  one under way. The `microSkills` call lists a project's facts with the
  evidence behind them; `microSkills.drop` drops one for good (it is not
  learned again) and `microSkills.restore` lets it be learned again. The
  `microSkills` topic carries the same listing, published as facts change.

  With the history import on (`historyImport`, off until turned on), the first
  turn to start in a project with nothing folded yet folds the project's
  earlier threads first (`MicroSkills.History`): the newest `historyMaxThreads`
  of those active in the last `historyDays` days, oldest first, each turn as a
  live one folds, and its green turns seed the loop guard's envelope where it
  has learned nothing yet. It reads in a task, a page at a time, never in this
  process; a project's turns that end meanwhile are held back and folded after
  it, in order. Where it got to is kept with the micro-skills, so a crash or a
  restart resumes it at the next turn without folding a turn twice. A project
  that had already learned is never imported into. `microSkills.forget`
  forgets what a project learned, the import's envelope samples with it, and
  runs the import again when it is on.

  With the micro-skills `on`, a paid proposer (`MicroSkills.Distiller`) also
  reads a compact digest of a project's recent turns every
  `microSkillsProposeEvery` turns and asks the user's text generation model
  for repository facts, each with a detector the plugin checks on later turns.
  The call is a task of the plugin's that sends its answer back
  (`{:proposed, project id, result}`); one that fails is not retried until the
  next proposal is due. Its spend is counted beside the judge's in the status.

  A project whose micro-skills file cannot be read is held: nothing is
  learned, staged or proposed for it, and its listing says why, until the file
  reads again. It is never silently started afresh.

  A turn whose start the plugin missed is not watched. Missed events (`"dropped"`) mark
  the turns under way as partial, and the turns heard until the events that were still
  waiting (`"waiting"`) have been, and a partial turn does not teach the envelope. A
  restarted process takes everything its feed still holds as such events. A turn whose
  end the feed lost for good is found by a sweep each minute, which asks the MC whether
  each turn's run is under way: one found ended on two sweeps running is dropped, as the
  next turn's start would drop it, and teaches the envelope nothing. The micro-skills read a partial
  turn back from the thread (`Host.history/3`) so a missed event in the middle of it
  teaches nothing half-seen; a turn is never folded twice.

  The topic `loopGuard` carries `status/1`: counts since the MC started and the latest
  redirects and stop offers. It is published when a turn ends and when the guard acts,
  never per tool call.

  Tool pruning watches the same turns for tools a conversation had loaded and never
  used (`ToolPrune.Evidence`). Once the evidence is enough it turns those tools off
  from the next provider conversation of the project — by itself under `auto`, once
  the project has been quiet a while, or when the person applies the proposal under
  `propose`; `off` only watches. A conversation already under way never has its
  tools changed. The topic `toolPrune` and the calls `toolPrune`, `toolPruneApply`
  and `toolPruneRestore` carry what is off, what is proposed, what was given back,
  and the evidence for each, per project and provider. Restore is the way back: a
  tool given back is never turned off again unless the person applies it by name.
  Turns a thread ran while the plugin was not running are read back once, when the
  thread is next heard, and fold in as imported evidence.
  """
  @behaviour HalC2.Plugins.Extension
  use GenServer

  require Logger

  alias HalC2.Plugins.Host
  alias HalC2Plugins.TokenEconomizer.LoopGuard.{Envelope, Judge, Turn}
  alias HalC2Plugins.TokenEconomizer.MicroSkills.{Distiller, EnvFacts, History}
  alias HalC2Plugins.TokenEconomizer.ToolPrune.Evidence, as: Prune

  @id "token-economizer"
  # The providers tool pruning has a unit for (`ToolPrune.Evidence.unit_for_provider/1`).
  @prune_providers ~w(claudeAgent codex)
  # How far back a read of a thread's history pages to find a segment's runs.
  @history_pages 20
  @topic "loopGuard"
  @skills_topic "microSkills"
  # How long a conversation's start waits for its shape (facts, denied tools), at most.
  @shape_run_ms 250
  @prune_topic "toolPrune"
  # The tool-pruning numbers a person may set, `{setting, least}`: whole numbers all.
  @prune_numbers %{
    "toolPruneEvidence" => 1,
    "toolPruneMinSessions" => 1,
    "toolPruneSessions" => 1,
    "toolPruneQuietMinutes" => 0
  }
  @recent 20
  # How often the plugin asks the MC which of its turns' runs are still under way.
  @sweep_ms 60_000
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
    every = settings["microSkillsProposeEvery"]

    cond do
      not (is_number(nudges) and nudges >= 0 and nudges == trunc(nudges)) ->
        {:error, "loopGuardNudges: give a whole number, 0 or more."}

      max_facts != nil and
          not (is_number(max_facts) and max_facts >= 1 and max_facts == trunc(max_facts)) ->
        {:error, "microSkillsMaxFacts: give a whole number, 1 or more."}

      max_tokens != nil and
          not (is_number(max_tokens) and max_tokens >= 1 and max_tokens == trunc(max_tokens)) ->
        {:error, "microSkillsMaxTokens: give a whole number, 1 or more."}

      settings["historyImport"] not in [nil, true, false] ->
        {:error, "historyImport: give true or false."}

      (bad = Enum.find(~w(historyDays historyMaxThreads), &(not whole?(settings[&1])))) != nil ->
        {:error, "#{bad}: give a whole number, 1 or more."}

      every != nil and not (is_number(every) and every >= 1 and every == trunc(every)) ->
        {:error, "microSkillsProposeEvery: give a whole number, 1 or more."}

      not is_map(thresholds) ->
        {:error, "loopGuardThresholds: give an object of threshold names and values."}

      (unknown = Enum.sort(Map.keys(thresholds) -- Map.keys(@pinnable))) != [] ->
        {:error,
         "loopGuardThresholds: #{Enum.join(unknown, ", ")} #{if length(unknown) == 1, do: "is not a threshold", else: "are not thresholds"}; " <>
           "the thresholds are #{@pinnable |> Map.keys() |> Enum.sort() |> Enum.join(", ")}."}

      bad = Enum.find(Enum.sort(thresholds), fn {k, v} -> not pinnable?(@pinnable[k], v) end) ->
        {name, _} = bad
        {:error, "loopGuardThresholds: #{name} takes #{range(@pinnable[name])}."}

      bad =
          Enum.find(Enum.sort(@prune_numbers), fn {key, least} ->
            value = settings[key]
            value != nil and not (is_number(value) and value >= least and value == trunc(value))
          end) ->
        {name, least} = bad
        {:error, "#{name}: give a whole number, #{least} or more."}

      not (is_list(settings["toolPruneProtect"] || []) and
               Enum.all?(settings["toolPruneProtect"] || [], &is_binary/1)) ->
        {:error, "toolPruneProtect: give a list of tool names or patterns."}

      true ->
        :ok
    end
  end

  defp whole?(nil), do: true
  defp whole?(v), do: is_number(v) and v >= 1 and v == trunc(v)

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

  def call("microSkills.forget", input, _context),
    do: GenServer.call(__MODULE__, {:micro_skill_forget, input})

  def call("toolPrune", input, _context),
    do: GenServer.call(__MODULE__, {:toolprune, :state, input || %{}})

  def call("toolPruneApply", input, _context),
    do: GenServer.call(__MODULE__, {:toolprune, :apply, input || %{}})

  def call("toolPruneRestore", input, _context),
    do: GenServer.call(__MODULE__, {:toolprune, :restore, input || %{}})

  def call(method, _input, _context), do: {:error, "Unknown method #{method}."}

  @impl HalC2.Plugins.Extension
  # The feed waits for each event, so a guard is never folded out of order and missed
  # events are counted where they were missed.
  def observe(event, _context), do: GenServer.call(__MODULE__, {:observe, event}, 15_000)

  @impl HalC2.Plugins.Extension
  # Asked as a conversation starts, and never allowed to hold it back: answers
  # from the facts already learned and the tools a project's evidence turned off
  # for the whole conversation, or nothing.
  def shape_run(run, _context) do
    # The deadline travels with the ask: handled after it, the answer would
    # never reach the conversation, so nothing may be staged on its behalf.
    deadline = System.monotonic_time(:millisecond) + @shape_run_ms
    GenServer.call(__MODULE__, {:shape_run, run, deadline}, @shape_run_ms)
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
       # The plugin's tasks, linked to it: `tasks` is pid => {thread id, :judge | :delivery}
       # or {project id, :proposer}.
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
       # project id => the shape of its entry last published, turn counts
       # aside: a project's topic is republished only when what a person would
       # see in it changes.
       published_skills: %{},
       # {thread id, provider instance} => the fact ids staged for that
       # conversation, oldest first in staged_order and capped, so it cannot
       # grow for good. Kept on disk too: a conversation staged before the MC
       # restarted is resumed, not staged again, and still counts its facts.
       staged: staged,
       staged_order: staged_order,
       # project id => its first fold from history (`MicroSkills.History`), loaded
       # with its micro-skills and saved with them; the one read under way, at most:
       # %{pid, project, fold, step, what}.
       folds: %{},
       reading: nil,
       # {project id, provider} => tool pruning's evidence, loaded on first use
       prunes: %{},
       # thread id => %{project, loaded, used, runs, active}, the conversation
       # tool pruning is hearing (a segment folds when it ends or goes idle); `runs`
       # are its runs as `%{"run" => id, "ordinal" => n}`, the ordinal nil until it ends
       convs: %{},
       # {thread id, project} => the loaded set the thread's conversation on the
       # project's provider was shaped with
       shaped: %{},
       # {thread id, project} => :read once its earlier turns were read back this
       # run, or {:unread, run id} while reading them failed: the first run heard
       # since, before which the next read stops (`seed_history/5`)
       seeded: %{},
       # {thread id, project} => the runs, as `%{"run" => id, "ordinal" => n}`, of segments
       # heard in part that folded before they could be read back: until they are
       # (`recover_uses/5`, `heard/4`), a use the feed dropped from them may be any tool,
       # so the project's conversations are denied nothing
       unresolved: %{},
       # The {thread id, project} keys of those whose thread has moved to another MC: kept,
       # for it may come back, but holding nothing off while it is away
       away: MapSet.new(),
       # {thread id, provider} => the tools used in it heard with no project to keep
       # them for, its thread's own unreadable (`strays/2`); saved, for it holds
       # pruning off until it is
       strays: read_strays(),
       # {project id, provider} => the timer that folds its idle conversations
       prune_timers: %{},
       stats: %{
         "turns" => 0,
         "nudges" => 0,
         "aborts" => 0,
         "judgeCalls" => 0,
         "judgeTokens" => 0,
         "proposerCalls" => 0,
         "proposerReplies" => 0,
         "proposerTokens" => 0
       },
       # The latest redirects and stop offers, newest first.
       recent: [],
       # Whether a run is under way, as the MC says (`Host.run_active?/3`); the runs of
       # turns the last sweep found ended, as {thread id, run id}; the next sweep's timer.
       active?: &Host.run_active?(@id, &1, &2),
       ended: MapSet.new(),
       sweep: arm(nil)
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
    mode = prune_cfg(state)["mode"]

    # The level and pinned thresholds shape each tracker: read them afresh. The
    # micro-skills' caps shape only what is staged, so the projects' learning
    # stays as it is, some of it maybe never saved, and takes the new caps. Tool
    # pruning reads its settings at each decision, so its evidence stays; a person
    # changing its mode has seen the saved uses it could not read.
    state = %{state | settings: settings, trackers: %{}}
    caps = EnvFacts.new(skills_caps(state))

    state = %{
      state
      | skills:
          Map.new(state.skills, fn {project_id, skills} ->
            {project_id,
             %{
               skills
               | max_facts: caps.max_facts,
                 max_tokens: caps.max_tokens,
                 proposing: caps.proposing
             }}
          end)
    }

    state =
      if prune_cfg(state)["mode"] != mode,
        do: release_unreadable(state, unreadable(state)),
        else: state

    # A proposal under way is one no one would read once the proposer is off.
    state =
      if micro_mode(state) == "on",
        do: state,
        else: cancel(state, &match?({_, :proposer}, &1))

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

    # Off, the guard reads no judge job; it hears the turns only while the micro-skills
    # learn from them. A delivery under way runs on: its steer may already have been
    # taken, and its answer says what happened. Watching only starts none (`act/5`).
    state =
      cond do
        on?(state) ->
          state

        # The guard off leaves the turns to the micro-skills, which still
        # learn from them; it judges nothing, and awaits no job it asked:
        # a verdict still on its way finds none pending (`Turn.verdict/3`),
        # and the guard switched back on asks afresh.
        micro_on?(state) ->
          state = cancel(state, &match?({_, :judge}, &1))

          turns =
            Map.new(state.turns, fn {id, turn} ->
              {id, %{turn | guard: %{turn.guard | judge_pending: nil, judge_arrived: nil}}}
            end)

          %{state | turns: turns}

        # Nothing listens: the turns under way are dropped, and the next turn
        # is heard from its start again.
        true ->
          %{cancel(state, &match?({_, :judge}, &1)) | turns: %{}}
      end

    # The import turned off stops each fold's reading; the live turns it held
    # back are still folded. Turned on again, a stopped fold resumes where it
    # stopped. Learning off pauses a fold where it is; back on, it goes on.
    state =
      if history_on?(state),
        do: each_fold(state, &History.resume/1),
        else: each_fold(state, &History.stop(&1, "the history import was turned off"))

    {:reply, :ok, state |> publish() |> publish_loaded_skills() |> publish_prune() |> pump()}
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

  def handle_call({:micro_skill_forget, input}, _from, state), do: forget(state, input)

  def handle_call({:shape_run, run, deadline}, _from, state) do
    {facts, ids, state} = shape(state, run, deadline)
    {denied, state} = shape_prune(state, run)

    reply =
      case Map.merge(facts || %{}, denied || %{}) do
        reply when reply == %{} -> nil
        reply -> reply
      end

    # Staged per conversation, not per thread: a thread carried on by another
    # provider instance (another driver, or another account of the same one)
    # gets its own staging, and each fold credits the conversation it belongs
    # to. Saved once the answer is on its way. A run naming no conversation
    # still gets the facts, but stages nothing: no turn could be credited to
    # it. A conversation that carries on another's shape without asking (a
    # native fork, a Claude home two instances share) has no staging of its
    # own, so its turns fold as an unstaged conversation's
    # (hal-c2/hal-c2#1473). One that replaces a staged conversation (a
    # Handoff) and is given nothing, learning off or past its deadline, is
    # staged nothing, so it is never credited its predecessor's facts.
    key = {run["threadId"], run["instanceId"] || run["provider"]}

    if is_binary(elem(key, 0)) and is_binary(elem(key, 1)) and
         (ids != nil or Map.has_key?(state.staged, key)) do
      {:reply, reply, stage(state, key, ids || []), {:continue, :save_staged}}
    else
      {:reply, reply, state}
    end
  end

  def handle_call({:toolprune, action, input}, _from, state) do
    {reply, state} = prune_call(state, action, input)
    {:reply, reply, state}
  end

  # With neither the guard nor the micro-skills listening no turn is heard, but the
  # window a report of missed events opens still runs over the events heard, so a turn
  # that starts in it once one is on again is partial; tool pruning hears every turn
  # whatever their modes.
  def handle_call({:observe, event}, _from, state) do
    state = state |> missed(event) |> hear_prune(event)
    state = if on?(state) or micro_on?(state), do: hear(state, event), else: state
    {:reply, :ok, suspect(state, event)}
  end

  # The facts a run is given, and their ids; nil ids when it is given none:
  # learning off, no project, or past its deadline.
  defp shape(state, run, deadline) do
    if micro_on?(state) and is_binary(run["projectId"]) and
         System.monotonic_time(:millisecond) <= deadline do
      {skills, state} = skills_for(state, run["projectId"])
      {text, skills} = EnvFacts.render(skills)
      state = put_in(state.skills[run["projectId"]], skills)

      # The render itself can cross the deadline (a project's first load):
      # past it the answer is discarded, so nothing was given.
      if System.monotonic_time(:millisecond) <= deadline,
        do:
          {if(text == "", do: nil, else: %{"context" => text}), EnvFacts.injected_ids(skills),
           state},
        else: {nil, nil, state}
    else
      {nil, nil, state}
    end
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

  def handle_info({:toolprune_tick, project}, state) do
    {:noreply,
     prune_tick(%{state | prune_timers: Map.delete(state.prune_timers, project)}, project)}
  end

  # A delivery's outcome. A redirect that reached its turn starts the turn's next segment,
  # whose judge job is not the old one's; one that did not leaves the guard to offer a
  # stop. The status says which, even when the turn has ended since. A redirect the
  # provider's runtime still held when it stopped waiting (`"confirmed" => false`) may
  # reach the agent, but nothing says when, so no later call can be read as after it:
  # it has not landed.
  def handle_info({:delivered, thread_id, run_id, entry, result}, state) do
    landed = confirmed?(result)

    unless landed,
      do:
        Logger.info(
          "token-economizer: #{entry["action"]} not delivered to #{thread_id}: #{inspect(result)}"
        )

    state =
      case {entry["action"], state.turns[thread_id]} do
        {"nudge", %{run: ^run_id, guard: %{redirecting: true} = guard}} ->
          state = if landed, do: cancel_judge(state, thread_id), else: state
          # The calls the agent had under way then may still be heard (`Turn.fold/6`).
          since = with {:ok, %{"ordinal" => last}} <- result, do: last, else: (_ -> nil)
          put_in(state.turns[thread_id].guard, Turn.redirected(guard, landed, since))

        _ ->
          state
      end

    {:noreply, state |> remember(Map.put(entry, "delivered", landed)) |> publish()}
  end

  # The turns whose run the MC says is not under way: their `turn.finished` was lost, or
  # is still on its way through the feed. One found so on two sweeps running is dropped,
  # as the next turn's start would drop it: it teaches nothing, and its judge job stops.
  # A run the MC cannot answer for counts as ended, so no turn is kept for good.
  def handle_info(:sweep, state) do
    ended =
      for {thread_id, %{run: run_id}} <- state.turns,
          not active?(state, thread_id, run_id),
          into: MapSet.new(),
          do: {thread_id, run_id}

    gone = MapSet.intersection(ended, state.ended)

    # The feed may have lost the turn's tail with its end: partial, the micro-skills read
    # the ended run back whole rather than learn from what was heard of it.
    state =
      Enum.reduce(gone, state, fn {thread_id, _}, state ->
        state |> put_in([:turns, thread_id, :partial], true) |> close(thread_id, false)
      end)

    {:noreply, %{state | ended: MapSet.difference(ended, gone), sweep: arm(state.sweep)}}
  end

  # A page of a fold, read in its task (`read/3`). One the fold has moved past
  # (forgotten, or read with learning off) is not folded.
  def handle_info({:history, project_id, fold_id, step, result}, state) do
    state =
      case state.reading do
        %{project: ^project_id, fold: ^fold_id, step: ^step} -> %{state | reading: nil}
        _ -> state
      end

    {:noreply, state |> fold_history(project_id, fold_id, step, result) |> pump()}
  end

  # A read that went down without an answer could not read what it was given.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{reading: %{pid: pid} = r} = state) do
    Logger.warning("token-economizer: a history read ended: #{inspect(reason)}")

    {:noreply,
     %{state | reading: nil}
     |> fold_history(r.project, r.fold, r.step, {:error, r.what, inspect(reason)})
     |> pump()}
  end

  # A proposal's answer, read against the project's window as it is now. Paid
  # for whatever it says; admitted only while the proposer is still on and the
  # project's file reads.
  def handle_info({:proposed, project_id, result}, state) do
    tokens =
      case result do
        {:ok, _out, usage} -> Distiller.tokens(usage)
        _ -> 0
      end

    state =
      state
      |> update_in([:stats, "proposerTokens"], &(&1 + tokens))
      |> update_in([:stats, "proposerReplies"], &(&1 + 1))

    case state.skills[project_id] do
      %EnvFacts{held: nil} = skills ->
        # The project pays for every answer; only a payload, while still on, is read.
        skills = Distiller.spent(skills, tokens)

        skills =
          case result do
            {:ok, %{"payload" => raw}, _usage} when is_binary(raw) ->
              if micro_mode(state) == "on" do
                {skills, outcomes} = Distiller.admit(skills, raw)
                log_proposal(project_id, outcomes)
                skills
              else
                log_proposal(project_id, :off)
                skills
              end

            other ->
              log_proposal(project_id, other)
              skills
          end

        state = put_in(state.skills[project_id], skills)
        save_skills(state, project_id)

        {:noreply,
         state
         |> publish_skills(project_id)
         |> publish()}

      _gone_or_held ->
        log_proposal(project_id, result)
        {:noreply, publish(state)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | tasks: Map.delete(state.tasks, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  # --- tool pruning -----------------------------------------------------------------------

  defp prune_cfg(state), do: Prune.config(state.settings)

  @doc "What the `toolPrune` topic carries: every project's evidence the plugin holds."
  def prune_status(state) do
    cfg = prune_cfg(state)

    %{
      "mode" => cfg["mode"],
      "unreadable" => unreadable(state),
      "projects" =>
        state.prunes
        |> Enum.sort()
        |> Enum.map(fn {project, prune} -> project_summary(state, project, prune, cfg, %{}) end)
    }
  end

  defp publish_prune(state) do
    Host.publish(@id, @prune_topic, prune_status(state))
    state
  end

  # A new conversation: read back what the thread ran while the plugin was not
  # running, and what the segments heard in part ran, so a tool used then is not
  # denied now, apply whatever `auto` held once the quiet has passed, then answer what
  # it runs without, and remember what it had loaded for its evidence. A segment that
  # cannot be read back may hold any use: the conversation is denied nothing.
  defp shape_prune(state, run) do
    unit = run["toolUnit"] || Prune.unit_for_provider(run["provider"])
    project = {run["projectId"], run["provider"]}

    if unit in ["tool", "capability"] and is_binary(run["projectId"]) and
         is_binary(run["provider"]) do
      cfg = prune_cfg(state)
      state = seed_history(state, run["threadId"], run["runId"], project, unit)
      {held?, state} = strays(state, project)
      {prune, state} = prune(state, project, unit)

      {prune, denied, state} =
        case recover_uses(prune, state, project, unit, run) do
          {:ok, prune, recovered, away} ->
            {prune, _} = Prune.apply_pending(prune, cfg, now_s(), active?(state, project))
            state = update_in(state.unresolved, &Map.drop(&1, recovered))
            denied = if held?, do: [], else: Prune.denied(prune, cfg)
            {prune, denied, put_away(state, project, away)}

          {:error, gone, away} ->
            state = update_in(state.unresolved, &Map.drop(&1, gone))
            {prune, [], put_away(state, project, away)}
        end

      changed? = prune != state.prunes[project]
      state = put_prune(state, project, prune, changed?)
      loaded = Prune.candidate_tools(unit) -- denied
      state = put_in(state.shaped[{run["threadId"], project}], loaded)
      state = if changed?, do: publish_prune(state), else: state
      {if(denied == [], do: nil, else: %{"deniedTools" => denied}), state}
    else
      {nil, state}
    end
  end

  # A call's input comes from any client: one that is not an object, or names its
  # project or provider with something other than a string, is refused rather than
  # read, so a bad call answers an error and the plugin keeps its state.
  defp prune_call(state, _action, input) when not is_map(input),
    do: {{:error, "Give toolPrune an object, with projectId, provider and tools."}, state}

  defp prune_call(state, _action, %{"projectId" => id}) when id != nil and not is_binary(id),
    do: {{:error, "Name the project by its id."}, state}

  defp prune_call(state, _action, %{"provider" => provider})
       when provider != nil and not is_binary(provider),
       do: {{:error, "Name the provider by its name."}, state}

  defp prune_call(state, action, input) do
    cfg = prune_cfg(state)
    # No tools means the whole proposal, or everything off: a malformed list is
    # refused rather than read as that.
    tools = input["tools"]
    tools? = tools == nil or (is_list(tools) and Enum.all?(tools, &is_binary/1))

    named? = is_binary(input["projectId"])

    case prune_targets(state, input) do
      _ when action != :state and not named? ->
        {{:error, "Name the project to apply or restore tools for."}, state}

      _ when action != :state and not tools? ->
        {{:error, "Name the tools as a list of names, or none for all of them."}, state}

      {:ok, [], state} when action != :state ->
        {{:error, "TokenEconomizer has no tool evidence for that project and provider."}, state}

      {:ok, targets, state} ->
        # Applying or restoring a provider's tools by hand is a person's word over the
        # saved uses it could not read: those of the providers acted on.
        state =
          if action == :state,
            do: state,
            else: release_unreadable(state, for({_, provider} <- targets, do: provider))

        {results, state} =
          Enum.map_reduce(targets, state, fn project, acc ->
            prune = acc.prunes[project]

            {next, extra} =
              case action do
                :state ->
                  {prune, %{}}

                :apply ->
                  {next, applied, refused} = Prune.apply_named(prune, cfg, tools)
                  {next, %{"applied" => applied, "refused" => refused}}

                :restore ->
                  {next, restored} = Prune.restore(prune, tools)
                  {next, %{"restored" => restored}}
              end

            # Saved whenever it changed: refusing a proposed tool restores nothing.
            acc = put_prune(acc, project, next, next != prune)
            {project_summary(acc, project, next, cfg, extra), acc}
          end)

        state = if action == :state, do: state, else: publish_prune(state)
        {{:ok, %{"mode" => cfg["mode"], "projects" => results}}, state}
    end
  end

  # `"unresolved"`: the threads whose segments heard in part could not be read back
  # yet (`recover_uses/5`); while there are any, the project's conversations are denied
  # nothing. `"away"`: those of them on another MC, which hold nothing off until they
  # come back. Threads heard with no project (`strays/2`) are unresolved for every
  # project of their provider. `"unreadable"`: saved uses of the provider's that could
  # not be read hold it off too (`unreadable/1`).
  defp project_summary(state, {project_id, provider} = project, prune, cfg, extra) do
    {away, unresolved} =
      for({{thread_id, ^project} = key, _} <- state.unresolved, do: {key, thread_id})
      |> Enum.split_with(fn {key, _} -> MapSet.member?(state.away, key) end)

    unresolved =
      unresolved ++ for({{t, ^provider}, _} <- state.strays, is_binary(t), do: {nil, t})

    Prune.summary(prune, cfg)
    |> Map.merge(%{
      "projectId" => project_id,
      "provider" => provider,
      "unresolved" => unresolved |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort(),
      "unreadable" => provider in unreadable(state),
      "away" => away |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    })
    |> Map.merge(extra)
  end

  # The projects a `toolPrune` call names, loading a named one's file if need be: one
  # with no evidence held or kept is none, so a call naming a project that never ran
  # (or a mistyped one) neither holds an empty entry nor saves a file for it. Without a
  # project the state call lists all held; apply and restore need one (`prune_call/3`).
  defp prune_targets(state, %{"projectId" => project_id, "provider" => provider})
       when is_binary(project_id) and is_binary(provider) do
    project = {project_id, provider}
    unit = Prune.unit_for_provider(provider)

    if unit != nil and
         (Map.has_key?(state.prunes, project) or File.exists?(toolprune_path(project))) do
      {_prune, state} = prune(state, project, unit)
      {:ok, [project], state}
    else
      {:ok, [], state}
    end
  end

  defp prune_targets(state, %{"projectId" => project_id}) when is_binary(project_id) do
    {:ok, for({id, _} = project <- Map.keys(state.prunes), id == project_id, do: project), state}
  end

  defp prune_targets(state, _input), do: {:ok, Map.keys(state.prunes), state}

  # The turns as tool pruning hears them, whatever the loop guard's mode: a new
  # conversation closes the thread's last one, a turn's items say what it used, and
  # a finished turn leaves the project idle for the quiet timer to fold. A thread's
  # segment is its provider's: a turn on another provider (a handoff, or one back to a
  # conversation it resumes) closes it and opens that provider's, with the tools its
  # conversation was shaped with.
  defp hear_prune(
         state,
         %{"type" => "turn.started", "threadId" => thread_id} = event
       ) do
    unit = Prune.unit_for_provider(event["provider"])
    project = {event["projectId"], event["provider"]}
    # Whatever provider the turn is on, it names the project.
    state = settle_strays(state, thread_id, event["projectId"])

    if unit == nil or not is_binary(event["projectId"]) do
      state
    else
      # Running here, it is back.
      state = update_in(state.away, &MapSet.delete(&1, {thread_id, project}))
      state = seed_history(state, thread_id, event["runId"], project, unit)
      {prune, state} = prune(state, project, unit)
      state = touch(state, project, prune)
      new? = event["newConversation"] == true

      run =
        if is_binary(event["runId"]), do: [%{"run" => event["runId"], "ordinal" => nil}], else: []

      case state.convs[thread_id] do
        %{project: ^project} = conv when not new? ->
          put_in(state.convs[thread_id], %{conv | runs: conv.runs ++ run, active: true})

        _ ->
          state =
            state
            |> close_conv(thread_id, event["runId"])
            |> cut_unread(thread_id, project, event["runId"])

          state =
            if new?,
              do: update_in(state.prunes[project], &Prune.new_conversation(&1, thread_id)),
              else: state

          put_in(state.convs[thread_id], %{
            thread: thread_id,
            project: project,
            loaded: state.shaped[{thread_id, project}] || default_loaded(state, project, unit),
            used: [],
            runs: run,
            active: true,
            partial: false,
            last_run: nil
          })
      end
    end
  end

  defp hear_prune(state, %{"type" => "turn.item", "threadId" => thread_id} = item) do
    case {state.convs[thread_id], item["provider"]} do
      # A use heard before its thread's turn was (a subagent's call as the plugin
      # restarted): no segment holds it, and its thread's history cannot show it, so
      # it is its project's evidence at once.
      {nil, provider} ->
        with true <- is_binary(provider),
             unit when unit != nil <- Prune.unit_for_provider(provider) do
          used = Prune.used_in_item(item, unit)

          # With no project, its thread's names it; one never here keeps nothing.
          case if(is_binary(item["projectId"]),
                 do: {:ok, item["projectId"]},
                 else: thread_project(thread_id)
               ) do
            {:ok, project_id} ->
              project = {project_id, provider}
              {_prune, state} = prune(state, project, unit)
              note_used(state, project, used)

            :gone ->
              state

            _away_or_error ->
              stray(state, {thread_id, provider}, used)
          end
        else
          _ -> state
        end

      # A use of a run on another provider than the thread's now, heard after the thread
      # went on (a subagent of that run's, still at work): its segment has folded, so the
      # use is that provider's evidence alone.
      {%{project: {project_id, provider}}, other} when is_binary(other) and other != provider ->
        project = {project_id, other}

        case Prune.unit_for_provider(other) do
          nil ->
            state

          unit ->
            {_prune, state} = prune(state, project, unit)
            note_used(state, project, Prune.used_in_item(item, unit))
        end

      {conv, _} ->
        unit = Prune.unit_for_provider(elem(conv.project, 1))
        used = Prune.used_in_item(item, unit)
        conv = %{conv | used: Enum.uniq(conv.used ++ used)}
        state = put_in(state.convs[thread_id], conv)
        {prune, state} = prune(state, conv.project, unit)
        state |> touch(conv.project, prune) |> note_used(conv.project, used)
    end
  end

  defp hear_prune(state, %{"type" => "turn.finished", "threadId" => thread_id} = event) do
    case state.convs[thread_id] do
      nil ->
        state

      conv ->
        run = event["runId"]
        state = ended_unresolved(state, thread_id, run, event["ordinal"])

        state =
          put_in(state.convs[thread_id], %{
            conv
            | active: false,
              runs:
                Enum.map(conv.runs, fn
                  %{"run" => ^run} = mark -> %{mark | "ordinal" => event["ordinal"]}
                  mark -> mark
                end),
              # The thread's watermark once the segment folds: its ordinal cuts the
              # history read back at it, though a rollback took the run out of it.
              last_run:
                if(is_binary(event["runId"]),
                  do: %{"run" => event["runId"], "ordinal" => event["ordinal"]},
                  else: conv.last_run
                )
          })

        unit = Prune.unit_for_provider(elem(conv.project, 1))
        {prune, state} = prune(state, conv.project, unit)
        state = state |> touch(conv.project, prune) |> save_prune(conv.project)
        schedule_tick(state, conv.project)
    end
  end

  defp hear_prune(state, _event), do: state

  # A run of a segment that folded unresolved has ended: absent from its thread's
  # history from now on, a rollback took it out (`recover_uses/5`).
  defp ended_unresolved(state, thread_id, run, ordinal) do
    Map.update!(state, :unresolved, fn unresolved ->
      Map.new(unresolved, fn
        {{^thread_id, _} = key, marks} ->
          {key,
           Enum.map(marks, fn
             %{"run" => ^run} = mark -> %{mark | "ordinal" => ordinal}
             mark -> mark
           end)}

        other ->
          other
      end)
    end)
  end

  # A use protects its tool at once, not only when the segment folds.
  defp stray(state, _key, []), do: state

  defp stray(state, key, used) do
    state
    |> update_in([:strays], &Map.update(&1, key, used, fn was -> Enum.uniq(was ++ used) end))
    |> save_strays()
  end

  # The uses heard with no project of `thread_id`'s, now its turn names it.
  defp settle_strays(state, thread_id, project_id) when is_binary(project_id) do
    Enum.reduce(state.strays, state, fn
      {{^thread_id, _} = key, used}, state -> settle_stray(state, key, project_id, used)
      _, state -> state
    end)
  end

  defp settle_strays(state, _thread_id, _project_id), do: state

  defp settle_stray(state, {_, provider} = key, project_id, used) do
    project = {project_id, provider}
    {_prune, state} = prune(state, project, Prune.unit_for_provider(provider))
    state = state |> update_in([:strays], &Map.delete(&1, key)) |> save_strays()
    note_used(state, project, used)
  end

  # Whether uses heard with no project (`hear_prune/2`), of the project's provider,
  # hold its pruning off: any may be its own while its thread cannot say which
  # project it is in. Once it can, they are that project's evidence; those of a
  # thread no longer here drop, and those of one away hold nothing until it is back.
  defp strays(state, {_, provider}) do
    Enum.reduce(state.strays, {false, state}, fn
      {{thread_id, ^provider} = key, used}, {held?, state} ->
        case thread_project(thread_id) do
          {:ok, project_id} -> {held?, settle_stray(state, key, project_id, used)}
          :gone -> {held?, state |> update_in([:strays], &Map.delete(&1, key)) |> save_strays()}
          :away -> {held?, state}
          :error -> {true, state}
        end

      _, acc ->
        acc
    end)
  end

  # The project `thread_id` is in, kept once it is deleted or moved. Naming none,
  # `:gone` when it was deleted or never here, `:away` while on another machine, and
  # `:error` when it could not be read or names none.
  defp thread_project(nil), do: :error

  defp thread_project(thread_id) do
    case Host.thread_project(@id, thread_id) do
      {:ok, project_id} when is_binary(project_id) -> {:ok, project_id}
      {:error, {:gone, _}} -> :gone
      {:error, {:away, _}} -> :away
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp strays_path, do: Path.join([Host.data_dir(@id), "toolprune", "strays.json"])

  # The saved strays. One that does not parse holds its provider's pruning off as a
  # use of an unreadable thread (`{nil, provider}`), or every provider's when not even
  # that can be read: what it kept may be any tool.
  defp read_strays do
    case File.read(strays_path()) do
      {:error, :enoent} ->
        %{}

      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, saved} when is_list(saved) -> Enum.reduce(saved, %{}, &read_stray/2)
          _ -> hold_stray(%{}, nil)
        end

      {:error, _} ->
        hold_stray(%{}, nil)
    end
  end

  defp read_stray(%{"threadId" => t, "provider" => p, "tools" => tools}, strays)
       when is_binary(t) and is_binary(p) and is_list(tools) do
    if Prune.unit_for_provider(p) != nil and Enum.all?(tools, &is_binary/1),
      do: Map.update(strays, {t, p}, tools, &Enum.uniq(&1 ++ tools)),
      else: hold_stray(strays, p)
  end

  defp read_stray(%{"provider" => p}, strays), do: hold_stray(strays, p)
  defp read_stray(_entry, strays), do: hold_stray(strays, nil)

  # The providers whose pruning saved uses that could not be read hold off
  # (`read_strays/0`): shown on the topic, and released by a person applying or
  # restoring that provider's tools or changing the mode.
  defp unreadable(state), do: for({nil, p} <- Map.keys(state.strays), do: p) |> Enum.sort()

  defp release_unreadable(state, providers) do
    held = for p <- providers, Map.has_key?(state.strays, {nil, p}), do: {nil, p}

    if held == [],
      do: state,
      else: state |> update_in([:strays], &Map.drop(&1, held)) |> save_strays()
  end

  defp hold_stray(strays, provider) do
    providers = if provider in @prune_providers, do: [provider], else: @prune_providers
    Enum.reduce(providers, strays, &Map.put_new(&2, {nil, &1}, []))
  end

  defp save_strays(state) do
    save_json(
      strays_path(),
      for(
        {{t, p}, tools} <- state.strays,
        do: %{"threadId" => t, "provider" => p, "tools" => tools}
      )
    )

    state
  end

  defp note_used(state, project, used) do
    noted = Prune.note_used(state.prunes[project], used, prune_cfg(state))

    if noted != state.prunes[project] do
      state |> put_prune(project, noted, true) |> publish_prune()
    else
      state
    end
  end

  defp default_loaded(state, project, unit) do
    {prune, _state} = prune(state, project, unit)
    Prune.candidate_tools(unit) -- Prune.denied(prune, prune_cfg(state))
  end

  # Folds the thread's open conversation, if any, and forgets it, as `run_id` starts
  # the thread's next: a run read back for it is one before `run_id`.
  defp close_conv(state, thread_id, run_id) do
    case Map.pop(state.convs, thread_id) do
      {nil, _} -> state
      {conv, convs} -> fold_conv(%{state | convs: convs}, conv, false, run_id)
    end
  end

  # Each run folds once, heard live or read back (`Prune.folded?/3`): the feed can tell
  # of a run after its thread's history was read with it in it.
  defp fold_conv(state, conv, imported \\ false, before \\ nil) do
    unit = Prune.unit_for_provider(elem(conv.project, 1))
    {prune, state} = prune(state, conv.project, unit)
    # Saved with the evidence, the thread's watermark moves to the segment's last run
    # (`seed_history/5`), so a restart before a segment folds reads its runs back; not
    # while its earlier runs are unread, which would leave them unread for good.
    key = {conv.thread, conv.project}
    read? = state.seeded[key] == :read
    heard_in_part? = Map.get(conv, :partial, false)

    conv =
      if read? and heard_in_part?,
        do: heard(conv, prune, unit, before),
        else: conv

    # A segment heard only in part (`missed/2`) whose runs could not be read back folds
    # as no evidence: its uses are still noted, its silences grow no streak, and the
    # watermark stays, so a restart reads its runs back.
    partial? = Map.get(conv, :partial, false)
    # A deleted thread leaves nothing to read back: its runs reach no conversation. One
    # moved away stays to read back, should it come back.
    gone? = Map.get(conv, :gone, false)

    runs =
      if partial?, do: [], else: Enum.reject(conv.runs, &Prune.folded?(prune, conv.thread, &1))

    # Its runs stay to read back, for every conversation the project shapes, until they
    # are; read back now, so are the thread's that folded so before them.
    state =
      cond do
        gone? ->
          update_in(state.unresolved, &Map.delete(&1, key))

        partial? ->
          update_in(
            state.unresolved,
            &Map.update(&1, key, conv.runs, fn marks ->
              Enum.uniq_by(marks ++ conv.runs, fn mark -> mark["run"] end)
            end)
          )

        heard_in_part? ->
          update_in(state.unresolved, &Map.delete(&1, key))

        true ->
          state
      end

    # Nor does a later fold of the thread: its runs are read back at its next turn.
    state =
      if read? and partial?,
        do: put_in(state.seeded[key], :partial),
        else: state

    prune =
      prune
      |> Prune.fold_segment(conv.loaded, conv.used, length(runs), prune_cfg(state), now_s(),
        imported: imported,
        thread: conv.thread,
        unrecorded: Map.get(conv, :unrecorded, [])
      )

    # Unread, the watermark stays, so the runs it folded are remembered past it.
    prune =
      if read? and not partial?,
        do: Prune.note_thread(prune, conv.thread, Map.get(conv, :last_run)),
        else: Prune.note_folded(prune, conv.thread, runs)

    state
    |> put_prune(conv.project, prune, true)
    |> publish_prune()
    |> schedule_tick(conv.project)
  end

  # A segment that folded unread (`fold_conv/3`) as `run_id` starts the thread's next:
  # the runs before it are read back, not it nor those after, heard as they run.
  defp cut_unread(state, thread_id, project, run_id) do
    key = {thread_id, project}

    if state.seeded[key] == :partial and is_binary(run_id),
      do: put_in(state.seeded[key], {:unread, run_id}),
      else: state
  end

  # A segment heard only in part, as its thread's history has it: its provider's runs
  # that ended since the watermark, with what their items used, the uses the feed
  # dropped among them, and the tools whose uses their items need not show
  # (`Prune.unrecorded/2`). Still partial when the history cannot be read, or does not
  # have one of the segment's runs yet (one still running as a quiet project folds it):
  # the uses dropped from it are read back at the thread's next turn.
  defp heard(conv, prune, unit, before) do
    with {:ok, history} <- history_back(conv.thread, before, conv.runs),
         read = MapSet.new(history, & &1["runId"]),
         true <-
           Enum.all?(conv.runs, &(&1["run"] in read or Prune.folded?(prune, conv.thread, &1))) do
      {watermark, runs} = unfolded(prune, history, conv.thread, conv.project, before)

      used = Enum.flat_map(runs, &uses(&1, unit))

      %{
        conv
        | used: Enum.uniq(conv.used ++ used),
          runs: Enum.map(runs, &run_mark/1),
          partial: false,
          last_run: watermark
      }
      |> Map.put(:unrecorded, unrecorded(runs, unit))
    else
      :gone -> Map.put(conv, :gone, true)
      _ -> conv
    end
  end

  # The uses of the project's segments heard in part (`missed/2`) that the feed may
  # have dropped, read back from their threads' histories and noted (`Prune.note_used/3`)
  # before a conversation is shaped: those under way, which still fold as they end,
  # their runs read back then as they are now, and those that folded unresolved, which
  # are then resolved, or dropped once their thread is gone (deleted). A thread moved to
  # another MC is `away`: its marks stay, for it may come back, which the next read
  # finds, but hold nothing off meanwhile. `{:error, gone, away}` while a history
  # cannot be read, or does not have all of a segment's runs yet: a run still going
  # (the history has only those that ended) may have used any tool. A run that ended
  # and is not there was rolled back: the history read reaches back past it
  # (`history_back/3`). Those of `gone`'s threads drop either way.
  defp recover_uses(prune, state, project, unit, run) do
    open =
      for {thread_id, %{project: ^project, partial: true} = conv} <- state.convs,
          do: {thread_id, conv.runs}

    folded = for {{thread_id, ^project}, marks} <- state.unresolved, do: {thread_id, marks}

    (open ++ folded)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce({:ok, prune, [], [], []}, fn {thread_id, marks},
                                                {ok, acc, recovered, gone, away} ->
      before = if thread_id == run["threadId"], do: run["runId"]
      marks = marks |> Enum.concat() |> Enum.reject(&(&1["run"] == run["runId"]))

      outstanding = Enum.reject(marks, &Prune.folded?(acc, thread_id, &1))

      with {:ok, history} <- history_back(thread_id, before, outstanding),
           read = MapSet.new(history, & &1["runId"]),
           true <-
             Enum.all?(
               marks,
               &(&1["run"] in read or &1["ordinal"] != nil or Prune.folded?(acc, thread_id, &1))
             ) do
        {_, runs} = unfolded(acc, history, thread_id, project, before)
        used = Enum.flat_map(runs, &uses(&1, unit))
        noted = Prune.note_used(acc, used, prune_cfg(state))
        {ok, noted, [{thread_id, project} | recovered], gone, away}
      else
        # Deleted: nothing it ran reaches a conversation any more.
        :gone -> {ok, acc, recovered, [{thread_id, project} | gone], away}
        :away -> {ok, acc, recovered, gone, [{thread_id, project} | away]}
        _ -> {:error, acc, recovered, gone, away}
      end
    end)
    |> case do
      {:ok, prune, recovered, gone, away} -> {:ok, prune, recovered ++ gone, away}
      {:error, _prune, _recovered, gone, away} -> {:error, gone, away}
    end
  end

  # The project's threads away on another MC, as its last shape found them.
  defp put_away(state, project, away) do
    kept = MapSet.reject(state.away, &(elem(&1, 1) == project))
    %{state | away: MapSet.union(kept, MapSet.new(away))}
  end

  # The provider's runs of `thread_id`'s history that are still to fold, before
  # `before`, and the watermark past them (`Prune.unseen_runs/4`).
  defp unfolded(prune, history, thread_id, {_, provider}, before) do
    Prune.unseen_runs(history, Prune.seeded_run(prune, thread_id), before, fn run ->
      run["provider"] == provider and not Prune.folded?(prune, thread_id, run_mark(run))
    end)
  end

  defp run_mark(run), do: %{"run" => run["runId"], "ordinal" => run["ordinal"]}

  defp uses(run, unit), do: Enum.flat_map(run["items"] || [], &Prune.used_in_item(&1, unit))

  defp unrecorded(runs, unit),
    do: runs |> Enum.flat_map(&Prune.unrecorded(&1, unit)) |> Enum.uniq()

  # Once the project has been quiet long enough, its open conversations fold as
  # finished sessions (a later resume starts a new segment with the same loaded
  # tools, which a conversation keeps), and whatever `auto` held is applied.
  defp prune_tick(state, project) do
    unit = Prune.unit_for_provider(elem(project, 1))

    if unit == nil or active?(state, project) do
      schedule_tick(state, project, 60_000)
    else
      cfg = prune_cfg(state)
      {prune, state} = prune(state, project, unit)
      idle = now_s() - prune["lastActivity"]
      waited = now_s() - ((prune["pending"] || %{})["since"] || now_s())

      if idle >= cfg["quiet_minutes"] * 60 or (prune["pending"] != nil and waited >= 86_400) do
        state =
          Enum.reduce(state.convs, state, fn {thread_id, conv}, acc ->
            if conv.project == project and (conv.runs != [] or conv.used != []) do
              acc
              |> fold_conv(conv)
              |> put_in([:convs, thread_id], %{
                conv
                | used: [],
                  runs: [],
                  active: false,
                  partial: false,
                  last_run: nil
              })
            else
              acc
            end
          end)

        {prune, state} = prune(state, project, unit)
        {prune, applied} = Prune.apply_pending(prune, cfg, now_s(), false)

        if applied != [] do
          Logger.info(
            "token-economizer: turned off #{Enum.join(applied, ", ")} for project #{elem(project, 0)} (#{elem(project, 1)})"
          )
        end

        state |> put_prune(project, prune, applied != []) |> publish_prune()
      else
        schedule_tick(state, project)
      end
    end
  end

  defp schedule_tick(state, project, delay \\ nil) do
    if Map.has_key?(state.prune_timers, project) do
      state
    else
      cfg = prune_cfg(state)
      ms = delay || max(cfg["quiet_minutes"] * 60_000, 0)
      ref = Process.send_after(self(), {:toolprune_tick, project}, ms)
      put_in(state.prune_timers[project], ref)
    end
  end

  defp active?(state, project),
    do: Enum.any?(state.convs, fn {_id, conv} -> conv.project == project and conv.active end)

  defp touch(state, project, prune) do
    put_in(state.prunes[project], Prune.activity(prune, now_s()))
  end

  # Turns a thread ran while the plugin was not running, read back once per run of
  # the plugin and folded as one imported session: what they used for good, and
  # their prompts as evidence `auto` alone does not act on. Read once per thread and
  # provider, and only the runs after the last already folded for the thread
  # (`Prune.note_thread/3`'s watermark, advanced as each live segment folds), so a
  # restart never folds a turn twice nor loses one heard but not yet folded. Only the
  # provider's own runs count: a thread's runs on another are that provider's evidence.
  # Read as `run_id` starts, and only the runs before it.
  #
  # A read that fails is tried again at the thread's next turn, up to the run first
  # heard since, and until it succeeds no fold moves the watermark (`fold_conv/3`):
  # the runs it could not read are still to fold, and those heard live already did. A
  # segment heard in part that folds unread is read so too, up to the turn after it.
  defp seed_history(state, thread_id, run_id, project, unit) do
    key = {thread_id, project}

    case state.seeded[key] do
      :read ->
        state

      seeded ->
        before = with {:unread, first} <- seeded, do: first, else: (_ -> run_id)

        case history(thread_id, before) do
          {:ok, history} ->
            fold_history(put_in(state.seeded[key], :read), history, key, before, unit)

          _unread ->
            unread = with {:unread, _} <- seeded, do: seeded, else: (_ -> {:unread, run_id})
            put_in(state.seeded[key], unread)
        end
    end
  end

  defp fold_history(state, history, {thread_id, project}, before, unit) do
    {prune, state} = prune(state, project, unit)

    {watermark, runs} = unfolded(prune, history, thread_id, project, before)

    # The watermark moves past the runs once they fold, as a live segment's does.
    if runs == [] do
      put_in(state.prunes[project], Prune.note_thread(prune, thread_id, watermark))
    else
      used = runs |> Enum.flat_map(&uses(&1, unit)) |> Enum.uniq()

      fold_conv(
        state,
        %{
          thread: thread_id,
          project: project,
          loaded: Prune.candidate_tools(unit),
          used: used,
          runs: Enum.map(runs, &run_mark/1),
          unrecorded: unrecorded(runs, unit),
          last_run: watermark
        },
        true
      )
    end
  end

  # `history/2`'s runs, older pages before them too, until they reach back to the oldest
  # of `marks` with an ordinal, or to the thread's first run: a mark's run that ended
  # and is not among them then was rolled back, not left behind by the window. Past
  # `@history_pages` pages, `:error`, so nothing is taken as rolled back.
  defp history_back(thread_id, before, marks) do
    oldest =
      marks |> Enum.map(& &1["ordinal"]) |> Enum.filter(&is_integer/1) |> Enum.min(fn -> nil end)

    page_back(thread_id, before, oldest, [], @history_pages)
  end

  defp page_back(thread_id, before, oldest, later, pages) do
    with {:ok, page} <- history(thread_id, before) do
      runs = page ++ later

      cond do
        oldest == nil or length(page) < history_page() -> {:ok, runs}
        is_integer(hd(page)["ordinal"]) and hd(page)["ordinal"] <= oldest -> {:ok, runs}
        pages <= 1 -> :error
        true -> page_back(thread_id, hd(page)["runId"], oldest, runs, pages - 1)
      end
    end
  end

  # A page of history: 50 runs, fewer in the property tests, which page through many.
  defp history_page, do: Application.get_env(:hal_c2, :token_economizer_history_page, 50)

  # The 50 runs that ended before `run_id` started, however late the feed tells of it
  # (the last 50 to end with no `run_id`).
  # Each names the driver it ran on, which is what a project's evidence is kept by, even
  # once its instance is deleted. `:gone` when the thread is deleted, or never was:
  # its runs never will be read. `:away` while it is on another MC, which it may come
  # back from. `:error` when they could not be read this time.
  defp history(thread_id, run_id) do
    case Host.history(@id, thread_id, limit: history_page(), before: run_id) do
      {:ok, runs} when is_list(runs) -> {:ok, runs}
      {:error, {:gone, _}} -> :gone
      {:error, {:away, _}} -> :away
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp now_s, do: System.os_time(:second)

  # --- tool pruning's files ---------------------------------------------------

  defp prune(state, project, unit) do
    case state.prunes[project] do
      nil ->
        prune = Prune.new(unit, read_prune(project))
        {prune, put_in(state.prunes[project], prune)}

      prune ->
        {prune, state}
    end
  end

  defp put_prune(state, project, prune, save?) do
    state = put_in(state.prunes[project], prune)
    if save?, do: save_prune(state, project), else: state
  end

  @doc "The file that keeps tool pruning's evidence of `project`, `{project id, provider}`."
  def toolprune_path({project_id, provider}) do
    key =
      :crypto.hash(:sha256, "#{project_id}\n#{provider}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    Path.join([Host.data_dir(@id), "toolprune", key <> ".json"])
  end

  defp read_prune(project) do
    with {:ok, text} <- File.read(toolprune_path(project)),
         {:ok, %{} = saved} <- JSON.decode(text) do
      saved
    else
      _ -> %{}
    end
  end

  defp save_prune(state, {project_id, provider} = project) do
    case state.prunes[project] do
      nil ->
        state

      prune ->
        saved =
          Map.merge(Prune.dump(prune), %{"projectId" => project_id, "provider" => provider})

        save_json(toolprune_path(project), saved)
        state
    end
  end

  defp active?(state, thread_id, run_id) do
    state.active?.(thread_id, run_id) == true
  catch
    kind, reason ->
      Logger.warning(
        "token-economizer: no answer for run #{run_id}: #{Exception.format_banner(kind, reason)}"
      )

      false
  end

  # The next sweep, which replaces any still to come.
  defp arm(timer) do
    if timer, do: Process.cancel_timer(timer)
    Process.send_after(self(), :sweep, @sweep_ms)
  end

  # --- turns ------------------------------------------------------------------------------

  # The feed says what it missed on the next event it delivers, and how many events were
  # waiting behind that one then: those and it may have been sent before the missed
  # ones, and a turn that starts in them may have lost what was missed. So the turns
  # and conversations under way are partial, and so is each one heard until they have
  # been heard.
  #
  # A partial turn teaches the envelope nothing. In a partial conversation what was
  # used still counts, but nothing may grow an unused streak (a missed item may be the
  # very use that would have reset it), and it stops counting as active: a missed turn
  # end would otherwise hold its project active, and `auto` stalled, until its next turn.
  defp missed(state, %{"dropped" => n, "waiting" => waiting})
       when is_integer(n) and n > 0 and is_integer(waiting) do
    %{
      state
      | turns: Map.new(state.turns, fn {id, turn} -> {id, %{turn | partial: true}} end),
        convs: Map.new(state.convs, fn {id, conv} -> {id, suspect_conv(conv)} end),
        missing: max(state.missing, waiting + 1)
    }
  end

  defp missed(state, _), do: state

  defp suspect(%{missing: 0} = state, _event), do: state

  defp suspect(state, %{"threadId" => thread_id}) do
    state = %{state | missing: state.missing - 1}

    state =
      if state.turns[thread_id],
        do: put_in(state.turns[thread_id].partial, true),
        else: state

    if state.convs[thread_id],
      do: update_in(state.convs[thread_id], &suspect_conv/1),
      else: state
  end

  defp suspect(state, _event), do: %{state | missing: state.missing - 1}

  defp suspect_conv(conv), do: %{conv | partial: true, active: false}

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
      # What its conversation was staged as it started, credited at its fold
      # even if the conversation is replaced before then.
      injected: Map.get(state.staged, {thread_id, event["instanceId"] || event["provider"]}, []),
      # The turn's calls, newest first, for the micro-skills to fold at its
      # end; `:history` once there were more than are kept, and the turn is
      # read back from the thread instead.
      calls: [],
      kept: 0,
      partial: false
    }

    # A turn under way whose end was missed did not end normally.
    state
    |> close(thread_id, false)
    |> put_in([:turns, thread_id], turn)
    |> start_fold(event["projectId"])
  end

  # A subagent's call is not the turn's own: the loop guard watches the agent's loop.
  defp hear(state, %{"type" => "turn.item", "subagent" => true}), do: state

  defp hear(state, %{"type" => "turn.item", "threadId" => thread_id, "runId" => run_id} = item) do
    case {state.turns[thread_id], call_of(item)} do
      {%{run: ^run_id} = turn, {_name, _args, _result, _code} = call} ->
        state = if micro_on?(state), do: keep_call(state, thread_id, call), else: state

        if on?(state), do: fold(state, thread_id, turn, call, item["ordinal"]), else: state

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

            if learns?(turn, stopped_normally) do
              {tracker, state} = tracker(state, turn.project)

              tracker =
                tracker
                |> History.claim(state.folds[elem(turn.project, 0)])
                |> History.record_turn(turn.guard, stopped_normally)

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
      # The fold is kept with the skills, so looking at it loads them; that is
      # kept only for a turn held back, as a turn that teaches nothing changes
      # nothing.
      {skills, loaded} = skills_for(state, project_id)
      fold = loaded.folds[project_id]

      # A fold from history under way folds this turn after it, read back
      # whole then, unless it read it already. A held project (its file does
      # not read) learns nothing until it does.
      cond do
        skills.held != nil ->
          loaded

        History.running?(fold) ->
          if turn.run in skills.folded,
            do: loaded,
            else:
              loaded
              |> put_fold(project_id, History.hold(fold, [thread_id, turn.run, turn.injected]))
              |> pump()

        true ->
          fold_live(state, project_id, thread_id, turn)
      end
    else
      state
    end
  end

  defp fold_live(state, project_id, thread_id, turn) do
    case fold_calls(thread_id, turn) do
      nil ->
        state

      calls ->
        {skills, state} = skills_for(state, project_id)
        proposing = micro_mode(state) == "on"

        skills =
          skills
          |> EnvFacts.seed_injected(turn.injected)
          |> then(&if(proposing, do: Distiller.fold(&1, calls, turn.run), else: &1))
          |> EnvFacts.update_turn(calls, turn.run)

        state = put_in(state.skills[project_id], skills)
        save_skills(state, project_id)

        state
        |> know_skill(project_id)
        |> publish_skills(project_id)
        |> maybe_propose(project_id)
    end
  end

  defp log_proposal(project_id, outcomes) when is_list(outcomes),
    do: Logger.info("token-economizer: proposal for project #{project_id}: #{inspect(outcomes)}")

  defp log_proposal(project_id, other) do
    Logger.info(
      "token-economizer: proposal for project #{project_id} admitted nothing: " <>
        inspect(other, limit: 5, printable_limit: 200)
    )
  end

  # One proposal per project at a time, when one is due: the prompt is built
  # here and the model asked off the plugin's process. It is counted as made
  # when it starts, so a call that fails or never answers is not asked again
  # until the next is due.
  defp maybe_propose(state, project_id) do
    skills = state.skills[project_id]
    out? = Enum.any?(state.tasks, fn {_pid, task} -> task == {project_id, :proposer} end)

    if micro_mode(state) == "on" and skills.held == nil and not out? and
         Distiller.due?(skills, propose_every(state)) do
      prompt = Distiller.prompt(skills, project_id)
      state = put_in(state.skills[project_id], Distiller.proposed(skills))
      save_skills(state, project_id)
      server = self()

      state
      |> update_in([:stats, "proposerCalls"], &(&1 + 1))
      |> spawn_task(project_id, :proposer, fn ->
        result =
          try do
            Host.generate(@id, prompt, %{"payload" => "string"})
          rescue
            e -> {:error, Exception.message(e)}
          catch
            kind, reason -> {:error, Exception.format_banner(kind, reason)}
          end

        send(server, {:proposed, project_id, result})
      end)
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

  @doc """
  Whether a turn the plugin closes feeds its project's envelope: heard whole, and ended
  green (`Turn.resolved_proxy/2`).
  """
  def learns?(turn, stopped_normally),
    do: not turn.partial and Turn.resolved_proxy(turn.guard, stopped_normally)

  defp fold(state, thread_id, turn, {name, args, result, code}, started) do
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
        now: System.monotonic_time(:second),
        started: started
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
      # it refuses once the run is over, or while it works if it cannot take a message,
      # and does not say so of one its runtime still held unanswered.
      state =
        deliver(state, thread_id, run_id, entry, fn ->
          steered = Host.steer(@id, thread_id, run_id, body)

          if confirmed?(steered),
            do:
              Host.notice(
                @id,
                thread_id,
                run_id,
                "TokenEconomizer nudged this turn (#{short}): the same failure kept recurring.",
                title: "Loop guard"
              )

          steered
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
    # The guard decides nothing more in the turn, so a judge job still out is a paid
    # answer no one reads.
    state = state |> update_in([:stats, "aborts"], &(&1 + 1)) |> cancel_judge(thread_id)
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

  # Whether a delivery reached its turn: a steer whose runtime still held it unanswered
  # (`Host.steer/4`'s `"confirmed"`) has not, as far as anyone knows.
  defp confirmed?({:ok, %{"confirmed" => false}}), do: false
  defp confirmed?({:ok, _}), do: true
  defp confirmed?(_), do: false

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

  # --- settings and the envelope's files ----------------------------------------------

  # The micro-skills' mode: `envfacts` learns the free environment facts, `on`
  # adds the paid proposer's. The host checks a save against plugin.json's
  # choices but not a stored value (a settings file edited by hand): anything
  # else is off.
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

    [
      max_facts: cap.("microSkillsMaxFacts"),
      max_tokens: cap.("microSkillsMaxTokens"),
      proposing: micro_mode(state) == "on"
    ]
  end

  # Turns between proposals, upstream's `every` (3): the first after a project's
  # second turn.
  defp propose_every(state) do
    case state.settings["microSkillsProposeEvery"] do
      value when is_number(value) and value >= 1 -> trunc(value)
      _ -> 3
    end
  end

  # A held project's file is read again at each use, so it is learned from
  # again once it reads.
  defp skills_for(state, project_id) do
    case state.skills[project_id] do
      skills when skills == nil or skills.held != nil ->
        load_skills(state, project_id)

      skills ->
        {skills, state}
    end
  end

  defp load_skills(state, project_id) do
    case read_skills(project_id, skills_caps(state)) do
      {:error, reason} ->
        if state.skills[project_id] == nil,
          do:
            Logger.warning(
              "token-economizer: the micro-skills of project #{project_id} are held: " <>
                "#{micro_skills_path(project_id)} #{reason}"
            )

        skills = %{EnvFacts.new(skills_caps(state)) | held: "Its saved file #{reason}."}
        {skills, put_in(state.skills[project_id], skills)}

      {saved, skills} ->
        state = put_in(state.skills[project_id], skills)

        # A fold saved running while the import is now off (turned off
        # while the MC was down) stops as it would have, folding what it held.
        state =
          case History.load(saved["history"]) do
            nil ->
              state

            fold ->
              stopped =
                if history_on?(state),
                  do: fold,
                  else: History.stop(fold, "the history import was turned off")

              state = put_in(state.folds[project_id], stopped)
              if stopped != fold, do: save_skills(state, project_id)
              state
          end

        # A fact the load left out for holding a credential leaves the file
        # too, and the log says so by family: an id can hold the credential.
        with %{"facts" => %{} = facts} <- saved,
             [_ | _] = gone <- Map.keys(facts) -- Map.keys(skills.facts) do
          families =
            gone |> Enum.map(&(get_in(facts, [&1, "family"]) || "?")) |> Enum.frequencies()

          Logger.warning(
            "token-economizer: dropped #{length(gone)} saved micro-skill fact(s) of " <>
              "project #{project_id} that hold a credential: #{inspect(families)}"
          )

          save_skills(state, project_id)
        end

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

  # `{saved, skills}`, the file and the state it loads (none at all when there is
  # no file), or `{:error, reason}` when there is one and it does not read: then
  # the project is held, never started afresh over what it had learned.
  defp read_skills(project_id, caps) do
    case File.read(micro_skills_path(project_id)) do
      {:error, :enoent} ->
        {%{}, EnvFacts.new(caps)}

      {:error, reason} ->
        {:error, "could not be read (#{:file.format_error(reason)})"}

      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, %{} = saved} -> {saved, EnvFacts.load(saved, caps)}
          {:ok, _} -> {:error, "is not a JSON object"}
          {:error, _} -> {:error, "is not valid JSON"}
        end
    end
  rescue
    e -> {:error, "could not be loaded (#{Exception.message(e)})"}
  end

  # As `save_tracker/2`: a failed write costs persistence, never the plugin.
  # Callers that answer a person (drop, restore, forget) report the failure; a
  # turn's fold keeps what it learned in memory. The project's fold from
  # history is kept in the same file, so a page folded and the place reached
  # after it are saved in one write.
  defp save_skills(state, project_id) do
    path = micro_skills_path(project_id)
    tmp = path <> ".tmp"

    saved =
      state.skills[project_id]
      |> EnvFacts.dump()
      |> Map.merge(%{"projectId" => project_id, "history" => state.folds[project_id]})
      |> Map.reject(fn {_k, v} -> v == nil end)

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

  # What the `microSkills` call answers: one project's facts when it is named,
  # else every project's, each an `entry/2`.
  defp micro_skills_view(state, nil) do
    {known, state} = known_skills(state)
    ids = known |> MapSet.union(MapSet.new(Map.keys(state.skills))) |> Enum.sort()

    {projects, state} =
      Enum.map_reduce(ids, state, fn project_id, state ->
        {_skills, state} = skills_for(state, project_id)
        {entry(state, project_id), state}
      end)

    {%{"mode" => micro_mode(state), "projects" => projects}, state}
  end

  defp micro_skills_view(state, project_id) do
    {_skills, state} = skills_for(state, project_id)

    {%{"mode" => micro_mode(state), "projects" => [entry(state, project_id)]}, state}
  end

  defp entry(state, project_id) do
    %{"projectId" => project_id, "history" => History.view(state.folds[project_id])}
    |> Map.merge(EnvFacts.view(state.skills[project_id]))
  end

  # Publishes a project's entry on its own topic, `microSkills:<project id>`,
  # when what a person would see in it changed: a turn that taught nothing new
  # only moves a turn count. One project's turn never rebuilds or resends the
  # others'; the whole listing is the `microSkills` call's.
  defp publish_skills(state, project_id) do
    entry = entry(state, project_id)
    shape = Map.delete(entry, "turns")

    if state.published_skills[project_id] == shape do
      state
    else
      Host.publish(@id, "#{@skills_topic}:#{project_id}", entry)
      put_in(state.published_skills[project_id], shape)
    end
  end

  # New caps change what each loaded project stages; one never loaded has
  # published nothing since the plugin started.
  defp publish_loaded_skills(state),
    do: state.skills |> Map.keys() |> Enum.reduce(state, &publish_skills(&2, &1))

  defp drop_or_restore(state, input, action) do
    with %{"projectId" => project_id, "id" => id} when is_binary(project_id) and is_binary(id) <-
           input || %{} do
      {skills, state} = skills_for(state, project_id)

      result =
        cond do
          skills.held != nil ->
            {:error, "The micro-skills of this project are held: #{skills.held}"}

          action == :drop ->
            EnvFacts.drop(skills, id)

          true ->
            EnvFacts.restore(skills, id)
        end

      case result do
        {:ok, skills} ->
          kept = put_in(state.skills[project_id], skills)

          case save_skills(kept, project_id) do
            :ok ->
              state =
                kept
                |> know_skill(project_id)
                |> publish_skills(project_id)

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
        saved = read_tracker(project)
        tracker = Envelope.new(level(state), thresholds(state), saved)

        # What a fold from history seeded it with (`History.seed/4`).
        tracker =
          case History.load_seed(saved["seed"]) do
            nil -> tracker
            seed -> Map.put(tracker, :seed, seed)
          end

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
    saved =
      tracker
      |> Envelope.dump()
      |> Map.merge(%{"projectId" => project_id, "provider" => provider, "seed" => tracker[:seed]})
      |> Map.reject(fn {_k, v} -> v == nil end)

    save_json(envelope_path(project), saved)
  end

  # A write that fails (a full disk, a data directory gone read-only) costs what it would
  # have saved, which the state in memory still holds: never the plugin and every turn
  # it is guarding.
  defp save_json(path, saved) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, JSON.encode!(saved)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("token-economizer: #{path} not saved: #{inspect(reason)}")
        :error
    end
  end

  # --- the first fold from history ----------------------------------------------------

  defp history_on?(state), do: state.settings["historyImport"] == true

  defp setting(state, key, default) do
    case state.settings[key] do
      value when is_number(value) and value >= 1 -> trunc(value)
      _ -> default
    end
  end

  # The turns of a thread read at once, and the held-back live turns.
  @history_page 20
  @pending_page 50

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # A turn starting in a project with learning and the import on starts its
  # fold, once: a project that already learned from its turns is skipped, and
  # one stopped resumes. Then the next read, if none is under way.
  defp start_fold(state, project_id) do
    if micro_on?(state) and history_on?(state) and is_binary(project_id) do
      {skills, state} = skills_for(state, project_id)

      case state.folds[project_id] do
        # A held project's file does not read: nothing is folded until it does.
        _fold when skills.held != nil ->
          state

        nil ->
          fold =
            if skills.now > 0 or skills.folded != [] or skills.facts != %{},
              do: History.skipped("the project had already learned from its turns", now()),
              else: History.new(fold_id(), now())

          put_fold(state, project_id, fold)

        %{"state" => "stopped"} = fold ->
          put_fold(state, project_id, History.resume(fold))

        _fold ->
          state
      end
      |> pump()
    else
      state
    end
  end

  defp fold_id, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # Keeps a project's fold, with its micro-skills, and publishes its entry.
  defp put_fold(state, project_id, fold) do
    state = put_in(state.folds[project_id], fold)
    save_skills(state, project_id)
    state |> know_skill(project_id) |> publish_skills(project_id)
  end

  defp each_fold(state, fun) do
    Enum.reduce(state.folds, state, fn {project_id, fold}, state ->
      case fun.(fold) do
        ^fold -> state
        changed -> put_fold(state, project_id, changed)
      end
    end)
  end

  # Starts the next read of a running fold, one at a time across projects,
  # while learning is on: off, a fold waits where it is.
  defp pump(%{reading: nil} = state) do
    if micro_on?(state) do
      Enum.find_value(state.folds, state, fn {project_id, fold} ->
        case History.next(fold) do
          nil -> nil
          :finish -> state |> put_fold(project_id, History.finish(fold, now())) |> pump()
          what -> read(state, project_id, fold, what)
        end
      end)
    else
      state
    end
  end

  defp pump(state), do: state

  # Reads what a fold reads next in a task, so a long read never holds up
  # the turns this process hears; its answer comes as `{:history, ...}`.
  defp read(state, project_id, fold, what) do
    server = self()
    step = fold["step"]
    days = setting(state, "historyDays", 365)
    most = setting(state, "historyMaxThreads", 200)
    {level, thr} = {level(state), thresholds(state)}

    work = fn ->
      result =
        try do
          case what do
            {:pending, entries} -> read_pending(entries, fold)
            what -> read_history(project_id, what, days, most, level, thr)
          end
        rescue
          e -> {:error, what, Exception.message(e)}
        end

      send(server, {:history, project_id, fold["id"], step, result})
    end

    {:ok, pid} = Task.Supervisor.start_child(state.sup, work)
    Process.monitor(pid)
    %{state | reading: %{pid: pid, project: project_id, fold: fold["id"], step: step, what: what}}
  end

  defp read_history(project_id, :plan, days, most, _level, _thr) do
    case Host.project_threads(@id, project_id) do
      {:ok, threads} ->
        {ids, skipped} = History.plan(threads, DateTime.utc_now(), days, most)
        {:plan, ids, skipped}

      {:error, reason} ->
        {:error, :plan, reason}
    end
  end

  defp read_history(_project_id, {:page, thread_id, after_run} = what, _days, _most, level, thr) do
    case Host.history(@id, thread_id, after: after_run, limit: @history_page) do
      {:ok, turns} ->
        entries =
          for turn <- turns do
            calls = turn["items"] |> Enum.map(&call_of/1) |> Enum.reject(&is_nil/1)

            %{
              "run" => turn["runId"],
              "endedAt" => turn["completedAt"] || turn["startedAt"],
              "provider" => turn["provider"] || turn["instanceId"],
              "calls" => calls,
              "sample" => History.replay(calls, turn["status"], level, thr)
            }
          end

        {:page, entries, length(turns) == @history_page}

      {:error, reason} ->
        {:error, what, reason}
    end
  end

  # The held-back live turns, read back from their threads (`History.held_turns/6`).
  defp read_pending(entries, fold) do
    read =
      entries
      |> Enum.group_by(&hd/1, &Enum.at(&1, 1))
      |> Map.new(fn {thread_id, runs} ->
        page = &Host.history(@id, thread_id, before: &1, limit: @pending_page)
        {thread_id, History.held_turns(MapSet.new(runs), fold, @pending_page, page)}
      end)

    {:pending,
     Enum.map(entries, fn [thread_id, run_id, _ids] ->
       case read[thread_id][run_id] do
         nil -> nil
         turn -> turn["items"] |> Enum.map(&call_of/1) |> Enum.reject(&is_nil/1)
       end
     end)}
  end

  # Applies a read to the fold that asked it, if it still awaits it: one
  # forgotten, moved past, or answered with learning off is not applied, and
  # read again when it is next.
  defp fold_history(state, project_id, fold_id, step, result) do
    fold = state.folds[project_id]

    if micro_on?(state) and History.running?(fold) and fold["id"] == fold_id and
         fold["step"] == step do
      applied(state, project_id, fold, result)
    else
      state
    end
  end

  defp applied(state, project_id, fold, {:plan, ids, skipped}),
    do: put_fold(state, project_id, History.planned(fold, ids, skipped))

  # A page of a thread's turns: those that ended before the fold started and
  # that no live turn holds (`History.held/1`) or still runs fold oldest first,
  # each once by its run id, and seed the envelope.
  defp applied(state, project_id, fold, {:page, entries, more}) do
    {skills, state} = skills_for(state, project_id)
    held = History.held(fold)
    live = MapSet.new(Map.values(state.turns), & &1.run)

    kept =
      Enum.filter(entries, fn entry ->
        entry["run"] not in held and entry["run"] not in live and
          History.imported?(fold, entry["endedAt"])
      end)

    folded = Enum.count(kept, &(&1["run"] not in skills.folded))
    skills = Enum.reduce(kept, skills, &EnvFacts.update_turn(&2, &1["calls"], &1["run"]))
    state = put_in(state.skills[project_id], skills)
    {fold, state} = seed_envelopes(state, project_id, fold, kept)
    last = List.last(entries)

    put_fold(state, project_id, History.paged(fold, folded, last && last["run"], more))
  end

  # The live turns held back, in the order they ended, each read back whole
  # from its thread; one that cannot be is counted.
  defp applied(state, project_id, %{"pending" => pending} = fold, {:pending, calls}) do
    {skills, state} = skills_for(state, project_id)
    entries = Enum.take(pending, length(calls))

    {skills, folded} =
      entries
      |> Enum.zip(calls)
      |> Enum.reduce({skills, 0}, fn
        {_entry, nil}, acc ->
          acc

        {[_thread, run, ids], calls}, {skills, n} ->
          {skills |> EnvFacts.seed_injected(ids) |> EnvFacts.update_turn(calls, run), n + 1}
      end)

    state = put_in(state.skills[project_id], skills)
    put_fold(state, project_id, History.drained(fold, entries, folded))
  end

  # The threads could not be listed: the fold stops, to resume when the
  # import is turned on again.
  defp applied(state, project_id, fold, {:error, :plan, reason}) do
    Logger.warning(
      "token-economizer: project #{project_id}'s threads not listed: #{inspect(reason)}"
    )

    put_fold(state, project_id, History.stop(fold, "the project's threads could not be listed"))
  end

  defp applied(state, project_id, fold, {:error, {:page, thread_id, _after}, reason}) do
    Logger.warning("token-economizer: thread #{thread_id} not read: #{inspect(reason)}")
    put_fold(state, project_id, History.unreadable(fold))
  end

  defp applied(state, project_id, fold, {:error, {:pending, entries}, _reason}),
    do: put_fold(state, project_id, History.drained(fold, entries, 0))

  # Seeds each provider's envelope with the page's green turns, where the
  # fold may (`History.seedable/2`); the tracker is saved before the fold
  # moves past the page, and `History.seed/4` seeds a step once.
  defp seed_envelopes(state, project_id, fold, kept) do
    kept
    |> Enum.filter(&(is_binary(&1["provider"]) and &1["sample"] != nil))
    |> Enum.group_by(& &1["provider"], & &1["sample"])
    |> Enum.reduce({fold, state}, fn {provider, samples}, {fold, state} ->
      key = {project_id, provider}
      {tracker, state} = tracker(state, key)

      entry = fold["envelopes"][provider]

      {outcome, state} =
        case History.envelope(entry, on?(state), tracker, fold["id"]) do
          :seed ->
            tracker = History.seed(tracker, fold["id"], fold["step"], samples)
            save_tracker(key, tracker)
            {{:seeded, tracker.seed["n"]}, put_in(state.trackers[key], tracker)}

          outcome ->
            {outcome, state}
        end

      {put_in(fold, ["envelopes", provider], History.noted(entry, on?(state), outcome)), state}
    end)
  end

  # Forgets what a project learned: its facts (a dropped fact stays dropped),
  # its fold from history, and the envelope samples that fold seeded. With
  # learning and the import on, the fold runs again.
  defp forget(state, input) do
    case project_id(input) do
      nil ->
        {:reply, {:error, "Give a projectId."}, state}

      project_id ->
        case skills_for(state, project_id) do
          {%EnvFacts{held: held}, state} when held != nil ->
            {:reply, {:error, "The micro-skills of this project are held: #{held}"}, state}

          {skills, state} ->
            forget(state, project_id, skills)
        end
    end
  end

  defp forget(state, project_id, skills) do
    fold = state.folds[project_id]
    fresh = %{EnvFacts.new(skills_caps(state)) | dropped: skills.dropped}

    again =
      if micro_on?(state) and history_on?(state), do: History.new(fold_id(), now())

    kept = %{
      put_in(state.skills[project_id], fresh)
      | folds:
          if(again,
            do: Map.put(state.folds, project_id, again),
            else: Map.delete(state.folds, project_id)
          )
    }

    case save_skills(kept, project_id) do
      :ok ->
        state =
          kept
          |> stop_reading(project_id)
          |> unseed(project_id, fold)
          |> know_skill(project_id)
          |> publish_skills(project_id)
          |> pump()

        {view, state} = micro_skills_view(state, project_id)
        {:reply, {:ok, view}, state}

      :error ->
        {:reply, {:error, "That could not be saved, so nothing was forgotten."}, state}
    end
  end

  defp stop_reading(%{reading: %{project: project_id, pid: pid}} = state, project_id) do
    Task.Supervisor.terminate_child(state.sup, pid)
    %{state | reading: nil}
  end

  defp stop_reading(state, _project_id), do: state

  defp unseed(state, _project_id, nil), do: state

  defp unseed(state, project_id, fold) do
    for({provider, %{"seeded" => _}} <- fold["envelopes"] || %{}, do: provider)
    |> Enum.reduce(state, fn provider, state ->
      key = {project_id, provider}
      {tracker, state} = tracker(state, key)
      tracker = History.unseed(tracker, fold["id"])
      save_tracker(key, tracker)
      put_in(state.trackers[key], tracker)
    end)
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
