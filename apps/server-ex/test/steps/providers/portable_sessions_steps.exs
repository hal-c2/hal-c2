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

    Map.put(context, :checkouts, %{
      local => %{title => World.project(context, title)},
      other => %{title => %{id: id, root: clone}}
    })
  end

  # --- a session of each provider ------------------------------------------------------

  step "{string} runs on Codex with a native session", %{args: [title]} = context do
    run_natively(context, title, "Codex")
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
    %{session: session} = context
    title = context.moved_title
    root = context.checkouts[machine][title_project(context, machine)].root
    source = context.checkouts[local(context)][title_project(context, local(context))].root
    copy = copy_path(context, machine, session)

    assert Machines.on(context, machine, File, :exists?, [copy])
    original = File.read!(session.path)
    placed = Machines.on(context, machine, File, :read!, [copy])
    assert records(placed) == records(moved(original, source, root))
    refute placed =~ source

    id = World.thread_id(context, title)
    [pt] = Machines.on(context, machine, Machines, :entities, [id, "provider-thread"])
    assert %{"carriedSession" => %{"path" => ^copy}} = pt
    Map.put(context, :copy, copy)
  end

  step "the agent on {string} continues the carried session", %{args: [machine]} = context do
    id = World.thread_id(context, context.moved_title)
    run = Machines.on(context, machine, Machines, :send_message, [id, "where are we"])
    assert run["status"] == "completed"
    [reply | _] = replies(context, machine, id)
    # The agent forked the copy: it remembers the earlier messages, and it was sent
    # no transcript of them.
    assert reply =~ "history False"
    assert reply =~ "earlier [#{Enum.join(context.session.said, " | ")}]"
    methods = File.read!(Path.join(Machines.home(context, machine), "codex-methods.log"))
    assert methods =~ "thread/fork"
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # "~/..." on a machine: under its user home.
  defp at(context, machine, "~/" <> rest),
    do: Path.join(Machines.user_home(context, machine), rest)

  defp local(context), do: hd(for {label, :local} <- context.machines, do: label)

  defp title_project(context, machine), do: context.checkouts[machine] |> Map.keys() |> hd()

  # Runs a turn on `provider` so the thread has a native session in the provider's own
  # home, and remembers where it is and what the user said in it.
  defp run_natively(context, title, "Codex") do
    said = ["write run-1.txt"]

    for text <- said,
        do: assert(%{"status" => "completed"} = World.finish_turn(context, title, text))

    state = World.state(context, title)
    [pt] = HalC2.StreamState.list(state, "provider-thread")
    native = get_in(pt, ["nativeThreadRef", "nativeId"])
    home = Path.join(Machines.user_home(context, local(context)), ".codex")
    assert [path] = Path.wildcard(Path.join(home, "sessions/*/*/*/rollout-*-#{native}.jsonl"))

    Map.merge(context, %{
      moved_title: title,
      session: %{driver: "codex", native: native, path: path, home: home, said: said}
    })
  end

  # Where the destination keeps its copy: the same place relative to its own home.
  defp copy_path(context, machine, %{driver: "codex", path: path, home: home}),
    do:
      Path.join(
        Path.join(Machines.user_home(context, machine), ".codex"),
        Path.relative_to(path, home)
      )

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
