defmodule HalC2.Steps.Files.AddingProjects do
  @moduledoc """
  Steps for `features/files/adding-projects.feature`. Clones run real `git` against
  a `git://` server on loopback that either holds the connection open (a clone in
  flight) or refuses the repository (`git_server/2`); hosts are looked up through
  fake CLIs and a fake Bitbucket API.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias HalC2.Test.Node
  alias HalC2.Test.Node.{Host, World}

  @fake_cli Path.expand("../../support/fake_gh.py", __DIR__)
  @clones_sub 7_001

  # --- local folders ---------------------------------------------------------------

  step "a client creates a project at {string} without a title", %{args: [path]} = context do
    File.mkdir_p!(Host.path(context, path))
    create(context, path, %{})
  end

  step "the project is titled {string}", %{args: [title]} = context do
    assert {:ok, %{"title" => ^title}} = context.reply
    context
  end

  step "its workspace folder is the expanded home path ending in {string}",
       %{args: [suffix]} = context do
    assert {:ok, %{"workspaceRoot" => root}} = context.reply
    assert root == Path.join(Host.home(context), suffix)
    context
  end

  step "{string} holds the folders {string} and {string}", %{args: [dir | names]} = context do
    for name <- names, do: File.mkdir_p!(Path.join(Host.path(context, dir), name))
    context
  end

  step "{string} cannot be read by the node", %{args: [dir]} = context do
    real = Host.path(context, dir)
    File.mkdir_p!(Path.join(real, "secret"))
    File.chmod!(real, 0o000)
    on_exit(fn -> File.chmod(real, 0o755) end)
    context
  end

  step "an empty list is returned without an error", context do
    assert {:ok, %{"entries" => []}} = context.reply
    context
  end

  step "a client creates a project at {string} without asking to create the folder",
       %{args: [path]} = context do
    create(context, path, %{})
  end

  step "a client creates a project at {string} and asks to create the folder",
       %{args: [path]} = context do
    create(context, path, %{"createWorkspaceRootIfMissing" => true})
  end

  step "the node answers that {string} does not exist on this machine",
       %{args: [path]} = context do
    assert {:error, error, _} = context.reply
    assert error =~ "#{Host.path(context, path)} does not exist on this machine"
    context
  end

  step "no project is created", context do
    assert projects() == []
    context
  end

  step "the project {string} is listed for {string}", %{args: [title, _env]} = context do
    listed(context, title)
  end

  # --- clones ----------------------------------------------------------------------

  step "a client starts cloning {string} into {string}", %{args: [url, dest]} = context do
    # The host's address leads to a loopback git server that never answers.
    port = git_server(context, :hang)
    [origin] = Regex.run(~r{^https?://[^/]+/}, url)
    git_env(%{"url.git://127.0.0.1:#{port}/.insteadOf" => origin})
    start_clone(context, url, dest)
  end

  step "the project {string} is listed for {string} immediately",
       %{args: [title, _env]} = context do
    context = listed(context, title)
    assert current_clone(context)["phase"] == "running"
    context
  end

  step "the clone is reported as running at the {string} stage", %{args: [stage]} = context do
    await_clone(context, &(&1["phase"] == "running" and &1["stage"] == stage))
  end

  step "the clone is reported as running", context do
    await_clone(context, &(&1["phase"] == "running"))
  end

  step "a clone of {string} is running", %{args: [repository]} = context do
    running_clone(context, repository)
  end

  step "git reports {string}", %{args: [line]} = context do
    send(
      HalC2.ProjectClones,
      {:clone_progress, context.clone.id, HalC2.ProjectClones.progress(line)}
    )

    context
  end

  step "the clone is at the {string} stage with {int} percent done",
       %{args: [stage, percent]} = context do
    await_clone(context, &(&1["stage"] == stage and &1["percent"] == percent))
  end

  step "a clone of {string} finished", %{args: [repository]} = context do
    origin = World.git_repo(context, "origin")

    context
    |> start_clone(origin, "/home/sam/#{Path.basename(repository)}")
    |> await_clone(&(&1["phase"] == "done"), 15_000)
  end

  step "half a minute passes", context do
    send(HalC2.ProjectClones, {:forget, context.clone.id})
    context
  end

  step "the clone is no longer reported", context do
    id = context.clone.id

    {_, client} =
      Node.await(World.client(context), fn frame ->
        frame["t"] == "projectClones" and not Enum.any?(frame["clones"], &(&1["projectId"] == id))
      end)

    World.put_client(context, client)
  end

  step "the project {string} stays with its files", %{args: [title]} = context do
    context = listed(context, title)
    assert File.exists?(Path.join(context.clone.dest, "README.md"))
    context
  end

  step "a clone of {string} failed with {string}", %{args: [repository, message]} = context do
    failed_clone(context, repository, message)
  end

  step "a clone of {string} failed", %{args: [repository]} = context do
    failed_clone(context, repository, "Repository not found.")
  end

  step "the clone is reported as failed with {string}", %{args: [message]} = context do
    assert %{"phase" => "failed", "error" => error} = current_clone(context)
    assert error =~ message
    context
  end

  step "the project {string} stays, pointing at its empty folder", %{args: [title]} = context do
    context = listed(context, title)
    assert World.await_row(context.clone.id, & &1)["workspaceRoot"] == context.clone.dest
    assert File.ls!(context.clone.dest) == []
    context
  end

  step "the user retries the clone", context do
    {reply, context} = call(context, "projectClone.retry", %{"projectId" => context.clone.id})
    Map.put(context, :reply, reply)
  end

  step "it clones into the same folder", context do
    assert %{"destinationPath" => dest, "remoteUrl" => url} = context.clone_snapshot
    assert {dest, url} == {context.clone.dest, context.clone.url}
    context
  end

  step "the node answers that nothing was applied", context do
    assert context.reply == {:ok, %{"applied" => false}}
    assert current_clone(context)["phase"] == "running"
    context
  end

  step "the user cancels the clone", context do
    {reply, context} =
      call(context, "projectClone.cancel", %{"projectId" => context.clone.id})

    assert reply == {:ok, %{"applied" => true}}
    context
  end

  step "the clone is reported as cancelled", context do
    await_clone(context, &(&1["phase"] == "cancelled"))
  end

  step "git stops cloning", context do
    assert_receive {:git_closed, _}, 5_000
    context
  end

  step "a clone of {string} was cancelled", %{args: [repository]} = context do
    context = running_clone(context, repository)

    {{:ok, %{"applied" => true}}, context} =
      call(context, "projectClone.cancel", %{"projectId" => context.clone.id})

    await_clone(context, &(&1["phase"] == "cancelled"))
  end

  step "no clone is reported", context do
    client = Node.sub(World.client(context), @clones_sub, clones_shape())
    {%{"clones" => clones}, client} = Node.await(client, &(&1["t"] == "projectClones"))
    assert clones == []
    World.put_client(context, client)
  end

  step "the project {string} is still listed with its folder", %{args: [title]} = context do
    context = listed(context, title)
    assert File.dir?(context.clone.dest)
    context
  end

  # --- looking up repositories -------------------------------------------------------

  step ~r/^the user is signed in to (?<host>Forgejo \/ Gitea|Bitbucket|Azure DevOps) on "[^"]+"$/,
       %{args: [host]} = context do
    signed_in(context, host)
  end

  step ~r/^the user looks up the repository "(?<repository>[^"]+)" on (?<host>Forgejo \/ Gitea|Bitbucket|Azure DevOps)$/,
       %{args: [repository, host]} = context do
    lookup(context, provider(host), repository)
  end

  step "the repository's clone address is returned", context do
    assert {:ok, %{"url" => url, "nameWithOwner" => "acme/shop"}} = context.reply
    assert url == context.clone_address
    context
  end

  step "the user looks up the GitHub repository {string}", %{args: [repository]} = context do
    fake_cli(context, "gh", [
      %{
        "args" => ["repo view #{repository}"],
        "stderr" =>
          "GraphQL: Could not resolve to a Repository with the name '#{repository}'. (repository)\n",
        "exit" => 1
      }
    ])

    lookup(context, "github", repository)
  end

  step "the lookup fails with the host's message", context do
    assert {:error, _, _} = context.reply

    assert inspect(context.reply) =~
             "Could not resolve to a Repository with the name 'acme/missing'"

    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp create(context, path, fields) do
    # `~` paths go to the node as typed; it expands them itself.
    root = if String.starts_with?(path, "~"), do: path, else: Host.path(context, path)
    id = World.slug(Path.basename(path))

    {reply, context} =
      World.call(
        context,
        "projects.mutate",
        Map.merge(
          %{"type" => "project.create", "projectId" => id, "workspaceRoot" => root},
          fields
        )
      )

    context = Map.put(context, :reply, reply)

    case reply do
      {:ok, project} ->
        put_in(context, [:projects, project["title"]], %{id: id, root: project["workspaceRoot"]})

      _ ->
        context
    end
  end

  defp projects do
    for {{node, _}, {"project", row}} <- HalC2.Shell.rows(),
        node == node(),
        row["deletedAt"] == nil,
        do: row
  end

  defp listed(context, title) do
    %{id: id, root: root} = World.project(context, title)
    row = World.await_row(id, &(&1["deletedAt"] == nil))
    assert row["title"] == title and row["workspaceRoot"] == root
    context
  end

  # An RPC whose reply races the `projectClones` frames it causes: those stay
  # queued on the socket for `await_clone/3`.
  defp call(context, method, payload) do
    id = System.unique_integer([:positive])
    client = Node.rpc(World.client(context), context.node.environment, id, method, payload)
    {frame, skipped, client} = HalC2.Test.WsClient.recv_until(client, Node.reply?(id), 5_000)
    context = World.put_client(context, %{client | inbox: skipped ++ client.inbox})

    case frame do
      %{"t" => "rpc.result", "result" => result} -> {{:ok, result}, context}
      %{"t" => "rpc.error", "error" => error} -> {{:error, error, frame["detail"]}, context}
    end
  end

  defp clones_shape, do: %{"type" => "projectClones", "node" => Atom.to_string(node())}

  defp start_clone(context, url, dest) do
    Node.ensure(HalC2.ProjectClones)
    real = Host.path(context, dest)
    File.mkdir_p!(Path.dirname(real))
    id = World.slug(Path.basename(dest))
    client = Node.sub(World.client(context), @clones_sub, clones_shape())
    {_, client} = Node.await(client, &(&1["t"] == "projectClones"))
    context = World.put_client(context, client)

    {{:ok, _}, context} =
      call(context, "projectClone.start", %{
        "projectId" => id,
        "title" => Path.basename(dest),
        "createdAt" => World.iso_from_now(0),
        "remoteUrl" => url,
        "destinationPath" => real
      })

    context
    |> Map.put(:clone, %{id: id, dest: real, url: url})
    |> put_in([:projects, Path.basename(dest)], %{id: id, root: real})
  end

  defp running_clone(context, repository) do
    port = git_server(context, :hang)

    context =
      context
      |> start_clone(
        "git://127.0.0.1:#{port}/#{repository}.git",
        "/home/sam/#{Path.basename(repository)}"
      )
      |> await_clone(&(&1["phase"] == "running"))

    # git is connected and waiting for the server.
    assert_receive {:git_connected, _}, 5_000
    context
  end

  defp failed_clone(context, repository, message) do
    port = git_server(context, {:refuse, message})

    context
    |> start_clone(
      "git://127.0.0.1:#{port}/#{repository}.git",
      "/home/sam/#{Path.basename(repository)}"
    )
    |> await_clone(&(&1["phase"] == "failed"), 10_000)
  end

  # Waits for a `projectClones` frame whose snapshot of the scenario's clone
  # satisfies `fun`; keeps it as `context.clone_snapshot`.
  defp await_clone(context, fun, timeout \\ 5_000) do
    id = context.clone.id

    {frame, client} =
      Node.await(
        World.client(context),
        fn frame ->
          frame["t"] == "projectClones" and
            Enum.any?(frame["clones"], &(&1["projectId"] == id and fun.(&1)))
        end,
        timeout
      )

    snapshot = Enum.find(frame["clones"], &(&1["projectId"] == id))
    context |> World.put_client(client) |> Map.put(:clone_snapshot, snapshot)
  end

  # The clone as a client subscribing now sees it.
  defp current_clone(context) do
    client = Node.connect(context.node)
    client = Node.sub(client, 1, clones_shape())
    {%{"clones" => clones}, _client} = Node.await(client, &(&1["t"] == "projectClones"))

    Enum.find(clones, &(&1["projectId"] == context.clone.id)) ||
      flunk("the clone is not reported")
  end

  # A `git://` server on loopback. `:hang` reads the request and never answers,
  # telling the test when git connects and when it goes away; `{:refuse, message}`
  # answers with a remote error, as a host does for a repository it does not have.
  defp git_server(_context, mode) do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    acceptor = spawn(fn -> accept(listen, mode, test) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)
    on_exit(fn -> Process.exit(acceptor, :kill) end)
    port
  end

  defp accept(listen, mode, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    handler = spawn(fn -> receive(do: (:go -> serve(socket, mode, test))) end)
    :ok = :gen_tcp.controlling_process(socket, handler)
    send(handler, :go)
    accept(listen, mode, test)
  end

  defp serve(socket, :hang, test) do
    {:ok, _request} = :gen_tcp.recv(socket, 0)
    send(test, {:git_connected, self()})
    drain(socket)
    send(test, {:git_closed, self()})
  end

  defp serve(socket, {:refuse, message}, _test) do
    {:ok, _request} = :gen_tcp.recv(socket, 0)
    payload = "ERR #{message}\n"
    length = (byte_size(payload) + 4) |> Integer.to_string(16) |> String.pad_leading(4, "0")
    :ok = :gen_tcp.send(socket, String.downcase(length) <> payload)
    :gen_tcp.close(socket)
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, _} -> drain(socket)
      {:error, _} -> :ok
    end
  end

  # git configuration for every git the node runs, for this scenario.
  defp git_env(config) do
    vars =
      config
      |> Enum.with_index()
      |> Enum.flat_map(fn {{key, value}, i} ->
        [{"GIT_CONFIG_KEY_#{i}", key}, {"GIT_CONFIG_VALUE_#{i}", value}]
      end)
      |> Kernel.++([{"GIT_CONFIG_COUNT", Integer.to_string(map_size(config))}])

    System.put_env(vars)
    on_exit(fn -> Enum.each(vars, fn {name, _} -> System.delete_env(name) end) end)
  end

  defp provider("Forgejo / Gitea"), do: "forgejo"
  defp provider("Bitbucket"), do: "bitbucket"
  defp provider("Azure DevOps"), do: "azure-devops"

  defp signed_in(context, "Forgejo / Gitea") do
    fake_cli(context, "tea", [
      %{
        "args" => ["login list"],
        "stdout" => [
          %{"name" => "codeberg", "url" => "https://codeberg.org", "default" => "true"}
        ]
      },
      %{
        "args" => ["api", "--login codeberg", "https://codeberg.org/api/v1/repos/acme/shop"],
        "stdout" => %{
          "full_name" => "acme/shop",
          "clone_url" => "https://codeberg.org/acme/shop.git",
          "ssh_url" => "git@codeberg.org:acme/shop.git"
        },
        "stderr" => "HTTP/2.0 200 OK\ncontent-type: application/json\n"
      }
    ])

    Map.put(context, :clone_address, "https://codeberg.org/acme/shop.git")
  end

  defp signed_in(context, "Azure DevOps") do
    fake_cli(context, "az", [
      %{
        "args" => ["repos show --detect true --repository acme/shop"],
        "stdout" => %{
          "name" => "shop",
          "project" => %{"name" => "acme"},
          "remoteUrl" => "https://dev.azure.com/contoso/acme/_git/shop",
          "sshUrl" => "git@ssh.dev.azure.com:v3/contoso/acme/shop",
          "webUrl" => "https://dev.azure.com/contoso/acme/_git/shop"
        }
      }
    ])

    Map.put(context, :clone_address, "https://dev.azure.com/contoso/acme/_git/shop")
  end

  defp signed_in(context, "Bitbucket") do
    {:ok, {_ip, port}} =
      ThousandIsland.listener_info(
        start_supervised!({Bandit, plug: __MODULE__.Bitbucket, port: 0, ip: :loopback})
      )

    env = [
      {"HAL_C2_BITBUCKET_API_BASE_URL", "http://127.0.0.1:#{port}/2.0"},
      {"HAL_C2_BITBUCKET_ACCESS_TOKEN", "bb-token"}
    ]

    System.put_env(env)
    on_exit(fn -> Enum.each(env, fn {name, _} -> System.delete_env(name) end) end)
    Map.put(context, :clone_address, "https://bitbucket.org/acme/shop.git")
  end

  # Stands a fake CLI in for `exe`, answering from `rules` (see fake_gh.py).
  defp fake_cli(context, exe, rules) do
    dir = Node.tmp_dir(context.node, "fake-#{exe}")
    File.write!(Path.join(dir, "rules.json"), JSON.encode!(rules))
    key = :"#{exe}_command"
    previous = Application.get_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, @fake_cli)
    System.put_env("FAKE_GH_RULES", Path.join(dir, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(dir, "calls.log"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, key, previous),
        else: Application.delete_env(:hal_c2, key)

      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
    end)
  end

  defp lookup(context, provider, repository) do
    {reply, context} =
      World.call(context, "sourceControl.lookupRepository", %{
        "provider" => provider,
        "repository" => repository
      })

    Map.put(context, :reply, reply)
  end

  defmodule Bitbucket do
    @moduledoc false
    # Bitbucket Cloud's repository endpoint, for the signed-in token only.
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/2.0/repositories/acme/shop"} = conn, _opts) do
      if get_req_header(conn, "authorization") == ["Bearer bb-token"] do
        body = %{
          "full_name" => "acme/shop",
          "links" => %{
            "clone" => [
              %{"name" => "https", "href" => "https://bitbucket.org/acme/shop.git"},
              %{"name" => "ssh", "href" => "git@bitbucket.org:acme/shop.git"}
            ],
            "html" => %{"href" => "https://bitbucket.org/acme/shop"}
          }
        }

        conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
      else
        send_resp(conn, 401, "")
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")
  end
end
