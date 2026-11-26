defmodule HalC2.PluginAuthorizationTest do
  use ExUnit.Case, async: false

  alias HalC2.Test.Mc

  @moduletag :tmp_dir

  @operator ~w(orchestration:read orchestration:operate)

  setup %{tmp_dir: dir} do
    mc = Mc.start(dir)
    plugin(Path.join([HalC2.Paths.data_dir(), "plugins", "runner"]))
    Mc.ensure(HalC2.Settings)
    Mc.ensure(HalC2.Plugins)
    {:ok, _} = HalC2.Plugins.handle("rescan", %{})
    {:ok, _} = HalC2.Plugins.handle("enable", %{"id" => "runner", "acceptPermissions" => []})
    {:ok, _} = Application.ensure_all_started(:inets)
    %{mc: mc}
  end

  test "rescanning and compiling plugins over HTTP need access management and the shell", %{
    mc: mc
  } do
    for {scopes, missing} <- [
          {HalC2.Auth.standard_scopes(), "access:write"},
          {["access:write"], "terminal:operate"}
        ] do
      bearer = Mc.pair(scopes, "Device")

      for path <- ["/api/plugins/rescan", "/api/plugins/runner/compile"] do
        assert {403, %{"_tag" => "EnvironmentScopeRequiredError", "requiredScope" => ^missing}} =
                 Mc.http(mc, :post, path, bearer: bearer, json: %{})
      end
    end
  end

  test "turning a plugin off needs what turning it on does", %{mc: mc} do
    client = Mc.connect_as(mc, Mc.pair(nil, "Standard"))

    assert {{:error, _, %{"_tag" => "EnvironmentScopeRequiredError"}}, _} =
             Mc.call(client, mc.environment, "plugins.disable", %{"id" => "runner"})

    assert HalC2.Settings.settings()["plugins"]["runner"]["enabled"] == true
  end

  test "a session without the shell cannot change what a plugin runs, and a standard one can", %{
    mc: mc
  } do
    operator = Mc.connect_as(mc, Mc.pair(@operator, "Operate only"))
    change = %{"id" => "runner", "settings" => %{"program" => "/opt/other"}}

    assert {{:error, message,
             %{"_tag" => "EnvironmentScopeRequiredError", "requiredScope" => "terminal:operate"}},
            operator} = Mc.call(operator, mc.environment, "plugins.saveSettings", change)

    assert message =~ "Program"
    refute HalC2.Settings.settings()["plugins"]["runner"]["settings"]["program"]

    # A setting that runs nothing is the operator's to change.
    assert {{:ok, _}, _} =
             Mc.call(operator, mc.environment, "plugins.saveSettings", %{
               "id" => "runner",
               "settings" => %{"count" => 2}
             })

    standard = Mc.connect_as(mc, Mc.pair(nil, "Standard"))
    assert {{:ok, _}, _} = Mc.call(standard, mc.environment, "plugins.saveSettings", change)
    assert HalC2.Settings.settings()["plugins"]["runner"]["settings"]["program"] == "/opt/other"
  end

  defp plugin(dir) do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "plugin.json"),
      JSON.encode!(%{
        "id" => "runner",
        "name" => "Runner",
        "version" => "1",
        "description" => "A package that runs a program.",
        "apiVersion" => 1,
        "settings" => [
          %{"key" => "program", "label" => "Program", "type" => "text", "exec" => true},
          %{"key" => "count", "label" => "Count", "type" => "number", "default" => 1}
        ]
      })
    )
  end
end
