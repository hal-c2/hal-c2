defmodule Mix.Tasks.T3.Connect do
  @shortdoc "Shows or turns off this node's T3 Connect setup"
  @moduledoc """
  The operator's side of T3 Connect on the host (`t3 connect`, `apps/server/src/cli/connect.ts`):

      mix t3.connect status     # the saved sign-in and link settings
      mix t3.connect unlink     # stops exposing the node; the sign-in stays
      mix t3.connect logout     # unlinks and forgets the sign-in

  `status` reads what is saved; it does not test whether the node is reachable.
  `unlink` and `logout` stop a running node's tunnel through its own
  `/api/connect/unlink`, revoke the link at the relay, and clear the saved link.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:exqlite, :inets, :crypto])

    case args do
      ["status"] -> Mix.shell().info(status())
      ["unlink"] -> disconnect(false)
      ["logout"] -> disconnect(true)
      _ -> Mix.raise("Usage: mix t3.connect status | unlink | logout")
    end
  end

  defp status do
    alias T3.Connect.Secrets

    desired = T3.Connect.desired_link() != nil
    signed_in = Secrets.get("cloud-cli-oauth-token") != nil
    linked = Secrets.get("cloud-linked-user-id") != nil

    provisioned =
      cond do
        linked -> "provisioned"
        desired and signed_in -> "pending server startup"
        true -> "not provisioned"
      end

    next =
      cond do
        not signed_in -> "Run `t3 connect link` to authorize and enable T3 Connect."
        not desired -> "Run `t3 connect link` to enable T3 Connect."
        not linked -> "Start T3 to provision the environment link and launch its managed tunnel."
        true -> nil
      end

    Enum.join(
      [
        "T3 Connect",
        "  Exposure: #{if desired, do: "enabled", else: "disabled"}",
        "  Authorization: #{if signed_in, do: "stored credential", else: "missing"}",
        "  Environment link: #{provisioned}",
        "  Relay: #{Secrets.get("cloud-relay-url") || "not provisioned"}",
        "  Publish agent activity: #{if T3.Connect.publishing?(), do: "enabled", else: "disabled"}"
      ] ++
        relay_client(T3.Connect.RelayClient.resolve()) ++
        [
          "",
          "This is saved setup, not a live connection check. Check the background service with `t3 service status`."
        ] ++ if(next, do: ["", "Next: " <> next], else: []),
      "\n"
    )
  end

  defp relay_client(%{"status" => "available"} = client) do
    source =
      %{"path" => "PATH", "managed" => "managed install"}[client["source"]] ||
        "configured override"

    [
      "  Relay client: available via #{source}",
      "    Path: #{client["executablePath"]}",
      "    Version: #{client["version"]}"
    ]
  end

  defp relay_client(%{"status" => "unsupported"} = client),
    do: [
      "  Relay client: unsupported on #{client["platform"]}-#{client["arch"]}",
      "    Managed version: #{client["version"]}"
    ]

  defp relay_client(_), do: ["  Relay client: not installed"]

  defp disconnect(sign_out?) do
    alias T3.Connect.Secrets

    Secrets.delete("cloud-cli-desired-link")
    live = live_unlink()
    relay = relay_unlink()
    T3.Connect.forget_link()
    if sign_out?, do: Secrets.delete("cloud-cli-oauth-token")

    if live == :failed do
      Mix.shell().error(
        "T3 Connect is disabled, but the running server could not stop its tunnel.\nRestart that server to stop the connector."
      )
    else
      Mix.shell().info("T3 Connect is disabled locally.")
    end

    case relay do
      :revoked ->
        Mix.shell().info("Revoked the relay-side environment record.")

      {:error, _} when sign_out? ->
        Mix.shell().error(
          "Could not revoke the relay-side environment record before signing out.\nThe stored CLI authorization was still removed locally."
        )

      {:error, _} ->
        Mix.shell().error(
          "Could not revoke the relay-side environment record yet.\nRun `t3 connect unlink` again when the relay is reachable."
        )

      _ ->
        :ok
    end

    if sign_out?,
      do:
        Mix.shell().info(
          "Signed out of T3 Connect locally.\nThe background service is managed separately with `t3 service`."
        )
  end

  # A node running on this host stops its tunnel through its own API, as the
  # operator, with a session minted from its store.
  defp live_unlink do
    base = "http://127.0.0.1:#{Application.get_env(:t3, :port, 3780)}"
    store = Path.join(Application.fetch_env!(:t3, :home), "t3.sqlite")

    with {:ok, _} <-
           :httpc.request(
             :get,
             {~c"#{base}/.well-known/t3/environment", []},
             [timeout: 5_000],
             []
           ),
         credential = T3.Auth.create_pairing_token(store, admin: true),
         {:ok, {{_, 200, _}, _, reply}} <-
           :httpc.request(
             :post,
             {~c"#{base}/oauth/token", [], ~c"application/x-www-form-urlencoded",
              URI.encode_query(%{
                "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token_type" => "urn:t3:params:oauth:token-type:environment-bootstrap",
                "subject_token" => credential,
                "client_label" => "t3 connect"
              })},
             [timeout: 5_000],
             body_format: :binary
           ),
         {:ok, %{"access_token" => access}} <- JSON.decode(reply),
         {:ok, {{_, 200, _}, _, _}} <-
           :httpc.request(
             :post,
             {~c"#{base}/api/connect/unlink", [{~c"authorization", ~c"Bearer #{access}"}],
              ~c"application/json", "{}"},
             [timeout: 5_000],
             []
           ) do
      :succeeded
    else
      {:error, {:failed_connect, _}} -> :not_running
      _ -> :failed
    end
  end

  defp relay_unlink do
    with token when is_binary(token) <- T3.Connect.cli_token(),
         url when is_binary(url) <- T3.Connect.relay_url() do
      id = URI.encode(T3.Environment.id(), &URI.char_unreserved?/1)

      case T3.Connect.relay(:delete, "#{url}/v1/client/environment-links/#{id}", token, nil) do
        {:ok, %{"ok" => true}} -> :revoked
        {:ok, _} -> :not_linked
        error -> {:error, error}
      end
    else
      _ -> :not_signed_in
    end
  end
end
