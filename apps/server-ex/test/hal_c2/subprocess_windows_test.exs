defmodule HalC2.SubprocessWindowsTest do
  use ExUnit.Case, async: false

  test "a .cmd runs through cmd.exe under a Windows os type" do
    dir = Path.join(System.tmp_dir!(), "win-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    shim = Path.join(dir, "cmd.exe")
    File.write!(shim, "#!/bin/sh\nshift\nexec \"$@\"\n")
    File.chmod!(shim, 0o755)
    cmd = Path.join(dir, "codex.cmd")
    fake = Path.expand("test/support/fake_codex.py")

    File.write!(
      cmd,
      "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"codex-cli 0.50.0\"; exit 0; fi\nexec python3 -u #{fake} \"$@\"\n"
    )

    File.chmod!(cmd, 0o755)
    System.put_env("PATH", "#{dir}:#{System.get_env("PATH")}")
    Application.put_env(:hal_c2, :os_type, {:win32, :nt})
    on_exit(fn -> Application.delete_env(:hal_c2, :os_type) end)

    assert {:ok, conn} =
             HalC2.JsonRpc.Connection.start_link(
               cmd: [cmd, "app-server"],
               handler: self(),
               program: "Codex App Server"
             )

    result =
      HalC2.JsonRpc.Connection.call(
        conn,
        "initialize",
        %{"clientInfo" => %{"name" => "t"}},
        5_000
      )

    IO.inspect(result, label: "initialize")
    assert {:ok, _} = result
    HalC2.JsonRpc.Connection.stop(conn)
  end
end
