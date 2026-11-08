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

  # Review of #1322: a lookup npm could not answer was not remembered, so every
  # provider snapshot ran `npm view` again and logged again.
  test "a failed npm lookup is not tried again within the hour", %{tmp_dir: dir} do
    bin = Path.join(dir, "path-bin")
    log = Path.join(dir, "npm.log")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "npm"), "#!/bin/sh\necho \"$*\" >> #{log}\nexit 1\n")
    File.chmod!(Path.join(bin, "npm"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    previous = Application.fetch_env(:hal_c2, :provider_update_checks)
    Application.put_env(:hal_c2, :provider_update_checks, true)

    on_exit(fn ->
      System.put_env("PATH", path)

      case previous do
        {:ok, value} -> Application.put_env(:hal_c2, :provider_update_checks, value)
        :error -> Application.delete_env(:hal_c2, :provider_update_checks)
      end
    end)

    HalC2.Test.LogTap.attach()
    :persistent_term.erase({HalC2.ProviderUpdates, "codex"})
    codex = install(dir, "Cellar/codex/0.1.0/bin/codex", "bin/codex")

    assert HalC2.ProviderUpdates.advisory("codex", codex, "0.1.0")["status"] == "unknown"

    assert_receive {:logged, :warning, "Configured npm version lookup failed for @openai/codex"},
                   15_000

    assert HalC2.ProviderUpdates.advisory("codex", codex, "0.1.0")["status"] == "unknown"
    refute_received {:logged, :warning, _}
    assert [_] = log |> File.read!() |> String.split("\n", trim: true)
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

  # Grok's latest is seeded like the others'.
  setup do
    :persistent_term.put(
      {HalC2.ProviderUpdates, "grok"},
      {"9.9.9", System.monotonic_time(:millisecond)}
    )

    on_exit(fn ->
      :persistent_term.erase({HalC2.ProviderUpdates, "grok"})
      :persistent_term.erase({HalC2.ProviderUpdates, {:cask, "grok-build"}})
    end)
  end

  test "Grok updates through its own updater, npm installs included", %{tmp_dir: dir} do
    own = install(dir, "home/.grok/bin/grok", "home/bin/grok")

    assert HalC2.ProviderUpdates.advisory("grok", own, "1.0.0")["updateCommand"] ==
             "#{own} update"

    npm = install(dir, "lib/node_modules/@xai-official/grok/bin/grok", "bin/grok")

    assert HalC2.ProviderUpdates.advisory("grok", npm, "1.0.0")["updateCommand"] ==
             "#{npm} update"
  end

  test "a Grok binary that cannot be resolved has no update command", %{tmp_dir: dir} do
    missing = Path.join(dir, "gone/grok")
    advisory = HalC2.ProviderUpdates.advisory("grok", missing, "1.0.0")
    assert advisory["status"] == "behind_latest"
    assert advisory["updateCommand"] == nil
    assert HalC2.ProviderUpdates.advisory("grok", nil, "1.0.0")["updateCommand"] == nil
  end

  test "a Grok in a Homebrew cask upgrades through brew only where brew owns the prefix",
       %{tmp_dir: dir} do
    path = install(dir, "brew/Caskroom/grok-build/1.0.0/grok", "brew/bin/grok")
    assert HalC2.ProviderUpdates.advisory("grok", path, "1.0.0")["updateCommand"] == nil

    brew = Path.join(dir, "brew/bin/brew")
    File.write!(brew, "#!/bin/sh\necho '{\"casks\":[{\"version\":\"1.0.60\"}]}'\n")
    File.chmod!(brew, 0o755)

    assert HalC2.ProviderUpdates.advisory("grok", path, "1.0.0")["updateCommand"] ==
             "#{brew} upgrade --cask grok-build"
  end
end
