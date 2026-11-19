Code.require_file("../../../../plugins/office/mc/floor.ex", __DIR__)

defmodule HalC2.OfficePropTest do
  @moduledoc """
  The office plugin's state (`HalC2Plugins.Office.Floor`, in `plugins/office/mc`) as a
  state machine: rows put and deleted in every state and with every flag, turns that
  start, call tools, send messages and finish, settings changed and time passing. After
  every step the office is the model's:

  - its people are the rows still in it (not archived, moved or deleted; a settled or
    long idle one only while it works, asks or waits; a worker whose parent left, or
    has no row, only while it works or waits), asking first, then working, waiting and
    the rest, newest first, no more than `maxPeople`;
  - each is in its row's state, shows what its agent last did only while working,
    and has a question exactly while asking;
  - its talks are the newest 40 kept, in the order first heard (a talk heard again
    keeps its place, time, who said it to whom and its kind), those under ten minutes
    old, each from, to and of the kind it was said; once the timer fires, the office
    keeps no talk older, text and all.

  A second property holds the deadline `next_change/2` names to `view/2`: an idle thread
  is in the office the millisecond before it and gone at it, whatever its idle hours.

  The plugin process, the host and the page are covered by
  `features/plugins/office.feature`.
  """
  use ExUnit.Case, async: true
  use PropCheck
  use PropCheck.StateM

  alias HalC2Plugins.Office.Floor

  @ids ~w(t1 t2 t3 t4 t5)
  @start 1_800_000_000_000
  @talk_ms 600_000
  @born_ms 120_000
  @ranks %{"asking" => 0, "working" => 1, "waiting" => 2, "idle" => 3, "failed" => 3}
  @tools %{
    "Read" => "reading",
    "Edit" => "typing",
    "WebSearch" => "browsing",
    "TodoWrite" => "planning",
    "mix test" => "testing",
    "ls -la" => "running",
    "mcp__hal-c2__delegate_task" => "delegating"
  }

  property "the office is the model's", numtests: HalC2.Prop.numtests(200) do
    forall cmds <- commands(__MODULE__) do
      Process.put(:floor, Floor.new(%{"maxPeople" => 3, "idleHours" => 1}))
      Process.put(:now, @start)
      {history, state, result} = run_commands(__MODULE__, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true)}
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result, pretty: true)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  property "an idle thread leaves the office at the deadline next_change names",
    numtests: HalC2.Prop.numtests(200) do
    forall {hours, age} <- {idle_hours(), integer(0, 10_000)} do
      now = @start
      floor = %{"maxPeople" => 3, "idleHours" => hours} |> Floor.new() |> put_idle(now - age)
      at = Floor.next_change(floor, now)

      at == nil or (in_office?(floor, at - 1) and not in_office?(floor, at))
    end
  end

  # Hours whose milliseconds are mostly not whole, a few of them short enough to pass.
  defp idle_hours,
    do:
      oneof([
        let(ms <- integer(1, 20_000), do: (ms + 0.4) / 3_600_000),
        let(ms <- integer(1, 20_000), do: (ms + 0.6) / 3_600_000),
        elements([1, 0.5, 1.0e-7, 24])
      ])

  defp put_idle(floor, at), do: Floor.load(floor, [row("t1", "idle", :none, nil, at)], at)
  defp in_office?(floor, now), do: Floor.view(floor, now)["people"] != []

  def initial_state,
    do: %{
      now: @start,
      max: 3,
      idle_hours: 1,
      rows: %{},
      activity: %{},
      said: %{},
      talks: []
    }

  def command(_state) do
    oneof([
      {:call, __MODULE__, :put_row,
       [
         elements(@ids),
         elements(~w(asking working waiting failed idle)),
         elements([:none, :archived, :moved, :settled, :unsettled]),
         elements([nil, "t1", "t2"]),
         elements([0, 60_000, 30 * 60_000, 2 * 3_600_000])
       ]},
      {:call, __MODULE__, :delete_row, [elements(@ids)]},
      {:call, __MODULE__, :start_turn, [elements(@ids)]},
      {:call, __MODULE__, :call_tool, [elements(@ids), elements(Map.keys(@tools))]},
      {:call, __MODULE__, :say, [elements(@ids), elements(["Done.\nAll green.", "  ", "Fixed"])]},
      {:call, __MODULE__, :send_message, [elements(@ids), elements(@ids), integer(0, 60)]},
      {:call, __MODULE__, :send_messages, [elements(@ids), integer(0, 60)]},
      {:call, __MODULE__, :finish, [elements(@ids), integer(0, 2)]},
      {:call, __MODULE__, :settings, [integer(1, 4), elements([1, 3])]},
      {:call, __MODULE__, :tick, [elements([1_000, 90_000, 5 * 60_000, 3_600_000])]}
    ])
  end

  def precondition(_state, _call), do: true

  # --- the system: the floor and the time, in the case's process ----------------------

  def put_row(id, state, flag, parent, age) do
    now = Process.get(:now)
    step(&Floor.rows(&1, [row(id, state, flag, parent, now - age)], now))
  end

  def delete_row(id) do
    now = Process.get(:now)
    step(&Floor.rows(&1, [%{"id" => id, "deletedAt" => Floor.iso(now)}], now))
  end

  def start_turn(id),
    do: event(%{"type" => "turn.started", "threadId" => id, "provider" => "claudeAgent"})

  def call_tool(id, tool), do: event(item(id, tool))

  def say(id, text),
    do:
      event(%{
        "type" => "turn.item",
        "threadId" => id,
        "itemType" => "assistant_message",
        "text" => text
      })

  # Fifteen messages at once, so the office holds more talks than it keeps.
  def send_messages(from, k) do
    for i <- k..(k + 14), reduce: nil, do: (_ -> send_message(from, "t1", i))
  end

  def send_message(from, to, k) do
    event(%{
      "type" => "turn.item",
      "threadId" => from,
      "itemId" => "i#{k}",
      "itemType" => "dynamic_tool",
      "tool" => "mcp__hal-c2__hal_c2_thread_send",
      "status" => "completed",
      "input" => JSON.encode!(%{"threadId" => to, "message" => "m#{k}"})
    })
  end

  def finish(id, run),
    do: event(%{"type" => "turn.finished", "threadId" => id, "runId" => "r#{run}"})

  def settings(max, hours),
    do: step(&Floor.settings(&1, %{"maxPeople" => max, "idleHours" => hours}))

  # Time passes and the timer fires, as `HalC2Plugins.Office`'s does: what it keeps
  # is said too.
  def tick(ms) do
    now = Process.get(:now) + ms
    Process.put(:now, now)
    view = step(&Floor.expire(&1, now))
    Map.put(view, "kept", Enum.map(Process.get(:floor).talks, & &1["id"]))
  end

  defp event(event), do: step(&Floor.observe(&1, event, Process.get(:now)))

  defp step(fun) do
    floor = fun.(Process.get(:floor))
    Process.put(:floor, floor)
    Floor.view(floor, Process.get(:now))
  end

  defp item(id, tool) when tool in ["mix test", "ls -la"],
    do: %{
      "type" => "turn.item",
      "threadId" => id,
      "itemType" => "command_execution",
      "tool" => "Bash",
      "status" => "completed",
      "input" => tool
    }

  defp item(id, tool) do
    type =
      case tool do
        "Edit" -> "file_change"
        "WebSearch" -> "web_search"
        _ -> "dynamic_tool"
      end

    %{
      "type" => "turn.item",
      "threadId" => id,
      "itemType" => type,
      "tool" => tool,
      "status" => "completed"
    }
  end

  defp row(id, state, flag, parent, at) do
    at = Floor.iso(at)

    %{
      "id" => id,
      "title" => "Thread #{id}",
      "projectId" => "p",
      "projectTitle" => "api",
      "providerInstanceId" => "codex",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "createdAt" => at,
      "updatedAt" => at,
      "deletedAt" => nil,
      "archivedAt" => if(flag == :archived, do: at),
      "movedTo" => if(flag == :moved, do: %{"mc" => "elsewhere"}),
      "settledAt" => if(flag in [:settled, :unsettled], do: at),
      "settledOverride" => if(flag == :unsettled, do: "active"),
      "lineage" =>
        if(parent && parent != id,
          do: %{"parentThreadId" => parent, "relationshipToParent" => "subagent"},
          else: %{"parentThreadId" => nil, "relationshipToParent" => nil}
        ),
      "status" =>
        case state do
          s when s in ~w(asking working) -> "running"
          "failed" -> "failed"
          _ -> "completed"
        end,
      "activityRunStatus" => if(state in ~w(asking working), do: "running"),
      "pendingRuntimeRequest" =>
        if(state == "asking", do: %{"id" => "q", "kind" => "approval", "createdAt" => at}),
      "pendingBackgroundTasks" =>
        if(state == "waiting", do: [%{"taskId" => "w", "taskType" => "subagent"}], else: [])
    }
  end

  # --- the model --------------------------------------------------------------------------

  def next_state(s, _result, {:call, _, :put_row, [id, state, flag, parent, age]}) do
    parent = if parent != id, do: parent
    entry = %{state: state, flag: flag, parent: parent, at: s.now - age}

    s =
      if not Map.has_key?(s.rows, id) and parent != nil and age <= @born_ms,
        do: add_talk(s, "delegate:" <> id, {parent, id, "delegate"}, "Thread #{id}"),
        else: s

    put_in(s, [:rows, id], entry)
  end

  def next_state(s, _result, {:call, _, :delete_row, [id]}) do
    %{
      s
      | rows: Map.delete(s.rows, id),
        activity: Map.delete(s.activity, id),
        said: Map.delete(s.said, id)
    }
  end

  def next_state(s, _result, {:call, _, :start_turn, [id]}),
    do: %{s | activity: Map.put(s.activity, id, "thinking"), said: Map.delete(s.said, id)}

  def next_state(s, _result, {:call, _, :call_tool, [id, tool]}),
    do: %{s | activity: Map.put(s.activity, id, @tools[tool])}

  def next_state(s, _result, {:call, _, :say, [id, text]}) do
    s = %{s | activity: Map.put(s.activity, id, "thinking")}

    case Floor.line(text) do
      line when line in [nil, ""] -> s
      line -> %{s | said: Map.put(s.said, id, line)}
    end
  end

  def next_state(s, result, {:call, _, :send_messages, [from, k]}) do
    Enum.reduce(
      k..(k + 14),
      s,
      &next_state(&2, result, {:call, __MODULE__, :send_message, [from, "t1", &1]})
    )
  end

  def next_state(s, _result, {:call, _, :send_message, [from, to, k]}) do
    %{s | activity: Map.put(s.activity, from, "delegating")}
    |> add_talk("message:#{from}:i#{k}", {from, to, "message"}, "m#{k}")
  end

  def next_state(s, _result, {:call, _, :finish, [id, run]}) do
    said = s.said[id]
    parent = get_in(s.rows, [id, :parent])
    s = %{s | activity: Map.delete(s.activity, id), said: Map.delete(s.said, id)}

    if parent && said,
      do: add_talk(s, "result:#{id}:r#{run}", {id, parent, "result"}, said),
      else: s
  end

  def next_state(s, _result, {:call, _, :settings, [max, hours]}),
    do: %{s | max: max, idle_hours: hours}

  def next_state(s, _result, {:call, _, :tick, [ms]}), do: expire(%{s | now: s.now + ms})

  # A talk heard again keeps its place, time, ends and kind, and takes the new text; one
  # too old is gone first, so a talk heard again after that is new.
  defp add_talk(s, id, {from, to, kind}, text) do
    s = expire(s)

    talks =
      if Enum.any?(s.talks, &(&1.id == id)),
        do: Enum.map(s.talks, &if(&1.id == id, do: %{&1 | text: text}, else: &1)),
        else:
          Enum.take(
            s.talks ++ [%{id: id, from: from, to: to, kind: kind, text: text, at: s.now}],
            -40
          )

    %{s | talks: talks}
  end

  defp expire(s), do: %{s | talks: Enum.filter(s.talks, &(&1.at > s.now - @talk_ms))}

  def postcondition(s, call, view) do
    s = next_state(s, nil, call)
    expected = people(s)
    talks = Enum.filter(s.talks, &(&1.at > s.now - @talk_ms))

    Enum.map(view["people"], & &1["id"]) == Enum.map(expected, &elem(&1, 0)) and
      Enum.all?(Enum.zip(view["people"], expected), &person?(s, &1)) and
      Enum.map(view["talks"], &talk/1) ==
        Enum.map(talks, &{&1.id, &1.from, &1.to, &1.kind, &1.text, &1.at}) and
      kept?(call, view, talks)
  end

  defp talk(t), do: {t["id"], t["from"], t["to"], t["kind"], t["text"], Floor.ms(t["at"])}

  # After the timer the office keeps only the talks it shows.
  defp kept?({:call, _, :tick, _}, view, talks), do: view["kept"] == Enum.map(talks, & &1.id)
  defp kept?(_call, _view, _talks), do: true

  defp people(s) do
    s.rows
    |> Enum.filter(fn {id, _r} -> here?(s, id, []) end)
    |> Enum.sort_by(fn {id, r} -> {@ranks[r.state], -r.at, id} end)
    |> Enum.take(s.max)
  end

  # A thread is here unless archived or moved; working or waiting it always is, and
  # otherwise only while its parent is (a parent with no row is not), then asking, or
  # recently idle and not settled. A lineage that loops stops where it does.
  defp here?(s, id, seen) do
    r = s.rows[id]
    seen = [id | seen]

    r.flag not in [:archived, :moved] and
      (r.state in ~w(working waiting) or
         ((r.parent == nil or r.parent in seen or
             (Map.has_key?(s.rows, r.parent) and here?(s, r.parent, seen))) and
            (r.state == "asking" or
               (r.flag != :settled and s.now - r.at < s.idle_hours * 3_600_000))))
  end

  defp person?(s, {person, {id, r}}) do
    person["state"] == r.state and person["parentId"] == r.parent and
      person["activity"] == if(r.state == "working", do: s.activity[id]) and
      person["question"] != nil == (r.state == "asking") and
      person["provider"] in ["claudeAgent", "codex"] and is_binary(person["since"]) and
      person["project"] == "api" and person["model"] == "gpt-5.4"
  end
end
