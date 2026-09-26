defmodule HalC2.Service do
  @moduledoc """
  The node as a background service for the operator's user (`hal-c2 service`,
  `apps/server/src/cloud/bootService.ts`): a systemd user unit on Linux, a
  LaunchAgent on macOS. The unit runs the release's `bin/hal-c2-service` (or
  `mix hal_c2.server` from a checkout) with this node's home.

  HAL-C2 Connect offers to install it (`mix hal_c2.connect`), but the two are managed
  separately: signing out of HAL-C2 Connect never stops or removes the service.

  `systemctl`, `loginctl` and `launchctl` are looked up as `:<exe>_command` in the
  app env first, so tests can stand in for the service manager; `:service_user_home`
  replaces the user's home directory the unit is written under.

  A release reaches it as `bin/hal-c2-service install|status|uninstall` (`main/1`), a
  checkout as `mix hal_c2.service`.
  """

  @unit "hal-c2.service"
  @label "io.github.halc2.halc2.service"

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

  @doc "`install`, `status` or `uninstall` as `{:ok, text}` or `{:error, message}`."
  def command(["install"]) do
    with {:ok, result} <- install() do
      verb = if result["previouslyInstalled"], do: "updated", else: "installed"
      {:ok, "Background service #{verb}. Logs: #{result["logPath"]}"}
    end
  end

  def command(["status"]) do
    status = status()

    {:ok,
     cond do
       not status["supported"] ->
         "Background service: not supported on this platform"

       not status["installed"] ->
         "Background service: not installed"

       status["current"] ->
         "Background service: installed\n  Unit: #{status["unitPath"]}\n  Logs: #{status["logPath"]}"

       true ->
         "Background service: installed, needs an update (run install again)"
     end}
  end

  def command(["uninstall"]) do
    with :ok <- uninstall(), do: {:ok, "Background service removed."}
  end

  def command(_), do: {:error, "usage: hal-c2-service install | status | uninstall"}

  @doc """
  `%{"supported", "installed", "current", "unitPath", "logPath"}`: whether this
  platform has a service manager, whether the unit exists, and whether it is the
  one this node would write.
  """
  def status do
    case manager() do
      nil ->
        %{"supported" => false, "installed" => false, "current" => false, "logPath" => log_path()}

      manager ->
        path = unit_path(manager)
        existing = File.read(path)

        %{
          "supported" => true,
          "installed" => match?({:ok, _}, existing),
          "current" => existing == {:ok, render(manager)},
          "unitPath" => path,
          "logPath" => log_path()
        }
    end
  end

  @doc """
  Writes the unit and starts it now and at every boot (Linux) or login (macOS).
  `{:ok, %{"previouslyInstalled" => boolean, ...status}}` or `{:error, message}`.
  """
  def install do
    with manager when manager != nil <- manager() || {:error, unsupported()} do
      before = status()
      path = unit_path(manager)
      File.mkdir_p!(Path.dirname(path))
      File.mkdir_p!(Path.dirname(log_path()))
      File.write!(path, render(manager))

      case run_all(activate(manager, path)) do
        :ok -> {:ok, Map.put(status(), "previouslyInstalled", before["installed"])}
        error -> error
      end
    end
  end

  @doc "Stops the service and removes it from startup. Projects and settings stay."
  def uninstall do
    with manager when manager != nil <- manager() || {:error, unsupported()} do
      path = unit_path(manager)

      if File.exists?(path) do
        with :ok <- run_all(deactivate(manager, path)) do
          File.rm!(path)
          if manager == :systemd, do: run_all([{"systemctl", ["--user", "daemon-reload"]}])
          :ok
        end
      else
        :ok
      end
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

  defp unit_path(:systemd), do: Path.join([user_home(), ".config", "systemd", "user", @unit])

  defp unit_path(:launchd),
    do: Path.join([user_home(), "Library", "LaunchAgents", @label <> ".plist"])

  defp log_path,
    do: Path.join([Application.fetch_env!(:hal_c2, :home), "logs", "boot-service.log"])

  # Linger keeps the user manager, and so the service, running after logout.
  defp activate(:systemd, _path) do
    user = System.get_env("USER") || System.get_env("LOGNAME") || ""

    [
      {"systemctl", ["--user", "daemon-reload"]},
      {"systemctl", ["--user", "enable", @unit]},
      {"loginctl", ["enable-linger", user]},
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

  defp deactivate(:systemd, _path), do: [{"systemctl", ["--user", "disable", "--now", @unit]}]

  defp deactivate(:launchd, _path),
    do: [{"launchctl", ["bootout", "gui/#{uid()}/#{@label}"], :ignore}]

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
      [
        "[Unit]",
        "Description=HAL-C2 server",
        "StartLimitIntervalSec=300",
        "StartLimitBurst=5",
        "",
        "[Service]",
        "Type=simple",
        "WorkingDirectory=#{quote_value(cwd)}",
        "Environment=HALC2_NODE_HOME=#{quote_value(Application.fetch_env!(:hal_c2, :home))}",
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
      ],
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
        <key>PATH</key>
        <string>#{x.(System.get_env("PATH", ""))}</string>
        <key>HALC2_NODE_HOME</key>
        <string>#{x.(Application.fetch_env!(:hal_c2, :home))}</string>
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

  defp run(exe, args) do
    command = Application.get_env(:hal_c2, :"#{exe}_command", exe)

    case System.find_executable(command) do
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
