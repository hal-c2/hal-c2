defmodule HalC2.Service do
  @moduledoc """
  The MC as a background service for the operator's user (`mix hal_c2.service`):
  a systemd user unit on Linux, a LaunchAgent on macOS. The unit runs the release's
  `bin/hal-c2-service` (or
  `mix hal_c2.server` from a checkout). It names a home only when the user chose one
  (`HAL_C2_MC_HOME`, or a `HAL_C2_HOME` that is not an old home); otherwise the
  service uses the XDG directories (`HalC2.Paths`). A unit written before, by
  T3 Code or before the rename (`t3code.service`, `com.t3tools.t3code.service`,
  `io.github.halc2.halc2.service`) and with `T3CODE_HOME` or an old home in it, is
  still found by its path; `status` and `uninstall` see it, and installing again
  replaces it.

  HAL-C2 Connect offers to install it (`mix hal_c2.connect`), but the two are managed
  separately: signing out of HAL-C2 Connect never stops or removes the service.

  `systemctl`, `loginctl` and `launchctl` are looked up as `:<exe>_command` in the
  app env first, so tests can stand in for the service manager; `:service_user_home`
  replaces the user's home directory the unit is written under.

  On Linux, `status` also asks systemd whether the user manager answers, whether the
  user may linger after logout, and whether the unit is enabled and running, and
  names each problem with its fix (`problem_message/1`, the codes
  `docs/user/background-service.md` lists). `install` switches lingering on itself
  when it is only switched off, and refuses before changing anything when systemd
  cannot run user services at all. A version installed without restarting the
  service leaves a `restart-pending` marker in the state directory
  (`mark_restart_pending/1`) until the service starts on it or `restart` runs.

  A release reaches it as `bin/hal-c2-service install|status|restart|uninstall`
  (`main/1`), a checkout as `mix hal_c2.service`.
  """

  @unit "hal-c2.service"
  @label "io.github.halc2.service"
  # Units written before the rename (T3 Code's, and HAL-C2's first launchd label).
  @old_units ["t3code.service"]
  @old_labels ["com.t3tools.t3code.service", "io.github.halc2.halc2.service"]

  @doc "Runs a `bin/hal-c2-service` subcommand and prints its outcome; exits 1 on failure."
  def main(args) do
    case command(args) do
      {:ok, text} ->
        IO.puts(text)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc "`install`, `status`, `restart` or `uninstall` as `{:ok, text}` or `{:error, message}`."
  def command(["install"]) do
    with {:ok, result} <- install() do
      verb = if result["previouslyInstalled"], do: "updated", else: "installed"
      {:ok, "Background service #{verb}. Logs: #{result["logPath"]}"}
    end
  end

  def command(["status"]), do: {:ok, format_status(status())}

  def command(["restart"]) do
    case restart() do
      {:ok, true} -> {:ok, "Background service restarted."}
      {:ok, false} -> {:ok, "Background service: not installed"}
      error -> error
    end
  end

  def command(["uninstall"]) do
    with :ok <- uninstall(), do: {:ok, "Background service removed."}
  end

  def command(_), do: {:error, "usage: hal-c2-service install | status | restart | uninstall"}

  @doc "What `mix hal_c2.service status` prints for a `status/0`."
  def format_status(status) do
    cond do
      not status["supported"] ->
        "Background service: not supported on this platform"

      not status["installed"] ->
        "Background service: not installed"

      true ->
        headline =
          if status["current"],
            do: "Background service: installed",
            else: "Background service: installed, needs an update or repair"

        problems =
          for problem <- status["problems"], do: "  [#{problem}] #{problem_message(problem)}"

        next =
          if status["current"],
            do: [],
            else: ["  Next: Run `hal-c2-mc install` to repair it."]

        Enum.join(
          [headline, "  Unit: #{status["unitPath"]}", "  Logs: #{status["logPath"]}"] ++
            problems ++ next,
          "\n"
        )
    end
  end

  @doc "How to fix a status problem; `docs/user/background-service.md` lists the codes."
  def problem_message("user-manager-unavailable"),
    do:
      "Cannot reach the systemd user manager. Run `systemctl --user status` in a login session for the service user. Install your distribution's systemd user-session support if it is missing; do not run HAL-C2 with sudo."

  def problem_message("linger-unavailable"),
    do:
      ~S|Cannot check whether this user can run services after logout. Run `loginctl show-user "$(id -un)" --property=Linger` and check that systemd-logind is available.|

  def problem_message("linger-disabled"),
    do:
      ~S|Lingering is disabled. HAL-C2 will stop when your last login session ends and will not start at boot. Run `sudo loginctl enable-linger "$(id -un)"` on this machine, then retry the service command as your normal user.|

  def problem_message("service-disabled"),
    do: "The service is not enabled to start automatically. Run `hal-c2-mc install` to repair it."

  def problem_message("service-stopped"),
    do:
      "The service is not running. Check the service log and `systemctl --user status hal-c2.service`, then run `hal-c2-mc install`."

  def problem_message("restart-pending"),
    do:
      "A newer version is installed but the service is still running the previous one. Run `hal-c2-mc restart` to switch."

  @doc """
  `%{"supported", "installed", "current", "problems", "unitPath", "logPath"}`: whether
  this platform has a service manager, whether the unit exists, what keeps it from
  running (`problem_message/1`), and whether it is the one this MC would write
  with nothing in its way.
  """
  def status do
    case manager() do
      nil ->
        %{
          "supported" => false,
          "installed" => false,
          "current" => false,
          "problems" => [],
          "logPath" => log_path()
        }

      manager ->
        path = unit_path(manager)
        installed = installed(manager)
        problems = if installed == [], do: [], else: problems(manager)

        %{
          "supported" => true,
          "installed" => installed != [],
          "current" =>
            problems == [] and installed == [{name(manager), path}] and
              File.read(path) == {:ok, render(manager)},
          "problems" => problems,
          "unitPath" => if(installed == [], do: path, else: installed |> hd() |> elem(1)),
          "logPath" => log_path()
        }
    end
  end

  @doc """
  Writes the unit and starts it now and at every boot (Linux) or login (macOS).
  `{:ok, %{"previouslyInstalled" => boolean, ...status}}` or `{:error, message}`.
  """
  def install do
    with manager when manager != nil <- manager() || {:error, unsupported()},
         # A service systemd could not keep running is refused before anything changes.
         :ok <- prerequisites(manager) do
      before = status()
      path = unit_path(manager)

      # A unit from before the rename is replaced by this one.
      result =
        with :ok <- remove(manager, Enum.reject(installed(manager), &(elem(&1, 1) == path))) do
          File.mkdir_p!(Path.dirname(path))
          File.mkdir_p!(Path.dirname(log_path()))
          File.write!(path, render(manager))
          run_all(activate(manager, path))
        end

      case result do
        :ok ->
          clear_restart_pending()
          {:ok, Map.put(status(), "previouslyInstalled", before["installed"])}

        error ->
          error
      end
    end
  end

  @doc """
  Starts the installed service again, on whatever version is installed now.
  `{:ok, true}`, `{:ok, false}` when no service is installed, or `{:error, message}`.
  """
  def restart do
    with manager when manager != nil <- manager() || {:error, unsupported()} do
      path = unit_path(manager)

      if File.exists?(path) do
        with :ok <- run_all(activate(manager, path)) do
          clear_restart_pending()
          {:ok, true}
        end
      else
        {:ok, false}
      end
    end
  end

  @doc """
  Marks the running service as behind `version`, which was installed without
  restarting it. `status` reports `restart-pending` until the service starts again
  (`clear_restart_pending/0`), or `restart/0` or `install/0` runs.
  """
  def mark_restart_pending(version) do
    File.mkdir_p!(Path.dirname(restart_pending_path()))
    File.write!(restart_pending_path(), version <> "\n")
  end

  @doc "The service runs the installed version now."
  def clear_restart_pending do
    File.rm(restart_pending_path())
    :ok
  end

  defp restart_pending_path, do: Path.join(HalC2.Paths.state_dir(), ".restart-pending")

  @doc "Stops the service and removes it from startup. Projects and settings stay."
  def uninstall do
    with manager when manager != nil <- manager() || {:error, unsupported()},
         do: remove(manager, installed(manager))
  end

  defp remove(_manager, []), do: :ok

  defp remove(manager, units) do
    result =
      Enum.reduce_while(units, :ok, fn {name, path}, :ok ->
        case run_all(deactivate(manager, name)) do
          :ok -> {:cont, File.rm!(path)}
          error -> {:halt, error}
        end
      end)

    if result == :ok and manager == :systemd,
      do: run_all([{"systemctl", ["--user", "daemon-reload"]}]),
      else: result
  end

  # The units on disk as `{name, path}`, this MC's first, then any from before the rename.
  defp installed(manager) do
    for name <- [name(manager) | old_names(manager)],
        path = unit_path(manager, name),
        File.exists?(path),
        do: {name, path}
  end

  # --- problems ----------------------------------------------------------------------

  # What keeps the installed service from running.
  defp problems(:systemd), do: systemd_problems(true) ++ restart_pending()
  defp problems(:launchd), do: restart_pending()

  defp restart_pending,
    do: if(File.exists?(restart_pending_path()), do: ["restart-pending"], else: [])

  defp systemd_problems(include_service) do
    manager_up = probe("systemctl", ["--user", "show-environment"]) != :error

    linger =
      case probe("loginctl", ["show-user", uid(), "--property=Linger", "--value"]) do
        {:ok, "yes"} -> []
        {:ok, "no"} -> ["linger-disabled"]
        _ -> ["linger-unavailable"]
      end

    service =
      if include_service and manager_up do
        enabled = probe("systemctl", ["--user", "is-enabled", @unit])
        active = probe("systemctl", ["--user", "is-active", @unit])

        if(enabled == {:ok, "enabled"}, do: [], else: ["service-disabled"]) ++
          if(active == :error, do: ["service-stopped"], else: [])
      else
        []
      end

    if(manager_up, do: [], else: ["user-manager-unavailable"]) ++ linger ++ service
  end

  # A systemd that cannot run user services, or cannot say whether this user may
  # linger, is refused; lingering that is only switched off is switched on.
  defp prerequisites(:launchd), do: :ok

  defp prerequisites(:systemd) do
    problems = systemd_problems(false)

    cond do
      problems == [] ->
        :ok

      problems != ["linger-disabled"] ->
        refuse(problems -- ["linger-disabled"])

      run("loginctl", ["enable-linger", "--no-ask-password", uid()]) == :ok ->
        refuse(systemd_problems(false))

      true ->
        refuse(problems)
    end
  end

  defp refuse([]), do: :ok
  defp refuse([problem | _]), do: {:error, "[#{problem}] #{problem_message(problem)}"}

  # `{:ok, trimmed output}` when a read-only question to the service manager
  # succeeded, `:error` otherwise.
  defp probe(exe, args) do
    with path when is_binary(path) <- executable(exe),
         {out, 0} <- System.cmd(path, args) do
      {:ok, String.trim(out)}
    else
      _ -> :error
    end
  end

  # --- platform ----------------------------------------------------------------------

  defp manager do
    case Application.get_env(:hal_c2, :service_platform) || :os.type() do
      {:unix, :linux} -> :systemd
      {:unix, :darwin} -> :launchd
      _ -> nil
    end
  end

  defp unsupported, do: "Background services are supported on Linux (systemd) and macOS only."

  defp user_home, do: Application.get_env(:hal_c2, :service_user_home) || System.user_home!()

  defp name(:systemd), do: @unit
  defp name(:launchd), do: @label

  defp old_names(:systemd), do: @old_units
  defp old_names(:launchd), do: @old_labels

  defp unit_path(manager), do: unit_path(manager, name(manager))

  defp unit_path(:systemd, unit), do: Path.join([user_home(), ".config", "systemd", "user", unit])

  defp unit_path(:launchd, label),
    do: Path.join([user_home(), "Library", "LaunchAgents", label <> ".plist"])

  defp log_path, do: Path.join([HalC2.Paths.state_dir(), "logs", "boot-service.log"])

  # The home variables the user set for this process that the unit should keep:
  # `HAL_C2_MC_HOME`, or a `HAL_C2_HOME` root. An old home is never written back.
  defp chosen_home do
    for {name, kind} <- [{"HAL_C2_MC_HOME", :mc}, {"HAL_C2_HOME", :root}],
        dir = System.get_env(name),
        dir not in [nil, ""],
        HalC2.Paths.root?(dir, kind, HalC2.Paths.user_home()),
        do: {name, String.trim(dir)}
  end

  # Lingering, which keeps the user manager and so the service running after
  # logout, is a prerequisite (`prerequisites/1`).
  defp activate(:systemd, _path) do
    [
      {"systemctl", ["--user", "daemon-reload"]},
      {"systemctl", ["--user", "enable", @unit]},
      {"systemctl", ["--user", "restart", @unit]}
    ]
  end

  defp activate(:launchd, path) do
    domain = "gui/#{uid()}"

    [
      {"launchctl", ["bootout", "#{domain}/#{@label}"], :ignore},
      {"launchctl", ["bootstrap", domain, path]}
    ]
  end

  defp deactivate(:systemd, unit), do: [{"systemctl", ["--user", "disable", "--now", unit]}]

  defp deactivate(:launchd, label),
    do: [{"launchctl", ["bootout", "gui/#{uid()}/#{label}"], :ignore}]

  defp uid do
    {out, 0} = System.cmd("id", ["-u"])
    String.trim(out)
  end

  # The command the service runs; units cannot rely on the user's shell or PATH.
  defp program do
    case System.get_env("RELEASE_ROOT") do
      nil -> {[System.find_executable("mix") || "mix", "hal_c2.server"], File.cwd!()}
      root -> {[Path.join([root, "bin", "hal-c2-service"])], user_home()}
    end
  end

  defp render(:systemd) do
    {argv, cwd} = program()
    log = log_path()

    Enum.join(
      List.flatten([
        "[Unit]",
        "Description=HAL-C2 server",
        "StartLimitIntervalSec=300",
        "StartLimitBurst=5",
        "",
        "[Service]",
        "Type=simple",
        "WorkingDirectory=#{quote_value(cwd)}",
        for({name, dir} <- chosen_home(), do: "Environment=#{name}=#{quote_value(dir)}"),
        "Environment=PATH=#{quote_value(System.get_env("PATH", ""))}",
        "ExecStart=#{Enum.map_join(argv, " ", &quote_value/1)}",
        "KillMode=mixed",
        "OOMPolicy=continue",
        "Restart=always",
        "RestartSec=5",
        "StandardOutput=append:#{log}",
        "StandardError=append:#{log}",
        "",
        "[Install]",
        "WantedBy=default.target",
        ""
      ]),
      "\n"
    )
  end

  defp render(:launchd) do
    {argv, cwd} = program()

    x =
      &(&1
        |> String.replace("&", "&amp;")
        |> String.replace("<", "&lt;")
        |> String.replace(">", "&gt;"))

    log = x.(log_path())

    env =
      Enum.map_join([{"PATH", System.get_env("PATH", "")} | chosen_home()], "\n", fn {k, v} ->
        "    <key>#{k}</key>\n    <string>#{x.(v)}</string>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
    #{Enum.map_join(argv, "\n", &"    <string>#{x.(&1)}</string>")}
      </array>
      <key>EnvironmentVariables</key>
      <dict>
    #{env}
      </dict>
      <key>WorkingDirectory</key>
      <string>#{x.(cwd)}</string>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>ThrottleInterval</key>
      <integer>5</integer>
      <key>StandardOutPath</key>
      <string>#{log}</string>
      <key>StandardErrorPath</key>
      <string>#{log}</string>
    </dict>
    </plist>
    """
  end

  defp quote_value(value) do
    if String.match?(value, ~r/[\s"\\]/),
      do: ~s("#{value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}"),
      else: value
  end

  # Runs each step in order, stopping at the first failure (`:ignore` steps may fail).
  defp run_all(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      {exe, args, mode} =
        case step do
          {exe, args} -> {exe, args, :check}
          {exe, args, mode} -> {exe, args, mode}
        end

      case run(exe, args) do
        :ok -> {:cont, :ok}
        {:error, _} when mode == :ignore -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp executable(exe),
    do: System.find_executable(Application.get_env(:hal_c2, :"#{exe}_command", exe))

  defp run(exe, args) do
    case executable(exe) do
      nil ->
        {:error, "#{exe} is not available on this machine."}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, _} -> {:error, "`#{exe} #{Enum.join(args, " ")}` failed: #{String.trim(out)}"}
        end
    end
  end
end
