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
  `%{port, environment, home}`. `before_serving` runs once the stores are up and
  before the socket listens.
  """
  def start(dir, before_serving \\ fn -> :ok end) do
    File.mkdir_p!(dir)
    Application.put_env(:t3, :home, dir)
    Application.put_env(:t3, :port, 0)
    :persistent_term.erase({T3.Web, :token})
    start_supervised!({T3.Store, path: Path.join(dir, "t3.sqlite")})
    start_supervised!(T3.Auth)
    start_supervised!(T3.Streams)
    start_supervised!(T3.Shell)
    before_serving.()
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(T3.Web))
    [{_node, %{"environmentId" => environment}}] = T3.Shell.environments()
    :ok = T3.Shell.subscribe(self())
    %{port: port, environment: environment, home: dir, store: Path.join(dir, "t3.sqlite")}
  end

  @doc """
  Stops the node's services and starts them again on the same state, as a
  restart does, and settles the turns the restart cut off as a booting node does
  (`T3.Orchestration.Recovery`), indexes messages search has not seen
  (`T3.Search.backfill/0`), continuing the threads it may when settings run.
  Sockets are gone afterwards; steps reconnect. `while_stopped` runs after the
  services stop and before they start, as an operator's offline task would.
  """
  def restart(%{home: dir}, while_stopped \\ fn -> :ok end) do
    # Services a scenario started on demand come back too, reloading what they stored.
    on_demand = Enum.filter([T3.ScheduledTasks], &Process.whereis/1)

    for child <- on_demand ++ [T3.Web, T3.Shell, T3.Streams, T3.Auth, T3.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    while_stopped.()

    # Turns are settled, and old messages indexed for search, before the socket
    # serves anyone, as the app boots.
    node =
      start(dir, fn ->
        T3.Orchestration.Recovery.run()
        T3.Search.backfill()
      end)

    # Then, once turns can start, cut-off threads may continue (settings permitting).
    if Process.whereis(T3.Settings),
      do: T3.Orchestration.Recovery.continue(),
      else: :persistent_term.erase({T3.Orchestration.Recovery, :continuable})

    Enum.each(on_demand, &ensure/1)
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
  # --- added by W8 ---

  @fake_codex Path.expand("fake_codex.py", __DIR__)
  @fake_claude Path.expand("fake_claude.py", __DIR__)
  @fake_acp Path.expand("fake_acp.py", __DIR__)

  @doc """
  Makes the node able to run turns: the scripted fake Codex, Claude and OpenCode
  (`test/support/fake_*.py`; a message containing "wait" keeps its turn running,
  "approve" asks for approval, "ask" asks a question) and the runtimes' registries.
  Codex's requests are logged for `codex_requests/2`.
  """
  def providers(context) do
    Application.put_env(:t3, :codex_command, ["python3", "-u", @fake_codex])
    Application.put_env(:t3, :claude_command, ["python3", "-u", @fake_claude])
    Application.put_env(:t3, :acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})

    ExUnit.Callbacks.on_exit(fn ->
      for key <- [:codex_command, :claude_command, :acp_commands],
          do: Application.delete_env(:t3, key)
    end)

    Node.ensure(T3.Settings)

    for {name, id} <- [
          {T3.Codex.Registry, :codex_registry},
          {T3.Claude.Registry, :claude_registry},
          {T3.Acp.Registry, :acp_registry}
        ],
        do: Node.ensure(Supervisor.child_spec({Registry, keys: :unique, name: name}, id: id))

    Node.ensure({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})

    log = context[:codex_log] || Path.join(Node.tmp_dir(context.node, "codex"), "requests.jsonl")
    System.put_env("FAKE_CODEX_REQUEST_LOG", log)
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_CODEX_REQUEST_LOG") end)
    Map.put(context, :codex_log, log)
  end

  @doc "The requests the fake Codex received with `method` (after `providers/1`), oldest first."
  def codex_requests(context, method) do
    case File.read(context.codex_log) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true),
            %{"method" => ^method} = request <- [JSON.decode!(line)],
            do: request["params"]

      _ ->
        []
    end
  end

  @doc """
  Creates a thread whose id is its name (`"t1"`), as the orchestration features
  name threads, and makes it the scenario's current thread (`context.thread`).
  """
  def named_thread(context, name, project \\ nil, fields \\ %{}) do
    context
    |> create_thread(name, project, Map.put(fields, "threadId", name))
    |> Map.put(:thread, name)
  end

  @doc "A thread's live stream state (`T3.StreamState`)."
  def state(context, title),
    do: T3.Streams.Server.state(T3.Streams.ensure(thread_id(context, title)))

  @doc "A thread's entities of `kind` (`\"run\"`, `\"message\"`, ...), in stream order."
  def entities(context, title, kind), do: T3.StreamState.list(state(context, title), kind)

  @doc """
  Waits until `fun` holds for the thread's stream state, re-checking on every
  commit to the stream; returns the state.
  """
  def await_state(context, title, fun, timeout \\ 5_000) do
    id = thread_id(context, title)
    :ok = T3.Streams.subscribe(id, self(), nil)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      await_state_loop(id, fun, deadline)
    after
      T3.Streams.unsubscribe(id, self())
    end
  end

  defp await_state_loop(id, fun, deadline) do
    state = T3.Streams.Server.state(T3.Streams.ensure(id))

    if fun.(state) do
      state
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      receive do
        {:t3_stream, ^id, _} -> await_state_loop(id, fun, deadline)
      after
        max(remaining, 0) ->
          if fun.(T3.Streams.Server.state(T3.Streams.ensure(id))),
            do: T3.Streams.Server.state(T3.Streams.ensure(id)),
            else: flunk("#{id} never reached the expected state")
      end
    end
  end

  @doc "The latest run of a thread (highest ordinal), or nil."
  def latest_run(context, title),
    do: context |> entities(title, "run") |> Enum.max_by(& &1["ordinal"], fn -> nil end)

  @doc "Waits until the thread's latest run has `status`; returns that run."
  def await_run(context, title, status, timeout \\ 5_000) do
    await_state(
      context,
      title,
      fn state ->
        case Enum.max_by(T3.StreamState.list(state, "run"), & &1["ordinal"], fn -> nil end) do
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
    T3.Store.path()
    |> T3.Store.reduce_stream(thread_id(context, title), 0, [], &[&1 | &2])
    |> Enum.reverse()
  end

  @doc """
  Dispatches an orchestration command straight to the engine and keeps the reply
  as `context.reply` (`{:ok, result}` or `{:error, message, nil}`), as the shared
  refusal steps read it.
  """
  def command(context, command) do
    command = Map.put_new(command, "commandId", "cmd-#{System.unique_integer([:positive])}")
    Map.put(context, :reply, normalize_reply(T3.Orchestration.dispatch(command)))
  end

  @doc "Normalizes an engine or RPC reply to `{:ok, r}` or `{:error, message, detail}`."
  def normalize_reply({:ok, result}), do: {:ok, result}
  def normalize_reply({:error, message, detail}), do: {:error, message, detail}

  def normalize_reply({:error, %{} = detail}),
    do: {:error, to_string(detail["message"] || detail["cause"] || detail["_tag"]), detail}

  def normalize_reply({:error, message}), do: {:error, to_string(message), nil}
  def normalize_reply(:ok), do: {:ok, nil}

  @doc "Sends a user message to a thread (`message.dispatch`); the reply is `context.reply`."
  def send_message(context, title, text, extra \\ %{}) do
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
    log = Path.join(Node.tmp_dir(context.node, "text"), "calls.jsonl")
    System.put_env("FAKE_TEXT_LOG", log)
    System.put_env("FAKE_TEXT_ANSWER", JSON.encode!(answer))

    Application.put_env(
      :t3,
      :text_claude_command,
      if(:claude in clis, do: @fake_text, else: "t3-test-no-claude")
    )

    Application.put_env(
      :t3,
      :text_codex_command,
      if(:codex in clis, do: @fake_text, else: "t3-test-no-codex")
    )

    ExUnit.Callbacks.on_exit(fn ->
      for var <- ~w(FAKE_TEXT_LOG FAKE_TEXT_ANSWER FAKE_TEXT_FAIL FAKE_TEXT_HANG),
          do: System.delete_env(var)

      for key <- [:text_claude_command, :text_codex_command],
          do: Application.delete_env(:t3, key)
    end)

    Node.ensure(T3.Settings)
    Map.put(context, :text_log, log)
  end

  @doc "The fake text writers' calls so far, oldest first (`%{\"argv\", \"cwd\", \"prompt\"}`)."
  def text_calls(context) do
    case File.read(context.text_log) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  @doc """
  Starts a turn that keeps running (the fake provider's "wait") in the named thread,
  creating the thread first when the scenario has none by that name.
  """
  def running_turn(context, title, text \\ "wait for it") do
    context = providers(context)

    context =
      if (context[:threads] || %{})[title], do: context, else: named_thread(context, title)

    context = send_message(context, title, text)
    assert {:ok, _} = context.reply, "message.dispatch failed: #{inspect(context.reply)}"
    run = await_run(context, title, "running")
    context |> Map.delete(:reply) |> Map.put(:thread, title) |> Map.put(:running, run["id"])
  end

  @doc """
  Sends a message that queues behind the thread's active run (`queue_after_active`,
  as the composer's queue does); its run id is appended to `context.queued`.
  """
  def queue_message(context, title, text) do
    before = MapSet.new(entities(context, title, "run"), & &1["id"])

    context =
      send_message(context, title, text, %{"dispatchMode" => %{"type" => "queue_after_active"}})

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
  socket receives it, filtered by `T3.Projection.Timeline`. Returns `{items, context}`.
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
      |> Enum.reduce(T3.StreamState.new(), fn {[kind, eid, entity], seq}, state ->
        T3.StreamState.apply_event(state, %{
          seq: seq,
          kind: kind,
          entity: eid,
          patch: %{"s" => entity}
        })
      end)

    {T3.Projection.Timeline.local_items(state), put_client(context, client)}
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
    [{pid, _}] = Registry.lookup(T3.Codex.Registry, thread_id(context, title))
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
  Deep-merges `patch` into the node's settings (`T3.Settings`, started if needed),
  as the settings RPC saves them; returns the context.
  """
  def write_settings(context, patch) do
    Node.ensure(T3.Settings)
    {settings, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(deep_merge(settings, patch), version)
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

  @doc "The user messages the fake Claude received since `log_claude_prompts/1`, oldest first."
  def claude_prompts(context) do
    case File.read(context.claude_log) do
      {:ok, text} -> for line <- String.split(text, "\n", trim: true), do: JSON.decode!(line)
      _ -> []
    end
  end

  @doc """
  Writes a Node server database holding only `orchestration_events`, as
  `T3.Import.V2` reads it. Each event is `{aggregate, stream, type, payload, at_ms}`;
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

  defp deep_merge(a, b),
    do:
      Map.merge(a, b, fn _, x, y -> if is_map(x) and is_map(y), do: deep_merge(x, y), else: y end)
end
