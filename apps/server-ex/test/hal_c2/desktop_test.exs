defmodule HalC2.DesktopTest do
  use ExUnit.Case, async: false

  setup do
    previous_bootstrap = System.get_env("HAL_C2_BOOTSTRAP_STDIN")
    previous_exit = Application.fetch_env(:hal_c2, :desktop_exit)

    on_exit(fn ->
      if previous_bootstrap,
        do: System.put_env("HAL_C2_BOOTSTRAP_STDIN", previous_bootstrap),
        else: System.delete_env("HAL_C2_BOOTSTRAP_STDIN")

      case previous_exit do
        {:ok, value} -> Application.put_env(:hal_c2, :desktop_exit, value)
        :error -> Application.delete_env(:hal_c2, :desktop_exit)
      end
    end)

    :ok
  end

  test "a bootstrap asking for the stdin lifeline stops the MC when stdin ends" do
    System.put_env("HAL_C2_BOOTSTRAP_STDIN", "1")
    test = self()
    Application.put_env(:hal_c2, :desktop_exit, &send(test, {:desktop_stdin_closed, &1}))

    line = JSON.encode!(%{"stdinLifeline" => true})
    {:ok, stdin} = StringIO.open(line <> "\n")

    :ok =
      Task.async(fn ->
        Process.group_leader(self(), stdin)
        HalC2.Desktop.configure()
      end)
      |> Task.await()

    assert_receive {:desktop_stdin_closed, 0}, 1_000
  end
end
