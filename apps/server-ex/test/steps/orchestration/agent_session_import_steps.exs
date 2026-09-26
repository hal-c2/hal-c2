defmodule T3.Steps.Orchestration.AgentSessionImport do
  @moduledoc """
  Steps for `features/node/orchestration/agent-session-import.feature`.

  Transcripts are written under a scratch folder that stands in for the user's
  home: `~/code/app` is `<scratch>/code/app`, and `CLAUDE_CONFIG_DIR` and
  `CODEX_HOME` point at `<scratch>/.claude` and `<scratch>/.codex`. The real home
  and temporary folders are only named, never written to.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node.World

  @day 24 * 60 * 60

  step "Claude Code and Codex transcripts exist on this machine", context do
    root = Path.join(System.tmp_dir!(), "t3-agent-home-#{System.unique_integer([:positive])}")
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

        "the T3 home" ->
          context.node.home

        "a T3 worktree" ->
          mkdir(Path.join(context.agent_home, ".t3/worktrees/app/t3code-1a2b"))

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
  # (`T3.Test.Node.Host`) rather than the agents' home (`context.agent_home`).
  step "project {string} has the folder {string}", %{args: [title, folder]} = context do
    if context[:agent_home] do
      path = mkdir(dir(context, folder))
      session(context, path, source: "claude")
      project(context, title, path)
    else
      T3.Test.Node.Host.home(context)

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
    assert T3.AgentSessions.remote_key("git@github.com:acme/app.git") == git["remoteKey"]
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
      state = T3.Streams.Server.state(T3.Streams.ensure(id))
      assert T3.StreamState.get(state, "thread")[id]["createdBy"] == "system"

      assert state |> T3.StreamState.list("message") |> Enum.map(&{&1["role"], &1["text"]}) ==
               [{"user", "Fix the login bug"}, {"assistant", "Fixed it."}]
    end

    context
  end

  step "each is marked as imported history", context do
    for {id, _row} <- imported(context, "demo") do
      state = T3.Streams.Server.state(T3.Streams.ensure(id))
      assert T3.StreamState.get(state, "thread")[id]["historyOrigin"] == "v1_import"
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
          do: {id, T3.Streams.Server.state(T3.Streams.ensure(id)).seq}

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
          assert(T3.Streams.Server.state(T3.Streams.ensure(id)).seq == context.imported_seqs[id])

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
      T3.Projects.mutate(%{
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

  # --- helpers ---------------------------------------------------------------------------

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
      for {{node, id}, {"thread", row}} <- T3.Shell.rows(),
          node == node() and row["projectId"] == project,
          do: {id, row}

    if length(rows) >= count do
      rows
    else
      receive do
        {:t3_shell, _} -> await_rows(project, count, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("expected #{count} imported threads, found #{length(rows)}")
      end
    end
  end

  defp messages(context) do
    [{id, _}] = imported(context, "demo")

    T3.Streams.Server.state(T3.Streams.ensure(id))
    |> T3.StreamState.list("message")
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
    id = Keyword.get(opts, :id, T3.Environment.uuid4())
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

          meta = %{
            "type" => "session_meta",
            "payload" => Map.reject(%{"id" => id, "cwd" => cwd}, &is_nil(elem(&1, 1)))
          }

          model = %{
            "type" => "turn_context",
            "payload" => %{"model" => opts[:model] || "gpt-5.4"}
          }

          file =
            Path.join([context.agent_home, ".codex/sessions/2026/09/20", "rollout-#{n}.jsonl"])

          {file, [meta, model | records]}
      end

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(records, &(JSON.encode!(&1) <> "\n")))
    File.touch!(path, mtime)
    id
  end

  defp claude_record(role, text) do
    %{
      "type" => role,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
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
