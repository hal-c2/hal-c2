defmodule HalC2.Steps.Providers.ProviderSetup do
  @moduledoc """
  Steps for `features/providers/provider-setup.feature`: status checks that never
  set anything up, updates run by the installer that owns a provider, and ACP
  sign-in (`provider.auth.*`), which belongs to the client that started it.

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

  # Codex 0.1.0 installed by Homebrew, behind the latest release 0.2.0, under no
  # compatibility policy unless the scenario set one.
  defp homebrew_codex(ctx) do
    ctx = Acp.ready(ctx)
    homebrew(ctx, "codex", :codex_command, "fake_codex.py", "codex-cli %s", "0.1.0")

    :persistent_term.put(
      {HalC2.ProviderUpdates, "codex"},
      {"0.2.0", System.monotonic_time(:millisecond)}
    )

    assert Acp.provider("codex")["versionAdvisory"]["status"] == "behind_latest"
    # The check an MC runs at boot, here against the Homebrew fake just installed.
    HalC2.Codex.Provider.load()
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
    # Its versions are made up: the bundled manifest's policies would call them
    # broken or unsupported, and an update to one is refused. A scenario sets its own.
    unless Application.get_env(:hal_c2, :provider_compatibility),
      do: World.put_app_env(:provider_compatibility, [])

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

  # Opening the pipe read-write never blocks, whether or not brew is reading it. With
  # nobody reading yet the line is lost, so this is only for cleaning up.
  defp release(hold), do: System.cmd("sh", ["-c", "echo go 1<>#{hold}"])

  # Hands brew its line: opening the pipe to write waits until brew has opened it to
  # read, however long brew takes to get there. Off the caller's process, which goes
  # on reporting; a writer brew never meets is let go by `release/1` at the end.
  defp release_to_reader(hold),
    do: spawn(fn -> System.cmd("sh", ["-c", "echo go > #{hold}"]) end)

  # Reports Codex's and Claude's update states to `test`, releasing Claude's brew
  # once Codex's update waits for it.
  defp watch_updates(test, hold) do
    receive do
      {:hal_c2_providers_changed, _} ->
        for driver <- ["codex", "claudeAgent"],
            state = :persistent_term.get({HalC2.ProviderUpdates, driver, :state}, nil) do
          send(test, {:update_state, driver, state})
          if driver == "codex" and state["status"] == "queued", do: release_to_reader(hold)
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
    if context[:compatibility],
      do: compatibility_shown(context, title),
      else: auth_shown(context, title)
  end

  defp auth_shown(context, message) do
    assert context.shown["message"] == message
    context
  end

  defp compatibility_shown(context, title) do
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
    {_, ctx} = ctx |> paired("second") |> Acp.watch_auth("grok", "second")
    {%{"flowId" => flow_id}, ctx} = start_sign_in(ctx, "first")
    {state, ctx} = Acp.await_auth(ctx, "grok", waiting?(flow_id), "first")
    Map.put(ctx, :sign_in, state)
  end

  # Also used by acp-registry.feature, whose agent is `context.auth_instance`. The
  # other client sees that it runs, but not where to sign in.
  step "the other client shows the same sign-in in progress", context do
    instance = context[:auth_instance] || "grok"
    {state, ctx} = Acp.await_auth(context, instance, &(&1["phase"] == "waiting"), "second")
    assert_redacted(state)
    ctx
  end

  step "both clients see it finish when the client that started it completes it", context do
    %{"flowId" => flow_id, "interaction" => interaction} = context.sign_in
    ctx = accept(context, flow_id, interaction, "first")

    Enum.reduce(["first", "second"], ctx, fn name, ctx ->
      {state, ctx} = Acp.await_auth(ctx, "grok", &(&1["phase"] == "succeeded"), name)
      assert state["message"] == "Sign-in complete."
      ctx
    end)
  end

  step "the user started a sign-in for an ACP agent on one client", context do
    ctx = signed_out_grok(context)
    {_, ctx} = Acp.watch_auth(ctx, "grok", "first")
    {_, ctx} = ctx |> paired("second") |> Acp.watch_auth("grok", "second")
    {%{"flowId" => flow_id}, ctx} = start_sign_in(ctx, "first")
    {state, ctx} = Acp.await_auth(ctx, "grok", waiting?(flow_id), "first")
    Map.put(ctx, :sign_in, state)
  end

  step "another client looks at that provider", context do
    {state, ctx} = Acp.await_auth(context, "grok", &(&1["phase"] == "waiting"), "second")
    Map.put(ctx, :seen, state)
  end

  step "it shows {string}", %{args: [message]} = context do
    assert context.seen["message"] == message
    context
  end

  step "it shows no sign-in address or interaction", context do
    assert_redacted(context.seen)
    refute JSON.encode!(context.seen) =~ "acme.test"
    context
  end

  # Both refusals must say the same; `context.reply` is the last.
  step "another client answers or cancels that sign-in", context do
    %{"flowId" => flow_id, "interaction" => interaction} = context.sign_in

    {answered, ctx} =
      World.call(
        context,
        "provider.auth.respond",
        %{
          "instanceId" => "grok",
          "flowId" => flow_id,
          "interactionId" => interaction["id"],
          "response" => %{"type" => "browser", "action" => "accept"}
        },
        "second"
      )

    {cancelled, ctx} =
      World.call(
        ctx,
        "provider.auth.cancel",
        %{"instanceId" => "grok", "flowId" => flow_id},
        "second"
      )

    assert refusal(answered) =~ "This sign-in is no longer active in this client."
    Map.put(ctx, :reply, cancelled)
  end

  # The client that started it still has it, waiting for the user, and can finish it.
  step "the sign-in keeps running", context do
    %{"flowId" => flow_id, "interaction" => interaction} = context.sign_in
    {state, ctx} = start_sign_in(context, "first")
    assert %{"flowId" => ^flow_id, "phase" => "waiting"} = state
    ctx = accept(ctx, flow_id, interaction, "first")
    {_, ctx} = Acp.await_auth(ctx, "grok", &(&1["phase"] == "succeeded"), "first")
    ctx
  end

  step "the first sign-in keeps running", context do
    flow_id = context.sign_in["flowId"]
    {state, ctx} = start_sign_in(context, "first")
    assert %{"flowId" => ^flow_id, "phase" => "waiting"} = state
    assert [_] = Acp.requests(ctx, "grok", "authenticate")
    ctx
  end

  step "another client starts a sign-in for the same instance", context do
    {reply, ctx} =
      World.call(
        paired(context, "second"),
        "provider.auth.start",
        %{"instanceId" => "grok", "methodId" => "acme-login"},
        "second"
      )

    Map.put(ctx, :reply, reply)
  end

  # The flow's timer, five minutes after it started, fired.
  step "a sign-in for an ACP agent expired after five minutes", context do
    ctx = signed_out_grok(context)
    {_, ctx} = Acp.watch_auth(ctx, "grok")
    {%{"flowId" => flow_id}, ctx} = start_sign_in(ctx)
    {state, ctx} = Acp.await_auth(ctx, "grok", waiting?(flow_id))
    send(Acp.auth_server("grok"), {:expire, flow_id})
    {_, ctx} = Acp.await_auth(ctx, "grok", &(&1["phase"] == "failed"))
    Map.put(ctx, :sign_in, state)
  end

  step "the user answers the expired sign-in", context do
    %{"flowId" => flow_id, "interaction" => interaction} = context.sign_in

    {reply, ctx} =
      World.call(context, "provider.auth.respond", %{
        "instanceId" => "grok",
        "flowId" => flow_id,
        "interactionId" => interaction["id"],
        "response" => %{"type" => "browser", "action" => "accept"}
      })

    Map.put(ctx, :reply, reply)
  end

  step "the user starts a sign-in with a method the provider did not advertise", context do
    ctx = signed_out_grok(context)
    {_, ctx} = Acp.watch_auth(ctx, "grok")

    {reply, ctx} =
      World.call(ctx, "provider.auth.start", %{"instanceId" => "grok", "methodId" => "made-up"})

    Map.put(ctx, :reply, reply)
  end

  step "the user started a sign-in for an ACP agent", context do
    ctx = signed_out_grok(context)
    {_, ctx} = Acp.watch_auth(ctx, "grok")
    {state, ctx} = start_sign_in(ctx)
    Map.merge(ctx, %{sign_in: state, shown: state})
  end

  step "the provider has been asked to start", context do
    # What `provider.auth.start` answered.
    context
  end

  step "the provider waits for the user to finish", context do
    {state, ctx} = Acp.await_auth(context, "grok", waiting?(context.sign_in["flowId"]))
    Map.put(ctx, :shown, state)
  end

  step "the provider is checking the finished sign-in", context do
    flow_id = context.sign_in["flowId"]
    {%{"interaction" => interaction}, ctx} = Acp.await_auth(context, "grok", waiting?(flow_id))
    ctx = accept(ctx, flow_id, interaction, "default")
    {state, ctx} = Acp.await_auth(ctx, "grok", &(&1["phase"] == "verifying"))
    Map.put(ctx, :shown, state)
  end

  step "the user cancels the sign-in", context do
    {state, ctx} =
      World.call!(context, "provider.auth.cancel", %{
        "instanceId" => "grok",
        "flowId" => context.sign_in["flowId"]
      })

    Map.put(ctx, :shown, state)
  end

  # The sign-in's worker goes down with a reason no step of it gives.
  step "the sign-in fails for no known reason", context do
    {_, ctx} = Acp.await_auth(context, "grok", waiting?(context.sign_in["flowId"]))
    Process.exit(:sys.get_state(Acp.auth_server("grok")).flow.worker, :crashed)
    {state, ctx} = Acp.await_auth(ctx, "grok", &(&1["phase"] == "failed"))
    Map.put(ctx, :shown, state)
  end

  step "five minutes pass with no answer from the user", context do
    flow_id = context.sign_in["flowId"]
    {_, ctx} = Acp.await_auth(context, "grok", waiting?(flow_id))
    send(Acp.auth_server("grok"), {:expire, flow_id})
    {state, ctx} = Acp.await_auth(ctx, "grok", &(&1["phase"] == "failed"))
    Map.put(ctx, :shown, state)
  end

  step "the sign-in shows {string}", %{args: [message]} = context do
    assert context.shown["message"] == message
    context
  end

  step "an ACP agent's sign-in methods were listed", context do
    ctx = signed_out_grok(context)
    {state, ctx} = Acp.watch_auth(ctx, "grok")
    assert [%{"id" => "acme-login"}] = state["methods"]
    Map.put(ctx, :listed, state["methods"])
  end

  # The agent no longer starts, and the user refreshes its provider.
  step "the MC cannot refresh them", context do
    Acp.control(context, "grok", %{"initializeError" => "agent is broken"})

    {_, ctx} =
      World.call!(context, "server.refreshProviders", %{"instanceId" => "grok"})

    {state, ctx} = Acp.await_auth(ctx, "grok", &(&1["message"] != nil))
    Map.put(ctx, :refreshed, state)
  end

  step "the earlier methods stay listed", context do
    assert context.refreshed["methods"] == context.listed
    context
  end

  step "the user is told why they could not be refreshed", context do
    assert context.refreshed["message"] == "Could not discover this agent's sign-in methods."
    context
  end

  # Grok's agent holds its sign-out until the pipe it waits on gets a line; a shell
  # opens the pipe to write, which waits until the agent opened it to read, and says
  # so. The MC's own sign-out runs off this process.
  step "the provider is signing out", context do
    ctx = signed_out_grok(context)
    File.write!(Path.join(Acp.dir(ctx), "grok.auth"), "signed in")
    hold = Path.join(Acp.dir(ctx), "logout.hold")
    {_, 0} = System.cmd("mkfifo", [hold])
    Acp.control(ctx, "grok", %{"logoutHold" => hold})
    test = self()

    spawn(fn ->
      send(test, {:signed_out, HalC2.ProviderAuth.logout(%{"instanceId" => "grok"})})
    end)

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", "exec 3>#{hold}; echo holding; read line; echo go >&3"]
      ])

    assert_receive {^port, {:data, "holding\n"}}, 30_000
    Map.put(ctx, :logout_hold, port)
  end

  step "the user starts a sign-in", context do
    {reply, ctx} =
      World.call(context, "provider.auth.start", %{
        "instanceId" => "grok",
        "methodId" => "acme-login"
      })

    # The sign-out then finishes.
    port = ctx.logout_hold
    Port.command(port, "\n")
    assert_receive {^port, {:exit_status, 0}}, 30_000
    assert_receive {:signed_out, {:ok, %{"message" => "Signed out."}}}, 30_000
    Map.put(ctx, :reply, reply)
  end

  # --- sign-out ------------------------------------------------------------------------

  step "the user signs out and it succeeds", context do
    {_, ctx} = Acp.watch_auth(context, "grok")
    {state, ctx} = World.call!(ctx, "provider.auth.logout", %{"instanceId" => "grok"})
    Map.put(ctx, :shown, state)
  end

  # The calling client's frames before the reply are skipped, so another client watches.
  step "the user signs out and it fails", context do
    Acp.control(context, "grok", %{"logoutError" => "token store is locked"})
    {_, ctx} = Acp.watch_auth(context, "grok", "watcher")
    {reply, ctx} = World.call(ctx, "provider.auth.logout", %{"instanceId" => "grok"})
    assert refusal(reply) =~ "Could not sign out. Try again."
    refute refusal(reply) =~ "token store"
    {state, ctx} = Acp.await_auth(ctx, "grok", &(&1["phase"] == "failed"), "watcher")
    Map.put(ctx, :shown, state)
  end

  # The client `name`, reconnected as another paired device: the MC's own token's sockets
  # (`two clients are connected to the MC`) are all one client, which sees its sign-ins
  # whole on each of them.
  def paired(ctx, name) do
    if name in (ctx[:paired] || []),
      do: ctx,
      else:
        ctx
        |> World.put_client(name, Mc.connect_as(ctx.mc, Mc.pair()))
        |> Map.update(:paired, [name], &[name | &1])
  end

  defp assert_redacted(state) do
    assert %{
             "flowId" => nil,
             "authorizationUrl" => nil,
             "interaction" => nil,
             "expiresAt" => nil,
             "message" => "Sign-in is in progress in another client."
           } = state

    refute Map.has_key?(state, "_owner")
  end

  defp accept(ctx, flow_id, interaction, name) do
    {_, ctx} =
      World.call!(
        ctx,
        "provider.auth.respond",
        %{
          "instanceId" => "grok",
          "flowId" => flow_id,
          "interactionId" => interaction["id"],
          "response" => %{"type" => "browser", "action" => "accept"}
        },
        name
      )

    ctx
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
    # Started on the mobile app, the only client that may answer it.
    {_, ctx} = Acp.watch_auth(ctx, "grok", "mobile")

    {%{"flowId" => flow_id}, ctx} =
      World.call!(
        ctx,
        "provider.auth.start",
        %{"instanceId" => "grok", "methodId" => "cli"},
        "mobile"
      )

    {state, ctx} =
      Acp.await_auth(
        ctx,
        "grok",
        fn state ->
          waiting?(flow_id).(state) and state["interaction"]["type"] == "terminal" and
            state["interaction"]["output"] =~ "Paste code"
        end,
        "mobile"
      )

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
      Acp.await_auth(
        context,
        "grok",
        fn state ->
          state["flowId"] == flow_id and state["interaction"]["type"] == "terminal" and
            state["interaction"]["output"] =~ "Signed in."
        end,
        "mobile"
      )

    {_, ctx} =
      Acp.await_auth(
        ctx,
        "grok",
        &(&1["flowId"] == flow_id and &1["phase"] == "succeeded"),
        "mobile"
      )

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

  # --- an update to a release that does not work here ----------------------------------

  step "Codex is behind the latest release", context do
    homebrew_codex(context)
  end

  # Codex 0.1.0 is supported; its latest release, 0.2.0, is not.
  step "that latest release is known to be broken with this HAL-C2 release", context do
    Application.put_env(:hal_c2, :provider_compatibility, [
      %{
        "driver" => "codex",
        "halC2Range" => ">=0",
        "recommendedRange" => "<0.2",
        "ranges" => [
          %{"range" => "<0.2", "status" => "supported"},
          %{"range" => ">=0.2", "status" => "broken"}
        ]
      }
    ])

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :provider_compatibility) end)
    context
  end

  # A client offers an update unless the provider says its latest release is broken or
  # unsupported here (`getProviderVersionAdvisoryPresentation`).
  step "Codex is not offered an update to that release", context do
    codex = Enum.find(context.providers, &(&1["instanceId"] == "codex"))
    assert %{"status" => "behind_latest", "latestVersion" => "0.2.0"} = codex["versionAdvisory"]

    assert %{"status" => "supported", "latestVersionStatus" => "broken"} =
             codex["compatibilityAdvisory"]

    context
  end

  # --- sign-out ------------------------------------------------------------------------

  # Grok, signed in, with one thread in the middle of a turn and one that finished.
  step "the user is signed in to an ACP agent", context do
    ctx = signed_out_grok(context)
    File.write!(Path.join(Acp.dir(ctx), "grok.auth"), "signed in")
    assert %{"status" => "authenticated", "canLogout" => true} = Acp.check("grok")["auth"]

    ctx = Acp.launch(ctx, "Finished", "grok", "hello")
    [%{"status" => "completed"}] = Acp.await_runs(ctx.threads["Finished"], 1)

    ctx = Acp.launch(ctx, "Running", "grok", "wait for me")

    Acp.await_stream(ctx.threads["Running"], fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))
    end)

    assert [_ | _] = Acp.requests(ctx, "grok", "session/prompt")
    ctx
  end

  # The client asks first; the MC is told once the user confirms.
  step "the user signs out and confirms", context do
    {state, ctx} = World.call!(context, "provider.auth.logout", %{"instanceId" => "grok"})
    assert %{"phase" => "idle", "message" => "Signed out."} = state
    ctx
  end

  step "running threads sharing that sign-in stop", context do
    assert [%{"status" => "interrupted"}] = Acp.await_runs(context.threads["Running"], 1)
    assert [_] = Acp.requests(context, "grok", "logout")
    assert Acp.check("grok")["auth"]["status"] == "unauthenticated"
    # The thread that had finished keeps what the agent said ("thread history is kept"
    # checks every thread's messages).
    assert Acp.assistant_text(context.threads["Finished"]) != ""
    context
  end

  # --- which registry says what is latest -----------------------------------------------

  # Codex 0.1.0 at a global npm prefix, not yet compared with any release. The public
  # registry (a fake) has 9.9.9.
  step "Codex was installed with npm", context do
    ctx = HalC2.Steps.Settings.Updates.install(context, "Codex", "a global npm install")
    :persistent_term.erase({HalC2.ProviderUpdates, "codex"})
    World.put_app_env(:provider_update_checks, true)

    {url, registry} =
      HalC2.Test.FakeHttp.start(%{"/@openai%2Fcodex/latest" => {200, %{"version" => "9.9.9"}}})

    World.put_app_env(:npm_registry_url, url)
    HalC2.Test.LogTap.attach()
    :ok = HalC2.Settings.watch(self())
    Map.put(ctx, :registry, registry)
  end

  # npm on the PATH answers from the registry it is set up with, which has 8.8.8.
  step "npm on the MC's path is configured for a company registry", context do
    npm_on_path(context, ~s(echo '"8.8.8"'))
  end

  step "npm on the MC's path fails to look the version up", context do
    npm_on_path(context, ~s(echo "npm error code E401" >&2; exit 1))
  end

  step "npm is not installed on the machine", context do
    without_npm(context)
  end

  # Only the tools a provider's version check runs, and no npm: the public registry
  # (the fake) is asked.
  defp without_npm(context) do
    bin = Path.join(context.mc.home, "path-without-npm")

    unless File.dir?(bin) do
      File.mkdir_p!(bin)

      for tool <- ~w(sh dirname readlink cat printf python3 git env uname),
          path = System.find_executable(tool),
          do: File.ln_s!(path, Path.join(bin, tool))

      World.put_env("PATH", bin)
    end

    refute System.find_executable("npm")
    context
  end

  step "the MC checks provider versions twice within an hour", context do
    context = context |> without_npm() |> HalC2.Steps.Settings.Updates.check()
    assert latest_read(context) == "9.9.9"
    HalC2.Steps.Settings.Updates.check(context)
  end

  step "the registry is asked for the latest Codex version once", context do
    assert [_] = public_reads(context)
    context
  end

  # A deadline of 200ms stands in for four seconds. The reply, 9.9.9, comes far later,
  # so a status that is unknown (not 9.9.9) is the deadline's doing.
  step "the package registry does not answer within four seconds", context do
    stalled_registry(context, fn _conn ->
      Process.sleep(3_000)
      {200, %{"version" => "9.9.9"}}
    end)
  end

  step "the package registry answers at once but stops sending before the version arrives",
       context do
    stalled_registry(context, fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, ~s({"name":"@openai/codex","versi))
      Process.sleep(3_000)
      # The MC has hung up by now.
      _ = Plug.Conn.chunk(conn, ~s(on":"9.9.9"}))
      conn
    end)
  end

  step ~r/^(after four seconds )?Codex's update status is unknown(, with no message for the user)?$/,
       context do
    read_ended()
    assert [_] = public_reads(context)
    advisory = Acp.provider("codex")["versionAdvisory"]
    assert %{"status" => "unknown", "latestVersion" => nil, "message" => nil} = advisory
    context
  end

  defp stalled_registry(context, answer) do
    World.put_app_env(:npm_registry_timeout, 200)
    {url, registry} = HalC2.Test.FakeHttp.start(%{"/@openai%2Fcodex/latest" => answer})
    World.put_app_env(:npm_registry_url, url)
    context |> without_npm() |> Map.put(:registry, registry)
  end

  # Every read, found or not, ends with the providers announced (after it stops reading).
  defp read_ended do
    assert_receive {:hal_c2_providers_changed, _}, 15_000
    if :persistent_term.get({HalC2.ProviderUpdates, "codex", :reading}, false), do: read_ended()
  end

  step "the latest version comes from the company registry", context do
    assert latest_read(context) == "8.8.8"
    prefix = Path.join(context.mc.home, "npm")

    assert context.mc.home |> Path.join("npm-view.log") |> File.read!() |> codex_lines() ==
             ["view --global --prefix #{prefix} --json @openai/codex@latest version"]

    assert public_reads(context) == []
    context
  end

  step "Codex's update status is unknown and the public registry is not asked", context do
    assert_receive {:logged, :warning, "Configured npm version lookup failed" <> _}, 15_000
    advisory = Acp.provider("codex")["versionAdvisory"]
    assert %{"status" => "unknown", "latestVersion" => nil, "message" => nil} = advisory
    assert public_reads(context) == []
    context
  end

  step "the latest version comes from the public npm registry", context do
    assert latest_read(context) == "9.9.9"

    assert [_] = public_reads(context)

    context
  end

  # Other providers found on this machine are looked up too.
  defp codex_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "@openai/codex"))

  defp public_reads(context),
    do:
      Enum.filter(
        HalC2.Test.FakeHttp.requests(context.registry),
        &(&1["path"] == "/@openai%2Fcodex/latest")
      )

  defp npm_on_path(context, answer) do
    bin = Path.join(context.mc.home, "path-bin")
    log = Path.join(context.mc.home, "npm-view.log")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "npm"), "#!/bin/sh\necho \"$*\" >> #{log}\n#{answer}\n")
    File.chmod!(Path.join(bin, "npm"), 0o755)
    World.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    context
  end

  # The read lands, and the providers are announced with it.
  defp latest_read(context) do
    assert_receive {:hal_c2_providers_changed, _}, 15_000

    case Acp.provider("codex")["versionAdvisory"]["latestVersion"] do
      nil -> latest_read(context)
      version -> version
    end
  end

  # --- how an update runs ---------------------------------------------------------------

  # Codex's update command, the npm at its global prefix (`Codex is behind the latest
  # version`), replaced with `script`.
  defp npm_update(context, script) do
    npm = Path.join([context.mc.home, "npm", "bin", "npm"])
    File.write!(npm, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(npm, 0o755)
    context
  end

  defp update_ran?(context),
    do: File.exists?(Path.join([context.mc.home, "npm", "npm.log"])) or brew_log(context) != []

  defp codex_update_state, do: Acp.provider("codex")["updateState"]

  # Claude 1.0.0 from Homebrew, reported behind 1.1.0; then, before the MC reads
  # its version again, it is at 1.1.0 already.
  # The user was offered 1.2.0, read within the hour. By the update, Claude is 1.1.0,
  # and npm now says 1.1.0 is the latest (1.2.0 was pulled): only a reread of the
  # latest finds Claude current.
  step "a fresh check finds Claude installed at its latest version", context do
    ctx = claude_cached_at(context, "1.2.0", "1.1.0")
    File.write!(Path.join(ctx.mc.home, "homebrew/claude-code.version"), "1.1.0")
    ctx
  end

  # Claude 1.0.0 from Homebrew; the hour's cache says `cached` is the latest, while
  # npm now says `fresh` is.
  defp claude_cached_at(context, cached, fresh) do
    ctx = Acp.ready(context)
    homebrew(ctx, "claude-code", :claude_command, "fake_claude.py", "%s (Claude Code)", "1.0.0")
    key = {HalC2.ProviderUpdates, "claudeAgent"}
    :persistent_term.put(key, {cached, System.monotonic_time(:millisecond)})
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase(key) end)
    assert Acp.provider("claudeAgent")["versionAdvisory"]["status"] == "behind_latest"

    npm = Path.join(ctx.mc.home, "fake-bin/npm")
    script = File.read!(npm)

    File.write!(
      npm,
      String.replace(
        script,
        "#!/bin/sh\n",
        ~s(#!/bin/sh\nif [ "$1" = view ]; then echo '"#{fresh}"'; exit 0; fi\n)
      )
    )

    World.put_app_env(:provider_update_checks, true)
    ctx
  end

  # The cache says 1.2.0, which the policy supports; the source now says 1.3.0, which
  # it marks broken. Only a reread of the latest sees that.
  step "a read within the hour found Claude behind a supported latest version", context do
    claude_cached_at(context, "1.2.0", "1.3.0")
  end

  step "the latest version has since been marked broken for this HAL-C2 release", context do
    World.put_app_env(:provider_compatibility, [
      %{
        "driver" => "claudeAgent",
        "halC2Range" => ">=0",
        "recommendedRange" => "<1.3",
        "ranges" => [
          %{"range" => "<1.3", "status" => "supported"},
          %{"range" => ">=1.3", "status" => "broken"}
        ]
      }
    ])

    context
  end

  step "the update fails saying Claude's latest version is incompatible with this HAL-C2 release",
       context do
    message =
      "The latest provider version is incompatible with this HAL-C2 release. Review provider settings."

    assert {:error, ^message, _} = context.reply
    context
  end

  step "the update finishes with {string}", %{args: [message]} = context do
    assert {:ok, %{"providers" => providers}} = context.reply
    claude = Enum.find(providers, &(&1["instanceId"] == "claudeAgent"))
    assert %{"status" => "succeeded", "message" => ^message} = claude["updateState"]
    assert claude["versionAdvisory"]["status"] == "current"
    context
  end

  step "Claude's installer is not run", context do
    assert brew_log(context) == []
    context
  end

  # It runs until it is killed, and says which process it is.
  step "its update command does not finish within five minutes", context do
    World.put_app_env(:provider_update_timeout, 200)
    pid = Path.join(context.mc.home, "npm/update.pid")
    context |> npm_update(~s(echo $$ > #{pid}\nexec sleep 600)) |> Map.put(:update_pid, pid)
  end

  step "the update fails as timed out", context do
    assert {:error, "Update timed out.", _} = context.reply
    assert %{"status" => "failed", "message" => "Update timed out."} = codex_update_state()
    # The command was stopped: `tail --pid` returns once that process is gone.
    pid = context.update_pid |> File.read!() |> String.trim()

    waiter =
      Task.async(fn -> System.cmd("tail", ["-s", "0.05", "--pid=#{pid}", "-f", "/dev/null"]) end)

    assert {_, 0} = Task.await(waiter, 5_000)
    context
  end

  step "its update command exits with code 1 and prints an error", context do
    npm_update(context, ~s(echo "fetching @openai/codex"\necho "npm error code E404" >&2\nexit 1))
  end

  step "the update fails naming exit code 1", context do
    assert {:error, "Update command exited with code 1.", _} = context.reply
    context
  end

  # Upstream joins stderr then stdout, a blank line between.
  step "the update's result carries the command's error output", context do
    assert %{"status" => "failed", "message" => "Update command exited with code 1."} =
             state = codex_update_state()

    assert state["output"] =~ ~r/\Anpm error code E404\n\n+fetching @openai\/codex\z/
    context
  end

  step "its update command prints far more than ten thousand characters", context do
    npm_update(context, ~s(printf begin\nhead -c 30000 /dev/zero | tr '\\0' x\necho end\nexit 1))
  end

  step "the update's result carries only the first ten thousand characters of that output",
       context do
    assert {:error, _, _} = context.reply
    output = codex_update_state()["output"]
    assert String.length(output) == 10_000
    assert output == "begin" <> String.duplicate("x", 9_995)
    context
  end

  # Codex 0.1.0 at a global npm prefix under a policy that recommends 0.1.5.
  step "the user asked to install the recommended {string} of Codex",
       %{args: [version]} = context do
    context =
      context
      |> HalC2.Steps.Settings.Updates.install("Codex", "a global npm install")
      |> HalC2.Steps.Settings.Updates.check()

    World.put_app_env(:provider_compatibility, [recommending("codex", version)])
    Map.put(context, :target_version, version)
  end

  step "{string} stopped being the recommended version before the update ran",
       %{args: [version]} = context do
    [policy] = Application.get_env(:hal_c2, :provider_compatibility)
    assert policy["recommendedVersion"] == version
    World.put_app_env(:provider_compatibility, [%{policy | "recommendedVersion" => "0.1.6"}])
    context
  end

  step "the update starts", context do
    {reply, context} =
      World.call(context, "server.updateProvider", %{
        "provider" => "codex",
        "targetVersion" => context.target_version
      })

    Map.put(context, :reply, reply)
  end

  step "the update fails telling the user to refresh provider settings", context do
    message =
      "This version is no longer recommended or this installer cannot install a specific version. Refresh provider settings."

    assert {:error, ^message, _} = context.reply
    assert %{"status" => "failed", "message" => ^message} = codex_update_state()
    context
  end

  step "no update command is run", context do
    refute update_ran?(context)
    context
  end

  # Codex's latest release is 9.9.9; the policy now gives it `status`.
  step ~r/^that latest release was marked (?<status>unsupported|broken) for this HAL-C2 release after the last check$/,
       %{args: [status]} = context do
    assert HalC2.Steps.Settings.Updates.advisory(context, "Codex")["latestVersion"] == "9.9.9"

    World.put_app_env(:provider_compatibility, [
      %{
        "driver" => "codex",
        "halC2Range" => ">=0",
        "recommendedRange" => "<9",
        "ranges" => [
          %{"range" => "<9", "status" => "supported"},
          %{"range" => ">=9", "status" => status}
        ]
      }
    ])

    context
  end

  step "the update fails saying the latest version is incompatible with this HAL-C2 release",
       context do
    message =
      "The latest provider version is incompatible with this HAL-C2 release. Review provider settings."

    assert {:error, ^message, _} = context.reply
    assert %{"status" => "failed", "message" => ^message} = codex_update_state()
    context
  end

  # npm installs, but the Codex it leaves cannot say its version.
  step "its update command succeeds but the provider's version cannot be read afterwards",
       context do
    codex = Path.join(context.mc.home, "npm/lib/node_modules/@openai/codex/bin/codex.js")
    npm_update(context, ~s(printf '#!/bin/sh\\nexit 1\\n' > #{codex}))
  end

  step "the user is told the update finished but the version could not be verified", context do
    assert {:ok, _} = context.reply

    assert %{
             "status" => "unchanged",
             "message" =>
               "Update command completed, but HAL-C2 could not verify the provider version."
           } = codex_update_state()

    context
  end

  # Codex's npm holds until the scenario lets it go; the update is seen running.
  step "a Codex update is running", context do
    context = context |> HalC2.Steps.Settings.Updates.install("Codex", "a global npm install")
    context = HalC2.Steps.Settings.Updates.check(context)
    hold = Path.join(context.mc.home, "npm/update.hold")
    {_, 0} = System.cmd("mkfifo", [hold])
    ExUnit.Callbacks.on_exit(fn -> release(hold) end)
    npm = Path.join(context.mc.home, "npm")

    npm_update(
      context,
      ~s(read line < #{hold}\necho "$@" >> #{npm}/npm.log\necho 9.9.9 > #{npm}/lib/node_modules/@openai/codex/bin/version)
    )

    test = self()

    watcher =
      spawn_link(fn ->
        :ok = HalC2.Settings.watch(self())
        send(test, :watching)
        watch_codex(test)
      end)

    assert_receive :watching
    ExUnit.Callbacks.on_exit(fn -> Process.exit(watcher, :kill) end)
    update = Task.async(fn -> HalC2.ProviderUpdates.update(%{"provider" => "codex"}) end)
    assert_receive {:codex_update, %{"status" => "running"}}, 5_000
    context |> Map.put(:first_update, update) |> Map.put(:hold, hold)
  end

  step "the user updates Codex again", context do
    {reply, context} = World.call(context, "server.updateProvider", %{"provider" => "codex"})
    Map.put(context, :reply, reply)
  end

  step "the second update is refused saying an update is already running for that provider",
       context do
    assert {:error, "An update is already running for this provider.", _} = context.reply
    # The first goes on, and ends as its own.
    assert %{"status" => "running"} = codex_update_state()
    release_to_reader(context.hold)
    assert {:ok, _} = Task.await(context.first_update)
    assert %{"status" => "succeeded"} = codex_update_state()

    assert [_] =
             context.mc.home
             |> Path.join("npm/npm.log")
             |> File.read!()
             |> String.split("\n", trim: true)

    context
  end

  defp watch_codex(test) do
    receive do
      {:hal_c2_providers_changed, _} ->
        if state = :persistent_term.get({HalC2.ProviderUpdates, "codex", :state}, nil),
          do: send(test, {:codex_update, state})

        watch_codex(test)

      _ ->
        watch_codex(test)
    end
  end

  # A policy for `driver` that supports every release and recommends `version`.
  defp recommending(driver, version),
    do: %{
      "driver" => driver,
      "halC2Range" => ">=0",
      "recommendedVersion" => version,
      "ranges" => [%{"range" => ">=0", "status" => "supported"}]
    }
end
