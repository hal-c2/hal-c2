defmodule Mix.Tasks.T3.Pair do
  @shortdoc "Prints a one-time pairing URL for this node"
  @moduledoc """
  Mints a pairing token (valid 5 minutes, single use) and prints the URL a client
  opens or pastes to pair with this node:

      mix t3.pair [BASE_URL]

  `BASE_URL` defaults to the node's own address (`T3.Web.base_url/1`), such as
  `http://127.0.0.1:3780`, or the LAN or tailnet address it was bound to.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:exqlite)
    base = List.first(args) || T3.Web.base_url()
    token = T3.Auth.create_pairing_token(T3.Store.home_path())
    Mix.shell().info("#{String.trim_trailing(base, "/")}/?token=#{token}")
  end
end
