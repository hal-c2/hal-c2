defmodule HalC2.OpenShell.Command do
  @moduledoc """
  `hal-c2-service openshell ...` and `mix hal_c2.openshell ...`:

      install [--archive FILE] [--drain] [--force]
                                           install, update or repair the pinned gateway
      status                               what is installed and what to fix
      check                                run the install's smoke test again
      rotate [--drain] [--force]           issue new certificates and restart on them
      reuse URL --ca FILE --cert FILE --key FILE
                                           use a gateway you run yourself
      uninstall [--drain] [--force]        remove the gateway (or forget a reused one)
      reap [--root DIR]                    delete review sandboxes past their time (the
                                           reaper's timer runs it every minute, naming
                                           the OpenShell directory it was written for)
      run --script FILE [--archive FILE]   (dev) stage it, and write the line that runs
                                           it in the foreground to FILE

  `docs/user/openshell.md` explains each, and the problem codes `status` prints.
  """

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Install
  alias HalC2.OpenShell.Manifest
  alias HalC2.OpenShell.Platform

  require Logger

  @usage """
  usage: hal-c2-service openshell install [--archive FILE] [--drain] [--force]
         hal-c2-service openshell status | check
         hal-c2-service openshell rotate [--drain] [--force]
         hal-c2-service openshell reuse https://HOST:PORT --ca FILE --cert FILE --key FILE
         hal-c2-service openshell uninstall [--drain] [--force]
         hal-c2-service openshell reap [--root DIR]\
  """

  @doc "Runs a subcommand and prints its outcome; exits 1 on failure."
  def main(args) do
    case command(args) do
      {:ok, text} ->
        IO.puts(text)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc "A subcommand as `{:ok, text}` or `{:error, message}`."
  # `--script` is the dev task's own temporary file.
  # sobelow_skip ["Traversal.FileModule"]
  def command(args) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl, :grpc, :exile])

    case OptionParser.parse(args,
           strict: [
             archive: :string,
             drain: :boolean,
             force: :boolean,
             ca: :string,
             cert: :string,
             key: :string,
             root: :string,
             script: :string
           ]
         ) do
      {opts, ["install"], []} ->
        run(:install, Keyword.take(opts, [:archive, :drain, :force]))

      # The dev run (`mise run openshell`): stages the gateway, and writes the line
      # that runs it in the foreground to the script the task then executes.
      {opts, ["run"], []} ->
        with script when is_binary(script) <- opts[:script] || {:error, @usage},
             {:ok, _} <-
               Install.install([service: false] ++ Keyword.take(opts, [:archive, :drain, :force])),
             {:ok, line} <- Install.foreground_command(),
             :ok <- File.write(script, line <> "\n") do
          {:ok, "OpenShell staged; starting it in the foreground."}
        end

      {_opts, ["status"], []} ->
        {:ok, format_status(Install.status())}

      {_opts, ["check"], []} ->
        run(:check, [])

      {opts, ["rotate"], []} ->
        run(:rotate, Keyword.take(opts, [:drain, :force]))

      {opts, ["reuse", endpoint], []} ->
        with {:ok, _} <- Install.reuse(endpoint, Keyword.take(opts, [:ca, :cert, :key])),
             do: {:ok, "This MC now uses the OpenShell gateway at #{endpoint}."}

      {opts, ["reap"], []} ->
        with :ok <- reaps_here(opts[:root]), do: reap()

      {opts, ["uninstall"], []} ->
        run(:uninstall, Keyword.take(opts, [:drain, :force]))

      _ ->
        {:error, @usage}
    end
  end

  @doc """
  One of the lifecycle commands Settings runs too (`HalC2.OpenShell.Operations`), as
  `{:ok, text}` or `{:error, message}`: `:install` (also update and repair), `:check`,
  `:rotate` or `:uninstall`, with the options `HalC2.OpenShell.Install` takes for it.
  """
  def run(:install, opts) do
    with {:ok, state} <- Install.install(opts) do
      verb =
        if state["previous"], do: "updated from #{state["previous"]} to", else: "installed,"

      {:ok,
       "OpenShell #{verb} #{state["version"]}, listening on #{state["endpoint"]}. Log: #{OpenShell.log_path()}"}
    end
  end

  def run(:check, opts) do
    with :ok <- Install.check(opts), do: {:ok, "OpenShell passed its checks."}
  end

  def run(:rotate, opts) do
    with {:ok, state} <- Install.rotate(opts) do
      if state["mode"] == "foreground",
        do:
          {:ok,
           "OpenShell's certificates were replaced. Start the dev gateway again (`mise run openshell`) to use them."},
        else: {:ok, "OpenShell's certificates were replaced, and the gateway restarted on them."}
    end
  end

  def run(:uninstall, opts) do
    with :ok <- Install.uninstall(opts), do: {:ok, "OpenShell removed."}
  end

  # A reaper's unit names the OpenShell directory of the home it was written for. One
  # whose environment no longer reaches that home reaps nothing rather than another
  # home's gateway.
  defp reaps_here(nil), do: :ok

  defp reaps_here(root) do
    if (HalC2.Paths.canonical(root) || Path.expand(root)) == OpenShell.root(),
      do: :ok,
      else:
        {:error,
         "[reaper-wrong-home] This reaper was written for the HAL-C2 home whose OpenShell directory is #{root}, but it reached #{OpenShell.root()}, so it reaped nothing. Run `hal-c2-service openshell install` from that home again to rewrite its reaper."}
  end

  # Only this MC's own sandboxes are listed and deleted, so a shared gateway is no
  # reason to leave them running.
  defp reap do
    case OpenShell.Client.connect_unchecked() do
      {:ok, conn} ->
        result = HalC2.OpenShell.Review.reap(conn, System.os_time(:second))
        OpenShell.Client.disconnect(conn)

        case result do
          {:ok, []} ->
            {:ok, "No review sandbox is past its time."}

          {:ok, names} ->
            {:ok, "Deleted review sandboxes past their time: #{Enum.join(names, ", ")}"}

          {:error, {:not_deleted, deleted, failed}} ->
            left = Enum.map_join(failed, "; ", &left_behind/1)
            done = if deleted == [], do: "", else: " Deleted: #{Enum.join(deleted, ", ")}."
            {:error, "Reaping review sandboxes left some behind: #{left}.#{done}"}
        end

      {:error, :not_installed} ->
        {:ok, "OpenShell is not installed; no review sandbox to reap."}

      {:error, reason} ->
        {:error, "Reaping review sandboxes failed: #{inspect(reason)}"}
    end
  end

  defp left_behind({kind, why}) when is_atom(kind), do: "#{kind} not listed: #{inspect(why)}"
  defp left_behind({name, why}), do: "#{name}: #{inspect(why)}"

  @doc "What `status` prints for an `HalC2.OpenShell.Install.status/0`."
  def format_status(status) do
    headline =
      cond do
        status["mode"] == nil -> "OpenShell: not installed"
        status["problems"] == [] -> "OpenShell: ready"
        true -> "OpenShell: installed, needs attention"
      end

    details =
      [
        status["mode"] &&
          "  Gateway: #{status["mode"]} #{status["version"]} at #{status["endpoint"]}",
        status["health"] &&
          "  Health: #{status["health"]["status"]}, version #{status["health"]["version"]}",
        status["service"] && status["service"]["unitPath"] &&
          "  Unit: #{status["service"]["unitPath"]}",
        status["mode"] == "managed" && "  Log: #{OpenShell.log_path()}"
      ]
      |> Enum.filter(&is_binary/1)

    problems = for code <- status["problems"], do: "  [#{code}] #{problem_message(code)}"
    Enum.join([headline | details] ++ problems, "\n")
  end

  # `status/0` asks the container runtime, the service manager and the gateway, each
  # bounded on its own; this caps the whole, so a settings page is answered either way.
  @status_timeout 20_000

  @doc """
  `server.getOpenShellStatus`: `HalC2.OpenShell.Install.status/0` as a client's
  settings show it: each problem's message names the Settings action that fixes it
  (`settings_problem_message/2`), and `actions` are the operations Settings offers
  (`settings_actions/1`, run by `HalC2.OpenShell.Operations`). `sandboxMachines`
  are the connected machines of the cluster that can run review sandboxes now
  (`machines`, `HalC2.OpenShell.Review.machines/0`), where code review sends a review
  that needs one while this machine can't run it. Read when a client asks, never
  pushed. `{:error, %{"_tag" => "ServerOpenShellStatusError"}}` when it
  takes longer than `timeout` ms, or fails; a failure's details go to the MC's log,
  not the client.
  """
  def settings_status(
        status \\ &Install.status/0,
        timeout \\ @status_timeout,
        machines \\ &HalC2.OpenShell.Review.machines/0
      ) do
    # Asked alongside the status, each peer bounded by the multicall's own timeout.
    machines = Task.async(fn -> machines.() end)
    # Caught inside the task: it is linked, so a raise would take the RPC down with it.
    task =
      Task.async(fn ->
        try do
          {:ok, status.()}
        catch
          kind, reason -> {:failed, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:failed, failure}} ->
        Task.shutdown(machines, :brutal_kill)
        Logger.error("OpenShell's status failed for settings: " <> failure)

        {:error,
         %{
           "_tag" => "ServerOpenShellStatusError",
           "message" =>
             "OpenShell's status could not be read; the MC's log says why. Refresh to try again."
         }}

      {:ok, {:ok, status}} ->
        actions = settings_actions(status)
        label = install_label(status, actions)

        {:ok,
         %{
           "supported" => status["supported"],
           "ready" => status["mode"] != nil and status["problems"] == [],
           "mode" => status["mode"],
           "version" => status["version"],
           "pinnedVersion" => Manifest.version(),
           "problems" =>
             for(
               code <- status["problems"],
               do: %{"code" => code, "message" => settings_problem_message(code, label)}
             ),
           "actions" => actions,
           "sandboxMachines" => Task.await(machines, :infinity)
         }}

      _ ->
        Task.shutdown(machines, :brutal_kill)

        {:error,
         %{
           "_tag" => "ServerOpenShellStatusError",
           "message" =>
             "OpenShell's status did not answer within #{div(timeout, 1000)} seconds. Refresh to try again."
         }}
    end
  end

  # What no install fixes: OpenShell has no build for this host.
  @host_problems ~w(intel-mac unsupported-os unsupported-arch glibc-too-old kernel-too-old
                    landlock-missing)

  @doc """
  The operations Settings offers for a status, as `[%{"operation", "label"}]`:
  Install where OpenShell can be installed and is not; Update or Repair while a
  gateway this MC runs needs it; Check, Rotate certificates and Uninstall for one
  it runs; Check and Stop using it for a user's own gateway (`reuse`).
  """
  def settings_actions(status) do
    problems = status["problems"]

    case status["mode"] do
      nil ->
        if Enum.any?(problems, &(&1 in @host_problems)),
          do: [],
          else: [action("install", "Install")]

      "managed" ->
        repair =
          cond do
            "update-available" in problems -> [action("install", "Update")]
            problems != [] -> [action("install", "Repair")]
            true -> []
          end

        repair ++
          [
            action("check", "Check"),
            action("rotate", "Rotate certificates"),
            action("uninstall", "Uninstall")
          ]

      "foreground" ->
        [
          action("check", "Check"),
          action("rotate", "Rotate certificates"),
          action("uninstall", "Uninstall")
        ]

      "external" ->
        [action("check", "Check"), action("uninstall", "Stop using it")]
    end
  end

  defp action(operation, label), do: %{"operation" => operation, "label" => label}

  # Settings offers no install for a dev run's gateway: it is updated by running
  # the dev run again (`foreground_command/0`), which a client cannot do.
  defp install_label(%{"mode" => "foreground"}, _actions), do: :dev_run

  defp install_label(_status, actions),
    do: Enum.find_value(actions, "Install", &(&1["operation"] == "install" && &1["label"]))

  @doc """
  What a status problem means and what to do in Settings, where `label` is the
  install action's (Install, Update or Repair), or `:dev_run` for a dev run's
  gateway, which Settings offers no install for; the CLI's wording is
  `problem_message/1`.
  """
  def settings_problem_message("not-installed", _label), do: "Press Install to install it."

  def settings_problem_message("update-available", :dev_run),
    do:
      "This MC pins OpenShell #{Manifest.version()}. Stop the dev gateway, then run `mise run openshell` again to update it."

  def settings_problem_message("update-available", label),
    do: "This MC pins OpenShell #{Manifest.version()}. Press #{label} to update."

  def settings_problem_message("service-missing", label),
    do: "The gateway's service is gone. Press #{label} to put it back."

  def settings_problem_message("service-not-ours", label),
    do:
      "The service under this home's name runs another HAL-C2 home's gateway, so this MC leaves it alone. If no HAL-C2 home uses it, remove its unit on the MC's machine, then #{press(label)}."

  def settings_problem_message("home-moved", label),
    do:
      "OpenShell was installed when this HAL-C2 home was at another path, and that path's gateway service is still there. Stop and remove it, or run the MC from the path it was installed at, then #{press(label)}."

  def settings_problem_message("service-outdated", label),
    do: "The gateway's service is not the one this MC writes. Press #{label} to rewrite it."

  def settings_problem_message("service-stopped", label),
    do: "The gateway's service is not running. Its log says why; #{label} restarts it."

  def settings_problem_message("gateway-shared", _label),
    do:
      "Another HAL-C2 environment has sandboxes on this gateway, so this MC makes none there. Give each environment a gateway of its own."

  def settings_problem_message("podman-missing", label),
    do:
      "No rootless Podman socket. Install Podman 5 or later with your distribution's package manager, then #{press(label)}: it starts Podman's socket for you."

  def settings_problem_message(code, _label), do: problem_message(code)

  defp press(:dev_run), do: "run `mise run openshell` again"
  defp press(label), do: "press #{label}"

  @doc """
  A lifecycle command's error as Settings shows it: `%{"code", "message",
  "sandboxes", "drain"}`, its first problem's code, each line's message worded for
  Settings (the CLI's names flags and commands), and for `sandboxes-running` (or
  `sandboxes-changed`, when they are not the ones confirmed) how many this MC has
  on the gateway, which a client names when it asks before stopping them, and
  their names, which it sends back as `drain` once its user said yes.
  """
  def settings_error(message) do
    lines = message |> String.split("\n", trim: true) |> Enum.map(&settings_line/1)
    drain = Enum.find_value(lines, &elem(&1, 2))

    %{
      "code" => Enum.find_value(lines, &elem(&1, 0)),
      "message" => lines |> Enum.map(&elem(&1, 1)) |> Enum.join("\n"),
      "sandboxes" => drain && length(drain),
      "drain" => drain
    }
  end

  defp settings_line(line) do
    case Regex.run(~r/^\[([a-z0-9-]+)\] (.*)$/s, line) do
      [_, code, text] -> {code, settings_text(code, text), sandboxes(code, text)}
      nil -> {nil, String.replace(line, Install.offline_hint(), settings_offline_hint()), nil}
    end
  end

  # The names `HalC2.OpenShell.Install` lists in parentheses.
  defp sandboxes(code, text) when code in ["sandboxes-running", "sandboxes-changed"] do
    case Regex.run(~r/on the gateway \(([^()]+)\)/, text) do
      [_, names] -> String.split(names, ", ")
      nil -> nil
    end
  end

  defp sandboxes(_code, _text), do: nil

  defp settings_text("sandboxes-running", text),
    do: on_gateway(sandboxes("sandboxes-running", text))

  defp settings_text("sandboxes-changed", text),
    do:
      "The running reviews changed since you confirmed. " <>
        on_gateway(sandboxes("sandboxes-changed", text))

  defp settings_text("sandboxes-unknown", text),
    do:
      String.replace(
        text,
        "Try again once it answers, or pass --force to go ahead.",
        "Try again once it answers, or go ahead anyway."
      )

  defp settings_text("external", text),
    do:
      String.replace(
        text,
        "Run `hal-c2-service openshell uninstall` first to install one of its own.",
        "Press Stop using it first, then Install to run one of its own."
      )

  defp settings_text("not-installed", _text), do: "OpenShell is not installed. Press Install."

  defp settings_text("busy", _text),
    do: "Another OpenShell command is running on this MC's home. Try again once it finishes."

  defp settings_text(code, text) do
    if Platform.problem_message(code) == text,
      do: settings_problem_message(code, "Install"),
      else: String.replace(text, Install.offline_hint(), settings_offline_hint())
  end

  defp on_gateway([_]),
    do:
      "1 of this MC's review sandboxes is on the gateway. Going ahead deletes it, which stops its review; or let it finish first."

  defp on_gateway(names) when is_list(names),
    do:
      "#{length(names)} of this MC's review sandboxes are on the gateway. Going ahead deletes them, which stops their reviews; or let them finish first."

  defp on_gateway(nil),
    do:
      "This MC's review sandboxes are on the gateway. Going ahead deletes them, which stops their reviews; or let them finish first."

  defp settings_offline_hint,
    do:
      " Without network access, copy the archive to the MC's machine and install it there with `hal-c2-service openshell install --archive <file>`; it is checked against the same hash."

  @doc "What a status problem means and what to do about it."
  def problem_message("not-installed"),
    do: "Run `hal-c2-service openshell install` to install it."

  def problem_message("update-available"),
    do:
      "This MC pins OpenShell #{Manifest.version()}. Run `hal-c2-service openshell install` to update."

  def problem_message("service-missing"),
    do: "The gateway's service is gone. Run `hal-c2-service openshell install` to repair it."

  def problem_message("service-not-ours"),
    do:
      "The service under this home's name runs another HAL-C2 home's gateway, so this MC leaves it alone. If no HAL-C2 home uses it, remove its unit, then run `hal-c2-service openshell install`."

  def problem_message("home-moved"),
    do:
      "OpenShell was installed when this HAL-C2 home was at another path, and that path's gateway service is still there. Stop and remove it, or run the MC from the path it was installed at, then run `hal-c2-service openshell install`."

  def problem_message("service-outdated"),
    do:
      "The gateway's service is not the one this MC writes. Run `hal-c2-service openshell install` to repair it."

  def problem_message("service-stopped"),
    do:
      "The gateway's service is not running. Its log says why; `hal-c2-service openshell install` restarts it."

  def problem_message("gateway-unreachable"),
    do: "The gateway does not answer over mTLS."

  def problem_message("gateway-unhealthy"), do: "The gateway reports itself unhealthy."

  def problem_message("gateway-shared"),
    do:
      "Another HAL-C2 environment has sandboxes on this gateway, so this MC makes none there. Give each environment a gateway of its own (`hal-c2-service openshell install`)."

  def problem_message("version-mismatch"),
    do: "The gateway runs another version than the #{Manifest.version()} this MC pins."

  def problem_message(code), do: Platform.problem_message(code)
end
