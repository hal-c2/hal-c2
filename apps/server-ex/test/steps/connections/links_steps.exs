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
end
