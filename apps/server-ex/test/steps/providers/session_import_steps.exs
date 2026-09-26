defmodule T3.Steps.Providers.SessionImport do
  @moduledoc """
  Steps for `features/providers/session-import.feature`: scanning Claude Code and Codex
  history (`agentSessions.scan` / `agentSessions.import`) and managing an ACP agent's
  own sessions (`server.*AcpRegistrySession`).

  "~" in the feature is a user home made for the scenario outside the node's home
  (which a scan never offers), with `CLAUDE_CONFIG_DIR` and `CODEX_HOME` inside it.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node.World

  @session_ids %{
    "shop-1" => "0b8f5c1e-4a7d-4c2b-9e1f-2d3c4b5a6f70",
    "shop-2" => "1c9f6d2e-5b8e-4d3c-8f20-3e4d5c6b7a81",
    "old" => "2da07e3f-6c9f-4e4d-9031-4f5e6d7c8b92",
    "blog-1" => "3eb18f40-7da0-4f5e-a142-506f7e8d9ca3"
  }
  @gemini "gemini"

  # --- scanning ---------------------------------------------------------------------------------

  step ~r/^(?<provider>Claude Code|Codex) has sessions in "(?<shop>[^"]+)" and "(?<blog>[^"]+)"$/,
       %{args: [provider, shop, blog]} = context do
    context = homes(context)
    source = if provider == "Codex", do: :codex, else: :claude
    session(context, source, "shop-1", dir!(context, shop))
    session(context, source, "shop-2", dir!(context, shop))
    session(context, source, "blog-1", dir!(context, blog))
    Map.put(context, :source, if(source == :codex, do: "codex", else: "claudeAgent"))
  end

  step "the node scans for agent history", context do
    context = homes(context)
    {result, context} = World.call!(context, "agentSessions.scan")
    Map.put(context, :scan, result)
  end

  step ~r/^"(?<a>[^"]+)" and "(?<b>[^"]+)" are offered as projects with their session counts from (?:Claude Code|Codex)$/,
       %{args: [a, b]} = context do
    assert %{"threadCount" => 2, "sources" => [source]} = candidate(context, a)
    assert source == context.source
    assert %{"threadCount" => 1, "sources" => [^source]} = candidate(context, b)
    context
  end

  step "CLAUDE_CONFIG_DIR points at {string}", %{args: [dir]} = context do
    context = homes(context)
    put_env("CLAUDE_CONFIG_DIR", path(context, dir))
    session(context, :claude, "shop-1", dir!(context, "~/code/shop"))
    context
  end

  step "Claude sessions under {string} are found", %{args: [_dir]} = context do
    assert %{"sources" => ["claudeAgent"], "threadCount" => 1} = candidate(context, "shop")
    context
  end

  step ~r/^Codex has sessions in (?<directory>[^"]+)$/, %{args: [directory]} = context do
    context = homes(context)

    dir =
      case directory do
        "a directory that no longer exists" -> path(context, "~/code/gone")
        "the home directory" -> System.user_home!()
        "the temporary directory" -> System.tmp_dir!()
        "the Downloads directory" -> Path.join(System.user_home!(), "Downloads")
        "a git worktree of another checkout" -> worktree(context)
        "a T3 Code worktree" -> dir!(context, "~/.t3/worktrees/shop/feature")
      end

    session(context, :codex, "shop-1", dir)
    # A project that is offered, so a scan that offers nothing proves nothing.
    session(context, :codex, "blog-1", dir!(context, "~/code/blog"))
    Map.put(context, :directory, Path.expand(dir))
  end

  step "that directory is not offered", context do
    assert candidate(context, "blog")
    refute Enum.any?(context.scan["candidates"], &(&1["path"] == context.directory))
    context
  end

  step "the project {string} is rooted at {string}", %{args: [title, dir]} = context do
    context = homes(context)
    root = dir!(context, dir)
    session(context, :codex, "shop-1", root)
    World.create_project(context, title, %{"workspaceRoot" => root})
  end

  step "{string} is offered as already imported", %{args: [title]} = context do
    id = World.project(context, title).id
    assert %{"alreadyImported" => true, "projectId" => ^id} = candidate(context, title)
    context
  end

  step "Codex has more sessions than a scan reads", context do
    context = homes(context)
    Application.put_env(:t3, :agent_sessions_max_transcripts, 2)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:t3, :agent_sessions_max_transcripts)
    end)

    for {name, days} <- [{"oldest", 3}, {"older", 2}, {"newer", 1}] do
      session(context, :codex, name, dir!(context, "~/code/#{name}"), days)
    end

    context
  end

  step "the newest sessions are offered", context do
    assert context.scan["candidates"] |> Enum.map(& &1["title"]) |> Enum.sort() == [
             "newer",
             "older"
           ]

    context
  end

  step "the scan says it was truncated", context do
    assert context.scan["truncated"] == true
    context
  end

  # --- importing --------------------------------------------------------------------------------

  step ~r/^"(?<title>[^"]+)" has Claude sessions from last week and from two months ago$/,
       %{args: [title]} = context do
    context = homes(context)
    root = dir!(context, "~/code/#{title}")
    session(context, :claude, "shop-1", root, 7)
    session(context, :claude, "old", root, 60)
    World.create_project(context, title, %{"workspaceRoot" => root})
  end

  step "the user imports {string}", %{args: [title]} = context do
    project = World.project(context, title)

    input =
      if context[:scanned_root],
        do: %{"projectId" => project.id, "expectedWorkspaceRoot" => context.scanned_root},
        else: %{"projectId" => project.id}

    {reply, context} = World.call(context, "agentSessions.import", input)
    Map.put(context, :reply, reply)
  end

  step "last week's sessions become threads with their visible messages", context do
    assert {:ok, %{"importedCount" => 1, "skippedCount" => 0}} = context.reply
    id = "import:claudeAgent:#{@session_ids["shop-1"]}"
    assert World.await_row(id, & &1)["title"] == "Fix the login bug"
    state = T3.Streams.Server.state(T3.Streams.ensure(id))

    assert for(m <- T3.StreamState.list(state, "message"), do: {m["role"], m["text"]}) ==
             [{"user", "Fix the login bug\nplease"}, {"assistant", "Fixed."}]

    context
  end

  step "the session from two months ago is not imported", context do
    assert T3.Shell.row(node(), "import:claudeAgent:#{@session_ids["old"]}") == nil
    context
  end

  step "a Claude session imported as a thread", context do
    context = homes(context)
    root = dir!(context, "~/code/shop")
    session(context, :claude, "shop-1", root)
    context = World.create_project(context, "shop", %{"workspaceRoot" => root})
    {_, context} = World.call!(context, "agentSessions.import", %{"projectId" => "shop"})
    id = "import:claudeAgent:#{@session_ids["shop-1"]}"
    World.await_row(id, & &1)

    context
    |> World.fake_providers()
    |> put_in([:threads, "Imported"], id)
    |> Map.put(:current_thread, "Imported")
  end

  step "the user sends a message in the thread", context do
    context = World.send_message(context, "Imported", "carry on")
    World.await_runs(context, "Imported", ["completed"])
    context
  end

  step "Claude resumes the original session", context do
    %{"argv" => argv} = World.await_provider_log(context, "claude", &Map.has_key?(&1, "argv"))
    assert ["--resume", @session_ids["shop-1"]] in Enum.chunk_every(argv, 2, 1)
    context
  end

  step "a Claude session whose only replies were Claude's own local errors", context do
    context = homes(context)
    root = dir!(context, "~/code/shop")
    session(context, :claude, "shop-1", root, 1, "<synthetic>")
    World.create_project(context, "shop", %{"workspaceRoot" => root})
  end

  step "the thread uses Claude's default model", context do
    assert {:ok, %{"importedCount" => 1}} = context.reply
    row = World.await_row("import:claudeAgent:#{@session_ids["shop-1"]}", & &1)
    # DEFAULT_MODEL_BY_PROVIDER in packages/contracts/src/model.ts.
    assert %{"instanceId" => "claudeAgent", "model" => "claude-fable-5-1"} = row["modelSelection"]
    context
  end

  step "the user scanned {string} at {string}", %{args: [title, dir]} = context do
    context = homes(context)
    root = dir!(context, dir)
    session(context, :claude, "shop-1", root)
    context = World.create_project(context, title, %{"workspaceRoot" => root})
    {%{"candidates" => candidates}, context} = World.call!(context, "agentSessions.scan")
    assert Enum.any?(candidates, &(&1["path"] == root))
    Map.put(context, :scanned_root, root)
  end

  step "{string} has since moved to {string}", %{args: [title, dir]} = context do
    id = World.project(context, title).id
    root = dir!(context, dir)

    {:ok, _} =
      T3.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => id,
        "workspaceRoot" => root
      })

    World.await_row(id, &(&1["workspaceRoot"] == root))
    context
  end

  step "the user is told the project changed directories and to scan again", context do
    assert {:error, message, %{"_tag" => "AgentSessionImportProjectChangedError"}} = context.reply
    assert message =~ "changed directories. Scan for projects again."
    context
  end

  step "the user imports sessions into a project that was deleted", context do
    context = World.create_project(context, "shop")
    {:ok, _} = T3.Projects.mutate(%{"type" => "project.delete", "projectId" => "shop"})
    World.await_row("shop", &(&1 == nil or &1["deletedAt"] != nil))
    {reply, context} = World.call(context, "agentSessions.import", %{"projectId" => "shop"})
    Map.put(context, :reply, reply)
  end

  step "the user is told the project does not exist", context do
    assert {:error, message, %{"_tag" => "AgentSessionImportProjectNotFoundError"}} =
             context.reply

    assert message =~ "does not exist"
    context
  end

  # --- ACP agents' own sessions ------------------------------------------------------------------

  step "the user imported a Gemini session as a thread", context do
    context = context |> gemini() |> import_gemini()
    assert {:ok, %{"imported" => true, "threadId" => id}} = context.reply
    World.await_row(id, & &1)
    Map.put(context, :imported_thread, id)
  end

  step "the user imports the same session again", context do
    import_gemini(context)
  end

  step "the existing thread is returned and no new thread is made", context do
    id = context.imported_thread
    assert {:ok, %{"imported" => false, "threadId" => ^id}} = context.reply

    threads =
      for {{_node, _id}, {"thread", row}} <- T3.Shell.rows(), row["projectId"] == "shop", do: row

    assert length(threads) == 1
    context
  end

  step "the user imports a Gemini session", context do
    context |> gemini() |> import_gemini()
  end

  step "the thread is supervised and uses the agent's default model", context do
    assert {:ok, %{"threadId" => id}} = context.reply
    row = World.await_row(id, & &1)
    [default | _] = T3.Acp.entry(@gemini)["models"]
    assert row["runtimeMode"] == "approval-required"
    assert row["modelSelection"] == %{"instanceId" => @gemini, "model" => default["slug"]}
    context
  end

  step ~r/^an ACP agent that (?<lacks>cannot load or resume sessions|cannot list sessions|cannot delete sessions|is not signed in)$/,
       %{args: [lacks]} = context do
    all = %{
      "loadSession" => true,
      "sessionCapabilities" => %{"resume" => %{}, "list" => %{}, "delete" => %{}}
    }

    case lacks do
      "cannot load or resume sessions" ->
        System.put_env(
          "FAKE_ACP_CAPS",
          JSON.encode!(%{"sessionCapabilities" => %{"list" => %{}}})
        )

      "cannot list sessions" ->
        System.put_env(
          "FAKE_ACP_CAPS",
          JSON.encode!(update_in(all, ["sessionCapabilities"], &Map.delete(&1, "list")))
        )

      "cannot delete sessions" ->
        System.put_env(
          "FAKE_ACP_CAPS",
          JSON.encode!(update_in(all, ["sessionCapabilities"], &Map.delete(&1, "delete")))
        )

      "is not signed in" ->
        System.put_env("FAKE_AUTH_FILE", Path.join(context.node.home, "never-signed-in"))
    end

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(~w(FAKE_ACP_CAPS FAKE_AUTH_FILE), &System.delete_env/1)
    end)

    gemini(context)
  end

  step ~r/^the user (?<action>imports one of its sessions|lists its sessions|deletes one of its sessions)$/,
       %{args: [action]} = context do
    {method, extra} =
      case action do
        "imports one of its sessions" ->
          {"server.importAcpRegistrySession", %{"sessionId" => "old-1"}}

        "lists its sessions" ->
          {"server.listAcpRegistrySessions", %{}}

        "deletes one of its sessions" ->
          {"server.deleteAcpRegistrySession", %{"sessionId" => "old-1"}}
      end

    acp_call(context, method, extra)
  end

  step "the user is told to sign in to the agent", context do
    assert {:error, message,
            %{"_tag" => "AcpRegistryOperationError", "reason" => "authentication_failed"}} =
             context.reply

    assert message =~ "Authentication required"
    context
  end

  step "a Gemini session imported as a thread", context do
    context = context |> gemini() |> import_gemini()
    assert {:ok, %{"imported" => true, "threadId" => id}} = context.reply
    World.await_row(id, & &1)
    Map.put(context, :imported_thread, id)
  end

  step "the user deletes the thread and then the native session", context do
    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "thread.delete",
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => context.imported_thread
      })

    World.await_row(context.imported_thread, &(&1 == nil or &1["deletedAt"] != nil))
    acp_call(context, "server.deleteAcpRegistrySession", %{"sessionId" => "old-1"})
  end

  step "the native session is deleted", context do
    assert {:ok, %{"deleted" => true}} = context.reply

    assert World.await_provider_log(
             context,
             "acp",
             &(get_in(&1, ["in", "method"]) == "session/delete")
           )
           |> get_in(["in", "params", "sessionId"]) == "old-1"

    context
  end

  step "the user lists an ACP agent's sessions for a project that is not on this node", context do
    context = gemini(context)

    acp_call(context, "server.listAcpRegistrySessions", %{"projectId" => "elsewhere"})
  end

  # --- helpers ----------------------------------------------------------------------------------

  # The scenario's user home, outside the node's, with the agents' homes in it.
  defp homes(%{user_home: _} = context), do: context

  defp homes(context) do
    home = Path.join(System.tmp_dir!(), "t3-user-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(home) end)
    context = Map.put(context, :user_home, home)
    put_env("CLAUDE_CONFIG_DIR", path(context, "~/.claude"))
    put_env("CODEX_HOME", path(context, "~/.codex"))
    context
  end

  defp path(context, "~/" <> rest), do: Path.join(context.user_home, rest)
  defp path(_context, path), do: path

  defp dir!(context, dir) do
    path = path(context, dir)
    File.mkdir_p!(path)
    path
  end

  # A linked worktree of a repository elsewhere, whose `.git` is a file.
  defp worktree(context) do
    main = dir!(context, "~/code/main")
    World.git!(main, ~w(init -q -b main))
    World.git!(main, ~w(-c user.name=t -c user.email=t@t commit -q --allow-empty -m init))
    linked = path(context, "~/code/linked")
    World.git!(main, ["worktree", "add", "-q", "-b", "linked", linked])
    linked
  end

  # One transcript named `name`, last active `days_ago` days ago.
  defp session(context, source, name, cwd, days_ago \\ 1, model \\ "claude-x")

  defp session(context, :claude, name, cwd, days_ago, model) do
    id = @session_ids[name]
    home = System.get_env("CLAUDE_CONFIG_DIR")
    file = Path.join([home, "projects", String.replace(cwd, "/", "-"), "#{id}.jsonl"])

    jsonl(file, days_ago, [
      %{
        "type" => "user",
        "cwd" => cwd,
        "sessionId" => id,
        "timestamp" => World.iso_from_now(-World.days(days_ago)),
        "message" => %{"role" => "user", "content" => "Fix the login bug\nplease"}
      },
      %{
        "type" => "assistant",
        "timestamp" => World.iso_from_now(-World.days(days_ago)),
        "message" => %{"model" => model, "content" => [%{"type" => "text", "text" => "Fixed."}]}
      }
    ])

    context
  end

  defp session(context, :codex, name, cwd, days_ago, _model) do
    file =
      Path.join([
        System.get_env("CODEX_HOME"),
        "sessions",
        "2026",
        "09",
        "20",
        "rollout-#{name}.jsonl"
      ])

    jsonl(file, days_ago, [
      %{"type" => "session_meta", "payload" => %{"id" => "codex-#{name}", "cwd" => cwd}},
      %{"type" => "event_msg", "payload" => %{"type" => "user_message", "message" => "Add tests"}}
    ])

    context
  end

  defp jsonl(file, days_ago, records) do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Enum.map_join(records, "\n", &JSON.encode!/1) <> "\n")
    File.touch!(file, System.os_time(:second) - days_ago * 86_400)
  end

  defp put_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  defp candidate(context, title),
    do: Enum.find(context.scan["candidates"], &(&1["title"] == title))

  # The Gemini CLI from the ACP Registry, and a project to manage its sessions from.
  defp gemini(context) do
    context
    |> World.acp_registry_agent(@gemini, "Gemini CLI")
    |> World.create_project("shop")
  end

  defp import_gemini(context) do
    acp_call(context, "server.importAcpRegistrySession", %{
      "sessionId" => "old-1",
      "title" => "Earlier work"
    })
  end

  defp acp_call(context, method, extra) do
    input = Map.merge(%{"instanceId" => @gemini, "projectId" => "shop"}, extra)
    {reply, context} = World.call(context, method, input)

    Map.merge(context, %{
      reply: reply,
      # What "the user deletes the native session" deletes.
      acp_session: %{instance: @gemini, project: input["projectId"], session: "old-1"}
    })
  end
end
