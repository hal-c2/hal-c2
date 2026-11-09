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
  thread list. Created by the system, from the server.
  """
  def launch_thread(id, kind, input, opts \\ []) do
    with :ok <- permit(id, "threads:create") do
      mark = %{"id" => id, "kind" => kind, "listed" => Keyword.get(opts, :listed, true)}

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
  Stops a thread the plugin started, waiting for its agent to be gone
  (`HalC2.Orchestration.stop_plugin_thread/3`).
  """
  def stop_thread(id, thread_id) do
    with :ok <- permit(id, "threads:organize"),
         do: HalC2.Orchestration.stop_plugin_thread(thread_id, id)
  end

  @doc """
  Calls `function` of the plugin's MC part with `args` on every other machine of
  the cluster connected now that runs the plugin, all at once:
  `[%{"machine" => label, "node" => node, "result" => result}]`. A machine that
  does not answer within `timeout`, does not run the plugin, or runs a version
  without `function` (or without this call) is left out, as one out of reach is,
  so a plugin that defers to its peers keeps working alone.
  """
  def peers(id, function, args, timeout \\ 5_000) do
    nodes = Node.list()
    results = :erpc.multicall(nodes, __MODULE__, :peer, [id, function, args], timeout)

    for {node, {:ok, {:ok, answer}}} <- Enum.zip(nodes, results),
        do: Map.put(answer, "node", to_string(node))
  end

  @doc false
  def peer(id, function, args) do
    with {:ok, module, _context} <- GenServer.call(Plugins, {:context, id}),
         true <- function_exported?(module, function, length(args)) do
      {:ok, %{"machine" => HalC2.Environment.label(), "result" => apply(module, function, args)}}
    else
      _ -> :none
    end
  end

  @doc """
  Steers run `run_id` of `thread_id` with `text`, as a user's steer does, and only it:
  a run that has ended, is being stopped, or whose provider cannot take a message while
  it works refuses it, and the message is neither queued nor kept (`steerOnly`). Needs
  `threads:steer`. `{:ok, receipt}` once the provider took it, or `{:error, message}`,
  also when `run_id` names no run.
  """
  def steer(id, thread_id, run_id, text) when is_binary(text) and text != "" do
    with :ok <- permit(id, "threads:steer"),
         :ok <- if(is_binary(run_id), do: :ok, else: {:error, "A steer must name its run."}) do
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

  @doc """
  How many turn events plugin `id`'s feed holds, still to deliver: 0 when it has no
  feed. A plugin process restarted while its feed ran has lost what it knew of the
  events before: any of these may have been sent before events it missed, and a report
  of missed events may have reached the process that went down.
  """
  def feed_backlog(id) do
    Enum.sum(
      for {pid, %{id: ^id}} <- Plugins.Feed.lookup(:observe),
          {:message_queue_len, n} <- [Process.info(pid, :message_queue_len)],
          do: n
    )
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
