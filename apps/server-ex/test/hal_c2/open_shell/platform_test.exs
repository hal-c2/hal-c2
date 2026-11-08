defmodule HalC2.OpenShell.PlatformTest do
  use ExUnit.Case, async: true

  alias HalC2.OpenShell.Platform

  @moduletag :tmp_dir

  @uid 1000

  defp linux(overrides \\ %{}) do
    Map.merge(
      %{
        os: :linux,
        arch: "x86_64",
        glibc: {2, 39},
        kernel: {6, 8},
        landlock: true,
        runtime: podman()
      },
      overrides
    )
  end

  defp podman(overrides \\ %{}) do
    Map.merge(
      %{
        kind: :podman,
        socket: "/run/user/1000/podman/podman.sock",
        owner_uid: @uid,
        uid: @uid,
        reachable: true,
        version: "5.2.1",
        rootless: true
      },
      overrides
    )
  end

  defp docker(overrides) do
    Map.merge(
      %{
        kind: :docker,
        socket: "/run/user/1000/docker.sock",
        owner_uid: @uid,
        uid: @uid,
        reachable: true,
        version: "28.1.0",
        rootless: true,
        desktop: false
      },
      overrides
    )
  end

  describe "check/1" do
    test "Linux with rootless Podman picks the target for its architecture" do
      assert {:ok, %{target: "x86_64-unknown-linux-gnu", driver: "podman", socket: socket}} =
               Platform.check(linux())

      assert socket == podman().socket

      assert {:ok, %{target: "aarch64-unknown-linux-gnu"}} =
               Platform.check(linux(%{arch: "aarch64"}))
    end

    test "each host requirement fails with its own code" do
      assert {:error, ["unsupported-arch"]} = Platform.check(linux(%{arch: "riscv64"}))
      assert {:error, ["glibc-too-old"]} = Platform.check(linux(%{glibc: {2, 27}}))
      assert {:error, ["glibc-too-old"]} = Platform.check(linux(%{glibc: nil}))
      assert {:error, ["kernel-too-old"]} = Platform.check(linux(%{kernel: {6, 1}}))
      assert {:error, ["landlock-missing"]} = Platform.check(linux(%{landlock: false}))
      assert {:error, ["landlock-missing"]} = Platform.check(linux(%{landlock: nil}))

      assert {:error, ["glibc-too-old", "kernel-too-old"]} =
               Platform.check(linux(%{glibc: {2, 17}, kernel: {5, 15}}))
    end

    test "Podman must be the user's own, rootless and 5 or later" do
      assert {:error, ["podman-missing"]} = Platform.check(linux(%{runtime: nil}))

      assert {:error, ["runtime-unreachable"]} =
               Platform.check(linux(%{runtime: podman(%{reachable: false})}))

      assert {:error, ["runtime-not-rootless"]} =
               Platform.check(linux(%{runtime: podman(%{rootless: false})}))

      assert {:error, ["runtime-not-rootless"]} =
               Platform.check(linux(%{runtime: podman(%{owner_uid: 0})}))

      assert {:error, ["podman-too-old"]} =
               Platform.check(linux(%{runtime: podman(%{version: "4.9.4"})}))
    end

    test "a root Docker daemon is refused, even when its socket is named" do
      for socket <- ["/var/run/docker.sock", "/run/docker.sock"] do
        assert {:error, ["root-docker"]} =
                 Platform.check(linux(%{runtime: docker(%{socket: socket})}))
      end

      assert {:error, ["root-docker"]} =
               Platform.check(linux(%{runtime: docker(%{rootless: false})}))

      assert {:error, ["root-docker"]} =
               Platform.check(linux(%{runtime: docker(%{owner_uid: 0})}))

      assert {:error, ["docker-too-old"]} =
               Platform.check(linux(%{runtime: docker(%{version: "27.5.1"})}))

      assert {:ok, %{driver: "docker", socket: "/run/user/1000/docker.sock"}} =
               Platform.check(linux(%{runtime: docker(%{})}))
    end

    test "macOS needs Apple Silicon and Docker Desktop" do
      desktop =
        docker(%{desktop: true, rootless: false, socket: "/Users/me/.docker/run/docker.sock"})

      assert {:ok, %{target: "aarch64-apple-darwin", driver: "docker"}} =
               Platform.check(%{os: :darwin, arch: "aarch64", runtime: desktop})

      assert {:error, ["intel-mac"]} =
               Platform.check(%{os: :darwin, arch: "x86_64", runtime: desktop})

      assert {:error, ["docker-desktop-missing"]} =
               Platform.check(%{os: :darwin, arch: "aarch64", runtime: nil})

      assert {:error, ["docker-desktop-missing"]} =
               Platform.check(%{
                 os: :darwin,
                 arch: "aarch64",
                 runtime: %{desktop | desktop: false}
               })
    end

    test "every other OS, and Podman on macOS, is unsupported" do
      assert {:error, ["unsupported-os"]} = Platform.check(%{os: :other, arch: "x86_64"})

      assert {:error, ["unsupported-runtime"]} =
               Platform.check(%{os: :darwin, arch: "aarch64", runtime: podman()})
    end

    test "every target check/1 can pick has a pinned archive" do
      targets =
        for facts <- [
              linux(),
              linux(%{arch: "aarch64"}),
              %{os: :darwin, arch: "aarch64", runtime: docker(%{desktop: true})}
            ],
            do: elem(Platform.check(facts), 1).target

      assert Enum.sort(targets) == Enum.sort(HalC2.OpenShell.Manifest.targets())
    end

    test "every problem code has a message" do
      codes =
        ~w(unsupported-os unsupported-arch intel-mac glibc-too-old kernel-too-old landlock-missing
           podman-missing podman-too-old runtime-not-rootless root-docker docker-too-old
           docker-desktop-missing runtime-unreachable unsupported-runtime)

      for code <- codes, do: refute(Platform.problem_message(code) == code, code)
    end
  end

  describe "probe_runtime/2" do
    test "reads a rootless Podman's version over its socket", %{tmp_dir: dir} do
      socket =
        serve(dir, %{
          "/version" => %{"Version" => "5.2.1"},
          "/libpod/info" => %{"host" => %{"security" => %{"rootless" => true}}}
        })

      assert %{kind: :podman, version: "5.2.1", rootless: true, reachable: true} =
               probe = Platform.probe_runtime(:podman, socket)

      assert probe.owner_uid == probe.uid
    end

    test "reads Docker's rootless and Desktop flags", %{tmp_dir: dir} do
      socket =
        serve(dir, %{
          "/version" => %{"Version" => "28.1.0"},
          "/info" => %{
            "SecurityOptions" => ["name=seccomp", "name=rootless"],
            "OperatingSystem" => "Ubuntu"
          }
        })

      assert %{version: "28.1.0", rootless: true, desktop: false} =
               Platform.probe_runtime(:docker, socket)
    end

    test "a socket that answers nonsense is unreachable, and a missing one is no runtime", %{
      tmp_dir: dir
    } do
      socket = serve(dir, %{})
      assert %{reachable: false, version: nil} = Platform.probe_runtime(:podman, socket)
      assert Platform.probe_runtime(:podman, Path.join(dir, "absent.sock")) == nil

      File.write!(Path.join(dir, "file.sock"), "")
      assert Platform.probe_runtime(:podman, Path.join(dir, "file.sock")) == nil
    end
  end

  # A runtime API on a Unix socket: one JSON document per path, 404 otherwise.
  # A socket path must fit in 108 bytes, so it goes in a short directory relative to
  # the working directory rather than in `dir`.
  defp serve(_dir, routes) do
    short = Path.join("tmp", "os-#{System.unique_integer([:positive])}")
    File.mkdir_p!(short)
    on_exit(fn -> File.rm_rf(short) end)
    path = Path.join(short, "r.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: :http_bin])

    test = self()

    pid =
      spawn_link(fn ->
        send(test, :listening)
        accept(listen, routes)
      end)

    receive do
      :listening -> :ok
    end

    on_exit(fn -> Process.exit(pid, :kill) end)
    path
  end

  defp accept(listen, routes) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, {:http_request, :GET, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0)
    skip_headers(socket)

    {status, body} =
      case routes[path] do
        nil -> {"404 Not Found", "not found"}
        doc -> {"200 OK", Jason.encode!(doc)}
      end

    :ok = :inet.setopts(socket, packet: :raw)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])

    :gen_tcp.close(socket)
    accept(listen, routes)
  end

  defp skip_headers(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, :http_eoh} -> :ok
      {:ok, _header} -> skip_headers(socket)
    end
  end
end
