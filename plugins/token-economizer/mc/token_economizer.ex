# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/plugin/controller.py and tokeneconomizer/plugin/hosts.py
# (microsoft/TokenEconomizer@cb42207e3e09), into Elixir for HAL-C2's MC. Changed: the
# guard hears the MC's turns (`observe/2`) instead of an agent's hooks, steers a turn
# through the MC instead of answering a hook, and keeps its state in one process.
# Tool pruning is ported in `tool_prune_evidence.ex`; here it is fed the same turns
# and shapes each new provider conversation (`shape_run/2`).

defmodule HalC2Plugins.TokenEconomizer do
  @moduledoc """
  TokenEconomizer's MC part: the loop guard and tool pruning.

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

  A turn whose start the plugin missed is not watched. Missed events (`"dropped"`) mark
  the turns under way as partial, and the turns heard until the events that were still
  waiting (`"waiting"`) have been, and a partial turn does not teach the envelope. A
  restarted process takes everything its feed still holds as such events.

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
  alias HalC2Plugins.TokenEconomizer.ToolPrune.Evidence, as: Prune

  @id "token-economizer"
  @topic "loopGuard"
  @prune_topic "toolPrune"
  # The tool-pruning numbers a person may set, `{setting, least}`: whole numbers all.
  @prune_numbers %{
    "toolPruneEvidence" => 1,
    "toolPruneMinSessions" => 1,
    "toolPruneSessions" => 1,
    "toolPruneQuietMinutes" => 0
  }
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

    cond do
      not (is_number(nudges) and nudges >= 0 and nudges == trunc(nudges)) ->
        {:error, "loopGuardNudges: give a whole number, 0 or more."}

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

  def call("toolPrune", input, _context),
    do: GenServer.call(__MODULE__, {:toolprune, :state, input || %{}})

  def call("toolPruneApply", input, _context),
    do: GenServer.call(__MODULE__, {:toolprune, :apply, input || %{}})

  def call("toolPruneRestore", input, _context),
    do: GenServer.call(__MODULE__, {:toolprune, :restore, input || %{}})

  def call(method, _input, _context), do: {:error, "Unknown method #{method}."}

  @impl HalC2.Plugins.Extension
  # Asked as a provider conversation starts, and left out when it takes too long:
  # the tools a project's evidence turned off, for the whole conversation.
  def shape_run(run, _context) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:shape, run}, 250)
      catch
        :exit, _ -> nil
      end
    end
  end

  @impl HalC2.Plugins.Extension
  # The feed waits for each event, so a guard is never folded out of order and missed
  # events are counted where they were missed.
  def observe(event, _context), do: GenServer.call(__MODULE__, {:observe, event}, 15_000)

  # --- server ---------------------------------------------------------------------------

  @impl GenServer
  def init(settings) do
    {:ok, sup} = Task.Supervisor.start_link()

    {:ok,
     %{
       settings: settings,
       # The plugin's tasks, linked to it: `tasks` is pid => {thread id, :judge | :delivery}.
       sup: sup,
       tasks: %{},
       # thread id => %{run, project, guard, partial}, the turn under way
       turns: %{},
       # Events still to hear that the feed may have queued before ones it missed. A
       # process restarted while its feed ran cannot tell which those are, so it is all
       # the feed holds.
       missing: Host.feed_backlog(@id),
       # {project id, provider} => tracker
       trackers: %{},
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
       # {project id, provider} => the timer that folds its idle conversations
       prune_timers: %{},
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
    # The level and pinned thresholds shape each tracker: read them afresh. Tool
    # pruning reads its settings at each decision, so its evidence stays.
    state = %{state | settings: settings, trackers: %{}}

    # Off, the guard hears no turn and no judge job is read. A delivery under way runs on:
    # its steer may already have been taken, and its answer says what happened. Watching
    # only starts none (`act/5`).
    state =
      if on?(state),
        do: state,
        else: %{cancel(state, &match?({_, :judge}, &1)) | turns: %{}}

    {:reply, :ok, state |> publish() |> publish_prune()}
  end

  def handle_call(:status, _from, state), do: {:reply, status(state), state}

  def handle_call({:shape, run}, _from, state) do
    {shape, state} = shape(state, run)
    {:reply, shape, state}
  end

  def handle_call({:toolprune, action, input}, _from, state) do
    {reply, state} = prune_call(state, action, input)
    {:reply, reply, state}
  end

  # Off, the guard hears no turn, but the window a report of missed events opens still
  # runs over the events heard, so a turn that starts in it once on again is partial;
  # tool pruning hears every turn whatever the guard's mode.
  def handle_call({:observe, event}, _from, state) do
    state = state |> missed(event) |> hear_prune(event)
    state = if on?(state), do: hear(state, event), else: state
    {:reply, :ok, suspect(state, event)}
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
          # The calls the agent had under way then may still be heard (`Turn.fold/6`).
          since = with {:ok, %{"ordinal" => last}} <- result, do: last, else: (_ -> nil)
          put_in(state.turns[thread_id].guard, Turn.redirected(guard, landed, since))

        _ ->
          state
      end

    {:noreply, state |> remember(Map.put(entry, "delivered", landed)) |> publish()}
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
      "projects" =>
        state.prunes
        |> Enum.sort()
        |> Enum.map(fn {{project_id, provider}, prune} ->
          Map.merge(Prune.summary(prune, cfg), %{
            "projectId" => project_id,
            "provider" => provider
          })
        end)
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
  defp shape(state, run) do
    unit = run["toolUnit"] || Prune.unit_for_provider(run["provider"])
    project = {run["projectId"], run["provider"]}

    if unit in ["tool", "capability"] and is_binary(run["projectId"]) and
         is_binary(run["provider"]) do
      cfg = prune_cfg(state)
      state = seed_history(state, run["threadId"], run["runId"], project, unit)
      {prune, state} = prune(state, project, unit)

      {prune, denied, state} =
        case recover_uses(prune, state, project, unit, run) do
          {:ok, prune, recovered} ->
            {prune, _} = Prune.apply_pending(prune, cfg, now_s(), active?(state, project))

            {prune, Prune.denied(prune, cfg),
             update_in(state.unresolved, &Map.drop(&1, recovered))}

          :error ->
            {prune, [], state}
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
            {project_summary(project, next, cfg, extra), acc}
          end)

        state = if action == :state, do: state, else: publish_prune(state)
        {{:ok, %{"mode" => cfg["mode"], "projects" => results}}, state}
    end
  end

  defp project_summary({project_id, provider}, prune, cfg, extra) do
    Prune.summary(prune, cfg)
    |> Map.merge(%{"projectId" => project_id, "provider" => provider})
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

    if unit == nil or not is_binary(event["projectId"]) do
      state
    else
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
        with project_id when is_binary(project_id) <- item["projectId"],
             true <- is_binary(provider),
             unit when unit != nil <- Prune.unit_for_provider(provider) do
          project = {project_id, provider}
          {_prune, state} = prune(state, project, unit)
          note_used(state, project, Prune.used_in_item(item, unit))
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

    runs =
      if partial?, do: [], else: Enum.reject(conv.runs, &Prune.folded?(prune, conv.thread, &1))

    # Its runs stay to read back, for every conversation the project shapes, until they
    # are; read back now, so are the thread's that folded so before them.
    state =
      cond do
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
    with {:ok, history} <- history(conv.thread, before),
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
      _ -> conv
    end
  end

  # The uses of the project's segments heard in part (`missed/2`) that the feed may
  # have dropped, read back from their threads' histories and noted (`Prune.note_used/3`)
  # before a conversation is shaped: those under way, which still fold as they end,
  # their runs read back then as they are now, and those that folded unresolved, which
  # are then resolved. `:error` while a history cannot be read, or does not have all of
  # a segment's runs yet: a run still going (the history has only those that ended)
  # may have used any tool. A run that ended and is not there was rolled back.
  defp recover_uses(prune, state, project, unit, run) do
    open =
      for {thread_id, %{project: ^project, partial: true} = conv} <- state.convs,
          do: {thread_id, conv.runs}

    folded = for {{thread_id, ^project}, marks} <- state.unresolved, do: {thread_id, marks}

    (open ++ folded)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce_while({:ok, prune, []}, fn {thread_id, marks}, {:ok, acc, recovered} ->
      before = if thread_id == run["threadId"], do: run["runId"]
      marks = marks |> Enum.concat() |> Enum.reject(&(&1["run"] == run["runId"]))

      with {:ok, history} <- history(thread_id, before),
           read = MapSet.new(history, & &1["runId"]),
           true <-
             Enum.all?(
               marks,
               &(&1["run"] in read or &1["ordinal"] != nil or Prune.folded?(acc, thread_id, &1))
             ) do
        {_, runs} = unfolded(acc, history, thread_id, project, before)
        used = Enum.flat_map(runs, &uses(&1, unit))
        noted = Prune.note_used(acc, used, prune_cfg(state))
        {:cont, {:ok, noted, [{thread_id, project} | recovered]}}
      else
        _ -> {:halt, :error}
      end
    end)
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

          :error ->
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

  # The 50 runs that ended before `run_id` started, however late the feed tells of it
  # (the last 50 to end with no `run_id`).
  # Each names the driver it ran on, which is what a project's evidence is kept by, even
  # once its instance is deleted. `:error` when they could not be read.
  defp history(thread_id, run_id) do
    case Host.history(@id, thread_id, limit: 50, before: run_id) do
      {:ok, runs} when is_list(runs) -> {:ok, runs}
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
    project = {event["projectId"], event["provider"] || event["instanceId"]}

    turn = %{
      run: run_id,
      project: project,
      guard: Turn.new("#{thread_id}:#{run_id}"),
      partial: false
    }

    # A turn under way whose end was missed did not end normally.
    state |> close(thread_id, false) |> put_in([:turns, thread_id], turn)
  end

  # A subagent's call is not the turn's own: the loop guard watches the agent's loop.
  defp hear(state, %{"type" => "turn.item", "subagent" => true}), do: state

  defp hear(state, %{"type" => "turn.item", "threadId" => thread_id, "runId" => run_id} = item) do
    case {state.turns[thread_id], call_of(item)} do
      {%{run: ^run_id} = turn, {name, args, result, code}} ->
        fold(state, thread_id, turn, {name, args, result, code}, item["ordinal"])

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
        state = cancel_judge(%{state | turns: turns}, thread_id)
        state = update_in(state.stats["turns"], &(&1 + 1))
        summary = Turn.summary(turn.guard, stopped_normally)

        Logger.debug(
          "token-economizer: turn #{inspect(Map.put(summary, "partial", turn.partial))}"
        )

        if learns?(turn, stopped_normally) do
          {tracker, state} = tracker(state, turn.project)
          tracker = Envelope.record_turn(tracker, turn.guard, stopped_normally)
          save_tracker(turn.project, tracker)
          publish(put_in(state.trackers[turn.project], tracker))
        else
          publish(state)
        end
    end
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
    saved =
      Map.merge(Envelope.dump(tracker), %{"projectId" => project_id, "provider" => provider})

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
