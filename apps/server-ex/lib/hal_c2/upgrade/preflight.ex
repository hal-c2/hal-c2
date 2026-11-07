defmodule HalC2.Upgrade.Preflight do
  @moduledoc """
  Whether a staged version can run on this machine, asked of that version before the
  MC stops to restart into it (`HalC2.Upgrade`). Only a restart brings another Erlang
  runtime or native code, so only a restart needs this.

  `run/2` starts the unpacked bundle as a release of its own (`bin/hal_c2 eval`), on
  its own runtime, and has it run `main/0`: a runtime built for another machine fails
  to start at all, and `main/0` loads every module of the release, so native code that
  does not load here (a NIF, a runtime library) fails too. A bundle without a launcher,
  or a version from before this check, has nothing to ask and passes.
  """

  @timeout :timer.minutes(2)
  @eval "if Code.ensure_loaded?(HalC2.Upgrade.Preflight), do: HalC2.Upgrade.Preflight.main()"

  @doc "`:ok`, or `{:error, reason}` with what the staged version at `bundle` said."
  def run(bundle, version, timeout \\ @timeout) do
    launcher = Path.join([bundle, "bin", "hal_c2"])

    if File.regular?(launcher) do
      # The launcher finds its release from where it lies; what the running MC's own
      # launcher exported would point it at the running release instead.
      env =
        for {name, _} <- System.get_env(),
            String.starts_with?(name, "RELEASE_") or name == "ELIXIR_ERL_OPTIONS",
            do: {String.to_charlist(name), false}

      port =
        Port.open({:spawn_executable, String.to_charlist(launcher)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["eval", @eval],
          env: env ++ [{~c"RELEASE_VSN", String.to_charlist(version)}]
        ])

      # A launcher that already exited has closed its port, and has nothing to kill.
      os_pid = with {:os_pid, pid} <- Port.info(port, :os_pid), do: pid
      collect(port, os_pid, System.monotonic_time(:millisecond) + timeout, timeout, [])
    else
      :ok
    end
  end

  defp collect(port, os_pid, deadline, timeout, output) do
    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, timeout, [output, data])

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        text = output |> IO.iodata_to_binary() |> String.trim()
        {:error, if(text == "", do: "it exited with status #{status}", else: text)}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)

        if os_pid,
          do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

        {:error, "it did not answer within #{timeout} ms"}
    end
  end

  @doc """
  Inside the staged version: loads every module of its release, prints what does not
  load and exits 1, or exits 0.
  """
  def main do
    case check(release_paths()) do
      [] ->
        System.halt(0)

      failures ->
        for {mod, reason} <- Enum.take(failures, 5),
            do: IO.puts("#{inspect(mod)} does not load here: #{inspect(reason)}")

        System.halt(1)
    end
  end

  @doc "The modules in the code directories `paths` that do not load, as `{module, reason}`."
  # The modules are the release's own, whose atoms loading them makes anyway.
  # sobelow_skip ["DOS.StringToAtom"]
  def check(paths) do
    for path <- paths,
        file <- Path.wildcard(Path.join(path, "*.beam")),
        mod = String.to_atom(Path.basename(file, ".beam")),
        reason = load(mod),
        do: {mod, reason}
  end

  defp load(mod) do
    case Code.ensure_loaded(mod) do
      {:module, _} -> nil
      {:error, reason} -> reason
    end
  end

  # The release's own code directories, not those of whatever started it.
  defp release_paths do
    root = System.get_env("RELEASE_ROOT") || ""
    lib = Path.join(root, "lib") <> "/"
    for path <- :code.get_path(), path = to_string(path), String.starts_with?(path, lib), do: path
  end
end
