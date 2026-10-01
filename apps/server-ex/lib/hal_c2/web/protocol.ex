defmodule HalC2.Web.Protocol do
  @moduledoc """
  The client wire protocol (version 3): JSON text frames over one WebSocket.

  A client subscribes to *shapes* and keeps each one in sync from an offset, the way
  Electric shapes work:

    * `{"type": "shell"}`: every MC's environment and every project and thread
      summary on it
    * `{"type": "shell", "links": true}`: the same, with each link also carrying its
      environment's MCs and rows (`HalC2.Links.Rows`), then their changes
    * `{"type": "stream", "mc": n, "stream": id}`: one project or thread
    * `{"type": "config", "mc": n}`: that MC's `ServerConfig` and name, then its settings and providers as they change;
      with `"usageLimitsCommand": true` (a client that answers `/usage-limits` itself),
      every provider with limits to show offers that command
    * `{"type": "terminal", "mc": n, "input": TerminalAttachInput}`: one terminal,
      opened if needed; a snapshot, then its events
    * `{"type": "terminals", "mc": n}`: that MC's terminal summaries, then changes
    * the shapes in `routed/0` with `"environment": id` instead of `"mc"`: on this
      MC or the cluster member serving that environment, else through this MC's
      link to it or to its cluster (`HalC2.Links.route/1`), whose token's scopes apply
      there (a linked stream resumes from `offset` and resyncs as a local one does).
      While that link is down the subscription fails at once with an error whose
      `detail` is `{"_tag": "EnvironmentUnreachableError", "environmentId", "reason"}`,
      `reason` being `"unreachable"` or `"refused"` (pair it again)
    * `{"type": "vcs", "mc": n, "cwd": dir}`: a checkout's git status, then changes
    * `{"type": "worktreeSetup", "mc": n, "threadId": id}`: a new thread's worktree
      setup (`WorktreeSetupStreamEvent`: null, or a snapshot), then changes
    * `{"type": "authAccess"}`: this MC's pairing links and paired clients
      (`AuthAccessStreamEvent`), for a session with `access:read`
    * `{"type": "resourceTelemetry", "mc": n}`: that MC's resource monitor
      (`ResourceTelemetrySnapshot`), sampled every few seconds while subscribed
    * `{"type": "preview", "mc": n}`: that MC's preview tab events (`PreviewEvent`)
    * `{"type": "previewAutomation", "mc": n, "host": PreviewAutomationHost}`: this
      client as that MC's browser automation host; agents' browser actions
      (`PreviewAutomationStreamEvent`) until the MC drops the host, which ends it
    * `{"type": "serverUpdate", "mc": n, "input": ServerSelfUpdateInput}`: moves
      that MC to another version (`HalC2.Upgrade`), streaming its progress and
      ending after `complete`
    * `{"type": "relayClientInstall", "mc": n}`: installs that MC's relay client
      (`cloud.installRelayClient`), streaming its stages and ending after `complete`
    * `{"type": "localServers", "mc": n}`: web servers listening on that MC's
      host (`DiscoveredLocalServerList`), then the list whenever it changes
    * `{"type": "devices", "mc": n}`: that MC's simulators, emulators and
      open device sessions (`DeviceServiceState`), then the whole state on every change
    * `{"type": "projectClones", "mc": n}`: that MC's project clones in
      progress (`ProjectCloneSnapshot[]`), then the whole list on every change
    * `{"type": "scheduledTasks", "mc": n}`: that MC's scheduled tasks, then
      the whole list again whenever one changes
    * `{"type": "backgroundPolicy", "mc": n}`: that MC's background policy
      (`BackgroundPolicySnapshot`), then again whenever it changes
    * `{"type": "pullRequestRefreshes", "mc": n}`: that MC's pull request
      refresh revision, then each new one (`pullRequests.subscribeRefreshes`)
    * `{"type": "providerAuth", "mc": n, "instanceId": id}`: that provider
      instance's sign-in state (`ProviderAuthState`), then changes
    * `{"type": "providerInstall", "mc": n, "instanceId": id}`: that provider
      instance's managed runtime installation (`ProviderInstallState`), then changes
    * `{"type": "gitAction", "mc": n, "input": GitRunStackedActionInput}`: runs the
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

      {"t": "hello", "protocol": 3, "mc": n, "environment": id}
        (the environment this MC serves, for RPCs about the MC itself)
      {"t": "shell", "id", "mcs": [{"mc", "online", "environment"}], "rows": [[mc, id, kind, row]],
        "links": [{"environment", "origin", "online", "problem"?}]}
      {"t": "shell.links", "id", "links"}   (environments this MC links to; the whole list)
      {"t": "shell.environment", "id", "mc", "environment"}
      {"t": "shell.rows", "id", "mc", "rows": [[id, kind, row]]}
      {"t": "shell.mc", "id", "mc", "online"}
      {"t": "shell.linkRows", "id", "link", "mc", "rows": [[id, kind, row]]}
      {"t": "shell.linkEnvironment", "id", "link", "mc", "environment"}
      {"t": "shell.linkMc", "id", "link", "mc", "online"}
        (with "links": true: the shell.* changes of the environment `link` names, whose
        MCs are its own; in the snapshot each link has "mcs" and "rows" as the shell
        does; an MC that appears is offline until shell.linkMc; a link that leaves
        shell.links takes its MCs and rows with it)
      {"t": "snapshot", "id", "offset", "at", "part", "rows": [[kind, id, entity]], "done"}
      {"t": "events", "id", "offset", "events": [[seq, kind, id, patch, at]]}
      {"t": "live", "id", "offset"}     (caught up; later events are live)
      {"t": "resync", "id", "offset"}   (fell behind: resubscribe from offset)
      {"t": "error", "id", "reason", "detail"?}
      {"t": "config", "id", "mc", "config"}
      {"t": "config.settings", "id", "settings"}   (the MC's ServerSettings changed)
      {"t": "config.providers", "id", "providers"} (its ServerConfig.providers changed)
      {"t": "config.ready", "id", "environment", "updateOutcome"} (the MC moved to
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

  # The shapes a client may name by environment. The rest are about the MC a client
  # talks to (shell, authAccess) or administer one MC's host (serverUpdate,
  # relayClientInstall, resourceTelemetry, localServers, devices, preview,
  # previewAutomation, scheduledTasks, backgroundPolicy, providerInstall),
  # and are asked of that MC by name. projectClones is routed because a client
  # starts a clone on any environment with a routed rpc and follows it there.
  @routed ~w(stream terminal terminals config vcs gitAction worktreeSetup providerAuth
             pullRequestRefreshes projectClones)

  @doc "The shape types a client may name by environment rather than MC."
  def routed, do: @routed

  @doc """
  An environment-named shape as `mc` serves it: its MC form, decoded. Where the
  shape goes is `HalC2.Links.route/1`'s answer.
  """
  @spec at_mc(map, node) :: {:ok, term} | {:error, String.t()}
  def at_mc(shape, mc),
    do:
      shape
      |> Map.delete("environment")
      |> Map.put("mc", Atom.to_string(mc))
      |> decode_shape([mc])

  @spec decode(binary, [node]) :: {:ok, request} | {:error, String.t()}
  def decode(frame, known_mcs) do
    case JSON.decode!(frame) do
      %{"t" => "sub", "id" => id, "shape" => shape} = msg when is_integer(id) ->
        with {:ok, shape} <- decode_shape(shape, known_mcs),
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

  # By environment instead of MC: routed where that environment is served
  # (`HalC2.Links.route/1`). The rest of the shape must be valid in its MC form.
  defp decode_shape(%{"type" => type, "environment" => env} = shape, _mcs)
       when type in @routed and is_binary(env) do
    with {:ok, _} <- at_mc(shape, node()), do: {:ok, {:environment, env, shape}}
  end

  defp decode_shape(%{"type" => "shell", "links" => true}, _mcs), do: {:ok, {:shell, :links}}
  defp decode_shape(%{"type" => "shell"}, _mcs), do: {:ok, :shell}

  defp decode_shape(%{"type" => "stream", "mc" => mc, "stream" => id}, mcs)
       when is_binary(id) do
    # Only MCs this server knows about; never create atoms from client input.
    case Enum.find(mcs, &(Atom.to_string(&1) == mc)) do
      nil -> {:error, "unknown MC"}
      mc -> {:ok, {:stream, mc, id}}
    end
  end

  defp decode_shape(%{"type" => "config", "usageLimitsCommand" => true} = shape, mcs) do
    with {:ok, config} <- decode_shape(Map.delete(shape, "usageLimitsCommand"), mcs),
         do: {:ok, Tuple.insert_at(config, 2, :usage_limits_command)}
  end

  defp decode_shape(%{"type" => "config", "mc" => mc}, mcs) do
    case Enum.find(mcs, &(Atom.to_string(&1) == mc)) do
      nil -> {:error, "unknown MC"}
      mc -> {:ok, {:config, mc}}
    end
  end

  defp decode_shape(%{"type" => "terminal", "mc" => mc, "input" => %{} = input}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:terminal, mc, input}}
  end

  defp decode_shape(%{"type" => "vcs", "mc" => mc, "cwd" => cwd}, mcs)
       when is_binary(cwd) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:vcs, mc, cwd}}
  end

  defp decode_shape(
         %{"type" => "gitAction", "mc" => mc, "input" => %{"actionId" => id} = input},
         mcs
       )
       when is_binary(id) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:git_action, mc, input}}
  end

  defp decode_shape(%{"type" => "authAccess"}, _mcs), do: {:ok, :auth_access}

  defp decode_shape(%{"type" => "resourceTelemetry", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:resource_telemetry, mc}}
  end

  defp decode_shape(%{"type" => "preview", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:preview, mc}}
  end

  defp decode_shape(
         %{"type" => "previewAutomation", "mc" => mc, "host" => %{"clientId" => id} = host},
         mcs
       )
       when is_binary(id) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:preview_automation, mc, host}}
  end

  defp decode_shape(%{"type" => "serverUpdate", "mc" => mc, "input" => %{} = input}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:server_update, mc, input}}
  end

  defp decode_shape(%{"type" => "relayClientInstall", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:relay_client_install, mc}}
  end

  defp decode_shape(%{"type" => "localServers", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:local_servers, mc}}
  end

  defp decode_shape(%{"type" => "devices", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:devices, mc}}
  end

  defp decode_shape(%{"type" => "projectClones", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:project_clones, mc}}
  end

  defp decode_shape(%{"type" => "scheduledTasks", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:scheduled_tasks, mc}}
  end

  defp decode_shape(%{"type" => "backgroundPolicy", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:background_policy, mc}}
  end

  defp decode_shape(%{"type" => "pullRequestRefreshes", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:pull_request_refreshes, mc}}
  end

  defp decode_shape(%{"type" => "worktreeSetup", "mc" => mc, "threadId" => id}, mcs)
       when is_binary(id) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:worktree_setup, mc, id}}
  end

  defp decode_shape(%{"type" => "providerAuth", "mc" => mc, "instanceId" => id}, mcs)
       when is_binary(id) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:provider_auth, mc, id}}
  end

  defp decode_shape(%{"type" => "providerInstall", "mc" => mc, "instanceId" => id}, mcs)
       when is_binary(id) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:provider_install, mc, id}}
  end

  defp decode_shape(%{"type" => "terminals", "mc" => mc}, mcs) do
    with {:ok, mc} <- known_mc(mc, mcs), do: {:ok, {:terminals, mc}}
  end

  defp decode_shape(_, _), do: {:error, "unknown shape"}

  defp known_mc(name, mcs) do
    case Enum.find(mcs, &(Atom.to_string(&1) == name)) do
      nil -> {:error, "unknown MC"}
      mc -> {:ok, mc}
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
