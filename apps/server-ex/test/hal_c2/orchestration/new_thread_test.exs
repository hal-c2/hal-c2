defmodule HalC2.Orchestration.NewThreadTest do
  # Uses the MC-wide named Store and Shell processes.
  use ExUnit.Case, async: false

  alias HalC2.Orchestration.NewThread
  alias HalC2.{Shell, Store}

  @moduletag :tmp_dir

  # A provider that can start a turn, unlike any this machine has: a selection of it
  # came from the shell's list, never from reading the provider CLIs.
  @ready %{"instanceId" => "fake", "models" => [%{"slug" => "fake-1"}]}

  setup %{tmp_dir: dir} do
    start_supervised!({Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(Shell)
    :ok = Shell.subscribe(self())
    :ok
  end

  # The shell waiting on a provider read of the test's: the one it started on its own
  # is no longer listened to, and the list is not known.
  defp unknown_providers do
    ref = make_ref()
    :sys.replace_state(Shell, &%{&1 | providers: nil, providers_read: ref})
    ref
  end

  defp providers_read(ref, providers) do
    send(Shell, {:new_thread_providers, ref, providers})
    :ok = Shell.sync()
  end

  defp put_project(id) do
    Shell.put_row(id, {"project", %{"id" => id, "title" => id, "defaultModelSelection" => nil}})
    :ok = Shell.sync()
    {"project", row} = Shell.row(node(), id)
    row
  end

  test "a project's new-thread model is absent until the provider list is known" do
    ref = unknown_providers()
    row = put_project("p1")
    refute Map.has_key?(row, "newThreadModelSelection")
    assert row["newThreadRuntimeMode"] == "full-access"

    # Known, and none can run: null.
    providers_read(ref, [])
    assert {"project", %{"newThreadModelSelection" => nil}} = Shell.row(node(), "p1")
  end

  test "a create naming a model but no permissions keeps its model and gets the row's mode" do
    providers_read(unknown_providers(), [@ready])
    row = put_project("p1")
    selection = %{"instanceId" => "codex", "model" => "gpt-5.5"}

    assert %{"modelSelection" => ^selection, "runtimeMode" => mode} =
             NewThread.complete(%{"projectId" => "p1", "modelSelection" => selection})

    assert mode == row["newThreadRuntimeMode"]
  end

  test "a create naming nothing runs on the model the project's row shows" do
    providers_read(unknown_providers(), [@ready])
    put_project("p1")

    assert %{"modelSelection" => %{"instanceId" => "fake", "model" => "fake-1"}} =
             NewThread.complete(%{"projectId" => "p1", "runtimeMode" => "approval-required"})
  end
end
