defmodule HalC2.Steps.Providers.UsageLimits.Hub do
  @moduledoc false
  # A CLIProxyAPI hub: its management API, and the upstream answers to its `api-call`
  # relays. It tells the scenario (`test`) about every request, and keeps whether a
  # credit was redeemed and whether it answers with a usage payload the node chokes on
  # in `state`.
  @behaviour Plug

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test, state: state}) do
    if get_req_header(conn, "authorization") != ["Bearer hub-key"] do
      send_resp(conn, 401, "")
    else
      {:ok, body, conn} = read_body(conn)
      request = if body == "", do: nil, else: JSON.decode!(body)
      send(test, {:hub, conn.request_path, request})
      route(conn, conn.request_path, request, Agent.get(state, & &1), state)
    end
  end

  defp route(conn, "/v0/management/auth-files", _, _, _) do
    json(conn, %{
      "files" => [
        %{
          "id" => "codex-a",
          "auth_index" => "0",
          "provider" => "codex",
          "email" => "a@example.com",
          "id_token" => %{"chatgpt_account_id" => "acct-1", "chatgpt_plan_type" => "pro"}
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

  defp route(conn, "/v0/management/reset-quota", _, _, _), do: json(conn, %{})

  defp route(conn, "/v0/management/api-call", %{"url" => url}, hub, state),
    do: json(conn, %{"status_code" => 200, "body" => JSON.encode!(upstream(url, hub, state))})

  defp upstream("https://chatgpt.com/backend-api/wham/usage", %{crash: true}, _),
    do: %{"plan_type" => "pro", "rate_limit" => "garbled"}

  defp upstream("https://chatgpt.com/backend-api/wham/usage", hub, _) do
    %{
      "plan_type" => "pro",
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => if(hub[:redeemed], do: 0, else: 20),
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

  defp upstream("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", hub, _) do
    credit =
      &%{"id" => &1, "status" => &2, "reset_type" => "codex_rate_limits", "expires_at" => &3}

    %{
      "credits" => [
        credit.(
          "c1",
          if(hub[:redeemed], do: "redeemed", else: "available"),
          "2099-01-01T00:00:00Z"
        ),
        credit.("c2", "available", "2099-01-02T00:00:00Z")
      ]
    }
  end

  defp upstream("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume", _, state) do
    Agent.update(state, &Map.put(&1, :redeemed, true))
    %{"code" => "reset"}
  end

  defp upstream("https://api.anthropic.com/api/oauth/usage", _, _) do
    %{
      "five_hour" => %{"utilization" => 40, "resets_at" => "2026-09-24T15:00:00Z"},
      "seven_day" => %{"utilization" => 60, "resets_at" => nil}
    }
  end

  defp json(conn, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
end

defmodule HalC2.Steps.Providers.UsageLimits.Vendor do
  @moduledoc false
  # The usage endpoints of Grok, Cursor and OpenCode Go, answering the sign-in each
  # scenario stores ("vendor-token").
  @behaviour Plug

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_req_header(conn, "authorization") != ["Bearer vendor-token"],
      do: send_resp(conn, 401, ""),
      else: route(conn, conn.method, conn.request_path)
  end

  defp route(conn, "GET", "/grok/billing") do
    json(conn, %{
      "config" => %{
        "creditUsagePercent" => 35,
        "currentPeriod" => %{
          "type" => "USAGE_PERIOD_TYPE_MONTHLY",
          "end" => "2026-10-01T00:00:00Z"
        }
      }
    })
  end

  defp route(conn, "POST", "/aiserver.v1.DashboardService/GetCurrentPeriodUsage") do
    if get_req_header(conn, "connect-protocol-version") == ["1"],
      do:
        json(conn, %{
          "billingCycleEnd" => "1790000000000",
          "planUsage" => %{
            "totalPercentUsed" => 50,
            "autoPercentUsed" => 30,
            "apiPercentUsed" => 20
          }
        }),
      else: send_resp(conn, 400, "")
  end

  defp route(conn, "GET", "/opencode/usage") do
    window = &%{"percent" => &1, "resetsAt" => &2}

    json(conn, %{
      "usage" => %{
        "rolling" => window.(10, "2026-09-26T05:00:00Z"),
        "weekly" => window.(25, "2026-10-01T00:00:00Z"),
        "monthly" => window.(40, "2026-10-15T00:00:00Z")
      }
    })
  end

  defp route(conn, _, _), do: send_resp(conn, 404, "")

  defp json(conn, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
  end
end

defmodule HalC2.Steps.Providers.UsageLimits do
  @moduledoc """
  Steps for features/providers/usage-limits.feature: Codex and Claude subscription
  windows read by `HalC2.ProviderUsageLimits` from the fake CLIs, and CLIProxyAPI hubs
  read by `HalC2.UsageLimitSources` from a fake hub served in the scenario.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Providers.UsageLimits.{Hub, Vendor}
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @marker "••••••"

  # --- setup -----------------------------------------------------------------------

  step "a connected environment with Codex and Claude signed in with subscriptions", context do
    context = World.fake_providers(context)
    System.put_env("FAKE_CODEX_CONSUME_LOG", consumed(context))
    Node.ensure(HalC2.BackgroundPolicy)
    # Connected before any thread's stream messages reach this process.
    World.put_client(context, World.client(context))
  end

  # The usage-limit service starts lazily, so "the node starts" can come first.
  step "Codex and Claude report their session and weekly windows", context do
    context = limits(context)
    # One read each, the boot probe: nobody asked for it.
    assert checks(context) == %{codex: 1, claude: 1}

    Enum.reduce(["codex", "claudeAgent"], context, fn instance, context ->
      {limits, context} = usage_limits(context, instance)
      kinds = for w <- limits["windows"], do: w["kind"]
      assert "session" in kinds and "weekly" in kinds, "#{instance}: #{inspect(kinds)}"
      context
    end)
  end

  # --- turns -----------------------------------------------------------------------

  step "Codex reports a new rate-limit reading", context do
    context = limits(context)
    {limits, context} = usage_limits(context, "codex")
    assert %{"usedPercent" => 42} = window(limits, "primary")
    # The user's follow-up steers the running turn, and Codex answers it with a reading.
    context = World.post_message(context, "Codex work", "rate limit", %{"dispatchMode" => nil})
    World.await_runs(context, "Codex work", ["completed"])
    # The runtime passed the update on before the turn completed.
    :sys.get_state(HalC2.ProviderUsageLimits)
    context
  end

  step "the session window shows the new reading without a new check", context do
    {limits, context} = usage_limits(context, "codex")
    assert %{"usedPercent" => 77} = window(limits, "primary")
    assert checks(context).codex == 1
    context
  end

  # --- probes ----------------------------------------------------------------------

  step "Codex reported its windows a minute ago", context do
    context = limits(context)
    {last, context} = usage_limits(context, "codex")
    assert [_, _] = last["windows"]
    Map.put(context, :last_limits, last)
  end

  step "the next check of Codex fails", context do
    ran = Path.join(context.fakes.dir, "failed-check")

    World.put_app_env(:codex_command, [
      script(context, "codex-fails", "echo x >> #{ran}; exit 1")
    ])

    {_, context} = World.call!(context, "server.refreshProviders", %{"instanceId" => "codex"})
    assert File.exists?(ran)
    context
  end

  step "the windows from a minute ago are still shown", context do
    {limits, context} = usage_limits(context, "codex")
    assert limits == context.last_limits
    context
  end

  step "Codex is signed in with an API key", context do
    System.put_env("FAKE_CODEX_ACCOUNT", "apiKey")
    context
  end

  step "the node checks Codex's limits", context do
    context = limits(context)
    {_, context} = World.call!(context, "server.refreshProviders", %{"instanceId" => "codex"})
    context
  end

  step "Codex's limits are reported as not supported for this account", context do
    {limits, context} = usage_limits(context, "codex")
    assert %{"windows" => [], "unavailable" => %{"reason" => "unsupported"}} = limits

    context
  end

  step "the user refreshes the providers", context do
    context = context |> limits() |> Map.put(:checks_before, checks(context))
    drain_hub()
    {_, context} = World.call!(context, "server.refreshProviders", %{})
    context
  end

  step "Codex, Claude and the hub are checked again", context do
    assert checks(context) == %{
             codex: context.checks_before.codex + 1,
             claude: context.checks_before.claude + 1
           }

    assert_received {:hub, "/v0/management/auth-files", _}
    assert [%{"id" => "hub", "accounts" => [_, _]}] = HalC2.UsageLimitSources.current()
    context
  end

  # --- background checks -----------------------------------------------------------

  step "the background activity profile checks provider status every five minutes", context do
    World.merge_settings(%{"backgroundActivity" => %{"profile" => "balanced"}})
    assert HalC2.ProviderUsageLimits.interval() == :timer.minutes(5)
    context
  end

  step "a client in front shows provider status", context do
    context |> limits() |> report_activity(true)
  end

  step "no client in front shows provider status", context do
    context |> limits() |> report_activity(false)
  end

  step "the background check interval passes", context do
    World.run_periodic_checks()
    context
  end

  step "Codex and Claude are checked again", context do
    %{codex: codex, claude: claude} = context.checks_before
    assert checks(context) == %{codex: codex + 1, claude: claude + 1}
    context
  end

  step "Codex and Claude are not checked", context do
    assert checks(context) == context.checks_before
    context
  end

  # --- Codex reset credits ---------------------------------------------------------

  step "Codex has a banked reset credit", context do
    context = limits(context)
    {last, context} = usage_limits(context, "codex")
    assert %{"availableCount" => 2} = last["resetCredits"]
    Map.put(context, :last_limits, last)
  end

  step "the user uses the reset credit", context do
    consume(context, %{"instanceId" => "codex"})
  end

  step "Codex's limits are checked again and show the reset", context do
    assert {:ok, %{"outcome" => "reset"}} = context.reply
    {now, context} = usage_limits(context, "codex")
    assert now["checkedAt"] != context.last_limits["checkedAt"]
    assert %{"usedPercent" => 0} = window(now, "primary")
    assert %{"availableCount" => 1} = now["resetCredits"]
    context
  end

  step "the user uses the reset credit and the following check fails", context do
    # The redemption's app-server works; every later one (the check) fails to start.
    once = Path.join(context.fakes.dir, "codex-ran")
    fake = Path.expand("../../support/fake_codex.py", __DIR__)

    codex =
      script(context, "codex-once", """
      if [ -e #{once} ]; then exit 1; fi
      touch #{once}
      exec python3 -u #{fake} "$@"
      """)

    World.put_app_env(:codex_command, [codex])
    consume(context, %{"instanceId" => "codex"})
  end

  # Codex failing the redemption stands in for a timeout: the node keeps the attempt's
  # key after either.
  step "a reset credit redemption timed out", context do
    context = limits(context)
    flag = Path.join(context.fakes.dir, "consume-fails")
    File.write!(flag, "")
    System.put_env("FAKE_CODEX_CONSUME_FAIL", flag)
    context = consume(context, %{"instanceId" => "codex"})
    assert {:error, "Codex could not redeem the reset credit.", _} = context.reply
    context
  end

  step "the user uses the reset credit again", context do
    context = consume(context, %{"instanceId" => "codex"})
    assert {:ok, %{"outcome" => "reset"}} = context.reply
    context
  end

  step "Codex receives the same redemption rather than a second one", context do
    assert [first, retry] = context |> consumed() |> File.read!() |> String.split()
    assert first == retry
    context
  end

  step ~r/^the user uses a reset credit on (?<target>Claude|a provider that is not set up|a hub that is disabled|a hub without naming a credit)$/,
       %{args: [target]} = context do
    {input, context} =
      case target do
        "Claude" ->
          {%{"instanceId" => "claudeAgent"}, context}

        "a provider that is not set up" ->
          {%{"instanceId" => "codex_personal"}, context}

        "a hub that is disabled" ->
          context = add_hub(context, %{"enabled" => false})
          assert HalC2.UsageLimitSources.key("hub") == "hub-key"
          {%{"sourceId" => "hub", "accountId" => "codex-a", "creditId" => "c1"}, context}

        "a hub without naming a credit" ->
          {%{"sourceId" => "hub", "accountId" => "codex-a"}, context}
      end

    consume(context, input)
  end

  # --- hubs --------------------------------------------------------------------------

  step "the user adds a hub with its URL and management key", context do
    context |> watch_config() |> add_hub()
  end

  step "the hub's accounts are reported with their limits", context do
    {frame, client} =
      Node.await(
        World.client(context),
        &(&1["t"] == "config.usageLimitSources" and
            match?([%{"accounts" => [_ | _]}], &1["sources"])),
        10_000
      )

    context = World.put_client(context, client)
    assert [%{"id" => "hub", "kind" => "cliproxy", "accounts" => accounts}] = frame["sources"]

    assert %{"driver" => "codex", "email" => "a@example.com", "usageLimits" => codex} =
             Enum.find(accounts, &(&1["id"] == "codex-a"))

    assert [%{"kind" => "session", "usedPercent" => 20}, %{"kind" => "weekly"}] = codex["windows"]
    assert %{"availableCount" => 2, "nextCreditId" => "c1"} = codex["resetCredits"]

    assert %{
             "driver" => "claudeAgent",
             "usageLimits" => %{"windows" => [%{"usedPercent" => 40} | _]}
           } =
             Enum.find(accounts, &(&1["id"] == "claude-b"))

    context
  end

  step "the user adds a hub with a management key", context do
    add_hub(context)
  end

  step "the settings show the key only as hidden", context do
    {%{"settings" => settings}, context} = World.call!(context, "hal-c2.readSettings")
    assert %{"hub" => %{"managementKey" => @marker}} = settings["usageLimitSources"]
    refute File.read!(Path.join(context.node.home, "settings.json")) =~ "hub-key"
    context
  end

  step "the key is kept in the environment's secret store", context do
    assert HalC2.UsageLimitSources.key("hub") == "hub-key"
    assert File.exists?(key_path(context))
    context
  end

  step "a hub with a saved management key", context do
    context = add_hub(context)
    assert [%{"id" => "hub", "accounts" => [_, _]}] = read_hubs()
    context
  end

  step "a hub is connected", context do
    context = context |> limits() |> add_hub()
    assert [%{"id" => "hub", "accounts" => [_, _]}] = read_hubs()
    context
  end

  step "the user renames the hub and saves", context do
    write_sources(context, fn sources ->
      # The client sends back the hidden key as it got it.
      assert %{"managementKey" => @marker} = sources["hub"]
      put_in(sources, ["hub", "label"], "Team hub")
    end)
  end

  step "the hub still reads with its saved key", context do
    assert [%{"label" => "Team hub", "accounts" => [_, _]} = hub] = read_hubs()
    refute Map.has_key?(hub, "error")
    assert HalC2.UsageLimitSources.key("hub") == "hub-key"
    context
  end

  step "the user removes the hub", context do
    write_sources(context, &Map.delete(&1, "hub"))
  end

  step "its accounts are no longer reported", context do
    assert read_hubs() == []
    context
  end

  step "its key is removed from the secret store", context do
    assert HalC2.UsageLimitSources.key("hub") == ""
    refute File.exists?(key_path(context))
    context
  end

  step ~r/^a hub (?<problem>without a management key|whose management request crashes)$/,
       %{args: [problem]} = context do
    case problem do
      "without a management key" -> add_hub(context, %{"managementKey" => ""})
      "whose management request crashes" -> context |> add_hub() |> put_hub(:crash, true)
    end
  end

  step "the node reads the hub", context do
    Map.put(context, :hubs, read_hubs())
  end

  step "the hub is reported with no accounts and the error {string}",
       %{args: [error]} = context do
    assert [%{"id" => "hub", "accounts" => [], "error" => ^error}] = context.hubs
    context
  end

  step "a hub account with a banked Codex reset credit", context do
    context = add_hub(context)
    [%{"accounts" => accounts}] = read_hubs()
    account = Enum.find(accounts, &(&1["id"] == "codex-a"))

    assert %{"availableCount" => 2, "nextCreditId" => credit} =
             account["usageLimits"]["resetCredits"]

    Map.put(context, :hub_credit, %{account: account, credit: credit})
  end

  step "the user uses that reset credit", context do
    drain_hub()
    %{account: account, credit: credit} = context.hub_credit
    consume(context, %{"sourceId" => "hub", "accountId" => account["id"], "creditId" => credit})
  end

  step "the hub redeems it and the account's limits are read again", context do
    assert {:ok, %{"outcome" => "reset"}} = context.reply

    assert_received {:hub, "/v0/management/api-call",
                     %{
                       "method" => "POST",
                       "url" =>
                         "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"
                     }}

    assert_received {:hub, "/v0/management/reset-quota", %{"auth_index" => "0"}}

    [%{"accounts" => accounts}] = HalC2.UsageLimitSources.current()
    account = Enum.find(accounts, &(&1["id"] == "codex-a"))

    assert account["usageLimits"]["checkedAt"] !=
             context.hub_credit.account["usageLimits"]["checkedAt"]

    assert [%{"usedPercent" => 0} | _] = account["usageLimits"]["windows"]

    assert %{"availableCount" => 1, "nextCreditId" => "c2"} =
             account["usageLimits"]["resetCredits"]

    context
  end

  # --- helpers -----------------------------------------------------------------------

  # Starts the node's usage-limit service (if it is not running yet) and waits for its
  # boot probe of Codex and Claude.
  defp limits(context) do
    Node.ensure(HalC2.ProviderUsageLimits)
    :ok = HalC2.ProviderUsageLimits.refresh([])
    context
  end

  # How often each fake CLI was asked for quota.
  defp checks(context) do
    %{
      codex:
        count(context, "codex", &(get_in(&1, ["in", "method"]) == "account/rateLimits/read")),
      claude: count(context, "claude", &(get_in(&1, ["in", "request", "subtype"]) == "get_usage"))
    }
  end

  defp count(context, name, fun), do: context |> World.provider_log(name) |> Enum.count(fun)

  # The provider entry's limits as clients get them.
  defp usage_limits(context, instance) do
    {providers, context} = World.provider_list(context)
    {Enum.find(providers, &(&1["instanceId"] == instance))["usageLimits"], context}
  end

  defp window(limits, id), do: Enum.find(limits["windows"], &(&1["id"] == id))

  # A client's activity lease on provider status, in front or not; the state call
  # makes sure the policy has it.
  defp report_activity(context, front?) do
    HalC2.BackgroundPolicy.report_client_activity(
      "session-#{System.unique_integer([:positive])}",
      self(),
      %{
        "clientId" => "tab-1",
        "clientKind" => "web",
        "visible" => front?,
        "focused" => front?,
        "recentlyInteracted" => false,
        "scopes" => [%{"type" => "provider-status"}],
        "observedAt" => HalC2.Orchestration.Entities.now()
      }
    )

    :sys.get_state(HalC2.BackgroundPolicy)
    assert HalC2.ProviderUsageLimits.wanted?() == front?
    Map.put(context, :checks_before, checks(context))
  end

  defp consume(context, input) do
    {reply, context} = World.call(context, "provider.consumeResetCredit", input)
    Map.put(context, :reply, reply)
  end

  defp consumed(context), do: Path.join(context.fakes.dir, "consumed")

  defp script(context, name, body) do
    path = Path.join(context.fakes.dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  # Serves the fake hub (once per scenario) and adds it as "hub" through the settings
  # a client writes.
  defp add_hub(context, extra \\ %{}) do
    context = serve_hub(context)
    Node.ensure(HalC2.UsageLimitSources)

    source =
      Map.merge(
        %{
          "kind" => "cliproxy",
          "enabled" => true,
          "url" => context.hub.url,
          "managementKey" => "hub-key"
        },
        extra
      )

    write_sources(context, &Map.put(&1, "hub", source))
  end

  defp serve_hub(%{hub: _} = context), do: context

  defp serve_hub(context) do
    state =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({Agent, fn -> %{} end}, id: :fake_hub_state)
      )

    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {Hub, %{test: self(), state: state}}, port: 0, ip: :loopback},
          id: :fake_hub
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Map.put(context, :hub, %{url: "http://127.0.0.1:#{port}", state: state})
  end

  defp put_hub(context, key, value) do
    Agent.update(context.hub.state, &Map.put(&1, key, value))
    context
  end

  defp write_sources(context, fun) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings")

    settings = Map.put(settings, "usageLimitSources", fun.(settings["usageLimitSources"] || %{}))

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{"settings" => settings, "version" => version})

    context
  end

  # Reads every hub now and returns what clients are shown.
  defp read_hubs do
    :ok = HalC2.UsageLimitSources.refresh()
    HalC2.UsageLimitSources.current()
  end

  defp watch_config(context) do
    {_, context} = World.provider_list(context)
    context
  end

  defp key_path(context),
    do:
      Path.join([
        context.node.home,
        "secrets",
        "usage-limit-source-#{Base.url_encode64("hub", padding: false)}.bin"
      ])

  defp drain_hub do
    receive do
      {:hub, _, _} -> drain_hub()
    after
      0 -> :ok
    end
  end

  # --- Grok, Cursor and OpenCode Go ------------------------------------------------

  step ~r/^(?<provider>Cursor|Grok|OpenCode Go) is signed in with a subscription$/,
       %{args: [provider]} = context do
    dir = Path.join(context.node.home, "vendor-auth")

    case provider do
      "Grok" ->
        write_json(Path.join(dir, ".grok/auth.json"), %{
          "https://accounts.x.ai/sign-in" => %{"key" => "vendor-token"}
        })

        vendor_instance(context, "grok", %{"GROK_HOME" => Path.join(dir, ".grok")})

      "Cursor" ->
        write_json(Path.join(dir, "config/cursor/auth.json"), %{"accessToken" => "vendor-token"})

        context
        |> vendor_instance("cursor", %{"XDG_CONFIG_HOME" => Path.join(dir, "config")})
        |> tap(&merge_vendor_config(&1, "cursor", %{"apiEndpoint" => &1.vendor}))

      "OpenCode Go" ->
        write_json(Path.join(dir, "data/opencode/auth.json"), %{
          "opencode-go" => %{"type" => "api", "key" => "vendor-token"}
        })

        vendor_instance(context, "opencode", %{"XDG_DATA_HOME" => Path.join(dir, "data")})
    end
  end

  step "Grok is connected with an explicit API key", context do
    # A grok.com sign-in is stored too: the explicit key decides whose quota it is.
    home = Path.join(context.node.home, "vendor-auth/.grok")

    write_json(Path.join(home, "auth.json"), %{
      "https://accounts.x.ai/sign-in" => %{"key" => "vendor-token"}
    })

    vendor_instance(context, "grok", %{"GROK_HOME" => home, "XAI_API_KEY" => "xai-key"})
  end

  step "OpenCode runs on an external server", context do
    data = Path.join(context.node.home, "vendor-auth/data")

    write_json(Path.join(data, "opencode/auth.json"), %{
      "opencode-go" => %{"type" => "api", "key" => "vendor-token"}
    })

    context = vendor_instance(context, "opencode", %{"XDG_DATA_HOME" => data})
    merge_vendor_config(context, "opencode", %{"serverUrl" => "http://127.0.0.1:4096"})
    context
  end

  step "the node checks limits", context do
    Node.ensure(HalC2.ProviderUsageLimits)

    {_, context} =
      World.call!(context, "server.refreshProviders", %{"instanceId" => context.vendor_instance})

    context
  end

  step ~r/^(?<provider>Cursor|Grok|OpenCode Go) reports its (?<windows>.+)$/,
       %{args: [provider, _windows]} = context do
    {limits, context} = usage_limits(context, context.vendor_instance)
    refute Map.has_key?(limits, "unavailable")

    shown = for w <- limits["windows"], do: {w["id"], w["kind"], w["label"], w["usedPercent"]}

    case provider do
      "Cursor" ->
        assert shown == [
                 {"apiPercentUsed", "monthly", "Monthly · API", 20},
                 {"autoPercentUsed", "monthly", "Monthly · Auto", 30},
                 {"totalPercentUsed", "monthly", "Monthly", 50}
               ]

        assert Enum.all?(limits["windows"], &(&1["resetsAt"] == "2026-09-21T14:13:20.000Z"))

      "Grok" ->
        assert shown == [{"subscription", "monthly", "Monthly", 35}]
        assert window(limits, "subscription")["resetsAt"] == "2026-10-01T00:00:00.000Z"

      "OpenCode Go" ->
        assert shown == [
                 {"go_rolling", "session", "Go · Session", 10},
                 {"go_weekly", "weekly", "Go · Weekly", 25},
                 {"go_monthly", "monthly", "Go · Monthly", 40}
               ]

        assert window(limits, "go_rolling")["windowDurationMins"] == 300
    end

    context
  end

  step "Grok's limits are reported as not supported for this account", context do
    {limits, context} = usage_limits(context, "grok")
    assert %{"windows" => [], "unavailable" => %{"reason" => "unsupported"}} = limits
    context
  end

  step "OpenCode's limits are reported as not available", context do
    {limits, context} = usage_limits(context, "opencode")
    assert %{"windows" => [], "unavailable" => %{"reason" => "unsupported"}} = limits
    context
  end

  # An enabled `providerInstances` entry for a built-in ACP agent, run by the fake
  # agent, with `env` on the instance and the vendor endpoints pointed at the fake.
  defp vendor_instance(context, id, env) do
    context = context |> World.fake_providers() |> serve_vendor()
    commands = Application.get_env(:hal_c2, :acp_commands, %{})
    World.put_app_env(:acp_commands, Map.put(commands, id, [context.fakes.acp]))
    World.put_app_env(:grok_billing_url, context.vendor <> "/grok/billing")
    World.put_app_env(:opencode_go_usage_url, context.vendor <> "/opencode/usage")
    ExUnit.Callbacks.on_exit(fn -> HalC2.Acp.forget(id) end)

    World.merge_settings(%{
      "providerInstances" => %{
        id => %{
          "driver" => id,
          "enabled" => true,
          "environment" => for({name, value} <- env, do: %{"name" => name, "value" => value})
        }
      }
    })

    Map.put(context, :vendor_instance, id)
  end

  defp merge_vendor_config(_context, id, config),
    do: World.merge_settings(%{"providerInstances" => %{id => %{"config" => config}}})

  defp serve_vendor(%{vendor: _} = context), do: context

  defp serve_vendor(context) do
    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({Bandit, plug: Vendor, port: 0, ip: :loopback}, id: :fake_vendor)
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Map.put(context, :vendor, "http://127.0.0.1:#{port}")
  end

  defp write_json(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(value))
  end
end
