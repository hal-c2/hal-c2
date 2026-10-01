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
