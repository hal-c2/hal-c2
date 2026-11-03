defmodule HalC2.WakeTest do
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.Wake

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(Wake)

    thread_id = "thread-#{System.unique_integer([:positive])}"

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Woken",
        "modelSelection" => %{"instanceId" => "claude", "model" => "claude-opus"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    on_exit(fn ->
      Application.delete_env(:hal_c2, :wake_hook)
      Application.delete_env(:hal_c2, :wake_pause)
    end)

    %{thread_id: thread_id}
  end

  @doc false
  # Refuses the first try, takes the next, and tells the test each one.
  def refuse_first(test, command) do
    send(test, {:tried, command})

    case Process.get(:tried) do
      nil ->
        Process.put(:tried, true)
        {:error, "not yet"}

      true ->
        {:ok, :sent}
    end
  end

  @doc false
  def no_pause(_attempt), do: 0

  # A refused try used to lose the instance that woke, so the retry went out on the
  # model of the thread's latest run, another provider's.
  test "a retried wake keeps the model of the provider that woke", %{thread_id: thread_id} do
    codex = %{"instanceId" => "codex", "model" => "gpt-5.4"}
    claude = %{"instanceId" => "claude", "model" => "claude-opus"}

    for {id, ordinal, selection} <- [{"run:1", 1, codex}, {"run:2", 2, claude}] do
      run = %{
        "id" => id,
        "ordinal" => ordinal,
        "status" => "completed",
        "modelSelection" => selection
      }

      {:ok, _} =
        HalC2.Streams.commit(thread_id, :thread, [{"run", id, HalC2.Patch.diff(nil, run)}])
    end

    Application.put_env(:hal_c2, :wake_hook, {__MODULE__, :refuse_first, [self()]})
    Application.put_env(:hal_c2, :wake_pause, {__MODULE__, :no_pause, []})

    Wake.deliver(thread_id, %{"text" => "Background command completed"}, instance: "codex")
    :ok = Wake.drain()

    assert_received {:tried, %{"modelSelection" => ^codex}}
    assert_received {:tried, %{"modelSelection" => ^codex}}
    refute_received {:tried, _}
  end
end
