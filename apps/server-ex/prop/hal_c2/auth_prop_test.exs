defmodule HalC2.AuthPropTest do
  @moduledoc """
  `HalC2.Auth` against a model of what it promises: a pairing token redeems once and
  grants the scopes it was minted with; a session authenticates until it expires or is
  revoked, as a bearer or by DPoP proof (each proof accepted once, for the key and
  token it names); a WebSocket ticket opens one socket for a session that is still
  there; what expired is rejected, and `prune/0` drops it. Time is a fixed clock the
  commands advance. Restarting `HalC2.Auth` must keep every pairing token and session,
  and forgets tickets and proof records (they live in ETS).

  A handle (an integer) names each token, session, ticket and proof, so a shrunk
  counterexample reads `exchange(3, 4, nil, nil)`. `HalC2.Prop.Auth` maps handles to
  the real credentials.

  The second property redeems and takes concurrently: single use means exactly one
  of any number of racing callers wins.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Auth
  alias HalC2.Prop.Auth, as: Reg
  alias HalC2.Store

  @moduletag timeout: :infinity

  @pairing_ttl :timer.minutes(5)
  @session_ttl :timer.hours(24 * 30)
  @dpop_ttl :timer.hours(1)
  @ticket_ttl :timer.minutes(5)
  @standard ~w(orchestration:read orchestration:operate terminal:operate review:write relay:read)
  @admin @standard ++ ~w(access:read access:write relay:write)
  @url "http://www.example.com/api/x"

  property "tokens, tickets, sessions and proofs keep their promises",
    numtests: HalC2.Prop.numtests(100),
    max_size: 60 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("auth")
        HalC2.Prop.start_services([{Store, path: Store.home_path()}, Auth])
        Reg.setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        stop_sockets()
        Reg.teardown()
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # links: pending pairing tokens (unexpired or not, until pruned). sessions: rows of
  # the store, expired ones until pruned. The `*_seen` lists keep dead handles so
  # commands can use a token after it was redeemed, revoked or expired.
  def initial_state do
    %{
      clock: Reg.t0(),
      next: 1,
      links: %{},
      links_seen: [],
      sessions: %{},
      sessions_seen: [],
      tickets: %{},
      tickets_seen: [],
      proofs: %{},
      sockets: %{}
    }
  end

  def command(state) do
    n = state.next

    frequency(
      [
        {5, {:call, __MODULE__, :mint_link, [n, link_scopes(), link_ttl(), maybe_key()]}},
        {1, {:call, __MODULE__, :mint_static, [n, boolean()]}},
        {2, {:call, __MODULE__, :pairing_links, []}},
        {2, {:call, __MODULE__, :clients, []}},
        {1, {:call, __MODULE__, :list_static, []}},
        {1, {:call, __MODULE__, :bad_credential, [oneof([:none, :bearer, :dpop, :basic])]}},
        {1, {:call, __MODULE__, :issue_local_ticket, [n]}},
        {3, {:call, __MODULE__, :advance, [duration()]}},
        {1, {:call, __MODULE__, :prune, []}},
        {1, {:call, __MODULE__, :restart, []}}
      ] ++
        if state.links_seen == [] do
          []
        else
          [
            {8,
             let lh <- pick(Map.keys(state.links), state.links_seen) do
               # Usually the key the token is bound to, so exchanges succeed.
               bound = get_in(state.links, [lh, :bound])
               key = frequency([{4, bound}, {1, maybe_key()}])
               {:call, __MODULE__, :exchange, [lh, n, requested_scopes(), key]}
             end},
            {2,
             {:call, __MODULE__, :revoke_link, [pick(Map.keys(state.links), state.links_seen)]}}
          ]
        end ++
        if state.sessions_seen == [] do
          []
        else
          seen = pick(Map.keys(state.sessions), state.sessions_seen)

          [
            {3, {:call, __MODULE__, :bearer_request, [seen]}},
            {4, {:call, __MODULE__, :issue_ticket, [n, oneof([:token, :session]), seen]}},
            {3, {:call, __MODULE__, :revoke_client, [seen]}},
            {1, {:call, __MODULE__, :revoke_others, [seen]}},
            {2, {:call, __MODULE__, :connect, [seen]}},
            {4, {:call, __MODULE__, :make_proof, [n, seen, key(), variant(), offset()]}}
          ]
        end ++
        if state.tickets_seen == [] do
          []
        else
          [
            {5,
             {:call, __MODULE__, :take_ticket,
              [pick(Map.keys(state.tickets), state.tickets_seen)]}},
            {3,
             {:call, __MODULE__, :ticket_scopes,
              [pick(Map.keys(state.tickets), state.tickets_seen)]}}
          ]
        end ++
        if map_size(state.proofs) == 0 or state.sessions_seen == [] do
          []
        else
          [
            {6,
             {:call, __MODULE__, :send_proof,
              [oneof(Map.keys(state.proofs)), oneof(state.sessions_seen)]}}
          ]
        end ++
        if Enum.any?(state.sockets, fn {_, c} -> c > 0 end) do
          [
            {2,
             {:call, __MODULE__, :disconnect, [oneof(for {h, c} <- state.sockets, c > 0, do: h)]}}
          ]
        else
          []
        end
    )
  end

  # Mostly something still alive, sometimes anything ever made, so dead credentials get used.
  defp pick([], seen), do: oneof(seen)
  defp pick(live, seen), do: frequency([{4, oneof(live)}, {1, oneof(seen)}])

  defp link_scopes do
    oneof([
      nil,
      nil,
      let(s <- resize(5, list(oneof(@admin ++ ["bogus:scope"]))), do: Enum.uniq(s))
    ])
  end

  defp requested_scopes do
    frequency([
      {8, nil},
      {2, let(s <- resize(4, list(oneof(@admin ++ ["bogus:scope"]))), do: Enum.uniq(s))},
      {2, let(s <- resize(3, list(oneof(@standard))), do: Enum.uniq(s))}
    ])
  end

  defp link_ttl, do: frequency([{6, nil}, {1, 1_000}, {1, 60_000}])
  defp maybe_key, do: frequency([{3, nil}, {2, key()}])
  defp key, do: integer(0, Reg.key_count() - 1)

  defp variant,
    do: frequency([{6, :ok}, {1, :wrong_method}, {1, :wrong_url}, {1, :wrong_ath}, {1, :forged}])

  defp offset, do: oneof([0, 0, -1, -299, -300, -301, 4, 5, 6, 60, -3600])

  # Seconds: inside a proof's window, past it, past a ticket, a pairing token, an hour, a month.
  defp duration do
    frequency([
      {4, 1_000},
      {3, 4_000},
      {3, 100_000},
      {2, 301_000},
      {1, 400_000},
      {1, 61 * 60_000},
      {1, 31 * 24 * 3_600_000}
    ])
  end

  def precondition(state, {:call, _, :connect, [h]}), do: Map.has_key?(state.sessions, h)

  def precondition(state, {:call, _, :issue_ticket, [_, :session, h]}),
    do: valid?(state, h)

  def precondition(state, {:call, _, :make_proof, [_, h, _, _, _]}),
    do: h in state.sessions_seen

  # A proof an earlier run of Auth accepted is not sent again: the replay record died with
  # that process (see the report on where the tables should live).
  def precondition(state, {:call, _, :send_proof, [p, h]}),
    do:
      state.proofs[p] != nil and state.proofs[p].accepted != :forgotten and
        h in state.sessions_seen

  def precondition(state, {:call, _, :disconnect, [h]}), do: Map.get(state.sockets, h, 0) > 0

  def precondition(state, {:call, _, name, [h | _]})
      when name in [:exchange, :revoke_link],
      do: h in state.links_seen

  def precondition(state, {:call, _, :take_ticket, [t]}), do: t in state.tickets_seen
  def precondition(state, {:call, _, :ticket_scopes, [t]}), do: t in state.tickets_seen
  def precondition(_state, _call), do: true

  defp valid?(state, h) do
    case state.sessions[h] do
      %{expires: expires} -> expires > state.clock
      nil -> false
    end
  end

  # --- next_state ---

  def next_state(state, _r, {:call, _, :mint_link, [h, scopes, ttl, key]}) do
    link = %{
      scopes: Enum.filter(scopes || @standard, &(&1 in @admin)),
      expires: state.clock + (ttl || @pairing_ttl),
      bound: key
    }

    %{
      state
      | next: h + 1,
        links: Map.put(state.links, h, link),
        links_seen: state.links_seen ++ [h]
    }
  end

  def next_state(state, _r, {:call, _, :mint_static, [h, admin?]}) do
    link = %{
      scopes: if(admin?, do: @admin, else: @standard),
      expires: state.clock + @pairing_ttl,
      bound: nil
    }

    %{
      state
      | next: h + 1,
        links: Map.put(state.links, h, link),
        links_seen: state.links_seen ++ [h]
    }
  end

  def next_state(state, _r, {:call, _, :revoke_link, [h]}),
    do: %{state | links: Map.delete(state.links, h)}

  def next_state(state, _r, {:call, _, :exchange, [lh, sh, req, key]}) do
    link = state.links[lh]

    if link == nil or (link.bound != nil and link.bound != key) do
      state
    else
      state = %{state | links: Map.delete(state.links, lh)}

      if link.expires <= state.clock or not subset?(req, link.scopes) do
        state
      else
        session = %{
          scopes: req || link.scopes,
          expires: state.clock + if(key, do: @dpop_ttl, else: @session_ttl),
          key: key
        }

        %{
          state
          | next: sh + 1,
            sessions: Map.put(state.sessions, sh, session),
            sessions_seen: state.sessions_seen ++ [sh]
        }
      end
    end
  end

  def next_state(state, _r, {:call, _, :revoke_client, [h]}), do: drop_sessions(state, [h])

  def next_state(state, _r, {:call, _, :revoke_others, [keep]}),
    do: drop_sessions(state, Map.keys(state.sessions) -- [keep])

  def next_state(state, _r, {:call, _, :connect, [h]}),
    do: %{state | sockets: Map.update(state.sockets, h, 1, &(&1 + 1))}

  def next_state(state, _r, {:call, _, :disconnect, [h]}),
    do: %{state | sockets: Map.update!(state.sockets, h, &(&1 - 1))}

  def next_state(state, _r, {:call, _, :advance, [ms]}), do: %{state | clock: state.clock + ms}

  def next_state(state, _r, {:call, _, :issue_ticket, [t, via, h]}) do
    if via == :token and not valid?(state, h) do
      state
    else
      issued(state, t, h, min(state.clock + @ticket_ttl, state.sessions[h].expires))
    end
  end

  def next_state(state, _r, {:call, _, :issue_local_ticket, [t]}),
    do: issued(state, t, :local, state.clock + @ticket_ttl)

  def next_state(state, _r, {:call, _, :take_ticket, [t]}),
    do: %{state | tickets: Map.delete(state.tickets, t)}

  def next_state(state, _r, {:call, _, :make_proof, [p, h, k, variant, offset]}) do
    proof = %{h: h, k: k, variant: variant, iat: div(state.clock, 1000) + offset, accepted: false}
    %{state | next: p + 1, proofs: Map.put(state.proofs, p, proof)}
  end

  def next_state(state, _r, {:call, _, :send_proof, [p, h]}) do
    case proof_outcome(state, p, h) do
      :ok -> put_in(state.proofs[p].accepted, true)
      _ -> state
    end
  end

  def next_state(state, _r, {:call, _, :prune, []}) do
    now = state.clock
    live = fn map -> map |> Enum.reject(fn {_, v} -> v.expires <= now end) |> Map.new() end

    %{
      state
      | links: live.(state.links),
        sessions: live.(state.sessions),
        tickets: live.(state.tickets)
    }
  end

  def next_state(state, _r, {:call, _, :restart, []}) do
    # Tickets, proof records and socket registrations lived in the process.
    proofs = Map.new(state.proofs, fn {p, proof} -> {p, %{proof | accepted: :forgotten}} end)
    %{state | tickets: %{}, proofs: proofs, sockets: %{}}
  end

  def next_state(state, _r, _call), do: state

  defp subset?(nil, _granted), do: true
  defp subset?(req, granted), do: Enum.all?(req, &(&1 in granted))

  defp issued(state, t, sess, expires) do
    %{
      state
      | next: t + 1,
        tickets: Map.put(state.tickets, t, %{expires: expires, sess: sess}),
        tickets_seen: state.tickets_seen ++ [t]
    }
  end

  defp drop_sessions(state, hs) do
    %{
      state
      | sessions: Map.drop(state.sessions, hs),
        tickets: state.tickets |> Enum.reject(fn {_, t} -> t.sess in hs end) |> Map.new(),
        sockets: Map.drop(state.sockets, hs)
    }
  end

  # What sending proof `p` as session `as` does: the first failing check, in the
  # order `HalC2.Auth.Dpop` makes them, or `:ok`.
  defp proof_outcome(state, p, as) do
    proof = state.proofs[p]
    session = state.sessions[as]
    now = div(state.clock, 1000)

    cond do
      not valid?(state, as) or session.key == nil -> :invalid_proof
      proof.k != session.key -> :key_mismatch
      proof.variant in [:wrong_method, :wrong_url] -> :request_mismatch
      proof.variant == :wrong_ath or proof.h != as -> :token_mismatch
      proof.variant == :forged -> :invalid_proof
      proof.iat > now + 5 or now - proof.iat > 300 -> :time_window
      proof.accepted == true -> :replay
      true -> :ok
    end
  end

  # --- postconditions ---

  def postcondition(_state, {:call, _, :mint_link, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :mint_static, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :advance, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :restart, _}, result), do: result == :ok

  def postcondition(state, {:call, _, :pairing_links, []}, result) do
    expected =
      for {h, l} <- state.links, l.expires > state.clock, do: {h, l.scopes, l.expires}

    result == Enum.sort(expected)
  end

  def postcondition(state, {:call, _, :revoke_link, [h]}, result),
    do: result == Map.has_key?(state.links, h)

  def postcondition(state, {:call, _, :exchange, [lh, _sh, req, key]}, result) do
    link = state.links[lh]

    cond do
      link == nil or (link.bound != nil and link.bound != key) ->
        result == :error

      link.expires <= state.clock ->
        result == :error

      not subset?(req, link.scopes) ->
        result == {:error, :scope_not_granted}

      true ->
        ttl = if key, do: @dpop_ttl, else: @session_ttl
        result == {:ok, div(ttl, 1000), req || link.scopes}
    end
  end

  def postcondition(state, {:call, _, :clients, []}, result) do
    expected =
      for {h, s} <- state.sessions, s.expires > state.clock do
        {h, s.scopes, s.expires, if(s.key, do: "dpop-access-token", else: "bearer-access-token"),
         Map.get(state.sockets, h, 0) > 0}
      end

    result == Enum.sort(expected)
  end

  def postcondition(state, {:call, _, :list_static, []}, result) do
    expected =
      for {h, s} <- state.sessions, s.expires > state.clock do
        {h, s.scopes, s.expires, if(s.key, do: "dpop-access-token", else: "bearer-access-token"),
         false}
      end

    result == Enum.sort(expected)
  end

  def postcondition(state, {:call, _, :revoke_client, [h]}, {result, closed}) do
    exists = Map.has_key?(state.sessions, h)

    result == exists and
      closed == if(exists and Map.get(state.sockets, h, 0) > 0, do: [h], else: [])
  end

  def postcondition(state, {:call, _, :revoke_others, [keep]}, {count, closed}) do
    revoked = Map.keys(state.sessions) -- [keep]

    count == length(revoked) and
      closed == Enum.sort(for h <- revoked, Map.get(state.sockets, h, 0) > 0, do: h)
  end

  def postcondition(_state, {:call, _, :connect, _}, result), do: result == :ok
  def postcondition(_state, {:call, _, :disconnect, _}, result), do: result == :ok

  def postcondition(state, {:call, _, :bearer_request, [h]}, result) do
    if valid?(state, h) and state.sessions[h].key == nil,
      do: result == {:ok, h},
      else: result == {:error, "invalid_credential", nil}
  end

  def postcondition(_state, {:call, _, :bad_credential, [kind]}, result) do
    case kind do
      :none -> result == {:error, "missing_credential", nil}
      :dpop -> result == {:error, "invalid_credential", :invalid_proof}
      _ -> result == {:error, "invalid_credential", nil}
    end
  end

  def postcondition(state, {:call, _, :issue_ticket, [_t, via, h]}, result) do
    if via == :token and not valid?(state, h),
      do: result == :error,
      else: result == {:ok, min(state.clock + @ticket_ttl, state.sessions[h].expires)}
  end

  def postcondition(state, {:call, _, :issue_local_ticket, _}, result),
    do: result == {:ok, state.clock + @ticket_ttl}

  def postcondition(state, {:call, _, :take_ticket, [t]}, result) do
    case state.tickets[t] do
      %{expires: expires, sess: sess} when expires > state.clock -> result == {:ok, sess}
      _ -> result == :error
    end
  end

  def postcondition(state, {:call, _, :ticket_scopes, [t]}, result) do
    case state.tickets[t] do
      %{expires: expires, sess: sess} when expires > state.clock ->
        if sess == :local do
          result == {:ok, Enum.sort(@admin)}
        else
          valid?(state, sess) and result == {:ok, Enum.sort(state.sessions[sess].scopes)}
        end

      _ ->
        result == :error
    end
  end

  def postcondition(_state, {:call, _, :make_proof, _}, result), do: result == :ok

  def postcondition(state, {:call, _, :send_proof, [p, as]}, result) do
    case proof_outcome(state, p, as) do
      :ok -> result == {:ok, as}
      reason -> result == {:error, "invalid_credential", reason}
    end
  end

  def postcondition(state, {:call, _, :prune, []}, {removed, remaining}) do
    now = state.clock
    count = fn map -> Enum.count(map, fn {_, v} -> v.expires <= now end) end
    threshold = div(now, 1000) - 305

    live_proofs =
      Enum.count(state.proofs, fn {_, p} -> p.accepted == true and p.iat >= threshold end)

    removed.pairing == count.(state.links) and removed.sessions == count.(state.sessions) and
      removed.tickets == count.(state.tickets) and
      remaining.pairing == map_size(state.links) - count.(state.links) and
      remaining.sessions == map_size(state.sessions) - count.(state.sessions) and
      remaining.tickets == map_size(state.tickets) - count.(state.tickets) and
      remaining.proofs <= live_proofs
  end

  # --- system under test --------------------------------------------------------

  def mint_link(h, scopes, ttl, key) do
    input =
      %{}
      |> then(&if(scopes, do: Map.put(&1, "scopes", scopes), else: &1))
      |> then(&if(ttl, do: Map.put(&1, "ttlMs", ttl), else: &1))
      |> then(&if(key, do: Map.put(&1, "proofKeyThumbprint", Reg.thumbprint(key)), else: &1))

    {:ok, %{"id" => id, "credential" => cred}} = Auth.create_pairing_link(input)
    register_link(h, id, cred)
  end

  def mint_static(h, admin?) do
    before = link_ids()
    cred = Auth.create_pairing_token(Store.path(), admin: admin?)
    [id] = link_ids() -- before
    register_link(h, id, cred)
  end

  defp register_link(h, id, cred) do
    Reg.put({:link, h}, {id, cred})
    Reg.put({:id, id}, {:link, h})
    :ok
  end

  defp link_ids, do: for(l <- Auth.pairing_links(), do: l["id"])

  def pairing_links do
    Auth.pairing_links()
    |> Enum.map(fn l ->
      {:link, h} = Reg.get({:id, l["id"]})
      {h, l["scopes"], ms(l["expiresAt"])}
    end)
    |> Enum.sort()
  end

  def revoke_link(h) do
    {id, _} = Reg.get({:link, h})
    Auth.revoke_pairing_link(id)
  end

  def exchange(lh, sh, req, key) do
    {_, cred} = Reg.get({:link, lh})

    client =
      %{label: "prop"}
      |> then(&if(req, do: Map.put(&1, :scopes, req), else: &1))
      |> then(&if(key, do: Map.put(&1, :proof_jkt, Reg.thumbprint(key)), else: &1))

    case Auth.exchange(cred, client) do
      {:ok, access, secs, scopes} ->
        {:ok, %{id: id}} = Auth.session(access)
        Reg.put({:session, sh}, {id, access})
        Reg.put({:id, id}, {:session, sh})
        {:ok, secs, scopes}

      other ->
        other
    end
  end

  def clients, do: summarize(Auth.clients(), true)
  def list_static, do: summarize(Auth.list_sessions(Store.path()), false)

  defp summarize(rows, connected?) do
    rows
    |> Enum.map(fn row ->
      {:session, h} = Reg.get({:id, row["sessionId"]})
      {h, row["scopes"], ms(row["expiresAt"]), row["method"], connected? and row["connected"]}
    end)
    |> Enum.sort()
  end

  defp ms(iso) do
    {:ok, at, 0} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at, :millisecond)
  end

  def revoke_client(h) do
    {id, _} = Reg.get({:session, h})
    result = Auth.revoke_client(id)
    {result, closed_sockets()}
  end

  def revoke_others(keep) do
    {id, _} = Reg.get({:session, keep})
    count = Auth.revoke_other_clients(id)
    {count, closed_sockets()}
  end

  def bearer_request(h) do
    {_, access} = Reg.get({:session, h})
    request("Bearer " <> access, nil)
  end

  def bad_credential(:none), do: request(nil, nil)
  def bad_credential(:bearer), do: request("Bearer nope", nil)
  def bad_credential(:dpop), do: request("DPoP nope", nil)
  def bad_credential(:basic), do: request("Basic eDp5", nil)

  def make_proof(p, h, k, variant, offset) do
    {_, access} = Reg.get({:session, h})
    Reg.put({:proof, p}, Reg.proof(k, access, "jti-#{p}", offset, variant, "GET", @url))
    :ok
  end

  def send_proof(p, as) do
    {_, access} = Reg.get({:session, as})
    request("DPoP " <> access, Reg.get({:proof, p}))
  end

  defp request(authorization, proof) do
    conn = Plug.Test.conn(:get, @url)

    conn =
      if authorization,
        do: Plug.Conn.put_req_header(conn, "authorization", authorization),
        else: conn

    conn = if proof, do: Plug.Conn.put_req_header(conn, "dpop", proof), else: conn

    case Auth.authenticate(conn) do
      {:ok, %{id: id}} ->
        {:session, h} = Reg.get({:id, id})
        {:ok, h}

      other ->
        other
    end
  end

  def issue_ticket(t, via, h) do
    {id, access} = Reg.get({:session, h})

    result =
      case via do
        :token -> Auth.issue_ticket(access)
        :session -> Auth.issue_ticket(%{id: id, expires_at: session_expiry(access)})
      end

    case result do
      {:ok, ticket, expires} ->
        Reg.put({:ticket, t}, ticket)
        {:ok, expires}

      :error ->
        :error
    end
  end

  def issue_local_ticket(t) do
    {:ok, ticket, expires} = Auth.issue_ticket(Auth.local_session())
    Reg.put({:ticket, t}, ticket)
    {:ok, expires}
  end

  # What `request_session/1` would have found for the session.
  defp session_expiry(access) do
    {:ok, %{expires_at: expires}} = Auth.session(access)
    expires
  end

  def take_ticket(t) do
    case Auth.take_ticket(Reg.get({:ticket, t})) do
      {:ok, nil} ->
        {:ok, :local}

      {:ok, id} ->
        {:session, h} = Reg.get({:id, id})
        {:ok, h}

      :error ->
        :error
    end
  end

  def ticket_scopes(t) do
    with {:ok, scopes} <- Auth.ticket_scopes(Reg.get({:ticket, t})), do: {:ok, Enum.sort(scopes)}
  end

  def advance(ms), do: Reg.advance(ms)

  def prune do
    removed = Auth.prune()

    remaining = %{
      pairing: count("auth_pairing"),
      sessions: count("auth_sessions"),
      tickets: :ets.info(Auth.Tickets, :size),
      proofs: :ets.info(Auth.Dpop.Proofs, :size)
    }

    {removed, remaining}
  end

  defp count(table) do
    {:ok, db} = Exqlite.Sqlite3.open(Store.path())
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT count(*) FROM #{table}")
    {:ok, [[n]]} = Exqlite.Sqlite3.fetch_all(db, stmt)
    Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    n
  end

  def restart do
    stop_sockets()
    HalC2.Prop.restart_service(Auth)
  end

  # Sockets are processes that register with Auth, forward the revocation they are
  # sent, and answer a barrier so a test can read what they received.
  def connect(h) do
    {id, _} = Reg.get({:session, h})
    parent = self()

    pid =
      spawn(fn ->
        Auth.connected(id)
        send(parent, {:connected, self()})
        socket_loop(parent, h)
      end)

    receive do
      {:connected, ^pid} -> :ok
    end

    Reg.put({:sockets, h}, Reg.get({:sockets, h}, []) ++ [pid])
    :ok
  end

  defp socket_loop(parent, h) do
    receive do
      {:hal_c2_session_revoked, _} -> send(parent, {:closed, h})
      {:flush, ref} -> send(parent, {:flushed, ref}) && socket_loop(parent, h)
      :stop -> :ok
    end
  end

  def disconnect(h) do
    [pid | rest] = Reg.get({:sockets, h})
    Reg.put({:sockets, h}, rest)
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    # Auth sees the exit through its own monitor; a round trip to it comes after.
    _ = :sys.get_state(Auth)
    :ok
  end

  defp all_sockets,
    do: for({{:sockets, h}, pids} <- :ets.tab2list(:auth_prop_handles), pid <- pids, do: {h, pid})

  # Which sessions' sockets were told to close, once every socket has handled its mail.
  defp closed_sockets do
    sockets = all_sockets()

    for {_, pid} <- sockets do
      ref = make_ref()
      monitor = Process.monitor(pid)
      send(pid, {:flush, ref})

      receive do
        {:flushed, ^ref} -> Process.demonitor(monitor, [:flush])
        {:DOWN, ^monitor, _, _, _} -> :ok
      end
    end

    closed = drain_closed([])

    for {h, _} <- sockets do
      if h in closed, do: Reg.put({:sockets, h}, [])
    end

    Enum.sort(Enum.uniq(closed))
  end

  defp drain_closed(acc) do
    receive do
      {:closed, h} -> drain_closed([h | acc])
    after
      0 -> acc
    end
  end

  defp stop_sockets do
    for {_, pid} <- all_sockets(), do: Process.exit(pid, :kill)
    for {{:sockets, h}, _} <- :ets.tab2list(:auth_prop_handles), do: Reg.put({:sockets, h}, [])
    :ok
  end
end

defmodule HalC2.AuthConcurrentPropTest do
  @moduledoc """
  Racing callers against `HalC2.Auth`. A fixed set of pairing tokens, tickets and
  sessions is made first; the commands then redeem, take, look up and revoke them from
  two processes at once, and PropEr looks for an order of the calls that explains every
  result. A token or ticket handed to two racing callers cannot be explained.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Auth
  alias HalC2.Prop.Auth, as: Reg
  alias HalC2.Store

  @moduletag timeout: :infinity

  # Handles: pairing tokens 1-3, sessions 4-5, tickets 6-9 (6 and 7 are session 4's,
  # 8 is session 5's, 9 is the MC's own).
  @links [1, 2, 3]
  @sessions [4, 5]
  @tickets [6, 7, 8, 9]
  @owners %{6 => 4, 7 => 4, 8 => 5, 9 => :local}

  property "a token or ticket is used once however many callers race",
    numtests: HalC2.Prop.numtests(100),
    max_size: 12 do
    forall cmds <- parallel_commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("auth-concurrent")
        HalC2.Prop.start_services([{Store, path: Store.home_path()}, Auth])
        Reg.setup()
        seed()
        {history, state, result} = run_parallel_commands(__MODULE__, cmds)
        Reg.teardown()
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp seed do
    for h <- @links do
      {:ok, %{"id" => id, "credential" => cred}} = Auth.create_pairing_link(%{})
      Reg.put({:link, h}, {id, cred})
    end

    for h <- @sessions do
      {:ok, %{"credential" => cred}} = Auth.create_pairing_link(%{})
      {:ok, access, _, _} = Auth.exchange(cred)
      {:ok, %{id: id}} = Auth.session(access)
      Reg.put({:session, h}, {id, access})
    end

    for {t, owner} <- @owners do
      {:ok, ticket, _} =
        case owner do
          :local -> Auth.issue_ticket(Auth.local_session())
          h -> Auth.issue_ticket(elem(Reg.get({:session, h}), 1))
        end

      Reg.put({:ticket, t}, ticket)
    end
  end

  def initial_state, do: %{links: @links, sessions: @sessions, tickets: @tickets}

  def command(_state) do
    frequency([
      {5, {:call, __MODULE__, :redeem, [oneof(@links)]}},
      {5, {:call, __MODULE__, :take_ticket, [oneof(@tickets)]}},
      {2, {:call, __MODULE__, :revoke, [oneof(@sessions)]}},
      {2, {:call, __MODULE__, :lookup, [oneof(@sessions)]}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _r, {:call, _, :redeem, [h]}), do: %{state | links: state.links -- [h]}

  def next_state(state, _r, {:call, _, :take_ticket, [t]}),
    do: %{state | tickets: state.tickets -- [t]}

  def next_state(state, _r, {:call, _, :revoke, [h]}) do
    %{
      state
      | sessions: state.sessions -- [h],
        tickets: Enum.reject(state.tickets, &(@owners[&1] == h))
    }
  end

  def next_state(state, _r, _call), do: state

  def postcondition(state, {:call, _, :redeem, [h]}, result),
    do: result == h in state.links

  def postcondition(state, {:call, _, :take_ticket, [t]}, result),
    do: result == t in state.tickets

  def postcondition(state, {:call, _, :revoke, [h]}, result),
    do: result == h in state.sessions

  def postcondition(state, {:call, _, :lookup, [h]}, result),
    do: result == h in state.sessions

  # --- system under test ---

  def redeem(h) do
    {_, cred} = Reg.get({:link, h})
    match?({:ok, _, _, _}, Auth.exchange(cred))
  end

  def take_ticket(t), do: match?({:ok, _}, Auth.take_ticket(Reg.get({:ticket, t})))

  def revoke(h) do
    {id, _} = Reg.get({:session, h})
    Auth.revoke_client(id)
  end

  def lookup(h) do
    {_, access} = Reg.get({:session, h})
    match?({:ok, _}, Auth.session(access))
  end
end
