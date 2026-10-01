defmodule HalC2.Test.FakeRelay do
  @moduledoc """
  The HAL-C2 Connect relay as an MC sees it, served on a loopback port: environment
  links (challenge, link, tunnel release, deregistering), the account's environment
  list and device connections, agent activity, relay client downloads, and the
  account's OAuth sign-in (authorization code with PKCE, device code, refresh). It
  signs with its own Ed25519 mint key, so steps can play the relay towards the MC
  (`sign/2`), and tells `owner` about every request it takes as
  `{:fake_relay, method, path, body}`.

  Its tunnel edge (`edge` in the handle) is a second loopback listener that passes
  each connection, byte for byte, to the origin of the account's linked MC while
  that MC's connector runs (a relay client under this VM holding the link's
  connector token), and answers 530 otherwise. It tells `owner`
  `{:fake_relay_edge, env}` for each connection it passes.

  `set/2` changes how it answers: `:fail` (`[{path_suffix, status, body}]`, a
  response for every request whose path ends so), `:downloads` (path → bytes),
  `:fail_once` (the same, each entry answering one request, in order), `:block`
  (true to hold each download until `release/1`), `:limit` (how many environments
  the account may link), `:device_interval` (seconds between device-code polls).
  """

  use Plug.Router

  plug :match
  plug :dispatch

  @user "user-1"

  @doc "Starts a relay under the test supervisor; returns its handle."
  def start(owner \\ self()) do
    # Supervised, so it outlives the services started after it (an MC releasing its tunnel).
    state =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               owner: owner,
               links: %{},
               fail: [],
               downloads: %{},
               block: false,
               accepted: MapSet.new(),
               revoked: MapSet.new(),
               limit: nil,
               codes: %{},
               devices: %{},
               counter: 0
             }
           end},
          id: {__MODULE__, :state, System.unique_integer()}
        )
      )

    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    Agent.update(state, &Map.merge(&1, %{public: public, private: private}))

    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {__MODULE__, state}, port: 0, ip: :loopback, startup_log: false},
          id: {__MODULE__, System.unique_integer()}
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    # The listening socket belongs to the calling (test) process, so it closes with it.
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, edge_port} = :inet.port(listen)

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({Task, fn -> accept(listen, state) end},
        id: {__MODULE__, :edge, System.unique_integer()}
      )
    )

    edge = "http://127.0.0.1:#{edge_port}"
    Agent.update(state, &Map.put(&1, :edge, edge))

    %{
      url: "http://127.0.0.1:#{port}",
      edge: edge,
      state: state,
      user: @user,
      public: public,
      private: private
    }
  end

  def set(%{state: state}, changes), do: Agent.update(state, &Map.merge(&1, Map.new(changes)))
  def get(%{state: state}, key), do: Agent.get(state, &Map.get(&1, key))

  @doc "The relay's mint public key, as it hands it to an MC (SPKI PEM)."
  def mint_public_pem(relay), do: HalC2.Connect.Jwt.public_pem(relay.public)

  @doc "A JWT signed by the relay with header `typ`."
  def sign(relay, payload, typ), do: HalC2.Connect.Jwt.sign(payload, typ, relay.private)

  @doc """
  Plays the hosted `/connect` page for a signed-in browser: the account approves a
  sign-in for PKCE `challenge`; returns the authorization code for the loopback callback.
  """
  def authorize(relay, challenge) do
    code = "code-#{System.unique_integer([:positive])}"
    Agent.update(relay.state, &put_in(&1, [:codes, code], challenge))
    code
  end

  @doc "Approves a device-code sign-in by its user code, as the account does on another device."
  def approve_device(relay, user_code) do
    Agent.update(relay.state, fn s ->
      devices =
        Map.new(s.devices, fn {device, entry} ->
          if entry.user_code == user_code,
            do: {device, %{entry | status: :approved}},
            else: {device, entry}
        end)

      %{s | devices: devices}
    end)
  end

  @doc "Lets held downloads finish."
  def release(relay) do
    held =
      Agent.get_and_update(
        relay.state,
        &{Map.get(&1, :held, []), Map.merge(&1, %{block: false, held: []})}
      )

    for pid <- held, do: send(pid, :fake_relay_release)
    :ok
  end

  @doc """
  Plays the relay towards an MC at `base` (its HTTP origin): a signed health check
  (`:health`) or credential request for the device key thumbprint `jkt` (`{:mint, jkt}`).
  `claims` override the request's own. Returns `{status, body, claims}`.
  """
  def ask(relay, base, kind, env, claims \\ %{}) do
    now = System.os_time(:second)

    {path, typ, own} =
      case kind do
        :health ->
          {"/api/hal-c2-connect/health", "hal-c2-cloud-health+jwt",
           %{"scope" => ["environment:status"]}}

        {:mint, jkt} ->
          {"/api/hal-c2-connect/mint-credential", "hal-c2-cloud-mint+jwt",
           %{
             "scope" => ["environment:connect"],
             "cnf" => %{"jkt" => jkt},
             "clientProofKeyThumbprint" => jkt
           }}
      end

    claims =
      %{
        "iss" => relay.url,
        "aud" => "hal-c2-env:" <> env,
        "sub" => relay.user,
        "jti" => "jti-#{System.unique_integer([:positive])}",
        "nonce" => "nonce-#{System.unique_integer([:positive])}",
        "iat" => now,
        "exp" => now + 60,
        "environmentId" => env
      }
      |> Map.merge(own)
      |> Map.merge(claims)

    {status, body} = send_proof(base <> path, %{"proof" => sign(relay, claims, typ)})
    {status, body, claims}
  end

  @doc "Sends a signed request `ask/5` made again, as a replay."
  def replay(relay, base, :health, claims),
    do:
      send_proof(base <> "/api/hal-c2-connect/health", %{
        "proof" => sign(relay, claims, "hal-c2-cloud-health+jwt")
      })

  defp send_proof(url, body) do
    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(
        :post,
        {String.to_charlist(url), [], ~c"application/json", JSON.encode!(body)},
        [],
        body_format: :binary
      )

    case JSON.decode(reply) do
      {:ok, decoded} -> {status, decoded}
      _ -> {status, reply}
    end
  end

  @impl Plug
  def init(state), do: state

  @impl Plug
  def call(conn, state), do: conn |> put_private(:relay, state) |> super(state)

  match _ do
    state = conn.private.relay
    {:ok, raw, conn} = read_body(conn)

    body =
      case {JSON.decode(raw), get_req_header(conn, "content-type")} do
        {{:ok, decoded}, _} -> decoded
        {_, ["application/x-www-form-urlencoded" <> _]} -> URI.decode_query(raw)
        _ -> raw
      end

    s = Agent.get(state, & &1)
    send(s.owner, {:fake_relay, conn.method, conn.request_path, body})

    case Enum.find(s.fail, fn {suffix, _, _} -> String.ends_with?(conn.request_path, suffix) end) ||
           once(state, conn.request_path) do
      {_, status, reply} -> json(conn, status, reply)
      nil -> route(conn, conn.method, conn.path_info, body, state, s)
    end
  end

  defp route(conn, "GET", ["download" | _], _body, state, s) do
    wait_released(state)

    case s.downloads[conn.request_path] do
      nil -> send_resp(conn, 404, "not found")
      bytes -> send_resp(conn, 200, bytes)
    end
  end

  defp route(conn, "POST", ["v1", "client", "environment-link-challenges"], _body, state, _s) do
    challenge = "challenge-" <> Integer.to_string(System.unique_integer([:positive]))
    Agent.update(state, &Map.put(&1, :challenge, challenge))
    json(conn, 200, %{"challenge" => challenge, "expiresAt" => iso(300)})
  end

  defp route(
         conn,
         "POST",
         ["v1", "client", "environment-links"],
         %{"proof" => proof} = body,
         state,
         s
       ) do
    with [_, p, _] <- String.split(proof, "."),
         {:ok, json} <- Base.url_decode64(p, padding: false),
         {:ok,
          %{"environmentId" => env, "environmentPublicKey" => pem, "challenge" => challenge} =
            claims} <- JSON.decode(json),
         true <- challenge == s[:challenge],
         {:ok, public} <- HalC2.Connect.Jwt.raw_public(pem),
         {:ok, _} <-
           HalC2.Connect.Jwt.verify(
             proof,
             "hal-c2-env-link+jwt",
             public,
             "hal-c2-env:" <> env,
             s_url(conn)
           ) do
      # One tunnel per environment, kept across links, as the relay reuses its address.
      # A deregistered environment that links again gets a new credential.
      credential =
        if MapSet.member?(s.revoked, "env-credential-" <> env),
          do: "env-credential-#{env}-#{System.unique_integer([:positive])}",
          else: "env-credential-" <> env

      link =
        s.links[env] ||
          %{"tunnelId" => "tunnel-" <> env, "credential" => credential, "linkedAt" => iso(0)}

      link =
        Map.merge(link, %{
          "claims" => claims,
          "user" => @user,
          "online" => true,
          "connector" => if(body["managedTunnelsEnabled"], do: "connector-" <> env)
        })

      others = Enum.count(s.links, fn {id, other} -> id != env and other["user"] == @user end)

      if s.limit && others >= s.limit do
        json(
          conn,
          409,
          relay_error("RelayEnvironmentLinkLimitExceededError", "Environment link limit reached")
        )
      else
        Agent.update(state, &put_in(&1, [:links, env], link))
        linked(conn, s, body, link)
      end
    else
      _ ->
        json(conn, 400, %{
          "_tag" => "RelayEnvironmentLinkProofInvalidError",
          "message" => "Invalid link proof",
          "traceId" => "trace-1"
        })
    end
  end

  # The MC gives its tunnel back as it stops: the link stays, shown offline.
  defp route(
         conn,
         "DELETE",
         ["v1", "client", "environment-links", env, "tunnel"],
         _body,
         state,
         s
       ) do
    if s.links[env], do: Agent.update(state, &put_in(&1, [:links, env, "online"], false))
    json(conn, 200, %{"ok" => true})
  end

  # Deregistering: the link and its credential are revoked, freeing the account's place.
  defp route(conn, "DELETE", ["v1", "client", "environment-links", env], _body, state, _s) do
    Agent.update(state, fn s ->
      revoked =
        case s.links[env] do
          %{"credential" => credential} -> MapSet.put(s.revoked, credential)
          nil -> s.revoked
        end

      %{s | links: Map.delete(s.links, env), revoked: revoked}
    end)

    json(conn, 200, %{"ok" => true})
  end

  # The account's environments, each at its tunnel address when it has one.
  defp route(conn, "GET", ["v1", "environments"], _body, _state, s) do
    environments =
      for {env, %{"user" => @user} = link} <- s.links do
        %{
          "environmentId" => env,
          "label" => get_in(link, ["claims", "descriptor", "label"]) || env,
          "endpoint" => endpoint(s, link),
          "linkedAt" => link["linkedAt"]
        }
      end

    json(conn, 200, %{"environments" => environments})
  end

  # A device asks for access: the relay has the MC mint a credential for the
  # device's key, through the MC's tunnel, and hands it on.
  defp route(conn, "POST", ["v1", "environments", env, "connect"], body, _state, s) do
    jkt = body["clientProofKeyThumbprint"] || body["clientKeyThumbprint"]

    case s.links[env] do
      nil ->
        json(conn, 404, relay_error("RelayEnvironmentNotFoundError", "Environment not found"))

      link ->
        endpoint = endpoint(s, link)
        relay = %{url: s_url(conn), user: @user, private: s.private}

        case ask(relay, endpoint["httpBaseUrl"], {:mint, jkt}, env) do
          {200, %{"credential" => credential} = minted, _claims} ->
            json(conn, 200, %{
              "environmentId" => env,
              "endpoint" => endpoint,
              "credential" => credential,
              "expiresAt" => minted["expiresAt"] || iso(120)
            })

          _ ->
            json(
              conn,
              503,
              relay_error("RelayEnvironmentUnavailableError", "Environment is unavailable")
            )
        end
    end
  end

  defp route(conn, "POST", ["oauth", "device_authorization"], _body, state, s) do
    device_code = "device-#{System.unique_integer([:positive])}"
    user_code = "WDJB-MJHT"

    Agent.update(
      state,
      &put_in(&1, [:devices, device_code], %{user_code: user_code, status: :pending})
    )

    json(conn, 200, %{
      "device_code" => device_code,
      "user_code" => user_code,
      "verification_uri" => s_url(conn) <> "/oauth/device",
      "verification_uri_complete" => s_url(conn) <> "/oauth/device?user_code=" <> user_code,
      "expires_in" => 600,
      "interval" => s[:device_interval] || 5
    })
  end

  defp route(conn, "POST", ["oauth", "token"], body, state, s) do
    case body do
      %{"grant_type" => "authorization_code", "code" => code, "code_verifier" => verifier} ->
        challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

        if s.codes[code] == challenge do
          Agent.update(state, &Map.update!(&1, :codes, fn codes -> Map.delete(codes, code) end))
          json(conn, 200, tokens())
        else
          json(conn, 400, %{"error" => "invalid_grant"})
        end

      %{"grant_type" => "urn:ietf:params:oauth:grant-type:device_code", "device_code" => device} ->
        case s.devices[device] do
          %{status: :approved} ->
            Agent.update(state, &Map.update!(&1, :devices, fn d -> Map.delete(d, device) end))
            json(conn, 200, tokens())

          %{status: :pending} ->
            json(conn, 400, %{"error" => "authorization_pending"})

          nil ->
            json(conn, 400, %{"error" => "invalid_grant"})
        end

      %{"grant_type" => "refresh_token"} ->
        json(conn, 200, tokens())

      _ ->
        json(conn, 400, %{"error" => "unsupported_grant_type"})
    end
  end

  defp route(
         conn,
         "POST",
         ["v1", "environments", env, "threads", thread, "agent-activity"],
         body,
         state,
         s
       ) do
    key = {env, thread, body["proof"]}

    credential = (s.links[env] || %{})["credential"] || "env-credential-" <> env

    cond do
      get_req_header(conn, "authorization") != ["Bearer " <> credential] or
          MapSet.member?(s.revoked, credential) ->
        json(conn, 401, %{"_tag" => "RelayAuthInvalidError", "message" => "unauthorized"})

      MapSet.member?(s.accepted, key) ->
        json(conn, 409, %{
          "_tag" => "RelayAgentActivityPublishProofInvalidError",
          "reason" => "replayed",
          "message" => "Agent activity proof was already used",
          "traceId" => "trace-1"
        })

      true ->
        Agent.update(state, &%{&1 | accepted: MapSet.put(&1.accepted, key)})
        json(conn, 200, %{"ok" => true, "deliveries" => 1})
    end
  end

  defp route(conn, _method, _path, _body, _state, _s), do: send_resp(conn, 404, "not found")

  # The next `:fail_once` entry for this path, taken so the one after answers.
  defp once(state, path) do
    Agent.get_and_update(state, fn s ->
      queue = Map.get(s, :fail_once, [])

      case Enum.split_with(queue, fn {suffix, _, _} -> String.ends_with?(path, suffix) end) do
        {[entry | rest], others} -> {entry, Map.put(s, :fail_once, rest ++ others)}
        {[], _} -> {nil, s}
      end
    end)
  end

  defp wait_released(state) do
    me = self()

    held? =
      Agent.get_and_update(state, fn s ->
        if s.block, do: {true, Map.update(s, :held, [me], &[me | &1])}, else: {false, s}
      end)

    if held? do
      send(Agent.get(state, & &1.owner), {:fake_relay, :download_held, me})

      receive do
        :fake_relay_release -> :ok
      end
    end
  end

  defp relay_error(tag, message),
    do: %{"_tag" => tag, "message" => message, "traceId" => "trace-1"}

  defp s_url(conn), do: "http://127.0.0.1:#{conn.port}"

  defp json(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))

  defp iso(seconds), do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.to_iso8601()
  # The link reply: the MC's credential, the relay's mint key, and the tunnel it runs.
  defp linked(conn, s, body, link) do
    runtime =
      if body["managedTunnelsEnabled"],
        do: %{
          "providerKind" => "cloudflare_tunnel",
          "connectorToken" => link["connector"],
          "tunnelId" => link["tunnelId"],
          "tunnelName" => String.replace_prefix(link["tunnelId"], "tunnel-", "hal-c2-")
        },
        else: nil

    json(conn, 200, %{
      "relayIssuer" => s_url(conn),
      "cloudUserId" => @user,
      "environmentCredential" => link["credential"],
      "cloudMintPublicKey" => HalC2.Connect.Jwt.public_pem(s.public),
      "endpointRuntime" => runtime
    })
  end

  defp endpoint(s, %{"connector" => connector} = link) when is_binary(connector) do
    ws = String.replace_prefix(s.edge, "http", "ws")

    %{"httpBaseUrl" => s.edge, "wsBaseUrl" => ws, "providerKind" => "cloudflare_tunnel"}
    |> Map.merge(if link["online"], do: %{}, else: %{"online" => false})
  end

  defp endpoint(_s, link), do: get_in(link, ["claims", "endpoint"]) || %{}

  defp tokens do
    claims = %{"sub" => "user_operator", "email" => "operator@example.com"}
    segment = fn map -> map |> JSON.encode!() |> Base.url_encode64(padding: false) end

    %{
      "access_token" => "clerk-token",
      "refresh_token" => "refresh-#{System.unique_integer([:positive])}",
      "token_type" => "Bearer",
      "expires_in" => 3600,
      "id_token" => segment.(%{"alg" => "none"}) <> "." <> segment.(claims) <> "."
    }
  end

  # --- tunnel edge ---------------------------------------------------------------

  defp accept(listen, state) do
    # The listener closes with the test that opened it.
    with {:ok, socket} <- :gen_tcp.accept(listen) do
      handler = spawn(fn -> receive(do: (:go -> edge(socket, state))) end)
      :ok = :gen_tcp.controlling_process(socket, handler)
      send(handler, :go)
      accept(listen, state)
    end
  end

  # Passes one connection to the linked MC's origin while its connector runs.
  defp edge(socket, state) do
    s = Agent.get(state, & &1)

    case Enum.find(s.links, fn {_env, link} -> running?(link) end) do
      {env, link} ->
        port = get_in(link, ["claims", "origin", "localHttpPort"])
        {:ok, origin} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])
        send(s.owner, {:fake_relay_edge, env})
        :ok = :inet.setopts(socket, active: true)
        pipe(socket, origin)

      nil ->
        :gen_tcp.send(socket, "HTTP/1.1 530 Origin Unreachable\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.close(socket)
    end
  end

  defp pipe(client, origin) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(origin, data)
        pipe(client, origin)

      {:tcp, ^origin, data} ->
        :gen_tcp.send(client, data)
        pipe(client, origin)

      {:tcp_closed, _} ->
        :gen_tcp.close(client)
        :gen_tcp.close(origin)
    end
  end

  # A link's tunnel is up while a relay client started from this test runs with its
  # connector token (a process under this VM with `TUNNEL_TOKEN` set to it).
  defp running?(%{"online" => true, "connector" => token}) when is_binary(token),
    do: token in connectors()

  defp running?(_link), do: false

  defp connectors do
    parents =
      for dir <- Path.wildcard("/proc/[0-9]*"),
          {:ok, stat} <- [File.read(Path.join(dir, "stat"))],
          # The command name may hold spaces; the fields after it do not.
          [_, rest] <- [String.split(stat, ") ", parts: 2)],
          [_state, ppid | _] = String.split(rest, " "),
          into: %{},
          do: {Path.basename(dir), ppid}

    for pid <- descendants(parents, [System.pid()], []),
        {:ok, environ} <- [File.read("/proc/#{pid}/environ")],
        "TUNNEL_TOKEN=" <> token <- String.split(environ, <<0>>),
        do: token
  end

  defp descendants(_parents, [], found), do: found

  defp descendants(parents, [pid | rest], found) do
    children = for {child, ^pid} <- parents, do: child
    descendants(parents, children ++ rest, children ++ found)
  end
end
