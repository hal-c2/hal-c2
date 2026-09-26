defmodule HalC2.Steps.Connections.ConnectionModes do
  @moduledoc """
  Steps for `features/connections/connection-modes.feature`: where the node
  listens (loopback, a LAN host from `HALC2_NODE_HOST`) and pairing over Tailscale Serve
  HTTPS with `mix hal_c2.pair --tailscale`, against `test/support/fake_tailscale.py`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @tailnet_name "box.tail5e3a.ts.net"

  # --- the listening address ---------------------------------------------------------

  # Another machine dials this one's LAN address.
  step "a client on another machine tries to connect", context do
    reply = :gen_tcp.connect(String.to_charlist(Node.lan_address()), context.node.port, [], 1_000)
    Map.put(context, :dial, reply)
  end

  step "the connection is refused", context do
    assert context.dial == {:error, :econnrefused}
    context
  end

  step "a client on the node's machine connects to the loopback address", context do
    World.put_client(context, Node.connect(context.node))
  end

  step "it reaches the node", context do
    client = HalC2.Test.WsClient.send_json(World.client(context), %{"t" => "ping"})
    {%{"t" => "pong"}, client} = HalC2.Test.WsClient.recv(client, 1_000)
    World.put_client(context, client)
  end

  step "an operator starts the node with a LAN host", context do
    host = Node.lan_address()
    System.put_env("HALC2_NODE_HOST", host)

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("HALC2_NODE_HOST")
      Application.delete_env(:hal_c2, :host)
    end)

    # As a release boots: runtime config reads the environment.
    config = Config.Reader.read!(Path.expand("config/runtime.exs"), env: :test)
    Application.put_env(:hal_c2, :host, get_in(config, [:hal_c2, :host]))

    context
    |> Map.merge(%{node: Node.restart(context.node), clients: %{}})
    |> Map.put(:lan_base, "http://#{host}:#{context.node.port}")
  end

  step "clients on the LAN can pair with it", context do
    assert [link] = Node.run_task(Mix.Tasks.HalC2.Pair, [context.lan_base])
    token = token_after(link, "#{context.lan_base}/?token=")

    assert {200, %{"access_token" => access}} = Node.pair_http(context.lan_base, token)

    assert {200, %{"authenticated" => true}} =
             Node.http(context.lan_base, :get, "/api/auth/session", bearer: access)

    context
  end

  # --- Tailscale Serve ---------------------------------------------------------------

  step "the node's machine is on a tailnet", context do
    on_tailnet(context)
  end

  step "an operator asks for a Tailscale pairing link", context do
    assert [link | _notes] = Node.run_task(Mix.Tasks.HalC2.Pair, ["--tailscale"])
    Map.put(context, :printed, link)
  end

  step "the node is served at its tailnet HTTPS name", context do
    assert served(context)["#{@tailnet_name}:443"] == "http://127.0.0.1:#{context.node.port}"
    assert reaches?(context, "#{@tailnet_name}:443")
    context
  end

  step "the printed link uses that name", context do
    token = token_after(context.printed, "https://#{@tailnet_name}/?token=")
    # Through the mapping, as a phone on the tailnet would.
    assert {200, _} = Node.pair_http(served(context)["#{@tailnet_name}:443"], token)
    context
  end

  step "an operator created a Tailscale pairing link", context do
    context = on_tailnet(context)
    assert [_link | _] = Node.run_task(Mix.Tasks.HalC2.Pair, ["--tailscale"])
    context
  end

  step "the tailnet HTTPS name still reaches it", context do
    assert reaches?(context, "#{@tailnet_name}:443")
    # Pairing again reuses the mapping.
    assert [link | _] = Node.run_task(Mix.Tasks.HalC2.Pair, ["--tailscale"])
    token_after(link, "https://#{@tailnet_name}/?token=")

    context
  end

  step "the default tailnet HTTPS port is in use", context do
    # Something that is not this node: a port nothing answers on.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, other} = :inet.port(socket)
    :gen_tcp.close(socket)

    context = on_tailnet(context, %{"#{@tailnet_name}:443" => "http://127.0.0.1:#{other}"})
    Map.put(context, :other_target, "http://127.0.0.1:#{other}")
  end

  step "an operator asks for a Tailscale pairing link on another port", context do
    assert {:error, message} = Node.run_task(Mix.Tasks.HalC2.Pair, ["--tailscale"])
    assert message =~ "Pass --tailscale-serve-port"

    assert [link | _] =
             Node.run_task(Mix.Tasks.HalC2.Pair, ["--tailscale", "--tailscale-serve-port", "8443"])

    Map.put(context, :printed, link)
  end

  step "the link uses that port", context do
    token_after(context.printed, "https://#{@tailnet_name}:8443/?token=")
    assert served(context)["#{@tailnet_name}:8443"] == "http://127.0.0.1:#{context.node.port}"
    assert served(context)["#{@tailnet_name}:443"] == context.other_target
    assert reaches?(context, "#{@tailnet_name}:8443")
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp token_after(link, prefix) do
    assert String.starts_with?(link, prefix), "#{link} does not start with #{prefix}"
    String.replace_prefix(link, prefix, "")
  end

  # Points `tailscale` at the fake with this machine on a tailnet and `serve` mappings.
  defp on_tailnet(context, serve \\ %{}) do
    state = Path.join(Node.tmp_dir(context.node, "tailscale"), "state.json")

    File.write!(
      state,
      JSON.encode!(%{
        "self" => %{"DNSName" => @tailnet_name <> ".", "TailscaleIPs" => ["100.64.0.7"]},
        "peers" => %{},
        "serve" => serve
      })
    )

    script = Path.expand("test/support/fake_tailscale.py")

    Application.put_env(:hal_c2, :tailscale_command, [
      "env",
      "FAKE_TAILSCALE_STATE=#{state}",
      script
    ])

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :tailscale_command) end)
    Map.put(context, :tailscale_state, state)
  end

  defp served(context),
    do: context.tailscale_state |> File.read!() |> JSON.decode!() |> Map.fetch!("serve")

  # The mapping's local target answers as this environment.
  defp reaches?(context, host) do
    target = Map.fetch!(served(context), host)
    environment = context.node.environment

    match?(
      {200, %{"environmentId" => ^environment}},
      Node.http(target, :get, "/.well-known/hal-c2/environment")
    )
  end
end
