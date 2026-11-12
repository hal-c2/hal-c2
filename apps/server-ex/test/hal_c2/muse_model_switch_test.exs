defmodule HalC2.MuseModelSwitchTest do
  # A session Muse lost is handed the thread by the first turn that reaches Muse, not
  # by one whose model switch failed (HalC2.AcpModelSwitchPropTest found it in ACP).
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @tid "muse-switch-thread"
  @fake Path.expand("../support/fake_muse_msp.py", __DIR__)

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)

    on_exit(fn ->
      HalC2.Acp.forget("muse")
      if previous, do: Application.put_env(:hal_c2, :home, previous)
    end)

    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.Orchestration.TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Muse.Registry})

    for {name, id} <- [
          {HalC2.Codex.Registry, :codex},
          {HalC2.Claude.Registry, :claude},
          {HalC2.Acp.Registry, :acp},
          {HalC2.Pi.Registry, :pi}
        ],
        do: start_supervised!({Registry, keys: :unique, name: name}, id: id)

    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    start_supervised!(HalC2.Settings)
    HalC2.Acp.forget("muse")

    fake = Path.join(dir, "fake-muse")
    File.mkdir_p!(Path.join(fake, "bin"))

    File.write!(
      Path.join(fake, "config.json"),
      JSON.encode!(%{"refuseModels" => ["fake/broken"]})
    )

    bin = Path.join([fake, "bin", "muse"])
    File.write!(bin, "#!/bin/sh\nexport FAKE_DIR='#{fake}'\nexec python3 -u '#{@fake}' \"$@\"\n")
    File.chmod!(bin, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{"providers" => %{"muse" => %{"enabled" => true, "binaryPath" => bin}}},
        0
      )

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Muse",
        "modelSelection" => %{"instanceId" => "muse", "model" => "fake/one"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    {:ok, fake: fake}
  end

  test "a lost session is handed the thread after a turn whose model switch failed",
       %{fake: fake} do
    assert {"completed", _} = turn("m1", "fake/one", "remember the walrus")

    # Muse loses its sessions, with the runtime that had one open.
    File.rm_rf!(Path.join(fake, "sessions"))
    [{pid, _}] = Registry.lookup(HalC2.Muse.Registry, @tid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}

    assert {"failed", ""} = turn("m2", "fake/broken", "try the broken model")
    assert {"completed", reply} = turn("m3", "fake/one", "what was it")
    assert reply =~ "remember the walrus"
  end

  defp turn(id, model, text) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => id,
        "text" => text,
        "attachments" => [],
        "modelSelection" => %{"instanceId" => "muse", "model" => model},
        "dispatchMode" => %{"type" => "queue_after_active"},
        "deliveryIntent" => "auto"
      })

    await_turn(id)
  end

  defp await_turn(id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    run = state |> StreamState.list("run") |> Enum.find(&(&1["userMessageId"] == id))

    if run && run["status"] in ~w(completed failed) do
      text =
        state
        |> StreamState.list("message")
        |> Enum.filter(&(&1["role"] == "assistant" and &1["runId"] == run["id"]))
        |> Enum.map_join(&(&1["text"] || ""))

      {run["status"], text}
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_turn(id)
      after
        15_000 -> flunk("turn #{id} did not finish")
      end
    end
  end
end
