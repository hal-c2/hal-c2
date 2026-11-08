defmodule HalC2.Codex.ChatGpt do
  @moduledoc """
  A ChatGPT account connected to a Codex instance through HAL-C2 rather than the
  Codex CLI's own login: the instance's `setupMode` setting is `"managed"`.

  Codex runs the sign-in itself (`account/login/start`), so the OAuth exchange,
  its PKCE and state, and every later token refresh stay Codex's. HAL-C2 shows
  OpenAI's link (`login/4`, under `HalC2.ProviderAuth`), delivers a callback
  address pasted from another device to Codex's login listener
  (`validate_callback/2`, `forward_callback/1`), and keeps the login in a Codex
  home of the instance's own beside the MC's secrets (`home/1`). That home is a
  shadow of the shared Codex home (`HalC2.Codex.Home`), so the instance's threads
  continue on the CLI's account and back; the CLI's own login is never read or
  written.

  The account is remembered (`record/1`: its email and plan, and whether it is
  signed in) across sign-outs, so a signed-out instance still names it.
  `move/1` hands the login to another environment of the cluster: a refresh
  token is good on one machine at a time, so the source forgets it.
  """

  require Logger

  alias HalC2.JsonRpc.Connection
  alias HalC2.ProviderUsageLimits, as: Limits
  alias HalC2.ProviderUsageLimits.Codex, as: Usage

  @method "chatgpt"
  @authorize "https://auth.openai.com/oauth/authorize"
  @first "Signed in with ChatGPT. Using Codex counts against your ChatGPT plan's usage limits."
  @signed_out "Codex is not signed in. Connect a ChatGPT account in its provider settings."

  @doc """
  Whether `instance` is a Codex instance whose ChatGPT account HAL-C2 connects.
  The mode is the instance's own: unlike its other settings, another instance
  does not take it from the built-in one (`providers.codex`), so connecting one
  account leaves every other instance on its own login.
  """
  def managed?(instance) when is_binary(instance) do
    settings = HalC2.Settings.settings()

    mode =
      case (settings["providerInstances"] || %{})[instance] do
        %{"driver" => "codex", "config" => %{"setupMode" => mode}} -> mode
        %{"driver" => "codex"} when instance != "codex" -> nil
        _ when instance == "codex" -> get_in(settings, ["providers", "codex", "setupMode"])
        _ -> nil
      end

    mode == "managed"
  end

  def managed?(_), do: false

  @doc "What a managed instance that is not signed in tells the user."
  def signed_out_message, do: @signed_out

  # --- the home and the account ----------------------------------------------------

  @doc """
  The instance's own Codex home: under the MC's secrets, owner-only, made on
  first use. Its `auth.json` is the connected account's login.
  """
  # Every path here is under `<data>/secrets/codex/<dir_name>`, a plain or hashed id.
  # sobelow_skip ["Traversal.FileModule"]
  def home(instance) do
    secrets = Path.join(HalC2.Paths.data_dir(), "secrets")
    dir = Path.join([secrets, "codex", dir_name(instance)])
    File.mkdir_p!(dir)
    for path <- [secrets, Path.dirname(dir), dir], do: File.chmod(path, 0o700)
    dir
  end

  # Instance ids are the operator's; anything but a plain id is hashed into one.
  defp dir_name(instance) do
    if instance =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/,
      do: instance,
      else: :crypto.hash(:sha256, instance) |> Base.encode16(case: :lower)
  end

  defp login_path(instance), do: Path.join(home(instance), "auth.json")
  defp secret(instance), do: "codex-chatgpt-" <> dir_name(instance)

  @doc """
  The account remembered for `instance`: `%{"email", "planType", "signedIn"}`,
  or nil when none was ever connected.
  """
  def record(instance) do
    with bytes when is_binary(bytes) <- HalC2.Secrets.get(secret(instance)),
         {:ok, %{} = record} <- JSON.decode(bytes),
         do: record,
         else: (_ -> nil)
  end

  defp put_record(instance, record),
    do: HalC2.Secrets.put(secret(instance), JSON.encode!(record))

  @doc """
  What a usage probe of a managed instance saw (`account/read`'s account, or nil):
  the remembered account follows it, and the hint for a signed-out one is returned.
  """
  def seen(instance, %{"type" => "chatgpt"} = account) do
    remember(instance, account)
    nil
  end

  def seen(instance, nil) do
    case record(instance) do
      %{"signedIn" => true} = record -> put_record(instance, %{record | "signedIn" => false})
      _ -> :ok
    end

    @signed_out
  end

  def seen(_instance, _other), do: nil

  defp remember(instance, account) do
    put_record(instance, %{
      "email" => account["email"],
      "planType" => account["planType"],
      "signedIn" => true
    })
  end

  # --- signing in (`HalC2.ProviderAuth`) ---------------------------------------------

  @doc "The one sign-in method, naming the remembered account's email."
  def methods(instance) do
    method =
      Limits.put_present(
        %{
          "id" => @method,
          "name" => "Sign in with ChatGPT",
          "description" => "Use your ChatGPT plan with Codex, signed in through HAL-C2.",
          "type" => "agent"
        },
        "accountEmail",
        (record(instance) || %{})["email"]
      )

    {:ok, [method]}
  end

  @doc """
  Runs one sign-in (see `HalC2.ProviderAuth`): Codex's link goes to the clients,
  and the sign-in ends when Codex reports it complete and reads the account. The
  first account ever connected to the instance says what that costs.
  """
  def login(instance, _method_id, server, flow_id) do
    first? = record(instance) == nil

    with {:ok, conn} <- open(instance),
         {:ok, %{"authUrl" => url} = started} <-
           call(conn, "account/login/start", %{"type" => @method}, 30_000),
         {:ok, _pending} <- checked(authorization(url)) do
      interaction = %{
        "type" => "browser",
        "id" => flow_id,
        "url" => url,
        "requiresConsent" => false,
        "acceptsCallback" => true
      }

      send(server, {:auth_interaction, flow_id, interaction, self()})
      await_completed(conn, started["loginId"])
      send(server, {:auth_verifying, flow_id})

      case call(conn, "account/read", %{"refreshToken" => false}, 30_000) do
        {:ok, %{"account" => %{"type" => "chatgpt"} = account}} ->
          stop(conn)
          remember(instance, account)
          Limits.remember_account(instance, Usage.account(account))
          if first?, do: exit({:shutdown, {:succeeded, @first}})

        _ ->
          fail("Codex finished the ChatGPT sign-in but cannot read the account. Start again.")
      end
    else
      {:error, detail} when is_binary(detail) -> fail(detail)
      {:ok, _} -> fail("Codex did not offer a ChatGPT sign-in. Update Codex and try again.")
      _ -> fail("Codex could not start the ChatGPT sign-in. Update Codex and try again.")
    end
  end

  defp checked({:ok, pending}), do: {:ok, pending}
  defp checked(:error), do: {:error, "Codex returned an invalid ChatGPT sign-in link."}

  defp await_completed(conn, login_id) do
    receive do
      {:json_rpc, ^conn, {:notification, "account/login/completed", %{} = done}} ->
        cond do
          done["loginId"] not in [login_id, nil] -> await_completed(conn, login_id)
          done["success"] != true -> fail(failure(done["error"]))
          true -> :ok
        end

      {:json_rpc, ^conn, {:request, id, method, _params}} ->
        Connection.respond(conn, id, {:error, %{"code" => -32601, "message" => method}})
        await_completed(conn, login_id)

      {:json_rpc, ^conn, _other} ->
        await_completed(conn, login_id)
    end
  end

  defp failure(error) do
    if is_binary(error) and error =~ ~r/access_denied|denied|cancel/i,
      do: "ChatGPT sign-in was not approved. Start sign-in again.",
      else: "ChatGPT sign-in failed. Start sign-in again."
  end

  defp fail(message), do: exit({:shutdown, {:failed, message}})

  # --- the callback ------------------------------------------------------------------

  @doc """
  The loopback callback and state an OpenAI sign-in link carries: `{:ok,
  %{redirect_uri, state}}`, or `:error` for anything but OpenAI's page.
  """
  def authorization(url) when is_binary(url) do
    with %URI{scheme: "https", host: "auth.openai.com", path: "/oauth/authorize"} = uri <-
           URI.parse(url),
         true <- String.starts_with?(url, @authorize),
         params = URI.query_decoder(uri.query || "") |> Enum.to_list(),
         [state] <- for({"state", v} <- params, v != "", do: v),
         [redirect] <- for({"redirect_uri", v} <- params, do: v),
         %URI{scheme: "http", host: host, port: port}
         when host in ["localhost", "127.0.0.1"] and
                is_integer(port) <-
           URI.parse(redirect) do
      {:ok, %{redirect_uri: redirect, state: state}}
    else
      _ -> :error
    end
  end

  def authorization(_), do: :error

  @doc """
  Checks a pasted callback address against the sign-in's own: the address may
  come without its scheme or with spaces around it, but it must point at the
  callback (the loopback port and path the link named) and carry one OpenAI
  answer, and the sign-in's state when it carries one. `{:ok, uri}` is the
  callback to deliver, or `{:error, detail}`.
  """
  def validate_callback(pending, url) do
    expected = URI.parse(pending.redirect_uri)
    url = String.trim(to_string(url))
    url = if url =~ ~r{\A[A-Za-z][A-Za-z0-9+.-]*://}, do: url, else: "http://" <> url
    foreign = {:error, "This address is not the ChatGPT sign-in callback."}

    with true <- byte_size(url) <= 16_384 || {:error, "The callback address is too long."},
         %URI{host: host} = uri when is_binary(host) <- URI.parse(url) do
      params = URI.query_decoder(uri.query || "") |> Enum.to_list()
      values = fn key -> for {^key, v} <- params, do: v end

      cond do
        uri.scheme != "http" or uri.host not in ["localhost", "127.0.0.1"] or
          uri.port != expected.port or uri.path != expected.path or uri.userinfo != nil or
            uri.fragment != nil ->
          foreign

        values.("state") not in [[], [pending.state]] ->
          {:error, "This callback address belongs to another ChatGPT sign-in."}

        not match?({[c], []} when c != "", {values.("code"), values.("error")}) and
            not match?({[], [e]} when e != "", {values.("code"), values.("error")}) ->
          {:error, "The callback address must carry one ChatGPT sign-in answer."}

        true ->
          query = URI.encode_query(Map.put_new(Map.new(params), "state", pending.state))
          {:ok, %{expected | query: query}}
      end
    else
      {:error, _} = error -> error
      _ -> foreign
    end
  end

  @doc "Delivers a checked callback to Codex's login listener on this machine, once."
  def forward_callback(%URI{} = uri) do
    target =
      case Application.get_env(:hal_c2, :codex_login_callback_origin) do
        nil -> %{uri | host: "127.0.0.1", fragment: nil}
        origin -> %{URI.parse(origin) | path: uri.path, query: uri.query}
      end

    request = {String.to_charlist(URI.to_string(target)), []}

    case :httpc.request(:get, request, [timeout: 10_000, autoredirect: false], []) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _headers, _body}} when status in 400..499 ->
        {:error, "Codex refused this callback address. Start sign-in again."}

      {:error, :timeout} ->
        {:error, "The sign-in answer timed out. Start sign-in again."}

      _ ->
        {:error, "Codex is no longer waiting for this sign-in. Start sign-in again."}
    end
  end

  # --- signing out -------------------------------------------------------------------

  @doc """
  Disconnects the account: the instance's idle sessions stop, Codex signs out
  of it (and the login file goes), and the account stays remembered as signed
  out. `:ok`.
  """
  def logout(instance, _session \\ nil) do
    stop_sessions(instance)

    case open(instance) do
      {:ok, conn} ->
        _ = call(conn, "account/logout", nil, 30_000)
        stop(conn)

      _ ->
        :ok
    end

    signed_out(instance)
  end

  # The login is gone from this machine: its file, and the account as signed in.
  # Every path here is under `<data>/secrets/codex/<dir_name>`, a plain or hashed id.
  # sobelow_skip ["Traversal.FileModule"]
  defp signed_out(instance) do
    File.rm(login_path(instance))
    seen(instance, nil)

    Limits.remember_account(instance, %{
      "status" => "unauthenticated",
      "message" => @signed_out
    })

    :ok
  end

  # A turn that is running keeps its session until it ends; the next one starts
  # Codex again in the signed-out home.
  defp stop_sessions(instance) do
    for thread_id <- Registry.select(HalC2.Codex.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        match?(
          %{"status" => status} when status != "stopped",
          HalC2.Streams.get(
            thread_id,
            "provider-session",
            HalC2.Orchestration.Entities.provider_session_id(instance, thread_id)
          )
        ) do
      HalC2.Orchestration.release_session(thread_id)
    end

    :ok
  catch
    kind, reason ->
      Logger.warning("codex #{instance} sessions not stopped: #{inspect({kind, reason})}")
      :ok
  end

  # --- moving the account ------------------------------------------------------------

  @doc """
  `provider.chatgpt.move`: hands `instanceId`'s connected account to the same
  instance on environment `environmentId`, which then runs Codex signed in with
  it. The login leaves this environment.
  """
  # Every path here is under `<data>/secrets/codex/<dir_name>`, a plain or hashed id.
  # sobelow_skip ["Traversal.FileModule"]
  def move(%{"instanceId" => instance, "environmentId" => environment}) do
    mc = HalC2.Shell.mc_for(environment)

    cond do
      not managed?(instance) ->
        error(instance, "This Codex does not use a ChatGPT account connected through HAL-C2.")

      environment == HalC2.Environment.id() ->
        error(instance, "The account is already on this environment.")

      not match?(%{"signedIn" => true}, record(instance)) or
          not File.exists?(login_path(instance)) ->
        error(instance, "No signed-in ChatGPT account to move. Connect one first.")

      mc == nil ->
        error(instance, "That environment cannot be reached. Try again once it is online.")

      true ->
        login = File.read!(login_path(instance))
        args = [instance, login, record(instance)]

        case :erpc.call(mc, __MODULE__, :adopt, args, 90_000) do
          :ok ->
            stop_sessions(instance)
            File.rm(login_path(instance))
            HalC2.Secrets.delete(secret(instance))

            Limits.remember_account(instance, %{
              "status" => "unauthenticated",
              "message" => @signed_out
            })

            {:ok, %{"instanceId" => instance, "environmentId" => environment}}

          {:error, detail} ->
            error(instance, detail)
        end
    end
  catch
    :error, {:erpc, _} ->
      error(instance, "That environment cannot be reached. Try again once it is online.")
  end

  @doc """
  Takes a login moved here (`move/1`): `instance` becomes a managed Codex
  instance if it was not one, signed in with the login. `:ok` or `{:error, detail}`.
  """
  # Every path here is under `<data>/secrets/codex/<dir_name>`, a plain or hashed id.
  # sobelow_skip ["Traversal.FileModule"]
  def adopt(instance, login, record) when is_binary(login) and is_map(record) do
    {:ok, _} = make_managed(instance)
    path = login_path(instance)
    tmp = path <> ".moving"
    File.write!(tmp, login)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    put_record(instance, Map.put(record, "signedIn", true))
    Limits.remember_account(instance, Usage.account(Map.put(record, "type", "chatgpt")))
    _ = Limits.refresh([instance])
    :ok
  rescue
    error in File.Error ->
      {:error, "The account could not be saved there: " <> Exception.message(error)}

    MatchError ->
      {:error, "That environment could not set Codex up for the account."}
  end

  defp make_managed(instance) do
    if managed?(instance) do
      {:ok, nil}
    else
      HalC2.Settings.update(fn settings ->
        if instance == "codex" do
          put_in(
            settings,
            [Access.key("providers", %{}), Access.key("codex", %{}), "setupMode"],
            "managed"
          )
        else
          entry = get_in(settings, ["providerInstances", instance]) || %{"driver" => "codex"}
          entry = put_in(entry, [Access.key("config", %{}), "setupMode"], "managed")
          put_in(settings, [Access.key("providerInstances", %{}), instance], entry)
        end
      end)
    end
  end

  # --- Codex -------------------------------------------------------------------------

  # A fresh, initialized app-server of `instance` in its managed home.
  defp open(instance) do
    Process.flag(:trap_exit, true)
    env = Enum.to_list(HalC2.Settings.instance_env(instance))

    with {:ok, home} <- HalC2.Codex.Home.env(instance),
         {:ok, conn} <-
           Connection.start_link(cmd: Usage.command(instance), handler: self(), env: home ++ env),
         {:ok, _} <-
           call(
             conn,
             "initialize",
             %{
               "clientInfo" => %{
                 "name" => "hal_c2_desktop",
                 "title" => "HAL-C2 Desktop",
                 "version" => "0.1.0"
               },
               "capabilities" => %{"experimentalApi" => true}
             },
             15_000
           ) do
      Connection.notify(conn, "initialized", nil)
      {:ok, conn}
    else
      {:error, detail} when is_binary(detail) -> {:error, detail}
      _ -> {:error, "Could not start Codex. Check its installation."}
    end
  catch
    :exit, _ -> {:error, "Could not start Codex. Check its installation."}
  end

  defp call(conn, method, params, timeout) do
    Connection.call(conn, method, params, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :closed}
  end

  defp stop(conn) do
    Connection.stop(conn)
  catch
    :exit, _ -> :ok
  end

  defp error(instance, detail) do
    {:error,
     %{
       "_tag" => "ProviderSetupError",
       "instanceId" => instance,
       "operation" => "move",
       "detail" => detail,
       "message" => detail
     }}
  end
end
