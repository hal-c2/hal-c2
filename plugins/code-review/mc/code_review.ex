defmodule HalC2Plugins.CodeReview do
  @moduledoc """
  Agent code review. Looks at the repositories the user watches every few minutes,
  starts a review thread for each pull request that should be reviewed, takes the
  agent's verdict, summary and line comments through the `code_review_report` tool,
  and posts them as a review on the pull request when the publishing setting or the
  user says so.

  A review is `ready` (not started), `queued`, `running`, `failed`, `waiting` (to be
  published), `kept` (in HAL-C2 only) or `published`. Reviews are kept in
  `reviews.json` in the plugin's data directory and published for the UI parts: all
  of them on the `reviews` topic, and each review thread's review on `threads`.

  Reads from the host (gh) run outside the server process: in the RPC caller for a
  call, in a process of their own for the timer, so the server only decides.
  """
  @behaviour HalC2.Plugins.Extension
  use GenServer

  alias HalC2.Plugins.Host
  alias HalC2Plugins.CodeReview.Checkout

  @id "code-review"
  @tool "code_review_report"
  @modes ~w(local draft automatic)
  @verdicts ~w(approve comment request-changes)
  # The most of a repository's REVIEW.md that goes into the prompt; a longer one is left out.
  @review_md_limit 64 * 1024
  @choices %{
    "activation" => ~w(automatic selective),
    "display" => ~w(page threads both),
    "publishing" => @modes,
    "runtimeMode" => ~w(approval-required auto-accept-edits auto full-access)
  }

  @report """
  When you have reviewed the change, report your review with the `code_review_report` \
  tool of the hal-c2 MCP server. Nobody sees your review until you do, and only the \
  report counts, not your messages. Report once, with:

  - verdict: approve, comment or request-changes
  - summary: what the change does and what you found, written for its author
  - comments: one per finding on a line of the change, each with path (from the \
  repository root), line (in the new file, or for a removed line in the old file with \
  side "old") and body\
  """

  # --- extension ------------------------------------------------------------------------

  @impl HalC2.Plugins.Extension
  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl HalC2.Plugins.Extension
  def validate_settings(settings) do
    repos = settings["repositories"] || []
    by_repo = settings["publishingByRepository"] || %{}

    cond do
      settings["host"] != "github" ->
        {:error, "host: only GitHub can be reviewed so far; #{settings["host"]} is coming later."}

      bad = Enum.find(repos, &(not repository?(&1))) ->
        {:error, "repositories: #{inspect(bad)} is not owner/name."}

      key = Enum.find(Map.keys(@choices), &(settings[&1] not in @choices[&1])) ->
        {:error, "#{key}: #{inspect(settings[key])} is not one of #{Enum.join(@choices[key], ", ")}."}

      not is_map(by_repo) ->
        {:error, "publishingByRepository: give it as {\"owner/name\": \"draft\"}."}

      bad = Enum.find(by_repo, fn {repo, mode} -> not repository?(repo) or mode not in @modes end) ->
        {repo, mode} = bad

        {:error,
         "publishingByRepository: #{inspect(repo)} → #{inspect(mode)} needs owner/name and one of #{Enum.join(@modes, ", ")}."}

      not is_map(settings["instructions"] || %{}) or
          not Enum.all?(settings["instructions"] || %{}, fn {r, t} -> repository?(r) and is_binary(t) end) ->
        {:error, "instructions: give them as {\"owner/name\": \"text\"}."}

      not (is_number(settings["concurrency"]) and settings["concurrency"] >= 1) ->
        {:error, "concurrency: at least one review must be able to run."}

      not (is_number(settings["pollMinutes"]) and settings["pollMinutes"] >= 1) ->
        {:error, "pollMinutes: look at least once a minute apart."}

      not (is_number(settings["maxChangedLines"]) and settings["maxChangedLines"] >= 0) ->
        {:error, "maxChangedLines: give a number of lines, or 0 for no limit."}

      String.trim(settings["prompt"] || "") == "" ->
        {:error, "prompt: the review prompt cannot be empty."}

      String.trim(settings["provider"] || "") == "" ->
        {:error, "provider: name the agent that reviews."}

      true ->
        :ok
    end
  end

  @impl HalC2.Plugins.Extension
  def call("reviews", _input, _context), do: {:ok, server(:snapshot)}

  # What the settings page offers: the agents and models, and the repositories of
  # this MC's projects on the host.
  def call("settings", _input, context) do
    {:ok, providers} = Host.providers(@id)

    repositories =
      case Host.projects(@id) do
        {:ok, projects} ->
          for %{"kind" => kind, "repository" => repository} <- projects,
              kind == context.settings["host"] and is_binary(repository),
              uniq: true,
              do: repository

        _ ->
          []
      end

    {:ok, %{"settings" => context.settings, "providers" => providers, "repositories" => repositories}}
  end

  def call("refresh", _input, context) do
    server({:looked, look(context.settings, server(:reviews))})
    {:ok, server(:snapshot)}
  end

  def call("start", %{"repository" => repository, "number" => number}, context)
      when is_binary(repository) and is_integer(number) do
    known = server(:reviews)

    pr =
      case known[key(repository, number)] do
        nil -> find(context.settings, repository, number)
        review -> {:ok, review}
      end

    with {:ok, pr} <- pr, do: server({:start, pr, "user"})
  end

  def call("retry", %{"key" => key}, _context), do: server({:start, key, "retry"})

  def call("dismiss", %{"key" => key, "commentId" => id} = input, _context),
    do: server({:dismiss, key, id, input["dismissed"] != false})

  def call("discard", %{"key" => key}, _context) do
    with {:ok, review} <- server({:discard, key}) do
      if review["checkout"], do: Checkout.remove(review["root"], review["checkout"])
      {:ok, server(:snapshot)}
    end
  end

  # The post can take a while; the caller waits for GitHub's answer.
  def call("publish", %{"key" => key}, _context),
    do: GenServer.call(__MODULE__, {:publish, key}, 120_000)

  def call(method, _input, _context), do: {:error, "code-review has no method #{method}."}

  @impl HalC2.Plugins.Extension
  def handle_event(%{"type" => "turn.finished", "threadId" => thread_id, "status" => status}, _context),
    do: GenServer.cast(__MODULE__, {:turn_finished, thread_id, status})

  def handle_event(_event, _context), do: :ok

  @impl HalC2.Plugins.Extension
  def agent_tools(%{thread_id: thread_id}) when is_binary(thread_id) do
    case server({:for_thread, thread_id}) do
      {:ok, _review} ->
        [
          %{
            "name" => @tool,
            "description" =>
              "Report your code review of the pull request this thread reviews: a verdict, a summary, and comments on lines of the change. Nobody sees the review until you report it.",
            "inputSchema" => %{
              "type" => "object",
              "required" => ["verdict", "summary"],
              "properties" => %{
                "verdict" => %{"type" => "string", "enum" => @verdicts},
                "summary" => %{"type" => "string"},
                "comments" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "required" => ["path", "line", "body"],
                    "properties" => %{
                      "path" => %{"type" => "string"},
                      "line" => %{"type" => "integer", "minimum" => 1},
                      "side" => %{"type" => "string", "enum" => ["new", "old"]},
                      "body" => %{"type" => "string"}
                    }
                  }
                }
              }
            }
          }
        ]

      _ ->
        []
    end
  end

  def agent_tools(_context), do: []

  @impl HalC2.Plugins.Extension
  def call_agent_tool(@tool, arguments, %{thread_id: thread_id}) do
    with {:ok, review} <- server({:for_thread, thread_id}),
         {:ok, findings} <- findings(arguments, review),
         {:ok, review} <- server({:report, thread_id, findings}) do
      on_lines = Enum.count(review["comments"])

      {:ok,
       %{
         "reported" => true,
         "commentsOnLines" => on_lines,
         "commentsInSummary" => length(findings.general),
         "next" =>
           case review["status"] do
             "kept" -> "The review is kept in HAL-C2."
             "waiting" -> "The review waits for the user to publish it."
             _ -> "The review is being posted to the pull request."
           end
       }}
    end
  end

  def call_agent_tool(name, _arguments, _context), do: {:error, "code-review has no tool #{name}."}

  # --- server -----------------------------------------------------------------------------

  @impl GenServer
  def init(settings) do
    # Runs and posts are linked to the server, so stopping the plugin stops them; the
    # server itself only hears that one ended.
    Process.flag(:trap_exit, true)
    send(self(), :poll)

    {:ok,
     %{
       settings: settings,
       reviews: load(),
       problem: nil,
       unwatched: [],
       checked_at: nil,
       looked: nil,
       polling: nil,
       threads: nil
     }, {:continue, :announce}}
  end

  @impl GenServer
  def handle_continue(:announce, state), do: {:noreply, announce(state)}

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}
  def handle_call(:reviews, _from, state), do: {:reply, state.reviews, state}

  def handle_call({:looked, found}, _from, state) do
    {:reply, :ok, state |> apply_look(found) |> pump() |> changed()}
  end

  def handle_call({:start, key, trigger}, _from, state) when is_binary(key) do
    case state.reviews[key] do
      nil -> {:reply, {:error, "There is no review #{key}."}, state}
      # Two asks before either sees the other's leave one run.
      %{"status" => status} when status in ~w(queued running) -> {:reply, {:ok, nil}, state}
      review -> {:reply, {:ok, nil}, state |> queue(review, trigger) |> pump() |> changed()}
    end
    |> reply_snapshot()
  end

  def handle_call({:start, pr, trigger}, _from, state) do
    review = state.reviews[pr["key"]] || pr

    if review["status"] in ~w(queued running) do
      {:reply, {:ok, nil}, state} |> reply_snapshot()
    else
      {:reply, {:ok, nil}, state |> queue(review, trigger) |> pump() |> changed()}
      |> reply_snapshot()
    end
  end

  def handle_call({:dismiss, key, id, dismissed}, _from, state) do
    with %{} = review <- state.reviews[key],
         true <- Enum.any?(review["comments"] || [], &(&1["id"] == id)) do
      comments =
        Enum.map(review["comments"], &if(&1["id"] == id, do: Map.put(&1, "dismissed", dismissed), else: &1))

      {:reply, {:ok, nil}, state |> put(Map.put(review, "comments", comments)) |> changed()}
      |> reply_snapshot()
    else
      _ -> {:reply, {:error, "There is no comment #{id} on #{key}."}, state}
    end
  end

  # A running review has a thread and a checkout on the way, and one being
  # published a post in flight; it is discarded once that is over.
  def handle_call({:discard, key}, _from, state) do
    case Map.pop(state.reviews, key) do
      {nil, _} -> {:reply, {:error, "There is no review #{key}."}, state}
      {%{"status" => "running"}, _} -> {:reply, {:error, "The review of #{key} is running."}, state}
      {%{"status" => "publishing"}, _} -> {:reply, {:error, "The review of #{key} is being published."}, state}
      {review, reviews} -> {:reply, {:ok, review}, %{state | reviews: reviews} |> pump() |> changed()}
    end
  end

  def handle_call({:publish, key}, from, state) do
    case state.reviews[key] do
      # Reserved here, so two asks cannot both post it, and posted from a process
      # linked to this one, so turning the plugin off calls the post off.
      %{"status" => "waiting"} = review ->
        review = Map.merge(review, %{"status" => "publishing", "publishError" => nil})
        settings = state.settings
        spawn_link(fn -> GenServer.reply(from, publish(review, settings)) end)
        {:noreply, state |> put(review) |> changed()}

      %{"status" => "publishing"} ->
        {:reply, {:error, "The review of #{key} is being published."}, state}

      %{"status" => "kept"} ->
        {:reply, {:error, "The review of #{key} is kept in HAL-C2; its repository does not publish reviews."}, state}

      %{"status" => "published"} ->
        {:reply, {:error, "The review of #{key} is already published."}, state}

      %{} ->
        {:reply, {:error, "The review of #{key} has no findings to publish yet."}, state}

      nil ->
        {:reply, {:error, "There is no review #{key}."}, state}
    end
  end

  # How posting the review of `thread_id` went; a review run again since is left alone.
  def handle_call({:published, key, thread_id, error}, _from, state) do
    case state.reviews[key] do
      %{"status" => "publishing", "threadId" => ^thread_id} = review ->
        review =
          if error,
            do: Map.merge(review, %{"status" => "waiting", "publishError" => error}),
            else:
              Map.merge(review, %{
                "status" => "published",
                "publishError" => nil,
                "publishedAt" => now()
              })

        {:reply, :ok, state |> put(review) |> changed()}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:for_thread, thread_id}, _from, state) do
    case by_thread(state, thread_id) do
      %{"status" => "published"} -> {:reply, {:error, "This review is already published."}, state}
      %{"status" => "publishing"} -> {:reply, {:error, "This review is being published."}, state}
      %{} = review -> {:reply, {:ok, review}, state}
      nil -> {:reply, {:error, "This thread is not a code review."}, state}
    end
  end

  def handle_call({:report, thread_id, findings}, _from, state) do
    case by_thread(state, thread_id) do
      %{"status" => status} = review when status not in ~w(published publishing) ->
        mode = publishing(state.settings, review["repository"])

        status =
          case mode do
            "local" -> "kept"
            "automatic" -> "publishing"
            _ -> "waiting"
          end

        review =
          Map.merge(review, %{
            "status" => status,
            "verdict" => findings.verdict,
            "summary" => findings.summary,
            "comments" => findings.comments,
            "finishedAt" => now(),
            "error" => nil,
            "publishError" => nil
          })

        if mode == "automatic", do: spawn_publish(review, state.settings)
        {:reply, {:ok, review}, state |> put(review) |> pump() |> changed()}

      _ ->
        {:reply, {:error, "This thread is not a code review waiting for findings."}, state}
    end
  end

  @impl GenServer
  def handle_cast({:turn_finished, thread_id, status}, state) do
    case by_thread(state, thread_id) do
      %{"status" => "running"} = review ->
        error =
          if status == "completed",
            do:
              "The agent finished without reporting its findings. If it could not reach the #{@tool} tool, check that the project lets agents use HAL-C2's tools.",
            else: "The agent's turn ended (#{status}) before it reported its findings."

        review = Map.merge(review, %{"status" => "failed", "error" => error, "finishedAt" => now()})
        {:noreply, state |> put(review) |> pump() |> changed()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:started, key, thread_id, checkout}, state) do
    case state.reviews[key] do
      %{"threadId" => ^thread_id} = review ->
        review = Map.merge(review, checkout)
        {:noreply, state |> put(review) |> changed()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:start_failed, key, thread_id, message}, state) do
    case state.reviews[key] do
      %{"threadId" => ^thread_id, "status" => "running"} = review ->
        review = Map.merge(review, %{"status" => "failed", "error" => message, "finishedAt" => now()})
        {:noreply, state |> put(review) |> pump() |> changed()}

      _ ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, %{polling: nil} = state) do
    server = self()
    settings = state.settings
    known = state.reviews
    {_pid, ref} = spawn_monitor(fn -> send(server, {:polled, look(settings, known)}) end)
    {:noreply, %{state | polling: ref}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({:polled, found}, state),
    do: {:noreply, state |> apply_look(found) |> pump() |> changed()}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{polling: ref} = state) do
    Process.send_after(self(), :poll, trunc(state.settings["pollMinutes"] * 60_000))

    state =
      if reason == :normal,
        do: %{state | polling: nil},
        else: %{state | polling: nil, problem: "Looking for pull requests failed: #{inspect(reason)}"} |> changed()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- looking at the watched repositories ----------------------------------------------

  # What the watched repositories hold now, read through the host: the open pull
  # requests, their sizes where the listing gave none, and the latest comment asking
  # for a review on those that changed since the last look.
  defp look(settings, known) do
    repos = settings["repositories"] || []
    at = System.monotonic_time()
    nothing = %{at: at, problem: nil, unwatched: [], entries: [], read: [], sizes: %{}, asked: %{}}

    with true <- repos != [],
         {:ok, projects} <- Host.projects(@id) do
      watched =
        for repo <- repos,
            project = Enum.find(projects, &(&1["kind"] == "github" and same?(&1["repository"], repo))),
            do: project

      unwatched = Enum.reject(repos, fn repo -> Enum.any?(watched, &same?(&1["repository"], repo)) end)
      ids = watched |> Enum.map(& &1["id"]) |> Enum.uniq()
      found = %{nothing | unwatched: unwatched}

      if ids == [] do
        found
      else
        case Host.pull_requests(@id, "list", %{"projectIds" => ids, "state" => "open"}) do
          {:ok, list} ->
            entries =
              for entry <- list["entries"] || [],
                  Enum.any?(repos, &same?(&1, entry["repository"])),
                  do: pr(entry)

            failed = Enum.map(list["errors"] || [], & &1["projectId"])

            %{
              found
              | problem: if(failed != [], do: Enum.map_join(list["errors"], " ", & &1["message"])),
                entries: entries,
                read: ids -- failed,
                sizes: sizes(entries, settings, known),
                asked: asked(entries, settings, known)
            }

          {:error, error} ->
            %{found | problem: message(error)}
        end
      end
    else
      false -> nothing
      {:error, error} -> %{nothing | problem: message(error)}
    end
  end

  defp pr(entry) do
    %{
      "key" => key(entry["repository"], entry["number"]),
      "repository" => entry["repository"],
      "number" => entry["number"],
      "projectId" => entry["projectId"],
      "title" => entry["title"],
      "url" => entry["url"],
      "author" => get_in(entry, ["author", "login"]),
      "headBranch" => entry["headBranch"],
      "baseBranch" => entry["baseBranch"],
      "headSha" => entry["headSha"],
      "isDraft" => entry["isDraft"] == true,
      "labels" => Enum.map(entry["labels"] || [], & &1["name"]),
      "reviewRequested" => entry["viewerReviewRequested"] == true,
      "changedLines" => (entry["additions"] || 0) + (entry["deletions"] || 0),
      "updatedAt" => entry["updatedAt"]
    }
  end

  # Line counts the listing left at zero, for the pull requests the size limit could
  # keep out of an automatic review.
  defp sizes(entries, settings, known) do
    wanted =
      for pr <- entries,
          settings["activation"] == "automatic" and settings["maxChangedLines"] > 0,
          pr["changedLines"] == 0,
          known[pr["key"]] == nil or known[pr["key"]]["reviewedSha"] != pr["headSha"],
          do: Map.take(pr, ~w(projectId repository number))

    with [_ | _] <- wanted,
         {:ok, %{"stats" => stats}} <- Host.pull_requests(@id, "listStats", %{"refs" => wanted}) do
      Map.new(stats, &{key(&1["repository"], &1["number"]), &1["additions"] + &1["deletions"]})
    else
      _ -> %{}
    end
  end

  # The time of the latest comment starting with the review command, for pull
  # requests updated since the last look.
  defp asked(entries, settings, known) do
    command = String.trim(settings["command"] || "")

    if settings["activation"] != "selective" or command == "" do
      %{}
    else
      for pr <- entries,
          known[pr["key"]]["seenAt"] != pr["updatedAt"],
          {:ok, activity} <- [Host.pull_requests(@id, "activity", Map.take(pr, ~w(projectId repository number)))],
          at =
            activity["comments"]
            |> Enum.filter(&(&1["kind"] == "issue-comment" and String.starts_with?(String.trim(&1["body"] || ""), command)))
            |> Enum.map(& &1["createdAt"])
            |> Enum.max(fn -> nil end),
          into: %{},
          do: {pr["key"], at}
    end
  end

  # The user's own ask for pull request `number`, which need not be watched.
  defp find(settings, repository, number) do
    with {:ok, projects} <- Host.projects(@id),
         %{} = project <-
           Enum.find(projects, &(&1["kind"] == settings["host"] and same?(&1["repository"], repository))) ||
             {:error, "No project on this MC has the repository #{repository}."},
         {:ok, list} <- Host.pull_requests(@id, "list", %{"projectIds" => [project["id"]], "state" => "open"}),
         %{} = entry <-
           Enum.find(list["entries"] || [], &(&1["number"] == number)) ||
             {:error, "#{repository} has no open pull request ##{number}."} do
      {:ok, pr(entry)}
    else
      {:error, error} -> {:error, message(error)}
    end
  end

  # A look that started before the one applied last is older news and is dropped.
  defp apply_look(%{looked: looked} = state, %{at: at}) when looked != nil and at < looked,
    do: state

  defp apply_look(state, found) do
    settings = state.settings
    open = MapSet.new(found.entries, & &1["key"])
    read = MapSet.new(found.read)

    # A pull request that closed before anyone asked for its review is dropped.
    reviews =
      Map.reject(state.reviews, fn {key, review} ->
        review["status"] == "ready" and review["projectId"] in read and key not in open
      end)

    state = %{
      state
      | reviews: reviews,
        problem: found.problem,
        unwatched: found.unwatched,
        checked_at: now(),
        looked: found.at
    }

    Enum.reduce(found.entries, state, fn pr, state ->
      pr = Map.update!(pr, "changedLines", &(found.sizes[pr["key"]] || &1))
      known = state.reviews[pr["key"]]
      asked = found.asked[pr["key"]]
      asked? = asked != nil and (known == nil or later?(asked, known["startedAt"]))
      trigger = trigger(settings, pr)
      skipped = skipped(settings, pr)
      review = Map.merge(known || %{"status" => "ready"}, Map.put(pr, "seenAt", pr["updatedAt"]))
      review = Map.put(review, "skipped", if(settings["activation"] == "automatic", do: skipped))
      reviewed = known && known["reviewedSha"]

      cond do
        known && known["status"] in ~w(queued running) ->
          put(state, review)

        asked? ->
          queue(state, review, "command")

        reviewed == nil ->
          if trigger, do: queue(state, review, trigger), else: put(state, review)

        reviewed == pr["headSha"] ->
          put(state, review)

        trigger && settings["reviewNewPushes"] ->
          queue(state, review, trigger)

        true ->
          put(state, Map.put(review, "changed", true))
      end
    end)
  end

  # Why the watch would start a review of `pr`, or nil.
  defp trigger(settings, pr) do
    label = String.trim(settings["label"] || "")

    case settings["activation"] do
      "automatic" ->
        if skipped(settings, pr) == nil, do: "automatic"

      _ ->
        cond do
          settings["reviewRequested"] && pr["reviewRequested"] -> "review requested"
          label != "" and Enum.any?(pr["labels"], &(String.downcase(&1) == String.downcase(label))) -> "label"
          true -> nil
        end
    end
  end

  # Why an automatic review leaves `pr` alone, or nil.
  defp skipped(settings, pr) do
    max = settings["maxChangedLines"]
    ignored = Enum.map(settings["ignoredAuthors"] || [], &String.downcase/1)

    cond do
      settings["skipDrafts"] && pr["isDraft"] -> "Draft"
      pr["author"] && String.downcase(pr["author"]) in ignored -> "By #{pr["author"]}"
      max > 0 and pr["changedLines"] > max -> "#{pr["changedLines"]} lines changed"
      true -> nil
    end
  end

  # --- running reviews -----------------------------------------------------------------

  defp queue(state, review, trigger) do
    review =
      Map.merge(review, %{
        "status" => "queued",
        "trigger" => trigger,
        "queuedAt" => now(),
        "startedAt" => nil,
        "finishedAt" => nil,
        "threadId" => nil,
        "verdict" => nil,
        "summary" => nil,
        "comments" => [],
        "error" => nil,
        "publishError" => nil,
        "changed" => false
      })

    put(state, review)
  end

  # Starts queued reviews, oldest first, while fewer than `concurrency` run.
  defp pump(state) do
    running = Enum.count(state.reviews, fn {_, r} -> r["status"] == "running" end)

    state.reviews
    |> Map.values()
    |> Enum.filter(&(&1["status"] == "queued"))
    |> Enum.sort_by(& &1["queuedAt"])
    |> Enum.take(max(trunc(state.settings["concurrency"]) - running, 0))
    |> Enum.reduce(state, fn review, state ->
      thread_id = uuid()

      review =
        Map.merge(review, %{
          "status" => "running",
          "threadId" => thread_id,
          "startedAt" => now()
        })

      settings = state.settings
      spawn_link(fn -> run(review, settings) end)
      put(state, review)
    end)
  end

  # Checks the pull request out and starts the review's thread; tells the server
  # how it went.
  defp run(review, settings) do
    %{"key" => key, "threadId" => thread_id} = review

    # The run before this one is over: its checkout goes, and this run gets one of
    # its own, so no two threads share a checkout.
    if review["checkout"], do: Checkout.remove(review["root"], review["checkout"])

    result =
      with {:ok, projects} <- Host.projects(@id),
           %{} = project <-
             Enum.find(projects, &(&1["id"] == review["projectId"])) ||
               {:error, "The project of #{review["repository"]} is no longer on this MC."},
           # Before the checkout, which nothing would remove if this failed after it.
           {:ok, model} <- model(settings),
           path =
             Path.join([Host.data_dir(@id), "checkouts", review["projectId"], "pr-#{review["number"]}", thread_id]),
           {:ok, checkout} <-
             Checkout.prepare(project["root"], path, review["repository"], review["number"], review["baseBranch"]) do
        review = Map.merge(review, %{"reviewedSha" => checkout["headSha"]})

        GenServer.cast(
          __MODULE__,
          {:started, key, thread_id,
           %{
             "checkout" => checkout["path"],
             "root" => project["root"],
             "mergeBase" => checkout["mergeBase"],
             "reviewedSha" => checkout["headSha"],
             "headSha" => review["headSha"] || checkout["headSha"]
           }}
        )

        Host.launch_thread(
          @id,
          "review",
          %{
            "threadId" => thread_id,
            "projectId" => review["projectId"],
            "title" => "Review ##{review["number"]} #{review["title"]}",
            "modelSelection" => model,
            "runtimeMode" => settings["runtimeMode"],
            "interactionMode" => "default",
            "workspaceStrategy" => %{"type" => "existing_worktree", "worktreePath" => checkout["path"]},
            "initialMessage" => %{
              "text" => prompt(settings, review, checkout),
              "attachments" => []
            }
          },
          listed: settings["display"] != "page"
        )
      end

    case result do
      {:ok, _} -> :ok
      {:error, error} -> GenServer.cast(__MODULE__, {:start_failed, key, thread_id, message(error)})
    end
  rescue
    e -> GenServer.cast(__MODULE__, {:start_failed, review["key"], review["threadId"], Exception.message(e)})
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

  @doc false
  # The first message of a review: the user's template filled in for the pull
  # request, the repository's own instructions and REVIEW.md, and how to report.
  def prompt(settings, review, checkout) do
    values = %{
      "pr.number" => "#{review["number"]}",
      "pr.title" => review["title"],
      "pr.author" => review["author"],
      "pr.url" => review["url"],
      "pr.base" => review["baseBranch"],
      "pr.head" => review["headBranch"],
      "pr.headSha" => checkout["headSha"],
      "pr.mergeBase" => checkout["mergeBase"],
      "repository" => review["repository"]
    }

    template =
      Regex.replace(~r/\{\{\s*([\w.]+)\s*\}\}/, settings["prompt"], fn whole, name ->
        values[name] || whole
      end)

    instructions =
      Enum.find_value(settings["instructions"] || %{}, fn {repo, text} ->
        if same?(repo, review["repository"]) and String.trim(text) != "", do: text
      end)

    review_md =
      if settings["readReviewMd"] do
        text = Checkout.read(checkout["path"], checkout["headSha"], "REVIEW.md", @review_md_limit)
        if text && String.trim(text) != "", do: text
      end

    [
      template,
      instructions && "Instructions for #{review["repository"]}:\n#{instructions}",
      review_md && "The repository's REVIEW.md says:\n#{review_md}",
      @report
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n\n", &String.trim/1)
  end

  # The agent's report, its comments placed on the lines of the change; a comment on
  # a line the change does not show goes into the summary.
  defp findings(arguments, review) do
    verdict = arguments["verdict"]
    summary = String.trim(arguments["summary"] || "")
    comments = arguments["comments"] || []

    cond do
      verdict not in @verdicts ->
        {:error, "verdict must be one of #{Enum.join(@verdicts, ", ")}."}

      not is_list(comments) or not Enum.all?(comments, &comment?/1) ->
        {:error, "each comment needs a path, a line number and a body."}

      true ->
        lines =
          if review["checkout"],
            do: Checkout.diff_lines(review["checkout"], review["mergeBase"], review["reviewedSha"]),
            else: %{}

        {placed, general} =
          comments
          |> Enum.with_index(1)
          |> Enum.map(fn {c, i} ->
            side = if c["side"] == "old", do: "old", else: "new"
            position = Checkout.position(lines, c["path"], c["line"], side)

            %{
              "id" => "c#{i}",
              "path" => c["path"],
              "line" => c["line"],
              "side" => side,
              "body" => String.trim(c["body"]),
              "position" => position,
              "dismissed" => false
            }
          end)
          |> Enum.split_with(& &1["position"])

        summary =
          case general do
            [] ->
              summary

            _ ->
              notes = Enum.map_join(general, "\n\n", &"`#{&1["path"]}:#{&1["line"]}`: #{&1["body"]}")
              String.trim("#{summary}\n\n#{notes}")
          end

        # The pull request takes a review that says nothing only as an approval.
        if verdict != "approve" and summary == "" and placed == [],
          do: {:error, "summary must say what the review found when no comment is on a line of the change."},
          else: {:ok, %{verdict: verdict, summary: summary, comments: placed, general: general}}
    end
  end

  defp comment?(%{"path" => path, "line" => line, "body" => body}),
    do: is_binary(path) and is_integer(line) and line > 0 and is_binary(body) and String.trim(body) != ""

  defp comment?(_), do: false

  # --- publishing ----------------------------------------------------------------------

  defp publishing(settings, repository) do
    Enum.find_value(settings["publishingByRepository"] || %{}, settings["publishing"], fn {repo, mode} ->
      if same?(repo, repository), do: mode
    end)
  end

  defp spawn_publish(review, settings), do: spawn_link(fn -> publish(review, settings) end)

  # Posts the review with the comments the user kept; the server hears how it went.
  defp publish(review, settings) do
    as_comment = settings["verdictAsComment"] == true and review["verdict"] != "comment"

    body =
      if as_comment,
        do: String.trim("#{verdict_line(review["verdict"])}\n\n#{review["summary"]}"),
        else: review["summary"]

    input = %{
      "projectId" => review["projectId"],
      "repository" => review["repository"],
      "number" => review["number"],
      "verdict" => if(as_comment, do: "comment", else: review["verdict"]),
      "body" => body,
      # The comments' lines are the reviewed commit's, whatever has been pushed since.
      "commitId" => review["reviewedSha"],
      "comments" =>
        for c <- review["comments"] || [], not c["dismissed"] do
          %{"path" => c["path"], "body" => c["body"], "position" => c["position"]}
        end
    }

    case Host.pull_requests(@id, "submitReview", input) do
      {:ok, _} ->
        server({:published, review["key"], review["threadId"], nil})
        {:ok, server(:snapshot)}

      {:error, error} ->
        server({:published, review["key"], review["threadId"], message(error)})
        {:error, message(error)}
    end
  end

  defp verdict_line("approve"), do: "**Approved**"
  defp verdict_line("request-changes"), do: "**Changes requested**"
  defp verdict_line(_), do: ""

  # --- state ----------------------------------------------------------------------------

  defp put(state, review), do: put_in(state.reviews[review["key"]], review)

  defp by_thread(state, thread_id),
    do: Enum.find_value(state.reviews, fn {_, r} -> if r["threadId"] == thread_id, do: r end)

  defp changed(state) do
    save(state.reviews)
    announce(state)
  end

  # What clients follow: `reviews` for the Reviews page, and `threads` for each
  # review thread's mark and header, by thread id, without the findings. A row mark
  # is drawn per row, so `threads` is sent only when it changes.
  defp announce(state) do
    Host.publish(@id, "reviews", snapshot(state))
    threads = threads(state)
    if threads != state.threads, do: Host.publish(@id, "threads", threads)
    %{state | threads: threads}
  end

  @thread_fields ~w(key repository number title url headBranch baseBranch status verdict error publishError)

  defp threads(state) do
    for {_, %{"threadId" => id} = review} <- state.reviews, is_binary(id), into: %{} do
      {id, Map.take(review, @thread_fields)}
    end
  end

  @order ~w(running queued publishing waiting failed kept ready published)

  defp snapshot(state) do
    %{
      "reviews" =>
        state.reviews
        |> Map.values()
        |> Enum.sort_by(&{Enum.find_index(@order, fn s -> s == &1["status"] end), &1["repository"], -&1["number"]})
        |> Enum.map(&Map.drop(&1, ["root"])),
      "problem" => state.problem,
      "unwatched" => state.unwatched,
      "watching" => state.settings["repositories"] || [],
      "activation" => state.settings["activation"],
      "checkedAt" => state.checked_at
    }
  end

  defp reply_snapshot({:reply, {:ok, _}, state}), do: {:reply, {:ok, snapshot(state)}, state}
  defp reply_snapshot(other), do: other

  defp file, do: Path.join(Host.data_dir(@id), "reviews.json")

  defp load do
    with {:ok, text} <- File.read(file()),
         {:ok, %{"reviews" => reviews}} when is_map(reviews) <- JSON.decode(text) do
      # A publish the MC stopped in the middle of is the user's to try again. So is a
      # run: the end of its turn may have come while the plugin was not there to hear
      # it. Its agent can still report, as to any failed review.
      Map.new(reviews, fn
        {key, %{"status" => "publishing"} = review} ->
          {key, %{review | "status" => "waiting"}}

        {key, %{"status" => "running"} = review} ->
          {key,
           Map.merge(review, %{
             "status" => "failed",
             "error" => "code-review restarted while this review ran; its agent can still report, or retry it.",
             "finishedAt" => now()
           })}

        entry ->
          entry
      end)
    else
      _ -> %{}
    end
  end

  defp save(reviews) do
    tmp = file() <> ".tmp"
    File.write!(tmp, JSON.encode!(%{"reviews" => reviews}))
    File.rename!(tmp, file())
  end

  # --- helpers -------------------------------------------------------------------------

  defp server(message), do: GenServer.call(__MODULE__, message, 30_000)

  defp key(repository, number), do: "#{repository}##{number}"

  defp same?(a, b) when is_binary(a) and is_binary(b), do: String.downcase(a) == String.downcase(b)
  defp same?(_, _), do: false

  defp repository?(value), do: is_binary(value) and value =~ ~r{^[\w.-]+/[\w.-]+$}

  defp later?(_at, nil), do: true

  defp later?(at, than) do
    with {:ok, a, _} <- DateTime.from_iso8601(at),
         {:ok, b, _} <- DateTime.from_iso8601(than),
         do: DateTime.compare(a, b) == :gt,
         else: (_ -> false)
  end

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(message) when is_binary(message), do: message
  defp message(other), do: inspect(other)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

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
