defmodule HalC2.OpenShell.Platform do
  @moduledoc """
  Where the MC runs OpenShell, and why not anywhere else. It fails closed: a
  platform outside this matrix, or one it cannot check, is refused with the reason.

  | Host                         | Runtime                                     |
  | ---------------------------- | ------------------------------------------- |
  | Linux x86_64 or aarch64      | rootless Podman 5 or later                  |
  | glibc 2.28+, kernel 6.2+,    |                                             |
  | Landlock enabled             |                                             |
  | macOS on Apple Silicon       | Docker Desktop 28 or later                  |

  Either runtime must be able to hold a sandbox to its CPU, memory and process
  limits: cgroup v2, with the cpu, memory and pids controllers its containers get.
  A rootless runtime on cgroup v1, or without those controllers delegated, would
  start sandboxes with no limits at all.

  The runtime's socket goes to the gateway and to nothing else. The runtime is told
  by what answers on the socket, not by its name: a Podman behind the socket named
  in `HAL_C2_OPENSHELL_DOCKER_SOCKET` is checked, and driven, as Podman.
  `DOCKER_HOST` is not read. A Docker daemon on Linux is refused: a root one's
  socket is the machine, a rootless one's containers run in RootlessKit's network
  namespace, where the gateway's loopback is not, and Docker Desktop's daemon runs
  as root in a VM OpenShell's Linux driver does not expect.

  `check/1` decides from facts; `facts/0` gathers them from this machine, probing
  the runtime's API over its socket. Tests hand `check/1` facts, and the app env's
  `:openshell_facts` stands in for `facts/0`.
  """

  @min_glibc {2, 28}
  @min_kernel {6, 2}
  @min_podman 5
  @min_docker 28
  @root_docker_sockets ["/var/run/docker.sock", "/run/docker.sock"]
  # What OpenShell's drivers limit a sandbox by: its CPU quota, memory and pids.
  @controllers ["cpu", "memory", "pids"]

  @doc """
  `{:ok, %{target, driver, socket, network}}`: the gateway archive
  (`HalC2.OpenShell.Manifest`) and compute driver to use, the runtime socket the
  gateway gets, and how the Docker driver's supervisors reach the gateway (`nil` for
  Podman); or `{:error, problems}`, codes `problem_message/1` explains.

  Docker Desktop runs the supervisors in its VM, whose host network is not the
  Mac's unless the user turned on Desktop's host networking, so they run on a bridge
  and reach the gateway as `host.docker.internal`.
  """
  def check(facts) do
    case host(facts) do
      {:ok, target} ->
        case runtime(facts) do
          {:ok, driver, socket} ->
            {:ok,
             %{target: target, driver: driver, socket: socket, network: network(facts, driver)}}

          {:error, problems} ->
            {:error, problems}
        end

      {:error, problems} ->
        {:error, problems}
    end
  end

  defp network(_facts, "podman"), do: nil
  defp network(%{os: :darwin}, "docker"), do: "bridge"

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

      {_, %{missing: true}} ->
        {:error, ["docker-socket-missing"]}

      {_, %{reachable: false}} ->
        {:error, ["runtime-unreachable"]}

      {:linux, %{kind: :docker, desktop: true}} ->
        {:error, ["docker-desktop-linux"]}

      {:linux, %{kind: :podman} = r} ->
        problems =
          []
          |> add(not owned?(r), "runtime-not-rootless")
          |> add(r.rootless != true, "runtime-not-rootless")
          |> add(major(r.version) < @min_podman, "podman-too-old")
          |> Enum.uniq()
          |> Kernel.++(limits(r))

        if problems == [], do: {:ok, "podman", r.socket}, else: {:error, problems}

      # OpenShell's Docker driver dials the gateway on 127.0.0.1 from the host's
      # network, which under rootless Docker is RootlessKit's namespace, and refuses a
      # bridge to a gateway bound to loopback only.
      {:linux, %{kind: :docker} = r} ->
        root = r.socket in @root_docker_sockets or not owned?(r) or r.rootless != true
        {:error, [if(root, do: "root-docker", else: "rootless-docker")]}

      {:darwin, %{kind: :docker} = r} ->
        problems =
          []
          |> add(r.desktop != true or not owned?(r), "docker-desktop-missing")
          |> add(major(r.version) < @min_docker, "docker-too-old")
          |> Enum.uniq()
          |> Kernel.++(limits(r))

        if problems == [], do: {:ok, "docker", r.socket}, else: {:error, problems}

      {:darwin, %{kind: :podman}} ->
        {:error, ["podman-on-mac"]}

      _ ->
        {:error, ["unsupported-runtime"]}
    end
  end

  # What the runtime said it can limit (`probe_runtime/2`); a runtime that said
  # nothing is not taken at its word.
  defp limits(%{cgroup: %{version: 2, controllers: controllers}}) do
    if Enum.all?(@controllers, &(&1 in controllers)),
      do: [],
      else: ["cgroup-controllers-missing"]
  end

  defp limits(%{cgroup: %{version: 1}}), do: ["cgroup-v1"]
  defp limits(_runtime), do: ["cgroup-unknown"]

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
      "No rootless Podman socket. Install Podman 5 or later and run `systemctl --user enable --now podman.socket` as your own user."

  def problem_message("podman-too-old"), do: "OpenShell needs Podman 5 or later."

  def problem_message("runtime-not-rootless"),
    do:
      "The Podman socket is not your own rootless one. OpenShell's gateway only gets a runtime that runs as you."

  def problem_message("root-docker"),
    do:
      "That Docker daemon runs as root, and whoever holds its socket holds the machine. Use rootless Podman, and unset HAL_C2_OPENSHELL_DOCKER_SOCKET."

  def problem_message("rootless-docker"),
    do:
      "OpenShell's sandboxes cannot reach its gateway through rootless Docker: the gateway listens on this machine's loopback only, and rootless Docker's containers run in a network namespace of their own. Use rootless Podman, and unset HAL_C2_OPENSHELL_DOCKER_SOCKET."

  def problem_message("cgroup-v1"),
    do:
      "The container runtime runs on cgroup v1, where it cannot hold a rootless container to CPU, memory and process limits, so sandboxes would run without any. Boot with cgroup v2 (the default on current distributions; `systemd.unified_cgroup_hierarchy=1` on the kernel command line), or update Docker Desktop."

  def problem_message("cgroup-controllers-missing"),
    do:
      "The container runtime cannot set CPU, memory and process limits for your containers: it needs the cpu, memory and pids cgroup controllers. On Linux, delegate them to your user (a drop-in for user@.service with `Delegate=cpu cpuset io memory pids`), then log in again."

  def problem_message("cgroup-unknown"),
    do:
      "The container runtime did not say which resource limits it can enforce, so OpenShell's sandboxes could run without them. Update the runtime, then try again."

  def problem_message("docker-too-old"), do: "OpenShell needs Docker 28 or later."

  def problem_message("docker-socket-missing"),
    do:
      "HAL_C2_OPENSHELL_DOCKER_SOCKET does not name a Unix socket. Give the path of your rootless Podman's socket (a `unix://` prefix is fine, a symlink is not), or unset it to use the default one."

  def problem_message("docker-desktop-linux"),
    do:
      "That is Docker Desktop for Linux, whose daemon runs as root in its own VM; OpenShell's Linux driver is not run against it. Use rootless Podman."

  def problem_message("podman-on-mac"),
    do:
      "That socket is Podman's. On macOS OpenShell runs on Docker Desktop only: install and start Docker Desktop 28 or later."

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

  # Docker only when the user named its socket; otherwise their own Podman's. A
  # named socket that is not there is reported as such, never passed over for
  # Podman's.
  defp linux_runtime do
    case System.get_env("HAL_C2_OPENSHELL_DOCKER_SOCKET") do
      socket when socket not in [nil, ""] ->
        named_runtime(socket)

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
  # The runtime behind a socket the user named, as `DOCKER_HOST` would name it.
  def named_runtime("unix://" <> socket), do: named_runtime(socket)

  def named_runtime(socket) do
    probe_runtime(:docker, socket) || %{kind: :docker, socket: socket, missing: true}
  end

  @doc false
  # A socket file itself (a symlink is not followed), and the runtime that answers
  # on it, which may not be the `kind` it was looked for as.
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
         {:ok, %{"host" => %{"security" => security} = host}} <-
           get_json(socket, "/v5.0.0/libpod/info") do
      cgroup =
        case host do
          %{"cgroupVersion" => "v" <> v, "cgroupControllers" => c} when is_list(c) ->
            cgroup(v, c)

          _ ->
            nil
        end

      {:ok, %{version: version, rootless: security["rootless"] == true, cgroup: cgroup}}
    else
      _ -> :error
    end
  end

  # Podman's Docker-compatible API names itself among the version's components.
  defp runtime_info(:docker, socket) do
    with {:ok, %{"Version" => version} = about} <- get_json(socket, "/version"),
         false <- podman?(about),
         {:ok, %{} = info} <- get_json(socket, "/info") do
      # Docker reports what it can limit rather than its controllers; with no
      # cgroup driver it limits nothing.
      controllers =
        for {flag, controller} <- [
              {"CpuCfsQuota", "cpu"},
              {"MemoryLimit", "memory"},
              {"PidsLimit", "pids"}
            ],
            info[flag] == true and info["CgroupDriver"] != "none",
            do: controller

      {:ok,
       %{
         version: version,
         rootless: "name=rootless" in (info["SecurityOptions"] || []),
         desktop: info["OperatingSystem"] == "Docker Desktop",
         cgroup: cgroup(info["CgroupVersion"], controllers)
       }}
    else
      true ->
        with {:ok, info} <- runtime_info(:podman, socket),
             do: {:ok, Map.put(info, :kind, :podman)}

      _ ->
        :error
    end
  end

  defp cgroup(version, controllers) when version in ["1", "2"],
    do: %{version: String.to_integer(version), controllers: controllers}

  defp cgroup(_version, _controllers), do: nil

  defp podman?(%{"Components" => components}) when is_list(components),
    do: Enum.any?(components, &match?(%{"Name" => "Podman Engine"}, &1))

  defp podman?(_about), do: false

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
      {:error, %Mint.HTTP1{} = conn, _reason} -> close(conn, :error)
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
