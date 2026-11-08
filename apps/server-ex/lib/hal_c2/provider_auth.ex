defmodule HalC2.ProviderAuth do
  @moduledoc """
  Signing a provider instance in on this MC (`provider.auth.*`), for the agents
  that keep their own credentials: ACP agents (`HalC2.Acp.Auth`), and Codex
  instances whose ChatGPT account HAL-C2 connects (`HalC2.Codex.ChatGpt`).

  One process per instance holds its `ProviderAuthState` and runs at most one
  sign-in. It starts with its first subscriber or request and stops once no one
  watches and nothing runs. The sign-in itself is a linked worker that reports
  `{:auth_interaction, flow, interaction, responder}` (a URL to open, or a login
  terminal's output) and `{:auth_verifying, flow}`, and exits `:normal` when the
  agent can open a session again (`{:shutdown, {:succeeded, message}}` when the
  success has something to say) or `{:shutdown, {:failed, message}}`; client
  responses go to the responder as `{:auth_response, response}`.

  Every client of the MC sees the same flow: an MC's clients are one user's
  paired devices.
  """

  use GenServer, restart: :temporary

  require Logger

  @registry HalC2.ProviderAuth.Registry
  @supervisor HalC2.ProviderAuth.Supervisor
  @timeout_ms 300_000

  # --- RPCs ------------------------------------------------------------------------

  @doc "`provider.auth.start`: signs in with a method (the first one by default)."
  def start(%{"instanceId" => instance} = input),
    do: call(instance, {:start, input["methodId"]})

  @doc "`provider.auth.respond`: answers the flow's current interaction."
  def respond(%{"instanceId" => instance} = input),
    do: call(instance, {:respond, input["flowId"], input["interactionId"], input["response"]})

  @doc "`provider.auth.cancel`."
  def cancel(%{"instanceId" => instance, "flowId" => flow_id}),
    do: call(instance, {:cancel, flow_id})

  @doc "`provider.auth.logout`."
  def logout(%{"instanceId" => instance}), do: call(instance, :logout)

  @doc """
  `provider.auth.complete`: the redirect URL of a browser sign-in, pasted from
  another device (Antigravity, and a ChatGPT sign-in of Codex).
  """
  def complete(%{"instanceId" => instance} = input) do
    if antigravity?(instance) or codex?(instance),
      do: call(instance, {:complete, input["flowId"], input["callbackUrl"]}),
      else: error(instance, "complete", "This provider does not accept a pasted redirect URL.")
  end

  @doc """
  Signs an instance out from one of its own thread sessions (`/logout`): its other
  sessions stop, `session` stays for its caller to close.
  """
  def logout_from(instance, session), do: call(instance, {:logout, session})

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
      not HalC2.Acp.agent?(instance) and not codex?(instance) ->
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
    server = self()
    Task.start(fn -> send(server, {:methods, auth_module(instance).methods(instance)}) end)

    {:ok,
     %{
       instance: instance,
       auth: idle(instance, nil),
       methods: nil,
       watchers: %{},
       flow: nil
     }}
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
      "credentialOwner" => if(codex?(instance), do: "hal-c2", else: "provider")
    }
  end

  @impl true
  def handle_call({:subscribe, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
    {:reply, {:ok, state.auth}, %{state | watchers: watchers}}
  end

  def handle_call(:signing_in?, _from, state), do: {:reply, state.flow != nil, state}

  def handle_call({:start, _method}, _from, %{flow: %{}} = state),
    do: {:reply, {:ok, state.auth}, state}

  def handle_call({:start, method_id}, _from, state) do
    methods = state.methods || []

    method_id =
      cond do
        antigravity?(state.instance) -> HalC2.Acp.Antigravity.config(state.instance)["authMethod"]
        codex?(state.instance) -> method_id || "chatgpt"
        true -> method_id || default_method(state.instance, methods)
      end

    refusal = if not codex?(state.instance), do: HalC2.Acp.sign_in_refusal(state.instance)

    if refusal do
      {:reply, error(state.instance, "start", refusal), state}
    else
      start_flow(method_id, methods, state)
    end
  end

  def handle_call({:respond, flow_id, interaction_id, response}, _from, state) do
    interaction = state.auth["interaction"]

    case state.flow do
      %{id: ^flow_id, responder: responder}
      when is_pid(responder) and is_map(interaction) and is_map(response) ->
        if interaction["id"] == interaction_id and interaction["type"] == response["type"] do
          send(responder, {:auth_response, response})
          {:reply, {:ok, state.auth}, state}
        else
          {:reply,
           error(state.instance, "respond", "This sign-in interaction is no longer available."),
           state}
        end

      _ ->
        {:reply, error(state.instance, "respond", "This sign-in is no longer active."), state}
    end
  end

  def handle_call({:cancel, flow_id}, _from, %{flow: %{id: flow_id}} = state) do
    state = end_flow(state, "cancelled", text(state.instance, :cancelled))
    {:reply, {:ok, state.auth}, state}
  end

  def handle_call({:cancel, _}, _from, state),
    do: {:reply, error(state.instance, "cancel", "This sign-in is no longer active."), state}

  def handle_call({:complete, flow_id, url}, _from, state) do
    interaction = state.auth["interaction"]

    result =
      case state.flow do
        %{id: ^flow_id} when not is_map(interaction) ->
          {:error, text(state.instance, :no_link)}

        %{id: ^flow_id, callback: true} ->
          {:error, text(state.instance, :sent)}

        %{id: ^flow_id} ->
          # `complete/1` lets only these two through.
          auth =
            if codex?(state.instance),
              do: HalC2.Codex.ChatGpt,
              else: HalC2.Acp.Antigravity.Auth

          with {:ok, pending} <- authorization(auth, interaction["url"]),
               {:ok, uri} <- auth.validate_callback(pending, to_string(url || "")),
               :ok <- auth.forward_callback(uri),
               do: :ok

        _ ->
          {:error, "This sign-in is no longer active in this client."}
      end

    case result do
      :ok ->
        state =
          publish(put_in(state.flow[:callback], true), %{
            "phase" => "verifying",
            "interaction" => nil,
            "authorizationUrl" => nil,
            "message" => text(state.instance, :finishing)
          })

        {:reply, {:ok, state.auth}, state}

      {:error, detail} ->
        {:reply, error(state.instance, "complete", detail), state}
    end
  end

  def handle_call(:logout, from, state) do
    cond do
      antigravity?(state.instance) -> handle_call({:logout, nil}, from, state)
      codex?(state.instance) -> codex_logout(state)
      true -> generic_logout(state)
    end
  end

  def handle_call({:logout, session}, _from, state) do
    state =
      if state.flow,
        do: end_flow(state, "idle", "Google sign-in was cancelled by sign-out."),
        else: state

    case HalC2.Acp.Antigravity.Auth.logout(state.instance, session) do
      :ok ->
        state =
          %{
            state
            | auth: Map.merge(idle(state.instance, "Signed out of Google."), methods(state))
          }

        broadcast(state)
        {:reply, {:ok, state.auth}, state}

      {:error, detail} ->
        state = finish(state, "failed", "Antigravity sign-out failed. Try again.")
        {:reply, error(state.instance, "logout", detail), state}
    end
  end

  defp codex_logout(state) do
    state = if state.flow, do: end_flow(state, "idle", nil), else: state
    :ok = HalC2.Codex.ChatGpt.logout(state.instance)
    HalC2.Settings.notify_providers()
    message = "Signed out of ChatGPT."
    state = %{state | auth: Map.merge(idle(state.instance, message), methods(state))}
    broadcast(state)
    {:reply, {:ok, state.auth}, state}
  end

  defp generic_logout(state) do
    state = if state.flow, do: end_flow(state, "idle", nil), else: state

    case HalC2.Acp.Sessions.logout(%{"instanceId" => state.instance}) do
      {:ok, _} ->
        state = %{state | auth: Map.merge(idle(state.instance, "Signed out."), methods(state))}
        broadcast(state)
        {:reply, {:ok, state.auth}, state}

      {:error, detail} ->
        {:reply,
         error(state.instance, "logout", detail["message"] || "Could not sign out. Try again."),
         state}
    end
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

  def handle_info({:methods, {:error, message}}, state) do
    state = %{state | methods: []}
    {:noreply, publish(state, %{"methods" => [], "message" => message})}
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
          succeeded(state, text(state.instance, :succeeded))

        {:shutdown, {:succeeded, message}} ->
          succeeded(state, message)

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

  defp start_flow(method_id, methods, state) do
    if method_id != nil and (methods == [] or Enum.any?(methods, &(&1["id"] == method_id))) do
      flow_id = HalC2.Environment.uuid4()
      expires = System.system_time(:millisecond) + @timeout_ms
      server = self()
      instance = state.instance

      worker =
        spawn_link(fn -> auth_module(instance).login(instance, method_id, server, flow_id) end)

      Process.send_after(self(), {:expire, flow_id}, @timeout_ms)

      state =
        publish(
          %{state | flow: %{id: flow_id, worker: worker, responder: nil}},
          %{
            "phase" => "starting",
            "flowId" => flow_id,
            "expiresAt" => iso(expires),
            "message" => text(state.instance, :starting),
            "interaction" => nil,
            "authorizationUrl" => nil
          }
        )

      {:reply, {:ok, state.auth}, state}
    else
      {:reply,
       error(state.instance, "start", "The provider did not advertise this sign-in method."),
       state}
    end
  end

  defp succeeded(state, message) do
    # The agent reads its new credentials when it is next started; a Codex
    # instance's sessions start Codex in its home each time.
    if not codex?(state.instance), do: HalC2.Acp.forget(state.instance)
    HalC2.Settings.notify_providers()
    # The account the sign-in connected is the methods' to name now.
    state = maybe_reload_methods(state)
    finish(state, "succeeded", message)
  end

  defp maybe_reload_methods(state) do
    if codex?(state.instance) do
      {:ok, methods} = HalC2.Codex.ChatGpt.methods(state.instance)
      %{state | methods: methods, auth: Map.put(state.auth, "methods", methods)}
    else
      state
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

  defp maybe_stop(%{watchers: watchers, flow: nil} = state) when map_size(watchers) == 0,
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

  defp codex?(instance), do: HalC2.Codex.ChatGpt.managed?(instance)

  defp auth_module(instance) do
    cond do
      antigravity?(instance) -> HalC2.Acp.Antigravity.Auth
      codex?(instance) -> HalC2.Codex.ChatGpt
      true -> HalC2.Acp.Auth
    end
  end

  defp authorization(auth, url) when is_binary(url) do
    case auth.authorization(url) do
      {:ok, pending} -> {:ok, pending}
      :error -> {:error, "This sign-in is no longer active in this client."}
    end
  end

  defp authorization(_auth, _url),
    do: {:error, "This sign-in is no longer active in this client."}

  # What a flow says at each step: Antigravity names Google, a Codex ChatGPT
  # sign-in OpenAI, others are generic.
  defp text(instance, key) do
    cond do
      antigravity?(instance) -> antigravity_text(instance, key)
      codex?(instance) -> codex_text(key)
      true -> generic_text(key)
    end
  end

  defp codex_text(key) do
    case key do
      :starting ->
        "Starting ChatGPT sign-in."

      :waiting ->
        "Open the ChatGPT sign-in link. If you are remote, paste the callback address here."

      :verifying ->
        "Checking the ChatGPT account."

      :succeeded ->
        "Signed in with ChatGPT."

      :expired ->
        "ChatGPT sign-in expired. Start sign-in again."

      :cancelled ->
        "ChatGPT sign-in was cancelled."

      :no_link ->
        "Wait for the ChatGPT sign-in link before you paste a callback address."

      :sent ->
        "The callback address was already sent. Wait for Codex to finish."

      :finishing ->
        "Waiting for Codex to finish the ChatGPT sign-in."
    end
  end

  defp generic_text(key) do
    case key do
      :starting -> "Starting sign-in."
      :waiting -> "Complete sign-in to continue."
      :verifying -> "Checking provider sign-in."
      :succeeded -> "Sign-in complete."
      :expired -> "Sign-in expired. Start again."
      :cancelled -> "Sign-in cancelled."
    end
  end

  defp antigravity_text(instance, key) do
    browser? =
      HalC2.Acp.Antigravity.browser?(HalC2.Acp.Antigravity.config(instance)["authMethod"])

    case key do
      :starting when browser? -> "Starting Google sign-in."
      :starting -> "Checking credentials."
      :waiting -> "Open the Google sign-in link. If you are remote, paste the redirect URL here."
      :verifying -> "Checking Antigravity access and models."
      :succeeded when browser? -> "Signed in with Google."
      :succeeded -> "Connected to Antigravity."
      :expired -> "Google sign-in expired. Start sign-in again."
      :cancelled -> "Google sign-in was cancelled."
      :no_link -> "Wait for the Google sign-in link before you send a redirect URL."
      :sent -> "The sign-in response was already sent. Wait for Google to finish."
      :finishing -> "Waiting for Google to finish sign-in."
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
