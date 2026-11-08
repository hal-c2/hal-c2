defmodule HalC2.OpenShell.Command do
  @moduledoc """
  `hal-c2-service openshell ...` and `mix hal_c2.openshell ...`:

      install [--archive FILE] [--drain]   install, update or repair the pinned gateway
      status                               what is installed and what to fix
      check                                run the install's smoke test again
      rotate [--drain]                     issue new certificates and restart on them
      reuse URL --ca FILE --cert FILE --key FILE
                                           use a gateway you run yourself
      uninstall [--drain]                  remove the gateway (or forget a reused one)
      run --script FILE [--archive FILE]   (dev) stage it, and write the line that runs
                                           it in the foreground to FILE

  `docs/user/openshell.md` explains each, and the problem codes `status` prints.
  """

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Install
  alias HalC2.OpenShell.Manifest
  alias HalC2.OpenShell.Platform

  @usage """
  usage: hal-c2-service openshell install [--archive FILE] [--drain]
         hal-c2-service openshell status | check
         hal-c2-service openshell rotate [--drain]
         hal-c2-service openshell reuse https://HOST:PORT --ca FILE --cert FILE --key FILE
         hal-c2-service openshell uninstall [--drain]\
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
             ca: :string,
             cert: :string,
             key: :string,
             script: :string
           ]
         ) do
      {opts, ["install"], []} ->
        with {:ok, state} <- Install.install(Keyword.take(opts, [:archive, :drain])) do
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
               Install.install([service: false] ++ Keyword.take(opts, [:archive, :drain])),
             {:ok, line} <- Install.foreground_command(),
             :ok <- File.write(script, line <> "\n") do
          {:ok, "OpenShell staged; starting it in the foreground."}
        end

      {_opts, ["status"], []} ->
        {:ok, format_status(Install.status())}

      {_opts, ["check"], []} ->
        case OpenShell.state() do
          nil -> {:error, "[not-installed] OpenShell is not installed."}
          state -> with :ok <- Install.smoke(state), do: {:ok, "OpenShell passed its checks."}
        end

      {opts, ["rotate"], []} ->
        with {:ok, _} <- Install.rotate(Keyword.take(opts, [:drain])),
             do:
               {:ok, "OpenShell's certificates were replaced, and the gateway restarted on them."}

      {opts, ["reuse", endpoint], []} ->
        with {:ok, _} <- Install.reuse(endpoint, Keyword.take(opts, [:ca, :cert, :key])),
             do: {:ok, "This MC now uses the OpenShell gateway at #{endpoint}."}

      {opts, ["uninstall"], []} ->
        with :ok <- Install.uninstall(Keyword.take(opts, [:drain])),
             do: {:ok, "OpenShell removed."}

      _ ->
        {:error, @usage}
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

  def problem_message("service-outdated"),
    do:
      "The gateway's service is not the one this MC writes. Run `hal-c2-service openshell install` to repair it."

  def problem_message("service-stopped"),
    do:
      "The gateway's service is not running. Its log says why; `hal-c2-service openshell install` restarts it."

  def problem_message("gateway-unreachable"),
    do: "The gateway does not answer over mTLS."

  def problem_message("gateway-unhealthy"), do: "The gateway reports itself unhealthy."

  def problem_message("version-mismatch"),
    do: "The gateway runs another version than the #{Manifest.version()} this MC pins."

  def problem_message(code), do: Platform.problem_message(code)
end
