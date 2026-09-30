defmodule HalC2.EnvironmentProvidersTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", @fake_codex])
    Application.put_env(:hal_c2, :claude_command, ["python3", @fake_claude])

    on_exit(fn ->
      Application.delete_env(:hal_c2, :codex_command)
      Application.delete_env(:hal_c2, :claude_command)
    end)

    start_supervised!(HalC2.Settings)
    :ok
  end

  defp codex, do: Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == "codex"))

  test "a provider carries its instance's trimmed name and accent colour" do
    refute Map.has_key?(codex(), "displayName")

    {:ok, _} =
      HalC2.Settings.update(fn settings ->
        Map.put(settings, "providerInstances", %{
          "codex" => %{
            "driver" => "codex",
            "displayName" => "  Work Codex ",
            "accentColor" => "#ff8800"
          }
        })
      end)

    assert %{"displayName" => "Work Codex", "accentColor" => "#ff8800"} = codex()
  end

  test "a blank name is left out" do
    {:ok, _} =
      HalC2.Settings.update(fn settings ->
        Map.put(settings, "providerInstances", %{
          "codex" => %{"driver" => "codex", "displayName" => "  "}
        })
      end)

    refute Map.has_key?(codex(), "displayName")
    refute Map.has_key?(codex(), "accentColor")
  end
end
