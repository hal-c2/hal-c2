defmodule HalC2Plugins.Planner do
  @moduledoc """
  The planner. Keeps a plan of tasks and milestones (`HalC2Plugins.Planner.Plan`),
  the views users save of it and the status updates that say how it goes; runs the
  user's actions as agent threads whose reports come back as proposals, starts work on
  a task in a worktree of its own, follows GitHub issues, boards and pull requests
  (`HalC2Plugins.Planner.Sync`) and talks to a Slack channel
  (`HalC2Plugins.Planner.Slack`).

  A run is `queued`, `running`, `failed`, `proposed` (its changes wait for the user),
  `applied` or `done` (it had nothing to apply). The plan and its runs are kept in
  `plan.json` in the plugin's data directory and published for the UI parts: the plan
  on the `plan` topic, the runs on `runs`, and each run thread's run on `threads`.

  The server only decides. GitHub and Slack are asked outside it: in the caller of a
  call or tool once the server has answered, and in a process of its own for the timer.
  """
  @behaviour HalC2.Plugins.Extension
  use GenServer

  alias HalC2.Plugins.Host
  alias HalC2Plugins.Planner.{Plan, Slack, Sync}

  @id "planner"
  @manifest Path.join(__DIR__, "../plugin.json")
  @external_resource @manifest
  # The built-in actions as the manifest gives them, so a prompt can be reset to its own.
  @default_actions @manifest
                   |> File.read!()
                   |> JSON.decode!()
                   |> Map.fetch!("settings")
                   |> Enum.find(&(&1["key"] == "actions"))
                   |> Map.fetch!("default")
  @builtin ~w(validate reschedule feedback breakdown status work)
  @modes ~w(approval-required auto-accept-edits auto full-access)
  @choices %{
    "runtimeMode" => @modes,
    "workRuntimeMode" => @modes,
    "display" => ~w(page threads both),
    "sync" => ~w(off import twoWay)
  }
  @healths ~w(on-track at-risk off-track)
  @not_connected "Slack is not connected on this MC."
  @read_tool "planner_read"
  @report_tool "planner_report"
  @progress_tool "planner_progress"

  @report """
  When you are done, report with the `planner_report` tool of the hal-c2 MCP server. \
  Nothing in the plan changes until you do, and only the report counts, not your \
  messages. Read the plan with `planner_read` when you need more than this message \
  gives. Report once, with:

  - summary: what you found, for the people who follow the plan
  - health: on-track, at-risk or off-track, when you judge how the plan is going
  - changes: each with an op and a reason. update gives itemId and fields; add gives \
  fields and a ref that later changes may name in parent and after; remove gives \
  itemId; link gives itemId and fields {"pullRequest": {repository, number}} or \
  {"issue": {repository, number}}. fields are title, notes, kind (task or milestone), \
  status (todo, doing, blocked, done, dropped), start and due (YYYY-MM-DD), progress \
  (0 to 100), parent, after (the ids it waits for), labels and owner
  - feedback: notes on one task ({itemId, text}) or on the whole plan ({text})\
  """

  # --- extension ------------------------------------------------------------------------

  @impl HalC2.Plugins.Extension
  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl HalC2.Plugins.Extension
  def validate_settings(settings) do
    repos = settings["repositories"] || []
    actions = settings["actions"]

    cond do
      String.trim(settings["provider"] || "") == "" ->
        {:error, "provider: name the agent that runs actions."}

      key = Enum.find(Map.keys(@choices), &(settings[&1] not in @choices[&1])) ->
        {:error,
         "#{key}: #{inspect(settings[key])} is not one of #{Enum.join(@choices[key], ", ")}."}

      not is_list(repos) ->
        {:error, "repositories: give them as a list of owner/name."}

      bad = Enum.find(repos, &(not repository?(&1))) ->
        {:error, "repositories: #{inspect(bad)} is not owner/name."}

      not board?(settings["board"] || "") ->
        {:error, "board: #{inspect(settings["board"])} is not owner/number of a GitHub Project."}

      not (is_number(settings["concurrency"]) and settings["concurrency"] >= 1) ->
        {:error, "concurrency: at least one action must be able to run."}

      not (is_number(settings["pollMinutes"]) and settings["pollMinutes"] >= 1) ->
        {:error, "pollMinutes: look at least once a minute apart."}

      not String.starts_with?(settings["slackCommand"] || "/", "/") ->
        {:error, "slackCommand: a slash command starts with /."}

      not is_map(actions) or actions == %{} ->
        {:error, "actions: give them as {\"id\": {label, scope, kind, apply, prompt}}."}

      true ->
        actions
        |> Enum.sort()
        |> Enum.find_value(:ok, fn {id, action} ->
          with :ok <- check_action(id, action), do: nil
        end)
    end
  end

  defp check_action(id, action) when is_map(action) do
    label = String.trim(action["label"] || "")

    cond do
      label == "" ->
        {:error, "actions: #{id} needs a label."}

      action["scope"] not in ~w(item plan) ->
        {:error, "actions: #{label} acts on a task (item) or on the whole plan (plan)."}

      action["kind"] not in ~w(action work) ->
        {:error, "actions: #{label} is an action or work on a task."}

      action["apply"] not in ~w(propose apply) ->
        {:error, "actions: #{label} proposes its changes (propose) or applies them (apply)."}

      not is_binary(action["prompt"]) or String.trim(action["prompt"]) == "" ->
        {:error, "actions: the prompt of #{label} cannot be empty."}

      action["kind"] == "work" and action["scope"] != "item" ->
        {:error, "actions: #{label} works on one task, so it acts on a task."}

      true ->
        :ok
    end
  end

  defp check_action(id, _action), do: {:error, "actions: #{id} is not an action."}

  @impl HalC2.Plugins.Extension
  def call("plan", _input, _context), do: {:ok, server(:plan)}
  def call("runs", _input, _context), do: {:ok, server(:runs)}

  # What the settings page offers: the agents and models, this MC's projects and their
  # repositories, the built-in actions to reset a prompt to, and the Slack channels.
  def call("settings", _input, context) do
    {:ok, providers} = Host.providers(@id)

    projects =
      case Host.projects(@id) do
        {:ok, projects} -> projects
        _ -> []
      end

    {connected, channels} =
      case slack("channels", %{}) do
        {:ok, %{"channels" => channels}} -> {true, Enum.map(channels, &Map.take(&1, ~w(id name)))}
        _ -> {false, []}
      end

    {:ok,
     %{
       "settings" => context.settings,
       "defaultActions" => @default_actions,
       "providers" => providers,
       "projects" => Enum.map(projects, &Map.take(&1, ~w(id title repository))),
       "repositories" =>
         for(
           %{"kind" => "github", "repository" => repository} <- projects,
           is_binary(repository),
           uniq: true,
           do: repository
         ),
       "slackChannels" => channels,
       "slackConnected" => connected
     }}
  end

  def call("boards", _input, _context), do: Sync.boards()

  def call("boardFields", %{"board" => board}, _context), do: Sync.board_fields(board)

  def call("addItem", %{"fields" => fields}, context),
    do: change({:add, fields}, context.settings)

  def call("updateItem", %{"id" => id, "fields" => fields}, context),
    do: change({:update, id, fields}, context.settings)

  def call("removeItem", %{"id" => id}, context), do: change({:remove, id}, context.settings)

  def call("moveItem", %{"id" => id} = input, context),
    do: change({:move, id, input["parent"], input["before"]}, context.settings)

  def call("moveToMilestone", %{"id" => id} = input, context),
    do: change({:to_milestone, id, input["from"], input["to"]}, context.settings)

  def call("saveView", %{"view" => view}, context),
    do: change({:save_view, view}, context.settings)

  def call("removeView", %{"id" => id}, context), do: change({:remove_view, id}, context.settings)
  def call("setBaseline", _input, context), do: change({:baseline, true}, context.settings)
  def call("clearBaseline", _input, context), do: change({:baseline, false}, context.settings)

  def call("postUpdate", input, context) do
    text = String.trim(input["text"] || "")

    cond do
      input["health"] not in @healths ->
        {:error, "health is one of #{Enum.join(@healths, ", ")}."}

      text == "" ->
        {:error, "An update needs its text."}

      true ->
        change({:post_update, input["health"], text}, context.settings)
    end
  end

  def call("run", %{"action" => action} = input, context),
    do: change({:run, action, input["itemIds"] || [], input["projectId"]}, context.settings)

  def call("retry", %{"runId" => id}, context), do: change({:retry, id}, context.settings)

  def call("dismissChange", %{"runId" => run, "changeId" => change} = input, context),
    do: change({:dismiss_change, run, change, input["dismissed"] != false}, context.settings)

  def call("apply", %{"runId" => id}, context), do: change({:apply, id}, context.settings)
  def call("discard", %{"runId" => id}, context), do: change({:discard, id}, context.settings)

  def call("dismissFeedback", %{"feedbackId" => feedback} = input, context),
    do: change({:dismiss_feedback, input["itemId"], feedback}, context.settings)

  def call("sync", _input, context) do
    :ok = server({:looked, look(context.settings, server(:items))})
    {:ok, server(:plan)}
  end

  # Works in every sync mode: the user asks for this issue, whatever the plan follows.
  def call("createIssue", %{"itemId" => id, "repository" => repository}, context) do
    with {:ok, item} <- server({:item, id}),
         {:ok, issue} <- Sync.create_issue(item, repository),
         do: change({:link, id, %{"issue" => issue}}, context.settings)
  end

  def call("link", %{"itemId" => id} = input, context) do
    fields =
      cond do
        ref?(input["pullRequest"]) ->
          {:ok, %{"pullRequest" => input["pullRequest"]}}

        ref?(input["issue"]) ->
          {:ok, %{"issue" => input["issue"]}}

        is_binary(input["threadId"]) ->
          thread(input["threadId"])

        true ->
          {:error, "link gives a pullRequest or an issue as {repository, number}, or a threadId."}
      end

    with {:ok, fields} <- fields, do: change({:link, id, fields}, context.settings)
  end

  def call("unlink", %{"itemId" => id, "kind" => kind} = input, context) do
    if kind == "pullRequest" and not ref?(input["ref"]),
      do: {:error, "unlink gives the pull request as {repository, number}."},
      else: change({:unlink, id, kind, input["ref"] || input["threadId"]}, context.settings)
  end

  def call(method, _input, _context), do: {:error, "planner has no method #{method}."}

  @impl HalC2.Plugins.Extension
  def handle_event(
        %{"type" => "turn.finished", "threadId" => thread_id, "status" => status},
        _context
      ),
      do: GenServer.cast(__MODULE__, {:turn_finished, thread_id, status})

  def handle_event(%{"type" => "slack.reply", "parentTs" => parent} = event, _context)
      when is_binary(parent),
      do: server({:slack_reply, parent, event["userName"] || event["user"], event["text"] || ""})

  def handle_event(%{"type" => "slack.command"} = event, %{settings: settings}) do
    if String.trim(event["command"] || "") == String.trim(settings["slackCommand"] || ""),
      do: command(event, settings)
  end

  def handle_event(%{"type" => "slack.status", "connected" => connected}, %{settings: settings}) do
    if String.trim(settings["slackChannel"] || "") != "" do
      result = if connected, do: {:ok, nil}, else: {:error, @not_connected}
      server({:slack, nil, result, System.monotonic_time()})
    end
  end

  def handle_event(_event, _context), do: :ok

  # Every thread linked to the plan may read it, and every thread at all when the user
  # offers it; only an action's own thread reports, and only work on a task progresses.
  @impl HalC2.Plugins.Extension
  def agent_tools(%{thread_id: thread_id, settings: settings}) when is_binary(thread_id) do
    offered = server({:tools, thread_id})

    [
      (offered.read or settings["offerToAllThreads"] == true) && read_tool(),
      offered.report && report_tool(),
      offered.progress && progress_tool()
    ]
    |> Enum.filter(& &1)
  end

  def agent_tools(_context), do: []

  defp read_tool do
    %{
      "name" => @read_tool,
      "description" =>
        "Read the plan: every task and milestone with its dates, state, progress, owner, what it waits for, its subtasks and its links to issues and pull requests, and today's date.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "itemIds" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Only these tasks."
          }
        }
      }
    }
  end

  defp report_tool do
    fields = %{
      "type" => "object",
      "description" =>
        "title, notes, kind (task|milestone), status (todo|doing|blocked|done|dropped), start, due (YYYY-MM-DD), progress (0-100), parent, after (ids), labels, owner; for link {pullRequest|issue: {repository, number}}"
    }

    %{
      "name" => @report_tool,
      "description" =>
        "Report what this planner action found: a summary, the plan's health, the changes to make to the plan and feedback on tasks. Nothing changes until you report; the user accepts the changes unless the action applies them.",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["summary"],
        "properties" => %{
          "summary" => %{"type" => "string"},
          "health" => %{"type" => "string", "enum" => @healths},
          "changes" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "required" => ["op"],
              "properties" => %{
                "op" => %{"type" => "string", "enum" => ~w(update add remove link)},
                "itemId" => %{"type" => "string"},
                "ref" => %{"type" => "string"},
                "fields" => fields,
                "reason" => %{"type" => "string"}
              }
            }
          },
          "feedback" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "required" => ["text"],
              "properties" => %{
                "itemId" => %{"type" => "string"},
                "text" => %{"type" => "string"}
              }
            }
          }
        }
      }
    }
  end

  defp progress_tool do
    ref = %{
      "type" => "object",
      "required" => ["repository", "number"],
      "properties" => %{"repository" => %{"type" => "string"}, "number" => %{"type" => "integer"}}
    }

    %{
      "name" => @progress_tool,
      "description" =>
        "Tell the plan how the work on your task goes: its progress, its status, a short note, and the pull request you opened.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "itemId" => %{
            "type" => "string",
            "description" => "The task; the one this thread works on when left out."
          },
          "progress" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
          "status" => %{"type" => "string", "enum" => ~w(doing blocked done)},
          "note" => %{"type" => "string"},
          "pullRequest" => ref
        }
      }
    }
  end

  @impl HalC2.Plugins.Extension
  def call_agent_tool(@read_tool, arguments, %{thread_id: thread_id, settings: settings}) do
    if server({:tools, thread_id}).read or settings["offerToAllThreads"] == true,
      do: {:ok, server({:read, arguments["itemIds"]})},
      else: {:error, "This thread may not read the plan."}
  end

  def call_agent_tool(@report_tool, arguments, %{thread_id: thread_id, settings: settings}) do
    with {:ok, report} <- report(arguments),
         {:ok, run, effects} <- server({:report, thread_id, report}) do
      effects(effects, settings)

      {:ok,
       %{
         "reported" => true,
         "status" => run["status"],
         "next" =>
           case run["status"] do
             "applied" ->
               "The changes are applied to the plan."

             "proposed" ->
               "The proposal waits for the user to apply it. Do not change the plan another way."

             _ ->
               "The plan has what you reported."
           end
       }}
    end
  end

  def call_agent_tool(@progress_tool, arguments, %{thread_id: thread_id, settings: settings}) do
    with {:ok, progress} <- progress(arguments),
         {:ok, item, effects} <- server({:progress, thread_id, progress}) do
      effects(effects, settings)

      {:ok,
       %{
         "itemId" => item["id"],
         "status" => item["status"],
         "progress" => item["progress"],
         "next" => "The plan has it."
       }}
    end
  end

  def call_agent_tool(name, _arguments, _context), do: {:error, "planner has no tool #{name}."}

  # The agent's report, checked for its shape; the server checks it against the plan.
  defp report(arguments) do
    summary = arguments["summary"]
    changes = arguments["changes"] || []
    feedback = arguments["feedback"] || []

    cond do
      not is_binary(summary) or String.trim(summary) == "" ->
        {:error, "summary must say what you found."}

      arguments["health"] not in [nil | @healths] ->
        {:error, "health is one of #{Enum.join(@healths, ", ")}."}

      not is_list(changes) ->
        {:error, "changes is a list."}

      not is_list(feedback) or not Enum.all?(feedback, &feedback?/1) ->
        {:error, "each feedback has a text, and an itemId when it is about one task."}

      true ->
        {:ok,
         %{
           summary: String.trim(summary),
           health: arguments["health"],
           changes: changes,
           feedback:
             Enum.map(feedback, &%{"itemId" => &1["itemId"], "text" => String.trim(&1["text"])})
         }}
    end
  end

  defp feedback?(%{"text" => text} = feedback),
    do:
      is_binary(text) and String.trim(text) != "" and
        (is_nil(feedback["itemId"]) or is_binary(feedback["itemId"]))

  defp feedback?(_), do: false

  defp progress(arguments) do
    progress = arguments["progress"]

    taken =
      arguments
      |> Map.take(~w(itemId progress status note pullRequest))
      |> Map.reject(fn {_, v} -> is_nil(v) end)

    cond do
      not (is_nil(progress) or (is_number(progress) and progress >= 0 and progress <= 100)) ->
        {:error, "progress is a number from 0 to 100."}

      arguments["status"] not in [nil, "doing", "blocked", "done"] ->
        {:error, "status is doing, blocked or done."}

      not (is_nil(arguments["note"]) or is_binary(arguments["note"])) ->
        {:error, "note is text."}

      not (is_nil(arguments["pullRequest"]) or ref?(arguments["pullRequest"])) ->
        {:error, "pullRequest is {repository, number}."}

      Map.drop(taken, ["itemId"]) == %{} ->
        {:error, "Report a progress, a status, a note or a pull request."}

      true ->
        {:ok, taken}
    end
  end

  # --- what calls send on ----------------------------------------------------------------

  # A change to the plan, then what it sends on: its pushes to GitHub, each told back to
  # the server, and its posts to Slack. An item in the reply is read again after them.
  defp change(message, settings) do
    with {:ok, reply, effects} <- server(message) do
      effects(effects, settings)

      case reply do
        %{"item" => %{"id" => id}} when effects != %{} ->
          with {:ok, item} <- server({:item, id}), do: {:ok, %{reply | "item" => item}}

        _ ->
          {:ok, reply}
      end
    end
  end

  defp effects(effects, settings) do
    for {id, push, ops} <- Map.get(effects, :pushes, []) do
      {error, extra} = Sync.run(ops)
      server({:pushed, id, push, error, extra})
    end

    for post <- Map.get(effects, :posts, []), do: post(post, settings)
    :ok
  end

  # Posts to the plan's channel, if it has one; the server hears how it went.
  defp post(post, settings) do
    channel = String.trim(settings["slackChannel"] || "")

    if channel != "" do
      {update, text} =
        case post do
          {:update, id, text} -> {id, text}
          {:announce, text} -> {nil, text}
        end

      result =
        case slack("post", %{"channel" => channel, "text" => text}) do
          {:ok, posted} -> {:ok, Map.take(posted, ~w(channel ts))}
          {:error, error} -> {:error, message(error)}
        end

      server({:slack, update, result, System.monotonic_time()})
    end
  end

  # Answers a slash command, seen only by who ran it.
  defp command(event, settings) do
    actions = action_list(settings)

    text =
      case Slack.command(event["text"], actions) do
        :status ->
          %{"items" => items, "updates" => updates} = server(:plan)
          Slack.status(items, updates)

        {:run, action, title} ->
          case server({:run_titled, action["id"], title}) do
            {:ok, text} -> text
            {:several, items} -> Slack.tasks(title, action, items, settings["slackCommand"])
            {:error, error} -> error
          end

        {:ambiguous, word, several} ->
          Slack.ambiguous(word, several, settings["slackCommand"])

        {:unknown, word} ->
          Slack.actions(word, actions, settings["slackCommand"])
      end

    slack("respond", %{"responseUrl" => event["responseUrl"], "text" => text})
  end

  defp thread(thread_id) do
    case Host.thread(@id, thread_id) do
      {:ok, %{} = row} -> {:ok, %{"thread" => thread_id, "projectId" => row["projectId"]}}
      {:ok, nil} -> {:error, "There is no thread #{thread_id}."}
      {:error, error} -> {:error, message(error)}
    end
  end

  # The MC's Slack connection, which is not there at all when the MC has none.
  defp slack(method, input) do
    Host.slack(@id, method, input)
  catch
    :exit, _ -> {:error, @not_connected}
  end

  # --- server -----------------------------------------------------------------------------

  @impl GenServer
  def init(settings) do
    # Thread starts and looks are linked to the server, so stopping the plugin stops
    # them; the server itself only hears that one ended.
    Process.flag(:trap_exit, true)
    send(self(), :poll)

    {:ok,
     Map.merge(load(settings), %{
       settings: settings,
       problem: nil,
       unwatched: [],
       checked_at: nil,
       looked: nil,
       projects: [],
       slack: nil,
       slack_at: nil,
       polling: nil,
       published: %{},
       pushing: %{}
     }), {:continue, :announce}}
  end

  @impl GenServer
  def handle_continue(:announce, state), do: {:noreply, state |> pump() |> changed()}

  @impl GenServer
  def handle_call(:plan, _from, state), do: {:reply, plan(state), state}
  def handle_call(:runs, _from, state), do: {:reply, runs(state), state}
  def handle_call(:items, _from, state), do: {:reply, state.items, state}

  def handle_call({:item, id}, _from, state) do
    case state.items[id] do
      nil -> {:reply, {:error, "There is no task #{id}."}, state}
      item -> {:reply, {:ok, item}, state}
    end
  end

  def handle_call({:looked, found}, _from, state),
    do: {:reply, :ok, state |> apply_look(found) |> changed()}

  def handle_call({:add, fields}, _from, state) do
    case Plan.add(state.items, id("t"), fields, now()) do
      {:ok, items, item} ->
        {:reply, {:ok, %{"item" => item}, %{}}, changed(%{state | items: items})}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:update, id, fields}, _from, state) do
    case Plan.update(state.items, id, fields, now()) do
      {:ok, items, _old, item} -> edit(state, items, %{"item" => item})
      error -> {:reply, error, state}
    end
  end

  def handle_call({:remove, id}, _from, state) do
    if state.items[id],
      do: edit(state, Plan.remove(state.items, id), %{}),
      else: {:reply, {:error, "There is no task #{id}."}, state}
  end

  def handle_call({:move, id, parent, before}, _from, state) do
    case Plan.move(state.items, id, parent, before, now()) do
      {:ok, items} -> edit(state, items, %{})
      error -> {:reply, error, state}
    end
  end

  # A task stops holding up the milestone `from` and holds up `to` instead, both or
  # neither; either may be nil for no milestone.
  def handle_call({:to_milestone, id, from, to}, _from, state) do
    with %{} <- state.items[id] || {:error, "There is no task #{id}."},
         {:ok, items} <- hold_up(state.items, from, &List.delete(&1, id)),
         {:ok, items} <- hold_up(items, to, &Enum.uniq(&1 ++ [id])) do
      edit(state, items, %{})
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:save_view, view}, _from, state) do
    case Plan.check_view(view) do
      {:ok, view} ->
        view =
          if is_binary(view["id"]) and view["id"] != "",
            do: view,
            else: Map.put(view, "id", id("v"))

        views =
          if Enum.any?(state.views, &(&1["id"] == view["id"])),
            do: Enum.map(state.views, &if(&1["id"] == view["id"], do: view, else: &1)),
            else: state.views ++ [view]

        {:reply, {:ok, %{"view" => view}, %{}}, changed(%{state | views: views})}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:remove_view, id}, _from, state) do
    case Enum.split_with(state.views, &(&1["id"] == id)) do
      {[], _} -> {:reply, {:error, "There is no view #{id}."}, state}
      {_, views} -> {:reply, {:ok, %{}, %{}}, changed(%{state | views: views})}
    end
  end

  # The dates each task has now become the ones its slip is counted from.
  def handle_call({:baseline, on}, _from, state) do
    items =
      Map.new(state.items, fn {id, item} ->
        {id,
         Map.put(item, "baseline", if(on, do: %{"start" => item["start"], "due" => item["due"]}))}
      end)

    {:reply, {:ok, %{}, %{}}, changed(%{state | items: items})}
  end

  def handle_call({:post_update, health, text}, _from, state) do
    update = new_update(health, text, "user")
    effects = %{posts: [{:update, update["id"], Slack.update(update)}]}

    {:reply, {:ok, %{"update" => update}, effects},
     changed(%{state | updates: [update | state.updates]})}
  end

  # How a post to Slack, or the connection, went. Older news than the last is dropped.
  def handle_call({:slack, update_id, result, at}, _from, state) do
    if state.slack_at != nil and at < state.slack_at do
      {:reply, :ok, state}
    else
      state =
        case result do
          {:ok, posted} ->
            updates =
              Enum.map(
                state.updates,
                &if(&1["id"] == update_id, do: Map.put(&1, "slack", posted), else: &1)
              )

            %{state | slack: nil, slack_at: at, updates: updates}

          {:error, error} ->
            %{state | slack: error, slack_at: at}
        end

      {:reply, :ok, changed(state)}
    end
  end

  def handle_call({:slack_reply, parent, user, text}, _from, state) do
    if Enum.any?(state.updates, &(get_in(&1, ["slack", "ts"]) == parent)) do
      feedback = %{"id" => id("f"), "at" => now(), "text" => text, "by" => "slack:#{user}"}
      {:reply, :ok, changed(%{state | plan_feedback: state.plan_feedback ++ [feedback]})}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:run, action, item_ids, project}, _from, state),
    do: start_run(state, action, item_ids, project)

  # A slash command names its task by title, or by id when tasks share the title; the
  # answer is what its runner is told, or `{:several, tasks}` to ask which.
  def handle_call({:run_titled, action_id, title}, _from, state) do
    action = actions(state.settings)[action_id]
    wanted = String.downcase(title)
    titled = for {_, item} <- state.items, String.downcase(item["title"]) == wanted, do: item
    named = state.items[wanted]
    item = named || List.first(titled)

    cond do
      title != "" and item == nil ->
        {:reply, {:error, ~s(No task is called "#{title}".)}, state}

      title == "" and action["scope"] == "item" ->
        {:reply, {:error, "Name the task #{action["label"]} acts on."}, state}

      named == nil and length(titled) > 1 ->
        {:reply, {:several, Enum.sort_by(titled, &{&1["start"], &1["id"]})}, state}

      true ->
        case start_run(state, action_id, if(item, do: [item["id"]], else: []), nil) do
          {:reply, {:ok, _, _}, state} ->
            on = if item, do: item["title"], else: "the plan"
            {:reply, {:ok, "Started #{action["label"]} on #{on}."}, state}

          other ->
            other
        end
    end
  end

  def handle_call({:retry, id}, _from, state) do
    case state.runs[id] do
      %{"status" => "failed"} = run ->
        state = state |> put_run(queue(run)) |> pump() |> changed()
        {:reply, {:ok, %{"run" => state.runs[id]}, %{}}, state}

      nil ->
        {:reply, {:error, "There is no run #{id}."}, state}

      run ->
        {:reply,
         {:error,
          "The run of #{run["label"]} is #{run["status"]}; only a failed run is tried again."},
         state}
    end
  end

  def handle_call({:dismiss_change, id, change_id, dismissed}, _from, state) do
    case state.runs[id] do
      %{"status" => "proposed", "changes" => changes} = run ->
        if Enum.any?(changes, &(&1["id"] == change_id)) do
          changes =
            Enum.map(
              changes,
              &if(&1["id"] == change_id, do: Map.put(&1, "dismissed", dismissed), else: &1)
            )

          {:reply, {:ok, %{}, %{}}, state |> put_run(%{run | "changes" => changes}) |> changed()}
        else
          {:reply, {:error, "There is no change #{change_id} in the run of #{run["label"]}."},
           state}
        end

      nil ->
        {:reply, {:error, "There is no run #{id}."}, state}

      run ->
        {:reply, {:error, "The run of #{run["label"]} is #{run["status"]}; it proposes nothing."},
         state}
    end
  end

  def handle_call({:apply, id}, _from, state) do
    case state.runs[id] do
      %{"status" => "proposed"} = run ->
        before = state.items
        {state, posts} = apply_run(state, run)
        {pushes, state} = pushes(state, before, state.items)
        state = changed(state)
        {:reply, {:ok, %{"run" => state.runs[id]}, %{pushes: pushes, posts: posts}}, state}

      nil ->
        {:reply, {:error, "There is no run #{id}."}, state}

      run ->
        {:reply, {:error, "The run of #{run["label"]} is #{run["status"]}; it proposes nothing."},
         state}
    end
  end

  # A running run has a thread on the way; it is discarded once that is over.
  def handle_call({:discard, id}, _from, state) do
    case Map.pop(state.runs, id) do
      {nil, _} ->
        {:reply, {:error, "There is no run #{id}."}, state}

      {%{"status" => "running"} = run, _} ->
        {:reply, {:error, "The run of #{run["label"]} is running."}, state}

      {_run, runs} ->
        {:reply, {:ok, %{}, %{}}, %{state | runs: runs} |> pump() |> changed()}
    end
  end

  # Feedback on the plan itself has no task.
  def handle_call({:dismiss_feedback, nil, feedback_id}, _from, state) do
    case Enum.split_with(state.plan_feedback, &(&1["id"] == feedback_id)) do
      {[], _} -> {:reply, {:error, "There is no feedback #{feedback_id} on the plan."}, state}
      {_, kept} -> {:reply, {:ok, %{}, %{}}, changed(%{state | plan_feedback: kept})}
    end
  end

  def handle_call({:dismiss_feedback, item_id, feedback_id}, _from, state) do
    with %{} = item <- state.items[item_id],
         {[_ | _], kept} <- Enum.split_with(item["feedback"] || [], &(&1["id"] == feedback_id)) do
      {:reply, {:ok, %{}, %{}}, changed(put_in(state.items[item_id]["feedback"], kept))}
    else
      _ -> {:reply, {:error, "There is no feedback #{feedback_id} on #{item_id}."}, state}
    end
  end

  # How a push to GitHub went; a task removed since is left alone. Pushes run in their
  # callers, so they can finish out of order: only the task's latest push says whether
  # it synced and what it learnt, such as its board item. An older one may be for an
  # issue the task was unlinked from since; the next look reads the board again.
  def handle_call({:pushed, id, push, error, extra}, _from, state) do
    latest? = state.pushing[id] == push
    state = if latest?, do: %{state | pushing: Map.delete(state.pushing, id)}, else: state

    case state.items[id] do
      item when latest? and item != nil ->
        item = item |> Map.merge(extra) |> Map.put("syncError", error)
        {:reply, :ok, changed(put_in(state.items[id], item))}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:link, id, fields}, _from, state) do
    case state.items[id] do
      nil ->
        {:reply, {:error, "There is no task #{id}."}, state}

      item ->
        item =
          case fields do
            %{"thread" => thread} ->
              item
              |> Map.update("threads", [thread], &Enum.uniq(&1 ++ [thread]))
              |> Map.update!("projectId", &(&1 || fields["projectId"]))

            _ ->
              Plan.link(item, fields, now())
          end

        edit(state, Map.put(state.items, id, item), %{"item" => item})
    end
  end

  def handle_call({:unlink, id, kind, ref}, _from, state) do
    item = state.items[id]

    unlinked =
      case kind do
        _ when item == nil ->
          {:error, "There is no task #{id}."}

        "pullRequest" ->
          {:ok,
           Map.update!(
             item,
             "pullRequests",
             &Enum.reject(&1, fn pr -> Plan.same_ref?(pr, ref) end)
           )}

        "issue" ->
          {:ok, Map.merge(item, %{"issue" => nil, "boardItemId" => nil, "syncError" => nil})}

        "thread" ->
          {:ok, Map.update(item, "threads", [], &List.delete(&1, ref))}

        _ ->
          {:error, "unlink takes the kind pullRequest, issue or thread."}
      end

    # A task unlinked from its issue no longer hears from the pushes to it in flight.
    state = if kind == "issue", do: %{state | pushing: Map.delete(state.pushing, id)}, else: state

    case unlinked do
      {:ok, item} -> edit(state, Map.put(state.items, id, item), %{"item" => item})
      error -> {:reply, error, state}
    end
  end

  def handle_call({:tools, thread_id}, _from, state) do
    run = by_thread(state, thread_id)
    linked = Enum.any?(state.items, fn {_, item} -> thread_id in (item["threads"] || []) end)

    {:reply,
     %{
       read: run != nil or linked,
       report:
         run != nil and run["kind"] == "action" and run["status"] in ~w(running failed proposed),
       progress: (run != nil and run["kind"] == "work") or linked
     }, state}
  end

  def handle_call({:read, ids}, _from, state) do
    derived = Plan.derive(state.items, today())

    items =
      if is_list(ids) and ids != [], do: Enum.filter(derived, &(&1["id"] in ids)), else: derived

    {:reply, %{"today" => today(), "items" => items, "latestUpdate" => List.first(state.updates)},
     state}
  end

  # A report that does not fit the plan goes back to the agent to fix.
  def handle_call({:report, thread_id, report}, _from, state) do
    with %{} = run <-
           by_thread(state, thread_id) || {:error, "This thread is not a planner action."},
         true <-
           run["kind"] == "action" ||
             {:error, "This thread works on a task; tell the plan with #{@progress_tool}."},
         true <-
           run["status"] in ~w(running failed proposed) ||
             {:error, "The run of #{run["label"]} is #{run["status"]}; it takes no more reports."},
         {:ok, changes} <- Plan.check_changes(state.items, report.changes),
         :ok <- check_feedback(state.items, report.feedback) do
      {state, run, effects} = take_report(state, run, changes, report)
      {:reply, {:ok, run, effects}, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:progress, thread_id, progress}, _from, state) do
    run = by_thread(state, thread_id)
    linked = for {id, item} <- state.items, thread_id in (item["threads"] || []), do: id
    ids = Enum.uniq(linked ++ if(run, do: run["itemIds"], else: []))
    id = progress["itemId"] || List.first(ids)

    cond do
      ids == [] ->
        {:reply, {:error, "This thread works on no task of the plan."}, state}

      id not in ids or state.items[id] == nil ->
        {:reply,
         {:error, "This thread does not work on #{id}; it works on #{Enum.join(ids, ", ")}."},
         state}

      true ->
        case Plan.update(state.items, id, Map.take(progress, ~w(progress status)), now()) do
          {:ok, items, _old, item} ->
            item = if progress["note"], do: Map.put(item, "note", progress["note"]), else: item

            item =
              if progress["pullRequest"],
                do: Plan.link(item, %{"pullRequest" => progress["pullRequest"]}, now()),
                else: item

            items = Map.put(items, id, item)
            {pushes, state} = pushes(state, state.items, items)
            {:reply, {:ok, item, %{pushes: pushes}}, changed(%{state | items: items})}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl GenServer
  def handle_cast({:turn_finished, thread_id, status}, state) do
    case by_thread(state, thread_id) do
      # Work goes on in the thread as the user directs it; the run's part is over.
      %{"status" => "running", "kind" => "work"} = run ->
        run = Map.merge(run, %{"status" => "done", "finishedAt" => now()})
        {:noreply, state |> put_run(run) |> pump() |> changed()}

      %{"status" => "running"} = run ->
        error =
          if status == "completed",
            do:
              "The agent finished without reporting with #{@report_tool}. If it could not reach the tool, check that the project lets agents use HAL-C2's tools.",
            else: "The agent's turn ended (#{status}) before it reported."

        run = Map.merge(run, %{"status" => "failed", "error" => error, "finishedAt" => now()})
        {:noreply, state |> put_run(run) |> pump() |> changed()}

      _ ->
        {:noreply, state}
    end
  end

  # Only work whose thread started marks its task; work that could not start leaves it.
  def handle_cast({:started, id, thread_id}, state) do
    case state.runs[id] do
      %{"threadId" => ^thread_id, "kind" => "work"} = run ->
        {:noreply, state |> working(run) |> changed()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:start_failed, id, thread_id, message}, state) do
    case state.runs[id] do
      %{"threadId" => ^thread_id, "status" => "running"} = run ->
        run = Map.merge(run, %{"status" => "failed", "error" => message, "finishedAt" => now()})
        {:noreply, state |> put_run(run) |> pump() |> changed()}

      _ ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, %{polling: nil} = state) do
    server = self()
    settings = state.settings
    items = state.items
    # Linked, so turning the planner off calls off a look still waiting on GitHub.
    {_pid, ref} =
      Process.spawn(fn -> send(server, {:polled, look(settings, items)}) end, [:link, :monitor])

    {:noreply, %{state | polling: ref}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  # Changed even when GitHub had nothing new, so a new day reaches clients.
  def handle_info({:polled, found}, state),
    do: {:noreply, state |> apply_look(found) |> changed()}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{polling: ref} = state) do
    Process.send_after(self(), :poll, trunc(state.settings["pollMinutes"] * 60_000))

    state =
      if reason == :normal,
        do: %{state | polling: nil},
        else:
          %{state | polling: nil, problem: "Looking at GitHub failed: #{inspect(reason)}"}
          |> changed()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- looking at GitHub and Slack ----------------------------------------------------------

  # The look keeps the plan it read, so applying it can tell the tasks changed since.
  defp look(settings, items) do
    found = settings |> Sync.look(items) |> Map.put(:items, items)

    if String.trim(settings["slackChannel"] || "") != "",
      do: Map.put(found, :slack, connected?()),
      else: found
  end

  defp connected? do
    case slack("status", %{}) do
      {:ok, %{"connected" => true}} -> {:ok, nil}
      {:ok, _} -> {:error, @not_connected}
      {:error, error} -> {:error, message(error)}
    end
  end

  # A look that started before the one applied last is older news and is dropped.
  defp apply_look(%{looked: looked} = state, %{at: at}) when looked != nil and at < looked,
    do: state

  # A task changed since the look read the plan, by the user or a push GitHub took,
  # keeps its change: the look is older news about it, and the next one catches it up.
  defp apply_look(state, found) do
    kept = Map.filter(state.items, fn {id, item} -> found.items[id] != item end)

    items =
      state.items
      |> Sync.apply(found, state.settings, now(), fn -> id("t") end)
      |> Map.merge(kept)

    state = %{
      state
      | items: items,
        problem: found.problem,
        unwatched: found.unwatched,
        checked_at: now(),
        looked: found.at,
        projects: found.projects || state.projects
    }

    case found[:slack] do
      nil -> %{state | slack: nil}
      _ when state.slack_at != nil and found.at < state.slack_at -> state
      result -> %{state | slack: elem(result, 1), slack_at: found.at}
    end
  end

  # --- runs -------------------------------------------------------------------------------

  defp start_run(state, action_id, item_ids, project) do
    action = actions(state.settings)[action_id]
    item_ids = if is_list(item_ids), do: item_ids, else: [item_ids]
    items = Enum.map(item_ids, &state.items[&1])
    missing = Enum.find(Enum.zip(item_ids, items), &(elem(&1, 1) == nil))

    cond do
      action == nil ->
        {:reply, {:error, "There is no action #{action_id}."}, state}

      missing ->
        {:reply, {:error, "There is no task #{elem(missing, 0)}."}, state}

      action["scope"] == "item" and length(items) != 1 ->
        {:reply, {:error, "#{action["label"]} acts on one task; pick it."}, state}

      project = project(state, action, items, project) ->
        run =
          queue(%{
            "id" => id("r"),
            "action" => action_id,
            "label" => action["label"],
            "kind" => action["kind"],
            "apply" => action["apply"],
            "itemIds" => item_ids,
            "projectId" => project
          })

        state = state |> put_run(run) |> pump() |> changed()
        {:reply, {:ok, %{"run" => state.runs[run["id"]]}, %{}}, state}

      items != [] ->
        titles = Enum.map_join(items, ", ", & &1["title"])

        {:reply, {:error, "Give #{titles} a project or set a default project for the planner."},
         state}

      true ->
        {:reply, {:error, "Set a default project for the planner, or give its tasks a project."},
         state}
    end
  end

  # Where a run works: the project asked for, its tasks' project, the default project,
  # and for the whole plan the project most of its tasks are in.
  defp project(state, action, items, asked) do
    present = fn value -> if is_binary(value) and value != "", do: value end

    present.(asked) || Enum.find_value(items, &present.(&1["projectId"])) ||
      present.(state.settings["defaultProject"]) ||
      if action["scope"] == "plan" and items == [] do
        state.items
        |> Map.values()
        |> Enum.map(& &1["projectId"])
        |> Enum.filter(present)
        |> Enum.frequencies()
        |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)
        |> elem(0)
      end
  end

  defp queue(run) do
    Map.merge(run, %{
      "status" => "queued",
      "queuedAt" => now(),
      "threadId" => nil,
      "startedAt" => nil,
      "finishedAt" => nil,
      "error" => nil,
      "summary" => nil,
      "health" => nil,
      "changes" => [],
      "feedback" => []
    })
  end

  # Starts queued runs, oldest first, while fewer than `concurrency` run. A run whose
  # task was removed while it waited fails instead.
  defp pump(state) do
    {gone, queued} =
      state.runs
      |> Map.values()
      |> Enum.filter(&(&1["status"] == "queued"))
      |> Enum.split_with(fn run -> Enum.any?(run["itemIds"], &(state.items[&1] == nil)) end)

    state =
      Enum.reduce(gone, state, fn run, state ->
        error = "Its task was removed before it started."
        put_run(state, Map.merge(run, %{"status" => "failed", "error" => error, "finishedAt" => now()}))
      end)

    running = Enum.count(state.runs, fn {_, run} -> run["status"] == "running" end)

    queued
    |> Enum.sort_by(& &1["queuedAt"])
    |> Enum.take(max(trunc(state.settings["concurrency"] || 2) - running, 0))
    |> Enum.reduce(state, fn run, state ->
      run = Map.merge(run, %{"status" => "running", "threadId" => uuid(), "startedAt" => now()})
      derived = Plan.derive(state.items, today())
      on = for id <- run["itemIds"], item = Enum.find(derived, &(&1["id"] == id)), do: item
      values = Plan.values(derived, on, today(), nil)
      action = actions(state.settings)[run["action"]]
      settings = state.settings
      spawn_link(fn -> start(run, action, values, settings) end)
      put_run(state, run)
    end)
  end

  # The task work started on is in progress, and linked to the work's thread.
  defp working(state, run) do
    with [id | _] <- run["itemIds"], %{} = item <- state.items[id] do
      item =
        item
        |> Map.update!("status", &if(&1 in ~w(todo blocked), do: "doing", else: &1))
        |> Map.update("threads", [run["threadId"]], &Enum.uniq(&1 ++ [run["threadId"]]))
        |> Map.put("updatedAt", now())

      put_in(state.items[id], item)
    else
      _ -> state
    end
  end

  # Starts the run's thread and tells the server whether it could.
  defp start(run, action, values, settings) do
    result =
      with %{} <-
             action ||
               {:error, "The action #{run["label"]} is no longer in the planner's settings."},
           {:ok, model} <- model(settings) do
        project =
          case Host.projects(@id) do
            {:ok, projects} -> Enum.find(projects, &(&1["id"] == run["projectId"]))
            _ -> nil
          end

        values = Map.put(values, "project", (project || %{})["title"] || run["projectId"])
        work? = run["kind"] == "work"

        Host.launch_thread(
          @id,
          run["kind"],
          %{
            "threadId" => run["threadId"],
            "projectId" => run["projectId"],
            "title" => title(run, values),
            "modelSelection" => model,
            "runtimeMode" =>
              if(work?, do: settings["workRuntimeMode"], else: settings["runtimeMode"]),
            "interactionMode" => "default",
            "workspaceStrategy" =>
              if(work?,
                do: %{
                  "type" => "worktree",
                  "baseRef" => "HEAD",
                  "branch" => branch(values["item.title"]),
                  "startFromOrigin" => false
                },
                else: %{"type" => "root"}
              ),
            "initialMessage" => %{"text" => prompt(action, run, values), "attachments" => []}
          },
          listed: settings["display"] != "page"
        )
      end

    case result do
      {:ok, _} ->
        GenServer.cast(__MODULE__, {:started, run["id"], run["threadId"]})

      {:error, error} ->
        GenServer.cast(__MODULE__, {:start_failed, run["id"], run["threadId"], message(error)})
    end
  rescue
    e ->
      GenServer.cast(
        __MODULE__,
        {:start_failed, run["id"], run["threadId"], Exception.message(e)}
      )
  end

  defp model(settings) do
    instance = settings["provider"]
    model = String.trim(settings["model"] || "")

    if model != "" do
      {:ok, %{"instanceId" => instance, "model" => model}}
    else
      {:ok, providers} = Host.providers(@id)

      with %{"models" => models} <-
             Enum.find(providers, &(&1["instanceId"] == instance)) ||
               {:error, "There is no agent #{instance} on this MC."},
           %{"slug" => slug} <-
             Enum.find(models, & &1["isDefault"]) || List.first(models) ||
               {:error, "#{instance} has no models; pick one in the settings."} do
        {:ok, %{"instanceId" => instance, "model" => slug}}
      end
    end
  end

  defp title(%{"kind" => "work"}, values), do: values["item.title"]
  defp title(run, %{"item.title" => ""}), do: run["label"]
  defp title(run, values), do: "#{run["label"]}: #{values["item.title"]}"

  defp branch(title) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    "planner/#{if slug == "", do: "task", else: slug}-#{Base.encode16(:crypto.strong_rand_bytes(2), case: :lower)}"
  end

  @doc false
  # The first message of a run: the action's prompt filled in for its tasks, then how
  # to report, or for work how to tell the plan about it.
  def prompt(action, run, values) do
    how =
      if run["kind"] == "work",
        do:
          "Tell the plan how the work goes with the `planner_progress` tool of the hal-c2 MCP server: its progress (0 to 100), its status (doing, blocked or done), a short note, and the pull request you open as {repository, number}. The task is #{values["item.id"]}.",
        else: @report

    String.trim(Plan.fill(action["prompt"], values)) <> "\n\n" <> how
  end

  defp check_feedback(items, feedback) do
    case Enum.find(feedback, &(&1["itemId"] != nil and items[&1["itemId"]] == nil)) do
      nil -> :ok
      %{"itemId" => id} -> {:error, "feedback: there is no task #{id}."}
    end
  end

  # The report taken: feedback on a task lands at once, as a note rather than a change;
  # feedback on the plan goes into the summary. Changes wait for the user unless the
  # action applies them.
  defp take_report(state, run, changes, report) do
    at = now()
    on_plan = for %{"itemId" => nil, "text" => text} <- report.feedback, do: text

    run =
      Map.merge(run, %{
        "summary" => Enum.join([report.summary | on_plan], "\n\n"),
        "health" => report.health,
        "changes" => changes,
        "feedback" => report.feedback,
        "finishedAt" => at,
        "error" => nil
      })

    items =
      Enum.reduce(report.feedback, state.items, fn
        %{"itemId" => id, "text" => text}, items when is_binary(id) ->
          note = %{"id" => id("f"), "at" => at, "text" => text, "by" => run["id"]}
          update_in(items[id]["feedback"], &((&1 || []) ++ [note]))

        _, items ->
          items
      end)

    state = %{state | items: items}

    cond do
      changes == [] and report.health == nil ->
        run = Map.put(run, "status", "done")
        {state |> put_run(run) |> pump() |> changed(), run, %{}}

      run["apply"] == "apply" ->
        before = state.items
        {state, posts} = apply_run(state, run)
        {pushes, state} = pushes(state, before, state.items)
        state = state |> pump() |> changed()
        {state, state.runs[run["id"]], %{pushes: pushes, posts: posts}}

      true ->
        run = Map.put(run, "status", "proposed")
        state = state |> put_run(run) |> pump() |> changed()

        posts =
          if state.settings["slackAnnounce"] != false and changes != [],
            do: [{:announce, Slack.announce(run, touched(state.items, changes))}],
            else: []

        {state, run, %{posts: posts}}
    end
  end

  defp touched(items, changes) do
    changes
    |> Enum.map(&(get_in(items, [&1["itemId"], "title"]) || &1["fields"]["title"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  # The run's kept changes applied in order; a status update it carries joins the plan's.
  defp apply_run(state, run) do
    {items, changes} =
      Plan.apply_changes(state.items, run["changes"], now(), run["projectId"], fn _ -> id("t") end)

    run = Map.merge(run, %{"status" => "applied", "changes" => changes, "appliedAt" => now()})

    if run["health"] do
      update = new_update(run["health"], run["summary"], run["id"])

      {%{state | items: items, updates: [update | state.updates]} |> put_run(run),
       [{:update, update["id"], Slack.update(update)}]}
    else
      {%{state | items: items} |> put_run(run), []}
    end
  end

  defp new_update(health, text, by),
    do: %{
      "id" => id("u"),
      "at" => now(),
      "health" => health,
      "text" => text,
      "by" => by,
      "slack" => nil
    }

  # --- state ----------------------------------------------------------------------------

  # A change to items, answered with what to push to GitHub for the tasks it changed.
  defp edit(state, items, reply) do
    {pushes, state} = pushes(state, state.items, items)
    {:reply, {:ok, reply, %{pushes: pushes}}, changed(%{state | items: items})}
  end

  # What to push for the tasks `items` changed from `before`, each push with a token the
  # state keeps as its task's latest.
  defp pushes(state, before, items) do
    pushes =
      for {id, new} <- items,
          old = before[id],
          old != new,
          ops = Sync.pushes(state.settings, old, new, items),
          ops != [],
          do: {id, System.unique_integer([:monotonic]), ops}

    latest = Map.new(pushes, fn {id, push, _} -> {id, push} end)
    {pushes, %{state | pushing: Map.merge(state.pushing, latest)}}
  end

  defp put_run(state, run), do: put_in(state.runs[run["id"]], run)

  # Changes what the milestone `id` waits for with `fun`, nothing for no milestone.
  defp hold_up(items, nil, _fun), do: {:ok, items}

  defp hold_up(items, id, fun) do
    case items[id] do
      %{"kind" => "milestone", "after" => after_ids} ->
        with {:ok, items, _old, _new} <- Plan.update(items, id, %{"after" => fun.(after_ids)}, now()),
             do: {:ok, items}

      _ ->
        {:error, "There is no milestone #{id}."}
    end
  end

  defp by_thread(state, thread_id),
    do: Enum.find_value(state.runs, fn {_, run} -> if run["threadId"] == thread_id, do: run end)

  defp actions(settings), do: settings["actions"] || @default_actions

  # The actions in the order the plugin gives its own, then the user's by label.
  defp action_list(settings) do
    settings
    |> actions()
    |> Enum.map(fn {id, action} -> Map.put(action, "id", id) end)
    |> Enum.sort_by(
      &{Enum.find_index(@builtin, fn id -> id == &1["id"] end) || length(@builtin), &1["label"]}
    )
  end

  defp changed(state) do
    save(state)
    announce(state)
  end

  # What clients follow: `plan` for the Planner page, `runs` for its runs, and
  # `threads` for each run thread's mark and header. Each is sent only when it changes.
  defp announce(state) do
    published =
      for {topic, value} <- [
            {"plan", plan(state)},
            {"runs", runs(state)},
            {"threads", threads(state)}
          ],
          into: %{} do
        if value != state.published[topic], do: Host.publish(@id, topic, value)
        {topic, value}
      end

    %{state | published: published}
  end

  defp plan(state) do
    settings = state.settings
    channel = String.trim(settings["slackChannel"] || "")

    %{
      "items" => Plan.derive(state.items, today()),
      "views" => state.views,
      "updates" => Enum.take(state.updates, 50),
      "planFeedback" => state.plan_feedback,
      "today" => today(),
      "actions" => Enum.map(action_list(settings), &Map.take(&1, ~w(id label scope kind apply))),
      "projects" => Enum.map(state.projects, &Map.take(&1, ~w(id title repository))),
      "sync" => %{
        "repositories" => settings["repositories"] || [],
        "board" => settings["board"] || "",
        "mode" => settings["sync"],
        "problem" => state.problem,
        "unwatched" => state.unwatched,
        "checkedAt" => state.checked_at,
        "slack" => %{"channel" => if(channel != "", do: channel), "problem" => state.slack}
      }
    }
  end

  defp runs(state),
    do: %{
      "runs" => state.runs |> Map.values() |> Enum.sort_by(&{&1["queuedAt"], &1["id"]}, :desc)
    }

  defp threads(state) do
    for {_, %{"threadId" => thread} = run} <- state.runs, is_binary(thread), into: %{} do
      {thread,
       %{
         "runId" => run["id"],
         "kind" => run["kind"],
         "label" => run["label"],
         "status" => run["status"],
         "items" => for(id <- run["itemIds"], item = state.items[id], do: item["title"]),
         "changes" => Enum.count(run["changes"], &(not &1["dismissed"])),
         "health" => run["health"],
         "itemId" => if(run["kind"] == "work", do: List.first(run["itemIds"]))
       }}
    end
  end

  defp file, do: Path.join(Host.data_dir(@id), "plan.json")

  defp load(settings) do
    data =
      with {:ok, text} <- File.read(file()),
           {:ok, %{} = data} <- JSON.decode(text),
           do: data,
           else: (_ -> %{})

    # A run the plugin stopped during may still hear from its agent, whose turn may
    # also have ended while the plugin was not there to hear it.
    runs =
      Map.new(data["runs"] || %{}, fn
        {id, %{"status" => "running"} = run} ->
          {id,
           Map.merge(run, %{
             "status" => "failed",
             "error" =>
               "planner restarted while this ran; its agent can still report, or retry it.",
             "finishedAt" => now()
           })}

        entry ->
          entry
      end)

    # Board items belong to the board the plan was saved with. Under another board they
    # are forgotten, so a task's next date is pushed by adding it to the new board.
    items =
      if (data["board"] || "") == (settings["board"] || ""),
        do: data["items"] || %{},
        else:
          Map.new(data["items"] || %{}, fn {id, item} ->
            {id, Map.replace(item, "boardItemId", nil)}
          end)

    %{
      items: items,
      views: data["views"] || Plan.default_views(),
      updates: data["updates"] || [],
      plan_feedback: data["planFeedback"] || [],
      runs: runs
    }
  end

  defp save(state) do
    data = %{
      "items" => state.items,
      "views" => state.views,
      "updates" => state.updates,
      "planFeedback" => state.plan_feedback,
      "runs" => state.runs,
      "board" => state.settings["board"] || ""
    }

    tmp = file() <> ".tmp"
    File.write!(tmp, JSON.encode!(data))
    File.rename!(tmp, file())
  end

  # --- helpers -------------------------------------------------------------------------

  defp server(message), do: GenServer.call(__MODULE__, message, 30_000)

  # The plan's today. A test holds it on a day of its own with this application env.
  defp today,
    do: Application.get_env(:hal_c2, :planner_today) || Date.to_iso8601(Date.utc_today())

  defp repository?(value), do: is_binary(value) and value =~ ~r{^[\w.-]+/[\w.-]+$}
  defp board?(value), do: value == "" or (is_binary(value) and value =~ ~r{^[\w.-]+/\d+$})

  defp ref?(%{"repository" => repository, "number" => number}),
    do: is_binary(repository) and is_integer(number)

  defp ref?(_), do: false

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(message) when is_binary(message), do: message
  defp message(other), do: inspect(other)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp id(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      Enum.join(
        [
          binary_part(hex, 0, 8),
          binary_part(hex, 8, 4),
          binary_part(hex, 12, 4),
          binary_part(hex, 16, 4),
          binary_part(hex, 20, 12)
        ],
        "-"
      )
    end)
  end
end
