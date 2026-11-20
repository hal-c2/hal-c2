defmodule HalC2.Steps.Plugins.CliProxyApi do
  @moduledoc """
  Steps for `features/plugins/cliproxyapi.feature`, run against the real package in the
  repository's `plugins/cliproxyapi`, copied into the MC's plugins directory as a user
  would install it.

  The proxy is `HalC2.Test.FakeCliProxyApi` (its management API and the release
  downloads) and `test/support/fake_cli_proxy_api.sh` in place of `cli-proxy-api`: the
  plugin's port setting points at the fake's, so the binary it runs listens on nothing
  and the fake answers what the plugin asks. The plugin's timer is an hour, so nothing
  drains behind a scenario's back; the page's `refresh` call drains at once and answers
  what the page would show, the same values its topics carry. What happens on its own
  (a restart, a download, an instance the user deleted) is waited for on the `status`
  topic.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Test.FakeCliProxyApi, as: Fake
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @id "cliproxyapi"
  @package Path.expand("../../../../../plugins/cliproxyapi", __DIR__)
  @binary Path.expand("../../support/fake_cli_proxy_api.sh", __DIR__)
  @version "8.0.79"

  # --- background ------------------------------------------------------------------------

  step "a fake CLIProxyAPI", context do
    fake = Fake.start()
    previous = Application.get_env(:hal_c2, :cliproxyapi)

    # No PATH lookup, so a cli-proxy-api on this machine is never run.
    Application.put_env(:hal_c2, :cliproxyapi,
      releases: fake.base <> "/releases",
      path: "",
      drain_ms: 3_600_000
    )

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :cliproxyapi, previous),
        else: Application.delete_env(:hal_c2, :cliproxyapi)
    end)

    dir = Path.join([context.mc.home, "plugins", @id])
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@package, dir)

    context
    |> Fixtures.ensure()
    |> Fixtures.rescan()
    |> Map.put(:fake, fake)
  end

  # --- settings and turning it on --------------------------------------------------------

  step "the CLIProxyAPI plugin is set to run the fake binary", context do
    save(context, run_settings(context, @binary))
  end

  step "the CLIProxyAPI plugin is set to run {string}", %{args: [path]} = context do
    save(context, run_settings(context, path))
  end

  step "the CLIProxyAPI plugin is set to run without a binary", context do
    save(context, run_settings(context, ""))
  end

  step "the CLIProxyAPI plugin runs the fake binary", context do
    context
    |> save(run_settings(context, @binary))
    |> turn_on()
    |> await_status(&(&1["state"] == "running"))
  end

  step("the user turns the CLIProxyAPI plugin on", context, do: turn_on(context))
  step("the user turns the CLIProxyAPI plugin off", context, do: turn_off(context))

  step "the user turns the CLIProxyAPI plugin off and on again", context do
    context |> turn_off() |> turn_on()
  end

  step "the user sets the CLIProxyAPI port to {int}", %{args: [port]} = context do
    context = Map.put(context, :pid, status(context)["pid"])

    # The plugin gets its settings by a cast, and publishes the new address once
    # it has moved its instances there.
    context
    |> save(%{"port" => port})
    |> await_status(&(&1["address"] == "http://127.0.0.1:#{port}"))
  end

  step "the user switches the CLIProxyAPI plugin to connect to it with the management key {string}",
       %{args: [key]} = context do
    save(context, %{"mode" => "connect", "url" => context.fake.base, "managementKey" => key})
  end

  step "the user connects the CLIProxyAPI plugin to it with the management key {string}",
       %{args: [key]} = context do
    context
    |> save(%{
      "mode" => "connect",
      "url" => context.fake.base,
      "managementKey" => key,
      "binaryPath" => @binary
    })
    |> turn_on()
  end

  step "the user saves Connect to {string} with the management key {string}",
       %{args: [url, key]} = context do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{
        "id" => @id,
        "settings" => %{"mode" => "connect", "url" => url, "managementKey" => key}
      })

    Map.put(context, :reply, reply)
  end

  step "the save is refused saying {string}", %{args: [text]} = context do
    assert {:error, message, %{"_tag" => "PluginSettingsInvalid"}} = context.reply
    assert message =~ text
    context
  end

  # The plugin's server, taken down as a crash would: the Agent keeps the settings and
  # `rest_for_one` starts the server again on them. A server held busy first loses the
  # settings changes sent to it meanwhile.
  step "the plugin's server is busy", context do
    :ok = :sys.suspend(server())
    context
  end

  step "the plugin's server crashes", context do
    old = server()
    {:dictionary, dictionary} = Process.info(old, :dictionary)
    [supervisor | _] = dictionary[:"$ancestors"]
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 5_000
    # Returns once the supervisor has handled the exit, and so started the server again;
    # the server applies its settings before it answers a call.
    :sys.get_state(supervisor)
    assert server() not in [nil, old]
    status(context)
    context
  end

  # --- the fake ----------------------------------------------------------------------

  step "the fake CLIProxyAPI lets agents in with the key {string}", %{args: [key]} = context do
    Fake.update(context.fake, &%{&1 | access: [key]})
    context
  end

  step "the fake CLIProxyAPI refuses every management key saying {string}",
       %{args: [message]} = context do
    Fake.update(context.fake, &%{&1 | refuse: message})
    context
  end

  step "the fake CLIProxyAPI takes the management key again and the user retries", context do
    Fake.update(context.fake, &%{&1 | refuse: nil})
    {_, context} = call!(context, "retry")
    context
  end

  step "the fake CLIProxyAPI keeps no usage, saying {string}", %{args: [message]} = context do
    Fake.update(context.fake, &%{&1 | no_usage: message})
    context
  end

  step "the fake CLIProxyAPI answers the next {string} with {int} saying {string}",
       %{args: [request, status, message]} = context do
    answer(context, request, {status, %{"error" => message}})
  end

  step "the fake CLIProxyAPI hands out the sign-in address {string}", %{args: [url]} = context do
    answer(
      context,
      "GET /oauth/auth-url",
      {200, %{"status" => "ok", "url" => url, "state" => "st-x"}}
    )
  end

  step "the {string} key {string} was added first on the proxy since",
       %{args: [provider, key]} = context do
    group = %{"keys" => [%{"api-key" => key}]}
    Fake.update(context.fake, fn fake -> update_in(fake.keys[provider], &[group | &1 || []]) end)
    context
  end

  step "the fake CLIProxyAPI holds its release downloads", context do
    Fake.update(context.fake, &%{&1 | hold: true})
    context
  end

  step "the fake CLIProxyAPI refuses API keys saying {string}", %{args: [message]} = context do
    Fake.update(context.fake, &%{&1 | refuse_keys: message})
    context
  end

  step "CLIProxyAPI 8.1.0 is released", context do
    Fake.update(context.fake, &%{&1 | latest: "v8.1.0"})
    context
  end

  step "the CLIProxyAPI 8.0.79 release for this machine, with its checksums", context do
    release(context, :match)
  end

  step "the CLIProxyAPI 8.0.79 release for this machine, with a checksum that does not match it",
       context do
    release(context, :mismatch)
  end

  step "the proxy has the {string} account {string}", %{args: [provider, email]} = context do
    account = %{
      "id" => "#{provider}-#{email}.json",
      "name" => "#{provider}-#{email}.json",
      "provider" => provider,
      "email" => email,
      "status" => "active",
      "disabled" => false
    }

    Fake.update(context.fake, &%{&1 | credentials: &1.credentials ++ [account]})
    refresh(context)
  end

  step "the proxy handed out these requests today:", %{datatable: table} = context do
    records =
      for row <- maps(table) do
        %{
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "auth_id" => row["account"],
          "model" => row["model"],
          "failed" => row["failed"] == "true",
          "tokens" => %{
            "input_tokens" => String.to_integer(row["input"]),
            "output_tokens" => String.to_integer(row["output"])
          }
        }
      end

    Fake.update(context.fake, &%{&1 | queue: &1.queue ++ records})
    context
  end

  step "the proxy logs {string} and the page refreshes", %{args: [line]} = context do
    Fake.update(context.fake, &%{&1 | logs: &1.logs ++ [line]})
    refresh(context)
  end

  step "the proxy exits saying its port is taken", context do
    pid = status(context)["pid"]
    assert is_integer(pid)
    # The pid the plugin reports is the fake this scenario started.
    {_, 0} = System.cmd("kill", ["-USR1", to_string(pid)])
    Map.put(context, :pid, pid)
  end

  # --- the page ------------------------------------------------------------------------

  step "the page refreshes {int} times", %{args: [n]} = context do
    Enum.reduce(1..n, context, fn _, context -> refresh(context) end)
  end

  step("the page refreshes", context, do: refresh(context))

  step "the user signs in to {string} from the page", %{args: [provider]} = context do
    {reply, context} = call!(context, "signIn", %{"provider" => provider})
    Map.put(context, :sign_in, reply)
  end

  step "the user tries to sign in to {string} from the page", %{args: [provider]} = context do
    {reply, context} = call(context, "signIn", %{"provider" => provider})
    Map.put(context, :reply, reply)
  end

  step "the user pastes the address the browser ended on", context do
    finish(context, "http://localhost:54545/callback?code=abc&state=#{state(context)}")
  end

  step "the user pastes an address the provider ended with the error {string}",
       %{args: [error]} = context do
    finish(context, "http://localhost:1455/auth/callback?error=#{error}&state=#{state(context)}")
  end

  step "the user cancels the sign-in from the page", context do
    {_, context} = call!(context, "cancelSignIn")
    context
  end

  step "the user switches the account {string} off", %{args: [email]} = context do
    {_, context} =
      call!(context, "toggleAccount", %{
        "name" => account(context, email)["name"],
        "disabled" => true
      })

    context
  end

  step "the user removes the account {string}", %{args: [email]} = context do
    {_, context} = call!(context, "removeAccount", %{"name" => account(context, email)["name"]})
    context
  end

  step "the user adds the {string} API key {string} with the base URL {string}",
       %{args: [provider, key, base]} = context do
    {_, context} =
      call!(context, "addKey", %{"provider" => provider, "apiKey" => key, "baseUrl" => base})

    context
  end

  step "the user adds the {string} API key {string}", %{args: [provider, key]} = context do
    {reply, context} = call(context, "addKey", %{"provider" => provider, "apiKey" => key})
    Map.put(context, :reply, reply)
  end

  step "the user removes the {string} key {string}", %{args: [provider, masked]} = context do
    key = Enum.find(view(context)["keys"], &(&1["provider"] == provider and masked in &1["keys"]))
    assert key

    {_, context} =
      call!(context, "removeKey", %{"provider" => provider, "id" => key["id"]})

    context
  end

  step "the user clears the log", context do
    {_, context} = call!(context, "clearLogs")
    context
  end

  step "the user adds {string} back from the page", %{args: [label]} = context do
    name = Enum.find(status(context)["instances"], &(&1["label"] == label))["name"]
    {_, context} = call!(context, "addInstance", %{"name" => name})
    context
  end

  # --- Settings → Providers --------------------------------------------------------------

  step "the user renamed {string} to {string}", %{args: [id, label]} = context do
    write(context, &put_in(&1, ["providerInstances", id, "displayName"], label))
  end

  step "the user has a Codex instance of their own as {string} named {string}",
       %{args: [id, label]} = context do
    write(context, fn settings ->
      Map.update(
        settings,
        "providerInstances",
        %{id => %{"driver" => "codex", "displayName" => label}},
        &Map.put(&1, id, %{"driver" => "codex", "displayName" => label})
      )
    end)
  end

  step "the user deletes {string} in Settings → Providers", %{args: [id]} = context do
    write(context, &Map.update!(&1, "providerInstances", fn all -> Map.delete(all, id) end))
  end

  # --- checks ----------------------------------------------------------------------------

  step "the proxy runs with the config in the plugin's data folder", context do
    assert [run] = runs()
    assert run.args == ["-config", Path.join(dir(), "config.yaml")]
    assert status(context)["pid"] == run.pid
    context
  end

  step "the config listens on 127.0.0.1 at the plugin's port, with remote management off",
       context do
    config = config()
    assert config["server"] == %{"host" => "127.0.0.1", "port" => context.fake.port}
    assert config["management"]["allow-remote"] == false
    assert config["access"]["api-keys"] == [client_key()]
    context
  end

  step "the config keeps the proxy's accounts in the plugin's data folder", context do
    assert config()["oauth"]["auth-dir"] == Path.join(dir(), "auths")
    assert File.dir?(Path.join(dir(), "auths"))
    context
  end

  step "the management key and the client key are files only the user can read", context do
    for file <- ["management.key", "client.key", "config.yaml"] do
      %File.Stat{mode: mode} = File.stat!(Path.join(dir(), file))
      assert Bitwise.band(mode, 0o777) == 0o600, "#{file} is #{Integer.to_string(mode, 8)}"
    end

    context
  end

  step "the proxy was given the management key and the data folder", context do
    assert [run] = runs()
    assert run.env == %{"MANAGEMENT_PASSWORD" => "set", "WRITABLE_PATH" => dir()}
    management = File.read!(Path.join(dir(), "management.key"))

    assert Enum.all?(
             Fake.requests(context.fake),
             &(&1["authorization"] == "Bearer " <> management)
           )

    context
  end

  step "the page shows the proxy {string}", %{args: [state]} = context do
    await_status(context, &(&1["state"] == state))
  end

  step "the page shows the proxy {string} saying {string}", %{args: [state, text]} = context do
    await_status(context, &(&1["state"] == state and (&1["message"] || "") =~ text))
  end

  step "the proxy runs again as a new process", context do
    old = context.pid
    context = await_status(context, &(is_integer(&1["pid"]) and &1["pid"] != old))
    assert alive?(status(context)["pid"])
    refute alive?(old)
    context
  end

  step "the proxy's process has ended", context do
    [run] = runs()
    refute alive?(run.pid)
    context
  end

  step "no proxy has run", context do
    assert runs() == []
    context
  end

  step "the proxy runs from {string} in the plugin's data folder", %{args: [path]} = context do
    context = await_status(context, &(&1["state"] == "running"))
    binary = Path.join(dir(), path)
    assert status(context)["binary"] == binary
    assert Bitwise.band(File.stat!(binary).mode, 0o111) != 0
    refute File.exists?(Path.join(dir(), "download"))
    context
  end

  step "nothing is installed in the plugin's data folder", context do
    refute File.exists?(Path.join(dir(), "bin"))
    refute File.exists?(Path.join(dir(), "download"))
    context
  end

  step "the page offers CLIProxyAPI {string} as an update", %{args: [version]} = context do
    assert status(context)["latest"] == version
    context
  end

  step "the page shows the proxy running CLIProxyAPI 8.0.79, downloading nothing", context do
    assert %{"state" => "running", "version" => @version, "source" => "setting"} = status(context)
    refute Enum.any?(Fake.requests(context.fake), &String.starts_with?(&1["path"], "/releases"))
    context
  end

  step "the proxy lets agents in with the plugin's client key", context do
    assert Fake.get(context.fake).access == [client_key()]
    context
  end

  step "the proxy lets agents in with {string} and the plugin's client key",
       %{args: [key]} = context do
    assert Fake.get(context.fake).access == [key, client_key()]
    context
  end

  step "the proxy lets agents in only with {string}", %{args: [key]} = context do
    assert Fake.get(context.fake).access == [key]
    context
  end

  step "the proxy was asked nothing after {string}", %{args: [request]} = context do
    last = Fake.requests(context.fake) |> List.last()

    assert last["method"] <> " " <> String.replace_prefix(last["path"], "/v8/management", "") ==
             request

    context
  end

  step "the proxy holds only the {string} key {string}", %{args: [provider, key]} = context do
    assert [%{"keys" => [%{"api-key" => ^key}]}] = Fake.get(context.fake).keys[provider]
    context
  end

  step "the proxy starts with the {string} key {string}", %{args: [provider, key]} = context do
    assert [%{"keys" => [%{"api-key" => ^key}]}] = config()["api-keys"][provider]
    context
  end

  step "the proxy was asked with the management key {string}", %{args: [key]} = context do
    requests = Fake.requests(context.fake)
    assert requests != []
    assert Enum.all?(requests, &(&1["authorization"] == "Bearer " <> key))
    context
  end

  step "the proxy was refused once", context do
    assert [_] =
             Enum.filter(Fake.requests(context.fake), &String.starts_with?(&1["path"], "/v8/"))

    context
  end

  step "the page gives the proxy's sign-in address for {string}", %{args: [provider]} = context do
    assert context.sign_in["url"] =~ "/oauth/#{provider}?state="
    assert view(context)["signIn"]["status"] == "wait"
    context
  end

  # The proxy's own callback page (`is_webui`) answers only on its machine; the
  # address pasted back works from any client.
  step "the sign-in is one the user finishes by pasting the address", context do
    [start] = Enum.filter(Fake.requests(context.fake), &(&1["path"] =~ "/oauth/auth-url"))
    refute Map.has_key?(start["query"], "is_webui")
    context
  end

  step "the page lists the {string} account {string}", %{args: [provider, email]} = context do
    assert %{"provider" => ^provider, "disabled" => false} = account(context, email)
    context
  end

  step "the page lists the account {string} as off", %{args: [email]} = context do
    assert %{"disabled" => true} = account(context, email)
    context
  end

  step "the page lists no accounts", context do
    assert view(context)["accounts"] == []
    context
  end

  step "no sign-in is waiting", context do
    assert view(context)["signIn"] == nil
    context
  end

  step "the sign-in failed saying {string}", %{args: [text]} = context do
    assert %{"status" => "error", "error" => error} = view(context)["signIn"]
    assert error =~ text
    context
  end

  step "the proxy was told to forget the sign-in", context do
    state = context.sign_in["url"] |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    assert Enum.any?(
             Fake.requests(context.fake),
             &(&1["method"] == "DELETE" and &1["path"] =~ "/oauth/session" and
                 &1["query"]["state"] == state["state"])
           )

    context
  end

  step "the page shows today's usage:", %{datatable: table} = context do
    today = Date.utc_today() |> Date.to_iso8601()

    shown =
      for row <- view(context)["usage"], row["day"] == today do
        %{
          "account" => row["account"],
          "model" => row["model"],
          "requests" => to_string(row["requests"]),
          "failed" => to_string(row["failed"]),
          "input" => to_string(row["inputTokens"]),
          "output" => to_string(row["outputTokens"])
        }
      end

    assert Enum.sort(shown) == Enum.sort(maps(table))
    context
  end

  step "the page shows no usage, saying {string}", %{args: [text]} = context do
    view = view(context)
    assert view["usage"] == []
    assert view["usageNote"] =~ text
    context
  end

  step "the page shows the {string} key {string} with the base URL {string}",
       %{args: [provider, masked, base]} = context do
    assert [%{"provider" => ^provider, "keys" => [^masked], "baseUrl" => ^base}] =
             view(context)["keys"]

    context
  end

  step "the page never shows the key {string}", %{args: [key]} = context do
    refute JSON.encode!(view(context)) =~ key
    refute JSON.encode!(status(context)) =~ key
    context
  end

  step "the page shows no upstream keys", context do
    assert view(context)["keys"] == []
    context
  end

  step "the page's call fails saying {string}", %{args: [text]} = context do
    assert {:error, _, _} = context.reply
    assert inspect(context.reply) =~ text
    context
  end

  step "the page shows the log line {string}", %{args: [line]} = context do
    assert line in view(context)["logs"]
    context
  end

  step "the page shows no log lines", context do
    assert view(context)["logs"] == []
    context
  end

  step "Settings → Providers has {string} named {string}", %{args: [id, label]} = context do
    assert %{"displayName" => ^label} = instance(id)
    context
  end

  step "Settings → Providers has no {string}", %{args: [id]} = context do
    refute instance(id)
    context
  end

  step "the agent of {string} is sent to the proxy with the plugin's client key and no API key",
       %{args: [id]} = context do
    env = HalC2.Settings.instance_env(id)
    assert instance(id)["driver"] == "claudeAgent"
    assert env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:#{context.fake.port}"
    assert env["ANTHROPIC_AUTH_TOKEN"] == client_key()
    assert env["ANTHROPIC_API_KEY"] == ""
    context
  end

  step "the agent of {string} keeps its Claude home in the plugin's data folder",
       %{args: [id]} = context do
    assert HalC2.Settings.instance_setting(id, "homePath") == Path.join(dir(), "claude")
    context
  end

  step "the agent of {string} uses the proxy as its model provider, with the plugin's client key",
       %{args: [id]} = context do
    assert instance(id)["driver"] == "codex"
    args = HalC2.Settings.instance_setting(id, "launchArgs")
    assert args =~ "-c model_provider=cliproxyapi"
    assert args =~ "model_providers.cliproxyapi.base_url=http://127.0.0.1:#{context.fake.port}/v1"
    assert args =~ "model_providers.cliproxyapi.env_key=CLIPROXYAPI_API_KEY"
    assert HalC2.Settings.instance_env(id)["CLIPROXYAPI_API_KEY"] == client_key()
    context
  end

  step "the agent of {string} is sent to {string}", %{args: [id, url]} = context do
    case instance(id)["driver"] do
      "claudeAgent" ->
        assert HalC2.Settings.instance_env(id)["ANTHROPIC_BASE_URL"] == url

      "codex" ->
        assert HalC2.Settings.instance_setting(id, "launchArgs") =~
                 "model_providers.cliproxyapi.base_url=#{url} "
    end

    context
  end

  step "the page shows {string} as removed", %{args: [label]} = context do
    await_status(context, fn status ->
      Enum.any?(status["instances"], &(&1["label"] == label and &1["state"] == "dismissed"))
    end)
  end

  step "the page shows {string} as not added, saying {string}",
       %{args: [label, text]} = context do
    await_status(context, fn status ->
      Enum.any?(
        status["instances"],
        &(&1["label"] == label and &1["state"] == "taken" and &1["message"] =~ text)
      )
    end)
  end

  # --- helpers ---------------------------------------------------------------------------

  defp run_settings(context, binary),
    do: %{"mode" => "run", "binaryPath" => binary, "port" => context.fake.port}

  defp save(context, patch) do
    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => @id, "settings" => patch})

    context
  end

  defp turn_on(context) do
    {_, context} =
      World.call!(context, "plugins.enable", %{
        "id" => @id,
        "acceptPermissions" => ["providers:configure"]
      })

    assert %{"status" => "running"} = Fixtures.entry(@id)
    # The plugin applies its settings before it answers a call.
    status(context)
    watch(context)
  end

  defp turn_off(context) do
    {_, context} = World.call!(context, "plugins.disable", %{"id" => @id})
    context
  end

  defp server, do: Process.whereis(HalC2Plugins.CliProxyApi)

  defp answer(context, request, reply) do
    Fake.update(context.fake, fn fake ->
      %{fake | next: Map.update(fake.next, request, [reply], &(&1 ++ [reply]))}
    end)

    context
  end

  defp call(context, method, input \\ %{}) do
    World.call(context, "plugins.call", %{"id" => @id, "method" => method, "input" => input})
  end

  defp call!(context, method, input \\ %{}) do
    World.call!(context, "plugins.call", %{"id" => @id, "method" => method, "input" => input})
  end

  defp view(context) do
    {view, _} = call!(context, "status")
    view
  end

  defp status(context), do: view(context)["status"]

  defp refresh(context) do
    {_, context} = call!(context, "refresh")
    context
  end

  defp finish(context, address) do
    {_, context} = call!(context, "finishSignIn", %{"address" => address})
    context
  end

  defp state(context) do
    context.sign_in["url"]
    |> URI.parse()
    |> Map.get(:query)
    |> URI.decode_query()
    |> Map.get("state")
  end

  defp account(context, email) do
    Enum.find(view(context)["accounts"], &(&1["email"] == email))
  end

  # The archive under every name a unix machine could ask for, so the scenario needs
  # nothing of the plugin's to know which one this machine is.
  defp release(context, checksum) do
    archive = Path.join(context.mc.home, "cli-proxy-api.tar.gz")

    :ok =
      :erl_tar.create(to_charlist(archive), [{~c"cli-proxy-api", File.read!(@binary)}], [
        :compressed
      ])

    bytes = File.read!(archive)
    signed = if checksum == :match, do: bytes, else: "something else"
    hex = :crypto.hash(:sha256, signed) |> Base.encode16(case: :lower)

    names =
      for os <- ~w(linux darwin freebsd),
          arch <- ~w(amd64 aarch64 aarch64_no-plugin),
          do: "CLIProxyAPI_#{@version}_#{os}_#{arch}.tar.gz"

    sums = Enum.map_join(names, fn name -> "#{hex}  #{name}\n" end)
    files = Map.new(names, &{&1, bytes}) |> Map.put("checksums.txt", sums)
    Fake.update(context.fake, &%{&1 | release: files})
    context
  end

  defp maps(table) do
    [header | rows] = table.raw
    Enum.map(rows, &Map.new(Enum.zip(header, &1)))
  end

  defp dir, do: HalC2.Plugins.Host.data_dir(@id)

  defp config, do: Path.join(dir(), "config.yaml") |> File.read!() |> JSON.decode!()

  defp client_key, do: Path.join(dir(), "client.key") |> File.read!() |> String.trim()

  # What the fake binary noted of each run: its pid, its arguments and its environment.
  defp runs do
    case File.read(Path.join(dir(), "fake-runs.log")) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true) do
          [pid, flag, path, password, writable] = String.split(line, " ")
          [_, password] = String.split(password, "=", parts: 2)
          [_, writable] = String.split(writable, "=", parts: 2)

          %{
            pid: String.to_integer(pid),
            args: [flag, path],
            env: %{"MANAGEMENT_PASSWORD" => password, "WRITABLE_PATH" => writable}
          }
        end

      {:error, :enoent} ->
        []
    end
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))

  defp instance(id), do: (HalC2.Settings.settings()["providerInstances"] || %{})[id]

  # As a client saves settings: the document it read, changed, with that version.
  defp write(context, fun) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings", %{})

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{
        "settings" => fun.(settings),
        "version" => version
      })

    context
  end

  defp watch(context) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => @id,
      "topic" => "status"
    }

    client = context |> World.client("cliproxyapi") |> Mc.sub(sub, shape)
    context |> World.put_client("cliproxyapi", client) |> Map.put(:watched, sub)
  end

  # The status as the page has it: now, or once the `status` topic says so.
  defp await_status(context, fun) do
    if fun.(status(context)) do
      context
    else
      {_, client} =
        Mc.await(
          World.client(context, "cliproxyapi"),
          &(&1["t"] == "plugin" and &1["id"] == context.watched and !!fun.(&1["value"])),
          15_000
        )

      World.put_client(context, "cliproxyapi", client)
    end
  end
end
