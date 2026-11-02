defmodule HalC2Plugins.Maintenance do
  @moduledoc """
  Repository maintenance: the `maintain` skill run by an agent on the repositories
  it follows, on a schedule or when asked, with the user deciding what reaches
  GitHub.

  Each run is a thread of the `maintenance` kind in the repository's project. In
  report mode it works in the project's checkout and changes nothing; in fix mode
  it works in a new worktree on a `maintenance/<date>` branch, committing one
  category at a time behind the repository's own gates. Its agent ends with the
  `maintenance_report` tool (`HalC2Plugins.Maintenance.Report` checks the report
  and redacts it); the report is the pull request's body. What a run does after
  reporting is publishing's choice: keep the branch in HAL-C2, wait for the user to
  open the pull request, or open it at once. Only this plugin pushes and opens it,
  never the agent, and never from or to the default branch.

  Runs and the last schedule slot handled per repository are kept in `state.json`
  in the plugin's data directory (`HalC2Plugins.Maintenance.Schedule` says when a
  slot is due, `HalC2Plugins.Maintenance.Runs` how a run moves). GitHub, git and
  the host's threads are asked outside the server, in the caller of a call or tool
  or a process of its own; the server only keeps the runs and when to look next.
  """
  @behaviour HalC2.Plugins.Extension
  use GenServer

  alias HalC2.Plugins.Host
  alias HalC2Plugins.Maintenance.{Report, Runs, Schedule}

  @id "maintenance"
  @kind "maintenance"
  @report_tool "maintenance_report"
  @repository ~r{^[\w.-]+/[\w.-]+$}
  @kept_finished 50
  # How long the server sleeps at most between looking at the schedule: a clock
  # change or a daylight saving shift costs at most this much delay.
  @tick_ms 60 * 60_000
  @skill Path.expand("../skill/SKILL.md", __DIR__)
  # A repository's own copy of the skill, preferred over the one shipped here.
  @own_skills [".agents/skills/maintain/SKILL.md", ".claude/skills/maintain/SKILL.md"]

  # --- extension ------------------------------------------------------------------------

  @impl HalC2.Plugins.Extension
  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  # A save reaches the running server, so runs under way keep going.
  @impl HalC2.Plugins.Extension
  def settings_changed(pid, settings, _old), do: GenServer.call(pid, {:settings, settings})

  @impl HalC2.Plugins.Extension
  # Choices are checked by the host against plugin.json; these are what it cannot check.
  def validate_settings(settings) do
    repositories = settings["repositories"] || []
    categories = settings["categories"] || []
    instructions = settings["instructions"] || %{}

    cond do
      not (is_list(repositories) and
               Enum.all?(repositories, &(is_binary(&1) and Regex.match?(@repository, &1)))) ->
        {:error, "repositories: give each as owner/name."}

      settings["schedule"] != "manual" and not Schedule.time?(settings["time"]) ->
        {:error, "time: give the time of day as HH:MM, such as 06:00."}

      not (is_list(categories) and categories != [] and
               Enum.all?(categories, &(&1 in Report.categories()))) ->
        {:error, "categories: pick from #{Enum.join(Report.categories(), ", ")}."}

      not is_boolean(settings["securityOnly"] || false) ->
        {:error, "securityOnly: on or off."}

      not (is_binary(settings["provider"]) and String.trim(settings["provider"]) != "") ->
        {:error, "provider: name the agent that runs maintenance."}

      not is_binary(settings["model"] || "") ->
        {:error, "model: give it as text, or leave it empty for the agent's default."}

      not is_map(settings["modelOptions"] || %{}) ->
        {:error, "modelOptions: give an object such as {\"effort\": \"high\"}."}

      not (is_number(settings["concurrency"]) and settings["concurrency"] >= 1) ->
        {:error, "concurrency: at least one run at once."}

      String.trim(settings["prompt"] || "") == "" ->
        {:error, "prompt: the prompt cannot be empty."}

      not (is_map(instructions) and
               Enum.all?(instructions, fn {repo, text} ->
                 Regex.match?(@repository, repo) and is_binary(text)
               end)) ->
        {:error, "instructions: give an object of owner/name to text."}

      true ->
        :ok
    end
  end

  @impl HalC2.Plugins.Extension
  def call("maintenance", _input, _context), do: {:ok, GenServer.call(__MODULE__, :snapshot)}

  # What the settings page offers: the agents and models, and the repositories of
  # this MC's GitHub projects, the ones a run can start in.
  def call("settings", _input, context) do
    {:ok, providers} = Host.providers(@id)

    {:ok,
     %{
       "settings" => context.settings,
       "providers" => providers,
       "repositories" =>
         for(
           %{"repository" => repository} <- projects(),
           uniq: true,
           do: repository
         )
     }}
  end

  # Run now, and rerun: a new run of the repository with the settings as they are.
  def call("run", %{"repository" => repository}, context) when is_binary(repository),
    do: start(repository, "manual", context.settings)

  # The run is cancelled before its agent is stopped, so a report it races in with
  # is refused rather than kept.
  def call("cancel", %{"runId" => run_id}, _context) when is_binary(run_id) do
    with {:ok, run} <- GenServer.call(__MODULE__, {:cancel, run_id}) do
      try do
        Host.stop_thread(@id, run["threadId"])
      catch
        :exit, _ -> :ok
      end

      {:ok, run}
    end
  end

  def call("dismiss", %{"runId" => run_id}, _context) when is_binary(run_id),
    do: GenServer.call(__MODULE__, {:dismiss, run_id})

  def call("publish", %{"runId" => run_id}, _context) when is_binary(run_id) do
    with {:ok, run} <- GenServer.call(__MODULE__, {:claim, run_id}), do: publish(run)
  end

  def call(method, _input, _context), do: {:error, "maintenance has no method #{method}."}

  # A run's turn ended: one that never reported failed, and its thread is settled
  # so it leaves the working part of the sidebar. One stopped at a usage limit is
  # left running and unsettled, for the MC to resume once the limit resets.
  @impl HalC2.Plugins.Extension
  def handle_event(%{"type" => "turn.finished", "threadId" => thread_id} = event, _context) do
    if GenServer.call(__MODULE__, {:finished, thread_id, event["error"], event["errorClass"]}) ==
         :ours,
       do: organize(thread_id, %{"settled" => true})

    :ok
  end

  def handle_event(_event, _context), do: :ok

  # --- agent tools ----------------------------------------------------------------------

  @impl HalC2.Plugins.Extension
  def agent_tools(%{thread_id: thread_id}) when is_binary(thread_id) do
    if GenServer.call(__MODULE__, {:ours?, thread_id}), do: [report_tool()], else: []
  end

  def agent_tools(_context), do: []

  defp report_tool do
    item = fn required, properties ->
      %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => required,
          "properties" => Map.new(properties, &{&1, %{"type" => "string"}})
        }
      }
    end

    %{
      "name" => @report_tool,
      "description" =>
        "Report this maintenance run, once, at its end, even when nothing changed. Your report becomes the pull request body. Give a summary, one entry per category of the run with what you applied (each commit's title and sha), what you deferred (the item, why, and the command a human would run) and findings to discuss, and the gate you ran with its result. Summarise tool output; never include tokens or keys.",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["summary", "categories", "gate"],
        "properties" => %{
          "summary" => %{"type" => "string"},
          "categories" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "required" => ["category"],
              "properties" => %{
                "category" => %{"type" => "string", "enum" => Report.categories()},
                "applied" => item.(["title"], ["title", "commit"]),
                "deferred" => item.(["item", "reason"], ["item", "reason", "command"]),
                "findings" => %{"type" => "array", "items" => %{"type" => "string"}}
              }
            }
          },
          "gate" => %{
            "type" => "object",
            "required" => ["result"],
            "properties" => %{
              "command" => %{"type" => "string"},
              "result" => %{"type" => "string", "enum" => Report.results()},
              "details" => %{"type" => "string"}
            }
          }
        }
      }
    }
  end

  @impl HalC2.Plugins.Extension
  def call_agent_tool(@report_tool, arguments, %{thread_id: thread_id}) do
    with {:ok, run} <- GenServer.call(__MODULE__, {:report, thread_id, arguments}) do
      run = if run["status"] == "publishing", do: published_now(run), else: run
      {:ok, %{"reported" => true, "status" => run["status"], "next" => next(run)}}
    end
  end

  def call_agent_tool(name, _arguments, _context),
    do: {:error, "maintenance has no tool #{name}."}

  # An automatic run is published by the agent's own report call, so the agent
  # hears how it went.
  defp published_now(run) do
    case publish(run) do
      {:ok, run} -> run
      {:error, message} -> Map.merge(run, %{"status" => "waiting", "publishError" => message})
    end
  end

  defp next(%{"status" => "published", "prUrl" => url}),
    do: "The pull request is open: #{url}. You are done; do not push or change it."

  defp next(%{"status" => "waiting", "publishError" => error}) when is_binary(error),
    do:
      "Opening the pull request failed (#{error}). The user can retry from the Maintenance page. Do not push or open it yourself."

  defp next(%{"status" => "waiting"}),
    do:
      "Your branch waits for the user to open its pull request. Do not push or open it yourself."

  defp next(%{"status" => "kept"}),
    do: "Your branch stays in HAL-C2. Do not push it or open a pull request."

  defp next(_run), do: "The report is kept. You are done."

  # --- starting a run -------------------------------------------------------------------

  # A run of `repository`, in the caller: its project, then whether a maintenance
  # pull request is already open (the run is skipped), then the run is claimed
  # (refused while another holds the repository), then its thread starts.
  defp start(repository, trigger, settings) do
    thread_id = uuid()
    today = Date.to_iso8601(local_date())
    mode = settings["mode"]
    security_only = settings["securityOnly"] == true
    categories = if security_only, do: ["security-alerts"], else: ordered(settings["categories"])

    run = %{
      "id" => uuid(),
      "repository" => repository,
      "trigger" => trigger,
      "mode" => mode,
      "categories" => categories,
      "securityOnly" => security_only,
      "date" => today,
      "threadId" => thread_id,
      "status" => "running",
      "createdAt" => System.system_time(:millisecond),
      "error" => nil
    }

    with {:ok, project} <- project_for(repository),
         run = Map.put(run, "projectId", project["id"]),
         {:ok, open} <- open_maintenance(project, repository) do
      if open do
        GenServer.call(__MODULE__, {:skipped, skipped(run, open)})
      else
        launch(run, project, settings)
      end
    end
  end

  defp skipped(run, pr) do
    Map.merge(run, %{
      "status" => "skipped",
      "prUrl" => pr["url"],
      "error" =>
        "#{pr["url"] || "A maintenance pull request"} (#{pr["headBranch"]}) is still open. Merge or close it first.",
      "finishedAt" => System.system_time(:millisecond)
    })
  end

  defp launch(run, project, settings) do
    root = project["root"]

    {workspace, run} =
      if run["mode"] == "fix" do
        base = default_branch(root)
        branch = free_branch(root, "maintenance/" <> run["date"])

        {%{
           "type" => "worktree",
           "baseRef" => base,
           "branch" => branch,
           "startFromOrigin" => true
         }, Map.merge(run, %{"branch" => branch, "base" => base})}
      else
        {%{"type" => "root"}, Map.put(run, "base", default_branch(root))}
      end

    with {:ok, model} <- model(settings),
         {:ok, run} <- GenServer.call(__MODULE__, {:started, run, settings["concurrency"]}) do
      launched =
        try do
          Host.launch_thread(
            @id,
            @kind,
            %{
              "threadId" => run["threadId"],
              "projectId" => project["id"],
              "title" => "Maintain #{run["repository"]} #{run["date"]}",
              "modelSelection" => model,
              "runtimeMode" => settings["runtimeMode"],
              "interactionMode" => "default",
              "workspaceStrategy" => workspace,
              "initialMessage" => %{"text" => prompt(settings, run, root), "attachments" => []}
            },
            listed: true
          )
        rescue
          e -> {:error, Exception.message(e)}
        end

      case launched do
        {:ok, _} ->
          {:ok, run}

        {:error, error} ->
          message = message(error)
          GenServer.call(__MODULE__, {:start_failed, run["id"], message})
          {:error, message}
      end
    end
  end

  # The settings' prompt, then what the plugin requires of every run, which a
  # changed prompt cannot leave out.
  defp prompt(settings, run, root) do
    values = %{
      "repository" => run["repository"],
      "mode" => run["mode"],
      "categories" => Enum.join(run["categories"], ", "),
      "branch" => run["branch"] || "",
      "base" => run["base"] || "",
      "date" => run["date"],
      "skill" => skill(root)
    }

    own = String.trim((settings["instructions"] || %{})[run["repository"]] || "")

    ([fill(settings["prompt"], values)] ++
       if(own == "", do: [], else: ["Instructions for #{run["repository"]}:\n\n" <> own]) ++
       [guardrails(run)])
    |> Enum.join("\n\n")
  end

  defp guardrails(run) do
    categories = Enum.join(run["categories"], ", ")

    mode =
      if run["mode"] == "report" do
        [
          "This is a report run: change nothing. Do not edit files, commit, make branches or push. Everything you would apply goes in the report as deferred, with the command a human would run."
        ]
      else
        [
          "You work on the branch #{run["branch"]}, made from #{run["base"]}, in this worktree. Commit only on #{run["branch"]}. Never commit to, merge into or push #{run["base"]} or any other branch. Do not push at all, and do not open a pull request: HAL-C2 does that once the user decides.",
          "Make one commit per category, titled `chore(deps): …`, `fix(security): …`, `docs: …` or `test: …`. Commit a category only after the repository's own gates pass (its test, lint and typecheck commands, from its docs, CI configuration or task runner). An item that makes a gate fail is reverted and deferred, with why.",
          "Always defer major version bumps, and any dependency pinned with a comment saying why, to the report. Never apply them."
        ]
      end

    security =
      if run["securityOnly"],
        do: [
          "Security only: fix the repository's open security advisories and nothing else, each with the smallest upgrade that resolves it. Defer an advisory that needs a major bump."
        ],
        else: []

    rules =
      mode ++
        security ++
        [
          "Summarise scanner, audit and log output in your own words; never paste it raw. Never write tokens, keys, passwords or private key blocks into files, commits or the report.",
          "End by reporting with the #{@report_tool} tool, even when nothing changed: a summary, an entry for each category (#{categories}) with what you applied (commit title and sha), what you deferred (item, reason, and the command a human would run) and findings to discuss, and the gate you ran with its result. The report is the pull request's body."
        ]

    "Rules for this run:\n\n" <> Enum.map_join(rules, "\n", &("- " <> &1))
  end

  # The skill the agent follows: the repository's own when it has one, else the copy
  # shipped with this plugin.
  defp skill(root) do
    case Enum.find(@own_skills, &File.regular?(Path.join(root || "", &1))) do
      nil -> @skill
      own -> "#{own} (this repository's own)"
    end
  end

  defp fill(template, values) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn whole, key -> values[key] || whole end)
  end

  defp ordered(categories), do: Enum.filter(Report.categories(), &(&1 in (categories || [])))

  # An open pull request of the repository from a maintenance branch, or nil.
  defp open_maintenance(project, repository) do
    case Host.pull_requests(@id, "list", %{"projectIds" => [project["id"]], "state" => "open"}) do
      {:ok, list} ->
        case list["errors"] || [] do
          [] ->
            {:ok,
             Enum.find(list["entries"] || [], fn entry ->
               same?(entry["repository"], repository) and
                 String.starts_with?(entry["headBranch"] || "", "maintenance/")
             end)}

          errors ->
            {:error,
             "Could not look for an open maintenance pull request: " <>
               Enum.map_join(errors, " ", &(&1["message"] || inspect(&1)))}
        end

      {:error, error} ->
        {:error, "Could not look for an open maintenance pull request: " <> message(error)}
    end
  end

  # --- publishing -----------------------------------------------------------------------

  # Pushes a claimed run's branch and opens its pull request against its base,
  # with the report as the body, in the caller. Only a maintenance branch that is
  # checked out in the run's worktree and has commits on its base is pushed.
  defp publish(run) do
    result =
      try do
        with :ok <- writable(),
             {:ok, path} <- worktree(run),
             {:ok, _} <- branch_checked_out(path, run),
             {:ok, _} <- ahead(path, run),
             {:ok, _} <-
               git(path, ["push", "-u", "origin", "#{run["branch"]}:refs/heads/#{run["branch"]}"]),
             do: open_pull_request(path, run)
      rescue
        e -> {:error, "Opening the pull request raised: " <> Exception.message(e)}
      end

    case result do
      {:ok, url} ->
        GenServer.call(__MODULE__, {:published, run["id"], url})

      {:error, message} ->
        GenServer.call(__MODULE__, {:publish_failed, run["id"], message})
        {:error, message}
    end
  end

  defp writable do
    if Host.granted?(@id, "pullRequests:write"),
      do: :ok,
      else:
        {:error,
         "maintenance was not granted the permission to open pull requests (pullRequests:write)."}
  end

  defp worktree(run) do
    case Host.thread(@id, run["threadId"]) do
      {:ok, %{"worktreePath" => path}} when is_binary(path) and path != "" -> {:ok, path}
      {:ok, _} -> {:error, "The run's thread has no worktree any more."}
      error -> error
    end
  end

  defp branch_checked_out(path, %{"branch" => "maintenance/" <> _ = branch, "base" => base})
       when branch != base do
    case git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, ^branch} ->
        {:ok, branch}

      {:ok, other} ->
        {:error,
         "The worktree is on #{other}, not #{branch}. Check it out again to open the pull request."}

      error ->
        error
    end
  end

  defp branch_checked_out(_path, run),
    do: {:error, "#{run["branch"] || "No branch"} is not a maintenance branch; it is not pushed."}

  defp ahead(path, run) do
    base =
      if match?({:ok, _}, git(path, ["rev-parse", "--verify", "-q", "origin/#{run["base"]}"])),
        do: "origin/#{run["base"]}",
        else: run["base"]

    case git(path, ["rev-list", "--count", "#{base}..HEAD"]) do
      {:ok, "0"} -> {:error, "#{run["branch"]} has no commits on #{run["base"]}."}
      {:ok, count} -> {:ok, count}
      error -> error
    end
  end

  # The body goes on stdin, so no file of it is left behind.
  defp open_pull_request(path, run) do
    gh = System.find_executable(Application.get_env(:hal_c2, :gh_command, "gh")) || "gh"

    args = [
      "pr",
      "create",
      "--repo",
      run["repository"],
      "--base",
      run["base"],
      "--head",
      run["branch"],
      "--title",
      "chore: repository maintenance #{run["date"]}",
      "--body-file",
      "-"
    ]

    {out, code} =
      Exile.stream([gh | args], cd: path, input: [run["body"] || ""], stderr: :consume)
      |> Enum.reduce({"", nil}, fn
        {:exit, {:status, code}}, {out, _} -> {out, code}
        {_stream, data}, {out, code} -> {out <> IO.iodata_to_binary(data), code}
        _other, acc -> acc
      end)

    case {code, Regex.run(~r{https://\S+/pull/\d+}, out)} do
      {0, [url]} -> {:ok, url}
      {0, _} -> {:error, "gh opened no pull request: " <> said(out)}
      _ -> {:error, "gh pr create failed: " <> said(out)}
    end
  end

  defp git(cwd, args) do
    case System.cmd("git", args,
           cd: cwd,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, "git #{hd(args)} failed: " <> said(out)}
    end
  rescue
    e in [ErlangError, File.Error] -> {:error, "git #{hd(args)} failed: " <> Exception.message(e)}
  end

  defp said(out),
    do:
      out
      |> Report.redact()
      |> String.split("\n", trim: true)
      |> Enum.map_join(" ", &String.trim/1)

  # --- the repository -------------------------------------------------------------------

  # This MC's GitHub projects: what the settings offer, what the page lists a
  # repository's project from, and what a run starts in.
  defp projects do
    case Host.projects(@id) do
      {:ok, projects} ->
        Enum.filter(projects, &(&1["kind"] == "github" and is_binary(&1["repository"])))

      _ ->
        []
    end
  end

  # The project whose remote is `repository`: its runs work in it.
  defp project_for(repository, projects \\ projects()) do
    case Enum.find(projects, &same?(&1["repository"], repository)) do
      nil ->
        {:error,
         "No project on this MC has #{repository} as its remote. Add a checkout of it as a project."}

      project ->
        {:ok, project}
    end
  end

  defp same?(a, b), do: String.downcase(a || "") == String.downcase(b || "")

  # The branch origin's HEAD names, else the one checked out: what a fix run
  # branches from and opens its pull request against.
  defp default_branch(root) do
    case git(root, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) do
      {:ok, "origin/" <> branch} ->
        branch

      _ ->
        case git(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
          {:ok, branch} when branch != "HEAD" -> branch
          _ -> "main"
        end
    end
  end

  # A second run on the same day takes the next free name, `-2`, `-3`…
  defp free_branch(root, base) do
    taken =
      case git(root, ["branch", "--all", "--format=%(refname:short)"]) do
        {:ok, out} ->
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&String.replace_prefix(&1, "origin/", ""))

        _ ->
          []
      end

    Enum.find([base | Enum.map(2..99, &"#{base}-#{&1}")], base, &(&1 not in taken))
  end

  # Settles a thread of ours, best effort: an MC that did not grant it, or a thread
  # already gone, changes nothing else.
  defp organize(thread_id, changes) do
    Host.organize_thread(@id, thread_id, changes)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp message(error) when is_binary(error), do: error
  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(error), do: inspect(error)

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::62>>, case: :lower)

    Enum.map_join([{0, 8}, {8, 4}, {12, 4}, {16, 4}, {20, 12}], "-", fn {at, length} ->
      binary_part(hex, at, length)
    end)
  end

  defp local_now, do: NaiveDateTime.from_erl!(:calendar.local_time())
  defp local_date, do: NaiveDateTime.to_date(local_now())

  # When a local time is, in milliseconds since the epoch, for the page.
  defp epoch_ms(nil), do: nil

  defp epoch_ms(%NaiveDateTime{} = local) do
    case :calendar.local_time_to_universal_time_dst(NaiveDateTime.to_erl(local)) do
      [utc | _] ->
        utc
        |> NaiveDateTime.from_erl!()
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix(:millisecond)

      [] ->
        nil
    end
  end

  # The model selection: the picked model with the options it offers, else the
  # agent's default model.
  defp model(settings) do
    instance = settings["provider"]
    wanted = String.trim(settings["model"] || "")
    chosen = settings["modelOptions"] || %{}
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
    saved = read_state()
    runs = Enum.map(saved["runs"] || [], &Runs.revive/1)
    # Slots handled under another schedule say nothing about this one.
    slots =
      if saved["schedule"] in [nil, schedule_key(settings)], do: saved["slots"] || %{}, else: %{}

    send(self(), :tick)

    {:ok,
     %{settings: settings, runs: runs, slots: slots, pending: %{}, timer: nil, repositories: []}}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:settings, settings}, _from, state) do
    same = schedule_key(settings) == schedule_key(state.settings)
    slots = if same, do: state.slots, else: %{}
    # A start still pending gives back no slot of another schedule.
    pending = if same, do: state.pending, else: Map.new(state.pending, &{elem(&1, 0), nil})
    send(self(), :tick)
    {:reply, :ok, %{state | settings: settings, slots: slots, pending: pending}}
  end

  def handle_call({:ours?, thread_id}, _from, state),
    do: {:reply, Enum.any?(state.runs, &(&1["threadId"] == thread_id)), state}

  # A scheduled start stops pending once it is decided here. One refused only for
  # the runs at once gives its slot back, so the repository stays due rather than
  # failing, and starts when a run ends.
  def handle_call({:started, run, limit}, _from, state) do
    {previous, pending} =
      if run["trigger"] == "scheduled",
        do: Map.pop(state.pending, run["repository"], :none),
        else: {:none, state.pending}

    state = %{state | pending: pending}

    case started(run, limit, state) do
      {:busy, _message} when previous != :none ->
        slots = Map.put(state.slots, run["repository"], previous)
        state = %{state | slots: slots}
        write_state(state)
        {:reply, {:error, :later}, state}

      {:busy, message} ->
        {:reply, {:error, message}, state}

      {:ok, run} ->
        {:reply, {:ok, run}, put_runs(state, [run | state.runs])}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:skipped, run}, _from, state),
    do:
      {:reply, {:ok, run},
       put_runs(%{state | pending: unpending(state.pending, run)}, [run | state.runs])}

  def handle_call({:start_failed, run_id, message}, _from, state) do
    state =
      change(state, run_id, fn run ->
        {:ok,
         Map.merge(run, %{
           "status" => "failed",
           "error" => message,
           "finishedAt" => System.system_time(:millisecond)
         })}
      end)
      |> elem(1)

    {:reply, :ok, state}
  end

  def handle_call({:report, thread_id, arguments}, _from, state) do
    case Enum.find(state.runs, &(&1["threadId"] == thread_id)) do
      nil ->
        {:reply, {:error, "This thread is not a maintenance run."}, state}

      run ->
        with :ok <- Runs.reportable(run),
             :ok <- unheld(state.runs, run),
             {:ok, report} <- Report.check(arguments, run),
             {:ok, reported} <-
               Runs.reported(
                 run,
                 report,
                 Report.applied(report),
                 Report.markdown(report, run),
                 state.settings["publishing"]
               ) do
          {:reply, {:ok, reported}, put_runs(state, replaced(state.runs, reported))}
        else
          error -> {:reply, error, state}
        end
    end
  end

  def handle_call({:finished, thread_id, error, class}, _from, state) do
    case Enum.find(state.runs, &(&1["threadId"] == thread_id)) do
      nil ->
        {:reply, :theirs, state}

      run ->
        message =
          if is_binary(error) and error != "",
            do: "The agent stopped without reporting: #{error}",
            else:
              "The agent finished without reporting with #{@report_tool}. If it could not reach the tool, check that the project lets agents use HAL-C2's tools."

        {:ok, finished} = Runs.finished(run, message, class)

        state =
          if finished == run, do: state, else: put_runs(state, replaced(state.runs, finished))

        {:reply, if(Runs.working?(finished), do: :paused, else: :ours), state}
    end
  end

  def handle_call({:cancel, run_id}, _from, state), do: step(state, run_id, &Runs.cancel/1)
  def handle_call({:dismiss, run_id}, _from, state), do: step(state, run_id, &Runs.dismiss/1)
  def handle_call({:claim, run_id}, _from, state), do: step(state, run_id, &Runs.claim/1)

  def handle_call({:published, run_id, url}, _from, state),
    do: step(state, run_id, &Runs.published(&1, url))

  def handle_call({:publish_failed, run_id, message}, _from, state),
    do: step(state, run_id, &Runs.publish_failed(&1, message))

  # Whether `run` may start beside the runs there are: `{:busy, message}` when only
  # the runs at once keep it from starting.
  defp started(run, limit, state) do
    holding =
      Enum.find(state.runs, &(&1["repository"] == run["repository"] and Runs.holding?(&1)))

    working = Enum.count(state.runs, &Runs.working?/1)

    cond do
      holding && holding["status"] == "running" ->
        {:error, "#{run["repository"]} has a maintenance run going already."}

      holding ->
        {:error,
         "#{run["repository"]} has a maintenance run #{holding["status"]} for you; open its pull request or dismiss it first."}

      working >= (limit || 1) ->
        {:busy, "#{working} maintenance runs are going already; wait for one to finish."}

      true ->
        {:ok, run}
    end
  end

  # A run that failed and reports late: another run of its repository started since
  # keeps the repository.
  defp unheld(runs, run) do
    if run["status"] != "running" and
         Enum.any?(
           runs,
           &(&1["id"] != run["id"] and &1["repository"] == run["repository"] and
               Runs.holding?(&1))
         ),
       do:
         {:error,
          "Another maintenance run of #{run["repository"]} started after this one failed; your report is not kept. Stop here."},
       else: :ok
  end

  defp step(state, run_id, fun) do
    case change(state, run_id, fun) do
      {{:ok, run}, state} -> {:reply, {:ok, run}, state}
      {error, state} -> {:reply, error, state}
    end
  end

  # Applies `fun` to run `run_id`; a step that answers `{:ok, run}` is kept.
  defp change(state, run_id, fun) do
    case Enum.find(state.runs, &(&1["id"] == run_id)) do
      nil ->
        {{:error, "There is no maintenance run #{run_id}."}, state}

      run ->
        case fun.(run) do
          {:ok, changed} -> {{:ok, changed}, put_runs(state, replaced(state.runs, changed))}
          error -> {error, state}
        end
    end
  end

  # Starts the runs whose slot came, and sleeps until the next slot (or at most
  # `@tick_ms`). A repository seen for the first time takes the latest slot as
  # handled, so adding one or changing the schedule does not start a run at once;
  # a slot missed while the MC was down is a slot that came, and runs once.
  @impl GenServer
  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    settings = state.settings
    now = local_now()
    repositories = settings["repositories"] || []

    # A repository whose last run is still going or waiting for the user lets its
    # slot pass. Scheduled starts still on their way count toward the runs at once.
    room =
      (settings["concurrency"] || 1) - Enum.count(state.runs, &Runs.working?/1) -
        map_size(state.pending)

    {starting, slots} =
      Schedule.plan(settings, repositories, state.slots, now, &held?(state.runs, &1), room)

    pending = Enum.reduce(starting, state.pending, &Map.put(&2, &1, state.slots[&1]))

    for repository <- starting do
      Process.spawn(fn -> scheduled(repository, settings) end, [])
    end

    next = Schedule.next_slot(settings, now)

    wait =
      if next,
        do: min(max(NaiveDateTime.diff(next, now, :millisecond), 1_000), @tick_ms),
        else: @tick_ms

    timer = Process.send_after(self(), :tick, wait)

    projects = projects()

    listed =
      for repository <- repositories do
        last = Enum.find(state.runs, &(&1["repository"] == repository))

        %{
          "repository" => repository,
          "project" =>
            case project_for(repository, projects) do
              {:ok, project} -> project["title"]
              _ -> nil
            end,
          "nextRunAt" => epoch_ms(next),
          "lastRunAt" => last && last["createdAt"]
        }
      end

    state = %{state | slots: slots, pending: pending, timer: timer, repositories: listed}
    write_state(state)
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:scheduled_failed, run}, state),
    do:
      {:noreply, put_runs(%{state | pending: unpending(state.pending, run)}, [run | state.runs])}

  def handle_info(_message, state), do: {:noreply, state}

  # A scheduled run that cannot start is kept as a failed run, so the page says why.
  defp scheduled(repository, settings) do
    case start(repository, "scheduled", settings) do
      {:ok, _run} ->
        :ok

      # Refused for the runs at once: its slot is due again.
      {:error, :later} ->
        :ok

      {:error, message} ->
        send(__MODULE__, {:scheduled_failed, failed_start(repository, settings, message)})
    end
  rescue
    e ->
      send(
        __MODULE__,
        {:scheduled_failed, failed_start(repository, settings, Exception.message(e))}
      )
  end

  defp failed_start(repository, settings, message) do
    now = System.system_time(:millisecond)

    %{
      "id" => uuid(),
      "repository" => repository,
      "trigger" => "scheduled",
      "mode" => settings["mode"],
      "categories" => ordered(settings["categories"]),
      "securityOnly" => settings["securityOnly"] == true,
      "date" => Date.to_iso8601(local_date()),
      "threadId" => nil,
      "status" => "failed",
      "createdAt" => now,
      "finishedAt" => now,
      "error" => message
    }
  end

  defp unpending(pending, %{"trigger" => "scheduled", "repository" => repository}),
    do: Map.delete(pending, repository)

  defp unpending(pending, _run), do: pending

  defp held?(runs, repository),
    do: Enum.any?(runs, &(&1["repository"] == repository and Runs.holding?(&1)))

  defp schedule_key(settings), do: Map.take(settings, ~w(schedule weekday time))

  defp replaced(runs, run), do: Enum.map(runs, &if(&1["id"] == run["id"], do: run, else: &1))

  # Finished runs beyond the latest few are dropped; ones still going or waiting stay.
  defp put_runs(state, runs) do
    # A run that stopped working makes room for a scheduled one kept waiting.
    if Enum.count(runs, &Runs.working?/1) < Enum.count(state.runs, &Runs.working?/1),
      do: send(self(), :tick)

    {open, finished} =
      Enum.split_with(
        runs,
        &(&1["status"] in ~w(running waiting publishing kept) and &1["dismissed"] != true)
      )

    state = %{state | runs: open ++ Enum.take(finished, @kept_finished)}
    write_state(state)
    broadcast(state)
    state
  end

  defp snapshot(state) do
    %{
      "repositories" => state.repositories,
      "runs" =>
        Enum.reject(state.runs, &(&1["dismissed"] == true)) |> Enum.map(&Map.delete(&1, "body")),
      "schedule" => schedule_key(state.settings),
      "publishing" => state.settings["publishing"]
    }
  end

  @thread_fields ~w(id repository status mode branch base prUrl error publishError date)

  defp broadcast(state) do
    Host.publish(@id, "maintenance", snapshot(state))

    threads =
      for %{"threadId" => thread_id} = run when is_binary(thread_id) <- state.runs,
          into: %{},
          do: {thread_id, Map.take(run, @thread_fields)}

    Host.publish(@id, "threads", threads)
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
      JSON.encode!(%{
        "runs" => state.runs,
        "slots" => state.slots,
        "schedule" => schedule_key(state.settings)
      })
    )
  end
end
