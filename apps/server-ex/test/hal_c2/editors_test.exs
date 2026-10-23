defmodule HalC2.EditorsTest do
  # Changes the :os_type app env and PATH, which every launch reads.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # A fake `open` on PATH that reports its arguments to this test over TCP.
  setup %{tmp_dir: dir} do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    script = Path.join(bin, "open")

    File.write!(script, """
    #!/usr/bin/env bash
    exec 3<>/dev/tcp/127.0.0.1/#{port}
    printf '%s\\x1f' "$@" >&3
    printf '\\n' >&3
    """)

    File.chmod!(script, 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    Application.put_env(:hal_c2, :os_type, {:unix, :darwin})

    on_exit(fn ->
      System.put_env("PATH", path)
      Application.delete_env(:hal_c2, :os_type)
    end)

    %{launches: socket}
  end

  defp file_manager(target, socket) do
    assert {:ok, nil} = HalC2.Editors.open(%{"cwd" => target, "editor" => "file-manager"})
    {:ok, conn} = :gen_tcp.accept(socket, 5_000)
    {:ok, line} = :gen_tcp.recv(conn, 0, 5_000)
    :gen_tcp.close(conn)
    line |> String.trim_trailing("\n") |> String.split("\x1f", trim: true)
  end

  test "a link to a folder is revealed, not followed", %{tmp_dir: dir, launches: socket} do
    real = Path.join(dir, "Tool.app")
    File.mkdir_p!(real)
    link = Path.join(dir, "docs")
    File.ln_s!(real, link)

    assert file_manager(link <> "/", socket) == ["-R", link]
  end

  test "a path through `..` is checked where it leads", %{tmp_dir: dir, launches: socket} do
    File.mkdir_p!(Path.join(dir, "Tool.app"))
    File.mkdir_p!(Path.join(dir, "project"))

    assert file_manager(Path.join(dir, "project/../Tool.app"), socket) ==
             ["-R", Path.join(dir, "Tool.app")]
  end
end
