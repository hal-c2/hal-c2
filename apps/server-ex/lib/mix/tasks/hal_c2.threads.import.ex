defmodule Mix.Tasks.HalC2.Threads.Import do
  @shortdoc "Picks threads from T3 Code or an older HAL-C2 and imports them"
  @moduledoc """
  Lists the threads of a T3 Code or Node HAL-C2 install on this machine and imports
  the ones you pick into the running MC (`HalC2.Import.Picker`).

      mix hal_c2.threads.import
      mix hal_c2.threads.import --release

  With `--release` the threads go to the installed MC on this machine instead of
  the one run from a checkout; that MC has the same picker of its own as
  `hal-c2-service threads import`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [release: :boolean])
    Mix.Task.run("app.config")

    # A checkout's own home is the dev profile; the installed MC's is the user's.
    if opts[:release] && Application.get_env(:hal_c2, :home) == :dev,
      do: Application.delete_env(:hal_c2, :home)

    case HalC2.Import.Picker.run() do
      {:ok, lines} -> Enum.each(lines, &Mix.shell().info(&1))
      {:error, message} -> Mix.raise(message)
    end
  end
end
