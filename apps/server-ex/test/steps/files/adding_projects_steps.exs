defmodule HalC2.Steps.Files.AddingProjects do
  @moduledoc """
  Steps for `features/files/adding-projects.feature`. Clones run real `git` against
  a `git://` server on loopback that either holds the connection open (a clone in
  flight) or refuses the repository (`git_server/2`), or through gates the scenario
  holds and releases at the fetch and at the checkout of the last file
  (`HalC2.Test.CloneGate`, `gated_clone/3`); hosts are looked up through fake CLIs
  and a fake Bitbucket API.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias HalC2.Test.{CloneGate, Mc}
  alias HalC2.Test.Mc.{Host, World}

  @fake_cli Path.expand("../../support/fake_gh.py", __DIR__)
  @clones_sub 7_001
  # What a gated clone checks out: its last file waits at the checkout gate.
  @gated_files %{
    ".gitattributes" => "zz.txt filter=gate\n",
    "README.md" => "shop\n",
    "src/app.txt" => "app\n",
    "zz.txt" => "last\n"
  }

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

  step "the MC's user is {string} with the home folder {string}",
       %{args: [_user, home]} = context do
    # `Host.home/1` makes the scenario's `/home/sam` the MC's `$HOME`.
    assert home == "/home/sam"
    Host.home(context)
    context
  end

  step "the current project's folder is {string} and holds the folder {string}",
       %{args: [dir, name]} = context do
    real = Host.path(context, dir)
    File.mkdir_p!(Path.join(real, name))
    Map.put(context, :current_project_folder, real)
  end

  step "{string} holds the folders {string}, {string} and {string} and the file {string}",
       %{args: [dir, a, b, c, file]} = context do
    real = Host.path(context, dir)
    for name <- [a, b, c], do: File.mkdir_p!(Path.join(real, name))
    File.write!(Path.join(real, file), "")
    context
  end

  step "a client browses {string} with no current project", %{args: [partial]} = context do
    browse(context, partial, nil)
  end

  step "a client browses {string} with the current project", %{args: [partial]} = context do
    browse(context, partial, context.current_project_folder)
  end

  step "the MC answers that the folder {string} could not be read", %{args: [dir]} = context do
    assert {:error, error, _} = context.reply
    assert error =~ "The folder '#{Host.path(context, dir)}' could not be read"
    context
  end

  step "the folders {string} and {string} are offered", %{args: names} = context do
    assert context.listing == names
    context
  end

  step "the folders {string}, {string} and {string} are offered", %{args: names} = context do
    assert context.listing == names
    context
  end

  step "the folders {string} are offered", %{args: names} = context do
    assert context.listing == names
    context
  end

  step "{string}, {string} and {string} are offered in that order", %{args: names} = context do
    assert context.listing == names
    context
  end

  step "{string} cannot be read by the MC", %{args: [dir]} = context do
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

  step "the MC answers that {string} does not exist on this machine",
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
    url = if url =~ "://", do: url, else: "https://example.com/#{url}.git"

    if context[:clone] do
      # Refused before git runs.
      start_clone(context, url, dest)
    else
      # The host's address leads to the repository behind a gate that holds the fetch.
      [origin, path] = Regex.run(~r{^(https?://[^/]+/)(.*)$}, url, capture: :all_but_first)
      context = gates(context)
      dir = Mc.tmp_dir(context.mc, "hosted")
      CloneGate.repo(dir, @gated_files, Path.join(dir, path))
      token = "fetch-#{World.slug(Path.basename(dest))}"
      transport = "ext::python3 #{gate_script()} #{context.gate_port} #{token} %S #{dir}/"
      git_env(gate_config(context, %{"url.#{transport}.insteadOf" => origin}))
      context = start_clone(context, url, dest)

      if match?({:ok, _}, context.reply),
        do: Map.put(context, :gate, CloneGate.await(token)),
        else: context
    end
  end

  step "a client starts cloning {string} into a blank destination", %{args: [url]} = context do
    Mc.ensure(HalC2.ProjectClones)

    {reply, context} =
      World.call(context, "projectClone.start", %{
        "projectId" => "shop",
        "title" => "shop",
        "createdAt" => World.iso_from_now(0),
        "remoteUrl" => url,
        "destinationPath" => "   "
      })

    Map.put(context, :reply, reply)
  end

  step "{string} does not exist", %{args: [path]} = context do
    Host.home(context)
    refute File.exists?(Host.path(context, path))
    context
  end

  step "the clone goes into {string}", %{args: [path]} = context do
    real = Host.path(context, path)
    assert {:ok, %{"cwd" => ^real}} = context.reply
    assert File.dir?(real)
    assert current_clone(context)["destinationPath"] == real
    context
  end

  step "a clone of {string} into {string} is running", %{args: [repository, dest]} = context do
    gated_clone(context, repository, dest)
  end

  step "no second project is created", context do
    assert HalC2.Projects.stored_roots() == [context.clone.dest]
    context
  end

  step "the repository {string} needs credentials the MC does not have",
       %{args: [repository]} = context do
    # A host that asks every request for a password, and an askpass program git
    # must never run: the MC's own environment points git at it.
    {:ok, {_ip, port}} =
      ThousandIsland.listener_info(
        start_supervised!({Bandit, plug: __MODULE__.Private, port: 0, ip: :loopback})
      )

    Host.home(context)
    marker = Path.join(Mc.tmp_dir(context.mc, "askpass"), "asked")
    askpass = Path.join(Path.dirname(marker), "askpass.sh")
    File.write!(askpass, "#!/bin/sh\ntouch '#{marker}'\necho hunter2\n")
    File.chmod!(askpass, 0o755)
    env = [{"GIT_ASKPASS", askpass}, {"SSH_ASKPASS", askpass}, {"SSH_ASKPASS_REQUIRE", "force"}]
    previous = for {name, _} <- env, do: {name, System.get_env(name)}
    System.put_env(env)

    on_exit(fn ->
      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    git_env(%{
      "url.http://127.0.0.1:#{port}/.insteadOf" => "https://example.com/",
      "credential.helper" => "",
      "core.askPass" => askpass
    })

    context
    |> Map.put(:askpass_marker, marker)
    |> Map.put(:private, "https://example.com/#{repository}.git")
  end

  step "a client starts cloning it", context do
    start_clone(context, context.private, "/home/sam/private")
  end

  step "git does not wait for a prompt", context do
    context = await_clone(context, &(&1["phase"] == "failed"), 15_000)
    refute File.exists?(context.askpass_marker), "git asked for a password"
    context
  end

  step "the clone is reported as failed with the last lines git printed", context do
    assert context.clone_snapshot["error"] =~ "terminal prompts disabled"
    context
  end

  step "a clone of {string} is running and has written part of the files",
       %{args: [repository]} = context do
    context =
      context
      |> gated_clone(repository, "/home/sam/#{Path.basename(repository)}")
      |> to_checkout()

    assert File.exists?(Path.join(context.clone.dest, "README.md"))
    refute File.exists?(Path.join(context.clone.dest, "zz.txt"))
    context
  end

  step "the folder {string} still exists and is empty", %{args: [path]} = context do
    assert File.ls!(Host.path(context, path)) == []
    context
  end

  step "retrying the clone starts from that empty folder", context do
    {reply, context} = call(context, "projectClone.retry", %{"projectId" => context.clone.id})
    assert reply == {:ok, %{"applied" => true}}
    context = Map.put(context, :gate, CloneGate.await("fetch-#{context.clone.id}"))
    context = await_clone(context, &(&1["phase"] == "running"))
    assert File.ls!(context.clone.dest) == [".git"]
    context
  end

  step "a clone of {string} finishes while the user's cancel is being applied",
       %{args: [repository]} = context do
    context =
      context
      |> gated_clone(repository, "/home/sam/#{Path.basename(repository)}")
      |> to_checkout()

    server = Process.whereis(HalC2.ProjectClones)
    id = context.clone.id

    # The cancel waits in the MC's queue while git finishes; each step is seen
    # arriving there (a trace), not waited for.
    :ok = :sys.suspend(server)
    :erlang.trace(server, true, [:receive])
    cancel = Task.async(fn -> HalC2.ProjectClones.cancel(%{"projectId" => id}) end)
    assert_receive {:trace, ^server, :receive, {:"$gen_call", _, {:cancel, ^id}}}, 5_000
    CloneGate.release(context.gate, "ok")
    assert_receive {:trace, ^server, :receive, {:clone_finished, _, ^id, :ok}}, 15_000
    :erlang.trace(server, false, [:receive])
    :ok = :sys.resume(server)

    Map.put(context, :reply, Task.await(cancel, 20_000))
  end

  step "the clone is reported done", context do
    assert context.reply == {:ok, %{"applied" => false}}
    assert current_clone(context)["phase"] == "done"
    context
  end

  step "the checkout is kept", context do
    assert Enum.sort(File.ls!(context.clone.dest)) ==
             [".git", ".gitattributes", "README.md", "src", "zz.txt"]

    context
  end

  step "git reports a transfer detail or an error far longer than a notice can show", context do
    context = gated_clone(context, "acme/shop", "/home/sam/shop")
    detail = String.duplicate("1.20 MiB | 2.00 MiB/s ", 30)

    send(
      HalC2.ProjectClones,
      {:clone_progress, context.clone.id,
       HalC2.ProjectClones.progress("Receiving objects:  45% (45/100), " <> detail)}
    )

    context = await_clone(context, &(&1["stage"] == "receiving"))
    detail = context.clone_snapshot["detail"]

    CloneGate.release(
      context.gate,
      "remote said: " <> String.duplicate("no such repository ", 100)
    )

    context = await_clone(context, &(&1["phase"] == "failed"), 15_000)
    Map.put(context, :long, %{detail: detail, error: context.clone_snapshot["error"]})
  end

  step "the reported detail and error are cut with an ellipsis within the contract's limit",
       context do
    for {text, max} <- [{context.long.detail, 200}, {context.long.error, 1000}] do
      assert String.length(text) == max
      assert String.ends_with?(text, "…")
    end

    context
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

  # The deadline stands in for two minutes at a fraction of a second; the one-shot
  # clone's answer is the receipt that it passed.
  step "a clone is still transferring after two minutes", context do
    previous = Application.get_env(:hal_c2, :clone_timeout)
    Application.put_env(:hal_c2, :clone_timeout, 500)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :clone_timeout, previous),
        else: Application.delete_env(:hal_c2, :clone_timeout)
    end)

    context = running_clone(context, "acme/shop")
    port = git_server(context, :hang)

    {reply, context} =
      call(context, "sourceControl.cloneRepository", %{
        "remoteUrl" => "git://127.0.0.1:#{port}/acme/slow.git",
        "destinationPath" => Host.path(context, "/home/sam/slow")
      })

    Map.put(context, :one_shot, reply)
  end

  step "a clone started in the background keeps running", context do
    assert [{_, "running"}] = :ets.lookup(HalC2.ProjectClones, context.clone.id)
    context
  end

  step "a clone that waits for its answer fails as timed out", context do
    assert {:error, message, _} = context.one_shot
    assert message =~ "timed out"
    refute File.exists?(Host.path(context, "/home/sam/slow"))
    context
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
      Mc.await(World.client(context), fn frame ->
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

  step "the MC answers that nothing was applied", context do
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
    client = Mc.sub(World.client(context), @clones_sub, clones_shape())
    {%{"clones" => clones}, client} = Mc.await(client, &(&1["t"] == "projectClones"))
    assert clones == []
    World.put_client(context, client)
  end

  step "the project {string} is still listed with its folder", %{args: [title]} = context do
    context = listed(context, title)
    assert File.dir?(context.clone.dest)
    context
  end

  # --- clones that must not start, and what happens to their folders -------------------

  step "a clone of {string} is still running", %{args: [repository]} = context do
    running_clone(context, repository)
  end

  step "a clone of {string} is failed or cancelled", %{args: [repository]} = context do
    failed_clone(context, repository, "Repository not found.")
  end

  step "a client starts a thread in the project {string}", %{args: [title]} = context do
    {reply, context} =
      World.call(context, "orchestration.dispatchCommand", %{
        "type" => "thread.create",
        "commandId" => "cmd-thread-#{System.unique_integer([:positive])}",
        "threadId" => "thread-#{System.unique_integer([:positive])}",
        "projectId" => World.project(context, title).id,
        "title" => "Work"
      })

    Map.put(context, :reply, reply)
  end

  step "no thread is created", context do
    refute Enum.any?(HalC2.Shell.rows(), &match?({{_, _}, {"thread", _}}, &1))
    context
  end

  step "the folder {string} already holds files", %{args: [path]} = context do
    real = Host.path(context, path)
    File.mkdir_p!(real)
    File.write!(Path.join(real, "notes.txt"), "mine")
    context
  end

  step "the user has since put files of their own in {string}", %{args: [_path]} = context do
    File.write!(Path.join(context.clone.dest, "mine.txt"), "mine")
    context
  end

  step "the retry fails with {string}", %{args: [message]} = context do
    assert {:error, error, _} = context.reply
    assert error =~ message
    context
  end

  step "the user's files are untouched", context do
    assert File.read!(Path.join(context.clone.dest, "mine.txt")) == "mine"
    context
  end

  step "git is given the address as pasted", context do
    assert :sys.get_state(HalC2.ProjectClones).runs[context.clone.id].url == context.clone.url
    context
  end

  step "the clone reported to every client carries {string}", %{args: [url]} = context do
    assert current_clone(context)["remoteUrl"] == url
    context
  end

  step "a failure's message has the credentials removed", context do
    # As git words a host refusing it.
    CloneGate.release(
      context.gate,
      "unable to access '#{context.clone.url}/': The requested URL returned error: 403"
    )

    context = await_clone(context, &(&1["phase"] == "failed"), 15_000)
    refute context.clone_snapshot["error"] =~ "s3cret"
    assert context.clone_snapshot["error"] =~ "https://example.com/acme/shop.git"
    context
  end

  step "a clone of {string} is running for the project {string}",
       %{args: [repository, _title]} = context do
    context =
      context
      |> gated_clone(repository, "/home/sam/#{Path.basename(repository)}")
      |> to_checkout()

    assert File.exists?(Path.join(context.clone.dest, "README.md"))
    context
  end

  step "the clone is stopped and no longer reported", context do
    # The gate ends with git, closing its connection.
    assert :gen_tcp.recv(context.gate, 0, 5_000) == {:error, :closed}
    client = Mc.sub(Mc.connect(context.mc), 1, clones_shape())
    {%{"clones" => clones}, _client} = Mc.await(client, &(&1["t"] == "projectClones"))
    refute Enum.any?(clones, &(&1["projectId"] == context.clone.id))
    context
  end

  step "the partial files are removed", context do
    assert File.ls!(context.clone.dest) == []
    context
  end

  step "a clone that had already finished keeps its files", context do
    origin = World.git_repo(context, "origin")

    done =
      context
      |> start_clone(origin, "/home/sam/finished")
      |> await_clone(&(&1["phase"] == "done"), 15_000)

    {{:ok, _}, done} =
      call(done, "projects.mutate", %{
        "type" => "project.delete",
        "projectId" => done.clone.id
      })

    assert File.exists?(Path.join(done.clone.dest, "README.md"))
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

  defp browse(context, partial, cwd) do
    input = %{"partialPath" => partial}
    input = if cwd, do: Map.put(input, "cwd", cwd), else: input
    {reply, context} = World.call(context, "filesystem.browse", input)

    listing =
      case reply do
        {:ok, %{"entries" => entries}} -> Enum.map(entries, & &1["name"])
        _ -> []
      end

    Map.merge(context, %{reply: reply, listing: listing})
  end

  defp create(context, path, fields) do
    # `~` paths go to the MC as typed; it expands them itself.
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
    for {{mc, _}, {"project", row}} <- HalC2.Shell.rows(),
        mc == node(),
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
    client = Mc.rpc(World.client(context), context.mc.environment, id, method, payload)
    {frame, skipped, client} = HalC2.Test.WsClient.recv_until(client, Mc.reply?(id), 5_000)
    context = World.put_client(context, %{client | inbox: skipped ++ client.inbox})

    case frame do
      %{"t" => "rpc.result", "result" => result} -> {{:ok, result}, context}
      %{"t" => "rpc.error", "error" => error} -> {{:error, error, frame["detail"]}, context}
    end
  end

  defp clones_shape, do: %{"type" => "projectClones", "mc" => Atom.to_string(node())}

  defp start_clone(context, url, dest) do
    Mc.ensure(HalC2.ProjectClones)
    # `~` paths go to the MC as typed, to expand; its parents are the MC's to make.
    real =
      if String.starts_with?(dest, "~") do
        Host.home(context)
        dest
      else
        File.mkdir_p!(Path.dirname(Host.path(context, dest)))
        Host.path(context, dest)
      end

    # A second clone in a scenario is its repository's project.
    id =
      if context[:clone],
        do: World.slug(Path.basename(url, ".git")),
        else: World.slug(Path.basename(dest))

    client = Mc.sub(World.client(context), @clones_sub, clones_shape())
    {_, client} = Mc.await(client, &(&1["t"] == "projectClones"))
    context = World.put_client(context, client)

    {reply, context} =
      call(context, "projectClone.start", %{
        "projectId" => id,
        "title" => Path.basename(dest),
        "createdAt" => World.iso_from_now(0),
        "remoteUrl" => url,
        "destinationPath" => real
      })

    context = Map.put(context, :reply, reply)

    if match?({:ok, _}, reply) do
      context
      |> Map.put(:clone, %{id: id, dest: real, url: url})
      |> put_in([:projects, Path.basename(dest)], %{id: id, root: real})
    else
      context
    end
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
      Mc.await(
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
    client = Mc.connect(context.mc)
    client = Mc.sub(client, 1, clones_shape())
    {%{"clones" => clones}, _client} = Mc.await(client, &(&1["t"] == "projectClones"))

    Enum.find(clones, &(&1["projectId"] == context.clone.id)) ||
      flunk("the clone is not reported")
  end

  # A clone of `repository` into `dest` whose git waits at its fetch gate
  # (`context.gate`), having made the folder's `.git`.
  defp gated_clone(context, repository, dest) do
    context = gates(context)
    id = World.slug(Path.basename(dest))
    bare = CloneGate.repo(Mc.tmp_dir(context.mc, "repos"), @gated_files)
    git_env(gate_config(context, %{}))
    url = CloneGate.transport_url(context.gate_port, "fetch-#{id}", bare)
    context = start_clone(context, url, dest)
    assert {:ok, _} = context.reply, "#{repository} did not start: #{inspect(context.reply)}"
    Map.put(context, :gate, CloneGate.await("fetch-#{id}"))
  end

  # Lets a gated clone fetch, up to where it waits to check out its last file.
  defp to_checkout(context) do
    CloneGate.release(context.gate, "ok")
    Map.put(context, :gate, CloneGate.await(Path.basename(context.clone.dest)))
  end

  defp gates(%{gate_port: _} = context), do: context
  defp gates(context), do: Map.put(context, :gate_port, CloneGate.listen())

  # git configuration for gates, with `extra`.
  defp gate_config(context, extra) do
    Map.merge(
      %{
        "protocol.ext.allow" => "always",
        "filter.gate.smudge" => CloneGate.smudge(context.gate_port, "@cwd"),
        "filter.gate.required" => "true"
      },
      extra
    )
  end

  defp gate_script, do: Path.expand("../../support/clone_gate.py", __DIR__)

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

  # git configuration for every git the MC runs, for this scenario.
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
          %{
            "name" => "codeberg",
            "url" => "https://codeberg.org",
            "user" => "sam",
            "default" => "true"
          }
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
    dir = Mc.tmp_dir(context.mc, "fake-#{exe}")
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

  defmodule Private do
    @moduledoc false
    # A host that wants a password for everything.
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("www-authenticate", ~s(Basic realm="private"))
      |> send_resp(401, "")
    end
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
