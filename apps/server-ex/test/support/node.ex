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
  `%{port, environment, home}`.
  """
  def start(dir) do
    File.mkdir_p!(dir)
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :port, 0)
    :persistent_term.erase({T3.Web, :token})
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Auth)
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))
    [{_node, %{"environmentId" => environment}}] = T3.Shell.environments()
    :ok = T3.Shell.subscribe(self())
    %{port: port, environment: environment, home: dir, store: Path.join(dir, "t3.sqlite")}
  end

  @doc """
  Stops the node's services and starts them again on the same state, as a
  restart does. Sockets are gone afterwards; steps reconnect.
  """
  def restart(%{home: dir}) do
    for child <- [T3.Web, T3.Shell, T3.Streams, T3.Auth, T3.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    start(dir)
  end

  @doc "Starts a service under the test supervisor if it is not running yet."
  def ensure(child) do
    case start_supervised(child) do
      {:ok, pid} -> pid
      {:error, {{:already_started, pid}, _}} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> raise "could not start #{inspect(child)}: #{inspect(reason)}"
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
  An HTTP request to the node: `{status, headers, body}`, with a JSON body decoded.
  Options: `bearer:`, `json:` (a body to send as JSON), `form:`, `body:`, `headers:`.
  """
  def http(%{port: port}, method, path, opts \\ []) do
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
          "subject_token_type" => "urn:t3:params:oauth:token-type:environment-bootstrap",
          "client_label" => "Test client"
        },
        fields
      )

    {status, _, body} = http(node, :post, "/oauth/token", form: form)
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
          Node.start(:"t3test#{System.unique_integer([:positive])}@127.0.0.1", :longnames)

        restart(node)
      end

    home = Path.join(node.home, "peer-#{System.unique_integer([:positive])}")

    {:ok, pid, name} =
      :peer.start(%{
        name: :"t3peer#{System.unique_integer([:positive])}",
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
        do: :ok = :erpc.call(name, Application, :put_env, [:t3, key, value])

    {:ok, _} = :erpc.call(name, Application, :ensure_all_started, [:t3])
    environment = :erpc.call(name, T3.Environment, :id, [])
    await_environment(name, 10_000)
    {node, %{name: name, pid: pid, environment: environment, home: home}}
  end

  defp await_environment(name, timeout) do
    unless Enum.any?(T3.Shell.environments(), &(elem(&1, 0) == name)) do
      receive do
        {:t3_shell, _} -> await_environment(name, timeout)
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
      {:function, 1, :__t3_variant__, 0,
       [{:clause, 1, [], [], [{:integer, 1, System.unique_integer([:positive])}]}]}

    export = {:attribute, 1, :export, [{:__t3_variant__, 0}]}

    {:ok, ^mod, beam} =
      :compile.forms(head ++ [module, export | body] ++ [mark | eof], [:binary, :debug_info])

    {mod, beam}
  end

  @doc """
  Makes the node run from a release at `<home>/release` (`RELEASE_ROOT`), under the
  service wrapper (`T3_SERVICE=1`) unless `service: false`. A restart the node asks
  for is sent to the test process as `{:t3_restart, status}` instead of stopping the
  VM. Environment, code paths, loaded versions and modules replaced by `bundle/4`
  are put back when the scenario ends. Returns the release root.
  """
  def release(%{home: home}, opts \\ []) do
    root = Path.join(home, "release")
    version = T3.Upgrade.version()
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
      do: System.put_env("T3_SERVICE", "1"),
      else: System.delete_env("T3_SERVICE")

    test = self()
    Application.put_env(:t3, :upgrade_stop, &send(test, {:t3_restart, &1}))

    unless :persistent_term.get({__MODULE__, :release}, false) do
      :persistent_term.put({__MODULE__, :release}, true)
      paths = :code.get_path()

      ExUnit.Callbacks.on_exit(fn ->
        System.delete_env("RELEASE_ROOT")
        System.delete_env("T3_SERVICE")
        Application.delete_env(:t3, :upgrade_stop)
        :persistent_term.erase({T3.Upgrade, :version})
        :persistent_term.erase({T3.Upgrade, :outcome})
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
      "platform" => T3.Upgrade.platform(),
      "applications" => %{"t3" => version},
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
    # Not `t3-<version>`: code paths move to that directory, which must not hide the
    # rest of the application's modules from the test VM.
    ebin = Path.join([dir, "lib", "t3_bundle-#{version}", "ebin"])
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
        T3.Upgrade.Source.file_name(version, T3.Upgrade.platform())
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
    if originals != %{}, do: T3.Hot.reload(Map.to_list(originals))
    :ok
  end
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

  @doc "Sets `:t3` app env for the rest of the scenario; the old value comes back when it ends."
  def put_app_env(key, value) do
    previous = Application.fetch_env(:t3, key)
    Application.put_env(:t3, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:t3, key, old)
        :error -> Application.delete_env(:t3, key)
      end
    end)
  end

  @doc "Sets (or with `nil` unsets) an OS environment variable for the rest of the scenario."
  def put_os_env(name, value) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  @doc "Deep-merges `patch` into the node's settings (T3.Settings must be running)."
  def merge_settings(patch) do
    {settings, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(deep_merge(settings, patch), version)
    :ok
  end

  defp deep_merge(%{} = left, %{} = right),
    do: Map.merge(left, right, fn _k, l, r -> deep_merge(l, r) end)

  defp deep_merge(_left, right), do: right

  @doc """
  Starts what a provider turn and a terminal need: the provider registries and
  supervisors, T3.Settings, T3.Terminal.Hub and T3.Mcp.
  """
  def provider_services do
    for {name, spec} <- [
          {T3.Codex.Registry, {Registry, keys: :unique, name: T3.Codex.Registry}},
          {T3.Claude.Registry, {Registry, keys: :unique, name: T3.Claude.Registry}},
          {T3.Acp.Registry, {Registry, keys: :unique, name: T3.Acp.Registry}},
          {T3.Codex.Supervisor,
           {DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one}},
          {T3.Terminal.Registry, {Registry, keys: :unique, name: T3.Terminal.Registry}},
          {T3.Terminal.Supervisor,
           {DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one}}
        ],
        do: Node.ensure(Supervisor.child_spec(spec, id: name))

    Enum.each([T3.Settings, T3.Terminal.Hub, T3.Mcp], &Node.ensure/1)
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

  @doc "Sends `text` as the user's message in thread `title` over the socket."
  def send_message(context, title, text) do
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
    :ok = T3.Streams.subscribe(id, self(), nil)
    await_run_loop(id, fun)
  end

  defp await_run_loop(id, fun) do
    runs = T3.StreamState.list(T3.Streams.Server.state(T3.Streams.ensure(id)), "run")

    case Enum.find(runs, fun) do
      nil ->
        failed = Enum.find(runs, &(&1["status"] == "failed"))
        if failed && not fun.(failed), do: flunk("the run failed: #{inspect(failed)}")

        receive do
          {:t3_stream, ^id, _} -> await_run_loop(id, fun)
        after
          10_000 -> flunk("no run matched in #{id}: #{inspect(runs)}")
        end

      run ->
        run
    end
  end

  @doc """
  Creates `title`, an idle thread on its own new worktree (a `t3/...` branch from
  `main`, under `<home>/worktrees`) of project `project` (created if missing), else
  of the scenario's only project or a new one, "api". The project's repository gets an `origin` (under a path with
  `github.com` in it, so `gh` is asked about its pull requests) whose default
  branch is `main`. Stores `context.worktree` as `%{path, branch, thread, repo}`.
  """
  def worktree_thread(context, title, project \\ nil, fields \\ %{}) do
    context =
      cond do
        project && is_nil((context[:projects] || %{})[project]) ->
          create_project(context, project)

        project ->
          context

        context[:projects] in [nil, %{}] ->
          create_project(context, "api")

        true ->
          context
      end

    repo = project(context, project).root
    with_origin(context, repo)
    branch = "t3/#{slug(title)}-#{System.unique_integer([:positive])}"

    {:ok, %{"worktree" => %{"path" => path}}} =
      T3.Vcs.create_worktree(%{"cwd" => repo, "refName" => "main", "newRefName" => branch})

    context
    |> create_thread(
      title,
      project,
      Map.merge(%{"branch" => branch, "worktreePath" => path}, fields)
    )
    |> Map.put(:worktree, %{path: path, branch: branch, thread: title, repo: repo})
  end

  defp with_origin(context, repo) do
    if git!(repo, ["remote"]) == "" do
      origin = Path.join([Node.tmp_dir(context.node, "remote"), "github.com", "acme", "api.git"])
      File.mkdir_p!(origin)
      git!(origin, ~w(init -q --bare -b main))
      git!(repo, ["remote", "add", "origin", origin])
      git!(repo, ~w(push -q origin main))
      git!(repo, ~w(remote set-head origin main))
    end

    :ok
  end

  @doc """
  Moves thread `title`'s creation, messages and runs `ms` into the past, as if
  nothing had happened in it since, and waits for its sidebar row.
  """
  def backdate_thread(context, title, ms) do
    id = thread_id(context, title)
    state = T3.Streams.Server.state(T3.Streams.ensure(id))
    at = iso_from_now(-ms)

    messages =
      for m <- T3.StreamState.list(state, "message"),
          do: {"message", m["id"], %{"s" => %{"createdAt" => at, "updatedAt" => at}}}

    runs =
      for r <- T3.StreamState.list(state, "run"),
          do:
            {"run", r["id"],
             %{"s" => Map.new(for(k <- ~w(requestedAt startedAt completedAt), r[k], do: {k, at}))}}

    {:ok, _} =
      T3.Streams.commit(
        id,
        :thread,
        [{"thread", id, %{"s" => %{"createdAt" => at}}}] ++ messages ++ runs
      )

    await_row(id, &(&1["createdAt"] == at))
    context
  end

  @doc """
  Starts T3.StorageCleanup (and what a sweep reads: providers, terminals) without
  its timed first sweep; returns its pid.
  """
  def storage_cleanup do
    provider_services()
    put_app_env(:storage_cleanup_first_ms, nil)
    Node.ensure(T3.StorageCleanup)
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
end
