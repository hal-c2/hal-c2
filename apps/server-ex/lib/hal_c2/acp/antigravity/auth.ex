defmodule HalC2.Acp.Antigravity.Auth do
  @moduledoc """
  Antigravity's sign-in for `HalC2.ProviderAuth`, with the instance's configured
  method. Personal and Enterprise Google accounts sign in in a browser: the agent
  prints Google's sign-in link and waits on a loopback redirect, which a browser
  on this machine reaches itself; from another device the user pastes the final
  redirect URL, which `HalC2.ProviderAuth` checks against this sign-in
  (`validate_callback/3`) and delivers to the agent (`forward_callback/1`). API
  key methods authenticate from the instance's settings.

  A sign-in succeeds only once a session opens and lists the account's models; a
  callback page that says "success" is not enough.
  """

  alias HalC2.Acp.Antigravity
  alias HalC2.JsonRpc.Connection

  @login_timeout 300_000
  @google "https://accounts.google.com/o/oauth2/v2/auth"

  @doc "The instance's one sign-in method, as `ProviderAuthMethod`s."
  def methods(instance) do
    method = Antigravity.config(instance)["authMethod"]

    {:ok,
     [
       %{
         "id" => method,
         "name" => Antigravity.label(method),
         "description" => nil,
         "type" => if(Antigravity.browser?(method), do: "agent", else: "credentials")
       }
     ]}
  end

  @doc "Runs one sign-in; exits `:normal` on success (see `HalC2.ProviderAuth`)."
  def login(instance, _method_id, server, flow_id) do
    config = Antigravity.config(instance)
    method = config["authMethod"]
    if issue = Antigravity.config_issue(config), do: fail(issue)

    cwd = Path.join(Antigravity.profile(instance), "sign-in")
    File.mkdir_p!(cwd)

    with {:ok, command, env} <- Antigravity.command(instance),
         {:ok, conn} <-
           Connection.start_link(cmd: command, handler: self(), cd: cwd, env: env, dialect: :v2),
         {:ok, _init} <-
           Connection.call(conn, "initialize", HalC2.Acp.initialize_params(), 60_000) do
      task =
        Task.async(fn ->
          Connection.call(conn, "authenticate", %{"methodId" => method}, @login_timeout)
        end)

      case await(conn, task, server, flow_id) do
        {:ok, _} -> verify(conn, cwd, instance, server, flow_id)
        {:error, reason} -> fail(failure(reason, Antigravity.browser?(method)))
      end
    else
      {:error, detail} when is_binary(detail) -> fail(detail)
      {:error, _} -> fail("Could not start Antigravity. Check its installation.")
    end
  end

  defp await(conn, task, server, flow_id) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:json_rpc, ^conn, {:invalid, line}} when is_binary(line) ->
        prefix = Antigravity.auth_prefix()

        if String.starts_with?(line, prefix) do
          url = line |> String.replace_prefix(prefix, "") |> String.trim()

          case authorization(url) do
            {:ok, _pending} ->
              interaction = %{
                "type" => "browser",
                "id" => flow_id,
                "url" => url,
                "requiresConsent" => false,
                "acceptsCallback" => true
              }

              send(server, {:auth_interaction, flow_id, interaction, self()})

            :error ->
              fail("Antigravity returned an invalid Google sign-in URL.")
          end
        end

        await(conn, task, server, flow_id)

      {:json_rpc, ^conn, {:request, id, method, _params}} ->
        Connection.respond(conn, id, {:error, %{"code" => -32601, "message" => method}})
        await(conn, task, server, flow_id)

      {:json_rpc, ^conn, _other} ->
        await(conn, task, server, flow_id)
    end
  end

  # Account access is confirmed by a session that lists the account's models.
  defp verify(conn, cwd, instance, server, flow_id) do
    send(server, {:auth_verifying, flow_id})

    case Connection.call(conn, "session/new", %{"cwd" => cwd, "mcpServers" => []}, 120_000) do
      {:ok, %{} = session} ->
        Connection.stop(conn)
        :persistent_term.erase({HalC2.Acp, instance, :unauthenticated})
        Antigravity.put_account(instance, HalC2.Acp.session_models(session))
        :ok

      _ ->
        fail("Antigravity authenticated, but could not initialize a session or load models.")
    end
  end

  defp failure(reason, browser?) do
    text = describe(reason)

    cond do
      text =~ "SUBSCRIPTION_REQUIRED" ->
        "Google requires an eligible Antigravity subscription for this account."

      text =~ ~r/access_denied|denied access|cancel/i ->
        "Google sign-in was not approved. Start sign-in again."

      not browser? and match?(%{"code" => -32602}, reason) ->
        "Antigravity rejected the configured credentials. Check the provider settings."

      browser? ->
        "Google sign-in failed. Start sign-in again."

      true ->
        "Antigravity could not authenticate with the configured credentials."
    end
  end

  defp describe(%{"message" => message} = reason) when is_binary(message),
    do: message <> " " <> inspect(reason["data"])

  defp describe(reason), do: inspect(reason)

  defp fail(message), do: exit({:shutdown, {:failed, message}})

  @doc """
  Signs an instance out: its sessions stop (all but `except`, which its caller
  closes), the agent removes its saved Google login, and the account is forgotten.
  `:ok` or `{:error, detail}`.
  """
  def logout(instance, except \\ nil) do
    Antigravity.stop_sessions(instance, except)
    cwd = Path.join(Antigravity.profile(instance), "sign-in")
    File.mkdir_p!(cwd)

    result =
      HalC2.Acp.with_agent(instance, cwd, fn conn, init ->
        if is_map(get_in(init, ["agentCapabilities", "auth", "logout"])) do
          case Connection.call(conn, "logout", %{}, 90_000) do
            {:ok, _} -> :ok
            {:error, _} -> {:error, "Antigravity sign-out failed. Try again."}
          end
        else
          {:error, "This Antigravity version does not support sign-out. Update the provider."}
        end
      end)

    case result do
      :ok ->
        Antigravity.drop_account(instance)
        :ok

      {:error, detail} when is_binary(detail) ->
        {:error, detail}

      _ ->
        {:error, "Antigravity sign-out failed. Try again."}
    end
  end

  # --- the redirect ----------------------------------------------------------------

  @doc """
  The loopback redirect and state a Google sign-in link carries: `{:ok,
  %{redirect_uri, state}}`, or `:error` for anything but Google's page.
  """
  def authorization(url) do
    with %URI{scheme: "https", host: "accounts.google.com", path: "/o/oauth2/v2/auth"} = uri <-
           URI.parse(url),
         true <- String.starts_with?(url, @google),
         params = URI.query_decoder(uri.query || "") |> Enum.to_list(),
         [state] <- for({"state", v} <- params, v != "", do: v),
         [redirect] <- for({"redirect_uri", v} <- params, do: v),
         %URI{scheme: "http", host: host, port: port}
         when host in ["127.0.0.1", "localhost"] and
                is_integer(port) <- URI.parse(redirect) do
      {:ok, %{redirect_uri: redirect, state: state}}
    else
      _ -> :error
    end
  end

  @doc """
  Checks a pasted redirect URL against the sign-in the link started: the same
  loopback address and path, its state, and one Google response. `{:ok, uri}` or
  `{:error, detail}`.
  """
  def validate_callback(pending, url) do
    expected = URI.parse(pending.redirect_uri)
    foreign = {:error, "This redirect URL does not belong to the current sign-in."}

    with true <-
           byte_size(url) <= 16_384 || {:error, "The sign-in response URL is too long."},
         %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) <-
           URI.parse(String.trim(url)),
         _ <- :ok do
      params = URI.query_decoder(uri.query || "") |> Enum.to_list()
      values = fn key -> for {^key, v} <- params, do: v end

      cond do
        uri.scheme != "http" or uri.host != "127.0.0.1" or uri.port != expected.port or
          (uri.path || "/") != (expected.path || "/") or uri.userinfo != nil or
            uri.fragment != nil ->
          foreign

        values.("state") != [pending.state] ->
          foreign

        not match?({[c], []} when c != "", {values.("code"), values.("error")}) and
            not match?({[], [e]} when e != "", {values.("code"), values.("error")}) ->
          {:error, "The redirect URL must contain one Google sign-in response."}

        values.("iss") not in [[], ["https://accounts.google.com"]] ->
          {:error, "The redirect URL is not a Google sign-in response."}

        true ->
          {:ok, uri}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Paste the complete redirect URL from the Google sign-in page."}
    end
  end

  @doc "Delivers a checked redirect to the agent's loopback listener, once."
  def forward_callback(%URI{} = uri) do
    request = {String.to_charlist(URI.to_string(%{uri | fragment: nil})), []}

    case :httpc.request(:get, request, [timeout: 10_000, autoredirect: false], []) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
        :ok

      {:error, :timeout} ->
        {:error, "The sign-in response timed out. Start sign-in again."}

      _ ->
        {:error, "Could not deliver the sign-in response. Start sign-in again."}
    end
  end
end
