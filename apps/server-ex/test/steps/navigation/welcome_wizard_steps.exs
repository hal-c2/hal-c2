defmodule T3.Steps.Navigation.WelcomeWizard do
  @moduledoc """
  Steps for `features/navigation/welcome-wizard.feature`: the project scan and the
  history import behind the wizard (`agentSessions.scan`, `agentSessions.import`).

  The agents' history lives in a fixture home outside the node's home: Claude Code
  transcripts under `.claude/projects`, Codex's under `.codex/sessions`. How the
  wizard groups, orders and preselects what a scan returns is the web client's
  (`apps/web/src/onboarding/projectImport.logic.ts`), reproduced in `listing/1`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.StreamState
  alias T3.Test.Node.World

  @day 86_400
  # WelcomeWizard.tsx
  @other_folders "Other folders"
  @scan_limit "Scan limit reached. Some projects or conversations may be missing."

  # --- listing projects ------------------------------------------------------------

  step "Claude Code and Codex used two git repositories and one plain folder", context do
    context = fixture(context)
    newer = repo(context, "newer")
    older = repo(context, "older")
    plain = folder(context, "notes")

    claude(context, newer, conversation("Fix the login"), 1 * @day)
    codex(context, older, "Add tests", 5 * @day)
    claude(context, plain, conversation("What is this?"), 2 * @day)

    Map.merge(context, %{git_folders: [newer, older], plain_folder: plain})
  end

  step "the wizard lists projects", context do
    {scan, context} = World.call!(context, "agentSessions.scan")
    Map.merge(context, %{scan: scan, listing: listing(scan)})
  end

  step "the git repositories are listed newest activity first", context do
    listed = for group <- context.listing.repositories, c <- group.candidates, do: c["path"]
    assert listed == context.git_folders
    context
  end

  step "the plain folder is listed under {string}", %{args: [label]} = context do
    assert label == @other_folders
    assert Enum.map(context.listing.other, & &1["path"]) == [context.plain_folder]
    context
  end

  step ~r/^two folders are clones of (?<remote>\S+)$/, %{args: [remote]} = context do
    context = fixture(context)
    [host, owner, name] = String.split(remote, "/")
    https = repo(context, "api", "https://#{host}/#{owner}/#{name}.git")
    ssh = repo(context, "api-copy", "git@#{host}:#{owner}/#{name}.git")
    claude(context, https, conversation("Ship it"), @day)
    claude(context, ssh, conversation("Review it"), 2 * @day)
    Map.put(context, :clones, [https, ssh])
  end

  step "both folders are grouped under {string}", %{args: [label]} = context do
    group = Enum.find(context.listing.repositories, &(&1.label == label))
    assert group, "no group #{inspect(label)} in #{inspect(context.listing.repositories)}"
    assert Enum.sort(Enum.map(group.candidates, & &1["path"])) == Enum.sort(context.clones)
    context
  end

  step "a repository with {int} conversation(s) in the last 30 days",
       %{args: [count]} = context do
    context = fixture(context)
    repos = Map.get(context, :wizard_repos, [])
    root = repo(context, "repo-#{length(repos) + 1}")
    for i <- 1..count, do: claude(context, root, conversation("Task #{i}"), i * @day)
    Map.put(context, :wizard_repos, repos ++ [root])
  end

  step "only the first repository is selected", context do
    assert Enum.map(context.listing.selected, & &1["path"]) == [hd(context.wizard_repos)]
    context
  end

  # A repository the scan does offer sits beside the folder, so the scan is known
  # to have run over the agent history that names both.
  step ~r/^an agent used a folder that is (?<kind>.+)$/, %{args: [kind]} = context do
    context = fixture(context)
    offered = repo(context, "offered")
    claude(context, offered, conversation("Offered"), @day)

    folder =
      case kind do
        "a linked git worktree" ->
          main = repo(context, "main")
          worktree = folder(context, "main-feature")
          File.mkdir_p!(Path.join([main, ".git", "worktrees", "main-feature"]))

          File.write!(
            Path.join(worktree, ".git"),
            "gitdir: #{Path.join([main, ".git", "worktrees", "main-feature"])}\n"
          )

          worktree

        "under Documents/Codex" ->
          repo(context, Path.join(["Documents", "Codex", "scratch"]), nil, :home)

        "under Downloads" ->
          repo(context, Path.join("Downloads", "unzipped"), nil, :home)
      end

    claude(context, folder, conversation("Hidden"), @day)
    Map.merge(context, %{hidden_folder: folder, offered_folder: offered})
  end

  step "that folder is not offered", context do
    paths = Enum.map(context.scan["candidates"], & &1["path"])
    assert context.offered_folder in paths
    refute context.hidden_folder in paths
    context
  end

  step "an agent history too large to scan fully", context do
    context = fixture(context)
    put_app_env(:agent_sessions_max_transcripts, 2)
    recent = repo(context, "recent")
    stale = repo(context, "stale")
    for i <- 1..2, do: claude(context, recent, conversation("Recent #{i}"), i * 3600)
    for i <- 1..2, do: claude(context, stale, conversation("Stale #{i}"), i * @day)
    Map.put(context, :found_folder, recent)
  end

  step "the projects found so far are listed", context do
    assert context.scan["truncated"] == true
    assert [%{"path" => path, "threadCount" => 2}] = context.scan["candidates"]
    assert path == context.found_folder
    context
  end

  step "the user is warned {string}", %{args: [message]} = context do
    warning = if context.scan["truncated"], do: @scan_limit
    assert warning == message
    context
  end

  # --- importing history -----------------------------------------------------------

  step "a conversation of {int} visible messages from the last 30 days",
       %{args: [count]} = context do
    context = fixture(context)
    root = repo(context, "long")

    # Visible messages alternate user and assistant; each prompt carries an image
    # and each reply a tool call, and tool results come back between them.
    records =
      Enum.flat_map(1..count, fn i ->
        at = DateTime.add(~U[2026-09-20 08:00:00Z], i, :second) |> DateTime.to_iso8601()

        if rem(i, 2) == 1 do
          [
            {"user",
             [
               %{"type" => "text", "text" => "Prompt #{i}"},
               %{"type" => "image", "source" => %{"type" => "base64", "data" => "aGk="}}
             ], at}
          ]
        else
          [
            {"assistant",
             [
               %{"type" => "text", "text" => "Reply #{i}"},
               %{"type" => "tool_use", "id" => "tool-#{i}", "name" => "Bash", "input" => %{}}
             ], at},
            {"user",
             [%{"type" => "tool_result", "tool_use_id" => "tool-#{i}", "content" => "ran #{i}"}],
             at}
          ]
        end
      end)

    session = claude(context, root, records, @day)
    Map.merge(context, %{import_root: root, long_session: session, message_count: count})
  end

  step "the conversation keeps the first user prompt and the newest messages up to {int} in total",
       %{args: [max]} = context do
    assert %{"importedCount" => 1} = context.import_result
    texts = context |> messages(context.long_session) |> Enum.map(& &1["text"])
    newest = for i <- (context.message_count - max + 2)..context.message_count, do: visible(i)
    assert texts == ["Prompt 1" | newest]
    assert length(texts) == max
    context
  end

  step "tool activity and attachments are left out", context do
    for message <- messages(context, context.long_session) do
      refute message["text"] =~ "ran "
      refute message["text"] =~ "tool-"
      assert message["attachments"] == []
    end

    context
  end

  step ~r/^a conversation that is (?<problem>.+)$/, %{args: [problem]} = context do
    context = fixture(context)
    root = repo(context, "mixed")
    good = for i <- 1..2, do: claude(context, root, conversation("Good #{i}"), i * @day)

    bad =
      case problem do
        "larger than 4 GiB" ->
          # The limit is lowered for the test rather than writing gigabytes.
          put_app_env(:agent_sessions_max_import_bytes, 4_096)
          claude(context, root, conversation(String.duplicate("big ", 2_000)), @day)

        "not parseable" ->
          session = claude(context, root, [], @day)

          File.write!(
            transcript(context, root, session),
            "{\"cwd\": #{JSON.encode!(root)}}\n{not json\n",
            [:append]
          )

          session

        "older than 30 days" ->
          claude(context, root, conversation("Old"), 40 * @day)
      end

    Map.merge(context, %{
      import_root: root,
      good_sessions: good,
      bad_session: bad,
      problem: problem
    })
  end

  step "that conversation is skipped", context do
    assert thread(context.bad_session) == nil

    # Read and refused counts as skipped; a conversation outside the window is
    # never read.
    unless context.problem == "older than 30 days",
      do: assert(context.import_result["skippedCount"] >= 1)

    context
  end

  step "the other conversations are imported", context do
    assert context.import_result["importedCount"] == length(context.good_sessions)
    for session <- context.good_sessions, do: assert(thread(session))
    context
  end

  step "a project with {int} conversation files", %{args: [count]} = context do
    context = fixture(context)
    root = repo(context, "big")
    sessions = for i <- 1..count, do: claude(context, root, conversation("Task #{i}"), i * 600)
    Map.merge(context, %{import_root: root, sessions: sessions})
  end

  step "the user imports it", context do
    World.import_agent_sessions(context)
  end

  step "at most {int} conversation files are read", %{args: [max]} = context do
    assert context.import_result["importedCount"] == max
    imported = Enum.filter(context.sessions, &thread/1)
    assert length(imported) == max
    # The newest first.
    assert imported == Enum.take(context.sessions, max)

    # The sidebar knows them before the user goes on.
    for session <- imported, do: World.await_row(thread_id(session), & &1)
    Map.put(context, :first_import, Map.new(imported, &{&1, length(messages(context, &1))}))
  end

  step "the user runs the import again", context do
    World.import_agent_sessions(context)
  end

  step "the rest are imported", context do
    assert context.import_result["importedCount"] == length(context.sessions)
    assert Enum.all?(context.sessions, &thread/1)
    context
  end

  step "conversations already imported are not imported again", context do
    for {session, count} <- context.first_import,
        do: assert(length(messages(context, session)) == count)

    project_id = World.project(context).id

    threads =
      for {{node, _}, {"thread", %{"projectId" => ^project_id} = t}} <- T3.Shell.rows(),
          node == node(),
          do: t["id"]

    assert length(Enum.uniq(threads)) <= length(context.sessions)
    context
  end

  # --- helpers -----------------------------------------------------------------------

  # The agents' home for this scenario, outside the node's home (which a scan skips).
  defp fixture(%{wizard_home: _} = context), do: context

  defp fixture(context) do
    home = Path.join(System.tmp_dir!(), "t3-wizard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(home) end)
    put_app_env(:agent_sessions_home, home)
    World.put_env("CLAUDE_CONFIG_DIR", Path.join(home, ".claude"))
    World.put_env("CODEX_HOME", Path.join(home, ".codex"))
    Map.put(context, :wizard_home, home)
  end

  defp put_app_env(key, value) do
    previous = Application.fetch_env(:t3, key)
    Application.put_env(:t3, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:t3, key, value)
        :error -> Application.delete_env(:t3, key)
      end
    end)
  end

  defp folder(context, name) do
    dir = Path.join([context.wizard_home, "code", name])
    File.mkdir_p!(dir)
    dir
  end

  # A git repository as a scan sees it: a `.git` directory with its config.
  defp repo(context, name, remote \\ nil, under \\ :code) do
    dir =
      if under == :home,
        do: Path.join(context.wizard_home, name),
        else: folder(context, name)

    File.mkdir_p!(Path.join(dir, ".git"))

    config =
      "[core]\n\trepositoryformatversion = 0\n" <>
        if(remote, do: "[remote \"origin\"]\n\turl = #{remote}\n", else: "")

    File.write!(Path.join([dir, ".git", "config"]), config)
    dir
  end

  defp conversation(prompt) do
    at = DateTime.to_iso8601(~U[2026-09-20 08:00:00Z])

    [
      {"user", prompt, at},
      {"assistant", "Done: #{prompt}", DateTime.to_iso8601(~U[2026-09-20 08:01:00Z])}
    ]
  end

  defp visible(i), do: if(rem(i, 2) == 1, do: "Prompt #{i}", else: "Reply #{i}")

  # A Claude Code transcript last written `age` seconds ago; returns its session id.
  defp claude(context, cwd, records, age) do
    session = session_id()
    path = transcript(context, cwd, session)
    File.mkdir_p!(Path.dirname(path))

    lines =
      for {role, content, at} <- records do
        JSON.encode!(%{
          "type" => role,
          "cwd" => cwd,
          "sessionId" => session,
          "timestamp" => at,
          "message" => %{"role" => role, "content" => content}
        })
      end

    File.write!(path, Enum.map(lines, &(&1 <> "\n")))
    File.touch!(path, System.os_time(:second) - age)
    session
  end

  defp transcript(context, cwd, session) do
    dir = String.replace(cwd, ~r/[^A-Za-z0-9]/, "-")
    Path.join([context.wizard_home, ".claude", "projects", dir, "#{session}.jsonl"])
  end

  defp codex(context, cwd, prompt, age) do
    session = "codex-#{System.unique_integer([:positive])}"

    path =
      Path.join([
        context.wizard_home,
        ".codex",
        "sessions",
        "2026",
        "09",
        "20",
        "rollout-#{session}.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Enum.map_join(
        [
          %{"type" => "session_meta", "payload" => %{"id" => session, "cwd" => cwd}},
          %{"type" => "event_msg", "payload" => %{"type" => "user_message", "message" => prompt}}
        ],
        &(JSON.encode!(&1) <> "\n")
      )
    )

    File.touch!(path, System.os_time(:second) - age)
    session
  end

  defp session_id do
    n = System.unique_integer([:positive])
    :io_lib.format("~8.16.0b-0000-4000-8000-~12.16.0b", [rem(n, 0xFFFFFFFF), n]) |> to_string()
  end

  # The wizard's view of a scan: repositories grouped by origin (newest activity
  # first), plain folders apart, and busy recent repositories preselected.
  defp listing(scan) do
    candidates = scan["candidates"]
    {other, repos} = Enum.split_with(candidates, &(&1["git"] == nil))
    cutoff = DateTime.add(DateTime.utc_now(), -30 * @day, :second) |> DateTime.to_iso8601()

    repositories =
      repos
      |> Enum.group_by(fn c ->
        if key = c["git"]["remoteKey"], do: "remote:#{key}", else: "path:#{c["path"]}"
      end)
      |> Enum.map(fn {_key, [first | _] = group} ->
        %{
          label: first["git"]["repository"] || first["title"],
          candidates: group,
          last: group |> Enum.map(& &1["lastActiveAt"]) |> Enum.max()
        }
      end)
      |> Enum.sort_by(&{&1.last, &1.label}, fn {a, la}, {b, lb} ->
        if a == b, do: la <= lb, else: a >= b
      end)

    selected =
      Enum.filter(candidates, fn c ->
        c["git"] != nil and c["threadCount"] >= 3 and c["lastActiveAt"] >= cutoff
      end)

    %{repositories: repositories, other: other, selected: selected}
  end

  defp thread_id(session), do: "import:claudeAgent:#{session}"

  defp thread(session) do
    id = thread_id(session)
    StreamState.get(T3.Streams.Server.state(T3.Streams.ensure(id)), "thread")[id]
  end

  defp messages(_context, session) do
    T3.Streams.Server.state(T3.Streams.ensure(thread_id(session)))
    |> StreamState.list("message")
  end
end
