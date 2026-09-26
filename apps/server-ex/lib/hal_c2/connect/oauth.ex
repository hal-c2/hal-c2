defmodule HalC2.Connect.OAuth do
  @moduledoc """
  The operator's HAL-C2 Connect sign-in on the host (`apps/server/src/cloud/CliTokenManager.ts`),
  kept as the `cloud-cli-oauth-token` secret the node links with at startup.

    * `loopback/1`: a browser on this machine. The operator opens the hosted app's
      `/connect` page, which sends the authorization code to a one-off listener on
      `127.0.0.1` (`/callback`); the code is redeemed with PKCE.
    * `device/1`: no browser here (SSH, `--headless`). The account's auth provider
      issues a short code the operator approves on any other device while this
      process polls (RFC 8628).

  Endpoints come from app env `:connect_oauth` (`token_endpoint`,
  `device_authorization_endpoint`, `client_id`, `hosted_app_url`, `loopback_port`),
  else from `HALC2_CLERK_PUBLISHABLE_KEY`, `HALC2_CLERK_CLI_OAUTH_CLIENT_ID` and
  `HALC2_HOSTED_APP_URL`, as the Node server reads them.
  """

  alias HalC2.Connect.Secrets

  @token "cloud-cli-oauth-token"
  @scopes "openid profile email offline_access"
  @device_grant "urn:ietf:params:oauth:grant-type:device_code"
  @callback_timeout :timer.minutes(10)
  @slow_down :timer.seconds(5)

  @doc "The sign-in endpoints, or `{:error, message}` when this build has none configured."
  def config do
    env = Map.new(Application.get_env(:hal_c2, :connect_oauth, []))

    frontend =
      case System.get_env("HALC2_CLERK_PUBLISHABLE_KEY", "") |> String.trim() do
        "pk_" <> _ = key -> clerk_frontend(key)
        _ -> nil
      end

    config = %{
      token_endpoint: env[:token_endpoint] || (frontend && frontend <> "/oauth/token"),
      device_authorization_endpoint:
        env[:device_authorization_endpoint] ||
          (frontend && frontend <> "/oauth/device_authorization"),
      client_id: env[:client_id] || blank(System.get_env("HALC2_CLERK_CLI_OAUTH_CLIENT_ID")),
      hosted_app_url:
        env[:hosted_app_url] || blank(System.get_env("HALC2_HOSTED_APP_URL")) ||
          "https://app.hal-c2.example",
      loopback_port: Map.get(env, :loopback_port, 34338)
    }

    if config.token_endpoint && config.client_id,
      do: {:ok, config},
      else:
        {:error,
         "HAL-C2 Connect sign-in is not configured for this build. Set HALC2_CLERK_PUBLISHABLE_KEY and HALC2_CLERK_CLI_OAUTH_CLIENT_ID."}
  end

  @doc "Whether this looks like a session without a local browser (SSH)."
  def headless_session?,
    do: System.get_env("SSH_CONNECTION") != nil or System.get_env("SSH_TTY") != nil

  @doc "The stored sign-in (`accessToken`, `refreshToken`, `expiresAtEpochMs`, `identity`), or nil."
  def stored do
    with json when is_binary(json) <- Secrets.get(@token),
         {:ok, %{"accessToken" => _} = token} <- JSON.decode(json),
         do: token,
         else: (_ -> nil)
  end

  @doc """
  Signs in through a browser on this machine. `show.(url)` tells the operator where
  to go. `{:ok, identity | nil}` once the sign-in is stored, or `{:error, message}`.
  """
  def loopback(show) do
    with {:ok, config} <- config() do
      verifier = random(32)
      challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
      state = random(16)
      ref = make_ref()

      {:ok, server} =
        Bandit.start_link(
          plug: {__MODULE__.Callback, %{state: state, to: {self(), ref}}},
          ip: :loopback,
          port: config.loopback_port,
          startup_log: false
        )

      try do
        {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

        show.(
          config.hosted_app_url <>
            "/connect#" <>
            URI.encode_query(%{"state" => state, "challenge" => challenge, "port" => port})
        )

        receive do
          {^ref, code} ->
            redeem(config, %{
              "grant_type" => "authorization_code",
              "code" => code,
              "redirect_uri" => "http://127.0.0.1:#{port}/callback",
              "client_id" => config.client_id,
              "code_verifier" => verifier
            })
        after
          @callback_timeout ->
            {:error, "HAL-C2 Connect authorization timed out. Run the command again to retry."}
        end
      after
        ThousandIsland.stop(server)
      end
    end
  end

  @doc """
  Signs in with a device code. `show.(%{uri, code, expires_in})` tells the operator
  where to approve it. `{:ok, identity | nil}` once approved and stored.
  """
  def device(show) do
    with {:ok, config} <- config(),
         {:ok, %{"device_code" => device_code, "user_code" => user_code} = auth} <-
           post(config.device_authorization_endpoint, %{
             "client_id" => config.client_id,
             "scope" => @scopes
           }) do
      expires_in = auth["expires_in"] || 600

      show.(%{
        uri: auth["verification_uri_complete"] || auth["verification_uri"],
        code: user_code,
        expires_in: expires_in
      })

      deadline = System.monotonic_time(:millisecond) + expires_in * 1000
      poll(config, device_code, round((auth["interval"] || 5) * 1000), deadline)
    else
      {:error, _status, body} ->
        {:error, "Could not start device authorization: #{describe(body)}"}

      {:error, _} = error ->
        error

      _ ->
        {:error, "Could not start device authorization."}
    end
  end

  defp poll(config, device_code, interval, deadline) do
    if System.monotonic_time(:millisecond) + interval > deadline do
      {:error, "HAL-C2 Connect authorization expired before it was approved. Run the command again."}
    else
      receive do
      after
        interval -> :ok
      end

      params = %{
        "grant_type" => @device_grant,
        "device_code" => device_code,
        "client_id" => config.client_id
      }

      case post(config.token_endpoint, params) do
        {:ok, body} ->
          store(body)

        {:error, status, _} when status >= 500 ->
          poll(config, device_code, interval + @slow_down, deadline)

        {:error, _status, %{"error" => "authorization_pending"}} ->
          poll(config, device_code, interval, deadline)

        {:error, _status, %{"error" => "slow_down"}} ->
          poll(config, device_code, interval + @slow_down, deadline)

        {:error, _status, %{"error" => "expired_token"}} ->
          {:error,
           "HAL-C2 Connect authorization expired before it was approved. Run the command again."}

        {:error, _status, %{"error" => "access_denied"}} ->
          {:error, "HAL-C2 Connect authorization was denied."}

        {:error, _status, body} ->
          {:error, "HAL-C2 Connect authorization failed: #{describe(body)}"}

        {:error, :transport} ->
          poll(config, device_code, interval + @slow_down, deadline)
      end
    end
  end

  defp redeem(config, params) do
    case post(config.token_endpoint, params) do
      {:ok, body} -> store(body)
      {:error, _status, body} -> {:error, "HAL-C2 Connect authorization failed: #{describe(body)}"}
      {:error, :transport} -> {:error, "Could not reach the HAL-C2 Connect sign-in service."}
    end
  end

  # Keeps a token response as the Node server does; the identity comes from the id token.
  defp store(%{"access_token" => access} = body) do
    identity = identity(body["id_token"])

    token =
      %{
        "accessToken" => access,
        "refreshToken" => body["refresh_token"] || "",
        "expiresAtEpochMs" => System.os_time(:millisecond) + (body["expires_in"] || 3600) * 1000
      }
      |> then(&if(identity, do: Map.put(&1, "identity", identity), else: &1))

    Secrets.put(@token, JSON.encode!(token))
    {:ok, identity}
  end

  defp store(_body), do: {:error, "The sign-in service answered without a token."}

  # An unverified read: the id token only names the account for the operator to see.
  defp identity(id_token) when is_binary(id_token) do
    with [_, payload, _] <- String.split(id_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- JSON.decode(json) do
      claims["email"] || claims["preferred_username"] || claims["sub"]
    else
      _ -> nil
    end
  end

  defp identity(_), do: nil

  defp post(url, params) do
    case :httpc.request(
           :post,
           {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded",
            URI.encode_query(params)},
           [timeout: 15_000, connect_timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, reply}} ->
        body =
          case JSON.decode(reply) do
            {:ok, json} -> json
            _ -> reply
          end

        if status in 200..299, do: {:ok, body}, else: {:error, status, body}

      {:error, _} ->
        {:error, :transport}
    end
  end

  defp describe(%{"error_description" => description}) when is_binary(description),
    do: description

  defp describe(%{"error" => error}), do: error
  defp describe(body) when is_binary(body), do: body
  defp describe(body), do: inspect(body)

  # `pk_live_<base64 of "frontend.api.host$">`.
  defp clerk_frontend(key) do
    with [_, _, encoded] <- String.split(key, "_", parts: 3),
         {:ok, decoded} <- Base.decode64(encoded, padding: false),
         host when host != "" <- String.trim_trailing(decoded, "$") do
      "https://" <> host
    else
      _ -> nil
    end
  end

  defp blank(nil), do: nil
  defp blank(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defmodule Callback do
    @moduledoc false
    # The loopback listener the authorization code is sent to.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{request_path: "/callback"} = conn, %{state: state, to: {pid, ref}}) do
      conn = fetch_query_params(conn)

      case conn.query_params do
        %{"state" => ^state, "code" => code} when code != "" ->
          send(pid, {ref, code})

          conn
          |> put_resp_content_type("text/html")
          |> send_resp(
            200,
            "<!doctype html><meta charset=\"utf-8\"><title>HAL-C2 Connect</title><p>HAL-C2 Connect is authorized. You can close this tab and return to the terminal.</p>"
          )

        _ ->
          send_resp(conn, 400, "Invalid HAL-C2 Connect authorization callback.")
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end
end
