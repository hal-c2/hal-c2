defmodule HalC2.Steps.Orchestration.AgentSessionImport do
  @moduledoc """
  Steps for `features/mc/orchestration/agent-session-import.feature`.

  Transcripts are written under a scratch folder that stands in for the user's
  home: `~/code/app` is `<scratch>/code/app`, and `CLAUDE_CONFIG_DIR` and
  `CODEX_HOME` point at `<scratch>/.claude` and `<scratch>/.codex`. The real home
  and temporary folders are only named, never written to.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  @day 24 * 60 * 60

  step "Claude Code and Codex transcripts exist on this machine", context do
    root = Path.join(System.tmp_dir!(), "hal-c2-agent-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".claude/projects"))
    File.mkdir_p!(Path.join(root, ".codex/sessions"))

    previous = for name <- ~w(CLAUDE_CONFIG_DIR CODEX_HOME), do: {name, System.get_env(name)}
    System.put_env("CLAUDE_CONFIG_DIR", Path.join(root, ".claude"))
    System.put_env("CODEX_HOME", Path.join(root, ".codex"))

    ExUnit.Callbacks.on_exit(fn ->
      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

      File.rm_rf(root)
    end)

    Map.put(context, :agent_home, root)
  end

  # --- scanning ------------------------------------------------------------------------

  step "{int} sessions ran in {string} and {int} in {string}",
       %{args: [n, first, m, second]} = context do
    now = System.os_time(:second)

    for i <- 1..n,
        do:
          session(context, mkdir(dir(context, first)),
            source: Enum.at(~w(claude codex), rem(i, 2)),
            mtime: now - i
          )

    for i <- 1..m,
        do: session(context, mkdir(dir(context, second)), source: "codex", mtime: now - @day - i)

    Map.put(context, :last_active, %{"app" => now - 1, "lib" => now - @day - 1})
  end

  step "a client scans for agent sessions", context do
    {result, context} = World.call!(context, "agentSessions.scan")
    Map.put(context, :scan, result)
  end

  step "it receives candidates {string} with {int} threads and {string} with {int}, newest first",
       %{args: [first, n, second, m]} = context do
    assert [%{"title" => ^first, "threadCount" => ^n}, %{"title" => ^second, "threadCount" => ^m}] =
             context.scan["candidates"]

    context
  end

  step "each candidate names the agents that used it and when it was last active", context do
    [app, lib] = context.scan["candidates"]
    assert Enum.sort(app["sources"]) == ["claudeAgent", "codex"]
    assert lib["sources"] == ["codex"]
    assert epoch_s(app["lastActiveAt"]) == context.last_active["app"]
    assert epoch_s(lib["lastActiveAt"]) == context.last_active["lib"]
    context
  end

  # A session in `~/code/app` runs alongside, so the scan is shown to find folders.
  step ~r/^sessions ran in (?<folder>.+)$/, %{args: [folder]} = context do
    path =
      case folder do
        "the home folder itself" ->
          System.user_home!()

        "the temporary folder" ->
          System.tmp_dir!()

        "a folder under Downloads" ->
          Path.join([System.user_home!(), "Downloads", "unpacked"])

        "the HAL-C2 home" ->
          context.mc.home

        "a HAL-C2 worktree" ->
          mkdir(Path.join(context.agent_home, ".hal-c2/worktrees/app/hal-c2-1a2b"))

        "a linked git worktree" ->
          main = mkdir(dir(context, "~/code/main"))
          mkdir(Path.join(main, ".git/worktrees/linked"))
          linked = mkdir(dir(context, "~/code/linked"))
          File.write!(Path.join(linked, ".git"), "gitdir: #{main}/.git/worktrees/linked\n")
          linked

        "a folder that no longer exists" ->
          Path.join(context.agent_home, "code/gone")
      end

    session(context, path, source: "codex")
    session(context, mkdir(dir(context, "~/code/app")), source: "codex")
    Map.put(context, :folder, path)
  end

  step "that folder is not a candidate", context do
    assert Enum.map(context.scan["candidates"], & &1["path"]) == [dir(context, "~/code/app")]
    context
  end

  # Shared with projects.feature, whose `~` is the scenario's `$HOME`
  # (`HalC2.Test.Mc.Host`) rather than the agents' home (`context.agent_home`).
  step "project {string} has the folder {string}", %{args: [title, folder]} = context do
    if context[:agent_home] do
      path = mkdir(dir(context, folder))
      session(context, path, source: "claude")
      project(context, title, path)
    else
      HalC2.Test.Mc.Host.home(context)

      World.create_project(context, title, %{
        "workspaceRoot" => folder,
        "createWorkspaceRootIfMissing" => true
      })
    end
  end

  step "candidate {string} is marked already imported with project {string}",
       %{args: [candidate, title]} = context do
    id = World.project(context, title).id

    assert [%{"alreadyImported" => true, "projectId" => ^id}] =
             Enum.filter(context.scan["candidates"], &(&1["title"] == candidate))

    context
  end

  step "{string} is a git repository cloned from a remote", %{args: [folder]} = context do
    path = mkdir(dir(context, folder))
    World.git!(path, ~w(init -q -b main))
    World.git!(path, ~w(remote add origin https://github.com/Acme/App.git))
    session(context, path, source: "codex")
    context
  end

  step "candidate {string} carries a key for that remote shared by every clone",
       %{args: [candidate]} = context do
    [%{"git" => git}] = Enum.filter(context.scan["candidates"], &(&1["title"] == candidate))
    assert git == %{"remoteKey" => "github.com/acme/app", "repository" => "Acme/App"}
    assert HalC2.AgentSessions.remote_key("git@github.com:acme/app.git") == git["remoteKey"]
    context
  end

  # The oldest transcript is the only one in `~/code/old`, so it drops out with the cap.
  step "more than 5,000 Codex transcripts exist", context do
    now = System.os_time(:second)
    app = mkdir(dir(context, "~/code/app"))
    for i <- 1..5_000, do: session(context, app, source: "codex", mtime: now - i, messages: 0)
    session(context, mkdir(dir(context, "~/code/old")), source: "codex", mtime: now - 6_000)
    context
  end

  step "only the newest 5,000 are read and the result is marked truncated", context do
    assert context.scan["truncated"] == true
    assert [%{"title" => "app", "threadCount" => 5_000}] = context.scan["candidates"]
    context
  end

  # --- importing -----------------------------------------------------------------------

  step "project {string} has the folder {string} with {int} sessions from this week",
       %{args: [title, folder, n]} = context do
    path = mkdir(dir(context, folder))
    now = System.os_time(:second)

    for i <- 1..n,
        do:
          session(context, path,
            source: Enum.at(~w(claude codex), rem(i, 2)),
            mtime: now - i * @day
          )

    project(context, title, path)
  end

  step "a client imports agent sessions for {string}", %{args: [title]} = context do
    import_sessions(context, title)
  end

  step "2 threads exist in {string}, settled, created by the system, with their visible messages",
       %{args: [title]} = context do
    threads = imported(context, title)
    assert length(threads) == 2

    for {id, row} <- threads do
      assert row["settledOverride"] == "settled"
      state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
      assert HalC2.StreamState.get(state, "thread")[id]["createdBy"] == "system"

      assert state |> HalC2.StreamState.list("message") |> Enum.map(&{&1["role"], &1["text"]}) ==
               [{"user", "Fix the login bug"}, {"assistant", "Fixed it."}]
    end

    context
  end

  step "each is marked as imported history", context do
    for {id, _row} <- imported(context, "demo") do
      state = HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
      assert HalC2.StreamState.get(state, "thread")[id]["historyOrigin"] == "v1_import"
    end

    context
  end

  step "the import reports {int} imported and {int} skipped", %{args: [n, m]} = context do
    assert context.import == %{"importedCount" => n, "skippedCount" => m}
    context
  end

  step "a Claude session was imported as a thread", context do
    path = mkdir(dir(context, "~/code/app"))
    session_id = session(context, path, source: "claude")
    context = context |> project("demo", path) |> import_sessions("demo")
    assert context.import["importedCount"] == 1
    Map.put(context, :session_id, session_id)
  end

  step "the user sends a follow-up in that thread", context do
    context = World.providers(context)
    [{id, _}] = imported(context, "demo")
    context = put_in(context, [:threads, "imported"], id)

    command =
      World.message_command(context, "imported", "Now add a test", %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}
      })

    {{:ok, _}, context} = World.dispatch(context, command)
    World.await_runs(context, "imported", ["completed"])
    context
  end

  step "the provider resumes the original Claude session", context do
    assert [argv] = World.claude_starts(context)
    assert ["--resume", context.session_id] in Enum.chunk_every(argv, 2, 1, :discard)
    context
  end

  step "project {string} has one session from {int} days ago", %{args: [title, days]} = context do
    path = mkdir(dir(context, "~/code/app"))
    session(context, path, source: "claude", mtime: System.os_time(:second) - days * @day)
    project(context, title, path)
  end

  step "no thread is created for it", context do
    assert context.import == %{"importedCount" => 0, "skippedCount" => 0}
    assert imported(context, "demo") == []
    context
  end

  step "agent sessions of {string} were imported", %{args: [title]} = context do
    path = mkdir(dir(context, "~/code/app"))
    session(context, path, source: "claude")
    session(context, path, source: "codex")
    context = context |> project(title, path) |> import_sessions(title)
    assert context.import["importedCount"] == 2

    seqs =
      for {id, _} <- imported(context, title),
          into: %{},
          do: {id, HalC2.Streams.Server.state(HalC2.Streams.ensure(id)).seq}

    Map.put(context, :imported_seqs, seqs)
  end

  step "a client imports them again", context do
    import_sessions(context, "demo")
  end

  step "no new threads are created", context do
    threads = imported(context, "demo")

    assert Enum.map(threads, &elem(&1, 0)) |> Enum.sort() ==
             Map.keys(context.imported_seqs) |> Enum.sort()

    for {id, _} <- threads,
        do:
          assert(
            HalC2.Streams.Server.state(HalC2.Streams.ensure(id)).seq == context.imported_seqs[id]
          )

    context
  end

  step "project {string} has {int} recent sessions", %{args: [title, n]} = context do
    path = mkdir(dir(context, "~/code/app"))
    now = System.os_time(:second)

    ids =
      for i <- 1..n,
          do: session(context, path, source: "codex", mtime: now - i * 60)

    context |> project(title, path) |> Map.put(:session_ids, ids)
  end

  step "the newest {int} are imported and {int} are reported skipped",
       %{args: [n, m]} = context do
    assert context.import == %{"importedCount" => n, "skippedCount" => m}

    assert imported(context, "demo") |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             context.session_ids |> Enum.take(n) |> Enum.map(&"import:codex:#{&1}") |> Enum.sort()

    context
  end

  step "a session has {int} visible messages", %{args: [n]} = context do
    records =
      for i <- 1..n do
        role = if rem(i, 2) == 1, do: "user", else: "assistant"
        claude_record(role, "message #{i}")
      end

    single(context, source: "claude", records: records)
  end

  step "it is imported", context do
    import_sessions(context, "demo")
  end

  step "its thread holds the first user prompt followed by the latest messages, 200 in all",
       context do
    texts = context |> messages() |> Enum.map(& &1["text"])
    assert length(texts) == 200
    assert hd(texts) == "message 1"
    assert tl(texts) == for(i <- 302..500, do: "message #{i}")
    context
  end

  step ~r/^a session (?<source>has (?:a title|no title).*)$/, %{args: [source]} = context do
    long = String.duplicate("word ", 30)

    {records, expected} =
      case source do
        "has a title Claude generated" ->
          {[
             claude_record("user", "Fix it"),
             %{"type" => "ai-title", "aiTitle" => "Login bug fix"}
           ], "Login bug fix"}

        "has no title and a multi-line first prompt" ->
          {[claude_record("user", long <> "\nsecond line")],
           long |> String.slice(0, 100) |> String.trim()}

        "has no title and a blank first prompt" ->
          {[claude_record("user", "   \n  "), claude_record("user", "Real prompt\nmore")],
           "Real prompt"}
      end

    context |> single(source: "claude", records: records) |> Map.put(:expected_title, expected)
  end

  step ~r/^its thread title is (?<title>.+)$/, %{args: [_described]} = context do
    [{id, row}] = imported(context, "demo")
    assert row["title"] == context.expected_title, "thread #{id}"
    context
  end

  step "a Codex session ran on {string}", %{args: [model]} = context do
    single(context, source: "codex", model: model)
  end

  step "its thread's model is {string} on {string}", %{args: [model, instance]} = context do
    [{_id, row}] = imported(context, "demo")
    assert row["modelSelection"] == %{"instanceId" => instance, "model" => model}
    context
  end

  step "a Claude session has side-chain, meta and compaction summary records", context do
    records = [
      claude_record("user", "Visible prompt"),
      Map.put(claude_record("assistant", "side chain reply"), "isSidechain", true),
      Map.put(claude_record("user", "meta note"), "isMeta", true),
      Map.put(claude_record("user", "compaction summary"), "isCompactSummary", true),
      claude_record("assistant", "Visible reply")
    ]

    single(context, source: "claude", records: records)
  end

  step "those records are not messages of the thread", context do
    assert context |> messages() |> Enum.map(& &1["text"]) == ["Visible prompt", "Visible reply"]
    context
  end

  step "a Codex session records each prompt both as typed and with setup text", context do
    records =
      Enum.flat_map(["Add tests", "Run them"], fn prompt ->
        [
          codex_item("user", "<environment_context>cwd</environment_context>\n#{prompt}"),
          %{"type" => "event_msg", "payload" => %{"type" => "user_message", "message" => prompt}},
          codex_item("assistant", "Done: #{prompt}")
        ]
      end)

    single(context, source: "codex", records: records)
  end

  step "each user message is the typed prompt only", context do
    users = for m <- messages(context), m["role"] == "user", do: m["text"]
    assert users == ["Add tests", "Run them"]
    context
  end

  step ~r/^a session (?<problem>has no session id|has no user prompt|has a malformed Claude session id)$/,
       %{args: [problem]} = context do
    case problem do
      "has no session id" ->
        single(context, source: "codex", id: nil)

      "has no user prompt" ->
        single(context, source: "claude", records: [claude_record("assistant", "Hello")])

      "has a malformed Claude session id" ->
        single(context, source: "claude", id: "not-a-session-id")
    end
  end

  step "its project is imported", context do
    import_sessions(context, "demo")
  end

  step "it is counted as skipped", context do
    assert context.import == %{"importedCount" => 0, "skippedCount" => 1}
    assert imported(context, "demo") == []
    context
  end

  step "a client imports agent sessions for project {string}", %{args: [id]} = context do
    {reply, context} = World.call(context, "agentSessions.import", %{"projectId" => id})
    Map.put(context, :reply, reply)
  end

  step "the client scanned {string} at {string} and the project now points elsewhere",
       %{args: [title, folder]} = context do
    path = mkdir(dir(context, folder))
    session(context, path, source: "claude")
    context = project(context, title, path)
    {scan, context} = World.call!(context, "agentSessions.scan")
    assert [%{"path" => ^path, "alreadyImported" => true}] = scan["candidates"]

    elsewhere = mkdir(dir(context, "~/code/moved"))

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.update",
        "projectId" => World.project(context, title).id,
        "workspaceRoot" => elsewhere
      })

    World.await_row(World.project(context, title).id, &(&1["workspaceRoot"] == elsewhere))
    context
  end

  step "the client imports expecting {string}", %{args: [folder]} = context do
    {reply, context} =
      World.call(context, "agentSessions.import", %{
        "projectId" => World.project(context, "demo").id,
        "expectedWorkspaceRoot" => dir(context, folder)
      })

    Map.put(context, :reply, reply)
  end

  step "a transcript contains a tool result line larger than 4 MB", context do
    huge = %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "content" => String.duplicate("x", 5 * 1024 * 1024)}
        ]
      }
    }

    records = [
      claude_record("user", "Take a screenshot"),
      huge,
      claude_record("assistant", "Here it is")
    ]

    single(context, source: "claude", records: records)
  end

  step "the line is skipped and the rest of the session is imported", context do
    assert context.import == %{"importedCount" => 1, "skippedCount" => 0}
    assert context |> messages() |> Enum.map(& &1["text"]) == ["Take a screenshot", "Here it is"]
    context
  end

  # --- sessions other threads own, and imports the user has since used --------------------

  step ~r/^thread "(?<id>[^"]+)" in "(?<project>[^"]+)" already runs the agent session "(?<session>[^"]+)" and is (?<state>active|archived|deleted)$/,
       %{args: [title, project, name, state]} = context do
    path = mkdir(dir(context, "~/code/app"))
    session_id = session(context, path, source: "claude")
    context = project(context, project, path)
    context = World.create_thread(context, title, project, %{"modelSelection" => claude_model()})
    id = World.thread_id(context, title)

    pt = HalC2.Orchestration.Entities.provider_thread_id("claudeAgent", id)

    provider_thread =
      HalC2.Orchestration.Entities.provider_thread(
        pt,
        id,
        nil,
        nil,
        HalC2.Orchestration.Entities.now(),
        "claudeAgent",
        "claudeAgent"
      )
      |> Map.put(
        "nativeThreadRef",
        HalC2.Orchestration.Entities.provider_ref(session_id, "claudeAgent")
      )

    context = World.put_entity(context, title, "provider-thread", pt, %{"s" => provider_thread})

    command =
      case state do
        "active" -> nil
        "archived" -> "thread.archive"
        "deleted" -> "thread.delete"
      end

    if command do
      {:ok, _} = HalC2.Orchestration.dispatch(%{"type" => command, "threadId" => id})
      World.await_row(id, &(&1["archivedAt"] != nil or &1["deletedAt"] != nil))
    end

    _ = name
    Map.put(context, :owner_session, session_id)
  end

  step "no new thread is created for {string}", context do
    assert [] =
             imported(context, "demo")
             |> Enum.filter(fn {id, _} -> String.starts_with?(id, "import:") end)

    context
  end

  step "{string} is counted as neither imported nor failed", context do
    assert context.import == %{"importedCount" => 0, "skippedCount" => 0}
    context
  end

  step ~r/^a session was imported as a thread and (?<change>the user continued it in HAL-C2|the thread now belongs to another project)$/,
       %{args: [change]} = context do
    path = mkdir(dir(context, "~/code/app"))
    session(context, path, source: "claude")
    context = context |> project("demo", path) |> import_sessions("demo")
    assert context.import["importedCount"] == 1
    [{id, _}] = imported(context, "demo")
    context = put_in(context, [:threads, "imported"], id)
    seq = HalC2.Streams.Server.state(HalC2.Streams.ensure(id)).seq

    context =
      case change do
        "the user continued it in HAL-C2" ->
          World.add_run(context, "imported", "completed")

        _ ->
          context = project(context, "other", mkdir(dir(context, "~/code/other")))
          other = World.project(context, "other").id
          World.patch_thread(context, "imported", %{"projectId" => other})
      end

    context
    |> Map.put(:imported_thread, id)
    |> Map.put(:imported_seq, HalC2.Streams.Server.state(HalC2.Streams.ensure(id)).seq)
    |> Map.put(:seq_before_change, seq)
  end

  step "a client imports the agent sessions of {string} again", %{args: [title]} = context do
    import_sessions(context, title)
  end

  step "the thread is not overwritten", context do
    id = context.imported_thread
    assert HalC2.Streams.Server.state(HalC2.Streams.ensure(id)).seq == context.imported_seq
    context
  end

  step "the session is counted as skipped", context do
    assert context.import == %{"importedCount" => 0, "skippedCount" => 1}
    context
  end

  # --- damaged records, titles, and other ways a transcript differs ---------------------------

  step ~r/^a session's transcript has one line that (?<damage>is cut off in the middle of its JSON|is not JSON at all|has no message in it that the MC understands)$/,
       %{args: [damage]} = context do
    line =
      case damage do
        "is cut off in the middle of its JSON" -> ~s({"type":"user","message":{"role":"us)
        "is not JSON at all" -> "this line is not JSON"
        _ -> %{"type" => "queue-operation", "operation" => "enqueue"}
      end

    records = [
      claude_record("user", "Before the damage"),
      line,
      claude_record("assistant", "After the damage")
    ]

    single(context, source: "claude", records: records)
  end

  step "a client imports the agent sessions of {string}", %{args: [title]} = context do
    import_sessions(context, title)
  end

  step "the session is imported with its other messages", context do
    assert context.import == %{"importedCount" => 1, "skippedCount" => 0}

    assert context |> messages() |> Enum.map(& &1["text"]) == [
             "Before the damage",
             "After the damage"
           ]

    context
  end

  step "that line is not a message of the thread", context do
    assert length(messages(context)) == 2
    context
  end

  @setup "<environment_context>cwd: /work</environment_context>"

  step "a Codex session whose first message starts with injected setup instructions before the user's request",
       context do
    records = [
      codex_item("user", @setup <> "\nFix the flaky test"),
      %{
        "type" => "event_msg",
        "payload" => %{"type" => "user_message", "message" => "Fix the flaky test"}
      },
      codex_item("assistant", "On it.")
    ]

    context
    |> single(source: "codex", records: records)
    |> Map.put(:expected_title, "Fix the flaky test")
  end

  step "a Codex session whose first message holds only injected setup instructions", context do
    records = [
      codex_item("user", @setup),
      codex_item("assistant", "Ready."),
      codex_item("user", @setup <> "\nAdd tests"),
      %{"type" => "event_msg", "payload" => %{"type" => "user_message", "message" => "Add tests"}}
    ]

    context |> single(source: "codex", records: records) |> Map.put(:expected_title, "Add tests")
  end

  step "the session is imported", context do
    import_sessions(context, "demo")
  end

  step "the thread's title comes from the user's request, not the setup instructions", context do
    [{_id, row}] = imported(context, "demo")
    assert row["title"] == context.expected_title
    context
  end

  step "the thread's title comes from the next message the user wrote", context do
    [{_id, row}] = imported(context, "demo")
    assert row["title"] == context.expected_title
    context
  end

  step "a Codex conversation the user renamed {string}, then {string}, then to a blank name",
       %{args: [first, second]} = context do
    id = "019f3efa-0b5d-7c63-b7fd-d961f1277744"
    context = single(context, source: "codex", id: id)
    write_index(context, id, [first, second, ""])
    Map.put(context, :expected_title, second)
  end

  step "a Codex conversation with no saved name is titled from its messages as before", context do
    records = [
      %{
        "type" => "event_msg",
        "payload" => %{"type" => "user_message", "message" => "Unnamed work"}
      }
    ]

    session(context, mkdir(dir(context, "~/code/app")), source: "codex", records: records)
    context = import_sessions(context, "demo")
    titles = for {_id, row} <- imported(context, "demo"), do: row["title"]
    assert Enum.sort(titles) == ["Cart totals", "Unnamed work"]
    context
  end

  step "a Claude session the user renamed {string} and Claude later titled {string}",
       %{args: [mine, theirs]} = context do
    records = [
      claude_record("user", "Fix it"),
      %{"type" => "custom-title", "customTitle" => mine},
      %{"type" => "ai-title", "aiTitle" => theirs}
    ]

    single(context, source: "claude", records: records)
    |> Map.put(:expected_title, mine)
  end

  step "a Codex session was forked and its transcript begins with its ancestor's session metadata",
       context do
    ancestor = %{
      "type" => "session_meta",
      "payload" => %{"id" => "ancestor-session", "cwd" => "/x"}
    }

    prompt = %{
      "type" => "event_msg",
      "payload" => %{"type" => "user_message", "message" => "Continue the work"}
    }

    context = single(context, source: "codex", id: "forked-session", records: [ancestor, prompt])
    Map.put(context, :session_id, "forked-session")
  end

  step "the thread resumes the id the transcript names first", context do
    assert [{"import:codex:forked-session", _}] = imported(context, "demo")
    context
  end

  step "a folder holds {int} recent Codex subagent sessions and {int} older top-level sessions",
       %{args: [children, top]} = context do
    path = mkdir(dir(context, "~/code/app"))
    now = System.os_time(:second)
    for i <- 1..children, do: session(context, path, source: "codex", child: true, mtime: now - i)
    for i <- 1..top, do: session(context, path, source: "codex", mtime: now - 1_000 - i)
    project(context, "demo", path)
  end

  step "the {int} top-level sessions are imported", %{args: [n]} = context do
    assert context.import["importedCount"] == n
    assert length(imported(context, "demo")) == n
    context
  end

  step "the subagent sessions are neither imported nor counted", context do
    assert context.import["skippedCount"] == 0
    context
  end

  step "project {string} has a session whose transcript was last changed tomorrow",
       %{args: [title]} = context do
    path = mkdir(dir(context, "~/code/app"))
    session(context, path, source: "claude", mtime: System.os_time(:second) + @day)
    project(context, title, path)
  end

  step "project {string} has the same Claude session in two transcript files",
       %{args: [title]} = context do
    path = mkdir(dir(context, "~/code/app"))
    id = HalC2.Environment.uuid4()
    session(context, path, source: "claude", id: id)
    session(context, path, source: "claude", id: id)
    project(context, title, path)
  end

  step "one thread exists for the session", context do
    assert [_] = imported(context, "demo")
    context
  end

  step "a session has a message whose time is missing or not a date", context do
    mtime = System.os_time(:second) - 3_600

    records = [
      claude_record("user", "No time") |> Map.delete("timestamp"),
      claude_record("assistant", "Odd time", "yesterday-ish")
    ]

    context |> single(source: "claude", records: records, mtime: mtime) |> Map.put(:mtime, mtime)
  end

  step "that message is dated with the transcript's last change time", context do
    expected =
      (context.mtime * 1000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    assert context |> messages() |> Enum.map(& &1["createdAt"]) == [expected, expected]
    context
  end

  step "a transcript whose first records hold only history and name the folder {string} in a later record",
       %{args: [folder]} = context do
    path = mkdir(dir(context, folder))

    records = [
      %{"type" => "response_item", "payload" => %{"type" => "reasoning"}},
      %{"type" => "event_msg", "payload" => %{"type" => "user_message", "message" => "Hi"}}
    ]

    session(context, path, source: "codex", records: records, late_cwd: true)
    context
  end

  step "the transcript counts toward {string}", %{args: [title]} = context do
    assert [%{"title" => ^title, "threadCount" => 1}] = context.scan["candidates"]
    context
  end

  step "sessions were recorded under {string} and under {string}, a link to the same folder",
       %{args: [real, via]} = context do
    app = mkdir(dir(context, real))
    session(context, app, source: "codex")
    link(context, app, via)
    session(context, dir(context, via), source: "claude")
    context
  end

  step "there is one candidate {string} counting the sessions of both",
       %{args: [title]} = context do
    assert [%{"title" => ^title, "threadCount" => 2}] = context.scan["candidates"]
    context
  end

  step "sessions were recorded under {string}, a link to that folder", %{args: [via]} = context do
    app = dir(context, "~/code/app")
    link(context, app, via)
    session(context, dir(context, via), source: "codex")
    context
  end

  step "project {string} has the folder {string}, a link to {string}",
       %{args: [title, via, real]} = context do
    app = mkdir(dir(context, real))
    link(context, app, via)
    project(context, title, dir(context, via))
  end

  step "sessions were recorded under {string}", %{args: [folder]} = context do
    session(context, dir(context, folder), source: "codex")
    context
  end

  step "the candidate is marked already imported with project {string}",
       %{args: [title]} = context do
    id = World.project(context, title).id
    assert [%{"alreadyImported" => true, "projectId" => ^id}] = context.scan["candidates"]
    context
  end

  step "the candidate's path is {string}", %{args: [folder]} = context do
    assert [%{"path" => path}] = context.scan["candidates"]
    assert path == dir(context, folder)
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp link(context, target, via) do
    path = dir(context, via)
    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(target, path)
  end

  defp write_index(context, id, names) do
    lines = for name <- names, do: JSON.encode!(%{"id" => id, "thread_name" => name}) <> "\n"
    File.write!(Path.join(context.agent_home, ".codex/session_index.jsonl"), lines)
  end

  defp claude_model, do: %{"instanceId" => "claudeAgent", "model" => "haiku"}

  defp dir(context, "~/" <> rest), do: Path.join(context.agent_home, rest)

  defp mkdir(path) do
    File.mkdir_p!(path)
    path
  end

  defp project(context, title, path) do
    World.create_project(context, title, %{"projectId" => title, "workspaceRoot" => path})
  end

  # One session in `~/code/app` of a project "demo".
  defp single(context, opts) do
    path = mkdir(dir(context, "~/code/app"))
    session(context, path, opts)
    project(context, "demo", path)
  end

  defp import_sessions(context, title) do
    {result, context} =
      World.call!(context, "agentSessions.import", %{
        "projectId" => World.project(context, title).id
      })

    Map.put(context, :import, result)
  end

  # Imported threads of a project, as `{id, row}`, once the import's
  # `importedCount` threads have their sidebar rows.
  defp imported(context, title) do
    project = World.project(context, title).id
    count = if context[:import], do: context.import["importedCount"], else: 0
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_rows(project, count, deadline)
  end

  defp await_rows(project, count, deadline) do
    rows =
      for {{mc, id}, {"thread", row}} <- HalC2.Shell.rows(),
          mc == node() and row["projectId"] == project,
          do: {id, row}

    if length(rows) >= count do
      rows
    else
      receive do
        {:hal_c2_shell, _} -> await_rows(project, count, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("expected #{count} imported threads, found #{length(rows)}")
      end
    end
  end

  defp messages(context) do
    [{id, _}] = imported(context, "demo")

    HalC2.Streams.Server.state(HalC2.Streams.ensure(id))
    |> HalC2.StreamState.list("message")
    |> Enum.sort_by(& &1["id"])
  end

  defp epoch_s(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at)
  end

  # Writes one transcript ran in `cwd` and returns its session id. Options: `source`
  # ("claude" or "codex"), `mtime` (unix seconds, default now), `records` (replacing
  # the default prompt and reply), `messages: 0` (no messages), `model`, `id`.
  defp session(context, cwd, opts) do
    source = Keyword.fetch!(opts, :source)
    mtime = Keyword.get(opts, :mtime, System.os_time(:second))
    id = Keyword.get(opts, :id, HalC2.Environment.uuid4())
    n = System.unique_integer([:positive])

    {path, records} =
      case source do
        "claude" ->
          records =
            Keyword.get_lazy(opts, :records, fn ->
              if opts[:messages] == 0,
                do: [],
                else: [
                  claude_record("user", "Fix the login bug"),
                  claude_record("assistant", "Fixed it.")
                ]
            end)

          head = %{"type" => "system", "cwd" => cwd, "sessionId" => id}

          file =
            Path.join([context.agent_home, ".claude/projects/p#{n}", "#{id || "none"}.jsonl"])

          {file, [head | records]}

        "codex" ->
          records =
            Keyword.get_lazy(opts, :records, fn ->
              if opts[:messages] == 0,
                do: [],
                else: [
                  %{
                    "type" => "event_msg",
                    "payload" => %{"type" => "user_message", "message" => "Fix the login bug"}
                  },
                  codex_item("assistant", "Fixed it.")
                ]
            end)

          source = if opts[:child], do: %{"subagent" => %{"thread_spawn" => %{}}}, else: "cli"
          late = opts[:late_cwd]

          meta = %{
            "type" => "session_meta",
            "payload" =>
              Map.reject(
                %{"id" => id, "cwd" => if(late, do: nil, else: cwd), "source" => source},
                &is_nil(elem(&1, 1))
              )
          }

          model = %{
            "type" => "turn_context",
            "payload" =>
              Map.reject(
                %{"model" => opts[:model] || "gpt-5.4", "cwd" => if(late, do: cwd)},
                &is_nil(elem(&1, 1))
              )
          }

          file =
            Path.join([context.agent_home, ".codex/sessions/2026/09/20", "rollout-#{n}.jsonl"])

          {file, [meta, model | records]}
      end

    File.mkdir_p!(Path.dirname(path))
    # A binary record is written as it is, to make a damaged line.
    File.write!(
      path,
      Enum.map(records, &(if(is_binary(&1), do: &1, else: JSON.encode!(&1)) <> "\n"))
    )

    File.touch!(path, mtime)
    id
  end

  defp claude_record(role, text, timestamp \\ DateTime.utc_now() |> DateTime.to_iso8601()) do
    %{
      "type" => role,
      "timestamp" => timestamp,
      "message" => %{"role" => role, "content" => text}
    }
  end

  defp codex_item(role, text) do
    type = if role == "user", do: "input_text", else: "output_text"

    %{
      "type" => "response_item",
      "payload" => %{
        "type" => "message",
        "role" => role,
        "content" => [%{"type" => type, "text" => text}]
      }
    }
  end
end
