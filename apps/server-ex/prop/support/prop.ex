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
    Application.put_env(:hal_c2, :home, dir)
    dir
  end

  @doc """
  Starts `specs` under a supervisor of their own for one case and returns it.

  PropEr runs every case in a process of its own, where ExUnit's `start_supervised`
  is not available, so a case starts its services with this and stops them with
  `stop_services/0` before it returns. The supervisor is kept in the process
  dictionary, where the commands of the case find it (`restart_service/1`).
  """
  def start_services(specs) do
    {:ok, sup} = Supervisor.start_link(specs, strategy: :one_for_one, max_restarts: 0)
    Process.unlink(sup)
    Process.put({__MODULE__, :services}, sup)
    sup
  end

  @doc "Stops what `start_services/1` started, waiting for every child to exit."
  def stop_services do
    case Process.delete({__MODULE__, :services}) do
      nil -> :ok
      sup -> Supervisor.stop(sup)
    end
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
