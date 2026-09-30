defmodule HalC2.Web.Protocol do
  @moduledoc """
  The client wire protocol (version 3): JSON text frames over one WebSocket.

  A client subscribes to *shapes* and keeps each one in sync from an offset, the way
  Electric shapes work:

    * `{"type": "shell"}`: every node's environment and every project and thread
      summary on it
    * `{"type": "shell", "links": true}`: the same, with each link also carrying its
      environment's nodes and rows (`HalC2.Links.Rows`), then their changes
    * `{"type": "stream", "node": n, "stream": id}`: one project or thread
    * `{"type": "config", "node": n}`: that node's `ServerConfig` and name, then its settings and providers as they change;
      with `"usageLimitsCommand": true` (a client that answers `/usage-limits` itself),
      every provider with limits to show offers that command
    * `{"type": "terminal", "node": n, "input": TerminalAttachInput}`: one terminal,
      opened if needed; a snapshot, then its events
    * `{"type": "terminals", "node": n}`: that node's terminal summaries, then changes
    * the shapes in `routed/0` with `"environment": id` instead of `"node"`: on this
      node or the cluster member serving that environment, else through this node's
      link to it or to its cluster (`HalC2.Links.route/1`), whose token's scopes apply
      there (a linked stream resumes from `offset` and resyncs as a local one does).
      While that link is down the subscription fails at once with an error whose
      `detail` is `{"_tag": "EnvironmentUnreachableError", "environmentId", "reason"}`,
      `reason` being `"unreachable"` or `"refused"` (pair it again)
    * `{"type": "vcs", "node": n, "cwd": dir}`: a checkout's git status, then changes
    * `{"type": "worktreeSetup", "node": n, "threadId": id}`: a new thread's worktree
      setup (`WorktreeSetupStreamEvent`: null, or a snapshot), then changes
    * `{"type": "authAccess"}`: this node's pairing links and paired clients
      (`AuthAccessStreamEvent`), for a session with `access:read`
    * `{"type": "resourceTelemetry", "node": n}`: that node's resource monitor
      (`ResourceTelemetrySnapshot`), sampled every few seconds while subscribed
    * `{"type": "preview", "node": n}`: that node's preview tab events (`PreviewEvent`)
    * `{"type": "previewAutomation", "node": n, "host": PreviewAutomationHost}`: this
      client as that node's browser automation host; agents' browser actions
      (`PreviewAutomationStreamEvent`) until the node drops the host, which ends it
    * `{"type": "serverUpdate", "node": n, "input": ServerSelfUpdateInput}`: moves
      that node to another version (`HalC2.Upgrade`), streaming its progress and
      ending after `complete`
    * `{"type": "relayClientInstall", "node": n}`: installs that node's relay client
      (`cloud.installRelayClient`), streaming its stages and ending after `complete`
    * `{"type": "localServers", "node": n}`: web servers listening on that node's
      host (`DiscoveredLocalServerList`), then the list whenever it changes
    * `{"type": "devices", "node": n}`: that node's simulators, emulators and
      open device sessions (`DeviceServiceState`), then the whole state on every change
    * `{"type": "projectClones", "node": n}`: that node's project clones in
      progress (`ProjectCloneSnapshot[]`), then the whole list on every change
    * `{"type": "scheduledTasks", "node": n}`: that node's scheduled tasks, then
      the whole list again whenever one changes
    * `{"type": "backgroundPolicy", "node": n}`: that node's background policy
      (`BackgroundPolicySnapshot`), then again whenever it changes
    * `{"type": "pullRequestRefreshes", "node": n}`: that node's pull request
      refresh revision, then each new one (`pullRequests.subscribeRefreshes`)
    * `{"type": "providerAuth", "node": n, "instanceId": id}`: that provider
      instance's sign-in state (`ProviderAuthState`), then changes
    * `{"type": "providerInstall", "node": n, "instanceId": id}`: that provider
      instance's managed runtime installation (`ProviderInstallState`), then changes
    * `{"type": "gitAction", "node": n, "input": GitRunStackedActionInput}`: runs the
      action once and streams its progress, ending with action_finished or
      action_failed

  Client to server:

      {"t": "sub", "id": 1, "shape": {...}, "offset": 1234 | null}
      {"t": "unsub", "id": 1}
      {"t": "ping"}
      {"t": "rpc", "id": 1, "environment": id, "method": m, "payload": ...}
        (a client RPC such as orchestration.dispatchCommand, run where that
        environment is served, as shapes are routed; answered by rpc.result or
        rpc.error, with EnvironmentUnreachableError while its link is down)

  Server to client:

      {"t": "hello", "protocol": 3, "node": n, "environment": id}
        (the environment this node serves, for RPCs about the node itself)
      {"t": "shell", "id", "nodes": [{"node", "online", "environment"}], "rows": [[node, id, kind, row]],
        "links": [{"environment", "origin", "online", "problem"?}]}
      {"t": "shell.links", "id", "links"}   (environments this node links to; the whole list)
      {"t": "shell.environment", "id", "node", "environment"}
      {"t": "shell.rows", "id", "node", "rows": [[id, kind, row]]}
      {"t": "shell.node", "id", "node", "online"}
      {"t": "shell.linkRows", "id", "link", "node", "rows": [[id, kind, row]]}
      {"t": "shell.linkEnvironment", "id", "link", "node", "environment"}
      {"t": "shell.linkNode", "id", "link", "node", "online"}
        (with "links": true: the shell.* changes of the environment `link` names, whose
        nodes are its own; in the snapshot each link has "nodes" and "rows" as the shell
        does; a node that appears is offline until shell.linkNode; a link that leaves
        shell.links takes its nodes and rows with it)
      {"t": "snapshot", "id", "offset", "at", "part", "rows": [[kind, id, entity]], "done"}
      {"t": "events", "id", "offset", "events": [[seq, kind, id, patch, at]]}
      {"t": "live", "id", "offset"}     (caught up; later events are live)
      {"t": "resync", "id", "offset"}   (fell behind: resubscribe from offset)
      {"t": "error", "id", "reason", "detail"?}
      {"t": "config", "id", "node", "config"}
      {"t": "config.settings", "id", "settings"}   (the node's ServerSettings changed)
      {"t": "config.providers", "id", "providers"} (its ServerConfig.providers changed)
      {"t": "config.ready", "id", "environment", "updateOutcome"} (the node moved to
        another version in place: its new descriptor, and how the update went)
      {"t": "serverUpdate", "id", "event"} (ServerSelfUpdateProgressEvent)
      {"t": "relayClientInstall", "id", "event"} (RelayClientInstallProgressEvent)
      {"t": "config.themes", "id", "themes"} (the EnvironmentTheme[] it publishes; after
        the snapshot, then on every change)
      {"t": "config.usageLimitSources", "id", "sources"} (its UsageLimitSourceSnapshot[];
        after the snapshot, then on every change)
      {"t": "terminal", "id", "event"}   (TerminalAttachStreamEvent)
      {"t": "terminals", "id", "event"}  (TerminalMetadataStreamEvent)
      {"t": "vcs", "id", "event"}        (VcsStatusStreamEvent)
      {"t": "gitAction", "id", "event"}  (GitActionProgressEvent)
      {"t": "providerAuth", "id", "state"} (ProviderAuthState)
      {"t": "providerInstall", "id", "state"} (ProviderInstallState)
      {"t": "worktreeSetup", "id", "event"} (WorktreeSetupStreamEvent)
      {"t": "scheduledTasks", "id", "tasks"} (ScheduledTask[])
      {"t": "backgroundPolicy", "id", "policy"} (BackgroundPolicySnapshot)
      {"t": "projectClones", "id", "clones"} (ProjectCloneSnapshot[])
      {"t": "preview", "id", "event"} (PreviewEvent)
      {"t": "previewAutomation", "id", "event"} (PreviewAutomationStreamEvent)
      {"t": "end", "id"}   (the shape is over; unsubscribed)
      {"t": "resourceTelemetry", "id", "snapshot"} (ResourceTelemetrySnapshot)
      {"t": "authAccess", "id", "event"} (AuthAccessStreamEvent)
      {"t": "localServers", "id", "list"} (DiscoveredLocalServerList)
      {"t": "devices", "id", "state"} (DeviceServiceState)
      {"t": "pullRequestRefreshes", "id", "revision"} (non-negative integer)
      {"t": "rpc.result", "id", "result"} / {"t": "rpc.error", "id", "error", "detail"?}
        (`detail` is the contract error as `{"_tag", ...fields}` when there is one)
      {"t": "pong"}

  Shell rows are `OrchestrationV2ThreadShell` (`kind` "thread") or
  `OrchestrationProjectShell` (`kind` "project") in their JSON encoding.

  A `snapshot` with `"part": 0` replaces the client's copy of the shape; later parts
  add to it, and rows arrive in creation order. `events` carry `HalC2.Patch` values,
  already merged per entity, with `at` in unix ms.
  """

  @version 3

  def version, do: @version

  @type request ::
          {:sub, integer,
           :shell
           | {:stream, node, String.t()}
           | {:config, node}
           | {:config, node, :usage_limits_command}
           | {:environment, String.t(), map}, non_neg_integer | nil}
          | {:unsub, integer}
          | {:rpc, integer, String.t(), String.t(), term}
          | :ping

  # The shapes a client may name by environment. The rest are about the node a client
  # talks to (shell, authAccess) or administer one node's host (serverUpdate,
  # relayClientInstall, resourceTelemetry, localServers, devices, preview,
  # previewAutomation, scheduledTasks, backgroundPolicy, providerInstall),
  # and are asked of that node by name. projectClones is routed because a client
  # starts a clone on any environment with a routed rpc and follows it there.
  @routed ~w(stream terminal terminals config vcs gitAction worktreeSetup providerAuth
             pullRequestRefreshes projectClones)

  @doc "The shape types a client may name by environment rather than node."
  def routed, do: @routed

  @doc """
  An environment-named shape as `node` serves it: its node form, decoded. Where the
  shape goes is `HalC2.Links.route/1`'s answer.
  """
  @spec at_node(map, node) :: {:ok, term} | {:error, String.t()}
  def at_node(shape, node),
    do:
      shape
      |> Map.delete("environment")
      |> Map.put("node", Atom.to_string(node))
      |> decode_shape([node])

  @spec decode(binary, [node]) :: {:ok, request} | {:error, String.t()}
  def decode(frame, known_nodes) do
    case JSON.decode!(frame) do
      %{"t" => "sub", "id" => id, "shape" => shape} = msg when is_integer(id) ->
        with {:ok, shape} <- decode_shape(shape, known_nodes),
             do: {:ok, {:sub, id, shape, offset(msg["offset"])}}

      %{"t" => "unsub", "id" => id} when is_integer(id) ->
        {:ok, {:unsub, id}}

      %{"t" => "ping"} ->
        {:ok, :ping}

      %{"t" => "rpc", "id" => id, "environment" => env, "method" => method} = msg
      when is_integer(id) and is_binary(env) and is_binary(method) ->
        {:ok, {:rpc, id, env, method, msg["payload"]}}

      _ ->
        {:error, "unknown message"}
    end
  rescue
    _ -> {:error, "invalid json"}
  end

  # By environment instead of node: routed where that environment is served
  # (`HalC2.Links.route/1`). The rest of the shape must be valid in its node form.
  defp decode_shape(%{"type" => type, "environment" => env} = shape, _nodes)
       when type in @routed and is_binary(env) do
    with {:ok, _} <- at_node(shape, node()), do: {:ok, {:environment, env, shape}}
  end

  defp decode_shape(%{"type" => "shell", "links" => true}, _nodes), do: {:ok, {:shell, :links}}
  defp decode_shape(%{"type" => "shell"}, _nodes), do: {:ok, :shell}

  defp decode_shape(%{"type" => "stream", "node" => node, "stream" => id}, nodes)
       when is_binary(id) do
    # Only nodes this server knows about; never create atoms from client input.
    case Enum.find(nodes, &(Atom.to_string(&1) == node)) do
      nil -> {:error, "unknown node"}
      node -> {:ok, {:stream, node, id}}
    end
  end

  defp decode_shape(%{"type" => "config", "usageLimitsCommand" => true} = shape, nodes) do
    with {:ok, config} <- decode_shape(Map.delete(shape, "usageLimitsCommand"), nodes),
         do: {:ok, Tuple.insert_at(config, 2, :usage_limits_command)}
  end

  defp decode_shape(%{"type" => "config", "node" => node}, nodes) do
    case Enum.find(nodes, &(Atom.to_string(&1) == node)) do
      nil -> {:error, "unknown node"}
      node -> {:ok, {:config, node}}
    end
  end

  defp decode_shape(%{"type" => "terminal", "node" => node, "input" => %{} = input}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:terminal, node, input}}
  end

  defp decode_shape(%{"type" => "vcs", "node" => node, "cwd" => cwd}, nodes)
       when is_binary(cwd) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:vcs, node, cwd}}
  end

  defp decode_shape(
         %{"type" => "gitAction", "node" => node, "input" => %{"actionId" => id} = input},
         nodes
       )
       when is_binary(id) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:git_action, node, input}}
  end

  defp decode_shape(%{"type" => "authAccess"}, _nodes), do: {:ok, :auth_access}

  defp decode_shape(%{"type" => "resourceTelemetry", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:resource_telemetry, node}}
  end

  defp decode_shape(%{"type" => "preview", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:preview, node}}
  end

  defp decode_shape(
         %{"type" => "previewAutomation", "node" => node, "host" => %{"clientId" => id} = host},
         nodes
       )
       when is_binary(id) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:preview_automation, node, host}}
  end

  defp decode_shape(%{"type" => "serverUpdate", "node" => node, "input" => %{} = input}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:server_update, node, input}}
  end

  defp decode_shape(%{"type" => "relayClientInstall", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:relay_client_install, node}}
  end

  defp decode_shape(%{"type" => "localServers", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:local_servers, node}}
  end

  defp decode_shape(%{"type" => "devices", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:devices, node}}
  end

  defp decode_shape(%{"type" => "projectClones", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:project_clones, node}}
  end

  defp decode_shape(%{"type" => "scheduledTasks", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:scheduled_tasks, node}}
  end

  defp decode_shape(%{"type" => "backgroundPolicy", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:background_policy, node}}
  end

  defp decode_shape(%{"type" => "pullRequestRefreshes", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:pull_request_refreshes, node}}
  end

  defp decode_shape(%{"type" => "worktreeSetup", "node" => node, "threadId" => id}, nodes)
       when is_binary(id) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:worktree_setup, node, id}}
  end

  defp decode_shape(%{"type" => "providerAuth", "node" => node, "instanceId" => id}, nodes)
       when is_binary(id) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:provider_auth, node, id}}
  end

  defp decode_shape(%{"type" => "providerInstall", "node" => node, "instanceId" => id}, nodes)
       when is_binary(id) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:provider_install, node, id}}
  end

  defp decode_shape(%{"type" => "terminals", "node" => node}, nodes) do
    with {:ok, node} <- known_node(node, nodes), do: {:ok, {:terminals, node}}
  end

  defp decode_shape(_, _), do: {:error, "unknown shape"}

  defp known_node(name, nodes) do
    case Enum.find(nodes, &(Atom.to_string(&1) == name)) do
      nil -> {:error, "unknown node"}
      node -> {:ok, node}
    end
  end

  defp offset(n) when is_integer(n) and n >= 0, do: n
  defp offset(_), do: nil

  @spec encode(map) :: {:text, iodata}
  def encode(message), do: {:text, JSON.encode_to_iodata!(message)}

  @doc """
  Merges consecutive patches to the same entity. The result is ordered by each
  entity's latest seq, which is all the ordering the fold depends on.
  """
  @spec coalesce([HalC2.Store.event()]) :: [HalC2.Store.event()]
  def coalesce(events) do
    events
    |> Enum.reduce(%{}, fn %{kind: k, entity: id} = event, acc ->
      Map.update(acc, {k, id}, event, fn prev ->
        %{event | patch: HalC2.Patch.compose(prev.patch, event.patch)}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.seq)
  end
end
