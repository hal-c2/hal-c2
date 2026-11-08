defmodule HalC2.OpenShellInstallPropTest do
  @moduledoc """
  `HalC2.OpenShell.Install` against a model of what an install promises, over any
  sequence of installs and updates (as a service or for the dev run, with the
  gateway's preflight or its check after start failing), certificate rotations,
  uninstalls, and the gateway writing its database.

  The gateway is a shell script (its `generate-certs` copies a fresh certificate set
  the test issued for that command), the service manager is the test's systemctl
  stand-in, and the check after start is the `:smoke` seam. A check that fails
  first writes over the database, as a new gateway that migrated it would. The
  promises checked after every step:

    * an install, update or rotation that fails changes nothing: the installed
      state, the certificates, the database and the unit are what they were;
    * one that succeeds installs what was asked, and only a fresh install or a
      rotation brings new certificates;
    * a gateway run as a service has its current unit, running; any other has none;
    * uninstalling removes the certificates and the database with the gateway;
    * the CA's key never stays on disk, keys and the configuration are owner-only,
      and nothing is left in staging.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Install
  alias HalC2.OpenShell.Service
  alias HalC2.Test.FakeOpenShell
  alias HalC2.Test.Storage

  @moduletag timeout: :infinity

  @facts %{
    os: :linux,
    arch: "x86_64",
    glibc: {2, 39},
    kernel: {6, 8},
    landlock: true,
    runtime: %{
      kind: :podman,
      socket: "/run/user/1000/podman/podman.sock",
      owner_uid: 1000,
      uid: 1000,
      reachable: true,
      version: "5.2.1",
      rootless: true
    }
  }

  @env [
    :openshell_facts,
    :service_platform,
    :service_user_home,
    :systemctl_command,
    :launchctl_command
  ]

  property "an install changes the gateway only once the new one passes, and never leaves keys behind",
    numtests: HalC2.Prop.numtests(60),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("openshell-install")
        level = Logger.level()
        # A drain's connection to a stopped gateway logs its retries.
        Logger.configure(level: :none)
        prepare_case(home)

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            Logger.configure(level: level)
            for key <- @env, do: Application.delete_env(:hal_c2, key)
            File.rm_rf!(home)
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp prepare_case(home) do
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    Storage.fake_service_manager(bin)
    Application.put_env(:hal_c2, :openshell_facts, @facts)
    Application.put_env(:hal_c2, :service_platform, {:unix, :linux})
    Application.put_env(:hal_c2, :service_user_home, Path.join(home, "user"))
    Application.put_env(:hal_c2, :systemctl_command, Path.join(bin, "systemctl"))
    Application.put_env(:hal_c2, :launchctl_command, Path.join(bin, "launchctl"))

    control = Path.join(home, "control")
    File.mkdir_p!(control)

    releases =
      for version <- ["0.1.6", "0.1.7"], into: %{} do
        {version, release(home, control, version)}
      end

    Process.put(:openshell, %{control: control, releases: releases, gens: %{}, next_gen: 0})
  end

  # --- model ----------------------------------------------------------------------

  # installed: nil or `{mode, version, previous}`; pki: the generation of the
  # certificates on disk, or nil; db: what the database holds; next_gen: the
  # generation the next install or rotation would be issued.
  def initial_state, do: %{installed: nil, pki: nil, db: nil, next_gen: 0}

  def command(state) do
    frequency(
      [
        {4,
         {:call, __MODULE__, :install,
          [oneof(["0.1.6", "0.1.7"]), oneof(["managed", "foreground"]), outcome()]}},
        {2, {:call, __MODULE__, :rotate, [oneof([:ok, :smoke_fails])]}},
        {1, {:call, __MODULE__, :uninstall, []}}
      ] ++
        if(state.installed,
          do: [{2, {:call, __MODULE__, :write_db, [oneof(["a", "b"])]}}],
          else: []
        )
    )
  end

  defp outcome, do: frequency([{3, :ok}, {1, :smoke_fails}, {1, :preflight_fails}])

  def precondition(state, {:call, _, :write_db, _}), do: state.installed != nil
  def precondition(_state, _call), do: true

  def next_state(state, _result, call), do: elem(step(state, call), 0)

  def postcondition(state, call, seen) do
    {_, expected} = step(state, call)

    if seen == expected do
      true
    else
      IO.puts("expected #{inspect(expected)}\n     got #{inspect(seen)}")
      false
    end
  end

  defp step(state, {:call, _, :install, [version, mode, outcome]}) do
    gen = state.next_gen
    # The certificates are issued before the preflight, and kept for the next try.
    state = %{state | next_gen: gen + 1, pki: state.pki || gen}

    cond do
      outcome == :preflight_fails ->
        seen(state, :preflight)

      outcome == :ok or mode == "foreground" ->
        previous = with {_, v, _} <- state.installed, do: v
        seen(%{state | installed: {mode, version, previous}}, :ok)

      true ->
        seen(state, :smoke)
    end
  end

  defp step(state, {:call, _, :rotate, [outcome]}) do
    gen = state.next_gen
    state = %{state | next_gen: gen + 1}

    case state.installed do
      nil -> seen(state, :not_installed)
      {"managed", _, _} when outcome == :smoke_fails -> seen(state, :smoke)
      _ -> seen(%{state | pki: gen}, :ok)
    end
  end

  defp step(%{installed: nil} = state, {:call, _, :uninstall, []}),
    do: seen(state, :not_installed)

  defp step(state, {:call, _, :uninstall, []}),
    do: seen(%{state | installed: nil, pki: nil, db: nil}, :ok)

  defp step(state, {:call, _, :write_db, [marker]}), do: seen(%{state | db: marker}, :ok)

  defp seen(state, result) do
    unit = if match?({"managed", _, _}, state.installed), do: {true, true}, else: :absent

    {state,
     %{
       result: result,
       installed: state.installed,
       pki: state.pki,
       db: state.db,
       unit: unit,
       clean: true
     }}
  end

  # --- commands -------------------------------------------------------------------

  def install(version, mode, outcome) do
    %{releases: releases} = next_certificates()
    {release, archive} = releases[version]
    preflight(outcome == :preflight_fails)

    Install.install(
      release: release,
      archive: archive,
      service: mode == "managed",
      smoke: smoke(outcome == :smoke_fails)
    )
    |> observe()
  end

  def rotate(outcome) do
    next_certificates()
    preflight(false)
    observe(Install.rotate(smoke: smoke(outcome == :smoke_fails)))
  end

  def uninstall, do: observe(Install.uninstall())

  def write_db(marker) do
    File.write!(OpenShell.db_path(), marker)
    observe(:ok)
  end

  # Issues the certificate set the gateway's next `generate-certs` copies, and
  # remembers its generation by its CA.
  defp next_certificates do
    ctx = Process.get(:openshell)
    pki = Path.join(ctx.control, "pki")
    File.rm_rf!(pki)
    FakeOpenShell.stranger(pki)
    ca = File.read!(Path.join(pki, "ca.crt"))
    ctx = %{ctx | gens: Map.put(ctx.gens, ca, ctx.next_gen), next_gen: ctx.next_gen + 1}
    Process.put(:openshell, ctx)
    ctx
  end

  defp preflight(fails) do
    path = Path.join(Process.get(:openshell).control, "preflight")
    if fails, do: File.write!(path, "1"), else: File.rm_rf!(path)
  end

  # The check after start. One that fails is the new gateway's, which has already
  # written over the database; the check of the gateway put back passes.
  defp smoke(fails) do
    calls = :counters.new(1, [])

    fn _state ->
      :counters.add(calls, 1, 1)

      if fails and :counters.get(calls, 1) == 1 do
        File.write!(OpenShell.db_path(), "migrated by the failed gateway")
        {:error, "[smoke] The new gateway failed its check."}
      else
        :ok
      end
    end
  end

  defp observe(result) do
    state = OpenShell.state()
    ca = Path.join(OpenShell.pki_dir(), "ca.crt")
    unit = Service.unit_path(:systemd)

    %{
      result: classify(result),
      installed: state && {state["mode"], state["version"], state["previous"]},
      pki:
        case File.read(ca) do
          {:ok, text} -> Map.fetch!(Process.get(:openshell).gens, text)
          _ -> nil
        end,
      db:
        case File.read(OpenShell.db_path()) do
          {:ok, text} -> text
          _ -> nil
        end,
      unit:
        if File.exists?(unit) do
          status = Service.status(state)
          {status["current"], status["running"]}
        else
          :absent
        end,
      clean: clean?()
    }
  end

  defp classify({:ok, _}), do: :ok
  defp classify(:ok), do: :ok
  defp classify({:error, "[smoke]" <> _}), do: :smoke
  defp classify({:error, "[not-installed]" <> _}), do: :not_installed
  defp classify({:error, "`openshell-gateway config preflight` failed" <> _}), do: :preflight
  defp classify(other), do: other

  defp clean? do
    pki = OpenShell.pki_dir()
    key = Path.join([pki, "client", "tls.key"])
    config = OpenShell.config_path()
    mode = &(File.stat!(&1).mode |> Bitwise.band(0o777))

    Path.wildcard(Path.join(OpenShell.root(), "**/ca.key"), match_dot: true) == [] and
      (not File.exists?(key) or mode.(key) == 0o600) and
      (not File.exists?(config) or mode.(config) == 0o600) and
      Path.wildcard(Path.join([OpenShell.root(), "staging", "*"])) == []
  end

  # A gateway release whose binary is a shell script (see the moduledoc).
  defp release(home, control, version),
    do: FakeOpenShell.release(control, Path.join(home, "archives"), version)
end
