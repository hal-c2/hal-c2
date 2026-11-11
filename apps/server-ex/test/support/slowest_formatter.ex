defmodule HalC2.Test.SlowestFormatter do
  @moduledoc """
  An ExUnit formatter that prints the slowest tests and test modules when the suite ends.
  `test_helper.exs` adds it when `HAL_C2_TEST_SLOWEST` names how many of each to show, as CI does.

  ExUnit's own `--slowest` and `--slowest-modules` turn on `--trace`, which runs one test
  module at a time and ignores every test's timeout. This one only listens, so the suite
  runs as it would without it.
  """

  use GenServer

  @doc "How many of each `HAL_C2_TEST_SLOWEST` asks for, or 0 when it is unset."
  def count do
    case Integer.parse(System.get_env("HAL_C2_TEST_SLOWEST", "")) do
      {count, ""} when count > 0 -> count
      _ -> 0
    end
  end

  def init(_config), do: {:ok, %{count: count(), tests: []}}

  def handle_cast({:test_finished, %ExUnit.Test{state: state} = test}, config)
      when state == nil or elem(state, 0) == :failed do
    entry = {test.module, test.name, test.tags.file, test.tags.line, test.tags[:async], test.time}
    {:noreply, %{config | tests: [entry | config.tests]}}
  end

  def handle_cast({:suite_finished, %{run: run_us}}, config) do
    IO.puts(report(config, run_us))
    {:noreply, config}
  end

  def handle_cast(_event, config), do: {:noreply, config}

  defp report(%{count: count, tests: tests}, run_us) do
    slowest_tests =
      tests
      |> Enum.sort_by(&elem(&1, 5), :desc)
      |> Enum.take(count)
      |> Enum.map(fn {module, name, file, line, async, time} ->
        "  #{ms(time)} #{mode(async)} #{inspect(module)} #{name} [#{relative(file)}:#{line}]\n"
      end)

    slowest_modules =
      tests
      |> Enum.group_by(&{elem(&1, 0), elem(&1, 2), elem(&1, 4)}, &elem(&1, 5))
      |> Enum.map(fn {key, times} -> {key, Enum.sum(times)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(count)
      |> Enum.map(fn {{module, file, async}, time} ->
        "  #{ms(time)} #{mode(async)} #{inspect(module)} [#{relative(file)}]\n"
      end)

    [
      "\nSlowest #{count} tests of a #{ms(run_us)} run:\n",
      slowest_tests,
      "\nSlowest #{count} modules, by the sum of their tests:\n",
      slowest_modules
    ]
  end

  defp ms(us), do: String.pad_leading("#{div(us, 1000)} ms", 10)
  defp mode(async), do: if(async, do: "async", else: "sync ")
  defp relative(file), do: Path.relative_to_cwd(file)
end
