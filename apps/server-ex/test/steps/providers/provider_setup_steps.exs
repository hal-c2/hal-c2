defmodule T3.Steps.Providers.ProviderSetup do
  @moduledoc """
  Steps for `features/providers/provider-setup.feature`: status checks that never
  set anything up, updates run by the installer that owns a provider, and ACP
  sign-in (`provider.auth.*`) shared by every client of the node.

  The ACP agent that signs in is Grok run as the fake agent of
  `T3.Test.AcpFixtures`; it asks the user to open a sign-in page
  (`https://acme.test/login`) and is signed in once the user accepts.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias T3.Test.AcpFixtures, as: Acp
  alias T3.Test.Node
  alias T3.Test.Node.World

  @login [%{"id" => "acme-login", "name" => "Log in with Acme"}]

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
      Node.sub(World.client(ctx, name), sub, %{
        "type" => "config",
        "node" => Atom.to_string(node())
      })

    {frame, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == sub), 5_000)
    {frame["config"]["providers"], World.put_client(ctx, name, client)}
  end

  # Codex 0.1.0 installed by Homebrew, behind the latest release 0.2.0.
  defp homebrew_codex(ctx) do
    ctx = Acp.ready(ctx)
    homebrew(ctx, "codex", :codex_command, "fake_codex.py", "codex-cli %s", "0.1.0")

    :persistent_term.put(
      {T3.ProviderUpdates, "codex"},
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
    home = ctx.node.home
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
    Application.put_env(:t3, app_key, [linked])

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
    case File.read(Path.join(ctx.node.home, "brew.log")) do
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
      {:t3_providers_changed, _} ->
        for driver <- ["codex", "claudeAgent"],
            state = :persistent_term.get({T3.ProviderUpdates, driver, :state}, nil) do
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

  step "the node checks its providers in the background", context do
    T3.Acp.load()
    Map.put(context, :providers, T3.Environment.providers())
  end

  step "no sign-in or installation is started", context do
    # The check did read Grok, and found it signed out.
    assert [_ | _] = Acp.launches(context, "grok")
    grok = Enum.find(context.providers, &(&1["instanceId"] == "grok"))
    assert grok["auth"]["status"] == "unauthenticated"
    assert grok["setup"]["canAuthenticate"]

    assert Acp.requests(context, "grok", "authenticate") == []
    assert Acp.auth_server("grok") == nil
    refute File.exists?(Path.join(context.node.home, "tools"))
    context
  end

  # --- updates -----------------------------------------------------------------------

  step "Codex was installed with Homebrew and is outdated", context do
    ctx = homebrew_codex(context)
    # Its upgrade brings it to the latest release.
    File.write!(Path.join(context.node.home, "homebrew/codex.upgrade"), "0.2.0")
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

  step "a Claude update is running", context do
    ctx = homebrew_codex(context)
    home = context.node.home
    File.write!(Path.join(home, "homebrew/codex.upgrade"), "0.2.0")
    homebrew(ctx, "claude-code", :claude_command, "fake_claude.py", "%s (Claude Code)", "1.0.0")

    :persistent_term.put(
      {T3.ProviderUpdates, "claudeAgent"},
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
        :ok = T3.Settings.watch(self())
        send(test, :watching)
        watch_updates(test, hold)
      end)

    assert_receive :watching
    ExUnit.Callbacks.on_exit(fn -> Process.exit(watcher, :kill) end)
    claude = Task.async(fn -> T3.ProviderUpdates.update(%{"provider" => "claudeAgent"}) end)
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
               "Update command completed, but T3 Code still detects an outdated provider version."
           } = codex["updateState"]

    context
  end

  step "Codex was reinstalled somewhere else after the last check", context do
    ctx = homebrew_codex(context)
    # The check offered Homebrew's upgrade.
    assert Acp.provider("codex")["versionAdvisory"]["updateCommand"] == "brew upgrade codex"

    # Then Codex was installed again with npm, which the node has not reported yet.
    home = context.node.home
    real = Path.join(home, "npm/lib/node_modules/@openai/codex/bin/codex.js")
    File.mkdir_p!(Path.dirname(real))
    File.cp!(Path.join(home, "homebrew/Cellar/codex/0.1.0/bin/codex"), real)
    linked = Path.join(home, "npm/bin/codex")
    File.mkdir_p!(Path.dirname(linked))
    File.ln_s!(real, linked)
    Application.put_env(:t3, :codex_command, [linked])
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
    # The node knows Claude is behind; it only has no updater to run.
    assert advisory["status"] == "behind_latest"
    assert advisory["updateCommand"] == nil
    assert advisory["canUpdate"] == false
    context
  end

  # --- sign-in -----------------------------------------------------------------------

  step "the user tries to sign in to Codex from T3 Code", context do
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
end
