defmodule T3.ProviderUsageLimits.Grok do
  @moduledoc """
  Grok's subscription quota: how much of the billing period's credit is used, from
  xAI's CLI proxy (`GET /v1/billing?format=credits`), as the Node server reads it
  (`grokUsageLimits.ts`).

  Only a Grok account signed in with `grok login` has one. An API key
  (`XAI_API_KEY`) or a deployment with its own auth or endpoints (the `GROK_*`
  overrides, or those sections in Grok's config) is `unsupported`, so the node never
  reads an account the CLI would not use.
  """

  alias T3.ProviderUsageLimits, as: Limits

  @url "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
  @custom ~w(GROK_OIDC_ISSUER GROK_OIDC_CLIENT_ID GROK_OAUTH2_ISSUER GROK_OAUTH2_CLIENT_ID
             GROK_OAUTH2_PRINCIPAL_TYPE GROK_OAUTH2_PRINCIPAL_ID GROK_AUTH_PROVIDER_COMMAND
             GROK_LOCAL_AUTH GROK_CLI_CHAT_PROXY_BASE_URL GROK_MODELS_BASE_URL GROK_CONFIG
             GROK_CONFIG_PATH)
  # The credential `grok login` stores; other deployments in the same file are never read.
  @scopes [
    "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828",
    "https://accounts.x.ai/sign-in"
  ]
  @custom_section ~r/^\s*(?:\[\[?\s*)?["']?(?:auth|grok_com_config|endpoints)["']?\s*[.\]=]/m

  @doc "The instance's limits, read with its environment `env` (a map)."
  def probe(env, checked_at) do
    case token(env) do
      nil ->
        Limits.unavailable(checked_at, "unsupported")

      token ->
        case Limits.get_json(Application.get_env(:t3, :grok_billing_url, @url), token, 10_000) do
          {:ok, 200, %{} = body} -> limits(body, checked_at)
          _ -> failed(checked_at)
        end
    end
  rescue
    _ -> failed(checked_at)
  end

  @doc "The billing response as `ServerProviderUsageLimits`: one window for the period."
  def limits(body, checked_at) do
    config = body["config"] || %{}

    case config["creditUsagePercent"] do
      percent when is_number(percent) ->
        period = config["currentPeriod"] || %{}

        {kind, label} =
          case String.replace_prefix(period["type"] || "", "USAGE_PERIOD_TYPE_", "") do
            "WEEKLY" -> {"weekly", "Weekly"}
            "MONTHLY" -> {"monthly", "Monthly"}
            _ -> {"other", "Subscription"}
          end

        window =
          %{"id" => "subscription", "kind" => kind, "label" => label}
          |> Map.put("usedPercent", Limits.clamp(percent))
          |> Limits.put_present("resetsAt", Limits.iso(period["end"]))

        Limits.limits(checked_at, [window])

      _ ->
        Limits.unavailable(checked_at, "unsupported")
    end
  end

  defp token(env) do
    if present?(env["XAI_API_KEY"]) or Enum.any?(@custom, &present?(env[&1])) or
         custom_config?(env) do
      nil
    else
      credentials =
        case env["GROK_AUTH"] do
          auth when is_binary(auth) and auth != "" -> JSON.decode!(auth)
          _ -> read_json(Path.join(home(env), "auth.json"))
        end

      credential = Enum.find_value(@scopes, &credentials[&1]) || %{}
      key = if credential["auth_mode"] != "api_key", do: credential["key"]
      if present?(key), do: String.trim(key)
    end
  end

  defp custom_config?(env) do
    home = home(env)

    [
      Path.join(home, "config.toml"),
      Path.join(home, "managed_config.toml"),
      Path.join(home, "requirements.toml"),
      "/etc/grok/managed_config.toml",
      "/etc/grok/requirements.toml"
    ]
    |> Enum.any?(fn path ->
      case File.read(path) do
        {:ok, config} -> Regex.match?(@custom_section, config)
        {:error, _} -> false
      end
    end)
  end

  defp home(env) do
    if present?(env["GROK_HOME"]),
      do: String.trim(env["GROK_HOME"]),
      else: Path.join(env["HOME"] || System.user_home!(), ".grok")
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, body} -> JSON.decode!(body)
      {:error, :enoent} -> %{}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp failed(checked_at),
    do: Limits.unavailable(checked_at, "probeFailed", "Grok could not read usage limits.")
end
