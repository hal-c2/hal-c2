defmodule HalC2.Cluster do
  @moduledoc """
  One person's machines as one cluster: Erlang distribution over mutual TLS 1.3, with no
  node names, cookies or port mapper for the user to know about.

  Each node has its own self-signed certificate (`<data>/cluster/node.pem`), made on
  first start and never changed, for `<environment id>.hal-c2`; the node is
  `hal_c2@<environment id>.hal-c2`. A handshake succeeds only when the peer's
  certificate is a member's (`verify_peer/3` checks its fingerprint against the pins
  taken from `members.json`), so the cookie is a constant and no CA is needed, and a
  change of membership applies from the next handshake.

  The VM boots with `-proto_dist inet_tls -ssl_dist_optfile PATH -setcookie hal_c2`
  (rel/env.sh.eex, `mise run node`) but unnamed. This process writes the TLS options to
  that path and starts distribution before anything reads `node()`, on the cluster
  port (4370) or any free one when that is taken. `HalC2.Cluster.Epmd` stands in for
  EPMD and `HalC2.Cluster.Discovery` finds where members are.

  A machine joins with a pairing link from any member (`join/1`): it trades the link
  for an `access:write` session, presents its fingerprint, and the member admits it
  (`admit/1`), answering with every member. Members exchange the list whenever they
  connect, entry by entry by timestamp (`merge/3`), so a machine that joins one member
  is admitted by all of them, and a removal (`remove/1`) reaches members that were
  away. Timestamps come from `stamp/1`, so they order changes even when the members'
  clocks disagree.
  """

  use GenServer
  require Logger

  alias HalC2.Cluster.Epmd

  @table __MODULE__
  @dist_port 4370
  @cookie :hal_c2
  @domain "hal-c2"
  # The certificate is pinned, not chained: it must outlive the machine.
  @valid_days 36_500
  @backdate_seconds 300
  @join_timeout 15_000
  # Files of the CA-based cluster this replaced.
  @obsolete ~w(ca.pem ca.key vm.args address revoked ssl_dist.conf)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The port a node listens on for members when it is free."
  def dist_port, do: Application.get_env(:hal_c2, :cluster_port, @dist_port)

  @spec dir(String.t()) :: String.t()
  def dir(data_dir), do: Path.join(data_dir, "cluster")

  @doc "The host a member's node is named after; `HalC2.Cluster.Epmd` maps it to an address."
  def host(id), do: "#{id}.#{@domain}"

  @doc "The node name of the member with environment id `id`."
  def node_name(id), do: :"hal_c2@#{host(id)}"

  @doc """
  This machine and the other members: `%{"clustered" => true, "id", "node", "addresses",
  "members" => [%{"id", "label", "addresses", "connected"}]}`, or `%{"clustered" =>
  false, "reason"}` when the node was not started for clustering.
  """
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "The other members, `{id, addresses}`, for `HalC2.Cluster.Discovery`."
  def peers, do: GenServer.call(__MODULE__, :peers)

  @doc """
  Admits the machine described by `entry` (`id`, `fingerprint`, `label`, `addresses`), as
  asked through `POST /api/cluster/members`. Returns this node's id, cluster port and
  member list for the new machine.
  """
  def admit(entry), do: GenServer.call(__MODULE__, {:admit, entry})

  @doc "Stops admitting the member `id`, here and on every member, and disconnects it."
  def remove(id), do: GenServer.call(__MODULE__, {:remove, id})

  @doc """
  Joins the cluster of the machine a pairing link is from. The link must grant
  `access:write` (an admin link from Settings → Connections, or `hal_c2.cluster invite`).
  Waits up to 15 s to connect and returns `status/0`.
  """
  def join(link) do
    with {:ok, entry} <- GenServer.call(__MODULE__, :entry),
         {:ok, base, token} <- parse_link(link),
         {:ok, access} <- exchange(base, token, entry["label"]),
         {:ok, %{"id" => inviter, "port" => port, "members" => members}}
         when is_binary(inviter) and is_map(members) <- ask_admission(base, access, entry) do
      :ok = :net_kernel.monitor_nodes(true)
      address = "#{URI.parse(base).host}:#{port}"
      :ok = GenServer.call(__MODULE__, {:joined, inviter, members, address})
      HalC2.Cluster.Discovery.poll()
      await_nodeup(node_name(inviter))
      :net_kernel.monitor_nodes(false)
      flush_node_events()
      {:ok, status()}
    else
      {:ok, _unexpected} -> {:error, :unexpected_answer}
      error -> error
    end
  end

  @doc """
  A one-time pairing link that grants `access:write`, for another machine to `join/1`
  with within five minutes: `%{"link", "expiresAt", "localOnly"}`. It points at
  `"baseUrl"` when given, else with `"tailscale" => true` at this node's Tailscale Serve
  name (published if need be), else at the address the node listens on. `localOnly`
  says no other machine can reach the link.
  """
  def invite(input \\ %{}) do
    with {:ok, base} <- invite_base(input),
         {:ok, %{"credential" => token, "expiresAt" => expires}} <-
           HalC2.Auth.create_pairing_link(%{
             "scopes" => ["access:write"],
             "label" => "Cluster invite"
           }) do
      host = URI.parse(base).host

      {:ok,
       %{
         "link" => "#{String.trim_trailing(base, "/")}/?token=#{token}",
         "expiresAt" => expires,
         "localOnly" => host in ["127.0.0.1", "localhost", "::1", "[::1]"]
       }}
    end
  end

  defp invite_base(%{"baseUrl" => base}) when is_binary(base) and base != "", do: {:ok, base}

  defp invite_base(%{"tailscale" => true}) do
    case HalC2.TailscaleServe.publish(HalC2.Web.port(), HalC2.TailscaleServe.default_port()) do
      {:ok, base} -> {:ok, base}
      {:error, message} -> {:error, {:tailscale, message}}
    end
  end

  # A node listening on every interface is reached at the address it reports to members.
  defp invite_base(_input) do
    wildcard? = Application.get_env(:hal_c2, :host, "127.0.0.1") in ["0.0.0.0", "::"]

    with true <- wildcard?,
         %{"clustered" => true, "addresses" => [address | _]} <- status(),
         [ip | _] <- String.split(address, ":"),
         false <- String.starts_with?(ip, "127.") do
      {:ok, "http://#{ip}:#{HalC2.Web.port()}"}
    else
      _ -> {:ok, HalC2.Web.base_url()}
    end
  end

  @doc "What went wrong with a cluster request, in words for the user."
  def describe(:not_booted_for_clustering),
    do: "The node was not started for clustering; start it as the app or service does."

  def describe(:link_lacks_access),
    do: "The pairing link cannot add machines to a cluster; make a cluster invite instead."

  def describe(:link_invalid), do: "The pairing link was used already or has expired."
  def describe(:invalid_link), do: "That is not a pairing link."
  def describe(:cannot_remove_self), do: "A machine cannot remove itself from its cluster."
  def describe(:not_a_member), do: "That machine is not a member of this cluster."
  def describe(:invalid_member), do: "The joining machine sent an invalid description."
  def describe({:refused, reason}), do: "The other machine refused: #{describe(reason)}"

  def describe({:unreachable, _}),
    do: "The machine the link is from cannot be reached from this one."

  def describe({:tailscale, message}), do: message
  def describe(reason) when is_binary(reason), do: describe_string(reason)
  def describe(reason), do: to_string(reason)

  # Reasons that crossed the wire as strings.
  @reasons ~w(not_booted_for_clustering link_lacks_access link_invalid invalid_link
    cannot_remove_self not_a_member invalid_member)a
  defp describe_string(reason) do
    case Enum.find(@reasons, &(Atom.to_string(&1) == reason)) do
      nil -> reason
      atom -> describe(atom)
    end
  end

  @doc "A cluster error's reason as the `ClusterError` contract carries it."
  def reason({:refused, reason}), do: reason(reason)
  def reason({:unreachable, _}), do: "unreachable"
  def reason({:tailscale, _}), do: "tailscale"
  def reason(reason), do: to_string(reason)

  @doc """
  Merges member tables: for each id, the latest `admittedAt` and `removedAt`, and the
  fingerprint, label and addresses of the entry updated last. Entries for `own_id` in
  `incoming` are ignored; only this machine speaks for itself.
  """
  def merge(local, incoming, own_id) do
    Enum.reduce(incoming, local, fn
      {^own_id, _}, acc ->
        acc

      {id, entry}, acc ->
        case sanitize(entry) do
          nil -> acc
          entry -> Map.update(acc, id, entry, &merge_entry(&1, entry))
        end
    end)
  end

  defp merge_entry(ours, theirs) do
    # Same-millisecond updates fall back to comparing the entries, so both sides pick one.
    newer = if {theirs["updatedAt"], theirs} > {ours["updatedAt"], ours}, do: theirs, else: ours

    Map.merge(newer, %{
      "admittedAt" => max(ours["admittedAt"], theirs["admittedAt"]),
      "removedAt" => max_time(ours["removedAt"], theirs["removedAt"])
    })
  end

  defp max_time(nil, b), do: b
  defp max_time(a, nil), do: a
  defp max_time(a, b), do: max(a, b)

  defp sanitize(%{"fingerprint" => fp, "admittedAt" => admitted, "updatedAt" => updated} = entry)
       when is_binary(fp) and is_integer(admitted) and is_integer(updated) do
    removed = entry["removedAt"]
    addresses = entry["addresses"]

    if is_integer(removed) or is_nil(removed) do
      %{
        "fingerprint" => fp,
        "label" => if(is_binary(entry["label"]), do: entry["label"]),
        "addresses" => if(is_list(addresses), do: Enum.filter(addresses, &is_binary/1), else: []),
        "admittedAt" => admitted,
        "removedAt" => removed,
        "updatedAt" => updated
      }
    end
  end

  defp sanitize(_entry), do: nil

  @doc """
  The time to record a change to `members` at: now, or just after the latest time the
  table holds when a member's clock ran ahead. A removal made after seeing an admission
  then always outranks it, however far apart the members' clocks are.
  """
  def stamp(members) do
    seen =
      for {_id, entry} <- members,
          time <- [entry["admittedAt"], entry["removedAt"], entry["updatedAt"]],
          is_integer(time),
          reduce: 0,
          do: (latest -> max(latest, time))

    max(System.os_time(:millisecond), seen + 1)
  end

  @doc "Whether a member table entry is a current member."
  def member?(%{"admittedAt" => admitted, "removedAt" => removed}),
    do: removed == nil or admitted > removed

  def member?(_entry), do: false

  @doc false
  # The distribution handshake's `verify_fun` (see `ssl_dist_conf/1`): a certificate
  # passes only if a member's fingerprint is pinned for it. Members' certificates are
  # self-signed, so the path check reports them as a self-signed or unknown issuer.
  def verify_peer(cert, {:bad_cert, reason}, state)
      when reason in [:selfsigned_peer, :unknown_ca],
      do: check_pin(cert, state)

  def verify_peer(_cert, {:bad_cert, reason}, _state), do: {:fail, reason}
  def verify_peer(_cert, {:extension, _}, state), do: {:unknown, state}
  def verify_peer(_cert, :valid, state), do: {:valid, state}
  def verify_peer(cert, :valid_peer, state), do: check_pin(cert, state)

  defp check_pin(cert, state) do
    if :ets.member(@table, {:pin, fingerprint(cert)}),
      do: {:valid, state},
      else: {:fail, :not_a_member}
  rescue
    ArgumentError -> {:fail, :not_a_member}
  end

  @doc "The SHA-256 of a certificate's DER, as members record it."
  def fingerprint(cert),
    do: Base.encode16(:crypto.hash(:sha256, X509.Certificate.to_der(cert)), case: :lower)

  # --- server ------------------------------------------------------------------

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    dir = dir(HalC2.Paths.data_dir())
    id = HalC2.Environment.id()
    fingerprint = identity!(dir, id)
    state = %{dir: dir, id: id, fingerprint: fingerprint, members: load(dir), off: nil}
    started = start_distribution(dir, id)
    forget_boot_flags()

    case started do
      :ok ->
        :ok = :net_kernel.monitor_nodes(true)
        {:ok, state |> refresh_own() |> commit()}

      {:off, reason} ->
        {:ok, %{state | off: reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, %{off: reason} = state) when reason != nil,
    do: {:reply, %{"clustered" => false, "reason" => to_string(reason)}, state}

  def handle_call(:status, _from, state) do
    connected = Node.list()

    members =
      for {id, entry} <- state.members, id != state.id, member?(entry) do
        %{
          "id" => id,
          "label" => entry["label"] || id,
          "addresses" => entry["addresses"] || [],
          "connected" => node_name(id) in connected
        }
      end

    {:reply,
     %{
       "clustered" => true,
       "id" => state.id,
       "label" => state.members[state.id]["label"],
       "node" => Atom.to_string(node()),
       "addresses" => state.members[state.id]["addresses"],
       "members" => Enum.sort_by(members, &{&1["label"], &1["id"]})
     }, state}
  end

  def handle_call(:peers, _from, %{off: reason} = state) when reason != nil,
    do: {:reply, [], state}

  def handle_call(:peers, _from, state) do
    {:reply,
     for(
       {id, entry} <- state.members,
       id != state.id,
       member?(entry),
       do: {id, entry["addresses"]}
     ), state}
  end

  def handle_call(_request, _from, %{off: reason} = state) when reason != nil,
    do: {:reply, {:error, reason}, state}

  def handle_call(:entry, _from, state) do
    own = state.members[state.id]

    {:reply,
     {:ok,
      %{
        "id" => state.id,
        "fingerprint" => own["fingerprint"],
        "label" => own["label"],
        "addresses" => own["addresses"]
      }}, state}
  end

  def handle_call({:admit, entry}, _from, state) do
    with %{"id" => id, "fingerprint" => fp} when is_binary(id) and is_binary(fp) <- entry,
         true <- id != state.id and Regex.match?(~r/^[0-9a-z][0-9a-z-]{0,62}$/, id),
         true <- Regex.match?(~r/^[0-9a-f]{64}$/, fp) do
      now = stamp(state.members)

      admitted = %{
        "fingerprint" => fp,
        "label" => entry["label"],
        "addresses" => entry["addresses"],
        "admittedAt" => now,
        "removedAt" => nil,
        "updatedAt" => now
      }

      state = merge_in(state, %{id => admitted})

      {:reply,
       {:ok, %{"id" => state.id, "port" => Epmd.listen_port(), "members" => state.members}},
       state}
    else
      _ -> {:reply, {:error, :invalid_member}, state}
    end
  end

  def handle_call({:joined, inviter, members, address}, _from, state) do
    # The link's host reached the inviter, so its cluster port there is worth a try first.
    members =
      Map.update(members, inviter, %{}, fn
        %{"addresses" => addresses} = entry when is_list(addresses) ->
          %{entry | "addresses" => Enum.uniq([address | addresses])}

        entry ->
          entry
      end)

    {:reply, :ok, merge_in(state, members)}
  end

  def handle_call({:remove, id}, _from, state) do
    entry = state.members[id]

    cond do
      id == state.id ->
        {:reply, {:error, :cannot_remove_self}, state}

      not member?(entry) ->
        {:reply, {:error, :not_a_member}, state}

      true ->
        now = stamp(state.members)
        removed = %{entry | "removedAt" => now, "updatedAt" => now}
        {:reply, :ok, merge_in(state, %{id => removed})}
    end
  end

  @impl true
  def handle_cast({:merge, incoming}, %{off: nil} = state) when is_map(incoming),
    do: {:noreply, merge_in(state, incoming)}

  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info({:nodeup, node}, state) do
    state = refresh_own(state) |> commit()
    GenServer.cast({__MODULE__, node}, {:merge, state.members})
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # --- members -----------------------------------------------------------------

  defp merge_in(state, incoming) do
    merged = merge(state.members, incoming, state.id)

    if merged == state.members do
      state
    else
      state = commit(%{state | members: merged})
      for node <- Node.list(), do: GenServer.cast({__MODULE__, node}, {:merge, merged})
      state
    end
  end

  # Saves the table, pins its members and cuts off anyone no longer one.
  defp commit(state) do
    save(state.dir, state.members)
    members = for {id, entry} <- state.members, member?(entry), into: %{}, do: {id, entry}
    pins = for {_id, entry} <- members, do: {{:pin, entry["fingerprint"]}, true}
    stale = :ets.match_object(@table, {{:pin, :_}, :_}) -- pins
    :ets.insert(@table, pins)
    for pin <- stale, do: :ets.delete_object(@table, pin)

    for node <- Node.list(), not Map.has_key?(members, id_of(node)), do: Node.disconnect(node)

    state
  end

  defp id_of(node) do
    case node |> Atom.to_string() |> String.split("@") do
      ["hal_c2", host] -> String.replace_suffix(host, ".#{@domain}", "")
      _ -> nil
    end
  end

  # This machine's entry, updated only when something in it changed, so gossip settles.
  defp refresh_own(state) do
    now = stamp(state.members)
    current = state.members[state.id]

    fresh = %{
      "fingerprint" => state.fingerprint,
      "label" => HalC2.Environment.label(),
      "addresses" => own_addresses()
    }

    own =
      cond do
        current == nil ->
          Map.merge(fresh, %{"admittedAt" => now, "removedAt" => nil, "updatedAt" => now})

        Map.take(current, Map.keys(fresh)) == fresh ->
          current

        true ->
          Map.merge(current, fresh) |> Map.put("updatedAt", now)
      end

    %{state | members: Map.put(state.members, state.id, own)}
  end

  # Where members can reach this node: the IPv4 address of every interface that is up,
  # loopback last, or only the one it listens on.
  defp own_addresses do
    port = Epmd.listen_port()

    ips =
      case Application.get_env(:hal_c2, :cluster_listen) do
        nil ->
          {:ok, interfaces} = :inet.getifaddrs()

          ips =
            for {_name, opts} <- interfaces,
                :up in Keyword.get(opts, :flags, []),
                {:addr, {a, b, _, _} = ip} <- opts,
                {a, b} != {169, 254},
                uniq: true,
                do: ip

          {loopback, other} = Enum.split_with(ips, &match?({127, _, _, _}, &1))
          Enum.map(other ++ loopback, &List.to_string(:inet.ntoa(&1)))

        ip ->
          [ip]
      end

    for ip <- ips, do: "#{ip}:#{port}"
  end

  defp load(dir) do
    with {:ok, json} <- File.read(Path.join(dir, "members.json")),
         {:ok, %{} = members} <- JSON.decode(json) do
      for {id, entry} <- members, entry = sanitize(entry), into: %{}, do: {id, entry}
    else
      _ -> %{}
    end
  end

  defp save(dir, members) do
    path = Path.join(dir, "members.json")
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(members))
    File.rename!(tmp, path)
  end

  # --- identity and distribution -----------------------------------------------

  # This machine's certificate, made on first start. One from the CA-based cluster
  # (issued by a CA, named after an address) is replaced along with that cluster's files.
  defp identity!(dir, id) do
    File.mkdir_p!(dir)
    host = host(id)

    cert =
      with {:ok, pem} <- File.read(Path.join(dir, "node.pem")),
           {:ok, cert} <- X509.Certificate.from_pem(pem),
           true <- X509.Certificate.subject(cert, "CN") == [host],
           true <- X509.Certificate.issuer(cert) == X509.Certificate.subject(cert),
           true <- File.exists?(Path.join(dir, "node.key")) do
        cert
      else
        _ -> create_identity(dir, host)
      end

    fingerprint(cert)
  end

  defp create_identity(dir, host) do
    for name <- @obsolete, do: File.rm(Path.join(dir, name))
    key = X509.PrivateKey.new_ec(:secp256r1)

    cert =
      X509.Certificate.self_signed(key, "/CN=#{host}",
        template: :server,
        validity: X509.Certificate.Validity.days_from_now(@valid_days, @backdate_seconds),
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name([host])]
      )

    write(dir, "node.key", X509.PrivateKey.to_pem(key), 0o600)
    write(dir, "node.pem", X509.Certificate.to_pem(cert), 0o644)
    cert
  end

  defp start_distribution(dir, id) do
    name = node_name(id)

    cond do
      # This process restarted; distribution outlives it.
      node() == name ->
        :ok

      Node.alive?() ->
        {:off, :not_booted_for_clustering}

      true ->
        with {:ok, [[~c"inet_tls"]]} <- :init.get_argument(:proto_dist),
             {:ok, [[optfile]]} <- :init.get_argument(:ssl_dist_optfile) do
          File.mkdir_p!(Path.dirname(optfile))
          File.write!(optfile, ssl_dist_conf(dir))
          Application.put_env(:kernel, :epmd_module, Epmd)

          with ip when is_binary(ip) <- Application.get_env(:hal_c2, :cluster_listen),
               {:ok, ip} <- :inet.parse_address(to_charlist(ip)),
               do: Application.put_env(:kernel, :inet_dist_use_interface, ip)

          if listen(name, dist_port()) or listen(name, 0) do
            Node.set_cookie(@cookie)
            :ok
          else
            {:off, :distribution_failed}
          end
        else
          _ -> {:off, :not_booted_for_clustering}
        end
    end
  end

  # The boot flags arrive in ELIXIR_ERL_OPTIONS, which programs the node starts (an
  # agent's `mix test`) would inherit and boot with.
  defp forget_boot_flags do
    with options when is_binary(options) <- System.get_env("ELIXIR_ERL_OPTIONS") do
      case Regex.replace(
             ~r/\s*-(proto_dist inet_tls|ssl_dist_optfile \S+|setcookie hal_c2)\b/,
             options,
             ""
           ) do
        "" -> System.delete_env("ELIXIR_ERL_OPTIONS")
        rest -> System.put_env("ELIXIR_ERL_OPTIONS", rest)
      end
    end
  end

  defp listen(name, port) do
    Epmd.put_listen_port(port)

    case :net_kernel.start(name, %{name_domain: :longnames}) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("Cluster: could not listen on port #{port}: #{inspect(reason)}")
        false
    end
  end

  # file:consult/1 format: plain terms only, no function calls (an external fun is a term).
  # The CA file is the node's own certificate: members' certificates are pinned instead.
  defp ssl_dist_conf(dir) do
    opts =
      [
        certfile: to_charlist(Path.join(dir, "node.pem")),
        keyfile: to_charlist(Path.join(dir, "node.key")),
        cacertfile: to_charlist(Path.join(dir, "node.pem")),
        verify: :verify_peer,
        verify_fun: {&__MODULE__.verify_peer/3, []},
        versions: [:"tlsv1.3"]
      ]

    conf = [server: opts ++ [fail_if_no_peer_cert: true], client: opts]
    :io_lib.format(~c"~p.~n", [conf]) |> IO.iodata_to_binary()
  end

  defp write(dir, name, contents, mode) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    File.chmod!(path, mode)
  end

  # --- joining -----------------------------------------------------------------

  defp parse_link(link) do
    uri = URI.parse(String.trim(link))
    params = Map.merge(URI.decode_query(uri.fragment || ""), URI.decode_query(uri.query || ""))

    case params do
      %{"token" => token} when uri.scheme in ["http", "https"] and is_binary(uri.host) ->
        {:ok, "#{uri.scheme}://#{uri.authority}", token}

      _ ->
        {:error, :invalid_link}
    end
  end

  defp exchange(base, token, label) do
    form =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
        "subject_token" => token,
        "scope" => "access:write",
        "client_label" => "Cluster: #{label}"
      })

    case request(base <> "/oauth/token", nil, "application/x-www-form-urlencoded", form) do
      {:ok, 200, %{"access_token" => access}} -> {:ok, access}
      {:ok, 400, %{"error" => "invalid_scope"}} -> {:error, :link_lacks_access}
      {:ok, _, _} -> {:error, :link_invalid}
      error -> error
    end
  end

  defp ask_admission(base, access, entry) do
    case request(base <> "/api/cluster/members", access, "application/json", JSON.encode!(entry)) do
      {:ok, 200, answer} -> {:ok, answer}
      {:ok, 409, %{"reason" => reason}} -> {:error, {:refused, reason}}
      {:ok, status, _} -> {:error, {:refused, status}}
      error -> error
    end
  end

  defp request(url, bearer, type, body) do
    headers = if bearer, do: [{~c"authorization", ~c"Bearer #{bearer}"}], else: []

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(
           :post,
           {to_charlist(url), headers, to_charlist(type), body},
           [timeout: 15_000, ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} ->
        case JSON.decode(body) do
          {:ok, decoded} -> {:ok, status, decoded}
          {:error, _} -> {:ok, status, nil}
        end

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  defp await_nodeup(node) do
    node in Node.list() or
      receive do
        {:nodeup, ^node} -> true
      after
        @join_timeout -> node in Node.list()
      end
  end

  defp flush_node_events do
    receive do
      {event, _node} when event in [:nodeup, :nodedown] -> flush_node_events()
    after
      0 -> :ok
    end
  end
end
