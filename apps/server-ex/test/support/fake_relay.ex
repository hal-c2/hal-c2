defmodule T3.Test.FakeRelay do
  @moduledoc """
  The T3 Connect relay as a node sees it, served on a loopback port: environment
  links (challenge, link, tunnel release), agent activity, and relay client
  downloads. It signs with its own Ed25519 mint key, so steps can play the relay
  towards the node (`sign/2`), and tells `owner` about every request it takes as
  `{:fake_relay, method, path, body}`.

  `set/2` changes how it answers: `:fail` (`[{path_suffix, status, body}]`, a
  response for every request whose path ends so), `:downloads` (path → bytes),
  `:fail_once` (the same, each entry answering one request, in order), `:block`
  (true to hold each download until `release/1`).
  """

  use Plug.Router

  plug :match
  plug :dispatch

  @user "user-1"

  @doc "Starts a relay under the test supervisor; returns its handle."
  def start(owner \\ self()) do
    # Supervised, so it outlives the services started after it (a node releasing its tunnel).
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

    %{
      url: "http://127.0.0.1:#{port}",
      state: state,
      user: @user,
      public: public,
      private: private
    }
  end

  def set(%{state: state}, changes), do: Agent.update(state, &Map.merge(&1, Map.new(changes)))
  def get(%{state: state}, key), do: Agent.get(state, &Map.get(&1, key))

  @doc "The relay's mint public key, as it hands it to a node (SPKI PEM)."
  def mint_public_pem(relay), do: T3.Connect.Jwt.public_pem(relay.public)

  @doc "A JWT signed by the relay with header `typ`."
  def sign(relay, payload, typ), do: T3.Connect.Jwt.sign(payload, typ, relay.private)

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
  Plays the relay towards a node at `base` (its HTTP origin): a signed health check
  (`:health`) or credential request for the device key thumbprint `jkt` (`{:mint, jkt}`).
  `claims` override the request's own. Returns `{status, body, claims}`.
  """
  def ask(relay, base, kind, env, claims \\ %{}) do
    now = System.os_time(:second)

    {path, typ, own} =
      case kind do
        :health ->
          {"/api/t3-connect/health", "t3-cloud-health+jwt", %{"scope" => ["environment:status"]}}

        {:mint, jkt} ->
          {"/api/t3-connect/mint-credential", "t3-cloud-mint+jwt",
           %{
             "scope" => ["environment:connect"],
             "cnf" => %{"jkt" => jkt},
             "clientProofKeyThumbprint" => jkt
           }}
      end

    claims =
      %{
        "iss" => relay.url,
        "aud" => "t3-env:" <> env,
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
      send_proof(base <> "/api/t3-connect/health", %{
        "proof" => sign(relay, claims, "t3-cloud-health+jwt")
      })

  defp send_proof(url, body) do
    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(
        :post,
        {String.to_charlist(url), [], ~c"application/json", JSON.encode!(body)},
        [],
        body_format: :binary
      )

    {status, JSON.decode!(reply)}
  end

  @impl Plug
  def init(state), do: state

  @impl Plug
  def call(conn, state), do: conn |> put_private(:relay, state) |> super(state)

  match _ do
    state = conn.private.relay
    {:ok, raw, conn} = read_body(conn)

    body =
      case JSON.decode(raw) do
        {:ok, decoded} -> decoded
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
         {:ok, public} <- T3.Connect.Jwt.raw_public(pem),
         {:ok, _} <-
           T3.Connect.Jwt.verify(proof, "t3-env-link+jwt", public, "t3-env:" <> env, s_url(conn)) do
      # One tunnel per environment, kept across links, as the relay reuses its address.
      link =
        s.links[env] ||
          %{"tunnelId" => "tunnel-" <> env, "credential" => "env-credential-" <> env}

      link = Map.merge(link, %{"claims" => claims, "user" => @user, "online" => true})
      Agent.update(state, &put_in(&1, [:links, env], link))

      runtime =
        if body["managedTunnelsEnabled"],
          do: %{
            "providerKind" => "cloudflare_tunnel",
            "connectorToken" => "connector-" <> env,
            "tunnelId" => link["tunnelId"],
            "tunnelName" => "t3-" <> env
          },
          else: nil

      json(conn, 200, %{
        "relayIssuer" => s_url(conn),
        "cloudUserId" => @user,
        "environmentCredential" => link["credential"],
        "cloudMintPublicKey" => T3.Connect.Jwt.public_pem(s.public),
        "endpointRuntime" => runtime
      })
    else
      _ ->
        json(conn, 400, %{
          "_tag" => "RelayEnvironmentLinkProofInvalidError",
          "message" => "Invalid link proof",
          "traceId" => "trace-1"
        })
    end
  end

  # The node gives its tunnel back as it stops: the link stays, shown offline.
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

  defp route(conn, "DELETE", ["v1", "client", "environment-links", env], _body, state, _s) do
    Agent.update(state, &Map.update!(&1, :links, fn links -> Map.delete(links, env) end))
    json(conn, 200, %{"ok" => true})
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

    cond do
      get_req_header(conn, "authorization") != [
        "Bearer " <> ((s.links[env] || %{})["credential"] || "env-credential-" <> env)
      ] ->
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

  defp s_url(conn), do: "http://127.0.0.1:#{conn.port}"

  defp json(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))

  defp iso(seconds), do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.to_iso8601()
end
