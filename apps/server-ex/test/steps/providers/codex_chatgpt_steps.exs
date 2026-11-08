defmodule HalC2.Steps.Providers.CodexChatGpt do
  @moduledoc """
  Steps for the ChatGPT account HAL-C2 connects to Codex (`HalC2.Codex.ChatGpt`), in
  `features/providers/codex.feature`. Codex is `fake_codex.py` with its ChatGPT
  sign-in on (`fake_codex_chatgpt.py`): its login listener stands in for Codex's on
  localhost:1455, and a request to it stands in for the browser OpenAI sends back.
  Nothing reaches OpenAI. Each scenario's `~` is its own (`HalC2.Test.Mc.Host.home/1`),
  so the Codex CLI's own login is the scenario's `~/.codex/auth.json`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Codex.ChatGpt
  alias HalC2.Test.{Machines, Mc}
  alias HalC2.Test.Mc.{Host, World}

  @instance "codex"
  @email "me@example.com"

  # --- connecting ------------------------------------------------------------------

  step "the user has a ChatGPT plan and Codex is not signed in on the environment", context do
    context = chatgpt(context)
    entry = probed(context)
    assert %{"auth" => %{"status" => "unauthenticated"}} = entry
    context
  end

  step("the user connects ChatGPT to Codex", context, do: connect(context))

  step("the user approves the sign-in with OpenAI", context, do: approve(context))

  step "Codex on the environment is signed in with that account", context do
    assert_signed_in(context, @email)
    # The login is the MC's, in its secrets: the Codex CLI's own home has none.
    assert File.regular?(Path.join(ChatGpt.home(@instance), "auth.json"))
    refute File.exists?(Path.join([Host.home(context), ".codex", "auth.json"]))
    context
  end

  step "the user has never connected a ChatGPT account", context do
    context = chatgpt(context)
    assert ChatGpt.record(@instance) == nil
    context
  end

  step "the user connects one", context do
    context |> connect() |> approve()
  end

  step "HAL-C2 explains that using Codex counts against the ChatGPT plan's usage", context do
    assert %{"phase" => "succeeded", "message" => message} = context.auth
    assert message =~ "counts against your ChatGPT plan's usage"
    context
  end

  # --- the pasted callback ---------------------------------------------------------

  step "the user is connecting ChatGPT to Codex and the browser could not reach the sign-in callback",
       context do
    context |> chatgpt() |> connect()
  end

  # The address as the user pasted it, spaces and all. A browser's carries the
  # sign-in's state; one without it is this sign-in's.
  step ~r/^the user pastes the callback address "(?<url>[^"]*)"(?: with spaces)?$/,
       %{args: [url]} = context do
    {reply, context} =
      World.call(context, "provider.auth.complete", %{
        "instanceId" => @instance,
        "flowId" => context.flow.id,
        "callbackUrl" => url
      })

    Map.put(context, :reply, reply)
  end

  step "the sign-in finishes", context do
    assert {:ok, _} = context.reply
    context = await_auth(context, "succeeded")
    assert_signed_in(context, @email)
    context
  end

  step "the address is refused as not the callback", context do
    assert {:error, "This address is not the ChatGPT sign-in callback.",
            %{"operation" => "complete"}} = context.reply

    # The sign-in still waits for its own callback, and nothing was signed in.
    assert %{"phase" => "waiting"} = current_auth()
    refute File.exists?(Path.join(ChatGpt.home(@instance), "auth.json"))
    context
  end

  # --- signed in, out, and back to the CLI -------------------------------------------

  step ~r/^(?:Codex is connected with a ChatGPT account|a Codex instance whose ChatGPT account was connected through HAL-C2)$/,
       context do
    context = context |> chatgpt() |> connect() |> approve()
    assert_signed_in(context, @email)
    context
  end

  step "the user disconnects the account", context do
    {state, context} = World.call!(context, "provider.auth.logout", %{"instanceId" => @instance})
    Map.put(context, :auth, state)
  end

  step "Codex on that environment is no longer signed in with it", context do
    assert %{"phase" => "idle", "message" => "Signed out of ChatGPT."} = context.auth
    refute File.exists?(Path.join(ChatGpt.home(@instance), "auth.json"))

    # Codex itself was asked to sign out, and now reads no account.
    assert codex_asked?(context, "account/logout")
    entry = probed(context)
    assert %{"status" => "error", "auth" => %{"status" => "unauthenticated"}} = entry
    assert entry["message"] == ChatGpt.signed_out_message()
    # The account is remembered as signed out, so it can be connected again.
    assert %{"email" => @email, "signedIn" => false} = ChatGpt.record(@instance)
    context
  end

  step "its account is remembered but no longer signed in", context do
    # Its login ran out, as a revoked sign-in does: Codex reads no account now.
    File.rm!(Path.join(ChatGpt.home(@instance), "auth.json"))
    entry = probed(context)
    assert entry["message"] == ChatGpt.signed_out_message()
    assert %{"email" => @email, "signedIn" => false} = ChatGpt.record(@instance)
    {:ok, [method]} = ChatGpt.methods(@instance)
    assert method["accountEmail"] == @email
    context
  end

  step "the user chooses to use the existing Codex CLI in its provider settings", context do
    # The Codex CLI on the environment is signed in with its own account.
    login = Path.join([Host.home(context), ".codex", "auth.json"])
    File.mkdir_p!(Path.dirname(login))

    File.write!(
      login,
      JSON.encode!(%{
        "auth_mode" => "chatgpt",
        "fake_account" => %{"email" => "cli@example.com", "planType" => "plus"}
      })
    )

    World.put_settings(context, %{"providers" => %{"codex" => %{"setupMode" => "existing"}}})
  end

  step "the instance uses the Codex CLI's own login from then on", context do
    refute ChatGpt.managed?(@instance)
    assert HalC2.Codex.Home.env(@instance) == {:ok, []}
    assert_signed_in(context, "cli@example.com")

    # HAL-C2 no longer signs this Codex in.
    assert {{:error, "This provider does not sign in here.", _}, _} =
             World.call(context, "provider.auth.start", %{"instanceId" => @instance})

    context
  end

  # --- the email -------------------------------------------------------------------

  step "the account's email is not shown", context do
    # The MC carries the email apart from every text a client shows as is.
    entry = probed(context)
    assert entry["auth"]["email"] == @email

    for text <- [entry["auth"]["label"], entry["message"], context.auth["message"]],
        do: refute(to_string(text) =~ @email)

    context
  end

  step "the user asks to show it", context do
    %{"methods" => [method]} = current_auth()
    Map.put(context, :shown_email, method["accountEmail"])
  end

  step "the email is shown", context do
    assert context.shown_email == @email
    context
  end

  # --- moving the account ----------------------------------------------------------

  step "the user connected a ChatGPT account on the primary environment", context do
    # The peer starts under the real `$HOME`, where the VM's cookie is; this MC's
    # Codex home is the cluster's scratch `CODEX_HOME`.
    # The cluster restarts this MC: the client connects again with its next call.
    context = %{Machines.cluster(context, "primary", ["other"]) | clients: %{}}
    context = context |> chatgpt() |> connect() |> approve()
    assert_signed_in(context, @email)
    context
  end

  step "the user chooses another environment for that Codex account", context do
    # The other environment's Codex has the same fake sign-in.
    :ok = Machines.on(context, "other", System, :put_env, ["FAKE_CODEX_CHATGPT", "1"])
    environment = Machines.machine(context, "other").environment

    {moved, context} =
      World.call!(context, "provider.chatgpt.move", %{
        "instanceId" => @instance,
        "environmentId" => environment
      })

    assert moved == %{"instanceId" => @instance, "environmentId" => environment}
    context
  end

  step "the other environment's Codex is signed in with the account", context do
    # Its Codex reads the account from the login it was handed.
    :ok = Machines.on(context, "other", HalC2.ProviderUsageLimits, :refresh, [[@instance]])
    Machines.on(context, "other", :sys, :get_state, [HalC2.ProviderUsageLimits])

    entry =
      Machines.on(context, "other", HalC2.ProviderUsageLimits, :put, [
        %{"instanceId" => @instance, "auth" => %{"status" => "authenticated"}}
      ])

    assert %{"auth" => %{"status" => "authenticated", "email" => @email}} = entry
    refute entry["status"] == "error"
    assert Machines.on(context, "other", ChatGpt, :managed?, [@instance])

    # A refresh token is good on one machine at a time: the primary is signed out.
    refute File.exists?(Path.join(ChatGpt.home(@instance), "auth.json"))
    assert probed(context)["message"] == ChatGpt.signed_out_message()
    context
  end

  # --- helpers ---------------------------------------------------------------------

  # Codex with its fake ChatGPT sign-in, and its login listener on a free port the MC
  # delivers pasted callbacks to.
  defp chatgpt(%{chatgpt: _} = context), do: context

  defp chatgpt(context) do
    Host.home(context)
    context = World.fake_providers(context)
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    World.put_env("FAKE_CODEX_CHATGPT", "1")
    World.put_env("FAKE_CODEX_LOGIN_PORT", Integer.to_string(port))
    World.put_app_env(:codex_login_callback_origin, "http://127.0.0.1:#{port}")

    Mc.ensure(HalC2.ProviderUsageLimits)

    Mc.ensure(
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.ProviderAuth.Registry},
        id: :provider_auth_registry
      )
    )

    Mc.ensure(
      Supervisor.child_spec(
        {DynamicSupervisor, name: HalC2.ProviderAuth.Supervisor, strategy: :one_for_one},
        id: :provider_auth_supervisor
      )
    )

    Map.put(context, :chatgpt, %{port: port})
  end

  # Connects ChatGPT to Codex: the instance becomes HAL-C2's to sign in, and the sign-in
  # starts; returns once OpenAI's link is up.
  defp connect(context) do
    context =
      World.put_settings(context, %{"providers" => %{"codex" => %{"setupMode" => "managed"}}})

    {context, id} = auth_sub(context)

    {state, context} =
      World.call!(context, "provider.auth.start", %{"instanceId" => @instance})

    context = context |> Map.merge(%{auth: state, auth_id: id}) |> await_auth("waiting")
    %{"interaction" => %{"url" => url, "id" => flow_id}} = context.auth
    assert url =~ "https://auth.openai.com/oauth/authorize?"
    assert {:ok, %{redirect_uri: redirect, state: state}} = ChatGpt.authorization(url)
    assert redirect == "http://localhost:1455/auth/callback"
    Map.put(context, :flow, %{id: flow_id, state: state})
  end

  defp approve(context) do
    assert browser(context, %{"code" => "openai-code"}) =~ "Signed in"
    await_auth(context, "succeeded")
  end

  # The browser following OpenAI's redirect to Codex's login listener.
  defp browser(context, params) do
    query = URI.encode_query(Map.put(params, "state", context.flow.state))
    url = "http://127.0.0.1:#{context.chatgpt.port}/auth/callback?" <> query

    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 10_000], [])

    to_string(body)
  end

  defp auth_sub(%{auth_id: id} = context), do: {context, id}

  defp auth_sub(context) do
    id = System.unique_integer([:positive])

    client =
      World.client(context, "default")
      |> Mc.sub(id, %{
        "type" => "providerAuth",
        # By environment: this MC's name changes when a scenario makes it a cluster.
        "environment" => context.mc.environment,
        "instanceId" => @instance
      })

    {_frame, client} = Mc.await(client, &(&1["t"] == "providerAuth" and &1["id"] == id))
    {World.put_client(context, "default", client), id}
  end

  # The sign-in state once the client is told its phase is `phase`.
  defp await_auth(context, phase) do
    id = context.auth_id

    {frame, client} =
      Mc.await(
        World.client(context, "default"),
        &(&1["t"] == "providerAuth" and &1["id"] == id and &1["state"]["phase"] == phase),
        15_000
      )

    context |> World.put_client("default", client) |> Map.put(:auth, frame["state"])
  end

  defp current_auth do
    [{server, _}] = Registry.lookup(HalC2.ProviderAuth.Registry, @instance)
    :sys.get_state(server).auth
  end

  # Codex's provider entry once its usage (and so its account) was checked.
  defp probed(context) do
    :ok = HalC2.ProviderUsageLimits.refresh([@instance])
    # The account arrives as a cast the probe sent; this call lands after it.
    :sys.get_state(HalC2.ProviderUsageLimits)
    {providers, _context} = World.provider_list(context)
    Enum.find(providers, &(&1["instanceId"] == @instance))
  end

  defp assert_signed_in(context, email) do
    entry = probed(context)

    assert %{"auth" => %{"status" => "authenticated", "type" => "chatgpt", "email" => ^email}} =
             entry

    refute entry["status"] == "error"
    entry
  end

  defp codex_asked?(context, method) do
    context
    |> World.provider_log("codex")
    |> Enum.any?(&(get_in(&1, ["in", "method"]) == method))
  end
end
