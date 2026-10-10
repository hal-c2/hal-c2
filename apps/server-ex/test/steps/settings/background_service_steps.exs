defmodule HalC2.Steps.Settings.BackgroundService do
  @moduledoc """
  Steps for features/settings/background-service.feature: the background activity
  profile (`HalC2.BackgroundPolicy`), clients' activity leases, and the service that
  starts the MC again after an update restart (the release from
  `HalC2.Steps.Settings.HotCodeUpgrade`).

  Leases arrive over `server.reportClientActivity`, which the socket casts to the
  policy without waiting; steps trace the policy's mailbox to know it has one.
  """
  use Cucumber.StepDefinition
  # Step files compile one by one; the release helpers are in a later one.
  @compile {:no_warn_undefined, HalC2.Steps.Settings.HotCodeUpgrade}
  import ExUnit.Assertions

  alias HalC2.BackgroundPolicy
  alias HalC2.Steps.Settings.HotCodeUpgrade
  alias HalC2.Test.Mc.World
  alias HalC2.Test.Storage

  @provider_status %{"type" => "provider-status", "instanceId" => "codex"}

  # --- profiles --------------------------------------------------------------------------

  step ~r/^the background profile is (?<profile>performance|balanced|battery saver)$/,
       %{args: [profile]} = context do
    profile = String.replace(profile, " ", "-")
    context = World.update_settings(context, %{"backgroundActivity" => %{"profile" => profile}})
    assert BackgroundPolicy.settings()["profile"] == profile
    context
  end

  step ~r/^git is fetched (?<fetch>never|every .+) and providers are checked every (?<health>.+)$/,
       %{args: [fetch, health]} = context do
    settings = BackgroundPolicy.settings()
    fetch = if fetch == "never", do: 0, else: ms(String.replace_prefix(fetch, "every ", ""))
    assert settings["automaticGitFetchInterval"] == fetch
    assert settings["providerHealthRefreshInterval"] == ms(health)
    context
  end

  step ~r/^periodic background work (?<result>pauses|continues)$/,
       %{args: [result]} = context do
    context = report_activity(context, [@provider_status])
    runs? = result == "continues"
    assert BackgroundPolicy.run_scope_work?(@provider_status) == runs?

    {policy, context} = World.call!(context, "server.getBackgroundPolicy")
    assert policy["shouldRunOpportunisticWork"] == runs?
    context
  end

  # --- leases ------------------------------------------------------------------------------

  step "a client reported it is watching git status for thread {string}",
       %{args: [title]} = context do
    context = context |> World.create_project("shop") |> World.create_thread(title, "shop")
    vcs = vcs_status(context)

    context =
      report_activity(context, [
        vcs,
        %{"type" => "thread", "threadId" => World.thread_id(context, title)}
      ])

    assert BackgroundPolicy.run_scope_work?(vcs)
    context
  end

  step "the client closes its connection", context do
    Mint.HTTP.close(World.client(context).conn)
    policy = context.policy
    assert_receive {:trace, ^policy, :receive, {:DOWN, _, :process, _, _}}, 2_000
    %{context | clients: %{}}
  end

  step "the MC stops fetching git for {string}", %{args: [_title]} = context do
    refute BackgroundPolicy.run_scope_work?(vcs_status(context))
    assert BackgroundPolicy.snapshot()["leases"] == []
    context
  end

  step "a client reported it is watching provider status", context do
    context = report_activity(context, [@provider_status], %{"ttlMs" => 1_000})
    assert BackgroundPolicy.run_scope_work?(@provider_status)
    context
  end

  step "the client does not renew the report for its lifetime", context do
    policy = context.policy
    assert_receive {:trace, ^policy, :receive, {:expire, _, _}}, 3_000
    context
  end

  # The lease went on its own; the client's socket is still open.
  step "the MC stops checking provider health for it", context do
    refute BackgroundPolicy.run_scope_work?(@provider_status)
    {policy, context} = World.call!(context, "server.getBackgroundPolicy")
    assert policy["leases"] == []
    assert policy["activeScopeKeys"] == []
    context
  end

  # --- the service -------------------------------------------------------------------------

  step "the MC stops to finish an update", context do
    context =
      context
      |> HotCodeUpgrade.cached_bundle("1.4.0", :native)
      |> HotCodeUpgrade.update_to("1.4.0")

    assert {:ok, %{"targetVersion" => "1.4.0"}} = context.reply
    context
  end

  step "the service starts it again on the new version", context do
    assert HotCodeUpgrade.await_service(context) == 0
    assert HotCodeUpgrade.boots(context) == ["1.3.0", "1.4.0"]
    assert HotCodeUpgrade.start_version(context) == "1.4.0"
    context
  end

  # --- installing, status and repair (`mix hal_c2.service`, a Linux user's systemd) -------

  @problems %{
    "cannot linger after logout on Linux" => {"linger-disabled", "linger", false},
    "is disabled" => {"service-disabled", "enabled", false},
    "is stopped" => {"service-stopped", "active", false},
    "is waiting for a restart" => {"restart-pending", nil, nil}
  }

  step ~r/^the user installs the background service(?: again)?$/, context do
    context = Storage.service(context, "install")
    assert context.service_output =~ ~r/^Background service (installed|updated)\. Logs: /
    context
  end

  step "the server starts at login and runs without a client", context do
    unit = File.read!(unit_path(context))
    assert unit =~ "WantedBy=default.target"
    assert unit =~ "ExecStart="
    # Enabled for the user's login, running now, and kept running after logout.
    for state <- ~w(enabled active linger), do: assert(service_state?(context, state))
    assert %{"current" => true, "problems" => []} = status()
    context
  end

  step "the user uninstalls the service", context do
    context = Storage.service(context, "uninstall")
    assert context.service_output == "Background service removed."
    context
  end

  step "the server no longer starts at login", context do
    refute File.exists?(unit_path(context))
    refute service_state?(context, "enabled")
    refute service_state?(context, "active")

    assert Storage.service(context, "status").service_output ==
             "Background service: not installed"

    context
  end

  step ~r/^the service (?<problem>cannot linger .+|is disabled|is stopped|is waiting for a restart)$/,
       %{args: [problem]} = context do
    context = Storage.service(context, "install")
    {code, state, on?} = Map.fetch!(@problems, problem)

    if state,
      do: Storage.service_state(context.service_tools, state, on?),
      else: Storage.as_release(fn -> HalC2.Service.mark_restart_pending("1.4.0") end)

    Map.put(context, :service_problem, code)
  end

  step "the user checks the service status", context do
    Storage.service(context, "status")
  end

  step "the status names the problem and how to fix it", context do
    code = context.service_problem
    lines = String.split(context.service_output, "\n")
    assert hd(lines) == "Background service: installed, needs an update or repair"
    # Only what is wrong is named, with its fix.
    assert [problem] = Enum.filter(lines, &String.starts_with?(&1, "  ["))
    assert problem == "  [#{code}] #{HalC2.Service.problem_message(code)}"

    fix =
      case code do
        "linger-disabled" -> ~S|sudo loginctl enable-linger "$(id -un)"|
        "restart-pending" -> "hal-c2-mc restart"
        _ -> "hal-c2-mc install"
      end

    assert problem =~ fix
    assert List.last(lines) == "  Next: Run `hal-c2-mc install` to repair it."
    context
  end

  step "the service definition was damaged", context do
    context = Storage.service(context, "install")
    File.write!(unit_path(context), "[Service]\nExecStart=/nowhere\n")
    # A unit systemd could not start is also not running.
    Storage.service_state(context.service_tools, "active", false)
    refute status()["current"]
    context
  end

  step "the service runs normally", context do
    assert %{"current" => true, "problems" => []} = status()

    assert Storage.service(context, "status").service_output =~
             ~r/\ABackground service: installed\n/

    context
  end

  # --- helpers -------------------------------------------------------------------------------

  defp status, do: Storage.as_release(&HalC2.Service.status/0)

  defp unit_path(context), do: Storage.unit_path(context, :systemd, "hal-c2.service")

  defp service_state?(context, name),
    do: File.exists?(Path.join(Path.dirname(context.service_tools), name))

  # A foreground client's report on `scopes`, once the policy has it.
  defp report_activity(context, scopes, extra \\ %{}) do
    policy = HalC2.Test.Mc.ensure(BackgroundPolicy)
    :erlang.trace(policy, true, [:receive])

    report =
      Map.merge(
        %{
          "clientId" => "web-1",
          "clientKind" => "web",
          "visible" => true,
          "focused" => true,
          "recentlyInteracted" => true,
          "appState" => "active",
          "lowPowerMode" => "false",
          "batteryState" => "charging",
          "scopes" => scopes
        },
        extra
      )

    {reply, context} = World.call(context, "server.reportClientActivity", report)
    assert reply == {:ok, nil}
    assert_receive {:trace, ^policy, :receive, {:"$gen_cast", {:lease, _, _, _}}}, 2_000
    Map.put(context, :policy, policy)
  end

  defp vcs_status(context), do: %{"type" => "vcs-status", "cwd" => World.project(context).root}

  defp ms(text) do
    [n, unit] = String.split(text)
    n = String.to_integer(n)

    case unit do
      "seconds" -> :timer.seconds(n)
      "minutes" -> :timer.minutes(n)
    end
  end
end
