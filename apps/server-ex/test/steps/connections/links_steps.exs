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

  # --- lent access ----------------------------------------------------------------

  step "a client of the node that already has access to {string}",
       %{args: [label]} = context do
    base = Machines.on(context, label, HalC2.Web, :base_url, [])
    home = Machines.on(context, label, HalC2.Store, :home_path, [])
    token = Machines.on(context, label, HalC2.Auth, :create_pairing_token, [home])

    assert {200, %{"access_token" => access}} =
             Node.exchange(%{port: URI.parse(base).port}, token)

    Map.put(context, :lent, {label, base, access})
  end

  step "it lends that access to the node", context do
    {label, base, access} = context.lent
    payload = %{"origin" => base, "token" => access}
    {reply, context} = call(context, label, "hal-c2.linkEnvironment", payload, :own)
    assert {:ok, %{"environmentId" => _}} = reply
    await_link(environment(context, label), true)
    context
  end

  step "it takes that access back", context do
    {label, _base, _access} = context.lent
    payload = %{"environmentId" => environment(context, label), "borrowed" => true}
    {reply, context} = call(context, label, "hal-c2.unlinkEnvironment", payload, :own)
    assert {:ok, nil} = reply
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

  step "its links carry only their environment, origin and whether they are online", context do
    assert [link] = context.shell_frame["links"]
    assert Enum.sort(Map.keys(link)) == ~w(environment online origin)
    assert context.shell_frame["links"] == HalC2.Links.list()
    context
  end

  step "the client stops following the shell", context do
    client = Node.unsub(World.client(context), 5)
    # The pong comes after the socket has handled the unsub.
    client = WsClient.send_json(client, %{"t" => "ping"})
    {_pong, client} = Node.await(client, &(&1["t"] == "pong"))
    World.put_client(context, client)
  end

  # --- helpers ----------------------------------------------------------------------

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

  # The link to `id` once it is `online`, as the node's links notify it.
  defp await_link(id, online) do
    :ok = HalC2.Links.subscribe(self())
    await_link(id, online, HalC2.Links.list())
  end

  defp await_link(id, online, links) do
    case Enum.find(links, &(&1["environment"]["environmentId"] == id)) do
      %{"online" => ^online} = link ->
        link

      _ ->
        receive do
          {:hal_c2_links, links} -> await_link(id, online, links)
        after
          10_000 -> flunk("no link to #{id} with online #{online}: #{inspect(links)}")
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
