defmodule HalC2.OpenShellInstallPropTest do
  @moduledoc """
  `HalC2.OpenShell.Install` against a model of what an install promises, over any
  sequence of installs and updates (as a service or for the dev run, with the
  gateway's preflight or its check after start failing, or a service that will not
  stop), certificate rotations, uninstalls (also of a service that will not stop),
  the gateway writing its database, and the gateway of a user (`reuse`)
  that is clean or already holds another HAL-C2 environment's sandboxes, or comes
  to hold one later.

  The gateway is a shell script (its `generate-certs` copies a fresh certificate set
  the test issued for that command, two per install: one for the gateway and one
  for the CA of the MC's client certificate), the service manager is the test's
  systemctl or launchctl stand-in, one of them for each case, and the check after
  start is the `:smoke` seam. A check that
  fails first writes over the database, as a new gateway that migrated it would.
  A user's gateway is the TLS fake. The promises checked after every step:

    * an install, update or rotation that fails changes nothing: the installed
      state, the certificates, the database and the unit are what they were; one
      over a service that will not stop fails;
    * an uninstall over a service that will not stop fails and removes nothing;
    * one that succeeds installs what was asked, and only a fresh install or a
      rotation brings new certificates;
    * a gateway run as a service has its current unit, running; any other has none;
    * uninstalling removes the certificates and the database with the gateway;
    * the CA's key never stays on disk, the MC's client certificate comes from a CA
      of its own that is not the gateway's, keys and the configuration are
      owner-only, and nothing is left in staging;
    * a user's gateway that holds another environment's sandboxes is refused and the
      MC keeps what it used, and the credentials it was tried with are gone; at most
      the current and the replaced credentials of users' gateways stay; one that comes to hold them is reported by `status` and
      refused by `connect`, and by a connection made before it came, when that one
      is asked for a sandbox; the MC never creates or deletes a sandbox there, and
      never touches the other environment's;
    * another HAL-C2 home on the machine installing, updating or uninstalling its
      gateway as a service changes none of this home's: it never names this home's
      unit to the service manager, and this home's unit, certificates, database and
      installed state are what they were. It has a service manager stand-in of its
      own, so this home's unit keeps running whatever the other home's does.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Client
  alias HalC2.OpenShell.Install
  alias HalC2.OpenShell.Manifest
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

  # The same model under each service manager: systemd on Linux, launchd on macOS.
  for platform <- [:linux, :darwin] do
    property "an install changes the gateway only once the new one passes, and never leaves keys behind (#{platform})",
      numtests: HalC2.Prop.numtests(40),
      max_size: 25 do
      platform = unquote(platform)

      forall cmds <- commands(__MODULE__) do
        trap_exit do
          home = HalC2.Prop.scratch_home("openshell-install")
          level = Logger.level()
          # A drain's connection to a stopped gateway logs its retries.
          Logger.configure(level: :none)
          prepare_case(home, platform)

          {history, state, result} =
            try do
              run_commands(__MODULE__, cmds)
            after
              Logger.configure(level: level)
              drop_retained()
              stop_gateways()
              for key <- @env, do: Application.delete_env(:hal_c2, key)
              File.rm_rf!(home)
            end

          (result == :ok)
          |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
          |> aggregate(command_names(cmds))
        end
      end
    end
  end

  # `platform` picks the service manager: systemd on Linux, launchd on macOS.
  defp prepare_case(home, platform) do
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    Storage.fake_service_manager(bin)
    other_bin = Path.join([home, "other", "bin"])
    File.mkdir_p!(other_bin)
    Storage.fake_service_manager(other_bin)
    Application.put_env(:hal_c2, :openshell_facts, @facts)
    Application.put_env(:hal_c2, :service_platform, {:unix, platform})
    Application.put_env(:hal_c2, :service_user_home, Path.join(home, "user"))
    Application.put_env(:hal_c2, :systemctl_command, Path.join(bin, "systemctl"))
    Application.put_env(:hal_c2, :launchctl_command, Path.join(bin, "launchctl"))

    control = Path.join(home, "control")
    File.mkdir_p!(control)

    releases =
      for version <- ["0.1.6", "0.1.7"], into: %{} do
        {version, release(home, control, version)}
      end

    Process.put(:openshell, %{
      home: home,
      control: control,
      releases: releases,
      gens: %{},
      next_gen: 0,
      # The gateways of users that were started, the one the MC records, and the
      # other environment's sandboxes put on them (`{gateway, name}`).
      servers: [],
      current: nil,
      foreign: [],
      # The connection `connect` kept, if any.
      retained: nil,
      seq: 0,
      # The other home on the machine, and its service manager stand-in.
      other: %{home: Path.join([home, "other", "mc"]), bin: other_bin}
    })
  end

  # --- model ----------------------------------------------------------------------

  # installed: nil or `{mode, version, previous}`; pki: the generation of the
  # certificates on disk, or nil; db: what the database holds; next_gen: the
  # generation the next install, rotation or user's gateway would be issued;
  # shared: whether the user's gateway the MC records holds another environment's
  # sandboxes; retained: whether the MC keeps a connection to it; other: whether the
  # machine's other home has its gateway installed.
  def initial_state,
    do: %{
      installed: nil,
      pki: nil,
      db: nil,
      next_gen: 0,
      shared: false,
      retained: false,
      other: false
    }

  def command(state) do
    frequency(
      [
        {4,
         {:call, __MODULE__, :install,
          [oneof(["0.1.6", "0.1.7"]), oneof(["managed", "foreground"]), outcome()]}},
        {2, {:call, __MODULE__, :rotate, [oneof([:ok, :smoke_fails, :stop_fails])]}},
        {2, {:call, __MODULE__, :reuse, [oneof([:clean, :shared])]}},
        {1, {:call, __MODULE__, :uninstall, [oneof([:ok, :stop_fails])]}},
        {2, {:call, __MODULE__, :other_home, [oneof([:install, :update, :uninstall])]}}
      ] ++
        if(writable?(state),
          do: [{2, {:call, __MODULE__, :write_db, [oneof(["a", "b"])]}}],
          else: []
        ) ++
        if(external?(state),
          do: [
            {2, {:call, __MODULE__, :other_environment_arrives, []}},
            {2, {:call, __MODULE__, :connect, []}},
            {2, {:call, __MODULE__, :status, []}}
          ],
          else: []
        ) ++
        if(external?(state) and state.retained,
          do: [{2, {:call, __MODULE__, :create_retained, []}}],
          else: []
        )
    )
  end

  defp external?(state), do: match?({"external", _, _}, state.installed)
  defp writable?(state), do: state.installed != nil and not external?(state)

  defp outcome,
    do: frequency([{3, :ok}, {1, :smoke_fails}, {1, :preflight_fails}, {1, :stop_fails}])

  def precondition(state, {:call, _, :write_db, _}), do: writable?(state)

  def precondition(state, {:call, _, name, _})
      when name in [:other_environment_arrives, :connect, :status],
      do: external?(state)

  def precondition(state, {:call, _, :create_retained, _}),
    do: external?(state) and state.retained

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

  # The MC uses a gateway it does not run; the certificates are queued but unused.
  defp step(%{installed: {"external", _, _}} = state, {:call, _, :install, _}),
    do: seen(%{state | next_gen: state.next_gen + 1}, :external)

  defp step(state, {:call, _, :install, [version, mode, outcome]}) do
    gen = state.next_gen
    # The certificates are issued before the preflight, and kept for the next try.
    state = %{state | next_gen: gen + 1, pki: state.pki || gen}

    cond do
      outcome == :preflight_fails ->
        seen(state, :preflight)

      # Only a gateway that runs as a service is stopped before an update.
      outcome == :stop_fails and match?({"managed", _, _}, state.installed) ->
        seen(state, :stop_failed)

      outcome in [:ok, :stop_fails] or mode == "foreground" ->
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
      {"external", _, _} -> seen(state, :external)
      {"managed", _, _} when outcome == :smoke_fails -> seen(state, :smoke)
      {"managed", _, _} when outcome == :stop_fails -> seen(state, :stop_failed)
      _ -> seen(%{state | pki: gen}, :ok)
    end
  end

  defp step(%{installed: nil} = state, {:call, _, :uninstall, _}),
    do: seen(state, :not_installed)

  defp step(%{installed: {"managed", _, _}} = state, {:call, _, :uninstall, [:stop_fails]}),
    do: seen(state, :stop_failed)

  defp step(state, {:call, _, :uninstall, _}),
    do: seen(%{state | installed: nil, pki: nil, db: nil, shared: false, retained: false}, :ok)

  defp step(state, {:call, _, :write_db, [marker]}), do: seen(%{state | db: marker}, :ok)

  # The other home's result; this home's observation is what it was.
  defp step(state, {:call, _, :other_home, [op]}) do
    case {op, state.other} do
      {:uninstall, false} -> seen(state, {:other, :not_installed})
      {:uninstall, true} -> seen(%{state | other: false}, {:other, :ok})
      _ -> seen(%{state | other: true}, {:other, :ok})
    end
  end

  # A gateway the MC runs is refused, whatever the gateway of the user holds. One
  # that holds another environment's sandboxes is refused and changes nothing: the
  # credentials it was tried with go (`clean?/1`). One that is clean is recorded,
  # over a gateway the MC recorded before.
  defp step(state, {:call, _, :reuse, [kind]}) do
    gen = state.next_gen
    state = %{state | next_gen: gen + 1}

    cond do
      match?({mode, _, _} when mode in ["managed", "foreground"], state.installed) ->
        seen(state, :managed)

      kind == :shared ->
        seen(state, :shared)

      true ->
        seen(
          %{
            state
            | installed: {"external", Manifest.version(), nil},
              pki: gen,
              shared: false,
              retained: false
          },
          :ok
        )
    end
  end

  defp step(state, {:call, _, :other_environment_arrives, []}),
    do: seen(%{state | shared: true}, :ok)

  # A connection that is let in is kept, in place of the one kept before.
  defp step(state, {:call, _, :connect, []}) do
    if state.shared,
      do: seen(state, {:shared, ["env-b"]}),
      else: seen(%{state | retained: true}, :ok)
  end

  # The kept connection makes (and then deletes) a sandbox only while the gateway
  # holds no other environment's.
  defp step(state, {:call, _, :create_retained, []}) do
    if state.shared,
      do: seen(state, {{:shared, ["env-b"]}, 0}),
      else: seen(state, {:created, 2})
  end

  defp step(state, {:call, _, :status, []}) do
    if state.shared,
      do: seen(state, {:status, ["gateway-shared"], ["env-b"]}),
      else: seen(state, {:status, [], []})
  end

  defp seen(state, result) do
    unit = if match?({"managed", _, _}, state.installed), do: {true, true}, else: :absent

    {state,
     %{
       result: result,
       installed: state.installed,
       pki: state.pki,
       db: state.db,
       unit: unit,
       clean: true,
       safe: true
     }}
  end

  # --- commands -------------------------------------------------------------------

  def install(version, mode, outcome) do
    %{releases: releases} = next_certificates()
    {release, archive} = releases[version]
    preflight(outcome == :preflight_fails)

    stop_fails(outcome == :stop_fails, fn ->
      Install.install(
        release: release,
        archive: archive,
        service: mode == "managed",
        smoke: smoke(outcome == :smoke_fails)
      )
    end)
    |> observe()
  end

  def rotate(outcome) do
    next_certificates()
    preflight(false)

    stop_fails(outcome == :stop_fails, fn ->
      Install.rotate(smoke: smoke(outcome == :smoke_fails))
    end)
    |> observe()
  end

  # Runs `fun` with the service manager failing every stop, or not.
  defp stop_fails(fails, fun) do
    path = Path.join([Process.get(:openshell).home, "bin", "stop-fails"])
    if fails, do: File.write!(path, "")

    try do
      fun.()
    after
      File.rm_rf!(path)
    end
  end

  def uninstall(outcome) do
    result = stop_fails(outcome == :stop_fails, fn -> Install.uninstall() end)
    drop_retained()
    Process.put(:openshell, %{Process.get(:openshell) | current: nil})
    observe(result)
  end

  # The machine's other home installs (0.1.6), updates (0.1.7) or uninstalls its
  # gateway as a service, with its own service manager stand-in.
  def other_home(op) do
    ctx = Process.get(:openshell)
    manager = Service.manager()
    unit = Service.unit_path(manager)
    name = Service.name(manager)
    before = File.read(unit)
    log = Path.join(ctx.other.bin, "calls.log")
    File.write!(log, "")

    result =
      in_other_home(ctx, fn ->
        case op do
          :uninstall ->
            Install.uninstall()

          op ->
            FakeOpenShell.queue_certificates(ctx.control)
            preflight(false)
            {release, archive} = ctx.releases[if(op == :install, do: "0.1.6", else: "0.1.7")]
            Install.install(release: release, archive: archive, smoke: fn _ -> :ok end)
        end
      end)

    calls = Storage.service_calls(log)
    named = Enum.filter(calls, &String.contains?(&1, name))
    unchanged = File.read(unit) == before

    observe(
      {:other, if(named == [] and unchanged, do: classify(result), else: {:touched, named})}
    )
  end

  @other_env [:home, :systemctl_command, :launchctl_command]

  defp in_other_home(ctx, fun) do
    previous = for key <- @other_env, do: {key, Application.get_env(:hal_c2, key)}
    Application.put_env(:hal_c2, :home, ctx.other.home)
    Application.put_env(:hal_c2, :systemctl_command, Path.join(ctx.other.bin, "systemctl"))
    Application.put_env(:hal_c2, :launchctl_command, Path.join(ctx.other.bin, "launchctl"))

    try do
      fun.()
    after
      for {key, value} <- previous, do: Application.put_env(:hal_c2, key, value)
    end
  end

  # A gateway of the user's own, clean or already holding another environment's
  # sandbox. Nothing may be created there when it is refused.
  def reuse(kind) do
    ctx = Process.get(:openshell)
    dir = Path.join([ctx.home, "gateways", "g#{ctx.seq}"])
    exec = fn _command, io -> io.exit.(0) end
    gateway = FakeOpenShell.start(dir, exec: exec, notify: self())
    foreign = if kind == :shared, do: [{gateway, "elsewhere"}], else: []
    for {gw, name} <- foreign, do: FakeOpenShell.put_sandbox(gw, name, other_labels())

    ctx = %{
      ctx
      | seq: ctx.seq + 1,
        servers: [gateway | ctx.servers],
        foreign: foreign ++ ctx.foreign,
        gens: Map.put(ctx.gens, File.read!(gateway.credentials[:ca]), ctx.next_gen),
        next_gen: ctx.next_gen + 1
    }

    result = Install.reuse(gateway.endpoint, gateway.credentials)
    Process.put(:openshell, ctx)
    if match?({:ok, _}, result), do: drop_retained()
    ctx = Process.get(:openshell)
    current = if match?({:ok, _}, result), do: gateway, else: ctx.current
    Process.put(:openshell, %{ctx | current: current})
    observe(result, kind == :shared)
  end

  def other_environment_arrives do
    ctx = Process.get(:openshell)
    FakeOpenShell.put_sandbox(ctx.current, "elsewhere", other_labels())
    Process.put(:openshell, %{ctx | foreign: [{ctx.current, "elsewhere"} | ctx.foreign]})
    observe(:ok)
  end

  def connect do
    case Client.connect() do
      {:ok, conn} ->
        drop_retained()
        Process.put(:openshell, %{Process.get(:openshell) | retained: conn})
        observe(:ok, true)

      {:error, {:shared_gateway, ids}} ->
        observe({:shared, ids}, true)

      {:error, reason} ->
        observe({:connect_failed, reason}, true)
    end
  end

  def status do
    status = Install.status()
    observe({:status, status["problems"], status["sharedWith"]}, true)
  end

  # Creates a sandbox over the connection `connect` kept, and deletes it again if it
  # was made: the result and the number of sandbox requests the gateway got.
  def create_retained do
    ctx = Process.get(:openshell)
    mutations()
    name = "mine-#{ctx.seq}"
    Process.put(:openshell, %{ctx | seq: ctx.seq + 1})

    result =
      case Client.create_sandbox(ctx.retained, name) do
        {:ok, _} -> with :ok <- Client.delete_sandbox(ctx.retained, name), do: :created
        {:error, {:shared_gateway, ids}} -> {:shared, ids}
        other -> other
      end

    observe({result, mutations()})
  end

  defp drop_retained do
    ctx = Process.get(:openshell)
    if ctx.retained, do: Client.disconnect(ctx.retained)
    Process.put(:openshell, %{ctx | retained: nil})
  end

  defp other_labels, do: %{OpenShell.owner_label() => "env-b"}

  def write_db(marker) do
    File.write!(OpenShell.db_path(), marker)
    observe(:ok)
  end

  # Issues the two certificate sets the gateway's next two `generate-certs` calls
  # copy, and remembers the generation of the first (the gateway's) by its CA.
  defp next_certificates do
    ctx = Process.get(:openshell)
    [ca | _] = FakeOpenShell.queue_certificates(ctx.control)
    ctx = %{ctx | gens: Map.put(ctx.gens, ca, ctx.next_gen), next_gen: ctx.next_gen + 1}
    Process.put(:openshell, ctx)
    ctx
  end

  defp stop_gateways do
    for %{server: server} <- Process.get(:openshell).servers do
      try do
        Supervisor.stop(server)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # The requests the fake gateways were sent that make or remove a sandbox, since
  # the last call.
  defp mutations(count \\ 0) do
    receive do
      {:openshell_request, method, _} when method in ["CreateSandbox", "DeleteSandbox"] ->
        mutations(count + 1)

      {:openshell_request, _, _} ->
        mutations(count)
    after
      0 -> count
    end
  end

  # No sandbox of another environment is gone, and, where asked, nothing was made or
  # removed since the last call.
  defp safe?(count?) do
    made = mutations()

    (not count? or made == 0) and
      Enum.all?(Process.get(:openshell).foreign, fn {gateway, name} ->
        Map.has_key?(FakeOpenShell.sandboxes(gateway), name)
      end)
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

  defp observe(result, count? \\ false) do
    state = OpenShell.state()
    ca = OpenShell.credentials(state)[:ca]
    unit = Service.unit_path(Service.manager())

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
      clean: clean?(state),
      safe: safe?(count?)
    }
  end

  defp classify({:ok, _}), do: :ok
  defp classify(:ok), do: :ok
  defp classify({:error, "[smoke]" <> _}), do: :smoke
  defp classify({:error, "[gateway-stop-failed]" <> _}), do: :stop_failed
  defp classify({:error, "[external]" <> _}), do: :external
  defp classify({:error, "[managed]" <> _}), do: :managed
  defp classify({:error, "[shared-gateway]" <> _}), do: :shared
  defp classify({:error, "[not-installed]" <> _}), do: :not_installed
  defp classify({:error, "`openshell-gateway config preflight` failed" <> _}), do: :preflight
  defp classify(other), do: other

  defp clean?(state) do
    pki = OpenShell.credentials_dir(state)
    key = Path.join([pki, "client", "tls.key"])
    users = Path.wildcard(Path.join(OpenShell.root(), "pki-*"))
    external = state != nil and state["mode"] == "external"
    config = OpenShell.config_path()
    mode = &(File.stat!(&1).mode |> Bitwise.band(0o777))

    Path.wildcard(Path.join(OpenShell.root(), "**/ca.key"), match_dot: true) == [] and
      client_authority?(pki, state) and
      (not File.exists?(pki <> ".new") and not File.exists?(pki <> ".previous")) and
      not File.exists?(pki <> ".client") and
      (not File.exists?(key) or mode.(key) == 0o600) and
      (not File.exists?(config) or mode.(config) == 0o600) and
      Path.wildcard(Path.join([OpenShell.root(), "staging", "*"])) == [] and
      if(external,
        do: pki in users and length(users) <= 2 and not File.exists?(OpenShell.pki_dir()),
        else: users == []
      )
  end

  # The certificates the MC issued: the client's come from a CA that is not the
  # gateway's, and the gateway's own do not authenticate as a client. A gateway of
  # the user's has the user's CA and no CA of ours.
  defp client_authority?(pki, state) do
    ca = Path.join(pki, "ca.crt")
    client_ca = Path.join(pki, "client-ca.crt")
    cert = Path.join([pki, "client", "tls.crt"])
    server = Path.join([pki, "server", "tls.crt"])

    cond do
      not File.exists?(ca) ->
        true

      state && state["mode"] == "external" ->
        not File.exists?(client_ca)

      true ->
        File.read!(ca) != File.read!(client_ca) and
          FakeOpenShell.signed_by?(cert, client_ca) and
          not FakeOpenShell.signed_by?(cert, ca) and
          FakeOpenShell.signed_by?(server, ca) and
          not FakeOpenShell.signed_by?(server, client_ca)
    end
  end

  # A gateway release whose binary is a shell script (see the moduledoc).
  defp release(home, control, version),
    do: FakeOpenShell.release(control, Path.join(home, "archives"), version)
end
