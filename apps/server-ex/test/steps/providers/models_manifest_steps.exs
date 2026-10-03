defmodule HalC2.Steps.Providers.ModelsManifest.Served do
  @moduledoc false
  # Serves the file a scenario publishes its model manifest in.
  @behaviour Plug
  def init(path), do: path

  def call(conn, path) do
    case File.read(path) do
      {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
      _ -> Plug.Conn.send_resp(conn, 404, "")
    end
  end
end

defmodule HalC2.Steps.Providers.ModelsManifest do
  @moduledoc """
  More steps for `features/providers/models.feature`: the model manifest an MC
  fetches (`HalC2.ModelManifest`, published here on a loopback server), custom model
  options, older model names, and a provider that cannot change models in a thread.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.ModelManifest
  alias HalC2.StreamState
  alias HalC2.Steps.Plugins.{Fixtures, Turns}
  alias HalC2.Test.AcpFixtures, as: Acp
  alias HalC2.Test.FakeAcp
  alias HalC2.Test.Mc.World

  @nova "claude-nova-9"

  # --- publishing a manifest -----------------------------------------------------------

  # What the manifest's maintainers would publish next: a new Claude model that is
  # also the default, edited after this release was cut.
  defp newer(manifest \\ ModelManifest.bundled()) do
    catalog = manifest["providers"]["claudeAgent"]
    profile = hd(catalog["models"])["profile"]

    nova =
      %{"slug" => @nova, "name" => "Claude Nova 9", "status" => "current"}
      |> then(&if(profile, do: Map.put(&1, "profile", profile), else: &1))

    catalog =
      catalog
      |> Map.update!("models", &[nova | &1])
      |> Map.put("defaults", %{"chat" => @nova})

    manifest
    |> Map.put("updatedAt", "2099-01-01T00:00:00Z")
    |> put_in(["providers", "claudeAgent"], catalog)
    |> update_in(["currentModels", "claudeAgent"], &[@nova | &1 || []])
  end

  # Publishes `body` where the MC fetches its manifest from.
  defp publish(context, body) do
    context = serve(context)
    File.write!(context.manifest_file, body)
    context
  end

  defp serve(%{manifest_file: _} = context), do: context

  defp serve(context) do
    file = Path.join(context.mc.home, "published-models.json")

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__.Served, file}, port: 0, ip: :loopback},
        id: :model_manifest_server
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    World.put_app_env(:model_manifest_url, "http://127.0.0.1:#{port}/model-manifest.json")
    fresh(context) |> Map.put(:manifest_file, file)
  end

  # An MC that has read nothing yet; what a scenario leaves in memory goes with it.
  defp fresh(context) do
    ModelManifest.forget()
    ExUnit.Callbacks.on_exit(&ModelManifest.forget/0)
    context
  end

  defp refresh(context) do
    {_, context} = World.call!(context, "server.refreshProviders", %{})
    context
  end

  defp claude_models(context) do
    {providers, context} = World.provider_list(context)
    {Enum.find(providers, &(&1["instanceId"] == "claudeAgent"))["models"], context}
  end

  defp cached(_context),
    do: ModelManifest.cache_path() |> File.read!() |> JSON.decode!() |> Map.fetch!("manifest")

  # --- fetching ----------------------------------------------------------------------------

  step "a newer model manifest is published", context do
    context = context |> World.fake_providers() |> publish(JSON.encode!(newer()))
    {models, context} = claude_models(context)
    refute Enum.any?(models, &(&1["slug"] == @nova))
    context
  end

  step "the MC refreshes the manifest", context do
    refresh(context)
  end

  step "the newer models and defaults are offered", context do
    {models, context} = claude_models(context)

    assert %{"name" => "Claude Nova 9", "isDefault" => true} =
             Enum.find(models, &(&1["slug"] == @nova))

    assert [_] = Enum.filter(models, & &1["isDefault"])

    # It is kept, so the next start uses it without the network.
    assert cached(context) == newer()
    ModelManifest.forget()
    assert ModelManifest.current() == newer()
    context
  end

  step "the MC downloads a manifest that is not valid", context do
    context = context |> World.fake_providers() |> publish(JSON.encode!(newer())) |> refresh()
    assert ModelManifest.current() == newer()

    duplicate =
      update_in(newer(), ["providers", "claudeAgent", "models"], fn [first | _] = models ->
        [first | models]
      end)

    invalid = [
      "<html>not a manifest</html>",
      JSON.encode!(Map.put(newer(), "version", 2)),
      JSON.encode!(Map.delete(newer(), "currentModels")),
      JSON.encode!(Map.put(duplicate, "updatedAt", "2099-06-01T00:00:00Z")),
      JSON.encode!(
        newer()
        |> Map.put("updatedAt", "2099-06-01T00:00:00Z")
        |> put_in(["providers", "claudeAgent", "defaults", "chat"], "claude-not-listed")
      )
    ]

    Enum.reduce(invalid, context, &(&2 |> publish(&1) |> refresh()))
  end

  step "the last usable manifest is kept", context do
    assert ModelManifest.current() == newer()
    assert cached(context) == newer()
    {models, context} = claude_models(context)
    assert %{"isDefault" => true} = Enum.find(models, &(&1["slug"] == @nova))
    context
  end

  # The cached copy is a manifest fetched before this release was cut, naming a model
  # the release no longer carries.
  step "the MC was updated with a manifest newer than its cached copy", context do
    context = context |> World.fake_providers() |> fresh()
    bundled = ModelManifest.bundled()

    stale =
      bundled
      |> newer()
      |> Map.put("updatedAt", "2020-01-01T00:00:00Z")

    assert ModelManifest.valid?(stale)
    assert stale["updatedAt"] < bundled["updatedAt"]

    File.mkdir_p!(Path.dirname(ModelManifest.cache_path()))

    File.write!(
      ModelManifest.cache_path(),
      JSON.encode!(%{"fetchedAtMs" => System.system_time(:millisecond), "manifest" => stale})
    )

    context
  end

  step "the bundled manifest is used", context do
    bundled = ModelManifest.bundled()
    assert ModelManifest.current() == bundled
    {models, context} = claude_models(context)
    catalog = bundled["providers"]["claudeAgent"]
    assert [_ | _] = models
    assert Enum.map(models, & &1["slug"]) -- Enum.map(catalog["models"], & &1["slug"]) == []
    # The cached copy's default did not replace the release's.
    assert Enum.all?(models, &(&1["isDefault"] == (&1["slug"] == catalog["defaults"]["chat"])))
    context
  end

  # --- compatibility policies ------------------------------------------------------------

  defp policy(driver, range, status) do
    %{
      "driver" => driver,
      "halC2Range" => ">=0",
      "recommendedRange" => ">=" <> String.trim_leading(range, "<"),
      "ranges" => [%{"range" => range, "status" => status}]
    }
  end

  # OpenCode 1.20.0 and Grok 0.5.0, the "other provider".
  step "the bundled manifest has compatibility policies for OpenCode and another provider",
       context do
    for key <- [:codex_command, :claude_command],
        do: World.put_app_env(key, ["hal-c2-test-not-installed"])

    bundled =
      Map.put(ModelManifest.bundled(), "compatibility", [
        policy("opencode", "<1.14.19", "broken"),
        policy("grok", "<1.0.0", "unsupported")
      ])

    World.put_app_env(:model_manifest_bundled, bundled)

    context =
      context
      |> fresh()
      |> FakeAcp.install("opencode", %{"version" => "1.20.0"}, enabled: true)
      |> FakeAcp.install("grok", %{"version" => "0.5.0"}, enabled: true)

    # The bundled OpenCode policy has nothing against 1.20.0.
    assert %{"status" => "unknown"} = FakeAcp.probe("opencode")["compatibilityAdvisory"]
    assert %{"status" => "unsupported"} = FakeAcp.probe("grok")["compatibilityAdvisory"]
    context
  end

  step "a newer manifest changes only OpenCode's policy", context do
    fetched =
      ModelManifest.bundled()
      |> Map.put("updatedAt", "2099-01-01T00:00:00Z")
      |> Map.put("compatibility", [policy("opencode", "<2.0.0", "broken")])

    publish(context, JSON.encode!(fetched))
  end

  step "OpenCode's versions are judged by the fetched policy", context do
    {providers, context} = FakeAcp.open_config(context)

    assert %{"status" => "broken", "recommendedRange" => ">=2.0.0", "message" => message} =
             FakeAcp.find(providers, "opencode")["compatibilityAdvisory"]

    assert message =~ "Use >=2.0.0."
    context
  end

  step "the other provider keeps its bundled policy", context do
    assert %{"status" => "unsupported", "recommendedRange" => ">=1.0.0"} =
             FakeAcp.find(context.providers, "grok")["compatibilityAdvisory"]

    context
  end

  # --- custom model options ------------------------------------------------------------------

  # The editor's "copy from" writes the built-in model's options into the custom entry.
  step "the user copies the options of a built-in Claude model into {string}",
       %{args: [slug]} = context do
    context = World.fake_providers(context)
    {models, context} = claude_models(context)

    source =
      Enum.find(models, &match?([_ | _], get_in(&1, ["capabilities", "optionDescriptors"]))) ||
        flunk("no built-in Claude model has options")

    context =
      Acp.write_settings(context, fn settings ->
        update_in(
          settings,
          [
            Access.key("providers", %{}),
            Access.key("claudeAgent", %{}),
            Access.key("customModels", [])
          ],
          &(&1 ++ [%{"slug" => slug, "capabilities" => source["capabilities"]}])
        )
      end)

    Map.put(context, :copied_from, source)
  end

  step "{string} offers the same options", %{args: [slug]} = context do
    {models, context} = claude_models(context)
    custom = Enum.find(models, &(&1["slug"] == slug)) || flunk("#{slug} is not offered")
    assert %{"isCustom" => true} = custom
    assert custom["capabilities"] == context.copied_from["capabilities"]
    refute context.copied_from["isCustom"]
    context
  end

  # --- older model names -------------------------------------------------------------------

  @alias "gpt-5-codex"

  step "a thread saved with an older alias of a Codex model", context do
    System.put_env(
      "FAKE_CODEX_MODELS",
      JSON.encode!([
        %{"model" => "gpt-6-luna", "displayName" => "GPT-6 Luna", "isDefault" => true},
        %{"model" => "gpt-5.4", "displayName" => "GPT-5.4"}
      ])
    )

    context = World.fake_providers(context)
    HalC2.Codex.Provider.load()

    context
    |> World.create_thread("Old", nil, %{
      "modelSelection" => %{"instanceId" => "codex", "model" => @alias}
    })
    |> Map.put(:current_thread, "Old")
  end

  # A client names a thread's model from its provider's list, by id or alias
  # (`ComposerModel`), and the thread's next turn runs on the model it names today.
  step "the thread shows the current name of that model", context do
    assert %{"instanceId" => "codex", "model" => @alias} =
             World.thread(context, "Old")["modelSelection"]

    models = FakeAcp.find(context.providers, "codex")["models"]
    refute Enum.any?(models, &(&1["slug"] == @alias))

    assert %{"slug" => "gpt-5.4", "name" => "GPT-5.4"} =
             Enum.find(models, &(@alias in (&1["aliases"] || [])))

    context = World.post_message(context, "Old", "hello")
    World.await_value(context, "Old", &(StreamState.list(&1, "run") != []))
    World.await_idle(context, "Old")

    start =
      World.await_provider_log(context, "codex", &(get_in(&1, ["in", "method"]) == "turn/start"))

    assert get_in(start, ["in", "params", "model"]) == "gpt-5.4"
    context
  end

  # --- a provider that keeps its model for the life of a thread -------------------------------

  step "a provider that cannot change models inside a thread", context do
    capabilities = HalC2.Plugins.ProviderAdapter.capabilities() -- [:model_switching]

    context =
      context
      |> Turns.providers()
      |> Fixtures.install("acme", Fixtures.provider("acme", capabilities: capabilities))
      |> Fixtures.enable("acme")

    {thread_id, context} =
      Turns.send_first(context, "acme", "hello", %{
        "modelSelection" => %{"instanceId" => "acme", "model" => "acme-1"}
      })

    [_] = Turns.await_runs(thread_id, ["completed"])
    Map.put(context, :thread_id, thread_id)
  end

  step "the user picks another model in an existing thread", context do
    command =
      context.thread_id
      |> Turns.message("m2", "try the other model")
      |> Map.put("modelSelection", %{"instanceId" => "acme", "model" => "acme-2"})

    {reply, context} = World.dispatch(context, command)
    Map.put(context, :reply, reply)
  end

  step "the user is offered to start a new thread with that model", context do
    assert {:error, message, _} = context.reply

    assert message ==
             "Acme cannot change the model of a running session. Start a new thread to use acme-2."

    # The provider says so up front, which is what a client offers the new thread on.
    assert %{"requiresNewThreadForModelChange" => true} =
             FakeAcp.find(HalC2.Environment.providers(), "acme")

    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(context.thread_id))
    assert [%{"status" => "completed"}] = StreamState.list(state, "run")

    assert %{"model" => "acme-1"} =
             StreamState.get(state, "thread")[context.thread_id]["modelSelection"]

    context
  end
end
