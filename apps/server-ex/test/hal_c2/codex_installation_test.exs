defmodule HalC2.CodexInstallationTest do
  use ExUnit.Case, async: false

  alias HalC2.Codex.Installation

  @moduletag :tmp_dir
  @target "x86_64-unknown-linux-musl"

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)
    on_exit(fn -> Application.put_env(:hal_c2, :home, previous) end)
    File.mkdir_p!(Installation.managed_dir())
    :ok
  end

  test "an active record whose version is a path does not run a Codex outside the install" do
    # A whole package beside the managed directory, whose records name the crafted version.
    version = "../elsewhere"
    package(Path.join(Installation.managed_dir(), version), version)
    File.write!(active(), JSON.encode!(%{"version" => version}))

    assert {:error, _} = Installation.active()
  end

  test "an active record naming a whole package inside the install is the managed Codex" do
    dir = package(Path.join(Installation.managed_dir(), "0.166.0"), "0.166.0")
    File.write!(active(), ~s({"version":"0.166.0"}))

    assert {:ok, %{version: "0.166.0", executable: executable}} = Installation.active()
    assert executable == Path.join(dir, "bin/codex")
  end

  test "no active record means no managed Codex" do
    assert Installation.active() == :none
  end

  defp active, do: Path.join(Installation.managed_dir(), "active.json")

  defp package(dir, version) do
    for name <- ["bin/codex", "bin/codex-code-mode-host", "codex-path/rg"] do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    manifest = %{
      "layoutVersion" => 1,
      "version" => version,
      "target" => @target,
      "entrypoint" => "bin/codex"
    }

    File.write!(Path.join(dir, "codex-package.json"), JSON.encode!(manifest))

    File.write!(
      Path.join(dir, ".install-complete.json"),
      JSON.encode!(%{"version" => version, "target" => @target})
    )

    dir
  end
end
