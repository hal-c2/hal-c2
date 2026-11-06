defmodule HalC2.ProviderUsageLimits.ClaudeResets do
  @moduledoc """
  Claude's banked resets (the CLI's `cedar_ember` program). The CLI reads the grants
  from the OAuth usage endpoint and claims one against the organization; this does
  the same with the login the CLI keeps in its config directory
  (`.credentials.json`) and the organization in its account record (`.claude.json`).
  macOS keeps that login in the Keychain, which the MC does not read, so there resets
  are not offered and nothing is sent.

  `:claude_api_base` (app env) is where requests go; anything but an http(s) URL turns
  the feature off before a login is read, which is how tests keep a real one unread.
  """

  alias HalC2.ProviderUsageLimits, as: Limits

  @program "cedar_ember"
  @grant_id ~r/^[a-z0-9_-]{1,40}$/
  @request_id ~r/^[A-Za-z0-9_-]{1,64}$/
  @outcomes %{
    "reset" => "reset",
    "not_limited" => "nothingToReset",
    "already_used" => "alreadyRedeemed",
    "ineligible" => "noCredit"
  }
  @failures %{
    malformed_credit: "Claude returned a malformed reset credit.",
    login_unreadable: "Claude could not read its login.",
    signed_out: "Sign in to Claude again to redeem resets.",
    rate_limited: "Claude is rate limiting resets. Try again soon.",
    cooling_down: "Claude resets are cooling down. Try again later.",
    unconfirmed:
      "Claude could not confirm the reset. If you are still limited in a moment, try again.",
    request_failed: "Claude could not redeem the reset."
  }

  @doc """
  The banked resets of `instance`'s login as `resetCredits`, or nil when there are
  none to offer: macOS, no login, not eligible, or any failure, so the windows never
  break on this extra.
  """
  def read(instance) do
    with {:ok, base} <- base(),
         token when is_binary(token) <- token(instance),
         {:ok, 200, %{} = body} <-
           request(:get, base <> "/api/oauth/usage?cedar_ember=1&skip_spend=1", token, instance) do
      credits(body["cedar_ember"], DateTime.utc_now())
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Claims `grant_id`. `request_id` is the idempotency key: a retry with the same id
  is the same claim. `{:ok, outcome}`, or `{:error, message, settled?}` where a
  settled failure is Claude's final answer and an unsettled one keeps the request id
  for the retry.
  """
  def consume(instance, grant_id, request_id) do
    with true <- is_binary(grant_id) and Regex.match?(@grant_id, grant_id),
         true <- Regex.match?(@request_id, request_id) do
      claim(instance, grant_id, request_id)
    else
      _ -> failure(:malformed_credit)
    end
  end

  defp claim(instance, grant_id, request_id) do
    with {:ok, base} <- base(),
         token when is_binary(token) <- token(instance),
         organization when is_binary(organization) <- organization(instance) do
      url = "#{base}/api/organizations/#{URI.encode_www_form(organization)}/reset_rate_limits"
      body = %{"program" => @program, "grant_id" => grant_id, "request_id" => request_id}

      case request(:post, url, token, instance, body) do
        {:ok, 429, _} ->
          failure(:rate_limited)

        {:ok, status, _} when status in [401, 403] ->
          failure(:signed_out)

        {:ok, 200, %{"result" => "cooldown"}} ->
          failure(:cooling_down)

        # Claude could not say whether the claim landed: the retry asks about the same one.
        {:ok, 200, %{"result" => "unavailable"}} ->
          failure(:unconfirmed)

        {:ok, 200, %{"result" => result}} when is_map_key(@outcomes, result) ->
          {:ok, @outcomes[result]}

        _ ->
          failure(:request_failed)
      end
    else
      :unreadable -> failure(:login_unreadable)
      _ -> failure(:signed_out)
    end
  end

  defp failure(reason),
    do: {:error, @failures[reason], reason not in [:request_failed, :unconfirmed]}

  @doc false
  # Grants that are paused, not usable now, or past `ends_at` cannot be claimed and
  # do not count.
  def credits(%{"eligible" => true} = block, now) do
    live =
      for %{"id" => id, "resets_left" => left} = grant <- List.wrap(block["grants"]),
          is_binary(id) and Regex.match?(@grant_id, id),
          is_integer(left) and left >= 0,
          grant["paused"] != true and grant["usable_now"] == true,
          live?(grant["ends_at"], now),
          do: grant

    case Enum.find(live, &(&1["id"] == block["next_grant_id"])) do
      nil ->
        %{"availableCount" => 0}

      next ->
        %{
          "availableCount" => Enum.sum_by(live, & &1["resets_left"]),
          "nextCreditId" => next["id"]
        }
        |> Limits.put_present("nextExpiresAt", Limits.iso(next["ends_at"]))
    end
  end

  def credits(_, _), do: nil

  defp live?(nil, _now), do: true

  defp live?(ends_at, now) when is_binary(ends_at) do
    case DateTime.from_iso8601(ends_at) do
      {:ok, at, _} -> DateTime.after?(at, now)
      _ -> false
    end
  end

  defp live?(_, _), do: false

  defp base do
    base = Application.get_env(:hal_c2, :claude_api_base, "https://api.anthropic.com")

    cond do
      (Application.get_env(:hal_c2, :os_type) || :os.type()) == {:unix, :darwin} -> :macos
      String.starts_with?(base, ["https://", "http://"]) -> {:ok, String.trim_trailing(base, "/")}
      true -> :off
    end
  end

  defp token(instance) do
    path = Path.join(HalC2.Claude.Provider.config_dir(instance), ".credentials.json")

    case read_json(path) do
      {:ok, %{"claudeAiOauth" => %{"accessToken" => token}}} when is_binary(token) ->
        blank_nil(token)

      {:ok, _} ->
        nil

      :error ->
        :unreadable
    end
  end

  # The CLI keeps the account record beside its settings when its config directory is
  # chosen, or in the home directory by default.
  defp organization(instance) do
    dir =
      if HalC2.Claude.Provider.home_path(instance) ||
           blank_nil(HalC2.Settings.instance_env(instance)["CLAUDE_CONFIG_DIR"]) ||
           blank_nil(System.get_env("CLAUDE_CONFIG_DIR")),
         do: HalC2.Claude.Provider.config_dir(instance),
         else: System.get_env("HOME") || System.user_home!()

    case read_json(Path.join(dir, ".claude.json")) do
      {:ok, %{"oauthAccount" => %{"organizationUuid" => id}}} when is_binary(id) -> blank_nil(id)
      {:ok, _} -> nil
      :error -> :unreadable
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, json} -> {:ok, json}
          _ -> :error
        end

      {:error, :enoent} ->
        {:ok, %{}}

      _ ->
        :error
    end
  end

  defp request(method, url, token, instance, body \\ nil) do
    headers = [
      {~c"authorization", to_charlist("Bearer " <> token)},
      {~c"anthropic-beta", ~c"oauth-2025-04-20"},
      {~c"user-agent", to_charlist("claude-cli/#{version(instance)} (external, cli)")}
    ]

    request =
      if body == nil,
        do: {to_charlist(url), headers},
        else: {to_charlist(url), headers, ~c"application/json", JSON.encode!(body)}

    options = [
      timeout: 25_000,
      connect_timeout: 10_000,
      ssl: :httpc.ssl_verify_host_options(true)
    ]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, _, response}} ->
        {:ok, status, with({:ok, json} <- JSON.decode(response), do: json, else: (_ -> nil))}

      error ->
        error
    end
  end

  defp version(instance) do
    case HalC2.ProviderUsageLimits.Claude.command(instance) do
      [path | _] -> HalC2.Claude.Provider.cli_version(path)
      _ -> "unknown"
    end
  end

  defp blank_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_nil(_), do: nil
end
