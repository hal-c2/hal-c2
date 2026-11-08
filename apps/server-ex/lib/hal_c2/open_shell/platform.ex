defmodule HalC2.OpenShell.Platform do
  @moduledoc """
  Where the MC runs OpenShell, and why not anywhere else. It fails closed: a
  platform outside this matrix, or one it cannot check, is refused with the reason.

  | Host                         | Runtime                                     |
  | ---------------------------- | ------------------------------------------- |
  | Linux x86_64 or aarch64      | rootless Podman 5 or later (the default)    |
  | glibc 2.28+, kernel 6.2+,    | or a rootless Docker daemon the user names  |
  | Landlock enabled             | (`HAL_C2_OPENSHELL_DOCKER_SOCKET`)          |
  | macOS on Apple Silicon       | Docker Desktop 28 or later                  |

  The runtime's socket goes to the gateway and to nothing else. A root Docker
  daemon's socket is refused even when named: whoever holds it holds the machine.

  `check/1` decides from facts; `facts/0` gathers them from this machine, probing
  the runtime's API over its socket. Tests hand `check/1` facts, and the app env's
  `:openshell_facts` stands in for `facts/0`.
  """

  @min_glibc {2, 28}
  @min_kernel {6, 2}
  @min_podman 5
  @min_docker 28
  @root_docker_sockets ["/var/run/docker.sock", "/run/docker.sock"]

  @doc """
  `{:ok, %{target, driver, socket}}`: the gateway archive (`HalC2.OpenShell.Manifest`)
  and compute driver to use, and the runtime socket the gateway gets; or
  `{:error, problems}`, codes `problem_message/1` explains.
  """
  def check(facts) do
    case host(facts) do
      {:ok, target} ->
        case runtime(facts) do
          {:ok, driver, socket} -> {:ok, %{target: target, driver: driver, socket: socket}}
          {:error, problems} -> {:error, problems}
        end

      {:error, problems} ->
        {:error, problems}
    end
  end

  defp host(%{os: :linux} = facts) do
    problems =
      []
      |> add(facts.arch not in ["x86_64", "aarch64"], "unsupported-arch")
      |> add(not at_least?(facts.glibc, @min_glibc), "glibc-too-old")
      |> add(not at_least?(facts.kernel, @min_kernel), "kernel-too-old")
      |> add(facts.landlock != true, "landlock-missing")

    if problems == [], do: {:ok, "#{facts.arch}-unknown-linux-gnu"}, else: {:error, problems}
  end

  defp host(%{os: :darwin, arch: "aarch64"}), do: {:ok, "aarch64-apple-darwin"}
  defp host(%{os: :darwin}), do: {:error, ["intel-mac"]}
  defp host(_facts), do: {:error, ["unsupported-os"]}

  defp runtime(%{os: os, runtime: runtime}) do
    case {os, runtime} do
      {_, nil} ->
        {:error, [if(os == :darwin, do: "docker-desktop-missing", else: "podman-missing")]}

      {_, %{reachable: false}} ->
        {:error, ["runtime-unreachable"]}

      {:linux, %{kind: :podman} = r} ->
        problems =
          []
          |> add(not owned?(r), "runtime-not-rootless")
          |> add(r.rootless != true, "runtime-not-rootless")
          |> add(major(r.version) < @min_podman, "podman-too-old")
          |> Enum.uniq()

        if problems == [], do: {:ok, "podman", r.socket}, else: {:error, problems}

      {:linux, %{kind: :docker} = r} ->
        problems =
          []
          |> add(r.socket in @root_docker_sockets or not owned?(r), "root-docker")
          |> add(r.rootless != true, "root-docker")
          |> add(major(r.version) < @min_docker, "docker-too-old")
          |> Enum.uniq()

        if problems == [], do: {:ok, "docker", r.socket}, else: {:error, problems}

      {:darwin, %{kind: :docker} = r} ->
        problems =
          []
          |> add(r.desktop != true or not owned?(r), "docker-desktop-missing")
          |> add(major(r.version) < @min_docker, "docker-too-old")
          |> Enum.uniq()

        if problems == [], do: {:ok, "docker", r.socket}, else: {:error, problems}

      _ ->
        {:error, ["unsupported-runtime"]}
    end
  end

  defp add(problems, true, code), do: problems ++ [code]
  defp add(problems, false, _code), do: problems

  defp owned?(%{owner_uid: owner, uid: uid}), do: is_integer(owner) and owner == uid

  defp at_least?(nil, _min), do: false
  defp at_least?(version, min), do: Tuple.to_list(version) >= Tuple.to_list(min)

  defp major(nil), do: 0

  defp major(version) do
    case Integer.parse(version) do
      {major, _} -> major
      :error -> 0
    end
  end

  @doc "What a `check/1` problem means and what the user can do about it."
  def problem_message("unsupported-os"),
    do: "OpenShell runs on Linux and on macOS with Apple Silicon only."

  def problem_message("unsupported-arch"),
    do: "OpenShell's gateway is built for x86_64 and aarch64 Linux only."

  def problem_message("intel-mac"),
    do:
      "OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta."

  def problem_message("glibc-too-old"),
    do:
      "OpenShell's gateway needs glibc 2.28 or newer (Ubuntu 20.04, RHEL 8, Fedora 32 or later)."

  def problem_message("kernel-too-old"),
    do: "OpenShell's sandboxes need Linux 6.2 or newer, for Landlock ABI 3."

  def problem_message("landlock-missing"),
    do:
      "Landlock is not enabled in this kernel (/sys/kernel/security/lsm does not list it). Add `landlock` to the kernel's `lsm=` boot parameter."

  def problem_message("podman-missing"),
    do:
      "No rootless Podman socket. Install Podman 5 or later and run `systemctl --user enable --now podman.socket` as your own user, or name a rootless Docker daemon's socket in HAL_C2_OPENSHELL_DOCKER_SOCKET."

  def problem_message("podman-too-old"), do: "OpenShell needs Podman 5 or later."

  def problem_message("runtime-not-rootless"),
    do:
      "The Podman socket is not your own rootless one. OpenShell's gateway only gets a runtime that runs as you."

  def problem_message("root-docker"),
    do:
      "That Docker daemon runs as root, and whoever holds its socket holds the machine. Run a rootless Docker daemon for OpenShell (dockerd-rootless-setuptool.sh) and name its socket, or use rootless Podman."

  def problem_message("docker-too-old"), do: "OpenShell needs Docker 28 or later."

  def problem_message("docker-desktop-missing"),
    do:
      "Docker Desktop is not running. Install Docker Desktop 28 or later and start it; OpenShell's sandboxes run in its Linux VM."

  def problem_message("runtime-unreachable"),
    do: "The container runtime's socket does not answer. Start the runtime, then try again."

  def problem_message("unsupported-runtime"),
    do: "That container runtime is not supported here."

  def problem_message(code), do: code

  # --- facts -------------------------------------------------------------------------

  @doc "The facts `check/1` decides from, gathered from this machine."
  def facts do
    case Application.get_env(:hal_c2, :openshell_facts) do
      nil -> gather()
      facts -> facts
    end
  end

  defp gather do
    os =
      case :os.type() do
        {:unix, :linux} -> :linux
        {:unix, :darwin} -> :darwin
        _ -> :other
      end

    arch =
      case :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") do
        ["arm64" | _] -> "aarch64"
        [arch | _] -> arch
      end

    base = %{os: os, arch: arch}

    case os do
      :linux ->
        Map.merge(base, %{
          glibc: glibc(),
          kernel: kernel(),
          landlock: landlock(),
          runtime: linux_runtime()
        })

      :darwin ->
        socket = Path.join([HalC2.Paths.user_home(), ".docker", "run", "docker.sock"])
        Map.put(base, :runtime, probe_runtime(:docker, socket))

      _ ->
        base
    end
  end

  defp glibc do
    with {out, 0} <- cmd("getconf", ["GNU_LIBC_VERSION"]),
         [_, major, minor] <- Regex.run(~r/glibc (\d+)\.(\d+)/, out) do
      {String.to_integer(major), String.to_integer(minor)}
    else
      _ -> nil
    end
  end

  defp kernel do
    case :os.version() do
      {major, minor, _} -> {major, minor}
      _ -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp landlock do
    case File.read("/sys/kernel/security/lsm") do
      {:ok, text} -> "landlock" in String.split(String.trim(text), ",")
      _ -> nil
    end
  end

  # Docker only when the user named its socket; otherwise their own Podman's.
  defp linux_runtime do
    case System.get_env("HAL_C2_OPENSHELL_DOCKER_SOCKET") do
      socket when socket not in [nil, ""] ->
        probe_runtime(:docker, socket)

      _ ->
        case System.get_env("XDG_RUNTIME_DIR") do
          dir when dir not in [nil, ""] ->
            probe_runtime(:podman, Path.join([dir, "podman", "podman.sock"]))

          _ ->
            nil
        end
    end
  end

  @doc false
  # sobelow_skip ["Traversal.FileModule"]
  def probe_runtime(kind, socket) do
    with {:ok, %File.Stat{type: :other, uid: owner}} <- File.lstat(socket) do
      base = %{kind: kind, socket: socket, owner_uid: owner, uid: uid()}

      case runtime_info(kind, socket) do
        {:ok, info} -> Map.merge(base, Map.put(info, :reachable, true))
        :error -> Map.merge(base, %{reachable: false, version: nil, rootless: nil})
      end
    else
      _ -> nil
    end
  end

  # Podman serves its own API only under a version prefix (its unversioned `/info`
  # is the Docker-compatible one, without `host.security`). v5.0.0 is the oldest
  # Podman `check/1` accepts.
  defp runtime_info(:podman, socket) do
    with {:ok, %{"Version" => version}} <- get_json(socket, "/version"),
         {:ok, %{"host" => %{"security" => security}}} <-
           get_json(socket, "/v5.0.0/libpod/info") do
      {:ok, %{version: version, rootless: security["rootless"] == true}}
    else
      _ -> :error
    end
  end

  defp runtime_info(:docker, socket) do
    with {:ok, %{"Version" => version}} <- get_json(socket, "/version"),
         {:ok, %{} = info} <- get_json(socket, "/info") do
      {:ok,
       %{
         version: version,
         rootless: "name=rootless" in (info["SecurityOptions"] || []),
         desktop: info["OperatingSystem"] == "Docker Desktop"
       }}
    else
      _ -> :error
    end
  end

  # One GET over the runtime's Unix socket, bounded: a runtime that hangs is down.
  # Passive mode, so nothing reaches the caller's mailbox.
  defp get_json(socket, path) do
    with {:ok, conn} <-
           Mint.HTTP1.connect(:http, {:local, socket}, 0,
             hostname: "localhost",
             mode: :passive,
             transport_opts: [timeout: 2_000]
           ),
         {:ok, conn, ref} <- Mint.HTTP1.request(conn, "GET", path, [], nil),
         {:ok, body} <- read_body(conn, ref, [], 0) do
      Jason.decode(body)
    else
      _ -> :error
    end
  end

  # A runtime's answer is a few KiB; anything past 4 MiB or 20 reads is not one.
  defp read_body(conn, _ref, _acc, reads) when reads > 20, do: close(conn, :error)

  defp read_body(conn, ref, acc, reads) do
    case Mint.HTTP1.recv(conn, 0, 5_000) do
      {:ok, conn, responses} ->
        acc = [acc | for({:data, ^ref, data} <- responses, do: data)]

        cond do
          IO.iodata_length(acc) > 4_194_304 ->
            close(conn, :error)

          Enum.any?(responses, &match?({:done, ^ref}, &1)) ->
            close(conn, {:ok, IO.iodata_to_binary(acc)})

          true ->
            read_body(conn, ref, acc, reads + 1)
        end

      {:error, conn, _reason, _responses} ->
        close(conn, :error)
    end
  end

  defp close(conn, result) do
    Mint.HTTP1.close(conn)
    result
  end

  defp uid do
    case cmd("id", ["-u"]) do
      {out, 0} -> String.to_integer(String.trim(out))
      _ -> nil
    end
  end

  # Fixed tool names looked up on PATH, with fixed arguments.
  # sobelow_skip ["CI.System"]
  defp cmd(exe, args) do
    case System.find_executable(exe) do
      nil -> :error
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end
end
