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
      "FAKE_CLAUDE_LOG" => logs["claude"],
      "FAKE_CODEX_LOG" => logs["codex"],
      "FAKE_ACP_LOG" => logs["acp"],
      # Cursor's sidecar runs under this Node binary.
      "T3_NODE_COMMAND" => acp
    }

    System.put_env(env)
    Application.put_env(:t3, :claude_command, [claude])
    Application.put_env(:t3, :codex_command, [codex])
    Application.put_env(:t3, :acp_commands, %{"pi" => [acp]})
    reset_provider_caches()

    ExUnit.Callbacks.on_exit(fn ->
      for {name, _} <- env, do: System.delete_env(name)

      for key <-
            ~w(FAKE_CODEX_MODELS FAKE_CODEX_ACCOUNT FAKE_CLAUDE_USAGE FAKE_ACP_MODELS FAKE_ACP_CAPS FAKE_AUTH_FILE FAKE_CODEX_CONSUME_LOG
                    FAKE_CODEX_CONSUME_FAIL),
          do: System.delete_env(key)

      for key <- [:claude_command, :codex_command, :acp_commands],
          do: Application.delete_env(:t3, key)

      reset_provider_caches()
    end)

    Node.ensure(T3.Settings)
    Node.ensure({Registry, keys: :unique, name: T3.Codex.Registry})

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Claude.Registry},
        id: :claude_registry
      )
    )

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Acp.Registry}, id: :acp_registry)
    )

    Node.ensure({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})

    # The built-in ACP agents run the fake through their binary setting, unless the
    # scenario already pointed them elsewhere.
    {settings, _} = T3.Settings.get()

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
          {T3.Codex.Provider, :models},
          {T3.Codex.Provider, :version},
          {T3.Claude.Provider, :version},
          {T3.ProviderUpdates, "codex"},
          {T3.ProviderUpdates, "claudeAgent"}
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

  @doc "Deep-merges `patch` into the node's settings (starting `T3.Settings` if needed)."
  def merge_settings(patch) do
    Node.ensure(T3.Settings)
    {settings, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(deep_merge(settings, patch), version)
    :ok
  end

  @doc "Merges maps recursively; `patch` wins on anything that is not a map on both sides."
  def deep_merge(%{} = left, %{} = right),
    do: Map.merge(left, right, fn _k, l, r -> deep_merge(l, r) end)

  def deep_merge(_left, right), do: right

  @doc """
  Starts a thread on `instance` with `text` as its first message, as the composer
  does (`orchestration.launchThread`), and subscribes the test process to its stream.
  `fields` override the launch input (`runtimeMode`, `interactionMode`, `model`, ...).
  """
  def launch_thread(context, title, instance, text, fields \\ %{}) do
    id = "th-#{slug(title)}-#{System.unique_integer([:positive])}"
    :ok = T3.Streams.subscribe(id, self(), nil)
    project = if context[:projects] not in [nil, %{}], do: project(context).id
    {model, fields} = Map.pop(fields, "model", default_model(instance))

    {:ok, _} =
      T3.Orchestration.launch_thread(
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

  @doc "The thread the scenario is about: the last one `launch_thread/5` started."
  def current_thread(context), do: context[:current_thread] || flunk("no thread was started")

  defp default_model("claudeAgent"), do: "sonnet"
  defp default_model("codex"), do: "gpt-5.4"
  defp default_model(_), do: "default"

  @doc """
  Sends a user message to a thread (`message.dispatch`), queued after a running turn;
  `extra` overrides fields, and a nil drops one (`"dispatchMode" => nil` lets the node
  decide whether to steer, as the composer does).
  """
  def send_message(context, title, text, extra \\ %{}) do
    id = thread_id(context, title)
    :ok = T3.Streams.subscribe(id, self(), nil)

    {:ok, _} =
      T3.Orchestration.dispatch(
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

  @doc "A thread's whole stream state (`T3.StreamState`)."
  def stream(context, title) do
    id = thread_id(context, title)
    T3.Streams.Server.state(T3.Streams.ensure(id))
  end

  @doc "A thread's runs in order."
  def runs(context, title),
    do: context |> stream(title) |> T3.StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  @doc """
  Waits until `fun` returns a truthy value for the thread's stream state, re-checking
  on each change of the stream (the test process subscribes); returns that value.
  """
  def await_stream(context, title, fun, timeout \\ 5_000) do
    id = thread_id(context, title)
    :ok = T3.Streams.subscribe(id, self(), nil)
    deadline = System.monotonic_time(:millisecond) + timeout
    await_stream_loop(context, title, id, fun, deadline)
  end

  defp await_stream_loop(context, title, id, fun, deadline) do
    state = stream(context, title)

    case fun.(state) do
      result when result not in [nil, false] ->
        result

      _ ->
        wait = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:t3_stream, ^id, _} -> await_stream_loop(context, title, id, fun, deadline)
        after
          wait ->
            flunk(
              "#{title}'s stream never got there; runs: " <>
                inspect(for r <- T3.StreamState.list(state, "run"), do: r["status"]) <>
                "; errors: " <>
                inspect(
                  for s <- T3.StreamState.list(state, "provider-session"), do: s["lastError"]
                )
            )
        end
    end
  end

  @doc "Waits until the thread's runs, in order, have `statuses`; returns the stream state."
  def await_runs(context, title, statuses) do
    await_stream(context, title, fn state ->
      runs = state |> T3.StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])
      if Enum.map(runs, & &1["status"]) == statuses, do: state
    end)
  end

  @doc "Waits for the thread's pending provider request (approval or question)."
  def await_request(context, title) do
    await_stream(context, title, fn state ->
      Enum.find(T3.StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
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
  def providers(context) do
    context = fake_providers(context)
    id = System.unique_integer([:positive])

    client =
      Node.sub(client(context), id, %{"type" => "config", "node" => Atom.to_string(node())})

    {frame, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == id), 10_000)
    {frame["config"]["providers"], put_client(context, client)}
  end

  @doc "One provider entry (by instance id) from `providers/1`, or nil."
  def provider(context, instance) do
    {providers, _} = providers(context)
    Enum.find(providers, &(&1["instanceId"] == instance))
  end

  @doc "Every event a thread's stream has committed, oldest first (`T3.Store.reduce_stream/6`)."
  def stream_events(context, title) do
    T3.Store.path()
    |> T3.Store.reduce_stream(thread_id(context, title), 0, [], &[&1 | &2])
    |> Enum.reverse()
  end

  @doc """
  Runs text generation (titles, commits) on `test/support/fake_text_cli.py` for the
  CLIs in `clis` (`:claude`, `:codex`); the others are missing. Returns the context
  with `:text_log`, read with `text_calls/1`.
  """
  def fake_text(context, clis) do
    fake = Path.join(@fakes, "fake_text_cli.py")
    log = Path.join(context.node.home, "text-calls.jsonl")
    System.put_env("FAKE_TEXT_LOG", log)

    for {cli, key, missing} <- [
          {:claude, :text_claude_command, "t3-test-no-claude"},
          {:codex, :text_codex_command, "t3-test-no-codex"}
        ],
        do: Application.put_env(:t3, key, if(cli in clis, do: fake, else: missing))

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("FAKE_TEXT_LOG")
      Application.put_env(:t3, :text_claude_command, "t3-test-no-claude")
      Application.put_env(:t3, :text_codex_command, "t3-test-no-codex")
    end)

    Map.put(context, :text_log, log)
  end

  @doc "The text-generation CLI calls `fake_text/2` recorded: `%{argv, cwd, prompt}` each."
  def text_calls(context) do
    case File.read(context.text_log) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  @doc "Waits until the thread's last run is `running` (its provider has the turn)."
  def await_running(context, title) do
    await_stream(context, title, fn state ->
      case state |> T3.StreamState.list("run") |> Enum.sort_by(& &1["ordinal"]) |> List.last() do
        %{"status" => "running"} = run -> run
        _ -> nil
      end
    end)
  end

  @doc "Waits until the thread's last run has ended; returns the stream state."
  def await_idle(context, title) do
    await_stream(context, title, fn state ->
      runs = T3.StreamState.list(state, "run")

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
    context = launch_thread(context, title, instance, first, fields)
    await_idle(context, title)

    Enum.reduce(rest, context, fn text, context ->
      count = length(runs(context, title))
      context = send_message(context, title, text)

      await_stream(context, title, fn state ->
        length(T3.StreamState.list(state, "run")) > count
      end)

      await_idle(context, title)
      context
    end)
  end

  @doc "The assistant's replies in a thread, oldest first."
  def replies(context, title) do
    for m <- context |> stream(title) |> T3.StreamState.list("message"),
        m["role"] == "assistant",
        do: m["text"]
  end

  @doc "Rolls a thread back to the end of its turn `ordinal` (`checkpoint.rollback`)."
  def rollback(context, title, ordinal, extra \\ %{}) do
    id = thread_id(context, title)
    scope = T3.Checkpoint.scope_id(id)

    reply =
      T3.Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "checkpoint.rollback",
            "commandId" => "cmd-#{System.unique_integer([:positive])}",
            "threadId" => id,
            "scopeId" => scope,
            "checkpointId" => T3.Checkpoint.checkpoint_id(scope, ordinal)
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
    :ok = T3.Streams.subscribe(id, self(), nil)

    reply =
      T3.Orchestration.dispatch(%{
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
    cache = Path.join([context.node.home, "cache", "acp-registry", "registry.json"])
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

    :persistent_term.erase({T3.Acp.Catalog, :index})
    commands = Application.get_env(:t3, :acp_commands, %{})
    Application.put_env(:t3, :acp_commands, Map.put(commands, id, [context.fakes.acp]))

    merge_settings(%{
      "providerInstances" => %{
        id => %{"driver" => "acpRegistry", "displayName" => name, "config" => %{"agentId" => id}}
      }
    })

    ExUnit.Callbacks.on_exit(fn ->
      T3.Acp.forget(id)
      :persistent_term.erase({T3.Acp.Catalog, :index})
      Application.put_env(:t3, :acp_commands, commands)
    end)

    T3.Acp.reload(id)
    context
  end

  @doc """
  Starts recording which transcripts `T3.Usage` parses (call tracing on
  `T3.Usage.Transcripts.read/3` in the usage process and the tasks it spawns);
  read them back with `usage_reads/0`. Tracing stops when the scenario ends.
  """
  def trace_usage_reads(context) do
    usage = Process.whereis(T3.Usage) || flunk("T3.Usage is not running")
    :erlang.trace_pattern({T3.Usage.Transcripts, :read, 3}, true, [])
    :erlang.trace(usage, true, [:call, :set_on_spawn, {:tracer, self()}])

    ExUnit.Callbacks.on_exit(fn ->
      :erlang.trace_pattern({T3.Usage.Transcripts, :read, 3}, false, [])
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
      {:trace, _pid, :call, {T3.Usage.Transcripts, :read, [path, provider, resume]}} ->
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
      {T3.Orchestration.IdleSessions, &T3.Orchestration.IdleSessions.check/0},
      {T3.ProviderUsageLimits, fn -> tick(T3.ProviderUsageLimits) end},
      {T3.UsageLimitSources, fn -> tick(T3.UsageLimitSources) end}
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
