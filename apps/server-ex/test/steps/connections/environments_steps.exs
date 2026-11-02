defmodule HalC2.Steps.Connections.Environments do
  @moduledoc """
  Steps for `features/connections/environments.feature`: the MC's side of a
  client's environment list, its descriptor and the persisted environment icon.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # The client's list of environments is client state; the MC's part is that
  # pairing with it over HTTP gives the client a session, as for any other environment.
  step "a client paired with two environments", context do
    {:ok, %{"credential" => credential}} = HalC2.Auth.create_pairing_link(%{"label" => "Laptop"})

    {200, %{"access_token" => access, "token_type" => "Bearer"}} =
      Mc.pair_http(context.mc, credential)

    Map.put(context, :paired_access, access)
  end

  # The machine's SSH server and Tailscale: a listener on a free port and a fake
  # `tailscale` stand in for them.
  defp ssh_listening(context, ip) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: ip])
    {:ok, port} = :inet.port(socket)
    set_env(:remote_open_ssh_port, port)
    Map.put(context, :ssh_listener, socket)
  end

  defp nothing_listening(context) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    set_env(:remote_open_ssh_port, port)
    context
  end

  defp fake_tailscale(script) do
    path = Path.join(System.tmp_dir!(), "fake-tailscale-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(path, 0o755)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    set_env(:tailscale_command, [path])
  end

  defp set_env(key, value) do
    before = Application.fetch_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:hal_c2, key, value)
        :error -> Application.delete_env(:hal_c2, key)
      end
    end)
  end

  defp mdns_name do
    {:ok, hostname} = :inet.gethostname()
    (hostname |> List.to_string() |> String.split(".") |> hd()) <> ".local"
  end

  step "no SSH server is listening on this machine", context do
    fake_tailscale(~s(echo '{"Self":{"DNSName":"box.tail.ts.net."}}'))
    nothing_listening(context)
  end

  step "the SSH server listens only on IPv6 loopback", context do
    fake_tailscale("exit 1")
    ssh_listening(context, {0, 0, 0, 0, 0, 0, 0, 1})
  end

  step "Tailscale reports a MagicDNS name and the machine has a name", context do
    fake_tailscale(~s(echo '{"Self":{"DNSName":"box.tail.ts.net."}}'))
    ssh_listening(context, {127, 0, 0, 1})
  end

  step "Tailscale is not available", context do
    fake_tailscale("exit 1")
    ssh_listening(context, {127, 0, 0, 1})
  end

  step "finding the machine's SSH names takes longer than a client should wait", context do
    fake_tailscale("sleep 5")
    set_env(:remote_open_budget_ms, 50)
    ssh_listening(context, {127, 0, 0, 1})
  end

  step "a client asks the MC for its configuration", context do
    Mc.ensure(HalC2.Settings)

    client =
      World.client(context)
      |> Mc.sub(21, %{"type" => "config", "environment" => context.mc.environment})

    {frame, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == 21))
    context |> World.put_client(client) |> Map.put(:server_config, frame["config"])
  end

  step "the MC advertises no SSH names for opening workspaces over SSH", context do
    assert context.server_config["remoteOpenTargets"] == []
    context
  end

  step "the MC advertises its names, because it is listening for opening workspaces over SSH",
       context do
    assert context.server_config["remoteOpenTargets"] == [
             %{"kind" => "mdns", "host" => mdns_name()}
           ]

    context
  end

  step "the MC advertises the tailnet name first, then the .local name for opening workspaces over SSH",
       context do
    assert context.server_config["remoteOpenTargets"] == [
             %{"kind" => "tailscale", "host" => "box.tail.ts.net"},
             %{"kind" => "mdns", "host" => mdns_name()}
           ]

    context
  end

  step "the MC advertises only the machine's .local name for opening workspaces over SSH",
       context do
    assert context.server_config["remoteOpenTargets"] == [
             %{"kind" => "mdns", "host" => mdns_name()}
           ]

    context
  end

  step "the configuration arrives without SSH names", context do
    assert context.server_config["remoteOpenTargets"] == []
    context
  end

  step "a client reads the MC's descriptor", context do
    {200, descriptor} = Mc.http(context.mc, :get, "/.well-known/hal-c2/environment")
    Map.put(context, :descriptor, descriptor)
  end

  step "it names the environment id, label, platform and detected machine kind", context do
    descriptor = context.descriptor
    assert descriptor["environmentId"] == context.mc.environment
    {:ok, host} = :inet.gethostname()
    assert descriptor["label"] == (System.get_env("HAL_C2_LABEL") || List.to_string(host))
    assert %{"os" => os, "arch" => arch} = descriptor["platform"]
    assert is_binary(os) and is_binary(arch)
    assert descriptor["platform"]["machine"] == HalC2.Environment.Machine.kind()
    assert descriptor["capabilities"]["environmentIcon"] == true
    context
  end

  step "a paired administrator's client", context do
    admin_client(context)
  end

  step "it sets the environment icon to {string}", %{args: [icon]} = context do
    set_icon(context, icon)
  end

  step "the MC's settings still name {string} as the environment icon",
       %{args: [icon]} = context do
    {settings, context} = read_settings(admin_client(context))
    assert settings["environmentIcon"] == icon
    context
  end

  step "an environment icon was chosen", context do
    context |> admin_client() |> set_icon("mac-studio")
  end

  step "a client clears the environment icon", context do
    set_icon(context, nil)
  end

  step "the MC's settings name no icon", context do
    {settings, context} = read_settings(context)
    assert settings["environmentIcon"] == nil
    assert HalC2.Settings.settings()["environmentIcon"] == nil
    context
  end

  step "the descriptor still names the machine the MC detected", context do
    {200, descriptor} = Mc.http(context.mc, :get, "/.well-known/hal-c2/environment")
    assert descriptor["platform"]["machine"] == HalC2.Environment.Machine.kind()
    context
  end

  defp admin_client(context) do
    Mc.ensure(HalC2.Settings)
    access = Mc.pair(Mc.admin_scopes(), "Admin")
    World.put_client(context, Mc.connect_as(context.mc, access))
  end

  defp read_settings(context) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings")

    {settings, Map.put(context, :settings_version, version)}
  end

  defp set_icon(context, icon) do
    {settings, context} = read_settings(context)

    {%{"version" => _}, context} =
      World.call!(context, "hal-c2.writeSettings", %{
        "settings" => Map.put(settings, "environmentIcon", icon),
        "version" => context.settings_version
      })

    context
  end
end
