defmodule HalC2.Links do
  @moduledoc """
  Environments this node reaches without clustering with them: other nodes the user
  paired this one with. A link keeps the access token its pairing gave and one
  websocket (`HalC2.Links.Connection`) that forwards client RPCs and subscriptions,
  so a client that only talks to this node reaches the linked environment too
  (`HalC2.Web.Socket`).

  A client can also lend this node the access it already holds on an environment
  (`borrow/2`): the desktop shell passes on what its page paired with, so nothing is
  paired twice. A borrowed link lives only as long as this node runs; the client
  lends it again on every connection and takes it back when the page forgets the
  environment.

  Paired links persist in the `environment-links` secret. Subscribers get
  `{:hal_c2_links, links}` with the whole list (`list/0`) whenever a link is added,
  removed, or goes on- or offline.
  """

  use GenServer

  alias HalC2.Connect.Secrets
  alias HalC2.Links.Connection

  @secret "environment-links"
  @http_timeout 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc ~s|Every link as `%{"environment" => descriptor, "origin", "online"}`.|
  @spec list() :: [map]
  def list do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :list), else: []
  end

  @spec subscribe(pid) :: :ok
  def subscribe(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:subscribe, pid}), else: :ok
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

  @doc """
  Links the environment at `origin` with `token`, an access token a client already
  holds there, without persisting it. Returns the environment's descriptor.
  """
  @spec borrow(String.t(), String.t()) :: {:ok, map} | {:error, String.t()}
  def borrow(origin, token) do
    with {:ok, origin} <- parse_origin(origin),
         {:ok, descriptor} <- fetch_descriptor(origin),
         :ok <- not_reachable(descriptor) do
      link = %{"origin" => origin, "token" => token, "environment" => descriptor}
      :ok = GenServer.call(__MODULE__, {:put, Map.put(link, "borrowed", true)})
      {:ok, descriptor}
    end
  end

  @doc "Forgets the link to `environment_id`."
  @spec remove(String.t()) :: :ok | {:error, String.t()}
  def remove(environment_id), do: GenServer.call(__MODULE__, {:remove, environment_id, :any})

  @doc "Takes back what `borrow/2` lent for `environment_id`; a paired link stays."
  @spec give_back(String.t()) :: :ok
  def give_back(environment_id) do
    _ = GenServer.call(__MODULE__, {:remove, environment_id, :borrowed})
    :ok
  end

  @doc "Runs a client RPC on a linked environment, as `HalC2.Rpc.handle/2` answers."
  @spec rpc(String.t(), String.t(), term, timeout) :: {:ok, term} | {:error, String.t() | map}
  def rpc(environment_id, method, payload, timeout) do
    case connection(environment_id) do
      nil -> {:error, "unknown environment"}
      pid -> Connection.rpc(pid, method, payload, timeout)
    end
  end

  @doc """
  Subscribes `pid` to `shape` (a protocol 3 shape naming the environment) on a
  linked environment, from `offset` for a stream. `pid` receives
  `{:hal_c2_link, ref, frame}` for each of the subscription's frames; the frame's `id`
  is the link's, not the client's.
  """
  @spec watch(String.t(), map, pid, non_neg_integer | nil) ::
          {:ok, reference} | {:error, String.t()}
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

  defp parse_origin(origin) do
    case URI.parse(String.trim(origin)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, "#{scheme}://#{uri.authority}"}

      _ ->
        {:error, "not an environment origin"}
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
    cluster = for {_node, d} <- HalC2.Shell.environments(), do: d["environmentId"]

    if id == HalC2.Environment.id() or id in cluster,
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
    {:ok, %{links: links, online: MapSet.new(), subscribers: %{}}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, listing(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers =
      Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  # A borrowed token never replaces a paired link, nor the same loan again.
  def handle_call({:put, %{"borrowed" => true, "token" => token} = link}, _from, state) do
    case state.links[link["environment"]["environmentId"]] do
      %{"borrowed" => true, "token" => ^token} -> {:reply, :ok, state}
      %{} = paired when not is_map_key(paired, "borrowed") -> {:reply, :ok, state}
      _ -> put(link, state)
    end
  end

  def handle_call({:put, link}, _from, state), do: put(link, state)

  def handle_call({:remove, id, which}, _from, state) do
    case state.links[id] do
      nil ->
        {:reply, {:error, "no link to #{id}"}, state}

      link when which == :borrowed and not is_map_key(link, "borrowed") ->
        {:reply, {:error, "the link to #{id} was paired"}, state}

      _ ->
        stop_connection(id)

        state = %{
          state
          | links: Map.delete(state.links, id),
            online: MapSet.delete(state.online, id)
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
        online: MapSet.delete(state.online, id)
    }

    persist(state)
    start_connection(link)
    {:reply, :ok, notify(state)}
  end

  @impl true
  def handle_cast({:online, id, online?}, state) do
    online = if online?, do: MapSet.put(state.online, id), else: MapSet.delete(state.online, id)

    if Map.has_key?(state.links, id) and online != state.online,
      do: {:noreply, notify(%{state | online: online})},
      else: {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  defp listing(state) do
    for {id, link} <- Enum.sort_by(state.links, &elem(&1, 1)["environment"]["label"]) do
      %{
        "environment" => link["environment"],
        "origin" => link["origin"],
        "online" => MapSet.member?(state.online, id)
      }
    end
  end

  defp notify(state) do
    links = listing(state)
    for {pid, _} <- state.subscribers, do: send(pid, {:hal_c2_links, links})
    state
  end

  defp persist(state) do
    paired = for {_, link} <- state.links, !link["borrowed"], do: link
    Secrets.put(@secret, JSON.encode!(paired))
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
