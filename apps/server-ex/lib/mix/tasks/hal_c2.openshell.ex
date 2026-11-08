defmodule Mix.Tasks.HalC2.Openshell do
  @shortdoc "Installs, checks, rotates or removes the OpenShell gateway"
  @moduledoc """
  Manages the NVIDIA OpenShell gateway review sandboxes run in
  (`HalC2.OpenShell.Command`):

      mix hal_c2.openshell install [--archive FILE] [--drain]
      mix hal_c2.openshell status
      mix hal_c2.openshell check
      mix hal_c2.openshell rotate [--drain]
      mix hal_c2.openshell reuse https://HOST:PORT --ca FILE --cert FILE --key FILE
      mix hal_c2.openshell uninstall [--drain]
      mix hal_c2.openshell reap

  An installed MC has the same commands as `hal-c2-service openshell ...`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case HalC2.OpenShell.Command.command(args) do
      {:ok, text} -> Mix.shell().info(text)
      {:error, message} -> Mix.raise(message)
    end
  end
end
