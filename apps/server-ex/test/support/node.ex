defmodule HalC2.Test.Node do
  @moduledoc """
  One node under test, as a client sees it over the protocol 3 socket.

  `start/1` brings up the same pieces `HalC2.ScenariosTest` does (store, auth,
  streams, shell, web) under the test supervisor with the state in a fresh
  directory; steps add the services their scenario needs with `ensure/1`.
  Clients are `HalC2.Test.WsClient` structs threaded through the scenario context.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised: 1, start_supervised!: 1]

  alias HalC2.Test.WsClient
  @doc false
  def ws_client, do: WsClient

  @doc """
  Starts a node in `dir` and returns what steps need to talk to it:
  `%{port, environment, home}`. `port` 0 picks a free one.

  The node keeps every file in `dir` itself unless `opts[:home]` gives it a `:home`
  as a release has one (`nil` for the XDG directories, `{:root, dir}`,
  `{:node, dir}`, see `HalC2.Paths`); it then readies its directories as
  `HalC2.Application` does, migrating with `opts[:migration]` where the app env
  allows, and `dir` only holds the scenario's scratch files.
  """
  def start(dir, port \\ 0, opts \\ []) do
    File.mkdir_p!(dir)
    spec = Keyword.get(opts, :home, dir)
    Application.put_env(:hal_c2, :home, spec)
    Application.put_env(:hal_c2, :port, port)
    :persistent_term.erase({HalC2.Web, :token})

    unless is_binary(spec) do
      :persistent_term.erase({HalC2.Environment, :id})
      :ok = HalC2.Application.prepare_files(Keyword.get(opts, :migration, []))
    end

    store = HalC2.Store.home_path()
    start_supervised!({HalC2.Store, path: store})
    start_supervised!(HalC2.Auth)
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    web = start_supervised!(Supervisor.child_spec(HalC2.Web, id: HalC2.Web))
    start_supervised!(HalC2.RuntimeRecord)
    # A named node finds its peers as it would at boot (HAL_C2_PEERS, the tailnet).
    for spec <- HalC2.Application.discovery(HalC2.Paths.data_dir()),
        do: start_supervised!(Supervisor.child_spec(spec, id: :discovery))

    {:ok, {_ip, port}} = ThousandIsland.listener_info(web)
    # The port it got, as a configured node knows its own (`mix hal_c2.pair` reads it).
    Application.put_env(:hal_c2, :port, port)
    {_, %{"environmentId" => environment}} = List.keyfind(HalC2.Shell.environments(), node(), 0)
    :ok = HalC2.Shell.subscribe(self())
    node = %{port: port, environment: environment, home: dir, store: store}
    if is_binary(spec), do: node, else: Map.put(node, :spec, spec)
  end

  @doc """
  Stops the node's services, as a shutdown does. Services a step added with
  `ensure/1` stop first (so a normal shutdown can still release its tunnel),
  then the core; `restart/1` brings them all back.
  """
  def stop(node) do
    # Provider processes die with the node.
    if Process.whereis(HalC2.Codex.Supervisor) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(HalC2.Codex.Supervisor),
          do: DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)
    end

    for child <- Enum.reverse(Process.get({__MODULE__, :ensured}, [])),
        do: ExUnit.Callbacks.stop_supervised(Supervisor.child_spec(child, []).id)

    for child <- [
          :discovery,
          HalC2.RuntimeRecord,
          HalC2.Web,
          HalC2.Shell,
          HalC2.Streams,
          HalC2.Auth,
          HalC2.Store
        ],
        do: ExUnit.Callbacks.stop_supervised(child)

    node
  end

  @doc """
  Stops the node's services (if `stop/1` has not) and starts them again on the
  same state, as a restart does, on the same port. Services a step started with
  `ensure/1` (settings, plugins, HAL-C2 Connect, diagnostics, scheduled tasks) come
  back after the core, so in-memory state (clones, setups) is lost as in a real
  restart. Turns the stop cut off are settled and, where the project asks for
  it, continued (`HalC2.Orchestration.Recovery`), as `HalC2.Application` boots.
  Sockets are gone afterwards; steps reconnect. `while_stopped` runs after the
  services stop and before they start, as an operator's offline task would
  (`mix hal_c2.import`).
  """
  def restart(%{home: dir, port: port} = node, while_stopped \\ fn -> :ok end) do
    stop(node)
    while_stopped.()
    ensured = Process.get({__MODULE__, :ensured}, [])

    opts =
      if Map.has_key?(node, :spec),
        do: [home: node.spec, migration: node[:migration] || []],
        else: []

    node =
      if(opts[:migration],
        do: Map.put(start(dir, port, opts), :migration, opts[:migration]),
        else: start(dir, port, opts)
      )

    # In the application's order: cut-off turns settle before the optional
    # services (HAL-C2 Connect among them) are back, then the boot tasks run.
    HalC2.Orchestration.Recovery.run()
    Enum.each(ensured, &ensure/1)
    :ok = HalC2.Orchestration.Recovery.continue()
    # Threads from before the search index are indexed, as at boot.
    HalC2.Search.backfill()
    :ok = HalC2.Projects.auto_pull()
    :ok = HalC2.Projects.identify_repositories()
    node
  end

  @doc """
  Starts a service under the test supervisor if it is not running yet; `restart/1`
  starts it again.
  """
  def ensure(child) do
    case start_supervised(child) do
      {:ok, pid} ->
        ensured = Process.get({__MODULE__, :ensured}, [])
        Process.put({__MODULE__, :ensured}, Enum.uniq(ensured ++ [child]))
        pid

      {:error, {{:already_started, pid}, _}} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        raise "could not start #{inspect(child)}: #{inspect(reason)}"
    end
  end

  @doc "A fresh temporary directory under the scenario's home, for repos and files."
  def tmp_dir(%{home: home}, name \\ "dir") do
    dir = Path.join([home, "tmp", "#{name}-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(dir)
    dir
  end

  @doc "Opens a socket with the node's token (or `query`) and consumes the hello frame."
  def connect(%{port: port}, query \\ nil) do
    {:ok, client} = WsClient.connect(port, "/ws?" <> (query || "token=#{HalC2.Web.token()}"))
    {%{"t" => "hello", "protocol" => 3}, client} = WsClient.recv(client, 1_000)
    client
  end

  @doc "Subscribes the socket to a shape under `id`."
  def sub(client, id, shape),
    do: WsClient.send_json(client, %{"t" => "sub", "id" => id, "shape" => shape})

  def unsub(client, id), do: WsClient.send_json(client, %{"t" => "unsub", "id" => id})

  @doc "Sends an RPC frame; the reply is awaited with `reply/2` or `call/4`."
  def rpc(client, environment, id, method, payload) do
    WsClient.send_json(client, %{
      "t" => "rpc",
      "id" => id,
      "environment" => environment,
      "method" => method,
      "payload" => payload
    })
  end

  @doc """
  Sends an RPC and waits for its reply. Returns `{{:ok, result} | {:error, error, detail}, client}`.
  """
  def call(client, environment, method, payload \\ %{}) do
    id = System.unique_integer([:positive])
    client = rpc(client, environment, id, method, payload)
    {frame, client} = await(client, reply?(id))

    case frame do
      %{"t" => "rpc.result", "result" => result} -> {{:ok, result}, client}
      %{"t" => "rpc.error", "error" => error} -> {{:error, error, frame["detail"]}, client}
    end
  end

  @doc "Like `call/4` but asserts success and returns `{result, client}`."
  def call!(client, environment, method, payload \\ %{}) do
    case call(client, environment, method, payload) do
      {{:ok, result}, client} -> {result, client}
      {{:error, error, detail}, _} -> flunk("#{method} failed: #{error} #{inspect(detail)}")
    end
  end

  @doc "The first frame matching `fun`, skipping others. Raises after `timeout`."
  def await(client, fun, timeout \\ 2_000) do
    {frame, _skipped, client} = WsClient.recv_until(client, fun, timeout)
    {frame, client}
  end

  @doc """
  The first frame matching each predicate, in predicate order, whatever order
  they arrive in (an RPC's reply and the push it causes race).
  """
  def await_all(client, preds), do: await_all(client, Enum.with_index(preds), %{})

  defp await_all(client, [], found),
    do: {found |> Enum.sort() |> Enum.map(&elem(&1, 1)), client}

  defp await_all(client, pending, found) do
    {frame, client} = WsClient.recv(client, 2_000)

    case Enum.find(pending, fn {pred, _} -> pred.(frame) end) do
      nil ->
        await_all(client, pending, found)

      {_, index} = hit ->
        await_all(client, List.delete(pending, hit), Map.put(found, index, frame))
    end
  end

  @doc "Asserts no frame matching `fun` arrives within `timeout`; returns the client."
  def refute_frame(client, fun, timeout \\ 300) do
    case WsClient.recv_until(client, fun, timeout) do
      {frame, _, _} -> flunk("unexpected frame: #{inspect(frame)}")
      _ -> client
    end
  rescue
    # `WsClient.recv/2` raises when nothing arrives in time, which is the pass.
    error in RuntimeError ->
      if error.message =~ "no frame within", do: client, else: reraise(error, __STACKTRACE__)
  catch
    :exit, _ -> client
  end

  def reply?(id), do: &(&1["t"] in ["rpc.result", "rpc.error"] and &1["id"] == id)

  @doc "Subscribes to the config shape and waits until its first snapshot lands."
  def config(client, id \\ 1) do
    client = sub(client, id, %{"type" => "config", "node" => Atom.to_string(node())})
    {_, client} = await(client, &(&1["t"] == "config.usageLimitSources" and &1["id"] == id))
    client
  end

  # --- added by W4 (terminal) ---

  @doc """
  Starts a second node joined to this one: a `:peer` VM running the whole app in
  its own home under the scenario's `node.home`. This VM becomes distributed on
  first use. Returns the peer's node name; the peer stops when the scenario ends.
  """
  def start_peer(node) do
    unless :erlang.is_alive() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = :"hal_c2_features#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
    end

    {:ok, peer, name} =
      :peer.start(%{
        name: :"hal_c2_peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    ExUnit.Callbacks.on_exit(fn -> :peer.stop(peer) end)

    # A peer node does not read Mix config, so it gets the node settings directly.
    for {key, value} <- [start_node: true, home: Path.join(node.home, "peer"), port: 0],
        do: :ok = :erpc.call(name, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = :erpc.call(name, Application, :ensure_all_started, [:hal_c2])
    name
  end

  @doc """
  An HTTP request to the node (or to a base URL such as `"http://10.0.0.5:3773"`):
  `{status, body}`, with a JSON body decoded. `opts`: `:bearer`, `:json` (a body to
  encode), `:form` (a map sent urlencoded).
  """
  def http(node_or_base, method, path, opts \\ []) do
    base =
      if is_binary(node_or_base), do: node_or_base, else: "http://127.0.0.1:#{node_or_base.port}"

    url = String.to_charlist(base <> path)

    headers =
      for token <- List.wrap(opts[:bearer]),
          do: {~c"authorization", ~c"Bearer " ++ String.to_charlist(token)}

    request =
      cond do
        body = opts[:json] ->
          {url, headers, ~c"application/json", JSON.encode!(body)}

        form = opts[:form] ->
          {url, headers, ~c"application/x-www-form-urlencoded", URI.encode_query(form)}

        true ->
          {url, headers}
      end

    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(method, request, [timeout: 5_000], body_format: :binary)

    case JSON.decode(body) do
      {:ok, decoded} -> {status, decoded}
      _ -> {status, body}
    end
  end

  @doc "Pairs a device with `scopes` (default standard); returns its bearer access token."
  def pair(scopes \\ nil, label \\ "Device") do
    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{"scopes" => scopes || HalC2.Auth.standard_scopes()})

    {:ok, access, _expires, _scopes} = HalC2.Auth.exchange(credential, %{label: label})
    access
  end

  @doc "Pairs over HTTP as a client does: posts `credential` to `/oauth/token`; `{status, body}`."
  def pair_http(node_or_base, credential, label \\ "Device") do
    http(node_or_base, :post, "/oauth/token",
      form: %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
        "subject_token" => credential,
        "client_label" => label
      }
    )
  end

  @doc "Opens a socket for a bearer access token (through a WebSocket ticket)."
  def connect_as(node, access) do
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)
    connect(node, "wsTicket=#{ticket}")
  end

  @doc "A non-loopback IPv4 address of this machine, as a string (what LAN clients dial)."
  def lan_address do
    {:ok, interfaces} = :inet.getifaddrs()

    ips =
      for {_name, opts} <- interfaces,
          {:addr, {a, _, _, _} = ip} <- opts,
          a != 127,
          do: ip

    assert ip = List.first(ips), "no LAN address on this machine"
    ip |> :inet.ntoa() |> List.to_string()
  end

  @doc """
  Runs a Mix task (`Mix.Tasks.HalC2.Pair`, say) in the node's home as an operator
  would and returns the lines it printed. A `Mix.raise` comes back as `{:error, message}`.
  """
  def run_task(task, args) do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      task.run(args)
      collect_info([])
    rescue
      e in Mix.Error -> {:error, e.message}
    after
      Mix.shell(previous)
    end
  end

  defp collect_info(lines) do
    receive do
      {:mix_shell, :info, [line]} -> collect_info([line | lines])
    after
      0 -> Enum.reverse(lines)
    end
  end

  @doc "The scopes an administrator's session carries."
  def admin_scopes, do: HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)

  # --- added by W14 ---

  @doc """
  The environment id of `peer` (from `start_peer/1`) as this node's shell knows
  it, waiting until the peer has announced itself; RPCs to the peer route by it.
  """
  def peer_environment(peer) do
    :ok = HalC2.Shell.subscribe(self())

    case List.keyfind(HalC2.Shell.environments(), peer, 0) do
      {^peer, %{"environmentId" => environment}} ->
        environment

      nil ->
        receive do
          {:hal_c2_shell, {:environment, ^peer, %{"environmentId" => environment}}} -> environment
        after
          10_000 -> ExUnit.Assertions.flunk("#{peer} never announced its environment")
        end
    end
  end

  @doc "Sends `text` as one raw text frame, JSON or not."
  def send_text(client, text) do
    {:ok, ws, data} = Mint.WebSocket.encode(client.ws, {:text, text})
    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    %{client | conn: conn, ws: ws}
  end

  @doc """
  Waits for the node to close the socket, skipping other frames. Returns
  `{:close, code, reason}` for a close frame, or `:closed` when the connection just drops.
  """
  def await_close(client, timeout \\ 2_000) do
    socket = Mint.HTTP.get_socket(client.conn)

    receive do
      {:tcp_closed, ^socket} ->
        :closed

      {:tcp, ^socket, _} = message ->
        case Mint.WebSocket.stream(client.conn, message) do
          {:ok, conn, responses} ->
            data = for {:data, _, data} <- responses, into: "", do: data
            {:ok, ws, frames} = Mint.WebSocket.decode(client.ws, data)

            case for({:close, code, reason} <- frames, do: {:close, code, reason}) do
              [close | _] -> close
              [] -> await_close(%{client | conn: conn, ws: ws}, timeout)
            end

          {:error, _conn, _reason, _responses} ->
            :closed
        end
    after
      timeout -> flunk("the socket stayed open for #{timeout} ms")
    end
  end

  @doc """
  An HTTP request to the node with its response headers: `{status, headers, body}`, with a JSON body decoded.
  Options: `bearer:`, `json:` (a body to send as JSON), `form:`, `body:`, `headers:`.
  """
  def request(%{port: port}, method, path, opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}#{path}"

    headers =
      for {k, v} <-
            (opts[:headers] || []) ++
              if(opts[:bearer], do: [{"authorization", "Bearer #{opts[:bearer]}"}], else: []),
          do: {to_charlist(k), to_charlist(v)}

    {type, body} =
      cond do
        opts[:json] -> {~c"application/json", JSON.encode!(opts[:json])}
        opts[:form] -> {~c"application/x-www-form-urlencoded", URI.encode_query(opts[:form])}
        true -> {~c"application/octet-stream", opts[:body] || ""}
      end

    request =
      if method in [:post, :put, :patch],
        do: {url, headers, type, body},
        else: {url, headers}

    {:ok, {{_, status, _}, resp_headers, resp}} =
      :httpc.request(method, request, [autoredirect: false], body_format: :binary)

    resp_headers = for {k, v} <- resp_headers, do: {to_string(k), to_string(v)}

    body =
      case List.keyfind(resp_headers, "content-type", 0) do
        {_, "application/json" <> _} when resp != "" -> JSON.decode!(resp)
        _ -> resp
      end

    {status, resp_headers, body}
  end

  @doc """
  Pairs a client the way the client runtime does (`POST /oauth/token`) with `token`
  (a pairing credential or the desktop bootstrap token); returns the grant or the error.
  """
  def exchange(node, token, fields \\ %{}) do
    form =
      Map.merge(
        %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
          "subject_token" => token,
          "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
          "client_label" => "Test client"
        },
        fields
      )

    {status, _, body} = request(node, :post, "/oauth/token", form: form)
    {status, body}
  end

  @doc """
  Joins this node to a second one: makes the test VM a distributed node (restarting
  the node's services under its new name), then boots a peer BEAM with the whole
  application in its own home. Returns `{node, peer}` where `node` is the restarted
  node map and `peer` is `%{name, pid, environment, home}`; the peer stops when the
  scenario ends.
  """
  def cluster(node) do
    node =
      if Node.alive?() do
        node
      else
        {_, 0} = System.cmd("epmd", ["-daemon"])
        # Unique names, so the test never collides with nodes running on this machine.
        {:ok, _} =
          Node.start(:"hal_c2_test#{System.unique_integer([:positive])}@127.0.0.1", :longnames)

        restart(node)
      end

    home = Path.join(node.home, "peer-#{System.unique_integer([:positive])}")

    {:ok, pid, name} =
      :peer.start(%{
        name: :"hal_c2_peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    ExUnit.Callbacks.on_exit(fn ->
      try do
        :peer.stop(pid)
      catch
        _, _ -> :ok
      end
    end)

    # A peer node does not read Mix config, so it gets the node settings directly.
    for {key, value} <- [start_node: true, home: home, port: 0],
        do: :ok = :erpc.call(name, Application, :put_env, [:hal_c2, key, value])

    {:ok, _} = :erpc.call(name, Application, :ensure_all_started, [:hal_c2])
    environment = :erpc.call(name, HalC2.Environment, :id, [])
    await_environment(name, 10_000)
    {node, %{name: name, pid: pid, environment: environment, home: home}}
  end

  defp await_environment(name, timeout) do
    unless Enum.any?(HalC2.Shell.environments(), &(elem(&1, 0) == name)) do
      receive do
        {:hal_c2_shell, _} -> await_environment(name, timeout)
      after
        timeout -> flunk("#{name} never joined the shell")
      end
    end
  end

  @doc """
  A copy of a module's code with one extra function, so it differs from what is
  loaded as a new version would: `{module, beam}`. `bin` defaults to the module's
  beam file.
  """
  def variant(mod, bin \\ nil) do
    bin = bin || elem(:code.get_object_code(mod), 1)

    {:ok, {^mod, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(bin, [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, mod, data, [])

    {head, [module | rest]} =
      Enum.split_while(forms, &(not match?({:attribute, _, :module, _}, &1)))

    {body, eof} = Enum.split_with(rest, &(not match?({:eof, _}, &1)))

    mark =
      {:function, 1, :__hal_c2_variant__, 0,
       [{:clause, 1, [], [], [{:integer, 1, System.unique_integer([:positive])}]}]}

    export = {:attribute, 1, :export, [{:__hal_c2_variant__, 0}]}

    {:ok, ^mod, beam} =
      :compile.forms(head ++ [module, export | body] ++ [mark | eof], [:binary, :debug_info])

    {mod, beam}
  end

  @doc """
  Makes the node run from a release at `<home>/release` (`RELEASE_ROOT`), under the
  service wrapper (`HAL_C2_SERVICE=1`) unless `service: false`. A restart the node asks
  for is sent to the test process as `{:hal_c2_restart, status}` instead of stopping the
  VM. Environment, code paths, loaded versions and modules replaced by `bundle/4`
  are put back when the scenario ends. Returns the release root.
  """
  def release(%{home: home}, opts \\ []) do
    root = Path.join(home, "release")
    version = HalC2.Upgrade.version()
    File.mkdir_p!(Path.join([root, "releases", version]))
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(
      Path.join([root, "releases", version, "upgrade.json"]),
      JSON.encode!(manifest(version))
    )

    File.write!(Path.join([root, "releases", "start_erl.data"]), "17.0.5 #{version}\n")
    System.put_env("RELEASE_ROOT", root)

    if Keyword.get(opts, :service, true),
      do: System.put_env("HAL_C2_SERVICE", "1"),
      else: System.delete_env("HAL_C2_SERVICE")

    test = self()
    Application.put_env(:hal_c2, :restart_exit, &send(test, {:hal_c2_restart, &1}))

    unless :persistent_term.get({__MODULE__, :release}, false) do
      :persistent_term.put({__MODULE__, :release}, true)
      paths = :code.get_path()

      ExUnit.Callbacks.on_exit(fn ->
        System.delete_env("RELEASE_ROOT")
        System.delete_env("HAL_C2_SERVICE")
        Application.delete_env(:hal_c2, :restart_exit)
        :persistent_term.erase({HalC2.Upgrade, :version})
        :persistent_term.erase({HalC2.Upgrade, :outcome})
        :persistent_term.erase({__MODULE__, :release})
        :code.set_path(paths)
        restore_modules()
      end)
    end

    root
  end

  @doc "The upgrade manifest of `version` as this node's release would carry it."
  def manifest(version) do
    %{
      "version" => version,
      "otpRelease" => "29",
      "erts" => "17.0.5",
      "platform" => HalC2.Upgrade.platform(),
      "applications" => %{"hal_c2" => version},
      "nifs" => %{},
      "config" => "c"
    }
  end

  @doc """
  A bundle archive for `version` (with its `.sha256` beside it): the running
  manifest with `changes`, and `modules` (`{module, beam}`) under `lib/`. Modules
  it replaces are loaded back when the scenario ends (see `release/2`).
  """
  def bundle(node, version, changes \\ %{}, modules \\ []) do
    dir = tmp_dir(node, "bundle")
    rel = Path.join([dir, "releases", version])
    # Not `hal-c2-<version>`: code paths move to that directory, which must not hide the
    # rest of the application's modules from the test VM.
    ebin = Path.join([dir, "lib", "hal_c2_bundle-#{version}", "ebin"])
    File.mkdir_p!(rel)
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(rel, "upgrade.json"),
      JSON.encode!(Map.merge(manifest(version), changes))
    )

    for {mod, beam} <- modules do
      remember_module(mod)
      File.write!(Path.join(ebin, "#{mod}.beam"), beam)
    end

    path =
      Path.join(
        tmp_dir(node, "archive"),
        HalC2.Upgrade.Source.file_name(version, HalC2.Upgrade.platform())
      )

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [
          {~c"releases", String.to_charlist(Path.join(dir, "releases"))},
          {~c"lib", String.to_charlist(Path.join(dir, "lib"))}
        ],
        [:compressed]
      )

    sum = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    File.write!(path <> ".sha256", "#{sum}  #{Path.basename(path)}\n")
    path
  end

  @doc "Remembers a module's current code, loaded back when the scenario ends (`release/2`)."
  def remember_module(mod) do
    originals = :persistent_term.get({__MODULE__, :originals}, %{})

    # Modules compiled in the test itself have no beam file and are left alone.
    with false <- Map.has_key?(originals, mod),
         {^mod, bin, _} <- :code.get_object_code(mod),
         do: :persistent_term.put({__MODULE__, :originals}, Map.put(originals, mod, bin))

    :ok
  end

  @doc "Loads back every module `remember_module/1` saw."
  def restore_modules do
    originals = :persistent_term.get({__MODULE__, :originals}, %{})
    :persistent_term.erase({__MODULE__, :originals})
    if originals != %{}, do: HalC2.Hot.reload(Map.to_list(originals))
    :ok
  end
end

defmodule HalC2.Test.Node.World do
  @moduledoc """
  What a scenario builds up on its node: projects, threads and sockets, by the
  names the feature uses. Everything is kept in the Cucumber context map so
  steps in any file can find it:

    * `context.node` - `%{port, environment, home, store}` from `HalC2.Test.Node.start/1`
    * `context.projects` - title → `%{id, root}`
    * `context.threads` - title → thread id
    * `context.clients` - name → `HalC2.Test.WsClient` (`"default"` for the unnamed one)

  Sockets are values: take one with `client/2`, thread it through the calls,
  and put it back with `put_client/3`.
  """

  import ExUnit.Assertions

  alias HalC2.Test.Node

  @doc "Creates a project rooted at a fresh git repository; `title` is also its id."
  def create_project(context, title, fields \\ %{}) do
    id = fields["projectId"] || slug(title)
    root = fields["workspaceRoot"] || git_repo(context, id)

    {:ok, _} =
      HalC2.Projects.mutate(
        Map.merge(
          %{
            "type" => "project.create",
            "projectId" => id,
            "title" => title,
            "workspaceRoot" => root
          },
          fields
        )
      )

    await_row(id, & &1)
    put_in(context, [:projects, title], %{id: id, root: root})
  end

  @doc "A project by title, or the scenario's only project, as `%{id, root}`."
  def project(context, title \\ nil) do
    projects = context[:projects] || %{}

    cond do
      title && projects[title] -> projects[title]
      title -> flunk("no project #{inspect(title)} in this scenario")
      map_size(projects) == 1 -> projects |> Map.values() |> hd()
      true -> flunk("the scenario has #{map_size(projects)} projects; name one")
    end
  end

  @doc "Creates an idle thread in `project` (a title, or nil for the only project)."
  def create_thread(context, title, project \\ nil, fields \\ %{}) do
    id = fields["threadId"] || "th-#{slug(title)}-#{System.unique_integer([:positive])}"

    project_id =
      if project || context[:projects] not in [nil, %{}], do: project(context, project).id

    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "thread.create",
            "threadId" => id,
            "projectId" => project_id,
            "title" => title,
            "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
          },
          fields
        )
      )

    await_row(id, & &1)
    put_in(context, [:threads, title], id)
  end

  @doc "A thread's id by title."
  def thread_id(context, title) do
    (context[:threads] || %{})[title] || flunk("no thread #{inspect(title)} in this scenario")
  end

  @doc "A thread's current entity (the `thread` row of its stream)."
  def thread(context, title) do
    id = thread_id(context, title)
    HalC2.StreamState.get(HalC2.Streams.Server.state(HalC2.Streams.ensure(id)), "thread")[id]
  end

  @doc "A thread's sidebar row."
  def row(context, title) do
    case HalC2.Shell.row(node(), thread_id(context, title)) do
      {_kind, row} -> row
      nil -> nil
    end
  end

  @doc "Patches fields of a thread entity directly, as test setup (backdating activity, say)."
  def patch_thread(context, title, fields),
    do: put_entity(context, title, "thread", thread_id(context, title), %{"s" => fields})

  @doc """
  Commits one entity patch (`%{"s" => fields}` or `HalC2.Patch.delete/0`) to a thread's
  stream and waits until the sidebar row reflects it.
  """
  def put_entity(context, title, kind, id, patch) do
    thread = thread_id(context, title)
    before = System.os_time(:millisecond)
    {:ok, _} = HalC2.Streams.commit(thread, :thread, [{kind, id, patch}])
    await_row(thread, &(HalC2.Projection.JS.epoch_ms(&1["updatedAt"]) >= before))
    context
  end

  @doc "Adds a user or assistant message to a thread at `at` (ISO), as if sent then."
  def add_message(context, title, role, text, at \\ nil, extra \\ %{}) do
    at = at || iso_from_now(0)
    id = extra["id"] || "msg-#{System.unique_integer([:positive])}"

    message =
      Map.merge(
        %{
          "createdBy" => if(role == "user", do: "user", else: "agent"),
          "creationSource" => if(role == "user", do: "web", else: "provider"),
          "id" => id,
          "threadId" => thread_id(context, title),
          "runId" => nil,
          "nodeId" => nil,
          "role" => role,
          "text" => text,
          "attachments" => [],
          "streaming" => false,
          "createdAt" => at,
          "updatedAt" => at
        },
        extra
      )

    put_entity(context, title, "message", id, %{"s" => message})
  end

  @doc "Adds a run in `status` to a thread (`requestedAt`/`startedAt`/`completedAt` from `at`)."
  def add_run(context, title, status, at \\ nil, extra \\ %{}) do
    at = at || iso_from_now(0)
    id = "run-#{System.unique_integer([:positive])}"
    done? = status in ~w(completed failed interrupted cancelled)

    run =
      Map.merge(
        %{
          "id" => id,
          "threadId" => thread_id(context, title),
          "ordinal" => System.unique_integer([:positive, :monotonic]),
          "providerInstanceId" => "codex",
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
          "providerThreadId" => nil,
          "userMessageId" => nil,
          "rootNodeId" => nil,
          "activeAttemptId" => nil,
          "status" => status,
          "queuePosition" => nil,
          "requestedAt" => at,
          "startedAt" => if(status == "starting", do: nil, else: at),
          "completedAt" => if(done?, do: at, else: nil),
          "checkpointId" => nil,
          "contextHandoffId" => nil
        },
        extra
      )

    put_entity(context, title, "run", id, %{"s" => run})
  end

  @doc "Waits until a stream's sidebar row satisfies `fun`; the test process must be subscribed to the shell."
  def await_row(id, fun, timeout \\ 2_000) do
    case HalC2.Shell.row(node(), id) do
      {_kind, row} -> if fun.(row), do: row, else: await_next_row(id, fun, timeout)
      nil -> await_next_row(id, fun, timeout)
    end
  end

  defp await_next_row(id, fun, timeout) do
    receive do
      {:hal_c2_shell, {:rows, _, rows}} ->
        case List.keyfind(rows, id, 0) do
          {^id, {_kind, row}} -> if fun.(row), do: row, else: await_next_row(id, fun, timeout)
          nil -> await_next_row(id, fun, timeout)
        end
    after
      timeout -> flunk("#{id}'s row never changed as expected")
    end
  end

  @doc "The named socket, opened with the node's own token on first use."
  def client(context, name \\ "default") do
    case context.clients[name] do
      nil -> Node.connect(context.node)
      client -> client
    end
  end

  def put_client(context, name \\ "default", client),
    do: put_in(context, [:clients, name], client)

  @doc "Calls an RPC on the named socket and stores the socket back; returns `{reply, context}`."
  def call(context, method, payload \\ %{}, name \\ "default") do
    {reply, client} = Node.call(client(context, name), context.node.environment, method, payload)
    {reply, put_client(context, name, client)}
  end

  @doc "Like `call/4`, asserting success; returns `{result, context}`."
  def call!(context, method, payload \\ %{}, name \\ "default") do
    case call(context, method, payload, name) do
      {{:ok, result}, context} -> {result, context}
      {{:error, error, detail}, _} -> flunk("#{method} failed: #{error} #{inspect(detail)}")
    end
  end

  @doc "Dispatches an orchestration command over the socket; returns `{reply, context}`."
  def dispatch(context, command, name \\ "default") do
    command = Map.put_new(command, "commandId", "cmd-#{System.unique_integer([:positive])}")
    call(context, "orchestration.dispatchCommand", command, name)
  end

  @doc "A fresh git repository with one commit on `main`, under the scenario's home."
  def git_repo(context, name \\ "repo") do
    root = Node.tmp_dir(context.node, name)
    git!(root, ~w(init -q -b main))
    git!(root, ~w(config user.email hal-c2@example.com))
    git!(root, ~w(config user.name HAL-C2))
    File.write!(Path.join(root, "README.md"), "# #{name}\n")
    git!(root, ~w(add README.md))
    git!(root, ~w(commit -q -m init))
    root
  end

  def git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(out)
  end

  @doc "An ISO-8601 time `ms` milliseconds from now (negative for the past)."
  def iso_from_now(ms),
    do: DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()

  def days(n), do: n * 24 * 60 * 60 * 1_000

  def slug(title), do: title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  @doc """
  Waits until `fun`, given a thread stream's `HalC2.StreamState`, returns something
  other than `nil`/`false`, and returns that. Subscribes the test process to the
  stream and re-checks on each of its commits.
  """
  def await_stream(stream_id, fun, timeout \\ 5_000) do
    :ok = HalC2.Streams.subscribe(stream_id, self(), nil)
    check_stream(stream_id, fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp check_stream(id, fun, deadline) do
    case fun.(HalC2.Streams.Server.state(HalC2.Streams.ensure(id))) do
      done when done in [nil, false] ->
        receive do
          {:hal_c2_stream, ^id, _} -> check_stream(id, fun, deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            flunk("#{id}'s stream never reached the expected state")
        end

      value ->
        value
    end
  end

  @doc """
  Deep-merges `patch` into the node's settings document and saves it, starting
  `HalC2.Settings` if the scenario has not yet. Returns the context.
  """
  def update_settings(context, patch) do
    Node.ensure(HalC2.Settings)
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(deep_merge(settings, patch), version)
    context
  end

  @doc "Merges nested maps, `b` winning; non-map values are replaced."
  def deep_merge(a, b) when is_map(a) and is_map(b),
    do: Map.merge(a, b, fn _, x, y -> deep_merge(x, y) end)

  def deep_merge(_a, b), do: b

  @doc """
  Gives the node the device tools the way `HalC2.DevicesTest` does: the pinned hub
  and agent-device fakes installed under the node's home (`hub:` picks another
  hub version, `nil` leaves it out) and a fake Android SDK on `ANDROID_HOME`,
  restored when the scenario ends. Starts `HalC2.Settings`; returns the context.
  """
  def fake_device_tools(context, opts \\ []) do
    support = Path.expand(".", __DIR__)
    home = context.node.home

    install = fn name, version, entry, fake ->
      root = Path.join([home, "tools", name, version])
      fake_tool(Path.join([root, "node_modules", name | entry]), Path.join(support, fake))
      File.write!(Path.join(root, ".install-complete"), version <> "\n")
    end

    if hub = Keyword.get(opts, :hub, "0.10.1"),
      do: install.("expo-device-hub", hub, ~w(dist server cli.mjs), "fake_device_hub.mjs")

    install.("agent-device", "0.21.12", ~w(bin agent-device.mjs), "fake_agent_device.mjs")

    sdk = Path.join(home, "sdk")
    fake_tool(Path.join([sdk, "platform-tools", "adb"]), Path.join(support, "fake_adb.sh"))
    fake_tool(Path.join([sdk, "emulator", "emulator"]), Path.join(support, "fake_emulator.sh"))

    fake_tool(
      Path.join([sdk, "cmdline-tools", "latest", "bin", "avdmanager"]),
      Path.join(support, "fake_emulator.sh")
    )

    put_env("ANDROID_HOME", sdk)
    Node.ensure(HalC2.Settings)
    context
  end

  @doc "Sets an OS environment variable for the rest of the scenario, restoring it after."
  def put_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  defp fake_tool(path, source) do
    File.mkdir_p!(Path.dirname(path))
    File.cp!(source, path)
    File.chmod!(path, 0o755)
  end

  @doc """
  Puts `test/support/fake_text_cli.py` in place of the text generation CLIs in
  `clis` (`:claude`, `:codex`); the others are missing. Each call is logged for
  `text_calls/1`. Restored when the scenario ends; returns the context.
  """
  def fake_text_clis(context, clis) do
    fake = Path.expand("fake_text_cli.py", __DIR__)

    for {cli, key} <- [claude: :text_claude_command, codex: :text_codex_command] do
      previous = Application.fetch_env(:hal_c2, key)
      Application.put_env(:hal_c2, key, if(cli in clis, do: fake, else: "hal-c2-test-no-#{cli}"))

      ExUnit.Callbacks.on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end)
    end

    put_env("FAKE_TEXT_LOG", Path.join(context.node.home, "text-calls.jsonl"))
    Node.ensure(HalC2.Settings)
    context
  end

  @doc "The text generation calls made so far: `%{\"argv\", \"cwd\", \"prompt\"}` each."
  def text_calls(context) do
    case File.read(Path.join(context.node.home, "text-calls.jsonl")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  @doc """
  Adds resource samples to `HalC2.Diagnostics` as if taken `ages` ms ago (newest
  first is not required), each a copy of the latest sample's process tree with
  `cpu` percent on the node's own process. Test setup for history that would
  otherwise take real minutes to collect.
  """
  def add_resource_samples(ages, cpu \\ 0.0) do
    now = System.system_time(:millisecond)

    :sys.replace_state(HalC2.Diagnostics, fn state ->
      [{_, rows} | _] = state.samples
      rows = Enum.map(rows, &if(&1.depth == 0, do: %{&1 | cpu: cpu}, else: &1))
      old = for age <- ages, do: {now - age, rows}
      %{state | samples: Enum.sort_by(state.samples ++ old, &elem(&1, 0), :desc)}
    end)

    :ok
  end

  @doc """
  Closes the named socket, as a client going offline, and drops what it had
  left in the mailbox (a later `Node.connect/2` reads the mailbox while upgrading).
  """
  def disconnect(context, name \\ "default") do
    case context.clients[name] do
      nil ->
        context

      client ->
        socket = Mint.HTTP.get_socket(client.conn)
        Mint.HTTP.close(client.conn)
        flush_socket(socket)
        %{context | clients: Map.delete(context.clients, name)}
    end
  end

  defp flush_socket(socket) do
    receive do
      {tag, ^socket, _} when tag in [:tcp, :ssl] -> flush_socket(socket)
      {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] -> flush_socket(socket)
    after
      0 -> :ok
    end
  end

  @doc """
  Imports agent history into the scenario's project with `agentSessions.import`,
  first creating the project at `context.import_root` when the scenario has none.
  Stores the result as `context.import_result` and `context.reply`.
  """
  def import_agent_sessions(context) do
    context =
      if (context[:projects] || %{}) == %{},
        do: create_project(context, "imported", %{"workspaceRoot" => context.import_root}),
        else: context

    {result, context} =
      call!(context, "agentSessions.import", %{"projectId" => project(context).id})

    Map.merge(context, %{import_result: result, reply: {:ok, result}})
  end

  @doc "Sets a `:hal_c2` application env key for the rest of the scenario, restoring it after."
  def put_app_env(key, value) do
    previous = Application.fetch_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:hal_c2, key, value)
        :error -> Application.delete_env(:hal_c2, key)
      end
    end)
  end

  @doc """
  Gives a project an `origin` on "github.com" (a bare repository under the
  node's home) with `main` pushed and `origin/HEAD` set, so the node knows the
  default branch and asks `gh` about its pull requests. Returns the context.
  """
  def github_origin(context, project \\ nil) do
    %{id: id, root: root} = project(context, project)
    origin = Path.join([context.node.home, "github.com", "acme", "#{id}.git"])
    File.mkdir_p!(Path.dirname(origin))
    git!(context.node.home, ["init", "-q", "--bare", "-b", "main", origin])
    git!(root, ["remote", "add", "origin", origin])
    git!(root, ~w(push -q origin main))
    git!(root, ~w(fetch -q origin))
    git!(root, ~w(remote set-head origin main))
    context
  end

  @doc """
  Creates the thread `title` on its own worktree, a new branch `hal-c2/<slug>` off
  `main` under `<home>/worktrees` as the node makes them, and records it as
  `context.worktree` (`%{thread, path, branch, root}`). `fields` go on the
  thread; `"branch"` and `"worktreePath"` there reuse an existing worktree. A
  missing `project` is created (with none named and none yet, "api").
  """
  def worktree_thread(context, title, project \\ nil, fields \\ %{}) do
    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Vcs.Registry},
        id: HalC2.Vcs.Registry
      )
    )

    # A project named but not yet made, or the scenario's first ("api"), is created.
    context =
      cond do
        project && is_nil((context[:projects] || %{})[project]) ->
          create_project(context, project)

        is_nil(project) and context[:projects] in [nil, %{}] ->
          create_project(context, "api")

        true ->
          context
      end

    %{root: root} = project(context, project)
    branch = fields["branch"] || "hal-c2/#{slug(title)}"

    path =
      fields["worktreePath"] ||
        (
          {:ok, %{"worktree" => %{"path" => path}}} =
            HalC2.Vcs.create_worktree(%{
              "cwd" => root,
              "refName" => "main",
              "newRefName" => branch
            })

          path
        )

    fields = Map.merge(%{"branch" => branch, "worktreePath" => path}, fields)

    context
    |> create_thread(title, project, fields)
    |> Map.put(:worktree, %{thread: title, path: path, branch: branch, root: root})
  end

  @doc """
  Starts `HalC2.StorageCleanup` and what it reads (settings, the provider session
  and VCS registries) if the scenario has not, with its hourly timer off so
  only the scenario sweeps. Returns the context.
  """
  def start_storage_cleanup(context) do
    unless Process.whereis(HalC2.StorageCleanup), do: put_app_env(:storage_cleanup_first_ms, nil)
    Node.ensure(HalC2.Settings)

    for name <- [
          HalC2.Codex.Registry,
          HalC2.Claude.Registry,
          HalC2.Acp.Registry,
          HalC2.Vcs.Registry
        ],
        do: Node.ensure(Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name))

    Node.ensure(HalC2.StorageCleanup)
    context
  end

  @doc "Runs one storage sweep now and waits for it (`start_storage_cleanup/1` first)."
  def sweep_storage(context) do
    context = start_storage_cleanup(context)
    :ok = HalC2.StorageCleanup.sweep()
    context
  end

  @doc """
  Opens a real terminal shell (`/bin/sh`) for `thread_id` in `cwd`, starting the
  terminal services if needed. Returns the shell's OS pid, killed when the
  scenario ends.
  """
  def open_terminal(thread_id, cwd, terminal_id \\ "term-1") do
    put_env("SHELL", "/bin/sh")

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Terminal.Registry},
        id: HalC2.Terminal.Registry
      )
    )

    Node.ensure({DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one})
    Node.ensure(HalC2.Terminal.Hub)

    {:ok, %{"pid" => shell}} =
      HalC2.Terminal.open(%{"threadId" => thread_id, "terminalId" => terminal_id, "cwd" => cwd})

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-9", "#{shell}"], stderr_to_stdout: true)
    end)

    shell
  end

  @doc "The output tokens a usage summary counts for `provider` across its buckets."
  def usage_output(summary, provider) do
    for(b <- summary["buckets"], b["provider"] == provider, do: b["totals"]["outputTokens"])
    |> Enum.sum()
  end

  @doc """
  Like `call/4`, but frames the node pushed before the reply (a `config.providers`
  after a refresh, rows a command wrote) stay in the socket's inbox to be received.
  """
  def call_keeping(context, method, payload \\ %{}, name \\ "default") do
    id = System.unique_integer([:positive])
    client = Node.rpc(client(context, name), context.node.environment, id, method, payload)
    {frame, skipped, client} = HalC2.Test.WsClient.recv_until(client, Node.reply?(id))
    client = %{client | inbox: skipped ++ client.inbox}

    reply =
      case frame do
        %{"t" => "rpc.result", "result" => result} -> {:ok, result}
        %{"t" => "rpc.error", "error" => error} -> {:error, error, frame["detail"]}
      end

    {reply, put_client(context, name, client)}
  end

  # --- source control (added by W5) ---------------------------------------------------

  @fake_cli Path.expand("fake_gh.py", __DIR__)

  @doc """
  Puts fake host CLIs (`gh`, `glab`, `tea`, `az`, `jj`, ...) first on the PATH for
  this scenario: each is `test/support/fake_gh.py` under that name, answering from
  the rules `cli_rules/2` adds and logging every call for `cli_calls/2`. The real
  PATH, `:gh_command` and fake env vars come back when the scenario ends. Calling it
  again adds tools to the same fake bin directory.
  """
  def fake_cli(context, tools \\ ["gh"]) do
    cli = context[:cli] || start_fake_cli(context)
    for tool <- tools, do: File.ln_s(@fake_cli, Path.join(cli.bin, tool))
    Map.put(context, :cli, cli)
  end

  defp start_fake_cli(context) do
    dir = Node.tmp_dir(context.node, "cli")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    rules = Path.join(dir, "rules.json")
    log = Path.join(dir, "calls.jsonl")
    File.write!(rules, "[]")
    File.write!(log, "")

    previous = %{
      path: System.get_env("PATH"),
      gh: Application.get_env(:hal_c2, :gh_command),
      rules: System.get_env("FAKE_GH_RULES"),
      log: System.get_env("FAKE_GH_LOG")
    }

    System.put_env("PATH", bin <> ":" <> previous.path)
    Application.put_env(:hal_c2, :gh_command, "gh")
    System.put_env("FAKE_GH_RULES", rules)
    System.put_env("FAKE_GH_LOG", log)

    ExUnit.Callbacks.on_exit(fn ->
      System.put_env("PATH", previous.path)
      restore_env("FAKE_GH_RULES", previous.rules)
      restore_env("FAKE_GH_LOG", previous.log)

      if previous.gh,
        do: Application.put_env(:hal_c2, :gh_command, previous.gh),
        else: Application.delete_env(:hal_c2, :gh_command)
    end)

    Node.ensure(HalC2.PullRequests.Refreshes)
    HalC2.PullRequests.invalidate(%{})
    %{bin: bin, rules: rules, log: log}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  @doc """
  Adds rules for the fake CLIs (see `test/support/fake_gh.py`) ahead of the ones
  already there, so a later step overrides an earlier one. Starts `fake_cli/1` if
  the scenario has none yet.
  """
  def cli_rules(context, rules) do
    context = if context[:cli], do: context, else: fake_cli(context)
    existing = context.cli.rules |> File.read!() |> Jason.decode!()
    File.write!(context.cli.rules, Jason.encode!(List.wrap(rules) ++ existing))
    context
  end

  @doc "The fake CLI calls so far whose joined args contain `fragment`, as `%{cmd, args, stdin, cwd}` maps."
  def cli_calls(context, fragment \\ "") do
    context.cli.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(Enum.join(&1["args"], " ") =~ fragment))
  end

  @doc """
  Makes `tool` impossible to find: its fake goes, `gh` is looked up under a name
  that does not exist (`:gh_command`), and other tools lose the PATH entries
  outside the system directories that hold them.
  """
  def remove_cli(context, tool) do
    context = if context[:cli], do: context, else: fake_cli(context, [])
    File.rm(Path.join(context.cli.bin, tool))

    if tool == "gh" do
      Application.put_env(:hal_c2, :gh_command, "hal-c2-test-no-gh")
    else
      path =
        System.get_env("PATH")
        |> String.split(":")
        |> Enum.reject(
          &(&1 not in [context.cli.bin, "/usr/bin", "/bin"] and
              File.exists?(Path.join(&1, tool)))
        )
        |> Enum.join(":")

      System.put_env("PATH", path)
    end

    HalC2.PullRequests.invalidate(%{})
    context
  end

  @doc """
  Gives the repository at `root` a bare `origin` it has pushed `main` (or its
  current branch) to, and returns the origin's path.
  """
  def git_remote(context, root, name \\ "origin") do
    origin = Path.join(Node.tmp_dir(context.node, "origin"), "#{name}.git")
    git!(Path.dirname(origin), ["init", "-q", "--bare", "-b", "main", origin])
    git!(root, ["remote", "add", name, origin])
    branch = git!(root, ~w(branch --show-current))
    git!(root, ["push", "-q", "-u", name, branch])
    git!(root, ["remote", "set-head", name, branch])
    origin
  end

  @doc """
  Makes the repository at `root` look hosted on GitHub as `owner/repo`: its
  `origin` is `git@github.com:owner/repo.git`, and a fake `GIT_SSH_COMMAND` serves
  that from a bare repository on disk, so push, fetch and ls-remote work while
  `git remote -v` still names GitHub. Returns the bare repository's path.
  """
  def github_remote(context, root, repository) do
    remotes = context[:fake_remotes] || fake_remotes(context)
    bare = Path.join(remotes, "#{repository}.git")

    unless File.dir?(bare) do
      File.mkdir_p!(Path.dirname(bare))
      git!(remotes, ["init", "-q", "--bare", "-b", "main", bare])
    end

    git!(root, ["remote", "add", "origin", "git@github.com:#{repository}.git"])
    branch = git!(root, ~w(branch --show-current))
    git!(root, ["push", "-q", "-u", "origin", branch])
    git!(root, ["remote", "set-head", "origin", branch])
    bare
  end

  defp fake_remotes(context) do
    dir = Node.tmp_dir(context.node, "remotes")
    ssh = Path.join(dir, "fake-ssh")

    File.write!(
      ssh,
      ~s(#!/bin/sh\nfor last; do :; done\ncd "$HAL_C2_FAKE_REMOTES" && exec sh -c "$last"\n)
    )

    File.chmod!(ssh, 0o755)
    previous = {System.get_env("GIT_SSH_COMMAND"), System.get_env("HAL_C2_FAKE_REMOTES")}
    System.put_env("GIT_SSH_COMMAND", ssh)
    System.put_env("HAL_C2_FAKE_REMOTES", dir)

    ExUnit.Callbacks.on_exit(fn ->
      restore_env("GIT_SSH_COMMAND", elem(previous, 0))
      restore_env("HAL_C2_FAKE_REMOTES", elem(previous, 1))
    end)

    dir
  end

  @doc "Writes `files` (path → content) under `root` and commits only them with `message`; returns the sha."
  def commit!(root, files, message) do
    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), content)
    end

    git!(root, ["add", "--" | Map.keys(files)])
    git!(root, ["commit", "-q", "-m", message, "--" | Map.keys(files)])
    git!(root, ~w(rev-parse HEAD))
  end

  @doc """
  Runs a stacked git action (`commit`, `push`, `create_pr`, `commit_push`,
  `commit_push_pr`) over the `gitAction` shape in `cwd` and collects its progress
  events until it finishes or fails. Returns `{events, context}`; the last event
  is `action_finished` or `action_failed`.
  """
  def git_action(context, cwd, action, extra \\ %{}, name \\ "default") do
    id = System.unique_integer([:positive])

    input =
      Map.merge(%{"actionId" => "act-#{id}", "cwd" => cwd, "action" => action}, extra)

    client =
      Node.sub(client(context, name), id, %{
        "type" => "gitAction",
        "node" => Atom.to_string(node()),
        "input" => input
      })

    {events, client} = git_action_events(client, id, [])
    client = Node.unsub(client, id)
    {events, put_client(context, name, client)}
  end

  defp git_action_events(client, id, acc) do
    {frame, client} = Node.await(client, &(&1["t"] == "gitAction" and &1["id"] == id), 10_000)
    acc = [frame["event"] | acc]

    if frame["event"]["kind"] in ["action_finished", "action_failed"],
      do: {Enum.reverse(acc), client},
      else: git_action_events(client, id, acc)
  end

  @doc """
  Creates the project `repository` (`owner/repo`, also its title) rooted at a git
  repository whose `origin` is that GitHub repository (`github_remote/3`), with a
  fake `gh` signed in as `monalisa`. Sets `context.cwd` to its root.
  """
  def github_project(context, repository) do
    context = create_project(context, repository)
    %{root: root} = project(context, repository)
    github_remote(context, root, repository)

    context
    |> cli_rules([%{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "monalisa"}}])
    |> Map.put_new(:cwd, root)
  end

  @doc """
  Makes the model that writes commit messages, PR descriptions and branch names
  answer with `script` (a `/bin/sh` body that reads the prompt on stdin), as the
  `claude` text CLI, until the scenario ends.
  """
  def fake_writer(context, script) do
    path = Path.join(Node.tmp_dir(context.node, "writer"), "claude")
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o755)
    previous = Application.get_env(:hal_c2, :text_claude_command)
    Application.put_env(:hal_c2, :text_claude_command, path)
    ExUnit.Callbacks.on_exit(fn -> restore_app_env(:text_claude_command, previous) end)
    Node.ensure(HalC2.Settings)
    context
  end

  @doc """
  The failure message of the last git action (`context.git_events`), or else the
  error of the last RPC (`context.reply`, its `detail` when it has one).
  """
  def failure(context) do
    case context[:git_events] do
      [_ | _] = events ->
        last = List.last(events)
        assert last["kind"] == "action_failed", "expected a failure, got #{inspect(last)}"
        last["message"]

      _ ->
        assert {:error, error, detail} = context[:reply],
               "expected a failure, got #{inspect(context[:reply])}"

        (detail || %{})["detail"] || error
    end
  end

  # Puts an app env key back as it was; one that was unset stays unset (a nil value
  # would override `Application.get_env/3` defaults in later scenarios).
  defp restore_app_env(key, nil), do: Application.delete_env(:hal_c2, key)
  defp restore_app_env(key, value), do: Application.put_env(:hal_c2, key, value)

  @doc "Deep-merges `patch` into the node's settings (starting `HalC2.Settings` if needed)."
  def put_settings(context, patch), do: update_settings(context, patch)

  @doc """
  Writes the node's log (warnings and up) to a file for the rest of the scenario
  and returns the context with `:log` set to its path; read it with `logged/1`.
  """
  def capture_log(context) do
    path = Path.join(Node.tmp_dir(context.node, "log"), "node.log")
    id = :"hal_c2_test_log_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, :logger_std_h, %{config: %{file: String.to_charlist(path)}})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
    Map.put(context, :log, {id, path})
  end

  @doc "What the node has logged since `capture_log/1`."
  def logged(%{log: {id, path}}) do
    :logger_std_h.filesync(id)
    File.read!(path)
  end

  @fake_codex Path.expand("fake_codex.py", __DIR__)

  @doc """
  Sends `text` to a thread and waits until the turn it starts completes, played by
  `test/support/fake_codex.py` (a text "write NAME" makes the agent create NAME in the
  thread's checkout). Returns the context; the thread's newest run is `context.last_run`.
  """
  def run_turn(context, title, text) do
    fake_codex()
    id = thread_id(context, title)
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    done = completed_runs(id)

    {{:ok, _}, context} =
      dispatch(context, %{
        "type" => "message.dispatch",
        "threadId" => id,
        "messageId" => "msg-#{System.unique_integer([:positive])}",
        "text" => text,
        "attachments" => [],
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    Map.put(context, :last_run, await_completed_run(id, length(done)))
  end

  # The fake Codex app server plays the agent until the scenario ends.
  defp fake_codex do
    Node.ensure({Registry, keys: :unique, name: HalC2.Codex.Registry})
    Node.ensure({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    unless Application.get_env(:hal_c2, :codex_command) == ["python3", "-u", @fake_codex] do
      previous = Application.get_env(:hal_c2, :codex_command)
      Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:hal_c2, :codex_command, previous),
          else: Application.delete_env(:hal_c2, :codex_command)
      end)
    end
  end

  defp completed_runs(id) do
    HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
    |> HalC2.StreamState.list("run")
    |> Enum.filter(&(&1["status"] == "completed"))
  end

  defp await_completed_run(id, before) do
    receive do
      {:hal_c2_stream, ^id, _} ->
        case completed_runs(id) do
          runs when length(runs) > before -> Enum.max_by(runs, & &1["ordinal"])
          _ -> await_completed_run(id, before)
        end
    after
      10_000 -> flunk("the turn in #{id} never completed")
    end
  end

  @doc """
  Subscribes the named socket to the git status of `cwd` (the `vcs` shape a client
  showing a thread opens) and waits for its snapshot. Sets `context.vcs` to
  `%{id, cwd, name, local, remote}`.
  """
  def watch_vcs(context, cwd, name \\ "default") do
    id = System.unique_integer([:positive])
    shape = %{"type" => "vcs", "node" => Atom.to_string(node()), "cwd" => cwd}
    client = Node.sub(client(context, name), id, shape)
    {frame, client} = Node.await(client, &(&1["t"] == "vcs" and &1["id"] == id), 10_000)
    assert %{"_tag" => "snapshot", "local" => local, "remote" => remote} = frame["event"]

    context
    |> put_client(name, client)
    |> Map.put(:vcs, %{id: id, cwd: cwd, name: name, local: local, remote: remote})
  end

  @doc """
  Waits for the `watch_vcs/3` subscription's next status event satisfying `fun`
  (given the `VcsStatusStreamEvent`); returns `{event, context}`.
  """
  def await_vcs(context, fun, timeout \\ 5_000) do
    %{id: id, name: name} = context.vcs

    {frame, client} =
      Node.await(
        client(context, name),
        &(&1["t"] == "vcs" and &1["id"] == id and fun.(&1["event"])),
        timeout
      )

    {frame["event"], put_client(context, name, client)}
  end

  @doc """
  POSTs `body` as JSON to the node's HTTP `path` with a paired client's bearer token
  (standard scopes); returns `{status, decoded_body}`.
  """
  def http_post(context, path, body) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, token, _, _} = HalC2.Auth.exchange(HalC2.Auth.create_pairing_token(context.node.store))
    url = ~c"http://127.0.0.1:#{context.node.port}#{path}"
    headers = [{~c"authorization", ~c"Bearer " ++ to_charlist(token)}]

    {:ok, {{_, status, _}, _, resp}} =
      :httpc.request(:post, {url, headers, ~c"application/json", JSON.encode!(body)}, [],
        body_format: :binary
      )

    {status, JSON.decode!(resp)}
  end

  @doc """
  Launches a thread in `project` (a title, or nil for the only one) into a new
  worktree of `main` (`orchestration.launchThread`), with `text` as its first
  message and `strategy` merged into its `worktree` workspace strategy. Starts what
  that needs first: `HalC2.WorktreeSetup`, terminals, and the fake Codex agent. Sets
  `context.setup_thread`, and `context.setup_snapshots` to the setup snapshots seen
  so far, oldest first (`await_setup/3` adds to them).
  """
  def launch_in_worktree(context, project \\ nil, text \\ "list the files", strategy \\ %{}) do
    worktree_services()
    thread_id = "th-worktree-#{System.unique_integer([:positive])}"
    HalC2.WorktreeSetup.subscribe(thread_id, self())
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {_, context} =
      call!(context, "orchestration.launchThread", %{
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => project(context, project).id,
        "title" => "Work",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => Map.merge(%{"type" => "worktree", "baseRef" => "main"}, strategy),
        "initialMessage" => %{"messageId" => "m1", "text" => text, "attachments" => []}
      })

    Map.merge(context, %{setup_thread: thread_id, setup_snapshots: []})
  end

  @doc """
  Starts what preparing and working in a new worktree needs: `HalC2.WorktreeSetup`,
  terminals (a setup script runs in one), and the fake Codex agent.
  """
  def worktree_services do
    Node.ensure(HalC2.Settings)
    Node.ensure(HalC2.Workspace)
    Node.ensure({Registry, keys: :unique, name: HalC2.Terminal.Registry})

    Node.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
        id: :terminal_sup
      )
    )

    Node.ensure(HalC2.Terminal.Hub)
    Node.ensure(HalC2.WorktreeSetup)
    fake_codex()
  end

  @doc """
  The first setup snapshot of `context.setup_thread` matching `pred`, among those
  seen or arriving next; returns `{snapshot, context}` with every snapshot received
  on the way kept in `context.setup_snapshots`.
  """
  def await_setup(context, pred, timeout \\ 15_000) do
    thread_id = context.setup_thread

    case Enum.find(context.setup_snapshots, pred) do
      nil ->
        receive do
          {:hal_c2_worktree_setup, ^thread_id, snapshot} ->
            context
            |> Map.update!(:setup_snapshots, &(&1 ++ [snapshot]))
            |> await_setup(pred, timeout)
        after
          timeout ->
            flunk("the setup never got there: #{inspect(List.last(context.setup_snapshots))}")
        end

      snapshot ->
        {snapshot, context}
    end
  end

  @doc "The status of the stage `id` in a setup snapshot (nil when it has no such stage)."
  def setup_stage(snapshot, id),
    do: Enum.find_value(snapshot["stages"], &(&1["id"] == id && &1["status"]))

  @doc "The paths of the worktrees git lists for the checkout at `root`."
  def worktrees(root) do
    for "worktree " <> path <- String.split(git!(root, ~w(worktree list --porcelain)), "\n"),
        do: path
  end

  # --- agents (added by W1) ------------------------------------------------------------

  @support Path.expand(".", __DIR__)

  @doc """
  Lets the node run turns with the fake provider CLIs in `test/support`
  (`fake_codex.py`, `fake_claude.py`, `fake_acp.py` for OpenCode and Cursor) and the
  fake text generator. Every scenario that sends a message must call this first, or
  the node would start the real CLIs. `env` is extra OS environment for the fakes;
  the fake Codex logs every request it gets and every answer to its own requests
  (see `codex_requests/2`) and refuses steers while `<home>/reject-steer` exists; the
  fake ACP agent logs its permission answers (see `acp_requests/2`). Paced fake Codex
  replies wait for gate files in `<home>/gate`.
  """
  def agents(context, env \\ %{}) do
    env =
      env
      |> Map.put_new("FAKE_CODEX_LOG", Path.join(context.node.home, "codex-requests.log"))
      |> Map.put_new("FAKE_CODEX_REJECT_STEER", Path.join(context.node.home, "reject-steer"))
      |> Map.put_new("FAKE_ACP_LOG", Path.join(context.node.home, "acp-requests.log"))
      |> Map.put_new("FAKE_CLAUDE_LOG", Path.join(context.node.home, "claude-prompts.log"))
      |> Map.put_new("FAKE_CODEX_GATE", Path.join(context.node.home, "gate"))

    fake = &["python3", "-u", Path.join(@support, &1)]
    keys = ~w(codex_command claude_command acp_commands text_codex_command text_claude_command)a
    # Put back as found: config/test.exs sets the text commands to missing CLIs, and
    # deleting them would let later scenarios reach the real `codex`/`claude`.
    previous = for key <- keys, do: {key, Application.fetch_env(:hal_c2, key)}
    Application.put_env(:hal_c2, :codex_command, fake.("fake_codex.py"))
    Application.put_env(:hal_c2, :claude_command, fake.("fake_claude.py"))

    Application.put_env(:hal_c2, :acp_commands, %{
      "opencode" => fake.("fake_acp.py"),
      "grok" => fake.("fake_acp.py"),
      "cursor" => fake.("fake_acp.py")
    })

    Application.put_env(:hal_c2, :text_codex_command, Path.join(@support, "fake_text_cli.py"))
    Application.put_env(:hal_c2, :text_claude_command, Path.join(@support, "fake_text_cli.py"))
    for {key, value} <- env, do: System.put_env(key, value)

    ExUnit.Callbacks.on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end

      for {key, _} <- env, do: System.delete_env(key)
    end)

    for name <- [HalC2.Codex.Registry, HalC2.Claude.Registry, HalC2.Acp.Registry],
        do: Node.ensure(Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name))

    Node.ensure({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    Map.put(context, :agents, true)
  end

  @doc """
  The requests the fake Codex received with `method` (\"turn/start\", say), oldest
  first. `"response"` gives the answers to its own requests as `%{"id", "result"}`.
  """
  def codex_requests(context, method), do: fake_log(context, "codex-requests.log", method)

  @doc "Like `codex_requests/2` for the fake ACP agent (only `\"response\"` is logged)."
  def acp_requests(context, method), do: fake_log(context, "acp-requests.log", method)

  defp fake_log(context, file, method) do
    case File.read(Path.join(context.node.home, file)) do
      {:ok, log} ->
        for line <- String.split(log, "\n", trim: true),
            %{"method" => ^method, "params" => params} <- [JSON.decode!(line)],
            do: params

      {:error, _} ->
        []
    end
  end

  @doc "The provider instance id for a name a feature uses (Codex, Claude, OpenCode, Cursor)."
  def instance(name) do
    case String.downcase(name) do
      "codex" -> "codex"
      "claude" <> _ -> "claudeAgent"
      "opencode" -> "opencode"
      "cursor" -> "cursor"
      other -> other
    end
  end

  @doc "A thread's live stream state (`HalC2.StreamState`); subscribes the test process to it."
  def stream(context, title) do
    id = thread_id(context, title)
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
  end

  @doc """
  The title of the thread a scenario is looking at: `context.current` (set by steps
  like "the user is looking at a thread in ..."), else the scenario's only thread.
  """
  def current(context) do
    case {context[:current], Map.keys(context[:threads] || %{})} do
      {nil, [title]} -> title
      {nil, _} -> "Current thread"
      {title, _} -> title
    end
  end

  @doc "A thread's runs, oldest first."
  def runs(context, title),
    do: context |> stream(title) |> HalC2.StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  @doc """
  Waits until `fun` holds for the thread's stream state and returns that state.
  Wakes on the stream's own commits, never on a timer.
  """
  def await_thread(context, title, fun, timeout \\ 5_000) do
    id = thread_id(context, title)
    state = stream(context, title)
    if fun.(state), do: state, else: await_stream_next(id, fun, timeout, state)
  end

  defp await_stream_next(id, fun, timeout, last) do
    receive do
      {:hal_c2_stream, ^id, _} ->
        state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
        if fun.(state), do: state, else: await_stream_next(id, fun, timeout, state)
    after
      timeout ->
        runs = last |> HalC2.StreamState.list("run") |> Enum.map(& &1["status"])
        flunk("#{id} never reached the expected state (runs: #{inspect(runs)})")
    end
  end

  @doc "Waits until the thread's runs, oldest first, have exactly these statuses."
  def await_runs(context, title, statuses, timeout \\ 5_000) do
    await_thread(
      context,
      title,
      fn state ->
        state
        |> HalC2.StreamState.list("run")
        |> Enum.sort_by(& &1["ordinal"])
        |> Enum.map(& &1["status"]) == statuses
      end,
      timeout
    )
  end

  @doc """
  Sends a user message into a thread as a client would (`message.dispatch`), queued
  after any active run unless `extra` says otherwise. Returns `{reply, context}` with
  the message id under `context.last_message_id`.
  """
  def send_message(context, title, text, extra \\ %{}) do
    context = if context[:agents], do: context, else: agents(context)
    _ = stream(context, title)
    message_id = extra["messageId"] || "msg-#{System.unique_integer([:positive])}"

    reply =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "message.dispatch",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => thread_id(context, title),
            "messageId" => message_id,
            "text" => text,
            "attachments" => [],
            "dispatchMode" => %{"type" => "queue_after_active"}
          },
          extra
        )
      )

    {reply, Map.put(context, :last_message_id, message_id)}
  end

  @doc """
  Creates `title` on `provider` (a name like "Codex") in the scenario's project and
  leaves its agent working on a turn that runs until it is interrupted or steered.
  """
  def working_thread(context, title, provider \\ "Codex") do
    context = if context[:agents], do: context, else: agents(context)
    # A thread without a project would run in the test's own checkout.
    context =
      if context[:projects] in [nil, %{}], do: create_project(context, "shop"), else: context

    context =
      if (context[:threads] || %{})[title],
        do: context,
        else:
          create_thread(context, title, nil, %{
            "modelSelection" => %{"instanceId" => instance(provider), "model" => "gpt-5.4"}
          })

    {{:ok, _}, context} = send_message(context, title, "wait for it")

    await_thread(
      context,
      title,
      &Enum.any?(HalC2.StreamState.list(&1, "run"), fn run -> run["status"] == "running" end)
    )

    # The sidebar row shows it too, as the node's restart recovery reads it.
    await_row(thread_id(context, title), &(&1["activeRunId"] != nil))
    context
  end

  @doc "A thread's queued messages as `{text, run}`, in queue order."
  def queued(context, title) do
    state = stream(context, title)
    messages = HalC2.StreamState.get(state, "message")

    state
    |> HalC2.StreamState.list("run")
    |> Enum.filter(&(&1["status"] == "queued"))
    |> Enum.sort_by(& &1["queuePosition"])
    |> Enum.map(&{messages[&1["userMessageId"]]["text"], &1})
  end

  @doc "The newest run whose user message reads `text`, or nil."
  def run_for(context, title, text) do
    state = stream(context, title)
    messages = HalC2.StreamState.get(state, "message")

    state
    |> HalC2.StreamState.list("run")
    |> Enum.filter(&(messages[&1["userMessageId"]]["text"] == text))
    |> Enum.max_by(& &1["ordinal"], fn -> nil end)
  end

  @doc "The texts of the turns the fake Codex was asked to start, in order."
  def started_turns(context),
    do:
      for(
        %{"input" => [%{"text" => text} | _]} <- codex_requests(context, "turn/start"),
        do: text
      )

  @doc """
  Sends `text` to the current thread's agent (stopping a turn it is still working on
  first) and waits for the prompt it raises, e.g. "approve run: npm test" with the fake
  providers. Returns the context with `:request_id` set to that pending request.
  """
  def request_from_agent(context, text) do
    title = current(context)
    running = Enum.find(runs(context, title), &(&1["status"] == "running"))

    if running do
      {:ok, _} =
        HalC2.Orchestration.dispatch(%{
          "type" => "run.interrupt",
          "threadId" => thread_id(context, title),
          "runId" => running["id"]
        })

      await_thread(
        context,
        title,
        &(HalC2.StreamState.get(&1, "run")[running["id"]]["status"] != "running")
      )
    end

    known = Map.keys(HalC2.StreamState.get(stream(context, title), "runtime-request"))
    {{:ok, _}, context} = send_message(context, title, text)

    pending =
      &Enum.find(HalC2.StreamState.list(&1, "runtime-request"), fn r ->
        r["status"] == "pending" and r["id"] not in known
      end)

    state = await_thread(context, title, pending)
    Map.put(context, :request_id, pending.(state)["id"])
  end

  @doc """
  Runs one finished turn per text in a thread, in order, waiting for each to complete.
  With the fake agents "write NAME" creates the file NAME in the thread's workspace.
  """
  def finished_turns(context, title, texts) do
    Enum.reduce(texts, context, fn text, context ->
      done = Enum.count(runs(context, title), &(&1["status"] == "completed"))
      {{:ok, _}, context} = send_message(context, title, text)

      await_thread(
        context,
        title,
        &(Enum.count(HalC2.StreamState.list(&1, "run"), fn r -> r["status"] == "completed" end) >
            done)
      )

      context
    end)
  end

  @doc """
  Opens the fake Codex gate `name` (see `agents/1`), with `content` for gates that
  read it ("answer from gate"). The file appears whole, so the fake never reads it half written.
  """
  def open_gate(context, name, content \\ "") do
    gate = Path.join(context.node.home, "gate")
    File.mkdir_p!(gate)
    File.write!(Path.join(gate, name <> ".tmp"), content)
    File.rename!(Path.join(gate, name <> ".tmp"), Path.join(gate, name))
    context
  end

  @doc """
  Subscribes the named socket (a device, say "phone") to the sidebar shell and skips
  its snapshot, so `await_shell_row/4` can wait on what it is pushed. Commands are
  best sent from another socket: awaiting an RPC reply drops the pushes it skips.
  """
  def watch_shell(context, name \\ "default") do
    if name in (context[:shell_watchers] || []) do
      context
    else
      client = context |> client(name) |> Node.sub(900, %{"type" => "shell"})
      {_, client} = Node.await(client, &(&1["t"] == "shell" and &1["id"] == 900))

      context
      |> put_client(name, client)
      |> Map.update(:shell_watchers, [name], &[name | &1])
    end
  end

  @doc """
  Waits for a `shell.rows` push to the named watching socket in which thread `title`'s
  row satisfies `fun`. Returns `{row, context}`.
  """
  def await_shell_row(context, name, title, fun) do
    id = thread_id(context, title)

    match = fn frame ->
      frame["t"] == "shell.rows" &&
        Enum.find_value(frame["rows"], fn
          [^id, "thread", row] -> if fun.(row), do: row
          _ -> nil
        end)
    end

    {frame, client} = Node.await(client(context, name), &match.(&1))
    {match.(frame), put_client(context, name, client)}
  end

  @doc "Thread rows by id, as a client connecting now sees them in its shell snapshot."
  def fresh_shell(context) do
    client = context.node |> Node.connect() |> Node.sub(1, %{"type" => "shell"})
    {%{"rows" => rows}, _client} = Node.await(client, &(&1["t"] == "shell"))
    for [_node, id, "thread", row] <- rows, into: %{}, do: {id, row}
  end

  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  @doc """
  The moment a phrase like "Wednesday 15:00", "tomorrow", "tomorrow 09:00" or
  "next Monday 09:00" names, as ISO text. Counted from `context.local_now` (a
  `NaiveDateTime`, set by "the local time is ...") or the clock; times are UTC. A bare
  weekday is today or the next one, "next" skips today.
  """
  def local_time(context, phrase) do
    now = context[:local_now] || NaiveDateTime.utc_now()

    [_, next, day, hour, minute] =
      (Regex.run(~r/^(next )?(\w+)(?: (\d{1,2}):(\d{2}))?$/i, phrase) ++ ["", ""])
      |> Enum.take(5)

    offset =
      case String.downcase(day) do
        "today" ->
          0

        "tomorrow" ->
          1

        weekday ->
          target = Enum.find_index(@weekdays, &(&1 == weekday)) || flunk("no day in #{phrase}")
          ahead = Integer.mod(target + 1 - Date.day_of_week(now), 7)
          if ahead == 0 and next != "", do: 7, else: ahead
      end

    time =
      if hour == "",
        do: NaiveDateTime.to_time(now),
        else: Time.new!(String.to_integer(hour), String.to_integer(minute), 0)

    now
    |> NaiveDateTime.to_date()
    |> Date.add(offset)
    |> NaiveDateTime.new!(time)
    |> DateTime.from_naive!("Etc/UTC")
    |> Map.put(:microsecond, {0, 3})
    |> DateTime.to_iso8601()
  end

  @doc """
  Launches a thread in `project` over the socket (`orchestration.launchThread`) with
  `text` as its first message, as the web client does: codex, full access, the
  project root. `fields` override the input (`"workspaceStrategy"`, `"generateTitle"`,
  `"threadId"`, `"title"`, ...). The thread is known by its title (default
  "New thread") afterwards. Returns `{reply, context}`.
  """
  def launch_thread(context, project, text, fields \\ %{}) do
    context = if context[:agents], do: context, else: agents(context)
    id = fields["threadId"] || "th-launch-#{System.unique_integer([:positive])}"
    title = fields["title"] || "New thread"
    # Subscribed first, so `await_stream/4` wakes on the launch's own commits.
    :ok = HalC2.Streams.subscribe(id, self(), nil)

    input =
      Map.merge(
        %{
          "commandId" => "cmd-#{System.unique_integer([:positive])}",
          "threadId" => id,
          "projectId" => project(context, project).id,
          "title" => title,
          "createdBy" => "user",
          "creationSource" => "web",
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
          "runtimeMode" => "full-access",
          "interactionMode" => "default",
          "workspaceStrategy" => %{"type" => "root"},
          "initialMessage" => %{
            "messageId" => "msg-#{System.unique_integer([:positive])}",
            "text" => text,
            "attachments" => []
          }
        },
        fields
      )

    {reply, context} = call(context, "orchestration.launchThread", input)

    context =
      if match?({:ok, _}, reply), do: put_in(context, [:threads, title], id), else: context

    {reply, context}
  end

  @doc """
  Scripts the fake title generator (see `agents/1`): each call takes the next of
  `answers` ("fail" fails it); with none left it titles from the first words of the
  message. Its calls are logged for `title_calls/1`, and retries are not delayed.
  """
  def title_generator(context, answers \\ []) do
    context = if context[:agents], do: context, else: agents(context)
    path = Path.join(context.node.home, "title-answers")
    File.write!(path, Enum.join(answers, "\n"))
    System.put_env("FAKE_TEXT_ANSWERS", path)
    System.put_env("FAKE_TEXT_LOG", Path.join(context.node.home, "text-calls.log"))
    Application.put_env(:hal_c2, :title_retry_ms, 10)
    Node.ensure(HalC2.Settings)

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("FAKE_TEXT_ANSWERS")
      System.delete_env("FAKE_TEXT_LOG")
      Application.delete_env(:hal_c2, :title_retry_ms)
    end)

    Map.put(context, :title_generator, true)
  end

  @doc "The prompts of the title requests the fake text generator got, oldest first."
  def title_calls(context) do
    case File.read(Path.join(context.node.home, "text-calls.log")) do
      {:ok, log} ->
        for line <- String.split(log, "\n", trim: true),
            %{"prompt" => prompt} = JSON.decode!(line),
            prompt =~ "title",
            do: prompt

      {:error, _} ->
        []
    end
  end

  @doc """
  Starts what preparing a new worktree for a launched thread needs
  (`HalC2.WorktreeSetup`, its terminals and settings).
  """
  def thread_worktrees(context) do
    Node.ensure(HalC2.Settings)
    Node.ensure(HalC2.Workspace)

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Terminal.Registry},
        id: HalC2.Terminal.Registry
      )
    )

    Node.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
        id: HalC2.Terminal.Supervisor
      )
    )

    Node.ensure(HalC2.Terminal.Hub)
    Node.ensure(HalC2.WorktreeSetup)
    context
  end

  @doc """
  Forks `source` into a new thread `title` (`thread.fork`), from its latest finished
  run unless `fields` name a `sourcePoint`, and registers it under `title`.
  """
  def fork_thread(context, source, title, fields \\ %{}) do
    id = "th-#{slug(title)}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "thread.fork",
            "commandId" => "cmd-fork-#{id}",
            "createdBy" => "user",
            "creationSource" => "web",
            "sourceThreadId" => thread_id(context, source),
            "targetThreadId" => id,
            "title" => title
          },
          fields
        )
      )

    await_row(id, & &1)
    put_in(context, [:threads, title], id)
  end

  @doc """
  The worktree setup snapshot of thread `title` once it has ended (`phase` is no
  longer "running"), waiting for it; nil when the node tracks no setup for it.
  """
  def setup_result(context, title, timeout \\ 15_000) do
    id = thread_id(context, title)

    case HalC2.WorktreeSetup.subscribe(id, self()) do
      %{"phase" => "running"} -> await_setup_end(id, timeout)
      snapshot -> snapshot
    end
  end

  defp await_setup_end(id, timeout) do
    receive do
      {:hal_c2_worktree_setup, ^id, %{"phase" => "running"}} -> await_setup_end(id, timeout)
      {:hal_c2_worktree_setup, ^id, snapshot} -> snapshot
    after
      timeout -> flunk("the worktree setup of #{id} never ended")
    end
  end

  @doc """
  The message texts the fake Claude was sent, one per turn, oldest first; after
  `log_claude_prompts/1`, every user message it received since.
  """
  def claude_prompts(%{claude_log: log}) do
    case File.read(log) do
      {:ok, text} -> for line <- String.split(text, "\n", trim: true), do: JSON.decode!(line)
      _ -> []
    end
  end

  def claude_prompts(context) do
    case File.read(Path.join(context.node.home, "claude-prompts.log")) do
      {:ok, log} ->
        for line <- String.split(log, "\n", trim: true), do: JSON.decode!(line)["text"]

      {:error, _} ->
        []
    end
  end

  # --- added by W7 ---

  @fake_claude Path.expand("fake_claude.py", __DIR__)
  @fake_acp Path.expand("fake_acp.py", __DIR__)

  @doc """
  Starts what real turns need, once per scenario: settings, the provider
  runtimes on the fake Codex, Claude and OpenCode (ACP) CLIs
  (`test/support/fake_codex.py`, `fake_claude.py`, `fake_acp.py`: a message
  containing "wait" keeps its turn running) and the MCP server. Each fake logs
  what it was sent under the node's home (`provider_inputs/1`,
  `provider_prompts/2`, `codex_methods/1`, `codex_requests/2`, `codex_sessions/1`,
  `claude_starts/1`).
  """
  def providers(context) do
    if Application.get_env(:hal_c2, :codex_command) == nil do
      log = "FAKE_CODEX_INPUT_LOG=" <> Path.join(context.node.home, "codex-inputs.jsonl")
      requests = "FAKE_CODEX_REQUEST_LOG=" <> Path.join(context.node.home, "codex-methods.log")
      sessions = "FAKE_CODEX_SESSION_LOG=" <> Path.join(context.node.home, "codex-sessions.jsonl")
      # The full requests and answers, as `codex_requests/2` reads them.
      full = "FAKE_CODEX_LOG=" <> Path.join(context.node.home, "codex-requests.log")

      Application.put_env(:hal_c2, :codex_command, [
        "env",
        log,
        requests,
        sessions,
        full,
        "python3",
        "-u",
        @fake_codex
      ])

      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :codex_command) end)
    end

    if Application.get_env(:hal_c2, :claude_command) == nil do
      log = "FAKE_CLAUDE_ARGV_LOG=" <> Path.join(context.node.home, "claude-argv.jsonl")
      input = "FAKE_CLAUDE_INPUT_LOG=" <> Path.join(context.node.home, "claude-inputs.jsonl")

      Application.put_env(:hal_c2, :claude_command, [
        "env",
        log,
        input,
        "python3",
        "-u",
        @fake_claude
      ])

      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :claude_command) end)
    end

    if Application.get_env(:hal_c2, :acp_commands) == nil do
      log = "FAKE_ACP_INPUT_LOG=" <> Path.join(context.node.home, "acp-inputs.jsonl")

      fake = ["env", log, "python3", "-u", @fake_acp]
      Application.put_env(:hal_c2, :acp_commands, %{"opencode" => fake, "grok" => fake})

      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :acp_commands) end)
    end

    for child <- [
          HalC2.Settings,
          registry(HalC2.Codex.Registry),
          registry(HalC2.Claude.Registry),
          registry(HalC2.Acp.Registry),
          Supervisor.child_spec(
            {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
            id: HalC2.Codex.Supervisor
          ),
          HalC2.Mcp
        ],
        do: Node.ensure(child)

    context
  end

  defp registry(name),
    do: Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name)

  @doc """
  Launches `title` in `project` (nil for the only one) with a first message, as
  `orchestration.launchThread` does (directly, unlike `launch_thread/4`), on the fake Codex CLI in full-access mode.
  `fields` override the launch input. Returns once the thread has its row.
  """
  def launch_titled(context, title, project, text, fields \\ %{}) do
    context = providers(context)
    id = fields["threadId"] || "th-#{slug(title)}-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(id, self(), nil)

    {:ok, _} =
      HalC2.Orchestration.launch_thread(
        Map.merge(
          %{
            "commandId" => "cmd-#{id}",
            "threadId" => id,
            "projectId" => project(context, project).id,
            "title" => title,
            "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
            "runtimeMode" => "full-access",
            "interactionMode" => "default",
            "workspaceStrategy" => %{"type" => "root"},
            "initialMessage" => %{
              "messageId" => "msg-#{id}",
              "text" => text,
              "attachments" => []
            }
          },
          fields
        )
      )

    await_row(id, & &1)
    put_in(context, [:threads, title], id)
  end

  @doc "A thread's stream state (see `HalC2.StreamState`)."
  def state(context, title),
    do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id(context, title)))

  @doc "Waits until a thread's stream state satisfies `fun` (`await_thread/4`)."
  def await_state(context, title, fun, timeout \\ 5_000),
    do: await_thread(context, title, fun, timeout)

  @doc """
  Sends one JSON-RPC request to the MCP server as the agent of `caller` (a
  thread title) on `instance`; returns `{status, body}` as `HalC2.Mcp.handle/2` does.
  Once the MCP server runs, it can be called from any process (a waiting call in
  a `Task`, say).
  """
  def mcp(context, caller, method, params \\ %{}, instance \\ "codex") do
    context = if Process.whereis(HalC2.Mcp), do: context, else: providers(context)
    %{authorization: auth} = HalC2.Mcp.server(thread_id(context, caller), instance)
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    HalC2.Mcp.handle(auth, JSON.encode!(request))
  end

  @doc """
  Calls an MCP tool as the agent of `caller`: `{:ok, structuredContent}` or
  `{:error, code, message}` from the tool's error result.
  """
  def mcp_tool(context, caller, name, arguments \\ %{}, instance \\ "codex") do
    case mcp(context, caller, "tools/call", %{"name" => name, "arguments" => arguments}, instance) do
      {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text} | _]}}} ->
        %{"code" => code, "message" => message} = JSON.decode!(text)
        {:error, code, message}

      {200, %{"result" => %{"structuredContent" => result}}} ->
        {:ok, result}

      other ->
        flunk("#{name} answered #{inspect(other)}")
    end
  end

  @doc """
  The `message.dispatch` command a client sends for `text` in a thread, starting
  immediately (queued behind an active run otherwise); `fields` override.
  """
  def message_command(context, title, text, fields \\ %{}) do
    id = System.unique_integer([:positive])

    Map.merge(
      %{
        "type" => "message.dispatch",
        "commandId" => "cmd-message-#{id}",
        "threadId" => thread_id(context, title),
        "messageId" => "msg-#{id}",
        "text" => text,
        "attachments" => [],
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "dispatchMode" => %{"type" => "start_immediately"},
        "createdBy" => "user",
        "creationSource" => "web"
      },
      fields
    )
  end

  @doc """
  What the fake Codex CLI was given as each turn's input, oldest first: one list
  of input items (`%{"type" => "text", "text" => ...}`, ...) per turn.
  """
  def provider_inputs(context) do
    case File.read(Path.join(context.node.home, "codex-inputs.jsonl")) do
      {:ok, lines} -> lines |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "The arguments of each fake Claude CLI start in this scenario, oldest first."
  def claude_starts(context) do
    case File.read(Path.join(context.node.home, "claude-argv.jsonl")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "The method of every request the fake Codex CLI got in this scenario, oldest first."
  def codex_methods(context) do
    case File.read(Path.join(context.node.home, "codex-methods.log")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  @doc """
  Sends `text` to a thread as the user, on the thread's own model selection (the
  fake Codex CLI unless the thread says otherwise), starting at once or queued
  behind an active run.
  """
  def send_turn(context, title, text, fields \\ %{}) do
    context = providers(context)
    selection = (thread(context, title) || %{})["modelSelection"]
    fields = if selection, do: Map.put_new(fields, "modelSelection", selection), else: fields
    {:ok, _} = HalC2.Orchestration.dispatch(message_command(context, title, text, fields))
    context
  end

  @doc """
  Sends `text` to a thread and waits until the run it starts has finished
  (completed, failed or interrupted); returns that run.
  """
  def finish_turn(context, title, text, timeout \\ 10_000) do
    ordinal = length(runs(context, title)) + 1
    context = send_turn(context, title, text)

    state =
      await_state(
        context,
        title,
        fn state ->
          Enum.any?(
            HalC2.StreamState.list(state, "run"),
            &(&1["ordinal"] == ordinal and &1["status"] in ~w(completed failed interrupted))
          )
        end,
        timeout
      )

    Enum.find(HalC2.StreamState.list(state, "run"), &(&1["ordinal"] == ordinal))
  end

  @doc """
  The text of each message a fake provider CLI was given in this scenario, oldest
  first: `"codex"`, `"claudeAgent"` or `"opencode"` (the fake ACP agent).
  """
  def provider_prompts(context, driver) do
    case driver do
      "codex" ->
        for input <- provider_inputs(context),
            do: Enum.map_join(input, "\n", &(&1["text"] || ""))

      driver ->
        file = if driver == "claudeAgent", do: "claude-inputs.jsonl", else: "acp-inputs.jsonl"

        case File.read(Path.join(context.node.home, file)) do
          {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
          {:error, :enoent} -> []
        end
    end
  end

  @doc """
  `text` with the scenario's thread ids and their run ids replaced by the names a
  feature gives them (`"t1"`, `"run-3"`), so refusals can be compared as written.
  """
  def named(context, text) do
    Enum.reduce(context[:threads] || %{}, text, fn {name, id}, text ->
      runs = HalC2.Streams.Server.state(HalC2.Streams.ensure(id)) |> HalC2.StreamState.list("run")

      Enum.reduce(runs, String.replace(text, id, name), fn run, text ->
        String.replace(text, run["id"], "run-#{run["ordinal"]}")
      end)
    end)
  end

  @doc """
  Starts what preparing a new worktree needs (`HalC2.WorktreeSetup` and the terminals
  its setup script runs in), with the fake providers, as `HalC2.Application` does.
  """
  def worktree_setup(context) do
    context = providers(context)

    for child <- [
          registry(HalC2.Terminal.Registry),
          Supervisor.child_spec(
            {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
            id: HalC2.Terminal.Supervisor
          ),
          HalC2.Terminal.Hub,
          HalC2.WorktreeSetup
        ],
        do: Node.ensure(child)

    context
  end

  @doc """
  Each thread/start and thread/resume the fake Codex CLI got in this scenario,
  oldest first, as `%{"method" => ..., "params" => ...}`.
  """
  def codex_sessions(context) do
    case File.read(Path.join(context.node.home, "codex-sessions.jsonl")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "Sets (or with `nil` unsets) an OS environment variable for the rest of the scenario."
  def put_os_env(name, value) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  @doc "Deep-merges `patch` into the node's settings (starting `HalC2.Settings` if needed)."
  def merge_settings(patch) do
    Node.ensure(HalC2.Settings)
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(deep_merge(settings, patch), version)
    :ok
  end

  @doc """
  Starts what a provider turn and a terminal need: the provider registries and
  supervisors, HalC2.Settings, HalC2.Terminal.Hub and HalC2.Mcp.
  """
  def provider_services do
    for {name, spec} <- [
          {HalC2.Codex.Registry, {Registry, keys: :unique, name: HalC2.Codex.Registry}},
          {HalC2.Claude.Registry, {Registry, keys: :unique, name: HalC2.Claude.Registry}},
          {HalC2.Acp.Registry, {Registry, keys: :unique, name: HalC2.Acp.Registry}},
          {HalC2.Codex.Supervisor,
           {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one}},
          {HalC2.Terminal.Registry, {Registry, keys: :unique, name: HalC2.Terminal.Registry}},
          {HalC2.Terminal.Supervisor,
           {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one}}
        ],
        do: Node.ensure(Supervisor.child_spec(spec, id: name))

    Enum.each([HalC2.Settings, HalC2.Terminal.Hub, HalC2.Mcp], &Node.ensure/1)
  end

  @doc """
  Makes Codex the fake provider (test/support/fake_codex.py) run as a process named
  `codex`, and starts `provider_services/0`. A message containing "wait" keeps its
  turn running.
  """
  def fake_codex(context) do
    provider_services()
    link = Path.join(Node.tmp_dir(context.node, "bin"), "codex")
    # The interpreter itself, not a version manager's shim that dispatches on its name.
    {python, 0} =
      System.cmd("python3", ["-c", "import os, sys; print(os.path.realpath(sys.executable))"])

    File.ln_s!(String.trim(python), link)
    fake = Path.expand("fake_codex.py", __DIR__)
    put_app_env(:codex_command, [link, "-u", fake])
    context
  end

  @doc """
  Sends `text` as the user's message in thread `title` over the socket, leaving the
  agents as the scenario set them (`send_message/4` dispatches directly and starts
  the fake agents). Returns the context.
  """
  def socket_message(context, title, text) do
    command = %{
      "type" => "message.dispatch",
      "threadId" => thread_id(context, title),
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "text" => text,
      "attachments" => []
    }

    {{:ok, _}, context} = dispatch(context, command)
    context
  end

  @doc "Waits until thread `title` has a run satisfying `fun`; flunks if a run fails instead."
  def await_run(context, title, fun) do
    id = thread_id(context, title)
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    await_run_loop(id, fun)
  end

  defp await_run_loop(id, fun) do
    runs = HalC2.StreamState.list(HalC2.Streams.Server.state(HalC2.Streams.ensure(id)), "run")

    case Enum.find(runs, fun) do
      nil ->
        failed = Enum.find(runs, &(&1["status"] == "failed"))
        if failed && not fun.(failed), do: flunk("the run failed: #{inspect(failed)}")

        receive do
          {:hal_c2_stream, ^id, _} -> await_run_loop(id, fun)
        after
          10_000 -> flunk("no run matched in #{id}: #{inspect(runs)}")
        end

      run ->
        run
    end
  end

  @doc """
  Moves thread `title`'s creation, messages and runs `ms` into the past, as if
  nothing had happened in it since, and waits for its sidebar row.
  """
  def backdate_thread(context, title, ms) do
    id = thread_id(context, title)
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
    at = iso_from_now(-ms)

    messages =
      for m <- HalC2.StreamState.list(state, "message"),
          do: {"message", m["id"], %{"s" => %{"createdAt" => at, "updatedAt" => at}}}

    runs =
      for r <- HalC2.StreamState.list(state, "run"),
          do:
            {"run", r["id"],
             %{"s" => Map.new(for(k <- ~w(requestedAt startedAt completedAt), r[k], do: {k, at}))}}

    {:ok, _} =
      HalC2.Streams.commit(
        id,
        :thread,
        [{"thread", id, %{"s" => %{"createdAt" => at}}}] ++ messages ++ runs
      )

    await_row(id, &(&1["createdAt"] == at))
    context
  end

  @doc """
  Puts a fake `gh` (test/support/fake_gh.py) first on PATH, answering by `rules`
  (see that file); returns the path of the log of its calls.
  """
  def gh_on_path(context, rules) do
    bin = Node.tmp_dir(context.node, "gh-bin")
    File.ln_s!(Path.expand("fake_gh.py", __DIR__), Path.join(bin, "gh"))
    File.write!(Path.join(bin, "rules.json"), JSON.encode!(rules))
    log = Path.join(bin, "calls.jsonl")
    put_os_env("FAKE_GH_RULES", Path.join(bin, "rules.json"))
    put_os_env("FAKE_GH_LOG", log)
    put_os_env("PATH", bin <> ":" <> System.get_env("PATH", ""))
    log
  end

  @doc """
  Calls `fun` of a mix task module (such as `run` with its argument list) and returns
  the lines it printed through `Mix.shell/0`.
  """
  def mix_output(task, fun, args \\ []) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      apply(task, fun, args)
    after
      Mix.shell(shell)
    end

    collect_mix_output([])
  end

  defp collect_mix_output(lines) do
    receive do
      {:mix_shell, :info, [line]} -> collect_mix_output([line | lines])
    after
      0 -> Enum.reverse(lines)
    end
  end

  # --- added by W8 ---

  @doc """
  Creates a thread whose id is its name (`"t1"`), as the orchestration features
  name threads, and makes it the scenario's current thread (`context.thread`).
  """
  def named_thread(context, name, project \\ nil, fields \\ %{}) do
    context
    |> create_thread(name, project, Map.put(fields, "threadId", name))
    |> Map.put(:thread, name)
  end

  @doc "A thread's entities of `kind` (`\"run\"`, `\"message\"`, ...), in stream order."
  def entities(context, title, kind), do: HalC2.StreamState.list(state(context, title), kind)

  @doc "The latest run of a thread (highest ordinal), or nil."
  def latest_run(context, title),
    do: context |> entities(title, "run") |> Enum.max_by(& &1["ordinal"], fn -> nil end)

  @doc "Waits until the thread's latest run has `status`; returns that run."
  def await_latest_run(context, title, status, timeout \\ 5_000) do
    await_state(
      context,
      title,
      fn state ->
        case Enum.max_by(HalC2.StreamState.list(state, "run"), & &1["ordinal"], fn -> nil end) do
          %{"status" => ^status} -> true
          _ -> false
        end
      end,
      timeout
    )

    latest_run(context, title)
  end

  @doc "Every change in a thread's log, oldest first (`%{seq, kind, entity, patch, at}`)."
  def events(context, title) do
    HalC2.Store.path()
    |> HalC2.Store.reduce_stream(thread_id(context, title), 0, [], &[&1 | &2])
    |> Enum.reverse()
  end

  @doc """
  Dispatches an orchestration command straight to the engine and keeps the reply
  as `context.reply` (`{:ok, result}` or `{:error, message, nil}`), as the shared
  refusal steps read it.
  """
  def command(context, command) do
    command = Map.put_new(command, "commandId", "cmd-#{System.unique_integer([:positive])}")
    Map.put(context, :reply, normalize_reply(HalC2.Orchestration.dispatch(command)))
  end

  @doc "Normalizes an engine or RPC reply to `{:ok, r}` or `{:error, message, detail}`."
  def normalize_reply({:ok, result}), do: {:ok, result}
  def normalize_reply({:error, message, detail}), do: {:error, message, detail}

  def normalize_reply({:error, %{} = detail}),
    do: {:error, to_string(detail["message"] || detail["cause"] || detail["_tag"]), detail}

  def normalize_reply({:error, message}), do: {:error, to_string(message), nil}
  def normalize_reply(:ok), do: {:ok, nil}

  @doc "Sends a user message to a thread (`message.dispatch`); the reply is `context.reply`."
  def dispatch_message(context, title, text, extra \\ %{}) do
    command(
      context,
      Map.merge(
        %{
          "type" => "message.dispatch",
          "threadId" => thread_id(context, title),
          "messageId" => "msg-#{System.unique_integer([:positive])}",
          "text" => text,
          "attachments" => []
        },
        extra
      )
    )
  end

  @fake_text Path.expand("fake_text_cli.py", __DIR__)

  @doc """
  Installs the fake text writers (`test/support/fake_text_cli.py`) as the `claude`
  and `codex` text generation CLIs named in `clis` (the others are missing), logs
  their calls for `text_calls/1`, and starts settings. `answer` (a map) replaces
  the writer's answers by key.
  """
  def text_writers(context, clis \\ [:codex, :claude], answer \\ %{}) do
    put_env("FAKE_TEXT_LOG", Path.join(context.node.home, "text-calls.jsonl"))
    put_env("FAKE_TEXT_ANSWER", JSON.encode!(answer))

    # Steps set these while the scenario runs; they end with it.
    ExUnit.Callbacks.on_exit(fn ->
      for var <- ~w(FAKE_TEXT_FAIL FAKE_TEXT_HANG), do: System.delete_env(var)
    end)

    put_app_env(
      :text_claude_command,
      if(:claude in clis, do: @fake_text, else: "hal-c2-test-no-claude")
    )

    put_app_env(
      :text_codex_command,
      if(:codex in clis, do: @fake_text, else: "hal-c2-test-no-codex")
    )

    Node.ensure(HalC2.Settings)
    Map.put(context, :text_log, true)
  end

  @doc """
  Starts a turn that keeps running (the fake provider's "wait") in the named thread,
  creating the thread first when the scenario has none by that name.
  """
  def running_turn(context, title, text \\ "wait for it") do
    context = providers(context)

    context =
      if (context[:threads] || %{})[title], do: context, else: named_thread(context, title)

    context = dispatch_message(context, title, text)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = await_latest_run(context, title, "running")
    context |> Map.delete(:reply) |> Map.put(:thread, title) |> Map.put(:running, run["id"])
  end

  @doc """
  Sends a message that queues behind the thread's active run (`queue_after_active`,
  as the composer's queue does); its run id is appended to `context.queued`.
  """
  def queue_message(context, title, text) do
    before = MapSet.new(entities(context, title, "run"), & &1["id"])

    context =
      dispatch_message(context, title, text, %{
        "dispatchMode" => %{"type" => "queue_after_active"}
      })

    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"

    [queued] =
      for run <- entities(context, title, "run"), not MapSet.member?(before, run["id"]), do: run

    assert queued["status"] == "queued"

    context
    |> Map.delete(:reply)
    |> Map.update(:queued, [queued["id"]], &(&1 ++ [queued["id"]]))
  end

  @doc """
  Whether the running step is a Given (an `And`/`But` takes the keyword before it),
  for steps whose text both arranges a state and asserts it.
  """
  def given?(context) do
    context
    |> Map.get(:step_history, [])
    |> Enum.reverse()
    |> Enum.map(&String.trim(&1.keyword))
    |> Enum.find(&(&1 in ~w(Given When Then)))
    |> Kernel.==("Given")
  end

  @doc """
  Puts run `n` of a thread in `status` as the orchestration features number runs:
  id `"run-<n>"`, ordinal `n`, root node `"node-run-<n>"`. Missing earlier runs are
  added as completed first. `extra` overrides fields.
  """
  def numbered_run(context, title, n, status, extra \\ %{}) do
    existing = MapSet.new(entities(context, title, "run"), & &1["id"])

    context =
      Enum.reduce(1..(n - 1)//1, context, fn i, context ->
        if MapSet.member?(existing, "run-#{i}"),
          do: context,
          else: put_numbered_run(context, title, i, "completed", %{})
      end)

    put_numbered_run(context, title, n, status, extra)
  end

  defp put_numbered_run(context, title, n, status, extra) do
    at = iso_from_now(0)
    done? = status in ~w(completed failed interrupted cancelled rolled_back)

    run =
      Map.merge(
        %{
          "id" => "run-#{n}",
          "threadId" => thread_id(context, title),
          "ordinal" => n,
          "providerInstanceId" => "codex",
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
          "providerThreadId" => nil,
          "userMessageId" => nil,
          "rootNodeId" => "node-run-#{n}",
          "activeAttemptId" => nil,
          "status" => status,
          "queuePosition" => nil,
          "requestedAt" => at,
          "startedAt" => if(status in ~w(queued starting), do: nil, else: at),
          "completedAt" => if(done?, do: at, else: nil),
          "checkpointId" => nil,
          "contextHandoffId" => nil
        },
        extra
      )

    put_entity(context, title, "run", run["id"], %{"s" => run})
  end

  @doc """
  Adds a turn item of `type` to a thread, in `run_id` (nil for none) on that run's
  root node, completed unless `extra` says otherwise; returns the context.
  """
  def add_item(context, title, id, type, run_id, extra \\ %{}) do
    at = iso_from_now(0)

    item =
      Map.merge(
        %{
          "id" => id,
          "threadId" => thread_id(context, title),
          "runId" => run_id,
          "nodeId" => if(run_id, do: "node-#{run_id}"),
          "providerTurnId" => nil,
          "nativeItemRef" => nil,
          "parentItemId" => nil,
          "type" => type,
          "status" => "completed",
          "ordinal" => System.unique_integer([:positive, :monotonic]),
          "startedAt" => at,
          "completedAt" => at,
          "updatedAt" => at
        },
        extra
      )

    put_entity(context, title, "turn-item", id, %{"s" => item})
  end

  @doc """
  The turn items a client's timeline shows for a thread: the stream's snapshot as a
  socket receives it, filtered by `HalC2.Projection.Timeline`. Returns `{items, context}`.
  """
  def timeline(context, title) do
    shape = %{
      "type" => "stream",
      "node" => Atom.to_string(node()),
      "stream" => thread_id(context, title)
    }

    id = System.unique_integer([:positive])
    client = Node.sub(client(context), id, shape)
    {rows, client} = snapshot_rows(client, id, [])
    Node.unsub(client, id)

    state =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(HalC2.StreamState.new(), fn {[kind, eid, entity], seq}, state ->
        HalC2.StreamState.apply_event(state, %{
          seq: seq,
          kind: kind,
          entity: eid,
          patch: %{"s" => entity}
        })
      end)

    {HalC2.Projection.Timeline.local_items(state), put_client(context, client)}
  end

  defp snapshot_rows(client, id, acc) do
    {frame, client} = Node.await(client, &(&1["t"] == "snapshot" and &1["id"] == id))
    acc = acc ++ frame["rows"]
    if frame["done"], do: {acc, client}, else: snapshot_rows(client, id, acc)
  end

  @doc """
  Answers the thread's pending questions (`runtime-request.respond`): `answer` goes
  to the first question, `extra` merges into the command. The reply is
  `context.reply`; the request is `context.request`.
  """
  def answer_questions(context, title, answer, extra \\ %{}) do
    request =
      Enum.find(entities(context, title, "runtime-request"), fn request ->
        request["kind"] == "user_input" and request["status"] == "pending"
      end) || flunk("#{title} has no pending questions")

    [question | _] =
      Enum.find_value(entities(context, title, "turn-item"), fn item ->
        item["requestId"] == request["id"] && item["questions"]
      end)

    context
    |> Map.put(:request, request["id"])
    |> command(
      Map.merge(
        %{
          "type" => "runtime-request.respond",
          "threadId" => thread_id(context, title),
          "requestId" => request["id"],
          "answers" => %{question["id"] => answer}
        },
        extra
      )
    )
  end

  @doc """
  The thread's Codex runtime (after `providers/1` and a turn): `{pid, state}`, whose
  state holds the app-server connection (`conn`) and the active `turn`.
  """
  def codex_runtime(context, title) do
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id(context, title))
    {pid, :sys.get_state(pid)}
  end

  @doc """
  Delivers a notification to the thread's Codex runtime as if the (fake) app-server
  sent it, such as `"turn/completed"`; returns the context.
  """
  def codex_notify(context, title, method, params) do
    {pid, state} = codex_runtime(context, title)
    send(pid, {:json_rpc, state.conn, {:notification, method, params}})
    context
  end

  @doc """
  Makes the fake Claude (`test/support/fake_claude.py`) log the text of every user
  message it receives from now on, for `claude_prompts/1`; returns the context.
  """
  def log_claude_prompts(context) do
    log = Path.join(Node.tmp_dir(context.node, "claude"), "prompts.jsonl")
    System.put_env("FAKE_CLAUDE_PROMPT_LOG", log)
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CLAUDE_PROMPT_LOG") end)
    Map.put(context, :claude_log, log)
  end

  @doc """
  Writes a Node server database holding only `orchestration_events`, as
  `HalC2.Import.V2` reads it. Each event is `{aggregate, stream, type, payload, at_ms}`;
  thread events are V2 (`application_event_version` 2), project events carry none.
  """
  def node_log(path, events) do
    alias Exqlite.Sqlite3
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE orchestration_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_kind TEXT, stream_id TEXT,
        event_type TEXT, payload_json TEXT, occurred_at TEXT, application_event_version INTEGER)
      """)

    :ok = Sqlite3.execute(db, "BEGIN")

    {:ok, stmt} =
      Sqlite3.prepare(db, """
      INSERT INTO orchestration_events (aggregate_kind, stream_id, event_type, payload_json,
        occurred_at, application_event_version) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """)

    for {aggregate, stream, type, payload, at} <- events do
      occurred = at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
      version = if aggregate == "project", do: nil, else: 2

      :ok =
        Sqlite3.bind(stmt, [aggregate, stream, type, JSON.encode!(payload), occurred, version])

      :done = Sqlite3.step(db, stmt)
    end

    :ok = Sqlite3.release(db, stmt)
    :ok = Sqlite3.execute(db, "COMMIT")
    :ok = Sqlite3.close(db)
    path
  end

  # --- providers on fakes (added by W9) -------------------------------------------

  @fakes __DIR__

  @doc """
  Runs the scenario's providers on the test fakes (`test/support/fake_*.py`), never a
  real CLI: `claude` and `codex` executables under `<home>/fakes` that answer
  `--version` with `:claude_version` / `:codex_version` (`update` bumps them to 9.9.9),
  and Grok, OpenCode, Cursor and Pi on `fake_acp.py`. Each fake appends what it is
  sent to its log (`provider_log/2`). Starts the registries and the supervisor provider
  sessions run under, and the settings. `:claude_layout` / `:codex_layout` put the
  executable where an installer would (`:native` for Claude's own, `:npm`), else a
  plain `bin/`. Idempotent; everything is undone when the scenario ends.
  """
  def fake_providers(context, opts \\ [])
  def fake_providers(%{fakes: %{}} = context, _opts), do: context

  def fake_providers(context, opts) do
    dir = Path.join(context.node.home, "fakes")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    logs = Map.new(~w(claude codex acp), &{&1, Path.join(dir, "#{&1}.log")})

    claude =
      fake_cli(dir, "claude", opts[:claude_layout], opts[:claude_version] || "2.1.0",
        version_line: "echo \"$(cat #{Path.join(dir, "claude.version")}) (Claude Code)\"",
        exec: "python3 -u #{@fakes}/fake_claude.py \"$@\""
      )

    codex =
      fake_cli(dir, "codex", opts[:codex_layout], opts[:codex_version] || "0.50.0",
        version_line: "echo \"codex-cli $(cat #{Path.join(dir, "codex.version")})\"",
        exec: "python3 -u #{@fakes}/fake_codex.py \"$@\""
      )

    acp = Path.join(bin, "acp-agent")
    script!(acp, "exec python3 -u #{@fakes}/fake_acp.py \"$@\"")

    env = %{
      "FAKE_CLAUDE_TRACE" => logs["claude"],
      "FAKE_CODEX_TRACE" => logs["codex"],
      "FAKE_ACP_TRACE" => logs["acp"],
      # OpenCode's sessions, which every fake reads (a fork reads its source's).
      "FAKE_ACP_SESSIONS" => Path.join(dir, "opencode-sessions"),
      # Cursor's sidecar runs under this Node binary.
      "HAL_C2_NODE_COMMAND" => acp
    }

    for {name, value} <- env, do: put_env(name, value)
    put_app_env(:claude_command, [claude])
    put_app_env(:codex_command, [codex])
    put_app_env(:acp_commands, %{"pi" => [acp]})
    reset_provider_caches()

    ExUnit.Callbacks.on_exit(fn ->
      for key <-
            ~w(FAKE_CODEX_MODELS FAKE_CODEX_ACCOUNT FAKE_CLAUDE_USAGE FAKE_ACP_MODELS FAKE_ACP_CAPS FAKE_AUTH_FILE FAKE_CODEX_CONSUME_LOG
                    FAKE_CODEX_CONSUME_FAIL),
          do: System.delete_env(key)

      reset_provider_caches()
    end)

    Node.ensure(HalC2.Settings)
    Node.ensure({Registry, keys: :unique, name: HalC2.Codex.Registry})

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: :claude_registry
      )
    )

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      )
    )

    Node.ensure({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    # The built-in ACP agents run the fake through their binary setting, unless the
    # scenario already pointed them elsewhere.
    {settings, _} = HalC2.Settings.get()

    merge_settings(%{
      "providers" =>
        for(
          driver <- ~w(grok opencode),
          get_in(settings, ["providers", driver, "binaryPath"]) == nil,
          into: %{},
          do: {driver, %{"binaryPath" => acp}}
        )
    })

    Map.put(context, :fakes, %{
      dir: dir,
      bin: bin,
      logs: logs,
      claude: claude,
      codex: codex,
      acp: acp
    })
  end

  # A fake CLI at the path its installer would use; `update` moves it to 9.9.9.
  defp fake_cli(dir, name, layout, version, script) do
    version_file = Path.join(dir, "#{name}.version")
    File.write!(version_file, version)

    real =
      case layout do
        :native ->
          Path.join([dir, "local", "share", "claude", "versions", name])

        :npm ->
          Path.join([dir, "npm", "lib", "node_modules", "@openai", "codex", "bin", "codex.js"])

        _ ->
          Path.join([dir, "bin", name])
      end

    script!(real, """
    if [ "$1" = "--version" ]; then #{script[:version_line]}; exit 0; fi
    if [ "$1" = "update" ]; then echo 9.9.9 > #{version_file}; exit 0; fi
    exec #{script[:exec]}
    """)

    case layout do
      nil ->
        real

      :npm ->
        prefix = Path.join(dir, "npm")

        script!(
          Path.join([prefix, "bin", "npm"]),
          "echo \"$@\" > #{dir}/npm.args; echo 9.9.9 > #{version_file}"
        )

        link(real, Path.join([prefix, "bin", name]))

      :native ->
        link(real, Path.join([dir, "bin", name]))
    end
  end

  defp link(real, path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
    File.ln_s!(real, path)
    path
  end

  defp script!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  @doc "Forgets what the node cached about its provider CLIs (versions, models, latest releases)."
  def reset_provider_caches do
    for key <- [
          {HalC2.Codex.Provider, :models},
          {HalC2.Codex.Provider, :version},
          {HalC2.Claude.Provider, :version},
          {HalC2.ProviderUpdates, "codex"},
          {HalC2.ProviderUpdates, "claudeAgent"},
          # The update a scenario was offered, and how its last update went.
          {HalC2.ProviderUpdates, "codex", :offered},
          {HalC2.ProviderUpdates, "claudeAgent", :offered},
          {HalC2.ProviderUpdates, "codex", :state},
          {HalC2.ProviderUpdates, "claudeAgent", :state}
        ],
        do: :persistent_term.erase(key)

    :ok
  end

  @doc "What a fake provider (`\"claude\"`, `\"codex\"` or `\"acp\"`) was sent, as decoded JSON lines."
  def provider_log(context, name) do
    case File.read(context.fakes.logs[name]) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc """
  Starts a thread on `instance` with `text` as its first message, as the composer
  does (`orchestration.launchThread`), and subscribes the test process to its stream.
  `fields` override the launch input (`runtimeMode`, `interactionMode`, `model`, ...).
  """
  def launch_on(context, title, instance, text, fields \\ %{}) do
    id = "th-#{slug(title)}-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    project = if context[:projects] not in [nil, %{}], do: project(context).id
    {model, fields} = Map.pop(fields, "model", default_model(instance))

    {:ok, _} =
      HalC2.Orchestration.launch_thread(
        Map.merge(
          %{
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => id,
            "projectId" => project,
            "title" => title,
            "modelSelection" => %{"instanceId" => instance, "model" => model},
            "runtimeMode" => "full-access",
            "interactionMode" => "default",
            "workspaceStrategy" => %{"type" => "root"},
            "initialMessage" => %{
              "messageId" => "msg-#{System.unique_integer([:positive])}",
              "text" => text,
              "attachments" => []
            }
          },
          fields
        )
      )

    context |> put_in([:threads, title], id) |> Map.put(:current_thread, title)
  end

  @provider_features ~w(capabilities claude codex models permission-modes session-import usage usage-limits)

  @doc """
  Whether the scenario is in one of the provider features that run on
  `fake_providers/2` and `launch_on/5`. Steps those features share with other
  fixtures dispatch on it.
  """
  def fakes_feature?(context) do
    file = context[:feature_file] || ""

    Path.basename(Path.dirname(file)) == "providers" and
      Path.basename(file, ".feature") in @provider_features
  end

  @doc "The thread the scenario is about: the last one `launch_on/5` started."
  def current_thread(context), do: context[:current_thread] || flunk("no thread was started")

  defp default_model("claudeAgent"), do: "sonnet"
  defp default_model("codex"), do: "gpt-5.4"
  defp default_model(_), do: "default"

  @doc """
  Sends a user message to a thread (`message.dispatch`), queued after a running turn;
  `extra` overrides fields, and a nil drops one (`"dispatchMode" => nil` lets the node
  decide whether to steer, as the composer does).
  """
  def post_message(context, title, text, extra \\ %{}) do
    id = thread_id(context, title)
    :ok = HalC2.Streams.subscribe(id, self(), nil)

    {:ok, _} =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "message.dispatch",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => id,
            "messageId" => "msg-#{System.unique_integer([:positive])}",
            "text" => text,
            "attachments" => [],
            "dispatchMode" => %{"type" => "queue_after_active"}
          },
          extra
        )
        |> Map.reject(fn {_key, value} -> value == nil end)
      )

    context
  end

  @doc """
  Waits until `fun` returns a truthy value for the thread's stream state, re-checking
  on each change of the stream (the test process subscribes); returns that value.
  """
  def await_value(context, title, fun, timeout \\ 5_000) do
    id = thread_id(context, title)
    :ok = HalC2.Streams.subscribe(id, self(), nil)
    deadline = System.monotonic_time(:millisecond) + timeout
    await_value_loop(context, title, id, fun, deadline)
  end

  defp await_value_loop(context, title, id, fun, deadline) do
    state = stream(context, title)

    case fun.(state) do
      result when result not in [nil, false] ->
        result

      _ ->
        wait = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:hal_c2_stream, ^id, _} -> await_value_loop(context, title, id, fun, deadline)
        after
          wait ->
            flunk(
              "#{title}'s stream never got there; runs: " <>
                inspect(for r <- HalC2.StreamState.list(state, "run"), do: r["status"]) <>
                "; errors: " <>
                inspect(
                  for s <- HalC2.StreamState.list(state, "provider-session"), do: s["lastError"]
                )
            )
        end
    end
  end

  @doc "Waits for the thread's pending provider request (approval or question)."
  def await_request(context, title) do
    await_value(context, title, fn state ->
      Enum.find(HalC2.StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
    end)
  end

  @doc "Waits until a fake provider's log has an entry matching `fun`; returns it."
  def await_provider_log(context, name, fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_log_loop(context, name, fun, deadline)
  end

  defp await_log_loop(context, name, fun, deadline) do
    case Enum.find(provider_log(context, name), fun) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline,
          do:
            flunk("the #{name} fake was never sent that: #{inspect(provider_log(context, name))}")

        # The fake writes its log from another OS process; there is no message to wait on.
        receive do
        after
          20 -> await_log_loop(context, name, fun, deadline)
        end

      entry ->
        entry
    end
  end

  @doc """
  The node's provider list as a client reads it (`ServerConfig.providers` from the
  config subscription), running the providers on fakes first; returns
  `{providers, context}`.
  """
  def provider_list(context) do
    context = fake_providers(context)
    id = System.unique_integer([:positive])

    client =
      Node.sub(client(context), id, %{"type" => "config", "node" => Atom.to_string(node())})

    {frame, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == id), 10_000)
    {frame["config"]["providers"], put_client(context, client)}
  end

  @doc "One provider entry (by instance id) from `provider_list/1`, or nil."
  def provider(context, instance) do
    {providers, _} = provider_list(context)
    Enum.find(providers, &(&1["instanceId"] == instance))
  end

  @doc "Every event a thread's stream has committed, oldest first (`HalC2.Store.reduce_stream/6`)."
  def stream_events(context, title) do
    HalC2.Store.path()
    |> HalC2.Store.reduce_stream(thread_id(context, title), 0, [], &[&1 | &2])
    |> Enum.reverse()
  end

  @doc "Waits until the thread's last run is `running` (its provider has the turn)."
  def await_running(context, title) do
    await_value(context, title, fn state ->
      case state
           |> HalC2.StreamState.list("run")
           |> Enum.sort_by(& &1["ordinal"])
           |> List.last() do
        %{"status" => "running"} = run -> run
        _ -> nil
      end
    end)
  end

  @doc "Waits until the thread's last run has ended; returns the stream state."
  def await_idle(context, title) do
    await_value(context, title, fn state ->
      runs = HalC2.StreamState.list(state, "run")

      if runs != [] and
           Enum.all?(
             runs,
             &(&1["status"] not in ~w(pending queued preparing starting running waiting))
           ),
         do: state
    end)
  end

  @doc """
  Starts a thread on `instance` and runs `texts` as its turns one after another,
  each finished before the next is sent.
  """
  def run_turns(context, title, instance, [first | rest], fields \\ %{}) do
    context = launch_on(context, title, instance, first, fields)
    await_idle(context, title)

    Enum.reduce(rest, context, fn text, context ->
      count = length(runs(context, title))
      context = post_message(context, title, text)

      await_value(context, title, fn state ->
        length(HalC2.StreamState.list(state, "run")) > count
      end)

      await_idle(context, title)
      context
    end)
  end

  @doc "The assistant's replies in a thread, oldest first."
  def replies(context, title) do
    for m <- context |> stream(title) |> HalC2.StreamState.list("message"),
        m["role"] == "assistant",
        do: m["text"]
  end

  @doc "Rolls a thread back to the end of its turn `ordinal` (`checkpoint.rollback`)."
  def rollback(context, title, ordinal, extra \\ %{}) do
    id = thread_id(context, title)
    scope = HalC2.Checkpoint.scope_id(id)

    reply =
      HalC2.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "checkpoint.rollback",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => id,
            "scopeId" => scope,
            "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope, ordinal)
          },
          extra
        )
      )

    Map.put(context, :reply, reply)
  end

  @doc "Forks a thread after its run number `ordinal` (1-based) into `fork_title`."
  def fork(context, title, ordinal, fork_title) do
    run = Enum.at(runs(context, title), ordinal - 1)
    id = "th-#{slug(fork_title)}-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(id, self(), nil)

    reply =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.fork",
        "commandId" => "cmd-fork-#{id}",
        "createdBy" => "user",
        "creationSource" => "web",
        "sourceThreadId" => thread_id(context, title),
        "targetThreadId" => id,
        "sourcePoint" => %{"type" => "run", "runId" => run["id"]}
      })

    context |> put_in([:threads, fork_title], id) |> Map.put(:reply, reply)
  end

  @doc """
  Adds an ACP Registry agent `id` (display name `name`) that runs the fake ACP agent:
  a registry index cached in the node's home, an `acpRegistry` provider instance, and
  its command. The agent is probed at once, so its capabilities and models are known.
  """
  def acp_registry_agent(context, id, name) do
    context = fake_providers(context)
    cache = Path.join([HalC2.Paths.cache_dir(), "acp-registry", "registry.json"])
    File.mkdir_p!(Path.dirname(cache))

    File.write!(
      cache,
      JSON.encode!(%{
        "agents" => [
          %{
            "id" => id,
            "name" => name,
            "version" => "1.0.0",
            "description" => "",
            "distribution" => %{"npx" => %{"package" => id}}
          }
        ]
      })
    )

    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    commands = Application.get_env(:hal_c2, :acp_commands, %{})
    Application.put_env(:hal_c2, :acp_commands, Map.put(commands, id, [context.fakes.acp]))

    merge_settings(%{
      "providerInstances" => %{
        id => %{"driver" => "acpRegistry", "displayName" => name, "config" => %{"agentId" => id}}
      }
    })

    ExUnit.Callbacks.on_exit(fn ->
      HalC2.Acp.forget(id)
      :persistent_term.erase({HalC2.Acp.Catalog, :index})
      Application.put_env(:hal_c2, :acp_commands, commands)
    end)

    HalC2.Acp.reload(id)
    context
  end

  @doc """
  Starts recording which transcripts `HalC2.Usage` parses (call tracing on
  `HalC2.Usage.Transcripts.read/3` in the usage process and the tasks it spawns);
  read them back with `usage_reads/0`. Tracing stops when the scenario ends.
  """
  def trace_usage_reads(context) do
    usage = Process.whereis(HalC2.Usage) || flunk("HalC2.Usage is not running")
    :erlang.trace_pattern({HalC2.Usage.Transcripts, :read, 3}, true, [])
    :erlang.trace(usage, true, [:call, :set_on_spawn, {:tracer, self()}])

    ExUnit.Callbacks.on_exit(fn ->
      :erlang.trace_pattern({HalC2.Usage.Transcripts, :read, 3}, false, [])
    end)

    context
  end

  @doc """
  The transcript reads recorded since `trace_usage_reads/1`, as `{path, provider,
  resume}` (`resume` is nil for a read from the start); every trace message is
  delivered before this returns.
  """
  def usage_reads do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    end

    collect_usage_reads([])
  end

  defp collect_usage_reads(acc) do
    receive do
      {:trace, _pid, :call, {HalC2.Usage.Transcripts, :read, [path, provider, resume]}} ->
        collect_usage_reads([{path, provider, resume} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Runs the node's periodic checks now, as if their interval had passed: the idle
  session release and the usage-limit probes of Codex, Claude and hubs, each deciding
  for itself whether to do anything. Returns the services that ran; flunks when none
  of them is running.
  """
  def run_periodic_checks do
    checks = [
      {HalC2.Orchestration.IdleSessions, &HalC2.Orchestration.IdleSessions.check/0},
      {HalC2.ProviderUsageLimits, fn -> tick(HalC2.ProviderUsageLimits) end},
      {HalC2.UsageLimitSources, fn -> tick(HalC2.UsageLimitSources) end}
    ]

    ran =
      for {name, run} <- checks, Process.whereis(name) != nil do
        run.()
        name
      end

    if ran == [], do: flunk("no periodic check is running on this node")
    ran
  end

  # The timer message a service schedules for itself; the state call waits it out.
  defp tick(name) do
    send(name, :tick)
    :sys.get_state(name, 120_000)
  end
end

# --- added by W4 (terminal) ---

defmodule HalC2.Test.Node.Terminal do
  @moduledoc """
  Terminals as `features/terminal/` drives them: over the socket, the way a client
  does. The scenario's terminal is `context.terminal` (a `TerminalOpenInput` map);
  each client attaches to one terminal at a time, under `context.terminal_subs`
  (client name → subscription id). Folders the feature names (`/work/app`) live
  under the scenario's home (`folder/2`).
  """

  import ExUnit.Assertions

  alias HalC2.Test.{Node, WsClient}
  alias HalC2.Test.Node.World

  @doc """
  Starts the node's terminal services and makes `/bin/sh` the user's shell for
  the scenario (quick, and it reads no rc files).
  """
  def ensure(%{terminals_ready: true} = context), do: context

  def ensure(context) do
    Node.ensure({Registry, keys: :unique, name: HalC2.Terminal.Registry})
    Node.ensure({DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one})
    Node.ensure(HalC2.Terminal.Hub)
    put_env("SHELL", "/bin/sh")
    Map.put(context, :terminals_ready, true)
  end

  @doc "Sets (or with `nil` unsets) an OS environment variable until the scenario ends."
  def put_env(key, value) do
    previous = System.get_env(key)
    if value, do: System.put_env(key, value), else: System.delete_env(key)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)
  end

  @doc "Where a folder named in the feature lives for this scenario (not created)."
  def folder(context, path), do: Path.join(context.node.home, "fs" <> path)

  @doc "`folder/2`, created."
  def mkdir(context, path) do
    dir = folder(context, path)
    File.mkdir_p!(dir)
    dir
  end

  @doc "The scenario's terminal input, with `overrides`; defaults to `term-1` in `/work/app`."
  def input(context, overrides \\ %{}) do
    (context[:terminal] ||
       %{
         "threadId" => "th-terminal",
         "terminalId" => "term-1",
         "cwd" => mkdir(context, "/work/app")
       })
    |> Map.merge(overrides)
  end

  def put_input(context, input), do: Map.put(context, :terminal, input)

  @doc "`terminal.open` on the named client; stores the input and returns `{reply, context}`."
  def open(context, overrides \\ %{}, name \\ "default") do
    context = ensure(context)
    input = input(context, overrides)
    {reply, context} = World.call(context, "terminal.open", input, name)
    {reply, put_input(context, input)}
  end

  @doc "Like `open/3`, asserting success; returns `{snapshot, context}`."
  def open!(context, overrides \\ %{}, name \\ "default") do
    case open(context, overrides, name) do
      {{:ok, snapshot}, context} -> {snapshot, context}
      {other, _} -> flunk("terminal.open failed: #{inspect(other)}")
    end
  end

  @doc """
  Attaches the named client to a terminal (`input`, default the scenario's) and
  returns `{first frame, context}`: `%{"t" => "terminal"}` with the snapshot, or an
  `%{"t" => "error"}`.
  """
  def attach(context, name, input \\ nil, node \\ Atom.to_string(node())) do
    context = ensure(context)
    input = input || input(context)
    id = System.unique_integer([:positive])
    client = World.client(context, name)
    shape = %{"type" => "terminal", "node" => node, "input" => input}
    client = Node.sub(client, id, shape)
    {frame, client} = Node.await(client, &(&1["id"] == id or &1["t"] == "error"), 5_000)

    context =
      context
      |> World.put_client(name, client)
      |> Map.update(:terminal_subs, %{name => id}, &Map.put(&1, name, id))

    {frame, context}
  end

  @doc "Like `attach/3`, asserting a snapshot; returns `{snapshot, context}`."
  def attach!(context, name, input \\ nil) do
    case attach(context, name, input) do
      {%{"t" => "terminal", "event" => %{"type" => "snapshot", "snapshot" => s}}, context} ->
        {s, context}

      {frame, _} ->
        flunk("attach failed: #{inspect(frame)}")
    end
  end

  @doc """
  The next terminal event on the named client's subscription matching `fun`;
  earlier events are skipped. Returns `{event, context}`.
  """
  def await_event(context, name, fun, timeout \\ 5_000) do
    id = Map.fetch!(context.terminal_subs, name)

    {%{"event" => event}, client} =
      Node.await(
        World.client(context, name),
        &(&1["t"] == "terminal" and &1["id"] == id and fun.(&1["event"])),
        timeout
      )

    {event, World.put_client(context, name, client)}
  end

  @doc """
  Output on the named client until it matches `pattern` (a string or regex);
  returns `{output so far, events seen, context}`.
  """
  def await_output(context, name, pattern, timeout \\ 5_000) do
    id = Map.fetch!(context.terminal_subs, name)
    collect(World.client(context, name), id, pattern, timeout, "", [], context, name)
  end

  defp collect(client, id, pattern, timeout, acc, events, context, name) do
    {frame, client} = WsClient.recv(client, timeout)

    case frame do
      %{"t" => "terminal", "id" => ^id, "event" => %{"type" => "output", "data" => data} = e} ->
        acc = acc <> data

        if acc =~ pattern,
          do: {acc, Enum.reverse([e | events]), World.put_client(context, name, client)},
          else: collect(client, id, pattern, timeout, acc, [e | events], context, name)

      %{"t" => "terminal", "id" => ^id, "event" => e} ->
        collect(client, id, pattern, timeout, acc, [e | events], context, name)

      _ ->
        collect(client, id, pattern, timeout, acc, events, context, name)
    end
  rescue
    error in RuntimeError ->
      flunk("#{Exception.message(error)}; no #{inspect(pattern)} in #{inspect(acc)}")
  end

  @doc "Sends keystrokes to the scenario's terminal from the named client, not waiting for the reply."
  def write(context, name, data, input \\ nil) do
    input = input || input(context)
    id = System.unique_integer([:positive])

    client =
      Node.rpc(World.client(context, name), context.node.environment, id, "terminal.write", %{
        "threadId" => input["threadId"],
        "terminalId" => input["terminalId"],
        "data" => data
      })

    World.put_client(context, name, client)
  end

  @doc """
  Runs `command` in the terminal the named client is attached to and waits until
  it finished; returns `{output, context}`.
  """
  def run(context, name, command, input \\ nil) do
    n = System.unique_integer([:positive])
    context = write(context, name, "#{command}; echo __done''_#{n}__\n", input)
    {output, _events, context} = await_output(context, name, "__done_#{n}__")
    {output, context}
  end

  @doc "Waits until an OS process has ended (a shell ignores SIGTERM, so up to a second)."
  def await_exit(os_pid) do
    {_, status} =
      System.cmd("timeout", ["5", "tail", "--pid=#{os_pid}", "-s", "0.05", "-f", "/dev/null"])

    assert status == 0, "process #{os_pid} still runs"
  end

  @doc "The OS process's command name."
  def comm(os_pid), do: "/proc/#{os_pid}/comm" |> File.read!() |> String.trim()

  @doc "The running terminal process for `input`."
  def session(input) do
    [{pid, _}] =
      Registry.lookup(HalC2.Terminal.Registry, {input["threadId"], input["terminalId"]})

    pid
  end

  @doc """
  The scenario's terminal after its shell printed `text` and exited; the "default"
  client is attached and has seen the exit.
  """
  def exited(context, text) do
    {_, context} = open!(context)
    {_, context} = attach!(context, "default", Map.delete(context.terminal, "cwd"))
    context = write(context, "default", "echo #{text}; exit 0\n")
    {_, context} = await_event(context, "default", &(&1["type"] == "exited"))
    context
  end

  @doc "Where the node saves `input`'s scrollback."
  def history_file(context, input) do
    name =
      "terminal_#{Base.url_encode64(input["threadId"], padding: false)}_" <>
        "#{Base.url_encode64(input["terminalId"], padding: false)}.log"

    Path.join([context.node.home, "terminals", name])
  end

  @doc """
  Waits until the running terminal for `input` has saved scrollback containing
  `text`, following its `:persist` timer rather than polling the file.
  """
  def await_persisted(context, input, text, timeout \\ 3_000) do
    pid = session(input)
    test = self()
    ref = make_ref()

    tracer =
      spawn_link(fn ->
        receive do
          :go -> :ok
        end

        Stream.repeatedly(fn ->
          receive do
            {:trace, ^pid, :receive, :persist} -> send(test, {ref, :persist})
            _ -> :ok
          end
        end)
        |> Stream.run()
      end)

    :erlang.trace(pid, true, [:receive, {:tracer, tracer}])
    send(tracer, :go)
    file = history_file(context, input)

    try do
      await_saved(pid, ref, file, text, System.monotonic_time(:millisecond) + timeout)
    after
      :erlang.trace(pid, false, [:receive])
      Process.unlink(tracer)
      Process.exit(tracer, :kill)
    end
  end

  defp await_saved(pid, ref, file, text, deadline) do
    # A save that already happened counts; `get_state` waits out one in progress.
    :sys.get_state(pid)

    case File.read(file) do
      {:ok, saved} ->
        if saved =~ text, do: saved, else: await_next_save(pid, ref, file, text, deadline)

      {:error, :enoent} ->
        await_next_save(pid, ref, file, text, deadline)
    end
  end

  defp await_next_save(pid, ref, file, text, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, :persist} -> await_saved(pid, ref, file, text, deadline)
    after
      remaining -> flunk("#{inspect(text)} was not saved to #{file}")
    end
  end
end

# --- added by W4 (files) ---

defmodule HalC2.Test.Node.Host do
  @moduledoc """
  The machine a scenario's node runs on, as features name it: absolute paths such
  as `/home/sam/shop` live under the scenario's home, and `~` is `/home/sam`
  there, made the node's `$HOME` for the scenario on first use.
  """

  @doc "Where a feature's path (`/home/sam/shop`, `~/code`) really is in this scenario."
  def path(context, "/" <> _ = path), do: Path.join(context.node.home, "fs") <> path
  def path(context, "~" <> rest), do: home(context) <> rest
  def path(_context, path), do: path

  @doc "The scenario's `$HOME` (`/home/sam`), set for the node on first call."
  def home(context) do
    case Process.get({__MODULE__, :home}) do
      nil ->
        real = path(context, "/home/sam")
        File.mkdir_p!(real)
        previous = System.get_env("HOME")
        System.put_env("HOME", real)
        ExUnit.Callbacks.on_exit(fn -> System.put_env("HOME", previous) end)
        Process.put({__MODULE__, :home}, real)
        real

      real ->
        real
    end
  end
end
