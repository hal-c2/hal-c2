defmodule HalC2.ProviderAuth do
  @moduledoc """
  Signing a provider instance in on this MC (`provider.auth.*`), for the agents
  that keep their own credentials: ACP agents today (`HalC2.Acp.Auth`).

  One process per instance holds its `ProviderAuthState` and runs at most one
  sign-in. It starts with its first subscriber or request and stops once no one
  watches and nothing runs. The sign-in itself is a linked worker that reports
  `{:auth_interaction, flow, interaction, responder}` (a URL to open, or a login
  terminal's output) and `{:auth_verifying, flow}`, and exits `:normal` when the
  agent can open a session again; client responses go to the responder as
  `{:auth_response, response}`.

  A flow belongs to the client that started it (its `owner/2`; `nil` is the MC
  itself, which may act on any flow). Only the owner answers or cancels it, and while it runs no one else starts
  another; other clients see it running, without its address, code or id (`view/2`).
  Subscribers get the whole state with the owner under `"_owner"`, and each socket
  shows its client `view/2` of it. Signing out is anyone's, and runs off this process
  so that nothing starts meanwhile.
  """

  use GenServer, restart: :temporary

  require Logger

  @registry HalC2.ProviderAuth.Registry
  @supervisor HalC2.ProviderAuth.Supervisor
  @active ~w(starting waiting verifying)
  @in_progress "Provider setup is already in progress."
  @not_active "This sign-in is no longer active in this client."

  # --- RPCs ------------------------------------------------------------------------

  @doc "A `provider.auth.*` RPC for the client `owner` (see the moduledoc)."
  def handle("provider.auth.start", input, owner), do: start(input, owner)
  def handle("provider.auth.respond", input, owner), do: respond(input, owner)
  def handle("provider.auth.cancel", input, owner), do: cancel(input, owner)
  def handle("provider.auth.logout", input, owner), do: logout(input, owner)
  def handle("provider.auth.complete", input, owner), do: complete(input, owner)
  def handle(_method, _input, _owner), do: {:error, "unknown method"}

  @doc "`provider.auth.start`: signs in with a method (the first one by default)."
  def start(%{"instanceId" => instance} = input, owner \\ nil),
    do: call(instance, {:start, input["methodId"], owner})

  @doc "`provider.auth.respond`: answers the flow's current interaction."
  def respond(%{"instanceId" => instance} = input, owner \\ nil),
    do:
      call(
        instance,
        {:respond, input["flowId"], input["interactionId"], input["response"], owner}
      )

  @doc "`provider.auth.cancel`."
  def cancel(%{"instanceId" => instance} = input, owner \\ nil),
    do: call(instance, {:cancel, input["flowId"], owner})

  @doc "`provider.auth.logout`."
  def logout(%{"instanceId" => instance}, owner \\ nil),
    do: call(instance, {:logout, nil, owner})

  @doc """
  `provider.auth.complete`: the redirect URL of a browser sign-in, pasted from
  another device (Antigravity only).
  """
  def complete(%{"instanceId" => instance} = input, owner \\ nil) do
    if antigravity?(instance),
      do: call(instance, {:complete, input["flowId"], input["callbackUrl"], owner}),
      else: error(instance, "complete", "This provider does not accept a pasted redirect URL.")
  end

  @doc """
  Signs an instance out from one of its own thread sessions (`/logout`): its other
  sessions stop, `session` stays for its caller to close.
  """
  def logout_from(instance, session), do: call(instance, {:logout, session, nil})

  @doc """
  Reads a running instance's sign-in methods again (`server.refreshProviders`); the
  ones already listed stay if the agent cannot say.
  """
  def refresh(instance) do
    case lookup(instance) do
      [{server, _}] -> send(server, :refresh)
      [] -> :ok
    end

    :ok
  end

  @doc """
  The owner a socket on `node` acts as: its paired session, so a device's sockets are
  one client, or for the MC's own token (`nil`) that MC's local tools, one client too.
  A sign-in may run on another MC of the cluster than the socket's, and a session, or
  the own token, means something only on its own MC, so each is qualified by its node.
  """
  def owner(session, node \\ node())
  def owner(nil, node), do: "own-token@#{node}"
  def owner(session, node), do: "session:#{session}@#{node}"

  @doc """
  What the client `viewer` (`nil`: the MC itself, which sees all) is shown of a state
  a subscriber got: someone else's flow without its id, address, interaction or expiry.
  """
  def view(auth, viewer) do
    {owner, auth} = Map.pop(auth, "_owner")

    if owner == nil or viewer == nil or owner == viewer do
      auth
    else
      Map.merge(auth, %{
        "flowId" => nil,
        "authorizationUrl" => nil,
        "interaction" => nil,
        "expiresAt" => nil,
        "message" =>
          if(auth["phase"] in @active,
            do: "Sign-in is in progress in another client.",
            else: auth["message"]
          )
      })
    end
  end

  @doc "Whether a sign-in is running for an instance."
  def signing_in?(instance) do
    case lookup(instance) do
      [{server, _}] -> GenServer.call(server, :signing_in?, 5_000)
      [] -> false
    end
  catch
    :exit, _ -> false
  end

  @doc """
  Adds `pid` as a subscriber under `ref` (`HalC2.Watchers`); it gets
  `{:hal_c2_provider_auth, instance, state}`.
  """
  def subscribe(instance, pid, ref \\ nil), do: call(instance, {:subscribe, pid, ref})

  def unsubscribe(instance, pid, ref \\ nil) do
    case lookup(instance) do
      [{server, _}] -> GenServer.cast(server, {:unsubscribe, pid, ref})
      [] -> :ok
    end
  end

  # The registry is gone with the services it belongs to (a scenario's teardown):
  # nothing is subscribed any more.
  defp lookup(instance) do
    Registry.lookup(@registry, instance)
  rescue
    ArgumentError -> []
  end

  defp call(instance, message) do
    cond do
      not HalC2.Acp.agent?(instance) ->
        error(instance, "start", "This provider does not sign in here.")

      true ->
        server =
          case DynamicSupervisor.start_child(@supervisor, {__MODULE__, instance}) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end

        GenServer.call(server, message, 60_000)
    end
  end

  def start_link(instance),
    do: GenServer.start_link(__MODULE__, instance, name: {:via, Registry, {@registry, instance}})

  # --- server ----------------------------------------------------------------------

  @impl true
  def init(instance) do
    Process.flag(:trap_exit, true)
    read_methods(instance)

    {:ok,
     %{
       instance: instance,
       auth: idle(instance, nil),
       methods: nil,
       watchers: %{},
       flow: nil,
       stopping: nil
     }}
  end

  defp read_methods(instance) do
    server = self()
    Task.start(fn -> send(server, {:methods, auth_module(instance).methods(instance)}) end)
  end

  defp idle(instance, message) do
    %{
      "instanceId" => instance,
      "phase" => "idle",
      "flowId" => nil,
      "authorizationUrl" => nil,
      "expiresAt" => nil,
      "message" => message,
      "interaction" => nil,
      "credentialOwner" => "provider",
      "_owner" => nil
    }
  end

  @impl true
  def handle_call({:subscribe, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
    {:reply, {:ok, state.auth}, %{state | watchers: watchers}}
  end

  def handle_call(:signing_in?, _from, state), do: {:reply, state.flow != nil, state}

  def handle_call({:start, _method, _owner}, _from, %{stopping: %{}} = state),
    do: {:reply, error(state.instance, "start", @in_progress), state}

  def handle_call({:start, _method, owner}, _from, %{flow: %{} = flow} = state) do
    if owns?(flow, owner),
      do: {:reply, {:ok, view(state.auth, owner)}, state},
      else: {:reply, error(state.instance, "start", @in_progress), state}
  end

  def handle_call({:start, method_id, owner}, _from, state) do
    methods = state.methods || []

    method_id =
      if antigravity?(state.instance),
        do: HalC2.Acp.Antigravity.config(state.instance)["authMethod"],
        else: method_id || default_method(state.instance, methods)

    refusal = HalC2.Acp.sign_in_refusal(state.instance)

    if refusal do
      {:reply, error(state.instance, "start", refusal), state}
    else
      start_flow(method_id, methods, owner, state)
    end
  end

  def handle_call({:respond, flow_id, interaction_id, response, owner}, _from, state) do
    interaction = state.auth["interaction"]

    cond do
      not active?(state, flow_id, owner) ->
        {:reply, error(state.instance, "respond", @not_active), state}

      is_pid(state.flow.responder) and is_map(interaction) and is_map(response) and
        interaction["id"] == interaction_id and interaction["type"] == response["type"] ->
        send(state.flow.responder, {:auth_response, response})
        {:reply, {:ok, view(state.auth, owner)}, state}

      true ->
        {:reply,
         error(state.instance, "respond", "This sign-in interaction is no longer available."),
         state}
    end
  end

  def handle_call({:cancel, flow_id, owner}, _from, state) do
    if active?(state, flow_id, owner) do
      state = end_flow(state, "cancelled", text(state.instance, :cancelled))
      {:reply, {:ok, view(state.auth, owner)}, state}
    else
      {:reply, error(state.instance, "cancel", @not_active), state}
    end
  end

  def handle_call({:complete, flow_id, url, owner}, _from, state) do
    interaction = state.auth["interaction"]

    result =
      cond do
        not active?(state, flow_id, owner) ->
          {:error, @not_active}

        not is_map(interaction) ->
          {:error, "Wait for the Google sign-in link before you send a redirect URL."}

        state.flow[:callback] ->
          {:error, "The sign-in response was already sent. Wait for Google to finish."}

        true ->
          with {:ok, pending} <- authorization(interaction["url"]),
               {:ok, uri} <-
                 HalC2.Acp.Antigravity.Auth.validate_callback(pending, to_string(url || "")),
               :ok <- HalC2.Acp.Antigravity.Auth.forward_callback(uri),
               do: :ok
      end

    case result do
      :ok ->
        state =
          publish(put_in(state.flow[:callback], true), %{
            "phase" => "verifying",
            "interaction" => nil,
            "authorizationUrl" => nil,
            "message" => "Waiting for Google to finish sign-in."
          })

        {:reply, {:ok, view(state.auth, owner)}, state}

      {:error, detail} ->
        {:reply, error(state.instance, "complete", detail), state}
    end
  end

  def handle_call({:logout, _session, _owner}, _from, %{stopping: %{}} = state),
    do: {:reply, error(state.instance, "logout", "Provider setup is already stopping."), state}

  # The agent signs out off this process, which meanwhile refuses to start a sign-in;
  # the caller is answered once it is done.
  def handle_call({:logout, session, owner}, from, state) do
    state =
      if state.flow, do: end_flow(state, "idle", text(state.instance, :logout_ends)), else: state

    instance = state.instance
    server = self()

    worker =
      spawn_link(fn ->
        send(server, {:logged_out, self(), auth_module(instance).logout(instance, session)})
      end)

    {:noreply, %{state | stopping: %{from: from, worker: worker, owner: owner}}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid, ref}, state) do
    maybe_stop(%{state | watchers: HalC2.Watchers.remove(state.watchers, pid, ref)})
  end

  @impl true
  def handle_info({:methods, {:ok, methods}}, state) do
    state = %{state | methods: methods}
    {:noreply, publish(state, %{"methods" => methods})}
  end

  # Methods already listed stay; the user is told why they could not be read again.
  def handle_info({:methods, {:error, message}}, state) do
    state = %{state | methods: state.methods || []}
    {:noreply, publish(state, %{"methods" => state.methods, "message" => message})}
  end

  def handle_info(:refresh, state) do
    read_methods(state.instance)
    {:noreply, state}
  end

  def handle_info({:logged_out, worker, result}, %{stopping: %{worker: worker}} = state),
    do: logged_out(state, result)

  def handle_info({:EXIT, worker, reason}, %{stopping: %{worker: worker}} = state)
      when reason != :normal do
    Logger.warning("#{state.instance} sign-out failed: #{inspect(reason)}")
    logged_out(state, {:error, text(state.instance, :logout_failed)})
  end

  def handle_info(
        {:auth_interaction, flow_id, interaction, responder},
        %{flow: %{id: flow_id}} = state
      ) do
    state = put_in(state.flow.responder, responder)

    url = if interaction["type"] in ["browser", "deviceCode"], do: interaction["url"]

    {:noreply,
     publish(state, %{
       "phase" => "waiting",
       "interaction" => interaction,
       "authorizationUrl" => url,
       "message" => text(state.instance, :waiting)
     })}
  end

  def handle_info({:auth_verifying, flow_id}, %{flow: %{id: flow_id}} = state) do
    state = put_in(state.flow.responder, nil)

    {:noreply,
     publish(state, %{
       "phase" => "verifying",
       "interaction" => nil,
       "authorizationUrl" => nil,
       "message" => text(state.instance, :verifying)
     })}
  end

  def handle_info({:expire, flow_id}, %{flow: %{id: flow_id}} = state),
    do: {:noreply, end_flow(state, "failed", text(state.instance, :expired))}

  def handle_info({:EXIT, worker, reason}, %{flow: %{worker: worker}} = state) do
    state = %{state | flow: nil}

    state =
      case reason do
        :normal ->
          # The agent reads its new credentials when it is next started.
          HalC2.Acp.forget(state.instance)
          HalC2.Settings.notify_providers()
          finish(state, "succeeded", text(state.instance, :succeeded))

        {:shutdown, {:failed, message}} ->
          finish(state, "failed", message)

        other ->
          Logger.warning("#{state.instance} sign-in failed: #{inspect(other)}")
          finish(state, "failed", "Sign-in failed. Start again.")
      end

    maybe_stop(state)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    maybe_stop(%{state | watchers: Map.delete(state.watchers, pid)})
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- helpers ---------------------------------------------------------------------

  # Signed out, or not: the flow is gone either way, and so is its owner.
  defp logged_out(state, result) do
    %{from: from, owner: owner} = state.stopping
    state = %{state | stopping: nil}

    {phase, message} =
      case result do
        :ok -> {"idle", text(state.instance, :signed_out)}
        {:error, _} -> {"failed", text(state.instance, :logout_failed)}
      end

    state = %{state | auth: Map.merge(idle(state.instance, message), methods(state))}
    state = publish(state, %{"phase" => phase})

    GenServer.reply(
      from,
      case result do
        :ok -> {:ok, view(state.auth, owner)}
        {:error, detail} -> error(state.instance, "logout", detail)
      end
    )

    maybe_stop(state)
  end

  # Whether `owner` may act on the running flow `flow_id`: its own, unexpired.
  defp active?(%{flow: %{id: flow_id} = flow}, flow_id, owner),
    do: owns?(flow, owner) and System.system_time(:millisecond) < flow.expires

  defp active?(_state, _flow_id, _owner), do: false

  defp owns?(flow, owner), do: owner == nil or flow.owner == owner

  defp start_flow(method_id, methods, owner, state) do
    if method_id != nil and (methods == [] or Enum.any?(methods, &(&1["id"] == method_id))) do
      flow_id = HalC2.Environment.uuid4()
      timeout = Application.get_env(:hal_c2, :provider_auth_timeout_ms, 300_000)
      expires = System.system_time(:millisecond) + timeout
      server = self()
      instance = state.instance

      worker =
        spawn_link(fn -> auth_module(instance).login(instance, method_id, server, flow_id) end)

      Process.send_after(self(), {:expire, flow_id}, timeout)
      flow = %{id: flow_id, worker: worker, responder: nil, owner: owner, expires: expires}

      state =
        publish(%{state | flow: flow}, %{
          "phase" => "starting",
          "flowId" => flow_id,
          "expiresAt" => iso(expires),
          "message" => text(state.instance, :starting),
          "interaction" => nil,
          "authorizationUrl" => nil,
          "_owner" => owner
        })

      {:reply, {:ok, view(state.auth, owner)}, state}
    else
      {:reply,
       error(state.instance, "start", "The provider did not advertise this sign-in method."),
       state}
    end
  end

  defp end_flow(state, phase, message) do
    Process.unlink(state.flow.worker)
    Process.exit(state.flow.worker, :kill)
    finish(%{state | flow: nil}, phase, message)
  end

  # A finished flow keeps its id, so clients can tell which sign-in ended.
  defp finish(state, phase, message) do
    publish(state, %{
      "phase" => phase,
      "interaction" => nil,
      "authorizationUrl" => nil,
      "expiresAt" => nil,
      "message" => message
    })
  end

  defp publish(state, patch) do
    state = %{state | auth: Map.merge(state.auth, patch)}
    broadcast(state)
    state
  end

  defp broadcast(state) do
    HalC2.Watchers.notify(state.watchers, {:hal_c2_provider_auth, state.instance, state.auth})
  end

  defp methods(%{methods: nil}), do: %{}
  defp methods(%{methods: methods}), do: %{"methods" => methods}

  defp maybe_stop(%{watchers: watchers, flow: nil, stopping: nil} = state)
       when map_size(watchers) == 0,
       do: {:stop, :normal, state}

  defp maybe_stop(state), do: {:noreply, state}

  # The instance's configured method, else the first one the agent listed.
  defp default_method(instance, methods) do
    configured =
      get_in(HalC2.Settings.settings(), ["providerInstances", instance, "config", "authMethodId"])

    if(is_binary(configured) and configured != "", do: configured) ||
      (List.first(methods) || %{})["id"]
  end

  defp antigravity?(instance), do: HalC2.Acp.driver(instance) == "antigravity"

  # `:provider_auth_module` stands in for both in the property tests.
  defp auth_module(instance) do
    Application.get_env(:hal_c2, :provider_auth_module) ||
      if(antigravity?(instance), do: HalC2.Acp.Antigravity.Auth, else: HalC2.Acp.Auth)
  end

  defp authorization(url) when is_binary(url) do
    case HalC2.Acp.Antigravity.Auth.authorization(url) do
      {:ok, pending} -> {:ok, pending}
      :error -> {:error, "This sign-in is no longer active in this client."}
    end
  end

  defp authorization(_url), do: {:error, "This sign-in is no longer active in this client."}

  # What a flow says at each step: Antigravity names Google, others are generic.
  defp text(instance, key) do
    if antigravity?(instance) do
      browser? =
        HalC2.Acp.Antigravity.browser?(HalC2.Acp.Antigravity.config(instance)["authMethod"])

      case key do
        :starting when browser? ->
          "Starting Google sign-in."

        :starting ->
          "Checking credentials."

        :waiting ->
          "Open the Google sign-in link. If you are remote, paste the redirect URL here."

        :verifying ->
          "Checking Antigravity access and models."

        :succeeded when browser? ->
          "Signed in with Google."

        :succeeded ->
          "Connected to Antigravity."

        :expired ->
          "Google sign-in expired. Start sign-in again."

        :cancelled ->
          "Google sign-in was cancelled."

        :logout_ends ->
          "Google sign-in was cancelled by sign-out."

        :signed_out ->
          "Signed out of Google."

        :logout_failed ->
          "Antigravity sign-out failed. Try again."
      end
    else
      case key do
        :starting -> "Starting sign-in."
        :waiting -> "Complete sign-in to continue."
        :verifying -> "Checking provider sign-in."
        :succeeded -> "Sign-in complete."
        :expired -> "Sign-in expired. Start again."
        :cancelled -> "Sign-in cancelled."
        :logout_ends -> nil
        :signed_out -> "Signed out."
        :logout_failed -> "Could not sign out. Try again."
      end
    end
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp error(instance, operation, detail) do
    {:error,
     %{
       "_tag" => "ProviderSetupError",
       "instanceId" => instance,
       "operation" => operation,
       "detail" => detail,
       "message" => detail
     }}
  end
end
