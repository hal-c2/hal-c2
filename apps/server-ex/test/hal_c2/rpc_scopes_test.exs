defmodule HalC2.RpcScopesTest do
  use ExUnit.Case, async: true

  alias HalC2.Rpc

  test "plugin code and self-update need the admin pair" do
    for method <- ~w(plugins.rescan plugins.enable plugins.restart plugins.compile
                     server.updateServer server.updateServerWithProgress) do
      assert Rpc.required_scopes(method, %{}) == ["access:write", "terminal:operate"],
             method
    end

    assert Rpc.required_scopes("plugins.list", %{}) == ["orchestration:operate"]
  end

  test "registering or moving a workspace root needs terminal:operate" do
    assert Rpc.required_scopes("projects.mutate", %{"type" => "project.create"}) ==
             ["orchestration:operate", "terminal:operate"]

    assert Rpc.required_scopes("projects.mutate", %{
             "type" => "project.update",
             "workspaceRoot" => "/somewhere"
           }) == ["orchestration:operate", "terminal:operate"]

    assert Rpc.required_scopes("projects.mutate", %{"type" => "project.update"}) ==
             ["orchestration:operate"]

    for method <- ~w(projectClone.start projectClone.retry) do
      assert Rpc.required_scopes(method, %{}) ==
               ["orchestration:operate", "terminal:operate"],
             method
    end
  end

  test "opening an editor is shell work" do
    assert Rpc.required_scope("shell.openInEditor") == "terminal:operate"
  end

  test "a settings write that changes what runs needs terminal:operate" do
    changed = %{
      "settings" => %{"providerInstances" => %{"x" => %{"binaryPath" => "/tmp/evil"}}}
    }

    assert Rpc.required_scopes("hal-c2.writeSettings", changed) ==
             ["orchestration:operate", "terminal:operate"]

    # Any driver's or instance's key that is not known to be plain, a key the
    # schema gains later included.
    for {key, value} <- [
          {"binaryPath", "/tmp/evil"},
          {"launchArgs", "--evil"},
          {"homePath", "/tmp/home"},
          {"serverUrl", "https://attacker.example"},
          {"apiEndpoint", "https://attacker.example"},
          {"someFutureKey", "x"}
        ],
        settings <- [
          %{"providers" => %{"codex" => %{key => value}}},
          %{"providers" => %{"opencode" => %{key => value}}},
          %{"providerInstances" => %{"x" => %{"driver" => "codex", "config" => %{key => value}}}}
        ] do
      assert Rpc.required_scopes("hal-c2.writeSettings", %{"settings" => settings}) ==
               ["orchestration:operate", "terminal:operate"],
             inspect(settings)
    end
  end

  test "a settings write that only shows or hides providers stays an operate call" do
    for settings <- [
          %{},
          %{"providers" => %{"codex" => %{"enabled" => false, "customModels" => ["m"]}}},
          %{"providerInstances" => %{}}
        ] do
      assert Rpc.required_scopes("hal-c2.writeSettings", %{"settings" => settings}) ==
               ["orchestration:operate"],
             inspect(settings)
    end
  end
end
