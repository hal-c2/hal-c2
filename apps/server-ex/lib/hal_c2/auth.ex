defmodule HalC2.Auth do
  @moduledoc """
  Client authentication, wire-compatible with the Node server so existing clients
  pair with a node exactly as they pair with any environment.

    * A pairing token (5 minutes, single use) is exchanged at `/oauth/token` for a
      bearer access token (30 days). Tokens made in Settings → Connections are
      pairing links, listed and revocable until used.
    * The desktop app's bootstrap token (`HalC2.Desktop`) is exchanged the same way,
      as often as its window needs, for 24 hours from boot, with administrative
      scopes.
    * A bearer token buys a WebSocket ticket (5 minutes, single use), which the
      client puts in the socket URL so the long-lived token never appears there.
    * An exchange proven with a DPoP key (`HalC2.Auth.Dpop`; a HAL-C2 Connect device, or any
      client that sends a proof) makes a session bound to that key for 1 hour: each
      request carries `Authorization: DPoP <token>` and a fresh proof
      (`authenticate/1`); a bound token is never accepted as a bearer. A HAL-C2 Connect
      device renews through the relay; open sockets are unaffected.
    * With a reusable development credential (`HAL_C2_DEV_AUTH_TOKEN`, dev builds
      only), that credential is itself an administrative session in every node's
      own store, so one browser signs in to every worktree on a host.

  Pairing tokens and sessions are stored hashed in the node's SQLite file, so a
  `mix hal_c2.pair` run next to a running node can mint a pairing token too. Tickets
  live in ETS. Sockets register their session (`connected/1`) so Connections can
  show which clients are online; watchers of the access list get
  `{:hal_c2_auth_access, event}` (`AuthAccessStreamEvent`, with `current` left false
  for each socket to set).
  """

  use GenServer

  alias Exqlite.Sqlite3

  @pairing_ttl :timer.minutes(5)
  @session_ttl :timer.hours(24 * 30)
  @dpop_session_ttl :timer.hours(1)
  # The dev credential's session never expires (the Node server's 9999-12-31).
  @dev_expires_at 253_402_300_799_999
  @ticket_ttl :timer.minutes(5)
  @standard_scopes ~w(orchestration:read orchestration:operate terminal:operate review:write relay:read)
  @admin_scopes @standard_scopes ++ ~w(access:read access:write relay:write)
  @desktop_ttl :timer.hours(24)
  @tickets __MODULE__.Tickets

  @schema [
    "CREATE TABLE IF NOT EXISTS auth_pairing (token_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)",
    """
    CREATE TABLE IF NOT EXISTS auth_sessions (
      token_hash TEXT PRIMARY KEY,
      scopes TEXT NOT NULL,
      label TEXT,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )
    """
  ]

  # Added after the first release; `ensure_schema/1` adds them to older files.
  @columns [
    {"auth_pairing", "id", "TEXT"},
    {"auth_pairing", "label", "TEXT"},
    {"auth_pairing", "scopes", "TEXT"},
    {"auth_pairing", "created_at", "INTEGER"},
    # HAL-C2 Connect credentials: the DPoP key thumbprint that must redeem them.
    {"auth_pairing", "proof_jkt", "TEXT"},
    {"auth_sessions", "id", "TEXT"},
    {"auth_sessions", "last_connected_at", "INTEGER"},
    {"auth_sessions", "device_type", "TEXT"},
    {"auth_sessions", "os", "TEXT"},
    {"auth_sessions", "user_agent", "TEXT"},
    # The DPoP key thumbprint a session is bound to, or NULL for a bearer session.
    {"auth_sessions", "proof_jkt", "TEXT"},
    # What made the session: pairing, desktop-bootstrap or reusable-dev-token-child.
    {"auth_sessions", "subject", "TEXT"}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Creates a pairing token in the store at `path`; usable from outside the node.
  `admin: true` pairs with the operator's scopes, for tools on the host itself.
  """
  @spec create_pairing_token(String.t(), keyword) :: String.t()
  def create_pairing_token(path, opts \\ []) do
    scopes = if opts[:admin], do: @admin_scopes, else: @standard_scopes

    with_db(path, fn db ->
      ensure_schema(db)
      insert_pairing(db, nil, scopes)
    end)
    |> Map.fetch!("credential")
  end

  @doc """
  Exchanges a pairing token for `{:ok, access_token, expires_in_s, scopes}`.
  `client` describes who asked: `label`, `device_type`, `os`, `user_agent`,
  `proof_jkt`, the DPoP key it proved and the token is bound to (a HAL-C2 Connect
  credential needs its own), and `scopes` to ask for fewer than the credential grants
  (`{:error, :scope_not_granted}` when it asks for more).
  """
  @spec exchange(String.t(), map) ::
          {:ok, String.t(), pos_integer, [String.t()]} | :error | {:error, :scope_not_granted}
  def exchange(pairing_token, client \\ %{}),
    do: GenServer.call(__MODULE__, {:exchange, pairing_token, client})

  @doc """
  The session behind an access token, if valid. `proof_jkt` is the DPoP key it is
  bound to (nil for a bearer session); `request_session/1` checks the proof.
  """
  @spec session(String.t()) ::
          {:ok,
           %{
             id: String.t(),
             scopes: [String.t()],
             expires_at: integer,
             proof_jkt: String.t() | nil
           }}
          | :error
  def session(access_token), do: GenServer.call(__MODULE__, {:session, access_token})

  @doc """
  The session an HTTP request authenticates as: `Authorization: Bearer <token>` for a
  bearer session, or `Authorization: DPoP <token>` with a `DPoP` proof for this
  method and URL, signed by the session's key, naming the token (`ath`) and not
  used before. A bound token sent as a bearer is refused. Returns `{:ok, session}` or
  `{:error, reason, dpop_failure}` (`EnvironmentAuthInvalidError`'s `reason` and
  `dpopFailureReason`).
  """
  @spec authenticate(Plug.Conn.t()) :: {:ok, map} | {:error, String.t(), atom | nil}
  def authenticate(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [] ->
        {:error, "missing_credential", nil}

      ["Bearer " <> token] ->
        if HalC2.Web.access_token?(token) do
          {:ok, local_session()}
        else
          case session(token) do
            {:ok, %{proof_jkt: nil} = session} -> {:ok, session}
            _ -> {:error, "invalid_credential", nil}
          end
        end

      ["DPoP " <> token] ->
        with {:ok, %{proof_jkt: jkt} = session} when is_binary(jkt) <- session(token),
             proof = conn |> Plug.Conn.get_req_header("dpop") |> List.first(),
             {:ok, _} <-
               HalC2.Auth.Dpop.verify(proof, conn.method, Plug.Conn.request_url(conn),
                 thumbprint: jkt,
                 access_token: token
               ) do
          {:ok, session}
        else
          {:error, reason} -> {:error, "invalid_credential", reason}
          _ -> {:error, "invalid_credential", :invalid_proof}
        end

      _ ->
        {:error, "invalid_credential", nil}
    end
  end

  @doc """
  The session the node's own access token stands for on HTTP: local tools (the TUI) that
  can read `<data>/access-token` get the trust `?token=` has on the socket. It has no
  stored row (`id` nil), so it is not a paired client, cannot be revoked, and its
  tickets open sockets with the node's own token's scopes.
  """
  def local_session,
    do: %{id: nil, scopes: @admin_scopes, expires_at: @dev_expires_at, proof_jkt: nil}

  @doc "`authenticate/1` without the reason: `{:ok, session}` or `:error`."
  @spec request_session(Plug.Conn.t()) :: {:ok, map} | :error
  def request_session(%Plug.Conn{} = conn) do
    case authenticate(conn) do
      {:ok, session} -> {:ok, session}
      _ -> :error
    end
  end

  @doc "A WebSocket ticket for an access token, or for a session `request_session/1` found."
  @spec issue_ticket(String.t() | map) :: {:ok, String.t(), integer} | :error
  def issue_ticket(%{id: id}) do
    ticket = random_token()
    expires_at = now() + @ticket_ttl
    :ets.insert(@tickets, {ticket, expires_at, id})
    {:ok, ticket, expires_at}
  end

  def issue_ticket(access_token) do
    with {:ok, session} <- session(access_token), do: issue_ticket(session)
  end

  @doc """
  The client sessions in the store at `path`, as `GET /api/auth/clients` lists them
  (without `connected`, which only the running node knows); usable from outside the node.
  """
  def list_sessions(path) do
    with_db(path, fn db ->
      ensure_schema(db)
      session_rows(db, MapSet.new(), "expires_at > ?1", [now()])
    end)
  end

  @doc """
  Revokes the session `id` in the store at `path`; usable from outside the node. Its
  next ticket or request fails; a running node's open sockets drop on their next check.
  """
  def revoke_session(path, id), do: revoke(path, "id = ?1", [id]) != []

  @doc "Consumes a WebSocket ticket; each ticket opens one socket, for its session."
  @spec take_ticket(String.t()) :: {:ok, String.t() | nil} | :error
  def take_ticket(ticket) do
    case :ets.take(@tickets, ticket) do
      [{_, expires_at, session_id}] -> if expires_at > now(), do: {:ok, session_id}, else: :error
      [] -> :error
    end
  end

  @doc """
  A WebSocket ticket's session scopes, leaving the ticket usable: `{:ok, scopes}`.
  The device hub proxy (`HalC2.Devices.Proxy`) authenticates every stream and image
  of a Device panel with one ticket, as the Node server does.
  """
  @spec ticket_scopes(String.t()) :: {:ok, [String.t()]} | :error
  def ticket_scopes(ticket) do
    now = now()

    case :ets.lookup(@tickets, ticket) do
      [{_, expires_at, _}] when expires_at <= now ->
        :error

      # A ticket bought with the node's access token (`local_session/0`).
      [{_, _, nil}] ->
        {:ok, @admin_scopes}

      [{_, _, session_id}] ->
        GenServer.call(__MODULE__, {:scopes, session_id})

      [] ->
        :error
    end
  end

  def standard_scopes, do: @standard_scopes

  @doc "A session's scopes, while it is valid: `{:ok, scopes}`."
  @spec session_scopes(String.t()) :: {:ok, [String.t()]} | :error
  def session_scopes(session_id), do: GenServer.call(__MODULE__, {:scopes, session_id})

  @doc "Called by a socket of `session_id` once open; it counts as connected until it exits."
  def connected(session_id), do: GenServer.cast(__MODULE__, {:connected, session_id, self()})

  @doc "`POST /api/auth/pairing-token`: a pairing link, with its one-time credential."
  def create_pairing_link(input), do: GenServer.call(__MODULE__, {:create_link, input})

  @doc "`GET /api/auth/pairing-links`."
  def pairing_links, do: GenServer.call(__MODULE__, :links)

  @doc "`POST /api/auth/pairing-links/revoke`."
  def revoke_pairing_link(id), do: GenServer.call(__MODULE__, {:revoke_link, id})

  @doc "`GET /api/auth/clients`: `AuthClientSession`s, `current` false."
  def clients, do: GenServer.call(__MODULE__, :clients)

  @doc "`POST /api/auth/clients/revoke`."
  def revoke_client(id), do: GenServer.call(__MODULE__, {:revoke_client, id})

  @doc "`POST /api/auth/clients/revoke-others`: every session but `keep`."
  def revoke_other_clients(keep), do: GenServer.call(__MODULE__, {:revoke_others, keep})

  @doc "Watches the access list; replies with its revision and snapshot."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})

  # --- server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@tickets, [:named_table, :public, write_concurrency: true])
    HalC2.Auth.Dpop.init()
    path = HalC2.Store.path()
    with_db(path, &ensure_schema/1)
    dev = dev_credential(path)

    desktop =
      case Application.get_env(:hal_c2, :desktop_token) do
        nil -> nil
        token -> %{hash: hash(token), expires_at: now() + @desktop_ttl}
      end

    # Open sockets: socket pid -> session id.
    {:ok, %{path: path, desktop: desktop, dev: dev, revision: 0, watchers: %{}, sockets: %{}}}
  end

  @impl true
  def handle_call({:exchange, token, client}, _from, state) do
    {reply, events, replaced} =
      with_db(state.path, fn db ->
        case grant(db, token, client, state) do
          {:ok, granted, subject, events} ->
            requested = client[:scopes] || granted

            if Enum.all?(requested, &(&1 in granted)) do
              # Desktop restarts forget the previous token, so its session is replaced.
              replaced =
                if subject == "desktop-bootstrap",
                  do: revoke_rows(db, "subject = ?1", [subject]),
                  else: []

              {reply, created} = create_session(db, requested, subject, client, state)
              {reply, events ++ removed_clients(replaced) ++ created, replaced}
            else
              {{:error, :scope_not_granted}, events, []}
            end

          {:error, events} ->
            {:error, events, []}
        end
      end)

    close_sockets(state, replaced)
    {:reply, reply, broadcast(state, events)}
  end

  def handle_call({:session, token}, _from, state) do
    reply =
      with_db(state.path, fn db ->
        case query(
               db,
               "SELECT id, scopes, expires_at, proof_jkt FROM auth_sessions WHERE token_hash = ?1",
               [hash(token)]
             ) do
          [[id, scopes, expires_at, jkt]] ->
            if expires_at > now(),
              do:
                {:ok,
                 %{id: id, scopes: String.split(scopes), expires_at: expires_at, proof_jkt: jkt}},
              else: :error

          [] ->
            :error
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:scopes, session_id}, _from, state) do
    reply =
      with_db(state.path, fn db ->
        case query(db, "SELECT scopes, expires_at FROM auth_sessions WHERE id = ?1", [session_id]) do
          [[scopes, expires_at]] ->
            if expires_at > now(), do: {:ok, String.split(scopes)}, else: :error

          [] ->
            :error
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:create_link, input}, _from, state) do
    scopes = Enum.filter(input["scopes"] || @standard_scopes, &(&1 in @admin_scopes))
    ttl = input["ttlMs"] || @pairing_ttl

    link =
      with_db(
        state.path,
        &insert_pairing(&1, input["label"], scopes, ttl, input["proofKeyThumbprint"])
      )

    listed =
      Map.drop(link, ["credential"])
      |> Map.merge(%{"scopes" => scopes, "subject" => input["subject"] || "pairing-link"})

    state = broadcast(state, [event("pairingLinkUpserted", listed)])
    {:reply, {:ok, Map.take(link, ~w(id credential label expiresAt))}, state}
  end

  def handle_call(:links, _from, state), do: {:reply, links(state.path), state}

  def handle_call({:revoke_link, id}, _from, state) do
    revoked =
      with_db(state.path, fn db ->
        query(db, "DELETE FROM auth_pairing WHERE id = ?1 RETURNING id", [id]) != []
      end)

    events = if revoked, do: [event("pairingLinkRemoved", %{"id" => id})], else: []
    {:reply, revoked, broadcast(state, events)}
  end

  def handle_call(:clients, _from, state), do: {:reply, clients(state), state}

  def handle_call({:revoke_client, id}, _from, state) do
    revoked = revoke(state.path, "id = ?1", [id])
    close_sockets(state, revoked)
    {:reply, revoked != [], broadcast(state, removed_clients(revoked))}
  end

  def handle_call({:revoke_others, keep}, _from, state) do
    revoked = revoke(state.path, "id IS NOT ?1", [keep])
    close_sockets(state, revoked)
    {:reply, length(revoked), broadcast(state, removed_clients(revoked))}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    snapshot = %{"pairingLinks" => links(state.path), "clientSessions" => clients(state)}
    {:reply, {:ok, state.revision, snapshot}, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:connected, id, socket}, state) do
    Process.monitor(socket)
    state = %{state | sockets: Map.put(state.sockets, socket, id)}

    with_db(state.path, fn db ->
      exec(db, "UPDATE auth_sessions SET last_connected_at = ?1 WHERE id = ?2", [now(), id])
    end)

    {:noreply, broadcast(state, client_events(state, id))}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    {ref, watchers} = Map.pop(state.watchers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | watchers: watchers}}
  end

  # A watcher left, or a socket closed (its session may now be offline).
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {session, sockets} = Map.pop(state.sockets, pid)
    state = %{state | watchers: Map.delete(state.watchers, pid), sockets: sockets}
    events = if session, do: client_events(state, session), else: []
    {:noreply, broadcast(state, events)}
  end

  # --- store -------------------------------------------------------------------

  defp insert_pairing(db, label, scopes, ttl \\ @pairing_ttl, proof_jkt \\ nil) do
    token = random_token()
    id = "pairing-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    created = now()

    exec(
      db,
      "INSERT INTO auth_pairing (token_hash, expires_at, id, label, scopes, created_at, proof_jkt) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      [hash(token), created + ttl, id, label, Enum.join(scopes, " "), created, proof_jkt]
    )

    %{
      "id" => id,
      "credential" => token,
      "createdAt" => iso(created),
      "expiresAt" => iso(created + ttl)
    }
    |> put_present("label", label)
  end

  # What a credential grants: `{:ok, scopes, subject, events}` or `{:error, events}`.
  defp grant(db, token, client, state) do
    cond do
      state.dev != nil and :crypto.hash_equals(hash(token), state.dev.hash) ->
        # Revoking the dev session on this node stops it here, not on other nodes.
        case query(db, "SELECT 1 FROM auth_sessions WHERE id = ?1", [state.dev.id]) do
          [_] -> {:ok, @admin_scopes, "reusable-dev-token-child", []}
          [] -> {:error, []}
        end

      state.desktop != nil and :crypto.hash_equals(hash(token), state.desktop.hash) ->
        if state.desktop.expires_at > now(),
          do: {:ok, @admin_scopes, "desktop-bootstrap", []},
          else: {:error, []}

      true ->
        # A credential bound to a device's key stays unused for anyone else.
        case query(
               db,
               """
               DELETE FROM auth_pairing
               WHERE token_hash = ?1 AND (proof_jkt IS NULL OR proof_jkt = ?2)
               RETURNING expires_at, id, scopes
               """,
               [hash(token), client[:proof_jkt]]
             ) do
          [[expires_at, id, scopes]] when expires_at > 0 ->
            removed = [event("pairingLinkRemoved", %{"id" => id})]

            if expires_at > now(),
              do: {:ok, scopes(scopes), "pairing", removed},
              else: {:error, removed}

          _ ->
            {:error, []}
        end
    end
  end

  defp create_session(db, scopes, subject, client, state) do
    access = random_token()
    id = "session-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    created = now()
    ttl = if client[:proof_jkt], do: @dpop_session_ttl, else: @session_ttl

    exec(
      db,
      """
      INSERT INTO auth_sessions (token_hash, scopes, label, created_at, expires_at, id, device_type, os, user_agent, proof_jkt, subject)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      """,
      [
        hash(access),
        Enum.join(scopes, " "),
        client[:label],
        created,
        created + ttl,
        id,
        client[:device_type],
        client[:os],
        client[:user_agent],
        client[:proof_jkt],
        subject
      ]
    )

    upserted =
      for client <- session_rows(db, online(state), "id = ?1", [id]),
          do: event("clientUpserted", client)

    {{:ok, access, div(ttl, 1000), scopes}, upserted}
  end

  # The reusable development credential, as a session of its own in this node's store
  # (created once; a revoked one comes back on the next start, as on the Node server).
  defp dev_credential(path) do
    case Application.get_env(:hal_c2, :dev_auth_token) do
      token when is_binary(token) and token != "" ->
        id = "dev-auth-" <> hash(token)

        with_db(path, fn db ->
          exec(
            db,
            """
            INSERT OR IGNORE INTO auth_sessions (token_hash, scopes, label, created_at, expires_at, id, device_type, subject)
            VALUES (?1, ?2, 'Reusable dev token', ?3, ?4, ?5, 'unknown', 'reusable-dev-token')
            """,
            [hash(token), Enum.join(@admin_scopes, " "), now(), @dev_expires_at, id]
          )
        end)

        %{hash: hash(token), id: id}

      _ ->
        nil
    end
  end

  defp links(path) do
    with_db(path, fn db ->
      for [id, label, scopes, created, expires] <-
            query(
              db,
              "SELECT id, label, scopes, created_at, expires_at FROM auth_pairing WHERE expires_at > ?1 AND id IS NOT NULL ORDER BY created_at",
              [now()]
            ) do
        %{
          "id" => id,
          "scopes" => scopes(scopes),
          "subject" => "pairing-link",
          "createdAt" => iso(created || expires - @pairing_ttl),
          "expiresAt" => iso(expires)
        }
        |> put_present("label", label)
      end
    end)
  end

  defp clients(state),
    do: with_db(state.path, &session_rows(&1, online(state), "expires_at > ?1", [now()]))

  defp online(state), do: state.sockets |> Map.values() |> MapSet.new()

  defp session_rows(db, online, where, args) do
    for [id, scopes, label, created, expires, last, device, os, agent, jkt] <-
          query(
            db,
            "SELECT id, scopes, label, created_at, expires_at, last_connected_at, device_type, os, user_agent, proof_jkt FROM auth_sessions WHERE #{where} ORDER BY created_at",
            args
          ) do
      %{
        "sessionId" => id,
        "subject" => "client",
        "scopes" => String.split(scopes),
        "method" => session_method(jkt),
        "client" =>
          %{"deviceType" => device || device_type(agent)}
          |> put_present("label", label)
          |> put_present("os", os)
          |> put_present("userAgent", agent),
        "issuedAt" => iso(created),
        "expiresAt" => iso(expires),
        "lastConnectedAt" => last && iso(last),
        "connected" => MapSet.member?(online, id),
        "current" => false
      }
    end
  end

  # Deletes matching sessions, returning their ids.
  defp revoke(path, where, args), do: with_db(path, &revoke_rows(&1, where, args))

  defp revoke_rows(db, where, args),
    do:
      for(
        [id] <- query(db, "DELETE FROM auth_sessions WHERE #{where} RETURNING id", args),
        do: id
      )

  # A revoked session's open sockets close (`HalC2.Web.Socket`) rather than outlive it.
  defp close_sockets(state, ids) do
    for {socket, id} <- state.sockets, id in ids, do: send(socket, {:hal_c2_session_revoked, id})
  end

  defp removed_clients(ids), do: for(id <- ids, do: event("clientRemoved", %{"sessionId" => id}))

  defp client_events(state, id) do
    with_db(state.path, fn db ->
      for client <- session_rows(db, online(state), "id = ?1", [id]),
          do: event("clientUpserted", client)
    end)
  end

  @doc "How a session authenticates (`sessionMethod`): with or without a DPoP key."
  def session_method(nil), do: "bearer-access-token"
  def session_method(_jkt), do: "dpop-access-token"

  defp device_type(nil), do: "unknown"

  defp device_type(agent) do
    cond do
      agent =~ ~r/iPad|Tablet/i -> "tablet"
      agent =~ ~r/Mobile|iPhone|Android/i -> "mobile"
      agent =~ ~r/bot|curl|Elixir|node/i -> "bot"
      true -> "desktop"
    end
  end

  # --- events ------------------------------------------------------------------

  # `{type, payload}`, numbered when broadcast.
  defp event(type, payload), do: {type, payload}

  defp broadcast(state, []), do: state

  defp broadcast(state, events) do
    Enum.reduce(events, state, fn {type, payload}, state ->
      revision = state.revision + 1
      message = %{"version" => 1, "revision" => revision, "type" => type, "payload" => payload}
      for {pid, _} <- state.watchers, do: send(pid, {:hal_c2_auth_access, message})
      %{state | revision: revision}
    end)
  end

  # --- helpers -----------------------------------------------------------------

  defp ensure_schema(db) do
    Enum.each(@schema, &(:ok = Sqlite3.execute(db, &1)))

    for {table, column, type} <- @columns do
      existing = for [_, name | _] <- query(db, "PRAGMA table_info(#{table})", []), do: name

      unless column in existing,
        do: :ok = Sqlite3.execute(db, "ALTER TABLE #{table} ADD COLUMN #{column} #{type}")
    end

    # Rows written before sessions and links had ids.
    exec(
      db,
      "UPDATE auth_sessions SET id = 'session-' || substr(token_hash, 1, 16) WHERE id IS NULL",
      []
    )

    exec(
      db,
      "UPDATE auth_pairing SET id = 'pairing-' || substr(token_hash, 1, 12) WHERE id IS NULL",
      []
    )
  end

  defp scopes(nil), do: @standard_scopes
  defp scopes(text), do: String.split(text)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)
  defp now, do: System.os_time(:millisecond)
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp with_db(path, fun) do
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA busy_timeout = 5000")

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end

  defp query(db, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, args)
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    Sqlite3.release(db, stmt)
    rows
  end

  defp exec(db, sql, args), do: query(db, sql, args) && :ok
end
