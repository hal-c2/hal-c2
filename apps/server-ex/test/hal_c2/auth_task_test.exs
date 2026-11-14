defmodule HalC2.AuthTaskTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "session revoke works without the Auth ETS tables", %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    session = HalC2.Auth.issue_session(Path.join(dir, "hal-c2.sqlite"), "ci")
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      assert :ets.whereis(HalC2.Auth.Tickets) == :undefined
      Mix.Tasks.HalC2.Auth.run(["session", "revoke", session.id])
      assert_received {:mix_shell, :info, [message]}
      assert message == "#{session.id}: the session was revoked"
      assert HalC2.Auth.list_sessions(Path.join(dir, "hal-c2.sqlite")) == []
    after
      Mix.shell(shell)
    end
  end

  test "a switch the command does not know is refused with the usage, not dropped" do
    assert_raise Mix.Error, ~r/mix hal_c2.auth session list/, fn ->
      Mix.Tasks.HalC2.Auth.run(["session", "issue", "ci", "--tokn"])
    end
  end
end
