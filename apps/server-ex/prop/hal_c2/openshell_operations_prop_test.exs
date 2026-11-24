defmodule HalC2.OpenShellOperationsPropTest do
  @moduledoc """
  `HalC2.OpenShell.Operations` against a model of one Settings operation at a time:
  clients ask for operations (some with arguments it does not take), the running one
  reports steps and ends with an outcome, raises, or is killed, and the service
  restarts, with the clock where it was or stepped back below every run before.

  This test is the subscriber, and its runner stands in for
  `HalC2.OpenShell.Command.run/2`: a process that tells the test it started and does
  what the test sends it. Every change is waited on through the notification the
  service sends its subscribers. The promises checked:

    * one operation at a time: a request while one runs is refused `busy` and starts
      nothing; one with an unknown operation, an unknown argument, a `force` that is
      not a boolean or a `drain` that is not a list of sandbox names (`true` among
      them: a drain names what its user agreed to delete) is refused `invalid` and
      starts nothing;
    * an operation starts with no steps and no result, and is given its drain's names
      and `force` only when true;
    * each operation's number is larger than every one before it, across restarts too,
      and its reply and every frame of it carry that number; before any since a
      restart there is no operation, and the number is larger than every run's before
      the restart, so a client waiting on a run sees that it went with the old server;
    * its steps are shown in order, the last 20 of them, while it runs;
    * it ends with its outcome (ok or not, with an error's code), a raise or a kill
      ending it not ok, and every subscriber is told each change;
    * a restart while one runs takes it back: it is still running under its number,
      its steps from before are gone, and its later steps and its outcome are shown;
      one that ends while no server is there is shown ended with its outcome (not ok
      when it was killed) under its number;
      after a restart while none runs there is no operation, and a new one may start.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.OpenShell.Operations

  @moduletag timeout: :infinity
  @step_limit 20

  property "Settings runs one OpenShell operation at a time and says how it went",
    numtests: HalC2.Prop.numtests(200),
    max_size: 60 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("openshell-operations")
        Process.put(:runners, [])
        Process.put(:numbers, [])
        Process.put(:boots, [])
        drain()
        # The run the last case's runners were killed under is not this case's to
        # take back.
        :persistent_term.erase({Operations, :running, Operations})

        test = self()
        clock = :atomics.new(1, signed: true)
        :atomics.put(clock, 1, System.os_time(:microsecond))
        Process.put(:clock, clock)

        HalC2.Prop.start_services([
          {Operations, runner: &runner(test, &1, &2), clock: fn -> :atomics.get(clock, 1) end}
        ])

        {:ok, _} = Operations.subscribe(self())

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            HalC2.Prop.stop_services()
            Enum.each(Process.get(:runners), &Process.exit(&1, :kill))
            File.rm_rf!(home)
            drain()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # operation: the one running or last run; run: which run it is, counting every
  # run this test started (:boot: none since a restart, numbered when the server
  # started); started: how many runs this test started; running: whether it runs;
  # steps: its steps so far; result: how it ended, as `{ok, code}`.
  def initial_state,
    do: %{operation: nil, run: :boot, started: 0, running: false, steps: [], result: nil}

  def command(state) do
    frequency(
      [
        {4, {:call, __MODULE__, :run, [input()]}},
        {1, {:call, __MODULE__, :state, []}},
        {2, {:call, __MODULE__, :restart, [oneof([:on, :back])]}}
      ] ++
        if(state.running,
          do: [
            {4, {:call, __MODULE__, :step, [oneof(~w(Downloading Starting Checking))]}},
            {2, {:call, __MODULE__, :answer, [answer()]}},
            {1, {:call, __MODULE__, :raise_in_runner, []}},
            {1, {:call, __MODULE__, :kill_runner, []}},
            {1, {:call, __MODULE__, :end_while_down, [oneof([answer(), :kill])]}}
          ],
          else: []
        )
    )
  end

  defp input do
    frequency([
      {6,
       let [operation <- oneof(~w(install check rotate uninstall)), flags <- flags()] do
         Map.put(flags, "operation", operation)
       end},
      {1, oneof([%{}, %{"operation" => "reap"}, %{"operation" => "install", "archive" => "x"}])},
      {1,
       oneof([
         %{"operation" => "install", "drain" => "yes"},
         %{"operation" => "install", "drain" => true},
         %{"operation" => "uninstall", "drain" => [""]},
         %{"operation" => "install", "force" => "yes"}
       ])}
    ])
  end

  defp flags do
    let [
      drain <- oneof([nil, [], ["review-a"], ["review-a", "review-b"]]),
      force <- oneof([nil, true, false])
    ] do
      %{"drain" => drain, "force" => force} |> Map.reject(fn {_, v} -> v == nil end)
    end
  end

  defp answer do
    oneof([
      {:ok, "done"},
      {:error, "Downloading failed: timeout"},
      {:error,
       "[sandboxes-running] 2 of this MC's sandboxes are on the gateway (review-a, review-b). Let their reviews finish, or pass --drain to delete them."},
      {:error,
       "[sandboxes-changed] The running reviews changed since they were confirmed: 1 of this MC's sandboxes is on the gateway (review-c). Check them again before deleting them."},
      {:error, HalC2.OpenShell.Install.busy()}
    ])
  end

  def precondition(state, {:call, _, name, _})
      when name in [:step, :answer, :raise_in_runner, :kill_runner, :end_while_down],
      do: state.running

  def precondition(_state, _call), do: true

  def next_state(state, _result, call), do: elem(step(state, call), 0)

  def postcondition(state, call, seen) do
    {_, expected} = step(state, call)
    seen == expected
  end

  # The model's next state, and what the call is expected to give back: a refusal's
  # reason, or the snapshot the subscriber is told (and, for a run, the flags the
  # runner was given).
  defp step(state, {:call, _, :run, [input]}) do
    cond do
      not valid?(input) ->
        {state, {:refused, "invalid"}}

      state.running ->
        {state, {:refused, "busy"}}

      true ->
        state = %{
          state
          | operation: input["operation"],
            run: state.started + 1,
            started: state.started + 1,
            running: true,
            steps: [],
            result: nil
        }

        flags =
          for {key, value} <- Enum.sort(Map.delete(input, "operation")),
              value != false,
              do: {String.to_existing_atom(key), value}

        {state, {:started, snapshot(state), flags}}
    end
  end

  defp step(state, {:call, _, :step, [text]}) do
    state = %{state | steps: Enum.take(state.steps ++ [text], -@step_limit)}
    {state, snapshot(state)}
  end

  defp step(state, {:call, _, :answer, [answer]}) do
    result =
      case answer do
        {:ok, _} -> {true, nil}
        {:error, "[" <> rest} -> {false, rest |> String.split("]") |> hd()}
        {:error, _} -> {false, nil}
      end

    finish(state, result)
  end

  defp step(state, {:call, _, name, []}) when name in [:raise_in_runner, :kill_runner],
    do: finish(state, {false, nil})

  defp step(state, {:call, _, :state, []}), do: {state, snapshot(state)}

  defp step(state, {:call, _, :end_while_down, [ending]}) do
    {state, _} = step(state, {:call, __MODULE__, :restart, [:on]})

    case ending do
      :kill -> finish(state, {false, nil})
      answer -> step(state, {:call, __MODULE__, :answer, [answer]})
    end
  end

  defp step(state, {:call, _, :restart, [_clock]}) do
    state =
      if state.running,
        do: %{state | steps: []},
        else: %{initial_state() | started: state.started}

    {state, snapshot(state)}
  end

  defp finish(state, result) do
    state = %{state | running: false, result: result}
    {state, snapshot(state)}
  end

  defp valid?(%{"operation" => operation} = input)
       when operation in ~w(install check rotate uninstall) do
    flags = Map.delete(input, "operation")

    Enum.all?(flags, fn
      {"drain", names} -> is_list(names) and Enum.all?(names, &(is_binary(&1) and &1 != ""))
      {"force", value} -> is_boolean(value)
      _ -> false
    end) and (operation != "check" or flags == %{})
  end

  defp valid?(_input), do: false

  defp snapshot(state),
    do: %{
      operation: state.operation,
      run: state.run,
      running: state.running,
      steps: state.steps,
      result: state.result
    }

  # --- the real thing ---------------------------------------------------------------

  def run(input) do
    case Operations.run(input) do
      {:ok, reply} ->
        # Larger than every number before it, the servers' starts too.
        numbers = Process.get(:numbers)
        true = Enum.all?(numbers ++ Process.get(:boots), &(&1 < reply["run"]))
        Process.put(:numbers, numbers ++ [reply["run"]])
        changed = notified()
        ^changed = model(reply)
        assert_receive {:runner, pid, operation, opts}, 5_000
        ^operation = String.to_existing_atom(input["operation"])
        Process.put(:runner, pid)
        Process.put(:runners, [pid | Process.get(:runners)])
        {:started, changed, opts |> Keyword.delete(:progress) |> Enum.sort()}

      {:error, %{"_tag" => "ServerOpenShellOperationError", "reason" => reason}} ->
        {:refused, reason}
    end
  end

  def step(text) do
    send(Process.get(:runner), {:step, text})
    notified()
  end

  def answer(answer) do
    send(Process.get(:runner), {:answer, answer})
    notified()
  end

  def raise_in_runner do
    send(Process.get(:runner), :raise)
    notified()
  end

  def kill_runner do
    Process.exit(Process.get(:runner), :kill)
    notified()
  end

  # The service goes down, the runner answers or is killed while none is there to
  # hear it, and a new one starts.
  def end_while_down(ending) do
    runner = Process.get(:runner)

    :ok =
      HalC2.Prop.restart_service(Operations, fn ->
        ref = Process.monitor(runner)

        case ending do
          :kill -> Process.exit(runner, :kill)
          answer -> send(runner, {:answer, answer})
        end

        receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
      end)

    {:ok, state} = Operations.subscribe(self())
    model(state)
  end

  def state do
    {:ok, state} = Operations.state()
    model(state)
  end

  # The subscription goes with the server; the test subscribes to the new one. The
  # clock goes on, or back below every number before.
  def restart(clock) do
    now = if clock == :back, do: 1, else: System.os_time(:microsecond)
    :atomics.put(Process.get(:clock), 1, now)
    :ok = HalC2.Prop.restart_service(Operations)
    {:ok, state} = Operations.subscribe(self())
    model(state)
  end

  def runner(test, operation, opts) do
    send(test, {:runner, self(), operation, opts})
    loop(opts[:progress])
  end

  defp loop(progress) do
    receive do
      {:step, text} ->
        progress.(text)
        loop(progress)

      {:answer, answer} ->
        answer

      :raise ->
        raise "the runner failed"
    end
  end

  defp notified do
    receive do
      {:hal_c2_openshell, _node, state} -> model(state)
    after
      5_000 -> :no_notification
    end
  end

  # A run's number as the how-manieth run this test started it is. With no
  # operation it is when the server started: :boot, once it is larger than every
  # run's before it and no smaller than an earlier server's start.
  defp model(state),
    do: %{
      operation: state["operation"],
      run: number(state),
      running: state["running"],
      steps: state["steps"],
      result: state["result"] && {state["result"]["ok"], state["result"]["code"]}
    }

  defp number(%{"operation" => nil, "run" => run}) do
    boots = Process.get(:boots)
    true = Enum.all?(Process.get(:numbers), &(&1 < run)) and Enum.all?(boots, &(&1 <= run))
    Process.put(:boots, boots ++ [run])
    :boot
  end

  defp number(%{"run" => run}),
    do: Enum.find_index(Process.get(:numbers), &(&1 == run)) + 1

  defp drain do
    receive do
      {:hal_c2_openshell, _, _} -> drain()
      {:runner, _, _, _} -> drain()
    after
      0 -> :ok
    end
  end
end
