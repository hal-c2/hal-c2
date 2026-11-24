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
               "message" => Command.settings_problem_message("not-installed", "Install")
             }

      assert {:ok, %{"actions" => [%{"operation" => "install", "label" => "Install"}]}} =
               Command.settings_status(status)
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

      assert message =~ "Refresh"
    end

    @tag :capture_log
    test "a status that raises is the contract's error, without its stack" do
      assert {:error, %{"_tag" => "ServerOpenShellStatusError", "message" => message}} =
               Command.settings_status(fn -> raise "state file is not JSON" end)

      assert message =~ "Refresh"
      refute message =~ "state file is not JSON"
    end
  end

  describe "settings_actions/1" do
    test "a host OpenShell has no build for offers nothing; one that can run it, Install" do
      assert Command.settings_actions(status(%{"problems" => ["intel-mac"]})) == []

      assert Command.settings_actions(status(%{"problems" => ["not-installed"]})) == [
               %{"operation" => "install", "label" => "Install"}
             ]
    end

    test "a managed gateway is updated, repaired or left, then checked, rotated or removed" do
      labels = fn problems ->
        status(%{"mode" => "managed", "problems" => problems})
        |> Command.settings_actions()
        |> Enum.map(& &1["label"])
      end

      rest = ["Check", "Rotate certificates", "Uninstall"]
      assert labels.([]) == rest
      assert labels.(["update-available", "service-stopped"]) == ["Update" | rest]
      assert labels.(["service-stopped"]) == ["Repair" | rest]
    end

    test "the problems name the button that fixes them" do
      repair = status(%{"mode" => "managed", "problems" => ["service-not-ours"]})

      assert {:ok, %{"problems" => [%{"message" => message}]}} =
               Command.settings_status(fn -> repair end)

      assert message =~ "press Repair"
      refute message =~ "hal-c2-service"
    end

    test "a service problem names Update when Update is what Settings offers" do
      problems = ["update-available", "service-missing", "service-outdated", "service-stopped"]
      outdated = status(%{"mode" => "managed", "problems" => problems})

      assert {:ok, %{"actions" => [%{"label" => "Update"} | _], "problems" => messages}} =
               Command.settings_status(fn -> outdated end)

      for %{"message" => message} <- messages do
        assert message =~ "Update"
        refute message =~ "Repair"
      end
    end

    test "a dev run's old gateway is still to update, by the dev run, not a button" do
      dev = status(%{"mode" => "foreground", "problems" => ["update-available"]})

      assert {:ok,
              %{
                "actions" => actions,
                "problems" => [%{"code" => "update-available", "message" => message}]
              }} = Command.settings_status(fn -> dev end)

      refute Enum.any?(actions, &(&1["operation"] == "install"))
      assert message =~ "mise run openshell"
      refute message =~ "Press"
    end

    test "a user's own gateway is checked or stopped being used" do
      assert Command.settings_actions(status(%{"mode" => "external"})) == [
               %{"operation" => "check", "label" => "Check"},
               %{"operation" => "uninstall", "label" => "Stop using it"}
             ]
    end
  end

  describe "settings_error/1" do
    test "running sandboxes are counted and named, and the CLI's flag is not named" do
      assert %{
               "code" => "sandboxes-running",
               "sandboxes" => 3,
               "drain" => ["review-a", "review-b", "review-c"],
               "message" => message
             } =
               Command.settings_error(
                 "[sandboxes-running] 3 of this MC's sandboxes are on the gateway (review-a, review-b, review-c). Let their reviews finish, or pass --drain to delete them."
               )

      assert message =~ "3 of this MC's review sandboxes are on the gateway"
      refute message =~ "--drain"

      assert %{"sandboxes" => 1, "drain" => ["review-a"], "message" => one} =
               Command.settings_error(
                 "[sandboxes-running] 1 of this MC's sandboxes is on the gateway (review-a). Let its review finish, or pass --drain to delete it."
               )

      assert one =~
               "1 of this MC's review sandboxes is on the gateway. Going ahead deletes it, which stops its review"
    end

    test "running reviews that changed since the yes are asked about again, by name" do
      assert %{
               "code" => "sandboxes-changed",
               "sandboxes" => 2,
               "drain" => ["review-a", "review-b"],
               "message" => message
             } =
               Command.settings_error(
                 "[sandboxes-changed] The running reviews changed since they were confirmed: 2 of this MC's sandboxes are on the gateway (review-a, review-b). Check them again before deleting them."
               )

      assert message =~ "changed since you confirmed"
      assert message =~ "2 of this MC's review sandboxes are on the gateway"
    end

    test "a busy lock and a platform problem are worded for Settings" do
      assert %{"code" => "busy", "sandboxes" => nil, "message" => busy} =
               Command.settings_error(HalC2.OpenShell.Install.busy())

      refute busy =~ "Run this one"

      assert %{"code" => "podman-missing", "message" => podman} =
               Command.settings_error(
                 "[podman-missing] " <> Platform.problem_message("podman-missing")
               )

      assert podman =~ "press Install"
    end

    test "a message without a code keeps its text" do
      assert Command.settings_error("Downloading failed: timeout") == %{
               "code" => nil,
               "message" => "Downloading failed: timeout",
               "sandboxes" => nil,
               "drain" => nil
             }
    end
  end

  defp status(fields) do
    Map.merge(
      %{"supported" => true, "problems" => [], "mode" => nil, "version" => nil},
      fields
    )
  end
end
