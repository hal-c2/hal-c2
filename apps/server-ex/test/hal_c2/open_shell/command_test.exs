defmodule HalC2.OpenShell.CommandTest do
  # The MC's home and the platform facts come from the app env.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell.Command
  alias HalC2.OpenShell.Manifest
  alias HalC2.OpenShell.Platform
  alias HalC2.Test.FakeOpenShell

  @moduletag :tmp_dir

  describe "settings_status/2" do
    test "an Intel Mac is not supported, and says why", %{tmp_dir: dir} do
      FakeOpenShell.put_env(
        home: Path.join(dir, "mc"),
        openshell_facts: %{os: :darwin, arch: "x86_64", runtime: nil}
      )

      assert {:ok,
              %{
                "supported" => false,
                "ready" => false,
                "mode" => nil,
                "version" => nil,
                "pinnedVersion" => pinned,
                "problems" => [%{"code" => "intel-mac", "message" => message}]
              }} = Command.settings_status()

      assert pinned == Manifest.version()
      assert message == Platform.problem_message("intel-mac")
    end

    test "a machine that can run it says how to install it" do
      status = fn -> status(%{"supported" => true, "problems" => ["not-installed"]}) end

      assert {:ok, %{"supported" => true, "ready" => false, "problems" => [problem]}} =
               Command.settings_status(status)

      assert problem == %{
               "code" => "not-installed",
               "message" => Command.problem_message("not-installed")
             }
    end

    test "an installed gateway with no problems is ready; one with problems is not" do
      ready = status(%{"mode" => "managed", "version" => Manifest.version()})

      assert {:ok, %{"ready" => true, "mode" => "managed", "problems" => []}} =
               Command.settings_status(fn -> ready end)

      unreachable = %{ready | "problems" => ["gateway-unreachable"]}

      assert {:ok, %{"ready" => false, "problems" => [%{"code" => "gateway-unreachable"}]}} =
               Command.settings_status(fn -> unreachable end)
    end

    test "a status that does not answer in time is the contract's error" do
      assert {:error, %{"_tag" => "ServerOpenShellStatusError", "message" => message}} =
               Command.settings_status(fn -> Process.sleep(:infinity) end, 0)

      assert message =~ "hal-c2-service openshell status"
    end
  end

  defp status(fields) do
    Map.merge(
      %{"supported" => true, "problems" => [], "mode" => nil, "version" => nil},
      fields
    )
  end
end
