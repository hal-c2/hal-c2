defmodule HalC2Plugins.IssueTracker do
  @moduledoc """
  The issue tracker: the triage queue in front of the GitHub issues of the
  repositories it follows. Every few minutes it lists their open issues through
  the host and publishes them on the `tracker` topic with its runs.

  Three triage actions each run as a thread of the agent picked for them —
  prioritising a repository's queue, asking an issue's reporter for follow-up,
  and summarising an issue. A triage agent reports with the
  `issue_tracker_report` tool (`HalC2Plugins.IssueTracker.Triage` checks the
  report's shape); its report waits as a proposal, and only applying it asks
  GitHub for anything — priority labels, or the drafted comment. A report that
  proposes nothing to apply is `done` at once.

  Implementing an issue starts the implementing agent in a new worktree of the
  issue's project, asked to open a pull request that closes the issue. The last
  thread started for each issue is kept beside it.

  Runs and implementing threads are kept in `state.json` in the plugin's data
  directory. GitHub is asked outside the server: in a process of its own for
  looking, and in the caller of a call or tool otherwise. The server only keeps
  the last snapshot, the runs, and when to look next.
  """
  @behaviour HalC2.Plugins.Extension
  use GenServer

  alias HalC2.Plugins.Host
  alias HalC2Plugins.IssueTracker.Triage

  @id "issue-tracker"
  @read_tool "issue_tracker_read"
  @report_tool "issue_tracker_report"
  @runtime_modes ~w(approval-required auto-accept-edits auto full-access)
  @repository ~r{^[\w.-]+/[\w.-]+$}
  # action => {agent setting, prompt setting, run kind}
  @triage %{
    "prioritise" => {"prioritising", "prioritisePrompt"},
    "followUp" => {"followingUp", "followUpPrompt"},
    "summarise" => {"summarising", "summarisePrompt"}
  }
  @roles ~w(prioritising followingUp summarising implementing)
  @prompts ~w(prioritisePrompt followUpPrompt summarisePrompt implementPrompt)
  @kept_finished 50
  # An apply claim older than this is stale: its caller is gone or wedged.
  @stale_claim_ms 5 * 60_000

  # --- extension ------------------------------------------------------------------------

  @impl HalC2.Plugins.Extension
  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl HalC2.Plugins.Extension
  def validate_settings(settings) do
    repositories = settings["repositories"] || []

    cond do
      not (is_list(repositories) and
               Enum.all?(repositories, &(is_binary(&1) and Regex.match?(@repository, &1)))) ->
        {:error, "repositories: give each as owner/name."}

      not (is_number(settings["pollMinutes"]) and settings["pollMinutes"] >= 1) ->
        {:error, "pollMinutes: look at most once a minute."}

      role = Enum.find(@roles, &(not agent?(settings[&1]))) ->
        {:error, "#{role}: name the agent that runs it."}

      key = Enum.find(@prompts, &(String.trim(settings[&1] || "") == "")) ->
        {:error, "#{key}: the prompt cannot be empty."}

      not is_binary(settings["issueLabel"] || "") ->
        {:error, "issueLabel: give it as text."}

      true ->
        :ok
    end
  end

  defp agent?(%{"provider" => provider} = agent) when is_binary(provider) do
    String.trim(provider) != "" and is_binary(agent["model"] || "") and
      is_map(agent["modelOptions"] || %{}) and
      (agent["runtimeMode"] || "approval-required") in @runtime_modes
  end

  defp agent?(_agent), do: false

  @impl HalC2.Plugins.Extension
  def call("tracker", _input, _context), do: {:ok, GenServer.call(__MODULE__, :snapshot)}

  def call("refresh", _input, _context) do
    send(__MODULE__, :poll)
    {:ok, nil}
  end

  # What the settings page offers: the agents and models, this MC's projects and
  # the repositories of its GitHub projects.
  def call("settings", _input, context) do
    {:ok, providers} = Host.providers(@id)
    projects = projects()

    {:ok,
     %{
       "settings" => context.settings,
       "providers" => providers,
       "projects" => Enum.map(projects, &Map.take(&1, ~w(id title repository))),
       "repositories" =>
         for(
           %{"kind" => "github", "repository" => repository} <- projects,
           is_binary(repository),
           uniq: true,
           do: repository
         )
     }}
  end

  # One issue with its body, read from GitHub when the user opens it.
  def call("issue", %{"repository" => repository, "number" => number}, _context)
      when is_binary(repository) and is_integer(number) do
    with {:ok, project} <- host_project(repository),
         {:ok, issue} <-
           Host.issues(@id, "detail", %{
             "projectId" => project["id"],
             "repository" => repository,
             "number" => number
           }),
         do: {:ok, Map.merge(Triage.slim(issue), %{"body" => issue["body"]})}
  end

  def call("prioritise", %{"repository" => repository}, context)
      when is_binary(repository),
      do: triage("prioritise", repository, nil, context.settings)

  def call(action, %{"repository" => repository, "number" => number}, context)
      when action in ["followUp", "summarise"] and is_binary(repository) and is_integer(number),
      do: triage(action, repository, number, context.settings)

  def call("implement", %{"repository" => repository, "number" => number}, context)
      when is_binary(repository) and is_integer(number),
      do: implement(repository, number, context.settings)

  # Applying is the only triage path that asks GitHub for anything. The run is
  # claimed first (proposed → applying), so two applies cannot run at once and
  # a dismiss cannot land mid-apply. Each operation that reaches GitHub is
  # recorded on the run as it lands; a retry after a partial failure replays
  # only the rest, so nothing is posted or set twice. What could not be done
  # keeps the run proposed and names the issues that failed. A raise or exit
  # anywhere in here settles the same way — this caller is rescued by the
  # plugin host and stays alive, so the claim's monitor alone would strand it.
  def call("apply", %{"runId" => run_id}, _context) do
    with {:ok, run} <- GenServer.call(__MODULE__, {:claim_apply, run_id}) do
      try do
        done_before = run["done"] || []

        failures =
          case current_labels(run) do
            {:ok, current} ->
              run["report"]
              |> Triage.operations(current)
              |> Enum.reject(&(operation_tag(&1) in done_before))
              |> apply_operations(run_id)

            {:error, message} ->
              [{"reading the issues", message}]
          end

        case failures do
          [] ->
            {:ok, GenServer.call(__MODULE__, {:applied, run_id})}

          _ ->
            message =
              "Part of the proposal did not reach GitHub: " <>
                Enum.map_join(failures, "; ", fn {key, why} -> "#{key}: #{why}" end)

            GenServer.call(__MODULE__, {:apply_failed, run_id, message})
            {:error, message}
        end
      rescue
        e -> settle_raised(run_id, "Applying raised: " <> Exception.message(e))
      catch
        :exit, reason -> settle_raised(run_id, "Applying raised: " <> inspect(reason))
      end
    end
  end

  def call("discard", %{"runId" => run_id}, _context),
    do: GenServer.call(__MODULE__, {:discard, run_id})

  def call(method, _input, _context), do: {:error, "issue-tracker has no method #{method}."}

  # A thread this plugin started finished a turn: an unreported triage run fails,
  # and how an implementing thread went shows beside its issue.
  @impl HalC2.Plugins.Extension
  def handle_event(
        %{"type" => "turn.finished", "threadId" => thread_id, "status" => status},
        _context
      ),
      do: GenServer.cast(__MODULE__, {:finished, thread_id, status})

  def handle_event(_event, _context), do: :ok

  # --- agent tools ----------------------------------------------------------------------

  # Only threads this plugin started get its tools: every one of them may read,
  # and a triage run's own thread reports.
  @impl HalC2.Plugins.Extension
  def agent_tools(%{thread_id: thread_id}) when is_binary(thread_id) do
    case GenServer.call(__MODULE__, {:tools, thread_id}) do
      :none -> []
      :read -> [read_tool()]
      :report -> [read_tool(), report_tool()]
    end
  end

  def agent_tools(_context), do: []

  defp read_tool do
    %{
      "name" => @read_tool,
      "description" =>
        "Read the tracker's queue: the open issues it last saw (titles, authors, labels, milestones, what blocks them — no bodies), or one issue in full by its repository and number. Also gives today's date.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "repository" => %{"type" => "string", "description" => "Only this repository's queue."},
          "number" => %{
            "type" => "integer",
            "description" => "One issue in full; needs its repository too."
          }
        }
      }
    }
  end

  defp report_tool do
    %{
      "name" => @report_tool,
      "description" =>
        "Report what this triage run found. Nothing reaches GitHub from your report until the user applies it. Prioritising: rank the queue, each item with its priority and reason, in working order. Follow-up: one item for your issue, its comment the question to post (leave it out only when nothing is missing). Summarising: one item for your issue, its comment the summary, and duplicates the numbers of issues saying the same thing.",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["summary"],
        "properties" => %{
          "summary" => %{"type" => "string"},
          "items" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "required" => ["repository", "number"],
              "properties" => %{
                "repository" => %{"type" => "string"},
                "number" => %{"type" => "integer"},
                "priority" => %{"type" => "string", "enum" => Triage.priorities()},
                "labels" => %{"type" => "array", "items" => %{"type" => "string"}},
                "comment" => %{"type" => "string"},
                "reason" => %{"type" => "string"},
                "duplicates" => %{"type" => "array", "items" => %{"type" => "integer"}}
              }
            }
          }
        }
      }
    }
  end

  @impl HalC2.Plugins.Extension
  def call_agent_tool(@read_tool, arguments, %{thread_id: thread_id}) do
    cond do
      GenServer.call(__MODULE__, {:tools, thread_id}) == :none ->
        {:error, "This thread was not started by the issue tracker."}

      is_integer(arguments["number"]) and is_binary(arguments["repository"]) ->
        with {:ok, project} <- host_project(arguments["repository"]),
             {:ok, issue} <-
               Host.issues(@id, "detail", %{
                 "projectId" => project["id"],
                 "repository" => arguments["repository"],
                 "number" => arguments["number"]
               }),
             do: {:ok, Map.merge(Triage.slim(issue), %{"body" => issue["body"]})}

      true ->
        snapshot = GenServer.call(__MODULE__, :snapshot)

        issues =
          case arguments["repository"] do
            repository when is_binary(repository) ->
              Enum.filter(snapshot["issues"], &(&1["repository"] == repository))

            _ ->
              snapshot["issues"]
          end

        {:ok, %{"today" => today(), "issues" => issues}}
    end
  end

  def call_agent_tool(@report_tool, arguments, %{thread_id: thread_id}) do
    with {:ok, run} <- GenServer.call(__MODULE__, {:report, thread_id, arguments}) do
      {:ok,
       %{
         "reported" => true,
         "status" => run["status"],
         "next" =>
           if(run["status"] == "proposed",
             do:
               "The proposal waits for the user to apply it. Do not change the issue another way.",
             else: "The tracker has what you reported. Nothing was proposed to change."
           )
       }}
    end
  end

  def call_agent_tool(name, _arguments, _context),
    do: {:error, "issue-tracker has no tool #{name}."}

  # --- starting threads -----------------------------------------------------------------

  # A triage run: stored first, so its agent can report the moment it is ready,
  # then started in the repository's own project. It works in the project's
  # checkout as it stands (it only reads) and stays out of the thread list —
  # its proposal shows on the Issues page.
  defp triage(action, repository, number, settings) do
    {role, prompt_key} = @triage[action]
    thread_id = uuid()
    snapshot = GenServer.call(__MODULE__, :snapshot)

    run = %{
      "id" => uuid(),
      "action" => action,
      "repository" => repository,
      "number" => number,
      "threadId" => thread_id,
      "status" => "running",
      "createdAt" => System.system_time(:millisecond),
      "summary" => nil,
      "report" => nil,
      "done" => [],
      "error" => nil
    }

    with {:ok, project} <- project_for(repository),
         {:ok, values} <- triage_values(action, repository, number, snapshot, project),
         {:ok, model} <- model(settings[role]),
         run = Map.put(run, "title", values["threadTitle"]),
         {:ok, run} <- GenServer.call(__MODULE__, {:started, run}),
         {:ok, _} <-
           Host.launch_thread(
             @id,
             action,
             %{
               "threadId" => thread_id,
               "projectId" => project["id"],
               "title" => run["title"],
               "modelSelection" => model,
               "runtimeMode" => settings[role]["runtimeMode"] || "approval-required",
               "interactionMode" => "default",
               "workspaceStrategy" => %{"type" => "root"},
               "initialMessage" => %{
                 "text" => Triage.fill(settings[prompt_key], values) <> reporting(action, number),
                 "attachments" => []
               }
             },
             listed: false
           ) do
      {:ok, run}
    else
      {:error, message} ->
        GenServer.call(__MODULE__, {:start_failed, thread_id, message})
        {:error, message}
    end
  end

  # The fill-ins for a triage prompt. A per-issue action reads its issue in full
  # from GitHub; prioritising takes the queue as last seen.
  defp triage_values("prioritise", repository, _number, snapshot, _project) do
    issues = Enum.filter(snapshot["issues"], &(&1["repository"] == repository))

    {:ok,
     %{
       "threadTitle" => "Prioritise #{repository}",
       "repository" => repository,
       "issues" => Triage.queue_text(issues),
       "count" => to_string(length(issues)),
       "today" => today()
     }}
  end

  defp triage_values(action, repository, number, snapshot, project) do
    with {:ok, issue} <-
           Host.issues(@id, "detail", %{
             "projectId" => project["id"],
             "repository" => repository,
             "number" => number
           }) do
      others =
        snapshot["issues"]
        |> Enum.filter(&(&1["repository"] == repository and &1["number"] != number))
        |> Triage.queue_text()

      {:ok,
       %{
         "threadTitle" =>
           "#{if(action == "followUp", do: "Follow up on", else: "Summarise")} #{Triage.key(repository, number)}",
         "repository" => repository,
         "number" => to_string(number),
         "title" => issue["title"] || "",
         "author" => issue["author"] || "its reporter",
         "body" => issue["body"] || "(no body)",
         "labels" => Enum.join(issue["labels"] || [], ", "),
         "url" => issue["url"] || "",
         "others" => others,
         "today" => today()
       }}
    end
  end

  # How a triage agent reports, added after every triage prompt.
  defp reporting("prioritise", _number) do
    "\n\nReport with the #{@report_tool} tool: a summary, then items in the order the issues should be worked on, each with its repository, number, priority and a one-line reason. Do not change anything on GitHub yourself; the user applies your proposal."
  end

  defp reporting(action, number) do
    what =
      if action == "followUp",
        do:
          "its comment the follow-up question to post — leave the comment out only when nothing is missing, and say so in the summary",
        else: "its comment the summary, and duplicates naming any issue that says the same thing"

    "\n\nReport with the #{@report_tool} tool: a summary and one item for ##{number}, #{what}. Do not change anything on GitHub yourself; the user applies your proposal."
  end

  # Implementing is the tracker's one piece of real work: a listed thread in a
  # new worktree of the issue's project, on a branch named for the issue.
  defp implement(repository, number, settings) do
    key = "implement:" <> Triage.key(repository, number)
    thread_id = uuid()

    with {:ok, project} <- project_for(repository),
         {:ok, issue} <-
           Host.issues(@id, "detail", %{
             "projectId" => project["id"],
             "repository" => repository,
             "number" => number
           }),
         {:ok, model} <- model(settings["implementing"]),
         prompt =
           Triage.fill(settings["implementPrompt"], %{
             "repository" => repository,
             "number" => to_string(number),
             "title" => issue["title"] || "",
             "author" => issue["author"] || "",
             "body" => issue["body"] || "(no body)",
             "labels" => Enum.join(issue["labels"] || [], ", "),
             "url" => issue["url"] || "",
             "today" => today()
           }),
         {:ok, _} <-
           Host.launch_thread(@id, "implement", %{
             "threadId" => thread_id,
             "projectId" => project["id"],
             "title" => "Implement #{Triage.key(repository, number)} #{issue["title"]}",
             "modelSelection" => model,
             "runtimeMode" => settings["implementing"]["runtimeMode"] || "auto-accept-edits",
             "interactionMode" => "default",
             "workspaceStrategy" => %{
               "type" => "worktree",
               "baseRef" => "HEAD",
               "branch" => free_branch(project["root"], Triage.branch(number, issue["title"])),
               "startFromOrigin" => false
             },
             "initialMessage" => %{"text" => prompt, "attachments" => []}
           }) do
      {:ok, GenServer.call(__MODULE__, {:implementing, key, thread_id})}
    end
  end

  # The labels each issue of a proposal has now, read from GitHub so applying a
  # priority replaces the old one on what is there, not on a stale snapshot.
  defp current_labels(%{"report" => %{"items" => items}}) do
    Enum.reduce_while(items, {:ok, %{}}, fn item, {:ok, current} ->
      with {:ok, project} <- host_project(item["repository"]),
           {:ok, issue} <-
             Host.issues(@id, "detail", %{
               "projectId" => project["id"],
               "repository" => item["repository"],
               "number" => item["number"]
             }) do
        {:cont,
         {:ok,
          Map.put(current, Triage.key(item["repository"], item["number"]), issue["labels"] || [])}}
      else
        {:error, message} ->
          {:halt,
           {:error, "Reading #{Triage.key(item["repository"], item["number"])}: #{message}"}}
      end
    end)
  end

  defp current_labels(_run), do: {:ok, %{}}

  # What each failed operation was refused with. One that lands is recorded on
  # the run as it lands, so even an apply that raises partway has its done
  # operations kept where a retry can skip them.
  defp apply_operations(operations, run_id) do
    Enum.reduce(operations, [], fn operation, failures ->
      case apply_operation(operation) do
        :ok ->
          GenServer.cast(__MODULE__, {:op_done, run_id, operation_tag(operation)})
          failures

        {:error, message} ->
          [{operation_key(operation), message} | failures]
      end
    end)
    |> Enum.reverse()
  end

  # A raised apply settles as a failed one; if even settling exits (the server
  # is gone), the claim is reset when the plugin next starts.
  defp settle_raised(run_id, message) do
    GenServer.call(__MODULE__, {:apply_failed, run_id, message})
    {:error, message}
  catch
    :exit, _ -> {:error, message}
  end

  defp operation_key({_, repository, number, _}), do: Triage.key(repository, number)

  # An operation's identity across retries: setting an issue's labels once is
  # the same operation, as is posting its comment.
  defp operation_tag({kind, repository, number, _}),
    do: "#{kind}:#{Triage.key(repository, number)}"

  defp apply_operation({:labels, repository, number, labels}) do
    with {:ok, project} <- host_project(repository),
         {:ok, _} <-
           Host.issues(@id, "update", %{
             "projectId" => project["id"],
             "repository" => repository,
             "number" => number,
             "labels" => labels
           }),
         do: :ok
  end

  defp apply_operation({:comment, repository, number, text}) do
    with {:ok, project} <- host_project(repository),
         {:ok, _} <-
           Host.issues(@id, "comment", %{
             "projectId" => project["id"],
             "repository" => repository,
             "number" => number,
             "body" => text
           }),
         do: :ok
  end

  # This MC's projects, or none when the permission was not granted.
  defp projects do
    case Host.projects(@id) do
      {:ok, projects} -> projects
      _ -> []
    end
  end

  # The project whose remote is `repository` — needed to run agents on it and
  # to implement its issues.
  defp project_for(repository) do
    case Enum.find(
           projects(),
           &(String.downcase(&1["repository"] || "") == String.downcase(repository))
         ) do
      nil ->
        {:error,
         "No project on this MC has #{repository} as its remote. Add a checkout of it as a project."}

      project ->
        {:ok, project}
    end
  end

  # Any GitHub project serves reading and writing another repository's issues;
  # its own project is preferred.
  defp host_project(repository) do
    all = projects()

    found =
      Enum.find(all, &(String.downcase(&1["repository"] || "") == String.downcase(repository))) ||
        Enum.find(all, &(&1["kind"] == "github"))

    if found,
      do: {:ok, found},
      else: {:error, "No GitHub project is on this MC to read #{repository} through."}
  end

  # Implementing an issue again must not reuse the branch the first thread
  # took: the first name `git worktree add -b` can still take in this checkout.
  defp free_branch(root, base) do
    taken =
      case System.cmd("git", ["-C", root, "branch", "--format=%(refname:short)"],
             stderr_to_stdout: true
           ) do
        {out, 0} -> String.split(out, "\n", trim: true)
        _ -> []
      end

    Triage.free_branch(base, taken)
  rescue
    _ -> base
  end

  defp today, do: Date.utc_today() |> Date.to_iso8601()

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::62>>, case: :lower)

    Enum.map_join([{0, 8}, {8, 4}, {12, 4}, {16, 4}, {20, 12}], "-", fn {at, length} ->
      binary_part(hex, at, length)
    end)
  end

  # The model selection for an agent setting: the picked model with the options
  # it offers, else the agent's default model.
  defp model(agent) do
    instance = agent["provider"]
    wanted = String.trim(agent["model"] || "")
    chosen = agent["modelOptions"] || %{}
    {:ok, providers} = Host.providers(@id)

    case Enum.find(providers, &(&1["instanceId"] == instance)) do
      nil ->
        {:error, "There is no agent #{instance} on this MC; pick one in the settings."}

      %{"models" => models} ->
        found = Enum.find(models, &(&1["slug"] == wanted))

        cond do
          wanted != "" and found == nil ->
            {:ok,
             selection(
               instance,
               wanted,
               Enum.map(chosen, fn {id, v} -> %{"id" => id, "value" => v} end)
             )}

          model = found || Enum.find(models, & &1["isDefault"]) || List.first(models) ->
            {:ok, selection(instance, model["slug"], options(model["options"] || [], chosen))}

          true ->
            {:error, "#{instance} has no models; pick one in the settings."}
        end
    end
  end

  defp selection(instance, slug, []), do: %{"instanceId" => instance, "model" => slug}

  defp selection(instance, slug, options),
    do: %{"instanceId" => instance, "model" => slug, "options" => options}

  defp options(descriptors, chosen) do
    for descriptor <- descriptors,
        value = chosen[descriptor["id"]],
        value != nil,
        option?(descriptor, value),
        do: %{"id" => descriptor["id"], "value" => value}
  end

  defp option?(%{"type" => "boolean"}, value), do: is_boolean(value)

  defp option?(descriptor, value),
    do: is_binary(value) and Enum.any?(descriptor["options"] || [], &(&1["id"] == value))

  # --- server ---------------------------------------------------------------------------

  @impl GenServer
  def init(settings) do
    send(self(), :poll)
    saved = read_state()
    # An apply this process did not live to finish leaves its run claimed;
    # proposed again, its done operations still on it, is where a retry goes.
    runs =
      Enum.map(saved["runs"] || [], fn
        %{"status" => "applying"} = run -> Map.put(run, "status", "proposed")
        run -> run
      end)

    {:ok,
     %{
       settings: settings,
       looking: nil,
       timer: nil,
       runs: runs,
       claims: %{},
       snapshot: %{
         "repositories" => [],
         "issues" => [],
         "runs" => runs,
         "threads" => saved["threads"] || %{},
         "checkedAt" => nil,
         "looking" => true,
         "problem" => nil
       }
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call({:run, run_id}, _from, state) do
    case Enum.find(state.runs, &(&1["id"] == run_id)) do
      nil -> {:reply, {:error, "There is no run #{run_id}."}, state}
      run -> {:reply, {:ok, run}, state}
    end
  end

  def handle_call({:started, run}, _from, state) do
    state = put_runs(state, [run | state.runs])
    {:reply, {:ok, run}, state}
  end

  def handle_call({:start_failed, thread_id, message}, _from, state) do
    runs =
      Enum.map(state.runs, fn
        %{"threadId" => ^thread_id, "status" => "running"} = run ->
          run |> Map.put("status", "failed") |> Map.put("error", message)

        run ->
          run
      end)

    {:reply, :ok, put_runs(state, runs)}
  end

  def handle_call({:report, thread_id, arguments}, _from, state) do
    run = Enum.find(state.runs, &(&1["threadId"] == thread_id and &1["status"] == "running"))

    cond do
      run == nil and
          Enum.any?(state.runs, &(&1["threadId"] == thread_id)) ->
        {:reply, {:error, "This run has already reported."}, state}

      run == nil ->
        {:reply, {:error, "This thread is not a triage run of the issue tracker."}, state}

      true ->
        target =
          if run["action"] == "prioritise",
            do: %{"repository" => run["repository"]},
            else: %{"repository" => run["repository"], "number" => run["number"]}

        case Triage.report(arguments, run["action"], target) do
          {:ok, report} ->
            status = if Triage.applicable?(report), do: "proposed", else: "done"

            reported =
              run
              |> Map.put("status", status)
              |> Map.put("summary", report["summary"])
              |> Map.put("report", report)

            runs = Enum.map(state.runs, &if(&1["id"] == run["id"], do: reported, else: &1))
            {:reply, {:ok, reported}, put_runs(state, runs)}

          error ->
            {:reply, error, state}
        end
    end
  end

  # Claims a proposed run for applying: while it is `applying`, a second apply
  # and a dismiss are refused by their own status checks. The claiming caller
  # is monitored, so an apply whose caller dies releases the claim instead of
  # stranding the run; a claim gone stale can be taken over.
  def handle_call({:claim_apply, run_id}, {caller, _} = _from, state) do
    run = Enum.find(state.runs, &(&1["id"] == run_id))
    now = System.system_time(:millisecond)
    claim = state.claims[run_id]

    cond do
      run == nil ->
        {:reply, {:error, "There is no run #{run_id}."}, state}

      run["status"] == "proposed" ->
        claim(state, run, caller, now)

      (run["status"] == "applying" and claim) && now - claim.at > @stale_claim_ms ->
        claim(state, run, caller, now)

      true ->
        {:reply, {:error, "That run is #{run["status"]}, not proposed."}, state}
    end
  end

  # Only the claim's holder settles it: after a stale takeover the original
  # caller is still alive, and its late settle must not release the new claim
  # or flip the run's status under the apply now running.
  def handle_call({:applied, run_id}, {caller, _} = _from, state) do
    if holder?(state, run_id, caller) do
      run =
        change_run(state, run_id, fn run ->
          run |> Map.put("status", "applied") |> Map.put("error", nil)
        end)

      state = state |> release_claim(run_id) |> put_runs(replaced(state.runs, run))
      {:reply, run, state}
    else
      {:reply, Enum.find(state.runs, &(&1["id"] == run_id)), state}
    end
  end

  def handle_call({:apply_failed, run_id, message}, {caller, _} = _from, state) do
    if holder?(state, run_id, caller) do
      run =
        change_run(state, run_id, fn run ->
          run |> Map.put("status", "proposed") |> Map.put("error", message)
        end)

      {:reply, :ok, state |> release_claim(run_id) |> put_runs(replaced(state.runs, run))}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:discard, run_id}, _from, state) do
    case Enum.find(state.runs, &(&1["id"] == run_id)) do
      nil ->
        {:reply, {:error, "There is no run #{run_id}."}, state}

      %{"status" => status} when status not in ["proposed", "done"] ->
        {:reply, {:error, "That run is #{status}; only a proposal can be dismissed."}, state}

      run ->
        run = Map.put(run, "status", "discarded")
        {:reply, {:ok, run}, put_runs(state, replaced(state.runs, run))}
    end
  end

  def handle_call({:implementing, key, thread_id}, _from, state) do
    thread = %{
      "threadId" => thread_id,
      "startedAt" => System.system_time(:millisecond),
      "status" => "running"
    }

    threads = Map.put(state.snapshot["threads"], key, thread)
    state = publish(state, %{"threads" => threads})
    write_state(state)
    {:reply, thread, state}
  end

  def handle_call({:tools, thread_id}, _from, state) do
    run = Enum.find(state.runs, &(&1["threadId"] == thread_id))

    implementing =
      Enum.any?(state.snapshot["threads"], fn {_key, thread} ->
        thread["threadId"] == thread_id
      end)

    offered =
      cond do
        run != nil -> :report
        implementing -> :read
        true -> :none
      end

    {:reply, offered, state}
  end

  defp holder?(state, run_id, caller) do
    case state.claims[run_id] do
      %{pid: ^caller} -> true
      _ -> false
    end
  end

  defp claim(state, run, caller, now) do
    state = release_claim(state, run["id"])
    ref = Process.monitor(caller)
    claims = Map.put(state.claims, run["id"], %{pid: caller, ref: ref, at: now})
    run = Map.put(run, "status", "applying")
    {:reply, {:ok, run}, put_runs(%{state | claims: claims}, replaced(state.runs, run))}
  end

  defp release_claim(state, run_id) do
    case state.claims[run_id] do
      nil ->
        state

      %{ref: ref} ->
        Process.demonitor(ref, [:flush])
        %{state | claims: Map.delete(state.claims, run_id)}
    end
  end

  # One operation of the claimed apply reached GitHub. Kept in memory until the
  # apply settles and writes the runs out; a crash in between replays at most
  # the operations since the last settle.
  def handle_cast({:op_done, run_id, tag}, state) do
    run =
      change_run(state, run_id, fn run ->
        Map.put(run, "done", Enum.uniq((run["done"] || []) ++ [tag]))
      end)

    {:noreply, %{state | runs: replaced(state.runs, run)}}
  end

  @impl GenServer
  def handle_cast({:finished, thread_id, status}, state) do
    runs =
      Enum.map(state.runs, fn
        %{"threadId" => ^thread_id, "status" => "running"} = run ->
          run
          |> Map.put("status", "failed")
          |> Map.put(
            "error",
            "The agent finished without reporting with #{@report_tool}. If it could not reach the tool, check that the project lets agents use HAL-C2's tools."
          )

        run ->
          run
      end)

    threads =
      Map.new(state.snapshot["threads"], fn
        {key, %{"threadId" => ^thread_id} = thread} -> {key, Map.put(thread, "status", status)}
        other -> other
      end)

    state = publish(%{state | runs: runs}, %{"runs" => runs, "threads" => threads})
    write_state(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, %{looking: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    server = self()
    settings = state.settings

    {_pid, ref} =
      Process.spawn(fn -> send(server, {:looked, look(settings)}) end, [:link, :monitor])

    {:noreply, publish(%{state | looking: ref, timer: nil}, %{"looking" => true})}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({:looked, found}, state), do: {:noreply, publish(state, found)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{looking: ref} = state) do
    timer = Process.send_after(self(), :poll, trunc(state.settings["pollMinutes"] * 60_000))
    changes = %{"looking" => false}

    changes =
      if reason == :normal,
        do: changes,
        else: Map.put(changes, "problem", "Looking failed: #{inspect(reason)}")

    {:noreply, publish(%{state | looking: nil, timer: timer}, changes)}
  end

  # The caller holding an apply claim died: its run is proposed again, the
  # operations it did reach GitHub with stayed on the run, so a retry is safe.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.claims, fn {_run_id, claim} -> claim.ref == ref end) do
      nil ->
        {:noreply, state}

      {run_id, _claim} ->
        run = change_run(state, run_id, &Map.put(&1, "status", "proposed"))

        {:noreply, state |> release_claim(run_id) |> put_runs(replaced(state.runs, run))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp change_run(state, run_id, change) do
    case Enum.find(state.runs, &(&1["id"] == run_id)) do
      nil -> nil
      run -> change.(run)
    end
  end

  defp replaced(runs, nil), do: runs
  defp replaced(runs, run), do: Enum.map(runs, &if(&1["id"] == run["id"], do: run, else: &1))

  # Finished runs beyond the latest few are dropped; running and proposed ones stay.
  defp put_runs(state, runs) do
    {open, finished} =
      Enum.split_with(runs, &(&1["status"] in ["running", "proposed", "applying"]))

    runs = open ++ Enum.take(finished, @kept_finished)
    state = publish(%{state | runs: runs}, %{"runs" => runs})
    write_state(state)
    state
  end

  defp publish(state, changes) do
    snapshot = Map.merge(state.snapshot, changes)
    Host.publish(@id, "tracker", snapshot)
    %{state | snapshot: snapshot}
  end

  defp state_path, do: Path.join(Host.data_dir(@id), "state.json")

  defp read_state do
    with {:ok, text} <- File.read(state_path()),
         {:ok, %{} = saved} <- JSON.decode(text),
         do: saved,
         else: (_ -> %{})
  end

  defp write_state(state) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{"runs" => state.runs, "threads" => state.snapshot["threads"]})
    )
  end

  # --- looking --------------------------------------------------------------------------

  # The followed repositories and their open issues as GitHub has them now. A
  # repository that cannot be read names itself in `problem` and keeps none of
  # its issues; the rest still list.
  defp look(settings) do
    all = projects()
    repositories = followed(settings, all)
    label = String.trim(settings["issueLabel"] || "")

    results =
      Enum.map(repositories, fn repository ->
        project =
          Enum.find(
            all,
            &(String.downcase(&1["repository"] || "") == String.downcase(repository))
          ) ||
            Enum.find(all, &(&1["kind"] == "github"))

        result =
          if project do
            input = %{
              "projectId" => project["id"],
              "repository" => repository,
              "state" => "open",
              "limit" => 200
            }

            input = if label == "", do: input, else: Map.put(input, "labels", [label])
            Host.issues(@id, "list", input)
          else
            {:error, "no GitHub project is on this MC to read it through"}
          end

        {repository, project, result}
      end)

    problems =
      for {repository, _project, {:error, message}} <- results,
          do: "#{repository} could not be read: #{message}"

    %{
      "repositories" =>
        for {repository, project, result} <- results do
          %{
            "repository" => repository,
            "project" => if(project && project["repository"] == repository, do: project["title"]),
            "truncated" => match?({:ok, %{"truncated" => true}}, result)
          }
        end,
      "issues" =>
        Enum.flat_map(results, fn
          {_repository, _project, {:ok, %{"issues" => issues}}} ->
            Enum.map(issues, &Triage.slim/1)

          _ ->
            []
        end),
      "checkedAt" => System.system_time(:millisecond),
      "problem" => if(problems == [], do: nil, else: Enum.join(problems, " "))
    }
  end

  # The chosen repositories, or every GitHub project's when none were chosen.
  defp followed(settings, projects) do
    case settings["repositories"] || [] do
      [] ->
        for %{"kind" => "github", "repository" => repository} <- projects,
            is_binary(repository),
            uniq: true,
            do: repository

      repositories ->
        repositories
    end
  end
end
