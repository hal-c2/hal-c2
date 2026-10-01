defmodule HalC2.Steps.Providers.ProviderSetup do
  @moduledoc """
  Steps for `features/providers/provider-setup.feature`: status checks that never
  set anything up, updates run by the installer that owns a provider, and ACP
  sign-in (`provider.auth.*`) shared by every client of the MC.

  The ACP agent that signs in is Grok run as the fake agent of
  `HalC2.Test.AcpFixtures`; it asks the user to open a sign-in page
  (`https://acme.test/login`) and is signed in once the user accepts.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Steps.Providers.Antigravity
  alias HalC2.Test.AcpFixtures, as: Acp
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @login [%{"id" => "acme-login", "name" => "Log in with Acme"}]

  # The ledger's words for a compatibility status, and the title clients show for it.
  @compatibility %{
    "of limited support" => {"graceful", "Limited support"},
    "unsupported" => {"unsupported", "Unsupported version"},
    "known to be broken" => {"broken", "Known broken version"}
  }

  # Grok, enabled and signed out, offering a browser sign-in.
  defp signed_out_grok(ctx, control \\ %{}) do
    ctx = Acp.ready(ctx)
    Acp.run_as(ctx, "grok", "grok")
    Acp.control(ctx, "grok", Map.merge(%{"auth" => "file", "methods" => @login}, control))
    Acp.put_provider("grok", %{"enabled" => true})
    ctx
  end

  defp start_sign_in(ctx, name \\ "default") do
    {state, ctx} =
      World.call!(
        ctx,
        "provider.auth.start",
        %{"instanceId" => "grok", "methodId" => "acme-login"},
        name
      )

    {state, ctx}
  end

  defp waiting?(flow_id), do: &(&1["phase"] == "waiting" and &1["flowId"] == flow_id)

  # The config snapshot a client gets when it opens its settings.
  defp opened_providers(ctx, name \\ "default") do
    sub = 2000 + System.unique_integer([:positive])

    client =
      Mc.sub(World.client(ctx, name), sub, %{
        "type" => "config",
        "mc" => Atom.to_string(node())
      })

    {frame, client} = Mc.await(client, &(&1["t"] == "config" and &1["id"] == sub), 5_000)
    {frame["config"]["providers"], World.put_client(ctx, name, client)}
  end

  # Codex 0.1.0 installed by Homebrew, behind the latest release 0.2.0.
  defp homebrew_codex(ctx) do
    ctx = Acp.ready(ctx)
    homebrew(ctx, "codex", :codex_command, "fake_codex.py", "codex-cli %s", "0.1.0")

    :persistent_term.put(
      {HalC2.ProviderUpdates, "codex"},
      {"0.2.0", System.monotonic_time(:millisecond)}
    )

    assert Acp.provider("codex")["versionAdvisory"]["status"] == "behind_latest"
    ctx
  end

  # A Homebrew install of `name` at `version`, run through the `app_key` command. Its
  # executable lives in the Cellar, linked into Homebrew's bin, and reports the
  # version in `homebrew/<name>.version` (printed with `format`); anything else runs
  # the fake. The fake `brew` logs each upgrade to `brew.log`, holds while
  # `homebrew/<name>.hold` is a pipe nobody wrote to, and moves the version to
  # `homebrew/<name>.upgrade` when that exists; `npm` logs it ran.
  defp homebrew(ctx, name, app_key, fake, format, version) do
    home = ctx.mc.home
    brew = Path.join(home, "homebrew")
    fake = Path.expand("../../support/#{fake}", __DIR__)
    version_file = Path.join(brew, "#{name}.version")
    File.mkdir_p!(brew)
    File.write!(version_file, version)

    cellar = Path.join(brew, "Cellar/#{name}/#{version}/bin/#{name}")
    File.mkdir_p!(Path.dirname(cellar))
    line = String.replace(format, "%s", "$(cat #{version_file})")

    File.write!(cellar, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "#{line}"; exit 0; fi
    exec python3 -u #{fake} "$@"
    """)

    File.chmod!(cellar, 0o755)
    linked = Path.join(brew, "bin/#{name}")
    File.mkdir_p!(Path.dirname(linked))
    File.ln_s!(cellar, linked)
    Application.put_env(:hal_c2, app_key, [linked])

    bin = Path.join(home, "fake-bin")

    unless File.exists?(bin) do
      File.mkdir_p!(bin)
      log = Path.join(home, "brew.log")

      File.write!(Path.join(bin, "brew"), """
      #!/bin/sh
      echo "start $2" >> #{log}
      if [ -p #{brew}/$2.hold ]; then read line < #{brew}/$2.hold; fi
      if [ -f #{brew}/$2.upgrade ]; then cp #{brew}/$2.upgrade #{brew}/$2.version; fi
      echo "end $2" >> #{log}
      """)

      File.write!(Path.join(bin, "npm"), "#!/bin/sh\necho \"npm $*\" >> #{log}\n")
      for tool <- ["brew", "npm"], do: File.chmod!(Path.join(bin, tool), 0o755)
      System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    end

    ctx
  end

  defp brew_log(ctx) do
    case File.read(Path.join(ctx.mc.home, "brew.log")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # Opening the pipe read-write never blocks, whether or not brew is reading it.
  defp release(hold), do: System.cmd("sh", ["-c", "echo go 1<>#{hold}"])

  # Reports Codex's and Claude's update states to `test`, releasing Claude's brew
  # once Codex's update waits for it.
  defp watch_updates(test, hold) do
    receive do
      {:hal_c2_providers_changed, _} ->
        for driver <- ["codex", "claudeAgent"],
            state = :persistent_term.get({HalC2.ProviderUpdates, driver, :state}, nil) do
          send(test, {:update_state, driver, state})
          if driver == "codex" and state["status"] == "queued", do: release(hold)
        end

        watch_updates(test, hold)

      _ ->
        watch_updates(test, hold)
    end
  end

  defp refusal({:error, error, detail}), do: "#{error} #{inspect(detail)}"
  defp refusal(other), do: flunk("expected a refusal, got #{inspect(other)}")

  # --- status checks -----------------------------------------------------------------

  step "Grok is enabled but not signed in", context do
    signed_out_grok(context)
  end

  step "the MC checks its providers in the background", context do
    HalC2.Acp.load()
    Map.put(context, :providers, HalC2.Environment.providers())
  end

  step "no sign-in or installation is started", context do
    # The check did read Grok, and found it signed out.
    assert [_ | _] = Acp.launches(context, "grok")
    grok = Enum.find(context.providers, &(&1["instanceId"] == "grok"))
    assert grok["auth"]["status"] == "unauthenticated"
    assert grok["setup"]["canAuthenticate"]

    assert Acp.requests(context, "grok", "authenticate") == []
    assert Acp.auth_server("grok") == nil
    refute File.exists?(Path.join(context.mc.home, "tools"))
    context
  end

  # --- updates -----------------------------------------------------------------------

  # Codex 0.1.0 under a policy that gives every release before 0.2 that status.
  step ~r/^the installed provider version is (?<status>of limited support|unsupported|known to be broken) for this HAL-C2 release$/,
       %{args: [status]} = context do
    {status, _title} = Map.fetch!(@compatibility, status)

    Application.put_env(:hal_c2, :provider_compatibility, [
      %{
        "driver" => "codex",
        "halC2Range" => ">=0",
        "recommendedRange" => ">=0.2",
        "ranges" => [%{"range" => "<0.2", "status" => status}]
      }
    ])

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :provider_compatibility) end)
    context |> homebrew_codex() |> Map.put(:compatibility, status)
  end

  # The title is the client's label for the status the MC reports.
  step "the provider shows {string}", %{args: [title]} = context do
    status = context.compatibility
    assert {status, title} in Map.values(@compatibility)
    codex = Enum.find(context.providers, &(&1["instanceId"] == "codex"))

    assert %{
             "status" => ^status,
             "message" => message,
             "recommendedRange" => ">=0.2",
             "recommendedVersion" => nil
           } = codex["compatibilityAdvisory"]

    assert message =~ "with this HAL-C2 release" or message =~ "for this HAL-C2 release"
    assert message =~ "Use >=0.2."
    # The provider still runs; the advisory only warns.
    assert codex["status"] == "ready"
    context
  end

  step "Codex was installed with Homebrew and is outdated", context do
    ctx = homebrew_codex(context)
    # Its upgrade brings it to the latest release.
    File.write!(Path.join(context.mc.home, "homebrew/codex.upgrade"), "0.2.0")
    ctx
  end

  step "Codex is updated through Homebrew", context do
    assert {:ok, %{"providers" => providers}} = context.reply
    assert brew_log(context) == ["start codex", "end codex"]
    codex = Enum.find(providers, &(&1["instanceId"] == "codex"))
    assert codex["version"] == "0.2.0"
    assert %{"status" => "succeeded", "message" => "Provider updated."} = codex["updateState"]
    context
  end

  step "the user is told this installation cannot install {string}",
       %{args: [version]} = context do
    assert {:error, message, _} = context.reply
    assert message == "This installation cannot install #{version}."
    assert brew_log(context) == []
    refute Acp.provider("codex")["versionAdvisory"]["canInstallVersion"]
    context
  end

  step "a Claude update is running", context do
    ctx = homebrew_codex(context)
    home = context.mc.home
    File.write!(Path.join(home, "homebrew/codex.upgrade"), "0.2.0")
    homebrew(ctx, "claude-code", :claude_command, "fake_claude.py", "%s (Claude Code)", "1.0.0")

    :persistent_term.put(
      {HalC2.ProviderUpdates, "claudeAgent"},
      {"1.1.0", System.monotonic_time(:millisecond)}
    )

    File.write!(Path.join(home, "homebrew/claude-code.upgrade"), "1.1.0")

    # Claude's brew holds until Codex's update is seen waiting for it.
    hold = Path.join(home, "homebrew/claude-code.hold")
    {_, 0} = System.cmd("mkfifo", [hold])
    ExUnit.Callbacks.on_exit(fn -> release(hold) end)
    test = self()

    watcher =
      spawn_link(fn ->
        :ok = HalC2.Settings.watch(self())
        send(test, :watching)
        watch_updates(test, hold)
      end)

    assert_receive :watching
    ExUnit.Callbacks.on_exit(fn -> Process.exit(watcher, :kill) end)
    claude = Task.async(fn -> HalC2.ProviderUpdates.update(%{"provider" => "claudeAgent"}) end)
    assert_receive {:update_state, "claudeAgent", %{"status" => "running"}}, 5_000
    Map.put(ctx, :claude_update, claude)
  end

  step "Codex's update waits for the Claude update to finish", context do
    assert_received {:update_state, "codex",
                     %{
                       "status" => "queued",
                       "message" => "Waiting for another provider update to finish."
                     }}

    assert {:ok, _} = Task.await(context.claude_update)
    assert {:ok, _} = context.reply

    assert brew_log(context) == [
             "start claude-code",
             "end claude-code",
             "start codex",
             "end codex"
           ]

    context
  end

  step "an update finishes but the provider still reports the old version", context do
    # Homebrew runs the upgrade but leaves Codex where it was.
    ctx = homebrew_codex(context)
    {reply, ctx} = World.call(ctx, "server.updateProvider", %{"provider" => "codex"})
    Map.put(ctx, :reply, reply)
  end

  step "the user is told the provider is still outdated", context do
    assert {:ok, %{"providers" => providers}} = context.reply
    assert brew_log(context) == ["start codex", "end codex"]
    codex = Enum.find(providers, &(&1["instanceId"] == "codex"))
    assert codex["versionAdvisory"]["status"] == "behind_latest"

    assert %{
             "status" => "unchanged",
             "message" =>
               "Update command completed, but HAL-C2 still detects an outdated provider version."
           } = codex["updateState"]

    context
  end

  step "Codex was reinstalled somewhere else after the last check", context do
    ctx = homebrew_codex(context)
    # The check offered Homebrew's upgrade.
    assert Acp.provider("codex")["versionAdvisory"]["updateCommand"] == "brew upgrade codex"

    # Then Codex was installed again with npm, which the MC has not reported yet.
    home = context.mc.home
    real = Path.join(home, "npm/lib/node_modules/@openai/codex/bin/codex.js")
    File.mkdir_p!(Path.dirname(real))
    File.cp!(Path.join(home, "homebrew/Cellar/codex/0.1.0/bin/codex"), real)
    linked = Path.join(home, "npm/bin/codex")
    File.mkdir_p!(Path.dirname(linked))
    File.ln_s!(real, linked)
    Application.put_env(:hal_c2, :codex_command, [linked])
    ctx
  end

  step "the update fails asking the user to refresh and try again", context do
    assert {:error, "Provider installation changed. Refresh and try again.", _} = context.reply
    # Neither installer ran.
    assert brew_log(context) == []

    assert %{"status" => "failed"} =
             Acp.provider("codex")["updateState"]

    context
  end

  step "the user opens Claude's update details", context do
    {providers, ctx} = opened_providers(context)
    Map.put(ctx, :claude, Enum.find(providers, &(&1["instanceId"] == "claudeAgent")))
  end

  step "no update command is offered for Claude", context do
    advisory = context.claude["versionAdvisory"]
    # The MC knows Claude is behind; it only has no updater to run.
    assert advisory["status"] == "behind_latest"
    assert advisory["updateCommand"] == nil
    assert advisory["canUpdate"] == false
    context
  end

  # --- sign-in -----------------------------------------------------------------------

  step "the user tries to sign in to Codex from HAL-C2", context do
    ctx = Acp.ready(context)
    {reply, ctx} = World.call(ctx, "provider.auth.start", %{"instanceId" => "codex"})
    Map.put(ctx, :reply, reply)
  end

  step "the user is told this provider does not sign in here", context do
    assert refusal(context.reply) =~ "This provider does not sign in here."
    context
  end

  step "the user starts signing in to an ACP agent on one client", context do
    ctx = signed_out_grok(context)
    {_, ctx} = Acp.watch_auth(ctx, "grok", "first")
    {_, ctx} = Acp.watch_auth(ctx, "grok", "second")
    {%{"flowId" => flow_id}, ctx} = start_sign_in(ctx, "first")
    {state, ctx} = Acp.await_auth(ctx, "grok", waiting?(flow_id), "first")
    Map.put(ctx, :sign_in, state)
  end

  # Also used by acp-registry.feature, whose agent is `context.auth_instance`.
  step "the other client shows the same sign-in in progress", context do
    %{"flowId" => flow_id, "interaction" => interaction} = context.sign_in
    instance = context[:auth_instance] || "grok"
    {state, ctx} = Acp.await_auth(context, instance, waiting?(flow_id), "second")
    assert state["interaction"] == interaction
    assert interaction["url"] == "https://acme.test/login"
    ctx
  end

  step "either client can finish or cancel it", context do
    flow_id = context.sign_in["flowId"]

    # The second client cancels what the first started; both see it end.
    {cancelled, ctx} =
      World.call!(
        context,
        "provider.auth.cancel",
        %{"instanceId" => "grok", "flowId" => flow_id},
        "second"
      )

    assert %{"phase" => "cancelled", "message" => "Sign-in cancelled."} = cancelled

    {_, ctx} =
      Acp.await_auth(
        ctx,
        "grok",
        &(&1["flowId"] == flow_id and &1["phase"] == "cancelled"),
        "first"
      )

    # The second client starts again, and the first finishes it.
    {%{"flowId" => again}, ctx} = start_sign_in(ctx, "second")
    {%{"interaction" => interaction}, ctx} = Acp.await_auth(ctx, "grok", waiting?(again), "first")

    {_, ctx} =
      World.call!(
        ctx,
        "provider.auth.respond",
        %{
          "instanceId" => "grok",
          "flowId" => again,
          "interactionId" => interaction["id"],
          "response" => %{"type" => "browser", "action" => "accept"}
        },
        "first"
      )

    Enum.reduce(["first", "second"], ctx, fn name, ctx ->
      {state, ctx} =
        Acp.await_auth(ctx, "grok", &(&1["flowId"] == again and &1["phase"] == "succeeded"), name)

      assert state["message"] == "Sign-in complete."
      ctx
    end)
  end

  step "a sign-in is in progress for an ACP agent", context do
    ctx = signed_out_grok(context)
    {_, ctx} = Acp.watch_auth(ctx, "grok")
    {%{"flowId" => flow_id}, ctx} = start_sign_in(ctx)
    {state, ctx} = Acp.await_auth(ctx, "grok", waiting?(flow_id))
    Map.put(ctx, :sign_in, state)
  end

  step "the user starts another sign-in for the same instance", context do
    {state, ctx} = start_sign_in(context)
    Map.put(ctx, :again, state)
  end

  step "the running sign-in is kept", context do
    assert context.again["flowId"] == context.sign_in["flowId"]
    assert context.again["phase"] == "waiting"
    assert context.again["interaction"] == context.sign_in["interaction"]
    # The agent was asked to sign in once.
    assert [_] = Acp.requests(context, "grok", "authenticate")
    context
  end

  # The agent's terminal method runs `<agent> login`, which asks for a code (`ok`).
  step "a terminal sign-in for an ACP agent is waiting for input", context do
    terminal = [
      %{"id" => "cli", "name" => "CLI login", "type" => "terminal", "args" => ["login"]}
    ]

    ctx = signed_out_grok(context, %{"methods" => terminal})
    {_, ctx} = Acp.watch_auth(ctx, "grok")

    {%{"flowId" => flow_id}, ctx} =
      World.call!(ctx, "provider.auth.start", %{"instanceId" => "grok", "methodId" => "cli"})

    {state, ctx} =
      Acp.await_auth(ctx, "grok", fn state ->
        waiting?(flow_id).(state) and state["interaction"]["type"] == "terminal" and
          state["interaction"]["output"] =~ "Paste code"
      end)

    Map.put(ctx, :sign_in, state)
  end

  # The mobile app is another client of the MC, answering over `provider.auth.respond`.
  step "the user sends a response from the mobile app", context do
    %{"flowId" => flow_id, "interaction" => interaction} = context.sign_in

    {_, ctx} =
      World.call!(
        context,
        "provider.auth.respond",
        %{
          "instanceId" => "grok",
          "flowId" => flow_id,
          "interactionId" => interaction["id"],
          "response" => %{"type" => "terminal", "data" => "ok\n"}
        },
        "mobile"
      )

    ctx
  end

  step "the response reaches the sign-in terminal on the MC", context do
    flow_id = context.sign_in["flowId"]

    {_, ctx} =
      Acp.await_auth(context, "grok", fn state ->
        state["flowId"] == flow_id and state["interaction"]["type"] == "terminal" and
          state["interaction"]["output"] =~ "Signed in."
      end)

    {_, ctx} =
      Acp.await_auth(ctx, "grok", &(&1["flowId"] == flow_id and &1["phase"] == "succeeded"))

    ctx
  end

  step "the user pastes a return address", context do
    {reply, ctx} =
      World.call(context, "provider.auth.complete", %{
        "instanceId" => "grok",
        "flowId" => context.sign_in["flowId"],
        "callbackUrl" => "http://localhost:1455/auth/callback?code=secret-code"
      })

    Map.put(ctx, :reply, reply)
  end

  step "the user is told this provider does not accept a pasted redirect URL", context do
    assert refusal(context.reply) =~ "This provider does not accept a pasted redirect URL."
    # The sign-in it was pasted into still runs.
    assert Acp.auth_server("grok") != nil
    context
  end

  step "a sign-in fails", context do
    # The agent's error carries the code and the address it asked the user to visit.
    ctx =
      signed_out_grok(context, %{
        "authenticateError" => "Visit https://acme.test/device?code=WXYZ-9876 and enter WXYZ-9876"
      })

    {_, ctx} = Acp.watch_auth(ctx, "grok")
    {%{"flowId" => flow_id}, ctx} = start_sign_in(ctx)

    {state, ctx} =
      Acp.await_auth(ctx, "grok", &(&1["flowId"] == flow_id and &1["phase"] == "failed"))

    Map.put(ctx, :failed, state)
  end

  step "the error shown to the user contains no sign-in code or return address", context do
    assert context.failed["message"] == "The ACP agent could not complete sign-in."
    shown = JSON.encode!(context.failed)
    refute shown =~ "WXYZ-9876"
    refute shown =~ "acme.test"
    context
  end

  # --- managed runtimes ---------------------------------------------------------------
  #
  # Antigravity is the provider whose runtime the MC installs itself; its release,
  # download and the older runtime already active come from antigravity_steps.exs.

  step "the user installs a managed provider runtime on one client", context do
    ctx = Antigravity.installer(context)
    ctx = Enum.reduce(["first", "second"], ctx, &watch_install(&2, &1))
    input = %{"instanceId" => "antigravity"}
    {_, ctx} = World.call!(ctx, "provider.install.start", input, "first")
    ctx
  end

  step "both clients show the download progress", context do
    total = context.release.archive_bytes

    Enum.reduce(["first", "second"], context, fn name, ctx ->
      {states, ctx} = install_states(ctx, name, &(&1["phase"] in ~w(succeeded failed)))
      downloading = Enum.filter(states, &(&1["phase"] == "downloading"))
      assert Enum.any?(downloading, &(&1["downloadedBytes"] == total))
      assert Enum.all?(downloading, &(&1["totalBytes"] == total))
      assert %{"phase" => "succeeded"} = List.last(states)
      ctx
    end)
  end

  step "a managed provider runtime is downloading", context do
    Antigravity.downloading(context)
  end

  step "the download stops and the previous runtime is unchanged", context do
    assert {:ok, %{"phase" => "cancelled", "operationId" => op}} = context.reply
    assert op == context.install_state["operationId"]
    ref = Process.monitor(context.fetch_worker)
    assert_receive {:DOWN, ^ref, :process, _, reason} when reason in [:killed, :noproc], 5_000
    Antigravity.previous_unchanged(context)
  end

  step "a managed provider runtime is installed and not in use", context do
    ctx = Antigravity.installer(context)

    assert %{"installedVersion" => "agy_acp_server_1.1.0", "canRemove" => true} =
             HalC2.Acp.Antigravity.Installation.state()

    assert HalC2.Acp.Antigravity.sessions("antigravity") == []
    ctx
  end

  step "the user removes it", context do
    input = %{"instanceId" => "antigravity"}
    {reply, ctx} = World.call(context, "provider.install.remove", input)
    Map.put(ctx, :reply, reply)
  end

  step "the provider shows that it is not installed", context do
    assert {:ok, %{"installedVersion" => nil, "canRemove" => false}} = context.reply
    {providers, ctx} = opened_providers(context)
    assert %{"installed" => false} = Enum.find(providers, &(&1["instanceId"] == "antigravity"))
    ctx
  end

  step "the user installs it again", context do
    ctx = Antigravity.watch_install(context)
    {_, ctx} = World.call!(ctx, "provider.install.start", %{"instanceId" => "antigravity"})
    {states, ctx} = Antigravity.collect_install(ctx, &(&1["phase"] in ~w(succeeded failed)))
    Map.put(ctx, :install_states, states)
  end

  step "the provider is installed", context do
    assert %{"phase" => "succeeded", "installedVersion" => "agy_acp_server_1.1.1"} =
             List.last(context.install_states)

    {providers, ctx} = opened_providers(context)
    assert %{"installed" => true} = Enum.find(providers, &(&1["instanceId"] == "antigravity"))
    ctx
  end

  # Subscribes client `name` to the Antigravity install state.
  defp watch_install(ctx, name) do
    sub = 3000 + System.unique_integer([:positive])

    shape = %{
      "type" => "providerInstall",
      "mc" => Atom.to_string(node()),
      "instanceId" => "antigravity"
    }

    client = Mc.sub(World.client(ctx, name), sub, shape)
    {_, client} = Mc.await(client, &(&1["t"] == "providerInstall" and &1["id"] == sub))

    ctx
    |> World.put_client(name, client)
    |> Map.update(:install_subs, %{name => sub}, &Map.put(&1, name, sub))
  end

  # The install states client `name` receives until one satisfies `done?`.
  defp install_states(ctx, name, done?, acc \\ []) do
    sub = ctx.install_subs[name]
    match = &(&1["t"] == "providerInstall" and &1["id"] == sub)
    {frame, client} = Mc.await(World.client(ctx, name), match, 15_000)
    ctx = World.put_client(ctx, name, client)
    acc = [frame["state"] | acc]

    if done?.(frame["state"]),
      do: {Enum.reverse(acc), ctx},
      else: install_states(ctx, name, done?, acc)
  end
end
