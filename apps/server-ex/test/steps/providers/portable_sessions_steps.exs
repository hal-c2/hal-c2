defmodule HalC2.Steps.Providers.PortableSessions do
  @moduledoc """
  Steps for `features/providers/portable-sessions.feature`.

  The machines are `HalC2.Test.Machines`: "laptop" is this VM, the others are peers.
  Every machine's fake agents keep sessions the way the real ones do, under the
  machine's own user home ("~" in the feature), so a carried session is a file that
  lands in the destination's provider home (`HalC2.PortableSessions`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.{Machines, Node}
  alias HalC2.Test.Node.World

  @repository "acme/shop"
  @history "<conversation_history>"
  @drivers %{"Claude" => "claudeAgent", "Codex" => "codex", "Pi" => "pi"}
  # Agents whose sessions are not carried: `{instance, registry agent id}`.
  @handoffs %{
    "Cursor" => {"cursor", nil},
    "Grok" => {"grok", nil},
    "a registry ACP agent" => {"acme-agent", "acme-agent"}
  }
  @selections %{
    "claudeAgent" => %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"},
    "codex" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
    "pi" => %{"instanceId" => "pi", "model" => "fake/one"}
  }

  # --- background ----------------------------------------------------------------------

  step "the project {string} is at {string} on {string} and at {string} on {string}",
       %{args: [title, here, local, there, other]} = context do
    assert Machines.machine(context, local) == :local
    root = at(context, local, here)
    File.mkdir_p!(root)

    for args <- [~w(init -q -b main), ~w(config user.email hal-c2@example.com)],
        do: World.git!(root, args)

    World.git!(root, ~w(config user.name HAL-C2))
    File.write!(Path.join(root, "README.md"), "# #{title}\n")
    World.git!(root, ~w(add README.md))
    World.git!(root, ~w(commit -q -m init))

    context = World.create_project(context, title, %{"workspaceRoot" => root})
    bare = World.github_remote(context, root, @repository)

    clone = at(context, other, there)
    File.mkdir_p!(Path.dirname(clone))
    World.git!(Path.dirname(clone), ["clone", "-q", bare, clone])
    World.git!(clone, ["remote", "set-url", "origin", "git@github.com:#{@repository}.git"])
    id = "#{World.slug(title)}-#{other}"
    Machines.on(context, other, Machines, :create_project, [id, title, clone])

    context
    |> Map.put(:bare, bare)
    |> Map.put(:checkouts, %{
      local => %{title => World.project(context, title)},
      other => %{title => %{id: id, root: clone}}
    })
  end

  # --- a session of each provider ------------------------------------------------------

  step "{string} runs on Codex with a native session", %{args: [title]} = context do
    run_natively(context, title, "Codex")
  end

  step ~r/^"(?<title>[^"]+)" runs on (?<provider>Claude|Codex|Pi|Cursor|Grok|a registry ACP agent) with a native session on "(?<machine>[^"]+)"(?: in the default home)?$/,
       %{args: [title, provider, machine]} = context do
    assert Machines.machine(context, machine) == :local

    if Map.has_key?(@handoffs, provider),
      do: run_handed_over(context, title, provider),
      else: run_natively(context, title, provider)
  end

  step ~r/^(?<provider>Claude|Codex|Pi) keeps that session in (?<where>.+)$/,
       %{args: [provider, _where]} = context do
    %{session: session} = context
    assert session.driver == @drivers[provider]
    root = context.checkouts[local(context)][title_project(context, local(context))].root

    case session.driver do
      "claudeAgent" ->
        folder = Path.join([session.home, "projects", HalC2.PortableSessions.claude_folder(root)])
        assert Path.dirname(session.path) == folder
        # Claude Code keeps a session's sub-agent transcripts and saved tool results in
        # a folder named by the session, beside its transcript.
        extra = Path.rootname(session.path)
        agent = Path.join(extra, "subagents/agent-a1b2c3.jsonl")
        result = Path.join(extra, "tool-results/toolu_01.txt")
        File.mkdir_p!(Path.dirname(agent))
        File.mkdir_p!(Path.dirname(result))
        File.write!(agent, JSON.encode!(%{"type" => "user", "cwd" => root}) <> "\n")
        File.write!(result, "a long tool output\n")

        put_in(context, [:session, :extra], [
          "subagents/agent-a1b2c3.jsonl",
          "tool-results/toolu_01.txt"
        ])

      "codex" ->
        assert Path.relative_to(session.path, session.home) =~
                 ~r"^sessions/\d{4}/\d{2}/\d{2}/rollout-[^/]+\.jsonl$"

        context

      "pi" ->
        folder = Path.join(session.home, HalC2.PortableSessions.pi_folder(root))
        assert Path.dirname(session.path) == folder
        context
    end
  end

  step ~r/^a copy of the session is placed in (?<where>.+)$/, %{args: [_where]} = context do
    placed!(context, context.move_to)
  end

  step ~r/^on the next message the agent on "(?<machine>[^"]+)" continues (?<how>.+)$/,
       %{args: [machine, _how]} = context do
    continue!(context, machine)
  end

  step "it is not sent a transcript of the conversation", context do
    refute context.reply =~ @history
    if context.session.driver != "pi", do: assert(context.reply =~ "history False")
    context
  end

  # --- recorded working directories --------------------------------------------------

  step "no session is copied to {string}", %{args: [machine]} = context do
    assert %{"sessionCarried" => false} = move_result(context)
    id = World.thread_id(context, context.moved_title)

    for pt <- Machines.on(context, machine, Machines, :entities, [id, "provider-thread"]),
        do: assert(pt["carriedSession"] == nil and pt["nativeThreadRef"] == nil)

    context
  end

  step ~r/^on the next message a new (?<provider>.+) session starts on "(?<machine>[^"]+)" with the handoff$/,
       %{args: [_provider, machine]} = context do
    %{instance: instance, selection: selection} = context.handoff
    id = World.thread_id(context, context.moved_title)
    dir = acp_dir(context, machine)

    assert %{"status" => "completed"} =
             Machines.on(context, machine, Machines, :send_message, [id, "Carry on", selection])

    [prompt | _] =
      Path.join(dir, "acp-inputs.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reverse()

    prompt = JSON.decode!(prompt)
    assert prompt =~ @history
    assert prompt =~ "write run-1.txt"
    assert prompt =~ "Carry on"

    methods =
      for line <-
            Path.join(dir, "acp-trace.jsonl") |> File.read!() |> String.split("\n", trim: true),
          %{"in" => %{"method" => method}} <- [JSON.decode!(line)],
          do: method

    assert "session/new" in methods, "#{instance} on #{machine} started no session"
    refute Enum.any?(methods, &(&1 in ~w(session/load session/resume)))
    context
  end

  step ~r/^the user was told before the move that (?<provider>.+) will get a summary of the conversation$/,
       %{args: [provider]} = context do
    name = if provider == "a registry ACP agent", do: "acme-agent", else: provider

    assert Enum.any?(
             context[:confirmation] || [],
             &(&1 =~ name and &1 =~ "will get a summary of the conversation")
           ),
           "not told: #{inspect(context[:confirmation])}"

    context
  end

  step ~r/^"(?<title>[^"]+)" runs on (?<provider>Claude|Codex|Pi) and its session records "(?<path>[^"]+)" as (?<record>.+)$/,
       %{args: [title, provider, path, _record]} = context do
    context = run_natively(context, title, provider)
    session = context.session
    assert [_ | _] = cwds = recorded_cwds(session.driver, File.read!(session.path))
    assert Enum.uniq(cwds) == [at(context, local(context), path)]
    context
  end

  step ~r/^the copy records "(?<path>[^"]+)" as (?<record>.+)$/,
       %{args: [path, _record]} = context do
    context = placed!(context, context.move_to)
    copy = Machines.on(context, context.move_to, File, :read!, [context.copy])
    assert [_ | _] = cwds = recorded_cwds(context.session.driver, copy)
    assert Enum.uniq(cwds) == [at(context, context.move_to, path)]
    context
  end

  step "the session on {string} still records {string}", %{args: [machine, path]} = context do
    assert Machines.machine(context, machine) == :local
    text = File.read!(context.session.path)
    assert text == context.session.original
    assert Enum.uniq(recorded_cwds(context.session.driver, text)) == [at(context, machine, path)]
    context
  end

  # --- agent homes -------------------------------------------------------------------

  step ~r/^the (?<provider>Claude|Codex|Pi) instance on "(?<machine>[^"]+)" keeps its sessions under (?<setting>[A-Z_]+) "(?<path>[^"]+)"$/,
       %{args: [provider, machine, setting, path]} = context do
    driver = @drivers[provider]
    dir = at(context, machine, path)
    if Machines.machine(context, machine) == :local, do: HalC2.Test.FakeAcp.services()
    Machines.on(context, machine, Machines, :put_instance_env, [driver, setting, dir])
    put_in(context, [Access.key(:homes, %{}), {machine, driver}], dir)
  end

  step "{string} runs on that instance", %{args: [title]} = context do
    run_natively(context, title, "Claude")
  end

  step "the copy is placed under {string} on {string}", %{args: [path, machine]} = context do
    context = placed!(context, machine)
    assert String.starts_with?(context.copy, at(context, machine, path) <> "/")
    context
  end

  step "the session is copied from {string} on {string}", %{args: [path, machine]} = context do
    assert String.starts_with?(context.session.path, at(context, machine, path) <> "/")
    placed!(context, context.move_to)
  end

  step "the copy is placed in the Claude home of the instance {string} runs on at {string}",
       %{args: [_title, machine]} = context do
    context = placed!(context, machine)
    home = Path.join(Machines.user_home(context, machine), ".claude")
    assert String.starts_with?(context.copy, home <> "/projects/")
    context
  end

  step "the session is still in the Claude home on {string}, unchanged",
       %{args: [machine]} = context do
    assert Machines.machine(context, machine) == :local
    assert File.read!(context.session.path) == context.session.original
    context
  end

  step "the user can still resume it with Claude Code on {string}",
       %{args: [machine]} = context do
    root = context.checkouts[machine][title_project(context, machine)].root
    fake = Path.expand("../../support/fake_claude.py", __DIR__)

    {out, status} =
      System.cmd(
        "sh",
        ["-c", ~s(exec python3 -u "$0" --resume "$1" < /dev/null), fake, context.session.native],
        cd: root,
        env: [{"FAKE_SESSIONS", "1"}, {"CLAUDE_CONFIG_DIR", context.session.home}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    context
  end

  # --- thread files --------------------------------------------------------------------

  step "the user exports {string} on {string} and imports the file on {string}",
       %{args: [title, local, other]} = context do
    assert Machines.machine(context, local) == :local
    path = Path.join(Node.tmp_dir(context.node, "exports"), "#{World.slug(title)}.hal-c2-thread")
    assert [line] = Node.run_task(Mix.Tasks.HalC2.Thread.Export, [title, path])
    assert line =~ "Exported #{title}"
    project = context.checkouts[other] |> Map.keys() |> hd()

    assert {:ok, _} =
             Machines.on(context, other, HalC2.ThreadArchive, :import_file, [
               path,
               [project: project]
             ])

    Map.merge(context, %{destination: other, thread_file: path})
  end

  step "the session is placed on {string} as a move would place it",
       %{args: [machine]} = context do
    placed!(context, machine)
  end

  step "the agent on {string} continues the carried session", %{args: [machine]} = context do
    continue!(context, machine)
  end

  # --- moving on and back ------------------------------------------------------------

  step "the cluster also has the machine {string}, with {string} at {string}",
       %{args: [machine, title, path]} = context do
    context = put_in(context, [:machines, machine], Machines.start(context, machine, :cluster))
    clone = at(context, machine, path)
    File.mkdir_p!(Path.dirname(clone))
    World.git!(Path.dirname(clone), ["clone", "-q", context.bare, clone])
    World.git!(clone, ["remote", "set-url", "origin", "git@github.com:#{@repository}.git"])
    id = "#{World.slug(title)}-#{machine}"
    Machines.on(context, machine, Machines, :create_project, [id, title, clone])
    put_in(context, [:checkouts, machine], %{title => %{id: id, root: clone}})
  end

  step ~r/^"(?<title>[^"]+)" moved (?:from "(?<from>[^"]+)" )?to "(?<to>[^"]+)" with its (?<provider>Claude|Codex) session$/,
       %{args: args} = context do
    [title, to, provider] = Enum.reject(args, &(&1 in [nil, "", local(context)]))
    context = run_natively(context, title, provider)
    move!(context, title, local(context), to)
  end

  step "the user worked in {string} on {string}", %{args: [title, machine]} = context do
    id = World.thread_id(context, title)
    selection = @selections[context.session.driver]

    run =
      Machines.on(context, machine, Machines, :send_message, [id, "work on #{machine}", selection])

    assert run["status"] == "completed"
    context
  end

  step "{string} moves back to {string}", %{args: [title, to]} = context do
    move!(context, title, context.move_to, to)
  end

  step "the agent on {string} continues the conversation including the work on {string}",
       %{args: [machine, other]} = context do
    context = continue!(context, machine)
    assert context.reply =~ "work on #{other}"
    context
  end

  step "the copies on {string} and {string} are still there, unchanged",
       %{args: [first, second]} = context do
    for machine <- [first, second] do
      {path, text} = context.copies[machine]
      assert Machines.on(context, machine, File, :read!, [path]) == text
    end

    context
  end

  step "{string} holds both its original copy of the session and the one from {string}",
       %{args: [machine, _other]} = context do
    assert Machines.machine(context, machine) == :local
    assert File.read!(context.session.path) == context.session.original
    id = World.thread_id(context, context.moved_title)
    [pt] = Machines.entities(id, "provider-thread")
    assert %{"carriedSession" => %{"path" => copy}} = pt
    assert copy != context.session.path and File.regular?(copy)
    assert Path.dirname(copy) == Path.dirname(context.session.path)
    context
  end

  step "{string} runs on Codex and {string} has a newer Codex than {string}",
       %{args: [title, newer, older]} = context do
    assert Machines.machine(context, older) == :local
    ["env" | rest] = Machines.on(context, newer, Application, :get_env, [:hal_c2, :codex_command])

    Machines.on(context, newer, Application, :put_env, [
      :hal_c2,
      :codex_command,
      ["env", "FAKE_CODEX_VERSION=0.200.0" | rest]
    ])

    run_natively(context, title, "Codex")
  end

  # --- Claude Code's file history --------------------------------------------------

  step "{string} runs on Claude and Claude Code kept file backups for its session",
       %{args: [title]} = context do
    context =
      context
      |> HalC2.Steps.Threads.MovingBetweenMachines.own_worktree(title, "feature/cart")
      |> run_natively(title, "Claude")

    backup = Path.join([context.session.home, "file-history", context.session.native, "3f2a@v1"])
    File.mkdir_p!(Path.dirname(backup))
    File.write!(backup, "# shop\n")
    Map.put(context, :backup, backup)
  end

  step "the file backups stay on {string}", %{args: [machine]} = context do
    assert Machines.machine(context, machine) == :local
    assert File.read!(context.backup) == "# shop\n"
    home = Path.join(Machines.user_home(context, context.move_to), ".claude")

    refute Machines.on(context, context.move_to, File, :exists?, [Path.join(home, "file-history")])

    context
  end

  step "rewinding {string} on {string} uses HAL-C2's checkpoints",
       %{args: [title, machine]} = context do
    context = Map.put(context, :move_to, machine)
    context = HalC2.Steps.Threads.MovingBetweenMachines.rewind_moved(context, title, 0)
    assert {:ok, _} = context.reply
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # "~/..." on a machine: under its user home.
  defp at(context, machine, "~/" <> rest),
    do: Path.join(Machines.user_home(context, machine), rest)

  defp local(context), do: hd(for {label, :local} <- context.machines, do: label)

  defp title_project(context, machine), do: context.checkouts[machine] |> Map.keys() |> hd()

  defp root(context, machine),
    do: context.checkouts[machine][title_project(context, machine)].root

  # Runs a turn on `provider` so the thread has a native session in the provider's own
  # home, and remembers where it is, what it held and what the user said in it.
  defp run_natively(context, title, provider) do
    driver = @drivers[provider]
    context = setup_provider(context, driver)

    context =
      if driver == "codex",
        do: context,
        else: World.patch_thread(context, title, %{"modelSelection" => @selections[driver]})

    said = ["write run-1.txt"]

    for text <- said,
        do: assert(%{"status" => "completed"} = World.finish_turn(context, title, text))

    state = World.state(context, title)
    [pt] = HalC2.StreamState.list(state, "provider-thread")
    native = get_in(pt, ["nativeThreadRef", "nativeId"])
    machine = local(context)
    home = home(context, machine, driver)
    cwd = World.thread(context, title)["worktreePath"] || root(context, machine)
    path = session_path(driver, home, native, cwd)
    assert File.regular?(path), "no #{provider} session at #{path}"

    original = File.read!(path)

    Map.merge(context, %{
      moved_title: title,
      copies: %{machine => {path, original}},
      session: %{
        driver: driver,
        native: native,
        path: path,
        home: home,
        said: said,
        extra: [],
        original: original
      }
    })
  end

  @doc """
  Runs a turn on an agent whose session stays where it is: the fake ACP agent is that
  agent on every machine, logging under `acp_dir/2`.
  """
  def run_handed_over(context, title, provider) do
    {instance, agent_id} = @handoffs[provider]
    HalC2.Test.FakeAcp.services()
    World.put_app_env(:acp_commands, Application.get_env(:hal_c2, :acp_commands, %{}))

    ExUnit.Callbacks.on_exit(fn ->
      HalC2.Acp.forget(instance)
      if agent_id, do: :persistent_term.erase({HalC2.Acp.Catalog, :index})
    end)

    for {label, _machine} <- context.machines,
        do:
          Machines.on(context, label, Machines, :install_acp, [
            acp_dir(context, label),
            instance,
            agent_id
          ])

    selection = %{"instanceId" => instance, "model" => "fake/one"}
    context = World.patch_thread(context, title, %{"modelSelection" => selection})
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")

    Map.merge(context, %{moved_title: title, handoff: %{instance: instance, selection: selection}})
  end

  def acp_dir(context, machine) do
    case Machines.machine(context, machine) do
      :local -> Path.join([context.node.home, "tmp", "fake-acp"])
      %{home: home} -> Path.join(home, "fake-acp")
    end
  end

  defp move_result(%{move: {:ok, %{"status" => "moved"} = result}}), do: result
  defp move_result(context), do: flunk("not moved: #{inspect(context[:move])}")

  # Pi is the scripted fake Pi on every machine; Claude and Codex are always there.
  defp setup_provider(context, "pi") do
    context = HalC2.Test.FakeAcp.install_pi(context, %{}, enabled: true)

    for {label, machine} <- context.machines,
        machine != :local,
        do:
          Machines.on(context, label, Machines, :install_pi, [Path.join(machine.home, "fake-pi")])

    context
  end

  defp setup_provider(context, _driver), do: context

  # Where `driver` keeps sessions on `machine`: an instance's custom home, else the
  # default under the machine's user home.
  defp home(context, machine, driver) do
    context[:homes][{machine, driver}] ||
      Path.join(
        Machines.user_home(context, machine),
        %{"claudeAgent" => ".claude", "codex" => ".codex", "pi" => ".pi/agent/sessions"}[driver]
      )
  end

  defp session_path("codex", home, native, _root),
    do: home |> Path.join("sessions/*/*/*/rollout-*-#{native}.jsonl") |> Path.wildcard() |> hd()

  defp session_path("claudeAgent", home, native, root),
    do:
      Path.join([home, "projects", HalC2.PortableSessions.claude_folder(root), "#{native}.jsonl"])

  defp session_path("pi", _home, native, _root), do: native

  # Where the destination keeps its copy: where its provider looks for sessions of
  # its own checkout.
  defp copy_path(context, machine, %{driver: driver, path: path} = session) do
    home = home(context, machine, driver)
    root = root(context, machine)

    case driver do
      "codex" ->
        Path.join(home, Path.relative_to(path, session.home))

      "claudeAgent" ->
        Path.join([
          home,
          "projects",
          HalC2.PortableSessions.claude_folder(root),
          Path.basename(path)
        ])

      "pi" ->
        Path.join([home, HalC2.PortableSessions.pi_folder(root), Path.basename(path)])
    end
  end

  # The copy on `machine` is where its provider looks, with each recorded working
  # directory moved to its checkout, beside the session's other files; the thread's
  # provider thread there carries it.
  defp placed!(context, machine) do
    %{session: session} = context
    copy = copy_path(context, machine, session)
    assert Machines.on(context, machine, File, :exists?, [copy]), "no copy at #{copy}"
    placed = Machines.on(context, machine, File, :read!, [copy])
    source = root(context, local(context))
    assert records(placed) == records(moved(session.original, source, root(context, machine)))
    refute placed =~ ~s("#{source}")

    for name <- session.extra do
      path = Path.join(Path.rootname(copy), name)
      assert Machines.on(context, machine, File, :exists?, [path]), "no #{name} beside the copy"
    end

    id = World.thread_id(context, context.moved_title)
    [pt] = Machines.on(context, machine, Machines, :entities, [id, "provider-thread"])
    assert %{"carriedSession" => %{"path" => ^copy}} = pt
    Map.put(context, :copy, copy)
  end

  # Asks the agent on `machine` where it is: it branched a new session from the
  # carried copy, so it remembers the earlier messages without being sent them.
  defp continue!(context, machine) do
    id = World.thread_id(context, context.moved_title)
    driver = context.session.driver

    run =
      Machines.on(context, machine, Machines, :send_message, [
        id,
        "where are we",
        @selections[driver]
      ])

    assert run["status"] == "completed"
    [reply | _] = replies(context, machine, id)
    refute reply =~ @history

    for text <- context.session.said, do: assert(reply =~ text)
    root = root(context, machine)
    home = Machines.home(context, machine)

    case driver do
      "codex" ->
        assert reply =~ "history False"
        [fork | _] = codex_requests(context, machine, "thread/fork") |> Enum.reverse()
        assert fork["cwd"] == root

      "claudeAgent" ->
        assert reply =~ "fork True history False"

        argv =
          home |> Path.join("claude-argv.jsonl") |> File.read!() |> String.split("\n", trim: true)

        argv = argv |> List.last() |> JSON.decode!()
        assert "--fork-session" in argv
        [copy] = for {"--resume", path} <- Enum.zip(argv, tl(argv)), do: path
        assert String.ends_with?(copy, ".jsonl")

      "pi" ->
        assert [start | _] =
                 for(
                   %{"start" => %{"argv" => argv} = start} <- pi_log(context, machine),
                   "--fork" in argv,
                   do: start
                 )
                 |> Enum.reverse()

        assert start["cwd"] == root
    end

    Map.put(context, :reply, reply)
  end

  # Moves the thread from where it lives, confirming what stays behind; remembers the
  # copy the destination got and what it holds.
  defp move!(context, title, from, to) do
    id = World.thread_id(context, title)

    assert {:ok, %{"status" => "moved", "sessionCarried" => true}} =
             Machines.on(context, from, HalC2.ThreadMove, :move, [id, to, [confirmed: true]])

    [pt] = Machines.on(context, to, Machines, :entities, [id, "provider-thread"])
    copy = pt["carriedSession"]["path"]
    text = Machines.on(context, to, File, :read!, [copy])

    context
    |> Map.put(:move_to, to)
    |> Map.update(:copies, %{to => {copy, text}}, &Map.put(&1, to, {copy, text}))
  end

  defp codex_requests(context, machine, method) do
    path = Path.join(Machines.home(context, machine), "codex-requests.log")

    for line <- path |> File.read!() |> String.split("\n", trim: true),
        %{"method" => ^method, "params" => params} <- [JSON.decode!(line)],
        do: params
  end

  defp pi_log(context, machine) do
    path =
      case Machines.machine(context, machine) do
        :local -> Path.join(HalC2.Test.FakeAcp.fake(context, "pi").dir, "log.jsonl")
        %{home: home} -> Path.join([home, "fake-pi", "log.jsonl"])
      end

    for line <- path |> File.read!() |> String.split("\n", trim: true), do: JSON.decode!(line)
  end

  # The working directories a session records: every Claude entry's, Codex's session
  # and turn contexts', Pi's header's.
  defp recorded_cwds(driver, text) do
    for record <- records(text), cwd = recorded_cwd(driver, record), do: cwd
  end

  defp recorded_cwd("claudeAgent", record), do: record["cwd"]

  defp recorded_cwd("codex", %{"type" => type, "payload" => payload})
       when type in ~w(session_meta turn_context),
       do: payload["cwd"]

  defp recorded_cwd("pi", %{"type" => "session", "cwd" => cwd}), do: cwd
  defp recorded_cwd(_driver, _record), do: nil

  # The session as it should read on the destination: each recorded working directory
  # moved from `from` to `to`.
  defp moved(text, from, to), do: String.replace(text, ~s("#{from}"), ~s("#{to}"))

  defp records(text),
    do: for(line <- String.split(text, "\n", trim: true), do: JSON.decode!(line))

  defp replies(context, machine, id) do
    Machines.on(context, machine, Machines, :entities, [id, "message"])
    |> Enum.filter(&(&1["role"] == "assistant"))
    |> Enum.sort_by(& &1["createdAt"], :desc)
    |> Enum.map(& &1["text"])
  end
end
