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
    {:ok, _} = Application.ensure_all_started([:inets, :ssl, :grpc])

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
        with {:ok, state} <- Install.install(Keyword.take(opts, [:archive, :drain, :force])) do
          verb =
            if state["previous"], do: "updated from #{state["previous"]} to", else: "installed,"

          {:ok,
           "OpenShell #{verb} #{state["version"]}, listening on #{state["endpoint"]}. Log: #{OpenShell.log_path()}"}
        end

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
        with :ok <- Install.check(), do: {:ok, "OpenShell passed its checks."}

      {opts, ["rotate"], []} ->
        with {:ok, state} <- Install.rotate(Keyword.take(opts, [:drain, :force])) do
          if state["mode"] == "foreground",
            do:
              {:ok,
               "OpenShell's certificates were replaced. Start the dev gateway again (`mise run openshell`) to use them."},
            else:
              {:ok, "OpenShell's certificates were replaced, and the gateway restarted on them."}
        end

      {opts, ["reuse", endpoint], []} ->
        with {:ok, _} <- Install.reuse(endpoint, Keyword.take(opts, [:ca, :cert, :key])),
             do: {:ok, "This MC now uses the OpenShell gateway at #{endpoint}."}

      {opts, ["reap"], []} ->
        with :ok <- reaps_here(opts[:root]), do: reap()

      {opts, ["uninstall"], []} ->
        with :ok <- Install.uninstall(Keyword.take(opts, [:drain, :force])),
             do: {:ok, "OpenShell removed."}

      _ ->
        {:error, @usage}
    end
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
            left = Enum.map_join(failed, "; ", fn {name, why} -> "#{name}: #{inspect(why)}" end)
            done = if deleted == [], do: "", else: " Deleted: #{Enum.join(deleted, ", ")}."
            {:error, "Reaping review sandboxes left some behind: #{left}.#{done}"}

          {:error, reason} ->
            {:error, "Reaping review sandboxes failed: #{inspect(reason)}"}
        end

      {:error, :not_installed} ->
        {:ok, "OpenShell is not installed; no review sandbox to reap."}

      {:error, reason} ->
        {:error, "Reaping review sandboxes failed: #{inspect(reason)}"}
    end
  end

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
