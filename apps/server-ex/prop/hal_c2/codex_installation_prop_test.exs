defmodule HalC2.CodexInstallationPropTest do
  @moduledoc """
  `HalC2.Codex.Installation` against a model of which managed Codex is active. The
  pinned release is served from a loopback server that holds each download until the
  case says how it ends (the whole package, HTTP 404, or half of it), so installs,
  cancels, removals and restarts of the service interleave with downloads in flight.

  The promise: only a finished, verified install of the pin changes the active Codex;
  a failed or cancelled one, or one the service stopped in the middle of, leaves the
  previous one active; a failed download asks for the connection, never the disk; a
  service that starts over an active Codex older than the pin updates it on its own;
  a removal leaves none; and the PATH's `codex`, which has no Code Mode host beside
  it, gives way to whichever managed Codex is active.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Codex.Installation

  @moduletag timeout: :infinity

  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @pinned "0.166.0"
  @old "0.165.0"
  @target "x86_64-unknown-linux-musl"
  @path "/codex-package.tar.gz"

  property "only a verified install of the pin changes the active Codex",
    numtests: HalC2.Prop.numtests(30),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        teardown(state)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- the case ------------------------------------------------------------------------

  defp setup do
    home = HalC2.Prop.scratch_home("codex-installation")
    bare = Path.join(home, "path")
    File.mkdir_p!(bare)
    File.write!(Path.join(bare, "codex"), <<0x7F, "ELF", 0::64>>)
    File.chmod!(Path.join(bare, "codex"), 0o755)
    Process.put(:path, System.get_env("PATH"))
    System.put_env("PATH", "#{bare}:#{System.get_env("PATH")}")
    Application.put_env(:hal_c2, :codex_command, ["codex", "app-server"])

    bytes = archive(home)
    {:ok, log} = Agent.start(fn -> [] end)
    case_pid = self()
    routes = %{@path => fn conn -> answer(conn, bytes, case_pid) end}

    sup =
      HalC2.Prop.start_services([
        HalC2.Settings,
        {Registry, keys: :unique, name: HalC2.Codex.Registry},
        Supervisor.child_spec(
          {Bandit, plug: {HalC2.Test.FakeHttp, {routes, log}}, port: 0, ip: :loopback},
          id: :fake_http
        ),
        Installation
      ])

    {_, bandit, _, _} =
      Enum.find(Supervisor.which_children(sup), &match?({:fake_http, _, _, _}, &1))

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)

    Application.put_env(:hal_c2, :codex_release, %{
      version: @pinned,
      target: @target,
      url: "http://127.0.0.1:#{port}#{@path}",
      sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      archive_bytes: byte_size(bytes)
    })

    # The service started before the release was set: start it again over it.
    :ok = HalC2.Prop.restart_service(Installation)
    {:ok, _} = Installation.subscribe("codex", self())
  end

  defp teardown(state) do
    # A download still held is let go, so its handler ends with the server.
    if state[:handler], do: send(state.handler, {:go, :not_found})
    HalC2.Prop.stop_services()
    System.put_env("PATH", Process.get(:path))
    for key <- [:codex_release, :codex_command], do: Application.delete_env(:hal_c2, key)
  end

  # The pinned package: wrappers around the fake Codex, laid out as OpenAI's are.
  defp archive(home) do
    tree = package(Path.join(home, "package"), @pinned)
    archive = Path.join(home, "codex.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        for(
          name <- ["codex-package.json", "bin", "codex-path"],
          do: {String.to_charlist(name), String.to_charlist(Path.join(tree, name))}
        ),
        [:compressed]
      )

    File.read!(archive)
  end

  defp package(dir, version) do
    files = %{
      "bin/codex" =>
        "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"codex-cli #{version}\"; exit 0; fi\n" <>
          "exec python3 -u #{@fake_codex} \"$@\"\n",
      "bin/codex-code-mode-host" => "#!/bin/sh\nexit 0\n",
      "codex-path/rg" => "#!/bin/sh\nexit 0\n"
    }

    for {name, body} <- files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
      File.chmod!(path, 0o755)
    end

    File.write!(
      Path.join(dir, "codex-package.json"),
      JSON.encode!(%{
        "layoutVersion" => 1,
        "version" => version,
        "target" => @target,
        "entrypoint" => "bin/codex"
      })
    )

    dir
  end

  # Every download is held until the case says how it ends.
  defp answer(conn, bytes, case_pid) do
    send(case_pid, {:codex_download, self()})

    receive do
      {:go, :ok} -> Plug.Conn.send_resp(conn, 200, bytes)
      {:go, :short} -> Plug.Conn.send_resp(conn, 200, binary_part(bytes, 0, 64))
      {:go, :not_found} -> {404, %{"error" => "not found"}}
    end
  end

  # --- model ---------------------------------------------------------------------------
  # `active`: the managed version in use, or nil. `pinned_dir`: whether the pin's
  # verified directory is on disk (a later install of it then needs no download).
  # `op`: an install is running. `handler`: the held download's server process, and
  # `op_id` the install's id (both real values, stored opaquely).

  def initial_state, do: %{active: nil, pinned_dir: false, op: false, handler: nil, op_id: nil}

  def command(%{op: false}) do
    frequency([
      {3, {:call, __MODULE__, :start, [nil]}},
      {1, {:call, __MODULE__, :place_old, []}},
      {1, {:call, __MODULE__, :remove, []}},
      {1, {:call, __MODULE__, :restart, [nil]}},
      {2, {:call, __MODULE__, :which, []}}
    ])
  end

  def command(state) do
    frequency([
      {4,
       {:call, __MODULE__, :finish,
        [state.handler, state.op_id, oneof([:ok, :short, :not_found])]}},
      {1, {:call, __MODULE__, :cancel, [state.handler, state.op_id]}},
      {1, {:call, __MODULE__, :start, [state.op_id]}},
      {1, {:call, __MODULE__, :remove, []}},
      {1, {:call, __MODULE__, :restart, [state.handler]}},
      {1, {:call, __MODULE__, :which, []}}
    ])
  end

  def precondition(%{op: op}, {:call, _, name, _}) when name in [:finish, :cancel], do: op
  def precondition(%{op: op}, {:call, _, :place_old, _}), do: not op
  def precondition(_state, _call), do: true

  # An install the pin's directory already holds finishes on its own; any other is
  # held at its download.
  def next_state(%{op: false, pinned_dir: true} = state, _result, {:call, _, :start, _}),
    do: %{state | active: @pinned}

  def next_state(%{op: false} = state, result, {:call, _, :start, _}),
    do: %{
      state
      | op: true,
        handler: {:call, Kernel, :elem, [result, 0]},
        op_id: {:call, Kernel, :elem, [result, 1]}
    }

  def next_state(state, _result, {:call, _, :finish, [_, _, outcome]}) do
    state = %{state | op: false, handler: nil, op_id: nil}
    if outcome == :ok, do: %{state | active: @pinned, pinned_dir: true}, else: state
  end

  def next_state(state, _result, {:call, _, :cancel, _}),
    do: %{state | op: false, handler: nil, op_id: nil}

  def next_state(state, _result, {:call, _, :place_old, _}), do: %{state | active: @old}

  def next_state(%{op: false} = state, _result, {:call, _, :remove, _}),
    do: %{state | active: nil, pinned_dir: false}

  def next_state(state, result, {:call, _, :restart, _}) do
    state = %{state | op: false, handler: nil, op_id: nil}

    cond do
      state.active != @old ->
        state

      state.pinned_dir ->
        %{state | active: @pinned}

      true ->
        %{
          state
          | op: true,
            handler: {:call, Kernel, :elem, [result, 0]},
            op_id: {:call, Kernel, :elem, [result, 1]}
        }
    end
  end

  def next_state(state, _result, _call), do: state

  def postcondition(%{op: true}, {:call, _, :start, _}, {_handler, _id, phase}),
    do: phase == "downloading"

  def postcondition(%{pinned_dir: true}, {:call, _, :start, _}, {nil, _id, phase}),
    do: phase == "succeeded"

  def postcondition(_state, {:call, _, :start, _}, {handler, _id, phase}),
    do: is_pid(handler) and phase == "downloading"

  def postcondition(state, {:call, _, :finish, [_, _, outcome]}, {phase, message, active}) do
    case outcome do
      :ok ->
        phase == "succeeded" and active == @pinned

      _ ->
        phase == "failed" and message =~ "Check your internet connection" and
          not (message =~ ~r/disk/i) and active == state.active
    end
  end

  def postcondition(state, {:call, _, :cancel, _}, {phase, active}),
    do: phase == "cancelled" and active == state.active

  def postcondition(%{op: true}, {:call, _, :remove, _}, result), do: match?({:error, _}, result)
  def postcondition(_state, {:call, _, :remove, _}, result), do: result == {:ok, nil}

  def postcondition(state, {:call, _, :restart, _}, {handler, _id, phase}) do
    cond do
      state.active != @old ->
        handler == nil and phase in ["idle", "failed", "cancelled", "succeeded"]

      state.pinned_dir ->
        phase == "succeeded"

      true ->
        is_pid(handler) and phase == "downloading"
    end
  end

  def postcondition(state, {:call, _, :which, _}, {active, command}) do
    expected =
      if state.active,
        do: [Path.join([Installation.managed_dir(), state.active, "bin", "codex"]), "app-server"],
        else: ["codex", "app-server"]

    active == state.active and command == expected
  end

  def postcondition(_state, _call, _result), do: true

  # --- commands ------------------------------------------------------------------------

  @doc """
  Starts an install: `{held download's handler or nil, op id, phase}`. With `running`,
  the install already under way, which the start answers with.
  """
  def start(running) do
    {:ok, %{"operationId" => id, "phase" => phase}} =
      Installation.start(%{"instanceId" => "codex"})

    if id == running, do: {nil, id, phase}, else: held(id, phase)
  end

  # The install `id` in `phase` is held at its download, or finishes without one.
  defp held(id, "downloading") do
    receive do
      {:codex_download, handler} -> {handler, id, "downloading"}
    after
      0 -> await_download_or_end(id)
    end
  end

  defp held(id, phase), do: {nil, id, phase}

  defp await_download_or_end(id) do
    receive do
      {:codex_download, handler} ->
        {handler, id, "downloading"}

      {:hal_c2_provider_install, "codex", %{"operationId" => ^id, "phase" => phase}}
      when phase in ["succeeded", "failed"] ->
        {nil, id, phase}
    end
  end

  @doc "Lets the held download end as `outcome`: `{phase, message, active version}`."
  def finish(handler, id, outcome) do
    send(handler, {:go, outcome})
    %{"phase" => phase, "message" => message} = await_end(id)
    {phase, message, active()}
  end

  def cancel(handler, id) do
    {:ok, %{"phase" => phase}} =
      Installation.cancel(%{"instanceId" => "codex", "operationId" => id})

    send(handler, {:go, :not_found})
    {phase, active()}
  end

  def place_old do
    dir = package(Path.join(Installation.managed_dir(), @old), @old)

    File.write!(
      Path.join(dir, ".install-complete.json"),
      JSON.encode!(%{"version" => @old, "target" => @target, "sha256" => "earlier"})
    )

    File.write!(Path.join(Installation.managed_dir(), "active.json"), ~s({"version":"#{@old}"}))
  end

  def remove do
    case Installation.remove(%{"instanceId" => "codex"}) do
      {:ok, _} -> {:ok, active()}
      error -> error
    end
  end

  @doc "Restarts the service, letting a held download go; then as `start/0` for what it began."
  def restart(handler) do
    :ok = HalC2.Prop.restart_service(Installation)
    if handler, do: send(handler, {:go, :not_found})
    {:ok, %{"operationId" => id, "phase" => phase}} = Installation.subscribe("codex", self())

    case phase do
      "downloading" -> held(id, phase)
      _ when id != nil -> settle(id, phase)
      _ -> {nil, id, phase}
    end
  end

  # A boot update the pin's directory already held may still be checking it.
  defp settle(id, phase) when phase in ["verifying", "extracting"],
    do: {nil, id, await_end(id)["phase"]}

  defp settle(id, phase), do: {nil, id, phase}

  def which, do: {active(), Installation.command("codex")}

  defp await_end(id) do
    receive do
      {:hal_c2_provider_install, "codex", %{"operationId" => ^id, "phase" => phase} = state}
      when phase in ["succeeded", "failed", "cancelled"] ->
        state
    end
  end

  defp active do
    case Installation.active() do
      {:ok, %{version: version}} -> version
      _ -> nil
    end
  end
end
