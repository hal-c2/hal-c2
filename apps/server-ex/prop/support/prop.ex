defmodule HalC2.Prop do
  @moduledoc """
  Shared pieces of the stateful property tests in `prop/` (GPL-3.0, see
  `prop/LICENSE.md`): how many cases a property runs, a scratch home for the services
  under test, and the services one case runs against, and the report a failed state machine prints.
  """

  @doc """
  The number of cases a property runs: `default`, or `PROPCHECK_NUMTESTS` when set,
  so a long soak and a quick edit loop use the same tests.
  """
  def numtests(default) do
    case System.get_env("PROPCHECK_NUMTESTS") do
      nil -> default
      n -> String.to_integer(n)
    end
  end

  @doc """
  Points the MC at a fresh directory under `tmp/prop` for one case and returns it.
  Every file a service writes lands there, never in a real HAL-C2 home.
  """
  def scratch_home(name) do
    # The OS pid keeps two runs in one checkout out of each other's homes.
    dir =
      Path.expand(
        "../../tmp/prop/#{name}-#{System.pid()}-#{System.unique_integer([:positive])}",
        __DIR__
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    put_env(:home, dir)
    dir
  end

  @doc """
  `Application.put_env(:hal_c2, key, value)` for one case; `restore_env/0` puts every
  key it set back as it was (unset stays unset), so a case leaves no setting behind
  for the tests that run after it.
  """
  def put_env(key, value) do
    remember({:app, key}, Application.fetch_env(:hal_c2, key))
    Application.put_env(:hal_c2, key, value)
  end

  @doc "`System.put_env/2` (or `System.delete_env/1` for nil) for one case; see `put_env/2`."
  def put_system_env(name, value) do
    remember({:system, name}, System.fetch_env(name))
    if value, do: System.put_env(name, value), else: System.delete_env(name)
  end

  # Only the first setting of a key in a case is what to go back to.
  defp remember(key, prior) do
    saved = Process.get({__MODULE__, :env}, [])

    if not List.keymember?(saved, key, 0),
      do: Process.put({__MODULE__, :env}, [{key, prior} | saved])
  end

  @doc """
  Undoes what `put_env/2`, `put_system_env/2` and `scratch_home/1` set in this case, and
  takes back a store refusing changes (`:store_hook`), however the case set it
  (`HalC2.Test.Machines.refuse_changes/1` included): a store left refusing fails every
  case after it before its first command.
  """
  def restore_env do
    for {key, prior} <- Process.delete({__MODULE__, :env}) || [] do
      case {key, prior} do
        {{:app, key}, {:ok, value}} -> Application.put_env(:hal_c2, key, value)
        {{:app, key}, :error} -> Application.delete_env(:hal_c2, key)
        {{:system, name}, {:ok, value}} -> System.put_env(name, value)
        {{:system, name}, :error} -> System.delete_env(name)
      end
    end

    Application.delete_env(:hal_c2, :store_hook)
  end

  @doc """
  Starts `specs` under a supervisor of their own for one case and returns it.

  PropEr runs every case in a process of its own, where ExUnit's `start_supervised`
  is not available, so a case starts its services with this and stops them with
  `stop_services/0` before it returns. The supervisor is kept in the process
  dictionary, where the commands of the case find it (`restart_service/1`).

  Cases run one at a time, so services still running are an earlier case's that never
  reached `stop_services/0` (its setup raised): they are stopped first, or every case
  after it would fail to start its own.
  """
  def start_services(specs) do
    if sup = Process.whereis(__MODULE__.Services), do: stop_supervisor(sup)

    {:ok, sup} =
      Supervisor.start_link(specs,
        strategy: :one_for_one,
        max_restarts: 0,
        name: __MODULE__.Services
      )

    Process.unlink(sup)
    Process.put({__MODULE__, :services}, sup)
    sup
  end

  @doc """
  Stops what `start_services/1` started, waiting for every child to exit, then
  `restore_env/0`: the case is over, and a `scratch_home/1` it set must not outlive it.
  Services that already went (a crash past `max_restarts: 0`) are stopped already.
  """
  def stop_services do
    case Process.delete({__MODULE__, :services}) do
      nil -> :ok
      sup -> stop_supervisor(sup)
    end
  after
    restore_env()
  end

  defp stop_supervisor(sup) do
    plugins = plugins_supervisor()

    try do
      Supervisor.stop(sup)
    catch
      :exit, :noproc -> :ok
    end

    if plugins, do: await_down(plugins)
  end

  # What runs the plugins hangs off `HalC2.Plugins` and ends after it, so stopping the
  # services does not wait for it. A plugin still running could save into the home of
  # the next case, which would load it.
  defp plugins_supervisor do
    if Process.whereis(HalC2.Plugins), do: :sys.get_state(HalC2.Plugins).supervisor
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
  end

  @doc "Stops the service `id` and starts it again, as a crash or an upgrade would."
  def restart_service(id) do
    sup = Process.get({__MODULE__, :services})
    :ok = Supervisor.terminate_child(sup, id)
    {:ok, _} = Supervisor.restart_child(sup, id)
    :ok
  end

  @doc """
  The message a failed run prints: the commands, the model and the result of each step,
  and why it failed. For `run_parallel_commands/2`, pass the commands, the sequential
  history and the parallel histories it returned in place of the history and state.
  """
  def report({prefix, branches}, sequential, parallel, result) do
    """
    Sequential prefix:
    #{inspect(prefix, pretty: true, limit: :infinity)}

    Parallel branches:
    #{inspect(branches, pretty: true, limit: :infinity)}

    Prefix history (model state and result after each step):
    #{inspect(sequential, pretty: true, limit: :infinity)}

    Branch histories (each step and its result):
    #{inspect(parallel, pretty: true, limit: :infinity)}

    Result: #{inspect(result, pretty: true)}
    """
  end

  def report(cmds, history, state, result) do
    """
    Commands:
    #{inspect(cmds, pretty: true, limit: :infinity)}

    History (model state and result after each step):
    #{inspect(Enum.zip(cmds, history), pretty: true, limit: :infinity)}

    Final model state:
    #{inspect(state, pretty: true, limit: :infinity)}

    Result: #{inspect(result, pretty: true)}
    """
  end
end
