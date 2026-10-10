defmodule HalC2.AcpTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!(HalC2.Settings)
    :ok
  end

  test "agent commands follow the runtime mode and the configured binary" do
    assert {:ok, ["opencode", "acp"], []} = HalC2.Acp.command("opencode", "full-access")

    assert {:ok, ["grok", "agent", "--always-approve", "stdio"], []} =
             HalC2.Acp.command("grok", "full-access")

    assert {:ok, ["grok", "--permission-mode", "default", "agent", "stdio"], []} =
             HalC2.Acp.command("grok", "approval-required")

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "opencode" => %{
              "driver" => "opencode",
              "enabled" => true,
              "config" => %{"binaryPath" => "/opt/oc"}
            }
          }
        },
        0
      )

    assert {:ok, ["/opt/oc", "acp"], []} = HalC2.Acp.command("opencode")
    assert HalC2.Acp.enabled?("opencode")
    refute HalC2.Acp.enabled?("grok")
    assert {:error, _} = HalC2.Acp.command("nope")
  end

  test "Cursor runs the SDK sidecar with its sign-in under the HAL-C2 home", %{tmp_dir: dir} do
    assert {:ok, ["node", script, "--mode", "full-access"], env} =
             HalC2.Acp.command("cursor", "full-access")

    assert File.exists?(script)

    assert {"HAL_C2_CURSOR_CREDENTIALS", Path.join(dir, "provider-auth/cursor/cursor.json")} in env
  end

  test "Pi is offered only where its binary is installed" do
    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "pi" => %{
              "driver" => "pi",
              "enabled" => true,
              "config" => %{"binaryPath" => "/nope/pi"}
            }
          }
        },
        0
      )

    assert HalC2.Acp.agent?("pi")
    assert HalC2.Acp.entry("pi") == nil
  end

  test "a disabled agent says so instead of claiming to be ready", %{tmp_dir: dir} do
    grok = Path.join(dir, "grok")
    File.write!(grok, "#!/bin/sh\n")
    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => false,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    assert %{"enabled" => false, "status" => "disabled", "message" => message} =
             HalC2.Acp.entry("grok")

    assert message == "Grok is disabled in HAL-C2 settings."
  end

  test "a disabled agent has no version, since it has never been launched", %{tmp_dir: dir} do
    grok = Path.join(dir, "grok")
    File.write!(grok, "#!/bin/sh\n")
    File.chmod!(grok, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{
          "providerInstances" => %{
            "grok" => %{
              "driver" => "grok",
              "enabled" => false,
              "config" => %{"binaryPath" => grok}
            }
          }
        },
        0
      )

    assert %{"version" => nil} = HalC2.Acp.entry("grok")
  end

  test "a disabled Antigravity is installed only when its runtime is on this machine", %{
    tmp_dir: dir
  } do
    put = fn path ->
      {:ok, _} =
        HalC2.Settings.put(
          %{
            "providerInstances" => %{
              "antigravity" => %{
                "driver" => "antigravity",
                "enabled" => false,
                "config" => %{"binaryPath" => path}
              }
            }
          },
          0
        )
    end

    put.(Path.join(dir, "missing"))

    assert %{"status" => "disabled", "installed" => false, "version" => nil} =
             HalC2.Acp.entry("antigravity")
  end
end
