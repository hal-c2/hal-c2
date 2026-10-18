defmodule HalC2.Codex.FeedbackTest do
  # A Codex session that stops while it answers `provider.uploadFeedback` is as gone
  # as one the registry no longer has; the caller gets the error, not the exit.
  use ExUnit.Case, async: false

  alias HalC2.Codex.ThreadRuntime

  setup do
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})
    :ok
  end

  # A registered session that receives the feedback call and stops with `reason`.
  defp session_stopping_with(thread_id, reason) do
    test = self()

    # Not linked: its exit would take the test with it.
    session =
      spawn(fn ->
        {:ok, _} = Registry.register(HalC2.Codex.Registry, thread_id, nil)
        send(test, :registered)

        receive do
          {:"$gen_call", _from, {:upload_feedback, _}} -> exit(reason)
        end
      end)

    assert_receive :registered
    on_exit(fn -> Process.exit(session, :kill) end)
  end

  for reason <- [{:shutdown, :released}, :shutdown, :normal, :killed, {:badarg, []}] do
    test "a session that stops with #{inspect(reason)} during the call is gone" do
      session_stopping_with("t1", unquote(Macro.escape(reason)))

      assert {:error, "The provider session is no longer running." <> _} =
               ThreadRuntime.upload_feedback("t1", "wrong answer")
    end
  end
end
