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
  The agents threads can run on, for a plugin that starts threads to pick from:
  `%{"instanceId", "name", "models" => [%{"slug", "name", "isDefault", "options"}]}`,
  where a model's `options` are its option descriptors (`%{"id", "label",
  "type", "options"}`) — reasoning effort among them — for a plugin that picks
  a model for its threads to pick among too.
  """
  def providers(_id) do
    {:ok,
     for provider <- Plugins.providers() || [] do
       %{
         "instanceId" => provider["instanceId"],
         "name" => provider["displayName"] || provider["instanceId"],
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
