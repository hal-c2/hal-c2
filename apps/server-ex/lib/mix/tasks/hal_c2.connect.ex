defmodule Mix.Tasks.HalC2.Connect do
  @shortdoc "Sets up, shows or turns off this node's HAL-C2 Connect link"
  @moduledoc """
  The operator's side of HAL-C2 Connect on the host (`hal-c2 connect`, `apps/server/src/cli/connect.ts`):

      mix hal_c2.connect            # sign in, link on next start, offer the background service
      mix hal_c2.connect login      # sign in only
      mix hal_c2.connect link       # sign in and link on next start
      mix hal_c2.connect status     # the saved sign-in and link settings
      mix hal_c2.connect unlink     # stops exposing the node; the sign-in stays
      mix hal_c2.connect logout     # unlinks and forgets the sign-in

  Signing in opens the hosted app in a browser on this machine; over SSH, or with
  `--headless`, it prints a link and a short code to approve on another device
  (`HalC2.Connect.OAuth`). The node links itself with the saved sign-in when it starts.
  `status` reads what is saved; it does not test whether the node is reachable.
  `unlink` and `logout` stop a running node's tunnel through its own
  `/api/connect/unlink`, revoke the link at the relay, and clear the saved link.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:exqlite, :inets, :crypto])

    {opts, args} = OptionParser.parse!(args, strict: [headless: :boolean])

    case args do
      [] ->
        connect(opts)

      ["login"] ->
        login(opts)

      ["link"] ->
        link(opts)

      ["status"] ->
        Mix.shell().info(status())

      ["unlink"] ->
        disconnect(false)

      ["logout"] ->
        disconnect(true)

      _ ->
        Mix.raise("Usage: mix hal_c2.connect [login | link | status | unlink | logout] [--headless]")
    end
  end

  defp connect(opts) do
    Mix.shell().info("HAL-C2 Connect\n")

    with {:ok, identity} <- link_environment(opts) do
      # Show which account was linked before the machine is brought online.
      Mix.shell().info("✓ Authorized#{as(identity)}")

      if offer_service() do
        Mix.shell().info(
          if match?({:unix, :darwin}, Application.get_env(:hal_c2, :service_platform, :os.type())),
            do:
              "\n✓ Background service ready\n\nHAL-C2 is set to run while you are logged in to this Mac. The server establishes the HAL-C2 Connect link on startup.",
            else:
              "\n✓ Background service ready\n\nHAL-C2 is set to keep running after you log out. The server establishes the HAL-C2 Connect link on startup."
        )
      else
        Mix.shell().info(
          "\nNext\n  Start the server with `mix hal_c2.server` to make this machine reachable."
        )
      end
    end
  end

  defp login(opts) do
    Mix.shell().info("HAL-C2 Connect\n")
    with {:ok, identity} <- authorize(opts), do: Mix.shell().info("✓ Signed in#{as(identity)}")
  end

  defp link(opts) do
    Mix.shell().info("HAL-C2 Connect\n")

    with {:ok, identity} <- link_environment(opts) do
      Mix.shell().info(
        "✓ Authorized#{as(identity)}\n\nNext\n  Start the server with `mix hal_c2.server` to make this machine reachable."
      )
    end
  end

  # The relay client first (the tunnel needs it), then the sign-in, then the wish to link.
  defp link_environment(opts) do
    with {:ok, version} <- relay_client_ready(),
         Mix.shell().info("✓ Relay client ready · cloudflared #{version}"),
         {:ok, identity} <- authorize(opts) do
      HalC2.Connect.Secrets.put("cloud-cli-desired-link", "managed")
      {:ok, identity}
    end
  end

  defp relay_client_ready do
    report = fn
      %{"type" => "progress", "stage" => stage} ->
        Mix.shell().info("Relay client: #{String.replace(stage, "_", " ")}...")

      _ ->
        :ok
    end

    install = fn ->
      case HalC2.Connect.RelayClient.install(report) do
        {:ok, %{"version" => version}} -> {:ok, version}
        {:error, %{"message" => message}} -> Mix.raise(message)
      end
    end

    case HalC2.Connect.RelayClient.resolve() do
      %{"status" => "available", "version" => version} ->
        {:ok, version}

      %{"status" => "unsupported"} ->
        install.()

      %{"version" => version} ->
        if Mix.shell().yes?(
             "The HAL-C2 relay client is required for HAL-C2 Connect. Download and install version #{version}?"
           ) do
          install.()
        else
          Mix.shell().info("HAL-C2 Connect setup cancelled. The relay client was not installed.")
          :cancelled
        end
    end
  end

  # A stored sign-in is reused; otherwise a browser here, or a device code over SSH.
  defp authorize(opts) do
    alias HalC2.Connect.OAuth

    result =
      cond do
        token = OAuth.stored() ->
          {:ok, token["identity"]}

        opts[:headless] || OAuth.headless_session?() ->
          OAuth.device(fn %{uri: uri, code: code, expires_in: expires_in} ->
            Mix.shell().info(
              Enum.join(
                [
                  "Headless authorization",
                  "Open this URL on a device with a browser:",
                  "  #{uri}",
                  "",
                  "Confirm this code when asked: #{code}",
                  "",
                  "Waiting for approval (expires in #{max(1, round(expires_in / 60))} min). Press Ctrl+C to cancel."
                ],
                "\n"
              )
            )
          end)

        true ->
          OAuth.loopback(fn url ->
            Mix.shell().info(
              "Open this URL to authorize HAL-C2 Connect:\n  #{url}\n\nNo browser on this device? Run `mix hal_c2.connect --headless` instead."
            )
          end)
      end

    case result do
      {:ok, identity} -> {:ok, identity}
      {:error, message} -> Mix.raise(message)
    end
  end

  # `offerServiceDuringOnboarding` (`apps/server/src/cli/service.ts`): true once the
  # node runs as a background service.
  defp offer_service do
    status = HalC2.Service.status()

    cond do
      not status["supported"] ->
        false

      status["installed"] and status["current"] ->
        Mix.shell().info("HAL-C2 is already set up to run in the background on this machine.")
        true

      Mix.shell().yes?(service_question(status)) ->
        case HalC2.Service.install() do
          {:ok, result} ->
            Mix.shell().info(
              "Background service #{if result["previouslyInstalled"], do: "updated", else: "installed"}. Logs: #{result["logPath"]}"
            )

            true

          {:error, message} ->
            Mix.shell().error("Background setup did not finish: #{message}")
            false
        end

      true ->
        false
    end
  end

  defp service_question(%{"installed" => true}),
    do: "The installed HAL-C2 service needs an update or repair. Update it now?"

  defp service_question(_) do
    if match?({:unix, :darwin}, Application.get_env(:hal_c2, :service_platform, :os.type())),
      do:
        "Run HAL-C2 in the background whenever you log in to this Mac? It stays reachable through HAL-C2 Connect while you are logged in.",
      else:
        "Run HAL-C2 in the background whenever this machine boots? It stays reachable through HAL-C2 Connect even after you log out."
  end

  defp as(nil), do: ""
  defp as(identity), do: " as #{identity}"

  defp status do
    alias HalC2.Connect.Secrets

    desired = HalC2.Connect.desired_link() != nil
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
        not signed_in -> "Run `hal-c2 connect link` to authorize and enable HAL-C2 Connect."
        not desired -> "Run `hal-c2 connect link` to enable HAL-C2 Connect."
        not linked -> "Start HAL-C2 to provision the environment link and launch its managed tunnel."
        true -> nil
      end

    Enum.join(
      [
        "HAL-C2 Connect",
        "  Exposure: #{if desired, do: "enabled", else: "disabled"}",
        "  Authorization: #{if signed_in, do: "stored credential", else: "missing"}",
        "  Environment link: #{provisioned}",
        "  Relay: #{Secrets.get("cloud-relay-url") || "not provisioned"}",
        "  Publish agent activity: #{if HalC2.Connect.publishing?(), do: "enabled", else: "disabled"}"
      ] ++
        relay_client(HalC2.Connect.RelayClient.resolve()) ++
        [
          "",
          "This is saved setup, not a live connection check. Check the background service with `hal-c2 service status`."
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
    alias HalC2.Connect.Secrets

    Secrets.delete("cloud-cli-desired-link")
    live = live_unlink()
    relay = relay_unlink()
    HalC2.Connect.forget_link()
    if sign_out?, do: Secrets.delete("cloud-cli-oauth-token")

    if live == :failed do
      Mix.shell().error(
        "HAL-C2 Connect is disabled, but the running server could not stop its tunnel.\nRestart that server to stop the connector."
      )
    else
      Mix.shell().info("HAL-C2 Connect is disabled locally.")
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
          "Could not revoke the relay-side environment record yet.\nRun `hal-c2 connect unlink` again when the relay is reachable."
        )

      _ ->
        :ok
    end

    if sign_out?,
      do:
        Mix.shell().info(
          "Signed out of HAL-C2 Connect locally.\nThe background service is managed separately with `hal-c2 service`."
        )
  end

  # A node running on this host stops its tunnel through its own API, as the
  # operator, with a session minted from its store.
  defp live_unlink do
    base = "http://127.0.0.1:#{Application.get_env(:hal_c2, :port, 3780)}"
    store = Path.join(Application.fetch_env!(:hal_c2, :home), "hal-c2.sqlite")

    with {:ok, _} <-
           :httpc.request(
             :get,
             {~c"#{base}/.well-known/hal-c2/environment", []},
             [timeout: 5_000],
             []
           ),
         credential = HalC2.Auth.create_pairing_token(store, admin: true),
         {:ok, {{_, 200, _}, _, reply}} <-
           :httpc.request(
             :post,
             {~c"#{base}/oauth/token", [], ~c"application/x-www-form-urlencoded",
              URI.encode_query(%{
                "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token_type" => "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
                "subject_token" => credential,
                "client_label" => "hal-c2 connect"
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
    with token when is_binary(token) <- HalC2.Connect.cli_token(),
         url when is_binary(url) <- HalC2.Connect.relay_url() do
      id = URI.encode(HalC2.Environment.id(), &URI.char_unreserved?/1)

      case HalC2.Connect.relay(:delete, "#{url}/v1/client/environment-links/#{id}", token, nil) do
        {:ok, %{"ok" => true}} -> :revoked
        {:ok, _} -> :not_linked
        error -> {:error, error}
      end
    else
      _ -> :not_signed_in
    end
  end
end
