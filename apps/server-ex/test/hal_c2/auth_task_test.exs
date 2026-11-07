defmodule HalC2.AuthTaskTest do
  use ExUnit.Case, async: true

  test "a switch the command does not know is refused with the usage, not dropped" do
    assert_raise Mix.Error, ~r/mix hal_c2.auth session list/, fn ->
      Mix.Tasks.HalC2.Auth.run(["session", "issue", "ci", "--tokn"])
    end
  end
end
