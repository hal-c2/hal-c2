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
  steers the agent once with a redirect and says so in a notice; if the turn still looks
  stuck after that, a notice offers to stop it. The plugin never stops a turn itself:
  the person decides.

  What counts as stuck is learned per project and agent, from turns that ended green
  (`LoopGuard.Envelope`), kept in the plugin's data directory. Until a project has
  enough of them the guard watches and does nothing. The paid judge, the user's text
  generation model, runs only when the free gate opens, in a process of its own; its
  verdict is read at the turn's next call.

  A turn whose start the plugin missed is not watched. Missed events (`"dropped"`) mark
  the turns under way as partial, and the turns heard over the next full feed queue
  too, and a partial turn does not teach the envelope.

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
    {:ok,
     %{
       settings: settings,
       # thread id => %{run, project, guard, partial}, the turn under way
       turns: %{},
       # Events still to hear that the feed may have queued before ones it missed.
       missing: 0,
       # {project id, provider} => tracker
       trackers: %{},
       # {project id, provider} => tool pruning's evidence, loaded on first use
       prunes: %{},
       # thread id => %{project, loaded, used, prompts, active}, the conversation
       # tool pruning is hearing (a segment folds when it ends or goes idle)
       convs: %{},
       # thread id => the loaded set its next conversation was shaped with
       shaped: %{},
       # thread ids whose earlier turns were read back this run
       seeded: MapSet.new(),
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
    state = if on?(state), do: state, else: %{state | turns: %{}}
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

  def handle_call({:observe, event}, _from, state) do
    state = state |> missed_prune(event["dropped"]) |> hear_prune(event)

    state =
      if on?(state) do
        state |> missed(event["dropped"]) |> hear(event) |> suspect(event)
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

  def handle_info({:toolprune_tick, project}, state) do
    {:noreply,
     prune_tick(%{state | prune_timers: Map.delete(state.prune_timers, project)}, project)}
  end

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

  # A new conversation: apply whatever `auto` held once the quiet has passed, then
  # answer what it runs without, and remember what it had loaded for its evidence.
  defp shape(state, run) do
    unit = run["toolUnit"] || Prune.unit_for_provider(run["provider"])
    project = {run["projectId"], run["provider"]}

    if unit in ["tool", "capability"] and is_binary(run["projectId"]) and
         is_binary(run["provider"]) do
      cfg = prune_cfg(state)
      {prune, state} = prune(state, project, unit)
      {prune, applied} = Prune.apply_pending(prune, cfg, now_s(), active?(state, project))
      state = put_prune(state, project, prune, applied != [])
      denied = Prune.denied(prune, cfg)
      loaded = Prune.candidate_tools(unit) -- denied
      state = put_in(state.shaped[run["threadId"]], loaded)
      state = if applied != [], do: publish_prune(state), else: state
      {if(denied == [], do: nil, else: %{"deniedTools" => denied}), state}
    else
      {nil, state}
    end
  end

  defp prune_call(state, action, input) do
    cfg = prune_cfg(state)
    tools = if is_list(input["tools"]), do: Enum.filter(input["tools"], &is_binary/1)

    case prune_targets(state, input) do
      {:ok, [], state} when action != :state ->
        {{:error, "TokenEconomizer has no tool evidence for that project and provider."}, state}

      {:ok, targets, state} ->
        {results, state} =
          Enum.map_reduce(targets, state, fn project, acc ->
            prune = acc.prunes[project]

            {prune, changed, extra} =
              case action do
                :state ->
                  {prune, [], %{}}

                :apply ->
                  {next, applied, refused} = Prune.apply_named(prune, cfg, tools)
                  {next, applied, %{"applied" => applied, "refused" => refused}}

                :restore ->
                  {next, restored} = Prune.restore(prune, tools)
                  {next, restored, %{"restored" => restored}}
              end

            acc = put_prune(acc, project, prune, changed != [])
            {project_summary(project, prune, cfg, extra), acc}
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

  # The projects a `toolPrune` call names, loading a named one's file if need be.
  # Without a project the state call lists all held; apply and restore need one.
  defp prune_targets(state, %{"projectId" => project_id, "provider" => provider})
       when is_binary(project_id) and is_binary(provider) do
    case Prune.unit_for_provider(provider) do
      nil ->
        {:ok, [], state}

      unit ->
        {_prune, state} = prune(state, {project_id, provider}, unit)
        {:ok, [{project_id, provider}], state}
    end
  end

  defp prune_targets(state, %{"projectId" => project_id}) when is_binary(project_id) do
    {:ok, for({id, _} = project <- Map.keys(state.prunes), id == project_id, do: project), state}
  end

  defp prune_targets(state, _input), do: {:ok, Map.keys(state.prunes), state}

  # Events the feed missed taint the conversations under way, as they mark the loop
  # guard's turns partial: what was used in them still counts, but nothing in them
  # may grow an unused streak -- a missed item may be the very use that would have
  # reset it. They also stop counting as active, since a missed turn end would
  # otherwise hold a project active (and `auto` stalled) until its next turn.
  defp missed_prune(state, n) when is_integer(n) and n > 0 do
    %{
      state
      | convs:
          Map.new(state.convs, fn {id, conv} -> {id, %{conv | partial: true, active: false}} end)
    }
  end

  defp missed_prune(state, _), do: state

  # The turns as tool pruning hears them, whatever the loop guard's mode: a new
  # conversation closes the thread's last one, a turn's items say what it used, and
  # a finished turn leaves the project idle for the quiet timer to fold.
  defp hear_prune(
         state,
         %{"type" => "turn.started", "threadId" => thread_id} = event
       ) do
    unit = Prune.unit_for_provider(event["provider"])
    project = {event["projectId"], event["provider"]}

    if unit == nil or not is_binary(event["projectId"]) do
      state
    else
      state = seed_history(state, thread_id, project, unit, event["instanceId"])
      {prune, state} = prune(state, project, unit)
      state = touch(state, project, prune)

      if event["newConversation"] do
        state = close_conv(state, thread_id)
        loaded = state.shaped[thread_id] || default_loaded(state, project, unit)

        put_in(state.convs[thread_id], %{
          project: project,
          loaded: loaded,
          used: [],
          prompts: 1,
          active: true,
          partial: false
        })
      else
        case state.convs[thread_id] do
          nil ->
            put_in(state.convs[thread_id], %{
              project: project,
              loaded: default_loaded(state, project, unit),
              used: [],
              prompts: 1,
              active: true,
              partial: false
            })

          conv ->
            put_in(state.convs[thread_id], %{conv | prompts: conv.prompts + 1, active: true})
        end
      end
    end
  end

  defp hear_prune(state, %{"type" => "turn.item", "threadId" => thread_id} = item) do
    case state.convs[thread_id] do
      nil ->
        state

      conv ->
        unit = Prune.unit_for_provider(elem(conv.project, 1))
        used = Prune.used_in_item(item, unit)
        conv = %{conv | used: Enum.uniq(conv.used ++ used)}
        state = put_in(state.convs[thread_id], conv)
        {prune, state} = prune(state, conv.project, unit)
        state = touch(state, conv.project, prune)
        # A use protects its tool at once, not only when the segment folds.
        noted = Prune.note_used(state.prunes[conv.project], used, prune_cfg(state))

        if noted != state.prunes[conv.project] do
          state |> put_prune(conv.project, noted, true) |> publish_prune()
        else
          state
        end
    end
  end

  defp hear_prune(state, %{"type" => "turn.finished", "threadId" => thread_id} = event) do
    case state.convs[thread_id] do
      nil ->
        state

      conv ->
        state = put_in(state.convs[thread_id].active, false)
        unit = Prune.unit_for_provider(elem(conv.project, 1))
        {prune, state} = prune(state, conv.project, unit)
        prune = Prune.note_thread(prune, thread_id, event["runId"])
        state = put_in(state.prunes[conv.project], prune)

        state =
          state |> touch(conv.project, state.prunes[conv.project]) |> save_prune(conv.project)

        schedule_tick(state, conv.project)
    end
  end

  defp hear_prune(state, _event), do: state

  defp default_loaded(state, project, unit) do
    {prune, _state} = prune(state, project, unit)
    Prune.candidate_tools(unit) -- Prune.denied(prune, prune_cfg(state))
  end

  # Folds the thread's open conversation, if any, and forgets it.
  defp close_conv(state, thread_id) do
    case Map.pop(state.convs, thread_id) do
      {nil, _} -> state
      {conv, convs} -> fold_conv(%{state | convs: convs}, conv)
    end
  end

  defp fold_conv(state, conv, imported \\ false) do
    unit = Prune.unit_for_provider(elem(conv.project, 1))
    {prune, state} = prune(state, conv.project, unit)
    # A segment heard only in part (`missed_prune/2`) folds as no evidence: its
    # uses are still noted, its silences grow no streak.
    prompts = if Map.get(conv, :partial, false), do: 0, else: conv.prompts

    prune =
      Prune.fold_segment(prune, conv.loaded, conv.used, prompts, prune_cfg(state), now_s(),
        imported: imported
      )

    state
    |> put_prune(conv.project, prune, true)
    |> publish_prune()
    |> schedule_tick(conv.project)
  end

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
            if conv.project == project and (conv.prompts > 0 or conv.used != []) do
              acc
              |> fold_conv(conv)
              |> put_in([:convs, thread_id], %{
                conv
                | used: [],
                  prompts: 0,
                  active: false,
                  partial: false
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
  # their prompts as evidence `auto` alone does not act on. Only this instance's
  # runs count (a thread's earlier runs on another provider are that provider's
  # evidence), and only those after the last run already folded for the thread
  # (`Prune.note_thread/3`'s watermark, advanced by every live turn's end), so a
  # restart never folds a turn twice.
  defp seed_history(state, thread_id, project, unit, instance) do
    if MapSet.member?(state.seeded, thread_id) do
      state
    else
      state = update_in(state.seeded, &MapSet.put(&1, thread_id))

      {prune, state} = prune(state, project, unit)
      watermark = Prune.seeded_run(prune, thread_id)

      runs =
        thread_id
        |> history()
        |> Enum.filter(&(instance == nil or &1["instanceId"] in [nil, instance]))
        |> after_watermark(watermark)

      case runs do
        [] ->
          state

        runs ->
          state =
            put_in(
              state.prunes[project],
              Prune.note_thread(
                state.prunes[project],
                thread_id,
                runs |> List.last() |> Map.get("runId")
              )
            )

          used =
            runs
            |> Enum.flat_map(& &1["items"])
            |> Enum.flat_map(&Prune.used_in_item(&1, unit))
            |> Enum.uniq()

          fold_conv(
            state,
            %{
              project: project,
              loaded: Prune.candidate_tools(unit),
              used: used,
              prompts: length(runs)
            },
            true
          )
      end
    end
  end

  # The runs after the thread's watermark. A watermark no longer in the window
  # read back is older than all of it (it names the last run folded), so the
  # whole window is new.
  defp after_watermark(runs, nil), do: runs

  defp after_watermark(runs, watermark) do
    case Enum.find_index(runs, &(&1["runId"] == watermark)) do
      nil -> runs
      index -> Enum.drop(runs, index + 1)
    end
  end

  defp history(thread_id) do
    case Host.history(@id, thread_id, limit: 50) do
      {:ok, runs} when is_list(runs) -> runs
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
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

  # The feed says what it missed on the next event it delivers, which it queued before
  # the missed ones: up to a full queue of events still to come were too, and a turn
  # that starts in them may have lost what was missed. So the turns under way are
  # partial, and so is each turn heard until that queue has been heard.
  defp missed(state, n) when is_integer(n) and n > 0 do
    turns = Map.new(state.turns, fn {id, turn} -> {id, %{turn | partial: true}} end)
    %{state | turns: turns, missing: HalC2.Plugins.Feed.max_queue()}
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

  defp hear(state, %{"type" => "turn.item", "threadId" => thread_id, "runId" => run_id} = item) do
    case {state.turns[thread_id], call_of(item)} do
      {%{run: ^run_id} = turn, {name, args, result, code}} ->
        fold(state, thread_id, turn, name, args, result, code)

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
    end
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
