defmodule HalC2.Steps.Providers.UsageLimits.Hub do
  @moduledoc false
  # A CLIProxyAPI hub: its management API, and the upstream answers to its `api-call`
  # relays. It tells the scenario (`test`) about every request, and keeps whether a
  # credit was redeemed and whether it answers with a usage payload the MC chokes on
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

  defp route(conn, "/v0/management/auth-files", _, %{unlisted: true}, _),
    do: send_resp(conn, 500, "")

  # A disabled Codex account, an enabled Claude one and a Gemini one.
  defp route(conn, "/v0/management/auth-files", _, %{files: :mixed}, _) do
    json(conn, %{
      "files" => [
        %{"id" => "codex-a", "auth_index" => "0", "provider" => "codex", "disabled" => true},
        %{"id" => "claude-b", "auth_index" => "1", "provider" => "claude"},
        %{"id" => "gemini-c", "auth_index" => "2", "provider" => "gemini"}
      ]
    })
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

  defp route(conn, "/v0/management/reset-quota", _, %{cooldown_fails: true}, _),
    do: send_resp(conn, 500, "")

  defp route(conn, "/v0/management/reset-quota", _, _, _), do: json(conn, %{})

  defp route(conn, "/v0/management/api-call", %{"url" => url}, hub, state) do
    case upstream(url, hub, state) do
      {status, text} -> json(conn, %{"status_code" => status, "body" => text})
      body -> json(conn, %{"status_code" => 200, "body" => JSON.encode!(body)})
    end
  end

  # What the upstream said when it refused: a secret the MC must never pass on.
  def secret, do: "invalid bearer sk-live-hub-secret-4242"

  defp upstream("https://chatgpt.com/backend-api/wham/usage", %{crash: true}, _),
    do: %{"plan_type" => "pro", "rate_limit" => "garbled"}

  defp upstream("https://chatgpt.com/backend-api/wham/usage", %{secret: true}, _),
    do: {401, JSON.encode!(%{"error" => secret()})}

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

  defp upstream(
         "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
         %{credits_fail: true},
         _
       ),
       do: {503, "upstream unavailable"}

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

  # The hub answers with `consume_code` (default "reset"); only a reset redeems.
  defp upstream(
         "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume",
         hub,
         state
       ) do
    code = hub[:consume_code] || "reset"
    if code == "reset", do: Agent.update(state, &Map.put(&1, :redeemed, true))
    %{"code" => code}
  end

  defp upstream("https://api.anthropic.com/api/oauth/usage", hub, _) do
    scoped =
      if hub[:scoped],
        do: [
          %{
            "kind" => "weekly_scoped",
            "percent" => 70,
            "resets_at" => "2026-09-30T00:00:00Z",
            "scope" => %{"model" => %{"display_name" => "Fable 1"}}
          }
        ],
        else: []

    %{
      "five_hour" => %{"utilization" => 40, "resets_at" => "2026-09-24T15:00:00Z"},
      "seven_day" => %{"utilization" => 60, "resets_at" => nil},
      "limits" => scoped
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
    case get_req_header(conn, "authorization") do
      ["Bearer vendor-token"] -> route(conn, conn.method, conn.request_path)
      # A Grok account with nothing metered yet: xAI leaves the percentage out.
      ["Bearer vendor-unmetered"] -> unmetered(conn, conn.request_path)
      _ -> send_resp(conn, 401, "")
    end
  end

  defp unmetered(conn, "/grok/billing"), do: json(conn, %{"config" => %{}})
  defp unmetered(conn, _), do: send_resp(conn, 404, "")

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

defmodule HalC2.Steps.Providers.UsageLimits.Anthropic do
  @moduledoc false
  # Claude's OAuth usage and reset endpoints for the login the scenario stores
  # ("claude-token", organization "org-1"). One banked reset (grant_1) until it is
  # claimed, which touches `flag` so the fake CLI's next usage read shows the reset.
  # Every request is told to the scenario (`test`).
  @behaviour Plug

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test, flag: flag}) do
    {:ok, body, conn} = read_body(conn)
    request = if body == "", do: nil, else: JSON.decode!(body)
    send(test, {:anthropic, conn.method, conn.request_path, request})

    if get_req_header(conn, "authorization") != ["Bearer claude-token"],
      do: send_resp(conn, 401, ""),
      else: route(conn, conn.method, conn.request_path, flag)
  end

  defp route(conn, "GET", "/api/oauth/usage", flag) do
    claimed? = File.exists?(flag)

    json(conn, %{
      "cedar_ember" => %{
        "eligible" => true,
        "next_grant_id" => if(claimed?, do: nil, else: "grant_1"),
        "grants" => [
          %{
            "id" => "grant_1",
            "resets_left" => if(claimed?, do: 0, else: 1),
            "usable_now" => not claimed?,
            "ends_at" => "2099-01-01T00:00:00Z"
          }
        ]
      }
    })
  end

  defp route(conn, "POST", "/api/organizations/org-1/reset_rate_limits", flag) do
    File.write!(flag, "")
    json(conn, %{"result" => "reset"})
  end

  defp route(conn, _, _, _), do: send_resp(conn, 404, "")

  defp json(conn, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
end

defmodule HalC2.Steps.Providers.UsageLimits do
  @moduledoc """
  Steps for features/providers/usage-limits.feature: Codex and Claude subscription
  windows read by `HalC2.ProviderUsageLimits` from the fake CLIs, and CLIProxyAPI hubs
  read by `HalC2.UsageLimitSources` from a fake hub served in the scenario.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Providers.UsageLimits.{Anthropic, Hub, Vendor}
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @marker "••••••"

  # What the desktop says for each redemption outcome (UsageController.cpp).
  @outcome_words %{
    "reset" => "Reset applied. Your windows have cleared.",
    "nothingToReset" => "Nothing to reset right now.",
    "noCredit" => "No reset credit left.",
    "alreadyRedeemed" => "That credit was already redeemed."
  }

  # --- setup -----------------------------------------------------------------------

  step "a connected environment with Codex and Claude signed in with subscriptions", context do
    context = World.fake_providers(context)
    System.put_env("FAKE_CODEX_CONSUME_LOG", consumed(context))
    Mc.ensure(HalC2.BackgroundPolicy)
    # Connected before any thread's stream messages reach this process.
    World.put_client(context, World.client(context))
  end

  # The usage-limit service starts lazily, so "the MC starts" can come first.
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

  step "the MC checks Codex's limits", context do
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
    consume(context, %{"instanceId" => context[:reset_instance] || "codex"})
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

  step "a second Codex instance has a banked reset credit", context do
    context = limits(context)
    second_codex_instance(context, true)
    :ok = HalC2.ProviderUsageLimits.refresh(["codex-work"])
    {last, context} = usage_limits(context, "codex-work")
    assert %{"availableCount" => 2} = last["resetCredits"]
    context
  end

  step "the user uses the reset credit on the second Codex instance", context do
    consume(context, %{"instanceId" => "codex-work"})
  end

  step "only the second Codex instance's account redeems it and shows the reset", context do
    assert {:ok, %{"outcome" => "reset"}} = context.reply
    assert [_key] = context |> second_consumed() |> File.read!() |> String.split()
    refute File.exists?(consumed(context))

    {work, context} = usage_limits(context, "codex-work")
    assert %{"usedPercent" => 0} = window(work, "primary")
    assert %{"availableCount" => 1} = work["resetCredits"]

    {built_in, context} = usage_limits(context, "codex")
    assert %{"usedPercent" => 42} = window(built_in, "primary")
    assert %{"availableCount" => 2} = built_in["resetCredits"]
    context
  end

  step ~r/^Codex refuses the reset credit because (?<refusal>it was already redeemed|nothing needs resetting|the account has no credit)$/,
       %{args: [refusal]} = context do
    context = limits(context)

    outcome =
      case refusal do
        "it was already redeemed" -> "alreadyRedeemed"
        "nothing needs resetting" -> "nothingToReset"
        "the account has no credit" -> "noCredit"
      end

    World.put_env("FAKE_CODEX_CONSUME_OUTCOME", outcome)
    Map.put(context, :refusal, outcome)
  end

  step "the reset is not reported as applied", context do
    refusal = context.refusal
    assert {:ok, %{"outcome" => ^refusal} = result} = context.reply
    refute Map.has_key?(result, "warning")
    context
  end

  # Codex failing the redemption stands in for a timeout: the MC keeps the attempt's
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

  step ~r/^the user uses a reset credit on (?<target>a provider that is not set up|a Codex instance that is off|a hub that is disabled|a hub without naming a credit)$/,
       %{args: [target]} = context do
    {input, context} =
      case target do
        "a provider that is not set up" ->
          {%{"instanceId" => "codex_personal"}, context}

        "a Codex instance that is off" ->
          context = limits(context)
          second_codex_instance(context, false)
          {%{"instanceId" => "codex-work"}, context}

        "a hub that is disabled" ->
          context = add_hub(context, %{"enabled" => false})
          assert HalC2.UsageLimitSources.key("hub") == "hub-key"
          {%{"sourceId" => "hub", "accountId" => "codex-a", "creditId" => "c1"}, context}

        "a hub without naming a credit" ->
          {%{"sourceId" => "hub", "accountId" => "codex-a"}, context}
      end

    consume(context, input)
  end

  # --- Claude reset credits ---------------------------------------------------------

  step "Claude has a banked reset credit", context do
    context = context |> limits() |> claude_resets()
    :ok = HalC2.ProviderUsageLimits.refresh(["claudeAgent"])
    {last, context} = usage_limits(context, "claudeAgent")
    assert %{"availableCount" => 1, "nextCreditId" => "grant_1"} = last["resetCredits"]

    context
    |> Map.put(:last_limits, last)
    |> Map.put(:reset_instance, "claudeAgent")
  end

  step "Claude's limits are checked again and show the reset", context do
    assert {:ok, %{"outcome" => "reset"}} = context.reply

    assert_received {:anthropic, "POST", "/api/organizations/org-1/reset_rate_limits",
                     %{"program" => "cedar_ember", "grant_id" => "grant_1", "request_id" => _}}

    {now, context} = usage_limits(context, "claudeAgent")
    assert now["checkedAt"] != context.last_limits["checkedAt"]
    assert %{"usedPercent" => 0} = window(now, "five_hour")
    assert %{"availableCount" => 0} = now["resetCredits"]
    context
  end

  step "the user views limits", context do
    {limits, context} = usage_limits(context, "claudeAgent")
    Map.put(context, :viewed, limits)
  end

  step "the limits show 1 reset credit banked for Claude", context do
    assert %{"availableCount" => 1} = context.viewed["resetCredits"]
    assert [_ | _] = context.viewed["windows"]
    context
  end

  step "the MC runs on macOS with Claude signed in", context do
    context = context |> limits() |> claude_resets()
    World.put_app_env(:os_type, {:unix, :darwin})
    :ok = HalC2.ProviderUsageLimits.refresh(["claudeAgent"])
    context
  end

  step "Claude shows no reset credits", context do
    assert [_ | _] = context.viewed["windows"]
    refute Map.has_key?(context.viewed, "resetCredits")
    context
  end

  step "no request for Claude's reset credits is sent", context do
    refute_received {:anthropic, _, _, _}
    context
  end

  # --- hubs --------------------------------------------------------------------------

  step "the user adds a hub with its URL and management key", context do
    context |> watch_config() |> add_hub()
  end

  step "the hub's accounts are reported with their limits", context do
    {frame, client} =
      Mc.await(
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
    refute File.read!(Path.join(context.mc.home, "settings.json")) =~ "hub-key"
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

  step ~r/^a hub (?<problem>without a management key|that cannot list its accounts)$/,
       %{args: [problem]} = context do
    case problem do
      "without a management key" -> add_hub(context, %{"managementKey" => ""})
      "that cannot list its accounts" -> context |> add_hub() |> put_hub(:unlisted, true)
    end
  end

  step "a hub whose Codex account reports usage the MC cannot read", context do
    context |> add_hub() |> put_hub(:crash, true)
  end

  step "the Codex account is reported as not read, beside the hub's other accounts", context do
    assert [%{"error" => nil, "accounts" => accounts}] =
             Enum.map(context.hubs, &Map.put_new(&1, "error", nil))

    assert %{
             "reason" => "probeFailed",
             "message" => "The hub could not read this account's usage."
           } =
             Enum.find(accounts, &(&1["id"] == "codex-a"))["usageLimits"]["unavailable"]

    assert [_ | _] = Enum.find(accounts, &(&1["id"] == "claude-b"))["usageLimits"]["windows"]
    context
  end

  step "the MC reads the hub", context do
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

  step "a hub that lists a disabled Codex account, an enabled Claude account and a Gemini account",
       context do
    context |> serve_hub() |> put_hub(:files, :mixed) |> add_hub()
  end

  step "only the enabled Claude account is reported", context do
    assert [%{"accounts" => accounts}] = context.hubs
    assert Enum.map(accounts, & &1["id"]) == ["claude-b"]
    context
  end

  step "a reset credit cannot be redeemed on the disabled Codex account", context do
    drain_hub()

    context =
      consume(context, %{"sourceId" => "hub", "accountId" => "codex-a", "creditId" => "c1"})

    assert {:error, message, _} = context.reply
    assert message =~ "missing or disabled"
    refute_received {:hub, "/v0/management/api-call", _}
    context
  end

  step "a hub whose Codex account reports its windows but whose credit lookup fails", context do
    context |> serve_hub() |> put_hub(:credits_fail, true) |> add_hub()
  end

  step "the account shows its windows with no reset credits", context do
    limits = hub_account(context, "codex-a")["usageLimits"]
    assert [_ | _] = limits["windows"]
    refute Map.has_key?(limits, "unavailable")
    refute Map.has_key?(limits, "resetCredits")
    context
  end

  step "a hub account whose upstream request fails with a message that holds a secret",
       context do
    context |> serve_hub() |> put_hub(:secret, true) |> add_hub()
  end

  step "the account is reported as not read", context do
    assert %{"windows" => [], "unavailable" => %{"reason" => "probeFailed"}} =
             hub_account(context, "codex-a")["usageLimits"]

    context
  end

  step "the secret text is not in anything sent to clients", context do
    # The config subscription: its providers, then the hubs' own frame.
    id = System.unique_integer([:positive])

    client =
      Mc.sub(World.client(context), id, %{"type" => "config", "mc" => Atom.to_string(node())})

    {config, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == id), 10_000)

    {sources, client} =
      Mc.await(client, &(&1["t"] == "config.usageLimitSources" and &1["id"] == id), 10_000)

    context = World.put_client(context, client)
    assert [%{"accounts" => [_ | _]}] = sources["sources"]

    for shown <- [config, sources, HalC2.UsageLimitSources.current()] do
      refute inspect(shown, limit: :infinity, printable_limit: :infinity) =~ "sk-live-hub-secret"
    end

    context
  end

  step "a hub Claude account that reports a weekly limit scoped to one model", context do
    context |> serve_hub() |> put_hub(:scoped, true) |> add_hub()
  end

  step "the account shows its session and weekly windows and the model's own weekly window",
       context do
    windows = hub_account(context, "claude-b")["usageLimits"]["windows"]
    shown = for w <- windows, do: {w["id"], w["kind"], w["usedPercent"]}
    assert {"five_hour", "session", 40} in shown
    assert {"seven_day", "weekly", 60} in shown
    assert {"seven_day_fable_1", "weekly", 70} in shown
    context
  end

  step ~r/^the hub answers the redemption with (?<answer>success|nothing to reset|no credit|already redeemed)$/,
       %{args: [answer]} = context do
    code =
      case answer do
        "success" -> "reset"
        "nothing to reset" -> "nothing_to_reset"
        "no credit" -> "no_credit"
        "already redeemed" -> "already_redeemed"
      end

    context |> put_hub(:consume_code, code) |> redeem_on_hub()
  end

  step ~r/^the user is told (?<outcome>the reset was applied|there was nothing to reset right now|the account has no reset credit left|the credit was already redeemed)$/,
       %{args: [outcome]} = context do
    expected =
      case outcome do
        "the reset was applied" -> "reset"
        "there was nothing to reset right now" -> "nothingToReset"
        "the account has no reset credit left" -> "noCredit"
        "the credit was already redeemed" -> "alreadyRedeemed"
      end

    assert {:ok, %{"outcome" => ^expected} = result} = context.reply
    refute Map.has_key?(result, "warning")
    context
  end

  step ~r/^the hub's cooldown for that account is (?<cooldown>cleared|left alone)$/,
       %{args: [cooldown]} = context do
    if cooldown == "cleared",
      do: assert_received({:hub, "/v0/management/reset-quota", %{"auth_index" => "0"}}),
      else: refute_received({:hub, "/v0/management/reset-quota", _})

    context
  end

  step "the user uses the reset credit and the hub cannot clear the account's cooldown",
       context do
    context |> put_hub(:cooldown_fails, true) |> redeem_on_hub()
  end

  step "the reset is reported as applied", context do
    assert {:ok, %{"outcome" => "reset"}} = context.reply
    context
  end

  step "the user is warned that routing may resume only after the hub's cooldown expires",
       context do
    assert {:ok, %{"warning" => warning}} = context.reply
    assert warning =~ "Routing may resume after its cooldown expires"
    context
  end

  step "a hub that lists two accounts", context do
    context = add_hub(context)
    [%{"accounts" => accounts}] = read_hubs()
    assert Enum.map(accounts, & &1["id"]) == ["codex-a", "claude-b"]
    context
  end

  step "the user uses a reset credit naming an account the hub does not list", context do
    drain_hub()
    consume(context, %{"sourceId" => "hub", "accountId" => "codex-z", "creditId" => "c1"})
  end

  step "the MC sends nothing to the hub's upstream", context do
    refute_received {:hub, "/v0/management/api-call", _}
    context
  end

  step "the user is told the account is missing or disabled", context do
    assert {:error, message, _} = context.reply
    assert message =~ "missing or disabled"
    context
  end

  # --- enabling and disabling ------------------------------------------------------

  step "Codex and Claude reported their limits", context do
    context = limits(context)
    assert HalC2.ProviderUsageLimits.get("codex") && HalC2.ProviderUsageLimits.get("claudeAgent")
    Map.put(context, :checks_before, checks(context))
  end

  step ~r/^the user turns Claude (?<action>off|back on)$/,
       %{args: [action]} = context do
    World.merge_settings(%{
      "providers" => %{"claudeAgent" => %{"enabled" => action == "back on"}}
    })

    # The settings change is in the service's mailbox before this call.
    :sys.get_state(HalC2.ProviderUsageLimits)
    context
  end

  step "Claude reports no limits and is not checked", context do
    {limits, context} = usage_limits(context, "claudeAgent")
    assert limits == nil
    assert HalC2.ProviderUsageLimits.get("codex")
    :ok = HalC2.ProviderUsageLimits.refresh()
    assert checks(context).claude == context.checks_before.claude
    context
  end

  step "Claude's limits are read again at once", context do
    assert checks(context).claude == context.checks_before.claude + 1
    {limits, context} = usage_limits(context, "claudeAgent")
    assert [_ | _] = limits["windows"]
    context
  end

  # --- /usage-limits ----------------------------------------------------------------

  step "Pi, which reports no limits, is set up too", context do
    World.merge_settings(%{
      "providers" => %{"pi" => %{"enabled" => true, "binaryPath" => context.fakes.acp}}
    })

    context
  end

  step ~r/^a client that (?<answers>answers|does not answer) "\/usage-limits" itself reads the providers$/,
       %{args: [answers]} = context do
    context = limits(context)
    id = System.unique_integer([:positive])
    shape = %{"type" => "config", "mc" => Atom.to_string(node())}
    shape = if answers == "answers", do: Map.put(shape, "usageLimitsCommand", true), else: shape

    {frame, client} =
      World.client(context)
      |> Mc.sub(id, shape)
      |> Mc.await(&(&1["t"] == "config" and &1["id"] == id))

    context
    |> World.put_client(client)
    |> Map.merge(%{config_sub: id, providers: frame["config"]["providers"]})
  end

  step "Codex and Claude offer {string}", %{args: [command]} = context do
    for instance <- ["codex", "claudeAgent"],
        do: assert(offers?(context.providers, instance, command), instance)

    context
  end

  step "Pi does not offer {string}", %{args: [command]} = context do
    assert Enum.any?(context.providers, &(&1["instanceId"] == "pi")), "Pi is not listed"
    refute offers?(context.providers, "pi", command)
    context
  end

  step "no provider offers {string}", %{args: [command]} = context do
    offering = for p <- context.providers, offers?([p], p["instanceId"], command), do: p
    assert offering == []
    context
  end

  step "a hub that cannot be read is added", context do
    context = add_hub(context, %{"managementKey" => ""})
    read_hubs()
    context
  end

  step "Pi offers {string} so the hub's error can be shown", %{args: [command]} = context do
    id = context.config_sub

    {_frame, client} =
      Mc.await(
        World.client(context),
        &(&1["t"] == "config.providers" and &1["id"] == id and
            offers?(&1["providers"], "pi", command))
      )

    World.put_client(context, client)
  end

  defp offers?(providers, instance, "/" <> name) do
    entry = Enum.find(providers, &(&1["instanceId"] == instance))
    Enum.any?((entry || %{})["slashCommands"] || [], &(&1["name"] == name))
  end

  # --- helpers -----------------------------------------------------------------------

  # Starts the MC's usage-limit service (if it is not running yet) and waits for its
  # boot probe of Codex and Claude.
  defp limits(context) do
    Mc.ensure(HalC2.ProviderUsageLimits)
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

  # A redemption's reply, and for an answer the words a client shows for its outcome
  # (`UsageController.cpp`), so "the user is told" reads what the user sees.
  defp consume(context, input) do
    {reply, context} = World.call(context, "provider.consumeResetCredit", input)

    told =
      case reply do
        {:ok, %{"outcome" => outcome} = result} ->
          Enum.reject([@outcome_words[outcome], result["warning"]], &is_nil/1)

        _ ->
          nil
      end

    context |> Map.put(:reply, reply) |> Map.put(:told, told)
  end

  # Redeems the hub's banked Codex credit (`a hub account with a banked Codex reset credit`).
  defp redeem_on_hub(context) do
    drain_hub()
    %{account: account, credit: credit} = context.hub_credit
    consume(context, %{"sourceId" => "hub", "accountId" => account["id"], "creditId" => credit})
  end

  defp hub_account(context, id) do
    [%{"accounts" => accounts}] = context.hubs
    Enum.find(accounts, &(&1["id"] == id))
  end

  # Claude's login in a config directory of the scenario's, and its usage and reset
  # endpoints served by `Anthropic`. The fake CLI shows the reset once one is claimed.
  defp claude_resets(context) do
    dir = Path.join(context.mc.home, "claude-config")
    flag = Path.join(context.fakes.dir, "claude-reset")

    write_json(Path.join(dir, ".credentials.json"), %{
      "claudeAiOauth" => %{"accessToken" => "claude-token"}
    })

    write_json(Path.join(dir, ".claude.json"), %{
      "oauthAccount" => %{"organizationUuid" => "org-1"}
    })

    World.put_env("CLAUDE_CONFIG_DIR", dir)
    World.put_env("FAKE_CLAUDE_RESET_FLAG", flag)

    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {Anthropic, %{test: self(), flag: flag}}, port: 0, ip: :loopback},
          id: :fake_anthropic
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    World.put_app_env(:claude_api_base, "http://127.0.0.1:#{port}")
    context
  end

  defp consumed(context), do: Path.join(context.fakes.dir, "consumed")
  defp second_consumed(context), do: Path.join(context.fakes.dir, "consumed-work")

  # A Codex instance settings add, whose redemptions the fake logs apart from the built-in's.
  defp second_codex_instance(context, enabled) do
    World.merge_settings(%{
      "providerInstances" => %{
        "codex-work" => %{
          "driver" => "codex",
          "enabled" => enabled,
          "environment" => [
            %{"name" => "FAKE_CODEX_CONSUME_LOG", "value" => second_consumed(context)}
          ]
        }
      }
    })
  end

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
    Mc.ensure(HalC2.UsageLimitSources)

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
        context.mc.home,
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
    dir = Path.join(context.mc.home, "vendor-auth")

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

  # Off macOS a Cursor login that is not in a file is its "memory" store. A file left by
  # an earlier login must not be read.
  step "Cursor is signed in through the system keychain", context do
    dir = Path.join(context.mc.home, "vendor-auth")
    write_json(Path.join(dir, "config/cursor/auth.json"), %{"accessToken" => "vendor-token"})
    store = if match?({:unix, :darwin}, :os.type()), do: "default", else: "memory"

    context
    |> vendor_instance("cursor", %{
      "XDG_CONFIG_HOME" => Path.join(dir, "config"),
      "AGENT_CLI_CREDENTIAL_STORE" => store
    })
    |> tap(&merge_vendor_config(&1, "cursor", %{"apiEndpoint" => &1.vendor}))
  end

  step "Cursor says usage needs a file-based login", context do
    {limits, context} = usage_limits(context, "cursor")

    assert %{"windows" => [], "unavailable" => %{"reason" => "unsupported", "message" => message}} =
             limits

    assert message == "Cursor usage requires a file-based login or CURSOR_AUTH_TOKEN."
    context
  end

  step "Grok is connected with an explicit API key", context do
    # A grok.com sign-in is stored too: the explicit key decides whose quota it is.
    home = Path.join(context.mc.home, "vendor-auth/.grok")

    write_json(Path.join(home, "auth.json"), %{
      "https://accounts.x.ai/sign-in" => %{"key" => "vendor-token"}
    })

    vendor_instance(context, "grok", %{"GROK_HOME" => home, "XAI_API_KEY" => "xai-key"})
  end

  step "OpenCode runs on an external server", context do
    data = Path.join(context.mc.home, "vendor-auth/data")

    write_json(Path.join(data, "opencode/auth.json"), %{
      "opencode-go" => %{"type" => "api", "key" => "vendor-token"}
    })

    context = vendor_instance(context, "opencode", %{"XDG_DATA_HOME" => data})
    merge_vendor_config(context, "opencode", %{"serverUrl" => "http://127.0.0.1:4096"})
    context
  end

  step "Grok is signed in with a subscription and has not used any metered credit yet",
       context do
    home = Path.join(context.mc.home, "vendor-auth/.grok")

    write_json(Path.join(home, "auth.json"), %{
      "https://accounts.x.ai/sign-in" => %{"key" => "vendor-unmetered"}
    })

    vendor_instance(context, "grok", %{"GROK_HOME" => home})
  end

  step "Grok is signed in with a subscription as {string}", %{args: [email]} = context do
    home = Path.join(context.mc.home, "vendor-auth/.grok")

    write_json(Path.join(home, "auth.json"), %{
      "https://accounts.x.ai/sign-in" => %{"key" => "vendor-token", "email" => " #{email} "}
    })

    vendor_instance(context, "grok", %{"GROK_HOME" => home})
  end

  step "the user opens Limits", context do
    Mc.ensure(HalC2.ProviderUsageLimits)

    {_, context} =
      World.call!(context, "server.refreshProviders", %{"instanceId" => context.vendor_instance})

    context
  end

  # The client words for an account with no windows; on the MC, a listed account that
  # reports none.
  step "Grok's account is listed with the notice {string}", context do
    {limits, context} = usage_limits(context, "grok")
    assert %{"windows" => []} = limits
    context
  end

  step "it is not reported as not supported", context do
    {limits, context} = usage_limits(context, "grok")
    refute Map.has_key?(limits, "unavailable")
    context
  end

  step "Grok's limits name the account {string}", %{args: [email]} = context do
    {providers, context} = World.provider_list(context)
    grok = Enum.find(providers, &(&1["instanceId"] == "grok"))
    assert %{"auth" => %{"email" => ^email}} = grok
    assert [_] = grok["usageLimits"]["windows"]
    context
  end

  step "the MC checks limits", context do
    Mc.ensure(HalC2.ProviderUsageLimits)

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
