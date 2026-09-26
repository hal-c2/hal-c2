defmodule HalC2.Connect do
  @moduledoc """
  HAL-C2 Connect, node side (`apps/server/src/cloud/http.ts`): linking this node to a
  user's cloud account through the relay, and answering the relay afterwards.

    * A client links the node by fetching a signed link proof (`link_proof/2`),
      handing it to the relay, and passing the relay's answer back
      (`apply_relay_config/1`), which starts the managed tunnel (`HalC2.Connect.Tunnel`).
    * An operator links from the command line instead: the stored desired link
      and sign-in make the node link itself at startup (`HalC2.Connect.Link`).
    * The relay then checks the node's health (`health/1`) and asks it to mint
      one-time credentials bound to a device's DPoP key (`mint_credential/1`); it
      never holds a session itself.

  Everything is kept in `HalC2.Connect.Secrets`, under the Node server's names. The
  relay is `HALC2_RELAY_URL` (app env `:connect_relay_url`) until a link names one.
  Failures are `{:error, status, message}`.
  """

  require Logger

  alias HalC2.Connect.{Jwt, Secrets, Tunnel}

  @mint_key "cloud-mint-ed25519-public-key"
  @runtime "cloud-endpoint-runtime-config"
  @user "cloud-linked-user-id"
  @relay_url "cloud-relay-url"
  @issuer "cloud-relay-issuer"
  @credential "cloud-relay-environment-credential"
  @publish "cloud-publish-agent-activity"
  @desired "cloud-cli-desired-link"
  @token "cloud-cli-oauth-token"
  @link_secrets [@mint_key, @runtime, @user, @relay_url, @issuer, @credential, @publish]

  @proof_ttl 300
  @mint_ttl :timer.minutes(2)

  # --- linking -------------------------------------------------------------------

  @doc """
  `POST /api/connect/link-proof`: the node's signed identity for the relay's
  `challenge`. `request` is the URL the node was asked on; the endpoint must be the
  node's own loopback origin, never one named by forwarded headers.
  """
  def link_proof(body, %{forwarded?: forwarded?, host: host, port: port}) do
    endpoint = body["endpoint"] || %{}
    origin = body["origin"] || %{}

    if forwarded? or endpoint["providerKind"] not in ["cloudflare_tunnel", "manual"] or
         not loopback?(origin["localHttpHost"]) or not loopback?(host) or
         origin["localHttpPort"] != port or not is_binary(body["challenge"]) do
      {:error, 400, "Invalid managed endpoint origin."}
    else
      {public, private} = Jwt.key_pair()
      id = HalC2.Environment.id()
      now = System.os_time(:second)

      scopes =
        if endpoint["providerKind"] == "cloudflare_tunnel",
          do: ["agent_activity_notifications", "managed_tunnels"],
          else: ["agent_activity_notifications"]

      payload = %{
        "iss" => "hal-c2-env:" <> id,
        "aud" => normalize_issuer(body["relayIssuer"]),
        "sub" => id,
        "jti" => uuid(),
        "iat" => now,
        "exp" => now + @proof_ttl,
        "challenge" => body["challenge"],
        "descriptor" => HalC2.Environment.descriptor(),
        "environmentId" => id,
        "environmentPublicKey" => Jwt.public_pem(public),
        "endpoint" => endpoint,
        "origin" => origin,
        "scopes" => scopes
      }

      {:ok, Jwt.sign(payload, "hal-c2-env-link+jwt", private)}
    end
  end

  @doc "`POST /api/connect/relay-config`: stores the relay's answer and starts the tunnel it names."
  def apply_relay_config(body) do
    with :ok <- valid_relay_url(body["relayUrl"]),
         :ok <- present(body["environmentCredential"], "Environment credential is required."),
         :ok <- present(body["cloudUserId"], "Cloud user id is required."),
         :ok <- same_user(body["cloudUserId"]),
         {:ok, _} <- mint_key(body["cloudMintPublicKey"]) do
      runtime = body["endpointRuntime"]
      status = Tunnel.apply(runtime)

      if status["status"] in ["disabled", "running"] do
        Secrets.put(@relay_url, body["relayUrl"])
        Secrets.put(@issuer, body["relayIssuer"] || body["relayUrl"])
        Secrets.put(@user, body["cloudUserId"])
        Secrets.put(@credential, body["environmentCredential"])
        Secrets.put(@mint_key, body["cloudMintPublicKey"])

        if runtime,
          do: Secrets.put(@runtime, JSON.encode!(runtime)),
          else: Secrets.delete(@runtime)

        {:ok, %{"ok" => true, "endpointRuntimeStatus" => status}}
      else
        {:error, 503, "Managed endpoint runtime could not be started.", status}
      end
    end
  end

  @doc "`GET /api/connect/link-state`."
  def link_state do
    user = Secrets.get(@user)

    %{
      "linked" => user != nil,
      "cloudUserId" => user,
      "relayUrl" => Secrets.get(@relay_url),
      "relayIssuer" => Secrets.get(@issuer),
      "managedTunnelActive" => Secrets.get(@runtime) != nil,
      "publishAgentActivity" => publishing?()
    }
  end

  @doc "`POST /api/connect/unlink`: stops the tunnel and forgets the link (the sign-in stays)."
  def unlink do
    status = Tunnel.apply(nil)
    forget_link()
    {:ok, %{"ok" => true, "endpointRuntimeStatus" => status}}
  end

  @doc "Clears the saved link and the operator's wish for one; the sign-in stays."
  def forget_link do
    Enum.each([@desired | @link_secrets], &Secrets.delete/1)
  end

  @doc """
  `POST /api/connect/preferences`: turns agent activity publishing on or off.
  Only a linked node can turn it on; it has nowhere to publish otherwise.
  """
  def preferences(%{"publishAgentActivity" => publish}) when is_boolean(publish) do
    cond do
      publish and Secrets.get(@user) == nil ->
        {:error, 409, "Link this environment to HAL-C2 Connect before publishing agent activity."}

      publish ->
        Secrets.put(@publish, "true")
        {:ok, link_state()}

      true ->
        Secrets.delete(@publish)
        {:ok, link_state()}
    end
  end

  def preferences(_), do: {:error, 400, "publishAgentActivity must be a boolean."}

  def publishing?, do: Secrets.get(@publish) == "true"

  @doc "Where and how to publish agent activity: `%{relay_url, issuer, credential}` or nil."
  def publish_target do
    with true <- publishing?(),
         url when is_binary(url) <- Secrets.get(@relay_url),
         credential when is_binary(credential) <- Secrets.get(@credential) do
      %{relay_url: url, issuer: Secrets.get(@issuer) || url, credential: credential}
    else
      _ -> nil
    end
  end

  # --- answering the relay ---------------------------------------------------------

  @doc "`POST /api/hal-c2-connect/health`: a signed \"online\", once per request nonce."
  def health(%{"proof" => proof}) do
    with {:ok, claims} <- relay_request(proof, "hal-c2-cloud-health+jwt", "environment:status"),
         :ok <-
           consume([
             {"cloud-health-jti-", claims["jti"]},
             {"cloud-health-nonce-", claims["nonce"]}
           ]) do
      {_public, private} = Jwt.key_pair()
      id = HalC2.Environment.id()
      now = System.os_time(:second)
      descriptor = HalC2.Environment.descriptor()
      checked = DateTime.utc_now() |> DateTime.to_iso8601()

      response =
        response_claims(now, now + @proof_ttl)
        |> Map.merge(%{
          "requestNonce" => claims["nonce"],
          "status" => "online",
          "descriptor" => descriptor,
          "checkedAt" => checked
        })

      {:ok,
       %{
         "environmentId" => id,
         "status" => "online",
         "descriptor" => descriptor,
         "checkedAt" => checked,
         "proof" => Jwt.sign(response, "hal-c2-env-health+jwt", private)
       }}
    else
      :replayed -> {:error, 409, "Cloud health request was already consumed."}
      _ -> {:error, 401, "Invalid cloud health request."}
    end
  end

  def health(_), do: {:error, 401, "Invalid cloud health request."}

  @doc """
  `POST /api/connect/mint-credential`: a two-minute pairing credential for the
  device the relay vouches for, redeemable only with that device's DPoP key.
  """
  def mint_credential(%{"proof" => proof}) do
    with {:ok, claims} <- relay_request(proof, "hal-c2-cloud-mint+jwt", "environment:connect"),
         %{"cnf" => %{"jkt" => jkt}, "clientProofKeyThumbprint" => jkt} when is_binary(jkt) <-
           claims,
         :ok <-
           consume([{"cloud-mint-jti-", claims["jti"]}, {"cloud-mint-nonce-", claims["nonce"]}]),
         {:ok, link} <-
           HalC2.Auth.create_pairing_link(%{
             "scopes" => HalC2.Auth.standard_scopes(),
             "label" => "HAL-C2 Connect connect",
             "subject" => "cloud-connect",
             "ttlMs" => @mint_ttl,
             "proofKeyThumbprint" => jkt
           }) do
      {_public, private} = Jwt.key_pair()
      now = System.os_time(:second)
      {:ok, expires, _} = DateTime.from_iso8601(link["expiresAt"])

      response =
        response_claims(now, DateTime.to_unix(expires))
        |> Map.merge(%{
          "clientProofKeyThumbprint" => jkt,
          "requestNonce" => claims["nonce"],
          "credential" => link["credential"]
        })

      {:ok,
       %{
         "credential" => link["credential"],
         "expiresAt" => link["expiresAt"],
         "proof" => Jwt.sign(response, "hal-c2-env-mint+jwt", private)
       }}
    else
      :replayed -> {:error, 409, "Cloud mint request was already consumed."}
      _ -> {:error, 401, "Invalid cloud mint request."}
    end
  end

  def mint_credential(_), do: {:error, 401, "Invalid cloud mint request."}

  # A relay-signed request for this node, from the linked account, with `scope` only.
  defp relay_request(proof, typ, scope) do
    id = HalC2.Environment.id()
    now = System.os_time(:second)

    with pem when is_binary(pem) <- Secrets.get(@mint_key),
         {:ok, key} <- Jwt.raw_public(pem),
         issuer when is_binary(issuer) <- Secrets.get(@issuer) || Secrets.get(@relay_url),
         {:ok, claims} <-
           Jwt.verify(proof, typ, key, normalize_issuer(issuer), "hal-c2-env:" <> id, now),
         %{"environmentId" => ^id, "sub" => sub, "iat" => iat, "exp" => exp, "scope" => [^scope]} <-
           claims,
         true <- sub == Secrets.get(@user),
         true <- exp > iat and exp - iat <= @proof_ttl and iat <= now + 60,
         true <- is_binary(claims["jti"]) and is_binary(claims["nonce"]) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  # Each jti and nonce is taken once; a request reusing either is a replay.
  # Relay-chosen values become file names only through a digest.
  defp consume(guards) do
    at = DateTime.utc_now() |> DateTime.to_iso8601()

    fresh =
      Enum.map(guards, fn {prefix, value} ->
        Secrets.create(prefix <> Base.encode16(:crypto.hash(:sha256, value), case: :lower), at)
      end)

    if Enum.all?(fresh, &(&1 == :ok)), do: :ok, else: :replayed
  end

  defp response_claims(now, exp) do
    id = HalC2.Environment.id()

    %{
      "iss" => "hal-c2-env:" <> id,
      "aud" => normalize_issuer(Secrets.get(@issuer) || Secrets.get(@relay_url)),
      "sub" => id,
      "jti" => uuid(),
      "iat" => now,
      "exp" => exp,
      "environmentId" => id
    }
  end

  # --- command-line link ------------------------------------------------------------

  @doc "The operator's saved link mode: `\"managed\"`, `\"publish_only\"` or nil."
  def desired_link, do: Secrets.get(@desired)

  @doc "The operator's stored HAL-C2 Connect sign-in, or nil."
  def cli_token do
    with json when is_binary(json) <- Secrets.get(@token),
         {:ok, %{"accessToken" => token}} when is_binary(token) <- JSON.decode(json),
         do: token,
         else: (_ -> nil)
  end

  @doc "The relay this node links through: the stored one, else the configured one."
  def relay_url do
    Secrets.get(@relay_url) || Application.get_env(:hal_c2, :connect_relay_url) ||
      System.get_env("HALC2_RELAY_URL")
  end

  @doc """
  Links the node as the operator asked (`hal-c2 connect link`), from its own loopback
  origin: challenge, proof, link, then `apply_relay_config/1`. `{:ok, result}`, or
  `{:error, :permanent | :transient, message}`: 4xx other than 408 and 429 will
  not get better by retrying.
  """
  def reconcile(local_origin) do
    uri = URI.parse(local_origin)
    mode = desired_link()
    managed = mode != "publish_only"

    flags = %{
      "notificationsEnabled" => true,
      "liveActivitiesEnabled" => true,
      "managedTunnelsEnabled" => managed
    }

    with {:token, token} when is_binary(token) <- {:token, cli_token()},
         {:url, url} when is_binary(url) <- {:url, relay_url()},
         {:ok, %{"challenge" => challenge}} <-
           relay(:post, url <> "/v1/client/environment-link-challenges", token, flags),
         {:ok, proof} <-
           link_proof(
             %{
               "challenge" => challenge,
               "relayIssuer" => url,
               "endpoint" => %{
                 "httpBaseUrl" => local_origin,
                 "wsBaseUrl" => String.replace_prefix(local_origin, "http", "ws"),
                 "providerKind" => if(managed, do: "cloudflare_tunnel", else: "manual")
               },
               "origin" => %{"localHttpHost" => uri.host, "localHttpPort" => uri.port}
             },
             %{forwarded?: false, host: uri.host, port: uri.port}
           ),
         {:ok, link} <-
           relay(
             :post,
             url <> "/v1/client/environment-links",
             token,
             Map.put(flags, "proof", proof)
           ) do
      Secrets.put(@desired, mode || "managed")

      case apply_relay_config(%{
             "relayUrl" => url,
             "relayIssuer" => link["relayIssuer"],
             "cloudUserId" => link["cloudUserId"],
             "environmentCredential" => link["environmentCredential"],
             "cloudMintPublicKey" => link["cloudMintPublicKey"],
             "endpointRuntime" => link["endpointRuntime"]
           }) do
        {:ok, result} -> {:ok, result}
        {:error, status, message} -> {:error, kind(status), message}
        {:error, status, message, _} -> {:error, kind(status), message}
      end
    else
      {:token, _} -> {:error, :permanent, "Run `hal-c2 connect link` to authorize this environment."}
      {:url, _} -> {:error, :permanent, "No HAL-C2 Connect relay is configured."}
      {:error, status, message} -> {:error, kind(status), message}
      {:error, message} -> {:error, :transient, message}
    end
  end

  @doc """
  Gives the managed tunnel back to the relay as the node stops normally: the
  connector stops and the relay marks the node offline, keeping its link and
  address for the next start. Only for a command-line managed link.
  """
  def release do
    runtime = Secrets.get(@runtime)
    url = Secrets.get(@relay_url)
    token = cli_token()

    if runtime && url && token && desired_link() == "managed" do
      Tunnel.apply(nil)
      id = URI.encode(HalC2.Environment.id(), &URI.char_unreserved?/1)

      case relay(:delete, "#{url}/v1/client/environment-links/#{id}/tunnel", token, nil) do
        {:ok, %{"ok" => true}} ->
          if Secrets.get(@runtime) == runtime, do: Secrets.delete(@runtime)
          :released

        other ->
          Logger.warning("Could not release the HAL-C2 Connect tunnel: #{inspect(other)}")
          :kept
      end
    else
      :none
    end
  end

  @doc """
  A request to the relay: `{:ok, json}`, `{:error, status, message}` for an HTTP
  failure (with the relay's recovery hint), or `{:error, message}` when it could
  not be reached.
  """
  def relay(method, url, bearer, body, headers \\ []) do
    headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(bearer)} | headers]
    url = String.to_charlist(url)

    request =
      if body == nil,
        do: {url, headers},
        else: {url, headers, ~c"application/json", JSON.encode!(body)}

    case :httpc.request(method, request, [timeout: 15_000, connect_timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, reply}} when status in 200..299 ->
        case JSON.decode(reply) do
          {:ok, json} -> {:ok, json}
          _ -> {:ok, %{}}
        end

      {:ok, {{_, status, _}, resp_headers, reply}} ->
        {:error, status, relay_message(status, reply, resp_headers)}

      {:error, reason} ->
        {:error,
         "Could not complete the HAL-C2 Connect relay request. The relay request failed (#{inspect(reason)}). Check this machine's network connection and relay availability, then retry."}
    end
  end

  @doc "What a relay failure tells the operator, with the way to recover (`relayResponse.ts`)."
  def relay_message(status, body, headers \\ []) do
    case JSON.decode(body) do
      {:ok, %{"_tag" => "Relay" <> _ = tag, "message" => message, "traceId" => trace}}
      when is_binary(message) and is_binary(trace) ->
        "HAL-C2 Connect: #{message}. #{hint(tag)} Trace ID: #{trace}."

      _ ->
        ray =
          case List.keyfind(headers, ~c"cf-ray", 0) do
            {_, ray} -> " Cloudflare Ray ID: #{ray}."
            nil -> ""
          end

        "HAL-C2 Connect relay returned HTTP #{status} without a recognized error response. Check relay access and any proxy or firewall restrictions, then restart HAL-C2.#{ray}"
    end
  end

  defp hint("RelayEnvironmentLinkLimitExceededError"),
    do: "Unlink an unused environment in HAL-C2 Connect, then restart HAL-C2 on this machine."

  defp hint("RelayAuthInvalidError"),
    do:
      "Run `hal-c2 connect login` to check this machine's authorization. If the stored credential was revoked, sign out with `hal-c2 connect logout`, then run `hal-c2 connect` again. Restart HAL-C2 after signing in."

  defp hint(tag)
       when tag in [
              "RelayEnvironmentLinkProofExpiredError",
              "RelayEnvironmentLinkProofInvalidError"
            ],
       do: "Check this machine's date and time, update HAL-C2, then restart it."

  defp hint(_),
    do:
      "Retry when the relay is available. If this continues, include the trace ID when reporting it."

  defp kind(status) when status in 400..499 and status not in [408, 429], do: :permanent
  defp kind(_), do: :transient

  # --- helpers ----------------------------------------------------------------------

  defp valid_relay_url(url) do
    case is_binary(url) && URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        :ok

      %URI{scheme: "http", host: host} when is_binary(host) ->
        if loopback?(host), do: :ok, else: bad_url()

      _ ->
        bad_url()
    end
  end

  defp bad_url, do: {:error, 400, "Relay URL must be a secure https URL."}

  defp present(value, message) do
    if is_binary(value) and String.trim(value) != "", do: :ok, else: {:error, 400, message}
  end

  defp same_user(user) do
    case Secrets.get(@user) do
      nil ->
        :ok

      ^user ->
        :ok

      _ ->
        {:error, 409,
         "This environment is already linked to a different cloud account. Unlink it before switching accounts."}
    end
  end

  defp mint_key(pem) do
    case Jwt.raw_public(pem) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, 400, "Cloud mint public key must be a valid Ed25519 public key."}
    end
  end

  def normalize_issuer(issuer),
    do: issuer |> to_string() |> String.trim() |> String.trim_trailing("/")

  defp loopback?(host), do: host in ["127.0.0.1", "::1", "[::1]", "localhost"]

  @doc "A random UUIDv4, for proof ids."
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u::128>> = <<a::48, 4::4, b::12, 2::2, c::62>>
    hex = u |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end
end
