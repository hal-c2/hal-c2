defmodule HalC2.Links do
  @moduledoc """
  Environments this node reaches without clustering with them: other nodes the user
  paired this one with. A link keeps the access token its pairing gave and one
  websocket (`HalC2.Links.Connection`) that forwards client RPCs and subscriptions,
  so a client that only talks to this node reaches the linked environment and the
  other members of its cluster too (`HalC2.Web.Socket`). `route/1` says where an
  environment id is served: this node, a cluster member, or a link. The other side
  checks the link token's scopes; this node widens nothing.

  Links persist in the `environment-links` secret. Subscribers get
  `{:hal_c2_links, links}` with the whole list (`list/0`) whenever a link is added,
  removed, goes on- or offline, or fails in a new way.

  A subscriber can also ask for the linked environments' sidebars (`subscribe_rows/1`).
  While one does, each link follows its environment's `shell` and keeps its nodes and
  rows (`HalC2.Links.Rows`); such subscribers also get `{:hal_c2_link_rows, id, change}`
  for each change, with `change` as `HalC2.Shell` notifies its own. When a link drops,
  its rows stay and its nodes go offline; when the last such subscriber leaves, the
  links stop following and forget the rows.
  """

  use GenServer

  alias HalC2.Connect.Secrets
  alias HalC2.Links.{Connection, Rows}

  @secret "environment-links"
  @http_timeout 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Every link as `%{"environment" => descriptor, "origin", "online"}`, plus
  `"problem"` while it is offline for a known reason: `"unreachable"`, or `"refused"`
  when the environment no longer accepts its token (pair it again).
  """
  @spec list() :: [map]
  def list do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :list), else: []
  end

  @spec subscribe(pid) :: :ok
  def subscribe(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:subscribe, pid}), else: :ok
  end

  @doc """
  Subscribes `pid` as `subscribe/1` does, and to the linked environments' rows too.
  Returns `list/0` with each link's `"nodes"` and `"rows"` as far as they are known.
  """
  @spec subscribe_rows(pid) :: [map]
  def subscribe_rows(pid) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:subscribe_rows, pid}),
      else: []
  end

  @doc "Stops sending `pid` the linked environments' rows; it stays subscribed to links."
  @spec unsubscribe_rows(pid) :: :ok
  def unsubscribe_rows(pid) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:unsubscribe_rows, pid}),
      else: :ok
  end

  @doc """
  Pairs this node with the environment behind `pairing_url`, a one-time pairing link
  with its token in the query or the fragment, and keeps the link. Pairing an
  environment again replaces its link. Returns the environment's descriptor.
  """
  @spec add(String.t()) :: {:ok, map} | {:error, String.t()}
  def add(pairing_url) do
    with {:ok, origin, token} <- parse(pairing_url),
         {:ok, descriptor} <- fetch_descriptor(origin),
         :ok <- not_reachable(descriptor),
         {:ok, access} <- exchange(origin, token) do
      link = %{"origin" => origin, "token" => access, "environment" => descriptor}
      :ok = GenServer.call(__MODULE__, {:put, link})
      {:ok, descriptor}
    end
  end

  @doc "Forgets the link to `environment_id`."
  @spec remove(String.t()) :: :ok | {:error, String.t()}
  def remove(environment_id), do: GenServer.call(__MODULE__, {:remove, environment_id})

  @doc """
  Where a client's shape or RPC for `environment_id` is served: `{:node, node}` on this
  node or the cluster member serving it, `:link` through the link to it or to a cluster
  it is a member of (`rpc/4`, `watch/4`), else `:unknown`. A linked cluster's members
  are known from its descriptor when the link connects and from any of its shells the
  link passes on; the linked node routes to them itself.
  """
  @spec route(String.t()) :: {:node, node} | :link | :unknown
  def route(environment_id) do
    cond do
      # Even if the node became distributed (and changed its name) after the shell
      # recorded it.
      environment_id == HalC2.Environment.id() -> {:node, node()}
      node = cluster_node(environment_id) -> {:node, node}
      connection(environment_id) -> :link
      true -> :unknown
    end
  end

  defp cluster_node(environment_id) do
    Enum.find_value(HalC2.Shell.environments(), fn {node, descriptor} ->
      if descriptor["environmentId"] == environment_id, do: node
    end)
  end

  @doc """
  Runs a client RPC on a linked environment, as `HalC2.Rpc.handle/2` answers, or fails
  at once with `unreachable/2`'s error while its link is down.
  """
  @spec rpc(String.t(), String.t(), term, timeout) :: {:ok, term} | {:error, String.t() | map}
  def rpc(environment_id, method, payload, timeout) do
    case connection(environment_id) do
      nil -> {:error, "unknown environment"}
      pid -> Connection.rpc(pid, environment_id, method, payload, timeout)
    end
  end

  @doc """
  The error a request for `environment_id` gets while its link is down: `reason` is
  `"unreachable"`, or `"refused"` when the environment no longer accepts the link's
  token. `message` says so for a person.
  """
  @spec unreachable(String.t(), String.t(), String.t()) :: map
  def unreachable(environment_id, reason, message),
    do: %{
      "_tag" => "EnvironmentUnreachableError",
      "environmentId" => environment_id,
      "reason" => reason,
      "message" => message
    }

  @doc """
  Subscribes `pid` to `shape` (a protocol 3 shape naming the environment) on a
  linked environment, from `offset` for a stream. `pid` receives
  `{:hal_c2_link, ref, frame}` for each of the subscription's frames; the frame's `id`
  is the link's, not the client's. While the link is down after failing, it fails at
  once as `rpc/4` does; while it first connects, the subscription waits for it.
  """
  @spec watch(String.t(), map, pid, non_neg_integer | nil) ::
          {:ok, reference} | {:error, String.t() | map}
  def watch(environment_id, shape, pid, offset \\ nil) do
    case connection(environment_id) do
      nil -> {:error, "unknown environment"}
      link -> Connection.watch(link, shape, pid, offset)
    end
  end

  @spec unwatch(String.t(), reference) :: :ok
  def unwatch(environment_id, ref) do
    case connection(environment_id) do
      nil -> :ok
      pid -> Connection.unwatch(pid, ref)
    end
  end

  defp connection(environment_id) do
    case Registry.lookup(HalC2.Links.Registry, environment_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    # No links on this node (tools, tests without them).
    ArgumentError -> nil
  end

  # --- pairing -------------------------------------------------------------------

  @doc false
  def parse(pairing_url) do
    uri = URI.parse(String.trim(pairing_url))
    fragment = URI.decode_query(uri.fragment || "")
    query = URI.decode_query(uri.query || "")
    token = presence(fragment["token"]) || presence(query["token"])

    cond do
      uri.scheme not in ["http", "https"] or uri.host in [nil, ""] ->
        {:error, "not a pairing link"}

      token == nil ->
        {:error, "the pairing link has no token"}

      true ->
        {:ok, "#{uri.scheme}://#{uri.authority}", token}
    end
  end

  defp presence(nil), do: nil
  defp presence(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp fetch_descriptor(origin) do
    case http(:get, origin <> "/.well-known/hal-c2/environment", [], nil) do
      {:ok, 200, %{"environmentId" => id, "orchestrationProtocolVersion" => v} = descriptor}
      when is_binary(id) and is_integer(v) and v >= 3 ->
        {:ok, Map.drop(descriptor, ["node", "cluster"])}

      {:ok, _, _} ->
        {:error, "#{origin} is not a HAL-C2 node"}

      {:error, reason} ->
        {:error, "cannot reach #{origin}: #{inspect(reason)}"}
    end
  end

  # This node and its cluster are reached without a link.
  defp not_reachable(%{"environmentId" => id}) do
    if match?({:node, _}, route(id)),
      do: {:error, "this node already reaches that environment"},
      else: :ok
  end

  defp exchange(origin, token) do
    form =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
        "subject_token" => token,
        "client_label" => HalC2.Environment.descriptor()["label"],
        "client_device_type" => "server"
      })

    case http(:post, origin <> "/oauth/token", [], {"application/x-www-form-urlencoded", form}) do
      {:ok, 200, %{"access_token" => access}} -> {:ok, access}
      {:ok, _, _} -> {:error, "the pairing link is invalid or expired"}
      {:error, reason} -> {:error, "cannot reach #{origin}: #{inspect(reason)}"}
    end
  end

  @doc false
  def http(method, url, headers, body) do
    headers = for {k, v} <- headers, do: {to_charlist(k), to_charlist(v)}

    request =
      case body do
        nil -> {to_charlist(url), headers}
        {type, data} -> {to_charlist(url), headers, to_charlist(type), data}
      end

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    options = [timeout: @http_timeout, connect_timeout: @http_timeout, ssl: ssl]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, _, reply}} ->
        {:ok, status, with({:ok, json} <- JSON.decode(reply), do: json, else: (_ -> nil))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- server --------------------------------------------------------------------

  @impl true
  def init(_opts) do
    links =
      case Secrets.get(@secret) do
        nil -> %{}
        json -> Map.new(JSON.decode!(json), &{&1["environment"]["environmentId"], &1})
      end

    Enum.each(links, fn {_, link} -> start_connection(link) end)
    # subscribers: pid => {monitor, rows?}; rows: id => Rows, while any subscriber wants
    # them; following: the ref of each link's shell subscription => id.
    {:ok,
     %{
       links: links,
       online: MapSet.new(),
       problems: %{},
       subscribers: %{},
       rows: %{},
       following: %{}
     }}
  end

  # From before linked rows: subscribers were pid => monitor.
  @impl true
  def code_change(_old_vsn, state, _extra) do
    subscribers =
      Map.new(state.subscribers, fn
        {pid, {_, _} = sub} -> {pid, sub}
        {pid, monitor} -> {pid, {monitor, false}}
      end)

    {:ok,
     state
     |> Map.put(:subscribers, subscribers)
     |> Map.put_new(:rows, %{})
     |> Map.put_new(:following, %{})
     |> Map.put_new(:problems, %{})}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, listing(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers =
      Map.put_new_lazy(state.subscribers, pid, fn -> {Process.monitor(pid), false} end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:subscribe_rows, pid}, _from, state) do
    monitor =
      case state.subscribers[pid] do
        {monitor, _} -> monitor
        nil -> Process.monitor(pid)
      end

    state = follow(%{state | subscribers: Map.put(state.subscribers, pid, {monitor, true})})

    links =
      for link <- listing(state) do
        rows = Map.get(state.rows, link["environment"]["environmentId"], Rows.new())
        Map.merge(link, Rows.listing(rows))
      end

    {:reply, links, state}
  end

  def handle_call({:unsubscribe_rows, pid}, _from, state) do
    case state.subscribers[pid] do
      {monitor, true} ->
        subscribers = Map.put(state.subscribers, pid, {monitor, false})
        {:reply, :ok, unfollow(%{state | subscribers: subscribers})}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:put, link}, _from, state), do: put(link, state)

  def handle_call({:remove, id}, _from, state) do
    case state.links[id] do
      nil ->
        {:reply, {:error, "no link to #{id}"}, state}

      _ ->
        stop_connection(id)

        state = %{
          state
          | links: Map.delete(state.links, id),
            online: MapSet.delete(state.online, id),
            problems: Map.delete(state.problems, id),
            rows: Map.delete(state.rows, id),
            following: Map.reject(state.following, &(elem(&1, 1) == id))
        }

        persist(state)
        {:reply, :ok, notify(state)}
    end
  end

  defp put(link, state) do
    id = link["environment"]["environmentId"]
    stop_connection(id)

    state = %{
      state
      | links: Map.put(state.links, id, link),
        online: MapSet.delete(state.online, id),
        problems: Map.delete(state.problems, id)
    }

    persist(state)
    start_connection(link)
    # A link paired again follows its environment afresh; until then its nodes are offline.
    state = %{state | following: Map.reject(state.following, &(elem(&1, 1) == id))}
    state = rows_changed(state, id, &Rows.offline/1)
    state = if rows_wanted?(state), do: follow_link(state, id), else: state
    {:reply, :ok, notify(state)}
  end

  @impl true
  def handle_cast({:online, id, online?}, state) do
    online = if online?, do: MapSet.put(state.online, id), else: MapSet.delete(state.online, id)
    problems = if online?, do: Map.delete(state.problems, id), else: state.problems

    if Map.has_key?(state.links, id) and online != state.online do
      state = notify(%{state | online: online, problems: problems})
      {:noreply, if(online?, do: state, else: rows_changed(state, id, &Rows.offline/1))}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:problem, id, kind}, state) do
    if Map.has_key?(state.links, id) and state.problems[id] != kind,
      do: {:noreply, notify(put_in(state.problems[id], kind))},
      else: {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, unfollow(%{state | subscribers: Map.delete(state.subscribers, pid)})}

  # A frame of a link's own shell subscription. One that ends it (the environment
  # refused it) leaves the link's rows as they were.
  def handle_info({:hal_c2_link, ref, frame}, state) do
    case {state.following, frame["t"]} do
      {%{^ref => _id}, t} when t in ["end", "error", "resync"] ->
        {:noreply, %{state | following: Map.delete(state.following, ref)}}

      {%{^ref => id}, _} ->
        {:noreply, rows_changed(state, id, &Rows.apply(&1, frame))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp listing(state) do
    for {id, link} <- Enum.sort_by(state.links, &elem(&1, 1)["environment"]["label"]) do
      online = MapSet.member?(state.online, id)

      listed = %{
        "environment" => link["environment"],
        "origin" => link["origin"],
        "online" => online
      }

      case state.problems[id] do
        problem when is_binary(problem) and not online -> Map.put(listed, "problem", problem)
        _ -> listed
      end
    end
  end

  defp notify(state) do
    links = listing(state)
    for {pid, _} <- state.subscribers, do: send(pid, {:hal_c2_links, links})
    state
  end

  # --- linked rows ---------------------------------------------------------------

  defp rows_wanted?(state), do: Enum.any?(state.subscribers, &match?({_, {_, true}}, &1))

  # Every link follows its environment's shell, once some subscriber wants rows.
  defp follow(state) do
    if map_size(state.following) == 0 and rows_wanted?(state),
      do: Enum.reduce(Map.keys(state.links), state, &follow_link(&2, &1)),
      else: state
  end

  defp follow_link(state, id) do
    case connection(id) do
      nil ->
        state

      pid ->
        ref = make_ref()
        Connection.watch_async(pid, ref, %{"type" => "shell"}, self())

        %{
          state
          | following: Map.put(state.following, ref, id),
            rows: Map.put_new(state.rows, id, Rows.new())
        }
    end
  end

  # Once no subscriber wants rows, the links stop following and forget them.
  defp unfollow(state) do
    if rows_wanted?(state) do
      state
    else
      for {ref, id} <- state.following, do: unwatch(id, ref)
      %{state | following: %{}, rows: %{}}
    end
  end

  defp rows_changed(state, id, fun) do
    case state.rows do
      %{^id => rows} ->
        {rows, changes} = fun.(rows)

        for {pid, {_, true}} <- state.subscribers,
            change <- changes,
            do: send(pid, {:hal_c2_link_rows, id, change})

        %{state | rows: Map.put(state.rows, id, rows)}

      _ ->
        state
    end
  end

  defp persist(state) do
    Secrets.put(@secret, JSON.encode!(Map.values(state.links)))
  end

  defp start_connection(link) do
    {:ok, _} = DynamicSupervisor.start_child(HalC2.Links.Supervisor, {Connection, link})
  end

  defp stop_connection(id) do
    case connection(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(HalC2.Links.Supervisor, pid)
    end
  end
end
