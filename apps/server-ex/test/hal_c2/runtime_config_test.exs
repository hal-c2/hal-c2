defmodule HalC2.RuntimeConfigTest do
  # Sets the OS environment, which every process shares.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    previous = System.get_env("HAL_C2_MC_HOME")

    on_exit(fn ->
      if previous,
        do: System.put_env("HAL_C2_MC_HOME", previous),
        else: System.delete_env("HAL_C2_MC_HOME")
    end)
  end

  # A shell that exported a scratch MC's home, as AGENTS.md's test-data recipe does,
  # had the tests open that MC's store: its running MC held it locked.
  test "a test run keeps to the checkout's home whatever HAL_C2_MC_HOME says" do
    System.put_env("HAL_C2_MC_HOME", "/scratch/mc")

    refute Keyword.has_key?(read(:test), :home)
    assert read(:dev)[:home] == {:mc, "/scratch/mc"}
    assert read(:prod)[:home] == {:mc, "/scratch/mc"}
  end

  defp read(env), do: Config.Reader.read!(@runtime, env: env, target: :host)[:hal_c2] || []
end
