defmodule HalC2.Steps.Threads.MovingBetweenMachines do
  @moduledoc """
  Steps for `features/threads/moving-between-machines.feature`.

  The first machine of the Background ("laptop") is the scenario's node in this VM;
  the others are peers running the whole node (`HalC2.Test.Machines`). Each machine's
  "shop" is its own clone of one repository whose origin names GitHub. The thread
  file is `HalC2.ThreadArchive`'s: exports run `mix hal_c2.thread.export` here, and
  imports call `HalC2.ThreadArchive.import_file/2` (the task's body) on the machine.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.{Machines, Node}
  alias HalC2.Test.Node.World

  @repository "acme/shop"
  @history_start "<conversation_history>"

  # --- background ----------------------------------------------------------------------

  step "a cluster of the machines {string} and {string}", %{args: [local, other]} = context do
    Machines.cluster(context, local, [other])
  end

  step "the project {string} on each machine is a checkout of the same repository",
       %{args: [title]} = context do
    [local] = for {label, :local} <- context.machines, do: label
    context = World.create_project(context, title)
    root = World.project(context, title).root
    bare = World.github_remote(context, root, @repository)

    context =
      put_in(context, [Access.key(:checkouts, %{}), local], %{
        title => World.project(context, title)
      })

    context.machines
    |> Enum.reject(&(elem(&1, 1) == :local))
    |> Enum.reduce(Map.put(context, :bare, bare), fn {label, _}, context ->
      clone(context, label, title, "#{World.slug(title)}-#{label}")
    end)
  end

  step "the thread {string} lives on {string} in {string}",
       %{args: [title, machine, project]} = context do
    assert Machines.machine(context, machine) == :local
    World.create_thread(context, title, project)
  end

  # --- the destination's projects ------------------------------------------------------

  step "{string} instead has one project that is a checkout of the same repository",
       %{args: [machine]} = context do
    assert [_] = checkouts(context, machine)
    context
  end

  step "{string} instead has two projects that are checkouts of the same repository",
       %{args: [machine]} = context do
    clone(context, machine, "shop copy", "shop-copy-#{machine}")
  end

  step "{string} instead has no checkout of the repository", %{args: [machine]} = context do
    for %{id: id} <- checkouts(context, machine),
        do: Machines.on(context, machine, Machines, :delete_project, [id])

    root = World.git_repo(context, "scratch-#{machine}")

    Machines.on(context, machine, Machines, :create_project, [
      "scratch-#{machine}",
      "scratch",
      root
    ])

    put_in(context, [:checkouts, machine], %{"scratch" => %{id: "scratch-#{machine}", root: root}})
  end

  # --- export and import ---------------------------------------------------------------

  step "the user exports {string} on {string} to the file {string}",
       %{args: [title, machine, file]} = context do
    assert Machines.machine(context, machine) == :local
    context = furnish(context, title)
    before = World.state(context, title)
    context = export(context, title, file)
    Map.put(context, :before, before)
  end

  step "the file holds the thread with its history, attachments, terminal scrollback, checkpoints and the agent's session",
       context do
    archive = context.thread_file |> File.read!() |> JSON.decode!()
    assert archive["format"] == "hal-c2-thread-export" and archive["version"] == 2
    kinds = Enum.frequencies(for [kind, _, _] <- archive["entities"], do: kind)
    assert kinds["thread"] == 1
    assert kinds["message"] >= 3
    assert kinds["run"] >= 1
    assert [%{"fileName" => _}] = archive["attachments"]
    assert [%{"fileName" => "term-1"}] = archive["terminalLogs"]
    assert [_ | _] = archive["checkpoints"]["refs"]
    assert %{"driver" => _, "files" => [_ | _]} = archive["session"]
    context
  end

  step "{string} stays on {string} unchanged", %{args: [title, machine]} = context do
    assert Machines.machine(context, machine) == :local
    after_export = World.state(context, title)
    assert after_export.seq == context.before.seq
    assert after_export.entities == context.before.entities
    context
  end

  step "{string} has left the cluster", %{args: [machine]} = context do
    Machines.leave(context, machine)
  end

  step "the file {string} was exported from {string}", %{args: [file, machine]} = context do
    assert Machines.machine(context, machine) == :local
    context |> furnish("Alpha") |> export("Alpha", file)
  end

  step "the user imports the file on {string} into the project {string}",
       %{args: [machine, project]} = context do
    import_file(context, machine, project: project)
  end

  step "{string} is listed under {string} in {string} with everything a move carries",
       %{args: [title, machine, project]} = context do
    assert {:ok, _} = context.imported
    id = World.thread_id(context, title)
    %{id: project_id, root: root} = checkout(context, machine, project)

    assert %{"projectId" => ^project_id, "title" => ^title} = remote_row(context, machine, id)
    carried!(context, machine, id, root)
  end

  step "the user imports {string} on {string} without naming a project",
       %{args: [file, machine]} = context do
    context
    |> ensure_file(file)
    |> import_file(machine, [])
  end

  step "{string} is imported into that project", %{args: [title]} = context do
    assert {:ok, %{project: project}} = context.imported
    [%{id: ^project}] = checkouts(context, context.import_machine)
    assert remote_row(context, context.import_machine, World.thread_id(context, title))
    context
  end

  step "the import is refused and asks the user to name one", context do
    assert {:error, message} = context.imported
    assert message =~ "Several projects on #{context.import_machine}"
    assert message =~ "Name the one to import it into."
    refute_imported(context)
  end

  step "the import is refused and asks the user to name a project", context do
    assert {:error, message} = context.imported
    assert message =~ "No project on #{context.import_machine}"
    assert message =~ "Name a project to import it into."
    refute_imported(context)
  end

  step "{string} was imported on {string}", %{args: [file, machine]} = context do
    context = context |> ensure_file(file) |> import_file(machine, [])
    assert {:ok, _} = context.imported
    context
  end

  step "the user imports it on {string} again", %{args: [machine]} = context do
    import_file(context, machine, [])
  end

  step "the user is told {string} is already on {string}",
       %{args: [title, machine]} = context do
    assert context.imported == {:error, "#{title} is already on #{machine}."}
    context
  end

  step "there is still one {string}", %{args: [title]} = context do
    rows = Machines.on(context, context.import_machine, Machines, :rows, [])
    assert length(for({"thread", %{"title" => ^title}} <- rows, do: 1)) == 1
    context
  end

  step "{string} was exported by a newer HAL-C2 in a format {string} does not know",
       %{args: [file, _machine]} = context do
    context = export(context, "Alpha", file)
    archive = context.thread_file |> File.read!() |> JSON.decode!()
    File.write!(context.thread_file, JSON.encode!(%{archive | "version" => 3}))
    context
  end

  step "the user imports it on {string}", %{args: [machine]} = context do
    import_file(context, machine, [])
  end

  step "the user is told the file needs a newer HAL-C2", context do
    assert {:error, message} = context.imported
    assert message =~ "needs a newer HAL-C2"
    context
  end

  step "nothing is imported", context do
    refute_imported(context)
  end

  step "one of the attachments in {string} does not match its checksum",
       %{args: [file]} = context do
    context = context |> furnish("Alpha") |> export("Alpha", file)
    archive = context.thread_file |> File.read!() |> JSON.decode!()
    [attachment | rest] = archive["attachments"]
    damaged = %{attachment | "dataBase64" => Base.encode64("not the image")}
    File.write!(context.thread_file, JSON.encode!(%{archive | "attachments" => [damaged | rest]}))
    context
  end

  step "the user is told the file is damaged", context do
    assert {:error, message} = context.imported
    assert message =~ "The file is damaged"
    assert message =~ "Nothing was imported."
    context
  end

  step "a thread file exported by the previous server", context do
    root = World.project(context, "shop").root
    id = "th-legacy-#{System.unique_integer([:positive])}"
    at = "2026-09-01T00:00:00.000Z"
    image = "#{id}-img"

    thread =
      Map.merge(thread_fields(id, "Legacy", "shop"), %{"createdAt" => at, "updatedAt" => at})

    events = [
      v1_event(id, "thread.created", thread, at),
      v1_event(id, "run.updated", run(id, "run-legacy", at), at),
      v1_event(
        id,
        "message.updated",
        message(id, "m1", "user", "Can you fix the cart?", at, [image]),
        at
      ),
      v1_event(
        id,
        "message.updated",
        message(id, "m2", "assistant", "The cart is fixed.", at, []),
        at
      ),
      v1_event(
        id,
        "provider-thread.updated",
        %{
          "id" => "pt-legacy",
          "appThreadId" => id,
          "providerInstanceId" => "codex",
          "driver" => "codex",
          "status" => "idle",
          "nativeThreadRef" => %{
            "driver" => "codex",
            "nativeId" => "thr-node",
            "strength" => "strong"
          },
          "firstRunOrdinal" => 1
        },
        at
      )
    ]

    archive = %{
      "format" => "hal-c2-thread-export",
      "version" => 1,
      "exportedAt" => at,
      "thread" => %{
        "id" => id,
        "title" => "Legacy",
        "sourceProjectId" => "shop",
        "sourceWorkspaceRoot" => root,
        "orchestrationVersion" => 2
      },
      "events" => events,
      "projections" => %{},
      "attachments" => [v1_file(image <> ".png", <<0x89, "PNG legacy">>)],
      "terminalLogs" => [
        v1_file("terminal_#{Base.url_encode64(id, padding: false)}.log", "$ make\nbuilt\n")
      ]
    }

    file = Path.join(Node.tmp_dir(context.node, "legacy"), "legacy.hal-c2-thread")
    File.write!(file, JSON.encode!(archive))

    context
    |> Map.put(:thread_file, file)
    |> put_in([:threads, "Legacy"], id)
    |> Map.put(:legacy, %{id: id, image: image})
  end

  step "the thread is listed with its history, attachments and terminal scrollback", context do
    assert {:ok, _} = context.imported
    %{id: id, image: image} = context.legacy
    machine = context.import_machine
    assert %{"title" => "Legacy"} = remote_row(context, machine, id)

    texts =
      for m <- Machines.on(context, machine, Machines, :entities, [id, "message"]), do: m["text"]

    assert Enum.sort(texts) == ["Can you fix the cart?", "The cart is fixed."]

    path = Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => image}])
    assert Machines.on(context, machine, File, :read!, [path]) == <<0x89, "PNG legacy">>

    assert Machines.on(context, machine, HalC2.Terminal, :saved_scrollback, [id]) == [
             {"term-1", "$ make\nbuilt\n"}
           ]

    context
  end

  step "its next message hands the conversation over to the agent", context do
    %{id: id} = context.legacy
    machine = context.import_machine

    for pt <- Machines.on(context, machine, Machines, :entities, [id, "provider-thread"]),
        do: assert(pt["nativeThreadRef"] == nil)

    prompt = remote_turn(context, machine, id, "Where were we?")
    assert String.starts_with?(prompt, @history_start)
    assert prompt =~ "User: Can you fix the cart?"
    assert prompt =~ "Assistant: The cart is fixed."
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  # A clone of the scenario's repository on `machine`, added there as a project.
  defp clone(context, machine, title, id) do
    root = Path.join(Node.tmp_dir(context.node, "#{machine}-checkouts"), World.slug(title))
    World.git!(Path.dirname(root), ["clone", "-q", context.bare, root])
    World.git!(root, ["remote", "set-url", "origin", "git@github.com:#{@repository}.git"])
    Machines.on(context, machine, Machines, :create_project, [id, title, root])

    put_in(context, [Access.key(:checkouts, %{}), Access.key(machine, %{}), title], %{
      id: id,
      root: root
    })
  end

  defp checkouts(context, machine),
    do: context.checkouts |> Map.get(machine, %{}) |> Map.values()

  defp checkout(context, machine, title),
    do: get_in(context, [:checkouts, machine, title]) || flunk("no #{title} on #{machine}")

  # Gives a thread what a move carries: a finished run with its checkpoint, a message
  # with an image, and a terminal's scrollback.
  defp furnish(%{furnished: true} = context, _title), do: context

  defp furnish(context, title) do
    id = World.thread_id(context, title)
    assert %{"status" => "completed"} = World.finish_turn(context, title, "write run-1.txt")

    image = "#{id |> String.replace(~r/[^a-z0-9_-]/i, "-")}-cart"
    File.mkdir_p!(HalC2.Attachments.dir())
    File.write!(Path.join(HalC2.Attachments.dir(), image <> ".png"), <<0x89, "PNG cart">>)

    context =
      World.add_message(context, title, "user", "Here is the cart", nil, %{
        "attachments" => [
          %{
            "type" => "image",
            "id" => image,
            "name" => "cart.png",
            "mimeType" => "image/png",
            "sizeBytes" => 12
          }
        ]
      })

    HalC2.Terminal.put_scrollback(id, "term-1", "$ npm run dev\nready on :3000\n")
    Map.merge(context, %{furnished: true, image: image})
  end

  defp export(context, title, file) do
    path = Path.join(Node.tmp_dir(context.node, "exports"), file)
    assert [line] = Node.run_task(Mix.Tasks.HalC2.Thread.Export, [title, path])
    assert line =~ "Exported #{title} to #{path}"
    Map.put(context, :thread_file, path)
  end

  defp ensure_file(%{thread_file: _} = context, _name), do: context
  defp ensure_file(context, name), do: context |> furnish("Alpha") |> export("Alpha", name)

  defp import_file(context, machine, opts) do
    result =
      Machines.on(context, machine, HalC2.ThreadArchive, :import_file, [context.thread_file, opts])

    Map.merge(context, %{imported: result, import_machine: machine})
  end

  defp refute_imported(context) do
    machine = context.import_machine
    id = (context[:legacy] || %{})[:id] || World.thread_id(context, "Alpha")
    rows = Machines.on(context, machine, Machines, :rows, [])
    refute Enum.any?(rows, fn {_, row} -> row["id"] == id end)

    streams =
      Machines.on(context, machine, HalC2.Store, :list_streams, [
        Machines.on(context, machine, HalC2.Store, :path, [])
      ])

    refute Enum.any?(streams, &(&1.id == id))
    assert Machines.on(context, machine, HalC2.Terminal, :saved_scrollback, [id]) == []

    if image = context[:image],
      do:
        assert(Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => image}]) == nil)

    context
  end

  defp remote_row(context, machine, id) do
    Machines.on(context, machine, Machines, :rows, [])
    |> Enum.find_value(fn
      {"thread", %{"id" => ^id} = row} -> row
      _ -> nil
    end)
  end

  # What a move carries arrived on `machine`: history, attachments, scrollback and
  # checkpoints in its checkout at `root`.
  defp carried!(context, machine, id, root) do
    here = World.state(context, "Alpha")
    messages = for m <- HalC2.StreamState.list(here, "message"), do: {m["id"], m["text"]}

    there =
      for m <- Machines.on(context, machine, Machines, :entities, [id, "message"]),
          do: {m["id"], m["text"]}

    assert Enum.sort(there) == Enum.sort(messages)

    runs = for r <- HalC2.StreamState.list(here, "run"), do: {r["id"], r["status"]}

    there_runs =
      for r <- Machines.on(context, machine, Machines, :entities, [id, "run"]),
          do: {r["id"], r["status"]}

    assert Enum.sort(there_runs) == Enum.sort(runs)

    path = Machines.on(context, machine, HalC2.Attachments, :path, [%{"id" => context.image}])
    assert Machines.on(context, machine, File, :read!, [path]) == <<0x89, "PNG cart">>

    assert Machines.on(context, machine, HalC2.Terminal, :saved_scrollback, [id]) ==
             HalC2.Terminal.saved_scrollback(id)

    checkpoints = Machines.on(context, machine, Machines, :entities, [id, "checkpoint"])
    assert [_ | _] = ready = Enum.filter(checkpoints, &(&1["status"] == "ready"))
    for c <- ready, do: assert(HalC2.Checkpoint.exists?(root, c["ref"]))
    context
  end

  # Sends a message to a thread on a cluster member and returns what its agent was given.
  defp remote_turn(context, machine, id, text) do
    node = Machines.node_of(context, machine)
    :ok = :erpc.call(node, HalC2.Streams, :subscribe, [id, self(), nil])

    {:ok, _} =
      :erpc.call(node, HalC2.Orchestration, :dispatch, [
        %{
          "type" => "message.dispatch",
          "commandId" => "cmd-#{System.unique_integer([:positive])}",
          "threadId" => id,
          "messageId" => "msg-#{System.unique_integer([:positive])}",
          "text" => text,
          "attachments" => [],
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
          "dispatchMode" => %{"type" => "start_immediately"},
          "createdBy" => "user",
          "creationSource" => "web"
        }
      ])

    await_remote_run(context, machine, id)
    inputs = Path.join(Machines.home(context, machine), "codex-inputs.jsonl")
    [input | _] = inputs |> File.read!() |> String.split("\n", trim: true) |> Enum.reverse()
    input |> JSON.decode!() |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  defp await_remote_run(context, machine, id) do
    receive do
      {:hal_c2_stream, ^id, _} ->
        runs = Machines.on(context, machine, Machines, :entities, [id, "run"])

        if Enum.any?(runs, &(&1["status"] in ~w(completed failed interrupted))),
          do: :ok,
          else: await_remote_run(context, machine, id)
    after
      15_000 -> flunk("the run in #{id} on #{machine} never finished")
    end
  end

  defp thread_fields(id, title, project) do
    %{
      "id" => id,
      "projectId" => project,
      "title" => title,
      "providerInstanceId" => "codex",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "runtimeMode" => "full-access",
      "interactionMode" => "default",
      "branch" => nil,
      "worktreePath" => nil
    }
  end

  defp run(thread, id, at) do
    %{
      "id" => id,
      "threadId" => thread,
      "ordinal" => 1,
      "providerInstanceId" => "codex",
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "providerThreadId" => "pt-legacy",
      "userMessageId" => "m1",
      "status" => "completed",
      "requestedAt" => at,
      "startedAt" => at,
      "completedAt" => at
    }
  end

  defp message(thread, id, role, text, at, images) do
    %{
      "id" => id,
      "threadId" => thread,
      "runId" => "run-legacy",
      "role" => role,
      "text" => text,
      "createdBy" => if(role == "user", do: "user", else: "agent"),
      "attachments" =>
        for(
          image <- images,
          do: %{"type" => "image", "id" => image, "name" => "cart.png", "mimeType" => "image/png"}
        ),
      "streaming" => false,
      "createdAt" => at,
      "updatedAt" => at
    }
  end

  defp v1_event(stream, type, payload, at) do
    %{
      "eventId" => "ev-#{System.unique_integer([:positive])}",
      "aggregateKind" => "thread",
      "streamId" => stream,
      "streamVersion" => 0,
      "eventType" => type,
      "occurredAt" => at,
      "commandId" => nil,
      "causationEventId" => nil,
      "correlationId" => nil,
      "actorKind" => "server",
      "payloadJson" => JSON.encode!(payload),
      "metadataJson" => "{}",
      "applicationEventVersion" => 2
    }
  end

  defp v1_file(name, data),
    do: %{
      "fileName" => name,
      "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
      "dataBase64" => Base.encode64(data)
    }
end
