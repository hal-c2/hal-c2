# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported in part from tokeneconomizer/toolprune/{tools.py,codex.py,stage.py},
# tokeneconomizer/plugin/{fold.py,adapter.py,denylist.py} (the decisions, not their
# settings-file writing) (microsoft/TokenEconomizer@cb42207e3e09), into Elixir for
# HAL-C2's MC. Changed: the evidence comes from turns the MC hears, not transcript
# files, and a decision takes effect through `shape_run/2` at the next provider
# conversation, so nothing is written into a provider's own settings.

defmodule HalC2Plugins.TokenEconomizer.ToolPrune.Evidence do
  @moduledoc """
  Tool pruning's evidence and decisions, per project and provider, as plain functions
  over one JSON-shaped state map (the plugin keeps one file of it per project and
  provider in its data directory).

  A conversation's loaded tools that go unused grow a streak, in conversations
  (sessions) and in the turns (prompts) those conversations ran; a use resets the
  streak and protects the tool for good. A tool is proposed once `enough_evidence?/4`
  holds — unused over `toolprune_evidence` prompts across at least
  `toolprune_min_sessions` sessions, or over `toolprune_sessions` sessions, three
  times as long for a high-risk tool (`NotebookEdit`, Codex's image/media package) —
  and a protected work-surface tool, a tool the person named in `toolprune_protect`,
  a tool ever seen in use, or one the person gave back with restore, never is.

  What a conversation had loaded is not in the MC's turn events, so the loaded set is
  derived, per provider, from what the MC can turn off (`candidate_tools/1`): for
  Codex that is exact, the three capability packages its runtime toggles; for Claude
  it is the known built-in tools outside the protected work surface and the
  interactive set (`INTERACTIVE_PROTECTED` upstream). A candidate a Claude build
  does not load counts as loaded-and-unused and may be turned off to no effect; a
  tool outside the list (an MCP tool, say) is never proposed until this list grows —
  upstream has the same limit without a probed catalog snapshot, where only deferred
  tools can be proposed. Providers the MC turns nothing off for get no proposals.

  Codex keeps upstream's controller shape: a package is first *demoted* — after its
  minimum loaded-but-unused exposures, at most two newly demoted per folded
  session — and proposed only once demoted and evidenced as above. A single use
  protects a package for good, stricter than upstream's recent-outcomes window.

  Modes: under `auto` a proposal is held pending and applied only once the
  project's conversations have been idle `toolprune_quiet_minutes` (or a day has
  passed since it formed), so a resumed conversation never has its tools changed
  under a warm prompt cache; under `propose` nothing is applied until the person
  applies it; under `off` the evidence still accrues and nothing is turned off.
  Evidence folded from a thread's earlier turns (`imported`) may form a proposal,
  but `auto` holds only what the turns heard live are enough evidence for on their
  own, as upstream does for sessions read from an agent's history.
  """

  # The work surface nothing prunes, upstream's `PROTECTED_TOOLS`, plus what a person
  # relies on interactively (`INTERACTIVE_PROTECTED`), which upstream's plugin adds.
  @protected MapSet.new(~w(
    bash view grep glob edit create str_replace read_bash stop_bash list_bash read_file
    shell apply_patch
    Bash Edit Write Read Grep Glob MultiEdit LS NotebookRead BashOutput KillShell KillBash
    AskUserQuestion EnterPlanMode ExitPlanMode TodoWrite
    TaskCreate TaskUpdate TaskGet TaskList TaskOutput TaskStop
    Agent Task Skill ToolSearch SlashCommand Monitor WebFetch WebSearch
  ))

  # Rarely used, but expensive to lose: three times the usual evidence.
  @high_risk MapSet.new(~w(NotebookEdit image_media))
  @high_risk_factor 3

  # What `shape_run/2` can turn off, by unit: Claude's known built-in tools outside
  # the protected sets, and Codex's live capability packages (upstream's
  # `CODEX_LIVE_CAPABILITIES`, the same three the MC's Codex runtime toggles).
  @candidates %{
    "tool" => ~w(NotebookEdit Workflow CronCreate CronDelete CronList ScheduleWakeup
                 EnterWorktree ExitWorktree),
    "capability" => ~w(collaboration goals image_media)
  }

  # Codex packages' minimum loaded-but-unused exposures before demotion, upstream's
  # `MIN_LOADED_EXPOSURES` for the live packages, and its per-session demotion cap.
  @min_exposures %{"collaboration" => 1, "goals" => 1, "image_media" => 3}
  @max_demotions 2

  # A pending `auto` list is applied after a day however busy the project stayed.
  @pending_max_s 24 * 3600

  # The capability a Codex item exercises, by its tool name (upstream's
  # `_ITEM_TYPES_BY_CAPABILITY`, for the live packages), or by its kind: the MC
  # records a subagent Codex spawned as a `subagent` item.
  @capability_of Map.merge(
                   Map.new(
                     ~w(spawn_agent send_input send_message followup_task resume_agent
                        wait_agent close_agent interrupt_agent list_agents collab_tool_call
                        subagent),
                     &{&1, "collaboration"}
                   ),
                   Map.merge(
                     Map.new(~w(create_goal get_goal update_goal), &{&1, "goals"}),
                     Map.new(
                       ~w(view_image image audio generated_image image_generation),
                       &{&1, "image_media"}
                     )
                   )
                 )

  # --- configuration ---------------------------------------------------------

  @doc """
  The tool-pruning settings in effect: upstream's numbers (10 prompts over at least
  2 sessions, or 5 sessions; a quiet hour) unless the person set others.
  """
  def config(settings) do
    %{
      "mode" => settings["toolPrune"] || "auto",
      "evidence" => trunc(settings["toolPruneEvidence"] || 10),
      "min_sessions" => trunc(settings["toolPruneMinSessions"] || 2),
      "sessions" => trunc(settings["toolPruneSessions"] || 5),
      "quiet_minutes" => trunc(settings["toolPruneQuietMinutes"] || 60),
      "protect" => List.wrap(settings["toolPruneProtect"] || [])
    }
  end

  @doc "The unit `shape_run/2` turns off for a provider driver, or nil for none."
  def unit_for_provider("claudeAgent"), do: "tool"
  def unit_for_provider("codex"), do: "capability"
  def unit_for_provider(_), do: nil

  @doc "The tools a conversation of `unit` is taken to have loaded, before any are off."
  def candidate_tools(unit), do: @candidates[unit] || []

  @doc "Whether nothing may propose `tool`: a protected name, or one the person protected by name or pattern."
  def protected?(tool, cfg) do
    MapSet.member?(@protected, tool) or
      Enum.any?(cfg["protect"], &matches?(tool, &1))
  end

  defp matches?(tool, pattern) do
    regex =
      pattern
      |> String.graphemes()
      |> Enum.map(fn
        "*" -> ".*"
        "?" -> "."
        char -> Regex.escape(char)
      end)
      |> Enum.join()

    Regex.match?(Regex.compile!("\\A" <> regex <> "\\z"), tool)
  end

  @doc "Whether `tool` needs three times the usual evidence."
  def high_risk?(tool), do: MapSet.member?(@high_risk, tool)

  @doc """
  Has a never-used tool gone unused long enough? Over `evidence` prompts spread
  across at least `min_sessions` sessions, or over `sessions` sessions however
  short; a high-risk tool needs three times the prompts and the sessions.
  """
  def enough_evidence?(sessions, prompts, cfg, high_risk \\ false) do
    k = if high_risk, do: @high_risk_factor, else: 1

    (sessions >= cfg["min_sessions"] and prompts >= cfg["evidence"] * k) or
      sessions >= cfg["sessions"] * k
  end

  # --- state -----------------------------------------------------------------

  @doc "A project's evidence for one provider unit, from what its JSON file had (`saved`)."
  def new(unit, saved \\ %{}) do
    %{
      "unit" => unit,
      "used" => strings(saved["used"]),
      "kept" => strings(saved["kept"]),
      "off" => strings(saved["off"]),
      "demoted" => strings(saved["demoted"]),
      "streaks" => streaks(saved["streaks"]),
      "liveStreaks" => streaks(saved["liveStreaks"]),
      "loadedSessions" => counts(saved["loadedSessions"]),
      "seededThreads" => seeded_threads(saved["seededThreads"]),
      "countedThreads" => strings(saved["countedThreads"]),
      "liveThreads" => strings(saved["liveThreads"]),
      "sessions" => count(saved["sessions"]),
      "prompts" => count(saved["prompts"]),
      "importedSessions" => count(saved["importedSessions"]),
      "pending" =>
        case saved["pending"] do
          %{"items" => items} = pending ->
            %{"items" => strings(items), "since" => count(pending["since"])}

          _ ->
            nil
        end,
      "lastActivity" => count(saved["lastActivity"])
    }
  end

  @doc "The state as its JSON file keeps it (it already is that shape)."
  def dump(state), do: state

  # What the file had is read as far as it has the right shape, and the rest left
  # out: a file edited by hand, or by an older version, never stops the plugin.
  defp strings(list), do: list |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq()
  defp count(n) when is_number(n), do: max(trunc(n), 0)
  defp count(_), do: 0

  defp streaks(map) when is_map(map) do
    for {tool, %{} = streak} <- map, into: %{} do
      {tool, %{"sessions" => count(streak["sessions"]), "prompts" => count(streak["prompts"])}}
    end
  end

  defp streaks(_), do: %{}

  defp counts(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, count(v)} end)
  defp counts(_), do: %{}

  # --- folding one conversation (or idle segment of one) ---------------------

  @doc """
  Folds one finished conversation — or one idle segment of a conversation that may
  later resume — into the evidence: what it had `loaded`, what it `used`, and the
  `prompts` (turns) it ran. A segment that ran no prompt is no evidence, and one
  folded from a thread's earlier turns (`imported: true`) does not grow the live
  streaks `auto` needs. A segment of `thread: id`'s conversation counts as a session
  only if none of that conversation's did before (`new_conversation/2` starts the
  next one), however many it folds in: its prompts count either way. A live session
  is counted apart, so a conversation read back first still counts once live when it
  resumes. `now` is unix seconds. Returns the new state.
  """
  def fold_segment(state, loaded, used, prompts, cfg, now, opts \\ []) do
    imported = Keyword.get(opts, :imported, false)
    thread = Keyword.get(opts, :thread)
    session = prompts > 0 and thread not in state["countedThreads"]
    live = prompts > 0 and not imported and thread not in state["liveThreads"]
    used = MapSet.new(used)

    state =
      state
      |> put_in(["used"], Enum.uniq(state["used"] ++ MapSet.to_list(used)))
      |> heal(cfg)
      |> count_thread("countedThreads", thread, session)
      |> count_thread("liveThreads", thread, live)

    cond do
      prompts <= 0 ->
        # No evidence about the unused, but a use is still a use.
        Enum.reduce(loaded, state, fn tool, acc ->
          if MapSet.member?(used, tool),
            do: acc |> reset("streaks", tool) |> reset("liveStreaks", tool),
            else: acc
        end)

      loaded == [] ->
        count_session(state, prompts, imported, session)

      true ->
        state =
          Enum.reduce(loaded, state, fn tool, acc ->
            acc =
              if session,
                do: update_in(acc["loadedSessions"][tool], &((&1 || 0) + 1)),
                else: acc

            if MapSet.member?(used, tool) do
              acc
              |> reset("streaks", tool)
              |> reset("liveStreaks", tool)
            else
              acc
              |> grow("streaks", tool, prompts, session)
              |> then(&if(imported, do: &1, else: grow(&1, "liveStreaks", tool, prompts, live)))
            end
          end)

        state
        |> count_session(prompts, imported, session)
        |> then(&if(session, do: demote(&1, cfg), else: &1))
        |> hold(cfg, now)
    end
  end

  defp count_thread(state, key, thread, true) when is_binary(thread),
    do: update_in(state[key], &[thread | &1])

  defp count_thread(state, _key, _thread, _counted), do: state

  defp count_session(state, prompts, imported, session) do
    sessions = if session, do: 1, else: 0

    state
    |> update_in(["sessions"], &(&1 + sessions))
    |> update_in(["prompts"], &(&1 + prompts))
    |> update_in(["importedSessions"], &(&1 + if(imported, do: sessions, else: 0)))
  end

  defp reset(state, key, tool),
    do: put_in(state[key][tool], %{"sessions" => 0, "prompts" => 0})

  defp grow(state, key, tool, prompts, session) do
    streak = state[key][tool] || %{"sessions" => 0, "prompts" => 0}

    put_in(state[key][tool], %{
      "sessions" => streak["sessions"] + if(session, do: 1, else: 0),
      "prompts" => streak["prompts"] + prompts
    })
  end

  # A tool that has since become protected, or has been seen in use, comes back:
  # only ever in the direction of giving a tool back.
  defp heal(state, cfg) do
    blocked = fn tool ->
      protected?(tool, cfg) or tool in state["used"] or tool in state["kept"]
    end

    state
    |> update_in(["off"], &Enum.reject(&1, blocked))
    |> update_in(["demoted"], &Enum.reject(&1, blocked))
  end

  # Codex: demote at most two newly eligible packages per session, folded as it is
  # first counted.
  defp demote(%{"unit" => "capability"} = state, cfg) do
    fresh =
      @candidates["capability"]
      |> Enum.filter(fn cap ->
        cap not in state["demoted"] and cap not in state["off"] and
          cap not in state["kept"] and cap not in state["used"] and
          not protected?(cap, cfg) and
          (state["loadedSessions"][cap] || 0) >= @min_exposures[cap]
      end)
      |> Enum.take(@max_demotions)

    update_in(state["demoted"], &Enum.uniq(&1 ++ fresh))
  end

  defp demote(state, _cfg), do: state

  # `auto`: hold the proposal pending, from when it first waited. What rests on
  # imported turns waits for the person to apply it: only live streaks count, as
  # imported prompts of a conversation already counted add no imported session.
  defp hold(state, %{"mode" => "auto"} = cfg, now) do
    held = live_proposal(state, cfg)

    if held == [] do
      state
    else
      since = (state["pending"] || %{})["since"] || now
      put_in(state["pending"], %{"items" => held, "since" => since})
    end
  end

  defp hold(state, _cfg, _now), do: state

  defp live_proposal(state, cfg) do
    state
    |> proposal(cfg)
    |> Enum.filter(&enough?(state["liveStreaks"][&1], cfg, high_risk?(&1)))
  end

  # --- proposals and what is off ---------------------------------------------

  @doc "The tools the evidence proposes turning off now, in candidate order."
  def proposal(state, cfg) do
    if cfg["mode"] == "off" do
      []
    else
      Enum.filter(candidate_tools(state["unit"]), fn tool ->
        proposable?(state, cfg, tool) and
          (state["unit"] != "capability" or tool in state["demoted"]) and
          enough?(state["streaks"][tool], cfg, high_risk?(tool))
      end)
    end
  end

  defp proposable?(state, cfg, tool) do
    not protected?(tool, cfg) and tool not in state["used"] and
      tool not in state["kept"] and tool not in state["off"]
  end

  defp enough?(nil, _cfg, _high), do: false

  defp enough?(streak, cfg, high),
    do: enough_evidence?(streak["sessions"], streak["prompts"], cfg, high)

  @doc """
  What the next conversation runs without: the applied list, healed of anything
  since protected, used, or given back. Nothing under `off`.
  """
  def denied(state, cfg) do
    if cfg["mode"] == "off" do
      []
    else
      state["off"]
      |> Enum.filter(&(&1 in candidate_tools(state["unit"])))
      |> Enum.reject(fn tool ->
        protected?(tool, cfg) or tool in state["used"] or tool in state["kept"]
      end)
    end
  end

  @doc """
  Applies the pending `auto` list once the project has been quiet long enough —
  idle `quiet_minutes` with no turn under way (`active`), or a day since the list
  formed regardless: applying only shapes the next conversation, so a turn that
  runs on (or whose end was never heard) cannot stall it for good. `{state,
  applied}`; nothing is applied, and the wait goes on, until then. A list whose
  tools were used, protected or given back meanwhile, or that the evidence no
  longer proposes on live evidence alone (the person raised the thresholds),
  applies only what is left of it, and is dropped when nothing is.
  """
  def apply_pending(state, cfg, now, active \\ false) do
    case {cfg["mode"], state["pending"]} do
      {"auto", %{"items" => items, "since" => since}} ->
        items = Enum.filter(items, &(&1 in live_proposal(state, cfg)))

        idle = now - state["lastActivity"]
        waited = now - since

        cond do
          items == [] ->
            {put_in(state["pending"], nil), []}

          waited < @pending_max_s and (active or idle < cfg["quiet_minutes"] * 60) ->
            {state, []}

          true ->
            state =
              state
              |> update_in(["off"], &Enum.uniq(&1 ++ items))
              |> put_in(["pending"], nil)

            {state, items}
        end

      _ ->
        # No longer `auto` (or nothing held): a held list does not outlive the mode.
        {put_in(state["pending"], nil), []}
    end
  end

  @doc """
  Applies tools by the person's say-so: the whole proposal when `tools` is nil, or
  the named ones, which may include a tool given back with restore (applying it by
  name is the one way back). A protected or ever-used tool is refused even by name,
  as is a name that is no candidate here. `{state, applied, refused}`.
  """
  def apply_named(state, cfg, tools) do
    wanted = if tools, do: Enum.uniq(tools), else: proposal(state, cfg)

    {applied, refused} =
      Enum.split_with(wanted, fn tool ->
        tool in candidate_tools(state["unit"]) and not protected?(tool, cfg) and
          tool not in state["used"]
      end)

    state =
      state
      |> update_in(["off"], &Enum.uniq(&1 ++ applied))
      |> update_in(["kept"], &(&1 -- applied))
      |> drop_pending(applied)

    {state, applied, refused}
  end

  @doc """
  Gives tools back: all that are off when `tools` is nil, or the named ones. A
  named tool need not be off yet: refusing a proposed or pending one gives it
  back before it ever applies. A tool given back is kept — never proposed or
  applied by itself again, only applied by name. `{state, restored}`, where
  `restored` is what was off and comes back.
  """
  def restore(state, tools) do
    named =
      if tools,
        do: Enum.filter(Enum.uniq(tools), &(&1 in candidate_tools(state["unit"]))),
        else: state["off"]

    restored = Enum.filter(named, &(&1 in state["off"]))

    state =
      state
      |> update_in(["off"], &(&1 -- restored))
      |> update_in(["kept"], &Enum.uniq(&1 ++ named))
      |> drop_pending(named)

    {state, restored}
  end

  defp drop_pending(state, done) do
    case state["pending"] do
      %{"items" => items} = pending ->
        case items -- done do
          [] -> put_in(state["pending"], nil)
          left -> put_in(state["pending"], %{pending | "items" => left})
        end

      _ ->
        state
    end
  end

  @doc """
  Notes tools seen in use while a conversation is still under way, before its
  segment folds: a use protects a tool from the moment it is seen, so a tool
  applied by name and then used in a conversation that had it loaded comes back
  at once, not at the fold, and no other conversation is shaped without it.
  """
  def note_used(state, used, cfg) do
    state
    |> put_in(["used"], Enum.uniq(state["used"] ++ used))
    |> heal(cfg)
    |> drop_pending(used)
  end

  @doc "Starts `thread_id`'s next conversation, whose first segment counts as a session."
  def new_conversation(state, thread_id) do
    state
    |> update_in(["countedThreads"], &List.delete(&1, thread_id))
    |> update_in(["liveThreads"], &List.delete(&1, thread_id))
  end

  defp seeded_threads(map) when is_map(map) do
    Map.new(map, fn {thread, run} -> {thread, if(is_binary(run), do: run)} end)
  end

  defp seeded_threads(_), do: %{}

  @doc """
  What a thread's history, oldest first, still has to fold as `run_id` starts:
  `{watermark, runs}`, the runs after the thread's watermark (`seeded_run/2`) and
  before `run_id` that `mine?` keeps, and the watermark past all of them, whoever's
  they were. `run_id` and any after it are still to be heard live, though the feed
  may deliver its start after it ended. A watermark not among them is older than all
  of them (it names the last run folded), so all are new.
  """
  def unseen_runs(history, watermark, run_id, mine?) do
    history = Enum.take_while(history, &(&1["runId"] != run_id))

    new =
      case watermark && Enum.find_index(history, &(&1["runId"] == watermark)) do
        nil -> history
        index -> Enum.drop(history, index + 1)
      end

    last = if new == [], do: watermark, else: List.last(new)["runId"]
    {last, Enum.filter(new, mine?)}
  end

  @doc "The last run of `thread_id` already folded, live or read back, or nil."
  def seeded_run(state, thread_id), do: state["seededThreads"][thread_id]

  @doc """
  Remembers `run_id` as the last run of `thread_id` already folded — a
  per-thread watermark, so a restart folds only the runs after it, however many
  turns the project ran live before it.
  """
  def note_thread(state, thread_id, run_id) when is_binary(run_id) do
    put_in(state["seededThreads"][thread_id], run_id)
  end

  def note_thread(state, _thread_id, _run_id), do: state

  @doc "Marks when the project last did anything (a turn starting, running, or ending)."
  def activity(state, now), do: put_in(state["lastActivity"], max(state["lastActivity"], now))

  # --- what a turn item used ---------------------------------------------------

  @doc """
  The tools of `unit` one observed turn item used: Claude's own tool name where the
  item has one (else the work-surface name its kind stands for), or the Codex
  capability a tool name exercises, including a nested `tools.<name>(...)` call in
  a tool's input, as upstream reads Codex traces.
  """
  def used_in_item(item, "tool") do
    cond do
      is_binary(item["tool"]) and item["tool"] != "" -> [item["tool"]]
      item["itemType"] == "command_execution" -> ["Bash"]
      item["itemType"] == "file_change" -> ["Edit"]
      item["itemType"] == "file_search" -> ["Grep"]
      item["itemType"] == "web_search" -> ["WebSearch"]
      true -> []
    end
  end

  def used_in_item(item, "capability") do
    names =
      [item["tool"], item["itemType"], item["title"]] ++
        nested_tools(item["input"])

    names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&@capability_of[native_name(&1)])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def used_in_item(_item, _unit), do: []

  # The MC names a Codex tool call `<namespace>.<tool>` (an MCP call `<server>.<tool>`),
  # and Codex's own tools sit in `tools`: `tools.view_image` is `view_image`, while
  # another server's `view_image` is that server's tool, not Codex's package.
  defp native_name("tools." <> name), do: name
  defp native_name(name), do: name

  defp nested_tools(input) when is_binary(input) do
    ~r/\btools\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/
    |> Regex.scan(input)
    |> Enum.map(&Enum.at(&1, 1))
  end

  defp nested_tools(_), do: []

  # --- what clients are shown ----------------------------------------------------

  @doc "The state as the `toolPrune` topic and the `toolPrune` call carry it, with the evidence for each tool."
  def summary(state, cfg) do
    proposed = proposal(state, cfg)
    off = denied(state, cfg)

    tools =
      Map.new(candidate_tools(state["unit"]), fn tool ->
        streak = state["streaks"][tool] || %{"sessions" => 0, "prompts" => 0}

        {tool,
         %{
           "state" =>
             cond do
               protected?(tool, cfg) -> "protected"
               tool in state["used"] -> "used"
               tool in state["kept"] -> "kept"
               tool in off -> "off"
               tool in proposed -> "proposed"
               true -> "loaded"
             end,
           "unusedSessions" => streak["sessions"],
           "unusedPrompts" => streak["prompts"],
           "loadedSessions" => state["loadedSessions"][tool] || 0
         }}
      end)

    %{
      "unit" => state["unit"],
      "mode" => cfg["mode"],
      "off" => off,
      "proposed" => proposed,
      "kept" => state["kept"],
      "pending" => (state["pending"] || %{})["items"] || [],
      "sessions" => state["sessions"],
      "prompts" => state["prompts"],
      "tools" => tools
    }
  end
end
