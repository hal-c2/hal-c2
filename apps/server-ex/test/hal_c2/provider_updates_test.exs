defmodule HalC2.ProviderUpdatesTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    # The latest release, as if already read from the registry.
    for driver <- ["codex", "claudeAgent"],
        do:
          :persistent_term.put(
            {HalC2.ProviderUpdates, driver},
            {"9.9.9", System.monotonic_time(:millisecond)}
          )

    on_exit(fn ->
      for driver <- ["codex", "claudeAgent"],
          do: :persistent_term.erase({HalC2.ProviderUpdates, driver})
    end)
  end

  # An executable at `real`, found through a symlink at `link`.
  defp install(dir, real, link) do
    real = Path.join(dir, real)
    link = Path.join(dir, link)
    File.mkdir_p!(Path.dirname(real))
    File.mkdir_p!(Path.dirname(link))
    File.write!(real, "")
    File.ln_s!(real, link)
    link
  end

  test "a Homebrew install updates with brew", %{tmp_dir: dir} do
    path = install(dir, "Cellar/codex/0.1.0/bin/codex", "bin/codex")

    assert %{
             "status" => "behind_latest",
             "latestVersion" => "9.9.9",
             "canUpdate" => true,
             "updateCommand" => "brew upgrade codex"
           } = HalC2.ProviderUpdates.advisory("codex", path, "0.1.0")
  end

  test "a global npm install updates its own prefix", %{tmp_dir: dir} do
    path = install(dir, "lib/node_modules/@openai/codex/bin/codex.js", "bin/codex")
    advisory = HalC2.ProviderUpdates.advisory("codex", path, "9.9.9")

    assert advisory["status"] == "current"
    assert advisory["updateCommand"] == "npm install -g --prefix #{dir} @openai/codex@latest"
  end

  test "OpenCode's own install upgrades itself, and an npm one updates opencode-ai",
       %{tmp_dir: dir} do
    own = install(dir, "home/.opencode/bin/opencode", "home/bin/opencode")

    assert HalC2.ProviderUpdates.advisory("opencode", own, "1.14.19")["updateCommand"] ==
             "#{own} upgrade"

    npm = install(dir, "lib/node_modules/opencode-ai/bin/opencode", "bin/opencode")

    assert HalC2.ProviderUpdates.advisory("opencode", npm, "1.14.19")["updateCommand"] ==
             "npm install -g --prefix #{dir} opencode-ai@latest"
  end

  test "an install nothing here owns is reported without an update", %{tmp_dir: dir} do
    path = install(dir, "opt/codex", "bin/codex")

    assert %{"canUpdate" => false, "updateCommand" => nil, "status" => "unknown"} =
             HalC2.ProviderUpdates.advisory("codex", path, "unknown")
  end

  test "only a global npm install can pin a version", %{tmp_dir: dir} do
    npm = install(dir, "lib/node_modules/@openai/codex/bin/codex.js", "bin/codex")
    assert HalC2.ProviderUpdates.advisory("codex", npm, "0.1.0")["canInstallVersion"]

    brew = install(dir, "Cellar/codex/0.1.0/bin/codex", "brew/codex")
    refute HalC2.ProviderUpdates.advisory("codex", brew, "0.1.0")["canInstallVersion"]
  end

  test "a WinGet Claude install is updated by hand, with the winget command shown",
       %{tmp_dir: dir} do
    path =
      install(
        dir,
        "Microsoft/WinGet/Packages/Anthropic.ClaudeCode/claude.exe",
        "Microsoft/WinGet/Links/claude.exe"
      )

    assert %{
             "status" => "behind_latest",
             "canUpdate" => false,
             "updateCommand" => "winget upgrade Anthropic.ClaudeCode"
           } = HalC2.ProviderUpdates.advisory("claudeAgent", path, "2.1.0")
  end

  test "a native Claude install is compared with its release channel, not npm",
       %{tmp_dir: dir} do
    # The channel is read from the instance's Claude settings; none here, so latest.
    System.put_env("CLAUDE_CONFIG_DIR", Path.join(dir, "claude-config"))
    on_exit(fn -> System.delete_env("CLAUDE_CONFIG_DIR") end)
    path = install(dir, ".local/share/claude/versions/2.1.0/claude", ".local/bin/claude")

    # npm is at 9.9.9 (setup), but the channel still offers the installed one.
    assert %{"status" => "unknown", "latestVersion" => nil} =
             HalC2.ProviderUpdates.advisory("claudeAgent", path, "2.1.0")

    :persistent_term.put(
      {HalC2.ProviderUpdates, :claude_channel, "latest"},
      {"2.1.0", System.monotonic_time(:millisecond)}
    )

    on_exit(fn -> :persistent_term.erase({HalC2.ProviderUpdates, :claude_channel, "latest"}) end)

    assert %{"status" => "current", "latestVersion" => "2.1.0"} =
             HalC2.ProviderUpdates.advisory("claudeAgent", path, "2.1.0")
  end

  test "a release channel's answer is a plain version or nothing" do
    assert HalC2.ProviderUpdates.parse_channel_version("2.1.300\n") == "2.1.300"
    assert HalC2.ProviderUpdates.parse_channel_version("v2.1.300") == "2.1.300"
    assert HalC2.ProviderUpdates.parse_channel_version("<html>nope</html>") == nil
    assert HalC2.ProviderUpdates.parse_channel_version("") == nil
  end

  test "a version to install must be a plain release", %{tmp_dir: dir} do
    path = install(dir, "lib/node_modules/@openai/codex/bin/codex.js", "bin/codex")
    File.chmod!(path, 0o755)
    Application.put_env(:hal_c2, :codex_command, [path])
    on_exit(fn -> Application.delete_env(:hal_c2, :codex_command) end)

    assert {:error, %{"reason" => "This installation cannot install v1.0.0; rm -rf /."}} =
             HalC2.ProviderUpdates.update(%{
               "provider" => "codex",
               "targetVersion" => "1.0.0; rm -rf /"
             })
  end
end
