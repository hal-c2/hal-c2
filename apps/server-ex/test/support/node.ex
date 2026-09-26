defmodule T3.Test.Node do
  @moduledoc """
  One node under test, as a client sees it over the protocol 3 socket.

  `start/1` brings up the same pieces `T3.ScenariosTest` does (store, auth,
  streams, shell, web) under the test supervisor with the state in a fresh
  directory; steps add the services their scenario needs with `ensure/1`.
  Clients are `T3.Test.WsClient` structs threaded through the scenario context.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised: 1, start_supervised!: 1]

  alias T3.Test.WsClient
  @doc false
  def ws_client, do: WsClient

  @doc """
  Starts a node in `dir` and returns what steps need to talk to it:
  `%{port, environment, home}`. `port` 0 picks a free one.
  """
  def start(dir, port \\ 0) do
    File.mkdir_p!(dir)
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :port, port)
    :persistent_term.erase({T3.Web, :token})
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Auth)
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    web = start_supervised!(Supervisor.child_spec(T3.Web, id: T3.Web))
    # A named node finds its peers as it would at boot (T3_PEERS, the tailnet).
    for spec <- T3.Application.discovery(dir),
        do: start_supervised!(Supervisor.child_spec(spec, id: :discovery))

    {:ok, {_ip, port}} = ThousandIsland.listener_info(web)
    # The port it got, as a configured node knows its own (`mix t3.pair` reads it).
    Application.put_env(:t3, :port, port)
    {_, %{"environmentId" => environment}} = List.keyfind(T3.Shell.environments(), node(), 0)
    :ok = T3.Shell.subscribe(self())
    %{port: port, environment: environment, home: dir, store: Path.join(dir, "t3.sqlite")}
  end

  @doc """
  Stops the node's services, as a shutdown does. Services a step added with
  `ensure/1` stop first (so a normal shutdown can still release its tunnel),
  then the core; `restart/1` brings them all back.
  """
  def stop(node) do
    for child <- Enum.reverse(Process.get({__MODULE__, :ensured}, [])),
        do: ExUnit.Callbacks.stop_supervised(Supervisor.child_spec(child, []).id)

    for child <- [:discovery, T3.Web, T3.Shell, T3.Streams, T3.Auth, T3.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    node
  end

  @doc """
  Stops the node's services (if `stop/1` has not) and starts them again on the
  same state, as a restart does, on the same port. Services a step started with
  `ensure/1` (settings, plugins, T3 Connect, diagnostics, scheduled tasks) come
  back after the core, so in-memory state (clones, setups) is lost as in a real
  restart. Turns the stop cut off are settled and, where the project asks for
  it, continued (`T3.Orchestration.Recovery`), as `T3.Application` boots.
  Sockets are gone afterwards; steps reconnect.
  """
  def restart(%{home: dir, port: port} = node) do
    stop(node)
    ensured = Process.get({__MODULE__, :ensured}, [])
    node = start(dir, port)
    Enum.each(ensured, &ensure/1)
    # The boot tasks the application runs once its services are up.
    :ok = T3.Projects.auto_pull()
    T3.Orchestration.Recovery.run()
    :ok = T3.Orchestration.Recovery.continue()
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
    {:ok, client} = WsClient.connect(port, "/ws?" <> (query || "token=#{T3.Web.token()}"))
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
      name = :"t3features#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
    end

    {:ok, peer, name} =
      :peer.start(%{
        name: :"t3peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    ExUnit.Callbacks.on_exit(fn -> :peer.stop(peer) end)

    # A peer node does not read Mix config, so it gets the node settings directly.
    for {key, value} <- [start_node: true, home: Path.join(node.home, "peer"), port: 0],
        do: :ok = :erpc.call(name, Application, :put_env, [:t3, key, value])

    {:ok, _} = :erpc.call(name, Application, :ensure_all_started, [:t3])
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
      T3.Auth.create_pairing_link(%{"scopes" => scopes || T3.Auth.standard_scopes()})

    {:ok, access, _expires, _scopes} = T3.Auth.exchange(credential, %{label: label})
    access
  end

  @doc "Pairs over HTTP as a client does: posts `credential` to `/oauth/token`; `{status, body}`."
  def pair_http(node_or_base, credential, label \\ "Device") do
    http(node_or_base, :post, "/oauth/token",
      form: %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token_type" => "urn:t3:params:oauth:token-type:environment-bootstrap",
        "subject_token" => credential,
        "client_label" => label
      }
    )
  end

  @doc "Opens a socket for a bearer access token (through a WebSocket ticket)."
  def connect_as(node, access) do
    {:ok, ticket, _} = T3.Auth.issue_ticket(access)
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
  Runs a Mix task (`Mix.Tasks.T3.Pair`, say) in the node's home as an operator
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
  def admin_scopes, do: T3.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)
end

defmodule T3.Test.Node.World do
  @moduledoc """
  What a scenario builds up on its node: projects, threads and sockets, by the
  names the feature uses. Everything is kept in the Cucumber context map so
  steps in any file can find it:

    * `context.node` - `%{port, environment, home, store}` from `T3.Test.Node.start/1`
    * `context.projects` - title → `%{id, root}`
    * `context.threads` - title → thread id
    * `context.clients` - name → `T3.Test.WsClient` (`"default"` for the unnamed one)

  Sockets are values: take one with `client/2`, thread it through the calls,
  and put it back with `put_client/3`.
  """

  import ExUnit.Assertions

  alias T3.Test.Node

  @doc "Creates a project rooted at a fresh git repository; `title` is also its id."
  def create_project(context, title, fields \\ %{}) do
    id = fields["projectId"] || slug(title)
    root = fields["workspaceRoot"] || git_repo(context, id)

    {:ok, _} =
      T3.Projects.mutate(
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
      T3.Orchestration.dispatch(
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
    T3.StreamState.get(T3.Streams.Server.state(T3.Streams.ensure(id)), "thread")[id]
  end

  @doc "A thread's sidebar row."
  def row(context, title) do
    case T3.Shell.row(node(), thread_id(context, title)) do
      {_kind, row} -> row
      nil -> nil
    end
  end

  @doc "Patches fields of a thread entity directly, as test setup (backdating activity, say)."
  def patch_thread(context, title, fields),
    do: put_entity(context, title, "thread", thread_id(context, title), %{"s" => fields})

  @doc """
  Commits one entity patch (`%{"s" => fields}` or `T3.Patch.delete/0`) to a thread's
  stream and waits until the sidebar row reflects it.
  """
  def put_entity(context, title, kind, id, patch) do
    thread = thread_id(context, title)
    before = System.os_time(:millisecond)
    {:ok, _} = T3.Streams.commit(thread, :thread, [{kind, id, patch}])
    await_row(thread, &(T3.Projection.JS.epoch_ms(&1["updatedAt"]) >= before))
    context
  end

  @doc "Adds a user or assistant message to a thread at `at` (ISO), as if sent then."
  def add_message(context, title, role, text, at \\ nil, extra \\ %{}) do
    at = at || iso_from_now(0)
    id = "msg-#{System.unique_integer([:positive])}"

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
    case T3.Shell.row(node(), id) do
      {_kind, row} -> if fun.(row), do: row, else: await_next_row(id, fun, timeout)
      nil -> await_next_row(id, fun, timeout)
    end
  end

  defp await_next_row(id, fun, timeout) do
    receive do
      {:t3_shell, {:rows, _, rows}} ->
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
    git!(root, ~w(config user.email t3@example.com))
    git!(root, ~w(config user.name T3))
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
  Waits until `fun`, given a thread stream's `T3.StreamState`, returns something
  other than `nil`/`false`, and returns that. Subscribes the test process to the
  stream and re-checks on each of its commits.
  """
  def await_stream(stream_id, fun, timeout \\ 5_000) do
    :ok = T3.Streams.subscribe(stream_id, self(), nil)
    check_stream(stream_id, fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp check_stream(id, fun, deadline) do
    case fun.(T3.Streams.Server.state(T3.Streams.ensure(id))) do
      done when done in [nil, false] ->
        receive do
          {:t3_stream, ^id, _} -> check_stream(id, fun, deadline)
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
  `T3.Settings` if the scenario has not yet. Returns the context.
  """
  def update_settings(context, patch) do
    Node.ensure(T3.Settings)
    {settings, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(deep_merge(settings, patch), version)
    context
  end

  @doc "Merges nested maps, `b` winning; non-map values are replaced."
  def deep_merge(a, b) when is_map(a) and is_map(b),
    do: Map.merge(a, b, fn _, x, y -> deep_merge(x, y) end)

  def deep_merge(_a, b), do: b

  @doc """
  Gives the node the device tools the way `T3.DevicesTest` does: the pinned hub
  and agent-device fakes installed under the node's home (`hub:` picks another
  hub version, `nil` leaves it out) and a fake Android SDK on `ANDROID_HOME`,
  restored when the scenario ends. Starts `T3.Settings`; returns the context.
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
    Node.ensure(T3.Settings)
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
      previous = Application.fetch_env(:t3, key)
      Application.put_env(:t3, key, if(cli in clis, do: fake, else: "t3-test-no-#{cli}"))

      ExUnit.Callbacks.on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:t3, key, value)
          :error -> Application.delete_env(:t3, key)
        end
      end)
    end

    put_env("FAKE_TEXT_LOG", Path.join(context.node.home, "text-calls.jsonl"))
    Node.ensure(T3.Settings)
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
  Adds resource samples to `T3.Diagnostics` as if taken `ages` ms ago (newest
  first is not required), each a copy of the latest sample's process tree with
  `cpu` percent on the node's own process. Test setup for history that would
  otherwise take real minutes to collect.
  """
  def add_resource_samples(ages, cpu \\ 0.0) do
    now = System.system_time(:millisecond)

    :sys.replace_state(T3.Diagnostics, fn state ->
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

  @doc "Sets a `:t3` application env key for the rest of the scenario, restoring it after."
  def put_app_env(key, value) do
    previous = Application.fetch_env(:t3, key)
    Application.put_env(:t3, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:t3, key, value)
        :error -> Application.delete_env(:t3, key)
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
  Creates the thread `title` on its own worktree, a new branch `t3/<slug>` off
  `main` under `<home>/worktrees` as the node makes them, and records it as
  `context.worktree` (`%{thread, path, branch, root}`). `fields` go on the
  thread; `"branch"` and `"worktreePath"` there reuse an existing worktree.
  """
  def worktree_thread(context, title, project \\ nil, fields \\ %{}) do
    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Vcs.Registry}, id: T3.Vcs.Registry)
    )

    %{root: root} = project(context, project)
    branch = fields["branch"] || "t3/#{slug(title)}"

    path =
      fields["worktreePath"] ||
        (
          {:ok, %{"worktree" => %{"path" => path}}} =
            T3.Vcs.create_worktree(%{"cwd" => root, "refName" => "main", "newRefName" => branch})

          path
        )

    fields = Map.merge(%{"branch" => branch, "worktreePath" => path}, fields)

    context
    |> create_thread(title, project, fields)
    |> Map.put(:worktree, %{thread: title, path: path, branch: branch, root: root})
  end

  @doc """
  Starts `T3.StorageCleanup` and what it reads (settings, the provider session
  and VCS registries) if the scenario has not, with its hourly timer off so
  only the scenario sweeps. Returns the context.
  """
  def start_storage_cleanup(context) do
    unless Process.whereis(T3.StorageCleanup), do: put_app_env(:storage_cleanup_first_ms, nil)
    Node.ensure(T3.Settings)

    for name <- [T3.Codex.Registry, T3.Claude.Registry, T3.Acp.Registry, T3.Vcs.Registry],
        do: Node.ensure(Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name))

    Node.ensure(T3.StorageCleanup)
    context
  end

  @doc "Runs one storage sweep now and waits for it (`start_storage_cleanup/1` first)."
  def sweep_storage(context) do
    context = start_storage_cleanup(context)
    :ok = T3.StorageCleanup.sweep()
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
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Terminal.Registry},
        id: T3.Terminal.Registry
      )
    )

    Node.ensure({DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one})
    Node.ensure(T3.Terminal.Hub)

    {:ok, %{"pid" => shell}} =
      T3.Terminal.open(%{"threadId" => thread_id, "terminalId" => terminal_id, "cwd" => cwd})

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
    {frame, skipped, client} = T3.Test.WsClient.recv_until(client, Node.reply?(id))
    client = %{client | inbox: skipped ++ client.inbox}

    reply =
      case frame do
        %{"t" => "rpc.result", "result" => result} -> {:ok, result}
        %{"t" => "rpc.error", "error" => error} -> {:error, error, frame["detail"]}
      end

    {reply, put_client(context, name, client)}
  end
end

# --- added by W4 (terminal) ---

defmodule T3.Test.Node.Terminal do
  @moduledoc """
  Terminals as `features/terminal/` drives them: over the socket, the way a client
  does. The scenario's terminal is `context.terminal` (a `TerminalOpenInput` map);
  each client attaches to one terminal at a time, under `context.terminal_subs`
  (client name → subscription id). Folders the feature names (`/work/app`) live
  under the scenario's home (`folder/2`).
  """

  import ExUnit.Assertions

  alias T3.Test.{Node, WsClient}
  alias T3.Test.Node.World

  @doc """
  Starts the node's terminal services and makes `/bin/sh` the user's shell for
  the scenario (quick, and it reads no rc files).
  """
  def ensure(%{terminals_ready: true} = context), do: context

  def ensure(context) do
    Node.ensure({Registry, keys: :unique, name: T3.Terminal.Registry})
    Node.ensure({DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one})
    Node.ensure(T3.Terminal.Hub)
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
    [{pid, _}] = Registry.lookup(T3.Terminal.Registry, {input["threadId"], input["terminalId"]})
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

defmodule T3.Test.Node.Host do
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
