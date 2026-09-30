defmodule HalC2.Steps.Connections.Links do
  @moduledoc """
  Steps for `features/connections/links.feature`.

  "beast" is a peer running the whole application on its own, driven over stdio, so
  it never joins this VM's cluster: the scenario's node reaches it only through a
  link. Its terminals run `/bin/sh` in a folder under its home.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.{Machines, Node, WsClient}
  alias HalC2.Test.Node.{Terminal, World}

  step "another node {string} outside the node's cluster", %{args: [label]} = context do
    Terminal.put_env("SHELL", "/bin/sh")
    Node.ensure({Registry, keys: :unique, name: HalC2.Links.Registry})
    Node.ensure({DynamicSupervisor, name: HalC2.Links.Supervisor, strategy: :one_for_one})
    Node.ensure(HalC2.Links)

    machine = Machines.start(context, label, :alone)
    context = put_in(context, [Access.key(:machines, %{}), label], machine)
    environment = Machines.on(context, label, HalC2.Environment, :id, [])
    put_in(context, [:machines, label], Map.put(machine, :environment, environment))
  end

  # --- linking --------------------------------------------------------------------

  step "the user runs the link task with a pairing link from {string}",
       %{args: [label]} = context do
    output = Node.run_task(Mix.Tasks.HalC2.Link, [pairing_link(context, label)])
    assert ["Linked " <> _] = output
    context
  end

  step "a pairing link from {string} that was already used", %{args: [label]} = context do
    url = pairing_link(context, label)
    %{"token" => token} = URI.decode_query(URI.parse(url).fragment)
    port = URI.parse(url).port
    assert {200, _} = Node.exchange(%{port: port}, token)
    Map.put(context, :pairing_link, url)
  end

  step "the user links the node with it", context do
    Map.put(context, :link_result, Node.run_task(Mix.Tasks.HalC2.Link, [context.pairing_link]))
  end

  step "linking is refused because the pairing link is invalid or expired", context do
    assert context.link_result == {:error, "the pairing link is invalid or expired"}
    context
  end

  step "the node is linked to {string}", %{args: [label]} = context do
    assert {:ok, _} = HalC2.Links.add(pairing_link(context, label))
    await_link(environment(context, label), true)
    context
  end

  step "the node lists {string} as a linked environment that is online",
       %{args: [label]} = context do
    link = await_link(environment(context, label), true)
    assert link["environment"]["label"] == label
    assert link["origin"] == Machines.on(context, label, HalC2.Web, :base_url, [])
    context
  end

  step "the node's clients see {string} among its links", %{args: [label]} = context do
    id = environment(context, label)
    client = context |> World.client() |> Node.sub(1, %{"type" => "shell"})
    {frame, client} = Node.await(client, &(&1["t"] == "shell" and &1["id"] == 1), 5_000)
    assert [%{"environment" => %{"environmentId" => ^id}, "online" => true}] = frame["links"]
    World.put_client(context, client)
  end

  step "the user removes the link to {string}", %{args: [label]} = context do
    id = environment(context, label)
    assert ["Removed the link to " <> ^id] = Node.run_task(Mix.Tasks.HalC2.Link, ["--remove", id])
    context
  end

  step "the node has no links", context do
    assert HalC2.Links.list() == []
    assert Node.run_task(Mix.Tasks.HalC2.Link, []) == ["No links."]
    context
  end

  step "a client of the node calling {string} is told the environment is unknown",
       %{args: [label]} = context do
    {reply, context} =
      call(context, label, "terminal.write", %{
        "threadId" => "th-link",
        "terminalId" => "term-1",
        "data" => "\n"
      })

    assert {:error, "unknown environment", _} = reply
    context
  end

  # --- failures -------------------------------------------------------------------

  step "{string} revokes every paired client", %{args: [label]} = context do
    Machines.on(context, label, HalC2.Auth, :revoke_other_clients, [nil])
    context
  end

  step "{string} stops", %{args: [label]} = context do
    Machines.stop(Machines.machine(context, label))
    context
  end

  step "the node lists {string} as a linked environment whose access is refused",
       %{args: [label]} = context do
    await_link(environment(context, label), &(&1["problem"] == "refused" and !&1["online"]))
    context
  end

  step "the node lists {string} as a linked environment that is unreachable",
       %{args: [label]} = context do
    await_link(environment(context, label), &(&1["problem"] == "unreachable" and !&1["online"]))
    context
  end

  step "a client of the node calling {string} is told to pair it again",
       %{args: [label]} = context do
    {reply, context} =
      call(context, label, "terminal.write", %{
        "threadId" => "th-link",
        "terminalId" => "term-1",
        "data" => "\n"
      })

    assert {:error, message, _} = reply
    assert message =~ "pair it again"
    context
  end

  # --- terminals through the link ---------------------------------------------------

  step "a client of the node attaches a terminal on {string}", %{args: [label]} = context do
    input = %{"threadId" => "th-link", "terminalId" => "term-1", "cwd" => cwd(context, label)}
    id = System.unique_integer([:positive])

    shape = %{
      "type" => "terminal",
      "environment" => environment(context, label),
      "input" => input
    }

    client = context |> World.client() |> Node.sub(id, shape)
    {frame, client} = Node.await(client, &(&1["id"] == id), 10_000)
    assert %{"t" => "terminal", "event" => %{"type" => "snapshot"}} = frame

    context
    |> World.put_client(client)
    |> Map.update(:terminal_subs, %{"default" => id}, &Map.put(&1, "default", id))
    |> Map.put(:link_terminal, {label, input})
  end

  step "it types {string} and a return in that terminal", %{args: [text]} = context do
    {label, input} = context.link_terminal
    payload = Map.take(input, ["threadId", "terminalId"]) |> Map.put("data", text <> "\n")
    {reply, context} = call(context, label, "terminal.write", payload)
    assert {:ok, _} = reply
    context
  end

  step "it receives {string} from the terminal on {string}", %{args: [text, _label]} = context do
    {_output, _events, context} =
      Terminal.await_output(context, "default", ~r/(^|\r)#{text}\r\n/m, 10_000)

    context
  end

  step "a client of the node follows the terminals on {string}", %{args: [label]} = context do
    client = Node.connect(context.node)
    shape = %{"type" => "terminals", "environment" => environment(context, label)}
    client = Node.sub(client, 2, shape)
    {frame, client} = Node.await(client, &(&1["id"] == 2), 10_000)
    assert %{"t" => "terminals"} = frame
    World.put_client(context, "follower", client)
  end

  step "the client following them sees the new terminal", context do
    {_label, input} = context.link_terminal

    {_frame, client} =
      Node.await(
        World.client(context, "follower"),
        &(&1["id"] == 2 and &1["t"] == "terminals" and
            match?(%{"type" => "upsert", "terminal" => %{"threadId" => "th-link"}}, &1["event"]) and
            &1["event"]["terminal"]["terminalId"] == input["terminalId"]),
        10_000
      )

    World.put_client(context, "follower", client)
  end

  # --- streams through the link -----------------------------------------------------

  step "a thread that lives on {string}", %{args: [label]} = context do
    thread = %{"s" => %{"id" => "th-beast", "title" => "On #{label}"}}
    commit(context, label, [{"thread", "th-beast", thread}])
    Map.put(context, :link_stream, label)
  end

  step "a client of the node follows that thread by its environment", context do
    {frames, _offset, client} = follow_linked(World.client(context), context, 3, nil)
    context |> World.put_client(client) |> Map.put(:link_frames, frames)
  end

  step "it receives the thread's snapshot and goes live", context do
    assert [%{"t" => "snapshot", "part" => 0, "done" => true} = snapshot] = context.link_frames
    assert [["thread", "th-beast", %{"title" => "On beast"}]] = snapshot["rows"]
    context
  end

  step "a change to the thread on {string} reaches the client", %{args: [label]} = context do
    seq = commit(context, label, [{"turn-item", "i1", %{"s" => %{"text" => "from beast"}}}])
    events = &(&1["t"] == "events" and &1["id"] == 3)
    {frame, client} = Node.await(World.client(context), events, 10_000)
    assert [[^seq, "turn-item", "i1", %{"s" => %{"text" => "from beast"}}, _at]] = frame["events"]
    World.put_client(context, client)
  end

  step "a client of the node followed that thread by its environment and stopped", context do
    {_frames, offset, client} = follow_linked(World.client(context), context, 3, nil)
    client = WsClient.send_json(client, %{"t" => "unsub", "id" => 3})
    context |> World.put_client(client) |> Map.put(:link_offset, offset)
  end

  step "the thread on {string} changed since", %{args: [label]} = context do
    seq = commit(context, label, [{"turn-item", "i2", %{"s" => %{"text" => "missed"}}}])
    Map.put(context, :missed, seq)
  end

  step "the client follows that thread again from the offset it last saw", context do
    {frames, _offset, client} =
      follow_linked(World.client(context), context, 4, context.link_offset)

    context |> World.put_client(client) |> Map.put(:link_frames, frames)
  end

  step "it receives only the change it missed, then goes live", context do
    seq = context.missed

    assert [%{"t" => "events", "events" => [[^seq, "turn-item", "i2", %{"s" => _}, _at]]}] =
             context.link_frames

    context
  end

  # --- linked rows in the shell -------------------------------------------------------

  step "a client of the node asks for the shell with its links' rows", context do
    {model, client} = shell_with_rows(World.client(context))
    context |> World.put_client(client) |> Map.put(:linked, model)
  end

  # Until the link's first rows are in: the thread when there is one, else a node.
  step "a client of the node follows the shell with its links' rows", context do
    {model, client} = shell_with_rows(World.client(context))

    done? =
      if context[:link_stream],
        do: &thread_listed?(&1, context),
        else: &Enum.any?(&1.links, fn {_, l} -> l.nodes != %{} end)

    {model, client} = await_linked(client, model, done?)
    context |> World.put_client(client) |> Map.put(:linked, model)
  end

  step "the thread is listed under the link to {string}", context do
    {model, client} =
      await_linked(World.client(context), context.linked, &thread_listed?(&1, context))

    context |> World.put_client(client) |> Map.put(:linked, model)
  end

  step "the node of {string} is listed online under its link", %{args: [label]} = context do
    id = environment(context, label)

    listed? = fn model ->
      Enum.any?(
        model.links[id].nodes,
        fn {_, n} -> n["online"] and n["environment"]["environmentId"] == id end
      )
    end

    {model, client} = await_linked(World.client(context), context.linked, listed?)
    context |> World.put_client(client) |> Map.put(:linked, model)
  end

  step "none of the rows of {string} are among the cluster's own", %{args: [label]} = context do
    id = environment(context, label)
    refute Enum.any?(context.linked.snapshot["rows"], &match?([_, "th-beast", _, _], &1))

    refute Enum.any?(
             context.linked.snapshot["nodes"],
             &(&1["environment"]["environmentId"] == id)
           )

    refute Enum.any?(HalC2.Shell.rows(), &match?({{_, "th-beast"}, _}, &1))
    context
  end

  step "the thread on {string} is renamed to {string}", %{args: [label, title]} = context do
    commit(context, label, [{"thread", "th-beast", %{"s" => %{"title" => title}}}])
    Map.put(context, :renamed, title)
  end

  step "the client receives only that thread's new row under the link to {string}",
       %{args: [label]} = context do
    id = environment(context, label)
    title = context.renamed

    {frame, client} =
      Node.await(
        World.client(context),
        &(&1["t"] == "shell.linkRows" and &1["link"] == id),
        10_000
      )

    assert [["th-beast", "thread", %{"title" => ^title}]] = frame["rows"]
    World.put_client(context, client)
  end

  step "{string} becomes unreachable", %{args: [label]} = context do
    :ok = Machines.stop(Machines.machine(context, label))
    context
  end

  step "the client is told the node of {string} is offline under its link",
       %{args: [label]} = context do
    id = environment(context, label)
    [node] = for {name, n} <- context.linked.links[id].nodes, n["online"], do: name

    {_frame, client} =
      Node.await(
        World.client(context),
        &(&1["t"] == "shell.linkNode" and &1["link"] == id and &1["node"] == node and
            &1["online"] == false),
        10_000
      )

    World.put_client(context, client)
  end

  step "a client of the node that asks for the shell with its links' rows sees the thread under the link to {string}, offline",
       %{args: [label]} = context do
    id = environment(context, label)
    {model, _client} = shell_with_rows(Node.connect(context.node))
    link = model.links[id]
    assert link.online == false
    assert link.nodes != %{} and Enum.all?(link.nodes, fn {_, n} -> n["online"] == false end)
    assert thread_listed?(model, context)
    context
  end

  step "the client's links no longer include {string}", %{args: [label]} = context do
    id = environment(context, label)

    {_frame, client} =
      Node.await(
        World.client(context),
        &(&1["t"] == "shell.links" and
            not Enum.any?(&1["links"], fn l -> l["environment"]["environmentId"] == id end)),
        5_000
      )

    World.put_client(context, client)
  end

  step ~r/^the node (?:no longer follows|does not follow) the shell of "(?<label>[^"]+)"$/,
       %{args: [label]} = context do
    id = environment(context, label)
    links = :sys.get_state(HalC2.Links)
    refute id in Map.values(links.following)
    refute Map.has_key?(links.rows, id)
    context
  end

  step "a client of the node asks for the shell", context do
    client = context |> World.client() |> Node.sub(5, %{"type" => "shell"})
    {frame, client} = Node.await(client, &(&1["t"] == "shell" and &1["id"] == 5), 5_000)
    context |> World.put_client(client) |> Map.put(:shell_frame, frame)
  end

  step "its links carry only their environment, origin, granted scopes and whether they are online",
       context do
    assert [link] = context.shell_frame["links"]
    assert Enum.sort(Map.keys(link)) == ~w(environment online origin scopes)
    assert context.shell_frame["links"] == HalC2.Links.list()
    context
  end

  step "its link to {string} lists orchestration:read as its only scope",
       %{args: [label]} = context do
    id = environment(context, label)
    assert [link] = context.shell_frame["links"]
    assert link["environment"]["environmentId"] == id
    assert link["scopes"] == ["orchestration:read"]
    context
  end

  step "the client stops following the shell", context do
    client = Node.unsub(World.client(context), 5)
    # The pong comes after the socket has handled the unsub.
    client = WsClient.send_json(client, %{"t" => "ping"})
    {_pong, client} = Node.await(client, &(&1["t"] == "pong"))
    World.put_client(context, client)
  end

  # --- shapes and calls routed through the link ------------------------------------

  step "a git checkout on {string}", %{args: [label]} = context do
    Map.put(context, :checkout, {label, checkout(context, label)})
  end

  step "a git checkout on {string} with a file that is not committed",
       %{args: [label]} = context do
    root = checkout(context, label)
    File.write!(Path.join(root, "linked.txt"), "linked\n")
    Map.put(context, :checkout, {label, root})
  end

  step "a client of the node follows the status of that checkout on {string}",
       %{args: [label]} = context do
    {^label, root} = context.checkout
    shape = %{"type" => "vcs", "environment" => environment(context, label), "cwd" => root}
    client = context |> World.client() |> Node.sub(6, shape)
    {frame, client} = Node.await(client, &(&1["id"] == 6), 10_000)
    context |> World.put_client(client) |> Map.put(:vcs_frame, frame)
  end

  step "it receives the checkout's status from {string}", context do
    assert %{"t" => "vcs", "event" => %{"_tag" => "snapshot", "local" => local}} =
             context.vcs_frame

    assert %{"refName" => "main", "hasWorkingTreeChanges" => false} = local
    context
  end

  step "a change in that checkout on {string} reaches the client", %{args: [label]} = context do
    {^label, root} = context.checkout
    File.write!(Path.join(root, "changed.txt"), "changed\n")
    # From another socket, so that waiting for the reply skips no status frame.
    caller = Node.connect(context.node)
    payload = %{"cwd" => root}

    assert {{:ok, %{"hasWorkingTreeChanges" => true}}, _} =
             Node.call(caller, environment(context, label), "vcs.refreshStatus", payload)

    {_frame, client} =
      Node.await(
        World.client(context),
        &(&1["id"] == 6 and &1["t"] == "vcs" and
            match?(
              %{"_tag" => "localUpdated", "local" => %{"hasWorkingTreeChanges" => true}},
              &1["event"]
            )),
        10_000
      )

    World.put_client(context, client)
  end

  step "a client of the node commits it with a git action on {string}",
       %{args: [label]} = context do
    {^label, root} = context.checkout

    input = %{
      "actionId" => "linked-action",
      "cwd" => root,
      "action" => "commit",
      "commitMessage" => "Through the link"
    }

    shape = %{
      "type" => "gitAction",
      "environment" => environment(context, label),
      "input" => input
    }

    client = context |> World.client() |> Node.sub(7, shape)
    {frame, client} = Node.await(client, &(&1["id"] == 7), 10_000)
    context |> World.put_client(client) |> Map.put(:git_action_frame, frame)
  end

  step "the client sees the git action start and finish", context do
    assert %{"t" => "gitAction", "event" => %{"kind" => "action_started"}} =
             context.git_action_frame

    {frame, client} =
      Node.await(
        World.client(context),
        &(&1["id"] == 7 and &1["t"] == "gitAction" and
            &1["event"]["kind"] in ~w(action_finished action_failed)),
        20_000
      )

    assert frame["event"]["kind"] == "action_finished", inspect(frame)
    World.put_client(context, client)
  end

  step "the commit is in the checkout on {string}", %{args: [label]} = context do
    {^label, root} = context.checkout
    {subject, 0} = System.cmd("git", ~w(log -1 --format=%s), cd: root)
    assert String.trim(subject) == "Through the link"
    context
  end

  step "a client of the node asks for the config of {string}", %{args: [label]} = context do
    shape = %{"type" => "config", "environment" => environment(context, label)}
    client = context |> World.client() |> Node.sub(8, shape)
    {frame, client} = Node.await(client, &(&1["id"] == 8 and &1["t"] == "config"), 10_000)
    context |> World.put_client(client) |> Map.put(:config_frame, frame)
  end

  step "a client of the node follows the project clones of {string}",
       %{args: [label]} = context do
    shape = %{"type" => "projectClones", "environment" => environment(context, label)}
    client = context |> World.client() |> Node.sub(9, shape)
    {_frame, client} = Node.await(client, &(&1["id"] == 9 and &1["t"] == "projectClones"), 10_000)
    World.put_client(context, client)
  end

  step "a client of the node starts cloning a repository on {string}",
       %{args: [label]} = context do
    id = "p-clone-#{System.unique_integer([:positive])}"
    dest = Path.join(Machines.home(context, label), "fs/work/cloned-#{id}")
    # From another socket, so that waiting for the reply skips no projectClones frame.
    caller = Node.connect(context.node)

    payload = %{
      "projectId" => id,
      "title" => Path.basename(dest),
      "createdAt" => World.iso_from_now(0),
      # Nothing answers there, so the clone fails, and a failed clone stays reported.
      "remoteUrl" => "file://" <> Path.join(Machines.home(context, label), "missing.git"),
      "destinationPath" => dest
    }

    assert {{:ok, _}, _} =
             Node.call(caller, environment(context, label), "projectClone.start", payload)

    Map.put(context, :linked_clone, id)
  end

  step "the client is told of that clone by {string}", context do
    id = context.linked_clone

    {_frame, client} =
      Node.await(
        World.client(context),
        &(&1["id"] == 9 and &1["t"] == "projectClones" and
            Enum.any?(&1["clones"], fn clone -> clone["projectId"] == id end)),
        10_000
      )

    World.put_client(context, client)
  end

  step "it receives the config of {string} with its providers and editors",
       %{args: [label]} = context do
    id = environment(context, label)
    config = context.config_frame["config"]
    assert config["environment"]["environmentId"] == id
    assert is_list(config["providers"])
    assert is_list(config["availableEditors"])
    context
  end

  step "a client of the node calls {word} on that checkout on {string}",
       %{args: [method, label]} = context do
    {^label, root} = context.checkout

    payload =
      case method do
        "projects.readFile" -> %{"cwd" => root, "relativePath" => "README.md"}
        "projects.searchEntries" -> %{"cwd" => root, "query" => "READ"}
        _ -> %{"cwd" => root}
      end

    {reply, context} = call(context, label, method, payload)
    assert {:ok, result} = reply, inspect(reply)
    Map.put(context, :called, result)
  end

  step "it receives the checkout's branches from {string}", context do
    assert Enum.any?(
             context.called["refs"] || context.called["branches"],
             &(&1["name"] == "main")
           ),
           inspect(context.called)

    context
  end

  step "it receives the checkout's files from {string}", context do
    assert Enum.any?(context.called["entries"], &(&1["path"] == "README.md"))
    context
  end

  step "it receives the files matching a query from {string}", context do
    assert Enum.any?(context.called["entries"], &(&1["path"] == "README.md"))
    context
  end

  step "a client of the node creates a thread on {string} and renames it",
       %{args: [label]} = context do
    thread = "th-routed-#{System.unique_integer([:positive])}"

    create = %{
      "type" => "thread.create",
      "commandId" => "c-" <> thread,
      "threadId" => thread,
      "title" => "Routed"
    }

    rename = %{
      "type" => "thread.metadata.update",
      "commandId" => "r-" <> thread,
      "threadId" => thread,
      "title" => "Renamed through the link"
    }

    {reply, context} = call(context, label, "orchestration.dispatchCommand", create)
    assert {:ok, _} = reply, inspect(reply)
    {reply, context} = call(context, label, "orchestration.dispatchCommand", rename)
    assert {:ok, _} = reply, inspect(reply)
    Map.put(context, :routed_thread, thread)
  end

  step "the thread on {string} has the new title", %{args: [label]} = context do
    thread = context.routed_thread
    server = Machines.on(context, label, HalC2.Streams, :ensure, [thread])
    state = Machines.on(context, label, HalC2.Streams.Server, :state, [server])

    assert %{^thread => %{"title" => "Renamed through the link"}} =
             HalC2.StreamState.get(state, "thread")

    context
  end

  step "the client reads the thread's diff from {string}", %{args: [label]} = context do
    thread = context.routed_thread
    payload = %{"threadId" => thread, "toTurnCount" => 0}
    {reply, context} = call(context, label, "orchestration.getFullThreadDiff", payload)
    assert {:ok, %{"threadId" => ^thread, "diff" => ""}} = reply
    context
  end

  step "none of it ran on the node", context do
    assert Registry.lookup(HalC2.Streams.Registry, context.routed_thread) == []
    context
  end

  step "it receives the file's contents from {string}", context do
    assert context.called["contents"] == "linked checkout\n"
    context
  end

  # A member "beast" lists but cannot reach: see the feature.
  step ~r/^"(?<label>[^"]+)" (?:has|gains) a cluster member "(?<member>[^"]+)"$/,
       %{args: [label, member]} = context do
    id = "env-" <> member
    descriptor = %{"environmentId" => id, "label" => member}
    peer = String.to_atom(member <> "@nowhere")

    Machines.on(context, label, GenServer, :cast, [
      HalC2.Shell,
      {:peer_environment, peer, descriptor}
    ])

    Map.update(context, :members, %{member => id}, &Map.put(&1, member, id))
  end

  step "the client sees {string} under the link to {string}",
       %{args: [member, label]} = context do
    member_id = context.members[member]
    id = environment(context, label)

    listed? = fn model ->
      Enum.any?(model.links[id].nodes, fn {_, n} ->
        n["environment"]["environmentId"] == member_id
      end)
    end

    {model, client} = await_linked(World.client(context), context.linked, listed?)
    context |> World.put_client(client) |> Map.put(:linked, model)
  end

  step "a client of the node calls {string}", %{args: [target]} = context do
    {reply, client} =
      Node.call(World.client(context), target_environment(context, target), "vcs.listRefs", %{
        "cwd" => "/"
      })

    context |> World.put_client(client) |> Map.put(:called, reply)
  end

  # Answered by "beast", which found the member in its cluster.
  step "{string} answers that the node of {string} is unavailable", context do
    assert {:error, "node unavailable" <> _, _} = context.called
    context
  end

  step "a client of the node that follows the status of a checkout on {string} is told the same",
       %{args: [target]} = context do
    frame = follow_status(context, target)
    assert %{"t" => "error", "reason" => "node unavailable" <> _} = frame
    context
  end

  step "a client of the node calling {string} is told {string} is unreachable",
       %{args: [label, _]} = context do
    {reply, context} = call(context, label, "vcs.listRefs", %{"cwd" => "/"})
    id = environment(context, label)

    assert {:error, message,
            %{
              "_tag" => "EnvironmentUnreachableError",
              "environmentId" => ^id,
              "reason" => "unreachable"
            }} =
             reply

    assert message =~ "unreachable"
    context
  end

  step "a client of the node that follows the status of a checkout on {string} is told {string} is unreachable",
       %{args: [label, _]} = context do
    id = environment(context, label)

    assert %{
             "t" => "error",
             "reason" => reason,
             "detail" => %{"_tag" => "EnvironmentUnreachableError", "environmentId" => ^id}
           } = follow_status(context, label)

    assert reason =~ "unreachable"
    context
  end

  step "the node is linked to {string} with only orchestration:read",
       %{args: [label]} = context do
    base = Machines.on(context, label, HalC2.Web, :base_url, [])

    {:ok, %{"credential" => credential}} =
      Machines.on(context, label, HalC2.Auth, :create_pairing_link, [
        %{"scopes" => ["orchestration:read"]}
      ])

    assert {:ok, _} = HalC2.Links.add(base <> "/pair#token=" <> credential)
    await_link(environment(context, label), true)
    context
  end

  step "{string} refuses the git action saying orchestration:operate is required", context do
    assert %{"t" => "error", "reason" => "orchestration:operate is required"} =
             context.git_action_frame

    context
  end

  step "a device paired with the node with only orchestration:read", context do
    client = Node.connect_as(context.node, Node.pair(["orchestration:read"]))
    World.put_client(context, "device", client)
  end

  step "the device starts a git action on {string}", %{args: [label]} = context do
    input = %{"actionId" => "device-action", "cwd" => cwd(context, label), "action" => "commit"}

    shape = %{
      "type" => "gitAction",
      "environment" => environment(context, label),
      "input" => input
    }

    client = context |> World.client("device") |> Node.sub(9, shape)
    {frame, client} = Node.await(client, &(&1["id"] == 9), 5_000)
    context |> World.put_client("device", client) |> Map.put(:device_frame, frame)
  end

  step "the node refuses the device saying orchestration:operate is required", context do
    assert %{"t" => "error", "reason" => "orchestration:operate is required"} =
             context.device_frame

    context
  end

  # --- helpers ----------------------------------------------------------------------

  # A git checkout with one commit under the machine's home.
  defp checkout(context, label) do
    root = Path.join(Machines.home(context, label), "fs/work/repo")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "linked checkout\n")

    for args <- [
          ~w(init -q -b main),
          ~w(config user.email hal-c2@example.com),
          ~w(config user.name HAL-C2),
          ~w(add README.md),
          ~w(commit -q -m init)
        ],
        do: {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)

    root
  end

  # A machine's environment, or a cluster member's the scenario made up.
  defp target_environment(context, target),
    do: get_in(context, [:members, target]) || environment(context, target)

  # The first frame of a status subscription on `target` from a fresh client.
  defp follow_status(context, target) do
    shape = %{"type" => "vcs", "environment" => target_environment(context, target), "cwd" => "/"}
    client = context.node |> Node.connect() |> Node.sub(10, shape)
    {frame, _client} = Node.await(client, &(&1["id"] == 10), 10_000)
    frame
  end

  defp commit(context, label, entities) do
    {:ok, seq} =
      Machines.on(context, label, HalC2.Streams, :commit, ["th-beast", :thread, entities])

    seq
  end

  # Subscribes to the linked thread by its environment: the frames before `live`, and
  # the live offset.
  defp follow_linked(client, context, id, offset) do
    shape = %{
      "type" => "stream",
      "environment" => environment(context, context.link_stream),
      "stream" => "th-beast"
    }

    client =
      WsClient.send_json(client, %{"t" => "sub", "id" => id, "shape" => shape, "offset" => offset})

    {live, frames, client} =
      WsClient.recv_until(client, &(&1["t"] == "live" and &1["id"] == id), 10_000)

    {Enum.filter(frames, &(&1["id"] == id)), live["offset"], client}
  end

  defp environment(context, label), do: Machines.machine(context, label).environment

  # A fresh one-time pairing link from the machine, as `mix hal_c2.pair` prints there.
  defp pairing_link(context, label) do
    base = Machines.on(context, label, HalC2.Web, :base_url, [])
    home = Machines.on(context, label, HalC2.Store, :home_path, [])
    token = Machines.on(context, label, HalC2.Auth, :create_pairing_token, [home])
    base <> "/pair#token=" <> token
  end

  defp cwd(context, label) do
    dir = Path.join(Machines.home(context, label), "fs/work/app")
    File.mkdir_p!(dir)
    dir
  end

  # An RPC from the default client, naming the linked environment, or with `:own`
  # the node's own.
  defp call(context, label, method, payload, on \\ :linked) do
    env = if on == :own, do: HalC2.Environment.id(), else: environment(context, label)
    {reply, client} = Node.call(World.client(context), env, method, payload)
    {reply, World.put_client(context, client)}
  end

  # The link to `id` once it is `online` (or matches the predicate), as the node's
  # links notify it.
  defp await_link(id, online) when is_boolean(online),
    do: await_link(id, &(&1["online"] == online))

  defp await_link(id, matches) do
    :ok = HalC2.Links.subscribe(self())
    await_link(id, matches, HalC2.Links.list())
  end

  defp await_link(id, matches, links) do
    link = Enum.find(links, &(&1["environment"]["environmentId"] == id))

    if link != nil and matches.(link) do
      link
    else
      receive do
        {:hal_c2_links, links} -> await_link(id, matches, links)
      after
        10_000 -> flunk("no such link to #{id}: #{inspect(links)}")
      end
    end
  end

  # The shell with its links' rows under id 5, as a model a client keeps: each link's
  # nodes by name and rows by `{node, id}`, and the snapshot it started from.
  defp shell_with_rows(client) do
    client = Node.sub(client, 5, %{"type" => "shell", "links" => true})
    {frame, client} = Node.await(client, &(&1["t"] == "shell" and &1["id"] == 5), 5_000)

    links =
      Map.new(frame["links"], fn link ->
        {link["environment"]["environmentId"],
         %{
           online: link["online"],
           nodes: Map.new(link["nodes"], &{&1["node"], &1}),
           rows: Map.new(link["rows"], fn [node, id, kind, row] -> {{node, id}, {kind, row}} end)
         }}
      end)

    {%{snapshot: frame, links: links}, client}
  end

  # Applies the shell's link frames to `model` until `done?` holds.
  defp await_linked(client, model, done?) do
    if done?.(model) do
      {model, client}
    else
      {frame, client} =
        Node.await(
          client,
          &(&1["id"] == 5 and String.starts_with?(&1["t"], "shell.link")),
          10_000
        )

      await_linked(client, apply_link_frame(model, frame), done?)
    end
  end

  defp apply_link_frame(model, %{"link" => id, "node" => node} = frame) do
    update_in(model.links[id], fn link ->
      entry = Map.get(link.nodes, node, %{"node" => node, "online" => false})

      case frame["t"] do
        "shell.linkRows" ->
          rows =
            for [row_id, kind, row] <- frame["rows"], into: %{}, do: {{node, row_id}, {kind, row}}

          %{link | rows: Map.merge(link.rows, rows)}

        "shell.linkEnvironment" ->
          put_in(link.nodes[node], Map.put(entry, "environment", frame["environment"]))

        "shell.linkNode" ->
          put_in(link.nodes[node], Map.put(entry, "online", frame["online"]))
      end
    end)
  end

  defp apply_link_frame(model, _frame), do: model

  defp thread_listed?(model, context) do
    link = model.links[environment(context, context.link_stream)]
    link != nil and Enum.any?(link.rows, &match?({{_, "th-beast"}, {"thread", _}}, &1))
  end
end
