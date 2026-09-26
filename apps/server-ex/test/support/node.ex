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
    # Worktree setups live in memory: a restart forgets them.
    setups = Process.whereis(T3.WorktreeSetup) != nil

    for child <- [T3.WorktreeSetup, T3.Web, T3.Shell, T3.Streams, T3.Auth, T3.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    node = start(dir)
    if setups, do: ensure(T3.WorktreeSetup)
    # Boot settles the turns the restart cut off, and continues what it can once
    # turns can start, as `T3.Application` does.
    T3.Orchestration.Recovery.run()
    if Process.whereis(T3.Codex.Supervisor), do: T3.Orchestration.Recovery.continue()
    node
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

  # --- added by W7 ---

  @fake_codex Path.expand("fake_codex.py", __DIR__)
  @fake_claude Path.expand("fake_claude.py", __DIR__)
  @fake_acp Path.expand("fake_acp.py", __DIR__)

  @doc """
  Starts what real turns need, once per scenario: settings, the provider
  runtimes on the fake Codex, Claude and OpenCode (ACP) CLIs
  (`test/support/fake_codex.py`, `fake_claude.py`, `fake_acp.py`: a message
  containing "wait" keeps its turn running) and the MCP server. Each fake logs
  what it was sent under the node's home (`provider_inputs/1`,
  `provider_prompts/2`, `codex_requests/1`, `codex_sessions/1`, `claude_starts/1`).
  """
  def providers(context) do
    if Application.get_env(:t3, :codex_command) == nil do
      log = "FAKE_CODEX_INPUT_LOG=" <> Path.join(context.node.home, "codex-inputs.jsonl")
      requests = "FAKE_CODEX_REQUEST_LOG=" <> Path.join(context.node.home, "codex-requests.log")
      sessions = "FAKE_CODEX_SESSION_LOG=" <> Path.join(context.node.home, "codex-sessions.jsonl")

      Application.put_env(:t3, :codex_command, [
        "env",
        log,
        requests,
        sessions,
        "python3",
        "-u",
        @fake_codex
      ])

      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :codex_command) end)
    end

    if Application.get_env(:t3, :claude_command) == nil do
      log = "FAKE_CLAUDE_ARGV_LOG=" <> Path.join(context.node.home, "claude-argv.jsonl")
      input = "FAKE_CLAUDE_INPUT_LOG=" <> Path.join(context.node.home, "claude-inputs.jsonl")

      Application.put_env(:t3, :claude_command, [
        "env",
        log,
        input,
        "python3",
        "-u",
        @fake_claude
      ])

      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :claude_command) end)
    end

    if Application.get_env(:t3, :acp_commands) == nil do
      log = "FAKE_ACP_INPUT_LOG=" <> Path.join(context.node.home, "acp-inputs.jsonl")

      Application.put_env(:t3, :acp_commands, %{
        "opencode" => ["env", log, "python3", "-u", @fake_acp]
      })

      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :acp_commands) end)
    end

    for child <- [
          T3.Settings,
          registry(T3.Codex.Registry),
          registry(T3.Claude.Registry),
          registry(T3.Acp.Registry),
          Supervisor.child_spec(
            {DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one},
            id: T3.Codex.Supervisor
          ),
          T3.Mcp
        ],
        do: Node.ensure(child)

    context
  end

  defp registry(name),
    do: Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name)

  @doc """
  Launches `title` in `project` (nil for the only one) with a first message, as
  `orchestration.launchThread` does, on the fake Codex CLI in full-access mode.
  `fields` override the launch input. Returns once the thread has its row.
  """
  def launch_thread(context, title, project, text, fields \\ %{}) do
    context = providers(context)
    id = fields["threadId"] || "th-#{slug(title)}-#{System.unique_integer([:positive])}"
    :ok = T3.Streams.subscribe(id, self(), nil)

    {:ok, _} =
      T3.Orchestration.launch_thread(
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

  @doc "A thread's stream state (see `T3.StreamState`)."
  def state(context, title),
    do: T3.Streams.Server.state(T3.Streams.ensure(thread_id(context, title)))

  @doc "A thread's runs, oldest first."
  def runs(context, title),
    do: context |> state(title) |> T3.StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  @doc """
  Waits until a thread's stream state satisfies `fun` and returns that state.
  """
  def await_state(context, title, fun, timeout \\ 5_000) do
    id = thread_id(context, title)
    :ok = T3.Streams.subscribe(id, self(), nil)
    deadline = System.monotonic_time(:millisecond) + timeout
    await_state_loop(id, fun, deadline)
  end

  defp await_state_loop(id, fun, deadline) do
    state = T3.Streams.Server.state(T3.Streams.ensure(id))

    if fun.(state) do
      state
    else
      receive do
        {:t3_stream, ^id, _} -> await_state_loop(id, fun, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("#{id} never reached the expected state")
      end
    end
  end

  @doc "Waits until a thread's runs, oldest first, have exactly `statuses`."
  def await_runs(context, title, statuses, timeout \\ 5_000) do
    await_state(
      context,
      title,
      fn state ->
        state
        |> T3.StreamState.list("run")
        |> Enum.sort_by(& &1["ordinal"])
        |> Enum.map(& &1["status"]) == statuses
      end,
      timeout
    )
  end

  @doc """
  Sends one JSON-RPC request to the MCP server as the agent of `caller` (a
  thread title) on `instance`; returns `{status, body}` as `T3.Mcp.handle/2` does.
  Once the MCP server runs, it can be called from any process (a waiting call in
  a `Task`, say).
  """
  def mcp(context, caller, method, params \\ %{}, instance \\ "codex") do
    context = if Process.whereis(T3.Mcp), do: context, else: providers(context)
    %{authorization: auth} = T3.Mcp.server(thread_id(context, caller), instance)
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    T3.Mcp.handle(auth, JSON.encode!(request))
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
  def codex_requests(context) do
    case File.read(Path.join(context.node.home, "codex-requests.log")) do
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
    {:ok, _} = T3.Orchestration.dispatch(message_command(context, title, text, fields))
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
            T3.StreamState.list(state, "run"),
            &(&1["ordinal"] == ordinal and &1["status"] in ~w(completed failed interrupted))
          )
        end,
        timeout
      )

    Enum.find(T3.StreamState.list(state, "run"), &(&1["ordinal"] == ordinal))
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
      runs = T3.Streams.Server.state(T3.Streams.ensure(id)) |> T3.StreamState.list("run")

      Enum.reduce(runs, String.replace(text, id, name), fn run, text ->
        String.replace(text, run["id"], "run-#{run["ordinal"]}")
      end)
    end)
  end

  @doc """
  Starts what preparing a new worktree needs (`T3.WorktreeSetup` and the terminals
  its setup script runs in), with the fake providers, as `T3.Application` does.
  """
  def worktree_setup(context) do
    context = providers(context)

    for child <- [
          registry(T3.Terminal.Registry),
          Supervisor.child_spec(
            {DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one},
            id: T3.Terminal.Supervisor
          ),
          T3.Terminal.Hub,
          T3.WorktreeSetup
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
end
