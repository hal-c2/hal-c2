Code.require_file("../../credo/checks/waits_in_changing_code.ex", __DIR__)

defmodule HalC2.CredoWaitsTest do
  use Credo.Test.Case

  alias HalC2.Credo.WaitsInChangingCode, as: Check

  setup_all do
    {:ok, _} = Application.ensure_all_started(:credo)
    :ok
  end

  defp messages(code, params \\ []) do
    code
    |> to_source_file("lib/example.ex")
    |> run_check(Check, params)
    |> Enum.map(& &1.message)
  end

  test "a receive without an end waits in code that changes" do
    assert [message] =
             messages("""
             defmodule Example do
               def wait, do: receive(do: (:go -> :ok))
             end
             """)

    assert message =~ "`receive` waits with no end"

    assert [_] =
             messages("""
             defmodule Example do
               def wait do
                 receive do
                   :go -> :ok
                 after
                   :infinity -> :ok
                 end
               end
             end
             """)
  end

  test "a bounded receive is a short wait" do
    assert [] =
             messages("""
             defmodule Example do
               def wait do
                 receive do
                   :go -> :ok
                 after
                   1_000 -> :timeout
                 end
               end
             end
             """)
  end

  test "the loop of a process spawned here is found through the functions it starts in" do
    assert [message] =
             messages("""
             defmodule Example do
               def start(proc), do: spawn_link(fn -> init(proc) end)
               defp init(proc), do: __MODULE__.loop(proc)
               def loop(proc) do
                 {:ok, _} = Exile.Process.read(proc, 100)
                 __MODULE__.loop(proc)
               end
             end
             """)

    assert message =~ "`loop` is the waiting loop"
  end

  test "recursion that does not wait is not a process loop" do
    assert [] =
             messages("""
             defmodule Example do
               def start(list), do: spawn(fn -> count(list, 0) end)
               defp count([], n), do: n
               defp count([_ | rest], n), do: count(rest, n + 1)
             end
             """)
  end

  test "a frozen module may wait" do
    assert [] =
             messages("""
             defmodule Example do
               use HalC2.Frozen
               def wait, do: receive(do: (:go -> :ok))
             end
             """)
  end

  @tag :tmp_dir
  test "the baseline excuses what it lists and asks for what it no longer needs", %{tmp_dir: dir} do
    baseline = Path.join(dir, "baseline.exs")
    File.write!(baseline, ~s|[{"lib/example.ex", [wait: :wait, gone: :wait]}]|)

    assert [message] =
             messages(
               """
               defmodule Example do
                 def wait, do: receive(do: (:go -> :ok))
               end
               """,
               baseline: baseline
             )

    assert message =~ "lists `gone`"
  end

  @tag :tmp_dir
  test "the baseline asks for entries of files that are gone", %{tmp_dir: dir} do
    baseline = Path.join(dir, "baseline.exs")
    File.write!(baseline, ~s|[{"lib/hal_c2/no_such_file.ex", [loop: :loop]}]|)

    # Not an issue of a checked file, so it is read off the run, as `mix credo` does.
    exec = Credo.Execution.build()
    source = to_source_file("defmodule Example, do: def(ok, do: :ok)", "lib/example.ex")
    :ok = Check.run_on_all_source_files(exec, [source], baseline: baseline)

    assert [[issue]] = Map.values(Credo.Execution.ExecutionIssues.to_map(exec))
    assert issue.message =~ "lists `lib/hal_c2/no_such_file.ex`, which no longer exists"
  end
end
