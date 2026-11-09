defmodule HalC2.Plugins.Host do
  @moduledoc """
  What a plugin may ask of the MC, each call naming the plugin. A call that needs a
  permission the user did not grant the plugin is refused with
  `{:error, message}` and recorded on the plugin (`denied` in its listing).

  The permissions gate this API, not the plugin's code: an MC part is Elixir in the
  MC's own VM, which is why the consent says so (`runsCode`).
  """

  alias HalC2.Plugins

  # Pull request methods that change something on the host.
  @writes ~w(runAction update comment updateComment submitReview replyToThread
             setThreadResolution setReaction setFilesViewed requestReviewers setLabels)

  @doc """
  Tells every client watching `topic` of plugin `id` its new `value`; a client that
  starts watching later gets the last one at once.
  """
  def publish(id, topic, value), do: Plugins.publish(id, topic, value)

  @doc "A directory that is the plugin's own, kept across restarts and updates."
  def data_dir(id) do
    dir = Path.join([HalC2.Paths.data_dir(), "plugin-data", id])
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  This MC's projects that have a git remote:
  `%{"id", "title", "root", "host", "repository", "kind"}`.
  """
  def projects(id) do
    with :ok <- permit(id, "projects:read") do
      {:ok,
       for project <- HalC2.PullRequests.projects() do
         %{
           "id" => project.id,
           "title" => project.title,
           "root" => project.root,
           "host" => project.host,
           "repository" => project.repository,
           "kind" => project.kind
         }
       end}
    end
  end

  @doc """
  The agents threads can run on, as clients list them (`HalC2.Environment.providers/0`,
  so `name` is the one the user gave the instance), for a plugin that starts threads
  to pick from:
  `%{"instanceId", "name", "driverKind", "enabled", "installed", "status",
  "availability", "auth" => %{"status"}, "models" => [%{"slug", "name",
  "isDefault", "options"}]}`.

  `driverKind` is the driver behind the instance (`"codex"`, `"claudeAgent"`,
  `"opencode"`, `"acpRegistry"` for an agent from the ACP registry, a provider
  plugin's driver), the same one `orchestrator_capabilities` names, so a plugin can
  tell what kind of agent a user-named instance is. `enabled`, `installed`, `status`
  (`ready`, `warning`, `error`, `disabled`), `availability` (`available`,
  `unavailable`) and `auth.status` (`authenticated`, `unauthenticated`, `unknown`)
  are the instance's provider status, for a plugin that offers only the instances
  that can run a thread now. An instance's settings and messages are left out.

  A model's `options` are its option descriptors (`%{"id", "label", "type",
  "options"}`) — reasoning effort among them — for a plugin that picks a model for
  its threads to pick among too.
  """
  def providers(_id) do
    {:ok,
     for provider <- HalC2.Environment.providers() do
       %{
         "instanceId" => provider["instanceId"],
         "name" => provider["displayName"] || provider["instanceId"],
         "driverKind" => provider["driver"],
         "enabled" => provider["enabled"] != false,
         "installed" => provider["installed"] != false,
         "status" => provider["status"],
         # A snapshot without one is available (`ServerProvider.availability`).
         "availability" => provider["availability"] || "available",
         "auth" => %{"status" => get_in(provider, ["auth", "status"]) || "unknown"},
         "models" =>
           for model <- provider["models"] || [] do
             %{
               "slug" => model["slug"],
               "name" => model["name"],
               "isDefault" => model["isDefault"] == true,
               "options" =>
                 for descriptor <- get_in(model, ["capabilities", "optionDescriptors"]) || [] do
                   %{
                     "id" => descriptor["id"],
                     "label" => descriptor["label"],
                     "type" => descriptor["type"],
                     "options" =>
                       for option <- descriptor["options"] || [] do
                         %{
                           "id" => option["id"],
                           "label" => option["label"],
                           "isDefault" => option["isDefault"] == true
                         }
                       end
                   }
                 end
             }
           end
       }
     end}
  end

  @doc "`pullRequests.<method>` as a client calls it (`HalC2.PullRequests.handle/2`)."
  def pull_requests(id, method, input) do
    permission = if method in @writes, do: "pullRequests:write", else: "pullRequests:read"
    with :ok <- permit(id, permission), do: HalC2.PullRequests.handle(method, input)
  end

  @doc """
  Who opened a pull request and who asked for its review, with the standing GitHub
  gives each (`HalC2.PullRequests.trust/1`). Needs `pullRequests:read`.
  """
  def pull_request_trust(id, ref) do
    with :ok <- permit(id, "pullRequests:read"), do: HalC2.PullRequests.trust(ref)
  end

  @doc """
  Opens a pull request of `cwd`'s checkout with `gh pr create` from `fields`:
  `repository`, `base`, `head`, `title` and `body`. Needs `pullRequests:write`. It is
  something asked for, so it goes through a rate limit pause (`HalC2.GitHub.asked/1`). `{:ok, stdout}`, which names the new pull request,
  or `{:error, detail}`.
  """
  def open_pull_request(id, cwd, fields) do
    args =
      ["pr", "create", "--repo", fields["repository"], "--base", fields["base"]] ++
        ["--head", fields["head"], "--title", fields["title"], "--body-file", "-"]

    opened = fn -> HalC2.GitHub.gh(cwd, args, input: fields["body"] || "", timeout: 120_000) end

    with :ok <- permit(id, "pullRequests:write"),
         {:error, {_, detail}} <- HalC2.GitHub.asked(opened),
         do: {:error, detail}
  end

  @doc """
  A repository's issues, milestones, sub-issues and dependencies, and the boards
  they sit on (`HalC2.Issues.handle/2`). Changes need `issues:write`, and answer
  with the whole issue or milestone only when `issues:read` is granted too.
  """
  def issues(id, method, input) do
    if HalC2.Issues.write?(method) do
      with :ok <- permit(id, "issues:write"),
           {:ok, result} <- HalC2.Issues.handle(method, input),
           do: {:ok, written(id, result)}
    else
      with :ok <- permit(id, "issues:read"), do: HalC2.Issues.handle(method, input)
    end
  end

  # A change answers with what it changed only to a plugin that may also read it;
  # otherwise `issues:write` would read any issue through an empty update.
  defp written(id, result) do
    if granted?(id, "issues:read"),
      do: result,
      else: Map.take(result, ~w(ok repository number url itemId))
  end

  @doc "A thread's sidebar row (`OrchestrationV2ThreadShell`), or nil."
  def thread(id, thread_id) do
    with :ok <- permit(id, "threads:read") do
      case HalC2.Shell.row(node(), thread_id) do
        {"thread", row} -> {:ok, row}
        _ -> {:ok, nil}
      end
    end
  end

  @doc """
  Starts a thread as `orchestration.launchThread` does (`input` in its shape),
  marked as a `kind` thread of the plugin. `listed: false` keeps it out of the
  thread list. `sandboxed: true` runs its agent in the sandbox `open_sandbox/3`
  made for it, and never on this machine; the plugin must have opened that sandbox
  itself. A plugin whose manifest has `threadsStay` (`HalC2.Plugins.threads_stay?/1`,
  which asks the version that runs first) has its threads marked `"stays"`: its sandbox,
  credentials and checkout for them do not travel, so a moved thread would run without
  them, and moves and exports of them are refused (`HalC2.ThreadArchive.stays/1`), as
  they are of a sandboxed thread. Created by the system, from the server.
  """
  def launch_thread(id, kind, input, opts \\ []) do
    with :ok <- permit(id, "threads:create"),
         :ok <- if(opts[:sandboxed], do: own_sandbox(id, input["threadId"]), else: :ok) do
      mark = %{"id" => id, "kind" => kind, "listed" => Keyword.get(opts, :listed, true)}
      mark = if opts[:sandboxed], do: Map.put(mark, "sandboxed", true), else: mark
      mark = if Plugins.threads_stay?(id), do: Map.put(mark, "stays", true), else: mark

      input
      |> Map.merge(%{"createdBy" => "system", "creationSource" => "server"})
      |> Map.put_new("commandId", "plugin:#{id}:#{HalC2.Environment.uuid4()}")
      |> HalC2.Orchestration.launch_thread(plugin: mark)
    end
  end

  @doc """
  Settles or unsettles a thread the plugin started and shows or hides it in the
  thread list, as `changes` (`"settled"`/`"listed"` booleans) asks
  (`HalC2.Orchestration.organize_plugin_thread/3`).
  """
  def organize_thread(id, thread_id, changes) do
    with :ok <- permit(id, "threads:organize"),
         do: HalC2.Orchestration.organize_plugin_thread(thread_id, id, changes)
  end

  @doc """
  Makes the OpenShell sandbox thread `thread_id` will review in, before the thread
  is launched with `sandboxed: true` (`HalC2.OpenShell.Review.open/1`, whose `spec`
  this takes without `:thread_id`). `{:ok, %{sandbox, deadline}}` or
  `{:error, message}`.
  """
  def open_sandbox(id, thread_id, spec) do
    with :ok <- permit(id, "threads:create"),
         :ok <- own_thread(id, thread_id),
         do: HalC2.OpenShell.Review.open(Map.merge(spec, %{thread_id: thread_id, owner: id}))
  end

  @doc """
  Deletes the sandbox of thread `thread_id`, if it has one: its agent can run no
  more. `reason` says why for `sandbox_ended/2`.
  """
  def close_sandbox(id, thread_id, reason \\ nil) do
    with :ok <- permit(id, "threads:organize"),
         :ok <- own_thread(id, thread_id),
         do: HalC2.OpenShell.Review.close(thread_id, reason, id)
  end

  @doc """
  Why the sandbox of thread `thread_id` went before its agent was done, as a
  sentence (a time, output or token limit), or nil.
  """
  def sandbox_ended(id, thread_id) do
    with :ok <- permit(id, "threads:create"),
         true <- HalC2.OpenShell.Review.opener(thread_id) in [nil, id] || nil do
      case HalC2.OpenShell.Review.ended(thread_id) do
        reason when reason in ~w(time output tokens) -> HalC2.OpenShell.Review.ended_text(reason)
        _ -> nil
      end
    end
  end

  # A sandbox is its plugin's: one for a thread another plugin started, or that
  # another plugin opened or closed first (`HalC2.OpenShell.Review.opener/1`), is not.
  # The thread's own mark outlives the review process's table across a restart.
  defp own_thread(id, thread_id) do
    case HalC2.Streams.get(thread_id, "thread", thread_id) do
      %{"plugin" => %{"id" => ^id}} -> :ok
      nil -> :ok
      _ -> {:error, "Thread #{thread_id} was not started by #{id}."}
    end
  end

  defp own_sandbox(id, thread_id) do
    if is_binary(thread_id) and HalC2.OpenShell.Review.opener(thread_id) == id,
      do: :ok,
      else: {:error, "A sandboxed thread runs only in a sandbox its plugin opened for it."}
  end

  @doc """
  Stops a thread the plugin started, waiting for its agent to be gone
  (`HalC2.Orchestration.stop_plugin_thread/3`).
  """
  def stop_thread(id, thread_id) do
    with :ok <- permit(id, "threads:organize"),
         do: HalC2.Orchestration.stop_plugin_thread(thread_id, id)
  end

  @doc """
  Calls `function` of the plugin's MC part with `args` on every other machine of
  the cluster connected now, all at once:
  `[%{"machine" => label, "node" => node, "result" => result}]`. One that does not
  run the plugin, or runs a version without `function`, answers `:none`. One out of
  reach, or that runs a version without this call, is left out, so a plugin that
  defers to its peers keeps working alone. One still connected that does not answer
  within `timeout`, or fails to, answers `:unanswered`: it may hold anything, so a
  plugin that defers to it waits for it as for one that cannot say.
  """
  def peers(id, function, args, timeout \\ 5_000) do
    nodes = Node.list()
    results = :erpc.multicall(nodes, __MODULE__, :peer, [id, function, args], timeout)

    answers =
      for {node, result} <- Enum.zip(nodes, results),
          answer = answer(result),
          do: Map.put(answer, "node", to_string(node))

    if Enum.any?(answers, &(&1["result"] == :unanswered)) do
      labels = cluster_machines(id)

      Enum.map(answers, fn
        %{"result" => :unanswered, "node" => node} = answer ->
          Map.put(answer, "machine", labels[node] || node)

        answer ->
          answer
      end)
    else
      answers
    end
  end

  defp answer({:ok, {:ok, %{} = answer}}), do: answer
  # An MC from before `peer/3` named its machine says only `:none` for a plugin it
  # does not run, or a function that plugin lacks.
  defp answer({:ok, :none}), do: %{"result" => :none}
  defp answer({:ok, _other}), do: nil
  defp answer({:error, {:erpc, :noconnection}}), do: nil
  defp answer({:error, {:exception, :undef, [{__MODULE__, :peer, _, _} | _]}}), do: nil
  defp answer(_silent), do: %{"result" => :unanswered}

  @doc false
  def peer(id, function, args) do
    with {:ok, module, _context} <- GenServer.call(Plugins, {:context, id}),
         true <- function_exported?(module, function, length(args)) do
      {:ok, %{"machine" => HalC2.Environment.label(), "result" => apply(module, function, args)}}
    else
      _ -> {:ok, %{"machine" => HalC2.Environment.label(), "result" => :none}}
    end
  end

  @doc """
  Whether the machine `node` (as `peers/4` names it) is no longer one this machine
  is clustered with: removed, switched off, or this MC's cluster is off. False when
  the cluster does not run here, or the node is not an MC's.
  """
  def left_cluster?(_id, node) do
    with ["hal_c2", host] <- node |> to_string() |> String.split("@", parts: 2),
         pid when pid != nil <- Process.whereis(HalC2.Cluster) do
      member = String.replace_suffix(host, ".hal-c2", "")

      case HalC2.Cluster.status() do
        %{"clustered" => true, "members" => members} ->
          not Enum.any?(members, &(&1["id"] == member and not &1["off"]))

        _ ->
          true
      end
    else
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @doc """
  The other machines of this machine's cluster, by node as `peers/4` names it, with
  their labels: every member not switched off, whether it is in reach now or has
  never been. Empty when the cluster does not run here or is off.
  """
  def cluster_machines(_id) do
    case Process.whereis(HalC2.Cluster) && HalC2.Cluster.status() do
      %{"clustered" => true, "members" => members} ->
        for %{"id" => member} = entry <- members,
            not entry["off"],
            into: %{},
            do: {to_string(HalC2.Cluster.mc_name(member)), entry["label"] || member}

      _ ->
        %{}
    end
  catch
    :exit, _ -> %{}
  end

  @doc """
  Steers run `run_id` of `thread_id` with `text`, as a user's steer does, and only it:
  a run that has ended, is being stopped, or whose provider cannot take a message while
  it works refuses it, and the message is neither queued nor kept (`steerOnly`). Needs
  `threads:steer`. `{:ok, receipt}` once the provider took it, or `{:error, message}`,
  also when `run_id` names no run of the thread.
  """
  def steer(id, thread_id, run_id, text) when is_binary(text) and text != "" do
    with :ok <- permit(id, "threads:steer"),
         :ok <- run_of(thread_id, run_id) do
      HalC2.Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "commandId" => "plugin:#{id}:#{HalC2.Environment.uuid4()}",
        "threadId" => thread_id,
        "text" => text,
        "attachments" => [],
        "createdBy" => "system",
        "creationSource" => "server",
        "deliveryIntent" => "steer",
        "dispatchMode" => %{"type" => "steer_active", "targetRunId" => run_id},
        "steerOnly" => true
      })
    end
  end

  # A steer naming no run is refused as the orchestration refuses any steer meant only
  # for its run that names none.
  defp run_of(thread_id, run_id) when is_binary(run_id) and run_id != "" do
    if HalC2.Streams.get(thread_id, "run", run_id),
      do: :ok,
      else: {:error, "Thread #{thread_id} has no run #{run_id}."}
  end

  defp run_of(_thread_id, _run_id), do: :ok

  @doc """
  Shows `message` in `thread_id`'s timeline, in run `run_id`, as a notice from the
  plugin (`system_notice`, with its `pluginId`). `opts`: `title` (the message when
  left out) and `interrupt: true`, which offers a button that stops the run while it
  works. Needs `threads:notice`. `{:ok, item_id}`, or `{:error, message}` when the
  thread has no such run.
  """
  def notice(id, thread_id, run_id, message, opts \\ []) when is_binary(message) do
    alias HalC2.Orchestration.Entities

    with :ok <- permit(id, "threads:notice") do
      item_id = "turn-item:plugin:#{id}:#{HalC2.Environment.uuid4()}"
      title = Keyword.get(opts, :title) || message

      fields =
        %{"title" => title, "message" => message, "pluginId" => id}
        |> then(&if(opts[:interrupt], do: Map.put(&1, "actions", ["interrupt"]), else: &1))

      HalC2.Streams.transact(thread_id, :thread, fn stream ->
        case HalC2.StreamState.get(stream, "run")[run_id] do
          %{} = run ->
            ids = %{
              thread: thread_id,
              run: run_id,
              root_node: run["rootNodeId"],
              provider_thread: run["providerThreadId"]
            }

            item =
              Entities.turn_item(
                ids,
                item_id,
                "system_notice",
                HalC2.Orchestration.next_ordinal(stream),
                "completed",
                Entities.now(),
                fields
              )

            {[HalC2.Orchestration.create("turn-item", item_id, item)], {:ok, item_id}}

          nil ->
            {[], {:error, "Thread #{thread_id} has no run #{run_id}."}}
        end
      end)
    end
  end

  @doc """
  Asks the user's text generation model (`HalC2.TextGeneration.for_plugin/2`) for an
  object with the `schema`'s keys (`%{"key" => "string" | "boolean"}`), in an empty
  directory: `{:ok, object, usage}`, where `usage` is `%{"instanceId", "model",
  "inputTokens", "cachedInputTokens", "outputTokens", "costUsd", "estimated"}`
  (`estimated` when the provider reports none, from the lengths of the prompt and the
  answer), or `{:error, message}`. Needs `textGeneration`.
  """
  def generate(id, prompt, schema) when is_binary(prompt) and is_map(schema) do
    with :ok <- permit(id, "textGeneration"),
         {:ok, schema} <- generation_schema(schema) do
      case HalC2.TextGeneration.for_plugin(prompt, schema) do
        {:ok, out, usage} -> {:ok, out, usage}
        {:error, {:unavailable, message}} -> {:error, message}
        {:error, message} when is_binary(message) -> {:error, message}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp generation_schema(schema) do
    Enum.reduce_while(schema, {:ok, %{}}, fn
      {key, type}, {:ok, acc} when is_binary(key) and type in ["string", "boolean"] ->
        {:cont, {:ok, Map.put(acc, key, String.to_existing_atom(type))}}

      {key, _type}, _acc ->
        {:halt, {:error, "#{inspect(key)} is not a key with type \"string\" or \"boolean\"."}}
    end)
  end

  @doc """
  The turns `thread_id` ran, oldest first, the newest `limit` (50 when left out) of
  those that ended: `%{"runId", "ordinal", "status", "provider", "instanceId", "model",
  "startedAt", "completedAt", "tokenUsage", "items"}`, each item as plugins hear it
  (`HalC2.Orchestration.TurnWriter.observed_item/1`), in the turn's order. What a
  plugin that hears turns missed while it was not running. Needs `turns:observe`.
  `{:error, message}` when there is no such thread.

  `"provider"` is the driver the turn ran on (`"claudeAgent"`, `"codex"`, ...), kept
  with the thread, so it is known after the instance the turn ran on is deleted and
  `providers/0` no longer lists it.

  `before: run_id` keeps only the turns that ended before run `run_id` started (a lower
  ordinal), whether that run ended or not, and takes `limit` of those: a plugin that
  hears of a turn late, after more turns ended, still gets the turns before it. A run
  the thread does not have cuts nothing off.
  """
  def history(id, thread_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before = Keyword.get(opts, :before)

    with :ok <- permit(id, "turns:observe") do
      HalC2.Streams.read(thread_id, fn stream ->
        if HalC2.StreamState.get(stream, "thread")[thread_id],
          do: {:ok, turns(stream, limit, before)},
          else: {:error, "There is no thread #{thread_id}."}
      end)
    end
  end

  @ended ~w(completed interrupted failed cancelled)

  defp turns(stream, limit, before) do
    alias HalC2.StreamState

    attempts = StreamState.get(stream, "run-attempt")
    provider_turns = StreamState.get(stream, "provider-turn")
    provider_threads = StreamState.get(stream, "provider-thread")
    runs = StreamState.get(stream, "run")

    cutoff =
      case runs[before] do
        %{"ordinal" => ordinal} -> &(&1["ordinal"] < ordinal)
        _ -> fn _run -> true end
      end

    selected =
      runs
      |> Map.values()
      |> Enum.filter(&(&1["status"] in @ended and cutoff.(&1)))
      |> Enum.sort_by(& &1["ordinal"])
      |> Enum.take(-limit)

    # The items of those runs alone, an older run's read back from the store once it
    # has gone cold (`HalC2.StreamState`, "Hot and cold").
    items =
      for {"turn-item", _id, item} <- StreamState.run_rows(stream, Enum.map(selected, & &1["id"])),
          reduce: %{} do
        acc -> Map.update(acc, item["runId"], [item], &[item | &1])
      end

    Enum.map(selected, fn run ->
      provider_turn = (attempts[run["activeAttemptId"]] || %{})["providerTurnId"]

      %{
        "runId" => run["id"],
        "ordinal" => run["ordinal"],
        "status" => run["status"],
        "provider" => (provider_threads[run["providerThreadId"]] || %{})["driver"],
        "instanceId" => run["providerInstanceId"],
        "model" => get_in(run, ["modelSelection", "model"]),
        "startedAt" => run["startedAt"],
        "completedAt" => run["completedAt"],
        "tokenUsage" => (provider_turns[provider_turn] || %{})["tokenUsage"],
        "items" =>
          (items[run["id"]] || [])
          |> Enum.sort_by(& &1["ordinal"])
          |> Enum.map(&HalC2.Orchestration.TurnWriter.observed_item/1)
      }
    end)
  end

  @doc "Whether plugin `id` was granted `permission`."
  def granted?(id, permission), do: permission in Plugins.granted(id)

  defp permit(id, permission) do
    if granted?(id, permission) do
      :ok
    else
      Plugins.denied(id, permission)

      {:error,
       "#{id} was not granted the permission to #{String.downcase(HalC2.Plugins.Package.permission_label(permission))} (#{permission})."}
    end
  end

  @doc """
  The MC's Slack connection (`HalC2.Slack`), as the bot. Reads need `slack:read`:
  `"status"` → `%{"connected", "team", "bot", "botUserId"}`, `"channels"` →
  `%{"channels" => [%{"id", "name", "private"}]}` (the bot's), `"replies"`
  `%{channel, ts}` → `%{"messages" => [message]}` (the parent and every reply), `"user"` `%{user}` →
  `%{"id", "name", "realName"}`. Writes need `slack:write`: `"post"` `%{channel, text,
  threadTs?, blocks?}` and `"update"` `%{channel, ts, text, blocks?}` →
  `%{"channel", "ts"}`, `"respond"` `%{responseUrl, text}` (seen only by who ran the
  slash command) and `"react"` `%{channel, ts, name}` → `%{"ok" => true}`. A channel is an
  id or `"#name"`; a message is `%{"channel", "ts", "threadTs", "user", "userName",
  "text", "botId"}`. Errors: `"Slack is not connected on this MC."` and
  `"Slack refused it: <Slack's error>"`.
  """
  def slack(id, method, input) do
    permission = if HalC2.Slack.write?(method), do: "slack:write", else: "slack:read"
    with :ok <- permit(id, permission), do: HalC2.Slack.call(method, input)
  end
end
