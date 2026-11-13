defmodule Mix.Tasks.HalC2.Auth do
  @shortdoc "Lists, issues or revokes the access this MC has handed out"
  @moduledoc """
  Manages the access of this MC, what Settings → Connections shows, from the command
  line:

      mix hal_c2.auth session list
      mix hal_c2.auth session issue SUBJECT [--token | --json]
      mix hal_c2.auth session revoke SESSION_ID
      mix hal_c2.auth pairing list
      mix hal_c2.auth pairing revoke PAIRING_ID

  `session issue` makes an administrative session for a headless client such as CI:
  it prints the bearer token the client signs in with (`--token` prints only that, for a
  script to capture, `--json` a JSON document). Pairing links are minted with
  `mix hal_c2.pair`.

  Works with the MC running or stopped: it reads and writes the MC's store directly,
  except that a revoke goes through the running MC (over its HTTP port with its access
  token), which closes the revoked session's sockets at once and tells the clients
  showing Connections. With no MC answering, it revokes in the store.
  Bearer tokens and pairing tokens of what already exists are never printed, as the
  store keeps only their hashes.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:exqlite)
    store = HalC2.Store.home_path()
    {opts, rest, invalid} = OptionParser.parse(args, strict: [token: :boolean, json: :boolean])
    if invalid != [], do: usage()

    case rest do
      ["session", "list"] ->
        list_sessions(store)

      ["session", "issue", subject] ->
        issue(store, subject, opts)

      ["session", "revoke", id] ->
        revoked =
          through_mc("/api/auth/clients/revoke", %{"sessionId" => id}, "revoked") ||
            HalC2.Auth.revoke_session(store, id)

        revoke(revoked, id, "session")

      ["pairing", "list"] ->
        list_pairing(store)

      ["pairing", "revoke", id] ->
        revoked =
          through_mc("/api/auth/pairing-links/revoke", %{"id" => id}, "revoked") ||
            HalC2.Auth.revoke_pairing_link(store, id)

        revoke(revoked, id, "pairing")

      _ ->
        usage()
    end
  end

  defp usage, do: Mix.raise(@moduledoc |> String.split("\n\n") |> Enum.at(1) |> String.trim())

  defp list_sessions(store) do
    case HalC2.Auth.list_sessions(store) do
      [] ->
        Mix.shell().info("No active sessions.")

      clients ->
        for client <- clients do
          Mix.shell().info(
            Enum.join(
              [
                client["sessionId"],
                client["client"]["label"] || "unlabeled client",
                client["method"],
                client["subject"],
                Enum.join(client["scopes"], ","),
                "issued #{client["issuedAt"]}",
                "expires #{client["expiresAt"]}",
                "last connected #{client["lastConnectedAt"] || "never"}"
              ],
              "\t"
            )
          )
        end
    end
  end

  defp list_pairing(store) do
    case HalC2.Auth.pairing_links(store) do
      [] ->
        Mix.shell().info("No active pairing credentials.")

      links ->
        for link <- links do
          Mix.shell().info(
            Enum.join(
              [
                link["id"],
                link["label"] || "unlabeled link",
                Enum.join(link["scopes"], ","),
                "expires #{link["expiresAt"]}"
              ],
              "\t"
            )
          )
        end
    end
  end

  defp issue(store, subject, opts) do
    session = HalC2.Auth.issue_session(store, subject)

    cond do
      opts[:token] ->
        Mix.shell().info(session.token)

      opts[:json] ->
        Mix.shell().info(
          JSON.encode!(%{
            "id" => session.id,
            "token" => session.token,
            "scopes" => session.scopes,
            "subject" => subject,
            "expiresAt" => session.expires_at
          })
        )

      true ->
        Mix.shell().info("Session #{session.id} for #{subject}, expires #{session.expires_at}")
        Mix.shell().info(session.token)
    end
  end

  # `key` of the running MC's answer to `POST path`, or nil when no MC of this home
  # answers (none has run, it is stopped, or another program holds the port), for the
  # caller to do the work in the store instead. The token goes only to a listener that
  # proved it holds it (`HalC2.Web.local_mc/2`); an MC this tool does not reach still
  # drops a session revoked in the store within its next session recheck. An MC that
  # answers `false` found nothing to revoke; the store then says the same.
  defp through_mc(path, body, key) do
    with {:ok, base, token} <- HalC2.Web.local_mc(),
         request =
           {~c"#{base}#{path}", [{~c"authorization", ~c"Bearer #{token}"}], ~c"application/json",
            JSON.encode!(body)},
         {:ok, {{_, 200, _}, _, reply}} <-
           :httpc.request(:post, request, [timeout: 10_000], body_format: :binary),
         {:ok, %{^key => true}} <- JSON.decode(reply) do
      true
    else
      _ -> nil
    end
  end

  defp revoke(true, id, "session"), do: Mix.shell().info("#{id}: the session was revoked")

  defp revoke(false, id, "session"),
    do: Mix.shell().info("#{id}: no active session has that id")

  defp revoke(true, id, "pairing"),
    do: Mix.shell().info("#{id}: the pairing credential was revoked")

  defp revoke(false, id, "pairing"),
    do: Mix.shell().info("#{id}: no active pairing credential has that id")
end
