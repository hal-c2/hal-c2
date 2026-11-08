defmodule HalC2.ProviderAuthPropTest do
  @moduledoc """
  Who may do what with a provider sign-in (`HalC2.ProviderAuth`), over the clients
  "a" and "b" and the MC itself (`nil`). A flow belongs to whoever started it: only
  they, or the MC, answer or cancel it, and no one else starts another meanwhile;
  an answer or a cancel for a flow that ended or expired is refused. Signing out is
  anyone's and ends the flow and its ownership. After every step each viewer is
  shown the state whole if the flow is theirs or no one's, and otherwise without its
  id, address, interaction or expiry, and as "in progress in another client" while
  it runs.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.ProviderAuth

  @moduletag timeout: :infinity
  @instance "grok"
  @owners ["a", "b", nil]
  @in_progress "Provider setup is already in progress."
  @not_active "This sign-in is no longer active in this client."
  @elsewhere "Sign-in is in progress in another client."

  defmodule Stub do
    @moduledoc false
    # Stands in for `HalC2.Acp.Auth`: one method, a browser interaction, and a
    # sign-out whose result the case sets.
    def methods(_instance), do: {:ok, [%{"id" => "m", "name" => "M", "type" => "agent"}]}

    def login(_instance, _method, server, flow_id) do
      interaction = %{"type" => "browser", "id" => "i", "url" => "https://x.test/#{flow_id}"}
      send(server, {:auth_interaction, flow_id, interaction, self()})
      receive do: ({:auth_response, %{"action" => "accept"}} -> :ok)
    end

    def logout(_instance, _session), do: :persistent_term.get({__MODULE__, :logout})
  end

  property "only a sign-in's owner answers or cancels it, and others never see where it signs in",
    numtests: HalC2.Prop.numtests(40),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()

        try do
          {history, state, result} = run_commands(__MODULE__, cmds)

          if result != :ok,
            do: IO.puts(HalC2.Prop.report(cmds, history, state, result))

          result == :ok
        after
          HalC2.Prop.stop_services()
          Application.delete_env(:hal_c2, :provider_auth_module)
        end
        |> aggregate(command_names(cmds))
      end
    end
  end

  # `owner` is whose the state is (`"_owner"`); `flow` whether one runs.
  def initial_state, do: %{flow: false, owner: nil, phase: "idle"}

  def command(_state) do
    frequency([
      {4, {:call, __MODULE__, :start, [elements(@owners)]}},
      {3, {:call, __MODULE__, :respond, [elements(@owners), elements([:current, :stale])]}},
      {2, {:call, __MODULE__, :cancel, [elements(@owners), elements([:current, :stale])]}},
      {1, {:call, __MODULE__, :expire, []}},
      {1, {:call, __MODULE__, :logout, [elements(@owners), boolean()]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, call), do: expect(state, call) |> elem(1)

  def postcondition(state, call, {result, auth}) do
    {reply, next} = expect(state, call)

    result == reply and auth["phase"] == next.phase and auth["_owner"] == next.owner and
      Enum.all?(@owners, &shown?(auth, next, &1))
  end

  # What the call answers and the model after it.
  defp expect(%{flow: true} = state, {:call, _, :start, [o]}),
    do: if(owns?(state, o), do: {{:ok, "waiting"}, state}, else: {{:error, @in_progress}, state})

  defp expect(_state, {:call, _, :start, [o]}),
    do: {{:ok, "starting"}, %{flow: true, owner: o, phase: "waiting"}}

  defp expect(state, {:call, _, op, [o, which]}) when op in [:respond, :cancel] do
    if state.flow and which == :current and owns?(state, o) do
      phase = if op == :respond, do: "succeeded", else: "cancelled"

      {{:ok, if(op == :respond, do: "waiting", else: "cancelled")},
       %{state | flow: false, phase: phase}}
    else
      {{:error, @not_active}, state}
    end
  end

  defp expect(%{flow: true} = state, {:call, _, :expire, []}),
    do: {:ok, %{state | flow: false, phase: "failed"}}

  defp expect(state, {:call, _, :expire, []}), do: {:ok, state}

  defp expect(_state, {:call, _, :logout, [_o, true]}),
    do: {{:ok, "idle"}, %{flow: false, owner: nil, phase: "idle"}}

  defp expect(_state, {:call, _, :logout, [_o, false]}),
    do: {{:error, "agent said no"}, %{flow: false, owner: nil, phase: "failed"}}

  defp owns?(state, o), do: o == nil or state.owner == o

  # Whole for its owner and the MC, else without where it signs in.
  defp shown?(auth, model, viewer) do
    view = ProviderAuth.view(auth, viewer)
    whole = Map.delete(auth, "_owner")

    if model.owner == nil or viewer == nil or viewer == model.owner do
      view == whole
    else
      message = if model.flow, do: @elsewhere, else: auth["message"]

      view ==
        Map.merge(whole, %{
          "flowId" => nil,
          "authorizationUrl" => nil,
          "interaction" => nil,
          "expiresAt" => nil,
          "message" => message
        })
    end
  end

  # --- commands: each answers `{reply, the state the server now holds}` ------------

  def start(owner) do
    reply =
      case ProviderAuth.start(%{"instanceId" => @instance, "methodId" => "m"}, owner) do
        {:ok, %{"phase" => "starting", "flowId" => flow}} ->
          await(&(&1["flowId"] == flow and &1["phase"] == "waiting"))
          {:ok, "starting"}

        other ->
          short(other)
      end

    {reply, auth()}
  end

  def respond(owner, which) do
    flow = flow_id(which)

    reply =
      ProviderAuth.respond(
        %{
          "instanceId" => @instance,
          "flowId" => flow,
          "interactionId" => "i",
          "response" => %{"type" => "browser", "action" => "accept"}
        },
        owner
      )

    # The worker then exits, and the server says the sign-in finished.
    if match?({:ok, _}, reply), do: await(&(&1["flowId"] == flow and &1["phase"] == "succeeded"))
    {short(reply), auth()}
  end

  def cancel(owner, which) do
    reply = ProviderAuth.cancel(%{"instanceId" => @instance, "flowId" => flow_id(which)}, owner)
    {short(reply), auth()}
  end

  # The flow's five-minute timer fires.
  def expire do
    send(server(), {:expire, flow_id(:current)})
    {:ok, auth()}
  end

  def logout(owner, ok) do
    :persistent_term.put({Stub, :logout}, if(ok, do: :ok, else: {:error, "agent said no"}))
    reply = ProviderAuth.logout(%{"instanceId" => @instance}, owner)
    {short(reply), auth()}
  end

  defp short({:ok, %{"phase" => phase}}), do: {:ok, phase}
  defp short({:error, %{"detail" => detail}}), do: {:error, detail}

  defp flow_id(:stale), do: "stale-flow"

  defp flow_id(:current) do
    case :sys.get_state(server()).flow do
      %{id: id} -> id
      nil -> "no-flow"
    end
  end

  # What the server holds, which must also be what it last told its subscriber.
  defp auth do
    auth = :sys.get_state(server()).auth
    told = drain(nil)
    if told != nil and told != auth, do: raise("told #{inspect(told)}, holds #{inspect(auth)}")
    auth
  end

  defp drain(last) do
    receive do
      {:hal_c2_provider_auth, @instance, auth} -> drain(auth)
    after
      0 -> last
    end
  end

  defp await(fun) do
    receive do
      {:hal_c2_provider_auth, @instance, auth} ->
        if fun.(auth),
          do: send(self(), {:hal_c2_provider_auth, @instance, auth}),
          else: await(fun)
    after
      5_000 -> raise "no sign-in state matched"
    end
  end

  defp server do
    [{pid, _}] = Registry.lookup(HalC2.ProviderAuth.Registry, @instance)
    pid
  end

  defp start_case do
    HalC2.Prop.scratch_home("provider-auth")
    Application.put_env(:hal_c2, :provider_auth_module, Stub)

    HalC2.Prop.start_services([
      HalC2.Settings,
      {Registry, keys: :unique, name: HalC2.Acp.Registry},
      {Registry, keys: :unique, name: HalC2.ProviderAuth.Registry},
      {DynamicSupervisor, name: HalC2.ProviderAuth.Supervisor, strategy: :one_for_one}
    ])

    # The stub's methods may be in before this subscribes, or arrive after.
    {:ok, auth} = ProviderAuth.subscribe(@instance, self())
    unless is_list(auth["methods"]), do: await(&is_list(&1["methods"]))
    drain(nil)
  end
end
