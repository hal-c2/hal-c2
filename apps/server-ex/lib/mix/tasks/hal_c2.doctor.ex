defmodule Mix.Tasks.HalC2.Doctor do
  @shortdoc "Checks and repairs a stopped MC's store"
  @moduledoc """
  Checks the store of this home, with its MC stopped, and repairs it (`HalC2.Doctor`).

      mix hal_c2.doctor             # in a terminal, choose the repairs to make
      mix hal_c2.doctor --dry-run   # list the repairs, change nothing
      mix hal_c2.doctor --fix       # make every recommended repair
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case HalC2.Doctor.command(args) do
      {:ok, text} -> Mix.shell().info(text)
      {:error, message} -> Mix.raise(message)
    end
  end
end
