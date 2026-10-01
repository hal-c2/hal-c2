defmodule Mix.Tasks.HalC2.Theme do
  @shortdoc "Shows or sets the theme this MC's clients switch to"
  @moduledoc """
  Inspects and sets the environment's theme, as `hal-c2 theme` does for the Node server:

      mix hal_c2.theme set ID    # a built-in theme, or one in <home>/themes (nightfall.json is "nightfall")
      mix hal_c2.theme clear     # clients keep the theme they have
      mix hal_c2.theme show      # the theme and the published themes

  Connected web and desktop clients switch when it is set; each set applies once,
  so a theme a user picks afterwards sticks until the next set. It edits the MC's
  settings.json, which a running MC checks every couple of seconds.
  """

  use Mix.Task

  alias HalC2.EnvironmentThemes

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case args do
      ["set", id] ->
        done(EnvironmentThemes.set_default(id), ~s(Environment theme set to "#{id}".))

      ["clear"] ->
        done(EnvironmentThemes.clear_default(), "Environment theme cleared.")

      ["show"] ->
        show = EnvironmentThemes.show()

        Mix.shell().info(
          if show["defaultTheme"],
            do: ~s(Environment theme: "#{show["defaultTheme"]}".),
            else: "Environment theme: not set."
        )

        Mix.shell().info(
          case show["published"] do
            [] -> "Published themes: none (publish into #{show["themesDirectory"]})."
            ids -> "Published themes: #{Enum.join(ids, ", ")}."
          end
        )

      _ ->
        Mix.raise("Usage: mix hal_c2.theme set ID | clear | show")
    end
  end

  defp done(:ok, message), do: Mix.shell().info(message)
  defp done({:error, message}, _), do: Mix.raise(message)
end
