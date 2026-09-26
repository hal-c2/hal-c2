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
    # Provider processes die with the node.
    if Process.whereis(T3.Codex.Supervisor) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(T3.Codex.Supervisor),
          do: DynamicSupervisor.terminate_child(T3.Codex.Supervisor, pid)
    end

    for child <- [T3.Web, T3.Shell, T3.Streams, T3.Auth, T3.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    node = start(dir)
    # As at boot: turns the stop cut off are settled, and continued if asked for, and
    # threads from before the search index are indexed.
    T3.Orchestration.Recovery.run()
    T3.Orchestration.Recovery.continue()
    T3.Search.backfill()
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
    Application.put_env(:t3, :codex_command, fake.("fake_codex.py"))
    Application.put_env(:t3, :claude_command, fake.("fake_claude.py"))

    Application.put_env(:t3, :acp_commands, %{
      "opencode" => fake.("fake_acp.py"),
      "cursor" => fake.("fake_acp.py")
    })

    Application.put_env(:t3, :text_codex_command, Path.join(@support, "fake_text_cli.py"))
    Application.put_env(:t3, :text_claude_command, Path.join(@support, "fake_text_cli.py"))
    for {key, value} <- env, do: System.put_env(key, value)

    ExUnit.Callbacks.on_exit(fn ->
      for key <-
            ~w(codex_command claude_command acp_commands text_codex_command text_claude_command)a,
          do: Application.delete_env(:t3, key)

      for {key, _} <- env, do: System.delete_env(key)
    end)

    for name <- [T3.Codex.Registry, T3.Claude.Registry, T3.Acp.Registry],
        do: Node.ensure(Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name))

    Node.ensure({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})
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

  @doc "A thread's live stream state (`T3.StreamState`); subscribes the test process to it."
  def stream(context, title) do
    id = thread_id(context, title)
    :ok = T3.Streams.subscribe(id, self(), nil)
    T3.Streams.Server.state(T3.Streams.ensure(id))
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
    do: context |> stream(title) |> T3.StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  @doc """
  Waits until `fun` holds for the thread's stream state and returns that state.
  Wakes on the stream's own commits, never on a timer.
  """
  def await_stream(context, title, fun, timeout \\ 5_000) do
    id = thread_id(context, title)
    state = stream(context, title)
    if fun.(state), do: state, else: await_stream_next(id, fun, timeout, state)
  end

  defp await_stream_next(id, fun, timeout, last) do
    receive do
      {:t3_stream, ^id, _} ->
        state = T3.Streams.Server.state(T3.Streams.ensure(id))
        if fun.(state), do: state, else: await_stream_next(id, fun, timeout, state)
    after
      timeout ->
        runs = last |> T3.StreamState.list("run") |> Enum.map(& &1["status"])
        flunk("#{id} never reached the expected state (runs: #{inspect(runs)})")
    end
  end

  @doc "Waits until the thread's runs, oldest first, have exactly these statuses."
  def await_runs(context, title, statuses) do
    await_stream(context, title, fn state ->
      state
      |> T3.StreamState.list("run")
      |> Enum.sort_by(& &1["ordinal"])
      |> Enum.map(& &1["status"]) ==
        statuses
    end)
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
      T3.Orchestration.dispatch(
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

    await_stream(
      context,
      title,
      &Enum.any?(T3.StreamState.list(&1, "run"), fn run -> run["status"] == "running" end)
    )

    # The sidebar row shows it too, as the node's restart recovery reads it.
    await_row(thread_id(context, title), &(&1["activeRunId"] != nil))
    context
  end

  @doc "A thread's queued messages as `{text, run}`, in queue order."
  def queued(context, title) do
    state = stream(context, title)
    messages = T3.StreamState.get(state, "message")

    state
    |> T3.StreamState.list("run")
    |> Enum.filter(&(&1["status"] == "queued"))
    |> Enum.sort_by(& &1["queuePosition"])
    |> Enum.map(&{messages[&1["userMessageId"]]["text"], &1})
  end

  @doc "The newest run whose user message reads `text`, or nil."
  def run_for(context, title, text) do
    state = stream(context, title)
    messages = T3.StreamState.get(state, "message")

    state
    |> T3.StreamState.list("run")
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
        T3.Orchestration.dispatch(%{
          "type" => "run.interrupt",
          "threadId" => thread_id(context, title),
          "runId" => running["id"]
        })

      await_stream(
        context,
        title,
        &(T3.StreamState.get(&1, "run")[running["id"]]["status"] != "running")
      )
    end

    known = Map.keys(T3.StreamState.get(stream(context, title), "runtime-request"))
    {{:ok, _}, context} = send_message(context, title, text)

    pending =
      &Enum.find(T3.StreamState.list(&1, "runtime-request"), fn r ->
        r["status"] == "pending" and r["id"] not in known
      end)

    state = await_stream(context, title, pending)
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

      await_stream(
        context,
        title,
        &(Enum.count(T3.StreamState.list(&1, "run"), fn r -> r["status"] == "completed" end) >
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
    :ok = T3.Streams.subscribe(id, self(), nil)

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
    Application.put_env(:t3, :title_retry_ms, 10)
    Node.ensure(T3.Settings)

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("FAKE_TEXT_ANSWERS")
      System.delete_env("FAKE_TEXT_LOG")
      Application.delete_env(:t3, :title_retry_ms)
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
  (`T3.WorktreeSetup`, its terminals and settings).
  """
  def worktrees(context) do
    Node.ensure(T3.Settings)
    Node.ensure(T3.Workspace)

    Node.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: T3.Terminal.Registry},
        id: T3.Terminal.Registry
      )
    )

    Node.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one},
        id: T3.Terminal.Supervisor
      )
    )

    Node.ensure(T3.Terminal.Hub)
    Node.ensure(T3.WorktreeSetup)
    context
  end

  @doc """
  Forks `source` into a new thread `title` (`thread.fork`), from its latest finished
  run unless `fields` name a `sourcePoint`, and registers it under `title`.
  """
  def fork_thread(context, source, title, fields \\ %{}) do
    id = "th-#{slug(title)}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      T3.Orchestration.dispatch(
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

    case T3.WorktreeSetup.subscribe(id, self()) do
      %{"phase" => "running"} -> await_setup_end(id, timeout)
      snapshot -> snapshot
    end
  end

  defp await_setup_end(id, timeout) do
    receive do
      {:t3_worktree_setup, ^id, %{"phase" => "running"}} -> await_setup_end(id, timeout)
      {:t3_worktree_setup, ^id, snapshot} -> snapshot
    after
      timeout -> flunk("the worktree setup of #{id} never ended")
    end
  end

  @doc "The message texts the fake Claude was sent, one per turn, oldest first."
  def claude_prompts(context) do
    case File.read(Path.join(context.node.home, "claude-prompts.log")) do
      {:ok, log} ->
        for line <- String.split(log, "\n", trim: true), do: JSON.decode!(line)["text"]

      {:error, _} ->
        []
    end
  end
end
