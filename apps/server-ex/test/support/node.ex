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
end
