defmodule HalC2.Plugins.Host do
  @moduledoc """
  What a plugin may ask of the MC, each call naming the plugin. A call that needs a
  permission the user did not grant the plugin is refused with
  `{:error, message}` and recorded on the plugin (`denied` in its listing).

  The permissions gate this API, not the plugin's code: an MC part is Elixir in the
  MC's own VM, which is why the consent says so (`runsCode`).
  """

  alias HalC2.Plugins
  alias HalC2.Plugins.Host.ThreadRelay

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
  "availability", "auth" => %{"status"}, "sandboxable", "models" => [%{"slug",
  "name", "isDefault", "options"}]}`.

  `driverKind` is the driver behind the instance (`"codex"`, `"claudeAgent"`,
  `"opencode"`, `"acpRegistry"` for an agent from the ACP registry, a provider
  plugin's driver), the same one `orchestrator_capabilities` names, so a plugin can
  tell what kind of agent a user-named instance is. `enabled`, `installed`, `status`
  (`ready`, `warning`, `error`, `disabled`), `availability` (`available`,
  `unavailable`) and `auth.status` (`authenticated`, `unauthenticated`, `unknown`)
  are the instance's provider status, for a plugin that offers only the instances
  that can run a thread now. `sandboxable` is whether its agent can run in an
  OpenShell review sandbox (`HalC2.OpenShell.Review.supported?/1`). An instance's
  settings and messages are left out.

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
         "sandboxable" => HalC2.OpenShell.Review.supported?(provider["driver"]),
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

  @doc """
  The provider instances plugin `id` added, each an ordinary `providerInstances` entry
  of the settings document (`ProviderInstanceConfig`) under the instance id
  `plugin_<id>_<name>`. The host records the ids it added for the plugin in the
  plugin's own config (`plugins.<id>.providerInstances`), in the same save as the
  instance, and that record, not the id's shape, is what the plugin reaches: an
  instance of the user's is never listed, replaced or removed, whatever its id. Needs
  `providers:configure`.

    * `"list"` → `%{"instances" => [%{"name", "instanceId", "instance"}]}`, sorted by
      name, each entry as the document holds it (a sensitive variable's value is
      sealed: `""` with `"valueRedacted": true`, which kept as it is in a `"put"`
      keeps the stored value).
    * `"put"` `%{"name", "instance"}` → `%{"instanceId"}`: adds the instance or
      replaces it whole, and refuses when the user has an instance of that id. A
      plugin that keeps what the user changed reads it first.
    * `"remove"` `%{"name"}` → `%{"removed" => boolean}`, whether an instance was
      removed. A name `list` gives as released is no longer, either way.

  A `name` is lowercase letters, digits and dashes. The instances last only while the
  plugin is installed, on and granted `providers:configure`: the plugin host takes
  them out of the document when it is turned off, removed, or updated to stop asking
  (`HalC2.Plugins`), and the plugin adds them again once it is back on. `list` names
  those the host took out (`"released"`) until the plugin puts or removes them, or the
  user adds an instance of their own under that id, so a plugin starting up can tell
  them from ones the user deleted while it was down.
  """
  def provider_instances(id, "list", _input) do
    with :ok <- permit(id, "providers:configure") do
      settings = HalC2.Settings.settings()
      all = settings["providerInstances"] || %{}

      instances =
        for instance_id <- Enum.sort(added_instances(settings, id)),
            %{} = instance <- [all[instance_id]],
            do: %{
              "name" => String.replace_prefix(instance_id, "plugin_#{id}_", ""),
              "instanceId" => instance_id,
              "instance" => instance
            }

      released =
        for instance_id <- Enum.sort(released_instances(settings, id)),
            do: String.replace_prefix(instance_id, "plugin_#{id}_", "")

      {:ok, %{"instances" => instances, "released" => released}}
    end
  end

  def provider_instances(id, "put", %{"name" => name, "instance" => %{} = instance}) do
    with :ok <- permit(id, "providers:configure"),
         {:ok, instance_id} <- instance_id(id, name),
         :ok <- driver(instance),
         :ok <- not_users(HalC2.Settings.settings(), id, instance_id),
         put = &put_instance(&1, id, instance_id, instance),
         :ok <- valid(HalC2.Settings.validate(put.(HalC2.Settings.settings()))),
         :ok <- saved(HalC2.Settings.update(put)),
         # An instance of the user's that came in before the save is kept by it.
         :ok <- not_users(HalC2.Settings.settings(), id, instance_id),
         do: {:ok, %{"instanceId" => instance_id}}
  end

  def provider_instances(id, "remove", %{"name" => name}) do
    with :ok <- permit(id, "providers:configure"),
         {:ok, instance_id} <- instance_id(id, name) do
      settings = HalC2.Settings.settings()
      added? = instance_id in added_instances(settings, id)

      if added? or instance_id in released_instances(settings, id) do
        drop = fn settings ->
          settings = unrelease(settings, id, instance_id)

          if instance_id in added_instances(settings, id) do
            settings
            |> Map.update("providerInstances", %{}, &Map.delete(&1, instance_id))
            |> record(id, &List.delete(&1, instance_id))
          else
            settings
          end
        end

        with :ok <- saved(HalC2.Settings.update(drop)), do: {:ok, %{"removed" => added?}}
      else
        {:ok, %{"removed" => false}}
      end
    end
  end

  def provider_instances(_id, method, _input),
    do: {:error, "providerInstances has no method #{inspect(method)} taking that input."}

  @doc """
  The ids of the provider instances the host recorded adding for plugin `id` in
  `settings` (`provider_instances/3`). The save that deletes one of them drops its id
  from the record (`seal_records/3`), so one the user adds later under that id is theirs.
  """
  def added_instances(settings, id), do: ids(settings, id, "providerInstances")

  @doc """
  The ids of the provider instances of plugin `id` the host took out of `settings` as
  the plugin stopped being installed, on and granted (`HalC2.Plugins`), and the plugin
  has not put or removed since. The save that gives the user an instance under one of
  them drops it (`seal_records/3`): that id is the user's now, not the plugin's to put.
  """
  def released_instances(settings, id), do: ids(settings, id, "releasedInstances")

  defp ids(settings, id, key) do
    case get_in(settings, ["plugins", id, key]) do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end

  @doc """
  Keeps the records of `added_instances/2` the host's as `HalC2.Settings` saves
  `settings` over `current`. A document a client wrote (`client?`) gets the whole
  `plugins` key from `current`: whether a plugin is on, what it was granted, its settings
  and its records (`added_instances/2`, `released_instances/2`) change only through
  `HalC2.Plugins` (`plugins.enable`, `plugins.disable`, `plugins.saveSettings`), which
  check the scopes and consent each needs; a copy the client held, or edited, cannot move
  them. Every saved document keeps only the recorded ids whose instance it still holds,
  so the save that deletes a plugin's instance ends the plugin's hold on that id before
  anything reconciles; and only the released ids it holds no instance under, so one the
  user takes is not the plugin's.
  """
  def seal_records(settings, current, client?) do
    settings = if client?, do: plugins_from(settings, current), else: settings

    case settings do
      %{"plugins" => %{} = plugins} ->
        held = settings["providerInstances"]
        held = if is_map(held), do: held, else: %{}

        plugins =
          Map.new(plugins, fn
            {id, %{} = config} ->
              {id,
               config
               |> filter_record("providerInstances", &Map.has_key?(held, &1))
               |> filter_record("releasedInstances", &(not Map.has_key?(held, &1)))}

            other ->
              other
          end)

        %{settings | "plugins" => plugins}

      _ ->
        settings
    end
  end

  defp filter_record(config, key, keep?) do
    case config do
      %{^key => ids} when is_list(ids) -> %{config | key => Enum.filter(ids, keep?)}
      _ -> config
    end
  end

  defp plugins_from(client, current) do
    case Map.fetch(current, "plugins") do
      {:ok, plugins} -> Map.put(client, "plugins", plugins)
      :error -> Map.delete(client, "plugins")
    end
  end

  defp record(settings, id, fun) do
    plugins = settings["plugins"] || %{}
    config = plugins[id] || %{}
    ids = fun.(added_instances(settings, id))
    Map.put(settings, "plugins", Map.put(plugins, id, Map.put(config, "providerInstances", ids)))
  end

  defp put_instance(settings, id, instance_id, instance) do
    if users?(settings, id, instance_id) do
      settings
    else
      settings
      |> Map.put(
        "providerInstances",
        Map.put(settings["providerInstances"] || %{}, instance_id, instance)
      )
      |> record(id, &Enum.uniq(&1 ++ [instance_id]))
      |> unrelease(id, instance_id)
    end
  end

  defp unrelease(settings, id, instance_id) do
    case released_instances(settings, id) do
      [] -> settings
      ids -> put_in(settings, ["plugins", id, "releasedInstances"], List.delete(ids, instance_id))
    end
  end

  # Whether `settings` holds an instance under that id the plugin did not add.
  defp users?(settings, id, instance_id),
    do:
      Map.has_key?(settings["providerInstances"] || %{}, instance_id) and
        instance_id not in added_instances(settings, id)

  defp not_users(settings, id, instance_id) do
    if users?(settings, id, instance_id),
      do:
        {:error,
         "#{instance_id} is a provider instance of the user's: a plugin reaches only the ones it added."},
      else: :ok
  end

  # Instance ids are slugs of at most 64 characters (`ProviderInstanceId`); the
  # plugin's id is part of it, so an id a slug cannot hold is refused too.
  defp instance_id(id, name) when is_binary(name) do
    instance_id = "plugin_#{id}_#{name}"

    if name =~ ~r/^[a-z0-9][a-z0-9-]*$/ and instance_id =~ ~r/^[a-zA-Z][a-zA-Z0-9_-]*$/ and
         String.length(instance_id) <= 64,
       do: {:ok, instance_id},
       else:
         {:error,
          "#{inspect(name)} cannot name a provider instance: use lowercase letters, digits and dashes, and keep plugin_#{id}_<name> to 64 letters, digits, dashes and underscores."}
  end

  defp instance_id(_id, name), do: {:error, "#{inspect(name)} cannot name a provider instance."}

  defp driver(%{"driver" => driver}) when is_binary(driver) do
    if driver =~ ~r/^[a-zA-Z][a-zA-Z0-9_-]*$/,
      do: :ok,
      else: {:error, "#{inspect(driver)} is not a provider driver."}
  end

  defp driver(_instance), do: {:error, "A provider instance names its driver (\"driver\")."}

  defp valid(:ok), do: :ok
  defp valid({:error, %{"message" => message}}), do: {:error, message}

  # Without a running settings server `HalC2.Settings.update/1` edits the file and says `:ok`.
  defp saved({:ok, _version}), do: :ok
  defp saved(:ok), do: :ok
  defp saved({:error, message}), do: {:error, message}

  @doc """
  `pullRequests.<method>` as a client calls it (`HalC2.PullRequests.handle/2`), and on
  Forgejo the reads and the review post a reviewer needs
  (`HalC2.PullRequests.plugin_handle/2`).
  """
  def pull_requests(id, method, input) do
    permission = if method in @writes, do: "pullRequests:write", else: "pullRequests:read"
    with :ok <- permit(id, permission), do: HalC2.PullRequests.plugin_handle(method, input)
  end

  @doc """
  How the plugin's own clone fetches the Forgejo repository of pull request `ref`
  over HTTP: `{:ok, %{"url", "username", "token"}}`, with the token the MC signs in to
  that server with (nil when it has none to give). A token is git's to send, never to
  log or show. Needs `pullRequests:write`: the token can do whatever the MC's login
  can, writes included, so reading pull requests is not enough to be handed it.
  """
  def pull_request_fetch(id, ref) do
    with :ok <- permit(id, "pullRequests:write"), do: HalC2.PullRequests.fetch_access(ref)
  end

  @doc """
  Who opened a pull request and who asked for its review, with the standing GitHub
  or Forgejo gives each (`HalC2.PullRequests.trust/1`). Needs `pullRequests:read`.
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
  This MC's thread sidebar rows (`OrchestrationV2ThreadShell`), deleted ones left out,
  each with its project's title as `"projectTitle"` (nil when the project is unknown).
  Threads on other machines of the cluster are theirs to show.
  """
  def threads(id) do
    with :ok <- permit(id, "threads:read") do
      {:ok,
       for(
         {{mc, _}, {"thread", row}} <- HalC2.Shell.rows(),
         mc == node() and row["deletedAt"] == nil,
         do: row
       )
       |> ThreadRelay.with_project_titles()}
    end
  end

  @doc """
  Sends the caller `{:hal_c2_threads, rows}` whenever rows of this MC's threads change:
  the changed rows only, shaped as `threads/1`'s, a deleted one with its `"deletedAt"`
  so the plugin can let it go. A project whose row changes sends its threads again,
  so a renamed project's `"projectTitle"` follows. Watch first, then read `threads/1`:
  a change in between comes again. The rows come from a process of the host's
  (`ThreadRelay`, returned as `{:ok, pid}`), linked to the caller and gone with it.
  """
  def watch_threads(id) do
    with :ok <- permit(id, "threads:read") do
      relay = ThreadRelay.start_link(self())
      :ok = HalC2.Shell.subscribe(relay)
      {:ok, relay}
    end
  end

  @doc """
  Starts a thread as `orchestration.launchThread` does (`input` in its shape),
  marked as a `kind` thread of the plugin. `listed: false` keeps it out of the
  thread list. `sandboxed: true` runs its agent in the sandbox `open_sandbox/3`
  made for it, and never on this machine; the plugin must have opened that sandbox
  itself. `tools: :plugin` gives its agent only the tools the plugin offers agents
  (`agentTools`), never the rest of HAL-C2's (`HalC2.Mcp.for_agent/2`). A plugin
  whose manifest has `threadsStay` (`HalC2.Plugins.threads_stay?/1`,
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
      mark = if opts[:tools] == :plugin, do: Map.put(mark, "tools", "plugin"), else: mark
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
  Whether this machine can open the plugin's sandboxes now
  (`HalC2.OpenShell.Review.ready?/0`), asked each time: it reaches the gateway.
  """
  def sandboxes_ready?(id) do
    permit(id, "threads:create") == :ok and HalC2.OpenShell.Review.ready?()
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
  sentence (a time, output or token limit, or that the sandbox server could not tell),
  or nil.
  """
  def sandbox_ended(id, thread_id) do
    with :ok <- permit(id, "threads:create"),
         true <- HalC2.OpenShell.Review.opener(thread_id) in [nil, id] || nil do
      case HalC2.OpenShell.Review.ended_settled(thread_id) do
        reason when reason in ~w(time output tokens) -> HalC2.OpenShell.Review.ended_text(reason)
        :unsettled -> "The review's sandbox server was too busy to say whether it hit a limit."
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

  @doc """
  Calls `function` of the plugin's MC part with `args` on the machine `node` (as
  `peers/4` names it) alone, answering as `peers/4` does for it:
  `%{"machine" => label, "node" => node, "result" => result}`, where the result is
  `:none` when that machine does not run the plugin or a version with `function`,
  and `:unanswered` when it is out of reach or does not answer within `timeout`.
  """
  def peer_call(id, node, function, args, timeout \\ 30_000) do
    answer =
      try do
        :erpc.call(
          String.to_existing_atom(node),
          __MODULE__,
          :peer,
          [id, function, args],
          timeout
        )
      catch
        _, _ -> :unanswered
      end

    case answer do
      {:ok, %{"result" => _} = answer} -> Map.put(answer, "node", node)
      _ -> %{"machine" => node, "node" => node, "result" => :unanswered}
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
  `threads:steer`. `{:ok, receipt}` once the message was handed to the provider, or
  `{:error, message}`, also when `run_id` names no run of the thread. The receipt's
  `"confirmed"` is false when the provider's runtime did not answer in time: it still
  holds the message and may hand it on, but nobody heard it taken. Its `"ordinal"` is the
  thread's last place then: an item heard with a higher one (`observe/2`'s
  `"ordinal"`) started after the provider took the message, and any other may have
  been under way before the agent was sent it.
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
      |> case do
        {:ok, receipt} ->
          last = HalC2.Streams.read(thread_id, &(HalC2.Orchestration.next_ordinal(&1) - 1))
          {:ok, Map.put(receipt, "ordinal", last)}

        refused ->
          refused
      end
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
  `{:error, {:gone, message}}` when there is no such thread or it was deleted: its
  turns will never be read. `{:error, {:away, message}}` while it is on another MC,
  which keeps its turns until it moves back here (`HalC2.ThreadMove`).

  `"subagents"` says whether a provider's own subagent worked during the turn, started
  in it or before: plugins hear a subagent's calls as its parent turn's
  (`HalC2.Orchestration.NativeSubagent.observe/2`), but its child thread keeps them,
  so the turn's `"items"` do not have them.

  `"provider"` is the driver the turn ran on (`"claudeAgent"`, `"codex"`, ...), kept
  with the thread, so it is known after the instance the turn ran on is deleted and
  `providers/0` no longer lists it.

  `before: run_id` keeps only the turns that ended before run `run_id` started (a lower
  ordinal), whether that run ended or not, and takes `limit` of those: a plugin that
  hears of a turn late, after more turns ended, still gets the turns before it. A run
  the thread does not have cuts nothing off.

  `after: run_id` keeps only the turns that started after run `run_id` (a higher
  ordinal) and takes the oldest `limit` of those, `after: nil` the oldest `limit` of
  all: a plugin reads a thread's whole history forwards a page at a time, each page
  after the last turn of the one before. A run the thread does not have cuts nothing
  off.
  """
  def history(id, thread_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    cut =
      if Keyword.has_key?(opts, :after),
        do: {:after, opts[:after]},
        else: {:before, opts[:before]}

    with :ok <- permit(id, "turns:observe") do
      HalC2.Streams.read(thread_id, fn stream ->
        case HalC2.StreamState.get(stream, "thread")[thread_id] do
          nil -> {:error, {:gone, "There is no thread #{thread_id}."}}
          %{"deletedAt" => at} when at != nil -> {:error, {:gone, "#{thread_id} was deleted."}}
          %{"movedTo" => %{}} -> {:error, {:away, "#{thread_id} is on another machine."}}
          _thread -> {:ok, turns(stream, limit, cut)}
        end
      end)
    end
  end

  @doc """
  The threads of project `project_id` on this MC that are not deleted, oldest first:
  `%{"id", "createdAt", "updatedAt", "latestUserMessageAt", "latestRunCompletedAt"}`,
  `latestUserMessageAt` nil for a thread never sent a message. For a plugin that learns
  from a project's earlier turns (`history/3` reads each thread's). A thread moved to
  another machine is that machine's. Needs `turns:observe`.
  """
  def project_threads(id, project_id) do
    with :ok <- permit(id, "turns:observe") do
      {:ok,
       for(
         {{mc, _}, {"thread", row}} <- HalC2.Shell.rows(),
         mc == node() and row["projectId"] == project_id and row["deletedAt"] == nil,
         do:
           Map.take(
             row,
             ~w(id createdAt updatedAt latestUserMessageAt latestRunCompletedAt)
           )
       )
       |> Enum.sort_by(&{&1["createdAt"] || "", &1["id"]})}
    end
  end

  @doc """
  Whether run `run_id` of `thread_id` is under way on this MC. Not once it ended, nor a
  run or thread this MC does not have: a plugin that never heard a turn end learns here
  that it will not. Needs `turns:observe`; without it, false.
  """
  def run_active?(id, thread_id, run_id) do
    granted?(id, "turns:observe") and
      HalC2.Orchestration.run_under_way?(HalC2.Streams.get(thread_id, "run", run_id))
  end

  @doc """
  The project a thread is in, from its stream: `{:ok, project id}`, kept once the
  thread is deleted or moved away. When its record names none, `{:error, {:gone,
  message}}` for a thread deleted or never here, `{:error, {:away, message}}` for one
  on another machine and `{:error, {:unknown, message}}` otherwise. Needs
  `turns:observe`.
  """
  def thread_project(id, thread_id) do
    with :ok <- permit(id, "turns:observe") do
      HalC2.Streams.read(thread_id, fn stream ->
        case HalC2.StreamState.get(stream, "thread")[thread_id] do
          nil -> {:error, {:gone, "There is no thread #{thread_id}."}}
          %{"projectId" => project_id} when is_binary(project_id) -> {:ok, project_id}
          %{"deletedAt" => at} when at != nil -> {:error, {:gone, "#{thread_id} was deleted."}}
          %{"movedTo" => %{}} -> {:error, {:away, "#{thread_id} is on another machine."}}
          _thread -> {:error, {:unknown, "#{thread_id} names no project."}}
        end
      end)
    end
  end

  @doc """
  How many turn events plugin `id`'s feed may still deliver: 0 when it has no feed. A
  plugin process restarted while its feed ran has lost what it knew of the events
  before: any of these may have been sent before events it missed, and a report of
  missed events may have reached the process that went down. Besides those the feed
  holds, each feed may be blocked delivering one more, its call already in the
  restarted process's mailbox, so each counts one more.
  """
  def feed_backlog(id) do
    Enum.sum(
      for {pid, %{id: ^id}} <- Plugins.Feed.lookup(:observe),
          {:message_queue_len, n} <- [Process.info(pid, :message_queue_len)],
          do: n + 1
    )
  end

  @ended ~w(completed interrupted failed cancelled)

  defp turns(stream, limit, cut) do
    alias HalC2.StreamState

    attempts = StreamState.get(stream, "run-attempt")
    provider_turns = StreamState.get(stream, "provider-turn")
    provider_threads = StreamState.get(stream, "provider-thread")
    runs = StreamState.get(stream, "run")

    subagents =
      for {_id, %{"origin" => "provider_native"} = sub} <- StreamState.get(stream, "subagent"),
          do: sub

    cutoff =
      case {cut, runs[elem(cut, 1)]} do
        {{:before, _}, %{"ordinal" => ordinal}} -> &(&1["ordinal"] < ordinal)
        {{:after, _}, %{"ordinal" => ordinal}} -> &(&1["ordinal"] > ordinal)
        _ -> fn _run -> true end
      end

    selected =
      runs
      |> Map.values()
      |> Enum.filter(&(&1["status"] in @ended and cutoff.(&1)))
      |> Enum.sort_by(& &1["ordinal"])
      |> Enum.take(if(elem(cut, 0) == :after, do: limit, else: -limit))

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
          |> Enum.map(&HalC2.Orchestration.TurnWriter.observed_item/1),
        # A thread it delegated to (`"app_owned"`) makes its calls in turns of its own.
        "subagents" =>
          Enum.any?(
            items[run["id"]] || [],
            &(&1["type"] == "subagent" and &1["origin"] == "provider_native")
          ) or Enum.any?(subagents, &worked_in?(&1, run))
      }
    end)
  end

  # A subagent worked during `run` if it started in it, or one of the spans it worked
  # overlaps it: each before it was resumed (`HalC2.Orchestration.NativeSubagent.resume/3`),
  # and the last, from its start or latest resume, still open while it runs.
  defp worked_in?(sub, run) do
    spans =
      (sub["workedSpans"] || []) ++
        [%{"from" => sub["resumedAt"] || sub["startedAt"], "to" => sub["completedAt"]}]

    sub["runId"] == run["id"] or Enum.any?(spans, &overlaps?(&1, run))
  end

  defp overlaps?(%{"from" => from, "to" => to}, run) do
    is_binary(from) and is_binary(run["completedAt"]) and from <= run["completedAt"] and
      (to == nil or to >= (run["startedAt"] || ""))
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
