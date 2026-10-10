defmodule Mix.Tasks.HalC2.Auth do
  @shortdoc "Lists or revokes the clients paired with this MC"
  @moduledoc """
  Manages the sessions of clients paired with this MC, the list Settings →
  Connections shows, from the command line:

      mix hal_c2.auth session list
      mix hal_c2.auth session revoke SESSION_ID

  Works next to a running MC: it reads and writes the MC's store directly.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:exqlite)
    store = HalC2.Store.home_path()

    case args do
      ["session", "list"] ->
        for client <- HalC2.Auth.list_sessions(store) do
          Mix.shell().info(
            Enum.join(
              [
                client["sessionId"],
                client["client"]["label"] || "-",
                client["client"]["deviceType"],
                Enum.join(client["scopes"], ","),
                client["expiresAt"]
              ],
              "\t"
            )
          )
        end

      ["session", "revoke", id] ->
        if HalC2.Auth.revoke_session(store, id),
          do: Mix.shell().info("Revoked #{id}."),
          else: Mix.raise("No session #{id}.")

      _ ->
        Mix.raise(
          "Usage: mix hal_c2.auth session list | mix hal_c2.auth session revoke SESSION_ID"
        )
    end
  end
end
