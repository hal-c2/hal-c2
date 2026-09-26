defmodule HalC2.Steps.Settings.UsageLimitSources do
  @moduledoc """
  Settings → Usage providers: CLIProxyAPI hubs added as usage limit sources
  (`usageLimitSources` in settings, `HalC2.UsageLimitSources`). A local fake hub serves
  the management API the node reads; hub URLs in the scenarios stand for it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World
  alias HalC2.UsageLimitSources

  @marker "••••••"
  @key "hub-key"

  # A CLIProxyAPI hub: its management API, and the upstream answers its `api-call`
  # relays. `state` is an Agent holding the redeem requests it received, the
  # redemptions it counted, and whether to drop redeem requests' connections.
  defmodule Hub do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    def init(state), do: state

    def call(conn, state) do
      if get_req_header(conn, "authorization") != ["Bearer hub-key"] do
        send_resp(conn, 401, "")
      else
        {:ok, body, conn} = read_body(conn)
        request = if body == "", do: nil, else: JSON.decode!(body)
        route(conn, conn.request_path, request, state)
      end
    end

    defp route(conn, "/v0/management/auth-files", _, _) do
      json(conn, %{
        "files" => [
          %{
            "id" => "codex-a",
            "auth_index" => "0",
            "provider" => "codex",
            "email" => "a@example.com",
            "id_token" => %{"chatgpt_account_id" => "acct-1", "chatgpt_plan_type" => "plus"}
          },
          %{
            "id" => "claude-b",
            "auth_index" => "1",
            "provider" => "claude",
            "email" => "b@example.com"
          }
        ]
      })
    end

    defp route(conn, "/v0/management/reset-quota", _, _), do: json(conn, %{})

    defp route(conn, "/v0/management/api-call", %{"url" => url} = request, state) do
      data = if is_binary(request["data"]), do: JSON.decode!(request["data"])
      json(conn, %{"status_code" => 200, "body" => JSON.encode!(upstream(url, data, state))})
    end

    # Redemption is keyed by the request id, as the provider does: a repeated id is
    # the same redemption and gets the same answer.
    defp upstream(
           "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume",
           data,
           state
         ) do
      %{"redeem_request_id" => id, "credit_id" => credit} = data

      drop? =
        Agent.get_and_update(state, fn s ->
          {s.drop, %{s | requests: s.requests ++ [id], redeemed: Map.put(s.redeemed, id, credit)}}
        end)

      # The hub redeemed the credit, but the answer never reaches the node.
      if drop?, do: Process.exit(self(), :kill)
      %{"code" => "reset"}
    end

    defp upstream("https://chatgpt.com/backend-api/wham/usage", _, _) do
      %{
        "plan_type" => "pro",
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 20,
            "reset_at" => 1_790_000_000,
            "limit_window_seconds" => 18_000
          },
          "secondary_window" => %{
            "used_percent" => 5,
            "reset_at" => 1_790_500_000,
            "limit_window_seconds" => 604_800
          }
        }
      }
    end

    defp upstream("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", _, state) do
      credits =
        if Agent.get(state, &(&1.redeemed == %{})),
          do: [
            %{
              "id" => "c1",
              "status" => "available",
              "reset_type" => "codex_rate_limits",
              "expires_at" => "2099-01-01T00:00:00Z"
            }
          ],
          else: []

      %{"credits" => credits}
    end

    defp upstream("https://api.anthropic.com/api/oauth/usage", _, _) do
      %{
        "five_hour" => %{"utilization" => 40, "resets_at" => "2026-09-24T15:00:00Z"},
        "seven_day" => %{"utilization" => 60, "resets_at" => nil}
      }
    end

    defp json(conn, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
    end
  end

  # An admin is a client on the node's own token: it may read auth access.
  step "a node the user administers", context do
    Node.ensure(HalC2.Settings)
    Node.ensure(UsageLimitSources)
    client = context |> World.client() |> Node.sub(90, %{"type" => "authAccess"})
    {_, client} = Node.await(client, &(&1["t"] == "authAccess" and &1["id"] == 90))
    World.put_client(context, client)
  end

  # "https://hub.example" is the fake hub on a local port.
  step "the user added a hub at {string} with its management key", %{args: [_url]} = context do
    add_hub(context)
  end

  step "the user added a hub with its management key", context do
    add_hub(context)
  end

  step "a hub that is unreachable", context do
    # Nothing listens on port 1.
    add_source(context, "http://127.0.0.1:1")
  end

  step "the node reads its usage sources", context do
    :ok = UsageLimitSources.refresh()
    client = Node.sub(World.client(context), 91, config_shape())

    {%{"sources" => sources}, client} =
      Node.await(client, &(&1["t"] == "config.usageLimitSources" and &1["id"] == 91))

    context |> World.put_client(client) |> Map.put(:sources, sources)
  end

  step "the hub's Codex and Claude accounts appear in limits", context do
    assert [%{"id" => "hub", "label" => label, "accounts" => accounts} = source] = context.sources
    refute Map.has_key?(source, "error")
    assert label == "127.0.0.1:#{context.hub.port}"

    assert %{"driver" => "codex", "email" => "a@example.com", "usageLimits" => codex} =
             Enum.find(accounts, &(&1["id"] == "codex-a"))

    assert [_ | _] = codex["windows"]

    assert %{"driver" => "claudeAgent", "usageLimits" => claude} =
             Enum.find(accounts, &(&1["id"] == "claude-b"))

    assert [_ | _] = claude["windows"]
    context
  end

  step "a client reads the settings", context do
    {{:ok, %{"settings" => settings, "version" => version}}, context} =
      World.call(context, "hal-c2.readSettings")

    Map.merge(context, %{settings: settings, version: version})
  end

  step "the settings hold only a marker in place of the key", context do
    assert get_in(context.settings, ["usageLimitSources", "hub", "managementKey"]) == @marker
    refute inspect(context.settings) =~ @key
    context
  end

  step "saving the settings back with the marker keeps the key", context do
    settings = put_in(context.settings, ["usageLimitSources", "hub", "label"], "Team hub")

    {{:ok, _}, context} =
      World.call(context, "hal-c2.writeSettings", %{
        "settings" => settings,
        "version" => context.version
      })

    assert get_in(HalC2.Settings.settings(), ["usageLimitSources", "hub", "label"]) == "Team hub"
    assert UsageLimitSources.key("hub") == @key
    context
  end

  step "the hub is still listed with the error", context do
    assert [%{"id" => "hub", "accounts" => [], "error" => "The hub could not list accounts."}] =
             context.sources

    context
  end

  step "a hub account with a banked reset credit", context do
    context = add_hub(context)
    :ok = UsageLimitSources.refresh()
    [%{"accounts" => accounts}] = UsageLimitSources.current()

    assert %{
             "usageLimits" => %{
               "resetCredits" => %{"availableCount" => 1, "nextCreditId" => credit}
             }
           } =
             Enum.find(accounts, &(&1["id"] == "codex-a"))

    Map.put(context, :credit, credit)
  end

  # The HTTP client itself resends a request whose kept-alive connection closed
  # unanswered, so the hub drops every attempt until the user tries again.
  step "the redeem request is sent again after a dropped connection", context do
    Agent.update(context.hub.state, &%{&1 | drop: true})
    input = %{"sourceId" => "hub", "accountId" => "codex-a", "creditId" => context.credit}
    {first, context} = World.call(context, "provider.consumeResetCredit", input)
    assert {:error, _, _} = first
    Agent.update(context.hub.state, &%{&1 | drop: false})
    {second, context} = World.call(context, "provider.consumeResetCredit", input)
    Map.put(context, :reply, second)
  end

  step "the hub counts one redemption", context do
    assert {:ok, %{"outcome" => "reset"}} = context.reply
    %{requests: requests, redeemed: redeemed} = Agent.get(context.hub.state, & &1)
    assert [id, _ | _] = requests
    assert Enum.uniq(requests) == [id]
    assert redeemed == %{id => context.credit}
    context
  end

  defp add_hub(context) do
    state =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{requests: [], redeemed: %{}, drop: false} end}
      )

    server =
      ExUnit.Callbacks.start_supervised!({Bandit, plug: {Hub, state}, port: 0, ip: :loopback})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    context
    |> Map.put(:hub, %{state: state, port: port})
    |> add_source("http://127.0.0.1:#{port}")
  end

  defp add_source(context, url) do
    World.update_settings(context, %{
      "usageLimitSources" => %{
        "hub" => %{"kind" => "cliproxy", "url" => url, "managementKey" => @key}
      }
    })
  end

  defp config_shape, do: %{"type" => "config", "node" => Atom.to_string(node())}
end
