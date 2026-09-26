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
  restart does, then runs the node's `:boot` functions in order (the boot tasks
  `T3.Application` starts, such as `T3.Projects.auto_pull/0`, which a scenario
  opts into by adding them to `node.boot`). Sockets are gone afterwards; steps
  reconnect.
  """
  def restart(%{home: dir} = node) do
    # Services a step added with `ensure/1` stop first and come back after the
    # core, so in-memory state (clones, setups) is lost as in a real restart.
    ensured = Process.get({__MODULE__, :ensured}, [])

    for child <- Enum.reverse(ensured),
        do: ExUnit.Callbacks.stop_supervised(Supervisor.child_spec(child, []).id)

    for child <- [T3.Web, T3.Shell, T3.Streams, T3.Auth, T3.Store],
        do: ExUnit.Callbacks.stop_supervised(child)

    boot = Map.get(node, :boot, [])
    started = start(dir)
    Enum.each(ensured, &ensure/1)
    Enum.each(boot, & &1.())
    Map.put(started, :boot, boot)
  end

  @doc """
  Starts a service under the test supervisor if it is not running yet;
  `restart/1` starts it again.
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
      gh: Application.get_env(:t3, :gh_command),
      rules: System.get_env("FAKE_GH_RULES"),
      log: System.get_env("FAKE_GH_LOG")
    }

    System.put_env("PATH", bin <> ":" <> previous.path)
    Application.put_env(:t3, :gh_command, "gh")
    System.put_env("FAKE_GH_RULES", rules)
    System.put_env("FAKE_GH_LOG", log)

    ExUnit.Callbacks.on_exit(fn ->
      System.put_env("PATH", previous.path)
      restore_env("FAKE_GH_RULES", previous.rules)
      restore_env("FAKE_GH_LOG", previous.log)

      if previous.gh,
        do: Application.put_env(:t3, :gh_command, previous.gh),
        else: Application.delete_env(:t3, :gh_command)
    end)

    Node.ensure(T3.PullRequests.Refreshes)
    T3.PullRequests.invalidate(%{})
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
      Application.put_env(:t3, :gh_command, "t3-test-no-gh")
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

    T3.PullRequests.invalidate(%{})
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
      ~s(#!/bin/sh\nfor last; do :; done\ncd "$T3_FAKE_REMOTES" && exec sh -c "$last"\n)
    )

    File.chmod!(ssh, 0o755)
    previous = {System.get_env("GIT_SSH_COMMAND"), System.get_env("T3_FAKE_REMOTES")}
    System.put_env("GIT_SSH_COMMAND", ssh)
    System.put_env("T3_FAKE_REMOTES", dir)

    ExUnit.Callbacks.on_exit(fn ->
      restore_env("GIT_SSH_COMMAND", elem(previous, 0))
      restore_env("T3_FAKE_REMOTES", elem(previous, 1))
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
    previous = Application.get_env(:t3, :text_claude_command)
    Application.put_env(:t3, :text_claude_command, path)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:t3, :text_claude_command, previous) end)
    Node.ensure(T3.Settings)
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

  @doc "Deep-merges `patch` into the node's settings (starting `T3.Settings` if needed)."
  def put_settings(context, patch) do
    Node.ensure(T3.Settings)
    {settings, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(deep_merge(settings, patch), version)
    context
  end

  defp deep_merge(a, b),
    do:
      Map.merge(a, b, fn _, x, y -> if is_map(x) and is_map(y), do: deep_merge(x, y), else: y end)

  @doc """
  Writes the node's log (warnings and up) to a file for the rest of the scenario
  and returns the context with `:log` set to its path; read it with `logged/1`.
  """
  def capture_log(context) do
    path = Path.join(Node.tmp_dir(context.node, "log"), "node.log")
    id = :"t3_test_log_#{System.unique_integer([:positive])}"
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
    :ok = T3.Streams.subscribe(id, self(), nil)
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
    Node.ensure({Registry, keys: :unique, name: T3.Codex.Registry})
    Node.ensure({DynamicSupervisor, name: T3.Codex.Supervisor, strategy: :one_for_one})

    unless Application.get_env(:t3, :codex_command) == ["python3", "-u", @fake_codex] do
      previous = Application.get_env(:t3, :codex_command)
      Application.put_env(:t3, :codex_command, ["python3", "-u", @fake_codex])

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:t3, :codex_command, previous),
          else: Application.delete_env(:t3, :codex_command)
      end)
    end
  end

  defp completed_runs(id) do
    T3.Streams.Server.state(T3.Streams.ensure(id))
    |> T3.StreamState.list("run")
    |> Enum.filter(&(&1["status"] == "completed"))
  end

  defp await_completed_run(id, before) do
    receive do
      {:t3_stream, ^id, _} ->
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

  @doc "Adds `fun` to what the node runs each time it starts (see `T3.Test.Node.restart/1`)."
  def on_boot(context, fun),
    do: update_in(context, [:node], &Map.update(&1, :boot, [fun], fn boot -> boot ++ [fun] end))

  @doc """
  POSTs `body` as JSON to the node's HTTP `path` with a paired client's bearer token
  (standard scopes); returns `{status, decoded_body}`.
  """
  def http_post(context, path, body) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, token, _, _} = T3.Auth.exchange(T3.Auth.create_pairing_token(context.node.store))
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
  that needs first: `T3.WorktreeSetup`, terminals, and the fake Codex agent. Sets
  `context.setup_thread`, and `context.setup_snapshots` to the setup snapshots seen
  so far, oldest first (`await_setup/3` adds to them).
  """
  def launch_in_worktree(context, project \\ nil, text \\ "list the files", strategy \\ %{}) do
    worktree_services()
    thread_id = "th-worktree-#{System.unique_integer([:positive])}"
    T3.WorktreeSetup.subscribe(thread_id, self())
    :ok = T3.Streams.subscribe(thread_id, self(), nil)

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
  Starts what preparing and working in a new worktree needs: `T3.WorktreeSetup`,
  terminals (a setup script runs in one), and the fake Codex agent.
  """
  def worktree_services do
    Node.ensure(T3.Settings)
    Node.ensure(T3.Workspace)
    Node.ensure({Registry, keys: :unique, name: T3.Terminal.Registry})

    Node.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: T3.Terminal.Supervisor, strategy: :one_for_one},
        id: :terminal_sup
      )
    )

    Node.ensure(T3.Terminal.Hub)
    Node.ensure(T3.WorktreeSetup)
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
          {:t3_worktree_setup, ^thread_id, snapshot} ->
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
end
