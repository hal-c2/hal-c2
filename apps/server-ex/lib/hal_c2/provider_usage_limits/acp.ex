defmodule HalC2.ProviderUsageLimits.Acp do
  @moduledoc """
  Subscription quota of the ACP agents whose vendors publish it, read from the
  account the agent's CLI is signed in to:

    * Grok: the billing period's credit use, from the grok.com sign-in in
      `$GROK_HOME/auth.json`;
    * Cursor: the month's plan use (total, Auto, API), from a file-based Cursor
      login or `CURSOR_AUTH_TOKEN`;
    * OpenCode: the OpenCode Go session, weekly and monthly windows, from
      OpenCode's stored `opencode-go` key or `OPENCODE_API_KEY`.

  An account that cannot be read this way (an API key, a custom deployment, an
  external OpenCode server) is `unsupported`; a failed read is `probeFailed`.
  Each instance reads with the MC's environment plus the variables set on it.
  """

  import HalC2.ProviderUsageLimits, only: [limits: 2, unavailable: 2, unavailable: 3, clamp: 1]

  @drivers ~w(grok cursor opencode)

  @grok_accounts [
    "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828",
    "https://accounts.x.ai/sign-in"
  ]

  # Any of these can select another account or endpoint than the stored sign-in.
  @grok_custom ~w(GROK_OIDC_ISSUER GROK_OIDC_CLIENT_ID GROK_OAUTH2_ISSUER GROK_OAUTH2_CLIENT_ID
                  GROK_OAUTH2_PRINCIPAL_TYPE GROK_OAUTH2_PRINCIPAL_ID GROK_AUTH_PROVIDER_COMMAND
                  GROK_LOCAL_AUTH GROK_CLI_CHAT_PROXY_BASE_URL GROK_MODELS_BASE_URL GROK_CONFIG
                  GROK_CONFIG_PATH)

  @doc "The enabled ACP instances whose quota can be read."
  def instances do
    for id <- HalC2.Acp.instances(),
        HalC2.Acp.driver(id) in @drivers,
        HalC2.Acp.enabled?(id),
        do: id
  end

  @doc "Whether `instance` is one of `instances/0`."
  def instance?(instance), do: instance in instances()

  @doc "Reads one instance's `ServerProviderUsageLimits`."
  def probe(instance, checked_at) do
    env = env(instance)

    case HalC2.Acp.driver(instance) do
      "grok" -> grok(env, checked_at)
      "cursor" -> cursor(instance, env, checked_at)
      "opencode" -> opencode(instance, env, checked_at)
    end
  end

  defp env(instance) do
    extra =
      case HalC2.Acp.command(instance) do
        {:ok, _command, env} -> Map.new(env)
        _ -> %{}
      end

    Map.merge(System.get_env(), extra)
  end

  # --- Grok ------------------------------------------------------------------------

  defp grok(env, checked_at) do
    home = present(env["GROK_HOME"]) || Path.join(home(env), ".grok")

    cond do
      present(env["XAI_API_KEY"]) ->
        unavailable(checked_at, "unsupported")

      Enum.any?(@grok_custom, &present(env[&1])) or grok_custom_config?(home) ->
        unavailable(checked_at, "unsupported")

      true ->
        auth = present(env["GROK_AUTH"]) || read(Path.join(home, "auth.json"))

        with {:ok, %{} = credentials} <- JSON.decode(auth),
             credential = Enum.find_value(@grok_accounts, &credentials[&1]),
             token when is_binary(token) <- grok_token(credential) do
          case http(:get, grok_url(), token) do
            {:ok, %{"config" => %{"creditUsagePercent" => used} = config}} when is_number(used) ->
              limits(checked_at, [grok_window(used, config["currentPeriod"] || %{})])

            {:ok, %{}} ->
              unavailable(checked_at, "unsupported")

            _ ->
              unavailable(checked_at, "probeFailed", "Grok could not read usage limits.")
          end
        else
          {:error, _} ->
            unavailable(checked_at, "probeFailed", "Grok could not read usage limits.")

          _ ->
            unavailable(checked_at, "unsupported")
        end
    end
  end

  defp grok_custom_config?(home) do
    [
      Path.join(home, "config.toml"),
      Path.join(home, "managed_config.toml"),
      Path.join(home, "requirements.toml"),
      "/etc/grok/managed_config.toml",
      "/etc/grok/requirements.toml"
    ]
    |> Enum.any?(
      &Regex.match?(
        ~r/^\s*(?:\[\[?\s*)?["']?(?:auth|grok_com_config|endpoints)["']?\s*[.\]=]/m,
        read(&1, "")
      )
    )
  end

  defp grok_token(%{"auth_mode" => "api_key"}), do: nil
  defp grok_token(%{"key" => key}), do: present(key)
  defp grok_token(_), do: nil

  defp grok_window(used, period) do
    kind =
      case String.replace_prefix(to_string(period["type"]), "USAGE_PERIOD_TYPE_", "") do
        "WEEKLY" -> "weekly"
        "MONTHLY" -> "monthly"
        _ -> "other"
      end

    %{
      "id" => "subscription",
      "kind" => kind,
      "label" => %{"weekly" => "Weekly", "monthly" => "Monthly"}[kind] || "Subscription",
      "usedPercent" => clamp(used)
    }
    |> HalC2.ProviderUsageLimits.put_present(
      "resetsAt",
      HalC2.ProviderUsageLimits.iso(period["end"])
    )
  end

  defp grok_url,
    do:
      Application.get_env(
        :hal_c2,
        :grok_billing_url,
        "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
      )

  # --- Cursor ----------------------------------------------------------------------

  @cursor_windows [
    {"totalPercentUsed", "Monthly"},
    {"autoPercentUsed", "Monthly · Auto"},
    {"apiPercentUsed", "Monthly · API"}
  ]

  defp cursor(instance, env, checked_at) do
    store = env["AGENT_CLI_CREDENTIAL_STORE"]

    cond do
      token = present(env["CURSOR_AUTH_TOKEN"]) ->
        cursor_read(instance, env, token, checked_at)

      # An API key (the MC's own Cursor sign-in) can name another account than the CLI login.
      present(env["CURSOR_API_KEY"]) || cursor_api_key?(env) ->
        unavailable(checked_at, "unsupported")

      store == "memory" or (match?({:unix, :darwin}, :os.type()) and store != "file") ->
        unavailable(
          checked_at,
          "unsupported",
          "Cursor usage requires a file-based login or CURSOR_AUTH_TOKEN."
        )

      token = cursor_login(env) ->
        cursor_read(instance, env, token, checked_at)

      true ->
        unavailable(checked_at, "unsupported")
    end
  end

  defp cursor_api_key?(env) do
    match?(
      {:ok, %{"apiKey" => key}} when is_binary(key) and key != "",
      JSON.decode(read(env["HAL_C2_CURSOR_CREDENTIALS"] || ""))
    )
  end

  defp cursor_login(env) do
    dir =
      case :os.type() do
        {:unix, :darwin} ->
          Path.join(home(env), ".cursor")

        {:win32, _} ->
          Path.join(env["APPDATA"] || Path.join(home(env), "AppData/Roaming"), "Cursor")

        _ ->
          Path.join(present(env["XDG_CONFIG_HOME"]) || Path.join(home(env), ".config"), "cursor")
      end

    case JSON.decode(read(Path.join(dir, "auth.json"))) do
      {:ok, %{"accessToken" => token}} -> present(token)
      _ -> nil
    end
  end

  defp cursor_read(instance, env, token, checked_at) do
    endpoint =
      (HalC2.Acp.setting(instance, "apiEndpoint") || present(env["CURSOR_API_ENDPOINT"]) ||
         "https://api2.cursor.sh")
      |> String.trim()
      |> String.trim_trailing("/")

    headers = [{~c"connect-protocol-version", ~c"1"}, {~c"x-cursor-client-type", ~c"cli"}]
    url = endpoint <> "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

    case http(:post, url, token, headers) do
      {:ok, %{} = body} ->
        resets_at = cursor_reset(body["billingCycleEnd"])
        usage = if is_map(body["planUsage"]), do: body["planUsage"], else: %{}

        windows =
          for {key, label} <- @cursor_windows, is_number(usage[key]) do
            %{
              "id" => key,
              "kind" => "monthly",
              "label" => label,
              "usedPercent" => clamp(usage[key])
            }
            |> HalC2.ProviderUsageLimits.put_present("resetsAt", resets_at)
          end

        if windows == [],
          do: unavailable(checked_at, "unsupported"),
          else: limits(checked_at, windows)

      _ ->
        unavailable(checked_at, "probeFailed", "Cursor could not read usage limits.")
    end
  end

  defp cursor_reset(value) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} -> cursor_reset(ms)
      _ -> nil
    end
  end

  defp cursor_reset(ms) when is_number(ms) and ms > 0,
    do: HalC2.ProviderUsageLimits.iso_from_seconds(ms / 1000)

  defp cursor_reset(_), do: nil

  # --- OpenCode Go -----------------------------------------------------------------

  @opencode_windows [
    {"rolling", "go_rolling", "session", "Go · Session", 300},
    {"weekly", "go_weekly", "weekly", "Go · Weekly", 10_080},
    {"monthly", "go_monthly", "monthly", "Go · Monthly", nil}
  ]

  # An external OpenCode server owns its credentials; the host's account is not its own.
  defp opencode(instance, env, checked_at) do
    if HalC2.Acp.setting(instance, "serverUrl") do
      unavailable(checked_at, "unsupported")
    else
      data = present(env["XDG_DATA_HOME"]) || Path.join(home(env), ".local/share")
      auth = present(env["OPENCODE_AUTH_CONTENT"]) || read(Path.join(data, "opencode/auth.json"))

      key =
        case JSON.decode(auth) do
          {:ok, %{"opencode-go" => %{"type" => "api", "key" => key}}} when is_binary(key) -> key
          _ -> env["OPENCODE_API_KEY"]
        end

      case present(key) && http(:get, opencode_url(), String.trim(key)) do
        nil ->
          unavailable(checked_at, "unsupported")

        # A Zen key without a Go subscription.
        {:error, 403} ->
          unavailable(checked_at, "unsupported")

        {:ok, %{"usage" => usage}} ->
          opencode_limits(usage, checked_at)

        _ ->
          unavailable(checked_at, "probeFailed", "OpenCode Go could not read usage.")
      end
    end
  end

  defp opencode_limits(usage, checked_at) do
    windows =
      for {key, id, kind, label, mins} <- @opencode_windows,
          %{"percent" => used, "resetsAt" => resets} <- [usage[key]],
          is_number(used),
          resets_at <- [HalC2.ProviderUsageLimits.iso(resets)],
          resets_at != nil do
        %{
          "id" => id,
          "kind" => kind,
          "label" => label,
          "usedPercent" => clamp(used),
          "resetsAt" => resets_at
        }
        |> HalC2.ProviderUsageLimits.put_present("windowDurationMins", mins)
      end

    if length(windows) == 3,
      do: limits(checked_at, windows),
      else: unavailable(checked_at, "probeFailed", "OpenCode Go could not read usage.")
  end

  defp opencode_url,
    do:
      Application.get_env(:hal_c2, :opencode_go_usage_url, "https://opencode.ai/zen/go/v1/usage")

  # --- helpers ---------------------------------------------------------------------

  defp http(method, url, token, headers \\ []) do
    headers = [{~c"authorization", ~c"Bearer " ++ to_charlist(token)} | headers]

    request =
      if method == :post,
        do: {to_charlist(url), headers, ~c"application/json", "{}"},
        else: {to_charlist(url), headers}

    options = [timeout: 10_000, connect_timeout: 5_000, ssl: :httpc.ssl_verify_host_options(true)]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} when status in 200..299 ->
        case JSON.decode(body) do
          {:ok, json} -> {:ok, json}
          _ -> {:error, :body}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, status}

      other ->
        {:error, other}
    end
  rescue
    error -> {:error, error}
  end

  defp home(env), do: present(env["HOME"]) || present(env["USERPROFILE"]) || System.user_home!()

  defp read(path, default \\ "{}") do
    case File.read(path) do
      {:ok, contents} -> contents
      _ -> default
    end
  end

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp present(_), do: nil
end
