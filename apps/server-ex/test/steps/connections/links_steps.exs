defmodule HalC2.Steps.Connections.Links do
  @moduledoc """
  Steps for `features/connections/links.feature`.

  "beast" is a peer running the whole application on its own, driven over stdio, so
  it never joins this VM's cluster: the scenario's node reaches it only through a
  link. Its terminals run `/bin/sh` in a folder under its home.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.{Machines, Node}
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

  # --- helpers ----------------------------------------------------------------------

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

  # An RPC from the default client, naming the linked environment.
  defp call(context, label, method, payload) do
    {reply, client} =
      Node.call(World.client(context), environment(context, label), method, payload)

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
end
